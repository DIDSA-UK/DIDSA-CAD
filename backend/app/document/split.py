"""OCCT geometry construction for `SplitFeature` (Boolean family, fourth/
last entry - Merge/Subtract/Common came first): divides one existing Body
into two independent, surviving pieces along a Plane or an existing
Surface.

Deliberately does not use `BRepAlgoAPI_Splitter`/`BOPAlgo` (a heavier
tool-chain, not confirmed available in this project's pinned
pythonocc-core build - see `environment.yml`). Instead, this builds one
large "half-space" solid block from the resolved cutting tool - generously
sized well past the target Body's own `Bnd_Box` (via `BRepBndLib`, the
same pattern `app.document.loft`'s own self-intersection check already
uses) so it stays robust regardless of how the tool is oriented relative
to the Body's bounding-box axes, not just an axis-aligned case - then
reuses the exact two Boolean primitives `app.document.boolean` already
added for Subtract/Common:

    piece_a = BRepAlgoAPI_Common(target_shape, block).Shape()  # tool's own + side
    piece_b = BRepAlgoAPI_Cut(target_shape, block).Shape()     # everything else

Both pieces are registered back under the target Body's own base id by
`app.document.extrude.compute_part_bodies`'s own `SplitFeature` branch (see
that function's docstring), not here - this module only ever resolves the
two piece shapes.

Three cutting-tool kinds (`SplitToolRef` - see its own docstring):
- `plane_ref`: resolved via `app.document.create_plane.resolve_plane_ref`
  (already shared by `CreatePlaneFeature`/`MirrorFeature`) to a
  `ResolvedPlane`, then the block is a rectangular box on the plane's own
  `+normal` side, sized off the target Body's bounding-box corners
  projected into the plane's own local frame (`app.document.plane_
  geometry.world_point_to_basis`/`signed_distance_to_plane` - pure Python,
  no OCCT) - this projection is what keeps the technique correct for a
  plane at any orientation, not just one aligned with the target Body's
  own bounding-box axes: a naive world-axis-aligned box sized from the
  bounding box alone would not reliably cover a tilted plane's own cross-
  section of that box.
- `surface_feature_id`: an existing, already-created `SurfaceFeature`'s own
  backing Sketch profile (closed profiles only - see `_surface_block`'s own
  docstring), swept far enough past the target Body's bounding box, along
  the same direction that Feature's own `direction_ref` (or Sketch-normal
  default) resolves to. Unlike the Plane case, this can only extend the
  tool along its own sweep direction, not laterally - the profile's own
  in-plane shape is used as drawn, so (mirroring standard "draw your
  cutting surface past the part" CAD guidance) a Surface-tool Split still
  needs its backing Sketch profile to already span the target Body's own
  cross-section for a complete split; a too-small profile produces a
  partial, real-but-incomplete cut rather than an error.
- `sketch_line_ref`: a single connectable-curve Sketch entity (Line, Arc,
  EllipseArc, or Spline - `CONNECTABLE_CURVE_ENTITY_TYPES` below), used
  directly with no backing `SurfaceFeature` at all - see `_sketch_line_
  block`'s own docstring for how an open curve like this (almost always
  open - a single segment, not a closed loop) gets turned into a genuine
  solid block. This is the guided flow's replacement for what used to be
  an inline "New Surface" mini-step silently persisting a real
  `SurfaceFeature` merely to extrude a picked Sketch line/curve into an
  "infinite" cutting surface - picking the raw curve now resolves
  immediately instead, always normal to its own host Sketch plane (no
  direction override - there is no persisted Feature for one to attach
  to).
"""

import logging
import math

from fastapi import HTTPException
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Common, BRepAlgoAPI_Cut
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakePolygon,
    BRepBuilderAPI_MakeWire,
)
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.gp import gp_Dir, gp_Vec
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape

from app.document.create_plane import resolve_plane_ref, resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    basis_normal,
    basis_point_to_world,
    compute_part_bodies,
    face_for_profile,
    select_profiles,
)
from app.document.graph import sketch_feature_id_for_sketch
from app.document.loft import wire_for_open_chain
from app.document.models import Part, ResolvedPlane, SketchFeature, SplitFeature, SplitToolRef, SurfaceFeature
from app.document.pattern import direction_vector
from app.document.plane_geometry import signed_distance_to_plane, world_point_to_basis
from app.sketch.models import Arc, EllipseArc, Line, Sketch, SketchEntity, SketchEntityRef, SketchEntityType, Spline
from app.sketch.profile import OpenChain, ProfileStatus, detect_profile
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity

logger = logging.getLogger(__name__)

# Added to the target Body's own Bnd_Box diagonal to size every block
# generously past it - large enough that floating-point slop near the
# boundary can never leave a sliver of the target Body outside the block
# on its own "should be fully covered" side.
_MARGIN_PADDING = 10.0

# `SplitToolRef.sketch_line_ref`'s own accepted `entity_type`s - exactly the
# Sketch entities with a real, non-`None` `endpoint_point_ids()` (see that
# method's own base-class docstring in `app.sketch.models.SketchEntity`):
# genuine open curves with two distinct connection points, as opposed to
# Circle/Ellipse (always already closed, no endpoints) or Point/Text (no
# curve at all). Shared with `app.document.router._validate_split_tool_ref`
# for its own typed-slot check, the same "one shared source of truth" every
# other typed-slot field (`SubShapeType.EDGE`/`FACE`, ...) already gets.
CONNECTABLE_CURVE_ENTITY_TYPES = frozenset(
    {SketchEntityType.LINE, SketchEntityType.ARC, SketchEntityType.ELLIPSE_ARC, SketchEntityType.SPLINE}
)


def _bbox_corners_and_diagonal(shape: TopoDS_Shape) -> tuple[list[tuple[float, float, float]], float]:
    """The 8 corners of `shape`'s own axis-aligned `Bnd_Box`, plus its
    diagonal length - shared by both `_plane_block`/`_surface_block` to
    size their own oversized block generously past `shape`, regardless of
    the cutting tool's own orientation relative to `shape`'s bounding-box
    axes (see this module's own top-level docstring)."""
    box = Bnd_Box()
    brepbndlib.Add(shape, box)
    xmin, ymin, zmin, xmax, ymax, zmax = box.Get()
    corners = [(x, y, z) for x in (xmin, xmax) for y in (ymin, ymax) for z in (zmin, zmax)]
    diagonal = ((xmax - xmin) ** 2 + (ymax - ymin) ** 2 + (zmax - zmin) ** 2) ** 0.5
    return corners, diagonal


def _plane_block(basis: ResolvedPlane, target_shape: TopoDS_Shape) -> TopoDS_Shape:
    """An oversized rectangular box on `basis`'s own `+normal` side -
    `target_shape`'s own bounding-box corners are projected into `basis`'s
    local (u, v) in-plane coordinates (`world_point_to_basis`) and signed
    distance along `basis.normal` (`signed_distance_to_plane`), both pure
    Python (no OCCT), so the box's own in-plane footprint and depth are
    both sized correctly regardless of `basis`'s orientation relative to
    `target_shape`'s own bounding-box axes - this projection is the piece
    that keeps a tilted cutting plane robust (a naive world-axis-aligned
    box built straight from the bounding box would not)."""
    corners, diagonal = _bbox_corners_and_diagonal(target_shape)
    margin = diagonal + _MARGIN_PADDING
    us = [world_point_to_basis(basis, corner)[0] for corner in corners]
    vs = [world_point_to_basis(basis, corner)[1] for corner in corners]
    ws = [signed_distance_to_plane(basis, corner) for corner in corners]
    min_u, max_u = min(us) - margin, max(us) + margin
    min_v, max_v = min(vs) - margin, max(vs) + margin
    # The box's near face sits exactly on the plane (w=0) - only the far
    # face, on the `+normal` side, needs to clear the bounding box; `max(...,
    # 0.0)` keeps the depth positive even when `target_shape` sits entirely
    # on the `-normal` side (the box then simply doesn't reach it, which is
    # correct - see this module's own top-level docstring).
    depth = max(max(ws), 0.0) + margin

    polygon_maker = BRepBuilderAPI_MakePolygon()
    for u, v in ((min_u, min_v), (max_u, min_v), (max_u, max_v), (min_u, max_v)):
        polygon_maker.Add(basis_point_to_world(basis, u, v))
    polygon_maker.Close()
    face = BRepBuilderAPI_MakeFace(polygon_maker.Wire()).Face()

    normal = basis_normal(basis)
    vector = gp_Vec(normal.X() * depth, normal.Y() * depth, normal.Z() * depth)
    return BRepPrimAPI_MakePrism(face, vector).Shape()


