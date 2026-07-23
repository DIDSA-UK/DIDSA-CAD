"""Wires a Sketch's Points + Constraints (Stage 2) to py-slvs (Stage 2a).

Solving is explicit and batched: solve_sketch() is only ever called from
the POST .../solve endpoint, never as a side effect of editing a Point or
adding/removing a Constraint. A Point's x/y at the time solve_sketch() is
called is used as py-slvs's initial guess for that Point.

Over-constrained/unsatisfiable systems are solved anyway, never rejected.
See SolveResult for how non-convergence is reported.
"""

import math
from dataclasses import dataclass, field

from py_slvs import slvs

from app.sketch.constraints import (
    AngleConstraint,
    CoincidentConstraint,
    CollinearConstraint,
    DistanceConstraint,
    EqualLengthConstraint,
    EqualRadiusConstraint,
    HorizontalConstraint,
    LineDistanceConstraint,
    ParallelConstraint,
    PerpendicularConstraint,
    PointLineDistanceConstraint,
    SplineTangentConstraint,
    TangentConstraint,
    VerticalConstraint,
)
from app.sketch.models import Point, Sketch

# Constraint types empirically confirmed to never need py-slvs's own
# redundancy detection to distrust a converged solve - see `converged`'s
# own comment in solve_sketch below for why this allowlist exists and, just
# as importantly, why AtMidpointConstraint is deliberately excluded from it.
_REDUNDANCY_SAFE_CONSTRAINT_TYPES = (
    DistanceConstraint,
    VerticalConstraint,
    HorizontalConstraint,
    AngleConstraint,
    CoincidentConstraint,
    ParallelConstraint,
    PerpendicularConstraint,
    EqualLengthConstraint,
    CollinearConstraint,
    LineDistanceConstraint,
    PointLineDistanceConstraint,
    SplineTangentConstraint,
    TangentConstraint,
    EqualRadiusConstraint,
)

# Constraint types `_residual_verified_convergence` (below) knows how to
# check directly from solved Point positions - a closed allowlist, same
# conservative shape as `_REDUNDANCY_SAFE_CONSTRAINT_TYPES` above (only
# trusted when *every* Constraint in the Sketch is one of these; falls
# through to ordinary non-convergence reporting otherwise, rather than
# silently ignoring a Constraint type it doesn't know how to verify).
#
# Bug fix (on-device feedback: a Polygon's own edge, given a Horizontal
# constraint, "doesn't fully solve and looks wrong" until an unrelated
# later solve happens to converge cleanly; a further LineDistanceConstraint
# on top then shows the whole Polygon as falsely over-constrained): a
# Regular Polygon's own EqualLength/EqualRadius/Angle chain is already
# redundant by construction, so stacking one further genuinely-implied
# Constraint (Horizontal, or an "across flats" LineDistanceConstraint) on
# top reliably produces py-slvs's own ambiguous `result_code=1` - the exact
# case this residual-verification path exists to disambiguate. Horizontal/
# VerticalConstraint were missing from this allowlist for no principled
# reason (they're just as directly, cheaply residual-checkable as any other
# entry here - see the two new branches below) - their mere *presence*
# disqualified the whole Sketch from residual verification even though the
# check loop never actually needed to understand them to correctly verify
# every other Constraint sharing the Sketch with one.
_RESIDUAL_CHECKABLE_CONSTRAINT_TYPES = (
    DistanceConstraint,
    EqualLengthConstraint,
    EqualRadiusConstraint,
    AngleConstraint,
    TangentConstraint,
    LineDistanceConstraint,
    HorizontalConstraint,
    VerticalConstraint,
    ParallelConstraint,
)

_RESIDUAL_TOLERANCE = 1e-4


def _distance(a: Point, b: Point) -> float:
    return math.hypot(b.x - a.x, b.y - a.y)


def _point_line_distance(point: Point, line_start: Point, line_end: Point) -> float:
    """Perpendicular distance from `point` to the infinite line through
    `line_start`/`line_end`."""
    dx = line_end.x - line_start.x
    dy = line_end.y - line_start.y
    length = math.hypot(dx, dy)
    if length < 1e-12:
        return _distance(point, line_start)
    cross = (point.x - line_start.x) * dy - (point.y - line_start.y) * dx
    return abs(cross) / length


def _angle_between_degrees(line1_start: Point, line1_end: Point, line2_start: Point, line2_end: Point) -> float:
    """Unsigned angle (0-180) between two Lines' direction vectors -
    deliberately unsigned since verifying an already-supposedly-satisfied
    redundant AngleConstraint only needs to confirm the *magnitude* matches,
    not reproduce py-slvs's own internal signed convention (which depends on
    solver-internal parameterization this residual check has no access to)."""
    dir1 = (line1_end.x - line1_start.x, line1_end.y - line1_start.y)
    dir2 = (line2_end.x - line2_start.x, line2_end.y - line2_start.y)
    len1 = math.hypot(*dir1)
    len2 = math.hypot(*dir2)
    if len1 < 1e-12 or len2 < 1e-12:
        return 0.0
    dot = (dir1[0] * dir2[0] + dir1[1] * dir2[1]) / (len1 * len2)
    return math.degrees(math.acos(max(-1.0, min(1.0, dot))))


