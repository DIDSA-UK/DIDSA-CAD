"""Gordon-surface construction for Loft and Loft Surface (`docs/loft-gordon-and-helix-plan.md`,
`docs/loft-gordon-spike.md`).

`BRepOffsetAPI_ThruSections` skins the sections alone, so a guide curve could only ever move a
section rigidly. `GeomFill_Gordon` (OCCT 8) builds a surface through a *network*: the section
curves are its profiles, and the guide curves cross every profile. This module turns the section
wires a loft already has (resolved, rotated, re-seamed and edge-count harmonised by
`app.document.loft`) into such networks and returns the faces.

**One face per section edge**, as `ThruSections` gives. A section's vertices are the loft's
correspondence, so each vertex gets a *hidden guide* (a line for two sections, an interpolating
curve through the corresponding vertices for more). One Gordon patch is built per section edge,
between the hidden guides at its two ends, and the patches are sewn. A user guide that crosses
the sections inside an edge becomes an interior guide of that edge's patch (it shapes the face
without splitting it); one that crosses at a vertex replaces that vertex's hidden guide.

A section that is a single closed edge (a circle) is one periodic face: it gets hidden guides at
equal parameter fractions (three, or twelve when user guides are present, so a bump does not
spread around the whole circle).

Guides that miss a profile are *snapped*: Gordon's intersection step fails (status
`IntersectionFailed`) for any miss larger than its tolerance, its approximate mode does not
rescue that, and a tolerance big enough to accept the miss lets the surface leave the profile by
about the miss (it then no longer meets the end caps). The guide is therefore rebuilt through the
exact crossing points on the profiles, with the offset blended along it, and the deviation is
reported as a warning; beyond `_MAX_SNAP_FRACTION` of the loft's size it is an error.
"""

import logging
import math
from dataclasses import dataclass, field

from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakeSolid,
    BRepBuilderAPI_MakeWire,
    BRepBuilderAPI_Sewing,
)
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepTools import BRepTools_WireExplorer
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.GC import GC_MakeSegment
from OCC.Core.Geom import Geom_Plane, Geom_TrimmedCurve
from OCC.Core.GeomAPI import GeomAPI_ExtremaCurveCurve, GeomAPI_Interpolate, GeomAPI_ProjectPointOnCurve
from OCC.Core.GeomAbs import GeomAbs_C2
from OCC.Core.GeomConvert import GeomConvert_ApproxCurve, GeomConvert_CompCurveToBSplineCurve, geomconvert
from OCC.Core.GeomFill import GeomFill_Gordon
from OCC.Core.GeomLib import GeomLib_IsPlanarSurface
from OCC.Core.GProp import GProp_GProps
from OCC.Core.ShapeFix import ShapeFix_Solid
from OCC.Core.TColGeom import TColGeom_Array1OfCurve
from OCC.Core.TColStd import TColStd_Array1OfReal
from OCC.Core.TColgp import TColgp_HArray1OfPnt
from OCC.Core.TopAbs import TopAbs_REVERSED, TopAbs_SHELL
from OCC.Core.TopoDS import TopoDS_Shape, TopoDS_Wire, topods
from OCC.Core.gp import gp_Pnt

logger = logging.getLogger(__name__)

# Intersection tolerance handed to Gordon. Every guide meets its profiles exactly (or is snapped
# to), so this only has to absorb the 1e-8 mm error of approximating arcs by non-rational splines.
_GORDON_TOL = 1e-4
# Rational (arc, circle) and non-rational (line, spline) profiles do not mix in Gordon
# (`CurveCompatibilityFailed`), so conics are approximated by a non-rational C2 spline this tight.
_CONIC_APPROX_TOL = 1e-7
_SEWING_TOL = 1e-4
# A crossing this close (as a fraction of the edge's parameter range) to a section vertex counts
# as being at the vertex.
_VERTEX_FRACTION = 0.01
# A guide may pass this far from a profile (as a fraction of the loft's bounding-box diagonal)
# and still be snapped onto it.
_MAX_SNAP_FRACTION = 0.1
# A miss below this is float noise: no snapping, no warning.
_EXACT_MISS = 1e-6
_HIDDEN_GUIDES_PLAIN = 3
_HIDDEN_GUIDES_WITH_USER_GUIDES = 12
_SAMPLES_PER_SPAN = 6

