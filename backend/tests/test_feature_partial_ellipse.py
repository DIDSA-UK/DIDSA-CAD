import json
import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.main import app
from app.sketch.models import EllipseArc, NoIntersectionFoundError, Plane, Sketch
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.solver import solve_sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _ellipse_equation_residual(sketch: Sketch, arc: EllipseArc, point_id: str) -> float:
    center = sketch.points[arc.center_point_id]
    major = sketch.points[arc.major_point_id]
    minor = sketch.points[arc.minor_point_id]
    point = sketch.points[point_id]
    major_radius = math.hypot(major.x - center.x, major.y - center.y)
    minor_radius = math.hypot(minor.x - center.x, minor.y - center.y)
    rotation = math.atan2(major.y - center.y, major.x - center.x)
    dx, dy = point.x - center.x, point.y - center.y
    ca, sa = math.cos(-rotation), math.sin(-rotation)
    u = dx * ca - dy * sa
    v = dx * sa + dy * ca
    return (u / major_radius) ** 2 + (v / minor_radius) ** 2 - 1.0


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_ellipse_arc_places_start_and_end_at_the_given_parametric_angles():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)

    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.3, 2.0)

    assert isinstance(arc, EllipseArc)
    assert arc.local_angle(sketch.points, arc.start_point_id) == pytest.approx(0.3)
    assert arc.local_angle(sketch.points, arc.end_point_id) == pytest.approx(2.0)
    assert arc.major_radius(sketch.points) == pytest.approx(8.0)
    assert arc.minor_radius(sketch.points) == pytest.approx(3.0)
    assert arc.rotation(sketch.points) == pytest.approx(0.0)


def test_add_ellipse_arc_with_rotated_major_axis():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(-3.0, 5.0)
    rotation = math.radians(35)
    major = sketch.add_point(-3.0 + 7.0 * math.cos(rotation), 5.0 + 7.0 * math.sin(rotation))

    arc = sketch.add_ellipse_arc(center.id, major.id, 4.0, 0.5, 4.0)

    assert arc.rotation(sketch.points) == pytest.approx(rotation)
    assert _ellipse_equation_residual(sketch, arc, arc.start_point_id) == pytest.approx(0.0, abs=1e-9)
    assert _ellipse_equation_residual(sketch, arc, arc.end_point_id) == pytest.approx(0.0, abs=1e-9)


def test_add_ellipse_arc_rejects_same_center_and_major_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse_arc(center.id, center.id, 3.0, 0.0, 1.0)


def test_add_ellipse_arc_rejects_non_positive_minor_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse_arc(center.id, major.id, 0.0, 0.0, 1.0)


def test_add_ellipse_arc_rejects_minor_radius_exceeding_major_radius():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(5.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse_arc(center.id, major.id, 9.0, 0.0, 1.0)


def test_add_ellipse_arc_rejects_coincident_start_and_end_angles():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    with pytest.raises(ValueError):
        sketch.add_ellipse_arc(center.id, major.id, 3.0, 1.2, 1.2)
    with pytest.raises(ValueError):
        # Same angle modulo 2*pi is still degenerate, not a full ellipse.
        sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.5, 0.5 + 2 * math.pi)


def test_add_ellipse_arc_with_unknown_major_point_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    with pytest.raises(KeyError):
        sketch.add_ellipse_arc(center.id, "does-not-exist", 3.0, 0.0, 1.0)


