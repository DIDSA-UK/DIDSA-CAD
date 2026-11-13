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
import time
from collections import deque
from dataclasses import dataclass, field, replace
from typing import Callable, Iterable

import numpy as np
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib

from app.document.appearance import PATTERN_SEGMENT
from app.document.assembly import (
    mate_drivers,
    mate_ref_drivers,
    mate_tops,
    parse_pattern_segment,
    pattern_copy_pose,
    top_level_occurrence_id,
)
from app.document.assembly_solver import (
    _axis_angle_from_quaternion,
    _angle_hinge,
    _angle_target_radians,
    _effective_mate,
    alignment_pairs,
    hinge_swing_state,
    apply_flipped_alias,
    branch_fields,
    resolve_oriented_branch,
    rotation_onto_pairs,
    sync_flipped,
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
    cross_midplane_geometry,
    midplane_spans_tops,
    _unsupported_mate_geometry,
    _vec_sub,
    solve_occurrence_from_guess,
)
from app.document.coupler import coupler_rows, is_coupler, travel_along, turn_about
from app.document.limit import is_limit, limit_value, row_unit, violated_bound
from app.document.mate_tolerance import is_within_tolerance, physical_residual
from app.document.constraint_model import (
    ConstraintModel,
    export_constraint_model,
    log_delta,
    pose_to_rigid,
    residual_inf as _model_residual_inf,
    rigid_to_pose,
    screw_exp,
    screw_log,
    sqp_nearest,
    rotvec_from_rot,
    weights as _local_weights,
    wish_cost,
)
from app.document.extrude import compute_part_bodies
from app.document.models import BRANCH_AUTO, BRANCH_USER, MATE_ALIGNED, MATE_ANTI_ALIGNED, ComponentPattern, Document, Mate, MateEntityRef, MateType, Part, ResolvedPlane, RigidTransform

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


def _copies_frozen(mate: Mate) -> bool:
    return is_coupler(mate) or is_limit(mate)


def _graph_ids(mate: Mate) -> tuple[str, ...]:
    """The occurrences a mate joins in the graph: its drivers (copies folded to their source), except for a coupler / limit mate."""
    return mate_tops(mate) if _copies_frozen(mate) else mate_drivers(mate)


def discover_component(
    part: Part, grabbed_id: str, also_frozen: frozenset[str] = frozenset(), extra_mates: tuple[Mate, ...] = ()
) -> GroupComponent:
    """The mate-graph component containing `grabbed_id`. `also_frozen` adds
    extra frozen ids (freezing every peer reproduces the single-occurrence
    analysis of `_free_motion`, used as the parity check). `extra_mates` are
    hypothetical mates (never in `part.mates`) joined to the graph - the
    New-Mate ghost preview."""
    by_id = {o.id: o for o in part.occurrences}
    frozen = {o.id for o in part.occurrences if o.fixed} | {""} | set(also_frozen)
    # A pattern copy (`<src>#pattern:<pid>:<i>`) is rigidly derived from its source: for the graph a mate on a copy is a mate on its
    # SOURCE (`mate_drivers`), and the copy follows the source's pose inside a solve (`_Side.follow`). Only a coupler or a limit mate
    # (which measure motion of the side's own body: not expressible through a follower) keeps the older rule: its copy side is
    # frozen at the source's STORED pose and takes no part in the graph.
    for mate in [*_live_mates(part), *extra_mates]:
        if _copies_frozen(mate):
            frozen.update(t for t in mate_tops(mate) if PATTERN_SEGMENT in t)
    if grabbed_id not in by_id:
        raise GroupError(f"unknown occurrence {grabbed_id!r}")
    if grabbed_id in frozen:
        raise GroupError(f"occurrence {grabbed_id!r} is frozen (fixed)")

    mates = [*_live_mates(part), *(m for m in extra_mates if len(m.references) == 2)]
    adjacency: dict[str, set[str]] = {}
    for mate in mates:
        # A mate joins every movable occurrence it involves (a Width mate over two parts involves up to four).
        movable = [t for t in _graph_ids(mate) if t not in frozen]
        for a in movable:
            for b in movable:
                if a != b:
                    adjacency.setdefault(a, set()).add(b)

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
        ids = _graph_ids(mate)
        if len(ids) < 2 or not any(i in seen for i in ids):
            continue
        used.append(mate)
        touched_frozen.update(i for i in ids if i in frozen)
    frozen_ids = tuple(sorted(touched_frozen))
    return GroupComponent(members, frozen_ids, tuple(used), grounded=bool(touched_frozen))


# ---- residual model ---------------------------------------------------------


def _midway(first: _ResolvedGeometry, second: _ResolvedGeometry) -> _ResolvedGeometry:
    """The plane midway between two world planes (origin = average, orientation = the first's) - `midplane_of_resolved` without
    its parallel check, which the solver's intermediate poses need (parallelism is held by the residual instead)."""
    a, b = first.plane, second.plane
    origin = tuple((x + y) / 2.0 for x, y in zip(a.origin, b.origin))
    plane = ResolvedPlane(origin=origin, normal=a.normal, x_axis=a.x_axis, y_axis=a.y_axis)
    return _ResolvedGeometry(point=origin, plane=plane, direction=a.normal)


@dataclass
class _Side:
    occurrence_id: str
    geometry: _ResolvedGeometry  # local to its target part
    frozen_transform: RigidTransform | None  # None for a member, or for the "" ref (identity)
    # A Width side whose second face is under another top-level occurrence: this side is the FIRST face's plane, `partner` the
    # second face's. The side's world geometry is the plane midway between the two at the pose being evaluated, and the mate
    # also keeps the two faces parallel (`GroupModel.residual`). None for every other side.
    partner: "_Side | None" = None
    # A reference on a pattern copy whose SOURCE is a member of the group: `occurrence_id` is the source, and the side's world pose
    # is the copy's pose at the source's pose being evaluated (`assembly.pattern_copy_pose`): the copy follows the source.
    follow: tuple[ComponentPattern, int] | None = None


@dataclass
class GroupModel:
    component: GroupComponent
    base_transforms: dict[str, RigidTransform]  # stored pose of every member
    sides: list[tuple[Mate, _Side, _Side]]  # (mate, first, second) - see `_orient`
    _index: dict[str, int] = field(default_factory=dict)
    _spec: dict | bool | None = field(default=None, repr=False)  # cached constraint model (False = not exportable)
    # `{mate_id: (alignment, secondary_flip)}`: the branch each mate of the component resolved to, in the convention it is stored in
    # (relative to its `references` order); `sides` carry the same branch in this model's own orientation.
    branches: dict[str, tuple[str | None, bool | None]] = field(default_factory=dict)
    # Limit mates (`app.document.limit`) are inequalities: they add NO rows unless listed here, `{mate_id: bound}` - the limits a solve
    # is currently holding at a bound (`solve_group`'s active set). A listed limit adds the row `value - bound`.
    active_limits: dict[str, float] = field(default_factory=dict)
    # M1 (`app.document.rigid_sets`): set on a REDUCED model, whose members are rigid-set leads (`rigid_sets.Reduction`); None otherwise.
    rigid: object | None = field(default=None, repr=False)
    # M1.1: the Part state this model was built from (`_model_cache_key` without the call's own arguments), when it came through the
    # cache; `rigid_sets.detect` keys on it instead of re-reading every side. None for a model built any other way.
    state_key: tuple | None = field(default=None, repr=False)

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
            if is_coupler(mate):
                out.extend(self._coupler_rows(mate, a, b, placed))
                continue
            if is_limit(mate):
                if mate.id in self.active_limits:
                    out.append((self.limit_value(mate, a, b, placed) - self.active_limits[mate.id]) * row_unit(mate))
                continue
            out.extend(_mate_residual_vector(mate, self._world(a, placed), self._world(b, placed)))
            for side in (a, b):
                if side.partner is not None:
                    out.extend(self._parallel_rows(side, placed))
        return np.asarray(out, dtype=float)

    def limit_value(self, mate: Mate, a: _Side, b: _Side, placed: dict[str, RigidTransform]) -> float:
        value = limit_value(mate, self._world(a, placed), self._world(b, placed))
        if value is None:
            raise ValueError(f"limit mate {mate.id} has no measurable value")
        return value

    def violated_limits(self, poses: dict[str, RigidTransform] | None = None) -> dict[str, float]:
        """`{mate_id: bound}` of the limits (not already held) whose range the `poses` (default: stored) leave."""
        placed = dict(self.base_transforms if poses is None else poses)
        out: dict[str, float] = {}
        for mate, a, b in self.sides:
            if is_limit(mate) and mate.id not in self.active_limits:
                bound = violated_bound(mate, self.limit_value(mate, a, b, placed))
                if bound is not None:
                    out[mate.id] = bound
        return out

    def has_limits(self) -> bool:
        return any(is_limit(m) for m, _a, _b in self.sides)

    def _coupler_rows(self, mate: Mate, a: _Side, b: _Side, placed: dict[str, RigidTransform]) -> list[float]:
        """The row of a coupler mate (`app.document.coupler`): each side's turn and travel since the BASE pose, about / along its
        axis as it stood at the base pose. A side that is not a member (fixed, or the root part's own geometry) does not move."""

        def base_axis(side: _Side) -> np.ndarray:
            direction = np.array(side.geometry.direction, float)
            direction /= float(np.linalg.norm(direction))
            if side.occurrence_id in self._index:
                return rigid_to_pose(self.base_transforms[side.occurrence_id])[0] @ direction
            if side.frozen_transform is not None:
                return rigid_to_pose(side.frozen_transform)[0] @ direction
            return direction

        def motion(side: _Side, axis: np.ndarray) -> tuple[float, float]:
            if side.occurrence_id not in self._index:
                return 0.0, 0.0
            r0, t0 = rigid_to_pose(self.base_transforms[side.occurrence_id])
            r, t = rigid_to_pose(placed[side.occurrence_id])
            point = np.array(side.geometry.axis_origin, float)
            return turn_about(r, r0, axis), travel_along(point, r, t, r0, t0, axis)

        axis_a, axis_b = base_axis(a), base_axis(b)
        if mate.type == MateType.GEAR:
            return coupler_rows(mate, motion(a, axis_a)[0], 0.0, motion(b, axis_b)[0], 0.0)
        if mate.type == MateType.RACK_PINION:
            return coupler_rows(mate, motion(a, axis_a)[0], 0.0, 0.0, motion(b, axis_b)[1])
        turn_a, move_a = motion(a, axis_a)
        turn_b, move_b = motion(b, axis_a)  # a screw: everything along / about the screw's axis
        return coupler_rows(mate, turn_a, move_a, turn_b, move_b)

    @staticmethod
    def _world_one(side: _Side, placed: dict[str, RigidTransform]) -> _ResolvedGeometry:
        transform = placed.get(side.occurrence_id, side.frozen_transform)
        if transform is not None and side.follow is not None:
            transform = pattern_copy_pose(side.follow[0], transform, side.follow[1])
        return side.geometry if transform is None else _place_in_world(side.geometry, transform)

    @staticmethod
    def _world(side: _Side, placed: dict[str, RigidTransform]) -> _ResolvedGeometry:
        one = GroupModel._world_one(side, placed)
        if side.partner is None:
            return one
        return _midway(one, GroupModel._world_one(side.partner, placed))

    @staticmethod
    def _parallel_rows(side: _Side, placed: dict[str, RigidTransform]) -> tuple[float, float, float]:
        """The two faces of a cross-occurrence Width side stay parallel: the cross product of their unit normals (3 rows, rank 2)."""
        n1 = _normalize(GroupModel._world_one(side, placed).plane.normal)
        n2 = _normalize(GroupModel._world_one(side.partner, placed).plane.normal)
        return _cross(n1, n2)

    def jacobian(self, poses: dict[str, RigidTransform] | None = None, step: float = _JACOBIAN_STEP) -> np.ndarray:
        """Jacobian (rows = residuals, `6k` columns), analytic from the exported constraint model (forward mode, exact;
        ~10x cheaper than differences at k = 8). Falls back to central differences if the model cannot be exported or the
        caller asks for a specific `step`."""
        if step == _JACOBIAN_STEP:
            if self._spec is None:
                self._spec = export_constraint_model(self) or False
            if self._spec:
                base = self.base_transforms if poses is None else poses
                placed = [rigid_to_pose(base[oid]) for oid in self.member_ids]
                # a coupler's rows are measured from THIS model's base poses (a cached spec may carry the anchors of an earlier one)
                anchors = [rigid_to_pose(self.base_transforms[oid]) for oid in self.member_ids]
                return ConstraintModel(self._spec, anchors, active=self.active_limits).residual(placed)[1]
        return self._jacobian_differences(poses, step)

    def _jacobian_differences(self, poses: dict[str, RigidTransform] | None, step: float) -> np.ndarray:
        """Central-difference Jacobian (rows = residuals, `6k` columns)."""
        n = self.n_vars
        rows = len(self.residual(None, poses))
        jac = np.zeros((rows, n))
        for i in range(n):
            e = np.zeros(n)
            e[i] = step
            jac[:, i] = (self.residual(e, poses) - self.residual(-e, poses)) / (2 * step)
        return jac


