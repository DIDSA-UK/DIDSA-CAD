import json
import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.main import app
from app.sketch.constraints import (
    FixedConstraint,
    PointOnCircleConstraint,
    PointOnEllipseConstraint,
    PointOnLineConstraint,
)
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _dist(sketch: Sketch, point_a_id: str, point_b_id: str) -> float:
    a = sketch.points[point_a_id]
    b = sketch.points[point_b_id]
    return math.hypot(a.x - b.x, a.y - b.y)


# --- PointOnLineConstraint: pure domain model --------------------------------


def test_add_point_on_line_constraint_between_an_existing_point_and_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    p = sketch.add_point(3.0, 4.0)

    constraint = sketch.add_point_on_line_constraint(p.id, line.id)

    assert isinstance(constraint, PointOnLineConstraint)
    assert constraint.id in sketch.constraints
    assert constraint.point_ids() == (p.id, a.id, b.id)


def test_add_point_on_line_constraint_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    with pytest.raises(KeyError):
        sketch.add_point_on_line_constraint("does-not-exist", line.id)


def test_add_point_on_line_constraint_with_non_line_entity_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    p = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_point_on_line_constraint(p.id, "does-not-exist")


def test_add_point_on_line_constraint_rejects_the_lines_own_endpoint():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    with pytest.raises(ValueError):
        sketch.add_point_on_line_constraint(a.id, line.id)


def test_solving_pulls_a_free_point_onto_a_fixed_line():
    """The line's own endpoints are pinned via FixedConstraint so the check
    below isolates PointOnLineConstraint's own effect rather than the whole,
    under-determined system finding some other valid configuration."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_fixed_constraint(line.id)
    p = sketch.add_point(3.0, 4.0)
    sketch.add_point_on_line_constraint(p.id, line.id)

    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[p.id].y == pytest.approx(0.0)
    assert sketch.points[a.id].x == pytest.approx(0.0)
    assert sketch.points[b.id].x == pytest.approx(10.0)


# --- PointOnCircleConstraint: pure domain model ------------------------------


def test_add_point_on_circle_constraint_between_an_existing_point_and_circle():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)
    p = sketch.add_point(3.0, 3.0)

    constraint = sketch.add_point_on_circle_constraint(p.id, circle.id)

    assert isinstance(constraint, PointOnCircleConstraint)
    assert constraint.id in sketch.constraints
    assert constraint.center_point_id == center.id


def test_add_point_on_circle_constraint_also_accepts_an_arc():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    end = sketch.add_point(0.0, 5.0)
    arc = sketch.add_arc(center.id, start.id, end.id)
    p = sketch.add_point(1.0, 1.0)

    constraint = sketch.add_point_on_circle_constraint(p.id, arc.id)

    assert constraint.circle_or_arc_id == arc.id


def test_add_point_on_circle_constraint_rejects_the_circles_own_centre():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)
    with pytest.raises(ValueError):
        sketch.add_point_on_circle_constraint(center.id, circle.id)


def test_add_point_on_circle_constraint_with_non_circle_entity_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    p = sketch.add_point(1.0, 1.0)
    with pytest.raises(KeyError):
        sketch.add_point_on_circle_constraint(p.id, line.id)


def test_solving_pulls_a_free_point_onto_a_fixed_circle():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)
    sketch.add_fixed_constraint(circle.id)
    p = sketch.add_point(3.0, 3.0)
    sketch.add_point_on_circle_constraint(p.id, circle.id)

    result = solve_sketch(sketch)

    assert result.converged
    assert _dist(sketch, p.id, center.id) == pytest.approx(5.0)
    assert sketch.points[center.id].x == pytest.approx(0.0)
    assert sketch.points[center.id].y == pytest.approx(0.0)


# --- FixedConstraint: pure domain model --------------------------------------


def test_add_fixed_constraint_on_a_bare_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    p = sketch.add_point(7.0, 7.0)

    constraint = sketch.add_fixed_constraint(p.id)

    assert isinstance(constraint, FixedConstraint)
    assert constraint.fixed_point_ids == [p.id]
    assert sketch.is_point_locked(p.id) is True


def test_add_fixed_constraint_on_a_line_covers_both_endpoints():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)

    constraint = sketch.add_fixed_constraint(line.id)

    assert set(constraint.fixed_point_ids) == {a.id, b.id}
    assert sketch.is_point_locked(a.id) is True
    assert sketch.is_point_locked(b.id) is True


def test_add_fixed_constraint_on_a_circle_covers_centre_radius_and_cardinal_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)

    constraint = sketch.add_fixed_constraint(circle.id)

    expected = {circle.center_point_id, circle.radius_point_id, *circle.cardinal_point_ids}
    assert set(constraint.fixed_point_ids) == expected


def test_add_fixed_constraint_on_unknown_entity_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.add_fixed_constraint("does-not-exist")


def test_add_fixed_constraint_twice_on_the_same_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    p = sketch.add_point(1.0, 1.0)
    sketch.add_fixed_constraint(p.id)
    with pytest.raises(ValueError):
        sketch.add_fixed_constraint(p.id)


def test_add_fixed_constraint_on_an_arc_skips_points_already_external_or_fixed():
    """Mirrors convert_body_edge's own Arc-conversion shape: start/end are
    already locked by some other mechanism (here, a prior FixedConstraint
    standing in for external_references) - add_fixed_constraint must fold
    in only the centre, not raise just because *some* of the Arc's Points
    are already covered."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    end = sketch.add_point(0.0, 5.0)
    arc = sketch.add_arc(center.id, start.id, end.id)
    sketch.add_fixed_constraint(start.id)
    sketch.add_fixed_constraint(end.id)

    constraint = sketch.add_fixed_constraint(arc.id)

    assert constraint.fixed_point_ids == [center.id]


