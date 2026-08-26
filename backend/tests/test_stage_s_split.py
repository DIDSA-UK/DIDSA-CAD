"""Boolean family, fourth/last entry: real-OCCT tests for `SplitFeature` -
divides one existing Body into two independent, surviving pieces along a
`plane_ref`, an existing `SurfaceFeature`, or a raw `sketch_line_ref`
(`app.document.split.resolve_split_pieces`'s own oversized-half-space-block
technique - see that module's own top-level docstring). Mirrors
test_stage_r_boolean.py's own structure/helpers (copy-pasted, not shared
via conftest, same as every other test_stage*.py file), plus the
THREE_POINTS vertex-picking helper from test_stage_c4_create_plane.py for
the non-axis-aligned-plane coverage below. Needs a real pythonocc-core
environment (not available in this repo's own dev sandbox - see
docs/status.md's dated entries for whether a real on-device/CI pass has
actually run by the time this is read).
"""

import itertools

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


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    mesh = next(e for e in _mesh(part_id) if e["body_id"] == body_id)["mesh"]
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _remaining_feature_ids(part_id: str) -> list[str]:
    return [f["id"] for f in client.get(f"/document/parts/{part_id}/features").json()]


def _make_box(
    part_id: str, *, x0: float = 0.0, y0: float = 0.0, size: float = 10.0, start_z=0.0, end_z=10.0
) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0),
    `start_z`..`end_z` in Z, and returns its own new Body id."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    response = _create_extrude_feature(part_id, sketch["id"], start_distance=start_z, end_distance=end_z)
    assert response.status_code == 201
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


def _create_split(part_id: str, target_body_id: str, tool: dict):
    return client.post(
        f"/document/parts/{part_id}/split-features",
        json={"target_body_id": target_body_id, "tool": tool},
    )


def _create_surface_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    start_distance: float = -5.0,
    end_distance: float = 5.0,
    direction_ref: dict | None = None,
) -> dict:
    payload = {
        "sketch_feature_id": sketch_feature_id,
        "start_distance": start_distance,
        "end_distance": end_distance,
    }
    if direction_ref is not None:
        payload["direction_ref"] = direction_ref
    response = client.post(f"/document/parts/{part_id}/surface-features", json=payload)
    assert response.status_code == 201
    return response.json()


def _vertex_point_ref(body_id: str, index: int) -> dict:
    return {"vertex_ref": {"body_id": body_id, "shape_type": "vertex", "index": index}}


def _create_three_points_plane(part_id: str, point_refs: list[dict]):
    return client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={"plane_type": "three_points", "point_refs": point_refs},
    )


def _add_arc(sketch_id: str, center_point_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/arcs",
        json={
            "center_point_id": center_point_id,
            "start_point_id": start_point_id,
            "end_point_id": end_point_id,
        },
    )
    assert response.status_code == 201
    return response.json()


def _add_spline(sketch_id: str, through_point_ids: list[str]) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/splines",
        json={"through_point_ids": through_point_ids},
    )
    assert response.status_code == 201
    return response.json()


def _sketch_line_ref(sketch_id: str, entity_type: str, entity_id: str) -> dict:
    return {"sketch_line_ref": {"sketch_id": sketch_id, "entity_type": entity_type, "entity_id": entity_id}}


def _feature_types(part_id: str) -> list[str]:
    return [f["type"] for f in client.get(f"/document/parts/{part_id}/features").json()]


def _first_tilted_three_vertex_plane(part_id: str, body_id: str) -> dict:
    """A plane through 3 real Body vertices, filtered to one whose own
    `normal` has all 3 components non-zero - i.e. genuinely tilted, not
    merely coincident with one of the box's own axis-aligned faces (a
    combination of 3 vertices sharing a face gives a normal with only one
    non-zero component). Brute-forces vertex-index combinations rather
    than assuming any particular index-to-corner correspondence, mirroring
    test_stage_c4_create_plane.py's own `_first_successful_three_vertex_
    plane` convention."""
    for combo in itertools.combinations(range(8), 3):
        point_refs = [_vertex_point_ref(body_id, i) for i in combo]
        response = _create_three_points_plane(part_id, point_refs)
        if response.status_code != 201:
            continue
        plane = response.json()
        if all(abs(c) > 1e-6 for c in plane["normal"]):
            return plane
    raise AssertionError("expected at least one non-axis-aligned vertex-triple plane on a box")


