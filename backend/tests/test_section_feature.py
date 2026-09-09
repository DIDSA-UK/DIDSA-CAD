"""Real-OCCT tests for the sectioning tool's stateless `POST .../section-
preview` endpoint (`app.document.section`/`app.document.router.
preview_section`) - same `ast.parse`-verified/manually reviewed caveat as
every other OCCT-touching backend test in this project until real CI runs
it (see `test_stage_d_fillet.py`'s own identical caveat).
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers -----------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _first_body_id(part_id: str) -> str:
    mesh = _mesh(part_id)
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _boxy_part_and_body() -> tuple[dict, str]:
    """A plain 10x10x10 box spanning x/y/z in [0, 10] - same construction
    `test_stage_d_fillet.py` uses for its own box fixture."""
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    return part, _first_body_id(part["id"])


def _box_with_through_hole_and_body() -> tuple[dict, str]:
    """The same 10x10x10 box, with a 4x4 square hole cut straight through
    it in Z (x/y in [3, 7], the full z height) - built as a second, smaller
    square Sketch cut into the first Extrude's own Body via `target_body_
    ids`, mirroring how every other Boss/Cut-pair test in this project
    builds non-trivial test geometry."""
    part, body_id = _boxy_part_and_body()
    hole_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    _create_extrude_feature(part["id"], hole_sketch["id"], extrude_type="cut", target_body_ids=[body_id])
    return part, _first_body_id(part["id"])


def _section_preview(part_id: str, body_ids: list[str], planes: list[dict], expected_status: int = 200) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/section-preview",
        json={"body_ids": body_ids, "planes": planes},
    )
    assert response.status_code == expected_status, response.text
    return response.json()


def _plane(origin: tuple[float, float, float], normal: tuple[float, float, float], flipped: bool = False) -> dict:
    return {"origin": list(origin), "normal": list(normal), "flipped": flipped}


def _bbox(mesh: dict) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    vertices = mesh["vertices"]
    xs, ys, zs = (v[0] for v in vertices), (v[1] for v in vertices), (v[2] for v in vertices)
    xs, ys, zs = list(xs), list(ys), list(zs)
    return (min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))


def _triangle_area(a: list[float], b: list[float], c: list[float]) -> float:
    ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
    cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    return 0.5 * (cx * cx + cy * cy + cz * cz) ** 0.5


def _cut_face_area(body: dict) -> float:
    mesh = body["mesh"]
    vertices, triangle_indices, face_ids = mesh["vertices"], mesh["triangle_indices"], mesh["face_ids"]
    cut_ids = set(body["cut_face_ids"])
    return sum(
        _triangle_area(vertices[a], vertices[b], vertices[c])
        for (a, b, c), face_id in zip(triangle_indices, face_ids)
        if face_id in cut_ids
    )


_TOLERANCE = 1e-2


# --- Success -----------------------------------------------------------------


def test_cutting_a_box_with_one_plane_keeps_roughly_half_the_volume_and_caps_the_face():
    part, body_id = _boxy_part_and_body()
    bodies = _section_preview(part["id"], [body_id], [_plane((0, 0, 5), (0, 0, 1))])
    assert len(bodies) == 1
    body = bodies[0]
    assert body["body_id"] == body_id
    assert body["source"] == "section"
    assert len(body["cut_face_ids"]) > 0

    (min_x, min_y, min_z), (max_x, max_y, max_z) = _bbox(body["mesh"])
    # +normal (z) side is kept: z in [5, 10], x/y unchanged from the box's own [0, 10].
    assert abs(min_z - 5.0) < _TOLERANCE
    assert abs(max_z - 10.0) < _TOLERANCE
    assert abs(min_x - 0.0) < _TOLERANCE and abs(max_x - 10.0) < _TOLERANCE
    assert abs(min_y - 0.0) < _TOLERANCE and abs(max_y - 10.0) < _TOLERANCE


def test_flipped_keeps_the_opposite_side():
    part, body_id = _boxy_part_and_body()
    bodies = _section_preview(part["id"], [body_id], [_plane((0, 0, 5), (0, 0, 1), flipped=True)])
    (min_x, _min_y, min_z), (_max_x, _max_y, max_z) = _bbox(bodies[0]["mesh"])
    # Flipped: the opposite (-normal) side is now kept: z in [0, 5].
    assert abs(min_z - 0.0) < _TOLERANCE
    assert abs(max_z - 5.0) < _TOLERANCE


def test_cutting_a_box_with_two_perpendicular_planes_gives_a_quarter_cutaway():
    part, body_id = _boxy_part_and_body()
    bodies = _section_preview(
        part["id"],
        [body_id],
        [_plane((0, 0, 5), (0, 0, 1)), _plane((5, 0, 0), (1, 0, 0))],
    )
    (min_x, min_y, min_z), (max_x, max_y, max_z) = _bbox(bodies[0]["mesh"])
    assert abs(min_x - 5.0) < _TOLERANCE and abs(max_x - 10.0) < _TOLERANCE
    assert abs(min_z - 5.0) < _TOLERANCE and abs(max_z - 10.0) < _TOLERANCE
    assert abs(min_y - 0.0) < _TOLERANCE and abs(max_y - 10.0) < _TOLERANCE


def test_cutting_a_box_with_an_internal_cavity_caps_the_hole_correctly():
    """The reason this whole feature computes via real OCCT geometry rather
    than naive client-side mesh-triangle clipping: a solid with a hole
    through it must produce a cap face that correctly has a hole in it too,
    not a face that's wrongly filled in solid where the cavity is."""
    part, body_id = _box_with_through_hole_and_body()
    # A plane through the mid-height, squarely crossing the through-hole -
    # its own cap face is the full 10x10 cross-section minus the 4x4 hole.
    bodies = _section_preview(part["id"], [body_id], [_plane((0, 0, 5), (0, 0, 1))])
    body = bodies[0]
    assert len(body["cut_face_ids"]) > 0

    cap_area = _cut_face_area(body)
    full_cross_section_area = 10.0 * 10.0
    hole_area = 4.0 * 4.0
    expected_area = full_cross_section_area - hole_area
    # A generous tolerance (not `_TOLERANCE`) - this is an area, not a
    # single linear dimension, so tessellation deflection error compounds;
    # what actually matters for this test is that the hole was subtracted
    # at all (cap_area is measurably less than the full, un-holed
    # cross-section), not exact mesh-area precision.
    assert cap_area < full_cross_section_area - 1.0
    assert abs(cap_area - expected_area) < 2.0


# --- Rejections ----------------------------------------------------------------


def test_an_empty_planes_list_is_rejected():
    part, body_id = _boxy_part_and_body()
    response_json = _section_preview(part["id"], [body_id], [], expected_status=422)
    assert response_json["detail"]["type"] == "no_section_planes"


def test_an_unknown_body_id_is_rejected():
    part, _body_id = _boxy_part_and_body()
    response_json = _section_preview(
        part["id"], ["not-a-real-body-id"], [_plane((0, 0, 5), (0, 0, 1))], expected_status=422
    )
    detail = response_json["detail"]
    assert detail["type"] == "unknown_body_id"
    assert detail["body_id"] == "not-a-real-body-id"
