"""Fix #6/#8 (Sketcher-roadmap feedback round): on-device feedback reported a
freshly-dropped Ellipse/Slot showing "fully constrained" with zero
user-visible dimensions. Root cause: `Sketch.add_circle`/`add_arc`/
`add_ellipse` each auto-create a real, solved `DistanceConstraint` to pin
the shape's size the moment it's drawn - not because the user asked for a
dimension. The old fix only hid that dimension's on-screen *label*
client-side; the underlying constraint stayed fully real and solved, so the
shape genuinely was fully constrained, just with an invisible dimension.

The real fix: a size-defining `DistanceConstraint` now starts
`provisional=True` and is skipped entirely by the solver (see
`DistanceConstraint.provisional`'s own doc comment and `solve_sketch`'s
main constraint loop) until the user confirms a value, at which point
`provisional` is cleared (see `update_constraint_value`) and the constraint
starts being solved for real. These tests exercise that mechanism directly
against `Sketch`/`solve_sketch`, the same OCC-free layer
test_bugfix_horizontal_vertical_distance_sign.py already covers.
"""

import math

from app.sketch.constraints import (
    AngleConstraint,
    DistanceConstraint,
    EqualLengthConstraint,
    EqualRadiusConstraint,
    TangentConstraint,
)
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch


def test_provisional_distance_constraint_is_skipped_by_the_solver():
    sketch = Sketch(id="s", plane=Plane.XY)
    fixed = sketch.add_point(0.0, 0.0)
    free = sketch.add_point(5.0, 0.0)
    constraint = DistanceConstraint(
        id="c1", point_a_id=fixed.id, point_b_id=free.id, distance=2.25, provisional=True
    )
    sketch.constraints[constraint.id] = constraint

    result = solve_sketch(sketch, anchor_point_ids=frozenset({fixed.id}))

    assert result.converged
    # Skipped entirely - the free point is left exactly where it was seeded,
    # not pulled to the provisional constraint's distance value.
    assert sketch.points[free.id].x == 5.0
    assert result.dof > 0


def test_confirming_a_provisional_distance_constraint_makes_the_solver_honor_it():
    sketch = Sketch(id="s", plane=Plane.XY)
    fixed = sketch.add_point(0.0, 0.0)
    free = sketch.add_point(5.0, 0.0)
    constraint = DistanceConstraint(
        id="c1", point_a_id=fixed.id, point_b_id=free.id, distance=2.25, provisional=True
    )
    sketch.constraints[constraint.id] = constraint

    # Mirrors update_constraint_value: any explicit value confirm clears
    # `provisional`.
    constraint.distance = 2.25
    constraint.provisional = False

    result = solve_sketch(sketch, anchor_point_ids=frozenset({fixed.id}))

    assert result.converged
    assert sketch.points[free.id].x == 2.25


def test_add_circle_radius_constraint_starts_provisional():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    radius_constraint = sketch.constraints[circle.radius_constraint_id]
    assert isinstance(radius_constraint, DistanceConstraint)
    assert radius_constraint.provisional is True


def test_add_circle_leaves_size_unconstrained_until_confirmed():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    result = solve_sketch(sketch, anchor_point_ids=frozenset({center.id}))
    # Genuinely under-constrained: the centre is pinned but nothing pins the
    # radius, so free parameters remain (the exact opposite of the bug
    # report - "fully constrained with zero dimensions").
    assert result.converged
    assert result.dof > 0

    radius_constraint = sketch.constraints[circle.radius_constraint_id]
    radius_constraint.provisional = False
    result = solve_sketch(sketch, anchor_point_ids=frozenset({center.id}))
    assert result.converged
    radius_point = sketch.points[circle.radius_point_id]
    assert math.isclose(
        math.hypot(radius_point.x - center.x, radius_point.y - center.y), 5.0, abs_tol=1e-6
    )


def test_add_arc_radius_constraint_starts_provisional():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(5.0, 0.0)
    arc = sketch.add_arc(center.id, start.id, end_angle=math.pi / 2)

    radius_constraint = sketch.constraints[arc.radius_constraint_id]
    assert isinstance(radius_constraint, DistanceConstraint)
    assert radius_constraint.provisional is True


