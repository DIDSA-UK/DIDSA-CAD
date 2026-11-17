"""An angle dimension can say WHICH of the four angles at the vertex it is (`AngleConstraint.quadrant`, bug report 2026-11-17 item 4).

The flange profile had a 23.59 deg dimension between a vertical line and one leaning up-left; the backend chose between the value and its
supplement by whichever was nearer the current shape, and nothing recorded which angle the user meant. With a quadrant the choice is
explicit: the angle between the two lines' outward rays from the vertex, each ray flipped as the quadrant says (bit 0 the first, bit 1 the
second). A file saved before the field has none and keeps the nearest rule."""

import copy
import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.main import app
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _vee() -> tuple[Sketch, str, str, str, str, str]:
    """A vertical line from the vertex straight up and a second line from the same vertex up and to the left (about 24 deg between them).
    Returns the sketch, the two line ids, the vertex and each line's far point."""
    sketch = Sketch(id="s", plane=Plane.XY)
    vertex = sketch.add_point(0.0, 0.0)
    top = sketch.add_point(0.0, 10.0)
    lean = sketch.add_point(-4.0, 9.0)
    line1 = sketch.add_line(vertex.id, top.id)
    line2 = sketch.add_line(vertex.id, lean.id)
    sketch.add_fixed_constraint(vertex.id)
    return sketch, line1.id, line2.id, vertex.id, top.id, lean.id


def _outward_angle(sketch: Sketch, vertex_id: str, far1_id: str, far2_id: str) -> float:
    """The angle between the two outward rays (vertex to each line's far point), 0-180."""
    v, a, b = sketch.points[vertex_id], sketch.points[far1_id], sketch.points[far2_id]
    a1 = math.atan2(a.y - v.y, a.x - v.x)
    a2 = math.atan2(b.y - v.y, b.x - v.x)
    d = abs(math.degrees(a1 - a2)) % 360
    return min(d, 360 - d)


@pytest.mark.parametrize("quadrant, expected", [(0, 30.0), (3, 30.0), (1, 150.0), (2, 150.0)])
def test_each_quadrant_solves_to_its_own_angle(quadrant, expected):
    sketch, l1, l2, v, top, lean = _vee()
    sketch.add_vertical_constraint(l1)
    sketch.add_angle_constraint(l1, l2, 30.0, quadrant)
    result = solve_sketch(sketch)
    assert result.converged
    assert _outward_angle(sketch, v, top, lean) == pytest.approx(expected, abs=1e-6)


@pytest.mark.parametrize("quadrant, expected", [(0, 30.0), (1, 150.0)])
def test_each_quadrant_holds_its_angle_through_a_drag_solve(quadrant, expected):
    sketch, l1, l2, v, top, lean = _vee()
    sketch.add_angle_constraint(l1, l2, 30.0, quadrant)
    assert solve_sketch(sketch).converged
    # Drag the first line's far point round (pinned there for this solve, as the client's drag does): the second line follows.
    for x, y in [(3.0, 10.0), (8.0, 6.0), (10.0, -1.0)]:
        sketch.points[top].x, sketch.points[top].y = x, y
        result = solve_sketch(sketch, anchor_point_ids=frozenset({top}))
        assert result.converged
        assert _outward_angle(sketch, v, top, lean) == pytest.approx(expected, abs=1e-6)


def test_no_quadrant_keeps_the_nearest_rule():
    # 156 with no quadrant: nearer the supplement of today's ~24 deg, so the shape keeps its ~24 deg (the value reads as the other side).
    sketch, l1, l2, v, top, lean = _vee()
    sketch.add_vertical_constraint(l1)
    sketch.add_angle_constraint(l1, l2, 156.0)
    assert solve_sketch(sketch).converged
    assert _outward_angle(sketch, v, top, lean) == pytest.approx(24.0, abs=1e-6)
    # The same value in quadrant 0 opens the angle between the rays to 156.
    sketch, l1, l2, v, top, lean = _vee()
    sketch.add_vertical_constraint(l1)
    sketch.add_angle_constraint(l1, l2, 156.0, 0)
    assert solve_sketch(sketch).converged
    assert _outward_angle(sketch, v, top, lean) == pytest.approx(156.0, abs=1e-6)


