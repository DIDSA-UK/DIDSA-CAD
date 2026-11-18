"""Bug report 2026-11-18 plan part C1: `app.sketch.projection.project_edge_onto_sketch` on real OCCT edges, one test (or more) per row of the plan's
classification list: a line, a line along the normal, a circle on a parallel plane, at an angle and edge-on, an ellipse (also one that projects round, and
edge-on), cubic and quadratic B-splines / Beziers (exact poles), a helix segment (sampled, within 1e-3 mm), a closed free-form curve (two halves), and a
reversed view (an arc's ends swap). Needs a real pythonocc-core environment."""

import math

import pytest
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeEdge
from OCC.Core.Geom import Geom_BezierCurve, Geom_BSplineCurve, Geom_CylindricalSurface
from OCC.Core.Geom2d import Geom2d_Line
from OCC.Core.gp import gp_Ax2, gp_Ax3, gp_Circ, gp_Dir, gp_Dir2d, gp_Elips, gp_Pnt, gp_Pnt2d
from OCC.Core.TColgp import TColgp_Array1OfPnt
from OCC.Core.TColStd import TColStd_Array1OfInteger, TColStd_Array1OfReal

from app.document.models import ResolvedPlane
from app.sketch.projection import SPLINE_TOLERANCE, ProjectedEntity, project_edge_onto_sketch

XY = ResolvedPlane(origin=(0.0, 0.0, 0.0), normal=(0.0, 0.0, 1.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 1.0, 0.0))
# The same plane seen from below: same x, y flipped (normal = x cross y, so a right-handed frame looking up).
XY_FROM_BELOW = ResolvedPlane(origin=(0.0, 0.0, 0.0), normal=(0.0, 0.0, -1.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, -1.0, 0.0))
COS30 = math.cos(math.radians(30.0))
SIN30 = math.sin(math.radians(30.0))


def _one(edge, basis=XY) -> ProjectedEntity:
    projected = project_edge_onto_sketch(edge, basis)
    assert len(projected) == 1, projected
    return projected[0]


def _bezier_at(p0, p1, p2, p3, f):
    g = 1 - f
    return tuple(g**3 * a + 3 * g * g * f * b + 3 * g * f * f * c + f**3 * d for a, b, c, d in zip(p0, p1, p2, p3))


def _spline_polyline(entity: ProjectedEntity, per_segment: int = 60) -> list[tuple[float, float]]:
    out = []
    for i in range(len(entity.through) - 1):
        p0, p1, p2, p3 = entity.through[i], entity.controls[2 * i], entity.controls[2 * i + 1], entity.through[i + 1]
        out += [_bezier_at(p0, p1, p2, p3, k / per_segment) for k in range(per_segment + (1 if i == len(entity.through) - 2 else 0))]
    return out


def _distance_to_polyline(p, polyline) -> float:
    best = math.inf
    for a, b in zip(polyline, polyline[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length2 = dx * dx + dy * dy
        t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length2))
        best = min(best, math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy))
    return best


def _on_ellipse(entity: ProjectedEntity, p) -> float:
    """Residual of `p` against the ellipse equation of `entity` (0 when on it)."""
    c, r = entity.centre, entity.rotation
    dx, dy = p[0] - c[0], p[1] - c[1]
    u = dx * math.cos(r) + dy * math.sin(r)
    v = -dx * math.sin(r) + dy * math.cos(r)
    return (u / entity.major_radius) ** 2 + (v / entity.minor_radius) ** 2 - 1.0


# --- lines -----------------------------------------------------------------------------------------------------------------


def test_a_line_projects_to_a_line_between_its_projected_ends():
    edge = BRepBuilderAPI_MakeEdge(gp_Pnt(1, 2, 3), gp_Pnt(4, 6, 9)).Edge()
    line = _one(edge)
    assert line.kind == "line"
    assert line.start == pytest.approx((1, 2)) and line.end == pytest.approx((4, 6))


def test_a_line_along_the_normal_projects_to_one_point():
    edge = BRepBuilderAPI_MakeEdge(gp_Pnt(3, -2, 0), gp_Pnt(3, -2, 25)).Edge()
    point = _one(edge)
    assert point.kind == "point" and point.start == pytest.approx((3, -2))


def test_a_reversed_line_edge_keeps_the_edges_own_direction():
    edge = BRepBuilderAPI_MakeEdge(gp_Pnt(0, 0, 0), gp_Pnt(5, 0, 1)).Edge().Reversed()
    line = _one(edge)
    assert line.start == pytest.approx((5, 0)) and line.end == pytest.approx((0, 0))


