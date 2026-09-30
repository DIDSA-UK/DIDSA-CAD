"""A3: replay identical 2-second hand paths on real mated occurrences (real backend solves for every frame),
then compare drag strategies offline under different network round-trip times."""
from scen import *
import numpy as np, json, math, sys

FPS = 60; N = 120

def smooth(s): return s * s * (3 - 2 * s)

def make_path(start, d_t, rv_total, wobble):
    """wish poses: from `start`, translate d_t, rotate by rv_total (rotvec, rad), plus out-of-plane hand tremor `wobble` (dict)"""
    out = []
    for f in range(N):
        s = smooth(f / (N - 1)); ph = 2 * math.pi * f / (N - 1)
        t = start.t + np.asarray(d_t) * s + np.asarray(wobble.get("t", (0, 0, 0))) * math.sin(3 * ph) * math.sin(math.pi * s)
        rv = np.asarray(rv_total) * s + np.asarray(wobble.get("rv", (0, 0, 0))) * math.sin(2 * ph) * math.sin(math.pi * s)
        out.append(Pose(t, R_from_rotvec(rv) @ start.R))
    return out

def collect(root, path):
    """real solves for every frame: response(W_f)"""
    resp = []
    for W in path:
        r = mate_motion(root, "occ-driven", W.to_json())
        if not r["converged"]:
            resp.append(None); continue
        resp.append({"pose": Pose.from_json(r["transform"]), "twists": r["free_twists"], "dof": r["dof"]})
    return resp

def dist_stats(a_list, b_list):
    tr = [pose_dist(a, b)[0] for a, b in zip(a_list, b_list)]; rt = [pose_dist(a, b)[1] for a, b in zip(a_list, b_list)]
    return tr, rt

def steps(poses):
    s = [pose_dist(poses[i], poses[i - 1]) for i in range(1, len(poses))]
    return [x[0] for x in s], [x[1] for x in s]

def simulate(strategy, path, resp, start_pose, rtt_ms, proc_ms):
    """returns list of displayed poses per frame + request count + first_answer_frame"""
    dt = 1000.0 / FPS
    disp = []; reqs = 0
    if strategy == "flat_today":
        return list(path), 0, 0
    lat_frames = lambda ms: max(1, math.ceil(ms / dt))
    shown = start_pose; first = None
    inflight = None    # (arrive_frame, idx_of_wish)
    ref = None; basis = None; last_send_f = -10**9
    for f in range(N):
        # arrivals
        if inflight and f >= inflight[0]:
            i = inflight[1]; inflight = None
            r = resp[i]
            if r is not None:
                if strategy in ("patch_solve_loop", "mate_motion_loop"):
                    shown = r["pose"]
                else:
                    ref = r["pose"]; basis = weighted_basis(r["twists"])
                if first is None: first = f
        # sending
        can_send = inflight is None
        if strategy == "local_projection":
            can_send = can_send and (f - last_send_f) * dt >= 150 or (inflight is None and ref is None)
        if strategy == "local_anchor_once":
            can_send = inflight is None and ref is None and last_send_f < 0
        if can_send and inflight is None:
            if strategy == "patch_solve_loop":
                inflight = (f + lat_frames(2 * (rtt_ms + proc_ms)), f); reqs += 2
            else:
                inflight = (f + lat_frames(rtt_ms + proc_ms), f); reqs += 1
            last_send_f = f
        if strategy.startswith("local") and ref is not None:
            shown = project_motion(ref, basis, path[f])
        disp.append(shown)
    return disp, reqs, first

def run(name, root, start_pose, path, proc):
    print(f"\n=== {name} ===")
    resp = collect(root, path)
    n_fail = sum(r is None for r in resp)
    print("frames:", N, "non-converged:", n_fail, "dof:", sorted({r['dof'] for r in resp if r}))
    truth = [r["pose"] if r else path[i] for i, r in enumerate(resp)]
    rows = []
    for rtt in (0, 50, 150, 400):
        for strat in ("flat_today", "patch_solve_loop", "mate_motion_loop", "local_anchor_once", "local_projection"):
            if strat == "flat_today" and rtt: continue
            disp, reqs, first = simulate(strat, path, resp, start_pose, rtt, proc)
            tr, rt = dist_stats(disp, truth)
            ds, dr = steps(disp); ts, trr = steps(truth); ws, wr = steps(path)
            rows.append({"scenario": name, "rtt_ms": rtt, "strategy": strat, "requests": reqs,
                         "first_answer_frame": first, "err_mm_mean": float(np.mean(tr)), "err_mm_max": float(np.max(tr)),
                         "err_deg_mean": float(np.mean(rt)), "err_deg_max": float(np.max(rt)),
                         "step_mm_max": float(np.max(ds)), "step_deg_max": float(np.max(dr)),
                         "stalled_frames": int(sum(1 for a, w in zip(ds, ws) if a < 1e-9 and w > 1e-3))})
    return rows, {"wish_step_mm_max": max(steps(path)[0]), "wish_step_deg_max": max(steps(path)[1]),
                  "truth_step_mm_max": max(steps(truth)[0]), "truth_step_deg_max": max(steps(truth)[1]),
                  "wish_to_truth_final_mm": pose_dist(path[-1], truth[-1])[0], "wish_to_truth_final_deg": pose_dist(path[-1], truth[-1])[1],
                  "wish_to_truth_max_mm": max(pose_dist(a, b)[0] for a, b in zip(path, truth)),
                  "wish_to_truth_max_deg": max(pose_dist(a, b)[1] for a, b in zip(path, truth))}

if __name__ == "__main__":
    # measure proc time once (localhost, mate-motion)
    allrows = []; meta = {}
    root = scenario_face(); solve(root, "occ-driven")
    st = Pose.from_json(occs(root)[0]["transform"])
    p = make_path(st, (30, 20, 0), (0, 0, math.radians(60)), {"t": (0, 0, 6), "rv": (math.radians(5), math.radians(4), 0)})
    proc = 5.0
    rows, m = run("face (3 DOF, flat)", root, st, p, proc); allrows += rows; meta["face"] = m

    root = scenario_concentric_offset(); solve(root, "occ-driven")
    st = Pose.from_json(occs(root)[0]["transform"])
    p = make_path(st, (0, 0, 15), (0, 0, math.radians(90)), {"t": (4, 3, 0), "rv": (math.radians(4), math.radians(3), 0)})
    rows, m = run("concentric, offset axis (2 DOF, curved)", root, st, p, proc); allrows += rows; meta["concentric"] = m

    root = scenario_angle(); solve(root, "occ-driven")
    st = Pose.from_json(occs(root)[0]["transform"])
    p = make_path(st, (15, -10, 5), (0, math.radians(35), math.radians(50)), {"t": (0, 0, 0), "rv": (math.radians(6), 0, 0)})
    rows, m = run("angle 60deg (5 DOF, curved cone)", root, st, p, proc); allrows += rows; meta["angle"] = m
    json.dump({"rows": allrows, "meta": meta}, open("a_strategies.json", "w"), indent=1)
    print(json.dumps(meta, indent=1))
    for r in allrows:
        print("%-38s rtt=%3d %-18s req=%3d first=%s err=%.2fmm/%.2fdeg (max %.2f/%.2f) step_max=%.2fmm/%.2fdeg stalled=%d" % (
            r["scenario"], r["rtt_ms"], r["strategy"], r["requests"], r["first_answer_frame"], r["err_mm_mean"], r["err_deg_mean"],
            r["err_mm_max"], r["err_deg_max"], r["step_mm_max"], r["step_deg_max"], r["stalled_frames"]))
