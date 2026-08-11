"""OCCT geometry construction for `BevelGearFeature`
(`docs/gear-design/10-bevel-gear.md`) - the OCCT-dependent half of
`app.document.bevel_math`'s pure math, implementing directly against both
of that doc's own spikes (2026-08-04: spherical-involute math + single-
flank `ThruSections` GO; 2026-08-05: full shell/solid assembly GO) rather
than re-deriving either. Mirrors `app.document.gear`/`app.document.rack`'s
overall shape (a real OCCT solid straight from parameters, no backing
Sketch - `00-conventions.md`'s "gear teeth are not Sketch entities"
decision), but the construction itself has no precedent anywhere else in
this codebase - every technique below is the one the two spikes above
found and validated, not an adaptation of an existing planar/prism/loft
Feature.

**Face inventory**: per tooth, 2 flank faces (right, left - the 2026-08-04
spike's own `ThruSections`-between-two-`Geom_BSplineCurve`-wires
technique, unchanged) plus 1 tip-land and 1 root-land face (the *same*
`ThruSections`-between-two-wires technique, just with plain circular arcs
instead of BSplines, since corresponding outer/inner points at a fixed
colatitude lie on the same ray from the apex for a straight-bevel tooth) -
`4N` faces for `N` teeth, per the 2026-08-05 spike's own §2, all
unchanged since that spike.

The 2 end-cap faces (outer/inner, one each - not per-tooth, per the
spike's own §6 topology dead end) are NOT flat single faces: on-device
feedback ("bevel gears are currently produced with a convex and concave
face... these should be flattened off") replaced the spike's own literal
spherical-patch end-cap (`Geom_SphericalSurface` + hand-rolled pcurves)
with a flat cap PLUS a thin `4N`-face "collar" bridging it back to the
true spherical rim (`_cap_collar_and_flat_faces` - see its own docstring
for why a collar is needed rather than just flattening the rim in place).
`4N + 2` faces total for the tooth geometry, `2*(4N + 1)` for the two
end-caps' own collar+flat construction: `12N + 2` faces for `N` teeth.

**Solid assembly**, exact order per the spike's own §4: `BRepBuilderAPI_
Sewing` (tolerance 1e-4) across all `12N + 2` faces, `ShapeFix_Shell` on
the whole sewn shell (not per-face), `BRepBuilderAPI_MakeSolid`, then
`BRepLib.OrientClosedSolid`. `MakeSolid` alone on the raw sewn shell is
not sufficient (comes back with zero volume - the two end-caps' own
orientation is genuinely ambiguous to OCCT's default resolution, per the
spike's own §5/§6).

**Validation deliberately does not gate on `BRepCheck_Analyzer.IsValid()`**
for the assembled solid - confirmed wrong twice in the 2026-08-04/
2026-08-05 spikes, in two different ways (a missed self-intersection for
a single flank; a false-negative `BRepCheck_UnorientableShape` on the
end-caps for the full assembly, even when the applied orientation is
correct). Per the spike's own §8 implementation sketch: a per-flank
grid-injectivity/normal-flip fold check (`_flank_fold_warning`) runs once
before assembly (all teeth are identical up to rotation - `10-bevel-
gear.md`'s own §7 finding that ring assembly never shifts this risk
relative to a single flank), surfaced as a non-blocking warning per
`00-conventions.md`; `BOPAlgo_CheckerSI` plus an independent mesh-volume
cross-check run once on the assembled solid afterward, as a final sanity
pass rather than the primary defense.

**Verification status**: written directly against both spikes' own
validated findings (not re-derived) and verified for real against genuine
`pythonocc-core` in this session's own on-device pass - `test_bevel_gear_
feature.py`'s own volume/apex-radius checks reproduce both spikes' own
reference numbers closely, and the fold-risk threshold discrepancy the
two spikes left open was re-resolved against this exact, committed code
(`_flank_fold_warning`'s own docstring; `docs/status.md`'s matching dated
entry).
"""

import logging
import math

from fastapi import HTTPException
from OCC.Core.BOPAlgo import BOPAlgo_CheckerSI
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakeSolid,
    BRepBuilderAPI_MakeWire,
    BRepBuilderAPI_Sewing,
)
from OCC.Core.BRepFill import brepfill
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepLib import breplib
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_ThruSections
from OCC.Core.BRepTools import breptools
from OCC.Core.GeomAPI import GeomAPI_Interpolate
from OCC.Core.GeomLProp import GeomLProp_SLProps
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Dir, gp_Pnt, gp_Vec
from OCC.Core.ShapeFix import ShapeFix_Shell
from OCC.Core.TColgp import TColgp_HArray1OfPnt
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_SHELL
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopLoc import TopLoc_Location
from OCC.Core.TopoDS import TopoDS_Edge, TopoDS_Face, TopoDS_Shape, TopoDS_Shell, TopoDS_Solid, TopoDS_Wire, topods

