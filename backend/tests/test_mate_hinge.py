"""The swing sense of an ANGLE about a hinge (`docs/mate-solution-choice-plan.md`, F2 "ANGLE on a hinge"): a lid joined to a base by a
coincident edge pair (a hinge) and an ANGLE between their faces has the roots {+theta, -theta} x {angle, supplement}.

* `alignment` of such an ANGLE names +theta / -theta; `secondary_flip` the supplement, so the four combinations reach four placements;
* a named (or resolved) swing sense survives re-solves from any start and drags through the flat position;
* the preview lists the control and an alternative for every root;
* the sense is stored against the references' order, so grounding the other part does not change what it means.
"""

import math

import numpy as np
import pytest

from tests.test_assembly_group import _compose, _face
from tests.test_assembly_solver import _create_part, _make_box_part, _place_occurrence, client

_STARTS = 10


def _rmat(axis, degrees):
    a = np.array(axis, float)
    a /= np.linalg.norm(a)
    t = math.radians(degrees)
    k = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + math.sin(t) * k + (1 - math.cos(t)) * (k @ k)


def _edge(part, index):
    return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "edge", "index": index}}


def _refs(driven, fixed, occurrence="occ-driven"):
    return [{"occurrence_id": occurrence, **driven}, {"occurrence_id": "", **fixed}]


def _hinge_scene():
    """A 20 x 20 x 10 base with a 20 x 20 x 2 lid hinged on its top front edge (y = 0, z = 10) by a coincident edge pair."""
    base = _make_box_part("Base", size=20.0, depth=10.0)
    lid = _make_box_part("Lid", size=20.0, depth=2.0)
    _place_occurrence(base["id"], lid["id"], translation=(0.0, 0.0, 10.0), rotation_axis=(1.0, 0.0, 0.0), rotation_angle_degrees=100.0)
    # the hinge itself is named too: which way along the hinge line the lid's edge points is the hinge mate's own root, not the swing's
    hinge = {"type": "coincident", "alignment": "aligned", "references": _refs(_edge(lid, 2), _edge(base, 3))}
    assert client.post(f"/document/parts/{base['id']}/mates", json=hinge).status_code == 201
    return base, lid


def _angle_payload(base, lid, value=60.0, **fields):
    return {"type": "angle", "value": value, "references": _refs(_face(lid, (0, 0, -1)), _face(base, (0, 0, 1))), **fields}


def _root(transform) -> str:
    """Which of the four placements the lid is in, from where its far edge ends up."""
    far = _rmat(transform["rotation_axis"], transform["rotation_angle_degrees"]) @ [0, 20, 0] + np.array(transform["translation"])
    return ("y+" if far[1] > 0 else "y-") + ("/up" if far[2] > 10 else "/down")


def _starts(seed, count=_STARTS):
    rng = np.random.default_rng(seed)
    for _ in range(count):
        axis = rng.normal(size=3)
        axis /= np.linalg.norm(axis)
        yield {
            "translation": [float(x) for x in rng.uniform(-15, 15, 3) + [0, 0, 10]],
            "rotation_axis": [float(x) for x in axis],
            "rotation_angle_degrees": float(rng.uniform(0, 360)),
        }


def _solve_from(root, start, occurrence="occ-driven"):
    assert client.patch(f"/document/parts/{root}/occurrences/{occurrence}", json={"transform": start}).status_code == 200
    response = client.post(f"/document/parts/{root}/occurrences/{occurrence}/solve")
    assert response.status_code == 200, response.text
    return response.json()["transform"]


# ---- the four combinations ---------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "alignment,flip,expected",
    [
        ("aligned", False, "y-/up"),
        ("anti_aligned", False, "y-/down"),
        ("aligned", True, "y+/up"),
        ("anti_aligned", True, "y+/down"),
    ],
)
def test_each_combination_reaches_its_own_root_from_every_start(alignment, flip, expected):
    base, lid = _hinge_scene()
    response = client.post(f"/document/parts/{base['id']}/mates", json=_angle_payload(base, lid, alignment=alignment, secondary_flip=flip))
    assert response.status_code == 201, response.text
    for start in _starts(31):
        assert _root(_solve_from(base["id"], start)) == expected