_STATUS_NAMES = {
    2: "invalid input",
    3: "curve conversion failed",
    4: "guides do not meet the sections",
    5: "guides could not be ordered across the sections (do they cross each other?)",
    6: "reparametrisation failed",
    7: "section compatibility failed",
    8: "curve types are incompatible",
    9: "rational reparametrisation failed",
    10: "skinning failed",
    11: "reference surface failed",
    12: "knot alignment failed",
    13: "rational degree overflow",
    14: "rational construction failed",
    15: "periodicity failed",
    16: "approximation failed",
    17: "construction failed",
}


class GordonLoftError(Exception):
    """The network could not be built. `guide` (0-based index into the guides given) and `section`
    (0-based) say what to blame when it is a particular guide at a particular section; the caller
    turns this into its own 422 type."""

    def __init__(self, detail: str, *, guide: int | None = None, section: int | None = None):
        super().__init__(detail)
        self.detail = detail
        self.guide = guide
        self.section = section


@dataclass
class _Crossing:
    parameter: float  # on the guide curve
    edge: int
    fraction: float  # 0..1 along that section edge's parameter range
    point: gp_Pnt  # on the section edge (the snap target)
    miss: float  # distance from the guide to the section edge


@dataclass
class _UserGuide:
    index: int
    curve: object  # Geom_Curve between its first and last section crossing
    edge: int
    vertex: int | None  # set when it crosses every section at the same vertex
    fraction: float  # along the edge, on the first section (ordering key)


@dataclass
class GordonLoft:
    faces: list = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def _bspline(curve):
    """`curve` as a non-rational B-spline with parameter range 0..1, the form Gordon takes
    without complaint when profiles of different kinds are mixed."""
    spline = geomconvert.CurveToBSplineCurve(curve)
    if spline.IsRational():
        approx = GeomConvert_ApproxCurve(spline, _CONIC_APPROX_TOL, GeomAbs_C2, 16, 8)
        if not approx.IsDone() or approx.MaxError() > 1e-5:
            raise GordonLoftError("could not approximate a circular section for the loft")
        spline = approx.Curve()
    knots = TColStd_Array1OfReal(1, spline.NbKnots())
    spline.Knots(knots)
    low, high = knots.Value(1), knots.Value(spline.NbKnots())
    unit = TColStd_Array1OfReal(1, spline.NbKnots())
    for i in range(1, spline.NbKnots() + 1):
        unit.SetValue(i, (knots.Value(i) - low) / (high - low))
    spline.SetKnots(unit)
    return spline


def _curve_array(curves) -> TColGeom_Array1OfCurve:
    array = TColGeom_Array1OfCurve(1, len(curves))
    for position, curve in enumerate(curves, start=1):
        array.SetValue(position, _bspline(curve))
    return array


def _section_edges(wire: TopoDS_Wire) -> list:
    """The edges of `wire` in traversal order as `Geom_TrimmedCurve`s running the way the wire
    does (a reversed edge's curve is reversed, so every curve starts at its edge's start vertex)."""
    curves = []
    explorer = BRepTools_WireExplorer(wire)
    while explorer.More():
        edge = topods.Edge(explorer.Current())
        curve, first, last = BRep_Tool.Curve(edge)
        trimmed = Geom_TrimmedCurve(curve, first, last)
        if edge.Orientation() == TopAbs_REVERSED:
            trimmed.Reverse()
        curves.append(trimmed)
        explorer.Next()
    return curves


def _start(curve) -> gp_Pnt:
    return curve.Value(curve.FirstParameter())


def _end(curve) -> gp_Pnt:
    return curve.Value(curve.LastParameter())


def _point_at(curve, fraction: float) -> gp_Pnt:
    first, last = curve.FirstParameter(), curve.LastParameter()
    return curve.Value(first + fraction * (last - first))


def _interpolate(points: list[gp_Pnt]):
    array = TColgp_HArray1OfPnt(1, len(points))
    for position, point in enumerate(points, start=1):
        array.SetValue(position, point)
    interpolator = GeomAPI_Interpolate(array, False, 1e-7)
    interpolator.Perform()
    if not interpolator.IsDone():
        raise GordonLoftError("could not interpolate a guide through the section vertices")
    return interpolator.Curve()


