"""Minimum / maximum distance between two Circles / Arcs (bug report 2026-11-18, part D, fifth type): `CircleCircleDistanceConstraint`.

A helper point on each circle on the centre line (each: two unknowns, two equations), then `distance(H1, H2) = value`. Covers the gap
and the overall size, DOF (exactly one less), the side check (the helpers on the wrong sides, overlapping circles), refusals (one
circle twice, concentric, a gap between overlapping circles), an Arc, the delete cascade and Point Merge, the saved file, the routes and
the driven kinds."""

import math

import pytest

from app.sketch.point_merge import MergeRefused, merge_points
from app.sketch.solver import solve_sketch
from tests.dimension_type_support import blockers, client, fixed_circle, http_sketch, new_sketch, round_trip


def _free_circle(sketch, x, y, radius):
    """A circle with a confirmed radius and a free centre."""
    center = sketch.add_point(x, y)
    circle = sketch.add_circle(center.id, radius=radius, angle=0.0)
    sketch.constraints[circle.radius_constraint_id].provisional = False
    sketch.constraints[circle.radius_constraint_id].distance = radius
    return circle


def _centres_apart(sketch, a, b) -> float:
    p, q = sketch.points[a.center_point_id], sketch.points[b.center_point_id]
    return math.hypot(q.x - p.x, q.y - p.y)


@pytest.mark.parametrize("side, value, centres", [("min", 6.0, 13.0), ("max", 30.0, 23.0)])
def test_the_gap_and_the_overall_size_are_met(side, value, centres):
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    two = _free_circle(sketch, 15.0, 2.0, 3.0)
    sketch.add_circle_circle_distance_constraint(one.id, two.id, value, side)
    result = solve_sketch(sketch)
    assert result.converged and result.result_code == 0
    assert _centres_apart(sketch, one, two) == pytest.approx(centres, abs=1e-6)


def test_dof_drops_by_exactly_one_the_helpers_add_none():
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    two = _free_circle(sketch, 15.0, 2.0, 3.0)
    before = solve_sketch(sketch)
    sketch.add_circle_circle_distance_constraint(one.id, two.id, 6.0, "min")
    after = solve_sketch(sketch)
    assert after.converged and after.result_code == 0 and after.dof == before.dof - 1


def test_the_side_check_catches_a_gap_given_the_overall_size_and_overlapping_circles():
    # Both centres fixed 15 apart, radii 4 and 3: the gap is 8, the overall size 22.
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    two = fixed_circle(sketch, 15.0, 0.0, 3.0)
    sketch.add_circle_circle_distance_constraint(one.id, two.id, 22.0, "min")
    assert not solve_sketch(sketch).converged
    # A gap with circles free to slide: asking for it and then shrinking a radius past the other circle cannot stay converged as a gap.
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    two = _free_circle(sketch, 15.0, 0.0, 3.0)
    sketch.add_horizontal_constraint(sketch.add_line(one.center_point_id, two.center_point_id).id)
    gap = sketch.add_circle_circle_distance_constraint(one.id, two.id, 8.0, "min")
    assert solve_sketch(sketch).converged
    sketch.add_fixed_constraint(two.center_point_id)
    sketch.constraints[two.radius_constraint_id].distance = 30.0  # now they would overlap: no gap of 8 exists
    assert not solve_sketch(sketch).converged
    assert gap.id in sketch.constraints


def test_refusals():
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    two = _free_circle(sketch, 5.0, 0.0, 3.0)  # overlapping
    with pytest.raises(ValueError):
        sketch.add_circle_circle_distance_constraint(one.id, one.id, 3.0)
    with pytest.raises(ValueError):
        sketch.add_circle_circle_distance_constraint(one.id, two.id, 3.0, "min")
    assert sketch.add_circle_circle_distance_constraint(one.id, two.id, 20.0, "max").side == "max"  # the overall size is fine
    concentric = _free_circle(sketch, 0.0, 0.0, 2.0)
    with pytest.raises(ValueError):
        sketch.add_circle_circle_distance_constraint(one.id, concentric.id, 3.0, "max")
    far = _free_circle(sketch, 30.0, 0.0, 2.0)
    with pytest.raises(ValueError):
        sketch.add_circle_circle_distance_constraint(one.id, far.id, 0.0)


