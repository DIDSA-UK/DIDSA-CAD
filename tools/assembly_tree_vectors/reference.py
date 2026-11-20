"""Reference implementation of the assembly tree's client rules (DIDSA-CAD `docs/assembly-tree/spec.md`).

Pure Python, standard library only. It is not used by any app: it exists to produce `docs/assembly-tree/vectors.json`
(`generate.py`), which the Flutter client and DIDSA-VR test their own copies of these rules against. Every function here
is one rule of the spec, named after the spec's section.

Two halves:
- `build_tree` turns a small hand-written model into a `GET /parts/{id}/assembly-tree` response, following the
  backend's walk (spec "Response", "Problem counts"), so the vectors' input trees are consistent without typing them out.
- `visible_rows` and the helpers above it are what a client does with a response (spec "Display names" to "Row keys").
"""

from __future__ import annotations

import re
from typing import Any

# --- Display names ----------------------------------------------------------------------------------------------------

_UUID = re.compile(r"^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$")
_PREFIXED_HEX = re.compile(r"^(?:[A-Za-z]{1,6}[-_])?[0-9a-fA-F]{16,}$")


def looks_generated(name: str | None) -> bool:
    """A name nobody chose: empty, a UUID (dashes optional), or 16+ hex digits with an optional short prefix (`part-3f2a...`)."""
    n = (name or "").strip()
    return n == "" or bool(_UUID.match(n)) or bool(_PREFIXED_HEX.match(n))


def file_base_name(external_ref: str | None) -> str | None:
    """`parts/bolt.didsa` -> `bolt`: the last `/` segment without its last extension (a leading dot is kept)."""
    if not external_ref:
        return None
    name = external_ref.split("/")[-1]
    dot = name.rfind(".")
    return name[:dot] if dot > 0 else name


def base_name(node: dict[str, Any], sibling_index: int) -> tuple[str, str]:
    """(name, source): the name override, else the Part's name, else the file name, else `Component N` (N = 1-based place
    among the siblings). A Part name or file name that looks generated is skipped. `source` is `override`, `part`, `file`
    or `ordinal`; only `part` and `file` names take instance numbers and group."""
    override = node.get("name_override")
    if override is not None and override.strip() != "":
        return override, "override"
    part_name = node.get("part_name")
    if part_name is not None and not looks_generated(part_name):
        return part_name, "part"
    file_name = file_base_name(node.get("external_ref"))
    if file_name is not None and not looks_generated(file_name):
        return file_name, "file"
    return f"Component {sibling_index + 1}", "ordinal"


def instance_key(node: dict[str, Any], source: str) -> str | None:
    """Which siblings count as "the same thing placed again": the resolved Part, or for a missing file its `external_ref`."""
    if source not in ("part", "file"):
        return None
    if node.get("resolved_part_id"):
        return "part:" + node["resolved_part_id"]
    if node.get("external_ref"):
        return "file:" + node["external_ref"]
    return None


