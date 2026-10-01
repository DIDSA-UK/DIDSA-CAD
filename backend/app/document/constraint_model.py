"""Resolved mate geometry ("constraint model") and the nearest-point retraction on it
(`docs/motion/projector-spec.md` section 4b, `docs/constrained-drag-f1a-design.md`).

`export_constraint_model` turns a `GroupModel` into plain JSON-able data: per mate its type, value, `allow_rotation` and, for
each side, the member index (-1 = not a member) plus an optional frozen pose and the resolved LOCAL geometry. `ConstraintModel`
evaluates the mate residuals of that data at poses `(R, t)` with analytic (forward-mode) Jacobians, exactly the residuals of
`assembly_solver._mate_residual_vector`. `sqp_nearest` is the sequential nearest-point retraction: at every iteration the
linearised problem "least weighted move to the wished poses that satisfies the mates" is solved, then a constraint-only
polish lands on the manifold. The client runs the same algorithm per frame (`client/lib/motion/local_retraction.dart`); the
backend runs it so its anchors are the nearest point too. Pure numpy; no OCCT."""

from __future__ import annotations

import math

import numpy as np

MODEL_VERSION = 1
SUPPORTED_TYPES = ("coincident", "concentric", "parallel", "angle", "distance")

# Constants of spec section 4b (also in docs/motion/vectors.json -> constants).
LOCAL_FOLLOWER = 1e-2  # follower weight of the local retraction (the PROJECTION metric keeps 1e-4)
TRUST = 6.0  # weighted mm of wished displacement per iteration
ROT_CAP = 0.6  # rad per iteration, any member
LAM_ABS = 1e-9  # absolute damping of A A^T
ITERS = 3  # per-frame iterations on the client
POLISH = 1  # constraint-only steps at the end
ACCEPT_RESIDUAL = 1e-6


# ---- rotations ---------------------------------------------------------------------------------------------------


def skew(w) -> np.ndarray:
    return np.array([[0.0, -w[2], w[1]], [w[2], 0.0, -w[0]], [-w[1], w[0], 0.0]])


def exp_rot(w) -> np.ndarray:
    th = float(np.linalg.norm(w))
    k = skew(w)
    if th < 1e-9:
        return np.eye(3) + k + 0.5 * k @ k
    return np.eye(3) + math.sin(th) / th * k + (1.0 - math.cos(th)) / (th * th) * k @ k


def rotvec_from_rot(r: np.ndarray) -> np.ndarray:
    v = np.array([r[2, 1] - r[1, 2], r[0, 2] - r[2, 0], r[1, 0] - r[0, 1]]) / 2.0
    s, c = float(np.linalg.norm(v)), (float(np.trace(r)) - 1.0) / 2.0
    th = math.atan2(s, c)
    if th < 1e-4:
        return v * (1.0 + th * th / 6.0)
    if math.pi - th < 1e-3:
        m = (r + np.eye(3)) / 2.0
        a = m[:, int(np.argmax(np.diag(m)))]
        a = a / float(np.linalg.norm(a))
        return a * th if float(a @ v) >= 0.0 else -a * th
    return v * (th / s)


Pose = tuple  # (R 3x3, t 3)


def apply_delta(pose: Pose, d) -> Pose:
    """Backend chart (`assembly_group.apply_delta`): `t += v`, `R = exp(w) R`."""
    return exp_rot(d[3:6]) @ pose[0], pose[1] + d[:3]


def log_delta(a: Pose, b: Pose) -> np.ndarray:
    """`[t_b - t_a, rotvec(R_b R_a^T)]`: the additive-chart move taking pose `a` to pose `b`."""
    return np.concatenate([b[1] - a[1], rotvec_from_rot(b[0] @ a[0].T)])


def weights(k: int, lever: float, grabbed: int = 0, follower: float = LOCAL_FOLLOWER) -> np.ndarray:
    base = np.array([1.0, 1.0, 1.0, lever, lever, lever])
    return np.concatenate([base if i == grabbed else base * follower for i in range(k)])


# ---- export ------------------------------------------------------------------------------------------------------


def _rotation_matrix(rt) -> np.ndarray:
    axis = np.array(rt.rotation_axis, float)
    n = float(np.linalg.norm(axis))
    if n < 1e-12 or abs(rt.rotation_angle_degrees) < 1e-15:
        return np.eye(3)
    return exp_rot(axis / n * math.radians(rt.rotation_angle_degrees))


def rigid_to_pose(rt) -> Pose:
    return _rotation_matrix(rt), np.array(rt.translation, float)


def pose_to_rigid(pose: Pose):
    from app.document.models import RigidTransform

    r, t = pose
    v = rotvec_from_rot(r)
    th = float(np.linalg.norm(v))
    axis = (v / th) if th > 1e-12 else np.array([0.0, 0.0, 1.0])
    return RigidTransform(
        translation=(float(t[0]), float(t[1]), float(t[2])),
        rotation_axis=(float(axis[0]), float(axis[1]), float(axis[2])),
        rotation_angle_degrees=math.degrees(th),
    )


