"""Thin walls built in 2D: the profile's wire is offset in its own plane and the region between the offsets is the wall's
cross-section. Used by a thin Revolve (Flutter-testing feedback 2026-11-11, item 5); kept apart so Extrude can use it later
(Extrude still thickens a prism shell and is not switched over here).

Why not Extrude's cap-removal approach: a 360 degree revolve has no caps to remove, and thickening a closed solid that has no
closing faces makes a hidden inner void, not a wall. Offsetting the wire first and revolving the ring has no such problem, and for
an angle below 360 gives the same solid (the revolved side faces' normals lie in the profile plane).

`ThicknessDirection`, closed profile (read against the sketched wire's material): `OUTWARD` grows the wall away from the
material (between the wire and its +t offset), `INWARD` into it (between the -t offset and the wire), `SYMMETRIC` by t/2 on both
sides. Open chain (no inside or outside, so the enum is read against the revolve **axis**): `OUTWARD` = the wall grows on the side
away from the axis, `INWARD` = toward the axis, `SYMMETRIC` = both sides by t/2.

Everything fails with `ThinProfileError(reason)`; the router turns that into the 422 `thin_revolve_failed` with the reason.
Holes (the profile's inner loops) are not thinned in v1: only the outer wire is.
"""

from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakePolygon,
    BRepBuilderAPI_MakeWire,
)
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakeOffset
from OCC.Core.GeomAbs import GeomAbs_Intersection, GeomAbs_Plane
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax1, gp_Pln, gp_Pnt, gp_Vec
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_WIRE
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopoDS import TopoDS_Face, TopoDS_Vertex, TopoDS_Wire, topods
from OCC.Core.TopTools import TopTools_ListOfShape

from app.document.models import ThicknessDirection

# A chain end this close to the axis is "on" it (the end cap then lies along the axis and the revolve closes it); one that is
# farther than this but closer than NEAR_AXIS_BAND is refused as `near_axis` (almost, but not quite, on the axis).
ON_AXIS_TOLERANCE = 1e-6
NEAR_AXIS_BAND = 1e-2
CROSS_TOLERANCE = 1e-6
_MIN_AREA = 1e-9


