"""Sweep: pure-Python tests for `app.document.graph.build_feature_graph`'s
new `SweepFeature` dependency edges - depends on the SketchFeature wrapping
its Profile's Sketch, the SketchFeature wrapping *every* distinct Sketch
named across `path_refs` (each entry may name a different Sketch - Sweep's
own confirmed decision, see `app.document.models.SweepFeature`'s docstring),
and every `target_body_ids` entry's owning Feature for Cut mode. Has zero
OCCT dependency (mirrors `test_stage_f_graph.py`'s identical Revolve
coverage), so this runs for real in this sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import (
    ExtrudeFeature,
    ExtrudeType,
    Part,
    SketchFeature,
    SweepFeature,
    SweepMode,
)
from app.sketch.models import SketchEntityRef, SketchEntityType


def _path_ref(sketch_id: str, entity_id: str) -> SketchEntityRef:
    return SketchEntityRef(sketch_id=sketch_id, entity_type=SketchEntityType.LINE, entity_id=entity_id)


def _part_with_one_sketch() -> tuple[Part, str]:
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    return part, sketch_feature.id


def test_sweep_depends_on_its_profile_sketch_feature_and_every_path_sketch_feature():
    """The common case: each path segment lives in its own, different
    Sketch than the Profile being swept - every one must contribute its own
    dependency edge."""
    part, profile_sketch_feature_id = _part_with_one_sketch()
    path_sketch_a = SketchFeature(id="sf2", sketch_id="sketch-path-a")
    path_sketch_b = SketchFeature(id="sf3", sketch_id="sketch-path-b")
    part.add_feature(path_sketch_a)
    part.add_feature(path_sketch_b)

    sweep = SweepFeature(
        id="sw1",
        sketch_feature_id=profile_sketch_feature_id,
        path_refs=[
            _path_ref(path_sketch_a.sketch_id, "line-a"),
            _path_ref(path_sketch_b.sketch_id, "line-b"),
        ],
        mode=SweepMode.BOSS,
    )
    part.add_feature(sweep)

    nodes = build_feature_graph(part)
    sweep_node = next(n for n in nodes if n.id == "sw1")
    assert set(sweep_node.depends_on) == {
        profile_sketch_feature_id,
        path_sketch_a.id,
        path_sketch_b.id,
    }

    order = topological_order(nodes)
    assert order.index(profile_sketch_feature_id) < order.index("sw1")
    assert order.index(path_sketch_a.id) < order.index("sw1")
    assert order.index(path_sketch_b.id) < order.index("sw1")


def test_sweep_with_every_path_segment_in_the_same_sketch_as_profile_depends_on_it_once():
    """Every path segment is allowed to belong to the same Sketch as the
    Profile (including being one of the Profile's own entities) - the
    dependency set must not double-count this as multiple edges."""
    part, sketch_feature_id = _part_with_one_sketch()
    sweep = SweepFeature(
        id="sw1",
        sketch_feature_id=sketch_feature_id,
        path_refs=[
            _path_ref("sketch-abc", "line-1"),
            _path_ref("sketch-abc", "line-2"),
        ],
        mode=SweepMode.BOSS,
    )
    part.add_feature(sweep)

    nodes = build_feature_graph(part)
    sweep_node = next(n for n in nodes if n.id == "sw1")
    assert sweep_node.depends_on == (sketch_feature_id,)


def test_sweep_cut_depends_on_target_body_ids_owning_extrude_feature():
    part, sketch_feature_id = _part_with_one_sketch()
    extrude = ExtrudeFeature(
        id="ef1", sketch_feature_id=sketch_feature_id, extrude_type=ExtrudeType.BOSS,
        start_distance=0, end_distance=10,
    )
    part.add_feature(extrude)
    path_sketch = SketchFeature(id="sf2", sketch_id="sketch-path")
    part.add_feature(path_sketch)

    sweep = SweepFeature(
        id="sw1",
        sketch_feature_id=sketch_feature_id,
        path_refs=[_path_ref(path_sketch.sketch_id, "line-1")],
        mode=SweepMode.CUT,
        target_body_ids=[extrude.id],
    )
    part.add_feature(sweep)

    nodes = build_feature_graph(part)
    sweep_node = next(n for n in nodes if n.id == "sw1")
    assert set(sweep_node.depends_on) == {sketch_feature_id, path_sketch.id, extrude.id}


def test_sweep_target_body_ids_with_a_split_body_id_depends_on_the_base_extrude_feature():
    """A `#N` split-index suffix must be stripped before the dependency edge
    is built - mirrors `test_stage_f_graph.py`'s identical Revolve case."""
    part, sketch_feature_id = _part_with_one_sketch()
    extrude = ExtrudeFeature(
        id="ef1", sketch_feature_id=sketch_feature_id, extrude_type=ExtrudeType.BOSS,
        start_distance=0, end_distance=10,
    )
    part.add_feature(extrude)

    sweep = SweepFeature(
        id="sw1",
        sketch_feature_id=sketch_feature_id,
        path_refs=[_path_ref("sketch-abc", "line-1")],
        mode=SweepMode.CUT,
        target_body_ids=[f"{extrude.id}#0"],
    )
    part.add_feature(sweep)

    nodes = build_feature_graph(part)
    sweep_node = next(n for n in nodes if n.id == "sw1")
    assert set(sweep_node.depends_on) == {sketch_feature_id, extrude.id}


def test_cascade_deleting_the_profile_sketch_takes_the_sweep_with_it():
    part, sketch_feature_id = _part_with_one_sketch()
    path_sketch = SketchFeature(id="sf2", sketch_id="sketch-path")
    part.add_feature(path_sketch)
    sweep = SweepFeature(
        id="sw1",
        sketch_feature_id=sketch_feature_id,
        path_refs=[_path_ref(path_sketch.sketch_id, "line-1")],
        mode=SweepMode.BOSS,
    )
    part.add_feature(sweep)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, sketch_feature_id) == {sketch_feature_id, "sw1"}


