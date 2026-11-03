"""B1 regression: matrix -> axis-angle must round-trip for every angle,
especially 180 degrees about axes with a ~0 X component."""

import math
import random

import pytest

from app.document.assembly import (
    _mat3_from_axis_angle,
    _mat3_to_axis_angle,
    compose,
    compose_chain,
    expand_component_pattern_instances,
)
from app.document.models import ComponentPattern, ComponentPatternType, RigidTransform


def _close(a, b, tol=1e-9):
    return all(abs(a[i][j] - b[i][j]) < tol for i in range(3) for j in range(3))


def _axes():
    s = math.sqrt(0.5)
    axes = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (0, s, s), (0, s, -s), (s, 0, s), (s, 0, -s), (s, s, 0), (s, -s, 0),
            (-3.8e-13, 0.7071067811865476, -0.7071067811865476)]
    rng = random.Random(7)
    for _ in range(40):
        v = [rng.uniform(-1, 1) for _ in range(3)]
        n = math.sqrt(sum(c * c for c in v))
        axes.append(tuple(c / n for c in v))
    return axes


ANGLES = [0.0, 1e-7, 45.0, 90.0, 179.9999, 180.0 - 1e-10, 180.0, 180.0 + 1e-10, 180.00000000004, 270.0, -90.0]


@pytest.mark.parametrize("angle", ANGLES)
def test_round_trip_and_idempotent(angle):
    for axis in _axes():
        m = _mat3_from_axis_angle(axis, angle)
        current = m
        for _ in range(3):
            ax, ang = _mat3_to_axis_angle(current)
            current = _mat3_from_axis_angle(ax, ang)
            assert _close(current, m), (axis, angle)


def test_bot_right_pattern_copy_world_rotation_matches_source():
    source = RigidTransform(
        translation=(0.0, 0.0, 0.0),
        rotation_axis=(-3.8e-13, 0.7071067811865476, -0.7071067811865476),
        rotation_angle_degrees=180.00000000004,
    )
    pattern = ComponentPattern(
        id="p1", source_occurrence_ids=["occ-1"], pattern_type=ComponentPatternType.LINEAR,
        direction=(0.0, 0.0, 1.0), count=2, spacing=1150.0,
    )
    instances = expand_component_pattern_instances(pattern, source)
    assert instances
    derived = next(iter(instances.values()))
    expected = _mat3_from_axis_angle(source.rotation_axis, source.rotation_angle_degrees)
    # second round trip, as the mesh walk does
    world = compose_chain([RigidTransform(), derived])
    got = _mat3_from_axis_angle(world.rotation_axis, world.rotation_angle_degrees)
    assert _close(got, expected)
