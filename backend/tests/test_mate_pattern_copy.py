"""B2 steps 2-3: mates may reference faces of component-pattern copies, with clear 422s and cascades.

F1 (docs/pattern-followers-and-dissolve-plan.md, the tests from `_poses` down): a copy is a FOLLOWER of its source in the group solver (it is only frozen,
at the source's stored pose, when the source is fixed or outside the group), so a part mated to a copy follows when the source moves or the pattern is edited;
a mate the part cannot follow is reported broken."""

from fastapi.testclient import TestClient

from app.document.assembly import resolve_occurrence_target
from app.document.assembly_solver import _place_in_world, _resolve_local_geometry, compute_part_bodies
from app.document.store import get_document
from app.main import app
from tests.conftest import TEST_API_KEY
from tests.test_assembly_nested_mate import _assert_coincident_opposed, _occurrence
from tests.test_assembly_solver import _export_part, _find_planar_face, _make_box_part

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

COPY = "src#pattern:{pid}:1"


def _scene(src_at=(0.0, 0.0, 0.0), pattern=None, src_fixed=False, mover_fixed=False):
    leaf = _make_box_part("Leaf")
    mover = _make_box_part("Mover")
    top = _make_box_part("Top")
    exports = {"leaf": _export_part(leaf["id"]), "mover": _export_part(mover["id"]), "top": _export_part(top["id"])}
    parts = {k: e["document"]["parts"][0] for k, e in exports.items()}
    parts["top"]["features"] = []
    parts["top"]["occurrences"] = [
        _occurrence("src", leaf["id"], src_at, fixed=src_fixed),
        _occurrence("mover", mover["id"], (500.0, 500.0, 500.0), fixed=mover_fixed),
    ]
    parts["top"]["mates"] = []
    payload = {
        "schema_version": exports["top"]["schema_version"],
        "document": {"id": "copy-doc", "root_part_id": top["id"], "parts": list(parts.values())},
        "sketches": [s for e in exports.values() for s in e["sketches"]],
    }
    assert client.post("/document/import/native", json=payload).status_code == 200
    top_id = top["id"]
    response = client.post(
        f"/document/parts/{top_id}/component-patterns",
        json=pattern or {"source_occurrence_ids": ["src"], "pattern_type": "linear", "direction": [1, 0, 0], "count": 3, "spacing": 300.0},
    )
    assert response.status_code == 201, response.text
    return {"top": top, "leaf": leaf, "mover": mover, "pid": response.json()["id"]}


def _payload(scene, copy_id, mover_first=True, normal=(0.0, 0.0, 1.0)):
    leaf_face = _find_planar_face(scene["leaf"]["id"], scene["leaf"]["body_id"], normal)
    mover_face = _find_planar_face(scene["mover"]["id"], scene["mover"]["body_id"], tuple(-c for c in normal))
    mover_ref = {"occurrence_id": "mover", "subshape_ref": {"body_id": scene["mover"]["body_id"], "shape_type": "face", "index": mover_face}}
    copy_ref = {"occurrence_id": copy_id, "subshape_ref": {"body_id": scene["leaf"]["body_id"], "shape_type": "face", "index": leaf_face}}
    return {"type": "coincident", "references": [mover_ref, copy_ref] if mover_first else [copy_ref, mover_ref]}


def _world(scene, ref):
    from app.document.router import _mate_entity_ref_to_domain
    from app.document.schemas import MateEntityRefResponse

    document = get_document()
    part = document.parts[scene["top"]["id"]]
    domain = _mate_entity_ref_to_domain(MateEntityRefResponse(**ref))
    target, transform = resolve_occurrence_target(document, part, domain.occurrence_id)
    local = _resolve_local_geometry(target, compute_part_bodies(target), domain)
    return _place_in_world(local, transform) if transform is not None else local


def test_mate_to_a_pattern_copy_face_solves_the_other_part_onto_it():
    scene = _scene()
    top_id = scene["top"]["id"]
    payload = _payload(scene, COPY.format(pid=scene["pid"]))
    response = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert response.status_code == 201, response.text
    solve = client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={})
    assert solve.status_code == 200, solve.text
    _assert_coincident_opposed(_world(scene, payload["references"][0]), _world(scene, payload["references"][1]))
    # the copy's face is a different world plane from the source's: it sits 300 mm along X
    source_face = _world(scene, {**payload['references'][1], 'occurrence_id': 'src'})
    copy_face = _world(scene, payload['references'][1])
    assert abs(copy_face.point[0] - source_face.point[0] - 300.0) < 1e-3