from app.document.bevel_math import (
    BevelGearGeometry,
    GearGeometryError,
    bevel_gear_geometry,
    bevel_tooth_flank_pair,
    max_recommended_face_width,
)
from app.document.create_plane import resolve_plane_ref
from app.document.extrude import basis_normal, compute_part_bodies
from app.document.models import BevelGearFeature, Part, ResolvedPlane

logger = logging.getLogger(__name__)

# 01-gear-math-core.md's own "~10-20 sampled points per flank" target,
# same default gear_math.py/bevel_math.py's own functions already use.
_POINTS_PER_FLANK = 12

# The 2026-08-05 spike's own fold-detector shape (§7): a 25x25 (u, v) grid
# per flank surface.
_FOLD_GRID_SIZE = 25


def _invalid_bevel_parameters(detail: str) -> HTTPException:
    """A bevel gear parameter combination `bevel_math` itself rejects -
    mirrors `app.document.gear._invalid_gear_parameters`'s own convention."""
    return HTTPException(status_code=422, detail={"type": "invalid_bevel_parameters", "detail": detail})


def _bevel_failed(detail: str) -> HTTPException:
    """A structurally-valid bevel gear that OCCT nonetheless couldn't
    build - mirrors `app.document.gear._gear_failed`'s own convention."""
    return HTTPException(status_code=422, detail={"type": "bevel_failed", "detail": detail})


# ---------------------------------------------------------------------------
# Local-frame helpers (apex at the origin, gear axis = +Z)
# ---------------------------------------------------------------------------


def _basis_point3_to_world(basis: ResolvedPlane, x: float, y: float, z: float) -> gp_Pnt:
    """The 3D generalization of `app.document.extrude.basis_point_to_world`
    (which only ever embeds a 2D (x, y) - every other gear-family Feature
    builds a flat profile in its own plane before extruding along the
    normal). A bevel tooth flank is a genuinely 3D space curve in the
    plane's own local frame (apex at the plane's origin, gear axis along
    its normal), so this embeds all three local coordinates directly:
    `origin + x*x_axis + y*y_axis + z*normal`."""
    ox, oy, oz = basis.origin
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    nx, ny, nz = basis.normal
    return gp_Pnt(ox + x * xx + y * yx + z * nx, oy + x * xy + y * yy + z * ny, oz + x * xz + y * yz + z * nz)


def _rotate_about_z(point: tuple[float, float, float], angle: float) -> tuple[float, float, float]:
    """Rotate a local-frame point by `angle` radians about the gear axis
    (+Z in this module's own local frame) - places tooth 0's own flank
    pair (`bevel_math.bevel_tooth_flank_pair`, always built centered on
    azimuth 0) at tooth `i`'s position, `angle = 2*pi*i/tooth_count`.
    Duplicates `bevel_math._rotate_about_z` rather than importing it (that
    one is a private helper of that module) but is the identical
    computation."""
    x, y, z = point
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    return (x * cos_a - y * sin_a, x * sin_a + y * cos_a, z)


# ---------------------------------------------------------------------------
# Flank / tip-land / root-land faces - all `ThruSections`-between-two-wires
# ---------------------------------------------------------------------------


def _interpolated_edge(world_points: list[gp_Pnt]) -> TopoDS_Edge:
    """A single real `Geom_BSplineCurve` edge fit through `world_points` via
    `GeomAPI_Interpolate` (`00-conventions.md`'s real-curve requirement) -
    factored out of `_bspline_wire` so `_cap_collar_and_flat_faces` can
    reuse the exact same curve-fitting technique for its own (already
    world-embedded) rim points, without going through `_bspline_wire`'s own
    local-frame embedding step a second time."""
    points_array = TColgp_HArray1OfPnt(1, len(world_points))
    for i, point in enumerate(world_points, start=1):
        points_array.SetValue(i, point)
    interpolator = GeomAPI_Interpolate(points_array, False, 1e-6)
    interpolator.Perform()
    if not interpolator.IsDone():
        raise _bevel_failed("could not fit a smooth curve through a tooth flank's sampled points")
    return BRepBuilderAPI_MakeEdge(interpolator.Curve()).Edge()


def _bspline_wire(basis: ResolvedPlane, local_points: list[tuple[float, float, float]]) -> TopoDS_Wire:
    """One tooth flank's sampled points, fit as a single real
    `Geom_BSplineCurve` edge (`_interpolated_edge`) - the 3D generalization
    of `app.document.gear._bspline_flank_edge` (that one embeds a 2D local
    profile; a bevel flank is a genuine 3D space curve, so this embeds via
    `_basis_point3_to_world` instead)."""
    world_points = [_basis_point3_to_world(basis, x, y, z) for x, y, z in local_points]
    return BRepBuilderAPI_MakeWire(_interpolated_edge(world_points)).Wire()


