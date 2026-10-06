"""Reference-identity overhaul (docs/reference-identity-design.md): a Sketch's external (Body vertex) references carry a geometric signature and an OCCT-history
lineage, are re-validated on every refresh, are re-found when the index goes stale, and are flagged (never silently rebound) when they cannot be found.

Needs a real pythonocc-core environment, like every other OCCT-touching test here. The probe that motivated this (a fillet moved to another edge renumbers the
vertices) lives in test_reference_follows_upstream_topology_change.py; this file covers the rest: every edit kind, a genuinely deleted vertex, ambiguity,
persistence, the status / re-attach / confirm routes, and the pure matching rules.
"""

import dataclasses
import json

import pytest
from fastapi.testclient import TestClient

from app.document.extrude import compute_part_bodies, edge_endpoint_vertex_refs
from app.document.models import SubShapeRef, SubShapeType
from app.document.native_format import export_native, import_native
from app.document.router import get_part_or_404
from app.document.store import get_document
from app.main import app
from app.sketch.models import ExternalVertexReference
from app.sketch.reference_signature import (
    ReferenceStatus,
    VertexSignature,
    decide_reference,
    fingerprint_matches,
)
from app.sketch.store import all_sketches
from tests.conftest import TEST_API_KEY
from tests.test_reference_follows_upstream_topology_change import _vertex_positions

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

CORNER = (10.0, 10.0, 10.0)


def _json(response):
    assert response.status_code < 300, (response.status_code, response.text[:400])
    return response.json()


def _polygon_extrude(points, depth=10.0):
    """A closed XY polygon sketch extruded `depth`. Returns (part id, sketch feature, extrude feature, the polygon's Point ids)."""
    part_id = _json(client.post("/document/parts", json={"name": "P"}))["id"]
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    ids = [_json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y})) for x, y in points]
    for a, b in zip(ids, ids[1:] + ids[:1]):
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}))
    extrude = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": depth, "target_body_ids": []},
        )
    )
    return part_id, sketch, extrude, [p["id"] for p in ids]


def _box():
    return _polygon_extrude([(0, 0), (10, 0), (10, 10), (0, 10)])


def _fillet(part_id, body_id, edge_index, radius=2.0):
    return _json(
        client.post(
            f"/document/parts/{part_id}/fillet-features",
            json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": edge_index}], "radius": radius},
        )
    )


def _vertex_index_at(part_id, body_id, position):
    return next(i for i, v in _vertex_positions(part_id, body_id).items() if v == position)


def _reference_to(part_id, body_id, position):
    """A new Sketch (XY) after the features so far, referencing the Body vertex at `position`. Returns (sketch feature, Point id)."""
    index = _vertex_index_at(part_id, body_id, position)
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    point = _json(
        client.post(
            f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references",
            json={"body_id": body_id, "vertex_index": index},
        )
    )
    return sketch, point["id"]


def _feature(part_id, feature_id):
    return next(f for f in _json(client.get(f"/document/parts/{part_id}/features")) if f["id"] == feature_id)


def _ref(sketch_feature, point_id) -> ExternalVertexReference:
    return all_sketches()[sketch_feature["sketch_id"]].external_references[point_id]


def _bound_corner(part_id, sketch_feature, point_id):
    ref = _ref(sketch_feature, point_id)
    return _vertex_positions(part_id, ref.body_id).get(ref.vertex_index)


# --- the reference carries what it needs ---------------------------------------------------------------------------


def test_a_new_reference_stores_the_signature_of_its_corner_and_where_the_corner_came_from():
    part_id, _, extrude, _ = _box()
    _fillet(part_id, extrude["id"], 0)
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    ref = _ref(sketch, point_id)
    assert ref.signature is not None
    assert tuple(round(c, 6) for c in ref.signature.position) == CORNER
    assert ref.signature.valence == 3
    assert sorted(ref.signature.face_normals) == sorted([(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)])
    assert ref.signature.body_diagonal == pytest.approx(17.3205, abs=1e-3)
    assert ref.lineage is not None and ref.lineage.feature_id == extrude["id"]  # the corner was created by the Extrude; the Fillet left it alone


