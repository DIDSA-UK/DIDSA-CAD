"""Computed mate status: `ok`, `near` or `broken` (`docs/pattern-followers-and-dissolve-plan.md`, "Broken mates"; `near`:
`docs/assembly-perf-mates-and-ui-plan.md`, B1).

Never stored, so it cannot go stale: a mate is `ok` when its residual at the STORED poses is within the solver's noise tolerance;
`near` above that but still within the near-redundant limits (`app.document.mate_tolerance`: 0.01 mm at the far end of its parts,
1e-4 rad), which is what two mates that fix the same thing with slightly different rounded numbers leave; `broken` beyond that
(a pattern edit, a part file edited under it, an over-constrained import ...), when a limit mate's measured value sits outside
its range, or when a reference no longer resolves. Suppressed mates and couplers (gear / rack-pinion / screw: they measure
relative MOTION since a solve began, not a position) are always `ok`.

Mate reference identity (N1b, `app.document.subshape_identity.refresh_mate_references`): a mate with a LOST reference (the face it named is gone or cannot be told
from its twins) is `broken` whatever its type, so a coupler's or a limit's always-`ok` never hides one. A held mate (a reference bound on weak evidence, or unsigned and
unconfirmed) keeps the status its bound geometry gives (a held coupler is `broken` only when its bound faces are not axes: `placement_confirms`); the held flag is
the listing's own (`MateReferenceState.held`).

The listing runs on every Assembly-tree refresh, so each target Part is tessellated once for the whole listing."""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import TYPE_CHECKING, Literal

from fastapi import HTTPException

from app.document.assembly_group import _NOISE_TOL, bounding_radius, mate_world_geometries
from app.document.assembly import mate_tops
from app.document.assembly_solver import _mate_residual_vector, resolve_oriented_branch
from app.document.coupler import is_coupler
from app.document.limit import is_limit, limit_value, violated_bound
from app.document.mate_tolerance import is_within_tolerance, physical_residual
from app.document.models import Document, Mate, MateType, Part

if TYPE_CHECKING:
    from app.document.subshape_identity import MateReferenceState

MateStatus = Literal["ok", "near", "broken"]


@dataclass(frozen=True)
class MateStatusDetail:
    """A mate's status, and for `near` the miss in millimetres (at the far end of its parts) and degrees (None otherwise)."""

    status: MateStatus
    residual_mm: float | None = None
    residual_deg: float | None = None


def mate_status_detail(
    document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None = None, state: "MateReferenceState | None" = None
) -> MateStatusDetail:
    """`state`: what `refresh_mate_references` found for this mate (None = not asked: the status is the geometry's alone, as before N1b)."""
    if state is not None and state.has_lost and not mate.suppressed:
        return MateStatusDetail("broken")
    if is_coupler(mate) and not mate.suppressed and state is not None and state.held and not placement_confirms(document, part, mate, cache):
        # A coupler measures motion, not position, so it is `ok` at any pose. But a held one (an old file's unsigned reference the placement does not confirm, a
        # reference bound weakly) whose faces are not the kind it needs (an axis on each side) is not `ok`: that is a reference that does not resolve.
        return MateStatusDetail("broken")
    if mate.suppressed or is_coupler(mate) or len(mate.references) != 2:
        return MateStatusDetail("ok")
    return _geometry_status(document, part, mate, cache)


def _geometry_status(document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None) -> MateStatusDetail:
    """The status the mate's own geometry gives at the stored poses (not coupler: those are `ok`)."""
    try:
        first, second = mate_world_geometries(document, part, mate, cache)
        if is_limit(mate):
            value = limit_value(mate, first, second)
            return MateStatusDetail("broken" if value is None or violated_bound(mate, value) is not None else "ok")
        # the branch the stored poses sit on (Closest resolves to it, exactly as `build_group_model` does)
        oriented, _canonical = resolve_oriented_branch(mate, first, second, False)
        if oriented.type == MateType.ANGLE and oriented.secondary_flip and oriented.value is not None:
            t = abs(oriented.value) % 360.0
            oriented = replace(oriented, value=180.0 - min(t, 360.0 - t))
        rows = _mate_residual_vector(oriented, first, second)
        if not rows:
            return MateStatusDetail("broken")
        if max(abs(float(r)) for r in rows) <= _NOISE_TOL:
            return MateStatusDetail("ok")
        # Above the strict tolerance: measure it in millimetres and degrees, and see whether it is a hair's miss or a real one.
        residual = physical_residual(oriented, first, second, rows)
        radius = max((bounding_radius(document, part, top) for top in mate_tops(mate) if top != ""), default=0.0)
    except (HTTPException, KeyError, ValueError):
        return MateStatusDetail("broken")  # a reference that no longer resolves (or geometry that no longer forms the mate)
    if is_within_tolerance(residual, radius):
        return MateStatusDetail("near", residual.displacement_mm(radius), residual.angular_deg)
    return MateStatusDetail("broken")


def placement_confirms(document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None = None) -> bool:
    """Whether the mate's references, resolved as they stand (an unsigned one at the face its index names), are the right ones for the STORED poses: the plan's N-3
    test for adopting an old file's unsigned reference. A mate reads `ok` / `near` there (suppressed or not: the geometry is judged, not the flag); a coupler's and
    a limit's faces are the kind they need (an axis on each side; a straight edge for a rack; the value a limit measures exists). Never raises."""
    if len(mate.references) != 2:
        return False
    try:
        first, second = mate_world_geometries(document, part, mate, cache)
    except (HTTPException, KeyError, ValueError):
        return False
    if is_coupler(mate):
        if any(g.axis_origin is None or g.direction is None for g in (first, second)):
            return False
        if mate.type == MateType.RACK_PINION:
            from app.document.coupler import _is_straight_edge

            try:
                return _is_straight_edge(document, part, mate.references[1])
            except (HTTPException, KeyError, ValueError):
                return False
        return True
    if is_limit(mate):
        return limit_value(mate, first, second) is not None
    return _geometry_status(document, part, mate, cache).status != "broken"


def mate_status(document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None = None) -> MateStatus:
    return mate_status_detail(document, part, mate, cache).status


def mate_status_details(
    document: Document, part: Part, states: "dict[str, MateReferenceState] | None" = None, cache: dict[str, dict] | None = None
) -> dict[str, MateStatusDetail]:
    """`{mate id: status detail}` for every mate of `part`. `states`: the reference refresh of the same listing (`refresh_mate_references`)."""
    cache = {} if cache is None else cache
    states = states or {}
    return {mate.id: mate_status_detail(document, part, mate, cache, states.get(mate.id)) for mate in part.mates}


def mate_statuses(document: Document, part: Part) -> dict[str, MateStatus]:
    """`{mate id: status}` for every mate of `part`."""
    return {mate_id: detail.status for mate_id, detail in mate_status_details(document, part).items()}