def _cone_arc_wire(
    basis: ResolvedPlane,
    sphere_radius: float,
    colatitude: float,
    p_start_world: gp_Pnt,
    p_end_world: gp_Pnt,
) -> TopoDS_Wire:
    """`_arc_wire` from `10-bevel-gear.md`'s own §8 implementation sketch:
    a plain circular arc at fixed `colatitude` on the sphere of
    `sphere_radius` (the tip-land/root-land faces' own wires - a
    straight-bevel tooth is ruled by lines through the apex, so
    corresponding outer/inner arc points lie on the same ray, and the
    arc-to-arc `ThruSections` loft *is* the exact trimmed cone patch - no
    separate `Geom_ConicalSurface` needed, per that doc's own §2).

    The circle's own reference X direction is pinned to point at
    `p_start_world` (mirrors `app.document.extrude.arc_axis`'s identical
    technique for a sketch Arc) so `BRepBuilderAPI_MakeEdge(gp_Circ, P1,
    P2)` always trims the *short* way from `p_start_world` to
    `p_end_world` - both callers always pass points already ordered in
    the tooth-rim's own increasing-azimuth traversal direction, so the
    short way is always the geometrically-correct one (a tooth's own tip
    width or the gap to the next tooth, never the long way around)."""
    circle_radius = sphere_radius * math.sin(colatitude)
    height = sphere_radius * math.cos(colatitude)
    center = _basis_point3_to_world(basis, 0.0, 0.0, height)
    normal = basis_normal(basis)
    x_ref = gp_Dir(gp_Vec(center, p_start_world))
    axis = gp_Ax2(center, normal, x_ref)
    circ = gp_Circ(axis, circle_radius)
    edge = BRepBuilderAPI_MakeEdge(circ, p_start_world, p_end_world).Edge()
    return BRepBuilderAPI_MakeWire(edge).Wire()


def _explode_faces(shape: TopoDS_Shape) -> list[TopoDS_Face]:
    faces: list[TopoDS_Face] = []
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while explorer.More():
        faces.append(topods.Face(explorer.Current()))
        explorer.Next()
    return faces


def _thru_sections_face(outer_wire: TopoDS_Wire, inner_wire: TopoDS_Wire) -> TopoDS_Face:
    """`ThruSections` between two single-edge wires, not built as a solid
    (`isSolid=False`) since this module sews independently-built faces
    together itself rather than fusing sub-solids - shared by flank
    (`_bspline_wire`-built wires) and tip-land/root-land
    (`_cone_arc_wire`-built wires) faces alike, per `10-bevel-gear.md`'s
    own §2 finding that both use "the *same* `ThruSections`-between-two-
    wires idiom." `ruled=True` - the 2026-08-04 spike's own finding that
    ruled/smoothed modes coincide for exactly two cross-sections."""
    loft_maker = BRepOffsetAPI_ThruSections(False, True)
    loft_maker.AddWire(outer_wire)
    loft_maker.AddWire(inner_wire)
    loft_maker.Build()
    if not loft_maker.IsDone():
        raise _bevel_failed("could not loft a tooth flank/land surface between its outer and inner curves")
    faces = _explode_faces(loft_maker.Shape())
    if len(faces) != 1:
        raise _bevel_failed(
            f"expected exactly one face from a two-wire ThruSections loft, got {len(faces)}"
        )
    return faces[0]


def _flank_face(
    basis: ResolvedPlane, outer_points: list[tuple[float, float, float]], inner_points: list[tuple[float, float, float]]
) -> TopoDS_Face:
    """One tooth flank's surface (right or left) - unchanged from the
    2026-08-04 spike's own confirmed technique."""
    return _thru_sections_face(_bspline_wire(basis, outer_points), _bspline_wire(basis, inner_points))


def _tip_land_face(
    basis: ResolvedPlane,
    geometry: BevelGearGeometry,
    right_outer_tip: gp_Pnt,
    left_outer_tip: gp_Pnt,
    right_inner_tip: gp_Pnt,
    left_inner_tip: gp_Pnt,
) -> TopoDS_Face:
    outer_wire = _cone_arc_wire(basis, geometry.cone_distance, geometry.face_cone_angle, right_outer_tip, left_outer_tip)
    inner_wire = _cone_arc_wire(
        basis, geometry.inner_cone_distance, geometry.face_cone_angle, right_inner_tip, left_inner_tip
    )
    return _thru_sections_face(outer_wire, inner_wire)


