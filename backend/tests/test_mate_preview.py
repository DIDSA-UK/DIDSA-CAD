"""Mate ghost preview and atomic create (`docs/mate-solution-choice-plan.md`, Phase 1).

* F4.1: the py-slvs fallback of a single-member group must see the preview's hypothetical mate;
* F4.3: the preview lists every member it moves (`members`), not just the driven occurrence;
* F6: `POST /mates?solve=...` stores the mate with the solved poses only when the solve converges.
"""

import numpy as np

from tests import table_top_fixture as tt
from tests.test_assembly_group import _face, _compose
from tests.test_assembly_minimal_movement import _mate as _bar_mate, _poses, _scene as _bar_scene
from tests.test_assembly_group_mitre_chain import _face as _bar_face, _MITRE_END, _MITRE_START
from tests.test_assembly_solver import _make_box_part, client

_IDENTITY = {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}


def _close(a: dict, b: dict, tol: float = 1e-6) -> bool:
    return np.allclose(a["translation"], b["translation"], atol=tol) and np.isclose(
        a["rotation_angle_degrees"], b["rotation_angle_degrees"], atol=tol
    )


def _preview(root: str, occurrence: str, payload: dict, movement: str = "auto") -> dict:
    response = client.post(
        f"/document/parts/{root}/occurrences/{occurrence}/preview-mate-solve", params={"movement": movement}, json=payload
    )
    assert response.status_code == 200, response.text
    return response.json()


def _table_top_from_identity() -> str:
    root = tt.import_table_top(client, keep_mates=False)
    assert client.patch(f"/document/parts/{root}/occurrences/{tt.PLATE}", json={"transform": _IDENTITY}).status_code == 200
    return root


def test_preview_of_the_tester_s_distance_mate_converges_and_matches_the_stored_solve():
    """F4.1: from the identity pose Gauss-Newton alone cannot reach this mate, so the preview needs the py-slvs fallback -
    which used to drop the hypothetical mate, leaving the preview unconverged (no ghost) although Confirm worked."""
    root = _table_top_from_identity()
    payload = tt.table_top_mate_payloads()[1]
    ghost = _preview(root, tt.PLATE, payload)
    assert ghost["converged"] and ghost["transform"] is not None
    # Confirm (the atomic create) stores what the ghost showed
    assert client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json=payload).status_code == 201
    stored = {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}[tt.PLATE]
    assert _close(ghost["transform"], stored)


def test_group_preview_lists_the_followers_that_move():
    """F4.3: with `movement=group` a follower slides when the mate is confirmed; the ghost must show it too."""
    root = _bar_scene()
    _bar_mate(root, "bar1", "bar2")
    assert client.post(f"/document/parts/{root}/occurrences/bar2/solve").status_code == 200
    before = _poses(root)
    payload = {
        "type": "coincident",
        "references": [_bar_face("bar2", _MITRE_END), _bar_face("bar3", _MITRE_START)],
        "flipped": False,
    }
    ghost = _preview(root, "bar3", payload, movement="group")
    assert ghost["converged"] and ghost["movement_used"] == "group"
    members = {m["occurrence_id"]: m["transform"] for m in ghost["members"]}
    assert ghost["members"][0]["occurrence_id"] == "bar3"  # the driven one first
    assert _close(members["bar3"], ghost["transform"])
    assert "bar2" in members and not _close(members["bar2"], before["bar2"], tol=1.0)
    assert "bar1" not in members and "bar4" not in members  # unmoved members are not ghosted
    # What the ghost shows is what Confirm stores.
    assert client.post(f"/document/parts/{root}/mates", json=payload).status_code == 201
    assert client.post(f"/document/parts/{root}/occurrences/bar3/solve", params={"movement": "group"}).status_code == 200
    after = _poses(root)
    for oid, transform in members.items():
        assert _close(transform, after[oid]), oid


def test_minimal_preview_lists_only_the_driven_occurrence():
    root = _bar_scene()
    _bar_mate(root, "bar1", "bar2")
    assert client.post(f"/document/parts/{root}/occurrences/bar2/solve").status_code == 200
    payload = {
        "type": "coincident",
        "references": [_bar_face("bar2", _MITRE_END), _bar_face("bar3", _MITRE_START)],
        "flipped": False,
    }
    ghost = _preview(root, "bar3", payload, movement="minimal")
    assert [m["occurrence_id"] for m in ghost["members"]] == ["bar3"]


def test_unconverged_preview_has_no_members():
    root = _table_top_from_identity()
    payload = {**tt.table_top_mate_payloads()[1], "value": None}
    ghost = _preview(root, tt.PLATE, payload)
    assert ghost["converged"] is False and ghost["members"] == []


# ---- atomic create / edit (F6) ---------------------------------------------------------------------------------------


