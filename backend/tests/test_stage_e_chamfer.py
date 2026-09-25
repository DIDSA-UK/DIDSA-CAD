"""Prompt E: real-OCCT tests for Chamfer's full router/HTTP surface - mirrors
test_stage_d_fillet.py exactly, substituting chamfer-features/distance for
fillet-features/radius and BRepFilletAPI_MakeChamfer's chamfer_failed for
fillet_failed. All touch `app.main`/`app.document.chamfer`/
`app.document.extrude`, which import OCC.Core directly, so (per the
recurring caveat in docs/status.md) these are `ast.parse`-verified/manually
reviewed only in this sandbox, same as every other OCCT-touching backend
prompt in this project until real CI runs it.
"""

import math

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_EDGE
from OCC.Core.TopExp import topexp
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.chamfer import _adjacent_face_indices, resolve_chamfer_from_bodies
from app.document.models import ChamferEdgeOptions, ChamferFeature, SubShapeRef, SubShapeType
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


# --- Feature 3: angle + flip (resolver-level, real OCCT) ---------------------
#
# Direct `resolve_chamfer_from_bodies` tests against a plain 10x10x10
# `BRepPrimAPI_MakeBox` so the expected volumes are exact closed-form
# numbers: chamfering one 10-long edge removes a right-triangle prism of
# legs `d` (along the reference face) and `d*tan(angle)` (along the other
# face) - 0.5 * d * d*tan(a) * 10.

_BOX_ID = "box"


def _box_bodies() -> dict:
    return {_BOX_ID: BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()}


def _edge(index: int = 0) -> SubShapeRef:
    return SubShapeRef(body_id=_BOX_ID, shape_type=SubShapeType.EDGE, index=index)


def _face(index: int, body_id: str = _BOX_ID) -> SubShapeRef:
    return SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=index)


def _props(shape) -> tuple[float, tuple[float, float, float]]:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    c = props.CentreOfMass()
    return props.Mass(), (c.X(), c.Y(), c.Z())


def _chamfer(edge_options: dict | None = None, distance: float = 2.0):
    feature = ChamferFeature(
        id="c", edge_refs=[_edge(0)], distance=distance, edge_options=edge_options or {}
    )
    body_id, shape = resolve_chamfer_from_bodies(_box_bodies(), feature)
    assert body_id == _BOX_ID
    return _props(shape)


def _box_edge_0_adjacent_faces() -> list[int]:
    bodies = _box_bodies()
    edges = TopTools_IndexedMapOfShape()
    topexp.MapShapes(bodies[_BOX_ID], TopAbs_EDGE, edges)
    return _adjacent_face_indices(bodies[_BOX_ID], edges.FindKey(1))


def test_a_box_edge_has_exactly_two_adjacent_faces_in_ascending_order():
    adjacent = _box_edge_0_adjacent_faces()
    assert len(adjacent) == 2
    assert adjacent == sorted(adjacent)


def test_no_edge_options_keeps_the_symmetric_distance_chamfer():
    volume, _ = _chamfer()
    assert volume == pytest.approx(1000.0 - 0.5 * 2.0 * 2.0 * 10.0)


def test_an_angle_option_uses_a_distance_angle_chamfer_with_angle_in_degrees():
    volume, _ = _chamfer({0: ChamferEdgeOptions(angle=30.0)})
    expected_removed = 0.5 * 2.0 * (2.0 * math.tan(math.radians(30.0))) * 10.0
    assert volume == pytest.approx(1000.0 - expected_removed)


def test_a_45_degree_angle_matches_the_symmetric_chamfer():
    symmetric_volume, symmetric_centroid = _chamfer()
    angled_volume, angled_centroid = _chamfer({0: ChamferEdgeOptions(angle=45.0)})
    assert angled_volume == pytest.approx(symmetric_volume)
    assert angled_centroid == pytest.approx(symmetric_centroid)


def test_an_edge_option_without_an_angle_is_the_symmetric_path():
    symmetric_volume, _ = _chamfer()
    volume, _ = _chamfer({0: ChamferEdgeOptions(flip=True)})
    assert volume == pytest.approx(symmetric_volume)


def test_flip_mirrors_the_angled_chamfer_across_the_edges_bisector():
    """Same removed volume, but the bevel's long leg moves to the other
    face - so the centroid is mirrored across the plane bisecting the two
    adjacent faces (for this box edge: its two in-plane coordinates swap)."""
    volume, centroid = _chamfer({0: ChamferEdgeOptions(angle=30.0)})
    flipped_volume, flipped_centroid = _chamfer({0: ChamferEdgeOptions(angle=30.0, flip=True)})
    assert flipped_volume == pytest.approx(volume)
    assert flipped_centroid != pytest.approx(centroid)
    assert sorted(flipped_centroid) == pytest.approx(sorted(centroid))


def test_an_explicit_face_ref_of_the_other_adjacent_face_matches_flip():
    first, second = _box_edge_0_adjacent_faces()
    _, flipped_centroid = _chamfer({0: ChamferEdgeOptions(angle=30.0, flip=True)})
    _, explicit_centroid = _chamfer({0: ChamferEdgeOptions(face_ref=_face(second), angle=30.0)})
    _, explicit_flipped_centroid = _chamfer(
        {0: ChamferEdgeOptions(face_ref=_face(second), angle=30.0, flip=True)}
    )
    _, default_centroid = _chamfer({0: ChamferEdgeOptions(angle=30.0)})
    assert explicit_centroid == pytest.approx(flipped_centroid)
    assert explicit_flipped_centroid == pytest.approx(default_centroid)
    assert first != second


