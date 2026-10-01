"""F1a prototype: a CLIENT-SIDE constraint model + exact nearest-point retraction (no production code).

The backend ships, once per anchor, what a client needs to evaluate the mates itself - per mate: type, value,
allow_rotation and, for each side, the member index (or a frozen world pose) plus the resolved LOCAL geometry (point, plane,
axis origin, direction, perp). This file (a) exports that "constraint model" from the real backend's `GroupModel`,
(b) re-implements the mate residuals with analytic Jacobians in plain numpy (forward-mode product rule, only 6 active
columns per member and mate side), checked against the backend residual and a finite-difference Jacobian, (c) implements
the retraction candidates, and (d) evaluates them against the current client projector (`tools/motion_vectors/generate.py`)
and the real backend on the smoothness-study scenes.

Run (needs the backend env, from backend/):  python ../docs/constrained-drag-investigation/prototypes/g_local_retraction.py [section...]
sections: check | scenes | random | warm | cost | reconcile   (default: check scenes random cost). Results are printed as tables; numbers quoted in
docs/constrained-drag-f1a-design.md come from this file."""
import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.getcwd())
sys.path.insert(0, os.path.join(ROOT, "tools", "motion_vectors"))
import generate as gen  # noqa: E402  (the S6 projector in numpy: screw_log / screw_exp / project)

FOLLOWER_WEIGHT = 1e-4
LOCAL_FOLLOWER = 1e-2  # follower weight of the LOCAL retraction (the projection metric keeps the contract's 1e-4): 1e-4 squares to a 1e8 range in A A^T and drowns in rounding, 1e-2 is stable and still moves the grabbed part < 0.01% off the wish
TRUST = 6.0  # weighted mm of wished displacement per iteration (trust region of the nearest-point step)


# ---- poses ------------------------------------------------------------------------------------------------------


def skew(w):
    return np.array([[0, -w[2], w[1]], [w[2], 0, -w[0]], [-w[1], w[0], 0.0]])


def exp_rot(w):
    th = float(np.linalg.norm(w))
    k = skew(w)
    if th < 1e-9:
        return np.eye(3) + k + 0.5 * k @ k
    return np.eye(3) + math.sin(th) / th * k + (1 - math.cos(th)) / th**2 * k @ k


def apply_delta(pose, d):
    """Backend chart: t += v, R = exp(w) R. pose = (R, t)."""
    R, t = pose
    return exp_rot(d[3:6]) @ R, t + d[:3]


def to_gen(pose):
    return gen.Pose(np.array(pose[1], float), np.array(pose[0], float))  # Pose(t, r)


def from_gen(p):
    return np.array(p.r, float), np.array(p.t, float)


def pose_dist(a, b, lever):
    """Weighted distance in the log chart (what the spec calls travel / weighted_dist)."""
    return gen.weighted_dist(to_gen(a), to_gen(b), lever)


def rt_pose(rt):
    """backend RigidTransform -> (R, t)."""
    axis = np.array(rt.rotation_axis, float)
    n = float(np.linalg.norm(axis))
    R = np.eye(3) if n < 1e-12 or abs(rt.rotation_angle_degrees) < 1e-15 else exp_rot(axis / n * math.radians(rt.rotation_angle_degrees))
    return R, np.array(rt.translation, float)


# ---- (a) export the constraint model from the backend's GroupModel ----------------------------------------------------


def export_model(model):
    """The wire format the client would receive with an anchor (dict of plain lists / numbers)."""
    ids = list(model.member_ids)
    mates = []
    for mate, a, b in model.sides:
        def side(s):
            g = s.geometry
            out = {"member": ids.index(s.occurrence_id) if s.occurrence_id in ids else -1}
            if s.frozen_transform is not None:
                R, t = rt_pose(s.frozen_transform)
                out["frozen"] = {"R": R.tolist(), "t": t.tolist()}
            for name in ("point", "axis_origin", "direction", "perp"):
                v = getattr(g, name)
                if v is not None:
                    out[name] = list(v)
            if g.plane is not None:
                out["plane"] = {"origin": list(g.plane.origin), "normal": list(g.plane.normal)}
            return out
        mates.append({"type": mate.type.value, "value": mate.value, "allow_rotation": bool(mate.allow_rotation), "a": side(a), "b": side(b)})
    return {"members": ids, "mates": mates}


