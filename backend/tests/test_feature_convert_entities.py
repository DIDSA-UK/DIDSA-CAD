"""Sketcher-roadmap Phase 9 v1 (Convert Entities): materializes a Body
vertex/edge as a real, plain sketch entity (no `external_references`
back-link, non-construction) - a frozen, one-time copy, distinct from Phase
4.3's live-pinned dimensioning references (`test_stage_phase43_external_
references.py`).

`Sketch.add_or_reuse_point` has zero OCCT dependency and runs for real in
this sandbox. The new `convert_body_vertex`/`convert_body_edge` HTTP
endpoints (`app.document.router`) need a real OCCT/pythonocc-core
environment (`compute_part_bodies`, `resolve_external_vertex_position`) -
not installed in this sandbox, so those are syntax-checked (`python3 -m
py_compile`) rather than executed directly here; they run for real in CI.
"""

from app.sketch.models import Plane, Sketch


def test_add_or_reuse_point_creates_a_fresh_point_when_nothing_is_there():
    sketch = Sketch(id="s", plane=Plane.XY)

    point = sketch.add_or_reuse_point(3.0, 4.0)

    assert point.id in sketch.points
    assert (sketch.points[point.id].x, sketch.points[point.id].y) == (3.0, 4.0)


def test_add_or_reuse_point_reuses_an_existing_point_within_epsilon():
    sketch = Sketch(id="s", plane=Plane.XY)
    existing = sketch.add_point(3.0, 4.0)

    reused = sketch.add_or_reuse_point(3.0 + 1e-9, 4.0 - 1e-9)

    assert reused.id == existing.id
    assert len(sketch.points) == 1


def test_add_or_reuse_point_does_not_reuse_a_point_outside_epsilon():
    sketch = Sketch(id="s", plane=Plane.XY)
    existing = sketch.add_point(3.0, 4.0)

    fresh = sketch.add_or_reuse_point(3.5, 4.0)

    assert fresh.id != existing.id
    assert len(sketch.points) == 2


def test_converting_two_edges_sharing_a_body_vertex_shares_one_sketch_point():
    """The scenario `add_or_reuse_point` exists for: two separately
    "converted" Body edges that share a Body vertex should end up sharing
    one real Sketch Point at that location, not two coincident-but-
    disconnected ones - otherwise the result never registers as a closed
    profile for Extrude, the same failure mode `trim_circle`'s own point-
    reuse fix addressed earlier."""
    sketch = Sketch(id="s", plane=Plane.XY)

    # Edge 1: (0, 0) -> (10, 0); Edge 2: (10, 0) -> (10, 10). Each call
    # mirrors what `convert_body_edge` does per endpoint: resolve the
    # world position, then add-or-reuse.
    e1_start = sketch.add_or_reuse_point(0.0, 0.0)
    e1_end = sketch.add_or_reuse_point(10.0, 0.0)
    line1 = sketch.add_line(e1_start.id, e1_end.id, construction=False)

    e2_start = sketch.add_or_reuse_point(10.0, 0.0)
    e2_end = sketch.add_or_reuse_point(10.0, 10.0)
    line2 = sketch.add_line(e2_start.id, e2_end.id, construction=False)

    assert e2_start.id == e1_end.id
    assert line1.end_point_id == line2.start_point_id
    assert len(sketch.points) == 3
