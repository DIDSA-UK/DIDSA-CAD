"""C4: real-OCCT tests for Create Plane's three new plane-construction
methods - NORMAL_TO_EDGE_THROUGH_VERTEX, PARALLEL_TO_FACE_THROUGH_VERTEX,
THREE_POINTS - over the real HTTP API, mirroring test_stage_c2_create_
plane.py's exact structure/helpers (brute-force-the-index-mapping style,
since face/edge/vertex-index-to-topological-feature correspondence isn't
part of this API's contract, only "some matching sub-shape exists" is).

Needs a real pythonocc-core environment (not available in this sandbox -
see the recurring caveat in docs/status.md) since `app.main` imports OCC
directly - `ast.parse`-verified/manually reviewed only here, same as every
other OCCT-touching backend prompt in this project until real CI runs it.
"""

import itertools

import pytest
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


def _create_circle_sketch_feature(part_id: str, *, radius: float = 10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    center = client.post(f"/sketch/sketches/{feature['sketch_id']}/points", json={"x": 0.0, "y": 0.0}).json()
    response = client.post(
        f"/sketch/sketches/{feature['sketch_id']}/circles",
        json={"center_point_id": center["id"], "radius": radius, "angle": 0.0},
    )
    assert response.status_code == 201
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


def _first_body_id(part_id: str) -> str:
    mesh = client.get(f"/document/parts/{part_id}/mesh").json()
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _boxy_part_and_body() -> tuple[dict, str]:
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    return part, _first_body_id(part["id"])


def _create_normal_to_edge_plane(part_id: str, body_id: str, edge_index: int, vertex_index: int):
    return client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={
            "plane_type": "normal_to_edge_through_vertex",
            "edge_ref": {"body_id": body_id, "shape_type": "edge", "index": edge_index},
            "vertex_ref": {"body_id": body_id, "shape_type": "vertex", "index": vertex_index},
        },
    )


def _first_successful_normal_to_edge_plane(part_id: str, body_id: str) -> dict:
    """A box has 12 straight edges and 8 vertices, none of which need to be
    incident to each other for this plane type (the vertex only supplies the
    origin, the edge only supplies the direction) - brute-forces index pairs
    the same way test_stage_c2_create_plane.py's own face-index brute force
    does, since exact index-to-topological-feature correspondence isn't part
    of this API's contract."""
    for edge_index, vertex_index in itertools.product(range(12), range(8)):
        response = _create_normal_to_edge_plane(part_id, body_id, edge_index, vertex_index)
        if response.status_code == 201:
            return response.json()
    raise AssertionError("expected at least one resolvable edge+vertex pair on a box")


def _create_parallel_to_face_plane(part_id: str, body_id: str, face_index: int, vertex_index: int):
    return client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={
            "plane_type": "parallel_to_face_through_vertex",
            "face_refs": [{"body_id": body_id, "shape_type": "face", "index": face_index}],
            "vertex_ref": {"body_id": body_id, "shape_type": "vertex", "index": vertex_index},
        },
    )


def _first_successful_parallel_to_face_plane(part_id: str, body_id: str) -> dict:
    for face_index, vertex_index in itertools.product(range(6), range(8)):
        response = _create_parallel_to_face_plane(part_id, body_id, face_index, vertex_index)
        if response.status_code == 201:
            return response.json()
    raise AssertionError("expected at least one resolvable face+vertex pair on a box")


def _vertex_point_ref(body_id: str, index: int) -> dict:
    return {"vertex_ref": {"body_id": body_id, "shape_type": "vertex", "index": index}}


def _sketch_point_ref(sketch_id: str, point_id: str) -> dict:
    return {"sketch_point_ref": {"sketch_id": sketch_id, "entity_type": "point", "entity_id": point_id}}


def _create_three_points_plane(part_id: str, point_refs: list[dict]):
    return client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={"plane_type": "three_points", "point_refs": point_refs},
    )


def _first_successful_three_vertex_plane(part_id: str, body_id: str) -> tuple[dict, tuple[int, int, int]]:
    """Any 3 of a box's 8 distinct vertices are non-collinear (a box has no 3
    vertices lying on a common straight line - each of its 12 edges has only
    2 endpoints, and no edge extended passes through a third vertex), so this
    should succeed on the very first combination tried; loops anyway for the
    same "don't assume index correspondence" reason every other helper here
    does."""
    for combo in itertools.combinations(range(8), 3):
        point_refs = [_vertex_point_ref(body_id, i) for i in combo]
        response = _create_three_points_plane(part_id, point_refs)
        if response.status_code == 201:
            return response.json(), combo
    raise AssertionError("expected at least one non-collinear vertex triple on a box")


