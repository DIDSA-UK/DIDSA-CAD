"""Rigid-transform math + a faithful numpy transcription of DIDSA-VR's project_motion()/weighted_basis()
(scripts/mates_tool.gd @ origin/ccr-5fcefc91-t2tc6f).  Scratch code, not product code."""
import numpy as np, math

def R_from_axis_angle(axis, deg):
    a = np.asarray(axis, float); n = np.linalg.norm(a)
    if n < 1e-12 or abs(deg) < 1e-12: return np.eye(3)
    a = a / n; th = math.radians(deg)
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + math.sin(th) * K + (1 - math.cos(th)) * K @ K

def rotvec_from_R(R):
    c = (np.trace(R) - 1) / 2; c = max(-1.0, min(1.0, c)); th = math.acos(c)
    if th < 1e-12: return np.zeros(3)
    if abs(th - math.pi) < 1e-6:
        w, v = np.linalg.eigh((R + R.T) / 2); ax = v[:, np.argmax(w)]; return ax * th
    ax = np.array([R[2, 1] - R[1, 2], R[0, 2] - R[2, 0], R[1, 0] - R[0, 1]]) / (2 * math.sin(th))
    return ax * th

def R_from_rotvec(v):
    v = np.asarray(v, float); th = np.linalg.norm(v)
    if th < 1e-14: return np.eye(3)
    return R_from_axis_angle(v / th, math.degrees(th))

class Pose:
    def __init__(self, t, R): self.t = np.asarray(t, float); self.R = np.asarray(R, float)
    @staticmethod
    def from_json(j): return Pose(j["translation"], R_from_axis_angle(j["rotation_axis"], j["rotation_angle_degrees"]))
    def to_json(self):
        rv = rotvec_from_R(self.R); th = np.linalg.norm(rv)
        ax = (rv / th) if th > 1e-12 else np.array([0, 0, 1.0])
        return {"translation": [float(x) for x in self.t], "rotation_axis": [float(x) for x in ax], "rotation_angle_degrees": math.degrees(th)}
    def apply(self, p): return self.R @ np.asarray(p, float) + self.t

def pose_dist(a, b):
    """(translation mm, rotation deg) between two poses."""
    return float(np.linalg.norm(a.t - b.t)), math.degrees(np.linalg.norm(rotvec_from_R(a.R @ b.R.T)))

def apply_twist(pose, tw, s=1.0):
    d = np.asarray(tw[:3]) * s; rv = np.asarray(tw[3:]) * s
    return Pose(pose.t + d, R_from_rotvec(rv) @ pose.R)

L = 100.0   # CONSTRAINT_LENGTH_MM

def weighted_basis(free_twists, L=L):
    out = []
    for tw in free_twists:
        v = np.array([tw[0], tw[1], tw[2], tw[3] * L, tw[4] * L, tw[5] * L], float)
        for u in out: v = v - (v @ u) * u
        n = np.linalg.norm(v)
        if n < 1e-9: continue
        out.append(v / n)
    return out

def project_motion(ref, basis, desired, L=L):
    rv = rotvec_from_R(desired.R @ ref.R.T)
    wanted = np.concatenate([desired.t - ref.t, rv * L])
    allowed = np.zeros(6)
    for u in basis: allowed += (u @ wanted) * u
    return Pose(ref.t + allowed[:3], R_from_rotvec(allowed[3:] / L) @ ref.R)

def _skew(w): return np.array([[0, -w[2], w[1]], [w[2], 0, -w[0]], [-w[0], w[1], 0]])

def _V(w):
    th = np.linalg.norm(w)
    K = _skew(w)
    if th < 1e-9: return np.eye(3) + 0.5 * K
    return np.eye(3) + (1 - math.cos(th)) / th**2 * K + (th - math.sin(th)) / th**3 * K @ K

def project_motion_screw(ref, basis, desired, L=L):
    """Same projection as project_motion, but the allowed twist (v = velocity of the occurrence origin, w = rotation vector)
    is integrated as a constant SPATIAL screw (exact exponential map) instead of 'add v, compose exp(w)'. Exact for
    screw-type freedoms (concentric, hinge, slider+spin), still 2nd-order-wrong on non-group manifolds (cones)."""
    rv = rotvec_from_R(desired.R @ ref.R.T)
    wanted = np.concatenate([desired.t - ref.t, rv * L])
    allowed = np.zeros(6)
    for u in basis: allowed += (u @ wanted) * u
    v = allowed[:3]; w = allowed[3:] / L
    vs = v - np.cross(w, ref.t)          # spatial (world-frame) translational part of the twist
    Rn = R_from_rotvec(w) @ ref.R
    tn = R_from_rotvec(w) @ ref.t + _V(w) @ vs
    return Pose(tn, Rn)
