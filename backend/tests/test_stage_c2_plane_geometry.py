"""C2: pure-Python tests for Create Plane's NORMAL_TO_LINE_AT_POINT math
(app.document.plane_geometry) and the new CreatePlaneFeature dependency-
graph edges (app.document.graph.build_feature_graph) - both have zero OCCT
dependency, so unlike the OFFSET_FACE half of this prompt (see
test_stage_c2_create_plane.py, which needs a real OCCT environment), these
run for real in this sandbox.
"""

import math

import pytest
from fastapi import HTTPException

from app.document.graph import build_feature_graph, topological_order, transitive_dependents
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
from app.document.plane_geometry import resolve_normal_to_line_at_point, sketch_basis_for_plane
from app.sketch.models import Plane, SketchEntityRef, SketchEntityType
from app.sketch.store import create_sketch


def _line_and_point_refs(sketch, line, point_id):
    return (
        SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.LINE, entity_id=line.id),
        SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=point_id),
    )


# --- resolve_normal_to_line_at_point ----------------------------------------


def test_resolves_a_horizontal_line_normal_along_x_at_its_start_point():
    sketch = create_sketch(Plane.XY)
    start = sketch.add_point(0.0, 0.0)
    line = sketch.add_line(start.id, length=10.0, angle=0.0)
    line_ref, point_ref = _line_and_point_refs(sketch, line, start.id)

    resolved = resolve_normal_to_line_at_point(line_ref, point_ref, sketch_basis_for_plane(Plane.XY))

    assert resolved.origin == (0.0, 0.0, 0.0)
    assert resolved.normal == pytest.approx((1.0, 0.0, 0.0))


def test_resolves_at_the_lines_end_point_too_not_just_the_start():
    sketch = create_sketch(Plane.XY)
    start = sketch.add_point(0.0, 0.0)
    line = sketch.add_line(start.id, length=10.0, angle=0.0)
    end_id = line.end_point_id
    line_ref, point_ref = _line_and_point_refs(sketch, line, end_id)

    resolved = resolve_normal_to_line_at_point(line_ref, point_ref, sketch_basis_for_plane(Plane.XY))

    assert resolved.origin == pytest.approx((10.0, 0.0, 0.0))
    assert resolved.normal == pytest.approx((1.0, 0.0, 0.0))


def test_the_normal_is_unit_length_regardless_of_the_lines_own_length():
    sketch = create_sketch(Plane.XY)
    start = sketch.add_point(0.0, 0.0)
    line = sketch.add_line(start.id, length=123.456, angle=math.pi / 5)
    line_ref, point_ref = _line_and_point_refs(sketch, line, start.id)

    resolved = resolve_normal_to_line_at_point(line_ref, point_ref, sketch_basis_for_plane(Plane.XY))

    length = math.sqrt(sum(c * c for c in resolved.normal))
    assert length == pytest.approx(1.0)


def test_maps_correctly_on_the_xz_and_yz_planes_too():
    sketch_xz = create_sketch(Plane.XZ)
    start_xz = sketch_xz.add_point(0.0, 0.0)
    line_xz = sketch_xz.add_line(start_xz.id, length=5.0, angle=0.0)
    line_ref, point_ref = _line_and_point_refs(sketch_xz, line_xz, start_xz.id)
    resolved_xz = resolve_normal_to_line_at_point(line_ref, point_ref, sketch_basis_for_plane(Plane.XZ))
    # XZ: local (x, y) -> world (-x, 0, y) - a local-x-direction line's world
    # direction is along world -X (see `_PLANE_BASIS`'s own doc comment for
    # why XZ's x_axis is negated).
    assert resolved_xz.normal == pytest.approx((-1.0, 0.0, 0.0))

    sketch_yz = create_sketch(Plane.YZ)
    start_yz = sketch_yz.add_point(0.0, 0.0)
    line_yz = sketch_yz.add_line(start_yz.id, length=5.0, angle=math.pi / 2)  # local +y
    line_ref2, point_ref2 = _line_and_point_refs(sketch_yz, line_yz, start_yz.id)
    resolved_yz = resolve_normal_to_line_at_point(line_ref2, point_ref2, sketch_basis_for_plane(Plane.YZ))
    # YZ: local (x, y) -> world (0, x, y) - a local-+y-direction line's world
    # direction is along world Z.
    assert resolved_yz.normal == pytest.approx((0.0, 0.0, 1.0))


def test_raises_point_not_on_line_for_a_point_that_is_not_the_lines_endpoint():
    sketch = create_sketch(Plane.XY)
    start = sketch.add_point(0.0, 0.0)
    line = sketch.add_line(start.id, length=10.0, angle=0.0)
    off_line_point = sketch.add_point(5.0, 5.0)
    line_ref, point_ref = _line_and_point_refs(sketch, line, off_line_point.id)

    with pytest.raises(HTTPException) as exc_info:
        resolve_normal_to_line_at_point(line_ref, point_ref, sketch_basis_for_plane(Plane.XY))

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail == {
        "type": "point_not_on_line",
        "sketch_id": sketch.id,
        "line_id": line.id,
        "point_id": off_line_point.id,
    }


