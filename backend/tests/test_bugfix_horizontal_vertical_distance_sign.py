"""Bug-fix round: on-device feedback (Sketcher-roadmap Phase 4.3 testing)
reported a horizontal DistanceConstraint's confirmed dimension "flipping"
the free Point to the mirror side of the fixed one it was measured from.

Root cause, confirmed empirically against the installed py-slvs build (see
`_PySlvsBuilder.horizontal_distance`'s own doc comment): `addPointsProject
Distance(value, point_a, point_b, ref_line)` is a genuinely *signed*
constraint whose sign convention is backwards from what the (point_a,
point_b, value) argument order suggests - for a positive `value` it always
solved `proj(point_b - point_a) == -value`, deterministically, regardless
of either Point's initial position (this is not the Newton-branch-
selection ambiguity `_fix_circle_cardinal_point_signs` handles for a
Circle's cardinal points, which only arises because those use a *zero*-
value distance constraint - sign is irrelevant to `-0.0 == 0.0`). The fix
negates `value` before it reaches py-slvs, in both `horizontal_distance`
and `vertical_distance`.
"""

from app.sketch.constraints import DistanceConstraint
from app.sketch.models import Plane, Sketch
from app.sketch.solver import solve_sketch


def test_horizontal_distance_keeps_the_free_point_on_its_original_positive_side():
    sketch = Sketch(id="s", plane=Plane.XY)
    fixed = sketch.add_point(0.0, 0.0)
    free = sketch.add_point(5.0, 0.0)  # starts well to the +x side of `fixed`.
    constraint = DistanceConstraint(
        id="c1", point_a_id=fixed.id, point_b_id=free.id, distance=2.25, orientation="horizontal"
    )
    sketch.constraints[constraint.id] = constraint

    result = solve_sketch(sketch, anchor_point_ids=frozenset({fixed.id}))

    assert result.converged
    assert sketch.points[free.id].x == 2.25
    assert sketch.points[fixed.id].x == 0.0


def test_horizontal_distance_keeps_the_free_point_on_its_original_negative_side():
    sketch = Sketch(id="s", plane=Plane.XY)
    fixed = sketch.add_point(0.0, 0.0)
    free = sketch.add_point(-5.0, 0.0)  # starts well to the -x side of `fixed`.
    constraint = DistanceConstraint(
        id="c1", point_a_id=fixed.id, point_b_id=free.id, distance=2.25, orientation="horizontal"
    )
    sketch.constraints[constraint.id] = constraint

    result = solve_sketch(sketch, anchor_point_ids=frozenset({fixed.id}))

    assert result.converged
    assert sketch.points[free.id].x == -2.25


def test_vertical_distance_keeps_the_free_point_on_its_original_positive_side():
    sketch = Sketch(id="s", plane=Plane.XY)
    fixed = sketch.add_point(0.0, 0.0)
    free = sketch.add_point(0.0, 5.0)  # starts well above `fixed`.
    constraint = DistanceConstraint(
        id="c1", point_a_id=fixed.id, point_b_id=free.id, distance=3.5, orientation="vertical"
    )
    sketch.constraints[constraint.id] = constraint

    result = solve_sketch(sketch, anchor_point_ids=frozenset({fixed.id}))

    assert result.converged
    assert sketch.points[free.id].y == 3.5


def test_horizontal_distance_is_correct_regardless_of_which_point_is_pointA_vs_pointB():
    # Same geometry as the first test, but with point_a/point_b swapped -
    # the fix must not depend on tap order (see confirmGhostValue's own
    # comment: pointA/pointB order is purely "whichever the user tapped
    # first").
    sketch = Sketch(id="s", plane=Plane.XY)
    free = sketch.add_point(5.0, 0.0)
    fixed = sketch.add_point(0.0, 0.0)
    constraint = DistanceConstraint(
        id="c1", point_a_id=free.id, point_b_id=fixed.id, distance=2.25, orientation="horizontal"
    )
    sketch.constraints[constraint.id] = constraint

    result = solve_sketch(sketch, anchor_point_ids=frozenset({fixed.id}))

    assert result.converged
    assert sketch.points[free.id].x == 2.25


def test_horizontal_distance_between_an_external_reference_and_a_sketch_point_does_not_flip():
    # The exact on-device repro shape: dimensioning a Sketch Point against a
    # materialized external-reference Point (Phase 4.3 v1) - the reference
    # is pinned every solve (see Sketch.external_references), and the
    # sketch Point being dimensioned started on the reference's +x side.
    from app.sketch.models import ExternalVertexReference

    sketch = Sketch(id="s", plane=Plane.XY)
    reference = sketch.add_external_vertex_reference(
        0.0, 0.0, ExternalVertexReference(body_id="body-1", vertex_index=0)
    )
    corner = sketch.add_point(5.0, 0.0)
    constraint = DistanceConstraint(
        id="c1", point_a_id=reference.id, point_b_id=corner.id, distance=2.25, orientation="horizontal"
    )
    sketch.constraints[constraint.id] = constraint

    result = solve_sketch(sketch)

    assert result.converged
    assert sketch.points[corner.id].x == 2.25
    assert sketch.points[reference.id].x == 0.0
