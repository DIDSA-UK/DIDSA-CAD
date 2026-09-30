from h import *
from geo import *
import numpy as np

def make_cyl_at(name, cx, radius=4.0, depth=10.0):
    p = create_part(name)
    sf = ok(req("POST", f"/document/parts/{p['id']}/features/sketch", json={"plane": "XY"}))
    sk = sf["sketch_id"]; c = add_point(sk, cx, 0.0)
    ok(req("POST", f"/sketch/sketches/{sk}/circles", json={"center_point_id": c["id"], "radius": radius, "angle": 0.0}))
    return _ext(p["id"], sf["id"], depth)
from h import _extrude as _ext

def scenario_face():
    base = make_box("Base", 20, 10); br = make_box("Bracket", 8, 4)
    place(base["id"], [("occ-driven", br["id"], (3, 3, 50), (0, 0, 1), 0.0)])
    create_mate(base["id"], "coincident", face_ref(br["body_id"], find_planar(br["id"], br["body_id"], (0, 0, -1))),
                face_ref(base["body_id"], find_planar(base["id"], base["body_id"], (0, 0, 1))))
    return base["id"]

def scenario_concentric_offset(cx=15.0):
    base = make_cyl("Peg", 5, 20); pin = make_cyl_at("OffsetPin", cx, 4, 10)
    place(base["id"], [("occ-driven", pin["id"], (0, 0, 30), (0, 0, 1), 0.0)])
    create_mate(base["id"], "concentric", face_ref(pin["body_id"], find_cyl(pin["id"], pin["body_id"])),
                face_ref(base["body_id"], find_cyl(base["id"], base["body_id"])))
    return base["id"]

def scenario_angle(value=60.0, start_deg=45.0):
    base = make_box("Base", 20, 10); br = make_box("Bracket", 8, 4)
    place(base["id"], [("occ-driven", br["id"], (5, 5, 60), (1, 0, 0), start_deg)])
    create_mate(base["id"], "angle", face_ref(br["body_id"], find_planar(br["id"], br["body_id"], (0, 0, -1))),
                face_ref(base["body_id"], find_planar(base["id"], base["body_id"], (0, 0, 1))), value=value)
    return base["id"]
