import json
from app.sketch.solver import solve_sketch
ids = json.load(open(work + "/ref_ids.json"))
sk = all_sketches()[ids["sketch2_sk"]]
res = solve_sketch(sk, anchor_point_ids=frozenset())
print("backend solve: converged", res.converged, "dof", res.dof, "| points", len(sk.points), "| locked", [k[:6] for k, p in sk.points.items() if getattr(p, 'is_locked', False)], "| external refs", len(sk.external_references))
for k, p in sk.points.items():
    print(k[:6], round(p.x,2), round(p.y,2), "ref" if k in sk.external_references else "")
