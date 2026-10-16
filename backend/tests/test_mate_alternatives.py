"""Mate panel controls and "Next solution" (`docs/mate-solution-choice-plan.md`, Phase 3): the preview's `controls`, `resolved` and
`alternatives`.

* `controls` names the branch fields that mean something for the picked geometry, per mate type (the client never works it out);
* `resolved` is the branch the ghost shows, in the convention a create takes back;
* `alternatives` lists every converging combination of the NEW mate's controls, nearest first, each reproducible by naming it.
"""

import numpy as np
import pytest

from tests import table_top_fixture as tt
from tests.test_assembly_solver import _make_box_part, _place_occurrence, client
from tests.test_mate_branches import _cyl, _face, _pin_scene, _plate_scene

_IDENTITY = {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}


def _preview(root: str, payload: dict, occurrence: str = "occ-driven", movement: str = "group") -> dict:
    response = client.post(
        f"/document/parts/{root}/occurrences/{occurrence}/preview-mate-solve", params={"movement": movement}, json=payload
    )
    assert response.status_code == 200, response.text
    return response.json()


def _payload(mtype: str, driven: dict, fixed: dict, **fields) -> dict:
    return {"type": mtype, "references": [{"occurrence_id": "occ-driven", **driven}, {"occurrence_id": "", **fixed}], **fields}


# ---- controls per geometry -------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "mtype,fields,expected",
    [
        ("coincident", {}, ["alignment"]),
        ("parallel", {}, ["alignment"]),
        ("distance", {"value": 15.0}, ["alignment", "secondary_flip"]),
        ("angle", {"value": 60.0}, ["secondary_flip"]),
    ],
)
def test_plane_plane_controls(mtype, fields, expected):
    base, bracket = _plate_scene()
    ghost = _preview(base["id"], _payload(mtype, _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), **fields))
    assert ghost["controls"] == expected
    # `resolved` carries a value for exactly the controls and nothing for the rest
    resolved = ghost["resolved"]
    assert (resolved["alignment"] is not None) == ("alignment" in expected)
    assert (resolved["secondary_flip"] is not None) == ("secondary_flip" in expected)


def test_axis_controls_free_and_locked():
    base, pin = _pin_scene()
    free = _preview(base["id"], _payload("concentric", _cyl(pin), _cyl(base)))
    assert free["controls"] == ["alignment"]
    locked = _preview(base["id"], _payload("concentric", _cyl(pin), _cyl(base), allow_rotation=False))
    assert locked["controls"] == ["alignment", "secondary_flip"]
    assert _preview(base["id"], _payload("distance", _cyl(pin), _cyl(base), value=25.0))["controls"] == ["alignment"]


