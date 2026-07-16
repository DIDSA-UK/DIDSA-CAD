"""Wraps OCCT's font-to-BRep text conversion for the Text sketch tool (see
docs/sketcher-overhaul-scope.md section 6.2.6).

`OCC.Core.Addons.text_to_brep`/`register_font` are the only entry points
into this - `OCC.Core.Font` (the module the underlying `Font_BRepFont`/
`Font_BRepTextBuilder` classes themselves live in) is not exposed by this
project's pinned `pythonocc-core=7.9.3=novtk*` build, confirmed by direct
on-device testing, but the higher-level `Addons` wrapper (`pythonocc-core`'s
own `src/Addons/Font3d.cpp` convenience layer) is, and produces real,
correctly-formed geometry: empirically confirmed that a single `text_to_brep`
call already returns one Face per glyph with its own holes fully punched
(e.g. "o" -> one Face with 2 wires, an outer ring and its inner counter) -
OCCT resolves each glyph's own nesting itself, so nothing here needs to
reimplement point-in-polygon hole detection for a single Text entity's own
glyphs (see `app.sketch.profile._text_profile`, which only needs that for
classifying a whole Text entity's loops against *other* sketch geometry).

This is the one file in `app.sketch` that imports OCCT at all - see
`app.sketch.text_fonts`'s own docstring for why the font allowlist itself
lives in a separate, OCCT-free module instead of here.
"""

import math
from pathlib import Path

from OCC.Core.Addons import Font_FA_Regular, register_font, text_to_brep
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.BRepTools import BRepTools_WireExplorer, breptools
from OCC.Core.GCPnts import GCPnts_UniformDeflection
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_WIRE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape, TopoDS_Wire, topods

from app.sketch.text_fonts import FONT_ALLOWLIST

_FONTS_DIR = Path(__file__).parent / "fonts"

# GCPnts_UniformDeflection's max chordal deviation, in sketch units - small
# enough that the tessellated polygon this drives (see `text_to_polygons`)
# is visually indistinguishable from the real curve at any sketch-editing
# zoom level, without generating an excessive point count for a typical
# glyph. Only affects nesting/containment classification and the client's
# own preview rendering - never the actual extruded solid's geometry,
# which `app.document.extrude.wire_for_profile` builds from this module's
# exact (non-tessellated) wires instead.
_TESSELLATION_DEFLECTION = 0.05

_registered_fonts: set[str] = set()


def place_local_point(
    anchor_x: float, anchor_y: float, rotation_degrees: float, local_x: float, local_y: float
) -> tuple[float, float]:
    """One `(local_x, local_y)` point from `text_to_shape`'s own local
    coordinate space (see that function's own docstring), rotated by
    `rotation_degrees` and translated to `(anchor_x, anchor_y)` - the
    plain 2D rotate-then-translate every entity here uses, shared so
    `app.sketch.profile._text_profile` (nesting/containment math) and
    the preview-outline endpoint (client rendering) never disagree with
    each other about where a Text entity's own glyph geometry actually
    sits in sketch-local space. `app.document.extrude.
    _text_world_transform` composes this same rotation with a Sketch's
    plane basis for the real 3D world-space placement, rather than
    calling this - a pure-2D helper has no plane basis to embed into.
    """
    rotation = math.radians(rotation_degrees)
    cos_r, sin_r = math.cos(rotation), math.sin(rotation)
    return (
        anchor_x + local_x * cos_r - local_y * sin_r,
        anchor_y + local_x * sin_r + local_y * cos_r,
    )


def _ensure_registered(font: str) -> None:
    if font in _registered_fonts:
        return
    font_path = _FONTS_DIR / FONT_ALLOWLIST[font]
    register_font(str(font_path), Font_FA_Regular)
    _registered_fonts.add(font)


def text_to_shape(content: str, font: str, size: float) -> TopoDS_Shape:
    """The raw `TopoDS_Shape` (a Compound of Faces, one per glyph, each
    already holed where the glyph needs it - see this module's own
    docstring) OCCT builds for `content` rendered in `font` at `size`
    (sketch units, same convention as every other entity's own
    coordinates) - regenerated fresh on every call, never cached/
    persisted, the same recompute-from-parametric-inputs principle every
    other feature in this app already follows (see `TextEntity`'s own
    docstring).

    Lies flat in the caller's local XY plane at Z=0, with the first
    glyph's own baseline origin at local (0, 0) - `app.sketch.profile.
    _text_profile`/`app.document.extrude.wire_for_profile` place this
    relative to the TextEntity's own anchor Point and rotation, exactly
    like every other entity's local-to-world placement.
    """
    if font not in FONT_ALLOWLIST:
        raise ValueError(f"Unknown font: {font!r}")
    if not content:
        raise ValueError("Text content cannot be empty")
    if size <= 0:
        raise ValueError("Text size must be positive")
    _ensure_registered(font)
    return text_to_brep(content, font, Font_FA_Regular, size, True)


