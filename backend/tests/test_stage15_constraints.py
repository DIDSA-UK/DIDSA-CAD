import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def dist_between(sketch: Sketch, point_a_id: str, point_b_id: str) -> float:
    a = sketch.points[point_a_id]
    b = sketch.points[point_b_id]
    return math.hypot(a.x - b.x, a.y - b.y)


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_coincident_constraint_between_two_existing_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 10.0)

    constraint = sketch.add_coincident_constraint(a.id, b.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id)


def test_add_coincident_constraint_rejects_same_point_twice():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_coincident_constraint(a.id, a.id)


def test_add_coincident_constraint_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_coincident_constraint(a.id, "does-not-exist")


def test_coincident_constraint_forces_same_position_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(1.0, -2.0)
    sketch.add_coincident_constraint(a.id, b.id)

    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[a.id].x == pytest.approx(sketch.points[b.id].x)
    assert sketch.points[a.id].y == pytest.approx(sketch.points[b.id].y)


def test_add_parallel_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 5.0)
    d = sketch.add_point(10.0, 6.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_parallel_constraint(line1.id, line2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)


def test_add_parallel_constraint_rejects_same_line_twice():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    with pytest.raises(ValueError):
        sketch.add_parallel_constraint(line.id, line.id)


def test_parallel_constraint_forces_parallel_lines_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.5)
    c = sketch.add_point(2.0, 2.0)
    d = sketch.add_point(12.0, 3.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_parallel_constraint(line1.id, line2.id)

    result = solve_sketch(sketch)

    assert result.converged
    v1 = (sketch.points[b.id].x - sketch.points[a.id].x, sketch.points[b.id].y - sketch.points[a.id].y)
    v2 = (sketch.points[d.id].x - sketch.points[c.id].x, sketch.points[d.id].y - sketch.points[c.id].y)
    cross = v1[0] * v2[1] - v1[1] * v2[0]
    assert cross == pytest.approx(0.0, abs=1e-6)


def test_add_perpendicular_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 0.0)
    d = sketch.add_point(0.0, 10.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_perpendicular_constraint(line1.id, line2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)


def test_perpendicular_constraint_forces_right_angle_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(3.0, 3.0)
    d = sketch.add_point(5.0, 9.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_perpendicular_constraint(line1.id, line2.id)

    result = solve_sketch(sketch)

    assert result.converged
    v1 = (sketch.points[b.id].x - sketch.points[a.id].x, sketch.points[b.id].y - sketch.points[a.id].y)
    v2 = (sketch.points[d.id].x - sketch.points[c.id].x, sketch.points[d.id].y - sketch.points[c.id].y)
    dot = v1[0] * v2[0] + v1[1] * v2[1]
    assert dot == pytest.approx(0.0, abs=1e-6)


def test_add_equal_length_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 5.0)
    d = sketch.add_point(0.0, 8.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_equal_length_constraint(line1.id, line2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)


def test_equal_length_constraint_forces_same_length_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.5)
    c = sketch.add_point(2.0, 2.0)
    d = sketch.add_point(12.0, 3.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_equal_length_constraint(line1.id, line2.id)

    result = solve_sketch(sketch)

    assert result.converged
    length1 = line1.length(sketch.points)
    length2 = line2.length(sketch.points)
    assert length1 == pytest.approx(length2)


def test_add_tangent_constraint_between_circle_and_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    a = sketch.add_point(-10.0, 8.0)
    b = sketch.add_point(10.0, 8.0)
    line = sketch.add_line(a.id, b.id)

    constraint = sketch.add_tangent_constraint(circle.id, line.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (circle.center_point_id, circle.radius_point_id, a.id, b.id)


def test_add_tangent_constraint_with_unknown_line_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    with pytest.raises(KeyError):
        sketch.add_tangent_constraint(circle.id, "does-not-exist")


def test_tangent_constraint_forces_perpendicular_distance_equal_radius_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    a = sketch.add_point(-10.0, 8.0)
    b = sketch.add_point(10.0, 9.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_tangent_constraint(circle.id, line.id)
    sketch.add_horizontal_constraint(line.id)

    result = solve_sketch(sketch)

    assert result.converged
    cy = sketch.points[center.id].y
    ay = sketch.points[a.id].y
    by = sketch.points[b.id].y
    assert ay == pytest.approx(by, abs=1e-6)
    radius = dist_between(sketch, center.id, circle.radius_point_id)
    assert abs(ay - cy) == pytest.approx(radius, abs=1e-6)


def test_add_equal_radius_constraint_between_two_circles():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    circle1 = sketch.add_circle(center1.id, radius=5.0, angle=0.0)
    center2 = sketch.add_point(20.0, 0.0)
    circle2 = sketch.add_circle(center2.id, radius=8.0, angle=0.0)

    constraint = sketch.add_equal_radius_constraint(circle1.id, circle2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (
        circle1.center_point_id,
        circle1.radius_point_id,
        circle2.center_point_id,
        circle2.radius_point_id,
    )


def test_equal_radius_constraint_rejects_same_entity_twice():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    with pytest.raises(ValueError):
        sketch.add_equal_radius_constraint(circle.id, circle.id)


def test_equal_radius_constraint_forces_same_radius_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    circle1 = sketch.add_circle(center1.id, radius=5.0, angle=0.0)
    center2 = sketch.add_point(20.0, 0.0)
    circle2 = sketch.add_circle(center2.id, radius=8.0, angle=0.0)
    # A Circle's own radius DistanceConstraint (8.0 here) would otherwise
    # directly contradict the EqualRadiusConstraint being added below (which
    # ties it to circle1's own 5.0) - see Sketch.add_arc's use of exactly
    # this same "delete the entity's own radius constraint first" pattern
    # for a Slot's second end-cap Arc.
    del sketch.constraints[circle2.radius_constraint_id]
    sketch.add_equal_radius_constraint(circle1.id, circle2.id)

    result = solve_sketch(sketch)

    assert result.converged
    radius1 = dist_between(sketch, circle1.center_point_id, circle1.radius_point_id)
    radius2 = dist_between(sketch, circle2.center_point_id, circle2.radius_point_id)
    assert radius1 == pytest.approx(radius2)


def test_equal_radius_constraint_with_explicit_radius2_point_id_ties_an_arcs_second_rim_point():
    """A Slot's second end-cap Arc needs BOTH of its rim Points tied back
    to the first Arc's radius independently (see Sketch._center_radius_
    point_ids' own doc comment) - an Arc, unlike a Circle, has no single
    "the" radius Point, so add_equal_radius_constraint's radius2_point_id
    override picks which one this particular tie is for."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    arc1 = sketch.add_arc(center1.id, sketch.add_point(5.0, 0.0).id, sketch.add_point(0.0, 5.0).id)
    center2 = sketch.add_point(20.0, 0.0)
    start2 = sketch.add_point(25.0, 0.0)
    end2 = sketch.add_point(20.0, 8.0)
    arc2 = sketch.add_arc(center2.id, start2.id, end2.id)

    constraint = sketch.add_equal_radius_constraint(arc1.id, arc2.id, radius2_point_id=end2.id)

    assert constraint.radius2_point_id == end2.id
    assert constraint.point_ids() == (
        arc1.center_point_id,
        arc1.start_point_id,
        arc2.center_point_id,
        end2.id,
    )


def test_equal_radius_constraint_rejects_a_radius2_point_id_not_belonging_to_the_entity():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    circle1 = sketch.add_circle(center1.id, radius=5.0, angle=0.0)
    center2 = sketch.add_point(20.0, 0.0)
    circle2 = sketch.add_circle(center2.id, radius=8.0, angle=0.0)
    unrelated = sketch.add_point(99.0, 99.0)
    with pytest.raises(ValueError):
        sketch.add_equal_radius_constraint(circle1.id, circle2.id, radius2_point_id=unrelated.id)


def test_add_equal_radius_constraint_from_points_between_two_raw_point_pairs():
    """The raw-Point counterpart to add_equal_radius_constraint, for a
    caller with no Circle/Arc entity id to resolve - e.g. a Polygon (see
    Sketch.add_equal_radius_constraint_from_points' own doc comment)."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    vertex1 = sketch.add_point(10.0, 0.0)
    vertex2 = sketch.add_point(0.0, 10.0)

    constraint = sketch.add_equal_radius_constraint_from_points(center.id, vertex1.id, center.id, vertex2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (center.id, vertex1.id, center.id, vertex2.id)


def test_equal_radius_constraint_from_points_rejects_an_unknown_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    vertex1 = sketch.add_point(10.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_equal_radius_constraint_from_points(center.id, vertex1.id, center.id, "does-not-exist")


def test_equal_radius_constraint_from_points_rejects_the_same_point_as_center_and_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    vertex1 = sketch.add_point(10.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_equal_radius_constraint_from_points(center.id, vertex1.id, center.id, center.id)


def test_equal_radius_constraint_from_points_forces_same_radius_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    vertex1 = sketch.add_point(10.0, 0.0)
    vertex2 = sketch.add_point(0.0, 7.0)
    sketch.add_distance_constraint(center.id, vertex1.id, 10.0)
    sketch.add_equal_radius_constraint_from_points(center.id, vertex1.id, center.id, vertex2.id)

    result = solve_sketch(sketch)

    assert result.converged
    radius1 = dist_between(sketch, center.id, vertex1.id)
    radius2 = dist_between(sketch, center.id, vertex2.id)
    assert radius1 == pytest.approx(radius2)


def test_regular_hexagon_built_from_raw_points_stays_regular_after_a_vertex_drag():
    """A real regular polygon composed from plain Points/Lines/Constraints
    only (no dedicated backend entity, same as Rectangle - see the client's
    own Sketch tool for Polygon): a single real DistanceConstraint (one
    vertex's own circumradius) plus N-1 EqualRadiusConstraint ties locks
    every vertex onto one circle, and the existing N-1 EqualLengthConstraint
    chain between consecutive edges locks the side lengths equal - together
    forcing equal angular spacing between vertices (fixed radius + equal
    chord length implies equal central angle), i.e. a regular polygon, with
    no separate angle-value constraint needed. Verified via a real drag +
    re-solve, mirroring every other shape's own convergence test in this
    file."""
    sketch = Sketch(id="s", plane=Plane.XY)
    n = 6
    radius = 10.0
    center = sketch.add_point(0.0, 0.0)
    vertices = [
        sketch.add_point(radius * math.cos(2 * math.pi * i / n), radius * math.sin(2 * math.pi * i / n))
        for i in range(n)
    ]
    sketch.add_distance_constraint(center.id, vertices[0].id, radius)
    for vertex in vertices[1:]:
        sketch.add_equal_radius_constraint_from_points(center.id, vertices[0].id, center.id, vertex.id)
    lines = [sketch.add_line(vertices[i].id, vertices[(i + 1) % n].id) for i in range(n)]
    for i in range(n - 1):
        sketch.add_equal_length_constraint(lines[i].id, lines[i + 1].id)

    # A modest drag of one vertex - within the shape's own scale, like a
    # real on-canvas gesture, not an unrealistic teleport far outside it.
    dragged = vertices[0]
    sketch.points[dragged.id].x = 8.0
    sketch.points[dragged.id].y = 6.0
    result = solve_sketch(sketch, anchor_point_ids=frozenset({dragged.id}))

    assert result.converged
    radii = [dist_between(sketch, center.id, v.id) for v in vertices]
    assert all(r == pytest.approx(radii[0], abs=1e-6) for r in radii)
    edge_lengths = [dist_between(sketch, lines[i].start_point_id, lines[i].end_point_id) for i in range(n)]
    assert all(length == pytest.approx(edge_lengths[0], abs=1e-6) for length in edge_lengths)


def test_slot_shaped_sketch_with_tangent_and_equal_radius_constraints_converges_and_survives_a_drag():
    """A real Slot: 2 Arcs + 2 Lines forming a closed loop, one shared
    radius (EqualRadiusConstraint replacing the second Arc's own two
    radius DistanceConstraints), and 4 TangentConstraints (one per Arc/
    Line pair) making both straight sides flush against both Arcs. This
    closed loop is mathematically over-determined by exactly one redundant
    equation (radius + both centres fully determine every rim Point), which
    solve_sketch's own narrow allowlist (see _REDUNDANCY_SAFE_CONSTRAINT_
    TYPES in solver.py) treats as still converged."""
    sketch = Sketch(id="s", plane=Plane.XY)
    c1 = sketch.add_point(-10.0, 0.0)
    c2 = sketch.add_point(10.0, 0.0)
    a = sketch.add_point(-10.0, 5.0)
    b = sketch.add_point(10.0, 5.0)
    c = sketch.add_point(10.0, -5.0)
    d = sketch.add_point(-10.0, -5.0)
    arc1 = sketch.add_arc(c1.id, a.id, b.id)
    line1 = sketch.add_line(b.id, c.id)
    arc2 = sketch.add_arc(c2.id, c.id, d.id)
    line2 = sketch.add_line(d.id, a.id)
    sketch.add_line(c1.id, c2.id, construction=True)

    del sketch.constraints[arc2.radius_constraint_id]
    del sketch.constraints[arc2.end_radius_constraint_id]
    sketch.add_equal_radius_constraint(arc1.id, arc2.id, radius2_point_id=c.id)
    sketch.add_equal_radius_constraint(arc1.id, arc2.id, radius2_point_id=d.id)
    for arc_, line_ in [(arc1, line1), (arc1, line2), (arc2, line1), (arc2, line2)]:
        sketch.add_tangent_constraint(arc_.id, line_.id)

    result = solve_sketch(sketch)
    assert result.converged

    def perp_dist(center_id: str, line) -> float:
        cx, cy = sketch.points[center_id].x, sketch.points[center_id].y
        x0, y0 = sketch.points[line.start_point_id].x, sketch.points[line.start_point_id].y
        x1, y1 = sketch.points[line.end_point_id].x, sketch.points[line.end_point_id].y
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy)
        return abs(dx * (y0 - cy) - dy * (x0 - cx)) / length

    radius1 = dist_between(sketch, arc1.center_point_id, arc1.start_point_id)
    radius2 = dist_between(sketch, arc2.center_point_id, arc2.start_point_id)
    assert radius1 == pytest.approx(radius2, abs=1e-6)
    for arc_, line_ in [(arc1, line1), (arc1, line2), (arc2, line1), (arc2, line2)]:
        assert perp_dist(arc_.center_point_id, line_) == pytest.approx(radius1, abs=1e-6)

    # Drag centre2 and re-solve, exactly like a real point-drag PATCH.
    sketch.points[c2.id].x = 25.0
    sketch.points[c2.id].y = -7.0
    result2 = solve_sketch(sketch, anchor_point_ids=frozenset({c2.id}))
    assert result2.converged
    radius1b = dist_between(sketch, arc1.center_point_id, arc1.start_point_id)
    for arc_, line_ in [(arc1, line1), (arc1, line2), (arc2, line1), (arc2, line2)]:
        assert perp_dist(arc_.center_point_id, line_) == pytest.approx(radius1b, abs=1e-6)


def test_add_collinear_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(2.0, 3.0)
    d = sketch.add_point(8.0, 3.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_collinear_constraint(line1.id, line2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)


def test_collinear_constraint_forces_lines_onto_same_line_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(2.0, 3.0)
    d = sketch.add_point(8.0, 3.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_collinear_constraint(line1.id, line2.id)

    result = solve_sketch(sketch)

    assert result.converged
    v1 = (sketch.points[b.id].x - sketch.points[a.id].x, sketch.points[b.id].y - sketch.points[a.id].y)
    v2 = (sketch.points[c.id].x - sketch.points[a.id].x, sketch.points[c.id].y - sketch.points[a.id].y)
    v3 = (sketch.points[d.id].x - sketch.points[a.id].x, sketch.points[d.id].y - sketch.points[a.id].y)
    cross_c = v1[0] * v2[1] - v1[1] * v2[0]
    cross_d = v1[0] * v3[1] - v1[1] * v3[0]
    assert cross_c == pytest.approx(0.0, abs=1e-6)
    assert cross_d == pytest.approx(0.0, abs=1e-6)


def test_add_line_distance_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 30.0)
    d = sketch.add_point(10.0, 30.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_line_distance_constraint(line1.id, line2.id, 50.0)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)
    assert constraint.distance == 50.0


def test_add_point_line_distance_constraint_between_a_point_and_a_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 5.0)
    line = sketch.add_line(a.id, b.id)

    constraint = sketch.add_point_line_distance_constraint(p.id, line.id, 5.0)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (p.id, a.id, b.id)
    assert constraint.distance == 5.0


def test_point_line_distance_constraint_pins_point_onto_line_after_solve():
    """Stage 21 item 3: a midpoint Point must stay collinear with its Line
    even as the Line moves - a perpendicular distance of 0 pins the Point
    onto the Line's infinite extension, unlike a pair of plain
    point-to-point DistanceConstraints (which only pin distance from each
    endpoint and let the Point swing off the Line in an arc).

    a/b are themselves unconstrained free Points (same as every other
    solver-integration test in this file, e.g.
    test_collinear_constraint_forces_lines_onto_same_line_after_solve), so
    the system is legitimately underdetermined and the solver is free to
    move the Line too - asserting p's *absolute* coordinates would wrongly
    assume a/b stay put. Assert the same relative invariants the collinear
    test uses instead: p stays on the (possibly-moved) line ab, and the
    distance constraint to a still holds.
    """
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 1.0)  # off the line to start
    line = sketch.add_line(a.id, b.id)

    sketch.add_point_line_distance_constraint(p.id, line.id, 0.0)
    sketch.add_distance_constraint(p.id, a.id, 5.0)
    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    px, py = sketch.points[p.id].x, sketch.points[p.id].y
    cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    assert cross == pytest.approx(0.0, abs=1e-6)
    assert math.hypot(px - ax, py - ay) == pytest.approx(5.0, abs=1e-6)


def test_add_at_midpoint_constraint_between_a_point_and_a_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 5.0)
    line = sketch.add_line(a.id, b.id)

    constraint = sketch.add_at_midpoint_constraint(p.id, line.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (p.id, a.id, b.id)


def test_add_at_midpoint_constraint_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    with pytest.raises(KeyError):
        sketch.add_at_midpoint_constraint("does-not-exist", line.id)


def test_at_midpoint_constraint_pins_point_to_midpoint_after_solve():
    """Stage 22 item 1: SLVS_C_AT_MIDPOINT pins the Point to the Line's
    actual geometric midpoint - unlike Stage 21's point_line_distance(0) +
    distance(half-length) workaround, this must still hold even as the
    Line's own length changes, since there is no fixed half-length value
    baked into the constraint."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 5.0)  # off the line to start
    line = sketch.add_line(a.id, b.id)
    sketch.add_at_midpoint_constraint(p.id, line.id)
    # Pin the line's own length so the system is fully determined.
    sketch.add_distance_constraint(a.id, b.id, 20.0)
    sketch.add_horizontal_constraint(line.id)

    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    px, py = sketch.points[p.id].x, sketch.points[p.id].y
    assert px == pytest.approx((ax + bx) / 2, abs=1e-6)
    assert py == pytest.approx((ay + by) / 2, abs=1e-6)


def test_at_midpoint_constraint_tracks_midpoint_as_line_length_changes():
    """Regresses against the Stage 21 workaround's actual bug: pinning the
    Point with a fixed half-length DistanceConstraint meant it stopped
    tracking the midpoint once the Line's length changed independently.
    SLVS_C_AT_MIDPOINT has no such fixed value, so it must still land on
    the midpoint after the Line's length constraint is changed and the
    sketch is re-solved."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_at_midpoint_constraint(p.id, line.id)
    sketch.add_horizontal_constraint(line.id)
    length = sketch.add_distance_constraint(a.id, b.id, 10.0)

    result = solve_sketch(sketch)
    assert result.converged
    assert sketch.points[p.id].x == pytest.approx(
        (sketch.points[a.id].x + sketch.points[b.id].x) / 2, abs=1e-6
    )

    length.distance = 40.0
    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[p.id].x == pytest.approx(
        (sketch.points[a.id].x + sketch.points[b.id].x) / 2, abs=1e-6
    )


def test_point_pinned_to_midpoint_of_two_lines_lands_at_their_shared_center():
    """Prompt B item B2: a rectangle's center Point is pinned to the
    midpoint of both diagonals via two AtMidpoint constraints on the same
    Point - both must hold simultaneously after solve. a/b/c/d are
    themselves unconstrained free Points (same rationale as
    test_point_line_distance_constraint_pins_point_onto_line_after_solve),
    so the solver is free to move the whole rectangle too - assert the
    relative invariant (center matches *both* diagonals' actual solved
    midpoints) rather than fixed absolute coordinates."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 6.0)
    d = sketch.add_point(0.0, 6.0)
    diagonal1 = sketch.add_line(a.id, c.id, construction=True)
    diagonal2 = sketch.add_line(b.id, d.id, construction=True)
    center = sketch.add_point(1.0, 1.0)  # off-center initial guess
    sketch.add_at_midpoint_constraint(center.id, diagonal1.id)
    sketch.add_at_midpoint_constraint(center.id, diagonal2.id)

    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    cx, cy = sketch.points[c.id].x, sketch.points[c.id].y
    dx, dy = sketch.points[d.id].x, sketch.points[d.id].y
    centerx, centery = sketch.points[center.id].x, sketch.points[center.id].y
    assert centerx == pytest.approx((ax + cx) / 2, abs=1e-6)
    assert centery == pytest.approx((ay + cy) / 2, abs=1e-6)
    assert centerx == pytest.approx((bx + dx) / 2, abs=1e-6)
    assert centery == pytest.approx((by + dy) / 2, abs=1e-6)


def test_two_at_midpoint_constraints_on_the_same_point_is_singular_once_hv_ties_diagonals_together():
    """Bug-fix round 2 regression test - a real, on-device bug: once
    Horizontal/Vertical constraints already force a quadrilateral into a
    rectangle, its two diagonals are *guaranteed* to share the same
    midpoint - so pinning one Point to *both* diagonals' midpoints via two
    AtMidpoint constraints is not merely redundant, it makes the whole
    system singular. py-slvs fails to converge (non-zero result_code) but
    still reports `dof == 0` in that failure state, which - trusted
    blindly - made a genuinely under-constrained rectangle (nothing pins
    its width/height/position) render as "fully constrained". This is
    exactly why the rectangle tool (`SketchController._buildRectangle`)
    now only ever creates *one* AtMidpoint constraint per center Point, not
    two - see that method's doc comment."""
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    p2 = sketch.add_point(10.0, 20.0)
    p3 = sketch.add_point(0.0, 20.0)
    line1 = sketch.add_line(p0.id, p1.id)
    line2 = sketch.add_line(p1.id, p2.id)
    line3 = sketch.add_line(p2.id, p3.id)
    line4 = sketch.add_line(p3.id, p0.id)
    sketch.add_horizontal_constraint(line1.id)
    sketch.add_vertical_constraint(line2.id)
    sketch.add_horizontal_constraint(line3.id)
    sketch.add_vertical_constraint(line4.id)
    diagonal1 = sketch.add_line(p0.id, p2.id, construction=True)
    diagonal2 = sketch.add_line(p1.id, p3.id, construction=True)
    center = sketch.add_point(5.0, 10.0)
    sketch.add_at_midpoint_constraint(center.id, diagonal1.id)
    sketch.add_at_midpoint_constraint(center.id, diagonal2.id)

    result = solve_sketch(sketch)

    assert not result.converged
    assert result.result_code != 0


def test_one_at_midpoint_constraint_is_enough_for_an_hv_constrained_rectangles_centre():
    """The fix for the regression above: a single AtMidpoint constraint
    (on just one diagonal) is sufficient - the other diagonal's Points
    still land at the same midpoint automatically, since the H/V
    constraints alone already force that - and the whole system converges
    with the correct, nonzero degrees of freedom (translation X/Y, width,
    height - nothing pins the rectangle's size or position in this test)."""
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    p2 = sketch.add_point(10.0, 20.0)
    p3 = sketch.add_point(0.0, 20.0)
    line1 = sketch.add_line(p0.id, p1.id)
    line2 = sketch.add_line(p1.id, p2.id)
    line3 = sketch.add_line(p2.id, p3.id)
    line4 = sketch.add_line(p3.id, p0.id)
    sketch.add_horizontal_constraint(line1.id)
    sketch.add_vertical_constraint(line2.id)
    sketch.add_horizontal_constraint(line3.id)
    sketch.add_vertical_constraint(line4.id)
    diagonal1 = sketch.add_line(p0.id, p2.id, construction=True)
    sketch.add_line(p1.id, p3.id, construction=True)  # diagonal2 - no constraint on it
    center = sketch.add_point(5.0, 10.0)
    sketch.add_at_midpoint_constraint(center.id, diagonal1.id)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.dof == 4
    assert sketch.points[center.id].x == pytest.approx(
        (sketch.points[p0.id].x + sketch.points[p2.id].x) / 2, abs=1e-6
    )
    assert sketch.points[center.id].y == pytest.approx(
        (sketch.points[p0.id].y + sketch.points[p2.id].y) / 2, abs=1e-6
    )


def test_line_distance_constraint_moves_lines_apart_without_creating_points():
    """Stage 16 item 9: a line-to-line distance dimension must move the
    Lines themselves (via py-slvs's point-line-distance primitive) rather
    than the old approach of materializing a midpoint Point on each Line
    and constraining a plain Point-to-Point DistanceConstraint between
    those - the bug this regresses against. Two parallel (horizontal)
    Lines start 30 units apart; raising the constraint's distance to 50
    must converge with the Lines moved apart and not a single new Point in
    the Sketch."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 30.0)
    d = sketch.add_point(10.0, 30.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_horizontal_constraint(line1.id)
    sketch.add_horizontal_constraint(line2.id)
    point_count_before = len(sketch.points)

    sketch.add_line_distance_constraint(line1.id, line2.id, 50.0)
    result = solve_sketch(sketch)

    assert result.converged
    assert len(sketch.points) == point_count_before
    gap = abs(sketch.points[c.id].y - sketch.points[a.id].y)
    assert gap == pytest.approx(50.0, abs=1e-6)
    assert gap != pytest.approx(30.0, abs=1e-6)  # the Lines actually moved apart


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _create_line(sketch_id: str, start_id: str, end_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_id, "end_point_id": end_id},
    )
    assert response.status_code == 201
    return response.json()


def _create_circle(sketch_id: str, center_id: str, radius: float) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center_id, "radius": radius, "angle": 0.0},
    )
    assert response.status_code == 201
    return response.json()


def test_create_coincident_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 1.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": a["id"], "point_b_id": b["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "coincident"
    assert body["point_a_id"] == a["id"]
    assert body["point_b_id"] == b["id"]


def test_create_parallel_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 5.0)
    d = _create_point(sketch["id"], 10.0, 5.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "parallel", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "parallel"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]


def test_create_perpendicular_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 0.0)
    d = _create_point(sketch["id"], 0.0, 10.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "perpendicular", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "perpendicular"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]


def test_create_equal_length_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 5.0)
    d = _create_point(sketch["id"], 0.0, 8.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "equal_length", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "equal_length"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]


def test_create_tangent_constraint_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    circle = _create_circle(sketch["id"], center["id"], 5.0)
    a = _create_point(sketch["id"], -10.0, 8.0)
    b = _create_point(sketch["id"], 10.0, 8.0)
    line = _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "tangent", "circle_or_arc_id": circle["id"], "line_id": line["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "tangent"
    assert body["center_point_id"] == center["id"]
    assert body["radius_point_id"] == circle["radius_point_id"]
    assert body["line_id"] == line["id"]


def test_create_tangent_constraint_with_unknown_line_is_404():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    circle = _create_circle(sketch["id"], center["id"], 5.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "tangent", "circle_or_arc_id": circle["id"], "line_id": "does-not-exist"},
    )

    assert response.status_code == 404


def test_create_equal_radius_constraint_over_the_api():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    circle1 = _create_circle(sketch["id"], center1["id"], 5.0)
    center2 = _create_point(sketch["id"], 20.0, 0.0)
    circle2 = _create_circle(sketch["id"], center2["id"], 8.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "equal_radius", "entity1_id": circle1["id"], "entity2_id": circle2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "equal_radius"
    assert body["center1_point_id"] == center1["id"]
    assert body["radius1_point_id"] == circle1["radius_point_id"]
    assert body["center2_point_id"] == center2["id"]
    assert body["radius2_point_id"] == circle2["radius_point_id"]


def test_create_equal_radius_constraint_rejects_same_entity_twice_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    circle = _create_circle(sketch["id"], center["id"], 5.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "equal_radius", "entity1_id": circle["id"], "entity2_id": circle["id"]},
    )

    assert response.status_code == 400


def test_create_equal_radius_points_constraint_over_the_api():
    """The raw-Point counterpart to equal_radius - see
    Sketch.add_equal_radius_constraint_from_points' own doc comment."""
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    vertex1 = _create_point(sketch["id"], 10.0, 0.0)
    vertex2 = _create_point(sketch["id"], 0.0, 10.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "equal_radius_points",
            "center1_point_id": center["id"],
            "radius1_point_id": vertex1["id"],
            "center2_point_id": center["id"],
            "radius2_point_id": vertex2["id"],
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "equal_radius"
    assert body["center1_point_id"] == center["id"]
    assert body["radius1_point_id"] == vertex1["id"]
    assert body["center2_point_id"] == center["id"]
    assert body["radius2_point_id"] == vertex2["id"]


def test_create_equal_radius_points_constraint_rejects_the_same_point_as_center_and_radius_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    vertex1 = _create_point(sketch["id"], 10.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "equal_radius_points",
            "center1_point_id": center["id"],
            "radius1_point_id": vertex1["id"],
            "center2_point_id": center["id"],
            "radius2_point_id": center["id"],
        },
    )

    assert response.status_code == 400


def test_create_collinear_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 2.0, 3.0)
    d = _create_point(sketch["id"], 8.0, 3.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "collinear", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "collinear"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]


def test_create_line_distance_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 30.0)
    d = _create_point(sketch["id"], 10.0, 30.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "line_distance",
            "line1_id": line1["id"],
            "line2_id": line2["id"],
            "distance": 50.0,
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "line_distance"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]
    assert body["distance"] == 50.0


def test_create_point_line_distance_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "point_line_distance",
            "point_id": p["id"],
            "line_id": line["id"],
            "distance": 5.0,
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "point_line_distance"
    assert body["point_id"] == p["id"]
    assert body["line_id"] == line["id"]
    assert body["distance"] == 5.0


def test_create_at_midpoint_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "at_midpoint", "point_id": p["id"], "line_id": line["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "at_midpoint"
    assert body["point_id"] == p["id"]
    assert body["line_id"] == line["id"]
    assert "distance" not in body


def test_patch_at_midpoint_constraint_value_is_422():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "at_midpoint", "point_id": p["id"], "line_id": line["id"]},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}",
        json={"value": 5.0},
    )

    assert response.status_code == 422


def test_delete_at_midpoint_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "at_midpoint", "point_id": p["id"], "line_id": line["id"]},
    ).json()

    response = client.delete(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}"
    )

    assert response.status_code == 204
    remaining = client.get(f"/sketch/sketches/{sketch['id']}/constraints").json()
    assert constraint["id"] not in [c["id"] for c in remaining]


