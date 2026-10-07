import math
sid = list(all_sketches())[0]; sk = all_sketches()[sid]; B=f"/sketch/sketches/{sid}"
slot = sk.slots()[0]
c2 = sk.points[slot.center2_point_id]
own = {slot.center1_point_id, slot.center2_point_id}
cands = [p for p in sk.points.values() if abs(p.y-c2.y) < 1e-6 and p.x > c2.x + 5]
a = max(cands, key=lambda p: p.x)
d = math.hypot(a.x-c2.x, a.y-c2.y)
r = client.post(f"{B}/constraints", json={"point_a_id": c2.id, "point_b_id": a.id, "distance": d})
print("slot centre2", (round(c2.x,2), round(c2.y,2)), "anchor", (round(a.x,2), round(a.y,2)), "dist", round(d,2), r.status_code)
