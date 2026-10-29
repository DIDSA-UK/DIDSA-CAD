"""A Part as a 3rd angle orthographic line drawing (PNG): front, top (above
it), right (to its right) and an isometric view (top right), with hidden
edges dashed - see `docs/ai-modelling/14-render-back-check.md`.

Built for AI Modelling's render-back check: a vision model compares this
drawing with the user's hand sketch, so it is drawn the way a sketch is
(hidden-line-removed edges, no shading) rather than as a viewport render.
Uses OCCT's HLR on the exact B-rep - no GL context - and writes the PNG
itself (stdlib `zlib`), so it needs no new dependency.

Views look at world axes: front from -Y (right = +X, up = +Z), top from +Z
(right = +X, up = +Y), right from +X (right = +Y, up = +Z). All three
orthographic views share one scale; the isometric view gets its own.
"""

import struct
import zlib
from dataclasses import dataclass

from OCC.Core.BRep import BRep_Builder, BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.GCPnts import GCPnts_QuasiUniformDeflection
from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Pnt
from OCC.Core.HLRAlgo import HLRAlgo_Projector
from OCC.Core.HLRBRep import HLRBRep_Algo, HLRBRep_HLRToShape
from OCC.Core.TopAbs import TopAbs_EDGE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, topods

Polyline = list[tuple[float, float]]

# (view direction towards the viewer, screen-right direction)
_VIEWS: dict[str, tuple[tuple[float, float, float], tuple[float, float, float]]] = {
    "front": ((0.0, -1.0, 0.0), (1.0, 0.0, 0.0)),
    "top": ((0.0, 0.0, 1.0), (1.0, 0.0, 0.0)),
    "right": ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0)),
    "iso": ((1.0, -1.0, 1.0), (1.0, 1.0, 0.0)),
}


@dataclass
class ProjectedView:
    visible: list[Polyline]
    hidden: list[Polyline]

    def bounds(self) -> tuple[float, float, float, float]:
        points = [p for line in self.visible + self.hidden for p in line]
        if not points:
            return (0.0, 0.0, 0.0, 0.0)
        xs, ys = [p[0] for p in points], [p[1] for p in points]
        return (min(xs), min(ys), max(xs), max(ys))


def _compound(shapes: list[TopoDS_Shape]) -> TopoDS_Compound:
    compound = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(compound)
    for shape in shapes:
        builder.Add(compound, shape)
    return compound


def _polylines(shape: TopoDS_Shape | None, deflection: float) -> list[Polyline]:
    """Every edge of an HLR output compound as a 2D polyline (HLR writes its
    result in the projection plane, so x/y are the view's own coordinates)."""
    if shape is None or shape.IsNull():
        return []
    lines: list[Polyline] = []
    explorer = TopExp_Explorer(shape, TopAbs_EDGE)
    while explorer.More():
        edge = topods.Edge(explorer.Current())
        explorer.Next()
        if BRep_Tool.Degenerated(edge):
            continue
        curve = BRepAdaptor_Curve(edge)
        sampler = GCPnts_QuasiUniformDeflection(curve, deflection)
        if not sampler.IsDone() or sampler.NbPoints() < 2:
            continue
        line = []
        for i in range(1, sampler.NbPoints() + 1):
            point = sampler.Value(i)
            line.append((point.X(), point.Y()))
        lines.append(line)
    return lines


def project(shape: TopoDS_Shape, view: str, deflection: float) -> ProjectedView:
    toward_viewer, right = _VIEWS[view]
    algo = HLRBRep_Algo()
    algo.Add(shape)
    algo.Projector(HLRAlgo_Projector(gp_Ax2(gp_Pnt(0.0, 0.0, 0.0), gp_Dir(*toward_viewer), gp_Dir(*right))))
    algo.Update()
    algo.Hide()
    out = HLRBRep_HLRToShape(algo)
    # Sharp edges, outlines (silhouettes of curved faces) and smooth seams
    # that are sharp enough to draw (Rg1Line) - the edges a draughtsman draws.
    visible = []
    for getter in (out.VCompound, out.OutLineVCompound, out.Rg1LineVCompound):
        visible += _polylines(getter(), deflection)
    hidden = []
    for getter in (out.HCompound, out.OutLineHCompound):
        hidden += _polylines(getter(), deflection)
    return ProjectedView(visible=visible, hidden=hidden)


