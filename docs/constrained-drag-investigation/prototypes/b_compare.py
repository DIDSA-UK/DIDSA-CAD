from b_probe2 import tangent_basis, mobility_from_basis
from b_probe import *
import json
dart = json.load(open("dart_dof.json")); exp = json.load(open("sketches_export.json"))
print("%-32s %6s %8s %8s | %-44s" % ("sketch", "py-slvs", "probe", "expected", "per-point: probe mobility (0 pinned/1 line/2 free)  vs  Dart structural verdict"))
expected = {"rect_partial(w fixed, h free)": 1, "rect_full": 0, "rect_floating": 4, "two_link_arm": 2, "hexagon(provisional)": 4, "slot": 5, "redundant_parallel": 1, "conflict_2_widths": "n/a"}
for name, f in ALL.items():
    s, drag = f()
    P, ids, st = projector(s, eps=1e-3)
    Q, S = tangent_basis(P); mob = mobility_from_basis(Q, ids)
    d_by_index = list(dart[name].values()); order_ids = list(s.points.keys())
    d = {pid: d_by_index[order_ids.index(pid)] for pid in ids}
    agree = 0; rows = []
    for pid in ids:
        rk = mob[pid][0]; dv = d[pid]
        verdict = "OVER" if dv["over"] else ("fully" if dv["fully"] else ("pinned" if dv["pinned"] else "free/under"))
        ok_ = (rk == 0 and verdict in ("fully", "pinned")) or (rk > 0 and verdict in ("free/under",)) or (verdict == "OVER")
        agree += ok_
        rows.append((rk, verdict, ok_))
    dis = [(i, r) for i, r in enumerate(rows) if not r[2]]
    print("%-32s %6s %8s %8s | %d/%d points agree; disagreements: %s" % (name, exp[name]["backend_dof"], Q.shape[1] if st["fails"] == 0 else f"{Q.shape[1]}*", expected[name], agree, len(ids),
          ", ".join(f"pt{i}: probe rank {r[0]} vs Dart '{r[1]}'" for i, r in dis) or "none"))
