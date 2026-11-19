"""Angle to horizontal (bug report 2026-11-18, part D, second type): `HorizontalAngleConstraint` on one Line.

`addAngle` against the workplane's fixed horizontal reference line (no unknowns of its own). The quadrant names the angle: bit 0 the end
it is drawn at (clear: the start, the ray running to the end; set: the end, running back), bit 1 the horizontal ray (+x or -x). Covers
each quadrant, DOF (exactly one less), a conflict, a drag, the delete cascade and Point Merge (`point_ids` are the Line's two Points), the
saved file, the routes (create, list, value and quadrant update) and the driven kind."""

import math

import pytest

from app.sketch.point_merge import merge_points
from app.sketch.solver import solve_sketch
from tests.dimension_type_support import blockers, client, http_sketch, new_sketch, round_trip


def _leaning_line(sketch, *, fix_start=True):
    """A line from (0, 0) to (10, 3), about 17 degrees above +x, its start fixed unless asked otherwise."""
    start = sketch.add_point(0.0, 0.0)
    end = sketch.add_point(10.0, 3.0)
    line = sketch.add_line(start.id, end.id)
    if fix_start:
        sketch.add_fixed_constraint(start.id)
    return line


def _direction_degrees(sketch, line) -> float:
    """The start-to-end direction's angle from +x, 0-180."""
    a, b = sketch.points[line.start_point_id], sketch.points[line.end_point_id]
    return abs(math.degrees(math.atan2(b.y - a.y, b.x - a.x)))


@pytest.mark.parametrize("quadrant, expected", [(0, 30.0), (3, 30.0), (1, 150.0), (2, 150.0), (None, 30.0)])
def test_each_quadrant_solves_to_its_own_angle(quadrant, expected):
    sketch = new_sketch()
    line = _leaning_line(sketch)
    sketch.add_horizontal_angle_constraint(line.id, 30.0, quadrant)
    result = solve_sketch(sketch)
    assert result.converged and result.result_code == 0
    assert _direction_degrees(sketch, line) == pytest.approx(expected, abs=1e-6)


def test_no_quadrant_keeps_the_nearer_side():
    sketch = new_sketch()
    line = _leaning_line(sketch)
    sketch.add_horizontal_angle_constraint(line.id, 160.0)  # nearer 180 - 17 than 17, so the shape keeps its side: 20 degrees
    assert solve_sketch(sketch).converged
    assert _direction_degrees(sketch, line) == pytest.approx(20.0, abs=1e-6)


def test_dof_drops_by_exactly_one():
    sketch = new_sketch()
    line = _leaning_line(sketch)
    before = solve_sketch(sketch)
    assert before.converged and before.dof == 2
    sketch.add_horizontal_angle_constraint(line.id, 30.0, 0)
    after = solve_sketch(sketch)
    assert after.converged and after.result_code == 0 and after.dof == 1
    sketch.add_distance_constraint(line.start_point_id, line.end_point_id, 10.0)
    full = solve_sketch(sketch)
    assert full.converged and full.result_code == 0 and full.dof == 0


def test_a_horizontal_line_cannot_also_be_at_30_degrees():
    sketch = new_sketch()
    line = _leaning_line(sketch)
    sketch.add_horizontal_constraint(line.id)
    sketch.add_horizontal_angle_constraint(line.id, 30.0, 0)
    assert not solve_sketch(sketch).converged


@pytest.mark.parametrize("value", [-1.0, 181.0, math.nan])
def test_values_outside_0_to_180_are_refused(value):
    sketch = new_sketch()
    line = _leaning_line(sketch)
    with pytest.raises(ValueError):
        sketch.add_horizontal_angle_constraint(line.id, value)


def test_a_drag_keeps_the_angle():
    sketch = new_sketch()
    line = _leaning_line(sketch)
    sketch.add_horizontal_angle_constraint(line.id, 30.0, 0)
    assert solve_sketch(sketch).converged
    end = sketch.points[line.end_point_id]
    for x, y in [(4.0, 6.0), (12.0, 2.0), (8.0, 9.0)]:
        end.x, end.y = x, y
        result = solve_sketch(sketch, anchor_point_ids=frozenset({end.id}))
        assert result.converged
        assert _direction_degrees(sketch, line) == pytest.approx(30.0, abs=1e-6)


