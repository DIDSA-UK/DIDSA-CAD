"""Reads one STEP / IGES file the way the backend's import does and prints a short report of what is wrong with the geometry, so a file too big to send
can still be looked at. Prints no model data: only counts, sizes, validity and the product names.

Run it from this folder, in the backend's environment (the one the server runs in):

    python diagnose_import.py "C:\\path\\to\\file.step"

and send back everything it prints (it also writes the same text to <file>.diagnosis.txt)."""

import collections
import faulthandler
import math
import os
import sys
import time

faulthandler.enable()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepCheck import BRepCheck_Analyzer, BRepCheck_ListOfStatus
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRep import BRep_Tool
from OCC.Core.GProp import GProp_GProps
from OCC.Core.ShapeAnalysis import ShapeAnalysis_FreeBounds
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_SHELL, TopAbs_SOLID, TopAbs_WIRE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import topods

from app.document import import_geometry as ig

LINES: list[str] = []


def _status_names() -> dict:
    import OCC.Core.BRepCheck as bc

    return {int(v): k[len("BRepCheck_"):] for k, v in vars(bc).items() if k.startswith("BRepCheck_") and isinstance(v, int)}


STATUS = _status_names()


def say(text: str = "") -> None:
    print(text, flush=True)
    LINES.append(text)


def count(shape, kind) -> int:
    explorer, n = TopExp_Explorer(shape, kind), 0
    while explorer.More():
        n += 1
        explorer.Next()
    return n


SURFACE_NAMES = {0: "plane", 1: "cylinder", 2: "cone", 3: "sphere", 4: "torus", 5: "bezier", 6: "bspline", 7: "revolution", 8: "extrusion", 9: "offset"}


def pieces_report(shape) -> None:
    """Every separate piece after the importer's own sewing (a solid, else a shell), and every piece that holds a sphere or a torus, with where it is and how big."""
    kind = TopAbs_SOLID if count(shape, TopAbs_SOLID) else TopAbs_SHELL
    pieces = []
    explorer = TopExp_Explorer(shape, kind)
    while explorer.More():
        piece = explorer.Current()
        box = Bnd_Box()
        brepbndlib.Add(piece, box)
        x0, y0, z0, x1, y1, z1 = box.Get()
        types = collections.Counter()
        area = 0.0
        faces = TopExp_Explorer(piece, TopAbs_FACE)
        while faces.More():
            face = topods.Face(faces.Current())
            types[SURFACE_NAMES.get(int(BRepAdaptor_Surface(face).GetType()), "?")] += 1
            props = GProp_GProps()
            brepgprop.SurfaceProperties(face, props)
            area += props.Mass()
            faces.Next()
        pieces.append((sum(types.values()), area, ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), (x1 - x0, y1 - y0, z1 - z0), types))
        explorer.Next()
    pieces.sort(key=lambda p: -p[1])
    say(f"pieces after sewing: {len(pieces)} ({'solids' if kind == TopAbs_SOLID else 'shells'}); the largest few by area:")
    for faces_n, area, c, size, types in pieces[:6]:
        say(f"  faces {faces_n:4d} area {area:9.1f} centre ({c[0]:.1f}, {c[1]:.1f}, {c[2]:.1f}) size ({size[0]:.1f}, {size[1]:.1f}, {size[2]:.1f}) {dict(types)}")
    round_pieces = [p for p in pieces if p[4].get("sphere") or p[4].get("torus")]
    say(f"pieces holding a sphere or a torus: {len(round_pieces)} (smallest first, at most 25)")
    for faces_n, area, c, size, types in sorted(round_pieces, key=lambda p: p[1])[:25]:
        say(f"  faces {faces_n:4d} area {area:9.1f} centre ({c[0]:.1f}, {c[1]:.1f}, {c[2]:.1f}) size ({size[0]:.1f}, {size[1]:.1f}, {size[2]:.1f}) {dict(types)}")


def round_faces_report(shape) -> None:
    """Every sphere and torus face: how much of the whole surface it covers and how many trim loops it has. A face that should be trimmed (a knob cut out of a
    sphere) but covers ~100 % of its surface with one loop has lost its trimming."""
    from OCC.Core.BRepTools import breptools

    rows = []
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while explorer.More():
        face = topods.Face(explorer.Current())
        adaptor = BRepAdaptor_Surface(face)
        kind = int(adaptor.GetType())
        if kind in (3, 4):
            props = GProp_GProps()
            brepgprop.SurfaceProperties(face, props)
            if kind == 3:
                radius = adaptor.Sphere().Radius()
                full, label = 4 * math.pi * radius**2, f"sphere r={radius:.2f}"
            else:
                big, small = adaptor.Torus().MajorRadius(), adaptor.Torus().MinorRadius()
                full, label = 4 * math.pi**2 * big * small, f"torus R={big:.2f} r={small:.2f}"
            u0, u1, v0, v1 = breptools.UVBounds(face)
            wires = count(face, TopAbs_WIRE)
            box = Bnd_Box()
            brepbndlib.Add(face, box)
            x0, y0, z0, x1, y1, z1 = box.Get()
            rows.append((props.Mass() / full, label, wires, count(face, TopAbs_EDGE), (u1 - u0) / (2 * math.pi), ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)))
        explorer.Next()
    spheres = [r for r in rows if r[1].startswith("sphere")]
    say(f"sphere faces: {len(spheres)}, torus faces: {len(rows) - len(spheres)}")
    say("  covers = share of the whole surface (100% with one loop = no trimming); loops = trim wires; edges; u-span = share of the full turn")
    for covers, label, wires, edges, uspan, c in sorted(rows, key=lambda r: -r[0])[:30]:
        say(f"  {label:26s} covers {100 * covers:6.1f}%  loops {wires}  edges {edges:3d}  u-span {100 * uspan:5.1f}%  centre ({c[0]:.1f}, {c[1]:.1f}, {c[2]:.1f})")