# ---- the built-model cache (M1.1) ---------------------------------------------------------------------------------------
#
# `build_group_model` resolves every mate's geometry (OCCT face / edge measurements) and branch on every call: ~50 ms for the
# 50-plate chain, most of a drag anchor once rigid sets made the solve itself cheap. The model depends only on what
# `_model_cache_key` lists - the Part's mates, occurrences and component patterns, the features (and the sketches they read) of
# every Part it places, and the call's own arguments - so a re-anchor or a preview that changes none of them reuses it. Any mate,
# fix, suppress, pose, pattern, feature or sketch change misses. `model_cache_enabled = False` builds every time (tests compare).

model_cache_enabled = True
_MODEL_CACHE_SIZE = 32
_model_cache: "dict[tuple, GroupModel]" = {}
model_cache_stats = {"hits": 0, "misses": 0}


def clear_model_cache() -> None:
    _model_cache.clear()


def _placed_parts(document: Document, part: Part) -> list[Part]:
    """`part` and every Part it places, through sub-assemblies (each once, in a stable order)."""
    seen: dict[str, Part] = {}
    stack = [part]
    while stack:
        current = stack.pop()
        if current.id in seen:
            continue
        seen[current.id] = current
        for occurrence in current.occurrences:
            target = document.parts.get(occurrence.part_id) if occurrence.part_id is not None else None
            if target is not None and target.id not in seen:
                stack.append(target)
    return list(seen.values())


def _model_cache_key(document: Document, part: Part, grabbed_id: str, also_frozen: frozenset[str], extra_mates: tuple[Mate, ...]) -> tuple:
    from app.document.body_cache import feature_fingerprint

    geometry = tuple(
        (p.id, tuple(feature_fingerprint(f) for f in p.features), repr(p.occurrences) if p is not part else "", repr(p.component_patterns) if p is not part else "")
        for p in _placed_parts(document, part)
    )
    state = (part.id, repr(part.mates), repr(part.occurrences), repr(part.component_patterns), geometry)
    return (grabbed_id, tuple(sorted(also_frozen)), repr(extra_mates), state)


def build_group_model(
    document: Document,
    part: Part,
    grabbed_id: str,
    also_frozen: frozenset[str] = frozenset(),
    extra_mates: tuple[Mate, ...] = (),
) -> GroupModel:
    """`_build_group_model`, cached (see above). Each call gets its own `GroupModel` (its `branches` / `active_limits` copied), so a
    caller may `replace` its poses or limits freely; the resolved sides are shared and never changed after the build."""
    if not model_cache_enabled:
        return _build_group_model(document, part, grabbed_id, also_frozen, extra_mates)
    key = _model_cache_key(document, part, grabbed_id, also_frozen, extra_mates)
    cached = _model_cache.get(key)
    if cached is None:
        model_cache_stats["misses"] += 1
        cached = _build_group_model(document, part, grabbed_id, also_frozen, extra_mates)
        _model_cache[key] = cached
        while len(_model_cache) > _MODEL_CACHE_SIZE:
            _model_cache.pop(next(iter(_model_cache)))
    else:
        model_cache_stats["hits"] += 1
        _model_cache[key] = _model_cache.pop(key)  # most recently used last
    out = replace(
        cached,
        base_transforms=dict(cached.base_transforms),
        branches=dict(cached.branches),
        active_limits=dict(cached.active_limits),
        state_key=key[3],
    )
    out._index = dict(cached._index)
    return out


def _build_group_model(
    document: Document,
    part: Part,
    grabbed_id: str,
    also_frozen: frozenset[str] = frozenset(),
    extra_mates: tuple[Mate, ...] = (),
) -> GroupModel:
    """Discover the component and resolve every mate's geometry once (local
    frames; poses are applied per evaluation). May raise the HTTPException
    `assembly_solver` raises for an unresolvable occurrence / unsupported
    geometry - callers at the HTTP layer already handle that shape."""
    component = discover_component(part, grabbed_id, also_frozen, extra_mates)
    occurrences = {o.id: o for o in part.occurrences}
    members = set(component.member_ids)
    bodies_cache: dict[str, dict] = {}

    def single_side(ref, mate: Mate) -> _Side:
        # A reference into a sub-assembly (`outer/inner`) is carried by its
        # top-level Occurrence `outer`: the geometry is lifted into `outer`'s
        # own local frame so it moves with `outer` (a member) or sits at
        # `outer`'s fixed transform (a frozen peer).
        top_id = top_level_occurrence_id(ref.occurrence_id)
        top_part, top_transform = _target_part_and_transform(document, part, top_id)
        target, inner = _target_part_and_transform(document, top_part, ref.occurrence_id[len(top_id) + 1 :])
        if target.id not in bodies_cache:
            bodies_cache[target.id] = compute_part_bodies(target)
        geometry = _resolve_local_geometry(target, bodies_cache[target.id], ref, document, part)
        if inner is not None:
            geometry = _place_in_world(geometry, inner)
        copy = parse_pattern_segment(top_id)
        if copy is not None and copy[0] in members and not _copies_frozen(mate):
            # A pattern copy of a member: it follows its source (`follow`); the geometry is already local to the copy's own part.
            pattern = next(p for p in part.component_patterns if p.id == copy[1])
            return _Side(copy[0], geometry, None, follow=(pattern, copy[2]))
        return _Side(top_id, geometry, None if top_id in members else top_transform)

    def side(ref, mate: Mate) -> _Side:
        if not midplane_spans_tops(ref):
            return single_side(ref, mate)
        # A Width reference over two top-level occurrences: each face is its own side. With neither occurrence a member the
        # mid-plane never moves, so it collapses to one fixed world plane (the model stays a plain plane-plane one); otherwise
        # the first side carries the second as its `partner` and the plane is recomputed at every evaluated pose.
        mp = ref.midplane
        first = single_side(MateEntityRef(occurrence_id=ref.occurrence_id, plane_ref=mp.a), mate)
        second = single_side(MateEntityRef(occurrence_id=mp.b_occurrence_id, plane_ref=mp.b), mate)
        if first.occurrence_id not in members and second.occurrence_id not in members:
            plane = cross_midplane_geometry(document, part, ref).plane
            return _Side("", _ResolvedGeometry(point=plane.origin, plane=plane, direction=plane.normal), None)
        return replace(first, partner=second)

    sides = []
    swaps: list[bool] = []
    for mate in component.mates:
        first, second = mate.references
        # Orient like `_applicable_mates`: the movable side is "driven" when
        # the other side is frozen (the residual is only sign-asymmetric).
        swapped = (
            not is_coupler(mate)  # a coupler is never swapped: its rows are in the references' order
            and not is_limit(mate)  # nor is a limit: its value is measured in the references' order
            and not any(t in members for t in mate_ref_drivers(first))
            and any(t in members for t in mate_ref_drivers(second))
        )
        if swapped:
            first, second = second, first
        a_side, b_side = side(first, mate), side(second, mate)
        if mate.type in (MateType.ANGLE, MateType.LIMIT_ANGLE):
            a_side, b_side = _with_hinge(mate, component.mates, lambda r: side(r, mate), a_side, b_side)
        sides.append((mate, a_side, b_side))
        swaps.append(swapped)

    model = GroupModel(
        component=component,
        base_transforms={oid: occurrences[oid].transform for oid in component.member_ids},
        sides=sides,
    )
    model._index = {oid: i for i, oid in enumerate(component.member_ids)}
    # Closest -> a concrete branch: every mate that has not named its alignment / side yet takes the one the STORED poses
    # sit on, once, here - the residuals below are zero only on that branch, so a solve or drag started from these poses can
    # never end on another one. (A mate that names its branch keeps it; legacy files, which name none, therefore keep
    # their stored placement exactly.)
    placed = dict(model.base_transforms)
    resolved_sides = []
    for (mate, a, b), swapped in zip(model.sides, swaps):
        if is_coupler(mate):
            # no branch to resolve: the sense is stored (`secondary_flip` is never None on a coupler)
            model.branches[mate.id] = (None, mate.secondary_flip)
            resolved_sides.append((mate, a, b))
            continue
        if is_limit(mate):
            model.branches[mate.id] = (None, None)  # a limit has no branch
            resolved_sides.append((mate, a, b))
            continue
        # `mate` is resolved in the orientation this model uses (`swapped`: reference 1 is the mover); the branch it is stored
        # in (relative to the references' order, what a commit writes back) is kept in `model.branches`.
        mate, canonical = resolve_oriented_branch(mate, model._world(a, placed), model._world(b, placed), swapped)
        model.branches[mate.id] = (canonical.alignment, canonical.secondary_flip)
        if mate.type == MateType.ANGLE and mate.secondary_flip and mate.value is not None:
            # `_mate_residual_vector` has no supplement switch; py-slvs' `addAngle` does, so solve for 180 - value.
            t = abs(mate.value) % 360.0
            mate = replace(mate, value=180.0 - min(t, 360.0 - t))
        resolved_sides.append((mate, a, b))
    model.sides = resolved_sides
    # A mate whose two geometries can't form its residual (e.g. CONCENTRIC on two planar
    # faces) would silently contribute nothing; reject it like the py-slvs path always did.
    for mate, a, b in model.sides:
        if is_coupler(mate):
            if a.geometry.axis_origin is None or a.geometry.direction is None or b.geometry.axis_origin is None or b.geometry.direction is None:
                raise _unsupported_mate_geometry(mate.references[0], "an axis on each side")
            continue
        if is_limit(mate):
            if limit_value(mate, model._world(a, placed), model._world(b, placed)) is None:
                raise _unsupported_mate_geometry(mate.references[0], "a plane (distance limit) or two directions about a hinge (angle limit)")
            continue
        if not _mate_residual_vector(mate, model._world(a, placed), model._world(b, placed)):
            ref = mate.references[0]
            raise _unsupported_mate_geometry(ref, "a compatible point, plane or axis on each side")
    return model


