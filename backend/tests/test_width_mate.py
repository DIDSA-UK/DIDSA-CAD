"""Width mate (`docs/width-mate-plan.md`, W1): a COINCIDENT / DISTANCE / PARALLEL mate whose references are mid-planes
(`MateEntityRef.midplane`: two parallel faces, resolved on the fly - nothing is ever stored for them).

* the tester's table top is centred between the frame's two inner y faces to 1e-6 from near / medium / far starts, with an
  offset of +/-5 mm on the named side;
* the errors (non-parallel faces, faces on different occurrences, a wrong mate type) and the two drift states;
* the no-clutter rule (plan 4a): create + delete leaves the document identical, export/import adds no objects, a user's own
  Plane survives deleting the mate;
* the constraint model of a Width mate is a plain plane-plane model, and the golden vectors need no regeneration.
"""

import copy
import json

import numpy as np
import pytest

from app.document.assembly import apply_transform_to_point
from app.document.assembly_group import build_group_model
from app.document.constraint_model import export_constraint_model
from app.document.models import RigidTransform
from app.document.store import get_document
from tests import table_top_fixture as tt
from tests.test_assembly_group import _compose, _face
from tests.test_assembly_solver import _make_box_part, client

PLATE_Y_FACES = (0, 2)  # the plate's two 780 mm faces (local -y / +y)
FRAME_INNER_FACE = 7  # a bar's inner face (local -z): world y = 60 on the y = 0 bar, 740 on the y = 800 bar
FRAME_CENTRE_Y = 400.0


def _fr(body_id: str, index: int) -> dict:
    return {"face_ref": {"body_id": body_id, "shape_type": "face", "index": index}}


def _plate_width() -> dict:
    return {"occurrence_id": tt.PLATE, "midplane": {"a": _fr(tt.PLATE_BODY, PLATE_Y_FACES[0]), "b": _fr(tt.PLATE_BODY, PLATE_Y_FACES[1])}}


def _frame_width(**changes) -> dict:
    ref = {
        "occurrence_id": tt.FRAME_BAR_Y0,
        "midplane": {
            "a": _fr(tt.FRAME_BODY, FRAME_INNER_FACE),
            "b": _fr(tt.FRAME_BODY, FRAME_INNER_FACE),
            "b_occurrence_id": tt.FRAME_BAR_Y800,
        },
    }
    ref["midplane"].update(changes)
    return ref


def _width_payload(mate_type="coincident", **fields) -> dict:
    return {"type": mate_type, "references": [_plate_width(), _frame_width()], **fields}


def _set_pose(root: str, transform: dict) -> None:
    response = client.patch(f"/document/parts/{root}/occurrences/{tt.PLATE}", json={"transform": transform})
    assert response.status_code == 200, response.text


def _plate_transform(root: str) -> RigidTransform:
    occ = {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}[tt.PLATE]
    return RigidTransform(tuple(occ["translation"]), tuple(occ["rotation_axis"]), occ["rotation_angle_degrees"])


def _plate_centre_y(transform: RigidTransform) -> float:
    """World y of the plate's mid-plane between its two y faces (plate local y = 0 and 780), from the pose alone."""
    ys = [apply_transform_to_point(transform, (0.0, y, 0.0))[1] for y in (0.0, 780.0)]
    return sum(ys) / 2.0


def _correct():
    return np.array(tt.CORRECT_PLATE_TRANSLATION)


def _start(kind: str) -> dict:
    flipped = {"rotation_axis": [1.0, 0.0, 0.0], "rotation_angle_degrees": 180.0}
    if kind == "near":
        return {"translation": [float(x) for x in _correct() + np.array([0.0, 5.0, 0.0])], **flipped}
    if kind == "medium":
        return {"translation": [float(x) for x in _correct() + np.array([12.0, -30.0, 8.0])], **flipped}
    return {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.3, 0.5, 0.8], "rotation_angle_degrees": 70.0}  # far


def _stored_mates(root: str) -> list[dict]:
    return client.get(f"/document/parts/{root}/mates").json()


# ---- poses on the tester's table top --------------------------------------------------------------------------------