# ---- (b) residuals + analytic Jacobian (forward-mode, 6 active columns per member) ---------------------------------------


class V:
    """A world-space 3-vector with its derivative (3 x n) w.r.t. the 6k twist coordinates."""
    __slots__ = ("v", "D")

    def __init__(self, v, D):
        self.v, self.D = v, D


class S:
    __slots__ = ("v", "D")

    def __init__(self, v, D):
        self.v, self.D = v, D


def vsub(a, b):
    return V(a.v - b.v, a.D - b.D)


def vdot(a, b):
    return S(float(a.v @ b.v), a.D.T @ b.v + b.D.T @ a.v)


def vcross(a, b):
    return V(np.cross(a.v, b.v), -skew(b.v) @ a.D + skew(a.v) @ b.D)


def vnorm(a):
    n = float(np.linalg.norm(a.v))
    u = a.v / n
    return V(u, (np.eye(3) - np.outer(u, u)) @ a.D / n)


class Model:
    def __init__(self, spec):
        self.spec = spec
        self.k = len(spec["members"])
        self.n = 6 * self.k
        self.mates = spec["mates"]

    def _world(self, side, poses, kind, name):
        """World value + derivative of one local geometry field of `side`."""
        if kind == "plane":
            local = np.array(side["plane"][name], float)
            kind = "point" if name == "origin" else "dir"
        else:
            local = np.array(side[name], float)
            kind = "point" if name in ("point", "axis_origin") else "dir"
        m = side["member"]
        D = np.zeros((3, self.n))
        if m < 0:
            fz = side.get("frozen")
            if fz is None:
                return V(local.copy(), D)
            R, t = np.array(fz["R"]), np.array(fz["t"])
        else:
            R, t = poses[m]
        w = R @ local
        if kind == "point":
            v = w + t
            if m >= 0:
                D[:, 6 * m : 6 * m + 3] = np.eye(3)
                D[:, 6 * m + 3 : 6 * m + 6] = -skew(w)
        else:
            v = w
            if m >= 0:
                D[:, 6 * m + 3 : 6 * m + 6] = -skew(w)
        return V(v, D)

    def _geo(self, side, poses):
        g = {}
        for name in ("point", "axis_origin", "direction", "perp"):
            if name in side:
                g[name] = self._world(side, poses, "x", name)
        if "plane" in side:
            g["porigin"] = self._world(side, poses, "plane", "origin")
            g["pnormal"] = self._world(side, poses, "plane", "normal")
        return g

    def residual(self, poses, with_jac=True):
        rows, jac = [], []

        def add(s):
            rows.append(s.v)
            jac.append(s.D)

        def addv(vec):
            for i in range(3):
                rows.append(float(vec.v[i]))
                jac.append(vec.D[i])

        for mate in self.mates:
            d, f = self._geo(mate["a"], poses), self._geo(mate["b"], poses)
            t = mate["type"]
            if t == "coincident":
                if "porigin" in d and "porigin" in f:
                    add(vdot(vsub(d["porigin"], f["porigin"]), f["pnormal"]))
                    addv(vcross(d["pnormal"], f["pnormal"]))
                elif "porigin" in d:
                    add(vdot(vsub(f["point"], d["porigin"]), d["pnormal"]))
                elif "porigin" in f:
                    add(vdot(vsub(d["point"], f["porigin"]), f["pnormal"]))
                else:
                    addv(vsub(d["point"], f["point"]))
            elif t == "concentric":
                addv(vcross(d["direction"], f["direction"]))
                addv(vcross(vsub(d["axis_origin"], f["axis_origin"]), f["direction"]))
                if not mate["allow_rotation"] and "perp" in d and "perp" in f:
                    addv(vcross(d["perp"], f["perp"]))
            elif t == "parallel":
                addv(vcross(d["direction"], f["direction"]))
            elif t == "angle":
                target = abs(mate["value"]) % 360
                target = min(target, 360 - target)
                dd = vdot(vnorm(d["direction"]), vnorm(f["direction"]))
                add(S(dd.v - math.cos(math.radians(target)), dd.D))
            elif t == "distance":
                tsq = mate["value"] ** 2
                if "porigin" in d and "porigin" in f:
                    sg = vdot(vsub(d["porigin"], f["porigin"]), f["pnormal"])
                    add(S(sg.v**2 - tsq, 2 * sg.v * sg.D))
                    addv(vcross(d["pnormal"], f["pnormal"]))
                elif "porigin" in d:
                    sg = vdot(vsub(f["point"], d["porigin"]), d["pnormal"])
                    add(S(sg.v**2 - tsq, 2 * sg.v * sg.D))
                elif "porigin" in f:
                    sg = vdot(vsub(d["point"], f["porigin"]), f["pnormal"])
                    add(S(sg.v**2 - tsq, 2 * sg.v * sg.D))
                elif "axis_origin" in d and "axis_origin" in f:
                    p = vcross(vsub(d["axis_origin"], f["axis_origin"]), f["direction"])
                    pp = vdot(p, p)
                    add(S(pp.v - tsq, pp.D))
                    addv(vcross(d["direction"], f["direction"]))
                else:
                    off = vsub(d["point"], f["point"])
                    oo = vdot(off, off)
                    add(S(oo.v - tsq, oo.D))
        r = np.array(rows, float)
        return (r, np.array(jac, float)) if with_jac else r


