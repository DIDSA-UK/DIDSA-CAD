"""Offset Entities v2 (on-device feedback: "offset should allow the
selection of multiple entities and should operate intuitively. eg offset
two connected lines results in two connected lines... if the origin lines
are connected, the offset lines should be connected effectively trimming
or extending the new lines to their intersect"):
`app.sketch.models.Sketch.offset_chain` and its own corner-join helper.

Entirely OCCT-free pure 2D math, same as `test_feature_offset_entities.py`
(this file's own single-entity sibling) - every test here runs for real in
this sandbox.
"""

import math

import pytest

from app.sketch.intersections import circle_vs_circle, line_vs_circle, line_vs_line
from app.sketch.models import Plane, Sketch


def _make_line(sketch: Sketch, x1, y1, x2, y2):
    p1 = sketch.add_point(x1, y1)
    p2 = sketch.add_point(x2, y2)
    return sketch.add_line(p1.id, p2.id)


def _make_arc(sketch: Sketch, cx, cy, radius, start_angle, end_angle):
    center = sketch.add_point(cx, cy)
    start = sketch.add_point(cx + radius * math.cos(start_angle), cy + radius * math.sin(start_angle))
    return sketch.add_arc(center.id, start.id, end_angle=end_angle)


def _make_circle(sketch: Sketch, cx, cy, radius):
    center = sketch.add_point(cx, cy)
    radius_point = sketch.add_point(cx + radius, cy)
    return sketch.add_circle(center.id, radius_point.id)


# --- line_vs_line (the one new pure-geometry primitive this feature adds) -


def test_line_vs_line_crosses_at_the_expected_point():
    assert line_vs_line((0.0, 0.0), (10.0, 0.0), (5.0, -5.0), (5.0, 5.0)) == pytest.approx((5.0, 0.0))


def test_line_vs_line_returns_none_for_parallel_lines():
    assert line_vs_line((0.0, 0.0), (10.0, 0.0), (0.0, 1.0), (10.0, 1.0)) is None


def test_line_vs_line_is_unclipped_unlike_line_vs_segment():
    # Both segments' own spans are nowhere near each other, but their
    # infinite extensions still cross - exactly the "extend the corner"
    # case offset_chain's join relies on.
    assert line_vs_line((0.0, 0.0), (1.0, 0.0), (5.0, -1.0), (5.0, 1.0)) == pytest.approx((5.0, 0.0))


# --- offset_chain: single-entity parity ------------------------------------


def test_offset_chain_matches_offset_line_for_a_single_lone_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    line = _make_line(sketch, 0.0, 0.0, 10.0, 0.0)

    [result] = sketch.offset_chain([line.id], 1.0)

    assert sketch.points[result.start_point_id].x == pytest.approx(0.0)
    assert sketch.points[result.start_point_id].y == pytest.approx(1.0)
    assert sketch.points[result.end_point_id].x == pytest.approx(10.0)
    assert sketch.points[result.end_point_id].y == pytest.approx(1.0)


def test_offset_chain_matches_offset_arc_for_a_single_lone_arc():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc = _make_arc(sketch, 0.0, 0.0, 5.0, 0.0, math.pi / 2)

    [result] = sketch.offset_chain([arc.id], 2.0)

    assert result.radius(sketch.points) == pytest.approx(7.0)


# --- offset_chain: the actual corner-join ----------------------------------


