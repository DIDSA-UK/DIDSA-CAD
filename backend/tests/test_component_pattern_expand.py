"""Phase 7 (`docs/assembly-scope.md` §3 item 7): direct unit tests for
`app.document.assembly.expand_component_pattern_instances` - pure math, no
OCCT/py_slvs dependency, mirroring `test_assembly_transform_apply.py`'s own
"hand-verified against known rotations" testing style for `apply_transform_
to_point`/`apply_transform_to_direction`."""

import math

from app.document.assembly import expand_component_pattern_instances
from app.document.models import ComponentPattern, ComponentPatternAxis, ComponentPatternType, RigidTransform


def _linear_pattern(**overrides) -> ComponentPattern:
    defaults = dict(
        id="p1",
        source_occurrence_ids=["occ-1"],
        pattern_type=ComponentPatternType.LINEAR,
        direction=(1.0, 0.0, 0.0),
        count=3,
        spacing=10.0,
    )
    defaults.update(overrides)
    return ComponentPattern(**defaults)


def _circular_pattern(**overrides) -> ComponentPattern:
    defaults = dict(
        id="p1",
        source_occurrence_ids=["occ-1"],
        pattern_type=ComponentPatternType.CIRCULAR,
        axis=ComponentPatternAxis(origin=(0.0, 0.0, 0.0), direction=(0.0, 0.0, 1.0)),
        count_angular=4,
        angle_total=360.0,
    )
    defaults.update(overrides)
    return ComponentPattern(**defaults)


def _assert_vec_close(actual, expected, abs_tol=1e-6):
    for a, e in zip(actual, expected):
        assert math.isclose(a, e, abs_tol=abs_tol)


def test_linear_pattern_excludes_the_untouched_seed_and_returns_count_minus_one_instances():
    pattern = _linear_pattern(count=3)
    instances = expand_component_pattern_instances(pattern, RigidTransform.identity())
    assert len(instances) == 2
    _assert_vec_close(instances[1].translation, (10.0, 0.0, 0.0))
    _assert_vec_close(instances[2].translation, (20.0, 0.0, 0.0))


def test_linear_pattern_reverse_flips_direction():
    pattern = _linear_pattern(count=3, reverse=True)
    instances = expand_component_pattern_instances(pattern, RigidTransform.identity())
    _assert_vec_close(instances[1].translation, (-10.0, 0.0, 0.0))
    _assert_vec_close(instances[2].translation, (-20.0, 0.0, 0.0))


def test_linear_pattern_normalizes_a_non_unit_direction():
    pattern = _linear_pattern(direction=(2.0, 0.0, 0.0), count=2, spacing=5.0)
    instances = expand_component_pattern_instances(pattern, RigidTransform.identity())
    _assert_vec_close(instances[1].translation, (5.0, 0.0, 0.0))


def test_linear_pattern_composes_onto_a_non_identity_source_transform():
    """The source Occurrence's own existing placement (translation *and*
    rotation) survives unchanged in every derived instance - only the
    pattern's own offset is added on top, in the same parent frame."""
    source = RigidTransform(translation=(0.0, 5.0, 0.0), rotation_axis=(0.0, 0.0, 1.0), rotation_angle_degrees=45.0)
    pattern = _linear_pattern(direction=(0.0, 1.0, 0.0), count=2, spacing=10.0)
    instances = expand_component_pattern_instances(pattern, source)
    assert len(instances) == 1
    _assert_vec_close(instances[1].translation, (0.0, 15.0, 0.0))
    assert math.isclose(instances[1].rotation_angle_degrees, 45.0, abs_tol=1e-6)
    _assert_vec_close(instances[1].rotation_axis, (0.0, 0.0, 1.0))


def test_linear_pattern_count_of_one_derives_nothing():
    pattern = _linear_pattern(count=1)
    assert expand_component_pattern_instances(pattern, RigidTransform.identity()) == {}


# --- Bug report (assembly testing): the optional second direction ------


def test_linear_pattern_crosses_direction_and_direction_2_into_a_2d_grid():
    """A 2x2 grid: `count`/`count_2` each 2, `direction`/`direction_2`
    perpendicular - mirrors `PatternFeature`'s own Rectangular
    `direction_1`/`direction_2` cross exactly, one level up. Flattened
    row-major index `i * count_2 + j` (index 0, the untouched seed at
    `i=0, j=0`, is never a key)."""
    pattern = _linear_pattern(
        direction=(1.0, 0.0, 0.0),
        count=2,
        spacing=10.0,
        direction_2=(0.0, 1.0, 0.0),
        count_2=2,
        spacing_2=5.0,
    )
    instances = expand_component_pattern_instances(pattern, RigidTransform.identity())
    assert sorted(instances.keys()) == [1, 2, 3]
    _assert_vec_close(instances[1].translation, (0.0, 5.0, 0.0))  # i=0, j=1
    _assert_vec_close(instances[2].translation, (10.0, 0.0, 0.0))  # i=1, j=0
    _assert_vec_close(instances[3].translation, (10.0, 5.0, 0.0))  # i=1, j=1


