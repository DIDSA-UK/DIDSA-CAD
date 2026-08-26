"""Boolean family, Subtract/Common: pure-Python tests for `app.document.
graph.build_feature_graph`'s `BooleanFeature` dependency edges - mirrors
test_stage_q_merge_graph.py's shape, substituting `BooleanFeature.target_
body_ids`/`tool_body_ids` (both, deduplicated together) for `MergeFeature.
body_ids`. Has zero OCCT dependency, so this runs for real in this
sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import (
    BooleanFeature,
    BooleanOperation,
    ExtrudeFeature,
    ExtrudeType,
    Part,
    SketchFeature,
)


def _part_with_sketch_and_extrude(sketch_id: str = "sf1", extrude_id: str = "ef1") -> tuple[Part, str, str]:
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id=sketch_id, sketch_id=f"sketch-{sketch_id}")
    part.add_feature(sketch_feature)
    extrude = ExtrudeFeature(
        id=extrude_id,
        sketch_feature_id=sketch_id,
        extrude_type=ExtrudeType.BOSS,
        start_distance=0,
        end_distance=10,
    )
    part.add_feature(extrude)
    return part, sketch_feature.id, extrude.id


def _two_body_part() -> tuple[Part, str, str]:
    part, _sketch_a, extrude_a = _part_with_sketch_and_extrude("sf1", "ef1")
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    return part, extrude_a, other_extrude.id


def test_boolean_depends_on_the_owning_extrude_feature_of_every_target_and_tool_body_id():
    part, target_id, tool_id = _two_body_part()
    boolean = BooleanFeature(
        id="bool1",
        operation=BooleanOperation.SUBTRACT,
        target_body_ids=[target_id],
        tool_body_ids=[tool_id],
    )
    part.add_feature(boolean)

    nodes = build_feature_graph(part)
    boolean_node = next(n for n in nodes if n.id == "bool1")
    assert set(boolean_node.depends_on) == {target_id, tool_id}
    order = topological_order(nodes)
    assert order.index(target_id) < order.index("bool1")
    assert order.index(tool_id) < order.index("bool1")


def test_boolean_referencing_split_body_ids_depends_on_the_base_extrude_features():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    boolean = BooleanFeature(
        id="bool1",
        operation=BooleanOperation.COMMON,
        target_body_ids=[f"{extrude_id}#0"],
        tool_body_ids=[f"{other_extrude.id}#1"],
    )
    part.add_feature(boolean)

    nodes = build_feature_graph(part)
    boolean_node = next(n for n in nodes if n.id == "bool1")
    assert set(boolean_node.depends_on) == {extrude_id, other_extrude.id}


def test_boolean_target_and_tool_owned_by_the_same_feature_dedupe_to_one_dependency():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    boolean = BooleanFeature(
        id="bool1",
        operation=BooleanOperation.SUBTRACT,
        target_body_ids=[f"{extrude_id}#0"],
        tool_body_ids=[f"{extrude_id}#1"],
    )
    part.add_feature(boolean)

    nodes = build_feature_graph(part)
    boolean_node = next(n for n in nodes if n.id == "bool1")
    assert boolean_node.depends_on == (extrude_id,)


def test_cascade_deleting_the_target_bodys_owning_extrude_takes_the_boolean_with_it():
    part, target_id, tool_id = _two_body_part()
    boolean = BooleanFeature(
        id="bool1", operation=BooleanOperation.SUBTRACT, target_body_ids=[target_id], tool_body_ids=[tool_id]
    )
    part.add_feature(boolean)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, target_id) == {target_id, "bool1"}


def test_cascade_deleting_the_tool_bodys_owning_extrude_takes_the_boolean_with_it():
    part, target_id, tool_id = _two_body_part()
    boolean = BooleanFeature(
        id="bool1", operation=BooleanOperation.SUBTRACT, target_body_ids=[target_id], tool_body_ids=[tool_id]
    )
    part.add_feature(boolean)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, tool_id) == {tool_id, "bool1"}


def test_deleting_an_unrelated_extrude_leaves_the_boolean_alone():
    part, target_id, tool_id = _two_body_part()
    unrelated_sketch = SketchFeature(id="sf3", sketch_id="sketch-unrelated")
    part.add_feature(unrelated_sketch)
    unrelated_extrude = ExtrudeFeature(
        id="ef3", sketch_feature_id="sf3", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(unrelated_extrude)
    boolean = BooleanFeature(
        id="bool1", operation=BooleanOperation.SUBTRACT, target_body_ids=[target_id], tool_body_ids=[tool_id]
    )
    part.add_feature(boolean)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, unrelated_extrude.id) == {unrelated_extrude.id}
