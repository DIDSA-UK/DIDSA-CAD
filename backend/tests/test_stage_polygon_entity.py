import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import _entity_from_dict, _entity_to_dict
from app.main import app
from app.sketch.models import Plane, Polygon, Sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _dist(sketch: Sketch, a_id: str, b_id: str) -> float:
    a, b = sketch.points[a_id], sketch.points[b_id]
    return math.hypot(b.x - a.x, b.y - a.y)


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_polygon_creates_the_full_constraint_chain_atomically():
    """A hexagon: 5 new vertex Points (the first is passed in), 6 Lines, 1
    real radius DistanceConstraint, 5 EqualRadiusConstraints, 5
    EqualLengthConstraints, 5 AngleConstraints - see the Polygon class
    docstring for why each family exists."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    points_before = len(sketch.points)

    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)

    assert isinstance(polygon, Polygon)
    assert polygon.sides == 6
    assert polygon.center_point_id == center.id
    assert polygon.vertex_point_ids[0] == first_vertex.id
    assert len(polygon.vertex_point_ids) == 6
    assert len(set(polygon.vertex_point_ids)) == 6, "every vertex must be a distinct point"
    assert len(sketch.points) == points_before + 5, "5 new vertices, the first was already given"
    assert len(polygon.line_ids) == 6
    assert len(polygon.equal_radius_constraint_ids) == 5
    assert len(polygon.equal_length_constraint_ids) == 5
    assert len(polygon.angle_constraint_ids) == 5
    assert polygon.radius_constraint_id in sketch.constraints
    assert polygon.radius(sketch.points) == pytest.approx(10.0)


def test_add_polygon_vertices_land_on_the_expected_regular_polygon():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)

    polygon = sketch.add_polygon(center.id, first_vertex.id, 4)

    expected = [(10.0, 0.0), (0.0, 10.0), (-10.0, 0.0), (0.0, -10.0)]
    for vertex_id, (ex, ey) in zip(polygon.vertex_point_ids, expected):
        point = sketch.points[vertex_id]
        assert point.x == pytest.approx(ex, abs=1e-9)
        assert point.y == pytest.approx(ey, abs=1e-9)


def test_add_polygon_rejects_fewer_than_3_sides():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_polygon(center.id, first_vertex.id, 2)


def test_add_polygon_rejects_first_vertex_coincident_with_center():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_polygon(center.id, center.id, 5)


def test_regular_polygon_stays_regular_after_an_anchored_vertex_drag():
    """The actual bug this entity exists to let the client fix correctly
    (see the Polygon class docstring): a real on-canvas drag of one vertex,
    anchored there, re-solved - every vertex must stay on the same circle
    and every edge the same length, proving the AngleConstraint chain
    genuinely keeps the shape rigid/regular, not just equal-length/
    equal-radius (which alone can still degenerate - see
    test_regular_hexagon_built_from_raw_points_stays_regular_after_a_
    vertex_drag in test_stage15_constraints.py)."""
    from app.sketch.solver import solve_sketch

    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False

    # A modest drag of one vertex - within the shape's own scale, like a
    # real on-canvas gesture, not an unrealistic teleport far outside it
    # (mirrors test_regular_hexagon_built_from_raw_points_stays_regular_
    # after_a_vertex_drag in test_stage15_constraints.py). vertex[2] starts
    # at (10*cos(120deg), 10*sin(120deg)) = (-5.0, 8.66).
    dragged_id = polygon.vertex_point_ids[2]
    sketch.points[dragged_id].x = -4.0
    sketch.points[dragged_id].y = 9.5
    result = solve_sketch(sketch, anchor_point_ids=frozenset({dragged_id}))

    assert result.converged
    radii = [_dist(sketch, center.id, v) for v in polygon.vertex_point_ids]
    assert all(r == pytest.approx(radii[0], abs=1e-6) for r in radii)
    lines = [sketch.entities[line_id] for line_id in polygon.line_ids]
    edge_lengths = [_dist(sketch, line.start_point_id, line.end_point_id) for line in lines]
    assert all(length == pytest.approx(edge_lengths[0], abs=1e-6) for length in edge_lengths)


def test_delete_polygon_removes_its_own_lines_and_constraints_but_not_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 5)
    points_before = set(sketch.points)

    sketch.delete_polygon(polygon.id)

    assert polygon.id not in sketch.entities
    for line_id in polygon.line_ids:
        assert line_id not in sketch.entities
    assert sketch.constraints == {}
    assert set(sketch.points) == points_before, "Points are never auto-deleted, even ones only this Polygon created"


def test_delete_polygon_line_already_gone_is_a_silent_no_op():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 5)
    sketch.delete_line(polygon.line_ids[0])

    sketch.delete_polygon(polygon.id)  # must not raise

    assert polygon.id not in sketch.entities


def test_point_deletion_is_blocked_while_referenced_by_a_polygon():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 5)

    with pytest.raises(ValueError):
        sketch.delete_point(center.id)
    with pytest.raises(ValueError):
        sketch.delete_point(polygon.vertex_point_ids[0])
    with pytest.raises(ValueError):
        sketch.delete_point(polygon.vertex_point_ids[3])  # a freshly-created-by-add_polygon vertex too


def test_polygon_native_format_round_trip_preserves_every_field():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 7, construction=True)

    round_tripped = _entity_from_dict(_entity_to_dict(polygon))

    assert isinstance(round_tripped, Polygon)
    assert round_tripped == polygon


# --- HTTP router tests --------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_polygon_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    first_vertex = _create_point(sketch["id"], 10.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": first_vertex["id"], "sides": 6},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "polygon"
    assert body["sides"] == 6
    assert body["center_point_id"] == center["id"]
    assert len(body["vertex_point_ids"]) == 6
    assert len(body["line_ids"]) == 6
    assert body["radius"] == pytest.approx(10.0)
    assert body["construction"] is False


def test_create_polygon_rejects_fewer_than_3_sides_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    first_vertex = _create_point(sketch["id"], 10.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": first_vertex["id"], "sides": 2},
    )

    assert response.status_code == 422


def test_create_polygon_rejects_degenerate_radius_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": center["id"], "sides": 5},
    )

    assert response.status_code == 400


def test_get_polygon_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/polygons/does-not-exist")
    assert response.status_code == 404


def test_list_polygons_returns_every_polygon_in_the_sketch():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    first_vertex = _create_point(sketch["id"], 10.0, 0.0)
    polygon = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": first_vertex["id"], "sides": 8},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/polygons")

    assert response.status_code == 200
    assert [p["id"] for p in response.json()] == [polygon["id"]]


def test_update_polygon_construction_flag_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    first_vertex = _create_point(sketch["id"], 10.0, 0.0)
    polygon = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": first_vertex["id"], "sides": 3},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/polygons/{polygon['id']}", json={"construction": True}
    )

    assert response.status_code == 200
    assert response.json()["construction"] is True


def test_delete_polygon_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    first_vertex = _create_point(sketch["id"], 10.0, 0.0)
    points_before = client.get(f"/sketch/sketches/{sketch['id']}/points").json()
    polygon = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": first_vertex["id"], "sides": 5},
    ).json()
    assert len(polygon["vertex_point_ids"]) == 5, "sanity check before comparing counts below"

    response = client.delete(f"/sketch/sketches/{sketch['id']}/polygons/{polygon['id']}")
    assert response.status_code == 204

    response = client.get(f"/sketch/sketches/{sketch['id']}/polygons/{polygon['id']}")
    assert response.status_code == 404

    # Every vertex Point (including the 4 add_polygon created fresh -
    # vertex_point_ids[1:], since [0] is the pre-existing first_vertex) is
    # still a real, listable Point - see the model-level "not points" test
    # above for the reasoning. Compared against the pre-creation count
    # (rather than a hardcoded one) since a Sketch may lazily materialize
    # its own origin Point independent of anything this test does.
    points_after = client.get(f"/sketch/sketches/{sketch['id']}/points").json()
    assert len(points_after) == len(points_before) + 4