def _with_hinge(mate: Mate, mates: Iterable[Mate], side, a_side: "_Side", b_side: "_Side") -> tuple["_Side", "_Side"]:
    """An ANGLE mate's two sides, the one carrying the mate's SECOND reference given the HINGE: the axis of a CONCENTRIC (or
    edge-on-edge COINCIDENT) mate between the same two occurrences, on that same occurrence (so the hinge direction does not
    depend on which side a solve calls "driven"). Unchanged when the pair has no hinge."""
    ids = [mate_ref_drivers(r)[0] for r in mate.references]  # a pattern copy is its source (what a follower side carries)
    if ids[0] == ids[1]:
        return a_side, b_side
    for other in mates:
        if other is mate or other.type not in (MateType.CONCENTRIC, MateType.COINCIDENT) or len(other.references) != 2:
            continue
        if {mate_ref_drivers(r)[0] for r in other.references} != set(ids):
            continue
        s0, s1 = side(other.references[0]), side(other.references[1])
        if _effective_mate(other, s0.geometry, s1.geometry).type != MateType.CONCENTRIC:
            continue
        for candidate in (s0, s1):
            g = candidate.geometry
            if candidate.occurrence_id == ids[1] and g.axis_origin is not None and g.direction is not None:
                hinge = (g.axis_origin, g.direction)
                if a_side.occurrence_id == ids[1]:
                    return replace(a_side, geometry=replace(a_side.geometry, hinge=hinge)), b_side
                return a_side, replace(b_side, geometry=replace(b_side.geometry, hinge=hinge))
    return a_side, b_side


def mate_world_geometries(
    document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None = None
) -> tuple[_ResolvedGeometry, _ResolvedGeometry]:
    """`mate`'s two references resolved into world space at the STORED poses (the first reference is returned first). `cache`
    (target Part id -> `compute_part_bodies`) lets a caller that resolves many mates share the tessellation work."""
    cache = {} if cache is None else cache
    worlds = []
    for ref in mate.references:
        if midplane_spans_tops(ref):
            worlds.append(cross_midplane_geometry(document, part, ref))
            continue
        target, transform = _target_part_and_transform(document, part, ref.occurrence_id)
        if target.id not in cache:
            cache[target.id] = compute_part_bodies(target)
        geometry = _resolve_local_geometry(target, cache[target.id], ref, document, part)
        worlds.append(geometry if transform is None else _place_in_world(geometry, transform))
    if mate.type in (MateType.ANGLE, MateType.LIMIT_ANGLE):
        worlds = _with_world_hinge(document, part, mate, worlds, cache)
    return worlds[0], worlds[1]


def _with_world_hinge(document: Document, part: Part, mate: Mate, worlds: list, cache: dict) -> list:
    """`worlds` (the ANGLE mate's two world geometries, references order) with the hinge attached to the second one, if a
    CONCENTRIC / edge-on-edge COINCIDENT between the same two occurrences gives it one (see `_with_hinge`)."""
    ids = [top_level_occurrence_id(r.occurrence_id) for r in mate.references]
    if ids[0] == ids[1]:
        return worlds
    for other in part.mates:
        if other.id == mate.id or other.suppressed or other.type not in (MateType.CONCENTRIC, MateType.COINCIDENT) or len(other.references) != 2:
            continue
        if {top_level_occurrence_id(r.occurrence_id) for r in other.references} != set(ids):
            continue
        pair = []
        for ref in other.references:
            target, transform = _target_part_and_transform(document, part, ref.occurrence_id)
            if target.id not in cache:
                cache[target.id] = compute_part_bodies(target)
            geometry = _resolve_local_geometry(target, cache[target.id], ref, document, part)
            pair.append(geometry if transform is None else _place_in_world(geometry, transform))
        if _effective_mate(other, pair[0], pair[1]).type != MateType.CONCENTRIC:
            continue
        for ref, geometry in zip(other.references, pair):
            if top_level_occurrence_id(ref.occurrence_id) == ids[1] and geometry.axis_origin is not None and geometry.direction is not None:
                return [worlds[0], replace(worlds[1], hinge=(geometry.axis_origin, geometry.direction))]
    return worlds


def validate_mate_geometry(document: Document, part: Part, mate: Mate) -> None:
    """Raises the structured 422 (`unsupported_mate_geometry`, or whatever the resolver raises for a dangling
    reference) when `mate`'s two references cannot form its constraint. `POST /mates` calls this BEFORE storing, so an
    unsolvable mate is never left in the document - once stored, `build_group_model` raises the same error for every
    solve of any group containing it, blocking all of that group's occurrences until the mate is deleted."""
    first, second = mate_world_geometries(document, part, mate)
    if is_coupler(mate) or is_limit(mate):
        return  # `coupler.prepare_coupler` / `limit.prepare_limit` validate those
    if not _mate_residual_vector(mate, first, second):
        raise _unsupported_mate_geometry(mate.references[0], "a compatible point, plane or axis on each side")


def mate_with_flipped_alias(document: Document, part: Part, mate: Mate, override: bool = False) -> Mate:
    """`mate` with the deprecated `flipped` flag read into `alignment` / `secondary_flip` (COINCIDENT plane-plane, ANGLE),
    for a payload that carried only `flipped`. Needs the geometry (see `apply_flipped_alias`); `override` replaces a branch
    the mate already names."""
    if is_coupler(mate) or is_limit(mate):
        return mate
    first, second = mate_world_geometries(document, part, mate)
    aliased = apply_flipped_alias(mate, first, second, override)
    sync_flipped(aliased)
    return aliased


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
    base = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])
    if model.rigid is None:
        weights = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm] * k)
    else:
        # a reduced model (rigid sets): every member of a set counts in the metric (`rigid_sets.expand_analysis` relies on it)
        weights = _RigidWeights(model, lambda _oid: base)(model.base_transforms)
    residual0 = model.residual()
    jac = model.jacobian()
    if jac.shape[0] == 0:
        rank, svals, vt = 0, np.zeros(0), np.eye(n)
    else:
        # Weighted variables y = W x make translation and rotation columns
        # commensurate, so the rank tolerance and conditioning are meaningful.
        _u, svals, vt_full = np.linalg.svd(_scale_cols(jac, weights), full_matrices=True)
        rank = relative_rank(svals, rank_rtol)
        vt = vt_full
    null_y = vt[rank:]  # (dof, n): orthonormal in y == orthonormal in the weighted metric
    basis = _unscale_rows(null_y, weights)
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


# ---- weights: a vector per variable, or (a reduced model) a block metric -------------------------------------------------
#
# Every weighted formula below reads `W x`, `J W^-1`, `W^-1 y`. On a plain model `W` is the diagonal weight vector (the code paths
# are the ones that existed before rigid sets). On a reduced model (`GroupModel.rigid`) a set's 6 variables carry the summed metric
# of all of its members (`constraint_model.RigidMetric`), so `W` is a block-diagonal matrix `F` that depends on the leads' poses.


class _Block:
    __slots__ = ("f", "finv", "metric")

    def __init__(self, f: np.ndarray, finv: np.ndarray, metric=None):
        self.f, self.finv, self.metric = f, finv, metric


def _scale_cols(jac: np.ndarray, w) -> np.ndarray:  # J W^-1
    return jac / w if isinstance(w, np.ndarray) else jac @ w.finv


def _unscale(y: np.ndarray, w) -> np.ndarray:  # W^-1 y
    return y / w if isinstance(w, np.ndarray) else w.finv @ y


def _scale(x: np.ndarray, w) -> np.ndarray:  # W x
    return x * w if isinstance(w, np.ndarray) else w.f @ x


def _scale_rows(rows: np.ndarray, w) -> np.ndarray:  # each row r -> W r
    return rows * w if isinstance(w, np.ndarray) else rows @ w.f.T


def _unscale_rows(rows: np.ndarray, w) -> np.ndarray:  # each row r -> W^-1 r
    return rows / w if isinstance(w, np.ndarray) else rows @ w.finv.T


class _RigidWeights:
    """The weights of a reduced model, as a function of the leads' poses: `weight_of(occurrence id)` is each MEMBER's own row."""

    def __init__(self, model: GroupModel, weight_of: Callable[[str], np.ndarray]):
        from app.document import rigid_sets

        self.model = model
        self.metric = rigid_sets.metric(model, weight_of)

    def __call__(self, poses: dict[str, RigidTransform]) -> _Block:
        f, finv = self.metric.factor([rigid_to_pose(poses[oid]) for oid in self.model.member_ids])
        return _Block(f, finv, self.metric)


def _weights_at(weights, poses: dict[str, RigidTransform]):
    return weights(poses) if callable(weights) else weights


# ---- group solve: weighted retraction (S2) -----------------------------------

_SOLVE_TOL = 1e-7  # the solver iterates until the residual is at or below this
# What counts as converged / worth a fallback: imported geometry carries ~1e-6 mm of noise, so a consistent but redundant
# system (two parallel mates to the same bars) can stall just above `_SOLVE_TOL` and is still a solution.
_NOISE_TOL = 1e-6
_MAX_ITERATIONS = 60
_MAX_ROTATION_STEP = 0.6  # rad per Gauss-Newton step (any member) before scaling down
_FOLLOWER_WEIGHT = 1e-4  # follower metric = this x the grabbed metric (follower cost ~ 0)
_PINV_RCOND = 1e-9
# Escalating follower weights tried, in order, when Gauss-Newton at `_FOLLOWER_WEIGHT` stalls on a multi-member group.
_FOLLOWER_WEIGHT_FALLBACKS = (1e-3, 1e-2, 1e-1, 1.0)
# M1.1: a retraction whose residual is still above `_STALL_RESIDUAL` (far beyond the near-redundant limits) and that took less than
# `_STALL_GAIN` off the residual norm over the last `_STALL_STEPS` steps stops: it is on a least-squares plateau (conflicting mates).
# Before, such a solve crawled through all `_MAX_ITERATIONS` with backtracked steps, five times with the re-weighted retries.
_STALL_STEPS = 5
_STALL_RESIDUAL = 0.1
_STALL_GAIN = 1e-4


@dataclass
class GroupSolveQuality:
    residual_inf: float
    jump: float | None  # weighted distance (grabbed block) between the solved pose and the first-order prediction
    iterations: int
    seeded_by: str  # "gauss-newton" | "slvs-fallback"
    max_step: float | None = None  # weighted mm the first-order (screw) model may be trusted from here; None = no curvature seen