def _surface_block(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    surface_feature: SurfaceFeature,
    target_shape: TopoDS_Shape,
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """The Surface-tool counterpart of `_plane_block` - `None` if `surface_
    feature`'s own backing Sketch currently has no closed profile (an
    open-chain Surface has no well-defined face to bound a solid block
    with - see `SurfaceFeature`'s own docstring for the open-chain case
    this deliberately doesn't support as a Split tool), mirroring `app.
    document.surface.resolve_surface_from_bodies`'s own "stale/edited-away
    profile should skip, not error" tolerance.

    Builds each of `surface_feature`'s own selected profile(s) as a real
    face (`app.document.extrude.face_for_profile`, holes and all - the same
    helper `app.document.revolve` reuses for its own face-with-holes need),
    then prisms it far enough past `target_shape`'s own bounding box along
    `surface_feature`'s own resolved direction (its own `direction_ref`, or
    Sketch-normal default) - unlike `_plane_block`, the profile's own
    in-plane shape is used exactly as drawn (see this module's own
    top-level docstring for why that's an accepted, CAD-standard
    limitation, not a bug). A MultiProfile's several selected profiles each
    become their own block, combined into one `TopoDS_Compound` - a single
    tool shape either Boolean primitive accepts directly, no `BRepAlgoAPI_
    Fuse` pre-step needed."""
    sketch_feature = part.get_feature(surface_feature.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        return None
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    try:
        basis = resolve_sketch_basis(part, sketch_feature, bodies, excluded_feature_ids)
    except HTTPException:
        # A custom-anchor-plane Sketch whose own CreatePlaneFeature (or
        # further chain) can't currently be resolved - cascade-delete
        # ordinarily prevents this for a live SplitFeature, but `excluded_
        # feature_ids` (hide/rollback) and hand-crafted documents can still
        # reach it, same tolerance `_plane_block`'s own caller already
        # gives `resolve_plane_ref`.
        return None
    result = detect_profile(sketch)
    if result.status not in EXTRUDABLE_STATUSES:
        logger.warning(
            "Skipping Split tool SurfaceFeature %s: its backing Sketch has no closed profile "
            "(status=%s) to build a cutting block from",
            surface_feature.id,
            result.status.value,
        )
        return None

    expanded_sketch = sketch.expand_pattern_and_mirror_instances()
    candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
    profiles = select_profiles(candidates, surface_feature.profile_refs)

    try:
        direction: gp_Dir = (
            basis_normal(basis)
            if surface_feature.direction_ref is None
            else direction_vector(part, bodies, surface_feature.direction_ref, excluded_feature_ids)
        )
    except HTTPException:
        # A dangling edge_ref/sketch_line_ref `direction_ref` - same
        # tolerance as the `resolve_sketch_basis` call above.
        return None
    corners, diagonal = _bbox_corners_and_diagonal(target_shape)
    margin = diagonal + _MARGIN_PADDING
    ox, oy, oz = basis.origin
    dx, dy, dz = direction.X(), direction.Y(), direction.Z()
    ws = [(cx - ox) * dx + (cy - oy) * dy + (cz - oz) * dz for cx, cy, cz in corners]
    depth = max(max(ws), 0.0) + margin
    vector = gp_Vec(dx * depth, dy * depth, dz * depth)

    blocks = [
        BRepPrimAPI_MakePrism(face_for_profile(expanded_sketch, profile, basis), vector).Shape()
        for profile in profiles
    ]
    if len(blocks) == 1:
        return blocks[0]
    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    for block in blocks:
        builder.Add(compound, block)
    return compound


_CIRCLE_SAMPLE_ANGLES = [i * 2.0 * math.pi / 16 for i in range(16)]


def _curve_extent_points_local(sketch: Sketch, entity: SketchEntity) -> list[tuple[float, float]]:
    """A handful of points, in `sketch`'s own local (x, y) space, that
    together bound `entity`'s own visual extent - folded into `_sketch_
    line_block`'s own combined-extent computation alongside the target
    Body's bounding box, so a bulging Arc/Spline that reaches further out
    than the Body still gets fully covered (see that function's own
    docstring for what this feeds into and why - a rotated-frame extent,
    not a plain axis-aligned one, is what actually needs covering, so this
    can't just reuse an axis-aligned bounding box).

    Deliberately conservative rather than exact: an Arc/EllipseArc samples
    16 evenly-spaced points around its own *full* circle (ignoring which
    portion the arc actually sweeps, and - for EllipseArc - approximating
    the ellipse as a circle of its own major radius, which always fully
    contains it since major >= minor by construction) - safe over-
    estimates either way, and correct at any rotation, unlike a plain
    axis-aligned bounding box's own corners (which do *not* reliably bound
    a circle's extent once projected onto a rotated pair of axes - only
    "center +/- radius along that exact axis" does, and 16 samples around
    the circle approximates that closely enough given the generous flat
    padding every caller already adds on top). A Spline instead reports
    every one of its own Bezier poles exactly (a cubic Bezier segment
    always lies within its own poles' convex hull, and a convex hull's
    extent along *any* axis is always exactly its own vertices' - poles
    are real points, so this one is exact, not an approximation)."""
    if isinstance(entity, Line):
        a, b = sketch.points[entity.start_point_id], sketch.points[entity.end_point_id]
        return [(a.x, a.y), (b.x, b.y)]
    if isinstance(entity, (Arc, EllipseArc)):
        center = sketch.points[entity.center_point_id]
        r = entity.radius(sketch.points) if isinstance(entity, Arc) else entity.major_radius(sketch.points)
        return [(center.x + r * math.cos(theta), center.y + r * math.sin(theta)) for theta in _CIRCLE_SAMPLE_ANGLES]
    assert isinstance(entity, Spline)
    pole_ids = {pid for segment in entity.segments() for pid in segment}
    return [(sketch.points[pid].x, sketch.points[pid].y) for pid in pole_ids]


def _sketch_line_block(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    ref: SketchEntityRef,
    target_shape: TopoDS_Shape,
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """The `sketch_line_ref`-tool counterpart of `_plane_block`/`_surface_
    block` - builds a genuinely closed, valid profile directly from one
    open Sketch curve (Line/Arc/EllipseArc/Spline - see this module's own
    `CONNECTABLE_CURVE_ENTITY_TYPES`), with no backing `SurfaceFeature`
    (unlike `_surface_block`, which requires a *closed* profile precisely
    because it has no such closing technique of its own).

    An open curve alone has no face `BRepBuilderAPI_MakeFace` can build a
    solid from, so this closes it into a proper loop first, in a local 2D
    frame anchored to the curve's own start->end chord (`e_u` along the
    chord, `e_v` its own in-plane perpendicular, origin at the curve's own
    start point): continue straight from each open end, *along* `e_u`
    (i.e. extending the chord's own direction, not perpendicular to it),
    far enough past `min_u`/`max_u` - the combined extent, in this same
    (u, v) frame, of both the target Body's own bounding box *and* the
    curve's own extent (`_curve_extent_points_local`) - then close the two
    far ends with a rectangle-shaped cap on one arbitrary side (`+v`, past
    `max_v` of that same combined extent). For a dead-straight Line (whose
    own chord already lies exactly along `e_u`, `v=0` throughout), this
    degenerates to exactly the flat, fully-covering rectangle `_plane_
    block` itself would build for the equivalent plane - which is the
    correctness bar this whole construction is built to hit for a curved
    entity too: continuing straight *along the chord* (not off to the
    side) is what guarantees the closed loop's own footprint fully covers
    the target Body's bounding box regardless of how short the curve is
    relative to it, unlike a naive "translate both ends by one fixed
    perpendicular offset" - which does close a valid loop, but one whose
    footprint can be no wider than the curve's own extent along `e_u`, so
    it can leave most of a much-larger target Body's own bounding box
    uncovered by the block entirely (silently producing a wrong split
    instead of raising anything, since nothing here would notice). Only
    the closure itself is a flat approximation - it still genuinely
    follows the curve's own actual shape across the curve's own span (a
    wavy Spline still cuts a wavy split), same "only defined out to where
    it matters" latitude `_plane_block`'s/`_surface_block`'s own
    oversized-but-flat far side already takes. Known sharp edge, not
    fully bulletproofed: a pathological curve that re-crosses its own
    chord (so some interior point sits at `v=0` or beyond `max_v` other
    than at its own two ends) could self-intersect this loop - a single
    user-drawn Line/Arc/Spline used as a dividing curve realistically
    never does.

    The resulting planar face sits exactly on the Sketch's own plane (like
    the curve itself), then prisms along that plane's own normal - see
    `SplitToolRef.sketch_line_ref`'s own docstring for why there is no
    direction override for this tool kind. `None` if `ref`'s own Sketch/
    entity can no longer be resolved, or resolves to something other than a
    connectable curve - the same tolerance `_surface_block` already gives a
    stale/edited-away reference."""
    sketch_feature_id = sketch_feature_id_for_sketch(part, ref.sketch_id)
    sketch_feature = part.get_feature(sketch_feature_id) if sketch_feature_id is not None else None
    if not isinstance(sketch_feature, SketchFeature):
        return None
    try:
        entity = resolve_sketch_entity(ref)
    except HTTPException:
        return None
    if not isinstance(entity, (Line, Arc, EllipseArc, Spline)):
        return None
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    try:
        basis = resolve_sketch_basis(part, sketch_feature, bodies, excluded_feature_ids)
    except HTTPException:
        # A custom-anchor-plane Sketch whose own CreatePlaneFeature (or
        # further chain) can't currently be resolved - same tolerance
        # `_surface_block`'s own identical call site already gives this.
        return None

    start_id, end_id = entity.endpoint_point_ids()
    chain = OpenChain(sketch_id=sketch.id, point_ids=[start_id, end_id], line_ids=[ref.entity_id])
    open_wire = wire_for_open_chain(sketch, chain, basis)
    start, end = sketch.points[start_id], sketch.points[end_id]

    chord_x, chord_y = end.x - start.x, end.y - start.y
    chord_length = math.hypot(chord_x, chord_y)
    # e_u along the chord, e_v its own in-plane perpendicular - an
    # arbitrary fallback orientation when the chord is degenerate (a
    # curved entity whose two ends happen to coincide) still closes the
    # loop correctly, just without the "reduces to `_plane_block`'s own
    # rectangle for a Line" property (moot for a degenerate Line, which
    # would be a zero-length entity to begin with).
    e_u = (1.0, 0.0) if chord_length == 0 else (chord_x / chord_length, chord_y / chord_length)
    e_v = (-e_u[1], e_u[0])

    def to_uv(local_x: float, local_y: float) -> tuple[float, float]:
        dx, dy = local_x - start.x, local_y - start.y
        return dx * e_u[0] + dy * e_u[1], dx * e_v[0] + dy * e_v[1]

    def from_uv(u: float, v: float) -> tuple[float, float]:
        return (start.x + u * e_u[0] + v * e_v[0], start.y + u * e_u[1] + v * e_v[1])

    corners, target_diagonal = _bbox_corners_and_diagonal(target_shape)
    target_local = [world_point_to_basis(basis, corner) for corner in corners]
    extent_local = _curve_extent_points_local(sketch, entity)
    all_uv = [to_uv(x, y) for x, y in (*target_local, *extent_local)]
    margin = target_diagonal + _MARGIN_PADDING
    min_u = min(u for u, _v in all_uv) - margin
    max_u = max(u for u, _v in all_uv) + margin
    max_v = max(v for _u, v in all_uv) + margin

    start_ext = from_uv(min_u, 0.0)
    end_ext = from_uv(max_u, 0.0)
    far_corner_from_end = from_uv(max_u, max_v)
    far_corner_from_start = from_uv(min_u, max_v)

    wire_maker = BRepBuilderAPI_MakeWire()
    wire_maker.Add(
        BRepBuilderAPI_MakeEdge(
            basis_point_to_world(basis, *start_ext), basis_point_to_world(basis, start.x, start.y)
        ).Edge()
    )
    wire_maker.Add(open_wire)
    wire_maker.Add(
        BRepBuilderAPI_MakeEdge(
            basis_point_to_world(basis, end.x, end.y), basis_point_to_world(basis, *end_ext)
        ).Edge()
    )
    wire_maker.Add(
        BRepBuilderAPI_MakeEdge(
            basis_point_to_world(basis, *end_ext), basis_point_to_world(basis, *far_corner_from_end)
        ).Edge()
    )
    wire_maker.Add(
        BRepBuilderAPI_MakeEdge(
            basis_point_to_world(basis, *far_corner_from_end), basis_point_to_world(basis, *far_corner_from_start)
        ).Edge()
    )
    wire_maker.Add(
        BRepBuilderAPI_MakeEdge(
            basis_point_to_world(basis, *far_corner_from_start), basis_point_to_world(basis, *start_ext)
        ).Edge()
    )
    face = BRepBuilderAPI_MakeFace(wire_maker.Wire()).Face()

    # Depth along the plane's own normal - identical technique to `_surface_
    # block`'s own depth calc (project the target's bounding-box corners
    # onto the normal axis through the plane's own origin, take the largest
    # positive value plus margin): the curve/loop above already sits
    # exactly on the plane (w=0), so only the `+normal` side needs to clear
    # the target Body, exactly like `_plane_block`'s own single-sided box.
    normal = basis_normal(basis)
    ox, oy, oz = basis.origin
    nx, ny, nz = normal.X(), normal.Y(), normal.Z()
    depth_margin = target_diagonal + _MARGIN_PADDING
    ws = [(cx - ox) * nx + (cy - oy) * ny + (cz - oz) * nz for cx, cy, cz in corners]
    depth = max(max(ws), 0.0) + depth_margin
    vector = gp_Vec(nx * depth, ny * depth, nz * depth)
    return BRepPrimAPI_MakePrism(face, vector).Shape()


def _split_tool_block(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    tool: SplitToolRef,
    target_shape: TopoDS_Shape,
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """Resolves `tool` (see `SplitToolRef`'s own docstring for its three
    mutually-exclusive kinds) to its own oversized half-space block -
    `None` when the referenced Feature/Sketch entity no longer exists, or
    its own resolution does (see `_surface_block`'s/`_sketch_line_block`'s
    own docstrings)."""
    if tool.plane_ref is not None:
        try:
            basis = resolve_plane_ref(part, bodies, tool.plane_ref, excluded_feature_ids)
        except HTTPException:
            return None
        return _plane_block(basis, target_shape)

    if tool.surface_feature_id is not None:
        surface_feature = part.get_feature(tool.surface_feature_id)
        if not isinstance(surface_feature, SurfaceFeature):
            return None
        return _surface_block(part, bodies, surface_feature, target_shape, excluded_feature_ids)

    assert tool.sketch_line_ref is not None
    return _sketch_line_block(part, bodies, tool.sketch_line_ref, target_shape, excluded_feature_ids)


def resolve_split_pieces(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: SplitFeature,
    excluded_feature_ids: frozenset[str],
) -> tuple[TopoDS_Shape, TopoDS_Shape] | None:
    """The two pieces `feature` divides `feature.target_body_id`'s current
    shape into - `(piece_a, piece_b)`, `piece_a` on the tool's own `+` side
    (`BRepAlgoAPI_Common`), `piece_b` everything else (`BRepAlgoAPI_Cut`) -
    or `None` if the target Body doesn't currently exist, or the tool can't
    currently be resolved (see `_split_tool_block`). Callers (`app.document.
    extrude.compute_part_bodies`'s own `SplitFeature` branch, `resolve_
    split`'s own fail-closed router wrapper below) decide what `None` means
    for them - skip-and-warn for the former, a structured 422 for the
    latter, mirroring every other resolver in this codebase that splits
    "resolve, tolerantly" from "resolve, or fail closed" this same way."""
    if feature.target_body_id not in bodies:
        logger.warning(
            "Skipping SplitFeature %s: target body %s does not currently exist",
            feature.id,
            feature.target_body_id,
        )
        return None
    target_shape = bodies[feature.target_body_id]
    block = _split_tool_block(part, bodies, feature.tool, target_shape, excluded_feature_ids)
    if block is None:
        logger.warning("Skipping SplitFeature %s: its cutting tool could not be resolved", feature.id)
        return None
    piece_a = BRepAlgoAPI_Common(target_shape, block).Shape()
    piece_b = BRepAlgoAPI_Cut(target_shape, block).Shape()
    return piece_a, piece_b


def resolve_split(
    part: Part, feature: SplitFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[TopoDS_Shape, TopoDS_Shape]:
    """Fresh entry point for the router's create/update eager-resolve-to-
    validate calls, mirroring `app.document.mirror.resolve_mirror`'s own
    self-exclusion convention exactly: computes `bodies` as if `feature`
    weren't in `part.features` yet, then raises a structured `missing_
    reference` 422 if `resolve_split_pieces` returns `None` rather than
    silently skipping - this is the router's own fail-closed validation
    path, not `compute_part_bodies`'s resilient mid-mesh tolerance."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    result = resolve_split_pieces(part, bodies, feature, all_excluded)
    if result is None:
        raise HTTPException(status_code=422, detail={"type": "missing_reference", "feature_id": feature.id})
    return result