def _residual_verified_convergence(sketch: Sketch) -> bool | None:
    """A solve that didn't cleanly report `converged` can still have landed
    on a genuinely valid, self-consistent set of Point positions - py-slvs's
    own `result_code` cannot always tell "every Constraint is actually
    satisfied, just redundantly so in a way this build's rank-deficiency
    handling doesn't cleanly certify" apart from a real conflict (confirmed
    directly: a Polygon's own already-redundant EqualLength/EqualRadius/
    Angle chain plus one further genuinely-implied Constraint on top - e.g.
    an "across flats" LineDistanceConstraint between two opposite edges -
    and a *deliberately wrong* value on that same Constraint both produce
    the identical `result_code=1`; the existing narrow `result_code in (4,
    5)` override above only ever catches a *single* layer of redundancy, not
    two stacked). Rather than trust the code, this recomputes every
    Constraint's own residual directly from the just-solved Point positions
    (already written back to `sketch.points` by the time this runs) - if
    every one is satisfied within tolerance, the positions are a real
    solution regardless of what `result_code` says, so it's safe to report
    `converged`.

    Returns `None` (not `False`) if any Constraint isn't one of
    `_RESIDUAL_CHECKABLE_CONSTRAINT_TYPES` - deliberately distinct from a
    confident `False` ("checked every Constraint, at least one residual is
    genuinely too large"). Bug fix: this used to conflate the two into a
    single `bool`, and the caller's own narrow `result_code in (4, 5)`
    fallback override (immediately below this function's own call site) ran
    *unconditionally* whenever this function returned a falsy value - so a
    confidently-`False` "no, this really isn't converged" (e.g. a Polygon
    edge nowhere near horizontal despite a HorizontalConstraint on it) was
    silently overridden back to `converged=True` by that older, weaker
    check the moment the same Sketch also happened to contain an
    EqualRadiusConstraint (true of every Polygon), same "never guess about
    a type it can't verify" conservatism `_REDUNDANCY_SAFE_CONSTRAINT_TYPES`
    already uses - only now the caller can tell "I don't know" apart from
    "I checked, and no."
    """
    constraints = list(sketch.constraints.values())
    if not constraints or not all(isinstance(c, _RESIDUAL_CHECKABLE_CONSTRAINT_TYPES) for c in constraints):
        return None

    points = sketch.points
    # Scale tolerance to the Sketch's own size, same idea already proven in
    # the client's local-solver drag guards (sketch_controller.dart's
    # _trySolveDuringDragLocally) - an absolute tolerance would be either
    # too loose for a tiny sketch or too tight for a large one.
    xs = [p.x for p in points.values()]
    ys = [p.y for p in points.values()]
    diagonal = math.hypot((max(xs) - min(xs)) if xs else 0.0, (max(ys) - min(ys)) if ys else 0.0)
    tolerance = max(diagonal * _RESIDUAL_TOLERANCE, 1e-6)

    for constraint in constraints:
        if isinstance(constraint, DistanceConstraint):
            if constraint.provisional:
                continue  # Skipped by the solve itself - nothing to verify.
            point_a = points[constraint.point_a_id]
            point_b = points[constraint.point_b_id]
            # Bug fix: a "horizontal"/"vertical" DistanceConstraint pins
            # only the X or Y separation, leaving the other axis free (see
            # that class's own doc comment) - checking plain Euclidean
            # distance against it here was wrong on two counts: it could
            # reject an actually-satisfied projected constraint whose two
            # Points are far apart on the free axis (a false negative), and
            # - the concrete bug that surfaced this, found while
            # investigating a Circle's own cardinal-point axis pins (always
            # `orientation="vertical"`/`"horizontal"`, `distance=0.0`) -
            # it could just as easily accept a genuinely broken solve
            # whose Points happen to have also collapsed together on the
            # free axis, since a coincident pair trivially reads as
            # "Euclidean distance 0" regardless of orientation (a false
            # positive).
            if constraint.orientation == "horizontal":
                actual = abs(point_b.x - point_a.x)
            elif constraint.orientation == "vertical":
                actual = abs(point_b.y - point_a.y)
            else:
                actual = _distance(point_a, point_b)
            if abs(actual - abs(constraint.distance)) > tolerance:
                return False
        elif isinstance(constraint, EqualLengthConstraint):
            len1 = _distance(points[constraint.line1_start_id], points[constraint.line1_end_id])
            len2 = _distance(points[constraint.line2_start_id], points[constraint.line2_end_id])
            if abs(len1 - len2) > tolerance:
                return False
        elif isinstance(constraint, EqualRadiusConstraint):
            r1 = _distance(points[constraint.center1_point_id], points[constraint.radius1_point_id])
            r2 = _distance(points[constraint.center2_point_id], points[constraint.radius2_point_id])
            if abs(r1 - r2) > tolerance:
                return False
        elif isinstance(constraint, AngleConstraint):
            actual_degrees = _angle_between_degrees(
                points[constraint.line1_start_id],
                points[constraint.line1_end_id],
                points[constraint.line2_start_id],
                points[constraint.line2_end_id],
            )
            target_degrees = abs(constraint.angle_degrees) % 360
            target_degrees = min(target_degrees, 360 - target_degrees)
            if abs(actual_degrees - target_degrees) > 1e-2:
                return False
        elif isinstance(constraint, TangentConstraint):
            radius = _distance(points[constraint.center_point_id], points[constraint.radius_point_id])
            actual_distance = _point_line_distance(
                points[constraint.center_point_id],
                points[constraint.line_start_id],
                points[constraint.line_end_id],
            )
            if abs(actual_distance - radius) > tolerance:
                return False
        elif isinstance(constraint, LineDistanceConstraint):
            actual_distance = _point_line_distance(
                points[constraint.line2_start_id],
                points[constraint.line1_start_id],
                points[constraint.line1_end_id],
            )
            if abs(actual_distance - constraint.distance) > tolerance:
                return False
        elif isinstance(constraint, HorizontalConstraint):
            point_a = points[constraint.point_a_id]
            point_b = points[constraint.point_b_id]
            if abs(point_b.y - point_a.y) > tolerance:
                return False
        elif isinstance(constraint, VerticalConstraint):
            point_a = points[constraint.point_a_id]
            point_b = points[constraint.point_b_id]
            if abs(point_b.x - point_a.x) > tolerance:
                return False
        elif isinstance(constraint, ParallelConstraint):
            dir1 = (
                points[constraint.line1_end_id].x - points[constraint.line1_start_id].x,
                points[constraint.line1_end_id].y - points[constraint.line1_start_id].y,
            )
            dir2 = (
                points[constraint.line2_end_id].x - points[constraint.line2_start_id].x,
                points[constraint.line2_end_id].y - points[constraint.line2_start_id].y,
            )
            len1 = math.hypot(*dir1)
            len2 = math.hypot(*dir2)
            if len1 < 1e-9 or len2 < 1e-9:
                continue  # A zero-length Line has no direction to compare - nothing to check.
            # sin(angle between the two directions) - scale-invariant (unlike
            # the raw cross product, which carries units of length^2), so a
            # fixed small threshold works regardless of the Sketch's own size.
            sin_angle = abs(dir1[0] * dir2[1] - dir1[1] * dir2[0]) / (len1 * len2)
            if sin_angle > 1e-4:
                return False

    return True


