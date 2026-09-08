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

import pytest

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


def test_polygon_with_reference_circles_across_flats_with_the_correct_value_converges():
    """Bug fix (on-device feedback, screenshot showing every Polygon edge/
    radial Line still red/over-constrained after adding an across-flats
    dimension - even after the fix above): a Polygon placed with
    `reference_circles=True` (see `Sketch.add_polygon`'s own doc comment)
    ties its inscribed circle's own radius Point to the first edge's
    midpoint via an AtMidpointConstraint - `AtMidpointConstraint` was
    missing from `_RESIDUAL_CHECKABLE_CONSTRAINT_TYPES`, so its mere
    presence (true of every Polygon with reference circles) disqualified
    the whole Sketch from residual verification, reintroducing the exact
    over-constrained false positive the tests above already fixed for a
    plain Polygon - the cardinal points/their own EqualRadius+zero-Distance
    ties were never the problem (already residual-checkable); the
    AtMidpointConstraint was the gap."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6, reference_circles=True)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    across_flats = 2 * 10.0 * math.cos(math.pi / 6)
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], across_flats)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.solver_reported_failed_constraint_ids == []
    for vertex_id in polygon.vertex_point_ids:
        vertex = sketch.points[vertex_id]
        radius = math.hypot(vertex.x - center.x, vertex.y - center.y)
        assert radius == pytest.approx(10.0, abs=1e-6)


def test_polygon_with_reference_circles_across_flats_with_a_wrong_value_is_still_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6, reference_circles=True)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], 99.0)
    result = solve_sketch(sketch)

    assert not result.converged


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


def test_hexagon_horizontal_edge_plus_across_flats_dimension_converges_end_to_end_via_the_real_solver():
    """On-device feedback: "a line to line (across flats) dimension
    combined with a horizontal constraint on an edge causes a red outline
    and the solver fails to solve or considers over constrained. This is a
    typical method for fully constraining a hex or other polygon."

    Unlike `test_polygon_edge_horizontal_plus_across_flats_dimension_is_
    not_falsely_over_constrained` above (which deliberately bypasses the
    real solve, setting Points directly to a hand-computed exact
    configuration - see that test's own doc comment for why), this drives
    the actual end-to-end path a real on-device sketch takes: centre
    Coincident to the origin (the common "place at the origin" case,
    exactly like a user tapping there), reference circles on (also common
    for a driving-dimension polygon), one real `solve_sketch` call per
    step in tap order, no Points ever set directly. Confirms both that
    py-slvs's own Newton solve actually reaches a self-consistent
    horizontal-plus-across-flats configuration from this realistic seed
    (not assumed, verified), and that the residual-verified-convergence
    override correctly recognizes it once there - the two-layer gap this
    whole module exists to close."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6, reference_circles=True)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    origin = sketch.origin_point()
    sketch.add_coincident_constraint(center.id, origin.id)
    solve_sketch(sketch)

    sketch.add_horizontal_constraint(polygon.line_ids[0])
    result = solve_sketch(sketch)
    assert result.converged, "a lone Horizontal edge must converge cleanly on its own first"

    across_flats = 2 * 10.0 * math.cos(math.pi / 6)
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], across_flats)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.solver_reported_failed_constraint_ids == []
    line0 = sketch.entities[polygon.line_ids[0]]
    point_a = sketch.points[line0.start_point_id]
    point_b = sketch.points[line0.end_point_id]
    assert abs(point_b.y - point_a.y) < 1e-6, "the Horizontal edge must still actually be horizontal"
    for vertex_id in polygon.vertex_point_ids:
        vertex = sketch.points[vertex_id]
        radius = math.hypot(vertex.x - sketch.points[center.id].x, vertex.y - sketch.points[center.id].y)
        assert radius == pytest.approx(10.0, abs=1e-6)


