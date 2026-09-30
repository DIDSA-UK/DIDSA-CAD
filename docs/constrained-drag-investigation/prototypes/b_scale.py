from b_probe import *
import statistics
def time_solve(s, reps=20):
    ts = []
    for _ in range(reps):
        t = copy.deepcopy(s); t0 = time.perf_counter(); solve_sketch(t); ts.append(time.perf_counter() - t0)
    return 1000 * statistics.median(ts)
def time_solve_anchored(s, anchor, reps=20):
    ts = []
    for _ in range(reps):
        t = copy.deepcopy(s); t.points[anchor].x += 0.5; t0 = time.perf_counter(); solve_sketch(t, anchor_point_ids=frozenset([anchor])); ts.append(time.perf_counter() - t0)
    return 1000 * statistics.median(ts)
if __name__ == "__main__":
    print("%-22s %8s %8s %12s %14s %18s %18s" % ("sketch", "points", "coords", "solve(ms)", "anch.solve(ms)", "drag-map (2 probes)", "full nullspace (2N probes)"))
    for n in (1, 3, 5, 10):
        s, first = sk_grid(n)
        # dimension a few things so that it is a realistic mix: each rectangle's corner0 width dim
        npts = len(s.points)
        ids = free_ids(s); tsolve = time_solve(s); tanch = time_solve_anchored(s, first)
        k = ids.index(first)
        t0 = time.perf_counter(); P2, _, _ = projector(s, cols=[2 * k, 2 * k + 1]); t_drag = 1000 * (time.perf_counter() - t0)
        if n <= 5:
            t0 = time.perf_counter(); Pf, _, st = projector(s); t_full = 1000 * (time.perf_counter() - t0)
            rank = int(round(np.trace(Pf))); full = "%.0f ms (rank %d)" % (t_full, rank)
        else:
            t0 = time.perf_counter(); Pf, _, st = projector(s, cols=list(range(0, 40))); t_part = 1000 * (time.perf_counter() - t0); full = "~%.0f ms (extrap. from 40 cols)" % (t_part / 40 * 2 * len(ids))
        print("%-22s %8d %8d %12.2f %14.2f %16.1f ms %s" % (f"grid {n}x{n} rects", npts, 2 * len(ids), tsolve, tanch, t_drag, full))
