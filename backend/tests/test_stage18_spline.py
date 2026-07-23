import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Plane, Sketch, Spline
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _tangent_dot_at_joint(sketch: Sketch, spline: Spline, joint_index: int) -> float:
    """The dot product of the two tangent directions meeting at
    `spline`'s `joint_index`-th interior through-point (0 = the first
    interior joint) - 1.0 means perfectly smooth (no kink), -1.0 means the
    solver converged to the tangency constraint's other, cusped solution
    branch (see `SplineTangentConstraint`'s own doc comment)."""
    segments = spline.segments()
    seg_a = segments[joint_index]
    seg_b = segments[joint_index + 1]
    c2 = sketch.points[seg_a[2]]
    joint = sketch.points[seg_a[3]]
    c3 = sketch.points[seg_b[1]]

    def direction(a, b):
        dx, dy = b.x - a.x, b.y - a.y
        n = math.hypot(dx, dy)
        return (dx / n, dy / n) if n > 1e-9 else (0.0, 0.0)

    d1 = direction(c2, joint)
    d2 = direction(joint, c3)
    return d1[0] * d2[0] + d1[1] * d2[1]


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_spline_creates_two_control_points_per_segment():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)
    p3 = sketch.add_point(20.0, 0.0)

    spline = sketch.add_spline([p1.id, p2.id, p3.id])

    assert isinstance(spline, Spline)
    assert spline.through_point_ids == [p1.id, p2.id, p3.id]
    assert len(spline.control_point_ids) == 4
    assert len(spline.tangent_constraint_ids) == 1
    assert len(sketch.constraints) == 1
    assert spline.endpoint_point_ids() == (p1.id, p3.id)


def test_add_spline_segments_returns_ordered_4_point_tuples():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)
    p3 = sketch.add_point(20.0, 0.0)
    spline = sketch.add_spline([p1.id, p2.id, p3.id])

    segments = spline.segments()

    assert len(segments) == 2
    assert segments[0][0] == p1.id
    assert segments[0][3] == p2.id
    assert segments[1][0] == p2.id
    assert segments[1][3] == p3.id
    assert segments[0][1] == spline.control_point_ids[0]
    assert segments[0][2] == spline.control_point_ids[1]
    assert segments[1][1] == spline.control_point_ids[2]
    assert segments[1][2] == spline.control_point_ids[3]


def test_add_spline_with_two_through_points_creates_no_tangent_constraint():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)

    spline = sketch.add_spline([p1.id, p2.id])

    assert len(spline.control_point_ids) == 2
    assert spline.tangent_constraint_ids == []
    assert sketch.constraints == {}


def test_add_spline_rejects_fewer_than_two_through_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_spline([p1.id])


def test_add_spline_rejects_duplicate_through_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_spline([p1.id, p2.id, p1.id])


def test_add_spline_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_spline([p1.id, "does-not-exist"])


def test_delete_spline_removes_its_tangent_constraints_and_prunes_now_orphaned_points_but_leaves_a_still_shared_one():
    # Bug fix (pre-existing stale test - predates `_prune_orphaned_points`;
    # see test_delete_line_prunes_a_now_orphaned_endpoint's own comment in
    # test_stage6_delete.py): control Points no longer unconditionally
    # survive their own Spline's deletion. `p1` stays shared with an
    # unrelated Line here.
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)
    p3 = sketch.add_point(20.0, 0.0)
    spline = sketch.add_spline([p1.id, p2.id, p3.id])
    other = sketch.add_point(30.0, 30.0)
    sketch.add_line(p1.id, other.id)
    assert len(sketch.constraints) == 1

    sketch.delete_spline(spline.id)

    assert spline.id not in sketch.entities
    for constraint_id in spline.tangent_constraint_ids:
        assert constraint_id not in sketch.constraints
    assert p1.id in sketch.points
    assert p2.id not in sketch.points
    assert p3.id not in sketch.points


def test_point_deletion_is_blocked_while_referenced_by_a_spline():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 0.0)
    p3 = sketch.add_point(20.0, 0.0)
    spline = sketch.add_spline([p1.id, p2.id, p3.id])

    with pytest.raises(ValueError):
        sketch.delete_point(p1.id)
    with pytest.raises(ValueError):
        sketch.delete_point(p2.id)
    with pytest.raises(ValueError):
        sketch.delete_point(spline.control_point_ids[0])


# --- Solver: tangent continuity ----------------------------------------------


