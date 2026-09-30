"""ANGLE mate from an identity-orientation start never converges (singular start: d cos(angle)/d theta = 0 there);
from a tilted start it does.  Real backend."""
from h import *
for start_deg, val in [(0, 30), (0, 60), (0, 90), (0, 150), (45, 60), (45, 30)]:
    base = make_box("Base", 20, 10); br = make_box("Bracket", 8, 4)
    place(base["id"], [("occ-driven", br["id"], (5, 5, 60), (1, 0, 0), float(start_deg))])
    create_mate(base["id"], "angle", face_ref(br["body_id"], find_planar(br["id"], br["body_id"], (0, 0, -1))),
                face_ref(base["body_id"], find_planar(base["id"], base["body_id"], (0, 0, 1))), value=val)
    r = mate_motion(base["id"], "occ-driven", None)
    print("start tilt %3d deg about X, angle mate %3d deg -> converged=%s dof=%s" % (start_deg, val, r["converged"], r["dof"]))
