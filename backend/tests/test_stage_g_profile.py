"""Prompt G: pure-Python tests for `detect_profile`'s relaxed, per-connected-
component closed-loop detection - a stray open chain or branch/T-junction
elsewhere in the sketch no longer fails detection for a closed loop that
exists independently of it (previously *any* degree-1 or degree-3+ point
anywhere in the sketch reported NO_LOOP/BRANCH for the whole sketch). Zero
OCCT dependency (`app.sketch.profile` has none), so this runs for real in
this sandbox - mirrors `test_stage2_profile.py`'s own helper conventions.
"""

from app.sketch.models import Plane, Sketch
from app.sketch.profile import ProfileStatus, detect_profile


def _add_square_loop(sketch: Sketch, x0: float, y0: float, size: float) -> list[str]:
    """Mirrors test_stage2_profile.py's own helper - returns the loop's Line
    ids in order, for tests that need to build a profile_refs anchor."""
    corners = [
        sketch.add_point(x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    line_ids = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        line_ids.append(sketch.add_line(a.id, b.id).id)
    return line_ids


def _add_open_chain(sketch: Sketch, x0: float, y0: float) -> None:
    """A 3-point open chain (two Lines, no closing Line back to the start) -
    not a candidate profile on its own, and (Prompt G) no longer poisons
    detection of a genuinely closed loop elsewhere in the same sketch."""
    a = sketch.add_point(x0, y0)
    b = sketch.add_point(x0 + 10.0, y0)
    c = sketch.add_point(x0 + 10.0, y0 + 10.0)
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)


def _add_branch(sketch: Sketch, x0: float, y0: float) -> str:
    """A T-junction: a point used as an endpoint by three lines - returns
    the branch point's own id."""
    centre = sketch.add_point(x0, y0)
    a = sketch.add_point(x0 + 10.0, y0)
    b = sketch.add_point(x0 - 10.0, y0)
    c = sketch.add_point(x0, y0 + 10.0)
    sketch.add_line(centre.id, a.id)
    sketch.add_line(centre.id, b.id)
    sketch.add_line(centre.id, c.id)
    return centre.id


def test_a_closed_loop_alongside_an_unrelated_open_chain_is_still_detected():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 10.0)
    _add_open_chain(sketch, 100.0, 0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert len(result.profile.point_ids) == 4


def test_a_closed_loop_alongside_an_unrelated_branch_is_still_detected():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 10.0)
    branch_point_id = _add_branch(sketch, 100.0, 0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert branch_point_id not in result.profile.point_ids


def test_two_closed_loops_alongside_an_open_chain_are_both_detected():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 10.0)
    _add_square_loop(sketch, 100.0, 0.0, 10.0)
    _add_open_chain(sketch, 200.0, 0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 2


def test_a_circle_alongside_an_unrelated_open_chain_is_still_detected():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    sketch.add_circle(center.id, radius=5.0, angle=0.0)
    _add_open_chain(sketch, 100.0, 0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None


def test_purely_an_open_chain_is_still_no_loop():
    """Regression: with nothing usable anywhere, the old whole-sketch
    NO_LOOP result must be unchanged."""
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_open_chain(sketch, 0.0, 0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.NO_LOOP


def test_purely_a_branch_is_still_branch():
    """Regression: with nothing usable anywhere, the old whole-sketch
    BRANCH result (and its branch_point_ids) must be unchanged."""
    sketch = Sketch(id="s", plane=Plane.XY)
    branch_point_id = _add_branch(sketch, 0.0, 0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.BRANCH
    assert result.branch_point_ids == [branch_point_id]


def test_an_open_chain_and_a_branch_with_nothing_usable_reports_branch():
    """Branch still takes priority over open-chain for the message detail
    when nothing usable exists anywhere - same precedence the original
    (pre-Prompt-G) whole-sketch check gave, now applied only to the
    "zero usable loops" fallback."""
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_open_chain(sketch, 0.0, 0.0)
    branch_point_id = _add_branch(sketch, 100.0, 0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.BRANCH
    assert result.branch_point_ids == [branch_point_id]


def test_closing_an_open_chain_with_a_coincident_constraint_detects_a_closed_loop():
    """Bug-fix round: reported from an on-device sketch that looked visibly
    closed (a corner "closed" by dragging one open end onto the other,
    which - per _autoCoincideIfNear on the client - creates a
    CoincidentConstraint between two still-distinct Point ids, not one
    merged Point) but detect_profile still reported NO_LOOP, since the
    adjacency graph only ever looked at Line/Circle endpoint ids and knew
    nothing about CoincidentConstraints. A three-Line open chain (four
    distinct Points) whose two open ends are made Coincident must now be
    detected as a three-cornered closed loop, exactly as if the two ends
    had always been the same shared Point."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 10.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(-10.0, -10.0)
    d = sketch.add_point(0.0, 10.0)
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)
    sketch.add_line(c.id, d.id)

    assert detect_profile(sketch).status == ProfileStatus.NO_LOOP

    sketch.add_coincident_constraint(d.id, a.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert len(result.profile.point_ids) == 3
    assert len(result.profile.line_ids) == 3


def test_coincidence_is_transitive_across_more_than_two_points():
    """A -- B are Coincident, and B -- C are Coincident (never A -- C
    directly) - the union-find must still treat all three as one node, the
    same way transitively-equal Points would behave if they'd always been
    a single shared Point."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(0.0, 0.0)
    c = sketch.add_point(0.0, 0.0)
    x = sketch.add_point(10.0, 0.0)
    y = sketch.add_point(-10.0, -10.0)
    sketch.add_line(a.id, x.id)
    sketch.add_line(x.id, y.id)
    sketch.add_line(y.id, c.id)
    sketch.add_coincident_constraint(a.id, b.id)
    sketch.add_coincident_constraint(b.id, c.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert len(result.profile.point_ids) == 3


def test_a_coincident_constraint_alone_does_not_fabricate_a_loop_out_of_an_open_chain():
    """Coincidence closes a loop only when it actually joins the two open
    ends of a chain into a cycle - a CoincidentConstraint between two
    Points that aren't a chain's open ends (e.g. tacked onto an unrelated
    branch point) must not be misread as closing anything."""
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_open_chain(sketch, 0.0, 0.0)
    stray = sketch.add_point(50.0, 50.0)
    other_stray = sketch.add_point(60.0, 60.0)
    sketch.add_coincident_constraint(stray.id, other_stray.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.NO_LOOP
