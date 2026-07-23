"""Pattern/Mirror scoping's Phase 1 (`docs/pattern-mirror-scope.md` §2.1/§4):
real-OCCT tests for Mirror's full router/HTTP surface - mirrors
test_stage_e_chamfer.py's structure exactly, substituting mirror-features'
source_body_ids/mirror_plane for chamfer-features' edge_refs/distance. All
touch `app.main`/`app.document.mirror`/`app.document.extrude`/`app.document.
create_plane`, which import OCC.Core directly, so (per the recurring caveat
in docs/status.md) these are `ast.parse`-verified/manually reviewed only in
this sandbox, same as every other OCCT-touching backend prompt in this
project until real CI runs it.
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


def _fixed_plane_ref(plane: str) -> dict:
    return {"face_ref": None, "fixed_plane": plane, "plane_feature_id": None}


def _face_plane_ref(body_id: str, index: int) -> dict:
    return {"face_ref": {"body_id": body_id, "shape_type": "face", "index": index}, "fixed_plane": None,
            "plane_feature_id": None}


def _create_plane_feature_ref(plane_feature_id: str) -> dict:
    return {"face_ref": None, "fixed_plane": None, "plane_feature_id": plane_feature_id}


def _create_mirror(part_id: str, source_body_ids: list[str], mirror_plane: dict):
    return client.post(
        f"/document/parts/{part_id}/mirror-features",
        json={"source_body_ids": source_body_ids, "mirror_plane": mirror_plane},
    )


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _vertex_x_range(part_id: str, body_id: str) -> tuple[float, float]:
    mesh = next(entry for entry in _mesh(part_id) if entry["body_id"] == body_id)
    xs = [v[0] for v in mesh["mesh"]["vertices"]]
    return min(xs), max(xs)


# --- Success -------------------------------------------------------------------


def test_mirroring_a_box_about_a_fixed_plane_succeeds():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"))
    assert response.status_code == 201
    feature = response.json()
    assert feature["type"] == "mirror"
    assert feature["source_body_ids"] == [body_id]
    assert feature["produces"] == "body"


def test_mirroring_produces_a_second_independent_body():
    part, body_id = _boxy_part_and_body()
    _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"))

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 2
    assert body_id in body_ids


def test_mirroring_about_yz_reflects_the_box_across_x_equals_zero():
    """The box spans x in [0, 10] (see `_add_square`'s default x0=0,
    size=10); `Plane.YZ` is the x=0 plane with normal (1, 0, 0) (see
    `app.document.plane_geometry._PLANE_BASIS`), so the mirrored copy must
    span x in [-10, 0] - the exact reflection, not just "some different
    shape"."""
    part, body_id = _boxy_part_and_body()
    _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ"))

    mirrored_body_id = next(bid for bid in _body_ids(part["id"]) if bid != body_id)
    original_min_x, original_max_x = _vertex_x_range(part["id"], body_id)
    mirrored_min_x, mirrored_max_x = _vertex_x_range(part["id"], mirrored_body_id)

    assert (original_min_x, original_max_x) == (0.0, 10.0)
    assert (mirrored_min_x, mirrored_max_x) == (-10.0, 0.0)


def test_mirror_about_a_body_face_succeeds():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [body_id], _face_plane_ref(body_id, 0))
    assert response.status_code == 201
    assert len(_body_ids(part["id"])) == 2


def test_mirror_about_an_existing_create_plane_feature_succeeds():
    part, body_id = _boxy_part_and_body()
    plane_response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [_fixed_plane_ref("XY")],
            "offset": 5.0,
        },
    )
    assert plane_response.status_code == 201
    plane_feature = plane_response.json()

    response = _create_mirror(part["id"], [body_id], _create_plane_feature_ref(plane_feature["id"]))
    assert response.status_code == 201
    assert len(_body_ids(part["id"])) == 2


def test_list_features_includes_the_mirror():
    part, body_id = _boxy_part_and_body()
    created = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ")).json()

    features = client.get(f"/document/parts/{part['id']}/features").json()
    mirror_entries = {f["id"]: f for f in features if f["type"] == "mirror"}
    assert created["id"] in mirror_entries
    assert mirror_entries[created["id"]]["source_body_ids"] == [body_id]


# --- Rejections ------------------------------------------------------------


def test_zero_source_body_ids_is_rejected():
    part, _body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [], _fixed_plane_ref("YZ"))
    assert response.status_code == 422


def test_two_source_body_ids_is_rejected_in_phase_1():
    part = _create_part()
    sketch_a = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    _create_extrude_feature(part["id"], sketch_a["id"])
    sketch_b = _create_square_sketch_feature(part["id"], x0=100.0, y0=100.0)
    _create_extrude_feature(part["id"], sketch_b["id"])
    body_id_a, body_id_b = _body_ids(part["id"])

    response = _create_mirror(part["id"], [body_id_a, body_id_b], _fixed_plane_ref("YZ"))
    assert response.status_code == 422


