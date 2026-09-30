"""Constrained drag, session S1 (`docs/constrained-drag-implementation-plan.md`):
the GROUP model - pure functions, no HTTP, no `py_slvs`.

`assembly_solver._free_motion` analyses ONE occurrence against frozen peers,
so a part whose neighbour is itself movable reports DOF 0 and cannot be
dragged (measured: plate + B, C, D -> per-occurrence DOF 0/1/1, yet the
group has DOF 5). This module analyses the whole mate-graph component
instead:

* component discovery: the non-frozen occurrences connected to the grabbed
  one through non-suppressed mates. FROZEN = `fixed` occurrences and the
  `""` ref (the focused part's own geometry); a frozen occurrence is never
  a variable and never joins two components together;
* variable layout: 6 per member, `[dx dy dz rx ry rz]`, members in a fixed
  order (grabbed first, then `part.occurrences` order) - the same
  perturbation convention as `_free_motion` (translation added, rotation
  vector composed onto the stored rotation, about the occurrence's origin);
* stacked residual (`assembly_solver._mate_residual_vector` of every mate,
  reused unchanged) and its central-difference Jacobian;
* `dof = 6k - rank(J)` with a RELATIVE-tolerance SVD rank (never
  `System.Dof`), `grounded`, a lever-arm-weighted orthonormal nullspace
  `basis`, per-member `mobility` and conditioning `quality`.

Nothing here solves or stores anything; S2 builds the solve on `GroupModel`.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib

from app.document.assembly_solver import (
    _axis_angle_from_quaternion,
    _mate_residual_vector,
    _place_in_world,
    _quaternion_from_axis_angle,
    _quaternion_multiply,
    _resolve_local_geometry,
    _ResolvedGeometry,
    _target_part_and_transform,
)
from app.document.extrude import compute_part_bodies
from app.document.models import Document, Mate, Part, RigidTransform

_JACOBIAN_STEP = 1e-6  # same step as `assembly_solver._DOF_JACOBIAN_STEP`
_DEFAULT_RANK_RTOL = 1e-6  # singular values <= rtol * sigma_max count as zero
_MOBILITY_TOL = 1e-6  # block singular values of the unit-normalised basis

Delta = tuple[float, float, float, float, float, float]


class GroupError(ValueError):
    """The requested group cannot be formed (grabbed occurrence unknown or frozen)."""


def apply_delta(base: RigidTransform, delta) -> RigidTransform:
    """`base` perturbed by `[dx dy dz rx ry rz]` - translation added, rotation
    vector (radians) composed onto the stored rotation. The exact convention
    `assembly_solver._free_motion` differentiates in, so bases from either
    are interchangeable."""
    rx, ry, rz = float(delta[3]), float(delta[4]), float(delta[5])
    angle = math.sqrt(rx * rx + ry * ry + rz * rz)
    dq = (
        (1.0, 0.0, 0.0, 0.0)
        if angle < 1e-12
        else _quaternion_from_axis_angle((rx / angle, ry / angle, rz / angle), math.degrees(angle))
    )
    q = _quaternion_multiply(dq, _quaternion_from_axis_angle(base.rotation_axis, base.rotation_angle_degrees))
    axis, degrees = _axis_angle_from_quaternion(q)
    translation = (base.translation[0] + delta[0], base.translation[1] + delta[1], base.translation[2] + delta[2])
    return RigidTransform(translation=translation, rotation_axis=axis, rotation_angle_degrees=degrees)


# ---- component discovery ---------------------------------------------------


@dataclass
class GroupComponent:
    member_ids: tuple[str, ...]  # variables; grabbed first, then part.occurrences order
    frozen_ids: tuple[str, ...]  # frozen occurrences (incl. "") the component's mates touch
    mates: tuple[Mate, ...]  # every non-suppressed mate with >= 1 member reference
    grounded: bool  # some mate ties the component to a frozen occurrence / the focused part


def _live_mates(part: Part) -> list[Mate]:
    return [m for m in part.mates if not m.suppressed and len(m.references) == 2]


def discover_component(part: Part, grabbed_id: str, also_frozen: frozenset[str] = frozenset()) -> GroupComponent:
    """The mate-graph component containing `grabbed_id`. `also_frozen` adds
    extra frozen ids (freezing every peer reproduces the single-occurrence
    analysis of `_free_motion`, used as the parity check)."""
    by_id = {o.id: o for o in part.occurrences}
    frozen = {o.id for o in part.occurrences if o.fixed} | {""} | set(also_frozen)
    if grabbed_id not in by_id:
        raise GroupError(f"unknown occurrence {grabbed_id!r}")
    if grabbed_id in frozen:
        raise GroupError(f"occurrence {grabbed_id!r} is frozen (fixed)")

    mates = _live_mates(part)
    adjacency: dict[str, set[str]] = {}
    for mate in mates:
        a, b = mate.references[0].occurrence_id, mate.references[1].occurrence_id
        if a == b or a in frozen or b in frozen:
            continue
        adjacency.setdefault(a, set()).add(b)
        adjacency.setdefault(b, set()).add(a)

    seen = {grabbed_id}
    stack = [grabbed_id]
    while stack:
        for nxt in adjacency.get(stack.pop(), ()):
            if nxt not in seen:
                seen.add(nxt)
                stack.append(nxt)

    order = {o.id: i for i, o in enumerate(part.occurrences)}
    members = (grabbed_id, *sorted(seen - {grabbed_id}, key=lambda oid: order.get(oid, len(order))))

    used: list[Mate] = []
    touched_frozen: set[str] = set()
    for mate in mates:
        ids = [r.occurrence_id for r in mate.references]
        if ids[0] == ids[1] or not any(i in seen for i in ids):
            continue
        used.append(mate)
        touched_frozen.update(i for i in ids if i in frozen)
    frozen_ids = tuple(sorted(touched_frozen))
    return GroupComponent(members, frozen_ids, tuple(used), grounded=bool(touched_frozen))


# ---- residual model ---------------------------------------------------------


@dataclass
class _Side:
    occurrence_id: str
    geometry: _ResolvedGeometry  # local to its target part
    frozen_transform: RigidTransform | None  # None for a member, or for the "" ref (identity)


@dataclass
class GroupModel:
    component: GroupComponent
    base_transforms: dict[str, RigidTransform]  # stored pose of every member
    sides: list[tuple[Mate, _Side, _Side]]  # (mate, first, second) - see `_orient`
    _index: dict[str, int] = field(default_factory=dict)

    @property
    def member_ids(self) -> tuple[str, ...]:
        return self.component.member_ids

    @property
    def n_vars(self) -> int:
        return 6 * len(self.component.member_ids)

    def residual(self, x=None, poses: dict[str, RigidTransform] | None = None) -> np.ndarray:
        """Stacked mate residual at `poses` (default: stored) perturbed by
        `x` (`6k`, member order; default zero)."""
        base = self.base_transforms if poses is None else poses
        placed: dict[str, RigidTransform] = {}
        for oid, i in self._index.items():
            delta = None if x is None else x[6 * i : 6 * i + 6]
            placed[oid] = base[oid] if delta is None or not np.any(delta) else apply_delta(base[oid], delta)
        out: list[float] = []
        for mate, a, b in self.sides:
            out.extend(_mate_residual_vector(mate, self._world(a, placed), self._world(b, placed)))
        return np.asarray(out, dtype=float)

    @staticmethod
    def _world(side: _Side, placed: dict[str, RigidTransform]) -> _ResolvedGeometry:
        transform = placed.get(side.occurrence_id, side.frozen_transform)
        return side.geometry if transform is None else _place_in_world(side.geometry, transform)

    def jacobian(self, poses: dict[str, RigidTransform] | None = None, step: float = _JACOBIAN_STEP) -> np.ndarray:
        """Central-difference Jacobian (rows = residuals, `6k` columns)."""
        n = self.n_vars
        rows = len(self.residual(None, poses))
        jac = np.zeros((rows, n))
        for i in range(n):
            e = np.zeros(n)
            e[i] = step
            jac[:, i] = (self.residual(e, poses) - self.residual(-e, poses)) / (2 * step)
        return jac


def build_group_model(
    document: Document, part: Part, grabbed_id: str, also_frozen: frozenset[str] = frozenset()
) -> GroupModel:
    """Discover the component and resolve every mate's geometry once (local
    frames; poses are applied per evaluation). May raise the HTTPException
    `assembly_solver` raises for an unresolvable occurrence / unsupported
    geometry - callers at the HTTP layer already handle that shape."""
    component = discover_component(part, grabbed_id, also_frozen)
    occurrences = {o.id: o for o in part.occurrences}
    members = set(component.member_ids)
    bodies_cache: dict[str, dict] = {}

    def side(ref) -> _Side:
        target, transform = _target_part_and_transform(document, part, ref.occurrence_id)
        if target.id not in bodies_cache:
            bodies_cache[target.id] = compute_part_bodies(target)
        geometry = _resolve_local_geometry(target, bodies_cache[target.id], ref)
        return _Side(ref.occurrence_id, geometry, None if ref.occurrence_id in members else transform)

    sides = []
    for mate in component.mates:
        first, second = mate.references
        # Orient like `_applicable_mates`: the movable side is "driven" when
        # the other side is frozen (the residual is only sign-asymmetric).
        if first.occurrence_id not in members and second.occurrence_id in members:
            first, second = second, first
        sides.append((mate, side(first), side(second)))

    model = GroupModel(
        component=component,
        base_transforms={oid: occurrences[oid].transform for oid in component.member_ids},
        sides=sides,
    )
    model._index = {oid: i for i, oid in enumerate(component.member_ids)}
    return model


# ---- lever arm ---------------------------------------------------------------


def bounding_radius(document: Document, part: Part, occurrence_id: str) -> float:
    """Default lever arm: half the diagonal of the occurrence's local bounding
    box (rotation-invariant), 1.0 for an empty part."""
    target, _ = _target_part_and_transform(document, part, occurrence_id)
    box = Bnd_Box()
    for shape in compute_part_bodies(target).values():
        brepbndlib.Add(shape, box)
    if box.IsVoid():
        return 1.0
    x0, y0, z0, x1, y1, z1 = box.Get()
    return max(0.5 * math.sqrt((x1 - x0) ** 2 + (y1 - y0) ** 2 + (z1 - z0) ** 2), 1e-6)


# ---- analysis ----------------------------------------------------------------


@dataclass
class GroupQuality:
    residual_inf: float  # max |residual| at the stored poses (inconsistent mates show here)
    sigma_min: float | None  # smallest RETAINED singular value (weighted J); None if rank 0
    sigma_gap: float | None  # sigma_min / largest DROPPED singular value (floored at eps*sigma_max);
    # small = near a rank change, None if rank 0


@dataclass
class GroupAnalysis:
    member_ids: tuple[str, ...]
    frozen_ids: tuple[str, ...]
    dof: int  # 6k - rank(J)
    rank: int
    grounded: bool
    lever_arm: float
    basis: np.ndarray  # (dof, 6k) rows, orthonormal in metric diag(1,1,1,L,L,L) per member
    mobility: dict[str, int]  # rank of each member's 6-column block of the basis
    quality: GroupQuality
    singular_values: np.ndarray


def relative_rank(singular_values: np.ndarray, rtol: float = _DEFAULT_RANK_RTOL) -> int:
    if singular_values.size == 0 or singular_values[0] <= 0.0:
        return 0
    return int(np.sum(singular_values > rtol * singular_values[0]))


def analyze_model(model: GroupModel, lever_arm: float, rank_rtol: float = _DEFAULT_RANK_RTOL) -> GroupAnalysis:
    n = model.n_vars
    k = len(model.member_ids)
    comp = model.component
    weights = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm] * k)
    residual0 = model.residual()
    jac = model.jacobian()
    if jac.shape[0] == 0:
        rank, svals, vt = 0, np.zeros(0), np.eye(n)
    else:
        # Weighted variables y = W x make translation and rotation columns
        # commensurate, so the rank tolerance and conditioning are meaningful.
        _u, svals, vt_full = np.linalg.svd(jac / weights, full_matrices=True)
        rank = relative_rank(svals, rank_rtol)
        vt = vt_full
    null_y = vt[rank:]  # (dof, n): orthonormal in y == orthonormal in the weighted metric
    basis = null_y / weights
    mobility = {
        oid: int(np.linalg.matrix_rank(null_y[:, 6 * i : 6 * i + 6], tol=_MOBILITY_TOL)) if null_y.size else 0
        for i, oid in enumerate(comp.member_ids)
    }
    sigma_min = sigma_gap = None
    if rank > 0:
        sigma_min = float(svals[rank - 1])
        dropped = float(svals[rank]) if rank < svals.size else 0.0
        sigma_gap = sigma_min / max(dropped, np.finfo(float).eps * float(svals[0]))
    return GroupAnalysis(
        member_ids=comp.member_ids,
        frozen_ids=comp.frozen_ids,
        dof=n - rank,
        rank=rank,
        grounded=comp.grounded,
        lever_arm=lever_arm,
        basis=basis,
        mobility=mobility,
        quality=GroupQuality(
            residual_inf=float(np.max(np.abs(residual0))) if residual0.size else 0.0,
            sigma_min=sigma_min,
            sigma_gap=sigma_gap,
        ),
        singular_values=svals,
    )


def analyze_group(
    document: Document,
    part: Part,
    grabbed_id: str,
    lever_arm: float | None = None,
    also_frozen: frozenset[str] = frozenset(),
    rank_rtol: float = _DEFAULT_RANK_RTOL,
) -> GroupAnalysis:
    """Group DOF / grounded / basis / mobility / quality for the component of
    `grabbed_id`. `lever_arm` defaults to the grabbed occurrence's bounding radius."""
    model = build_group_model(document, part, grabbed_id, also_frozen)
    if lever_arm is None:
        lever_arm = bounding_radius(document, part, grabbed_id)
    return analyze_model(model, lever_arm, rank_rtol)
