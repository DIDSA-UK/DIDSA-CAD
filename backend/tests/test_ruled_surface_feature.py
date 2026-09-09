"""Integration tests for `RuledSurfaceFeature` over the real HTTP API -
mirrors `test_loft_surface_feature.py`'s own helper conventions, since
`RuledSurfaceFeature` is a thin delegating wrapper around Loft Surface's own
construction (see `app.document.ruled_surface`'s own module docstring).
Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox)."""

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


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201
    return response.json()


def _add_polygon(sketch_id: str, points: list[tuple[float, float]]) -> list[dict]:
    corners = [_add_point(sketch_id, x, y) for x, y in points]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])
    return corners


def _square_sketch(part_id: str, *, plane: str = "XY", size: float = 10.0) -> dict:
    feature = _create_sketch_feature(part_id, plane)
    h = size / 2
    _add_polygon(feature["sketch_id"], [(-h, -h), (h, -h), (h, h), (-h, h)])
    return feature


def _move_sketch_feature_up(part_id: str, height: float) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [{"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}],
            "offset": height,
        },
    )
    assert response.status_code == 201, response.json()
    return response.json()


def _section(sketch_feature: dict) -> dict:
    return {"sketch_feature_id": sketch_feature["id"]}


def _create_ruled_surface(part_id: str, sections: list[dict]) -> dict:
    return client.post(f"/document/parts/{part_id}/ruled-surface-features", json={"sections": sections})


def _create_loft_surface(part_id: str, sections: list[dict], **overrides) -> dict:
    payload = {"sections": sections}
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/loft-surface-features", json=payload)


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


def _two_square_sections(part_id: str) -> tuple[dict, dict]:
    bottom = _square_sketch(part_id, size=10.0)
    plane = _move_sketch_feature_up(part_id, 10.0)
    top = client.post(
        f"/document/parts/{part_id}/features/sketch", json={"plane_feature_id": plane["id"]}
    ).json()
    _add_polygon(top["sketch_id"], [(-3, -3), (3, -3), (3, 3), (-3, 3)])
    return bottom, top


# --- Creation validation -------------------------------------------------------


def test_create_ruled_surface_feature_between_two_closed_squares_succeeds():
    part = _create_part()
    bottom, top = _two_square_sections(part["id"])

    response = _create_ruled_surface(part["id"], [_section(bottom), _section(top)])

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "ruled_surface"
    assert body["produces"] == "surface"
    assert len(body["sections"]) == 2
    # RuledSurfaceSectionSchema exposes only sketch_feature_id/profile_refs/
    # edge_ref - no reference_point/alignment_point in the response shape at all.
    assert set(body["sections"][0].keys()) == {"sketch_feature_id", "profile_refs", "edge_ref"}


def test_create_ruled_surface_feature_with_1_section_is_rejected():
    part = _create_part()
    bottom = _square_sketch(part["id"])

    response = _create_ruled_surface(part["id"], [_section(bottom)])

    assert response.status_code == 422
    assert response.json()["detail"] == "RuledSurfaceFeature requires exactly 2 sections"


def test_create_ruled_surface_feature_with_3_sections_is_rejected():
    """Unlike Loft Surface's own "2+" rule, Ruled Surface requires exactly
    2 - its whole point is the narrower, exactly-2-pick UX."""
    part = _create_part()
    bottom, top = _two_square_sections(part["id"])
    plane = _move_sketch_feature_up(part["id"], 20.0)
    third = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    ).json()
    _add_polygon(third["sketch_id"], [(-1, -1), (1, -1), (1, 1), (-1, 1)])

    response = _create_ruled_surface(part["id"], [_section(bottom), _section(top), _section(third)])

    assert response.status_code == 422


# --- Geometric equivalence against Loft Surface -------------------------------


def test_ruled_surface_produces_the_same_shape_as_an_equivalent_loft_surface():
    """At exactly 2 sections, `ruled=True` vs `False` is geometrically
    identical (per `LoftFeature`'s own docstring) - confirms the delegation
    to `app.document.loft_surface` actually produces the same shape a
    directly-created, `ruled=True` Loft Surface would."""
    part_a = _create_part("Ruled")
    bottom_a, top_a = _two_square_sections(part_a["id"])
    ruled = _create_ruled_surface(part_a["id"], [_section(bottom_a), _section(top_a)]).json()

    part_b = _create_part("Loft")
    bottom_b, top_b = _two_square_sections(part_b["id"])
    loft = _create_loft_surface(part_b["id"], [_section(bottom_b), _section(top_b)], ruled=True).json()

    ruled_body = _body(_get_bodies(part_a["id"]), ruled["id"])
    loft_body = _body(_get_bodies(part_b["id"]), loft["id"])

    ruled_vertices = sorted(tuple(round(c, 6) for c in v) for v in ruled_body["mesh"]["vertices"])
    loft_vertices = sorted(tuple(round(c, 6) for c in v) for v in loft_body["mesh"]["vertices"])
    assert ruled_vertices == loft_vertices


# --- native_format round-trip -------------------------------------------------


def test_ruled_surface_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        bottom, top = _two_square_sections(part["id"])
        surface = _create_ruled_surface(part["id"], [_section(bottom), _section(top)]).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200
        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "ruled_surface")
        assert len(round_tripped["sections"]) == 2
        assert round_tripped["sections"][0]["sketch_feature_id"] == surface["sections"][0]["sketch_feature_id"]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
