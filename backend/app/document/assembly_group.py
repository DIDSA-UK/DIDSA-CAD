"""Constrained drag, sessions S1-S2 (`docs/constrained-drag-implementation-plan.md`):
the GROUP model and its solve - pure functions, no HTTP, no direct `py_slvs` use (only the
single-occurrence fallback seed calls `assembly_solver.solve_occurrence_from_guess`).

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

`solve_group` (S2, bottom of this file) is the weighted Gauss-Newton retraction built on
`GroupModel`; nothing here stores anything.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field, replace

import numpy as np
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib

from app.document.assembly_solver import (
    _axis_angle_from_quaternion,
    _axis_perpendicular,
    _cross,
    _dot,
    _mate_residual_vector,
    _normalize,
    _place_in_world,
    _quaternion_from_axis_angle,
    _quaternion_multiply,
    _resolve_local_geometry,
    _ResolvedGeometry,
    _target_part_and_transform,
    _vec_sub,
    solve_occurrence_from_guess,
)
from app.document.extrude import compute_part_bodies
from app.document.models import Document, Mate, MateType, Part, RigidTransform

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
        if mate.type == MateType.ANGLE and mate.flipped and mate.value is not None:
            # `_mate_residual_vector` ignores `flipped`; py-slvs' `addAngle`
            # uses it as the supplement toggle, so solve for 180 - value.
            t = abs(mate.value) % 360.0
            mate = replace(mate, value=180.0 - min(t, 360.0 - t))
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


# ---- group solve: weighted retraction (S2) -----------------------------------

_SOLVE_TOL = 1e-7  # residual_inf at or below this = converged
_MAX_ITERATIONS = 60
_MAX_ROTATION_STEP = 0.6  # rad per Gauss-Newton step (any member) before scaling down
_FOLLOWER_WEIGHT = 1e-4  # follower metric = this x the grabbed metric (follower cost ~ 0)
_PINV_RCOND = 1e-9


@dataclass
class GroupSolveQuality:
    residual_inf: float
    jump: float | None  # weighted distance (grabbed block) between the solved pose and the first-order prediction
    iterations: int
    seeded_by: str  # "gauss-newton" | "slvs-fallback"


@dataclass
class GroupSolveResult:
    converged: bool
    poses: dict[str, RigidTransform]  # every member; best effort when not converged
    analysis: GroupAnalysis | None  # at the solved poses; None when not converged (clients must not read "no basis" as "free")
    quality: GroupSolveQuality

    @property
    def dof(self) -> int | None:
        return None if self.analysis is None else self.analysis.dof


def _rotvec_between(new: RigidTransform, old: RigidTransform) -> np.ndarray:
    """Rotation vector (rad) `w` with `exp(w) * R_old = R_new` - the chart `apply_delta` uses."""
    q = _quaternion_multiply(
        _quaternion_from_axis_angle(new.rotation_axis, new.rotation_angle_degrees),
        _quaternion_from_axis_angle(old.rotation_axis, -old.rotation_angle_degrees),
    )
    if q[0] < 0.0:
        q = tuple(-c for c in q)
    sin_half = math.sqrt(q[1] ** 2 + q[2] ** 2 + q[3] ** 2)
    if sin_half < 1e-15:
        return np.zeros(3)
    angle = 2.0 * math.atan2(sin_half, q[0])
    return np.array(q[1:]) / sin_half * angle


def pose_delta(new: RigidTransform, old: RigidTransform) -> np.ndarray:
    """`[dx dy dz rx ry rz]` taking `old` to `new` (inverse of `apply_delta`)."""
    return np.concatenate([np.array(new.translation) - np.array(old.translation), _rotvec_between(new, old)])


def _rotate_member(poses: dict[str, RigidTransform], oid: str, rotvec) -> None:
    poses[oid] = apply_delta(poses[oid], (0.0, 0.0, 0.0, *rotvec))


def _translate_member(poses: dict[str, RigidTransform], oid: str, vector) -> None:
    poses[oid] = apply_delta(poses[oid], (*vector, 0.0, 0.0, 0.0))


def _minimal_rotvec(source, target) -> np.ndarray:
    """Rotation vector of the minimal rotation taking unit `source` onto unit `target`."""
    a, b = np.array(_normalize(tuple(source))), np.array(_normalize(tuple(target)))
    axis = np.cross(a, b)
    norm = float(np.linalg.norm(axis))
    angle = math.atan2(norm, float(a @ b))
    if norm < 1e-12:
        if a @ b > 0:
            return np.zeros(3)
        axis, norm = np.array(_axis_perpendicular(tuple(a))), 1.0
    return axis / norm * angle


def _seed_poses(model: GroupModel, poses: dict[str, RigidTransform]) -> None:
    """Move members off the states plain Gauss-Newton on `_mate_residual_vector`
    cannot leave: the residuals are sign-agnostic (`flipped` is invisible to
    them) or have a zero gradient there. Only these cases are touched - anywhere
    else the retraction itself keeps the nearest solution:

    * COINCIDENT plane-plane not facing the right way -> minimal rotation onto the
      flipped/unflipped target (the same seed the py-slvs path uses);
    * ANGLE at a (anti)aligned start (gradient of the dot product vanishes) ->
      rotate onto the target angle about an axis perpendicular to the fixed one
      (this is the S2 fix for the singular start);
    * DISTANCE closer than a quarter of its value to zero separation (the
      squared residual has zero gradient at 0) -> slide out along the
      separation direction to exactly the target (the nearest solution anyway).
    The mover is always the mate's first side (`build_group_model` orients it)."""
    for mate, first, second in model.sides:
        placed = {oid: poses[oid] for oid in model.member_ids}
        d, f = model._world(first, placed), model._world(second, placed)
        mover = first.occurrence_id
        if mate.type == MateType.COINCIDENT and d.plane is not None and f.plane is not None:
            target = f.plane.normal if mate.flipped else tuple(-c for c in f.plane.normal)
            # Frozen partner: align fully (minimal rotation = the nearest orientation, the same
            # seed py-slvs gets). Member partner: only undo a wrong-way facing.
            if second.occurrence_id not in poses or _dot(_normalize(d.plane.normal), _normalize(target)) < 0.0:
                _rotate_member(poses, mover, _minimal_rotvec(d.plane.normal, target))
        elif mate.type == MateType.ANGLE and d.direction is not None and f.direction is not None and mate.value is not None:
            nd, nf = _normalize(d.direction), _normalize(f.direction)
            dot = _dot(nd, nf)
            if abs(dot) > 1.0 - 5e-7:
                t = abs(mate.value) % 360.0
                t = math.radians(min(t, 360.0 - t))
                axis = np.array(_axis_perpendicular(nf))
                _rotate_member(poses, mover, axis * (t if dot > 0 else math.pi - t))
        elif mate.type == MateType.DISTANCE and mate.value:
            target = abs(mate.value)
            state = _distance_state(d, f)
            if state is not None and abs(state[0]) < 0.25 * target:
                current, direction, kind = state
                sign = -1.0 if kind == "signed" and current < 0.0 else 1.0
                _translate_member(poses, mover, np.array(direction) * (sign * target - current))


