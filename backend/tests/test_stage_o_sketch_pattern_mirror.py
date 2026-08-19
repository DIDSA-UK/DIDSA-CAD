"""Sketcher-roadmap Phase 7 (2D Pattern/Mirror, docs/pattern-mirror-scope.md
Section 2.9/4): lightweight, non-solved sketch-level Pattern/Mirror
instances - pure 2D math (`Sketch.add_pattern_instance`/`add_mirror_
instance`/`expand_pattern_and_mirror_instances`, `app.sketch.models`), the
`detect_profile` wire-assembly expansion pre-pass (`app.sketch.profile`),
and the new CRUD endpoints (`app.sketch.router`).

Section A (model-level, pure Python, no OCCT) mirrors `test_feature_offset_
entities.py`'s own OCCT-free shape - `app.sketch.models` never imports OCC.
Sections B/C (detect_profile / HTTP endpoints) transitively import `app.
sketch.text_geometry`, which does need a real `pythonocc-core` - same
"OCCT-touching test" caveat every profile.py-dependent test file in this
suite already carries.
"""

import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.main import app
from app.sketch.models import (
    Plane,
    Sketch,
    SketchFixedAxis,
    SketchPatternDirection,
)
from app.sketch.profile import ProfileStatus, detect_profile
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Section A: model-level, pure 2D math, no OCCT --------------------------


def _line_sketch() -> tuple[Sketch, "object"]:
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    return sketch, line


def test_expand_with_no_instances_returns_the_same_object():
    sketch, _ = _line_sketch()
    assert sketch.expand_pattern_and_mirror_instances() is sketch


def test_add_pattern_instance_rejects_empty_source():
    sketch, _ = _line_sketch()
    with pytest.raises(ValueError):
        sketch.add_pattern_instance([], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=1.0)


