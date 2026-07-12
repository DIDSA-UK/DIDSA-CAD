import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Plane, Sketch
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def test_vertical_constraint_forces_same_x_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 10.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_vertical_constraint(line.id)

    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[a.id].x == pytest.approx(sketch.points[b.id].x)


def test_horizontal_constraint_forces_same_y_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 10.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_horizontal_constraint(line.id)

    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[a.id].y == pytest.approx(sketch.points[b.id].y)


def test_angle_constraint_produces_correct_angle_after_solve():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 0.0)
    d = sketch.add_point(10.0, 1.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_horizontal_constraint(line1.id)
    sketch.add_angle_constraint(line1.id, line2.id, 30.0)

    result = solve_sketch(sketch)

    assert result.converged
    p1a, p1b = sketch.points[a.id], sketch.points[b.id]
    p2a, p2b = sketch.points[c.id], sketch.points[d.id]
    angle1 = math.atan2(p1b.y - p1a.y, p1b.x - p1a.x)
    angle2 = math.atan2(p2b.y - p2a.y, p2b.x - p2a.x)
    angle_between = math.degrees(abs(angle1 - angle2))
    angle_between = angle_between % 180
    # d=(10, 1) seeds Line 2 at ~5.7 degrees from Line 1 - clearly closer to
    # the 30 degree target than to its supplement (150) - so the fix (see
    # test below) should deterministically land on 30, not either.
    assert angle_between == pytest.approx(30.0, abs=0.01)


def test_angle_constraint_preserves_the_supplementary_configuration_when_that_is_what_the_seed_already_has():
    """Bug fix: py-slvs's addAngle has a `supplement` flag choosing between
    constraining to `degrees` or to its supplement (180 - degrees) - this
    codebase always passed False, so a Sketch already sitting near the
    *supplementary* configuration (e.g. mid-drag, or one interior angle of
    a Polygon while its neighbours hold the primary angle) would be forced
    to snap down to the primary angle instead of staying where it already
    was - reported on-device as a dimension "flipping polarity" and, for a
    Polygon, breaking its regular shape. d=(-10, 1) seeds Line 2 at ~170.9
    degrees from Line 1, i.e. close to 150 (30's supplement) - the fix
    should recognise that and preserve ~150, not force 30."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(0.0, 0.0)
    d = sketch.add_point(-10.0, 1.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(c.id, d.id)
    sketch.add_horizontal_constraint(line1.id)
    sketch.add_angle_constraint(line1.id, line2.id, 30.0)

    result = solve_sketch(sketch)

    assert result.converged
    p1a, p1b = sketch.points[a.id], sketch.points[b.id]
    p2a, p2b = sketch.points[c.id], sketch.points[d.id]
    angle1 = math.atan2(p1b.y - p1a.y, p1b.x - p1a.x)
    angle2 = math.atan2(p2b.y - p2a.y, p2b.x - p2a.x)
    angle_between = math.degrees(abs(angle1 - angle2)) % 180
    assert angle_between == pytest.approx(150.0, abs=0.01)


def test_construction_line_excluded_from_profile_detection_even_when_closing_a_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)
    # This line would close the loop back to a, but it's construction-only,
    # so it must be invisible to profile detection.
    sketch.add_line(c.id, a.id, construction=True)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.NO_LOOP


def test_sketch_with_only_construction_entities_has_no_profile():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    sketch.add_line(a.id, b.id, construction=True)
    sketch.add_line(b.id, c.id, construction=True)
    sketch.add_line(c.id, a.id, construction=True)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.NO_LOOP


def test_construction_diagonals_alongside_a_closed_loop_still_detect_the_loop():
    """Prompt B item B2: a rectangle's 2 construction corner-to-corner
    diagonals coexist with its 4 regular sides - the diagonals must stay
    invisible to profile detection while the regular loop they cross is
    still found, same as the rectangle tool's own output."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    d = sketch.add_point(0.0, 10.0)
    side1 = sketch.add_line(a.id, b.id)
    side2 = sketch.add_line(b.id, c.id)
    side3 = sketch.add_line(c.id, d.id)
    side4 = sketch.add_line(d.id, a.id)
    sketch.add_line(a.id, c.id, construction=True)
    sketch.add_line(b.id, d.id, construction=True)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert set(result.profile.line_ids) == {side1.id, side2.id, side3.id, side4.id}


# --- Stage 13: PATCH constraint value -----------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_patch_distance_constraint_value_produces_correct_new_solved_geometry():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 10.0},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}",
        json={"value": 25.0},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["converged"] is True

    updated_b = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    updated_a = client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").json()
    new_distance = math.hypot(updated_b["x"] - updated_a["x"], updated_b["y"] - updated_a["y"])
    assert new_distance == pytest.approx(25.0)


def test_patch_vertical_constraint_value_is_422():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 10.0)
    line = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "vertical", "line_id": line["id"]},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{constraint['id']}",
        json={"value": 5.0},
    )

    assert response.status_code == 422
