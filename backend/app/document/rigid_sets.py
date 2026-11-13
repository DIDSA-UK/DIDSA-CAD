"""Rigid sets in the group solve (phase M1 of `docs/mates-storage-sessions-plan-2026-11-12.md`).

Members of a mate-graph component that the mates lock to each other move as one body. `detect` finds them; `reduce_model` turns
the component's `GroupModel` into one whose members are the sets' LEADS (one 6-variable body per set), with every mate side on a
follower re-expressed in its lead's frame (the follower keeps a constant offset from the lead) and the mates inside a set left
out (they cannot change; `solve_group` checks them once at the end, on the expanded poses). The solve itself is the unchanged
`assembly_group` machinery run on the reduced model; `expand_poses` / `expand_analysis` give back every member, so
`GroupSolveResult.poses`, the analysis' `basis` / `mobility` and every route's member lists still list every occurrence.

**Detection** (exact, at the model's base poses; mates that cannot lock are left out first):
  * a mate LOCKS when it is not a coupler or a limit (they measure motion / bound a range: never merged across), not a
    hypothetical one (`exclude`: a preview's new mate - it only adds constraints, so sets found without it stay rigid with it),
    and it is met at the base poses, exactly or within the near-redundant limits (`near`, amber, counts as locking); a broken mate
    (beyond those limits) does not lock;
  * members a coupler or a limit touches, and the source of a pattern copy that follows it (`_Side.follow`), never join a set;
  * pass 1 (cheap): two members whose shared locking mates alone have rank 6 are one set; a member whose locking mates with
    frozen occurrences (fixed, the `""` ref) alone have rank 6 is locked to the ground;
  * pass 2 (exact): the nullspace of every locking row on the pass-1 bodies; bodies whose relative motion is zero in every
    nullspace vector are one set, bodies with no motion at all are locked to the ground. Every ground-locked member forms ONE set
    (they are all fixed in the world); unlike the plan's wording it is still solved as a 6-variable body held by its mates to the
    frozen parts (identical answers, no special case for a frozen side), and it is not reported as a set (`set_ids`): nothing in it
    moves, its members already read `fully_constrained`.
The result is cached per component state (`_detection_key`: members, frozen peers, every mate with its resolved geometry and
branch, the stored poses): any mate, fix, suppress, geometry or stored-pose change misses the cache.

**Weighting.** A set costs what its members would cost moving separately (`constraint_model.RigidMetric`: the 6 x 6 sum of the
members' metrics in the lead's chart), so the nearest-point answer and the follower weighting keep their meaning.
"""

from __future__ import annotations

import threading
from collections import OrderedDict
from dataclasses import dataclass, field, replace
from typing import Callable

import numpy as np
from fastapi import HTTPException

from app.document.assembly import mate_tops
from app.document.assembly_solver import _mate_residual_vector, _place_in_world
from app.document.constraint_model import (
    ConstraintModel,
    RigidMetric,
    export_constraint_model,
    pose_to_rigid,
    rigid_to_pose,
    with_rigid_sets,
)
from app.document.coupler import is_coupler
from app.document.limit import is_limit
from app.document.mate_tolerance import is_within_tolerance, physical_residual
from app.document.models import Document, Mate, Part, RigidTransform

_GROUND = "\x00ground"
_RIGID_TOL = 1e-6  # weighted relative twist (unit nullspace vectors) below which two bodies count as moving together
_CACHE_SIZE = 64


@dataclass(frozen=True)
class RigidSetsFound:
    groups: tuple[tuple[str, ...], ...] = ()  # every set of >= 2 members (the ground-locked one included), component order
    ground: frozenset[str] = frozenset()  # the members locked to the ground (one of `groups` when there are 2 or more)

    def __bool__(self) -> bool:
        return bool(self.groups)


_EMPTY = RigidSetsFound()


