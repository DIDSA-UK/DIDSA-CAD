"""On-device feedback: adding an "across flats" LineDistanceConstraint
between two opposite edges of a Polygon reported the sketch as over-
constrained, even though the value exactly matched what the Polygon's own
already-redundant EqualLength/EqualRadius/AngleConstraint chain implies.

Root-caused directly against the real solver (see solver.py's own
`_residual_verified_convergence` doc comment): py-slvs's own `result_code`
cannot tell "doubly-redundant but still consistent" apart from a genuine
conflict here - both a correct and a deliberately wrong across-flats value
produce the identical `result_code=1`. These tests exercise the residual-
based fallback added to fix that, both the positive case (the fallback
lets a real, doubly-redundant-but-consistent dimension through) and the
negative case (it doesn't just rubber-stamp a genuinely wrong value)."""

import math

from app.sketch.constraints import DistanceConstraint
from app.sketch.models import Plane, Sketch
from app.sketch.solver import _residual_verified_convergence, solve_sketch


def test_polygon_across_flats_with_the_correct_value_converges():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    across_flats = 2 * 10.0 * math.cos(math.pi / 6)
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], across_flats)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.result_code != 0, (
        "sanity check: py-slvs itself must not cleanly certify this - the residual fallback is "
        "what makes it converged, not a lucky clean solve"
    )