# --- Creation validation -------------------------------------------------------


def test_split_tool_with_neither_plane_ref_nor_surface_feature_id_is_rejected():
    part = _create_part()
    target_id = _make_box(part["id"])

    response = _create_split(part["id"], target_id, {})

    assert response.status_code == 422


def test_split_tool_with_both_plane_ref_and_surface_feature_id_is_rejected():
    part = _create_part()
    target_id = _make_box(part["id"])
    surface_sketch = _create_sketch_feature(part["id"], plane="XZ")
    _add_square(surface_sketch["sketch_id"], -20.0, -20.0, 40.0)
    surface = _create_surface_feature(part["id"], surface_sketch["id"])

    response = _create_split(
        part["id"],
        target_id,
        {"plane_ref": {"fixed_plane": "XY"}, "surface_feature_id": surface["id"]},
    )

    assert response.status_code == 422


def test_split_tool_with_plane_ref_and_sketch_line_ref_both_set_is_rejected():
    part = _create_part()
    target_id = _make_box(part["id"])
    line_sketch = _create_sketch_feature(part["id"], plane="XZ")
    p1 = _add_point(line_sketch["sketch_id"], -20.0, -20.0)
    p2 = _add_point(line_sketch["sketch_id"], 20.0, 20.0)
    line = _add_line(line_sketch["sketch_id"], p1["id"], p2["id"])

    response = _create_split(
        part["id"],
        target_id,
        {
            "plane_ref": {"fixed_plane": "XY"},
            **_sketch_line_ref(line_sketch["sketch_id"], "line", line["id"]),
        },
    )

    assert response.status_code == 422


def test_split_tool_with_sketch_line_ref_pointing_at_a_non_connectable_entity_type_is_rejected():
    """A typed-slot check, mirroring `edge_ref`/`face_ref`'s own
    `shape_type` checks - Circle/Ellipse/Point/Text are never connectable
    curves (see `app.document.split.CONNECTABLE_CURVE_ENTITY_TYPES`), so
    this must be rejected before ever trying to resolve the Sketch/entity
    at all."""
    part = _create_part()
    target_id = _make_box(part["id"])

    response = _create_split(
        part["id"], target_id, _sketch_line_ref("some-sketch-id", "circle", "some-entity-id")
    )

    assert response.status_code == 422


def test_split_with_unknown_target_body_id_is_rejected():
    part = _create_part()

    response = _create_split(part["id"], "not-a-real-feature-id", {"plane_ref": {"fixed_plane": "XY"}})

    assert response.status_code == 400


def test_split_with_surface_feature_id_not_referring_to_a_surface_feature_is_rejected():
    part = _create_part()
    target_id = _make_box(part["id"])
    other_body_id = _make_box(part["id"], x0=50.0)

    # `other_body_id`'s owning ExtrudeFeature id is a real Feature id in this
    # Part, just not a SurfaceFeature - must be rejected via isinstance, not
    # merely "does some Feature exist with this id".
    response = _create_split(part["id"], target_id, {"surface_feature_id": other_body_id})

    assert response.status_code == 400


