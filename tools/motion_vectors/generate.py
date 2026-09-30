#!/usr/bin/env python3
"""Golden vectors for the free-motion projector (docs/motion/projector-spec.md).

    python tools/motion_vectors/generate.py            # (re)writes docs/motion/vectors.json
    python tools/motion_vectors/generate.py --check    # exits 1 if the committed file differs

numpy only. The math is the numpy transcription of `docs/constrained-drag-investigation/prototypes/geo.py`
with the changes the spec makes normative: projection metric with follower weights, Gram-Schmidt in that
metric, per-member screw integration, an atan2 rotation-vector extraction (the prototype's acos loses
~1e-8 rad at small angles), and the blender / scheduler / acceptance / hysteresis state machines.

Deterministic: no randomness, every float is rounded to 10 decimals (and -0.0 -> 0.0) before it is
written, inputs are rounded BEFORE the expected values are computed from them, so a client reading the
JSON reproduces the expected numbers from exactly the inputs it sees.

Bases in the vectors are analytic (no SVD), so regeneration does not depend on LAPACK's choice of
nullspace basis. Anchors of the swing sequence use an analytic stand-in for the backend's retraction
(the vectors test the projector, not the solver; the real backend answers are pinned by
backend/tests/test_assembly_group*.py).
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "docs" / "motion" / "vectors.json"

# ---- constants (mirrored in the spec, section 10) -------------------------------------------------
FOLLOWER_WEIGHT = 1e-4      # backend _FOLLOWER_WEIGHT: follower metric scale relative to the grabbed member
DROP_REL = 1e-6             # Gram-Schmidt: drop a row whose remainder is < DROP_REL * its own norm
DROP_ABS = 1e-12
TAU_FRAMES = 2.0            # blend decay time constant
RESIDUAL_TOL = 1e-6         # anchor acceptance: residual_inf
JUMP_REJECT_FACTOR = 1.0    # anchor acceptance: client-measured jump > factor * L  => reject
REANCHOR_MS = 150.0
REANCHOR_MS_NEAR_SINGULAR = 75.0
SIGMA_GAP_LOW = 100.0
GAIN_MIN = 0.05             # hysteresis: weighted mm of wish captured only by the new directions
GAIN_FRAMES = 3


# ---- rotation / pose math ---------------------------------------------------------------------------
def skew(w):
    return np.array([[0, -w[2], w[1]], [w[2], 0, -w[0]], [-w[1], w[0], 0]], float)


def rot_from_rotvec(w):
    """Rodrigues. Small angles use the series so sin/(th), (1-cos)/th^2 never divide by ~0."""
    w = np.asarray(w, float)
    th = float(np.linalg.norm(w))
    k = skew(w)
    if th < 1e-4:
        a, b = 1.0 - th * th / 6.0, 0.5 - th * th / 24.0
    else:
        a, b = math.sin(th) / th, (1.0 - math.cos(th)) / (th * th)
    return np.eye(3) + a * k + b * (k @ k)


def rotvec_from_rot(r):
    """Inverse of `rot_from_rotvec` (angles in [0, pi]); atan2-based (exact at small angles), axis-from-symmetric-part near pi."""
    v = np.array([r[2, 1] - r[1, 2], r[0, 2] - r[2, 0], r[1, 0] - r[0, 1]]) / 2.0
    s, c = float(np.linalg.norm(v)), (float(np.trace(r)) - 1.0) / 2.0
    th = math.atan2(s, c)
    if th < 1e-4:
        return v * (1.0 + th * th / 6.0)  # th/sin(th) series
    if math.pi - th < 1e-3:
        # sin(th) ~ 0: take the axis from the symmetric part (R + I)/2 = a a^T (largest column), sign from v
        m = (r + np.eye(3)) / 2.0
        a = m[:, int(np.argmax(np.diag(m)))]
        a = a / float(np.linalg.norm(a))
        return a * th if float(a @ v) >= 0.0 else -a * th
    return v * (th / s)


def rot_axis_angle(axis, deg):
    a = np.asarray(axis, float)
    n = float(np.linalg.norm(a))
    if n < 1e-12 or abs(deg) < 1e-15:
        return np.eye(3)
    return rot_from_rotvec(a / n * math.radians(deg))


class Pose:
    def __init__(self, t, r):
        self.t, self.r = np.asarray(t, float), np.asarray(r, float)

    @staticmethod
    def from_json(j):
        return Pose(j["translation"], rot_axis_angle(j["rotation_axis"], j["rotation_angle_degrees"]))

    @staticmethod
    def from_rotvec(t, w):
        return Pose(t, rot_from_rotvec(w))

    def out(self):
        return {"translation": list(self.t), "rotation": [float(x) for x in self.r.reshape(9)]}


def pose_in(t, axis=(0, 0, 1), deg=0.0):
    return {"translation": list(t), "rotation_axis": list(axis), "rotation_angle_degrees": deg}


def pose_delta(new: Pose, old: Pose):
    """[dt, rotvec(R_new R_old^T)] - inverse of apply_delta (the backend's chart)."""
    return np.concatenate([new.t - old.t, rotvec_from_rot(new.r @ old.r.T)])


def apply_delta(base: Pose, d):
    return Pose(base.t + d[:3], rot_from_rotvec(d[3:]) @ base.r)


def screw_exp(base: Pose, d) -> Pose:
    """Integrate the twist d = [v (velocity of the occurrence origin), w (rotation vector)] as a constant
    spatial screw: R' = exp(w) R,  t' = exp(w) t + V(w) (v - w x t)."""
    v, w = np.asarray(d[:3], float), np.asarray(d[3:], float)
    th = float(np.linalg.norm(w))
    k = skew(w)
    if th < 1e-4:
        a = 0.5 - th * th / 24.0
        b = 1.0 / 6.0 - th * th / 120.0
    else:
        a = (1.0 - math.cos(th)) / (th * th)
        b = (th - math.sin(th)) / th**3
    vm = np.eye(3) + a * k + b * (k @ k)
    e = rot_from_rotvec(w)
    return Pose(e @ base.t + vm @ (v - np.cross(w, base.t)), e @ base.r)


# ---- weighted Gram-Schmidt / projection --------------------------------------------------------------
def member_scale(k, lever, grabbed=0, follower=FOLLOWER_WEIGHT):
    """Per-coordinate metric scale s (length 6k): <a,b> = sum (s a)(s b)."""
    out = []
    for m in range(k):
        f = 1.0 if m == grabbed else follower
        out += [f, f, f, f * lever, f * lever, f * lever]
    return np.array(out)


def weighted_gram_schmidt(rows, s):
    out = []
    for row in rows:
        v = np.asarray(row, float).copy()
        n0 = float(np.linalg.norm(s * v))
        if n0 < DROP_ABS:
            continue
        for _ in range(2):  # modified GS with one re-orthogonalisation pass
            for u in out:
                v = v - float((s * v) @ (s * u)) * u
        n = float(np.linalg.norm(s * v))
        if n < DROP_REL * n0:
            continue
        out.append(v / n)
    return out


def project_delta(rows_orthonormal, s, want):
    a = np.zeros_like(want)
    for u in rows_orthonormal:
        a = a + float((s * u) @ (s * want)) * u
    return a


def wish_vector(refs, wanted: Pose, k):
    want = np.zeros(6 * k)
    want[:6] = pose_delta(wanted, refs[0])
    return want


def project(refs, rows, wanted: Pose, lever, integrator="screw", follower=FOLLOWER_WEIGHT):
    k = len(refs)
    s = member_scale(k, lever, 0, follower)
    u = weighted_gram_schmidt(rows, s)
    d = project_delta(u, s, wish_vector(refs, wanted, k))
    if integrator == "screw":
        return [screw_exp(refs[m], d[6 * m : 6 * m + 6]) for m in range(k)]
    return [apply_delta(refs[m], d[6 * m : 6 * m + 6]) for m in range(k)]


# ---- blender ----------------------------------------------------------------------------------------------
class Blender:
    """Displayed-vs-anchor offset per member, in the pose_delta chart, decaying by exp(-1/tau) per frame."""

    def __init__(self, k, tau=TAU_FRAMES):
        self.o = [np.zeros(6) for _ in range(k)]
        self.decay = math.exp(-1.0 / tau)

    def shown(self, projected):
        out = [apply_delta(p, o) for p, o in zip(projected, self.o)]
        self.o = [o * self.decay for o in self.o]
        return out

    def on_anchor(self, old_projected, new_projected):
        """Call on the frame a new anchor is accepted, BEFORE `shown`: continuity with what the old
        model would have shown this frame."""
        old_shown = [apply_delta(p, o) for p, o in zip(old_projected, self.o)]
        self.o = [pose_delta(a, b) for a, b in zip(old_shown, new_projected)]


# ---- scheduler / acceptance / hysteresis ----------------------------------------------------------------
def needs_reanchor(now_ms, anchor_ms, travel, max_step, sigma_gap, in_flight):
    if in_flight:
        return False, "in_flight"
    interval = REANCHOR_MS_NEAR_SINGULAR if (sigma_gap is not None and sigma_gap < SIGMA_GAP_LOW) else REANCHOR_MS
    if now_ms - anchor_ms >= interval:
        return True, "time_near_singular" if interval != REANCHOR_MS else "time"
    if max_step is not None and travel >= max_step:
        return True, "distance"
    return False, "none"


def weighted_dist(a: Pose, b: Pose, lever):
    d = pose_delta(a, b)
    return float(np.linalg.norm(d * np.array([1, 1, 1, lever, lever, lever])))


def accept_anchor(resp, own_projection: Pose | None, lever):
    """`own_projection`: the pose the client's current model projects the SAME wish to (None for the first anchor)."""
    if not resp["converged"]:
        return False, "not_converged", None
    if resp["residual_inf"] > RESIDUAL_TOL:
        return False, "residual", None
    jump = None
    if own_projection is not None:
        jump = weighted_dist(Pose.from_json(resp["grabbed_transform"]), own_projection, lever)
        if jump > JUMP_REJECT_FACTOR * lever:
            return False, "jump", jump
    return True, "ok", jump


class Hysteresis:
    """Rank/dof-change hysteresis. Active model = (rows, dof); candidate = latest anchor with MORE free
    dimensions. dof drops (a new wall) and equal dof are adopted at once; dof rises wait GAIN_FRAMES
    consecutive frames of wish captured only by the new directions."""

    def __init__(self, lever, k=1):
        self.lever, self.s = lever, member_scale(k, lever)
        self.active = None  # (rows_orthonormal, ref poses)
        self.cand = None
        self.count = 0

    def anchor(self, refs, rows):
        u = weighted_gram_schmidt(rows, self.s)
        if self.active is None or len(u) <= len(self.active[0]):
            self.active, self.cand, self.count = (u, refs), None, 0
            return "adopted"
        # more freedom: refresh the reference, keep the old directions, remember the candidate
        self.active = (self.active[0], refs)
        self.cand = u
        return "candidate"

    def frame(self, wanted: Pose):
        rows, refs = self.active
        want = wish_vector(refs, wanted, len(refs))
        gain, event = 0.0, "none"
        if self.cand is not None:
            full = project_delta(self.cand, self.s, want)
            old = project_delta(rows, self.s, want)
            gain = float(np.linalg.norm(self.s * (full - old)))
            self.count = self.count + 1 if gain > GAIN_MIN else 0
            if self.count >= GAIN_FRAMES:
                self.active, self.cand, self.count, event = (self.cand, refs), None, 0, "adopted"
        rows, refs = self.active
        proj = screw_exp(refs[0], project_delta(rows, self.s, want)[:6])
        return proj, gain, event


# ---- output helpers ---------------------------------------------------------------------------------------
def clean(x):
    if isinstance(x, (float, np.floating)):
        v = round(float(x), 10)
        return 0.0 if v == 0 else v
    if isinstance(x, (int, np.integer)) and not isinstance(x, bool):
        return int(x)
    if isinstance(x, np.ndarray):
        return [clean(v) for v in x.tolist()]
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [clean(v) for v in x]
    return x


CASES = []


def case(kind, cid, description, inp, fn):
    inp = clean(inp)
    inp = json.loads(json.dumps(inp))  # compute from exactly what a client will read
    CASES.append({"id": cid, "kind": kind, "description": description, "input": inp, "expected": clean(fn(inp))})


def rows_flat(rows):
    return [[float(x) for x in r] for r in rows]


def project_case(kind, cid, description, refs, rows, wanted, lever, grabbed_note="", extra=None):
    inp = {
        "lever_arm": lever,
        "follower_weight": FOLLOWER_WEIGHT,
        "refs": [pose_in(r.t, *axis_angle_of(r.r)) for r in refs],
        "basis": rows_flat(rows),
        "wanted": pose_in(wanted.t, *axis_angle_of(wanted.r)),
    }
    if extra:
        inp.update(extra)

    def fn(i):
        rf = [Pose.from_json(p) for p in i["refs"]]
        w = Pose.from_json(i["wanted"])
        proj = project(rf, i["basis"], w, i["lever_arm"])
        add = project(rf, i["basis"], w, i["lever_arm"], "additive")
        s = member_scale(len(rf), i["lever_arm"])
        u = weighted_gram_schmidt(i["basis"], s)
        return {
            "members": [p.out() for p in proj],
            "additive_members": [p.out() for p in add],  # informational (VR v0 integrator); NOT normative
            "orthonormal_dim": len(u),
        }

    case(kind, cid, description, inp, fn)


def axis_angle_of(r):
    v = rotvec_from_rot(r)
    th = float(np.linalg.norm(v))
    return ((v / th).tolist() if th > 1e-12 else [0.0, 0.0, 1.0]), math.degrees(th)


def P(t, axis=(0, 0, 1), deg=0.0):
    return Pose(t, rot_axis_angle(axis, deg))


def wish_from(base: Pose, dt=(0, 0, 0), rv=(0, 0, 0)):
    return apply_delta(base, np.array([*dt, *rv], float))


E = np.eye(6)
D = math.radians


# ---- scene builders -----------------------------------------------------------------------------------------
def flat_face_rows():
    """Face mate on the world XY plane: free tx, ty, spin about the plane normal."""
    return [E[0], E[1], E[5]]


def tilted_face_rows(deg):
    n = np.array([0.0, math.sin(D(deg)), math.cos(D(deg))])
    e2 = np.array([0.0, math.cos(D(deg)), -math.sin(D(deg))])
    return [np.array([1.0, 0, 0, 0, 0, 0]), np.array([*e2, 0, 0, 0]), np.array([0, 0, 0, *n])]


CX = 15.0  # offset of the pin axis from the pin's origin (the prototype's scene)


def conc_pose(theta_deg, z):
    th = D(theta_deg)
    return Pose([-CX * math.cos(th), -CX * math.sin(th), z], rot_from_rotvec([0, 0, th]))


def conc_rows(p: Pose):
    """Offset-axis concentric mate at pose p: slide along z, spin about the world z axis (origin velocity w x t)."""
    return [E[2], np.array([-p.t[1], p.t[0], 0.0, 0, 0, 1.0])]


def conc_violation(p: Pose):
    q = p.r @ np.array([CX, 0, 0.0]) + p.t
    return float(np.hypot(q[0], q[1]))


ANGLE_DEG = 40.0


def angle_pose(spin_z_deg, base_tilt_deg=ANGLE_DEG, t=(3.0, -4.0, 12.0)):
    r = rot_from_rotvec([0, 0, D(spin_z_deg)]) @ rot_from_rotvec([0, D(base_tilt_deg), 0])
    return Pose(t, r)


def angle_rows(p: Pose):
    d = p.r @ np.array([0.0, 0, 1.0])
    return [E[0], E[1], E[2], np.array([0, 0, 0, 0, 0, 1.0]), np.array([0, 0, 0, *d])]


def angle_err_deg(p: Pose):
    d = p.r @ np.array([0.0, 0, 1.0])
    return math.degrees(math.acos(max(-1, min(1, d[2])))) - ANGLE_DEG


BCD_T = {"B": (20.0, 20.0, 10.0), "C": (28.0, 20.0, 10.0), "D": (20.0, 12.0, 10.0)}


def bcd_rows(order, lever):
    """Analytic group basis for plate + B(+x)C, D(-y of B): x of B&C, x of D, y of B&D, y of C, rigid spin about z
    through the world origin. Members in `order`; rows Gram-Schmidt'ed in the EQUAL metric like the backend's."""
    def row(fn):
        v = np.zeros(6 * len(order))
        for m, name in enumerate(order):
            v[6 * m : 6 * m + 6] = fn(name)
        return v

    gens = [
        row(lambda n: [1, 0, 0, 0, 0, 0] if n in "BC" else [0] * 6),
        row(lambda n: [1, 0, 0, 0, 0, 0] if n == "D" else [0] * 6),
        row(lambda n: [0, 1, 0, 0, 0, 0] if n in "BD" else [0] * 6),
        row(lambda n: [0, 1, 0, 0, 0, 0] if n == "C" else [0] * 6),
        row(lambda n: [-BCD_T[n][1], BCD_T[n][0], 0, 0, 0, 1]),
    ]
    return weighted_gram_schmidt(gens, member_scale(len(order), lever, 0, 1.0))


# ---- the cases ------------------------------------------------------------------------------------------------
def build():
    L = 10.0

    # 1. weighted Gram-Schmidt --------------------------------------------------------------------------------
    def gs_case(cid, description, rows, lever, k=1, follower=FOLLOWER_WEIGHT):
        inp = {"lever_arm": lever, "members": k, "follower_weight": follower, "rows": rows_flat(rows)}

        def fn(i):
            s = member_scale(i["members"], i["lever_arm"], 0, i["follower_weight"])
            u = weighted_gram_schmidt(i["rows"], s)
            return {"rows": rows_flat(u), "kept": len(u)}

        case("gram_schmidt", cid, description, inp, fn)

    gs_case("gs-axes-L10", "Coordinate rows: rotation rows are scaled by 1/L", [E[0], E[1], E[5]], L)
    gs_case("gs-dependent-dropped", "Row 3 = row 1 + 2*row 2 is dropped", [E[0] + 0, E[1], E[0] + 2 * E[1], E[5]], L)
    gs_case("gs-mixed-rows-L100", "Mixed translation/rotation rows, VR's old constant L = 100",
            [np.array([1, 2, 0, 0.5, 0, 1]), np.array([0, 1, 1, 0, 0.1, 0]), np.array([1, 0, 1, 0, 0, 0.02])], 100.0)
    gs_case("gs-zero-row", "An all-zero row is dropped without breaking the rest", [np.zeros(6), E[2], E[3]], L)
    gs_case("gs-followers", "Two members: follower coordinates count 1e-4 in the metric",
            [np.array([1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0]), np.array([0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0]),
             np.array([0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0])], L, k=2)
    gs_case("gs-near-dependent", "Row 2 differs from row 1 by 1e-9 (below the 1e-6 relative drop threshold): dropped",
            [np.array([1, 1, 0, 0, 0, 0]), np.array([1, 1 + 1e-9, 0, 0, 0, 0]), E[2]], L)

    # 2. flat face -----------------------------------------------------------------------------------------------
    base = P((10.0, 20.0, 5.0), (0, 0, 1), 30.0)
    rows = flat_face_rows()
    flat = [
        ("flat-inplane", "In-plane drag passes through", wish_from(base, (7.0, -3.0, 0))),
        ("flat-offplane-dropped", "Off-plane translation is dropped (blocked)", wish_from(base, (0, 0, 9.0))),
        ("flat-tilt-dropped", "Tilt about x is dropped", wish_from(base, (0, 0, 0), (D(20), 0, 0))),
        ("flat-spin-45", "Spin about the face normal passes; origin stays put", wish_from(base, (0, 0, 0), (0, 0, D(45)))),
        ("flat-combined", "In-plane + spin + off-plane + tilt: only the free part survives",
         wish_from(base, (5.0, 6.0, 4.0), (D(10), D(-8), D(25)))),
        ("flat-spin-170", "Large spin (170 deg) about the normal: screw with v = 0 keeps t", wish_from(base, (0, 0, 0), (0, 0, D(170)))),
    ]
    for cid, desc, w in flat:
        project_case("project", cid, desc, [base], rows, w, L)
    project_case("project", "flat-inplane-L100", "Same in-plane+spin wish with L = 100: less spin per unit of pointer",
                 [base], rows, wish_from(base, (7.0, -3.0, 0), (0, 0, D(45))), 100.0)
    tb = P((0.0, 8.0, 3.0), (1, 0, 0), 0.0)
    project_case("project", "tilted-face", "Face mate on a plane tilted 25 deg about x",
                 [tb], tilted_face_rows(25.0), wish_from(tb, (4.0, 5.0, 6.0), (D(5), D(4), D(30))), L)

    # 3. offset-axis concentric (curved mate) -------------------------------------------------------------------
    c0 = conc_pose(0.0, 30.0)
    crow = conc_rows(c0)
    conc = [
        ("conc-spin-90", "90 deg spin wish about the pin's own origin: screw stays on the manifold", wish_from(c0, (0, 0, 0), (0, 0, D(90))), L),
        ("conc-spin-90-L100", "Same wish with L = 100 (VR's old constant): almost no swing", wish_from(c0, (0, 0, 0), (0, 0, D(90))), 100.0),
        ("conc-lift-15", "Slide along the axis", wish_from(c0, (0, 0, 15.0), (0, 0, 0)), L),
        ("conc-lift-and-spin", "15 mm lift + 90 deg spin", wish_from(c0, (0, 0, 15.0), (0, 0, D(90))), L),
        ("conc-radial-blocked", "Translation across the axis is dropped or converted to swing", wish_from(c0, (6.0, 0, 0), (0, 0, 0)), L),
        ("conc-tilt-dropped", "Tilt of the axis is dropped", wish_from(c0, (0, 0, 0), (D(12), D(9), 0)), L),
        ("conc-spin-neg-60-from-137", "Start at theta = 137 deg, spin -60 deg",
         None, L),
        ("conc-tiny-twist", "1e-7 rad twist: small-angle series branch of the screw", wish_from(c0, (0, 1e-7, 0), (0, 0, 1e-7)), L),
    ]
    for cid, desc, w, lever in conc:
        if cid == "conc-spin-neg-60-from-137":
            c1 = conc_pose(137.0, 30.0)
            project_case("project", cid, desc, [c1], conc_rows(c1), wish_from(c1, (0, 0, 0), (0, 0, D(-60))), lever,
                         extra={"violation_hint": "informational"})
            continue
        project_case("project", cid, desc, [c0], crow, w, lever)

    # 4. angle cone (non-group manifold) -------------------------------------------------------------------------
    a0 = angle_pose(0.0)
    arow = angle_rows(a0)
    ang = [
        ("angle-spin-about-z-50", "Rotation about the world axis: exact orbit of the cone", wish_from(a0, (0, 0, 0), (0, 0, D(50)))),
        ("angle-tilt-off-cone", "Tilt that leaves the cone: only the tangent part survives (first-order)", wish_from(a0, (0, 0, 0), (0, D(35), 0))),
        ("angle-combined", "Spin about d + about z: 2nd-order error remains, re-anchor needed", wish_from(a0, (0, 0, 0), (D(20), D(35), D(50)))),
        ("angle-translate", "Translation is free", wish_from(a0, (15.0, -10.0, 5.0), (0, 0, 0))),
    ]
    for cid, desc, w in ang:
        project_case("project", cid, desc, [a0], arow, w, L)
    a1 = angle_pose(150.0, 40.0)
    project_case("project", "angle-from-other-spin", "Same combined wish from a start rotated 150 deg about z",
                 [a1], angle_rows(a1), wish_from(a1, (0, 0, 0), (D(20), D(35), D(50))), L)

    # 5. group B/C/D (followers) -------------------------------------------------------------------------------
    def bcd(cid, desc, order, wish_dt=(0, 0, 0), wish_rv=(0, 0, 0)):
        refs = [P(BCD_T[n]) for n in order]
        rws = bcd_rows(order, L)
        project_case("project", cid, desc, refs, rws, wish_from(refs[0], wish_dt, wish_rv), L, extra={"members": list(order)})

    bcd("bcd-B-plus-6y", "Drag B +6 y: B and D move 6, C stays (backend: exact)", "BCD", (0, 6.0, 0))
    bcd("bcd-B-plus-4x", "Drag B +4 x: C follows 4, D stays", "BCD", (4.0, 0, 0))
    bcd("bcd-B-lift-blocked", "B off the plate is dropped", "BCD", (0, 0, 5.0))
    bcd("bcd-B-spin-10", "Spin B 10 deg about its origin: group answers with the rigid mode + slides", "BCD", (0, 0, 0), (0, 0, D(10)))
    bcd("bcd-D-plus-6x", "Grab D (basis order D,B,C): +6 x moves D alone", "DBC", (6.0, 0, 0))
    bcd("bcd-D-plus-6y", "Grab D: +6 y drags B along, C stays", "DBC", (0, 6.0, 0))
    bcd("bcd-C-plus-5x", "Grab C (order C,B,D): +5 x drags B, D stays", "CBD", (5.0, 0, 0))
    bcd("bcd-C-plus-5y", "Grab C: +5 y moves C alone", "CBD", (0, 5.0, 0))

    # 6. rank change / hysteresis ---------------------------------------------------------------------------------
    def hyst_case(cid, description, frames):
        """frames: list of {"anchor": {"rows":..., "ref": pose} | None, "wish": pose}"""
        inp = {"lever_arm": L, "gain_min": GAIN_MIN, "gain_frames": GAIN_FRAMES, "frames": frames}

        def fn(i):
            h = Hysteresis(i["lever_arm"])
            out = []
            for f in i["frames"]:
                ev = None
                if f["anchor"] is not None:
                    ev = h.anchor([Pose.from_json(f["anchor"]["ref"])], f["anchor"]["rows"])
                proj, gain, event = h.frame(Pose.from_json(f["wish"]))
                out.append({"anchor_event": ev, "gain": gain, "event": event, "count": h.count, "dim": len(h.active[0]),
                            "projected": proj.out()})
            return {"frames": out}

        case("hysteresis", cid, description, inp, fn)

    r3 = flat_face_rows()
    r4 = flat_face_rows() + [E[2]]  # mate released: z opens up
    r2 = [E[0], E[5]]               # a wall appears in y
    rf = lambda p: pose_in(p.t, *axis_angle_of(p.r))
    ref0 = P((0, 0, 0))

    def wf(dt):  # wish `dt` from the origin pose
        return rf(wish_from(ref0, dt))

    A = lambda rows: {"rows": rows_flat(rows), "ref": rf(ref0)}
    hyst_case("hyst-rise-adopted-after-3-frames", "dof 3 -> 4: z opens; wish keeps pushing +z, adopted on the 3rd frame",
              [{"anchor": A(r3), "wish": wf((1, 0, 0))}, {"anchor": A(r4), "wish": wf((1, 0, 1.0))},
               {"anchor": None, "wish": wf((1, 0, 1.2))}, {"anchor": None, "wish": wf((1, 0, 1.4))},
               {"anchor": None, "wish": wf((1, 0, 1.6))}])
    hyst_case("hyst-rise-flicker-resets", "dof 3 -> 4 but the wish only touches z every other frame: never adopted",
              [{"anchor": A(r3), "wish": wf((0, 0, 0))}, {"anchor": A(r4), "wish": wf((1, 0, 1.0))},
               {"anchor": None, "wish": wf((2, 0, 0.0))}, {"anchor": None, "wish": wf((3, 0, 1.0))},
               {"anchor": None, "wish": wf((4, 0, 0.0))}, {"anchor": None, "wish": wf((5, 0, 1.0))}])
    hyst_case("hyst-drop-immediate", "dof 3 -> 2: the new wall is adopted at once, motion into y is dropped",
              [{"anchor": A(r3), "wish": wf((0, 0, 0))}, {"anchor": A(r2), "wish": wf((2, 3.0, 0))},
               {"anchor": None, "wish": wf((4, 6.0, 0))}])
    hyst_case("hyst-equal-dof-refresh", "Equal dof: an anchor with a fresh ref replaces the model immediately",
              [{"anchor": A(r3), "wish": wf((1, 1, 0))},
               {"anchor": {"rows": rows_flat(r3), "ref": rf(P((1.0, 1.0, 0.0)))}, "wish": wf((2, 2, 0))}])

    # 7. blend ------------------------------------------------------------------------------------------------------
    def blend_case(cid, description, offset, projected_frames):
        inp = {"tau_frames": TAU_FRAMES, "offsets": [list(map(float, o)) for o in offset],
               "projected": [[rf(p) for p in fr] for fr in projected_frames]}

        def fn(i):
            b = Blender(len(i["offsets"]), i["tau_frames"])
            b.o = [np.array(o) for o in i["offsets"]]
            return {"shown": [[p.out() for p in b.shown([Pose.from_json(x) for x in fr])] for fr in i["projected"]]}

        case("blend", cid, description, inp, fn)

    still = [[P((5, 5, 5), (0, 0, 1), 20.0)]] * 6
    blend_case("blend-translation-offset", "A 1 mm offset decays by e^-0.5 per frame on a still projection", [[1.0, 0, 0, 0, 0, 0]], still)
    blend_case("blend-rotation-offset", "A 10 deg rotation offset decays the same way", [[0, 0, 0, 0, 0, D(10)]], still)
    moving = [[P((5 + k, 5, 5), (0, 0, 1), 20.0 + 2 * k)] for k in range(6)]
    blend_case("blend-moving-projection", "The offset rides on a moving projection", [[0, 2.0, -1.0, 0.05, 0, 0.1]], moving)
    blend_case("blend-two-members", "Followers blend independently",
               [[1.0, 0, 0, 0, 0, 0], [0, 0, -0.5, 0, D(3), 0]],
               [[P((5 + k, 5, 5)), P((15, 5 - k, 5))] for k in range(5)])

    def blend_anchor_case(cid, description):
        """Old model then a new anchor on frame 3: continuity of `shown`, then decay onto the new projection."""
        old = [P((0.0 + k, 0.0, 0.0), (0, 0, 1), 0.0 + 3 * k) for k in range(8)]
        new = [P((0.0 + k, 1.5, 0.0), (0, 0, 1), 4.0 + 3 * k) for k in range(8)]
        inp = {"tau_frames": TAU_FRAMES, "anchor_frame": 3, "old_projected": [rf(p) for p in old], "new_projected": [rf(p) for p in new]}

        def fn(i):
            b = Blender(1, i["tau_frames"])
            shown = []
            for f in range(len(i["old_projected"])):
                o, n = Pose.from_json(i["old_projected"][f]), Pose.from_json(i["new_projected"][f])
                if f < i["anchor_frame"]:
                    shown.append(b.shown([o])[0].out())
                else:
                    if f == i["anchor_frame"]:
                        b.on_anchor([o], [n])
                    shown.append(b.shown([n])[0].out())
            return {"shown": shown}

        case("blend_anchor", cid, description, inp, fn)

    blend_anchor_case("blend-anchor-continuity", "Anchor accepted on frame 3: shown is continuous, then converges to the new projection")

    # 8. re-anchor scheduler ----------------------------------------------------------------------------------------
    def sched(cid, description, now, anchor, travel, max_step, gap, in_flight):
        inp = {"now_ms": now, "anchor_ms": anchor, "travel": travel, "max_step": max_step, "sigma_gap": gap, "in_flight": in_flight}
        case("scheduler", cid, description, inp, lambda i: dict(zip(("reanchor", "reason"), needs_reanchor(
            i["now_ms"], i["anchor_ms"], i["travel"], i["max_step"], i["sigma_gap"], i["in_flight"]))))

    sched("sched-early", "50 ms, small travel: nothing", 1050.0, 1000.0, 1.0, 5.0, 1e6, False)
    sched("sched-time-cap", "150 ms since anchor", 1150.0, 1000.0, 1.0, 5.0, 1e6, False)
    sched("sched-distance", "Travel reaches max_step before the cap", 1060.0, 1000.0, 5.0, 5.0, 1e6, False)
    sched("sched-null-max-step", "max_step null (flat): only the time cap applies", 1100.0, 1000.0, 500.0, None, 1e6, False)
    sched("sched-in-flight", "Due but a request is in flight: wait", 1400.0, 1000.0, 50.0, 5.0, 1e6, True)
    sched("sched-near-singular-halved", "sigma_gap < 100 halves the interval: 80 ms is due", 1080.0, 1000.0, 1.0, None, 40.0, False)
    sched("sched-gap-null-rank0", "sigma_gap null (rank 0): normal interval", 1080.0, 1000.0, 1.0, None, None, False)
    sched("sched-just-under", "149.9 ms: not yet", 1149.9, 1000.0, 0.0, None, 1e6, False)

    # 9. anchor acceptance --------------------------------------------------------------------------------------------
    own = P((10, 10, 0), (0, 0, 1), 20.0)

    def acc(cid, description, converged, residual, grabbed, has_own=True):
        inp = {"lever_arm": L, "converged": converged, "residual_inf": residual, "grabbed_transform": rf(grabbed),
               "own_projection": rf(own) if has_own else None}

        def fn(i):
            ok, why, jump = accept_anchor({"converged": i["converged"], "residual_inf": i["residual_inf"],
                                           "grabbed_transform": i["grabbed_transform"]},
                                          Pose.from_json(i["own_projection"]) if i["own_projection"] else None, i["lever_arm"])
            return {"accept": ok, "reason": why, "client_jump": jump}

        case("accept_anchor", cid, description, inp, fn)

    acc("acc-ok-small-jump", "Anchor 1.5 mm and 4 deg from the client's own projection", True, 1e-10,
        P((11.5, 10, 0), (0, 0, 1), 24.0))
    acc("acc-ok-swing-jump", "Honest curvature correction ~0.5 L (the off-axis swing scene): accepted", True, 1e-9,
        P((10, 10, 0), (0, 0, 1), 20.0 + math.degrees(4.0 / L)))
    acc("acc-not-converged", "converged:false is never accepted", False, 5.0, own)
    acc("acc-residual", "residual_inf above 1e-6", True, 3e-6, own)
    acc("acc-jump-flip", "Anchor half a turn away (a branch flip): rejected", True, 1e-10, P((10, 10, 0), (0, 0, 1), 200.0))
    acc("acc-jump-far", "Anchor 12 mm away with L = 10: rejected", True, 1e-10, P((22, 10, 0), (0, 0, 1), 20.0))
    acc("acc-first-anchor", "No model yet: no jump test", True, 1e-10, P((99, 99, 99)), has_own=False)
    acc("acc-boundary-ok", "Jump just under 1.0*L", True, 1e-10, P((10, 10, 9.99), (0, 0, 1), 20.0))

    # 10. swing sequence (offset-axis concentric, 90 deg / 15 mm over 63 frames, re-anchor every 9) ------------------
    frames, every = 63, 9
    base = conc_pose(0.0, 30.0)
    hand = [wish_from(base, (0, 0, 15.0 * f / frames), (0, 0, D(90) * f / frames)) for f in range(frames + 1)]

    def anchor_at(wish: Pose, lever=L) -> Pose:
        """Analytic stand-in for the backend retraction: the manifold point nearest to the wish in the metric
        diag(1,1,1,L,L,L) (z is free and orthogonal; theta by ternary search on [0, wish spin], deterministic)."""
        phi = rotvec_from_rot(wish.r)[2]

        def cost(th):
            return (float(np.hypot(-CX * math.cos(th) - wish.t[0], -CX * math.sin(th) - wish.t[1])) ** 2
                    + (lever * (th - phi)) ** 2)

        lo, hi = min(0.0, phi), max(0.0, phi)
        for _ in range(200):
            m1, m2 = lo + (hi - lo) / 3.0, hi - (hi - lo) / 3.0
            if cost(m1) < cost(m2):
                hi = m2
            else:
                lo = m1
        return conc_pose(math.degrees((lo + hi) / 2.0), wish.t[2])

    # Anchor spin angles (deg) the REAL backend returned for this hand path (solve_group @ main 76f7699 + S4, L = 10,
    # the persisted previous anchor as the stored pose, one anchor per 9 frames, frame 0 = the settled pose).
    # Captured by running backend/tests (scene `_offset_pin_scene`), NOT recomputed here. They overshoot the true
    # nearest point (analytic anchors below: 3.96, 11.9, 28.5 deg at frames 9, 27, 63; backend: 4.08, 14.9, 51.0).
    backend_theta = [0.0, 4.078784558, 8.858851956, 14.883502354, 22.451526709, 31.056886352, 40.043343104, 51.032455339]
    inp = {"lever_arm": L, "frames": frames, "reanchor_every": every, "tau_frames": TAU_FRAMES,
           "hand": [rf(h) for h in hand], "backend_anchor_theta_deg": backend_theta}

    def run_sequence(i, anchor_of):
        hnd = [Pose.from_json(h) for h in i["hand"]]
        lever = i["lever_arm"]
        out = {"screw": [], "screw_blended": [], "additive": []}
        b = Blender(1, i["tau_frames"])
        old_ref = old_rows = None
        anchors = []
        viol_s, viol_a = [], []
        for f, w in enumerate(hnd):
            if f % i["reanchor_every"] == 0:
                new_ref = anchor_of(f, w)
                new_rows = conc_rows(new_ref)
                if old_ref is not None:  # continuity against the old model's projection on this frame
                    b.on_anchor(project([old_ref], old_rows, w, lever), project([new_ref], new_rows, w, lever))
                old_ref, old_rows = new_ref, new_rows
                anchors.append(new_ref)
            s = project([old_ref], old_rows, w, lever, "screw")
            a = project([old_ref], old_rows, w, lever, "additive")
            out["screw"].append(s[0].out())
            out["additive"].append(a[0].out())
            out["screw_blended"].append(b.shown(s)[0].out())
            viol_s.append(conc_violation(s[0]))
            viol_a.append(conc_violation(a[0]))

        def steps(seq):
            ps = [Pose(np.array(x["translation"]), np.array(x["rotation"]).reshape(3, 3)) for x in seq]
            return max(weighted_dist(ps[k], ps[k - 1], lever) for k in range(1, len(ps)))

        n = i["reanchor_every"]
        out["summary"] = {
            "max_anchor_step_per_interval": max(weighted_dist(anchors[k], anchors[k - 1], lever) for k in range(1, len(anchors))),
            "max_hand_step_per_interval": max(weighted_dist(hnd[k], hnd[k - n], lever) for k in range(n, len(hnd))),
            "max_frame_step_hand": max(weighted_dist(hnd[k], hnd[k - 1], lever) for k in range(1, len(hnd))),
            "max_frame_step_screw": steps(out["screw"]),
            "max_frame_step_screw_blended": steps(out["screw_blended"]),
            "max_frame_step_additive": steps(out["additive"]),
            "max_violation_screw_mm": max(viol_s),
            "max_violation_additive_mm": max(viol_a),
        }
        return out

    def nearest_anchor(i):
        return lambda f, w: (conc_pose(0.0, 30.0) if f == 0 else anchor_at(w, i["lever_arm"]))

    def backend_anchor(i):
        return lambda f, w: conc_pose(i["backend_anchor_theta_deg"][f // i["reanchor_every"]], w.t[2])

    def swing(i):
        return {"nearest_anchors": run_sequence(i, nearest_anchor(i)), "backend_anchors": run_sequence(i, backend_anchor(i))}

    case("swing_sequence", "swing-offset-axis-90deg",
         "63-frame hand path (15 mm lift, 90 deg spin) on the off-axis concentric mate, anchors every 9 frames. "
         "`nearest_anchors`: analytic true-nearest anchors; `backend_anchors`: the anchors the real S2 solver returned "
         "(they overshoot). Screw integration stays on the manifold; blending shrinks the anchor pop; the additive "
         "integrator (v0) leaves the manifold", inp, swing)


def self_check():
    """Properties the vectors rely on (the prototype's `_skew` had a wrong third row, which made its screw translation
    wrong for any rotation with an x or y component; these would have caught it)."""
    rng = np.random.default_rng(12345)  # fixed seed: only used to assert, never to produce vector data
    for _ in range(50):
        w = rng.normal(size=3)
        w = w / np.linalg.norm(w) * rng.choice([1e-7, 1e-5, 0.1, 1.0, 3.0])  # angles < pi
        r = rot_from_rotvec(w)
        assert np.abs(r @ r.T - np.eye(3)).max() < 1e-12 and abs(np.linalg.det(r) - 1) < 1e-12
        assert np.abs(rotvec_from_rot(r) - w).max() < 1e-9 * max(1.0, np.linalg.norm(w))
        axis, c = rng.normal(size=3), rng.normal(size=3) * 20
        axis /= np.linalg.norm(axis)
        theta = float(rng.uniform(-2.5, 2.5))
        base = Pose(rng.normal(size=3) * 20, rot_from_rotvec(rng.normal(size=3)))
        e = rot_from_rotvec(theta * axis)
        exact = Pose(e @ (base.t - c) + c, e @ base.r)  # rotate the body rigidly about the line (c, axis)
        got = screw_exp(base, np.concatenate([np.cross(theta * axis, base.t - c), theta * axis]))
        assert np.abs(got.t - exact.t).max() < 1e-9 and np.abs(got.r - exact.r).max() < 1e-12, "screw_exp is not exact"


def main():
    self_check()
    build()
    doc = {
        "version": 1,
        "tolerance": 1e-9,
        "generator": "tools/motion_vectors/generate.py",
        "constants": {
            "follower_weight": FOLLOWER_WEIGHT, "gram_schmidt_drop_relative": DROP_REL, "gram_schmidt_drop_absolute": DROP_ABS,
            "tau_frames": TAU_FRAMES, "residual_tol": RESIDUAL_TOL, "jump_reject_factor": JUMP_REJECT_FACTOR,
            "reanchor_ms": REANCHOR_MS, "reanchor_ms_near_singular": REANCHOR_MS_NEAR_SINGULAR, "sigma_gap_low": SIGMA_GAP_LOW,
            "gain_min": GAIN_MIN, "gain_frames": GAIN_FRAMES,
        },
        "conventions": {
            "pose_in": "translation + rotation_axis (normalised on read) + rotation_angle_degrees (the contract's RigidTransform)",
            "pose_out": "translation + rotation (3x3 row-major, 9 floats): compare matrices, never axis-angle",
            "twist": "[vx vy vz wx wy wz]: velocity of the occurrence ORIGIN and rotation vector (rad); rows/columns per member, grabbed first",
            "metric": "<a,b> = sum (s_i a_i)(s_i b_i), s = [1,1,1,L,L,L] per member, times follower_weight for non-grabbed members",
        },
        "cases": CASES,
    }
    text = json.dumps(clean(doc), indent=1) + "\n"
    if "--check" in sys.argv:
        sys.exit(0 if OUT.exists() and OUT.read_text() == text else 1)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    kinds = {}
    for c in CASES:
        kinds[c["kind"]] = kinds.get(c["kind"], 0) + 1
    print(f"wrote {OUT.relative_to(REPO)}: {len(CASES)} cases {kinds}")


if __name__ == "__main__":
    main()
