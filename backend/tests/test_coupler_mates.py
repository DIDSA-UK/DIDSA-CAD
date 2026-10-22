"""Coupler ("motion") mates - gear, rack and pinion, screw (`docs/gears-and-motion-plan.md` M3) - through the real HTTP surface.

Generic parts only (cylinders and boxes, no gear features): the ratio, travel and lead are typed. The auto-filled ratios and
senses, which need real gear parts, are in `test_coupler_mates_gears.py`."""

import math

import numpy as np

from tests.motion_scenes import _plate_with_hole, fix
from tests.test_assembly_group import _compose, _cyl, _face, _mate
from tests.test_assembly_solver import _create_part, _find_straight_edge, _make_box_part, _make_cylinder_part, client


def _occs(root):
    response = client.get(f"/document/parts/{root}/occurrences")
    assert response.status_code == 200, response.text
    return {o["id"]: o["transform"] for o in response.json()}


def _motion(root, oid, body):
    response = client.post(f"/document/parts/{root}/occurrences/{oid}/mate-motion", json=body)
    assert response.status_code == 200, response.text
    return response.json()


def _post_mate(root, mate_type, a, b, **extra):
    body = {"type": mate_type, "references": [a, b], **extra}
    return client.post(f"/document/parts/{root}/mates", json=body)


def _spin_z(transform) -> float:
    """The signed turn (degrees) of a pose's rotation about world z."""
    sign = 1.0 if transform["rotation_axis"][2] >= 0 else -1.0
    return sign * float(transform["rotation_angle_degrees"])


def _wish(transform, degrees: float) -> dict:
    wish = dict(transform)
    wish["rotation_axis"] = [0, 0, 1]
    wish["rotation_angle_degrees"] = degrees
    return wish


def _wrap(degrees: float) -> float:
    return (degrees + 180.0) % 360.0 - 180.0


def _ref(occurrence_id, face):
    return {"occurrence_id": occurrence_id, **face}


def gear_scene():
    """Two hole plates (fixed), a shaft in each hole (concentric + coincident on the plate top): each shaft only spins, 1 dof each."""
    plate = _plate_with_hole("GearPlate")
    shaft = _make_cylinder_part("GearShaft", radius=4.0, depth=20.0)
    root = _compose(_create_part("GearAssembly"), [("plate-a", plate, (0, 0, 0)), ("plate-b", plate, (60, 0, 0)), ("shaft-a", shaft, (30, 30, 10)), ("shaft-b", shaft, (90, 30, 10))])
    for side in "ab":
        _mate(root, "concentric", f"shaft-{side}", _cyl(shaft), f"plate-{side}", _cyl(plate))
        _mate(root, "coincident", f"shaft-{side}", _face(shaft, (0, 0, -1)), f"plate-{side}", _face(plate, (0, 0, 1)))
        fix(root, f"plate-{side}")
    return root, plate, shaft


def _gear_mate(root, shaft, value=0.5, **extra):
    response = _post_mate(root, "gear", _ref("shaft-a", _cyl(shaft)), _ref("shaft-b", _cyl(shaft)), value=value, **extra)
    assert response.status_code == 201, response.text
    return response.json()


# ---- create / list / PATCH / delete ----------------------------------------------------------------------------------


def test_create_list_patch_delete_a_gear_mate_and_nothing_moves():
    root, _plate, shaft = gear_scene()
    stored = _occs(root)
    mate = _gear_mate(root, shaft)
    assert mate["type"] == "gear" and mate["value"] == 0.5
    assert mate["secondary_flip"] is False  # parallel same-way axes, two external gears: they turn opposite ways, k = -1
    assert mate["branch_source"] == "auto" and mate["alignment"] is None
    assert _occs(root) == stored  # a coupler never pulls anything (D1)
    assert [m["id"] for m in client.get(f"/document/parts/{root}/mates").json() if m["type"] == "gear"] == [mate["id"]]
    patched = client.patch(f"/document/parts/{root}/mates/{mate['id']}", json={"value": 2.0, "secondary_flip": True})
    assert patched.status_code == 200 and patched.json()["value"] == 2.0 and patched.json()["secondary_flip"] is True and patched.json()["branch_source"] == "user"
    suppressed = client.patch(f"/document/parts/{root}/mates/{mate['id']}", json={"suppressed": True}).json()
    assert suppressed["suppressed"] is True
    assert client.delete(f"/document/parts/{root}/mates/{mate['id']}").status_code == 204
    assert not [m for m in client.get(f"/document/parts/{root}/mates").json() if m["type"] == "gear"]


