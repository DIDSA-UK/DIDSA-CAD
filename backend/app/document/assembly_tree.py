"""`GET /parts/{part_id}/assembly-tree`: the whole assembly hierarchy below one Part in a single call, with the state each row
needs and problem counts rolled up to every assembly level. The response and every rule clients apply to it are in
`docs/assembly-tree/spec.md` (the contract of the assembly tree overhaul, `docs/assembly-tree-overhaul-scope.md` 9.2).

No geometry is sent. Without `status` the walk reads the model only (names, flags, missing files: a few milliseconds even
for thousands of rows). With `status` it also asks, once per distinct assembly Part (not once per placement), what
`GET /parts/{id}/constraint-status` and `GET /parts/{id}/mates` would answer: both need the placed Parts' bodies, so
that is where the time goes on a cold document. The walk never writes to the document (unlike `GET /mates`, it does not
persist re-found mate reference indices). A level whose status raises is logged and reported without status
(`status_failed` on its nodes, `status_incomplete` on the response); the other levels are unaffected.

Guards: a Part placed inside itself (directly or further down) is a node marked `cycle` with no children; the walk stops
at `max_depth` levels and after `max_nodes` occurrence nodes, marking the node it stopped under `truncated` and saying so
on the response. Pattern copies are not nodes (the pattern is summarised on its assembly)."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from app.document.assembly import mate_tops
from app.document.assembly_group import constraint_report
from app.document.mate_status import mate_status_details
from app.document.models import Document, Part
from app.document.subshape_identity import refresh_mate_references

logger = logging.getLogger(__name__)

MAX_DEPTH = 32
MAX_NODES = 10_000

KIND_ASSEMBLY = "assembly"
KIND_PART = "part"
KIND_MISSING = "missing"


@dataclass
class _Level:
    """What the status calls say about one assembly Part's own level (shared by every placement of it)."""

    constraint: dict[str, dict[str, Any]] = field(default_factory=dict)  # occurrence id -> {status, dof, rigid_set}
    mates: dict[str, Any] = field(default_factory=dict)
    broken_by_occurrence: dict[str, int] = field(default_factory=dict)
    near_by_occurrence: dict[str, int] = field(default_factory=dict)
    failed: bool = False  # status was asked for and could not be computed for this level


def _structure_level(part: Part) -> _Level:
    return _Level(mates={"count": len(part.mates), "suppressed": sum(1 for m in part.mates if m.suppressed), "broken": None, "near": None, "held": None, "lost": None})


def _status_level(document: Document, part: Part, bodies: dict[str, dict]) -> _Level:
    """`constraint-status` and the `mates` listing's status for `part`'s own level (the functions those endpoints call), read-only:
    the mate references are re-checked without writing a re-found index or signature back (`persist=False`). `bodies` (target
    Part id -> its bodies) is shared by every level of one walk, so each placed Part is tessellated once.

    A mate touching a suppressed occurrence of this level is left out of `broken` / `near` / `held` / `lost` and of the rows'
    `broken_mates` / `near_mates`: a suppressed occurrence is out of the model (spec section 6)."""
    level = _structure_level(part)
    if part.occurrences:
        sets: dict[str, str] = {}
        report = constraint_report(document, part, rigid_set_ids=sets, free_motions=False)
        level.constraint = {oid: {"status": status, "dof": dof, "rigid_set": sets.get(oid)} for oid, (status, dof, _motions) in report.items()}
    broken = near = held = lost = 0
    if part.mates:
        off = {o.id for o in part.occurrences if o.suppressed}
        states = refresh_mate_references(document, part, persist=False, cache=bodies)
        statuses = mate_status_details(document, part, states, cache=bodies)
        for mate in part.mates:
            tops = mate_tops(mate)
            if off.intersection(tops):
                continue
            status = statuses[mate.id].status
            state = states.get(mate.id)
            broken += status == "broken"
            near += status == "near"
            held += bool(state is not None and state.held)
            lost += bool(state is not None and state.has_lost)
            if mate.suppressed or status == "ok":
                continue
            counter = level.broken_by_occurrence if status == "broken" else level.near_by_occurrence
            for top in tops:
                counter[top] = counter.get(top, 0) + 1
    level.mates.update(broken=broken, near=near, held=held, lost=lost)
    return level


def row_state_counts_as_over_constrained(constraint: dict[str, Any] | None) -> bool:
    """The spec's state slot reads `over_constrained` (red) for this constraint entry: over-constrained, touched by no broken
    mate (that would read `broken`) and not only by `near` ones (that reads `near`, amber)."""
    if constraint is None or constraint["status"] != "over_constrained":
        return False
    return constraint["broken_mates"] == 0 and constraint["near_mates"] == 0


