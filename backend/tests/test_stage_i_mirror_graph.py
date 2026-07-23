"""Pattern/Mirror scoping's Phase 1 (`docs/pattern-mirror-scope.md` §2.1/§4):
pure-Python tests for `app.document.graph.build_feature_graph`'s
`MirrorFeature` dependency edges - mirrors test_stage_e_graph.py's shape,
substituting `MirrorFeature.source_body_ids`/`mirror_plane` for
`ChamferFeature.edge_refs`, plus coverage for the `mirror_plane` reference
(a fixed plane contributing no edge, a Body face, and an existing
`CreatePlaneFeature`). Has zero OCCT dependency, so this runs for real in
this sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import (
    CreatePlaneFeature,
    ExtrudeFeature,
    ExtrudeType,
    MirrorFeature,
    Part,
    PlaneRef,
    PlaneType,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
)
from app.sketch.models import Plane


def _part_with_sketch_and_extrude() -> tuple[Part, str, str]:
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    extrude = ExtrudeFeature(
        id="ef1", sketch_feature_id="sf1", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=10
    )
    part.add_feature(extrude)
    return part, sketch_feature.id, extrude.id


def _face_ref(body_id: str, index: int) -> SubShapeRef:
    return SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=index)


def test_mirror_depends_on_the_owning_extrude_feature_of_its_source_body_and_nothing_else_for_a_fixed_plane():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    mirror = MirrorFeature(
        id="mirror1", source_body_ids=[extrude_id], mirror_plane=PlaneRef(fixed_plane=Plane.YZ)
    )
    part.add_feature(mirror)

    nodes = build_feature_graph(part)
    mirror_node = next(n for n in nodes if n.id == "mirror1")
    assert mirror_node.depends_on == (extrude_id,)
    assert topological_order(nodes).index(extrude_id) < topological_order(nodes).index("mirror1")


def test_mirror_referencing_a_split_body_id_depends_on_the_base_extrude_feature():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    mirror = MirrorFeature(
        id="mirror1", source_body_ids=[f"{extrude_id}#0"], mirror_plane=PlaneRef(fixed_plane=Plane.XZ)
    )
    part.add_feature(mirror)

    nodes = build_feature_graph(part)
    mirror_node = next(n for n in nodes if n.id == "mirror1")
    assert mirror_node.depends_on == (extrude_id,)


def test_mirror_about_a_body_face_also_depends_on_that_faces_owning_extrude():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    mirror = MirrorFeature(
        id="mirror1",
        source_body_ids=[extrude_id],
        mirror_plane=PlaneRef(face_ref=_face_ref(other_extrude.id, 0)),
    )
    part.add_feature(mirror)

    nodes = build_feature_graph(part)
    mirror_node = next(n for n in nodes if n.id == "mirror1")
    assert set(mirror_node.depends_on) == {extrude_id, other_extrude.id}


def test_mirror_about_an_existing_plane_feature_depends_on_that_plane_feature():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane_feature = CreatePlaneFeature(
        id="plane1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[PlaneRef(fixed_plane=Plane.XY)],
        offset=5.0,
    )
    part.add_feature(plane_feature)
    mirror = MirrorFeature(
        id="mirror1", source_body_ids=[extrude_id], mirror_plane=PlaneRef(plane_feature_id="plane1")
    )
    part.add_feature(mirror)

    nodes = build_feature_graph(part)
    mirror_node = next(n for n in nodes if n.id == "mirror1")
    assert set(mirror_node.depends_on) == {extrude_id, "plane1"}


def test_cascade_deleting_the_source_extrude_takes_the_mirror_with_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    mirror = MirrorFeature(
        id="mirror1", source_body_ids=[extrude_id], mirror_plane=PlaneRef(fixed_plane=Plane.YZ)
    )
    part.add_feature(mirror)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, extrude_id) == {extrude_id, "mirror1"}


def test_cascade_deleting_the_referenced_plane_feature_takes_the_mirror_with_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane_feature = CreatePlaneFeature(
        id="plane1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[PlaneRef(fixed_plane=Plane.XY)],
        offset=5.0,
    )
    part.add_feature(plane_feature)
    mirror = MirrorFeature(
        id="mirror1", source_body_ids=[extrude_id], mirror_plane=PlaneRef(plane_feature_id="plane1")
    )
    part.add_feature(mirror)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, "plane1") == {"plane1", "mirror1"}


def test_deleting_an_unrelated_extrude_leaves_the_mirror_alone():
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    mirror = MirrorFeature(
        id="mirror1", source_body_ids=[extrude_id], mirror_plane=PlaneRef(fixed_plane=Plane.YZ)
    )
    part.add_feature(mirror)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, other_extrude.id) == {other_extrude.id}
    assert transitive_dependents(nodes, sketch_feature_id) == {sketch_feature_id, extrude_id, "mirror1"}
