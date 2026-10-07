import math
sid = list(all_sketches())[0]; sk = all_sketches()[sid]; B=f"/sketch/sketches/{sid}"
circ = list(sk.circles.values())[0] if isinstance(sk.circles, dict) else sk.circles()[0]
c = sk.points[circ.center_point_id]
cands = [p for p in sk.points.values() if p.id != circ.center_point_id and abs(p.y-c.y) < 1e-6 and p.x > c.x + 5 and p.id != circ.radius_point_id]
a = max(cands, key=lambda p: p.x)
d = math.hypot(a.x-c.x, a.y-c.y)
r = client.post(f"{B}/constraints", json={"point_a_id": c.id, "point_b_id": a.id, "distance": d})
print("centre", (round(c.x,3), round(c.y,3)), "anchor", (round(a.x,3), round(a.y,3)), "dist", round(d,3), r.status_code)
