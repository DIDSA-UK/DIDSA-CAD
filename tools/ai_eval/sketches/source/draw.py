"""Draws the AI-eval assembly sketches from models.py's views.json (tools/ai_eval/sketches/source/README.md).

Usage: python draw.py <views.json> <out_dir>    (needs matplotlib and Pillow)
Each sheet is A3 landscape, drawn in paper millimetres, then saved at 1568 px on the long edge, as the app
downscales an attached image.
"""
import json
import math
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Circle, PathPatch, Polygon
from matplotlib.path import Path
from PIL import Image

plt.rcParams["hatch.linewidth"] = 0.5
plt.rcParams["font.family"] = "DejaVu Sans"
W, H = 420.0, 297.0
LW_VIS, LW_THIN = 1.1, 0.45
TXT = 9.5  # pt
V = {}


class Sheet:
    def __init__(self, title, dwg_no, sheet, scale):
        self.fig = plt.figure(figsize=(W / 25.4, H / 25.4))
        self.ax = self.fig.add_axes([0, 0, 1, 1])
        self.ax.set_xlim(0, W)
        self.ax.set_ylim(0, H)
        self.ax.set_aspect("equal")
        self.ax.axis("off")
        self.fig.patch.set_facecolor("white")
        a = self.ax
        a.add_patch(plt.Rectangle((10, 10), W - 20, H - 20, fill=False, lw=1.4))
        self.title_block(title, dwg_no, sheet, scale)

    def line(self, pts, lw=LW_THIN, ls="-", **k):
        xs, ys = zip(*pts)
        self.ax.plot(xs, ys, color="black", lw=lw, ls=ls, solid_capstyle="butt", **k)

    def text(self, x, y, s, size=TXT, ha="center", va="center", rot=0, **k):
        self.ax.text(x, y, s, fontsize=size, ha=ha, va=va, rotation=rot, **k)

    def title_block(self, title, dwg_no, sheet, scale):
        x0, y0, w = 250, 10, 160
        rows = [(y0, 9), (y0 + 9, 9), (y0 + 18, 9), (y0 + 27, 13)]
        for y, h in rows:
            self.ax.add_patch(plt.Rectangle((x0, y), w, h, fill=False, lw=1.0))
        self.text(x0 + 2, y0 + 33.5, title, size=12, ha="left", weight="bold")
        self.text(x0 + 2, y0 + 22.5, f"DRG No. {dwg_no}", size=8.5, ha="left")
        self.text(x0 + w - 2, y0 + 22.5, f"SHEET {sheet}", size=8.5, ha="right")
        self.text(x0 + 2, y0 + 13.5, f"SCALE {scale}", size=8.5, ha="left")
        self.text(x0 + w - 2, y0 + 13.5, "ALL DIMENSIONS IN mm", size=8.5, ha="right")
        self.text(x0 + 2, y0 + 4.5, "3RD ANGLE PROJECTION", size=8.5, ha="left")
        self.text(x0 + w - 2, y0 + 4.5, "DIDSA AI EVAL", size=8.5, ha="right")
        # third-angle symbol: frustum side view, end view (two circles) to its right
        sx, sy = x0 + 62, y0 + 4.5
        self.line([(sx, sy - 3), (sx, sy + 3), (sx + 7, sy + 1.6), (sx + 7, sy - 1.6), (sx, sy - 3)], lw=0.7)
        self.line([(sx - 1.5, sy), (sx + 8.5, sy)], lw=0.35, ls=(0, (6, 1.5, 1, 1.5)))
        for r in (3, 1.6):
            self.ax.add_patch(Circle((sx + 15, sy), r, fill=False, lw=0.7))

    def parts_list(self, rows, x0=250, y0=50, w=160, title=None):
        cols = [0, 14, 128, 160]  # ITEM | DESCRIPTION | QTY
        h = 7
        allrows = rows[::-1] + [("ITEM", "DESCRIPTION", "QTY")]
        for i, r in enumerate(allrows):
            y = y0 + i * h
            self.ax.add_patch(plt.Rectangle((x0, y), w, h, fill=False, lw=0.9))
            for c in range(3):
                self.line([(x0 + cols[c], y), (x0 + cols[c], y + h)], lw=0.9)
                bold = i == len(allrows) - 1
                ha = "left" if c == 1 else "center"
                x = x0 + cols[c] + 2 if c == 1 else x0 + (cols[c] + cols[c + 1]) / 2
                self.text(x, y + h / 2, str(r[c]), size=8.5, ha=ha, weight="bold" if bold else "normal")
        if title:
            self.text(x0, y0 + len(allrows) * h + 4, title, size=9, ha="left", weight="bold")

    def save(self, path):
        tmp = path + ".tmp.png"
        self.fig.savefig(tmp, dpi=300, facecolor="white")
        plt.close(self.fig)
        im = Image.open(tmp).convert("L")
        im = im.resize((1568, round(1568 * im.height / im.width)), Image.LANCZOS)
        im.save(path, optimize=True)
        os.remove(tmp)