@dataclass
class GroupSolveResult:
    converged: bool
    poses: dict[str, RigidTransform]  # every member; best effort when not converged
    analysis: GroupAnalysis | None  # at the solved poses; None when not converged (clients must not read "no basis" as "free")
    quality: GroupSolveQuality
    constraint_model: dict | None = None  # resolved mate geometry for the client's local retraction (spec section 4b); None when not converged
    # The branch every mate of the component solved on, `{mate_id: (alignment, secondary_flip)}`: what Closest resolved to (a mate
    # that already named its branch is listed with it). A commit writes the resolved values of still-unresolved mates back.
    branches: dict[str, tuple[str | None, bool | None]] = field(default_factory=dict)
    # B1 (`app.document.mate_tolerance`): `{mate_id: (millimetres at the far end, degrees)}` of the mates that sit above `_NOISE_TOL` in a result
    # accepted as converged because every mate is within the near-redundant limits. Empty for an exact solve. Never silent: the
    # routes report it (`X-Mate-Tolerance: near`) and every listing marks those mates `near`.
    near: dict[str, tuple[float, float]] = field(default_factory=dict)
    # M1 (`app.document.rigid_sets`): `{occurrence id: rigid set id}` for the members of a set that moves (not one locked to the
    # ground); empty when the group has none. The solve ran on one body per set; `poses` / `analysis` still list every member.
    rigid_sets: dict[str, str] = field(default_factory=dict)
    solved_bodies: int | None = None  # bodies the solve had (one per set + every other member); None = one per member (no set)

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


def _rotate_member_about(poses: dict[str, RigidTransform], oid: str, origin, axis, angle: float) -> None:
    """Rotates member `oid` by `angle` (radians) about the world line through `origin` along `axis`."""
    axis_v = np.array(_normalize(axis), dtype=float)
    k = np.array([[0.0, -axis_v[2], axis_v[1]], [axis_v[2], 0.0, -axis_v[0]], [-axis_v[1], axis_v[0], 0.0]])
    rot = np.eye(3) + math.sin(angle) * k + (1.0 - math.cos(angle)) * (k @ k)
    p = np.array(origin, dtype=float)
    t = np.array(poses[oid].translation, dtype=float)
    moved = p + rot @ (t - p)
    poses[oid] = replace(apply_delta(poses[oid], (0.0, 0.0, 0.0, *(axis_v * angle))), translation=(float(moved[0]), float(moved[1]), float(moved[2])))


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


def _follow_rotation(side: _Side) -> np.ndarray:
    """The rotation a follower side's copy has relative to its source (identity for every other side, and for a Linear
    pattern): a seed computed in the copy's world frame is mapped back to the SOURCE's frame by its inverse (the source is
    the member that moves; turning it by `R_s^-1 dR R_s` turns the copy by `dR`)."""
    if side.follow is None:
        return np.eye(3)
    return rigid_to_pose(pattern_copy_pose(side.follow[0], RigidTransform.identity(), side.follow[1]))[0]


def _seed_poses(model: GroupModel, poses: dict[str, RigidTransform]) -> None:
    """Move members off the states plain Gauss-Newton on `_mate_residual_vector`
    cannot leave: an alignment residual `d - s f` has a zero-gradient dead point
    exactly opposite its target (the residual is parallel to `d`, the only
    direction the rotation cannot change), and ANGLE / squared-DISTANCE ones
    vanish at an extremum. Only these cases are touched - anywhere else the
    retraction itself keeps the nearest solution:

    * a direction pointing the WRONG way for its mate's alignment (the opposite
      of `s * fixed`) -> ONE rotation of the mover onto all of its alignment
      targets together (`rotation_onto_pairs`: the minimal rotation for one
      target, a least-squares fit for several), the same seed the py-slvs path
      gets. This is what keeps a mate on its stored branch while it is dragged:
      a wish that would turn a pin over is pulled back to the same way up, never
      across to the other root. A COINCIDENT plane-plane against a frozen
      partner is aligned fully even when it is not wrong-way (the nearest
      orientation, as before);
    * ANGLE at a (anti)aligned start (gradient of the dot product vanishes) ->
      rotate onto the target angle about an axis perpendicular to the fixed one
      (this is the S2 fix for the singular start);
    * a squared DISTANCE (axis-axis, point-point: no side to carry) closer than a
      quarter of its value to zero separation (zero gradient at 0) -> slide out
      along the separation direction to exactly the target. The signed plane /
      point DISTANCE residual is linear in the separation, converges in one step
      from either side and needs no seed.
    The mover is always the mate's first side (`build_group_model` orients it)."""
    by_mover: dict[str, list[tuple[Mate, _Side, _Side]]] = {}
    for entry in model.sides:
        if is_coupler(entry[0]) or is_limit(entry[0]):
            continue  # a coupler has no dead point to seed out of: its rows are zero at the base pose
        by_mover.setdefault(entry[1].occurrence_id, []).append(entry)
    for mover, entries in by_mover.items():
        placed = {oid: poses[oid] for oid in model.member_ids}
        pairs: list[tuple[tuple[float, float, float], tuple[float, float, float]]] = []
        trigger = False
        for mate, first, second in entries:
            d, f = model._world(first, placed), model._world(second, placed)
            mate_pairs = alignment_pairs(mate, d, f)
            if first.follow is not None:
                back = _follow_rotation(first).T  # the mover is the source: its pairs in the source's frame
                mate_pairs = [(tuple(back @ np.array(a)), tuple(back @ np.array(b))) for a, b in mate_pairs]
            pairs.extend(mate_pairs)
            if any(_dot(source, target) < 0.0 for source, target in mate_pairs):
                trigger = True
            elif mate.type == MateType.COINCIDENT and d.plane is not None and f.plane is not None and second.occurrence_id not in poses:
                trigger = True  # frozen partner: align fully, the nearest orientation (the same seed py-slvs gets)
        if trigger:
            rotation = rotation_onto_pairs(pairs)
            if rotation is not None:
                _rotate_member(poses, mover, rotvec_from_rot(rotation))
    for mate, first, second in model.sides:
        if is_coupler(mate) or is_limit(mate):
            continue
        placed = {oid: poses[oid] for oid in model.member_ids}
        d, f = model._world(first, placed), model._world(second, placed)
        mover = first.occurrence_id
        back = _follow_rotation(first).T if first.follow is not None else None
        swing = hinge_swing_state(mate, d, f) if mate.type == MateType.ANGLE and mate.alignment is not None and first.follow is None else None
        if swing is not None:
            # An ANGLE about a hinge, the lid on the wrong side (or exactly flat): swing it about the hinge to the named root
            # (+theta or -theta); Gauss-Newton then only polishes. On the right side nothing is touched.
            (origin, axis), current = swing
            target = _angle_target_radians(mate) * (-1.0 if mate.alignment == "anti_aligned" else 1.0)
            if math.sin(current) * math.sin(target) < 1e-12:
                _rotate_member_about(poses, mover, origin, axis, current - target)
            continue
        if mate.type == MateType.ANGLE and d.direction is not None and f.direction is not None and mate.value is not None:
            nd, nf = _normalize(d.direction), _normalize(f.direction)
            dot = _dot(nd, nf)
            if abs(dot) > 1.0 - 5e-7:
                t = abs(mate.value) % 360.0
                t = math.radians(min(t, 360.0 - t))
                axis = np.array(_axis_perpendicular(nf))
                rotvec = axis * (t if dot > 0 else math.pi - t)
                _rotate_member(poses, mover, rotvec if back is None else back @ rotvec)
        elif mate.type == MateType.DISTANCE and mate.value:
            target = abs(mate.value)
            state = _distance_state(d, f)
            if state is not None and state[2] == "unsigned" and abs(state[0]) < 0.25 * target:
                current, direction, _kind = state
                shift = np.array(direction) * (target - current)
                _translate_member(poses, mover, shift if back is None else back @ shift)


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


def _metric(lever_arm: float) -> np.ndarray:
    return np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])


def _solve_weights(
    model: GroupModel, grabbed_id: str, lever_arm: float, follower_weight: float = _FOLLOWER_WEIGHT, grabbed_scale: float = 1.0
):
    """The retraction's weights: the grabbed member at `[1,1,1,L,L,L]` (times `grabbed_scale`), every other member at
    `follower_weight` times that. A vector; on a reduced model a `_RigidWeights` (evaluate it at the poses with `_weights_at`)."""
    base = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])
    if model.rigid is not None:
        return _RigidWeights(model, lambda oid: base * grabbed_scale if oid == grabbed_id else base * follower_weight)
    out = np.concatenate([base if oid == grabbed_id else base * follower_weight for oid in model.member_ids])
    if grabbed_scale != 1.0:
        gi = model.member_ids.index(grabbed_id)
        out[6 * gi : 6 * gi + 6] *= grabbed_scale
    return out


def _retract(
    model: GroupModel, poses: dict[str, RigidTransform], weights, max_iterations: int = _MAX_ITERATIONS
) -> tuple[dict, float, int]:
    """Weighted minimum-norm Gauss-Newton from `poses` onto `residual == 0`:
    `dx = -W^-1 pinv(J W^-1) r` (the least step in the metric `W`), with a
    rotation-step cap and residual-decrease backtracking. Returns `(poses, residual_inf, iterations)`."""
    ids = model.member_ids
    n = len(ids)

    def resid(p):
        return model.residual(None, p)

    r = resid(poses)
    iterations = 0
    norms: list[float] = []
    while r.size and float(np.max(np.abs(r))) > _SOLVE_TOL and iterations < max_iterations:
        norms.append(float(np.linalg.norm(r)))
        if (
            len(norms) > _STALL_STEPS
            and float(np.max(np.abs(r))) > _STALL_RESIDUAL
            and norms[-1 - _STALL_STEPS] - norms[-1] < _STALL_GAIN * norms[-1 - _STALL_STEPS]
        ):
            break  # crawling on a plateau far from any solution (a conflict): more steps cannot get there
        iterations += 1
        jac = model.jacobian(poses)
        w = _weights_at(weights, poses)
        dx = -_unscale(np.linalg.pinv(_scale_cols(jac, w), rcond=_PINV_RCOND) @ r, w)
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


def _predicted_seed(
    model: GroupModel,
    stored: dict[str, RigidTransform],
    wanted: RigidTransform,
    grabbed_id: str,
    lever_arm: float,
    analysis: GroupAnalysis,
) -> tuple[dict[str, RigidTransform], bool] | None:
    """Seed poses for `solve_group`'s retry: the grabbed member at the wish, every other member at the screw
    integration of the wish projected (follower-weighted) onto the free motion of the STORED pose. `None` when
    the stored pose has no free motion to project onto."""
    ids = model.member_ids
    if not analysis.basis.size:
        return None
    want = np.zeros(6 * len(ids))
    want[:6] = pose_delta(wanted, stored[grabbed_id])
    nb = analysis.basis
    # The grabbed member must land on the wish (weight 1e6) and, among the free motions that do that, the
    # followers should move least (unit weight: the free-motion space has directions - e.g. a bolt's spin - that
    # only move followers, and the retraction's tiny follower weight would leave them arbitrary).
    base = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])
    if model.rigid is None:
        sw = np.concatenate([base * (1e6 if oid == grabbed_id else 1.0) for oid in ids])
    else:
        sw = _RigidWeights(model, lambda oid: base * (1e6 if oid == grabbed_id else 1.0))(stored)
    nbw = _scale_rows(nb, sw)
    a = nbw @ nbw.T
    c = np.linalg.solve(a + 1e-12 * np.eye(len(a)), nbw @ _scale(want, sw))
    twist = nb.T @ c
    g = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])
    # The wish is (to first order) a free motion of the group: the grabbed block of the projection IS the wish.
    on_manifold = float(np.linalg.norm((twist[:6] - want[:6]) * g)) < 1e-4 * (1.0 + float(np.linalg.norm(want[:6] * g)))
    seed: dict[str, RigidTransform] = {}
    for i, oid in enumerate(ids):
        if oid == grabbed_id:
            seed[oid] = wanted
            continue
        blk = twist[6 * i : 6 * i + 6].copy()
        blk[:3] = _screw_translation_delta(np.array(stored[oid].translation), blk[:3], blk[3:])
        seed[oid] = apply_delta(stored[oid], blk)
    return seed, on_manifold


