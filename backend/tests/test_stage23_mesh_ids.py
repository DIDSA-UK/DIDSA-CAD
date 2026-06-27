from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers (mirrors test_stage11_edges.py) --------------------------------


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
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
        },
    )
    assert response.status_code == 201
    return response.json()


def _boss_box_mesh(part_id: str) -> dict:
    sketch_feature = _create_square_sketch_feature(part_id)
    _create_extrude_feature(part_id, sketch_feature["id"])
    return client.get(f"/document/parts/{part_id}/mesh").json()


# --- face_ids ----------------------------------------------------------------


def test_box_extrude_face_ids_parallel_triangle_indices():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])["mesh"]

    assert len(mesh["face_ids"]) == len(mesh["triangle_indices"])


def test_box_extrude_has_six_distinct_face_ids():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])["mesh"]

    # A box has 6 faces, each tessellated as 2 triangles sharing one face id.
    assert set(mesh["face_ids"]) == {0, 1, 2, 3, 4, 5}


def test_placeholder_mesh_also_includes_face_ids():
    part = _create_part()

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    mesh = response.json()["mesh"]
    assert len(mesh["face_ids"]) == len(mesh["triangle_indices"])
    assert len(mesh["face_ids"]) > 0


# --- edge_ids ----------------------------------------------------------------


def test_box_extrude_edge_ids_parallel_edge_segments():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])["mesh"]

    assert len(mesh["edge_ids"]) == len(mesh["edges"]) // 6


def test_box_extrude_has_twelve_distinct_edge_ids():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])["mesh"]

    # A box's 12 edges are all straight, so each one is exactly one segment
    # and gets exactly one (distinct) edge id.
    assert set(mesh["edge_ids"]) == set(range(12))


# --- topology_vertices / topology_vertex_ids ---------------------------------


def test_box_extrude_has_eight_topology_vertices():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])["mesh"]

    assert len(mesh["topology_vertices"]) == 8
    assert mesh["topology_vertex_ids"] == list(range(8))


def test_box_extrude_topology_vertices_are_a_subset_of_mesh_vertex_positions():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])["mesh"]

    vertex_positions = {tuple(v) for v in mesh["vertices"]}
    for topology_vertex in mesh["topology_vertices"]:
        assert tuple(topology_vertex) in vertex_positions


def test_placeholder_mesh_also_includes_topology_vertices():
    part = _create_part()

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    mesh = response.json()["mesh"]
    assert len(mesh["topology_vertices"]) == 8
    assert mesh["topology_vertex_ids"] == list(range(8))


# --- empty computed mesh -------------------------------------------------------


def test_empty_computed_mesh_has_empty_ids():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"], extrude_type="cut")

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    mesh = response.json()["mesh"]
    assert mesh["face_ids"] == []
    assert mesh["edge_ids"] == []
    assert mesh["topology_vertices"] == []
    assert mesh["topology_vertex_ids"] == []
