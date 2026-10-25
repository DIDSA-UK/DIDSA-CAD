"""M9: limit mates (`limit_distance`, `limit_angle`; `docs/limit-mates-scope.md`) - the HTTP surface, the group solve's active set and the
exported constraint model (version 6) with its client-side active-set retraction."""

import math

import numpy as np

from app.document.assembly_group import build_group_model, solve_group
from app.document.constraint_model import (
    COUPLER_MODEL_VERSION,
    LIMIT_MODEL_VERSION,
    MODEL_VERSION,
    ConstraintModel,
    apply_delta as apply_pose,
    export_constraint_model,
    rigid_to_pose,
    sqp_nearest_limits,
    weights,
)
from app.document.store import get_document
from tests.motion_scenes import _plate_with_hole, fix
from tests.test_assembly_group import _compose, _cyl, _face, _mate
from tests.test_assembly_solver import _create_part, _make_box_part, client
from tests.test_coupler_mates import _motion, _occs, _post_mate, _ref, _spin_z, _wish


def slider_scene():
    """A block that slides along x (flat on a fixed plate, side face on a fixed guide) with a fixed stop box ahead of it. Its +x face
    and the stop's -x face face each other: the limit_distance value (block face - stop face) . (-x) is the gap, 20 mm to start with."""
    plate = _make_box_part("SlidePlate", size=100.0, depth=10.0)
    guide = _make_box_part("SlideGuide", size=10.0, depth=10.0)
    block = _make_box_part("SlideBlock", size=10.0, depth=10.0)
    stop = _make_box_part("SlideStop", size=10.0, depth=10.0)
    root = _compose(_create_part("SlideAssembly"), [("plate", plate, (0, 0, 0)), ("guide", guide, (0, 60, 0)), ("block", block, (10, 50, 10)), ("stop", stop, (40, 50, 10))])
    _mate(root, "coincident", "block", _face(block, (0, 0, -1)), "plate", _face(plate, (0, 0, 1)))
    _mate(root, "coincident", "block", _face(block, (0, 1, 0)), "guide", _face(guide, (0, -1, 0)))
    for oid in ("plate", "guide", "stop"):
        fix(root, oid)
    return root, block, stop


def _limit(root, block, stop, **extra):
    return _post_mate(root, "limit_distance", _ref("block", _face(block, (1, 0, 0))), _ref("stop", _face(stop, (-1, 0, 0))), **extra)


def _block_x(root):
    return _occs(root)["block"]["translation"][0]


def _slide(root, to_x, reference=None):
    wish = dict(_occs(root)["block"])
    wish["translation"] = [to_x, wish["translation"][1], wish["translation"][2]]
    body = {"transform": wish}
    if reference:
        body["reference"] = [{"occurrence_id": "block", "transform": reference}]
    out = _motion(root, "block", body)
    assert out["converged"], out
    return out


def _x_of(out):
    return next(m["transform"] for m in out["members"] if m["occurrence_id"] == "block")["translation"][0]


# ---- the mate: create / patch / 422 / files ---------------------------------------------------------------------------


def test_create_patch_and_delete_a_distance_limit_and_nothing_moves():
    root, block, stop = slider_scene()
    stored = _occs(root)
    made = _limit(root, block, stop, limit_min=0.0, limit_max=30.0)
    assert made.status_code == 201, made.text
    mate = made.json()
    assert mate["type"] == "limit_distance" and mate["limit_min"] == 0.0 and mate["limit_max"] == 30.0 and mate["value"] is None
    assert _occs(root) == stored
    assert abs(mate["limit_value"] - 20.0) < 1e-6  # the gap now, to type a range against
    listed = [m for m in client.get(f"/document/parts/{root}/mates").json() if m["id"] == mate["id"]][0]
    assert abs(listed["limit_value"] - 20.0) < 1e-6
    patched = client.patch(f"/document/parts/{root}/mates/{mate['id']}", json={"limit_max": None, "limit_min": 2.5})
    assert patched.status_code == 200 and patched.json()["limit_min"] == 2.5 and patched.json()["limit_max"] is None
    assert client.patch(f"/document/parts/{root}/mates/{mate['id']}", json={"suppressed": True}).json()["suppressed"] is True
    assert client.delete(f"/document/parts/{root}/mates/{mate['id']}").status_code == 204


