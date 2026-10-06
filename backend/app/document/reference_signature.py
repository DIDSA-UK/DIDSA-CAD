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
from OCC.Core.BRepGProp import BRepGProp_Face
from OCC.Core.gp import gp_Pnt, gp_Vec
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_VERTEX
from OCC.Core.TopExp import topexp
from OCC.Core.TopoDS import TopoDS_Shape, topods
from OCC.Core.TopTools import TopTools_IndexedDataMapOfShapeListOfShape, TopTools_IndexedMapOfShape

from app.sketch.reference_signature import VertexSignature

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
