"""OCCT history for edge and face references (docs/reference-identity-design.md, "OCCT history"): a reference stamped while the Part is small carries a lineage - the
Feature whose output created the sub-shape - and, when its index goes stale, history says what became of it: followed through the operations since, or *consumed by
<feature>*, in which case replay fails closed instead of binding a look-alike the signature search alone would have accepted. Needs a real pythonocc-core
environment."""

import dataclasses

import pytest

from app.document.extrude import compute_part_bodies
from app.document.models import SubShapeRef, SubShapeType
from app.document.reference_history import ReferenceHistory
from app.document.reference_signature import BodyEdgeMeasurer, BodyFaceMeasurer
from app.document.router import get_part_or_404
from app.document.subshape_identity import HISTORY_MAX_FEATURES, bodies_before_feature, refresh_feature_subshape_refs
from tests.test_reference_identity import _box, _feature, _fillet, _json, client
from tests.test_subshape_identity import _plane_on_top_face, _top_face_index


def _rectangle_cut(part_id: str, target_body_id: str, corners, start=0.0, end=10.0):
    """An extrude CUT of a closed XY rectangle. Returns (sketch feature, cut feature, the four Point ids)."""
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    points = [_json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y})) for x, y in corners]
    for a, b in zip(points, points[1:] + points[:1]):
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}))
    cut = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "cut", "start_distance": start, "end_distance": end, "target_body_ids": [target_body_id]},
        )
    )
    return sketch, cut, [p["id"] for p in points]


def _move_rectangle(sketch: dict, point_ids, corners):
    for pid, (x, y) in zip(point_ids, corners):
        _json(client.patch(f"/sketch/sketches/{sketch['sketch_id']}/points/{pid}", json={"x": x, "y": y}))


def _comb(notches: int):
    """A plate with `notches` identical rectangular notches cut into its top edge (an extruded polygon), so a notch's inner corner edge has identical twins."""
    points = [(0, 0), (10 * notches + 10, 0), (10 * notches + 10, 10)]
    for i in reversed(range(notches)):
        x = 4 + 10 * i
        points += [(x + 2, 10), (x + 2, 7), (x, 7), (x, 10)]
    points.append((0, 10))
    from tests.test_reference_identity import _polygon_extrude

    return _polygon_extrude(points)


def _edge_at(part_id: str, body_id: str, x: float, y: float) -> int:
    body = compute_part_bodies(get_part_or_404(part_id))[body_id]
    return next(
        i
        for i, s in enumerate(BodyEdgeMeasurer(body).all())
        if s.curve_kind == "line" and abs(s.position[0] - x) < 1e-6 and abs(s.position[1] - y) < 1e-6 and abs(s.direction[2]) > 0.99
    )


# --- lineage is recorded for edges and faces ---------------------------------------------------------------------


def test_an_edge_reference_made_after_a_fillet_traces_back_to_the_extrude_that_created_it():
    part_id, _, extrude, _ = _box()
    _fillet(part_id, extrude["id"], 0)
    f2 = _fillet(part_id, extrude["id"], _edge_at(part_id, extrude["id"], 10.0, 10.0), radius=1.0)
    ref = get_part_or_404(part_id).get_feature(f2["id"]).edge_refs[0]
    assert ref.lineage is not None and ref.lineage.kind == "edge" and ref.lineage.feature_id == extrude["id"]
    assert ref.lineage.signature.curve_kind == "line"


def test_a_face_reference_made_after_a_fillet_traces_back_to_the_extrude_that_created_it():
    part_id, _, extrude, _ = _box()
    _fillet(part_id, extrude["id"], 0)
    plane = _plane_on_top_face(part_id, extrude["id"])
    ref = get_part_or_404(part_id).get_feature(plane["id"]).face_refs[0].face_ref
    assert ref.lineage is not None and ref.lineage.kind == "face" and ref.lineage.feature_id == extrude["id"]


def test_a_part_with_too_many_features_is_not_traced_and_keeps_working_on_signatures_alone():
    part_id, _, extrude, _ = _box()
    part = get_part_or_404(part_id)
    original = HISTORY_MAX_FEATURES
    import app.document.subshape_identity as module

    module.HISTORY_MAX_FEATURES = 0
    try:
        plane = _plane_on_top_face(part_id, extrude["id"])
        ref = part.get_feature(plane["id"]).face_refs[0].face_ref
        assert ref.signature is not None and ref.lineage is None
    finally:
        module.HISTORY_MAX_FEATURES = original


# --- history beats a look-alike -----------------------------------------------------------------------------------


def _comb_with_a_fillet_on_the_notch_corner(notches: int = 2):
    """Plate with notches; an upstream rectangle CUT parked well away from the notches; a fillet on the first notch's inner corner edge (the one at (14, 7)).
    Returns (part, extrude id, cut sketch, cut Point ids, the fillet feature)."""
    part_id, _, extrude, _ = _comb(notches)
    sketch, cut, ids = _rectangle_cut(part_id, extrude["id"], [(0.5, 0.5), (1.5, 0.5), (1.5, 1.5), (0.5, 1.5)])
    fillet = _fillet(part_id, extrude["id"], _edge_at(part_id, extrude["id"], 14.0, 7.0), radius=0.4)
    return part_id, extrude, sketch, ids, fillet


