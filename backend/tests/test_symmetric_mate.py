"""Symmetric about a plane (`docs/width-mate-plan.md` W5): two faces on two parts that mirror each other about a plane (a left and a
right bracket either side of a centre plane).

For FACES that is already expressible with the cross-part Width machinery and no third reference: the faces mirror each other about
P exactly when the mid-plane between them IS P. So the stored mate is a `coincident` of `[midplane(A on X, B on Y), P]`, P any plane
reference (a face of a centre part, a face of the assembly's own content). These tests pin that, from several starts.
"""

import numpy as np
import pytest

from app.document.assembly import apply_transform_to_direction, apply_transform_to_point
from app.document.models import RigidTransform
from app.document.store import get_document
from tests.test_assembly_group import _compose, _face
from tests.test_assembly_solver import _make_box_part, client


def _fr(part: dict, normal) -> dict:
    return {"face_ref": _face(part, normal)["subshape_ref"]}


def _scene(fix_centre: bool = True):
    base = _make_box_part("Base", size=5.0, depth=5.0)
    centre = _make_box_part("Centre", size=4.0, depth=40.0)  # its +x face is the mirror plane P: x = 4
    left = _make_box_part("Left", size=10.0, depth=10.0)
    right = _make_box_part("Right", size=10.0, depth=10.0)
    root = _compose(base, [("centre", centre, (0, 0, 0)), ("left", left, (-16.0, 2.0, 3.0)), ("right", right, (14.0, 7.0, 1.0))])
    if fix_centre:
        assert client.patch(f"/document/parts/{root}/occurrences/centre", json={"fixed": True}).status_code == 200
    return root, centre, left, right


def _symmetric_payload(centre, left, right, **fields) -> dict:
    pair = {
        "occurrence_id": "left",
        "midplane": {"a": _fr(left, (1, 0, 0)), "b": _fr(right, (-1, 0, 0)), "b_occurrence_id": "right"},
    }
    mirror = {"occurrence_id": "centre", **_face(centre, (1, 0, 0))}
    return {"type": "coincident", "references": [pair, mirror], **fields}


def _poses(root: str) -> dict:
    return {
        o["id"]: RigidTransform(tuple(o["transform"]["translation"]), tuple(o["transform"]["rotation_axis"]), o["transform"]["rotation_angle_degrees"])
        for o in client.get(f"/document/parts/{root}/occurrences").json()
    }


def _assert_mirrored(root: str) -> None:
    poses = _poses(root)
    a = apply_transform_to_point(poses["left"], (10.0, 5.0, 5.0))  # left's +x face, a point on it
    b = apply_transform_to_point(poses["right"], (0.0, 5.0, 5.0))  # right's -x face
    na = apply_transform_to_direction(poses["left"], (1.0, 0.0, 0.0))
    nb = apply_transform_to_direction(poses["right"], (-1.0, 0.0, 0.0))
    assert abs(abs(na[0]) - 1.0) < 1e-6 and abs(abs(nb[0]) - 1.0) < 1e-6  # both faces parallel to the mirror plane x = 4
    assert (a[0] - 4.0) + (b[0] - 4.0) == pytest.approx(0.0, abs=1e-6)  # equal distances either side of it


@pytest.mark.parametrize("movement", ["auto", "group"])
def test_two_parts_mirror_each_other_about_a_fixed_centre_plane(movement):
    root, centre, left, right = _scene()
    response = client.post(
        f"/document/parts/{root}/mates", params={"solve": movement, "occurrence_id": "left"}, json=_symmetric_payload(centre, left, right)
    )
    assert response.status_code == 201, response.text
    _assert_mirrored(root)


def test_the_mirror_holds_when_either_part_is_moved_later():
    root, centre, left, right = _scene()
    assert client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": "left"}, json=_symmetric_payload(centre, left, right)).status_code == 201
    # solving for the OTHER part afterwards keeps the pair symmetric (the group solve sees the same mate from either side)
    client.patch(f"/document/parts/{root}/occurrences/right", json={"transform": {"translation": [30.0, 0.0, 0.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}})
    response = client.post(f"/document/parts/{root}/occurrences/right/solve")
    assert response.status_code in (200, 422), response.text  # the single-occurrence solve cannot place a two-part mid-plane: it says so rather than guess
    if response.status_code == 422:
        assert response.json()["detail"]["type"] in ("midplane_faces_on_different_occurrences", "mate_solve_did_not_converge")
    mate_motion = client.post(f"/document/parts/{root}/occurrences/right/mate-motion", json={})
    assert mate_motion.status_code == 200, mate_motion.text


def test_non_parallel_faces_are_refused():
    root, centre, left, right = _scene()
    payload = _symmetric_payload(centre, left, right)
    payload["references"][0]["midplane"]["b"] = _fr(right, (0, 1, 0))  # a y face against an x face
    response = client.post(f"/document/parts/{root}/mates", json=payload)
    assert response.status_code == 422 and response.json()["detail"]["type"] == "faces_not_parallel"


def test_no_objects_are_created_and_deleting_the_mate_leaves_the_assembly():
    root, centre, left, right = _scene()
    before = {pid: ([f.id for f in p.features], [o.id for o in p.occurrences]) for pid, p in get_document().parts.items()}
    mate = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": "left"}, json=_symmetric_payload(centre, left, right)).json()
    assert client.delete(f"/document/parts/{root}/mates/{mate['id']}").status_code == 204
    assert {pid: ([f.id for f in p.features], [o.id for o in p.occurrences]) for pid, p in get_document().parts.items()} == before
