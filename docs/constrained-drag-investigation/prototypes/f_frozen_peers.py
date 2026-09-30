"""Follow-up: how low can per-occurrence DOF fall against frozen peers?  Base plate; B, C, D boxes all resting on it (face mates);
B additionally mated side-to-side to C (x) and D (y).  Truth: translating B, C, D together in x or y (and spinning them together about z) keeps every mate."""
from h import *
base = make_box("Base", 60, 10); B = make_box("B", 8, 4); C = make_box("C", 8, 4); D = make_box("D", 8, 4)
place(base["id"], [("occ-B", B["id"], (20, 20, 10), (0, 0, 1), 0.0), ("occ-C", C["id"], (28, 20, 10), (0, 0, 1), 0.0), ("occ-D", D["id"], (20, 12, 10), (0, 0, 1), 0.0)])
root = base["id"]
bt = find_planar(root, base["body_id"], (0, 0, 1))
def bottom(p): return face_ref(p["body_id"], find_planar(p["id"], p["body_id"], (0, 0, -1)))
def side(p, n): return face_ref(p["body_id"], find_planar(p["id"], p["body_id"], n))
for occ, p in (("occ-B", B), ("occ-C", C), ("occ-D", D)):
    create_mate(root, "coincident", bottom(p), face_ref(base["body_id"], bt), occ=occ)
def report(tag):
    print(tag)
    for occ in ("occ-B", "occ-C", "occ-D"):
        r = mate_motion(root, occ, None); print("   %s: converged=%s dof=%s" % (occ, r["converged"], r["dof"]))
report("only the three base-plate mates (each part on the plate):")
create_mate(root, "coincident", side(B, (1, 0, 0)), side(C, (-1, 0, 0)), occ="occ-B", fixed_occ="occ-C")
report("+ B side-mated to C (B.+x face on C.-x face), C treated as frozen:")
create_mate(root, "coincident", side(B, (0, -1, 0)), side(D, (0, 1, 0)), occ="occ-B", fixed_occ="occ-D")
report("+ B side-mated to D (B.-y face on D.+y face):")
