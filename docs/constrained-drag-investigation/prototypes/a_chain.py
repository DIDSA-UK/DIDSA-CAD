"""A3 multi-body: peg(base) <- B (concentric, slides on the peg) <- C (sits on B's top face). Drag B."""
from h import *
peg = make_cyl("Peg", 5, 40); B = make_cyl("B", 4, 10); C = make_box("C", 6, 4)
place(peg["id"], [("occ-B", B["id"], (0, 0, 5), (0, 0, 1), 0.0), ("occ-C", C["id"], (-3, -3, 15), (0, 0, 1), 0.0)])
# B concentric with the peg
create_mate(peg["id"], "concentric", face_ref(B["body_id"], find_cyl(B["id"], B["body_id"])), face_ref(peg["body_id"], find_cyl(peg["id"], peg["body_id"])), occ="occ-B")
# C.bottom coincident with B.top
create_mate(peg["id"], "coincident", face_ref(C["body_id"], find_planar(C["id"], C["body_id"], (0, 0, -1))),
            face_ref(B["body_id"], find_planar(B["id"], B["body_id"], (0, 0, 1))), occ="occ-C", fixed_occ="occ-B")
root = peg["id"]
for o in ("occ-B", "occ-C"): solve(root, o)
print("settled: B", [round(x, 3) for x in [o for o in occs(root) if o["id"] == "occ-B"][0]["transform"]["translation"]],
      " C", [round(x, 3) for x in [o for o in occs(root) if o["id"] == "occ-C"][0]["transform"]["translation"]])
# user drags B up the peg by 12 (allowed by B's own concentric mate)
Bt = [o for o in occs(root) if o["id"] == "occ-B"][0]["transform"]
wish = tr((Bt["translation"][0], Bt["translation"][1], Bt["translation"][2] + 12))
r = mate_motion(root, "occ-B", wish)
print("mate-motion(B, wish z+12): converged", r["converged"], "dof", r["dof"], "->", r.get("transform") and [round(x, 3) for x in r["transform"]["translation"]])
print("  free twists:", [[round(x, 2) for x in t] for t in r["free_twists"]])
# the same as the old PATCH+solve path
patch_tr(root, "occ-B", wish)
try:
    s = solve(root, "occ-B"); print("PATCH+solve(B): B ->", [round(x, 3) for x in s["transform"]["translation"]])
except AssertionError as e: print("PATCH+solve(B) failed:", e)
print("C afterwards:", [round(x, 3) for x in [o for o in occs(root) if o["id"] == "occ-C"][0]["transform"]["translation"]], "(C never follows: only the driven occurrence is solved; peers are frozen)")
