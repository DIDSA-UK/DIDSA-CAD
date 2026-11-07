"""Sketch origin defaults ("auto"): docs/view-override-edit-alone-sketch-origin-plan.md Item 3.

A client that sends `origin: "auto"` gets a concrete stored origin (or None), so the stored value never changes by itself after creation:

| Anchor                                                                          | Default origin                                                  |
|---------------------------------------------------------------------------------|-----------------------------------------------------------------|
| a fixed plane, a Plane offset from one (or from a Plane that ends at one)       | None: the plane's own origin                                    |
| a Body face (or a Plane offset from / parallel to one)                          | the face's bottom-left corner, as the Sketch is ORIENTED        |
| such a face whose outer boundary is one circular edge (a disc, a cylinder end)  | that edge's centre                                              |
| anything else (three points, midplane, normal to a line / curve / edge, a face with a curved boundary and no corner) | None                |

"Bottom-left" = the outer-wire vertex with the smallest local y in the Sketch's oriented frame, ties (within 1e-6 of the face size) broken by the smallest x.
Flip and rotate change which corner that is, so the client asks again ("auto") after each flip / rotate until the user picks an origin by hand.
"""

from __future__ import annotations

import math

from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepTools import breptools
from OCC.Core.GeomAbs import GeomAbs_Circle
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_VERTEX
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopoDS import TopoDS_Shape, topods
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.create_plane import oriented_anchor_basis
from app.document.extrude import resolve_subshape_from_bodies
from app.document.models import (
    CreatePlaneFeature,
    Part,
    PlaneType,
    PointRef,
    SketchFeature,
    SketchOrigin,
    SubShapeRef,
    SubShapeType,
)
from app.sketch.store import get_sketch_or_404

_FACE_TOLERANCE_REL = 1e-6
_MAX_PLANE_CHAIN = 32


def anchor_face_ref(part: Part, sketch_feature: SketchFeature) -> SubShapeRef | None:
    """The Body face `sketch_feature` ultimately sits on: its anchor Plane's face for an offset-face / parallel-to-face plane, following a Plane built on another
    Plane. None for a fixed plane and for every plane kind that has no single face (three points, midplane, normal to a line / curve / edge)."""
    plane_id = sketch_feature.plane_feature_id
    for _ in range(_MAX_PLANE_CHAIN):
        if plane_id is None:
            return None
        plane = part.get_feature(plane_id)
        if not isinstance(plane, CreatePlaneFeature):
            return None
        if plane.plane_type not in (PlaneType.OFFSET_FACE, PlaneType.PARALLEL_TO_FACE_THROUGH_VERTEX) or not plane.face_refs:
            return None
        ref = plane.face_refs[0]
        if ref.face_ref is not None:
            return ref.face_ref
        plane_id = ref.plane_feature_id  # None for a fixed plane: ends the loop above
    return None


def _outer_wire_edges(face: TopoDS_Shape) -> list[TopoDS_Shape]:
    wire = breptools.OuterWire(topods.Face(face))
    edges: list[TopoDS_Shape] = []
    seen = TopTools_IndexedMapOfShape()
    explorer = TopExp_Explorer(wire, TopAbs_EDGE)
    while explorer.More():
        edge = explorer.Current()
        if seen.Add(edge):
            edges.append(edge)
        explorer.Next()
    return edges


def _outer_wire_vertices(face: TopoDS_Shape) -> list[TopoDS_Shape]:
    wire = breptools.OuterWire(topods.Face(face))
    vertices: list[TopoDS_Shape] = []
    seen = TopTools_IndexedMapOfShape()
    explorer = TopExp_Explorer(wire, TopAbs_VERTEX)
    while explorer.More():
        vertex = explorer.Current()
        if seen.Add(vertex):
            vertices.append(vertex)
        explorer.Next()
    return vertices


def _index_in_body(body: TopoDS_Shape, shape: TopoDS_Shape, kind) -> int:
    shape_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, kind, shape_map)
    return shape_map.FindIndex(shape) - 1


def _face_size(face: TopoDS_Shape) -> float:
    box = Bnd_Box()
    brepbndlib.Add(face, box)
    xmin, ymin, zmin, xmax, ymax, zmax = box.Get()
    return math.dist((xmin, ymin, zmin), (xmax, ymax, zmax))


def bottom_left_vertex_index(
    face: TopoDS_Shape, body: TopoDS_Shape, x_axis: tuple[float, float, float], y_axis: tuple[float, float, float], origin: tuple[float, float, float]
) -> int | None:
    """The body-vertex index of the face's bottom-left corner in the frame (`origin`, `x_axis`, `y_axis`): the outer-wire vertex with the smallest local y, ties within
    1e-6 of the face size broken by the smallest local x. None when the outer wire has no vertex."""
    tolerance = _FACE_TOLERANCE_REL * max(_face_size(face), 1.0)
    best: tuple[float, float, TopoDS_Shape] | None = None
    for vertex in _outer_wire_vertices(face):
        point = BRep_Tool.Pnt(topods.Vertex(vertex))
        delta = (point.X() - origin[0], point.Y() - origin[1], point.Z() - origin[2])
        x = sum(a * b for a, b in zip(delta, x_axis))
        y = sum(a * b for a, b in zip(delta, y_axis))
        if best is None or y < best[1] - tolerance or (abs(y - best[1]) <= tolerance and x < best[0]):
            best = (x, y, vertex)
    return None if best is None else _index_in_body(body, best[2], TopAbs_VERTEX)


def auto_sketch_origin(
    part: Part,
    sketch_feature: SketchFeature,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> SketchOrigin | None:
    """The "auto" default for `sketch_feature` (see the module docstring), as a concrete `SketchOrigin` or None. Never raises for geometry it cannot make sense of: that is None
    (the plane's own origin)."""
    face_ref = anchor_face_ref(part, sketch_feature)
    if face_ref is None:
        return None
    try:
        face = resolve_subshape_from_bodies(bodies, face_ref)
        body = bodies[face_ref.body_id]
        sketch = get_sketch_or_404(sketch_feature.sketch_id)
        basis = oriented_anchor_basis(part, sketch, bodies, excluded_feature_ids)
    except Exception:  # an unresolvable face / plane: nothing to default to
        return None
    edges = _outer_wire_edges(face)
    if len(edges) == 1 and BRepAdaptor_Curve(topods.Edge(edges[0])).GetType() == GeomAbs_Circle:
        # A disc or a cylinder end: the circle's seam vertex is an accident of the model, its centre is not.
        return SketchOrigin(
            circle_centre_ref=SubShapeRef(body_id=face_ref.body_id, shape_type=SubShapeType.EDGE, index=_index_in_body(body, edges[0], TopAbs_EDGE))
        )
    index = bottom_left_vertex_index(face, body, basis.x_axis, basis.y_axis, basis.origin)
    if index is None:
        return None
    return SketchOrigin(point_ref=PointRef(vertex_ref=SubShapeRef(body_id=face_ref.body_id, shape_type=SubShapeType.VERTEX, index=index)))
