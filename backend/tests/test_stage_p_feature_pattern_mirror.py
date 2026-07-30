"""Pattern/Mirror scoping's Phase 8 (`docs/pattern-mirror-scope.md` §2.11/
§4): real-OCCT tests for `tool_feature_id` - the third, mutually-exclusive
seed-picking mode on both `MirrorFeature`/`PatternFeature`, naming an
upstream Extrude/Revolve/Sweep Cut/Boss-into-target Feature instead of a
Body/Feature-tree Body source. Mirrors test_stage_i_mirror.py/test_stage_j_
pattern.py/test_stage_m_merge.py's own structure and helpers - all touch
`app.main`/`app.document.mirror`/`app.document.pattern`/`app.document.
extrude`, which import OCC.Core directly, so (per the recurring caveat in
docs/status.md) these only run for real against a genuine pythonocc-core
toolchain (micromamba + conda-forge, this session's own bootstrap).

Core scenario throughout: a 40x40x10 "plate" (a single Boss), with a small
square hole Cut into it (`target_body_ids=[plate_id]`) - the "eligible
upstream Cut/Boss-into-target Feature" `tool_feature_id` names. Mirroring/
patterning that Cut via `tool_feature_id` must end up with *more holes in
the same plate Body*, not a second, independent plate.
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


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _volume(part_id: str, body_id: str) -> float:
    """The Body's own enclosed volume via the divergence theorem over its
    tessellated triangle mesh (`sum(v0 . (v1 x v2)) / 6`) - exact (up to
    floating-point) for a Body built entirely from planar box/hole faces
    like every scenario in this file, since a flat face tessellates into
    coplanar triangles with zero curvature error."""
    entry = next(e for e in _mesh(part_id) if e["body_id"] == body_id)
    vertices = entry["mesh"]["vertices"]
    total = 0.0
    for a, b, c in entry["mesh"]["triangle_indices"]:
        v0, v1, v2 = vertices[a], vertices[b], vertices[c]
        cross = (
            v1[1] * v2[2] - v1[2] * v2[1],
            v1[2] * v2[0] - v1[0] * v2[2],
            v1[0] * v2[1] - v1[1] * v2[0],
        )
        total += v0[0] * cross[0] + v0[1] * cross[1] + v0[2] * cross[2]
    return abs(total) / 6.0


def _fixed_plane_ref(plane: str) -> dict:
    return {"face_ref": None, "fixed_plane": plane, "plane_feature_id": None}


def _fixed_axis_direction(axis: str) -> dict:
    return {"edge_ref": None, "sketch_line_ref": None, "fixed_axis": axis}


def _create_mirror(
    part_id: str,
    source_body_ids: list[str],
    mirror_plane: dict,
    *,
    tool_feature_id: str | None = None,
    merge: str | None = None,
):
    payload: dict = {"source_body_ids": source_body_ids, "mirror_plane": mirror_plane}
    if tool_feature_id is not None:
        payload["tool_feature_id"] = tool_feature_id
    if merge is not None:
        payload["merge"] = merge
    return client.post(f"/document/parts/{part_id}/mirror-features", json=payload)


def _create_pattern_rectangular(
    part_id: str,
    source_body_ids: list[str],
    direction_1: dict,
    count_1: int,
    spacing_1: float,
    *,
    tool_feature_id: str | None = None,
    merge: str | None = None,
):
    payload: dict = {
        "source_body_ids": source_body_ids,
        "pattern_type": "rectangular",
        "direction_1": direction_1,
        "count_1": count_1,
        "spacing_1": spacing_1,
    }
    if tool_feature_id is not None:
        payload["tool_feature_id"] = tool_feature_id
    if merge is not None:
        payload["merge"] = merge
    return client.post(f"/document/parts/{part_id}/pattern-features", json=payload)


def _plate(part_id: str, *, size: float = 40.0) -> str:
    """A single centered `size`x`size`x10 Boss - the shared target every
    scenario below Cuts a hole into."""
    half = size / 2.0
    sketch = _create_square_sketch_feature(part_id, x0=-half, y0=-half, size=size)
    response = _create_extrude_feature(part_id, sketch["id"])
    assert response.status_code == 201
    return response.json()["id"]


def _hole_cut(part_id: str, plate_id: str, *, x0: float, y0: float, size: float = 2.0) -> dict:
    """A small square Cut into `plate_id` - the "eligible upstream Cut/
    Boss-into-target Feature" every `tool_feature_id` scenario below names."""
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    response = _create_extrude_feature(
        part_id, sketch["id"], extrude_type="cut", target_body_ids=[plate_id]
    )
    assert response.status_code == 201
    return response.json()


def _plate_with_hole(part_id: str, *, plate_size: float = 40.0, hole_size: float = 2.0):
    plate_id = _plate(part_id, size=plate_size)
    cut = _hole_cut(part_id, plate_id, x0=1.0, y0=1.0, size=hole_size)
    return plate_id, cut


def _targetless_boss(part_id: str) -> dict:
    sketch = _create_square_sketch_feature(part_id, x0=100.0, y0=100.0, size=5.0)
    response = _create_extrude_feature(part_id, sketch["id"], extrude_type="boss")
    assert response.status_code == 201
    return response.json()