def test_add_pattern_instance_rejects_unsupported_source_kind():
    # Ellipse/EllipseArc are valid Pattern/Mirror sources (see the Section A.1
    # tests below) - Spline is not, and stands in here for "any entity kind
    # outside {Line, Circle, Arc, Ellipse, EllipseArc}".
    sketch, _ = _line_sketch()
    a = sketch.add_point(0.0, 5.0)
    b = sketch.add_point(5.0, 8.0)
    c = sketch.add_point(10.0, 5.0)
    spline = sketch.add_spline([a.id, b.id, c.id])
    with pytest.raises(ValueError):
        sketch.add_pattern_instance(
            [spline.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=1.0
        )


def test_add_pattern_instance_rejects_unknown_source_id():
    sketch, _ = _line_sketch()
    with pytest.raises(KeyError):
        sketch.add_pattern_instance(
            ["nope"], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=1.0
        )


def test_add_pattern_instance_rejects_neither_or_both_direction_fields():
    sketch, line = _line_sketch()
    with pytest.raises(ValueError):
        sketch.add_pattern_instance([line.id], SketchPatternDirection(), count_1=3, spacing_1=1.0)
    with pytest.raises(ValueError):
        sketch.add_pattern_instance(
            [line.id],
            SketchPatternDirection(line_id=line.id, fixed_axis=SketchFixedAxis.X),
            count_1=3,
            spacing_1=1.0,
        )


def test_add_pattern_instance_rejects_count_below_two():
    sketch, line = _line_sketch()
    with pytest.raises(ValueError):
        sketch.add_pattern_instance([line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=1, spacing_1=1.0)


def test_add_pattern_instance_rejects_zero_spacing():
    sketch, line = _line_sketch()
    with pytest.raises(ValueError):
        sketch.add_pattern_instance([line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=0.0)


def test_add_pattern_instance_rejects_zero_length_direction_line():
    sketch, line = _line_sketch()
    p = sketch.add_point(3.0, 3.0)
    zero_line = sketch.add_line(p.id, sketch.add_point(3.0, 3.0).id)
    with pytest.raises(ValueError):
        sketch.add_pattern_instance(
            [line.id], SketchPatternDirection(line_id=zero_line.id), count_1=3, spacing_1=1.0
        )


def test_pattern_fixed_axis_x_produces_expected_translated_copies():
    sketch, line = _line_sketch()
    sketch.add_pattern_instance([line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=5.0)

    expanded = sketch.expand_pattern_and_mirror_instances()

    lines = [e for e in expanded.entities.values() if e.type == "line"]
    assert len(lines) == 3
    starts_x = sorted(expanded.points[l.start_point_id].x for l in lines)
    assert starts_x == pytest.approx([0.0, 5.0, 10.0])
    # The seed's own real entity/point ids are untouched and still present.
    assert line.id in expanded.entities


def test_pattern_reverse_flips_direction():
    sketch, line = _line_sketch()
    sketch.add_pattern_instance(
        [line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=2, spacing_1=5.0, reverse_1=True
    )
    expanded = sketch.expand_pattern_and_mirror_instances()
    new_lines = [e for e in expanded.entities.values() if e.type == "line" and e.id != line.id]
    assert len(new_lines) == 1
    assert expanded.points[new_lines[0].start_point_id].x == pytest.approx(-5.0)


def test_pattern_direction_from_line_uses_its_unit_vector():
    sketch, line = _line_sketch()
    dir_a = sketch.add_point(0.0, 0.0)
    dir_b = sketch.add_point(0.0, 3.0)  # +Y direction, length 3 (normalized away)
    dir_line = sketch.add_line(dir_a.id, dir_b.id, construction=True)
    sketch.add_pattern_instance([line.id], SketchPatternDirection(line_id=dir_line.id), count_1=2, spacing_1=4.0)

    expanded = sketch.expand_pattern_and_mirror_instances()
    new_lines = [e for e in expanded.entities.values() if e.type == "line" and e.id != line.id and e.id != dir_line.id]
    assert len(new_lines) == 1
    start = expanded.points[new_lines[0].start_point_id]
    assert start.x == pytest.approx(0.0)
    assert start.y == pytest.approx(4.0)


def test_pattern_preserves_shared_endpoint_of_a_connected_chain():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(b.id, c.id)
    sketch.add_pattern_instance(
        [line1.id, line2.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.Y), count_1=2, spacing_1=1.0
    )

    expanded = sketch.expand_pattern_and_mirror_instances()
    new_line1 = next(e for e in expanded.entities.values() if e.type == "line" and e.id.endswith(f"#{line1.id}"))
    new_line2 = next(e for e in expanded.entities.values() if e.type == "line" and e.id.endswith(f"#{line2.id}"))
    # The two patterned copies must still share their own corner Point -
    # same original point (b) always maps to the same synthetic id.
    assert new_line1.end_point_id == new_line2.start_point_id


def test_pattern_of_circle_and_arc():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    radius_point = sketch.add_point(2.0, 0.0)
    circle = sketch.add_circle(center.id, radius_point_id=radius_point.id)
    arc_center = sketch.add_point(0.0, 20.0)
    arc_start = sketch.add_point(2.0, 20.0)
    arc = sketch.add_arc(arc_center.id, arc_start.id, end_angle=math.pi / 2)

    sketch.add_pattern_instance(
        [circle.id, arc.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=2, spacing_1=10.0
    )
    expanded = sketch.expand_pattern_and_mirror_instances()

    new_circle = next(e for e in expanded.entities.values() if e.type == "circle" and e.id != circle.id)
    assert expanded.points[new_circle.center_point_id].x == pytest.approx(10.0)
    assert new_circle.radius(expanded.points) == pytest.approx(2.0)

    new_arc = next(e for e in expanded.entities.values() if e.type == "arc" and e.id != arc.id)
    assert expanded.points[new_arc.center_point_id].x == pytest.approx(10.0)
    assert expanded.points[new_arc.center_point_id].y == pytest.approx(20.0)


def test_pattern_of_ellipse_translates_every_defining_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(4.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=2.0)

    sketch.add_pattern_instance(
        [ellipse.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=2, spacing_1=10.0
    )
    expanded = sketch.expand_pattern_and_mirror_instances()

    new_ellipse = next(e for e in expanded.entities.values() if e.type == "ellipse" and e.id != ellipse.id)
    assert expanded.points[new_ellipse.center_point_id].x == pytest.approx(10.0)
    assert expanded.points[new_ellipse.center_point_id].y == pytest.approx(0.0)
    assert new_ellipse.major_radius(expanded.points) == pytest.approx(4.0)
    assert new_ellipse.minor_radius(expanded.points) == pytest.approx(2.0)
    assert new_ellipse.rotation(expanded.points) == pytest.approx(0.0)
    # The negative axis tips need no special re-derivation - translation is
    # affine and preserves the AtMidpoint symmetry automatically (see
    # `_place_transformed_entity`'s own Ellipse branch doc comment).
    assert expanded.points[new_ellipse.major_point_neg_id].x == pytest.approx(6.0)
    assert expanded.points[new_ellipse.minor_point_neg_id].y == pytest.approx(-2.0)


def test_pattern_of_ellipse_arc_translates_every_defining_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(4.0, 0.0)
    ellipse_arc = sketch.add_ellipse_arc(center.id, major.id, minor_radius=2.0, start_angle=0.0, end_angle=math.pi / 2)

    sketch.add_pattern_instance(
        [ellipse_arc.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.Y), count_1=2, spacing_1=10.0
    )
    expanded = sketch.expand_pattern_and_mirror_instances()

    new_arc = next(e for e in expanded.entities.values() if e.type == "ellipse_arc" and e.id != ellipse_arc.id)
    assert expanded.points[new_arc.center_point_id].y == pytest.approx(10.0)
    assert new_arc.major_radius(expanded.points) == pytest.approx(4.0)
    assert new_arc.minor_radius(expanded.points) == pytest.approx(2.0)
    original_start = sketch.points[ellipse_arc.start_point_id]
    original_end = sketch.points[ellipse_arc.end_point_id]
    new_start = expanded.points[new_arc.start_point_id]
    new_end = expanded.points[new_arc.end_point_id]
    assert (new_start.x, new_start.y) == pytest.approx((original_start.x, original_start.y + 10.0))
    assert (new_end.x, new_end.y) == pytest.approx((original_end.x, original_end.y + 10.0))


def test_pattern_two_directions_produces_a_row_major_grid():
    """On-device feedback ("allow pattern in two directions, check body
    pattern tool for UX"): a 2x3 grid (count_1=2 along X, count_2=3 along
    Y) produces 5 new instances (6 total including the untouched seed at
    linear index 0), each at `(i*spacing_1, j*spacing_2)` - row-major,
    matching `PatternFeature`'s own `index = i * count_2 + j` convention."""
    sketch, line = _line_sketch()
    sketch.add_pattern_instance(
        [line.id],
        SketchPatternDirection(fixed_axis=SketchFixedAxis.X),
        count_1=2,
        spacing_1=10.0,
        direction_2=SketchPatternDirection(fixed_axis=SketchFixedAxis.Y),
        count_2=3,
        spacing_2=100.0,
    )

    expanded = sketch.expand_pattern_and_mirror_instances()

    new_lines = [e for e in expanded.entities.values() if e.type == "line" and e.id != line.id]
    assert len(new_lines) == 5
    starts = sorted((expanded.points[l.start_point_id].x, expanded.points[l.start_point_id].y) for l in new_lines)
    expected = sorted(
        (i * 10.0, j * 100.0) for i in range(2) for j in range(3) if not (i == 0 and j == 0)
    )
    assert starts == pytest.approx(expected)


def test_pattern_two_directions_reverse_2_flips_the_second_direction():
    sketch, line = _line_sketch()
    sketch.add_pattern_instance(
        [line.id],
        SketchPatternDirection(fixed_axis=SketchFixedAxis.X),
        count_1=1,
        spacing_1=0.0,
        direction_2=SketchPatternDirection(fixed_axis=SketchFixedAxis.Y),
        count_2=2,
        spacing_2=10.0,
        reverse_2=True,
    )
    expanded = sketch.expand_pattern_and_mirror_instances()
    new_lines = [e for e in expanded.entities.values() if e.type == "line" and e.id != line.id]
    assert len(new_lines) == 1
    assert expanded.points[new_lines[0].start_point_id].y == pytest.approx(-10.0)


def test_pattern_count_1_of_one_patterns_purely_along_direction_2():
    """`count_1 == 1` alone is a no-op contribution from direction_1 (i only
    ever takes 0) - a valid, real shape once a second direction exists,
    unlike single-direction Pattern where `count_1 >= 2` was the whole
    point."""
    sketch, line = _line_sketch()
    sketch.add_pattern_instance(
        [line.id],
        SketchPatternDirection(fixed_axis=SketchFixedAxis.X),
        count_1=1,
        spacing_1=0.0,
        direction_2=SketchPatternDirection(fixed_axis=SketchFixedAxis.Y),
        count_2=2,
        spacing_2=7.0,
    )
    expanded = sketch.expand_pattern_and_mirror_instances()
    new_lines = [e for e in expanded.entities.values() if e.type == "line" and e.id != line.id]
    assert len(new_lines) == 1
    assert expanded.points[new_lines[0].start_point_id].x == pytest.approx(0.0)
    assert expanded.points[new_lines[0].start_point_id].y == pytest.approx(7.0)


def test_add_pattern_instance_rejects_count_2_without_direction_2():
    sketch, line = _line_sketch()
    with pytest.raises(ValueError):
        sketch.add_pattern_instance(
            [line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=2, spacing_1=5.0, count_2=2
        )


def test_add_pattern_instance_rejects_zero_spacing_2():
    sketch, line = _line_sketch()
    with pytest.raises(ValueError):
        sketch.add_pattern_instance(
            [line.id],
            SketchPatternDirection(fixed_axis=SketchFixedAxis.X),
            count_1=2,
            spacing_1=5.0,
            direction_2=SketchPatternDirection(fixed_axis=SketchFixedAxis.Y),
            count_2=2,
            spacing_2=0.0,
        )


def test_update_pattern_instance_can_add_and_then_clear_direction_2():
    sketch, line = _line_sketch()
    instance = sketch.add_pattern_instance(
        [line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=2, spacing_1=5.0
    )

    sketch.update_pattern_instance(
        instance.id,
        direction_2=SketchPatternDirection(fixed_axis=SketchFixedAxis.Y),
        count_2=2,
        spacing_2=10.0,
    )
    assert instance.direction_2 is not None
    assert instance.count_2 == 2

    sketch.update_pattern_instance(instance.id, clear_direction_2=True, count_2=1)
    assert instance.direction_2 is None
    assert instance.count_2 == 1


def test_update_pattern_instance_revalidates_count_2_needs_direction_2():
    sketch, line = _line_sketch()
    instance = sketch.add_pattern_instance(
        [line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=2, spacing_1=5.0
    )
    with pytest.raises(ValueError):
        sketch.update_pattern_instance(instance.id, count_2=2)


def test_pattern_instance_native_format_round_trip_with_two_directions():
    sketch, line = _line_sketch()
    sketch.add_pattern_instance(
        [line.id],
        SketchPatternDirection(fixed_axis=SketchFixedAxis.X),
        count_1=2,
        spacing_1=10.0,
        reverse_1=True,
        direction_2=SketchPatternDirection(fixed_axis=SketchFixedAxis.Y),
        count_2=3,
        spacing_2=20.0,
        reverse_2=True,
    )

    round_tripped = sketch_from_dict(sketch_to_dict(sketch))

    original = next(iter(sketch.pattern_instances.values()))
    restored = next(iter(round_tripped.pattern_instances.values()))
    assert restored.count_1 == original.count_1
    assert restored.spacing_1 == original.spacing_1
    assert restored.reverse_1 == original.reverse_1
    assert restored.direction_2 == original.direction_2
    assert restored.count_2 == original.count_2
    assert restored.spacing_2 == original.spacing_2
    assert restored.reverse_2 == original.reverse_2


def test_pattern_instance_native_format_import_defaults_missing_second_direction_fields():
    """A save from the brief window between Phase 7's own initial ship and
    this on-device revision has no `direction_2`/`count_2`/`spacing_2`/
    `reverse_2` keys at all, and its primary fields are still named
    `direction`/`count`/`spacing`/`reverse` - both must import cleanly."""
    data = {
        "id": "s",
        "plane": "XY",
        "origin_point_id": None,
        "points": [],
        "entities": [],
        "constraints": [],
        "pattern_instances": [
            {
                "id": "pat-1",
                "source_entity_ids": ["line-1"],
                "direction": {"line_id": None, "fixed_axis": "x"},
                "count": 3,
                "spacing": 5.0,
            }
        ],
    }
    sketch = sketch_from_dict(data)
    instance = sketch.pattern_instances["pat-1"]
    assert instance.count_1 == 3
    assert instance.spacing_1 == 5.0
    assert instance.reverse_1 is False
    assert instance.direction_2 is None
    assert instance.count_2 == 1
    assert instance.spacing_2 == 0.0
    assert instance.reverse_2 is False


def test_update_pattern_instance_partial_update_leaves_other_fields_unchanged():
    sketch, line = _line_sketch()
    instance = sketch.add_pattern_instance(
        [line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=5.0
    )
    sketch.update_pattern_instance(instance.id, spacing_1=8.0)
    assert instance.spacing_1 == 8.0
    assert instance.count_1 == 3
    assert instance.direction_1.fixed_axis == SketchFixedAxis.X


def test_update_pattern_instance_revalidates_merged_result():
    sketch, line = _line_sketch()
    instance = sketch.add_pattern_instance(
        [line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=5.0
    )
    with pytest.raises(ValueError):
        sketch.update_pattern_instance(instance.id, count_1=1)
    assert instance.count_1 == 3  # unchanged - the failed update never partially applied


def test_delete_pattern_instance_removes_it_and_its_derived_geometry():
    sketch, line = _line_sketch()
    instance = sketch.add_pattern_instance(
        [line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=5.0
    )
    sketch.delete_pattern_instance(instance.id)
    assert instance.id not in sketch.pattern_instances
    expanded = sketch.expand_pattern_and_mirror_instances()
    assert expanded is sketch  # no instances left at all


def test_delete_pattern_instance_missing_id_raises():
    sketch, _ = _line_sketch()
    with pytest.raises(KeyError):
        sketch.delete_pattern_instance("nope")


def test_pattern_instance_tolerates_a_deleted_source_entity():
    sketch, line = _line_sketch()
    instance = sketch.add_pattern_instance(
        [line.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=5.0
    )
    sketch.delete_line(line.id)
    # Drift-tolerant at read time - does not raise, just produces nothing.
    expanded = sketch.expand_pattern_and_mirror_instances()
    assert not any(eid.startswith(f"{instance.id}#") for eid in expanded.entities)


def test_add_mirror_instance_rejects_non_line_mirror_id():
    sketch, line = _line_sketch()
    with pytest.raises(KeyError):
        sketch.add_mirror_instance([line.id], "not-a-line")


def test_mirror_line_across_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    mirror_a = sketch.add_point(0.0, -5.0)
    mirror_b = sketch.add_point(0.0, 5.0)
    mirror_line = sketch.add_line(mirror_a.id, mirror_b.id, construction=True)
    source_a = sketch.add_point(2.0, 0.0)
    source_b = sketch.add_point(2.0, 3.0)
    source_line = sketch.add_line(source_a.id, source_b.id)

    sketch.add_mirror_instance([source_line.id], mirror_line.id)
    expanded = sketch.expand_pattern_and_mirror_instances()

    mirrored = next(
        e for e in expanded.entities.values() if e.type == "line" and e.id not in (mirror_line.id, source_line.id)
    )
    start = expanded.points[mirrored.start_point_id]
    end = expanded.points[mirrored.end_point_id]
    assert {round(start.x, 6), round(end.x, 6)} == {-2.0}
    assert sorted([start.y, end.y]) == pytest.approx([0.0, 3.0])


def test_mirror_arc_swaps_endpoints_to_preserve_ccw_visual_arc():
    sketch = Sketch(id="s", plane=Plane.XY)
    mirror_a = sketch.add_point(0.0, -5.0)
    mirror_b = sketch.add_point(0.0, 5.0)
    mirror_line = sketch.add_line(mirror_a.id, mirror_b.id, construction=True)
    center = sketch.add_point(0.0, 0.0)
    start = sketch.add_point(1.0, 0.0)
    arc = sketch.add_arc(center.id, start.id, end_angle=math.pi / 2)  # CCW quarter circle, Q1

    sketch.add_mirror_instance([arc.id], mirror_line.id)
    expanded = sketch.expand_pattern_and_mirror_instances()
    mirrored = next(e for e in expanded.entities.values() if e.type == "arc" and e.id != arc.id)

    mirrored_start = expanded.points[mirrored.start_point_id]
    mirrored_end = expanded.points[mirrored.end_point_id]
    # The correct mirror image of the Q1 CCW quarter-circle (0deg->90deg) is
    # the Q2 CCW quarter-circle swept 90deg->180deg - i.e. starting at the
    # point nearest the original *end* (now on the mirror line itself) and
    # ending at the point nearest the original *start*'s own mirror image.
    assert mirrored_start.x == pytest.approx(0.0, abs=1e-9)
    assert mirrored_start.y == pytest.approx(1.0)
    assert mirrored_end.x == pytest.approx(-1.0)
    assert mirrored_end.y == pytest.approx(0.0, abs=1e-9)


def test_mirror_ellipse_reflects_every_defining_point_and_preserves_symmetry():
    sketch = Sketch(id="s", plane=Plane.XY)
    mirror_a = sketch.add_point(0.0, -5.0)
    mirror_b = sketch.add_point(0.0, 5.0)
    mirror_line = sketch.add_line(mirror_a.id, mirror_b.id, construction=True)
    center = sketch.add_point(2.0, 0.0)
    major = sketch.add_point(6.0, 0.0)
    ellipse = sketch.add_ellipse(center.id, major.id, minor_radius=2.0)

    sketch.add_mirror_instance([ellipse.id], mirror_line.id)
    expanded = sketch.expand_pattern_and_mirror_instances()
    mirrored = next(e for e in expanded.entities.values() if e.type == "ellipse" and e.id != ellipse.id)

    assert expanded.points[mirrored.center_point_id].x == pytest.approx(-2.0)
    assert mirrored.major_radius(expanded.points) == pytest.approx(4.0)
    assert mirrored.minor_radius(expanded.points) == pytest.approx(2.0)
    # Reflection is affine too - the AtMidpoint symmetry between a positive
    # tip and its negative counterpart survives without special-casing.
    assert expanded.points[mirrored.major_point_id].x == pytest.approx(-6.0)
    assert expanded.points[mirrored.major_point_neg_id].x == pytest.approx(2.0)


def test_mirror_ellipse_arc_swaps_endpoints_to_preserve_ccw_visual_arc():
    sketch = Sketch(id="s", plane=Plane.XY)
    mirror_a = sketch.add_point(0.0, -5.0)
    mirror_b = sketch.add_point(0.0, 5.0)
    mirror_line = sketch.add_line(mirror_a.id, mirror_b.id, construction=True)
    center = sketch.add_point(0.0, 0.0)
    major = sketch.add_point(2.0, 0.0)
    ellipse_arc = sketch.add_ellipse_arc(center.id, major.id, minor_radius=1.0, start_angle=0.0, end_angle=math.pi / 2)

    sketch.add_mirror_instance([ellipse_arc.id], mirror_line.id)
    expanded = sketch.expand_pattern_and_mirror_instances()
    mirrored = next(e for e in expanded.entities.values() if e.type == "ellipse_arc" and e.id != ellipse_arc.id)

    original_start = sketch.points[ellipse_arc.start_point_id]
    original_end = sketch.points[ellipse_arc.end_point_id]
    mirrored_start = expanded.points[mirrored.start_point_id]
    mirrored_end = expanded.points[mirrored.end_point_id]
    # Same swap as the plain-Arc case above: the mirrored curve's own start
    # must be the reflection of the *original end* for the CCW-from-start
    # convention to still trace the visually-correct (non-reflex) sweep.
    assert (mirrored_start.x, mirrored_start.y) == pytest.approx((-original_end.x, original_end.y))
    assert (mirrored_end.x, mirrored_end.y) == pytest.approx((-original_start.x, original_start.y))


def test_mirror_instance_across_zero_length_line_produces_nothing():
    sketch, line = _line_sketch()
    p = sketch.add_point(1.0, 1.0)
    zero_line = sketch.add_line(p.id, sketch.add_point(1.0, 1.0).id, construction=True)
    sketch.add_mirror_instance([line.id], zero_line.id)
    expanded = sketch.expand_pattern_and_mirror_instances()
    assert not any(e.id != line.id and e.id != zero_line.id for e in expanded.entities.values())


def test_update_and_delete_mirror_instance():
    sketch, line = _line_sketch()
    mirror_a = sketch.add_point(0.0, -5.0)
    mirror_b = sketch.add_point(0.0, 5.0)
    mirror_line = sketch.add_line(mirror_a.id, mirror_b.id, construction=True)
    other_mirror_a = sketch.add_point(-5.0, 0.0)
    other_mirror_b = sketch.add_point(5.0, 0.0)
    other_mirror_line = sketch.add_line(other_mirror_a.id, other_mirror_b.id, construction=True)

    instance = sketch.add_mirror_instance([line.id], mirror_line.id)
    sketch.update_mirror_instance(instance.id, mirror_line_id=other_mirror_line.id)
    assert instance.mirror_line_id == other_mirror_line.id

    sketch.delete_mirror_instance(instance.id)
    assert instance.id not in sketch.mirror_instances
    with pytest.raises(KeyError):
        sketch.delete_mirror_instance(instance.id)


# --- Section B: detect_profile expansion pre-pass (needs OCCT) -------------


def test_detect_profile_unaffected_for_a_sketch_with_no_instances():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    d = sketch.add_point(0.0, 10.0)
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)
    sketch.add_line(c.id, d.id)
    sketch.add_line(d.id, a.id)

    result = detect_profile(sketch)
    assert result.status == ProfileStatus.CLOSED_LOOP
    assert len(result.profile.point_ids) == 4


def test_detect_profile_closes_a_loop_mirrored_from_a_half_profile():
    """The single most common real-world reason to mirror a sketch at all:
    draw half a symmetric profile up to a centerline, mirror it across that
    centerline, get one closed loop - the load-bearing case §2.9 calls out
    (and the reason `_place_transformed_entity`'s own "weld a transformed
    Point back onto its source when it lands on the exact same position"
    fix exists - see that method's own doc comment; found via this exact
    test failing during Phase 7's own development, not anticipated by the
    original design).

    Half-profile: A(0,0) -> B(5,0) -> C(5,5) -> D(0,5), both open ends (A,
    D) sitting exactly on the mirror axis (the Y-axis) - so their own
    mirrored images weld back onto them, and the combined real+mirrored
    geometry forms one connected hexagonal loop: A-B-C-D-C'-B'-A."""
    sketch = Sketch(id="s", plane=Plane.XY)
    mirror_a = sketch.add_point(0.0, -10.0)
    mirror_b = sketch.add_point(0.0, 10.0)
    mirror_line = sketch.add_line(mirror_a.id, mirror_b.id, construction=True)

    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(5.0, 0.0)
    c = sketch.add_point(5.0, 5.0)
    d = sketch.add_point(0.0, 5.0)
    line_ab = sketch.add_line(a.id, b.id)
    line_bc = sketch.add_line(b.id, c.id)
    line_cd = sketch.add_line(c.id, d.id)

    sketch.add_mirror_instance([line_ab.id, line_bc.id, line_cd.id], mirror_line.id)

    result = detect_profile(sketch)
    assert result.status == ProfileStatus.CLOSED_LOOP
    # 6 distinct corners (A, B, C, D, C', B') - A and D are shared/welded,
    # not duplicated.
    assert len(result.profile.point_ids) == 6
    assert a.id in result.profile.point_ids
    assert d.id in result.profile.point_ids


def test_detect_profile_pattern_of_a_closed_loop_produces_multiple_loops():
    """A Pattern's own translated copies never weld back onto pre-existing
    geometry (translation has no fixed points) - but a Pattern of an
    *already self-contained closed* source (a Circle here) still produces
    N genuinely independent, individually-closed loops, each entirely its
    own instance's own derived geometry."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    radius_point = sketch.add_point(2.0, 0.0)
    circle = sketch.add_circle(center.id, radius_point_id=radius_point.id)
    sketch.add_pattern_instance(
        [circle.id], SketchPatternDirection(fixed_axis=SketchFixedAxis.X), count_1=3, spacing_1=10.0
    )

    result = detect_profile(sketch)
    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 3


def test_detect_profile_treats_a_standalone_mirrored_circle_as_its_own_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    mirror_a = sketch.add_point(0.0, -5.0)
    mirror_b = sketch.add_point(0.0, 5.0)
    mirror_line = sketch.add_line(mirror_a.id, mirror_b.id, construction=True)
    center = sketch.add_point(5.0, 0.0)
    radius_point = sketch.add_point(7.0, 0.0)
    circle = sketch.add_circle(center.id, radius_point_id=radius_point.id)
    sketch.add_mirror_instance([circle.id], mirror_line.id)

    result = detect_profile(sketch)
    # Two disjoint circles (the real one and its mirror image) - MultiProfile.
    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 2


def test_detect_profile_construction_direction_line_never_closes_a_loop_itself():
    """A pattern's own `direction.line_id`/mirror's own `mirror_line_id`
    reference is typically a construction Line - `detect_profile` already
    filters construction entities before the connectivity walk, unaffected
    by Phase 7 (confirms the expansion pre-pass doesn't accidentally
    un-construction anything)."""
    sketch, line = _line_sketch()
    dir_a = sketch.add_point(0.0, 0.0)
    dir_b = sketch.add_point(0.0, 3.0)
    dir_line = sketch.add_line(dir_a.id, dir_b.id, construction=True)
    sketch.add_pattern_instance([line.id], SketchPatternDirection(line_id=dir_line.id), count_1=2, spacing_1=4.0)

    result = detect_profile(sketch)
    # Two disjoint open Lines (original + one pattern copy) plus a
    # construction direction Line - nothing closes, still NO_LOOP.
    assert result.status == ProfileStatus.NO_LOOP


# --- Section C: HTTP endpoints (needs OCCT, full app) -----------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _create_line(sketch_id: str, start_id: str, end_id: str, *, construction: bool = False) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_id, "end_point_id": end_id, "construction": construction},
    )
    assert response.status_code == 201
    return response.json()


def test_create_pattern_instance_endpoint():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/pattern-instances",
        json={
            "source_entity_ids": [line["id"]],
            "direction_1": {"fixed_axis": "y"},
            "count_1": 3,
            "spacing_1": 5.0,
        },
    )
    assert response.status_code == 201
    body = response.json()
    assert body["count_1"] == 3
    assert body["direction_1"]["fixed_axis"] == "y"

    listed = client.get(f"/sketch/sketches/{sketch['id']}/pattern-instances").json()
    assert len(listed) == 1
    assert listed[0]["id"] == body["id"]


def test_create_pattern_instance_endpoint_with_two_directions():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/pattern-instances",
        json={
            "source_entity_ids": [line["id"]],
            "direction_1": {"fixed_axis": "x"},
            "count_1": 2,
            "spacing_1": 10.0,
            "direction_2": {"fixed_axis": "y"},
            "count_2": 2,
            "spacing_2": 20.0,
        },
    )
    assert response.status_code == 201
    body = response.json()
    assert body["count_2"] == 2
    assert body["direction_2"]["fixed_axis"] == "y"

    updated = client.patch(
        f"/sketch/sketches/{sketch['id']}/pattern-instances/{body['id']}", json={"clear_direction_2": True, "count_2": 1}
    )
    assert updated.status_code == 200
    assert updated.json()["direction_2"] is None
    assert updated.json()["count_2"] == 1


def test_create_pattern_instance_count_2_without_direction_2_returns_400():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/pattern-instances",
        json={
            "source_entity_ids": [line["id"]],
            "direction_1": {"fixed_axis": "x"},
            "count_1": 2,
            "spacing_1": 10.0,
            "count_2": 2,
        },
    )
    assert response.status_code == 400


def test_create_pattern_instance_invalid_source_returns_400():
    sketch = _create_sketch()
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/pattern-instances",
        json={"source_entity_ids": [], "direction_1": {"fixed_axis": "x"}, "count_1": 3, "spacing_1": 5.0},
    )
    assert response.status_code == 400


def test_create_pattern_instance_unknown_source_returns_404():
    sketch = _create_sketch()
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/pattern-instances",
        json={"source_entity_ids": ["nope"], "direction_1": {"fixed_axis": "x"}, "count_1": 3, "spacing_1": 5.0},
    )
    assert response.status_code == 404


def test_create_pattern_instance_direction_requires_exactly_one_field():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/pattern-instances",
        json={"source_entity_ids": [line["id"]], "direction_1": {}, "count_1": 3, "spacing_1": 5.0},
    )
    assert response.status_code == 422


def test_update_and_delete_pattern_instance_endpoints():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/pattern-instances",
        json={"source_entity_ids": [line["id"]], "direction_1": {"fixed_axis": "x"}, "count_1": 3, "spacing_1": 5.0},
    ).json()

    updated = client.patch(
        f"/sketch/sketches/{sketch['id']}/pattern-instances/{created['id']}", json={"spacing_1": 8.0}
    )
    assert updated.status_code == 200
    assert updated.json()["spacing_1"] == 8.0
    assert updated.json()["count_1"] == 3

    deleted = client.delete(f"/sketch/sketches/{sketch['id']}/pattern-instances/{created['id']}")
    assert deleted.status_code == 200
    assert deleted.json()["id"] == created["id"]

    listed = client.get(f"/sketch/sketches/{sketch['id']}/pattern-instances").json()
    assert listed == []


def test_pattern_instance_endpoints_404_for_missing_sketch_or_instance():
    sketch = _create_sketch()
    assert client.get("/sketch/sketches/nope/pattern-instances").status_code == 404
    assert client.get(f"/sketch/sketches/{sketch['id']}/pattern-instances/nope").status_code == 404
    assert client.delete(f"/sketch/sketches/{sketch['id']}/pattern-instances/nope").status_code == 404


def test_create_mirror_instance_endpoint():
    sketch = _create_sketch()
    mirror_a = _create_point(sketch["id"], 0.0, -5.0)
    mirror_b = _create_point(sketch["id"], 0.0, 5.0)
    mirror_line = _create_line(sketch["id"], mirror_a["id"], mirror_b["id"], construction=True)
    src_a = _create_point(sketch["id"], 2.0, 0.0)
    src_b = _create_point(sketch["id"], 2.0, 3.0)
    src_line = _create_line(sketch["id"], src_a["id"], src_b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/mirror-instances",
        json={"source_entity_ids": [src_line["id"]], "mirror_line_id": mirror_line["id"]},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["mirror_line_id"] == mirror_line["id"]

    listed = client.get(f"/sketch/sketches/{sketch['id']}/mirror-instances").json()
    assert len(listed) == 1


def test_create_mirror_instance_unknown_mirror_line_returns_404():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], a["id"], b["id"])
    response = client.post(
        f"/sketch/sketches/{sketch['id']}/mirror-instances",
        json={"source_entity_ids": [line["id"]], "mirror_line_id": "nope"},
    )
    assert response.status_code == 404


def test_update_and_delete_mirror_instance_endpoints():
    sketch = _create_sketch()
    mirror_a = _create_point(sketch["id"], 0.0, -5.0)
    mirror_b = _create_point(sketch["id"], 0.0, 5.0)
    mirror_line = _create_line(sketch["id"], mirror_a["id"], mirror_b["id"], construction=True)
    other_mirror_a = _create_point(sketch["id"], -5.0, 0.0)
    other_mirror_b = _create_point(sketch["id"], 5.0, 0.0)
    other_mirror_line = _create_line(sketch["id"], other_mirror_a["id"], other_mirror_b["id"], construction=True)
    src_a = _create_point(sketch["id"], 2.0, 0.0)
    src_b = _create_point(sketch["id"], 2.0, 3.0)
    src_line = _create_line(sketch["id"], src_a["id"], src_b["id"])
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/mirror-instances",
        json={"source_entity_ids": [src_line["id"]], "mirror_line_id": mirror_line["id"]},
    ).json()

    updated = client.patch(
        f"/sketch/sketches/{sketch['id']}/mirror-instances/{created['id']}",
        json={"mirror_line_id": other_mirror_line["id"]},
    )
    assert updated.status_code == 200
    assert updated.json()["mirror_line_id"] == other_mirror_line["id"]

    deleted = client.delete(f"/sketch/sketches/{sketch['id']}/mirror-instances/{created['id']}")
    assert deleted.status_code == 200

    listed = client.get(f"/sketch/sketches/{sketch['id']}/mirror-instances").json()
    assert listed == []