# --- circles ---------------------------------------------------------------------------------------------------------------


def test_a_circle_on_a_parallel_plane_projects_to_the_same_circle():
    edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(2, 3, 40), gp_Dir(0, 0, 1)), 7.5)).Edge()
    circle = _one(edge)
    assert circle.kind == "circle" and circle.centre == pytest.approx((2, 3)) and circle.radius == pytest.approx(7.5)


def test_a_circular_arc_on_a_parallel_plane_projects_to_a_counter_clockwise_arc():
    # A quarter arc from angle 0 to 90 degrees, 10 mm above the plane.
    edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(0, 0, 10), gp_Dir(0, 0, 1)), 5.0), 0.0, math.pi / 2).Edge()
    arc = _one(edge)
    assert arc.kind == "arc" and arc.radius == pytest.approx(5.0) and arc.centre == pytest.approx((0, 0))
    assert arc.start == pytest.approx((5, 0)) and arc.end == pytest.approx((0, 5)) and not arc.reversed


def test_a_circle_tilted_30_degrees_projects_to_an_ellipse_with_minor_radius_r_cos_30():
    r = 10.0
    axis = gp_Dir(0, SIN30, COS30)  # the circle's plane is tilted 30 degrees about x
    edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(1, 2, 5), axis), r)).Edge()
    ellipse = _one(edge)
    assert ellipse.kind == "ellipse"
    assert ellipse.major_radius == pytest.approx(r) and ellipse.minor_radius == pytest.approx(r * COS30)
    assert ellipse.centre == pytest.approx((1, 2))
    # The major axis is along x (the tilt axis): rotation 0 or pi.
    assert math.sin(ellipse.rotation) == pytest.approx(0.0, abs=1e-12)


def test_an_arc_of_a_tilted_circle_projects_to_an_elliptical_arc_whose_ends_lie_on_it():
    axis = gp_Dir(0, SIN30, COS30)
    circ = gp_Circ(gp_Ax2(gp_Pnt(0, 0, 0), axis, gp_Dir(1, 0, 0)), 10.0)
    edge = BRepBuilderAPI_MakeEdge(circ, 0.0, 2.0).Edge()
    arc = _one(edge)
    assert arc.kind == "ellipse_arc"
    assert arc.minor_radius == pytest.approx(10.0 * COS30)
    for end in (arc.start, arc.end):
        assert _on_ellipse(arc, end) == pytest.approx(0.0, abs=1e-12)
    # The ends are the edge's own ends, projected (the arc runs counter-clockwise from start to end in the sketch).
    assert {tuple(round(c, 9) for c in p) for p in (arc.start, arc.end)} == {(10.0, 0.0), (round(10 * math.cos(2.0), 9), round(10 * math.sin(2.0) * COS30, 9))}
    sweep = (arc.end_angle - arc.start_angle) % (2 * math.pi)
    assert sweep == pytest.approx(2.0, abs=1e-9)


def test_a_circle_seen_edge_on_projects_to_a_line_between_its_extreme_points():
    edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(1, 2, 5), gp_Dir(1, 0, 0)), 10.0)).Edge()
    line = _one(edge)
    assert line.kind == "line"
    assert sorted([line.start, line.end]) == [pytest.approx((1, -8)), pytest.approx((1, 12))]


def test_a_three_quarter_arc_seen_edge_on_reaches_its_extreme_points_not_just_its_ends():
    # Axis +x, x reference +y: the arc from 0 to 1.5 pi passes y = +r (t = 0) and y = -r (t = pi) and ends at t = 1.5 pi (y = 0).
    circ = gp_Circ(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0), gp_Dir(0, 1, 0)), 4.0)
    line = _one(BRepBuilderAPI_MakeEdge(circ, 0.0, 1.5 * math.pi).Edge())
    assert line.kind == "line"
    assert sorted(p[1] for p in (line.start, line.end)) == pytest.approx([-4.0, 4.0])


# --- ellipses --------------------------------------------------------------------------------------------------------------


def test_an_ellipse_on_a_parallel_plane_projects_to_the_same_ellipse():
    elips = gp_Elips(gp_Ax2(gp_Pnt(3, 0, -7), gp_Dir(0, 0, 1), gp_Dir(0, 1, 0)), 12.0, 5.0)  # major along y
    ellipse = _one(BRepBuilderAPI_MakeEdge(elips).Edge())
    assert ellipse.kind == "ellipse" and ellipse.major_radius == pytest.approx(12.0) and ellipse.minor_radius == pytest.approx(5.0)
    assert math.cos(ellipse.rotation) == pytest.approx(0.0, abs=1e-12)


