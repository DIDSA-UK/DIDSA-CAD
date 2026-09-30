"""Scratch HTTP harness against a running DIDSA backend (not product code)."""
import math, time, json, statistics
import httpx

BASE = "http://127.0.0.1:8000"
C = httpx.Client(base_url=BASE, headers={"X-API-Key": "testkey"}, timeout=60)
LOG = []   # (method, path, seconds)

def req(method, path, **kw):
    t = time.perf_counter()
    r = C.request(method, path, **kw)
    dt = time.perf_counter() - t
    LOG.append((method, path, dt))
    return r

def ok(r, code=(200, 201, 204)):
    assert r.status_code in code, (r.status_code, r.text[:400])
    return r.json() if r.content else None

def create_part(name):
    return ok(req("POST", "/document/parts", json={"name": name}))

def add_point(sk, x, y):
    return ok(req("POST", f"/sketch/sketches/{sk}/points", json={"x": x, "y": y}))

def add_line(sk, a, b):
    ok(req("POST", f"/sketch/sketches/{sk}/lines", json={"start_point_id": a, "end_point_id": b}))

def _extrude(part_id, sk_feat, depth):
    ok(req("POST", f"/document/parts/{part_id}/extrude-features", json={
        "sketch_feature_id": sk_feat, "extrude_type": "boss",
        "start_distance": 0.0, "end_distance": depth, "target_body_ids": []}))
    mesh = ok(req("GET", f"/document/parts/{part_id}/mesh"))
    return {"id": part_id, "body_id": mesh[0]["body_id"]}

def make_box(name, size=10.0, depth=10.0):
    p = create_part(name)
    sf = ok(req("POST", f"/document/parts/{p['id']}/features/sketch", json={"plane": "XY"}))
    sk = sf["sketch_id"]
    cs = [add_point(sk, x, y) for x, y in [(0, 0), (size, 0), (size, size), (0, size)]]
    for a, b in zip(cs, cs[1:] + cs[:1]):
        add_line(sk, a["id"], b["id"])
    return _extrude(p["id"], sf["id"], depth)

def make_cyl(name, radius=5.0, depth=10.0):
    p = create_part(name)
    sf = ok(req("POST", f"/document/parts/{p['id']}/features/sketch", json={"plane": "XY"}))
    sk = sf["sketch_id"]
    c = add_point(sk, 0.0, 0.0)
    ok(req("POST", f"/sketch/sketches/{sk}/circles", json={"center_point_id": c["id"], "radius": radius, "angle": 0.0}))
    return _extrude(p["id"], sf["id"], depth)

def export_part(pid):
    return ok(req("GET", "/document/export/native", params={"part_id": pid}))

def place(root_id, driven_ids, *, translation=(0, 0, 0), rot_axis=(0, 0, 1), rot_deg=0.0):
    """driven_ids: list of (occ_id, part_id, translation, axis, deg)"""
    re = export_part(root_id)
    rp = re["document"]["parts"][0]
    parts = [rp]; sketches = list(re["sketches"])
    occs = []
    seen = set()
    for occ_id, pid, tr, ax, dg in driven_ids:
        occs.append({"id": occ_id, "external_ref": f"parts/{pid}.didsa", "resolved_part_id": pid,
                     "name_override": None,
                     "transform": {"translation": list(tr), "rotation_axis": list(ax), "rotation_angle_degrees": dg},
                     "suppressed": False, "hidden": False})
        if pid not in seen:
            de = export_part(pid); parts.append(de["document"]["parts"][0]); sketches += de["sketches"]; seen.add(pid)
    rp["occurrences"] = occs; rp["mates"] = []
    payload = {"schema_version": re["schema_version"],
               "document": {"id": "composed-doc", "root_part_id": root_id, "parts": parts},
               "sketches": sketches}
    ok(req("POST", "/document/import/native", json=payload))

def measure(pid, body, shape, idx):
    return ok(req("POST", f"/document/parts/{pid}/measure", json={"refs": [{"body_id": body, "shape_type": shape, "index": idx}]}))

def vclose(a, b, tol=1e-4):
    return all(abs(x - y) < tol for x, y in zip(a, b))

def find_planar(pid, body, normal):
    for i in range(12):
        m = measure(pid, body, "face", i)
        if m.get("normal") is not None and vclose(m["normal"], normal): return i
    raise AssertionError("no face")

def find_cyl(pid, body):
    for i in range(12):
        m = measure(pid, body, "face", i)
        if m.get("axis") is not None and m.get("radius") is not None: return i
    raise AssertionError("no cyl")

def create_mate(root, mtype, driven_ref, fixed_ref, occ="occ-driven", value=None, flipped=False, allow_rotation=None, fixed_occ=""):
    body = {"type": mtype, "references": [{"occurrence_id": occ, **driven_ref}, {"occurrence_id": fixed_occ, **fixed_ref}], "flipped": flipped}
    if value is not None: body["value"] = value
    if allow_rotation is not None: body["allow_rotation"] = allow_rotation
    return ok(req("POST", f"/document/parts/{root}/mates", json=body))

def face_ref(body, idx): return {"subshape_ref": {"body_id": body, "shape_type": "face", "index": idx}}

def mate_motion(root, occ, transform):
    r = req("POST", f"/document/parts/{root}/occurrences/{occ}/mate-motion", json={"transform": transform})
    return ok(r)

def solve(root, occ):
    return ok(req("POST", f"/document/parts/{root}/occurrences/{occ}/solve"))

def patch_tr(root, occ, tr):
    return ok(req("PATCH", f"/document/parts/{root}/occurrences/{occ}", json={"transform": tr}))

def occs(root):
    return ok(req("GET", f"/document/parts/{root}/occurrences"))

def tr(t, ax=(0, 0, 1), deg=0.0):
    return {"translation": list(t), "rotation_axis": list(ax), "rotation_angle_degrees": deg}

def stats(xs):
    xs = sorted(xs)
    return {"n": len(xs), "mean_ms": 1000 * statistics.mean(xs), "p50_ms": 1000 * xs[len(xs) // 2],
            "p95_ms": 1000 * xs[min(len(xs) - 1, int(len(xs) * .95))], "max_ms": 1000 * xs[-1]}