def _root_land_face(
    basis: ResolvedPlane,
    geometry: BevelGearGeometry,
    root_colatitude: float,
    left_outer_root: gp_Pnt,
    next_right_outer_root: gp_Pnt,
    left_inner_root: gp_Pnt,
    next_right_inner_root: gp_Pnt,
) -> TopoDS_Face:
    outer_wire = _cone_arc_wire(basis, geometry.cone_distance, root_colatitude, left_outer_root, next_right_outer_root)
    inner_wire = _cone_arc_wire(
        basis, geometry.inner_cone_distance, root_colatitude, left_inner_root, next_right_inner_root
    )
    return _thru_sections_face(outer_wire, inner_wire)


# ---------------------------------------------------------------------------
# Flat end-caps (10-bevel-gear.md §3's spherical patch, flattened - on-device
# feedback: "bevel gears are currently produced with a convex and concave
# face... these should be flattened off")
# ---------------------------------------------------------------------------


def _cap_rim_points(
    tooth_count: int, right0: list[tuple[float, float, float]], left0: list[tuple[float, float, float]]
) -> list[tuple[float, float, float]]:
    """The whole end-cap rim's local-frame points, in traversal order, one
    lap around the gear - `tooth_count` repetitions of [tooth's own right
    flank, root-to-tip] + [tooth's own left flank, tip-to-root] (`right0`/
    `left0` are tooth 0's own flank points, both already root-to-tip per
    `bevel_math.bevel_tooth_flank_pair`'s own docstring - the left flank
    is reversed here, unlike `gear_math`'s planar convention which already
    stores its own left flank pre-reversed). `_cap_rim_edges`'s own final
    root-land leg (last tooth back to the first) wraps back to index 0 by
    plain modulo - a genuine 3D point, no seam-continuity concern - so no
    closing duplicate point is needed here."""
    points: list[tuple[float, float, float]] = []
    for i in range(tooth_count):
        angle = 2 * math.pi * i / tooth_count
        points.extend(_rotate_about_z(p, angle) for p in right0)
        points.extend(_rotate_about_z(p, angle) for p in reversed(left0))
    return points


def _cap_rim_edges(world_points: list[gp_Pnt], tooth_count: int, points_per_flank: int) -> list[TopoDS_Edge]:
    """The end-cap rim's `4*tooth_count` edges (right flank, tip corner,
    left flank, root corner - per tooth), built directly from
    already-world-embedded `world_points` (`_cap_rim_points`, embedded via
    `_basis_point3_to_world`) - shared by `_cap_collar_and_flat_faces`
    for both the true (still on the sphere) rim and its flattened copy
    (same point count/order, only each point's own z differs), so a collar
    face built leg-by-leg between corresponding true/flat edges (see that
    function) always connects the right curve type to the right one."""
    k = points_per_flank
    span = 2 * k  # one tooth's own share of world_points: right (k) + left-reversed (k)
    edges: list[TopoDS_Edge] = []
    for i in range(tooth_count):
        base = i * span
        edges.append(_interpolated_edge(world_points[base : base + k]))
        edges.append(BRepBuilderAPI_MakeEdge(world_points[base + k - 1], world_points[base + k]).Edge())
        edges.append(_interpolated_edge(world_points[base + k : base + span]))
        next_base = (base + span) % (tooth_count * span)
        edges.append(BRepBuilderAPI_MakeEdge(world_points[base + span - 1], world_points[next_base]).Edge())
    return edges


