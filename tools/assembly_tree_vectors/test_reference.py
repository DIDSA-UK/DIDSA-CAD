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


def cases_of(*kinds):
    return [c for c in VECTORS["cases"] if c["kind"] in kinds]


def rows_of(case_):
    expected = case_["expected"]
    return expected["rows"] if isinstance(expected, dict) else expected


def keys_of(name):
    return [r["key"] for r in rows_of(case(name))]


class VersionTwo(unittest.TestCase):
    """Spec sections 11 to 13 (B1). Hand-written from the spec, like the rest."""

    def test_version_and_the_36_version_1_cases_come_first(self):
        self.assertEqual(VECTORS["version"], 2)
        first = VECTORS["cases"][:36]
        self.assertTrue(all(c["kind"] in ("rows", "reveal") for c in first))
        self.assertEqual(sum(c["kind"] == "reveal" for c in first), 6)
        self.assertEqual(first[0]["name"], "rover_collapsed")
        self.assertEqual(first[-1]["name"], "reveal_inside_group_member")
        self.assertFalse(any(c["kind"] in ("rows", "reveal") for c in VECTORS["cases"][36:]))
        self.assertEqual({c["kind"] for c in VECTORS["cases"]}, {"rows", "reveal", "filter", "restore", "live_part", "live_part_filter", "live_part_restore"})

    def test_the_backend_file_is_untouched_by_version_2(self):
        self.assertEqual(json.loads(generate.BACKEND_OUT.read_text())["version"], 1)

    # --- section 11
    def test_parse_query(self):
        self.assertEqual(ref.parse_query("  Bolt   :ERRORS <2> :foo :Foo :hidden"), (["bolt", "<2>"], [":errors", ":hidden"], [":foo"]))
        self.assertEqual(ref.parse_query(""), ([], [], []))
        self.assertEqual(ref.parse_query(":"), ([], [], [":"]))

    def test_tokens_one_by_one(self):
        def row(**f):
            return {"state": "none", "hidden": False, "suppressed": False, "kind": "part", **f}

        t = ref.TOKENS
        self.assertTrue(t[":missing"](row(state="missing"), False) and not t[":missing"](row(state="cycle"), False))
        for state in ("missing", "cycle", "broken", "over_constrained", "lost_reference"):
            self.assertTrue(t[":errors"](row(state=state), False), state)
        for state in ("near", "unsaved", "moved_reference", "under_constrained", "none"):
            self.assertFalse(t[":errors"](row(state=state), False), state)
        self.assertTrue(t[":warnings"](row(state="near"), False) and t[":warnings"](row(state="moved_reference"), False))
        self.assertFalse(t[":warnings"](row(state="broken"), False))
        self.assertTrue(t[":unsaved"](row(state="unsaved"), False) and not t[":unsaved"](row(state="broken"), False))
        self.assertTrue(t[":fixed"](row(state="fully_constrained"), True) and not t[":fixed"](row(state="fixed"), False))
        self.assertTrue(t[":hidden"](row(hidden=True, state="lost_reference"), False))
        self.assertTrue(t[":suppressed"](row(suppressed=True), False))
        self.assertTrue(t[":parts"](row(kind="part"), False) and not t[":parts"](row(kind="missing"), False))
        self.assertTrue(t[":assemblies"](row(kind="assembly"), False) and not t[":assemblies"](row(kind="group"), False))
        self.assertTrue(t[":features"](row(kind="feature"), False) and not t[":features"](row(kind="part"), False))
        self.assertTrue(t[":sketches"](row(kind="feature", type="sketch"), False) and not t[":sketches"](row(kind="feature"), False))
        self.assertNotIn(":mates", t)  # waits for Phase C

    def test_deep_match_lists_ancestors_open_and_nothing_else(self):
        rows = rows_of(case("filter_deep_collapsed"))
        self.assertEqual([r["key"] for r in rows], ["", "mast", "mast/arm", "mast/arm/head", "mast/arm/head/lens"])
        self.assertEqual([r["match"] for r in rows], [False, False, False, False, True])
        self.assertEqual([r["open"] for r in rows], [True, True, True, True, False])
        self.assertTrue(rows[-1]["expandable"])  # a match with nothing below it listed: open false, expandable as usual
        self.assertEqual(keys_of("filter_ignores_open_keys"), keys_of("filter_deep_collapsed"))

    def test_a_match_in_a_group_lists_the_group_and_only_the_matching_members(self):
        rows = rows_of(case("filter_in_group"))
        self.assertEqual([r["key"] for r in rows], ["", "wheel_l", "wheel_l/#group:b1", "wheel_l/b3", "wheel_r", "wheel_r/#group:b1", "wheel_r/b3"])
        group = rows[2]
        self.assertEqual((group["kind"], group["open"], group["match"], group["bubble"], group["count"]), ("group", True, False, None, 4))
        self.assertEqual([r["depth"] for r in rows], [0, 1, 2, 3, 1, 2, 3])
        self.assertNotIn("#group", " ".join(keys_of("filter_grouping_off")))

    def test_two_terms_and_instance_numbers(self):
        self.assertEqual([r["label"] for r in rows_of(case("filter_two_terms")) if r["match"]], ["Screw M3 <2>"])
        labels = [r["label"] for r in rows_of(case("filter_instance_number")) if r["match"]]
        self.assertEqual(labels, ["Bolt M4 <2>", "Wheel <2>", "Bolt M4 <2>", "Screw M3 <2>"])

    def test_group_and_root_labels_never_match(self):
        self.assertEqual(keys_of("filter_group_and_own_label"), [""])

    def test_only_unknown_tokens_match_nothing_and_are_listed(self):
        c = case("filter_only_unknown_token")
        self.assertEqual((c["expected"]["unknown"], [r["key"] for r in c["expected"]["rows"]]), ([":foo"], [""]))
        self.assertEqual(case("filter_unknown_token")["expected"]["unknown"], [":foo", ":bar"])
        self.assertEqual([r["key"] for r in rows_of(case("filter_unknown_token")) if r["match"]], ["mast/arm/head/lens"])

    def test_an_empty_query_is_section_7(self):
        for name, open_keys in (("filter_empty_query", {"wheel_l"}), ("filter_spaces_only", {"mast"})):
            rows = rows_of(case(name))
            self.assertTrue(all(r["match"] is False for r in rows))
            self.assertEqual([{k: v for k, v in r.items() if k != "match"} for r in rows], ref.visible_rows(VECTORS["trees"]["rover"], open_keys))

    def test_without_status_errors_finds_only_what_section_5_lists(self):
        with_status = [r["key"] for r in rows_of(case("filter_errors")) if r["match"]]
        without = [r["key"] for r in rows_of(case("filter_errors_no_status")) if r["match"]]
        self.assertEqual(without, ["mast/arm/head/cable", "batt"])
        self.assertEqual(with_status, ["mast", "mast/arm/head/cable", "batt"])

    def test_features_match_only_where_fetched(self):
        rows = rows_of(case("filter_fetched_and_unfetched_features"))
        self.assertEqual([r["key"] for r in rows if r["match"]], ["chassis#feature:g1", "mast/arm/head/lens#feature:f1"])

    def test_folders_and_the_mates_folder_are_not_listed_under_a_filter(self):
        for c in cases_of("filter", "live_part_filter"):
            if c["query"].strip():
                self.assertFalse({"mates_folder", "patterns_folder"} & {r["kind"] for r in rows_of(c)}, c["name"])

    def test_listed_rows_are_open_when_something_below_is_listed(self):
        for c in cases_of("filter", "live_part_filter"):
            rows = rows_of(c)
            if not c["query"].strip():
                continue
            for i, r in enumerate(rows):
                below = i + 1 < len(rows) and rows[i + 1]["depth"] > r["depth"]
                self.assertEqual(r["open"], below if r["key"] != "" else True, f"{c['name']} {r['key']}")
            self.assertTrue(all(r["match"] for r in rows if not r["open"] and r["key"] != ""), c["name"])

    # --- section 12
    def test_restore(self):
        kept = case("restore_keeps_what_still_exists")["expected"]
        self.assertEqual(kept, ["chassis", "wheel_l", "wheel_l/#group:b1", "mast", "#group:s1", "#mates", "#patterns"])
        self.assertEqual(case("restore_group_key_with_grouping_off")["expected"], ["wheel_l", "wheel_l/#group:b1", "#group:s1"])
        self.assertEqual(case("restore_group_that_no_longer_forms")["expected"], ["b1"])
        self.assertEqual(case("restore_row_that_can_no_longer_open")["expected"], ["l1", "l1/l2"])
        self.assertEqual(case("restore_root_is_not_stored")["expected"], ["mast"])
        self.assertEqual(case("restore_limit")["expected"], ["chassis", "wheel_l", "wheel_r"])

    def test_restore_does_not_depend_on_grouping(self):
        for c in cases_of("restore"):
            tree = VECTORS["trees"][c["tree"]]
            self.assertEqual(ref.restore(tree, c["stored"], None, c["limit"]), c["expected"], c["name"])

    # --- section 13
    def test_feature_state_most_severe_wins(self):
        self.assertEqual(ref.FEATURE_STATES, ["lost_reference", "moved_reference", "pending_detail", "rolled_back", "hidden", "none"])
        f = {"lost_reference": "gone", "moved_reference": True, "pending_detail": True, "rolled_back": True, "hidden": True}
        order = []
        while f:
            order.append(ref.feature_state(f))
            f.pop(next(iter(f)))
        self.assertEqual(order, ["lost_reference", "moved_reference", "pending_detail", "rolled_back", "hidden"])
        self.assertEqual(ref.feature_state({}), "none")
        self.assertEqual(ref.feature_state({"lost_reference": None, "moved_reference": False}), "none")
        self.assertEqual(ref.feature_state({"lost_reference": ""}), "lost_reference")  # a reason, even an empty one, is a lost reference

    def test_every_feature_state_is_in_the_vectors(self):
        seen = {r["state"] for c in cases_of("live_part") for r in c["expected"] if r["kind"] == "feature"}
        self.assertEqual(seen, set(ref.FEATURE_STATES))
        rows = {r["key"]: r for r in case("live_part_every_feature_state")["expected"]}
        self.assertEqual(rows["#feature:s_lost_moved_hidden"]["state"], "lost_reference")
        self.assertTrue(rows["#feature:s_lost_moved_hidden"]["hidden"])
        self.assertEqual(rows["#feature:s_moved_pending"]["state"], "moved_reference")
        self.assertEqual(rows["#feature:s_pending_rolled"]["state"], "pending_detail")
        self.assertEqual(rows["#feature:s_rolled_hidden"]["state"], "rolled_back")

    def test_a_part_opened_alone(self):
        rows = case("live_part_alone_collapsed")["expected"]
        self.assertEqual(
            [(r["key"], r["kind"], r["depth"], r["count"]) for r in rows][:4],
            [("", "root", 0, None), ("#bodies", "bodies_folder", 1, 2), ("#planes", "planes_folder", 1, 4), ("#curves", "curves_folder", 1, 1)],
        )
        self.assertNotIn("#surfaces", [r["key"] for r in rows])  # empty: not listed
        self.assertTrue(all(r["open"] is False for r in rows if r["kind"].endswith("_folder")))
        self.assertEqual([r["key"] for r in rows][4:], ["#feature:f1", "#feature:f2", "#feature:f3", "#feature:f4", "#feature:f5"])
        self.assertEqual([r["key"] for r in case("live_part_alone_empty_folders")["expected"]][:2], ["", "#planes"])  # Planes always

    def test_folder_contents_and_keys(self):
        keys = [r["key"] for r in case("live_part_alone_folders_open")["expected"]]
        self.assertEqual(
            keys[:12],
            ["", "#bodies", "#body:b1", "#body:b2", "#planes", "#plane:xy", "#plane:xz", "#plane:yz", "#plane:f3", "#curves", "#curve:c1", "#feature:f1"],
        )
        rows = {r["key"]: r for r in case("live_part_alone_folders_open")["expected"]}
        self.assertEqual((rows["#plane:xz"]["kind"], rows["#plane:xz"]["state"], rows["#plane:xz"]["hidden"]), ("default_plane", "hidden", True))
        self.assertEqual((rows["#plane:f3"]["kind"], rows["#plane:f3"]["type"], rows["#feature:f3"]["type"]), ("feature", "create_plane", "create_plane"))
        self.assertEqual(rows["#body:b2"]["state"], "hidden")
        self.assertEqual({r["type"] for r in rows.values() if r["kind"] != "feature"}, {None})

    def test_a_plane_feature_can_never_take_a_default_planes_key(self):
        self.assertEqual(ref.plane_feature_key("", "f3"), "#plane:f3")
        for plane in ("xy", "xz", "yz"):
            self.assertEqual(ref.plane_feature_key("a/b", plane), f"a/b#plane:feature:{plane}")
        keys = [r["key"] for r in case("live_part_plane_feature_named_xy")["expected"]]
        self.assertEqual(len(keys), len(set(keys)))

    def test_the_live_part_in_an_assembly(self):
        rows = case("live_part_three_levels_down")["expected"]
        keys = [r["key"] for r in rows]
        head = keys.index("mast/arm/head")
        self.assertEqual(
            keys[head : head + 11],
            ["mast/arm/head", "mast/arm/head/lens", "mast/arm/head/lens#feature:f1", "mast/arm/head/lens#feature:f2", "mast/arm/head/lens#feature:f3", "mast/arm/head/cable", "mast/arm/head#bodies", "mast/arm/head#planes", "mast/arm/head#surfaces", "mast/arm/head#feature:h1", "mast/arm/head#feature:h2"],
        )
        self.assertEqual(rows[head + 9]["depth"], rows[head]["depth"] + 1)  # features at the same depth as the children and folders
        self.assertTrue(all(r["type"] is None for r in rows if "lens#feature" in r["key"]))  # read-only names: no type
        self.assertEqual(rows[-2]["key"], "#mates")  # the root's folders come before the root's own live block, which is not here
        root = case("live_part_at_root_of_assembly")["expected"]
        order = [r["key"] for r in root]
        self.assertLess(order.index("#patterns"), order.index("#planes"))
        self.assertLess(order.index("#planes"), order.index("#feature:f1"))

    def test_a_missing_or_unknown_live_key_adds_nothing(self):
        for name in ("live_part_key_names_no_row", "live_part_on_missing_row"):
            rows = case(name)["expected"]
            self.assertFalse(any(r["kind"].endswith("_folder") and r["kind"] not in ("mates_folder", "patterns_folder") for r in rows), name)

    def test_live_filter(self):
        errors = [r["key"] for r in rows_of(case("live_filter_lost_reference_in_collapsed_live_part")) if r["match"]]
        self.assertEqual(errors, ["mast", "mast/arm/head/cable", "mast/arm/head#feature:h2", "batt"])
        self.assertEqual([r["key"] for r in rows_of(case("live_filter_warnings_moved_reference")) if r["match"]], ["mast/arm/head#feature:h3", "cam"])
        bodies = rows_of(case("live_filter_match_inside_bodies"))
        self.assertEqual([r["key"] for r in bodies][-2:], ["mast/arm/head#bodies", "mast/arm/head#body:hb1"])
        self.assertEqual([(r["match"], r["open"]) for r in bodies][-2:], [(False, True), (True, False)])
        self.assertEqual([r["key"] for r in rows_of(case("live_filter_plane_feature_twice")) if r["match"]], ["#plane:f3", "#feature:f3"])
        self.assertEqual(keys_of("live_filter_folder_label_never_matches"), [""])
        self.assertEqual([r["key"] for r in rows_of(case("live_filter_sketches")) if r["match"]], ["#feature:f1", "#feature:f4"])
        hidden = [r["key"] for r in rows_of(case("live_filter_hidden")) if r["match"]]
        self.assertEqual(hidden, ["#body:b2", "#plane:xz", "#feature:f4"])
        both = [r["key"] for r in rows_of(case("live_filter_hidden_beneath_a_worse_state")) if r["match"]]
        self.assertEqual(both, ["#feature:s_lost_moved_hidden"])
        self.assertEqual([r["key"] for r in rows_of(case("live_filter_every_state_errors")) if r["match"]], ["#feature:s_lost", "#feature:s_lost_moved_hidden"])

    def test_live_restore(self):
        self.assertEqual(case("live_restore_folder_key_and_feature_key")["expected"], ["mast/arm/head", "mast/arm/head#bodies", "mast/arm/head#planes", "mast/arm/head#surfaces"])
        self.assertEqual(case("live_restore_without_the_live_part")["expected"], ["mast/arm/head"])

    def test_every_row_kind_and_token_is_in_the_vectors(self):
        kinds = {r["kind"] for c in VECTORS["cases"] if c["kind"] in ("live_part", "live_part_filter") for r in rows_of(c)}
        self.assertEqual(kinds, {"root", "assembly", "part", "missing", "group", "feature", "mates_folder", "patterns_folder", "bodies_folder", "planes_folder", "surfaces_folder", "curves_folder", "body", "surface", "curve", "default_plane"})
        tokens = {w for c in cases_of("filter", "live_part_filter") for w in c["query"].lower().split() if w.startswith(":")}
        self.assertTrue(set(ref.TOKENS) <= tokens, set(ref.TOKENS) - tokens)

    def test_live_rows_carry_type_and_filter_rows_carry_match(self):
        for c in VECTORS["cases"]:
            rows = rows_of(c) if c["kind"] != "restore" and c["kind"] != "live_part_restore" and c["kind"] != "reveal" else []
            for r in rows:
                self.assertEqual("type" in r, "live" in c, c["name"])
                self.assertEqual("match" in r, c["kind"] in ("filter", "live_part_filter"), c["name"])


if __name__ == "__main__":
    unittest.main()
