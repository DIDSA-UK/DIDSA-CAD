"""Kernel micro-benchmarks for the release-note claims: many-hole face check, Booleans, fillets, meshing, STEP size."""
import json, os, statistics, sys, tempfile, time
import OCC
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepFilletAPI import BRepFilletAPI_MakeFillet
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakeTorus
from OCC.Core.STEPControl import STEPControl_Writer, STEPControl_AsIs
from OCC.Core.TopAbs import TopAbs_EDGE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopTools import TopTools_ListOfShape
from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Pnt
from OCC.Core.GProp import GProp_GProps
from OCC.Core.BRepGProp import brepgprop

def timed(fn, reps=3):
    out = []
    for _ in range(reps):
        s = time.perf_counter(); r = fn(); out.append(time.perf_counter() - s)
    return statistics.median(out), r

def perforated(n):
    plate = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), 10.0 * n + 10, 10.0 * n + 10, 5.0).Shape()
    tools = TopTools_ListOfShape()
    for i in range(n):
        for j in range(n):
            tools.Append(BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(10 + 10 * i, 10 + 10 * j, -1), gp_Dir(0, 0, 1)), 3.0, 7.0).Shape())
    args = TopTools_ListOfShape(); args.Append(plate)
    cut = BRepAlgoAPI_Cut(); cut.SetArguments(args); cut.SetTools(tools); cut.Build()
    return cut.Shape()

res = {"pythonocc": OCC.VERSION}
res["cut_400_holes_s"], plate = timed(lambda: perforated(20))
res["check_400_hole_plate_s"], ok = timed(lambda: BRepCheck_Analyzer(plate).IsValid()); res["check_valid"] = bool(ok)
res["cut_1600_holes_s"], plate2 = timed(lambda: perforated(40), reps=1)
res["check_1600_hole_plate_s"], _ = timed(lambda: BRepCheck_Analyzer(plate2).IsValid(), reps=1)
def fuse_chain():
    s = BRepPrimAPI_MakeBox(100, 100, 10).Shape()
    for i in range(30):
        s = BRepAlgoAPI_Fuse(s, BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(5 + 3 * i, 50, 10), gp_Dir(0, 0, 1)), 4.0, 10.0 + i).Shape()).Shape()
    return s
res["fuse_chain_30_s"], fused = timed(fuse_chain)
p = GProp_GProps(); brepgprop.VolumeProperties(fused, p); res["fuse_chain_volume"] = p.Mass()
def fillet_all():
    box = BRepPrimAPI_MakeBox(40, 30, 20).Shape()
    box = BRepAlgoAPI_Cut(box, BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(20, 15, -1), gp_Dir(0, 0, 1)), 6.0, 22.0).Shape()).Shape()
    f = BRepFilletAPI_MakeFillet(box)
    e = TopExp_Explorer(box, TopAbs_EDGE)
    while e.More():
        f.Add(1.5, e.Current()); e.Next()
    f.Build()
    return f.Shape()
res["fillet_all_edges_s"], filleted = timed(fillet_all)
p = GProp_GProps(); brepgprop.VolumeProperties(filleted, p); res["fillet_volume"] = p.Mass()
def mesh_torus():
    t = BRepPrimAPI_MakeTorus(50, 10).Shape()
    m = BRepMesh_IncrementalMesh(t, 0.005, False, 0.1, False); m.Perform()
    return t
res["mesh_fine_torus_s"], _ = timed(mesh_torus)
def step_size(shape):
    w = STEPControl_Writer(); w.Transfer(shape, STEPControl_AsIs)
    fd, path = tempfile.mkstemp(suffix=".step"); os.close(fd)
    w.Write(path); n = os.path.getsize(path); os.unlink(path); return n
res["step_bytes_400_hole_plate"] = step_size(plate)
res["step_bytes_filleted"] = step_size(filleted)
res["step_write_400_hole_plate_s"], _ = timed(lambda: step_size(plate))
json.dump(res, open(sys.argv[1], "w"), indent=1)
print(json.dumps(res, indent=1))
