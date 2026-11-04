"""AI Modelling workstream 3/5: deterministic edge-selector heuristics for
Fillet/Chamfer plan steps - resolves an `EdgeSelector`
(`app.document.ai_plan_schemas`) against the real, already-computed
topology of a Body, never against a second LLM call (see
docs/ai-modelling/03-structured-plan-schema.md's own "Open design
problem: edge selection for Fillet/Chamfer" section, resolved here in
favour of option (b)).

v1 limitation, stated explicitly since it's real: every selector is
relative to the *global* X/Y/Z axes, never a Sketch's own local plane
normal or a Body's own "which way was this actually extruded" direction -
correct for the common case this v1 scope is built around (an XY-plane
Sketch extruded along Z, "top"/"bottom"/"vertical" all matching intuition
directly), not a fully general resolver. A Body extruded along a tilted
custom plane will get selector results relative to world Z, which may not
match what "top face" intuitively means for that Body - a known,
deliberately out-of-scope gap for v1, not a bug.

Indices in every returned `SubShapeRef` use the same "undeduplicated,
0-based, topexp.MapShapes(body, TopAbs_EDGE, ...)" scheme
`app.document.extrude.resolve_subshape_from_bodies` already uses -
*not* `app.document.mesh`'s own dense (degenerate-edges-skip-an-id)
scheme, which can disagree with this one for a Body that happens to have
a degenerate edge.

Workstream 12 (docs/ai-modelling/12-provenance-edge-selectors.md) added
two more selectors, `EDGE_FROM_SKETCH_POINT`/`EDGE_FROM_SKETCH_LINE` -
unlike the four heuristics above, these resolve a *specific single* edge
by sketch-entity lineage (`app.document.extrude`'s `_feature_edge_
provenance_cache`, populated as a side effect of that Feature's own real
construction), not a geometric guess over the finished Body. See that
module's own docstring for the full mechanism and its real, disclosed
limits (only Extrude/Revolve/Sweep; only a single-profile Boss with no
target_body_ids; never an edge a *prior* Fillet/Chamfer created).
"""

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.GeomAbs import GeomAbs_Line, GeomAbs_Plane
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_REVERSED
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopoDS import TopoDS_Shape, TopoDS_Vertex, topods
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.ai_plan_schemas import CardinalDirection, EdgeSelectorKind
from app.document.face_normal import plane_axis_points_inward
from app.document.extrude import cached_feature_edge_provenance, edge_vertex_key_set
from app.document.models import Part, SubShapeRef, SubShapeType

# ~2.6 degrees off pure alignment - tight enough to reject a merely-close
# face/edge on a chamfered or lightly-angled body, loose enough to absorb
# ordinary floating-point noise from OCCT's own construction.
_ALIGNMENT_COS_TOLERANCE = 0.999

_DIRECTION_VECTORS: dict[str, tuple[float, float, float]] = {
    "+x": (1.0, 0.0, 0.0),
    "-x": (-1.0, 0.0, 0.0),
    "+y": (0.0, 1.0, 0.0),
    "-y": (0.0, -1.0, 0.0),
    "+z": (0.0, 0.0, 1.0),
    "-z": (0.0, 0.0, -1.0),
}

_FIXED_FACE_DIRECTION: dict[EdgeSelectorKind, str] = {
    EdgeSelectorKind.TOP_FACE_EDGES: "+z",
    EdgeSelectorKind.BOTTOM_FACE_EDGES: "-z",
}


