"""Geometry report for a STEP file: solids, volume, bbox, face types, cylinder radii.
Run with the backend's conda python. Usage: inspect_step.py model.step [out.json]"""
import json
import sys
from collections import Counter

from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GeomAbs import GeomAbs_Cylinder, GeomAbs_Plane
from OCC.Core.GProp import GProp_GProps
from OCC.Core.STEPControl import STEPControl_Reader
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import topods


def shapes(shape, kind):
    exp = TopExp_Explorer(shape, kind)
    while exp.More():
        yield exp.Current()
        exp.Next()


def report(path):
    reader = STEPControl_Reader()
    if reader.ReadFile(path) != 1:
        return {"error": "STEP read failed"}
    reader.TransferRoots()
    shape = reader.OneShape()
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    box = Bnd_Box()
    box.SetGap(0.0)
    brepbndlib.AddOptimal(shape, box, False, False)
    x0, y0, z0, x1, y1, z1 = box.Get()
    kinds, radii = Counter(), Counter()
    for f in shapes(shape, TopAbs_FACE):
        s = BRepAdaptor_Surface(topods.Face(f))
        t = s.GetType()
        if t == GeomAbs_Plane:
            kinds["plane"] += 1
        elif t == GeomAbs_Cylinder:
            kinds["cylinder"] += 1
            radii[round(s.Cylinder().Radius(), 3)] += 1
        else:
            kinds[f"other:{t}"] += 1
    c = props.CentreOfMass()
    return {
        "solids": sum(1 for _ in shapes(shape, TopAbs_SOLID)),
        "volume_mm3": round(props.Mass(), 2),
        "bbox_size": [round(v, 3) for v in (x1 - x0, y1 - y0, z1 - z0)],
        "bbox_min": [round(v, 3) for v in (x0, y0, z0)],
        "centroid": [round(v, 3) for v in (c.X(), c.Y(), c.Z())],
        "faces": dict(kinds),
        "cylinder_radii": {str(k): v for k, v in sorted(radii.items())},
    }


if __name__ == "__main__":
    r = report(sys.argv[1])
    out = json.dumps(r, indent=2)
    if len(sys.argv) > 2:
        open(sys.argv[2], "w").write(out)
    print(out)