def test_split_with_a_dangling_plane_face_ref_is_a_missing_reference():
    part = _create_part()
    target_id = _make_box(part["id"])

    response = _create_split(
        part["id"],
        target_id,
        {"plane_ref": {"face_ref": {"body_id": "no-such-body", "shape_type": "face", "index": 0}}},
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


# --- Split by Plane ------------------------------------------------------------


def test_split_by_a_fixed_plane_produces_two_independent_pieces():
    """A 10x10x20 box straddling z=0 (z in [-10, 10]), split by the fixed
    XY plane (normal +Z) - piece #0 (Common, the tool's own +Z side) should
    span z in [0, 10]; piece #1 (Cut, everything else) should span
    z in [-10, 0]."""
    part = _create_part()
    target_id = _make_box(part["id"], start_z=-10.0, end_z=10.0)

    response = _create_split(part["id"], target_id, {"plane_ref": {"fixed_plane": "XY"}})

    assert response.status_code == 201
    assert response.json()["type"] == "split"
    assert response.json()["target_body_id"] == target_id

    body_ids = _body_ids(part["id"])
    assert f"{target_id}#0" in body_ids
    assert f"{target_id}#1" in body_ids
    assert target_id not in body_ids

    _x, _y, z_range_0 = _bbox_ranges(part["id"], f"{target_id}#0")
    _x, _y, z_range_1 = _bbox_ranges(part["id"], f"{target_id}#1")
    assert z_range_0 == (0.0, 10.0)
    assert z_range_1 == (-10.0, 0.0)


def test_split_by_a_body_face_plane_ref():
    """Splitting by a Body face (rather than a fixed plane) - one of the
    tool box's own faces (any face whose plane actually crosses the
    target box's own z in [0, 20] straddles it into two real pieces; a
    face at z=0 or a side face at x/y=50+ doesn't) as the cutting plane.
    Tries every face index against a fresh target box each time (a
    box's own vertex/face indexing isn't part of this API's contract -
    same "don't assume index correspondence" convention `test_stage_c4_
    create_plane.py`'s own helpers already establish) until one produces
    a genuine two-piece split, rather than assuming the first resolvable
    face happens to be the one at z=10."""
    part = _create_part()
    tool_id = _make_box(part["id"], x0=50.0, start_z=0.0, end_z=10.0)

    for face_index in range(6):
        target_id = _make_box(part["id"], start_z=0.0, end_z=20.0)
        response = _create_split(
            part["id"],
            target_id,
            {"plane_ref": {"face_ref": {"body_id": tool_id, "shape_type": "face", "index": face_index}}},
        )
        if response.status_code == 201:
            body_ids = _body_ids(part["id"])
            if f"{target_id}#0" in body_ids and f"{target_id}#1" in body_ids:
                return
    raise AssertionError("expected at least one tool-box face to cleanly split the target box in two")


# --- Split by Surface ------------------------------------------------------------


def test_split_by_a_surface_feature_produces_two_independent_pieces():
    """A 20x20x10 target box straddling y=0 (y in [-10, 10], x in [0, 20],
    z in [0, 10]), split by a Surface built from a big rectangle sketched
    on the fixed XZ plane (normal +Y, anchored at y=0) - the surface's own
    profile is drawn generously past the target box's own x/z extent (see
    `app.document.split`'s own top-level docstring on why the Surface-tool
    case needs that). Piece #0 (Common, +Y side) should span y in [0, 10];
    piece #1 (Cut, -Y side) should span y in [-10, 0]."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)

    surface_sketch = _create_sketch_feature(part["id"], plane="XZ")
    _add_square(surface_sketch["sketch_id"], -30.0, -10.0, 40.0)
    surface = _create_surface_feature(part["id"], surface_sketch["id"])

    response = _create_split(part["id"], target_id, {"surface_feature_id": surface["id"]})

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert f"{target_id}#0" in body_ids
    assert f"{target_id}#1" in body_ids

    _x, y_range_0, _z = _bbox_ranges(part["id"], f"{target_id}#0")
    _x, y_range_1, _z = _bbox_ranges(part["id"], f"{target_id}#1")
    assert y_range_0 == (0.0, 10.0)
    assert y_range_1 == (-10.0, 0.0)


def test_split_by_a_surface_feature_with_an_open_chain_sketch_is_rejected_as_missing_reference():
    """An open-chain Surface has no closed profile to build a solid
    cutting block from - see `app.document.split._surface_block`'s own
    docstring."""
    part = _create_part()
    target_id = _make_box(part["id"])

    surface_sketch = _create_sketch_feature(part["id"], plane="XZ")
    p1 = _add_point(surface_sketch["sketch_id"], -20.0, -20.0)
    p2 = _add_point(surface_sketch["sketch_id"], 20.0, 20.0)
    _add_line(surface_sketch["sketch_id"], p1["id"], p2["id"])
    surface = _create_surface_feature(part["id"], surface_sketch["id"])

    response = _create_split(part["id"], target_id, {"surface_feature_id": surface["id"]})

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


# --- Split by a raw Sketch line/curve (no backing SurfaceFeature) --------------


def test_split_by_a_sketch_line_produces_two_independent_pieces_with_no_surface_feature_created():
    """The bug this whole `sketch_line_ref` tool kind replaces: extruding a
    picked Sketch line into a Surface first (the old inline "New Surface"
    mini-step) used to be the only way to Split along a raw Sketch curve,
    and silently failed for anything but a closed profile. A plain open
    Line, used directly, must now produce the same result a `plane_ref`/
    `surface_feature_id` Split would - and must not create any Feature
    beyond the SplitFeature itself, unlike the old mini-step it replaces.

    A 20x20x10 target box straddling y=0 (y in [-10, 10], x in [0, 20],
    z in [0, 10]), split by a short, diagonal Line sketched on the fixed XZ
    plane (normal +Y, anchored at y=0) - deliberately much smaller than the
    target box's own footprint (unlike the Surface-tool test's own
    generously-oversized square), to exercise `_sketch_line_block`'s own
    "cover the target regardless of the curve's own extent" contract. Since
    the Line is straight, this must produce exactly the same split as the
    fixed-XY-plane test: piece #0 (Common, +Y side) spans y in [0, 10];
    piece #1 (Cut, -Y side) spans y in [-10, 0]."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)

    line_sketch = _create_sketch_feature(part["id"], plane="XZ")
    p1 = _add_point(line_sketch["sketch_id"], 1.0, 0.0)
    p2 = _add_point(line_sketch["sketch_id"], 3.0, 2.0)
    line = _add_line(line_sketch["sketch_id"], p1["id"], p2["id"])
    features_before = _feature_types(part["id"])

    response = _create_split(
        part["id"], target_id, _sketch_line_ref(line_sketch["sketch_id"], "line", line["id"])
    )

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert f"{target_id}#0" in body_ids
    assert f"{target_id}#1" in body_ids

    x_range_0, y_range_0, z_range_0 = _bbox_ranges(part["id"], f"{target_id}#0")
    x_range_1, y_range_1, z_range_1 = _bbox_ranges(part["id"], f"{target_id}#1")
    assert y_range_0 == pytest.approx((0.0, 10.0), abs=1e-4)
    assert y_range_1 == pytest.approx((-10.0, 0.0), abs=1e-4)
    # Both pieces must still span the target box's own full x/z extent -
    # the Line itself is much smaller than the box, so this is really a
    # check that `_sketch_line_block`'s own closure comfortably covers the
    # target regardless of the curve's own (in this case tiny) extent,
    # rather than only covering a footprint as wide as the Line itself.
    assert x_range_0 == pytest.approx((0.0, 20.0), abs=1e-4)
    assert x_range_1 == pytest.approx((0.0, 20.0), abs=1e-4)
    assert z_range_0 == pytest.approx((0.0, 10.0), abs=1e-4)
    assert z_range_1 == pytest.approx((0.0, 10.0), abs=1e-4)

    features_after = _feature_types(part["id"])
    assert "surface" not in features_after
    assert features_after.count("split") == features_before.count("split") + 1


