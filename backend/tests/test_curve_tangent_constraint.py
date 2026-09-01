"""Tests for CurveTangentConstraint (two Arcs meeting smoothly at a shared
endpoint - the curve-curve sibling of TangentConstraint, which only ever
pins a Circle/Arc against a Line). See app.sketch.constraints.
CurveTangentConstraint's own docstring for why this only ever takes two
Arcs (never a Circle, which has no endpoint Point to share) and why the
tangency condition is expressed as "the shared Point is collinear with both
centres" rather than any radius-equality term.

Mirrors test_stage15_constraints.py's own structure for TangentConstraint -
pure domain-model tests first (no HTTP, no solver), then a real
solve_sketch convergence test, then the HTTP layer.
"""

import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import _constraint_from_dict, _constraint_to_dict
from app.main import app
from app.sketch.constraints import CurveTangentConstraint
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _two_connected_arcs(sketch: Sketch):
    """arc1: centre (0,0), radius 3, sweeping from (3,0) to (0,3). arc2
    shares arc1's own end Point (0,3) as its own start Point, centred at
    (-2,3) (radius 2) - deliberately *not* already tangent there (centre1,
    the shared Point, and centre2 aren't collinear: centre1/shared sit on
    the y-axis, centre2 sits off it at x=-2), so a solve actually has to
    move something to satisfy a CurveTangentConstraint between them."""
    center1 = sketch.add_point(0.0, 0.0)
    start1 = sketch.add_point(3.0, 0.0)
    arc1 = sketch.add_arc(center1.id, start1.id, end_angle=math.pi / 2)
    shared = sketch.points[arc1.end_point_id]

    center2 = sketch.add_point(-2.0, 3.0)
    arc2 = sketch.add_arc(center2.id, shared.id, end_angle=math.pi)
    return arc1, arc2, center1, center2, shared


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_curve_tangent_constraint_between_two_arcs_sharing_an_endpoint():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc1, arc2, center1, center2, shared = _two_connected_arcs(sketch)

    constraint = sketch.add_curve_tangent_constraint(arc1.id, arc2.id, shared.id)

    assert constraint.id in sketch.constraints
    assert isinstance(constraint, CurveTangentConstraint)
    assert constraint.entity1_id == arc1.id
    assert constraint.entity2_id == arc2.id
    assert constraint.center1_point_id == center1.id
    assert constraint.center2_point_id == center2.id
    assert constraint.shared_point_id == shared.id
    assert constraint.point_ids() == (center1.id, center2.id, shared.id)
    assert constraint.type == "curve_tangent"


def test_add_curve_tangent_constraint_rejects_a_point_that_isnt_actually_shared():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc1, arc2, _center1, _center2, _shared = _two_connected_arcs(sketch)

    with pytest.raises(ValueError):
        sketch.add_curve_tangent_constraint(arc1.id, arc2.id, arc1.start_point_id)


def test_add_curve_tangent_constraint_rejects_a_circle():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc1, _arc2, _center1, _center2, shared = _two_connected_arcs(sketch)
    circle_center = sketch.add_point(20.0, 20.0)
    circle = sketch.add_circle(circle_center.id, radius=4.0, angle=0.0)

    with pytest.raises(KeyError):
        sketch.add_curve_tangent_constraint(arc1.id, circle.id, shared.id)


def test_add_curve_tangent_constraint_with_unknown_entity_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc1, _arc2, _center1, _center2, shared = _two_connected_arcs(sketch)

    with pytest.raises(KeyError):
        sketch.add_curve_tangent_constraint(arc1.id, "does-not-exist", shared.id)


# --- Solver convergence ------------------------------------------------------


def test_curve_tangent_constraint_pulls_the_second_centre_onto_the_tangent_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc1, arc2, center1, center2, shared = _two_connected_arcs(sketch)
    sketch.add_curve_tangent_constraint(arc1.id, arc2.id, shared.id)
    # Anchor arc1's own circle in place - center1 and its own start Point
    # fully determine it - so the solve has exactly one meaningful thing
    # left to do: move center2 (and, along with it, arc2's own end Point)
    # into a tangent configuration.
    sketch.add_fixed_constraint(center1.id)
    sketch.add_fixed_constraint(arc1.start_point_id)
    sketch.add_fixed_constraint(shared.id)

    result = solve_sketch(sketch)

    assert result.converged
    c1 = sketch.points[center1.id]
    c2 = sketch.points[center2.id]
    p = sketch.points[shared.id]
    # Collinearity: the cross product of (p - c1) and (c2 - c1) is ~0.
    cross = (p.x - c1.x) * (c2.y - c1.y) - (p.y - c1.y) * (c2.x - c1.x)
    assert cross == pytest.approx(0.0, abs=1e-6)


