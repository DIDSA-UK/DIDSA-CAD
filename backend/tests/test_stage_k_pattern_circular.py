"""Pattern/Mirror scoping's Phase 4 (`docs/pattern-mirror-scope.md` §2.3/
§2.7/§4): real-OCCT tests for Circular Pattern's full router/HTTP surface -
mirrors test_stage_j_pattern.py's own structure, substituting `axis`/
`count_angular`/`angle_total`/`reverse_angular` for Rectangular's own
`direction_1`/`count_1`/`spacing_1`. All touch `app.main`/`app.document.
pattern`/`app.document.extrude`/`app.document.create_plane`, which import
OCC.Core directly, so (per the recurring caveat in docs/status.md) these
are `ast.parse`-verified/manually reviewed only in this sandbox, same as
every other OCCT-touching backend prompt in this project until real CI
runs it.
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


def _create_ellipse_sketch_feature(
    part_id: str, *, major_radius: float = 10.0, minor_radius: float = 5.0, plane="XY"
) -> dict:
    """An Ellipse-profile Sketch, extruded to a Body whose curved
    boundary edges are elliptical (`GeomAbs_Ellipse`) - neither circular
    nor straight, so a genuinely unsupported `axis` `edge_ref` shape for
    `_axis_from_ref`'s rejection test below."""
    feature = _create_sketch_feature(part_id, plane)
    center = _add_point(feature["sketch_id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{feature['sketch_id']}/ellipses",
        json={
            "center_point_id": center["id"],
            "major_radius": major_radius,
            "angle": 0.0,
            "minor_radius": minor_radius,
        },
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


def _cylinder_part_and_body(*, radius: float = 20.0) -> tuple[dict, str]:
    part = _create_part()
    sketch_feature = _create_circle_sketch_feature(part["id"], radius=radius)
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


def _edge_axis(body_id: str, index: int) -> dict:
    return {"edge_ref": {"body_id": body_id, "shape_type": "edge", "index": index}, "face_ref": None,
            "sketch_line_ref": None}


def _face_axis(body_id: str, index: int) -> dict:
    return {"edge_ref": None, "face_ref": {"body_id": body_id, "shape_type": "face", "index": index},
            "sketch_line_ref": None}


def _sketch_line_axis(sketch_id: str, entity_id: str) -> dict:
    return {
        "edge_ref": None,
        "face_ref": None,
        "sketch_line_ref": {"sketch_id": sketch_id, "entity_type": "line", "entity_id": entity_id},
    }


def _create_standalone_axis_line(part_id: str, *, x: float, y0: float, y1: float, plane="XY") -> dict:
    """A Sketch containing just one Line, usable as a Circular Pattern axis
    - through `(x, y0)`/`(x, y1)`, both in the sketch's own local 2D
    coordinates. For `plane="XY"` and `x=0.0`, this is the world Y axis
    (not Z) - see individual tests for which axis a given call actually
    produces in world space."""
    feature = _create_sketch_feature(part_id, plane)
    p0 = _add_point(feature["sketch_id"], x, y0)
    p1 = _add_point(feature["sketch_id"], x, y1)
    line = _add_line(feature["sketch_id"], p0["id"], p1["id"])
    return {"sketch_id": feature["sketch_id"], "line_id": line["id"]}


def _create_pattern_circular(
    part_id: str,
    source_body_ids: list[str],
    axis: dict | None,
    count_angular: int,
    *,
    angle_total: float = 360.0,
    reverse_angular: bool = False,
):
    return client.post(
        f"/document/parts/{part_id}/pattern-features",
        json={
            "source_body_ids": source_body_ids,
            "pattern_type": "circular",
            "axis": axis,
            "count_angular": count_angular,
            "angle_total": angle_total,
            "reverse_angular": reverse_angular,
        },
    )


def _first_circular_edge_index(part_id: str, body_id: str, *, probe_count: int = 12) -> int:
    """Brute-forces which edge index on `body_id` is a genuinely circular
    edge running through the Body's own true centre axis - mirrors
    test_stage_c4_create_plane.py's own edge-index brute force (exact
    index-to-topological-feature correspondence isn't part of this API's
    contract), but (Pattern/Mirror Phase 4 revision) can no longer accept
    success alone as proof of circularity: a straight seam edge - which
    every OCCT circular extrusion has, connecting its top/bottom circular
    caps along the surface's own parametric seam - is now ALSO a valid,
    but off-axis, `edge_ref` (see `test_a_straight_edge_axis_...` below),
    and would otherwise be picked up first. Verified instead by self-
    patterning `body_id` around the candidate edge and checking the
    resulting new instance's own bounding box is still centred near the
    world origin in X/Y - true only when the axis is the Body's own true
    centre (every current caller's own cylinder is itself centred at
    (0, 0)), never for an off-centre seam edge, whose rotation visibly
    shifts the whole Body's bounding box away from the origin."""
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


def _first_cylindrical_face_index(part_id: str, body_id: str, *, probe_count: int = 8) -> int:
    for index in range(probe_count):
        response = _create_pattern_circular(part_id, [body_id], _face_axis(body_id, index), 4)
        if response.status_code == 201:
            client.delete(f"/document/parts/{part_id}/features/{response.json()['id']}/cascade")
            return index
    raise AssertionError("expected at least one cylindrical face")


_STRAIGHT_EDGE_AXIS_Z_QUADRANT_POSITIONS = {
    ((30.0, 35.0), (0.0, 5.0)),
    ((-5.0, 0.0), (30.0, 35.0)),
    ((-35.0, -30.0), (-5.0, 0.0)),
    ((0.0, 5.0), (-35.0, -30.0)),
}


def _first_straight_edge_axis_index_through_world_z(
    part_id: str, axis_body_id: str, target_body_id: str, *, probe_count: int = 12
) -> int:
    """Brute-forces which straight edge index on `axis_body_id` is the
    vertical edge running exactly along the world Z axis (through the
    origin) - not by guessing the topological index (edge-index-to-
    geometry correspondence isn't part of this API's contract, same
    reasoning as `_first_circular_edge_index`), but by actually performing
    the circular pattern for each candidate and checking the resulting
    quadrant positions exactly match a clean 90-degree-step rotation of
    `target_body_id` about the true Z axis. `axis_body_id` is expected to
    be a box whose own `(x0=0, y0=0)` corner sits at the world origin (see
    `test_circular_pattern_via_a_straight_edge_axis_succeeds_and_rotates_
    correctly`) - its *other* three vertical corner edges, and its
    horizontal (X/Y-parallel) edges, are all straight too and so are all
    individually valid `edge_ref` axes now, just not ones producing this
    exact quadrant set, so this probe skips right past them rather than
    treating a mismatch as a failure."""
    for index in range(probe_count):
        response = _create_pattern_circular(part_id, [target_body_id], _edge_axis(axis_body_id, index), 4)
        if response.status_code != 201:
            continue
        feature_id = response.json()["id"]
        # Includes target_body_id itself - the seed keeps its own id and
        # occupies one of the 4 quadrant positions unrotated, exactly like
        # `test_circular_pattern_around_a_z_axis_produces_the_expected_
        # quadrant_positions`'s own `box_body_ids` convention above.
        positions = {
            _rounded_xy_ranges(part_id, bid) for bid in _body_ids(part_id) if bid != axis_body_id
        }
        client.delete(f"/document/parts/{part_id}/features/{feature_id}/cascade")
        if positions == _STRAIGHT_EDGE_AXIS_Z_QUADRANT_POSITIONS:
            return index
    raise AssertionError("expected a straight edge axis producing a clean world-Z-axis rotation")


# --- Success -------------------------------------------------------------------


def test_circular_pattern_via_a_circular_edge_axis_succeeds():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    response = _create_pattern_circular(part["id"], [body_id], _edge_axis(body_id, edge_index), 4)
    assert response.status_code == 201
    feature = response.json()
    assert feature["type"] == "pattern"
    assert feature["pattern_type"] == "circular"
    assert feature["source_body_ids"] == [body_id]
    assert feature["produces"] == "body"

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 4  # seed + 3 new instances


def test_circular_pattern_via_a_cylindrical_face_axis_succeeds():
    part, body_id = _cylinder_part_and_body()
    face_index = _first_cylindrical_face_index(part["id"], body_id)
    response = _create_pattern_circular(part["id"], [body_id], _face_axis(body_id, face_index), 4)
    assert response.status_code == 201
    assert len(_body_ids(part["id"])) == 4


def test_circular_pattern_around_a_z_axis_produces_the_expected_quadrant_positions():
    """The rigorous geometric check: a small box offset along +X, circular-
    patterned 4 ways (90 degrees apart) around a real world Z axis (supplied
    by a *different* Body's own circular edge - a cylinder centred at the
    origin, extruded along Z) must land its axis-aligned bounding box in
    exactly the 4 quadrant positions a clean 90-degree-step rotation about Z
    through the origin implies - regardless of which rotation direction OCCT
    actually uses (never assumed - see this test's own set-based assertion)."""
    part = _create_part()
    cylinder_sketch = _create_circle_sketch_feature(part["id"], radius=20.0)
    _create_extrude_feature(part["id"], cylinder_sketch["id"])
    cylinder_body_id = _first_body_id(part["id"])
    edge_index = _first_circular_edge_index(part["id"], cylinder_body_id)

    box_sketch = _create_square_sketch_feature(part["id"], x0=30.0, y0=0.0, size=5.0)
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = next(bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id)

    response = _create_pattern_circular(
        part["id"], [box_body_id], _edge_axis(cylinder_body_id, edge_index), 4
    )
    assert response.status_code == 201

    box_body_ids = [bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id]
    assert len(box_body_ids) == 4  # seed box + 3 new instances

    actual_positions = {_rounded_xy_ranges(part["id"], bid) for bid in box_body_ids}
    expected_positions = {
        ((30.0, 35.0), (0.0, 5.0)),
        ((-5.0, 0.0), (30.0, 35.0)),
        ((-35.0, -30.0), (-5.0, 0.0)),
        ((0.0, 5.0), (-35.0, -30.0)),
    }
    assert actual_positions == expected_positions


def test_reverse_angular_swaps_the_first_and_third_quarter_instances():
    """With 4 equally-spaced instances, reversing the rotation direction
    swaps which quadrant instance 1 (90 degrees) vs. instance 3 (270
    degrees) lands in, while instance 2 (180 degrees, the midpoint) is
    unaffected - a precise, direction-aware check complementing the
    direction-agnostic set check above."""
    part = _create_part()
    cylinder_sketch = _create_circle_sketch_feature(part["id"], radius=20.0)
    _create_extrude_feature(part["id"], cylinder_sketch["id"])
    cylinder_body_id = _first_body_id(part["id"])
    edge_index = _first_circular_edge_index(part["id"], cylinder_body_id)

    box_sketch = _create_square_sketch_feature(part["id"], x0=30.0, y0=0.0, size=5.0)
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = next(bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id)

    forward = _create_pattern_circular(
        part["id"], [box_body_id], _edge_axis(cylinder_body_id, edge_index), 4
    ).json()
    forward_positions = {
        bid: _rounded_xy_ranges(part["id"], bid)
        for bid in _body_ids(part["id"])
        if bid not in (cylinder_body_id, box_body_id)
    }
    client.delete(f"/document/parts/{part['id']}/features/{forward['id']}/cascade")

    reversed_response = _create_pattern_circular(
        part["id"], [box_body_id], _edge_axis(cylinder_body_id, edge_index), 4, reverse_angular=True
    )
    assert reversed_response.status_code == 201
    reversed_positions = {
        bid: _rounded_xy_ranges(part["id"], bid)
        for bid in _body_ids(part["id"])
        if bid not in (cylinder_body_id, box_body_id)
    }

    # The 180-degree instance's position must be identical either way; the
    # overall *set* of 4 quadrant positions (seed + 3 new) must also be
    # identical either way (reversing only permutes which index lands in
    # which quadrant, never changes which quadrants are used).
    assert set(forward_positions.values()) == set(reversed_positions.values())


def test_a_partial_angle_total_produces_the_expected_single_instance_position():
    """angle_total=180, count_angular=2 -> one new instance at exactly a
    90-degree step (the same clean, direction-agnostic-checkable rotation
    the full-360 test above uses, just reached via a different angle_total/
    count_angular combination)."""
    part = _create_part()
    cylinder_sketch = _create_circle_sketch_feature(part["id"], radius=20.0)
    _create_extrude_feature(part["id"], cylinder_sketch["id"])
    cylinder_body_id = _first_body_id(part["id"])
    edge_index = _first_circular_edge_index(part["id"], cylinder_body_id)

    box_sketch = _create_square_sketch_feature(part["id"], x0=30.0, y0=0.0, size=5.0)
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = next(bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id)

    response = _create_pattern_circular(
        part["id"], [box_body_id], _edge_axis(cylinder_body_id, edge_index), 2, angle_total=180.0
    )
    assert response.status_code == 201

    box_body_ids = [bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id]
    assert len(box_body_ids) == 2  # seed + 1 new instance

    actual_positions = {_rounded_xy_ranges(part["id"], bid) for bid in box_body_ids}
    expected_positions = {
        ((30.0, 35.0), (0.0, 5.0)),
        ((-5.0, 0.0), (30.0, 35.0)),
    }
    assert actual_positions == expected_positions


def test_circular_pattern_via_a_sketch_line_axis_succeeds():
    part, body_id = _boxy_part_and_body(x0=30.0, y0=0.0, size=5.0)
    axis_line = _create_standalone_axis_line(part["id"], x=0.0, y0=0.0, y1=10.0)
    response = _create_pattern_circular(
        part["id"], [body_id], _sketch_line_axis(axis_line["sketch_id"], axis_line["line_id"]), 4
    )
    assert response.status_code == 201
    assert len(_body_ids(part["id"])) == 4


def test_circular_pattern_via_a_straight_edge_axis_succeeds_and_rotates_correctly():
    """A straight Body edge is now (Pattern/Mirror Phase 4 revision) a
    valid Circular Pattern axis in its own right, not just a circular
    edge/cylindrical face - `_axis_from_ref` resolves it via the edge's
    own `gp_Lin` (`Location()`/`Direction()`), the same idea as a real
    axle running along that edge. Uses a dedicated axis-defining box whose
    `(x0=0, y0=0)` corner sits exactly at the world origin, so one of its
    4 vertical edges is exactly the world Z axis - brute-forced by index
    (edge-to-index correspondence isn't part of the API's contract) and
    verified with the same rigorous quadrant-position check the circular-
    edge-axis test above uses, rather than merely asserting success."""
    part = _create_part()
    axis_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0, size=10.0)
    _create_extrude_feature(part["id"], axis_sketch["id"], start_distance=0.0, end_distance=20.0)
    axis_body_id = _first_body_id(part["id"])

    box_sketch = _create_square_sketch_feature(part["id"], x0=30.0, y0=0.0, size=5.0)
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = next(bid for bid in _body_ids(part["id"]) if bid != axis_body_id)

    edge_index = _first_straight_edge_axis_index_through_world_z(part["id"], axis_body_id, box_body_id)

    response = _create_pattern_circular(part["id"], [box_body_id], _edge_axis(axis_body_id, edge_index), 4)
    assert response.status_code == 201
    assert response.json()["pattern_type"] == "circular"

    box_body_ids = [bid for bid in _body_ids(part["id"]) if bid != axis_body_id]
    assert len(box_body_ids) == 4  # seed + 3 new instances
    actual_positions = {_rounded_xy_ranges(part["id"], bid) for bid in box_body_ids}
    assert actual_positions == _STRAIGHT_EDGE_AXIS_Z_QUADRANT_POSITIONS


def test_list_features_includes_the_circular_pattern():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    created = _create_pattern_circular(part["id"], [body_id], _edge_axis(body_id, edge_index), 4).json()

    features = client.get(f"/document/parts/{part['id']}/features").json()
    pattern_entries = {f["id"]: f for f in features if f["type"] == "pattern"}
    assert created["id"] in pattern_entries
    assert pattern_entries[created["id"]]["pattern_type"] == "circular"
    assert pattern_entries[created["id"]]["count_angular"] == 4


def test_pattern_type_defaults_to_rectangular_when_omitted():
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/pattern-features",
        json={
            "source_body_ids": [body_id],
            "direction_1": {"edge_ref": None, "sketch_line_ref": None, "fixed_axis": "x"},
            "count_1": 3,
            "spacing_1": 20.0,
        },
    )
    assert response.status_code == 201
    assert response.json()["pattern_type"] == "rectangular"


