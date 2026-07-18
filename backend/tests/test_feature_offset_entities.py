"""Sketcher-roadmap Phase 9 v1 (Offset Entities): a real, independently
editable copy of a single Line/Circle/Arc, offset by a signed distance -
no live link back to the source, same "frozen copy" shape as Convert
Entities (`test_feature_convert_entities.py`).

Entirely OCCT-free pure 2D math (`app.sketch.models.Sketch.offset_line`/
`offset_circle`/`offset_arc`) - every test here runs for real in this
sandbox, unlike Convert Entities' document-router endpoints.
"""

import math

import pytest

from app.sketch.models import Plane, Sketch


def _make_line(sketch: Sketch, x1, y1, x2, y2):
    p1 = sketch.add_point(x1, y1)
    p2 = sketch.add_point(x2, y2)
    return sketch.add_line(p1.id, p2.id)


def _make_circle(sketch: Sketch, cx, cy, radius):
    center = sketch.add_point(cx, cy)
    radius_point = sketch.add_point(cx + radius, cy)
    return sketch.add_circle(center.id, radius_point.id)


def _make_arc(sketch: Sketch, cx, cy, radius, start_angle, end_angle):
    center = sketch.add_point(cx, cy)
    start = sketch.add_point(cx + radius * math.cos(start_angle), cy + radius * math.sin(start_angle))
    return sketch.add_arc(center.id, start.id, end_angle=end_angle)


# --- offset_line ---------------------------------------------------------


def test_offset_line_positive_distance_offsets_to_the_left_of_travel():
    sketch = Sketch(id="s", plane=Plane.XY)
    line = _make_line(sketch, 0.0, 0.0, 10.0, 0.0)

    offset = sketch.offset_line(line.id, 2.0)

    start = sketch.points[offset.start_point_id]
    end = sketch.points[offset.end_point_id]
    assert (start.x, start.y) == pytest.approx((0.0, 2.0))
    assert (end.x, end.y) == pytest.approx((10.0, 2.0))
    assert offset.id != line.id


def test_offset_line_negative_distance_offsets_to_the_right():
    sketch = Sketch(id="s", plane=Plane.XY)
    line = _make_line(sketch, 0.0, 0.0, 10.0, 0.0)

    offset = sketch.offset_line(line.id, -2.0)

    start = sketch.points[offset.start_point_id]
    end = sketch.points[offset.end_point_id]
    assert (start.x, start.y) == pytest.approx((0.0, -2.0))
    assert (end.x, end.y) == pytest.approx((10.0, -2.0))


def test_offset_line_is_non_construction_by_default():
    sketch = Sketch(id="s", plane=Plane.XY)
    line = _make_line(sketch, 0.0, 0.0, 10.0, 0.0)

    offset = sketch.offset_line(line.id, 2.0)

    assert offset.construction is False


def test_offset_line_rejects_zero_length_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    line = _make_line(sketch, 3.0, 3.0, 3.0, 3.0)

    with pytest.raises(ValueError):
        sketch.offset_line(line.id, 2.0)


def test_offset_line_rejects_zero_distance():
    sketch = Sketch(id="s", plane=Plane.XY)
    line = _make_line(sketch, 0.0, 0.0, 10.0, 0.0)

    with pytest.raises(ValueError):
        sketch.offset_line(line.id, 0.0)


def test_offset_line_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)

    with pytest.raises(KeyError):
        sketch.offset_line("does-not-exist", 2.0)


def test_offset_line_reuses_a_point_shared_with_an_already_offset_collinear_continuation():
    """Two collinear Lines (a straight continuation, not a corner) sharing
    an endpoint, offset by the same distance, share the identical
    perpendicular direction - so their independently-offset copies land on
    the exact same new point at the join, and `add_or_reuse_point` (same
    reasoning as Convert Entities) reuses it rather than creating a
    coincident duplicate.

    v1 scope note: this is *not* true in general for two Lines meeting at
    an angle (a real corner) - each Line is offset independently, with no
    miter/corner-join logic, so two angled Lines' offsets land near but not
    exactly on each other at the corner. Multi-entity chain offset with
    real corner joining is out of v1's scope (see `offset_line`'s own doc
    comment) - deliberately not what this test exercises."""
    sketch = Sketch(id="s", plane=Plane.XY)
    join = sketch.add_point(10.0, 0.0)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(20.0, 0.0)
    line1 = sketch.add_line(p1.id, join.id)
    line2 = sketch.add_line(join.id, p2.id)

    offset1 = sketch.offset_line(line1.id, 1.0)
    offset2 = sketch.offset_line(line2.id, 1.0)

    assert offset1.end_point_id == offset2.start_point_id


