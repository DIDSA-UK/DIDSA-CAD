"""C5: pure-Python tests for `app.document.graph.build_feature_graph`'s
handling of the two new `PlaneRef` kinds a `CreatePlaneFeature.face_refs`
entry can now be (see `app.document.models.PlaneRef`) - a fixed reference
plane (XY/XZ/YZ), which contributes no dependency edge at all, and an
existing `CreatePlaneFeature` (`plane_feature_id`), which contributes a
direct edge to that Feature. The third kind (`face_ref`, a Body face) is
already covered by test_stage_c2_plane_geometry.py/test_stage_c3_graph.py's
existing OFFSET_FACE/MIDPLANE tests - unaffected by C5 other than the
`SubShapeRef` wrapping change those files already picked up. All of this
has zero OCCT dependency, so - like those files' own graph tests - these
run for real in this sandbox.
"""

from app.document.graph import build_feature_graph, transitive_dependents
from app.document.models import (
    CreatePlaneFeature,
    ExtrudeFeature,
    ExtrudeType,
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


def test_offset_face_on_a_fixed_plane_has_no_dependencies():
    part = Part(id="p1", name="Test")
    plane = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[PlaneRef(fixed_plane=Plane.XY)],
        offset=5.0,
    )
    part.add_feature(plane)

    nodes = build_feature_graph(part)
    plane_node = next(n for n in nodes if n.id == "pl1")
    assert plane_node.depends_on == ()


def test_midplane_between_an_existing_plane_and_a_face_depends_on_both():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    base_plane = CreatePlaneFeature(
        id="pl1", plane_type=PlaneType.OFFSET_FACE, face_refs=[PlaneRef(fixed_plane=Plane.XY)], offset=1.0
    )
    part.add_feature(base_plane)
    midplane = CreatePlaneFeature(
        id="pl2",
        plane_type=PlaneType.MIDPLANE,
        face_refs=[
            PlaneRef(plane_feature_id="pl1"),
            PlaneRef(face_ref=SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.FACE, index=0)),
        ],
    )
    part.add_feature(midplane)

    nodes = build_feature_graph(part)
    midplane_node = next(n for n in nodes if n.id == "pl2")
    assert set(midplane_node.depends_on) == {"pl1", extrude_id}


def test_cascade_deleting_a_plane_feature_takes_a_midplane_anchored_to_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    base_plane = CreatePlaneFeature(
        id="pl1", plane_type=PlaneType.OFFSET_FACE, face_refs=[PlaneRef(fixed_plane=Plane.XY)], offset=1.0
    )
    part.add_feature(base_plane)
    midplane = CreatePlaneFeature(
        id="pl2",
        plane_type=PlaneType.MIDPLANE,
        face_refs=[
            PlaneRef(plane_feature_id="pl1"),
            PlaneRef(face_ref=SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.FACE, index=0)),
        ],
    )
    part.add_feature(midplane)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, "pl1") == {"pl1", "pl2"}


def test_parallel_to_face_through_vertex_on_a_fixed_plane_depends_only_on_the_vertexs_body():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.PARALLEL_TO_FACE_THROUGH_VERTEX,
        face_refs=[PlaneRef(fixed_plane=Plane.XZ)],
        vertex_ref=SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.VERTEX, index=0),
    )
    part.add_feature(plane)

    nodes = build_feature_graph(part)
    plane_node = next(n for n in nodes if n.id == "pl1")
    assert plane_node.depends_on == (extrude_id,)