# --- Rejections ------------------------------------------------------------


def test_circular_pattern_without_an_axis_is_rejected():
    part, body_id = _cylinder_part_and_body()
    response = _create_pattern_circular(part["id"], [body_id], None, 4)
    assert response.status_code == 422


def test_count_angular_of_one_is_rejected():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    response = _create_pattern_circular(part["id"], [body_id], _edge_axis(body_id, edge_index), 1)
    assert response.status_code == 422


def test_count_angular_of_zero_is_rejected():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    response = _create_pattern_circular(part["id"], [body_id], _edge_axis(body_id, edge_index), 0)
    assert response.status_code == 422


def test_angle_total_of_zero_is_rejected():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    response = _create_pattern_circular(
        part["id"], [body_id], _edge_axis(body_id, edge_index), 4, angle_total=0.0
    )
    assert response.status_code == 422


def test_angle_total_over_360_is_rejected():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    response = _create_pattern_circular(
        part["id"], [body_id], _edge_axis(body_id, edge_index), 4, angle_total=361.0
    )
    assert response.status_code == 422


def test_axis_with_no_fields_set_is_rejected():
    part, body_id = _cylinder_part_and_body()
    response = _create_pattern_circular(
        part["id"], [body_id], {"edge_ref": None, "face_ref": None, "sketch_line_ref": None}, 4
    )
    assert response.status_code == 422