def test_unfix_via_generic_constraint_delete_frees_the_point_again():
    sketch = Sketch(id="s", plane=Plane.XY)
    p = sketch.add_point(7.0, 7.0)
    constraint = sketch.add_fixed_constraint(p.id)
    assert sketch.is_point_locked(p.id) is True

    del sketch.constraints[constraint.id]

    assert sketch.is_point_locked(p.id) is False


def test_fixed_point_stays_put_while_a_tied_free_point_moves_to_satisfy_a_distance():
    sketch = Sketch(id="s", plane=Plane.XY)
    fixed_pt = sketch.add_point(7.0, 7.0)
    other_pt = sketch.add_point(0.0, 0.0)
    sketch.add_fixed_constraint(fixed_pt.id)
    sketch.add_distance_constraint(fixed_pt.id, other_pt.id, 5.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[fixed_pt.id].x == pytest.approx(7.0)
    assert sketch.points[fixed_pt.id].y == pytest.approx(7.0)
    assert _dist(sketch, fixed_pt.id, other_pt.id) == pytest.approx(5.0)


def test_a_fixed_point_that_conflicts_with_another_constraint_fails_to_converge_with_a_real_blame():
    """FixedConstraint's own SolverBuilder.where_dragged is a real py-slvs
    constraint with its own real handle (unlike the fixed-group placement
    origin/external_references use) - a genuine conflict must surface as a
    solve failure naming a real constraint in this Sketch, not silently
    never converge with an empty blame list. Deliberately doesn't assert
    *which* of the two conflicting constraints (FixedConstraint vs.
    CoincidentConstraint) py-slvs's own `system.Failed` names - confirmed
    empirically that this depends on solve-time add order, not a contract
    either constraint type makes."""
    sketch = Sketch(id="s", plane=Plane.XY)
    origin = sketch.origin_point()
    p = sketch.add_point(9.0, 9.0)
    fixed_constraint = sketch.add_fixed_constraint(p.id)
    coincident_constraint = sketch.add_coincident_constraint(origin.id, p.id)

    result = solve_sketch(sketch)

    assert result.converged is False
    assert result.solver_reported_failed_constraint_ids
    assert set(result.solver_reported_failed_constraint_ids) <= {
        fixed_constraint.id,
        coincident_constraint.id,
    }


# --- Redundancy-fixture regression check (sibling-branch flagged risk) ------


def test_fixed_constraint_on_an_hv_tied_rectangle_corner_does_not_falsely_report_over_constrained():
    """Root-cause regression fixture for the same class of bug the
    AtMidpointConstraint/H+V rectangle redundancy clash already fixed on
    this branch (see solver.py's own `_RESIDUAL_CHECKABLE_CONSTRAINT_TYPES`
    doc comment): a Rectangle's own H/V axis-constraint chain plus its
    AtMidpointConstraint diagonal tie is already redundant by construction,
    so stacking one further genuinely-implied Constraint on top (here, a
    FixedConstraint on one corner) is exactly the shape that previously
    tripped py-slvs's own ambiguous result_code before the residual-
    verification fix landed. Confirms a FixedConstraint doesn't reopen that
    class of false positive."""
    sketch = Sketch(id="s", plane=Plane.XY)
    corner0 = sketch.add_point(0.0, 0.0)
    corner1 = sketch.add_point(10.0, 0.0)
    corner2 = sketch.add_point(10.0, 5.0)
    corner3 = sketch.add_point(0.0, 5.0)
    sketch.add_rectangle([corner0.id, corner1.id, corner2.id, corner3.id])

    sketch.add_fixed_constraint(corner0.id)

    result = solve_sketch(sketch)

    assert result.converged is True
    assert sketch.points[corner0.id].x == pytest.approx(0.0)
    assert sketch.points[corner0.id].y == pytest.approx(0.0)


# --- HTTP-level round trip ----------------------------------------------------


def test_point_on_line_and_fixed_constraints_over_the_api():
    sketch = client.post("/sketch/sketches", json={"plane": "XY"}).json()
    sketch_id = sketch["id"]
    a = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0, "y": 0}).json()
    b = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10, "y": 0}).json()
    line = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()
    p = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 3, "y": 4}).json()

    resp = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "point_on_line", "point_id": p["id"], "line_id": line["id"]},
    )
    assert resp.status_code == 201
    assert resp.json()["type"] == "point_on_line"

    fix_resp = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "fixed", "entity_id": line["id"]},
    )
    assert fix_resp.status_code == 201
    fixed_id = fix_resp.json()["id"]
    assert set(fix_resp.json()["point_ids"]) == {a["id"], b["id"]}

    point_a = client.get(f"/sketch/sketches/{sketch_id}/points/{a['id']}").json()
    assert point_a["is_locked"] is True

    solve_resp = client.post(f"/sketch/sketches/{sketch_id}/solve")
    assert solve_resp.status_code == 200
    assert solve_resp.json()["converged"] is True

    delete_resp = client.delete(f"/sketch/sketches/{sketch_id}/constraints/{fixed_id}")
    assert delete_resp.status_code == 204

    point_a_after = client.get(f"/sketch/sketches/{sketch_id}/points/{a['id']}").json()
    assert point_a_after["is_locked"] is False


