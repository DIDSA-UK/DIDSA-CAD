import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Line, Plane, Point, Sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_line_set_length_preserves_direction():
    points = {"a": Point(id="a", x=0.0, y=0.0), "b": Point(id="b", x=3.0, y=4.0)}
    line = Line(id="l", start_point_id="a", end_point_id="b")
    assert line.length(points) == pytest.approx(5.0)

    line.set_length(points, 10.0)

    assert points["a"].x == pytest.approx(0.0)
    assert points["a"].y == pytest.approx(0.0)
    assert points["b"].x == pytest.approx(6.0)
    assert points["b"].y == pytest.approx(8.0)
    assert line.length(points) == pytest.approx(10.0)


def test_line_set_length_on_zero_length_line_raises():
    points = {"a": Point(id="a", x=1.0, y=1.0), "b": Point(id="b", x=1.0, y=1.0)}
    line = Line(id="l", start_point_id="a", end_point_id="b")
    with pytest.raises(ValueError):
        line.set_length(points, 5.0)


def test_sketch_add_line_rejects_same_start_and_end_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    point = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_line(point.id, point.id)


def test_moving_a_shared_point_updates_every_line_referencing_it():
    """Two Lines sharing an end Point (a connected corner) both move when
    that Point moves, since they reference the same Point object."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)

    line_ab = sketch.add_line(a.id, b.id)
    line_bc = sketch.add_line(b.id, c.id)

    sketch.points[b.id].x = 20.0
    sketch.points[b.id].y = 5.0

    assert line_ab.length(sketch.points) == pytest.approx((20.0**2 + 5.0**2) ** 0.5)
    assert line_bc.length(sketch.points) == pytest.approx(((20.0 - 10.0) ** 2 + (5.0 - 10.0) ** 2) ** 0.5)


def test_setting_length_on_a_shared_point_moves_dependent_line_too():
    """Setting line_ab's length moves Point b, which line_bc also
    references - line_bc's length changes too even though only line_ab
    was edited directly."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)

    line_ab = sketch.add_line(a.id, b.id)
    line_bc = sketch.add_line(b.id, c.id)

    line_ab.set_length(sketch.points, 20.0)

    assert sketch.points[b.id].x == pytest.approx(20.0)
    assert sketch.points[b.id].y == pytest.approx(0.0)
    assert line_bc.length(sketch.points) == pytest.approx(((20.0 - 10.0) ** 2 + 10.0**2) ** 0.5)


def test_sketches_do_not_share_points_or_entities():
    sketch_one = Sketch(id="s1", plane=Plane.XY)
    sketch_two = Sketch(id="s2", plane=Plane.XY)

    sketch_one.add_point(0.0, 0.0)

    assert sketch_one.points
    assert not sketch_two.points


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_sketch_assigns_plane():
    sketch = _create_sketch("XZ")
    assert sketch["plane"] == "XZ"
    assert "id" in sketch


def test_create_sketch_rejects_invalid_plane():
    response = client.post("/sketch/sketches", json={"plane": "NOT_A_PLANE"})
    assert response.status_code == 422


def test_get_sketch_round_trip():
    created = _create_sketch("YZ")
    response = client.get(f"/sketch/sketches/{created['id']}")
    assert response.status_code == 200
    assert response.json() == created


def test_get_sketch_not_found():
    response = client.get("/sketch/sketches/does-not-exist")
    assert response.status_code == 404


def test_create_and_get_point():
    sketch = _create_sketch()
    point = _create_point(sketch["id"], 3.0, 4.0)
    assert point["x"] == pytest.approx(3.0)
    assert point["y"] == pytest.approx(4.0)

    response = client.get(f"/sketch/sketches/{sketch['id']}/points/{point['id']}")
    assert response.status_code == 200
    assert response.json() == point


def test_get_point_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/points/does-not-exist")
    assert response.status_code == 404


def test_update_point_moves_it():
    sketch = _create_sketch()
    point = _create_point(sketch["id"], 0.0, 0.0)

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/points/{point['id']}", json={"x": 5.0, "y": -2.0}
    )

    assert response.status_code == 200
    body = response.json()
    assert body["x"] == pytest.approx(5.0)
    assert body["y"] == pytest.approx(-2.0)