def test_the_fast_path_changes_nothing_and_reports_nothing():
    part_id, _, extrude, _ = _box()
    _fillet(part_id, extrude["id"], 0)
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    before = _ref(sketch, point_id)
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"]
    assert feature["lost_reference_point_ids"] == feature["moved_reference_point_ids"] == feature["followed_reference_point_ids"] == []
    assert _ref(sketch, point_id).vertex_index == before.vertex_index


# --- every topology-changing edit: follow, or flag; never another corner -------------------------------------------


def _pristine_box_edge_endpoints():
    """For every edge index of a plain box: the world positions of its two endpoints."""
    part_id, _, extrude, _ = _box()
    bodies = compute_part_bodies(get_part_or_404(part_id))
    positions = _vertex_positions(part_id, extrude["id"])
    out = {}
    for edge_index in range(12):
        start, end = edge_endpoint_vertex_refs(bodies, SubShapeRef(body_id=extrude["id"], shape_type=SubShapeType.EDGE, index=edge_index))
        out[edge_index] = (positions[start.index], positions[end.index])
    return out


@pytest.mark.parametrize("new_edge", range(12))
def test_moving_the_fillet_to_any_edge_follows_the_corner_or_flags_it_lost(new_edge: int):
    endpoints = _pristine_box_edge_endpoints()[new_edge]
    part_id, _, extrude, _ = _box()
    fillet = _fillet(part_id, extrude["id"], 0)
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    _json(
        client.patch(
            f"/document/parts/{part_id}/fillet-features/{fillet['id']}",
            json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": new_edge}]},
        )
    )
    feature = _feature(part_id, sketch["id"])
    if CORNER in endpoints:  # the fillet now eats the very corner the reference names
        assert feature["has_lost_reference"] and feature["lost_reference_point_ids"] == [point_id]
        assert feature["reference_reasons"][point_id] == f"consumed_by_{fillet['id']}"
    else:
        assert not feature["has_lost_reference"], feature
        assert _bound_corner(part_id, sketch, point_id) == CORNER
        assert feature["moved_reference_point_ids"] == []


def test_adding_a_second_filleted_edge_follows_the_corner():
    part_id, _, extrude, _ = _box()
    fillet = _fillet(part_id, extrude["id"], 0)
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    _json(
        client.patch(
            f"/document/parts/{part_id}/fillet-features/{fillet['id']}",
            json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": i} for i in (0, 1)]},
        )
    )
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"]
    assert _bound_corner(part_id, sketch, point_id) == CORNER


def test_a_chamfer_moved_to_another_edge_follows_the_corner():
    part_id, _, extrude, _ = _box()
    chamfer = _json(
        client.post(
            f"/document/parts/{part_id}/chamfer-features",
            json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": 0}], "distance": 2.0},
        )
    )
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    _json(
        client.patch(
            f"/document/parts/{part_id}/chamfer-features/{chamfer['id']}",
            json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": 5}]},
        )
    )
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"]
    assert _bound_corner(part_id, sketch, point_id) == CORNER


# --- no regression of the parametric cases -------------------------------------------------------------------------


def test_a_fillet_radius_change_and_an_extrude_depth_change_are_followed_without_any_flag():
    part_id, _, extrude, _ = _box()
    fillet = _fillet(part_id, extrude["id"], 0)
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    _json(client.patch(f"/document/parts/{part_id}/fillet-features/{fillet['id']}", json={"radius": 3.0}))
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"] and feature["moved_reference_point_ids"] == [] and feature["followed_reference_point_ids"] == []
    _json(client.patch(f"/document/parts/{part_id}/extrude-features/{extrude['id']}", json={"end_distance": 20.0}))
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"] and feature["moved_reference_point_ids"] == []
    assert _bound_corner(part_id, sketch, point_id) == (10.0, 10.0, 20.0)  # the same corner, now higher


