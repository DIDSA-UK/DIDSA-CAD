"""Reference models for the AI-eval assembly sketches (tools/ai_eval/sketches/source/README.md).

Builds every part and assembly with OpenCascade, then writes:
  views.json  - hidden-line projections (visible / hidden polylines, hatched section faces) for draw.py
  keys.json   - geometry of every part and assembly, the source of the answer keys in expected.py
  step/*.step - each part and assembly, for reference

Run with the backend's conda python:  $CAD_PY -I models.py <out_dir>
Units mm, Z up. Third-angle views: front looks along +Y (u=X, v=Z), top looks down (u=X, v=Y),
right looks along -X (u=Y, v=Z).
"""
import json
import math
import os
import sys

from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepBuilderAPI import (BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakePolygon,
                                     BRepBuilderAPI_Transform)
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakePrism
from OCC.Core.BRepTools import BRepTools_WireExplorer
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.GCPnts import GCPnts_QuasiUniformDeflection
from OCC.Core.GeomAbs import GeomAbs_Cylinder, GeomAbs_Plane
from OCC.Core.GProp import GProp_GProps
from OCC.Core.HLRAlgo import HLRAlgo_Projector
from OCC.Core.HLRBRep import HLRBRep_Algo, HLRBRep_HLRToShape
from OCC.Core.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
from OCC.Core.STEPControl import STEPControl_AsIs, STEPControl_Writer
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_SOLID, TopAbs_WIRE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Compound, topods
from OCC.Core.gp import gp_Ax1, gp_Ax2, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec

X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)


# ---------------------------------------------------------------- primitives
def box(x0, y0, z0, dx, dy, dz):
    return BRepPrimAPI_MakeBox(gp_Pnt(x0, y0, z0), dx, dy, dz).Shape()


def cyl(p, d, r, h):
    return BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(*p), gp_Dir(*d)), r, h).Shape()


def fuse(*s):
    out = s[0]
    for t in s[1:]:
        out = BRepAlgoAPI_Fuse(out, t).Shape()
    return out


def cut(a, *s):
    for t in s:
        a = BRepAlgoAPI_Cut(a, t).Shape()
    return a


def prism(pts, vec):
    poly = BRepBuilderAPI_MakePolygon()
    for p in pts:
        poly.Add(gp_Pnt(*p))
    poly.Close()
    return BRepPrimAPI_MakePrism(BRepBuilderAPI_MakeFace(poly.Wire()).Face(), gp_Vec(*vec)).Shape()


def hex_x(af, x0, length, r_hole=0.0):
    """Hex prism along +X from x0, across flats `af`, flats top and bottom (parallel to Y)."""
    rc = af / math.sqrt(3)
    pts = [(x0, rc * math.cos(math.radians(a)), rc * math.sin(math.radians(a))) for a in range(0, 360, 60)]
    s = prism(pts, (length, 0, 0))
    if r_hole:
        s = cut(s, cyl((x0 - 1, 0, 0), X, r_hole, length + 2))
    return s


def moved(shape, dx=0, dy=0, dz=0, rot=None):
    t = gp_Trsf()
    if rot:
        axis, deg = rot
        t.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(*axis)), math.radians(deg))
    t2 = gp_Trsf()
    t2.SetTranslation(gp_Vec(dx, dy, dz))
    t2.Multiply(t)
    return BRepBuilderAPI_Transform(shape, t2, True).Shape()


def compound(shapes):
    c = TopoDS_Compound()
    b = BRep_Builder()
    b.MakeCompound(c)
    for s in shapes:
        b.Add(c, s)
    return c


def explore(shape, kind):
    e = TopExp_Explorer(shape, kind)
    while e.More():
        yield e.Current()
        e.Next()


# ---------------------------------------------------------------- parts
# Every part is built in the orientation it has in its assembly, about its own origin.
P = {}

# A: locating pin assembly (2 parts)
P["A1"] = ("BASE BLOCK", cut(box(-40, -25, 0, 80, 50, 20), cyl((0, 0, -1), Z, 10, 22)))
P["A2"] = ("LOCATING PIN", fuse(cyl((0, 0, 0), Z, 10, 40), cyl((0, 0, 40), Z, 16, 6)))

# B: wheel bracket (4 parts, 5 components)
P["B1"] = ("BASE PLATE", cut(box(-70, -40, 0, 140, 80, 10),
                             *[cyl((sx * 55, sy * 25, -1), Z, 4.5, 12) for sx in (-1, 1) for sy in (-1, 1)]))