@pytest.mark.parametrize("sides", [8, 9, 10, 11, 12, 16, 20, 24, 32])
@pytest.mark.parametrize("edge_index", [0, 1, 2, 3])
def test_polygon_horizontal_edge_alone_converges_at_every_side_count_and_starting_edge(sides, edge_index):
    """Bug fix (follow-up to the on-device report above, which is
    specifically about a hexagon and was already fixed there): a lone
    Horizontal constraint on one edge of a Polygon with 8 or more sides
    used to fail to converge at all (`result_code` 2, not the ambiguous
    4/5 this module's own residual fallback targets) starting from the
    perfectly-symmetric as-created seed every `add_polygon` caller starts
    from - the shape never rotated at all. Confirmed directly (this
    module's own git history) that neither reference_circles nor an
    origin Coincidence was a contributing factor, and that the minimum
    symmetry-breaking nudge needed to escape the trap only grows with
    side count - probed up to a 20-gon, where even a nudge approaching
    half a vertex's own angular spacing still failed, ruling out any
    single fixed-magnitude nudge as a robust fix.

    Root-caused instead to a pure Newton-seeding gap with a closed-form
    answer: `Sketch._seed_polygon_edge_axis_rotation` (called from
    `add_horizontal_constraint`/`add_vertical_constraint` directly) now
    pre-seeds the Polygon's own vertices at the exact rotation Horizontal/
    Vertical needs before the solve ever runs, rather than leaving Newton
    to search for it - see that method's own doc comment for the full
    derivation. This drives the real end-to-end path (no Points ever set
    directly, unlike the doubly-redundant-case test above), parametrized
    across every side count 8-32 this bug reproduced at and every
    starting edge index, confirming both a clean `result_code == 0` (a
    real convergence, not one the residual fallback needed to rescue) and
    that the shape is genuinely horizontal, not just reported converged."""
    if edge_index >= sides:
        pytest.skip("edge_index only meaningful up to this Polygon's own side count")
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, sides)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    sketch.add_horizontal_constraint(polygon.line_ids[edge_index])
    result = solve_sketch(sketch)

    line = sketch.entities[polygon.line_ids[edge_index]]
    point_a = sketch.points[line.start_point_id]
    point_b = sketch.points[line.end_point_id]
    assert result.converged and result.result_code == 0
    assert abs(point_b.y - point_a.y) < 1e-6


def test_polygon_vertical_edge_alone_converges_at_a_high_side_count():
    """[_seed_polygon_edge_axis_rotation]'s own Vertical-targeting branch -
    the sibling test above only ever exercises Horizontal."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 16)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    sketch.add_vertical_constraint(polygon.line_ids[0])
    result = solve_sketch(sketch)

    line0 = sketch.entities[polygon.line_ids[0]]
    point_a = sketch.points[line0.start_point_id]
    point_b = sketch.points[line0.end_point_id]
    assert result.converged and result.result_code == 0
    assert abs(point_b.x - point_a.x) < 1e-6


def test_polygon_horizontal_edge_seeding_still_converges_stacked_with_across_flats_at_a_high_side_count():
    """The full on-device scenario (Horizontal edge + a matching
    across-flats LineDistance together), but at a side count high enough
    that the lone-Horizontal seeding fix above is load-bearing on its own
    first - confirms the two fixes compose correctly rather than each
    only being validated in isolation."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 12, reference_circles=True)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    origin = sketch.origin_point()
    sketch.add_coincident_constraint(center.id, origin.id)
    solve_sketch(sketch)

    sketch.add_horizontal_constraint(polygon.line_ids[0])
    result = solve_sketch(sketch)
    assert result.converged and result.result_code == 0

    across_flats = 2 * 10.0 * math.cos(math.pi / 12)
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[6], across_flats)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.solver_reported_failed_constraint_ids == []
    line0 = sketch.entities[polygon.line_ids[0]]
    point_a = sketch.points[line0.start_point_id]
    point_b = sketch.points[line0.end_point_id]
    assert abs(point_b.y - point_a.y) < 1e-6


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