def test_create_coincident_constraint_with_unknown_point_is_404():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": a["id"], "point_b_id": "does-not-exist"},
    )
    assert response.status_code == 404


def test_create_parallel_constraint_with_unknown_line_is_404():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "parallel", "line1_id": line["id"], "line2_id": "does-not-exist"},
    )
    assert response.status_code == 404


def test_create_parallel_constraint_rejects_same_line_twice_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "parallel", "line1_id": line["id"], "line2_id": line["id"]},
    )
    assert response.status_code == 400


def test_list_constraints_includes_new_types_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 5.0)
    d = _create_point(sketch["id"], 10.0, 5.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "parallel", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    response = client.get(f"/sketch/sketches/{sketch['id']}/constraints")

    assert response.status_code == 200
    types = [c["type"] for c in response.json()]
    assert types == ["parallel"]


def test_coincident_constraint_solves_correctly_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 5.0, 5.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": a["id"], "point_b_id": b["id"]},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["converged"] is True
    solved_a = client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").json()
    solved_b = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    assert solved_a["x"] == pytest.approx(solved_b["x"])
    assert solved_a["y"] == pytest.approx(solved_b["y"])


# --- Prompt B item B3: DistanceConstraint orientation --------------------


def test_add_distance_constraint_defaults_to_linear_orientation():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)

    constraint = sketch.add_distance_constraint(a.id, b.id, 5.0)

    assert constraint.orientation == "linear"