def test_create_line_from_two_existing_points():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["start_point_id"] == a["id"]
    assert body["end_point_id"] == b["id"]
    assert body["length"] == pytest.approx(5.0)
    assert body["type"] == "line"


def test_create_line_from_length_and_angle_creates_new_end_point():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 1.0, 1.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "length": 10, "angle": 0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["start_point_id"] == a["id"]
    assert body["length"] == pytest.approx(10.0)

    end_point = client.get(f"/sketch/sketches/{sketch['id']}/points/{body['end_point_id']}").json()
    assert end_point["x"] == pytest.approx(11.0)
    assert end_point["y"] == pytest.approx(1.0)


def test_create_line_requires_end_point_or_length_and_angle():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines", json={"start_point_id": a["id"]}
    )
    assert response.status_code == 422


def test_create_line_rejects_both_end_point_and_length():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 1.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"], "length": 5, "angle": 0},
    )
    assert response.status_code == 422


def test_create_line_with_unknown_start_point_is_404():
    sketch = _create_sketch()
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": "does-not-exist", "length": 5, "angle": 0},
    )
    assert response.status_code == 404


def test_create_line_with_unknown_end_point_is_404():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": "does-not-exist"},
    )
    assert response.status_code == 404


def test_create_line_rejects_same_start_and_end_point():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": a["id"]},
    )
    assert response.status_code == 400


def test_two_lines_can_explicitly_share_a_point():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 10.0, 10.0)

    line_ab = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()
    line_bc = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": b["id"], "end_point_id": c["id"]},
    ).json()

    assert line_ab["end_point_id"] == line_bc["start_point_id"] == b["id"]


def test_lines_with_coincident_but_distinct_points_are_not_merged():
    """Two Points with identical coordinates but different ids remain
    separate and unrelated - no tolerance-based auto-merge."""
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 5.0, 5.0)
    b = _create_point(sketch["id"], 5.0, 5.0)
    assert a["id"] != b["id"]

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    )
    assert response.status_code == 201
    assert response.json()["length"] == pytest.approx(0.0)


def test_get_line_round_trip():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 6.0, 8.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/lines/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_line_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/lines/does-not-exist")
    assert response.status_code == 404


def test_update_line_length_moves_end_point():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)
    line = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()

    response = client.patch(f"/sketch/sketches/{sketch['id']}/lines/{line['id']}", json={"length": 15})

    assert response.status_code == 200
    body = response.json()
    assert body["length"] == pytest.approx(15.0)

    moved_end = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    assert moved_end["x"] == pytest.approx(9.0)
    assert moved_end["y"] == pytest.approx(12.0)


def test_update_line_length_moves_shared_point_and_affects_other_line():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 10.0, 10.0)

    line_ab = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()
    line_bc = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": b["id"], "end_point_id": c["id"]},
    ).json()

    client.patch(f"/sketch/sketches/{sketch['id']}/lines/{line_ab['id']}", json={"length": 20})

    updated_bc = client.get(f"/sketch/sketches/{sketch['id']}/lines/{line_bc['id']}").json()
    # b moved from (10, 0) to (20, 0); line_bc now runs from (20, 0) to (10, 10).
    assert updated_bc["length"] == pytest.approx(((20.0 - 10.0) ** 2 + 10.0**2) ** 0.5)


def test_update_zero_length_line_with_length_is_rejected():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 2.0, 2.0)
    b = _create_point(sketch["id"], 2.0, 2.0)
    line = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()

    response = client.patch(f"/sketch/sketches/{sketch['id']}/lines/{line['id']}", json={"length": 5})

    assert response.status_code == 400


def test_update_line_requires_length():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 1.0)
    line = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()

    response = client.patch(f"/sketch/sketches/{sketch['id']}/lines/{line['id']}", json={})

    assert response.status_code == 422


def test_multiple_sketches_do_not_interfere_over_the_api():
    sketch_one = _create_sketch("XY")
    sketch_two = _create_sketch("XZ")

    point_one = _create_point(sketch_one["id"], 1.0, 1.0)

    response = client.get(f"/sketch/sketches/{sketch_two['id']}/points/{point_one['id']}")
    assert response.status_code == 404
