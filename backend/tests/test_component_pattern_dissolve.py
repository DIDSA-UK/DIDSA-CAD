"""F2 (`docs/pattern-followers-and-dissolve-plan.md`): `POST /parts/{id}/component-patterns/{pid}/dissolve` turns every live copy into a
real occurrence at the copy's own pose, re-points mates / appearance overrides / scene overrides at it (in every Part), splits
`scope: "pattern"` appearance overrides and deletes the pattern."""

import copy

import numpy as np

from app.document.store import get_document
from tests.test_assembly_nested_mate import _build_scene, _mate_payload
from tests.test_assembly_solver import _export_part, _find_planar_face, _make_box_part, client
from tests.test_assembly_nested_mate import _occurrence

LINEAR_2X2 = {
    "source_occurrence_ids": ["src"], "pattern_type": "linear", "direction": [1, 0, 0], "count": 2, "spacing": 300.0,
    "direction_2": [0, 1, 0], "count_2": 2, "spacing_2": 200.0,
}
CIRCULAR = {
    "source_occurrence_ids": ["src"], "pattern_type": "circular", "count_angular": 4, "angle_total": 360.0,
    "axis": {"origin": [0, 0, 0], "direction": [0, 0, 1]},
}


def _scene(pattern=LINEAR_2X2, src_at=(0.0, 0.0, 0.0), src_name=None, src_fixed=False, src_color=None):
    leaf = _make_box_part("Leaf")
    mover = _make_box_part("Mover")
    top = _make_box_part("Top")
    exports = {"leaf": _export_part(leaf["id"]), "mover": _export_part(mover["id"]), "top": _export_part(top["id"])}
    parts = {k: e["document"]["parts"][0] for k, e in exports.items()}
    parts["top"]["features"] = []
    src = _occurrence("src", leaf["id"], src_at, fixed=src_fixed)
    src["name_override"] = src_name
    if src_color:
        src["color"] = src_color
    parts["top"]["occurrences"] = [src, _occurrence("mover", mover["id"], (500.0, 500.0, 500.0))]
    parts["top"]["mates"] = []
    payload = {
        "schema_version": exports["top"]["schema_version"],
        "document": {"id": "dissolve-doc", "root_part_id": top["id"], "parts": list(parts.values())},
        "sketches": [s for e in exports.values() for s in e["sketches"]],
    }
    assert client.post("/document/import/native", json=payload).status_code == 200
    response = client.post(f"/document/parts/{top['id']}/component-patterns", json=pattern)
    assert response.status_code == 201, response.text
    return {"top": top, "leaf": leaf, "mover": mover, "pid": response.json()["id"]}


def _dissolve(scene):
    return client.post(f"/document/parts/{scene['top']['id']}/component-patterns/{scene['pid']}/dissolve")


def _instances(top_id):
    data = client.get(f"/document/parts/{top_id}/assembly-mesh", params={"geometry": "false"}).json()
    return {"/".join(i["occurrence_path"]): i for i in data["instances"]}


def _same_pose(a, b):
    ta, tb = a["world_transform"], b["world_transform"]
    return (
        np.allclose(ta["translation"], tb["translation"], atol=1e-9)
        and np.allclose(np.array(ta["rotation_axis"]) * ta["rotation_angle_degrees"], np.array(tb["rotation_axis"]) * tb["rotation_angle_degrees"], atol=1e-9)
    )


def _check_every_copy_became_an_occurrence_at_the_same_pose(scene):
    top_id = scene["top"]["id"]
    before = _instances(top_id)
    response = _dissolve(scene)
    assert response.status_code == 200, response.text
    body = response.json()
    after = _instances(top_id)
    copies = {k: v for k, v in before.items() if "#pattern:" in k}
    assert copies and set(body["renamed"]) == set(copies)
    for old, new_id in body["renamed"].items():
        assert new_id in after and "#pattern:" not in new_id
        assert _same_pose(copies[old], after[new_id]), (old, new_id)
        assert after[new_id]["part_id"] == copies[old]["part_id"]
    assert len(after) == len(before)  # the same instances, the copy paths replaced by plain ids
    assert not any("#pattern:" in k for k in after)
    assert [o["id"] for o in body["occurrences"]] == [body["renamed"][k] for k in sorted(body["renamed"], key=lambda k: int(k.rsplit(":", 1)[1]))]
    assert client.get(f"/document/parts/{top_id}/component-patterns").json() == []
    return body


