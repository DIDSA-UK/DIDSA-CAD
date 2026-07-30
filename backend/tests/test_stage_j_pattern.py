"""Pattern/Mirror scoping's Phase 2 (`docs/pattern-mirror-scope.md` §2.2/§4):
real-OCCT tests for Rectangular Pattern's full router/HTTP surface - mirrors
test_stage_i_mirror.py's structure, substituting pattern-features' direction/
count/spacing/reverse for mirror-features' mirror_plane. All touch
`app.main`/`app.document.pattern`/`app.document.extrude`/`app.document.
create_plane`, which import OCC.Core directly, so (per the recurring caveat
in docs/status.md) these are `ast.parse`-verified/manually reviewed only in
this sandbox, same as every other OCCT-touching backend prompt in this
project until real CI runs it.
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


def _boxy_part_and_body() -> tuple[dict, str]:
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    return part, _first_body_id(part["id"])


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    """Per-axis (min, max) of `body_id`'s own tessellated vertices - used to
    verify a rigid translation: unaffected axes' extents and lower bound
    stay identical, exactly one axis' lower bound shifts by the expected
    offset, regardless of which world axis a given Body edge/Sketch Line
    happens to be aligned to (a box's own edges are always axis-aligned,
    but not always to a *predictable* one - same "don't assume, brute-force
    or verify structurally" precedent test_stage_c4_create_plane.py's own
    edge-index brute force establishes)."""
    mesh = next(e for e in _mesh(part_id) if e["body_id"] == body_id)["mesh"]
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _assert_pure_translation(part_id: str, seed_body_id: str, new_body_id: str, expected_distance: float) -> None:
    seed_ranges = _bbox_ranges(part_id, seed_body_id)
    new_ranges = _bbox_ranges(part_id, new_body_id)
    seed_extents = [hi - lo for lo, hi in seed_ranges]
    new_extents = [hi - lo for lo, hi in new_ranges]
    assert all(abs(a - b) < 1e-6 for a, b in zip(seed_extents, new_extents)), (
        seed_extents,
        new_extents,
    )
    shifts = [new_ranges[i][0] - seed_ranges[i][0] for i in range(3)]
    nonzero_shifts = [s for s in shifts if abs(s) > 1e-6]
    assert len(nonzero_shifts) == 1, shifts
    assert abs(abs(nonzero_shifts[0]) - expected_distance) < 1e-6, shifts


def _fixed_axis_direction(axis: str) -> dict:
    return {"edge_ref": None, "sketch_line_ref": None, "fixed_axis": axis}


def _edge_direction(body_id: str, index: int) -> dict:
    return {"edge_ref": {"body_id": body_id, "shape_type": "edge", "index": index}, "sketch_line_ref": None,
            "fixed_axis": None}


def _sketch_line_direction(sketch_id: str, entity_id: str) -> dict:
    return {
        "edge_ref": None,
        "sketch_line_ref": {"sketch_id": sketch_id, "entity_type": "line", "entity_id": entity_id},
        "fixed_axis": None,
    }


def _create_standalone_direction_line(part_id: str, *, x: float, y0: float, y1: float, plane="XY") -> dict:
    """A Sketch containing just one Line, usable as a pattern direction
    independent of any Profile - mirrors test_stage_f_revolve.py's own
    `_create_standalone_axis_line`."""
    feature = _create_sketch_feature(part_id, plane)
    p0 = _add_point(feature["sketch_id"], x, y0)
    p1 = _add_point(feature["sketch_id"], x, y1)
    line = _add_line(feature["sketch_id"], p0["id"], p1["id"])
    return {"sketch_id": feature["sketch_id"], "line_id": line["id"]}


def _create_pattern(
    part_id: str,
    source_body_ids: list[str],
    direction_1: dict,
    count_1: int,
    spacing_1: float,
    *,
    reverse_1: bool = False,
    direction_2: dict | None = None,
    count_2: int = 1,
    spacing_2: float = 0.0,
    reverse_2: bool = False,
):
    return client.post(
        f"/document/parts/{part_id}/pattern-features",
        json={
            "source_body_ids": source_body_ids,
            "direction_1": direction_1,
            "count_1": count_1,
            "spacing_1": spacing_1,
            "reverse_1": reverse_1,
            "direction_2": direction_2,
            "count_2": count_2,
            "spacing_2": spacing_2,
            "reverse_2": reverse_2,
        },
    )


# --- Success -------------------------------------------------------------------


def test_pattern_along_a_fixed_axis_produces_the_expected_number_of_bodies():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0)
    assert response.status_code == 201
    feature = response.json()
    assert feature["type"] == "pattern"
    assert feature["source_body_ids"] == [body_id]
    assert feature["produces"] == "body"

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 3  # seed + 2 new instances
    assert body_id in body_ids


def test_pattern_instances_are_pure_translations_along_the_fixed_axis():
    part, body_id = _boxy_part_and_body()
    _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0)

    new_body_ids = [bid for bid in _body_ids(part["id"]) if bid != body_id]
    assert len(new_body_ids) == 2

    distances = set()
    for new_body_id in new_body_ids:
        ranges_seed = _bbox_ranges(part["id"], body_id)
        ranges_new = _bbox_ranges(part["id"], new_body_id)
        shift = ranges_new[0][0] - ranges_seed[0][0]  # x axis
        distances.add(round(abs(shift), 6))
    assert distances == {20.0, 40.0}


def test_a_single_new_instance_registers_directly_under_the_feature_id_with_no_suffix():
    """Mirrors MirrorFeature's own single-vs-multiple naming convention -
    count_1=2 produces exactly one new instance (index 1), which should use
    `feature.id` directly rather than an `#1`-suffixed id."""
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], [body_id], _fixed_axis_direction("z"), 2, 15.0)
    feature = response.json()

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 2
    assert feature["id"] in body_ids


def test_reverse_flips_the_pattern_direction():
    part, body_id = _boxy_part_and_body()
    forward = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 2, 20.0)
    forward_new_id = next(bid for bid in _body_ids(part["id"]) if bid != body_id)
    forward_shift = _bbox_ranges(part["id"], forward_new_id)[0][0] - _bbox_ranges(part["id"], body_id)[0][0]
    client.delete(f"/document/parts/{part['id']}/features/{forward.json()['id']}/cascade")

    reversed_response = _create_pattern(
        part["id"], [body_id], _fixed_axis_direction("x"), 2, 20.0, reverse_1=True
    )
    reversed_new_id = next(bid for bid in _body_ids(part["id"]) if bid != body_id)
    reversed_shift = (
        _bbox_ranges(part["id"], reversed_new_id)[0][0] - _bbox_ranges(part["id"], body_id)[0][0]
    )
    assert reversed_response.status_code == 201
    assert abs(forward_shift + reversed_shift) < 1e-6
    assert abs(forward_shift) > 1e-6


def test_pattern_along_a_straight_body_edge_direction_succeeds():
    part, body_id = _boxy_part_and_body()
    # A box has 12 straight edges - any index is a straight (GeomAbs_Line)
    # edge, so no brute force is needed the way a curved-edge search needs.
    response = _create_pattern(part["id"], [body_id], _edge_direction(body_id, 0), 2, 5.0)
    assert response.status_code == 201
    new_body_id = next(bid for bid in _body_ids(part["id"]) if bid != body_id)
    _assert_pure_translation(part["id"], body_id, new_body_id, 5.0)


def test_pattern_along_a_sketch_line_direction_succeeds():
    part, body_id = _boxy_part_and_body()
    axis_line = _create_standalone_direction_line(part["id"], x=50.0, y0=0.0, y1=10.0)
    response = _create_pattern(
        part["id"], [body_id], _sketch_line_direction(axis_line["sketch_id"], axis_line["line_id"]), 2, 7.0
    )
    assert response.status_code == 201
    new_body_id = next(bid for bid in _body_ids(part["id"]) if bid != body_id)
    _assert_pure_translation(part["id"], body_id, new_body_id, 7.0)


def test_two_direction_pattern_produces_a_grid():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(
        part["id"],
        [body_id],
        _fixed_axis_direction("x"),
        2,
        20.0,
        direction_2=_fixed_axis_direction("y"),
        count_2=2,
        spacing_2=30.0,
    )
    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 4  # seed + 3 new grid instances

    seed_ranges = _bbox_ranges(part["id"], body_id)
    shifts = set()
    for new_body_id in (bid for bid in body_ids if bid != body_id):
        new_ranges = _bbox_ranges(part["id"], new_body_id)
        dx = round(new_ranges[0][0] - seed_ranges[0][0], 6)
        dy = round(new_ranges[1][0] - seed_ranges[1][0], 6)
        shifts.add((dx, dy))
    assert shifts == {(20.0, 0.0), (0.0, 30.0), (20.0, 30.0)}


def test_list_features_includes_the_pattern():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0).json()

    features = client.get(f"/document/parts/{part['id']}/features").json()
    pattern_entries = {f["id"]: f for f in features if f["type"] == "pattern"}
    assert created["id"] in pattern_entries
    assert pattern_entries[created["id"]]["source_body_ids"] == [body_id]
    assert pattern_entries[created["id"]]["count_1"] == 3


# --- Rejections ------------------------------------------------------------


def test_zero_source_body_ids_is_rejected():
    part, _body_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], [], _fixed_axis_direction("x"), 3, 20.0)
    assert response.status_code == 422


def test_an_unknown_source_body_id_is_rejected():
    part, _body_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], ["no-such-body"], _fixed_axis_direction("x"), 3, 20.0)
    assert response.status_code == 400


def test_count_1_of_zero_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 0, 20.0)
    assert response.status_code == 422


def test_a_no_op_pattern_count_of_one_in_both_directions_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 1, 20.0)
    assert response.status_code == 422


def test_direction_2_is_required_when_count_2_is_greater_than_one():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 2, 20.0, count_2=2)
    assert response.status_code == 422


def test_direction_ref_with_no_fields_set_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(
        part["id"], [body_id], {"edge_ref": None, "sketch_line_ref": None, "fixed_axis": None}, 3, 20.0
    )
    assert response.status_code == 422


def test_direction_ref_with_two_fields_set_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(
        part["id"],
        [body_id],
        {
            "edge_ref": {"body_id": body_id, "shape_type": "edge", "index": 0},
            "sketch_line_ref": None,
            "fixed_axis": "x",
        },
        3,
        20.0,
    )
    assert response.status_code == 422


def test_direction_edge_ref_must_have_shape_type_edge():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(
        part["id"],
        [body_id],
        {"edge_ref": {"body_id": body_id, "shape_type": "face", "index": 0}, "sketch_line_ref": None,
         "fixed_axis": None},
        3,
        20.0,
    )
    assert response.status_code == 422


def test_direction_edge_ref_with_unknown_body_is_a_missing_reference():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], [body_id], _edge_direction("no-such-body", 0), 3, 20.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


def test_a_curved_edge_direction_is_rejected_as_non_linear_edge():
    part = _create_part()
    sketch_feature = _create_circle_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])

    responses = [_create_pattern(part["id"], [body_id], _edge_direction(body_id, i), 2, 5.0) for i in range(6)]
    non_linear = [
        r for r in responses if r.status_code == 422 and r.json()["detail"].get("type") == "non_linear_edge"
    ]
    assert non_linear, "expected at least one curved edge on the cylinder rejected as non_linear_edge"


def test_sketch_line_ref_pointing_to_a_point_is_rejected_as_invalid_direction_ref():
    part, body_id = _boxy_part_and_body()
    axis_line = _create_standalone_direction_line(part["id"], x=50.0, y0=0.0, y1=10.0)
    point = _add_point(axis_line["sketch_id"], 50.0, 20.0)
    bad_direction = _sketch_line_direction(axis_line["sketch_id"], point["id"])
    response = _create_pattern(part["id"], [body_id], bad_direction, 2, 7.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_direction_ref"


def test_sketch_line_ref_with_unknown_entity_id_is_rejected_as_invalid_direction_ref():
    part, body_id = _boxy_part_and_body()
    axis_line = _create_standalone_direction_line(part["id"], x=50.0, y0=0.0, y1=10.0)
    bad_direction = _sketch_line_direction(axis_line["sketch_id"], "no-such-line")
    response = _create_pattern(part["id"], [body_id], bad_direction, 2, 7.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_direction_ref"


# --- Editing / rollback ------------------------------------------------------


def test_patch_updates_the_pattern_and_the_mesh_reflects_it():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0).json()

    patch_response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}",
        json={"count_1": 4},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["count_1"] == 4

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 4  # seed + 3 new instances now


def test_patch_re_validates_the_merged_candidate_and_rejects_an_invalid_count():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0).json()

    patch_response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}",
        json={"count_1": 0},
    )
    assert patch_response.status_code == 422

    # A rejected PATCH must never leave the Feature half-updated.
    features = client.get(f"/document/parts/{part['id']}/features").json()
    pattern_entry = next(f for f in features if f["id"] == created["id"])
    assert pattern_entry["count_1"] == 3


def test_patch_can_edit_an_earlier_pattern_via_rollback_style_editing():
    """B4: any Feature can be edited, not just the last one - editing this
    Pattern's count after a later, unrelated Feature has been added must
    still resolve correctly."""
    part, body_id = _boxy_part_and_body()
    created = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0).json()

    other_sketch = _create_square_sketch_feature(part["id"], x0=200.0, y0=200.0)
    _create_extrude_feature(part["id"], other_sketch["id"])

    patch_response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}",
        json={"count_1": 2},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["count_1"] == 2


# --- Cascade delete ------------------------------------------------------------


def test_cascade_deleting_the_owning_extrude_takes_the_pattern_with_it():
    part, body_id = _boxy_part_and_body()
    extrude_feature_id = body_id
    pattern = _create_pattern(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{extrude_feature_id}/cascade")
    assert response.status_code == 200
    assert pattern["id"] in response.json()["deleted_feature_ids"]

    features = client.get(f"/document/parts/{part['id']}/features").json()
    assert all(f["id"] != pattern["id"] for f in features)


def test_cascade_deleting_the_sketch_owning_a_sketch_line_direction_takes_the_pattern_with_it():
    part, body_id = _boxy_part_and_body()
    axis_line = _create_standalone_direction_line(part["id"], x=50.0, y0=0.0, y1=10.0)
    axis_sketch_feature_id = None
    for feature in client.get(f"/document/parts/{part['id']}/features").json():
        if feature["type"] == "sketch" and feature["sketch_id"] == axis_line["sketch_id"]:
            axis_sketch_feature_id = feature["id"]
    assert axis_sketch_feature_id is not None

    pattern = _create_pattern(
        part["id"], [body_id], _sketch_line_direction(axis_line["sketch_id"], axis_line["line_id"]), 2, 7.0
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{axis_sketch_feature_id}/cascade")
    assert response.status_code == 200
    assert pattern["id"] in response.json()["deleted_feature_ids"]
