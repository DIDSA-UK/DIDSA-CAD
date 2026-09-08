"""Integration tests for `KnitSurfaceFeature` over the real HTTP API -
mirrors `test_planar_surface_feature.py`'s own shape and helper conventions.
Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see `app.document.knit_surface`'s own module docstring)."""

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


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_planar_surface(part_id: str, sketch_feature_id: str):
    return client.post(
        f"/document/parts/{part_id}/planar-surface-features",
        json={"sketch_feature_id": sketch_feature_id},
    )


def _create_knit_surface(part_id: str, surface_feature_ids: list[str]):
    return client.post(
        f"/document/parts/{part_id}/knit-surface-features",
        json={"surface_feature_ids": surface_feature_ids},
    )


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


def _create_two_adjacent_squares(part_id: str, size: float = 10.0) -> list[dict]:
    """Two coplanar, edge-adjacent unit squares on the XY plane (x in
    [0, size] and x in [size, 2*size], both y in [0, size]) - the minimal
    "these two surfaces are actually touching" case, same shape `test_
    surface_ops.py`'s own OCCT-level unit test uses."""
    sketch_a = _create_square_sketch_feature(part_id, x0=0.0, y0=0.0, size=size)
    sketch_b = _create_square_sketch_feature(part_id, x0=size, y0=0.0, size=size)
    surface_a = _create_planar_surface(part_id, sketch_a["id"]).json()
    surface_b = _create_planar_surface(part_id, sketch_b["id"]).json()
    return [surface_a, surface_b]


# --- Creation validation -------------------------------------------------------


def test_knitting_two_adjacent_surfaces_succeeds():
    part = _create_part()
    surfaces = _create_two_adjacent_squares(part["id"])

    response = _create_knit_surface(part["id"], [s["id"] for s in surfaces])

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "knit_surface"
    assert body["produces"] == "surface"
    assert body["surface_feature_ids"] == [s["id"] for s in surfaces]


def test_knit_surface_with_fewer_than_two_ids_is_rejected():
    part = _create_part()
    surfaces = _create_two_adjacent_squares(part["id"])

    response = _create_knit_surface(part["id"], [surfaces[0]["id"]])

    assert response.status_code == 400


def test_knit_surface_referencing_a_non_surface_feature_is_rejected():
    part = _create_part()
    surfaces = _create_two_adjacent_squares(part["id"])
    sketch = _create_sketch_feature(part["id"])

    response = _create_knit_surface(part["id"], [surfaces[0]["id"], sketch["id"]])

    assert response.status_code == 400


def test_knit_surface_with_invalid_surface_feature_id_is_rejected():
    part = _create_part()
    surfaces = _create_two_adjacent_squares(part["id"])

    response = _create_knit_surface(part["id"], [surfaces[0]["id"], "not-a-real-feature-id"])

    assert response.status_code == 400


# --- Geometry --------------------------------------------------------------


def test_knit_surface_produces_a_surface_body_in_the_mesh_response():
    part = _create_part()
    surfaces = _create_two_adjacent_squares(part["id"])
    knit = _create_knit_surface(part["id"], [s["id"] for s in surfaces]).json()

    bodies = _get_bodies(part["id"])
    knit_body = _body(bodies, knit["id"])
    assert knit_body["is_surface"] is True


# --- Update ------------------------------------------------------------------


def test_update_knit_surface_feature_surface_feature_ids():
    part = _create_part()
    surfaces = _create_two_adjacent_squares(part["id"])
    extra_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=10.0, size=10.0)
    extra_surface = _create_planar_surface(part["id"], extra_sketch["id"]).json()
    knit = _create_knit_surface(part["id"], [surfaces[0]["id"], surfaces[1]["id"]]).json()

    response = client.patch(
        f"/document/parts/{part['id']}/knit-surface-features/{knit['id']}",
        json={"surface_feature_ids": [surfaces[0]["id"], extra_surface["id"]]},
    )

    assert response.status_code == 200
    assert response.json()["surface_feature_ids"] == [surfaces[0]["id"], extra_surface["id"]]


# --- native_format round-trip -------------------------------------------------


def test_knit_surface_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        surfaces = _create_two_adjacent_squares(part["id"])
        knit = _create_knit_surface(part["id"], [s["id"] for s in surfaces]).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "knit_surface")
        assert round_tripped["surface_feature_ids"] == knit["surface_feature_ids"]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