def test_creating_the_mate_with_solve_drives_the_non_copy_side():
    scene = _scene()
    top_id = scene["top"]["id"]
    response = client.post(
        f"/document/parts/{top_id}/mates?solve=group", json=_payload(scene, COPY.format(pid=scene["pid"]), mover_first=False)
    )
    assert response.status_code == 201, response.text


def test_explicitly_driving_a_copy_is_a_clear_422():
    scene = _scene()
    top_id = scene["top"]["id"]
    copy_id = COPY.format(pid=scene["pid"])
    response = client.post(
        f"/document/parts/{top_id}/mates", params={"solve": "group", "occurrence_id": copy_id}, json=_payload(scene, copy_id)
    )
    assert response.status_code == 422
    assert "pattern copy" in str(response.json()["detail"]).lower()


def test_a_dead_copy_is_rejected_at_creation():
    scene = _scene()
    top_id = scene["top"]["id"]
    response = client.post(f"/document/parts/{top_id}/mates", json=_payload(scene, f"src#pattern:{scene['pid']}:9"))
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "occurrence_not_found"


def test_a_source_and_its_own_copy_cannot_be_mated():
    scene = _scene()
    top_id = scene["top"]["id"]
    payload = _payload(scene, COPY.format(pid=scene["pid"]))
    payload["references"][0]["occurrence_id"] = "src"
    response = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert response.status_code == 422
    assert "different occurrences" in str(response.json()["detail"])


def _mate_ids(top_id):
    return [m["id"] for m in client.get(f"/document/parts/{top_id}/mates").json()]


def test_pattern_delete_update_and_source_delete_cascade_to_mates():
    for action in ("delete", "shrink", "source"):
        scene = _scene()
        top_id = scene["top"]["id"]
        pid = scene["pid"]
        assert client.post(f"/document/parts/{top_id}/mates", json=_payload(scene, COPY.format(pid=pid))).status_code == 201
        assert len(_mate_ids(top_id)) == 1
        if action == "delete":
            assert client.delete(f"/document/parts/{top_id}/component-patterns/{pid}").status_code == 204
        elif action == "shrink":
            assert client.patch(f"/document/parts/{top_id}/component-patterns/{pid}", json={"skip_indices": [1]}).status_code == 200
        else:
            assert client.delete(f"/document/parts/{top_id}/occurrences/src").status_code in (200, 204)
        assert _mate_ids(top_id) == [], action


def test_a_mate_on_a_surviving_copy_is_kept_when_the_pattern_is_edited():
    scene = _scene()
    top_id = scene["top"]["id"]
    assert client.post(f"/document/parts/{top_id}/mates", json=_payload(scene, COPY.format(pid=scene["pid"]))).status_code == 201
    assert client.patch(f"/document/parts/{top_id}/component-patterns/{scene['pid']}", json={"spacing": 400.0}).status_code == 200
    assert len(_mate_ids(top_id)) == 1


def test_native_round_trip_keeps_a_copy_mate():
    scene = _scene()
    top_id = scene["top"]["id"]
    assert client.post(f"/document/parts/{top_id}/mates", json=_payload(scene, COPY.format(pid=scene["pid"]))).status_code == 201
    exported = client.get("/document/export/native", params={"part_id": top_id})
    assert exported.status_code == 200, exported.text
    assert client.post("/document/import/native", json=exported.json()).status_code == 200
    mates = client.get(f"/document/parts/{top_id}/mates").json()
    assert len(mates) == 1
    assert mates[0]["references"][1]["occurrence_id"] == COPY.format(pid=scene["pid"])


# ---- F1: a part mated to a copy FOLLOWS the copy's source (docs/pattern-followers-and-dissolve-plan.md) -------------------

import numpy as np
import pytest

from app.document.assembly_group import build_group_model, solve_group
from app.document.constraint_model import FOLLOW_MODEL_VERSION, export_constraint_model


def _poses(top_id):
    return {o["id"]: o["transform"] for o in client.get(f"/document/parts/{top_id}/occurrences").json()}