def solve_group(
    document: Document,
    part: Part,
    grabbed_id: str,
    wanted_pose: RigidTransform | None = None,
    lever_arm: float | None = None,
    also_frozen: frozenset[str] = frozenset(),
    extra_mates: tuple[Mate, ...] = (),
    with_jump: bool = True,
    reference: dict[str, RigidTransform] | None = None,
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
    seed - py-slvs is a fallback seed only, never the verifier.

    Limit mates (`app.document.limit`) are inequalities and add no rows: the group is solved without them, any limit the answer
    violates is held at its nearest bound (an equality row) and the group is solved again from the same start and wish - at
    most `_LIMIT_ROUNDS` times, each round only ever adding limits. A range that cannot be met is not converged."""
    model = build_group_model(document, part, grabbed_id, also_frozen, extra_mates)
    if reference:
        # Warm start: the members' current poses are the client's last accepted ones, not the stored ones.
        model = replace(model, base_transforms={**model.base_transforms, **{k: v for k, v in reference.items() if k in model.member_ids}})
    if lever_arm is None:
        lever_arm = bounding_radius(document, part, grabbed_id)
    reduced = None
    if rigid_sets_enabled and len(model.member_ids) > 1:
        from app.document import rigid_sets

        found = rigid_sets.detect(document, part, model, exclude=frozenset(m.id for m in extra_mates))
        reduced = rigid_sets.reduce_model(part, model, found, grabbed_id, lever_arm)
    if reduced is None:
        return _solve_with_limits(document, part, model, grabbed_id, wanted_pose, lever_arm, extra_mates, with_jump)
    result = _solve_with_limits(document, part, reduced, grabbed_id, wanted_pose, lever_arm, extra_mates, with_jump)
    return _expand_result(document, part, reduced, result, grabbed_id, lever_arm)


# M1 switch: False solves every group member by member as before (a test / benchmark compares the two; nothing else reads it).
rigid_sets_enabled = True


def _expand_result(
    document: Document, part: Part, reduced: GroupModel, result: GroupSolveResult, grabbed_id: str, lever_arm: float
) -> GroupSolveResult:
    """A reduced solve's answer over every member: followers placed from their leads, the mates inside the sets checked once on
    those poses (a miss there beyond the near-redundant limits is not converged, as the unreduced solve would be), the analysis
    expanded (`rigid_sets.expand_analysis`) and the constraint model as version 8.

    A set may be held together by mates that disagree by a hair (`near`, amber: they count as locking). The reduced solve keeps
    such a set exactly as it stands, which would leave the whole disagreement on one mate; the unreduced solve shares it out in
    least squares. So when a mate inside a set is above the strict tolerance, the whole group gets the unreduced Gauss-Newton
    steps from the expanded poses (it starts next to the answer: a few steps), and the near-redundant check judges the result."""
    from app.document import rigid_sets

    red = reduced.rigid
    poses = rigid_sets.expand_poses(red, result.poses)
    internal = red.internal_inf  # the followers keep their offsets: the mates inside the sets read what they read at the base poses
    residual_inf = max(result.quality.residual_inf, internal)
    converged, near = result.converged, dict(result.near)
    full = replace(red.full, active_limits={})
    if converged and internal > _NOISE_TOL:
        if near_redundant_mates(document, part, full, poses) is None:
            # a mate inside a set is missed beyond the near limits: the set is rigid without it, so no solve can meet it here (the
            # unreduced solve fails the same way, only slower) - not converged, and no unreduced steps spent on it
            converged = False
        elif not reduced.active_limits:
            polished, polished_inf, _ = _retract(full, poses, _solve_weights(full, grabbed_id, lever_arm))
            if polished_inf < residual_inf:
                poses, residual_inf = polished, polished_inf
    if converged and (residual_inf > _NOISE_TOL or near):
        # some mate is above the strict tolerance: judge the whole group (the mates inside the sets too) as the unreduced solve would
        accepted = near_redundant_mates(document, part, full, poses)
        converged, near = accepted is not None, (accepted or {})
    analysis = constraint_model = None
    if converged and result.analysis is not None:
        lead_poses = {oid: result.poses[oid] for oid in red.leads}
        analysis = rigid_sets.expand_analysis(_free(reduced, lead_poses), result.analysis, residual_inf)
        constraint_model = rigid_sets.export_v8(reduced, result.constraint_model)
    return GroupSolveResult(
        converged=converged,
        poses=poses,
        analysis=analysis,
        quality=replace(result.quality, residual_inf=residual_inf),
        constraint_model=constraint_model,
        branches=dict(result.branches),
        near=near if converged else {},
        rigid_sets=dict(red.set_ids),
        solved_bodies=len(red.leads),
    )


def _solve_with_limits(
    document: Document,
    part: Part,
    model: GroupModel,
    grabbed_id: str,
    wanted_pose: RigidTransform | None,
    lever_arm: float,
    extra_mates: tuple[Mate, ...],
    with_jump: bool,
) -> GroupSolveResult:
    """`_solve_model`, with the limit mates' active-set rounds (see `solve_group`)."""
    if not model.has_limits():
        return _solve_model(document, part, model, grabbed_id, wanted_pose, lever_arm, extra_mates, with_jump)
    active: dict[str, float] = {}
    for _ in range(_LIMIT_ROUNDS + 1):
        held = replace(model, active_limits=dict(active))
        result = _solve_model(document, part, held, grabbed_id, wanted_pose, lever_arm, extra_mates, with_jump)
        if not result.converged:
            return result
        violated = held.violated_limits(result.poses)
        if not violated:
            return result
        active.update(violated)
    return replace(result, converged=False, analysis=None, constraint_model=None)  # the range cannot be met together


_LIMIT_ROUNDS = 3


def _free(model: GroupModel, poses: dict[str, RigidTransform]) -> GroupModel:
    """`model` at `poses` with no limit held: the analysis (the free motion) and the first-order prediction never see a bound."""
    return replace(model, base_transforms=dict(poses), active_limits={})


def _solve_model(
    document: Document,
    part: Part,
    model: GroupModel,
    grabbed_id: str,
    wanted_pose: RigidTransform | None,
    lever_arm: float,
    extra_mates: tuple[Mate, ...],
    with_jump: bool,
) -> GroupSolveResult:
    """One solve of `model` (`solve_group`'s body; `model.active_limits` are the limits held at a bound)."""
    weights = _solve_weights(model, grabbed_id, lever_arm)
    stored = dict(model.base_transforms)

    seed = dict(stored)
    if wanted_pose is not None:
        seed[grabbed_id] = wanted_pose
    at_rest: GroupAnalysis | None = None
    _seed_poses(model, seed)
    poses, residual_inf, iterations = _retract(model, seed, weights)
    seeded_by = "gauss-newton"

    if residual_inf > _NOISE_TOL and len(model.member_ids) > 1:
        # Followers at ~0 cost soak up the whole correction even when their own mates cannot absorb it (a chain of
        # mitre-plane mates leaves only two spins of orientation): the step is then huge for almost no residual
        # decrease and Gauss-Newton crawls to `_MAX_ITERATIONS` without converging, though the SAME mates solve
        # instantly when another member is grabbed. Re-weight so the grabbed member shares the correction.
        for follower_weight in _FOLLOWER_WEIGHT_FALLBACKS:
            retry_poses, retry_residual, more = _retract(
                model, seed, _solve_weights(model, grabbed_id, lever_arm, follower_weight)
            )
            iterations += more
            if retry_residual <= _NOISE_TOL:
                poses, residual_inf, seeded_by = retry_poses, retry_residual, "gauss-newton-reweighted"
                break

    # (The py-slvs single-occurrence fallback cannot express a Width mid-plane that depends on another part's pose, nor a pattern copy that follows its source - its `_applicable_mates` matches references by raw top and would silently ignore the mate: skip it for those.)
    if residual_inf > _NOISE_TOL and len(model.member_ids) == 1 and model.rigid is None and not any(a.partner or b.partner or a.follow or b.follow for _m, a, b in model.sides):
        guess = wanted_pose if wanted_pose is not None else stored[grabbed_id]
        fallback = solve_occurrence_from_guess(document, part, grabbed_id, guess, extra_mates)
        if fallback.converged:
            fallback_poses = {grabbed_id: fallback.transform}
            _seed_poses(model, fallback_poses)  # py-slvs knows no swing sense: put an ANGLE about a hinge on its named root first
            poses, residual_inf, more = _retract(model, fallback_poses, weights)
            iterations += more
            seeded_by = "slvs-fallback"

    if wanted_pose is not None and len(model.member_ids) > 1:
        reached = residual_inf <= _SOLVE_TOL and float(np.linalg.norm(pose_delta(poses[grabbed_id], wanted_pose) * _metric(lever_arm))) <= 1e-6
        if not reached:
            # Followers must ride along with the grabbed member (a floating bolt + plate turned a quarter turn):
            # Gauss-Newton from "followers where they are" can stall, or settle far from the nearest solution
            # with the grabbed member pulled back towards its old pose although the wish is a free motion of the
            # group. Retry from the client's own prediction - the wish projected onto the stored pose's free motion,
            # integrated as a screw - then, if the wish is reachable, pin the grabbed member at it and let only the
            # followers correct. Adopted only if it converges and lands nearer the wish.
            at_rest = analyze_model(_free(model, stored), lever_arm)
            predicted = _predicted_seed(model, stored, wanted_pose, grabbed_id, lever_arm, at_rest)
            if predicted is not None:
                seed_poses, on_manifold = predicted
                _seed_poses(model, seed_poses)
                cand, cand_residual, more = _retract(model, seed_poses, weights)
                iterations += more
                if cand_residual <= _SOLVE_TOL and on_manifold:
                    pinned = dict(cand)
                    pinned[grabbed_id] = wanted_pose
                    heavy = _solve_weights(model, grabbed_id, lever_arm, grabbed_scale=1e3)
                    polished, polished_residual, more = _retract(model, pinned, heavy, max_iterations=20)
                    iterations += more
                    if polished_residual <= _SOLVE_TOL:
                        cand, cand_residual = polished, polished_residual
                if cand_residual <= _SOLVE_TOL:
                    old = float("inf") if residual_inf > _SOLVE_TOL else float(np.linalg.norm(pose_delta(poses[grabbed_id], wanted_pose) * _metric(lever_arm)))
                    new = float(np.linalg.norm(pose_delta(cand[grabbed_id], wanted_pose) * _metric(lever_arm)))
                    if new < old:
                        poses, residual_inf = cand, cand_residual
                        seeded_by = "predicted-seed"

    converged = residual_inf <= _NOISE_TOL
    near: dict[str, tuple[float, float]] = {}
    if not converged:
        # B1: the strict solve missed. Accept the least-squares result it reached only if every mate is within the
        # near-redundant limits in physical units (`near_redundant_mates`); anything else is a real conflict and stays unconverged.
        accepted = near_redundant_mates(document, part, model, poses)
        if accepted is not None:
            converged, near = True, accepted
    constraint_model = export_constraint_model(model) if converged else None
    if converged and wanted_pose is not None and constraint_model is not None:
        refined = _nearest_point_stage(model, constraint_model, poses, stored, wanted_pose, grabbed_id, lever_arm)
        if refined is not None:
            poses = refined
            seeded_by += "+nearest"
    analysis, jump, max_step = None, None, None
    if converged:
        analysis = analyze_model(_free(model, poses), lever_arm)
        if with_jump:
            jump, max_step = _jump(model, stored, poses, seed_wish=wanted_pose, grabbed_id=grabbed_id, lever_arm=lever_arm, at_rest_analysis=at_rest)
    return GroupSolveResult(
        converged=converged,
        poses=poses,
        analysis=analysis,
        quality=GroupSolveQuality(residual_inf=residual_inf, jump=jump, iterations=iterations, seeded_by=seeded_by, max_step=max_step),
        constraint_model=constraint_model,
        branches=dict(model.branches),
        near=near,
    )


def near_redundant_mates(
    document: Document, part: Part, model: GroupModel, poses: dict[str, RigidTransform]
) -> dict[str, tuple[float, float]] | None:
    """`{mate_id: (mm, degrees)}` of the mates above `_NOISE_TOL` at `poses` when EVERY mate of `model` is within the
    near-redundant limits (`app.document.mate_tolerance`); `None` when any mate is outside them (a real conflict), when a
    coupler or a held limit is part of the group (they measure motion, not a placement: never accepted this way), or when a
    mate's size cannot be measured (it is then not accepted). Nothing is changed."""
    from fastapi import HTTPException  # local: this module is otherwise HTTP-free

    if model.active_limits or any(is_coupler(mate) for mate, _a, _b in model.sides):
        return None
    placed = dict(poses)
    radii: dict[str, float] = {}
    out: dict[str, tuple[float, float]] = {}
    try:
        for mate, a, b in model.sides:
            if is_limit(mate):
                continue
            first, second = model._world(a, placed), model._world(b, placed)
            rows = _mate_residual_vector(mate, first, second)
            parallel = tuple(r for side in (a, b) if side.partner is not None for r in model._parallel_rows(side, placed))
            if not rows and not parallel:
                continue
            if max((abs(float(r)) for r in (*rows, *parallel)), default=0.0) <= _NOISE_TOL:
                continue
            residual = physical_residual(mate, first, second, rows, parallel)
            radius = 0.0
            for top in mate_tops(mate):
                if top == "":
                    continue
                if top not in radii:
                    radii[top] = bounding_radius(document, part, top)
                radius = max(radius, radii[top])
            if not is_within_tolerance(residual, radius):
                return None
            out[mate.id] = (residual.displacement_mm(radius), residual.angular_deg)
    except (HTTPException, KeyError, ValueError):
        return None  # a mate that cannot be measured is not accepted
    return out or None


_NEAREST_ITERATIONS = 12  # the backend is not on the per-frame path: plenty to settle
_NEAREST_POLISH = 3
_NEAREST_MIN_GAIN = 1e-9  # adopt only a strictly nearer answer (never worse than the plain retraction)


def _nearest_point_stage(
    model: GroupModel,
    spec: dict,
    poses: dict[str, RigidTransform],
    stored: dict[str, RigidTransform],
    wanted: RigidTransform,
    grabbed_id: str,
    lever_arm: float,
) -> dict[str, RigidTransform] | None:
    """Spec section 4b on the backend: refine a converged answer to the weighted-nearest mate-satisfying point
    (the plain Gauss-Newton retraction lands on SOME solution, 1-14 weighted mm farther from the wish on curved
    mates). The grabbed member's wish is `wanted`, every follower's is its current (stored / reference) pose, so followers
    move least; the metric is the local one (follower weight 1e-2, see the spec). Returns the new poses, or `None` when
    the refinement did not converge or is not nearer (the caller keeps its own answer)."""
    ids = list(model.member_ids)
    cm = ConstraintModel(spec, active=model.active_limits)
    if model.rigid is None:
        w = _local_weights(len(ids), lever_arm, grabbed=ids.index(grabbed_id))
    else:
        from app.document import rigid_sets
        from app.document.constraint_model import LOCAL_FOLLOWER

        base = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])
        # the followers (those of the grabbed member's set too) wish to stay at their stored poses, as every follower does
        w = rigid_sets.metric(model, lambda oid: base if oid == grabbed_id else base * LOCAL_FOLLOWER, rest=stored)
    start = [rigid_to_pose(poses[oid]) for oid in ids]
    wishes = [rigid_to_pose(wanted if oid == grabbed_id else stored[oid]) for oid in ids]
    cand = sqp_nearest(cm, start, wishes, w, iters=_NEAREST_ITERATIONS, polish=_NEAREST_POLISH)
    if _model_residual_inf(cm, cand) > _SOLVE_TOL:
        return None
    gi = ids.index(grabbed_id)
    metric = _metric(lever_arm)
    wished = float(np.linalg.norm(log_delta(rigid_to_pose(stored[grabbed_id]), wishes[gi]) * metric))
    off = float(np.linalg.norm(log_delta(cand[gi], wishes[gi]) * metric))
    if off <= 1e-3 * (1.0 + wished):
        # The wish is (all but) reachable. The local follower weight (1e-2 against the contract's 1e-4) leaves the grabbed
        # member 1e-4 of the followers' travel short of it: pin it exactly and let only the followers settle, the contract
        # metric (the grabbed answer of an on-manifold wish IS the wish).
        pinned = {oid: pose_to_rigid(cand[i]) for i, oid in enumerate(ids)}
        pinned[grabbed_id] = wanted
        heavy = _solve_weights(model, grabbed_id, lever_arm, grabbed_scale=1e3)
        settled, settled_residual, _ = _retract(model, pinned, heavy, max_iterations=20)
        if settled_residual <= _SOLVE_TOL:
            cand = [rigid_to_pose(settled[oid]) for oid in ids]
    if wish_cost(cand, wishes, w) >= wish_cost(start, wishes, w) - _NEAREST_MIN_GAIN:
        return None
    return {oid: pose_to_rigid(cand[i]) for i, oid in enumerate(ids)}


