"""Convert Entities, real projection (bug report 2026-11-18, plan part C1; docs/bug-report-2026-11-18-plan.md): one function, `project_edge_onto_sketch`,
that turns any 3D edge (a Body edge, or an edge built from another Sketch's entity) into the sketch entities it looks like when seen square to the sketch
plane, in that sketch's own 2D coordinates.

What an edge becomes (the plan's classification list):

* a line: a Line; a line along the plane's normal: a single Point;
* a circle on a parallel plane: a Circle (whole) or an Arc;
* a circle seen at an angle: an Ellipse or an EllipseArc; a circle seen edge-on: a Line between its extreme points;
* an ellipse: an Ellipse / EllipseArc, a Circle / Arc when the projection happens to be round, a Line when seen edge-on;
* a cubic (or lower degree) non-rational B-spline or Bezier: a Spline whose through and control points are the projected poles (exact: an orthographic
  projection is affine, and an affine map of a Bezier is the Bezier of the mapped poles);
* anything else (rational or higher-degree curves, offset curves, curves known only on a surface such as a helix): a Spline through sampled points with
  tangent handles from the curve's derivative (cubic Hermite), refined until it stays within `SPLINE_TOLERANCE` of the projected curve;
* any of these whose projection is flat (a planar curve seen edge-on) becomes a Line, and one that collapses to a dot a Point.

Arcs and elliptical arcs run counter-clockwise in the sketch's own 2D coordinates (the `Arc` / `EllipseArc` convention): when the projection runs the other
way (the edge seen from behind), start and end are swapped and `ProjectedEntity.reversed` says so.

Conics are projected with their own parametric form rather than through `GeomProjLib.ProjectOnPlane` (the plan's suggestion): a circle or ellipse is
`C + u cos t + v sin t`, and an orthographic projection maps it to the same form with projected `C`, `u`, `v`, whose axes are a 2x2 singular value
decomposition. That is exact, needs no OCCT call, and handles the edge-on case (the smaller singular value is zero) without a degenerate Geom curve.

Pure geometry: takes the edge and a `basis` (anything with `origin`, `normal`, `x_axis` and `y_axis` 3-tuples, i.e. a `ResolvedPlane`; this module does not
import the document layer) and returns plain values. Making the sketch entities is the caller's (`app.document.projected_curves`)."""

from __future__ import annotations

import math
from dataclasses import dataclass

from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.Geom import Geom_BezierCurve, Geom_BSplineCurve
from OCC.Core.GeomAbs import GeomAbs_BezierCurve, GeomAbs_BSplineCurve, GeomAbs_Circle, GeomAbs_Ellipse, GeomAbs_Line
from OCC.Core.GeomConvert import GeomConvert_BSplineCurveToBezierCurve
from OCC.Core.gp import gp_Pnt, gp_Vec
from OCC.Core.TopAbs import TopAbs_REVERSED
from OCC.Core.TopoDS import TopoDS_Edge

Vec2 = tuple[float, float]

# Largest distance (mm) a sampled Spline may stray from the projected curve (the plan's 1e-3 mm), and the most segments it may use to get there.
SPLINE_TOLERANCE = 1e-3
_MAX_SAMPLED_SEGMENTS = 1024
# Relative size below which a length counts as zero (a projection that collapses), and below which two radii count as equal (a round projection).
_REL_EPS = 1e-9

KINDS = ("point", "line", "circle", "arc", "ellipse", "ellipse_arc", "spline")