def test_polygon_across_flats_with_the_correct_value_reports_no_failed_constraints():
    """Bug fix (on-device feedback: the 3D sketcher's Polygon vertices/edges
    still showed/behaved as over-constrained - red, undraggable - even
    though the across-flats dimension above converges correctly): py-slvs's
    own `system.Failed` is a *raw*, pre-override diagnostic, populated
    whenever `result_code != 0` - exactly the ambiguous case the residual
    fallback exists to reinterpret as a genuine, consistent solve. Left
    unguarded, `solve_sketch` used to return every one of the Sketch's
    constraint ids here regardless of `converged`, and the client
    (`SketchController.backendFlaggedOverConstrainedPointIds`) trusts that
    list unconditionally, with no `converged` check of its own - so a
    correctly-`converged=True` solve still poisoned every Polygon Point as
    "over constrained" downstream. Nothing should read as "failed" once the
    solve itself is reported converged."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    across_flats = 2 * 10.0 * math.cos(math.pi / 6)
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], across_flats)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.solver_reported_failed_constraint_ids == []


def test_polygon_edge_horizontal_constraint_converges_cleanly():
    """On-device feedback: "user places polygon > applies horizontal
    constraint to one side > polygon doesn't fully solve and looks wrong"
    (only fixing itself at some later, unrelated solve).

    Originally root-caused to a *different*, more subtle bug than the
    across-flats LineDistance tests above: py-slvs's own Newton solve used
    to empirically fail to actually rotate a Polygon's own already-
    redundant EqualLength/EqualRadius/Angle chain into a Horizontal-
    satisfying configuration in one pass, and this test used to assert
    that stuck, still-wrong result was at least *honestly* reported as
    `not converged` (see git history for that version) rather than a false
    `converged=True` positive.

    Superseded by the Polygon redesign (see that class's own docstring):
    switching the angle family from edge-to-edge to radial-line-to-radial-
    line (pinning each vertex's own central angle directly, rather than
    only the *average* of each neighbouring arc pair) turned out to fix
    this Newton-convergence-quality issue too, not just the redundancy it
    was actually aimed at - confirmed directly against the real solver:
    the exact same scenario that used to get stuck now converges cleanly,
    genuinely horizontal, `result_code == 0`, in one pass. This test now
    asserts the improved behaviour directly instead of merely the honest
    non-convergence report the old design was stuck with."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    sketch.add_horizontal_constraint(polygon.line_ids[0])
    result = solve_sketch(sketch)

    line0 = sketch.entities[polygon.line_ids[0]]
    point_a = sketch.points[line0.start_point_id]
    point_b = sketch.points[line0.end_point_id]
    assert abs(point_b.y - point_a.y) < 1e-6
    assert result.converged
    assert result.result_code == 0


def test_polygon_edge_horizontal_plus_across_flats_dimension_is_not_falsely_over_constrained():
    """On-device feedback: "user places polygon > applies horizontal
    constraint to one side > applies dimension between parallel lines >
    polygon shows as over constrained" - a genuinely self-consistent
    Polygon (Horizontal edge + a matching across-flats LineDistance, both
    actually satisfied) must not be flagged as over-constrained. Unlike a
    lone Horizontal constraint (see the sibling test above, which now
    converges cleanly on its own after the Polygon redesign), stacking an
    across-flats LineDistance on top of it still produces py-slvs's own
    ambiguous `result_code == 1` (a measurement across two exactly-parallel
    opposite edges of a genuinely regular/symmetric polygon is a real
    Jacobian singularity at that exact configuration, confirmed directly
    against the real solver - not fixed, or fixable, by any particular
    choice of *which* constraints define the Polygon's own regularity) -
    so residual verification is still exactly what's needed here. Points
    are set directly to a mathematically exact, already-satisfying
    configuration (bypassing the solve itself, whose own convergence
    quality for this specific stacked case is a separate concern from what
    this test verifies) so this exercises the residual-verification logic
    itself in isolation."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)
    sketch.add_horizontal_constraint(polygon.line_ids[0])

    radius = 10.0
    for index, vertex_id in enumerate(polygon.vertex_point_ids):
        angle = math.radians(60 + 60 * index)
        sketch.points[vertex_id].x = radius * math.cos(angle)
        sketch.points[vertex_id].y = radius * math.sin(angle)
    sketch.points[center.id].x = 0.0
    sketch.points[center.id].y = 0.0

    across_flats = 2 * radius * math.cos(math.pi / 6)
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], across_flats)

    assert _residual_verified_convergence(sketch) is True


def test_polygon_across_flats_with_a_wrong_value_is_still_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], 99.0)
    result = solve_sketch(sketch)

    assert not result.converged
    # A genuine non-convergence must still surface py-slvs's own diagnostic -
    # the fix that clears this list only applies once `converged` is True.
    assert result.solver_reported_failed_constraint_ids


def test_polygon_across_flats_is_not_polygon_specific_slot_style_redundancy_still_works():
    """The residual fallback isn't a Polygon-only special case - a Slot's
    own pre-existing redundant Tangent/EqualRadius chain (already handled
    by the narrower, longer-standing override above it in solver.py) must
    keep converging unaffected by this addition."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    slot = sketch.add_slot(center1.id, center2.id, 5.0)
    sketch.constraints[slot.radius_constraint_id].provisional = False

    result = solve_sketch(sketch)

    assert result.converged


def test_residual_check_respects_horizontal_orientation_not_plain_euclidean_distance():
    """Bug fix, found while investigating a Circle drag/collapse report: a
    "horizontal"/"vertical" DistanceConstraint pins only the X or Y
    separation, leaving the other axis free (see that class's own doc
    comment) - a Circle's own cardinal-point axis pins are always exactly
    this shape (orientation="horizontal"/"vertical", distance=0.0). The
    residual check used to compare plain Euclidean distance against the
    target value regardless of orientation, which would have incorrectly
    rejected this - the two Points are 100 units apart in Y, so Euclidean
    distance is ~100.1, nowhere near the target of 5 - even though the
    *horizontal* separation the constraint actually cares about is exactly
    5, genuinely satisfied."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(5.0, 100.0)
    horizontal = DistanceConstraint(id="h", point_a_id=a.id, point_b_id=b.id, distance=5.0, orientation="horizontal")
    sketch.constraints[horizontal.id] = horizontal

    assert _residual_verified_convergence(sketch) is True


def test_residual_check_still_rejects_a_genuinely_wrong_horizontal_distance():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(5.0, 100.0)
    horizontal = DistanceConstraint(id="h", point_a_id=a.id, point_b_id=b.id, distance=50.0, orientation="horizontal")
    sketch.constraints[horizontal.id] = horizontal

    assert _residual_verified_convergence(sketch) is False