def test_ellipse_arc_endpoint_point_ids_are_start_and_end():
    """Unlike Ellipse (never a chain participant), EllipseArc overrides
    endpoint_point_ids() the same way Arc does - see EllipseArc's own
    docstring."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.0, 2.0)

    assert arc.endpoint_point_ids() == (arc.start_point_id, arc.end_point_id)


def test_delete_ellipse_arc_removes_its_constraints_axis_lines_and_prunes_points():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.3, 2.0)
    entity_count_before = len(sketch.entities)
    constraint_count_before = len(sketch.constraints)

    pruned = sketch.delete_ellipse_arc(arc.id)

    assert arc.id not in sketch.entities
    assert arc.major_axis_line_id not in sketch.entities
    assert arc.minor_axis_line_id not in sketch.entities
    assert arc.major_constraint_id not in sketch.constraints
    assert arc.minor_constraint_id not in sketch.constraints
    assert arc.perpendicular_constraint_id not in sketch.constraints
    assert arc.start_on_ellipse_constraint_id not in sketch.constraints
    assert arc.end_on_ellipse_constraint_id not in sketch.constraints
    assert entity_count_before - len(sketch.entities) == 3  # arc + 2 axis lines
    assert constraint_count_before - len(sketch.constraints) == 5
    assert set(pruned) == {center.id, major.id, arc.start_point_id, arc.end_point_id, arc.minor_point_id}
    assert len(sketch.points) == 0


def test_delete_ellipse_arc_on_unknown_id_raises():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_ellipse_arc("does-not-exist")


# --- Solver: DOF / convergence -----------------------------------------------


def test_solving_a_fixed_ellipse_arc_converges_with_start_and_end_exactly_on_the_curve():
    """Regression test for the same kind of Fix-on-an-internally-
    constrained-entity redundancy PointOnEllipseConstraint's own feature
    surfaced for a plain Ellipse (see solver.py's Ellipse/EllipseArc
    override) - confirms it's fixed for EllipseArc too, not just Ellipse."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.3, 2.0)
    sketch.add_fixed_constraint(arc.id)

    result = solve_sketch(sketch)

    assert result.converged, result.detail
    assert _ellipse_equation_residual(sketch, arc, arc.start_point_id) == pytest.approx(0.0, abs=1e-6)
    assert _ellipse_equation_residual(sketch, arc, arc.end_point_id) == pytest.approx(0.0, abs=1e-6)
    assert sketch.points[center.id].x == pytest.approx(0.0)
    assert sketch.points[center.id].y == pytest.approx(0.0)


@pytest.mark.parametrize(
    "cx,cy,major_r,minor_r,rotation,start,end",
    [
        (0.0, 0.0, 8.0, 3.0, 0.0, 0.3, 2.0),
        (4.0, -2.0, 6.0, 2.0, math.radians(35), 0.5, 4.0),
        (0.0, 0.0, 5.0, 4.9, 0.0, -1.0, 1.0),
        (1.0, 1.0, 10.0, 1.5, math.radians(-70), 1.0, 5.5),
    ],
)
def test_solving_a_fixed_ellipse_arc_converges_across_varied_configurations(
    cx, cy, major_r, minor_r, rotation, start, end
):
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(cx, cy)
    major = sketch.add_point(cx + major_r * math.cos(rotation), cy + major_r * math.sin(rotation))
    arc = sketch.add_ellipse_arc(center.id, major.id, minor_r, start, end)
    sketch.add_fixed_constraint(arc.id)

    result = solve_sketch(sketch)

    assert result.converged, result.detail
    assert _ellipse_equation_residual(sketch, arc, arc.start_point_id) == pytest.approx(0.0, abs=1e-6)
    assert _ellipse_equation_residual(sketch, arc, arc.end_point_id) == pytest.approx(0.0, abs=1e-6)


def test_solving_a_freshly_drawn_unanchored_ellipse_arc_does_not_move_it():
    """Bug fix (on-device feedback: "the elliptical arc is not as the user
    draws it... feels like the solver changes the shape after drawing and
    does not respect the points placed by user"): unlike the two tests
    above, this leaves *everything* free - no FixedConstraint, no anchors -
    exactly the state right after the draw tool places an EllipseArc and
    calls /solve for the first time, before any drag ever touches it.

    Root cause: PointOnEllipseConstraint's trammel auxiliary points (M/N)
    used to be seeded at major_point's/minor_point's own position - at
    distance major_radius/minor_radius from centre, the WRONG distance for
    the trammel rod (which is major_radius+minor_radius long - see that
    class's own doc comment for the algebra). That seed carried a nonzero
    residual into the very first solve even though every Point started
    exactly self-consistent (add_ellipse_arc places start/end exactly on
    the curve by construction) - and since nothing here pins the arc's own
    centre/rotation, Newton absorbed that spurious residual as a visible
    rigid shift/rotation of the whole arc. Confirmed empirically before this
    fix: the exact same setup below drifted individual Points by 1.4-2.5
    units (on a shape with major_radius=6) after a single unanchored solve.
    """
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(3.0, -2.0)
    major = sketch.add_point(9.0, -2.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, minor_radius=2.5, start_angle=0.3, end_angle=2.1)
    before = {point_id: (p.x, p.y) for point_id, p in sketch.points.items()}

    result = solve_sketch(sketch)

    assert result.converged, result.detail
    for point_id, (bx, by) in before.items():
        after = sketch.points[point_id]
        assert after.x == pytest.approx(bx, abs=1e-6), f"{point_id}.x drifted"
        assert after.y == pytest.approx(by, abs=1e-6), f"{point_id}.y drifted"


