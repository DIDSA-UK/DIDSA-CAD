"""On-device feedback ("when offsetting an edge, a line or curve is created
on the edge - these lines should be construction"): `convert_body_edge`'s
`construction` payload field (default `False`, unchanged Convert Entities
behavior) threaded through to whichever of Line/Arc/Circle it resolves -
`SketchController.pickBodyEdgeForOffset` is the one real caller that ever
passes `True`, since that seed is only ever a reference for the offset
distance to measure from, never its own profile boundary."""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201, response.text
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201, response.text
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201, response.text
    return response.json()


def _add_line(sketch_id: str, p1: str, p2: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": p1, "end_point_id": p2}
    )
    assert response.status_code == 201, response.text
    return response.json()


def _add_circle(sketch_id: str, cx: float, cy: float, radius: float) -> dict:
    center = _add_point(sketch_id, cx, cy)
    response = client.post(
        f"/sketch/sketches/{sketch_id}/circles", json={"center_point_id": center["id"], "radius": radius}
    )
    assert response.status_code == 201, response.text
    return response.json()


def _extrude(part_id: str, sketch_feature_id: str, end_distance: float = 10.0) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": end_distance,
            "target_body_ids": [],
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _get_mesh(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200, response.text
    return response.json()


def _convert_edge(part_id: str, feature_id: str, body_id: str, edge_index: int, **kwargs):
    payload = {"body_id": body_id, "edge_index": edge_index, **kwargs}
    return client.post(
        f"/document/parts/{part_id}/features/sketch/{feature_id}/convert-entities/edge", json=payload
    )


def _square_body() -> tuple[dict, dict, str]:
    """A plain extruded square - part, its sketch feature to convert edges
    onto, and the resulting Body's id."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    corners = [_add_point(sketch_id, x, y) for x, y in [(0, 0), (10, 0), (10, 10), (0, 10)]]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])
    _extrude(part["id"], sketch_feature["id"])
    body = _get_mesh(part["id"])[0]
    new_feature = _create_sketch_feature(part["id"])
    return part, new_feature, body["body_id"]


def test_convert_body_edge_defaults_to_non_construction_line():
    part, feature, body_id = _square_body()

    response = _convert_edge(part["id"], feature["id"], body_id, 0)

    assert response.status_code == 201, response.text
    data = response.json()
    assert data["line"] is not None
    assert data["line"]["construction"] is False


def test_convert_body_edge_construction_true_creates_a_construction_line():
    part, feature, body_id = _square_body()

    response = _convert_edge(part["id"], feature["id"], body_id, 0, construction=True)

    assert response.status_code == 201, response.text
    data = response.json()
    assert data["line"] is not None
    assert data["line"]["construction"] is True


def test_convert_body_edge_construction_true_creates_a_construction_circle():
    """A full circular Body edge (e.g. a cylinder's rim) resolves as a
    Circle instead of a Line - the same `construction` flag must still
    reach it, not just the Line branch."""
    part = _create_part("CircleBody")
    sketch_feature = _create_sketch_feature(part["id"])
    _add_circle(sketch_feature["sketch_id"], 0.0, 0.0, 5.0)
    _extrude(part["id"], sketch_feature["id"])
    body = _get_mesh(part["id"])[0]
    top_edge_ids = body["mesh"]["face_edge_ids"][
        max(range(len(body["mesh"]["face_edge_ids"])), key=lambda i: len(body["mesh"]["face_edge_ids"][i]))
    ]
    new_feature = _create_sketch_feature(part["id"])

    response = None
    for edge_id in top_edge_ids:
        candidate = _convert_edge(part["id"], new_feature["id"], body["body_id"], edge_id, construction=True)
        if candidate.status_code == 201 and candidate.json().get("circle") is not None:
            response = candidate
            break

    assert response is not None, "expected at least one full circular edge to convert as a Circle"
    assert response.json()["circle"]["construction"] is True
