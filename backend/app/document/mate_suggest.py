"""M4 (`docs/mates-storage-sessions-plan-2026-11-12.md`, "A better first guess"): the mate type suggested by the two picks.

The rule lives here, in the backend, so the flat app and the VR client cannot drift. `preview-mate-solve` with `type: "auto"`
reads it and answers with `suggested_type` and the solve of that suggestion; a client starts its type control on it and the user
can still change it.

| first pick | second pick | suggested_type |
|---|---|---|
| round face or circular edge | round face or circular edge | `concentric` |
| circular edge (on a flat face) | circular edge (on a flat face) | `peg_in_hole`: Concentric on the two edges plus Coincident on the two flat faces they lie on, one action |
| flat face (or a plane) | flat face (or a plane) | `coincident` |
| flat face | round face or circular edge | none (Tangent is not a mate type) |
| anything else (a corner, a straight edge, a Width mid-plane, ...) | | none |

"Round face" is a cylindrical face (the only round surface a mate can use). A circular edge counts as round on its own; two circular
edges are a peg in a hole only when each lies on a flat face (the hole's rim on the plate's top, the peg's shoulder), otherwise they
are a plain Concentric. Nothing here moves anything: the suggestion is only a starting type.
"""

from __future__ import annotations

import dataclasses
import math

from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.GeomAbs import GeomAbs_Circle, GeomAbs_Cylinder, GeomAbs_Plane
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE
from OCC.Core.TopExp import topexp
from OCC.Core.TopoDS import topods
from OCC.Core.TopTools import TopTools_IndexedDataMapOfShapeListOfShape, TopTools_IndexedMapOfShape

from app.document.assembly_solver import _resolve_local_geometry, _target_part_and_transform
from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import Document, MateEntityRef, Part, SubShapeRef, SubShapeType

SUGGEST_COINCIDENT = "coincident"
SUGGEST_CONCENTRIC = "concentric"
SUGGEST_PEG_IN_HOLE = "peg_in_hole"

# What one pick is, for the rule above.
FLAT, ROUND, CIRCLE, OTHER = "flat", "round", "circle", "other"

_PARALLEL_TOL = 1e-6  # |cos| off 1 for "the face's normal is the circle's axis"
_ON_PLANE_TOL = 1e-6  # mm: the circle's centre on the face's plane


def pick_kind(document: Document, part: Part, ref: MateEntityRef) -> str:
    """`flat` (a planar face or a plane), `round` (a cylindrical face), `circle` (a circular edge) or `other` (a corner, a straight
    edge, a point, a Width mid-plane, a surface no mate can use). Raises the resolver's 4xx for a reference that does not resolve."""
    if ref.plane_ref is not None:
        return FLAT
    if ref.subshape_ref is None:
        return OTHER
    shape = _resolve(document, part, ref)
    if ref.subshape_ref.shape_type == SubShapeType.FACE:
        surface = BRepAdaptor_Surface(topods.Face(shape), True).GetType()
        return FLAT if surface == GeomAbs_Plane else (ROUND if surface == GeomAbs_Cylinder else OTHER)
    if ref.subshape_ref.shape_type == SubShapeType.EDGE:
        return CIRCLE if BRepAdaptor_Curve(topods.Edge(shape)).GetType() == GeomAbs_Circle else OTHER
    return OTHER


def suggest_type(first: str, second: str, peg_faces_found: bool = False) -> str | None:
    """The table in the module docstring, on two pick kinds. `peg_faces_found`: both circular edges lie on a flat face."""
    kinds = {first, second}
    if first == CIRCLE and second == CIRCLE:
        return SUGGEST_PEG_IN_HOLE if peg_faces_found else SUGGEST_CONCENTRIC
    if kinds <= {ROUND, CIRCLE}:
        return SUGGEST_CONCENTRIC
    if kinds == {FLAT}:
        return SUGGEST_COINCIDENT
    return None


def suggest_mate_type(document: Document, part: Part, references: list[MateEntityRef]) -> str | None:
    """The suggested type for the two picks (None = no suggestion). Raises the resolver's 4xx for a reference that does not resolve."""
    first, second = (pick_kind(document, part, ref) for ref in references)
    peg = first == CIRCLE and second == CIRCLE and peg_in_hole_faces(document, part, references) is not None
    return suggest_type(first, second, peg)