def test_a_base_sketch_dimension_change_moves_the_reference_with_its_corner():
    part_id, base, extrude, base_points = _box()
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    _json(client.patch(f"/sketch/sketches/{base['sketch_id']}/points/{base_points[2]}", json={"x": 14.0, "y": 10.0}))
    _json(client.patch(f"/sketch/sketches/{base['sketch_id']}/points/{base_points[1]}", json={"x": 14.0, "y": 0.0}))
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"]
    assert _bound_corner(part_id, sketch, point_id) == (14.0, 10.0, 10.0)
    points = {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}
    assert (points[point_id]["x"], points[point_id]["y"]) == (14.0, 10.0)


# --- genuinely deleted ------------------------------------------------------------------------------------------


def test_a_corner_removed_by_an_upstream_cut_is_flagged_lost_with_the_cut_named():
    part_id, _, extrude, _ = _box()
    cut_sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    cut_points = [
        _json(client.post(f"/sketch/sketches/{cut_sketch['sketch_id']}/points", json={"x": x, "y": y}))
        for x, y in [(-5, -5), (3, -5), (3, 3), (-5, 3)]
    ]
    for a, b in zip(cut_points, cut_points[1:] + cut_points[:1]):
        _json(client.post(f"/sketch/sketches/{cut_sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}))
    cut = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": cut_sketch["id"], "extrude_type": "cut", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": [extrude["id"]]},
        )
    )
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    assert not _feature(part_id, sketch["id"])["has_lost_reference"]
    index_before = _ref(sketch, point_id).vertex_index
    # Move the cut over the far corner.
    for point, (x, y) in zip(cut_points, [(5, 5), (12, 5), (12, 12), (5, 12)]):
        _json(client.patch(f"/sketch/sketches/{cut_sketch['sketch_id']}/points/{point['id']}", json={"x": x, "y": y}))
    feature = _feature(part_id, sketch["id"])
    assert feature["has_lost_reference"] and feature["lost_reference_point_ids"] == [point_id]
    assert feature["reference_reasons"][point_id] == f"consumed_by_{cut['id']}"
    # Lost is not rebound: the Point keeps its last position, and the stored vertex is untouched.
    assert _ref(sketch, point_id).vertex_index == index_before


# --- ambiguity: three identical notches ---------------------------------------------------------------------------

COMB = [
    (0, 0), (30, 0), (30, 10), (26, 10), (26, 7), (24, 7), (24, 10), (16, 10), (16, 7), (14, 7), (14, 10),
    (6, 10), (6, 7), (4, 7), (4, 10), (0, 10),
]  # fmt: skip


def _comb_with_reference_to_the_middle_notch():
    part_id, _, extrude, _ = _polygon_extrude(COMB)
    bodies = compute_part_bodies(get_part_or_404(part_id))
    positions = _vertex_positions(part_id, extrude["id"])
    target = (14.0, 7.0, 10.0)
    # the Fillet edge that runs straight down through that notch corner
    edge_index = next((i for i in range(60) if _edge_positions(bodies, positions, extrude["id"], i) == {target, (14.0, 7.0, 0.0)}), None)
    assert edge_index is not None, "no vertical edge at the notch corner"
    # A fillet on an unrelated edge comes first (the Sketch only sees the Part as it stood after the features before it), and is then moved onto the notch.
    far_edge = next(i for i in range(60) if i != edge_index and _edge_positions(bodies, positions, extrude["id"], i) == {(0.0, 0.0, 0.0), (0.0, 0.0, 10.0)})
    fillet = _fillet(part_id, extrude["id"], far_edge, radius=0.5)
    sketch, point_id = _reference_to(part_id, extrude["id"], target)
    return part_id, extrude, fillet, edge_index, sketch, point_id


