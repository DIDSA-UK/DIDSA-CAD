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

from app.sketch.models import Point, Sketch

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
    ):
        self._system = system
        self._workplane = workplane
        self._points = points
        self._point_handles: dict[str, int] = {}
        self._line_handles: dict[tuple[int, int], int] = {}
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

    def point2d(self, point_id: str) -> int:
        if point_id not in self._point_handles:
            point = self._points[point_id]
            group = _FIXED_GROUP if point_id == self._origin_point_id else _SOLVE_GROUP
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


def solve_sketch(sketch: Sketch) -> SolveResult:
    """Build the py-slvs problem for `sketch`'s Points + Constraints, solve
    it, and write the resulting positions back onto `sketch.points` (best
    effort even when it doesn't fully converge). Does not mutate
    `sketch.constraints`.

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

    builder = _PySlvsBuilder(system, workplane, sketch.points, origin_point_id=sketch.origin_point_id)

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
