"""A1: pure-Python tests for app.document.graph's topological sort - no
OCCT/pythonocc-core import anywhere in this file (unlike every other test
file under backend/tests), so these run in any Python 3.11 environment,
not just the real OCCT Docker image."""

import pytest

from app.document.graph import CycleError, GraphNode, topological_order


def test_empty_graph_returns_empty_order():
    assert topological_order([]) == []


def test_single_node_with_no_dependencies():
    assert topological_order([GraphNode(id="a")]) == ["a"]


def test_linear_chain_preserves_dependency_order():
    nodes = [
        GraphNode(id="a"),
        GraphNode(id="b", depends_on=("a",)),
        GraphNode(id="c", depends_on=("b",)),
    ]
    assert topological_order(nodes) == ["a", "b", "c"]


def test_independent_nodes_keep_original_input_order():
    """No edges at all between these three - the old list-order-driven
    recompute this replaces must be reproduced exactly for every part with
    no cross-referencing edges (A1's regression requirement)."""
    nodes = [GraphNode(id="c"), GraphNode(id="a"), GraphNode(id="b")]
    assert topological_order(nodes) == ["c", "a", "b"]


def test_list_order_preserved_even_with_a_far_back_dependency_edge():
    """A Feature can depend on something much earlier than the Feature
    immediately before it (e.g. a Cut's target_body_ids naming a Body from
    several Features back) without disturbing the order of everything
    else - this is the whole point of moving off pure list order."""
    nodes = [
        GraphNode(id="a"),
        GraphNode(id="b"),
        GraphNode(id="c"),
        GraphNode(id="d", depends_on=("a",)),
    ]
    assert topological_order(nodes) == ["a", "b", "c", "d"]


def test_dependency_reordering_when_a_later_node_is_required_first():
    """If a node only becomes ready once a much-earlier node in the input
    list finishes, it still can't run before its dependency - even though
    nothing else in the graph forces that ordering directly."""
    nodes = [
        GraphNode(id="a", depends_on=("b",)),
        GraphNode(id="b"),
    ]
    assert topological_order(nodes) == ["b", "a"]


def test_diamond_dependency_resolves_deterministically():
    nodes = [
        GraphNode(id="a"),
        GraphNode(id="b", depends_on=("a",)),
        GraphNode(id="c", depends_on=("a",)),
        GraphNode(id="d", depends_on=("b", "c")),
    ]
    assert topological_order(nodes) == ["a", "b", "c", "d"]


def test_dependency_on_unknown_id_is_ignored_not_an_error():
    nodes = [GraphNode(id="a", depends_on=("does-not-exist",))]
    assert topological_order(nodes) == ["a"]


def test_duplicate_dependency_ids_do_not_break_the_count():
    nodes = [
        GraphNode(id="a"),
        GraphNode(id="b", depends_on=("a", "a", "a")),
    ]
    assert topological_order(nodes) == ["a", "b"]


def test_self_dependency_is_ignored_not_a_cycle():
    nodes = [GraphNode(id="a", depends_on=("a",))]
    assert topological_order(nodes) == ["a"]


def test_direct_cycle_raises_cycle_error():
    nodes = [
        GraphNode(id="a", depends_on=("b",)),
        GraphNode(id="b", depends_on=("a",)),
    ]
    with pytest.raises(CycleError):
        topological_order(nodes)


def test_longer_cycle_raises_cycle_error():
    nodes = [
        GraphNode(id="a", depends_on=("c",)),
        GraphNode(id="b", depends_on=("a",)),
        GraphNode(id="c", depends_on=("b",)),
    ]
    with pytest.raises(CycleError):
        topological_order(nodes)


def test_merge_style_fan_in_and_fan_out_stays_stable_and_ordered():
    """Mirrors the real-world Boss/Cut/target_body_ids shape: two
    body-creating Boss features (independent), a third Boss that fuses
    them (depends on both), and a Cut against the merged result (depends
    only on the fuse feature) - listed slightly out of dependency order to
    confirm the sort actually reorders when it must, while everything with
    no ordering constraint keeps its original relative position."""
    nodes = [
        GraphNode(id="sketch1"),
        GraphNode(id="boss1", depends_on=("sketch1",)),
        GraphNode(id="sketch2"),
        GraphNode(id="boss2", depends_on=("sketch2",)),
        GraphNode(id="sketch3"),
        GraphNode(id="fuse", depends_on=("sketch3", "boss1", "boss2")),
        GraphNode(id="sketch4"),
        GraphNode(id="cut", depends_on=("sketch4", "fuse")),
    ]
    order = topological_order(nodes)
    assert order == [
        "sketch1",
        "boss1",
        "sketch2",
        "boss2",
        "sketch3",
        "fuse",
        "sketch4",
        "cut",
    ]