def test_axis_with_two_fields_set_is_rejected():
    part, body_id = _cylinder_part_and_body()
    response = _create_pattern_circular(
        part["id"],
        [body_id],
        {
            "edge_ref": {"body_id": body_id, "shape_type": "edge", "index": 0},
            "face_ref": {"body_id": body_id, "shape_type": "face", "index": 0},
            "sketch_line_ref": None,
        },
        4,
    )
    assert response.status_code == 422


def test_axis_edge_ref_must_have_shape_type_edge():
    part, body_id = _cylinder_part_and_body()
    response = _create_pattern_circular(
        part["id"],
        [body_id],
        {"edge_ref": {"body_id": body_id, "shape_type": "face", "index": 0}, "face_ref": None,
         "sketch_line_ref": None},
        4,
    )
    assert response.status_code == 422


def test_axis_face_ref_must_have_shape_type_face():
    part, body_id = _cylinder_part_and_body()
    response = _create_pattern_circular(
        part["id"],
        [body_id],
        {"edge_ref": None, "face_ref": {"body_id": body_id, "shape_type": "edge", "index": 0},
         "sketch_line_ref": None},
        4,
    )
    assert response.status_code == 422


def test_an_elliptical_edge_axis_is_rejected_as_unsupported_axis_edge():
    """A straight edge and a circular edge are both valid axis sources
    now (see `test_circular_pattern_via_a_straight_edge_axis_succeeds_
    and_rotates_correctly`), but an edge that's neither - e.g. an
    Ellipse-profile extrusion's own elliptical boundary edges - still has
    no single well-defined axis and is rejected."""
    part = _create_part()
    ellipse_sketch = _create_ellipse_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], ellipse_sketch["id"])
    body_id = _first_body_id(part["id"])

    found_unsupported = None
    for index in range(8):
        response = _create_pattern_circular(part["id"], [body_id], _edge_axis(body_id, index), 4)
        if response.status_code == 422 and response.json()["detail"].get("type") == "unsupported_axis_edge":
            found_unsupported = index
            break
    assert found_unsupported is not None