def test_a_linear_grid_becomes_real_occurrences_at_exactly_the_copies_poses():
    scene = _scene()
    body = _check_every_copy_became_an_occurrence_at_the_same_pose(scene)
    assert len(body["occurrences"]) == 3 and all(o["fixed"] is False for o in body["occurrences"])
    ids = [o["id"] for o in client.get(f"/document/parts/{scene['top']['id']}/occurrences").json()]
    assert ids[0] == "src" and ids[1:4] == [o["id"] for o in body["occurrences"]] and ids[4] == "mover"  # each right after its source


def test_a_circular_pattern_becomes_real_occurrences_at_exactly_the_copies_poses():
    scene = _scene(CIRCULAR, src_at=(200.0, 0.0, 0.0))
    body = _check_every_copy_became_an_occurrence_at_the_same_pose(scene)
    assert len(body["occurrences"]) == 3


def test_skipped_indices_produce_no_occurrence():
    scene = _scene({**LINEAR_2X2, "skip_indices": [2]})
    body = _check_every_copy_became_an_occurrence_at_the_same_pose(scene)
    assert len(body["occurrences"]) == 2 and not any(k.endswith(":2") for k in body["renamed"])


def test_a_fixed_source_does_not_make_its_dissolved_copies_fixed():
    scene = _scene(src_fixed=True)
    body = _check_every_copy_became_an_occurrence_at_the_same_pose(scene)
    assert all(o["fixed"] is False for o in body["occurrences"])
    assert next(o for o in client.get(f"/document/parts/{scene['top']['id']}/occurrences").json() if o["id"] == "src")["fixed"] is True


def test_a_suppressed_pattern_is_a_422_and_changes_nothing_and_an_unknown_one_a_404():
    scene = _scene()
    top_id = scene["top"]["id"]
    assert client.patch(f"/document/parts/{top_id}/component-patterns/{scene['pid']}", json={"suppressed": True}).status_code == 200
    before = (client.get(f"/document/parts/{top_id}/occurrences").json(), client.get(f"/document/parts/{top_id}/component-patterns").json())
    assert _dissolve(scene).status_code == 422
    assert (client.get(f"/document/parts/{top_id}/occurrences").json(), client.get(f"/document/parts/{top_id}/component-patterns").json()) == before
    assert client.post(f"/document/parts/{top_id}/component-patterns/nope/dissolve").status_code == 404


def test_naming_follows_the_source_override_or_leaves_it_to_the_tree():
    plain = _scene()
    assert [o["name_override"] for o in _dissolve(plain).json()["occurrences"]] == [None, None, None]
    named = _scene(src_name="Short Rail BOT_RIGHT")
    names = [o["name_override"] for o in _dissolve(named).json()["occurrences"]]
    assert names == ["Short Rail BOT_RIGHT (2)", "Short Rail BOT_RIGHT (3)", "Short Rail BOT_RIGHT (4)"]  # pattern index + 1


def _face_ref(part, body_key, normal):
    return {"body_id": part["body_id"], "shape_type": "face", "index": _find_planar_face(part["id"], part["body_id"], normal)}


def _mate_to_copy(scene, copy_index=1):
    top_id = scene["top"]["id"]
    payload = {
        "type": "coincident",
        "references": [
            {"occurrence_id": "mover", "subshape_ref": _face_ref(scene["mover"], "mover", (0.0, 0.0, -1.0))},
            {"occurrence_id": f"src#pattern:{scene['pid']}:{copy_index}", "subshape_ref": _face_ref(scene["leaf"], "leaf", (0.0, 0.0, 1.0))},
        ],
    }
    created = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert created.status_code == 201, created.text
    return created.json()["id"]


def test_a_mate_on_a_copy_names_the_new_occurrence_and_still_solves():
    scene = _scene()
    top_id = scene["top"]["id"]
    mate_id = _mate_to_copy(scene)
    assert client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={}).status_code == 200
    mover_before = next(o for o in client.get(f"/document/parts/{top_id}/occurrences").json() if o["id"] == "mover")["transform"]
    body = _dissolve(scene).json()
    new_id = body["renamed"][f"src#pattern:{scene['pid']}:1"]
    mate = next(m for m in client.get(f"/document/parts/{top_id}/mates").json() if m["id"] == mate_id)
    assert mate["references"][1]["occurrence_id"] == new_id and mate["status"] == "ok"
    assert client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={}).status_code == 200
    mover_after = next(o for o in client.get(f"/document/parts/{top_id}/occurrences").json() if o["id"] == "mover")["transform"]
    assert np.allclose(mover_before["translation"], mover_after["translation"], atol=1e-3)
    # the former copy is an ordinary floating occurrence now: it no longer follows `src`
    def pose_of(oid):
        return next(o for o in client.get(f"/document/parts/{top_id}/occurrences").json() if o["id"] == oid)["transform"]

    former_copy_before = pose_of(new_id)
    assert client.patch(f"/document/parts/{top_id}/occurrences/src", json={"transform": {**pose_of("src"), "translation": [0, 0, 80.0]}}).status_code == 200
    assert pose_of(new_id) == former_copy_before


