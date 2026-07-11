import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Ellipse, Plane, Sketch
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_ellipse_from_major_radius_and_angle_creates_a_major_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)

    ellipse = sketch.add_ellipse(center.id, major_radius=10.0, angle=0.0, minor_radius=4.0)

    assert isinstance(ellipse, Ellipse)
    assert ellipse.center_point_id == center.id
    assert ellipse.major_point_id in sketch.points
    major = sketch.points[ellipse.major_point_id]
    assert major.x == pytest.approx(10.0)
    assert major.y == pytest.approx(0.0)
    assert ellipse.major_radius(sketch.points) == pytest.approx(10.0)
    assert ellipse.minor_radius(sketch.points) == pytest.approx(4.0)
    assert ellipse.rotation(sketch.points) == pytest.approx(0.0)


def test_add_ellipse_with_existing_major_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(3.0, 4.0)

    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=2.0)

    assert ellipse.major_point_id == major.id
    assert ellipse.major_radius(sketch.points) == pytest.approx(5.0)
    assert ellipse.rotation(sketch.points) == pytest.approx(math.atan2(4.0, 3.0))


def test_add_ellipse_creates_a_minor_point_exactly_perpendicular_to_the_major_axis():
    """Feedback round: the minor axis is now real, solver-tracked geometry
    (a Point + DistanceConstraint), not a bare stored float - and its
    initial placement is exactly perpendicular to the major axis (the
    PerpendicularConstraint between the two axis Lines then keeps it that
    way under drag)."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(10.0, 0.0)

    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=4.0)

    assert ellipse.minor_point_id in sketch.points
    minor = sketch.points[ellipse.minor_point_id]
    assert minor.x == pytest.approx(0.0, abs=1e-9)
    assert minor.y == pytest.approx(4.0)
    assert ellipse.minor_radius(sketch.points) == pytest.approx(4.0)


def test_add_ellipse_creates_two_construction_axis_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(10.0, 0.0)

    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=4.0)

    major_line = sketch.entities[ellipse.major_axis_line_id]
    minor_line = sketch.entities[ellipse.minor_axis_line_id]
    assert major_line.construction is True
    assert minor_line.construction is True
    assert {major_line.start_point_id, major_line.end_point_id} == {
        ellipse.center_point_id,
        ellipse.major_point_id,
    }
    assert {minor_line.start_point_id, minor_line.end_point_id} == {
        ellipse.center_point_id,
        ellipse.minor_point_id,
    }


def test_add_ellipse_rejects_same_center_and_major_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse(center.id, center.id, minor_radius=1.0)


def test_add_ellipse_rejects_non_positive_minor_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(10.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse(center.id, start.id, minor_radius=0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse(center.id, start.id, minor_radius=-1.0)


def test_add_ellipse_rejects_minor_radius_exceeding_major_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(10.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse(center.id, start.id, minor_radius=20.0)


def test_add_ellipse_with_unknown_major_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_ellipse(center.id, "does-not-exist", minor_radius=1.0)


def test_add_ellipse_automatically_creates_its_own_constraints():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(10.0, 0.0)

    ellipse = sketch.add_ellipse(center.id, start.id, minor_radius=4.0)

    # 2 radius DistanceConstraints (major, minor) + 1 PerpendicularConstraint.
    assert len(sketch.constraints) == 3
    major_constraint = sketch.constraints[ellipse.major_constraint_id]
    assert set(major_constraint.point_ids()) == {ellipse.center_point_id, ellipse.major_point_id}
    assert major_constraint.distance == pytest.approx(10.0)
    minor_constraint = sketch.constraints[ellipse.minor_constraint_id]
    assert set(minor_constraint.point_ids()) == {ellipse.center_point_id, ellipse.minor_point_id}
    assert minor_constraint.distance == pytest.approx(4.0)
    perpendicular = sketch.constraints[ellipse.perpendicular_constraint_id]
    assert perpendicular.line1_id == ellipse.major_axis_line_id
    assert perpendicular.line2_id == ellipse.minor_axis_line_id


def test_solving_keeps_the_major_point_at_a_fixed_distance_after_moving_center():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, start.id, minor_radius=2.0)

    # A real drag re-solves after every incremental move, so Newton's
    # method always starts close to a valid configuration - a moderate
    # jump exercises that "moved, must re-satisfy the constraint" behavior
    # without the artificial stress of teleporting the centre far outside
    # any neighborhood the (unmoved) major/minor Points could converge from.
    sketch.points[center.id].x = 10.0
    sketch.points[center.id].y = -5.0

    result = solve_sketch(sketch)

    assert result.converged
    c = sketch.points[ellipse.center_point_id]
    m = sketch.points[ellipse.major_point_id]
    assert math.hypot(m.x - c.x, m.y - c.y) == pytest.approx(5.0)


def test_solving_keeps_the_minor_axis_perpendicular_after_dragging_the_major_point():
    """A real drag: rotating the major axis by dragging its Point must
    carry the minor axis along with it (via the PerpendicularConstraint),
    not leave it pointing in its original, now-stale direction."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(10.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=4.0)

    # Drag the major point to a new angle - roughly 30 degrees, not exactly
    # on the circle of radius 10, to also exercise the radius constraint
    # re-solving to the correct distance.
    sketch.points[major.id].x = 9.0
    sketch.points[major.id].y = 5.5

    result = solve_sketch(sketch, anchor_point_ids=frozenset({major.id}))

    assert result.converged
    c = sketch.points[ellipse.center_point_id]
    m = sketch.points[ellipse.major_point_id]
    n = sketch.points[ellipse.minor_point_id]
    major_angle = math.atan2(m.y - c.y, m.x - c.x)
    minor_angle = math.atan2(n.y - c.y, n.x - c.x)
    angle_diff = abs(((minor_angle - major_angle + math.pi) % (2 * math.pi)) - math.pi)
    assert angle_diff == pytest.approx(math.pi / 2, abs=1e-6)
    assert math.hypot(m.x - c.x, m.y - c.y) == pytest.approx(10.0, abs=1e-6)
    assert math.hypot(n.x - c.x, n.y - c.y) == pytest.approx(4.0, abs=1e-6)