def test_point_on_circle_constraint_over_the_api():
    sketch = client.post("/sketch/sketches", json={"plane": "XY"}).json()
    sketch_id = sketch["id"]
    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0, "y": 0}).json()
    circle = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center["id"], "radius": 5},
    ).json()
    p = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 3, "y": 3}).json()

    resp = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "point_on_circle", "point_id": p["id"], "circle_or_arc_id": circle["id"]},
    )

    assert resp.status_code == 201
    assert resp.json()["circle_or_arc_id"] == circle["id"]


def test_creating_a_second_fixed_constraint_over_the_api_on_an_already_fixed_point_returns_400():
    sketch = client.post("/sketch/sketches", json={"plane": "XY"}).json()
    sketch_id = sketch["id"]
    p = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 1, "y": 1}).json()
    first = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "fixed", "entity_id": p["id"]},
    )
    assert first.status_code == 201

    second = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "fixed", "entity_id": p["id"]},
    )

    assert second.status_code == 400


# --- native_format.py round trip + pinned_point_ids backward compatibility --


def test_new_constraint_types_round_trip_through_native_format_json():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    p = sketch.add_point(3.0, 4.0)
    sketch.add_point_on_line_constraint(p.id, line.id)
    center = sketch.add_point(20.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0)
    p2 = sketch.add_point(23.0, 3.0)
    sketch.add_point_on_circle_constraint(p2.id, circle.id)
    sketch.add_fixed_constraint(line.id)

    data = sketch_to_dict(sketch)
    assert "pinned_point_ids" not in data
    restored = sketch_from_dict(json.loads(json.dumps(data)))

    restored_types = {c.type for c in restored.constraints.values()}
    assert {"point_on_line", "point_on_circle", "fixed"} <= restored_types
    assert restored.is_point_locked(a.id) is True
    assert restored.is_point_locked(b.id) is True