def sibling_names(children: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Per child, in order: {name, base, key}. Siblings sharing an instance key are numbered `Base <1>`, `Base <2>`... in
    sibling order; a key used once keeps the plain base name."""
    bases = [base_name(child, i) for i, child in enumerate(children)]
    keys = [instance_key(child, source) for child, (_, source) in zip(children, bases)]
    totals: dict[str, int] = {}
    for key in keys:
        if key is not None:
            totals[key] = totals.get(key, 0) + 1
    seen: dict[str, int] = {}
    out = []
    for (base, _source), key in zip(bases, keys):
        if key is not None and totals[key] > 1:
            seen[key] = seen.get(key, 0) + 1
            out.append({"name": f"{base} <{seen[key]}>", "base": base, "key": key})
        else:
            out.append({"name": base, "base": base, "key": key})
    return out


# --- Grouping repeats -------------------------------------------------------------------------------------------------

GROUP_MIN = 4  # "more than 3 identical siblings"


def sibling_items(children: list[dict[str, Any]], grouping: bool) -> list[dict[str, Any]]:
    """The rows one level lists, in order: `{"node", "name"}` for an occurrence, `{"group": [indices], "base", "key"}` for a
    group. With grouping on, siblings sharing an instance key, when there are 4 or more of them, become one group row at the
    place of the first; the members are listed under it, in order, with their instance names."""
    names = sibling_names(children)
    members: dict[str, list[int]] = {}
    for i, entry in enumerate(names):
        if entry["key"] is not None:
            members.setdefault(entry["key"], []).append(i)
    items: list[dict[str, Any]] = []
    for i, (child, entry) in enumerate(zip(children, names)):
        group = members.get(entry["key"]) if entry["key"] is not None else None
        if grouping and group is not None and len(group) >= GROUP_MIN:
            if group[0] == i:
                items.append({"group": group, "base": entry["base"], "key": entry["key"]})
            continue
        items.append({"node": child, "name": entry["name"]})
    return items


# --- State slot -------------------------------------------------------------------------------------------------------

STATES = ["missing", "cycle", "broken", "over_constrained", "near", "unsaved", "under_constrained", "fixed", "fully_constrained", "none"]


def state_slot(node: dict[str, Any], unsaved_part_ids: frozenset[str]) -> str:
    """The one state a row shows, most severe first (`STATES`)."""
    if node["kind"] == "missing":
        return "missing"
    if node.get("cycle"):
        return "cycle"
    constraint = node.get("constraint")
    status = constraint["status"] if constraint else None
    if constraint and constraint["broken_mates"] > 0:
        return "broken"
    if status == "over_constrained":
        return "near" if constraint["near_mates"] > 0 else "over_constrained"
    if node.get("resolved_part_id") in unsaved_part_ids:
        return "unsaved"
    if status == "under_constrained":
        return "under_constrained"
    if status == "fixed" or (constraint is None and node.get("fixed")):
        return "fixed"
    if status == "fully_constrained":
        return "fully_constrained"
    return "none"


def worst_state(states: list[str]) -> str:
    return min(states, key=STATES.index) if states else "none"


# --- Problem counts -----------------------------------------------------------------------------------------------------

def _zero() -> dict[str, int]:
    return {"error": 0, "warning": 0, "unsaved": 0}


def _add(total: dict[str, int], more: dict[str, int]) -> None:
    for k in total:
        total[k] += more[k]


def _row_contribution(node: dict[str, Any], unsaved: frozenset[str]) -> dict[str, int]:
    """What one (unsuppressed) row adds to the bubble of a collapsed row above it."""
    out = _zero()
    state = state_slot(node, unsaved)
    if state in ("missing", "cycle", "over_constrained"):
        out["error"] += 1
    if node.get("resolved_part_id") in unsaved and node["kind"] != "missing":
        out["unsaved"] += 1
    return out


def _problems_below(problems: dict[str, Any] | None) -> dict[str, int]:
    out = _zero()
    if problems:
        out["error"] = sum(problems[k] or 0 for k in ("missing", "cycles", "broken", "over_constrained"))
        out["warning"] = problems["near"] or 0
    return out


def _unsaved_below(node: dict[str, Any], unsaved: frozenset[str]) -> int:
    total = 0
    for child in node.get("children", []):
        if child["suppressed"]:
            continue
        if child.get("resolved_part_id") in unsaved and child["kind"] != "missing":
            total += 1
        total += _unsaved_below(child, unsaved)
    return total


def subtree_counts(node: dict[str, Any], unsaved: frozenset[str]) -> dict[str, int]:
    """Everything under a collapsed occurrence (or root) row: the backend's `problems` plus the unsaved rows below it."""
    out = _problems_below(node.get("problems"))
    out["unsaved"] = _unsaved_below(node, unsaved)
    return out


def own_level_counts(node: dict[str, Any]) -> dict[str, int]:
    """An open assembly row: only its own mates' problems (its children are rows of their own)."""
    out = _zero()
    mates = node.get("mates")
    if mates:
        out["error"] = mates["broken"] or 0
        out["warning"] = mates["near"] or 0
    return out


def group_counts(members: list[dict[str, Any]], unsaved: frozenset[str]) -> dict[str, int]:
    out = _zero()
    for member in members:
        if member["suppressed"]:
            continue
        _add(out, _row_contribution(member, unsaved))
        _add(out, subtree_counts(member, unsaved))
    return out


def bubble(counts: dict[str, int]) -> dict[str, Any] | None:
    """One bubble, most severe first: error (red), warning (amber), unsaved."""
    for level in ("error", "warning", "unsaved"):
        if counts[level] > 0:
            return {"level": level, "count": counts[level]}
    return None


# --- Row keys -----------------------------------------------------------------------------------------------------------

def occurrence_key(path: list[str]) -> str:
    return "/".join(path)


def group_key(parent_key: str, first_member_id: str) -> str:
    return (parent_key + "/" if parent_key else "") + "#group:" + first_member_id


def feature_key(node_key: str, feature_id: str) -> str:
    return node_key + "#feature:" + feature_id


def folder_key(node_key: str, folder: str) -> str:
    return node_key + "#" + folder


# --- Visible rows -------------------------------------------------------------------------------------------------------

def _row(key, kind, depth, label, state="none", bubble_=None, expandable=False, is_open=False, count=None, path=None, hidden=False, suppressed=False):
    return {
        "key": key,
        "kind": kind,
        "depth": depth,
        "label": label,
        "state": state,
        "bubble": bubble_,
        "expandable": expandable,
        "open": is_open,
        "count": count,
        "path": path,
        "hidden": hidden,
        "suppressed": suppressed,
    }


def _expandable(node: dict[str, Any]) -> bool:
    return node["kind"] != "missing" and (bool(node.get("children")) or (node.get("feature_count") or 0) > 0)


def visible_rows(
    tree: dict[str, Any],
    open_keys: set[str] | frozenset[str] = frozenset(),
    grouping: bool = True,
    unsaved_part_ids: set[str] | frozenset[str] = frozenset(),
    features: dict[str, list[dict[str, Any]]] | None = None,
) -> list[dict[str, Any]]:
    """The flat list of rows to draw, top to bottom (spec "Visible rows")."""
    unsaved = frozenset(unsaved_part_ids)
    features = features or {}
    rows = [_row("", "root", 0, tree["part_name"], state="unsaved" if tree["part_id"] in unsaved else "none", expandable=False, is_open=True, path=[])]

    def emit_features(node_key: str, depth: int) -> None:
        for feature in features.get(node_key, []):
            rows.append(_row(feature_key(node_key, feature["id"]), "feature", depth, feature["label"]))

    def emit_occurrence(node: dict[str, Any], name: str, depth: int) -> None:
        key = occurrence_key(node["path"])
        expandable = _expandable(node)
        is_open = expandable and key in open_keys
        if not expandable:
            counts = None
        elif is_open:
            counts = own_level_counts(node)
        else:
            counts = subtree_counts(node, unsaved)
        rows.append(
            _row(
                key,
                node["kind"],
                depth,
                name,
                state=state_slot(node, unsaved),
                bubble_=bubble(counts) if counts else None,
                expandable=expandable,
                is_open=is_open,
                path=list(node["path"]),
                hidden=node["hidden"],
                suppressed=node["suppressed"],
            )
        )
        if is_open:
            emit_level(node, key, depth + 1)
            emit_features(key, depth + 1)

    def emit_level(node: dict[str, Any], node_key: str, depth: int) -> None:
        children = node.get("children", [])
        names = sibling_names(children)
        for item in sibling_items(children, grouping):
            if "node" in item:
                emit_occurrence(item["node"], item["name"], depth)
                continue
            members = [children[i] for i in item["group"]]
            live = [m for m in members if not m["suppressed"]]  # the group's state: its worst unsuppressed member (all suppressed: its worst)
            key = group_key(node_key, members[0]["occurrence_id"])
            is_open = key in open_keys
            rows.append(
                _row(
                    key,
                    "group",
                    depth,
                    f"{item['base']} x{len(members)}",
                    state=worst_state([state_slot(m, unsaved) for m in (live or members)]),
                    bubble_=None if is_open else bubble(group_counts(members, unsaved)),
                    expandable=True,
                    is_open=is_open,
                    count=len(members),
                    hidden=all(m["hidden"] for m in members),
                    suppressed=all(m["suppressed"] for m in members),
                )
            )
            if is_open:
                for i in item["group"]:
                    emit_occurrence(children[i], names[i]["name"], depth + 1)

    emit_level(tree, "", 1)
    mates = tree.get("mates")
    if mates and mates["count"] > 0:
        rows.append(_row(folder_key("", "mates"), "mates_folder", 1, "Mates", bubble_=bubble(own_level_counts(tree)), expandable=True, is_open=folder_key("", "mates") in open_keys, count=mates["count"]))
    patterns = tree.get("patterns")
    if patterns and patterns["count"] > 0:
        rows.append(_row(folder_key("", "patterns"), "patterns_folder", 1, "Patterns", expandable=True, is_open=folder_key("", "patterns") in open_keys, count=patterns["count"]))
    emit_features("", 1)
    return rows


def reveal(tree: dict[str, Any], path: list[str], grouping: bool = True) -> list[str]:
    """The keys to open so the row at `path` is listed: each ancestor occurrence, and the group row an ancestor-or-self sits
    in when grouping is on. The root is always open and is not listed."""
    keys: list[str] = []
    node = tree
    for depth, occurrence_id in enumerate(path):
        children = node.get("children", [])
        parent_key = occurrence_key(path[:depth])
        for item in sibling_items(children, grouping):
            if "group" in item and any(children[i]["occurrence_id"] == occurrence_id for i in item["group"]):
                keys.append(group_key(parent_key, children[item["group"][0]]["occurrence_id"]))
        node = next(c for c in children if c["occurrence_id"] == occurrence_id)
        if depth < len(path) - 1:
            keys.append(occurrence_key(path[: depth + 1]))
    return keys


# --- Building a response from a small model (the backend's walk) --------------------------------------------------------

MAX_DEPTH = 32


def build_tree(model: dict[str, Any], root_id: str, status: bool, max_depth: int = MAX_DEPTH, max_nodes: int = 10_000) -> dict[str, Any]:
    """A `GET /parts/{root}/assembly-tree` response for `model`:
        {"parts": {part_id: {"name", "feature_count", "occurrences": [occ], "mates": {count, suppressed, broken, near, held, lost},
                             "patterns": {count, suppressed}}}}
        occ: {"id", "part" (a part id, or None for a missing file), "external_ref", "name_override", "fixed", "hidden",
              "suppressed", "color", "constraint": {status, dof, rigid_set, broken_mates, near_mates} | None}
    `status=False` drops `constraint` and the status-only counts, as the endpoint does without `?status=true`."""
    parts = model["parts"]
    counter = {"nodes": 0, "depth": False, "cap": False}
    placed: list[dict[str, Any]] = []

    def mates_of(part: dict[str, Any]) -> dict[str, Any]:
        mates = {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0, **part.get("mates", {})}
        if not status:
            mates.update(broken=None, near=None, held=None, lost=None)
        return mates

    def fill(part: dict[str, Any], node: dict[str, Any], ancestors: tuple[str, ...], path: list[str]) -> None:
        node["mates"] = mates_of(part)
        node["patterns"] = {"count": 0, "suppressed": 0, **part.get("patterns", {})}
        problems = {"missing": 0, "cycles": 0, "broken": node["mates"]["broken"], "over_constrained": 0 if status else None, "near": node["mates"]["near"]}
        for occ in part["occurrences"]:
            if counter["nodes"] >= max_nodes:
                counter["cap"] = True
                node["truncated"] = True
                break
            child = make(occ, ancestors, path)
            node["children"].append(child)
            if child["suppressed"]:
                continue
            if child["kind"] == "missing":
                problems["missing"] += 1
            elif child["cycle"]:
                problems["cycles"] += 1
            elif status and child["constraint"] and child["constraint"]["status"] == "over_constrained" and child["constraint"]["broken_mates"] == 0 and child["constraint"]["near_mates"] == 0:
                problems["over_constrained"] += 1
            if child["problems"] is not None:
                for k, v in child["problems"].items():
                    if v is not None:
                        problems[k] += v
        node["problems"] = problems

    def make(occ: dict[str, Any], ancestors: tuple[str, ...], parent_path: list[str]) -> dict[str, Any]:
        counter["nodes"] += 1
        path = parent_path + [occ["id"]]
        part_id = occ.get("part")
        part = parts.get(part_id) if part_id else None
        kind = "missing" if part is None else ("assembly" if part["occurrences"] else "part")
        constraint = None
        if status and occ.get("constraint") is not None:
            constraint = {"status": "under_constrained", "dof": 0, "rigid_set": None, "broken_mates": 0, "near_mates": 0, **occ["constraint"]}
        node = {
            "occurrence_id": occ["id"],
            "path": path,
            "external_ref": occ.get("external_ref", f"parts/{part_id}.didsa" if part_id else None),
            "ref_part_id": occ.get("ref_part_id", part_id),
            "resolved_part_id": part_id if part is not None else None,
            "part_name": part["name"] if part is not None else None,
            "name_override": occ.get("name_override"),
            "kind": kind,
            "fixed": occ.get("fixed", False),
            "hidden": occ.get("hidden", False),
            "suppressed": occ.get("suppressed", False),
            "color": occ.get("color"),
            "constraint": constraint,
            "feature_count": part.get("feature_count", 0) if part is not None else None,
            "placements": None,
            "cycle": False,
            "truncated": False,
            "mates": None,
            "patterns": None,
            "problems": None,
            "children": [],
        }
        if part is not None:
            placed.append(node)
        if kind != "assembly":
            return node
        if part_id in ancestors:
            node["cycle"] = True
            return node
        if len(path) >= max_depth:
            node["truncated"] = True
            counter["depth"] = True
            return node
        fill(part, node, ancestors + (part_id,), path)
        return node

    root = parts[root_id]
    response = {
        "part_id": root_id,
        "part_name": root["name"],
        "kind": "assembly" if root["occurrences"] else "part",
        "feature_count": root.get("feature_count", 0),
        "status_included": status,
        "truncated": False,
        "mates": None,
        "patterns": None,
        "problems": None,
        "children": [],
    }
    if root["occurrences"]:
        fill(root, response, (root_id,), [])
    totals: dict[str, int] = {}
    for node in placed:
        totals[node["resolved_part_id"]] = totals.get(node["resolved_part_id"], 0) + 1
    for node in placed:
        node["placements"] = totals[node["resolved_part_id"]]
    response.update(node_count=counter["nodes"], max_depth=max_depth, max_nodes=max_nodes, truncated_depth=counter["depth"], truncated_nodes=counter["cap"])
    return response