@dataclass
class Reduction:
    """What `reduce_model` did: the full model, the sets' leads, each follower's constant offset from its lead and the mates left
    out (inside a set)."""

    full: object  # the unreduced `GroupModel`
    leads: tuple[str, ...]
    lead_of: dict[str, str]  # every member -> its lead (a lead -> itself)
    followers: dict[str, list[tuple[str, np.ndarray, np.ndarray]]]  # lead -> [(follower id, R_off, t_off)] (pose in the lead's frame)
    internal: list = field(default_factory=list)  # (mate, side, side) of the full model inside one set
    set_ids: dict[str, str] = field(default_factory=dict)  # reported id per member of a set that is not ground-locked
    ground: frozenset[str] = frozenset()


# ---- detection ------------------------------------------------------------------------------------------------------


_cache: "OrderedDict[tuple, RigidSetsFound]" = OrderedDict()
_cache_lock = threading.Lock()
cache_stats = {"hits": 0, "misses": 0}


def clear_cache() -> None:
    with _cache_lock:
        _cache.clear()


def _side_key(side) -> tuple:
    if side is None:
        return ()
    follow = None if side.follow is None else (side.follow[0].id, side.follow[1])
    return (side.occurrence_id, repr(side.geometry), repr(side.frozen_transform), follow, _side_key(side.partner))


def _detection_key(part: Part, model, exclude: frozenset[str]) -> tuple:
    stored = {o.id: o.transform for o in part.occurrences}
    return (
        part.id,
        tuple(sorted(model.component.member_ids)),  # the sets do not depend on which member was grabbed (it only orders them)
        model.component.frozen_ids,
        tuple((repr(mate), _side_key(a), _side_key(b)) for mate, a, b in model.sides if mate.id not in exclude),
        tuple(repr(stored.get(oid)) for oid in sorted(model.component.member_ids)),
    )


def _all_sides(a, b) -> list:
    out = []
    for side in (a, b):
        while side is not None:
            out.append(side)
            side = side.partner
    return out


def _never_merged(model) -> set[str]:
    """Members a coupler or a limit touches, and the sources of pattern copies that follow them."""
    index = model._index
    out: set[str] = set()
    for mate, a, b in model.sides:
        sides = _all_sides(a, b)
        if is_coupler(mate) or is_limit(mate):
            out.update(s.occurrence_id for s in sides if s.occurrence_id in index)
        out.update(s.occurrence_id for s in sides if s.follow is not None)
    return out


def _is_near(document: Document, part: Part, model, mate: Mate, a, b, placed: dict[str, RigidTransform]) -> bool:
    """`mate` (above the strict tolerance at `placed`) is within the near-redundant limits (`mate_tolerance`): it still locks."""
    from app.document.assembly_group import bounding_radius

    try:
        first, second = model._world(a, placed), model._world(b, placed)
        rows = _mate_residual_vector(mate, first, second)
        parallel = tuple(r for side in (a, b) if side.partner is not None for r in model._parallel_rows(side, placed))
        residual = physical_residual(mate, first, second, rows, parallel)
        radius = max((bounding_radius(document, part, top) for top in mate_tops(mate) if top != ""), default=0.0)
    except (HTTPException, KeyError, ValueError):
        return False
    return bool(is_within_tolerance(residual, radius))


class _Union:
    def __init__(self, items):
        self.parent = {i: i for i in items}

    def find(self, x):
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a, b) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[rb] = ra


def _relative_rank(svals: np.ndarray) -> int:
    from app.document.assembly_group import relative_rank

    return relative_rank(svals)


def _ad(d: np.ndarray) -> np.ndarray:
    out = np.eye(6)
    out[:3, 3:] = -np.array([[0.0, -d[2], d[1]], [d[2], 0.0, -d[0]], [-d[1], d[0], 0.0]])
    return out


