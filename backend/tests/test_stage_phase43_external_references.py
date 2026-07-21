"""Sketcher-roadmap Phase 4.3 v1: a Sketch Point that tracks a Body vertex
from outside the Sketch entirely, materialized via a new document-router
endpoint and kept pinned (never moved by the solver) exactly like the
Sketch's own origin already is.

Most of this feature - `app.sketch.models.Sketch.external_references`/
`add_external_vertex_reference`, `app.sketch.solver.solve_sketch`'s pinning,
`app.document.plane_geometry.world_point_to_basis`, and
`app.document.graph.build_feature_graph`'s new SketchFeature dependency edge
- has zero OCCT dependency and runs for real in this sandbox, the same way
this project's other OCCT-free layers already do (see e.g.
`test_stage_c5_graph.py`'s own docstring). The new
`create_external_vertex_reference` HTTP endpoint and
`SketchFeatureResponse.has_lost_reference` need a real OCCT/pythonocc-core
environment (to resolve a `TopoDS_Shape`/compute Part Bodies) - not
installed in this sandbox, so those are syntax-checked (`python3 -m
py_compile`) and reviewed by hand rather than executed directly here; they
run for real in CI, which has the full conda environment.
"""

import pytest

from app.document.graph import build_feature_graph
from app.document.models import ExtrudeFeature, ExtrudeType, Part, SketchFeature
from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.document.plane_geometry import (
    basis_point,
    oriented_basis_for_plane,
    sketch_basis_for_plane,
    world_point_to_basis,
)
from app.sketch.models import ExternalVertexReference, Plane, Sketch
from app.sketch.solver import solve_sketch
from app.sketch.store import create_sketch


# --- Sketch model -------------------------------------------------------


def test_add_external_vertex_reference_creates_a_real_point_and_records_the_mapping():
    sketch = Sketch(id="s", plane=Plane.XY)
    ref = ExternalVertexReference(body_id="body-1", vertex_index=3)

    point = sketch.add_external_vertex_reference(5.0, 7.0, ref)

    assert point.id in sketch.points
    assert (sketch.points[point.id].x, sketch.points[point.id].y) == (5.0, 7.0)
    assert sketch.external_references[point.id] == ref


def test_delete_point_also_removes_its_external_reference_mapping():
    sketch = Sketch(id="s", plane=Plane.XY)
    ref = ExternalVertexReference(body_id="body-1", vertex_index=0)
    point = sketch.add_external_vertex_reference(1.0, 2.0, ref)

    sketch.delete_point(point.id)

    assert point.id not in sketch.points
    assert point.id not in sketch.external_references


# --- Solver pinning -------------------------------------------------------


