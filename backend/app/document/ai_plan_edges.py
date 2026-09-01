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
from app.document.extrude import cached_feature_edge_provenance
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
    face-position selectors)."""
    surface = BRepAdaptor_Surface(face, True)
    if surface.GetType() != GeomAbs_Plane:
        return None
    axis = surface.Plane().Axis().Direction()
    normal = (axis.X(), axis.Y(), axis.Z())
    if face.Orientation() == TopAbs_REVERSED:
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
    "lines_far") - a plain dict lookup, never a geometric guess. Fails
    closed with the same `edge_selector_no_matching_edges` the four
    heuristics already use (never a silent empty selection) whenever the
    provenance cache has nothing for this Feature at all (no matching
    profile shape when it last ran, a MultiProfile/fused/cut/
    target_body_ids-non-empty case, or - the one guaranteed-permanent case,
    not just a v1 gap - `feature_id` names a Fillet/Chamfer, whose own
    edges have no sketch lineage at all to trace back to) or has nothing
    for this specific sketch entity (e.g. a full-360 Revolve's own
    disclosed radial-edge gap for `lines_far`)."""
    provenance = cached_feature_edge_provenance(part, feature_id)
    index = None if provenance is None else provenance.get(provenance_key, {}).get(sketch_entity_id)
    if index is None:
        raise _no_matching_edges(body_id, selector)
    return [SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=index)]


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
            return _resolve_provenance_selector(part, feature_id, body_id, selector, "points", sketch_point_id)
        assert sketch_line_id is not None
        provenance_key = "lines_far" if far else "lines_near"
        return _resolve_provenance_selector(part, feature_id, body_id, selector, provenance_key, sketch_line_id)

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
