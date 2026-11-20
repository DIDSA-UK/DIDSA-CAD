"""Tests of the assembly tree's reference implementation and its vectors (DIDSA-CAD `docs/assembly-tree/spec.md`).

    python -m unittest discover -s tools/assembly_tree_vectors -v      (standard library only; CI: .github/workflows/assembly-tree-vectors.yml)

The spot checks are written by hand from the spec, not read back from the generator, so a change to a rule in
reference.py that the spec does not say fails here. `test_checked_in_vectors_are_what_the_generator_writes` keeps
docs/assembly-tree/vectors.json generated: an edit by hand, or a rule change without regenerating, fails it."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate  # noqa: E402
import reference as ref  # noqa: E402

VECTORS = json.loads(generate.OUT.read_text())


def node(id_, part_id="p", **fields):
    out = {
        "occurrence_id": id_,
        "path": [id_],
        "external_ref": f"parts/{part_id}.didsa" if part_id else None,
        "resolved_part_id": part_id,
        "part_name": "Bolt" if part_id else None,
        "name_override": None,
        "kind": "part" if part_id else "missing",
        "fixed": False,
        "hidden": False,
        "suppressed": False,
        "constraint": None,
        "feature_count": 1,
        "cycle": False,
        "problems": None,
        "children": [],
    }
    out.update(fields)
    return out


def constraint(status, broken=0, near=0):
    return {"status": status, "dof": 0, "rigid_set": None, "broken_mates": broken, "near_mates": near}


def case(name):
    return next(c for c in VECTORS["cases"] if c["name"] == name)


class CheckedIn(unittest.TestCase):
    def test_checked_in_vectors_are_what_the_generator_writes(self):
        for path, text in generate.outputs().items():
            self.assertEqual(path.read_text(), text, f"{path} is stale or was edited by hand: run python tools/assembly_tree_vectors/generate.py")

    def test_vectors_are_self_contained(self):
        """DIDSA-VR copies the file as-is: no machine paths, every case's tree is in the file."""
        text = generate.OUT.read_text()
        for needle in ("/home/", "/tmp/", "C:\\", "backend/"):
            self.assertNotIn(needle, text)
        for c in VECTORS["cases"]:
            self.assertIn(c["tree"], VECTORS["trees"], c["name"])


class DisplayNames(unittest.TestCase):
    def test_order_override_part_file_ordinal(self):
        self.assertEqual(ref.base_name(node("a", name_override="Left"), 0), ("Left", "override"))
        self.assertEqual(ref.base_name(node("a", name_override="  "), 0), ("Bolt", "part"))
        self.assertEqual(ref.base_name(node("a", part_name="part-0123456789abcdef"), 0), ("p", "file"))
        uuid_ref = "parts/0f8e2a1c-9b7d-4e3f-8a6b-5c4d3e2f1a0b.didsa"
        self.assertEqual(ref.base_name(node("a", part_name="", external_ref=uuid_ref), 4), ("Component 5", "ordinal"))

    def test_generated_names(self):
        for name in ("", "  ", "3f2a9c1d-7e6b-4a5c-9d8e-1f2a3b4c5d6e", "3f2a9c1d7e6b4a5c9d8e1f2a3b4c5d6e", "part-0123456789abcdef", "occ_0123456789ABCDEF00"):
            self.assertTrue(ref.looks_generated(name), name)
        for name in ("Bolt", "bolt-2", "deadbeef", "Gear (40 teeth)", "toolong-0123456789abcdef"):
            self.assertFalse(ref.looks_generated(name), name)

    def test_file_names(self):
        self.assertEqual(ref.file_base_name("parts/bolt.didsa"), "bolt")
        self.assertEqual(ref.file_base_name("lib/v1.2/clip.step.didsa"), "clip.step")
        self.assertEqual(ref.file_base_name("parts/.washer"), ".washer")
        self.assertIsNone(ref.file_base_name(None))

    def test_one_part_through_different_files_takes_the_first_name(self):
        rows = {r["key"]: r["label"] for r in case("names_one_part_through_different_files")["expected"]}
        self.assertEqual([rows[k] for k in ("r1", "r2", "r3", "r4", "r5")], ["left_arm <1>", "left_arm <2>", "left_arm <3>", "left_arm <4>", "Spare"])
        grouped = {r["key"]: r["label"] for r in case("names_one_part_through_different_files_grouped")["expected"]}
        self.assertEqual(grouped["#group:r1"], "left_arm x4")

    def test_instance_numbers(self):
        """Owner, 11 and 20 Nov: `Bolt <2>`. Numbered per Part among unnamed siblings; a renamed placement is not counted."""
        names = ref.sibling_names([node("a"), node("b", name_override="Lid"), node("c"), node("d", "q", part_name="Nut")])
        self.assertEqual([n["name"] for n in names], ["Bolt <1>", "Lid", "Bolt <2>", "Nut"])
        self.assertEqual([n["name"] for n in ref.sibling_names([node("a")])], ["Bolt"])