def test_closest_resolves_from_the_first_solve_and_the_swing_sense_is_then_kept():
    base, lid = _hinge_scene()
    mate = client.post(f"/document/parts/{base['id']}/mates", json=_angle_payload(base, lid)).json()
    assert mate["alignment"] is None
    roots = set()
    for start in _starts(32):
        roots.add(_root(_solve_from(base["id"], start)))
    assert len(roots) == 1  # it used to float between up and down with the start pose
    stored = client.get(f"/document/parts/{base['id']}/mates").json()[-1]
    assert stored["alignment"] in ("aligned", "anti_aligned") and stored["secondary_flip"] is not None


def test_a_legacy_hinge_angle_keeps_the_stored_placement_exactly():
    base, lid = _hinge_scene()
    # the lid stored raised 60 degrees about the hinge, an ANGLE mate that names nothing (as in a file from before)
    placed = {"translation": [0.0, 0.0, 10.0], "rotation_axis": [1.0, 0.0, 0.0], "rotation_angle_degrees": 120.0}
    assert client.patch(f"/document/parts/{base['id']}/occurrences/occ-driven", json={"transform": placed}).status_code == 200
    assert client.post(f"/document/parts/{base['id']}/mates", json=_angle_payload(base, lid)).status_code == 201
    solved = client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/solve").json()["transform"]
    assert np.allclose(_rmat(solved["rotation_axis"], solved["rotation_angle_degrees"]), _rmat(placed["rotation_axis"], placed["rotation_angle_degrees"]), atol=1e-6)
    assert np.allclose(solved["translation"], placed["translation"], atol=1e-6)


# ---- drags -------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("alignment", ["aligned", "anti_aligned"])
def test_a_drag_through_the_flat_position_stays_on_the_named_way(alignment):
    base, lid = _hinge_scene()
    assert client.post(f"/document/parts/{base['id']}/mates", json=_angle_payload(base, lid, alignment=alignment, secondary_flip=True)).status_code == 201
    before = _root(_solve_from(base["id"], {"translation": [0.0, 0.0, 10.0], "rotation_axis": [1, 0, 0], "rotation_angle_degrees": 120.0}))
    rng = np.random.default_rng(33)
    for _ in range(25):
        wish = {"translation": [float(rng.uniform(-3, 3)), 0.0, 10.0], "rotation_axis": [1, 0, 0], "rotation_angle_degrees": float(rng.uniform(-200, 200))}
        body = client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/mate-motion", json={"transform": wish, "commit": False}).json()
        assert body["converged"]
        assert _root(body["members"][0]["transform"]) == before


def test_a_drag_commit_never_changes_the_named_swing_sense():
    base, lid = _hinge_scene()
    mate = client.post(f"/document/parts/{base['id']}/mates", json=_angle_payload(base, lid, alignment="aligned", secondary_flip=True)).json()
    _solve_from(base["id"], next(_starts(34)))
    wish = {"translation": [0.0, 0.0, 10.0], "rotation_axis": [1, 0, 0], "rotation_angle_degrees": 170.0}
    client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/mate-motion", json={"transform": wish, "commit": True})
    stored = next(m for m in client.get(f"/document/parts/{base['id']}/mates").json() if m["id"] == mate["id"])
    assert (stored["alignment"], stored["secondary_flip"]) == ("aligned", True)


# ---- preview -----------------------------------------------------------------------------------------------------------