def test_a_non_adjacent_face_ref_is_rejected():
    adjacent = set(_box_edge_0_adjacent_faces())
    non_adjacent = next(i for i in range(6) if i not in adjacent)
    with pytest.raises(HTTPException) as exc_info:
        _chamfer({0: ChamferEdgeOptions(face_ref=_face(non_adjacent), angle=30.0)})
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["type"] == "chamfer_face_not_adjacent"


def test_a_face_ref_on_another_body_is_a_mixed_body_selection():
    with pytest.raises(HTTPException) as exc_info:
        _chamfer({0: ChamferEdgeOptions(face_ref=_face(0, body_id="other"), angle=30.0)})
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["type"] == "mixed_body_selection"


def test_only_the_edges_with_options_are_angled():
    bodies = _box_bodies()
    both_symmetric = ChamferFeature(id="c", edge_refs=[_edge(0), _edge(2)], distance=2.0)
    one_angled = ChamferFeature(
        id="c",
        edge_refs=[_edge(0), _edge(2)],
        distance=2.0,
        edge_options={1: ChamferEdgeOptions(angle=30.0)},
    )
    symmetric_volume, _ = _props(resolve_chamfer_from_bodies(bodies, both_symmetric)[1])
    mixed_volume, _ = _props(resolve_chamfer_from_bodies(bodies, one_angled)[1])
    # Edge 0 stays symmetric (removes 20), edge 2 becomes a 30-degree bevel.
    angled_removed = 0.5 * 2.0 * (2.0 * math.tan(math.radians(30.0))) * 10.0
    assert symmetric_volume == pytest.approx(1000.0 - 40.0)
    assert mixed_volume == pytest.approx(1000.0 - 20.0 - angled_removed)


# --- Feature 3: angle + flip (router/HTTP) -----------------------------------


def _create_angled_chamfer(part_id: str, edge_refs: list[dict], distance: float, edge_options: dict):
    return client.post(
        f"/document/parts/{part_id}/chamfer-features",
        json={"edge_refs": edge_refs, "distance": distance, "edge_options": edge_options},
    )


def test_creating_an_angled_flipped_chamfer_round_trips_edge_options():
    part, body_id = _boxy_part_and_body()
    response = _create_angled_chamfer(
        part["id"], [_edge_ref(body_id, 0)], 1.0, {"0": {"angle": 30.0, "flip": True}}
    )
    assert response.status_code == 201
    options = response.json()["edge_options"]
    assert options == {"0": {"face_ref": None, "angle": 30.0, "flip": True}}

    features = client.get(f"/document/parts/{part['id']}/features").json()
    entry = next(f for f in features if f["id"] == response.json()["id"])
    assert entry["edge_options"] == options


def test_a_plain_chamfer_response_has_empty_edge_options():
    part, body_id = _boxy_part_and_body()
    response = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0)
    assert response.status_code == 201
    assert response.json()["edge_options"] == {}


def test_an_angled_chamfer_differs_from_the_symmetric_one_and_flip_changes_it_again():
    part, body_id = _boxy_part_and_body()
    created = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0).json()
    symmetric = _mesh(part["id"])[0]["mesh"]["vertices"]

    url = f"/document/parts/{part['id']}/chamfer-features/{created['id']}"
    assert client.patch(url, json={"edge_options": {"0": {"angle": 30.0}}}).status_code == 200
    angled = _mesh(part["id"])[0]["mesh"]["vertices"]
    assert client.patch(url, json={"edge_options": {"0": {"angle": 30.0, "flip": True}}}).status_code == 200
    flipped = _mesh(part["id"])[0]["mesh"]["vertices"]

    assert angled != symmetric
    assert flipped != angled


def test_patch_omitting_edge_options_keeps_them_and_an_empty_dict_clears_them():
    part, body_id = _boxy_part_and_body()
    created = _create_angled_chamfer(
        part["id"], [_edge_ref(body_id, 0)], 1.0, {"0": {"angle": 30.0}}
    ).json()
    url = f"/document/parts/{part['id']}/chamfer-features/{created['id']}"

    kept = client.patch(url, json={"distance": 1.5})
    assert kept.status_code == 200
    assert kept.json()["edge_options"] == {"0": {"face_ref": None, "angle": 30.0, "flip": False}}

    cleared = client.patch(url, json={"edge_options": {}})
    assert cleared.status_code == 200
    assert cleared.json()["edge_options"] == {}


@pytest.mark.parametrize("angle", [0.0, 180.0, -10.0, 200.0])
def test_an_out_of_range_angle_is_rejected(angle):
    part, body_id = _boxy_part_and_body()
    response = _create_angled_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0, {"0": {"angle": angle}})
    assert response.status_code == 400


def test_an_edge_options_key_outside_edge_refs_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_angled_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0, {"1": {"angle": 30.0}})
    assert response.status_code == 422


def test_an_edge_ref_masquerading_as_a_face_ref_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _create_angled_chamfer(
        part["id"],
        [_edge_ref(body_id, 0)],
        1.0,
        {"0": {"angle": 30.0, "face_ref": _edge_ref(body_id, 1)}},
    )
    assert response.status_code == 422


def test_patch_rejecting_bad_edge_options_leaves_the_feature_unchanged():
    part, body_id = _boxy_part_and_body()
    created = _create_chamfer(part["id"], [_edge_ref(body_id, 0)], 1.0).json()
    url = f"/document/parts/{part['id']}/chamfer-features/{created['id']}"
    assert client.patch(url, json={"edge_options": {"0": {"angle": 0.0}}}).status_code == 400
    features = client.get(f"/document/parts/{part['id']}/features").json()
    assert next(f for f in features if f["id"] == created["id"])["edge_options"] == {}
