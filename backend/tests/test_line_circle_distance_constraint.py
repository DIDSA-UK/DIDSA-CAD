"""Tangent-side / far-side distance from a Line to a Circle or Arc (bug report 2026-11-18, part D, sixth type):
`LineCircleDistanceConstraint`.

One helper point on the circle with its radius square to the line (`perpendicular` + `equal_length`: two unknowns, two equations), then
a signed `point_line_distance` on the centre's side. Covers both sides (and both sides of the line), DOF (exactly one less), the side check
(a line cutting the circle where the tangent side was asked for), refusals, an Arc, the delete cascade and Point Merge, the saved file,
the routes and the driven kinds."""

import math

import pytest

from app.sketch.point_merge import MergeRefused, merge_points
from app.sketch.solver import solve_sketch
from tests.dimension_type_support import blockers, client, fixed_circle, http_sketch, new_sketch, round_trip


def _floor(sketch, y=0.0, *, fixed=True):
    """A horizontal line along y, from x = -20 to 20, fixed unless asked otherwise."""
    a = sketch.add_point(-20.0, y)
    b = sketch.add_point(20.0, y)
    line = sketch.add_line(a.id, b.id)
    if fixed:
        sketch.add_fixed_constraint(line.id)
    return line


def _free_circle(sketch, x, y, radius):
    center = sketch.add_point(x, y)
    circle = sketch.add_circle(center.id, radius=radius, angle=0.0)
    sketch.constraints[circle.radius_constraint_id].provisional = False
    sketch.constraints[circle.radius_constraint_id].distance = radius
    return circle


@pytest.mark.parametrize("centre_y, side, value, expected_y", [(10.0, "min", 3.0, 7.0), (10.0, "max", 12.0, 8.0), (-10.0, "min", 3.0, -7.0), (-10.0, "max", 12.0, -8.0)])
def test_both_sides_and_both_sides_of_the_line(centre_y, side, value, expected_y):
    sketch = new_sketch()
    line = _floor(sketch)
    circle = _free_circle(sketch, 2.0, centre_y, 4.0)
    sketch.add_line_circle_distance_constraint(line.id, circle.id, value, side)
    result = solve_sketch(sketch)
    assert result.converged and result.result_code == 0
    assert sketch.points[circle.center_point_id].y == pytest.approx(expected_y, abs=1e-6)


def test_dof_drops_by_exactly_one_the_helper_adds_none():
    sketch = new_sketch()
    line = _floor(sketch)
    circle = _free_circle(sketch, 2.0, 10.0, 4.0)
    before = solve_sketch(sketch)
    sketch.add_line_circle_distance_constraint(line.id, circle.id, 3.0)
    after = solve_sketch(sketch)
    assert after.converged and after.result_code == 0 and after.dof == before.dof - 1


def test_a_centre_on_the_line_is_fine_for_the_far_side():
    sketch = new_sketch()
    line = _floor(sketch)
    circle = fixed_circle(sketch, 0.0, 0.0, 4.0)
    # Only the far side exists with the centre on the line; the line is pinned, so the radius moves.
    sketch.constraints[circle.radius_constraint_id].provisional = True
    sketch.add_line_circle_distance_constraint(line.id, circle.id, 6.0, "max")
    assert solve_sketch(sketch).converged
    assert circle.radius(sketch.points) == pytest.approx(6.0, abs=1e-6)


def test_the_side_check_a_tangent_side_given_the_far_sides_value_is_not_converged():
    # The line and the circle are both fixed: centre 10 above the line, radius 4 - tangent side 6, far side 14.
    sketch = new_sketch()
    line = _floor(sketch)
    circle = fixed_circle(sketch, 0.0, 10.0, 4.0)
    sketch.add_line_circle_distance_constraint(line.id, circle.id, 14.0, "min")
    assert not solve_sketch(sketch).converged
    sketch = new_sketch()
    line = _floor(sketch)
    circle = fixed_circle(sketch, 0.0, 10.0, 4.0)
    sketch.add_line_circle_distance_constraint(line.id, circle.id, 14.0, "max")
    assert solve_sketch(sketch).converged


def test_refusals():
    sketch = new_sketch()
    line = _floor(sketch)
    cutting = _free_circle(sketch, 0.0, 2.0, 4.0)
    with pytest.raises(ValueError):
        sketch.add_line_circle_distance_constraint(line.id, cutting.id, 3.0, "min")
    assert sketch.add_line_circle_distance_constraint(line.id, cutting.id, 6.0, "max").side == "max"
    clear = _free_circle(sketch, 0.0, 10.0, 4.0)
    with pytest.raises(ValueError):
        sketch.add_line_circle_distance_constraint(line.id, clear.id, 0.0)
    with pytest.raises(KeyError):
        sketch.add_line_circle_distance_constraint(clear.id, clear.id, 3.0)