# --- NORMAL_TO_EDGE_THROUGH_VERTEX --------------------------------------------


def test_normal_to_edge_through_vertex_against_a_real_box_succeeds():
    part, body_id = _boxy_part_and_body()
    body = _first_successful_normal_to_edge_plane(part["id"], body_id)
    assert body["plane_type"] == "normal_to_edge_through_vertex"
    assert body["origin"] is not None
    assert body["normal"] is not None
    assert body["produces"] == "plane"


def test_normal_to_edge_through_vertex_against_a_curved_edge_is_rejected():
    part = _create_part()
    sketch_feature = _create_circle_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])

    # A cylinder has 2 circular (curved) edges and up to 1 straight seam edge
    # depending on OCCT's own tessellation of the lateral surface - try every
    # edge/vertex index pair (a cylinder's own vertex count/indexing isn't
    # part of this API's contract either) and expect at least one non_linear_
    # edge rejection among the results.
    results = [
        _create_normal_to_edge_plane(part["id"], body_id, edge_index, vertex_index)
        for edge_index, vertex_index in itertools.product(range(6), range(4))
    ]
    non_linear = [
        r for r in results if r.status_code == 422 and r.json()["detail"]["type"] == "non_linear_edge"
    ]
    assert non_linear, "expected at least one curved edge rejected as non_linear_edge"


def test_normal_to_edge_through_vertex_against_an_unknown_body_is_a_missing_reference():
    part = _create_part()
    response = _create_normal_to_edge_plane(part["id"], "no-such-body", 0, 0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


def test_normal_to_edge_through_vertex_payload_missing_vertex_ref_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "normal_to_edge_through_vertex",
            "edge_ref": {"body_id": body_id, "shape_type": "edge", "index": 0},
        },
    )
    assert response.status_code == 422


def test_normal_to_edge_through_vertex_rejects_a_face_ref_masquerading_as_edge_ref():
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "normal_to_edge_through_vertex",
            "edge_ref": {"body_id": body_id, "shape_type": "face", "index": 0},
            "vertex_ref": {"body_id": body_id, "shape_type": "vertex", "index": 0},
        },
    )
    assert response.status_code == 422


# --- PARALLEL_TO_FACE_THROUGH_VERTEX -------------------------------------------


def test_parallel_to_face_through_vertex_against_a_real_box_succeeds():
    part, body_id = _boxy_part_and_body()
    body = _first_successful_parallel_to_face_plane(part["id"], body_id)
    assert body["plane_type"] == "parallel_to_face_through_vertex"
    assert body["origin"] is not None
    assert body["normal"] is not None
    assert body["x_axis"] is not None
    assert body["y_axis"] is not None
    assert body["produces"] == "plane"


def test_parallel_to_face_through_vertex_origin_is_the_referenced_vertex():
    part, body_id = _boxy_part_and_body()
    body = _first_successful_parallel_to_face_plane(part["id"], body_id)

    # The vertex used lies on the plane by construction (see create_plane.
    # resolve_parallel_face_through_vertex_from_bodies's own docstring) - the
    # topology_vertices exposed by the mesh give us real vertex world
    # positions to cross-check the returned origin against.
    mesh = client.get(f"/document/parts/{part['id']}/mesh").json()
    vertex_positions = [tuple(v) for m in mesh for v in m["mesh"]["topology_vertices"]]
    assert any(pytest.approx(body["origin"]) == pos for pos in vertex_positions)


def test_parallel_to_face_through_vertex_against_a_curved_face_is_rejected():
    part = _create_part()
    sketch_feature = _create_circle_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    body_id = _first_body_id(part["id"])

    results = [_create_parallel_to_face_plane(part["id"], body_id, i, 0) for i in range(3)]
    statuses = [r.status_code for r in results]
    assert 201 in statuses, "expected at least one planar face (top/bottom cap)"
    assert 422 in statuses, "expected the curved lateral face rejected as non-planar"
    rejected = next(r for r in results if r.status_code == 422)
    assert rejected.json()["detail"]["type"] == "non_planar_reference"


def test_parallel_to_face_through_vertex_payload_missing_face_refs_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "parallel_to_face_through_vertex",
            "vertex_ref": {"body_id": body_id, "shape_type": "vertex", "index": 0},
        },
    )
    assert response.status_code == 422


# --- THREE_POINTS --------------------------------------------------------------


