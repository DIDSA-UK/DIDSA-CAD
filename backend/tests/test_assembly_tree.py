"""Assembly tree overhaul A1 (`docs/assembly-tree/spec.md`): `GET /parts/{part_id}/assembly-tree`, the whole hierarchy in one
call. Two levels; one sub-assembly placed twice (distinct paths, same child ids); a missing file and the hidden / suppressed /
fixed flags; the problem roll-up; the cycle guard and the caps; and agreement, level by level, with `/occurrences`,
`/constraint-status` and `/mates`.

The structure tests import small featureless documents (no OCCT work). The status tests use the gear-train demo
(`tests/data/gear_train_demo_current.didsa`, DIDSA-VR's demo) placed twice under a new root, and its old version whose bevel
mates read `broken`, so they need the real pythonocc-core environment and take a few seconds (the bodies are built once)."""

import copy
import json

import pytest
from fastapi.testclient import TestClient

from app.document.models import Occurrence
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY
from tests.gear_train_demo_motion_source import DATA, DEMO

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

NODE_FIELDS = {
    "occurrence_id", "path", "external_ref", "ref_part_id", "resolved_part_id", "part_name", "name_override", "kind", "fixed",
    "hidden", "suppressed", "color", "constraint", "feature_count", "placements", "cycle", "truncated", "mates", "patterns",
    "problems", "children",
}  # fmt: skip
RESPONSE_FIELDS = {
    "part_id", "part_name", "kind", "feature_count", "status_included", "truncated", "mates", "patterns", "problems", "children",
    "node_count", "max_depth", "max_nodes", "truncated_depth", "truncated_nodes",
}  # fmt: skip


def _occ(id_, part_id, **fields):
    return {
        "id": id_,
        "external_ref": f"parts/{part_id}.didsa" if part_id else None,
        "resolved_part_id": part_id,
        "name_override": None,
        "transform": {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0},
        "suppressed": False,
        "hidden": False,
        "fixed": False,
        "color": None,
        "ref_part_id": part_id,
        **fields,
    }


def _part(id_, name, occurrences=()):
    return {"id": id_, "name": name, "features": [], "occurrences": list(occurrences), "mates": [], "component_patterns": []}


def _import(root_id, parts):
    payload = {"schema_version": 1, "document": {"id": "tree-test", "root_part_id": root_id, "parts": parts}, "sketches": []}
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200, response.text
    return root_id


def _tree(part_id, **params):
    response = client.get(f"/document/parts/{part_id}/assembly-tree", params=params)
    assert response.status_code == 200, response.text
    return response.json()


def _walk(node):
    for child in node["children"]:
        yield child
        yield from _walk(child)


# Root "Rover" places a chassis (fixed), a wheel sub-assembly twice (wheel_l hidden), a missing battery and a suppressed spare
# wheel; the wheel places a hub and a bolt.
def _rover():
    return _import(
        "rover",
        [
            _part(
                "rover",
                "Rover",
                [
                    _occ("chassis", "chassis", fixed=True),
                    _occ("wheel_l", "wheel", hidden=True),
                    _occ("wheel_r", "wheel", name_override="Right wheel", color="#FF0000"),
                    _occ("batt", "battery_gone", external_ref="parts/battery.didsa", ref_part_id="battery_gone"),
                    _occ("spare", "wheel", suppressed=True),
                ],
            ),
            _part("chassis", "Chassis"),
            _part("wheel", "Wheel", [_occ("hub", "hub"), _occ("bolt", "bolt")]),
            _part("hub", "Hub"),
            _part("bolt", "Bolt M4"),
        ],
    )