# ---- (c) retractions ---------------------------------------------------------------------------------------------


def weights(k, lever, grabbed=0, follower=FOLLOWER_WEIGHT):
    base = np.array([1, 1, 1, lever, lever, lever], float)
    return np.concatenate([base if i == grabbed else base * follower for i in range(k)])


def sqp_nearest(model, poses, wish_poses, W, iters, lam=0.0, rot_cap=0.6, stats=None, trust=TRUST, lam_abs=1e-9, polish=1):
    """Sequential nearest-point retraction: at each iteration solve the LINEARISED nearest-point problem
         min |W (x + dx - x_wish)|  s.t.  r + J dx = 0           (x = current twist offsets, x_wish = wished poses)
    (damped KKT, y = W dx, A = J W^-1:  y = y0 - A^T (A A^T + lam I)^-1 (A y0 + r),  y0 = W g,  g = log(wish) - log(x)),
    apply it (additive chart, rotation step cap), repeat a FIXED number of times. `poses`: list of (R, t) per member (start),
    `wish_poses`: where each member would like to be (grabbed = the hand, followers = their previous poses)."""
    k = len(poses)
    cur = list(poses)
    for it in range(iters):
        r, J = model.residual(cur)
        # desired displacement of every member from its CURRENT pose to its wished pose (log chart)
        g = np.concatenate([_log_delta(cur[i], wish_poses[i]) for i in range(k)])
        A = J / W
        y0 = W * g
        n0 = float(np.linalg.norm(y0))
        if trust and n0 > trust:  # trust region: never ask for more than `trust` weighted mm of displacement per iteration
            y0 = y0 * (trust / n0)
        if r.size:
            M = A @ A.T
            M += (lam * max(1.0, float(np.trace(M))) + lam_abs) * np.eye(len(M))
            y = y0 - A.T @ np.linalg.solve(M, A @ y0 + r)
        else:
            y = y0
        dx = y / W
        rot = max(float(np.linalg.norm(dx[6 * i + 3 : 6 * i + 6])) for i in range(k))
        if rot > rot_cap:
            dx *= rot_cap / rot
        cur = [apply_delta(cur[i], dx[6 * i : 6 * i + 6]) for i in range(k)]
        if stats is not None:
            stats["evals"] = stats.get("evals", 0) + 1
            stats["rows"] = r.size
    if polish:  # constraint-only correction (no pull towards the wish): drives the residual to ~1e-8 at the end of the frame
        cur = min_norm_gn(model, cur, W, polish, rot_cap=rot_cap, lam_abs=lam_abs)
    return cur


def _log_delta(a, b):
    """[t_b - t_a, rotvec(R_b R_a^T)] - the additive chart delta taking pose a to pose b."""
    w = gen.rotvec_from_rot(b[0] @ a[0].T)
    return np.concatenate([b[1] - a[1], w])


def min_norm_gn(model, poses, W, iters, lam=0.0, rot_cap=0.6, stats=None, lam_abs=1e-9):
    """What the backend does: GN min-norm correction FROM THE SEED (grabbed already put at the wish): dx = -W^-1 A^+ r."""
    k = len(poses)
    cur = list(poses)
    for _ in range(iters):
        r, J = model.residual(cur)
        if not r.size or np.max(np.abs(r)) < 1e-12:
            break
        A = J / W
        M = A @ A.T
        M += (lam * max(1.0, float(np.trace(M))) + lam_abs) * np.eye(len(M))
        dx = -(A.T @ np.linalg.solve(M, r)) / W
        rot = max(float(np.linalg.norm(dx[6 * i + 3 : 6 * i + 6])) for i in range(k))
        if rot > rot_cap:
            dx *= rot_cap / rot
        cur = [apply_delta(cur[i], dx[6 * i : 6 * i + 6]) for i in range(k)]
        if stats is not None:
            stats["evals"] = stats.get("evals", 0) + 1
    return cur


