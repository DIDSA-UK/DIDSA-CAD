"""Phase 6 (`docs/assembly-scope.md` §3): direct unit tests for
`app.document.assembly.apply_transform_to_point`/`apply_transform_to_direction`
- the mate solver's own basic "place a fixed Occurrence's local geometry
into world space" primitive. Pure math, no OCCT/py_slvs dependency, mirroring
`compose`/`compose_chain`'s own "hand-verified against known rotations"
testing style (those two are only exercised indirectly via
`test_assembly_mesh.py`'s endpoint-level checks; these two new siblings get
direct unit tests since nothing else in this pass exercises them from first
principles)."""

import math

from app.document.assembly import apply_transform_to_direction, apply_transform_to_point
from app.document.models import RigidTransform


def test_identity_transform_leaves_a_point_unchanged():
    result = apply_transform_to_point(RigidTransform.identity(), (1.0, 2.0, 3.0))
    assert result == (1.0, 2.0, 3.0)


def test_pure_translation_adds_directly():
    transform = RigidTransform(translation=(5.0, -2.0, 0.5))
    result = apply_transform_to_point(transform, (1.0, 1.0, 1.0))
    assert result == (6.0, -1.0, 1.5)


def test_90_degree_rotation_about_z_then_translate():
    transform = RigidTransform(
        translation=(10.0, 0.0, 0.0), rotation_axis=(0.0, 0.0, 1.0), rotation_angle_degrees=90.0
    )
    x, y, z = apply_transform_to_point(transform, (1.0, 0.0, 0.0))
    # Rotating (1,0,0) by +90 about +Z gives (0,1,0), then translate by (10,0,0).
    assert math.isclose(x, 10.0, abs_tol=1e-9)
    assert math.isclose(y, 1.0, abs_tol=1e-9)
    assert math.isclose(z, 0.0, abs_tol=1e-9)


def test_direction_is_rotated_but_never_translated():
    transform = RigidTransform(
        translation=(100.0, 200.0, 300.0), rotation_axis=(0.0, 0.0, 1.0), rotation_angle_degrees=90.0
    )
    x, y, z = apply_transform_to_direction(transform, (1.0, 0.0, 0.0))
    assert math.isclose(x, 0.0, abs_tol=1e-9)
    assert math.isclose(y, 1.0, abs_tol=1e-9)
    assert math.isclose(z, 0.0, abs_tol=1e-9)


def test_identity_direction_unchanged():
    result = apply_transform_to_direction(RigidTransform.identity(), (0.0, 1.0, 0.0))
    assert result == (0.0, 1.0, 0.0)


def test_180_degree_rotation_about_x_flips_y_and_z_direction():
    transform = RigidTransform(rotation_axis=(1.0, 0.0, 0.0), rotation_angle_degrees=180.0)
    x, y, z = apply_transform_to_direction(transform, (0.0, 1.0, 0.0))
    assert math.isclose(x, 0.0, abs_tol=1e-9)
    assert math.isclose(y, -1.0, abs_tol=1e-9)
    assert math.isclose(z, 0.0, abs_tol=1e-9)
