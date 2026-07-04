"""C3: pure-Python tests for the new full-basis plumbing in
app.document.plane_geometry - `sketch_basis_for_plane` (the fixed-plane
lookup table) and `arbitrary_perpendicular_basis` (the no-natural-reference
case, exercised indirectly through `resolve_normal_to_line_at_point`'s own
returned `x_axis`/`y_axis`) - both have zero OCCT dependency, so unlike the
OFFSET_FACE/MIDPLANE/custom-plane-Sketch/custom-plane-Extrude cases (see
test_stage_c2_create_plane.py, which needs a real OCCT environment), these
run for real in this sandbox.
"""

import math

import pytest

from app.document.plane_geometry import (
    arbitrary_perpendicular_basis,
    resolve_normal_to_line_at_point,
    sketch_basis_for_plane,
)
from app.sketch.models import Plane, SketchEntityRef, SketchEntityType
from app.sketch.store import create_sketch


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


# --- sketch_basis_for_plane ---------------------------------------------------


def test_xy_basis_reproduces_the_existing_sketch_point_to_world_convention():
    basis = sketch_basis_for_plane(Plane.XY)
    assert basis.origin == (0.0, 0.0, 0.0)
    assert basis.normal == (0.0, 0.0, 1.0)
    assert basis.x_axis == (1.0, 0.0, 0.0)
    assert basis.y_axis == (0.0, 1.0, 0.0)


def test_xz_basis_reproduces_the_existing_sketch_point_to_world_convention():
    # XZ: local (x, y) -> world (x, 0, y) - origin + x*x_axis + y*y_axis must
    # reproduce that mapping exactly.
    basis = sketch_basis_for_plane(Plane.XZ)
    for x, y in [(0.0, 0.0), (3.0, 0.0), (0.0, 4.0), (2.0, 5.0)]:
        ox, oy, oz = basis.origin
        xx, xy, xz = basis.x_axis
        yx, yy, yz = basis.y_axis
        world = (ox + x * xx + y * yx, oy + x * xy + y * yy, oz + x * xz + y * yz)
        assert world == pytest.approx((x, 0.0, y))


def test_yz_basis_reproduces_the_existing_sketch_point_to_world_convention():
    basis = sketch_basis_for_plane(Plane.YZ)
    for x, y in [(0.0, 0.0), (3.0, 0.0), (0.0, 4.0), (2.0, 5.0)]:
        ox, oy, oz = basis.origin
        xx, xy, xz = basis.x_axis
        yx, yy, yz = basis.y_axis
        world = (ox + x * xx + y * yx, oy + x * xy + y * yy, oz + x * xz + y * yz)
        assert world == pytest.approx((0.0, x, y))


# --- arbitrary_perpendicular_basis -------------------------------------------


def test_arbitrary_basis_is_orthonormal_for_a_variety_of_normals():
    for normal in [
        (1.0, 0.0, 0.0),
        (0.0, 1.0, 0.0),
        (0.0, 0.0, 1.0),
        (0.0, 0.0, -1.0),
        (1.0, 1.0, 1.0),
    ]:
        length = math.sqrt(sum(c * c for c in normal))
        unit_normal = tuple(c / length for c in normal)
        x_axis, y_axis = arbitrary_perpendicular_basis(unit_normal)
        assert _is_orthonormal_right_handed(x_axis, y_axis, unit_normal), f"normal={unit_normal}"


def test_arbitrary_basis_is_deterministic():
    normal = (0.0, 0.6, 0.8)
    first = arbitrary_perpendicular_basis(normal)
    second = arbitrary_perpendicular_basis(normal)
    assert first == second


# --- resolve_normal_to_line_at_point's returned basis -------------------------


def test_resolved_plane_carries_an_orthonormal_basis_too():
    sketch = create_sketch(Plane.XY)
    start = sketch.add_point(0.0, 0.0)
    line = sketch.add_line(start.id, length=10.0, angle=math.pi / 6)
    line_ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.LINE, entity_id=line.id)
    point_ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=start.id)

    resolved = resolve_normal_to_line_at_point(line_ref, point_ref, sketch_basis_for_plane(Plane.XY))

    assert _is_orthonormal_right_handed(resolved.x_axis, resolved.y_axis, resolved.normal)


def test_resolving_against_a_custom_basis_offsets_the_origin_by_that_basis():
    """A Sketch anchored to a custom plane (C3) resolves its own Line/Point
    positions through that plane's basis, not through a fixed Plane's - here
    a basis whose origin sits away from the world origin, to confirm
    `_basis_point` (not just `_basis_vector`) is used for the returned
    plane's own `origin`."""
    from app.document.models import ResolvedPlane

    custom_basis = ResolvedPlane(
        origin=(100.0, 0.0, 0.0),
        normal=(0.0, 0.0, 1.0),
        x_axis=(1.0, 0.0, 0.0),
        y_axis=(0.0, 1.0, 0.0),
    )
    sketch = create_sketch(None)
    start = sketch.add_point(0.0, 0.0)
    line = sketch.add_line(start.id, length=5.0, angle=0.0)
    line_ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.LINE, entity_id=line.id)
    point_ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=start.id)

    resolved = resolve_normal_to_line_at_point(line_ref, point_ref, custom_basis)

    # The resolved plane's normal is the *line's* direction mapped through
    # `custom_basis` (a local +x-direction line maps to `custom_basis.x_axis`
    # here) - not `custom_basis`'s own normal, which only matters for how
    # the Sketch itself is embedded, not for what this new Plane is normal
    # to.
    assert resolved.origin == pytest.approx((100.0, 0.0, 0.0))
    assert resolved.normal == pytest.approx((1.0, 0.0, 0.0))
