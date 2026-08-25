"""Boolean family, first entry (Merge): pure-Python tests for `app.document.
graph.build_feature_graph`'s `MergeFeature` dependency edges - mirrors
test_stage_i_mirror_graph.py's shape, substituting `MergeFeature.body_ids`
for `MirrorFeature.source_body_ids` (no plane reference to cover - Merge has
no `mirror_plane` concept, just `body_ids`). Has zero OCCT dependency, so
this runs for real in this sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import ExtrudeFeature, ExtrudeType, MergeFeature, Part, SketchFeature


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


def test_merge_depends_on_the_owning_extrude_feature_of_every_body_id():
    part, body_id_a, body_id_b = _two_body_part()
    merge = MergeFeature(id="merge1", body_ids=[body_id_a, body_id_b])
    part.add_feature(merge)

    nodes = build_feature_graph(part)
    merge_node = next(n for n in nodes if n.id == "merge1")
    assert set(merge_node.depends_on) == {body_id_a, body_id_b}
    order = topological_order(nodes)
    assert order.index(body_id_a) < order.index("merge1")
    assert order.index(body_id_b) < order.index("merge1")


def test_merge_referencing_a_split_body_id_depends_on_the_base_extrude_feature():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    merge = MergeFeature(id="merge1", body_ids=[f"{extrude_id}#0", f"{other_extrude.id}#1"])
    part.add_feature(merge)

    nodes = build_feature_graph(part)
    merge_node = next(n for n in nodes if n.id == "merge1")
    assert set(merge_node.depends_on) == {extrude_id, other_extrude.id}


def test_merge_body_ids_owned_by_the_same_feature_dedupe_to_one_dependency():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    merge = MergeFeature(id="merge1", body_ids=[f"{extrude_id}#0", f"{extrude_id}#1"])
    part.add_feature(merge)

    nodes = build_feature_graph(part)
    merge_node = next(n for n in nodes if n.id == "merge1")
    assert merge_node.depends_on == (extrude_id,)


def test_cascade_deleting_one_merged_bodys_owning_extrude_takes_the_merge_with_it():
    part, body_id_a, body_id_b = _two_body_part()
    merge = MergeFeature(id="merge1", body_ids=[body_id_a, body_id_b])
    part.add_feature(merge)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, body_id_a) == {body_id_a, "merge1"}
    assert transitive_dependents(nodes, body_id_b) == {body_id_b, "merge1"}


def test_deleting_an_unrelated_extrude_leaves_the_merge_alone():
    part, body_id_a, body_id_b = _two_body_part()
    unrelated_sketch = SketchFeature(id="sf3", sketch_id="sketch-unrelated")
    part.add_feature(unrelated_sketch)
    unrelated_extrude = ExtrudeFeature(
        id="ef3", sketch_feature_id="sf3", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(unrelated_extrude)
    merge = MergeFeature(id="merge1", body_ids=[body_id_a, body_id_b])
    part.add_feature(merge)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, unrelated_extrude.id) == {unrelated_extrude.id}
