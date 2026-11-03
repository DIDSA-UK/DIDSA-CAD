"""Computed mate status: `ok` or `broken` (`docs/pattern-followers-and-dissolve-plan.md`, "Broken mates").

Never stored, so it cannot go stale: a mate is `broken` when its residual at the STORED poses is above the solver's tolerance
(a pattern edit, a part file edited under it, an over-constrained import ...), when a limit mate's measured value sits outside
its range, or when a reference no longer resolves. Suppressed mates and couplers (gear / rack-pinion / screw: they measure
relative MOTION since a solve began, not a position) are always `ok`.

The listing runs on every Assembly-tree refresh, so each target Part is tessellated once for the whole listing."""

from __future__ import annotations

from dataclasses import replace
from typing import Literal

from fastapi import HTTPException

from app.document.assembly_group import _NOISE_TOL, mate_world_geometries
from app.document.assembly_solver import _mate_residual_vector, resolve_oriented_branch
from app.document.coupler import is_coupler
from app.document.limit import is_limit, limit_value, violated_bound
from app.document.models import Document, Mate, MateType, Part

MateStatus = Literal["ok", "broken"]


def mate_status(document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None = None) -> MateStatus:
    if mate.suppressed or is_coupler(mate) or len(mate.references) != 2:
        return "ok"
    try:
        first, second = mate_world_geometries(document, part, mate, cache)
        if is_limit(mate):
            value = limit_value(mate, first, second)
            return "broken" if value is None or violated_bound(mate, value) is not None else "ok"
        # the branch the stored poses sit on (Closest resolves to it, exactly as `build_group_model` does)
        oriented, _canonical = resolve_oriented_branch(mate, first, second, False)
        if oriented.type == MateType.ANGLE and oriented.secondary_flip and oriented.value is not None:
            t = abs(oriented.value) % 360.0
            oriented = replace(oriented, value=180.0 - min(t, 360.0 - t))
        rows = _mate_residual_vector(oriented, first, second)
    except (HTTPException, KeyError, ValueError):
        return "broken"  # a reference that no longer resolves (or geometry that no longer forms the mate)
    if not rows:
        return "broken"
    return "ok" if max(abs(float(r)) for r in rows) <= _NOISE_TOL else "broken"


def mate_statuses(document: Document, part: Part) -> dict[str, MateStatus]:
    """`{mate id: status}` for every mate of `part`."""
    cache: dict[str, dict] = {}
    return {mate.id: mate_status(document, part, mate, cache) for mate in part.mates}
