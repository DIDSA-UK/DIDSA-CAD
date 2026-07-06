"""OCCT geometry construction for ChamferFeature (Prompt E) - mirrors
app.document.fillet exactly (see that module's own doc comment for the
circular-import reasoning this follows identically: this module needs
compute_part_bodies/resolve_subshape_from_bodies from extrude.py at module
level, so extrude.py imports this module back via a function-local import
inside compute_part_bodies instead).
"""

from fastapi import HTTPException
from OCC.Core.BRepFilletAPI import BRepFilletAPI_MakeChamfer
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import ChamferFeature, Part


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
    router/resolver validation split) rather than repeating it here."""
    body_ids = {ref.body_id for ref in feature.edge_refs}
    if len(body_ids) != 1:
        raise _mixed_body_selection(body_ids)
    body_id = next(iter(body_ids))

    edges = [resolve_subshape_from_bodies(bodies, ref) for ref in feature.edge_refs]
    chamfer_maker = BRepFilletAPI_MakeChamfer(bodies[body_id])
    for edge in edges:
        chamfer_maker.Add(feature.distance, edge)
    chamfer_maker.Build()
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