def test_offset_line_does_not_join_two_lines_meeting_at_an_angle():
    """v1 scope boundary, made concrete: two Lines meeting at a real corner
    (not collinear), each offset independently by the same distance, do
    *not* share a point - proves there's no accidental/silent corner-join
    happening, since a caller relying on one would get subtly wrong
    (gapped) geometry rather than a clear failure."""
    sketch = Sketch(id="s", plane=Plane.XY)
    corner = sketch.add_point(10.0, 0.0)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 10.0)
    line1 = sketch.add_line(p1.id, corner.id)
    line2 = sketch.add_line(corner.id, p2.id)

    offset1 = sketch.offset_line(line1.id, 1.0)
    offset2 = sketch.offset_line(line2.id, 1.0)

    assert offset1.end_point_id != offset2.start_point_id


# --- offset_circle --------------------------------------------------------


def test_offset_circle_grows_outward_for_a_positive_distance_same_center():
    sketch = Sketch(id="s", plane=Plane.XY)
    circle = _make_circle(sketch, 0.0, 0.0, 5.0)

    offset = sketch.offset_circle(circle.id, 2.0)

    assert offset.center_point_id == circle.center_point_id
    assert offset.radius(sketch.points) == pytest.approx(7.0)
    radius_point = sketch.points[offset.radius_point_id]
    assert (radius_point.x, radius_point.y) == pytest.approx((7.0, 0.0))


def test_offset_circle_shrinks_inward_for_a_negative_distance():
    sketch = Sketch(id="s", plane=Plane.XY)
    circle = _make_circle(sketch, 0.0, 0.0, 5.0)

    offset = sketch.offset_circle(circle.id, -2.0)

    assert offset.radius(sketch.points) == pytest.approx(3.0)


def test_offset_circle_preserves_the_radius_points_angle_from_center():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(1.0, 1.0)
    radius_point = sketch.add_point(1.0, 6.0)  # straight up: radius 5, angle 90deg
    circle = sketch.add_circle(center.id, radius_point.id)

    offset = sketch.offset_circle(circle.id, 3.0)

    new_radius_point = sketch.points[offset.radius_point_id]
    assert (new_radius_point.x, new_radius_point.y) == pytest.approx((1.0, 9.0))


def test_offset_circle_rejects_a_distance_that_would_collapse_the_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    circle = _make_circle(sketch, 0.0, 0.0, 5.0)

    with pytest.raises(ValueError):
        sketch.offset_circle(circle.id, -5.0)  # exactly zero radius

    with pytest.raises(ValueError):
        sketch.offset_circle(circle.id, -10.0)  # would invert


def test_offset_circle_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)

    with pytest.raises(KeyError):
        sketch.offset_circle("does-not-exist", 2.0)


# --- offset_arc ------------------------------------------------------------


def test_offset_arc_keeps_the_same_center_and_sweep_at_a_new_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc = _make_arc(sketch, 0.0, 0.0, 5.0, 0.0, math.pi / 2)

    offset = sketch.offset_arc(arc.id, 2.0)

    assert offset.center_point_id == arc.center_point_id
    assert offset.radius(sketch.points) == pytest.approx(7.0)
    start = sketch.points[offset.start_point_id]
    end = sketch.points[offset.end_point_id]
    assert (start.x, start.y) == pytest.approx((7.0, 0.0))
    assert (end.x, end.y) == pytest.approx((0.0, 7.0))


def test_offset_arc_shrinks_inward_for_a_negative_distance():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc = _make_arc(sketch, 0.0, 0.0, 5.0, 0.0, math.pi / 2)

    offset = sketch.offset_arc(arc.id, -2.0)

    assert offset.radius(sketch.points) == pytest.approx(3.0)


def test_offset_arc_rejects_a_distance_that_would_collapse_the_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc = _make_arc(sketch, 0.0, 0.0, 5.0, 0.0, math.pi / 2)

    with pytest.raises(ValueError):
        sketch.offset_arc(arc.id, -5.0)


def test_offset_arc_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)

    with pytest.raises(KeyError):
        sketch.offset_arc("does-not-exist", 2.0)
