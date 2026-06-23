from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers (mirrors test_stage9_extrude.py) -----------------------------------


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


# --- edges field -----------------------------------------------------------------


def test_box_extrude_mesh_includes_a_non_empty_edges_field():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])

    assert mesh["source"] == "computed"
    assert len(mesh["mesh"]["edges"]) > 0


def test_box_extrude_returns_exactly_12_edges():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])

    edges = mesh["mesh"]["edges"]
    # Flat [x1,y1,z1, x2,y2,z2, ...] segments - a box's 12 edges are all
    # straight, so each one collapses to exactly one 6-float segment.
    assert len(edges) % 6 == 0
    assert len(edges) // 6 == 12


def test_edge_endpoints_are_consistent_with_mesh_vertex_positions():
    part = _create_part()

    mesh = _boss_box_mesh(part["id"])

    vertex_positions = {tuple(v) for v in mesh["mesh"]["vertices"]}
    edges = mesh["mesh"]["edges"]
    for i in range(0, len(edges), 6):
        start = (edges[i], edges[i + 1], edges[i + 2])
        end = (edges[i + 3], edges[i + 4], edges[i + 5])
        assert start in vertex_positions
        assert end in vertex_positions


def test_placeholder_mesh_also_includes_edges():
    part = _create_part()

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    body = response.json()
    assert body["source"] == "placeholder"
    assert len(body["mesh"]["edges"]) > 0


def test_empty_computed_mesh_has_empty_edges():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"], extrude_type="cut")

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    body = response.json()
    assert body["source"] == "computed"
    assert body["mesh"]["edges"] == []