def test_limit_422s():
    root, block, stop = slider_scene()
    r = _limit(root, block, stop, limit_min=5, limit_max=1)
    assert r.json()["detail"]["type"] == "limit_range_inverted"
    r = _limit(root, block, stop)
    assert r.json()["detail"]["type"] == "limit_range_required"
    # a distance limit needs a plane on one side: an edge-less point cannot form it - the same occurrence twice is refused too
    r = _post_mate(root, "limit_distance", _ref("block", _face(block, (1, 0, 0))), _ref("block", _face(block, (-1, 0, 0))), limit_min=0)
    assert r.status_code == 422
    r = _post_mate(root, "limit_angle", _ref("block", _face(block, (1, 0, 0))), _ref("stop", _face(stop, (-1, 0, 0))), limit_min=-10, limit_max=10)
    assert r.status_code == 422 and r.json()["detail"]["type"] == "limit_angle_needs_hinge"
    mate = _limit(root, block, stop, limit_min=0.0, limit_max=30.0).json()
    bad = client.patch(f"/document/parts/{root}/mates/{mate['id']}", json={"limit_min": 40.0})
    assert bad.status_code == 422 and bad.json()["detail"]["type"] == "limit_range_inverted"
    assert [m for m in client.get(f"/document/parts/{root}/mates").json() if m["id"] == mate["id"]][0]["limit_min"] == 0.0


def test_native_round_trip_and_a_file_without_limits_is_unchanged():
    root, block, stop = slider_scene()
    plain = client.get("/document/export/native", params={"part_id": root}).json()
    assert all("limit_min" not in m for p in plain["document"]["parts"] for m in p["mates"])
    mate = _limit(root, block, stop, limit_min=1.0, limit_max=18.0).json()
    exported = client.get("/document/export/native", params={"part_id": root}).json()
    stored = [m for p in exported["document"]["parts"] for m in p["mates"] if m["type"] == "limit_distance"]
    assert len(stored) == 1 and stored[0]["limit_min"] == 1.0 and stored[0]["limit_max"] == 18.0
    assert client.post("/document/import/native", json=exported).status_code == 200
    again = [m for m in client.get(f"/document/parts/{root}/mates").json() if m["type"] == "limit_distance"]
    assert len(again) == 1 and again[0]["id"] == mate["id"] and again[0]["limit_max"] == 18.0


def test_preview_moves_nothing():
    root, block, stop = slider_scene()
    body = {"type": "limit_distance", "references": [_ref("block", _face(block, (1, 0, 0))), _ref("stop", _face(stop, (-1, 0, 0)))], "limit_min": 0.0, "limit_max": 5.0}
    r = client.post(f"/document/parts/{root}/occurrences/block/preview-mate-solve", json=body)
    assert r.status_code == 200 and r.json()["converged"] is True
    assert r.json()["transform"] == _occs(root)["block"]
    assert abs(r.json()["limit_value"] - 20.0) < 1e-6


# ---- the solve: the active set ----------------------------------------------------------------------------------------


def test_a_drag_inside_the_range_is_untouched_and_past_it_stops_at_the_bound():
    root, block, stop = slider_scene()
    assert _limit(root, block, stop, limit_min=5.0, limit_max=30.0).status_code == 201  # gap 20 now: block may travel -10 .. +15
    x0 = _block_x(root)
    assert abs(_x_of(_slide(root, x0 + 8.0)) - (x0 + 8.0)) < 1e-4  # inside the range
    assert abs(_x_of(_slide(root, x0 + 40.0)) - (x0 + 15.0)) < 1e-4  # gap 5 = the min: the stop
    assert abs(_x_of(_slide(root, x0 - 40.0)) - (x0 - 10.0)) < 1e-4  # gap 30 = the max
    assert abs(_x_of(_slide(root, x0 + 14.9)) - (x0 + 14.9)) < 1e-4  # and just inside again: released, nothing sticks


def test_slide_along_the_bound_keeps_the_other_motion():
    root, block, stop = slider_scene()
    assert _limit(root, block, stop, limit_min=5.0).status_code == 201
    x0 = _block_x(root)
    out = _slide(root, x0 + 40.0)
    pose = next(m["transform"] for m in out["members"] if m["occurrence_id"] == "block")
    assert abs(pose["translation"][0] - (x0 + 15.0)) < 1e-4
    assert abs(pose["translation"][1] - 50.0) < 1e-6 and abs(pose["translation"][2] - 10.0) < 1e-6  # the guide and the plate still hold


def test_a_part_that_starts_outside_is_brought_to_the_nearest_bound():
    root, block, stop = slider_scene()
    assert _limit(root, block, stop, limit_min=25.0).status_code == 201  # the gap is 20: 5 mm short of the min
    x0 = _block_x(root)
    assert abs(_x_of(_slide(root, x0)) - (x0 - 5.0)) < 1e-4


def test_a_suppressed_limit_is_ignored():
    root, block, stop = slider_scene()
    mate = _limit(root, block, stop, limit_min=5.0).json()
    client.patch(f"/document/parts/{root}/mates/{mate['id']}", json={"suppressed": True})
    x0 = _block_x(root)
    assert abs(_x_of(_slide(root, x0 + 40.0)) - (x0 + 40.0)) < 1e-4


