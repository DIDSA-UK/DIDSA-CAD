import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_distance_constraint_between_two_existing_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)

    constraint = sketch.add_distance_constraint(a.id, b.id, 50.0)

    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (a.id, b.id)
    assert constraint.distance == 50.0


def test_add_distance_constraint_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_distance_constraint(a.id, "does-not-exist", 10.0)


def test_add_distance_constraint_rejects_same_point_twice():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_distance_constraint(a.id, a.id, 10.0)


def test_solving_two_points_satisfies_distance_constraint():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    sketch.add_distance_constraint(a.id, b.id, 50.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.result_code == 0
    distance = math.hypot(
        sketch.points[b.id].x - sketch.points[a.id].x,
        sketch.points[b.id].y - sketch.points[a.id].y,
    )
    assert distance == pytest.approx(50.0)


def test_solving_a_line_via_its_points_moves_the_line():
    """The actual Stage 2 <-> Stage 2a wiring check: build a Line (which
    only knows about its two Point ids, not constraints), add a distance
    constraint against those same Point ids, solve, and confirm the Line's
    derived length reflects the solved positions - exactly as it does
    when a Point is moved directly via Line.set_length()."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    assert line.length(sketch.points) == pytest.approx(3.0)

    sketch.add_distance_constraint(a.id, b.id, 25.0)
    result = solve_sketch(sketch)

    assert result.converged
    assert line.length(sketch.points) == pytest.approx(25.0)


def test_constraint_with_no_constraints_is_trivially_converged():
    sketch = Sketch(id="s", plane=Plane.XY)
    sketch.add_point(0.0, 0.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.blamed_constraint_ids == []


def test_overconstrained_triangle_reports_non_convergence_and_diagnostics():
    """A, B, C with distances that violate the triangle inequality
    (10 + 10 < 100) can never be simultaneously satisfied."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(5.0, 8.0)

    sketch.add_distance_constraint(a.id, b.id, 10.0)
    sketch.add_distance_constraint(b.id, c.id, 10.0)
    newest = sketch.add_distance_constraint(a.id, c.id, 100.0)

    result = solve_sketch(sketch)

    assert not result.converged
    assert result.result_code != 0
    # Blame convention: the most-recently-added constraint, not a real
    # root-cause diagnosis.
    assert result.blamed_constraint_ids == [newest.id]
    # Genuine py-slvs diagnostics are still surfaced alongside the
    # convention: a Dof reading, and py-slvs's own (coarse) failed-
    # constraint report.
    assert isinstance(result.dof, int)
    assert result.solver_reported_failed_constraint_ids
    assert set(result.solver_reported_failed_constraint_ids) <= set(sketch.constraints)


def test_solve_with_anchor_keeps_the_anchored_point_fixed_and_moves_the_other():
    """Drag-solve semantics: the just-dragged Point should stay exactly
    where the user placed it, with the other end of the Constraint moving
    to satisfy it - not the ordinary "every Point is equally free, current
    position is merely an initial guess" solve behaviour."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    sketch.add_distance_constraint(a.id, b.id, 50.0)

    # Simulate having just dragged `a` to an arbitrary position - without
    # anchoring, an ordinary solve would be free to move it too.
    sketch.points[a.id].x = 3.0
    sketch.points[a.id].y = 4.0

    result = solve_sketch(sketch, anchor_point_ids=frozenset({a.id}))

    assert result.converged
    assert sketch.points[a.id].x == pytest.approx(3.0)
    assert sketch.points[a.id].y == pytest.approx(4.0)
    distance = math.hypot(
        sketch.points[b.id].x - sketch.points[a.id].x,
        sketch.points[b.id].y - sketch.points[a.id].y,
    )
    assert distance == pytest.approx(50.0)
    # b actually moved from its own initial guess to satisfy the
    # constraint relative to the now-fixed a, rather than a moving instead.
    assert (sketch.points[b.id].x, sketch.points[b.id].y) != pytest.approx((10.0, 0.0))


def test_solve_with_two_anchors_that_violate_their_own_distance_constraint_falls_back_to_a_free_solve():
    """Anchoring both ends of a Constraint to positions that don't actually
    satisfy it makes the constraint literally unsatisfiable with both
    Points held fixed (nothing left to solve for) - the conflict case
    flagged as a risk when this feature was scoped. Rather than leaving
    the Sketch stuck in that unconverged, contradictory-looking state
    (both anchors visually "holding" positions 95 units apart from a
    Constraint that says they must be 5 apart) until some unrelated later
    solve corrects it, `solve_sketch` retries with no anchors at all -
    same fallback as the origin-coincidence case below - so it converges
    immediately by freeing both Points to actually satisfy the
    Constraint."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(100.0, 100.0)
    sketch.add_distance_constraint(a.id, b.id, 5.0)

    result = solve_sketch(sketch, anchor_point_ids=frozenset({a.id, b.id}))

    assert result.converged
    distance = math.hypot(
        sketch.points[b.id].x - sketch.points[a.id].x,
        sketch.points[b.id].y - sketch.points[a.id].y,
    )
    assert distance == pytest.approx(5.0)


def test_solve_with_anchor_on_a_point_coincident_to_the_fixed_origin_snaps_back_immediately():
    """Bug-fix round: a Point Coincident with the Sketch's own (permanently
    fixed) origin, dragged away and anchored at the drop location, used to
    report non-convergence but leave the Point exactly where it was
    dropped - since a Point pinned into the fixed group is never touched
    by the solve regardless of whether it converges. That looked like the
    drag "worked" until some unrelated later solve (with no anchor) pulled
    the Point back to satisfy the Coincident constraint - a confusing
    delayed correction reported against a real on-device sketch. Anchoring
    against a fixed origin is exactly the "anchor conflicts with another
    already-fixed position" case `solve_sketch`'s retry-without-anchors
    fallback exists for, so this must now converge and land back on the
    origin in the same solve that the drag ends with."""
    sketch = Sketch(id="s", plane=Plane.XY)
    origin = sketch.origin_point()
    p = sketch.add_point(5.0, 5.0)
    sketch.add_coincident_constraint(p.id, origin.id)

    # Simulate the drag: the client PATCHes the Point to wherever it was
    # dropped, same as updatePointDrag does mid-gesture.
    sketch.points[p.id].x = 40.0
    sketch.points[p.id].y = 40.0

    result = solve_sketch(sketch, anchor_point_ids=frozenset({p.id}))

    assert result.converged
    assert sketch.points[p.id].x == pytest.approx(0.0)
    assert sketch.points[p.id].y == pytest.approx(0.0)


def test_multiple_sketches_have_independent_constraints():
    sketch_one = Sketch(id="s1", plane=Plane.XY)
    a1 = sketch_one.add_point(0.0, 0.0)
    b1 = sketch_one.add_point(1.0, 0.0)
    sketch_one.add_distance_constraint(a1.id, b1.id, 7.0)

    sketch_two = Sketch(id="s2", plane=Plane.XY)
    a2 = sketch_two.add_point(0.0, 0.0)
    b2 = sketch_two.add_point(1.0, 0.0)

    assert len(sketch_one.constraints) == 1
    assert len(sketch_two.constraints) == 0

    result_one = solve_sketch(sketch_one)
    result_two = solve_sketch(sketch_two)

    assert result_one.converged
    distance_one = math.hypot(
        sketch_one.points[b1.id].x - sketch_one.points[a1.id].x,
        sketch_one.points[b1.id].y - sketch_one.points[a1.id].y,
    )
    assert distance_one == pytest.approx(7.0)
    # sketch_two had no constraints, so its points are untouched.
    assert sketch_two.points[a2.id].x == pytest.approx(0.0)
    assert sketch_two.points[b2.id].x == pytest.approx(1.0)
    assert result_two.converged
    assert result_two.detail == "No constraints to solve."


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 12.0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "distance"
    assert body["point_a_id"] == a["id"]
    assert body["point_b_id"] == b["id"]
    assert body["distance"] == pytest.approx(12.0)


def test_create_constraint_with_unknown_point_is_404():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": "does-not-exist", "distance": 1.0},
    )
    assert response.status_code == 404


