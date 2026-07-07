"""Import: pure-Python tests for `app.document.graph`'s handling of
`ImportFeature` - it has no dependency edges at all (its only "source of
truth" is the raw file bytes it already carries, not a reference to any
other Feature), so it simply falls through `build_feature_graph`'s per-type
dispatch untouched (`depends_on = ()`, the same default every unmatched
Feature type gets). Confirmed here rather than assumed, plus its cascade-
delete behavior (nothing depends on it, so deleting it alone never takes
anything else with it, and deleting some other unrelated Feature never
takes it out either). Has zero OCCT dependency, so this runs for real in
this sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import ExtrudeFeature, ExtrudeType, ImportFeature, ImportSourceFormat, Part


def test_import_feature_has_no_dependencies():
    part = Part(id="p1", name="Test")
    feature = ImportFeature(id="imp1", source_format=ImportSourceFormat.STEP, source_data=b"")
    part.add_feature(feature)

    nodes = build_feature_graph(part)
    node = next(n for n in nodes if n.id == "imp1")
    assert node.depends_on == ()


def test_import_feature_can_be_targeted_by_a_later_extrude_cut():
    part = Part(id="p1", name="Test")
    imported = ImportFeature(id="imp1", source_format=ImportSourceFormat.STEP, source_data=b"")
    part.add_feature(imported)
    cut = ExtrudeFeature(
        id="ext1",
        sketch_feature_id="sf-unused",
        extrude_type=ExtrudeType.CUT,
        start_distance=0.0,
        end_distance=10.0,
        target_body_ids=[imported.id],
    )
    part.add_feature(cut)

    nodes = build_feature_graph(part)
    cut_node = next(n for n in nodes if n.id == "ext1")
    assert imported.id in cut_node.depends_on
    assert topological_order(nodes).index("imp1") < topological_order(nodes).index("ext1")


def test_deleting_the_import_feature_alone_takes_nothing_else_with_it():
    part = Part(id="p1", name="Test")
    imported = ImportFeature(id="imp1", source_format=ImportSourceFormat.STEP, source_data=b"")
    unrelated = ImportFeature(id="imp2", source_format=ImportSourceFormat.STL, source_data=b"")
    part.add_feature(imported)
    part.add_feature(unrelated)

    dependents = transitive_dependents(build_feature_graph(part), "imp1")
    assert dependents == {"imp1"}


def test_cascade_deleting_the_import_feature_takes_a_dependent_cut_with_it():
    part = Part(id="p1", name="Test")
    imported = ImportFeature(id="imp1", source_format=ImportSourceFormat.STEP, source_data=b"")
    part.add_feature(imported)
    cut = ExtrudeFeature(
        id="ext1",
        sketch_feature_id="sf-unused",
        extrude_type=ExtrudeType.CUT,
        start_distance=0.0,
        end_distance=10.0,
        target_body_ids=[imported.id],
    )
    part.add_feature(cut)

    dependents = transitive_dependents(build_feature_graph(part), "imp1")
    assert dependents == {"imp1", "ext1"}
