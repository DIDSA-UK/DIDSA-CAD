"""Minimum / maximum distance from a Point to a Circle or Arc (bug report 2026-11-18, part D, fourth type):
`PointCircleDistanceConstraint`.

One solver-only helper H on the line through the Point and the centre at the radius (`point_on_line` + `equal_length`: its two
unknowns, two equations), then `distance(Point, H) = value`. Covers min and max (outside and inside the circle), DOF (exactly one less,
nothing redundant), the side check (a solve that satisfies the helper on the wrong side is not converged), a drag, an Arc, the delete
cascade and Point Merge, the saved file, the routes and the driven kinds."""

import math

import pytest

from app.sketch.point_merge import MergeRefused, merge_points
from app.sketch.solver import solve_sketch
from tests.dimension_type_support import blockers, client, fixed_circle, http_sketch, new_sketch, round_trip


def _from_centre(sketch, circle, point_id) -> float:
    c, p = sketch.points[circle.center_point_id], sketch.points[point_id]
    return math.hypot(p.x - c.x, p.y - c.y)


@pytest.mark.parametrize(
    "start, side, value, centre_distance",
    [((10.0, 0.0), "min", 3.0, 8.0), ((10.0, 0.0), "max", 20.0, 15.0), ((2.0, 1.0), "min", 1.0, 4.0), ((2.0, 1.0), "max", 7.0, 2.0)],
)
def test_min_and_max_are_met_outside_and_inside(start, side, value, centre_distance):
    sketch = new_sketch()
    circle = fixed_circle(sketch)
    point = sketch.add_point(*start)
    sketch.add_point_circle_distance_constraint(point.id, circle.id, value, side)
    result = solve_sketch(sketch)
    assert result.converged and result.result_code == 0
    assert _from_centre(sketch, circle, point.id) == pytest.approx(centre_distance, abs=1e-6)


def test_dof_drops_by_exactly_one_the_helper_adds_none():
    sketch = new_sketch()
    circle = fixed_circle(sketch)
    point = sketch.add_point(10.0, 0.0)
    before = solve_sketch(sketch)
    sketch.add_point_circle_distance_constraint(point.id, circle.id, 3.0, "min")
    after = solve_sketch(sketch)
    assert after.converged and after.result_code == 0
    assert after.dof == before.dof - 1
    # Pin the Point's direction too: one less again, still no redundancy.
    sketch.add_horizontal_constraint(sketch.add_line(circle.center_point_id, point.id).id)
    pinned = solve_sketch(sketch)
    assert pinned.converged and pinned.result_code == 0 and pinned.dof == after.dof - 1


def test_the_side_check_a_minimum_given_the_maximums_value_is_not_converged():
    # The Point is fixed 10 from the centre of a radius-5 circle: the minimum is 5 and the maximum 15. A "minimum" of 15 can only be met
    # by the helper on the far side, which is the maximum: the solve must not call that converged.
    sketch = new_sketch()
    circle = fixed_circle(sketch)
    point = sketch.add_point(10.0, 0.0)
    sketch.add_fixed_constraint(point.id)
    sketch.add_point_circle_distance_constraint(point.id, circle.id, 15.0, "min")
    assert not solve_sketch(sketch).converged
    # The same value as a maximum is right.
    sketch = new_sketch()
    circle = fixed_circle(sketch)
    point = sketch.add_point(10.0, 0.0)
    sketch.add_fixed_constraint(point.id)
    sketch.add_point_circle_distance_constraint(point.id, circle.id, 15.0, "max")
    result = solve_sketch(sketch)
    assert result.converged


def test_a_drag_keeps_the_distance_and_the_circle_can_grow():
    sketch = new_sketch()
    center = sketch.add_point(0.0, 0.0)
    sketch.add_fixed_constraint(center.id)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)  # radius left provisional: free
    point = sketch.add_point(10.0, 0.0)
    sketch.add_fixed_constraint(point.id)
    sketch.add_point_circle_distance_constraint(point.id, circle.id, 2.0, "min")
    assert solve_sketch(sketch).converged
    assert circle.radius(sketch.points) == pytest.approx(8.0, abs=1e-6)


def test_an_arc_is_measured_as_its_circle():
    sketch = new_sketch()
    c = sketch.add_point(0.0, 0.0)
    s = sketch.add_point(5.0, 0.0)
    e = sketch.add_point(0.0, 5.0)
    arc = sketch.add_arc(c.id, s.id, e.id)
    sketch.constraints[arc.radius_constraint_id].provisional = False
    sketch.add_fixed_constraint(c.id)
    point = sketch.add_point(-9.0, -1.0)
    constraint = sketch.add_point_circle_distance_constraint(point.id, arc.id, 2.0, "min")
    assert constraint.radius_point_id == s.id
    assert solve_sketch(sketch).converged
    assert math.hypot(sketch.points[point.id].x, sketch.points[point.id].y) == pytest.approx(7.0, abs=1e-6)


