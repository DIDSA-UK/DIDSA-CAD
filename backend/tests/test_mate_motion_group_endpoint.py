"""Constrained drag S3: the `mate-motion` contract of record (plan §3), and `/solve` +
`/preview-mate-solve` re-implemented on the group solver - through the real HTTP surface,
real OCCT + py-slvs."""

import numpy as np

from tests.test_assembly_group import _compose, _face, _mate, _plate_bcd
from tests.test_assembly_solver import _make_box_part, client


def _occs(root):
    response = client.get(f"/document/parts/{root}/occurrences")
    assert response.status_code == 200, response.text
    return {o["id"]: o["transform"] for o in response.json()}


def _motion(root, oid, body):
    return client.post(f"/document/parts/{root}/occurrences/{oid}/mate-motion", json=body)


def _shifted(transform, dx=0.0, dy=0.0, dz=0.0):
    t = dict(transform)
    t["translation"] = [transform["translation"][0] + dx, transform["translation"][1] + dy, transform["translation"][2] + dz]
    return t


def _t(transform):
    return np.array(transform["translation"], float)


def test_contract_shape_group_dof_basis_and_members():
    root, _p, _parts = _plate_bcd()
    stored = _occs(root)
    r = _motion(root, "occ-B", {"transform": None, "lever_arm": 12.5})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["converged"] is True and body["dof"] == 5 and body["grounded"] is True
    assert [m["occurrence_id"] for m in body["members"]] == ["occ-B", "occ-C", "occ-D"]
    assert [m["mobility"] for m in body["members"]] == [3, 3, 3]
    assert len(body["basis"]) == 5 and all(len(row) == 18 for row in body["basis"])
    w = np.array([1, 1, 1, 12.5, 12.5, 12.5] * 3)
    y = np.array(body["basis"]) * w
    assert np.allclose(y @ y.T, np.eye(5), atol=1e-9)  # orthonormal in the lever-arm metric
    assert body["chart"] == {"kind": "se3_owner_frame", "lever_arm": 12.5}
    q = body["quality"]
    assert q["residual_inf"] < 1e-7 and q["sigma_min"] > 0 and q["sigma_gap"] > 1 and q["jump"] < 1e-6 and q["max_step"] is None
    assert body["diagnostics"]["solve_ms"] > 0 and body["committed"] is False
    assert "transform" not in body and "free_twists" not in body  # the v0 single-occurrence aliases are gone
    assert _occs(root) == stored  # nothing stored without commit


def test_default_lever_arm_is_the_bounding_radius_and_bad_lever_arm_is_422():
    root, _p, _parts = _plate_bcd()
    body = _motion(root, "occ-B", {}).json()
    assert body["chart"]["lever_arm"] > 0
    assert _motion(root, "occ-B", {"lever_arm": 0}).status_code == 422


def test_drag_b_plus_6_y_moves_b_and_d_and_commit_persists_the_whole_group():
    root, _p, _parts = _plate_bcd()
    stored = _occs(root)
    wish = _shifted(stored["occ-B"], dy=6.0)
    r = _motion(root, "occ-B", {"transform": wish, "lever_arm": 10.0, "commit": False}).json()
    moved = {m["occurrence_id"]: _t(m["transform"]) - _t(stored[m["occurrence_id"]]) for m in r["members"]}
    assert np.allclose(moved["occ-B"], (0, 6, 0), atol=1e-6) and np.allclose(moved["occ-D"], (0, 6, 0), atol=1e-6)
    assert np.allclose(moved["occ-C"], 0, atol=1e-6)
    assert _occs(root) == stored

    c = _motion(root, "occ-B", {"transform": wish, "lever_arm": 10.0, "commit": True}).json()
    assert c["converged"] and c["committed"] is True
    after = _occs(root)
    for m in c["members"]:
        assert np.allclose(_t(after[m["occurrence_id"]]), _t(m["transform"]), atol=1e-9)
    assert np.allclose(_t(after["occ-D"]) - _t(stored["occ-D"]), (0, 6, 0), atol=1e-6)