P["B2"] = ("UPRIGHT", cut(fuse(box(0, -40, 0, 10, 80, 60), cyl((0, 0, 60), X, 40, 10)),
                          cyl((-1, 0, 60), X, 6, 12)))
P["B3"] = ("AXLE", cyl((-40, 0, 0), X, 6, 80))
P["B4"] = ("WHEEL", cut(cyl((-15, 0, 0), X, 35, 30), cyl((-16, 0, 0), X, 6, 32)))

# C: swivel caster (8 parts; wheel + bushing are the WHEEL ASSY sub-assembly)
P["C1"] = ("TOP PLATE", cut(box(-50, -50, 0, 100, 100, 6), cyl((0, 0, -1), Z, 6, 8),
                            *[cyl((sx * 40, sy * 40, -1), Z, 4.5, 8) for sx in (-1, 1) for sy in (-1, 1)]))
P["C2"] = ("SWIVEL WASHER", cut(cyl((0, 0, 0), Z, 20, 3), cyl((0, 0, -1), Z, 6, 5)))
P["C3"] = ("KINGPIN", fuse(cyl((0, 0, 0), Z, 6, 16), cyl((0, 0, 16), Z, 10, 4)))
_leg = lambda x0: cut(fuse(box(x0, -25, -65, 4, 50, 61), cyl((x0, 0, -65), X, 25, 4)), cyl((x0 - 1, 0, -65), X, 5, 6))
P["C4"] = ("FORK", cut(fuse(box(-21, -25, -4, 42, 50, 4), _leg(-21), _leg(17)), cyl((0, 0, -5), Z, 6, 6)))
P["C5"] = ("WHEEL", cut(cyl((-15, 0, 0), X, 50, 30), cyl((-16, 0, 0), X, 8, 32),
                        cyl((-16, 0, 0), X, 30, 5), cyl((11, 0, 0), X, 30, 5)))
P["C6"] = ("BUSHING", cut(cyl((-17, 0, 0), X, 8, 34), cyl((-18, 0, 0), X, 5, 36)))
P["C7"] = ("AXLE BOLT", fuse(hex_x(16, 0, 7), cyl((-55, 0, 0), X, 5, 55)))
P["C8"] = ("HEX NUT", hex_x(16, 0, 8, r_hole=5))

# D: the owner's hand sketch "block with four pins" (asm_block_pins.jpg), as read for its answer key
P["D1"] = ("BLOCK", cut(box(-80, -40, 0, 160, 80, 30),
                        *[cyl((sx * 60, sy * 20, -1), Z, 5, 32) for sx in (-1, 1) for sy in (-1, 1)]))
P["D2"] = ("PIN", fuse(cyl((0, 0, 0), Z, 5, 30), cyl((0, 0, 30), Z, 15, 10)))

def unify(shape):
    u = ShapeUpgrade_UnifySameDomain(shape, True, True, False)
    u.Build()
    return u.Shape()


P = {k: (n, unify(s)) for k, (n, s) in P.items()}

# ---------------------------------------------------------------- assemblies (component placements)
ASM = {
    "A": [("A1", (0, 0, 0)), ("A2", (0, 0, -20))],
    "B": [("B1", (0, 0, 0)), ("B2", (20, 0, 10)), ("B2", (-30, 0, 10)), ("B3", (0, 0, 70)), ("B4", (0, 0, 70))],
    "D": [("D1", (0, 0, 0))] + [("D2", (sx * 60, sy * 20, 0)) for sx in (-1, 1) for sy in (-1, 1)],
    "C_SUB": [("C5", (0, 0, 0)), ("C6", (0, 0, 0))],
    "C": [("C1", (0, 0, 0)), ("C2", (0, 0, -3)), ("C3", (0, 0, -10)), ("C4", (0, 0, -3)),
          ("C_SUB", (0, 0, -68)), ("C7", (21, 0, -68)), ("C8", (-29, 0, -68))],
}


def placed(name, off=(0, 0, 0)):
    """[(part_id, shape)] for a part or a (sub-)assembly placed at `off`."""
    if name in P:
        return [(name, moved(P[name][1], *off))]
    out = []
    for child, o in ASM[name]:
        out += placed(child, tuple(a + b for a, b in zip(off, o)))
    return out