def _hidden_guide(points: list[gp_Pnt]):
    """A guide through `points` (one per section, same vertex): a straight line for two sections,
    an interpolating curve for more."""
    for a, b in zip(points, points[1:]):
        if a.Distance(b) < 1e-9:
            raise GordonLoftError("two sections share a vertex, so no guide can run between them")
    if len(points) == 2:
        return GC_MakeSegment(points[0], points[1]).Value()
    return _interpolate(points)


def _guide_curve(wire: TopoDS_Wire):
    """The whole guide chain as one B-spline (C0 at the joins between its edges)."""
    joined = GeomConvert_CompCurveToBSplineCurve()
    explorer = BRepTools_WireExplorer(wire)
    while explorer.More():
        edge = topods.Edge(explorer.Current())
        curve, first, last = BRep_Tool.Curve(edge)
        trimmed = Geom_TrimmedCurve(curve, first, last)
        if edge.Orientation() == TopAbs_REVERSED:
            trimmed.Reverse()
        piece = geomconvert.CurveToBSplineCurve(trimmed)
        if not joined.Add(piece, 1e-4):
            raise GordonLoftError("could not join the edges of a guide curve into one curve")
        explorer.Next()
    return joined.BSplineCurve()


def _nearest_on_section(guide, edges: list) -> _Crossing:
    """Where `guide` meets (or comes closest to) a section: the nearest approach over its edges,
    from curve-curve extrema plus both curves' end points (which extrema can miss)."""
    best: _Crossing | None = None
    near: list[_Crossing] = []

    def consider(candidate: _Crossing):
        nonlocal best
        if best is None or candidate.miss < best.miss:
            best = candidate

    for edge_index, edge in enumerate(edges):
        first, last = edge.FirstParameter(), edge.LastParameter()
        span = last - first

        def at(edge_parameter: float, guide_parameter: float, edge_index=edge_index, first=first, span=span):
            point = edge.Value(edge_parameter)
            miss = point.Distance(guide.Value(guide_parameter))
            return _Crossing(guide_parameter, edge_index, (edge_parameter - first) / span, point, miss)

        try:
            extrema = GeomAPI_ExtremaCurveCurve(guide, edge)
            for k in range(1, extrema.NbExtrema() + 1):
                guide_parameter, edge_parameter = extrema.Parameters(k)
                candidate = at(edge_parameter, guide_parameter)
                consider(candidate)
                if candidate.miss < _EXACT_MISS:
                    near.append(candidate)
        except RuntimeError:
            logger.debug("curve-curve extrema failed for a guide/section pair", exc_info=True)
        for end in (first, last):
            projection = GeomAPI_ProjectPointOnCurve(edge.Value(end), guide)
            if projection.NbPoints():
                consider(at(end, projection.LowerDistanceParameter()))
        for guide_end in (guide.FirstParameter(), guide.LastParameter()):
            projection = GeomAPI_ProjectPointOnCurve(guide.Value(guide_end), edge)
            if projection.NbPoints():
                consider(at(projection.LowerDistanceParameter(), guide_end))
    assert best is not None
    # A guide that genuinely crosses a section twice has no single crossing to use.
    distinct = [c for c in near if c.point.Distance(best.point) > 1e-4]
    if distinct and best.miss < _EXACT_MISS:
        raise GordonLoftError("crosses a section more than once")
    return best


def _snap_guide(guide, crossings: list[_Crossing]):
    """`guide`, from its first to its last section crossing, bent through the exact points on the
    profiles when it misses any of them (the offset at each crossing is blended along the span
    after it). Exact when nothing is missed."""
    first, last = crossings[0].parameter, crossings[-1].parameter
    if max(c.miss for c in crossings) < _EXACT_MISS:
        return Geom_TrimmedCurve(guide, first, last)
    points: list[gp_Pnt] = []
    for crossing, following in zip(crossings, crossings[1:]):
        start = guide.Value(crossing.parameter)
        offset_a = (
            crossing.point.X() - start.X(),
            crossing.point.Y() - start.Y(),
            crossing.point.Z() - start.Z(),
        )
        end = guide.Value(following.parameter)
        offset_b = (
            following.point.X() - end.X(),
            following.point.Y() - end.Y(),
            following.point.Z() - end.Z(),
        )
        points.append(crossing.point)
        for j in range(1, _SAMPLES_PER_SPAN + 1):
            w = j / (_SAMPLES_PER_SPAN + 1)
            sample = guide.Value(crossing.parameter + w * (following.parameter - crossing.parameter))
            points.append(
                gp_Pnt(
                    sample.X() + (1 - w) * offset_a[0] + w * offset_b[0],
                    sample.Y() + (1 - w) * offset_a[1] + w * offset_b[1],
                    sample.Z() + (1 - w) * offset_a[2] + w * offset_b[2],
                )
            )
    points.append(crossings[-1].point)
    return _interpolate(points)