def test_an_elliptical_arc_projects_to_an_elliptical_arc():
    elips = gp_Elips(gp_Ax2(gp_Pnt(0, 0, 3), gp_Dir(0, 0, 1)), 12.0, 5.0)
    arc = _one(BRepBuilderAPI_MakeEdge(elips, 0.5, 2.5).Edge())
    assert arc.kind == "ellipse_arc" and arc.start_angle == pytest.approx(0.5) and arc.end_angle == pytest.approx(2.5)


def test_an_ellipse_that_projects_round_becomes_a_circle():
    # Major 10 along x, minor 5; tilting its plane 60 degrees about y shortens x by cos 60 = 0.5: 10 * 0.5 = 5 = the minor radius.
    tilt = math.radians(60.0)
    axis = gp_Dir(math.sin(tilt), 0, math.cos(tilt))
    x_dir = gp_Dir(math.cos(tilt), 0, -math.sin(tilt))
    elips = gp_Elips(gp_Ax2(gp_Pnt(0, 0, 0), axis, x_dir), 10.0, 5.0)
    circle = _one(BRepBuilderAPI_MakeEdge(elips).Edge())
    assert circle.kind == "circle" and circle.radius == pytest.approx(5.0)


def test_an_ellipse_seen_edge_on_projects_to_a_line():
    elips = gp_Elips(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 1, 0), gp_Dir(1, 0, 0)), 9.0, 4.0)  # in the XZ plane, major along x
    line = _one(BRepBuilderAPI_MakeEdge(elips).Edge())
    assert line.kind == "line" and sorted(p[0] for p in (line.start, line.end)) == pytest.approx([-9.0, 9.0])


# --- B-splines and Beziers (exact poles) -----------------------------------------------------------------------------------


def _cubic_bspline(poles):
    array = TColgp_Array1OfPnt(1, len(poles))
    for i, p in enumerate(poles, start=1):
        array.SetValue(i, gp_Pnt(*p))
    segments = (len(poles) - 1) // 3
    knots = TColStd_Array1OfReal(1, segments + 1)
    mults = TColStd_Array1OfInteger(1, segments + 1)
    for i in range(segments + 1):
        knots.SetValue(i + 1, float(i))
        mults.SetValue(i + 1, 4 if i in (0, segments) else 3)
    return Geom_BSplineCurve(array, knots, mults, 3)


def test_a_cubic_bspline_projects_to_a_spline_whose_points_are_the_projected_poles():
    poles = [(0, 0, 0), (1, 2, 3), (3, 2, -1), (4, 0, 2), (5, -2, 5), (7, -1, 0), (8, 0, 1)]
    curve = _cubic_bspline(poles)
    spline = _one(BRepBuilderAPI_MakeEdge(curve).Edge())
    assert spline.kind == "spline" and spline.exact
    assert list(spline.through) == [pytest.approx((x, y)) for x, y, _ in (poles[0], poles[3], poles[6])]
    assert list(spline.controls) == [pytest.approx((x, y)) for x, y, _ in (poles[1], poles[2], poles[4], poles[5])]
    # And the projected spline is the projected curve.
    for k in range(21):
        u = 2.0 * k / 20
        p = curve.Value(u)
        assert _distance_to_polyline((p.X(), p.Y()), _spline_polyline(spline, 200)) < 1e-6


def test_a_quadratic_bezier_is_raised_to_a_cubic_spline_that_is_the_same_curve():
    array = TColgp_Array1OfPnt(1, 3)
    for i, p in enumerate([(0, 0, 0), (2, 4, 7), (4, 0, 1)], start=1):
        array.SetValue(i, gp_Pnt(*p))
    curve = Geom_BezierCurve(array)
    spline = _one(BRepBuilderAPI_MakeEdge(curve).Edge())
    assert spline.kind == "spline" and spline.exact and len(spline.through) == 2 and len(spline.controls) == 2
    for k in range(11):
        p = curve.Value(k / 10)
        assert _distance_to_polyline((p.X(), p.Y()), _spline_polyline(spline, 200)) < 1e-6


def test_a_planar_spline_seen_edge_on_projects_to_a_line():
    poles = [(0, 0, 0), (1, 0, 3), (3, 0, -2), (4, 0, 1)]  # all in the XZ plane
    line = _one(BRepBuilderAPI_MakeEdge(_cubic_bspline(poles)).Edge())
    assert line.kind == "line"
    assert sorted(p[0] for p in (line.start, line.end)) == pytest.approx([0.0, 4.0])


