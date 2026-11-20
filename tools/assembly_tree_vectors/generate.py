#!/usr/bin/env python3
"""Golden vectors for the assembly tree (DIDSA-CAD `docs/assembly-tree/spec.md`).

    python tools/assembly_tree_vectors/generate.py            # (re)writes docs/assembly-tree/vectors.json
    python tools/assembly_tree_vectors/generate.py --check    # exits 1 if the committed file differs

Never edit vectors.json by hand: change the models or cases here (or the rules in reference.py) and regenerate.
`test_reference.py` fails when the committed file is not what this script writes.

The file is self-contained, so DIDSA-VR copies it as-is (`tests/fixtures/assembly_tree_vectors.json`):
- `trees`: named `GET /parts/{id}/assembly-tree` responses (every field of the spec's Response), built by
  `reference.build_tree` from the small models below. Ids are made up and only mean something inside the file.
- `cases`: `kind: "rows"` gives the inputs of the spec's "Visible rows" (`tree`, `open` keys, `grouping`,
  `unsaved_part_ids`, `features` per row key) and `expected` (the rows, top to bottom, every field);
  `kind: "reveal"` gives a `path` and `grouping` and `expected` (the keys to open, in order).
  `why` says what the case pins. Deterministic: no randomness, keys sorted.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import reference as ref  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "docs" / "assembly-tree" / "vectors.json"
VERSION = 1


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

TREES = {
    "rover": ref.build_tree(ROVER, "rover", status=True),
    "rover_no_status": ref.build_tree(ROVER, "rover", status=False),
    "names": ref.build_tree(NAMES, "root", status=True),
    "states": ref.build_tree(STATES, "root", status=True),
    "states_no_status": ref.build_tree(STATES, "root", status=False),
    "cycle": ref.build_tree(CYCLE, "top", status=False),
    "deep_capped": ref.build_tree(DEEP, "d0", status=False, max_depth=3),
    "wide_capped": ref.build_tree(WIDE, "w", status=False, max_nodes=3),
    "unsaved": ref.build_tree(UNSAVED, "root", status=True),
    "suppressed": ref.build_tree(SUPPRESSED, "top", status=True),
    "single_part": ref.build_tree(SINGLE, "solo", status=True),
    "repeats": ref.build_tree(REPEATS, "root", status=True),
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


def expected(case: dict) -> object:
    tree = TREES[case["tree"]]
    if case["kind"] == "reveal":
        return ref.reveal(tree, case["path"], case["grouping"])
    return ref.visible_rows(tree, set(case["open"]), case["grouping"], set(case["unsaved_part_ids"]), case["features"])


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


def main() -> int:
    text = dumps(build())
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != text:
            print(f"{OUT.relative_to(REPO)} is stale: run python tools/assembly_tree_vectors/generate.py")
            return 1
        print(f"{OUT.relative_to(REPO)} is up to date ({len(CASES)} cases)")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print(f"wrote {len(CASES)} cases to {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