# ---- scenes / backend plumbing -------------------------------------------------------------------------------------


def backend_scene(name, variant):
    import tests.conftest  # noqa: F401
    from tests import motion_scenes as ms
    from tests import test_assembly_group_solve as gs
    from tests.test_assembly_solver import client
    if name in ("bolt", "hinge"):
        root, roles = getattr(ms, f"{name}_scene")()
        if variant == "fixed":
            ms.fix(root, roles["base"])
        mover = roles["mover"]
    elif name == "swing":  # off-axis pin: the curved single-part mate
        root = gs._offset_pin_scene()
        mover = client.get(f"/document/parts/{root}/occurrences").json()[0]["id"]
    elif name == "angle":
        root = gs._plate_scene("angle", start=((5, 5, 60), (1, 0, 0), 45.0), value=60.0)
        mover = client.get(f"/document/parts/{root}/occurrences").json()[0]["id"]
    elif name == "bcd":
        from tests.test_assembly_group import _plate_bcd
        root, _p, _parts = _plate_bcd()
        mover = "occ-B"
    else:
        raise ValueError(name)
    from app.document.store import get_document
    document = get_document()
    return document, document.parts[root], mover


class Scene:
    def __init__(self, name, variant, lever=10.0, follower=LOCAL_FOLLOWER):
        from app.document import assembly_group as ag
        self.ag = ag
        self.name, self.variant, self.lever = name, variant, lever
        self.document, self.part, self.mover = backend_scene(name, variant)
        bm = ag.build_group_model(self.document, self.part, self.mover)
        self.backend_model = bm
        self.ids = list(bm.member_ids)
        self.spec = export_model(bm)
        self.model = Model(self.spec)
        self.start = [rt_pose(bm.base_transforms[i]) for i in self.ids]
        self.W = weights(len(self.ids), lever, follower=follower)
        # a scene built by a script may start with a mate unsatisfied (the app snaps at create_mate): snap with the backend
        snapped, _ = self.backend_solve(self.start[0])
        if snapped is not None:
            self.start = snapped

    def backend_solve(self, wish_pose, reference=None):
        from app.document.models import RigidTransform
        R, t = wish_pose
        v = gen.rotvec_from_rot(R)
        th = float(np.linalg.norm(v))
        axis = v / th if th > 1e-12 else np.array([0, 0, 1.0])
        wanted = RigidTransform(translation=tuple(float(x) for x in t), rotation_axis=tuple(float(x) for x in axis), rotation_angle_degrees=math.degrees(th))
        ref = None
        if reference is not None:
            ref = {}
            for i, oid in enumerate(self.ids):
                R_, t_ = reference[i]
                vv = gen.rotvec_from_rot(R_)
                tt = float(np.linalg.norm(vv))
                ax = vv / tt if tt > 1e-12 else np.array([0, 0, 1.0])
                ref[oid] = RigidTransform(translation=tuple(float(x) for x in t_), rotation_axis=tuple(float(x) for x in ax), rotation_angle_degrees=math.degrees(tt))
        res = self.ag.solve_group(self.document, self.part, self.mover, wanted, self.lever, reference=ref)
        if not res.converged:
            return None, res
        return [rt_pose(res.poses[i]) for i in self.ids], res

    def anchor_model(self, poses):
        """The current client projector's model at `poses`: weighted GS rows of the backend basis at that reference."""
        from dataclasses import replace
        base = {}
        from app.document.models import RigidTransform
        for i, oid in enumerate(self.ids):
            R_, t_ = poses[i]
            vv = gen.rotvec_from_rot(R_)
            tt = float(np.linalg.norm(vv))
            ax = vv / tt if tt > 1e-12 else np.array([0, 0, 1.0])
            base[oid] = RigidTransform(translation=tuple(float(x) for x in t_), rotation_axis=tuple(float(x) for x in ax), rotation_angle_degrees=math.degrees(tt))
        m = replace(self.backend_model, base_transforms=base)
        an = self.ag.analyze_model(m, self.lever)
        s = gen.member_scale(len(self.ids), self.lever)
        rows = gen.weighted_gram_schmidt([list(r) for r in an.basis], s) if an.basis.size else []
        return [to_gen(p) for p in poses], rows

    def project(self, anchor, wish_pose):
        refs, rows = anchor
        out = gen.project(refs, rows, to_gen(wish_pose), self.lever)
        return [from_gen(p) for p in out]


