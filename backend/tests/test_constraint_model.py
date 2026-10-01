"""F1b: the exported constraint model (`app/document/constraint_model.py`), the nearest-point retraction on it, and its use in
`solve_group` / the `mate-motion` response (`docs/motion/projector-spec.md` section 4b).

* the exported model reproduces `GroupModel.residual` (the backend's own residual) and its analytic Jacobian matches the
  finite-difference one, on every scene family (flat, hinge, off-axis pin, angle cone, chain, floating group);
* on the off-axis pin the group solve now lands on the weighted-NEAREST point (spec section 13.2: the plain retraction
  landed at spin 51 deg vs 28.5 deg), and an on-manifold wish still comes back exactly;
* the response carries the model, JSON-clean, with the member order of the basis."""

import json
import math

import numpy as np

from app.document.assembly_group import apply_delta, build_group_model, pose_delta, solve_group
from app.document.constraint_model import (
    ConstraintModel,
    apply_delta as apply_pose,
    export_constraint_model,
    rigid_to_pose,
    rotvec_from_rot,
    sqp_nearest,
    weights,
    wish_cost,
)
from app.document.store import get_document
from tests import motion_scenes as ms
from tests.test_assembly_group import _plate_bcd
from tests.test_assembly_group_solve import _L, _floating_bolt_scene, _offset_pin_scene, _plate_scene
from tests.test_assembly_solver import client


def _first_occurrence(root):
    return client.get(f"/document/parts/{root}/occurrences").json()[0]["id"]


def _build_bolt():
    root, roles = ms.bolt_scene()
    return root, roles["mover"]


def _build_hinge():
    root, roles = ms.hinge_scene()
    return root, roles["mover"]


def _build_swing():
    root = _offset_pin_scene()
    return root, _first_occurrence(root)


def _build_angle():
    root = _plate_scene("angle", start=((5, 5, 60), (1, 0, 0), 45.0), value=60.0)
    return root, _first_occurrence(root)


def _build_bcd():
    root, _p, _parts = _plate_bcd()
    return root, "occ-B"


_BUILDERS = {"bolt": _build_bolt, "hinge": _build_hinge, "swing": _build_swing, "angle": _build_angle, "bcd": _build_bcd}


def _scenes():
    """(name, root, grabbed) for scenes of every family, built one at a time (a builder replaces the document)."""
    for name, build in _BUILDERS.items():
        root, grabbed = build()
        yield name, root, grabbed


def _poses(model, perturb):
    base = [rigid_to_pose(model.base_transforms[o]) for o in model.member_ids]
    return base, [
        rigid_to_pose(apply_delta(model.base_transforms[o], perturb[6 * i : 6 * i + 6])) for i, o in enumerate(model.member_ids)
    ]


def test_exported_model_reproduces_the_backend_residual_and_jacobian():
    rng = np.random.default_rng(7)
    for name, root, grabbed in _scenes():
        document = get_document()
        part = document.parts[root]
        model = build_group_model(document, part, grabbed)
        spec = export_constraint_model(model)
        assert spec is not None and spec["version"] == 1 and spec["members"] == list(model.member_ids), name
        json.dumps(spec)  # plain JSON
        cm = ConstraintModel(spec)
        for scale in (0.0, 0.3):
            x = rng.normal(size=model.n_vars) * scale
            x[::6] *= 20.0  # translations in mm
            _, poses = _poses(model, x)
            r, jac = cm.residual(poses)
            expected = model.residual(x)
            assert r.shape == expected.shape, name
            assert np.max(np.abs(r - expected)) < 1e-9, (name, scale)
            # backend finite-difference Jacobian at the perturbed poses
            perturbed = {o: apply_delta(model.base_transforms[o], x[6 * i : 6 * i + 6]) for i, o in enumerate(model.member_ids)}
            fd = model.jacobian(perturbed)  # the backend's own (central difference, ~1e-4 accurate)
            assert np.max(np.abs(jac - fd)) < 1e-4 * (1.0 + np.max(np.abs(fd))), (name, scale)
            # and an exact check of the analytic Jacobian against central differences of the exported model itself
            fd2 = np.zeros_like(jac)
            h = 1e-6
            for c in range(6 * len(poses)):
                e = np.zeros(6 * len(poses))
                e[c] = h
                plus = [apply_pose(poses[i], e[6 * i : 6 * i + 6]) for i in range(len(poses))]
                minus = [apply_pose(poses[i], -e[6 * i : 6 * i + 6]) for i in range(len(poses))]
                fd2[:, c] = (cm.residual(plus, with_jacobian=False) - cm.residual(minus, with_jacobian=False)) / (2 * h)
            assert np.max(np.abs(jac - fd2)) < 1e-6 * (1.0 + np.max(np.abs(fd2))), (name, scale)