def test_refused_for_the_circles_own_points_the_centre_and_bad_values():
    sketch = new_sketch()
    circle = fixed_circle(sketch)
    with pytest.raises(ValueError):
        sketch.add_point_circle_distance_constraint(circle.radius_point_id, circle.id, 2.0)
    at_centre = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_point_circle_distance_constraint(at_centre.id, circle.id, 2.0)
    point = sketch.add_point(9.0, 0.0)
    for bad in (0.0, -1.0):
        with pytest.raises(ValueError):
            sketch.add_point_circle_distance_constraint(point.id, circle.id, bad)
    with pytest.raises(ValueError):
        sketch.add_point_circle_distance_constraint(point.id, circle.id, 2.0, "middle")


def test_point_ids_list_the_point_the_centre_and_the_radius_point_and_block_deletion():
    sketch = new_sketch()
    circle = fixed_circle(sketch)
    point = sketch.add_point(10.0, 0.0)
    constraint = sketch.add_point_circle_distance_constraint(point.id, circle.id, 3.0)
    assert set(constraint.point_ids()) == {point.id, circle.center_point_id, circle.radius_point_id}
    assert f"referenced by {sketch.name_of(constraint.id)}" in blockers(sketch, [point.id])[point.id]
    probe = round_trip(sketch)
    probe.delete_circle(circle.id)
    assert circle.center_point_id in probe.points and circle.radius_point_id in probe.points  # still held by the dimension
    del sketch.constraints[constraint.id]
    assert blockers(sketch, [point.id])[point.id] is None


def test_point_merge_rewrites_and_refuses_onto_the_circle():
    sketch = new_sketch()
    circle = fixed_circle(sketch)
    point = sketch.add_point(10.0, 0.0)
    constraint = sketch.add_point_circle_distance_constraint(point.id, circle.id, 3.0)
    assert solve_sketch(sketch).converged
    p = sketch.points[point.id]
    loose = sketch.add_point(p.x, p.y)
    sketch.add_line(loose.id, sketch.add_point(p.x, p.y + 4.0).id)
    kept = merge_points(sketch, [loose.id, point.id]).kept_id
    assert constraint.point_id == kept
    assert solve_sketch(sketch).converged
    with pytest.raises(MergeRefused):
        merge_points(sketch, [kept, circle.center_point_id])


def test_saved_and_loaded():
    sketch = new_sketch()
    circle = fixed_circle(sketch)
    point = sketch.add_point(10.0, 0.0)
    constraint = sketch.add_point_circle_distance_constraint(point.id, circle.id, 20.0, "max")
    loaded = round_trip(sketch)
    assert loaded.constraints[constraint.id] == constraint
    assert solve_sketch(loaded).converged
    assert _from_centre(loaded, circle, point.id) == pytest.approx(15.0, abs=1e-6)


def test_routes_create_update_and_the_driven_kinds():
    sketch_id, sketch = http_sketch()
    centre = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()
    circle = client.post(f"/sketch/sketches/{sketch_id}/circles", json={"center_point_id": centre["id"], "radius": 5.0}).json()
    point = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10.0, "y": 0.0}).json()
    made = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "point_circle_distance", "point_id": point["id"], "circle_or_arc_id": circle["id"], "distance": 3.0, "side": "min"},
    )
    assert made.status_code == 201, made.text
    body = made.json()
    assert (body["side"], body["center_point_id"], body["radius_point_id"]) == ("min", centre["id"], circle["radius_point_id"])
    solved = client.patch(f"/sketch/sketches/{sketch_id}/constraints/{body['id']}", json={"value": 4.0})
    assert solved.status_code == 200 and solved.json()["converged"], solved.text
    assert client.patch(f"/sketch/sketches/{sketch_id}/constraints/{body['id']}", json={"value": 0.0}).status_code == 400
    refs = [{"type": "point", "id": point["id"]}, {"type": "circle", "id": circle["id"]}]
    nearest = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "min_distance", "refs": refs})
    farthest = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "max_distance", "refs": refs[::-1]})
    assert nearest.status_code == 201 and farthest.status_code == 201, nearest.text + farthest.text
    radius = sketch.entities[circle["id"]].radius(sketch.points)
    assert nearest.json()["value"] == pytest.approx(4.0, abs=1e-6)
    assert farthest.json()["value"] == pytest.approx(4.0 + 2 * radius, abs=1e-6)