def test_point_plane_distance_has_the_side_only_and_point_point_none():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    pin = _make_box_part("Pin", size=2.0, depth=2.0)
    _place_occurrence(base["id"], pin["id"], translation=(1.0, 1.0, 40.0))
    vertex = {"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}}
    side = _preview(base["id"], _payload("distance", vertex, _face(base, (0, 0, 1)), value=6.0))
    assert side["controls"] == ["secondary_flip"] and side["resolved"]["alignment"] is None
    other_vertex = {"subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 0}}
    point_point = _preview(base["id"], _payload("coincident", vertex, other_vertex))
    assert point_point["controls"] == [] and point_point["alternatives"] == []


def test_an_unfinished_payload_has_no_alternatives_and_a_distance_still_lists_its_controls():
    base, bracket = _plate_scene()
    ghost = _preview(base["id"], _payload("distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1))))  # no value yet
    assert ghost["converged"] is False and ghost["alternatives"] == []


# ---- alternatives ----------------------------------------------------------------------------------------------------------


def test_the_tester_s_first_distance_mate_lists_all_four_roots_including_the_centred_one():
    root = tt.import_table_top(client, keep_mates=False)
    assert client.patch(f"/document/parts/{root}/occurrences/{tt.PLATE}", json={"transform": _IDENTITY}).status_code == 200
    payload = tt.table_top_mate_payloads()[0]
    ghost = _preview(root, payload, occurrence=tt.PLATE)
    assert ghost["converged"] and ghost["controls"] == ["alignment", "secondary_flip"]
    alternatives = ghost["alternatives"]
    assert {(a["alignment"], a["secondary_flip"]) for a in alternatives} == {
        ("aligned", True), ("aligned", False), ("anti_aligned", True), ("anti_aligned", False)
    }
    # nearest first; the ghost shows the DEFAULT, which is the nearest root unless Phase 4 moves a facing gap outside (here the plate starts
    # facing the bar, so the default is the outside root), and either way it is one of the alternatives
    costs = [a["movement_cost"] for a in alternatives]
    assert costs == sorted(costs)
    shown = next(a for a in alternatives if (a["alignment"], a["secondary_flip"]) == (ghost["resolved"]["alignment"], ghost["resolved"]["secondary_flip"]))
    assert np.allclose(shown["members"][0]["transform"]["translation"], ghost["transform"]["translation"], atol=1e-6)
    # the centred root (the plate's edge 10 mm INSIDE the bar: the plate at y = 790) is one of them: aligned + inside
    centred = next(a for a in alternatives if (a["alignment"], a["secondary_flip"]) == ("aligned", True))
    assert centred["members"][0]["transform"]["translation"][1] == pytest.approx(tt.CORRECT_PLATE_TRANSLATION[1], abs=1e-3)
    # and it is the one that is NOT the nearest from here - Next solution is what reaches it
    assert (ghost["resolved"]["alignment"], ghost["resolved"]["secondary_flip"]) != ("aligned", True)


def test_naming_an_alternative_reproduces_its_placement():
    root = tt.import_table_top(client, keep_mates=False)
    assert client.patch(f"/document/parts/{root}/occurrences/{tt.PLATE}", json={"transform": _IDENTITY}).status_code == 200
    payload = tt.table_top_mate_payloads()[0]
    for alternative in _preview(root, payload, occurrence=tt.PLATE)["alternatives"]:
        named = _preview(
            root, {**payload, "alignment": alternative["alignment"], "secondary_flip": alternative["secondary_flip"]}, occurrence=tt.PLATE
        )
        assert named["converged"]
        assert named["resolved"] == {"alignment": alternative["alignment"], "secondary_flip": alternative["secondary_flip"]}
        assert np.allclose(named["transform"]["translation"], alternative["members"][0]["transform"]["translation"], atol=1e-6)


def test_the_alternatives_do_not_depend_on_which_branch_the_payload_names():
    base, bracket = _plate_scene()
    plain = _payload("distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=15.0)
    first = _preview(base["id"], plain)["alternatives"]
    named = _preview(base["id"], {**plain, "alignment": "anti_aligned", "secondary_flip": True})["alternatives"]
    assert [(a["alignment"], a["secondary_flip"]) for a in first] == [(a["alignment"], a["secondary_flip"]) for a in named]


def test_nothing_is_stored_by_listing_alternatives():
    base, bracket = _plate_scene()
    before = client.get(f"/document/parts/{base['id']}/occurrences").json()
    _preview(base["id"], _payload("distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=15.0))
    assert client.get(f"/document/parts/{base['id']}/occurrences").json() == before
    assert client.get(f"/document/parts/{base['id']}/mates").json() == []


def test_a_coincident_lists_both_alignments_and_no_side():
    """Only the fields in `controls` vary: a COINCIDENT of two planes has an alignment and no side."""
    base, bracket = _plate_scene()
    ghost = _preview(base["id"], _payload("coincident", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1))))
    assert {a["alignment"] for a in ghost["alternatives"]} == {"aligned", "anti_aligned"}
    assert all(a["secondary_flip"] is None for a in ghost["alternatives"])
