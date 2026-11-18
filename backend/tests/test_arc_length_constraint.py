"""Arc length (bug report 2026-11-18, part D, first type): `ArcLengthConstraint` on one Arc.

Solved with py-slvs's ArcOfCircle entity and addEqualLineArcLength against a helper line in the fixed group; the Arc's own end-radius
EqualRadiusConstraint is left out of that solve, since the arc entity already states it. Covers: the value is met, DOF (exactly one
less, no redundancy), a length the radius cannot meet, a drag, the delete cascade and Point Merge (`point_ids` are the Arc's three
Points), the saved file, the driven (reference) kind, and the routes (create, list, value update with its reseed)."""

import math

import pytest

from app.sketch.dimension_geometry import arc_length
from app.sketch.point_merge import merge_points
from app.sketch.solver import arc_entity_replaced_constraint_ids, solve_sketch
from tests.dimension_type_support import blockers, client, http_sketch, new_sketch, round_trip


def _quarter_arc(sketch, *, confirm_radius=True, fix_center=True):
    """A quarter arc of radius 10 about (0, 0), from (10, 0) counter-clockwise to (0, 10). Its radius is confirmed (not provisional) and
    its centre fixed unless asked otherwise."""
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(10.0, 0.0)
    end = sketch.add_point(0.0, 10.0)
    arc = sketch.add_arc(center.id, start.id, end.id)
    if confirm_radius:
        sketch.constraints[arc.radius_constraint_id].provisional = False
        sketch.constraints[arc.radius_constraint_id].distance = 10.0
    if fix_center:
        sketch.add_fixed_constraint(center.id)
    return arc


def _length(sketch, arc) -> float:
    p = sketch.points
    return arc_length(
        (p[arc.center_point_id].x, p[arc.center_point_id].y),
        (p[arc.start_point_id].x, p[arc.start_point_id].y),
        (p[arc.end_point_id].x, p[arc.end_point_id].y),
    )


def test_the_length_is_met_and_the_radius_kept():
    sketch = new_sketch()
    arc = _quarter_arc(sketch)
    sketch.add_arc_length_constraint(arc.id, 20.0)
    result = solve_sketch(sketch)
    assert result.converged and result.result_code == 0
    assert _length(sketch, arc) == pytest.approx(20.0, abs=1e-6)
    assert arc.radius(sketch.points) == pytest.approx(10.0, abs=1e-6)


def test_more_than_half_a_turn_is_met():
    sketch = new_sketch()
    arc = _quarter_arc(sketch)
    sketch.points[arc.end_point_id].x, sketch.points[arc.end_point_id].y = 0.0, -10.0  # three quarters
    sketch.add_arc_length_constraint(arc.id, 50.0)
    assert solve_sketch(sketch).converged
    assert _length(sketch, arc) == pytest.approx(50.0, abs=1e-6)


def test_dof_drops_by_exactly_one_and_nothing_is_redundant():
    sketch = new_sketch()
    arc = _quarter_arc(sketch)
    before = solve_sketch(sketch)
    assert before.converged and before.dof == 2  # turning the arc about its centre, and its sweep
    constraint = sketch.add_arc_length_constraint(arc.id, 20.0)
    after = solve_sketch(sketch)
    # Result 0, not 5: the arc entity's own "end on the start's circle" replaced the Arc's EqualRadius rather than repeating it.
    assert after.converged and after.result_code == 0
    assert after.dof == 1
    assert arc_entity_replaced_constraint_ids(sketch) == {arc.end_radius_constraint_id}
    # One more dimension (the turn) makes it fully constrained, with no redundancy.
    sketch.add_horizontal_constraint(sketch.add_line(arc.center_point_id, arc.start_point_id).id)
    full = solve_sketch(sketch)
    assert full.converged and full.result_code == 0 and full.dof == 0
    assert sketch.constraints[constraint.id].length == 20.0


def test_without_the_arc_length_the_arc_keeps_its_equal_radius():
    sketch = new_sketch()
    _quarter_arc(sketch)
    assert arc_entity_replaced_constraint_ids(sketch) == frozenset()