def _bbox_diagonal(wires: list[TopoDS_Wire]) -> float:
    box = Bnd_Box()
    for wire in wires:
        brepbndlib.Add(wire, box)
    xmin, ymin, zmin, xmax, ymax, zmax = box.Get()
    return math.dist((xmin, ymin, zmin), (xmax, ymax, zmax))


def _prepare_user_guide(
    index: int, wire: TopoDS_Wire, sections: list[list], closed: bool, diagonal: float, warnings: list[str]
) -> _UserGuide:
    """Locates `wire` against every section, orders it first-to-last section, snaps it onto the
    profiles and decides which edge (or vertex) of the sections it belongs to."""
    guide = _guide_curve(wire)
    label = f"guide {index + 1}"

    def locate() -> list[_Crossing]:
        found = []
        for section_index, edges in enumerate(sections):
            try:
                found.append(_nearest_on_section(guide, edges))
            except GordonLoftError as error:
                raise GordonLoftError(f"{label} {error}", guide=index, section=section_index) from None
        return found

    crossings = locate()
    if crossings[0].parameter > crossings[-1].parameter:
        guide.Reverse()
        crossings = locate()
    for section_index, crossing in enumerate(crossings):
        if crossing.miss > _MAX_SNAP_FRACTION * diagonal:
            raise GordonLoftError(
                f"{label} passes {crossing.miss:.2f} mm from section {section_index + 1}; "
                f"it has to reach every section (within {_MAX_SNAP_FRACTION * diagonal:.2f} mm)",
                guide=index,
                section=section_index,
            )
    parameters = [c.parameter for c in crossings]
    if any(b <= a for a, b in zip(parameters, parameters[1:])):
        raise GordonLoftError(
            f"{label} does not meet the sections in order (it doubles back)", guide=index
        )

    worst = max(crossings, key=lambda c: c.miss)
    if worst.miss >= _EXACT_MISS:
        warnings.append(
            f"Guide {index + 1} misses section {crossings.index(worst) + 1} by {worst.miss:.2f} mm; "
            f"the surface was bent to meet both, so it deviates from the guide by up to that much."
        )

    # Which edge / vertex: every section must agree.
    m = len(sections[0])

    def vertex_of(crossing: _Crossing) -> int | None:
        if crossing.fraction <= _VERTEX_FRACTION:
            return crossing.edge
        if crossing.fraction >= 1 - _VERTEX_FRACTION:
            return (crossing.edge + 1) % m if closed else crossing.edge + 1
        return None

    vertices = {vertex_of(c) for c in crossings}
    edges = {c.edge for c in crossings}
    if len(vertices) == 1 and None not in vertices:
        vertex = vertices.pop()
        edge = crossings[0].edge
    elif vertices == {None} and len(edges) == 1:
        vertex = None
        edge = edges.pop()
    else:
        raise GordonLoftError(
            f"{label} crosses the sections on different edges (section {_describe_edges(crossings)}); "
            f"a guide has to stay on the same edge, or the same corner, of every section",
            guide=index,
        )
    return _UserGuide(
        index=index,
        curve=_snap_guide(guide, crossings),
        edge=edge,
        vertex=vertex,
        fraction=crossings[0].fraction,
    )


def _describe_edges(crossings: list[_Crossing]) -> str:
    return ", ".join(f"{k + 1}: edge {c.edge + 1}" for k, c in enumerate(crossings))