def _edge_positions(bodies, positions, body_id, edge_index):
    try:
        a, b = edge_endpoint_vertex_refs(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=edge_index))
    except Exception:
        return None
    return {positions[a.index], positions[b.index]}


def _move_fillet(part_id, body_id, fillet_id, edge_index):
    _json(
        client.patch(
            f"/document/parts/{part_id}/fillet-features/{fillet_id}",
            json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": edge_index}]},
        )
    )


def test_a_corner_consumed_with_identical_twins_left_is_flagged_not_rebound_to_a_twin():
    part_id, extrude, fillet, edge_index, sketch, point_id = _comb_with_reference_to_the_middle_notch()
    _move_fillet(part_id, extrude["id"], fillet["id"], edge_index)  # fillets the referenced corner away; the two other notches remain
    feature = _feature(part_id, sketch["id"])
    assert feature["lost_reference_point_ids"] == [point_id]
    assert feature["reference_reasons"][point_id] == f"consumed_by_{fillet['id']}"  # OCCT history knows the corner was consumed


def test_the_same_edit_without_history_is_ambiguous_and_flagged():
    part_id, extrude, fillet, edge_index, sketch, point_id = _comb_with_reference_to_the_middle_notch()
    sketch_obj = all_sketches()[sketch["sketch_id"]]
    sketch_obj.external_references[point_id] = dataclasses.replace(sketch_obj.external_references[point_id], lineage=None)  # as an old file would
    _move_fillet(part_id, extrude["id"], fillet["id"], edge_index)
    feature = _feature(part_id, sketch["id"])
    assert feature["lost_reference_point_ids"] == [point_id]
    assert feature["reference_reasons"][point_id] == "ambiguous"
    decision = sketch_obj.external_reference_decisions[point_id]
    assert len(decision.candidates) >= 2  # the twins, offered to the re-attach UI


# --- persistence -----------------------------------------------------------------------------------------------


def test_the_signature_and_lineage_survive_a_native_save_and_load():
    part_id, _, extrude, _ = _box()
    _fillet(part_id, extrude["id"], 0)
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    original = _ref(sketch, point_id)
    document = get_document()
    data = json.loads(json.dumps(export_native(document, all_sketches(), part_id)))
    _, sketches = import_native(data)
    loaded = sketches[sketch["sketch_id"]].external_references[point_id]
    assert loaded.signature == original.signature
    assert loaded.lineage == original.lineage
    assert (loaded.body_id, loaded.vertex_index) == (original.body_id, original.vertex_index)


def test_a_file_saved_before_signatures_existed_loads_and_adopts_one_on_its_first_refresh():
    part_id, _, extrude, _ = _box()
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    data = json.loads(json.dumps(export_native(get_document(), all_sketches(), part_id)))
    saved = [ref for entry in data["sketches"] for ref in entry["external_references"]]
    assert saved and all("signature" in ref and "lineage" in ref for ref in saved)  # what is written now
    for ref in saved:
        ref.pop("signature")
        ref.pop("lineage")
    assert all(set(ref) == {"point_id", "body_id", "vertex_index"} for ref in saved)  # the legacy shape
    _, sketches = import_native(data)
    legacy = sketches[sketch["sketch_id"]].external_references[point_id]
    assert legacy.signature is None and legacy.lineage is None
    all_sketches()[sketch["sketch_id"]].external_references[point_id] = legacy  # as if the file had been opened
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"]
    assert _ref(sketch, point_id).signature is not None  # adopted on trust, once


# --- the routes ---------------------------------------------------------------------------------------------------


def _lost_reference_setup():
    part_id, _, extrude, _ = _box()
    fillet = _fillet(part_id, extrude["id"], 0)
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    edge_at_corner = next(e for e, ends in _pristine_box_edge_endpoints().items() if CORNER in ends)
    _json(
        client.patch(
            f"/document/parts/{part_id}/fillet-features/{fillet['id']}",
            json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": edge_at_corner}]},
        )
    )
    return part_id, extrude, sketch, point_id