def true_nearest(scene, start, wish_poses, iters=40):
    """High-effort reference: long SQP from the given start (not part of any run-time budget)."""
    return sqp_nearest(scene.model, start, wish_poses, scene.W, iters)


def cost(scene, poses, wish_grabbed):
    """The objective the retraction minimises: weighted distance of the grabbed pose from the wish (grabbed block only)."""
    return pose_dist(poses[0], wish_grabbed, scene.lever)


def residual_inf(scene, poses):
    r = scene.model.residual(poses, with_jac=False)
    return float(np.max(np.abs(r))) if r.size else 0.0


# ---- hand paths (same family as client/test/constrained_drag_smoothness_test.dart) ----------------------------------


def min_jerk(t):
    return 10 * t**3 - 15 * t**4 + 6 * t**5


def hand(path, base, t):
    s = min_jerk(t)
    R, tr = base
    d = np.zeros(6)
    deg = math.pi / 180
    if path.startswith("rot_x"):
        d[3] = (120 if path == "rot_x_120" else 180) * deg * (s if path == "rot_x_120" else min_jerk(min(1.0, t * 3)))
    elif path == "rot_y_120":
        d[4] = 120 * deg * s
    elif path == "rot_z_120":
        d[5] = 120 * deg * s
    elif path == "rot_xy_60":
        d[3] = d[4] = 0.7071 * 60 * deg * s
    elif path == "trans_x_40":
        d[0] = 40 * s
    elif path == "trans_z_40":
        d[2] = 40 * s
    elif path == "radial_out_back_12":
        d[0] = 12 * math.sin(math.pi * t)
    elif path == "circle_xy_25":
        d[0] = 25 * (math.cos(2 * math.pi * s) - 1)
        d[1] = 25 * math.sin(2 * math.pi * s)
    elif path == "swing_z_90":
        d[5] = 90 * deg * s
    else:
        raise ValueError(path)
    return apply_delta(base, d)


PATHS = ["rot_x_120", "rot_y_120", "rot_z_120", "rot_xy_60", "trans_x_40", "trans_z_40", "radial_out_back_12", "circle_xy_25", "rot_x_fast_180"]


# ---- (d) evaluation ---------------------------------------------------------------------------------------------------


