"""OCCT geometry construction for ChamferFeature (Prompt E) - mirrors
app.document.fillet exactly (see that module's own doc comment for the
circular-import reasoning this follows identically: this module needs
compute_part_bodies/resolve_subshape_from_bodies from extrude.py at module
level, so extrude.py imports this module back via a function-local import
inside compute_part_bodies instead).
"""

import math

from fastapi import HTTPException
from OCC.Core.BRepFilletAPI import BRepFilletAPI_MakeChamfer
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE
from OCC.Core.TopExp import topexp
from OCC.Core.TopoDS import TopoDS_Shape
from OCC.Core.TopTools import TopTools_IndexedDataMapOfShapeListOfShape, TopTools_IndexedMapOfShape

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import ChamferEdgeOptions, ChamferFeature, Part, SubShapeRef, SubShapeType


def _mixed_body_selection(body_ids: set[str]) -> HTTPException:
    """E: a Chamfer's `edge_refs` must all resolve to the same Body - same
    reasoning as `app.document.fillet._mixed_body_selection` (OCCT's
    `BRepFilletAPI_MakeChamfer` operates on one solid at a time)."""
    return HTTPException(
        status_code=422,
        detail={"type": "mixed_body_selection", "body_ids": sorted(body_ids)},
    )


def _chamfer_failed(body_id: str) -> HTTPException:
    """E: `BRepFilletAPI_MakeChamfer.IsDone()` returned false - a geometric
    failure (distance too large for an edge, a resulting self-intersection,
    etc.), not a malformed reference. 422, not an uncaught OCCT exception -
    same reasoning as `app.document.fillet._fillet_failed`."""
    return HTTPException(status_code=422, detail={"type": "chamfer_failed", "body_id": body_id})


def _build_chamfer(chamfer_maker: BRepFilletAPI_MakeChamfer, body_id: str) -> None:
    """Mirrors `app.document.fillet._build_fillet` exactly, substituting
    `_chamfer_failed` - see that function's own doc comment for the full
    on-device-confirmed reasoning (`BRepFilletAPI_MakeChamfer.Build()` can
    raise a raw `RuntimeError` for a genuinely unsuitable edge selection
    rather than always failing gracefully into `IsDone() == False`)."""
    try:
        chamfer_maker.Build()
    except RuntimeError as exc:
        raise _chamfer_failed(body_id) from exc


def _reference_face_not_adjacent(edge_index: int, face_ref: SubShapeRef) -> HTTPException:
    """Feature 3: an explicit `ChamferEdgeOptions.face_ref` that resolves to
    a real face of the right Body, but not one of the two faces its edge
    actually bounds - `AddDA` needs the edge to lie on the reference face.
    A referential check (only knowable after resolving), so 422 alongside
    `mixed_body_selection`/`chamfer_failed` rather than a router check."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "chamfer_face_not_adjacent",
            "edge_index": edge_index,
            "face_index": face_ref.index,
        },
    )


def _adjacent_face_indices(body: TopoDS_Shape, edge: TopoDS_Shape) -> list[int]:
    """Feature 3: the 0-based FACE indices (the same `TopTools_IndexedMapOf
    Shape` enumeration `resolve_subshape_from_bodies` uses, so each is
    directly usable as a `SubShapeRef.index`) of every face of `body`
    bounded by `edge`, deduplicated and ascending - exactly two for an
    ordinary manifold-solid edge (confirmed on-device via `topexp.
    MapShapesAndAncestors`); a seam edge (e.g. a cylinder's) lists its one
    face twice, hence the dedupe. Ascending order is what makes the default
    reference face (and therefore `flip`) deterministic."""
    edge_face_map = TopTools_IndexedDataMapOfShapeListOfShape()
    topexp.MapShapesAndAncestors(body, TopAbs_EDGE, TopAbs_FACE, edge_face_map)
    if not edge_face_map.Contains(edge):
        return []
    face_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_FACE, face_map)
    indices = {face_map.FindIndex(face) - 1 for face in edge_face_map.FindFromKey(edge)}
    return sorted(i for i in indices if i >= 0)


def _reference_face_ref(
    bodies: dict[str, TopoDS_Shape],
    body_id: str,
    edge_index: int,
    edge: TopoDS_Shape,
    opts: ChamferEdgeOptions,
) -> SubShapeRef:
    """Feature 3: the reference face `AddDA` measures `distance`/`angle`
    from for one angled edge - `opts.face_ref` if given (must be adjacent
    to `edge`), else the lower-indexed adjacent face; `opts.flip` then swaps
    to the edge's *other* adjacent face."""
    adjacent = _adjacent_face_indices(bodies[body_id], edge)
    if opts.face_ref is not None:
        if opts.face_ref.index not in adjacent:
            raise _reference_face_not_adjacent(edge_index, opts.face_ref)
        chosen = opts.face_ref.index
    elif adjacent:
        chosen = adjacent[0]
    else:
        raise _chamfer_failed(body_id)
    if opts.flip:
        others = [i for i in adjacent if i != chosen]
        if not others:
            # A seam/boundary edge with only one distinct adjacent face has
            # no "other side" to flip to.
            raise _chamfer_failed(body_id)
        chosen = others[0]
    return SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=chosen)


