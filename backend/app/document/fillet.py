"""OCCT geometry construction for FilletFeature (Prompt D) - kept separate
from app.document.router the same way app.document.extrude/create_plane
already are, and imported from app.document.extrude's own compute_part_
bodies via a function-local import (see that function's own doc comment)
to avoid a circular import: this module needs compute_part_bodies/
resolve_subshape_from_bodies from extrude.py at module level, so extrude.py
cannot import this module back at its own module level.
"""

from fastapi import HTTPException
from OCC.Core.BRepFilletAPI import BRepFilletAPI_MakeFillet
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import FilletFeature, Part


def _mixed_body_selection(body_ids: set[str]) -> HTTPException:
    """D: a Fillet's `edge_refs` must all resolve to the same Body - OCCT's
    `BRepFilletAPI_MakeFillet` operates on one solid at a time, so a
    selection spanning two Bodies can never be a single Fillet Feature (a
    real multi-body fillet is a different, out-of-scope design - see the
    prompt's own scope note). 422, matching every other structured
    resolution error's status code in this codebase (`missing_reference`,
    `non_planar_reference`, `faces_not_parallel`, ...)."""
    return HTTPException(
        status_code=422,
        detail={"type": "mixed_body_selection", "body_ids": sorted(body_ids)},
    )


def _fillet_failed(body_id: str) -> HTTPException:
    """D: `BRepFilletAPI_MakeFillet.IsDone()` returned false - a geometric
    failure (radius too large for an edge, a resulting self-intersection,
    etc.), not a malformed reference. 422, not an uncaught OCCT exception
    surfacing as a 500 - this is exactly the class of failure the prompt's
    own brief calls out as needing a structured, non-crashing response."""
    return HTTPException(status_code=422, detail={"type": "fillet_failed", "body_id": body_id})


def resolve_fillet_from_bodies(
    bodies: dict[str, TopoDS_Shape],
    feature: FilletFeature,
) -> tuple[str, TopoDS_Shape]:
    """The Body id `feature` modifies and its post-fillet shape, resolved
    against `bodies` - an already-in-progress `app.document.extrude.
    compute_part_bodies` accumulator, never a fresh recompute (see
    `resolve_fillet`'s own doc comment for why a fresh recompute here would
    recurse forever from inside `compute_part_bodies`'s own loop, the same
    reasoning `app.document.create_plane`'s own `_from_bodies` resolvers
    already established).

    Every `edge_ref` must already share the same `body_id` (see
    `_mixed_body_selection`) - checked before resolving any of them, so a
    cross-body selection is reported as that specific structured error
    rather than whichever edge happens to resolve first raising a plain
    `missing_reference` instead. Assumes `feature.edge_refs` is non-empty -
    enforced by `app.document.router`'s own payload-shape validation before
    this is ever called, the same "payload shape checked by the router,
    referential/geometric validity checked by the resolver" split every
    other structured error in this module family already uses."""
    body_ids = {ref.body_id for ref in feature.edge_refs}
    if len(body_ids) != 1:
        raise _mixed_body_selection(body_ids)
    body_id = next(iter(body_ids))

    edges = [resolve_subshape_from_bodies(bodies, ref) for ref in feature.edge_refs]
    fillet_maker = BRepFilletAPI_MakeFillet(bodies[body_id])
    for edge in edges:
        fillet_maker.Add(feature.radius, edge)
    fillet_maker.Build()
    if not fillet_maker.IsDone():
        raise _fillet_failed(body_id)
    return body_id, fillet_maker.Shape()


def resolve_fillet(
    part: Part, feature: FilletFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[str, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation -
    computes `bodies` *as if `feature` weren't in `part.features` yet*
    (excludes its own id in addition to whatever the caller already
    excludes), so validating a candidate edit to an existing Fillet's
    `radius`/`edge_refs` is checked against the target Body's shape
    *before* this Fillet's own (about-to-be-replaced) effect, not stacked
    on top of it - a Fillet modifies a Body in place, so re-resolving
    against its own prior output would double-apply it (round two of
    filleting an already-filleted edge selection, not re-deriving the
    original candidate). A brand-new Feature (not yet in `part.features`)
    is unaffected by the extra exclusion - its id isn't there to exclude in
    the first place.

    Any future Feature type with the same shape (modifies a Body in place,
    and its own live-edit UI lets the client keep re-picking sub-shapes of
    that same Body - Chamfer will) needs this identical self-exclusion
    convention in its own resolver, paired with the client-side
    stable-pick-body + preview-overlay pattern this enables - see
    `docs/live-preview-pattern.md`, written after a real bug shipped from
    the client half of this pairing being implemented without it."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_fillet_from_bodies(bodies, feature)
