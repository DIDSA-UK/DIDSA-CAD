"""C4: pure-Python tests for `app.document.plane_geometry.resolve_three_points`
- the THREE_POINTS plane-construction math, given three already-resolved
world-space positions. Has zero OCCT dependency of its own (unlike the
`_resolve_point_ref_position`/`resolve_three_points_from_bodies` callers in
app.document.create_plane, which resolve a Body vertex or Sketch Point into
those positions first - see test_stage_c4_create_plane.py for the OCCT-
touching end-to-end path), so this runs for real in this sandbox, same as
test_stage_c3_plane_basis.py's own arbitrary_perpendicular_basis coverage.
"""

import math

import pytest

from app.document.plane_geometry import resolve_three_points


def _is_orthonormal_right_handed(x_axis, y_axis, normal) -> bool:
    def dot(a, b):
        return sum(p * q for p, q in zip(a, b))

    def cross(a, b):
        ax, ay, az = a
        bx, by, bz = b
        return (ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)

    def is_unit(v):
        return math.sqrt(dot(v, v)) == pytest.approx(1.0)

    return (
        is_unit(x_axis)
        and is_unit(y_axis)
        and is_unit(normal)
        and dot(x_axis, y_axis) == pytest.approx(0.0, abs=1e-9)
        and cross(x_axis, y_axis) == pytest.approx(normal, abs=1e-9)
    )


def test_three_points_in_the_xy_plane_resolve_to_the_standard_basis():
    resolved = resolve_three_points((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0))
    assert resolved.origin == pytest.approx((0.0, 0.0, 0.0))
    assert resolved.normal == pytest.approx((0.0, 0.0, 1.0))
    assert resolved.x_axis == pytest.approx((1.0, 0.0, 0.0))
    assert resolved.y_axis == pytest.approx((0.0, 1.0, 0.0))


def test_origin_is_always_the_first_point_and_x_axis_points_toward_the_second():
    resolved = resolve_three_points((5.0, 5.0, 5.0), (9.0, 5.0, 5.0), (5.0, 9.0, 5.0))
    assert resolved.origin == pytest.approx((5.0, 5.0, 5.0))
    assert resolved.x_axis == pytest.approx((1.0, 0.0, 0.0))


def test_resolved_basis_is_orthonormal_and_right_handed_for_an_arbitrary_triangle():
    resolved = resolve_three_points((1.0, 2.0, 3.0), (4.0, 0.0, -1.0), (2.0, 5.0, 7.0))
    assert _is_orthonormal_right_handed(resolved.x_axis, resolved.y_axis, resolved.normal)


def test_reordering_the_same_three_points_can_flip_the_normal():
    """Swapping p1/p2 swaps which cross-product direction `normal` comes
    from - flips its sign relative to the original ordering, since `x_axis`
    (now pointing at the old p2) is different too. Confirms point *order* is
    load-bearing, not just point *identity* - the same real-world plane can
    be represented by either normal depending on selection order, matching
    `resolve_three_points`'s own docstring."""
    a = resolve_three_points((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0))
    b = resolve_three_points((0.0, 0.0, 0.0), (0.0, 1.0, 0.0), (1.0, 0.0, 0.0))
    assert a.normal == pytest.approx(tuple(-c for c in b.normal))


def test_collinear_points_are_rejected():
    with pytest.raises(Exception) as exc_info:
        resolve_three_points((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0))
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail == {"type": "collinear_points"}


def test_coincident_points_are_rejected_as_collinear():
    with pytest.raises(Exception) as exc_info:
        resolve_three_points((1.0, 1.0, 1.0), (1.0, 1.0, 1.0), (2.0, 2.0, 2.0))
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail == {"type": "collinear_points"}
