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
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
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
    spur_gear_geometry,
)
from app.document.models import GearFeature, Part, ResolvedPlane

logger = logging.getLogger(__name__)

# 01-gear-math-core.md's own "~10-20 sampled points per flank" target,
# same default gear_math.py's own functions already use.
_POINTS_PER_FLANK = 12


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
    (where a flank meets the root gap) - `resolve_gear_from_bodies` needs
    these afterward to locate the corresponding axial edges of the
    extruded solid for the optional root fillet (`BRepPrimAPI_MakePrism.
    Generated()` maps an original wire vertex to its generated lateral
    edge in the prism - the same "map original topology through the
    operation" idiom `app.document.fillet`'s own edge picking already
    relies on OCCT for, just via `Generated()` instead of a `SubShapeRef`)."""
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


def _gear_face(basis: ResolvedPlane, feature: GearFeature, geometry: SpurGearGeometry, wire: TopoDS_Wire):
    """External gear: the tooth-profile wire alone bounds the face (solid
    star shape, no hole). Internal gear: the tooth-profile wire is the
    *inner* boundary (a hole - the bore where a mating pinion sits, teeth
    pointing inward per `spur_gear_geometry`'s `is_internal` sign flip),
    with a plain circle at `feature.outer_diameter / 2` as the outer rim -
    same `BRepBuilderAPI_MakeFace(outer).Add(inner)` idiom
    `app.document.extrude.face_for_profile` already uses for a Sketch
    profile's own inner loops, including the same winding-direction check
    (`_wire_normal` dot product) since `.Add` does not reorient a hole
    wire for you."""
    if not feature.is_internal:
        return BRepBuilderAPI_MakeFace(wire).Face()

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

    face_maker = BRepBuilderAPI_MakeFace(outer_wire)
    inner_wire = wire
    if _wire_normal(inner_wire).Dot(_wire_normal(outer_wire)) > 0:
        inner_wire = inner_wire.Reversed()
    face_maker.Add(inner_wire)
    return face_maker.Face()


def _apply_root_fillet(
    prism_maker: BRepPrimAPI_MakePrism, solid: TopoDS_Shape, root_corner_vertices: list[TopoDS_Vertex], radius: float
) -> TopoDS_Shape:
    """Rounds the axial edge at each root-gap corner (where a flank's side
    face meets the root edge's side face, running the full `face_width`
    depth) - the geometrically correct thing to round for a "root fillet"
    (not the top/bottom rim edges). `prism_maker.Generated(vertex)` maps
    an original (pre-extrusion) wire vertex to the lateral edge(s) it
    generated in the prism - the standard OCCT sweep-history idiom for
    exactly this.

    Best-effort: if the fillet construction doesn't converge (same
    `IsDone()` failure mode `app.document.fillet` already handles), falls
    back to the unfilleted solid with a warning rather than failing the
    whole Feature - a root fillet improves strength but an unfilleted gear
    is still a valid, meshable gear."""
    fillet_maker = BRepFilletAPI_MakeFillet(solid)
    edge_count = 0
    for vertex in root_corner_vertices:
        for generated in prism_maker.Generated(vertex):
            if generated.ShapeType() != TopAbs_EDGE:
                continue
            fillet_maker.Add(radius, topods.Edge(generated))
            edge_count += 1
    if edge_count == 0:
        logger.warning("Gear root fillet requested but no root-corner edges were found - skipping")
        return solid
    fillet_maker.Build()
    if not fillet_maker.IsDone():
        logger.warning("Gear root fillet did not converge (radius=%r) - falling back to unfilleted gear", radius)
        return solid
    return fillet_maker.Shape()


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
) -> TopoDS_Shape:
    """One helical (or one herringbone half's) tooth-boundary solid: a
    `BRepOffsetAPI_ThruSections` loft between two twisted/shifted copies of
    `_gear_outline_wire`'s ordinary straight-tooth outline - the *primary*
    helical-tooth technique per the 04 doc's own spike (loft-between-two-
    rotated-profile-copies, not sweep-along-helix, which was prototyped and
    found to distort the cross-section). `ruled=False` (smooth mode): the
    spike found no measurable difference between ruled/smooth for a
    2-section loft (a spline fit through exactly 2 points degenerates to a
    straight line either way).

    Root-corner vertices aren't threaded through here (unlike
    `resolve_gear_from_bodies`'s straight-tooth path) - a `ThruSections`
    loft has no `BRepPrimAPI_MakePrism.Generated()`-equivalent vertex-
    tracking `_apply_root_fillet` could use, so root fillet is not
    currently supported for a helical/herringbone tooth (see
    `GearFeature`'s own docstring) - the caller skips it with a warning
    instead of calling this differently."""
    bottom_basis = _twisted_basis(basis, bottom_height, bottom_twist)
    top_basis = _twisted_basis(basis, top_height, top_twist)
    bottom_wire, _ = _gear_outline_wire(bottom_basis, geometry, points_per_flank)
    top_wire, _ = _gear_outline_wire(top_basis, geometry, points_per_flank)

    loft_maker = BRepOffsetAPI_ThruSections(True, False)
    loft_maker.AddWire(bottom_wire)
    loft_maker.AddWire(top_wire)
    loft_maker.Build()
    if not loft_maker.IsDone():
        raise _gear_failed("could not loft the helical tooth profile between its two twisted end sections")
    return loft_maker.Shape()


def _helical_or_herringbone_solid(
    basis: ResolvedPlane, feature: GearFeature, geometry: SpurGearGeometry, points_per_flank: int
) -> TopoDS_Shape:
    """The full helical/herringbone gear solid - `resolve_gear_from_bodies`'s
    branch for `feature.helix_angle_degrees != 0.0`. Builds the twisted
    tooth-boundary solid (one loft for a plain helical gear, two lofts
    fused together for a herringbone gear's own mirrored halves - see
    `GearFeature.herringbone`'s own docstring for the "mirrored, not simply
    twice as tall" construction: bottom-to-midplane at `+half_twist`,
    midplane-to-top at `-half_twist` relative to the midplane, so both
    halves meet at zero *relative* twist at the shared midplane and the
    whole tooth returns to the same orientation at top and bottom),
    external exactly as-is, internal by cutting that same twisted solid out
    of a plain (untwisted - an internal gear's outer rim is a plain
    cylinder regardless of tooth twist) outer-rim prism, mirroring
    `_gear_face`'s own external/internal split but as two separate solids
    plus a boolean Cut instead of one face-with-a-hole plus one prism
    (`ThruSections` builds from wire sections, not faces-with-holes, so the
    single-face-with-a-hole trick the straight-tooth path uses doesn't
    apply directly here)."""
    total_twist = helical_twist_angle(geometry.pitch_radius, feature.face_width, feature.helix_angle_degrees)
    if feature.herringbone:
        half_width = feature.face_width / 2
        half_twist = helical_twist_angle(geometry.pitch_radius, half_width, feature.helix_angle_degrees)
        bottom_half = _twisted_tooth_loft(basis, geometry, points_per_flank, 0.0, 0.0, half_width, half_twist)
        top_half = _twisted_tooth_loft(
            basis, geometry, points_per_flank, half_width, half_twist, feature.face_width, 0.0
        )
        tooth_solid = BRepAlgoAPI_Fuse(bottom_half, top_half).Shape()
    else:
        tooth_solid = _twisted_tooth_loft(basis, geometry, points_per_flank, 0.0, 0.0, feature.face_width, total_twist)

    if not feature.is_internal:
        return tooth_solid

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
    return BRepAlgoAPI_Cut(outer_solid, tooth_solid).Shape()


def resolve_gear_from_bodies(
    feature: GearFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The real OCCT solid for one `GearFeature` - parameters straight in,
    solid straight out, no backing Sketch at any point
    (`00-conventions.md`'s "gear teeth are not Sketch entities" decision).
    Raises a structured `HTTPException` (`invalid_gear_parameters`/
    `gear_failed`) rather than returning `None` - unlike `ExtrudeFeature`'s
    "skip if the backing Sketch has no profile" tolerance, a `GearFeature`
    has no equivalent "temporarily has nothing to build" state; a bad
    parameter combination is always a real error to surface, not a
    transient/expected one to silently skip.

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
    try:
        geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=feature.tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            profile_shift=feature.profile_shift,
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

    basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)

    if feature.helix_angle_degrees != 0.0 or feature.herringbone:
        if feature.root_fillet_radius > 0:
            logger.warning(
                "GearFeature %s: root_fillet_radius is not supported for a helical/herringbone tooth "
                "(helix_angle_degrees=%r, herringbone=%r) - skipping",
                feature.id,
                feature.helix_angle_degrees,
                feature.herringbone,
            )
        return _helical_or_herringbone_solid(basis, feature, geometry, _POINTS_PER_FLANK)

    wire, root_corner_vertices = _gear_outline_wire(basis, geometry, _POINTS_PER_FLANK)
    face = _gear_face(basis, feature, geometry, wire)

    normal = basis_normal(basis)
    prism_vector = gp_Vec(normal.X(), normal.Y(), normal.Z()).Multiplied(feature.face_width)
    prism_maker = BRepPrimAPI_MakePrism(face, prism_vector)
    solid = prism_maker.Shape()

    if feature.root_fillet_radius > 0:
        solid = _apply_root_fillet(prism_maker, solid, root_corner_vertices, feature.root_fillet_radius)

    return solid


def resolve_gear(
    part: Part, feature: GearFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation -
    mirrors `app.document.fillet.resolve_fillet`'s own shape exactly:
    computes `bodies` *as if `feature` weren't in `part.features` yet*
    (excludes its own id in addition to whatever the caller already
    excludes), so validating a candidate edit to an existing `GearFeature`
    is checked against the Part's shape before this Feature's own effect,
    not stacked on top of it."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_gear_from_bodies(feature, part, bodies, excluded_feature_ids | {feature.id})
