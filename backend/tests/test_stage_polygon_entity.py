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
    """A hexagon: 5 new vertex Points (the first is passed in), 6 edge
    Lines, 6 radial construction Lines (center to each vertex), 1 real
    radius DistanceConstraint, 5 EqualRadiusConstraints, 5 AngleConstraints
    between consecutive radial lines - see the Polygon class docstring for
    why each family exists (and why an EqualLengthConstraint per edge pair,
    and an edge-to-edge rather than radial-line-to-radial-line
    AngleConstraint, both present in an earlier design, are no longer among
    them)."""
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
    assert len(polygon.radial_line_ids) == 6
    assert len(set(polygon.radial_line_ids)) == 6, "every radial line must be a distinct entity"
    assert not set(polygon.radial_line_ids) & set(polygon.line_ids), "radial lines are not edges"
    for i, radial_line_id in enumerate(polygon.radial_line_ids):
        radial_line = sketch.entities[radial_line_id]
        assert radial_line.construction is True
        assert {radial_line.start_point_id, radial_line.end_point_id} == {
            center.id,
            polygon.vertex_point_ids[i],
        }
    assert len(polygon.equal_radius_constraint_ids) == 5
    assert len(polygon.angle_constraint_ids) == 5
    assert not hasattr(polygon, "equal_length_constraint_ids")
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


