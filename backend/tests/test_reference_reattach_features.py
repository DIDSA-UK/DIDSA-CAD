"""DIDSA-VR plan, phase 4.1 (R-D): a feature whose reference is flagged (`lost_references` / `moved_references`) can be mended from its PATCH: a replacement reference
is re-measured (a fresh signature, the lost flag gone) and the part rebuilds; and a sketch's two corner references of one edge are re-attached with ONE call
(`.../external-references/reattach-edge`, tests at the end). Needs a real pythonocc-core environment."""

import pytest

from app.document.extrude import compute_part_bodies
from app.document.reference_signature import BodyEdgeMeasurer
from app.document.router import get_part_or_404
from app.sketch.store import all_sketches
from tests.test_reference_identity import _box, _feature, _fillet, _json, _reference_to, client, CORNER


def _row(part_id: str, feature_id: str) -> dict:
    return _feature(part_id, feature_id)


def _bodies_before(part_id: str, feature_id: str):
    from app.document.subshape_identity import bodies_before_feature

    return bodies_before_feature(get_part_or_404(part_id), feature_id)


def _straight_edges(bodies: dict, body_id: str) -> list[int]:
    measurer = BodyEdgeMeasurer(bodies[body_id])
    return [i for i in range(measurer.count) if measurer.signature(i).curve_kind == "line"]


def _chamfer(part_id: str, body_id: str, edge_index: int, distance: float = 1.0) -> dict:
    return _json(
        client.post(
            f"/document/parts/{part_id}/chamfer-features",
            json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": edge_index}], "distance": distance},
        )
    )


