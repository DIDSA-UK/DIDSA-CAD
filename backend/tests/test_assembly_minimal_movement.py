"""Minimal movement mode (`minimal_movement=true` on `/solve` and `/preview-mate-solve`) and edge-to-edge COINCIDENT.

Uses the mitred frame member (`data/mitred_frame_member.didsa.json`): `bar1` grounded, three bars rough-placed by
swipe-sized errors. With only mitre-face mates the earlier bars keep free motion, so the default group solve slides
`bar2` while solving `bar3`; minimal movement must move `bar3` alone.
"""

import numpy as np

from tests.test_assembly_group_mitre_chain import _BODY, _FRAME, _MITRE_END, _MITRE_START, _ROUGH, _face
from tests.test_assembly_solver import client

_EDGE_OUTER_END, _EDGE_OUTER_START = 3, 0


def _scene():
    assert client.post("/document/new").status_code == 201
    root = client.post("/document/parts", json={"name": "Frame"}).json()["id"]
    for n in range(1, 5):
        assert client.post(f"/document/parts/{root}/add-component", json={"component": _FRAME, "occurrence_id": f"bar{n}"}).status_code == 200
    for oid, transform in _ROUGH.items():
        assert client.patch(f"/document/parts/{root}/occurrences/{oid}", json={"transform": transform}).status_code == 200
    return root


def _poses(root):
    return {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}


def _mate(root, a, b, mtype="coincident", faces=True, ia=_MITRE_END, ib=_MITRE_START):
    kind = "face" if faces else "edge"
    ref = lambda oid, i: {"occurrence_id": oid, "subshape_ref": {"body_id": _BODY, "shape_type": kind, "index": i}}
    r = client.post(f"/document/parts/{root}/mates", json={"type": mtype, "references": [ref(a, ia), ref(b, ib)], "flipped": False})
    assert r.status_code == 201, r.text


def _build_to_bar3(root, minimal):
    _mate(root, "bar1", "bar2")
    assert client.post(f"/document/parts/{root}/occurrences/bar2/solve").status_code == 200
    _mate(root, "bar2", "bar3")
    before = _poses(root)
    r = client.post(f"/document/parts/{root}/occurrences/bar3/solve", params={"minimal_movement": minimal})
    assert r.status_code == 200, r.text
    return before, _poses(root)


def _moved(a, b):
    return float(np.linalg.norm(np.array(a["translation"]) - np.array(b["translation"]))) + abs(a["rotation_angle_degrees"] - b["rotation_angle_degrees"])


def test_default_solve_lets_earlier_bar_follow():
    before, after = _build_to_bar3(_scene(), minimal=False)
    assert _moved(before["bar2"], after["bar2"]) > 1.0  # the group solve slid the earlier bar


def test_minimal_movement_moves_only_the_driven_bar():
    root = _scene()
    before, after = _build_to_bar3(root, minimal=True)
    for oid in ("bar1", "bar2", "bar4"):
        assert before[oid] == after[oid], oid
    assert _moved(before["bar3"], after["bar3"]) > 0.1  # bar3 did move to meet its mate
    motion = client.post(f"/document/parts/{root}/occurrences/bar3/mate-motion", json={}).json()
    assert motion["converged"] and motion["quality"]["residual_inf"] <= 1e-6  # and the mate really holds


def test_minimal_movement_preview_matches_its_solve():
    root = _scene()
    _mate(root, "bar1", "bar2")
    assert client.post(f"/document/parts/{root}/occurrences/bar2/solve").status_code == 200
    payload = {"type": "coincident", "references": [_face("bar2", _MITRE_END), _face("bar3", _MITRE_START)], "flipped": False}
    ghost = client.post(f"/document/parts/{root}/occurrences/bar3/preview-mate-solve", params={"minimal_movement": True}, json=payload).json()
    assert ghost["converged"]
    client.post(f"/document/parts/{root}/mates", json=payload)
    solved = client.post(f"/document/parts/{root}/occurrences/bar3/solve", params={"minimal_movement": True}).json()
    assert np.allclose(ghost["transform"]["translation"], solved["transform"]["translation"], atol=1e-6)


def test_coincident_on_two_edges_is_the_axis_lock_concentric_gives():
    results = {}
    for mtype in ("coincident", "concentric"):
        root = _scene()
        _mate(root, "bar1", "bar2", mtype, faces=False, ia=_EDGE_OUTER_END, ib=_EDGE_OUTER_START)
        r = client.post(f"/document/parts/{root}/occurrences/bar2/solve")
        assert r.status_code == 200, f"{mtype}: {r.text}"
        results[mtype] = r.json()["transform"]
    assert np.allclose(results["coincident"]["translation"], results["concentric"]["translation"], atol=1e-6)
    assert np.isclose(results["coincident"]["rotation_angle_degrees"], results["concentric"]["rotation_angle_degrees"], atol=1e-6)
