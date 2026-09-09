"""Integration tests for `ThickenFeature` over the real HTTP API - mirrors
`test_planar_surface_feature.py`'s own shape and helper conventions (copy-
pasted, not shared via conftest, same as every other test_stage*.py file).
Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see `app.document.thicken`'s own module docstring).

A `ThickenFeature` resolves eagerly at create/update time (same "always
raise, never return None" contract `LoftFeature` follows) - there is no
lazy-tolerant path to test the way `SurfaceFeature` itself has."""

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


def _create_planar_surface(part_id: str, sketch_feature_id: str) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/planar-surface-features",
        json={"sketch_feature_id": sketch_feature_id},
    )
    assert response.status_code == 201
    return response.json()


def _create_thicken(part_id: str, surface_feature_id: str, thickness: float):
    return client.post(
        f"/document/parts/{part_id}/thicken-features",
        json={"surface_feature_id": surface_feature_id, "thickness": thickness},
    )


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


# --- Creation validation -------------------------------------------------------


def test_create_thicken_on_a_planar_surface_succeeds():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"])

    response = _create_thicken(part["id"], surface["id"], 2.0)

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "thicken"
    assert body["produces"] == "body"
    assert body["surface_feature_id"] == surface["id"]
    assert body["thickness"] == 2.0


def test_create_thicken_with_negative_thickness_succeeds():
    """Sign is meaningful (which side of the shell material is added to) -
    not rejected the way zero is."""
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"])

    response = _create_thicken(part["id"], surface["id"], -2.0)

    assert response.status_code == 201
    assert response.json()["thickness"] == -2.0


def test_create_thicken_with_zero_thickness_is_rejected():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"])

    response = _create_thicken(part["id"], surface["id"], 0.0)

    assert response.status_code == 400


def test_create_thicken_with_invalid_surface_feature_id_is_rejected():
    part = _create_part()

    response = _create_thicken(part["id"], "not-a-real-feature-id", 2.0)

    assert response.status_code == 400


def test_create_thicken_referencing_a_non_surface_feature_is_rejected():
    """`surface_feature_id` must produce a Surface - a SketchFeature (which
    produces `Produces.SKETCH`) is a real Feature id but the wrong kind."""
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])

    response = _create_thicken(part["id"], sketch["id"], 2.0)

    assert response.status_code == 400


def test_create_thicken_referencing_a_deleted_surface_feature_is_rejected():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"])
    delete_response = client.delete(f"/document/parts/{part['id']}/features/{surface['id']}/cascade")
    assert delete_response.status_code == 200

    response = _create_thicken(part["id"], surface["id"], 2.0)

    assert response.status_code == 400


# --- Geometry --------------------------------------------------------------


def test_thicken_produces_a_solid_body_in_the_mesh_response():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"])
    thicken = _create_thicken(part["id"], surface["id"], 2.0).json()

    bodies = _get_bodies(part["id"])
    thicken_body = _body(bodies, thicken["id"])
    assert thicken_body["is_surface"] is False


# --- Update ------------------------------------------------------------------


def test_update_thicken_feature_thickness():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"])
    thicken = _create_thicken(part["id"], surface["id"], 2.0).json()

    response = client.patch(
        f"/document/parts/{part['id']}/thicken-features/{thicken['id']}",
        json={"thickness": 3.5},
    )

    assert response.status_code == 200
    assert response.json()["thickness"] == 3.5


def test_update_thicken_feature_with_zero_thickness_is_rejected():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"])
    thicken = _create_thicken(part["id"], surface["id"], 2.0).json()

    response = client.patch(
        f"/document/parts/{part['id']}/thicken-features/{thicken['id']}",
        json={"thickness": 0.0},
    )

    assert response.status_code == 400


# --- native_format round-trip -------------------------------------------------


def test_thicken_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        sketch = _create_square_sketch_feature(part["id"])
        surface = _create_planar_surface(part["id"], sketch["id"])
        thicken = _create_thicken(part["id"], surface["id"], 2.0).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "thicken")
        assert round_tripped["surface_feature_id"] == thicken["surface_feature_id"]
        assert round_tripped["thickness"] == thicken["thickness"]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_the_backing_surface_feature_cascade_deletes_the_thicken_feature():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"])
    thicken = _create_thicken(part["id"], surface["id"], 2.0).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{surface['id']}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {surface["id"], thicken["id"]}
