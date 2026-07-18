"""On-device feedback: after trimming two Lines to reach a Circle (each via
`trim_or_extend_line`), then trimming the Circle itself between those two
points (`trim_circle`, converting it to an Arc), the resulting wedge shape
visually looked like a closed profile but `detect_profile`
(`app.sketch.profile`) never registered it as one. Root cause: `trim_circle`
always placed its new Arc endpoints at a purely *computed* (x, y) - with no
awareness that a Line's own endpoint, from an earlier trim/extend, might
already sit at that exact spot. Two different Point objects at the same
location aren't topologically connected on their own, so the connectivity
walk `detect_profile` uses never saw the Arc and the two Lines as one loop.

First attempt fixed this via `Sketch._existing_point_at` plus a new
CoincidentConstraint tying a freshly-created Point to whatever existing one
was already there. That made `detect_profile` (and so the client's live
shading) see the loop as closed - but on-device feedback then reported a
*second*, subtler bug: Extrude on exactly this kind of sketch built the
*wrong* region. Root cause: `app.document.extrude.wire_for_profile`'s own
Arc branch deliberately builds an Arc's edge from its literal
`start_point_id`/`end_point_id`, bypassing `app.sketch.profile`'s
constraint-based canonicalization entirely (on purpose - see that branch's
own comment) - so a constraint-tied Arc endpoint and its neighbouring
Line's own (canonicalized) endpoint could resolve to two
different-but-coincident OCC vertices instead of one shared one, risking an
incorrectly-closed or wrongly-oriented wire once actually extruded, even
though sketch-side loop detection already read it as closed either way.

Final fix: `_existing_point_at`'s result is now reused *directly* (the same
"explicit sharing" pattern `add_line`/`add_arc` already document) rather
than tied via a new CoincidentConstraint - the Arc's own start/end Point
*is* the Line's own endpoint, not merely constrained to match it, so there
is no separate "canonical vs literal" id to ever diverge on. These tests
exercise the fix directly against `Sketch`, the same OCC-free layer
test_bugfix_provisional_size_constraints.py already covers - `app.sketch.
profile`/`app.document.extrude` themselves pull in OCC (via
`text_geometry`) and can't be imported in this environment, so the fix is
verified one layer down: the two entities either literally share the same
Point id, or they don't.
"""

import math

from app.sketch.models import Plane, Sketch


def test_trim_circle_reuses_existing_line_endpoints_as_its_new_arc_endpoints():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    radius = 5.0
    # Deliberately off a cardinal angle (0/90/180/270deg) - add_circle
    # always creates its own North/East/South/West Points regardless of
    # radius_point_id's own angle (Sketch._CARDINAL_ANGLES), so a target
    # angle that happened to land on one of those would find *that*
    # instead of this test's own Line endpoints, an unrelated confound.
    radius_pt = sketch.add_point(radius * math.cos(math.radians(10)), radius * math.sin(math.radians(10)))
    circle = sketch.add_circle(center.id, radius_pt.id)

    def on_circle(angle_degrees: float) -> tuple[float, float]:
        angle = math.radians(angle_degrees)
        return (radius * math.cos(angle), radius * math.sin(angle))

    # Line 1: fixed point far outside, moved point extended out to the
    # circle's own boundary at 40deg.
    target1 = on_circle(40)
    fixed1 = sketch.add_point(target1[0] * 4, target1[1] * 4)
    moved1 = sketch.add_point(target1[0] * 0.2, target1[1] * 0.2)
    line1 = sketch.add_line(fixed1.id, moved1.id)
    _, moved1_after, created1 = sketch.trim_or_extend_line(line1.id, moved1.id)
    assert not created1  # moved1 wasn't shared, so it moves in place.
    assert moved1_after.id == moved1.id  # still the exact same Point.
    assert math.isclose(moved1_after.x, target1[0], abs_tol=1e-6)
    assert math.isclose(moved1_after.y, target1[1], abs_tol=1e-6)

    # Line 2: symmetric, heading toward the circle's own boundary at
    # 200deg.
    target2 = on_circle(200)
    fixed2 = sketch.add_point(target2[0] * 4, target2[1] * 4)
    moved2 = sketch.add_point(target2[0] * 0.2, target2[1] * 0.2)
    line2 = sketch.add_line(fixed2.id, moved2.id)
    _, moved2_after, created2 = sketch.trim_or_extend_line(line2.id, moved2.id)
    assert not created2
    assert moved2_after.id == moved2.id
    assert math.isclose(moved2_after.x, target2[0], abs_tol=1e-6)
    assert math.isclose(moved2_after.y, target2[1], abs_tol=1e-6)

    # Trim the Circle at a click angle bracketed by the only two crossings
    # available (the two Line endpoints, at 40deg/200deg) - which specific
    # side gets excluded doesn't matter for this test; either way the new
    # Arc's own two endpoints land exactly at those two angles.
    click_x, click_y = on_circle(120)
    arc = sketch.trim_circle(circle.id, click_x=click_x, click_y=click_y)

    # The Arc's own start/end must be *literally* Line 1's/Line 2's own
    # endpoint ids - not merely two more Points sitting at the same spot.
    arc_endpoints = {arc.start_point_id, arc.end_point_id}
    assert moved1.id in arc_endpoints, "the new Arc's own endpoint at 40deg should literally be Line 1's own endpoint"
    assert moved2.id in arc_endpoints, "the new Arc's own endpoint at 200deg should literally be Line 2's own endpoint"
    # No stray third Point was created for either end.
    assert len(arc_endpoints) == 2


