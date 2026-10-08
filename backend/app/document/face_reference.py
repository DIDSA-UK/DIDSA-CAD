"""DIDSA-VR plan, phase 2.2: what a FACE of the part gives a sketch to point at, without any new solver machinery.

* A flat face standing PERPENDICULAR to the sketch plane is a line edge-on: its two extreme corners (the pair of the face's vertices that lie furthest apart once projected
  into the sketch) are ordinary vertex references and the line between them is pinned like a converted straight edge.
* A round face (cylinder / cone / torus) whose axis is perpendicular to the sketch plane is a live centre: a hole's wall seen from above, even a blind hole whose rim is
  not in the sketch plane. The centre is a `kind="circle_centre"` reference of one of the face's own circular edges whose axis is that axis, so it follows and is flagged
  exactly like a converted hole's centre, with no new reference type.

Everything here is geometry: it reads the Body and the sketch's basis and returns indices and sketch-local coordinates; `router.convert_body_face` makes the Sketch entities."""

from __future__ import annotations

import math
from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_VERTEX
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopoDS import TopoDS_Shape, topods
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.models import SubShapeRef, SubShapeType
from app.document.plane_geometry import ResolvedPlane, world_point_to_basis
from app.document.reference_signature import measurer_for

PERPENDICULAR_TOLERANCE_DEGREES = 1.0
_ROUND_KINDS = ("cylinder", "cone", "torus")


@dataclass(frozen=True)
class FaceLine:
    """A perpendicular flat face: the body vertex indices at its two extremes, and where they project in the sketch."""

    start_vertex: int
    end_vertex: int
    start_xy: tuple[float, float]
    end_xy: tuple[float, float]


@dataclass(frozen=True)
class FaceAxis:
    """A round face with its axis perpendicular to the sketch: the circular edge (body edge index) whose centre stands for the axis, and the axis point in the sketch."""

    edge_index: int
    xy: tuple[float, float]


def _unprocessable(kind: str, body_id: str, index: int) -> HTTPException:
    return HTTPException(status_code=422, detail={"type": kind, "body_id": body_id, "index": index})


def _dot(a, b) -> float:
    return sum(x * y for x, y in zip(a, b))


def _face_shape(bodies: dict[str, TopoDS_Shape], body_id: str, face_index: int) -> TopoDS_Shape:
    from app.document.extrude import resolve_subshape_from_bodies

    return resolve_subshape_from_bodies(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=face_index))


def _unique_indices(face: TopoDS_Shape, kind, map_of: TopTools_IndexedMapOfShape) -> list[int]:
    seen: dict[int, None] = {}
    explorer = TopExp_Explorer(face, kind)
    while explorer.More():
        seen[map_of.FindIndex(explorer.Current()) - 1] = None
        explorer.Next()
    return sorted(seen)


def classify_face(bodies: dict[str, TopoDS_Shape], body_id: str, face_index: int, basis: ResolvedPlane) -> str:
    """"line" (a flat face standing perpendicular to the sketch plane), "centre" (a round face whose axis is perpendicular to it), or raises `unsupported_face` (422)."""
    _face_shape(bodies, body_id, face_index)
    signature = measurer_for(bodies[body_id], "face").signature(face_index)
    alignment = abs(_dot(signature.direction, basis.normal))
    if signature.surface_kind == "plane":
        if alignment <= math.sin(math.radians(PERPENDICULAR_TOLERANCE_DEGREES)):
            return "line"
        raise _unprocessable("face_not_perpendicular", body_id, face_index)
    if signature.surface_kind in _ROUND_KINDS:
        if alignment >= math.cos(math.radians(PERPENDICULAR_TOLERANCE_DEGREES)):
            return "centre"
        raise _unprocessable("face_axis_not_perpendicular", body_id, face_index)
    raise _unprocessable("unsupported_face", body_id, face_index)


def face_line(bodies: dict[str, TopoDS_Shape], body_id: str, face_index: int, basis: ResolvedPlane) -> FaceLine:
    body = bodies[body_id]
    face = _face_shape(bodies, body_id, face_index)
    vertices = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_VERTEX, vertices)
    measurer = measurer_for(body, "vertex")
    projected: list[tuple[int, tuple[float, float]]] = []
    for index in _unique_indices(face, TopAbs_VERTEX, vertices):
        projected.append((index, world_point_to_basis(basis, measurer.signature(index).position)))
    best: tuple[float, int, int] | None = None
    for i, (index_a, a) in enumerate(projected):
        for index_b, b in projected[i + 1 :]:
            distance = math.dist(a, b)
            if best is None or distance > best[0]:
                best = (distance, index_a, index_b)
    if best is None or best[0] < 1e-6:
        raise _unprocessable("degenerate_face", body_id, face_index)
    by_index = dict(projected)
    return FaceLine(best[1], best[2], by_index[best[1]], by_index[best[2]])


def face_axis(bodies: dict[str, TopoDS_Shape], body_id: str, face_index: int, basis: ResolvedPlane) -> FaceAxis:
    body = bodies[body_id]
    face = _face_shape(bodies, body_id, face_index)
    edges = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_EDGE, edges)
    measurer = measurer_for(body, "edge")
    for index in _unique_indices(face, TopAbs_EDGE, edges):
        signature = measurer.signature(index)
        if signature.curve_kind == "circle" and abs(_dot(signature.direction, basis.normal)) >= math.cos(math.radians(PERPENDICULAR_TOLERANCE_DEGREES)):
            return FaceAxis(index, world_point_to_basis(basis, signature.centre))
    raise _unprocessable("face_has_no_circular_edge", body_id, face_index)