def test_linear_pattern_reverse_2_flips_the_second_direction():
    pattern = _linear_pattern(
        direction=(1.0, 0.0, 0.0),
        count=1,
        spacing=0.0,
        direction_2=(0.0, 1.0, 0.0),
        count_2=2,
        spacing_2=5.0,
        reverse_2=True,
    )
    instances = expand_component_pattern_instances(pattern, RigidTransform.identity())
    assert len(instances) == 1
    _assert_vec_close(instances[1].translation, (0.0, -5.0, 0.0))


def test_linear_pattern_direction_2_is_inert_while_count_2_is_one():
    """`count_2` defaulting to `1` (every pattern authored before the
    second direction existed) means `direction_2`/`spacing_2`/`reverse_2`
    are never resolved/applied, whatever they're set to - the identical
    "`direction_2` inert unless `count_2 > 1`" convention `PatternFeature`
    already uses one level up."""
    pattern = _linear_pattern(
        direction=(1.0, 0.0, 0.0),
        count=3,
        spacing=10.0,
        direction_2=(0.0, 0.0, 0.0),
        count_2=1,
        spacing_2=999.0,
        reverse_2=True,
    )
    instances = expand_component_pattern_instances(pattern, RigidTransform.identity())
    assert sorted(instances.keys()) == [1, 2]
    _assert_vec_close(instances[1].translation, (10.0, 0.0, 0.0))
    _assert_vec_close(instances[2].translation, (20.0, 0.0, 0.0))


def test_linear_pattern_2d_grid_skip_indices_uses_the_flattened_index():
    pattern = _linear_pattern(
        direction=(1.0, 0.0, 0.0),
        count=2,
        spacing=10.0,
        direction_2=(0.0, 1.0, 0.0),
        count_2=2,
        spacing_2=5.0,
        skip_indices=[2],
    )
    instances = expand_component_pattern_instances(pattern, RigidTransform.identity())
    assert sorted(instances.keys()) == [1, 3]
    _assert_vec_close(instances[1].translation, (0.0, 5.0, 0.0))
    _assert_vec_close(instances[3].translation, (10.0, 5.0, 0.0))


def test_linear_pattern_skip_indices_omits_specific_instances_without_renumbering():
    """Phase 11 (`[9]`): skipping index 1 leaves index 2 keyed at `2`, not
    shifted down to `1` - the same "stable id per index" guarantee
    `PatternFeature.skip_indices` already provides for Body-level Patterns."""
    pattern = _linear_pattern(count=4, skip_indices=[1])
    instances = expand_component_pattern_instances(pattern, RigidTransform.identity())
    assert sorted(instances.keys()) == [2, 3]
    _assert_vec_close(instances[2].translation, (20.0, 0.0, 0.0))
    _assert_vec_close(instances[3].translation, (30.0, 0.0, 0.0))


def test_circular_pattern_evenly_spaces_instances_around_the_default_axis():
    """4 instances over 360 degrees around world Z through the origin, a
    source Occurrence sitting at (10, 0, 0) - the 3 derived instances land
    at 90/180/270 degrees."""
    pattern = _circular_pattern(count_angular=4, angle_total=360.0)
    source = RigidTransform(translation=(10.0, 0.0, 0.0))
    instances = expand_component_pattern_instances(pattern, source)
    assert len(instances) == 3
    _assert_vec_close(instances[1].translation, (0.0, 10.0, 0.0))
    _assert_vec_close(instances[2].translation, (-10.0, 0.0, 0.0))
    _assert_vec_close(instances[3].translation, (0.0, -10.0, 0.0))
    assert math.isclose(instances[1].rotation_angle_degrees, 90.0, abs_tol=1e-6)


def test_circular_pattern_reverse_angular_flips_rotation_direction():
    # Forward (see the previous test) rotates +90 degrees about Z ->
    # (0, 10, 0); reverse rotates -90 degrees instead -> (0, -10, 0).
    pattern = _circular_pattern(count_angular=2, angle_total=180.0, reverse_angular=True)
    source = RigidTransform(translation=(10.0, 0.0, 0.0))
    instances = expand_component_pattern_instances(pattern, source)
    assert len(instances) == 1
    _assert_vec_close(instances[1].translation, (0.0, -10.0, 0.0))


