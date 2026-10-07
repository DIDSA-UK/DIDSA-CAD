import math
sid = list(all_sketches())[0]; sk = all_sketches()[sid]; B=f"/sketch/sketches/{sid}"
tot = 0
for ln in sk.lines():
    a, b = sk.points[ln.start_point_id], sk.points[ln.end_point_id]
    d = math.hypot(b.x-a.x, b.y-a.y); tot += d
    r = client.post(f"{B}/constraints", json={"point_a_id": a.id, "point_b_id": b.id, "distance": d})
    print("line", (round(a.x,2), round(a.y,2)), "->", (round(b.x,2), round(b.y,2)), "len", round(d,2), r.status_code)
print("reach", round(tot,2))
