from scen import *
for name, f in [("face", scenario_face), ("concentric_offset", scenario_concentric_offset), ("angle30", scenario_angle)]:
    root = f()
    solve(root, "occ-driven")
    r = mate_motion(root, "occ-driven", None)
    print(name, "dof", r["dof"], "converged", r["converged"], "solved", [round(x,3) for x in r["transform"]["translation"]], r["transform"]["rotation_angle_degrees"])
    for t in r["free_twists"]: print("   ", [round(x, 3) for x in t])