def test_horizontal_distance_constraint_pins_only_x_separation_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    sketch.add_distance_constraint(a.id, b.id, 10.0, "horizontal")
    # Pin `a` in place (coincident, not a zero-distance constraint - py-slvs's
    # point-distance equation is singular at distance 0) so the solver has a
    # unique answer to check against.
    sketch.add_coincident_constraint(a.id, sketch.origin_point().id)

    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    assert abs(ax - bx) == pytest.approx(10.0, abs=1e-6)
    assert by == pytest.approx(4.0, abs=1e-6)  # y separation left unconstrained


def test_vertical_distance_constraint_pins_only_y_separation_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    sketch.add_distance_constraint(a.id, b.id, 10.0, "vertical")
    sketch.add_coincident_constraint(a.id, sketch.origin_point().id)

    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    assert abs(ay - by) == pytest.approx(10.0, abs=1e-6)
    assert bx == pytest.approx(3.0, abs=1e-6)  # x separation left unconstrained


def test_create_horizontal_orientation_distance_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "point_a_id": a["id"],
            "point_b_id": b["id"],
            "distance": 10.0,
            "orientation": "horizontal",
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["orientation"] == "horizontal"


def test_update_constraint_value_preserves_horizontal_orientation():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "point_a_id": a["id"],
            "point_b_id": b["id"],
            "distance": 10.0,
            "orientation": "horizontal",
        },
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}",
        json={"value": 25.0},
    )

    assert response.status_code == 200
    constraints = client.get(f"/sketch/sketches/{sketch['id']}/constraints").json()
    updated = next(c for c in constraints if c["id"] == constraint["id"])
    assert updated["orientation"] == "horizontal"
    assert updated["distance"] == 25.0