def _tessellate_wire(wire: TopoDS_Wire) -> list[tuple[float, float]]:
    """`wire`'s own edges, in wire order (`BRepTools_WireExplorer`, unlike
    a generic `TopExp_Explorer`, walks a wire's edges in their actual
    connectivity order - required here, since the result is a polygon
    boundary, not just an unordered point set), each discretized to within
    `_TESSELLATION_DEFLECTION` via `GCPnts_UniformDeflection` - more points
    where the curve bends, fewer along straight stretches. Z is always 0
    for this module's own shapes (see `text_to_shape`'s docstring), so
    only (x, y) is kept."""
    points: list[tuple[float, float]] = []
    wire_explorer = BRepTools_WireExplorer(wire)
    while wire_explorer.More():
        edge = wire_explorer.Current()
        discretizer = GCPnts_UniformDeflection(BRepAdaptor_Curve(edge), _TESSELLATION_DEFLECTION)
        if discretizer.IsDone():
            for i in range(1, discretizer.NbPoints() + 1):
                point = discretizer.Value(i)
                points.append((point.X(), point.Y()))
        wire_explorer.Next()
    return points


def text_to_polygons(
    content: str, font: str, size: float
) -> list[tuple[list[tuple[float, float]], list[list[tuple[float, float]]]]]:
    """One `(outer, holes)` pair per glyph Face in `text_to_shape`'s own
    output - `outer` and each of `holes` a tessellated `(x, y)` polygon
    (see `_tessellate_wire`) in the same local coordinate space
    `text_to_shape` itself uses. A pure-Python return type (no OCCT
    objects cross this function's boundary) - used by both
    `app.sketch.profile._text_profile` (nesting/containment
    classification against other sketch geometry - never for the actual
    extruded solid, which needs the exact, non-tessellated curve; see
    `text_to_shape`'s own docstring) and the preview-outline endpoint
    (client rendering, which only ever needs an approximation to draw).

    Confirmed by direct on-device testing that OCCT's own font-to-BRep
    conversion already resolves each glyph's own hole nesting correctly
    (e.g. "o" -> one Face, 2 wires: one outer ring, one inner counter) -
    `BRepTools.OuterWire` identifies which of a Face's wires is the outer
    one; every other wire on that Face is one of its holes.
    """
    shape = text_to_shape(content, font, size)
    contours: list[tuple[list[tuple[float, float]], list[list[tuple[float, float]]]]] = []
    face_explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while face_explorer.More():
        face = topods.Face(face_explorer.Current())
        outer_wire = breptools.OuterWire(face)
        outer = _tessellate_wire(outer_wire)
        holes: list[list[tuple[float, float]]] = []
        wire_explorer = TopExp_Explorer(face, TopAbs_WIRE)
        while wire_explorer.More():
            wire = topods.Wire(wire_explorer.Current())
            if not wire.IsSame(outer_wire):
                holes.append(_tessellate_wire(wire))
            wire_explorer.Next()
        contours.append((outer, holes))
        face_explorer.Next()
    return contours


def text_contour_wire(
    content: str, font: str, size: float, contour_index: int, hole_index: int | None
) -> TopoDS_Wire:
    """The EXACT (non-tessellated) outer wire of glyph contour
    `contour_index` (`hole_index=None`), or its `hole_index`-th hole wire -
    re-derives a fresh `text_to_shape` call and walks to the requested
    Face/wire by index, mirroring `text_to_polygons`'s own face/wire walk
    exactly so the two can never disagree about ordering (both use the
    same `TopExp_Explorer`-over-`TopAbs_FACE`-then-`TopAbs_WIRE` walk).
    Used by `app.document.extrude.wire_for_profile` to build the actual
    extruded solid's geometry from the real curve - `text_to_polygons`'s
    own tessellated version exists only for nesting classification/
    preview rendering (see that function's own docstring), never for the
    solid itself, so the two must stay independently derivable from the
    same inputs rather than one being reconstructed from the other's
    (lossy) tessellation.

    Recomputes `text_to_shape` from scratch on every call, once per
    outer/hole wire needed - for a multi-glyph, multi-hole Text entity,
    this means the underlying font-to-BRep conversion runs more than once
    per extrude (a known, accepted v1 inefficiency, not a correctness
    issue - the same "regenerate rather than cache/persist" principle
    every other derived-geometry function in this codebase already
    follows, just paid multiple times here instead of once).
    """
    shape = text_to_shape(content, font, size)
    face_explorer = TopExp_Explorer(shape, TopAbs_FACE)
    for _ in range(contour_index):
        face_explorer.Next()
    face = topods.Face(face_explorer.Current())
    outer_wire = breptools.OuterWire(face)
    if hole_index is None:
        return outer_wire

    wire_explorer = TopExp_Explorer(face, TopAbs_WIRE)
    seen_holes = 0
    while wire_explorer.More():
        wire = topods.Wire(wire_explorer.Current())
        if not wire.IsSame(outer_wire):
            if seen_holes == hole_index:
                return wire
            seen_holes += 1
        wire_explorer.Next()
    raise IndexError(f"No hole {hole_index} on text contour {contour_index}")