def _cap_collar_and_flat_faces(
    basis: ResolvedPlane,
    sphere_radius: float,
    face_colatitude: float,
    tooth_count: int,
    right0: list[tuple[float, float, float]],
    left0: list[tuple[float, float, float]],
) -> list[TopoDS_Face]:
    """One end-cap's faces (outer or inner) - on-device feedback: the
    original spike's own literal spherical-patch end-cap (hand-rolled
    pcurves against a `Geom_SphericalSurface`, `10-bevel-gear.md`'s own
    §3) produced a visibly convex/concave face; real bevel gears cut this
    flat instead (the standard "back cone" approximation).

    A genuinely flat (planar) face's ENTIRE boundary must be coplanar, but
    the true `4*tooth_count`-edge zigzag rim isn't (it follows the tooth
    flank's own spherical-involute shape, root to tip) - and that same rim
    is exactly the boundary the neighbouring flank/tip-land/root-land
    faces already share (built from these same `right0`/`left0` points),
    so simply moving the rim's own points to one flat z (an earlier
    attempt at this fix) breaks watertightness: the flat cap's edges no
    longer coincide with those unchanged neighbours', and `BRepBuilderAPI_
    Sewing` can't stitch a millimetre-scale gap shut.

    Instead this returns the flat cap face PLUS a thin `4*tooth_count`-face
    "collar" bridging the true rim back to a flattened copy of itself (each
    corresponding true/flat edge pair joined via `BRepFill.Face`, a plain
    ruled surface between two edges - unlike `BRepOffsetAPI_ThruSections`,
    which on-device testing found `IsDone() == False` for a straight,
    already-degenerate-looking single-edge-to-single-edge loft here) - the
    true rim edges are reused as-is (still exactly matching the flank/land
    faces' own boundary, so sewing them into the same shell in
    `_assemble_gear_solid` still closes cleanly), and the collar's own far
    edge is the flat cap's boundary. Verified on-device (this session):
    sewn together with the flank/tip-land/root-land faces, the resulting
    solid's independent mesh-volume cross-check (`_mesh_volume`) agrees
    with its analytic volume to within 0.2% and `BOPAlgo_CheckerSI` finds
    no self-intersections.

    The flat plane sits at `sphere_radius * cos(face_colatitude)` - this
    cone's own tooth-TIP axial position (the real "back cone" is
    conventionally tangent to the true sphere at the tip circle) - so the
    collar is a no-op at the tip corners (already exactly on that plane)
    and only bridges the gap elsewhere along the rim."""
    k = len(right0)
    local_points = _cap_rim_points(tooth_count, right0, left0)
    true_world = [_basis_point3_to_world(basis, x, y, z) for x, y, z in local_points]
    z_flat = sphere_radius * math.cos(face_colatitude)
    flat_world = [_basis_point3_to_world(basis, x, y, z_flat) for x, y, _z in local_points]

    true_edges = _cap_rim_edges(true_world, tooth_count, k)
    flat_edges = _cap_rim_edges(flat_world, tooth_count, k)
    collar_faces = [brepfill.Face(true_edge, flat_edge) for true_edge, flat_edge in zip(true_edges, flat_edges)]

    flat_wire_maker = BRepBuilderAPI_MakeWire()
    for edge in flat_edges:
        flat_wire_maker.Add(edge)
    if not flat_wire_maker.IsDone():
        raise _bevel_failed("could not assemble the flat end-cap's own zigzag rim into one closed wire")
    flat_face_maker = BRepBuilderAPI_MakeFace(flat_wire_maker.Wire())
    if not flat_face_maker.IsDone():
        raise _bevel_failed("could not build a flat end-cap face from its own rim wire")

    return collar_faces + [flat_face_maker.Face()]


# ---------------------------------------------------------------------------
# Fold-risk validation (10-bevel-gear.md's own resolved §7 finding)
# ---------------------------------------------------------------------------