def test_add_ellipse_axis_constraints_start_provisional():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major_radius=8.0, angle=0.0, minor_radius=4.0)

    major_constraint = sketch.constraints[ellipse.major_constraint_id]
    minor_constraint = sketch.constraints[ellipse.minor_constraint_id]
    assert isinstance(major_constraint, DistanceConstraint)
    assert isinstance(minor_constraint, DistanceConstraint)
    assert major_constraint.provisional is True
    assert minor_constraint.provisional is True


def test_provisional_size_constraint_does_not_inflate_dof_used_for_over_constrained_reporting():
    # A genuinely user-confirmed dimension on top of an otherwise-fine
    # circle must still solve cleanly - provisional-skipping must not, by
    # itself, ever make an otherwise-valid system look inconsistent.
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    # Bare radius, no angle: the centre-point circle tool's own mode (the
    # new Point becomes the north cardinal point directly, see add_circle's
    # own doc comment) - the only mode with no remaining rotational DOF
    # once the radius is confirmed, since an explicit-angle radius Point
    # has no constraint pinning its angle around centre, only its distance.
    circle = sketch.add_circle(center.id, radius=5.0)
    radius_constraint = sketch.constraints[circle.radius_constraint_id]
    radius_constraint.provisional = False
    radius_constraint.distance = 7.0

    result = solve_sketch(sketch, anchor_point_ids=frozenset({center.id}))

    assert result.converged
    assert result.dof == 0


def _regular_polygon_angles(sides: int, radius: float, cx: float = 0.0, cy: float = 0.0):
    return [
        (cx + radius * math.cos(2 * math.pi * i / sides), cy + radius * math.sin(2 * math.pi * i / sides))
        for i in range(sides)
    ]


def _build_polygon(sketch: Sketch, sides: int, radius: float):
    """Mirrors the client's own `_clickPolygonTool` (Fix #6/#7): a centre
    Point, `sides` vertex Points connected in a cycle by Lines, an
    EqualLength chain plus an AngleConstraint (360/sides degrees) between
    every consecutive pair of edges (the validated fix for the polygon
    collapsing under drag), and a single provisional circumradius
    DistanceConstraint - the polygon tool is a shortcut, not itself a
    dimensioning action, so nothing here should count as a user dimension
    until confirmed.
    """
    center = sketch.add_point(0.0, 0.0)
    positions = _regular_polygon_angles(sides, radius)
    vertices = [sketch.add_point(x, y) for x, y in positions]

    line_ids = []
    for i in range(sides):
        line = sketch.add_line(vertices[i].id, vertices[(i + 1) % sides].id)
        line_ids.append(line.id)

    exterior_angle = 360.0 / sides
    for i in range(sides - 1):
        line1 = sketch.entities[line_ids[i]]
        line2 = sketch.entities[line_ids[i + 1]]
        equal_length = EqualLengthConstraint(
            id=f"el-{i}",
            line1_id=line_ids[i],
            line2_id=line_ids[i + 1],
            line1_start_id=line1.start_point_id,
            line1_end_id=line1.end_point_id,
            line2_start_id=line2.start_point_id,
            line2_end_id=line2.end_point_id,
        )
        sketch.constraints[equal_length.id] = equal_length
        angle = AngleConstraint(
            id=f"ang-{i}",
            line1_id=line_ids[i],
            line2_id=line_ids[i + 1],
            line1_start_id=line1.start_point_id,
            line1_end_id=line1.end_point_id,
            line2_start_id=line2.start_point_id,
            line2_end_id=line2.end_point_id,
            angle_degrees=exterior_angle,
        )
        sketch.constraints[angle.id] = angle

    circumradius = math.hypot(vertices[0].x - center.x, vertices[0].y - center.y)
    radius_constraint = DistanceConstraint(
        id="radius-c", point_a_id=center.id, point_b_id=vertices[0].id, distance=circumradius, provisional=True
    )
    sketch.constraints[radius_constraint.id] = radius_constraint
    for i in range(1, sides):
        equal_radius = EqualRadiusConstraint(
            id=f"er-{i}",
            center1_point_id=center.id,
            radius1_point_id=vertices[0].id,
            center2_point_id=center.id,
            radius2_point_id=vertices[i].id,
        )
        sketch.constraints[equal_radius.id] = equal_radius

    return center, vertices, line_ids


