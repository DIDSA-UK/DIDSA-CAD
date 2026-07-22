"""On-device feedback: adding an "across flats" LineDistanceConstraint
between two opposite edges of a Polygon reported the sketch as over-
constrained, even though the value exactly matched what the Polygon's own
already-redundant EqualLength/EqualRadius/AngleConstraint chain implies.

Root-caused directly against the real solver (see solver.py's own
`_residual_verified_convergence` doc comment): py-slvs's own `result_code`
cannot tell "doubly-redundant but still consistent" apart from a genuine
conflict here - both a correct and a deliberately wrong across-flats value
produce the identical `result_code=1`. These tests exercise the residual-
based fallback added to fix that, both the positive case (the fallback
lets a real, doubly-redundant-but-consistent dimension through) and the
negative case (it doesn't just rubber-stamp a genuinely wrong value)."""

import math

from app.sketch.constraints import DistanceConstraint
from app.sketch.models import Plane, Sketch
from app.sketch.solver import _residual_verified_convergence, solve_sketch


def test_polygon_across_flats_with_the_correct_value_converges():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    across_flats = 2 * 10.0 * math.cos(math.pi / 6)
    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], across_flats)
    result = solve_sketch(sketch)

    assert result.converged
    assert result.result_code != 0, (
        "sanity check: py-slvs itself must not cleanly certify this - the residual fallback is "
        "what makes it converged, not a lucky clean solve"
    )


def test_polygon_across_flats_with_a_wrong_value_is_still_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    first_vertex = sketch.add_point(10.0, 0.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 6)
    sketch.constraints[polygon.radius_constraint_id].provisional = False
    solve_sketch(sketch)

    sketch.add_line_distance_constraint(polygon.line_ids[0], polygon.line_ids[3], 99.0)
    result = solve_sketch(sketch)

    assert not result.converged


def test_polygon_across_flats_is_not_polygon_specific_slot_style_redundancy_still_works():
    """The residual fallback isn't a Polygon-only special case - a Slot's
    own pre-existing redundant Tangent/EqualRadius chain (already handled
    by the narrower, longer-standing override above it in solver.py) must
    keep converging unaffected by this addition."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center1 = sketch.add_point(0.0, 0.0)
    center2 = sketch.add_point(20.0, 0.0)
    slot = sketch.add_slot(center1.id, center2.id, 5.0)
    sketch.constraints[slot.radius_constraint_id].provisional = False

    result = solve_sketch(sketch)

    assert result.converged


def test_residual_check_respects_horizontal_orientation_not_plain_euclidean_distance():
    """Bug fix, found while investigating a Circle drag/collapse report: a
    "horizontal"/"vertical" DistanceConstraint pins only the X or Y
    separation, leaving the other axis free (see that class's own doc
    comment) - a Circle's own cardinal-point axis pins are always exactly
    this shape (orientation="horizontal"/"vertical", distance=0.0). The
    residual check used to compare plain Euclidean distance against the
    target value regardless of orientation, which would have incorrectly
    rejected this - the two Points are 100 units apart in Y, so Euclidean
    distance is ~100.1, nowhere near the target of 5 - even though the
    *horizontal* separation the constraint actually cares about is exactly
    5, genuinely satisfied."""
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(5.0, 100.0)
    horizontal = DistanceConstraint(id="h", point_a_id=a.id, point_b_id=b.id, distance=5.0, orientation="horizontal")
    sketch.constraints[horizontal.id] = horizontal

    assert _residual_verified_convergence(sketch) is True


def test_residual_check_still_rejects_a_genuinely_wrong_horizontal_distance():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(5.0, 100.0)
    horizontal = DistanceConstraint(id="h", point_a_id=a.id, point_b_id=b.id, distance=50.0, orientation="horizontal")
    sketch.constraints[horizontal.id] = horizontal

    assert _residual_verified_convergence(sketch) is False
