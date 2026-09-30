"""B4: nullspace / tangent-space of a sketch's solution manifold, using ONLY the public py-slvs solve (via the backend's
solve_sketch): perturb one coordinate at a time, re-solve from the perturbed start with everything free (origin/locked pinned),
read the response.  Newton in SolveSpace takes minimum-norm steps, so the response to a perturbation eps*e_i is, to first
order, the ORTHOGONAL PROJECTION of it onto the tangent space T of the solution set.  Stacking the responses gives P (the
projector): rank(P)=dof, range(P)=the free-motion basis.  Scratch code; imports product code read-only."""
import copy, time, statistics
import numpy as np
from b_sketches import *

def free_ids(s):
    return [pid for pid in s.points if pid != s.origin_point_id and not s.is_point_locked(pid)]

def coords(s, ids): return np.array([c for pid in ids for c in (s.points[pid].x, s.points[pid].y)])

def set_coords(s, ids, x):
    for k, pid in enumerate(ids): s.points[pid].x, s.points[pid].y = float(x[2 * k]), float(x[2 * k + 1])

def projector(s0, eps=1e-2, ids=None, cols=None):
    """returns (P, ids, stats). cols = subset of coordinate indices to probe (default all)"""
    s = copy.deepcopy(s0)
    r0 = solve_sketch(s)                      # settle onto the manifold
    ids = ids or free_ids(s); x0 = coords(s, ids); n = len(x0)
    cols = range(n) if cols is None else cols
    P = np.zeros((n, n)); times = []; fails = 0
    for i in cols:
        t = copy.deepcopy(s); x = x0.copy(); x[i] += eps; set_coords(t, ids, x)
        t0 = time.perf_counter(); r = solve_sketch(t); times.append(time.perf_counter() - t0)
        if not r.converged: fails += 1
        P[:, i] = (coords(t, ids) - x0) / eps
    return P, ids, {"solves": len(times), "fails": fails, "mean_ms": 1000 * statistics.mean(times) if times else 0, "converged0": r0.converged, "dof0": r0.dof}

def analyze(P):
    n = P.shape[0]
    sym = float(np.linalg.norm(P - P.T) / max(1e-12, np.linalg.norm(P)))
    w = np.linalg.eigvalsh((P + P.T) / 2)
    return {"trace": float(np.trace(P)), "rank_from_eig": int(np.sum(w > 0.5)), "sym_err": sym, "eig_gap": (float(w[w <= 0.5].max()) if np.any(w <= 0.5) else None, float(w[w > 0.5].min()) if np.any(w > 0.5) else None)}

def point_mobility(P, ids, tol=0.25):
    """per point: rank of the 2x2 diagonal block of the projector (0 = pinned, 1 = slides on a line, 2 = free)+ direction"""
    out = {}
    for k, pid in enumerate(ids):
        B = P[2 * k:2 * k + 2, 2 * k:2 * k + 2]; B = (B + B.T) / 2
        w, v = np.linalg.eigh(B)
        rank = int(np.sum(w > tol))
        d = v[:, -1] if rank == 1 else None
        out[pid] = (rank, None if d is None else (float(d[0]), float(d[1])), [float(x) for x in w])
    return out

if __name__ == "__main__":
    for name, f in ALL.items():
        s, drag = f()
        P, ids, st = projector(s)
        a = analyze(P); mob = point_mobility(P, ids)
        print(f"\n== {name}: N_free_points={len(ids)} ({2*len(ids)} coords)  backend dof={st['dof0']} conv={st['converged0']}")
        print("   probe: %d solves, %d non-converged, %.2f ms/solve   trace(P)=%.3f  rank(eig>0.5)=%d  asymmetry=%.2e  eig gap=(<=%.3f | >=%.3f)" % (
            st["solves"], st["fails"], st["mean_ms"], a["trace"], a["rank_from_eig"], a["sym_err"], a["eig_gap"][0] or 0, a["eig_gap"][1] or 0))
        counts = {0: 0, 1: 0, 2: 0}
        for pid, (rk, d, w) in mob.items(): counts[rk] += 1
        print("   point mobility (rank of own 2x2 block):", {"pinned": counts[0], "line": counts[1], "free": counts[2]})
        dpid = drag
        if dpid in mob:
            rk, d, w = mob[dpid]
            print("   drag target %s: mobility rank %d%s" % (dpid[:6], rk, "" if d is None else "  direction (%.3f, %.3f)" % d))