def peg_in_hole_faces(document: Document, part: Part, references: list[MateEntityRef]) -> tuple[MateEntityRef, MateEntityRef] | None:
    """The two flat faces a peg-in-hole's Coincident joins: for each circular edge, the planar face it bounds whose plane holds the
    circle (normal along the circle's axis, the centre on the plane). None when either edge has no such face (or is not circular)."""
    faces = []
    for ref in references:
        if ref.subshape_ref is None or ref.subshape_ref.shape_type != SubShapeType.EDGE:
            return None
        found = _flat_face_of_circle(document, part, ref)
        if found is None:
            return None
        faces.append(found)
    return faces[0], faces[1]


def _resolve(document: Document, part: Part, ref: MateEntityRef):
    target, _transform = _target_part_and_transform(document, part, ref.occurrence_id)
    return resolve_subshape_from_bodies(compute_part_bodies(target), ref.subshape_ref)


def _flat_face_of_circle(document: Document, part: Part, ref: MateEntityRef) -> MateEntityRef | None:
    target, _transform = _target_part_and_transform(document, part, ref.occurrence_id)
    bodies = compute_part_bodies(target)
    body = bodies.get(ref.subshape_ref.body_id)
    if body is None:
        return None
    edge = topods.Edge(resolve_subshape_from_bodies(bodies, ref.subshape_ref))
    curve = BRepAdaptor_Curve(edge)
    if curve.GetType() != GeomAbs_Circle:
        return None
    circle = curve.Circle()
    axis, centre = circle.Axis().Direction(), circle.Location()
    ancestors = TopTools_IndexedDataMapOfShapeListOfShape()
    topexp.MapShapesAndAncestors(body, TopAbs_EDGE, TopAbs_FACE, ancestors)
    if not ancestors.Contains(edge):
        return None
    face_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_FACE, face_map)
    for ancestor in ancestors.FindFromKey(edge):
        face = topods.Face(ancestor)
        surface = BRepAdaptor_Surface(face, True)
        if surface.GetType() != GeomAbs_Plane:
            continue
        plane = surface.Plane()
        normal = plane.Axis().Direction()
        if abs(abs(normal.Dot(axis)) - 1.0) > _PARALLEL_TOL or abs(plane.Distance(centre)) > _ON_PLANE_TOL:
            continue
        index = face_map.FindIndex(face) - 1
        if index < 0:
            continue
        return dataclasses.replace(ref, subshape_ref=SubShapeRef(body_id=ref.subshape_ref.body_id, shape_type=SubShapeType.FACE, index=index))
    return None


def peg_concentric_alignment(document: Document, part: Part, references: list[MateEntityRef], faces: tuple[MateEntityRef, MateEntityRef]) -> str | None:
    """The Concentric's alignment that agrees with the Coincident of a peg in a hole: the two flat faces touch (anti-aligned normals,
    the Coincident's default), so with each circle's axis along (+1) or against (-1) its own face's outward normal, the two axes are
    aligned when those signs differ and anti-aligned when they agree. Read from the same resolved geometry the solver uses. None when it
    cannot be worked out (the Concentric is then left to Closest)."""
    signs = []
    for edge_ref, face_ref in zip(references, faces):
        target, _transform = _target_part_and_transform(document, part, edge_ref.occurrence_id)
        bodies = compute_part_bodies(target)
        axis = _resolve_local_geometry(target, bodies, edge_ref, document, part).direction
        plane = _resolve_local_geometry(target, bodies, face_ref, document, part).plane
        if axis is None or plane is None:
            return None
        dot = sum(a * n for a, n in zip(axis, plane.normal))
        if not math.isfinite(dot) or abs(dot) < 0.5:
            return None
        signs.append(1 if dot > 0 else -1)
    # n_a = -n_b (touching faces) and axis_i = s_i n_i, so axis_a . axis_b = -s_a s_b
    return "aligned" if -signs[0] * signs[1] > 0 else "anti_aligned"


def suggestion_or_none(document: Document, part: Part, references: list[MateEntityRef]) -> str | None:
    """`suggest_mate_type`, with a reference that does not resolve read as "no suggestion" (the preview is tolerant mid-pick)."""
    try:
        return suggest_mate_type(document, part, references)
    except HTTPException:
        return None