def test_a_length_the_fixed_radius_cannot_meet_does_not_converge():
    sketch = new_sketch()
    arc = _quarter_arc(sketch)
    sketch.add_arc_length_constraint(arc.id, 20.0)
    assert solve_sketch(sketch).converged
    # Pin the end as well: radius 10, fixed centre, fixed start and end make a 15.7 length, so 20 conflicts.
    sketch.add_fixed_constraint(arc.start_point_id)
    sketch.add_fixed_constraint(arc.end_point_id)
    sketch.points[arc.start_point_id].x, sketch.points[arc.start_point_id].y = 10.0, 0.0
    sketch.points[arc.end_point_id].x, sketch.points[arc.end_point_id].y = 0.0, 10.0
    assert not solve_sketch(sketch).converged


@pytest.mark.parametrize("value", [0.0, -5.0, 2 * math.pi * 10.0, 80.0])
def test_values_outside_zero_to_a_full_turn_are_refused(value):
    sketch = new_sketch()
    arc = _quarter_arc(sketch)
    with pytest.raises(ValueError):
        sketch.add_arc_length_constraint(arc.id, value)


def test_a_drag_keeps_the_length():
    sketch = new_sketch()
    arc = _quarter_arc(sketch)
    sketch.add_arc_length_constraint(arc.id, 20.0)
    assert solve_sketch(sketch).converged
    start = sketch.points[arc.start_point_id]
    for angle in (0.3, 1.2, 2.5):
        start.x, start.y = 10.0 * math.cos(angle), 10.0 * math.sin(angle)
        result = solve_sketch(sketch, anchor_point_ids=frozenset({start.id}))
        assert result.converged
        assert _length(sketch, arc) == pytest.approx(20.0, abs=1e-6)


def test_point_ids_are_the_arcs_three_points_and_block_their_deletion():
    sketch = new_sketch()
    arc = _quarter_arc(sketch, fix_center=False)
    constraint = sketch.add_arc_length_constraint(arc.id, 20.0)
    own = (arc.center_point_id, arc.start_point_id, arc.end_point_id)
    assert set(constraint.point_ids()) == set(own)
    # With the Arc gone but the dimension left, the dimension still holds every one of the three Points...
    probe = round_trip(sketch)
    assert probe.delete_arc(arc.id) == []
    assert all(f"constraint {constraint.id}" in (reason or "") for reason in blockers(probe, own).values())
    # ...so the client's cascade deletes the dimension first; then deleting the Arc takes its Points.
    del sketch.constraints[constraint.id]
    pruned = sketch.delete_arc(arc.id)
    assert set(pruned) == set(own)


def test_a_point_merge_rewrites_the_dimension_to_the_kept_point():
    sketch = new_sketch()
    arc = _quarter_arc(sketch)
    constraint = sketch.add_arc_length_constraint(arc.id, 20.0)
    assert solve_sketch(sketch).converged
    # A loose line end fixed exactly where the arc's end is: the fixed one is kept, the arc's end absorbed.
    end = sketch.points[arc.end_point_id]
    loose = sketch.add_point(end.x, end.y)
    sketch.add_line(loose.id, sketch.add_point(end.x + 5.0, end.y).id)
    sketch.add_fixed_constraint(loose.id)
    result = merge_points(sketch, [arc.end_point_id, loose.id])
    assert result.kept_id == loose.id
    assert constraint.end_point_id == loose.id and arc.end_point_id == loose.id
    assert constraint.id in sketch.constraints
    assert solve_sketch(sketch).converged
    assert _length(sketch, arc) == pytest.approx(20.0, abs=1e-6)


def test_saved_and_loaded():
    sketch = new_sketch()
    arc = _quarter_arc(sketch)
    constraint = sketch.add_arc_length_constraint(arc.id, 20.0)
    loaded = round_trip(sketch)
    again = loaded.constraints[constraint.id]
    assert type(again) is type(constraint) and again == constraint
    assert solve_sketch(loaded).converged
    assert _length(loaded, loaded.entities[arc.id]) == pytest.approx(20.0, abs=1e-6)


def test_a_file_without_the_new_types_is_written_as_before():
    sketch = new_sketch()
    _quarter_arc(sketch)
    data = round_trip(sketch)
    assert all(c.type != "arc_length" for c in data.constraints.values())


def _arc_over_http(sketch_id):
    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()
    start = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10.0, "y": 0.0}).json()
    end = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 10.0}).json()
    arc = client.post(
        f"/sketch/sketches/{sketch_id}/arcs", json={"center_point_id": center["id"], "start_point_id": start["id"], "end_point_id": end["id"]}
    ).json()
    return arc


