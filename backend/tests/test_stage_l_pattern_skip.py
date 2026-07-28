"""Pattern/Mirror scoping's Phase 3 (`docs/pattern-mirror-scope.md` §2.4/
§4): real-OCCT tests for `skip_indices` - suppressing individual pattern
instances by their own linear index, for both Rectangular and Circular
`PatternFeature`s (Phase 3 was implemented after Phase 4 - see this doc's
own Phase 3/4 status notes - so both construction methods already exist
and both need coverage here, not just Rectangular). Mirrors
test_stage_j_pattern.py/test_stage_k_pattern_circular.py's own structure
and helpers. All touch `app.main`/`app.document.pattern`/`app.document.
extrude`/`app.document.create_plane`, which import OCC.Core directly, so
(per the recurring caveat in docs/status.md) these are `ast.parse`-
verified/manually reviewed only in this sandbox, same as every other
OCCT-touching backend prompt in this project until real CI runs it.
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
    direction_2: dict | None = None,
    count_2: int = 1,
    spacing_2: float = 0.0,
    skip_indices: list[int] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/pattern-features",
        json={
            "source_body_ids": source_body_ids,
            "pattern_type": "rectangular",
            "direction_1": direction_1,
            "count_1": count_1,
            "spacing_1": spacing_1,
            "direction_2": direction_2,
            "count_2": count_2,
            "spacing_2": spacing_2,
            "skip_indices": skip_indices or [],
        },
    )


def _create_pattern_circular(
    part_id: str,
    source_body_ids: list[str],
    axis: dict | None,
    count_angular: int,
    *,
    angle_total: float = 360.0,
    skip_indices: list[int] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/pattern-features",
        json={
            "source_body_ids": source_body_ids,
            "pattern_type": "circular",
            "axis": axis,
            "count_angular": count_angular,
            "angle_total": angle_total,
            "skip_indices": skip_indices or [],
        },
    )


def _first_circular_edge_index(part_id: str, body_id: str, *, probe_count: int = 12) -> int:
    """Brute-forces a genuinely circular edge index on `body_id` - mirrors
    test_stage_k_pattern_circular.py's own identical helper (see that
    module for why success alone no longer implies circularity, now that
    a straight edge is also a valid axis)."""
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


# --- Rectangular: success ------------------------------------------------------


def test_skipping_a_rectangular_instance_produces_one_fewer_body():
    part, body_id = _boxy_part_and_body()
    # A 2x2 grid (indices 0..3) with index 2 skipped: seed (0) + 1 + 3 = 3 bodies.
    response = _create_pattern_rectangular(
        part["id"],
        [body_id],
        _fixed_axis_direction("x"),
        2,
        20.0,
        direction_2=_fixed_axis_direction("y"),
        count_2=2,
        spacing_2=20.0,
        skip_indices=[2],
    )
    assert response.status_code == 201
    feature = response.json()
    assert feature["skip_indices"] == [2]
    assert len(_body_ids(part["id"])) == 3


def test_skipping_every_new_rectangular_instance_leaves_only_the_seed():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[1, 2]
    )
    assert response.status_code == 201
    assert _body_ids(part["id"]) == [body_id]


def test_list_features_includes_rectangular_skip_indices():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[1]
    ).json()

    features = client.get(f"/document/parts/{part['id']}/features").json()
    pattern_entries = {f["id"]: f for f in features if f["type"] == "pattern"}
    assert pattern_entries[created["id"]]["skip_indices"] == [1]


# --- Circular: success -----------------------------------------------------


def test_skipping_a_circular_instance_produces_one_fewer_body():
    part, body_id = _create_part(), None
    cylinder_sketch = _create_circle_sketch_feature(part["id"], radius=20.0)
    _create_extrude_feature(part["id"], cylinder_sketch["id"])
    cylinder_body_id = _first_body_id(part["id"])
    edge_index = _first_circular_edge_index(part["id"], cylinder_body_id)

    box_sketch = _create_square_sketch_feature(part["id"], x0=30.0, y0=0.0, size=5.0)
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = next(bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id)

    response = _create_pattern_circular(
        part["id"], [box_body_id], _edge_axis(cylinder_body_id, edge_index), 4, skip_indices=[2]
    )
    assert response.status_code == 201
    assert response.json()["skip_indices"] == [2]

    box_body_ids = [bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id]
    assert len(box_body_ids) == 3  # seed + 1 + 3 (index 2 skipped)


def test_skipping_the_180_degree_circular_instance_leaves_the_expected_quadrant_positions():
    """Index 2 (of 4, 90-degree steps) is always exactly 180 degrees from
    the seed - diametrically opposite regardless of which rotation
    direction OCCT actually uses (the same direction-agnostic reasoning
    test_stage_k_pattern_circular.py's own quadrant test relies on: a
    CW-vs-CCW sweep only permutes which index lands in which *other*
    quadrant, but 180 degrees is always the same point either way).
    Skipping it therefore has a single, fully-predictable expected
    outcome: the seed's own quadrant plus the two "side" quadrants,
    minus the one diametrically opposite the seed."""
    part = _create_part()
    cylinder_sketch = _create_circle_sketch_feature(part["id"], radius=20.0)
    _create_extrude_feature(part["id"], cylinder_sketch["id"])
    cylinder_body_id = _first_body_id(part["id"])
    edge_index = _first_circular_edge_index(part["id"], cylinder_body_id)

    box_sketch = _create_square_sketch_feature(part["id"], x0=30.0, y0=0.0, size=5.0)
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = next(bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id)

    response = _create_pattern_circular(
        part["id"], [box_body_id], _edge_axis(cylinder_body_id, edge_index), 4, skip_indices=[2]
    )
    assert response.status_code == 201

    box_body_ids = [bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id]
    assert len(box_body_ids) == 3
    actual_positions = {_rounded_xy_ranges(part["id"], bid) for bid in box_body_ids}
    # The full 4-way set (see test_stage_k_pattern_circular.py) minus the
    # diametrically-opposite (180-degree) quadrant.
    expected_positions = {
        ((30.0, 35.0), (0.0, 5.0)),
        ((-5.0, 0.0), (30.0, 35.0)),
        ((0.0, 5.0), (-35.0, -30.0)),
    }
    assert actual_positions == expected_positions


# --- Editing / rollback -----------------------------------------------------


def test_patch_updates_skip_indices_and_mesh_reflects_it():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern_rectangular(part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0).json()
    assert len(_body_ids(part["id"])) == 3  # no skips yet

    response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}", json={"skip_indices": [1]}
    )
    assert response.status_code == 200
    assert response.json()["skip_indices"] == [1]
    assert len(_body_ids(part["id"])) == 2  # seed + index 2 only


def test_patch_omitting_skip_indices_leaves_existing_skips_unchanged():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[1]
    ).json()

    # Patch an unrelated field (reverse_1) without touching skip_indices.
    response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}", json={"reverse_1": True}
    )
    assert response.status_code == 200
    assert response.json()["skip_indices"] == [1]


def test_patch_with_empty_skip_indices_list_clears_all_skips():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[1, 2]
    ).json()
    assert len(_body_ids(part["id"])) == 1  # seed only, both new instances skipped

    response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}", json={"skip_indices": []}
    )
    assert response.status_code == 200
    assert response.json()["skip_indices"] == []
    assert len(_body_ids(part["id"])) == 3  # both instances restored


def test_patch_rejects_an_invalid_skip_index_and_leaves_the_original_unchanged():
    part, body_id = _boxy_part_and_body()
    created = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[1]
    ).json()

    response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}", json={"skip_indices": [99]}
    )
    assert response.status_code == 422

    # The original skip_indices=[1] must still be in effect.
    features = client.get(f"/document/parts/{part['id']}/features").json()
    pattern_entry = next(f for f in features if f["id"] == created["id"])
    assert pattern_entry["skip_indices"] == [1]
    assert len(_body_ids(part["id"])) == 2


# --- Rejections --------------------------------------------------------------


def test_skip_index_zero_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[0]
    )
    assert response.status_code == 422


def test_skip_index_at_total_count_is_rejected():
    part, body_id = _boxy_part_and_body()
    # count_1=3 -> valid indices are 0..2; 3 is out of range.
    response = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[3]
    )
    assert response.status_code == 422


def test_negative_skip_index_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_pattern_rectangular(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[-1]
    )
    assert response.status_code == 422


def test_circular_skip_index_at_or_above_count_angular_is_rejected():
    part = _create_part()
    cylinder_sketch = _create_circle_sketch_feature(part["id"], radius=20.0)
    _create_extrude_feature(part["id"], cylinder_sketch["id"])
    cylinder_body_id = _first_body_id(part["id"])
    edge_index = _first_circular_edge_index(part["id"], cylinder_body_id)

    response = _create_pattern_circular(
        part["id"], [cylinder_body_id], _edge_axis(cylinder_body_id, edge_index), 4, skip_indices=[4]
    )
    assert response.status_code == 422


def test_skip_indices_defaults_to_empty_when_omitted():
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/pattern-features",
        json={
            "source_body_ids": [body_id],
            "direction_1": _fixed_axis_direction("x"),
            "count_1": 3,
            "spacing_1": 20.0,
        },
    )
    assert response.status_code == 201
    assert response.json()["skip_indices"] == []
    assert len(_body_ids(part["id"])) == 3
