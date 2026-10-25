"""Resolved mate geometry ("constraint model") and the nearest-point retraction on it
(`docs/motion/projector-spec.md` section 4b, `docs/constrained-drag-f1a-design.md`).

`export_constraint_model` turns a `GroupModel` into plain JSON-able data: per mate its type, value, `allow_rotation`, the BRANCH
the mate stands for (`alignment`, `side`, `perp`: +1 / -1, `docs/mate-solution-choice-plan.md`) and, for each side, the member
index (-1 = not a member) plus an optional frozen pose and the resolved LOCAL geometry. `ConstraintModel` evaluates the mate
residuals of that data at poses `(R, t)` with analytic (forward-mode) Jacobians, exactly the residuals of
`assembly_solver._mate_residual_vector` - each zero only on the chosen branch. `sqp_nearest` is the sequential nearest-point retraction: at every iteration the
linearised problem "least weighted move to the wished poses that satisfies the mates" is solved, then a constraint-only
polish lands on the manifold. The client runs the same algorithm per frame (`client/lib/motion/local_retraction.dart`); the
backend runs it so its anchors are the nearest point too. Pure numpy; no OCCT."""

from __future__ import annotations

import math

import numpy as np

MODEL_VERSION = 3  # 3: an ANGLE about a hinge (`hinge_direction` on a side) also fixes the swing sense; 2: branch-specific residuals (`alignment` / `side` / `perp` per mate, linear signed DISTANCE, mm-scaled squared ones)
PAIR_MODEL_VERSION = 4  # 4: a side may carry `pair` (the mid-plane of two faces on two members); emitted ONLY when some side has one, else 3
COUPLER_MODEL_VERSION = 5  # 5: coupler mates (gear / rack_pinion / screw: rows on the MOVE of each side from its `anchor` pose); emitted ONLY when the model has one
LIMIT_MODEL_VERSION = 6  # 6: limit mates (limit_distance / limit_angle: an inequality row with `min` / `max`, held only when violated); emitted ONLY when the model has one
COUPLER_TYPES = ("gear", "rack_pinion", "screw")
LIMIT_TYPES = ("limit_distance", "limit_angle")
SUPPORTED_TYPES = ("coincident", "concentric", "parallel", "angle", "distance", *COUPLER_TYPES, *LIMIT_TYPES)
LIMIT_ROUNDS = 3  # active-set rounds of one retraction (a limit held at its bound is added, never dropped, within a frame)
LIMIT_TOL = 1e-6  # mm / degrees a value may sit outside its range before the limit counts as violated (the client's tolerance)

# Constants of spec section 4b (also in docs/motion/vectors.json -> constants).
LOCAL_FOLLOWER = 1e-2  # follower weight of the local retraction (the PROJECTION metric keeps 1e-4)
TRUST = 6.0  # weighted mm of wished displacement per iteration
ROT_CAP = 0.6  # rad per iteration, any member
LAM_ABS = 1e-9  # absolute damping of A A^T
ITERS = 3  # per-frame iterations on the client
POLISH = 1  # constraint-only steps at the end
ACCEPT_RESIDUAL = 1e-6
DISTANCE_FLOOR = 1e-3  # mm: divisor floor of the mm-scaled squared DISTANCE residuals (axis-axis, point-point)


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


def _screw_v(w) -> np.ndarray:
    """`V(w) = I + (1-cos th)/th^2 K + (th-sin th)/th^3 K^2` (projector spec section 5)."""
    th = float(np.linalg.norm(w))
    k = skew(w)
    if th < 1e-4:
        return np.eye(3) + (0.5 - th * th / 24.0) * k + (1.0 / 6.0 - th * th / 120.0) * k @ k
    return np.eye(3) + (1.0 - math.cos(th)) / (th * th) * k + (th - math.sin(th)) / th**3 * k @ k


def screw_exp(pose: Pose, d) -> Pose:
    """Pose reached by integrating the twist `d = [v, w]` (origin velocity + rotation vector) as a constant spatial screw:
    `R' = exp(w) R`, `t' = exp(w) t + V (v - w x t)`. The client's integrator (projector spec section 5)."""
    w = np.asarray(d[3:6], float)
    r, t = pose
    return exp_rot(w) @ r, exp_rot(w) @ t + _screw_v(w) @ (np.asarray(d[:3], float) - np.cross(w, t))