class _Canvas:
    def __init__(self, width: int, height: int) -> None:
        self.width, self.height = width, height
        self.pixels = bytearray([255]) * (width * height)

    def _dot(self, x: int, y: int, shade: int, radius: int) -> None:
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                px, py = x + dx, y + dy
                if 0 <= px < self.width and 0 <= py < self.height:
                    index = py * self.width + px
                    self.pixels[index] = min(self.pixels[index], shade)

    def line(self, a: tuple[float, float], b: tuple[float, float], shade: int, radius: int, dash: int = 0) -> None:
        steps = max(1, int(max(abs(b[0] - a[0]), abs(b[1] - a[1]))))
        for i in range(steps + 1):
            if dash and (i // dash) % 2 == 1:
                continue
            t = i / steps
            self._dot(round(a[0] + (b[0] - a[0]) * t), round(a[1] + (b[1] - a[1]) * t), shade, radius)

    def png(self) -> bytes:
        rows = b"".join(b"\x00" + bytes(self.pixels[y * self.width : (y + 1) * self.width]) for y in range(self.height))

        def chunk(kind: bytes, data: bytes) -> bytes:
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

        header = struct.pack(">IIBBBBB", self.width, self.height, 8, 0, 0, 0, 0)  # 8-bit greyscale
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def render_line_drawing(shapes: list[TopoDS_Shape], width: int = 1400, height: int = 1000) -> bytes:
    """PNG of `shapes` (a Part's Bodies) laid out in 3rd angle projection:
    top view above the front view, right view to its right, isometric top
    right. Raises ValueError for empty geometry."""
    shape = _compound(shapes)
    probe = project(shape, "front", 1.0)
    x0, y0, x1, y1 = probe.bounds()
    size = max(x1 - x0, y1 - y0, 1e-6)
    deflection = size / 400.0
    views = {name: project(shape, name, deflection) for name in _VIEWS}
    if not any(view.visible for view in views.values()):
        raise ValueError("nothing to draw")

    def extent(name: str) -> tuple[float, float]:
        bx0, by0, bx1, by1 = views[name].bounds()
        return bx1 - bx0, by1 - by0

    front_w, front_h = extent("front")
    top_w, top_h = extent("top")
    right_w, right_h = extent("right")
    gap_fraction = 0.12
    model_gap = gap_fraction * max(front_w, front_h, top_h, right_w, 1e-6)
    columns = max(front_w, top_w) + model_gap + right_w
    rows = top_h + model_gap + front_h
    margin = 40
    scale = min((width - 2 * margin) / max(columns, 1e-6), (height - 2 * margin) / max(rows, 1e-6))

    canvas = _Canvas(width, height)

    def place(view: ProjectedView, left: float, top: float, view_scale: float) -> None:
        bx0, _, _, by1 = view.bounds()
        to_px = lambda p: (left + (p[0] - bx0) * view_scale, top + (by1 - p[1]) * view_scale)  # noqa: E731
        for line in view.hidden:
            for a, b in zip(line, line[1:]):
                canvas.line(to_px(a), to_px(b), shade=140, radius=0, dash=6)
        for line in view.visible:
            for a, b in zip(line, line[1:]):
                canvas.line(to_px(a), to_px(b), shade=0, radius=1)

    front_left = margin
    front_top = margin + (top_h + model_gap) * scale
    place(views["front"], front_left, front_top, scale)
    place(views["top"], front_left, margin, scale)
    place(views["right"], front_left + (max(front_w, top_w) + model_gap) * scale, front_top, scale)

    iso_w, iso_h = extent("iso")
    box_left = front_left + (max(front_w, top_w) + model_gap) * scale
    box_w, box_h = width - margin - box_left, front_top - margin - model_gap * scale * 0.5
    if box_w > 20 and box_h > 20:
        iso_scale = min(box_w / max(iso_w, 1e-6), box_h / max(iso_h, 1e-6), scale)
        place(views["iso"], box_left + (box_w - iso_w * iso_scale) / 2, margin, iso_scale)
    return canvas.png()


def bounding_box_size(shapes: list[TopoDS_Shape]) -> tuple[float, float, float]:
    from OCC.Core.Bnd import Bnd_Box
    from OCC.Core.BRepBndLib import brepbndlib

    box = Bnd_Box()
    box.SetGap(0.0)
    for shape in shapes:
        brepbndlib.AddOptimal(shape, box, False, False)
    x0, y0, z0, x1, y1, z1 = box.Get()
    return (x1 - x0, y1 - y0, z1 - z0)