def test_solve_sketch_never_moves_an_external_reference_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.origin_point()
    ref = ExternalVertexReference(body_id="body-1", vertex_index=0)
    ext_point = sketch.add_external_vertex_reference(12.0, 0.0, ref)
    other = sketch.add_point(6.0, 4.0)
    sketch.add_distance_constraint(center.id, other.id, 10.0)
    sketch.add_distance_constraint(ext_point.id, other.id, 5.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert (sketch.points[ext_point.id].x, sketch.points[ext_point.id].y) == (12.0, 0.0)


def test_solve_sketch_keeps_an_external_reference_point_pinned_even_on_the_no_anchor_retry():
    """An inconsistent drag-anchor attempt retries with no anchors at all
    (see `solve_sketch`'s own doc comment) - an external reference must
    stay pinned on *both* attempts, unlike a plain drag anchor which is
    only ever pinned for the one attempt that includes it."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.origin_point()
    ref = ExternalVertexReference(body_id="body-1", vertex_index=0)
    ext_point = sketch.add_external_vertex_reference(12.0, 0.0, ref)
    dragged = sketch.add_point(1.0, 1.0)
    other = sketch.add_point(6.0, 4.0)
    # A Constraint tying the dragged Point to the (already-fixed) origin at
    # a distance the dragged Point's own current position doesn't satisfy -
    # forces the anchored attempt to fail to converge, triggering the retry.
    sketch.add_distance_constraint(center.id, dragged.id, 999.0)
    sketch.add_distance_constraint(ext_point.id, other.id, 5.0)

    result = solve_sketch(sketch, anchor_point_ids=frozenset({dragged.id}))

    assert (sketch.points[ext_point.id].x, sketch.points[ext_point.id].y) == (12.0, 0.0)


def test_two_distance_dimensions_off_a_grounded_centre_and_an_external_reference_fully_constrain_a_point():
    """A Point pinned by distance to two already-fixed anchors (the
    grounded origin, and an external reference - both pinned exactly the
    same way, see `solve_sketch`'s own doc comment) has both of its 2
    degrees of freedom removed, the same way any other two-anchor distance
    dimensioning already does - confirms an external reference behaves as
    a genuine, ordinary fixed anchor to the solver, not a special case."""
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.origin_point()
    ref = ExternalVertexReference(body_id="body-1", vertex_index=0)
    ext_point = sketch.add_external_vertex_reference(12.0, 0.0, ref)
    other = sketch.add_point(6.0, 4.0)
    sketch.add_distance_constraint(center.id, other.id, 10.0)
    sketch.add_distance_constraint(ext_point.id, other.id, 5.0)

    result = solve_sketch(sketch)

    assert result.converged
    assert result.dof == 0


# --- plane_geometry: world <-> sketch-local round trip ---------------------


def test_world_point_to_basis_is_the_exact_inverse_of_basis_point_for_every_fixed_plane():
    for plane in (Plane.XY, Plane.XZ, Plane.YZ):
        basis = sketch_basis_for_plane(plane)
        for x, y in [(3.0, 4.0), (-2.5, 7.1), (0.0, 0.0)]:
            world = basis_point(basis, x, y)
            rx, ry = world_point_to_basis(basis, world)
            assert rx == pytest.approx(x)
            assert ry == pytest.approx(y)


def test_world_point_to_basis_round_trips_through_flip_and_rotation_too():
    for plane in (Plane.XY, Plane.XZ, Plane.YZ):
        for flip in (False, True):
            for turns in range(4):
                basis = oriented_basis_for_plane(plane, flip=flip, rotation_quarter_turns=turns)
                world = basis_point(basis, -4.0, 9.5)
                rx, ry = world_point_to_basis(basis, world)
                assert rx == pytest.approx(-4.0)
                assert ry == pytest.approx(9.5)


# --- Feature dependency graph -----------------------------------------------


def test_a_sketch_feature_depends_on_the_extrude_that_created_a_body_it_references():
    sketch = create_sketch(Plane.XY)
    sketch.external_references["fake-point-id"] = ExternalVertexReference(
        body_id="extrude-1", vertex_index=0
    )
    part = Part(id="p1", name="Test")
    extrude = ExtrudeFeature(
        id="extrude-1",
        sketch_feature_id="unrelated-sketch-feature",
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=10.0,
    )
    part.add_feature(extrude)
    sketch_feature = SketchFeature(id="sketch-feature-1", sketch_id=sketch.id)
    part.add_feature(sketch_feature)

    nodes = build_feature_graph(part)

    node = next(n for n in nodes if n.id == "sketch-feature-1")
    assert "extrude-1" in node.depends_on


def test_a_sketch_feature_with_no_external_references_gets_no_extra_dependency():
    sketch = create_sketch(Plane.XY)
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sketch-feature-1", sketch_id=sketch.id)
    part.add_feature(sketch_feature)

    nodes = build_feature_graph(part)

    node = next(n for n in nodes if n.id == "sketch-feature-1")
    assert node.depends_on == ()


def test_a_sketch_feature_whose_sketch_no_longer_resolves_gets_no_extra_dependency_either():
    """`sketch_id` pointing nowhere is tolerated, not an error - same rule
    every other unresolvable dependency id in this module already follows."""
    part = Part(id="p1", name="Test")
    sketch_feature = SketchFeature(id="sketch-feature-1", sketch_id="does-not-exist")
    part.add_feature(sketch_feature)

    nodes = build_feature_graph(part)

    node = next(n for n in nodes if n.id == "sketch-feature-1")
    assert node.depends_on == ()


# --- Native format persistence ----------------------------------------------


def test_native_format_round_trips_external_references():
    sketch = Sketch(id="s1", plane=Plane.XY)
    sketch.origin_point()
    ref = ExternalVertexReference(body_id="body-1", vertex_index=5)
    point = sketch.add_external_vertex_reference(12.0, 8.0, ref)

    data = sketch_to_dict(sketch)
    restored = sketch_from_dict(data)

    assert restored.external_references[point.id] == ref
    assert (restored.points[point.id].x, restored.points[point.id].y) == (12.0, 8.0)


def test_native_format_defaults_external_references_to_empty_for_an_older_save_file():
    sketch = Sketch(id="s1", plane=Plane.XY)
    data = sketch_to_dict(sketch)
    del data["external_references"]  # simulates a file saved before this feature existed

    restored = sketch_from_dict(data)

    assert restored.external_references == {}
