"""A1/A2: what the flat app does today when a mated occurrence is dragged, replayed against a live backend."""
from h import *
import numpy as np

base = make_box("Base", 20, 10); bracket = make_box("Bracket", 8, 4)
place(base["id"], [("occ-driven", bracket["id"], (3, 3, 50), (0, 0, 1), 0.0)])
bt = find_planar(base["id"], base["body_id"], (0, 0, 1)); bb = find_planar(bracket["id"], bracket["body_id"], (0, 0, -1))
create_mate(base["id"], "coincident", face_ref(bracket["body_id"], bb), face_ref(base["body_id"], bt))
root = base["id"]
print("stored after mate create (no solve yet):", occs(root)[0]["transform"]["translation"])
solve(root, "occ-driven")
print("after explicit /solve  (what _confirmMate does):", occs(root)[0]["transform"]["translation"])

# ---- Replay the CURRENT gizmo drag along local +Z (lift off the face) then release.
LOG.clear()
frames = 60                                    # 1 s of 60 fps pointer moves
# During the drag: _updateComponentGizmoDrag -> onComponentGizmoDragUpdate -> setState. ZERO network calls (verified by reading code).
n_during = 0
final = tr((3, 3, 10 + 30))                    # user lifted 30 units along gizmo Z
t0 = time.perf_counter()
patch_tr(root, "occ-driven", final)            # _api.updateOccurrenceTransform
occs(root)                                     # _refreshAssemblyTree: listOccurrences
ok(req("GET", f"/document/parts/{root}/mates"))
ok(req("GET", f"/document/parts/{root}/component-patterns"))
mesh = req("GET", f"/document/parts/{root}/assembly-mesh")   # _refreshAssemblyMesh
t1 = time.perf_counter()
print("\nDrag-end sequence (PATCH + 3 list GETs + assembly-mesh): %d requests, %.1f ms total; mesh payload %d bytes"
      % (len(LOG), 1000 * (t1 - t0), len(mesh.content)))
for m, p, d in LOG: print("  %-5s %-70s %6.1f ms" % (m, p.replace(root, "<part>"), 1000 * d))
print("STORED transform after release:", occs(root)[0]["transform"]["translation"], "<- mate demands z=10; nothing re-solved")
mm = mate_motion(root, "occ-driven", None)
print("mate-motion(from stored) says nearest satisfying pose is:", [round(x, 3) for x in mm["transform"]["translation"]])
