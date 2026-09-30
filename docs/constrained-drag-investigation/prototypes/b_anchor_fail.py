from b_probe import *
s, drag = sk_two_link()
o = s.origin_point_id; p1, p2 = [pid for pid in s.points if pid != o]
def trial(p1xy, p2xy, label):
    t = copy.deepcopy(s); t.points[p1].x, t.points[p1].y = p1xy; t.points[p2].x, t.points[p2].y = p2xy
    r = solve_sketch(t, anchor_point_ids=frozenset([p2]))
    moved = math.dist((t.points[p2].x, t.points[p2].y), p2xy)
    print("%-52s converged=%s code=%s  dragged point moved %.2f  -> P1=(%.1f,%.1f) P2=(%.1f,%.1f)" % (label, r.converged, r.result_code, moved, t.points[p1].x, t.points[p1].y, t.points[p2].x, t.points[p2].y))
trial((19.3, 23.0), (28.9, 34.5), "P1 stale (19.3,23.0) P2 raw (28.9,34.5) [r=45, reachable]")
trial((19.3, 23.0), (35.0, 41.0), "P1 stale, P2 raw (35,41) [r=53.9, near full reach]")
trial((19.3, 23.0), (40.0, 48.0), "P1 stale, P2 raw (40,48) [r=62.5, out of reach]")
trial((25.0, 16.5), (28.9, 34.5), "P1 well-placed (25,16.5), P2 raw (28.9,34.5)")
trial((30.0, 0.0), (28.9, 34.5), "P1 on x axis (30,0), P2 raw (28.9,34.5)")