def test_create_constraint_rejects_same_point_twice_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": a["id"], "distance": 1.0},
    )
    assert response.status_code == 400


def test_list_constraints_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    )

    response = client.get(f"/sketch/sketches/{sketch['id']}/constraints")

    assert response.status_code == 200
    assert len(response.json()) == 1


def test_delete_constraint_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/constraints/{created['id']}")
    assert response.status_code == 204

    response = client.get(f"/sketch/sketches/{sketch['id']}/constraints")
    assert response.json() == []


def test_delete_unknown_constraint_is_404():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/constraints/does-not-exist")
    assert response.status_code == 404


def test_moving_a_point_directly_does_not_trigger_a_solve():
    """PATCH on a Point only updates its position - it is the next initial
    guess, not a solved result. Moving b away from where the constraint
    would put it, then never calling /solve, must leave it exactly where
    PATCH put it."""
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 50.0},
    )

    client.patch(f"/sketch/sketches/{sketch['id']}/points/{b['id']}", json={"x": 99.0, "y": 99.0})

    moved = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    assert moved["x"] == pytest.approx(99.0)
    assert moved["y"] == pytest.approx(99.0)


def test_solve_over_the_api_updates_points_and_reports_convergence():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 50.0},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    body = response.json()
    assert body["converged"] is True
    assert body["result_code"] == 0
    assert body["blamed_constraint_ids"] == []

    solved_a = client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").json()
    solved_b = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    distance = math.hypot(solved_b["x"] - solved_a["x"], solved_b["y"] - solved_a["y"])
    assert distance == pytest.approx(50.0)