class ThinProfileError(Exception):
    """A thin profile could not be built. `reason` is one of `inward_collapsed`, `offset_failed`, `crosses_axis`,
    `near_axis`, `invalid_ring`, `revolve_failed`."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def _area(face: TopoDS_Face) -> float:
    props = GProp_GProps()
    brepgprop.SurfaceProperties(face, props)
    return props.Mass()


def _face_of_wire(wire: TopoDS_Wire) -> TopoDS_Face:
    maker = BRepBuilderAPI_MakeFace(wire, True)
    if not maker.IsDone():
        raise ThinProfileError("offset_failed")
    return maker.Face()


def _straight_offset(wire: TopoDS_Wire, distance: float, plane: gp_Pln) -> list[TopoDS_Wire]:
    """`BRepOffsetAPI_MakeOffset` cannot give a straight (single-direction) chain a plane of its own, so it refuses it: offset it
    directly instead, along the in-plane normal (positive = to the left of the chain's own direction in `plane`). Empty when the
    chain is not straight."""
    first, last = _end_vertices(wire)
    p0, p1 = _point(first), _point(last)
    direction = gp_Vec(p0, p1)
    length = direction.Magnitude()
    if length < 1e-12:
        return []
    direction.Normalize()
    for point in _wire_points(wire, samples_per_edge=4):
        if gp_Vec(p0, point).Crossed(direction).Magnitude() > 1e-9:
            return []  # bends: not a straight chain
    side = gp_Vec(plane.Axis().Direction()).Crossed(direction)
    side.Normalize()
    shift = side.Multiplied(distance)
    polygon = BRepBuilderAPI_MakePolygon()
    polygon.Add(p0.Translated(shift))
    polygon.Add(p1.Translated(shift))
    return [polygon.Wire()]


def _offset_wires(
    wire: TopoDS_Wire, distance: float, open_result: bool, plane: gp_Pln | None = None
) -> list[TopoDS_Wire]:
    """The wire(s) `BRepOffsetAPI_MakeOffset` gives for `distance` (sharp `GeomAbs_Intersection` corners, as Extrude's thin walls
    have). Empty when the offset collapsed away (an inward offset past the profile's half width). A straight open chain (which
    the kernel refuses) is offset directly when `plane` is given."""
    maker = BRepOffsetAPI_MakeOffset()
    maker.Init(GeomAbs_Intersection, open_result)
    maker.AddWire(wire)
    wires: list[TopoDS_Wire] = []
    try:
        maker.Perform(distance)
        if maker.IsDone():
            explorer = TopExp_Explorer(maker.Shape(), TopAbs_WIRE)
            while explorer.More():
                wires.append(topods.Wire(explorer.Current()))
                explorer.Next()
    except RuntimeError:
        wires = []
    if not wires and open_result and plane is not None:
        return _straight_offset(wire, distance, plane)
    return wires


def _ring(big: TopoDS_Face, small: TopoDS_Face) -> TopoDS_Face:
    """The region of `big` that is not in `small` (both planar, in one plane): one face with one hole."""
    cut = BRepAlgoAPI_Cut(big, small)
    if not cut.IsDone():
        raise ThinProfileError("offset_failed")
    explorer = TopExp_Explorer(cut.Shape(), TopAbs_FACE)
    faces = []
    while explorer.More():
        faces.append(topods.Face(explorer.Current()))
        explorer.Next()
    if len(faces) != 1:
        raise ThinProfileError("offset_failed")
    expected = _area(big) - _area(small)
    if abs(_area(faces[0]) - expected) > 1e-6 * max(1.0, abs(expected)):
        raise ThinProfileError("invalid_ring")
    return faces[0]


def ring_for_closed_wire(outer_wire: TopoDS_Wire, thickness: float, direction: ThicknessDirection) -> TopoDS_Face:
    """The wall's cross-section for a closed profile's outer wire: see the module docstring for which side each direction is."""
    base = _face_of_wire(outer_wire)
    base_area = _area(base)

    # Which sign of offset grows the profile depends on the wire's winding: find it by area, never by assumption.
    probe = _offset_wires(outer_wire, thickness, open_result=False)
    if len(probe) != 1:
        raise ThinProfileError("offset_failed")
    grow = 1.0 if _area(_face_of_wire(probe[0])) > base_area else -1.0

    def offset_face(amount: float, *, inward: bool) -> TopoDS_Face:
        wires = _offset_wires(outer_wire, grow * amount, open_result=False)
        if len(wires) != 1:
            raise ThinProfileError("inward_collapsed" if inward else "offset_failed")
        face = _face_of_wire(wires[0])
        area = _area(face)
        if inward and not _MIN_AREA < area < base_area:
            raise ThinProfileError("inward_collapsed")
        return face

    if direction == ThicknessDirection.OUTWARD:
        return _ring(offset_face(thickness, inward=False), base)
    if direction == ThicknessDirection.INWARD:
        return _ring(base, offset_face(-thickness, inward=True))
    return _ring(offset_face(thickness / 2.0, inward=False), offset_face(-thickness / 2.0, inward=True))


def _end_vertices(wire: TopoDS_Wire) -> tuple[TopoDS_Vertex, TopoDS_Vertex]:
    first, last = TopoDS_Vertex(), TopoDS_Vertex()
    topexp.Vertices(wire, first, last)
    return first, last


def _point(vertex: TopoDS_Vertex) -> gp_Pnt:
    return BRep_Tool.Pnt(vertex)


def distance_to_axis(point: gp_Pnt, axis: gp_Ax1) -> float:
    """Distance from `point` to the (infinite) axis line."""
    direction = gp_Vec(axis.Direction())
    offset = gp_Vec(axis.Location(), point)
    return offset.Crossed(direction).Magnitude()


def _wire_points(wire: TopoDS_Wire, samples_per_edge: int = 12) -> list[gp_Pnt]:
    points: list[gp_Pnt] = []
    explorer = TopExp_Explorer(wire, TopAbs_EDGE)
    while explorer.More():
        curve = BRepAdaptor_Curve(topods.Edge(explorer.Current()))
        first, last = curve.FirstParameter(), curve.LastParameter()
        for i in range(samples_per_edge + 1):
            points.append(curve.Value(first + (last - first) * i / samples_per_edge))
        explorer.Next()
    return points


def _mean_axis_distance(wire: TopoDS_Wire, axis: gp_Ax1) -> float:
    points = _wire_points(wire)
    return sum(distance_to_axis(p, axis) for p in points) / len(points)


def _check_axis_ends(open_wire: TopoDS_Wire, axis: gp_Ax1) -> None:
    for vertex in _end_vertices(open_wire):
        distance = distance_to_axis(_point(vertex), axis)
        if ON_AXIS_TOLERANCE < distance < NEAR_AXIS_BAND:
            raise ThinProfileError("near_axis")


def _closing_wire(a: TopoDS_Wire, b: TopoDS_Wire) -> TopoDS_Wire:
    """One closed wire out of two open wires with the same kind of ends: `a`, a straight end cap, `b` the other way, a cap.
    The end of `a` is joined to the nearer end of `b`."""
    a0, a1 = (_point(v) for v in _end_vertices(a))
    b0, b1 = (_point(v) for v in _end_vertices(b))
    straight = a0.Distance(b0) + a1.Distance(b1)
    crossed = a0.Distance(b1) + a1.Distance(b0)
    (c0, c1) = ((b0, b1) if straight <= crossed else (b1, b0))
    # One list of all the edges (the offsets' edges come in no particular order); the wire maker connects them by their ends.
    edges = TopTools_ListOfShape()
    for source in (a, b):
        explorer = TopExp_Explorer(source, TopAbs_EDGE)
        while explorer.More():
            edges.Append(explorer.Current())
            explorer.Next()
    for p, q in ((a0, c0), (a1, c1)):
        if p.Distance(q) > 1e-9:
            edges.Append(BRepBuilderAPI_MakeEdge(p, q).Edge())
    maker = BRepBuilderAPI_MakeWire()
    maker.Add(edges)
    if not maker.IsDone():
        raise ThinProfileError("offset_failed")
    return maker.Wire()


def ring_for_open_wire(
    open_wire: TopoDS_Wire, thickness: float, direction: ThicknessDirection, axis: gp_Ax1, plane: gp_Pln
) -> TopoDS_Face:
    """The wall's cross-section for one open chain: the chain and an offset of it (or two offsets) joined by straight end caps into one
    face. The side is chosen against `axis` (module docstring). A chain end on the axis is allowed (the end cap lies along the axis
    and the revolve closes it); one almost on it is `near_axis`."""
    _check_axis_ends(open_wire, axis)
    plus = _offset_wires(open_wire, thickness, open_result=True, plane=plane)
    minus = _offset_wires(open_wire, -thickness, open_result=True, plane=plane)
    if len(plus) != 1 or len(minus) != 1:
        raise ThinProfileError("offset_failed")
    # "Away from the axis" is the side whose offset sits farther from it on average.
    if _mean_axis_distance(plus[0], axis) >= _mean_axis_distance(minus[0], axis):
        sign_away = 1.0
    else:
        sign_away = -1.0

    def offset(amount: float) -> TopoDS_Wire:
        wires = _offset_wires(open_wire, amount, open_result=True, plane=plane)
        if len(wires) != 1:
            raise ThinProfileError("offset_failed")
        return wires[0]

    if direction == ThicknessDirection.OUTWARD:
        closed = _closing_wire(open_wire, offset(sign_away * thickness))
    elif direction == ThicknessDirection.INWARD:
        closed = _closing_wire(open_wire, offset(-sign_away * thickness))
    else:
        closed = _closing_wire(offset(sign_away * thickness / 2.0), offset(-sign_away * thickness / 2.0))
    face = _face_of_wire(closed)
    if not BRepCheck_Analyzer(face).IsValid() or _area(face) < _MIN_AREA:
        raise ThinProfileError("invalid_ring")
    return face


def ring_crosses_axis(face: TopoDS_Face, axis: gp_Ax1) -> bool:
    """True when the ring has material on both sides of `axis` (a revolve of it would intersect itself). Touching the axis from one
    side is fine. Only judged when the axis lies in the ring's plane (the normal case: a Sketch Line in the same Sketch); an axis out
    of the plane is left to `BRepPrimAPI_MakeRevol`'s own failure."""
    surface = BRepAdaptor_Surface(face)
    if surface.GetType() != GeomAbs_Plane:
        return False
    plane = surface.Plane()
    normal = gp_Vec(plane.Axis().Direction())
    direction = gp_Vec(axis.Direction())
    if abs(normal.Dot(direction)) > 1e-6:
        return False
    if abs(gp_Vec(plane.Location(), axis.Location()).Dot(normal)) > 1e-6:
        return False
    side = normal.Crossed(direction)
    low = high = 0.0
    explorer = TopExp_Explorer(face, TopAbs_WIRE)
    while explorer.More():
        for point in _wire_points(topods.Wire(explorer.Current())):
            s = gp_Vec(axis.Location(), point).Dot(side)
            low, high = min(low, s), max(high, s)
        explorer.Next()
    return high > CROSS_TOLERANCE and low < -CROSS_TOLERANCE


def checked_ring(ring: TopoDS_Face, axis: gp_Ax1) -> TopoDS_Face:
    if ring_crosses_axis(ring, axis):
        raise ThinProfileError("crosses_axis")
    return ring


__all__ = [
    "ThinProfileError",
    "checked_ring",
    "distance_to_axis",
    "ring_crosses_axis",
    "ring_for_closed_wire",
    "ring_for_open_wire",
]