def test_coupler_422s():
    root, plate, shaft = gear_scene()
    a, b = _ref("shaft-a", _cyl(shaft)), _ref("shaft-b", _cyl(shaft))
    for value in (0, -1.0):
        r = _post_mate(root, "gear", a, b, value=value)
        assert r.status_code == 422 and r.json()["detail"]["type"] == "invalid_coupler_value", r.text
    r = _post_mate(root, "gear", a, b)  # no gear feature on either part, no value
    assert r.status_code == 422 and r.json()["detail"]["type"] == "gear_ratio_required"
    r = _post_mate(root, "screw", a, b)
    assert r.status_code == 422 and r.json()["detail"]["type"] == "screw_lead_required"
    r = _post_mate(root, "rack_pinion", a, b, value=10.0)  # B is a cylinder, not a straight edge
    assert r.status_code == 422 and r.json()["detail"]["type"] == "rack_reference_not_straight_edge"
    r = _post_mate(root, "gear", a, _ref("shaft-a", _cyl(shaft)), value=1.0)
    assert r.status_code == 422  # the same occurrence twice
    r = _post_mate(root, "gear", a, _ref("shaft-b", _face(shaft, (0, 0, 1))), value=1.0)
    assert r.status_code == 422  # a planar face is not an axis
    r = _post_mate(root, "gear", a, {"occurrence_id": "shaft-b", "midplane": {"a": {"fixed_plane": "XY"}, "b": {"fixed_plane": "XZ"}}}, value=1.0)
    assert r.status_code == 422  # a Width reference
    mate = _gear_mate(root, shaft)
    bad = client.patch(f"/document/parts/{root}/mates/{mate['id']}", json={"value": -3.0})
    assert bad.status_code == 422 and bad.json()["detail"]["type"] == "invalid_coupler_value"
    assert client.get(f"/document/parts/{root}/mates").json()[-1]["value"] == 0.5


def test_native_round_trip_keeps_the_coupler():
    root, _plate, shaft = gear_scene()
    mate = _gear_mate(root, shaft, value=0.25, secondary_flip=True)
    exported = client.get("/document/export/native", params={"part_id": root})
    assert exported.status_code == 200
    stored = [m for p in exported.json()["document"]["parts"] for m in p["mates"] if m["type"] == "gear"]
    assert len(stored) == 1 and stored[0]["value"] == 0.25 and stored[0]["secondary_flip"] is True and stored[0]["branch_source"] == "user"
    assert client.post("/document/import/native", json=exported.json()).status_code == 200
    again = [m for m in client.get(f"/document/parts/{root}/mates").json() if m["type"] == "gear"]
    assert len(again) == 1 and again[0]["id"] == mate["id"] and again[0]["value"] == 0.25 and again[0]["secondary_flip"] is True


def test_a_file_without_couplers_is_unchanged():
    root, _plate, _shaft = gear_scene()
    exported = client.get("/document/export/native", params={"part_id": root}).json()
    types = {m["type"] for p in exported["document"]["parts"] for m in p["mates"]}
    assert types == {"concentric", "coincident"}


def test_preview_returns_the_current_pose_and_the_default_sense():
    root, _plate, shaft = gear_scene()
    stored = _occs(root)
    body = {"type": "gear", "references": [_ref("shaft-a", _cyl(shaft)), _ref("shaft-b", _cyl(shaft))], "value": 0.5}
    r = client.post(f"/document/parts/{root}/occurrences/shaft-b/preview-mate-solve", json=body)
    assert r.status_code == 200, r.text
    answer = r.json()
    assert answer["converged"] is True and answer["transform"] == stored["shaft-b"] and answer["coupler_value"] == 0.5
    assert answer["resolved"]["secondary_flip"] is False and answer["controls"] == ["secondary_flip"]
    assert _occs(root) == stored


# ---- solve / enforce move nothing ------------------------------------------------------------------------------------


