import math
sid = list(all_sketches())[0]; sk = all_sketches()[sid]
for e in sk.ellipses() + sk.ellipse_arcs():
    c, M, m = sk.points[e.center_point_id], sk.points[e.major_point_id], sk.points[e.minor_point_id]
    a = math.hypot(M.x-c.x, M.y-c.y); b = math.hypot(m.x-c.x, m.y-c.y)
    dot = ((M.x-c.x)*(m.x-c.x) + (M.y-c.y)*(m.y-c.y)) / (a*b)
    d = [round(math.hypot(M.x-p.x, M.y-p.y), 3) for p in sk.points.values() if abs(math.hypot(M.x-p.x, M.y-p.y)-19.92) < 0.05]
    print(type(e).__name__, "major", round(a,3), "minor", round(b,3), "axes cos", round(dot,6), "tip-anchor", d)