def _gordon_surface(profiles, guides, warnings: list[str], what: str):
    gordon = GeomFill_Gordon()
    gordon.Init(_curve_array(profiles), _curve_array(guides), _GORDON_TOL)
    gordon.SetApproximationMode(GeomFill_Gordon.ApproximationMode_AllowApproximateFallback)
    try:
        gordon.Perform()
    except (RuntimeError, IndexError, KeyError) as error:
        raise GordonLoftError(f"could not build the surface for {what}: {error}") from None
    if not gordon.IsDone():
        status = int(gordon.Status())
        raise GordonLoftError(f"could not build the surface for {what}: {_STATUS_NAMES.get(status, f'status {status}')}")
    if gordon.IsApproximate():
        warnings.append(f"The surface for {what} is an approximation of the guide network.")
    return gordon.Surface()


def _face_from_patch(surface, profiles, guides):
    """The face for one Gordon patch. A patch that turns out planar (a straight-sided loft face,
    the common case) becomes a real plane bounded by its four boundary curves: a B-spline surface
    that happens to be flat is far slower to intersect, mesh and fillet than the plane it is."""
    plane = GeomLib_IsPlanarSurface(surface, 1e-7)
    if plane.IsPlanar() and len(guides) >= 2:
        try:
            loop = [profiles[0], guides[-1], profiles[-1].Reversed(), guides[0].Reversed()]
            wire_maker = BRepBuilderAPI_MakeWire()
            for curve in loop:
                wire_maker.Add(BRepBuilderAPI_MakeEdge(curve).Edge())
            if wire_maker.IsDone():
                face_maker = BRepBuilderAPI_MakeFace(Geom_Plane(plane.Plan()), wire_maker.Wire(), True)
                if face_maker.IsDone():
                    return face_maker.Face()
        except RuntimeError:
            logger.debug("planar patch face failed; keeping the B-spline surface", exc_info=True)
    return BRepBuilderAPI_MakeFace(surface, 1e-6).Face()


def _patch_faces(
    sections: list[list],
    closed: bool,
    user_guides: list[_UserGuide],
    warnings: list[str],
) -> list:
    """The faces of one Gordon network over `sections` (lists of edge curves, same edge count)."""
    m = len(sections[0])
    faces = []

    if closed and m == 1:
        # A single periodic face. Hidden guides at equal parameter fractions, except near a user guide.
        profiles = [edges[0] for edges in sections]
        total = _HIDDEN_GUIDES_WITH_USER_GUIDES if user_guides else _HIDDEN_GUIDES_PLAIN
        keep_clear = 1.0 / (2 * total)
        placed: list[tuple[float, object]] = []
        seam = next((g for g in user_guides if g.vertex is not None), None)
        placed.append((0.0, seam.curve if seam else _hidden_guide([_point_at(c, 0.0) for c in profiles])))
        interior = [g for g in user_guides if g.vertex is None]
        for g in interior:
            placed.append((g.fraction, g.curve))
        for k in range(1, total):
            fraction = k / total
            if all(abs(fraction - f) >= keep_clear for f, _ in placed):
                placed.append((fraction, _hidden_guide([_point_at(c, fraction) for c in profiles])))
        placed.sort(key=lambda item: item[0])
        surface = _gordon_surface(profiles, [g for _, g in placed], warnings, "the closed section")
        return [BRepBuilderAPI_MakeFace(surface, 1e-6).Face()]

    vertex_count = m if closed else m + 1
    vertex_guides = []
    for v in range(vertex_count):
        user = next((g for g in user_guides if g.vertex == v), None)
        if user is not None:
            vertex_guides.append(user.curve)
        else:
            points = [_start(edges[v]) if v < m else _end(edges[m - 1]) for edges in sections]
            vertex_guides.append(_hidden_guide(points))
    for i in range(m):
        profiles = [edges[i] for edges in sections]
        interior = sorted((g for g in user_guides if g.vertex is None and g.edge == i), key=lambda g: g.fraction)
        guides = [vertex_guides[i]] + [g.curve for g in interior] + [vertex_guides[(i + 1) % vertex_count]]
        surface = _gordon_surface(profiles, guides, warnings, f"edge {i + 1} of the sections")
        faces.append(_face_from_patch(surface, profiles, guides))
    return faces