def _flank_fold_warning(face: TopoDS_Face, grid_size: int = _FOLD_GRID_SIZE) -> str | None:
    """A real fold/self-intersection detector for one flank surface -
    `10-bevel-gear.md`'s own §7/§8: `BRepCheck_Analyzer`/`IsDone()` are
    both confirmed-insufficient signals for this construction (missed a
    real self-intersection in the 2026-08-04 spike), so this samples the
    surface on a real `grid_size x grid_size` (u, v) grid and checks two
    genuine geometric signals, either one sufficient to flag a fold:

    1. **Point coincidence**: any two *non-adjacent* grid points landing
       at nearly the same 3D position - the direct signature of a folded/
       self-overlapping surface (adjacent grid points are expected to be
       close together; only non-adjacent ones colliding is a real fold).
    2. **Normal sign flip**: the local surface normal (`GeomLProp_SLProps`)
       at any two adjacent grid points pointing in substantially opposite
       directions - a surface that's still injective (no two points
       coincide) can nonetheless be creasing/folding back on itself, which
       a pure point-coincidence check alone would miss.

    Run once per unique flank shape (all teeth are identical up to
    rotation - `10-bevel-gear.md`'s own §7 confirms ring assembly never
    shifts this risk relative to a single flank, so re-checking every
    flank would be redundant, not more thorough), before assembly -
    `00-conventions.md`'s non-blocking validation-banner convention.
    Returns a warning message, or `None` if no fold was detected."""
    surface = BRep_Tool.Surface(face)
    u1, u2, v1, v2 = breptools.UVBounds(face)

    grid_points: list[gp_Pnt] = []
    grid_normals: list[gp_Vec | None] = []
    for i in range(grid_size):
        u = u1 + (u2 - u1) * i / (grid_size - 1)
        for j in range(grid_size):
            v = v1 + (v2 - v1) * j / (grid_size - 1)
            props = GeomLProp_SLProps(surface, u, v, 1, 1e-6)
            grid_points.append(props.Value())
            grid_normals.append(props.Normal() if props.IsNormalDefined() else None)

    # Point coincidence: only compare non-adjacent grid points (index
    # difference in EITHER the flattened i or j sense) - immediate
    # neighbours are expected to be close, that's not a fold.
    #
    # 0.05mm (not the sewing tolerance's own 1e-4mm, and not an arbitrary
    # tiny epsilon): this session's own re-derivation of the spike's
    # positive control (10-bevel-gear.md's own resolved §7 finding, see
    # docs/status.md's matching dated entry) found the grid's own minimum
    # non-adjacent-point gap for the 6T/80T case shrinks smoothly and
    # predictably with face_width - 0.0989mm at face_width = 2.0x
    # max_recommended_face_width, 0.0049mm at 2.95x (both bit-for-bit
    # reproductions of the second spike's own reported numbers) - and never
    # drops below 0.2mm for any realistic face_width (<=1.2x
    # max_recommended_face_width) in any of the three canonical test cases.
    # 0.05mm sits inside that shrinking range at a value with real physical
    # meaning for this app's own stated audience (a small-module gear
    # meant to actually mesh with another *3D-printed* gear, per
    # `00-conventions.md`'s own mesh-quality discussion) - roughly a single
    # FDM nozzle's own resolution, so two non-adjacent points closer than
    # this are already at the edge of "the same printed feature," not just
    # mathematically close. Fires only in the genuinely extreme regime
    # (empirically, ratio >~2.5 for the tightest tested case) - a realistic
    # design (ratio <=1.0, the existing `max_recommended_face_width`
    # warning's own boundary) never approaches it.
    coincidence_tolerance = 0.05
    min_neighbor_gap = 2
    n = len(grid_points)
    for a in range(n):
        ia, ja = divmod(a, grid_size)
        for b in range(a + 1, n):
            ib, jb = divmod(b, grid_size)
            if abs(ia - ib) < min_neighbor_gap and abs(ja - jb) < min_neighbor_gap:
                continue
            if grid_points[a].Distance(grid_points[b]) < coincidence_tolerance:
                return (
                    "This bevel gear's tooth flank surface may fold back on itself (near-coincident "
                    "non-adjacent points detected) - likely face_width pushed too large relative to "
                    "cone distance on a tight pitch cone. Try a smaller face_width."
                )

    # Normal sign flip between adjacent grid points.
    for i in range(grid_size):
        for j in range(grid_size):
            index = i * grid_size + j
            normal = grid_normals[index]
            if normal is None:
                continue
            for neighbor_index in (index + 1 if j + 1 < grid_size else None, index + grid_size if i + 1 < grid_size else None):
                if neighbor_index is None:
                    continue
                neighbor_normal = grid_normals[neighbor_index]
                if neighbor_normal is None:
                    continue
                if normal.Dot(neighbor_normal) < 0:
                    return (
                        "This bevel gear's tooth flank surface may fold back on itself (surface normal "
                        "sign flip detected) - likely face_width pushed too large relative to cone "
                        "distance on a tight pitch cone. Try a smaller face_width."
                    )
    return None


# ---------------------------------------------------------------------------
# Solid assembly (10-bevel-gear.md's own §4/§8)
# ---------------------------------------------------------------------------


def _single_shell(shape: TopoDS_Shape) -> TopoDS_Shell:
    if shape.ShapeType() == TopAbs_SHELL:
        return topods.Shell(shape)
    shells: list[TopoDS_Shell] = []
    explorer = TopExp_Explorer(shape, TopAbs_SHELL)
    while explorer.More():
        shells.append(topods.Shell(explorer.Current()))
        explorer.Next()
    if len(shells) != 1:
        raise _bevel_failed(f"expected sewing all tooth faces to produce exactly one shell, got {len(shells)}")
    return shells[0]


def _mesh_volume(solid: TopoDS_Shape) -> float:
    """An independent divergence-theorem volume - genuinely different code
    from `BRepGProp`'s own analytic integration, per `10-bevel-gear.md`'s
    own §5 finding that agreement between the two (not `BRepCheck_
    Analyzer`) is the real evidence a solid is correctly closed and
    oriented. Sums signed tetrahedron volumes from the world origin over
    every mesh triangle of a real `BRepMesh_IncrementalMesh` tessellation."""
    BRepMesh_IncrementalMesh(solid, 0.05, False, 0.5, True)
    total = 0.0
    explorer = TopExp_Explorer(solid, TopAbs_FACE)
    while explorer.More():
        face = topods.Face(explorer.Current())
        location = TopLoc_Location()
        triangulation = BRep_Tool.Triangulation(face, location)
        explorer.Next()
        if triangulation is None:
            continue
        transform = location.Transformation()
        is_reversed = face.Orientation() == 1  # TopAbs_REVERSED
        for tri_index in range(1, triangulation.NbTriangles() + 1):
            i1, i2, i3 = triangulation.Triangle(tri_index).Get()
            p1 = triangulation.Node(i1).Transformed(transform)
            p2 = triangulation.Node(i2).Transformed(transform)
            p3 = triangulation.Node(i3).Transformed(transform)
            if is_reversed:
                p2, p3 = p3, p2
            total += (
                p1.X() * (p2.Y() * p3.Z() - p2.Z() * p3.Y())
                - p1.Y() * (p2.X() * p3.Z() - p2.Z() * p3.X())
                + p1.Z() * (p2.X() * p3.Y() - p2.Y() * p3.X())
            ) / 6.0
    return abs(total)