def test_an_arc_and_a_circle():
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    c = sketch.add_point(20.0, 0.0)
    s = sketch.add_point(23.0, 0.0)
    e = sketch.add_point(20.0, 3.0)
    arc = sketch.add_arc(c.id, s.id, e.id)
    sketch.constraints[arc.radius_constraint_id].provisional = False
    sketch.constraints[arc.radius_constraint_id].distance = 3.0
    sketch.add_circle_circle_distance_constraint(arc.id, one.id, 5.0, "min")
    assert solve_sketch(sketch).converged
    assert math.hypot(sketch.points[c.id].x, sketch.points[c.id].y) == pytest.approx(12.0, abs=1e-6)


def test_point_ids_are_both_centres_and_rims_and_block_deletion():
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    two = _free_circle(sketch, 15.0, 2.0, 3.0)
    constraint = sketch.add_circle_circle_distance_constraint(one.id, two.id, 6.0)
    own = {one.center_point_id, one.radius_point_id, two.center_point_id, two.radius_point_id}
    assert set(constraint.point_ids()) == own
    probe = round_trip(sketch)
    probe.delete_circle(two.id)
    assert {two.center_point_id, two.radius_point_id} <= set(probe.points)
    assert f"referenced by {sketch.name_of(constraint.id)}" in blockers(probe, [two.center_point_id])[two.center_point_id]
    del sketch.constraints[constraint.id]
    assert two.center_point_id in sketch.delete_circle(two.id)


def test_point_merge_rewrites_and_refuses_concentric():
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    two = _free_circle(sketch, 15.0, 0.0, 3.0)
    constraint = sketch.add_circle_circle_distance_constraint(one.id, two.id, 8.0)
    assert solve_sketch(sketch).converged
    c = sketch.points[two.center_point_id]
    loose = sketch.add_point(c.x, c.y)
    sketch.add_line(loose.id, sketch.add_point(c.x, c.y + 9.0).id)
    kept = merge_points(sketch, [loose.id, two.center_point_id]).kept_id
    assert constraint.center2_point_id == kept
    assert solve_sketch(sketch).converged
    with pytest.raises(MergeRefused):
        merge_points(sketch, [kept, one.center_point_id])


def test_saved_and_loaded():
    sketch = new_sketch()
    one = fixed_circle(sketch, radius=4.0)
    two = _free_circle(sketch, 15.0, 2.0, 3.0)
    constraint = sketch.add_circle_circle_distance_constraint(one.id, two.id, 30.0, "max")
    loaded = round_trip(sketch)
    assert loaded.constraints[constraint.id] == constraint
    assert solve_sketch(loaded).converged
    assert _centres_apart(loaded, one, two) == pytest.approx(23.0, abs=1e-6)


def test_routes_create_update_and_the_driven_kinds():
    sketch_id, sketch = http_sketch()
    ids = []
    for x, r in ((0.0, 4.0), (15.0, 3.0)):
        centre = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": 0.0}).json()
        ids.append(client.post(f"/sketch/sketches/{sketch_id}/circles", json={"center_point_id": centre["id"], "radius": r}).json()["id"])
    made = client.post(
        f"/sketch/sketches/{sketch_id}/constraints", json={"type": "circle_distance", "entity1_id": ids[0], "entity2_id": ids[1], "distance": 8.0}
    )
    assert made.status_code == 201, made.text
    body = made.json()
    assert body["side"] == "min" and body["entity2_id"] == ids[1]
    assert client.patch(f"/sketch/sketches/{sketch_id}/constraints/{body['id']}", json={"value": 6.0}).json()["converged"]
    refs = [{"type": "circle", "id": i} for i in ids]
    gap = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "min_distance", "refs": refs})
    size = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "max_distance", "refs": refs})
    assert gap.status_code == 201 and size.status_code == 201, gap.text + size.text
    radii = sum(sketch.entities[i].radius(sketch.points) for i in ids)
    assert gap.json()["value"] == pytest.approx(6.0, abs=1e-6)
    assert size.json()["value"] == pytest.approx(6.0 + 2 * radii, abs=1e-6)
    overlap = client.post(
        f"/sketch/sketches/{sketch_id}/constraints", json={"type": "circle_distance", "entity1_id": ids[0], "entity2_id": ids[0], "distance": 8.0}
    )
    assert overlap.status_code == 400
