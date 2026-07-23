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

    # The radius constraint, plus two auxiliary constraints (EqualRadius +
    # a zero-value axis DistanceConstraint) per cardinal point - see
    # Circle.cardinal_constraint_ids' own docstring.
    assert len(sketch.constraints) == 1 + len(circle.cardinal_constraint_ids)
    constraint = sketch.constraints[circle.radius_constraint_id]
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
    # Bug fix (pre-existing stale test - predates provisional size
    # constraints; see DistanceConstraint.provisional's own doc comment): a
    # freshly-`add_circle`d radius constraint starts provisional, which the
    # solver deliberately skips until confirmed - this must be flipped
    # first, or there is nothing pulling the radius point back to 5.0 at
    # all.
    sketch.constraints[circle.radius_constraint_id].provisional = False

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


# --- Cardinal points ----------------------------------------------------------


def test_add_circle_creates_four_cardinal_points_in_north_east_south_west_order():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    assert len(circle.cardinal_point_ids) == 4
    north, east, south, west = (sketch.points[pid] for pid in circle.cardinal_point_ids)
    assert (north.x, north.y) == pytest.approx((0.0, 5.0))
    assert (east.x, east.y) == pytest.approx((5.0, 0.0))
    assert (south.x, south.y) == pytest.approx((0.0, -5.0))
    assert (west.x, west.y) == pytest.approx((-5.0, 0.0))
    # Every id is unique and distinct from the center/radius points.
    all_ids = {circle.center_point_id, circle.radius_point_id, *circle.cardinal_point_ids}
    assert len(all_ids) == 6


def test_cardinal_points_stay_on_circle_after_moving_center():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    # Bug fix - see test_solving_satisfies_the_circle_radius_constraint's
    # own comment.
    sketch.constraints[circle.radius_constraint_id].provisional = False

    sketch.points[center.id].x = 100.0
    sketch.points[center.id].y = -50.0
    result = solve_sketch(sketch)
    assert result.converged

    new_center = sketch.points[center.id]
    north, east, south, west = (sketch.points[pid] for pid in circle.cardinal_point_ids)
    assert (north.x, north.y) == pytest.approx((new_center.x, new_center.y + 5.0))
    assert (east.x, east.y) == pytest.approx((new_center.x + 5.0, new_center.y))
    assert (south.x, south.y) == pytest.approx((new_center.x, new_center.y - 5.0))
    assert (west.x, west.y) == pytest.approx((new_center.x - 5.0, new_center.y))


def test_cardinal_points_track_a_radius_edit_via_equal_radius():
    """The cardinal points are tied to the *same* solver-tracked radius
    value as radius_point_id (via EqualRadiusConstraint), not a second,
    independently-editable distance - editing the circle's own radius
    constraint must move all four in sync, with nothing else to PATCH."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    # Bug fix - see test_solving_satisfies_the_circle_radius_constraint's
    # own comment: must be confirmed (non-provisional) before the solver
    # will honour the edited distance at all.
    sketch.constraints[circle.radius_constraint_id].provisional = False
    sketch.constraints[circle.radius_constraint_id].distance = 12.0
    result = solve_sketch(sketch)
    assert result.converged

    for point in (sketch.points[pid] for pid in circle.cardinal_point_ids):
        assert math.hypot(point.x - center.x, point.y - center.y) == pytest.approx(12.0)


def test_delete_circle_removes_cardinal_constraints_but_leaves_a_still_shared_cardinal_point():
    # Bug fix (pre-existing stale test - predates `_prune_orphaned_points`;
    # see test_delete_line_prunes_a_now_orphaned_endpoint's own comment in
    # test_stage6_delete.py): cardinal Points no longer unconditionally
    # survive their own Circle's deletion - only if something else still
    # references them. North stays shared with an unrelated Line here.
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    cardinal_point_ids = list(circle.cardinal_point_ids)
    cardinal_constraint_ids = list(circle.cardinal_constraint_ids)
    other = sketch.add_point(20.0, 20.0)
    sketch.add_line(cardinal_point_ids[0], other.id)

    sketch.delete_circle(circle.id)

    assert circle.id not in sketch.entities
    for constraint_id in cardinal_constraint_ids:
        assert constraint_id not in sketch.constraints
    assert cardinal_point_ids[0] in sketch.points
    for point_id in cardinal_point_ids[1:]:
        assert point_id not in sketch.points


# --- Centre-point circle tool: radius point becomes north cardinal point ----


def test_add_circle_with_bare_radius_unifies_radius_point_with_north_cardinal():
    """The centre-point circle tool's own mode (radius alone, no
    radius_point_id, no angle) - the radius-defining Point is not a fifth,
    separately-floating Point; it IS the north cardinal point."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)

    circle = sketch.add_circle(center.id, radius=5.0)

    assert circle.radius_point_id == circle.cardinal_point_ids[0]
    north, east, south, west = (sketch.points[pid] for pid in circle.cardinal_point_ids)
    assert (north.x, north.y) == pytest.approx((0.0, 5.0))
    assert (east.x, east.y) == pytest.approx((5.0, 0.0))
    assert (south.x, south.y) == pytest.approx((0.0, -5.0))
    assert (west.x, west.y) == pytest.approx((-5.0, 0.0))
    # Only 5 Points total (center + 4 cardinals) - no separate radius Point.
    assert len(sketch.points) == 5