def test_a_parent_assemblys_mate_through_a_nested_path_is_rewritten():
    scene = _build_scene()
    sub_id, top_id = scene["sub"]["id"], scene["top"]["id"]
    pid = client.post(
        f"/document/parts/{sub_id}/component-patterns",
        json={"source_occurrence_ids": ["inner"], "pattern_type": "linear", "direction": [0, 1, 0], "count": 3, "spacing": 200.0},
    ).json()["id"]
    payload = _mate_payload(scene, "mover", "outer/inner")
    payload["references"][1]["occurrence_id"] = f"outer/inner#pattern:{pid}:1"
    created = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert created.status_code == 201, created.text
    body = client.post(f"/document/parts/{sub_id}/component-patterns/{pid}/dissolve").json()
    new_id = body["renamed"][f"inner#pattern:{pid}:1"]
    mate = client.get(f"/document/parts/{top_id}/mates").json()[0]
    assert mate["references"][1]["occurrence_id"] == f"outer/{new_id}"
    assert mate["status"] != "x" and client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={}).status_code == 200


def _put(top_id, body):
    response = client.put(f"/document/parts/{top_id}/appearance-overrides", json=body)
    assert response.status_code in (200, 201), response.text


def _colours(top_id):
    return {k: v["appearance"].get("colour") for k, v in _instances(top_id).items()}


def test_path_scene_and_pattern_scope_appearance_overrides_follow_the_copies():
    scene = _scene()
    top_id, pid = scene["top"]["id"], scene["pid"]
    copy1, copy2 = f"src#pattern:{pid}:1", f"src#pattern:{pid}:2"
    _put(top_id, {"path": copy1, "appearance": {"colour": "#112233"}})  # a path override on one copy
    _put(top_id, {"path": "src", "scope": "pattern", "pattern_id": pid, "appearance": {"colour": "#AA0000", "metallic": 1.0}})
    _put(top_id, {"path": copy2, "appearance": {"opacity": 0.5}})  # a copy with its OWN override that leaves colour / metallic unset
    scene_response = client.post(
        f"/document/parts/{top_id}/scenes",
        json={"name": "S", "overrides": [{"path": copy1, "hidden": True}]},
    )
    assert scene_response.status_code == 201, scene_response.text
    before = _instances(top_id)
    renamed = _dissolve(scene).json()["renamed"]
    after = _instances(top_id)
    # every instance paints the same as before: the source, every copy under its new id
    assert after["src"]["appearance"] == before["src"]["appearance"]
    for old, new_id in renamed.items():
        assert after[new_id]["appearance"] == before[old]["appearance"], old
    assert before[copy1]["appearance"]["colour"] == "#112233" and before[copy2]["appearance"]["metallic"] == 1.0  # (fixture sanity)
    overrides = client.get(f"/document/parts/{top_id}/appearance-overrides").json()["overrides"]
    assert not any(o.get("scope") == "pattern" for o in overrides)
    paths = [o["path"] for o in overrides if o.get("scope") is None]
    assert len(paths) == len(set(paths)), "merged, never two overrides on one target"
    assert set(paths) == {"src", *renamed.values()}
    merged = next(o for o in overrides if o["path"] == renamed[copy2])
    assert merged["appearance"] == {"opacity": 0.5, "colour": "#AA0000", "metallic": 1.0}
    own = next(o for o in overrides if o["path"] == renamed[copy1])
    assert own["appearance"] == {"colour": "#112233", "metallic": 1.0}  # keeps its own colour, takes the rest
    scene_after = client.get(f"/document/parts/{top_id}/scenes").json()[0]
    assert [o["path"] for o in scene_after["overrides"]] == [renamed[copy1]]


def test_native_export_import_round_trip_after_a_dissolve():
    scene = _scene()
    top_id = scene["top"]["id"]
    _put(top_id, {"path": "src", "scope": "pattern", "pattern_id": scene["pid"], "appearance": {"colour": "#AA0000"}})
    _mate_to_copy(scene)
    assert _dissolve(scene).status_code == 200
    exported = client.get("/document/export/native")  # the whole document: every placed part resolves again on import
    assert exported.status_code == 200, exported.text
    assert client.post("/document/import/native", json=copy.deepcopy(exported.json())).status_code == 200
    assert client.get("/document/export/native").json() == exported.json()
    assert len(client.get(f"/document/parts/{top_id}/occurrences").json()) == 5