# max_step rule (docs/motion/projector-spec.md section 6). The client integrates the free motion as a
# constant SCREW per member; `max_step` is how far that first-order motion can be trusted to stay on
# the mate manifold. Probe: apply the client's own prediction (screw of the basis-projected wish, from
# the STORED pose) and evaluate the mate residual there; residual / sigma_min bounds the distance e (weighted
# mm) it leaves the manifold. e grows as d^2 (d = weighted length of the predicted step), so the step whose
# error stays within _MAX_STEP_TOL is sqrt(tol / e) * d. Independent of where the solver lands (the
# Gauss-Newton retraction is not always the nearest point; that shows up in `jump`, not here).
# Exact screw freedoms (flat mates, concentric about any axis) give e = 0 -> None.
_MAX_STEP_TOL = 0.25  # weighted mm of first-order error the display blend can hide
_MAX_STEP_MIN_D = 1e-3  # below this the wish tells nothing about curvature
_MAX_STEP_MIN_E = 1e-4  # below this the residual is finite-difference noise: flat, no limit


def _screw_translation_delta(t: np.ndarray, v: np.ndarray, w: np.ndarray) -> np.ndarray:
    """`t_new - t` when the twist (origin velocity `v`, rotation vector `w`) is integrated as a
    constant spatial screw: `t_new = E t + V (v - w x t)`, `E = exp(w)`, `V = I + (1-cos)/th^2 K + (th-sin)/th^3 K^2`."""
    th = float(np.linalg.norm(w))
    k = np.array([[0.0, -w[2], w[1]], [w[2], 0.0, -w[0]], [-w[1], w[0], 0.0]])
    if th < 1e-9:
        e, vm = np.eye(3) + k, np.eye(3) + 0.5 * k
    else:
        e = np.eye(3) + math.sin(th) / th * k + (1 - math.cos(th)) / th**2 * k @ k
        vm = np.eye(3) + (1 - math.cos(th)) / th**2 * k + (th - math.sin(th)) / th**3 * k @ k
    return (e - np.eye(3)) @ t + vm @ (v - np.cross(w, t))


def _jump(model: GroupModel, stored, solved, seed_wish, grabbed_id: str, lever_arm: float, at_rest_analysis: GroupAnalysis | None = None) -> tuple[float, float | None]:
    """`(jump, max_step)`, both in the screw chart the client integrates in (projector spec sections 5-6).
    `jump`: distance (grabbed block, metric diag(1,1,1,L,L,L), `screw_log`) between where the solve landed and where a
    client projecting the wish onto the STORED pose's free-motion basis and integrating the screw would have put the
    grabbed member - how far the first-order model was off (curved mates). It is ~0 on every screw orbit (flat mates,
    concentric about any axis). `max_step`: see the rule above."""
    ids = model.member_ids
    analysis = at_rest_analysis or analyze_model(_free(model, stored), lever_arm)
    w = _weights_at(_solve_weights(model, grabbed_id, lever_arm), stored)
    stored_poses = {oid: rigid_to_pose(stored[oid]) for oid in ids}
    want = np.zeros(6 * len(ids))
    if seed_wish is not None:
        want[:6] = screw_log(stored_poses[grabbed_id], rigid_to_pose(seed_wish))
    predicted = np.zeros_like(want)
    if analysis.basis.size:
        nb = analysis.basis  # rows; solve min |W (N^T c - want)| over c
        nbw = _scale_rows(nb, w)
        a = nbw @ nbw.T
        c = np.linalg.solve(a + 1e-12 * np.eye(len(a)), nbw @ _scale(want, w))
        predicted = nb.T @ c
    shown = {oid: screw_exp(stored_poses[oid], predicted[6 * i : 6 * i + 6]) for i, oid in enumerate(ids)}
    g = np.array([1.0, 1.0, 1.0, lever_arm, lever_arm, lever_arm])
    jump = float(np.linalg.norm(screw_log(shown[grabbed_id], rigid_to_pose(solved[grabbed_id])) * g))

    max_step = None
    sigma_min = analysis.quality.sigma_min
    d = float(np.linalg.norm(predicted[:6] * g))
    if sigma_min and d >= _MAX_STEP_MIN_D:
        r = model.residual(None, {**stored, **{oid: pose_to_rigid(p) for oid, p in shown.items()}})
        e = float(np.linalg.norm(r)) / sigma_min
        if e >= _MAX_STEP_MIN_E:
            max_step = d * math.sqrt(_MAX_STEP_TOL / e)
    return jump, max_step


# ---- branch search: a new mate that needs an earlier mate on its other branch ---------------------------------------------------
#
# `docs/mate-solution-choice-plan.md`, Phase 2b. Gauss-Newton keeps a mate on the branch it stands for, so a new mate that can
# only be met with an EARLIER mate on its other root (F6: a DISTANCE put the bracket above the base, a COINCIDENT then needs
# it below) cannot be solved from the current branches. The search below looks for the fewest earlier mates to move to their
# other branch - only ones whose branch the program chose (`branch_source == "auto"`) - and the caller shows the user that
# before anything is stored. It runs ONLY in the create / edit flow (preview, `POST /mates?solve=`, `PATCH ?solve=`), never in a
# drag, `mate-motion` or a plain `/solve`: a drag that needs another branch simply stops at the limit.

BRANCH_SEARCH_MAX_SOLVES = 24
BRANCH_SEARCH_SECONDS = 1.5
# M1.1: a `preview-mate-solve` as a whole (the first solve, the branch search, the conflict step and the alternatives) stops trying more
# once this many seconds have passed since it began - each part still gets its minimum solves - and says so (`budget_exhausted`).
# The create / edit flows (`POST` / `PATCH .../mates?solve=`) are not bounded by it: they keep the search's own budget only.
PREVIEW_SECONDS = 2.5