def test_raises_missing_reference_for_an_unknown_line_id():
    sketch = create_sketch(Plane.XY)
    start = sketch.add_point(0.0, 0.0)
    line_ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.LINE, entity_id="nope")
    point_ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=start.id)

    with pytest.raises(HTTPException) as exc_info:
        resolve_normal_to_line_at_point(line_ref, point_ref, sketch_basis_for_plane(Plane.XY))

    assert exc_info.value.detail["type"] == "missing_reference"


def test_raises_missing_reference_for_an_unknown_point_id():
    sketch = create_sketch(Plane.XY)
    start = sketch.add_point(0.0, 0.0)
    line = sketch.add_line(start.id, length=10.0, angle=0.0)
    line_ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.LINE, entity_id=line.id)
    point_ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id="nope")

    with pytest.raises(HTTPException) as exc_info:
        resolve_normal_to_line_at_point(line_ref, point_ref, sketch_basis_for_plane(Plane.XY))

    assert exc_info.value.detail["type"] == "missing_reference"


# --- build_feature_graph / cascade-delete for CreatePlaneFeature ------------


def _part_with_sketch_and_extrude() -> tuple[Part, str, str]:
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sf1", sketch_id="sketch-abc")
    part.add_feature(sketch_feature)
    extrude = ExtrudeFeature(
        id="ef1", sketch_feature_id="sf1", extrude_type=ExtrudeType.BOSS, start_distance=0, end_distance=10
    )
    part.add_feature(extrude)
    return part, sketch_feature.id, extrude.id


def test_offset_face_plane_depends_on_the_owning_extrude_feature():
    part, _sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[PlaneRef(face_ref=SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.FACE, index=0))],
        offset=5.0,
    )
    part.add_feature(plane)

    nodes = build_feature_graph(part)
    plane_node = next(n for n in nodes if n.id == "pl1")
    assert plane_node.depends_on == (extrude_id,)
    assert topological_order(nodes).index(extrude_id) < topological_order(nodes).index("pl1")


def test_normal_to_line_at_point_plane_depends_on_the_owning_sketch_feature():
    part, sketch_feature_id, _extrude_id = _part_with_sketch_and_extrude()
    plane = CreatePlaneFeature(
        id="pl2",
        plane_type=PlaneType.NORMAL_TO_LINE_AT_POINT,
        line_ref=SketchEntityRef(sketch_id="sketch-abc", entity_type=SketchEntityType.LINE, entity_id="l1"),
        point_ref=SketchEntityRef(
            sketch_id="sketch-abc", entity_type=SketchEntityType.POINT, entity_id="p1"
        ),
    )
    part.add_feature(plane)

    nodes = build_feature_graph(part)
    plane_node = next(n for n in nodes if n.id == "pl2")
    assert plane_node.depends_on == (sketch_feature_id,)


def test_cascade_deleting_the_sketch_feature_takes_both_kinds_of_plane_with_it():
    """A Plane referencing the Extrude's face, and a Plane referencing the
    Sketch's own Line/Point directly, are both transitively downstream of
    the SketchFeature - deleting it must take the Extrude and both Planes
    with it, not leave either dangling (the exact bug class B2 fixed for
    Boss/Cut's target_body_ids, now checked for this new reference kind)."""
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane1 = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[PlaneRef(face_ref=SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.FACE, index=0))],
        offset=5.0,
    )
    plane2 = CreatePlaneFeature(
        id="pl2",
        plane_type=PlaneType.NORMAL_TO_LINE_AT_POINT,
        line_ref=SketchEntityRef(sketch_id="sketch-abc", entity_type=SketchEntityType.LINE, entity_id="l1"),
        point_ref=SketchEntityRef(
            sketch_id="sketch-abc", entity_type=SketchEntityType.POINT, entity_id="p1"
        ),
    )
    part.add_feature(plane1)
    part.add_feature(plane2)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, sketch_feature_id) == {sketch_feature_id, extrude_id, "pl1", "pl2"}


def test_deleting_only_the_extrude_leaves_the_sketch_referencing_plane_alone():
    part, sketch_feature_id, extrude_id = _part_with_sketch_and_extrude()
    plane1 = CreatePlaneFeature(
        id="pl1",
        plane_type=PlaneType.OFFSET_FACE,
        face_refs=[PlaneRef(face_ref=SubShapeRef(body_id=extrude_id, shape_type=SubShapeType.FACE, index=0))],
        offset=5.0,
    )
    plane2 = CreatePlaneFeature(
        id="pl2",
        plane_type=PlaneType.NORMAL_TO_LINE_AT_POINT,
        line_ref=SketchEntityRef(sketch_id="sketch-abc", entity_type=SketchEntityType.LINE, entity_id="l1"),
        point_ref=SketchEntityRef(
            sketch_id="sketch-abc", entity_type=SketchEntityType.POINT, entity_id="p1"
        ),
    )
    part.add_feature(plane1)
    part.add_feature(plane2)

    nodes = build_feature_graph(part)
    assert transitive_dependents(nodes, extrude_id) == {extrude_id, "pl1"}
