"""Width mate over 2, 3 or 4 parts (`docs/width-mate-plan.md`): the gap faces and/or the tab faces may sit on different
top-level occurrences (two loose bars, a plate made of two parts).

* 3 parts, the bars fixed: the mid-plane never moves, so the constraint model stays a plain plane-plane one;
* 3 parts, the bars free, and 4 parts: the mid-plane depends on two poses - the group solve holds it (and keeps each pair of
  faces parallel), the constraint model is not exported (the clients keep projecting);
* nothing is created or stored for a mid-plane, whichever case.
"""

import numpy as np
import pytest

from app.document.assembly_group import build_group_model, mate_world_geometries
from app.document.constraint_model import export_constraint_model
from app.document.store import get_document
from tests.test_assembly_group import _compose, _face
from tests.test_assembly_solver import _make_box_part, client

BAR_L_X, BAR_R_X, BAR = 0.0, 60.0, 10.0  # inner faces: x = 10 (normal +x) and x = 60 (normal -x); the gap is 10..60, centre 35


def _fr(part: dict, normal) -> dict:
    return {"face_ref": _face(part, normal)["subshape_ref"]}


def _scene(plate_parts: int = 1, fix_bars: bool = True):
    bar_l = _make_box_part("BarL", size=BAR, depth=40.0)
    bar_r = _make_box_part("BarR", size=BAR, depth=40.0)
    base = _make_box_part("Base", size=5.0, depth=5.0)
    if plate_parts == 1:
        plate_a = _make_box_part("Plate", size=30.0, depth=5.0)  # x 0..30: faces at 0 and 30
        plate_b = None
        occurrences = [("barL", bar_l, (BAR_L_X, 0, 0)), ("barR", bar_r, (BAR_R_X, 0, 0)), ("plate", plate_a, (7.0, 3.0, 11.0))]
    else:
        plate_a = _make_box_part("PlateA", size=12.0, depth=5.0)  # x 0..12
        plate_b = _make_box_part("PlateB", size=12.0, depth=5.0)
        occurrences = [
            ("barL", bar_l, (BAR_L_X, 0, 0)),
            ("barR", bar_r, (BAR_R_X, 0, 0)),
            ("plateA", plate_a, (14.0, 3.0, 11.0)),
            ("plateB", plate_b, (40.0, 4.0, 11.0)),
        ]
    root = _compose(base, occurrences)
    if fix_bars:
        for oid in ("barL", "barR"):
            assert client.patch(f"/document/parts/{root}/occurrences/{oid}", json={"fixed": True}).status_code == 200
    return root, bar_l, bar_r, plate_a, plate_b


def _gap(bar_l, bar_r) -> dict:
    return {
        "occurrence_id": "barL",
        "midplane": {"a": _fr(bar_l, (1, 0, 0)), "b": _fr(bar_r, (-1, 0, 0)), "b_occurrence_id": "barR"},
    }


def _tab_one(plate) -> dict:
    return {"occurrence_id": "plate", "midplane": {"a": _fr(plate, (-1, 0, 0)), "b": _fr(plate, (1, 0, 0))}}


def _tab_two(plate_a, plate_b) -> dict:
    return {
        "occurrence_id": "plateA",
        "midplane": {"a": _fr(plate_a, (-1, 0, 0)), "b": _fr(plate_b, (1, 0, 0)), "b_occurrence_id": "plateB"},
    }


def _poses(root: str) -> dict:
    return {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}


def _x(root: str, occurrence: str, local_x: float) -> float:
    return _poses(root)[occurrence]["translation"][0] + local_x  # no rotation in these scenes' x


def _create(root: str, payload: dict, solve_on: str):
    return client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": solve_on}, json=payload)


def _objects(root: str):
    document = get_document()
    return {
        pid: ([f.id for f in p.features], [o.id for o in p.occurrences]) for pid, p in sorted(document.parts.items())
    }