# --- Bug fix: Coincident/Collinear/PointOnLine/Perpendicular/Concentric ------
#
# On-device feedback: an ordinary hand-drawn profile mixing Horizontal/
# Vertical constraints with a Collinear (tying two segments into one
# straight run) and/or Coincident-joined endpoints - a completely standard
# dimensioning pattern, not an edge case - showed red/over-constrained even
# though it's genuinely solvable. Root cause: these five types were entirely
# missing from `_RESIDUAL_CHECKABLE_CONSTRAINT_TYPES`, so their mere
# *presence* anywhere in the Sketch disqualified the whole thing from
# residual verification, the same class of gap `test_polygon_with_
# reference_circles_across_flats_with_the_correct_value_converges` above
# already fixed once for AtMidpointConstraint/Polygon reference circles.
#
# Each type gets its own direct residual-function test (positive: an
# already-exact satisfying configuration set directly on `sketch.points`,
# bypassing the solve itself, mirroring `test_hexagon_across_flats_...`
# above; negative: the same constraint against a genuinely wrong
# configuration), then one end-to-end test reproducing the actual reported
# shape - a Polygon's own already-redundant chain (proven rescuable above)
# with an *additional*, independently-redundant Coincident/Collinear
# constraint stacked on top, confirming that addition no longer disqualifies
# the whole Sketch the way it did before this fix.


def test_coincident_residual_holds_for_two_points_at_the_same_position():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(3.0, 4.0)
    b = sketch.add_point(3.0, 4.0)
    sketch.add_coincident_constraint(a.id, b.id)

    assert _residual_verified_convergence(sketch) is True


def test_coincident_residual_rejects_two_points_at_different_positions():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(3.0, 4.0)
    b = sketch.add_point(3.0, 5.0)
    sketch.add_coincident_constraint(a.id, b.id)

    assert _residual_verified_convergence(sketch) is False


def test_concentric_residual_holds_for_two_circles_with_the_same_centre():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    edge1 = sketch.add_point(5.0, 0.0)
    circle1 = sketch.add_circle(center1.id, edge1.id)
    center2 = sketch.add_point(0.0, 0.0)
    edge2 = sketch.add_point(0.0, 2.0)
    circle2 = sketch.add_circle(center2.id, edge2.id)
    sketch.add_concentric_constraint(circle1.id, circle2.id)

    assert _residual_verified_convergence(sketch) is True


def test_concentric_residual_rejects_two_circles_with_different_centres():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    edge1 = sketch.add_point(5.0, 0.0)
    circle1 = sketch.add_circle(center1.id, edge1.id)
    center2 = sketch.add_point(1.0, 1.0)
    edge2 = sketch.add_point(1.0, 3.0)
    circle2 = sketch.add_circle(center2.id, edge2.id)
    sketch.add_concentric_constraint(circle1.id, circle2.id)

    assert _residual_verified_convergence(sketch) is False