def test_add_circle_with_bare_radius_is_fully_constrained_by_one_dimension_and_a_grounded_centre():
    """The whole point of unifying the radius point with north: with the
    centre grounded (here, the Sketch's own origin) and just the one radius
    DistanceConstraint `add_circle` already auto-creates, the circle has
    zero remaining degrees of freedom - no separate angle constraint ever
    needs to be added by hand."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.origin_point()

    circle = sketch.add_circle(center.id, radius=5.0)
    # Bug fix - see test_solving_satisfies_the_circle_radius_constraint's
    # own comment: a still-provisional radius constraint contributes
    # nothing towards "fully constrained", which is exactly this test's own
    # point to prove - it must be confirmed first.
    sketch.constraints[circle.radius_constraint_id].provisional = False

    result = solve_sketch(sketch)
    assert result.converged
    assert result.dof == 0


def test_delete_circle_with_bare_radius_removes_norths_own_axis_constraint_too():
    # Bug fix - see test_delete_circle_removes_cardinal_constraints_but_
    # leaves_a_still_shared_cardinal_point's own comment above.
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)
    cardinal_point_ids = list(circle.cardinal_point_ids)
    other = sketch.add_point(20.0, 20.0)
    sketch.add_line(cardinal_point_ids[0], other.id)

    sketch.delete_circle(circle.id)

    assert circle.radius_constraint_id not in sketch.constraints
    for constraint_id in circle.cardinal_constraint_ids:
        assert constraint_id not in sketch.constraints
    assert cardinal_point_ids[0] in sketch.points
    for point_id in cardinal_point_ids[1:]:
        assert point_id not in sketch.points


def test_create_circle_from_bare_radius_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 5.0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["radius"] == pytest.approx(5.0)
    assert body["radius_point_id"] == body["cardinal_point_ids"][0]


# --- Profile detection -------------------------------------------------------


def test_standalone_circle_is_its_own_closed_profile():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    # Bug fix (pre-existing stale test - predates cardinal points, added
    # later purely as internal solver-tracked reference Points, never part
    # of the profile boundary itself): a Circle's own profile is just its
    # center/radius Points, not every Point `add_circle` happens to create.
    assert set(result.profile.point_ids) == {center.id, circle.radius_point_id}


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


def test_create_circle_rejects_radius_point_and_a_bare_radius_too():
    """Same "not both" rule as the radius+angle case above - a bare radius
    (no angle, the centre-point circle tool's own mode) alongside an
    explicit radius_point_id is just as invalid a combination."""
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    edge = _create_point(sketch["id"], 1.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius_point_id": edge["id"], "radius": 1.0},
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