def test_an_arc():
    sketch = new_sketch()
    line = _floor(sketch)
    c = sketch.add_point(0.0, 10.0)
    s = sketch.add_point(4.0, 10.0)
    e = sketch.add_point(0.0, 14.0)
    arc = sketch.add_arc(c.id, s.id, e.id)
    sketch.constraints[arc.radius_constraint_id].provisional = False
    sketch.constraints[arc.radius_constraint_id].distance = 4.0
    sketch.add_line_circle_distance_constraint(line.id, arc.id, 2.0)
    assert solve_sketch(sketch).converged
    assert sketch.points[c.id].y == pytest.approx(6.0, abs=1e-6)


def test_point_ids_are_the_line_ends_the_centre_and_the_rim_and_block_deletion():
    sketch = new_sketch()
    line = _floor(sketch, fixed=False)
    circle = _free_circle(sketch, 2.0, 10.0, 4.0)
    constraint = sketch.add_line_circle_distance_constraint(line.id, circle.id, 3.0)
    own = {line.start_point_id, line.end_point_id, circle.center_point_id, circle.radius_point_id}
    assert set(constraint.point_ids()) == own
    probe = round_trip(sketch)
    assert probe.delete_line(line.id) == []
    assert all(f"referenced by {sketch.name_of(constraint.id)}" in (r or "") for r in blockers(probe, [line.start_point_id, line.end_point_id]).values())
    del sketch.constraints[constraint.id]
    assert set(sketch.delete_line(line.id)) == {line.start_point_id, line.end_point_id}


def test_point_merge_rewrites_and_refuses_the_centre_onto_the_line():
    sketch = new_sketch()
    line = _floor(sketch, fixed=False)
    circle = _free_circle(sketch, 2.0, 10.0, 4.0)
    constraint = sketch.add_line_circle_distance_constraint(line.id, circle.id, 3.0)
    assert solve_sketch(sketch).converged
    end = sketch.points[line.end_point_id]
    loose = sketch.add_point(end.x, end.y)
    sketch.add_line(loose.id, sketch.add_point(end.x + 3.0, end.y - 3.0).id)
    kept = merge_points(sketch, [loose.id, line.end_point_id]).kept_id
    assert constraint.line_end_id == kept
    assert solve_sketch(sketch).converged
    with pytest.raises(MergeRefused):
        merge_points(sketch, [kept, circle.center_point_id])


def test_saved_and_loaded():
    sketch = new_sketch()
    line = _floor(sketch)
    circle = _free_circle(sketch, 2.0, 10.0, 4.0)
    constraint = sketch.add_line_circle_distance_constraint(line.id, circle.id, 12.0, "max")
    loaded = round_trip(sketch)
    assert loaded.constraints[constraint.id] == constraint
    assert solve_sketch(loaded).converged
    assert loaded.points[circle.center_point_id].y == pytest.approx(8.0, abs=1e-6)


def test_routes_create_update_and_the_driven_kinds():
    sketch_id, sketch = http_sketch()
    a = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": -20.0, "y": 0.0}).json()
    b = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 20.0, "y": 0.0}).json()
    line = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}).json()
    centre = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 2.0, "y": 10.0}).json()
    circle = client.post(f"/sketch/sketches/{sketch_id}/circles", json={"center_point_id": centre["id"], "radius": 4.0}).json()
    made = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "line_circle_distance", "line_id": line["id"], "circle_or_arc_id": circle["id"], "distance": 3.0},
    )
    assert made.status_code == 201, made.text
    body = made.json()
    assert (body["side"], body["line_start_id"], body["center_point_id"]) == ("min", a["id"], centre["id"])
    assert client.patch(f"/sketch/sketches/{sketch_id}/constraints/{body['id']}", json={"value": 5.0}).json()["converged"]
    refs = [{"type": "line", "id": line["id"]}, {"type": "circle", "id": circle["id"]}]
    near = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "min_distance", "refs": refs})
    far = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "max_distance", "refs": refs[::-1]})
    assert near.status_code == 201 and far.status_code == 201, near.text + far.text
    radius = sketch.entities[circle["id"]].radius(sketch.points)
    assert near.json()["value"] == pytest.approx(5.0, abs=1e-6)
    assert far.json()["value"] == pytest.approx(5.0 + 2 * radius, abs=1e-6)