def test_three_points_from_body_vertices_succeeds():
    part, body_id = _boxy_part_and_body()
    body, _combo = _first_successful_three_vertex_plane(part["id"], body_id)
    assert body["plane_type"] == "three_points"
    assert body["origin"] is not None
    assert body["normal"] is not None
    assert body["produces"] == "plane"


def test_three_points_mixing_a_body_vertex_and_sketch_points_succeeds():
    part, body_id = _boxy_part_and_body()
    plane_sketch = _create_sketch_feature(part["id"], plane="XZ")
    sketch_id = plane_sketch["sketch_id"]
    p1 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 1.0, "y": 0.0}).json()
    p2 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 1.0}).json()

    point_refs = [
        _vertex_point_ref(body_id, 0),
        _sketch_point_ref(sketch_id, p1["id"]),
        _sketch_point_ref(sketch_id, p2["id"]),
    ]
    response = _create_three_points_plane(part["id"], point_refs)
    assert response.status_code == 201
    body = response.json()
    assert body["plane_type"] == "three_points"
    length = sum(c * c for c in body["normal"]) ** 0.5
    assert length == pytest.approx(1.0)


def test_three_collinear_sketch_points_are_rejected():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    p0 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()
    p1 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 1.0, "y": 0.0}).json()
    p2 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 2.0, "y": 0.0}).json()

    point_refs = [_sketch_point_ref(sketch_id, p["id"]) for p in (p0, p1, p2)]
    response = _create_three_points_plane(part["id"], point_refs)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "collinear_points"


def test_three_points_payload_with_only_two_entries_is_rejected():
    part, body_id = _boxy_part_and_body()
    point_refs = [_vertex_point_ref(body_id, 0), _vertex_point_ref(body_id, 1)]
    response = _create_three_points_plane(part["id"], point_refs)
    assert response.status_code == 422


def test_three_points_entry_with_both_vertex_ref_and_sketch_point_ref_is_rejected():
    part, body_id = _boxy_part_and_body()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    p0 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()

    point_refs = [
        {**_vertex_point_ref(body_id, 0), **_sketch_point_ref(sketch_id, p0["id"])},
        _vertex_point_ref(body_id, 1),
        _vertex_point_ref(body_id, 2),
    ]
    response = _create_three_points_plane(part["id"], point_refs)
    assert response.status_code == 422


def test_three_points_entry_with_neither_ref_is_rejected():
    part, body_id = _boxy_part_and_body()
    point_refs = [{}, _vertex_point_ref(body_id, 0), _vertex_point_ref(body_id, 1)]
    response = _create_three_points_plane(part["id"], point_refs)
    assert response.status_code == 422


def test_three_points_against_an_unknown_body_vertex_is_a_missing_reference():
    part, body_id = _boxy_part_and_body()
    point_refs = [
        {"vertex_ref": {"body_id": "no-such-body", "shape_type": "vertex", "index": 0}},
        _vertex_point_ref(body_id, 0),
        _vertex_point_ref(body_id, 1),
    ]
    response = _create_three_points_plane(part["id"], point_refs)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


# --- Editing, listing (spot-check across the 3 new types) ---------------------


def test_patch_updates_a_three_points_planes_vertex_and_the_response_reflects_it():
    part, body_id = _boxy_part_and_body()
    created, combo = _first_successful_three_vertex_plane(part["id"], body_id)
    other_index = next(i for i in range(8) if i not in combo)

    patch_response = client.patch(
        f"/document/parts/{part['id']}/create-plane-features/{created['id']}",
        json={"point_refs": [_vertex_point_ref(body_id, other_index), *[_vertex_point_ref(body_id, i) for i in combo[1:]]]},
    )
    assert patch_response.status_code == 200
    updated = patch_response.json()
    assert updated["origin"] != created["origin"] or updated["normal"] != created["normal"]


def test_list_features_includes_the_three_new_plane_types_with_resolved_geometry():
    part, body_id = _boxy_part_and_body()
    edge_plane = _first_successful_normal_to_edge_plane(part["id"], body_id)
    face_plane = _first_successful_parallel_to_face_plane(part["id"], body_id)
    points_plane, _combo = _first_successful_three_vertex_plane(part["id"], body_id)

    features = client.get(f"/document/parts/{part['id']}/features").json()
    plane_entries = {f["id"]: f for f in features if f["type"] == "create_plane"}
    for created in (edge_plane, face_plane, points_plane):
        assert created["id"] in plane_entries
        assert plane_entries[created["id"]]["origin"] is not None
