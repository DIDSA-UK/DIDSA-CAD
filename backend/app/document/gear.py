"""OCCT geometry construction for `GearFeature`
(`docs/gear-design/02-gear-feature.md`) - the OCCT-dependent half of
`app.document.gear_math`'s pure math, mirroring the split every other
Feature module in this codebase keeps between its own `*_math.py`/
pure-Python helpers and its OCCT construction (see
`docs/gear-design/00-conventions.md`).

**Verification status, stated honestly**: this module has never been run
against real `pythonocc-core` - this repo's dev sandbox doesn't have it
installed (see `docs/gear-design/01-gear-math-core.md`'s own note on this).
Written to mirror `app.document.extrude`/`app.document.fillet`'s existing,
proven OCCT idioms as closely as possible (real `Geom_BSplineCurve` tooth
flanks via `GeomAPI_Interpolate`, the same face-with-holes pattern
`app.document.extrude.face_for_profile` already uses for an internal
gear's annulus, the same `BRepFilletAPI_MakeFillet` class
`app.document.fillet` already uses for the optional root fillet), but
needs a real on-device/CI pass (this repo's CI does have `pythonocc-core`)
before being trusted, same as every other genuinely new OCCT technique in
this project.
"""

import logging
import math
from dataclasses import replace

from fastapi import HTTPException
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakeWire,
)
from OCC.Core.BRepFilletAPI import BRepFilletAPI_MakeFillet
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_ThruSections
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakePrism
from OCC.Core.GeomAPI import GeomAPI_Interpolate
from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Vec
from OCC.Core.TColgp import TColgp_HArray1OfPnt
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_VERTEX
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Edge, TopoDS_Shape, TopoDS_Vertex, TopoDS_Wire, topods

from app.document.create_plane import resolve_plane_ref
from app.document.extrude import _wire_normal, basis_normal, basis_point_to_world, compute_part_bodies
from app.document.gear_math import (
    GearGeometryError,
    SpurGearGeometry,
    full_gear_profile_by_tooth,
    helical_twist_angle,
    minimum_profile_shift_to_avoid_undercut,
    spur_gear_geometry,
    undercut_warning,
)
from app.document.models import GearFeature, Part, ResolvedPlane

logger = logging.getLogger(__name__)


def _invalid_gear_parameters(detail: str) -> HTTPException:
    """A gear parameter combination `gear_math` itself rejects
    (`GearGeometryError`) - mirrors `app.document.sweep._invalid_path_ref`'s
    own "client-supplied-parameters problem" 422 convention."""
    return HTTPException(status_code=422, detail={"type": "invalid_gear_parameters", "detail": detail})


def _gear_failed(detail: str) -> HTTPException:
    """A structurally-valid gear that OCCT nonetheless couldn't build -
    mirrors `app.document.sweep._sweep_failed`'s own "resolvable
    parameters, unresolvable geometry" distinction."""
    return HTTPException(status_code=422, detail={"type": "gear_failed", "detail": detail})


def _bspline_flank_edge(basis: ResolvedPlane, local_points: list[tuple[float, float]]) -> TopoDS_Edge:
    """One tooth flank's sampled points, fit as a single real
    `Geom_BSplineCurve` edge via `GeomAPI_Interpolate` - the only choice
    that keeps STEP export genuinely smooth (`00-conventions.md`), not a
    polyline of short straight edges. `local_points` are in the gear's own
    local 2D frame (gear centre at the origin); each is embedded into
    world space via `basis_point_to_world` before fitting, so the
    resulting curve already lives directly on `basis`'s own plane."""
    world_points = [basis_point_to_world(basis, x, y) for x, y in local_points]
    points_array = TColgp_HArray1OfPnt(1, len(world_points))
    for i, point in enumerate(world_points, start=1):
        points_array.SetValue(i, point)
    interpolator = GeomAPI_Interpolate(points_array, False, 1e-6)
    interpolator.Perform()
    if not interpolator.IsDone():
        raise _gear_failed("could not fit a smooth curve through a tooth flank's sampled points")
    return BRepBuilderAPI_MakeEdge(interpolator.Curve()).Edge()


def _straight_edge(basis: ResolvedPlane, p1: tuple[float, float], p2: tuple[float, float]) -> TopoDS_Edge:
    return BRepBuilderAPI_MakeEdge(basis_point_to_world(basis, *p1), basis_point_to_world(basis, *p2)).Edge()


