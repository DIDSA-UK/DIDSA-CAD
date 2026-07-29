"""Pattern/Mirror scoping's Phase 5 (`docs/pattern-mirror-scope.md` §2.10/
§4): real-OCCT tests for `MergeMode` - `KEEP_SEPARATE` (the existing Phase
1-4 default, unchanged) vs. `FUSE_INTO_ONE` (fuses every realized instance
plus the original source Body/Bodies together via `BRepAlgoAPI_Fuse`,
mirroring `_apply_boss_or_cut`'s own multi-target fuse/survivor-tie-break
convention - see `app.document.extrude._fuse_realized_instances`), for both
MirrorFeature and PatternFeature (both Rectangular and Circular). Mirrors
test_stage_i_mirror.py/test_stage_j_pattern.py/test_stage_k_pattern_
circular.py's own structure and helpers. All touch `app.main`/`app.
document.mirror`/`app.document.pattern`/`app.document.extrude`, which
import OCC.Core directly, so (per the recurring caveat in docs/status.md)
these are `ast.parse`-verified/manually reviewed only in a sandbox without
a real pythonocc-core toolchain - this session installed one (micromamba +
conda-forge) and ran the full suite for real instead.
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


def _create_circle_sketch_feature(part_id: str, *, radius: float = 10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    center = _add_point(feature["sketch_id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{feature['sketch_id']}/circles",
        json={"center_point_id": center["id"], "radius": radius, "angle": 0.0},
    )
    assert response.status_code == 201
    return feature


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


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _first_body_id(part_id: str) -> str:
    mesh = _mesh(part_id)
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _boxy_part_and_body(*, x0=0.0, y0=0.0, size=10.0) -> tuple[dict, str]:
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"], x0=x0, y0=y0, size=size)
    _create_extrude_feature(part["id"], sketch_feature["id"])
    return part, _first_body_id(part["id"])


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    mesh = next(e for e in _mesh(part_id) if e["body_id"] == body_id)["mesh"]
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _rounded_xy_ranges(part_id: str, body_id: str) -> tuple[tuple[float, float], tuple[float, float]]:
    x_range, y_range, _z_range = _bbox_ranges(part_id, body_id)
    return (round(x_range[0], 3), round(x_range[1], 3)), (round(y_range[0], 3), round(y_range[1], 3))


def _fixed_plane_ref(plane: str) -> dict:
    return {"face_ref": None, "fixed_plane": plane, "plane_feature_id": None}


def _offset_plane_feature(part_id: str, fixed_plane: str, offset: float) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={"plane_type": "offset_face", "face_refs": [_fixed_plane_ref(fixed_plane)], "offset": offset},
    )
    assert response.status_code == 201
    return response.json()


def _create_plane_feature_ref(plane_feature_id: str) -> dict:
    return {"face_ref": None, "fixed_plane": None, "plane_feature_id": plane_feature_id}


def _create_mirror(part_id: str, source_body_ids: list[str], mirror_plane: dict, *, merge: str | None = None):
    payload = {"source_body_ids": source_body_ids, "mirror_plane": mirror_plane}
    if merge is not None:
        payload["merge"] = merge
    return client.post(f"/document/parts/{part_id}/mirror-features", json=payload)


def _fixed_axis_direction(axis: str) -> dict:
    return {"edge_ref": None, "sketch_line_ref": None, "fixed_axis": axis}


def _edge_axis(body_id: str, index: int) -> dict:
    return {"edge_ref": {"body_id": body_id, "shape_type": "edge", "index": index}, "face_ref": None,
            "sketch_line_ref": None}


def _create_pattern_rectangular(
    part_id: str,
    source_body_ids: list[str],
    direction_1: dict,
    count_1: int,
    spacing_1: float,
    *,
    skip_indices: list[int] | None = None,
    merge: str | None = None,
):
    payload = {
        "source_body_ids": source_body_ids,
        "pattern_type": "rectangular",
        "direction_1": direction_1,
        "count_1": count_1,
        "spacing_1": spacing_1,
        "skip_indices": skip_indices or [],
    }
    if merge is not None:
        payload["merge"] = merge
    return client.post(f"/document/parts/{part_id}/pattern-features", json=payload)


def _create_pattern_circular(
    part_id: str,
    source_body_ids: list[str],
    axis: dict,
    count_angular: int,
    *,
    angle_total: float = 360.0,
    merge: str | None = None,
):
    payload = {
        "source_body_ids": source_body_ids,
        "pattern_type": "circular",
        "axis": axis,
        "count_angular": count_angular,
        "angle_total": angle_total,
    }
    if merge is not None:
        payload["merge"] = merge
    return client.post(f"/document/parts/{part_id}/pattern-features", json=payload)


def _first_circular_edge_index(part_id: str, body_id: str, *, probe_count: int = 12) -> int:
    """Brute-forces a genuinely circular edge index on `body_id` - mirrors
    test_stage_k_pattern_circular.py's own identical helper."""
    for index in range(probe_count):
        response = _create_pattern_circular(part_id, [body_id], _edge_axis(body_id, index), 4)
        if response.status_code != 201:
            continue
        feature_id = response.json()["id"]
        new_body_id = next(bid for bid in _body_ids(part_id) if bid != body_id)
        x_range, y_range = _rounded_xy_ranges(part_id, new_body_id)
        centered = abs(x_range[0] + x_range[1]) < 2.0 and abs(y_range[0] + y_range[1]) < 2.0
        client.delete(f"/document/parts/{part_id}/features/{feature_id}/cascade")
        if centered:
            return index
    raise AssertionError("expected at least one circular edge through the Body's own true centre")