def detect(document: Document, part: Part, model, exclude: frozenset[str] = frozenset(), lever_arm: float | None = None) -> RigidSetsFound:
    """The rigid sets of `model`'s component (see the module docstring), cached. `exclude`: mate ids that never lock (the new mate
    of a preview). `lever_arm` weights rotation against translation for the rank tests (default: the bounding radius of the
    component's first member in `part.occurrences` order, so the answer does not depend on which member was grabbed)."""
    ids = model.member_ids
    if len(ids) < 2:
        return _EMPTY
    key = _detection_key(part, model, exclude)
    with _cache_lock:
        found = _cache.get(key)
        if found is not None:
            _cache.move_to_end(key)
            cache_stats["hits"] += 1
            return found
    cache_stats["misses"] += 1
    if lever_arm is None:
        from app.document.assembly_group import bounding_radius

        order = {o.id: i for i, o in enumerate(part.occurrences)}
        lever_arm = bounding_radius(document, part, min(ids, key=lambda oid: order.get(oid, len(order))))
    found = _detect(document, part, model, exclude, lever_arm)
    with _cache_lock:
        _cache[key] = found
        while len(_cache) > _CACHE_SIZE:
            _cache.popitem(last=False)
    return found


def _detect(document: Document, part: Part, model, exclude: frozenset[str], lever: float) -> RigidSetsFound:
    ids = list(model.member_ids)
    k = len(ids)
    index = {oid: i for i, oid in enumerate(ids)}
    spec = export_constraint_model(model)
    if not spec:
        return _EMPTY  # a mate the analytic model cannot evaluate: no reduction (the group is solved as before)
    placed = [rigid_to_pose(model.base_transforms[oid]) for oid in ids]
    placed_rt = dict(model.base_transforms)
    weights = np.array([1.0, 1.0, 1.0, lever, lever, lever] * k)
    blocked = _never_merged(model)

    locking: list[np.ndarray] = []
    pair_rows: dict[tuple[str, ...], list[np.ndarray]] = {}
    for (mate, a, b), entry in zip(model.sides, spec["mates"]):
        if mate.id in exclude or is_coupler(mate) or is_limit(mate):
            continue
        r, jac = ConstraintModel({"members": ids, "mates": [entry]}).residual(placed)
        if not r.size:
            continue
        from app.document.assembly_group import _NOISE_TOL

        if float(np.max(np.abs(r))) > _NOISE_TOL and not _is_near(document, part, model, mate, a, b, placed_rt):
            continue  # broken: never locks
        locking.append(jac)
        occ = {s.occurrence_id for s in _all_sides(a, b)}
        movers = tuple(sorted((o for o in occ if o in index), key=index.get))
        grounded = any(o not in index for o in occ)
        if any(m in blocked for m in movers):
            continue
        if len(movers) == 2 and not grounded:
            pair_rows.setdefault(movers, []).append(jac)
        elif len(movers) == 1 and grounded:
            pair_rows.setdefault((movers[0], _GROUND), []).append(jac)
    if not locking:
        return _EMPTY

    union = _Union([*ids, _GROUND])
    for pair, jacs in pair_rows.items():
        cols = np.concatenate([np.arange(6 * index[m], 6 * index[m] + 6) for m in pair if m != _GROUND])
        sub = np.vstack(jacs)[:, cols] / weights[cols]
        if _relative_rank(np.linalg.svd(sub, compute_uv=False)) == 6:
            union.union(*pair) if pair[1] != _GROUND else union.union(_GROUND, pair[0])

    # pass 2: the nullspace of every locking row on the pass-1 bodies (lead = first member in component order)
    classes: dict[str, list[str]] = {}
    for oid in ids:
        classes.setdefault(union.find(oid), []).append(oid)
    bodies = list(classes.values())
    g = len(bodies)
    expand = np.zeros((6 * k, 6 * g))
    metric = np.zeros((6 * g, 6 * g))
    w6 = weights[:6]
    for c, members in enumerate(bodies):
        lead_t = placed[index[members[0]]][1]
        m_c = np.zeros((6, 6))
        for oid in members:
            ad = _ad(placed[index[oid]][1] - lead_t)
            expand[6 * index[oid] : 6 * index[oid] + 6, 6 * c : 6 * c + 6] = ad
            m_c += ad.T @ ((w6 * w6)[:, None] * ad)
        metric[6 * c : 6 * c + 6, 6 * c : 6 * c + 6] = np.linalg.cholesky(m_c).T
    finv = np.linalg.inv(metric)
    a = (np.vstack(locking) @ expand) @ finv
    _u, svals, vt = np.linalg.svd(a, full_matrices=True)
    rank = _relative_rank(svals)
    twists = vt[rank:] @ finv.T  # (dof, 6g): each body's lead twist [v, w] per nullspace vector
    scale = np.array([1.0, 1.0, 1.0, lever, lever, lever])
    spatial = []  # each body's motion as a spatial twist (velocity of the world origin, w): equal for bodies that move together
    for c, members in enumerate(bodies):
        blk = twists[:, 6 * c : 6 * c + 6]
        lead_t = placed[index[members[0]]][1]
        spatial.append(np.hstack([blk[:, :3] - np.cross(blk[:, 3:], lead_t), blk[:, 3:]]) * scale)
    free = [c for c, members in enumerate(bodies) if not any(m in blocked for m in members)]
    for c in free:
        if not twists.shape[0] or float(np.linalg.norm(twists[:, 6 * c : 6 * c + 6] * scale)) <= _RIGID_TOL:
            union.union(_GROUND, bodies[c][0])
    for i, c in enumerate(free):
        for h in free[i + 1 :]:
            if union.find(bodies[c][0]) == union.find(bodies[h][0]):
                continue
            if not twists.shape[0] or float(np.linalg.norm(spatial[c] - spatial[h])) <= _RIGID_TOL:
                union.union(bodies[c][0], bodies[h][0])

    final: dict[str, list[str]] = {}
    for oid in ids:
        final.setdefault(union.find(oid), []).append(oid)
    ground_root = union.find(_GROUND)
    ground = frozenset(final.get(ground_root, ()))
    groups = tuple(tuple(members) for members in final.values() if len(members) >= 2)
    return RigidSetsFound(groups=groups, ground=ground)