def test_solving_a_freshly_created_spline_keeps_its_interior_joint_smooth():
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 5.0)
    p3 = sketch.add_point(20.0, 0.0)
    spline = sketch.add_spline([p1.id, p2.id, p3.id])

    result = solve_sketch(sketch)

    assert result.converged
    assert _tangent_dot_at_joint(sketch, spline, 0) == pytest.approx(1.0, abs=1e-6)


def test_incrementally_dragging_a_through_point_keeps_it_smooth_over_small_steps():
    """Mirrors how the client actually drags a Point - many small
    position updates, each followed by a solve with that Point anchored
    (see SketchController.updatePointDrag / the POST .../solve
    anchor_point_ids parameter) - not one large teleport. A large,
    discontinuous jump can converge to the tangency constraint's other
    (cusped) solution branch; this is a known, accepted limitation of
    curve-tangent constraints in general (shared by SolveSpace's own
    native spline tool and every other constraint-based CAD sketcher),
    not something this test tries to eliminate - only confirms that
    *ordinary* incremental dragging stays on the smooth branch."""
    sketch = Sketch(id="s", plane=Plane.XY)
    p1 = sketch.add_point(0.0, 0.0)
    p2 = sketch.add_point(10.0, 5.0)
    p3 = sketch.add_point(20.0, 0.0)
    spline = sketch.add_spline([p1.id, p2.id, p3.id])
    solve_sketch(sketch)

    start_x, start_y = sketch.points[p2.id].x, sketch.points[p2.id].y
    target_x, target_y = 11.0, 7.0
    steps = 10
    for i in range(1, steps + 1):
        t = i / steps
        sketch.points[p2.id].x = start_x + (target_x - start_x) * t
        sketch.points[p2.id].y = start_y + (target_y - start_y) * t
        result = solve_sketch(sketch, anchor_point_ids=frozenset({p2.id}))
        assert result.converged

    assert _tangent_dot_at_joint(sketch, spline, 0) == pytest.approx(1.0, abs=1e-3)


# --- Profile detection -------------------------------------------------------


def test_line_and_spline_chain_closes_into_a_single_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 5.0)
    c = sketch.add_point(20.0, 0.0)
    d = sketch.add_point(20.0, -10.0)
    e = sketch.add_point(0.0, -10.0)
    sketch.add_spline([a.id, b.id, c.id])
    sketch.add_line(c.id, d.id)
    sketch.add_line(d.id, e.id)
    sketch.add_line(e.id, a.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
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


def test_create_spline_over_the_api():
    sketch = _create_sketch()
    p1 = _create_point(sketch["id"], 0.0, 0.0)
    p2 = _create_point(sketch["id"], 10.0, 5.0)
    p3 = _create_point(sketch["id"], 20.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [p1["id"], p2["id"], p3["id"]]},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "spline"
    assert body["through_point_ids"] == [p1["id"], p2["id"], p3["id"]]
    assert len(body["control_point_ids"]) == 4


def test_create_spline_requires_at_least_two_through_points():
    sketch = _create_sketch()
    p1 = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [p1["id"]]},
    )

    assert response.status_code == 422


def test_create_spline_with_unknown_point_is_404():
    sketch = _create_sketch()
    p1 = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [p1["id"], "does-not-exist"]},
    )

    assert response.status_code == 404


def test_get_spline_round_trip():
    sketch = _create_sketch()
    p1 = _create_point(sketch["id"], 0.0, 0.0)
    p2 = _create_point(sketch["id"], 10.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [p1["id"], p2["id"]]},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/splines/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_spline_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/splines/does-not-exist")
    assert response.status_code == 404


def test_list_splines_returns_every_spline_in_the_sketch():
    sketch = _create_sketch()
    p1 = _create_point(sketch["id"], 0.0, 0.0)
    p2 = _create_point(sketch["id"], 10.0, 0.0)
    spline = client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [p1["id"], p2["id"]]},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/splines")

    assert response.status_code == 200
    assert [s["id"] for s in response.json()] == [spline["id"]]


def test_update_spline_construction_flag_over_the_api():
    sketch = _create_sketch()
    p1 = _create_point(sketch["id"], 0.0, 0.0)
    p2 = _create_point(sketch["id"], 10.0, 0.0)
    spline = client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [p1["id"], p2["id"]]},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/splines/{spline['id']}", json={"construction": True}
    )

    assert response.status_code == 200
    assert response.json()["construction"] is True


