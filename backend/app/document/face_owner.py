"""Which Feature made a face (bug report 2026-11-17 item 2A): what the Pattern / Mirror tools add to their scope when the user picks a
face on the Feature tab - a cut's side wall gives the cut, a boss's face the boss.

Rule. Take the Features that act on the face's Body, latest first: every Extrude / Revolve / Sweep / Loft that qualifies as a tool
Feature (`tool_feature_qualifies`: a cut, or a boss into a target) and targets that Body, and every Pattern / Mirror that repeats tool
Features into it. For each, take the tool shape it applied, resolved against the Part as it stood just before that Feature ran
(`resolve_feature_tool_shape_as_it_ran`; for a Pattern / Mirror, its instances). The face belongs to the first Feature whose tool
shape's bounded FACES carry every sample point of the face. Bounded faces, not their surfaces: a hole cut from a block's top face has a
cap coplanar with that face, but the cap covers only the hole, so the rest of the top face is not the cut's. No match: the Feature that
made the Body (`base_feature_id` of the Body id). Hidden Features and the ones the client has rolled back are skipped.
"""

from __future__ import annotations

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeVertex
from OCC.Core.BRepClass import BRepClass_FaceClassifier
from OCC.Core.BRepExtrema import BRepExtrema_DistShapeShape
from OCC.Core.BRepTools import breptools
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.gp import gp_Pnt, gp_Pnt2d
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_IN
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Face, TopoDS_Shape, topods

from app.document.extrude import compute_part_bodies, resolve_feature_tool_shape_as_it_ran, resolve_subshape_from_bodies
from app.document.graph import base_feature_id, excluded_feature_ids_after, tool_feature_qualifies
from app.document.models import MirrorFeature, Part, PatternFeature, SubShapeRef, SubShapeType

# How many points of the picked face are checked, and the grid they are picked from (UV space, kept only where inside the face).
_SAMPLES = 5
_GRID = 9


def _bad_face(ref: SubShapeRef) -> HTTPException:
    return HTTPException(
        status_code=422,
        detail={"type": "missing_reference", "body_id": ref.body_id, "shape_type": ref.shape_type.value, "index": ref.index},
    )


def _sample_points(face: TopoDS_Face) -> list[gp_Pnt]:
    """Up to `_SAMPLES` points spread over the face (inside its boundary, holes excluded)."""
    u_min, u_max, v_min, v_max = breptools.UVBounds(face)
    surface = BRepAdaptor_Surface(face)
    inside: list[gp_Pnt] = []
    for i in range(_GRID):
        for j in range(_GRID):
            u = u_min + (u_max - u_min) * (i + 0.5) / _GRID
            v = v_min + (v_max - v_min) * (j + 0.5) / _GRID
            classifier = BRepClass_FaceClassifier(face, gp_Pnt2d(u, v), 1e-9)
            if classifier.State() == TopAbs_IN:
                inside.append(surface.Value(u, v))
    if len(inside) <= _SAMPLES:
        return inside
    step = len(inside) / _SAMPLES
    return [inside[int(k * step)] for k in range(_SAMPLES)]


def _faces_compound(shape: TopoDS_Shape) -> TopoDS_Compound:
    """The shape's faces only, so a distance is to its boundary (a distance to a solid is 0 anywhere inside it)."""
    compound = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(compound)
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while explorer.More():
        builder.Add(compound, explorer.Current())
        explorer.Next()
    return compound


def _size(shape: TopoDS_Shape) -> float:
    box = Bnd_Box()
    brepbndlib.Add(shape, box)
    if box.IsVoid():
        return 1.0
    x0, y0, z0, x1, y1, z1 = box.Get()
    return max(((x1 - x0) ** 2 + (y1 - y0) ** 2 + (z1 - z0) ** 2) ** 0.5, 1e-9)


def _all_on(points: list[gp_Pnt], tool_faces: TopoDS_Compound, tolerance: float) -> bool:
    for point in points:
        distance = BRepExtrema_DistShapeShape(BRepBuilderAPI_MakeVertex(point).Vertex(), tool_faces)
        if not distance.IsDone() or distance.Value() > tolerance:
            return False
    return True


def _candidate_tools(part: Part, body_id: str, skipped: frozenset[str]) -> list[tuple[str, list[TopoDS_Shape]]]:
    """(Feature id, its tool shapes) for every Feature acting on `body_id` as a tool, latest first. A Feature whose tool cannot be
    resolved (an error further up its own history) is left out rather than failing the whole question."""
    candidates: list[tuple[str, list[TopoDS_Shape]]] = []
    for feature in reversed(part.features):
        if feature.id in skipped:
            continue
        try:
            if tool_feature_qualifies(feature):
                result = resolve_feature_tool_shape_as_it_ran(part, feature.id, skipped)
                if result is not None and body_id in result[1]:
                    candidates.append((feature.id, [result[0]]))
            elif isinstance(feature, PatternFeature) and feature.all_tool_feature_ids:
                from app.document.pattern import resolve_pattern_coarse

                tool_ids = feature.all_tool_feature_ids
                targets = resolve_feature_tool_shape_as_it_ran(part, tool_ids[0], skipped)
                if targets is not None and body_id in targets[1]:
                    excluded = skipped | excluded_feature_ids_after(part, feature.id)
                    candidates.append((feature.id, [resolve_pattern_coarse(part, feature, excluded)]))
            elif isinstance(feature, MirrorFeature) and feature.tool_feature_id is not None:
                from app.document.mirror import mirrored_tool_feature_shapes

                excluded = skipped | {feature.id} | excluded_feature_ids_after(part, feature.id)
                bodies = compute_part_bodies(part, excluded)
                target_id, tools = mirrored_tool_feature_shapes(part, bodies, feature, excluded)
                if target_id == body_id:
                    candidates.append((feature.id, [shape for shape, _is_cut in tools]))
        except HTTPException:
            continue
    return candidates


def face_owner_feature_ids(
    part: Part, faces: list[SubShapeRef], rollback_excluded_feature_ids: frozenset[str] = frozenset()
) -> list[str]:
    """The Feature that made each face, in order (see the module docstring). 422 `missing_reference` for a ref that is not a face of a
    current Body."""
    skipped = frozenset(rollback_excluded_feature_ids) | frozenset(part.hidden_feature_ids)
    bodies = compute_part_bodies(part, frozenset(rollback_excluded_feature_ids))
    candidates_by_body: dict[str, list[tuple[str, list[TopoDS_Compound]]]] = {}
    owners: list[str] = []
    for ref in faces:
        if ref.shape_type != SubShapeType.FACE or ref.body_id not in bodies:
            raise _bad_face(ref)
        try:
            face = topods.Face(resolve_subshape_from_bodies(bodies, ref))
        except HTTPException:
            raise _bad_face(ref) from None
        if ref.body_id not in candidates_by_body:
            candidates_by_body[ref.body_id] = [
                (feature_id, [_faces_compound(shape) for shape in shapes])
                for feature_id, shapes in _candidate_tools(part, ref.body_id, skipped)
            ]
        points = _sample_points(face)
        tolerance = 1e-6 * _size(bodies[ref.body_id])
        owner = base_feature_id(ref.body_id)
        if points:
            for feature_id, tool_faces in candidates_by_body[ref.body_id]:
                if any(_all_on(points, faces_of_tool, tolerance) for faces_of_tool in tool_faces):
                    owner = feature_id
                    break
        owners.append(owner)
    return owners