@dataclass(frozen=True)
class ProjectedEntity:
    """One sketch entity a projected edge becomes, in sketch coordinates (millimetres). Which fields mean something depends on `kind`:

    * `point`: `start`.
    * `line`: `start`, `end`.
    * `circle`: `centre`, `radius`.
    * `arc`: `centre`, `radius`, `start`, `end` (counter-clockwise from start to end).
    * `ellipse`: `centre`, `major_radius`, `minor_radius`, `rotation` (the major axis's angle from +x, radians).
    * `ellipse_arc`: as `ellipse`, plus `start`, `end` and their parametric angles `start_angle`, `end_angle` (radians in the ellipse's own frame,
      counter-clockwise from start to end; the `EllipseArc.local_angle` convention).
    * `spline`: `through` (N >= 2 points on the curve) and `controls` (2 per segment, `Spline.segments` order), so each segment is the cubic Bezier
      (through[i], controls[2i], controls[2i+1], through[i+1]). `start` / `end` are the first and last through points. `exact` is True when the poles
      were projected (the copy is the curve), False when it was sampled (within `SPLINE_TOLERANCE`).

    `reversed` (arc kinds and a spline): True when `start` is where the EDGE ends (the counter-clockwise rule swapped them), so a caller matching ends to
    the edge's vertices knows which is which."""

    kind: str
    start: Vec2 | None = None
    end: Vec2 | None = None
    centre: Vec2 | None = None
    radius: float = 0.0
    major_radius: float = 0.0
    minor_radius: float = 0.0
    rotation: float = 0.0
    start_angle: float = 0.0
    end_angle: float = 0.0
    through: tuple[Vec2, ...] = ()
    controls: tuple[Vec2, ...] = ()
    exact: bool = True
    reversed: bool = False


# --- basis maths -----------------------------------------------------------------------------------------------------------


def _dot3(a, b) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _point_2d(basis, p) -> Vec2:
    """A world point (a gp_Pnt or a 3-tuple) in sketch coordinates: its offset from the plane origin dotted with the in-plane axes, which is exactly the
    orthographic projection along the normal (the axes are orthonormal)."""
    xyz = (p.X(), p.Y(), p.Z()) if isinstance(p, gp_Pnt) else p
    d = (xyz[0] - basis.origin[0], xyz[1] - basis.origin[1], xyz[2] - basis.origin[2])
    return (_dot3(d, basis.x_axis), _dot3(d, basis.y_axis))


def _vector_2d(basis, v: tuple[float, float, float]) -> Vec2:
    """A world direction's in-plane part, in sketch coordinates."""
    return (_dot3(v, basis.x_axis), _dot3(v, basis.y_axis))


def _sub(a: Vec2, b: Vec2) -> Vec2:
    return (a[0] - b[0], a[1] - b[1])


def _add(a: Vec2, b: Vec2) -> Vec2:
    return (a[0] + b[0], a[1] + b[1])


def _scale(a: Vec2, s: float) -> Vec2:
    return (a[0] * s, a[1] * s)


def _dot(a: Vec2, b: Vec2) -> float:
    return a[0] * b[0] + a[1] * b[1]


def _dist(a: Vec2, b: Vec2) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def _ccw_sweep(start: float, end: float) -> float:
    """The counter-clockwise angle from `start` to `end`, in [0, 2pi)."""
    return (end - start) % (2.0 * math.pi)


def _bezier(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, f: float) -> Vec2:
    g = 1.0 - f
    a, b, c, d = g * g * g, 3 * g * g * f, 3 * g * f * f, f * f * f
    return (a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1])


# --- the entry point -------------------------------------------------------------------------------------------------------


def project_edge_onto_sketch(
    edge: TopoDS_Edge, basis, *, tolerance: float = SPLINE_TOLERANCE, sampled_segments: int | None = None
) -> list[ProjectedEntity]:
    """The sketch entities `edge` becomes, projected square onto `basis`'s plane (see the module docstring for the classification). Usually one; a CLOSED
    edge that becomes a Spline is two (a Spline is open, so a closed one is split in half, the halves sharing their ends).

    `sampled_segments` asks a sampled Spline for exactly that many segments (a refresh keeps the copy's point count, so the same Points can follow)."""
    adaptor = BRepAdaptor_Curve(edge)
    first, last = adaptor.FirstParameter(), adaptor.LastParameter()
    reverse = edge.Orientation() == TopAbs_REVERSED
    curve_type = adaptor.GetType()
    if curve_type == GeomAbs_Line:
        return [_project_segment(adaptor, first, last, basis, reverse)]
    if curve_type in (GeomAbs_Circle, GeomAbs_Ellipse):
        return [_project_conic(adaptor, curve_type, first, last, basis, reverse)]
    if curve_type in (GeomAbs_BSplineCurve, GeomAbs_BezierCurve) and sampled_segments is None:
        projected = _project_poles(adaptor, curve_type, first, last, basis, reverse)
        if projected is not None:
            return projected
    return _project_sampled(adaptor, first, last, basis, reverse, tolerance, sampled_segments)


# --- lines -----------------------------------------------------------------------------------------------------------------