def test_delete_spline_over_the_api():
    sketch = _create_sketch()
    p1 = _create_point(sketch["id"], 0.0, 0.0)
    p2 = _create_point(sketch["id"], 10.0, 0.0)
    spline = client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [p1["id"], p2["id"]]},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/splines/{spline['id']}")
    # Bug fix (pre-existing stale test - predates `DeleteEntityResponse`;
    # see test_delete_line_over_the_api's own comment in
    # test_stage6_delete.py).
    assert response.status_code == 200

    response = client.get(f"/sketch/sketches/{sketch['id']}/splines/{spline['id']}")
    assert response.status_code == 404


def test_creating_a_3_point_spline_over_the_api_creates_a_solvable_tangent_constraint():
    sketch = _create_sketch()
    p1 = _create_point(sketch["id"], 0.0, 0.0)
    p2 = _create_point(sketch["id"], 10.0, 5.0)
    p3 = _create_point(sketch["id"], 20.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [p1["id"], p2["id"], p3["id"]]},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["converged"] is True


def test_spline_and_line_chain_profile_detection_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 5.0)
    c = _create_point(sketch["id"], 20.0, 0.0)
    d = _create_point(sketch["id"], 20.0, -10.0)
    e = _create_point(sketch["id"], 0.0, -10.0)

    client.post(
        f"/sketch/sketches/{sketch['id']}/splines",
        json={"through_point_ids": [a["id"], b["id"], c["id"]]},
    )
    client.post(f"/sketch/sketches/{sketch['id']}/lines", json={"start_point_id": c["id"], "end_point_id": d["id"]})
    client.post(f"/sketch/sketches/{sketch['id']}/lines", json={"start_point_id": d["id"], "end_point_id": e["id"]})
    client.post(f"/sketch/sketches/{sketch['id']}/lines", json={"start_point_id": e["id"], "end_point_id": a["id"]})

    response = client.get(f"/sketch/sketches/{sketch['id']}/profile")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "closed_loop"
    assert len(body["profile"]["line_ids"]) == 4


# --- Extrude (Spline wire construction) ---------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_extrude_feature(part_id: str, sketch_feature_id: str, *, end_distance: float = 10.0) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": end_distance,
            "target_body_ids": [],
        },
    )
    assert response.status_code == 201
    return response.json()


def test_extruding_a_spline_and_line_profile_produces_a_non_empty_computed_mesh():
    """The Spline wire-construction path in app.document.extrude.
    wire_for_profile (one Geom_BezierCurve edge per internal segment),
    exercised end-to-end through a real extrude - a straight-polygon-only
    wire would silently draw chords across the spline's own curve instead
    of the real cubic segments, but this at least confirms the mixed path
    produces a valid, meshable solid at all - the same shape of check
    test_stage16_arc.py/test_stage17_ellipse.py already run for their own
    curved wire paths."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    a = _create_point(sketch_id, 0.0, 0.0)
    b = _create_point(sketch_id, 10.0, 8.0)
    c = _create_point(sketch_id, 20.0, 0.0)
    d = _create_point(sketch_id, 20.0, -10.0)
    e = _create_point(sketch_id, 0.0, -10.0)

    assert client.post(
        f"/sketch/sketches/{sketch_id}/splines",
        json={"through_point_ids": [a["id"], b["id"], c["id"]]},
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": c["id"], "end_point_id": d["id"]}
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": d["id"], "end_point_id": e["id"]}
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": e["id"], "end_point_id": a["id"]}
    ).status_code == 201

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0


def test_extruding_a_4_through_point_spline_chain_produces_a_non_empty_computed_mesh():
    """Same shape of check as the 3-point test above, but with a spline
    that has 2 interior joints (2 SplineTangentConstraints) instead of 1,
    and the walk tracing it in the *reverse* of its own through_point_ids
    order for one of the two entities that reference it (exercises the
    `profile.point_ids[i] == entity.through_point_ids[-1]` reversal branch
    in wire_for_profile)."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    a = _create_point(sketch_id, 0.0, 0.0)
    b = _create_point(sketch_id, 7.0, 6.0)
    c = _create_point(sketch_id, 14.0, -3.0)
    d = _create_point(sketch_id, 20.0, 0.0)
    e = _create_point(sketch_id, 20.0, -10.0)
    f = _create_point(sketch_id, 0.0, -10.0)

    assert client.post(
        f"/sketch/sketches/{sketch_id}/splines",
        json={"through_point_ids": [a["id"], b["id"], c["id"], d["id"]]},
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": d["id"], "end_point_id": e["id"]}
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": e["id"], "end_point_id": f["id"]}
    ).status_code == 201
    assert client.post(
        f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": f["id"], "end_point_id": a["id"]}
    ).status_code == 201

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0
