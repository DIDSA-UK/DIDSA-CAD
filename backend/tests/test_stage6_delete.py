import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Plane, Sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_delete_line_removes_entity_but_not_its_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    line = sketch.add_line(a.id, b.id)

    sketch.delete_line(line.id)

    assert line.id not in sketch.entities
    assert a.id in sketch.points
    assert b.id in sketch.points


def test_delete_line_with_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_line("does-not-exist")


def test_delete_circle_removes_entity_and_its_radius_constraint_but_not_its_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    radius_point_id = circle.radius_point_id
    assert circle.radius_constraint_id in sketch.constraints

    sketch.delete_circle(circle.id)

    assert circle.id not in sketch.entities
    assert circle.radius_constraint_id not in sketch.constraints
    assert center.id in sketch.points
    assert radius_point_id in sketch.points


def test_delete_circle_with_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_circle("does-not-exist")


def test_delete_unreferenced_point_succeeds():
    sketch = Sketch(id="s", plane=Plane.XY)
    point = sketch.add_point(1.0, 1.0)

    sketch.delete_point(point.id)

    assert point.id not in sketch.points


def test_delete_point_with_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_point("does-not-exist")


def test_delete_point_still_referenced_by_a_line_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    sketch.add_line(a.id, b.id)

    with pytest.raises(ValueError):
        sketch.delete_point(a.id)
    assert a.id in sketch.points


def test_delete_point_still_referenced_by_a_circles_center_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    sketch.add_circle(center.id, radius=5.0, angle=0.0)

    with pytest.raises(ValueError):
        sketch.delete_point(center.id)


def test_delete_point_still_referenced_by_a_circles_radius_point_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    with pytest.raises(ValueError):
        sketch.delete_point(circle.radius_point_id)


def test_delete_point_referenced_by_a_distance_constraint_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(5.0, 0.0)
    sketch.add_distance_constraint(a.id, b.id, 5.0)

    with pytest.raises(ValueError):
        sketch.delete_point(a.id)
    with pytest.raises(ValueError):
        sketch.delete_point(b.id)


def test_delete_origin_point_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    origin = sketch.origin_point()

    with pytest.raises(ValueError):
        sketch.delete_point(origin.id)
    assert origin.id in sketch.points


def test_deleting_a_line_does_not_unblock_its_now_dangling_former_endpoint():
    """Deleting the Line that referenced a Point makes that Point
    deletable again - dependency-checking is live, not cached."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    line = sketch.add_line(a.id, b.id)

    sketch.delete_line(line.id)
    sketch.delete_point(a.id)

    assert a.id not in sketch.points


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_delete_line_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)
    line = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/lines/{line['id']}")

    assert response.status_code == 204
    assert client.get(f"/sketch/sketches/{sketch['id']}/lines/{line['id']}").status_code == 404
    # Endpoint points must survive the Line's deletion.
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").status_code == 200
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").status_code == 200


def test_delete_line_not_found_over_the_api():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/lines/does-not-exist")
    assert response.status_code == 404


def test_delete_circle_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    circle = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 5.0, "angle": 0.0},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/circles/{circle['id']}")

    assert response.status_code == 204
    assert client.get(f"/sketch/sketches/{sketch['id']}/circles/{circle['id']}").status_code == 404
    # The center point must survive the Circle's deletion.
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{center['id']}").status_code == 200


def test_delete_circle_not_found_over_the_api():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/circles/does-not-exist")
    assert response.status_code == 404


def test_delete_unreferenced_point_over_the_api():
    sketch = _create_sketch()
    point = _create_point(sketch["id"], 1.0, 1.0)

    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{point['id']}")

    assert response.status_code == 204
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{point['id']}").status_code == 404


def test_delete_point_not_found_over_the_api():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/does-not-exist")
    assert response.status_code == 404


def test_delete_point_referenced_by_a_line_is_rejected_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    )

    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{a['id']}")

    assert response.status_code == 400
    assert "line" in response.json()["detail"].lower()
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").status_code == 200


def test_delete_point_referenced_by_a_circle_is_rejected_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 5.0, "angle": 0.0},
    )

    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{center['id']}")

    assert response.status_code == 400
    assert "circle" in response.json()["detail"].lower()


def test_delete_point_referenced_by_a_constraint_is_rejected_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 5.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    )

    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{a['id']}")

    assert response.status_code == 400
    assert "constraint" in response.json()["detail"].lower()


def test_delete_origin_point_is_rejected_over_the_api():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{sketch['origin_point_id']}")

    assert response.status_code == 400
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{sketch['origin_point_id']}").status_code == 200
