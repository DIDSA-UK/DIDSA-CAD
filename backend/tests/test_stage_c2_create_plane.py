"""C2: real-OCCT tests for Create Plane's full router/HTTP surface - both
plane types end to end (OFFSET_FACE needs a real face/planarity check;
NORMAL_TO_LINE_AT_POINT could run without OCCT on its own, see
test_stage_c2_plane_geometry.py, but exercising it here too over the real
API confirms the router's payload validation/dispatch, not just the math).

Needs a real pythonocc-core environment (not available in this sandbox -
see the recurring caveat in docs/status.md) since `app.main` imports OCC
directly - `ast.parse`-verified/manually reviewed only here, same as every
other OCCT-touching backend prompt in this project until real CI runs it.
"""

import pytest
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


def _create_circle_sketch_feature(part_id: str, *, radius: float = 10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    center = client.post(f"/sketch/sketches/{feature['sketch_id']}/points", json={"x": 0.0, "y": 0.0}).json()
    response = client.post(
        f"/sketch/sketches/{feature['sketch_id']}/circles",
        json={"center_point_id": center["id"], "radius": radius, "angle": 0.0},
    )
    assert response.status_code == 201
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


def _first_body_id(part_id: str) -> str:
    mesh = client.get(f"/document/parts/{part_id}/mesh").json()
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _create_offset_face_plane(part_id: str, body_id: str, index: int, offset: float):
    return client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_ref": {"body_id": body_id, "shape_type": "face", "index": index},
            "offset": offset,
        },
    )


def _create_normal_to_line_plane(
    part_id: str, sketch_id: str, line_id: str, point_id: str
):
    return client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={
            "plane_type": "normal_to_line_at_point",
            "line_ref": {"sketch_id": sketch_id, "entity_type": "line", "entity_id": line_id},
            "point_ref": {"sketch_id": sketch_id, "entity_type": "point", "entity_id": point_id},
        },
    )


# --- OFFSET_FACE -------------------------------------------------------------


def test_offset_face_against_a_real_planar_face_succeeds():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])

    # A boxy extrude has 6 planar faces - try each index until one resolves
    # (face-index-to-side correspondence isn't part of this API's contract,
    # only "some planar face exists" is guaranteed).
    last_response = None
    for index in range(6):
        response = _create_offset_face_plane(part["id"], body_id, index, offset=5.0)
        last_response = response
        if response.status_code == 201:
            break
    assert last_response.status_code == 201
    body = last_response.json()
    assert body["plane_type"] == "offset_face"
    assert body["origin"] is not None
    assert body["normal"] is not None
    assert body["produces"] == "plane"


def test_offset_face_against_a_curved_face_is_rejected_as_non_planar():
    part = _create_part()
    sketch_feature = _create_circle_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])

    # A cylinder's 3 faces are top (planar), bottom (planar), side (curved) -
    # find the curved one by trying every index and expecting exactly one
    # non_planar_reference rejection among successes.
    results = [_create_offset_face_plane(part["id"], body_id, i, offset=1.0) for i in range(3)]
    statuses = [r.status_code for r in results]
    assert 201 in statuses, "expected at least one planar face (top/bottom cap)"
    assert 422 in statuses, "expected at least one curved face rejected as non-planar"
    rejected = next(r for r in results if r.status_code == 422)
    assert rejected.json()["detail"]["type"] == "non_planar_reference"


def test_offset_face_against_an_unknown_body_is_a_missing_reference():
    part = _create_part()
    response = _create_offset_face_plane(part["id"], "no-such-body", 0, offset=1.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


def test_offset_face_payload_missing_offset_is_rejected():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])

    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_ref": {"body_id": body_id, "shape_type": "face", "index": 0},
        },
    )
    assert response.status_code == 422


# --- NORMAL_TO_LINE_AT_POINT --------------------------------------------------


