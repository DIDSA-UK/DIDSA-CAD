for sid, sk in all_sketches().items():
    polys = sk.polygons()
    if not polys:
        continue
    r = client.post(f"/sketch/sketches/{sid}/constraints", json={"type": "horizontal", "line_id": polys[0].line_ids[1]})
    print("sketch", sid[:8], "horizontal on edge 1 ->", r.status_code)