# --- Mirror: KEEP_SEPARATE is unchanged ---------------------------------------


def test_mirror_default_merge_is_keep_separate():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"))
    assert response.status_code == 201
    assert response.json()["merge"] == "keep_separate"
    assert len(_body_ids(part["id"])) == 2


def test_mirror_explicit_keep_separate_matches_the_default():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"), merge="keep_separate")
    assert response.status_code == 201
    assert len(_body_ids(part["id"])) == 2


# --- Mirror: FUSE_INTO_ONE -----------------------------------------------------


def test_mirror_fuse_into_one_produces_a_single_body():
    """The box spans x in [0, 10]; mirroring across YZ (x=0) produces a
    copy spanning [-10, 0], which touches the original at x=0 - a single
    connected solid spanning the full [-10, 10] range once fused."""
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"), merge="fuse_into_one")
    assert response.status_code == 201
    assert response.json()["merge"] == "fuse_into_one"

    body_ids = _body_ids(part["id"])
    assert body_ids == [body_id]  # single source -> the fused result inherits its own id
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (-10.0, 10.0)


def test_mirror_fuse_into_one_with_a_disconnected_copy_still_splits_into_two_bodies():
    """Mirroring the [0, 10] box about an offset plane at x=20 produces a
    copy spanning [30, 40] - disjoint from the original, with a real gap
    between x=10 and x=30. `_fuse_realized_instances`' own `_register_
    solids` call must still split this into two separate Bodies, not
    silently merge or drop one."""
    part, body_id = _boxy_part_and_body()
    plane_feature = _offset_plane_feature(part["id"], "YZ", 20.0)

    response = _create_mirror(
        part["id"], [body_id], _create_plane_feature_ref(plane_feature["id"]), merge="fuse_into_one"
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 2
    assert all(bid == body_id or bid.startswith(f"{body_id}#") for bid in body_ids)
    ranges = {_bbox_ranges(part["id"], bid)[0] for bid in body_ids}
    assert ranges == {(0.0, 10.0), (30.0, 40.0)}


def test_mirror_fuse_into_one_with_two_sources_survivor_is_the_earlier_created_source():
    """Two boxes ([0,10] and [10,20], touching each other) mirrored across
    YZ (x=0): the mirrored copies ([-10,0] and [-20,-10]) chain-connect the
    whole thing into one solid spanning [-20, 20]. The fused result must
    register under `body_id_a` (the earlier-created source, per
    `_fuse_realized_instances`' own `feature_index` tie-break) - mirrors
    `_apply_boss_or_cut`'s own survivor convention - not a brand-new id and
    not `body_id_b`."""
    part = _create_part()
    sketch_a = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0, size=10.0)
    _create_extrude_feature(part["id"], sketch_a["id"])
    body_id_a = _first_body_id(part["id"])
    sketch_b = _create_square_sketch_feature(part["id"], x0=10.0, y0=0.0, size=10.0)
    _create_extrude_feature(part["id"], sketch_b["id"])
    body_id_b = next(bid for bid in _body_ids(part["id"]) if bid != body_id_a)

    response = _create_mirror(
        part["id"], [body_id_a, body_id_b], _fixed_plane_ref("YZ"), merge="fuse_into_one"
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    assert body_ids == [body_id_a]
    x_range, _y, _z = _bbox_ranges(part["id"], body_id_a)
    assert x_range == (-20.0, 20.0)


def test_mirror_patch_toggling_merge_to_fuse_into_one_collapses_to_one_body():
    part, body_id = _boxy_part_and_body()
    created = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ")).json()
    assert len(_body_ids(part["id"])) == 2

    patch_response = client.patch(
        f"/document/parts/{part['id']}/mirror-features/{created['id']}", json={"merge": "fuse_into_one"}
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["merge"] == "fuse_into_one"
    assert _body_ids(part["id"]) == [body_id]


def test_mirror_patch_omitting_merge_leaves_it_unchanged():
    part, body_id = _boxy_part_and_body()
    created = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"), merge="fuse_into_one").json()
    assert created["merge"] == "fuse_into_one"

    patch_response = client.patch(
        f"/document/parts/{part['id']}/mirror-features/{created['id']}",
        json={"mirror_plane": _fixed_plane_ref("XZ")},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["merge"] == "fuse_into_one"
    assert _body_ids(part["id"]) == [body_id]


def test_mirror_invalid_merge_value_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"), merge="not_a_real_mode")
    assert response.status_code == 422


# --- Pattern (Rectangular): KEEP_SEPARATE is unchanged ------------------------


def test_pattern_default_merge_is_keep_separate():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern_rectangular(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0)
    assert response.status_code == 201
    assert response.json()["merge"] == "keep_separate"
    assert len(_body_ids(part["id"])) == 3


# --- Pattern (Rectangular): FUSE_INTO_ONE -------------------------------------


def test_pattern_rectangular_fuse_into_one_produces_a_single_body():
    """A 3-instance pattern with spacing (5) less than the box's own size
    (10) overlaps every instance with its neighbour - one connected solid
    spanning [0, 20] once fused, registered under the seed's own existing
    id (not a brand-new one)."""
    part, body_id = _boxy_part_and_body()
    response = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 5.0, merge="fuse_into_one"
    )
    assert response.status_code == 201
    assert response.json()["merge"] == "fuse_into_one"

    body_ids = _body_ids(part["id"])
    assert body_ids == [body_id]
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 20.0)


def test_pattern_rectangular_fuse_into_one_excludes_skipped_instances():
    """3 instances 20 apart ([0,10], [20,30], [40,50]) - disjoint even
    without any skip. Skipping the middle instance (index 1) means only
    the seed and the last instance are ever realized/fused - two disjoint
    solids, not three, and the skipped instance's [20,30] range must be
    absent entirely (per PatternFeature's own docstring: a skipped
    instance never even briefly exists as a shape, so it can never be part
    of a FUSE_INTO_ONE merge either)."""
    part, body_id = _boxy_part_and_body()
    response = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[1], merge="fuse_into_one"
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 2
    assert all(bid == body_id or bid.startswith(f"{body_id}#") for bid in body_ids)
    ranges = {_bbox_ranges(part["id"], bid)[0] for bid in body_ids}
    assert ranges == {(0.0, 10.0), (40.0, 50.0)}


def test_pattern_rectangular_fuse_into_one_with_fully_disjoint_instances_splits_into_three():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, merge="fuse_into_one"
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 3
    assert all(bid == body_id or bid.startswith(f"{body_id}#") for bid in body_ids)
    ranges = {_bbox_ranges(part["id"], bid)[0] for bid in body_ids}
    assert ranges == {(0.0, 10.0), (20.0, 30.0), (40.0, 50.0)}


def test_pattern_patch_toggling_merge_to_fuse_into_one_collapses_overlapping_instances():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern_rectangular(part["id"], [body_id], _fixed_axis_direction("x"), 3, 5.0).json()
    assert len(_body_ids(part["id"])) == 3

    patch_response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}", json={"merge": "fuse_into_one"}
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["merge"] == "fuse_into_one"
    assert _body_ids(part["id"]) == [body_id]