def test_split_by_a_sketch_arc_produces_two_pieces_that_reconstruct_the_original_bounds():
    """An Arc used directly as a Split tool - a genuinely curved cutting
    surface, not just a flat one. Center (10, 0), start (18, 0), end
    (2, 0): the CCW-from-start convention (`app.sketch.models.Arc`'s own
    docstring) sweeps the *top* semicircle, bulging up to (10, 8) - well
    inside the target box's own y in [-10, 10] and x in [0, 20] footprint,
    so the cutting surface genuinely intersects the box rather than
    grazing its boundary.

    Checked two ways: the two pieces' combined bounding box must
    reconstruct the original box exactly (same "nothing lost or
    duplicated outside the original bounds" check the tilted-plane
    robustness test already makes), and - proof the actual curved shape
    took effect, not just a flat split through the chord's own baseline -
    one of the two pieces' own y_max must be capped at the arc's own peak
    (y ~= 8) rather than reaching the box's own full y_max (10); which of
    the two pieces that is depends on this construction's own arbitrary
    "+v side" choice (see `_sketch_line_block`'s own docstring), so this
    checks the sorted pair rather than a specific piece index."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=20.0)
    original_bounds = _bbox_ranges(part["id"], target_id)

    arc_sketch = _create_sketch_feature(part["id"], plane="XY")
    center = _add_point(arc_sketch["sketch_id"], 10.0, 0.0)
    start = _add_point(arc_sketch["sketch_id"], 18.0, 0.0)
    end = _add_point(arc_sketch["sketch_id"], 2.0, 0.0)
    arc = _add_arc(arc_sketch["sketch_id"], center["id"], start["id"], end["id"])

    response = _create_split(
        part["id"], target_id, _sketch_line_ref(arc_sketch["sketch_id"], "arc", arc["id"])
    )

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert f"{target_id}#0" in body_ids
    assert f"{target_id}#1" in body_ids

    bounds_0 = _bbox_ranges(part["id"], f"{target_id}#0")
    bounds_1 = _bbox_ranges(part["id"], f"{target_id}#1")
    combined_bounds = [
        (min(bounds_0[axis][0], bounds_1[axis][0]), max(bounds_0[axis][1], bounds_1[axis][1]))
        for axis in range(3)
    ]
    for axis in range(3):
        assert combined_bounds[axis] == pytest.approx(original_bounds[axis], abs=1e-4)
    y_maxes = sorted([bounds_0[1][1], bounds_1[1][1]])
    assert y_maxes[0] == pytest.approx(8.0, abs=0.5)
    assert y_maxes[1] == pytest.approx(10.0, abs=1e-4)
    # Neither piece is clipped along z (the sketch's own normal/prism
    # axis) - both must still span the target box's own full z extent,
    # confirming the depth calc comfortably cleared the whole Body.
    assert bounds_0[2] == pytest.approx((0.0, 20.0), abs=1e-4)
    assert bounds_1[2] == pytest.approx((0.0, 20.0), abs=1e-4)

    features_after = _feature_types(part["id"])
    assert "surface" not in features_after


def test_split_by_a_sketch_spline_produces_two_pieces_that_reconstruct_the_original_bounds():
    """A Spline used directly as a Split tool - same "combined bounds
    reconstruct the original, nothing lost outside it" robustness check as
    the Arc case above, without re-asserting the exact bulge height (a
    Spline's own cubic-Bezier shape is a less exact target to assert
    against than a circular Arc's, and the tilted-plane/Arc tests already
    cover "the curved-boundary technique genuinely follows the curve" from
    both the coverage and shape-fidelity angles)."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)
    original_bounds = _bbox_ranges(part["id"], target_id)

    spline_sketch = _create_sketch_feature(part["id"], plane="XY")
    p1 = _add_point(spline_sketch["sketch_id"], 2.0, 0.0)
    p2 = _add_point(spline_sketch["sketch_id"], 10.0, 5.0)
    p3 = _add_point(spline_sketch["sketch_id"], 18.0, 0.0)
    spline = _add_spline(spline_sketch["sketch_id"], [p1["id"], p2["id"], p3["id"]])

    response = _create_split(
        part["id"], target_id, _sketch_line_ref(spline_sketch["sketch_id"], "spline", spline["id"])
    )

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert f"{target_id}#0" in body_ids
    assert f"{target_id}#1" in body_ids

    bounds_0 = _bbox_ranges(part["id"], f"{target_id}#0")
    bounds_1 = _bbox_ranges(part["id"], f"{target_id}#1")
    combined_bounds = [
        (min(bounds_0[axis][0], bounds_1[axis][0]), max(bounds_0[axis][1], bounds_1[axis][1]))
        for axis in range(3)
    ]
    for axis in range(3):
        assert combined_bounds[axis] == pytest.approx(original_bounds[axis], abs=1e-4)
    # Neither piece is clipped along z (the sketch's own normal/prism
    # axis) - both must still span the target box's own full z extent.
    assert bounds_0[2] == pytest.approx((0.0, 10.0), abs=1e-4)
    assert bounds_1[2] == pytest.approx((0.0, 10.0), abs=1e-4)

    features_after = _feature_types(part["id"])
    assert "surface" not in features_after


