"""Reference implementation of the assembly tree's client rules (DIDSA-CAD `docs/assembly-tree/spec.md`).

Pure Python, standard library only. It is not used by any app: it exists to produce `docs/assembly-tree/vectors.json`
(`generate.py`), which the Flutter client and DIDSA-VR test their own copies of these rules against. Every function here
is one rule of the spec, named after the spec's section.

Two halves:
- `build_tree` turns a small hand-written model into a `GET /parts/{id}/assembly-tree` response, following the
  backend's walk (spec "Response", "Problem counts"), so the vectors' input trees are consistent without typing them out.
- `visible_rows` and the helpers above it are what a client does with a response (spec "Display names" to "Row keys", and
  sections 11 to 14).
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
    or `ordinal`. For a single node; `sibling_names` names placements of the same Part alike."""
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


def _has_override(node: dict[str, Any]) -> bool:
    override = node.get("name_override")
    return override is not None and override.strip() != ""


def instance_key(node: dict[str, Any]) -> str | None:
    """Which siblings are "the same thing placed again": unnamed placements of the same resolved Part, or, for a missing file,
    of the same `external_ref`. A renamed placement has no key."""
    if _has_override(node):
        return None
    if node.get("resolved_part_id"):
        return "part:" + node["resolved_part_id"]
    if node.get("external_ref"):
        return "file:" + node["external_ref"]
    return None


