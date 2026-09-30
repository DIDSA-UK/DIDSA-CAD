"""E: does a WEIGHTED retraction on the backend (same metric as the client's projector) remove the re-anchor pop?
Toy backend for the offset-axis concentric mate using my own residual function (the real backend has one too:
assembly_solver._mate_residual_vector) + numerical Jacobian; Gauss-Newton in a (t, w) chart weighted by L."""
from a_strategies2 import *
import geo

def resid_conc(P):
    p = P.apply((15.0, 0, 0)); d = P.R @ np.array([0, 0, 1.0]); return np.array([p[0], p[1], d[0], d[1]])

def jac(P, resid, h=1e-6):
    J = np.zeros((len(resid(P)), 6))
    for i in range(6):
        e = np.zeros(6); e[i] = h
        Pp = geo.Pose(P.t + e[:3], geo.R_from_rotvec(e[3:]) @ P.R); Pm = geo.Pose(P.t - e[:3], geo.R_from_rotvec(-e[3:]) @ P.R)
        J[:, i] = (resid(Pp) - resid(Pm)) / (2 * h)
    return J

def weighted_retraction(P0, resid, L, iters=30):
    """nearest point of {resid=0} to P0 in the metric diag(1,1,1,L,L,L) (t in mm, rotation-vector in rad*L)"""
    W = np.diag([1, 1, 1, L, L, L]); Winv2 = np.linalg.inv(W @ W)
    P = P0
    for _ in range(iters):
        r = resid(P); 
        if np.linalg.norm(r) < 1e-10: break
        J = jac(P, resid)
        # minimum weighted-norm step that zeroes the residual: dx = -Winv2 J^T (J Winv2 J^T)^+ r   (pseudo-inverse: J can be rank deficient)
        A = J @ Winv2 @ J.T; dx = -Winv2 @ J.T @ (np.linalg.pinv(A, rcond=1e-9) @ r)
        P = geo.Pose(P.t + dx[:3], geo.R_from_rotvec(dx[3:]) @ P.R)
    return P

def free_basis(P, resid):
    J = jac(P, resid); U, S, Vt = np.linalg.svd(J); rank = int(np.sum(S > 1e-6)); return [list(v) for v in Vt[rank:]]

root = scenario_concentric_offset(); solve(root, "occ-driven"); st = Pose.from_json(occs(root)[0]["transform"])
path = make_path(st, (0, 0, 15), (0, 0, math.radians(90)), {"t": (4, 3, 0), "rv": (math.radians(4), math.radians(3), 0)})
print("offset-axis concentric, 90deg spin wish; re-anchor every 9 frames (~150 ms) with a WEIGHTED backend retraction (toy backend)")
for Lw in (10.0, 100.0):
    for label, fn in (("additive", geo.project_motion), ("screw   ", geo.project_motion_screw)):
        vv = []; prev = None; steps_ = []
        for f in range(N):
            if f % 9 == 0:
                ref = weighted_retraction(path[f], resid_conc, Lw); basis = geo.weighted_basis(free_basis(ref, resid_conc), L=Lw)
            d = fn(ref, basis, path[f], L=Lw); vv.append(viol_conc(d))
            if prev is not None: steps_.append(pose_dist(d, prev)[0])
            prev = d
        print("  L=%4.0f %s  violation mean %.3fmm max %.3fmm | max frame step %.2fmm (wish step max %.2f)" % (Lw, label, np.mean([a for a, b in vv]), max(a for a, b in vv), max(steps_), max(pose_dist(path[i], path[i - 1])[0] for i in range(1, N))))
