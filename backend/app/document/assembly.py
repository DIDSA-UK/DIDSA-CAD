"""Assembly support's coordinate-transform math (`docs/assembly-scope.md`):
composing `RigidTransform`s down a nested Occurrence tree (an Occurrence's
target Part can itself have its own Occurrences, placing components inside
components) - what `GET /parts/{part_id}/assembly-mesh` (Phase 2) needs to
place each unique leaf's shared, cached mesh at every one of its
Occurrences' world positions, and what a `ComponentPattern`'s transform
expansion (Phase 8) needs to mint each generated Occurrence's own
placement.

Pure vector/matrix math, no OCCT dependency - `RigidTransform`'s translate +
axis-angle representation (`app.document.models.RigidTransform`) doesn't
need a geometry kernel to compose, only 3x3 rotation matrices and
Rodrigues' rotation formula, the same primitive the client's own gizmo math
already uses (`client/lib/viewport3d/section_gizmo.dart`'s
`rotateAroundAxis`) - kept in matching form here so backend and client
transform composition agree.
"""

import math

from app.document.models import RigidTransform

Vec3 = tuple[float, float, float]
# Row-major: Mat3[row][col].
Mat3 = tuple[Vec3, Vec3, Vec3]

_IDENTITY_MAT3: Mat3 = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))


def _normalize(v: Vec3) -> Vec3:
    length = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    if length < 1e-12:
        return (0.0, 0.0, 1.0)
    return (v[0] / length, v[1] / length, v[2] / length)


def _mat3_from_axis_angle(axis: Vec3, angle_degrees: float) -> Mat3:
    """Rodrigues' rotation formula - the same construction
    `section_gizmo.dart`'s `rotateAroundAxis` already applies per-vector on
    the client, in matrix form here so it composes with other rotations."""
    if abs(angle_degrees) < 1e-12:
        return _IDENTITY_MAT3
    x, y, z = _normalize(axis)
    theta = math.radians(angle_degrees)
    c = math.cos(theta)
    s = math.sin(theta)
    t = 1.0 - c
    return (
        (t * x * x + c, t * x * y - s * z, t * x * z + s * y),
        (t * x * y + s * z, t * y * y + c, t * y * z - s * x),
        (t * x * z - s * y, t * y * z + s * x, t * z * z + c),
    )


def _mat3_multiply(a: Mat3, b: Mat3) -> Mat3:
    """`a * b` (row-major) - applying `b` first, then `a`, matching
    `compose`'s own "parent applied after child" convention below."""
    return tuple(
        tuple(sum(a[row][k] * b[k][col] for k in range(3)) for col in range(3)) for row in range(3)
    )  # type: ignore[return-value]


def _mat3_apply(m: Mat3, v: Vec3) -> Vec3:
    return tuple(sum(m[row][k] * v[k] for k in range(3)) for row in range(3))  # type: ignore[return-value]


def _mat3_to_axis_angle(m: Mat3) -> tuple[Vec3, float]:
    """The inverse of `_mat3_from_axis_angle` - extracts an axis + angle
    (degrees) from a rotation matrix, so a composed transform can still be
    stored in `RigidTransform`'s own axis-angle wire format (see that
    class's own docstring for why axis-angle, not a matrix/quaternion, is
    this codebase's wire convention)."""
    trace = m[0][0] + m[1][1] + m[2][2]
    cos_theta = max(-1.0, min(1.0, (trace - 1.0) / 2.0))
    theta = math.acos(cos_theta)
    if theta < 1e-9:
        return (0.0, 0.0, 1.0), 0.0
    if abs(theta - math.pi) < 1e-6:
        # 180-degree rotation: (m - m^T) vanishes, so the usual off-
        # diagonal extraction below is degenerate - pull the axis from the
        # symmetric part instead ((m + I) / 2's diagonal), then disambiguate
        # signs from the off-diagonal terms.
        axis = (
            math.sqrt(max(0.0, (m[0][0] + 1.0) / 2.0)),
            math.sqrt(max(0.0, (m[1][1] + 1.0) / 2.0)),
            math.sqrt(max(0.0, (m[2][2] + 1.0) / 2.0)),
        )
        if m[0][1] < 0:
            axis = (axis[0], -axis[1], axis[2])
        if m[0][2] < 0:
            axis = (axis[0], axis[1], -axis[2])
        return _normalize(axis), math.degrees(theta)
    axis = (m[2][1] - m[1][2], m[0][2] - m[2][0], m[1][0] - m[0][1])
    return _normalize(axis), math.degrees(theta)


def compose(parent: RigidTransform, child: RigidTransform) -> RigidTransform:
    """The world-space `RigidTransform` of an Occurrence placed by `child`
    inside a parent Part that is itself placed by `parent` - one step of
    walking down a nested-subassembly Occurrence tree
    (`GET /parts/{part_id}/assembly-mesh`, Phase 2). Applies `child` in the
    parent's local frame, then places the result via `parent` - the
    standard child-relative-to-parent composition, matching
    `RigidTransform`'s own rotate-then-translate convention at each level."""
    parent_rot = _mat3_from_axis_angle(parent.rotation_axis, parent.rotation_angle_degrees)
    child_rot = _mat3_from_axis_angle(child.rotation_axis, child.rotation_angle_degrees)
    composed_rot = _mat3_multiply(parent_rot, child_rot)
    rotated_child_translation = _mat3_apply(parent_rot, child.translation)
    composed_translation: Vec3 = (
        parent.translation[0] + rotated_child_translation[0],
        parent.translation[1] + rotated_child_translation[1],
        parent.translation[2] + rotated_child_translation[2],
    )
    axis, angle = _mat3_to_axis_angle(composed_rot)
    return RigidTransform(translation=composed_translation, rotation_axis=axis, rotation_angle_degrees=angle)


def compose_chain(transforms: list[RigidTransform]) -> RigidTransform:
    """`compose` folded left-to-right over a full Occurrence path from an
    assembly-mesh walk's root down to one leaf - `transforms[0]` is the
    outermost (the root Part's own top-level Occurrence transform, if any)
    and `transforms[-1]` the innermost (the leaf's own Occurrence
    transform). An empty list returns the identity transform."""
    result = RigidTransform.identity()
    for transform in transforms:
        result = compose(result, transform)
    return result
