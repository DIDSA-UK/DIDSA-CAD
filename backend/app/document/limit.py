"""Limit mates - `limit_distance`, `limit_angle` (`docs/limit-mates-scope.md`, M9).

A limit keeps one measured value inside `[limit_min, limit_max]` (either bound may be left out). It places nothing: creating one
moves nothing, and a solve holds it at its nearest bound only while the wish would otherwise leave the range (the active set of
`assembly_group.solve_group`; clients do the same per frame from the exported rows, `constraint_model`).

The measured value, with A and B the mate's references in stored order (a limit is never swapped):

* limit_distance: `(P_A - P_B) . N` in mm, `P` the point / plane origin of each side and `N` the normal of B's plane (A's when B has
  none). One side at least must be a plane; plane-plane needs no more.
* limit_angle: the signed angle in degrees, `(-180, 180]`, from A's direction to B's about the hinge (the axis of a concentric / edge
  mate between the same two occurrences, as an ANGLE gets it): `atan2((a x b) . h, a . b)`.
"""

from __future__ import annotations

import math

import numpy as np
from fastapi import HTTPException

from app.document.assembly import mate_ref_tops
from app.document.models import LIMIT_TYPES, Mate, MateType

LIMIT_TOL = 1e-7  # mm / degrees a value may sit outside its range before the limit counts as violated


def is_limit(mate: Mate) -> bool:
    return mate.type in LIMIT_TYPES


def _unit(v) -> np.ndarray:
    a = np.asarray(v, float)
    return a / float(np.linalg.norm(a))


def limit_value(mate: Mate, a, b) -> float | None:
    """The measured value of a limit mate at two WORLD geometries (`_ResolvedGeometry`, a with its hinge when it is an angle);
    `None` when they cannot form it."""
    if mate.type == MateType.LIMIT_DISTANCE:
        if b.plane is not None:
            normal, point_b = b.plane.normal, b.plane.origin
            point_a = a.plane.origin if a.plane is not None else a.point
        elif a.plane is not None:
            normal, point_a = a.plane.normal, a.plane.origin
            point_b = b.point
        else:
            return None
        if point_a is None or point_b is None:
            return None
        return float((np.asarray(point_a, float) - np.asarray(point_b, float)) @ _unit(normal))
    if mate.type == MateType.LIMIT_ANGLE:
        hinge = a.hinge or b.hinge
        if hinge is None or a.direction is None or b.direction is None:
            return None
        na, nb, h = _unit(a.direction), _unit(b.direction), _unit(hinge[1])
        return math.degrees(math.atan2(float(np.cross(na, nb) @ h), float(na @ nb)))
    return None


def current_limit_value(document, part, mate: Mate) -> float | None:
    """The value of limit `mate` at the STORED poses (mm / degrees), for the client to show next to its range; `None` when it cannot be measured."""
    from app.document.assembly_group import mate_world_geometries

    try:
        first, second = mate_world_geometries(document, part, mate)
    except HTTPException:
        return None
    return limit_value(mate, first, second)


def row_unit(mate: Mate) -> float:
    """Scale of a held limit's equality row `(value - bound) * unit`: millimetres as they are, an angle in radians."""
    return math.pi / 180.0 if mate.type == MateType.LIMIT_ANGLE else 1.0


def violated_bound(mate: Mate, value: float, tol: float = LIMIT_TOL) -> float | None:
    """The bound `value` has crossed (the one to hold it at), else `None`."""
    if mate.limit_max is not None and value > mate.limit_max + tol:
        return float(mate.limit_max)
    if mate.limit_min is not None and value < mate.limit_min - tol:
        return float(mate.limit_min)
    return None


def validate_limit_fields(mate: Mate) -> None:
    """The 422s of a limit's own numbers (shape only; the geometry is `prepare_limit`'s)."""
    lo, hi = mate.limit_min, mate.limit_max
    if lo is None and hi is None:
        raise _unprocessable("limit_range_required", "A limit mate needs a minimum, a maximum, or both")
    for name, v in (("limit_min", lo), ("limit_max", hi)):
        if v is not None and not math.isfinite(v):
            raise _unprocessable("invalid_limit_value", f"{name} must be a finite number, got {v!r}")
    if lo is not None and hi is not None and lo > hi:
        raise _unprocessable("limit_range_inverted", f"limit_min ({lo}) is above limit_max ({hi})")
    if mate.type == MateType.LIMIT_ANGLE:
        for name, v in (("limit_min", lo), ("limit_max", hi)):
            if v is not None and not (-180.0 <= v <= 180.0):
                raise _unprocessable("limit_angle_out_of_range", f"{name} must be between -180 and 180 degrees, got {v!r}")


def _unprocessable(kind: str, message: str) -> HTTPException:
    return HTTPException(status_code=422, detail={"type": kind, "detail": message})


def prepare_limit(document, part, mate: Mate) -> Mate:
    """Validates a NEW limit mate and returns the mate to store (branch fields cleared: a limit has none). Raises the 422s."""
    from dataclasses import replace

    from app.document.assembly_group import mate_world_geometries

    if len(mate.references) != 2:
        raise HTTPException(status_code=422, detail="A Mate must have exactly 2 references")
    for ref in mate.references:
        if ref.midplane is not None:
            raise HTTPException(status_code=422, detail=f"A Width (midplane) reference cannot be used with a {mate.type.value} mate")
    if set(mate_ref_tops(mate.references[0])) & set(mate_ref_tops(mate.references[1])):
        raise HTTPException(status_code=422, detail="A Mate's two references must name different occurrences")
    validate_limit_fields(mate)
    first, second = mate_world_geometries(document, part, mate)  # raises for a dangling reference
    if mate.type == MateType.LIMIT_DISTANCE and limit_value(mate, first, second) is None:
        raise _unprocessable("limit_needs_plane", "A distance limit needs a plane (a flat face or a plane) on at least one side")
    if mate.type == MateType.LIMIT_ANGLE:
        if first.direction is None or second.direction is None:
            raise _unprocessable("limit_angle_needs_directions", "An angle limit needs a direction (a face normal or an axis) on each side")
        if first.hinge is None and second.hinge is None:
            raise _unprocessable("limit_angle_needs_hinge", "An angle limit needs a hinge: mate the two parts with a concentric (or edge on edge) mate about the swing axis first")
    return replace(mate, value=None, alignment=None, secondary_flip=None, flipped=False)