class PreviewBudget:
    """The clock of one preview (`PREVIEW_SECONDS`, read when it is made: a test can change it). `exhausted` is set by whatever
    stopped short because of it."""

    def __init__(self, seconds: float | None = None):
        self.deadline = time.monotonic() + (PREVIEW_SECONDS if seconds is None else seconds)
        self.exhausted = False

    def expired(self) -> bool:
        return time.monotonic() > self.deadline
BRANCH_SEARCH_MIN_SOLVES = 8  # solves a search always gets, whatever the clock says
_CONFLICT_RESERVE = 4  # solves kept back for the "which mate does it fight with" step
_PAIR_CANDIDATES = 6  # pairs are tried among this many of the best-ordered single changes


@dataclass(frozen=True)
class BranchChange:
    """One earlier mate moved to its other branch, in the convention the mate is STORED in (see `orient_branch`)."""

    mate_id: str
    field: str  # "alignment" | "secondary_flip"
    from_value: str | bool
    to_value: str | bool


@dataclass(frozen=True)
class BranchOption:
    """A change a search may try: `change` on `mate` (stored mate), by `source` the program or the user chose its branch."""

    mate: Mate
    change: BranchChange
    graph_distance: int
    residual: float


@dataclass
class BranchSearchOutcome:
    result: GroupSolveResult | None = None  # the converged answer WITH `changes` applied (only for auto changes)
    used: str = "group"  # which movement mode produced `result`
    changes: tuple[BranchChange, ...] = ()
    blocked_by: tuple[str, ...] = ()  # user-set mates whose other branch would have worked
    conflicting: tuple[str, ...] = ()  # mates that, suppressed, let the new mate converge: what it fights with
    solves: int = 0


def part_with_branch_changes(part: Part, changes: Iterable[BranchChange]) -> Part:
    """A copy of `part` whose mates carry `changes` (the stored mates are not touched)."""
    by_id: dict[str, dict] = {}
    for change in changes:
        by_id.setdefault(change.mate_id, {})[change.field] = change.to_value
    return replace(part, mates=[replace(m, **by_id[m.id]) if m.id in by_id else m for m in part.mates])


def _other_alignment(value: str | None) -> str:
    return MATE_ALIGNED if value == MATE_ANTI_ALIGNED else MATE_ANTI_ALIGNED


def branch_options(
    document: Document,
    part: Part,
    grabbed_id: str,
    extra_mates: tuple[Mate, ...] = (),
    skip_mate_ids: frozenset[str] = frozenset(),
    failed: GroupSolveResult | None = None,
) -> list[BranchOption]:
    """Every single change a branch search may try on the mates of `grabbed_id`'s component, ordered: graph distance from the
    new mates' occurrences first (mates on the same occurrence before mates further away), then the residual each mate has at
    `failed`'s end point (the most violated first). `skip_mate_ids` (the new / edited mate) are never candidates."""
    model = build_group_model(document, part, grabbed_id, extra_mates=extra_mates)
    stored = {m.id: m for m in part.mates}
    placed = dict(model.base_transforms)
    end = dict(placed)
    if failed is not None:
        end.update({oid: pose for oid, pose in failed.poses.items() if oid in end})
    anchors = {t for m in extra_mates for t in mate_tops(m)}
    for mate_id in skip_mate_ids:
        if mate_id in stored:
            anchors.update(mate_tops(stored[mate_id]))
    adjacency: dict[str, set[str]] = {}
    for mate, _a, _b in model.sides:
        ids = mate_tops(mate)
        for x in ids:
            for y in ids:
                if x != y:
                    adjacency.setdefault(x, set()).add(y)
    distance = {a: 0 for a in anchors}
    queue = deque(anchors)
    while queue:
        node = queue.popleft()
        for nxt in adjacency.get(node, ()):
            if nxt not in distance:
                distance[nxt] = distance[node] + 1
                queue.append(nxt)
    options: list[BranchOption] = []
    for mate, a, b in model.sides:
        if mate.id in skip_mate_ids or mate.id not in stored or is_coupler(mate) or is_limit(mate):
            continue  # a coupler's sense is the user's (or its default), never searched
        d, f = model._world(a, placed), model._world(b, placed)
        fields = branch_fields(mate, d, f)
        alignment, flip = model.branches.get(mate.id, (None, None))
        ids = mate_tops(mate)
        hops = min(distance.get(i, 1 << 20) for i in ids)
        residual = _mate_residual_vector(mate, model._world(a, end), model._world(b, end))
        worst = max((abs(x) for x in residual), default=0.0)
        if "alignment" in fields and alignment is not None:
            options.append(BranchOption(stored[mate.id], BranchChange(mate.id, "alignment", alignment, _other_alignment(alignment)), hops, worst))
        if "secondary_flip" in fields and flip is not None:
            options.append(BranchOption(stored[mate.id], BranchChange(mate.id, "secondary_flip", flip, not flip), hops, worst))
    options.sort(key=lambda o: (o.graph_distance, -o.residual))
    return options


def search_branch_changes(
    document: Document,
    part: Part,
    solve: Callable[[Part], tuple[GroupSolveResult, str]],
    grabbed_id: str,
    new_mate: Mate | None = None,
    skip_mate_ids: frozenset[str] = frozenset(),
    failed: GroupSolveResult | None = None,
    max_solves: int = BRANCH_SEARCH_MAX_SOLVES,
    seconds: float | None = None,  # None = BRANCH_SEARCH_SECONDS, read when the search runs (a test can change it)
    budget: PreviewBudget | None = None,  # a preview's own clock (M1.1): past it, every step stops once it has had its minimum
) -> BranchSearchOutcome:
    """The fewest earlier mates to move to their other branch so the new mate (`new_mate`, or an already-edited stored one) can
    be met. `solve(part) -> (result, movement_used)` is the caller's own solve of the new mate against the mates `part` carries.

    1. Single changes of an `auto` mate, one field at a time, in `branch_options` order; every converged one is kept, the
       one that moves the parts least wins (`pose_delta` in `_metric`).
    2. If no single works, pairs among the best-ordered few.
    3. If no `auto` change works but one on a `user` mate would: `blocked_by` names it (never changed for the user).
    4. If no branch combination works: `conflicting` = the existing mates that, suppressed one at a time, let it converge.
    A budget of solves and seconds bounds all of it; the conflict step keeps a few solves in reserve."""
    seconds = BRANCH_SEARCH_SECONDS if seconds is None else seconds
    started = time.monotonic()
    outcome = BranchSearchOutcome()
    extra = (new_mate,) if new_mate is not None else ()

    def spent(reserve: int = 0) -> bool:
        # The clock only ends a search that has had its minimum: a cold server (the first solve builds every body) or a slow CI runner
        # would otherwise stop it before it tried a single change and answer "no branch works".
        if outcome.solves >= max_solves - reserve:
            return True
        if outcome.solves < BRANCH_SEARCH_MIN_SOLVES:
            return False
        if budget is not None and budget.expired():
            budget.exhausted = True
            return True
        return time.monotonic() - started > seconds

    def run(trial: Part) -> tuple[GroupSolveResult, str]:
        outcome.solves += 1
        return solve(trial)

    options = branch_options(document, part, grabbed_id, extra, skip_mate_ids, failed)
    lever = bounding_radius(document, part, grabbed_id)
    metric = _metric(lever)
    stored = {o.id: o.transform for o in part.occurrences}

    def movement(result: GroupSolveResult) -> float:
        return sum(float(np.linalg.norm(pose_delta(pose, stored[oid]) * metric)) for oid, pose in result.poses.items() if oid in stored)

    def best_of(candidates: list[tuple[tuple[BranchChange, ...], GroupSolveResult, str]]):
        return min(candidates, key=lambda c: movement(c[1])) if candidates else None

    auto = [o for o in options if o.mate.branch_source == BRANCH_AUTO]
    user = [o for o in options if o.mate.branch_source != BRANCH_AUTO]

    singles: list[tuple[tuple[BranchChange, ...], GroupSolveResult, str]] = []
    for option in auto:
        if spent(_CONFLICT_RESERVE):
            break
        result, used = run(part_with_branch_changes(part, [option.change]))
        if result.converged:
            singles.append(((option.change,), result, used))
    best = best_of(singles)
    if best is None:
        pool = auto[:_PAIR_CANDIDATES]
        pairs: list[tuple[tuple[BranchChange, ...], GroupSolveResult, str]] = []
        for i in range(len(pool)):
            for j in range(i + 1, len(pool)):
                if spent(_CONFLICT_RESERVE):
                    break
                changes = (pool[i].change, pool[j].change)
                result, used = run(part_with_branch_changes(part, changes))
                if result.converged:
                    pairs.append((changes, result, used))
        best = best_of(pairs)
    if best is not None:
        outcome.changes, outcome.result, outcome.used = best[0], best[1], best[2]
        return outcome

    blockers: list[str] = []
    for option in user:
        if spent(_CONFLICT_RESERVE):
            break
        result, _used = run(part_with_branch_changes(part, [option.change]))
        if result.converged and option.change.mate_id not in blockers:
            blockers.append(option.change.mate_id)
    if blockers:
        outcome.blocked_by = tuple(blockers)
        return outcome

    fighting: list[str] = []
    in_play = {m.id for m in discover_component(part, grabbed_id, frozenset(), extra).mates}
    for mate in part.mates:
        if spent() or mate.id not in in_play or mate.id in skip_mate_ids or mate.suppressed or (new_mate is not None and mate.id == new_mate.id):
            continue
        trial = replace(part, mates=[replace(m, suppressed=True) if m.id == mate.id else m for m in part.mates])
        result, _used = run(trial)
        if result.converged:
            fighting.append(mate.id)
    outcome.conflicting = tuple(fighting)
    return outcome


# ---- Phase 3: the new mate's own branch choices -------------------------------------------------------------------------------


@dataclass(frozen=True)
class BranchAlternative:
    """One combination of a new mate's branch fields that converges, and where it puts the group."""

    alignment: str | None
    secondary_flip: bool | None
    result: GroupSolveResult
    used: str
    movement_cost: float


def mate_branch_controls(document: Document, part: Part, mate: Mate) -> tuple[str, ...]:
    """The branch fields (`"alignment"`, `"secondary_flip"`) that mean something for `mate`'s picked geometry, for the client to
    show as controls. Empty when the geometry cannot be resolved (a payload still being filled in)."""
    from fastapi import HTTPException  # local: this module is otherwise HTTP-free

    if is_limit(mate):
        return ()
    if is_coupler(mate):
        return ("secondary_flip",)  # the Reverse switch
    try:
        first, second = mate_world_geometries(document, part, mate)
    except HTTPException:
        return ()
    return branch_fields(mate, first, second)


def movement_cost(part: Part, result: GroupSolveResult, lever_arm: float) -> float:
    """How far `result` moves the group from the stored poses: the sum over members of the weighted pose distance
    (translation in mm, rotation as radians times `lever_arm`)."""
    stored = {o.id: o.transform for o in part.occurrences}
    return float(
        sum(
            np.linalg.norm(pose_delta(pose, stored[oid]) * _metric(lever_arm))
            for oid, pose in result.poses.items()
            if oid in stored
        )
    )