def resolve_chamfer_from_bodies(
    bodies: dict[str, TopoDS_Shape],
    feature: ChamferFeature,
) -> tuple[str, TopoDS_Shape]:
    """The Body id `feature` modifies and its post-chamfer shape, resolved
    against `bodies` - an already-in-progress `app.document.extrude.
    compute_part_bodies` accumulator, never a fresh recompute. Mirrors
    `app.document.fillet.resolve_fillet_from_bodies` exactly, substituting
    `BRepFilletAPI_MakeChamfer`/`distance` for `BRepFilletAPI_MakeFillet`/
    `radius` - see that function's own doc comment for the full reasoning
    (recursion-avoidance, cross-body-checked-before-resolving order, the
    router/resolver validation split) rather than repeating it here.

    Feature 3: an edge with an `edge_options` entry whose `angle` is set is
    added via `AddDA(distance, radians(angle), edge, reference_face)` instead
    (see `_reference_face_ref`); every other edge keeps the original
    symmetric `Add(distance, edge)` path unchanged. An explicit `face_ref`
    must share the edges' Body (checked with them, as one selection)."""
    body_ids = {ref.body_id for ref in feature.edge_refs} | {
        opts.face_ref.body_id for opts in feature.edge_options.values() if opts.face_ref is not None
    }
    if len(body_ids) != 1:
        raise _mixed_body_selection(body_ids)
    body_id = next(iter(body_ids))

    edges = [resolve_subshape_from_bodies(bodies, ref) for ref in feature.edge_refs]
    chamfer_maker = BRepFilletAPI_MakeChamfer(bodies[body_id])
    for i, edge in enumerate(edges):
        opts = feature.edge_options.get(i)
        if opts is None or opts.angle is None:
            chamfer_maker.Add(feature.distance, edge)
            continue
        if opts.face_ref is not None:
            resolve_subshape_from_bodies(bodies, opts.face_ref)  # missing_reference if bogus
        face = resolve_subshape_from_bodies(bodies, _reference_face_ref(bodies, body_id, i, edge, opts))
        try:
            chamfer_maker.AddDA(feature.distance, math.radians(opts.angle), edge, face)
        except RuntimeError as exc:
            raise _chamfer_failed(body_id) from exc
    _build_chamfer(chamfer_maker, body_id)
    if not chamfer_maker.IsDone():
        raise _chamfer_failed(body_id)
    return body_id, chamfer_maker.Shape()


def resolve_chamfer(
    part: Part, feature: ChamferFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[str, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.fillet.resolve_fillet` exactly, including the self-
    exclusion of `feature.id` (a Chamfer modifies a Body in place, so
    re-resolving against its own prior output would double-apply it) - see
    that function's own doc comment for the full reasoning."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_chamfer_from_bodies(bodies, feature)
