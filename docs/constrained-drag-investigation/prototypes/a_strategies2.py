"""A3 (refined): constraint VIOLATION of what is displayed (independent geometric residual), jumps at re-anchor, and
the weighting question (L) - on real solver answers."""
import a_strategies as S
from a_strategies import *
import geo

def viol_face(P):   # bracket bottom plane must lie in z=10, normal (0,0,-1)
    n = P.R @ np.array([0, 0, -1.0]); return abs(P.apply((0, 0, 0))[2] - 10.0), math.degrees(math.acos(max(-1, min(1, n @ np.array([0, 0, -1.0])))))
def viol_conc(P):   # driven axis: through local (15,0,0), dir z ; fixed axis = world z through origin
    p = P.apply((15.0, 0, 0)); d = P.R @ np.array([0, 0, 1.0]); return math.hypot(p[0], p[1]), math.degrees(math.acos(max(-1, min(1, abs(d[2])))))
def viol_angle(P):  # angle between driven normal and base normal +z must be 60 (or 120)
    n = P.R @ np.array([0, 0, -1.0]); th = math.degrees(math.acos(max(-1, min(1, n[2])))); return 0.0, min(abs(th - 60), abs(th - 120))

def replay(name, root, start_pose, path, viol, proc=5.0, rtts=(0, 150)):
    resp = collect(root, path)
    assert all(resp)
    truth = [r["pose"] for r in resp]
    out = {}
    for rtt in rtts:
        for strat in ("flat_today", "mate_motion_loop", "local_anchor_once", "local_projection"):
            if strat == "flat_today" and rtt: continue
            disp, reqs, first = simulate(strat, path, resp, start_pose, rtt, proc)
            v = [viol(d) for d in disp]
            ds, dr = steps(disp)
            out[(rtt, strat)] = dict(req=reqs, viol_mm_mean=np.mean([a for a, b in v]), viol_mm_max=max(a for a, b in v),
                                     viol_deg_mean=np.mean([b for a, b in v]), viol_deg_max=max(b for a, b in v),
                                     step_mm_max=max(ds), step_deg_max=max(dr))
    # weighting sweep: local projection at rtt=0 (anchor ~ every 150ms) vs solver truth, for several L
    sweep = {}
    for Lw in (1.0, 10.0, 100.0, 1000.0):
        geo.L = Lw
        # weighted_basis/project_motion read module default L at def time -> pass explicitly
        errs = []; vv = []
        ref = None
        for f in range(N):
            if f % 9 == 0: ref = resp[f]["pose"]; basis = geo.weighted_basis(resp[f]["twists"], L=Lw)
            d = geo.project_motion(ref, basis, path[f], L=Lw)
            errs.append(pose_dist(d, truth[f])); vv.append(viol(d))
        sweep[Lw] = dict(err_mm_mean=np.mean([e[0] for e in errs]), err_deg_mean=np.mean([e[1] for e in errs]),
                         viol_mm_max=max(a for a, b in vv), viol_deg_max=max(b for a, b in vv))
    print(f"\n=== {name} ===")
    for k, v in out.items():
        print("rtt=%3d %-18s req=%3d  VIOLATION mean %.2fmm/%.2fdeg max %.2fmm/%.2fdeg | max frame step %.2fmm/%.2fdeg" % (
            k[0], k[1], v["req"], v["viol_mm_mean"], v["viol_deg_mean"], v["viol_mm_max"], v["viol_deg_max"], v["step_mm_max"], v["step_deg_max"]))
    print("weighting sweep (rtt~0, re-anchor every 9 frames): L -> mean distance to solver's nearest pose, max violation")
    for Lw, s in sweep.items():
        print("  L=%6.0f  err %.2fmm/%.2fdeg   viol_max %.3fmm/%.3fdeg" % (Lw, s["err_mm_mean"], s["err_deg_mean"], s["viol_mm_max"], s["viol_deg_max"]))
    return out, sweep

if __name__ == "__main__":
    res = {}
    root = scenario_face(); solve(root, "occ-driven"); st = Pose.from_json(occs(root)[0]["transform"])
    p = make_path(st, (30, 20, 0), (0, 0, math.radians(60)), {"t": (0, 0, 6), "rv": (math.radians(5), math.radians(4), 0)})
    res["face"] = replay("face", root, st, p, viol_face)
    root = scenario_concentric_offset(); solve(root, "occ-driven"); st = Pose.from_json(occs(root)[0]["transform"])
    p = make_path(st, (0, 0, 15), (0, 0, math.radians(90)), {"t": (4, 3, 0), "rv": (math.radians(4), math.radians(3), 0)})
    res["concentric"] = replay("concentric offset-axis, 90deg spin wish", root, st, p, viol_conc)
    p2 = make_path(st, (0, 0, 15), (0, 0, math.radians(30)), {"t": (4, 3, 0), "rv": (math.radians(4), math.radians(3), 0)})
    res["concentric30"] = replay("concentric offset-axis, 30deg spin wish", root, st, p2, viol_conc)
    root = scenario_angle(); solve(root, "occ-driven"); st = Pose.from_json(occs(root)[0]["transform"])
    p = make_path(st, (15, -10, 5), (0, math.radians(35), math.radians(50)), {"t": (0, 0, 0), "rv": (math.radians(6), 0, 0)})
    res["angle"] = replay("angle 60 (cone), 35deg about Y + 50deg about Z", root, st, p, viol_angle)