def test_solve_over_the_api_reports_non_convergence_for_overconstrained_sketch():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 5.0, 8.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 10.0},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": b["id"], "point_b_id": c["id"], "distance": 10.0},
    )
    newest = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": c["id"], "distance": 100.0},
    ).json()

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    body = response.json()
    assert body["converged"] is False
    assert body["blamed_constraint_ids"] == [newest["id"]]
    assert body["solver_reported_failed_constraint_ids"]


def test_solve_over_the_api_with_anchor_keeps_the_anchored_point_fixed():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 50.0},
    )
    # Simulate a drag: PATCH a to a new position (its own next initial
    # guess - see test_moving_a_point_directly_does_not_trigger_a_solve),
    # then solve anchored to it.
    client.patch(f"/sketch/sketches/{sketch['id']}/points/{a['id']}", json={"x": 3.0, "y": 4.0})

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/solve",
        json={"anchor_point_ids": [a["id"]]},
    )

    assert response.status_code == 200
    assert response.json()["converged"] is True

    solved_a = client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").json()
    solved_b = client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").json()
    assert solved_a["x"] == pytest.approx(3.0)
    assert solved_a["y"] == pytest.approx(4.0)
    distance = math.hypot(solved_b["x"] - solved_a["x"], solved_b["y"] - solved_a["y"])
    assert distance == pytest.approx(50.0)


def test_solve_over_the_api_with_anchor_on_a_point_coincident_to_the_origin_snaps_back_immediately():
    """API-level counterpart of
    test_solve_with_anchor_on_a_point_coincident_to_the_fixed_origin_snaps_back_immediately
    - exercises the same bug through the real /solve endpoint rather than
    calling solve_sketch directly."""
    sketch = _create_sketch()
    p = _create_point(sketch["id"], 5.0, 5.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "coincident", "point_a_id": p["id"], "point_b_id": sketch["origin_point_id"]},
    )
    client.patch(f"/sketch/sketches/{sketch['id']}/points/{p['id']}", json={"x": 40.0, "y": 40.0})

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/solve",
        json={"anchor_point_ids": [p["id"]]},
    )

    assert response.status_code == 200
    assert response.json()["converged"] is True
    solved_p = client.get(f"/sketch/sketches/{sketch['id']}/points/{p['id']}").json()
    assert solved_p["x"] == pytest.approx(0.0)
    assert solved_p["y"] == pytest.approx(0.0)


def test_solve_over_the_api_with_no_body_still_works():
    """Every caller from before this field existed POSTs no body at all -
    confirms that keeps working unchanged (SolveRequest is an optional
    param, not a required one)."""
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    )

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve")

    assert response.status_code == 200
    assert response.json()["converged"] is True


# --- solve-and-refresh (Phase 0 round-trip reduction) -----------------------


def test_solve_and_refresh_bundles_solve_points_constraints_and_profile_in_one_response():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 1.0, 0.0)
    constraint = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 50.0},
    ).json()

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve-and-refresh")

    assert response.status_code == 200
    body = response.json()

    # Same solve outcome as the plain /solve endpoint would report.
    assert body["solve"]["converged"] is True
    assert body["solve"]["result_code"] == 0

    # Points reflect the same post-solve positions a separate listPoints
    # call would - the whole point of bundling this response.
    points_by_id = {p["id"]: p for p in body["points"]}
    distance = math.hypot(
        points_by_id[b["id"]]["x"] - points_by_id[a["id"]]["x"],
        points_by_id[b["id"]]["y"] - points_by_id[a["id"]]["y"],
    )
    assert distance == pytest.approx(50.0)
    # The Sketch's own lazily-created origin Point is included too, same as
    # a plain listPoints call would return.
    assert sketch["origin_point_id"] in points_by_id

    constraint_ids = {c["id"] for c in body["constraints"]}
    assert constraint["id"] in constraint_ids

    # Two Points and no Line between them - nothing closed to detect.
    assert body["profile"]["status"] == "no_loop"


def test_solve_and_refresh_with_anchor_keeps_the_anchored_point_fixed():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 50.0},
    )
    client.patch(f"/sketch/sketches/{sketch['id']}/points/{a['id']}", json={"x": 3.0, "y": 4.0})

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/solve-and-refresh",
        json={"anchor_point_ids": [a["id"]]},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["solve"]["converged"] is True
    points_by_id = {p["id"]: p for p in body["points"]}
    assert points_by_id[a["id"]]["x"] == pytest.approx(3.0)
    assert points_by_id[a["id"]]["y"] == pytest.approx(4.0)


def test_solve_and_refresh_reports_non_convergence_same_as_plain_solve():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    c = _create_point(sketch["id"], 5.0, 8.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 10.0},
    )
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": b["id"], "point_b_id": c["id"], "distance": 10.0},
    )
    newest = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": c["id"], "distance": 100.0},
    ).json()

    response = client.post(f"/sketch/sketches/{sketch['id']}/solve-and-refresh")

    assert response.status_code == 200
    body = response.json()
    assert body["solve"]["converged"] is False
    assert body["solve"]["blamed_constraint_ids"] == [newest["id"]]