def test_a_planar_face_axis_is_rejected_as_non_cylindrical_face():
    part, body_id = _boxy_part_and_body()
    # A box's 6 faces are all planar - any index is non-cylindrical.
    response = _create_pattern_circular(part["id"], [body_id], _face_axis(body_id, 0), 4)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "non_cylindrical_face"


def test_axis_sketch_line_ref_pointing_to_a_point_is_rejected_as_invalid_axis_ref():
    part, body_id = _cylinder_part_and_body()
    axis_line = _create_standalone_axis_line(part["id"], x=0.0, y0=0.0, y1=10.0)
    point = _add_point(axis_line["sketch_id"], 5.0, 5.0)
    bad_axis = _sketch_line_axis(axis_line["sketch_id"], point["id"])
    response = _create_pattern_circular(part["id"], [body_id], bad_axis, 4)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_axis_ref"


def test_rectangular_pattern_without_direction_1_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/pattern-features",
        json={
            "source_body_ids": [body_id],
            "pattern_type": "rectangular",
            "count_1": 3,
            "spacing_1": 20.0,
        },
    )
    assert response.status_code == 422


# --- Editing / rollback ------------------------------------------------------


def test_patch_updates_count_angular_and_the_mesh_reflects_it():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    created = _create_pattern_circular(part["id"], [body_id], _edge_axis(body_id, edge_index), 4).json()

    patch_response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}",
        json={"count_angular": 6},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["count_angular"] == 6
    assert len(_body_ids(part["id"])) == 6