def test_update_constraint_value_on_a_point_line_distance_constraint():
    """Bug fix (on-device feedback: "before this work any dimension could be
    edited... this has been lost on certain dimension types"): a
    PointLineDistanceConstraint used to fall through update_constraint_value's
    switch straight to a 422 ("constraints have no numeric value to update"),
    the only constraint kind with a real numeric value that couldn't be
    PATCHed at all - DistanceConstraint and LineDistanceConstraint were
    already handled, matching the client's own selectedConstraintValue gap
    (see that getter's own doc comment)."""
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "point_line_distance", "point_id": p["id"], "line_id": line["id"], "distance": 5.0},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}",
        json={"value": 8.0},
    )

    assert response.status_code == 200
    constraints = client.get(f"/sketch/sketches/{sketch['id']}/constraints").json()
    updated = next(c for c in constraints if c["id"] == constraint["id"])
    assert updated["distance"] == 8.0


def test_update_constraint_value_keeps_the_free_point_on_the_same_side():
    """On-device feedback: confirming a new dimension value sometimes
    flipped the free Point to the opposite side of the anchor Point
    (reported as a dimension "changing polarity", "only some of the time")
    - py-slvs's squared-distance equation has two mirror-symmetric roots,
    and the solve (with neither Point anchored) seeds from each Point's
    current x/y, so a near-degenerate starting separation lets floating-
    point noise decide which root it converges to. A tiny (0.0001mm)
    initial x-separation is exactly that near-degenerate case - without
    re-seeding the free Point along its current direction before solving
    (see `_reseed_distance_constraint_free_point`), this is the scenario
    most likely to flip sides."""
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 0.0001, 0.0)
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "point_a_id": a["id"],
            "point_b_id": b["id"],
            "distance": 0.0001,
            "orientation": "linear",
        },
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}",
        json={"value": 10.0},
    )

    assert response.status_code == 200
    solved_b = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    # b started on the +x side of a - it must still be there, not flipped to -x.
    assert solved_b["x"] == pytest.approx(10.0, abs=1e-3)