def _dot(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _missing_direction(body_id: str, selector: EdgeSelectorKind) -> HTTPException:
    return HTTPException(
        status_code=422,
        detail={
            "type": "edge_selector_missing_direction",
            "body_id": body_id,
            "selector": selector.value,
        },
    )


def _no_matching_face(body_id: str, direction: str) -> HTTPException:
    return HTTPException(
        status_code=422,
        detail={"type": "edge_selector_no_matching_face", "body_id": body_id, "direction": direction},
    )


def _no_matching_edges(body_id: str, selector: EdgeSelectorKind) -> HTTPException:
    return HTTPException(
        status_code=422,
        detail={"type": "edge_selector_no_matching_edges", "body_id": body_id, "selector": selector.value},
    )


def _face_outward_normal(face) -> tuple[float, float, float] | None:
    """The face's real outward unit normal, or None if it isn't planar (a
    curved face has no single normal - not a candidate for any of v1's
    face-position selectors). Its sign comes from `face_normal`, not from the
    face's orientation flag alone (see that module)."""
    surface = BRepAdaptor_Surface(face, True)
    if surface.GetType() != GeomAbs_Plane:
        return None
    axis = surface.Plane().Axis().Direction()
    normal = (axis.X(), axis.Y(), axis.Z())
    if plane_axis_points_inward(face):
        normal = (-normal[0], -normal[1], -normal[2])
    return normal


def _find_face_for_direction(body: TopoDS_Shape, body_id: str, direction: str):
    target = _DIRECTION_VECTORS[direction]
    best_face = None
    best_dot = _ALIGNMENT_COS_TOLERANCE
    explorer = TopExp_Explorer(body, TopAbs_FACE)
    while explorer.More():
        face = topods.Face(explorer.Current())
        normal = _face_outward_normal(face)
        if normal is not None:
            alignment = _dot(normal, target)
            if alignment > best_dot:
                best_dot = alignment
                best_face = face
        explorer.Next()
    if best_face is None:
        raise _no_matching_face(body_id, direction)
    return best_face


def _edge_refs_of_face(body_id: str, face, edge_map: TopTools_IndexedMapOfShape) -> list[SubShapeRef]:
    refs: list[SubShapeRef] = []
    seen: set[int] = set()
    explorer = TopExp_Explorer(face, TopAbs_EDGE)
    while explorer.More():
        edge = topods.Edge(explorer.Current())
        if not BRep_Tool.Degenerated(edge):
            index = edge_map.FindIndex(edge)
            if index > 0 and index not in seen:
                seen.add(index)
                refs.append(SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=index - 1))
        explorer.Next()
    return refs


def _vertical_edge_refs(body_id: str, edge_map: TopTools_IndexedMapOfShape) -> list[SubShapeRef]:
    refs: list[SubShapeRef] = []
    for i in range(1, edge_map.Size() + 1):
        edge = topods.Edge(edge_map.FindKey(i))
        if BRep_Tool.Degenerated(edge):
            continue
        # Only a straight edge can be "vertical" in the plain sense v1
        # means - a curved edge (e.g. a filleted vertical corner) is
        # skipped rather than guessed at.
        if BRepAdaptor_Curve(edge).GetType() != GeomAbs_Line:
            continue
        v1, v2 = TopoDS_Vertex(), TopoDS_Vertex()
        topexp.Vertices(edge, v1, v2)
        p1, p2 = BRep_Tool.Pnt(v1), BRep_Tool.Pnt(v2)
        dx, dy, dz = p2.X() - p1.X(), p2.Y() - p1.Y(), p2.Z() - p1.Z()
        length = (dx * dx + dy * dy + dz * dz) ** 0.5
        if length == 0:
            continue
        if abs(dz) / length > _ALIGNMENT_COS_TOLERANCE:
            refs.append(SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=i - 1))
    return refs


_PROVENANCE_SELECTOR_KINDS = frozenset(
    {EdgeSelectorKind.EDGE_FROM_SKETCH_POINT, EdgeSelectorKind.EDGE_FROM_SKETCH_LINE}
)