def _gear_outline_wire(
    basis: ResolvedPlane, geometry: SpurGearGeometry, points_per_flank: int
) -> tuple[TopoDS_Wire, list[TopoDS_Vertex]]:
    """The whole gear's closed-loop outline: one real `Geom_BSplineCurve`
    edge per flank, a straight edge across each tooth's tip land (the two
    flanks of one tooth meet the addendum circle at two genuinely distinct
    points, not a single sharp apex - real gear teeth have a flat or
    slightly rounded top land), and a straight edge across each root gap
    between consecutive teeth.

    Also returns the world-space vertex at each root-gap edge's two ends
    (where a flank meets the root gap) - `resolve_gear_from_bodies`'s
    straight-tooth path and `_twisted_tooth_loft`'s helical/herringbone
    path each need these afterward to locate the corresponding lateral
    edges of the extruded/lofted solid for the optional root fillet
    (`BRepPrimAPI_MakePrism.Generated()`/`BRepOffsetAPI_ThruSections.
    Generated()` both map an original wire vertex to its generated lateral
    edge - the same "map original topology through the operation" idiom
    `app.document.fillet`'s own edge picking already relies on OCCT for,
    just via `Generated()` instead of a `SubShapeRef`)."""
    by_tooth = full_gear_profile_by_tooth(geometry, points_per_flank)
    wire_maker = BRepBuilderAPI_MakeWire()

    tooth_count = len(by_tooth)
    for i in range(tooth_count):
        right, left = by_tooth[i]
        next_right, _ = by_tooth[(i + 1) % tooth_count]

        wire_maker.Add(_bspline_flank_edge(basis, right))
        wire_maker.Add(_straight_edge(basis, right[-1], left[0]))  # tip land
        wire_maker.Add(_bspline_flank_edge(basis, left))
        wire_maker.Add(_straight_edge(basis, left[-1], next_right[0]))  # root gap

    # Root-corner vertices are read back from the assembled wire's own
    # EDGES (_root_corner_vertices_from_wire), not the standalone edges
    # built above and not a raw vertex-level wire traversal either -
    # BRepBuilderAPI_MakeWire may share/rebuild vertices as it stitches
    # edges together, so the vertices that actually appear in the final
    # wire (and are therefore the ones BRepPrimAPI_MakePrism.Generated()
    # will recognise later) are the wire's own. Walking EDGES rather than
    # VERTICES avoids a real ambiguity: TopExp_Explorer(wire, TopAbs_VERTEX)
    # does not guarantee one entry per unique vertex (a vertex shared by
    # two consecutive edges can be visited once per adjacent edge) - this
    # codebase's own existing code already reaches for
    # TopTools_IndexedMapOfShape specifically to guard against exactly
    # that. Edges have no such ambiguity: each of the 4*tooth_count edges
    # added above is distinct and appears exactly once in traversal order.
    wire = wire_maker.Wire()
    return wire, _root_corner_vertices_from_wire(wire, tooth_count)


def _root_corner_vertices_from_wire(wire: TopoDS_Wire, tooth_count: int) -> list[TopoDS_Vertex]:
    """Every 4th edge of the assembled wire (right-flank, tip-land,
    left-flank, root-gap, repeating per tooth in the exact order
    `_gear_outline_wire` adds edges) is a root-gap edge; both of *its* own
    two vertices are root-corner points (unambiguous - a single edge has
    exactly two vertices, no traversal-order question to get wrong the way
    a whole wire's vertex list would be). Different teeth's root-gap edges
    never share a vertex with each other, so no deduplication is needed -
    each root-gap edge contributes exactly 2 distinct vertices."""
    edges: list[TopoDS_Edge] = []
    edge_explorer = TopExp_Explorer(wire, TopAbs_EDGE)
    while edge_explorer.More():
        edges.append(topods.Edge(edge_explorer.Current()))
        edge_explorer.Next()

    root_edges = edges[3::4][:tooth_count]
    vertices: list[TopoDS_Vertex] = []
    for root_edge in root_edges:
        vertex_explorer = TopExp_Explorer(root_edge, TopAbs_VERTEX)
        while vertex_explorer.More():
            vertices.append(topods.Vertex(vertex_explorer.Current()))
            vertex_explorer.Next()
    return vertices


def _gear_face(
    basis: ResolvedPlane, is_internal: bool, outer_diameter: float | None, geometry: SpurGearGeometry, wire: TopoDS_Wire
):
    """External gear: the tooth-profile wire alone bounds the face (solid
    star shape, no hole). Internal gear: the tooth-profile wire is the
    *inner* boundary (a hole - the bore where a mating pinion sits, teeth
    pointing inward per `spur_gear_geometry`'s `is_internal` sign flip),
    with a plain circle at `outer_diameter / 2` as the outer rim - same
    `BRepBuilderAPI_MakeFace(outer).Add(inner)` idiom `app.document.extrude.
    face_for_profile` already uses for a Sketch profile's own inner loops,
    including the same winding-direction check (`_wire_normal` dot product)
    since `.Add` does not reorient a hole wire for you.

    Takes `is_internal`/`outer_diameter` as plain values rather than a whole
    `GearFeature` (`resolve_gear_from_bodies`'s original shape) so
    `docs/gear-design/05-gear-chain-and-planetary.md`'s `GearChainFeature`
    can reuse this directly for one chain member at a time, which has no
    `GearFeature` of its own to pass - mirrors this codebase's established
    "promote to an explicit-params helper once a second caller needs it"
    convention (see e.g. `app.document.create_plane.resolve_plane_ref`'s own
    docstring)."""
    if not is_internal:
        return BRepBuilderAPI_MakeFace(wire).Face()

    assert outer_diameter is not None  # enforced by the router before this is ever called
    outer_radius = outer_diameter / 2
    if outer_radius <= geometry.dedendum_radius:
        raise _invalid_gear_parameters(
            f"outer_diameter ({outer_diameter!r}) must exceed the tooth profile's own outer "
            f"reach (dedendum diameter {geometry.dedendum_radius * 2!r}) - there is no rim material left "
            "otherwise"
        )
    axis = gp_Ax2(basis_point_to_world(basis, 0.0, 0.0), basis_normal(basis))
    outer_edge = BRepBuilderAPI_MakeEdge(gp_Circ(axis, outer_radius)).Edge()
    outer_wire = BRepBuilderAPI_MakeWire(outer_edge).Wire()

    face_maker = BRepBuilderAPI_MakeFace(outer_wire)
    inner_wire = wire
    if _wire_normal(inner_wire).Dot(_wire_normal(outer_wire)) > 0:
        inner_wire = inner_wire.Reversed()
    face_maker.Add(inner_wire)
    return face_maker.Face()


