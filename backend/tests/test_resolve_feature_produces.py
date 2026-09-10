"""Bug fix (on-device feedback: "mirrored and patterned surfaces present in
the build tree as bodies... they should present as surfaces like their
parent surface from which they were copied, these copied surfaces will
need to be valid targets for thicken and body from surfaces down the
line"): pure-Python tests for `app.document.graph.resolve_feature_produces`,
the source-aware replacement for `MirrorFeature.produces`/`PatternFeature.
produces` (both hardcoded to `Produces.BODY` before this fix). Mirrors
test_surface_graph.py's/test_stage_i_mirror_graph.py's shape - has zero
OCCT dependency, so this runs for real in this sandbox.
"""

from app.document.graph import resolve_feature_produces
from app.document.models import (
    ExtrudeFeature,
    ExtrudeType,
    FixedAxis,
    MirrorFeature,
    Part,
    PatternDirectionRef,
    PatternFeature,
    PatternType,
    PlaneRef,
    Produces,
    SketchFeature,
    SurfaceFeature,
)
from app.sketch.models import Plane


def _part_with_sketch() -> tuple[Part, str]:
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    return part, sketch_feature.id


def _add_extrude(part: Part, sketch_feature_id: str, feature_id: str = "ef1") -> str:
    extrude = ExtrudeFeature(
        id=feature_id,
        sketch_feature_id=sketch_feature_id,
        extrude_type=ExtrudeType.BOSS,
        start_distance=0,
        end_distance=10,
    )
    part.add_feature(extrude)
    return extrude.id


def _add_surface(part: Part, sketch_feature_id: str, feature_id: str = "surf1") -> str:
    surface = SurfaceFeature(id=feature_id, sketch_feature_id=sketch_feature_id, start_distance=0, end_distance=5)
    part.add_feature(surface)
    return surface.id


def test_mirror_of_a_surface_resolves_to_surface():
    part, sketch_feature_id = _part_with_sketch()
    surface_id = _add_surface(part, sketch_feature_id)
    mirror = MirrorFeature(id="mirror1", source_body_ids=[surface_id], mirror_plane=PlaneRef(fixed_plane=Plane.YZ))
    part.add_feature(mirror)

    assert resolve_feature_produces(mirror, part) == Produces.SURFACE


def test_mirror_of_a_solid_still_resolves_to_body_regression():
    part, sketch_feature_id = _part_with_sketch()
    extrude_id = _add_extrude(part, sketch_feature_id)
    mirror = MirrorFeature(id="mirror1", source_body_ids=[extrude_id], mirror_plane=PlaneRef(fixed_plane=Plane.YZ))
    part.add_feature(mirror)

    assert resolve_feature_produces(mirror, part) == Produces.BODY


def test_mirror_of_a_mixed_solid_and_surface_source_resolves_to_body():
    part, sketch_feature_id = _part_with_sketch()
    extrude_id = _add_extrude(part, sketch_feature_id, feature_id="ef1")
    surface_id = _add_surface(part, sketch_feature_id, feature_id="surf1")
    mirror = MirrorFeature(
        id="mirror1", source_body_ids=[extrude_id, surface_id], mirror_plane=PlaneRef(fixed_plane=Plane.YZ)
    )
    part.add_feature(mirror)

    assert resolve_feature_produces(mirror, part) == Produces.BODY


def test_mirror_of_a_mirror_of_a_surface_still_resolves_to_surface_chained():
    part, sketch_feature_id = _part_with_sketch()
    surface_id = _add_surface(part, sketch_feature_id)
    mirror1 = MirrorFeature(id="mirror1", source_body_ids=[surface_id], mirror_plane=PlaneRef(fixed_plane=Plane.YZ))
    part.add_feature(mirror1)
    mirror2 = MirrorFeature(
        id="mirror2", source_body_ids=["mirror1"], mirror_plane=PlaneRef(fixed_plane=Plane.XZ)
    )
    part.add_feature(mirror2)

    assert resolve_feature_produces(mirror2, part) == Produces.SURFACE


def test_pattern_of_a_surface_resolves_to_surface():
    part, sketch_feature_id = _part_with_sketch()
    surface_id = _add_surface(part, sketch_feature_id)
    pattern = PatternFeature(
        id="pattern1",
        source_body_ids=[surface_id],
        pattern_type=PatternType.RECTANGULAR,
        direction_1=PatternDirectionRef(fixed_axis=FixedAxis.X),
        count_1=3,
        spacing_1=20.0,
    )
    part.add_feature(pattern)

    assert resolve_feature_produces(pattern, part) == Produces.SURFACE


def test_pattern_of_a_solid_still_resolves_to_body_regression():
    part, sketch_feature_id = _part_with_sketch()
    extrude_id = _add_extrude(part, sketch_feature_id)
    pattern = PatternFeature(
        id="pattern1",
        source_body_ids=[extrude_id],
        pattern_type=PatternType.RECTANGULAR,
        direction_1=PatternDirectionRef(fixed_axis=FixedAxis.X),
        count_1=3,
        spacing_1=20.0,
    )
    part.add_feature(pattern)

    assert resolve_feature_produces(pattern, part) == Produces.BODY


def test_mirror_with_no_resolvable_source_resolves_to_body():
    part = Part(id="p1", name="Test")
    mirror = MirrorFeature(id="mirror1", source_body_ids=["missing"], mirror_plane=PlaneRef(fixed_plane=Plane.YZ))
    part.add_feature(mirror)

    assert resolve_feature_produces(mirror, part) == Produces.BODY


def test_non_mirror_pattern_feature_passes_through_its_own_produces_unchanged():
    part, sketch_feature_id = _part_with_sketch()
    surface_id = _add_surface(part, sketch_feature_id)
    surface_feature = part.get_feature(surface_id)
    assert surface_feature is not None

    assert resolve_feature_produces(surface_feature, part) == surface_feature.produces == Produces.SURFACE
