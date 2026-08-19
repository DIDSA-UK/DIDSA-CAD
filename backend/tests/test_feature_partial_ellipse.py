import json
import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.main import app
from app.sketch.models import EllipseArc, Plane, Sketch
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _ellipse_equation_residual(sketch: Sketch, arc: EllipseArc, point_id: str) -> float:
    center = sketch.points[arc.center_point_id]
    major = sketch.points[arc.major_point_id]
    minor = sketch.points[arc.minor_point_id]
    point = sketch.points[point_id]
    major_radius = math.hypot(major.x - center.x, major.y - center.y)
    minor_radius = math.hypot(minor.x - center.x, minor.y - center.y)
    rotation = math.atan2(major.y - center.y, major.x - center.x)
    dx, dy = point.x - center.x, point.y - center.y
    ca, sa = math.cos(-rotation), math.sin(-rotation)
    u = dx * ca - dy * sa
    v = dx * sa + dy * ca
    return (u / major_radius) ** 2 + (v / minor_radius) ** 2 - 1.0


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_ellipse_arc_places_start_and_end_at_the_given_parametric_angles():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)

    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.3, 2.0)

    assert isinstance(arc, EllipseArc)
    assert arc.local_angle(sketch.points, arc.start_point_id) == pytest.approx(0.3)
    assert arc.local_angle(sketch.points, arc.end_point_id) == pytest.approx(2.0)
    assert arc.major_radius(sketch.points) == pytest.approx(8.0)
    assert arc.minor_radius(sketch.points) == pytest.approx(3.0)
    assert arc.rotation(sketch.points) == pytest.approx(0.0)


def test_add_ellipse_arc_with_rotated_major_axis():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(-3.0, 5.0)
    rotation = math.radians(35)
    major = sketch.add_point(-3.0 + 7.0 * math.cos(rotation), 5.0 + 7.0 * math.sin(rotation))

    arc = sketch.add_ellipse_arc(center.id, major.id, 4.0, 0.5, 4.0)

    assert arc.rotation(sketch.points) == pytest.approx(rotation)
    assert _ellipse_equation_residual(sketch, arc, arc.start_point_id) == pytest.approx(0.0, abs=1e-9)
    assert _ellipse_equation_residual(sketch, arc, arc.end_point_id) == pytest.approx(0.0, abs=1e-9)


def test_add_ellipse_arc_rejects_same_center_and_major_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse_arc(center.id, center.id, 3.0, 0.0, 1.0)


def test_add_ellipse_arc_rejects_non_positive_minor_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse_arc(center.id, major.id, 0.0, 0.0, 1.0)


def test_add_ellipse_arc_rejects_minor_radius_exceeding_major_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(5.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse_arc(center.id, major.id, 9.0, 0.0, 1.0)


def test_add_ellipse_arc_rejects_coincident_start_and_end_angles():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse_arc(center.id, major.id, 3.0, 1.2, 1.2)
    with pytest.raises(ValueError):
        # Same angle modulo 2*pi is still degenerate, not a full ellipse.
        sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.5, 0.5 + 2 * math.pi)


def test_add_ellipse_arc_with_unknown_major_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_ellipse_arc(center.id, "does-not-exist", 3.0, 0.0, 1.0)


def test_ellipse_arc_endpoint_point_ids_are_start_and_end():
    """Unlike Ellipse (never a chain participant), EllipseArc overrides
    endpoint_point_ids() the same way Arc does - see EllipseArc's own
    docstring."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.0, 2.0)

    assert arc.endpoint_point_ids() == (arc.start_point_id, arc.end_point_id)


def test_delete_ellipse_arc_removes_its_constraints_axis_lines_and_prunes_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.3, 2.0)
    entity_count_before = len(sketch.entities)
    constraint_count_before = len(sketch.constraints)

    pruned = sketch.delete_ellipse_arc(arc.id)

    assert arc.id not in sketch.entities
    assert arc.major_axis_line_id not in sketch.entities
    assert arc.minor_axis_line_id not in sketch.entities
    assert arc.major_constraint_id not in sketch.constraints
    assert arc.minor_constraint_id not in sketch.constraints
    assert arc.perpendicular_constraint_id not in sketch.constraints
    assert arc.start_on_ellipse_constraint_id not in sketch.constraints
    assert arc.end_on_ellipse_constraint_id not in sketch.constraints
    assert entity_count_before - len(sketch.entities) == 3  # arc + 2 axis lines
    assert constraint_count_before - len(sketch.constraints) == 5
    assert set(pruned) == {center.id, major.id, arc.start_point_id, arc.end_point_id, arc.minor_point_id}
    assert len(sketch.points) == 0


def test_delete_ellipse_arc_on_unknown_id_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_ellipse_arc("does-not-exist")


# --- Solver: DOF / convergence -----------------------------------------------


def test_solving_a_fixed_ellipse_arc_converges_with_start_and_end_exactly_on_the_curve():
    """Regression test for the same kind of Fix-on-an-internally-
    constrained-entity redundancy PointOnEllipseConstraint's own feature
    surfaced for a plain Ellipse (see solver.py's Ellipse/EllipseArc
    override) - confirms it's fixed for EllipseArc too, not just Ellipse."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.3, 2.0)
    sketch.add_fixed_constraint(arc.id)

    result = solve_sketch(sketch)

    assert result.converged, result.detail
    assert _ellipse_equation_residual(sketch, arc, arc.start_point_id) == pytest.approx(0.0, abs=1e-6)
    assert _ellipse_equation_residual(sketch, arc, arc.end_point_id) == pytest.approx(0.0, abs=1e-6)
    assert sketch.points[center.id].x == pytest.approx(0.0)
    assert sketch.points[center.id].y == pytest.approx(0.0)