def sibling_names(children: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Per child, in order: {name, base, key}. Siblings sharing an instance key form one instance group, named alike: the
    Part's name unless it looks generated, else the file name of the first member (in sibling order) whose file name does
    not look generated. A group with neither has no name of its own: each member is `Component N` and is not numbered or
    grouped (key None). Members of a group of two or more are numbered `Base <1>`, `Base <2>`... in sibling order; a group of
    one keeps the plain base name. Every other child: `base_name`."""
    keys = [instance_key(child) for child in children]
    group_base: dict[str, str | None] = {}
    for child, key in zip(children, keys):
        if key is None:
            continue
        if key not in group_base:
            part_name = child.get("part_name")
            group_base[key] = part_name if key.startswith("part:") and not looks_generated(part_name) else None
        if group_base[key] is None:
            file_name = file_base_name(child.get("external_ref"))
            if file_name is not None and not looks_generated(file_name):
                group_base[key] = file_name
    keys = [key if key is not None and group_base[key] is not None else None for key in keys]
    totals: dict[str, int] = {}
    for key in keys:
        if key is not None:
            totals[key] = totals.get(key, 0) + 1
    seen: dict[str, int] = {}
    out = []
    for i, (child, key) in enumerate(zip(children, keys)):
        if key is None:
            base = base_name(child, i)[0]
            out.append({"name": base, "base": base, "key": None})
            continue
        base = group_base[key]
        if totals[key] > 1:
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


# --- The live part (spec section 13) -------------------------------------------------------------------------------------

FEATURE_STATES = ["lost_reference", "moved_reference", "pending_detail", "rolled_back", "hidden", "none"]
DEFAULT_PLANES = [("xy", "XY plane"), ("xz", "XZ plane"), ("yz", "YZ plane")]
FOLDERS = [("bodies", "Bodies", "body"), ("planes", "Planes", None), ("surfaces", "Surfaces", "surface"), ("curves", "Curves", "curve")]


def feature_state(feature: dict[str, Any]) -> str:
    """The one state a live feature row shows, most severe first (`FEATURE_STATES`). `lost_reference` is the reason (a string)
    or null; the other flags are booleans. A missing flag is false. `hidden` is also the row's own `hidden` field."""
    if feature.get("lost_reference") is not None:
        return "lost_reference"
    if feature.get("moved_reference"):
        return "moved_reference"
    if feature.get("pending_detail"):
        return "pending_detail"
    if feature.get("rolled_back"):
        return "rolled_back"
    if feature.get("hidden"):
        return "hidden"
    return "none"


def plane_feature_key(owner_key: str, feature_id: str) -> str:
    """A plane feature in the Planes folder: always `K#plane:feature:<id>`, so it can never share a key with a default plane
    (`K#plane:xy`, `xz`, `yz`), whatever a hand-written file calls its features."""
    return owner_key + "#plane:feature:" + feature_id


# --- A folder per assembly level (spec section 14) ------------------------------------------------------------------------

ITEM_STATES = ["lost", "broken", "near", "held", "suppressed", "none"]


def item_state(item: dict[str, Any]) -> str:
    """The one state a mate or pattern item row shows, most severe first (`ITEM_STATES`). Input as the spec gives it: `status`
    (`ok` / `near` / `broken`, the `/mates` listing's), `held`, `lost` (`lost_references` not empty), `suppressed`; a pattern has
    only `suppressed`. A missing field is ok / false."""
    if item.get("lost"):
        return "lost"
    status = item.get("status") or "ok"
    if status == "broken":
        return "broken"
    if status == "near":
        return "near"
    if item.get("held"):
        return "held"
    if item.get("suppressed"):
        return "suppressed"
    return "none"


MATE_TYPE_LABELS = {
    "coincident": "Coincident",
    "concentric": "Concentric",
    "parallel": "Parallel",
    "distance": "Distance",
    "angle": "Angle",
    "gear": "Gear",
    "rack_pinion": "Rack and pinion",
    "screw": "Screw",
    "limit_distance": "Limit distance",
    "limit_angle": "Limit angle",
}
PATTERN_TYPE_LABELS = {"linear": "Linear", "circular": "Circular"}


def _is_symmetric(mate: dict[str, Any]) -> bool:
    refs = mate.get("references") or []
    return len(refs) == 2 and refs[0].get("midplane") is not None and refs[1].get("midplane") is None


def _is_width(mate: dict[str, Any]) -> bool:
    return any(r.get("midplane") is not None for r in mate.get("references") or []) and not _is_symmetric(mate)


def mate_names(mates: list[dict[str, Any]]) -> list[str]:
    """One level's `/mates` entries, in listing order -> their labels. A Symmetric mate (exactly two references, the first a
    mid-plane, the second not) is `Symmetric N`; any other mate with a mid-plane reference is `Width N`; every other mate is its
    type's label (`MATE_TYPE_LABELS`, an unknown type as written) and N. N counts, up to and including this one, the mates named
    the same way: Symmetric among Symmetric, Width among Width, else the same `type` that is neither."""
    out = []
    for i, mate in enumerate(mates):
        before = mates[: i + 1]
        if _is_symmetric(mate):
            out.append(f"Symmetric {sum(1 for m in before if _is_symmetric(m))}")
        elif _is_width(mate):
            out.append(f"Width {sum(1 for m in before if _is_width(m))}")
        else:
            n = sum(1 for m in before if m["type"] == mate["type"] and not _is_width(m) and not _is_symmetric(m))
            out.append(f"{MATE_TYPE_LABELS.get(mate['type'], mate['type'])} {n}")
    return out


def pattern_names(patterns: list[dict[str, Any]]) -> list[str]:
    """One level's `/component-patterns` entries -> their labels: the `pattern_type`'s label (`PATTERN_TYPE_LABELS`, an unknown
    type as written) and N, counting the patterns of that type up to and including this one."""
    return [
        f"{PATTERN_TYPE_LABELS.get(p['pattern_type'], p['pattern_type'])} {sum(1 for q in patterns[: i + 1] if q['pattern_type'] == p['pattern_type'])}"
        for i, p in enumerate(patterns)
    ]


def item_key(folder_key_: str, item_id: str) -> str:
    return folder_key_ + "#item:" + item_id


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
    live: dict[str, Any] | None = None,
    items: dict[str, list[dict[str, Any]]] | None = None,
    *,
    listed: set[str] | None = None,
    trace: dict[str, dict[str, Any]] | None = None,
    open_all: bool = False,
) -> list[dict[str, Any]]:
    """The flat list of rows to draw, top to bottom (spec "Visible rows").

    `live` (section 13) adds the live part's folders and features, and a `type` to every row. `items` (section 14) are the mate
    and pattern items fetched per folder key. `listed`, `trace` and `open_all`
    are for the filter and for restore (sections 11 and 12): with `listed` only those keys are emitted; `open_all` opens
    everything that can open; `trace` receives, per emitted key, its parent's key and its row's `fixed` flag."""
    unsaved = frozenset(unsaved_part_ids)
    features = features or {}
    items = items or {}
    live_key = live["key"] if live is not None else None
    rows: list[dict[str, Any]] = []

    def is_open_key(key: str) -> bool:
        return open_all or key in open_keys

    def add(row: dict[str, Any], parent: str | None, fixed: bool = False, type_: str | None = None) -> bool:
        if listed is not None and row["key"] not in listed:
            return False
        if live is not None:
            row["type"] = type_
        rows.append(row)
        if trace is not None:
            trace[row["key"]] = {"parent": parent, "fixed": fixed}
        return True

    add(_row("", "root", 0, tree["part_name"], state="unsaved" if tree["part_id"] in unsaved else "none", expandable=False, is_open=True, path=[]), None)

    def emit_features(node_key: str, depth: int) -> None:
        for feature in features.get(node_key, []):
            add(_row(feature_key(node_key, feature["id"]), "feature", depth, feature["label"]), node_key)

    def emit_live(node_key: str, depth: int) -> None:
        """Section 13: the folders, then the features in build order."""
        feats = live.get("features", [])
        contents = {"bodies": live.get("bodies", []), "surfaces": live.get("surfaces", []), "curves": live.get("curves", [])}
        for name, label, item_kind in FOLDERS:
            if name == "planes":
                plane_features = [f for f in feats if f.get("type") == "create_plane"]
                count = len(DEFAULT_PLANES) + len(plane_features)
            else:
                count = len(contents[name])
                if count == 0:
                    continue
            fkey = folder_key(node_key, name)
            opened = is_open_key(fkey)
            if not add(_row(fkey, f"{name}_folder", depth, label, expandable=True, is_open=opened, count=count), node_key) or not opened:
                continue
            if name == "planes":
                hidden = live.get("default_planes_hidden", {})
                for plane_id, plane_label in DEFAULT_PLANES:
                    h = bool(hidden.get(plane_id, False))
                    add(_row(f"{node_key}#plane:{plane_id}", "default_plane", depth + 1, plane_label, state="hidden" if h else "none", hidden=h), fkey)
                for f in plane_features:
                    add(_row(plane_feature_key(node_key, f["id"]), "feature", depth + 1, f["label"], state=feature_state(f), hidden=bool(f.get("hidden"))), fkey, type_=f.get("type"))
            else:
                for item in contents[name]:
                    h = bool(item.get("hidden"))
                    add(_row(f"{node_key}#{item_kind}:{item['id']}", item_kind, depth + 1, item["label"], state="hidden" if h else "none", hidden=h), fkey)
        for f in feats:
            add(_row(feature_key(node_key, f["id"]), "feature", depth, f["label"], state=feature_state(f), hidden=bool(f.get("hidden"))), node_key, type_=f.get("type"))

    def emit_tail(node_key: str, depth: int) -> None:
        if live is not None and node_key == live_key:
            emit_live(node_key, depth)
        else:
            emit_features(node_key, depth)

    def mates_folder_listed(node: dict[str, Any], node_key: str) -> bool:
        """Whether an open row's Mates folder is listed: it has mates, and no filter leaves it out (section 14's bubble rule)."""
        mates = node.get("mates")
        return bool(mates and mates["count"] > 0) and (listed is None or folder_key(node_key, "mates") in listed)

    def emit_level_folders(node: dict[str, Any], node_key: str, depth: int) -> None:
        """Section 14: under an open assembly (or the root), after its children: Mates, then Patterns, each with its fetched items."""
        for name, kind, item_kind, counts in (("mates", "mates_folder", "mate", node.get("mates")), ("patterns", "patterns_folder", "pattern", node.get("patterns"))):
            if not counts or counts["count"] <= 0:
                continue
            fkey = folder_key(node_key, name)
            opened = is_open_key(fkey)
            bubble_ = bubble(own_level_counts(node)) if name == "mates" else None
            label = "Mates" if name == "mates" else "Patterns"
            if not add(_row(fkey, kind, depth, label, bubble_=bubble_, expandable=True, is_open=opened, count=counts["count"]), node_key) or not opened:
                continue
            for item in items.get(fkey, []):
                add(_row(item_key(fkey, item["id"]), item_kind, depth + 1, item["label"], state=item_state(item), suppressed=bool(item.get("suppressed"))), fkey)

    def emit_occurrence(node: dict[str, Any], name: str, depth: int, parent: str) -> None:
        key = occurrence_key(node["path"])
        expandable = _expandable(node) or (live is not None and key == live_key and node["kind"] != "missing")
        is_open = expandable and is_open_key(key)
        if not expandable:
            counts = None
        elif is_open:
            # Section 14: an open row's own mates are shown on its Mates folder; only when that folder is not listed (a filter) does
            # the row keep them.
            counts = None if mates_folder_listed(node, key) else own_level_counts(node)
        else:
            counts = subtree_counts(node, unsaved)
        shown = add(
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
            ),
            parent,
            fixed=node["fixed"],
        )
        if shown and is_open:
            emit_level(node, key, depth + 1)
            emit_level_folders(node, key, depth + 1)
            emit_tail(key, depth + 1)

    def emit_level(node: dict[str, Any], node_key: str, depth: int) -> None:
        children = node.get("children", [])
        names = sibling_names(children)
        for item in sibling_items(children, grouping):
            if "node" in item:
                emit_occurrence(item["node"], item["name"], depth, node_key)
                continue
            members = [children[i] for i in item["group"]]
            live_members = [m for m in members if not m["suppressed"]]  # the group's state: its worst unsuppressed member (all suppressed: its worst)
            key = group_key(node_key, members[0]["occurrence_id"])
            is_open = is_open_key(key)
            shown = add(
                _row(
                    key,
                    "group",
                    depth,
                    f"{item['base']} x{len(members)}",
                    state=worst_state([state_slot(m, unsaved) for m in (live_members or members)]),
                    bubble_=None if is_open else bubble(group_counts(members, unsaved)),
                    expandable=True,
                    is_open=is_open,
                    count=len(members),
                    hidden=all(m["hidden"] for m in members),
                    suppressed=all(m["suppressed"] for m in members),
                ),
                node_key,
            )
            if shown and is_open:
                for i in item["group"]:
                    emit_occurrence(children[i], names[i]["name"], depth + 1, key)

    emit_level(tree, "", 1)
    emit_level_folders(tree, "", 1)
    emit_tail("", 1)
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


