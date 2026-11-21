#!/usr/bin/env python3
"""Golden vectors for the assembly tree (DIDSA-CAD `docs/assembly-tree/spec.md`).

    python tools/assembly_tree_vectors/generate.py            # (re)writes docs/assembly-tree/vectors.json and the backend copy
    python tools/assembly_tree_vectors/generate.py --check    # exits 1 if a committed file differs

Never edit vectors.json by hand: change the models or cases here (or the rules in reference.py) and regenerate.
`test_reference.py` fails when the committed file is not what this script writes.

The file is self-contained, so DIDSA-VR copies it as-is (`tests/fixtures/assembly_tree_vectors.json`):
- `trees`: named `GET /parts/{id}/assembly-tree` responses (every field of the spec's Response), built by
  `reference.build_tree` from the small models below. Ids are made up and only mean something inside the file.
- `cases`: `kind: "rows"` gives the inputs of the spec's "Visible rows" (`tree`, `open` keys, `grouping`,
  `unsaved_part_ids`, `features` per row key) and `expected` (the rows, top to bottom, every field);
  `kind: "reveal"` gives a `path` and `grouping` and `expected` (the keys to open, in order).
  `why` says what the case pins. Deterministic: no randomness, keys sorted.
- Version 2 adds (spec sections 11 to 13): `kind: "filter"` (the rows inputs plus `query`; `expected`: `{rows, unknown}`, every row
  with `match`), `"restore"` (`stored`, `grouping`, `limit`; `expected`: the kept keys), `"live_part"` (the rows inputs plus
  `live`; every row has `type`), `"live_part_filter"` and `"live_part_restore"`. The 36 version 1 cases come first, unchanged.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import reference as ref  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "docs" / "assembly-tree" / "vectors.json"
# The backend's copy of a few models as native documents, with the trees the reference builds for them (no status): the
# endpoint must answer exactly these (backend/tests/test_assembly_tree.py). The CI image holds backend/ only, hence a copy.
BACKEND_OUT = REPO / "backend" / "tests" / "data" / "assembly_tree_rollup_vectors.json"
VERSION = 2  # vectors.json: 2 adds the filter, restore and live-part cases (spec sections 11-13); the 36 version 1 cases are first and unchanged
BACKEND_VERSION = 1  # the backend roll-up file did not change


def occ(id_, part, **fields):
    return {"id": id_, "part": part, **fields}


def part(name, occurrences=(), feature_count=1, **fields):
    return {"name": name, "occurrences": list(occurrences), "feature_count": feature_count, **fields}


FIXED = {"status": "fixed", "dof": 0}
FULL = {"status": "fully_constrained", "dof": 0}
UNDER = {"status": "under_constrained", "dof": 2}

# ---- the main model: a rover, three levels of sub-assembly and every kind of row --------------------------------------
# rover places: chassis (fixed), two wheels (one sub-assembly placed twice), a mast (4 levels deep down to mast/arm/head/lens),
# a camera whose Part name looks generated (named by its file), a missing battery, five unnamed screws and one renamed screw.
# Each wheel places a hub, a tyre and four bolts (a group). The head places a lens and a missing cable with a generated file name.
ROVER = {
    "parts": {
        "rover": part(
            "Rover",
            [
                occ("chassis", "chassis", fixed=True, constraint=FIXED),
                occ("wheel_l", "wheel", constraint=FULL),
                occ("wheel_r", "wheel", constraint=UNDER),
                occ("mast", "mast", constraint={"status": "over_constrained", "dof": 0, "broken_mates": 1}),
                occ("cam", "camera", constraint={"status": "over_constrained", "dof": 0, "near_mates": 2}, external_ref="parts/camera_v2.didsa"),
                occ("batt", None, external_ref="parts/battery.didsa"),
                occ("s1", "screw", constraint=FULL),
                occ("s2", "screw", constraint=FULL),
                occ("lid", "screw", name_override="Lid screw", constraint=FULL),
                occ("s3", "screw", constraint=UNDER, hidden=True),
                occ("s4", "screw", constraint=FULL),
                occ("s5", "screw", constraint=FULL, hidden=True),
            ],
            feature_count=2,
            mates={"count": 9, "suppressed": 1, "broken": 1, "near": 2, "held": 1, "lost": 1},
            patterns={"count": 1, "suppressed": 0},
        ),
        "chassis": part("Chassis", feature_count=5),
        "wheel": part(
            "Wheel",
            [
                occ("hub", "hub", fixed=True, constraint=FIXED),
                occ("tyre", "tyre", constraint=UNDER),
                occ("b1", "bolt", constraint=FULL),
                occ("b2", "bolt", constraint=FULL),
                occ("b3", "bolt", constraint=FULL),
                occ("b4", "bolt", constraint=UNDER),
            ],
            feature_count=0,
            mates={"count": 6, "suppressed": 0, "broken": 0, "near": 1, "held": 0, "lost": 0},
        ),
        "hub": part("Hub"),
        "tyre": part("Tyre"),
        "bolt": part("Bolt M4"),
        "mast": part("Mast", [occ("base", "mast_base", fixed=True, constraint=FIXED), occ("arm", "arm", constraint=FULL)], feature_count=0, mates={"count": 1}),
        "mast_base": part("Mast base"),
        "arm": part("Arm", [occ("seg", "segment", fixed=True, constraint=FIXED), occ("head", "head", constraint=FULL)], feature_count=0, mates={"count": 1}),
        "segment": part("Segment"),
        "head": part(
            "Head",
            [occ("lens", "lens", constraint=FULL), occ("cable", None, external_ref="parts/0f8e2a1c-9b7d-4e3f-8a6b-5c4d3e2f1a0b.didsa")],
            feature_count=1,
            mates={"count": 1},
        ),
        "lens": part("Lens", feature_count=3),
        "camera": part("part-0123456789abcdef0123"),
        "screw": part("Screw M3"),
    }
}

# ---- names: every fallback of the spec's "Display names" ------------------------------------------------------------------
NAMES = {
    "parts": {
        "root": part(
            "Names",
            [
                occ("n1", "bracket", name_override="Left bracket"),
                occ("n2", "bracket"),
                occ("n3", "bracket"),
                occ("n4", "uuid_named", external_ref="parts/spacer.didsa"),
                occ("n5", "uuid_named", external_ref="parts/spacer.didsa"),
                occ("n6", "anon", external_ref="parts/9c1f6d2e8b7a4f3e9d2c1b0a9f8e7d6c.didsa"),
                occ("n7", None, external_ref="lib/v1.2/clip.step.didsa"),
                occ("n8", None, external_ref="lib/v1.2/clip.step.didsa"),
                occ("n9", None, external_ref=None, ref_part_id=None),
                occ("n10", "plate_a"),
                occ("n11", "plate_b"),
                occ("n12", "pin", name_override="   "),
                occ("n13", "dotfile", external_ref="parts/.washer"),
            ],
            feature_count=0,
        ),
        "bracket": part("Bracket"),
        "uuid_named": part("3f2a9c1d-7e6b-4a5c-9d8e-1f2a3b4c5d6e"),
        "anon": part(""),
        "plate_a": part("Plate"),
        "plate_b": part("Plate"),
        "pin": part("Pin"),
        "dotfile": part("occ_0123456789abcdef"),
    }
}

# ---- one Part (its name generated) placed through different files: the first placement's file names them all -------------
REFS = {
    "parts": {
        "root": part(
            "Refs",
            [
                occ("r1", "arm", external_ref="parts/left_arm.didsa"),
                occ("r2", "arm", external_ref="parts/arm_copy.didsa"),
                occ("r3", "arm", external_ref="parts/left_arm.didsa"),
                occ("r4", "arm", external_ref="parts/0f8e2a1c-9b7d-4e3f-8a6b-5c4d3e2f1a0b.didsa"),
                occ("r5", "arm", external_ref="parts/spare_arm.didsa", name_override="Spare"),
            ],
            feature_count=0,
        ),
        "arm": part("4b1d0c2e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"),
    }
}

# ---- states: one row per state slot, and the precedence between them ------------------------------------------------------
STATES = {
    "parts": {
        "root": part(
            "States",
            [
                occ("missing", None, external_ref="parts/gone.didsa", fixed=True),
                occ("broken", "p_broken", constraint={"status": "over_constrained", "dof": 0, "broken_mates": 1, "near_mates": 1}),
                occ("broken_under", "p_broken_under", constraint={"status": "under_constrained", "dof": 1, "broken_mates": 2}),
                occ("over", "p_over", constraint={"status": "over_constrained", "dof": 0}),
                occ("near", "p_near", constraint={"status": "over_constrained", "dof": 0, "near_mates": 1}),
                occ("unsaved_under", "p_unsaved", constraint={"status": "under_constrained", "dof": 3}),
                occ("unsaved_broken", "p_unsaved", name_override="Unsaved but broken", constraint={"status": "fully_constrained", "dof": 0, "broken_mates": 1}),
                occ("under", "p_under", constraint={"status": "under_constrained", "dof": 6}),
                occ("fixed", "p_fixed", fixed=True, constraint=FIXED),
                occ("fixed_flag", "p_fixed_flag", fixed=True),
                occ("full", "p_full", constraint=FULL),
                occ("free", "p_free"),
            ],
            feature_count=0,
            mates={"count": 4, "suppressed": 0, "broken": 2, "near": 1, "held": 0, "lost": 0},
        ),
        **{
            pid: part(name)
            for pid, name in (
                ("p_broken", "Broken"),
                ("p_broken_under", "Broken under"),
                ("p_over", "Over"),
                ("p_near", "Near"),
                ("p_unsaved", "Unsaved"),
                ("p_under", "Under"),
                ("p_fixed", "Fixed"),
                ("p_fixed_flag", "Fixed flag"),
                ("p_full", "Full"),
                ("p_free", "Free"),
            )
        },
    }
}

# ---- cycle: a Part placed inside itself (directly, and through another Part) ---------------------------------------------
CYCLE = {
    "parts": {
        "top": part("Top", [occ("a", "loop_a"), occ("self", "top")], feature_count=0),
        "loop_a": part("Loop A", [occ("b", "loop_b")], feature_count=0),
        "loop_b": part("Loop B", [occ("back", "loop_a"), occ("leaf", "leaf")], feature_count=2),
        "leaf": part("Leaf"),
    }
}

# ---- caps: a chain deeper than the depth cap, a level wider than the node cap ---------------------------------------------
DEEP = {
    "parts": {
        "d0": part("Depth 0", [occ("l1", "d1")], feature_count=0),
        "d1": part("Depth 1", [occ("l2", "d2")], feature_count=0),
        "d2": part("Depth 2", [occ("l3", "d3")], feature_count=0),
        "d3": part("Depth 3", [occ("l4", "d4"), occ("lost", None, external_ref="parts/lost.didsa")], feature_count=0),
        "d4": part("Depth 4"),
    }
}
WIDE = {"parts": {"w": part("Wide", [occ(f"c{i}", "cube") for i in range(1, 7)], feature_count=0), "cube": part("Cube")}}

# ---- a suppressed sub-assembly with problems inside: they do not reach the rows above ------------------------------------
SUPPRESSED = {
    "parts": {
        "top": part("Top", [occ("sub", "sub", suppressed=True), occ("ok", "frame", constraint=FULL)], feature_count=0, mates={"count": 1}),
        "sub": part("Sub", [occ("gone", None, external_ref="parts/gone.didsa"), occ("frame", "frame", constraint={"status": "over_constrained", "dof": 0})], feature_count=0),
        "frame": part("Frame"),
    }
}

# ---- unsaved Parts below collapsed rows (nothing worse there, so the bubble says unsaved) --------------------------------
UNSAVED = {
    "parts": {
        "root": part("Unsaved", [occ("frame", "frame_asm", constraint=FULL), occ("spare", "frame_asm", suppressed=True)], feature_count=0, mates={"count": 1}),
        "frame_asm": part("Frame", [occ("b1", "bolt_u", constraint=FULL), occ("b2", "bolt_u", constraint=FULL), occ("plate", "plate_u", fixed=True, constraint=FIXED)], feature_count=0, mates={"count": 2}),
        "bolt_u": part("Bolt"),
        "plate_u": part("Plate"),
    }
}

# ---- a Part opened on its own: the same tree with the part at the root, features under it --------------------------------
SINGLE = {"parts": {"solo": part("Bracket", feature_count=3)}}

# ---- missing files placed four times (grouped by file) and a group with a missing member ----------------------------------
REPEATS = {
    "parts": {
        "root": part(
            "Repeats",
            [
                occ("m1", None, external_ref="parts/nut.didsa"),
                occ("w1", "washer", constraint=FULL),
                occ("m2", None, external_ref="parts/nut.didsa"),
                occ("m3", None, external_ref="parts/nut.didsa"),
                occ("w2", "washer", constraint=UNDER),
                occ("m4", None, external_ref="parts/nut.didsa"),
                occ("w3", "washer", suppressed=True, constraint={"status": "over_constrained", "dof": 0}),
                occ("w4", "washer", constraint=FULL),
                occ("k1", "kit", constraint=FULL),
                occ("k2", "kit", constraint=FULL),
                occ("k3", "kit", constraint=FULL),
                occ("k4", "kit", constraint=FULL),
            ],
            feature_count=0,
        ),
        "washer": part("Washer"),
        "kit": part("Kit", [occ("pin", "pin", constraint=FULL), occ("tag", None, external_ref="parts/tag.didsa")], feature_count=0),
        "pin": part("Pin"),
    }
}

# ---- version 2: three identical bolts, not enough to group (a group key stored earlier no longer names a row) -----------------
THREE_BOLTS = {"parts": {"wheel": part("Wheel", [occ("b1", "bolt", constraint=FULL), occ("b2", "bolt", constraint=FULL), occ("b3", "bolt", constraint=FULL)], feature_count=0), "bolt": part("Bolt M4")}}

TREES = {
    "rover": ref.build_tree(ROVER, "rover", status=True),
    "rover_no_status": ref.build_tree(ROVER, "rover", status=False),
    "names": ref.build_tree(NAMES, "root", status=True),
    "refs": ref.build_tree(REFS, "root", status=False),
    "states": ref.build_tree(STATES, "root", status=True),
    "states_no_status": ref.build_tree(STATES, "root", status=False),
    "cycle": ref.build_tree(CYCLE, "top", status=False),
    "deep_capped": ref.build_tree(DEEP, "d0", status=False, max_depth=3),
    "wide_capped": ref.build_tree(WIDE, "w", status=False, max_nodes=3),
    "unsaved": ref.build_tree(UNSAVED, "root", status=True),
    "suppressed": ref.build_tree(SUPPRESSED, "top", status=True),
    "single_part": ref.build_tree(SINGLE, "solo", status=True),
    "repeats": ref.build_tree(REPEATS, "root", status=True),
    "wheel_three_bolts": ref.build_tree(THREE_BOLTS, "wheel", status=True),
}

FEATURES_LENS = {"mast/arm/head/lens": [{"id": "f1", "label": "Sketch 1"}, {"id": "f2", "label": "Revolve 1"}, {"id": "f3", "label": "Fillet 1"}]}
FEATURES_ROOT = {"": [{"id": "f1", "label": "Sketch 1"}, {"id": "f2", "label": "Extrude 1"}, {"id": "f3", "label": "Fillet 1"}]}


def rows_case(name, why, tree, open_keys=(), grouping=True, unsaved=(), features=None):
    return {
        "kind": "rows",
        "name": name,
        "why": why,
        "tree": tree,
        "open": list(open_keys),
        "grouping": grouping,
        "unsaved_part_ids": list(unsaved),
        "features": features or {},
    }


def reveal_case(name, why, tree, path, grouping=True):
    return {"kind": "reveal", "name": name, "why": why, "tree": tree, "path": list(path), "grouping": grouping}


CASES = [
    # --- visible rows and keys
    rows_case("rover_collapsed", "The default: the root open, everything below collapsed; group rows, folders, bubbles on collapsed rows.", "rover"),
    rows_case(
        "rover_both_wheels_open",
        "One sub-assembly placed twice: the same child ids get distinct keys under each placement (wheel_l/hub, wheel_r/hub); an open row's bubble is its own mates only.",
        "rover",
        ["wheel_l", "wheel_r"],
    ),
    rows_case(
        "rover_wheel_group_open",
        "A group open under one placement only: its key includes the parent's path; members are numbered Bolt M4 <1>..<4>.",
        "rover",
        ["wheel_l", "wheel_l/#group:b1"],
    ),
    rows_case(
        "rover_four_deep_with_features",
        "Four levels open down to a part, with its features listed under it (keys <path>#feature:<id>); the missing cable has a generated file name: Component 2.",
        "rover",
        ["mast", "mast/arm", "mast/arm/head", "mast/arm/head/lens"],
        features=FEATURES_LENS,
    ),
    rows_case("rover_open_part_without_features_yet", "An open part whose features the client has not fetched: no rows under it yet, still open.", "rover", ["chassis"]),
    rows_case("rover_screws_group_open", "The root-level group open: key #group:s1; the renamed screw stays a row of its own where it was.", "rover", ["#group:s1"]),
    rows_case("rover_grouping_off", "Grouping switched off: the repeats are listed one by one with their numbers.", "rover", ["wheel_l"], grouping=False),
    rows_case("rover_folders_open", "The root's Mates and Patterns folders open (their contents are the client's: not rows here); an open key on a row that cannot open (a missing file) is ignored.", "rover", ["#mates", "#patterns", "batt"]),
    rows_case("rover_unsaved", "Unsaved is client state: an unsaved Part's rows say unsaved over a lesser state; a worse problem below still wins the bubble.", "rover", ["mast", "mast/arm"], unsaved=["head", "bolt"]),
    rows_case("unsaved_bubble", "A collapsed row counts the unsaved rows below it (one per placement); a suppressed placement adds nothing above but keeps its own bubble.", "unsaved", unsaved=["bolt_u"]),
    rows_case("unsaved_open", "...open: the rows themselves say unsaved; an unsaved sub-assembly Part marks its own row too.", "unsaved", ["frame"], unsaved=["bolt_u", "frame_asm"]),
    rows_case("rover_unsaved_root", "The root's own Part unsaved: the root row says so.", "rover", unsaved=["rover"]),
    rows_case("rover_no_status", "Without ?status=true: no constraint states, only missing / cycle / unsaved / fixed flags; bubbles count missing files and cycles only.", "rover_no_status", ["mast", "mast/arm"]),
    rows_case("rover_no_status_grouping_off", "Without status, grouping off.", "rover_no_status", grouping=False),
    # --- names
    rows_case("names", "Every name fallback: override, Part name, file name, Component N; generated names skipped; numbering per Part (or per file when missing).", "names"),
    rows_case("names_grouping_off", "Names do not depend on grouping when nothing reaches four.", "names", grouping=False),
    rows_case(
        "names_one_part_through_different_files",
        "A Part with a generated name placed through different files: the first placement's file name names every placement of it "
        "(a generated file name included); a renamed placement keeps its own name.",
        "refs",
        grouping=False,
    ),
    rows_case("names_one_part_through_different_files_grouped", "...and the group takes the same name.", "refs", ["#group:r1"]),
    # --- states
    rows_case("states", "One row per state slot, and the precedence between them.", "states", unsaved=["p_unsaved"]),
    rows_case("states_no_status", "The same rows without status: the fixed flag is the only constraint information left.", "states_no_status", unsaved=["p_unsaved"]),
    # --- repeats
    rows_case("repeats", "Missing files group by file; a group sits where its first member was and shows its worst unsuppressed member's state; suppressed members add nothing to its bubble.", "repeats"),
    rows_case("repeats_open", "The groups open, and one sub-assembly member open inside its group.", "repeats", ["#group:m1", "#group:w1", "#group:k1", "k2"]),
    rows_case("repeats_grouping_off", "Grouping off: four and more are listed one by one.", "repeats", grouping=False),
    # --- guards
    rows_case("cycle", "A Part placed inside itself is a cycle row: no children, red, counted on the rows above.", "cycle", ["a", "a/b"]),
    rows_case("cycle_collapsed", "The cycle counted on the collapsed row above it.", "cycle"),
    rows_case("deep_capped", "Stopped at the depth cap: the last node is truncated (no children listed, not expandable when it has no features).", "deep_capped", ["l1", "l1/l2"]),
    rows_case("wide_capped", "Stopped at the node cap: only the first nodes are listed.", "wide_capped"),
    rows_case("suppressed", "A suppressed sub-assembly is listed (dimmed) and keeps its own bubble, but adds nothing to the rows above.", "suppressed"),
    rows_case("suppressed_open", "...open, its rows show their own states.", "suppressed", ["sub"]),
    rows_case("single_part", "A Part opened on its own: the root row and its features.", "single_part", features=FEATURES_ROOT),
    # --- reveal
    reveal_case("reveal_four_deep", "Reveal a row four levels down: open each ancestor.", "rover", ["mast", "arm", "head", "lens"]),
    reveal_case("reveal_top_level", "A top-level row needs nothing opened.", "rover", ["chassis"]),
    reveal_case("reveal_in_group", "A row inside a group: open its ancestors and the group.", "rover", ["wheel_r", "b3"]),
    reveal_case("reveal_in_group_off", "...with grouping off, only the ancestors.", "rover", ["wheel_r", "b3"], grouping=False),
    reveal_case("reveal_root_group", "A top-level member of a group: just the group.", "rover", ["s4"]),
    reveal_case("reveal_inside_group_member", "Below a member of a group: the group and the member.", "repeats", ["k3", "pin"]),
]


# ---- version 2: filter (section 11), restore (section 12), the live part (section 13) ----------------------------------
def filter_case(name, why, tree, query, open_keys=(), grouping=True, unsaved=(), features=None, live=None):
    return {
        "kind": "live_part_filter" if live is not None else "filter",
        "name": name,
        "why": why,
        "tree": tree,
        "query": query,
        "open": list(open_keys),
        "grouping": grouping,
        "unsaved_part_ids": list(unsaved),
        "features": features or {},
        **({"live": live} if live is not None else {}),
    }


def restore_case(name, why, tree, stored, grouping=True, limit=ref.MAX_STORED_KEYS, live=None):
    return {
        "kind": "live_part_restore" if live is not None else "restore",
        "name": name,
        "why": why,
        "tree": tree,
        "stored": list(stored),
        "grouping": grouping,
        "limit": limit,
        **({"live": live} if live is not None else {}),
    }


def live_case(name, why, tree, live, open_keys=(), grouping=True, unsaved=(), features=None):
    return {**rows_case(name, why, tree, open_keys, grouping, unsaved, features), "kind": "live_part", "live": live}


def lf(id_, label, type_, **flags):
    return {"id": id_, "label": label, "type": type_, **flags}


PLANES_SHOWN = {"xy": False, "xz": False, "yz": False}
# A part opened on its own: build order sketch, extrude, plane, sketch, fillet; one body.
LIVE_ALONE = {
    "key": "",
    "features": [
        lf("f1", "Sketch 1", "sketch"),
        lf("f2", "Extrude 1", "extrude"),
        lf("f3", "Plane 1", "create_plane"),
        lf("f4", "Sketch 2", "sketch", hidden=True),
        lf("f5", "Fillet 1", "fillet"),
    ],
    "bodies": [{"id": "b1", "label": "Body 1", "hidden": False}, {"id": "b2", "label": "Bracket tab", "hidden": True}],
    "surfaces": [],
    "curves": [{"id": "c1", "label": "Curve 1", "hidden": False}],
    "default_planes_hidden": {"xy": False, "xz": True, "yz": False},
}
LIVE_EMPTY = {"key": "", "features": [lf("f1", "Sketch 1", "sketch"), lf("f2", "Extrude 1", "extrude")], "bodies": [], "surfaces": [], "curves": [], "default_planes_hidden": PLANES_SHOWN}
# Every feature state, and two or three on one feature (the most severe wins).
LIVE_STATES = {
    "key": "",
    "features": [
        lf("s_lost", "Lost", "extrude", lost_reference="The sketch edge was deleted"),
        lf("s_moved", "Moved", "fillet", moved_reference=True),
        lf("s_pending", "Pending", "revolve", pending_detail=True),
        lf("s_rolled", "Rolled back", "sketch", rolled_back=True),
        lf("s_hidden", "Hidden", "sketch", hidden=True),
        lf("s_none", "Plain", "extrude"),
        lf("s_lost_moved_hidden", "Lost and moved and hidden", "fillet", lost_reference="The face moved away", moved_reference=True, hidden=True),
        lf("s_moved_pending", "Moved and pending", "chamfer", moved_reference=True, pending_detail=True),
        lf("s_pending_rolled", "Pending and rolled back", "extrude", pending_detail=True, rolled_back=True),
        lf("s_rolled_hidden", "Rolled back and hidden", "sketch", rolled_back=True, hidden=True),
    ],
    "bodies": [],
    "surfaces": [],
    "curves": [],
    "default_planes_hidden": PLANES_SHOWN,
}
# The live part three levels down in the rover (mast / arm / head places a lens and a missing cable).
LIVE_HEAD = {
    "key": "mast/arm/head",
    "features": [
        lf("h1", "Sketch 1", "sketch"),
        lf("h2", "Extrude 1", "extrude", lost_reference="The sketch was deleted"),
        lf("h3", "Fillet 1", "fillet", moved_reference=True),
    ],
    "bodies": [{"id": "hb1", "label": "Head body", "hidden": False}],
    "surfaces": [{"id": "hs1", "label": "Skin", "hidden": True}],
    "curves": [],
    "default_planes_hidden": PLANES_SHOWN,
}
LIVE_LENS = {"key": "mast/arm/head/lens", "features": [lf("l1", "Sketch 1", "sketch"), lf("l2", "Revolve 1", "revolve")], "bodies": [{"id": "lb1", "label": "Lens body", "hidden": False}], "surfaces": [], "curves": [], "default_planes_hidden": PLANES_SHOWN}
# A hand-written file can carry a plane feature whose id is xy: plane features are keyed #plane:feature:<id>, so no clash.
LIVE_XY = {"key": "", "features": [lf("xy", "Plane XY copy", "create_plane"), lf("f2", "Sketch 1", "sketch")], "bodies": [], "surfaces": [], "curves": [], "default_planes_hidden": PLANES_SHOWN}
FEATURES_FETCHED = {"mast/arm/head/lens": FEATURES_LENS["mast/arm/head/lens"], "chassis": [{"id": "g1", "label": "Sketch 1"}, {"id": "g2", "label": "Boss 1"}]}

CASES += [
    # --- filter: name terms
    filter_case("filter_empty_query", "An empty query is no filter: section 7's rows for the open keys, every match false.", "rover", "", ["wheel_l"]),
    filter_case("filter_spaces_only", "Only spaces is also no filter.", "rover", "   ", ["mast"]),
    filter_case("filter_deep_collapsed", "A name term deep in a collapsed branch: every ancestor is listed and open, the rest of each level is not; the open keys play no part.", "rover", "lens"),
    filter_case("filter_ignores_open_keys", "The same query with other rows open gives the same rows.", "rover", "lens", ["wheel_l", "chassis"]),
    filter_case("filter_case_insensitive", "Case does not matter.", "rover", "LEN"),
    filter_case("filter_in_group", "A match inside a group lists the group row (open) and only the matching members, under the open wheel.", "rover", "bolt m4 <3>"),
    filter_case("filter_two_terms", "Two name terms must both be in the label (AND); the order of the words does not matter.", "rover", "<2> screw"),
    filter_case("filter_instance_number", "`<2>` finds the second instance of every repeated Part, inside groups and out.", "rover", "<2>"),
    filter_case("filter_term_no_match", "Nothing matches: the root alone.", "rover", "zzz"),
    filter_case("filter_grouping_off", "Grouping off: no group rows; the members are listed by their ancestors.", "rover", "bolt <1>", grouping=False),
    filter_case("filter_group_and_own_label", "A group's own label never matches (`x4`), and neither does the root's (`rover`).", "rover", "x4 rover"),
    # --- filter: tokens
    filter_case("filter_missing", "`:missing`: the missing battery, and the missing cable below mast / arm / head.", "rover", ":missing"),
    filter_case("filter_errors", "`:errors`: missing, cycle, broken, over-constrained rows (the bubble's error set). A fixed, near or unsaved row is not one.", "rover", ":errors"),
    filter_case("filter_errors_no_status", "`:errors` without status finds only what section 5 lists for that case: the missing files.", "rover_no_status", ":errors"),
    filter_case("filter_warnings", "`:warnings`: state near.", "rover", ":warnings"),
    filter_case("filter_unsaved", "`:unsaved`: state unsaved (the client's set).", "rover", ":unsaved", unsaved=["bolt"]),
    filter_case("filter_fixed", "`:fixed`: the fixed flag, whatever the state (the mast's base is fixed and constrained both ways).", "rover", ":fixed"),
    filter_case("filter_fixed_flag_without_status", "`:fixed` without status still works: it is the flag.", "rover_no_status", ":fixed"),
    filter_case("filter_hidden", "`:hidden`: rows with the eye-off.", "rover", ":hidden"),
    filter_case("filter_suppressed", "`:suppressed`: a suppressed sub-assembly; its children are not suppressed themselves, so they do not match.", "suppressed", ":suppressed"),
    filter_case("filter_parts", "`:parts`: kind part (not assemblies, not missing).", "rover", ":parts"),
    filter_case("filter_assemblies", "`:assemblies`: kind assembly.", "rover", ":assemblies"),
    filter_case("filter_token_and_name", "A token and a name term: both must hold.", "rover", ":hidden screw"),
    filter_case("filter_two_tokens", "Two tokens: both must hold (AND).", "rover", ":parts :hidden"),
    filter_case("filter_token_case", "Tokens are case-insensitive too.", "rover", ":MISSING"),
    filter_case("filter_unknown_token", "An unknown token is left out of the matching and listed, lower case, once, in query order.", "rover", ":Foo lens :bar :foo"),
    filter_case("filter_only_unknown_token", "Only an unknown token: a filter with no criteria matches nothing, and says what it did not understand.", "rover", ":foo"),
    filter_case("filter_lone_colon", "A lone `:` is an unknown token.", "rover", ":"),
    # --- filter: features, fetched and not
    filter_case("filter_fetched_and_unfetched_features", "Feature rows match only where features were fetched: the lens's and the chassis's Sketch 1 are found; the mast base (one feature, not fetched) is not.", "rover", "sketch", features=FEATURES_FETCHED),
    filter_case("filter_features_token", "`:features`: every fetched feature row.", "rover", ":features", features=FEATURES_FETCHED),
    filter_case("filter_sketches_without_live_part", "`:sketches` needs a feature `type`: rows from section 7's `features` have none, so nothing matches.", "rover", ":sketches", features=FEATURES_FETCHED),
    filter_case("filter_root_features", "A part opened on its own: the root's features match by name.", "single_part", "fillet", features=FEATURES_ROOT),
    # --- restore
    restore_case(
        "restore_keeps_what_still_exists",
        "Kept: rows that can open. Dropped: a row that was deleted, a missing file, a feature key, a folder that does not exist; the order is the visible-row order of the tree with everything open, not the stored order.",
        "rover",
        ["#patterns", "wheel_l/#group:b1", "gone/row", "batt", "mast/arm/head/lens#feature:f1", "mast", "chassis", "#mates", "wheel_l", "#group:s1", "mast/arm/head#bodies"],
    ),
    restore_case("restore_group_key_with_grouping_off", "A group key is kept while grouping is off (it only names a row when grouping is on): switching grouping off and on loses nothing.", "rover", ["wheel_l", "wheel_l/#group:b1", "#group:s1"], grouping=False),
    restore_case("restore_group_that_no_longer_forms", "A group key whose group no longer has four members is dropped; the first member's own key stays (a part with features opens).", "wheel_three_bolts", ["#group:b1", "b1"]),
    restore_case("restore_row_that_can_no_longer_open", "A row that cannot open any more (the depth cap stops l1 / l2 / l3, which has no features) is dropped; its ancestors stay.", "deep_capped", ["l1", "l1/l2", "l1/l2/l3"]),
    restore_case("restore_root_is_not_stored", "The root's key is never an open key.", "rover", ["", "mast"]),
    restore_case("restore_limit", "At most `limit` keys (2,000 in the app): the first ones in visible-row order are kept, the rest dropped.", "rover", ["mast", "wheel_l", "wheel_r", "#mates", "#patterns", "chassis"], limit=3),
    # --- the live part
    live_case("live_part_alone_collapsed", "A part opened on its own: Planes always shows (3 default planes + 1 plane feature), Bodies and Curves have items, Surfaces is empty and not listed; folders start collapsed; then the features in build order.", "single_part", LIVE_ALONE),
    live_case("live_part_alone_folders_open", "The folders open: bodies, then the three default planes and the plane feature, then curves; the plane feature also stays in the build order, under its own key.", "single_part", LIVE_ALONE, ["#bodies", "#planes", "#curves"]),
    live_case("live_part_alone_empty_folders", "Nothing to put in Bodies, Surfaces or Curves: only Planes is listed.", "single_part", LIVE_EMPTY, ["#planes"]),
    live_case("live_part_every_feature_state", "Every feature state, and several states on one feature: the most severe state wins (lost > moved > pending > rolled back > hidden), `hidden` stays true on the row.", "single_part", LIVE_STATES),
    live_case("live_part_plane_feature_named_xy", "A plane feature whose id is `xy` (only a hand-written file can have one): the default plane keeps `#plane:xy`; every plane feature in the Planes folder is `#plane:feature:<id>` (here `#plane:feature:xy`), its build-order row `#feature:xy`.", "single_part", LIVE_XY, ["#planes"]),
    live_case("live_part_three_levels_down_collapsed", "The live row is not open: nothing under it is listed, exactly as for any row.", "rover", LIVE_HEAD),
    live_case("live_part_three_levels_down", "The live part is mast / arm / head, open: its child occurrences first (lens, the missing cable), then its folders, then its features at the same depth; a Part in the same tree stays read-only (the lens's features are section 7's, `type` null).", "rover", LIVE_HEAD, ["mast", "mast/arm", "mast/arm/head", "mast/arm/head/lens"], features=FEATURES_LENS),
    live_case("live_part_three_levels_down_folders_open", "...with Bodies, Planes and Surfaces open.", "rover", LIVE_HEAD, ["mast", "mast/arm", "mast/arm/head", "mast/arm/head#bodies", "mast/arm/head#planes", "mast/arm/head#surfaces"]),
    live_case("live_part_leaf_four_deep", "A live part with no child occurrences, four levels down: the folders and features at depth 5.", "rover", LIVE_LENS, ["mast", "mast/arm", "mast/arm/head", "mast/arm/head/lens"]),
    live_case("live_part_at_root_of_assembly", "The root is live and an assembly: its occurrences, then its Mates and Patterns folders, then the live folders and features.", "rover", {**LIVE_ALONE, "features": LIVE_ALONE["features"][:2]}, ["chassis"]),
    live_case("live_part_key_names_no_row", "The live key names no row of this tree: the inputs are ignored (a `type` null on every row).", "rover", {**LIVE_ALONE, "key": "gone/part"}, ["wheel_l"]),
    live_case("live_part_on_missing_row", "A missing row cannot be live and cannot open: nothing is added.", "rover", {**LIVE_ALONE, "key": "batt"}, ["batt"]),
    # --- the live part and the filter
    filter_case("live_filter_lost_reference_in_collapsed_live_part", "`:errors` also matches a lost reference: the collapsed live part is listed open as an ancestor, with the one feature under it (the folders hold no match); the broken mast and missing files match as before.", "rover", ":errors", live=LIVE_HEAD),
    filter_case("live_filter_warnings_moved_reference", "`:warnings` also matches a moved reference.", "rover", ":warnings", live=LIVE_HEAD),
    filter_case("live_filter_match_inside_bodies", "A match inside Bodies lists the folder (open) and the body, and the live part above it.", "rover", "head body", live=LIVE_HEAD),
    filter_case("live_filter_default_plane", "A default plane can match by label; a folder never does.", "single_part", "xz", live=LIVE_ALONE),
    filter_case("live_filter_plane_feature_twice", "A plane feature is two rows (build order and the Planes folder): both match, each listed under its parent.", "single_part", "plane 1", live=LIVE_ALONE),
    filter_case("live_filter_folder_label_never_matches", "The word `bodies` is a folder's label: folders never match, so the rows are the root alone.", "single_part", "bodies", live=LIVE_ALONE),
    filter_case("live_filter_sketches", "`:sketches`: feature rows of type sketch.", "single_part", ":sketches", live=LIVE_ALONE),
    filter_case("live_filter_features", "`:features`: every feature row, the plane feature in both places.", "single_part", ":features", live=LIVE_ALONE),
    filter_case("live_filter_hidden", "`:hidden`: hidden features, bodies and default planes (the flag, whatever the state).", "single_part", ":hidden", live=LIVE_ALONE),
    filter_case("live_filter_hidden_beneath_a_worse_state", "A hidden feature whose state is worse still matches `:hidden`, and also `:errors`.", "single_part", ":hidden :errors", live=LIVE_STATES),
    filter_case("live_filter_every_state_errors", "`:errors` finds lost references only (not moved ones).", "single_part", ":errors", live=LIVE_STATES),
    filter_case("live_filter_term_and_token", "A name term and a token on live rows.", "single_part", "sketch :hidden", live=LIVE_ALONE),
    filter_case("live_filter_open_keys_ignored", "The open keys play no part under a filter, for live rows too.", "single_part", "curve", ["#planes", "#bodies"], live=LIVE_ALONE),
    filter_case("live_filter_empty_query", "An empty query is the live rows for the open keys, every match false.", "single_part", "", ["#planes"], live=LIVE_ALONE),
    # --- the live part and restore
    restore_case(
        "live_restore_folder_key_and_feature_key",
        "Folder keys of the live part are open keys (kept when the folder shows); feature, body, plane keys never are; the empty Surfaces folder is not a row, so its key is dropped.",
        "rover",
        ["mast/arm/head#feature:h1", "mast/arm/head#planes", "mast/arm/head#bodies", "mast/arm/head#surfaces", "mast/arm/head#body:hb1", "mast/arm/head#plane:xy", "mast/arm/head", "mast/arm/head#curves"],
        live=LIVE_HEAD,
    ),
    restore_case("live_restore_without_the_live_part", "The same folder keys without a live part name no rows: dropped.", "rover", ["mast/arm/head#planes", "mast/arm/head"]),
]


def expected(case: dict) -> object:
    tree = TREES[case["tree"]]
    live = case.get("live")
    if case["kind"] == "reveal":
        return ref.reveal(tree, case["path"], case["grouping"])
    if case["kind"] in ("restore", "live_part_restore"):
        return ref.restore(tree, case["stored"], live, case["limit"])
    if case["kind"] in ("filter", "live_part_filter"):
        return ref.filter_rows(tree, case["query"], set(case["open"]), case["grouping"], set(case["unsaved_part_ids"]), case["features"], live)
    return ref.visible_rows(tree, set(case["open"]), case["grouping"], set(case["unsaved_part_ids"]), case["features"], live)


def native_document(model: dict, root_id: str) -> dict:
    """`model` as a `POST /document/import/native` payload: featureless Parts (so `feature_count` is 0), no mates."""
    parts = []
    for part_id, p in model["parts"].items():
        occurrences = [
            {
                "id": o["id"],
                "external_ref": o.get("external_ref", f"parts/{o['part']}.didsa" if o["part"] else None),
                "resolved_part_id": o["part"],
                "ref_part_id": o.get("ref_part_id", o["part"]),
                "name_override": o.get("name_override"),
                "transform": {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0},
                "suppressed": o.get("suppressed", False),
                "hidden": o.get("hidden", False),
                "fixed": o.get("fixed", False),
                "color": o.get("color"),
            }
            for o in p["occurrences"]
        ]
        parts.append({"id": part_id, "name": p["name"], "features": [], "occurrences": occurrences, "mates": [], "component_patterns": []})
    return {"schema_version": 1, "document": {"id": "rollup", "root_part_id": root_id, "parts": parts}, "sketches": []}


def featureless(model: dict) -> dict:
    return {"parts": {pid: {**p, "feature_count": 0} for pid, p in model["parts"].items()}}


# (name, model, root, caps): models with no mates or patterns, so a native document reproduces them exactly.
BACKEND_MODELS = [
    ("names", NAMES, "root", {}),
    ("refs", REFS, "root", {}),
    ("repeats", REPEATS, "root", {}),
    ("cycle", CYCLE, "top", {}),
    ("deep_capped", DEEP, "d0", {"max_depth": 3}),
    ("wide_capped", WIDE, "w", {"max_nodes": 3}),
]


def build_backend() -> dict:
    return {
        "version": BACKEND_VERSION,
        "about": "Generated by tools/assembly_tree_vectors/generate.py; never edit by hand. Each case: import `document`, GET "
        "/parts/{root}/assembly-tree with `params`, expect `expected` (the reference's tree, no status).",
        "cases": [
            {
                "name": name,
                "root": root,
                "params": caps,
                "document": native_document(model, root),
                "expected": ref.build_tree(featureless(model), root, status=False, **caps),
            }
            for name, model, root, caps in BACKEND_MODELS
        ],
    }


def build() -> dict:
    return {
        "version": VERSION,
        "about": (
            "Assembly tree golden vectors. The rules: DIDSA-CAD docs/assembly-tree/spec.md. Generated by DIDSA-CAD "
            "tools/assembly_tree_vectors/generate.py from its reference implementation; never edit by hand. `trees` are "
            "GET /parts/{id}/assembly-tree responses (ids are made up); `cases` are rows or reveal cases over them."
        ),
        "states": ref.STATES,
        "trees": TREES,
        "cases": [{**case, "expected": expected(case)} for case in CASES],
    }


def dumps(doc: dict) -> str:
    return json.dumps(doc, indent=1, sort_keys=True, ensure_ascii=False) + "\n"


def outputs() -> dict[Path, str]:
    return {OUT: dumps(build()), BACKEND_OUT: dumps(build_backend())}


def main() -> int:
    files = outputs()
    if "--check" in sys.argv:
        stale = [str(p.relative_to(REPO)) for p, text in files.items() if not p.exists() or p.read_text() != text]
        if stale:
            print(f"stale: {', '.join(stale)}: run python tools/assembly_tree_vectors/generate.py")
            return 1
        print(f"up to date ({len(CASES)} cases; {len(BACKEND_MODELS)} backend roll-up cases)")
        return 0
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    print(f"wrote {len(CASES)} cases to {OUT.relative_to(REPO)} and {len(BACKEND_MODELS)} to {BACKEND_OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