def _resolve_provenance_selector(
    body: TopoDS_Shape,
    part: Part,
    feature_id: str,
    body_id: str,
    selector: EdgeSelectorKind,
    provenance_key: str,
    sketch_entity_id: str,
) -> list[SubShapeRef]:
    """Workstream 12: looks `sketch_entity_id` up in `feature_id`'s own
    cached edge-provenance (`app.document.extrude.cached_feature_edge_
    provenance`) under `provenance_key` ("points"/"lines_near"/
    "lines_far"). Fails closed with the same `edge_selector_no_matching_
    edges` the four heuristics already use (never a silent empty selection)
    whenever the provenance cache has nothing for this Feature at all (no
    matching profile shape when it last ran, a MultiProfile/fused/cut/
    target_body_ids-non-empty case, or - the one guaranteed-permanent case,
    not just a v1 gap - `feature_id` names a Fillet/Chamfer, whose own
    edges have no sketch lineage at all to trace back to), has nothing for
    this specific sketch entity (e.g. a full-360 Revolve's own disclosed
    radial-edge gap for `lines_far`), or (below) the cached entry's own
    coordinate anchor no longer matches any edge of `body`.

    Bug fix (on-device feedback, "fillets consistently failing to find
    their target edges"): the cached entry's own index is only valid
    against the *pristine* shape `feature_id`'s Extrude/Revolve/Sweep
    construction produced - never against `body`, whenever `body` is the
    result of a *prior* Fillet/Chamfer step already having modified that
    same Body (the common "several fillets on one boss" case a real plan
    routinely produces). An on-device spike confirmed `topexp.MapShapes`'
    own edge-index ordering is not preserved by a Fillet/Chamfer's boolean
    rebuild, even for an edge the rebuild never touched - so this always
    re-locates the edge inside `body`'s own current topology by real-world
    coordinate (`app.document.extrude.edge_vertex_key_set`, stable across
    that rebuild for any edge it didn't itself touch), checking the cached
    index first as a cheap fast path (valid, and by far the common case,
    whenever `body` still *is* the pristine shape - the first Fillet/
    Chamfer step against a given Body, or any provenance selector used
    against a fresh Extrude/Revolve/Sweep result directly) before falling
    back to a full scan. Never returns the cached index un-checked."""
    provenance = cached_feature_edge_provenance(part, feature_id)
    entry = None if provenance is None else provenance.get(provenance_key, {}).get(sketch_entity_id)
    if entry is None:
        raise _no_matching_edges(body_id, selector)
    cached_index, anchor = entry

    edge_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_EDGE, edge_map)

    if 0 <= cached_index < edge_map.Size():
        candidate = topods.Edge(edge_map.FindKey(cached_index + 1))
        if edge_vertex_key_set(candidate) == anchor:
            return [SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=cached_index)]

    for i in range(1, edge_map.Size() + 1):
        candidate = topods.Edge(edge_map.FindKey(i))
        if edge_vertex_key_set(candidate) == anchor:
            return [SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=i - 1)]

    raise _no_matching_edges(body_id, selector)


def resolve_face_selector(body: TopoDS_Shape, body_id: str, direction: CardinalDirection) -> SubShapeRef:
    """The single FACE `SubShapeRef` (indexed the same undeduplicated 0-based
    `topexp.MapShapes(body, TopAbs_FACE, ...)` scheme `resolve_subshape_
    from_bodies` already reads a FACE ref with) a `shell` plan step's own
    `faces_to_remove` entry names against `body`'s real current topology -
    the exact same "which face has this outward normal" heuristic
    `all_edges_of_face_at_position` already uses internally
    (`_find_face_for_direction`), reused here to name the face itself
    rather than its edges. Raises the same structured 422
    `edge_selector_no_matching_face` `_find_face_for_direction` already
    raises for "no planar face aligns with this direction" - reused as-is
    rather than inventing a Shell-specific error shape for the same
    underlying condition."""
    face = _find_face_for_direction(body, body_id, direction.value)
    face_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_FACE, face_map)
    index = face_map.FindIndex(face)
    return SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=index - 1)


def resolve_mate_face_selector(
    body: TopoDS_Shape,
    body_id: str,
    *,
    direction: CardinalDirection | None = None,
    cylinder_radius: float | None = None,
    near: tuple[float, float, float] | None = None,
    normal: tuple[float, float, float] | None = None,
) -> SubShapeRef:
    """The one FACE a mate reference's `face_selector` names on `body`, in that Body's own (Part-local) frame:
    a planar face whose outward normal is `direction`, or a cylindrical face of `cylinder_radius`. Of several
    candidates, the one nearest `near`, or without `near` the outermost along `direction` (for a cylinder
    without `near`, several distinct candidates are ambiguous: 422). Indexed like `resolve_face_selector`."""
    from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeVertex
    from OCC.Core.BRepExtrema import BRepExtrema_DistShapeShape
    from OCC.Core.BRepGProp import brepgprop
    from OCC.Core.GeomAbs import GeomAbs_Cylinder
    from OCC.Core.GProp import GProp_GProps
    from OCC.Core.gp import gp_Pnt

    target = None
    if direction is not None:
        target = _DIRECTION_VECTORS[direction.value]
    elif normal is not None:
        length = sum(c * c for c in normal) ** 0.5
        target = tuple(c / length for c in normal)
    face_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_FACE, face_map)
    candidates = []
    for i in range(1, face_map.Size() + 1):
        face = topods.Face(face_map.FindKey(i))
        if target is not None:
            face_normal = _face_outward_normal(face)
            if face_normal is not None and _dot(face_normal, target) > _ALIGNMENT_COS_TOLERANCE:
                candidates.append((i, face))
        else:
            surface = BRepAdaptor_Surface(face, True)
            if surface.GetType() == GeomAbs_Cylinder and abs(surface.Cylinder().Radius() - cylinder_radius) < 1e-3:
                candidates.append((i, face))
    wanted = (
        f"direction {direction.value}" if direction is not None
        else f"normal {list(normal)}" if normal is not None
        else f"cylinder radius {cylinder_radius}"
    )
    if not candidates:
        raise HTTPException(
            status_code=422,
            detail={"type": "face_selector_no_matching_face", "body_id": body_id, "selector": wanted},
        )

    def centre(face) -> tuple[float, float, float]:
        props = GProp_GProps()
        brepgprop.SurfaceProperties(face, props)
        c = props.CentreOfMass()
        return (c.X(), c.Y(), c.Z())

    if near is not None:
        vertex = BRepBuilderAPI_MakeVertex(gp_Pnt(*near)).Vertex()
        index, _ = min(candidates, key=lambda c: BRepExtrema_DistShapeShape(vertex, c[1]).Value())
    elif target is not None:
        index, _ = max(candidates, key=lambda c: _dot(centre(c[1]), target))
    else:
        axes = set()
        for _, face in candidates:
            axis = BRepAdaptor_Surface(face, True).Cylinder().Axis()
            loc, d = axis.Location(), axis.Direction()
            # one cylinder split into several faces shares its axis line: key it by direction and the point on it
            # nearest the origin
            t = loc.X() * d.X() + loc.Y() * d.Y() + loc.Z() * d.Z()
            p = (loc.X() - t * d.X(), loc.Y() - t * d.Y(), loc.Z() - t * d.Z())
            axes.add(tuple(round(v, 3) for v in (*p, abs(d.X()), abs(d.Y()), abs(d.Z()))))
        if len(axes) > 1:
            raise HTTPException(
                status_code=422,
                detail={
                    "type": "face_selector_ambiguous",
                    "body_id": body_id,
                    "selector": wanted,
                    "message": f"{len(axes)} separate faces match {wanted}; add 'near' to say which",
                },
            )
        index = candidates[0][0]
    return SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=index - 1)


