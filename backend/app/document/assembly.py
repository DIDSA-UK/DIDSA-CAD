"""Assembly support's coordinate-transform math (`docs/assembly-scope.md`):
composing `RigidTransform`s down a nested Occurrence tree (an Occurrence's
target Part can itself have its own Occurrences, placing components inside
components) - what `GET /parts/{part_id}/assembly-mesh` (Phase 2) needs to
place each unique leaf's shared, cached mesh at every one of its
Occurrences' world positions, and what a `ComponentPattern`'s transform
expansion (Phase 7, `expand_component_pattern_instances` below) needs to
mint each derived instance's own placement.

Pure vector/matrix math, no OCCT dependency - `RigidTransform`'s translate +
axis-angle representation (`app.document.models.RigidTransform`) doesn't
need a geometry kernel to compose, only 3x3 rotation matrices and
Rodrigues' rotation formula, the same primitive the client's own gizmo math
already uses (`client/lib/viewport3d/section_gizmo.dart`'s
`rotateAroundAxis`) - kept in matching form here so backend and client
transform composition agree.
"""

import math

from app.document.models import ComponentPattern, ComponentPatternAxis, ComponentPatternType, RigidTransform

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


def apply_transform_to_point(transform: RigidTransform, point: Vec3) -> Vec3:
    """Phase 6 (`docs/assembly-scope.md` §3): the mate solver's own most
    basic need - a fixed (non-driven) Occurrence's `transform` is fully
    known, so a `MateEntityRef` resolved against *that* Occurrence's own
    target Part (in its local frame, via `compute_part_bodies`) is placed
    into world space by plain rotate-then-translate, the exact same
    convention `compose` itself already uses one level up - no `py_slvs`
    involvement needed for a side of a mate that isn't being solved for.
    `apply_transform_to_direction` is this function's sibling for a
    direction/normal, which only rotates (never translates)."""
    rotation = _mat3_from_axis_angle(transform.rotation_axis, transform.rotation_angle_degrees)
    rotated = _mat3_apply(rotation, point)
    return (
        transform.translation[0] + rotated[0],
        transform.translation[1] + rotated[1],
        transform.translation[2] + rotated[2],
    )


def apply_transform_to_direction(transform: RigidTransform, direction: Vec3) -> Vec3:
    """`apply_transform_to_point`'s sibling for a direction vector (a face
    normal, an axis direction) - rotates only, since translation has no
    effect on a direction (unlike a position)."""
    rotation = _mat3_from_axis_angle(transform.rotation_axis, transform.rotation_angle_degrees)
    return _mat3_apply(rotation, direction)


def _linear_pattern_step(direction: Vec3, distance: float) -> RigidTransform:
    """The pure-translation `RigidTransform` for a Linear `ComponentPattern`
    step of `distance` along `direction` (already signed by `reverse` and
    scaled by `spacing * index` - see `expand_component_pattern_instances`).
    A zero-length `direction` (never normalized - `_normalize`'s own
    degenerate fallback would silently substitute +Z) is rejected by the
    router before this is ever called (`_validate_component_pattern_
    create`), not defended against here."""
    unit = _normalize(direction)
    return RigidTransform(translation=(unit[0] * distance, unit[1] * distance, unit[2] * distance))


def _circular_pattern_step(axis: ComponentPatternAxis, angle_degrees: float) -> RigidTransform:
    """The `RigidTransform` for a Circular `ComponentPattern` step of
    `angle_degrees` around `axis` - a rotation about an arbitrary world-space
    line (`axis.origin` + `axis.direction`), not just the origin the way
    `_mat3_from_axis_angle` alone assumes. Built from the standard "rotate
    about an off-origin axis" decomposition (translate the origin to zero,
    rotate, translate back - `T(origin) . R(axis, angle) . T(-origin)`),
    computed here via `apply_transform_to_point` itself (a pure rotation
    applied to `axis.origin` gives `R(axis, angle) . origin`, so `origin -
    that` is exactly the translation term this composed transform needs) -
    reusing this module's own public function rather than duplicating its
    rotation math a second time.

    The result is meant to be applied as `compose(step, source_transform)`
    (see `expand_component_pattern_instances`) - `compose`'s own "parent
    applied after child" semantics are exactly the extrinsic-rotation
    behavior wanted here (rotate the *entire* existing placement - both its
    position and its own orientation - around the fixed world axis), as
    long as `step` and `source_transform` are expressed in the same
    reference frame, true for any two top-level Occurrences' transforms
    (both relative to the same parent Part, this pattern's own v1 scope
    limit - see `ComponentPattern`'s own docstring)."""
    rotation_only = RigidTransform(rotation_axis=axis.direction, rotation_angle_degrees=angle_degrees)
    rotated_origin = apply_transform_to_point(rotation_only, axis.origin)
    translation: Vec3 = (
        axis.origin[0] - rotated_origin[0],
        axis.origin[1] - rotated_origin[1],
        axis.origin[2] - rotated_origin[2],
    )
    return RigidTransform(translation=translation, rotation_axis=axis.direction, rotation_angle_degrees=angle_degrees)