def test_two_levels_without_status():
    root = _rover()
    tree = _tree(root)
    assert set(tree) == RESPONSE_FIELDS
    assert (tree["part_id"], tree["part_name"], tree["kind"], tree["status_included"]) == ("rover", "Rover", "assembly", False)
    assert [c["occurrence_id"] for c in tree["children"]] == ["chassis", "wheel_l", "wheel_r", "batt", "spare"]
    assert tree["node_count"] == 5 + 3 * 2
    for node in _walk(tree):
        assert set(node) == NODE_FIELDS
        assert node["constraint"] is None
    wheel = tree["children"][1]
    assert (wheel["kind"], wheel["part_name"], wheel["path"]) == ("assembly", "Wheel", ["wheel_l"])
    assert [(c["occurrence_id"], c["path"], c["kind"], c["part_name"]) for c in wheel["children"]] == [
        ("hub", ["wheel_l", "hub"], "part", "Hub"),
        ("bolt", ["wheel_l", "bolt"], "part", "Bolt M4"),
    ]
    assert wheel["children"][0]["children"] == [] and wheel["children"][0]["mates"] is None and wheel["children"][0]["problems"] is None
    assert wheel["mates"] == {"count": 0, "suppressed": 0, "broken": None, "near": None, "held": None, "lost": None}
    assert wheel["patterns"] == {"count": 0, "suppressed": 0}
    assert tree["children"][0]["feature_count"] == 0


def test_a_sub_assembly_placed_twice_has_distinct_paths_and_the_same_child_ids():
    tree = _tree(_rover())
    left, right = tree["children"][1], tree["children"][2]
    assert [c["occurrence_id"] for c in left["children"]] == [c["occurrence_id"] for c in right["children"]] == ["hub", "bolt"]
    assert [c["path"] for c in left["children"]] == [["wheel_l", "hub"], ["wheel_l", "bolt"]]
    assert [c["path"] for c in right["children"]] == [["wheel_r", "hub"], ["wheel_r", "bolt"]]
    # "used N x": every placement of a Part in the whole tree, the suppressed spare included
    assert left["placements"] == right["placements"] == 3
    assert left["children"][0]["placements"] == 3
    assert tree["children"][0]["placements"] == 1


def test_missing_file_and_flags():
    tree = _tree(_rover())
    by_id = {c["occurrence_id"]: c for c in tree["children"]}
    batt = by_id["batt"]
    assert batt["kind"] == "missing"
    assert (batt["resolved_part_id"], batt["part_name"], batt["feature_count"], batt["placements"]) == (None, None, None, None)
    assert (batt["external_ref"], batt["ref_part_id"]) == ("parts/battery.didsa", "battery_gone")
    assert by_id["chassis"]["fixed"] and not by_id["wheel_l"]["fixed"]
    assert by_id["wheel_l"]["hidden"] and not by_id["wheel_r"]["hidden"]
    assert by_id["spare"]["suppressed"] and by_id["spare"]["children"]  # a suppressed occurrence is still listed, with its subtree
    assert (by_id["wheel_r"]["name_override"], by_id["wheel_r"]["color"]) == ("Right wheel", "#FF0000")


def test_problem_roll_up_without_status():
    """Missing files count on every assembly above them, once per placement; a suppressed subtree adds nothing above it."""
    root = _import(
        "top",
        [
            _part("top", "Top", [_occ("a1", "asm"), _occ("a2", "asm"), _occ("off", "asm", suppressed=True), _occ("gone", "nowhere")]),
            _part("asm", "Asm", [_occ("x", "nowhere"), _occ("ok", "leaf")]),
            _part("leaf", "Leaf"),
        ],
    )
    tree = _tree(root)
    assert tree["problems"] == {"missing": 3, "cycles": 0, "broken": None, "over_constrained": None, "near": None}
    for child in tree["children"][:3]:
        assert child["problems"]["missing"] == 1  # the suppressed one keeps its own count


def test_cycle_guard():
    """A Part placed inside itself, directly or through another Part, is a `cycle` node with no children (the server does
    not stop cycles being added, so the tree must not recurse)."""
    root = _import("loop_top", [_part("loop_top", "Top", [_occ("a", "loop_a")]), _part("loop_a", "Loop A", [_occ("b", "loop_b")]), _part("loop_b", "Loop B", [_occ("leaf", "leaf")]), _part("leaf", "Leaf")])
    get_part_or_404("loop_b").occurrences.append(Occurrence(id="back", part_id="loop_a"))
    get_part_or_404("loop_top").occurrences.append(Occurrence(id="self", part_id="loop_top"))
    tree = _tree(root)
    back = tree["children"][0]["children"][0]["children"][1]
    assert (back["path"], back["kind"], back["cycle"], back["children"], back["problems"]) == (["a", "b", "back"], "assembly", True, [], None)
    self_ = tree["children"][1]
    assert (self_["occurrence_id"], self_["cycle"], self_["children"]) == ("self", True, [])
    assert tree["problems"]["cycles"] == 2
    assert tree["children"][0]["problems"]["cycles"] == 1
    assert tree["node_count"] == 5


