"""Wires a Sketch's Points + Constraints (Stage 2) to py-slvs (Stage 2a).

Solving is explicit and batched: solve_sketch() is only ever called from
the POST .../solve endpoint, never as a side effect of editing a Point or
adding/removing a Constraint. A Point's x/y at the time solve_sketch() is
called is used as py-slvs's initial guess for that Point.

Over-constrained/unsatisfiable systems are solved anyway, never rejected.
See SolveResult for how non-convergence is reported.
"""

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

    def horizontal_distance(self, point_a_handle: int, point_b_handle: int, value: float) -> int:
        return self._system.addPointsProjectDistance(
            value, point_a_handle, point_b_handle, self._horizontal_ref_line_handle(), group=_SOLVE_GROUP
        )

    def vertical_distance(self, point_a_handle: int, point_b_handle: int, value: float) -> int:
        return self._system.addPointsProjectDistance(
            value, point_a_handle, point_b_handle, self._vertical_ref_line_handle(), group=_SOLVE_GROUP
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

    def angle(self, line_a_handle: int, line_b_handle: int, degrees: float) -> int:
        return self._system.addAngle(
            degrees, False, line_a_handle, line_b_handle, wrkpln=self._workplane, group=_SOLVE_GROUP
        )

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
    """

    result = _solve_sketch_once(sketch, anchor_point_ids)
    if anchor_point_ids and not result.converged:
        return _solve_sketch_once(sketch, frozenset())
    return result


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
    if (
        not converged
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
        # blanket override would have silently reintroduced.
        converged = True

    for point_id in builder.solved_point_ids():
        handle = builder.handle_for_point(point_id)
        u_param = system.getEntityParam(handle, 0)
        v_param = system.getEntityParam(handle, 1)
        point = sketch.points[point_id]
        point.x = system.getParam(u_param).val
        point.y = system.getParam(v_param).val

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
        dof=system.Dof,
        result_code=result_code,
        blamed_constraint_ids=blamed_constraint_ids,
        solver_reported_failed_constraint_ids=solver_reported_failed_constraint_ids,
        detail=detail,
    )