def run_path(scene, path, frames=90, anchor_every=9, local_iters=3):
    """Simulate one drag three ways from the same hand:
       current  - the S6 projector, re-anchored every `anchor_every` frames from the backend (reference = last anchor),
       local    - SQP nearest-point retraction each frame, warm start = previous frame, `local_iters` iterations,
       truth    - long SQP from the previous truth (reference for 'nearest')."""
    lever, W = scene.lever, scene.W
    k = len(scene.ids)
    base = scene.start[0]
    cur_poses = list(scene.start)  # projector's anchor state
    anchor = scene.anchor_model(cur_poses)
    blender = gen.Blender(k)
    local = list(scene.start)
    truth = list(scene.start)
    out = {m: {"shown": [list(scene.start)]} for m in ("current", "local", "truth")}
    hand_prev = base
    hand_steps, rows = [], {"current": [], "local": [], "truth": []}
    costs = {"current": [], "local": [], "truth": []}
    resid = {"current": [], "local": [], "truth": []}
    iters_used = []
    for f in range(1, frames + 1):
        wish = hand(path, base, f / frames)
        hand_steps.append(pose_dist(wish, hand_prev, lever))
        hand_prev = wish
        # current: re-anchor from the backend every few frames (reference = the last anchor), blend ignored (see note in doc)
        if f % anchor_every == 0:
            sol, _ = scene.backend_solve(wish, reference=cur_poses)
            if sol is not None:
                old_proj = [to_gen(p) for p in scene.project(anchor, wish)]
                cur_poses = sol
                anchor = scene.anchor_model(sol)
                blender.on_anchor(old_proj, [to_gen(p) for p in scene.project(anchor, wish)])
        cur = [from_gen(p) for p in blender.shown([to_gen(p) for p in scene.project(anchor, wish)])]  # with the spec's tau=2 blend
        # local: wish for the grabbed member, followers want to stay where they were (min motion = continuity)
        wishes = [wish] + [local[i] for i in range(1, k)]
        t0 = time.perf_counter()
        st = {}
        local = sqp_nearest(scene.model, local, wishes, W, local_iters, stats=st)
        iters_used.append(time.perf_counter() - t0)
        wishes_t = [wish] + [truth[i] for i in range(1, k)]
        truth = sqp_nearest(scene.model, truth, wishes_t, W, 40)
        for name, poses in (("current", cur), ("local", local), ("truth", truth)):
            out[name]["shown"].append(poses)
            costs[name].append(cost(scene, poses, wish))
            resid[name].append(residual_inf(scene, poses))
    res = {}
    hs = np.array(hand_steps)
    for name in ("current", "local", "truth"):
        sh = out[name]["shown"]
        stepg = np.array([pose_dist(sh[i + 1][0], sh[i][0], lever) for i in range(frames)])
        stepf = np.array([max([pose_dist(sh[i + 1][j], sh[i][j], lever) for j in range(1, k)] or [0.0]) for i in range(frames)])
        jerkg = np.abs(np.diff(stepg))
        jerkf = np.abs(np.diff(stepf))
        big = hs > 0.2 * hs.max()
        res[name] = {
            "ratio_g": float(np.max(stepg[big] / hs[big])) if big.any() else 0.0,
            "jerk_g": float(jerkg.max()) if len(jerkg) else 0.0,
            "jerk_f": float(jerkf.max()) if len(jerkf) else 0.0,
            "cost_excess_max": float(np.max(np.array(costs[name]) - np.array(costs["truth"]))),
            "resid_max": float(np.max(resid[name])),
        }
    res["hand_jerk"] = float(np.abs(np.diff(hs)).max())
    res["local_us_per_frame"] = float(np.mean(iters_used) * 1e6)
    return res


def reconcile(scene, path, frames=90, every=9, local_iters=3):
    """How far does the BACKEND's anchor answer (reference = the client's CURRENT local poses) differ from the local result at
    the same wish? That distance is the pop an anchor would cause under 'local solve + backend reconciliation'."""
    lever, k = scene.lever, len(scene.ids)
    base = scene.start[0]
    local = list(scene.start)
    pops_g, pops_f, excess = [], [], []
    for f in range(1, frames + 1):
        wish = hand(path, base, f / frames)
        local = sqp_nearest(scene.model, local, [wish] + [local[i] for i in range(1, k)], scene.W, local_iters)
        if f % every == 0:
            sol, _ = scene.backend_solve(wish, reference=local)
            if sol is not None:
                pops_g.append(pose_dist(sol[0], local[0], lever))
                pops_f.append(max([pose_dist(sol[j], local[j], lever) for j in range(1, k)] or [0.0]))
                excess.append(cost(scene, sol, wish) - cost(scene, local, wish))  # > 0: the backend's answer is FARTHER from the wish
    return (max(pops_g) if pops_g else float("nan"), max(pops_f) if pops_f else float("nan"), max(excess) if excess else float("nan"))


# ---- sections ---------------------------------------------------------------------------------------------------------