# --- native_format round-trip -------------------------------------------------


def test_curve_tangent_constraint_round_trips_through_native_format():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc1, arc2, _center1, _center2, shared = _two_connected_arcs(sketch)
    constraint = sketch.add_curve_tangent_constraint(arc1.id, arc2.id, shared.id)

    data = _constraint_to_dict(constraint)
    assert data["type"] == "curve_tangent"
    restored = _constraint_from_dict(data)

    assert isinstance(restored, CurveTangentConstraint)
    assert restored == constraint


# --- HTTP layer ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _create_arc(sketch_id: str, center_id: str, start_id: str, *, end_angle: float) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/arcs",
        json={"center_point_id": center_id, "start_point_id": start_id, "end_angle": end_angle},
    )
    assert response.status_code == 201
    return response.json()


def test_create_curve_tangent_constraint_over_the_api():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    start1 = _create_point(sketch["id"], 3.0, 0.0)
    arc1 = _create_arc(sketch["id"], center1["id"], start1["id"], end_angle=math.pi / 2)
    center2 = _create_point(sketch["id"], -2.0, 3.0)
    arc2 = _create_arc(sketch["id"], center2["id"], arc1["end_point_id"], end_angle=math.pi)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "curve_tangent",
            "entity1_id": arc1["id"],
            "entity2_id": arc2["id"],
            "shared_point_id": arc1["end_point_id"],
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "curve_tangent"
    assert body["entity1_id"] == arc1["id"]
    assert body["entity2_id"] == arc2["id"]
    assert body["center1_point_id"] == center1["id"]
    assert body["center2_point_id"] == center2["id"]
    assert body["shared_point_id"] == arc1["end_point_id"]


def test_create_curve_tangent_constraint_with_unknown_entity_is_404():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    start1 = _create_point(sketch["id"], 3.0, 0.0)
    arc1 = _create_arc(sketch["id"], center1["id"], start1["id"], end_angle=math.pi / 2)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "curve_tangent",
            "entity1_id": arc1["id"],
            "entity2_id": "does-not-exist",
            "shared_point_id": arc1["end_point_id"],
        },
    )

    assert response.status_code == 404


def test_create_curve_tangent_constraint_with_non_shared_point_is_400():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    start1 = _create_point(sketch["id"], 3.0, 0.0)
    arc1 = _create_arc(sketch["id"], center1["id"], start1["id"], end_angle=math.pi / 2)
    center2 = _create_point(sketch["id"], -2.0, 3.0)
    arc2 = _create_arc(sketch["id"], center2["id"], arc1["end_point_id"], end_angle=math.pi)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={
            "type": "curve_tangent",
            "entity1_id": arc1["id"],
            "entity2_id": arc2["id"],
            "shared_point_id": start1["id"],
        },
    )

    assert response.status_code == 400


# --- Point-deletion interaction (matches TangentConstraint/ConcentricConstraint's
# --- own pre-existing "a Point referenced by any Constraint is never pruned
# --- automatically" behavior - see Sketch._point_deletion_blocker's own doc
# --- comment) --------------------------------------------------------------


def test_deleting_an_arc_leaves_its_centre_behind_while_the_tangent_constraint_still_needs_it():
    sketch = Sketch(id="s", plane=Plane.XY)
    arc1, arc2, center1, _center2, shared = _two_connected_arcs(sketch)
    sketch.add_curve_tangent_constraint(arc1.id, arc2.id, shared.id)

    sketch.delete_arc(arc1.id)

    assert arc1.id not in sketch.entities
    # center1 is still referenced by the CurveTangentConstraint, so pruning
    # must leave it behind - same convention every other Point-referencing
    # Constraint here already relies on.
    assert center1.id in sketch.points
