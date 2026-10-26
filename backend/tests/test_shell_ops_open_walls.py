"""`shell_ops.thicken_shell_to_solid` on open walls of several faces: the path
`_thicken_by_offset_and_walls` (mitred offset plus ruled walls) that replaced `MakeThickSolidBySimple`
for shells the join and cap-the-boundary paths decline. Volumes are analytic."""

import math

import pytest
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakePolygon, BRepBuilderAPI_MakeWire
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_SOLID
from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Dir, gp_Pnt, gp_Vec

from app.document.shell_ops import thicken_shell_to_solid


def _volume(shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props, 1e-7)
    return props.Mass()


def _polyline_wall(points: list[tuple[float, float]], height: float):
    polygon = BRepBuilderAPI_MakePolygon()
    for x, y in points:
        polygon.Add(gp_Pnt(x, y, 0.0))
    return BRepPrimAPI_MakePrism(polygon.Wire(), gp_Vec(0, 0, height)).Shape()


def _both_sides(shell, thickness: float):
    solids = [thicken_shell_to_solid(shell, sign * thickness) for sign in (1.0, -1.0)]
    for solid in solids:
        assert solid.ShapeType() == TopAbs_SOLID
        assert BRepCheck_Analyzer(solid).IsValid()
    return sorted(_volume(solid) for solid in solids)


def test_a_single_flat_wall_is_a_box_on_either_side():
    wall = _polyline_wall([(0, 0), (10, 0)], 8.0)
    assert _both_sides(wall, 2.0) == pytest.approx([160.0, 160.0], rel=1e-9)


def test_an_l_shaped_wall_has_a_mitred_corner_outside_and_an_overlap_inside():
    wall = _polyline_wall([(0, 0), (10, 0), (10, 6)], 8.0)
    assert _both_sides(wall, 1.0) == pytest.approx([120.0, 136.0], rel=1e-9)


def test_a_wall_with_two_bends_the_same_way_round():
    # A U: legs 6 / 10 / 6 mm. Outside of the two bends: 22 + 2 corner squares; inside: 22 - 2.
    wall = _polyline_wall([(0, 6), (0, 0), (10, 0), (10, 6)], 5.0)
    assert _both_sides(wall, 1.0) == pytest.approx([(22 - 2) * 5.0, (22 + 2) * 5.0], rel=1e-9)


def test_two_45_degree_bends_the_same_way_add_and_remove_a_mitre_triangle_each():
    # (0,0) -> (10,0) -> (15,5) -> (15,15): both bends turn left by 45 degrees. A mitre adds (outside)
    # or removes (inside) t^2 tan(22.5 deg) of section at each bend.
    wall = _polyline_wall([(0, 0), (10, 0), (15, 5), (15, 15)], 4.0)
    length = 10 + 5 * math.sqrt(2) + 10
    mitres = 2 * math.tan(math.radians(22.5))
    inside, outside = _both_sides(wall, 1.0)
    assert inside == pytest.approx((length - mitres) * 4.0, rel=1e-6)
    assert outside == pytest.approx((length + mitres) * 4.0, rel=1e-6)


def test_a_curved_wall_matches_the_cylinder_formula():
    arc = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), 10.0), 0.0, math.pi / 2).Edge()
    wall = BRepPrimAPI_MakePrism(BRepBuilderAPI_MakeWire(arc).Wire(), gp_Vec(0, 0, 5.0)).Shape()
    inside, outside = _both_sides(wall, 1.0)
    assert outside == pytest.approx(math.pi / 4 * (11.0**2 - 10.0**2) * 5.0, rel=1e-4)
    assert inside == pytest.approx(math.pi / 4 * (10.0**2 - 9.0**2) * 5.0, rel=1e-4)
