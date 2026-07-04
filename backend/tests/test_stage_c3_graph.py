"""C3: pure-Python tests for the two new app.document.graph.build_feature_
graph dependency edges - a SketchFeature anchored to a custom plane depends
on that CreatePlaneFeature, and a MIDPLANE CreatePlaneFeature depends on
*both* of its face_refs' owning ExtrudeFeatures (not just one, as OFFSET_
FACE's single face_refs entry already covered before C3). Both have zero
OCCT dependency, so - like test_stage_c2_plane_geometry.py's own graph
tests - these run for real in this sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import (
    CreatePlaneFeature,
    ExtrudeFeature,
    ExtrudeType,
    Part,
    PlaneType,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
)


def _part_with_sketch_and_extrude() -> tuple[Part, str, str]:
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    extrude = ExtrudeFeature(
        id="ef1", sketch_feature_id="sf1", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=10
    )
    part.add_feature(extrude)
    return part, sketch_feature.id, extrude.id


def test_a_sketch_feature_on_a_fixed_plane_has_no_dependencies():
    part, sketch_feature_id, _extrude_id = _part_with_sketch_and_extrude()
    nodes = build_feature_graph(part)
    sketch_node = next(n for n in nodes if n.id == sketch_feature_id)
    assert sketch_node.depends_on == ()


def test_a_sketch_feature_anchored_to_a_custom_plane_depends_on_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.FACE, index=0)],
        offset=5.0,
    )
    part.add_feature(plane)
    custom_sketch = SketchFeature(id="sf2", sketch_id="sketch-on-plane", plane_feature_id="pl1")
    part.add_feature(custom_sketch)

    nodes = build_feature_graph(part)
    custom_sketch_node = next(n for n in nodes if n.id == "sf2")
    assert custom_sketch_node.depends_on == ("pl1",)
    order = topological_order(nodes)
    assert order.index("pl1") < order.index("sf2")


def test_cascade_deleting_the_custom_plane_takes_the_sketch_anchored_to_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.FACE, index=0)],
        offset=5.0,
    )
    part.add_feature(plane)
    custom_sketch = SketchFeature(id="sf2", sketch_id="sketch-on-plane", plane_feature_id="pl1")
    part.add_feature(custom_sketch)
    downstream_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(downstream_extrude)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, "pl1") == {"pl1", "sf2", "ef2"}


def test_midplane_depends_on_both_of_its_owning_extrude_features():
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    extrude_a = ExtrudeFeature(
        id="ef1", sketch_feature_id="sf1", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=10
    )
    part.add_feature(extrude_a)
    extrude_b = ExtrudeFeature(
        id="ef2",
        sketch_feature_id="sf1",
        extrude_type=ExtrudeType.BOSS,
        start_distance=20,
        end_distance=30,
        target_body_ids=[],
    )
    part.add_feature(extrude_b)
    midplane = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.MIDPLANE,
        face_refs=[
            SubShapeRef(body_id="ef1", shape_type=SubShapeType.FACE, index=0),
            SubShapeRef(body_id="ef2", shape_type=SubShapeType.FACE, index=0),
        ],
    )
    part.add_feature(midplane)

    nodes = build_feature_graph(part)
    midplane_node = next(n for n in nodes if n.id == "pl1")
    assert set(midplane_node.depends_on) == {"ef1", "ef2"}


def test_deleting_only_one_midplane_source_extrude_takes_the_midplane_with_it():
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    extrude_a = ExtrudeFeature(
        id="ef1", sketch_feature_id="sf1", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=10
    )
    part.add_feature(extrude_a)
    extrude_b = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf1", extrude_type=ExtrudeType.BOSS, start_distance=20, end_distance=30
    )
    part.add_feature(extrude_b)
    midplane = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.MIDPLANE,
        face_refs=[
            SubShapeRef(body_id="ef1", shape_type=SubShapeType.FACE, index=0),
            SubShapeRef(body_id="ef2", shape_type=SubShapeType.FACE, index=0),
        ],
    )
    part.add_feature(midplane)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, "ef1") == {"ef1", "pl1"}
