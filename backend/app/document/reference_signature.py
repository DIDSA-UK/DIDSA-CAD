"""OCCT-bound half of the reference-identity overhaul (docs/reference-identity-design.md): measures a Body's vertices into `VertexSignature`s.

The pure decision logic is `app.sketch.reference_signature`; this module only turns a `TopoDS_Shape` into numbers. Vertex indices are the same 0-based
`topexp.MapShapes(body, TopAbs_VERTEX)` enumeration `SubShapeRef` / `extrude.resolve_subshape_from_bodies` use, so `signatures[i]` describes the
vertex `SubShapeRef(index=i)` resolves to.
"""

from __future__ import annotations

import math

from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepGProp import BRepGProp_Face, brepgprop
from OCC.Core.BRepTools import breptools
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Pnt, gp_Vec
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_VERTEX
from OCC.Core.TopExp import topexp
from OCC.Core.TopoDS import TopoDS_Shape, topods
from OCC.Core.TopTools import TopTools_IndexedDataMapOfShapeListOfShape, TopTools_IndexedMapOfShape

from app.sketch.reference_signature import EdgeSignature, FaceSignature, ShapeSignature, VertexSignature

_SURFACE_KIND_NAMES = {
    0: "plane",
    1: "cylinder",
    2: "cone",
    3: "sphere",
    4: "torus",
    5: "bezier",
    6: "bspline",
    7: "revolution",
    8: "extrusion",
    9: "offset",
    10: "other",
}


def body_diagonal(shape: TopoDS_Shape) -> float:
    box = Bnd_Box()
    brepbndlib.Add(shape, box)
    if box.IsVoid():
        return 0.0
    xmin, ymin, zmin, xmax, ymax, zmax = box.Get()
    return math.dist((xmin, ymin, zmin), (xmax, ymax, zmax))


def _unit(vec: gp_Vec) -> tuple[float, float, float] | None:
    magnitude = vec.Magnitude()
    if magnitude < 1e-12:
        return None
    return (vec.X() / magnitude, vec.Y() / magnitude, vec.Z() / magnitude)


def _face_normal_at_vertex(face: TopoDS_Shape, vertex: TopoDS_Shape) -> tuple[tuple[float, float, float], str] | None:
    """The outward unit normal of `face` at `vertex` and the face's surface kind. `BRepGProp_Face` already applies the face's own orientation, so this is the outward normal."""
    face = topods.Face(face)
    try:
        uv = BRep_Tool.Parameters(topods.Vertex(vertex), face)
        u, v = uv.X(), uv.Y()
        point, normal = gp_Pnt(), gp_Vec()
        BRepGProp_Face(face).Normal(u, v, point, normal)
        unit = _unit(normal)
        if unit is None:
            return None
        kind = _SURFACE_KIND_NAMES.get(int(BRepAdaptor_Surface(face, True).GetType()), "other")
        return unit, kind
    except Exception:  # a degenerate parametrisation (cone apex, sphere pole): this face contributes no normal
        return None


def _edge_direction_at_vertex(edge: TopoDS_Shape, vertex: TopoDS_Shape) -> tuple[float, float, float] | None:
    try:
        edge = topods.Edge(edge)
        curve = BRepAdaptor_Curve(edge)
        found, parameter = BRep_Tool.Parameter(topods.Vertex(vertex), edge)
        if not found:
            return None
        point, tangent = gp_Pnt(), gp_Vec()
        curve.D1(parameter, point, tangent)
        unit = _unit(tangent)
        if unit is None:
            return None
        # Unsigned: an edge has no preferred direction, so flip into the half-space with the larger leading component.
        for component in unit:
            if abs(component) > 1e-9:
                if component < 0:
                    unit = (-unit[0], -unit[1], -unit[2])
                break
        return unit
    except Exception:
        return None


def _round_key(vec: tuple[float, float, float]) -> tuple[float, float, float]:
    return (round(vec[0], 3), round(vec[1], 3), round(vec[2], 3))


