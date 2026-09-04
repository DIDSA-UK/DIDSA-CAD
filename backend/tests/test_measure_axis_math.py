"""Measure tool: dedicated hand-computed tests for `app.document.measure.
_axis_to_axis_distance` - the one piece of genuinely new, hand-derived math
in the Measure feature (every other computation in `measure.py` repackages
an already-proven OCCT call elsewhere in this codebase). Per the same
sandbox caveat as every other OCCT-touching test in this project (see
`test_stage_d_fillet.py`'s own docstring), these are `ast.parse`-verified/
manually reviewed only here, pending a real pythonocc-core environment.
"""

import pytest
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeFace
from OCC.Core.gp import gp_Ax1, gp_Dir, gp_Pln, gp_Pnt, gp_Vec

from app.document.measure import _axis_to_axis_distance, _point_to_plane_distance


def _axis(origin: tuple[float, float, float], direction: tuple[float, float, float]) -> gp_Ax1:
    return gp_Ax1(gp_Pnt(*origin), gp_Dir(*direction))


def test_parallel_axes_offset_by_a_known_perpendicular_distance():
    # Two lines parallel to Z: one through the origin, one through (3, 4, 0)
    # - offset entirely perpendicular to the shared direction, so the
    # expected distance is exactly the 3-4-5 triangle's hypotenuse.
    a = _axis((0, 0, 0), (0, 0, 1))
    b = _axis((3, 4, 0), (0, 0, 1))
    distance, parallel = _axis_to_axis_distance(a, b)
    assert parallel is True
    assert distance == pytest.approx(5.0)


def test_perpendicular_skew_axes_use_the_common_perpendicular_formula():
    # Classic skew-line example: the X-axis, and a line parallel to Y
    # offset by 5 units along Z - they never meet (skew), and the common
    # perpendicular (along Z) has length exactly 5.
    a = _axis((0, 0, 0), (1, 0, 0))
    b = _axis((0, 0, 5), (0, 1, 0))
    distance, parallel = _axis_to_axis_distance(a, b)
    assert parallel is False
    assert distance == pytest.approx(5.0)


def test_intersecting_non_parallel_axes_report_zero_distance():
    # The X-axis and a line parallel to Y through (5, 0, 0) intersect at
    # (5, 0, 0) - non-parallel, but the offset (5, 0, 0) is coplanar with
    # both directions, so the scalar triple product - and therefore the
    # reported distance - must vanish.
    a = _axis((0, 0, 0), (1, 0, 0))
    b = _axis((5, 0, 0), (0, 1, 0))
    distance, parallel = _axis_to_axis_distance(a, b)
    assert parallel is False
    assert distance == pytest.approx(0.0, abs=1e-9)


def test_coincident_axes_report_zero_distance_and_are_parallel():
    a = _axis((0, 0, 0), (0, 0, 1))
    b = _axis((0, 0, 0), (0, 0, 1))
    distance, parallel = _axis_to_axis_distance(a, b)
    assert parallel is True
    assert distance == pytest.approx(0.0, abs=1e-9)


def test_point_to_plane_distance_is_independent_of_footprint_overlap():
    """Two parallel planes 7 units apart along the shared normal - the
    plane-to-plane distance must be exactly 7 regardless of where each
    plane's own representative point sits laterally, unlike a generic
    closest-point distance (which would include lateral offset via
    Pythagoras whenever the two faces' footprints don't overlap)."""
    plane_a = BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), -5, 5, -5, 5, 1e-6).Face()
    # Offset both along Z (7 units) and laterally along X (20 units, well
    # outside plane_a's own -5..5 bounds) - a generic min-distance would see
    # sqrt(7**2 + 20**2), not 7.
    plane_b = BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(20, 0, 7), gp_Dir(0, 0, 1)), -5, 5, -5, 5, 1e-6).Face()
    normal_a = gp_Vec(0, 0, 1)
    distance = _point_to_plane_distance(plane_a, plane_b, normal_a)
    assert distance == pytest.approx(7.0)