# ---------------------------------------------------------------- geometry report
def geometry(shape):
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    bb = Bnd_Box()
    bb.SetGap(0)
    brepbndlib.AddOptimal(shape, bb, False, False)
    x0, y0, z0, x1, y1, z1 = bb.Get()
    radii = set()
    for f in explore(shape, TopAbs_FACE):
        s = BRepAdaptor_Surface(topods.Face(f))
        if s.GetType() == GeomAbs_Cylinder:
            radii.add(round(s.Cylinder().Radius(), 3))
    c = props.CentreOfMass()
    return {"solids": sum(1 for _ in explore(shape, TopAbs_SOLID)), "volume": round(props.Mass(), 2),
            "bbox": [round(v, 3) for v in (x1 - x0, y1 - y0, z1 - z0)],
            "bbox_min": [round(v, 3) for v in (x0, y0, z0)],
            "centroid": [round(v, 3) for v in (c.X(), c.Y(), c.Z())], "radii": sorted(radii)}


# ---------------------------------------------------------------- projections
VIEWS = {
    "front": ((0, -1, 0), (1, 0, 0)),
    "top": ((0, 0, 1), (1, 0, 0)),
    "right": ((1, 0, 0), (0, 1, 0)),
    "left": ((-1, 0, 0), (0, -1, 0)),
    "back": ((0, 1, 0), (-1, 0, 0)),
    "iso": ((1, -1, 1), (1, 1, 0)),
}


def polylines(compound_shape, ax2=None):
    out = []
    if compound_shape is None or compound_shape.IsNull():
        return out
    for e in explore(compound_shape, TopAbs_EDGE):
        edge = topods.Edge(e)
        try:
            c = BRepAdaptor_Curve(edge)
        except Exception:
            continue
        d = GCPnts_QuasiUniformDeflection(c, 0.02)
        if not d.IsDone():
            continue
        pts = [d.Value(i) for i in range(1, d.NbPoints() + 1)]
        out.append([[round(p.X(), 3), round(p.Y(), 3)] for p in pts])
    return out


def project(shapes, view, hidden=True):
    d, x = VIEWS[view]
    algo = HLRBRep_Algo()
    for s in shapes:
        algo.Add(s)
    algo.Projector(HLRAlgo_Projector(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(*d), gp_Dir(*x))))
    algo.Update()
    algo.Hide()
    h = HLRBRep_HLRToShape(algo)
    vis = polylines(h.VCompound()) + polylines(h.OutLineVCompound())
    hid = (polylines(h.HCompound()) + polylines(h.OutLineHCompound())) if hidden else []
    return {"vis": vis, "hid": hid}


def section_faces(shape, view, coord):
    """Faces of `shape` lying on the section plane (world axis of the view direction = coord),
    as projected polygon loops."""
    d, x = VIEWS[view]
    ax = [i for i in range(3) if d[i] != 0][0]
    dv, xv = gp_Dir(*d), gp_Dir(*x)
    yv = dv.Crossed(xv)
    faces = []
    for f in explore(shape, TopAbs_FACE):
        s = BRepAdaptor_Surface(topods.Face(f))
        if s.GetType() != GeomAbs_Plane:
            continue
        pl = s.Plane()
        if abs(abs(pl.Axis().Direction().Dot(dv)) - 1) > 1e-6:
            continue
        o = pl.Location()
        if abs((o.X(), o.Y(), o.Z())[ax] - coord) > 1e-4:
            continue
        loops = []
        for w in explore(f, TopAbs_WIRE):
            pts = []
            we = BRepTools_WireExplorer(topods.Wire(w), topods.Face(f))
            while we.More():
                g = GCPnts_QuasiUniformDeflection(BRepAdaptor_Curve(we.Current()), 0.02)
                ps = [g.Value(i) for i in range(1, g.NbPoints() + 1)]
                if we.Orientation() == 1:  # TopAbs_REVERSED
                    ps = ps[::-1]
                pts += [[round(gp_Vec(p.XYZ()).Dot(gp_Vec(xv)), 3), round(gp_Vec(p.XYZ()).Dot(gp_Vec(yv)), 3)] for p in ps]
                we.Next()
            loops.append(pts)
        faces.append(loops)
    return faces


def section(parts, view, coord, uncut=()):
    """Section on the plane (view axis = coord), the half toward the viewer removed. Parts in `uncut`
    (pins, shafts, bolts, by convention) are shown whole and not hatched."""
    d = VIEWS[view][0]
    ax = [i for i in range(3) if d[i] != 0][0]
    big = 1000.0
    lo = [-big] * 3
    size = [2 * big] * 3
    lo[ax] = coord if d[ax] > 0 else coord - big
    size[ax] = big
    keep, hatch = [], []
    for pid, s in parts:
        if pid in uncut:
            keep.append(s)
            continue
        c = cut(s, box(*lo, *size))
        keep.append(c)
        hatch.append({"part": pid, "faces": section_faces(c, view, coord)})
    out = project(keep, view, hidden=False)
    out["hatch"] = hatch
    return out


