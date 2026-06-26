import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_coincident_constraint_between_two_existing_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 10.0)

    constraint = sketch.add_coincident_constraint(a.id, b.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id)


def test_add_coincident_constraint_rejects_same_point_twice():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_coincident_constraint(a.id, a.id)


def test_add_coincident_constraint_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_coincident_constraint(a.id, "does-not-exist")


def test_coincident_constraint_forces_same_position_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(1.0, -2.0)
    sketch.add_coincident_constraint(a.id, b.id)

    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[a.id].x == pytest.approx(sketch.points[b.id].x)
    assert sketch.points[a.id].y == pytest.approx(sketch.points[b.id].y)


def test_add_parallel_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 5.0)
    d = sketch.add_point(10.0, 6.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_parallel_constraint(line1.id, line2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)


def test_add_parallel_constraint_rejects_same_line_twice():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    with pytest.raises(ValueError):
        sketch.add_parallel_constraint(line.id, line.id)


def test_parallel_constraint_forces_parallel_lines_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.5)
    c = sketch.add_point(2.0, 2.0)
    d = sketch.add_point(12.0, 3.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_parallel_constraint(line1.id, line2.id)

    result = solve_sketch(sketch)

    assert result.converged
    v1 = (sketch.points[b.id].x - sketch.points[a.id].x, sketch.points[b.id].y - sketch.points[a.id].y)
    v2 = (sketch.points[d.id].x - sketch.points[c.id].x, sketch.points[d.id].y - sketch.points[c.id].y)
    cross = v1[0] * v2[1] - v1[1] * v2[0]
    assert cross == pytest.approx(0.0, abs=1e-6)


def test_add_perpendicular_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 0.0)
    d = sketch.add_point(0.0, 10.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_perpendicular_constraint(line1.id, line2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)


def test_perpendicular_constraint_forces_right_angle_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(3.0, 3.0)
    d = sketch.add_point(5.0, 9.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_perpendicular_constraint(line1.id, line2.id)

    result = solve_sketch(sketch)

    assert result.converged
    v1 = (sketch.points[b.id].x - sketch.points[a.id].x, sketch.points[b.id].y - sketch.points[a.id].y)
    v2 = (sketch.points[d.id].x - sketch.points[c.id].x, sketch.points[d.id].y - sketch.points[c.id].y)
    dot = v1[0] * v2[0] + v1[1] * v2[1]
    assert dot == pytest.approx(0.0, abs=1e-6)


def test_add_equal_length_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 5.0)
    d = sketch.add_point(0.0, 8.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_equal_length_constraint(line1.id, line2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)


def test_equal_length_constraint_forces_same_length_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.5)
    c = sketch.add_point(2.0, 2.0)
    d = sketch.add_point(12.0, 3.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_equal_length_constraint(line1.id, line2.id)

    result = solve_sketch(sketch)

    assert result.converged
    length1 = line1.length(sketch.points)
    length2 = line2.length(sketch.points)
    assert length1 == pytest.approx(length2)


def test_add_collinear_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(2.0, 3.0)
    d = sketch.add_point(8.0, 3.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_collinear_constraint(line1.id, line2.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)


def test_collinear_constraint_forces_lines_onto_same_line_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(2.0, 3.0)
    d = sketch.add_point(8.0, 3.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_collinear_constraint(line1.id, line2.id)

    result = solve_sketch(sketch)

    assert result.converged
    v1 = (sketch.points[b.id].x - sketch.points[a.id].x, sketch.points[b.id].y - sketch.points[a.id].y)
    v2 = (sketch.points[c.id].x - sketch.points[a.id].x, sketch.points[c.id].y - sketch.points[a.id].y)
    v3 = (sketch.points[d.id].x - sketch.points[a.id].x, sketch.points[d.id].y - sketch.points[a.id].y)
    cross_c = v1[0] * v2[1] - v1[1] * v2[0]
    cross_d = v1[0] * v3[1] - v1[1] * v3[0]
    assert cross_c == pytest.approx(0.0, abs=1e-6)
    assert cross_d == pytest.approx(0.0, abs=1e-6)


def test_add_line_distance_constraint_between_two_existing_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 30.0)
    d = sketch.add_point(10.0, 30.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)

    constraint = sketch.add_line_distance_constraint(line1.id, line2.id, 50.0)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id, c.id, d.id)
    assert constraint.distance == 50.0


def test_add_point_line_distance_constraint_between_a_point_and_a_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 5.0)
    line = sketch.add_line(a.id, b.id)

    constraint = sketch.add_point_line_distance_constraint(p.id, line.id, 5.0)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (p.id, a.id, b.id)
    assert constraint.distance == 5.0


def test_point_line_distance_constraint_pins_point_onto_line_after_solve():
    """Stage 21 item 3: a midpoint Point must stay collinear with its Line
    even as the Line moves - a perpendicular distance of 0 pins the Point
    onto the Line's infinite extension (py-slvs's point-on-line primitive),
    unlike a pair of plain point-to-point DistanceConstraints (which only
    pin distance from each endpoint and let the Point swing off the Line in
    an arc)."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 1.0)  # off the line to start
    line = sketch.add_line(a.id, b.id)

    sketch.add_point_line_distance_constraint(p.id, line.id, 0.0)
    sketch.add_distance_constraint(p.id, a.id, 5.0)
    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[p.id].y == pytest.approx(0.0, abs=1e-6)
    assert sketch.points[p.id].x == pytest.approx(5.0, abs=1e-6)


def test_line_distance_constraint_moves_lines_apart_without_creating_points():
    """Stage 16 item 9: a line-to-line distance dimension must move the
    Lines themselves (via py-slvs's point-line-distance primitive) rather
    than the old approach of materializing a midpoint Point on each Line
    and constraining a plain Point-to-Point DistanceConstraint between
    those - the bug this regresses against. Two parallel (horizontal)
    Lines start 30 units apart; raising the constraint's distance to 50
    must converge with the Lines moved apart and not a single new Point in
    the Sketch."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 30.0)
    d = sketch.add_point(10.0, 30.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_horizontal_constraint(line1.id)
    sketch.add_horizontal_constraint(line2.id)
    point_count_before = len(sketch.points)

    sketch.add_line_distance_constraint(line1.id, line2.id, 50.0)
    result = solve_sketch(sketch)

    assert result.converged
    assert len(sketch.points) == point_count_before
    gap = abs(sketch.points[c.id].y - sketch.points[a.id].y)
    assert gap == pytest.approx(50.0, abs=1e-6)
    assert gap != pytest.approx(30.0, abs=1e-6)  # the Lines actually moved apart


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _create_line(sketch_id: str, start_id: str, end_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_id, "end_point_id": end_id},
    )
    assert response.status_code == 201
    return response.json()


def test_create_coincident_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 1.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": a["id"], "point_b_id": b["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "coincident"
    assert body["point_a_id"] == a["id"]
    assert body["point_b_id"] == b["id"]


def test_create_parallel_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 5.0)
    d = _create_point(sketch["id"], 10.0, 5.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "parallel", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "parallel"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]


def test_create_perpendicular_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 0.0)
    d = _create_point(sketch["id"], 0.0, 10.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "perpendicular", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "perpendicular"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]