def test_depth_cap():
    parts = [_part(f"d{i}", f"Depth {i}", [_occ(f"l{i + 1}", f"d{i + 1}")]) for i in range(5)] + [_part("d5", "Depth 5")]
    root = _import("d0", parts)
    full = _tree(root)
    assert not full["truncated_depth"] and full["node_count"] == 5
    capped = _tree(root, max_depth=3)
    assert capped["truncated_depth"] and not capped["truncated_nodes"]
    assert (capped["max_depth"], capped["node_count"]) == (3, 3)
    third = capped["children"][0]["children"][0]["children"][0]
    assert (third["path"], third["truncated"], third["children"]) == (["l1", "l2", "l3"], True, [])
    # the cap cannot be raised past 32, and must be at least 1
    assert client.get(f"/document/parts/{root}/assembly-tree", params={"max_depth": 33}).status_code == 422
    assert client.get(f"/document/parts/{root}/assembly-tree", params={"max_depth": 0}).status_code == 422


def test_node_cap():
    root = _import("w", [_part("w", "Wide", [_occ("s1", "sub"), _occ("s2", "sub")]), _part("sub", "Sub", [_occ(f"c{i}", "cube") for i in range(4)]), _part("cube", "Cube")])
    capped = _tree(root, max_nodes=7)
    assert capped["truncated_nodes"] and not capped["truncated_depth"]
    assert capped["node_count"] == 7
    assert [len(c["children"]) for c in capped["children"]] == [4, 1]
    assert capped["children"][1]["truncated"] and not capped["children"][0]["truncated"]
    assert client.get(f"/document/parts/{root}/assembly-tree", params={"max_nodes": 10_001}).status_code == 422


def test_a_part_on_its_own():
    _import("solo", [_part("solo", "Bracket")])
    tree = _tree("solo", status="true")
    assert (tree["kind"], tree["children"], tree["mates"], tree["problems"], tree["node_count"]) == ("part", [], None, None, 0)


def test_unknown_part_is_404():
    assert client.get("/document/parts/no-such-part/assembly-tree").status_code == 404


# --- with status: the gear-train demo -----------------------------------------------------------------------------------


def _gear_trains(*sources):
    """A new root placing each demo file's assembly once (`sources`: paths), every Part kept."""
    parts, roots = [], []
    for source in sources:
        doc = json.loads(source.read_text())["document"]
        for part in doc["parts"]:
            if part["id"] in {p["id"] for p in parts}:
                continue
            parts.append(part)
        roots.append(doc["root_part_id"])
    return parts, roots


@pytest.fixture
def demo_twice():
    """The demo's gear train placed twice under a new root, plus a missing file (imported per test: another test's import replaces the document)."""
    parts, (train,) = _gear_trains(DEMO)
    parts = copy.deepcopy(parts) + [_part("bench", "Bench", [_occ("left", train, fixed=True), _occ("right", train), _occ("lost", "nowhere")])]
    return _import("bench", parts), train


