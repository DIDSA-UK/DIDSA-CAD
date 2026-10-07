# Box (10x10x10) with a fillet, then a sketch AFTER the fillet holding a reference to the far corner (10,10,10), a line from it to a
# free point and a length dimension. Writes ids to WORK/ref_ids.json for the later steps.
import json, math
from app.document.create_plane import _resolve_vertex_position
from app.document.models import SubShapeRef, SubShapeType
from app.document.router import compute_part_bodies, get_part_or_404

def J(r):
    assert r.status_code < 300, (r.status_code, r.text[:300]); return r.json()
part_id = list(get_document().parts)[0]
sk = J(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
pts = [J(client.post(f"/sketch/sketches/{sk['sketch_id']}/points", json={"x": x, "y": y})) for x, y in [(0,0),(10,0),(10,10),(0,10)]]
for a, b in zip(pts, pts[1:] + pts[:1]):
    J(client.post(f"/sketch/sketches/{sk['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}))
ex = J(client.post(f"/document/parts/{part_id}/extrude-features", json={"sketch_feature_id": sk["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []}))
fil = J(client.post(f"/document/parts/{part_id}/fillet-features", json={"edge_refs": [{"body_id": ex["id"], "shape_type": "edge", "index": 0}], "radius": 2.0}))
def verts():
    bodies = compute_part_bodies(get_part_or_404(part_id)); out = {}
    for i in range(200):
        try: p = _resolve_vertex_position(bodies, SubShapeRef(body_id=ex["id"], shape_type=SubShapeType.VERTEX, index=i))
        except Exception: break
        out[i] = (round(p.X(),3), round(p.Y(),3), round(p.Z(),3))
    return out
idx = next(i for i, v in verts().items() if v == (10.0, 10.0, 10.0))
s2 = J(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
ref = J(client.post(f"/document/parts/{part_id}/features/sketch/{s2['id']}/external-references", json={"body_id": ex["id"], "vertex_index": idx}))
free = J(client.post(f"/sketch/sketches/{s2['sketch_id']}/points", json={"x": 4.0, "y": 14.0}))
J(client.post(f"/sketch/sketches/{s2['sketch_id']}/lines", json={"start_point_id": ref["id"], "end_point_id": free["id"]}))
J(client.post(f"/sketch/sketches/{s2['sketch_id']}/constraints", json={"point_a_id": ref["id"], "point_b_id": free["id"], "distance": 8.0}))
json.dump({"part": part_id, "base": sk["id"], "extrude": ex["id"], "fillet": fil["id"], "sketch2": s2["id"], "sketch2_sk": s2["sketch_id"], "ref": ref["id"], "free": free["id"], "far_index": idx}, open(work + "/ref_ids.json", "w"))
print("far corner vertex index", idx, "ref point", (ref["x"], ref["y"]), "free", (free["x"], free["y"]))
print("features:", [f["type"] if "type" in f else f.get("kind") for f in J(client.get(f"/document/parts/{part_id}/features"))])
