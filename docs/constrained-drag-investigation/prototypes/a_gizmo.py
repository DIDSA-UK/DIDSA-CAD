"""A4: how much of each gizmo handle's motion lies inside the free subspace (1.0 = fully free, 0 = locked)."""
from scen import *
from geo import *
import numpy as np
names = ["move X", "move Y", "move Z", "rot X ", "rot Y ", "rot Z "]
def table(name, root):
    solve(root, "occ-driven")
    st = Pose.from_json(occs(root)[0]["transform"])
    r = mate_motion(root, "occ-driven", st.to_json()); Lw = 100.0
    basis = weighted_basis(r["free_twists"], L=Lw)
    print(f"\n{name}: dof={r['dof']}  pose t={np.round(st.t,2)}")
    for i, nm in enumerate(names):
        a = st.R[:, i % 3]                  # occurrence local axis in world coords
        v = np.concatenate([a, np.zeros(3)]) if i < 3 else np.concatenate([np.zeros(3), a * Lw])
        proj = sum((u @ v) * u for u in basis) if basis else np.zeros(6)
        frac = float(np.linalg.norm(proj) / np.linalg.norm(v))
        print(f"   {nm}  free fraction {frac:5.2f}")
table("face-to-face coincident", scenario_face())
table("concentric (offset axis)", scenario_concentric_offset())
table("angle 60deg", scenario_angle())