def _agrees_level_by_level(node, part_id):
    """Children against `/occurrences`, constraint against `/constraint-status`, mates against `/mates`, then recurse."""
    occurrences = client.get(f"/document/parts/{part_id}/occurrences").json()
    status = client.get(f"/document/parts/{part_id}/constraint-status").json()
    mates = client.get(f"/document/parts/{part_id}/mates").json()
    assert [c["occurrence_id"] for c in node["children"]] == [o["id"] for o in occurrences]
    for child, occurrence in zip(node["children"], occurrences):
        for field, listed in (("external_ref", "external_ref"), ("resolved_part_id", "resolved_part_id"), ("ref_part_id", "ref_part_id"), ("name_override", "name_override"), ("fixed", "fixed"), ("hidden", "hidden"), ("suppressed", "suppressed"), ("color", "color")):
            assert child[field] == occurrence[listed], (child["path"], field)
        entry = status.get(occurrence["id"])
        if entry is None:
            assert child["constraint"] is None
        else:
            assert {k: child["constraint"][k] for k in ("status", "dof", "rigid_set")} == {k: entry[k] for k in ("status", "dof", "rigid_set")}, child["path"]
            touching = [m for m in mates if not m["suppressed"] and any(r["occurrence_id"].split("/")[0] == occurrence["id"] for r in m["references"])]
            assert child["constraint"]["broken_mates"] == sum(m["status"] == "broken" for m in touching)
            assert child["constraint"]["near_mates"] == sum(m["status"] == "near" for m in touching)
    assert node["mates"] == {
        "count": len(mates),
        "suppressed": sum(m["suppressed"] for m in mates),
        "broken": sum(m["status"] == "broken" for m in mates),
        "near": sum(m["status"] == "near" for m in mates),
        "held": sum(m["held"] for m in mates),
        "lost": sum(bool(m["lost_references"]) for m in mates),
    }
    for child in node["children"]:
        if child["kind"] == "assembly":
            _agrees_level_by_level(child, child["resolved_part_id"])


def test_status_agrees_with_occurrences_constraint_status_and_mates_level_by_level(demo_twice):
    root, train = demo_twice
    tree = _tree(root, status="true")
    assert tree["status_included"]
    left, right, lost = tree["children"]
    assert left["resolved_part_id"] == right["resolved_part_id"] == train
    assert [c["occurrence_id"] for c in left["children"]] == [c["occurrence_id"] for c in right["children"]]
    assert left["constraint"]["status"] == "fixed" and lost["constraint"] is None
    assert any(c["constraint"] and c["constraint"]["status"] == "under_constrained" for c in left["children"])
    _agrees_level_by_level(tree, root)


def test_status_off_leaves_the_status_fields_null(demo_twice):
    root, _train = demo_twice
    tree = _tree(root)
    assert not tree["status_included"]
    assert all(node["constraint"] is None for node in _walk(tree))
    assert tree["problems"] == {"missing": 1, "cycles": 0, "broken": None, "over_constrained": None, "near": None}
    assert tree["children"][0]["mates"]["broken"] is None and tree["children"][0]["mates"]["count"] == 18


def test_problem_roll_up_with_broken_mates():
    """The demo's old version (bevel mates on faces its bevel body no longer has: they read `broken`) placed twice: its
    broken mates count once per placement at the root, and on each row they touch."""
    parts, (old,) = _gear_trains(DATA / "gear_train_demo_old_bevel_indices.didsa")
    parts = copy.deepcopy(parts) + [_part("old_bench", "Bench", [_occ("one", old, fixed=True), _occ("two", old), _occ("off", old, suppressed=True)])]
    root = _import("old_bench", parts)
    tree = _tree(root, status="true")
    mates = client.get(f"/document/parts/{old}/mates").json()
    broken = sum(m["status"] == "broken" for m in mates)
    near = sum(m["status"] == "near" for m in mates)
    assert broken > 0
    one = tree["children"][0]
    assert one["mates"]["broken"] == broken
    assert one["problems"]["broken"] == broken
    over = sum(1 for c in one["children"] if c["constraint"] and c["constraint"]["status"] == "over_constrained" and not c["constraint"]["broken_mates"] and not c["constraint"]["near_mates"])
    assert one["problems"] == {"missing": 0, "cycles": 0, "broken": broken, "over_constrained": over, "near": near}
    assert tree["problems"] == {"missing": 0, "cycles": 0, "broken": 2 * broken, "over_constrained": 2 * over, "near": 2 * near}  # "off" is suppressed
    assert any(c["constraint"] and c["constraint"]["broken_mates"] > 0 for c in one["children"])
    _agrees_level_by_level(tree, root)
