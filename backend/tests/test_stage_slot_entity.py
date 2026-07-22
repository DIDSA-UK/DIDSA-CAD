import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import _entity_from_dict, _entity_to_dict
from app.main import app
from app.sketch.models import Plane, Sketch, Slot
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _dist(sketch: Sketch, a_id: str, b_id: str) -> float:
    a, b = sketch.points[a_id], sketch.points[b_id]
    return math.hypot(b.x - a.x, b.y - a.y)


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_slot_creates_the_full_constraint_chain_atomically():
    """2 Arcs, 2 straight Lines + 1 construction centreline, 1 real radius
    DistanceConstraint (arc1's own), 4 EqualRadiusConstraints (each Arc's
    own start<->end tie from add_arc, plus the 2 new cross-ties back to
    arc1), 4 TangentConstraints (one per Arc/Line pair) - see the Slot
    class docstring for why each family exists."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    points_before = len(sketch.points)

    slot = sketch.add_slot(center1.id, center2.id, 5.0)

    assert isinstance(slot, Slot)
    assert slot.center1_point_id == center1.id
    assert slot.center2_point_id == center2.id
    assert len(sketch.points) == points_before + 4, "4 new corner points (a/b/c/d)"
    assert len({slot.a_point_id, slot.b_point_id, slot.c_point_id, slot.d_point_id}) == 4
    assert len(slot.equal_radius_constraint_ids) == 4
    assert len(slot.tangent_constraint_ids) == 4
    assert slot.radius_constraint_id in sketch.constraints
    # arc2's own provisional radius DistanceConstraint was deleted, not left dangling.
    arc2 = sketch.entities[slot.arc2_id]
    assert arc2.radius_constraint_id not in sketch.constraints
    assert slot.radius(sketch.points) == pytest.approx(5.0)


def test_add_slot_corners_land_on_the_expected_geometry():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)

    slot = sketch.add_slot(center1.id, center2.id, 5.0)

    a = sketch.points[slot.a_point_id]
    b = sketch.points[slot.b_point_id]
    c = sketch.points[slot.c_point_id]
    d = sketch.points[slot.d_point_id]
    assert (a.x, a.y) == pytest.approx((0.0, 5.0))
    assert (b.x, b.y) == pytest.approx((0.0, -5.0))
    assert (c.x, c.y) == pytest.approx((20.0, -5.0))
    assert (d.x, d.y) == pytest.approx((20.0, 5.0))
    line1 = sketch.entities[slot.line1_id]
    line2 = sketch.entities[slot.line2_id]
    assert {line1.start_point_id, line1.end_point_id} == {slot.b_point_id, slot.c_point_id}
    assert {line2.start_point_id, line2.end_point_id} == {slot.d_point_id, slot.a_point_id}


def test_add_slot_rejects_zero_length_centerline():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_slot(center.id, center.id, 5.0)


def test_add_slot_rejects_non_positive_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_slot(center1.id, center2.id, 0.0)
    with pytest.raises(ValueError):
        sketch.add_slot(center1.id, center2.id, -5.0)


def test_slot_stays_a_valid_closed_stadium_after_an_anchored_corner_drag():
    """Mirrors test_regular_polygon_stays_regular_after_an_anchored_vertex_
    drag - the actual bug this entity exists to let the client fix
    correctly: a real, anchored re-solve must keep both Arcs' radii equal
    and both Arcs tangent to both Lines."""
    from app.sketch.solver import solve_sketch

    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    slot = sketch.add_slot(center1.id, center2.id, 5.0)
    sketch.constraints[slot.radius_constraint_id].provisional = False

    dragged_id = slot.a_point_id
    sketch.points[dragged_id].x = -2.0
    sketch.points[dragged_id].y = 7.0
    result = solve_sketch(sketch, anchor_point_ids=frozenset({dragged_id}))

    assert result.converged
    r1 = _dist(sketch, center1.id, slot.a_point_id)
    r2a = _dist(sketch, center1.id, slot.b_point_id)
    r2b = _dist(sketch, center2.id, slot.c_point_id)
    r2c = _dist(sketch, center2.id, slot.d_point_id)
    assert r2a == pytest.approx(r1, abs=1e-6)
    assert r2b == pytest.approx(r1, abs=1e-6)
    assert r2c == pytest.approx(r1, abs=1e-6)


def test_delete_slot_removes_its_own_entities_and_constraints():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    slot = sketch.add_slot(center1.id, center2.id, 5.0)

    sketch.delete_slot(slot.id)

    assert slot.id not in sketch.entities
    for entity_id in (slot.centerline_id, slot.arc1_id, slot.arc2_id, slot.line1_id, slot.line2_id):
        assert entity_id not in sketch.entities
    assert sketch.constraints == {}


def test_delete_slot_line_already_gone_is_a_silent_no_op():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    slot = sketch.add_slot(center1.id, center2.id, 5.0)
    sketch.delete_line(slot.line1_id)

    sketch.delete_slot(slot.id)  # must not raise

    assert slot.id not in sketch.entities


def test_point_deletion_is_blocked_while_referenced_by_a_slot():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    slot = sketch.add_slot(center1.id, center2.id, 5.0)

    with pytest.raises(ValueError):
        sketch.delete_point(center1.id)
    with pytest.raises(ValueError):
        sketch.delete_point(slot.a_point_id)
    with pytest.raises(ValueError):
        sketch.delete_point(slot.c_point_id)


def test_slot_native_format_round_trip_preserves_every_field():
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    slot = sketch.add_slot(center1.id, center2.id, 5.0, construction=True)

    round_tripped = _entity_from_dict(_entity_to_dict(slot))

    assert isinstance(round_tripped, Slot)
    assert round_tripped == slot


# --- HTTP router tests --------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_slot_over_the_api():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    center2 = _create_point(sketch["id"], 20.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/slots",
        json={"center1_point_id": center1["id"], "center2_point_id": center2["id"], "radius": 5.0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "slot"
    assert body["center1_point_id"] == center1["id"]
    assert body["center2_point_id"] == center2["id"]
    assert body["radius"] == pytest.approx(5.0)
    assert body["construction"] is False


def test_create_slot_rejects_non_positive_radius_over_the_api():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    center2 = _create_point(sketch["id"], 20.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/slots",
        json={"center1_point_id": center1["id"], "center2_point_id": center2["id"], "radius": 0.0},
    )

    assert response.status_code == 422


def test_create_slot_rejects_degenerate_centerline_over_the_api():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/slots",
        json={"center1_point_id": center1["id"], "center2_point_id": center1["id"], "radius": 5.0},
    )

    assert response.status_code == 400


def test_get_slot_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/slots/does-not-exist")
    assert response.status_code == 404


def test_list_slots_returns_every_slot_in_the_sketch():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    center2 = _create_point(sketch["id"], 20.0, 0.0)
    slot = client.post(
        f"/sketch/sketches/{sketch['id']}/slots",
        json={"center1_point_id": center1["id"], "center2_point_id": center2["id"], "radius": 5.0},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/slots")

    assert response.status_code == 200
    assert [s["id"] for s in response.json()] == [slot["id"]]


def test_update_slot_construction_flag_over_the_api():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    center2 = _create_point(sketch["id"], 20.0, 0.0)
    slot = client.post(
        f"/sketch/sketches/{sketch['id']}/slots",
        json={"center1_point_id": center1["id"], "center2_point_id": center2["id"], "radius": 5.0},
    ).json()

    response = client.patch(f"/sketch/sketches/{sketch['id']}/slots/{slot['id']}", json={"construction": True})

    assert response.status_code == 200
    assert response.json()["construction"] is True


def test_delete_slot_over_the_api():
    sketch = _create_sketch()
    center1 = _create_point(sketch["id"], 0.0, 0.0)
    center2 = _create_point(sketch["id"], 20.0, 0.0)
    slot = client.post(
        f"/sketch/sketches/{sketch['id']}/slots",
        json={"center1_point_id": center1["id"], "center2_point_id": center2["id"], "radius": 5.0},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/slots/{slot['id']}")
    assert response.status_code == 200

    assert client.get(f"/sketch/sketches/{sketch['id']}/slots/{slot['id']}").status_code == 404