def export_constraint_model(model) -> dict | None:
    """The wire form of a `GroupModel`'s mates; `None` when a mate type is not one the client can evaluate."""
    ids = list(model.member_ids)
    mates = []
    for mate, a, b in model.sides:
        if mate.type.value not in SUPPORTED_TYPES:
            return None

        def side(s) -> dict:
            g = s.geometry
            out: dict = {"member": ids.index(s.occurrence_id) if s.occurrence_id in ids else -1}
            if s.frozen_transform is not None:
                r, t = rigid_to_pose(s.frozen_transform)
                out["frozen"] = {"r": r.tolist(), "t": t.tolist()}
            for name in ("point", "axis_origin", "direction", "perp"):
                v = getattr(g, name)
                if v is not None:
                    out[name] = [float(c) for c in v]
            if g.plane is not None:
                out["plane"] = {"origin": [float(c) for c in g.plane.origin], "normal": [float(c) for c in g.plane.normal]}
            return out

        mates.append(
            {
                "type": mate.type.value,
                "value": None if mate.value is None else float(mate.value),
                "allow_rotation": bool(mate.allow_rotation),
                "a": side(a),
                "b": side(b),
            }
        )
    return {"version": MODEL_VERSION, "members": ids, "mates": mates}


# ---- residual + analytic Jacobian --------------------------------------------------------------------------------


class _V:
    """A world 3-vector with its derivative (3 x n) w.r.t. the 6k twist coordinates."""

    __slots__ = ("v", "d")

    def __init__(self, v, d):
        self.v, self.d = v, d


class _S:
    __slots__ = ("v", "d")

    def __init__(self, v, d):
        self.v, self.d = v, d


def _sub(a: _V, b: _V) -> _V:
    return _V(a.v - b.v, a.d - b.d)


def _dot(a: _V, b: _V) -> _S:
    return _S(float(a.v @ b.v), a.d.T @ b.v + b.d.T @ a.v)


def _cross(a: _V, b: _V) -> _V:
    return _V(np.cross(a.v, b.v), -skew(b.v) @ a.d + skew(a.v) @ b.d)


def _unit(a: _V) -> _V:
    n = float(np.linalg.norm(a.v))
    u = a.v / n
    return _V(u, (np.eye(3) - np.outer(u, u)) @ a.d / n)


class ConstraintModel:
    """Mate residuals of an exported model, `residual(poses)` -> `(r, J)` with `J` the twist Jacobian
    (`6k` columns, `[v, w]` per member, left-multiplied: `t += v`, `R = exp(w) R`)."""

    def __init__(self, spec: dict):
        self.spec = spec
        self.k = len(spec["members"])
        self.n = 6 * self.k
        self.mates = spec["mates"]
        self.members = list(spec["members"])

    def _world(self, side: dict, poses, name: str, kind: str, plane: bool = False) -> _V:
        local = np.array(side["plane"][name] if plane else side[name], float)
        m = side["member"]
        d = np.zeros((3, self.n))
        if m < 0:
            fz = side.get("frozen")
            if fz is None:
                return _V(local.copy(), d)
            r, t = np.array(fz["r"], float), np.array(fz["t"], float)
        else:
            r, t = poses[m]
        w = r @ local
        if kind == "point":
            v = w + t
            if m >= 0:
                d[:, 6 * m : 6 * m + 3] = np.eye(3)
                d[:, 6 * m + 3 : 6 * m + 6] = -skew(w)
        else:
            v = w
            if m >= 0:
                d[:, 6 * m + 3 : 6 * m + 6] = -skew(w)
        return _V(v, d)

    def _geo(self, side: dict, poses) -> dict:
        g = {}
        for name, kind in (("point", "point"), ("axis_origin", "point"), ("direction", "dir"), ("perp", "dir")):
            if name in side:
                g[name] = self._world(side, poses, name, kind)
        if "plane" in side:
            g["porigin"] = self._world(side, poses, "origin", "point", plane=True)
            g["pnormal"] = self._world(side, poses, "normal", "dir", plane=True)
        return g

    def residual(self, poses, with_jacobian: bool = True):
        rows: list = []
        jac: list = []

        def add(s: _S) -> None:
            rows.append(s.v)
            jac.append(s.d)

        def addv(vec: _V) -> None:
            for i in range(3):
                rows.append(float(vec.v[i]))
                jac.append(vec.d[i])

        for mate in self.mates:
            d, f = self._geo(mate["a"], poses), self._geo(mate["b"], poses)
            t = mate["type"]
            if t == "coincident":
                if "porigin" in d and "porigin" in f:
                    add(_dot(_sub(d["porigin"], f["porigin"]), f["pnormal"]))
                    addv(_cross(d["pnormal"], f["pnormal"]))
                elif "porigin" in d:
                    add(_dot(_sub(f["point"], d["porigin"]), d["pnormal"]))
                elif "porigin" in f:
                    add(_dot(_sub(d["point"], f["porigin"]), f["pnormal"]))
                else:
                    addv(_sub(d["point"], f["point"]))
            elif t == "concentric":
                addv(_cross(d["direction"], f["direction"]))
                addv(_cross(_sub(d["axis_origin"], f["axis_origin"]), f["direction"]))
                if not mate["allow_rotation"] and "perp" in d and "perp" in f:
                    addv(_cross(d["perp"], f["perp"]))
            elif t == "parallel":
                addv(_cross(d["direction"], f["direction"]))
            elif t == "angle":
                target = abs(mate["value"]) % 360.0
                target = min(target, 360.0 - target)
                dd = _dot(_unit(d["direction"]), _unit(f["direction"]))
                add(_S(dd.v - math.cos(math.radians(target)), dd.d))
            elif t == "distance":
                tsq = mate["value"] ** 2
                if "porigin" in d and "porigin" in f:
                    sg = _dot(_sub(d["porigin"], f["porigin"]), f["pnormal"])
                    add(_S(sg.v**2 - tsq, 2 * sg.v * sg.d))
                    addv(_cross(d["pnormal"], f["pnormal"]))
                elif "porigin" in d:
                    sg = _dot(_sub(f["point"], d["porigin"]), d["pnormal"])
                    add(_S(sg.v**2 - tsq, 2 * sg.v * sg.d))
                elif "porigin" in f:
                    sg = _dot(_sub(d["point"], f["porigin"]), f["pnormal"])
                    add(_S(sg.v**2 - tsq, 2 * sg.v * sg.d))
                elif "axis_origin" in d and "axis_origin" in f:
                    p = _cross(_sub(d["axis_origin"], f["axis_origin"]), f["direction"])
                    pp = _dot(p, p)
                    add(_S(pp.v - tsq, pp.d))
                    addv(_cross(d["direction"], f["direction"]))
                else:
                    off = _sub(d["point"], f["point"])
                    oo = _dot(off, off)
                    add(_S(oo.v - tsq, oo.d))
        r = np.array(rows, float)
        if not with_jacobian:
            return r
        return r, (np.array(jac, float) if jac else np.zeros((0, self.n)))