@dataclass
class _Walk:
    document: Document
    status: bool
    max_depth: int
    max_nodes: int
    levels: dict[str, _Level] = field(default_factory=dict)
    bodies: dict[str, dict] = field(default_factory=dict)  # one tessellation per placed Part for the whole walk
    status_failed: bool = False
    node_count: int = 0
    truncated_depth: bool = False
    truncated_nodes: bool = False
    placed: list[dict[str, Any]] = field(default_factory=list)

    def level(self, part: Part) -> _Level:
        cached = self.levels.get(part.id)
        if cached is None:
            if not self.status:
                cached = _structure_level(part)
            else:
                try:
                    cached = _status_level(self.document, part, self.bodies)
                except Exception:  # noqa: BLE001 - one level that cannot be analysed must not fail the whole tree
                    logger.exception("assembly-tree: status failed for Part %s; its level is reported without it", part.id)
                    cached = _structure_level(part)
                    cached.failed = True
                    self.status_failed = True
            self.levels[part.id] = cached
        return cached

    def assembly_fields(self, part: Part, node: dict[str, Any], ancestors: tuple[str, ...], path: list[str]) -> None:
        """Fill `children`, `mates`, `patterns` and `problems` of the node (or root) standing for assembly Part `part`."""
        level = self.level(part)
        node["mates"] = dict(level.mates)
        node["status_failed"] = level.failed
        node["patterns"] = {"count": len(part.component_patterns), "suppressed": sum(1 for p in part.component_patterns if p.suppressed)}
        problems = {
            "missing": 0,
            "cycles": 0,
            # With status, a level whose status failed adds nothing of its own (its node says `status_failed`).
            "broken": (level.mates["broken"] or 0) if self.status else None,
            "over_constrained": 0 if self.status else None,
            "near": (level.mates["near"] or 0) if self.status else None,
        }
        for occurrence in part.occurrences:
            if self.node_count >= self.max_nodes:
                self.truncated_nodes = True
                node["truncated"] = True
                break
            child = self.occurrence_node(part, occurrence, level, ancestors, path)
            node["children"].append(child)
            if child["suppressed"]:
                continue  # a suppressed occurrence is out of the model: its subtree adds nothing above it
            if child["kind"] == KIND_MISSING:
                problems["missing"] += 1
            elif child["cycle"]:
                problems["cycles"] += 1
            elif self.status and row_state_counts_as_over_constrained(child["constraint"]):
                problems["over_constrained"] += 1
            below = child["problems"]
            if below is not None:
                for key, value in below.items():
                    if value is not None:
                        problems[key] += value
        # Counts cover the nodes listed: under a cap (`truncated_*` on the response) they can be short.
        node["problems"] = problems

    def occurrence_node(self, owner: Part, occurrence, level: _Level, ancestors: tuple[str, ...], parent_path: list[str]) -> dict[str, Any]:
        self.node_count += 1
        path = parent_path + [occurrence.id]
        part = self.document.parts.get(occurrence.part_id) if occurrence.part_id else None
        if part is None:
            kind = KIND_MISSING
        else:
            kind = KIND_ASSEMBLY if part.occurrences else KIND_PART
        constraint = None
        if self.status:
            entry = level.constraint.get(occurrence.id)
            if entry is not None:
                constraint = {
                    **entry,
                    "broken_mates": level.broken_by_occurrence.get(occurrence.id, 0),
                    "near_mates": level.near_by_occurrence.get(occurrence.id, 0),
                }
        node: dict[str, Any] = {
            "occurrence_id": occurrence.id,
            "path": path,
            "external_ref": occurrence.external_ref,
            "ref_part_id": occurrence.placed_part_id,
            "resolved_part_id": part.id if part is not None else None,
            "part_name": part.name if part is not None else None,
            "name_override": occurrence.name_override,
            "kind": kind,
            "fixed": occurrence.fixed,
            "hidden": occurrence.hidden,
            "suppressed": occurrence.suppressed,
            "color": occurrence.color,
            "constraint": constraint,
            "feature_count": len(part.features) if part is not None else None,
            "placements": None,
            "cycle": False,
            "truncated": False,
            "status_failed": False,
            "mates": None,
            "patterns": None,
            "problems": None,
            "children": [],
        }
        if part is not None:
            self.placed.append(node)
        if kind != KIND_ASSEMBLY:
            return node
        if part.id in ancestors:
            node["cycle"] = True
            return node
        if len(path) >= self.max_depth:
            node["truncated"] = True
            self.truncated_depth = True
            return node
        self.assembly_fields(part, node, ancestors + (part.id,), path)
        return node


def build_assembly_tree(document: Document, root: Part, *, status: bool, max_depth: int = MAX_DEPTH, max_nodes: int = MAX_NODES) -> dict[str, Any]:
    """The `AssemblyTreeResponse` for `root` as plain data (see the module docstring and the spec)."""
    walk = _Walk(document, status, max_depth, max_nodes)
    response: dict[str, Any] = {
        "part_id": root.id,
        "part_name": root.name,
        "kind": KIND_ASSEMBLY if root.occurrences else KIND_PART,
        "feature_count": len(root.features),
        "status_included": status,
        "truncated": False,
        "status_failed": False,
        "mates": None,
        "patterns": None,
        "problems": None,
        "children": [],
    }
    if root.occurrences:
        walk.assembly_fields(root, response, (root.id,), [])
    counts: dict[str, int] = {}
    for node in walk.placed:
        counts[node["resolved_part_id"]] = counts.get(node["resolved_part_id"], 0) + 1
    for node in walk.placed:
        node["placements"] = counts[node["resolved_part_id"]]
    response.update(
        node_count=walk.node_count,
        max_depth=max_depth,
        max_nodes=max_nodes,
        truncated_depth=walk.truncated_depth,
        truncated_nodes=walk.truncated_nodes,
        status_incomplete=walk.status_failed,
    )
    return response
