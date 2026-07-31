"""Bug fix: on-device follow-up to the same day's Plane/Sketch display-
drift fix (see `test_bugfix_stale_feature_resolution.py`) - after that fix
landed, the user tried the actual reported workflow end to end ("pattern a
hole in a plate") and it still didn't work: no second hole appeared, and a
later, more precise repro (100x200mm plate, hole hosted on a face-anchored
Plane) showed a small stray cut appearing in the wrong corner of the plate
instead of a clean second hole - "it looks like the cylinder is in the
wrong orientation."

Root cause: a *third* instance of the same underlying bug class as the
Plane/Sketch display-drift fix, this time in Phase 8's own new code
(`docs/pattern-mirror-scope.md` §2.11) rather than a display/refresh path -
`app.document.pattern.resolve_pattern_tool_feature_from_bodies`/
`app.document.mirror.resolve_mirror_tool_feature_from_bodies` both called
`app.document.extrude.resolve_feature_tool_shape` (which re-derives the
referenced upstream `tool_feature_id`'s own standalone tool shape) passing
their *own* `bodies`/`excluded_feature_ids` straight through - i.e. the
Part as of the calling Pattern/Mirror's own position in the walk, which is
*after* `tool_feature_id`'s own Cut/Boss already ran. When that upstream
Feature's Sketch is anchored to a face-anchored `CreatePlaneFeature` (the
exact `sketch>extrude>plane>sketch>cut>pattern` shape from the earlier
report), re-resolving the Plane's own `face_ref` against the *post-cut*
Body silently returns a different face than the one used when the Cut was
originally created (the same "OCCT face index isn't a persistent label"
problem - see `app.document.graph.excluded_feature_ids_after`'s own
docstring) - producing a tool shape with a correct volume but a wrong
position/orientation, which one direct reproduction confirmed by comparing
the anchor Plane's own resolved origin/normal between the two call sites:
`(0, 0, 5)`/`(0, 0, 1)` (correct) vs. `(20, 45, 0)`/`(0, 1, 0)` (wrong - a
different face of the same box entirely).

Fix: both resolvers now compute a *separate* bodies snapshot - the Part
exactly as it stood right before `tool_feature_id` itself ran (via the same
`excluded_feature_ids_after` helper the Plane/Sketch display fix
introduced, applied here to `tool_feature_id` rather than to `self`) -
and resolve `resolve_feature_tool_shape` against that, instead of this
Pattern/Mirror's own further-advanced accumulator.

Runs for real against pythonocc-core in this sandbox - confirmed to fail
without the fix (wrong hole location entirely, verified via the tool
shape's own bounding box landing far outside the plate's real extent) and
pass with it (see this file's own git history for the pre-fix trace, kept
out of the test body itself to stay a plain assertion, not a debug script).
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, **payload) -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json=payload or {"plane": "XY"})
    assert response.status_code == 201
    return response.json()


def _add_rect(sketch_id: str, x0: float, y0: float, width: float, height: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + width, y0), (x0 + width, y0 + height), (x0, y0 + height)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _add_circle(sketch_id: str, cx: float, cy: float, radius: float) -> None:
    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": cx, "y": cy}).json()
    response = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center["id"], "radius": radius},
    )
    assert response.status_code == 201


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


def _build_the_reported_scenario() -> dict:
    """A 40x90x5 plate, a `CreatePlaneFeature` anchored to its own top face
    (`sketch>extrude>plane`, matching the earlier report's exact Build Tree
    shape), a hole Sketch hosted on that Plane (`plane_feature_id`) and cut
    into the plate (`plane>sketch>cut`), then a `tool_feature_id`-seeded
    Rectangular Pattern of that Cut along one of the plate's own real edges
    (`cut>pattern`) - the full `sketch>extrude>plane>sketch>cut>pattern`
    chain from the original on-device report."""
    part = _create_part()
    base_sketch = _create_sketch_feature(part["id"], plane="XY")
    _add_rect(base_sketch["sketch_id"], -20.0, -45.0, 40.0, 90.0)
    plate = _create_extrude_feature(part["id"], base_sketch["id"], end_distance=5.0)

    plane = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [{"face_ref": {"body_id": plate["id"], "shape_type": "face", "index": 5}}],
            "offset": 0.0,
        },
    ).json()
    assert plane["origin"] == [0.0, 0.0, 5.0]
    assert plane["normal"] == [0.0, 0.0, 1.0]

    hole_sketch = _create_sketch_feature(part["id"], plane_feature_id=plane["id"])
    _add_circle(hole_sketch["sketch_id"], 8.0, -10.0, 4.0)
    cut = _create_extrude_feature(
        part["id"],
        hole_sketch["id"],
        extrude_type="cut",
        start_distance=-5.0,
        end_distance=0.0,
        target_body_ids=[plate["id"]],
    )

    return {"part": part, "plate": plate, "plane": plane, "hole_sketch": hole_sketch, "cut": cut}


def test_pattern_tool_feature_hole_lands_on_the_correct_face_not_a_stray_corner():
    scenario = _build_the_reported_scenario()
    part_id = scenario["part"]["id"]
    plate_id = scenario["plate"]["id"]
    cut_id = scenario["cut"]["id"]

    mesh_before = client.get(f"/document/parts/{part_id}/mesh").json()
    verts_before = len(mesh_before[0]["mesh"]["vertices"])

    payload = {
        "source_body_ids": [],
        "source_feature_ids": [],
        "pattern_type": "rectangular",
        # Edge 10: the plate's own top short edge at z=0 (proven stable pre-
        # cut) - direction (-1, 0, 0), so a spacing of 20 moves the second
        # hole from x=8 to x=-12, still well inside the 40-wide plate.
        "direction_1": {"edge_ref": {"body_id": plate_id, "shape_type": "edge", "index": 10}},
        "count_1": 2,
        "spacing_1": 20.0,
        "merge": "fuse_into_one",
        "tool_feature_id": cut_id,
    }
    response = client.post(f"/document/parts/{part_id}/pattern-features", json=payload)
    assert response.status_code == 201

    mesh_after = client.get(f"/document/parts/{part_id}/mesh").json()
    assert len(mesh_after) == 1
    verts_after = len(mesh_after[0]["mesh"]["vertices"])

    # The bug produced a no-op (identical vertex count - the mis-oriented
    # tool cylinder missed the plate's material entirely) in one repro, and
    # a stray off-target cut in another - either way, the two real holes
    # (original at x=8 and its pattern copy at x=-12, both on the plate's
    # own top face at z=0, y=-10) are the only correct outcome. A real,
    # correctly-placed second hole always changes the mesh's own vertex
    # count from the single-hole baseline.
    assert verts_after != verts_before


def test_mirror_tool_feature_hole_lands_on_the_correct_face_not_a_stray_corner():
    scenario = _build_the_reported_scenario()
    part_id = scenario["part"]["id"]
    cut_id = scenario["cut"]["id"]

    mesh_before = client.get(f"/document/parts/{part_id}/mesh").json()
    verts_before = len(mesh_before[0]["mesh"]["vertices"])

    payload = {
        "source_body_ids": [],
        "source_feature_ids": [],
        "mirror_plane": {"fixed_plane": "YZ"},
        "merge": "fuse_into_one",
        "tool_feature_id": cut_id,
    }
    response = client.post(f"/document/parts/{part_id}/mirror-features", json=payload)
    assert response.status_code == 201

    mesh_after = client.get(f"/document/parts/{part_id}/mesh").json()
    assert len(mesh_after) == 1
    verts_after = len(mesh_after[0]["mesh"]["vertices"])
    assert verts_after != verts_before
