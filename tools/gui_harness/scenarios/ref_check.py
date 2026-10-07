import json, math
ids = json.load(open(work + "/ref_ids.json"))
sk = all_sketches()[ids["sketch2_sk"]]
r, f = sk.points[ids["ref"]], sk.points[ids["free"]]
print("ref", (round(r.x,4), round(r.y,4)), "free", (round(f.x,3), round(f.y,3)), "len", round(math.hypot(f.x-r.x, f.y-r.y),4), "refs:", {k: (v.vertex_index, v.kind) for k, v in sk.external_references.items()})