# --- trim_ellipse (v1: Line targets only) --------------------------------------


def test_trim_ellipse_excludes_the_clicked_segment_and_keeps_the_rest():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(10.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=5.0)
    a = sketch.add_point(5.0, -20.0)
    b = sketch.add_point(5.0, 20.0)
    sketch.add_line(a.id, b.id)

    # The vertical line x=5 crosses the ellipse at (5, +/-5*sqrt(3)/2), a
    # local-angle 60deg/300deg pair. Clicking near the top (0, 5) - inside
    # the 240deg span between them, going the long way through 90/180/270 -
    # should exclude that whole span, keeping only the short 120deg arc on
    # the ellipse's own right side.
    arc, pruned_point_ids = sketch.trim_ellipse(ellipse.id, 0.0, 5.0)

    assert isinstance(arc, EllipseArc)
    assert ellipse.id not in sketch.entities
    assert arc.major_radius(sketch.points) == pytest.approx(10.0)
    assert arc.minor_radius(sketch.points) == pytest.approx(5.0)
    start = sketch.points[arc.start_point_id]
    end = sketch.points[arc.end_point_id]
    assert (start.x, start.y) == pytest.approx((5.0, -4.330127018922193))
    assert (end.x, end.y) == pytest.approx((5.0, 4.330127018922193))
    # The old Ellipse's own negative axis tips are pruned - the new
    # EllipseArc never reuses them.
    assert len(pruned_point_ids) == 3


def test_trim_ellipse_reuses_an_existing_point_at_the_crossing():
    """Mirrors trim_circle's own closed-profile fix: a Line whose own
    endpoint already sits exactly on the ellipse boundary (e.g. from a
    prior trim/extend) must have that same Point id reused, not a new
    coincident duplicate."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(10.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=5.0)
    a = sketch.add_point(5.0, -20.0)
    b = sketch.add_point(5.0, 20.0)
    sketch.add_line(a.id, b.id)
    existing = sketch.add_point(5.0, -4.330127018922193)
    sketch.add_line(existing.id, sketch.add_point(30.0, -30.0).id)

    arc, _ = sketch.trim_ellipse(ellipse.id, 0.0, 5.0)

    assert existing.id in (arc.start_point_id, arc.end_point_id)
    matching = [p for p in sketch.points.values() if math.isclose(p.x, 5.0) and math.isclose(p.y, -4.330127018922193)]
    assert len(matching) == 1


def test_trim_ellipse_raises_when_fewer_than_two_crossings_found():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(10.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=5.0)

    with pytest.raises(NoIntersectionFoundError):
        sketch.trim_ellipse(ellipse.id, 0.0, 5.0)


def test_trim_ellipse_does_not_bracket_against_its_own_axis_construction_lines():
    """Regression guard for the bug found while building this: an
    Ellipse's own major/minor axis construction Lines always have their
    endpoints sitting exactly on its own curve (the 4 cardinal tip
    Points), so without excluding them they'd contribute 4 free
    "crossings" against every Ellipse ever, even one with nothing else
    drawn against it - this is the same scenario as the "fewer than two
    crossings" test above, just confirming the axis lines specifically
    are never counted."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(10.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=5.0)
    candidates = sketch._ellipse_candidates_against(
        (0.0, 0.0),
        10.0,
        5.0,
        0.0,
        exclude_ids=frozenset({ellipse.id, ellipse.major_axis_line_id, ellipse.minor_axis_line_id}),
    )
    assert candidates == []


def test_trim_ellipse_rejects_unknown_ellipse_id():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.trim_ellipse("does-not-exist", 0.0, 0.0)