# --- Mirror: tool_feature_id happy path ---------------------------------------


def test_mirror_tool_feature_id_mirrors_a_cut_into_the_same_shared_target():
    """The scope doc's own headline example: a plate with one off-center
    hole, mirrored, ends up with two holes in the *same* plate, not two
    separate plates."""
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"], plate_size=40.0, hole_size=2.0)
    plate_volume_one_hole = _volume(part["id"], plate_id)

    response = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=cut["id"], merge="fuse_into_one"
    )
    assert response.status_code == 201
    body = response.json()
    assert body["tool_feature_id"] == cut["id"]
    assert body["source_body_ids"] == []
    assert body["source_feature_ids"] == []

    body_ids = _body_ids(part["id"])
    assert body_ids == [plate_id]  # still one Body, the plate's own id - not a second plate

    hole_volume = 2.0 * 2.0 * 10.0
    assert _volume(part["id"], plate_id) == pytest.approx(plate_volume_one_hole - hole_volume)


def test_mirror_tool_feature_id_response_and_get_round_trip_tool_feature_id():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    created = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=cut["id"], merge="fuse_into_one"
    ).json()

    fetched = client.get(f"/document/parts/{part['id']}/features").json()
    mirror_entry = next(f for f in fetched if f["id"] == created["id"])
    assert mirror_entry["tool_feature_id"] == cut["id"]


def test_mirror_tool_feature_id_against_a_boss_into_target_fuses_the_boss_copy_too():
    """Boss-into-target mode (not just Cut): mirroring a Boss that was
    itself fused into an existing plate must fuse the mirrored copy into
    that same plate too - `is_cut=False` dispatches to `BRepAlgoAPI_Fuse`,
    not `_Cut`, against the target's current shape. The boss pedestal sits
    *on top of* the plate's own top face (z in [10, 12], the plate's own z
    range is [0, 10]) rather than embedded inside its footprint - a boss
    fully contained within the target's own existing volume would fuse to
    a no-op (same volume before and after), which wouldn't actually prove
    anything got added."""
    part = _create_part()
    plate_id = _plate(part["id"], size=40.0)
    boss_sketch = _create_square_sketch_feature(part["id"], x0=1.0, y0=1.0, size=2.0)
    boss = _create_extrude_feature(
        part["id"],
        boss_sketch["id"],
        extrude_type="boss",
        start_distance=10.0,
        end_distance=12.0,
        target_body_ids=[plate_id],
    ).json()
    plate_volume_with_boss = _volume(part["id"], plate_id)

    response = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=boss["id"], merge="fuse_into_one"
    )
    assert response.status_code == 201
    assert _body_ids(part["id"]) == [plate_id]

    boss_volume = 2.0 * 2.0 * 2.0
    assert _volume(part["id"], plate_id) == pytest.approx(plate_volume_with_boss + boss_volume)


# --- Pattern: tool_feature_id happy path --------------------------------------


def test_pattern_tool_feature_id_repeats_a_cut_n_times_into_the_same_shared_target():
    """Index 0 (the seed Cut's own hole) is already baked into the target -
    a count_1=3 pattern only adds the *other* two holes, not three new
    ones, and everything lands in the one shared plate Body."""
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"], plate_size=40.0, hole_size=2.0)
    plate_volume_one_hole = _volume(part["id"], plate_id)

    response = _create_pattern_rectangular(
        part["id"],
        [],
        _fixed_axis_direction("x"),
        3,
        5.0,
        tool_feature_id=cut["id"],
        merge="fuse_into_one",
    )
    assert response.status_code == 201
    body = response.json()
    assert body["tool_feature_id"] == cut["id"]

    assert _body_ids(part["id"]) == [plate_id]
    hole_volume = 2.0 * 2.0 * 10.0
    # 2 *additional* holes (index 0 already existed) - not 3.
    assert _volume(part["id"], plate_id) == pytest.approx(plate_volume_one_hole - 2 * hole_volume)


def test_pattern_tool_feature_id_skip_indices_applies_the_same_way():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"], plate_size=40.0, hole_size=2.0)
    plate_volume_one_hole = _volume(part["id"], plate_id)

    payload = {
        "source_body_ids": [],
        "tool_feature_id": cut["id"],
        "pattern_type": "rectangular",
        "direction_1": _fixed_axis_direction("x"),
        "count_1": 3,
        "spacing_1": 5.0,
        "skip_indices": [1],
        "merge": "fuse_into_one",
    }
    response = client.post(f"/document/parts/{part['id']}/pattern-features", json=payload)
    assert response.status_code == 201

    hole_volume = 2.0 * 2.0 * 10.0
    # Only index 2 is realized (index 1 skipped, index 0 already existed) -
    # one additional hole, not two.
    assert _volume(part["id"], plate_id) == pytest.approx(plate_volume_one_hole - hole_volume)


# --- Validation: mutual exclusivity / merge / eligibility ---------------------


