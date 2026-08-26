"""Boolean family, fourth/last entry (Split): pure-Python tests for
`app.document.graph.build_feature_graph`'s `SplitFeature` dependency edges
- mirrors test_stage_i_mirror_graph.py's shape for the `plane_ref` tool
case (a fixed plane contributing no edge, a Body face, an existing
`CreatePlaneFeature`), plus coverage for the `surface_feature_id` tool case
(a bare Feature id dependency, no `base_feature_id` mapping needed). Has
zero OCCT dependency, so this runs for real in this sandbox.
"""

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
from app.document.models import (
    CreatePlaneFeature,
    ExtrudeFeature,
    ExtrudeType,
    Part,
    PlaneRef,
    PlaneType,
    SketchFeature,
    SplitFeature,
    SplitToolRef,
    SubShapeRef,
    SubShapeType,
    SurfaceFeature,
)
from app.sketch.models import Plane, SketchEntityRef, SketchEntityType


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


def _face_ref(body_id: str, index: int) -> SubShapeRef:
    return SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=index)


def test_split_by_a_fixed_plane_depends_only_on_the_target_bodys_owning_extrude():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    split = SplitFeature(
        id="split1", target_body_id=extrude_id, tool=SplitToolRef(plane_ref=PlaneRef(fixed_plane=Plane.XY))
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    split_node = next(n for n in nodes if n.id == "split1")
    assert split_node.depends_on == (extrude_id,)
    order = topological_order(nodes)
    assert order.index(extrude_id) < order.index("split1")


def test_split_referencing_a_split_body_id_target_depends_on_the_base_extrude_feature():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    split = SplitFeature(
        id="split1",
        target_body_id=f"{extrude_id}#0",
        tool=SplitToolRef(plane_ref=PlaneRef(fixed_plane=Plane.XY)),
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    split_node = next(n for n in nodes if n.id == "split1")
    assert split_node.depends_on == (extrude_id,)


def test_split_by_a_body_face_plane_ref_also_depends_on_that_faces_owning_extrude():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    split = SplitFeature(
        id="split1",
        target_body_id=extrude_id,
        tool=SplitToolRef(plane_ref=PlaneRef(face_ref=_face_ref(other_extrude.id, 0))),
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    split_node = next(n for n in nodes if n.id == "split1")
    assert set(split_node.depends_on) == {extrude_id, other_extrude.id}


def test_split_by_an_existing_plane_feature_depends_on_that_plane_feature():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane_feature = CreatePlaneFeature(
        id="plane1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[PlaneRef(fixed_plane=Plane.XY)],
        offset=5.0,
    )
    part.add_feature(plane_feature)
    split = SplitFeature(
        id="split1", target_body_id=extrude_id, tool=SplitToolRef(plane_ref=PlaneRef(plane_feature_id="plane1"))
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    split_node = next(n for n in nodes if n.id == "split1")
    assert set(split_node.depends_on) == {extrude_id, "plane1"}


def test_split_by_a_surface_feature_depends_on_that_surface_feature_directly():
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    surface_sketch = SketchFeature(id="sf2", sketch_id="sketch-surface")
    part.add_feature(surface_sketch)
    surface = SurfaceFeature(
        id="surface1", sketch_feature_id="sf2", start_distance=-5.0, end_distance=5.0
    )
    part.add_feature(surface)
    split = SplitFeature(
        id="split1", target_body_id=extrude_id, tool=SplitToolRef(surface_feature_id="surface1")
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    split_node = next(n for n in nodes if n.id == "split1")
    assert set(split_node.depends_on) == {extrude_id, "surface1"}
    order = topological_order(nodes)
    assert order.index("surface1") < order.index("split1")
    assert order.index(sketch_feature_id) < order.index("split1")


def test_split_by_a_sketch_line_ref_depends_on_that_sketchs_owning_sketch_feature():
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    line_sketch = SketchFeature(id="sf2", sketch_id="sketch-line")
    part.add_feature(line_sketch)
    split = SplitFeature(
        id="split1",
        target_body_id=extrude_id,
        tool=SplitToolRef(
            sketch_line_ref=SketchEntityRef(
                sketch_id="sketch-line", entity_type=SketchEntityType.LINE, entity_id="line1"
            )
        ),
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    split_node = next(n for n in nodes if n.id == "split1")
    assert set(split_node.depends_on) == {extrude_id, "sf2"}
    order = topological_order(nodes)
    assert order.index("sf2") < order.index("split1")
    assert order.index(sketch_feature_id) < order.index("split1")


def test_cascade_deleting_the_target_bodys_owning_extrude_takes_the_split_with_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    split = SplitFeature(
        id="split1", target_body_id=extrude_id, tool=SplitToolRef(plane_ref=PlaneRef(fixed_plane=Plane.YZ))
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, extrude_id) == {extrude_id, "split1"}


def test_cascade_deleting_the_referenced_plane_feature_takes_the_split_with_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane_feature = CreatePlaneFeature(
        id="plane1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[PlaneRef(fixed_plane=Plane.XY)],
        offset=5.0,
    )
    part.add_feature(plane_feature)
    split = SplitFeature(
        id="split1", target_body_id=extrude_id, tool=SplitToolRef(plane_ref=PlaneRef(plane_feature_id="plane1"))
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, "plane1") == {"plane1", "split1"}


def test_cascade_deleting_the_referenced_surface_feature_takes_the_split_with_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    surface_sketch = SketchFeature(id="sf2", sketch_id="sketch-surface")
    part.add_feature(surface_sketch)
    surface = SurfaceFeature(
        id="surface1", sketch_feature_id="sf2", start_distance=-5.0, end_distance=5.0
    )
    part.add_feature(surface)
    split = SplitFeature(
        id="split1", target_body_id=extrude_id, tool=SplitToolRef(surface_feature_id="surface1")
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, "surface1") == {"surface1", "split1"}


def test_cascade_deleting_the_referenced_sketch_features_owning_feature_takes_the_split_with_it():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    line_sketch = SketchFeature(id="sf2", sketch_id="sketch-line")
    part.add_feature(line_sketch)
    split = SplitFeature(
        id="split1",
        target_body_id=extrude_id,
        tool=SplitToolRef(
            sketch_line_ref=SketchEntityRef(
                sketch_id="sketch-line", entity_type=SketchEntityType.LINE, entity_id="line1"
            )
        ),
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, "sf2") == {"sf2", "split1"}


def test_deleting_an_unrelated_extrude_leaves_the_split_alone():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    other_sketch = SketchFeature(id="sf2", sketch_id="sketch-xyz")
    part.add_feature(other_sketch)
    other_extrude = ExtrudeFeature(
        id="ef2", sketch_feature_id="sf2", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=5
    )
    part.add_feature(other_extrude)
    split = SplitFeature(
        id="split1", target_body_id=extrude_id, tool=SplitToolRef(plane_ref=PlaneRef(fixed_plane=Plane.YZ))
    )
    part.add_feature(split)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, other_extrude.id) == {other_extrude.id}