def _apply_root_fillet(
    prism_maker: BRepPrimAPI_MakePrism, solid: TopoDS_Shape, root_corner_vertices: list[TopoDS_Vertex], radius: float
) -> tuple[TopoDS_Shape, str | None]:
    """Rounds the axial edge at each root-gap corner (where a flank's side
    face meets the root edge's side face, running the full `face_width`
    depth) - the geometrically correct thing to round for a "root fillet"
    (not the top/bottom rim edges). `prism_maker.Generated(vertex)` maps
    an original (pre-extrusion) wire vertex to the lateral edge(s) it
    generated in the prism - the standard OCCT sweep-history idiom for
    exactly this.

    Best-effort: if the fillet construction doesn't converge (same
    `IsDone()` failure mode `app.document.fillet` already handles), falls
    back to the unfilleted solid rather than failing the whole Feature - a
    root fillet improves strength but an unfilleted gear is still a valid,
    meshable gear. Returns `(solid, warning)` rather than just `solid` -
    `warning` is a non-`None` user-facing message on the fallback path (on-
    device testing found the pre-existing `logger.warning`-only version of
    this genuinely invisible: a too-large radius silently produced an
    unfilleted gear with zero signal anywhere in the HTTP response or UI),
    `None` when the fillet actually converged."""
    fillet_maker = BRepFilletAPI_MakeFillet(solid)
    edge_count = 0
    for vertex in root_corner_vertices:
        for generated in prism_maker.Generated(vertex):
            if generated.ShapeType() != TopAbs_EDGE:
                continue
            fillet_maker.Add(radius, topods.Edge(generated))
            edge_count += 1
    if edge_count == 0:
        warning = "Root fillet requested but no root-corner edges were found - skipped"
        logger.warning(warning)
        return solid, warning
    fillet_maker.Build()
    if not fillet_maker.IsDone():
        warning = (
            f"Root fillet radius {radius!r} did not converge for this gear's geometry - "
            "falling back to an unfilleted gear. Try a smaller radius."
        )
        logger.warning("Gear root fillet did not converge (radius=%r) - falling back to unfilleted gear", radius)
        return solid, warning
    return fillet_maker.Shape(), None


def _apply_root_fillet_to_loft(
    loft_maker: BRepOffsetAPI_ThruSections,
    solid: TopoDS_Shape,
    root_corner_vertices: list[TopoDS_Vertex],
    radius: float,
) -> tuple[TopoDS_Shape, str | None]:
    """`_apply_root_fillet`'s counterpart for a twisted-tooth `ThruSections`
    loft rather than a straight-tooth `BRepPrimAPI_MakePrism`. Same
    "map an original wire vertex to its generated lateral edge, fillet
    that edge" idiom, just sourced from `BRepOffsetAPI_ThruSections.
    Generated()` instead of `BRepPrimAPI_MakePrism.Generated()` -
    `ThruSections` is, like every `BRepBuilderAPI_MakeShape` subclass, a
    real shape-history producer (its own `Generated()` override is
    redefined precisely to report exactly this: which lateral "rib" edge a
    given input section's vertex generated). The rib edge for a twisted
    tooth is a genuinely curved 3D edge (it follows the tooth's own twist
    across the loft's whole height), not the straight vertical edge the
    prism case fillets - `BRepFilletAPI_MakeFillet.Add` doesn't care, it
    fillets whichever kind of edge it's given identically either way, so
    only the *source* of the edge differs from `_apply_root_fillet`, not
    the fillet construction itself. Passing either section's own root-
    corner vertices works equally well (`Generated()` on either endpoint
    of the same rib edge returns that same edge) - the caller picks
    whichever section is more convenient (see `_helical_or_herringbone_
    solid`, which uses each herringbone half's own *outer* section so the
    shared mid-plane seam is left unfilleted, matching how a real hobbed
    herringbone gear's root looks at that reversal point).

    Newer, less-proven territory than `_apply_root_fillet` (this is the
    first time this codebase has asked `ThruSections` for its own
    `Generated()` history at all) - needs the same real on-device/CI
    `pythonocc-core` pass as the rest of this module before being trusted,
    doubly so here specifically."""
    fillet_maker = BRepFilletAPI_MakeFillet(solid)
    edge_count = 0
    for vertex in root_corner_vertices:
        for generated in loft_maker.Generated(vertex):
            if generated.ShapeType() != TopAbs_EDGE:
                continue
            fillet_maker.Add(radius, topods.Edge(generated))
            edge_count += 1
    if edge_count == 0:
        warning = "Root fillet requested but no root-corner edges were found on the twisted tooth loft - skipped"
        logger.warning(warning)
        return solid, warning
    fillet_maker.Build()
    if not fillet_maker.IsDone():
        warning = (
            f"Root fillet radius {radius!r} did not converge for this helical/herringbone gear's geometry - "
            "falling back to an unfilleted gear. Try a smaller radius."
        )
        logger.warning(
            "Helical/herringbone gear root fillet did not converge (radius=%r) - falling back to unfilleted gear",
            radius,
        )
        return solid, warning
    return fillet_maker.Shape(), None


