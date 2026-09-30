from b_scale import time_solve, time_solve_anchored
from b_probe import *
def sk_chain(n):     # connected staircase polyline of n segments: alternating H / V constraints, every 3rd segment dimensioned
    s = new(); prev = s.origin_point(); x = y = 0.0; last = None
    for i in range(n):
        if i % 2 == 0: x += 10
        else: y += 10
        p = s.add_point(x + (i % 3) * 0.1, y + (i % 5) * 0.1)
        l = s.add_line(prev.id, p.id)
        (s.add_horizontal_constraint if i % 2 == 0 else s.add_vertical_constraint)(l.id)
        if i % 3 == 0: s.add_distance_constraint(prev.id, p.id, 10.0)
        prev = p; last = p.id
    return s, last
print("connected staircase chains (H/V on every segment, every 3rd dimensioned):")
print("%-10s %8s %10s %14s" % ("segments", "points", "solve(ms)", "anchored(ms)"))
for n in (10, 40, 100, 200, 400):
    s, last = sk_chain(n)
    r = solve_sketch(copy.deepcopy(s))
    print("%-10d %8d %10.2f %14.2f   converged=%s dof=%s" % (n, len(s.points), time_solve(s, 8), time_solve_anchored(s, last, 8), r.converged, r.dof))