@pytest.mark.parametrize("start", ["near", "medium", "far"])
@pytest.mark.parametrize("branch", [{}, {"alignment": "aligned"}, {"alignment": "anti_aligned"}], ids=["unnamed", "aligned", "anti_aligned"])
def test_the_plate_is_centred_between_the_frames_inner_faces(start, branch):
    root = tt.import_table_top(client, keep_mates=False)
    _set_pose(root, _start(start))
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json=_width_payload(**branch))
    assert response.status_code == 201, response.text
    assert abs(_plate_centre_y(_plate_transform(root)) - FRAME_CENTRE_Y) < 1e-6
    stored = _stored_mates(root)[0]
    assert stored["alignment"] in ("aligned", "anti_aligned")
    if "alignment" in branch:
        assert stored["alignment"] == branch["alignment"]
    assert stored["references"][0]["midplane"] is not None and stored["references"][0]["subshape_ref"] is None


@pytest.mark.parametrize("start", ["near", "medium", "far"])
@pytest.mark.parametrize("flip,sign", [(False, 1.0), (True, -1.0)])
def test_an_offset_lands_off_centre_by_exactly_that_on_the_named_side(start, flip, sign):
    root = tt.import_table_top(client, keep_mates=False)
    _set_pose(root, _start(start))
    payload = _width_payload("distance", value=5.0, alignment="aligned", secondary_flip=flip)
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json=payload)
    assert response.status_code == 201, response.text
    # the offset runs along the FIXED mid-plane's normal (the first frame bar's inner face, +y) for secondary_flip False
    assert _plate_centre_y(_plate_transform(root)) == pytest.approx(FRAME_CENTRE_Y + sign * 5.0, abs=1e-6)


def test_a_width_mate_previews_and_offers_alternatives_like_any_plane_mate():
    root = tt.import_table_top(client, keep_mates=False)
    _set_pose(root, _start("medium"))
    ghost = client.post(
        f"/document/parts/{root}/occurrences/{tt.PLATE}/preview-mate-solve", params={"movement": "auto"}, json=_width_payload()
    ).json()
    assert ghost["converged"] and ghost["resolved"]["alignment"] in ("aligned", "anti_aligned")
    assert "midplane" not in json.dumps(ghost["transform"])  # the preview returns a pose, no plane geometry
    # a Width mate does not break the other mates' branch machinery: add the tester's bottom face mate next to it
    assert client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json=_width_payload()).status_code == 201
    bottom = tt.table_top_mate_payloads()[2]
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json={**bottom, "alignment": "anti_aligned"})
    assert response.status_code == 201, response.text
    assert abs(_plate_centre_y(_plate_transform(root)) - FRAME_CENTRE_Y) < 1e-6


# ---- errors and drift ------------------------------------------------------------------------------------------------


def _post(root, payload):
    return client.post(f"/document/parts/{root}/mates", json=payload)


def test_non_parallel_faces_are_a_422():
    root = tt.import_table_top(client, keep_mates=False)
    skewed = {"occurrence_id": tt.PLATE, "midplane": {"a": _fr(tt.PLATE_BODY, 0), "b": _fr(tt.PLATE_BODY, 4)}}  # a y face and an x face
    response = _post(root, {"type": "coincident", "references": [skewed, _frame_width()]})
    assert response.status_code == 422 and response.json()["detail"]["type"] == "faces_not_parallel"
    assert _stored_mates(root) == []


def test_faces_on_different_top_level_occurrences_are_a_422():
    root = tt.import_table_top(client, keep_mates=False)
    across = {"occurrence_id": tt.FRAME_BAR_Y0, "midplane": {"a": _fr(tt.FRAME_BODY, 7), "b": _fr(tt.PLATE_BODY, 2), "b_occurrence_id": tt.PLATE}}
    response = _post(root, {"type": "coincident", "references": [_plate_width(), across]})
    assert response.status_code == 422 and response.json()["detail"]["type"] == "midplane_faces_on_different_occurrences"
    assert _stored_mates(root) == []


@pytest.mark.parametrize("mate_type", ["concentric", "angle"])
def test_a_midplane_reference_is_refused_for_the_wrong_mate_type(mate_type):
    root = tt.import_table_top(client, keep_mates=False)
    response = _post(root, {"type": mate_type, "value": 30.0, "references": [_plate_width(), _frame_width()]})
    assert response.status_code == 422 and "Width" in response.json()["detail"]
    assert _stored_mates(root) == []


