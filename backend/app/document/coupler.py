"""Coupler ("motion") mates - gear, rack and pinion, screw (`docs/gears-and-motion-plan.md` 3.3).

A coupler does not place its two parts. It keeps a RELATION between how far each has MOVED from the pose a solve started from
(D1 of the plan): creating one, Enforce all and Solve never pull anything because of it, and a drag keeps the relation for every
move. Per side of the mate, with `d` the side's world axis at the BASE pose, `p` its local axis point, base pose (R0, t0) and
candidate pose (R, t):

* turn about d:   Q = R R0^T as a unit quaternion (w, v), w >= 0;  d_theta = 2 atan2(v . d, w)   (the twist of a swing-twist split)
* travel along d: d_s = ((R p + t) - (R0 p + t0)) . d

A side that does not move (a fixed occurrence, the root part's own geometry) has d_theta = d_s = 0. A and B are the mate's
references in stored order; a coupler is never swapped. Rows (one each; k = +1 / -1, `Mate.secondary_flip` True / False):

* gear:          d_theta_B - k r d_theta_A                                     (radians)
* rack_pinion:   d_s_B - k (p / 2 pi) d_theta_A                                (mm), d_s_B along B's edge direction
* screw:         (d_s_B - d_s_A) - k (L / 2 pi) (d_theta_B - d_theta_A)        (mm), all along / about A's axis

All pure numpy except the create-time defaults and validation (`prepare_coupler`), which need the document.
"""

from __future__ import annotations

import math
from dataclasses import replace

import numpy as np
from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.GeomAbs import GeomAbs_Line
from OCC.Core.TopoDS import topods

from app.document.assembly import mate_ref_tops, top_level_occurrence_id
from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import (
    BRANCH_AUTO,
    BRANCH_USER,
    COUPLER_TYPES,
    BevelGearFeature,
    Document,
    GearFeature,
    Mate,
    MateType,
    Part,
    RackFeature,
    SubShapeType,
)


def is_coupler(mate: Mate) -> bool:
    return mate.type in COUPLER_TYPES


# ---- the rows ----------------------------------------------------------------------------------------------------------


def _quaternion(r: np.ndarray) -> tuple[float, np.ndarray]:
    """(w, v) of the rotation matrix `r`, w >= 0."""
    t = float(np.trace(r))
    if t > 0.0:
        s = math.sqrt(t + 1.0) * 2.0
        w, v = 0.25 * s, np.array([r[2, 1] - r[1, 2], r[0, 2] - r[2, 0], r[1, 0] - r[0, 1]]) / s
    else:
        i = int(np.argmax(np.diag(r)))
        j, k = (i + 1) % 3, (i + 2) % 3
        s = math.sqrt(r[i, i] - r[j, j] - r[k, k] + 1.0) * 2.0
        v = np.zeros(3)
        v[i] = 0.25 * s
        v[j] = (r[j, i] + r[i, j]) / s
        v[k] = (r[k, i] + r[i, k]) / s
        w = (r[k, j] - r[j, k]) / s
    if w < 0.0:
        w, v = -w, -v
    return w, v


def turn_about(r: np.ndarray, r0: np.ndarray, d: np.ndarray) -> float:
    """The turn (radians, in [-pi, pi]) of the move R0 -> R about the world unit axis `d`."""
    w, v = _quaternion(r @ r0.T)
    return 2.0 * math.atan2(float(v @ d), w)


def travel_along(p: np.ndarray, r: np.ndarray, t: np.ndarray, r0: np.ndarray, t0: np.ndarray, d: np.ndarray) -> float:
    """How far the point `p` (local) moved along the world unit axis `d` between the base pose and the candidate."""
    return float(((r @ p + t) - (r0 @ p + t0)) @ d)


def coupler_k(mate: Mate) -> float:
    """The sense: `secondary_flip` True is +1, False (or unset) is -1."""
    return 1.0 if mate.secondary_flip else -1.0


def coupler_rows(mate: Mate, turn_a: float, move_a: float, turn_b: float, move_b: float) -> list[float]:
    """The one residual row of `mate` from each side's turn (radians) and travel (mm) since the base pose."""
    k, value = coupler_k(mate), float(mate.value)
    if mate.type == MateType.GEAR:
        return [turn_b - k * value * turn_a]
    if mate.type == MateType.RACK_PINION:
        return [move_b - k * value / (2.0 * math.pi) * turn_a]
    return [(move_b - move_a) - k * value / (2.0 * math.pi) * (turn_b - turn_a)]


def needs_point(mate: Mate) -> tuple[bool, bool]:
    """(side A needs a travel, side B needs a travel): the rack's B and the screw's both."""
    if mate.type == MateType.RACK_PINION:
        return False, True
    if mate.type == MateType.SCREW:
        return True, True
    return False, False


# ---- validation and defaults (create) ----------------------------------------------------------------------------------


def _unprocessable(error_type: str, message: str) -> HTTPException:
    return HTTPException(status_code=422, detail={"type": error_type, "detail": message})


def _tooth_features(document: Document, part: Part, occurrence_id: str) -> list:
    """The gear, bevel gear and rack features of the part the occurrence places (the leaf part under a sub-assembly path)."""
    from app.document.assembly_solver import _target_part_and_transform

    top = top_level_occurrence_id(occurrence_id)
    top_part, _ = _target_part_and_transform(document, part, top)
    target, _ = _target_part_and_transform(document, top_part, occurrence_id[len(top) + 1 :])
    return [f for f in target.features if isinstance(f, (GearFeature, BevelGearFeature, RackFeature))]


