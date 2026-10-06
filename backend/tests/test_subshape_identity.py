"""Reference identity for `SubShapeRef` consumers (docs/reference-identity-design.md): a Fillet's edge, a Create Plane's face, ... carry a geometric signature, are
re-found when an upstream edit renumbers the Body, and are flagged (never silently rebound) when they cannot be found. Needs a real pythonocc-core environment."""

import dataclasses
import json

import pytest

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import SubShapeRef, SubShapeType
from app.document.native_format import export_native, import_native
from app.document.reference_signature import BodyEdgeMeasurer, BodyFaceMeasurer
from app.document.router import get_part_or_404
from app.document.store import get_document
from app.document.subshape_identity import (
    bodies_before_feature,
    iter_subshape_refs,
    map_subshape_refs,
    refresh_feature_subshape_refs,
)
from app.sketch.reference_signature import EdgeSignature, FaceSignature
from app.sketch.store import all_sketches
from tests.test_reference_identity import _box, _feature, _fillet, _json, _pristine_box_edge_endpoints, client


def _vertical_edge_index(part_id: str, body_id: str, x: float, y: float) -> int:
    """The straight edge parallel to z at (x, y) in the Part as it stands now."""
    body = compute_part_bodies(get_part_or_404(part_id))[body_id]
    measurer = BodyEdgeMeasurer(body)
    return next(
        i
        for i, sig in enumerate(measurer.all())
        if sig.curve_kind == "line" and abs(sig.position[0] - x) < 1e-6 and abs(sig.position[1] - y) < 1e-6 and abs(sig.direction[2]) > 0.99
    )


def _top_face_index(part_id: str, body_id: str) -> int:
    body = compute_part_bodies(get_part_or_404(part_id))[body_id]
    return next(i for i, sig in enumerate(BodyFaceMeasurer(body).all()) if sig.surface_kind == "plane" and sig.direction[2] > 0.99)


def _feature_ref_edge_midpoint(part_id: str, feature_id: str) -> tuple[float, float, float]:
    """The first edge reference of a Fillet / Chamfer feature, in the Bodies the feature sees as input, as (x, y, 5.0) when it is a straight edge parallel to z
    (a neighbouring fillet may shorten it and move its midpoint along z, which is not the edge moving) - so `(10.0, 10.0, 5.0)` means "the vertical edge at
    (10, 10)"."""
    part = get_part_or_404(part_id)
    feature = part.get_feature(feature_id)
    ref = feature.edge_refs[0]
    bodies = bodies_before_feature(part, feature_id)
    sig = BodyEdgeMeasurer(bodies[ref.body_id]).signature(ref.index)
    vertical = sig.curve_kind == "line" and abs(sig.direction[2]) > 0.99
    return (round(sig.position[0], 6), round(sig.position[1], 6), 5.0 if vertical else sig.position[2])


def _a_box_with_a_second_fillet_on_the_far_vertical_edge():
    """Box, F1 rounding one edge, F2 rounding the vertical edge at (10, 10). Returns (part, extrude id, f1, f2)."""
    part_id, _, extrude, _ = _box()
    f1 = _fillet(part_id, extrude["id"], 0)
    index = _vertical_edge_index(part_id, extrude["id"], 10.0, 5.0 + 5.0)
    f2 = _fillet(part_id, extrude["id"], index, radius=1.0)
    return part_id, extrude["id"], f1, f2


def _move_f1(part_id, body_id, f1_id, edge_index):
    _json(
        client.patch(
            f"/document/parts/{part_id}/fillet-features/{f1_id}",
            json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": edge_index}]},
        )
    )


# --- stamping -------------------------------------------------------------------------------------------------------


def test_creating_a_fillet_stamps_its_edge_with_a_signature_and_a_healthy_response_flags_nothing():
    part_id, body_id, f1, f2 = _a_box_with_a_second_fillet_on_the_far_vertical_edge()
    feature = _feature(part_id, f2["id"])
    assert not feature["has_lost_reference"]
    assert feature["lost_references"] == feature["moved_references"] == feature["followed_references"] == []
    ref = get_part_or_404(part_id).get_feature(f2["id"]).edge_refs[0]
    assert isinstance(ref.signature, EdgeSignature)
    assert ref.signature.curve_kind == "line" and abs(ref.signature.direction[2]) > 0.99
    assert tuple(round(c, 6) for c in ref.signature.position[:2]) == (10.0, 10.0)


def test_a_signature_never_changes_a_features_equality_repr_or_cache_fingerprint():
    ref = SubShapeRef(body_id="b", shape_type=SubShapeType.EDGE, index=3)
    signed = dataclasses.replace(ref, signature=EdgeSignature(position=(1.0, 2.0, 3.0), curve_kind="line"))
    assert ref == signed and hash(ref) == hash(signed) and repr(ref) == repr(signed)


# --- following an upstream topology change --------------------------------------------------------------------------