def test_lines_drawn_towards_the_vertex_use_the_same_rays():
    # The second line runs from its far point INTO the vertex: its outward ray is end-to-start, and the quadrant still means the same angle.
    sketch = Sketch(id="s", plane=Plane.XY)
    vertex = sketch.add_point(0.0, 0.0)
    top = sketch.add_point(0.0, 10.0)
    lean = sketch.add_point(-4.0, 9.0)
    vertex2 = sketch.add_point(0.0, 0.0)
    line1 = sketch.add_line(vertex.id, top.id)
    line2 = sketch.add_line(lean.id, vertex2.id)
    sketch.add_fixed_constraint(vertex.id)
    sketch.add_coincident_constraint(vertex.id, vertex2.id)
    sketch.add_vertical_constraint(line1.id)
    sketch.add_angle_constraint(line1.id, line2.id, 30.0, 0)
    assert solve_sketch(sketch).converged
    assert _outward_angle(sketch, vertex.id, top.id, lean.id) == pytest.approx(30.0, abs=1e-6)


def test_quadrant_out_of_range_is_refused():
    sketch, l1, l2, *_ = _vee()
    with pytest.raises(ValueError):
        sketch.add_angle_constraint(l1, l2, 30.0, 4)


def test_quadrant_round_trips_through_the_file_and_an_old_file_loads_without_it():
    sketch, l1, l2, *_ = _vee()
    constraint = sketch.add_angle_constraint(l1, l2, 30.0, 2)
    data = sketch_to_dict(sketch)
    loaded = sketch_from_dict(copy.deepcopy(data))
    assert loaded.constraints[constraint.id].quadrant == 2
    for c in data["constraints"]:
        c.pop("quadrant", None)  # a file saved before the field existed
    old = sketch_from_dict(data)
    assert old.constraints[constraint.id].quadrant is None
    assert old.constraints[constraint.id].angle_degrees == 30.0


def test_api_create_update_and_read_back():
    sketch_id = client.post("/sketch/sketches", json={"plane": "XY"}).json()["id"]

    def point(x, y):
        return client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()["id"]

    v, top, lean = point(0.0, 0.0), point(0.0, 10.0), point(-4.0, 9.0)
    l1 = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": v, "end_point_id": top}).json()["id"]
    l2 = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": v, "end_point_id": lean}).json()["id"]
    url = f"/sketch/sketches/{sketch_id}/constraints"
    response = client.post(url, json={"type": "angle", "line1_id": l1, "line2_id": l2, "angle_degrees": 30.0, "quadrant": 1})
    assert response.status_code == 201, response.text
    created = response.json()
    assert created["quadrant"] == 1
    assert client.post(url, json={"type": "angle", "line1_id": l1, "line2_id": l2, "angle_degrees": 30.0, "quadrant": 7}).status_code == 422
    plain = client.post(url, json={"type": "angle", "line1_id": l1, "line2_id": l2, "angle_degrees": 30.0})
    assert plain.status_code == 201 and plain.json()["quadrant"] is None
    client.delete(f"{url}/{plain.json()['id']}")

    assert client.patch(f"{url}/{created['id']}", json={"value": 40.0}).status_code == 200
    by_id = {c["id"]: c for c in client.get(url).json()}
    assert by_id[created["id"]]["quadrant"] == 1  # omitted on update keeps the saved one
    assert client.patch(f"{url}/{created['id']}", json={"value": 40.0, "quadrant": 0}).status_code == 200
    by_id = {c["id"]: c for c in client.get(url).json()}
    assert by_id[created["id"]]["quadrant"] == 0 and by_id[created["id"]]["angle_degrees"] == 40.0