def test_perpendicular_residual_holds_for_two_genuinely_perpendicular_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 0.0)
    d = sketch.add_point(0.0, 7.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_perpendicular_constraint(line1.id, line2.id)

    assert _residual_verified_convergence(sketch) is True


def test_perpendicular_residual_rejects_two_lines_that_are_not_perpendicular():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 0.0)
    d = sketch.add_point(5.0, 5.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_perpendicular_constraint(line1.id, line2.id)

    assert _residual_verified_convergence(sketch) is False


def test_point_on_line_residual_holds_for_a_point_exactly_on_the_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    point = sketch.add_point(4.0, 0.0)
    sketch.add_point_on_line_constraint(point.id, line.id)

    assert _residual_verified_convergence(sketch) is True


def test_point_on_line_residual_rejects_a_point_off_the_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    point = sketch.add_point(4.0, 1.0)
    sketch.add_point_on_line_constraint(point.id, line.id)

    assert _residual_verified_convergence(sketch) is False


def test_collinear_residual_holds_for_two_lines_on_the_same_straight_run():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(15.0, 0.0)
    d = sketch.add_point(20.0, 0.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_collinear_constraint(line1.id, line2.id)

    assert _residual_verified_convergence(sketch) is True


def test_collinear_residual_rejects_two_lines_that_are_not_collinear():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(15.0, 1.0)
    d = sketch.add_point(20.0, 1.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_collinear_constraint(line1.id, line2.id)

    assert _residual_verified_convergence(sketch) is False


def test_collinear_residual_is_never_verified_against_a_degenerate_zero_length_line1():
    """Guard mirroring CurveTangentConstraint's own degenerate-concentric-
    centres branch above: a near-zero-length Line 1 has no well-defined
    "line through its endpoints" - must never be treated as trivially
    satisfied."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(5.0, 5.0)
    b = sketch.add_point(5.0 + 1e-10, 5.0)
    c = sketch.add_point(0.0, 0.0)
    d = sketch.add_point(10.0, 0.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_collinear_constraint(line1.id, line2.id)

    assert _residual_verified_convergence(sketch) is False


def test_polygon_across_flats_plus_a_redundant_but_satisfied_coincident_constraint_still_converges():
    """Reproduces the actual reported bug shape: an already-known-rescuable
    stacked-redundancy Sketch (the Polygon-across-flats case above) with an
    *additional* Coincident constraint stacked on top - before this fix,
    CoincidentConstraint's mere presence disqualified the whole Sketch from
    residual verification regardless of how well-understood every other
    Constraint was."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    across_flats = 2 * 10.0 * math.cos(math.pi / 6)
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], across_flats)

    # A harmless, exactly-satisfied Coincident constraint between a new
    # Point and the polygon's own already-solved centre - real redundancy
    # (the new Point adds no actual freedom of its own once pinned here),
    # genuinely consistent, exactly the class this fix targets.
    duplicate_center = sketch.add_point(center.x, center.y)
    sketch.add_coincident_constraint(center.id, duplicate_center.id)

    result = solve_sketch(sketch)

    assert result.converged


def test_stepped_rectangle_with_horizontal_vertical_and_collinear_converges():
    """Reproduces the reported screenshot's actual shape: a stepped/notched
    profile fully dimensioned with Horizontal/Vertical constraints on every
    edge (a completely ordinary dimensioning practice), plus a Collinear
    constraint tying an extra wall segment onto the same line as one of the
    profile's own edges - genuinely solvable (the Collinear is exactly
    satisfied by construction below), but its mere presence used to
    disqualify the whole Sketch from residual verification."""
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    p2 = sketch.add_point(10.0, 6.0)
    p3 = sketch.add_point(6.0, 6.0)
    p4 = sketch.add_point(6.0, 10.0)
    p5 = sketch.add_point(0.0, 10.0)

    bottom = sketch.add_line(p0.id, p1.id)
    right_lower = sketch.add_line(p1.id, p2.id)
    step = sketch.add_line(p2.id, p3.id)
    right_upper = sketch.add_line(p3.id, p4.id)
    top = sketch.add_line(p4.id, p5.id)
    left = sketch.add_line(p5.id, p0.id)

    for line in (bottom, top):
        sketch.add_horizontal_constraint(line.id)
    for line in (right_lower, right_upper, left):
        sketch.add_vertical_constraint(line.id)
    sketch.add_horizontal_constraint(step.id)

    sketch.add_distance_constraint(p0.id, p1.id, 10.0)
    sketch.add_distance_constraint(p5.id, p0.id, 10.0)
    sketch.add_distance_constraint(p4.id, p5.id, 6.0)
    sketch.add_distance_constraint(p1.id, p2.id, 6.0)

    # An extra wall segment, unconnected to the profile, deliberately built
    # exactly along the extension of the left edge's own line (x=0) - a
    # real Collinear use case (aligning a separate wall to an existing one)
    # that is exactly satisfied by construction, so the Sketch as a whole
    # must still converge once Collinear no longer disqualifies it.
    extra_a = sketch.add_point(0.0, -5.0)
    extra_b = sketch.add_point(0.0, -15.0)
    extra_wall = sketch.add_line(extra_a.id, extra_b.id)
    sketch.add_collinear_constraint(left.id, extra_wall.id)

    result = solve_sketch(sketch)

    assert result.converged