def _try_move_f1(part_id, body_id, f1_id, edge_index) -> bool:
    """PATCHes the upstream fillet onto `edge_index`; False when the route refuses it (an edge index is validated against the Part as the PATCH sees it, which
    includes the downstream fillet, so some indices are legitimately rejected)."""
    response = client.patch(
        f"/document/parts/{part_id}/fillet-features/{f1_id}",
        json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": edge_index}]},
    )
    return response.status_code < 300


def _assert_f2_still_on_the_far_vertical_edge_or_flagged(part_id: str, f2_id: str):
    feature = _feature(part_id, f2_id)
    if feature["has_lost_reference"]:
        assert feature["lost_references"] == ["edge_refs[0]"]
        return "lost"
    assert _feature_ref_edge_midpoint(part_id, f2_id) == (10.0, 10.0, 5.0)
    return "followed"


def test_a_downstream_fillet_keeps_its_edge_or_is_flagged_whenever_an_upstream_fillet_moves():
    outcomes = []
    for new_edge in range(1, 12):
        part_id, body_id, f1, f2 = _a_box_with_a_second_fillet_on_the_far_vertical_edge()
        if not _try_move_f1(part_id, body_id, f1["id"], new_edge):
            continue
        outcomes.append(_assert_f2_still_on_the_far_vertical_edge_or_flagged(part_id, f2["id"]))
    assert len(outcomes) >= 3 and "followed" in outcomes


def test_the_stored_index_is_updated_and_the_response_says_it_was_followed_when_the_numbering_changed():
    seen_follow = False
    for new_edge in range(1, 12):
        part_id, body_id, f1, f2 = _a_box_with_a_second_fillet_on_the_far_vertical_edge()
        before = get_part_or_404(part_id).get_feature(f2["id"]).edge_refs[0].index
        if not _try_move_f1(part_id, body_id, f1["id"], new_edge):
            continue
        feature = _feature(part_id, f2["id"])
        after = get_part_or_404(part_id).get_feature(f2["id"]).edge_refs[0].index
        if after != before and not feature["has_lost_reference"]:
            seen_follow = True
            assert feature["followed_references"] == ["edge_refs[0]"]
            assert _feature_ref_edge_midpoint(part_id, f2["id"]) == (10.0, 10.0, 5.0)
    assert seen_follow, "none of the probe edits renumbered the Body: the test no longer exercises following"


def test_a_fillet_whose_edge_is_consumed_upstream_is_flagged_lost_and_never_lands_on_another_edge():
    part_id, body_id, f1, f2 = _a_box_with_a_second_fillet_on_the_far_vertical_edge()
    # F1 rounds the very edge F2 named. (The PATCH validates its edge index against the Part as it stands - including F2 - so the index that means "that
    # edge" there is the one in the Part with F2 applied; find it the same way the route will.)
    flagged = False
    for candidate in range(12):
        fresh_part, fresh_body, fresh_f1, fresh_f2 = _a_box_with_a_second_fillet_on_the_far_vertical_edge()
        if not _try_move_f1(fresh_part, fresh_body, fresh_f1["id"], candidate):
            continue
        feature = _feature(fresh_part, fresh_f2["id"])
        if feature["has_lost_reference"]:
            flagged = True
            assert feature["lost_references"] == ["edge_refs[0]"]
            assert feature["reference_reasons"]["edge_refs[0]"] in ("no_match", "ambiguous")
    assert flagged, "no probe edit consumed the downstream fillet's edge"
    return
    feature = _feature(part_id, f2["id"])
    assert feature["has_lost_reference"]
    assert feature["lost_references"] == ["edge_refs[0]"]
    assert feature["reference_reasons"]["edge_refs[0]"] in ("no_match", "ambiguous")


def _vertical_edge_index_in_pristine_box(x: float, y: float) -> int:
    for index, (a, b) in _pristine_box_edge_endpoints().items():
        if {a, b} == {(x, y, 0.0), (x, y, 10.0)}:
            return index
    raise AssertionError("no such edge")


def test_replay_fails_closed_for_a_signed_reference_that_cannot_be_found():
    part_id, body_id, f1, f2 = _a_box_with_a_second_fillet_on_the_far_vertical_edge()
    part = get_part_or_404(part_id)
    bodies = bodies_before_feature(part, f2["id"])
    ref = part.get_feature(f2["id"]).edge_refs[0]
    resolve_subshape_from_bodies(bodies, ref)  # healthy: resolves
    stale = dataclasses.replace(ref, signature=dataclasses.replace(ref.signature, curve_kind="circle", position=(500.0, 500.0, 500.0), centre=(500.0, 500.0, 500.0)))
    with pytest.raises(Exception) as caught:
        resolve_subshape_from_bodies(bodies, stale)
    detail = caught.value.detail
    assert detail["type"] == "missing_reference" and detail["reason"] == "no_match"


# --- a Create Plane on a face ---------------------------------------------------------------------------------------


