# usage: set KIND via a leading assignment in the copy: dims the first matching entity point to the anchor (the free point
# furthest right on the same row / below) and prints the pixel-independent facts. KIND in {rectangle, arc}
import math
sid = list(all_sketches())[0]; sk = all_sketches()[sid]; B=f"/sketch/sketches/{sid}"
if KIND == "rectangle":
    r = sk.rectangles()[0]; target = sk.points[r.corner_point_ids[2]]
elif KIND == "ellipse":
    e = sk.ellipses()[0]; target = sk.points[e.major_point_id]
elif KIND == "ellipse_arc":
    e = sk.ellipse_arcs()[0]; target = sk.points[e.major_point_id]
else:
    a_ = sk.arcs()[0]; target = sk.points[a_.start_point_id]
own = {p.id for p in sk.points.values() if abs(p.x-target.x) < 1e-9 and abs(p.y-target.y) < 1e-9}
cands = [p for p in sk.points.values() if p.id != target.id and p.x > target.x + 5 and p.id not in own]
anchor = min(cands, key=lambda p: math.hypot(p.x-target.x, p.y-target.y))
d = math.hypot(anchor.x-target.x, anchor.y-target.y)
res = client.post(f"{B}/constraints", json={"point_a_id": target.id, "point_b_id": anchor.id, "distance": d})
print(KIND, "target", (round(target.x,2), round(target.y,2)), "anchor", (round(anchor.x,2), round(anchor.y,2)), "dist", round(d,2), res.status_code)