def test_mirror_tool_feature_id_mutually_exclusive_with_source_body_ids():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    response = _create_mirror(
        part["id"], [plate_id], _fixed_plane_ref("YZ"), tool_feature_id=cut["id"], merge="fuse_into_one"
    )
    assert response.status_code == 422


def test_pattern_tool_feature_id_mutually_exclusive_with_source_feature_ids():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    payload = {
        "source_body_ids": [],
        "source_feature_ids": [plate_id],
        "tool_feature_id": cut["id"],
        "pattern_type": "rectangular",
        "direction_1": _fixed_axis_direction("x"),
        "count_1": 3,
        "spacing_1": 5.0,
        "merge": "fuse_into_one",
    }
    response = client.post(f"/document/parts/{part['id']}/pattern-features", json=payload)
    assert response.status_code == 422


def test_mirror_tool_feature_id_rejects_default_keep_separate_merge():
    """merge is meaningless once tool_feature_id names exactly one shared
    target - the router rejects the type's own KEEP_SEPARATE default
    outright rather than silently ignoring it."""
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    response = _create_mirror(part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=cut["id"])
    assert response.status_code == 422


def test_mirror_tool_feature_id_rejects_explicit_keep_separate_merge():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    response = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=cut["id"], merge="keep_separate"
    )
    assert response.status_code == 422


def test_pattern_tool_feature_id_rejects_default_keep_separate_merge():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    response = _create_pattern_rectangular(
        part["id"], [], _fixed_axis_direction("x"), 3, 5.0, tool_feature_id=cut["id"]
    )
    assert response.status_code == 422


def test_mirror_tool_feature_id_rejects_a_wrong_feature_type():
    """A SketchFeature is a real Feature id in this Part, but not an
    Extrude/Revolve/Sweep - `invalid_tool_feature_ref`, not a generic
    missing_reference."""
    part = _create_part()
    plate_id, _cut = _plate_with_hole(part["id"])
    sketch_feature = _create_sketch_feature(part["id"])

    response = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=sketch_feature["id"], merge="fuse_into_one"
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_tool_feature_ref"


def test_mirror_tool_feature_id_rejects_a_targetless_boss():
    """A Boss with empty target_body_ids has no "shared target" problem at
    all - the ordinary source_body_ids/source_feature_ids path already
    copies it correctly as an independent Body, so it's excluded here."""
    part = _create_part()
    boss = _targetless_boss(part["id"])

    response = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=boss["id"], merge="fuse_into_one"
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_tool_feature_ref"


def test_pattern_tool_feature_id_rejects_a_nonexistent_feature_id():
    part = _create_part()
    plate_id, _cut = _plate_with_hole(part["id"])

    response = _create_pattern_rectangular(
        part["id"], [], _fixed_axis_direction("x"), 3, 5.0,
        tool_feature_id="does-not-exist", merge="fuse_into_one",
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_tool_feature_ref"


def test_pattern_tool_feature_id_rejects_a_fillet_feature():
    """Fillet/Chamfer feature-pattern/mirror stays out of scope for Phase 8
    (§2.11's own scope-boundary note - no standalone tool shape to
    transform) - a Fillet id is a real, body-producing-adjacent Feature in
    this Part, but must still be rejected as `invalid_tool_feature_ref`.
    Uses a plain, hole-free plate (not `_plate_with_hole`) - a small,
    always-valid radius on an unmodified box edge, no brute-forcing a
    working index the way a post-Cut topology might need."""
    part = _create_part()
    plate_id = _plate(part["id"])
    fillet_response = client.post(
        f"/document/parts/{part['id']}/fillet-features",
        json={
            "edge_refs": [{"body_id": plate_id, "shape_type": "edge", "index": 0}],
            "radius": 1.0,
        },
    )
    assert fillet_response.status_code == 201
    fillet = fillet_response.json()

    response = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=fillet["id"], merge="fuse_into_one"
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_tool_feature_ref"


# --- Cascade delete -----------------------------------------------------------


def test_cascade_deleting_the_tool_feature_takes_the_mirror_with_it():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    mirror = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=cut["id"], merge="fuse_into_one"
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{cut['id']}/cascade")
    assert response.status_code == 200
    assert mirror["id"] in response.json()["deleted_feature_ids"]


def test_cascade_deleting_the_tool_feature_takes_the_pattern_with_it():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    pattern = _create_pattern_rectangular(
        part["id"], [], _fixed_axis_direction("x"), 3, 5.0, tool_feature_id=cut["id"], merge="fuse_into_one"
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{cut['id']}/cascade")
    assert response.status_code == 200
    assert pattern["id"] in response.json()["deleted_feature_ids"]


# --- PATCH ---------------------------------------------------------------------


def test_mirror_patch_omitting_tool_feature_id_leaves_it_unchanged():
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"])
    created = _create_mirror(
        part["id"], [], _fixed_plane_ref("YZ"), tool_feature_id=cut["id"], merge="fuse_into_one"
    ).json()

    response = client.patch(
        f"/document/parts/{part['id']}/mirror-features/{created['id']}",
        json={"mirror_plane": _fixed_plane_ref("XZ")},
    )
    assert response.status_code == 200
    assert response.json()["tool_feature_id"] == cut["id"]