def test_cascade_deleting_any_path_sketch_takes_the_sweep_with_it():
    """Every path Sketch is a real dependency, not just the Profile's own
    one - deleting any one of them must cascade the same way."""
    part, sketch_feature_id = _part_with_one_sketch()
    path_sketch_a = SketchFeature(id="sf2", sketch_id="sketch-path-a")
    path_sketch_b = SketchFeature(id="sf3", sketch_id="sketch-path-b")
    part.add_feature(path_sketch_a)
    part.add_feature(path_sketch_b)
    sweep = SweepFeature(
        id="sw1",
        sketch_feature_id=sketch_feature_id,
        path_refs=[
            _path_ref(path_sketch_a.sketch_id, "line-a"),
            _path_ref(path_sketch_b.sketch_id, "line-b"),
        ],
        mode=SweepMode.BOSS,
    )
    part.add_feature(sweep)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, path_sketch_a.id) == {path_sketch_a.id, "sw1"}
    assert transitive_dependents(nodes, path_sketch_b.id) == {path_sketch_b.id, "sw1"}


def test_deleting_an_unrelated_sketch_leaves_the_sweep_alone():
    part, sketch_feature_id = _part_with_one_sketch()
    path_sketch = SketchFeature(id="sf2", sketch_id="sketch-path")
    part.add_feature(path_sketch)
    other_sketch = SketchFeature(id="sf3", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    sweep = SweepFeature(
        id="sw1",
        sketch_feature_id=sketch_feature_id,
        path_refs=[_path_ref(path_sketch.sketch_id, "line-1")],
        mode=SweepMode.BOSS,
    )
    part.add_feature(sweep)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, other_sketch.id) == {other_sketch.id}
    assert "sw1" not in transitive_dependents(nodes, other_sketch.id)
