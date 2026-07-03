"""B2: graph-aware cascade delete - the actual dependency-graph walk
(`app.document.graph.transitive_dependents`), plus `build_feature_graph`/
`base_feature_id` now that they live alongside it. All of this is pure
Python with zero OCCT/pythonocc-core dependency (same as
test_stage_a1_graph.py's `topological_order` tests) - genuinely executed in
this sandbox, unlike almost everything else B2 touches (the `/cascade`
endpoint itself needs a real Part with real Sketches, so its end-to-end
tests live in test_stage_b2_cascade.py and need real OCCT).
"""

from app.document.graph import GraphNode, build_feature_graph, transitive_dependents
from app.document.models import ExtrudeFeature, ExtrudeType, Part, SketchFeature

# --- Direct GraphNode-level tests (mirrors test_stage_a1_graph.py's own style)


def test_a_node_with_no_dependents_deletes_only_itself():
    nodes = [GraphNode(id="a"), GraphNode(id="b", depends_on=("a",))]

    assert transitive_dependents(nodes, "b") == {"b"}


def test_deleting_a_shared_root_takes_every_dependent_with_it():
    nodes = [
        GraphNode(id="root"),
        GraphNode(id="child1", depends_on=("root",)),
        GraphNode(id="child2", depends_on=("root",)),
    ]

    assert transitive_dependents(nodes, "root") == {"root", "child1", "child2"}


def test_deleting_one_sibling_leaves_the_root_and_other_sibling_untouched():
    nodes = [
        GraphNode(id="root"),
        GraphNode(id="child1", depends_on=("root",)),
        GraphNode(id="child2", depends_on=("root",)),
    ]

    assert transitive_dependents(nodes, "child1") == {"child1"}


def test_cascades_transitively_through_a_multi_step_chain():
    nodes = [
        GraphNode(id="a"),
        GraphNode(id="b", depends_on=("a",)),
        GraphNode(id="c", depends_on=("b",)),
        GraphNode(id="d", depends_on=("c",)),
    ]

    assert transitive_dependents(nodes, "a") == {"a", "b", "c", "d"}
    assert transitive_dependents(nodes, "c") == {"c", "d"}


def test_diamond_dependency_deletes_the_whole_diamond_from_the_root():
    nodes = [
        GraphNode(id="root"),
        GraphNode(id="left", depends_on=("root",)),
        GraphNode(id="right", depends_on=("root",)),
        GraphNode(id="join", depends_on=("left", "right")),
    ]

    assert transitive_dependents(nodes, "root") == {"root", "left", "right", "join"}


def test_diamond_dependency_deleting_one_side_takes_the_join_but_not_the_other_side():
    nodes = [
        GraphNode(id="root"),
        GraphNode(id="left", depends_on=("root",)),
        GraphNode(id="right", depends_on=("root",)),
        GraphNode(id="join", depends_on=("left", "right")),
    ]

    assert transitive_dependents(nodes, "left") == {"left", "join"}


def test_unrelated_branches_are_untouched_by_each_others_cascade():
    nodes = [
        GraphNode(id="a1"),
        GraphNode(id="a2", depends_on=("a1",)),
        GraphNode(id="b1"),
        GraphNode(id="b2", depends_on=("b1",)),
    ]

    assert transitive_dependents(nodes, "a1") == {"a1", "a2"}
    assert transitive_dependents(nodes, "b1") == {"b1", "b2"}


def test_unknown_feature_id_returns_an_empty_set():
    nodes = [GraphNode(id="a"), GraphNode(id="b", depends_on=("a",))]

    assert transitive_dependents(nodes, "does-not-exist") == set()


def test_a_diamond_with_a_shared_dependency_that_survives_a_lower_delete():
    """The `join` node depends on both `left` and `right` - deleting `right`
    alone still takes `join` with it (join can no longer exist without one
    of its two dependencies), but `left` itself survives untouched, mirroring
    a Boss/Cut whose `target_body_ids` names 2+ bodies where only one is
    later removed."""
    nodes = [
        GraphNode(id="root"),
        GraphNode(id="left", depends_on=("root",)),
        GraphNode(id="right", depends_on=("root",)),
        GraphNode(id="join", depends_on=("left", "right")),
    ]

    result = transitive_dependents(nodes, "right")

    assert result == {"right", "join"}
    assert "left" not in result