def test_add_polygon_with_reference_circles_creates_real_solver_tracked_circles():
    """On-device feedback ("when the toggle in the polygon tool is on, the
    2 construction circles should be drawn and visible to the user to
    dimension and use in the sketch - at the moment they are not shown
    after placing the polygon"): `reference_circles=True` must create two
    real, independently addressable Circles - a circumscribed one sharing
    the Polygon's own center/first-vertex Points directly, and an inscribed
    one whose own radius Point sits at the first edge's own midpoint (see
    the Polygon class's own docstring for why that's the exact inradius,
    with no separate constraint needed to keep it that way under drag -
    "driven", not "defining")."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)

    polygon = sketch.add_polygon(center.id, first_vertex.id, 6, reference_circles=True)

    assert polygon.circumscribed_circle_id is not None
    assert polygon.inscribed_circle_id is not None
    assert polygon.inscribed_midpoint_constraint_id is not None

    circumscribed = sketch.entities[polygon.circumscribed_circle_id]
    assert circumscribed.center_point_id == center.id
    assert circumscribed.radius_point_id == first_vertex.id

    inscribed = sketch.entities[polygon.inscribed_circle_id]
    assert inscribed.center_point_id == center.id
    inradius_point = sketch.points[inscribed.radius_point_id]
    actual_inradius = math.hypot(inradius_point.x - center.x, inradius_point.y - center.y)
    assert actual_inradius == pytest.approx(10.0 * math.cos(math.pi / 6))

    # The inscribed circle's own radius Point really is edge0's midpoint,
    # not just numerically coincidentally at the right distance.
    edge0 = sketch.entities[polygon.line_ids[0]]
    edge0_start = sketch.points[edge0.start_point_id]
    edge0_end = sketch.points[edge0.end_point_id]
    assert inradius_point.x == pytest.approx((edge0_start.x + edge0_end.x) / 2)
    assert inradius_point.y == pytest.approx((edge0_start.y + edge0_end.y) / 2)

    assert polygon.inscribed_midpoint_constraint_id in sketch.constraints


def test_add_polygon_without_reference_circles_creates_neither():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)

    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)

    assert polygon.circumscribed_circle_id is None
    assert polygon.inscribed_circle_id is None
    assert polygon.inscribed_midpoint_constraint_id is None


def test_delete_polygon_with_reference_circles_cleans_up_both_circles_and_the_midpoint_constraint():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6, reference_circles=True)
    circumscribed_id = polygon.circumscribed_circle_id
    inscribed_id = polygon.inscribed_circle_id
    midpoint_constraint_id = polygon.inscribed_midpoint_constraint_id
    radial_line_ids = list(polygon.radial_line_ids)

    sketch.delete_polygon(polygon.id)

    assert circumscribed_id not in sketch.entities
    assert inscribed_id not in sketch.entities
    assert midpoint_constraint_id not in sketch.constraints
    for radial_line_id in radial_line_ids:
        assert radial_line_id not in sketch.entities


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


@pytest.mark.parametrize("sides", [3, 4, 5, 6, 7, 8, 9, 10, 12])
def test_regular_polygon_stays_regular_after_a_modest_drag_at_every_vertex_and_side_count(sides):
    """Bug fix (found while root-causing the across-flats over-constrained
    report - see the Polygon class docstring): the *previous*, edge-to-edge
    AngleConstraint design only pins the *average* of each pair of
    neighbouring vertex-to-vertex arcs, not each one individually, and
    (confirmed directly against the real solver) regularly settles into a
    genuinely non-regular alternating-arc solution - equal radii, equal
    edge-to-edge turn angle, but *not* equal edge length - for an ordinary,
    modest single-vertex drag at plenty of side counts. The radial-line
    (center-to-vertex) AngleConstraint this replaces it with pins each
    vertex's own central angle directly, closing that gap - this test
    drags every single vertex of every side count 3-12 by a modest, real-
    on-canvas-scale amount and re-solves, asserting the shape lands back on
    a true regular polygon (equal radii *and* equal edge lengths) every
    time, not just most of the time."""
    from app.sketch.solver import solve_sketch

    for vertex_index in range(sides):
        sketch = Sketch(id="s", plane=Plane.XY)
        center = sketch.add_point(0.0, 0.0)
        first_vertex = sketch.add_point(10.0, 0.0)
        polygon = sketch.add_polygon(center.id, first_vertex.id, sides)
        sketch.constraints[polygon.radius_constraint_id].provisional = False

        dragged_id = polygon.vertex_point_ids[vertex_index]
        sketch.points[dragged_id].x += 1.2
        sketch.points[dragged_id].y -= 0.8
        result = solve_sketch(sketch, anchor_point_ids=frozenset({dragged_id}))

        assert result.converged, f"sides={sides} vertex_index={vertex_index}"
        radii = [_dist(sketch, center.id, v) for v in polygon.vertex_point_ids]
        assert all(r == pytest.approx(radii[0], abs=1e-5) for r in radii), f"sides={sides} vertex_index={vertex_index}"
        lines = [sketch.entities[line_id] for line_id in polygon.line_ids]
        edge_lengths = [_dist(sketch, line.start_point_id, line.end_point_id) for line in lines]
        assert all(
            length == pytest.approx(edge_lengths[0], abs=1e-5) for length in edge_lengths
        ), f"sides={sides} vertex_index={vertex_index}"


def test_delete_polygon_removes_its_own_lines_and_constraints_and_prunes_now_orphaned_points_but_leaves_a_still_shared_one():
    # Bug fix (pre-existing stale test - predates `_prune_orphaned_points`;
    # see test_delete_line_prunes_a_now_orphaned_endpoint's own comment in
    # test_stage6_delete.py): the center/vertex Points no longer
    # unconditionally survive their own Polygon's deletion. The centre
    # stays shared with an unrelated Line here.
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 5)
    other = sketch.add_point(50.0, 50.0)
    sketch.add_line(center.id, other.id)

    sketch.delete_polygon(polygon.id)

    assert polygon.id not in sketch.entities
    for line_id in (*polygon.line_ids, *polygon.radial_line_ids):
        assert line_id not in sketch.entities
    assert sketch.constraints == {}
    assert center.id in sketch.points
    for vertex_id in polygon.vertex_point_ids:
        assert vertex_id not in sketch.points


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


def test_collapse_polygon_removes_only_the_bookkeeping_record():
    """On-device feedback ("if an entity from a rectangle, slot, polygon
    is deleted it should collapse into lines and constraints"):
    collapse_polygon must leave every one of the Polygon's own Points/
    Lines/Constraints completely untouched - unlike delete_polygon, which
    cascades all of them away."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 5)
    entities_before = set(sketch.entities) - {polygon.id}
    constraints_before = set(sketch.constraints)
    points_before = set(sketch.points)

    sketch.collapse_polygon(polygon.id)

    assert polygon.id not in sketch.entities
    assert set(sketch.entities) == entities_before
    assert set(sketch.constraints) == constraints_before
    assert set(sketch.points) == points_before


def test_collapse_polygon_removes_the_polygon_specific_point_deletion_blocker():
    """The actual bug this exists to fix ("Point is still referenced by
    polygon ..."): once the Polygon record itself is collapsed, its own
    centre Point is no longer blocked *by it specifically* - checked
    directly against `_point_deletion_blocker`'s own return value (rather
    than a full end-to-end delete_point call).

    Uses `center_point_id`, not a vertex: every vertex is also a real
    edge Line's endpoint, and `_point_deletion_blocker` checks Line
    references before Polygon ones, so a vertex's message would say
    "line" regardless of whether the Polygon record still exists. The
    centre Point is referenced by nothing but the Polygon entity itself
    in the entity scan (its ties to the radius/equal-radius constraints
    are Constraint references, checked only after every entity type), so
    it's the one point where "polygon" being in the blocker message
    actually depends on the Polygon record still existing."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 5)

    blocker = sketch._point_deletion_blocker(polygon.center_point_id)
    assert blocker is not None
    assert "polygon" in blocker

    sketch.collapse_polygon(polygon.id)

    blocker_after = sketch._point_deletion_blocker(polygon.center_point_id)
    # Still blocked - the radius/equal-radius Constraints tying it to
    # each vertex - but no longer by the (now-gone) Polygon record.
    assert blocker_after is not None
    assert "polygon" not in blocker_after
    # Everything the Polygon used to own survives untouched.
    for line_id in polygon.line_ids:
        assert line_id in sketch.entities
    for vertex_id in polygon.vertex_point_ids:
        assert vertex_id in sketch.points


def test_collapse_polygon_rejects_an_unknown_id():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.collapse_polygon("does-not-exist")


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
    assert len(body["radial_line_ids"]) == 6
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
    # Bug fix (pre-existing stale test - predates `DeleteEntityResponse`/
    # `_prune_orphaned_points`; see test_delete_line_over_the_api's own
    # comment in test_stage6_delete.py): the center is kept shared with an
    # unrelated Line to survive; every vertex is now genuinely orphaned and
    # pruned, reported via `pruned_point_ids`.
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    first_vertex = _create_point(sketch["id"], 10.0, 0.0)
    other = _create_point(sketch["id"], 50.0, 50.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": center["id"], "end_point_id": other["id"]},
    )
    points_before = client.get(f"/sketch/sketches/{sketch['id']}/points").json()
    polygon = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": first_vertex["id"], "sides": 5},
    ).json()
    assert len(polygon["vertex_point_ids"]) == 5, "sanity check before comparing counts below"

    response = client.delete(f"/sketch/sketches/{sketch['id']}/polygons/{polygon['id']}")
    assert response.status_code == 200
    assert set(response.json()["pruned_point_ids"]) == set(polygon["vertex_point_ids"])

    response = client.get(f"/sketch/sketches/{sketch['id']}/polygons/{polygon['id']}")
    assert response.status_code == 404

    # The centre, still shared with the Line, survives; every vertex
    # (including the pre-existing `first_vertex`, itself now genuinely
    # orphaned too) was pruned above - one fewer than the pre-Polygon count.
    points_after = client.get(f"/sketch/sketches/{sketch['id']}/points").json()
    assert len(points_after) == len(points_before) - 1


def test_collapse_polygon_over_the_api_leaves_its_own_lines_and_vertices_in_place():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    first_vertex = _create_point(sketch["id"], 10.0, 0.0)
    polygon = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": first_vertex["id"], "sides": 5},
    ).json()

    response = client.post(f"/sketch/sketches/{sketch['id']}/polygons/{polygon['id']}/collapse")

    assert response.status_code == 204
    assert client.get(f"/sketch/sketches/{sketch['id']}/polygons/{polygon['id']}").status_code == 404
    assert client.get(f"/sketch/sketches/{sketch['id']}/lines/{polygon['line_ids'][0]}").status_code == 200
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{polygon['vertex_point_ids'][1]}").status_code == 200


def test_collapse_polygon_not_found_over_the_api():
    sketch = _create_sketch()
    response = client.post(f"/sketch/sketches/{sketch['id']}/polygons/does-not-exist/collapse")
    assert response.status_code == 404
