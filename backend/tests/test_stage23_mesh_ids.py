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


def _get_bodies(part_id: str, hidden_feature_ids: list[str] | None = None) -> list[dict]:
    response = client.get(
        f"/document/parts/{part_id}/mesh",
        params={"hidden_feature_ids": hidden_feature_ids} if hidden_feature_ids else None,
    )
    assert response.status_code == 200
    return response.json()


def _boss_box_mesh(part_id: str) -> dict:
    """A1: still returns exactly one Body dict, same as before this stage's
    array-wrapping - every call site below reads `mesh["mesh"]` from it
    exactly as it did when GET /mesh returned one combined object."""
    sketch_feature = _create_square_sketch_feature(part_id)
    _create_extrude_feature(part_id, sketch_feature["id"])
    bodies = _get_bodies(part_id)
    assert len(bodies) == 1
    return bodies[0]


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

    bodies = _get_bodies(part["id"])

    assert len(bodies) == 1
    mesh = bodies[0]["mesh"]
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

    bodies = _get_bodies(part["id"])

    assert len(bodies) == 1
    mesh = bodies[0]["mesh"]
    assert len(mesh["topology_vertices"]) == 8
    assert mesh["topology_vertex_ids"] == list(range(8))


# --- empty computed mesh -------------------------------------------------------


def test_body_with_a_skipped_cut_and_no_other_geometry_is_absent_from_the_array():
    """A1: replaces the old "empty computed mesh has empty ids" test - a
    Cut can no longer be created with nothing to name in target_body_ids
    (see test_stage_a1_multibody.py's 422 test), so "nothing computed yet"
    is represented by an empty array rather than a single Body entry with
    empty id lists. This reproduces the equivalent "nothing to show" state
    via a Cut whose target Body is hidden away at recompute time."""
    part = _create_part()
    boss_sketch = _create_square_sketch_feature(part["id"])
    boss = _create_extrude_feature(part["id"], boss_sketch["id"], extrude_type="boss")
    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[boss["id"]]
    )

    bodies = _get_bodies(part["id"], hidden_feature_ids=[boss["id"]])

    assert bodies == []