class Grouping(unittest.TestCase):
    def test_more_than_three_group(self):
        four = [node(x) for x in "abcd"]
        three = [node(x) for x in "abc"]
        self.assertEqual(len(ref.sibling_items(four, True)), 1)
        self.assertEqual(len(ref.sibling_items(three, True)), 3)
        self.assertEqual(len(ref.sibling_items(four, False)), 4)

    def test_vectors_cover_grouping_on_and_off_with_four_identical_siblings(self):
        rows = [c for c in VECTORS["cases"] if c["kind"] == "rows"]
        self.assertTrue(any(c["grouping"] for c in rows) and any(not c["grouping"] for c in rows))
        self.assertTrue(any(r["kind"] == "group" and r["count"] > 3 for c in rows for r in c["expected"]))
        off = case("rover_grouping_off")["expected"]
        self.assertFalse(any(r["kind"] == "group" for r in off))
        self.assertIn("Bolt M4 <4>", [r["label"] for r in off])

    def test_group_row(self):
        rows = case("rover_wheel_group_open")["expected"]
        group = next(r for r in rows if r["kind"] == "group")
        self.assertEqual((group["label"], group["key"], group["count"]), ("Bolt M4 x4", "wheel_l/#group:b1", 4))
        members = rows[rows.index(group) + 1 : rows.index(group) + 5]
        self.assertEqual([m["label"] for m in members], ["Bolt M4 <1>", "Bolt M4 <2>", "Bolt M4 <3>", "Bolt M4 <4>"])
        self.assertTrue(all(m["depth"] == group["depth"] + 1 for m in members))


class StateSlot(unittest.TestCase):
    def test_severity_order(self):
        """Scope 9.2: missing > broken > over-constrained > unsaved > under-constrained > fixed (cycle, near and
        fully_constrained placed by this spec)."""
        self.assertEqual(ref.STATES, ["missing", "cycle", "broken", "over_constrained", "near", "unsaved", "under_constrained", "fixed", "fully_constrained", "none"])
        none = frozenset()
        unsaved = frozenset({"p"})
        self.assertEqual(ref.state_slot(node("a", None, fixed=True), unsaved), "missing")
        self.assertEqual(ref.state_slot(node("a", constraint=constraint("fully_constrained", broken=1)), unsaved), "broken")
        self.assertEqual(ref.state_slot(node("a", constraint=constraint("over_constrained")), unsaved), "over_constrained")
        self.assertEqual(ref.state_slot(node("a", constraint=constraint("over_constrained", near=1)), none), "near")
        self.assertEqual(ref.state_slot(node("a", constraint=constraint("under_constrained")), unsaved), "unsaved")
        self.assertEqual(ref.state_slot(node("a", constraint=constraint("under_constrained")), none), "under_constrained")
        self.assertEqual(ref.state_slot(node("a", fixed=True), none), "fixed")
        self.assertEqual(ref.state_slot(node("a", constraint=constraint("fully_constrained")), none), "fully_constrained")
        self.assertEqual(ref.state_slot(node("a"), none), "none")

    def test_every_state_is_in_the_vectors(self):
        seen = {r["state"] for c in VECTORS["cases"] if c["kind"] == "rows" for r in c["expected"]}
        self.assertEqual(seen, set(ref.STATES))


