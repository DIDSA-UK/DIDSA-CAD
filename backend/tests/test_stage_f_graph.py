"""Prompt F: pure-Python tests for `app.document.graph.build_feature_graph`'s
new `RevolveFeature` dependency edges - depends on the SketchFeature wrapping
its Profile's Sketch, the SketchFeature wrapping its `axis_ref`'s Sketch
(possibly a different Sketch - Prompt F's own confirmed decision, see
`app.document.models.RevolveFeature`'s docstring), and every `target_body_ids`
entry's owning Feature for Cut mode. Has zero OCCT dependency (mirrors every
other graph-only test file in this project, e.g. `test_stage_d_graph.py`), so
this runs for real in this sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import (
    ExtrudeFeature,
    ExtrudeType,
    Part,
    RevolveFeature,
    RevolveMode,
    SketchFeature,
)
from app.sketch.models import SketchEntityRef, SketchEntityType


def _axis_ref(sketch_id: str, entity_id: str = "line-axis") -> SketchEntityRef:
    return SketchEntityRef(sketch_id=sketch_id, entity_type=SketchEntityType.LINE, entity_id=entity_id)


def _part_with_one_sketch() -> tuple[Part, str]:
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    return part, sketch_feature.id


def test_revolve_depends_on_its_profile_sketch_feature_and_axis_sketch_feature():
    """The common case: the axis Line lives in a *different* Sketch than the
    Profile being revolved - both must contribute their own dependency
    edge."""
    part, profile_sketch_feature_id = _part_with_one_sketch()
    axis_sketch_feature = SketchFeature(id="sf2", sketch_id="sketch-axis")
    part.add_feature(axis_sketch_feature)

    revolve = RevolveFeature(
        id="rev1",
        sketch_feature_id=profile_sketch_feature_id,
        axis_ref=_axis_ref(axis_sketch_feature.sketch_id),
        angle=180.0,
        mode=RevolveMode.BOSS,
    )
    part.add_feature(revolve)

    nodes = build_feature_graph(part)
    revolve_node = next(n for n in nodes if n.id == "rev1")
    assert set(revolve_node.depends_on) == {profile_sketch_feature_id, axis_sketch_feature.id}

    order = topological_order(nodes)
    assert order.index(profile_sketch_feature_id) < order.index("rev1")
    assert order.index(axis_sketch_feature.id) < order.index("rev1")


def test_revolve_with_axis_in_the_same_sketch_as_profile_depends_on_it_once():
    """The axis Line is allowed to belong to the same Sketch as the Profile
    (including being one of the Profile's own entities - Prompt F's other
    confirmed decision) - the dependency set must not double-count this as
    two edges."""
    part, sketch_feature_id = _part_with_one_sketch()
    revolve = RevolveFeature(
        id="rev1",
        sketch_feature_id=sketch_feature_id,
        axis_ref=_axis_ref("sketch-abc"),
        angle=360.0,
        mode=RevolveMode.BOSS,
    )
    part.add_feature(revolve)

    nodes = build_feature_graph(part)
    revolve_node = next(n for n in nodes if n.id == "rev1")
    assert revolve_node.depends_on == (sketch_feature_id,)


def test_revolve_cut_depends_on_target_body_ids_owning_extrude_feature():
    part, sketch_feature_id = _part_with_one_sketch()
    extrude = ExtrudeFeature(
        id="ef1", sketch_feature_id=sketch_feature_id, extrude_type=ExtrudeType.BOSS,
        start_distance=0, end_distance=10,
    )
    part.add_feature(extrude)
    axis_sketch_feature = SketchFeature(id="sf2", sketch_id="sketch-axis")
    part.add_feature(axis_sketch_feature)

    revolve = RevolveFeature(
        id="rev1",
        sketch_feature_id=sketch_feature_id,
        axis_ref=_axis_ref(axis_sketch_feature.sketch_id),
        angle=90.0,
        mode=RevolveMode.CUT,
        target_body_ids=[extrude.id],
    )
    part.add_feature(revolve)

    nodes = build_feature_graph(part)
    revolve_node = next(n for n in nodes if n.id == "rev1")
    assert set(revolve_node.depends_on) == {sketch_feature_id, axis_sketch_feature.id, extrude.id}


def test_revolve_target_body_ids_with_a_split_body_id_depends_on_the_base_extrude_feature():
    """A `#N` split-index suffix must be stripped before the dependency edge
    is built - mirrors `test_stage_d_graph.py`'s identical Fillet case."""
    part, sketch_feature_id = _part_with_one_sketch()
    extrude = ExtrudeFeature(
        id="ef1", sketch_feature_id=sketch_feature_id, extrude_type=ExtrudeType.BOSS,
        start_distance=0, end_distance=10,
    )
    part.add_feature(extrude)

    revolve = RevolveFeature(
        id="rev1",
        sketch_feature_id=sketch_feature_id,
        axis_ref=_axis_ref("sketch-abc"),
        angle=45.0,
        mode=RevolveMode.CUT,
        target_body_ids=[f"{extrude.id}#0"],
    )
    part.add_feature(revolve)

    nodes = build_feature_graph(part)
    revolve_node = next(n for n in nodes if n.id == "rev1")
    assert set(revolve_node.depends_on) == {sketch_feature_id, extrude.id}


def test_cascade_deleting_the_profile_sketch_takes_the_revolve_with_it():
    part, sketch_feature_id = _part_with_one_sketch()
    axis_sketch_feature = SketchFeature(id="sf2", sketch_id="sketch-axis")
    part.add_feature(axis_sketch_feature)
    revolve = RevolveFeature(
        id="rev1",
        sketch_feature_id=sketch_feature_id,
        axis_ref=_axis_ref(axis_sketch_feature.sketch_id),
        angle=180.0,
        mode=RevolveMode.BOSS,
    )
    part.add_feature(revolve)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, sketch_feature_id) == {sketch_feature_id, "rev1"}


def test_cascade_deleting_the_axis_sketch_takes_the_revolve_with_it():
    """The axis Sketch is a real dependency too, not just the Profile's own
    one - deleting it must cascade the same way."""
    part, sketch_feature_id = _part_with_one_sketch()
    axis_sketch_feature = SketchFeature(id="sf2", sketch_id="sketch-axis")
    part.add_feature(axis_sketch_feature)
    revolve = RevolveFeature(
        id="rev1",
        sketch_feature_id=sketch_feature_id,
        axis_ref=_axis_ref(axis_sketch_feature.sketch_id),
        angle=180.0,
        mode=RevolveMode.BOSS,
    )
    part.add_feature(revolve)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, axis_sketch_feature.id) == {axis_sketch_feature.id, "rev1"}


def test_deleting_an_unrelated_sketch_leaves_the_revolve_alone():
    part, sketch_feature_id = _part_with_one_sketch()
    axis_sketch_feature = SketchFeature(id="sf2", sketch_id="sketch-axis")
    part.add_feature(axis_sketch_feature)
    other_sketch = SketchFeature(id="sf3", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    revolve = RevolveFeature(
        id="rev1",
        sketch_feature_id=sketch_feature_id,
        axis_ref=_axis_ref(axis_sketch_feature.sketch_id),
        angle=180.0,
        mode=RevolveMode.BOSS,
    )
    part.add_feature(revolve)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, other_sketch.id) == {other_sketch.id}
    assert "rev1" not in transitive_dependents(nodes, other_sketch.id)