# ---- reduction ------------------------------------------------------------------------------------------------------


def _offset(lead: RigidTransform, member: RigidTransform) -> tuple[np.ndarray, np.ndarray]:
    r_l, t_l = rigid_to_pose(lead)
    r_m, t_m = rigid_to_pose(member)
    return r_l.T @ r_m, r_l.T @ (t_m - t_l)


def reported_ids(part: Part, found: RigidSetsFound) -> dict[str, str]:
    """`{member: set id}` for every set that is not locked to the ground; the id is the set's first member in
    `part.occurrences` order (stable whichever member is grabbed)."""
    order = {o.id: i for i, o in enumerate(part.occurrences)}
    out: dict[str, str] = {}
    for group in found.groups:
        if set(group) <= found.ground:
            continue
        set_id = min(group, key=lambda oid: order.get(oid, len(order)))
        out.update({oid: set_id for oid in group})
    return out


def reduce_model(part: Part, full, found: RigidSetsFound, grabbed_id: str):
    """`full` with every set merged into its lead (the grabbed member leads its own set), or `None` when there is no set."""
    from app.document.assembly_group import GroupModel

    if not found.groups:
        return None
    ids = full.member_ids
    lead_of = {oid: oid for oid in ids}
    followers: dict[str, list[tuple[str, np.ndarray, np.ndarray]]] = {}
    offsets: dict[str, RigidTransform] = {}
    for group in found.groups:
        lead = grabbed_id if grabbed_id in group else group[0]
        entries = []
        for oid in group:
            lead_of[oid] = lead
            if oid != lead:
                r, t = _offset(full.base_transforms[lead], full.base_transforms[oid])
                entries.append((oid, r, t))
                offsets[oid] = pose_to_rigid((r, t))
        followers[lead] = entries
    leads = tuple(oid for oid in ids if lead_of[oid] == oid)

    def map_side(side):
        if side is None:
            return None
        partner = map_side(side.partner)
        oid = side.occurrence_id
        if oid in offsets:
            side = replace(side, occurrence_id=lead_of[oid], geometry=_place_in_world(side.geometry, offsets[oid]))
        return side if partner is side.partner else replace(side, partner=partner)

    kept, internal = [], []
    for mate, a, b in full.sides:
        ma, mb = map_side(a), map_side(b)
        occ = {s.occurrence_id for s in _all_sides(ma, mb)}
        if not is_coupler(mate) and len(occ) == 1 and next(iter(occ)) in leads:
            internal.append((mate, a, b))
            continue
        kept.append((mate, ma, mb))
    reduced = GroupModel(
        component=replace(full.component, member_ids=leads),
        base_transforms={oid: full.base_transforms[oid] for oid in leads},
        sides=kept,
        branches=dict(full.branches),
        active_limits=dict(full.active_limits),
    )
    reduced._index = {oid: i for i, oid in enumerate(leads)}
    reduced.rigid = Reduction(
        full=full,
        leads=leads,
        lead_of=lead_of,
        followers=followers,
        internal=internal,
        set_ids=reported_ids(part, found),
        ground=found.ground,
    )
    return reduced


