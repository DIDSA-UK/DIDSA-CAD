"""On-device feedback: "when deleting lines, curves, trimming I end up with
floating, redundant points" - deleting/trimming an entity has always
deliberately left its own defining Points behind (a Point might still be
shared with something else), which is correct as a *default* but leaves
genuinely orphaned Points around forever once nothing else references them.

`Sketch._prune_orphaned_points`/`_entity_defining_point_ids` and every
`delete_line`/`delete_circle`/`delete_arc`/`delete_ellipse`/`delete_polygon`/
`delete_spline`/`delete_text`/`trim_circle` call site that now uses them are
entirely OCCT-free and run for real in this sandbox.
"""

import math

from app.sketch.models import Plane, Sketch


def test_delete_line_prunes_its_own_unshared_endpoints():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p1.id, p2.id)

    pruned = sketch.delete_line(line.id)

    assert set(pruned) == {p1.id, p2.id}
    assert p1.id not in sketch.points
    assert p2.id not in sketch.points


def test_delete_line_does_not_prune_an_endpoint_still_shared_with_another_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)
    p3 = sketch.add_point(10.0, 10.0)
    line1 = sketch.add_line(p1.id, p2.id)
    sketch.add_line(p2.id, p3.id)  # shares p2 with line1

    pruned = sketch.delete_line(line1.id)

    assert pruned == [p1.id]
    assert p1.id not in sketch.points
    assert p2.id in sketch.points  # still needed by the surviving line


def test_delete_line_does_not_prune_the_origin():
    sketch = Sketch(id="s", plane=Plane.XY)
    origin = sketch.origin_point()
    p2 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(origin.id, p2.id)

    pruned = sketch.delete_line(line.id)

    assert origin.id not in pruned
    assert origin.id in sketch.points
    assert p2.id in pruned


def test_delete_line_does_not_prune_an_endpoint_still_referenced_by_a_constraint():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)
    p3 = sketch.add_point(0.0, 10.0)
    line = sketch.add_line(p1.id, p2.id)
    sketch.add_distance_constraint(p1.id, p3.id, 10.0)  # p1 also constrained elsewhere

    pruned = sketch.delete_line(line.id)

    assert pruned == [p2.id]
    assert p1.id in sketch.points  # still needed by the DistanceConstraint


def test_delete_circle_prunes_its_own_cardinal_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)  # bare-radius mode: 4 cardinal points
    cardinal_ids = set(circle.cardinal_point_ids)
    assert len(cardinal_ids) == 4  # sanity check on the fixture itself

    pruned = sketch.delete_circle(circle.id)

    assert cardinal_ids <= set(pruned)
    assert circle.radius_point_id in pruned
    assert center.id in pruned  # nothing else references the center either
    for point_id in cardinal_ids:
        assert point_id not in sketch.points


def test_delete_circle_does_not_prune_a_center_still_shared_with_another_entity():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)
    other_point = sketch.add_point(20.0, 0.0)
    sketch.add_line(center.id, other_point.id)  # shares the center

    pruned = sketch.delete_circle(circle.id)

    assert center.id not in pruned
    assert center.id in sketch.points


def test_delete_arc_prunes_its_own_unshared_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    arc = sketch.add_arc(center.id, start.id, end_angle=1.5707963267948966)

    pruned = sketch.delete_arc(arc.id)

    assert set(pruned) == {center.id, start.id, arc.end_point_id}


def test_delete_polygon_prunes_its_own_center_and_vertices():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    vertex = sketch.add_point(5.0, 0.0)
    polygon = sketch.add_polygon(center.id, vertex.id, sides=5)

    pruned = sketch.delete_polygon(polygon.id)

    assert set(pruned) >= {center.id, vertex.id, *polygon.vertex_point_ids}


def test_delete_text_prunes_its_own_unshared_anchor():
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)
    text = sketch.add_text("hello", "Roboto", 10.0, anchor.id)

    pruned = sketch.delete_text(text.id)

    assert pruned == [anchor.id]
    assert anchor.id not in sketch.points


def test_delete_text_does_not_prune_an_anchor_shared_with_a_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)
    other = sketch.add_point(10.0, 0.0)
    sketch.add_line(anchor.id, other.id)
    text = sketch.add_text("hello", "Roboto", 10.0, anchor.id)

    pruned = sketch.delete_text(text.id)

    assert pruned == []
    assert anchor.id in sketch.points


def test_trim_circle_prunes_the_old_circles_radius_and_cardinal_points_but_keeps_the_shared_center():
    """The concrete on-device scenario the bug report described: trimming a
    Circle into an Arc reuses only the center Point - the old radius Point
    and (if the Circle was drawn via the bare-radius/cardinal tool) all
    four cardinal Points become genuinely orphaned, since the new Arc has
    no use for any of them."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)
    old_radius_point_id = circle.radius_point_id
    old_cardinal_ids = set(circle.cardinal_point_ids)

    # A Line crossing the circle, off-cardinal, so the Arc's own new
    # start/end Points don't happen to coincide with any of the old ones.
    line_start = sketch.add_point(-20.0, -8.0)
    line_end = sketch.add_point(20.0, 8.0)
    sketch.add_line(line_start.id, line_end.id)

    click_x, click_y = 5.0 * math.cos(math.radians(150)), 5.0 * math.sin(math.radians(150))
    arc, pruned = sketch.trim_circle(circle.id, click_x=click_x, click_y=click_y)

    assert old_radius_point_id in pruned
    assert old_cardinal_ids <= set(pruned)
    assert center.id not in pruned  # the new Arc still needs it
    assert center.id in sketch.points
    assert arc.center_point_id == center.id
