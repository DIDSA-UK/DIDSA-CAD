"""Prompt E: pure-Python tests for `app.document.graph.build_feature_graph`'s
`ChamferFeature` dependency edge - mirrors test_stage_d_graph.py exactly,
substituting ChamferFeature/distance for FilletFeature/radius. Has zero OCCT
dependency, so this runs for real in this sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import (
    ChamferFeature,
    ExtrudeFeature,
    ExtrudeType,
    Part,
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


def _edge_ref(body_id: str, index: int) -> SubShapeRef:
    return SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=index)


def test_chamfer_depends_on_the_owning_extrude_feature_of_its_edges():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    chamfer = ChamferFeature(
        id="chamfer1",
        edge_refs=[_edge_ref(extrude_id, 0), _edge_ref(extrude_id, 1)],
        distance=2.0,
    )
    part.add_feature(chamfer)

    nodes = build_feature_graph(part)
    chamfer_node = next(n for n in nodes if n.id == "chamfer1")
    assert chamfer_node.depends_on == (extrude_id,)
    assert topological_order(nodes).index(extrude_id) < topological_order(nodes).index("chamfer1")


def test_chamfer_referencing_a_split_body_id_depends_on_the_base_extrude_feature():
    """A `#N` split-index suffix (see `app.document.graph.base_feature_id`)
    must be stripped before the dependency edge is built - the Chamfer
    depends on the ExtrudeFeature, not the literal (possibly-suffixed) Body
    id string."""
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    chamfer = ChamferFeature(id="chamfer1", edge_refs=[_edge_ref(f"{extrude_id}#0", 0)], distance=1.0)
    part.add_feature(chamfer)

    nodes = build_feature_graph(part)
    chamfer_node = next(n for n in nodes if n.id == "chamfer1")
    assert chamfer_node.depends_on == (extrude_id,)


def test_cascade_deleting_the_extrude_takes_the_chamfer_with_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    chamfer = ChamferFeature(id="chamfer1", edge_refs=[_edge_ref(extrude_id, 0)], distance=2.0)
    part.add_feature(chamfer)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, extrude_id) == {extrude_id, "chamfer1"}


def test_deleting_an_unrelated_extrude_leaves_the_chamfer_alone():
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    chamfer = ChamferFeature(id="chamfer1", edge_refs=[_edge_ref(extrude_id, 0)], distance=2.0)
    part.add_feature(chamfer)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, other_extrude.id) == {other_extrude.id}
    assert "chamfer1" not in transitive_dependents(nodes, other_extrude.id)
    assert transitive_dependents(nodes, sketch_feature_id) == {
        sketch_feature_id,
        extrude_id,
        "chamfer1",
    }


def test_chamfer_with_edges_spanning_two_bodies_depends_on_both_owning_extrudes():
    """`build_feature_graph` itself doesn't enforce the "must be one Body"
    rule (that's `app.document.chamfer._mixed_body_selection`, an OCCT-
    resolution-time check) - it just builds whatever dependency edges the
    Feature's own refs imply, tolerating an already-invalid/hand-crafted
    Feature the same defensive way every other dependency function in this
    module does."""
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    chamfer = ChamferFeature(
        id="chamfer1",
        edge_refs=[_edge_ref(extrude_id, 0), _edge_ref(other_extrude.id, 0)],
        distance=2.0,
    )
    part.add_feature(chamfer)

    nodes = build_feature_graph(part)
    chamfer_node = next(n for n in nodes if n.id == "chamfer1")
    assert set(chamfer_node.depends_on) == {extrude_id, other_extrude.id}