def _distance_state(d: _ResolvedGeometry, f: _ResolvedGeometry):
    """`(separation, unit direction the mover slides along to increase it, kind)` for
    the geometry pairs a DISTANCE mate accepts, mirroring `_mate_residual_vector`'s branches."""
    if d.plane is not None and f.plane is not None:
        n = _normalize(f.plane.normal)
        return _dot(_vec_sub(d.plane.origin, f.plane.origin), n), n, "signed"
    if d.plane is not None and f.point is not None:
        n = _normalize(d.plane.normal)
        return _dot(_vec_sub(f.point, d.plane.origin), n), tuple(-c for c in n), "signed"
    if f.plane is not None and d.point is not None:
        n = _normalize(f.plane.normal)
        return _dot(_vec_sub(d.point, f.plane.origin), n), n, "signed"
    if d.axis_origin is not None and d.direction is not None and f.axis_origin is not None and f.direction is not None:
        axis = _normalize(f.direction)
        offset = _vec_sub(d.axis_origin, f.axis_origin)
        radial = tuple(o - _dot(offset, axis) * a for o, a in zip(offset, axis))
        length = math.sqrt(_dot(radial, radial))
        direction = _axis_perpendicular(axis) if length < 1e-12 else tuple(c / length for c in radial)
        return length, direction, "unsigned"
    if d.point is not None and f.point is not None:
        offset = _vec_sub(d.point, f.point)
        length = math.sqrt(_dot(offset, offset))
        direction = (1.0, 0.0, 0.0) if length < 1e-12 else tuple(c / length for c in offset)
        return length, direction, "unsigned"
    return None


def _solve_weights(model: GroupModel, grabbed_id: str, lever_arm: float) -> np.ndarray:
    base = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])
    return np.concatenate([base if oid == grabbed_id else base * _FOLLOWER_WEIGHT for oid in model.member_ids])


