"""C: does the probe route carry to a TRUE 3D sketch (3 params/point, free-3D constraints, no workplane)?  py-slvs supports it
(the assembly solver already uses free-3D addPointsDistance etc.).  Toy 3D sketches built directly on py_slvs; nothing in the app
models these today."""
import numpy as np, time
from py_slvs import slvs

def solve3d(pts0, dists, fixed=(0,), on_plane=(), anchor=None):
    """pts0: (N,3) start; dists: [(i,j,d)]; fixed: indices pinned (fixed group); on_plane: indices constrained to z=0 plane."""
    s = slvs.System(); FIX, SOL = 1, 2
    h = []
    for i, p in enumerate(pts0):
        g = FIX if (i in fixed or i == anchor) else SOL
        h.append(s.addPoint3dV(float(p[0]), float(p[1]), float(p[2]), group=g))
    for i, j, d in dists: s.addPointsDistance(float(d), h[i], h[j], group=SOL)
    if on_plane:
        o = s.addPoint3dV(0, 0, 0, group=FIX); n = s.addNormal3dV(1, 0, 0, 0, group=FIX); w = s.addWorkplane(o, n, group=FIX)
        for i in on_plane: s.addPointInPlane(h[i], w, group=SOL)
    code = s.solve(group=SOL, reportFailed=True)
    out = np.array([[s.getParam(s.getEntityParam(hh, k)).val for k in range(3)] for hh in h])
    return code, out, s.Dof

def probe(pts0, dists, fixed=(0,), on_plane=(), eps=1e-3):
    code, x0, dof = solve3d(pts0, dists, fixed, on_plane); free = [i for i in range(len(pts0)) if i not in fixed]
    idx = [(i, k) for i in free for k in range(3)]; n = len(idx); P = np.zeros((n, n)); t0 = time.perf_counter()
    for c, (i, k) in enumerate(idx):
        p = x0.copy(); p[i, k] += eps; code2, x1, _ = solve3d(p, dists, fixed, on_plane)
        P[:, c] = np.array([(x1[a, b] - x0[a, b]) / eps for a, b in idx])
    dt = time.perf_counter() - t0
    U, S, _ = np.linalg.svd(P); return code, dof, int(np.sum(S > 0.5)), dt / n * 1000, P, idx, U[:, :int(np.sum(S > 0.5))]

# 3D two-link arm from a fixed origin: L1=30, L2=25
pts = np.array([[0, 0, 0], [20, 20, 5], [35, 40, 12.0]]); d = [(0, 1, 30.0), (1, 2, 25.0)]
code, dof_slvs, rank, ms, P, idx, Q = probe(pts, d)
print("3D arm (2 links, 6 free coords): solve code", code, "py-slvs Dof", dof_slvs, "probe rank", rank, "(expected 4: P1 on a sphere 2, P2 on a sphere about P1 2) ; %.3f ms/solve" % ms)
# per-point mobility: the 3xd block for each free point tells the drag manifold's dimension at that point
for pi, i in enumerate([1, 2]):
    B = Q[3 * pi:3 * pi + 3, :]; sv = np.linalg.svd(B)[1]
    print("   P%d: reachable-motion subspace dimension %d  (singular values %s)  -> %s" % (i, int(np.sum(sv > 0.05)), np.round(sv, 2), "drag on a 2D tangent surface: choose the camera-facing plane projected onto it" if int(np.sum(sv > 0.05)) == 3 else ("drag plane = the tangent plane" if int(np.sum(sv > 0.05)) == 2 else "line")))
# planar-constrained 3D point cloud: a triangle whose three points lie in z=0 plane
pts = np.array([[0, 0, 0], [30, 0, 0.2], [10, 25, -0.1]]); d = [(0, 1, 30.0), (1, 2, 28.0), (0, 2, 26.0)]
code, dof_slvs, rank, ms, P, idx, Q = probe(pts, d, on_plane=(1, 2))
print("3D triangle pinned to plane z=0 by point-in-plane (rigid, origin fixed): solve code", code, "py-slvs Dof", dof_slvs, "probe rank", rank, "(expected 1: rotation about the fixed origin within the plane)")