def _t(transform):
    return np.array(transform["translation"], float)


def _move_source(top_id, **translation_delta):
    stored = _poses(top_id)["src"]
    t = list(stored["translation"])
    for axis, delta in translation_delta.items():
        t["xyz".index(axis)] += delta
    moved = client.patch(f"/document/parts/{top_id}/occurrences/src", json={"transform": {**stored, "translation": t}})
    assert moved.status_code == 200, moved.text


def _mate_and_settle(scene, normal=(0.0, 0.0, 1.0), copy_index=1):
    top_id = scene["top"]["id"]
    payload = _payload(scene, f"src#pattern:{scene['pid']}:{copy_index}", normal=normal)
    created = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert created.status_code == 201, created.text
    assert client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={}).status_code == 200
    return payload, created.json()["id"]


def _assert_still_mated(scene, payload, copy_index=1):
    _assert_coincident_opposed(_world(scene, payload["references"][0]), _world(scene, payload["references"][1]))


def test_a_part_mated_to_a_copy_follows_when_the_source_moves():
    scene = _scene()
    top_id = scene["top"]["id"]
    payload, _ = _mate_and_settle(scene)
    before = _poses(top_id)
    _move_source(top_id, z=100.0)
    solved = client.post(f"/document/parts/{top_id}/occurrences/src/solve", json={})
    assert solved.status_code == 200, solved.text
    after = _poses(top_id)
    assert np.allclose(_t(after["src"]) - _t(before["src"]), [0, 0, 100.0], atol=1e-6)  # the source stays where it was put
    assert np.allclose(_t(after["mover"]) - _t(before["mover"]), [0, 0, 100.0], atol=0.05)  # ... and the mated part follows
    _assert_still_mated(scene, payload)


@pytest.mark.parametrize("orient", [True, False])
def test_a_part_mated_to_a_circular_copy_follows_when_the_source_moves(orient):
    pattern = {
        "source_occurrence_ids": ["src"], "pattern_type": "circular", "count_angular": 4, "angle_total": 360.0,
        "axis": {"origin": [0, 0, 0], "direction": [0, 0, 1]}, "orient_with_rotation": orient,
    }
    scene = _scene(src_at=(200.0, 0.0, 0.0), pattern=pattern)
    top_id = scene["top"]["id"]
    payload, _ = _mate_and_settle(scene)
    before = _poses(top_id)
    _move_source(top_id, z=70.0)
    assert client.post(f"/document/parts/{top_id}/occurrences/src/solve", json={}).status_code == 200
    after = _poses(top_id)
    assert np.allclose(_t(after["mover"])[2] - _t(before["mover"])[2], 70.0, atol=0.05)
    _assert_still_mated(scene, payload)


def test_a_fixed_source_stays_put_and_the_part_mates_onto_its_copy():
    scene = _scene(src_fixed=True)
    top_id = scene["top"]["id"]
    before = _poses(top_id)
    payload, _ = _mate_and_settle(scene)
    after = _poses(top_id)
    assert after["src"] == before["src"]
    _assert_still_mated(scene, payload)


def _follower_model(scene):
    top = get_document().parts[scene["top"]["id"]]
    return build_group_model(get_document(), top, "mover")


def test_the_follower_group_carries_a_version_7_constraint_model_and_mate_motion_sends_it():
    # S1 (docs/pattern-followers-smoothness-plan.md): this assertion flipped ON PURPOSE. It used to be `export_constraint_model(model) is None`
    # and `body.get("constraint_model") is None` ("no constraint model for a follower"); a follower side now travels as wire version 7.
    scene = _scene()
    top_id = scene["top"]["id"]
    _mate_and_settle(scene)
    model = _follower_model(scene)
    assert sorted(model.member_ids) == ["mover", "src"]  # the copy joined its SOURCE to the group
    assert any(a.follow or b.follow for _m, a, b in model.sides)
    spec = export_constraint_model(model)
    assert spec is not None and spec["version"] == FOLLOW_MODEL_VERSION == 7
    follows = [s["follow"] for m in spec["mates"] for s in (m["a"], m["b"]) if "follow" in s]
    assert len(follows) == 1
    assert follows[0]["keep_rotation"] is False
    assert np.allclose(follows[0]["r"], np.eye(3)) and np.allclose(follows[0]["t"], [300.0, 0.0, 0.0])  # Linear: the copy is 300 mm along X
    response = client.post(f"/document/parts/{top_id}/occurrences/mover/mate-motion", json={"transform": None})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["converged"] is True and body["constraint_model"]["version"] == 7
    assert sorted(m["occurrence_id"] for m in body["members"]) == ["mover", "src"]


