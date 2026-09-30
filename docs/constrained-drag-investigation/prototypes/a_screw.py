from a_strategies2 import *
import geo
def run_variant(name, root, st, path, viol):
    resp = collect(root, path); truth = [r["pose"] for r in resp]
    print(f"\n=== {name}: additive (VR today) vs screw-exponential projection; re-anchor every 9 frames (~150ms)")
    for Lw in (10.0, 100.0):
        for label, fn in (("additive", geo.project_motion), ("screw   ", geo.project_motion_screw)):
            for every in (9, 10**9):
                vv = []; steps_ = []; prev = None
                for f in range(N):
                    if f % every == 0: ref = resp[f]["pose"]; basis = geo.weighted_basis(resp[f]["twists"], L=Lw)
                    d = fn(ref, basis, path[f], L=Lw); vv.append(viol(d))
                    if prev is not None: steps_.append(pose_dist(d, prev)[0])
                    prev = d
                print("  L=%4.0f %s re-anchor=%-5s  violation mean %.3fmm/%.3fdeg  max %.3fmm/%.3fdeg   max step %.2fmm" % (
                    Lw, label, "150ms" if every == 9 else "never", np.mean([a for a, b in vv]), np.mean([b for a, b in vv]),
                    max(a for a, b in vv), max(b for a, b in vv), max(steps_)))
root = scenario_concentric_offset(); solve(root, "occ-driven"); st = Pose.from_json(occs(root)[0]["transform"])
p = make_path(st, (0, 0, 15), (0, 0, math.radians(90)), {"t": (4, 3, 0), "rv": (math.radians(4), math.radians(3), 0)})
run_variant("concentric offset axis, 90deg spin wish", root, st, p, viol_conc)
root = scenario_angle(); solve(root, "occ-driven"); st = Pose.from_json(occs(root)[0]["transform"])
p = make_path(st, (15, -10, 5), (0, math.radians(35), math.radians(50)), {"t": (0, 0, 0), "rv": (math.radians(6), 0, 0)})
run_variant("angle cone", root, st, p, viol_angle)
