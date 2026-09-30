"""E (multi-body): drag B up its peg when C sits on B.  Single-occurrence solve freezes C, so B is blocked (measured on the real backend in
a_chain.py: dof 1, no slide).  Toy check that a GROUP motion model (variables = poses of B and C, stacked Jacobian, weighted projection with the
grabbed body weighted 1 and followers ~0) lets B slide and C ride along.  Residuals written by hand (toy), not the real backend's."""
import numpy as np, math, geo
from geo import Pose, R_from_rotvec

ez = np.array([0, 0, 1.0])
def resid(B, C):
    rB = np.array([B.t[0], B.t[1], (B.R @ ez)[0], (B.R @ ez)[1]])                      # B concentric with the world-z peg
    pB = B.apply((0, 0, 10.0)); nB = B.R @ ez                                            # B's top plane
    pC = C.apply((0, 0, 0.0)); nCe = C.R @ ez                                            # C's bottom plane, normal = -Rz
    rC = np.concatenate([[nB @ (pC - pB)], nCe - nB])                                    # coincident, opposite-facing
    return np.concatenate([rB, rC])

def step(P, d): return Pose(P.t + d[:3], R_from_rotvec(d[3:]) @ P.R)
def J_of(B, C, h=1e-6):
    J = np.zeros((8, 12))
    for i in range(12):
        e = np.zeros(12); e[i] = h
        Bp, Cp = step(B, e[:6]) if i < 6 else B, step(C, e[6:]) if i >= 6 else C
        Bm, Cm = step(B, -e[:6]) if i < 6 else B, step(C, -e[6:]) if i >= 6 else C
        J[:, i] = (resid(Bp, Cp) - resid(Bm, Cm)) / (2 * h)
    return J

B = Pose([0, 0, 5.0], np.eye(3)); C = Pose([-3, -3, 15.0], np.eye(3))
print("residual at rest:", np.round(np.abs(resid(B, C)).max(), 9))
J = J_of(B, C); U, S, Vt = np.linalg.svd(J); rank = int(np.sum(S > 1e-6)); N = Vt[rank:]
print("group DOF (12 vars - rank %d) = %d   [B: slide + spin (2), C on B: 2 in-plane + spin (3) = 5]" % (rank, N.shape[0]))
# wish: hand pulls B up by 12 along the peg; C not touched.  Weighted projection: minimise wB*|dB - wantB|^2 + wC*|dC - 0|^2 over the nullspace.
L = 100.0
Wd = np.array([1, 1, 1, L, L, L] * 2, float) ** 2 * np.array([1] * 6 + [1e-4] * 6)    # follower C is ~free (weight 1e-4)
want = np.zeros(12); want[2] = 12.0
# minimise (N^T x - want)^T Wd (N^T x - want) over x  (N rows are the basis vectors)
A = N @ np.diag(Wd) @ N.T; x = np.linalg.solve(A, N @ np.diag(Wd) @ want); d = N.T @ x
print("group projection of 'B +12 along z':  B moves", np.round(d[:3], 3), " C follows", np.round(d[6:9], 3), "(C in-plane / spin untouched: %s)" % np.round(d[6:8], 3))
# single-occurrence view (today's solver: C frozen): nullspace of the B-only columns
Jb = J[:, :6]; Ub, Sb, Vtb = np.linalg.svd(Jb); rb = int(np.sum(Sb > 1e-6)); print("B alone against a frozen C: DOF", 6 - rb, "-> free directions (B): ", [list(np.round(v, 2)) for v in Vtb[rb:]])