# --- Prompt B item B5: solve response DOF ---------------------------------


def test_a_fully_constrained_sketch_reports_zero_dof():
    """One Point pinned to the (fixed) origin, the other fully pinned
    relative to it by a Vertical constraint (equal X) plus a plain
    DistanceConstraint (fixes the remaining Y up to sign) - 2 independent
    equations for the second Point's 2 unknowns, 0 degrees of freedom."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(0.0, 5.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_coincident_constraint(a.id, sketch.origin_point().id)
    sketch.add_vertical_constraint(line.id)
    sketch.add_distance_constraint(a.id, b.id, 5.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.dof == 0


def test_an_under_constrained_sketch_reports_nonzero_dof():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    sketch.add_distance_constraint(a.id, b.id, 10.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.dof > 0


def test_a_sketch_with_free_geometry_and_zero_constraints_reports_nonzero_dof():
    """Bug-fix round: solve_sketch() used to short-circuit to a canned
    dof=0 whenever a Sketch had no Constraints at all, regardless of how
    much free geometry it had - which made the sketcher's "fully
    constrained" indicator/line colouring light up for *any* freshly drawn,
    completely unconstrained geometry (every entity-placement tool solves
    once after creating it). Two free Points (4 unknowns, 0 equations) must
    report dof == 4, not 0."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    sketch.add_point(10.0, 0.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.dof == 4
    assert result.detail == "No constraints to solve."
    assert sketch.points[a.id].x == pytest.approx(0.0)  # positions untouched


def test_a_fully_constrained_sketch_reports_zero_dof_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 0.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": a["id"], "point_b_id": sketch["origin_point_id"]},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "vertical", "line_id": line["id"]},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["dof"] == 0