def test_a_reference_needs_exactly_one_of_its_fields():
    root = tt.import_table_top(client, keep_mates=False)
    both = {**_plate_width(), "subshape_ref": {"body_id": tt.PLATE_BODY, "shape_type": "face", "index": 0}}
    assert _post(root, {"type": "coincident", "references": [both, _frame_width()]}).status_code == 422


def _break_stored_midplane(root: str, **changes) -> None:
    mate = get_document().parts[root].mates[0]
    ref = mate.references[1]
    mp = ref.midplane
    replacement = type(mp)(**{**mp.__dict__, **changes})
    mate.references[1] = type(ref)(occurrence_id=ref.occurrence_id, midplane=replacement)


def test_drift_a_lost_face_and_faces_that_are_no_longer_parallel_are_distinct_named_errors():
    from app.document.models import PlaneRef, SubShapeRef, SubShapeType

    root = tt.import_table_top(client, keep_mates=False)
    assert _post(root, _width_payload()).status_code == 201
    document = get_document()
    part = document.parts[root]
    mate = part.mates[0]
    original = mate.references[1].midplane
    # a part edit that removes the face
    _break_stored_midplane(root, b=PlaneRef(face_ref=SubShapeRef(body_id=tt.FRAME_BODY, shape_type=SubShapeType.FACE, index=999)))
    with pytest.raises(Exception) as lost:
        build_group_model(document, part, tt.PLATE)
    assert lost.value.detail["type"] == "missing_reference"
    # a part edit that leaves both faces but turns one: an x face against the y face
    _break_stored_midplane(root, b=PlaneRef(face_ref=SubShapeRef(body_id=tt.FRAME_BODY, shape_type=SubShapeType.FACE, index=9)))
    with pytest.raises(Exception) as skewed:
        build_group_model(document, part, tt.PLATE)
    assert skewed.value.detail["type"] == "faces_not_parallel"
    _break_stored_midplane(root, a=original.a, b=original.b)
    build_group_model(document, part, tt.PLATE)  # restored: resolves again


# ---- no clutter, no orphans (plan 4a) -------------------------------------------------------------------------------------


def _objects(root: str) -> dict:
    """Everything the document holds except the mates themselves: parts, features, planes, sketches, occurrences."""
    payload = client.get("/document/export/native", params={"part_id": root}).json()
    payload = copy.deepcopy(payload)
    for part in payload["document"]["parts"]:
        part["mates"] = []
    return payload


def test_creating_then_deleting_a_width_mate_leaves_the_document_identical():
    root = tt.import_table_top(client, keep_mates=False)
    before = _objects(root)
    planes_before = _plane_features()
    mate = _post(root, _width_payload()).json()
    assert _plane_features() == planes_before
    during = _objects(root)
    assert during == before  # creating it added no part, feature, plane, sketch or occurrence
    assert client.delete(f"/document/parts/{root}/mates/{mate['id']}").status_code == 204
    assert _objects(root) == before
    assert _plane_features() == planes_before


def _plane_features() -> list[str]:
    return sorted(f.id for p in get_document().parts.values() for f in p.features if f.__class__.__name__ == "CreatePlaneFeature")


def test_export_and_import_round_trip_a_width_mate_and_add_no_objects():
    root = tt.import_table_top(client, keep_mates=False)
    assert _post(root, _width_payload("distance", value=5.0, alignment="aligned", secondary_flip=True)).status_code == 201
    exported = client.get("/document/export/native", params={"part_id": root}).json()
    stored = [m for m in exported["document"]["parts"] if m["id"] == root][0]["mates"]
    assert stored[0]["references"][0]["midplane"]["a"]["face_ref"]["index"] == PLATE_Y_FACES[0]
    assert stored[0]["references"][1]["midplane"]["b_occurrence_id"] == tt.FRAME_BAR_Y800
    # re-import the export: the same mates and the same objects (the importer re-resolves external refs, so ignore those)
    assert client.post("/document/import/native", json=exported).status_code == 200
    again = client.get("/document/export/native", params={"part_id": root}).json()

    def strip(payload):
        payload = copy.deepcopy(payload)
        for part in payload["document"]["parts"]:
            for occurrence in part["occurrences"]:
                occurrence.pop("resolved_part_id", None)
        return payload

    assert strip(again) == strip(exported)
    # no object beyond the mate's own references: the export carries the same parts/features/sketches/occurrences with and without it
    bare = copy.deepcopy(exported)
    for part in bare["document"]["parts"]:
        part["mates"] = []
    assert {k: v for k, v in bare.items() if k != "document"} == {k: v for k, v in exported.items() if k != "document"}
    assert [(p["id"], [f["id"] for f in p["features"]], [o["id"] for o in p["occurrences"]]) for p in bare["document"]["parts"]] == [
        (p["id"], [f["id"] for f in p["features"]], [o["id"] for o in p["occurrences"]]) for p in again["document"]["parts"]
    ]