def test_an_unknown_source_body_id_is_rejected():
    part, _body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], ["no-such-body"], _fixed_plane_ref("YZ"))
    assert response.status_code == 400


def test_mirror_plane_with_no_fields_set_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(
        part["id"], [body_id], {"face_ref": None, "fixed_plane": None, "plane_feature_id": None}
    )
    assert response.status_code == 422


def test_mirror_plane_with_two_fields_set_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(
        part["id"],
        [body_id],
        {"face_ref": {"body_id": body_id, "shape_type": "face", "index": 0}, "fixed_plane": "XY",
         "plane_feature_id": None},
    )
    assert response.status_code == 422


def test_mirror_plane_face_ref_must_have_shape_type_face():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(
        part["id"],
        [body_id],
        {"face_ref": {"body_id": body_id, "shape_type": "edge", "index": 0}, "fixed_plane": None,
         "plane_feature_id": None},
    )
    assert response.status_code == 422


def test_mirror_plane_with_unknown_plane_feature_id_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [body_id], _create_plane_feature_ref("no-such-plane"))
    assert response.status_code == 400


def test_mirror_plane_face_ref_with_unknown_body_is_a_missing_reference():
    part, body_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [body_id], _face_plane_ref("no-such-body", 0))
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


# --- Editing / rollback ------------------------------------------------------


def test_patch_updates_the_mirror_plane_and_the_mesh_reflects_it():
    part, body_id = _boxy_part_and_body()
    created = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ")).json()
    mirrored_body_id_before = next(bid for bid in _body_ids(part["id"]) if bid != body_id)
    mesh_before = next(e for e in _mesh(part["id"]) if e["body_id"] == mirrored_body_id_before)["mesh"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/mirror-features/{created['id']}",
        json={"mirror_plane": _fixed_plane_ref("XZ")},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["mirror_plane"]["fixed_plane"] == "XZ"

    mirrored_body_id_after = next(bid for bid in _body_ids(part["id"]) if bid != body_id)
    mesh_after = next(e for e in _mesh(part["id"]) if e["body_id"] == mirrored_body_id_after)["mesh"]
    assert mesh_after["vertices"] != mesh_before["vertices"]


def test_patch_re_validates_the_merged_candidate_and_rejects_an_invalid_plane():
    part, body_id = _boxy_part_and_body()
    created = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ")).json()

    patch_response = client.patch(
        f"/document/parts/{part['id']}/mirror-features/{created['id']}",
        json={"mirror_plane": _create_plane_feature_ref("no-such-plane")},
    )
    assert patch_response.status_code == 400

    # A rejected PATCH must never leave the Feature half-updated.
    features = client.get(f"/document/parts/{part['id']}/features").json()
    mirror_entry = next(f for f in features if f["id"] == created["id"])
    assert mirror_entry["mirror_plane"]["fixed_plane"] == "YZ"


def test_patch_can_edit_an_earlier_mirror_via_rollback_style_editing():
    """B4: any Feature can be edited, not just the last one - editing this
    Mirror's plane after a later, unrelated Feature has been added must
    still resolve correctly."""
    part, body_id = _boxy_part_and_body()
    created = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ")).json()

    other_sketch = _create_square_sketch_feature(part["id"], x0=100.0, y0=100.0)
    _create_extrude_feature(part["id"], other_sketch["id"])

    patch_response = client.patch(
        f"/document/parts/{part['id']}/mirror-features/{created['id']}",
        json={"mirror_plane": _fixed_plane_ref("XZ")},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["mirror_plane"]["fixed_plane"] == "XZ"


# --- Cascade delete ------------------------------------------------------------


def test_cascade_deleting_the_owning_extrude_takes_the_mirror_with_it():
    part, body_id = _boxy_part_and_body()
    extrude_feature_id = body_id
    mirror = _create_mirror(part["id"], [body_id], _fixed_plane_ref("YZ")).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{extrude_feature_id}/cascade")
    assert response.status_code == 200
    assert mirror["id"] in response.json()["deleted_feature_ids"]

    features = client.get(f"/document/parts/{part['id']}/features").json()
    assert all(f["id"] != mirror["id"] for f in features)


def test_cascade_deleting_the_referenced_create_plane_feature_takes_the_mirror_with_it():
    part, body_id = _boxy_part_and_body()
    plane_feature = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [_fixed_plane_ref("XY")],
            "offset": 5.0,
        },
    ).json()
    mirror = _create_mirror(part["id"], [body_id], _create_plane_feature_ref(plane_feature["id"])).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{plane_feature['id']}/cascade")
    assert response.status_code == 200
    assert mirror["id"] in response.json()["deleted_feature_ids"]
