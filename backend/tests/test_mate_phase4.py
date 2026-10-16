"""Phase 4 (`docs/mate-solution-choice-plan.md`): the default side of a NEW, unnamed DISTANCE. A facing distance (anti-aligned normals) or a
point-to-face distance is a gap, so the driven body goes on the +normal side of the face - outside the other solid - even when the part starts on
the wrong side. Same-facing distances (flush inset / overhang) keep the nearest root; a named branch is never touched.
"""

import numpy as np
import pytest

from tests import table_top_fixture as tt
from tests.test_assembly_group import _face
from tests.test_assembly_solver import _make_box_part, _place_occurrence, client


def _scene(translation, rotation_axis=(0.0, 0.0, 1.0), rotation_angle_degrees=0.0):
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    _place_occurrence(base["id"], bracket["id"], translation=translation, rotation_axis=rotation_axis, rotation_angle_degrees=rotation_angle_degrees)
    return base, bracket


def _refs(driven, fixed):
    return [{"occurrence_id": "occ-driven", **driven}, {"occurrence_id": "", **fixed}]


def _shelf(base, bracket, value=6.0, **fields):
    """The bracket's bottom face 6 mm over the base top (facing faces)."""
    return {"type": "distance", "value": value, "references": _refs(_face(bracket, (0, 0, -1)), _face(base, (0, 0, 1))), **fields}


def _preview(base, payload):
    response = client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/preview-mate-solve", params={"movement": "auto"}, json=payload)
    assert response.status_code == 200, response.text
    return response.json()


def _z(base):
    return client.get(f"/document/parts/{base['id']}/occurrences").json()[0]["transform"]["translation"][2]


def test_a_gap_between_facing_faces_goes_outside_even_from_the_wrong_side():
    # the bracket starts 5 mm under the base's top plane (inside the base): the nearest root is "below" (z = 4), but a gap cannot be inside the solid
    base, bracket = _scene((5.0, 5.0, 5.0))
    ghost = _preview(base, _shelf(base, bracket))
    assert ghost["converged"]
    assert ghost["resolved"] == {"alignment": "anti_aligned", "secondary_flip": False}
    assert ghost["transform"]["translation"][2] == pytest.approx(16.0, abs=1e-6)


def test_a_facing_gap_under_a_face_goes_on_that_faces_outside_too():
    # under the base's underside (normal -z): outside is DOWN, z = -6 - 4
    base, bracket = _scene((5.0, 5.0, 3.0))
    payload = {"type": "distance", "value": 6.0, "references": _refs(_face(bracket, (0, 0, 1)), _face(base, (0, 0, -1)))}
    ghost = _preview(base, payload)
    assert ghost["converged"] and ghost["resolved"]["secondary_flip"] is False
    assert ghost["transform"]["translation"][2] == pytest.approx(-10.0, abs=1e-6)


def test_a_point_to_face_distance_goes_outside():
    base, bracket = _scene((5.0, 5.0, 7.0))
    corner = {"subshape_ref": {"body_id": bracket["body_id"], "shape_type": "vertex", "index": 0}}
    ghost = _preview(base, {"type": "distance", "value": 6.0, "references": _refs(corner, _face(base, (0, 0, 1)))})
    assert ghost["converged"] and ghost["resolved"]["secondary_flip"] is False
    assert ghost["transform"]["translation"][2] == pytest.approx(16.0, abs=1e-6)


def test_same_facing_faces_keep_the_nearest_root_inset_or_overhang():
    # the bracket's +x face against the base's +x face (same way): 3 mm behind the edge (inset) or past it (overhang) - both are legitimate
    for start_x, behind in ((9.5, True), (14.5, False)):
        base, bracket = _scene((start_x, 6.0, 10.0))
        payload = {"type": "distance", "value": 3.0, "references": _refs(_face(bracket, (1, 0, 0)), _face(base, (1, 0, 0)))}
        ghost = _preview(base, payload)
        assert ghost["converged"] and ghost["resolved"] == {"alignment": "aligned", "secondary_flip": behind}, start_x


def test_a_named_side_is_never_overridden():
    base, bracket = _scene((5.0, 5.0, 5.0))
    ghost = _preview(base, _shelf(base, bracket, secondary_flip=True))
    assert ghost["resolved"]["secondary_flip"] is True and ghost["transform"]["translation"][2] == pytest.approx(4.0, abs=1e-6)


def test_the_preview_and_the_created_mate_agree_and_the_mate_stays_auto():
    base, bracket = _scene((5.0, 5.0, 5.0))
    payload = _shelf(base, bracket)
    ghost = _preview(base, payload)
    created = client.post(f"/document/parts/{base['id']}/mates", params={"solve": "auto"}, json=payload)
    assert created.status_code == 201, created.text
    mate = created.json()
    assert (mate["alignment"], mate["secondary_flip"]) == (ghost["resolved"]["alignment"], ghost["resolved"]["secondary_flip"])
    assert mate["branch_source"] == "auto"  # the program chose it: a later mate may still ask to move it
    assert _z(base) == pytest.approx(ghost["transform"]["translation"][2], abs=1e-6)


def test_plain_creates_and_edits_are_unchanged():
    base, bracket = _scene((5.0, 5.0, 5.0))
    plain = client.post(f"/document/parts/{base['id']}/mates", json=_shelf(base, bracket))  # no solve=: nothing resolved here
    assert plain.status_code == 201 and plain.json()["secondary_flip"] is None


def test_the_tester_s_same_facing_distances_are_still_the_nearest_root():
    """Not a facing gap (the plate's edge face and the bar's outer face point the same way): the plate 12 mm outside stays 10 mm outside."""
    root = tt.import_table_top(client, keep_mates=False)
    start = {"translation": [float(x) for x in np.array(tt.CORRECT_PLATE_TRANSLATION) + [0, -12.0, 0]], "rotation_axis": [1.0, 0.0, 0.0], "rotation_angle_degrees": 180.0}
    assert client.patch(f"/document/parts/{root}/occurrences/{tt.PLATE}", json={"transform": start}).status_code == 200
    ghost = client.post(
        f"/document/parts/{root}/occurrences/{tt.PLATE}/preview-mate-solve", params={"movement": "auto"}, json=tt.table_top_mate_payloads()[0]
    ).json()
    assert ghost["converged"] and ghost["resolved"]["secondary_flip"] is False
