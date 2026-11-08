"""Computed mate status: `ok`, `near` or `broken` (`docs/pattern-followers-and-dissolve-plan.md`, "Broken mates"; `near`:
`docs/assembly-perf-mates-and-ui-plan.md`, B1).

Never stored, so it cannot go stale: a mate is `ok` when its residual at the STORED poses is within the solver's noise tolerance;
`near` above that but still within the near-redundant limits (`app.document.mate_tolerance`: 0.01 mm at the far end of its parts,
1e-4 rad), which is what two mates that fix the same thing with slightly different rounded numbers leave; `broken` beyond that
(a pattern edit, a part file edited under it, an over-constrained import ...), when a limit mate's measured value sits outside
its range, or when a reference no longer resolves. Suppressed mates and couplers (gear / rack-pinion / screw: they measure
relative MOTION since a solve began, not a position) are always `ok`.

The listing runs on every Assembly-tree refresh, so each target Part is tessellated once for the whole listing."""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Literal

from fastapi import HTTPException

from app.document.assembly_group import _NOISE_TOL, bounding_radius, mate_world_geometries
from app.document.assembly import mate_tops
from app.document.assembly_solver import _mate_residual_vector, resolve_oriented_branch
from app.document.coupler import is_coupler
from app.document.limit import is_limit, limit_value, violated_bound
from app.document.mate_tolerance import is_within_tolerance, physical_residual
from app.document.models import Document, Mate, MateType, Part

MateStatus = Literal["ok", "near", "broken"]


@dataclass(frozen=True)
class MateStatusDetail:
    """A mate's status, and for `near` the miss in millimetres (at the far end of its parts) and degrees (None otherwise)."""

    status: MateStatus
    residual_mm: float | None = None
    residual_deg: float | None = None


def mate_status_detail(document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None = None) -> MateStatusDetail:
    if mate.suppressed or is_coupler(mate) or len(mate.references) != 2:
        return MateStatusDetail("ok")
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


def mate_status(document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None = None) -> MateStatus:
    return mate_status_detail(document, part, mate, cache).status


def mate_status_details(document: Document, part: Part) -> dict[str, MateStatusDetail]:
    """`{mate id: status detail}` for every mate of `part`."""
    cache: dict[str, dict] = {}
    return {mate.id: mate_status_detail(document, part, mate, cache) for mate in part.mates}


def mate_statuses(document: Document, part: Part) -> dict[str, MateStatus]:
    """`{mate id: status}` for every mate of `part`."""
    return {mate_id: detail.status for mate_id, detail in mate_status_details(document, part).items()}
