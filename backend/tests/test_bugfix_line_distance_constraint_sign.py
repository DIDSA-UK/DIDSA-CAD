"""Bug-fix round: on-device feedback ("an across flats dimension over
constrains the polygon") reported a hexagon that needed to *resize* to a
new "across flats" LineDistanceConstraint value never actually moving -
result_code stayed non-zero and every one of the Polygon's own Points
showed as over-constrained, even for a perfectly achievable target value.

Root cause, confirmed empirically against the installed py-slvs build (see
`_signed_point_line_distance`'s own doc comment in models.py):
py-slvs's `addPointLineDistance` (wrapped by `SolverBuilder.
point_line_distance`, underlying both LineDistanceConstraint and
PointLineDistanceConstraint) is a genuinely *signed* perpendicular
distance - passing a plain positive magnitude that doesn't match Line 2's/
the Point's *current* side of Line 1 doesn't just solve to the mirrored
position (the way a simple, non-redundant two-Line system can absorb a
sign mismatch by freely repositioning both Lines - confirmed this still
converges either way when nothing else pins the Lines in place), it fails
to converge outright once the shape has no other freedom left to explore -
exactly a Polygon's own already-redundant EqualRadius/Angle chain, which
leaves only the LineDistanceConstraint itself with any give. A hexagon's
own opposite edges, needing to shrink to a new radius, never moved a
single Point when given a plain positive target value, but converged
immediately given the same magnitude negated.

The fix: `add_line_distance_constraint`/`add_point_line_distance_
constraint` (and `update_constraint_value`'s own PATCH equivalent, router.py)
work out the correct sign from whichever side the geometry is currently
on and store a signed `distance`, rather than trusting the caller's
always-positive value (a dimension is always typed in as a plain positive
magnitude - the UI has no way to ask "which side" and shouldn't need to).
"""

import math

import pytest

from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch


def test_add_line_distance_constraint_stores_a_signed_distance_matching_line2s_current_side():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 30.0)
    d = sketch.add_point(10.0, 30.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_line_distance_constraint(line1.id, line2.id, 50.0)

    assert constraint.distance == -50.0


def test_add_point_line_distance_constraint_stores_a_signed_distance_matching_the_points_current_side():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 5.0)
    line = sketch.add_line(a.id, b.id)

    constraint = sketch.add_point_line_distance_constraint(p.id, line.id, 5.0)

    assert constraint.distance == -5.0


def test_add_point_line_distance_constraint_at_zero_has_no_sign_to_flip():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 5.0)
    line = sketch.add_line(a.id, b.id)

    constraint = sketch.add_point_line_distance_constraint(p.id, line.id, 0.0)

    assert constraint.distance == 0.0


def _hexagon_across_flats_distance(sketch: Sketch, radius: float, sides: int = 6) -> tuple:
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(radius, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, sides)
    return polygon, center


def test_across_flats_line_distance_constraint_resizes_a_hexagon_to_a_new_radius():
    """The literal on-device repro: a hexagon drawn at one radius, then
    dimensioned "across flats" to a genuinely different (but perfectly
    achievable) target value - the real-world dimensioning workflow, not
    just the degenerate "already at the target value" case
    test_residual_verified_convergence.py's own tests happen to cover."""
    sketch = Sketch(id="s", plane=Plane.XY)
    polygon, center = _hexagon_across_flats_distance(sketch, radius=10.0)

    target_across_flats = 12.0
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], target_across_flats)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.solver_reported_failed_constraint_ids == []
    expected_radius = target_across_flats / (2 * math.cos(math.pi / 6))
    for vertex_id in polygon.vertex_point_ids:
        vertex = sketch.points[vertex_id]
        radius = math.hypot(vertex.x - center.x, vertex.y - center.y)
        assert radius == pytest.approx(expected_radius, abs=1e-6)


def test_across_flats_line_distance_constraint_resizes_a_pentagon_to_a_new_value():
    """Odd side counts have no exactly-opposite edge pair, but the same
    resize workflow (and the same signed-distance fix) still applies -
    matches the second on-device screenshot (a 5-sided Polygon, no
    reference circles, dimensioned to 18.00)."""
    sketch = Sketch(id="s", plane=Plane.XY)
    polygon, center = _hexagon_across_flats_distance(sketch, radius=10.0, sides=5)

    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], 18.0)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.solver_reported_failed_constraint_ids == []


def test_across_flats_line_distance_constraint_resizes_a_hexagon_with_reference_circles():
    """Same resize workflow with `reference_circles=True` (matches the
    first on-device screenshot) - the inscribed circle's own
    TangentConstraint must not interfere with the resize."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6, reference_circles=True)

    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], 12.0)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.solver_reported_failed_constraint_ids == []