def _twisted_basis(basis: ResolvedPlane, height: float, twist: float) -> ResolvedPlane:
    """`docs/gear-design/04-helical-herringbone-loft.md` (Workstream 4a): a
    `ResolvedPlane` identical to `basis` except shifted `height` along its
    own normal and with its in-plane `x_axis`/`y_axis` rotated by `twist`
    radians (CCW-positive, same convention `gear_math._rotate` uses) about
    that same normal.

    Embedding a profile's local (x, y) through *this* basis is
    mathematically identical to first rotating the profile's own real
    (x, y) coordinates by `twist` about the local origin and *then*
    embedding through the original, unshifted/unrotated `basis` -
    `basis_point_to_world`'s embedding (`origin + x*x_axis + y*y_axis`) is
    linear in (x, y), and rotation commutes with a linear map applied in
    the same plane it rotates within. This is exactly the pre-rotate-the-
    real-(x,y)-coordinates twist-control technique the 04 doc's own
    2026-08-04 spike confirmed (`Result 1`/`Implementation sketch` - no
    wire-reordering, no winding-direction correction needed), applied here
    by rotating the *basis* instead of every individual point so
    `_gear_outline_wire`/`_gear_face` can be reused completely unchanged
    for the twisted copy rather than duplicating their point-level
    construction."""
    ox, oy, oz = basis.origin
    nx, ny, nz = basis.normal
    shifted_origin = (ox + height * nx, oy + height * ny, oz + height * nz)
    cos_t, sin_t = math.cos(twist), math.sin(twist)
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    rotated_x_axis = (cos_t * xx + sin_t * yx, cos_t * xy + sin_t * yy, cos_t * xz + sin_t * yz)
    rotated_y_axis = (-sin_t * xx + cos_t * yx, -sin_t * xy + cos_t * yy, -sin_t * xz + cos_t * yz)
    return replace(basis, origin=shifted_origin, x_axis=rotated_x_axis, y_axis=rotated_y_axis)


def _twisted_tooth_loft(
    basis: ResolvedPlane,
    geometry: SpurGearGeometry,
    points_per_flank: int,
    bottom_height: float,
    bottom_twist: float,
    top_height: float,
    top_twist: float,
) -> tuple[TopoDS_Shape, BRepOffsetAPI_ThruSections, list[TopoDS_Vertex], list[TopoDS_Vertex]]:
    """One helical (or one herringbone half's) tooth-boundary solid: a
    `BRepOffsetAPI_ThruSections` loft between two twisted/shifted copies of
    `_gear_outline_wire`'s ordinary straight-tooth outline - the *primary*
    helical-tooth technique per the 04 doc's own spike (loft-between-two-
    rotated-profile-copies, not sweep-along-helix, which was prototyped and
    found to distort the cross-section). `ruled=False` (smooth mode): the
    spike found no measurable difference between ruled/smooth for a
    2-section loft (a spline fit through exactly 2 points degenerates to a
    straight line either way).

    `CheckCompatibility(False)` is the fix for a real reported bug (large
    helix angle -> a tooth's tip vertex visibly lofts to a *different*
    tooth's root vertex, not its own twisted counterpart -
    `docs/gear-design/04-helical-herringbone-loft.md`'s own dated addendum
    has the full root-cause writeup). `ThruSections` defaults to
    `CheckCompatibility(True)`: it *searches* for its own vertex-to-vertex
    correspondence between the two wires, explicitly trying to minimise the
    resulting surface's apparent twist - which is exactly wrong here, since
    `bottom_wire`/`top_wire` are already built with a known-correct,
    already-intentional correspondence (the exact same `_gear_outline_
    wire` code path, same tooth/flank/point order, same edge count, only
    ever differing by the deliberate `bottom_twist`/`top_twist` rotation
    baked into each one's own basis) - for a real gear tooth's own highly
    repetitive, near-symmetric profile (every tooth looks almost identical
    to its neighbour, just rotated by one angular tooth pitch), that
    search's own "minimise apparent twist" heuristic can converge on
    entirely the wrong correspondence once the *true* twist exceeds roughly
    half an angular tooth pitch - snapping a tip vertex onto a
    neighbouring tooth's root instead, still `IsDone()`-valid (a real,
    closed, buildable surface - just the wrong one). `CheckCompatibility
    (False)` turns this search off entirely and makes `ThruSections` trust
    the two wires' own edge-insertion order directly (edge *i* of
    `bottom_wire` <-> edge *i* of `top_wire`) - exactly the correspondence
    this function actually wants, and always safe here specifically because
    both wires are guaranteed the same edge count (`4 * tooth_count`,
    always, regardless of twist).

    Root-corner vertices for *both* sections are threaded back out (unlike
    a prior version of this function, which discarded them, before root
    fillet was believed unsupported here) so the caller can fillet a
    twisted tooth's root edge too - see `_apply_root_fillet_to_loft`."""
    bottom_basis = _twisted_basis(basis, bottom_height, bottom_twist)
    top_basis = _twisted_basis(basis, top_height, top_twist)
    bottom_wire, bottom_root_vertices = _gear_outline_wire(bottom_basis, geometry, points_per_flank)
    top_wire, top_root_vertices = _gear_outline_wire(top_basis, geometry, points_per_flank)

    loft_maker = BRepOffsetAPI_ThruSections(True, False)
    loft_maker.AddWire(bottom_wire)
    loft_maker.AddWire(top_wire)
    loft_maker.CheckCompatibility(False)
    loft_maker.Build()
    if not loft_maker.IsDone():
        raise _gear_failed("could not loft the helical tooth profile between its two twisted end sections")
    return loft_maker.Shape(), loft_maker, bottom_root_vertices, top_root_vertices