# --- Filter (spec section 11) -------------------------------------------------------------------------------------------

ERROR_STATES = frozenset({"missing", "cycle", "broken", "over_constrained", "lost_reference", "lost"})  # item rows: lost, broken (section 14)
WARNING_STATES = frozenset({"near", "moved_reference", "held"})  # item rows: near, held
# token -> test(row, fixed flag). Written out one by one so the spec's list and this one can be compared line by line.
TOKENS = {
    ":missing": lambda r, fixed: r["state"] == "missing",
    ":errors": lambda r, fixed: r["state"] in ERROR_STATES,
    ":warnings": lambda r, fixed: r["state"] in WARNING_STATES,
    ":unsaved": lambda r, fixed: r["state"] == "unsaved",
    ":fixed": lambda r, fixed: fixed,
    ":hidden": lambda r, fixed: r["hidden"],
    ":suppressed": lambda r, fixed: r["suppressed"],
    ":parts": lambda r, fixed: r["kind"] == "part",
    ":assemblies": lambda r, fixed: r["kind"] == "assembly",
    ":features": lambda r, fixed: r["kind"] == "feature",
    ":sketches": lambda r, fixed: r.get("type") == "sketch",
    ":mates": lambda r, fixed: r["kind"] == "mate",
}
NON_MATCHING_KINDS = frozenset({"root", "group", "mates_folder", "patterns_folder", "bodies_folder", "planes_folder", "surfaces_folder", "curves_folder"})