def expand_poses(reduction: Reduction, poses: dict[str, RigidTransform]) -> dict[str, RigidTransform]:
    """Every member's pose with the leads at `poses` (a follower at its lead's pose times its offset), in the full member order."""
    out: dict[str, RigidTransform] = {}
    lead_poses = {lead: rigid_to_pose(poses[lead]) for lead in reduction.leads}
    by_follower = {oid: (lead, r, t) for lead, entries in reduction.followers.items() for oid, r, t in entries}
    for oid in reduction.full.member_ids:
        if oid in by_follower:
            lead, r, t = by_follower[oid]
            r_l, t_l = lead_poses[lead]
            out[oid] = pose_to_rigid((r_l @ r, r_l @ t + t_l))
        else:
            out[oid] = poses[oid]
    return out


def metric(reduced, weight_of: Callable[[str], np.ndarray], rest: dict[str, RigidTransform] | None = None) -> RigidMetric:
    """The `RigidMetric` of `reduced` with each member weighted by `weight_of(occurrence id)` (6 entries); `rest`: the lead poses the
    followers wish to stay at (their rest poses), None = the start of the retraction."""
    red: Reduction = reduced.rigid
    lead_weights = np.concatenate([weight_of(lead) for lead in red.leads])
    followers = [[(r, t, weight_of(oid)) for oid, r, t in red.followers.get(lead, [])] for lead in red.leads]
    rest_poses = None if rest is None else [rigid_to_pose(rest[lead]) for lead in red.leads]
    return RigidMetric(lead_weights, followers, rest_poses)


def internal_residual_inf(reduced, poses: dict[str, RigidTransform]) -> float:
    """Max residual of the mates inside the sets at the expanded `poses` (every member)."""
    red: Reduction = reduced.rigid
    if not red.internal:
        return 0.0
    view = replace(red.full, sides=list(red.internal), active_limits={})
    r = view.residual(None, poses)
    return float(np.max(np.abs(r))) if r.size else 0.0