def test_the_preview_offers_the_swing_sense_and_an_alternative_for_every_root():
    base, lid = _hinge_scene()
    ghost = client.post(
        f"/document/parts/{base['id']}/occurrences/occ-driven/preview-mate-solve", params={"movement": "auto"}, json=_angle_payload(base, lid)
    ).json()
    assert ghost["converged"] and ghost["controls"] == ["alignment", "secondary_flip"]
    assert {_root(a["members"][0]["transform"]) for a in ghost["alternatives"]} == {"y-/up", "y+/up", "y-/down", "y+/down"}
    # naming an alternative reproduces its placement
    for alt in ghost["alternatives"]:
        named = client.post(
            f"/document/parts/{base['id']}/occurrences/occ-driven/preview-mate-solve",
            params={"movement": "auto"},
            json=_angle_payload(base, lid, alignment=alt["alignment"], secondary_flip=alt["secondary_flip"]),
        ).json()
        assert named["converged"] and _root(named["transform"]) == _root(alt["members"][0]["transform"])


def test_an_angle_without_a_hinge_keeps_only_the_supplement_control():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    lid = _make_box_part("Lid", size=20.0, depth=2.0)
    _place_occurrence(base["id"], lid["id"], translation=(0.0, 0.0, 30.0), rotation_axis=(1.0, 0.0, 0.0), rotation_angle_degrees=100.0)
    ghost = client.post(
        f"/document/parts/{base['id']}/occurrences/occ-driven/preview-mate-solve", params={"movement": "auto"}, json=_angle_payload(base, lid)
    ).json()
    assert ghost["controls"] == ["secondary_flip"]


def test_an_angle_of_0_or_180_degrees_has_one_swing_so_no_alignment_control():
    base, lid = _hinge_scene()
    for value in (0.0, 180.0):
        ghost = client.post(
            f"/document/parts/{base['id']}/occurrences/occ-driven/preview-mate-solve",
            params={"movement": "auto"},
            json=_angle_payload(base, lid, value=value),
        ).json()
        assert "alignment" not in ghost["controls"]


# ---- the sense is stored against the references' order -----------------------------------------------------------------


def test_grounding_the_other_part_does_not_change_what_the_swing_sense_means():
    base_part = _make_box_part("Base", size=20.0, depth=10.0)
    lid_part = _make_box_part("Lid", size=20.0, depth=2.0)
    root = _compose(_create_part("Hinged"), [("base", base_part, (0.0, 0.0, 0.0)), ("lid", lid_part, (0.0, 0.0, 10.0))])
    refs = lambda a, b: [{"occurrence_id": "lid", **a}, {"occurrence_id": "base", **b}]
    assert client.post(f"/document/parts/{root}/mates", json={"type": "coincident", "references": refs(_edge(lid_part, 2), _edge(base_part, 3))}).status_code == 201
    angle = {"type": "angle", "value": 60.0, "references": refs(_face(lid_part, (0, 0, -1)), _face(base_part, (0, 0, 1))), "alignment": "anti_aligned", "secondary_flip": True}
    assert client.post(f"/document/parts/{root}/mates", json=angle).status_code == 201

    def relative(lid_pose, base_pose):
        rl, rb = _rmat(lid_pose["rotation_axis"], lid_pose["rotation_angle_degrees"]), _rmat(base_pose["rotation_axis"], base_pose["rotation_angle_degrees"])
        return rb.T @ rl, rb.T @ (np.array(lid_pose["translation"]) - np.array(base_pose["translation"]))

    def poses():
        return {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}

    client.patch(f"/document/parts/{root}/occurrences/base", json={"fixed": True})
    lid_start = {"translation": [3.0, -8.0, 20.0], "rotation_axis": [0.3, 0.5, 0.2], "rotation_angle_degrees": 80.0}
    _solve_from(root, lid_start, "lid")
    first = relative(poses()["lid"], poses()["base"])
    # the other way round: the lid is grounded, the base moves
    client.patch(f"/document/parts/{root}/occurrences/base", json={"fixed": False})
    client.patch(f"/document/parts/{root}/occurrences/lid", json={"fixed": True})
    base_start = {"translation": [1.0, 4.0, -5.0], "rotation_axis": [0.1, 0.9, 0.3], "rotation_angle_degrees": 130.0}
    _solve_from(root, base_start, "base")
    second = relative(poses()["lid"], poses()["base"])
    # the free slide along the hinge may differ; the swing (the relative rotation) must not
    assert np.allclose(first[0], second[0], atol=1e-5)
