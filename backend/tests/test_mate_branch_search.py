"""Branch search for a new mate that needs an earlier mate on its other branch (`docs/mate-solution-choice-plan.md`, Phase 2b).

The F6 scene: base 20 x 20 x 10, bracket 8 x 8 x 4. A DISTANCE 14 between the bracket's bottom and the base's top is solved from above
(bracket bottom z = 24, the mate's side "+"). A COINCIDENT between the bracket's top and the base's bottom can only hold with the bracket
bottom at z = -4, i.e. with the DISTANCE on its other side. Gauss-Newton keeps a mate on its branch, so the search is what finds that.
"""

import numpy as np

from tests import table_top_fixture as tt
from tests.test_assembly_group import _compose, _face
from tests.test_assembly_solver import _make_box_part, client

_IDENTITY = {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}


def _scene(distance_fields: dict | None = None):
    """The F6 scene with the DISTANCE mate stored (side "+"): `distance_fields` adds explicit branch fields (a `user` mate)."""
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    root = _compose(base, [("bracket", bracket, (5.0, 5.0, 30.0))])
    distance = {
        "type": "distance",
        "references": [{"occurrence_id": "bracket", **_face(bracket, (0, 0, -1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}],
        "value": 14.0,
        **(distance_fields or {}),
    }
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json=distance)
    assert response.status_code == 201, response.text
    coincident = {
        "type": "coincident",
        "references": [{"occurrence_id": "bracket", **_face(bracket, (0, 0, 1))}, {"occurrence_id": "", **_face(base, (0, 0, -1))}],
    }
    return root, response.json(), coincident, (base, bracket)


def _preview(root: str, occurrence: str, payload: dict, **params) -> dict:
    response = client.post(f"/document/parts/{root}/occurrences/{occurrence}/preview-mate-solve", params={"movement": "auto", **params}, json=payload)
    assert response.status_code == 200, response.text
    return response.json()


def _mates(root: str) -> list[dict]:
    return client.get(f"/document/parts/{root}/mates").json()


def _pose(root: str, occurrence: str) -> dict:
    return {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}[occurrence]


# ---- F6: the mate that can be moved ------------------------------------------------------------------------------------------


def test_preview_proposes_the_earlier_mates_other_side_and_ghosts_that_placement():
    root, distance, coincident, _ = _scene()
    assert distance["branch_source"] == "auto" and distance["secondary_flip"] is False
    before = _pose(root, "bracket")
    ghost = _preview(root, "bracket", coincident)
    assert ghost["converged"] and abs(ghost["transform"]["translation"][2] - (-4.0)) < 1e-6
    assert ghost["branch_changes"] == [{"mate_id": distance["id"], "field": "secondary_flip", "from": False, "to": True}]
    assert ghost["blocked_by"] == [] and ghost["conflicting"] == []
    # a preview proposes, it never stores: neither the pose nor the mate's branch moved
    assert _pose(root, "bracket") == before
    assert [(m["id"], m["secondary_flip"]) for m in _mates(root)] == [(distance["id"], False)]


def test_a_mate_that_fits_the_persisted_branches_needs_no_change():
    root, distance, _coincident, (base, bracket) = _scene()
    on_top = {
        "type": "distance",
        "references": [{"occurrence_id": "bracket", **_face(bracket, (0, 0, 1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}],
        "value": 18.0,  # the bracket top 18 above the base top = the bottom 14 above it
    }
    ghost = _preview(root, "bracket", on_top)
    assert ghost["converged"] and ghost["branch_changes"] == []


def test_confirm_without_the_changes_is_refused_and_nothing_is_stored():
    root, distance, coincident, _ = _scene()
    before = _pose(root, "bracket")
    for _ in range(2):
        response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json=coincident)
        assert response.status_code == 422, response.text
        detail = response.json()["detail"]
        assert detail["type"] == "branch_change_needed"
        assert detail["branch_changes"] == [{"mate_id": distance["id"], "field": "secondary_flip", "from": False, "to": True}]
    assert [m["id"] for m in _mates(root)] == [distance["id"]] and _pose(root, "bracket") == before
    assert _mates(root)[0]["secondary_flip"] is False


def test_confirm_with_the_previewed_changes_stores_both_mates_the_flipped_side_and_the_pose():
    root, distance, coincident, _ = _scene()
    ghost = _preview(root, "bracket", coincident)
    confirmed = [{"mate_id": c["mate_id"], "field": c["field"], "to": c["to"]} for c in ghost["branch_changes"]]
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json={**coincident, "branch_changes": confirmed})
    assert response.status_code == 201, response.text
    mates = {m["id"]: m for m in _mates(root)}
    assert len(mates) == 2
    assert mates[distance["id"]]["secondary_flip"] is True and mates[distance["id"]]["branch_source"] == "auto"
    stored = mates[response.json()["id"]]
    assert stored["alignment"] == "anti_aligned"
    assert abs(_pose(root, "bracket")["translation"][2] - (-4.0)) < 1e-6
    # and the whole thing now holds from any start: a plain solve changes nothing
    assert client.post(f"/document/parts/{root}/occurrences/bracket/solve").status_code == 200
    assert abs(_pose(root, "bracket")["translation"][2] - (-4.0)) < 1e-6


def test_a_change_that_was_never_proposed_is_refused():
    root, distance, coincident, _ = _scene()
    response = client.post(
        f"/document/parts/{root}/mates",
        params={"solve": "auto"},
        json={**coincident, "branch_changes": [{"mate_id": distance["id"], "field": "alignment", "to": "anti_aligned"}]},
    )
    assert response.status_code == 422 and response.json()["detail"]["type"] == "invalid_branch_change"
    assert len(_mates(root)) == 1


# ---- a mate the user set is never moved ----------------------------------------------------------------------------------------


def test_a_user_set_side_is_reported_not_moved():
    root, distance, coincident, _ = _scene({"secondary_flip": False})
    assert distance["branch_source"] == "user"
    ghost = _preview(root, "bracket", coincident)
    assert ghost["converged"] is False and ghost["transform"] is None
    assert ghost["blocked_by"] == [distance["id"]] and ghost["branch_changes"] == [] and ghost["conflicting"] == []
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json=coincident)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "mate_blocked_by_user_branch" and response.json()["detail"]["blocked_by"] == [distance["id"]]
    assert len(_mates(root)) == 1
    # a confirmed change on that mate is refused too
    forced = client.post(
        f"/document/parts/{root}/mates",
        params={"solve": "auto"},
        json={**coincident, "branch_changes": [{"mate_id": distance["id"], "field": "secondary_flip", "to": True}]},
    )
    assert forced.status_code == 422 and forced.json()["detail"]["type"] == "invalid_branch_change"
    assert _mates(root)[0]["secondary_flip"] is False