def expand_component_pattern_instances(
    pattern: ComponentPattern, source_transform: RigidTransform
) -> dict[int, RigidTransform]:
    """Every *derived* instance transform for `pattern`, applied to
    `source_transform` (one of `pattern.source_occurrence_ids`' own current
    `Occurrence.transform`) - excludes index 0, the untouched seed
    Occurrence itself, the identical `PatternFeature`-precedent convention
    `ComponentPattern`'s own docstring documents ("count includes the
    original"). Returns `{}` for `count`/`count_angular <= 1` (nothing to
    derive). Callers compose each result onto whatever transform chain
    already places `source_transform`'s own parent (`GET /parts/{part_id}/
    assembly-mesh`'s own `_walk`) - this function only ever computes the
    *local* step relative to the source Occurrence's existing placement,
    same "local step, composed by the caller" split `compose_chain`'s own
    per-level `compose` calls already use.

    Keyed by the same index the loop below enumerates - Linear's own
    flattened `i * count_2 + j` (row-major, mirroring `_rectangular_
    instances`'s identical convention one level down in
    `app.document.pattern`; `1` is simply the first derived instance
    whenever `count_2 == 1`), Circular's plain `1`-based angular-step index
    - rather than returned as a plain list, so a skipped index (Phase 11,
    `[9]`, `pattern.skip_indices`) leaves every surviving instance's own id
    stable instead of shifting it - the same "don't let a skip quietly
    renumber its neighbors" concern that convention already protects
    against for Body-level Patterns."""
    skip_indices = set(pattern.skip_indices)
    if pattern.pattern_type == ComponentPatternType.LINEAR:
        count_1 = max(pattern.count, 1)
        count_2 = max(pattern.count_2, 1)
        sign_1 = -1.0 if pattern.reverse else 1.0
        sign_2 = -1.0 if pattern.reverse_2 else 1.0
        instances: dict[int, RigidTransform] = {}
        for i in range(count_1):
            for j in range(count_2):
                index = i * count_2 + j
                if index == 0 or index in skip_indices:
                    continue
                step = _linear_pattern_step(pattern.direction, pattern.spacing * i * sign_1)
                if count_2 > 1:
                    step_2 = _linear_pattern_step(pattern.direction_2, pattern.spacing_2 * j * sign_2)
                    step = RigidTransform(
                        translation=(
                            step.translation[0] + step_2.translation[0],
                            step.translation[1] + step_2.translation[1],
                            step.translation[2] + step_2.translation[2],
                        )
                    )
                instances[index] = compose(step, source_transform)
        return instances

    count = max(pattern.count_angular, 1)
    axis = pattern.axis if pattern.axis is not None else ComponentPatternAxis()
    step_angle = pattern.angle_total / count
    sign = -1.0 if pattern.reverse_angular else 1.0
    instances = {}
    for index in range(1, count):
        if index in skip_indices:
            continue
        step = _circular_pattern_step(axis, step_angle * index * sign)
        composed = compose(step, source_transform)
        if not pattern.orient_with_rotation:
            # `[10]`: reposition around the circle (keep `composed`'s own
            # translation, the fully rotation-aware displacement `compose`
            # already derived) without also rotating the instance's own
            # local orientation around `axis` - restore `source_transform`'s
            # own rotation term in place of `composed`'s.
            composed = RigidTransform(
                translation=composed.translation,
                rotation_axis=source_transform.rotation_axis,
                rotation_angle_degrees=source_transform.rotation_angle_degrees,
            )
        instances[index] = composed
    return instances