def _retract(model: GroupModel, poses: dict[str, RigidTransform], weights: np.ndarray) -> tuple[dict, float, int]:
    """Weighted minimum-norm Gauss-Newton from `poses` onto `residual == 0`:
    `dx = -W^-1 pinv(J W^-1) r` (the least step in the metric `W`), with a
    rotation-step cap and residual-decrease backtracking. Returns `(poses, residual_inf, iterations)`."""
    ids = model.member_ids
    n = len(ids)

    def resid(p):
        return model.residual(None, p)

    r = resid(poses)
    iterations = 0
    while r.size and float(np.max(np.abs(r))) > _SOLVE_TOL and iterations < _MAX_ITERATIONS:
        iterations += 1
        jac = model.jacobian(poses)
        dx = -(np.linalg.pinv(jac / weights, rcond=_PINV_RCOND) @ r) / weights
        rot = np.array([np.linalg.norm(dx[6 * i + 3 : 6 * i + 6]) for i in range(n)])
        if rot.max() > _MAX_ROTATION_STEP:
            dx *= _MAX_ROTATION_STEP / rot.max()
        alpha, norm0 = 1.0, float(np.linalg.norm(r))
        for _ in range(12):
            trial = {oid: apply_delta(poses[oid], alpha * dx[6 * i : 6 * i + 6]) for i, oid in enumerate(ids)}
            r_trial = resid(trial)
            if float(np.linalg.norm(r_trial)) < norm0:
                poses, r = trial, r_trial
                break
            alpha *= 0.5
        else:
            break  # no decrease along the step: stalled (conflicting / unreachable)
    return poses, float(np.max(np.abs(r))) if r.size else 0.0, iterations


def solve_group(
    document: Document,
    part: Part,
    grabbed_id: str,
    wanted_pose: RigidTransform | None = None,
    lever_arm: float | None = None,
    also_frozen: frozenset[str] = frozenset(),
) -> GroupSolveResult:
    """Nearest mate-satisfying configuration of the whole group to the wish:
    the grabbed member seeded at `wanted_pose` (`None` = its stored pose), the
    others at their stored poses; weighted Gauss-Newton on the stacked mate
    residuals in the metric `diag(1,1,1,L,L,L)` per member with follower
    weights ~ 0 (`_FOLLOWER_WEIGHT`), so mated neighbours move only as the
    mates require. Verified by `residual_inf`, never by a solver code.
    Nothing is stored. Not converged -> `analysis is None` (no basis).

    A single-member group that Gauss-Newton fails on is retried from the
    py-slvs single-occurrence solution (`solve_occurrence_from_guess`) as a
    seed - py-slvs is a fallback seed only, never the verifier."""
    model = build_group_model(document, part, grabbed_id, also_frozen)
    if lever_arm is None:
        lever_arm = bounding_radius(document, part, grabbed_id)
    weights = _solve_weights(model, grabbed_id, lever_arm)
    stored = dict(model.base_transforms)

    seed = dict(stored)
    if wanted_pose is not None:
        seed[grabbed_id] = wanted_pose
    _seed_poses(model, seed)
    poses, residual_inf, iterations = _retract(model, seed, weights)
    seeded_by = "gauss-newton"

    if residual_inf > _SOLVE_TOL and len(model.member_ids) == 1:
        guess = wanted_pose if wanted_pose is not None else stored[grabbed_id]
        fallback = solve_occurrence_from_guess(document, part, grabbed_id, guess)
        if fallback.converged:
            poses, residual_inf, more = _retract(model, {grabbed_id: fallback.transform}, weights)
            iterations += more
            seeded_by = "slvs-fallback"

    converged = residual_inf <= _SOLVE_TOL
    analysis, jump = None, None
    if converged:
        solved = replace(model, base_transforms=dict(poses))
        analysis = analyze_model(solved, lever_arm)
        jump = _jump(model, stored, poses, seed_wish=wanted_pose, grabbed_id=grabbed_id, lever_arm=lever_arm)
    return GroupSolveResult(
        converged=converged,
        poses=poses,
        analysis=analysis,
        quality=GroupSolveQuality(residual_inf=residual_inf, jump=jump, iterations=iterations, seeded_by=seeded_by),
    )


def _jump(model: GroupModel, stored, solved, seed_wish, grabbed_id: str, lever_arm: float) -> float:
    """Distance (grabbed block, metric diag(1,1,1,L,L,L)) between where the solve landed and
    where a client projecting the wish onto the STORED pose's free-motion basis would have put
    the grabbed member - how far the first-order model was off (curved mates), i.e. the pop a
    re-anchor would cause."""
    ids = model.member_ids
    at_rest = replace(model, base_transforms=dict(stored))
    analysis = analyze_model(at_rest, lever_arm)
    w = _solve_weights(model, grabbed_id, lever_arm)
    want = np.zeros(6 * len(ids))
    if seed_wish is not None:
        want[:6] = pose_delta(seed_wish, stored[grabbed_id])
    predicted = np.zeros_like(want)
    if analysis.basis.size:
        nb = analysis.basis  # rows; solve min |W (N^T c - want)| over c
        a = (nb * w) @ (nb * w).T
        c = np.linalg.solve(a + 1e-12 * np.eye(len(a)), (nb * w) @ (want * w))
        predicted = nb.T @ c
    actual = np.concatenate([pose_delta(solved[oid], stored[oid]) for oid in ids])
    g = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])
    return float(np.linalg.norm((actual[:6] - predicted[:6]) * g))