def parse_query(query: str) -> tuple[list[str], list[str], list[str]]:
    """(name terms, known tokens, unknown tokens), all lower case, in query order, each listed once. Words are split on runs of
    whitespace; a word starting with `:` is a token."""
    terms: list[str] = []
    tokens: list[str] = []
    unknown: list[str] = []
    for word in query.lower().split():
        bucket = (tokens if word in TOKENS else unknown) if word.startswith(":") else terms
        if word not in bucket:
            bucket.append(word)
    return terms, tokens, unknown


def filter_rows(
    tree: dict[str, Any],
    query: str,
    open_keys: set[str] | frozenset[str] = frozenset(),
    grouping: bool = True,
    unsaved_part_ids: set[str] | frozenset[str] = frozenset(),
    features: dict[str, list[dict[str, Any]]] | None = None,
    live: dict[str, Any] | None = None,
    items: dict[str, list[dict[str, Any]]] | None = None,
) -> dict[str, Any]:
    """`{"rows", "unknown"}`: section 7's (or section 13's) rows narrowed to the root, the matches and their ancestors. Every row
    has `match`. An empty query is no filter (the rows for `open_keys`, every `match` false). A query with words but no
    criteria (only unknown tokens) is a filter that matches nothing."""
    terms, tokens, unknown = parse_query(query)
    if not query.split():
        rows = visible_rows(tree, open_keys, grouping, unsaved_part_ids, features, live, items)
        return {"rows": [{**row, "match": False} for row in rows], "unknown": []}
    trace: dict[str, dict[str, Any]] = {}
    everything = visible_rows(tree, frozenset(), grouping, unsaved_part_ids, features, live, items, open_all=True, trace=trace)
    matches = set()
    if terms or tokens:
        for row in everything:
            if row["kind"] in NON_MATCHING_KINDS:
                continue
            if all(term in row["label"].lower() for term in terms) and all(TOKENS[t](row, trace[row["key"]]["fixed"]) for t in tokens):
                matches.add(row["key"])
    listed = {""}
    for key in matches:
        while key is not None and key not in listed:
            listed.add(key)
            key = trace[key]["parent"]
    opened = {trace[key]["parent"] for key in listed if key != ""}  # a listed row is open when something below it is listed
    rows = visible_rows(tree, opened, grouping, unsaved_part_ids, features, live, items, listed=listed)
    return {"rows": [{**row, "match": row["key"] in matches} for row in rows], "unknown": unknown}