def section_check():
    print("== check: exported model vs backend residual, analytic vs finite-difference Jacobian")
    for name, variant in (("bolt", "floating"), ("hinge", "floating"), ("swing", ""), ("angle", ""), ("bcd", "")):
        sc = Scene(name, variant)
        rng = np.random.default_rng(1)
        worst_r, worst_j = 0.0, 0.0
        for _ in range(5):
            poses = [apply_delta(p, rng.normal(0, 0.05, 6) * np.array([5, 5, 5, 1, 1, 1])) for p in sc.start]
            from app.document.models import RigidTransform
            bpos = {}
            for i, oid in enumerate(sc.ids):
                R_, t_ = poses[i]
                vv = gen.rotvec_from_rot(R_)
                tt = float(np.linalg.norm(vv))
                ax = vv / tt if tt > 1e-12 else np.array([0, 0, 1.0])
                bpos[oid] = RigidTransform(translation=tuple(float(x) for x in t_), rotation_axis=tuple(float(x) for x in ax), rotation_angle_degrees=math.degrees(tt))
            rb = sc.backend_model.residual(None, bpos)
            ra, J = sc.model.residual(poses)
            worst_r = max(worst_r, float(np.max(np.abs(rb - ra))))
            # finite-difference Jacobian in the same chart
            Jfd = np.zeros_like(J)
            for c in range(sc.model.n):
                e = np.zeros(sc.model.n)
                e[c] = 1e-6
                pp = [apply_delta(poses[i], e[6 * i : 6 * i + 6]) for i in range(len(poses))]
                pm = [apply_delta(poses[i], -e[6 * i : 6 * i + 6]) for i in range(len(poses))]
                Jfd[:, c] = (sc.model.residual(pp, False) - sc.model.residual(pm, False)) / 2e-6
            worst_j = max(worst_j, float(np.max(np.abs(J - Jfd))))
        print(f"  {name:6} {variant:8} members={len(sc.ids)} rows={len(ra):2} cols={sc.model.n:2}  |r_np - r_backend|max={worst_r:.1e}  |J_analytic - J_fd|max={worst_j:.1e}")


def section_scenes():
    print("== scenes: current projector vs local nearest-point retraction (3 iterations/frame, warm start), 90 frames, anchors every 9")
    print(f"{'scene':6} {'variant':8} {'path':19} | ratioG cur>loc | jerkG cur>loc    | jerkF cur>loc    | cost-excess cur>loc (vs true nearest) | resid_max cur>loc  | us/frame")
    for name, variant in (("bolt", "floating"), ("bolt", "fixed"), ("hinge", "floating"), ("hinge", "fixed"), ("swing", ""), ("angle", ""), ("bcd", "")):
        sc = Scene(name, variant)
        for path in PATHS if name in ("bolt", "hinge") else ["rot_z_120", "swing_z_90", "trans_x_40", "rot_x_120", "circle_xy_25"] if name != "bcd" else ["trans_x_40", "rot_z_120", "circle_xy_25"]:
            try:
                r = run_path(sc, path)
            except Exception as exc:  # report, never hide
                print(f"{name:6} {variant:8} {path:19} | ERROR {type(exc).__name__}: {str(exc)[:80]}")
                continue
            c, l = r["current"], r["local"]
            print(f"{name:6} {variant:8} {path:19} | {c['ratio_g']:5.2f}>{l['ratio_g']:<5.2f} | {c['jerk_g']:6.3f}>{l['jerk_g']:<6.3f} | {c['jerk_f']:6.3f}>{l['jerk_f']:<6.3f} | {c['cost_excess_max']:8.3f}>{l['cost_excess_max']:<8.3f}           | {c['resid_max']:.1e}>{l['resid_max']:.1e} | {r['local_us_per_frame']:7.0f}")


def section_random(n=60):
    print("== random: large off-manifold wishes (up to 2 rad / 120 mm from the start), fixed-iteration local solve from a COLD start (projector output) and from the previous pose")
    rng = np.random.default_rng(7)
    for name, variant in (("bolt", "fixed"), ("hinge", "fixed"), ("swing", ""), ("angle", ""), ("hinge", "floating")):
        sc = Scene(name, variant)
        k = len(sc.ids)
        anchor = sc.anchor_model(sc.start)
        stats = {"conv": {2: 0, 3: 0, 5: 0, 8: 0}, "worse_than_proj": 0, "cost_ratio": []}
        for _ in range(n):
            d = np.concatenate([rng.normal(0, 1, 3) * 120 / 3, rng.normal(0, 1, 3) * 2 / 3])
            wish = apply_delta(sc.start[0], d)
            proj = sc.project(anchor, wish)
            best = None
            for it in (2, 3, 5, 8):
                sol = sqp_nearest(sc.model, proj, [wish] + [proj[i] for i in range(1, k)], sc.W, it)
                ok = residual_inf(sc, sol) < 1e-6
                stats["conv"][it] += int(ok)
                if it == 5:
                    best = (sol, ok)
            ref = sqp_nearest(sc.model, proj, [wish] + [proj[i] for i in range(1, k)], sc.W, 60)
            if residual_inf(sc, ref) < 1e-6:
                cr = cost(sc, best[0], wish) / max(cost(sc, ref, wish), 1e-9)
                stats["cost_ratio"].append(cr)
            if cost(sc, best[0], wish) > cost(sc, proj, wish) + 1e-9 and residual_inf(sc, best[0]) > 1e-6:
                stats["worse_than_proj"] += 1
        cr = np.array(stats["cost_ratio"]) if stats["cost_ratio"] else np.array([float("nan")])
        print(f"  {name:6} {variant:8} converged(res<1e-6) after 2/3/5/8 its: " + "/".join(f"{stats['conv'][i]}" for i in (2, 3, 5, 8)) + f" of {n};  cost vs 60-it reference (5 its): median {np.median(cr):.3f} max {np.max(cr):.3f}")