def _single_tooth_feature(document: Document, part: Part, occurrence_id: str):
    found = _tooth_features(document, part, occurrence_id)
    return found[0] if len(found) == 1 else None


def _is_straight_edge(document: Document, part: Part, ref) -> bool:
    from app.document.assembly_solver import _target_part_and_transform

    sub = ref.subshape_ref
    if sub is None or sub.shape_type != SubShapeType.EDGE:
        return False
    target, _ = _target_part_and_transform(document, part, ref.occurrence_id)
    shape = resolve_subshape_from_bodies(compute_part_bodies(target), sub)
    return BRepAdaptor_Curve(topods.Edge(shape)).GetType() == GeomAbs_Line


def _pitch_diameter(feature) -> float | None:
    if isinstance(feature, GearFeature):
        return feature.module * feature.tooth_count
    return None


def _default_value(document: Document, part: Part, mate: Mate) -> float:
    a = _single_tooth_feature(document, part, mate.references[0].occurrence_id)
    b = _single_tooth_feature(document, part, mate.references[1].occurrence_id)
    if mate.type == MateType.GEAR and isinstance(a, (GearFeature, BevelGearFeature)) and isinstance(b, (GearFeature, BevelGearFeature)):
        return a.tooth_count / b.tooth_count
    if mate.type == MateType.RACK_PINION:
        diameter = _pitch_diameter(a)
        if diameter is not None and isinstance(b, RackFeature):
            return math.pi * diameter
        if isinstance(a, BevelGearFeature):
            return math.pi * a.module * a.tooth_count
    raise _unprocessable("gear_ratio_required", "Type the ratio: the part has no gear, or several")


def _default_sense(document: Document, part: Part, mate: Mate, d_a: np.ndarray, d_b: np.ndarray, p_a: np.ndarray, p_b: np.ndarray) -> bool:
    """`secondary_flip` for a new coupler from the stored poses (plan 3.3.3): True is k = +1."""
    if mate.type == MateType.SCREW:
        return True
    if mate.type == MateType.GEAR:
        dot = float(d_a @ d_b)
        if abs(dot) > 0.9:
            c = 1.0 if dot > 0 else -1.0
            a = _single_tooth_feature(document, part, mate.references[0].occurrence_id)
            b = _single_tooth_feature(document, part, mate.references[1].occurrence_id)
            internal = any(isinstance(f, GearFeature) and f.is_internal for f in (a, b))
            k = c if internal else -c
            return k > 0
        return False  # a bevel pair: k = -1
    # rack and pinion: the rack moves along t = d_a x n for a positive turn of A, n the pinion-to-rack direction
    n = p_b - p_a
    n = n - (n @ d_a) * d_a
    length = float(np.linalg.norm(n))
    if length < 1e-9:
        return True
    t = np.cross(d_a, n / length)
    along = float(t @ d_b)
    if abs(along) < 0.5:
        return True
    return along > 0


def prepare_coupler(document: Document, part: Part, mate: Mate, flip_given: bool) -> Mate:
    """Validates a NEW coupler (plan 3.3.2) and fills in what it left empty (3.3.3). Raises the 422 `HTTPException`s;
    returns the mate to store: `value` set, `secondary_flip` a bool, `branch_source` "user" when the request set the sense."""
    from app.document.assembly_group import mate_world_geometries
    from app.document.assembly_solver import _unsupported_mate_geometry

    if len(mate.references) != 2:
        raise HTTPException(status_code=422, detail="A Mate must have exactly 2 references")
    for ref in mate.references:
        if ref.midplane is not None:
            raise HTTPException(status_code=422, detail=f"A Width (midplane) reference cannot be used with a {mate.type.value} mate")
    tops_a, tops_b = mate_ref_tops(mate.references[0]), mate_ref_tops(mate.references[1])
    if set(tops_a) & set(tops_b):
        raise HTTPException(status_code=422, detail="A Mate's two references must name different occurrences")
    if mate.value is not None and not (math.isfinite(mate.value) and mate.value > 0):
        raise _unprocessable("invalid_coupler_value", f"The value of a {mate.type.value} mate must be a number above zero, got {mate.value!r}")
    if mate.type == MateType.SCREW and mate.value is None:
        raise _unprocessable("screw_lead_required", "A screw mate needs its lead (mm per turn)")
    if mate.type == MateType.RACK_PINION and not _is_straight_edge(document, part, mate.references[1]):
        raise _unprocessable("rack_reference_not_straight_edge", "The rack's side of a rack and pinion mate must be a straight edge")
    first, second = mate_world_geometries(document, part, mate)  # raises for a dangling reference
    for ref, geometry in zip(mate.references, (first, second)):
        if geometry.axis_origin is None or geometry.direction is None:
            raise _unsupported_mate_geometry(ref, "an axis (a cylindrical face, or a circular or straight edge)")
    value = mate.value if mate.value is not None else _default_value(document, part, mate)
    if flip_given and mate.secondary_flip is not None:
        flip, source = bool(mate.secondary_flip), BRANCH_USER
    else:
        d_a = np.array(first.direction, float)
        d_b = np.array(second.direction, float)
        flip = _default_sense(
            document, part, mate, d_a / np.linalg.norm(d_a), d_b / np.linalg.norm(d_b), np.array(first.axis_origin, float), np.array(second.axis_origin, float)
        )
        source = BRANCH_AUTO
    return replace(mate, value=float(value), secondary_flip=flip, alignment=None, flipped=False, branch_source=source)