_CIRCULAR = {"source_occurrence_ids": ["src"], "pattern_type": "circular", "count_angular": 4, "angle_total": 360.0, "axis": {"origin": [0, 0, 0], "direction": [0, 0, 1]}}


@pytest.mark.parametrize(
    "name,pattern,src_at",
    [
        ("linear", None, (0.0, 0.0, 0.0)),
        ("linear-2d-reversed", {"source_occurrence_ids": ["src"], "pattern_type": "linear", "direction": [1, 0, 0], "count": 2, "spacing": 300.0, "reverse": True, "direction_2": [0, 1, 0], "count_2": 2, "spacing_2": 250.0}, (0.0, 0.0, 0.0)),
        ("circular-orient", {**_CIRCULAR, "orient_with_rotation": True}, (200.0, 0.0, 0.0)),
        ("circular-keep-rotation", {**_CIRCULAR, "orient_with_rotation": False}, (200.0, 0.0, 0.0)),
    ],
)
def test_a_follower_model_reproduces_the_backend_residual_and_its_analytic_jacobian_matches_central_differences(name, pattern, src_at):
    from tests.test_constraint_model import _assert_parity

    scene = _scene(src_at=src_at, pattern=pattern)
    _mate_and_settle(scene)
    model = _follower_model(scene)
    spec = export_constraint_model(model)
    assert spec["version"] == 7 and any("follow" in s for m in spec["mates"] for s in (m["a"], m["b"])), name
    assert spec["mates"][0]["a"].get("follow", spec["mates"][0]["b"].get("follow"))["keep_rotation"] is (name == "circular-keep-rotation")
    _assert_parity(name, model, spec, np.random.default_rng(11))  # residual == GroupModel.residual; Jacobian == both central-difference ones


def test_a_group_with_a_follower_never_uses_the_py_slvs_fallback(monkeypatch):
    # B (fixed) is mated to the source AND to its copy on the same plane: no placement of the single member A can satisfy both.
    scene = _scene(mover_fixed=True)
    top_id = scene["top"]["id"]
    face_normal = (1.0, 0.0, 0.0)
    for occurrence in ("src", f"src#pattern:{scene['pid']}:1"):
        assert client.post(f"/document/parts/{top_id}/mates", json=_payload(scene, occurrence, normal=face_normal)).status_code == 201

    def boom(*args, **kwargs):
        raise AssertionError("py-slvs fallback ran for a group with a follower side")

    import app.document.assembly_group as group_module

    monkeypatch.setattr(group_module, "solve_occurrence_from_guess", boom)
    result = solve_group(get_document(), get_document().parts[top_id], "src")
    assert result.converged is False  # and, above all, no false "converged" from a fallback that ignores the follower mate


@pytest.mark.parametrize("mate_type", ["limit_distance", "gear"])
def test_coupler_and_limit_mates_on_a_copy_are_refused(mate_type):
    scene = _scene()
    top_id = scene["top"]["id"]
    payload = _payload(scene, COPY.format(pid=scene["pid"]))
    payload["type"] = mate_type
    if mate_type == "limit_distance":
        payload["limit_min"] = 0.0
    response = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert response.status_code == 422
    assert "pattern copy" in str(response.json()["detail"]).lower()
    assert _mate_ids(top_id) == []


# ---- F1 (pattern edits re-solve what is mated to their copies; broken mates) ---------------------------------------------

def test_a_pattern_spacing_edit_moves_the_mated_part_with_the_copy_not_the_source():
    scene = _scene()
    top_id = scene["top"]["id"]
    payload, _ = _mate_and_settle(scene, normal=(1.0, 0.0, 0.0))
    before = _poses(top_id)
    edited = client.patch(f"/document/parts/{top_id}/component-patterns/{scene['pid']}", json={"spacing": 450.0})
    assert edited.status_code == 200, edited.text
    assert edited.json()["spacing"] == 450.0 and edited.json()["broken_mate_ids"] == []
    after = _poses(top_id)
    assert after["src"] == before["src"]
    assert np.allclose(_t(after["mover"]) - _t(before["mover"]), [150.0, 0, 0], atol=0.05)
    _assert_still_mated(scene, payload)