def _assembly_sanity_warnings(solid: TopoDS_Solid) -> list[str]:
    """The assembled-solid final sanity pass per `10-bevel-gear.md`'s own
    §8: `BOPAlgo_CheckerSI` (self-intersection) plus an independent mesh-
    volume cross-check against `BRepGProp`'s own analytic volume - run
    once, after assembly, deliberately NOT gating on `BRepCheck_Analyzer.
    IsValid()` (confirmed wrong for this construction's own end-caps, per
    that doc's §5). Non-blocking, per `00-conventions.md` - a disagreement
    here is a real, but not certainly-fatal, signal worth surfacing.

    `SetRunParallel(True)` (on-device feedback this session, after the
    flat-end-cap fix's own `_cap_collar_and_flat_faces` added `4*tooth_
    count` extra collar faces per cap): `BOPAlgo_CheckerSI`'s own
    pairwise-face cost scales with total face count, and profiling this
    session found it dominating this function's own runtime by roughly
    two orders of magnitude over everything else combined once those
    extra faces are in the shell - `SetRunParallel` roughly halves it back
    down, a pure performance win with no change to what gets checked or
    reported."""
    warnings: list[str] = []

    checker = BOPAlgo_CheckerSI()
    checker.SetRunParallel(True)
    checker.AddArgument(solid)
    checker.Perform()
    if checker.HasErrors():
        warnings.append(
            "This bevel gear's assembled solid failed a self-intersection check (BOPAlgo_CheckerSI) - "
            "the geometry may not be physically valid. Try a smaller face_width or a less extreme "
            "pitch cone angle."
        )

    props = GProp_GProps()
    brepgprop.VolumeProperties(solid, props)
    analytic_volume = abs(props.Mass())
    try:
        mesh_volume = _mesh_volume(solid)
    except Exception:  # noqa: BLE001 - best-effort diagnostic only, never fails the Feature itself
        logger.warning("Bevel gear independent mesh-volume cross-check itself failed - skipping", exc_info=True)
        return warnings
    if analytic_volume > 0 and abs(analytic_volume - mesh_volume) / analytic_volume > 0.02:
        warnings.append(
            "This bevel gear's assembled solid's analytic volume disagrees with an independent "
            "mesh-based volume check by more than 2% - the geometry may not be a correctly closed solid."
        )
    return warnings


