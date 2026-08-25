"""Integration tests for `SurfaceFeature` over the real HTTP API - mirrors
test_stage9_extrude.py's/test_stage_b2_cascade.py's own shape and helper
conventions (copy-pasted, not shared via conftest, same as every other
test_stage*.py file). Needs a real pythonocc-core environment (not
available in this repo's own dev sandbox - see `app.document.surface`'s own
module docstring and `docs/status.md`'s dated entries for whether a real
on-device/CI pass has actually run by the time this is read); the pure
dependency-graph half of this coverage (SurfaceFeature.direction_ref edges,
cascade-delete of the Sketch a Surface extrudes) has zero OCCT dependency
and lives in test_surface_graph.py instead, which does run for real in this
sandbox.

A `SurfaceFeature` never flips `Part.produces_solid_geometry` (see that
class's own docstring - `produces_solid_geometry` is always False, `produces`
is always SURFACE, not BODY), so every test below also creates one ordinary
Boss Extrude first - otherwise `GET /mesh` would just keep returning its
placeholder box and never actually compute/tessellate the Surface at all.
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
    """Draws a closed `size` x `size` square, bottom-left at (x0, y0)."""
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


def _add_open_chain(sketch_id: str, x0: float, y0: float, size: float) -> None:
    """Draws an *unclosed* 3-point, 2-line zig-zag - same footprint as
    `_add_square` minus its final closing edge, so the Sketch has no closed
    profile at all (`detect_profile` reports NO_LOOP), only a single open
    chain (`detect_open_chain` reports SINGLE_CHAIN) - the wire
    `SurfaceFeature`'s own open-wire path (`app.document.loft.
    wire_for_open_chain`) is meant to extrude."""
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_open_chain_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_open_chain(feature["sketch_id"], x0, y0, size)
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


def _create_surface_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    start_distance: float = 0.0,
    end_distance: float = 5.0,
    direction_ref: dict | None = None,
    profile_refs: list[dict] | None = None,
):
    payload = {
        "sketch_feature_id": sketch_feature_id,
        "start_distance": start_distance,
        "end_distance": end_distance,
    }
    if direction_ref is not None:
        payload["direction_ref"] = direction_ref
    if profile_refs is not None:
        payload["profile_refs"] = profile_refs
    return client.post(f"/document/parts/{part_id}/surface-features", json=payload)


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


def _vertex_bounds(body: dict) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    vertices = body["mesh"]["vertices"]
    xs, ys, zs = zip(*vertices)
    return (min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))


def _remaining_feature_ids(part_id: str) -> list[str]:
    return [f["id"] for f in client.get(f"/document/parts/{part_id}/features").json()]


# --- Creation validation -------------------------------------------------------


def test_create_surface_feature_on_a_closed_square_profile_succeeds():
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=0.0)

    response = _create_surface_feature(part["id"], surface_sketch["id"], end_distance=5.0)

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "surface"
    assert body["produces"] == "surface"
    assert body["sketch_feature_id"] == surface_sketch["id"]
    assert body["locked"] is False


def test_create_surface_feature_on_a_single_open_chain_succeeds():
    """Unlike `create_extrude_feature`, a Surface does not require its
    backing Sketch to already have a closed profile - a single open wire is
    also a valid `SurfaceFeature` source (see that class's own docstring)."""
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_open_chain_sketch_feature(part["id"], x0=100.0, y0=0.0)

    response = _create_surface_feature(part["id"], surface_sketch["id"], end_distance=5.0)

    assert response.status_code == 201
    assert response.json()["type"] == "surface"


def test_create_surface_feature_with_sketch_feature_id_not_in_part_is_rejected():
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], body_sketch["id"])

    response = _create_surface_feature(part["id"], "not-a-real-feature-id")

    assert response.status_code == 400


def test_create_surface_feature_with_end_distance_not_greater_than_start_distance_is_rejected():
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=0.0)

    response = _create_surface_feature(part["id"], surface_sketch["id"], start_distance=5.0, end_distance=5.0)

    # _validate_extrude_distances (reused as-is for Surface) raises 400, not
    # 422 - matches ExtrudeFeature's own identical validation.
    assert response.status_code == 400


def test_create_surface_feature_with_malformed_direction_ref_is_rejected():
    """`direction_ref` must have exactly one of edge_ref/sketch_line_ref/
    fixed_axis set - `_validate_surface_payload` reuses `_validate_pattern_
    direction_ref`'s identical structural check."""
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=0.0)

    response = _create_surface_feature(
        part["id"], surface_sketch["id"], direction_ref={"fixed_axis": "x", "sketch_line_ref": None}
    )
    assert response.status_code == 201  # exactly one set (fixed_axis) - valid

    response = _create_surface_feature(part["id"], surface_sketch["id"], direction_ref={})
    assert response.status_code == 422  # zero of the three set - invalid


# --- Geometry: open wire vs closed profile, direction default vs override ----


def test_surface_on_closed_profile_produces_a_body_in_the_mesh_response():
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=0.0, size=10.0)

    surface = _create_surface_feature(part["id"], surface_sketch["id"], end_distance=5.0).json()

    bodies = _get_bodies(part["id"])
    surface_body = _body(bodies, surface["id"])
    assert surface_body["source"] == "computed"
    (min_x, min_y, min_z), (max_x, max_y, max_z) = _vertex_bounds(surface_body)
    # The square's own footprint (x in [100, 110], y in [0, 10]) plus the
    # normal-to-XY extrusion span (z in [0, 5]).
    assert min_x == 100.0 and max_x == 110.0
    assert min_y == 0.0 and max_y == 10.0
    assert min_z == 0.0 and max_z == 5.0


def test_surface_on_open_chain_produces_a_body_in_the_mesh_response():
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_open_chain_sketch_feature(part["id"], x0=100.0, y0=0.0, size=10.0)

    surface = _create_surface_feature(part["id"], surface_sketch["id"], end_distance=5.0).json()

    bodies = _get_bodies(part["id"])
    surface_body = _body(bodies, surface["id"])
    assert surface_body["source"] == "computed"
    assert len(surface_body["mesh"]["vertices"]) > 0


def test_surface_direction_defaults_to_the_sketch_plane_normal():
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=0.0, size=10.0)

    surface = _create_surface_feature(part["id"], surface_sketch["id"], end_distance=8.0).json()

    bodies = _get_bodies(part["id"])
    (min_x, _min_y, min_z), (max_x, _max_y, max_z) = _vertex_bounds(_body(bodies, surface["id"]))
    # No direction_ref -> extrudes along the XY sketch plane's own normal
    # (world Z) - x stays within the flat sketch footprint, z spans the
    # full start/end distance.
    assert max_x - min_x == 10.0
    assert max_z - min_z == 8.0


def test_surface_direction_ref_overrides_the_sketch_plane_normal():
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=0.0, size=10.0)

    surface = _create_surface_feature(
        part["id"],
        surface_sketch["id"],
        end_distance=8.0,
        direction_ref={"fixed_axis": "x"},
    ).json()

    bodies = _get_bodies(part["id"])
    (min_x, _min_y, min_z), (max_x, _max_y, max_z) = _vertex_bounds(_body(bodies, surface["id"]))
    # direction_ref=fixed_axis X -> extrudes flat along world X instead of
    # the sketch plane's own Z normal - x now spans footprint + end_distance,
    # z stays flat at 0 (the wire never leaves the sketch plane's own
    # height).
    assert max_x - min_x == 10.0 + 8.0
    assert max_z - min_z == 0.0


# --- native_format round-trip -------------------------------------------------


def test_surface_feature_round_trips_through_native_export_import():
    """Mirrors test_bevel_gear_feature.py's own native round-trip precedent:
    `/document/export/native` exports the *whole* Document (every Part any
    test in this session has created, not just this test's own - see
    `export_native_document`'s own docstring), and `/document/import/native`
    is a full replace, not a merge. So this must (a) save/restore the
    Document/Sketch store around the whole test, since importing the export
    right back in would otherwise be a no-op for *this* test but would
    permanently clobber whatever other state existed only by coincidence,
    and (b) look the re-imported Part back up by `part["id"]` directly
    (export/import preserves ids verbatim) rather than assuming `imported.
    json()["part_ids"][0]` is this test's own Part - it's simply the first
    Part in the whole Document, which depends on what other tests already
    ran in this same worker."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
        _create_extrude_feature(part["id"], body_sketch["id"])
        surface_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=0.0)
        surface = _create_surface_feature(
            part["id"],
            surface_sketch["id"],
            start_distance=-1.0,
            end_distance=5.0,
            direction_ref={"fixed_axis": "x"},
        ).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "surface")
        assert round_tripped["sketch_feature_id"] == surface["sketch_feature_id"]
        assert round_tripped["start_distance"] == -1.0
        assert round_tripped["end_distance"] == 5.0
        assert round_tripped["direction_ref"] == {
            "edge_ref": None,
            "sketch_line_ref": None,
            "fixed_axis": "x",
        }
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_the_backing_sketch_feature_cascade_deletes_the_surface_feature():
    part = _create_part()
    body_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], body_sketch["id"])
    surface_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=0.0)
    surface = _create_surface_feature(part["id"], surface_sketch["id"]).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{surface_sketch['id']}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {surface_sketch["id"], surface["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert surface["id"] not in remaining
    assert surface_sketch["id"] not in remaining
