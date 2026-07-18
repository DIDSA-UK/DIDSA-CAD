"""Sketcher-roadmap Phase 9 v2 (Convert Entities): materializes a Body
vertex/edge as a real, non-construction sketch entity with associative
(live-linked) endpoint Points - reuses Phase 4.3's own `external_references`/
pinning/staleness machinery (`test_stage_phase43_external_references.py`)
verbatim via `Sketch.add_or_reuse_external_vertex_reference`, the one
difference from Phase 4.3's own edge-reference endpoint being that the
resulting Line stays non-construction (real, extrude-participating
geometry).

`add_or_reuse_point`/`add_or_reuse_external_vertex_reference` both have zero
OCCT dependency and run for real in this sandbox. The `convert_body_vertex`/
`convert_body_edge` HTTP endpoints (`app.document.router`) need a real
OCCT/pythonocc-core environment (`compute_part_bodies`,
`resolve_external_vertex_position`) - not installed in this sandbox, so
those are syntax-checked (`python3 -m py_compile`) rather than executed
directly here; they run for real in CI.
"""

from app.sketch.models import ExternalVertexReference, Plane, Sketch

# --- add_or_reuse_point (also used by Offset Entities' own point-sharing -
# see test_feature_offset_entities.py) ------------------------------------


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


# --- add_or_reuse_external_vertex_reference (Convert Entities v2's own
# mechanism - identity-matched, not position-matched) ----------------------


def test_add_or_reuse_external_vertex_reference_creates_a_fresh_associative_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    ref = ExternalVertexReference(body_id="body-1", vertex_index=3)

    point = sketch.add_or_reuse_external_vertex_reference(5.0, 7.0, ref)

    assert point.id in sketch.points
    assert (sketch.points[point.id].x, sketch.points[point.id].y) == (5.0, 7.0)
    assert sketch.external_references[point.id] == ref


def test_add_or_reuse_external_vertex_reference_reuses_the_point_already_tracking_the_same_vertex():
    sketch = Sketch(id="s", plane=Plane.XY)
    ref = ExternalVertexReference(body_id="body-1", vertex_index=3)
    first = sketch.add_or_reuse_external_vertex_reference(5.0, 7.0, ref)

    second = sketch.add_or_reuse_external_vertex_reference(5.0, 7.0, ref)

    assert second.id == first.id
    assert len(sketch.points) == 1


def test_add_or_reuse_external_vertex_reference_matches_by_identity_not_position():
    """Two picks of the exact same Body vertex must reuse the same Point
    even if the resolved (x, y) drifted slightly between calls (e.g. the
    Body moved a hair between the two picks) - identity match, not a
    position-epsilon match like `add_or_reuse_point`'s own reuse rule."""
    sketch = Sketch(id="s", plane=Plane.XY)
    ref = ExternalVertexReference(body_id="body-1", vertex_index=3)
    first = sketch.add_or_reuse_external_vertex_reference(5.0, 7.0, ref)

    second = sketch.add_or_reuse_external_vertex_reference(5.5, 7.5, ref)

    assert second.id == first.id
    # The stored position is whatever the *first* call resolved - a second
    # pick's own (x, y) is discarded when reusing, same as the real
    # endpoint's own flow (a fresh resolve happens on refresh, not on pick).
    assert (sketch.points[first.id].x, sketch.points[first.id].y) == (5.0, 7.0)


def test_add_or_reuse_external_vertex_reference_does_not_reuse_a_different_vertex():
    sketch = Sketch(id="s", plane=Plane.XY)
    ref_a = ExternalVertexReference(body_id="body-1", vertex_index=3)
    ref_b = ExternalVertexReference(body_id="body-1", vertex_index=4)
    first = sketch.add_or_reuse_external_vertex_reference(5.0, 7.0, ref_a)

    second = sketch.add_or_reuse_external_vertex_reference(6.0, 8.0, ref_b)

    assert second.id != first.id
    assert len(sketch.points) == 2


def test_converting_two_edges_sharing_a_body_vertex_shares_one_associative_sketch_point():
    """The scenario `add_or_reuse_external_vertex_reference` exists for:
    two separately-converted Body edges that share a Body vertex should
    end up sharing one real, associative Sketch Point - `convert_body_edge`
    resolves a shared corner to the *exact same* `ExternalVertexReference`
    for both edges (`edge_endpoint_vertex_refs` against the same indexed
    vertex map), so the reuse lookup finds it deterministically."""
    sketch = Sketch(id="s", plane=Plane.XY)
    shared_vertex_ref = ExternalVertexReference(body_id="body-1", vertex_index=2)

    # Edge 1: vertex 0 -> shared vertex 2; Edge 2: shared vertex 2 -> vertex 5.
    e1_start = sketch.add_or_reuse_external_vertex_reference(
        0.0, 0.0, ExternalVertexReference(body_id="body-1", vertex_index=0)
    )
    e1_end = sketch.add_or_reuse_external_vertex_reference(10.0, 0.0, shared_vertex_ref)
    line1 = sketch.add_line(e1_start.id, e1_end.id, construction=False)

    e2_start = sketch.add_or_reuse_external_vertex_reference(10.0, 0.0, shared_vertex_ref)
    e2_end = sketch.add_or_reuse_external_vertex_reference(
        10.0, 10.0, ExternalVertexReference(body_id="body-1", vertex_index=5)
    )
    line2 = sketch.add_line(e2_start.id, e2_end.id, construction=False)

    assert e2_start.id == e1_end.id
    assert line1.end_point_id == line2.start_point_id
    assert len(sketch.points) == 3
    assert line1.construction is False
    assert line2.construction is False