def test_create_equal_length_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 5.0)
    d = _create_point(sketch["id"], 0.0, 8.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "equal_length", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "equal_length"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]


def test_create_collinear_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 2.0, 3.0)
    d = _create_point(sketch["id"], 8.0, 3.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "collinear", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "collinear"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]


def test_create_line_distance_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 30.0)
    d = _create_point(sketch["id"], 10.0, 30.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "line_distance",
            "line1_id": line1["id"],
            "line2_id": line2["id"],
            "distance": 50.0,
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "line_distance"
    assert body["line1_id"] == line1["id"]
    assert body["line2_id"] == line2["id"]
    assert body["distance"] == 50.0


def test_create_point_line_distance_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "point_line_distance",
            "point_id": p["id"],
            "line_id": line["id"],
            "distance": 5.0,
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "point_line_distance"
    assert body["point_id"] == p["id"]
    assert body["line_id"] == line["id"]
    assert body["distance"] == 5.0


def test_create_coincident_constraint_with_unknown_point_is_404():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": a["id"], "point_b_id": "does-not-exist"},
    )
    assert response.status_code == 404


def test_create_parallel_constraint_with_unknown_line_is_404():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "parallel", "line1_id": line["id"], "line2_id": "does-not-exist"},
    )
    assert response.status_code == 404


def test_create_parallel_constraint_rejects_same_line_twice_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "parallel", "line1_id": line["id"], "line2_id": line["id"]},
    )
    assert response.status_code == 400


def test_list_constraints_includes_new_types_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 0.0, 5.0)
    d = _create_point(sketch["id"], 10.0, 5.0)
    line1 = _create_line(sketch["id"], a["id"], b["id"])
    line2 = _create_line(sketch["id"], c["id"], d["id"])
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "parallel", "line1_id": line1["id"], "line2_id": line2["id"]},
    )

    response = client.get(f"/sketch/sketches/{sketch['id']}/constraints")

    assert response.status_code == 200
    types = [c["type"] for c in response.json()]
    assert types == ["parallel"]


def test_coincident_constraint_solves_correctly_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 5.0, 5.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": a["id"], "point_b_id": b["id"]},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["converged"] is True
    solved_a = client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").json()
    solved_b = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    assert solved_a["x"] == pytest.approx(solved_b["x"])
    assert solved_a["y"] == pytest.approx(solved_b["y"])
