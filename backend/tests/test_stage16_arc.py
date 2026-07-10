import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Arc, Plane, Sketch
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_arc_from_end_angle_creates_new_end_point_on_the_same_circle():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)

    arc = sketch.add_arc(center.id, start.id, end_angle=math.pi / 2)

    assert isinstance(arc, Arc)
    assert arc.center_point_id == center.id
    assert arc.start_point_id == start.id
    assert arc.end_point_id in sketch.points
    end = sketch.points[arc.end_point_id]
    assert end.x == pytest.approx(0.0, abs=1e-9)
    assert end.y == pytest.approx(5.0)
    assert arc.radius(sketch.points) == pytest.approx(5.0)


def test_add_arc_with_existing_end_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(3.0, 4.0)
    end = sketch.add_point(-3.0, 4.0)

    arc = sketch.add_arc(center.id, start.id, end.id)

    assert arc.end_point_id == end.id
    assert arc.radius(sketch.points) == pytest.approx(5.0)


def test_add_arc_rejects_center_start_end_not_all_distinct():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_arc(center.id, start.id, start.id)
    with pytest.raises(ValueError):
        sketch.add_arc(center.id, center.id, end_angle=0.0)


def test_add_arc_rejects_start_point_coincident_with_center():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_arc(center.id, start.id, end_angle=0.0)


def test_add_arc_with_unknown_end_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_arc(center.id, start.id, "does-not-exist")


def test_add_arc_automatically_creates_two_distance_constraints_at_the_same_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(10.0, 0.0)

    arc = sketch.add_arc(center.id, start.id, end_angle=math.pi)

    assert len(sketch.constraints) == 2
    radius_constraint = sketch.constraints[arc.radius_constraint_id]
    end_radius_constraint = sketch.constraints[arc.end_radius_constraint_id]
    assert set(radius_constraint.point_ids()) == {arc.center_point_id, arc.start_point_id}
    assert set(end_radius_constraint.point_ids()) == {arc.center_point_id, arc.end_point_id}
    assert radius_constraint.distance == pytest.approx(10.0)
    assert end_radius_constraint.distance == pytest.approx(10.0)


def test_solving_keeps_both_arc_ends_on_the_same_circle_after_moving_center():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    arc = sketch.add_arc(center.id, start.id, end_angle=math.pi / 2)

    sketch.points[center.id].x = 50.0
    sketch.points[center.id].y = -20.0

    result = solve_sketch(sketch)

    assert result.converged
    c = sketch.points[arc.center_point_id]
    s = sketch.points[arc.start_point_id]
    e = sketch.points[arc.end_point_id]
    assert math.hypot(s.x - c.x, s.y - c.y) == pytest.approx(5.0)
    assert math.hypot(e.x - c.x, e.y - c.y) == pytest.approx(5.0)


def test_arc_endpoint_point_ids_returns_start_and_end_not_center():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    arc = sketch.add_arc(center.id, start.id, end_angle=math.pi / 2)

    assert arc.endpoint_point_ids() == (arc.start_point_id, arc.end_point_id)
    assert center.id not in arc.endpoint_point_ids()


def test_delete_arc_removes_both_radius_constraints():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    arc = sketch.add_arc(center.id, start.id, end_angle=math.pi / 2)
    assert len(sketch.constraints) == 2

    sketch.delete_arc(arc.id)

    assert arc.id not in sketch.entities
    assert sketch.constraints == {}


def test_point_deletion_is_blocked_while_referenced_by_an_arc():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    arc = sketch.add_arc(center.id, start.id, end_angle=math.pi / 2)

    with pytest.raises(ValueError):
        sketch.delete_point(center.id)
    with pytest.raises(ValueError):
        sketch.delete_point(arc.start_point_id)
    with pytest.raises(ValueError):
        sketch.delete_point(arc.end_point_id)


# --- Profile detection -------------------------------------------------------