def test_pattern_invalid_merge_value_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, merge="not_a_real_mode"
    )
    assert response.status_code == 422


# --- Pattern (Circular): FUSE_INTO_ONE ----------------------------------------


def test_pattern_circular_fuse_into_one_splits_into_disjoint_quadrant_bodies():
    """Mirrors test_stage_k_pattern_circular.py's own quadrant-position
    setup: a small offset box, patterned 4x around a separate cylinder's
    own centre axis, lands in 4 non-touching quadrant positions - fusing
    them must still split into 4 separate Bodies (registered under the
    box's own id, `#N`-suffixed), not silently collapse or drop any."""
    part = _create_part()
    cylinder_sketch = _create_circle_sketch_feature(part["id"], radius=20.0)
    _create_extrude_feature(part["id"], cylinder_sketch["id"])
    cylinder_body_id = _first_body_id(part["id"])
    edge_index = _first_circular_edge_index(part["id"], cylinder_body_id)

    box_sketch = _create_square_sketch_feature(part["id"], x0=30.0, y0=0.0, size=5.0)
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = next(bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id)

    response = _create_pattern_circular(
        part["id"], [box_body_id], _edge_axis(cylinder_body_id, edge_index), 4, merge="fuse_into_one"
    )
    assert response.status_code == 201
    assert response.json()["merge"] == "fuse_into_one"

    box_body_ids = [bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id]
    assert len(box_body_ids) == 4
    assert all(bid == box_body_id or bid.startswith(f"{box_body_id}#") for bid in box_body_ids)

    actual_positions = {_rounded_xy_ranges(part["id"], bid) for bid in box_body_ids}
    expected_positions = {
        ((30.0, 35.0), (0.0, 5.0)),
        ((-5.0, 0.0), (30.0, 35.0)),
        ((-35.0, -30.0), (-5.0, 0.0)),
        ((0.0, 5.0), (-35.0, -30.0)),
    }
    assert actual_positions == expected_positions


# --- List/response shape -------------------------------------------------------


def test_list_features_includes_merge_for_mirror_and_pattern():
    part, body_id = _boxy_part_and_body()
    mirror = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"), merge="fuse_into_one").json()
    client.delete(f"/document/parts/{part['id']}/features/{mirror['id']}/cascade")
    pattern = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 2, 20.0, merge="fuse_into_one"
    ).json()

    features = client.get(f"/document/parts/{part['id']}/features").json()
    pattern_entry = next(f for f in features if f["id"] == pattern["id"])
    assert pattern_entry["merge"] == "fuse_into_one"
