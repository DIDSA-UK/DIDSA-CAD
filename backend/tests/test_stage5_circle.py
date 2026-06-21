import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Circle, Plane, Sketch
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_circle_from_radius_and_angle_creates_new_radius_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)

    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    assert isinstance(circle, Circle)
    assert circle.center_point_id == center.id
    assert circle.radius_point_id in sketch.points
    assert circle.radius(sketch.points) == pytest.approx(5.0)


def test_add_circle_with_existing_radius_point_computes_current_distance():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    edge = sketch.add_point(3.0, 4.0)

    circle = sketch.add_circle(center.id, edge.id)

    assert circle.radius_point_id == edge.id
    assert circle.radius(sketch.points) == pytest.approx(5.0)


def test_add_circle_rejects_same_center_and_radius_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_circle(center.id, center.id)


def test_add_circle_with_unknown_radius_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_circle(center.id, "does-not-exist")


def test_add_circle_automatically_creates_a_distance_constraint():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    edge = sketch.add_point(10.0, 0.0)

    circle = sketch.add_circle(center.id, edge.id)

    assert len(sketch.constraints) == 1
    constraint = next(iter(sketch.constraints.values()))
    assert set(constraint.point_ids()) == {circle.center_point_id, circle.radius_point_id}
    assert constraint.distance == pytest.approx(10.0)


def test_solving_satisfies_the_circle_radius_constraint_after_moving_center():
    """Move the center after creation (the next initial guess, same as a
    Line's points), then solve - the radius point must end up exactly
    `radius` away from the new center position, same as Line's length
    constraint already does for its end point."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    sketch.points[center.id].x = 100.0
    sketch.points[center.id].y = 100.0

    result = solve_sketch(sketch)

    assert result.converged
    assert circle.radius(sketch.points) == pytest.approx(5.0)


def test_circle_endpoint_point_ids_is_none():
    """Documented design decision: a Circle's center/radius points are not
    chain-connection points the way a Line's start/end points are, so it
    does not participate in the Line-chain connectivity graph."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    assert circle.endpoint_point_ids() is None


def test_circle_center_and_radius_point_can_be_explicitly_shared_with_a_line():
    """Per the explicit-sharing-only rule already used by Line, a Circle's
    points are real Points like any other - a Line can reference one of
    them by id without anything breaking."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    other = sketch.add_point(20.0, 0.0)

    line = sketch.add_line(circle.center_point_id, other.id)

    assert line.start_point_id == circle.center_point_id
    result = solve_sketch(sketch)
    assert result.converged


# --- Profile detection -------------------------------------------------------


def test_standalone_circle_is_its_own_closed_profile():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    sketch.add_circle(center.id, radius=5.0, angle=0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert set(result.profile.point_ids) == set(sketch.points)


def test_multiple_standalone_circles_are_multiple_loops():
    sketch = Sketch(id="s", plane=Plane.XY)
    center_a = sketch.add_point(0.0, 0.0)
    sketch.add_circle(center_a.id, radius=5.0, angle=0.0)
    center_b = sketch.add_point(100.0, 0.0)
    sketch.add_circle(center_b.id, radius=2.0, angle=0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 2


def test_existing_line_chain_profile_detection_is_unaffected_by_circle_support():
    """A square line loop, with no circles at all, must still be detected
    exactly as before - circle support must not change this path."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    d = sketch.add_point(0.0, 10.0)
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)
    sketch.add_line(c.id, d.id)
    sketch.add_line(d.id, a.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert len(result.profile.line_ids) == 4


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_circle_from_existing_points_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    edge = _create_point(sketch["id"], 3.0, 4.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius_point_id": edge["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "circle"
    assert body["center_point_id"] == center["id"]
    assert body["radius_point_id"] == edge["id"]
    assert body["radius"] == pytest.approx(5.0)


def test_create_circle_from_radius_and_angle_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 7.0, "angle": 0.0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["radius"] == pytest.approx(7.0)


def test_create_circle_requires_radius_point_or_radius_and_angle():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"]},
    )

    assert response.status_code == 422


def test_create_circle_rejects_both_radius_point_and_radius_and_angle():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    edge = _create_point(sketch["id"], 1.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius_point_id": edge["id"], "radius": 1.0, "angle": 0.0},
    )

    assert response.status_code == 422


def test_create_circle_with_unknown_center_point_is_404():
    sketch = _create_sketch()
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": "does-not-exist", "radius": 1.0, "angle": 0.0},
    )
    assert response.status_code == 404


def test_get_circle_round_trip():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 9.0, "angle": 0.0},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/circles/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_circle_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/circles/does-not-exist")
    assert response.status_code == 404


def test_list_circles_returns_every_circle_in_the_sketch():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    circle = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 9.0, "angle": 0.0},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/circles")

    assert response.status_code == 200
    assert [c["id"] for c in response.json()] == [circle["id"]]


def test_list_circles_on_a_sketch_with_no_circles_is_empty():
    sketch = _create_sketch()

    response = client.get(f"/sketch/sketches/{sketch['id']}/circles")

    assert response.status_code == 200
    assert response.json() == []


def test_creating_a_circle_over_the_api_creates_a_solvable_radius_constraint():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 6.0, "angle": 0.0},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["converged"] is True


def test_standalone_circle_profile_detection_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 4.0, "angle": 0.0},
    )

    response = client.get(f"/sketch/sketches/{sketch['id']}/profile")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "closed_loop"
    assert len(body["profile"]["point_ids"]) == 2