def resolve_edge_selector(
    body: TopoDS_Shape,
    body_id: str,
    selector: EdgeSelectorKind,
    direction: CardinalDirection | None,
    *,
    part: Part | None = None,
    feature_id: str | None = None,
    sketch_point_id: str | None = None,
    sketch_line_id: str | None = None,
    far: bool = False,
) -> list[SubShapeRef]:
    """The `SubShapeRef`s (EDGE, indexed the same way `resolve_subshape_
    from_bodies` reads them) a `fillet`/`chamfer` plan step's `edges`
    selector names against `body`'s real current topology. Raises a
    structured 422 `HTTPException` (never returns an empty list silently)
    for "no matching face", "no matching edges", and "selector needs a
    direction but none was given".

    `part`/`feature_id`/`sketch_point_id`/`sketch_line_id`/`far` are only
    used by the two Workstream 12 provenance selectors (`EDGE_FROM_SKETCH_
    POINT`/`EDGE_FROM_SKETCH_LINE`) - `part`/`feature_id` must both be
    given for either (the caller's own job to supply, per `EdgeSelector.of`
    resolving to a real Feature id), and `sketch_point_id`/`sketch_line_id`
    is the already-resolved *real* sketch entity id the corresponding
    `EdgeSelector.sketch_point_ref`/`sketch_line_ref` plan-local_id
    resolved to (never the plan-local_id itself - that resolution is the
    caller's job, exactly like every other plan-local_id in this schema)."""
    if selector in _PROVENANCE_SELECTOR_KINDS:
        assert part is not None and feature_id is not None
        if selector == EdgeSelectorKind.EDGE_FROM_SKETCH_POINT:
            assert sketch_point_id is not None
            return _resolve_provenance_selector(body, part, feature_id, body_id, selector, "points", sketch_point_id)
        assert sketch_line_id is not None
        provenance_key = "lines_far" if far else "lines_near"
        return _resolve_provenance_selector(body, part, feature_id, body_id, selector, provenance_key, sketch_line_id)

    edge_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_EDGE, edge_map)

    if selector == EdgeSelectorKind.VERTICAL_EDGES:
        refs = _vertical_edge_refs(body_id, edge_map)
        if not refs:
            raise _no_matching_edges(body_id, selector)
        return refs

    face_direction = _FIXED_FACE_DIRECTION.get(selector)
    if face_direction is None:
        if direction is None:
            raise _missing_direction(body_id, selector)
        face_direction = direction.value

    face = _find_face_for_direction(body, body_id, face_direction)
    refs = _edge_refs_of_face(body_id, face, edge_map)
    if not refs:
        raise _no_matching_edges(body_id, selector)
    return refs
