"""Integration tests for `LoftSurfaceFeature` over the real HTTP API -
mirrors `test_loft_feature.py`'s own section/sketch helper conventions.
Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see `app.document.loft_surface`'s own module docstring)."""

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


def _add_open_chain(sketch_id: str, points: list[tuple[float, float]]) -> list[dict]:
    corners = [_add_point(sketch_id, x, y) for x, y in points]
    for a, b in zip(corners, corners[1:]):
        _add_line(sketch_id, a["id"], b["id"])
    return corners


def _square_sketch(part_id: str, *, plane: str = "XY", size: float = 10.0) -> dict:
    feature = _create_sketch_feature(part_id, plane)
    h = size / 2
    _add_polygon(feature["sketch_id"], [(-h, -h), (h, -h), (h, h), (-h, h)])
    return feature


def _move_sketch_feature_up(part_id: str, height: float) -> dict:
    """A `CreatePlaneFeature` (`OFFSET_FACE` from the fixed XY plane), the
    standard way this codebase puts a second Sketch at a real 3D height
    above another - see `test_loft_feature.py`'s own identical helper."""
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


# --- Creation validation -------------------------------------------------------


def test_create_loft_surface_feature_between_two_closed_squares_succeeds():
    part = _create_part()
    bottom = _square_sketch(part["id"], size=10.0)
    plane = _move_sketch_feature_up(part["id"], 10.0)
    top_feature = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    ).json()
    _add_polygon(top_feature["sketch_id"], [(-3, -3), (3, -3), (3, 3), (-3, 3)])

    response = _create_loft_surface(part["id"], [_section(bottom), _section(top_feature)])

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "loft_surface"
    assert body["produces"] == "surface"
    assert body["warnings"] == []


def test_create_loft_surface_feature_between_two_open_chains_succeeds():
    """Unlike LoftFeature (which needs an explicit `thickness` to switch to
    the open-chain path), Loft Surface's own dispatcher probes: falls back
    to open-chain resolution automatically once any section fails as a
    closed profile."""
    part = _create_part()
    bottom = _create_sketch_feature(part["id"])
    _add_open_chain(bottom["sketch_id"], [(-5, -5), (5, -5), (5, 5)])
    plane = _move_sketch_feature_up(part["id"], 10.0)
    top = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    ).json()
    _add_open_chain(top["sketch_id"], [(-3, -3), (3, -3), (3, 3)])

    response = _create_loft_surface(part["id"], [_section(bottom), _section(top)])

    assert response.status_code == 201


def test_create_loft_surface_feature_with_fewer_than_2_sections_is_rejected():
    part = _create_part()
    bottom = _square_sketch(part["id"])

    response = _create_loft_surface(part["id"], [_section(bottom)])

    assert response.status_code == 422


def test_create_loft_surface_feature_with_a_hollow_section_is_rejected():
    part = _create_part()
    bottom = _create_sketch_feature(part["id"])
    _add_polygon(bottom["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])
    _add_polygon(bottom["sketch_id"], [(-2, -2), (2, -2), (2, 2), (-2, 2)])
    plane = _move_sketch_feature_up(part["id"], 10.0)
    top = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    ).json()
    _add_polygon(top["sketch_id"], [(-3, -3), (3, -3), (3, 3), (-3, 3)])

    response = _create_loft_surface(part["id"], [_section(bottom), _section(top)])

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_loft_surface_section"


# --- Geometry --------------------------------------------------------------


def test_loft_surface_produces_a_shell_body_in_the_mesh_response():
    part = _create_part()
    bottom = _square_sketch(part["id"], size=10.0)
    plane = _move_sketch_feature_up(part["id"], 10.0)
    top = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    ).json()
    _add_polygon(top["sketch_id"], [(-3, -3), (3, -3), (3, 3), (-3, 3)])

    surface = _create_loft_surface(part["id"], [_section(bottom), _section(top)]).json()

    bodies = _get_bodies(part["id"])
    surface_body = _body(bodies, surface["id"])
    assert surface_body["is_surface"] is True
    assert len(surface_body["mesh"]["vertices"]) > 0


# --- native_format round-trip -------------------------------------------------


def test_loft_surface_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        bottom = _square_sketch(part["id"])
        plane = _move_sketch_feature_up(part["id"], 10.0)
        top = client.post(
            f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
        ).json()
        _add_polygon(top["sketch_id"], [(-3, -3), (3, -3), (3, 3), (-3, 3)])
        surface = _create_loft_surface(
            part["id"], [_section(bottom), _section(top)], ruled=True
        ).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200
        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "loft_surface")
        assert round_tripped["ruled"] is True
        assert len(round_tripped["sections"]) == 2
        assert round_tripped["sections"][0]["sketch_feature_id"] == surface["sections"][0]["sketch_feature_id"]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