def screw_log(a: Pose, b: Pose) -> np.ndarray:
    """The twist `d` with `screw_exp(a, d) == b` (exact inverse of `screw_exp`, projector spec section 5)."""
    w = rotvec_from_rot(b[0] @ a[0].T)
    th = float(np.linalg.norm(w))
    k = skew(w)
    c = (1.0 / 12.0 + th**2 / 720.0 + th**4 / 30240.0) if th < 1e-2 else (1.0 - th * math.sin(th) / (2.0 * (1.0 - math.cos(th)))) / (th * th)
    u = (np.eye(3) - 0.5 * k + c * k @ k) @ (b[1] - exp_rot(w) @ a[1])
    return np.concatenate([u + np.cross(w, a[1]), w])


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
    has_pair = False
    has_coupler = False
    has_limit = False
    for mate, a, b in model.sides:
        if mate.type.value not in SUPPORTED_TYPES:
            return None

        def side(s) -> dict:
            nonlocal has_pair
            g = s.geometry
            out: dict = {"member": ids.index(s.occurrence_id) if s.occurrence_id in ids else -1}
            if s.frozen_transform is not None:
                r, t = rigid_to_pose(s.frozen_transform)
                out["frozen"] = {"r": r.tolist(), "t": t.tolist()}
            if mate.type.value in COUPLER_TYPES and s.occurrence_id in ids:
                # a coupler measures a member's MOVE from the pose the solve started from: its base pose (clients refresh it at every anchor)
                ar, at = rigid_to_pose(model.base_transforms[s.occurrence_id])
                out["anchor"] = {"r": ar.tolist(), "t": at.tolist()}
            for name in ("point", "axis_origin", "direction", "perp"):
                v = getattr(g, name)
                if v is not None:
                    out[name] = [float(c) for c in v]
            if g.hinge is not None and mate.type.value in ("angle", "limit_angle"):
                # the hinge an ANGLE swings about (the direction only: the residual needs no point on it)
                out["hinge_direction"] = [float(c) for c in g.hinge[1]]
            if g.plane is not None:
                out["plane"] = {"origin": [float(c) for c in g.plane.origin], "normal": [float(c) for c in g.plane.normal]}
            if s.partner is not None:
                # A Width / Symmetric side over two moving parts: this side is the FIRST face; `pair` is the second face (same
                # shape as a side's member / frozen / plane). The world plane is (average of the two origins, the first normal).
                has_pair = True
                p = s.partner
                pair: dict = {"member": ids.index(p.occurrence_id) if p.occurrence_id in ids else -1}
                if p.frozen_transform is not None:
                    pr, pt = rigid_to_pose(p.frozen_transform)
                    pair["frozen"] = {"r": pr.tolist(), "t": pt.tolist()}
                pg = p.geometry.plane
                pair["plane"] = {"origin": [float(c) for c in pg.origin], "normal": [float(c) for c in pg.normal]}
                out["pair"] = pair
            return out

        from app.document.assembly_solver import _effective_mate

        if mate.type.value in LIMIT_TYPES:
            has_limit = True
            mates.append(
                {"type": mate.type.value, "id": mate.id, "min": mate.limit_min, "max": mate.limit_max, "a": side(a), "b": side(b)}
            )
            continue
        mate = _effective_mate(mate, a.geometry, b.geometry)
        if mate.type.value in COUPLER_TYPES:
            has_coupler = True
            mates.append(
                {"type": mate.type.value, "value": float(mate.value), "k": 1 if mate.secondary_flip else -1, "a": side(a), "b": side(b)}
            )
            continue
        mates.append(
            {
                "type": mate.type.value,
                "value": None if mate.value is None else float(mate.value),
                "allow_rotation": bool(mate.allow_rotation),
                # The branch (resolved: `build_group_model` fills a Closest mate in before this runs). `alignment`: +1 the
                # directions point the same way, -1 opposite; `side`: -1 when a DISTANCE sits on the -normal side;
                # `perp`: -1 for the half-turn spin of a rotation-locked CONCENTRIC. Absent / 0 reads as +1.
                "alignment": -1 if mate.alignment == "anti_aligned" else 1,
                "side": -1 if (mate.type.value == "distance" and mate.secondary_flip) else 1,
                "perp": -1 if (mate.type.value == "concentric" and mate.secondary_flip) else 1,
                "a": side(a),
                "b": side(b),
            }
        )
    version = LIMIT_MODEL_VERSION if has_limit else (COUPLER_MODEL_VERSION if has_coupler else (PAIR_MODEL_VERSION if has_pair else MODEL_VERSION))
    return {"version": version, "members": ids, "mates": mates}


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