def _assemble_gear_solid(
    basis: ResolvedPlane, geometry: BevelGearGeometry, tooth_count: int, points_per_flank: int = _POINTS_PER_FLANK
) -> tuple[TopoDS_Shape, list[str]]:
    """The full bevel gear solid - `10-bevel-gear.md`'s own §8
    implementation sketch, in order: collect the `4*tooth_count` side
    faces tooth by tooth, append the 2 end-cap faces, `Sewing` ->
    `ShapeFix_Shell` -> `MakeSolid` -> `OrientClosedSolid` (§4's exact
    sequence - `MakeSolid` alone on the raw sewn shell is not sufficient).
    Root fillet is not supported - see `BevelGearFeature`'s own
    docstring for why (no `BRepPrimAPI_MakePrism.Generated()`-equivalent
    vertex-tracking for a `ThruSections`/`Sewing`-built solid)."""
    right0, left0 = bevel_tooth_flank_pair(geometry, points_per_flank)
    right0_outer, right0_inner = right0
    left0_outer, left0_inner = left0
    start_colatitude = max(geometry.root_cone_angle, geometry.base_cone_angle)
    face_colatitude = geometry.face_cone_angle

    faces: list[TopoDS_Face] = []
    fold_warning: str | None = None
    for i in range(tooth_count):
        angle = 2 * math.pi * i / tooth_count
        right_outer = [_rotate_about_z(p, angle) for p in right0_outer]
        right_inner = [_rotate_about_z(p, angle) for p in right0_inner]
        left_outer = [_rotate_about_z(p, angle) for p in left0_outer]
        left_inner = [_rotate_about_z(p, angle) for p in left0_inner]

        right_flank_face = _flank_face(basis, right_outer, right_inner)
        left_flank_face = _flank_face(basis, left_outer, left_inner)
        if i == 0:
            # All teeth are identical up to rotation (10-bevel-gear.md §7) -
            # checking one flank once is the load-bearing check, not a
            # per-tooth re-check.
            fold_warning = _flank_fold_warning(right_flank_face)
        faces.append(right_flank_face)
        faces.append(left_flank_face)

        right_outer_tip_world = _basis_point3_to_world(basis, *right_outer[-1])
        left_outer_tip_world = _basis_point3_to_world(basis, *left_outer[-1])
        right_inner_tip_world = _basis_point3_to_world(basis, *right_inner[-1])
        left_inner_tip_world = _basis_point3_to_world(basis, *left_inner[-1])
        faces.append(
            _tip_land_face(
                basis, geometry, right_outer_tip_world, left_outer_tip_world, right_inner_tip_world, left_inner_tip_world
            )
        )

        next_angle = 2 * math.pi * ((i + 1) % tooth_count) / tooth_count
        next_right_outer_root_world = _basis_point3_to_world(basis, *_rotate_about_z(right0_outer[0], next_angle))
        next_right_inner_root_world = _basis_point3_to_world(basis, *_rotate_about_z(right0_inner[0], next_angle))
        left_outer_root_world = _basis_point3_to_world(basis, *left_outer[0])
        left_inner_root_world = _basis_point3_to_world(basis, *left_inner[0])
        faces.append(
            _root_land_face(
                basis,
                geometry,
                start_colatitude,
                left_outer_root_world,
                next_right_outer_root_world,
                left_inner_root_world,
                next_right_inner_root_world,
            )
        )

    faces.extend(
        _cap_collar_and_flat_faces(
            basis, geometry.cone_distance, face_colatitude, tooth_count, right0_outer, left0_outer
        )
    )
    faces.extend(
        _cap_collar_and_flat_faces(
            basis, geometry.inner_cone_distance, face_colatitude, tooth_count, right0_inner, left0_inner
        )
    )

    sewing = BRepBuilderAPI_Sewing(1e-4)
    for face in faces:
        sewing.Add(face)
    sewing.Perform()
    sewn = sewing.SewedShape()
    shell = _single_shell(sewn)

    fixer = ShapeFix_Shell(shell)
    fixer.Perform()
    fixed_shell = fixer.Shell()

    solid_maker = BRepBuilderAPI_MakeSolid(fixed_shell)
    if not solid_maker.IsDone():
        raise _bevel_failed("could not build a solid from the sewn tooth shell")
    solid = solid_maker.Solid()
    breplib.OrientClosedSolid(solid)

    warnings = [fold_warning] if fold_warning else []
    warnings.extend(_assembly_sanity_warnings(solid))
    return solid, warnings


# ---------------------------------------------------------------------------
# Feature entry points
# ---------------------------------------------------------------------------


def resolve_bevel_gear_from_bodies(
    feature: BevelGearFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> tuple[TopoDS_Shape, list[str]]:
    """The real OCCT solid for one `BevelGearFeature`, plus any non-
    blocking warnings - mirrors `app.document.gear.resolve_gear_from_
    bodies`'s overall shape (raises a structured `HTTPException` rather
    than returning `None`: no backing Sketch, so no "temporarily has
    nothing to build" state to tolerate)."""
    try:
        geometry = bevel_gear_geometry(
            module=feature.module,
            tooth_count=feature.tooth_count,
            face_width=feature.face_width,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            backlash=feature.backlash,
            profile_shift=feature.profile_shift,
            pitch_cone_angle_degrees=feature.pitch_cone_angle_degrees,
        )
    except GearGeometryError as exc:
        raise _invalid_bevel_parameters(str(exc)) from exc

    if feature.face_width <= 0:
        raise _invalid_bevel_parameters(f"face_width must be positive, got {feature.face_width!r}")

    warnings: list[str] = []
    max_face_width = max_recommended_face_width(geometry.cone_distance)
    if feature.face_width > max_face_width:
        warnings.append(
            f"face_width ({feature.face_width!r}) exceeds the recommended maximum "
            f"({max_face_width!r} = cone_distance / 3) - the tooth thins toward degeneracy near the apex."
        )

    basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)
    solid, assembly_warnings = _assemble_gear_solid(basis, geometry, feature.tooth_count)
    warnings.extend(assembly_warnings)
    return solid, warnings


def resolve_bevel_gear(
    part: Part, feature: BevelGearFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[TopoDS_Shape, list[str]]:
    """Fresh entry point for the router's create/update validation -
    mirrors `app.document.gear.resolve_gear`'s exact shape."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_bevel_gear_from_bodies(feature, part, bodies, excluded_feature_ids | {feature.id})
