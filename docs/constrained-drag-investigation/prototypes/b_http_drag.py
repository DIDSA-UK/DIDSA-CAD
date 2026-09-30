from h import *
import numpy as np, math

def mk_sketch(): return ok(req("POST", "/sketch/sketches", json={"plane": "XY"}))["id"]
def pt(sk, x, y): return ok(req("POST", f"/sketch/sketches/{sk}/points", json={"x": x, "y": y}))["id"]
def line(sk, a, b): return ok(req("POST", f"/sketch/sketches/{sk}/lines", json={"start_point_id": a, "end_point_id": b}))["id"]
def dist(sk, a, b, d): return ok(req("POST", f"/sketch/sketches/{sk}/constraints", json={"type": "distance", "point_a_id": a, "point_b_id": b, "distance": d}))
def pts(sk): return {p["id"]: (p["x"], p["y"]) for p in ok(req("GET", f"/sketch/sketches/{sk}/points"))}
def patch(sk, p, x, y): return ok(req("PATCH", f"/sketch/sketches/{sk}/points/{p}", json={"x": x, "y": y}))
def solve_anchor(sk, anchors): return ok(req("POST", f"/sketch/sketches/{sk}/solve", json={"anchor_point_ids": anchors}))

def build_arm():
    sk = mk_sketch(); o = list(pts(sk).keys())[0]
    p1 = pt(sk, 20, 20); p2 = pt(sk, 35, 40)
    line(sk, o, p1); line(sk, p1, p2); dist(sk, o, p1, 30.0); dist(sk, p1, p2, 25.0)
    ok(req("POST", f"/sketch/sketches/{sk}/solve"))
    return sk, o, p1, p2

def replay_fallback(sk, drag, others, path, throttle_ms=120, fps=60, proc_ms=None):
    """client fallback path.  returns metrics"""
    dt = 1000.0 / fps
    LOG.clear(); shown_others = {k: pts(sk)[k] for k in others}; hist = []
    last_solve_t = -1e9; conv_fail = 0; solves = 0; jumps = []; dropped = []
    t_ms = 0.0
    for (x, y) in path:
        patch(sk, drag, x, y)                                     # every pointer-move (fire-and-forget in the app)
        if t_ms - last_solve_t >= throttle_ms:
            last_solve_t = t_ms; solves += 1
            r = solve_anchor(sk, [drag]); conv_fail += (not r["converged"])
            P = pts(sk)
            dropped.append(math.dist(P[drag], (x, y)))
            new = {k: P[k] for k in others}
            step = {k: math.dist(new[k], shown_others[k]) for k in others}
            jumps.append(max(step.values())); shown_others = new
            hist.append((t_ms, P[drag], dict(new), r["converged"]))
        t_ms += dt
    n_patch = sum(1 for m, p, d in LOG if m == "PATCH"); n_solve = sum(1 for m, p, d in LOG if m == "POST"); n_get = sum(1 for m, p, d in LOG if m == "GET")
    return {"requests": len(LOG), "patch": n_patch, "solve": n_solve, "get_points": n_get, "solve_fail": conv_fail, "max_other_jump_per_update": max(jumps), "mean_other_jump": float(np.mean(jumps)), "updates": len(jumps),
            "final": hist[-1] if hist else None, "anchor_dropped": sum(1 for d in dropped if d > 1e-3), "max_anchor_drop": max(dropped), "req_ms": stats([d for m, p, d in LOG])}

def circle_path(r, a0, a1, n): return [(r * math.cos(math.radians(a0 + (a1 - a0) * i / (n - 1))), r * math.sin(math.radians(a0 + (a1 - a0) * i / (n - 1)))) for i in range(n)]

if __name__ == "__main__":
    print("== two-link arm (L1=30, L2=25): drag the end point P2 through the sketch API's backend-fallback stream")
    for label, path in (("sweep 20deg->160deg at r=45 (always reachable), 1.5 s", circle_path(45, 20, 160, 90)),
                        ("radial excursion 45 -> 75 (unreachable) -> 45, 1.5 s", [(r * math.cos(math.radians(50)), r * math.sin(math.radians(50))) for r in list(np.linspace(45, 75, 45)) + list(np.linspace(75, 45, 45))])):
        sk, o, p1, p2 = build_arm()
        p1_start = pts(sk)[p1]
        m = replay_fallback(sk, p2, [p1], path)
        print(" ", label); print("    anchor honoured? in %(anchor_dropped)d of %(updates)d solves the dragged point ended >1e-3 from the raw cursor (anchor silently dropped by the no-anchor retry); worst gap %(max_anchor_drop).1f units" % m)
        print("    requests %(requests)d  (PATCH %(patch)d, POST solve %(solve)d, GET points %(get_points)d); solves not converged: %(solve_fail)d/%(updates)d" % m)
        print("    the un-dragged link joint P1 (what the solve reflows) moved at most %.2f units between two reflow updates (mean %.2f); %d reflows in 1.5 s = %.1f Hz" % (m["max_other_jump_per_update"], m["mean_other_jump"], m["updates"], m["updates"] / 1.5))
        print("    per-request latency on localhost: mean %.1f ms p95 %.1f ms" % (m["req_ms"]["mean_ms"], m["req_ms"]["p95_ms"]))
        endpos = pts(sk)
        print("    after final PATCH+drag-end solve state (P2 raw = last cursor %s):" % (tuple(round(v, 1) for v in path[-1]),), {k: tuple(round(v, 1) for v in endpos[k]) for k in (p1, p2)})
        r = solve_anchor(sk, [p2]); print("    drag-end solve anchored at P2:", "converged" if r["converged"] else "NOT converged", "-> P2 lands at", tuple(round(v, 1) for v in pts(sk)[p2]), "P1", tuple(round(v, 1) for v in pts(sk)[p1]))