def test_patch_re_validates_and_rejects_an_invalid_count_angular():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    created = _create_pattern_circular(part["id"], [body_id], _edge_axis(body_id, edge_index), 4).json()

    patch_response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}",
        json={"count_angular": 1},
    )
    assert patch_response.status_code == 422

    features = client.get(f"/document/parts/{part['id']}/features").json()
    pattern_entry = next(f for f in features if f["id"] == created["id"])
    assert pattern_entry["count_angular"] == 4


def test_patch_can_edit_an_earlier_circular_pattern_via_rollback_style_editing():
    part, body_id = _cylinder_part_and_body()
    edge_index = _first_circular_edge_index(part["id"], body_id)
    created = _create_pattern_circular(part["id"], [body_id], _edge_axis(body_id, edge_index), 4).json()

    other_sketch = _create_square_sketch_feature(part["id"], x0=200.0, y0=200.0)
    _create_extrude_feature(part["id"], other_sketch["id"])

    patch_response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{created['id']}",
        json={"count_angular": 3},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["count_angular"] == 3


# --- Cascade delete ------------------------------------------------------------


def test_cascade_deleting_the_owning_extrude_of_the_axis_body_takes_the_pattern_with_it():
    """The axis (a cylinder's own circular edge) belongs to a *different*
    Body than the one being patterned - deleting the cylinder's own owning
    ExtrudeFeature must still cascade-delete the Pattern, confirming the
    axis dependency edge (not just the source Body's own)."""
    part = _create_part()
    cylinder_sketch = _create_circle_sketch_feature(part["id"], radius=20.0)
    cylinder_extrude = _create_extrude_feature(part["id"], cylinder_sketch["id"])
    cylinder_body_id = _first_body_id(part["id"])
    edge_index = _first_circular_edge_index(part["id"], cylinder_body_id)

    box_sketch = _create_square_sketch_feature(part["id"], x0=30.0, y0=0.0, size=5.0)
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = next(bid for bid in _body_ids(part["id"]) if bid != cylinder_body_id)

    pattern = _create_pattern_circular(
        part["id"], [box_body_id], _edge_axis(cylinder_body_id, edge_index), 4
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{cylinder_extrude['id']}/cascade")
    assert response.status_code == 200
    assert pattern["id"] in response.json()["deleted_feature_ids"]


def test_cascade_deleting_the_sketch_owning_a_sketch_line_axis_takes_the_pattern_with_it():
    part, body_id = _boxy_part_and_body(x0=30.0, y0=0.0, size=5.0)
    axis_line = _create_standalone_axis_line(part["id"], x=0.0, y0=0.0, y1=10.0)
    axis_sketch_feature_id = None
    for feature in client.get(f"/document/parts/{part['id']}/features").json():
        if feature["type"] == "sketch" and feature["sketch_id"] == axis_line["sketch_id"]:
            axis_sketch_feature_id = feature["id"]
    assert axis_sketch_feature_id is not None

    pattern = _create_pattern_circular(
        part["id"], [body_id], _sketch_line_axis(axis_line["sketch_id"], axis_line["line_id"]), 4
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{axis_sketch_feature_id}/cascade")
    assert response.status_code == 200
    assert pattern["id"] in response.json()["deleted_feature_ids"]