def test_solve_with_a_coupler_present_moves_nothing():
    root, _plate, shaft = gear_scene()
    _gear_mate(root, shaft)
    stored = _occs(root)
    for oid in ("shaft-a", "shaft-b"):
        r = client.post(f"/document/parts/{root}/occurrences/{oid}/solve")
        assert r.status_code == 200, r.text
    after = _occs(root)
    for oid in ("shaft-a", "shaft-b"):
        assert np.allclose(after[oid]["translation"], stored[oid]["translation"], atol=1e-6)
        assert abs(_spin_z(after[oid]) - _spin_z(stored[oid])) < 1e-6
    status = client.get(f"/document/parts/{root}/constraint-status").json()
    assert status["shaft-a"]["status"] != "over_constrained" and status["shaft-b"]["status"] != "over_constrained"


# ---- motion ----------------------------------------------------------------------------------------------------------


def test_group_dof_is_one_and_a_model_of_version_5_comes_with_it():
    root, _plate, shaft = gear_scene()
    free = _motion(root, "shaft-a", {})
    assert free["dof"] == 1 and [m["occurrence_id"] for m in free["members"]] == ["shaft-a"]  # alone: its own spin
    _gear_mate(root, shaft)
    body = _motion(root, "shaft-a", {})
    assert body["converged"] and body["dof"] == 1 and body["grounded"] is True
    assert body["constraint_model"]["version"] == 5  # the analytic model (M6): clients can retract locally
    assert [m["occurrence_id"] for m in body["members"]] == ["shaft-a", "shaft-b"]


def test_gear_mate_turns_b_half_as_far_the_opposite_way():
    root, _plate, shaft = gear_scene()
    _gear_mate(root, shaft, value=0.5)
    stored = _occs(root)
    body = _motion(root, "shaft-a", {"transform": _wish(stored["shaft-a"], 90.0)})
    assert body["converged"] and body["quality"]["residual_inf"] < 1e-7
    poses = {m["occurrence_id"]: m["transform"] for m in body["members"]}
    assert abs(_spin_z(poses["shaft-a"]) - 90.0) < 0.1
    assert abs(_spin_z(poses["shaft-b"]) + 45.0) < 0.1  # opposite, half as far
    for oid, home in (("shaft-a", (30, 30, 10)), ("shaft-b", (90, 30, 10))):
        assert np.allclose(poses[oid]["translation"], home, atol=1e-6)  # still on its hole


def test_gear_mate_with_b_grabbed():
    root, _plate, shaft = gear_scene()
    _gear_mate(root, shaft, value=0.5)
    stored = _occs(root)
    body = _motion(root, "shaft-b", {"transform": _wish(stored["shaft-b"], 60.0)})
    assert body["converged"]
    poses = {m["occurrence_id"]: m["transform"] for m in body["members"]}
    assert abs(_spin_z(poses["shaft-b"]) - 60.0) < 0.1
    assert abs(_spin_z(poses["shaft-a"]) + 120.0) < 0.1


def test_reverse_switch_turns_the_same_way():
    root, _plate, shaft = gear_scene()
    _gear_mate(root, shaft, value=0.5, secondary_flip=True)
    stored = _occs(root)
    body = _motion(root, "shaft-a", {"transform": _wish(stored["shaft-a"], 90.0)})
    poses = {m["occurrence_id"]: m["transform"] for m in body["members"]}
    assert abs(_spin_z(poses["shaft-b"]) - 45.0) < 0.1


def test_warm_started_drag_through_400_degrees_unwraps():
    root, _plate, shaft = gear_scene()
    _gear_mate(root, shaft, value=0.5)
    start = _occs(root)
    reference = [{"occurrence_id": oid, "transform": start[oid]} for oid in ("shaft-a", "shaft-b")]
    previous_b = _spin_z(start["shaft-b"])
    total_b = 0.0
    for step in range(1, 11):  # ten 40-degree steps, each anchored on the last accepted poses
        body = _motion(root, "shaft-a", {"transform": _wish(start["shaft-a"], _wrap(40.0 * step)), "reference": reference})
        assert body["converged"], step
        poses = {m["occurrence_id"]: m["transform"] for m in body["members"]}
        now_b = _spin_z(poses["shaft-b"])
        total_b += _wrap(now_b - previous_b)
        previous_b = now_b
        reference = [{"occurrence_id": oid, "transform": poses[oid]} for oid in ("shaft-a", "shaft-b")]
    assert abs(total_b + 200.0) < 0.1, total_b


def _box_with_edge(name, size, depth):
    part = _make_box_part(name, size=size, depth=depth)
    return part, _find_straight_edge(part["id"], part["body_id"], (1, 0, 0))