@pytest.mark.parametrize(
    "cx,cy,major_r,minor_r,rotation,start,end",
    [
        (0.0, 0.0, 8.0, 3.0, 0.0, 0.3, 2.0),
        (4.0, -2.0, 6.0, 2.0, math.radians(35), 0.5, 4.0),
        (0.0, 0.0, 5.0, 4.9, 0.0, -1.0, 1.0),
        (1.0, 1.0, 10.0, 1.5, math.radians(-70), 1.0, 5.5),
    ],
)
def test_solving_a_fixed_ellipse_arc_converges_across_varied_configurations(
    cx, cy, major_r, minor_r, rotation, start, end
):
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(cx, cy)
    major = sketch.add_point(cx + major_r * math.cos(rotation), cy + major_r * math.sin(rotation))
    arc = sketch.add_ellipse_arc(center.id, major.id, minor_r, start, end)
    sketch.add_fixed_constraint(arc.id)

    result = solve_sketch(sketch)

    assert result.converged, result.detail
    assert _ellipse_equation_residual(sketch, arc, arc.start_point_id) == pytest.approx(0.0, abs=1e-6)
    assert _ellipse_equation_residual(sketch, arc, arc.end_point_id) == pytest.approx(0.0, abs=1e-6)


# --- profile.py chain detection -----------------------------------------------


def test_line_and_ellipse_arc_chain_closes_into_a_single_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.0, math.pi)
    sketch.add_line(arc.end_point_id, arc.start_point_id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert arc.id in result.profile.line_ids


def test_ellipse_arc_alone_with_no_closing_line_is_not_a_closed_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.0, math.pi)

    result = detect_profile(sketch)

    assert result.status != ProfileStatus.CLOSED_LOOP


# --- HTTP API -----------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_ellipse_arc_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 8.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.3,
            "end_angle": 2.0,
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "ellipse_arc"
    assert body["center_point_id"] == center["id"]
    assert body["major_point_id"] == major["id"]
    assert body["major_radius"] == pytest.approx(8.0)
    assert body["minor_radius"] == pytest.approx(3.0)
    assert body["rotation"] == pytest.approx(0.0)


def test_create_ellipse_arc_rejects_minor_radius_exceeding_major_radius_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 5.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 9.0,
            "start_angle": 0.0,
            "end_angle": 1.0,
        },
    )

    assert response.status_code == 400


def test_create_ellipse_arc_with_unknown_center_point_is_404():
    sketch = _create_sketch()
    major = _create_point(sketch["id"], 5.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": "does-not-exist",
            "major_point_id": major["id"],
            "minor_radius": 2.0,
            "start_angle": 0.0,
            "end_angle": 1.0,
        },
    )
    assert response.status_code == 404


def test_get_ellipse_arc_round_trip():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.0,
            "end_angle": 2.0,
        },
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_ellipse_arc_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/does-not-exist")
    assert response.status_code == 404


def test_list_ellipse_arcs_returns_every_ellipse_arc_in_the_sketch():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.0,
            "end_angle": 2.0,
        },
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs")

    assert response.status_code == 200
    assert [entry["id"] for entry in response.json()] == [created["id"]]


def test_delete_ellipse_arc_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.0,
            "end_angle": 2.0,
        },
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/{created['id']}")

    assert response.status_code == 200
    assert set(response.json()["pruned_point_ids"]) >= {center["id"], major["id"]}
    assert client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/{created['id']}").status_code == 404


def test_creating_an_ellipse_arc_and_fixing_it_over_the_api_creates_a_solvable_constraint_set():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    arc = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.3,
            "end_angle": 2.0,
        },
    ).json()

    fix_resp = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "fixed", "entity_id": arc["id"]},
    )
    assert fix_resp.status_code == 201

    solve_resp = client.post(f"/sketch/sketches/{sketch['id']}/solve")
    assert solve_resp.status_code == 200
    assert solve_resp.json()["converged"] is True


# --- native_format.py round trip ----------------------------------------------


def test_ellipse_arc_round_trips_through_native_format_json():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.3, 2.0)
    sketch.add_fixed_constraint(arc.id)

    data = sketch_to_dict(sketch)
    restored = sketch_from_dict(json.loads(json.dumps(data)))

    restored_arc = restored.entities[arc.id]
    assert isinstance(restored_arc, EllipseArc)
    assert restored_arc.start_point_id == arc.start_point_id
    assert restored_arc.end_point_id == arc.end_point_id
    result = solve_sketch(restored)
    assert result.converged, result.detail


# --- extrude.py OCCT wire construction ----------------------------------------


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


def test_extruding_a_line_and_ellipse_arc_profile_produces_a_non_empty_computed_mesh():
    """The EllipseArc wire-construction branch in app.document.extrude.
    wire_for_profile (gp_Elips trimmed between two Points, via
    _ellipse_axis), exercised end-to-end through a real extrude - the
    partial-ellipse analogue of test_stage16_arc.py's own stadium-profile
    extrude check."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    center = _create_point(sketch_feature["sketch_id"], 0.0, 0.0)
    major = _create_point(sketch_feature["sketch_id"], 15.0, 0.0)
    arc = client.post(
        f"/sketch/sketches/{sketch_feature['sketch_id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 8.0,
            "start_angle": 0.0,
            "end_angle": math.pi,
        },
    ).json()
    assert client.post(
        f"/sketch/sketches/{sketch_feature['sketch_id']}/lines",
        json={"start_point_id": arc["end_point_id"], "end_point_id": arc["start_point_id"]},
    ).status_code == 201

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0
