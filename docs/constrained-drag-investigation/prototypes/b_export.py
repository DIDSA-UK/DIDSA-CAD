from b_sketches import *
from app.sketch.router import _constraint_response
out = {}
for name, f in ALL.items():
    s, drag = f()
    r = solve_sketch(s)
    out[name] = {"backend_dof": r.dof, "converged": r.converged, "result_code": r.result_code,
                 "origin": s.origin_point_id,
                 "points": {pid: [p.x, p.y] for pid, p in s.points.items()},
                 "lines": {l.id: [l.start_point_id, l.end_point_id] for l in s.lines()},
                 "constraints": [_constraint_response(c).model_dump(mode="json") for c in s.constraints.values()]}
    print("%-32s backend dof=%s converged=%s code=%s  n_points=%d n_constraints=%d" % (name, r.dof, r.converged, r.result_code, len(s.points), len(s.constraints)))
json.dump(out, open("sketches_export.json", "w"))