def _mate_status(top_id, mate_id):
    return next(m for m in client.get(f"/document/parts/{top_id}/mates").json() if m["id"] == mate_id)["status"]


def test_a_satisfied_mate_is_ok_and_one_never_solved_is_broken():
    scene = _scene()
    top_id = scene["top"]["id"]
    payload = _payload(scene, COPY.format(pid=scene["pid"]))
    mate_id = client.post(f"/document/parts/{top_id}/mates", json=payload).json()["id"]
    assert _mate_status(top_id, mate_id) == "broken"  # `mover` sits 500 mm away: the stored poses do not satisfy it
    assert client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={}).status_code == 200
    assert _mate_status(top_id, mate_id) == "ok"
    assert client.patch(f"/document/parts/{top_id}/mates/{mate_id}", json={"suppressed": True}).status_code == 200
    assert _mate_status(top_id, mate_id) == "ok"  # a suppressed mate is never broken


def test_a_pattern_edit_the_mated_part_cannot_follow_is_stored_and_leaves_the_mate_broken_until_it_is_undone():
    scene = _scene()
    top_id = scene["top"]["id"]
    _payload_, mate_id = _mate_and_settle(scene, normal=(1.0, 0.0, 0.0))
    assert client.patch(f"/document/parts/{top_id}/occurrences/mover", json={"fixed": True}).status_code == 200
    before = _poses(top_id)
    edited = client.patch(f"/document/parts/{top_id}/component-patterns/{scene['pid']}", json={"spacing": 450.0})
    assert edited.status_code == 200, edited.text  # the edit is never refused because of a mate
    assert edited.json()["spacing"] == 450.0 and edited.json()["broken_mate_ids"] == [mate_id]
    assert client.get(f"/document/parts/{top_id}/component-patterns").json()[0]["spacing"] == 450.0  # stored
    assert _poses(top_id) == before  # the fixed part and the source stay put
    assert _mate_status(top_id, mate_id) == "broken"
    back = client.patch(f"/document/parts/{top_id}/component-patterns/{scene['pid']}", json={"spacing": 300.0})
    assert back.status_code == 200 and back.json()["broken_mate_ids"] == []
    assert _mate_status(top_id, mate_id) == "ok"


def test_a_limit_mate_outside_its_range_is_broken_inside_it_ok():
    from tests.test_limit_mates import _limit, slider_scene

    root, block, stop = slider_scene()  # the gap starts at 20 mm
    inside = _limit(root, block, stop, limit_min=0.0, limit_max=50.0)
    assert inside.status_code == 201, inside.text
    outside = _limit(root, block, stop, limit_max=10.0)
    assert outside.status_code == 201, outside.text
    assert _mate_status(root, inside.json()["id"]) == "ok"
    assert _mate_status(root, outside.json()["id"]) == "broken"


def test_a_dead_copy_in_a_parent_assembly_mate_is_cleaned_up_across_parts():
    from tests.test_assembly_nested_mate import _mate_payload

    scene = _nested_scene_with_pattern()
    top_id, sub_id, pid = scene["top"]["id"], scene["sub"]["id"], scene["pid"]
    payload = _mate_payload(scene, "mover", "outer/inner")
    payload["references"][1]["occurrence_id"] = f"outer/inner#pattern:{pid}:1"
    created = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert created.status_code == 201, created.text
    assert client.patch(f"/document/parts/{sub_id}/component-patterns/{pid}", json={"skip_indices": [1]}).status_code == 200
    assert _mate_ids(top_id) == [], "the parent assembly's mate on the now-dead copy is dropped"


def _nested_scene_with_pattern():
    from tests.test_assembly_nested_mate import _build_scene

    scene = _build_scene()
    response = client.post(
        f"/document/parts/{scene['sub']['id']}/component-patterns",
        json={"source_occurrence_ids": ["inner"], "pattern_type": "linear", "direction": [0, 1, 0], "count": 3, "spacing": 200.0},
    )
    assert response.status_code == 201, response.text
    return {**scene, "pid": response.json()["id"]}