# ---- retraction --------------------------------------------------------------------------------------------------


def residual_inf(model: ConstraintModel, poses) -> float:
    r = model.residual(poses, with_jacobian=False)
    return float(np.max(np.abs(r))) if r.size else 0.0


def min_norm_steps(model: ConstraintModel, poses, w: np.ndarray, iters: int, rot_cap: float = ROT_CAP, lam_abs: float = LAM_ABS):
    """Constraint-only Newton steps (least move in the metric `w`): the polish."""
    cur = list(poses)
    for _ in range(iters):
        r, jac = model.residual(cur)
        if not r.size or float(np.max(np.abs(r))) < 1e-12:
            break
        a = jac / w
        m = a @ a.T + lam_abs * np.eye(len(a))
        dx = -(a.T @ np.linalg.solve(m, r)) / w
        dx = _cap_rotation(dx, model.k, rot_cap)
        cur = [apply_delta(cur[i], dx[6 * i : 6 * i + 6]) for i in range(model.k)]
    return cur


def _cap_rotation(dx: np.ndarray, k: int, rot_cap: float) -> np.ndarray:
    rot = max(float(np.linalg.norm(dx[6 * i + 3 : 6 * i + 6])) for i in range(k))
    return dx * (rot_cap / rot) if rot > rot_cap else dx


def sqp_nearest(
    model: ConstraintModel,
    poses,
    wishes,
    w: np.ndarray,
    iters: int = ITERS,
    polish: int = POLISH,
    trust: float = TRUST,
    rot_cap: float = ROT_CAP,
    lam_abs: float = LAM_ABS,
):
    """Sequential nearest-point retraction (spec section 4b). From `poses` (a list of `(R, t)` per member) towards `wishes`
    (the poses each member would like), `iters` steps of
    `y = y0 - A^T (A A^T + lam I)^-1 (A y0 + r)`, `y0 = W g` (trust-scaled), `A = J W^-1`, `dx = W^-1 y`, then `polish`
    constraint-only steps. A fixed iteration count: bounded latency, deterministic."""
    cur = list(poses)
    for _ in range(iters):
        r, jac = model.residual(cur)
        g = np.concatenate([log_delta(cur[i], wishes[i]) for i in range(model.k)])
        a = jac / w
        y0 = w * g
        n0 = float(np.linalg.norm(y0))
        if trust and n0 > trust:
            y0 = y0 * (trust / n0)
        if r.size:
            m = a @ a.T + lam_abs * np.eye(len(a))
            y = y0 - a.T @ np.linalg.solve(m, a @ y0 + r)
        else:
            y = y0
        dx = _cap_rotation(y / w, model.k, rot_cap)
        cur = [apply_delta(cur[i], dx[6 * i : 6 * i + 6]) for i in range(model.k)]
    if polish:
        cur = min_norm_steps(model, cur, w, polish, rot_cap=rot_cap, lam_abs=lam_abs)
    return cur


def wish_cost(poses, wishes, w: np.ndarray) -> float:
    """The objective the retraction minimises: weighted squared distance of every member from its wished pose."""
    g = np.concatenate([log_delta(poses[i], wishes[i]) for i in range(len(poses))])
    return float(np.sum((w * g) ** 2))
