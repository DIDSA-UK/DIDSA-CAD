"""Fix 4B (test report item 4's own "dof" follow-up): dedicated,
hand-computed tests for `app.document.assembly_solver._independent_dof` -
the rank-based replacement for `system.Dof` (`py_slvs`'s own naive
params-minus-equations count, confirmed unpatchable - `py-slvs==1.0.6` is a
precompiled, pinned third-party wheel with no vendored source in this repo).

Deliberately pure-Python/pure-`numpy` - no OCCT geometry construction, no
`py_slvs` solve, no HTTP - every input here is a hand-built `_ResolvedGeometry`
already sitting at its own known, already-mate-satisfying configuration, so
the expected DOF can be reasoned about directly from the physical meaning of
each Mate type (mirrors `test_measure_axis_math.py`'s own identical
"dedicated hand-computed math test" precedent for `measure._axis_to_axis_
distance`). `dof` is *not* observable through a converged HTTP solve at all
(`OccurrenceResponse`/`MateSolvePreviewResponse` never echo it back - only
`mate_solve_did_not_converge`'s own 422 detail does), so a direct-import test
is the only way to verify it on a genuinely converged configuration.

Per the same sandbox caveat as every other OCCT/`py_slvs`-touching test in
this project (see `test_stage_d_fillet.py`'s own docstring): importing
`app.document.assembly_solver` at all pulls in `OCC.Core`/`py_slvs` at
module level, neither installed in this repo's own dev sandbox - these are
`ast.parse`-verified/manually reviewed only here, pending a real
pythonocc-core + py_slvs environment."""

from app.document.assembly_solver import _ResolvedGeometry, _independent_dof
from app.document.models import Mate, MateEntityRef, MateType, ResolvedPlane, RigidTransform

_IDENTITY = RigidTransform.identity()
_DRIVEN_REF = MateEntityRef(occurrence_id="occ-driven")
_FIXED_REF = MateEntityRef(occurrence_id="")


def _mate(mate_type: MateType, *, allow_rotation: bool = True) -> Mate:
    return Mate(id="m", type=mate_type, references=[_DRIVEN_REF, _FIXED_REF], allow_rotation=allow_rotation)


def test_no_applicable_mates_is_six_dof():
    assert _independent_dof([], _IDENTITY) == 6


def test_a_single_point_coincident_mate_removes_exactly_three_dof():
    # A point pinned to a point removes all 3 translational DOF, leaving
    # every rotational DOF free (a point has no orientation of its own).
    driven = _ResolvedGeometry(point=(0.0, 0.0, 0.0))
    fixed = _ResolvedGeometry(point=(0.0, 0.0, 0.0))
    resolved = [(_mate(MateType.COINCIDENT), _DRIVEN_REF, driven, fixed)]
    assert _independent_dof(resolved, _IDENTITY) == 3


def test_a_single_concentric_mate_with_rotation_allowed_removes_four_dof():
    # Axis-to-axis alignment: 2 DOF for direction-parallel + 2 DOF for the
    # driven axis's own origin lying on the fixed axis line - translation
    # along, and rotation about, the shared axis both stay free (this
    # module's own documented v1 CONCENTRIC scope), leaving 2 DOF.
    driven = _ResolvedGeometry(axis_origin=(0.0, 0.0, 0.0), direction=(0.0, 0.0, 1.0))
    fixed = _ResolvedGeometry(axis_origin=(0.0, 0.0, 0.0), direction=(0.0, 0.0, 1.0))
    resolved = [(_mate(MateType.CONCENTRIC, allow_rotation=True), _DRIVEN_REF, driven, fixed)]
    assert _independent_dof(resolved, _IDENTITY) == 2


def test_a_single_concentric_mate_with_rotation_locked_removes_five_dof():
    # Fix 4A/4B's own real bug-report repro (test report item 4): on top of
    # the plain CONCENTRIC axis lock above (2 DOF remaining - slide along
    # and spin about the shared axis), `allow_rotation=False` also locks
    # spin, leaving only the axial slide - 1 DOF.
    driven = _ResolvedGeometry(axis_origin=(0.0, 0.0, 0.0), direction=(0.0, 0.0, 1.0), perp=(1.0, 0.0, 0.0))
    fixed = _ResolvedGeometry(axis_origin=(0.0, 0.0, 0.0), direction=(0.0, 0.0, 1.0), perp=(1.0, 0.0, 0.0))
    resolved = [(_mate(MateType.CONCENTRIC, allow_rotation=False), _DRIVEN_REF, driven, fixed)]
    assert _independent_dof(resolved, _IDENTITY) == 1


def test_bolt_in_hole_repro_concentric_locked_plus_coincident_is_fully_constrained():
    """The exact bug-report repro (test report item 4/assembly testing): a
    CONCENTRIC mate with `allow_rotation=False` (bolt shaft to hole bore),
    plus a COINCIDENT mate (bolt underside plane to plate top plane) whose
    own plane normal is, by construction, parallel to the shared CONCENTRIC
    axis - exactly the geometric redundancy `_mate_residual_satisfied`'s
    own docstring already documents for this scenario. Physically this
    fully constrains the bolt (0 DOF: nothing left to solve for), even
    though the two Mates' own residuals overlap - the whole point of a
    rank-based count over `system.Dof`'s naive per-equation tally."""
    axis_geometry_driven = _ResolvedGeometry(axis_origin=(0.0, 0.0, 0.0), direction=(0.0, 0.0, 1.0), perp=(1.0, 0.0, 0.0))
    axis_geometry_fixed = _ResolvedGeometry(axis_origin=(0.0, 0.0, 0.0), direction=(0.0, 0.0, 1.0), perp=(1.0, 0.0, 0.0))
    plane_geometry_driven = _ResolvedGeometry(
        point=(0.0, 0.0, 0.0),
        plane=ResolvedPlane(origin=(0.0, 0.0, 0.0), normal=(0.0, 0.0, -1.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 1.0, 0.0)),
    )
    plane_geometry_fixed = _ResolvedGeometry(
        point=(0.0, 0.0, 0.0),
        plane=ResolvedPlane(origin=(0.0, 0.0, 0.0), normal=(0.0, 0.0, 1.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 1.0, 0.0)),
    )
    resolved = [
        (_mate(MateType.CONCENTRIC, allow_rotation=False), _DRIVEN_REF, axis_geometry_driven, axis_geometry_fixed),
        (_mate(MateType.COINCIDENT), _DRIVEN_REF, plane_geometry_driven, plane_geometry_fixed),
    ]
    assert _independent_dof(resolved, _IDENTITY) == 0