def test_a_closed_freeform_curve_becomes_two_splines_sharing_their_ends():
    poles = [(0, 0, 0), (4, -3, 1), (8, 3, 2), (8, 6, 1), (8, 9, 0), (0, 9, 2), (0, 0, 0)]
    projected = project_edge_onto_sketch(BRepBuilderAPI_MakeEdge(_cubic_bspline(poles)).Edge(), XY)
    assert [p.kind for p in projected] == ["spline", "spline"]
    first, second = projected
    assert first.end == pytest.approx(second.start) and second.end == pytest.approx(first.start)


# --- a helix (sampled) -----------------------------------------------------------------------------------------------------


def _helix_edge(radius: float, pitch: float, turns: float):
    """A helix about z as a 2D line on a cylinder (no 3D curve of its own, as a swept helix edge can be): the sampler's case."""
    surface = Geom_CylindricalSurface(gp_Ax3(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), radius)
    line = Geom2d_Line(gp_Pnt2d(0, 0), gp_Dir2d(2 * math.pi, pitch))
    length = turns * math.hypot(2 * math.pi, pitch)
    return BRepBuilderAPI_MakeEdge(line, surface, 0.0, length).Edge(), length


@pytest.mark.parametrize(
    "basis",
    [
        pytest.param(ResolvedPlane(origin=(0, 0, 0), normal=(0, -1, 0), x_axis=(1, 0, 0), y_axis=(0, 0, 1)), id="side-on"),
        pytest.param(ResolvedPlane(origin=(0, 0, 0), normal=(0, -SIN30, COS30), x_axis=(1, 0, 0), y_axis=(0, COS30, SIN30)), id="tilted-30"),
    ],
)
def test_a_helix_segment_projects_to_a_spline_within_tolerance(basis):
    radius, pitch, turns = 5.0, 3.0, 1.25
    edge, _ = _helix_edge(radius, pitch, turns)
    projected = project_edge_onto_sketch(edge, basis)
    assert len(projected) == 1 and projected[0].kind == "spline" and not projected[0].exact
    polyline = _spline_polyline(projected[0], 80)
    worst = 0.0
    for k in range(801):
        angle = 2 * math.pi * turns * k / 800
        p = (radius * math.cos(angle), radius * math.sin(angle), pitch * angle / (2 * math.pi))
        q = tuple(sum(a * b for a, b in zip(p, axis)) for axis in (basis.x_axis, basis.y_axis))
        worst = max(worst, _distance_to_polyline(q, polyline))
    assert worst < SPLINE_TOLERANCE, worst


def test_a_sampled_spline_can_be_asked_for_a_fixed_number_of_segments():
    edge, _ = _helix_edge(5.0, 3.0, 1.0)
    side = ResolvedPlane(origin=(0, 0, 0), normal=(0, -1, 0), x_axis=(1, 0, 0), y_axis=(0, 0, 1))
    projected = project_edge_onto_sketch(edge, side, sampled_segments=7)
    assert len(projected[0].through) == 8 and len(projected[0].controls) == 14


# --- a reversed view ---------------------------------------------------------------------------------------------------------


def test_a_reversed_view_swaps_an_arcs_ends():
    edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), 5.0), 0.0, math.pi / 2).Edge()
    from_above = _one(edge, XY)
    from_below = _one(edge, XY_FROM_BELOW)
    assert from_above.start == pytest.approx((5, 0)) and from_above.end == pytest.approx((0, 5)) and not from_above.reversed
    # Seen from below, the edge runs clockwise in that sketch's coordinates, so its ends swap to keep the arc counter-clockwise.
    assert from_below.start == pytest.approx((0, -5)) and from_below.end == pytest.approx((5, 0)) and from_below.reversed


def test_a_reversed_view_swaps_an_elliptical_arcs_ends():
    circ = gp_Circ(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, SIN30, COS30), gp_Dir(1, 0, 0)), 10.0)
    edge = BRepBuilderAPI_MakeEdge(circ, 0.0, 1.0).Edge()
    from_above, from_below = _one(edge, XY), _one(edge, XY_FROM_BELOW)
    assert from_above.reversed != from_below.reversed
    assert from_above.start[0] == pytest.approx(from_below.end[0]) and from_above.start[1] == pytest.approx(-from_below.end[1])