def test_a_file_without_a_midplane_loads_unchanged():
    root = tt.import_table_top(client)  # the tester's legacy mates
    mates = _stored_mates(root)
    assert len(mates) == 3 and all(r["midplane"] is None for m in mates for r in m["references"])
    exported = client.get("/document/export/native", params={"part_id": root}).json()
    assert "midplane" not in json.dumps(exported)  # nothing new is written for mates without one


def _plane(part_id: str, body_id: str, index: int) -> str:
    response = client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={"plane_type": "offset_face", "face_refs": [_fr(body_id, index)], "offset": 0.0},
    )
    assert response.status_code == 201, response.text
    return response.json()["id"]


def test_a_plane_the_user_made_and_referenced_survives_deleting_the_mate():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    # the user's own plane on the bracket's top face; the Width mate's other face is the bracket's underside
    top = _face(bracket, (0, 0, 1))["subshape_ref"]["index"]
    bottom = _face(bracket, (0, 0, -1))["subshape_ref"]["index"]
    plane_id = _plane(bracket["id"], bracket["body_id"], top)
    root = _compose(base, [("occ-driven", bracket, (3.0, 3.0, 20.0))])
    base_top = _face(base, (0, 0, 1))["subshape_ref"]["index"]
    base_bottom = _face(base, (0, 0, -1))["subshape_ref"]["index"]
    payload = {
        "type": "coincident",
        "references": [
            {"occurrence_id": "occ-driven", "midplane": {"a": {"plane_feature_id": plane_id}, "b": _fr(bracket["body_id"], bottom)}},
            {"occurrence_id": "", "midplane": {"a": _fr(base["body_id"], base_bottom), "b": _fr(base["body_id"], base_top)}},
        ],
    }
    created = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": "occ-driven"}, json=payload)
    assert created.status_code == 201, created.text
    transform = client.get(f"/document/parts/{root}/occurrences").json()[0]["transform"]
    # bracket mid-plane (z 0..4 -> 2) on the base's (z 0..10 -> 5): the bracket sits at z = 3
    assert transform["translation"][2] == pytest.approx(3.0, abs=1e-6)
    features_before = [f["id"] for f in client.get(f"/document/parts/{bracket['id']}/features").json()]
    assert plane_id in features_before
    assert client.delete(f"/document/parts/{root}/mates/{created.json()['id']}").status_code == 204
    assert [f["id"] for f in client.get(f"/document/parts/{bracket['id']}/features").json()] == features_before


# ---- parity ----------------------------------------------------------------------------------------------------------------


def test_the_constraint_model_of_a_width_mate_is_a_plain_plane_plane_model():
    root = tt.import_table_top(client, keep_mates=False)
    _set_pose(root, _start("medium"))
    created = client.post(
        f"/document/parts/{root}/mates",
        params={"solve": "auto", "occurrence_id": tt.PLATE},
        json=_width_payload("distance", value=5.0, alignment="aligned", secondary_flip=False),
    )
    assert created.status_code == 201, created.text
    document = get_document()
    spec = export_constraint_model(build_group_model(document, document.parts[root], tt.PLATE))
    assert spec is not None
    json.dumps(spec)
    (mate,) = spec["mates"]
    assert mate["type"] == "distance" and mate["value"] == 5.0
    assert set(mate) == {"type", "value", "allow_rotation", "alignment", "side", "perp", "a", "b"}  # no new key
    for side in (mate["a"], mate["b"]):
        assert set(side) <= {"member", "frozen", "point", "direction", "plane"}
        assert set(side["plane"]) == {"origin", "normal"}
    # and the model still holds: the solved poses satisfy the residual
    model = build_group_model(document, document.parts[root], tt.PLATE)
    assert np.max(np.abs(model.residual(np.zeros(model.n_vars)))) < 1e-6