def section_warm(n=60):
    print("== warm: one frame from an on-manifold pose to a wish s away (random direction), 3 SQP iterations + 1 polish; converged = residual < 1e-6")
    rng = np.random.default_rng(11)
    sizes = ((3.0, 0.05), (20.0, 0.3), (60.0, 1.0))
    print("  scene variant   step (mm, rad): converged / " + " / ".join(f"{mm:g}mm,{rd:g}rad" for mm, rd in sizes) + "   (cost vs 40-it reference: median)")
    for name, variant in (("bolt", "fixed"), ("hinge", "fixed"), ("swing", ""), ("angle", ""), ("hinge", "floating"), ("bcd", "")):
        sc = Scene(name, variant)
        k = len(sc.ids)
        line = []
        for mm, rd in sizes:
            ok, crs = 0, []
            for _ in range(n):
                d = np.concatenate([rng.normal(size=3) / 1.7 * mm, rng.normal(size=3) / 1.7 * rd])
                wish = apply_delta(sc.start[0], d)
                w = [wish] + [sc.start[i] for i in range(1, k)]
                sol = sqp_nearest(sc.model, sc.start, w, sc.W, 3)
                good = residual_inf(sc, sol) < 1e-6
                ok += int(good)
                if good:
                    ref = sqp_nearest(sc.model, sc.start, w, sc.W, 40)
                    if residual_inf(sc, ref) < 1e-6:
                        crs.append(cost(sc, sol, wish) / max(cost(sc, ref, wish), 1e-9))
            line.append(f"{ok:2d}/{n} ({np.median(crs) if crs else float('nan'):.3f})")
        print(f"  {name:6} {variant:8}                  " + "   ".join(line))


def section_cost():
    print("== cost: linear-system size and operation counts per iteration, wall clock of this numpy prototype")
    for name, variant in (("bolt", "floating"), ("hinge", "floating"), ("hinge", "fixed"), ("bcd", "")):
        sc = Scene(name, variant)
        r, J = sc.model.residual(sc.start)
        rows, cols = J.shape
        k = len(sc.ids)
        t0 = time.perf_counter()
        for _ in range(200):
            sqp_nearest(sc.model, sc.start, sc.start, sc.W, 1)
        us = (time.perf_counter() - t0) / 200 * 1e6
        flops = rows * rows * cols + rows**3 // 3 + 2 * rows * cols
        print(f"  {name:6} {variant:8} k={k} mates={len(sc.model.mates)} rows={rows:2} cols={cols:2}  (A A^T is {rows}x{rows}; ~{flops} flops/iteration + residual/Jacobian ~{40 * len(sc.model.mates) * 12} flops)  numpy {us:.0f} us/iteration")


def main():
    secs = sys.argv[1:] or ["check", "scenes", "random", "cost"]
    for s in secs:
        if s in ("check", "scenes", "random", "cost"):
            {"check": section_check, "scenes": section_scenes, "random": section_random, "cost": section_cost}[s]()
    if "reconcile" in secs:
        for name, variant, path in (("hinge", "fixed", "trans_x_40"), ("hinge", "fixed", "rot_z_120"), ("hinge", "fixed", "circle_xy_25"), ("swing", "", "swing_z_90"), ("swing", "", "circle_xy_25"), ("bolt", "floating", "rot_x_120"), ("hinge", "floating", "rot_x_120")):
            sc = Scene(name, variant)
            g_, f_, e_ = reconcile(sc, path)
            print(f"  reconcile {name:6} {variant:8} {path:12} backend(reference=local) vs local: max distance grabbed {g_:.3f} followers {f_:.3f}; backend cost - local cost (max) {e_:.3f}")
    if "warm" in secs:
        section_warm()


if __name__ == "__main__":
    main()