def test_the_status_route_says_which_point_is_lost_and_why():
    part_id, extrude, sketch, point_id = _lost_reference_setup()
    statuses = _json(client.get(f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references"))
    assert [(s["point_id"], s["status"]) for s in statuses] == [(point_id, "lost")]
    assert statuses[0]["reason"].startswith("consumed_by_")


def test_reattaching_a_lost_reference_keeps_the_point_and_what_is_built_on_it():
    part_id, extrude, sketch, point_id = _lost_reference_setup()
    other = _json(  # a Line from the reference Point to a free Point: it must survive the re-attach
        client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 0.0, "y": 0.0})
    )
    line = _json(
        client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": point_id, "end_point_id": other["id"]})
    )
    replacement = _vertex_index_at(part_id, extrude["id"], (0.0, 10.0, 10.0))
    point = _json(
        client.post(
            f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references/{point_id}/reattach",
            json={"body_id": extrude["id"], "vertex_index": replacement},
        )
    )
    assert point["id"] == point_id and (point["x"], point["y"]) == (0.0, 10.0) and point["is_locked"]
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"]
    assert _bound_corner(part_id, sketch, point_id) == (0.0, 10.0, 10.0)
    assert line["id"] in {entity["id"] for entity in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines"))}
    assert tuple(round(c, 6) for c in _ref(sketch, point_id).signature.position) == (0.0, 10.0, 10.0)  # the signature was re-captured


def test_reattaching_something_that_is_not_an_external_reference_or_does_not_exist_is_refused():
    part_id, extrude, sketch, point_id = _lost_reference_setup()
    base = f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references"
    free = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 1.0, "y": 1.0}))
    assert client.post(f"{base}/{free['id']}/reattach", json={"body_id": extrude["id"], "vertex_index": 0}).status_code == 404
    assert client.post(f"{base}/{point_id}/reattach", json={"body_id": extrude["id"], "vertex_index": 999}).status_code == 422
    assert client.post(f"{base}/{point_id}/confirm").status_code == 409  # lost: nothing to confirm