def test_loading_a_pre_fixed_constraint_file_migrates_pinned_point_ids_to_a_real_constraint():
    """Backward compatibility for a native file saved before `pinned_point_
    ids` was replaced by `FixedConstraint` - the removed field's raw point
    ids still round-trip correctly into real, deletable FixedConstraints."""
    sketch = Sketch(id="s", plane=Plane.XY)
    legacy_pinned_point = sketch.add_point(1.0, 1.0)
    data = sketch_to_dict(sketch)
    data["pinned_point_ids"] = [legacy_pinned_point.id]  # simulate a pre-migration save file

    restored = sketch_from_dict(data)

    assert restored.is_point_locked(legacy_pinned_point.id) is True
    fixed_constraints = [c for c in restored.constraints.values() if isinstance(c, FixedConstraint)]
    assert len(fixed_constraints) == 1
    assert fixed_constraints[0].fixed_point_ids == [legacy_pinned_point.id]


# --- PointOnEllipseConstraint: pure domain model ------------------------------


def test_add_point_on_ellipse_constraint_between_an_existing_point_and_ellipse():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major_radius=8.0, angle=0.0, minor_radius=3.0)
    p = sketch.add_point(5.0, 2.0)

    constraint = sketch.add_point_on_ellipse_constraint(p.id, ellipse.id)

    assert isinstance(constraint, PointOnEllipseConstraint)
    assert constraint.id in sketch.constraints
    assert constraint.center_point_id == center.id
    assert constraint.major_point_id == ellipse.major_point_id
    assert constraint.minor_point_id == ellipse.minor_point_id


def test_add_point_on_ellipse_constraint_with_unknown_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major_radius=8.0, angle=0.0, minor_radius=3.0)
    with pytest.raises(KeyError):
        sketch.add_point_on_ellipse_constraint("does-not-exist", ellipse.id)


def test_add_point_on_ellipse_constraint_with_non_ellipse_entity_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    p = sketch.add_point(1.0, 1.0)
    with pytest.raises(KeyError):
        sketch.add_point_on_ellipse_constraint(p.id, line.id)


def test_add_point_on_ellipse_constraint_rejects_the_ellipses_own_centre():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major_radius=8.0, angle=0.0, minor_radius=3.0)
    with pytest.raises(ValueError):
        sketch.add_point_on_ellipse_constraint(center.id, ellipse.id)


def _ellipse_equation_residual(sketch: Sketch, ellipse, point_id: str) -> float:
    """`(u/a)^2 + (v/b)^2 - 1` in the Ellipse's own (possibly rotated,
    possibly off-origin) frame - reads centre/major/minor Point positions
    straight from `sketch.points` rather than the literal values the
    Ellipse was created with, so this stays correct even after a solve
    that moved the Ellipse itself (e.g. an unfixed one)."""
    center = sketch.points[ellipse.center_point_id]
    major = sketch.points[ellipse.major_point_id]
    minor = sketch.points[ellipse.minor_point_id]
    point = sketch.points[point_id]
    major_radius = math.hypot(major.x - center.x, major.y - center.y)
    minor_radius = math.hypot(minor.x - center.x, minor.y - center.y)
    angle = math.atan2(major.y - center.y, major.x - center.x)
    dx, dy = point.x - center.x, point.y - center.y
    ca, sa = math.cos(-angle), math.sin(-angle)
    u = dx * ca - dy * sa
    v = dx * sa + dy * ca
    return (u / major_radius) ** 2 + (v / minor_radius) ** 2 - 1.0