# --- Remembered open rows (spec section 12) -------------------------------------------------------------------------------

MAX_STORED_KEYS = 2000
OPEN_KINDS = frozenset({"assembly", "part", "group", "mates_folder", "patterns_folder", "bodies_folder", "planes_folder", "surfaces_folder", "curves_folder"})


def restore(tree: dict[str, Any], stored: list[str], live: dict[str, Any] | None = None, limit: int = MAX_STORED_KEYS) -> list[str]:
    """The stored open keys that still name a row that can open, in the visible-row order of the tree with everything open
    (grouping on: group keys are checked under that setting, so switching grouping off and on loses nothing), at most `limit`.
    Feature, body, surface, curve, plane and item keys are never open keys; the root's `""` is always open and never stored.
    A Mates or Patterns folder key of any level is kept when that folder shows (its level has mates / patterns, section 14)."""
    wanted = set(stored)
    rows = visible_rows(tree, frozenset(), True, frozenset(), {}, live, open_all=True)
    kept = [r["key"] for r in rows if r["key"] in wanted and r["kind"] in OPEN_KINDS and r["expandable"]]
    return kept[:limit]


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
            "status_failed": False,
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
        "status_failed": False,
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
    response.update(node_count=counter["nodes"], max_depth=max_depth, max_nodes=max_nodes, truncated_depth=counter["depth"], truncated_nodes=counter["cap"], status_incomplete=False)
    return response