def test_confirming_a_potentially_moved_reference_clears_the_flag():
    part_id, _, extrude, _ = _box()
    sketch, point_id = _reference_to(part_id, extrude["id"], CORNER)
    # Make the stored signature stale in a way only the position betrays: pretend the corner used to be elsewhere and was unique-looking.
    obj = all_sketches()[sketch["sketch_id"]]
    ref = obj.external_references[point_id]
    stale = dataclasses.replace(ref.signature, face_normals=((9.0, 0.0, 0.0),), face_kinds=("plane",), valence=2)  # nothing fits: soft path
    obj.external_references[point_id] = dataclasses.replace(ref, signature=stale, lineage=None)
    feature = _feature(part_id, sketch["id"])
    assert feature["moved_reference_point_ids"] == [point_id] and not feature["has_lost_reference"]
    assert feature["reference_reasons"][point_id] == "fingerprint_changed_in_place"
    _json(client.post(f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references/{point_id}/confirm"))
    feature = _feature(part_id, sketch["id"])
    assert feature["moved_reference_point_ids"] == [] and not feature["has_lost_reference"]
    assert fingerprint_matches(_ref(sketch, point_id).signature, _ref(sketch, point_id).signature)


def test_convert_entities_edge_references_both_endpoints_with_signatures_and_stays_idempotent():
    part_id, _, extrude, _ = _box()
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    url = f"/document/parts/{part_id}/features/sketch/{sketch['id']}/convert-entities/edge"
    first = _json(client.post(url, json={"body_id": extrude["id"], "edge_index": 0}))
    again = _json(client.post(url, json={"body_id": extrude["id"], "edge_index": 0}))
    assert first["start_point"]["id"] == again["start_point"]["id"] and first["end_point"]["id"] == again["end_point"]["id"]
    refs = all_sketches()[sketch["sketch_id"]].external_references
    assert len(refs) == 2 and all(r.signature is not None and r.lineage is not None for r in refs.values())


# --- the pure matching rules ---------------------------------------------------------------------------------------


def _sig(position, normals=((0, 0, 1), (0, 1, 0), (1, 0, 0)), valence=3, diagonal=100.0):
    return VertexSignature(position=position, valence=valence, face_normals=tuple(normals), face_kinds=("plane",) * len(normals), body_diagonal=diagonal)


def test_index_still_right_is_ok_even_after_a_large_parametric_move():
    stored = _sig((0, 0, 0))
    decision = decide_reference(stored, 1, [_sig((50, 0, 0), normals=((0, 0, -1), (0, -1, 0), (-1, 0, 0))), _sig((40, 40, 40))])
    assert (decision.status, decision.index) == (ReferenceStatus.OK, 1)


def test_unique_fingerprint_elsewhere_is_followed_when_near_and_flagged_when_far():
    stored = _sig((10, 10, 10))
    other = _sig((0, 0, 0), normals=((0, 0, -1), (0, -1, 0), (-1, 0, 0)))
    near = decide_reference(stored, 0, [other, _sig((11, 10, 10))])
    assert (near.status, near.index, near.method) == (ReferenceStatus.FOLLOWED, 1, "signature")
    far = decide_reference(stored, 0, [other, _sig((90, 90, 90))])
    assert (far.status, far.index, far.reason) == (ReferenceStatus.POTENTIALLY_MOVED, 1, "unique_fingerprint_far")


def test_identical_twins_are_ambiguous_unless_one_is_clearly_nearest():
    stored = _sig((10, 0, 0))
    other = _sig((50, 50, 50), normals=((0, 0, -1), (0, -1, 0), (-1, 0, 0)))
    ambiguous = decide_reference(stored, 0, [other, _sig((0, 0, 0)), _sig((20, 0, 0))])
    assert ambiguous.status == ReferenceStatus.LOST and ambiguous.reason == "ambiguous" and set(ambiguous.candidates) == {1, 2}
    clear = decide_reference(stored, 0, [other, _sig((10.5, 0, 0)), _sig((40, 0, 0))])
    assert (clear.status, clear.index) == (ReferenceStatus.POTENTIALLY_MOVED, 1)
    too_far = decide_reference(stored, 0, [other, _sig((30, 0, 0)), _sig((70, 0, 0))])
    assert too_far.status == ReferenceStatus.LOST


def test_a_changed_fingerprint_with_a_lone_vertex_in_place_is_potentially_moved_otherwise_lost():
    stored = _sig((10, 10, 10))
    reshaped = _sig((10, 10, 10.2), normals=((0, 0, 1), (0, 0.7071, 0.7071), (1, 0, 0)), valence=4)
    soft = decide_reference(stored, 0, [reshaped, _sig((0, 0, 0), valence=2)])
    assert (soft.status, soft.index, soft.reason) == (ReferenceStatus.POTENTIALLY_MOVED, 0, "fingerprint_changed_in_place")
    gone = decide_reference(stored, 0, [_sig((60, 60, 60), valence=2)])
    assert (gone.status, gone.reason) == (ReferenceStatus.LOST, "no_match")


def test_tolerances_are_relative_to_the_body_diagonal():
    small = _sig((10, 10, 10), diagonal=20.0)  # 5 % of 20 = 1
    big = _sig((10, 10, 10), diagonal=2000.0)  # 5 % of 2000 = 100
    moved = _sig((13, 10, 10))
    other = _sig((0, 0, 0), normals=((0, 0, -1), (0, -1, 0), (-1, 0, 0)))
    assert decide_reference(small, 0, [other, moved]).status == ReferenceStatus.POTENTIALLY_MOVED  # 3 away is far for a 20 mm body
    assert decide_reference(big, 0, [other, moved]).status == ReferenceStatus.FOLLOWED  # and close for a 2 m one