def test_offset_chain_joins_two_lines_meeting_at_a_right_angle():
    """The literal example from the on-device feedback: two connected
    Lines' offsets stay connected, trimmed/extended to their own new
    intersection rather than each independently offsetting into a gap -
    see `test_offset_line_does_not_join_two_lines_meeting_at_an_angle` in
    the single-entity sibling file for the old (v1) behavior this
    replaces for a multi-entity call."""
    sketch = Sketch(id="s", plane=Plane.XY)
    corner = sketch.add_point(10.0, 0.0)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 10.0)
    line1 = sketch.add_line(p1.id, corner.id)
    line2 = sketch.add_line(corner.id, p2.id)

    [offset1, offset2] = sketch.offset_chain([line1.id, line2.id], 1.0)

    assert offset1.end_point_id == offset2.start_point_id
    joined = sketch.points[offset1.end_point_id]
    assert (joined.x, joined.y) == pytest.approx((9.0, 1.0))
    # The far ends, untouched by any join, keep their own raw offset.
    start = sketch.points[offset1.start_point_id]
    assert (start.x, start.y) == pytest.approx((0.0, 1.0))
    end = sketch.points[offset2.end_point_id]
    assert (end.x, end.y) == pytest.approx((9.0, 10.0))


def test_offset_chain_reuses_the_shared_point_for_a_collinear_continuation():
    """Mirrors `test_offset_line_reuses_a_point_shared_with_an_already_
    offset_collinear_continuation` - collinear Lines have no real corner to
    trim/extend to (their raw offsets already coincide, and `line_vs_line`
    itself returns None for this exact parallel case - see the
    `line_vs_line` tests above), so this exercises the "no join found,
    fall back to the raw endpoint" path landing on the same answer
    `add_or_reuse_point` already gave the single-entity version."""
    sketch = Sketch(id="s", plane=Plane.XY)
    join = sketch.add_point(10.0, 0.0)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(20.0, 0.0)
    line1 = sketch.add_line(p1.id, join.id)
    line2 = sketch.add_line(join.id, p2.id)

    [offset1, offset2] = sketch.offset_chain([line1.id, line2.id], 1.0)

    assert offset1.end_point_id == offset2.start_point_id


def test_offset_chain_joins_a_line_and_an_arc():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc = _make_arc(sketch, 0.0, 0.0, 5.0, 0.0, math.pi / 2)  # (5,0) -> (0,5)
    shared = sketch.points[arc.end_point_id]
    far = sketch.add_point(0.0, 10.0)
    line = sketch.add_line(shared.id, far.id)  # (0,5) -> (0,10)

    [offset_arc, offset_line] = sketch.offset_chain([arc.id, line.id], 1.0)

    # Ground truth computed the same way offset_chain's join dispatch does
    # internally: the raw offset Line is x = -1 (perpendicular offset of a
    # straight-up Line is 1 unit to the left); the raw offset Arc's circle
    # has radius 6 - both independently derived from the same math
    # `offset_line`/`offset_arc` already use and already have their own
    # dedicated tests for.
    candidates = [point for _, point in line_vs_circle((-1.0, 5.0), (-1.0, 10.0), (0.0, 0.0), 6.0)]
    expected = min(candidates, key=lambda p: math.hypot(p[0] - 0.0, p[1] - 5.0))

    assert offset_arc.end_point_id == offset_line.start_point_id
    joined = sketch.points[offset_arc.end_point_id]
    assert (joined.x, joined.y) == pytest.approx(expected)
    # The arc's untouched start (not part of the join) keeps its raw offset.
    arc_start = sketch.points[offset_arc.start_point_id]
    assert (arc_start.x, arc_start.y) == pytest.approx((6.0, 0.0))


def test_offset_chain_joins_two_arcs():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc_a = _make_arc(sketch, 0.0, 0.0, 5.0, 0.0, math.pi / 2)  # (5,0) -> (0,5)
    shared = sketch.points[arc_a.end_point_id]
    # Arc B's own start point is explicitly the same shared Point, at
    # angle pi (180deg) around its own center (5,5) - (5-5, 5+0) = (0,5).
    arc_b = sketch.add_arc(
        sketch.add_point(5.0, 5.0).id, shared.id, end_angle=3 * math.pi / 2
    )

    [offset_a, offset_b] = sketch.offset_chain([arc_a.id, arc_b.id], 1.0)

    candidates = circle_vs_circle((0.0, 0.0), 6.0, (5.0, 5.0), 6.0)
    expected = min(candidates, key=lambda p: math.hypot(p[0] - 0.0, p[1] - 5.0))

    assert offset_a.end_point_id == offset_b.start_point_id
    joined = sketch.points[offset_a.end_point_id]
    assert (joined.x, joined.y) == pytest.approx(expected)