def test_fixed_grabbed_occurrence_is_422():
    root, _p, _parts = _plate_bcd()
    assert client.patch(f"/document/parts/{root}/occurrences/occ-B", json={"fixed": True}).status_code == 200
    r = _motion(root, "occ-B", {})
    assert r.status_code == 422 and r.json()["detail"]["type"] == "occurrence_is_fixed"


def test_non_convergence_reports_no_basis_and_commit_stores_nothing():
    root, _p, parts = _plate_bcd()
    # Contradicts B's coincident mate with the plate (flush vs 5 mm apart).
    plate_top = client.get(f"/document/parts/{root}/mates").json()[0]["references"][1]
    _mate(root, "distance", "occ-B", _face(parts["B"], (0, 0, -1)), "", {"subshape_ref": plate_top["subshape_ref"]}, value=5.0)
    stored = _occs(root)
    for commit in (False, True):
        r = _motion(root, "occ-B", {"transform": _shifted(stored["occ-B"], dy=3.0), "commit": commit})
        assert r.status_code == 200
        body = r.json()
        assert body["converged"] is False
        assert body["basis"] is None and body["dof"] is None and body["members"] == [] and body["committed"] is False
        assert body["quality"]["residual_inf"] > 1.0
        assert _occs(root) == stored


def test_ungrounded_component_reports_grounded_false():
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    b = _make_box_part("B", size=8.0, depth=4.0)
    c = _make_box_part("C", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-B", b, (20, 20, 30)), ("occ-C", c, (28, 20, 30))])
    _mate(root, "coincident", "occ-B", _face(b, (1, 0, 0)), "occ-C", _face(c, (-1, 0, 0)))
    body = _motion(root, "occ-B", {}).json()
    assert body["converged"] and body["grounded"] is False and body["dof"] == 9


def test_solve_endpoint_now_moves_followers_and_stores_the_group():
    root, _p, _parts = _plate_bcd()
    stored = _occs(root)
    # The gizmo's raw PATCH first, then /solve (the flat app's flow): B dragged 4 mm in x.
    assert client.patch(f"/document/parts/{root}/occurrences/occ-B", json={"transform": _shifted(stored["occ-B"], dx=4.0)}).status_code == 200
    r = client.post(f"/document/parts/{root}/occurrences/occ-B/solve")
    assert r.status_code == 200, r.text
    after = _occs(root)
    assert np.allclose(_t(after["occ-B"]) - _t(stored["occ-B"]), (4, 0, 0), atol=1e-6)
    assert np.allclose(_t(after["occ-C"]) - _t(stored["occ-C"]), (4, 0, 0), atol=1e-6)  # C rides along (was frozen before)
    assert np.allclose(_t(after["occ-D"]) - _t(stored["occ-D"]), 0, atol=1e-6)  # D only shares B's y-face: it may stay


def test_solve_endpoint_non_convergence_is_still_422_and_stores_nothing():
    root, _p, parts = _plate_bcd()
    plate_top = client.get(f"/document/parts/{root}/mates").json()[0]["references"][1]
    _mate(root, "distance", "occ-B", _face(parts["B"], (0, 0, -1)), "", {"subshape_ref": plate_top["subshape_ref"]}, value=5.0)
    stored = _occs(root)
    r = client.post(f"/document/parts/{root}/occurrences/occ-B/solve")
    assert r.status_code == 422 and r.json()["detail"]["type"] == "mate_solve_did_not_converge"
    assert _occs(root) == stored


def test_preview_mate_solve_uses_the_group_and_stores_nothing():
    root, _p, parts = _plate_bcd()
    stored = _occs(root)
    plate_top = client.get(f"/document/parts/{root}/mates").json()[0]["references"][1]
    # Hypothetical: a second, consistent coincident mate of D's bottom on the plate top.
    payload = {
        "type": "coincident",
        "references": [
            {"occurrence_id": "occ-D", **_face(parts["D"], (0, 0, -1))},
            {"occurrence_id": "", "subshape_ref": plate_top["subshape_ref"]},
        ],
        "flipped": False,
    }
    r = client.post(f"/document/parts/{root}/occurrences/occ-D/preview-mate-solve", json=payload)
    assert r.status_code == 200 and r.json()["converged"] is True
    assert _occs(root) == stored
