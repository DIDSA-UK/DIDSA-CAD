"""Three-point angle (bug report 2026-11-18, part D, third type): `PointAngleConstraint`, the angle at a vertex Point between the rays to
two other Points.

`addAngle` between two solver-only segments on the existing Points (no helper Points). The quadrant flips the ray to the first Point
(bit 0) or the second (bit 1). Covers each quadrant, DOF (exactly one less), a conflict, a drag, the delete cascade and Point Merge
(`point_ids` are the three Points; a merge that collapses two of them is refused), the saved file, the routes and the driven kind."""

import math

import pytest

from app.sketch.point_merge import MergeRefused, merge_points
from app.sketch.solver import solve_sketch
from tests.dimension_type_support import blockers, client, http_sketch, new_sketch, round_trip


def _three_points(sketch):
    """A vertex at (0, 0), fixed, with Points at (10, 0) and (6, 8) (about 53 degrees apart)."""
    vertex = sketch.add_point(0.0, 0.0)
    a = sketch.add_point(10.0, 0.0)
    b = sketch.add_point(6.0, 8.0)
    sketch.add_fixed_constraint(vertex.id)
    return vertex.id, a.id, b.id


def _angle(sketch, v, a, b) -> float:
    p, q, r = sketch.points[v], sketch.points[a], sketch.points[b]
    d = abs(math.degrees(math.atan2(q.y - p.y, q.x - p.x) - math.atan2(r.y - p.y, r.x - p.x))) % 360
    return min(d, 360 - d)


@pytest.mark.parametrize("quadrant, expected", [(0, 40.0), (3, 40.0), (1, 140.0), (2, 140.0), (None, 40.0)])
def test_each_quadrant_solves_to_its_own_angle(quadrant, expected):
    sketch = new_sketch()
    v, a, b = _three_points(sketch)
    sketch.add_point_angle_constraint(v, a, b, 40.0, quadrant)
    result = solve_sketch(sketch)
    assert result.converged and result.result_code == 0
    assert _angle(sketch, v, a, b) == pytest.approx(expected, abs=1e-6)


def test_dof_drops_by_exactly_one():
    sketch = new_sketch()
    v, a, b = _three_points(sketch)
    assert solve_sketch(sketch).dof == 4
    sketch.add_point_angle_constraint(v, a, b, 40.0, 0)
    after = solve_sketch(sketch)
    assert after.converged and after.result_code == 0 and after.dof == 3


def test_a_conflicting_angle_does_not_converge():
    sketch = new_sketch()
    v, a, b = _three_points(sketch)
    sketch.add_fixed_constraint(a)
    sketch.add_fixed_constraint(b)
    sketch.add_point_angle_constraint(v, a, b, 40.0, 0)  # the fixed Points make 53.13
    assert not solve_sketch(sketch).converged


def test_a_drag_keeps_the_angle():
    sketch = new_sketch()
    v, a, b = _three_points(sketch)
    sketch.add_point_angle_constraint(v, a, b, 40.0, 0)
    assert solve_sketch(sketch).converged
    for x, y in [(8.0, 3.0), (2.0, 9.0), (-5.0, 5.0)]:
        sketch.points[a].x, sketch.points[a].y = x, y
        assert solve_sketch(sketch, anchor_point_ids=frozenset({a})).converged
        assert _angle(sketch, v, a, b) == pytest.approx(40.0, abs=1e-6)


def test_refused_with_a_repeated_point_or_a_bad_value():
    sketch = new_sketch()
    v, a, b = _three_points(sketch)
    with pytest.raises(ValueError):
        sketch.add_point_angle_constraint(v, a, a, 40.0)
    with pytest.raises(ValueError):
        sketch.add_point_angle_constraint(v, a, b, 190.0)
    with pytest.raises(KeyError):
        sketch.add_point_angle_constraint(v, a, "nope", 40.0)


def test_point_ids_are_the_three_points_and_block_their_deletion():
    sketch = new_sketch()
    v, a, b = _three_points(sketch)
    constraint = sketch.add_point_angle_constraint(v, a, b, 40.0)
    assert set(constraint.point_ids()) == {v, a, b}
    reasons = blockers(sketch, (a, b))
    assert all(f"constraint {constraint.id}" in (reason or "") for reason in reasons.values())
    del sketch.constraints[constraint.id]
    assert blockers(sketch, (a, b)) == {a: None, b: None}


def test_point_merge_rewrites_and_refuses_a_collapse():
    sketch = new_sketch()
    v, a, b = _three_points(sketch)
    constraint = sketch.add_point_angle_constraint(v, a, b, 40.0, 0)
    assert solve_sketch(sketch).converged
    end = sketch.points[b]
    loose = sketch.add_point(end.x, end.y)
    sketch.add_line(loose.id, sketch.add_point(end.x + 4.0, end.y).id)
    result = merge_points(sketch, [loose.id, b])
    kept = result.kept_id
    assert constraint.point2_id == kept and kept in sketch.points
    assert solve_sketch(sketch).converged
    with pytest.raises(MergeRefused) as refused:
        merge_points(sketch, [a, kept])
    assert refused.value.reason == "degenerate_constraint"


def test_saved_and_loaded():
    sketch = new_sketch()
    v, a, b = _three_points(sketch)
    constraint = sketch.add_point_angle_constraint(v, a, b, 40.0, 1)
    loaded = round_trip(sketch)
    assert loaded.constraints[constraint.id] == constraint
    assert solve_sketch(loaded).converged
    assert _angle(loaded, v, a, b) == pytest.approx(140.0, abs=1e-6)


def test_routes_create_update_and_measure():
    sketch_id, sketch = http_sketch()
    ids = [client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()["id"] for x, y in [(0, 0), (10, 0), (6, 8)]]
    made = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "point_angle", "vertex_point_id": ids[0], "point1_id": ids[1], "point2_id": ids[2], "angle_degrees": 40.0, "quadrant": 0},
    )
    assert made.status_code == 201, made.text
    body = made.json()
    assert (body["vertex_point_id"], body["point1_id"], body["point2_id"], body["quadrant"]) == (ids[0], ids[1], ids[2], 0)
    solved = client.patch(f"/sketch/sketches/{sketch_id}/constraints/{body['id']}", json={"value": 60.0, "quadrant": 2})
    assert solved.status_code == 200 and solved.json()["converged"], solved.text
    assert _angle(sketch, *ids) == pytest.approx(120.0, abs=1e-6)
    same = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "point_angle", "vertex_point_id": ids[0], "point1_id": ids[1], "point2_id": ids[1], "angle_degrees": 40.0},
    )
    assert same.status_code == 400
    reference = client.post(
        f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "point_angle", "refs": [{"type": "point", "id": i} for i in ids]}
    )
    assert reference.status_code == 201, reference.text
    assert reference.json()["value"] == pytest.approx(120.0, abs=1e-6)
