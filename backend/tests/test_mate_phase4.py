"""Phase 4 (`docs/mate-solution-choice-plan.md`): when the nearest roots of a NEW, unnamed mate are about equally near (within 10 % of the
nearest one's movement), bounding-box interference and then "behind the fixed face" break the tie; a clearly nearer root and a named
branch are left alone.
"""

import numpy as np
import pytest

from tests import table_top_fixture as tt
from tests.test_assembly_group import _face
from tests.test_assembly_solver import _make_box_part, _place_occurrence, client

_IDENTITY = {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}


def _scene(translation, rotation_axis=(0.0, 0.0, 1.0), rotation_angle_degrees=0.0):
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    _place_occurrence(base["id"], bracket["id"], translation=translation, rotation_axis=rotation_axis, rotation_angle_degrees=rotation_angle_degrees)
    return base, bracket


def _distance(base, bracket, value=6.0, **fields):
    refs = [{"occurrence_id": "occ-driven", **_face(bracket, (0, 0, -1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}]
    return {"type": "distance", "value": value, "references": refs, **fields}


def _preview(base, payload):
    response = client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/preview-mate-solve", params={"movement": "auto"}, json=payload)
    assert response.status_code == 200, response.text
    return response.json()


def _z(base):
    return client.get(f"/document/parts/{base['id']}/occurrences").json()[0]["transform"]["translation"][2]


def test_a_near_tie_goes_to_the_root_that_does_not_interfere():
    # the bracket sits over the base, 0.1 mm below its top plane: the "below" root (bracket inside the base) is 3 % nearer than "above"
    base, bracket = _scene((5.0, 5.0, 9.9))
    ghost = _preview(base, _distance(base, bracket))
    assert ghost["converged"]
    assert ghost["resolved"] == {"alignment": "anti_aligned", "secondary_flip": False}  # above the base top, not inside it
    assert ghost["transform"]["translation"][2] == pytest.approx(16.0, abs=1e-6)


def test_a_clearly_nearer_root_wins_even_when_it_interferes():
    # 20 mm under the plane: "below" (10 - 6 = 4) is far nearer than "above" (16); the tie-break must not drag the part across
    base, bracket = _scene((5.0, 5.0, -20.0))
    ghost = _preview(base, _distance(base, bracket))
    assert ghost["converged"] and ghost["resolved"]["secondary_flip"] is True
    assert ghost["transform"]["translation"][2] == pytest.approx(4.0, abs=1e-6)


def test_a_named_branch_is_never_overridden():
    base, bracket = _scene((5.0, 5.0, 9.9))
    ghost = _preview(base, _distance(base, bracket, secondary_flip=True))
    assert ghost["resolved"]["secondary_flip"] is True and ghost["transform"]["translation"][2] == pytest.approx(4.0, abs=1e-6)


def test_the_preview_and_the_created_mate_agree_and_the_mate_stays_auto():
    base, bracket = _scene((5.0, 5.0, 9.9))
    payload = _distance(base, bracket)
    ghost = _preview(base, payload)
    created = client.post(f"/document/parts/{base['id']}/mates", params={"solve": "auto"}, json=payload)
    assert created.status_code == 201, created.text
    mate = created.json()
    assert (mate["alignment"], mate["secondary_flip"]) == (ghost["resolved"]["alignment"], ghost["resolved"]["secondary_flip"])
    assert mate["branch_source"] == "auto"  # the program chose it: a later mate may still ask to move it
    assert _z(base) == pytest.approx(ghost["transform"]["translation"][2], abs=1e-6)


def test_a_tie_with_nothing_to_hit_puts_a_same_facing_distance_behind_the_fixed_face():
    # an upside-down bracket far to the side of the base (aligned normals), exactly in the base's top plane: both sides are 6 mm away and
    # neither hits anything, so the tester's "inset" rule decides - behind the fixed face (the minus side)
    base, bracket = _scene((100.0, 5.0, 10.0), rotation_axis=(1.0, 0.0, 0.0), rotation_angle_degrees=180.0)
    ghost = _preview(base, _distance(base, bracket))
    assert ghost["converged"]
    assert ghost["resolved"] == {"alignment": "aligned", "secondary_flip": True}
    assert ghost["transform"]["translation"][2] == pytest.approx(10.0 - 6.0, abs=1e-6)


def test_edits_and_plain_creates_are_unchanged():
    base, bracket = _scene((5.0, 5.0, 9.9))
    plain = client.post(f"/document/parts/{base['id']}/mates", json=_distance(base, bracket))  # no solve=: nothing resolved here
    assert plain.status_code == 201 and plain.json()["alignment"] is None


def test_the_tester_s_outward_shifts_still_resolve_to_the_nearest_root():
    """Not a tie (the plate is 12 mm outside, the inside root is 22 mm away): the nearest root is kept - Phase 4 is not a rule that
    overrides the user's placement."""
    root = tt.import_table_top(client, keep_mates=False)
    start = {"translation": [float(x) for x in np.array(tt.CORRECT_PLATE_TRANSLATION) + [0, -12.0, 0]], "rotation_axis": [1.0, 0.0, 0.0], "rotation_angle_degrees": 180.0}
    assert client.patch(f"/document/parts/{root}/occurrences/{tt.PLATE}", json={"transform": start}).status_code == 200
    ghost = client.post(
        f"/document/parts/{root}/occurrences/{tt.PLATE}/preview-mate-solve", params={"movement": "auto"}, json=tt.table_top_mate_payloads()[0]
    ).json()
    assert ghost["converged"] and ghost["resolved"]["secondary_flip"] is False  # 10 mm outside, as before
