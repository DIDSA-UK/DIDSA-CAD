"""M6: coupler mates in the exported constraint model (version 5, `app/document/constraint_model.py`): the export shape, version 5 only with a
coupler, the model reproducing `GroupModel.residual`, its analytic gradients against central differences (also near +-150 degrees), and the
nearest-point retraction landing on the relation."""

import json
import math

import numpy as np

from app.document.assembly_group import apply_delta, build_group_model, solve_group
from app.document.constraint_model import (
    COUPLER_MODEL_VERSION,
    MODEL_VERSION,
    ConstraintModel,
    apply_delta as apply_pose,
    export_constraint_model,
    residual_inf,
    rigid_to_pose,
    sqp_nearest,
    weights,
)
from app.document.store import get_document
from tests.test_coupler_mates import _gear_mate, gear_scene, rack_scene, screw_scene


def _scene(kind):
    if kind == "gear":
        root, _plate, shaft = gear_scene()
        _gear_mate(root, shaft, value=0.5)
        return root, "shaft-a"
    if kind == "rack":
        root, _made = rack_scene()
        return root, "pinion"
    root, _made = screw_scene()
    return root, "nut"


def _model(kind):
    root, grabbed = _scene(kind)
    document = get_document()
    return build_group_model(document, document.parts[root], grabbed)


def _poses(model, x):
    return [rigid_to_pose(apply_delta(model.base_transforms[o], x[6 * i : 6 * i + 6])) for i, o in enumerate(model.member_ids)]


def _fd(cm, poses, h=1e-6):
    n = 6 * len(poses)
    out = None
    for c in range(n):
        e = np.zeros(n)
        e[c] = h
        plus = [apply_pose(poses[i], e[6 * i : 6 * i + 6]) for i in range(len(poses))]
        minus = [apply_pose(poses[i], -e[6 * i : 6 * i + 6]) for i in range(len(poses))]
        col = (cm.residual(plus, with_jacobian=False) - cm.residual(minus, with_jacobian=False)) / (2 * h)
        out = np.zeros((len(col), n)) if out is None else out
        out[:, c] = col
    return out


def test_export_shape_and_version():
    for kind in ("gear", "rack", "screw"):
        model = _model(kind)
        spec = export_constraint_model(model)
        assert spec["version"] == COUPLER_MODEL_VERSION == 5
        json.dumps(spec)
        couplers = [m for m in spec["mates"] if m["type"] in ("gear", "rack_pinion", "screw")]
        assert len(couplers) == 1
        mate = couplers[0]
        assert mate["k"] in (1, -1) and mate["value"] > 0
        for side in (mate["a"], mate["b"]):
            assert "direction" in side and "axis_origin" in side
            if side["member"] >= 0:
                assert set(side["anchor"]) == {"r", "t"} and np.allclose(np.array(side["anchor"]["r"]) @ np.array(side["anchor"]["r"]).T, np.eye(3))
            else:
                assert "frozen" in side or side["member"] < 0


def test_version_stays_3_without_a_coupler():
    root, _plate, _shaft = gear_scene()  # concentric + coincident only
    document = get_document()
    model = build_group_model(document, document.parts[root], "shaft-a")
    assert export_constraint_model(model)["version"] == MODEL_VERSION


def test_the_model_reproduces_the_backend_residual_and_its_gradients_match_differences():
    rng = np.random.default_rng(11)
    for kind in ("gear", "rack", "screw"):
        model = _model(kind)
        cm = ConstraintModel(export_constraint_model(model))
        for scale in (0.0, 0.3, 1.0):
            x = rng.normal(size=model.n_vars) * scale
            x[::6] *= 5.0
            poses = _poses(model, x)
            r, jac = cm.residual(poses)
            assert np.max(np.abs(r - model.residual(x))) < 1e-9, (kind, scale)
            fd = _fd(cm, poses)
            assert np.max(np.abs(jac - fd)) < 1e-6 * (1.0 + np.max(np.abs(fd))), (kind, scale)
        # near +-150 degrees about the shaft axis
        for degrees in (150.0, -150.0, 170.0):
            x = np.zeros(model.n_vars)
            x[5] = math.radians(degrees)  # the grabbed member's turn about z
            if model.n_vars > 11:
                x[11] = math.radians(degrees / 2.0)
            poses = _poses(model, x)
            r, jac = cm.residual(poses)
            assert np.max(np.abs(r - model.residual(x))) < 1e-9, (kind, degrees)
            fd = _fd(cm, poses)
            assert np.max(np.abs(jac - fd)) < 1e-6 * (1.0 + np.max(np.abs(fd))), (kind, degrees)