def _orient_open_sections(sections: list[list]) -> list[list]:
    """Open chains have no seam to align but do have a direction: `ThruSections` flips a chain that
    runs the opposite way to its neighbour (otherwise the loft is a bow-tie). Same rule here: each
    section after the first is reversed when its ends are nearer the *other* ends of the section
    before it."""
    oriented = [sections[0]]
    for edges in sections[1:]:
        previous = oriented[-1]
        start, end = _start(previous[0]), _end(previous[-1])
        same = start.Distance(_start(edges[0])) + end.Distance(_end(edges[-1]))
        flipped = start.Distance(_end(edges[-1])) + end.Distance(_start(edges[0]))
        if flipped < same - 1e-9:
            reversed_edges = [curve.Reversed() for curve in reversed(edges)]
            edges = reversed_edges
        oriented.append(edges)
    return oriented


def loft_faces(
    wires: list[TopoDS_Wire], *, ruled: bool = False, guides: list[TopoDS_Wire] | None = None
) -> GordonLoft:
    """The side faces of a loft through `wires` (already harmonised to one edge count) with optional
    `guides`: one face per section edge. `ruled` builds each span between neighbouring sections
    separately (straight hidden guides), as `ThruSections(ruled=True)` does."""
    guides = guides or []
    result = GordonLoft()
    if len(wires) < 2:
        raise GordonLoftError("a loft needs at least 2 sections")
    sections = [_section_edges(wire) for wire in wires]
    counts = {len(edges) for edges in sections}
    if len(counts) != 1:
        raise GordonLoftError("the sections have different numbers of edges")
    closed_flags = {bool(BRep_Tool.IsClosed(wire)) for wire in wires}
    if len(closed_flags) != 1:
        raise GordonLoftError("sections must be all closed or all open")
    closed = closed_flags.pop()
    if not closed:
        sections = _orient_open_sections(sections)
    if ruled and guides:
        raise GordonLoftError("a ruled loft cannot use guide curves: straight spans contradict a curved guide")

    if ruled:
        for k in range(len(wires) - 1):
            result.faces.extend(_patch_faces([sections[k], sections[k + 1]], closed, [], result.warnings))
        return result

    diagonal = _bbox_diagonal(wires)
    prepared = [
        _prepare_user_guide(i, guide, sections, closed, diagonal, result.warnings) for i, guide in enumerate(guides)
    ]
    _check_guide_order(prepared)
    result.faces.extend(_patch_faces(sections, closed, prepared, result.warnings))
    return result


def _check_guide_order(prepared: list[_UserGuide]) -> None:
    seen_vertices: dict[int, int] = {}
    for guide in prepared:
        if guide.vertex is not None:
            if guide.vertex in seen_vertices:
                raise GordonLoftError(
                    f"guides {seen_vertices[guide.vertex] + 1} and {guide.index + 1} both run through the same corner",
                    guide=guide.index,
                )
            seen_vertices[guide.vertex] = guide.index


def _planar_cap(wire: TopoDS_Wire, section: int):
    maker = BRepBuilderAPI_MakeFace(wire, True)
    if not maker.IsDone():
        raise GordonLoftError(
            f"section {section + 1} is not planar, so the loft cannot be capped there; "
            f"use a Loft Surface instead",
            section=section,
        )
    return maker.Face()


def _volume(shape: TopoDS_Shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


def sew_shell(faces: list) -> TopoDS_Shape:
    """The faces sewn into a shell (or compound of shells when they do not all connect)."""
    sewing = BRepBuilderAPI_Sewing(_SEWING_TOL)
    for face in faces:
        sewing.Add(face)
    sewing.Perform()
    return sewing.SewedShape()


def capped_solid(faces: list, wires: list[TopoDS_Wire]) -> TopoDS_Shape:
    """A solid from the side `faces` plus planar caps on the first and last section."""
    caps = [_planar_cap(wires[0], 0), _planar_cap(wires[-1], len(wires) - 1)]
    shell = sew_shell(faces + caps)
    if shell.ShapeType() != TopAbs_SHELL:
        raise GordonLoftError("the lofted faces did not close into one shell")
    solid = BRepBuilderAPI_MakeSolid(topods.Shell(shell)).Solid()
    fixer = ShapeFix_Solid(solid)
    fixer.Perform()
    solid = fixer.Solid()
    if _volume(solid) < 0:
        solid = solid.Reversed()
    if not BRepCheck_Analyzer(solid).IsValid():
        raise GordonLoftError("the lofted solid is not valid")
    return solid
