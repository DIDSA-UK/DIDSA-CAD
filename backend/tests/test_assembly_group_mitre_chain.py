"""Regression: a chain of mitre-plane COINCIDENT mates must still solve when the NEWEST bar is the driven one.

Four copies of a mitred 60x60 tube (`data/mitred_frame_member.didsa.json`), `bar1` grounded, rough-placed by swipe-sized
errors (~25 mm / ~7 deg). Mitre mates bar1-2, bar2-3 then bar3-4, each followed by the client's `solve` on the second
pick. Before the follower-weight fallback in `assembly_group.solve_group` the third solve returned 422
`mate_solve_did_not_converge` (Gauss-Newton crawled at residual ~0.8 because the 1e-4-weight followers `bar2`/`bar3` soaked
up a correction their own mates could not absorb), while grabbing `bar3` on the very same mates converged in 3 iterations.
"""

import json
from pathlib import Path

import numpy as np

from app.document.assembly_group import solve_group
from app.document.store import get_document
from tests.test_assembly_solver import client

_FRAME = json.loads((Path(__file__).parent / "data" / "mitred_frame_member.didsa.json").read_text())
_BODY = "e8d7bb68-342f-4421-9ae2-2a6af71d3a28"
_MITRE_START, _MITRE_END = 1, 4
_ROUGH = {
    "bar2": {"translation": [-17.419538, 785.801818, 12.728819], "rotation_axis": [-0.993426, 0.006937, -0.114266], "rotation_angle_degrees": 84.331797},
    "bar3": {"translation": [6.027929, 795.109301, -723.371634], "rotation_axis": [-0.999641, 0.012453, 0.023705], "rotation_angle_degrees": 177.659389},
    "bar4": {"translation": [23.415032, 27.584418, -746.171719], "rotation_axis": [0.999073, -0.04046, 0.014702], "rotation_angle_degrees": 89.041882},
}


def _face(oid, index):
    return {"occurrence_id": oid, "subshape_ref": {"body_id": _BODY, "shape_type": "face", "index": index}}


def test_newest_bar_solves_at_end_of_mitre_chain():
    assert client.post("/document/new").status_code == 201
    root = client.post("/document/parts", json={"name": "Frame"}).json()["id"]
    for n in range(1, 5):
        r = client.post(f"/document/parts/{root}/add-component", json={"component": _FRAME, "occurrence_id": f"bar{n}"})
        assert r.status_code == 200, r.text
    for oid, transform in _ROUGH.items():
        assert client.patch(f"/document/parts/{root}/occurrences/{oid}", json={"transform": transform}).status_code == 200
    for a, b in (("bar1", "bar2"), ("bar2", "bar3"), ("bar3", "bar4")):
        r = client.post(
            f"/document/parts/{root}/mates",
            json={"type": "coincident", "references": [_face(a, _MITRE_END), _face(b, _MITRE_START)], "flipped": False},
        )
        assert r.status_code == 201, r.text
        solved = client.post(f"/document/parts/{root}/occurrences/{b}/solve")
        assert solved.status_code == 200, f"{a}->{b}: {solved.text}"
    document = get_document()
    result = solve_group(document, document.parts[root], "bar4", None)
    assert result.converged
    assert result.quality.residual_inf <= 1e-7
    # the newest bar shares the correction; it is never left unmoved while earlier bars are dragged around
    stored = {o.id: np.array(o.transform.translation) for o in document.parts[root].occurrences}
    assert np.linalg.norm(stored["bar4"] - np.array(_ROUGH["bar4"]["translation"])) < 50.0
