from scen import *
import numpy as np
res = {}
for name, f in [("face", scenario_face), ("concentric_offset", scenario_concentric_offset), ("angle", scenario_angle)]:
    root = f(); solve(root, "occ-driven")
    st = occs(root)[0]["transform"]
    w = dict(st); w["translation"] = [x + 7 for x in st["translation"]]
    for label, fn in (
        ("PATCH transform", lambda: patch_tr(root, "occ-driven", w)),
        ("POST /solve", lambda: (patch_tr(root, "occ-driven", w), solve(root, "occ-driven"))[1]),
        ("POST /mate-motion", lambda: mate_motion(root, "occ-driven", w)),
        ("GET /occurrences", lambda: occs(root)),
        ("GET /assembly-mesh", lambda: ok(req("GET", f"/document/parts/{root}/assembly-mesh")))):
        ts = []
        for _ in range(60):
            t = time.perf_counter(); fn(); ts.append(time.perf_counter() - t)
        if label == "POST /solve": label = "PATCH+POST /solve (pair)"
        s = stats(ts); print("%-18s %-26s n=%d mean %.1f  p50 %.1f  p95 %.1f  max %.1f ms" % (name, label, s["n"], s["mean_ms"], s["p50_ms"], s["p95_ms"], s["max_ms"]))