def _ends(adaptor, first: float, last: float, reverse: bool) -> tuple[gp_Pnt, gp_Pnt]:
    a, b = adaptor.Value(first), adaptor.Value(last)
    return (b, a) if reverse else (a, b)


def _project_segment(adaptor, first, last, basis, reverse) -> ProjectedEntity:
    a, b = _ends(adaptor, first, last, reverse)
    start, end = _point_2d(basis, a), _point_2d(basis, b)
    if _dist(start, end) <= _REL_EPS * max(1.0, a.Distance(b)):
        return ProjectedEntity(kind="point", start=start)  # a line along the normal
    return ProjectedEntity(kind="line", start=start, end=end)


# --- circles and ellipses --------------------------------------------------------------------------------------------------


def _project_conic(adaptor, curve_type, first, last, basis, reverse) -> ProjectedEntity:
    if curve_type == GeomAbs_Circle:
        circ = adaptor.Circle()
        centre3, x_dir, y_dir, a3, b3 = circ.Location(), circ.XAxis().Direction(), circ.YAxis().Direction(), circ.Radius(), circ.Radius()
    else:
        elips = adaptor.Ellipse()
        centre3, x_dir, y_dir = elips.Location(), elips.XAxis().Direction(), elips.YAxis().Direction()
        a3, b3 = elips.MajorRadius(), elips.MinorRadius()
    centre = _point_2d(basis, centre3)
    u = _scale(_vector_2d(basis, (x_dir.X(), x_dir.Y(), x_dir.Z())), a3)
    v = _scale(_vector_2d(basis, (y_dir.X(), y_dir.Y(), y_dir.Z())), b3)
    full = abs((last - first) - 2.0 * math.pi) < 1e-9

    # P(t) - centre = u cos t + v sin t. The axes are the singular vectors of [u v]: eigenvectors of S = M M^T.
    s00, s01, s11 = u[0] * u[0] + v[0] * v[0], u[0] * u[1] + v[0] * v[1], u[1] * u[1] + v[1] * v[1]
    half_trace = 0.5 * (s00 + s11)
    root = math.hypot(0.5 * (s00 - s11), s01)
    major = math.sqrt(max(half_trace + root, 0.0))
    minor = math.sqrt(max(half_trace - root, 0.0))
    rotation = 0.5 * math.atan2(2.0 * s01, s00 - s11)
    e1 = (math.cos(rotation), math.sin(rotation))
    e2 = (-e1[1], e1[0])
    size = max(1.0, a3)

    def at(t: float) -> Vec2:
        return _add(centre, _add(_scale(u, math.cos(t)), _scale(v, math.sin(t))))

    if minor <= _REL_EPS * size:
        # Seen edge-on: the curve lies on the line through the centre along e1. Its extent over [first, last]: s(t) = (u.e1) cos t + (v.e1) sin t, whose
        # extremes are the ends of the range or where ds/dt = 0 (t* = atan2(v.e1, u.e1) + k pi).
        ue, ve = _dot(u, e1), _dot(v, e1)
        candidates = [first, last]
        t_star = math.atan2(ve, ue)
        for k in range(-4, 5):
            t = t_star + k * math.pi
            if first - 1e-12 <= t <= last + 1e-12:
                candidates.append(t)
        values = [ue * math.cos(t) + ve * math.sin(t) for t in candidates]
        lo, hi = min(values), max(values)
        if hi - lo <= _REL_EPS * size:
            return ProjectedEntity(kind="point", start=_add(centre, _scale(e1, lo)))
        return ProjectedEntity(kind="line", start=_add(centre, _scale(e1, lo)), end=_add(centre, _scale(e1, hi)))

    p_first, p_last = at(first), at(last)
    p_mid = at(0.5 * (first + last))
    start, end = (p_last, p_first) if reverse else (p_first, p_last)

    if major - minor <= _REL_EPS * size:
        radius = 0.5 * (major + minor)
        if full:
            return ProjectedEntity(kind="circle", centre=centre, radius=radius)
        angle = lambda p: math.atan2(p[1] - centre[1], p[0] - centre[0])  # noqa: E731
        swapped = not _mid_on_ccw_sweep(angle(start), angle(p_mid), angle(end))
        if swapped:
            start, end = end, start
        return ProjectedEntity(kind="arc", centre=centre, radius=radius, start=start, end=end, reversed=swapped)

    if full:
        return ProjectedEntity(kind="ellipse", centre=centre, major_radius=major, minor_radius=minor, rotation=rotation)

    def param(p: Vec2) -> float:
        d = _sub(p, centre)
        return math.atan2(_dot(d, e2) / minor, _dot(d, e1) / major)

    t_start, t_mid, t_end = param(start), param(p_mid), param(end)
    swapped = not _mid_on_ccw_sweep(t_start, t_mid, t_end)
    if swapped:
        start, end, t_start, t_end = end, start, t_end, t_start
    return ProjectedEntity(
        kind="ellipse_arc",
        centre=centre,
        major_radius=major,
        minor_radius=minor,
        rotation=rotation,
        start=start,
        end=end,
        start_angle=t_start,
        end_angle=t_end,
        reversed=swapped,
    )