def test_solving_pulls_a_free_point_onto_a_fixed_ellipse():
    """Mirrors test_solving_pulls_a_free_point_onto_a_fixed_circle - the
    Ellipse's own defining Points are pinned via FixedConstraint (the
    single, unified "this is immobile" mechanism every entity type shares)
    so the point-on-curve effect is isolated from the rest of an
    under-determined system finding some other valid configuration."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major_radius=8.0, angle=0.0, minor_radius=3.0)
    sketch.add_fixed_constraint(ellipse.id)
    p = sketch.add_point(5.0, 2.0)
    sketch.add_point_on_ellipse_constraint(p.id, ellipse.id)

    result = solve_sketch(sketch)

    assert result.converged, result.detail
    assert result.dof == 1
    assert _ellipse_equation_residual(sketch, ellipse, p.id) == pytest.approx(0.0, abs=1e-6)
    assert sketch.points[center.id].x == pytest.approx(0.0)
    assert sketch.points[center.id].y == pytest.approx(0.0)


def test_solving_pulls_a_free_point_onto_a_fixed_rotated_ellipse():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(-3.0, 5.0)
    ellipse = sketch.add_ellipse(
        center.id, major_radius=7.0, angle=math.radians(-60), minor_radius=4.0
    )
    sketch.add_fixed_constraint(ellipse.id)
    p = sketch.add_point(-1.0, 2.0)
    sketch.add_point_on_ellipse_constraint(p.id, ellipse.id)

    result = solve_sketch(sketch)

    assert result.converged, result.detail
    assert result.dof == 1
    assert _ellipse_equation_residual(sketch, ellipse, p.id) == pytest.approx(0.0, abs=1e-6)


def test_fixing_an_ellipse_alone_converges_cleanly():
    """Regression test for a gap this feature's own verification uncovered:
    `add_fixed_constraint` on an Ellipse (no PointOnEllipseConstraint
    involved at all) used to report `converged=False`/`dof=0` even though
    every Point landed exactly where it should - `add_ellipse`'s own
    DistanceConstraint(radius)/PerpendicularConstraint chain becomes a
    zero-derivative ("redundant") row in py-slvs's Jacobian the moment
    every Point it references is pinned, the same structural situation
    Circle's own Fix already had to be rescued from (see
    `_REDUNDANCY_SAFE_CONSTRAINT_TYPES`'s own comment in solver.py) - see
    the new override in `_solve_sketch_once` (gated on
    `_ellipse_owned_at_midpoint_constraint_ids`) for the fix."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major_radius=8.0, angle=0.0, minor_radius=3.0)

    sketch.add_fixed_constraint(ellipse.id)
    result = solve_sketch(sketch)

    assert result.converged, result.detail


def test_point_on_ellipse_constraint_over_the_api():
    sketch = client.post("/sketch/sketches", json={"plane": "XY"}).json()
    sketch_id = sketch["id"]
    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0, "y": 0}).json()
    ellipse = client.post(
        f"/sketch/sketches/{sketch_id}/ellipses",
        json={"center_point_id": center["id"], "major_radius": 8, "angle": 0, "minor_radius": 3},
    ).json()
    p = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 5, "y": 2}).json()

    resp = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "point_on_ellipse", "point_id": p["id"], "ellipse_id": ellipse["id"]},
    )

    assert resp.status_code == 201
    body = resp.json()
    assert body["type"] == "point_on_ellipse"
    assert body["ellipse_id"] == ellipse["id"]
    assert body["center_point_id"] == center["id"]
    assert body["major_point_id"] == ellipse["major_point_id"]
    assert body["minor_point_id"] == ellipse["minor_point_id"]

    fix_resp = client.post(
        f"/sketch/sketches/{sketch_id}/constraints",
        json={"type": "fixed", "entity_id": ellipse["id"]},
    )
    assert fix_resp.status_code == 201

    solve_resp = client.post(f"/sketch/sketches/{sketch_id}/solve")
    assert solve_resp.status_code == 200
    assert solve_resp.json()["converged"] is True


def test_point_on_ellipse_constraint_round_trips_through_native_format_json():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major_radius=8.0, angle=0.0, minor_radius=3.0)
    p = sketch.add_point(5.0, 2.0)
    sketch.add_point_on_ellipse_constraint(p.id, ellipse.id)
    sketch.add_fixed_constraint(ellipse.id)

    data = sketch_to_dict(sketch)
    restored = sketch_from_dict(json.loads(json.dumps(data)))

    restored_types = {c.type for c in restored.constraints.values()}
    assert "point_on_ellipse" in restored_types
    result = solve_sketch(restored)
    assert result.converged, result.detail