# --- build_feature_graph against real Feature dataclasses, feeding straight
# --- into transitive_dependents - proves the two functions this prompt
# --- moved into graph.py actually integrate correctly, still with zero OCCT.


def _boss(feature_id: str, sketch_feature_id: str, target_body_ids: list[str] | None = None):
    return ExtrudeFeature(
        id=feature_id,
        sketch_feature_id=sketch_feature_id,
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=10.0,
        target_body_ids=target_body_ids or [],
    )


def _cut(feature_id: str, sketch_feature_id: str, target_body_ids: list[str]):
    return ExtrudeFeature(
        id=feature_id,
        sketch_feature_id=sketch_feature_id,
        extrude_type=ExtrudeType.CUT,
        start_distance=0.0,
        end_distance=10.0,
        target_body_ids=target_body_ids,
    )


def test_deleting_a_shared_sketch_removes_both_dependent_extrudes():
    """B2's own headline scenario: a Sketch feeding two independent
    Extrudes - deleting the Sketch must delete both Extrudes (and anything
    downstream of either)."""
    part = Part(id="p", name="Part 1")
    sketch = SketchFeature(id="sketch", sketch_id="s1")
    extrude_a = _boss("extrude-a", "sketch")
    extrude_b = _boss("extrude-b", "sketch")
    part.add_feature(sketch)
    part.add_feature(extrude_a)
    part.add_feature(extrude_b)

    to_delete = transitive_dependents(build_feature_graph(part), "sketch")

    assert to_delete == {"sketch", "extrude-a", "extrude-b"}


def test_deleting_one_of_two_sibling_extrudes_off_a_shared_sketch_leaves_the_other_alone():
    part = Part(id="p", name="Part 1")
    sketch = SketchFeature(id="sketch", sketch_id="s1")
    extrude_a = _boss("extrude-a", "sketch")
    extrude_b = _boss("extrude-b", "sketch")
    part.add_feature(sketch)
    part.add_feature(extrude_a)
    part.add_feature(extrude_b)

    to_delete = transitive_dependents(build_feature_graph(part), "extrude-a")

    assert to_delete == {"extrude-a"}


def test_deleting_a_leaf_feature_removes_only_itself():
    part = Part(id="p", name="Part 1")
    sketch = SketchFeature(id="sketch", sketch_id="s1")
    boss = _boss("boss", "sketch")
    cut = _cut("cut", "sketch", target_body_ids=["boss"])
    part.add_feature(sketch)
    part.add_feature(boss)
    part.add_feature(cut)

    to_delete = transitive_dependents(build_feature_graph(part), "cut")

    assert to_delete == {"cut"}


def test_deleting_an_upstream_boss_cascades_through_a_target_body_ids_chain():
    """A Boss that later Extrudes target via `target_body_ids` (not just
    `sketch_feature_id`) is exactly the "far-back dependency" edge A1
    introduced - deleting it must cascade through that chain too, not just
    through sketch references."""
    part = Part(id="p", name="Part 1")
    sketch = SketchFeature(id="sketch", sketch_id="s1")
    boss = _boss("boss", "sketch")
    cut = _cut("cut", "sketch", target_body_ids=["boss"])
    later_boss = _boss("later-boss", "sketch", target_body_ids=["boss"])
    part.add_feature(sketch)
    part.add_feature(boss)
    part.add_feature(cut)
    part.add_feature(later_boss)

    to_delete = transitive_dependents(build_feature_graph(part), "boss")

    assert to_delete == {"boss", "cut", "later-boss"}


def test_independent_sketches_do_not_cascade_into_each_other():
    """Three unrelated SketchFeatures share no dependency edges at all -
    deleting one must never touch the others, unlike the pre-B2 "everything
    after it in the list" behaviour."""
    part = Part(id="p", name="Part 1")
    first = SketchFeature(id="first", sketch_id="s1")
    second = SketchFeature(id="second", sketch_id="s2")
    third = SketchFeature(id="third", sketch_id="s3")
    part.add_feature(first)
    part.add_feature(second)
    part.add_feature(third)

    to_delete = transitive_dependents(build_feature_graph(part), "first")

    assert to_delete == {"first"}