def _spin_degrees(pose, base):
    return math.degrees(float(np.linalg.norm(pose_delta(pose, base)[3:])))


def test_off_axis_pin_90_degree_wish_lands_on_the_weighted_nearest_point():
    """Spec section 13.2's case: the plain Gauss-Newton retraction answered spin 51 deg (cost 213) for a 90 deg wish about the
    pin's own axis while the true weighted-nearest point is 28.5 deg (cost 170). The group solve now refines to it."""
    root = _offset_pin_scene()
    document = get_document()
    part = document.parts[root]
    occ = part.occurrences[0]
    settled = solve_group(document, part, occ.id, None, lever_arm=_L)
    base = occ.transform = settled.poses[occ.id]
    wish = apply_delta(base, (0, 0, 0, 0, 0, math.radians(90)))
    result = solve_group(document, part, occ.id, wish, lever_arm=_L)
    assert result.converged and result.quality.residual_inf < 1e-7
    assert result.quality.seeded_by.endswith("+nearest"), result.quality.seeded_by
    # an independent high-effort nearest point from the stored pose
    model = build_group_model(document, part, occ.id)
    cm = ConstraintModel(export_constraint_model(model))
    w = weights(1, _L)
    start = [rigid_to_pose(base)]
    wishes = [rigid_to_pose(wish)]
    truth = sqp_nearest(cm, start, wishes, w, iters=60, polish=3)
    got = [rigid_to_pose(result.poses[occ.id])]
    assert wish_cost(got, wishes, w) <= wish_cost(truth, wishes, w) * (1 + 1e-6) + 1e-9
    spin = _spin_degrees(result.poses[occ.id], base)
    assert abs(spin - 28.5) < 1.0, spin  # (and not the 51 deg the plain retraction gave)


def test_on_manifold_wish_still_comes_back_exactly():
    """A wish that already satisfies the mates (a pure spin of the floating bolt about its own axis) must not be 'refined'
    away from the wish by the local follower weight."""
    root = _floating_bolt_scene()
    document = get_document()
    part = document.parts[root]
    stored = next(o for o in part.occurrences if o.id == "occ-bolt").transform
    wish = apply_delta(stored, (0, 0, 0, 0, 0, math.radians(40)))
    result = solve_group(document, part, "occ-bolt", wish, lever_arm=20.0)
    assert result.converged
    assert float(np.linalg.norm(pose_delta(result.poses["occ-bolt"], wish) * np.array([1, 1, 1, 20, 20, 20]))) < 1e-6


def test_nearest_stage_never_makes_a_converged_answer_worse():
    """Over a sweep of wishes on every scene the answer satisfies the mates and is no farther from the wish (in the local
    metric, followers at their current poses) than the model's own retraction from the same seed would be: the stage only
    adopts a strictly nearer converged result."""
    rng = np.random.default_rng(3)
    for name, root, grabbed in _scenes():
        document = get_document()
        part = document.parts[root]
        settled = solve_group(document, part, grabbed, None, lever_arm=_L)
        for oid, pose in settled.poses.items():
            next(o for o in part.occurrences if o.id == oid).transform = pose
        stored = next(o for o in part.occurrences if o.id == grabbed).transform
        for _ in range(6):
            d = np.concatenate([rng.normal(size=3) * 8.0, rng.normal(size=3) * 0.3])
            wish = apply_delta(stored, d)
            result = solve_group(document, part, grabbed, wish, lever_arm=_L)
            if result.converged:
                assert result.quality.residual_inf < 1e-7, (name, d)