def test_normal_to_line_at_point_against_a_real_line_endpoint_succeeds():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    p0 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()
    p1 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10.0, "y": 0.0}).json()
    line = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": p0["id"], "end_point_id": p1["id"]},
    ).json()

    response = _create_normal_to_line_plane(part["id"], sketch_id, line["id"], p0["id"])
    assert response.status_code == 201
    body = response.json()
    assert body["plane_type"] == "normal_to_line_at_point"
    assert body["origin"] == pytest.approx([0.0, 0.0, 0.0])
    assert body["normal"] == pytest.approx([1.0, 0.0, 0.0])


def test_normal_to_line_at_point_rejects_a_point_that_is_not_the_lines_endpoint():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    p0 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()
    p1 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10.0, "y": 0.0}).json()
    off_line = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 5.0, "y": 5.0}).json()
    line = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": p0["id"], "end_point_id": p1["id"]},
    ).json()

    response = _create_normal_to_line_plane(part["id"], sketch_id, line["id"], off_line["id"])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "point_not_on_line"


def test_normal_to_line_at_point_against_an_unknown_line_is_a_missing_reference():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    p0 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()

    response = _create_normal_to_line_plane(part["id"], sketch_id, "no-such-line", p0["id"])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


# --- Editing, listing, cascade-delete -----------------------------------------


def test_patch_updates_offset_and_the_response_reflects_the_new_origin():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])
    created = None
    for index in range(6):
        response = _create_offset_face_plane(part["id"], body_id, index, offset=5.0)
        if response.status_code == 201:
            created = response.json()
            break
    assert created is not None

    patch_response = client.patch(
        f"/document/parts/{part['id']}/create-plane-features/{created['id']}",
        json={"offset": 20.0},
    )
    assert patch_response.status_code == 200
    updated = patch_response.json()
    assert updated["offset"] == 20.0
    assert updated["origin"] != created["origin"]


def test_patch_is_never_locked_even_when_a_later_feature_exists():
    """C2's own explicit instruction: never add, and then need to remove, an
    'editable only if last' lock - this Feature type is unlocked from the
    start, same as B4 already established generically for Extrude/Sketch."""
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])
    created = None
    for index in range(6):
        response = _create_offset_face_plane(part["id"], body_id, index, offset=5.0)
        if response.status_code == 201:
            created = response.json()
            break
    assert created is not None

    # A later Feature now exists (nothing needs to reference the Plane -
    # any subsequent Feature at all makes this Plane "not the last one").
    another_sketch = _create_sketch_feature(part["id"], plane="XZ")

    patch_response = client.patch(
        f"/document/parts/{part['id']}/create-plane-features/{created['id']}",
        json={"offset": 1.0},
    )
    assert patch_response.status_code == 200


def test_list_features_includes_create_plane_feature_with_resolved_geometry():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])
    created = None
    for index in range(6):
        response = _create_offset_face_plane(part["id"], body_id, index, offset=5.0)
        if response.status_code == 201:
            created = response.json()
            break
    assert created is not None

    features = client.get(f"/document/parts/{part['id']}/features").json()
    plane_entries = [f for f in features if f["type"] == "create_plane"]
    assert len(plane_entries) == 1
    assert plane_entries[0]["origin"] is not None


def test_cascade_deleting_the_extrude_takes_its_offset_face_plane_with_it():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])
    created = None
    for index in range(6):
        response = _create_offset_face_plane(part["id"], body_id, index, offset=5.0)
        if response.status_code == 201:
            created = response.json()
            break
    assert created is not None

    cascade_response = client.delete(f"/document/parts/{part['id']}/features/{extrude['id']}/cascade")
    assert cascade_response.status_code == 200
    deleted_ids = cascade_response.json()["deleted_feature_ids"]
    assert extrude["id"] in deleted_ids
    assert created["id"] in deleted_ids

    features = client.get(f"/document/parts/{part['id']}/features").json()
    assert all(f["id"] != created["id"] for f in features)