def test_trim_ellipse_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 10.0, 0.0)
    ellipse_response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 5.0},
    )
    assert ellipse_response.status_code == 201
    ellipse_id = ellipse_response.json()["id"]
    a = _create_point(sketch["id"], 5.0, -20.0)
    b = _create_point(sketch["id"], 5.0, 20.0)
    line_response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    )
    assert line_response.status_code == 201

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses/{ellipse_id}/trim",
        json={"click_x": 0.0, "click_y": 5.0},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["ellipse_arc"]["type"] == "ellipse_arc"
    assert body["ellipse_arc"]["major_radius"] == pytest.approx(10.0)
    assert body["ellipse_arc"]["minor_radius"] == pytest.approx(5.0)
    assert len(body["pruned_point_ids"]) == 3
    get_response = client.get(f"/sketch/sketches/{sketch['id']}/ellipses/{ellipse_id}")
    assert get_response.status_code == 404


def test_trim_ellipse_with_no_intersection_returns_422_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 10.0, 0.0)
    ellipse_response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses",
        json={"center_point_id": center["id"], "major_point_id": major["id"], "minor_radius": 5.0},
    )
    ellipse_id = ellipse_response.json()["id"]

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses/{ellipse_id}/trim",
        json={"click_x": 0.0, "click_y": 5.0},
    )

    assert response.status_code == 422


def test_trim_ellipse_with_unknown_id_returns_404_over_the_api():
    sketch = _create_sketch()
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipses/does-not-exist/trim",
        json={"click_x": 0.0, "click_y": 5.0},
    )
    assert response.status_code == 404


# --- profile.py chain detection -----------------------------------------------


def test_line_and_ellipse_arc_chain_closes_into_a_single_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.0, math.pi)
    sketch.add_line(arc.end_point_id, arc.start_point_id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert arc.id in result.profile.line_ids


def test_ellipse_arc_alone_with_no_closing_line_is_not_a_closed_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.0, math.pi)

    result = detect_profile(sketch)

    assert result.status != ProfileStatus.CLOSED_LOOP


# --- HTTP API -----------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_ellipse_arc_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 8.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.3,
            "end_angle": 2.0,
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "ellipse_arc"
    assert body["center_point_id"] == center["id"]
    assert body["major_point_id"] == major["id"]
    assert body["major_radius"] == pytest.approx(8.0)
    assert body["minor_radius"] == pytest.approx(3.0)
    assert body["rotation"] == pytest.approx(0.0)


def test_create_ellipse_arc_rejects_minor_radius_exceeding_major_radius_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 5.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 9.0,
            "start_angle": 0.0,
            "end_angle": 1.0,
        },
    )

    assert response.status_code == 400


def test_create_ellipse_arc_with_unknown_center_point_is_404():
    sketch = _create_sketch()
    major = _create_point(sketch["id"], 5.0, 0.0)
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": "does-not-exist",
            "major_point_id": major["id"],
            "minor_radius": 2.0,
            "start_angle": 0.0,
            "end_angle": 1.0,
        },
    )
    assert response.status_code == 404


def test_get_ellipse_arc_round_trip():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.0,
            "end_angle": 2.0,
        },
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def _minor_constraint_id(sketch_id: str, ellipse_arc_id: str) -> str:
    constraints = client.get(f"/sketch/sketches/{sketch_id}/constraints").json()
    arc = client.get(f"/sketch/sketches/{sketch_id}/ellipse-arcs/{ellipse_arc_id}").json()
    for constraint in constraints:
        if (
            constraint["type"] == "distance"
            and {constraint["point_a_id"], constraint["point_b_id"]} == {arc["center_point_id"], arc["minor_point_id"]}
        ):
            return constraint["id"]
    raise AssertionError("minor radius DistanceConstraint not found")


def _major_constraint_id(sketch_id: str, ellipse_arc_id: str) -> str:
    constraints = client.get(f"/sketch/sketches/{sketch_id}/constraints").json()
    arc = client.get(f"/sketch/sketches/{sketch_id}/ellipse-arcs/{ellipse_arc_id}").json()
    for constraint in constraints:
        if (
            constraint["type"] == "distance"
            and {constraint["point_a_id"], constraint["point_b_id"]} == {arc["center_point_id"], arc["major_point_id"]}
        ):
            return constraint["id"]
    raise AssertionError("major radius DistanceConstraint not found")