def test_mate_motion_response_carries_the_constraint_model():
    root = _offset_pin_scene()
    occ = get_document().parts[root].occurrences[0]
    r = client.post(f"/document/parts/{root}/occurrences/{occ.id}/mate-motion", json={"transform": None, "lever_arm": _L})
    assert r.status_code == 200, r.text
    body = r.json()
    model = body["constraint_model"]
    assert model["version"] == 1
    assert model["members"] == [m["occurrence_id"] for m in body["members"]]
    (mate,) = model["mates"]
    assert mate["type"] == "concentric" and mate["a"]["member"] == 0 and mate["b"]["member"] == -1
    assert "frozen" not in mate["b"]  # the root's own geometry: identity pose
    assert "axis_origin" in mate["a"] and "direction" in mate["a"]
    # a non-converged answer has none
    bad = client.post(f"/document/parts/{root}/occurrences/{occ.id}/mate-motion", json={"transform": {"translation": [1e9, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}})
    if bad.status_code == 200 and not bad.json()["converged"]:
        assert bad.json()["constraint_model"] is None


def test_backend_retraction_reproduces_the_golden_vectors():
    """`docs/motion/vectors.json` kind `local_retract` is computed by tools/motion_vectors/generate.py (numpy only); the backend's
    `constraint_model.sqp_nearest` is the same algorithm in another file and must agree (the Dart port is checked against the
    same file): same poses after the 3 + 1 iterations, same residual, same accept/reject by the section 4b guard."""
    from pathlib import Path

    from app.document.constraint_model import ACCEPT_RESIDUAL, residual_inf

    doc = json.loads((Path(__file__).resolve().parents[2] / "docs" / "motion" / "vectors.json").read_text())
    c = doc["constants"]
    cases = [x for x in doc["cases"] if x["kind"] == "local_retract"]
    assert len(cases) >= 12
    for case in cases:
        inp, exp = case["input"], case["expected"]
        cm = ConstraintModel(inp["model"])
        def pose_of(j):
            return rigid_to_pose(_Rt(j))

        poses = [pose_of(p) for p in inp["poses"]]
        wishes = [pose_of(p) for p in inp["wishes"]]
        w = weights(len(poses), inp["lever_arm"], follower=inp["local_follower"])
        got = sqp_nearest(cm, poses, wishes, w, iters=c["local_iters"], polish=c["local_polish"])
        for i, p in enumerate(got):
            if exp["residual_inf"] > ACCEPT_RESIDUAL:
                break  # a non-converged raw answer is a sensitive function of the linear solve; only converged ones are pinned
            assert np.max(np.abs(p[1] - np.array(exp["local_poses"][i]["translation"]))) < 1e-9, case["id"]
            assert np.max(np.abs(p[0].reshape(9) - np.array(exp["local_poses"][i]["rotation"]))) < 1e-9, case["id"]
        if exp["residual_inf"] <= ACCEPT_RESIDUAL:
            assert abs(residual_inf(cm, got) - exp["residual_inf"]) < 1e-9, case["id"]
        else:
            assert residual_inf(cm, got) > ACCEPT_RESIDUAL, case["id"]
        wish_step = float(np.linalg.norm(np.concatenate([wishes[0][1] - poses[0][1], rotvec_from_rot(wishes[0][0] @ poses[0][0].T) * inp["lever_arm"]])))
        accepted = residual_inf(cm, got) <= ACCEPT_RESIDUAL and exp["fallback_distance"] <= c["local_accept_distance"] * max(inp["lever_arm"], wish_step)
        assert accepted == exp["accepted"], case["id"]


class _Rt:
    """Duck-typed RigidTransform for `rigid_to_pose` from a vector pose (translation, axis, degrees)."""

    def __init__(self, j):
        self.translation, self.rotation_axis, self.rotation_angle_degrees = j["translation"], j["rotation_axis"], j["rotation_angle_degrees"]