def test_the_groups_analytic_jacobian_is_used_and_matches_differences():
    model = _model("gear")
    x = np.zeros(model.n_vars)
    x[5] = 0.4
    poses = {o: apply_delta(model.base_transforms[o], x[6 * i : 6 * i + 6]) for i, o in enumerate(model.member_ids)}
    assert export_constraint_model(model) is not None
    analytic = model.jacobian(poses)
    fd = model._jacobian_differences(poses, 1e-6)
    assert np.max(np.abs(analytic - fd)) < 1e-4 * (1.0 + np.max(np.abs(fd)))


def test_a_stale_cached_spec_does_not_carry_old_anchors():
    """`dataclasses.replace(model, base_transforms=...)` keeps the cached spec; the Jacobian must read the NEW base poses."""
    from dataclasses import replace

    model = _model("gear")
    model.jacobian()  # caches the spec at the original base
    moved = {o: apply_delta(model.base_transforms[o], np.array([0, 0, 0, 0, 0, 0.9 if i == 0 else -0.45])) for i, o in enumerate(model.member_ids)}
    rebased = replace(model, base_transforms=moved)
    jac = rebased.jacobian(moved)  # at the new base itself every gear row's gradient is (d, -k r d)
    fd = rebased._jacobian_differences(moved, 1e-6)
    assert np.max(np.abs(jac - fd)) < 1e-4 * (1.0 + np.max(np.abs(fd)))


def test_sqp_nearest_lands_on_the_gear_relation():
    model = _model("gear")
    cm = ConstraintModel(export_constraint_model(model))
    start = [rigid_to_pose(model.base_transforms[o]) for o in model.member_ids]
    wishes = [apply_pose(start[0], np.array([0, 0, 0, 0, 0, math.radians(80.0)])), start[1]]
    w = weights(len(start), 10.0, grabbed=0)
    result = sqp_nearest(cm, start, wishes, w, iters=12, polish=3)
    assert residual_inf(cm, result) < 1e-6
    from app.document.coupler import turn_about

    axis = np.array([0.0, 0.0, 1.0])
    turn_a = turn_about(result[0][0], start[0][0], axis)
    turn_b = turn_about(result[1][0], start[1][0], axis)
    assert abs(turn_b - (-1.0 if not model.sides[-1][0].secondary_flip else 1.0) * 0.5 * turn_a) < 1e-6
    assert abs(turn_a - math.radians(80.0)) < 0.05  # the grabbed gear gets (nearly) all of the wish


def test_solve_group_answers_with_the_version_5_model():
    root, _plate, shaft = gear_scene()
    _gear_mate(root, shaft, value=0.5)
    document = get_document()
    part = document.parts[root]
    grabbed = next(o for o in part.occurrences if o.id == "shaft-a")
    result = solve_group(document, part, "shaft-a", apply_delta(grabbed.transform, np.array([0, 0, 0, 0, 0, math.radians(90.0)])), lever_arm=10.0)
    assert result.converged and result.constraint_model["version"] == 5
    # (the nearest-point stage keeps the plain answer when it is not strictly nearer, as here: the wish is on the manifold)
    pose_b = result.poses["shaft-b"]
    assert abs(abs(pose_b.rotation_angle_degrees) - 45.0) < 1e-3