def test_dragging_the_minor_point_past_the_major_radius_is_clamped_not_swapped():
    """Unlike a plain Ellipse (see Ellipse._major_minor's own doc comment
    in models.py), an EllipseArc's major axis fixes where its own
    parametric angle-zero sits - and therefore what start_point_id/
    end_point_id even mean - so swapping which axis is "major" mid-drag
    isn't safe here. PATCHing the minor axis's DistanceConstraint past the
    major axis's current radius must clamp to the major radius instead,
    the same cap `add_ellipse_arc` already applies at creation."""
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    arc = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.0,
            "end_angle": 2.0,
        },
    ).json()
    # Confirm the major dimension at its own current value first - see
    # test_stage17_ellipse.py's own identical fix for why: both of a
    # freshly-created EllipseArc's DistanceConstraints start provisional,
    # so without this the minor-axis PATCH below would hit
    # update_constraint_value's "sketch's first real dimension" whole-
    # sketch-scale path instead of the ordinary single-point reseed,
    # confounding this test's actual target (the clamp).
    client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{_major_constraint_id(sketch['id'], arc['id'])}",
        json={"value": 9.0},
    )

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/constraints/{_minor_constraint_id(sketch['id'], arc['id'])}",
        json={"value": 15.0},
    )
    assert response.status_code == 200

    updated = client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/{arc['id']}").json()
    assert updated["major_radius"] == pytest.approx(9.0)
    assert updated["minor_radius"] == pytest.approx(9.0)


def test_get_ellipse_arc_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/does-not-exist")
    assert response.status_code == 404


def test_list_ellipse_arcs_returns_every_ellipse_arc_in_the_sketch():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.0,
            "end_angle": 2.0,
        },
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs")

    assert response.status_code == 200
    assert [entry["id"] for entry in response.json()] == [created["id"]]


def test_delete_ellipse_arc_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.0,
            "end_angle": 2.0,
        },
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/{created['id']}")

    assert response.status_code == 200
    assert set(response.json()["pruned_point_ids"]) >= {center["id"], major["id"]}
    assert client.get(f"/sketch/sketches/{sketch['id']}/ellipse-arcs/{created['id']}").status_code == 404


def test_creating_an_ellipse_arc_and_fixing_it_over_the_api_creates_a_solvable_constraint_set():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    major = _create_point(sketch["id"], 9.0, 0.0)
    arc = client.post(
        f"/sketch/sketches/{sketch['id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 3.0,
            "start_angle": 0.3,
            "end_angle": 2.0,
        },
    ).json()

    fix_resp = client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"type": "fixed", "entity_id": arc["id"]},
    )
    assert fix_resp.status_code == 201

    solve_resp = client.post(f"/sketch/sketches/{sketch['id']}/solve")
    assert solve_resp.status_code == 200
    assert solve_resp.json()["converged"] is True


# --- native_format.py round trip ----------------------------------------------


def test_ellipse_arc_round_trips_through_native_format_json():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(8.0, 0.0)
    arc = sketch.add_ellipse_arc(center.id, major.id, 3.0, 0.3, 2.0)
    sketch.add_fixed_constraint(arc.id)

    data = sketch_to_dict(sketch)
    restored = sketch_from_dict(json.loads(json.dumps(data)))

    restored_arc = restored.entities[arc.id]
    assert isinstance(restored_arc, EllipseArc)
    assert restored_arc.start_point_id == arc.start_point_id
    assert restored_arc.end_point_id == arc.end_point_id
    result = solve_sketch(restored)
    assert result.converged, result.detail


# --- extrude.py OCCT wire construction ----------------------------------------


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


def test_extruding_a_line_and_ellipse_arc_profile_produces_a_non_empty_computed_mesh():
    """The EllipseArc wire-construction branch in app.document.extrude.
    wire_for_profile (gp_Elips trimmed between two Points, via
    _ellipse_axis), exercised end-to-end through a real extrude - the
    partial-ellipse analogue of test_stage16_arc.py's own stadium-profile
    extrude check."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    center = _create_point(sketch_feature["sketch_id"], 0.0, 0.0)
    major = _create_point(sketch_feature["sketch_id"], 15.0, 0.0)
    arc = client.post(
        f"/sketch/sketches/{sketch_feature['sketch_id']}/ellipse-arcs",
        json={
            "center_point_id": center["id"],
            "major_point_id": major["id"],
            "minor_radius": 8.0,
            "start_angle": 0.0,
            "end_angle": math.pi,
        },
    ).json()
    assert client.post(
        f"/sketch/sketches/{sketch_feature['sketch_id']}/lines",
        json={"start_point_id": arc["end_point_id"], "end_point_id": arc["start_point_id"]},
    ).status_code == 201

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0