class Bubbles(unittest.TestCase):
    def test_collapsed_rows_count_below_open_rows_count_their_own_mates(self):
        collapsed = {r["key"]: r for r in case("rover_collapsed")["expected"]}
        self.assertEqual(collapsed["mast"]["bubble"], {"level": "error", "count": 1})  # the missing cable, three levels down
        opened = {r["key"]: r for r in case("rover_four_deep_with_features")["expected"]}
        self.assertIsNone(opened["mast"]["bubble"])
        self.assertEqual(collapsed["#mates"]["bubble"], {"level": "error", "count": 1})

    def test_error_beats_warning_beats_unsaved(self):
        self.assertEqual(ref.bubble({"error": 1, "warning": 3, "unsaved": 2}), {"level": "error", "count": 1})
        self.assertEqual(ref.bubble({"error": 0, "warning": 3, "unsaved": 2}), {"level": "warning", "count": 3})
        self.assertEqual(ref.bubble({"error": 0, "warning": 0, "unsaved": 2}), {"level": "unsaved", "count": 2})
        self.assertIsNone(ref.bubble({"error": 0, "warning": 0, "unsaved": 0}))

    def test_suppressed_subtrees_add_nothing_above(self):
        tree = VECTORS["trees"]["suppressed"]
        self.assertEqual(tree["problems"]["missing"], 0)
        self.assertEqual(tree["children"][0]["problems"]["missing"], 1)


class KeysAndRows(unittest.TestCase):
    def test_two_placements_have_distinct_keys(self):
        keys = [r["key"] for r in case("rover_both_wheels_open")["expected"]]
        self.assertIn("wheel_l/hub", keys)
        self.assertIn("wheel_r/hub", keys)
        self.assertEqual(len(keys), len(set(keys)))

    def test_every_case_has_unique_keys_and_every_row_kind_appears(self):
        kinds = set()
        for c in VECTORS["cases"]:
            if c["kind"] != "rows":
                continue
            keys = [r["key"] for r in c["expected"]]
            self.assertEqual(len(keys), len(set(keys)), c["name"])
            self.assertEqual(c["expected"][0]["kind"], "root")
            kinds |= {r["kind"] for r in c["expected"]}
        self.assertEqual(kinds, {"root", "assembly", "part", "missing", "group", "feature", "mates_folder", "patterns_folder"})

    def test_key_formats(self):
        self.assertEqual(ref.occurrence_key(["a", "b"]), "a/b")
        self.assertEqual(ref.group_key("", "s1"), "#group:s1")
        self.assertEqual(ref.group_key("a/b", "s1"), "a/b/#group:s1")
        self.assertEqual(ref.feature_key("a/b", "f1"), "a/b#feature:f1")
        self.assertEqual(ref.feature_key("", "f1"), "#feature:f1")
        self.assertEqual(ref.folder_key("", "mates"), "#mates")

    def test_reveal_lists_the_row(self):
        for c in (c for c in VECTORS["cases"] if c["kind"] == "reveal"):
            tree = VECTORS["trees"][c["tree"]]
            rows = ref.visible_rows(tree, set(c["expected"]), c["grouping"])
            self.assertIn("/".join(c["path"]), [r["key"] for r in rows], c["name"])
        self.assertEqual(case("reveal_four_deep")["expected"], ["mast", "mast/arm", "mast/arm/head"])


class BuildTree(unittest.TestCase):
    def test_root_problems_add_up(self):
        tree = VECTORS["trees"]["rover"]
        # near: the root's 2, and the wheel's 1 once per placement (two wheels)
        self.assertEqual(tree["problems"], {"missing": 2, "cycles": 0, "broken": 1, "over_constrained": 0, "near": 4})
        self.assertEqual(VECTORS["trees"]["rover_no_status"]["problems"], {"missing": 2, "cycles": 0, "broken": None, "over_constrained": None, "near": None})

    def test_caps_and_cycles(self):
        self.assertTrue(VECTORS["trees"]["deep_capped"]["truncated_depth"])
        self.assertTrue(VECTORS["trees"]["wide_capped"]["truncated_nodes"])
        self.assertEqual(VECTORS["trees"]["wide_capped"]["node_count"], 3)
        self.assertEqual(VECTORS["trees"]["cycle"]["problems"]["cycles"], 2)

    def test_placements_count_the_whole_tree(self):
        wheel = VECTORS["trees"]["rover"]["children"][1]
        self.assertEqual(wheel["placements"], 2)
        self.assertEqual(wheel["children"][2]["placements"], 8)  # four bolts in each of two wheels


if __name__ == "__main__":
    unittest.main()
