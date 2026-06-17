"""Stage 2a de-risking spike: confirm py-slvs (SolveSpace constraint solver
bindings) installs and runs correctly in this environment, on both amd64 and
arm64. Does not touch the Sketch/Point/Line/Profile model - this is purely
about proving the third-party library works before designing anything
around it.
"""

import math

import pytest
from py_slvs import slvs

FIXED_GROUP = 1
GROUP = 2


def _make_workplane(system: slvs.System) -> int:
    origin = system.addPoint3d(0, 0, 0, group=FIXED_GROUP)
    normal = system.addNormal3dV(1, 0, 0, 0, group=FIXED_GROUP)
    return system.addWorkplane(origin, normal, group=FIXED_GROUP)


def _make_point2d(system: slvs.System, workplane: int, u: float, v: float) -> int:
    pu = system.addParamV(u, group=GROUP)
    pv = system.addParamV(v, group=GROUP)
    return system.addPoint2d(workplane, pu, pv, group=GROUP)


def _point_xy(system: slvs.System, point_handle: int) -> tuple[float, float]:
    u_param = system.getEntityParam(point_handle, 0)
    v_param = system.getEntityParam(point_handle, 1)
    return system.getParam(u_param).val, system.getParam(v_param).val


def test_distance_constraint_is_satisfied_after_solving():
    system = slvs.System()
    workplane = _make_workplane(system)

    point_a = _make_point2d(system, workplane, 0.0, 0.0)
    point_b = _make_point2d(system, workplane, 10.0, 0.0)
    system.addPointsDistance(50.0, point_a, point_b, wrkpln=workplane, group=GROUP)

    result = system.solve(group=GROUP, reportFailed=True)

    assert result == 0
    assert system.Failed == ()

    ax, ay = _point_xy(system, point_a)
    bx, by = _point_xy(system, point_b)
    assert math.hypot(bx - ax, by - ay) == pytest.approx(50.0)


@pytest.mark.parametrize("initial_guess", [(10.0, 0.0), (3.0, 4.0), (100.0, 100.0)])
def test_solver_converges_from_different_initial_guesses(initial_guess: tuple[float, float]):
    system = slvs.System()
    workplane = _make_workplane(system)

    point_a = _make_point2d(system, workplane, 0.0, 0.0)
    point_b = _make_point2d(system, workplane, *initial_guess)
    system.addPointsDistance(50.0, point_a, point_b, wrkpln=workplane, group=GROUP)

    result = system.solve(group=GROUP, reportFailed=True)

    assert result == 0
    assert system.Failed == ()

    ax, ay = _point_xy(system, point_a)
    bx, by = _point_xy(system, point_b)
    assert math.hypot(bx - ax, by - ay) == pytest.approx(50.0)