class BodyVertexMeasurer:
    """Measures the vertices of one Body shape on demand and remembers them: the ancestor maps are built once, each vertex's signature only when asked
    for (the common refresh needs just the one vertex the stored index names; the search path measures them all)."""

    def __init__(self, shape: TopoDS_Shape) -> None:
        self._diagonal = body_diagonal(shape)
        self._vertices = TopTools_IndexedMapOfShape()
        topexp.MapShapes(shape, TopAbs_VERTEX, self._vertices)
        self._faces_of = TopTools_IndexedDataMapOfShapeListOfShape()
        topexp.MapShapesAndAncestors(shape, TopAbs_VERTEX, TopAbs_FACE, self._faces_of)
        self._edges_of = TopTools_IndexedDataMapOfShapeListOfShape()
        topexp.MapShapesAndAncestors(shape, TopAbs_VERTEX, TopAbs_EDGE, self._edges_of)
        self._cache: dict[int, VertexSignature] = {}

    @property
    def count(self) -> int:
        return self._vertices.Size()

    @property
    def diagonal(self) -> float:
        return self._diagonal

    def signature(self, index: int) -> VertexSignature:
        """The signature of vertex `index` (0-based, `topexp.MapShapes` order)."""
        cached = self._cache.get(index)
        if cached is not None:
            return cached
        i = index + 1
        vertex = self._vertices.FindKey(i)
        point = BRep_Tool.Pnt(topods.Vertex(vertex))

        normals: list[tuple[tuple[float, float, float], str]] = []
        seen_faces = TopTools_IndexedMapOfShape()
        for face in self._faces_of.FindFromIndex(i):
            if seen_faces.Contains(face):
                continue
            seen_faces.Add(face)
            measured = _face_normal_at_vertex(face, vertex)
            if measured is not None:
                normals.append(measured)
        normals.sort(key=lambda item: (item[1], _round_key(item[0])))

        directions: list[tuple[float, float, float]] = []
        seen_edges = TopTools_IndexedMapOfShape()
        for edge in self._edges_of.FindFromIndex(i):
            if seen_edges.Contains(edge) or BRep_Tool.Degenerated(topods.Edge(edge)):
                continue
            seen_edges.Add(edge)
            direction = _edge_direction_at_vertex(edge, vertex)
            if direction is not None:
                directions.append(direction)
        directions.sort(key=_round_key)

        measured_signature = VertexSignature(
            position=(point.X(), point.Y(), point.Z()),
            valence=seen_edges.Size(),
            face_normals=tuple(n for n, _ in normals),
            face_kinds=tuple(k for _, k in normals),
            edge_directions=tuple(directions),
            body_diagonal=self._diagonal,
        )
        self._cache[index] = measured_signature
        return measured_signature

    def all(self) -> list[VertexSignature]:
        return [self.signature(i) for i in range(self.count)]


def vertex_signatures(shape: TopoDS_Shape) -> list[VertexSignature]:
    """The signature of every vertex of `shape`, in `topexp.MapShapes` index order."""
    return BodyVertexMeasurer(shape).all()


def vertex_signature(shape: TopoDS_Shape, index: int) -> VertexSignature:
    """One vertex's signature (callers measuring several vertices of one Body should keep a `BodyVertexMeasurer`)."""
    return BodyVertexMeasurer(shape).signature(index)


# --- edges and faces (reference-identity overhaul, SubShapeRef consumers) --------------------------------------------------------------

_CURVE_KIND_NAMES = {0: "line", 1: "circle"}


def _unsigned(unit: tuple[float, float, float]) -> tuple[float, float, float]:
    for component in unit:
        if abs(component) > 1e-9:
            return unit if component > 0 else (-unit[0], -unit[1], -unit[2])
    return unit


class BodyEdgeMeasurer:
    """`BodyVertexMeasurer`'s edge counterpart: signature of edge `index` (0-based, `topexp.MapShapes` order) of one Body, measured on demand and remembered."""

    def __init__(self, shape: TopoDS_Shape) -> None:
        self._diagonal = body_diagonal(shape)
        self._edges = TopTools_IndexedMapOfShape()
        topexp.MapShapes(shape, TopAbs_EDGE, self._edges)
        self._faces_of = TopTools_IndexedDataMapOfShapeListOfShape()
        topexp.MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, self._faces_of)
        self._cache: dict[int, EdgeSignature] = {}

    @property
    def count(self) -> int:
        return self._edges.Size()

    @property
    def diagonal(self) -> float:
        return self._diagonal

    def signature(self, index: int) -> EdgeSignature:
        cached = self._cache.get(index)
        if cached is not None:
            return cached
        edge = topods.Edge(self._edges.FindKey(index + 1))
        curve = BRepAdaptor_Curve(edge)
        first, last = curve.FirstParameter(), curve.LastParameter()
        middle = (first + last) / 2.0
        point, tangent = gp_Pnt(), gp_Vec()
        curve.D1(middle, point, tangent)
        kind = _CURVE_KIND_NAMES.get(int(curve.GetType()), "other")
        direction = (0.0, 0.0, 0.0)
        radius, centre = 0.0, (0.0, 0.0, 0.0)
        if kind == "line":
            unit = _unit(tangent)
            direction = _unsigned(unit) if unit is not None else direction
        elif kind == "circle":
            circle = curve.Circle()
            axis = circle.Axis().Direction()
            direction = _unsigned((axis.X(), axis.Y(), axis.Z()))
            radius = circle.Radius()
            location = circle.Location()
            centre = (location.X(), location.Y(), location.Z())
        length = 0.0
        try:
            props = GProp_GProps()
            brepgprop.LinearProperties(edge, props)
            length = props.Mass()
        except Exception:
            pass

        normals: list[tuple[tuple[float, float, float], str]] = []
        seen = TopTools_IndexedMapOfShape()
        for face in self._faces_of.FindFromIndex(index + 1):
            if seen.Contains(face):
                continue
            seen.Add(face)
            face = topods.Face(face)
            try:
                pcurve, p_first, p_last = BRep_Tool.CurveOnSurface(edge, face)
                uv = pcurve.Value(p_first + (p_last - p_first) * ((middle - first) / (last - first) if last > first else 0.5))
                surface_point, normal = gp_Pnt(), gp_Vec()
                BRepGProp_Face(face).Normal(uv.X(), uv.Y(), surface_point, normal)
                unit = _unit(normal)
                if unit is not None:
                    kind_name = _SURFACE_KIND_NAMES.get(int(BRepAdaptor_Surface(face, True).GetType()), "other")
                    normals.append((unit, kind_name))
            except Exception:
                continue
        normals.sort(key=lambda item: (item[1], _round_key(item[0])))
        measured = EdgeSignature(
            position=(point.X(), point.Y(), point.Z()),
            curve_kind=kind,
            direction=direction,
            length=length,
            radius=radius,
            centre=centre,
            face_normals=tuple(n for n, _ in normals),
            face_kinds=tuple(k for _, k in normals),
            body_diagonal=self._diagonal,
        )
        self._cache[index] = measured
        return measured

    def all(self) -> list[EdgeSignature]:
        return [self.signature(i) for i in range(self.count)]


