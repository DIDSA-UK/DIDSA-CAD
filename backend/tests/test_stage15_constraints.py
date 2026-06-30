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
    onto the Line's infinite extension, unlike a pair of plain
    point-to-point DistanceConstraints (which only pin distance from each
    endpoint and let the Point swing off the Line in an arc).

    a/b are themselves unconstrained free Points (same as every other
    solver-integration test in this file, e.g.
    test_collinear_constraint_forces_lines_onto_same_line_after_solve), so
    the system is legitimately underdetermined and the solver is free to
    move the Line too - asserting p's *absolute* coordinates would wrongly
    assume a/b stay put. Assert the same relative invariants the collinear
    test uses instead: p stays on the (possibly-moved) line ab, and the
    distance constraint to a still holds.
    """
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 1.0)  # off the line to start
    line = sketch.add_line(a.id, b.id)

    sketch.add_point_line_distance_constraint(p.id, line.id, 0.0)
    sketch.add_distance_constraint(p.id, a.id, 5.0)
    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    px, py = sketch.points[p.id].x, sketch.points[p.id].y
    cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    assert cross == pytest.approx(0.0, abs=1e-6)
    assert math.hypot(px - ax, py - ay) == pytest.approx(5.0, abs=1e-6)


def test_add_at_midpoint_constraint_between_a_point_and_a_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 5.0)
    line = sketch.add_line(a.id, b.id)

    constraint = sketch.add_at_midpoint_constraint(p.id, line.id)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (p.id, a.id, b.id)


def test_add_at_midpoint_constraint_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    with pytest.raises(KeyError):
        sketch.add_at_midpoint_constraint("does-not-exist", line.id)


def test_at_midpoint_constraint_pins_point_to_midpoint_after_solve():
    """Stage 22 item 1: SLVS_C_AT_MIDPOINT pins the Point to the Line's
    actual geometric midpoint - unlike Stage 21's point_line_distance(0) +
    distance(half-length) workaround, this must still hold even as the
    Line's own length changes, since there is no fixed half-length value
    baked into the constraint."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 5.0)  # off the line to start
    line = sketch.add_line(a.id, b.id)
    sketch.add_at_midpoint_constraint(p.id, line.id)
    # Pin the line's own length so the system is fully determined.
    sketch.add_distance_constraint(a.id, b.id, 20.0)
    sketch.add_horizontal_constraint(line.id)

    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    px, py = sketch.points[p.id].x, sketch.points[p.id].y
    assert px == pytest.approx((ax + bx) / 2, abs=1e-6)
    assert py == pytest.approx((ay + by) / 2, abs=1e-6)


def test_at_midpoint_constraint_tracks_midpoint_as_line_length_changes():
    """Regresses against the Stage 21 workaround's actual bug: pinning the
    Point with a fixed half-length DistanceConstraint meant it stopped
    tracking the midpoint once the Line's length changed independently.
    SLVS_C_AT_MIDPOINT has no such fixed value, so it must still land on
    the midpoint after the Line's length constraint is changed and the
    sketch is re-solved."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    p = sketch.add_point(5.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_at_midpoint_constraint(p.id, line.id)
    sketch.add_horizontal_constraint(line.id)
    length = sketch.add_distance_constraint(a.id, b.id, 10.0)

    result = solve_sketch(sketch)
    assert result.converged
    assert sketch.points[p.id].x == pytest.approx(
        (sketch.points[a.id].x + sketch.points[b.id].x) / 2, abs=1e-6
    )

    length.distance = 40.0
    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[p.id].x == pytest.approx(
        (sketch.points[a.id].x + sketch.points[b.id].x) / 2, abs=1e-6
    )


def test_point_pinned_to_midpoint_of_two_lines_lands_at_their_shared_center():
    """Prompt B item B2: a rectangle's center Point is pinned to the
    midpoint of both diagonals via two AtMidpoint constraints on the same
    Point - both must hold simultaneously after solve. a/b/c/d are
    themselves unconstrained free Points (same rationale as
    test_point_line_distance_constraint_pins_point_onto_line_after_solve),
    so the solver is free to move the whole rectangle too - assert the
    relative invariant (center matches *both* diagonals' actual solved
    midpoints) rather than fixed absolute coordinates."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 6.0)
    d = sketch.add_point(0.0, 6.0)
    diagonal1 = sketch.add_line(a.id, c.id, construction=True)
    diagonal2 = sketch.add_line(b.id, d.id, construction=True)
    center = sketch.add_point(1.0, 1.0)  # off-center initial guess
    sketch.add_at_midpoint_constraint(center.id, diagonal1.id)
    sketch.add_at_midpoint_constraint(center.id, diagonal2.id)

    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    cx, cy = sketch.points[c.id].x, sketch.points[c.id].y
    dx, dy = sketch.points[d.id].x, sketch.points[d.id].y
    centerx, centery = sketch.points[center.id].x, sketch.points[center.id].y
    assert centerx == pytest.approx((ax + cx) / 2, abs=1e-6)
    assert centery == pytest.approx((ay + cy) / 2, abs=1e-6)
    assert centerx == pytest.approx((bx + dx) / 2, abs=1e-6)
    assert centery == pytest.approx((by + dy) / 2, abs=1e-6)


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