# --- Non-axis-aligned robustness -----------------------------------------------


def test_split_by_a_plane_not_aligned_with_the_target_bodys_bounding_box_axes():
    """The specific risk the oversized-half-space-block technique flagged
    up front: a cutting plane through 3 real vertices of a cube (tilted
    relative to every one of the cube's own bounding-box axes, not just an
    axis-aligned face) must still cleanly divide it into two pieces whose
    combined extent reconstructs the original cube's own bounding box - no
    lost or duplicated material outside the original bounds."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=0.0, size=20.0, start_z=0.0, end_z=20.0)
    original_bounds = _bbox_ranges(part["id"], target_id)

    plane = _first_tilted_three_vertex_plane(part["id"], target_id)

    response = _create_split(part["id"], target_id, {"plane_ref": {"plane_feature_id": plane["id"]}})

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert f"{target_id}#0" in body_ids
    assert f"{target_id}#1" in body_ids

    bounds_0 = _bbox_ranges(part["id"], f"{target_id}#0")
    bounds_1 = _bbox_ranges(part["id"], f"{target_id}#1")
    combined_bounds = [
        (min(bounds_0[axis][0], bounds_1[axis][0]), max(bounds_0[axis][1], bounds_1[axis][1]))
        for axis in range(3)
    ]
    for axis in range(3):
        assert combined_bounds[axis] == pytest.approx(original_bounds[axis], abs=1e-4)


# --- native_format round-trip ---------------------------------------------------


def test_split_by_plane_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        target_id = _make_box(part["id"], start_z=-10.0, end_z=10.0)
        split = _create_split(part["id"], target_id, {"plane_ref": {"fixed_plane": "XY"}}).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "split")
        assert round_tripped["target_body_id"] == split["target_body_id"] == target_id
        assert round_tripped["tool"]["plane_ref"]["fixed_plane"] == "XY"
        assert round_tripped["tool"]["surface_feature_id"] is None
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_split_by_surface_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)
        surface_sketch = _create_sketch_feature(part["id"], plane="XZ")
        _add_square(surface_sketch["sketch_id"], -30.0, -10.0, 40.0)
        surface = _create_surface_feature(part["id"], surface_sketch["id"])
        split = _create_split(part["id"], target_id, {"surface_feature_id": surface["id"]}).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "split")
        assert round_tripped["target_body_id"] == split["target_body_id"] == target_id
        assert round_tripped["tool"]["surface_feature_id"] == surface["id"]
        assert round_tripped["tool"]["plane_ref"] is None
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_split_by_sketch_line_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)
        line_sketch = _create_sketch_feature(part["id"], plane="XZ")
        p1 = _add_point(line_sketch["sketch_id"], 1.0, 0.0)
        p2 = _add_point(line_sketch["sketch_id"], 3.0, 2.0)
        line = _add_line(line_sketch["sketch_id"], p1["id"], p2["id"])
        tool = _sketch_line_ref(line_sketch["sketch_id"], "line", line["id"])
        split = _create_split(part["id"], target_id, tool).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "split")
        assert round_tripped["target_body_id"] == split["target_body_id"] == target_id
        assert round_tripped["tool"]["sketch_line_ref"] == tool["sketch_line_ref"]
        assert round_tripped["tool"]["plane_ref"] is None
        assert round_tripped["tool"]["surface_feature_id"] is None
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_the_target_bodys_owning_extrude_cascade_deletes_the_split_feature():
    part = _create_part()
    target_id = _make_box(part["id"], start_z=-10.0, end_z=10.0)
    split = _create_split(part["id"], target_id, {"plane_ref": {"fixed_plane": "XY"}}).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{target_id}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {target_id, split["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert split["id"] not in remaining
    assert target_id not in remaining


def test_deleting_the_referenced_plane_feature_cascade_deletes_the_split_feature():
    part = _create_part()
    target_id = _make_box(part["id"], start_z=-10.0, end_z=10.0)
    plane_response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [{"fixed_plane": "XY"}],
            "offset": 0.0,
        },
    )
    assert plane_response.status_code == 201
    plane = plane_response.json()
    split = _create_split(part["id"], target_id, {"plane_ref": {"plane_feature_id": plane["id"]}}).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{plane['id']}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {plane["id"], split["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert split["id"] not in remaining
    assert target_id in remaining


def test_deleting_the_referenced_surface_feature_cascade_deletes_the_split_feature():
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)
    surface_sketch = _create_sketch_feature(part["id"], plane="XZ")
    _add_square(surface_sketch["sketch_id"], -30.0, -10.0, 40.0)
    surface = _create_surface_feature(part["id"], surface_sketch["id"])
    split = _create_split(part["id"], target_id, {"surface_feature_id": surface["id"]}).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{surface['id']}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {surface["id"], split["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert split["id"] not in remaining
    assert target_id in remaining


def test_deleting_the_referenced_sketchs_owning_sketch_feature_cascade_deletes_the_split_feature():
    """The `sketch_line_ref` tool kind's own cascade-delete edge, mirroring
    the plane/surface cases above: deleting the SketchFeature that owns the
    referenced Sketch entity must take the SplitFeature with it, leaving
    the target Body's own owning Extrude alone."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)
    line_sketch = _create_sketch_feature(part["id"], plane="XZ")
    p1 = _add_point(line_sketch["sketch_id"], 1.0, 0.0)
    p2 = _add_point(line_sketch["sketch_id"], 3.0, 2.0)
    line = _add_line(line_sketch["sketch_id"], p1["id"], p2["id"])
    split = _create_split(
        part["id"], target_id, _sketch_line_ref(line_sketch["sketch_id"], "line", line["id"])
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{line_sketch['id']}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {line_sketch["id"], split["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert split["id"] not in remaining
    assert target_id in remaining


# --- Update endpoint -------------------------------------------------------------


def test_update_split_feature_switches_from_plane_to_surface_tool():
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)
    # XZ (normal +Y, origin at y=0) genuinely straddles the target box's own
    # y in [-10, 10] range, unlike YZ/XY here (both tangent to this box at
    # x=0/z=0 respectively) - avoids a degenerate zero-volume Common on the
    # very first create, before this test ever gets to the update it means
    # to cover.
    split = _create_split(part["id"], target_id, {"plane_ref": {"fixed_plane": "XZ"}}).json()

    surface_sketch = _create_sketch_feature(part["id"], plane="XZ")
    _add_square(surface_sketch["sketch_id"], -30.0, -10.0, 40.0)
    surface = _create_surface_feature(part["id"], surface_sketch["id"])

    response = client.patch(
        f"/document/parts/{part['id']}/split-features/{split['id']}",
        json={"tool": {"surface_feature_id": surface["id"]}},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["tool"]["surface_feature_id"] == surface["id"]
    assert body["tool"]["plane_ref"] is None
    assert body["target_body_id"] == target_id

    body_ids = _body_ids(part["id"])
    assert f"{target_id}#0" in body_ids
    assert f"{target_id}#1" in body_ids


def test_update_split_feature_switches_from_plane_to_sketch_line_tool():
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0, y0=-10.0, size=20.0, start_z=0.0, end_z=10.0)
    split = _create_split(part["id"], target_id, {"plane_ref": {"fixed_plane": "XZ"}}).json()

    line_sketch = _create_sketch_feature(part["id"], plane="XZ")
    p1 = _add_point(line_sketch["sketch_id"], 1.0, 0.0)
    p2 = _add_point(line_sketch["sketch_id"], 3.0, 2.0)
    line = _add_line(line_sketch["sketch_id"], p1["id"], p2["id"])
    tool = _sketch_line_ref(line_sketch["sketch_id"], "line", line["id"])

    response = client.patch(
        f"/document/parts/{part['id']}/split-features/{split['id']}",
        json={"tool": tool},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["tool"]["sketch_line_ref"] == tool["sketch_line_ref"]
    assert body["tool"]["plane_ref"] is None
    assert body["tool"]["surface_feature_id"] is None
    assert body["target_body_id"] == target_id

    body_ids = _body_ids(part["id"])
    assert f"{target_id}#0" in body_ids
    assert f"{target_id}#1" in body_ids