def _plane_on_top_face(part_id: str, body_id: str, offset: float = 5.0):
    return _json(
        client.post(
            f"/document/parts/{part_id}/create-plane-features",
            json={
                "plane_type": "offset_face",
                "face_refs": [{"face_ref": {"body_id": body_id, "shape_type": "face", "index": _top_face_index(part_id, body_id)}}],
                "offset": offset,
            },
        )
    )


@pytest.mark.parametrize("new_edge", [1, 3, 5, 8])
def test_a_plane_on_the_top_face_stays_on_the_top_face_when_an_upstream_fillet_moves(new_edge: int):
    part_id, _, extrude, _ = _box()
    f1 = _fillet(part_id, extrude["id"], 0)
    plane = _plane_on_top_face(part_id, extrude["id"])
    assert plane["normal"] == pytest.approx([0.0, 0.0, 1.0])
    _move_f1(part_id, extrude["id"], f1["id"], new_edge)
    feature = _feature(part_id, plane["id"])
    assert not feature["has_lost_reference"], feature
    assert feature["normal"] == pytest.approx([0.0, 0.0, 1.0])
    assert feature["origin"][2] == pytest.approx(15.0)  # 10 (top face) + 5 (offset)


def test_the_plane_probe_really_renumbers_the_face_and_the_response_says_it_was_followed():
    followed_somewhere = False
    for new_edge in [1, 3, 5, 8]:
        part_id, _, extrude, _ = _box()
        f1 = _fillet(part_id, extrude["id"], 0)
        plane = _plane_on_top_face(part_id, extrude["id"])
        before = get_part_or_404(part_id).get_feature(plane["id"]).face_refs[0].face_ref.index
        _move_f1(part_id, extrude["id"], f1["id"], new_edge)
        feature = _feature(part_id, plane["id"])
        after = get_part_or_404(part_id).get_feature(plane["id"]).face_refs[0].face_ref.index
        if after != before:
            followed_somewhere = True
            assert feature["followed_references"] == ["face_refs[0].face_ref"]
    assert followed_somewhere


def test_a_plane_on_a_face_that_an_upstream_extrude_change_moves_follows_it():
    part_id, _, extrude, _ = _box()
    plane = _plane_on_top_face(part_id, extrude["id"])
    _json(client.patch(f"/document/parts/{part_id}/extrude-features/{extrude['id']}", json={"end_distance": 20.0}))
    feature = _feature(part_id, plane["id"])
    assert not feature["has_lost_reference"]
    assert feature["origin"][2] == pytest.approx(25.0)


# --- the walker -----------------------------------------------------------------------------------------------------


def test_the_walker_finds_and_replaces_references_nested_inside_a_features_value_types():
    part_id, _, extrude, _ = _box()
    plane = _plane_on_top_face(part_id, extrude["id"])
    feature = get_part_or_404(part_id).get_feature(plane["id"])
    paths = [path for path, _ in iter_subshape_refs(feature)]
    assert paths == ["face_refs[0].face_ref"]
    changed = map_subshape_refs(feature, lambda path, ref: dataclasses.replace(ref, index=ref.index + 100))
    assert changed and feature.face_refs[0].face_ref.index >= 100
    assert not map_subshape_refs(feature, lambda path, ref: ref)  # identity map changes nothing


def test_a_feature_without_sub_shape_references_is_left_alone():
    part_id, base, extrude, _ = _box()
    assert refresh_feature_subshape_refs(get_part_or_404(part_id), get_part_or_404(part_id).get_feature(extrude["id"])) is None


# --- persistence -------------------------------------------------------------------------------------------------------


def test_edge_and_face_signatures_survive_a_native_save_and_load_and_a_legacy_file_loads_unsigned():
    part_id, body_id, f1, f2 = _a_box_with_a_second_fillet_on_the_far_vertical_edge()
    plane = _plane_on_top_face(part_id, body_id)
    _feature(part_id, plane["id"])  # stamped by its response
    data = json.loads(json.dumps(export_native(get_document(), all_sketches(), part_id)))
    document, _ = import_native(data)
    part = document.parts[part_id]
    loaded_edge = part.get_feature(f2["id"]).edge_refs[0].signature
    loaded_face = part.get_feature(plane["id"]).face_refs[0].face_ref.signature
    original = get_part_or_404(part_id)
    assert loaded_edge == original.get_feature(f2["id"]).edge_refs[0].signature and isinstance(loaded_edge, EdgeSignature)
    assert loaded_face == original.get_feature(plane["id"]).face_refs[0].face_ref.signature and isinstance(loaded_face, FaceSignature)

    def strip(node):
        if isinstance(node, dict):
            node.pop("signature", None)
            for value in node.values():
                strip(value)
        elif isinstance(node, list):
            for value in node:
                strip(value)

    strip(data["document"])
    legacy, _ = import_native(data)
    assert legacy.parts[part_id].get_feature(f2["id"]).edge_refs[0].signature is None
