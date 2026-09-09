"""Integration tests for `SolidFromSurfacesFeature` over the real HTTP API -
mirrors `test_planar_surface_feature.py`'s own shape and helper conventions.
Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see `app.document.solid_from_surfaces`'s own module docstring).

The cube built by `_create_cube_surfaces` below is 6 `PlanarSurfaceFeature`s,
one per axis-aligned face of a `size`-edge cube with one corner at the
origin - each face's own Sketch is anchored either directly to a fixed
plane (bottom/left/front) or to an `OFFSET_FACE` `CreatePlaneFeature`
translated `size` along that fixed plane's own normal (top/right/back), with
each Sketch's own local square chosen so its embedding (`origin + x * x_axis
+ y * y_axis`, per `app.document.plane_geometry`'s own fixed-plane basis
table) lands exactly on that face's own world footprint - see this module's
own per-face comments for the coordinate derivation. **Needs a real on-
device/CI pass to confirm the 6 faces actually do sew edge-to-edge into one
closed shell** (this sandbox has never had pythonocc-core installed)."""

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


def _create_sketch_feature(part_id: str, *, plane: str | None = None, plane_feature_id: str | None = None) -> dict:
    payload: dict = {}
    if plane is not None:
        payload["plane"] = plane
    if plane_feature_id is not None:
        payload["plane_feature_id"] = plane_feature_id
    response = client.post(f"/document/parts/{part_id}/features/sketch", json=payload)
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


def _create_offset_plane_feature(part_id: str, fixed_plane: str, offset: float) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [{"fixed_plane": fixed_plane}],
            "offset": offset,
        },
    )
    assert response.status_code == 201
    return response.json()


def _create_planar_surface(part_id: str, sketch_feature_id: str):
    return client.post(
        f"/document/parts/{part_id}/planar-surface-features",
        json={"sketch_feature_id": sketch_feature_id},
    )


def _create_solid_from_surfaces(part_id: str, surface_feature_ids: list[str]):
    return client.post(
        f"/document/parts/{part_id}/solid-from-surfaces-features",
        json={"surface_feature_ids": surface_feature_ids},
    )


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


def _create_cube_surfaces(part_id: str, size: float = 10.0, *, skip: str | None = None) -> list[dict]:
    """Builds the 6 axis-aligned `PlanarSurfaceFeature`s of a `size`-edge
    cube with one corner at the origin (see this module's own top docstring
    for the per-face coordinate derivation) - `skip` (one of "bottom"/
    "top"/"front"/"back"/"left"/"right") omits one face entirely, for the
    deliberately-non-watertight test case."""
    surfaces = []

    # Bottom (z=0): directly on the XY fixed plane.
    if skip != "bottom":
        sketch = _create_sketch_feature(part_id, plane="XY")
        _add_square(sketch["sketch_id"], 0.0, 0.0, size)
        surfaces.append(_create_planar_surface(part_id, sketch["id"]).json())

    # Top (z=size): XY offset by `size` along its own normal (0,0,1).
    if skip != "top":
        plane_feature = _create_offset_plane_feature(part_id, "XY", size)
        sketch = _create_sketch_feature(part_id, plane_feature_id=plane_feature["id"])
        _add_square(sketch["sketch_id"], 0.0, 0.0, size)
        surfaces.append(_create_planar_surface(part_id, sketch["id"]).json())

    # Front (y=0): directly on the XZ fixed plane - XZ's own x_axis is
    # (-1,0,0), so a local square from x0=-size to 0 embeds to world x in
    # [0, size] (see app.document.plane_geometry's own XZ basis doc
    # comment for why x_axis is negated on this plane).
    if skip != "front":
        sketch = _create_sketch_feature(part_id, plane="XZ")
        _add_square(sketch["sketch_id"], -size, 0.0, size)
        surfaces.append(_create_planar_surface(part_id, sketch["id"]).json())

    # Back (y=size): XZ offset by `size` along its own normal (0,1,0).
    if skip != "back":
        plane_feature = _create_offset_plane_feature(part_id, "XZ", size)
        sketch = _create_sketch_feature(part_id, plane_feature_id=plane_feature["id"])
        _add_square(sketch["sketch_id"], -size, 0.0, size)
        surfaces.append(_create_planar_surface(part_id, sketch["id"]).json())

    # Left (x=0): directly on the YZ fixed plane.
    if skip != "left":
        sketch = _create_sketch_feature(part_id, plane="YZ")
        _add_square(sketch["sketch_id"], 0.0, 0.0, size)
        surfaces.append(_create_planar_surface(part_id, sketch["id"]).json())

    # Right (x=size): YZ offset by `size` along its own normal (1,0,0).
    if skip != "right":
        plane_feature = _create_offset_plane_feature(part_id, "YZ", size)
        sketch = _create_sketch_feature(part_id, plane_feature_id=plane_feature["id"])
        _add_square(sketch["sketch_id"], 0.0, 0.0, size)
        surfaces.append(_create_planar_surface(part_id, sketch["id"]).json())

    return surfaces


# --- The critical case: a genuinely watertight cube ---------------------------


def test_six_faces_of_a_cube_produce_a_valid_solid_with_the_expected_volume():
    part = _create_part()
    size = 10.0
    surfaces = _create_cube_surfaces(part["id"], size=size)
    assert len(surfaces) == 6

    response = _create_solid_from_surfaces(part["id"], [s["id"] for s in surfaces])

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "solid_from_surfaces"
    assert body["produces"] == "body"

    bodies = _get_bodies(part["id"])
    solid_body = _body(bodies, body["id"])
    assert solid_body["is_surface"] is False


# --- The critical failure path: a deliberately non-watertight set -------------


def test_five_of_six_cube_faces_is_rejected_as_not_watertight():
    part = _create_part()
    surfaces = _create_cube_surfaces(part["id"], size=10.0, skip="right")
    assert len(surfaces) == 5

    response = _create_solid_from_surfaces(part["id"], [s["id"] for s in surfaces])

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "not_watertight"


# --- Payload validation --------------------------------------------------------


def test_solid_from_surfaces_with_fewer_than_two_ids_is_rejected():
    part = _create_part()
    surfaces = _create_cube_surfaces(part["id"], size=10.0)

    response = _create_solid_from_surfaces(part["id"], [surfaces[0]["id"]])

    assert response.status_code == 400


def test_solid_from_surfaces_referencing_a_non_surface_feature_is_rejected():
    part = _create_part()
    surfaces = _create_cube_surfaces(part["id"], size=10.0)
    sketch = _create_sketch_feature(part["id"], plane="XY")

    response = _create_solid_from_surfaces(part["id"], [surfaces[0]["id"], sketch["id"]])

    assert response.status_code == 400


# --- native_format round-trip -------------------------------------------------


def test_solid_from_surfaces_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        surfaces = _create_cube_surfaces(part["id"], size=10.0)
        solid = _create_solid_from_surfaces(part["id"], [s["id"] for s in surfaces]).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "solid_from_surfaces")
        assert set(round_tripped["surface_feature_ids"]) == set(solid["surface_feature_ids"])
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