def _scale(a: _V, c: float) -> _V:
    return _V(a.v * c, a.d * c)


def _unit(a: _V) -> _V:
    n = float(np.linalg.norm(a.v))
    u = a.v / n
    return _V(u, (np.eye(3) - np.outer(u, u)) @ a.d / n)


def _quaternion_wv(r: np.ndarray):
    """(w, v) of a rotation matrix, w >= 0 (the same as `app.document.coupler._quaternion`)."""
    t = float(np.trace(r))
    if t > 0.0:
        s = math.sqrt(t + 1.0) * 2.0
        w, v = 0.25 * s, np.array([r[2, 1] - r[1, 2], r[0, 2] - r[2, 0], r[1, 0] - r[0, 1]]) / s
    else:
        i = int(np.argmax(np.diag(r)))
        j, k = (i + 1) % 3, (i + 2) % 3
        s = math.sqrt(r[i, i] - r[j, j] - r[k, k] + 1.0) * 2.0
        v = np.zeros(3)
        v[i] = 0.25 * s
        v[j] = (r[j, i] + r[i, j]) / s
        v[k] = (r[k, i] + r[i, k]) / s
        w = (r[k, j] - r[j, k]) / s
    if w < 0.0:
        w, v = -w, -v
    return w, v


class ConstraintModel:
    """Mate residuals of an exported model, `residual(poses)` -> `(r, J)` with `J` the twist Jacobian
    (`6k` columns, `[v, w]` per member, left-multiplied: `t += v`, `R = exp(w) R`).

    A coupler mate (version 5) measures each side's move from its `anchor` pose; `anchors` (a list of `(R, t)` per member) replaces
    the exported ones - the retraction's start poses of the moment, which clients refresh at every accepted anchor.

    A limit mate (version 6) is an inequality: it adds no row unless its id is in `active` (`{mate id: bound}`, the limits a retraction
    is currently holding), when it adds `(value - bound)` (radians for an angle). `violated(poses)` lists the ones to add next."""

    def __init__(self, spec: dict, anchors=None, active=None):
        self.spec = spec
        self.anchors = anchors
        self.active = dict(active or {})
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
        for name, kind in (("point", "point"), ("axis_origin", "point"), ("direction", "dir"), ("perp", "dir"), ("hinge_direction", "dir")):
            if name in side:
                g[name] = self._world(side, poses, name, kind)
        if "plane" in side:
            g["porigin"] = self._world(side, poses, "origin", "point", plane=True)
            g["pnormal"] = self._world(side, poses, "normal", "dir", plane=True)
            pair = side.get("pair")
            if pair is not None:
                # v4: the plane midway between this face and the pair's (origin = average, normal = this face's). The mate
                # residuals read it as an ordinary plane; `pair_normal` feeds the extra "the two faces stay parallel" rows.
                other = self._world(pair, poses, "origin", "point", plane=True)
                mid = _V((g["porigin"].v + other.v) / 2.0, (g["porigin"].d + other.d) / 2.0)
                g["porigin"] = mid
                if "point" in g:
                    g["point"] = mid
                g["pair_normal"] = self._world(pair, poses, "normal", "dir", plane=True)
        return g

    def _anchor(self, side: dict, m: int):
        if self.anchors is not None:
            return self.anchors[m]
        a = side["anchor"]
        return np.array(a["r"], float), np.array(a["t"], float)

    def _base_axis(self, side: dict) -> np.ndarray:
        """The side's axis direction in the world at the base pose (a constant)."""
        local = np.array(side["direction"], float)
        local = local / float(np.linalg.norm(local))
        m = side["member"]
        if m >= 0:
            return self._anchor(side, m)[0] @ local
        fz = side.get("frozen")
        return (np.array(fz["r"], float) @ local) if fz is not None else local

    def _motion(self, side: dict, poses, axis: np.ndarray):
        """`(turn, d turn, travel, d travel)` of a member side about / along the world unit `axis` since its anchor pose; zeros for a
        side that does not move. The derivatives are rows of `n` entries in the twist chart."""
        n = self.n
        zero = np.zeros(n)
        m = side["member"]
        if m < 0:
            return 0.0, zero, 0.0, zero
        r0, t0 = self._anchor(side, m)
        r, t = poses[m]
        w, v = _quaternion_wv(r @ r0.T)
        a = float(v @ axis)
        turn = 2.0 * math.atan2(a, w)
        grad = (w * w * axis + w * np.cross(v, axis) + a * v) / (w * w + a * a)
        gturn = zero.copy()
        gturn[6 * m + 3 : 6 * m + 6] = grad
        p = np.array(side["axis_origin"], float)
        q = r @ p
        travel = float(((q + t) - (r0 @ p + t0)) @ axis)
        gtravel = zero.copy()
        gtravel[6 * m : 6 * m + 3] = axis
        gtravel[6 * m + 3 : 6 * m + 6] = np.cross(q, axis)
        return turn, gturn, travel, gtravel

    def _coupler(self, mate: dict, poses):
        """`(value, gradient)` of the one row of a coupler mate (see `app.document.coupler`)."""
        t, k, val = mate["type"], float(mate["k"]), float(mate["value"])
        a, b = mate["a"], mate["b"]
        axis_a = self._base_axis(a)
        if t == "gear":
            ta, ga, _, _ = self._motion(a, poses, axis_a)
            tb, gb, _, _ = self._motion(b, poses, self._base_axis(b))
            return tb - k * val * ta, gb - k * val * ga
        if t == "rack_pinion":
            ta, ga, _, _ = self._motion(a, poses, axis_a)
            _, _, sb, gsb = self._motion(b, poses, self._base_axis(b))
            c = k * val / (2.0 * math.pi)
            return sb - c * ta, gsb - c * ga
        ta, ga, sa, gsa = self._motion(a, poses, axis_a)
        tb, gb, sb, gsb = self._motion(b, poses, axis_a)  # a screw: everything about / along the screw's axis
        c = k * val / (2.0 * math.pi)
        return (sb - sa) - c * (tb - ta), (gsb - gsa) - c * (gb - ga)

    def _limit(self, mate: dict, poses):
        """`(value, gradient)` of a limit mate's measured value (mm, or degrees for an angle); see `app.document.limit`."""
        a, b = self._geo(mate["a"], poses), self._geo(mate["b"], poses)
        if mate["type"] == "limit_distance":
            def origin(g):
                return g.get("porigin", g.get("point"))

            if "pnormal" in b:
                normal = b["pnormal"]
            else:
                normal = a["pnormal"]
            sg = _dot(_sub(origin(a), origin(b)), _unit(normal))
            return sg.v, sg.d
        hinge = a.get("hinge_direction") or b.get("hinge_direction")
        na, nb = _unit(a["direction"]), _unit(b["direction"])
        s = _dot(_cross(na, nb), _unit(hinge))
        c = _dot(na, nb)
        den = s.v * s.v + c.v * c.v
        deg = 180.0 / math.pi
        return math.degrees(math.atan2(s.v, c.v)), (c.v * s.d - s.v * c.d) / den * deg

    def violated(self, poses) -> dict:
        """`{mate id: bound}` of the limits not already held whose range `poses` leave."""
        out = {}
        for mate in self.mates:
            if mate["type"] not in LIMIT_TYPES or mate["id"] in self.active:
                continue
            value, _g = self._limit(mate, poses)
            lo, hi = mate.get("min"), mate.get("max")
            if hi is not None and value > hi + LIMIT_TOL:
                out[mate["id"]] = float(hi)
            elif lo is not None and value < lo - LIMIT_TOL:
                out[mate["id"]] = float(lo)
        return out

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

        def sign(mate: dict, key: str) -> float:
            return -1.0 if float(mate.get(key) or 1.0) < 0.0 else 1.0

        def direction_rows(a: _V, b: _V, s: float) -> None:
            # `a - s b`: zero only when `a` points the way `s b` does (the alignment branch)
            addv(_sub(a, _scale(b, s)))

        for mate in self.mates:
            t = mate["type"]
            if t in LIMIT_TYPES:
                if mate["id"] in self.active:
                    value, gradient = self._limit(mate, poses)
                    unit = math.pi / 180.0 if t == "limit_angle" else 1.0
                    rows.append((float(value) - self.active[mate["id"]]) * unit)
                    jac.append(gradient * unit)
                continue
            if t in COUPLER_TYPES:
                value, gradient = self._coupler(mate, poses)
                rows.append(float(value))
                jac.append(gradient)
                continue
            d, f = self._geo(mate["a"], poses), self._geo(mate["b"], poses)
            s = sign(mate, "alignment")
            if t == "coincident":
                if "porigin" in d and "porigin" in f:
                    add(_dot(_sub(d["porigin"], f["porigin"]), f["pnormal"]))
                    direction_rows(d["pnormal"], f["pnormal"], s)
                elif "porigin" in d:
                    add(_dot(_sub(f["point"], d["porigin"]), d["pnormal"]))
                elif "porigin" in f:
                    add(_dot(_sub(d["point"], f["porigin"]), f["pnormal"]))
                else:
                    addv(_sub(d["point"], f["point"]))
            elif t == "concentric":
                direction_rows(d["direction"], f["direction"], s)
                addv(_cross(_sub(d["axis_origin"], f["axis_origin"]), f["direction"]))
                if not mate["allow_rotation"] and "perp" in d and "perp" in f:
                    direction_rows(d["perp"], f["perp"], sign(mate, "perp"))
            elif t == "parallel":
                direction_rows(d["direction"], f["direction"], s)
            elif t == "angle":
                target = abs(mate["value"]) % 360.0
                target = min(target, 360.0 - target)
                nd, nf = _unit(d["direction"]), _unit(f["direction"])
                dd = _dot(nd, nf)
                add(_S(dd.v - math.cos(math.radians(target)), dd.d))
                hinge = d.get("hinge_direction") or f.get("hinge_direction")
                if hinge is not None and math.sin(math.radians(target)) >= 1e-6:
                    # about a hinge: the sine of the signed swing is +-sin(target) (`alignment`) - zero only on the named way
                    sw = _dot(_cross(nd, nf), _unit(hinge))
                    add(_S(sw.v - s * math.sin(math.radians(target)), sw.d))
            elif t == "distance":
                dist = abs(mate["value"])
                signed_target = sign(mate, "side") * dist
                scale = 2.0 * max(dist, DISTANCE_FLOOR)
                if "porigin" in d and "porigin" in f:
                    sg = _dot(_sub(d["porigin"], f["porigin"]), f["pnormal"])
                    add(_S(sg.v - signed_target, sg.d))
                    direction_rows(d["pnormal"], f["pnormal"], s)
                elif "porigin" in d:
                    sg = _dot(_sub(f["point"], d["porigin"]), d["pnormal"])
                    add(_S(sg.v - signed_target, sg.d))
                elif "porigin" in f:
                    sg = _dot(_sub(d["point"], f["porigin"]), f["pnormal"])
                    add(_S(sg.v - signed_target, sg.d))
                elif "axis_origin" in d and "axis_origin" in f:
                    p = _cross(_sub(d["axis_origin"], f["axis_origin"]), f["direction"])
                    pp = _dot(p, p)
                    add(_S((pp.v - dist * dist) / scale, pp.d / scale))
                    direction_rows(d["direction"], f["direction"], s)
                else:
                    off = _sub(d["point"], f["point"])
                    oo = _dot(off, off)
                    add(_S((oo.v - dist * dist) / scale, oo.d / scale))
            for geo in (d, f):
                if "pair_normal" in geo:
                    addv(_cross(_unit(geo["pnormal"]), _unit(geo["pair_normal"])))  # the pair's two faces stay parallel (rank 2)
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


def sqp_nearest_limits(spec: dict, anchors, poses, wishes, w: np.ndarray, iters: int = ITERS, polish: int = POLISH, **kw):
    """`sqp_nearest` on a model with limit mates: the active-set rounds of the clients (`docs/motion/projector-spec.md`, limits).
    Retract with no limit held; every limit the answer leaves is held at its nearest bound (an equality row) and the retraction is
    run again from the SAME start and wish, at most `LIMIT_ROUNDS` times. Stateless: nothing is carried from one call to the next, so
    a limit is released the moment the wish no longer pushes past it. Returns `(poses, {held mate id: bound})`."""
    active: dict = {}
    cand = list(poses)
    for _ in range(LIMIT_ROUNDS + 1):
        cm = ConstraintModel(spec, anchors, active=active)
        cand = sqp_nearest(cm, poses, wishes, w, iters=iters, polish=polish, **kw)
        violated = cm.violated(cand)
        if not violated:
            break
        active.update(violated)
    return cand, active