def test_line_and_arc_chain_closes_into_a_single_loop():
    """A 'stadium' shape - two straight sides plus two semicircular arc
    caps - is a valid closed profile: Arc.endpoint_point_ids() slots it
    into the same generic chain-walk Line already participates in, with no
    profile.py changes of its own."""
    sketch = Sketch(id="s", plane=Plane.XY)
    left_center = sketch.add_point(0.0, 0.0)
    right_center = sketch.add_point(20.0, 0.0)
    a = sketch.add_point(0.0, 5.0)
    b = sketch.add_point(0.0, -5.0)
    c = sketch.add_point(20.0, -5.0)
    d = sketch.add_point(20.0, 5.0)

    sketch.add_arc(left_center.id, a.id, b.id)
    sketch.add_line(b.id, c.id)
    sketch.add_arc(right_center.id, c.id, d.id)
    sketch.add_line(d.id, a.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert len(result.profile.line_ids) == 4


def test_existing_line_chain_profile_detection_is_unaffected_by_arc_support():
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


def test_create_arc_from_existing_end_point_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    start = _create_point(sketch["id"], 5.0, 0.0)
    end = _create_point(sketch["id"], 0.0, 5.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"], "end_point_id": end["id"]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "arc"
    assert body["center_point_id"] == center["id"]
    assert body["start_point_id"] == start["id"]
    assert body["end_point_id"] == end["id"]
    assert body["radius"] == pytest.approx(5.0)


def test_create_arc_from_end_angle_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    start = _create_point(sketch["id"], 7.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"], "end_angle": math.pi},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["radius"] == pytest.approx(7.0)


def test_create_arc_requires_end_point_id_or_end_angle():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    start = _create_point(sketch["id"], 5.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"]},
    )

    assert response.status_code == 422


def test_create_arc_rejects_both_end_point_id_and_end_angle():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    start = _create_point(sketch["id"], 5.0, 0.0)
    end = _create_point(sketch["id"], 0.0, 5.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={
            "center_point_id": center["id"],
            "start_point_id": start["id"],
            "end_point_id": end["id"],
            "end_angle": 1.0,
        },
    )

    assert response.status_code == 422


def test_create_arc_with_unknown_center_point_is_404():
    sketch = _create_sketch()
    start = _create_point(sketch["id"], 5.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": "does-not-exist", "start_point_id": start["id"], "end_angle": 1.0},
    )
    assert response.status_code == 404


def test_get_arc_round_trip():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    start = _create_point(sketch["id"], 9.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"], "end_angle": math.pi / 2},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/arcs/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_arc_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/arcs/does-not-exist")
    assert response.status_code == 404


def test_list_arcs_returns_every_arc_in_the_sketch():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    start = _create_point(sketch["id"], 9.0, 0.0)
    arc = client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"], "end_angle": math.pi / 2},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/arcs")

    assert response.status_code == 200
    assert [a["id"] for a in response.json()] == [arc["id"]]


def test_delete_arc_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    start = _create_point(sketch["id"], 9.0, 0.0)
    arc = client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"], "end_angle": math.pi / 2},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/arcs/{arc['id']}")
    assert response.status_code == 204

    response = client.get(f"/sketch/sketches/{sketch['id']}/arcs/{arc['id']}")
    assert response.status_code == 404


def test_creating_an_arc_over_the_api_creates_a_solvable_pair_of_radius_constraints():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    start = _create_point(sketch["id"], 6.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"], "end_angle": math.pi},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["converged"] is True


def test_stadium_profile_detection_over_the_api():
    sketch = _create_sketch()
    left_center = _create_point(sketch["id"], 0.0, 0.0)
    right_center = _create_point(sketch["id"], 20.0, 0.0)
    a = _create_point(sketch["id"], 0.0, 5.0)
    b = _create_point(sketch["id"], 0.0, -5.0)
    c = _create_point(sketch["id"], 20.0, -5.0)
    d = _create_point(sketch["id"], 20.0, 5.0)

    client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": left_center["id"], "start_point_id": a["id"], "end_point_id": b["id"]},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": b["id"], "end_point_id": c["id"]},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/arcs",
        json={"center_point_id": right_center["id"], "start_point_id": c["id"], "end_point_id": d["id"]},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": d["id"], "end_point_id": a["id"]},
    )

    response = client.get(f"/sketch/sketches/{sketch['id']}/profile")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "closed_loop"
    assert len(body["profile"]["line_ids"]) == 4


# --- Extrude (mixed Line/Arc wire construction) -------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_stadium(sketch_id: str, length: float, radius: float) -> None:
    """A rectangle of the given `length` with semicircular caps of
    `radius` on each short end, entirely via the real /sketch API - two
    Arcs (one per cap) plus two Lines (top/bottom straight sides)."""
    left_center = _create_point(sketch_id, 0.0, 0.0)
    right_center = _create_point(sketch_id, length, 0.0)
    a = _create_point(sketch_id, 0.0, radius)
    b = _create_point(sketch_id, 0.0, -radius)
    c = _create_point(sketch_id, length, -radius)
    d = _create_point(sketch_id, length, radius)

    assert client.post(
        f"/sketch/sketches/{sketch_id}/arcs",
        json={"center_point_id": left_center["id"], "start_point_id": a["id"], "end_point_id": b["id"]},
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": b["id"], "end_point_id": c["id"]},
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/arcs",
        json={"center_point_id": right_center["id"], "start_point_id": c["id"], "end_point_id": d["id"]},
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": d["id"], "end_point_id": a["id"]},
    ).status_code == 201


def _create_extrude_feature(part_id: str, sketch_feature_id: str, *, end_distance: float = 10.0) -> dict:
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
    assert response.status_code == 201
    return response.json()


def test_extruding_a_stadium_profile_produces_a_non_empty_computed_mesh():
    """The mixed Line/Arc wire-construction path in
    app.document.extrude.wire_for_profile, exercised end-to-end through a
    real extrude - a straight-polygon-only wire would silently draw
    chords across the arc caps instead of curves, but this at least
    confirms the mixed path produces a valid, meshable solid at all."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_stadium(sketch_feature["sketch_id"], length=20.0, radius=5.0)

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0
    assert len(bodies[0]["mesh"]["triangle_indices"]) > 0