def _helical_or_herringbone_solid(
    basis: ResolvedPlane, feature: GearFeature, geometry: SpurGearGeometry, points_per_flank: int
) -> tuple[TopoDS_Shape, list[str]]:
    """The full helical/herringbone gear solid, plus any non-blocking root-
    fillet warnings - `resolve_gear_from_bodies`'s branch for
    `feature.helix_angle_degrees != 0.0`. Builds the twisted tooth-boundary
    solid (one loft for a plain helical gear, two lofts fused together for
    a herringbone gear's own mirrored halves - see `GearFeature.
    herringbone`'s own docstring for the "mirrored, not simply twice as
    tall" construction: bottom-to-midplane at `+half_twist`, midplane-to-
    top at `-half_twist` relative to the midplane, so both halves meet at
    zero *relative* twist at the shared midplane and the whole tooth
    returns to the same orientation at top and bottom), external exactly
    as-is, internal by cutting that same twisted solid out of a plain
    (untwisted - an internal gear's outer rim is a plain cylinder
    regardless of tooth twist) outer-rim prism, mirroring `_gear_face`'s
    own external/internal split but as two separate solids plus a boolean
    Cut instead of one face-with-a-hole plus one prism (`ThruSections`
    builds from wire sections, not faces-with-holes, so the single-face-
    with-a-hole trick the straight-tooth path uses doesn't apply directly
    here).

    Root fillet, if requested, is applied to each loft *before* the
    herringbone Fuse (or, for a plain helical gear, to the single loft
    directly) - using each solid's own `Generated()` history
    (`_apply_root_fillet_to_loft`) after a boolean Fuse would have no such
    history to work from. A herringbone gear's two halves are each
    filleted using only their own *outer* section's root-corner vertices
    (`bottom_half` at z=0, `top_half` at z=face_width) - the shared mid-
    plane seam where the two halves meet is deliberately left unfilleted,
    matching a real hobbed herringbone gear's own root at that reversal
    point (not a stress-concentration edge in the same way the two outer
    root corners are)."""
    warnings: list[str] = []
    total_twist = helical_twist_angle(geometry.pitch_radius, feature.face_width, feature.helix_angle_degrees)
    if feature.herringbone:
        half_width = feature.face_width / 2
        half_twist = helical_twist_angle(geometry.pitch_radius, half_width, feature.helix_angle_degrees)
        bottom_shape, bottom_loft, bottom_root_vertices, _ = _twisted_tooth_loft(
            basis, geometry, points_per_flank, 0.0, 0.0, half_width, half_twist
        )
        top_shape, top_loft, _, top_root_vertices = _twisted_tooth_loft(
            basis, geometry, points_per_flank, half_width, half_twist, feature.face_width, 0.0
        )
        if feature.root_fillet_radius > 0:
            bottom_shape, bottom_warning = _apply_root_fillet_to_loft(
                bottom_loft, bottom_shape, bottom_root_vertices, feature.root_fillet_radius
            )
            top_shape, top_warning = _apply_root_fillet_to_loft(
                top_loft, top_shape, top_root_vertices, feature.root_fillet_radius
            )
            warnings.extend(warning for warning in (bottom_warning, top_warning) if warning is not None)
        tooth_solid = BRepAlgoAPI_Fuse(bottom_shape, top_shape).Shape()
    else:
        tooth_solid, loft_maker, bottom_root_vertices, _ = _twisted_tooth_loft(
            basis, geometry, points_per_flank, 0.0, 0.0, feature.face_width, total_twist
        )
        if feature.root_fillet_radius > 0:
            tooth_solid, fillet_warning = _apply_root_fillet_to_loft(
                loft_maker, tooth_solid, bottom_root_vertices, feature.root_fillet_radius
            )
            if fillet_warning is not None:
                warnings.append(fillet_warning)

    if not feature.is_internal:
        return tooth_solid, warnings

    assert feature.outer_diameter is not None  # enforced by the router before this is ever called
    outer_radius = feature.outer_diameter / 2
    if outer_radius <= geometry.dedendum_radius:
        raise _invalid_gear_parameters(
            f"outer_diameter ({feature.outer_diameter!r}) must exceed the tooth profile's own outer "
            f"reach (dedendum diameter {geometry.dedendum_radius * 2!r}) - there is no rim material left "
            "otherwise"
        )
    axis = gp_Ax2(basis_point_to_world(basis, 0.0, 0.0), basis_normal(basis))
    outer_edge = BRepBuilderAPI_MakeEdge(gp_Circ(axis, outer_radius)).Edge()
    outer_wire = BRepBuilderAPI_MakeWire(outer_edge).Wire()
    outer_face = BRepBuilderAPI_MakeFace(outer_wire).Face()
    normal = basis_normal(basis)
    prism_vector = gp_Vec(normal.X(), normal.Y(), normal.Z()).Multiplied(feature.face_width)
    outer_solid = BRepPrimAPI_MakePrism(outer_face, prism_vector).Shape()
    return BRepAlgoAPI_Cut(outer_solid, tooth_solid).Shape(), warnings


