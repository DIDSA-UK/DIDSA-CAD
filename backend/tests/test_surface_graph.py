"""Pure-Python tests for `app.document.graph.build_feature_graph`'s
`SurfaceFeature` dependency edges - mirrors test_stage_i_mirror_graph.py's
shape, substituting `SurfaceFeature.sketch_feature_id`/`direction_ref` for
`MirrorFeature.source_body_ids`/`mirror_plane`. Has zero OCCT dependency,
so this runs for real in this sandbox.
"""

from app.document.graph import build_feature_graph, transitive_dependents
from app.document.models import (
    ExtrudeFeature,
    ExtrudeType,
    FixedAxis,
    Part,
    PatternDirectionRef,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
    SurfaceFeature,
)
from app.sketch.models import SketchEntityRef, SketchEntityType


def _part_with_sketch_and_extrude() -> tuple[Part, str, str]:
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    extrude = ExtrudeFeature(
        id="ef1", sketch_feature_id="sf1", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=10
    )
    part.add_feature(extrude)
    return part, sketch_feature.id, extrude.id


def test_surface_with_no_direction_ref_depends_only_on_its_own_sketch_feature():
    part, sketch_feature_id, _extrude_id = _part_with_sketch_and_extrude()
    surface = SurfaceFeature(id="surf1", sketch_feature_id=sketch_feature_id, start_distance=0, end_distance=5)
    part.add_feature(surface)

    nodes = build_feature_graph(part)
    surface_node = next(n for n in nodes if n.id == "surf1")

    assert set(surface_node.depends_on) == {sketch_feature_id}


def test_surface_with_edge_ref_direction_also_depends_on_the_owning_extrude_feature_of_that_edge():
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    surface = SurfaceFeature(
        id="surf1",
        sketch_feature_id=sketch_feature_id,
        start_distance=0,
        end_distance=5,
        direction_ref=PatternDirectionRef(
            edge_ref=SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.EDGE, index=0)
        ),
    )
    part.add_feature(surface)

    nodes = build_feature_graph(part)
    surface_node = next(n for n in nodes if n.id == "surf1")

    assert set(surface_node.depends_on) == {sketch_feature_id, extrude_id}


def test_surface_with_edge_ref_direction_on_a_split_body_id_resolves_to_the_base_feature_id():
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    surface = SurfaceFeature(
        id="surf1",
        sketch_feature_id=sketch_feature_id,
        start_distance=0,
        end_distance=5,
        # A `#N`-suffixed Body id (see `app.document.extrude._register_solids`)
        # still resolves to its owning Feature via `base_feature_id`.
        direction_ref=PatternDirectionRef(
            edge_ref=SubShapeRef(body_id=f"{extrude_id}#0", shape_type=SubShapeType.EDGE, index=0)
        ),
    )
    part.add_feature(surface)

    nodes = build_feature_graph(part)
    surface_node = next(n for n in nodes if n.id == "surf1")

    assert set(surface_node.depends_on) == {sketch_feature_id, extrude_id}


def test_surface_with_sketch_line_direction_depends_on_that_sketch_line_s_own_sketch_feature():
    part, sketch_feature_id, _extrude_id = _part_with_sketch_and_extrude()
    direction_sketch = SketchFeature(id="sf2", sketch_id="sketch-direction")
    part.add_feature(direction_sketch)
    surface = SurfaceFeature(
        id="surf1",
        sketch_feature_id=sketch_feature_id,
        start_distance=0,
        end_distance=5,
        direction_ref=PatternDirectionRef(
            sketch_line_ref=SketchEntityRef(
                sketch_id="sketch-direction", entity_type=SketchEntityType.LINE, entity_id="line1"
            )
        ),
    )
    part.add_feature(surface)

    nodes = build_feature_graph(part)
    surface_node = next(n for n in nodes if n.id == "surf1")

    assert set(surface_node.depends_on) == {sketch_feature_id, "sf2"}


def test_surface_with_fixed_axis_direction_depends_on_nothing_but_its_own_sketch_feature():
    part, sketch_feature_id, _extrude_id = _part_with_sketch_and_extrude()
    surface = SurfaceFeature(
        id="surf1",
        sketch_feature_id=sketch_feature_id,
        start_distance=0,
        end_distance=5,
        direction_ref=PatternDirectionRef(fixed_axis=FixedAxis.X),
    )
    part.add_feature(surface)

    nodes = build_feature_graph(part)
    surface_node = next(n for n in nodes if n.id == "surf1")

    assert set(surface_node.depends_on) == {sketch_feature_id}


def test_deleting_the_backing_sketch_feature_cascades_to_the_surface_feature():
    """B2: `transitive_dependents` is what `DELETE .../cascade` actually
    walks (see test_stage_b2_cascade.py's own real-HTTP equivalent) - this
    is the pure-graph half of the same guarantee: deleting the SketchFeature
    a Surface extrudes must pull the Surface (and anything between them,
    here a normal Extrude Body sharing the same Sketch) into the same
    cascade, exactly like every other Sketch-profile-backed Feature type."""
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    surface = SurfaceFeature(id="surf1", sketch_feature_id=sketch_feature_id, start_distance=0, end_distance=5)
    part.add_feature(surface)

    nodes = build_feature_graph(part)
    deleted = transitive_dependents(nodes, sketch_feature_id)

    assert deleted == {sketch_feature_id, extrude_id, "surf1"}


def test_deleting_an_unrelated_feature_does_not_cascade_to_the_surface_feature():
    part, sketch_feature_id, _extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-other")
    part.add_feature(other_sketch)
    surface = SurfaceFeature(id="surf1", sketch_feature_id=sketch_feature_id, start_distance=0, end_distance=5)
    part.add_feature(surface)

    nodes = build_feature_graph(part)
    deleted = transitive_dependents(nodes, "sf2")

    assert deleted == {"sf2"}
