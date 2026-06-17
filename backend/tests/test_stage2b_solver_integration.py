import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch

client = TestClient(app)


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_distance_constraint_between_two_existing_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)

    constraint = sketch.add_distance_constraint(a.id, b.id, 50.0)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id)
    assert constraint.distance == 50.0


def test_add_distance_constraint_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_distance_constraint(a.id, "does-not-exist", 10.0)


def test_add_distance_constraint_rejects_same_point_twice():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_distance_constraint(a.id, a.id, 10.0)


def test_solving_two_points_satisfies_distance_constraint():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    sketch.add_distance_constraint(a.id, b.id, 50.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.result_code == 0
    distance = math.hypot(
        sketch.points[b.id].x - sketch.points[a.id].x,
        sketch.points[b.id].y - sketch.points[a.id].y,
    )
    assert distance == pytest.approx(50.0)


def test_solving_a_line_via_its_points_moves_the_line():
    """The actual Stage 2 <-> Stage 2a wiring check: build a Line (which
    only knows about its two Point ids, not constraints), add a distance
    constraint against those same Point ids, solve, and confirm the Line's
    derived length reflects the solved positions - exactly as it does
    when a Point is moved directly via Line.set_length()."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    assert line.length(sketch.points) == pytest.approx(3.0)

    sketch.add_distance_constraint(a.id, b.id, 25.0)
    result = solve_sketch(sketch)

    assert result.converged
    assert line.length(sketch.points) == pytest.approx(25.0)


def test_constraint_with_no_constraints_is_trivially_converged():
    sketch = Sketch(id="s", plane=Plane.XY)
    sketch.add_point(0.0, 0.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.blamed_constraint_ids == []


def test_overconstrained_triangle_reports_non_convergence_and_diagnostics():
    """A, B, C with distances that violate the triangle inequality
    (10 + 10 < 100) can never be simultaneously satisfied."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(5.0, 8.0)

    sketch.add_distance_constraint(a.id, b.id, 10.0)
    sketch.add_distance_constraint(b.id, c.id, 10.0)
    newest = sketch.add_distance_constraint(a.id, c.id, 100.0)

    result = solve_sketch(sketch)

    assert not result.converged
    assert result.result_code != 0
    # Blame convention: the most-recently-added constraint, not a real
    # root-cause diagnosis.
    assert result.blamed_constraint_ids == [newest.id]
    # Genuine py-slvs diagnostics are still surfaced alongside the
    # convention: a Dof reading, and py-slvs's own (coarse) failed-
    # constraint report.
    assert isinstance(result.dof, int)
    assert result.solver_reported_failed_constraint_ids
    assert set(result.solver_reported_failed_constraint_ids) <= set(sketch.constraints)


def test_multiple_sketches_have_independent_constraints():
    sketch_one = Sketch(id="s1", plane=Plane.XY)
    a1 = sketch_one.add_point(0.0, 0.0)
    b1 = sketch_one.add_point(1.0, 0.0)
    sketch_one.add_distance_constraint(a1.id, b1.id, 7.0)

    sketch_two = Sketch(id="s2", plane=Plane.XY)
    a2 = sketch_two.add_point(0.0, 0.0)
    b2 = sketch_two.add_point(1.0, 0.0)

    assert len(sketch_one.constraints) == 1
    assert len(sketch_two.constraints) == 0

    result_one = solve_sketch(sketch_one)
    result_two = solve_sketch(sketch_two)

    assert result_one.converged
    distance_one = math.hypot(
        sketch_one.points[b1.id].x - sketch_one.points[a1.id].x,
        sketch_one.points[b1.id].y - sketch_one.points[a1.id].y,
    )
    assert distance_one == pytest.approx(7.0)
    # sketch_two had no constraints, so its points are untouched.
    assert sketch_two.points[a2.id].x == pytest.approx(0.0)
    assert sketch_two.points[b2.id].x == pytest.approx(1.0)
    assert result_two.converged
    assert result_two.detail == "No constraints to solve."


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 12.0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "distance"
    assert body["point_a_id"] == a["id"]
    assert body["point_b_id"] == b["id"]
    assert body["distance"] == pytest.approx(12.0)


def test_create_constraint_with_unknown_point_is_404():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": "does-not-exist", "distance": 1.0},
    )
    assert response.status_code == 404


def test_create_constraint_rejects_same_point_twice_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": a["id"], "distance": 1.0},
    )
    assert response.status_code == 400


def test_list_constraints_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    )

    response = client.get(f"/sketch/sketches/{sketch['id']}/constraints")

    assert response.status_code == 200
    assert len(response.json()) == 1


def test_delete_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/constraints/{created['id']}")
    assert response.status_code == 204

    response = client.get(f"/sketch/sketches/{sketch['id']}/constraints")
    assert response.json() == []


def test_delete_unknown_constraint_is_404():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/constraints/does-not-exist")
    assert response.status_code == 404


def test_moving_a_point_directly_does_not_trigger_a_solve():
    """PATCH on a Point only updates its position - it is the next initial
    guess, not a solved result. Moving b away from where the constraint
    would put it, then never calling /solve, must leave it exactly where
    PATCH put it."""
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 50.0},
    )

    client.patch(f"/sketch/sketches/{sketch['id']}/points/{b['id']}", json={"x": 99.0, "y": 99.0})

    moved = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    assert moved["x"] == pytest.approx(99.0)
    assert moved["y"] == pytest.approx(99.0)


def test_solve_over_the_api_updates_points_and_reports_convergence():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 50.0},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    body = response.json()
    assert body["converged"] is True
    assert body["result_code"] == 0
    assert body["blamed_constraint_ids"] == []

    solved_a = client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").json()
    solved_b = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    distance = math.hypot(solved_b["x"] - solved_a["x"], solved_b["y"] - solved_a["y"])
    assert distance == pytest.approx(50.0)


def test_solve_over_the_api_reports_non_convergence_for_overconstrained_sketch():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 5.0, 8.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 10.0},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": b["id"], "point_b_id": c["id"], "distance": 10.0},
    )
    newest = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": c["id"], "distance": 100.0},
    ).json()

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    body = response.json()
    assert body["converged"] is False
    assert body["blamed_constraint_ids"] == [newest["id"]]
    assert body["solver_reported_failed_constraint_ids"]