def expand_analysis(reduced, analysis, residual_inf: float):
    """`analysis` (of `reduced`, at its base poses) over every member: each follower's block of the basis is its lead's twist moved
    to the follower's origin (`[v + w x d, w]`). The rows stay orthonormal in the full metric (the reduced analysis used the summed
    metric), so the free-motion space and every route reading it are what the unreduced analysis gives; `rank` is `6k - dof`. The
    conditioning (`sigma_min`, `sigma_gap`, `singular_values`) is the reduced model's: the mates inside a set are not in it."""
    from app.document.assembly_group import _MOBILITY_TOL, GroupAnalysis

    red: Reduction = reduced.rigid
    full_ids = red.full.member_ids
    lever = analysis.lever_arm
    w6 = np.array([1.0, 1.0, 1.0, lever, lever, lever])
    dof = analysis.dof
    lead_index = {oid: i for i, oid in enumerate(analysis.member_ids)}
    by_follower = {oid: (lead, t) for lead, entries in red.followers.items() for oid, _r, t in entries}
    basis = np.zeros((dof, 6 * len(full_ids)))
    for j, oid in enumerate(full_ids):
        if oid in by_follower:
            lead, t_off = by_follower[oid]
            i = lead_index[lead]
            blk = analysis.basis[:, 6 * i : 6 * i + 6]
            d = rigid_to_pose(reduced.base_transforms[lead])[0] @ t_off
            basis[:, 6 * j : 6 * j + 3] = blk[:, :3] + np.cross(blk[:, 3:], d)
            basis[:, 6 * j + 3 : 6 * j + 6] = blk[:, 3:]
        else:
            i = lead_index[oid]
            basis[:, 6 * j : 6 * j + 6] = analysis.basis[:, 6 * i : 6 * i + 6]
    null_y = basis * np.tile(w6, len(full_ids))
    mobility = {
        oid: int(np.linalg.matrix_rank(null_y[:, 6 * j : 6 * j + 6], tol=_MOBILITY_TOL)) if null_y.size else 0
        for j, oid in enumerate(full_ids)
    }
    return GroupAnalysis(
        member_ids=full_ids,
        frozen_ids=red.full.component.frozen_ids,
        dof=dof,
        rank=6 * len(full_ids) - dof,
        grounded=analysis.grounded,
        lever_arm=lever,
        basis=basis,
        mobility=mobility,
        quality=replace(analysis.quality, residual_inf=residual_inf),
        singular_values=analysis.singular_values,
    )


def export_v8(reduced, spec: dict | None) -> dict | None:
    """The reduced model's exported `spec` as constraint model version 8 (its followers as fixed offsets)."""
    if spec is None:
        return None
    red: Reduction = reduced.rigid
    return with_rigid_sets(spec, {lead: red.followers.get(lead, []) for lead in red.leads})


# ---- reporting ------------------------------------------------------------------------------------------------------


def component_sets(document: Document, part: Part, model) -> RigidSetsFound:
    """`detect` for a listing (nothing excluded)."""
    try:
        return detect(document, part, model)
    except (HTTPException, KeyError, ValueError, np.linalg.LinAlgError):
        return _EMPTY


def mate_rigid_sets(document: Document, part: Part) -> dict[str, str]:
    """`{mate id: set id}` of every mate that lies inside one reported rigid set (both of its sides on members of it)."""
    from app.document.assembly_group import GroupError, _graph_ids, build_group_model, discover_component

    out: dict[str, str] = {}
    visited: set[str] = set()
    for occurrence in part.occurrences:
        if occurrence.fixed or occurrence.id in visited:
            continue
        try:
            component = discover_component(part, occurrence.id)
        except GroupError:
            continue
        visited.update(component.member_ids)
        if len(component.member_ids) < 2:
            continue
        try:
            model = build_group_model(document, part, occurrence.id)
        except (GroupError, HTTPException):
            continue
        ids = reported_ids(part, component_sets(document, part, model))
        for mate in component.mates:
            if is_coupler(mate) or is_limit(mate):
                continue
            tops = set(_graph_ids(mate))
            set_of = {ids.get(t) for t in tops}
            if len(set_of) == 1 and None not in set_of:
                out[mate.id] = next(iter(set_of))
    return out