def test_create_at_midpoint_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "at_midpoint", "point_id": p["id"], "line_id": line["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "at_midpoint"
    assert body["point_id"] == p["id"]
    assert body["line_id"] == line["id"]
    assert "distance" not in body


def test_patch_at_midpoint_constraint_value_is_422():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "at_midpoint", "point_id": p["id"], "line_id": line["id"]},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}",
        json={"value": 5.0},
    )

    assert response.status_code == 422


def test_delete_at_midpoint_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    p = _create_point(sketch["id"], 5.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "at_midpoint", "point_id": p["id"], "line_id": line["id"]},
    ).json()

    response = client.delete(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}"
    )

    assert response.status_code == 204
    remaining = client.get(f"/sketch/sketches/{sketch['id']}/constraints").json()
    assert constraint["id"] not in [c["id"] for c in remaining]


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


# --- Prompt B item B3: DistanceConstraint orientation --------------------


def test_add_distance_constraint_defaults_to_linear_orientation():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)

    constraint = sketch.add_distance_constraint(a.id, b.id, 5.0)

    assert constraint.orientation == "linear"


def test_horizontal_distance_constraint_pins_only_x_separation_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    sketch.add_distance_constraint(a.id, b.id, 10.0, "horizontal")
    # Pin `a` in place (coincident, not a zero-distance constraint - py-slvs's
    # point-distance equation is singular at distance 0) so the solver has a
    # unique answer to check against.
    sketch.add_coincident_constraint(a.id, sketch.origin_point().id)

    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    assert abs(ax - bx) == pytest.approx(10.0, abs=1e-6)
    assert by == pytest.approx(4.0, abs=1e-6)  # y separation left unconstrained


def test_vertical_distance_constraint_pins_only_y_separation_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    sketch.add_distance_constraint(a.id, b.id, 10.0, "vertical")
    sketch.add_coincident_constraint(a.id, sketch.origin_point().id)

    result = solve_sketch(sketch)

    assert result.converged
    ax, ay = sketch.points[a.id].x, sketch.points[a.id].y
    bx, by = sketch.points[b.id].x, sketch.points[b.id].y
    assert abs(ay - by) == pytest.approx(10.0, abs=1e-6)
    assert bx == pytest.approx(3.0, abs=1e-6)  # x separation left unconstrained


def test_create_horizontal_orientation_distance_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "point_a_id": a["id"],
            "point_b_id": b["id"],
            "distance": 10.0,
            "orientation": "horizontal",
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["orientation"] == "horizontal"


def test_update_constraint_value_preserves_horizontal_orientation():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "point_a_id": a["id"],
            "point_b_id": b["id"],
            "distance": 10.0,
            "orientation": "horizontal",
        },
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}",
        json={"value": 25.0},
    )

    assert response.status_code == 200
    constraints = client.get(f"/sketch/sketches/{sketch['id']}/constraints").json()
    updated = next(c for c in constraints if c["id"] == constraint["id"])
    assert updated["orientation"] == "horizontal"
    assert updated["distance"] == 25.0


# --- Prompt B item B5: solve response DOF ---------------------------------


def test_a_fully_constrained_sketch_reports_zero_dof():
    """One Point pinned to the (fixed) origin, the other fully pinned
    relative to it by a Vertical constraint (equal X) plus a plain
    DistanceConstraint (fixes the remaining Y up to sign) - 2 independent
    equations for the second Point's 2 unknowns, 0 degrees of freedom."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(0.0, 5.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_coincident_constraint(a.id, sketch.origin_point().id)
    sketch.add_vertical_constraint(line.id)
    sketch.add_distance_constraint(a.id, b.id, 5.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.dof == 0


def test_an_under_constrained_sketch_reports_nonzero_dof():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    sketch.add_distance_constraint(a.id, b.id, 10.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.dof > 0


def test_a_fully_constrained_sketch_reports_zero_dof_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 0.0, 5.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": a["id"], "point_b_id": sketch["origin_point_id"]},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "vertical", "line_id": line["id"]},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["dof"] == 0