def _flagged_chamfer_scenario():
    """A box, a fillet on one edge, then a chamfer on another edge of the filleted body; then the fillet is moved onto an edge at the chamfer's corner, which consumes
    the corner the chamfer names. Returns (part id, body id, fillet, chamfer) with the chamfer flagged lost."""
    part_id, _, extrude, _ = _box()
    body_id = extrude["id"]
    fillet = _fillet(part_id, body_id, 0)
    after_fillet = _bodies_before(part_id, fillet["id"])  # the pristine box, what the fillet sees
    # the chamfer's edge: any straight edge of the filleted body that shares no end with edge 0 of the box
    filleted = compute_part_bodies(get_part_or_404(part_id))
    chamfer_edge = _straight_edges(filleted, body_id)[-1]
    chamfer = _chamfer(part_id, body_id, chamfer_edge)
    # try moving the fillet to each other edge until the chamfer's reference is flagged lost
    for new_edge in range(12):
        _json(client.patch(f"/document/parts/{part_id}/fillet-features/{fillet['id']}", json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": new_edge}]}))
        row = _row(part_id, chamfer["id"])
        if row["lost_references"]:
            return part_id, body_id, fillet, chamfer
    pytest.skip("no fillet position consumed the chamfer's corner on this OCCT build")


def test_a_flagged_chamfer_is_mended_by_patching_a_replacement_edge():
    part_id, body_id, fillet, chamfer = _flagged_chamfer_scenario()
    flagged = _row(part_id, chamfer["id"])
    assert flagged["has_lost_reference"] and flagged["lost_references"] == ["edge_refs[0]"]
    before = _bodies_before(part_id, chamfer["id"])
    replacement = next(i for i in _straight_edges(before, body_id) if i != chamfer["edge_refs"][0]["index"])
    patched = _json(client.patch(f"/document/parts/{part_id}/chamfer-features/{chamfer['id']}", json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": replacement}]}))
    assert patched["edge_refs"][0]["index"] == replacement
    row = _row(part_id, chamfer["id"])
    assert not row["has_lost_reference"] and row["lost_references"] == [] and row["moved_references"] == []
    stored = get_part_or_404(part_id).get_feature(chamfer["id"]).edge_refs[0]
    assert stored.signature is not None and stored.lost_reason is None  # re-measured against the body the chamfer sees, not the old one
    assert client.get(f"/document/parts/{part_id}/mesh").status_code == 200  # the part rebuilds


def test_a_replacement_that_does_not_resolve_is_refused_and_the_flag_stays():
    part_id, body_id, fillet, chamfer = _flagged_chamfer_scenario()
    response = client.patch(f"/document/parts/{part_id}/chamfer-features/{chamfer['id']}", json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": 999}]})
    assert response.status_code == 422
    assert _row(part_id, chamfer["id"])["lost_references"] == ["edge_refs[0]"]


def test_a_flagged_fillet_is_mended_the_same_way():
    part_id, _, extrude, _ = _box()
    body_id = extrude["id"]
    first = _chamfer(part_id, body_id, 0)
    chamfered = compute_part_bodies(get_part_or_404(part_id))
    second_edge = _straight_edges(chamfered, body_id)[-1]
    second = _fillet(part_id, body_id, second_edge)
    # move the CHAMFER until the fillet after it loses the corner it names
    flagged = False
    for new_edge in range(12):
        moved = client.patch(f"/document/parts/{part_id}/chamfer-features/{first['id']}", json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": new_edge}]})
        if moved.status_code >= 300:
            continue
        if _row(part_id, second["id"])["lost_references"]:
            flagged = True
            break
    if not flagged:
        pytest.skip("no chamfer position consumed the fillet's corner")
    before = _bodies_before(part_id, second["id"])
    replacement = next(i for i in _straight_edges(before, body_id) if i != second["edge_refs"][0]["index"])
    _json(client.patch(f"/document/parts/{part_id}/fillet-features/{second['id']}", json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": replacement}]}))
    row = _row(part_id, second["id"])
    assert not row["has_lost_reference"] and row["lost_references"] == []


# --- the other consumers: a replacement is accepted, re-measured and the part rebuilds --------------------------------------------
# (A naturally flagged Shell / Mirror / Create Plane needs an upstream feature that consumes a FACE, which a box cannot give; the flag-clearing is shown above for
# the chamfer and the fillet, and here the PATCH contract itself: the replacement is accepted, stamped with its own fresh signature, and the part still builds.)


def _faces(part_id: str, body_id: str):
    from app.document.reference_signature import BodyFaceMeasurer

    return BodyFaceMeasurer(compute_part_bodies(get_part_or_404(part_id))[body_id])


def test_a_shell_takes_a_replacement_face_and_re_measures_it():
    part_id, _, extrude, _ = _box()
    body_id = extrude["id"]
    faces = _faces(part_id, body_id)
    top = next(i for i in range(faces.count) if faces.signature(i).direction[2] > 0.99)
    other = next(i for i in range(faces.count) if faces.signature(i).direction[0] > 0.99)
    shell = _json(
        client.post(
            f"/document/parts/{part_id}/shell-features",
            json={"body_id": body_id, "faces_to_remove": [{"body_id": body_id, "shape_type": "face", "index": top}], "thickness": 1.0, "thickness_direction": "inward"},
        )
    )
    _json(client.patch(f"/document/parts/{part_id}/shell-features/{shell['id']}", json={"faces_to_remove": [{"body_id": body_id, "shape_type": "face", "index": other}]}))
    row = _row(part_id, shell["id"])
    assert row["faces_to_remove"][0]["index"] == other and not row["has_lost_reference"] and row["lost_references"] == []
    stored = get_part_or_404(part_id).get_feature(shell["id"]).faces_to_remove[0]
    assert stored.signature is not None and stored.signature.direction[0] > 0.99  # the face it names now, not the top
    assert client.get(f"/document/parts/{part_id}/mesh").status_code == 200


def test_a_mirror_takes_a_replacement_plane_face_and_re_measures_it():
    part_id, _, extrude, _ = _box()
    body_id = extrude["id"]
    faces = _faces(part_id, body_id)
    side = next(i for i in range(faces.count) if faces.signature(i).direction[0] > 0.99)
    other = next(i for i in range(faces.count) if faces.signature(i).direction[1] > 0.99)
    mirror = _json(
        client.post(
            f"/document/parts/{part_id}/mirror-features",
            json={"source_body_ids": [body_id], "mirror_plane": {"face_ref": {"body_id": body_id, "shape_type": "face", "index": side}}, "merge": "keep_separate"},
        )
    )
    _json(client.patch(f"/document/parts/{part_id}/mirror-features/{mirror['id']}", json={"mirror_plane": {"face_ref": {"body_id": body_id, "shape_type": "face", "index": other}}}))
    row = _row(part_id, mirror["id"])
    assert row["mirror_plane"]["face_ref"]["index"] == other and not row["has_lost_reference"] and row["lost_references"] == []
    assert get_part_or_404(part_id).get_feature(mirror["id"]).mirror_plane.face_ref.signature.direction[1] > 0.99


def test_a_create_plane_takes_a_replacement_face_and_re_measures_it():
    part_id, _, extrude, _ = _box()
    body_id = extrude["id"]
    faces = _faces(part_id, body_id)
    top = next(i for i in range(faces.count) if faces.signature(i).direction[2] > 0.99)
    other = next(i for i in range(faces.count) if faces.signature(i).direction[0] > 0.99)
    plane = _json(
        client.post(
            f"/document/parts/{part_id}/create-plane-features",
            json={"plane_type": "offset_face", "face_refs": [{"face_ref": {"body_id": body_id, "shape_type": "face", "index": top}}], "offset": 5.0},
        )
    )
    _json(client.patch(f"/document/parts/{part_id}/create-plane-features/{plane['id']}", json={"face_refs": [{"face_ref": {"body_id": body_id, "shape_type": "face", "index": other}}]}))
    row = _row(part_id, plane["id"])
    assert row["face_refs"][0]["face_ref"]["index"] == other and not row["has_lost_reference"] and row["lost_references"] == []
    assert get_part_or_404(part_id).get_feature(plane["id"]).face_refs[0].face_ref.signature.direction[0] > 0.99


# --- one pick mends both corners of an edge ----------------------------------------------------------------------------------------


def _edge_with_ends(part_id: str, body_id: str, wanted: set):
    """The index of the straight edge whose two ends are exactly `wanted` (box corner positions), as the Part stands now."""
    from app.document.extrude import edge_endpoint_vertex_refs
    from app.document.models import SubShapeRef, SubShapeType
    from app.document.reference_signature import BodyVertexMeasurer

    bodies = compute_part_bodies(get_part_or_404(part_id))
    vertices = BodyVertexMeasurer(bodies[body_id])
    for edge in _straight_edges(bodies, body_id):
        a, b = edge_endpoint_vertex_refs(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=edge))
        ends = {tuple(round(v, 6) for v in vertices.signature(a.index).position), tuple(round(v, 6) for v in vertices.signature(b.index).position)}
        if ends == wanted:
            return edge
    raise AssertionError(f"no edge with ends {wanted}")


def test_one_call_re_attaches_both_corners_of_an_edge_and_keeps_the_line():
    from tests.test_circle_centre_reference import _convert_edge, _new_sketch

    part_id, _, extrude, _ = _box()  # a 10 x 10 x 10 box from the XY plane
    body_id = extrude["id"]
    sketch = _new_sketch(part_id)
    bottom_front = _edge_with_ends(part_id, body_id, {(0.0, 0.0, 0.0), (10.0, 0.0, 0.0)})
    bottom_back = _edge_with_ends(part_id, body_id, {(0.0, 10.0, 0.0), (10.0, 10.0, 0.0)})
    made = _convert_edge(part_id, sketch, body_id, bottom_front, construction=True)
    line = made["line"]
    ends = [line["start_point_id"], line["end_point_id"]]
    before = {i: (p["x"], p["y"]) for i, p in {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}.items() if i in ends}
    assert sorted(y for _, y in before.values()) == [0.0, 0.0]

    mended = _json(
        client.post(
            f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references/reattach-edge",
            json={"point_ids": ends, "body_id": body_id, "edge_index": bottom_back},
        )
    )
    assert [p["id"] for p in mended] == ends
    after = {p["id"]: (p["x"], p["y"]) for p in mended}
    assert sorted(y for _, y in after.values()) == [10.0, 10.0]
    # each end kept its side: the one that was at x = 0 is still at x = 0 (the pairing that moves the points least)
    for point_id in ends:
        assert after[point_id][0] == pytest.approx(before[point_id][0])
    assert _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines"))[0]["id"] == line["id"]  # the line, and anything built on it, is the same
    refs = all_sketches()[sketch["sketch_id"]].external_references
    assert all(refs[i].signature is not None for i in ends)
    assert not _feature(part_id, sketch["id"])["has_lost_reference"]


def test_re_attaching_an_edge_is_all_or_nothing_and_says_why():
    from tests.test_circle_centre_reference import _convert_edge, _new_sketch

    part_id, _, extrude, _ = _box()
    body_id = extrude["id"]
    sketch = _new_sketch(part_id)
    front = _edge_with_ends(part_id, body_id, {(0.0, 0.0, 0.0), (10.0, 0.0, 0.0)})
    line = _convert_edge(part_id, sketch, body_id, front, construction=True)["line"]
    ends = [line["start_point_id"], line["end_point_id"]]
    url = f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references/reattach-edge"
    assert client.post(url, json={"point_ids": [ends[0], ends[0]], "body_id": body_id, "edge_index": front}).status_code == 422
    assert client.post(url, json={"point_ids": [ends[0], "nope"], "body_id": body_id, "edge_index": front}).status_code == 404
    assert client.post(url, json={"point_ids": ends, "body_id": body_id, "edge_index": 999}).status_code == 422
    after = {p["id"]: (p["x"], p["y"]) for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points")) if p["id"] in ends}
    assert sorted(y for _, y in after.values()) == [0.0, 0.0]  # nothing moved