class View:
    """One projected view on a sheet. World view coords (u, v) in mm map to paper (ox + s*u, oy + s*v)."""

    def __init__(self, sh, key, ox, oy, s=1.0, label=None, hidden=True, parts=None, label_dy=-12):
        self.sh, self.d, self.ox, self.oy, self.s = sh, V[key], ox, oy, s
        self.draw(hidden, parts)
        if label:
            u0, v0, u1, v1 = self.extent()
            sh.text((self.P(u0, 0)[0] + self.P(u1, 0)[0]) / 2, self.P(0, v0)[1] + label_dy, label, size=10,
                    weight="bold")

    def P(self, u, v):
        return (self.ox + self.s * u, self.oy + self.s * v)

    def extent(self):
        pts = [p for pl in self.d["vis"] for p in pl]
        us, vs = [p[0] for p in pts], [p[1] for p in pts]
        return min(us), min(vs), max(us), max(vs)

    def draw(self, hidden, parts):
        for pl in self.d["vis"]:
            self.sh.line([self.P(*p) for p in pl], lw=LW_VIS)
        if hidden:
            for pl in self.d.get("hid", []):
                self.sh.line([self.P(*p) for p in pl], lw=LW_THIN, ls=(0, (3.5, 2)))
        for i, h in enumerate(self.d.get("hatch", [])):
            if parts and h["part"] not in parts:
                continue
            hatch = "////" if i % 2 == 0 else "\\\\\\\\"
            for loops in h["faces"]:
                verts, codes = [], []
                for lp in loops:
                    pts = [self.P(*p) for p in lp]
                    verts += pts + [pts[0]]
                    codes += [Path.MOVETO] + [Path.LINETO] * (len(pts) - 1) + [Path.CLOSEPOLY]
                self.sh.ax.add_patch(PathPatch(Path(verts, codes), facecolor="none", edgecolor="black", lw=0,
                                               hatch=hatch))

    # ---- annotation, all in world view coords
    def centre(self, a, b, ext=4):
        (x0, y0), (x1, y1) = self.P(*a), self.P(*b)
        L = math.hypot(x1 - x0, y1 - y0)
        ux, uy = (x1 - x0) / L, (y1 - y0) / L
        self.sh.line([(x0 - ux * ext, y0 - uy * ext), (x1 + ux * ext, y1 + uy * ext)], lw=0.4,
                     ls=(0, (12, 2, 2, 2)))

    def cross(self, c, r):
        u, v = c
        self.centre((u - r, v), (u + r, v), ext=3)
        self.centre((u, v - r), (u, v + r), ext=3)

    def _arrow(self, tip, direction):
        x, y = tip
        dx, dy = direction
        L = math.hypot(dx, dy)
        dx, dy = dx / L, dy / L
        al, aw = 3.0, 0.9
        self.sh.ax.add_patch(Polygon([(x, y), (x - al * dx - aw * dy, y - al * dy + aw * dx),
                                      (x - al * dx + aw * dy, y - al * dy - aw * dx)], color="black", lw=0))

    def dim(self, a, b, at, text, orient="h", text_side=None):
        """Linear dimension between world points a and b. orient 'h' measures along u with the dimension
        line at world v = at; 'v' measures along v with the line at world u = at."""
        sh = self.sh
        if orient == "h":
            p1, p2 = self.P(a[0], at), self.P(b[0], at)
            for src, dst in ((self.P(*a), p1), (self.P(*b), p2)):
                sgn = 1 if dst[1] > src[1] else -1
                sh.line([(src[0], src[1] + sgn * 1.2), (dst[0], dst[1] + sgn * 2)], lw=0.4)
        else:
            p1, p2 = self.P(at, a[1]), self.P(at, b[1])
            for src, dst in ((self.P(*a), p1), (self.P(*b), p2)):
                sgn = 1 if dst[0] > src[0] else -1
                sh.line([(src[0] + sgn * 1.2, src[1]), (dst[0] + sgn * 2, dst[1])], lw=0.4)
        L = math.hypot(p2[0] - p1[0], p2[1] - p1[1])
        d = ((p2[0] - p1[0]) / L, (p2[1] - p1[1]) / L)
        if L >= 14:
            sh.line([p1, p2], lw=0.4)
            self._arrow(p1, (-d[0], -d[1]))
            self._arrow(p2, d)
            mx, my = (p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2
        else:  # arrows outside, text beyond the second arrow
            sh.line([(p1[0] - d[0] * 8, p1[1] - d[1] * 8), (p2[0] + d[0] * 8, p2[1] + d[1] * 8)], lw=0.4)
            self._arrow(p1, d)
            self._arrow(p2, (-d[0], -d[1]))
            mx, my = (p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2
        if orient == "h":
            sh.text(mx, my + 2.4, text)
        else:
            sh.text(mx - 2.4, my, text, rot=90)

    def leader(self, tip, angle_deg, length, text, shoulder=5):
        """Leader with arrow at world point `tip`, running out at angle (paper) then a horizontal shoulder."""
        x, y = self.P(*tip)
        a = math.radians(angle_deg)
        ex, ey = x + length * math.cos(a), y + length * math.sin(a)
        right = math.cos(a) >= 0
        sx = ex + (shoulder if right else -shoulder)
        self.sh.line([(x, y), (ex, ey), (sx, ey)], lw=0.4)
        self._arrow((x, y), (x - ex, y - ey))
        self.sh.text(sx + (1 if right else -1), ey, text, ha="left" if right else "right")

    def note(self, u, v, text, **k):
        x, y = self.P(u, v)
        self.sh.text(x, y, text, **k)

    def cutting_plane(self, a, b, letter, look):
        """Section line from a to b (world), arrows pointing in paper direction `look`."""
        (x0, y0), (x1, y1) = self.P(*a), self.P(*b)
        self.sh.line([(x0, y0), (x1, y1)], lw=0.4, ls=(0, (12, 2, 2, 2)))
        for (x, y) in ((x0, y0), (x1, y1)):
            self.sh.line([(x - 0.01, y), (x, y)], lw=0)
            L = 7
            self.sh.line([(x, y), (x + look[0] * L, y + look[1] * L)], lw=1.2)
            self._arrow((x + look[0] * L, y + look[1] * L), look)
            self.sh.text(x + look[0] * L + look[0] * 4, y + look[1] * L + look[1] * 4, letter, size=11,
                         weight="bold")


class Iso(View):
    def __init__(self, sh, key, box, label=None, pts_key=None, balloons=None, label_dy=-8):
        d = V[key]
        pts = [p for pl in d["vis"] for p in pl]
        us, vs = [p[0] for p in pts], [p[1] for p in pts]
        x0, y0, x1, y1 = box
        s = min((x1 - x0) / (max(us) - min(us)), (y1 - y0) / (max(vs) - min(vs)))
        ox = (x0 + x1) / 2 - s * (max(us) + min(us)) / 2
        oy = (y0 + y1) / 2 - s * (max(vs) + min(vs)) / 2
        super().__init__(sh, key, ox, oy, s, label=label, hidden=False, label_dy=label_dy)
        if balloons:
            for (num, ang, length), p in zip(balloons, V["iso_pts"][pts_key]):
                self.balloon(p, num, ang, length)

    def balloon(self, p, num, ang, length):
        x, y = self.P(*p)
        a = math.radians(ang)
        r = 4.2
        cx, cy = x + (length + r) * math.cos(a), y + (length + r) * math.sin(a)
        self.sh.line([(x, y), (x + length * math.cos(a), y + length * math.sin(a))], lw=0.45)
        self.sh.ax.add_patch(Circle((x, y), 0.7, color="black"))
        self.sh.ax.add_patch(Circle((cx, cy), r, fill=False, lw=0.8))
        self.sh.text(cx, cy, str(num), size=9.5)


# ======================================================================================== sheets
def sheet_A(out):
    sh = Sheet("LOCATING PIN ASSEMBLY", "EVAL-A01", "1 OF 1", "1:1")
    # item 1: base block, top view above front view
    t = View(sh, "A1_top", 85, 225, label=None)
    t.cross((0, 0), 14)
    t.dim((-40, 25), (40, 25), 35, "80")
    t.dim((40, -25), (40, 25), 52, "50", orient="v")
    t.leader((7.07, 7.07), 40, 22, "Ø20 THRU")
    f = View(sh, "A1_front", 85, 160, label="ITEM 1 - BASE BLOCK", label_dy=-13)
    f.centre((0, -3), (0, 23), ext=2)
    f.dim((40, 0), (40, 20), 52, "20", orient="v")
    # item 2: pin, end view above front view
    pt = View(sh, "A2_top", 200, 232)
    pt.cross((0, 0), 18)
    pt.leader((11.3, 11.3), 40, 12, "Ø32")
    pf = View(sh, "A2_front", 200, 150, label="ITEM 2 - LOCATING PIN", label_dy=-13)
    pf.centre((0, -3), (0, 49), ext=2)
    pf.dim((-16, 40), (-16, 46), -26, "6", orient="v", text_side=1)
    pf.dim((-10, 0), (-10, 40), -26, "40", orient="v")
    pf.dim((-10, 0), (10, 0), -9, "Ø20")
    pf.dim((-16, 46), (16, 46), 56, "Ø32")
    # assembly: plan with cutting plane, section A-A below it (pin not sectioned, by convention)
    ap = View(sh, "A1_top", 330, 240)
    View(sh, "A2_top", 330, 240)
    ap.cutting_plane((-48, 0), (48, 0), "A", (0, 1))
    ap.note(0, -38, "ASSEMBLY - PLAN", size=10, weight="bold")
    s = View(sh, "A_sec", 330, 150, label="SECTION A-A", label_dy=-14)
    s.centre((0, -23), (0, 29), ext=2)
    s.dim((40, -20), (40, 26), 52, "46", orient="v")
    s.dim((-10, -20), (-10, 0), -48, "20", orient="v")
    # iso with balloons
    Iso(sh, "A_iso", (30, 25, 200, 110), label="ASSEMBLY", pts_key="A", balloons=[(1, -20, 22), (2, 120, 22)])
    sh.parts_list([(1, "BASE BLOCK", 1), (2, "LOCATING PIN", 1)])
    sh.text(250, 82, "NOTES: 1. PIN HEAD SEATS ON TOP FACE OF ITEM 1.", size=8.5, ha="left")
    sh.save(os.path.join(out, "asm_pin_block.png"))


def sheet_B(out):
    # sheet 1: general arrangement
    sh = Sheet("WHEEL BRACKET ASSEMBLY", "EVAL-B01", "1 OF 2", "1:1")
    f = View(sh, "B_front", 100, 140, label="FRONT VIEW", label_dy=-24)
    f.centre((0, -2), (0, 112), ext=2)
    f.centre((-44, 70), (44, 70), ext=0)
    f.dim((-20, 110), (20, 110), 120, "40")
    f.dim((-70, 0), (70, 0), -12, "140")
    f.dim((70, 0), (70, 70), 82, "70", orient="v")
    f.dim((-70, 0), (-70, 110), -82, "110", orient="v")
    r = View(sh, "B_right", 245, 140, label="RIGHT SIDE VIEW", label_dy=-24)
    r.cross((0, 70), 40)
    r.dim((-40, 0), (40, 0), -12, "80")
    Iso(sh, "B_iso", (305, 140, 405, 268), label="ISOMETRIC", pts_key="B",
        balloons=[(1, -40, 14), (2, 15, 28), (2, 120, 18), (3, 15, 22), (4, 200, 34)])
    sh.parts_list([(1, "BASE PLATE", 1), (2, "UPRIGHT", 2), (3, "AXLE", 1), (4, "WHEEL", 1)])
    sh.text(20, 40, "NOTES:", size=9, ha="left", weight="bold")
    sh.text(20, 33, "1. UPRIGHTS (ITEM 2) STAND ON TOP FACE OF ITEM 1, SYMMETRIC ABOUT ITS CENTRE.", size=8.5, ha="left")
    sh.text(20, 27, "2. AXLE (ITEM 3) PASSES THROUGH BOTH UPRIGHTS, CENTRED; WHEEL (ITEM 4) CENTRED ON AXLE.",
            size=8.5, ha="left")
    sh.text(20, 21, "3. ITEM 2: 2 OFF, IDENTICAL.", size=8.5, ha="left")
    sh.save(os.path.join(out, "asm_wheel_bracket_1.png"))

    # sheet 2: part details
    sh = Sheet("WHEEL BRACKET ASSEMBLY - DETAILS", "EVAL-B01", "2 OF 2", "1:1")
    t = View(sh, "B1_top", 95, 207)
    for sx in (-1, 1):
        for sy in (-1, 1):
            t.cross((sx * 55, sy * 25), 7)
    t.dim((-55, 25), (55, 25), 48, "110")
    t.dim((-70, 40), (70, 40), 58, "140")
    t.dim((55, -25), (55, 25), 82, "50", orient="v")
    t.dim((70, -40), (70, 40), 95, "80", orient="v")
    t.leader((-55 + 3.2, -25 + 3.2), 50, 20, "4 HOLES Ø9 THRU")
    f = View(sh, "B1_front", 95, 148, label="ITEM 1 - BASE PLATE - 1 OFF", label_dy=-12)
    f.dim((70, 0), (70, 10), 82, "10", orient="v", text_side=1)
    # item 2 upright: front (edge) view, right (profile) view
    uf = View(sh, "B2_front", 265, 140)
    uf.centre((-3, 60), (13, 60), ext=1)
    uf.dim((0, 0), (10, 0), -10, "10", text_side=1)
    ur = View(sh, "B2_right", 345, 140, label="ITEM 2 - UPRIGHT - 2 OFF", label_dy=-24)
    ur.cross((0, 60), 44)
    ur.dim((-40, 0), (40, 0), -12, "80")
    ur.dim((40, 0), (40, 60), 50, "60", orient="v")
    ur.leader((28.28, 88.28), 45, 10, "R40")
    ur.leader((-4.24, 64.24), 135, 26, "Ø12 THRU")
    # item 3 axle
    a = View(sh, "B3_front", 70, 80, label="ITEM 3 - AXLE - 1 OFF", label_dy=-18)
    a.centre((-40, 0), (40, 0))
    a.dim((-40, 6), (40, 6), 16, "80")
    a.dim((40, -6), (40, 6), 50, "Ø12", orient="v")
    # item 4 wheel: front view and right (end) view
    wf = View(sh, "B4_front", 160, 75)
    wf.centre((-17, 0), (17, 0), ext=1)
    wf.dim((-15, 35), (15, 35), 43, "30")
    wr = View(sh, "B4_right", 215, 75, label=None)
    wr.cross((0, 0), 38)
    wr.leader((24.75, 24.75), 40, 10, "Ø70")
    wr.leader((-4.24, -4.24), 225, 34, "Ø12 THRU")
    sh.text(187, 26, "ITEM 4 - WHEEL - 1 OFF", size=10, weight="bold")
    sh.save(os.path.join(out, "asm_wheel_bracket_2.png"))


def sheet_C(out):
    # sheet 1: general arrangement
    sh = Sheet("SWIVEL CASTER ASSEMBLY", "EVAL-C01", "1 OF 3", "1:1")
    f = View(sh, "C_front", 95, 255, label="FRONT VIEW", label_dy=-14)
    f.centre((0, 13), (0, -121), ext=0)
    f.centre((-38, -68), (32, -68), ext=0)
    f.dim((50, 10), (50, -118), 74, "128", orient="v")
    f.dim((50, 6), (50, -68), 62, "74", orient="v")
    for num, p, ang, length in [(1, (-40, 3), 200, 16), (2, (-17, -1.5), 210, 26), (3, (-5, 8), 150, 22),
                                (4, (-19, -40), 180, 26), (5, (-8, -100), 200, 34), (6, (26, -63), 30, 18),
                                (7, (-27, -74), 210, 18)]:
        Iso.balloon(f, p, num, ang, length)
    r = View(sh, "C_right", 245, 262, label="RIGHT SIDE VIEW", label_dy=-14)
    r.cross((0, -68), 53)
    r.dim((-50, 0), (50, 0), 14, "100")
    Iso(sh, "C_iso", (308, 120, 405, 275), label="ISOMETRIC")
    sh.parts_list([(1, "TOP PLATE", 1), (2, "SWIVEL WASHER", 1), (3, "KINGPIN", 1), (4, "FORK", 1),
                   (5, "WHEEL ASSY (SUB-ASSEMBLY, SHEET 2)", 1), (6, "AXLE BOLT", 1), (7, "HEX NUT", 1)])
    notes = ["NOTES:",
             "1. STACK FROM TOP: KINGPIN HEAD, TOP PLATE, SWIVEL WASHER, FORK. KINGPIN",
             "    PASSES THROUGH ALL THREE, COAXIAL.",
             "2. AXLE BOLT PASSES THROUGH BOTH FORK LEGS AND THE WHEEL ASSY BUSHING;",
             "    HEAD AGAINST ONE LEG, NUT AGAINST THE OTHER.",
             "3. BUSHING ENDS BEAR ON THE INSIDE FACES OF THE FORK LEGS.",
             "4. ITEM 5 IS SUPPLIED AS A SUB-ASSEMBLY: SEE SHEET 2. OTHER PARTS: SHEET 3."]
    for i, n in enumerate(notes):
        sh.text(20, 100 - i * 6.5, n, size=8.5, ha="left", weight="bold" if i == 0 else "normal")
    sh.save(os.path.join(out, "asm_caster_1.png"))

    # sheet 2: wheel sub-assembly
    sh = Sheet("SWIVEL CASTER - WHEEL ASSY (ITEM 5)", "EVAL-C01", "2 OF 3", "1:1")
    r = View(sh, "CS_right", 95, 175)
    r.cross((0, 0), 54)
    r.cutting_plane((0, 58), (0, -58), "A", (-1, 0))
    r.leader((35.36, 35.36), 40, 12, "Ø100")
    sh.text(95, 108, "WHEEL ASSY - SIDE VIEW", size=10, weight="bold")
    s = View(sh, "CS_sec", 200, 175, parts=None)
    s.centre((-21, 0), (21, 0), ext=0)
    s.dim((-17, 50), (17, 50), 62, "34")
    s.dim((-15, 50), (15, 50), 56, "30")
    s.dim((-15, -30), (-11, -30), -42, "4", text_side=-1)
    s.dim((11, -30), (15, -30), -42, "4", text_side=1)
    s.dim((15, -30), (15, 30), 30, "Ø60", orient="v")
    s.dim((-17, -8), (-17, 8), -32, "Ø16", orient="v")
    s.dim((17, -5), (17, 5), 46, "Ø10", orient="v")
    sh.text(200, 108, "SECTION A-A", size=10, weight="bold")
    Iso(sh, "CS_iso", (295, 150, 400, 262), label="ISOMETRIC", pts_key="CS", balloons=[(1, -30, 20), (2, 40, 30)])
    sh.parts_list([(1, "WHEEL", 1), (2, "BUSHING", 1)], y0=50, title="PARTS LIST - WHEEL ASSY")
    notes = ["NOTES:",
             "1. BUSHING (ITEM 2) IS A PRESS FIT IN THE WHEEL BORE, CENTRED:",
             "    IT STANDS 2 PROUD OF EACH WHEEL FACE.",
             "2. WHEEL: Ø100 x 30 WIDE, Ø16 BORE, Ø60 x 4 DEEP RECESS BOTH FACES.",
             "3. BUSHING: Ø16 OD x Ø10 ID x 34 LONG."]
    for i, n in enumerate(notes):
        sh.text(20, 80 - i * 6.5, n, size=8.5, ha="left", weight="bold" if i == 0 else "normal")
    sh.save(os.path.join(out, "asm_caster_2.png"))

    # sheet 3: part details
    sh = Sheet("SWIVEL CASTER - PART DETAILS", "EVAL-C01", "3 OF 3", "1:1")
    t = View(sh, "C1_top", 80, 203)
    t.cross((0, 0), 10)
    for sx in (-1, 1):
        for sy in (-1, 1):
            t.cross((sx * 40, sy * 40), 7)
    t.dim((-40, 40), (40, 40), 58, "80")
    t.dim((-50, 50), (50, 50), 64, "100")
    t.dim((40, -40), (40, 40), 60, "80", orient="v")
    t.dim((50, -50), (50, 50), 68, "100", orient="v")
    t.leader((-40 + 3.2, -40 + 3.2), 45, 16, "4 HOLES Ø9 THRU")
    t.leader((4.24, 4.24), 40, 16, "Ø12 THRU")
    tf = View(sh, "C1_front", 80, 132, label="ITEM 1 - TOP PLATE", label_dy=-11)
    tf.dim((50, 0), (50, 6), 60, "6", orient="v", text_side=1)
    # fork: front and right views
    ff = View(sh, "C4_front", 200, 255)
    ff.centre((0, 3), (0, -93), ext=0)
    ff.centre((-25, -65), (25, -65), ext=0)
    ff.dim((-21, 0), (21, 0), 8, "42")
    ff.dim((-17, -65), (17, -65), -80, "34")
    ff.dim((21, 0), (21, -4), 30, "4", orient="v", text_side=-1)
    ff.dim((21, 0), (21, -65), 40, "65", orient="v")
    ff.note(-26, -45, "4 THK", size=8.5, ha="right")
    fr = View(sh, "C4_right", 275, 255, label="ITEM 4 - FORK", label_dy=-12)
    fr.cross((0, -65), 29)
    fr.dim((-25, 0), (25, 0), 8, "50")
    fr.leader((17.68, -82.68), -30, 8, "R25")
    fr.leader((-3.54, -61.46), 150, 22, "Ø10 THRU")
    sh.text(237, 146, "Ø12 THRU HOLE IN BASE, CENTRAL", size=8.5)
    # washer
    wt = View(sh, "C2_top", 360, 245)
    wt.cross((0, 0), 23)
    wt.leader((14.14, 14.14), 45, 8, "Ø40")
    wt.leader((-4.24, -4.24), 225, 16, "Ø12")
    wf = View(sh, "C2_front", 360, 207, label="ITEM 2 - SWIVEL WASHER", label_dy=-10)
    wf.dim((20, 0), (20, 3), 28, "3", orient="v", text_side=1)
    # kingpin
    k = View(sh, "C3_front", 345, 140, label="ITEM 3 - KINGPIN", label_dy=-12)
    k.centre((0, -3), (0, 23), ext=0)
    k.dim((-10, 20), (10, 20), 27, "Ø20")
    k.dim((-6, 0), (6, 0), -6, "Ø12")
    k.dim((10, 16), (10, 20), 22, "4", orient="v", text_side=1)
    k.dim((6, 0), (6, 16), 30, "16", orient="v")
    # bolt
    b = View(sh, "C7_front", 95, 75, label="ITEM 6 - AXLE BOLT", label_dy=-17)
    b.centre((-58, 0), (10, 0), ext=0)
    b.dim((-55, 5), (0, 5), 17, "55")
    b.dim((0, 8), (7, 8), 17, "7", text_side=1)
    b.dim((-55, -5), (-55, 5), -64, "Ø10", orient="v")
    br = View(sh, "C7_right", 140, 75)
    br.cross((0, 0), 11)
    br.dim((-9.24, -8), (-9.24, 8), -14, "16 A/F", orient="v")
    # nut
    n = View(sh, "C8_front", 195, 75, label="ITEM 7 - HEX NUT", label_dy=-17)
    n.centre((-3, 0), (11, 0), ext=0)
    n.dim((0, 9.24), (8, 9.24), 16, "8", text_side=1)
    nr = View(sh, "C8_right", 232, 75)
    nr.cross((0, 0), 11)
    nr.dim((9.24, -8), (9.24, 8), 15, "16 A/F", orient="v")
    nr.leader((3.54, 3.54), 50, 16, "Ø10 THRU")
    sh.save(os.path.join(out, "asm_caster_3.png"))


if __name__ == "__main__":
    V.update(json.load(open(sys.argv[1])))
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    sheet_A(out)
    sheet_B(out)
    sheet_C(out)
    print("ok")