def test_point_ids_are_the_lines_two_points_and_block_their_deletion():
    sketch = new_sketch()
    line = _leaning_line(sketch, fix_start=False)
    constraint = sketch.add_horizontal_angle_constraint(line.id, 30.0)
    own = (line.start_point_id, line.end_point_id)
    assert set(constraint.point_ids()) == set(own)
    probe = round_trip(sketch)
    assert probe.delete_line(line.id) == []
    assert all(f"constraint {constraint.id}" in (reason or "") for reason in blockers(probe, own).values())
    del sketch.constraints[constraint.id]
    assert set(sketch.delete_line(line.id)) == set(own)


def test_a_point_merge_rewrites_the_dimension_to_the_kept_point():
    sketch = new_sketch()
    line = _leaning_line(sketch, fix_start=False)  # both ends fixed would leave the angle nothing to move (redundant)
    constraint = sketch.add_horizontal_angle_constraint(line.id, 30.0, 0)
    assert solve_sketch(sketch).converged
    end = sketch.points[line.end_point_id]
    loose = sketch.add_point(end.x, end.y)
    sketch.add_line(loose.id, sketch.add_point(end.x, end.y + 5.0).id)
    sketch.add_fixed_constraint(loose.id)
    result = merge_points(sketch, [line.end_point_id, loose.id])
    assert result.kept_id == loose.id
    assert constraint.line_end_id == loose.id
    assert solve_sketch(sketch).converged
    assert _direction_degrees(sketch, line) == pytest.approx(30.0, abs=1e-6)


def test_saved_and_loaded():
    sketch = new_sketch()
    line = _leaning_line(sketch)
    constraint = sketch.add_horizontal_angle_constraint(line.id, 30.0, 2)
    loaded = round_trip(sketch)
    assert loaded.constraints[constraint.id] == constraint
    assert solve_sketch(loaded).converged
    assert _direction_degrees(loaded, loaded.entities[line.id]) == pytest.approx(150.0, abs=1e-6)
    # Without a quadrant the field is still written (as null) and read back the same.
    plain = sketch.add_horizontal_angle_constraint(line.id, 30.0)
    assert round_trip(sketch).constraints[plain.id].quadrant is None


def test_routes_create_list_update_and_measure():
    sketch_id, sketch = http_sketch()
    a = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()
    b = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10.0, "y": 3.0}).json()
    line = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}).json()
    made = client.post(
        f"/sketch/sketches/{sketch_id}/constraints", json={"type": "horizontal_angle", "line_id": line["id"], "angle_degrees": 30.0, "quadrant": 0}
    )
    assert made.status_code == 201, made.text
    body = made.json()
    assert body["type"] == "horizontal_angle" and body["quadrant"] == 0
    assert (body["line_start_id"], body["line_end_id"]) == (a["id"], b["id"])
    assert any(c["id"] == body["id"] for c in client.get(f"/sketch/sketches/{sketch_id}/constraints").json())
    assert client.post(f"/sketch/sketches/{sketch_id}/solve").json()["converged"]
    solved = client.patch(f"/sketch/sketches/{sketch_id}/constraints/{body['id']}", json={"value": 45.0, "quadrant": 1})
    assert solved.status_code == 200 and solved.json()["converged"], solved.text
    assert sketch.constraints[body["id"]].quadrant == 1
    assert _direction_degrees(sketch, sketch.entities[line["id"]]) == pytest.approx(135.0, abs=1e-6)
    assert client.patch(f"/sketch/sketches/{sketch_id}/constraints/{body['id']}", json={"value": 200.0}).status_code == 400
    reference = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "horizontal_angle", "refs": [{"type": "line", "id": line["id"]}]})
    assert reference.status_code == 201, reference.text
    assert reference.json()["value"] == pytest.approx(135.0, abs=1e-6)
    bad = client.post(f"/sketch/sketches/{sketch_id}/constraints", json={"type": "horizontal_angle", "line_id": line["id"], "angle_degrees": 30.0, "quadrant": 7})
    assert bad.status_code == 422