def iso_points(points):
    d, x = VIEWS["iso"]
    dv, xv = gp_Dir(*d), gp_Dir(*x)
    yv = dv.Crossed(xv)
    return [[round(gp_Vec(*p).Dot(gp_Vec(xv)), 3), round(gp_Vec(*p).Dot(gp_Vec(yv)), 3)] for p in points]


def main(out):
    os.makedirs(os.path.join(out, "step"), exist_ok=True)
    keys = {"parts": {}, "assemblies": {}}
    for pid, (name, s) in P.items():
        keys["parts"][pid] = {"name": name, **geometry(s)}
        w = STEPControl_Writer()
        w.Transfer(s, STEPControl_AsIs)
        w.Write(os.path.join(out, "step", f"{pid}.step"))
    for a in ASM:
        pl = placed(a)
        comp = compound([s for _, s in pl])
        union = pl[0][1]
        for _, s2 in pl[1:]:
            union = BRepAlgoAPI_Fuse(union, s2).Shape()
        keys["assemblies"][a] = {
            "union_volume": geometry(union)["volume"],
            "components": [[pid, geometry(s)["centroid"], geometry(s)["volume"]] for pid, s in pl],
            **{k: v for k, v in geometry(comp).items() if k in ("bbox", "bbox_min", "volume")},
        }
        w = STEPControl_Writer()
        w.Transfer(comp, STEPControl_AsIs)
        w.Write(os.path.join(out, "step", f"ASM_{a}.step"))

    V = {}
    part = lambda pid: [P[pid][1]]
    shapes = lambda a: [s for _, s in placed(a)]
    # A
    V["A1_top"] = project(part("A1"), "top")
    V["A1_front"] = project(part("A1"), "front")
    V["A2_front"] = project(part("A2"), "front")
    V["A2_top"] = project(part("A2"), "top")
    V["A_sec"] = section(placed("A"), "front", 0.0, uncut=("A2",))
    V["A_iso"] = project(shapes("A"), "iso", hidden=False)
    # B
    for v in ("front", "right", "top", "iso"):
        V[f"B_{v}"] = project(shapes("B"), v, hidden=False)
    V["B1_top"] = project(part("B1"), "top")
    V["B1_front"] = project(part("B1"), "front")
    V["B2_right"] = project(part("B2"), "right")
    V["B2_front"] = project(part("B2"), "front")
    V["B3_front"] = project(part("B3"), "front")
    V["B4_front"] = project(part("B4"), "front")
    V["B4_right"] = project(part("B4"), "right")
    # C
    for v in ("front", "right", "top", "iso"):
        V[f"C_{v}"] = project(shapes("C"), v, hidden=False)
    V["CS_sec"] = section(placed("C_SUB"), "back", 0.0)
    V["CS_right"] = project(shapes("C_SUB"), "right", hidden=False)
    V["CS_iso"] = project(shapes("C_SUB"), "iso", hidden=False)
    V["C1_top"] = project(part("C1"), "top")
    V["C1_front"] = project(part("C1"), "front")
    V["C2_top"] = project(part("C2"), "top")
    V["C2_front"] = project(part("C2"), "front")
    V["C3_front"] = project(part("C3"), "front")
    V["C3_top"] = project(part("C3"), "top")
    V["C4_front"] = project(part("C4"), "front")
    V["C4_right"] = project(part("C4"), "right")
    V["C4_top"] = project(part("C4"), "top")
    V["C7_front"] = project(part("C7"), "front")
    V["C7_right"] = project(part("C7"), "right")
    V["C8_front"] = project(part("C8"), "front")
    V["C8_right"] = project(part("C8"), "right")
    # balloon anchor points on the iso views (3D points on each component's surface)
    V["iso_pts"] = {
        "A": iso_points([(30, -25, 10), (-12, -10, 23)]),
        "B": iso_points([(60, -40, 5), (30, -20, 30), (-25, 0, 110), (40, 0, 70), (5, -30.31, 52.5)]),
        "C": iso_points([(45, -50, 3), (17, -10, -1.5), (-6, 0, 10), (21, -20, -40), (3, -30, -100), (28, 4, -68), (-29, -6, -64)]),
        "CS": iso_points([(13, -30, -30), (17, -6, 5)]),
    }
    json.dump(V, open(os.path.join(out, "views.json"), "w"))
    json.dump(keys, open(os.path.join(out, "keys.json"), "w"), indent=1)
    print(json.dumps(keys, indent=1))


if __name__ == "__main__":
    main(sys.argv[1])