def resolve_gear_profile_shift(
    *,
    module: float,
    tooth_count: int,
    pressure_angle_degrees: float,
    backlash: float,
    profile_shift: float | None,
    is_internal: bool,
) -> float:
    """Resolves `GearFeature.profile_shift` (`float | None` - `None` meaning
    "auto") to a concrete float - the undercut-avoidance counterpart to
    `app.document.bevel_pair.resolve_member_profile_shifts`. An explicit
    value always wins (returned unchanged), same "explicit always wins"
    rule that module's own docstring establishes.

    Unlike that bevel pair resolver's own bisected two-pass search (each
    member's own margin depends on the *other* member's geometry, with no
    algebraic inverse), undercut avoidance for a single ordinary gear is
    invertible in closed form directly from `gear_math.minimum_tooth_
    count_without_undercut`'s own formula - `gear_math.minimum_profile_
    shift_to_avoid_undercut` gives the exact smallest shift that clears
    undercut at `tooth_count`, no search needed.

    Auto only ever *raises* `profile_shift` off its naive `0.0` default,
    never lowers it below - a gear whose `tooth_count` already clears the
    undercut-free minimum at `0.0` shift keeps `0.0` exactly (`min_shift <=
    0.0` short-circuits before any geometry is built), leaving every
    GearFeature persisted before this could auto-resolve byte-identical.
    Internal gears never undercut this way (the tooth points inward, not
    outward - `01-gear-math-core.md`'s formula is derived for an external
    cutter path), same `is_internal` exemption `/gear/preview`'s own
    undercut warning already carries - auto always resolves to `0.0` for
    one.

    The closed-form `min_shift` can itself yield invalid gear geometry at
    the extreme end (a very low `tooth_count`/`pressure_angle_degrees`
    combination can push it past what `spur_gear_geometry` still accepts -
    see that formula's own docstring) - verified with a real `spur_gear_
    geometry` call before ever being applied automatically; a `Gear
    GeometryError` there falls back to the naive `0.0` default rather than
    proposing a shift that would make `resolve_gear_from_bodies`'s own
    subsequent real geometry call fail outright."""
    if profile_shift is not None:
        return profile_shift
    if is_internal:
        return 0.0
    min_shift = minimum_profile_shift_to_avoid_undercut(tooth_count, pressure_angle_degrees)
    if min_shift <= 0.0:
        return 0.0
    try:
        spur_gear_geometry(
            module=module,
            tooth_count=tooth_count,
            pressure_angle_degrees=pressure_angle_degrees,
            profile_shift=min_shift,
            backlash=backlash,
            is_internal=False,
        )
    except GearGeometryError:
        return 0.0
    return min_shift