def test_offset_chain_leaves_a_t_junction_unjoined():
    """A Point shared by three (not two) of the given entities is a
    branch/T-junction - `offset_chain`'s own doc comment documents this as
    "no join, no error" for v1; this proves it doesn't crash and every
    entity still gets its own valid raw offset."""
    sketch = Sketch(id="s", plane=Plane.XY)
    hub = sketch.add_point(0.0, 0.0)
    a = sketch.add_point(10.0, 0.0)
    b = sketch.add_point(0.0, 10.0)
    c = sketch.add_point(-10.0, 0.0)
    line1 = sketch.add_line(hub.id, a.id)
    line2 = sketch.add_line(hub.id, b.id)
    line3 = sketch.add_line(hub.id, c.id)

    results = sketch.offset_chain([line1.id, line2.id, line3.id], 1.0)

    assert len(results) == 3
    for result in results:
        start = sketch.points[result.start_point_id]
        end = sketch.points[result.end_point_id]
        assert (start.x, start.y) != (end.x, end.y)


def test_offset_chain_joins_disjoint_pairs_independently():
    """Two entirely unrelated connected pairs in the same call each join
    only within their own pair - no cross-talk between the two corners."""
    sketch = Sketch(id="s", plane=Plane.XY)
    corner1 = sketch.add_point(10.0, 0.0)
    a1 = sketch.add_point(0.0, 0.0)
    a2 = sketch.add_point(10.0, 10.0)
    line1a = sketch.add_line(a1.id, corner1.id)
    line1b = sketch.add_line(corner1.id, a2.id)

    corner2 = sketch.add_point(110.0, 0.0)
    b1 = sketch.add_point(100.0, 0.0)
    b2 = sketch.add_point(110.0, 10.0)
    line2a = sketch.add_line(b1.id, corner2.id)
    line2b = sketch.add_line(corner2.id, b2.id)

    [o1a, o1b, o2a, o2b] = sketch.offset_chain([line1a.id, line1b.id, line2a.id, line2b.id], 1.0)

    assert o1a.end_point_id == o1b.start_point_id
    assert o2a.end_point_id == o2b.start_point_id
    assert o1a.end_point_id != o2a.end_point_id
    joined1 = sketch.points[o1a.end_point_id]
    joined2 = sketch.points[o2a.end_point_id]
    assert (joined1.x, joined1.y) == pytest.approx((9.0, 1.0))
    assert (joined2.x, joined2.y) == pytest.approx((109.0, 1.0))


# --- offset_chain: construction flag / errors ------------------------------


def test_offset_chain_propagates_the_construction_flag():
    sketch = Sketch(id="s", plane=Plane.XY)
    line = _make_line(sketch, 0.0, 0.0, 10.0, 0.0)

    [result] = sketch.offset_chain([line.id], 1.0, construction=True)

    assert result.construction is True


def test_offset_chain_rejects_empty_entity_ids():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(ValueError):
        sketch.offset_chain([], 1.0)


def test_offset_chain_rejects_zero_distance():
    sketch = Sketch(id="s", plane=Plane.XY)
    line = _make_line(sketch, 0.0, 0.0, 10.0, 0.0)
    with pytest.raises(ValueError):
        sketch.offset_chain([line.id], 0.0)


def test_offset_chain_rejects_a_circle_entity():
    sketch = Sketch(id="s", plane=Plane.XY)
    circle = _make_circle(sketch, 0.0, 0.0, 5.0)
    with pytest.raises(ValueError):
        sketch.offset_chain([circle.id], 1.0)


def test_offset_chain_raises_keyerror_for_a_missing_entity():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.offset_chain(["does-not-exist"], 1.0)
