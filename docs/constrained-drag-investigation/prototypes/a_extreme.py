from scen import *
from geo import *
root = scenario_face(); solve(root, "occ-driven")
print("face mate, extreme wishes -> nearest solution")
for label, w in [("tilt 60deg about X (not free)", tr((3, 3, 12), (1, 0, 0), 60)), ("flip 179deg about X", tr((3, 3, 12), (1, 0, 0), 179)),
                 ("flip 181deg (=-179) about X", tr((3, 3, 12), (1, 0, 0), 181)), ("upside down + far", tr((300, -200, 500), (1, 0, 0), 180)),
                 ("spin 170 about Z", tr((3, 3, 10), (0, 0, 1), 170)), ("spin 190 about Z", tr((3, 3, 10), (0, 0, 1), 190))]:
    r = mate_motion(root, "occ-driven", w)
    if not r["converged"]: print("  %-32s NOT converged (dof %s)" % (label, r["dof"])); continue
    P = Pose.from_json(r["transform"]); print("  %-32s -> t=%s rot=%.1f deg about %s dof=%d" % (label, np.round(P.t, 2), r["transform"]["rotation_angle_degrees"], np.round(r["transform"]["rotation_axis"], 2), r["dof"]))
