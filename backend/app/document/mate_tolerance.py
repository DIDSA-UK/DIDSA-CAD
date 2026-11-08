"""Near-redundant mates: when is a solve that misses by a hair still good enough? (`docs/assembly-perf-mates-and-ui-plan.md`, B1)

An AI-written plan rounds its coordinates (an angled gusset edge at 41.3498 / 41.3500 / 41.3502 degrees, a brace placed at
41.3499), so two mates that both fix the same rotation disagree by a few millionths of a radian. The strict solve
(`assembly_group._SOLVE_TOL`, converged at `_NOISE_TOL`) then reports "no placement satisfies these mates together", though the
model is right to within a hair.

The rule here is an ENGINEERING one: nothing is loosened silently, and a dimension that is wrong still fails.

* The strict solve is always tried first, and a result within `_NOISE_TOL` is `ok`, exactly as before.
* Only a result the strict solve could not reach is judged, and each mate's residual is measured in PHYSICAL units: a distance
  in millimetres and an angle in radians. The solver's own rows are never compared with a threshold: a row can be a distance, a
  unit-vector difference (about an angle in radians), or the cosine of an angle (almost flat near 0 and 180 degrees).
* It is accepted, with the mates over `_NOISE_TOL` marked `near`, only if EVERY mate is within both
  - `LINEAR_LIMIT_MM` (0.01 mm), and
  - an angle that moves the far end of the part by no more than the same 0.01 mm (angle x the larger bounding radius of the
    parts the mate joins), and never more than `ANGULAR_LIMIT_RAD` (1e-4 rad) whatever the part size.
  An angular limit alone would not be safe: 1e-4 rad is 0.6 mm across 6 m.
* Stored mate values, part geometry and sketches are never changed. The poses kept are the solver's least-squares compromise,
  which is within the limits by construction.

Mates that are not placements (couplers, limits) never take part: a result they spoil is not accepted here.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Literal

from app.document.assembly_solver import _effective_mate, _mate_residual_vector, resolve_branch
from app.document.models import Mate, MateType

LINEAR_LIMIT_MM = 0.01
"""A mate may miss by at most this many millimetres."""

ANGULAR_LIMIT_RAD = 1e-4
"""Cap on any mate's angle, whatever the part size."""

FAR_END_LIMIT_MM = LINEAR_LIMIT_MM
"""An angle may move the far end of the part (angle x bounding radius) by at most this many millimetres."""

RowKind = Literal["lin", "ang", "cos", "hinge"]


@dataclass(frozen=True)
class PhysicalResidual:
    """One mate's miss: `linear_mm` a distance, `angular_rad` an angle."""

    linear_mm: float
    angular_rad: float

    @property
    def angular_deg(self) -> float:
        return math.degrees(self.angular_rad)

    def displacement_mm(self, radius_mm: float) -> float:
        """The larger of the linear miss and what the angle moves the far end of the part (angle x `radius_mm`): the one
        number a person is shown ("within 0.006 mm"). Acceptance is judged on both separately (`is_within_tolerance`)."""
        return max(self.linear_mm, self.angular_rad * radius_mm if math.isfinite(radius_mm) else 0.0)


def angular_limit_rad(radius_mm: float) -> float:
    """The largest angle allowed for a mate between parts of bounding radius up to `radius_mm`: it must keep the far end within
    `FAR_END_LIMIT_MM` and never exceed `ANGULAR_LIMIT_RAD`."""
    if radius_mm <= 0 or not math.isfinite(radius_mm):
        return ANGULAR_LIMIT_RAD
    return min(ANGULAR_LIMIT_RAD, FAR_END_LIMIT_MM / radius_mm)