def main(path: str) -> None:
    data = open(path, "rb").read()
    is_iges = path.lower().endswith((".igs", ".iges"))
    say(f"file: {os.path.basename(path)}  {len(data) / 1e6:.1f} MB  format: {'IGES' if is_iges else 'STEP'}")
    head = data[:4000].decode("latin-1", "ignore")
    for line in head.splitlines():
        if any(k in line.upper() for k in ("FILE_SCHEMA", "FILE_NAME", "FILE_DESCRIPTION", "ORIGINATING", "PREPROCESSOR")):
            say("  " + line.strip()[:160])

    from app.document import step_assembly

    try:
        probe = (step_assembly.probe_iges if is_iges else step_assembly.probe_step)(data)
        say(f"probe: {probe}")
    except Exception as exc:  # noqa: BLE001 - a diagnostic reports, it does not stop
        say(f"probe failed: {type(exc).__name__}: {exc}")

    t = time.time()
    shape = (ig._shape_from_iges if is_iges else ig._shape_from_step)(data)
    say(f"import: {time.time() - t:.1f} s  top shape type {shape.ShapeType()} (0 compound, 2 solid, 3 shell, 4 face)")
    solids, shells, faces, edges = (count(shape, k) for k in (TopAbs_SOLID, TopAbs_SHELL, TopAbs_FACE, TopAbs_EDGE))
    say(f"counts: solids {solids}  shells {shells}  faces {faces}  edges {edges}")
    say(f"has a closed solid: {ig.shape_has_solid(shape)}")
    box = Bnd_Box()
    brepbndlib.Add(shape, box)
    if not box.IsVoid():
        x0, y0, z0, x1, y1, z1 = box.Get()
        say(f"size mm: {x1 - x0:.2f} x {y1 - y0:.2f} x {z1 - z0:.2f}  diagonal {math.dist((x0, y0, z0), (x1, y1, z1)):.2f}")

    say(f"valid overall (BRepCheck): {BRepCheck_Analyzer(shape).IsValid()}")

    # which faces / edges / solids fail BRepCheck, and how
    bad = collections.Counter()
    analyzer = BRepCheck_Analyzer(shape)
    for kind, name in ((TopAbs_FACE, "face"), (TopAbs_EDGE, "edge"), (TopAbs_SHELL, "shell"), (TopAbs_SOLID, "solid")):
        explorer = TopExp_Explorer(shape, kind)
        while explorer.More():
            sub = explorer.Current()
            result = analyzer.Result(sub)
            if result is not None:
                statuses = result.Status()
                for status in statuses:
                    if int(status) != 0:
                        bad[f"{name}: {STATUS.get(int(status), int(status))}"] += 1
            explorer.Next()
    if bad:
        say("BRepCheck problems (count of faces / edges / shells / solids affected):")
        for key, n in bad.most_common(15):
            say(f"  {n:6d}  {key}")
    else:
        say("BRepCheck problems: none")

    surfaces = collections.Counter()
    tiny = 0
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while explorer.More():
        face = topods.Face(explorer.Current())
        surfaces[str(BRepAdaptor_Surface(face).GetType()).split("_")[-1]] += 1
        props = GProp_GProps()
        brepgprop.SurfaceProperties(face, props)
        if props.Mass() < 1e-6:
            tiny += 1
        explorer.Next()
    say(f"face surface types (GeomAbs codes: 0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus, 5 Bezier, 6 B-spline, 7 revolution, 8 extrusion, 9 offset): {dict(surfaces)}   faces with ~zero area: {tiny}")

    # free (unconnected) boundary edges: a closed solid has none
    try:
        free = ShapeAnalysis_FreeBounds(shape)
        say(f"open boundary wires: closed {count(free.GetClosedWires(), TopAbs_EDGE)} edges, open {count(free.GetOpenWires(), TopAbs_EDGE)} edges")
    except Exception as exc:  # noqa: BLE001
        say(f"free bounds failed: {exc}")

    max_tol = 0.0
    explorer = TopExp_Explorer(shape, TopAbs_EDGE)
    while explorer.More():
        max_tol = max(max_tol, BRep_Tool.Tolerance(topods.Edge(explorer.Current())))
        explorer.Next()
    say(f"largest edge tolerance: {max_tol:.4f} mm")

    if solids:
        total = 0.0
        explorer = TopExp_Explorer(shape, TopAbs_SOLID)
        while explorer.More():
            props = GProp_GProps()
            brepgprop.VolumeProperties(explorer.Current(), props)
            total += props.Mass()
            explorer.Next()
        say(f"total solid volume: {total:.1f} mm3")

    pieces_report(shape)
    round_faces_report(shape)

    say("meshing (this is where a crash would show)...")
    from app.document import mesh as mesh_module
    from app.document.mesh_data import DEFAULT_MESH_QUALITY

    t = time.time()
    mesh = mesh_module.tessellate_shape(shape, DEFAULT_MESH_QUALITY)
    say(f"mesh ok: {len(mesh.triangles)} triangles, {time.time() - t:.1f} s")
    say("done")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    try:
        main(sys.argv[1])
    finally:
        try:
            open(sys.argv[1] + ".diagnosis.txt", "w").write("\n".join(LINES))
        except OSError:
            pass
