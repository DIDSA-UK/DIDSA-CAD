"""B2 steps 2-3: mates may reference faces of component-pattern copies (frozen sides), with clear 422s and cascades."""

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


def _scene():
    leaf = _make_box_part("Leaf")
    mover = _make_box_part("Mover")
    top = _make_box_part("Top")
    exports = {"leaf": _export_part(leaf["id"]), "mover": _export_part(mover["id"]), "top": _export_part(top["id"])}
    parts = {k: e["document"]["parts"][0] for k, e in exports.items()}
    parts["top"]["features"] = []
    parts["top"]["occurrences"] = [
        _occurrence("src", leaf["id"], (0.0, 0.0, 0.0)),
        _occurrence("mover", mover["id"], (500.0, 500.0, 500.0)),
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
        json={"source_occurrence_ids": ["src"], "pattern_type": "linear", "direction": [1, 0, 0], "count": 3, "spacing": 300.0},
    )
    assert response.status_code == 201, response.text
    return {"top": top, "leaf": leaf, "mover": mover, "pid": response.json()["id"]}


def _payload(scene, copy_id, mover_first=True):
    leaf_face = _find_planar_face(scene["leaf"]["id"], scene["leaf"]["body_id"], (0.0, 0.0, 1.0))
    mover_face = _find_planar_face(scene["mover"]["id"], scene["mover"]["body_id"], (0.0, 0.0, -1.0))
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