@pytest.mark.parametrize("start", [(7.0, 3.0, 11.0), (30.0, 9.0, 2.0), (-40.0, 25.0, 30.0)], ids=["near", "medium", "far"])
def test_three_parts_two_fixed_bars_and_a_plate_centre_it_between_them(start):
    root, bar_l, bar_r, plate, _ = _scene(1)
    client.patch(
        f"/document/parts/{root}/occurrences/plate",
        json={"transform": {"translation": list(start), "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}},
    )
    objects = _objects(root)
    response = _create(root, {"type": "coincident", "references": [_tab_one(plate), _gap(bar_l, bar_r)]}, "plate")
    assert response.status_code == 201, response.text
    # plate faces x = 0 and 30 (local) -> centre local 15 must land on 35
    assert _x(root, "plate", 15.0) == pytest.approx(35.0, abs=1e-6)
    assert _objects(root) == objects  # no part, feature or occurrence was added for the mid-plane


def test_three_fixed_bars_give_a_plain_plane_plane_constraint_model():
    root, bar_l, bar_r, plate, _ = _scene(1)
    assert _create(root, {"type": "coincident", "references": [_tab_one(plate), _gap(bar_l, bar_r)]}, "plate").status_code == 201
    document = get_document()
    spec = export_constraint_model(build_group_model(document, document.parts[root], "plate"))
    assert spec is not None
    (mate,) = spec["mates"]
    assert set(mate) == {"type", "value", "allow_rotation", "alignment", "side", "perp", "a", "b"}
    # the (fixed) mid-plane of the two bars is one world plane at x = 35 with no member
    fixed_side = mate["b"]
    assert fixed_side["member"] == -1 and fixed_side["plane"]["origin"][0] == pytest.approx(35.0, abs=1e-9)


def test_an_offset_from_the_centre_over_three_parts():
    root, bar_l, bar_r, plate, _ = _scene(1)
    payload = {"type": "distance", "value": 4.0, "alignment": "anti_aligned", "secondary_flip": True, "references": [_tab_one(plate), _gap(bar_l, bar_r)]}
    assert _create(root, payload, "plate").status_code == 201
    assert abs(_x(root, "plate", 15.0) - 35.0) == pytest.approx(4.0, abs=1e-6)


def test_gap_faces_that_are_not_parallel_are_a_422_and_nothing_is_stored():
    root, bar_l, bar_r, plate, _ = _scene(1, fix_bars=False)
    client.patch(
        f"/document/parts/{root}/occurrences/barR",
        json={"transform": {"translation": [BAR_R_X, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 10.0}},
    )
    response = client.post(
        f"/document/parts/{root}/mates", json={"type": "coincident", "references": [_tab_one(plate), _gap(bar_l, bar_r)]}
    )
    assert response.status_code == 422 and response.json()["detail"]["type"] == "faces_not_parallel"
    assert client.get(f"/document/parts/{root}/mates").json() == []


def test_a_gap_face_on_a_missing_occurrence_is_a_422():
    root, bar_l, bar_r, plate, _ = _scene(1)
    gap = _gap(bar_l, bar_r)
    gap["midplane"]["b_occurrence_id"] = "nope"
    response = client.post(f"/document/parts/{root}/mates", json={"type": "coincident", "references": [_tab_one(plate), gap]})
    assert response.status_code == 422


def test_three_parts_with_free_bars_hold_the_centre_and_export_no_constraint_model():
    root, bar_l, bar_r, plate, _ = _scene(1, fix_bars=False)
    # the bars are free: minimal movement moves only the plate; the centre still lands
    assert _create(root, {"type": "coincident", "references": [_tab_one(plate), _gap(bar_l, bar_r)]}, "plate").status_code == 201
    assert _x(root, "plate", 15.0) == pytest.approx(35.0, abs=1e-6)
    document = get_document()
    assert export_constraint_model(build_group_model(document, document.parts[root], "plate")) is None
    # grabbing a bar: the mate holds both bars and the plate to the same centre (the model is solved, just not exported)
    model = build_group_model(document, document.parts[root], "barL")
    assert set(model.member_ids) == {"barL", "barR", "plate"}
    assert np.max(np.abs(model.residual(np.zeros(model.n_vars)))) < 1e-6


@pytest.mark.parametrize("plate_a_x", [14.0, 5.0, -30.0], ids=["near", "medium", "far"])
def test_four_parts_a_tab_made_of_two_parts_between_a_gap_made_of_two_parts(plate_a_x):
    root, bar_l, bar_r, plate_a, plate_b = _scene(2, fix_bars=True)
    client.patch(
        f"/document/parts/{root}/occurrences/plateA",
        json={"transform": {"translation": [plate_a_x, 3.0, 11.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}},
    )
    objects = _objects(root)
    response = _create(root, {"type": "coincident", "references": [_tab_two(plate_a, plate_b), _gap(bar_l, bar_r)]}, "plateA")
    assert response.status_code == 201, response.text
    # tab mid-plane = halfway between plateA's left face (local x 0) and plateB's right face (local x 12)
    left, right = _x(root, "plateA", 0.0), _x(root, "plateB", 12.0)
    assert (left + right) / 2.0 == pytest.approx(35.0, abs=1e-6)
    assert _objects(root) == objects
    # the pair's faces stay parallel (the mate holds that: both plates are still axis-aligned)
    for oid in ("plateA", "plateB"):
        assert _poses(root)[oid]["rotation_angle_degrees"] == pytest.approx(0.0, abs=1e-5)
    document = get_document()
    assert export_constraint_model(build_group_model(document, document.parts[root], "plateA")) is None


def test_four_parts_survive_export_and_import_and_deleting_the_mate_leaves_the_objects():
    root, bar_l, bar_r, plate_a, plate_b = _scene(2, fix_bars=True)
    objects = _objects(root)
    mate = _create(root, {"type": "coincident", "references": [_tab_two(plate_a, plate_b), _gap(bar_l, bar_r)]}, "plateA").json()
    exported = client.get("/document/export/native", params={"part_id": root}).json()
    stored = [p for p in exported["document"]["parts"] if p["id"] == root][0]["mates"][0]
    assert stored["references"][0]["midplane"]["b_occurrence_id"] == "plateB"
    assert stored["references"][1]["midplane"]["b_occurrence_id"] == "barR"
    assert client.delete(f"/document/parts/{root}/mates/{mate['id']}").status_code == 204
    assert _objects(root) == objects


def test_deleting_any_of_the_involved_occurrences_removes_the_mate():
    root, bar_l, bar_r, plate_a, plate_b = _scene(2, fix_bars=False)
    assert _create(root, {"type": "coincident", "references": [_tab_two(plate_a, plate_b), _gap(bar_l, bar_r)]}, "plateA").status_code == 201
    # plateB / barR appear only as a mid-plane's second face - the mate must still go with them
    assert client.delete(f"/document/parts/{root}/occurrences/barR").status_code == 204
    assert client.get(f"/document/parts/{root}/mates").json() == []


def test_world_geometry_of_a_cross_part_gap_is_the_plane_between_the_bars():
    root, bar_l, bar_r, plate, _ = _scene(1)
    from app.document.router import _mate_entity_ref_to_domain  # the wire -> domain converter
    from app.document.schemas import MateEntityRefResponse
    from app.document.models import Mate, MateType

    refs = [_mate_entity_ref_to_domain(MateEntityRefResponse(**r)) for r in (_tab_one(plate), _gap(bar_l, bar_r))]
    document = get_document()
    first, second = mate_world_geometries(document, document.parts[root], Mate(id="m", type=MateType.COINCIDENT, references=refs))
    assert second.plane.origin[0] == pytest.approx(35.0, abs=1e-9)
    assert abs(sum(a * b for a, b in zip(second.plane.normal, (1, 0, 0)))) == pytest.approx(1.0, abs=1e-9)


def test_preview_and_group_drag_work_over_four_parts():
    root, bar_l, bar_r, plate_a, plate_b = _scene(2, fix_bars=True)
    payload = {"type": "coincident", "references": [_tab_two(plate_a, plate_b), _gap(bar_l, bar_r)]}
    ghost = client.post(f"/document/parts/{root}/occurrences/plateA/preview-mate-solve", params={"movement": "auto"}, json=payload).json()
    assert ghost["converged"] and ghost["resolved"]["alignment"] in ("aligned", "anti_aligned")
    assert ghost["controls"] == ["alignment"]
    assert _create(root, payload, "plateA").status_code == 201
    # a free-motion drag of a plate: the backend still answers (no constraint model is exported for this component)
    response = client.post(f"/document/parts/{root}/occurrences/plateB/mate-motion", json={})
    assert response.status_code == 200, response.text
    assert response.json().get("constraint_model") is None


@pytest.mark.parametrize("movement", ["auto", "group", "minimal"])
def test_four_parts_turned_away_still_centre_and_a_refusal_is_not_the_wrong_message(movement):
    root, bar_l, bar_r, plate_a, plate_b = _scene(2, fix_bars=True)
    axis = [0.3, 0.5, 0.8]
    for oid, base in (("plateA", (14.0, 3.0, 11.0)), ("plateB", (40.0, 4.0, 11.0))):
        client.patch(
            f"/document/parts/{root}/occurrences/{oid}",
            json={"transform": {"translation": list(base), "rotation_axis": axis, "rotation_angle_degrees": 70.0}},
        )
    payload = {"type": "coincident", "references": [_tab_two(plate_a, plate_b), _gap(bar_l, bar_r)]}
    response = client.post(f"/document/parts/{root}/mates", params={"solve": movement, "occurrence_id": "plateA"}, json=payload)
    if movement == "minimal":
        # only plateA may move, and its faces cannot stay parallel to plateB's then: refused as a plain non-convergence, never
        # as the single-occurrence solver's "cannot resolve a Width reference" error
        assert response.status_code == 422 and response.json()["detail"]["type"] == "mate_solve_did_not_converge"
        return
    assert response.status_code == 201, response.text
    document = get_document()
    model = build_group_model(document, document.parts[root], "plateA")
    assert np.max(np.abs(model.residual(np.zeros(model.n_vars)))) < 1e-6
