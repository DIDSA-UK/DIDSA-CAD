"""`GET /parts/{id}/assembly-mesh?geometry=false` (docs/pattern-followers-and-dissolve-plan.md, "One backend addition for VR"): the same
instances (paths and world transforms, pattern copies and nested parts included), no tessellation."""

from tests.test_component_pattern_dissolve import LINEAR_2X2, _scene, _put, client


def _both(top_id):
    full = client.get(f"/document/parts/{top_id}/assembly-mesh")
    lean = client.get(f"/document/parts/{top_id}/assembly-mesh", params={"geometry": "false"})
    assert full.status_code == 200 and lean.status_code == 200, (full.text, lean.text)
    return full.json(), lean.json()


def test_geometry_false_has_the_same_instances_and_no_geometry():
    scene = _scene(LINEAR_2X2)
    top_id = scene["top"]["id"]
    full, lean = _both(top_id)
    assert full["geometry"], "the default stays unchanged: geometry is returned"
    assert lean["geometry"] == []
    key = lambda i: ("/".join(i["occurrence_path"]), i["part_id"], i["hidden"], i["color"])  # noqa: E731
    assert [key(i) for i in lean["instances"]] == [key(i) for i in full["instances"]]
    assert [i["world_transform"] for i in lean["instances"]] == [i["world_transform"] for i in full["instances"]]
    assert sum("#pattern:" in "/".join(i["occurrence_path"]) for i in lean["instances"]) == 3  # the copies are there


def test_geometry_true_is_the_default_and_the_node_level_look_survives_geometry_false():
    scene = _scene(LINEAR_2X2)
    top_id = scene["top"]["id"]
    _put(top_id, {"path": "src", "appearance": {"colour": "#2F6FD6"}})
    explicit = client.get(f"/document/parts/{top_id}/assembly-mesh", params={"geometry": "true"}).json()
    full, lean = _both(top_id)
    assert explicit["instances"] == full["instances"]
    by_path = lambda data: {"/".join(i["occurrence_path"]): i["appearance"] for i in data["instances"]}  # noqa: E731
    assert by_path(lean)["src"] == {"colour": "#2F6FD6"} == by_path(full)["src"]
