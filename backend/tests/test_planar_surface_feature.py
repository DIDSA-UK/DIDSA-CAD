"""Integration tests for `PlanarSurfaceFeature` over the real HTTP API -
mirrors `test_surface.py`'s own shape and helper conventions (copy-pasted,
not shared via conftest, same as every other test_stage*.py file). Needs a
real pythonocc-core environment (not available in this repo's own dev
sandbox - see `app.document.planar_surface`'s own module docstring and
`docs/status.md`'s dated entries for whether a real on-device/CI pass has
actually run by the time this is read).

Unlike `SurfaceFeature`, a `PlanarSurfaceFeature` requires a genuinely
closed profile at create/update time (no open-chain fallback) and resolves
eagerly - see that class's own docstring."""

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


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> list[dict]:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    lines = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        lines.append(_add_line(sketch_id, a["id"], b["id"]))
    return lines


def _add_open_chain(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        _add_point(sketch_id, x, y) for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:]):
        _add_line(sketch_id, a["id"], b["id"])


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_planar_surface(part_id: str, sketch_feature_id: str, *, profile_refs: list[dict] | None = None):
    payload = {"sketch_feature_id": sketch_feature_id}
    if profile_refs is not None:
        payload["profile_refs"] = profile_refs
    return client.post(f"/document/parts/{part_id}/planar-surface-features", json=payload)


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


# --- Creation validation -------------------------------------------------------


def test_create_planar_surface_feature_on_a_closed_square_profile_succeeds():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])

    response = _create_planar_surface(part["id"], sketch["id"])

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "planar_surface"
    assert body["produces"] == "surface"
    assert body["sketch_feature_id"] == sketch["id"]
    assert body["locked"] is False


def test_create_planar_surface_feature_on_an_open_chain_is_rejected():
    """Unlike SurfaceFeature/RevolveSurfaceFeature, there is no open-chain
    fallback - a genuinely closed profile is required up front."""
    part = _create_part()
    feature = _create_sketch_feature(part["id"])
    _add_open_chain(feature["sketch_id"], 0.0, 0.0, 10.0)

    response = _create_planar_surface(part["id"], feature["id"])

    assert response.status_code == 400


def test_create_planar_surface_feature_with_sketch_feature_id_not_in_part_is_rejected():
    part = _create_part()

    response = _create_planar_surface(part["id"], "not-a-real-feature-id")

    assert response.status_code == 400


# --- Geometry --------------------------------------------------------------


def test_planar_surface_produces_a_flat_body_in_the_mesh_response():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0, size=10.0)

    surface = _create_planar_surface(part["id"], sketch["id"]).json()

    bodies = _get_bodies(part["id"])
    surface_body = _body(bodies, surface["id"])
    assert surface_body["source"] == "computed"
    assert surface_body["is_surface"] is True
    vertices = surface_body["mesh"]["vertices"]
    zs = [v[2] for v in vertices]
    # A flat face straight from the XY-plane square - every vertex sits at
    # z=0, unlike an extruded/prismed solid which would span a real depth.
    assert all(z == 0.0 for z in zs)


def test_planar_surface_only_part_returns_computed_geometry_not_placeholder():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"]).json()

    bodies = _get_bodies(part["id"])

    assert len(bodies) == 1
    assert bodies[0]["body_id"] == surface["id"]
    assert bodies[0]["is_surface"] is True


def test_planar_surface_with_profile_refs_selects_one_of_two_disjoint_squares():
    part = _create_part()
    feature = _create_sketch_feature(part["id"])
    lines_a = _add_square(feature["sketch_id"], 0.0, 0.0, 5.0)
    _add_square(feature["sketch_id"], 100.0, 0.0, 5.0)

    profile_ref = {"sketch_id": feature["sketch_id"], "entity_type": "line", "entity_id": lines_a[0]["id"]}
    response = _create_planar_surface(part["id"], feature["id"], profile_refs=[profile_ref])

    assert response.status_code == 201
    assert response.json()["profile_refs"] == [profile_ref]


# --- Update ------------------------------------------------------------------


def test_update_planar_surface_feature_profile_refs():
    part = _create_part()
    feature = _create_sketch_feature(part["id"])
    lines_a = _add_square(feature["sketch_id"], 0.0, 0.0, 5.0)
    lines_b = _add_square(feature["sketch_id"], 100.0, 0.0, 5.0)
    surface = _create_planar_surface(part["id"], feature["id"]).json()

    profile_ref = {"sketch_id": feature["sketch_id"], "entity_type": "line", "entity_id": lines_b[0]["id"]}
    response = client.patch(
        f"/document/parts/{part['id']}/planar-surface-features/{surface['id']}",
        json={"profile_refs": [profile_ref]},
    )

    assert response.status_code == 200
    assert response.json()["profile_refs"] == [profile_ref]


# --- native_format round-trip -------------------------------------------------


def test_planar_surface_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        sketch = _create_square_sketch_feature(part["id"])
        surface = _create_planar_surface(part["id"], sketch["id"]).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "planar_surface")
        assert round_tripped["sketch_feature_id"] == surface["sketch_feature_id"]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_the_backing_sketch_feature_cascade_deletes_the_planar_surface_feature():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])
    surface = _create_planar_surface(part["id"], sketch["id"]).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{sketch['id']}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {sketch["id"], surface["id"]}