def _mid_on_ccw_sweep(start: float, mid: float, end: float) -> bool:
    """Whether going counter-clockwise from `start` to `end` passes `mid` (all angles in radians)."""
    return _ccw_sweep(start, mid) <= _ccw_sweep(start, end)


# --- splines from poles (exact) --------------------------------------------------------------------------------------------


def _project_poles(adaptor, curve_type, first, last, basis, reverse) -> list[ProjectedEntity] | None:
    """A non-rational B-spline / Bezier of degree <= 3, cut to the edge's range and split into cubic Bezier pieces whose poles are projected: exact. None
    when the curve is rational or of a higher degree, or the projection has a piece that collapses (left to the sampler, which copes with both)."""
    if curve_type == GeomAbs_BezierCurve:
        bezier = Geom_BezierCurve.DownCast(adaptor.Bezier().Copy())
        if bezier.IsRational() or bezier.Degree() > 3:
            return None
        if first > 1e-12 or last < 1.0 - 1e-12:
            bezier.Segment(first, last)
        if bezier.Degree() < 3:
            bezier.Increase(3)
        pieces = [[bezier.Pole(i) for i in range(1, 5)]]
    else:
        bspline = Geom_BSplineCurve.DownCast(adaptor.BSpline().Copy())
        if bspline.IsRational() or bspline.Degree() > 3:
            return None
        if first > bspline.FirstParameter() + 1e-12 or last < bspline.LastParameter() - 1e-12:
            bspline.Segment(first, last)
        if bspline.Degree() < 3:
            bspline.IncreaseDegree(3)
        converter = GeomConvert_BSplineCurveToBezierCurve(bspline)
        pieces = []
        for i in range(1, converter.NbArcs() + 1):
            arc = converter.Arc(i)
            pieces.append([arc.Pole(j) for j in range(1, 5)])
    if reverse:
        pieces = [list(reversed(piece)) for piece in reversed(pieces)]
    projected = [[_point_2d(basis, p) for p in piece] for piece in pieces]
    through = [projected[0][0]] + [piece[3] for piece in projected]
    controls = [c for piece in projected for c in (piece[1], piece[2])]
    size = max(1.0, max(abs(c) for p in through + controls for c in p))
    flat = _flat_result(through + controls, through[0], through[-1], size)
    if flat is not None:
        return [flat]
    if any(_dist(a, b) <= _REL_EPS * size for a, b in zip(through, through[1:])):
        return None
    closed = _dist(through[0], through[-1]) <= _REL_EPS * size
    if closed and len(through) < 3:
        return None
    return _spline_entities(through, controls, closed, exact=True, reverse=reverse)


# --- splines from samples (within tolerance) -------------------------------------------------------------------------------