def rack_scene():
    """A pinion on a hole plate and a rack block that can only slide along x (flat on the plate, side face on a fixed guide); rack and pinion mate, 10 mm per turn."""
    plate = _plate_with_hole("PinionPlate")
    shaft = _make_cylinder_part("PinionShaft", radius=4.0, depth=20.0)
    guide = _make_box_part("Guide", size=10.0, depth=10.0)
    rack, edge = _box_with_edge("Rack", 8.0, 4.0)
    root = _compose(_create_part("RackAssembly"), [("plate", plate, (0, 0, 0)), ("pinion", shaft, (30, 30, 10)), ("guide", guide, (20, 70, 0)), ("rack", rack, (20, 62, 10))])
    _mate(root, "concentric", "pinion", _cyl(shaft), "plate", _cyl(plate))
    _mate(root, "coincident", "pinion", _face(shaft, (0, 0, -1)), "plate", _face(plate, (0, 0, 1)))
    _mate(root, "coincident", "rack", _face(rack, (0, 0, -1)), "plate", _face(plate, (0, 0, 1)))
    _mate(root, "coincident", "rack", _face(rack, (0, 1, 0)), "guide", _face(guide, (0, -1, 0)))
    fix(root, "plate")
    fix(root, "guide")
    made = _post_mate(root, "rack_pinion", _ref("pinion", _cyl(shaft)), _ref("rack", {"subshape_ref": {"body_id": rack["body_id"], "shape_type": "edge", "index": edge}}), value=10.0)
    assert made.status_code == 201, made.text
    return root, made


def screw_scene():
    """A fixed screw and a nut plate concentric to it (free to turn and slide); screw mate, lead 2 mm."""
    plate = _plate_with_hole("NutPlate", size=40.0, depth=6.0, at=(20.0, 20.0))
    screw = _make_cylinder_part("Screw", radius=4.0, depth=40.0)
    root = _compose(_create_part("ScrewAssembly"), [("screw", screw, (20, 20, -10)), ("nut", plate, (0, 0, 10))])
    _mate(root, "concentric", "nut", _cyl(plate), "screw", _cyl(screw))
    fix(root, "screw")
    made = _post_mate(root, "screw", _ref("screw", _cyl(screw)), _ref("nut", _cyl(plate)), value=2.0)
    assert made.status_code == 201, made.text
    return root, made


def test_rack_and_pinion_and_the_reverse_switch():
    root, made = rack_scene()
    stored = _occs(root)
    body = _motion(root, "pinion", {"transform": _wish(stored["pinion"], 180.0)})
    assert body["converged"], body
    moved = {m["occurrence_id"]: np.array(m["transform"]["translation"]) - np.array(stored[m["occurrence_id"]]["translation"]) for m in body["members"]}
    assert np.allclose(moved["rack"][1:], 0, atol=1e-6) and abs(abs(moved["rack"][0]) - 5.0) < 1e-3  # half a turn of a 10 mm/turn pinion
    direction = math.copysign(1.0, moved["rack"][0])
    assert client.patch(f"/document/parts/{root}/mates/{made.json()['id']}", json={"secondary_flip": not made.json()["secondary_flip"]}).status_code == 200
    again = _motion(root, "pinion", {"transform": _wish(stored["pinion"], 180.0)})
    rack_pose = next(m for m in again["members"] if m["occurrence_id"] == "rack")
    assert math.copysign(1.0, rack_pose["transform"]["translation"][0] - stored["rack"]["translation"][0]) == -direction


def test_screw_nut_climbs_its_lead():
    root, made = screw_scene()
    assert made.json()["secondary_flip"] is True  # right-hand
    start = _occs(root)
    reference = [{"occurrence_id": "nut", "transform": start["nut"]}]
    previous = _spin_z(start["nut"])
    turned = 0.0
    z = start["nut"]["translation"][2]
    for step in range(1, 9):  # eight quarter turns = two full turns
        body = _motion(root, "nut", {"transform": _wish(start["nut"], _wrap(90.0 * step)), "reference": reference})
        assert body["converged"], step
        pose = next(m["transform"] for m in body["members"] if m["occurrence_id"] == "nut")
        turned += _wrap(_spin_z(pose) - previous)
        previous = _spin_z(pose)
        reference = [{"occurrence_id": "nut", "transform": pose}]
        z = pose["translation"][2]
    assert abs(turned - 720.0) < 0.1
    assert abs((z - start["nut"]["translation"][2]) - 4.0) < 1e-3  # two turns of a 2 mm lead