def branch_alternatives(
    part: Part,
    new_mate: Mate,
    controls: Iterable[str],
    solve: Callable[[Mate], tuple[GroupSolveResult, str]],
    lever_arm: float,
    budget: PreviewBudget | None = None,
) -> list[BranchAlternative]:
    """Every combination of `new_mate`'s `controls` solved from the same start - the other mates keep their persisted branches,
    no search - keeping the converged ones, nearest to the start first. `solve(mate)` runs the caller's own solve with `mate` as
    the hypothetical one. At most 4 solves (two binary fields); with a `budget` (a preview), none after it has run out but the first."""
    controls = tuple(controls)
    alignments: list[str | None] = [MATE_ALIGNED, MATE_ANTI_ALIGNED] if "alignment" in controls else [None]
    flips: list[bool | None] = [False, True] if "secondary_flip" in controls else [None]
    found: list[BranchAlternative] = []
    tried = 0
    for alignment in alignments:
        for flip in flips:
            if budget is not None and tried and budget.expired():
                budget.exhausted = True  # the preview's clock ran out: the list may be short (the first combination is always tried)
                break
            tried += 1
            variant = replace(new_mate, alignment=alignment, secondary_flip=flip, branch_source=BRANCH_USER)
            sync_flipped(variant)
            result, used = solve(variant)
            if result.converged:
                found.append(BranchAlternative(alignment, flip, result, used, movement_cost(part, result, lever_arm)))
    found.sort(key=lambda alt: alt.movement_cost)
    return found


# ---- per-occurrence constraint status (assembly tree badge) -------------------

# A group whose stored poses leave a larger residual than this has mates that
# contradict each other (a redundant-but-consistent mate stays ~1e-12; the
# contradicting-distance case in the tests is > 1). Looser than `_SOLVE_TOL`
# because stored poses went through JSON and a solve, not a Gauss-Newton polish.
_STATUS_RESIDUAL_TOL = 1e-5

STATUS_FIXED = "fixed"
STATUS_FULLY_CONSTRAINED = "fully_constrained"
STATUS_UNDER_CONSTRAINED = "under_constrained"
STATUS_OVER_CONSTRAINED = "over_constrained"


def constraint_status(document: Document, part: Part) -> dict[str, tuple[str, int]]:
    """`{occurrence_id: (status, dof)}` for every occurrence of `part`, for the
    Assembly tree's constraint badge. No new maths: it reuses the group
    analysis (`build_group_model` + `analyze_model`) once per mate-graph
    component, not once per occurrence.

    * `fixed` - `occurrence.fixed` (dof 0).
    * `fully_constrained` - the member's mobility is 0 AND its component is
      grounded (some mate ties it to a fixed occurrence / the part itself) AND
      the mates are consistent. The grounded condition matters: a group can
      have every member at mobility 0 relative to the others and still float
      as one rigid body, which is *under*-constrained.
    * `over_constrained` - the stored poses leave a residual (the mates
      contradict each other); dof is the member's mobility.
    * `under_constrained` - anything else, `dof` = the member's mobility. An
      unmated, unfixed occurrence is under-constrained with dof 6.

    A component whose geometry cannot be resolved (an unresolved reference, an
    unsupported face pairing) is left out of the result: the client then shows
    no badge for it, rather than a status that would be a guess.
    """
    return {oid: (status, dof) for oid, (status, dof, _m) in constraint_report(document, part).items()}


def constraint_report(
    document: Document, part: Part, rigid_set_ids: dict[str, str] | None = None
) -> dict[str, tuple[str, int, list[dict]]]:
    """[constraint_status] plus, for an `under_constrained` occurrence, its free motions
    (`free_motions_for_member`): `{occurrence_id: (status, dof, free_motions)}`. Every other status has no motions
    listed (`fixed` and `fully_constrained` have none; `over_constrained` motions would be a guess).

    M1: a component with rigid sets is analysed on one body per set (`app.document.rigid_sets`; the mates inside a set count in
    the residual check, and the analysis is expanded back to every member). `rigid_set_ids`, when given, is filled with
    `{occurrence id: set id}` for every member of a set that moves (a set locked to the ground reports none)."""
    from fastapi import HTTPException  # local: this module is otherwise HTTP-free

    from app.document import rigid_sets

    result: dict[str, tuple[str, int, list[dict]]] = {}
    visited: set[str] = set()
    for occurrence in part.occurrences:
        if occurrence.fixed:
            result[occurrence.id] = (STATUS_FIXED, 0, [])
            visited.add(occurrence.id)
    transforms = {o.id: o.transform for o in part.occurrences}
    for occurrence in part.occurrences:
        if occurrence.id in visited:
            continue
        component = discover_component(part, occurrence.id)
        visited.update(component.member_ids)
        try:
            model = build_group_model(document, part, occurrence.id)
            lever = bounding_radius(document, part, occurrence.id)
            reduced = None
            if rigid_sets_enabled and len(model.member_ids) > 1:
                reduced = rigid_sets.reduce_model(part, model, rigid_sets.component_sets(document, part, model), occurrence.id, lever)
            if reduced is None:
                analysis = analyze_model(model, lever)
            else:
                analysis = analyze_model(reduced, lever)
                residual_inf = max(analysis.quality.residual_inf, reduced.rigid.internal_inf)
                analysis = rigid_sets.expand_analysis(reduced, analysis, residual_inf)
                if rigid_set_ids is not None:
                    rigid_set_ids.update(reduced.rigid.set_ids)
        except (GroupError, HTTPException):
            continue
        contradictory = analysis.quality.residual_inf > _STATUS_RESIDUAL_TOL
        for member_id in analysis.member_ids:
            mobility = analysis.mobility[member_id]
            if contradictory:
                result[member_id] = (STATUS_OVER_CONSTRAINED, mobility, [])
            elif mobility == 0 and analysis.grounded:
                result[member_id] = (STATUS_FULLY_CONSTRAINED, 0, [])
            else:
                motions = free_motions_for_member(analysis, member_id, transforms[member_id]) if mobility else []
                result[member_id] = (STATUS_UNDER_CONSTRAINED, mobility, motions)
    return result


# ---- describing the free motion (completeness check, `docs/ai-modelling/16-assembly-mates-gaps-plan.md`) ----------

_MOTION_ROUND = 6  # decimals kept in a reported direction / point
_PITCH_FLOOR = 1e-5  # |pitch| / lever arm below this is a pure spin


def _unit_rows(rows: np.ndarray) -> np.ndarray:
    """`rows` orthonormalised (Gram-Schmidt in row order), dropping any row that is already spanned."""
    out: list[np.ndarray] = []
    for row in rows:
        v = np.array(row, float)
        for u in out:
            v = v - float(v @ u) * u
        n = float(np.linalg.norm(v))
        if n > 1e-9:
            out.append(v / n)
    return np.array(out).reshape(-1, 3)


def _signed(direction: np.ndarray) -> np.ndarray:
    """`direction` with its largest component positive: the same direction always reads the same."""
    d = np.array(direction, float)
    if d[int(np.argmax(np.abs(d)))] < 0:
        d = -d
    return d


def _canonical_directions(basis: np.ndarray) -> np.ndarray:
    """A readable orthonormal basis of the subspace spanned by the unit rows `basis` (m x 3): the coordinate axes that
    lie inside it when there are any, completed with the remaining directions. Three rows are always the axes."""
    m = basis.shape[0]
    if m == 0:
        return np.zeros((0, 3))
    if m == 3:
        return np.eye(3)
    chosen = [e for e in np.eye(3) if float(np.linalg.norm((e @ basis.T) @ basis)) > 1.0 - 1e-6]
    rest = _unit_rows(np.array(chosen).reshape(-1, 3).tolist() + basis.tolist())
    return np.array([_signed(d) for d in rest[:m]]).reshape(-1, 3)


def _clean(vector: np.ndarray) -> list[float]:
    return [round(float(c), _MOTION_ROUND) + 0.0 for c in vector]


def free_motions_for_member(analysis: GroupAnalysis, member_id: str, transform: RigidTransform) -> list[dict]:
    """The motions `member_id` is still free to make, in its OWN part frame (the frame its face selectors use).

    `analysis.basis` rows are twists `[v, w]` per member (`v` the origin's translation, `w` the rotation vector, both in
    world axes, in mm and radians): they are already divided by the `diag(1,1,1,L,L,L)` weights, so the weighting is
    NOT undone again here. The member's own block of those rows spans its motions (the rows themselves are an
    arbitrary mix, so they are re-expressed): pure translations first, then rotations, rotated into the part frame.
    Each is one of

    * `{"kind": "slide", "direction": [x, y, z]}`;
    * `{"kind": "spin", "axis": [x, y, z], "through": [x, y, z]}` (the point on the axis nearest the part origin);
    * `{"kind": "screw", "axis", "through", "pitch_per_turn"}` when the rotation also advances along its axis.

    When there are several (mobility above 1) the list is a basis of the free space, not a set of independent single
    motions: any mix of them is free too. The coordinate axes inside each subspace are preferred as its basis, so a
    plate that can slide in its plane reads as slides along x and y.
    """
    i = analysis.member_ids.index(member_id)
    lever = analysis.lever_arm
    weights = np.array([1.0, 1.0, 1.0, lever, lever, lever])
    block = analysis.basis[:, 6 * i : 6 * i + 6] * weights  # the member's columns of the orthonormal nullspace
    if block.size == 0:
        return []
    _u, svals, vt = np.linalg.svd(block, full_matrices=False)
    twists_w = vt[svals > _MOBILITY_TOL]  # weighted twists, orthonormal
    if not len(twists_w):
        return []
    # World -> part frame (the occurrence's rotation), and out of the weighted metric.
    from app.document.constraint_model import _rotation_matrix

    r_part = _rotation_matrix(transform).T
    twists = twists_w / weights
    v_all = twists[:, :3] @ r_part.T
    w_all = twists[:, 3:] @ r_part.T
    # Rotational rank: how many independent rotation directions the motions have.
    uw, sw, _vwt = np.linalg.svd(w_all * lever, full_matrices=True)
    n_rot = int(np.sum(sw > _MOBILITY_TOL))
    mixed_v = uw.T @ v_all
    mixed_w = uw.T @ w_all
    slides = _unit_rows(mixed_v[n_rot:]) if len(mixed_v) > n_rot else np.zeros((0, 3))
    motions: list[dict] = [{"kind": "slide", "direction": _clean(d)} for d in _canonical_directions(slides)]
    if n_rot:
        rot_w = mixed_w[:n_rot]
        rot_v = mixed_v[:n_rot].copy()
        for u in slides:  # a rotation's own translation, with the slides taken out
            rot_v -= np.outer(rot_v @ u, u)
        span = _unit_rows(rot_w)
        for d in _canonical_directions(span):
            # The twist with rotation exactly `d`: a combination of the rows (their rotations are orthogonal).
            coeff = np.array([float(d @ w) / float(w @ w) for w in rot_w])
            v = coeff @ rot_v
            axis = d / float(np.linalg.norm(d))
            through = np.cross(axis, v)
            pitch = float(v @ axis)  # mm per radian along the axis
            entry = {"axis": _clean(axis), "through": _clean(through)}
            if abs(pitch) / max(lever, 1e-9) < _PITCH_FLOOR:
                motions.append({"kind": "spin", **entry})
            else:
                motions.append({"kind": "screw", **entry, "pitch_per_turn": round(2.0 * math.pi * pitch, _MOTION_ROUND) + 0.0})
    return motions