def test_polygon_radius_constraint_is_provisional_and_size_is_not_solver_pinned():
    sketch = Sketch(id="s", plane=Plane.XY)
    center, vertices, _ = _build_polygon(sketch, sides=5, radius=10.0)

    radius_constraint_id = next(
        cid
        for cid, c in sketch.constraints.items()
        if isinstance(c, DistanceConstraint) and c.point_a_id == center.id
    )
    assert sketch.constraints[radius_constraint_id].provisional is True

    # Rescale every vertex to a different circumradius before solving - if
    # the size were still solver-pinned (the pre-fix behaviour), this would
    # snap straight back to the original radius=10.0 seed. Since the size
    # constraint is provisional (skipped), it instead stays at the new
    # size: no dimension the user placed themselves is pinning it.
    for vertex in vertices:
        vertex.x *= 1.3
        vertex.y *= 1.3

    result = solve_sketch(sketch, anchor_point_ids=frozenset({center.id}))
    assert result.converged
    radii = [math.hypot(v.x - center.x, v.y - center.y) for v in vertices]
    for r in radii:
        assert math.isclose(r, 13.0, rel_tol=1e-3)


def test_polygon_stays_regular_under_incremental_drag():
    """Fix #6: equal-length alone (the pre-fix constraint set) can converge
    to a degenerate, non-adjacent-vertices-coincident solution under drag.
    Adding an AngleConstraint per consecutive edge pair (this module's own
    `_build_polygon`, mirroring the client's `_clickPolygonTool`) keeps a
    regular pentagon genuinely rigid: dragging one vertex through several
    small incremental steps - matching the app's real pointer-move-driven
    drag UX, see `solve_sketch`'s own `anchor_point_ids` doc comment -
    leaves every vertex still equidistant from centre and evenly spaced
    angularly.
    """
    sketch = Sketch(id="s", plane=Plane.XY)
    sides = 5
    center, vertices, _ = _build_polygon(sketch, sides=sides, radius=10.0)

    # Drag vertex 0 outward and around, in several small steps rather than
    # one large jump - see solve_sketch's own anchor_point_ids doc comment
    # for why a one-shot jump can find a degenerate solution branch a real
    # incremental drag never would.
    dragged = vertices[0]
    start_x, start_y = dragged.x, dragged.y
    target_x, target_y = 14.0, 6.0
    steps = 12
    for step in range(1, steps + 1):
        t = step / steps
        dragged.x = start_x + (target_x - start_x) * t
        dragged.y = start_y + (target_y - start_y) * t
        result = solve_sketch(sketch, anchor_point_ids=frozenset({center.id, dragged.id}))
        assert result.converged

    radii = [math.hypot(v.x - center.x, v.y - center.y) for v in vertices]
    assert max(radii) - min(radii) < 1e-4

    angles = sorted(math.atan2(v.y - center.y, v.x - center.x) for v in vertices)
    gaps = [
        (angles[(i + 1) % sides] - angles[i]) % (2 * math.pi) for i in range(sides)
    ]
    expected_gap = 2 * math.pi / sides
    for gap in gaps:
        assert abs(gap - expected_gap) < 1e-3