def test_a_one_sided_limit_leaves_the_other_end_free():
    root, block, stop = slider_scene()
    assert _limit(root, block, stop, limit_max=25.0).status_code == 201
    x0 = _block_x(root)
    assert abs(_x_of(_slide(root, x0 + 40.0)) - (x0 + 40.0)) < 1e-4
    assert abs(_x_of(_slide(root, x0 - 40.0)) - (x0 - 5.0)) < 1e-4


def test_two_limits_that_cannot_both_hold_are_not_converged():
    root, block, stop = slider_scene()
    first = _limit(root, block, stop, limit_min=0.0, limit_max=30.0)
    assert first.status_code == 201
    # a second range on the same value that excludes the first: min 40 > max 30 of the other
    assert _limit(root, block, stop, limit_min=40.0, limit_max=50.0).status_code == 201
    body = _motion(root, "block", {"transform": dict(_occs(root)["block"])})
    assert body["converged"] is False


# ---- the exported model ----------------------------------------------------------------------------------------------


def _model(root, grabbed="block"):
    document = get_document()
    return build_group_model(document, document.parts[root], grabbed)


def test_the_constraint_model_is_version_6_only_with_a_limit():
    root, block, stop = slider_scene()
    assert export_constraint_model(_model(root))["version"] == MODEL_VERSION
    assert _limit(root, block, stop, limit_min=5.0, limit_max=30.0).status_code == 201
    spec = export_constraint_model(_model(root))
    assert spec["version"] == LIMIT_MODEL_VERSION == 6
    mate = [m for m in spec["mates"] if m["type"] == "limit_distance"][0]
    assert mate["min"] == 5.0 and mate["max"] == 30.0 and mate["id"]
    body = _motion(root, "block", {"transform": None})
    assert body["constraint_model"]["version"] == 6


def test_limit_rows_exist_only_when_held_and_the_gradient_is_exact():
    root, block, stop = slider_scene()
    assert _limit(root, block, stop, limit_min=5.0, limit_max=30.0).status_code == 201
    model = _model(root)
    spec = export_constraint_model(model)
    poses = [rigid_to_pose(model.base_transforms[o]) for o in model.member_ids]
    free = ConstraintModel(spec)
    base_rows = len(free.residual(poses, with_jacobian=False))
    mate = [m for m in spec["mates"] if m["type"] == "limit_distance"][0]
    held = ConstraintModel(spec, active={mate["id"]: 5.0})
    r, jac = held.residual(poses)
    assert len(r) == base_rows + 1 and abs(r[-1] - (20.0 - 5.0)) < 1e-6  # gap 20 - bound 5
    value, grad = held._limit(mate, poses)
    h = 1e-6
    for c in range(jac.shape[1]):
        e = np.zeros(jac.shape[1])
        e[c] = h
        plus = [apply_pose(poses[i], e[6 * i : 6 * i + 6]) for i in range(len(poses))]
        minus = [apply_pose(poses[i], -e[6 * i : 6 * i + 6]) for i in range(len(poses))]
        fd = (held._limit(mate, plus)[0] - held._limit(mate, minus)[0]) / (2 * h)
        assert abs(fd - grad[c]) < 1e-5, c


def test_the_client_style_active_set_stops_at_the_bound_in_one_call():
    root, block, stop = slider_scene()
    assert _limit(root, block, stop, limit_min=5.0, limit_max=30.0).status_code == 201
    model = _model(root)
    spec = export_constraint_model(model)
    ids = list(model.member_ids)
    start = [rigid_to_pose(model.base_transforms[o]) for o in ids]
    gi = ids.index("block")
    w = weights(len(ids), 20.0, grabbed=gi)
    wishes = [(p[0], p[1] + (np.array([40.0, 0.0, 0.0]) if i == gi else 0.0)) for i, p in enumerate(start)]
    out, held = sqp_nearest_limits(spec, None, start, wishes, w)
    assert list(held.values()) == [5.0]
    assert abs(out[gi][1][0] - (start[gi][1][0] + 15.0)) < 1e-4
    wishes_back = [(p[0], p[1] + (np.array([8.0, 0.0, 0.0]) if i == gi else 0.0)) for i, p in enumerate(start)]
    inside, held = sqp_nearest_limits(spec, None, start, wishes_back, w)
    assert held == {} and abs(inside[gi][1][0] - (start[gi][1][0] + 8.0)) < 1e-4  # the limit is released the moment the wish pulls back


def test_limit_beside_a_coupler_keeps_version_6():
    root, block, stop = slider_scene()
    assert _limit(root, block, stop, limit_min=5.0).status_code == 201
    assert export_constraint_model(_model(root))["version"] > COUPLER_MODEL_VERSION


# ---- an angle limit about a hinge ------------------------------------------------------------------------------------