def test_trim_circle_still_creates_fresh_points_when_nothing_is_actually_there():
    """The ordinary case (P36's own original test coverage) - a Circle
    trimmed against a Line whose mid-span crossing doesn't happen to land
    on any existing Point (the Line's own endpoints are far from the
    crossing) - must still create brand-new Points, same as before this
    whole fix existed. Also off a cardinal angle for the same reason as
    the test above."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    radius_pt = sketch.add_point(5.0 * math.cos(math.radians(10)), 5.0 * math.sin(math.radians(10)))
    circle = sketch.add_circle(center.id, radius_pt.id)

    # A long diagonal Line straight through the circle at 45deg/225deg -
    # its own two endpoints are far outside the circle, so the crossing
    # itself (a genuine *interior* point along the Line, not either of its
    # own endpoints) has no existing Point anywhere near it.
    line_start = sketch.add_point(-20.0, -20.0)
    line_end = sketch.add_point(20.0, 20.0)
    sketch.add_line(line_start.id, line_end.id)

    points_before = set(sketch.points)
    click_x, click_y = 5.0 * math.cos(math.radians(120)), 5.0 * math.sin(math.radians(120))
    arc = sketch.trim_circle(circle.id, click_x=click_x, click_y=click_y)

    assert arc.start_point_id not in points_before
    assert arc.end_point_id not in points_before


def test_trim_or_extend_line_repoints_to_an_existing_point_instead_of_moving_in_place():
    """Lower-level check of the same fix, isolated to Line-vs-Line
    trim/extend (no Circle/Arc involved at all) - a pre-existing Point
    (`shared_point`, an unrelated Line's own endpoint) already sits exactly
    where Line B's own trim/extend target resolves to."""
    sketch = Sketch(id="s", plane=Plane.XY)

    # Line A: horizontal, at y=5 - Line B's own trim/extend target crosses
    # it at (5, 5), exactly where `shared_point` (Line C's own endpoint,
    # otherwise unrelated) already sits.
    a_start = sketch.add_point(0.0, 5.0)
    a_end = sketch.add_point(10.0, 5.0)
    sketch.add_line(a_start.id, a_end.id)

    shared_point = sketch.add_point(5.0, 5.0)
    other_end = sketch.add_point(5.0, 8.0)
    sketch.add_line(shared_point.id, other_end.id)

    fixed = sketch.add_point(5.0, 20.0)
    moved = sketch.add_point(5.0, 6.0)
    line_b = sketch.add_line(fixed.id, moved.id)
    _, moved_after, created = sketch.trim_or_extend_line(line_b.id, moved.id)

    # Repointed to the existing shared_point (not moved.id itself) - the
    # `created` flag reads True here (matching the "shared/blocked" branch's
    # own convention) since the Line's own reference changed away from
    # moved.id, even though no brand-new Point was actually created either.
    assert created
    assert moved_after.id == shared_point.id
    assert line_b.end_point_id == shared_point.id
    assert math.isclose(moved_after.x, 5.0, abs_tol=1e-6)
    assert math.isclose(moved_after.y, 5.0, abs_tol=1e-6)
