"""Prompt E: real-OCCT tests for Chamfer's full router/HTTP surface - mirrors
test_stage_d_fillet.py exactly, substituting chamfer-features/distance for
fillet-features/radius and BRepFilletAPI_MakeChamfer's chamfer_failed for
fillet_failed. All touch `app.main`/`app.document.chamfer`/
`app.document.extrude`, which import OCC.Core directly, so (per the
recurring caveat in docs/status.md) these are `ast.parse`-verified/manually
reviewed only in this sandbox, same as every other OCCT-touching backend
prompt in this project until real CI runs it.
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers -----------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _first_body_id(part_id: str) -> str:
    mesh = _mesh(part_id)
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _boxy_part_and_body() -> tuple[dict, str]:
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    return part, _first_body_id(part["id"])


def _edge_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "edge", "index": index}


def _create_chamfer(part_id: str, edge_refs: list[dict], distance: float):
    return client.post(
        f"/document/parts/{part_id}/chamfer-features",
        json={"edge_refs": edge_refs, "distance": distance},
    )


# --- Success -------------------------------------------------------------------


def test_chamfering_every_edge_of_a_box_with_a_small_shared_distance_succeeds():
    """A fully-chamfered box at a distance well under half its edge length
    is a standard, always-valid OCCT operation - no brute force needed the
    way other Create Plane tests need to hunt for a working index, since
    "every edge" is unambiguous."""
    part, body_id = _boxy_part_and_body()
    response = _create_chamfer(part["id"], [_edge_ref(body_id, i) for i in range(12)], 1.0)
    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "chamfer"
    assert body["distance"] == 1.0
    assert len(body["edge_refs"]) == 12
    assert body["produces"] == "body"


def test_the_chamfered_bodys_mesh_keeps_the_same_body_id():
    """The body-id-stability decision (same as Prompt D's own scope note):
    Chamfer modifies a Body in place rather than minting a new id - the
    `/mesh` response's `body_id` for the chamfered Body must be unchanged
    from before the Chamfer was applied."""
    part, body_id = _boxy_part_and_body()
    response = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0)
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["body_id"] == body_id


def test_a_single_edge_chamfer_actually_changes_the_meshs_geometry():
    part, body_id = _boxy_part_and_body()
    mesh_before = _mesh(part["id"])[0]["mesh"]
    response = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0)
    assert response.status_code == 201

    mesh_after = _mesh(part["id"])[0]["mesh"]
    assert mesh_after["vertices"] != mesh_before["vertices"]


def test_list_features_includes_the_chamfer():
    part, body_id = _boxy_part_and_body()
    created = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0).json()

    features = client.get(f"/document/parts/{part['id']}/features").json()
    chamfer_entries = {f["id"]: f for f in features if f["type"] == "chamfer"}
    assert created["id"] in chamfer_entries
    assert chamfer_entries[created["id"]]["distance"] == 1.0


# --- Rejections ------------------------------------------------------------


def test_edges_spanning_two_different_bodies_is_rejected_as_mixed_body_selection():
    part = _create_part()
    sketch_a = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], sketch_a["id"])
    sketch_b = _create_square_sketch_feature(part["id"], x0=100.0, y0=100.0)
    _create_extrude_feature(part["id"], sketch_b["id"])

    mesh = _mesh(part["id"])
    assert len(mesh) == 2
    body_id_a, body_id_b = mesh[0]["body_id"], mesh[1]["body_id"]

    response = _create_chamfer(part["id"], [_edge_ref(body_id_a, 0), _edge_ref(body_id_b, 0)], 1.0)
    assert response.status_code == 422
    detail = response.json()["detail"]
    assert detail["type"] == "mixed_body_selection"
    assert set(detail["body_ids"]) == {body_id_a, body_id_b}


def test_an_excessive_distance_is_rejected_as_chamfer_failed_not_a_500():
    part, body_id = _boxy_part_and_body()
    response = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1000.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "chamfer_failed"


def test_a_zero_distance_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 0.0)
    assert response.status_code == 400


def test_a_negative_distance_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], -1.0)
    assert response.status_code == 400


def test_an_empty_edge_refs_list_is_rejected():
    part, _body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/chamfer-features",
        json={"edge_refs": [], "distance": 1.0},
    )
    assert response.status_code == 422


def test_a_face_ref_masquerading_as_an_edge_ref_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/chamfer-features",
        json={"edge_refs": [{"body_id": body_id, "shape_type": "face", "index": 0}], "distance": 1.0},
    )
    assert response.status_code == 422


def test_an_unknown_body_id_is_a_missing_reference():
    part, _body_id = _boxy_part_and_body()
    response = _create_chamfer(part["id"], [_edge_ref("no-such-body", 0)], 1.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


# --- Editing / rollback ------------------------------------------------------


def test_patch_updates_the_distance_and_the_mesh_reflects_it():
    part, body_id = _boxy_part_and_body()
    created = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0).json()
    mesh_at_distance_1 = _mesh(part["id"])[0]["mesh"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/chamfer-features/{created['id']}",
        json={"distance": 2.0},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["distance"] == 2.0

    mesh_at_distance_2 = _mesh(part["id"])[0]["mesh"]
    assert mesh_at_distance_2["vertices"] != mesh_at_distance_1["vertices"]


def test_patch_re_validates_the_merged_candidate_and_rejects_an_excessive_distance():
    part, body_id = _boxy_part_and_body()
    created = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0).json()

    patch_response = client.patch(
        f"/document/parts/{part['id']}/chamfer-features/{created['id']}",
        json={"distance": 1000.0},
    )
    assert patch_response.status_code == 422
    assert patch_response.json()["detail"]["type"] == "chamfer_failed"

    # A rejected PATCH must never leave the Feature half-updated.
    features = client.get(f"/document/parts/{part['id']}/features").json()
    chamfer_entry = next(f for f in features if f["id"] == created["id"])
    assert chamfer_entry["distance"] == 1.0


def test_patch_can_edit_an_earlier_chamfer_via_rollback_style_editing():
    """B4: any Feature can be edited, not just the last one - editing this
    Chamfer's distance after a later Feature (a second Extrude, unrelated
    body) has been added must still resolve correctly, re-validated against
    the Body's shape *before* this Chamfer's own prior effect (see
    `app.document.chamfer.resolve_chamfer`'s own doc comment)."""
    part, body_id = _boxy_part_and_body()
    created = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0).json()

    other_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=100.0)
    _create_extrude_feature(part["id"], other_sketch["id"])

    patch_response = client.patch(
        f"/document/parts/{part['id']}/chamfer-features/{created['id']}",
        json={"distance": 1.5},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["distance"] == 1.5


# --- Cascade delete ------------------------------------------------------------


def test_cascade_deleting_the_owning_extrude_takes_the_chamfer_with_it():
    part, body_id = _boxy_part_and_body()
    extrude_feature_id = body_id
    chamfer = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{extrude_feature_id}/cascade")
    assert response.status_code == 200
    assert chamfer["id"] in response.json()["deleted_feature_ids"]

    features = client.get(f"/document/parts/{part['id']}/features").json()
    assert all(f["id"] != chamfer["id"] for f in features)


# --- Interaction with Fillet -------------------------------------------------


def test_a_body_with_both_a_fillet_and_a_chamfer_recomputes_correctly():
    """Prompt E's own on-device gate: a Body with both a Fillet and a
    Chamfer applied (in either order) must render/recompute correctly -
    both modify their target Body in place and keep its `body_id`, so
    applying one after the other must not raise and must keep changing the
    mesh's geometry each time."""
    part, body_id = _boxy_part_and_body()
    fillet_response = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0)
    assert fillet_response.status_code == 201
    mesh_after_chamfer = _mesh(part["id"])[0]["mesh"]

    chamfer_response = client.post(
        f"/document/parts/{part['id']}/fillet-features",
        json={"edge_refs": [_edge_ref(body_id, 2)], "radius": 1.0},
    )
    assert chamfer_response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["body_id"] == body_id
    assert mesh[0]["mesh"]["vertices"] != mesh_after_chamfer["vertices"]