def hinge_leaves():
    """Two leaf plates joined directly by a concentric (the hinge axis, vertical through (20, 20)) and a coincident (B on A): leaf A fixed,
    leaf B swings about the hinge."""
    a = _plate_with_hole("LimLeafA", size=40.0, depth=5.0, at=(20.0, 20.0), radius=4.5)
    b = _plate_with_hole("LimLeafB", size=40.0, depth=5.0, at=(20.0, 20.0), radius=4.5)
    root = _compose(_create_part("LimHinge"), [("leaf-a", a, (0, 0, 0)), ("leaf-b", b, (0, 0, 5))])
    _mate(root, "concentric", "leaf-b", _cyl(b), "leaf-a", _cyl(a))
    _mate(root, "coincident", "leaf-b", _face(b, (0, 0, -1)), "leaf-a", _face(a, (0, 0, 1)))
    fix(root, "leaf-a")
    return root, a, b


def _angle_limit(root, a, b, **extra):
    return _post_mate(root, "limit_angle", _ref("leaf-b", _face(b, (1, 0, 0))), _ref("leaf-a", _face(a, (1, 0, 0))), **extra)


def _swing(root, degrees):
    stored = _occs(root)["leaf-b"]
    wish = _wish(stored, degrees)  # a true swing about the hinge: the hinge point (20, 20) stays where it is
    c, s = math.cos(math.radians(degrees)), math.sin(math.radians(degrees))
    wish["translation"] = [20.0 - (c * 20.0 - s * 20.0), 20.0 - (s * 20.0 + c * 20.0), stored["translation"][2]]
    out = _motion(root, "leaf-b", {"transform": wish})
    assert out["converged"], out
    return _spin_z(next(m["transform"] for m in out["members"] if m["occurrence_id"] == "leaf-b"))


def test_an_angle_limit_stops_the_swing_at_each_bound():
    root, a, b = hinge_leaves()
    made = _angle_limit(root, a, b, limit_min=-20.0, limit_max=50.0)
    assert made.status_code == 201, made.text
    inside = _swing(root, 30.0)
    assert abs(abs(inside) - 30.0) < 0.05
    sign = math.copysign(1.0, inside)
    up = _swing(root, 90.0)
    down = _swing(root, -90.0)
    assert {round(abs(up), 1), round(abs(down), 1)} == {50.0, 20.0}, (up, down)
    assert up * down < 0 and sign in (-1.0, 1.0)  # the two stops are on opposite sides of the flat pose


def test_angle_limit_range_must_stay_within_180():
    root, a, b = hinge_leaves()
    r = _angle_limit(root, a, b, limit_min=-190.0, limit_max=10.0)
    assert r.status_code == 422 and r.json()["detail"]["type"] == "limit_angle_out_of_range"


def test_a_held_angle_limit_row_matches_between_the_group_model_and_the_exported_model():
    import dataclasses

    root, a, b = hinge_leaves()
    assert _angle_limit(root, a, b, limit_min=-20.0, limit_max=50.0).status_code == 201
    model = _model(root, "leaf-b")
    mate_id = [m.id for m, _a, _b in model.sides if m.type.value == "limit_angle"][0]
    held = dataclasses.replace(model, active_limits={mate_id: 50.0})
    spec = export_constraint_model(held)
    for degrees in (-40.0, 0.0, 33.0, 80.0):
        c, s = math.cos(math.radians(degrees)), math.sin(math.radians(degrees))
        from app.document.models import RigidTransform

        pose = RigidTransform(translation=(20 - (c * 20 - s * 20), 20 - (s * 20 + c * 20), 5.0), rotation_axis=(0, 0, 1), rotation_angle_degrees=degrees)
        theirs = ConstraintModel(spec, active={mate_id: 50.0}).residual([rigid_to_pose(pose)], with_jacobian=False)
        mine = held.residual(None, {"leaf-b": pose})
        assert np.allclose(theirs, mine, atol=1e-9), (degrees, theirs, mine)
    poses = [rigid_to_pose(model.base_transforms["leaf-b"])]
    start = poses
    wish = [(poses[0][0], poses[0][1])]
    ang = math.radians(80.0)
    from app.document.constraint_model import exp_rot

    wish = [(exp_rot(np.array([0, 0, ang])) @ poses[0][0], np.array([20 - (math.cos(ang) * 20 - math.sin(ang) * 20), 20 - (math.sin(ang) * 20 + math.cos(ang) * 20), 5.0]))]
    out, held_ids = sqp_nearest_limits(spec, None, start, wish, weights(1, 20.0, grabbed=0), iters=40)  # many iterations: a frame moves only a trust-region step
    assert list(held_ids.values()) in ([50.0], [-20.0]) and len(held_ids) == 1
    value, _g = ConstraintModel(spec)._limit([m for m in spec["mates"] if m["type"] == "limit_angle"][0], out)
    assert min(abs(value - 50.0), abs(value + 20.0)) < 1e-4