def resolve_gear_from_bodies(
    feature: GearFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> tuple[TopoDS_Shape, list[str]]:
    """The real OCCT solid for one `GearFeature`, plus any non-blocking
    `warnings` - parameters straight in, solid (and warnings) straight out,
    no backing Sketch at any point (`00-conventions.md`'s "gear teeth are
    not Sketch entities" decision). Raises a structured `HTTPException`
    (`invalid_gear_parameters`/`gear_failed`) rather than returning `None`
    - unlike `ExtrudeFeature`'s "skip if the backing Sketch has no profile"
    tolerance, a `GearFeature` has no equivalent "temporarily has nothing
    to build" state; a bad parameter combination is always a real error to
    surface, not a transient/expected one to silently skip.

    `warnings` covers every case where a requested `root_fillet_radius`
    couldn't actually be honoured - a straight tooth whose fillet didn't
    converge (`_apply_root_fillet`) or a helical/herringbone tooth's own
    loft-based fillet (`_apply_root_fillet_to_loft`) either not converging
    or finding no root-corner edges at all - each used to be (straight-
    tooth case) a `logger.warning`-only server-side event with no signal
    anywhere in the HTTP response or UI, or (helical/herringbone case)
    unsupported outright, a real on-device gap (see docs/status.md's dated
    entries for both fixes). Mirrors `app.document.loft.
    resolve_loft_from_bodies`'s own `(shape, warnings)` shape exactly.

    Also covers `gear_math.undercut_warning` for an external gear whose
    resolved `profile_shift` (`resolve_gear_profile_shift` - only reached
    when the feature's own field is an explicit value, since auto is
    resolved specifically to clear this) still leaves `tooth_count` below
    the undercut-free minimum - previously only surfaced by the `/gear/
    preview` endpoint, never by the real Feature itself.

    `feature.helix_angle_degrees == 0.0` (the default) takes the exact
    original straight-tooth `BRepPrimAPI_MakePrism` path unchanged - see
    `GearFeature`'s own docstring for why this keeps every gear persisted
    before Workstream 4a byte-identical. A non-zero value (or
    `feature.herringbone`) instead builds via `_helical_or_herringbone_
    solid`."""
    if not (-90 < feature.helix_angle_degrees < 90):
        raise _invalid_gear_parameters(
            f"helix_angle_degrees must be in (-90, 90), got {feature.helix_angle_degrees!r}"
        )
    if feature.points_per_flank < 2:
        # Mirrors gear_math.sample_involute_flank's own `point_count must be
        # >= 2` floor - checked here too (rather than only inside gear_math,
        # several calls deep) so a bad value fails closed with the same
        # clean 422 every other bad GearFeature parameter gets, instead of
        # an uncaught GearGeometryError surfacing as a 500 from partway
        # through wire construction.
        raise _invalid_gear_parameters(f"points_per_flank must be >= 2, got {feature.points_per_flank!r}")
    resolved_profile_shift = resolve_gear_profile_shift(
        module=feature.module,
        tooth_count=feature.tooth_count,
        pressure_angle_degrees=feature.pressure_angle_degrees,
        backlash=feature.backlash,
        profile_shift=feature.profile_shift,
        is_internal=feature.is_internal,
    )
    try:
        geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=feature.tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            profile_shift=resolved_profile_shift,
            backlash=feature.backlash,
            root_fillet_radius=feature.root_fillet_radius,
            is_internal=feature.is_internal,
        )
    except GearGeometryError as exc:
        raise _invalid_gear_parameters(str(exc)) from exc

    if feature.is_internal and feature.outer_diameter is None:
        raise _invalid_gear_parameters("outer_diameter is required for an internal gear")
    if feature.face_width <= 0:
        raise _invalid_gear_parameters(f"face_width must be positive, got {feature.face_width!r}")

    # Non-blocking - only meaningful for an external gear (mirrors
    # resolve_gear_profile_shift's own is_internal exemption above); an
    # explicit profile_shift that still undercuts surfaces here too
    # ("explicit always wins" means auto never overrides it - the warning
    # is how that gets surfaced instead, same as bevel_pair's own
    # unfixable-explicit-intruder-shift case).
    warnings: list[str] = []
    if not feature.is_internal:
        warning = undercut_warning(feature.tooth_count, feature.pressure_angle_degrees, resolved_profile_shift)
        if warning is not None:
            warnings.append(warning)

    basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)

    if feature.helix_angle_degrees != 0.0 or feature.herringbone:
        solid, build_warnings = _helical_or_herringbone_solid(basis, feature, geometry, feature.points_per_flank)
        return solid, warnings + build_warnings

    wire, root_corner_vertices = _gear_outline_wire(basis, geometry, feature.points_per_flank)
    face = _gear_face(basis, feature.is_internal, feature.outer_diameter, geometry, wire)

    normal = basis_normal(basis)
    prism_vector = gp_Vec(normal.X(), normal.Y(), normal.Z()).Multiplied(feature.face_width)
    prism_maker = BRepPrimAPI_MakePrism(face, prism_vector)
    solid = prism_maker.Shape()

    if feature.root_fillet_radius > 0:
        solid, fillet_warning = _apply_root_fillet(
            prism_maker, solid, root_corner_vertices, feature.root_fillet_radius
        )
        if fillet_warning is not None:
            warnings.append(fillet_warning)

    return solid, warnings