def _build_slot(sketch: Sketch, c1: tuple[float, float], c2: tuple[float, float], radius: float):
    """Mirrors the client's `SketchController._clickSlotTool` exactly: a
    construction centerline, two Arcs (arc1's own radius DistanceConstraint
    stays provisional per `add_arc`), arc2's own two auto radius
    constraints deleted and replaced with EqualRadiusConstraint ties to
    arc1, and 4 TangentConstraints (2 mathematically redundant given the
    EqualRadius ties - see solver.py's own REDUNDANT_OKAY comment)."""
    c1p = sketch.add_point(*c1)
    c2p = sketch.add_point(*c2)
    dx, dy = c2[0] - c1[0], c2[1] - c1[1]
    length = math.hypot(dx, dy)
    dirx, diry = dx / length, dy / length
    nx, ny = -diry, dirx
    a = sketch.add_point(c1[0] + nx * radius, c1[1] + ny * radius)
    b = sketch.add_point(c1[0] - nx * radius, c1[1] - ny * radius)
    c = sketch.add_point(c2[0] - nx * radius, c2[1] - ny * radius)
    d = sketch.add_point(c2[0] + nx * radius, c2[1] + ny * radius)

    centerline = sketch.add_line(c1p.id, c2p.id, construction=True)
    arc1 = sketch.add_arc(c1p.id, a.id, b.id)
    line1 = sketch.add_line(b.id, c.id)
    arc2 = sketch.add_arc(c2p.id, c.id, d.id)
    line2 = sketch.add_line(d.id, a.id)

    del sketch.constraints[arc2.radius_constraint_id]
    del sketch.constraints[arc2.end_radius_constraint_id]
    for radius_point_id in (c.id, d.id):
        sketch.add_equal_radius_constraint(arc1.id, arc2.id, radius2_point_id=radius_point_id)
    for arc, line in [(arc1, line1), (arc1, line2), (arc2, line1), (arc2, line2)]:
        sketch.add_tangent_constraint(arc.id, line.id)

    return c1p, c2p, a, b, c, d, arc1, arc2, centerline


def test_slot_leaves_radius_unconstrained_until_confirmed():
    """On-device feedback: a freshly-drawn Slot showed "fully constrained"
    (padlock green) with only a Horizontal constraint on its centerline -
    before its radius (or length) had ever been signed. Root cause was
    *not* a missing `provisional` flag (arc1's own radius constraint is
    already provisional, same as any other Arc's - see `add_arc`): it was
    that `system.Dof` is unreliable for this deliberately-redundant
    Tangent+EqualRadius system (the same REDUNDANT_OKAY path documented in
    solver.py), reporting 0 even though a real, unconfirmed degree of
    freedom (the shared radius) remains. See solver.py's own dof-floor
    comment for the fix."""
    sketch = Sketch(id="s", plane=Plane.XY)
    c1p, c2p, a, b, c, d, arc1, arc2, centerline = _build_slot(sketch, (0.0, 0.0), (20.0, 0.0), 5.0)

    radius_constraint = sketch.constraints[arc1.radius_constraint_id]
    assert isinstance(radius_constraint, DistanceConstraint)
    assert radius_constraint.provisional is True

    result = solve_sketch(sketch, anchor_point_ids=frozenset({c1p.id}))
    assert result.converged
    assert result.dof > 0

    # Same on-device repro step: add a Horizontal constraint on the
    # centerline (the one constraint the user had actually added) and
    # re-solve - still not fully constrained, since the radius is still
    # unconfirmed.
    sketch.add_horizontal_constraint(centerline.id)
    result = solve_sketch(sketch, anchor_point_ids=frozenset({c1p.id}))
    assert result.converged
    assert result.dof > 0

    # The geometry itself must stay intact throughout (this was the second
    # on-device report - a wrong/collapsed extrude) - every rim Point stays
    # exactly `radius` from its own arc centre, not collapsed toward it.
    for center, points in ((c1p, (a, b)), (c2p, (c, d))):
        for point in points:
            assert math.isclose(
                math.hypot(point.x - center.x, point.y - center.y), 5.0, abs_tol=1e-6
            )


def test_slot_becomes_fully_constrained_once_radius_is_confirmed():
    sketch = Sketch(id="s", plane=Plane.XY)
    c1p, c2p, a, b, c, d, arc1, arc2, centerline = _build_slot(sketch, (0.0, 0.0), (20.0, 0.0), 5.0)
    sketch.add_horizontal_constraint(centerline.id)

    radius_constraint = sketch.constraints[arc1.radius_constraint_id]
    radius_constraint.distance = 5.0
    radius_constraint.provisional = False

    # Mirrors update_selected_constraint_value's own "one more axis": once
    # the centerline itself is fully pinned (length + one endpoint's
    # position), nothing but the radius was ever left free.
    length_constraint = sketch.add_distance_constraint(c1p.id, c2p.id, 20.0)

    result = solve_sketch(sketch, anchor_point_ids=frozenset({c1p.id}))
    assert result.converged
    assert result.dof <= 0