def _project_sampled(adaptor, first, last, basis, reverse, tolerance, sampled_segments) -> list[ProjectedEntity]:
    """A cubic Hermite spline through samples of the projected curve, the handles from its derivative (`P_i + T_i h / 3`, `P_{i+1} - T_{i+1} h / 3`), the
    segment count doubled until every segment stays within `tolerance / 2` of the curve at its quarter points (or `sampled_segments` exactly, if given)."""

    def sample(n: int):
        h = (last - first) / n
        points, tangents = [], []
        for i in range(n + 1):
            t = first + i * h
            p, d1 = gp_Pnt(), gp_Vec()
            adaptor.D1(t, p, d1)
            points.append(_point_2d(basis, p))
            tangents.append(_vector_2d(basis, (d1.X(), d1.Y(), d1.Z())))
        controls = []
        for i in range(n):
            controls.append(_add(points[i], _scale(tangents[i], h / 3.0)))
            controls.append(_sub(points[i + 1], _scale(tangents[i + 1], h / 3.0)))
        return h, points, controls

    def deviation(n: int, h: float, points, controls) -> float:
        worst = 0.0
        for i in range(n):
            for f in (0.25, 0.5, 0.75):
                on_curve = _point_2d(basis, adaptor.Value(first + (i + f) * h))
                worst = max(worst, _dist(on_curve, _bezier(points[i], controls[2 * i], controls[2 * i + 1], points[i + 1], f)))
        return worst

    closed3d = adaptor.Value(first).Distance(adaptor.Value(last)) <= 1e-7
    n = sampled_segments if sampled_segments is not None else 4
    while True:
        h, points, controls = sample(n)
        if sampled_segments is not None or n >= _MAX_SAMPLED_SEGMENTS or deviation(n, h, points, controls) <= 0.5 * tolerance:
            break
        n *= 2
    if reverse:
        points = list(reversed(points))
        segments = [(controls[2 * i], controls[2 * i + 1]) for i in range(n)]
        controls = [c for (c1, c2) in reversed(segments) for c in (c2, c1)]
    size = max(1.0, max(abs(c) for p in points for c in p))
    flat = _flat_result(points + controls, points[0], points[-1], size)
    if flat is not None:
        return [flat]
    # Neighbouring samples that coincide (a cusp seen end-on) would make a zero-length segment: drop the later one with its handles.
    through, kept_controls = [points[0]], []
    for i in range(n):
        if _dist(points[i + 1], through[-1]) <= _REL_EPS * size and i < n - 1:
            continue
        kept_controls.extend((controls[2 * i], controls[2 * i + 1]))
        through.append(points[i + 1])
    closed = closed3d or _dist(through[0], through[-1]) <= _REL_EPS * size
    return _spline_entities(through, kept_controls, closed and len(through) >= 3, exact=False, reverse=reverse)


# --- shared ----------------------------------------------------------------------------------------------------------------


def _flat_result(points: list[Vec2], start: Vec2, end: Vec2, size: float) -> ProjectedEntity | None:
    """A Point when every point is (all but) the same, a Line between the extremes when they all lie on one line (a planar curve seen edge-on), else None."""
    eps = _REL_EPS * size * 10.0
    far = max(points, key=lambda p: _dist(p, points[0]))
    if _dist(far, points[0]) <= eps:
        return ProjectedEntity(kind="point", start=points[0])
    direction = _sub(far, points[0])
    length = math.hypot(*direction)
    unit = (direction[0] / length, direction[1] / length)
    normal = (-unit[1], unit[0])
    if any(abs(_dot(_sub(p, points[0]), normal)) > eps for p in points):
        return None
    along = [_dot(_sub(p, points[0]), unit) for p in points]
    lo, hi = min(along), max(along)
    a, b = _add(points[0], _scale(unit, lo)), _add(points[0], _scale(unit, hi))
    # Keep the edge's own direction where it is monotonic, so a caller matching ends to vertices finds them.
    if _dist(a, end) < _dist(a, start):
        a, b = b, a
    return ProjectedEntity(kind="line", start=a, end=b)


def _spline_entities(through: list[Vec2], controls: list[Vec2], closed: bool, *, exact: bool, reverse: bool) -> list[ProjectedEntity]:
    """One Spline, or for a closed curve two halves split at the middle through point (they share both ends: the second ends where the first began)."""
    if not closed:
        return [ProjectedEntity(kind="spline", through=tuple(through), controls=tuple(controls), start=through[0], end=through[-1], exact=exact, reversed=reverse)]
    through = list(through[:-1]) + [through[0]]
    mid = len(through) // 2
    first_half = ProjectedEntity(
        kind="spline",
        through=tuple(through[: mid + 1]),
        controls=tuple(controls[: 2 * mid]),
        start=through[0],
        end=through[mid],
        exact=exact,
        reversed=reverse,
    )
    second_half = ProjectedEntity(
        kind="spline",
        through=tuple(through[mid:]),
        controls=tuple(controls[2 * mid :]),
        start=through[mid],
        end=through[-1],
        exact=exact,
        reversed=reverse,
    )
    return [first_half, second_half]