def resolve_gear(
    part: Part, feature: GearFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[TopoDS_Shape, list[str]]:
    """Fresh entry point for the router's create/update validation -
    mirrors `app.document.fillet.resolve_fillet`'s own shape exactly:
    computes `bodies` *as if `feature` weren't in `part.features` yet*
    (excludes its own id in addition to whatever the caller already
    excludes), so validating a candidate edit to an existing `GearFeature`
    is checked against the Part's shape before this Feature's own effect,
    not stacked on top of it."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_gear_from_bodies(feature, part, bodies, excluded_feature_ids | {feature.id})


# ---------------------------------------------------------------------------
# Coarse (LOD) construction - `docs/lod-strategy/01-design.md` SS3: a single
# `BRepPrimAPI_MakeCylinder` sized from this gear's own addendum diameter and
# face width, standing in for the real tooth-by-tooth solid above. Applied
# unconditionally (no `helix_angle_degrees`/herringbone gate - a cylinder is
# equally cheap regardless of those parameters, so there is no server-side
# "is this one actually expensive" classification to make; whether/when to
# actually show this to the user instead of the real geometry is a client-
# side timing decision, out of this chunk's own scope per the design's SS8
# chunk breakdown).
#
# **Never persisted, never enters the Feature graph** - this is a pure
# rendering-layer stand-in computed on demand by `app.document.router`'s
# `tier=coarse` mesh query and coarse-preview endpoints only. It is never
# the input to any Boolean/Boss/Cut resolution - `resolve_gear_from_bodies`
# above (the real construction) is what every downstream Feature always
# resolves against, unconditionally.


def coarse_gear_solid(basis: ResolvedPlane, radius: float, face_width: float) -> TopoDS_Shape:
    """The coarse stand-in itself: one plain cylinder, `radius` around
    `basis`'s own axis (its origin/normal - the same axis
    `resolve_gear_from_bodies`'s own straight-tooth path extrudes along),
    `face_width` tall. Shared by `app.document.gear_chain`/`app.document.
    planetary_gear`'s own coarse builders (per `01-design.md` SS3's "cylinder
    for gears... members" row) - a chain/planetary member has no
    `GearFeature` of its own to pass, just a resolved radius/face_width by
    different field paths, mirroring `_gear_face`'s own "promote to an
    explicit-params helper once a second caller needs it" convention."""
    axis = gp_Ax2(basis_point_to_world(basis, 0.0, 0.0), basis_normal(basis))
    return BRepPrimAPI_MakeCylinder(axis, radius, face_width).Shape()


def coarse_gear_radius_from_geometry(
    is_internal: bool, outer_diameter: float | None, geometry: SpurGearGeometry
) -> float:
    """The radius a coarse stand-in cylinder should use for an already-
    resolved `SpurGearGeometry` - `outer_diameter / 2` for an internal gear
    (its real rim, already the coarsest correct proxy for "the material
    this gear occupies"; the tooth-inward annulus detail is exactly what
    coarse is meant to skip - mirrors `_gear_face`'s own internal/external
    split), otherwise the external gear's own real `addendum_radius`. Takes
    plain params rather than a whole `GearFeature` (mirrors `_gear_face`'s
    own "promote to an explicit-params helper once a second caller needs
    it" convention) so `app.document.gear_chain`/`app.document.
    planetary_gear`'s own coarse builders can reuse this directly for one
    chain/planetary member at a time, neither of which has a `GearFeature`
    of its own to pass."""
    if is_internal:
        assert outer_diameter is not None  # enforced by each caller before this is ever reached
        return outer_diameter / 2
    return geometry.addendum_radius


def coarse_gear_radius(feature: GearFeature) -> float:
    """The radius `resolve_gear_coarse_from_bodies` builds its stand-in
    cylinder at - cheap pure-Python math only (no OCCT, no tooth wire/loft
    construction), per `01-design.md` SS2's "computed synchronously in
    milliseconds" requirement. Reuses `resolve_gear_profile_shift`/`spur_
    gear_geometry` exactly as `resolve_gear_from_bodies` does, so a coarse
    and full build agree on which resolved `profile_shift` they're each
    sizing against - not a second, drifting copy of that resolution."""
    resolved_profile_shift = resolve_gear_profile_shift(
        module=feature.module,
        tooth_count=feature.tooth_count,
        pressure_angle_degrees=feature.pressure_angle_degrees,
        backlash=feature.backlash,
        profile_shift=feature.profile_shift,
        is_internal=feature.is_internal,
    )
    try:
        geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=feature.tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            profile_shift=resolved_profile_shift,
            backlash=feature.backlash,
            is_internal=feature.is_internal,
        )
    except GearGeometryError as exc:
        raise _invalid_gear_parameters(str(exc)) from exc
    return coarse_gear_radius_from_geometry(feature.is_internal, feature.outer_diameter, geometry)


def resolve_gear_coarse_from_bodies(
    feature: GearFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The coarse stand-in for one `GearFeature`, positioned exactly like
    `resolve_gear_from_bodies`'s own real solid (same `resolve_plane_ref`
    call) but built from `coarse_gear_solid` instead of the real tooth
    construction - `app.document.router`'s `tier=coarse` mesh query and
    coarse-preview endpoint both call this, never anything that persists
    or registers against the Feature graph."""
    if feature.is_internal and feature.outer_diameter is None:
        raise _invalid_gear_parameters("outer_diameter is required for an internal gear")
    if feature.face_width <= 0:
        raise _invalid_gear_parameters(f"face_width must be positive, got {feature.face_width!r}")
    basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)
    radius = coarse_gear_radius(feature)
    return coarse_gear_solid(basis, radius, feature.face_width)


def resolve_gear_coarse(
    part: Part, feature: GearFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for a not-yet-created `GearFeature` payload (the
    coarse-preview endpoint) or for `tier=coarse` mesh serving - mirrors
    `resolve_gear`'s own self-exclusion convention exactly."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_gear_coarse_from_bodies(feature, part, bodies, excluded_feature_ids | {feature.id})