class BodyFaceMeasurer:
    """`BodyVertexMeasurer`'s face counterpart (signature of face `index`, 0-based, `topexp.MapShapes` order)."""

    def __init__(self, shape: TopoDS_Shape) -> None:
        self._diagonal = body_diagonal(shape)
        self._faces = TopTools_IndexedMapOfShape()
        topexp.MapShapes(shape, TopAbs_FACE, self._faces)
        self._cache: dict[int, FaceSignature] = {}

    @property
    def count(self) -> int:
        return self._faces.Size()

    @property
    def diagonal(self) -> float:
        return self._diagonal

    def signature(self, index: int) -> FaceSignature:
        cached = self._cache.get(index)
        if cached is not None:
            return cached
        face = topods.Face(self._faces.FindKey(index + 1))
        props = GProp_GProps()
        brepgprop.SurfaceProperties(face, props)
        centre = props.CentreOfMass()
        surface = BRepAdaptor_Surface(face, True)
        kind = _SURFACE_KIND_NAMES.get(int(surface.GetType()), "other")
        direction = (0.0, 0.0, 0.0)
        try:
            if kind in ("cylinder", "cone", "sphere", "torus"):
                axis = {
                    "cylinder": lambda: surface.Cylinder().Axis(),
                    "cone": lambda: surface.Cone().Axis(),
                    "sphere": lambda: surface.Sphere().Position().Axis(),
                    "torus": lambda: surface.Torus().Axis(),
                }[kind]().Direction()
                direction = _unsigned((axis.X(), axis.Y(), axis.Z()))
            else:
                u_min, u_max, v_min, v_max = breptools.UVBounds(face)
                point, normal = gp_Pnt(), gp_Vec()
                BRepGProp_Face(face).Normal((u_min + u_max) / 2.0, (v_min + v_max) / 2.0, point, normal)
                unit = _unit(normal)
                if unit is not None:
                    direction = unit if kind == "plane" else _unsigned(unit)
        except Exception:
            pass
        measured = FaceSignature(
            position=(centre.X(), centre.Y(), centre.Z()),
            surface_kind=kind,
            direction=direction,
            area=props.Mass(),
            body_diagonal=self._diagonal,
        )
        self._cache[index] = measured
        return measured

    def all(self) -> list[FaceSignature]:
        return [self.signature(i) for i in range(self.count)]

    def index_of(self, face: TopoDS_Shape) -> int:
        """0-based index of `face` in this Body, or -1 when it is not one of its faces."""
        return self._faces.FindIndex(face) - 1

    def shape_at(self, index: int) -> TopoDS_Shape:
        return self._faces.FindKey(index + 1)


_MEASURER_CACHE: dict[tuple[int, str], tuple[TopoDS_Shape, object]] = {}
_MEASURER_CACHE_SIZE = 16


def measurer_for(shape: TopoDS_Shape, kind: str):
    """The (cached per Body shape object) measurer for `kind` ("vertex" / "edge" / "face"). A replay builds each Body once and may resolve many references
    against it, so the ancestor maps are built once per Body per replay, not once per reference. The shape is kept alive by the cache entry, so `id()` stays
    unique for as long as the entry exists."""
    key = (id(shape), kind)
    hit = _MEASURER_CACHE.get(key)
    if hit is not None:
        return hit[1]
    measurer = {"vertex": BodyVertexMeasurer, "edge": BodyEdgeMeasurer, "face": BodyFaceMeasurer}[kind](shape)
    while len(_MEASURER_CACHE) >= _MEASURER_CACHE_SIZE:
        _MEASURER_CACHE.pop(next(iter(_MEASURER_CACHE)))
    _MEASURER_CACHE[key] = (shape, measurer)
    return measurer