def row_kinds(mate: Mate, driven, fixed, row_count: int) -> tuple[RowKind, ...]:
    """What each row of `_mate_residual_vector(mate, driven, fixed)` measures. Mirrors that function's branches (same geometry
    tests, same order); `tests/test_mate_tolerance.py` checks the row counts agree for every mate type and geometry pairing."""
    mate = _effective_mate(resolve_branch(mate, driven, fixed), driven, fixed)
    t = mate.type
    if t == MateType.COINCIDENT:
        if driven.plane is not None and fixed.plane is not None:
            return ("lin", "ang", "ang", "ang")
        if driven.plane is not None or fixed.plane is not None:
            return ("lin",)
        return ("lin", "lin", "lin")
    if t == MateType.CONCENTRIC:
        kinds: tuple[RowKind, ...] = ("ang", "ang", "ang", "lin", "lin", "lin")
        if row_count > 6:
            kinds += ("ang", "ang", "ang")  # allow_rotation off: the perpendicular reference directions too
        return kinds
    if t == MateType.PARALLEL:
        return ("ang", "ang", "ang")
    if t == MateType.ANGLE:
        return ("cos",) + ("hinge",) * (row_count - 1)
    if t == MateType.DISTANCE:
        if driven.plane is not None and fixed.plane is not None:
            return ("lin", "ang", "ang", "ang")
        if driven.plane is not None or fixed.plane is not None:
            return ("lin",)
        if driven.axis_origin is not None and driven.direction is not None and fixed.axis_origin is not None and fixed.direction is not None:
            return ("lin", "ang", "ang", "ang")
        return ("lin",)
    return ()


def _angle_of_difference(x: float, y: float, z: float) -> float:
    """The angle between two unit vectors from the length of their difference: |a - b| = 2 sin(angle / 2)."""
    return 2.0 * math.asin(min(1.0, math.sqrt(x * x + y * y + z * z) / 2.0))


def physical_residual(mate: Mate, driven, fixed, rows: tuple[float, ...] | None = None, extra_parallel_rows: tuple[float, ...] = ()) -> PhysicalResidual:
    """The mate's residual at the geometry `driven` / `fixed` (world frame) in millimetres and radians. `extra_parallel_rows` are
    the cross product of the unit normals of a Width side's two faces (they must stay parallel): an angle, as `sin(angle)`."""
    if rows is None:
        rows = _mate_residual_vector(mate, driven, fixed)
    kinds = row_kinds(mate, driven, fixed, len(rows))
    if len(kinds) != len(rows):
        raise ValueError(f"mate {mate.id}: {len(rows)} residual rows, {len(kinds)} kinds")
    effective = _effective_mate(resolve_branch(mate, driven, fixed), driven, fixed)
    linear_squares = 0.0
    angular = 0.0
    i = 0
    while i < len(rows):
        kind, row = kinds[i], float(rows[i])
        if kind == "lin":
            linear_squares += row * row
            i += 1
        elif kind == "ang":
            if i + 2 < len(rows) and kinds[i + 1] == "ang" and kinds[i + 2] == "ang":
                angular = max(angular, _angle_of_difference(row, float(rows[i + 1]), float(rows[i + 2])))
                i += 3
            else:  # not a whole vector (never produced today): the row itself is the best available angle
                angular = max(angular, abs(row))
                i += 1
        elif kind == "cos":
            target = _folded_angle_rad(effective)
            if target is None:
                angular = math.inf
            else:
                actual = math.acos(max(-1.0, min(1.0, row + math.cos(target))))
                angular = max(angular, abs(actual - target))
            i += 1
        else:  # hinge: sin(swing) - (+-)sin(target); the angle it stands for is this over cos(target), floored (never under-reported)
            target = _folded_angle_rad(effective)
            divisor = 1e-3 if target is None else max(abs(math.cos(target)), 1e-3)
            angular = max(angular, math.asin(min(1.0, abs(row) / divisor)))
            i += 1
    if len(extra_parallel_rows) >= 3:
        sine = math.sqrt(sum(float(r) ** 2 for r in extra_parallel_rows[:3]))
        angular = max(angular, math.asin(min(1.0, sine)))
    return PhysicalResidual(math.sqrt(linear_squares), angular)


def _folded_angle_rad(mate: Mate) -> float | None:
    """The target of an ANGLE mate in radians, folded to 0..180 degrees as `_mate_residual_vector` does."""
    if mate.value is None:
        return None
    degrees = abs(mate.value) % 360
    return math.radians(min(degrees, 360 - degrees))


def is_within_tolerance(residual: PhysicalResidual, radius_mm: float) -> bool:
    """Whether a mate's miss is inside the near-redundant limits (linear 0.01 mm; angle x radius 0.01 mm and 1e-4 rad)."""
    return residual.linear_mm <= LINEAR_LIMIT_MM and residual.angular_rad <= angular_limit_rad(radius_mm)