def test_ellipse_has_no_endpoints_like_circle():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, start.id, minor_radius=2.0)

    assert ellipse.endpoint_point_ids() is None


def test_delete_ellipse_removes_its_constraints_and_axis_lines():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, start.id, minor_radius=2.0)
    assert len(sketch.constraints) == 3

    sketch.delete_ellipse(ellipse.id)

    assert ellipse.id not in sketch.entities
    assert ellipse.major_axis_line_id not in sketch.entities
    assert ellipse.minor_axis_line_id not in sketch.entities
    assert sketch.constraints == {}
    # The Points themselves are left untouched, same as delete_line/delete_circle.
    assert center.id in sketch.points


def test_delete_ellipse_is_a_no_op_if_an_axis_line_was_already_deleted_directly():
    """Bug fix: a real, on-device 404 - an axis Line can be deleted
    directly (its own DELETE has no notion of "still owned by an
    Ellipse"), so it may already be gone by the time delete_ellipse runs.
    That must not raise (see delete_ellipse's own comment)."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, start.id, minor_radius=2.0)
    sketch.delete_line(ellipse.major_axis_line_id)

    sketch.delete_ellipse(ellipse.id)

    assert ellipse.id not in sketch.entities
    assert ellipse.minor_axis_line_id not in sketch.entities
    assert ellipse.major_point_id in sketch.points
    assert ellipse.minor_point_id in sketch.points


def test_point_deletion_is_blocked_while_referenced_by_an_ellipse():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, start.id, minor_radius=2.0)

    with pytest.raises(ValueError):
        sketch.delete_point(center.id)
    with pytest.raises(ValueError):
        sketch.delete_point(start.id)
    with pytest.raises(ValueError):
        sketch.delete_point(ellipse.minor_point_id)


# --- Profile detection -------------------------------------------------------


def test_standalone_ellipse_is_a_closed_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(10.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, start.id, minor_radius=4.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert result.profile.line_ids == [ellipse.id]


def test_ellipse_hole_inside_a_rectangle_is_detected_as_a_nested_profile():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(50.0, 0.0)
    c = sketch.add_point(50.0, 30.0)
    d = sketch.add_point(0.0, 30.0)
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)
    sketch.add_line(c.id, d.id)
    sketch.add_line(d.id, a.id)

    hole_center = sketch.add_point(25.0, 15.0)
    hole_major = sketch.add_point(35.0, 15.0)
    sketch.add_ellipse(hole_center.id, hole_major.id, minor_radius=5.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert len(result.profile.inner_loops) == 1


def test_ellipse_outside_a_rectangle_is_a_disjoint_multi_profile():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    d = sketch.add_point(0.0, 10.0)
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)
    sketch.add_line(c.id, d.id)
    sketch.add_line(d.id, a.id)

    far_center = sketch.add_point(100.0, 0.0)
    far_major = sketch.add_point(105.0, 0.0)
    sketch.add_ellipse(far_center.id, far_major.id, minor_radius=2.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 2


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_ellipse_from_existing_major_point_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 8.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 3.0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "ellipse"
    assert body["center_point_id"] == center["id"]
    assert body["major_point_id"] == major["id"]
    assert body["major_radius"] == pytest.approx(8.0)
    assert body["minor_radius"] == pytest.approx(3.0)
    assert body["rotation"] == pytest.approx(0.0)


def test_create_ellipse_from_major_radius_and_angle_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={
            "center_point_id": center["id"],
            "major_radius": 6.0,
            "angle": math.pi / 2,
            "minor_radius": 2.0,
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["major_radius"] == pytest.approx(6.0)
    assert body["rotation"] == pytest.approx(math.pi / 2)


def test_create_ellipse_requires_major_point_id_or_major_radius_and_angle():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "minor_radius": 2.0},
    )

    assert response.status_code == 422


def test_create_ellipse_rejects_both_major_point_id_and_major_radius():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 8.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "major_radius": 8.0,
            "angle": 0.0,
            "minor_radius": 2.0,
        },
    )

    assert response.status_code == 422


def test_create_ellipse_rejects_minor_radius_exceeding_major_radius_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 5.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 9.0},
    )

    assert response.status_code == 400


def test_create_ellipse_with_unknown_center_point_is_404():
    sketch = _create_sketch()
    major = _create_point(sketch["id"], 5.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": "does-not-exist", "major_point_id": major["id"], "minor_radius": 2.0},
    )
    assert response.status_code == 404


def test_get_ellipse_round_trip():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 3.0},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipses/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_ellipse_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipses/does-not-exist")
    assert response.status_code == 404


def test_list_ellipses_returns_every_ellipse_in_the_sketch():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    ellipse = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 3.0},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipses")

    assert response.status_code == 200
    assert [e["id"] for e in response.json()] == [ellipse["id"]]


def test_update_ellipse_minor_radius_by_patching_its_distance_constraint_over_the_api():
    """Feedback round: minor_radius is no longer a field on EllipseUpdate -
    like Circle/Arc's own radius, it's edited by PATCHing its backing
    DistanceConstraint (`minor_constraint_id`) via the ordinary
    `/constraints/{id}` endpoint."""
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    ellipse = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 3.0},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{_minor_constraint_id(sketch['id'], ellipse['id'])}",
        json={"value": 5.0},
    )
    assert response.status_code == 200

    updated = client.get(f"/sketch/sketches/{sketch['id']}/ellipses/{ellipse['id']}").json()
    assert updated["minor_radius"] == pytest.approx(5.0)


def _minor_constraint_id(sketch_id: str, ellipse_id: str) -> str:
    constraints = client.get(f"/sketch/sketches/{sketch_id}/constraints").json()
    ellipse = client.get(f"/sketch/sketches/{sketch_id}/ellipses/{ellipse_id}").json()
    for constraint in constraints:
        if (
            constraint["type"] == "distance"
            and {constraint["point_a_id"], constraint["point_b_id"]}
            == {ellipse["center_point_id"], ellipse["minor_point_id"]}
        ):
            return constraint["id"]
    raise AssertionError("minor radius DistanceConstraint not found")


def test_delete_ellipse_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    ellipse = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 3.0},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/ellipses/{ellipse['id']}")
    assert response.status_code == 204

    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipses/{ellipse['id']}")
    assert response.status_code == 404


def test_creating_an_ellipse_over_the_api_creates_a_solvable_constraint():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 6.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 2.0},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["converged"] is True


def test_standalone_ellipse_profile_detection_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 10.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 4.0},
    )

    response = client.get(f"/sketch/sketches/{sketch['id']}/profile")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "closed_loop"
    assert len(body["profile"]["line_ids"]) == 1


# --- Extrude (Ellipse wire construction) --------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


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


def test_extruding_a_standalone_ellipse_profile_produces_a_non_empty_computed_mesh():
    """The Ellipse wire-construction path in app.document.extrude.
    wire_for_profile (gp_Elips, via _ellipse_axis), exercised end-to-end
    through a real extrude - confirms it produces a valid, meshable solid,
    the same shape of check test_stage16_arc.py runs for its own mixed
    Line/Arc stadium wire path."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    center = _create_point(sketch_feature["sketch_id"], 0.0, 0.0)
    major = _create_point(sketch_feature["sketch_id"], 15.0, 0.0)
    assert client.post(
        f"/sketch/sketches/{sketch_feature['sketch_id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 8.0},
    ).status_code == 201

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0


def test_extruding_a_rotated_ellipse_profile_produces_a_non_empty_computed_mesh():
    """A rotated Ellipse (major axis not aligned with the sketch's local
    +X) exercises _ellipse_axis's explicit X-reference-direction rotation
    math, not just the angle=0 identity case above."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    center = _create_point(sketch_feature["sketch_id"], 0.0, 0.0)
    major = _create_point(sketch_feature["sketch_id"], 10.0, 10.0)
    assert client.post(
        f"/sketch/sketches/{sketch_feature['sketch_id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 4.0},
    ).status_code == 201

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0