def _bracket_scene():
    """Base 20 x 20 x 10, bracket 8 x 8 x 4 floating above it, with the DISTANCE 14 mate between the bracket's bottom and the
    base's top stored and solved from above (bracket bottom at z = 24)."""
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    root = _compose(base, [("bracket", bracket, (5.0, 5.0, 30.0))])
    payload = {
        "type": "distance",
        "references": [{"occurrence_id": "bracket", **_face(bracket, (0, 0, -1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}],
        "value": 14.0,
        "flipped": False,
    }
    assert client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json=payload).status_code == 201
    conflicting = {
        "type": "coincident",
        "references": [{"occurrence_id": "bracket", **_face(bracket, (0, 0, 1))}, {"occurrence_id": "", **_face(base, (0, 0, -1))}],
        "flipped": False,
    }
    return root, conflicting


def _z(root: str) -> float:
    return client.get(f"/document/parts/{root}/occurrences").json()[0]["transform"]["translation"][2]


def test_atomic_create_stores_the_mate_and_the_solved_pose_together():
    root, _conflicting = _bracket_scene()
    assert abs(_z(root) - 24.0) < 1e-6
    mates = client.get(f"/document/parts/{root}/mates").json()
    assert [m["type"] for m in mates] == ["distance"]


def test_atomic_create_that_does_not_converge_stores_nothing():
    """F6: the second mate can only hold on the other side of the first, which Gauss-Newton cannot cross. The refused mate
    must not stay behind (it used to, leaving the assembly over-constrained and a second Confirm adding a duplicate).
    Phase 2b names the refusal: the first (auto) mate would have to move to its other side, which the user confirms."""
    root, conflicting = _bracket_scene()
    before = client.get(f"/document/parts/{root}/occurrences").json()
    for _ in range(2):  # a retry must not stack a duplicate either
        response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json=conflicting)
        assert response.status_code == 422, response.text
        assert response.json()["detail"]["type"] == "branch_change_needed"
    assert [m["type"] for m in client.get(f"/document/parts/{root}/mates").json()] == ["distance"]
    assert client.get(f"/document/parts/{root}/occurrences").json() == before
    # The plain create (no `solve`) still stores it, as before.
    assert client.post(f"/document/parts/{root}/mates", json=conflicting).status_code == 201


def test_atomic_create_reports_the_movement_used():
    root, _ = _bracket_scene()
    base_mate = client.get(f"/document/parts/{root}/mates").json()[0]
    assert client.delete(f"/document/parts/{root}/mates/{base_mate['id']}").status_code == 204
    payload = {k: base_mate[k] for k in ("type", "references", "value", "flipped")}
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json=payload)
    assert response.status_code == 201 and response.headers["X-Movement-Used"] in ("minimal", "group")


def test_atomic_create_with_an_explicit_fixed_occurrence_is_refused():
    root, conflicting = _bracket_scene()
    client.patch(f"/document/parts/{root}/occurrences/bracket", json={"fixed": True})
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": "bracket"}, json=conflicting)
    assert response.status_code == 422 and response.json()["detail"]["type"] == "occurrence_is_fixed"


def test_atomic_edit_keeps_the_old_values_when_the_solve_fails():
    root, conflicting = _bracket_scene()
    mate = client.get(f"/document/parts/{root}/mates").json()[0]
    # A second, stored-but-unsolved mate that contradicts a larger distance: editing the value then cannot converge.
    assert client.post(f"/document/parts/{root}/mates", json=conflicting).status_code == 201
    before = client.get(f"/document/parts/{root}/occurrences").json()
    response = client.patch(f"/document/parts/{root}/mates/{mate['id']}", params={"solve": "auto"}, json={"value": 30.0})
    assert response.status_code == 422, response.text
    assert client.get(f"/document/parts/{root}/mates").json()[0]["value"] == 14.0
    assert client.get(f"/document/parts/{root}/occurrences").json() == before


def test_atomic_edit_stores_the_new_value_and_the_pose():
    root, _ = _bracket_scene()
    mate = client.get(f"/document/parts/{root}/mates").json()[0]
    response = client.patch(f"/document/parts/{root}/mates/{mate['id']}", params={"solve": "auto"}, json={"value": 20.0})
    assert response.status_code == 200, response.text
    assert response.json()["value"] == 20.0 and abs(_z(root) - 30.0) < 1e-6


def test_preview_of_an_edit_replaces_the_stored_mate_instead_of_fighting_it():
    root, _ = _bracket_scene()
    mate = client.get(f"/document/parts/{root}/mates").json()[0]
    revised = {k: mate[k] for k in ("type", "references", "flipped")} | {"value": 20.0}
    url = f"/document/parts/{root}/occurrences/bracket/preview-mate-solve"
    # As a NEW mate the revised value contradicts the stored 14 mm one between the same two faces...
    assert client.post(url, params={"movement": "auto"}, json=revised).json()["converged"] is False
    # ...as an edit it replaces it, and the ghost is where the stored edit then lands.
    ghost = client.post(url, params={"movement": "auto", "replace_mate_id": mate["id"]}, json=revised).json()
    assert ghost["converged"] and abs(ghost["transform"]["translation"][2] - 30.0) < 1e-6
    assert abs(_z(root) - 24.0) < 1e-6  # the preview stored nothing
    assert client.post(url, params={"replace_mate_id": "nope"}, json=revised).status_code == 404