def test_the_user_can_free_it_and_the_mate_then_goes_through():
    root, distance, coincident, _ = _scene({"secondary_flip": False})
    assert client.patch(f"/document/parts/{root}/mates/{distance['id']}", json={"secondary_flip": None}).json()["branch_source"] == "auto"
    ghost = _preview(root, "bracket", coincident)
    assert ghost["converged"] and [c["mate_id"] for c in ghost["branch_changes"]] == [distance["id"]]


# ---- a genuine conflict names what it fights with -------------------------------------------------------------------------------


def test_an_impossible_mate_names_the_mate_it_fights_with():
    root, distance, _coincident, (base, bracket) = _scene()
    twenty = {  # the same two faces 20 mm apart: no side or orientation of the 14 mm one allows it
        "type": "distance",
        "references": [{"occurrence_id": "bracket", **_face(bracket, (0, 0, -1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}],
        "value": 20.0,
    }
    ghost = _preview(root, "bracket", twenty)
    assert ghost["converged"] is False and ghost["conflicting"] == [distance["id"]]
    assert ghost["branch_changes"] == [] and ghost["blocked_by"] == []
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json=twenty)
    assert response.status_code == 422
    detail = response.json()["detail"]
    assert detail["type"] == "mate_conflict" and detail["conflicting"] == [distance["id"]]
    assert "satisfied together" not in detail["detail"]
    assert len(_mates(root)) == 1


# ---- the search runs only in the create / edit flow --------------------------------------------------------------------------


def test_a_plain_solve_never_searches_or_changes_a_branch():
    root, distance, coincident, _ = _scene()
    assert client.post(f"/document/parts/{root}/mates", json=coincident).status_code == 201  # plain create: stored, unsolved
    response = client.post(f"/document/parts/{root}/occurrences/bracket/solve")
    assert response.status_code == 422 and response.json()["detail"]["type"] == "mate_solve_did_not_converge"
    assert next(m for m in _mates(root) if m["id"] == distance["id"])["secondary_flip"] is False


def test_a_drag_across_the_boundary_never_changes_a_stored_branch():
    root, distance, _coincident, _ = _scene()
    for z in (-30.0, 0.0, 5.0, 80.0):
        wish = {"translation": [5.0, 5.0, z], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}
        body = client.post(f"/document/parts/{root}/occurrences/bracket/mate-motion", json={"transform": wish, "commit": True}).json()
        assert body["converged"] and abs(body["members"][0]["transform"]["translation"][2] - 24.0) < 1e-6, z
        assert [(m["secondary_flip"], m["branch_source"]) for m in _mates(root)] == [(False, "auto")]


# ---- the edit flow ---------------------------------------------------------------------------------------------------------------


def test_editing_a_mate_can_ask_an_earlier_one_to_move_and_applies_it_on_confirmation():
    root, distance, _coincident, (base, bracket) = _scene()
    on_top = {
        "type": "distance",
        "references": [{"occurrence_id": "bracket", **_face(bracket, (0, 0, 1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}],
        "value": 18.0,
    }
    second = client.post(f"/document/parts/{root}/mates", params={"solve": "auto"}, json=on_top).json()
    # bottom 14 above the base top = top 18 above it. Now ask for the top 10 BELOW the base top (bottom at z = -4): the first
    # mate (auto) has to move to its other side
    edit = {"value": 10.0, "secondary_flip": True}
    preview_payload = {**on_top, **edit}
    ghost = _preview(root, "bracket", preview_payload, replace_mate_id=second["id"])
    assert ghost["converged"] and [c["mate_id"] for c in ghost["branch_changes"]] == [distance["id"]]
    refused = client.patch(f"/document/parts/{root}/mates/{second['id']}", params={"solve": "auto"}, json=edit)
    assert refused.status_code == 422 and refused.json()["detail"]["type"] == "branch_change_needed"
    stored = {m["id"]: m for m in _mates(root)}
    assert stored[second["id"]]["value"] == 18.0 and stored[second["id"]]["secondary_flip"] is False  # the old values are kept
    assert stored[distance["id"]]["secondary_flip"] is False
    confirmed = [{"mate_id": c["mate_id"], "field": c["field"], "to": c["to"]} for c in ghost["branch_changes"]]
    accepted = client.patch(f"/document/parts/{root}/mates/{second['id']}", params={"solve": "auto"}, json={**edit, "branch_changes": confirmed})
    assert accepted.status_code == 200, accepted.text
    stored = {m["id"]: m for m in _mates(root)}
    assert stored[second["id"]]["value"] == 10.0 and stored[second["id"]]["secondary_flip"] is True
    assert stored[distance["id"]]["secondary_flip"] is True
    assert abs(_pose(root, "bracket")["translation"][2] - (-4.0)) < 1e-6


# ---- the tester's table top ------------------------------------------------------------------------------------------------------


def _outside_start() -> dict:
    """The plate 40 mm further out than its correct pose along both measured edges: both distances resolve to "outside"."""
    correct = np.array(tt.CORRECT_PLATE_TRANSLATION)
    return {"translation": [float(x) for x in correct + [0.0, -40.0, -40.0]], "rotation_axis": [1.0, 0.0, 0.0], "rotation_angle_degrees": 180.0}


def _table_top_outside() -> tuple[str, list[dict]]:
    root = tt.import_table_top(client, keep_mates=False)
    assert client.patch(f"/document/parts/{root}/occurrences/{tt.PLATE}", json={"transform": _outside_start()}).status_code == 200
    created = []
    for payload in tt.table_top_mate_payloads():
        response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json=payload)
        assert response.status_code == 201, response.text
        created.append(response.json())
    return root, created


def test_table_top_started_outside_resolves_both_distances_to_outside_as_auto():
    root, created = _table_top_outside()
    distances = [m for m in created if m["type"] == "distance"]
    assert [(m["alignment"], m["secondary_flip"], m["branch_source"]) for m in distances] == [("aligned", False, "auto")] * 2
    translation = np.array(_pose(root, tt.PLATE)["translation"])
    assert np.allclose(translation, np.array(tt.CORRECT_PLATE_TRANSLATION) + [0.0, -20.0, -20.0], atol=1e-5)  # 10 mm OUTSIDE each outer edge


def _far_edge(plate_face: int, bar: str, bar_face: int = 0) -> dict:
    """The plate's far edge `plate_face` 10 mm inside the frame's far outer face (the bar's face `bar_face`)."""
    return {
        "type": "distance",
        "references": [tt.face_ref(tt.PLATE, tt.PLATE_BODY, plate_face), tt.face_ref(bar, tt.FRAME_BODY, bar_face)],
        "value": 10.0,
    }


def test_table_top_a_later_mate_that_needs_inside_offers_the_flip_of_the_outside_distance():
    root, created = _table_top_outside()
    near_y, near_z = [m for m in created if m["type"] == "distance"]  # face 2 / the y = 0 bar, face 3 / the z = -1570 bar
    far_y = _far_edge(0, tt.FRAME_BAR_Y800)  # plate far edge y = 790 against the y = 800 outer face: the plate is 780 wide
    ghost = _preview(root, tt.PLATE, far_y, movement="auto")
    assert ghost["converged"]
    assert [(c["mate_id"], c["field"], c["from"], c["to"]) for c in ghost["branch_changes"]] == [(near_y["id"], "secondary_flip", False, True)]
    confirmed = [{"mate_id": c["mate_id"], "field": c["field"], "to": c["to"]} for c in ghost["branch_changes"]]
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json={**far_y, "branch_changes": confirmed})
    assert response.status_code == 201, response.text
    stored = {m["id"]: m for m in _mates(root)}
    assert stored[near_y["id"]]["secondary_flip"] is True and stored[near_z["id"]]["secondary_flip"] is False
    pose = np.array(_pose(root, tt.PLATE)["translation"])
    assert abs(pose[1] - tt.CORRECT_PLATE_TRANSLATION[1]) < 1e-5  # y is centred now; z is still 10 mm outside


def test_table_top_the_other_axis_offers_the_other_flip_and_together_they_centre_the_plate():
    root, created = _table_top_outside()
    near_y, near_z = [m for m in created if m["type"] == "distance"]
    for far, near in ((_far_edge(0, tt.FRAME_BAR_Y800), near_y), (_far_edge(1, tt.FRAME_TOP_BAR), near_z)):
        ghost = _preview(root, tt.PLATE, far, movement="auto")
        assert ghost["converged"] and [c["mate_id"] for c in ghost["branch_changes"]] == [near["id"]]
        confirmed = [{"mate_id": c["mate_id"], "field": c["field"], "to": c["to"]} for c in ghost["branch_changes"]]
        assert client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json={**far, "branch_changes": confirmed}).status_code == 201
    pose = _pose(root, tt.PLATE)
    assert np.allclose(pose["translation"], tt.CORRECT_PLATE_TRANSLATION, atol=1e-5)
    assert all(m["secondary_flip"] is True for m in _mates(root) if m["type"] == "distance" and m["id"] in (near_y["id"], near_z["id"]))
