"""Integration tests for `OffsetSurfaceFeature` over the real HTTP API -
mirrors `test_planar_surface_feature.py`'s own shape and helper conventions.
Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see `app.document.offset_surface`'s own module docstring)."""

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


def _create_extrude_feature(part_id: str, sketch_feature_id: str, *, end_distance: float = 10.0) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": end_distance,
            "target_body_ids": [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _create_planar_surface(part_id: str, sketch_feature_id: str):
    return client.post(
        f"/document/parts/{part_id}/planar-surface-features",
        json={"sketch_feature_id": sketch_feature_id},
    )


def _create_offset_surface(part_id: str, source: dict, distance: float):
    return client.post(
        f"/document/parts/{part_id}/offset-surface-features",
        json={"source": source, "distance": distance},
    )


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


# --- From a Body face ----------------------------------------------------------


def test_offset_surface_from_a_body_face_succeeds():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    box = _create_extrude_feature(part["id"], sketch["id"])

    source = {"face_ref": {"body_id": box["id"], "shape_type": "face", "index": 0}}
    response = _create_offset_surface(part["id"], source, 2.0)

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "offset_surface"
    assert body["produces"] == "surface"
    assert body["distance"] == 2.0


def test_offset_surface_from_a_face_of_a_missing_body_is_rejected():
    part = _create_part()

    source = {"face_ref": {"body_id": "not-a-real-body", "shape_type": "face", "index": 0}}
    response = _create_offset_surface(part["id"], source, 2.0)

    assert response.status_code in (400, 422)


# --- From an existing single-shell surface Feature -----------------------------


def test_offset_surface_from_an_existing_surface_feature_succeeds():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"]).json()

    source = {"surface_feature_id": surface["id"]}
    response = _create_offset_surface(part["id"], source, 2.0)

    assert response.status_code == 201
    assert response.json()["source"]["surface_feature_id"] == surface["id"]


def test_offset_surface_from_a_non_surface_feature_is_rejected():
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])

    source = {"surface_feature_id": sketch["id"]}
    response = _create_offset_surface(part["id"], source, 2.0)

    assert response.status_code == 400


def test_offset_surface_from_a_compound_of_shells_source_is_rejected():
    """v1 scope: a MultiProfile PlanarSurfaceFeature result (a Compound of
    disjoint Faces, not a single Shell) is ambiguous per-shell for this
    tool - rejected outright."""
    part = _create_part()
    feature = _create_sketch_feature(part["id"])
    _add_square(feature["sketch_id"], 0.0, 0.0, 5.0)
    _add_square(feature["sketch_id"], 100.0, 0.0, 5.0)
    surface = _create_planar_surface(part["id"], feature["id"]).json()

    source = {"surface_feature_id": surface["id"]}
    response = _create_offset_surface(part["id"], source, 2.0)

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_offset_source"


# --- Payload validation --------------------------------------------------------


def test_offset_surface_with_both_source_kinds_is_rejected():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"]).json()
    box_sketch = _create_square_sketch_feature(part["id"], x0=100.0)
    box = _create_extrude_feature(part["id"], box_sketch["id"])

    source = {
        "face_ref": {"body_id": box["id"], "shape_type": "face", "index": 0},
        "surface_feature_id": surface["id"],
    }
    response = _create_offset_surface(part["id"], source, 2.0)

    assert response.status_code == 422


def test_offset_surface_with_neither_source_kind_is_rejected():
    part = _create_part()

    response = _create_offset_surface(part["id"], {}, 2.0)

    assert response.status_code == 422


def test_offset_surface_with_zero_distance_is_rejected():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"]).json()

    source = {"surface_feature_id": surface["id"]}
    response = _create_offset_surface(part["id"], source, 0.0)

    assert response.status_code == 422


# --- Geometry --------------------------------------------------------------


def test_offset_surface_produces_a_surface_body_in_the_mesh_response():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"]).json()
    source = {"surface_feature_id": surface["id"]}
    offset = _create_offset_surface(part["id"], source, 2.0).json()

    bodies = _get_bodies(part["id"])
    offset_body = _body(bodies, offset["id"])
    assert offset_body["is_surface"] is True


# --- Update ------------------------------------------------------------------


def test_update_offset_surface_feature_distance():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"]).json()
    source = {"surface_feature_id": surface["id"]}
    offset = _create_offset_surface(part["id"], source, 2.0).json()

    response = client.patch(
        f"/document/parts/{part['id']}/offset-surface-features/{offset['id']}",
        json={"distance": 3.5},
    )

    assert response.status_code == 200
    assert response.json()["distance"] == 3.5


# --- native_format round-trip -------------------------------------------------


def test_offset_surface_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        sketch = _create_square_sketch_feature(part["id"])
        surface = _create_planar_surface(part["id"], sketch["id"]).json()
        source = {"surface_feature_id": surface["id"]}
        _create_offset_surface(part["id"], source, 2.0)

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "offset_surface")
        assert round_tripped["source"]["surface_feature_id"] == surface["id"]
        assert round_tripped["distance"] == 2.0
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