# Group 1 holds the fixed workplane (origin + normal); group 2 holds every
# Point/Constraint being solved. There is no need for finer-grained groups
# at this stage - the whole Sketch is solved as one batch.
_FIXED_GROUP = 1
_SOLVE_GROUP = 2


@dataclass
class SolveResult:
    """Outcome of solving one Sketch's constraints.

    `blamed_constraint_ids` is a *convention*, not a diagnosis: it names the
    most-recently-added constraint when the system fails to fully converge,
    on the simple heuristic that the last constraint added is the most
    likely culprit. py-slvs itself cannot attribute non-convergence to a
    single constraint - see `solver_reported_failed_constraint_ids` below,
    which is its own (real, but coarse) diagnostic, kept clearly separate
    from the convention. It's a list (not a single optional id) so a future
    subset-removal diagnosis (retrying with one constraint removed at a
    time) can populate it with more than one id without changing this
    shape.

    `solver_reported_failed_constraint_ids` is py-slvs's own `Failed` list,
    translated from its internal handles back to our Constraint ids.
    Empirically (see backend/tests/test_stage2b_solver_integration.py),
    py-slvs reports *every* constraint in an inconsistent system here, not
    a single root cause - it's surfaced for transparency, not used for
    blame.

    `dof` is py-slvs's degrees-of-freedom count (System.Dof) and
    `result_code` is the raw return value of System.solve() (0 = success).
    Both are genuine py-slvs diagnostics, included alongside the above.
    """

    converged: bool
    dof: int
    result_code: int
    blamed_constraint_ids: list[str] = field(default_factory=list)
    solver_reported_failed_constraint_ids: list[str] = field(default_factory=list)
    detail: str = ""