def test_an_edge_consumed_by_an_upstream_cut_is_lost_even_though_an_identical_looking_twin_remains():
    part_id, extrude, sketch, ids, fillet = _comb_with_a_fillet_on_the_notch_corner(notches=2)
    assert not _feature(part_id, fillet["id"])["has_lost_reference"]
    # The cut now swallows the notch corner the fillet names; the OTHER notch's corner edge looks exactly like it.
    _move_rectangle(sketch, ids, [(13.0, 6.0), (15.0, 6.0), (15.0, 8.0), (13.0, 8.0)])
    feature = _feature(part_id, fillet["id"])
    assert feature["has_lost_reference"] and feature["lost_references"] == ["edge_refs[0]"]
    assert feature["reference_reasons"]["edge_refs[0]"].startswith("consumed_by_")
    ref = get_part_or_404(part_id).get_feature(fillet["id"]).edge_refs[0]
    assert ref.lost_reason is not None  # replay fails closed on it: the fillet is not applied to the twin
    # and the solid really has no fillet on the twin: the replayed Part keeps the twin's corner sharp
    body = compute_part_bodies(get_part_or_404(part_id))[extrude["id"]]
    twin = [s for s in BodyEdgeMeasurer(body).all() if s.curve_kind == "line" and abs(s.direction[2]) > 0.99 and abs(s.position[0] - 4.0) < 1e-6 and abs(s.position[1] - 7.0) < 1e-6]
    assert twin, "the twin notch corner edge is still a sharp straight edge"


def test_without_history_the_same_edit_is_still_flagged_but_only_as_ambiguous():
    part_id, extrude, sketch, ids, fillet = _comb_with_a_fillet_on_the_notch_corner(notches=2)
    _feature(part_id, fillet["id"])
    holder = get_part_or_404(part_id).get_feature(fillet["id"])
    holder.edge_refs[0] = dataclasses.replace(holder.edge_refs[0], lineage=None)  # as a Part too large to trace, or an old file, has it
    _move_rectangle(sketch, ids, [(13.0, 6.0), (15.0, 6.0), (15.0, 8.0), (13.0, 8.0)])
    feature = _feature(part_id, fillet["id"])
    assert feature["has_lost_reference"] and feature["lost_references"] == ["edge_refs[0]"]
    assert feature["reference_reasons"]["edge_refs[0]"] == "ambiguous"  # safe, but it cannot say WHY (history says "consumed by the cut")


def test_a_reference_heals_when_the_upstream_edit_is_undone():
    part_id, extrude, sketch, ids, fillet = _comb_with_a_fillet_on_the_notch_corner(notches=2)
    harmless = [(0.5, 0.5), (1.5, 0.5), (1.5, 1.5), (0.5, 1.5)]
    _move_rectangle(sketch, ids, [(13.0, 6.0), (15.0, 6.0), (15.0, 8.0), (13.0, 8.0)])
    assert _feature(part_id, fillet["id"])["has_lost_reference"]
    _move_rectangle(sketch, ids, harmless)
    feature = _feature(part_id, fillet["id"])
    assert not feature["has_lost_reference"], feature
    assert get_part_or_404(part_id).get_feature(fillet["id"]).edge_refs[0].lost_reason is None


def test_a_face_consumed_by_an_upstream_cut_is_lost_not_rebound_to_the_new_top():
    part_id, _, extrude, _ = _box()
    sketch, cut, ids = _rectangle_cut(part_id, extrude["id"], [(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)], start=5.0, end=10.0)  # misses the box
    plane = _plane_on_top_face(part_id, extrude["id"])
    assert not _feature(part_id, plane["id"])["has_lost_reference"]
    # The slab z in [5, 10] over the whole footprint goes: the top face is consumed and a NEW top face appears at z = 5, same normal.
    _move_rectangle(sketch, ids, [(-1.0, -1.0), (11.0, -1.0), (11.0, 11.0), (-1.0, 11.0)])
    feature = _feature(part_id, plane["id"])
    assert feature["has_lost_reference"] and feature["lost_references"] == ["face_refs[0].face_ref"]
    assert feature["reference_reasons"]["face_refs[0].face_ref"].startswith("consumed_by_")


def test_a_face_that_survives_the_operations_since_is_followed_through_them():
    part_id, _, extrude, _ = _box()
    sketch, cut, ids = _rectangle_cut(part_id, extrude["id"], [(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)], start=7.0, end=10.0)
    plane = _plane_on_top_face(part_id, extrude["id"])
    # A slot across the part's corner region: the top face is cut but not consumed (it is Modified), so the plane stays on it.
    _move_rectangle(sketch, ids, [(-1.0, -1.0), (3.0, -1.0), (3.0, 3.0), (-1.0, 3.0)])
    feature = _feature(part_id, plane["id"])
    assert not feature["has_lost_reference"], feature
    assert feature["origin"][2] == pytest.approx(15.0)  # still the top face (z = 10) plus the 5 offset