def test_circular_pattern_around_an_off_origin_axis():
    """Rotating a source at (10, 0, 0) by 90 degrees about a Z axis through
    (5, 0, 0): relative vector (5, 0, 0) rotates to (0, 5, 0), then the axis
    origin is added back -> (5, 5, 0)."""
    pattern = _circular_pattern(
        axis=ComponentPatternAxis(origin=(5.0, 0.0, 0.0), direction=(0.0, 0.0, 1.0)),
        count_angular=2,
        angle_total=180.0,
    )
    source = RigidTransform(translation=(10.0, 0.0, 0.0))
    instances = expand_component_pattern_instances(pattern, source)
    assert len(instances) == 1
    _assert_vec_close(instances[1].translation, (5.0, 5.0, 0.0))
    assert math.isclose(instances[1].rotation_angle_degrees, 90.0, abs_tol=1e-6)


def test_circular_pattern_defaults_to_the_world_z_axis_through_the_origin_when_axis_omitted():
    # count_angular=2 over 180 degrees -> a single +90-degree step, same
    # forward result the explicit-axis test above gets for the same params.
    pattern = _circular_pattern(axis=None, count_angular=2, angle_total=180.0)
    source = RigidTransform(translation=(10.0, 0.0, 0.0))
    instances = expand_component_pattern_instances(pattern, source)
    assert len(instances) == 1
    _assert_vec_close(instances[1].translation, (0.0, 10.0, 0.0))


def test_circular_pattern_composes_rotation_onto_an_already_rotated_source():
    """The source's own existing orientation is preserved and further
    rotated by the pattern's own +90-degree step (count_angular=2 over 180
    degrees), not overwritten by it: 30 + 90 = 120 degrees."""
    source = RigidTransform(translation=(10.0, 0.0, 0.0), rotation_axis=(0.0, 0.0, 1.0), rotation_angle_degrees=30.0)
    pattern = _circular_pattern(count_angular=2, angle_total=180.0)
    instances = expand_component_pattern_instances(pattern, source)
    assert len(instances) == 1
    assert math.isclose(instances[1].rotation_angle_degrees, 120.0, abs_tol=1e-6)
    _assert_vec_close(instances[1].rotation_axis, (0.0, 0.0, 1.0))


def test_circular_pattern_count_angular_of_one_derives_nothing():
    pattern = _circular_pattern(count_angular=1)
    assert expand_component_pattern_instances(pattern, RigidTransform.identity()) == {}


def test_circular_pattern_skip_indices_omits_specific_instances_without_renumbering():
    pattern = _circular_pattern(count_angular=4, angle_total=360.0, skip_indices=[2])
    source = RigidTransform(translation=(10.0, 0.0, 0.0))
    instances = expand_component_pattern_instances(pattern, source)
    assert sorted(instances.keys()) == [1, 3]
    _assert_vec_close(instances[1].translation, (0.0, 10.0, 0.0))
    _assert_vec_close(instances[3].translation, (0.0, -10.0, 0.0))


def test_circular_pattern_orient_with_rotation_false_repositions_without_rotating_own_orientation():
    """Phase 11 (`[10]`): with `orient_with_rotation=False`, each derived
    instance still lands at the correct circular position (the same
    translation the default `True` case produces - see the "evenly spaces"
    test above) but keeps the source's own rotation term (here, the
    identity) instead of picking up the pattern step's own +90-degree
    rotation."""
    pattern = _circular_pattern(count_angular=4, angle_total=360.0, orient_with_rotation=False)
    source = RigidTransform(translation=(10.0, 0.0, 0.0))
    instances = expand_component_pattern_instances(pattern, source)
    assert len(instances) == 3
    _assert_vec_close(instances[1].translation, (0.0, 10.0, 0.0))
    assert math.isclose(instances[1].rotation_angle_degrees, 0.0, abs_tol=1e-9)
    _assert_vec_close(instances[2].translation, (-10.0, 0.0, 0.0))
    assert math.isclose(instances[2].rotation_angle_degrees, 0.0, abs_tol=1e-9)


def test_circular_pattern_orient_with_rotation_false_preserves_a_non_identity_source_rotation():
    """The source's own pre-existing rotation (30 degrees about Z here)
    survives unchanged in every derived instance when `orient_with_rotation`
    is `False` - unlike the default `True` case (see "composes rotation
    onto an already rotated source" above, which adds the pattern step's
    own rotation on top: 30 + 90 = 120)."""
    source = RigidTransform(translation=(10.0, 0.0, 0.0), rotation_axis=(0.0, 0.0, 1.0), rotation_angle_degrees=30.0)
    pattern = _circular_pattern(count_angular=2, angle_total=180.0, orient_with_rotation=False)
    instances = expand_component_pattern_instances(pattern, source)
    assert len(instances) == 1
    assert math.isclose(instances[1].rotation_angle_degrees, 30.0, abs_tol=1e-6)
    _assert_vec_close(instances[1].rotation_axis, (0.0, 0.0, 1.0))
    _assert_vec_close(instances[1].translation, (0.0, 10.0, 0.0))