class _PySlvsBuilder:
    """Adapts a Sketch's Points to py-slvs handles, creating each Point's
    py-slvs entity lazily (on first reference by a Constraint) using that
    Point's current x/y as the initial guess."""

    def __init__(
        self,
        system: "slvs.System",
        workplane: int,
        points: dict[str, Point],
        origin_point_id: str | None = None,
        anchor_point_ids: frozenset[str] = frozenset(),
    ):
        self._system = system
        self._workplane = workplane
        self._points = points
        self._point_handles: dict[str, int] = {}
        self._line_handles: dict[tuple[int, int], int] = {}
        self._cubic_handles: dict[tuple[int, int, int, int], int] = {}
        self._horizontal_ref_line: int | None = None
        self._vertical_ref_line: int | None = None
        # The Sketch's origin Point (see Sketch.origin_point) is real,
        # addressable geometry - snappable and referenceable like any other
        # Point - but must never drift under the solver. Adding it (and only
        # it) to the fixed group rather than the solve group achieves this
        # the same way the workplane's own origin/normal are fixed: a point
        # added to a group never passed to system.solve(group=...) keeps
        # whatever initial value it was given, here always (0, 0).
        self._origin_point_id = origin_point_id
        # Stage: drag-solve semantics ("dragged Point stays put, others move
        # to accommodate"). A Point the client just dragged (or, for a
        # dragged Line, both its endpoints) is pinned into the fixed group
        # for this one solve call the same way the origin always is - not
        # persisted anywhere, just a per-call hint. A Constraint tying an
        # anchored Point to a *free* Point (e.g. a fixed-length dimension)
        # still converges normally - the free Point simply moves to satisfy
        # it. It's a Constraint tying an anchored Point to *another already-
        # fixed* position (the origin, or a second anchored Point) that
        # can't converge, since neither side is free to move to match the
        # other - see `solve_sketch`'s retry-without-anchors fallback for
        # how that case is resolved rather than left stuck.
        self._anchor_point_ids = anchor_point_ids

    def point2d(self, point_id: str) -> int:
        if point_id not in self._point_handles:
            point = self._points[point_id]
            is_pinned = point_id == self._origin_point_id or point_id in self._anchor_point_ids
            group = _FIXED_GROUP if is_pinned else _SOLVE_GROUP
            pu = self._system.addParamV(point.x, group=group)
            pv = self._system.addParamV(point.y, group=group)
            self._point_handles[point_id] = self._system.addPoint2d(
                self._workplane, pu, pv, group=group
            )
        return self._point_handles[point_id]

    def distance(self, point_a_handle: int, point_b_handle: int, value: float) -> int:
        return self._system.addPointsDistance(
            value, point_a_handle, point_b_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def _fixed_ref_point(self, u: float, v: float) -> int:
        pu = self._system.addParamV(u, group=_FIXED_GROUP)
        pv = self._system.addParamV(v, group=_FIXED_GROUP)
        return self._system.addPoint2d(self._workplane, pu, pv, group=_FIXED_GROUP)

    def _horizontal_ref_line_handle(self) -> int:
        """A fixed (never solved) line from (0, 0) to (1, 0) in workplane
        coordinates, used only as a direction reference for
        horizontal_distance below. py-slvs 1.0.6 has no
        addPointsHorizDistance/addPointsVertDistance primitive - the
        documented way to pin only one axis of separation between two
        points is addPointsProjectDistance (SLVS_C_PROJ_PT_DISTANCE)
        against a reference line in the desired direction. Lazily created
        and cached so at most one such line exists per solve, regardless of
        how many horizontal DistanceConstraints reference it."""
        if self._horizontal_ref_line is None:
            p0 = self._fixed_ref_point(0.0, 0.0)
            p1 = self._fixed_ref_point(1.0, 0.0)
            self._horizontal_ref_line = self._system.addLineSegment(p0, p1, group=_FIXED_GROUP)
        return self._horizontal_ref_line

    def _vertical_ref_line_handle(self) -> int:
        """Same as `_horizontal_ref_line_handle`, but a (0, 0)-(0, 1)
        reference line for vertical_distance."""
        if self._vertical_ref_line is None:
            p0 = self._fixed_ref_point(0.0, 0.0)
            p1 = self._fixed_ref_point(0.0, 1.0)
            self._vertical_ref_line = self._system.addLineSegment(p0, p1, group=_FIXED_GROUP)
        return self._vertical_ref_line

    def horizontal_distance(self, point_a_id: str, point_b_id: str, value: float) -> int:
        return self._project_distance(point_a_id, point_b_id, value, "x", self._horizontal_ref_line_handle())

    def vertical_distance(self, point_a_id: str, point_b_id: str, value: float) -> int:
        return self._project_distance(point_a_id, point_b_id, value, "y", self._vertical_ref_line_handle())

    def _project_distance(
        self, point_a_id: str, point_b_id: str, value: float, axis: str, ref_line_handle: int
    ) -> int:
        # Bug-fix round (on-device feedback, Phase 4.3): confirmed
        # empirically against the installed py-slvs build -
        # `addPointsProjectDistance` is a genuinely *signed* constraint,
        # not the unsigned magnitude `horizontal_distance`/`vertical_
        # distance`'s own doc comments used to assume (that assumption was
        # copied from `_fix_circle_cardinal_point_signs`'s finding, which
        # only holds there because it always uses a *zero* value - sign is
        # meaningless for `-0.0 == 0.0`). Confirmed via direct experiment:
        # for a positive `value`, `addPointsProjectDistance(value, a, b,
        # ref_line)` deterministically solves `proj(b - a) == -value`,
        # regardless of either Point's initial position (this is not a
        # Newton-branch-selection ambiguity - re-seeding the free Point's
        # initial guess, including seeding it exactly at the "expected"
        # answer, made no difference at all).
        #
        # Rather than hardcode a fixed sign convention (which would just
        # move the "which side does it land on" surprise from "always
        # wrong" to "deterministic but arbitrary, and still wrong half the
        # time depending on tap order" - confirmed by testing both), this
        # chooses the sign that preserves whichever side point_b *already*
        # sits on relative to point_a along this axis, before the solve -
        # the same "nudge the value, don't teleport the geometry" behaviour
        # a CAD user expects when refining a dimension, and the same
        # left-alone-if-already-satisfied default a Newton solver would
        # give if this primitive weren't seed-independent. Defaults to the
        # positive side only when the two Points start out exactly level
        # (or plumb) with each other, i.e. there is no existing side to
        # preserve.
        point_a = self._points[point_a_id]
        point_b = self._points[point_b_id]
        current_separation = getattr(point_b, axis) - getattr(point_a, axis)
        signed_value = -abs(value) if current_separation < 0 else abs(value)
        point_a_handle = self.point2d(point_a_id)
        point_b_handle = self.point2d(point_b_id)
        return self._system.addPointsProjectDistance(
            -signed_value, point_a_handle, point_b_handle, ref_line_handle, group=_SOLVE_GROUP
        )

    def vertical(self, point_a_handle: int, point_b_handle: int) -> int:
        return self._system.addPointsVertical(
            point_a_handle, point_b_handle, self._workplane, group=_SOLVE_GROUP
        )

    def horizontal(self, point_a_handle: int, point_b_handle: int) -> int:
        return self._system.addPointsHorizontal(
            point_a_handle, point_b_handle, self._workplane, group=_SOLVE_GROUP
        )

    def line_segment(self, point_a_handle: int, point_b_handle: int) -> int:
        key = (point_a_handle, point_b_handle)
        if key not in self._line_handles:
            self._line_handles[key] = self._system.addLineSegment(
                point_a_handle, point_b_handle, group=_SOLVE_GROUP
            )
        return self._line_handles[key]

    def cubic(
        self, p0_handle: int, p1_handle: int, p2_handle: int, p3_handle: int
    ) -> int:
        key = (p0_handle, p1_handle, p2_handle, p3_handle)
        if key not in self._cubic_handles:
            self._cubic_handles[key] = self._system.addCubic(
                self._workplane, p0_handle, p1_handle, p2_handle, p3_handle, group=_SOLVE_GROUP
            )
        return self._cubic_handles[key]

    def curves_tangent(
        self, at_end1: bool, at_end2: bool, curve1_handle: int, curve2_handle: int
    ) -> int:
        return self._system.addCurvesTangent(
            at_end1, at_end2, curve1_handle, curve2_handle, self._workplane, group=_SOLVE_GROUP
        )

    def angle(
        self,
        line_a_handle: int,
        line_b_handle: int,
        degrees: float,
        line_a_start_id: str,
        line_a_end_id: str,
        line_b_start_id: str,
        line_b_end_id: str,
    ) -> int:
        supplement = self._angle_needs_supplement(
            degrees, line_a_start_id, line_a_end_id, line_b_start_id, line_b_end_id
        )
        return self._system.addAngle(
            degrees, supplement, line_a_handle, line_b_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def _angle_needs_supplement(
        self, degrees: float, line_a_start_id: str, line_a_end_id: str, line_b_start_id: str, line_b_end_id: str
    ) -> bool:
        """py-slvs's addAngle takes a `supplement` flag choosing between
        constraining the angle to `degrees` or to its supplement
        (180 - degrees) - confirmed by direct experiment against the
        installed py-slvs build that this is a genuine, un-auto-resolved
        ambiguity (unlike the ordinary +/- sign of an angle/distance, which
        Newton's method already picks correctly to match whichever side the
        seed geometry is already on, from any seed, however far off).
        Always passing `False` here meant a Sketch already sitting near the
        *supplementary* configuration (e.g. one interior angle of a Polygon,
        mid-drag, while its neighbours hold the primary angle) would be
        forced to snap the ~135 degrees it already had to 45 - reported
        on-device as a dimension "flipping polarity" and, for a Polygon
        specifically, breaking its regular shape.

        Chooses whichever of `degrees`/`180 - degrees` is closer to the
        Lines' currently *measured* angle (the same "preserve what's
        already true" principle `_project_distance` below already uses for
        horizontal_distance/vertical_distance's sign) - a no-op returning
        False when either Line has zero current length, since there is no
        current angle to preserve in that case."""
        a_start, a_end = self._points[line_a_start_id], self._points[line_a_end_id]
        b_start, b_end = self._points[line_b_start_id], self._points[line_b_end_id]
        a_dx, a_dy = a_end.x - a_start.x, a_end.y - a_start.y
        b_dx, b_dy = b_end.x - b_start.x, b_end.y - b_start.y
        a_len = math.hypot(a_dx, a_dy)
        b_len = math.hypot(b_dx, b_dy)
        if a_len == 0 or b_len == 0:
            return False
        cos_theta = max(-1.0, min(1.0, (a_dx * b_dx + a_dy * b_dy) / (a_len * b_len)))
        current_angle = math.degrees(math.acos(cos_theta))
        return abs((180.0 - degrees) - current_angle) < abs(degrees - current_angle)

    def coincident(self, point_a_handle: int, point_b_handle: int) -> int:
        return self._system.addPointsCoincident(
            point_a_handle, point_b_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def parallel(self, line_a_handle: int, line_b_handle: int) -> int:
        return self._system.addParallel(
            line_a_handle, line_b_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def perpendicular(self, line_a_handle: int, line_b_handle: int) -> int:
        return self._system.addPerpendicular(
            line_a_handle, line_b_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def equal_length(self, line_a_handle: int, line_b_handle: int) -> int:
        return self._system.addEqualLength(
            line_a_handle, line_b_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def equal_length_point_line_distance(
        self, point_handle: int, radius_line_handle: int, tangent_line_handle: int
    ) -> int:
        return self._system.addEqualLengthPointLineDistance(
            point_handle, radius_line_handle, tangent_line_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def point_on_line(self, point_handle: int, line_handle: int) -> int:
        return self._system.addPointOnLine(
            point_handle, line_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def point_line_distance(self, point_handle: int, line_handle: int, value: float) -> int:
        return self._system.addPointLineDistance(
            value, point_handle, line_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def at_midpoint(self, point_handle: int, line_handle: int) -> int:
        return self._system.addMidPoint(
            point_handle, line_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

    def solved_point_ids(self) -> list[str]:
        return list(self._point_handles)

    def handle_for_point(self, point_id: str) -> int:
        return self._point_handles[point_id]


def solve_sketch(sketch: Sketch, anchor_point_ids: frozenset[str] = frozenset()) -> SolveResult:
    """Build the py-slvs problem for `sketch`'s Points + Constraints, solve
    it, and write the resulting positions back onto `sketch.points` (best
    effort even when it doesn't fully converge). Does not mutate
    `sketch.constraints`.

    `anchor_point_ids` - drag-solve semantics: any Point id in this set
    holds exactly the x/y it already had (its position going into this
    solve, e.g. wherever the client just PATCHed it to mid-drag) rather
    than being free for the solver to move - see `_PySlvsBuilder`'s own
    doc comment for the fixed-group mechanism. Empty (the default)
    reproduces the previous behaviour exactly: nothing pinned beyond the
    sketch's own origin.

    If pinning those anchors leaves the system unable to converge (e.g. the
    dragged Point is Coincident with the fixed origin, or with another
    anchored Point - two fixed positions that a Constraint demands be
    equal, but aren't), the explicit Constraint wins: this retries once
    with no anchors at all and returns *that* result instead. Without this,
    the anchored attempt's non-convergence still writes back the anchored
    (dropped) position unchanged - since a Point pinned into the fixed
    group is never touched by the solve regardless of whether it
    converges - which looks like the drag "worked" until some unrelated
    later solve (with no anchor) finally pulls the Point back to satisfy
    the Constraint. Retrying immediately here gives the same end state
    without the confusing delay.

    Sketcher-roadmap Phase 4.3 v1: every id in `sketch.external_references`
    (a Point tracking a Body vertex from outside this Sketch) is pinned
    exactly like the origin already is, on *both* attempts - unlike
    `anchor_point_ids`, an external reference is never dropped on retry,
    since it represents fixed real-world geometry this Sketch has no
    business moving under any circumstance. This Sketch has no OCCT/Part
    access to *refresh* those positions from the Body's current topology
    (see `app.document.create_plane.refresh_external_references` for that
    half) - this only ever pins whatever `(x, y)` the Point already holds.
    """

    external_point_ids = frozenset(sketch.external_references)
    result = _solve_sketch_once(sketch, anchor_point_ids | external_point_ids)
    if anchor_point_ids and not result.converged:
        result = _solve_sketch_once(sketch, external_point_ids)
    if result.converged:
        _fix_circle_cardinal_point_signs(sketch)
    return result


def _fix_circle_cardinal_point_signs(sketch: Sketch) -> None:
    """Corrects a Circle's four cardinal Points (see `Circle.
    cardinal_point_ids`'s own doc comment) back onto their own designated
    side of centre, if this solve flipped one to its mirror position.

    Each cardinal Point is solver-pinned by an `EqualRadiusConstraint`
    (radius) plus a zero-value `DistanceConstraint` (same X or Y as
    centre) - together those admit *two* valid positions (e.g. "same X,
    radius away" is satisfied by both North and South). At this *zero*
    value, `addPointsProjectDistance` gives no way to rule the wrong one
    out at the constraint level - confirmed empirically: neither a
    negative `value` nor swapping the two Point arguments changes which
    side it converges to, since `-0.0 == 0.0` either way. (This is
    specific to the zero-value case here - for a *nonzero* value the same
    primitive is fully signed and deterministic, see `_PySlvsBuilder.
    _project_distance`'s own doc comment for the unrelated bug that
    surfaced there.) In practice this means a large jump in
    centre's position (typing new coordinates, or a big/fast drag) can
    converge to the mirrored solution instead of the nearer, correct one -
    Newton's method just finds *a* valid position close to the previous
    one, and "close" stops meaning "on the right side" once centre has
    moved far enough. Since both solutions are exact mirror images of each
    other through centre (this is a discrete 2-fold ambiguity, not a
    partial/approximate error), the fix is a cheap direct reflection
    rather than a re-solve: whichever coordinate the flipped Point's own
    constraint left unconstrained (X for North/South, Y for East/West) is
    checked against its expected sign relative to centre, and mirrored
    through centre if it's backwards.
    """
    for circle in sketch.circles():
        if len(circle.cardinal_point_ids) != 4:
            continue
        center = sketch.points.get(circle.center_point_id)
        if center is None:
            continue
        north_id, east_id, south_id, west_id = circle.cardinal_point_ids
        for point_id, expect_positive, axis in (
            (north_id, True, "y"),
            (east_id, True, "x"),
            (south_id, False, "y"),
            (west_id, False, "x"),
        ):
            point = sketch.points.get(point_id)
            if point is None:
                continue
            actual = point.y - center.y if axis == "y" else point.x - center.x
            is_positive = actual > 0
            if is_positive != expect_positive and actual != 0:
                point.x = 2 * center.x - point.x
                point.y = 2 * center.y - point.y


def _solve_sketch_once(sketch: Sketch, anchor_point_ids: frozenset[str]) -> SolveResult:
    """One py-slvs solve attempt - see `solve_sketch` for the retry-without-
    anchors fallback built on top of this.

    Always builds and solves the system - including every Point, even ones
    no Constraint references - rather than skipping straight to a canned
    "nothing to solve" result whenever `sketch.constraints` is empty. It
    used to skip (hardcoding `dof=0`), which was harmless before `dof` had
    any UI meaning, but is wrong once it does (see Bug-fix round item: the
    sketcher's "fully constrained" indicator/line colouring): a sketch with
    free, unconstrained geometry and zero Constraints is exactly the
    opposite of fully constrained, and must report a nonzero `dof`
    (verified directly against the installed py-slvs wheel - solving an
    otherwise-empty constraint set is safe and reports the correct free
    parameter count, not an error).
    """

    system = slvs.System()
    # The "V" suffix matters: addPoint3d (no V) takes existing param
    # *handles*, not raw coordinate values - passing literal 0/0/0 there
    # silently wires the origin to invalid param handle 0, which only
    # surfaces once a constraint dereferences a point's absolute (rather
    # than workplane-relative) position, e.g. AngleConstraint.
    origin = system.addPoint3dV(0, 0, 0, group=_FIXED_GROUP)
    normal = system.addNormal3dV(1, 0, 0, 0, group=_FIXED_GROUP)
    workplane = system.addWorkplane(origin, normal, group=_FIXED_GROUP)

    builder = _PySlvsBuilder(
        system,
        workplane,
        sketch.points,
        origin_point_id=sketch.origin_point_id,
        anchor_point_ids=anchor_point_ids,
    )

    constraint_id_by_handle: dict[int, str] = {}
    for constraint in sketch.constraints.values():
        if isinstance(constraint, DistanceConstraint) and constraint.provisional:
            # Not yet confirmed by the user - contributes zero DOF-removal,
            # exactly as if it didn't exist, until confirmed (see
            # DistanceConstraint.provisional's own doc comment).
            continue
        handle = constraint.add_to_solver(builder)
        constraint_id_by_handle[handle] = constraint.id

    # Register every Point - not just ones a Constraint happens to
    # reference - so its free parameters are counted toward `dof` below.
    # `point2d` is idempotent (a no-op for a Point already registered by a
    # Constraint above), and the Sketch's own origin Point is still pinned
    # into the fixed group exactly as before (see _PySlvsBuilder.point2d).
    for point_id in sketch.points:
        builder.point2d(point_id)

    result_code = system.solve(group=_SOLVE_GROUP, reportFailed=True)
    converged = result_code == 0

    # Point positions are written back *before* either redundancy override
    # below (both the narrow one and the residual-based one) rather than
    # after, the same "best effort even when it doesn't fully converge"
    # behaviour this function has always had - `_residual_verified_
    # convergence` needs the just-solved positions in `sketch.points` to
    # check against.
    for point_id in builder.solved_point_ids():
        handle = builder.handle_for_point(point_id)
        u_param = system.getEntityParam(handle, 0)
        v_param = system.getEntityParam(handle, 1)
        point = sketch.points[point_id]
        point.x = system.getParam(u_param).val
        point.y = system.getParam(v_param).val

    # Bug fix (on-device feedback: a Polygon's own edge, given a Horizontal
    # constraint plus a further "across flats" LineDistanceConstraint, was
    # reported as over-constrained/not-fully-solved even though the
    # geometry was genuinely consistent): this residual-verified check is
    # now run *before* the narrower Slot-shaped override below, not after.
    # `HorizontalConstraint`/`VerticalConstraint` are members of both
    # `_REDUNDANCY_SAFE_CONSTRAINT_TYPES` (below) and, as of this fix,
    # `_RESIDUAL_CHECKABLE_CONSTRAINT_TYPES` - so a Polygon's own
    # EqualRadius chain plus a Horizontal constraint satisfied the older
    # override's own trigger condition (`any(...EqualRadiusConstraint...)`)
    # and got blindly trusted on `result_code in (4, 5)` alone, without ever
    # actually checking whether the Horizontal constraint (or anything
    # else) was satisfied - confirmed directly: a genuinely *unconverged*
    # solve (a Polygon edge nowhere near horizontal) was accepted as
    # `converged=True` purely because it shared a result_code with a
    # real Slot. Running the stronger, numerically-verified check first
    # whenever every Constraint type is one it actually understands closes
    # that gap without weakening the older override's own already-narrow
    # scope for the Sketches it's still needed for (whatever mix of
    # `_REDUNDANCY_SAFE_CONSTRAINT_TYPES` types the residual checker
    # doesn't yet know how to verify).
    # `residual_result` is deliberately tri-state (`True`/`False`/`None`,
    # not a plain `bool`) - see `_residual_verified_convergence`'s own doc
    # comment for the bug a plain `bool` caused here: the narrow override
    # immediately below must only run when residual verification couldn't
    # rule on this Sketch at all (`None`), never when it confidently ruled
    # `False`.
    residual_result = _residual_verified_convergence(sketch) if not converged else None
    if residual_result is True:
        # Stacked redundancy (e.g. a Polygon's own already-redundant
        # EqualLength/EqualRadius/Angle chain plus a further genuinely-
        # implied Constraint on top, like an "across flats" LineDistance
        # between two opposite edges, or a Horizontal/Vertical constraint
        # on one of its own edges) - see `_residual_verified_convergence`'s
        # own doc comment for why `result_code` alone can't tell this apart
        # from a real conflict here.
        converged = True

    if (
        not converged
        and residual_result is None
        and result_code in (4, 5)
        and any(isinstance(c, (TangentConstraint, EqualRadiusConstraint)) for c in sketch.constraints.values())
        and all(isinstance(c, _REDUNDANCY_SAFE_CONSTRAINT_TYPES) for c in sketch.constraints.values())
    ):
        # A Slot's closed loop of 2 Arcs + 2 Lines, tied together with
        # Tangent/EqualRadius constraints, is *mathematically* over-
        # determined by exactly one redundant equation (radius + centre
        # positions alone fully determine every rim Point once tangency and
        # equal-radius are enforced). Upstream SolveSpace documents this
        # exact situation as SLVS_RESULT_REDUNDANT_OKAY=4 ("solved
        # correctly despite a redundant constraint"); the installed py-slvs
        # fork here (realthunder/solvespace) empirically reports 5 for it
        # instead - confirmed by comparing a genuinely inconsistent system
        # (contradictory DistanceConstraints on the same two points,
        # result_code=1, never 4/5) against a Slot's own constraint set,
        # which converges to numerically exact tangency (perpendicular
        # distance from each Arc's centre to each Line equals its radius,
        # to 4 decimal places) across varied starting positions, a live
        # point drag, and a live radius edit - every time.
        #
        # This override is intentionally narrow rather than a blanket
        # `result_code in (0, 4, 5)`: `_REDUNDANCY_SAFE_CONSTRAINT_TYPES`
        # excludes AtMidpointConstraint on purpose, because
        # test_two_at_midpoint_constraints_on_the_same_point_is_singular_
        # once_hv_ties_diagonals_together (test_stage15_constraints.py)
        # proves the *same* result_code can also mean a genuinely under-
        # constrained shape (an HV-constrained rectangle whose width/
        # height/position are never actually pinned) that py-slvs
        # nonetheless reports as dof == 0 - a real false positive a
        # blanket override would have silently reintroduced. Now only
        # reached once the stronger residual-verified check above has
        # already had - and passed up - its own chance to rule on the
        # Sketch, so this is a documented fallback for constraint-type
        # combinations that check doesn't understand, not the primary
        # source of truth it used to be.
        converged = True

    # On-device feedback: a freshly-drawn Slot (2 Arcs tied together via
    # Tangent/EqualRadius, arc1's own radius DistanceConstraint still
    # `provisional` - see that flag's own doc comment) showed as fully
    # constrained (padlocked green) the instant it was drawn, before the
    # user ever confirmed a radius value. Root cause: `system.Dof` above is
    # py-slvs's own naive param-count-minus-equation-count for this
    # *redundant* system (the whole reason the REDUNDANT_OKAY override two
    # paragraphs up exists at all) - it does not distinguish "the one
    # genuinely-implied-by-the-others equation" from "every equation is
    # independent", so it reports 0 even while a real, still-unconfirmed
    # degree of freedom (the shared radius) remains. Confirmed directly
    # against this exact Slot construction (a fresh 2-Arc/2-Line/
    # Tangent+EqualRadius sketch, radius left provisional): `system.Dof`
    # reads 0 immediately after creation and stays 0 after adding a
    # Horizontal constraint on the centerline, even though the geometry
    # itself solves correctly (unlike the AtMidpoint false-positive the
    # comment above already documents, this one leaves the actual Point
    # positions untouched - only the reported count is wrong). A `dof` of 0
    # is only trustworthy once every DistanceConstraint that measures this
    # redundant sub-system has actually been confirmed - `provisional`
    # existing at all on such a Constraint means the opposite by
    # definition, so bump the floor to 1 rather than trust py-slvs's count.
    if converged and any(
        isinstance(c, DistanceConstraint) and c.provisional for c in sketch.constraints.values()
    ):
        dof = max(system.Dof, 1)
    else:
        dof = system.Dof

    solver_reported_failed_constraint_ids = [
        constraint_id_by_handle[handle]
        for handle in system.Failed
        if handle in constraint_id_by_handle
    ]

    blamed_constraint_ids: list[str] = []
    if not converged:
        newest_constraint = list(sketch.constraints.values())[-1]
        blamed_constraint_ids = [newest_constraint.id]

    if not sketch.constraints:
        detail = "No constraints to solve."
    elif converged:
        detail = "Solve converged."
    else:
        detail = (
            "Solve did not fully converge. blamed_constraint_ids names the "
            "most-recently-added constraint by convention only - it is not "
            "a diagnosed root cause. py-slvs's own failed-constraint report "
            "(solver_reported_failed_constraint_ids) tends to list every "
            "constraint in an inconsistent system rather than a single "
            "culprit, which is why it isn't used for blame."
        )

    return SolveResult(
        converged=converged,
        dof=dof,
        result_code=result_code,
        blamed_constraint_ids=blamed_constraint_ids,
        solver_reported_failed_constraint_ids=solver_reported_failed_constraint_ids,
        detail=detail,
    )
