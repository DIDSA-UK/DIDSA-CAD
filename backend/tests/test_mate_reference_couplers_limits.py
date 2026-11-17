"""N1b, test plan item 6: couplers (gear, rack and pinion, screw) and limit mates are stamped and followed like every other mate, and their always-`ok` status
(a coupler measures motion, not position; a limit has a range) never hides a LOST reference: that mate reads `broken`, is left out of every solve, and the
solve's answer names it (plan N-6) instead of failing the group with a 422."""

import dataclasses

import numpy as np

from app.document.subshape_identity import _rebuild
from tests.test_coupler_mates import _gear_mate, _motion, _occs, gear_scene
from tests.test_limit_mates import _limit, slider_scene
from tests.test_mate_reference_identity import _json, _mate, _refs, _write_index, client


def _lose(root, mate_id, path):
    """A reference whose Body is gone (a deleted body: lost, `body_missing`), the plain way to make one lost."""
    from tests.test_mate_reference_identity import _stored_mate

    mate = _stored_mate(root, mate_id)
    mate.references = [
        _rebuild(entity, f"references[{i}]", lambda p, ref: dataclasses.replace(ref, body_id="no-such-body") if p == path else ref) for i, entity in enumerate(mate.references)
    ]


def test_a_gear_coupler_is_signed_and_followed():
    root, _plate, shaft = gear_scene()
    mate = _gear_mate(root, shaft)
    assert all(ref.signature is not None for ref in _refs(root, mate["id"]).values())
    assert mate["held"] is False and mate["status"] == "ok"
    path = "references[0].subshape_ref"
    original = _refs(root, mate["id"])[path].index
    _write_index(root, mate["id"], path, (original + 1) % 3)  # the shaft has three faces: the cylinder and its two ends
    listed = _mate(root, mate["id"])
    assert path in listed["followed_references"] and listed["held"] is False and listed["status"] == "ok"
    assert _refs(root, mate["id"])[path].index == original


def test_a_gear_coupler_with_a_lost_reference_is_broken_and_left_out_of_the_solve():
    root, _plate, shaft = gear_scene()
    mate = _gear_mate(root, shaft)
    before = _occs(root)
    _lose(root, mate["id"], "references[1].subshape_ref")
    listed = _mate(root, mate["id"])
    assert listed["lost_references"] == ["references[1].subshape_ref"] and listed["reference_reasons"] == {"references[1].subshape_ref": "body_missing"}
    assert listed["status"] == "broken"  # a coupler is always `ok` otherwise: it must not hide this
    assert listed["held"] is False  # nothing to confirm: the face has to be picked again
    out = _motion(root, "shaft-a", {})
    assert out["converged"] and out["held_mate_ids"] == [mate["id"]]  # the group still solves, without the coupler, and names it
    assert _occs(root) == before


def test_a_limit_mate_is_signed_followed_and_a_lost_reference_reads_broken():
    root, block, stop = slider_scene()
    made = _limit(root, block, stop, limit_min=0.0, limit_max=30.0)
    assert made.status_code == 201, made.text
    mate = made.json()
    assert all(ref.signature is not None for ref in _refs(root, mate["id"]).values())
    assert mate["held"] is False and mate["status"] == "ok"
    path = "references[1].subshape_ref"
    original = _refs(root, mate["id"])[path].index
    _write_index(root, mate["id"], path, (original + 1) % 6)
    listed = _mate(root, mate["id"])
    assert path in listed["followed_references"] and listed["status"] == "ok" and abs(listed["limit_value"] - 20.0) < 1e-6
    assert _refs(root, mate["id"])[path].index == original
    _lose(root, mate["id"], path)
    listed = _mate(root, mate["id"])
    assert listed["lost_references"] == [path] and listed["status"] == "broken"
    out = _motion(root, "block", {})
    assert out["converged"] and out["held_mate_ids"] == [mate["id"]]


def test_a_rack_and_pinion_and_a_screw_are_signed_edges_and_faces():
    from tests.test_coupler_mates import rack_scene, screw_scene

    for scene in (rack_scene, screw_scene):
        out = scene()
        root = out[0]
        mates = _json(client.get(f"/document/parts/{root}/mates"))
        couplers = [m for m in mates if m["type"] in ("rack_pinion", "screw")]
        assert couplers, scene.__name__
        from app.document.subshape_identity import iter_mate_subshape_refs
        from tests.test_mate_reference_identity import _stored_mate

        for m in couplers:
            refs = iter_mate_subshape_refs(_stored_mate(root, m["id"]))
            assert refs and all(r.signature is not None for _p, r in refs), (scene.__name__, m["type"])