def test_routes_create_list_update_and_measure():
    sketch_id, sketch = http_sketch()
    arc = _arc_over_http(sketch_id)
    assert client.patch(f"/sketch/sketches/{sketch_id}/constraints/{arc['radius_constraint_id']}", json={"value": 10.0}).status_code == 200
    made = client.post(f"/sketch/sketches/{sketch_id}/constraints", json={"type": "arc_length", "arc_id": arc["id"], "length": 20.0})
    assert made.status_code == 201, made.text
    body = made.json()
    assert body["type"] == "arc_length" and body["length"] == 20.0 and body["arc_id"] == arc["id"]
    assert {body["center_point_id"], body["start_point_id"], body["end_point_id"]} == {
        arc["center_point_id"],
        arc["start_point_id"],
        arc["end_point_id"],
    }
    listed = [c for c in client.get(f"/sketch/sketches/{sketch_id}/constraints").json() if c["type"] == "arc_length"]
    assert listed and listed[0]["id"] == body["id"]
    # Three quarters of a turn from a quarter: the route turns the end round first, so the solve converges.
    solved = client.patch(f"/sketch/sketches/{sketch_id}/constraints/{body['id']}", json={"value": 15.0 * math.pi})
    assert solved.status_code == 200 and solved.json()["converged"], solved.text
    assert _length(sketch, sketch.entities[arc["id"]]) == pytest.approx(15.0 * math.pi, abs=1e-5)
    # The driven version measures the same thing.
    reference = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "arc_length", "refs": [{"type": "arc", "id": arc["id"]}]})
    assert reference.status_code == 201, reference.text
    assert reference.json()["value"] == pytest.approx(15.0 * math.pi, abs=1e-5)


def test_routes_refuse_bad_values_and_missing_arcs():
    sketch_id, _ = http_sketch()
    arc = _arc_over_http(sketch_id)
    assert client.post(f"/sketch/sketches/{sketch_id}/constraints", json={"type": "arc_length", "arc_id": arc["id"], "length": -1.0}).status_code == 400
    assert client.post(f"/sketch/sketches/{sketch_id}/constraints", json={"type": "arc_length", "arc_id": "nope", "length": 5.0}).status_code == 404
    made = client.post(f"/sketch/sketches/{sketch_id}/constraints", json={"type": "arc_length", "arc_id": arc["id"], "length": 5.0}).json()
    assert client.patch(f"/sketch/sketches/{sketch_id}/constraints/{made['id']}", json={"value": 0.0}).status_code == 400
    assert client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "arc_length", "refs": [{"type": "line", "id": "x"}]}).status_code == 400


def test_an_ai_plan_on_a_part_whose_sketch_holds_one_passes_it_through_unchanged():
    """The AI modelling plan keeps its own constraint set (plan part D, "out of scope"): validating a plan against a Part that already
    has a sketch with an arc length leaves that sketch exactly as it was."""
    part = client.post("/document/parts", json={"name": "Arc length and a plan"}).json()
    feature = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert feature.status_code == 201, feature.text
    sketch_id = feature.json()["sketch_id"]
    arc = _arc_over_http(sketch_id)
    made = client.post(f"/sketch/sketches/{sketch_id}/constraints", json={"type": "arc_length", "arc_id": arc["id"], "length": 6.0})
    assert made.status_code == 201
    before = client.get(f"/sketch/sketches/{sketch_id}/constraints").json()
    steps = [
        {"local_id": "sk1", "kind": "sketch", "plane": "XY"},
        {"local_id": "p1", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 0, "y": 0},
        {"local_id": "p2", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 60, "y": 0},
        {"local_id": "p3", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 60, "y": 40},
        {"local_id": "p4", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 0, "y": 40},
        {"local_id": "r1", "kind": "sketch_rectangle", "sketch_feature_id": "sk1", "corner_point_ids": ["p1", "p2", "p3", "p4"]},
        {"local_id": "f1", "kind": "extrude", "sketch_feature_id": "sk1", "extrude_type": "boss", "start_distance": 0, "end_distance": 5},
    ]
    validated = client.post(f"/document/parts/{part['id']}/ai-plan/validate", json={"version": 1, "steps": steps})
    assert validated.status_code == 200, validated.text
    assert all(r["ok"] for r in validated.json()["results"])
    assert client.get(f"/sketch/sketches/{sketch_id}/constraints").json() == before
