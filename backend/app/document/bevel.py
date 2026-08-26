"""OCCT geometry construction for `BevelGearFeature`
(`docs/gear-design/10-bevel-gear.md`) - the OCCT-dependent half of
`app.document.bevel_math`'s pure math, implementing directly against both
of that doc's own spikes (2026-08-04: spherical-involute math + single-
flank `ThruSections` GO; 2026-08-05: full shell/solid assembly GO) rather
than re-deriving either. The spike's own flank *curve* (spherical
involute) was later replaced by `bevel_math.tredgold_bevel_point`'s
Tredgold approximation (real mating pairs built via true spherical
involute don't reliably mesh - see that function's own docstring); this
module's own surface/solid *assembly* technique below - everything from
"Face inventory" on - is unaffected, since it just samples whichever
curve `bevel_tooth_flank_pair` hands it the same way either curve was
sampled. Mirrors `app.document.gear`/`app.document.rack`'s overall shape
(a real OCCT solid straight from parameters, no backing Sketch - `00-
conventions.md`'s "gear teeth are not Sketch entities" decision), but the
construction itself has no precedent anywhere else in this codebase -
every technique below is the one the two spikes above found and
validated, not an adaptation of an existing planar/prism/loft Feature.

**Face inventory** (`4N + 2` faces for `N` teeth, per the 2026-08-05
spike's own §2): per tooth, 2 flank faces (right, left - the 2026-08-04
spike's own `ThruSections`-between-two-`Geom_BSplineCurve`-wires
technique, unchanged) plus 1 tip-land and 1 root-land face (the *same*
`ThruSections`-between-two-wires technique, just with plain circular arcs
instead of BSplines, since corresponding outer/inner points at a fixed
colatitude lie on the same ray from the apex for a straight-bevel tooth);
plus 2 spherical end-cap faces (outer/inner, one each - not per-tooth,
per the spike's own §6 topology dead end), built via hand-rolled pcurves
against a `Geom_SphericalSurface` (`_spherical_cap_face`, the one
genuinely new technique - see its own docstring).

**Solid assembly**, exact order per the spike's own §4: `BRepBuilderAPI_
Sewing` (tolerance 1e-4) across all `4N + 2` faces, `ShapeFix_Shell` on
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
`00-conventions.md`; an independent mesh-volume cross-check runs once on
the assembled solid afterward, as a final sanity pass rather than the
primary defense (`_assembly_sanity_warnings`'s own docstring - bevel-pair
timeout investigation - explains why the whole-solid `BOPAlgo_CheckerSI`
self-intersection check this used to also run here was dropped entirely,
not just made cheaper: expensive, redundant with the per-flank check
above, and explicitly secondary already).

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
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakeSolid,
    BRepBuilderAPI_MakeWire,
    BRepBuilderAPI_Sewing,
)
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepLib import breplib
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_ThruSections
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakeSphere
from OCC.Core.BRepTools import breptools
from OCC.Core.Geom import Geom_SphericalSurface
from OCC.Core.Geom2d import Geom2d_Line
from OCC.Core.Geom2dAPI import Geom2dAPI_Interpolate
from OCC.Core.GeomAPI import GeomAPI_Interpolate
from OCC.Core.GeomLProp import GeomLProp_SLProps
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax2, gp_Ax3, gp_Circ, gp_Dir, gp_Dir2d, gp_Pnt, gp_Pnt2d, gp_Vec, gp_Vec2d
from OCC.Core.ShapeFix import ShapeFix_Shell
from OCC.Core.TColgp import TColgp_HArray1OfPnt, TColgp_HArray1OfPnt2d
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_SHELL, TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopLoc import TopLoc_Location
from OCC.Core.TopoDS import TopoDS_Face, TopoDS_Shape, TopoDS_Shell, TopoDS_Solid, TopoDS_Wire, topods

from app.document.bevel_math import (
    DEFAULT_SPIRAL_SECTION_COUNT,
    BevelGearGeometry,
    GearGeometryError,
    SpiralHand,
    bevel_gear_geometry,
    bevel_tooth_flank_pair,
    bevel_tooth_flank_sections,
    max_recommended_face_width,
    spiral_build_cost_warning,
    spiral_curve_offset_angle,
    spiral_section_count_for_twist,
    thin_hub_warning,
    tredgold_base_colatitude,
)
from app.document.create_plane import resolve_plane_ref
from app.document.extrude import basis_normal, compute_part_bodies
from app.document.models import BevelGearFeature, Part, ResolvedPlane, SpiralBevelHand


def _spiral_hand_from_feature(spiral_hand: SpiralBevelHand) -> SpiralHand:
    """Converts `models.SpiralBevelHand` (the Feature's own wire-facing
    enum, kept as a separate definition per that enum's own docstring) to
    `bevel_math.SpiralHand` (the math-layer enum `bevel_tooth_flank_
    sections`/`spiral_curve_offset_angle` actually take) - the one place
    this module needs to bridge the two, since both share the same
    `LEFT`/`RIGHT` member names by design."""
    return SpiralHand[spiral_hand.name]

logger = logging.getLogger(__name__)

# 01-gear-math-core.md's own "~10-20 sampled points per flank" target,
# same default gear_math.py/bevel_math.py's own functions already use.
_POINTS_PER_FLANK = 12

# The 2026-08-05 spike's own fold-detector shape (§7): a 25x25 (u, v) grid
# per flank surface.
_FOLD_GRID_SIZE = 25

# `_outer_cap_flattening_tool`'s own two safety margins - both confirmed
# on-device against this module's own real bevel gear geometry (0.1mm avoids
# a real, silently-wrong `BRepAlgoAPI_Cut` degeneracy at exact tangency; the
# height margin is a generous, arbitrary clearance past the sphere's own
# pole so the cut tool always fully spans the dome regardless of a given
# gear's own dimensions - safe to overshoot, see that function's own
# docstring for why).
_END_CAP_RADIUS_MARGIN = 0.1
_END_CAP_HEIGHT_MARGIN = 1.0

# `_flatten_end_caps`'s own `BRepAlgoAPI_Fuse`/`Cut` fuzzy tolerance -
# confirmed on-device to fix the inner cap's own coincident-edge boolean
# degeneracy (`_inner_cap_flattening_tool`'s own flat base sits exactly on
# the sewn shell's own root-land boundary, by construction) for realistic
# gears; a small enough value to stay far below any real gear dimension.
_END_CAP_FUZZY_VALUE = 1e-3


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


def _sphere_axis(basis: ResolvedPlane) -> gp_Ax3:
    """The world-space `gp_Ax3` for a `Geom_SphericalSurface` centred at
    the apex (`basis.origin`), main direction along the gear axis
    (`basis.normal`), X direction along `basis.x_axis` - chosen so that a
    LOCAL-frame point's own closed-form `(atan2(y, x), asin(z / R))` is
    exactly that surface's own (u, v) parametrization at the matching
    world-embedded point (`Geom_SphericalSurface`'s `P(u, v) = O +
    R*cos(v)*(cos(u)*XDir + sin(u)*YDir) + R*sin(v)*ZDir`), letting
    `_spherical_cap_face` compute pcurve coordinates directly from local
    (x, y, z) without any extra projection step."""
    ox, oy, oz = basis.origin
    nx, ny, nz = basis.normal
    xx, xy, xz = basis.x_axis
    return gp_Ax3(gp_Pnt(ox, oy, oz), gp_Dir(nx, ny, nz), gp_Dir(xx, xy, xz))


# ---------------------------------------------------------------------------
# Flank / tip-land / root-land faces - all `ThruSections`-between-two-wires
# ---------------------------------------------------------------------------


def _bspline_wire(basis: ResolvedPlane, local_points: list[tuple[float, float, float]]) -> TopoDS_Wire:
    """One tooth flank's sampled points, fit as a single real
    `Geom_BSplineCurve` edge via `GeomAPI_Interpolate` (`00-conventions.md`'s
    real-curve requirement) - the 3D generalization of
    `app.document.gear._bspline_flank_edge` (that one embeds a 2D local
    profile; a bevel flank is a genuine 3D space curve, so this embeds via
    `_basis_point3_to_world` instead)."""
    world_points = [_basis_point3_to_world(basis, x, y, z) for x, y, z in local_points]
    points_array = TColgp_HArray1OfPnt(1, len(world_points))
    for i, point in enumerate(world_points, start=1):
        points_array.SetValue(i, point)
    interpolator = GeomAPI_Interpolate(points_array, False, 1e-6)
    interpolator.Perform()
    if not interpolator.IsDone():
        raise _bevel_failed("could not fit a smooth curve through a tooth flank's sampled points")
    edge = BRepBuilderAPI_MakeEdge(interpolator.Curve()).Edge()
    return BRepBuilderAPI_MakeWire(edge).Wire()


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


def _thru_sections_face_n(wires: list[TopoDS_Wire]) -> TopoDS_Face:
    """`docs/gear-design/12-spiral-bevel-gear.md`: N-section (`N >= 2`)
    generalization of `_thru_sections_face`, for a spiral bevel tooth's
    flank/tip-land/root-land surfaces - the azimuthal offset varies
    continuously along the face width once spiral is active, so a single
    2-wire ruled loft under-counts the real geometry (that doc's own Spike
    A §3 "Section-count convergence" finding, ~17% off at 2 sections for a
    real mesh-overlap measurement; re-confirmed purely mathematically in
    `test_bevel_math.py`).

    `ruled=False` + `CheckCompatibility(False)` - NOT `_thru_sections_face`'s
    own `ruled=True`/default-`CheckCompatibility` combination - reusing
    `app.document.gear._twisted_tooth_loft`'s own established fix for the
    structurally identical "loft between N wires with an already-known-
    correct point correspondence" problem (`gear.py`'s own docstring: large
    twist can otherwise make `ThruSections`' own vertex-correspondence
    search snap a tip vertex to a *different* tooth's root vertex, still
    `IsDone()`-valid but silently wrong) - carried over unchanged per that
    doc's own Spike A/C findings ("carried over without needing further
    tuning")."""
    loft_maker = BRepOffsetAPI_ThruSections(False, False)
    for wire in wires:
        loft_maker.AddWire(wire)
    loft_maker.CheckCompatibility(False)
    loft_maker.Build()
    if not loft_maker.IsDone():
        raise _bevel_failed("could not loft a spiral tooth flank/land surface across its cross-sections")
    faces = _explode_faces(loft_maker.Shape())
    if len(faces) != 1:
        raise _bevel_failed(f"expected exactly one face from an N-section ThruSections loft, got {len(faces)}")
    return faces[0]


def _flank_face_n(basis: ResolvedPlane, sections: list[list[tuple[float, float, float]]]) -> TopoDS_Face:
    """One spiral tooth flank's surface (right or left), N cross-sections
    (outer to inner) instead of `_flank_face`'s fixed 2 - each section is
    fit as its own real `Geom_BSplineCurve` wire (`_bspline_wire`,
    unchanged), then lofted together via `_thru_sections_face_n`."""
    return _thru_sections_face_n([_bspline_wire(basis, section) for section in sections])


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
# Spherical end-caps - the one genuinely new technique (10-bevel-gear.md §3)
# ---------------------------------------------------------------------------


def _unwrap_azimuths(raw_azimuths: list[float]) -> list[float]:
    """Running-offset azimuth unwrap - matches `numpy.unwrap`'s own
    algorithm (adjust each step by the nearest multiple of a full turn so
    consecutive values never jump by more than half a turn), hand-rolled
    here per `10-bevel-gear.md`'s own explicit "no numpy dependency"
    finding. Needed because `atan2` wraps to `(-pi, pi]`: naively using
    its raw per-point value breaks monotonicity every time the rim
    traversal (`_spherical_cap_face`, all the way around `tooth_count`
    teeth) crosses that seam, which a whole-gear rim always does for some
    tooth. Every consecutive pair of points this is applied to is close
    together in azimuth by construction (at most one tooth-plus-gap's own
    angular pitch, `2*pi / tooth_count`, always well under half a turn
    for any real gear), so "nearest multiple of a full turn" always finds
    the physically-correct unwrap, never an ambiguous one."""
    if not raw_azimuths:
        return []
    result = [raw_azimuths[0]]
    for raw in raw_azimuths[1:]:
        prev = result[-1]
        delta = raw - prev
        delta -= 2 * math.pi * round(delta / (2 * math.pi))
        result.append(prev + delta)
    return result


def _cap_rim_points(
    tooth_count: int, right0: list[tuple[float, float, float]], left0: list[tuple[float, float, float]]
) -> list[tuple[float, float, float]]:
    """The whole end-cap rim's local-frame points, in traversal order, one
    lap around the gear - `tooth_count` repetitions of [tooth's own right
    flank, root-to-tip] + [tooth's own left flank, tip-to-root] (`right0`/
    `left0` are tooth 0's own flank points, both already root-to-tip per
    `bevel_math.bevel_tooth_flank_pair`'s own docstring - the left flank
    is reversed here, unlike `gear_math`'s planar convention which already
    stores its own left flank pre-reversed), plus one closing point (a
    fresh copy of the very first point) so `_unwrap_azimuths` can carry
    the accumulated azimuth all the way around back to tooth 0's own
    starting point - needed for the final root-land arc's own pcurve,
    which spans from the last tooth back to the first."""
    points: list[tuple[float, float, float]] = []
    for i in range(tooth_count):
        angle = 2 * math.pi * i / tooth_count
        points.extend(_rotate_about_z(p, angle) for p in right0)
        points.extend(_rotate_about_z(p, angle) for p in reversed(left0))
    points.append(points[0])
    return points


def _spherical_cap_face(
    basis: ResolvedPlane,
    sphere_radius: float,
    start_colatitude: float,
    face_colatitude: float,
    tooth_count: int,
    right0: list[tuple[float, float, float]],
    left0: list[tuple[float, float, float]],
) -> TopoDS_Face:
    """One end-cap face (outer or inner sphere), bounded by the entire
    `4*tooth_count`-edge zigzag rim - `10-bevel-gear.md`'s own §3/§8: hand-
    built pcurves against a `Geom_SphericalSurface`, since
    `BRepBuilderAPI_MakeFace(Geom_SphericalSurface, wire)` given only 3D
    edges (no pcurves) silently returns a zero-area face, and
    `BRepOffsetAPI_MakeFilling` silently returns a ~3.2x-wrong area for a
    rim this irregular (both are real, measured dead ends per that doc -
    don't retry either).

    Each edge is built via the `BRepBuilderAPI_MakeEdge(pcurve2d, surface,
    P1, P2)` overload (a 2D curve on a surface plus two 3D end points, no
    explicit 3D curve) - a flank edge's pcurve is a `Geom2dAPI_Interpolate`
    through its own points' `(azimuth, latitude)` pairs (closed-form:
    `atan2(y, x)`, `asin(z / sphere_radius)` in the LOCAL apex-centred
    frame, which is exactly `_sphere_axis`'s own `Geom_SphericalSurface`
    parametrization at the matching world point); a tip-land/root-land
    arc edge's pcurve is a trivial `Geom2d_Line` between its own two
    points (constant latitude, azimuth varies) - matching the doc's own
    "trivial" description exactly, since `MakeEdge`'s 4-argument overload
    trims an unbounded `Geom2d_Line` to exactly the span between the two
    given 3D points, no explicit parameter range needed.

    `BRepLib.BuildCurves3d(wire)` runs BEFORE `MakeFace`, not after - per
    the doc's own second gotcha, an edge built from a pcurve+surface alone
    carries no 3D curve at all until that call, and `MakeFace`/
    `BRepCheck_Analyzer` cannot evaluate such an edge outside a face
    context."""
    surface = Geom_SphericalSurface(_sphere_axis(basis), sphere_radius)
    points_per_flank = len(right0)

    local_points = _cap_rim_points(tooth_count, right0, left0)
    raw_azimuths = [math.atan2(y, x) for x, y, _z in local_points]
    azimuths = _unwrap_azimuths(raw_azimuths)
    latitudes = [math.asin(max(-1.0, min(1.0, z / sphere_radius))) for _x, _y, z in local_points]
    world_points = [_basis_point3_to_world(basis, x, y, z) for x, y, z in local_points]

    def pnt2d(index: int) -> gp_Pnt2d:
        return gp_Pnt2d(azimuths[index], latitudes[index])

    def interpolated_pcurve(indices: range):
        points_2d = TColgp_HArray1OfPnt2d(1, len(indices))
        for offset, index in enumerate(indices, start=1):
            points_2d.SetValue(offset, pnt2d(index))
        interpolator = Geom2dAPI_Interpolate(points_2d, False, 1e-6)
        interpolator.Perform()
        if not interpolator.IsDone():
            raise _bevel_failed("could not fit a 2D pcurve through a tooth flank's sampled points")
        curve = interpolator.Curve()
        return curve, curve.FirstParameter(), curve.LastParameter()

    def line_pcurve(index_a: int, index_b: int):
        # `Geom2d_Line` is unbounded (parameter range (-inf, +inf)) - the
        # 4-arg `BRepBuilderAPI_MakeEdge(pcurve, surface, P1, P2)` overload
        # does NOT auto-trim an unbounded curve to the span between P1/P2
        # (confirmed on-device: it raises StdFail_NotDone), so this always
        # passes explicit parameters via the 6-arg overload instead - `0.0`
        # at `p_a` (the line's own origin) and the Euclidean 2D distance to
        # `p_b` (the line's own direction is already a unit vector via
        # `gp_Dir2d`, so parameter and arc length coincide).
        p_a, p_b = pnt2d(index_a), pnt2d(index_b)
        length = p_a.Distance(p_b)
        line = Geom2d_Line(p_a, gp_Dir2d(gp_Vec2d(p_a, p_b)))
        return line, 0.0, length

    wire_maker = BRepBuilderAPI_MakeWire()
    k = points_per_flank
    span = 2 * k  # one tooth's own share of _cap_rim_points: right (k) + left-reversed (k)
    for i in range(tooth_count):
        base = i * span
        right_range = range(base, base + k)
        left_range = range(base + k, base + span)

        right_pcurve, right_u1, right_u2 = interpolated_pcurve(right_range)
        wire_maker.Add(
            BRepBuilderAPI_MakeEdge(
                right_pcurve, surface, world_points[base], world_points[base + k - 1], right_u1, right_u2
            ).Edge()
        )

        tip_pcurve, tip_u1, tip_u2 = line_pcurve(base + k - 1, base + k)
        wire_maker.Add(
            BRepBuilderAPI_MakeEdge(
                tip_pcurve, surface, world_points[base + k - 1], world_points[base + k], tip_u1, tip_u2
            ).Edge()
        )

        left_pcurve, left_u1, left_u2 = interpolated_pcurve(left_range)
        wire_maker.Add(
            BRepBuilderAPI_MakeEdge(
                left_pcurve, surface, world_points[base + k], world_points[base + span - 1], left_u1, left_u2
            ).Edge()
        )

        next_base = (base + span) % (tooth_count * span)
        root_pcurve, root_u1, root_u2 = line_pcurve(base + span - 1, base + span)
        wire_maker.Add(
            BRepBuilderAPI_MakeEdge(
                root_pcurve, surface, world_points[base + span - 1], world_points[next_base], root_u1, root_u2
            ).Edge()
        )

    if not wire_maker.IsDone():
        raise _bevel_failed("could not assemble the spherical end-cap's own zigzag rim into one closed wire")
    wire = wire_maker.Wire()
    breplib.BuildCurves3d(wire)

    face_maker = BRepBuilderAPI_MakeFace(surface, wire)
    if not face_maker.IsDone():
        raise _bevel_failed("could not build a spherical end-cap face from its own rim wire")
    return face_maker.Face()


# ---------------------------------------------------------------------------
# End-cap flattening - trims each spherical end-cap's own dome/dish
# (`radius_from_axis < root_radius`, no tooth ever reaches there) down to a
# flat disc at the tooth root's own latitude, on the fully-assembled solid.
# ---------------------------------------------------------------------------


def _outer_cap_flattening_tool(
    basis: ResolvedPlane, sphere_radius: float, start_colatitude: float, radius_margin: float = 0.0
) -> TopoDS_Shape:
    """A plain coaxial cylinder, tangent to the outer cap's own tooth-root
    latitude circle, spanning from that tangent plane out to (and safely
    past) the sphere's own pole - used to `BRepAlgoAPI_Cut` away the outer
    cap's forward dome (`_flatten_end_caps`'s own docstring has the
    geometric argument for why every point at `radius < root_radius` is
    solid material bulging past this exact plane, and every point at
    `radius >= root_radius` - every real tooth flank/land face - never is).

    `radius_margin` (default `0.0`, straight bevel's own byte-for-byt no-op
    value): an *additional* shrink on top of `_END_CAP_RADIUS_MARGIN` below,
    `_flatten_end_caps`'s own real-worst-case spiral bulge estimate
    (`spiral_section_count_for_twist`'s own module docstring/`bevel_math.py`
    has the derivation) - a real spiral tooth's own N-section root-land loft
    is only guaranteed to pass exactly through its own sampled cross-
    sections, not to stay exactly on the root cone in between, so it can
    dip to a slightly smaller `radius_from_axis` than the nominal
    `root_radius` between two adjacent sections. Shrinking this tool's own
    radius further (not less) is the safe direction for a `Cut` tool
    specifically: it only ever narrows the region this tool can remove, so
    a larger `radius_margin` can only leave MORE of a thin, already-
    negligible sliver of the true dome un-cut at the very edge (a small,
    bounded cost - see `_flatten_end_caps`'s own docstring), never risk
    removing genuine tooth material that happens to dip slightly inward of
    the nominal boundary.

    A plain, possibly-overshooting-height cylinder is provably safe here
    specifically for `Cut` (unlike the analogous `Fuse` case on the inner
    cap, which needs `_inner_cap_flattening_tool`'s own exact spherical-
    segment solid instead - see that function's own docstring for why):
    `Cut` only ever removes `existing_solid ∩ tool`, and the dome's own
    cross-sectional radius (`sphere_radius * sin(colatitude)`) is <=
    `root_radius` at every colatitude from the root up to the pole (root_
    radius is that function's own maximum over the range), so a cylinder
    of exactly `root_radius` fully contains the dome at every height -
    remove exactly the dome, nothing more (any part of the tool beyond the
    pole intersects nothing, since there's no material there to begin
    with) and nothing less.

    The radius is shrunk by a small `_END_CAP_RADIUS_MARGIN` below the
    root latitude circle's own exact radius rather than built exactly on
    it - confirmed on-device that an exactly-tangent cylinder (its own rim
    edge exactly coincident with the sewn shell's own root-land/flank
    boundary) makes `BRepAlgoAPI_Cut` drop most of the flat disc face it
    should produce (silently, no exception - the boolean's own coincident-
    edge degeneracy)."""
    radius = sphere_radius * math.sin(start_colatitude) - _END_CAP_RADIUS_MARGIN - radius_margin
    tangent_z = sphere_radius * math.cos(start_colatitude)
    height = (sphere_radius - tangent_z) + _END_CAP_HEIGHT_MARGIN
    base_center = _basis_point3_to_world(basis, 0.0, 0.0, tangent_z)
    normal = basis_normal(basis)
    axis = gp_Ax2(base_center, normal)
    return BRepPrimAPI_MakeCylinder(axis, radius, height).Shape()


def _inner_cap_flattening_tool(
    basis: ResolvedPlane, sphere_radius: float, start_colatitude: float, radius_margin: float = 0.0
) -> TopoDS_Shape:
    """The EXACT solid needed to `BRepAlgoAPI_Fuse`-fill the inner cap's
    own recessed dish: a genuine `BRepPrimAPI_MakeSphere` spherical
    SEGMENT (the "latitude1/latitude2" overload, not the plain-radius one)
    spanning from the root latitude up to the pole - not an approximation
    like a cylinder or cone, the literal solid region `{points within
    sphere_radius of the local apex} ∩ {at or past the root's own
    latitude}`.

    This is the one tool shape that's simultaneously exact both AT the
    flat cut plane (its own flat end is a genuine circle of exactly
    `root_radius`, since that's just this same sphere's own cross-section
    at the root colatitude) AND along its own curved portion (identical
    to - not merely close to - the true dish it's replacing, since it's
    cut from the SAME sphere, same radius, same center). Confirmed
    on-device to be REQUIRED, not merely tidier, over a plain cylinder: a
    cylinder's constant radius vastly overshoots the dish's own rapidly-
    narrowing cross-section near the pole for any steep pitch cone (a
    45-degree-cone case measured a completely exposed extra cylindrical
    "shelf" face and `BRepCheck_Analyzer.IsValid() is False` before this
    fix), even though the same cylinder shape looks fine on a shallow one -
    `docs/status.md`'s matching dated entry has the full angle-dependent
    argument for why only the exact spherical segment is safe for every
    cone angle, not just the ones this session happened to check first.

    `gp_Ax2`'s own Z direction is the sphere's polar axis (`basis_normal`);
    OCCT's own latitude convention measures from the equator (`+-pi/2` at
    the poles), so `angle1 = pi/2 - start_colatitude` (colatitude is
    measured from the OTHER pole) and `angle2 = pi/2` (the pole itself).
    The X direction is `basis.x_axis`, given explicitly - on-device feedback
    (bevel-pair end-cap investigation) found this matters for real, not
    just tidiness: the 2-argument `gp_Ax2(point, direction)` form (no X
    given) lets OCCT auto-pick an arbitrary X perpendicular to the main
    direction, which this sphere's own Fuse target - `_spherical_cap_face`'s
    identical sphere, always built via `_sphere_axis`'s explicit-X `gp_Ax3`
    - has no reason to share. When the two happen to agree (as they always
    did for every basis this module was tested against before - the fixed
    XY plane, `normal = (0, 0, 1)`, apparently lands on the same auto-picked
    X OCCT would choose anyway) the Fuse cleanly recognizes the tool's
    sphere and the solid's own inner-cap sphere as the same surface and
    flattens correctly; for *any* other basis (confirmed on a plain 90-
    degree tilt, a generic 37-degree tilt, and a tilt about a different
    axis entirely - i.e. every `BevelPairFeature` member 2, which is never
    built on the untouched plane_ref) the mismatched parametrization
    silently breaks the Fuse - `IsDone()` still reports success, but the
    inner cap comes back still domed, not flattened, with no warning
    (`_single_solid_face_count`'s own post-boolean check only counts total
    faces, not planarity, so it doesn't catch this). Giving both spheres
    the exact same explicit X direction removes the mismatch entirely -
    verified on-device: the tilted-basis case that used to come back with
    only 1 planar face (should be 2) now matches the untilted case exactly,
    same face count, same planar count.

    Built at the exact `sphere_radius`/`start_colatitude` - NOT shrunk -
    unlike `_outer_cap_flattening_tool`'s own cylinder (which very
    deliberately shrinks its radius by `_END_CAP_RADIUS_MARGIN` to dodge a
    coincident-edge degeneracy). A shrunk sphere here was tried and
    confirmed WORSE on-device: `_flatten_end_caps`'s own `Fuse` then
    routinely lands as two touching-but-separate solids (a genuinely
    different failure than the un-shrunk exact tool's own occasional-but-
    rarer empty-result degeneracy) - `_flatten_end_caps`'s own `SetFuzzyValue`
    call on both booleans is this module's real answer to the coincident-
    edge case instead, and `_flatten_end_caps`'s own post-boolean face-count
    check (`_single_solid_face_count`) is the backstop for the cases even
    that doesn't resolve - see both of those for the full picture.

    `radius_margin` (default `0.0`, straight bevel's own byte-for-byte no-op
    value): the same spiral-bulge estimate `_outer_cap_flattening_tool`
    takes, but EXTENDING this tool's own colatitude range past
    `start_colatitude` (toward the tooth, not away from it) rather than
    shrinking anything - the opposite direction from the "shrunk sphere"
    experiment this docstring's own prior paragraph already found WORSE, so
    it does not reintroduce that failure mode. Safe for this tool
    specifically because `Fuse` is additive: extending the fill tool
    slightly past the nominal root colatitude can only ensure a spiral
    root-land loft that dips slightly inward (a smaller local `radius_from_
    axis` than the nominal `root_radius` between two adjacent sections,
    `_flatten_end_caps`'s own docstring has the mechanism) is still fully
    covered by the fill - never risks removing anything, since there is no
    subtraction here to remove real material with. Converted from a
    linear-mm margin to a colatitude delta via the same small-angle
    approximation `_flatten_end_caps` uses to derive `radius_margin` in the
    first place (`arc_length ~= sphere_radius * delta_angle` for small
    `delta_angle`): `delta_colatitude = radius_margin / sphere_radius`."""
    ox, oy, oz = basis.origin
    nx, ny, nz = basis.normal
    xx, xy, xz = basis.x_axis
    apex = _basis_point3_to_world(basis, 0.0, 0.0, 0.0)
    axis = gp_Ax2(apex, gp_Dir(nx, ny, nz), gp_Dir(xx, xy, xz))
    delta_colatitude = radius_margin / sphere_radius if sphere_radius else 0.0
    angle1 = math.pi / 2 - start_colatitude - delta_colatitude
    angle2 = math.pi / 2
    return BRepPrimAPI_MakeSphere(axis, sphere_radius, angle1, angle2).Shape()


def _flatten_end_caps(
    basis: ResolvedPlane,
    geometry: BevelGearGeometry,
    start_colatitude: float,
    solid: TopoDS_Shape,
    twist_per_section: float = 0.0,
) -> TopoDS_Shape:
    """Trims both spherical end-caps (`_spherical_cap_face`, one per
    `_assemble_gear_solid` call - outer at `geometry.cone_distance`, inner
    at `geometry.inner_cone_distance`) down to a flat disc at the tooth
    root's own latitude - the change this session's own user testing asked
    for directly: "the convex face needs to be taken off at the outboard
    tooth root [and] the concave space needs filling in at the tooth
    outboard root."

    **Why a flat disc at the root's own latitude, not the tip's**: every
    end-cap point at `colatitude < start_colatitude` (i.e. `radius <
    root_radius`, the region strictly under the gear's own central hub, no
    tooth ever reaches there - `_cap_rim_points`'s own zigzag rim never
    dips below `start_colatitude`, since root-land arcs sit at exactly that
    colatitude and flank curves only ever increase from it toward the tip)
    sits at `z = R*cos(colatitude) > R*cos(start_colatitude)` - strictly
    PAST the root's own flat plane, since cosine is strictly decreasing
    over this range. That's the dome/dish this trims away or fills in.
    Conversely every point at `colatitude >= start_colatitude` (i.e.
    `radius >= root_radius`) sits at `z <= R*cos(start_colatitude)` - AT OR
    BEHIND that same flat plane, never past it - and that's exactly where
    every real tooth flank/tip-land/root-land face lives (by the same
    zigzag-rim fact above). So a flat cut/fill exactly at the root's own
    latitude is provably the ONE choice that removes 100% of the dome/dish
    (nothing with `radius < root_radius` is ever left un-trimmed) while
    touching 0% of real tooth material (nothing with `radius >= root_radius`
    is ever in front of that plane to begin with).

    A flat cut at the TIP's own (larger) colatitude instead - the more
    obvious-looking choice, since it's the tooth's own visible top land -
    was this session's own earlier, wrong attempt: measured to remove
    ~12% of each flank's own real surface area, because the tip-land arc's
    own radius is only reached at the narrow top-land azimuths, not all the
    way around, so a full circle that size necessarily eats into the
    flank's own material everywhere else around that radius.

    `Fuse` first, for the inner cap's own recessed dish (`_inner_cap_
    flattening_tool`'s own EXACT spherical-segment solid - required, not
    just tidier, for `Fuse` to stay correct across every cone angle, per
    that function's own docstring), THEN `Cut`, for the outer cap's own
    forward dome (`_outer_cap_flattening_tool`'s own plain, oversized-on-
    purpose cylinder - provably safe for `Cut` regardless of cone angle) -
    fuse-before-cut, not the other way round, matters for real: the inner
    tool's own solid sphere segment reaches all the way up to `inner_cone_
    distance` itself (that sphere's own pole, at `radius = 0`) to correctly
    close the gap there, and for a large enough `face_width` relative to
    `cone_distance` on a steep pitch cone, that pole can sit PAST the outer
    cap's own flat target z (confirmed on-device: a 45-degree/`face_width`-
    heavy case measured `inner_cone_distance` itself landing above `outer_
    tangent_z`) - i.e. the fuse can genuinely overshoot past where the
    outer cap's own flat plane belongs. Cutting last always re-establishes
    that exact plane regardless, trimming away any such overshoot along
    with the original dome in the same pass; cutting first would leave that
    overshoot in place uncorrected, since nothing runs after it to catch it.

    **`twist_per_section`** (default `0.0` - straight bevel's own byte-for-
    byte no-op value, since there is no per-section approximation there at
    all): the worst-case azimuthal twist (radians) `app.document.bevel_
    math.spiral_section_count_for_twist`'s own effective section count still
    leaves between two adjacent spiral cross-sections - `_assemble_gear_
    solid`'s own caller computes this once, from the same `spiral_curve_
    offset_angle` total-twist quantity that function already derives, using
    whatever `section_count` it actually ends up using (which can exceed
    the bound-driven minimum if the caller/feature passed a larger one
    explicitly). Converted to a linear-mm bulge estimate at each cap's own
    `root_radius = sphere_radius * sin(start_colatitude)` via the small-
    angle approximation `arc_length ~= radius * angle` (both this function's
    own `radius_margin` terms below and `_inner_cap_flattening_tool`'s own
    colatitude-delta conversion share this same approximation) - a real,
    but deliberately secondary, safety net for whatever residual surface-
    bulge `_tooth_side_faces_spiral`'s own N-section root/tip-land loft
    still carries after `spiral_section_count_for_twist` has already cut it
    down close to (not exactly to) zero. See `_outer_cap_flattening_tool`'s
    own docstring for why growing this margin is safe in each tool's own
    respective direction (shrink further for the subtractive `Cut` tool,
    extend further for the additive `Fuse` tool - never the other way
    round for either)."""
    outer_radius_margin = geometry.cone_distance * math.sin(start_colatitude) * twist_per_section
    inner_radius_margin = geometry.inner_cone_distance * math.sin(start_colatitude) * twist_per_section

    inner_tool = _inner_cap_flattening_tool(basis, geometry.inner_cone_distance, start_colatitude, inner_radius_margin)
    fuse = BRepAlgoAPI_Fuse(solid, inner_tool)
    fuse.SetFuzzyValue(_END_CAP_FUZZY_VALUE)
    fuse.Build()
    if not fuse.IsDone():
        raise _bevel_failed("could not fill the inner end-cap's own central spherical dish")
    filled = fuse.Shape()

    outer_tool = _outer_cap_flattening_tool(basis, geometry.cone_distance, start_colatitude, outer_radius_margin)
    cut = BRepAlgoAPI_Cut(filled, outer_tool)
    cut.SetFuzzyValue(_END_CAP_FUZZY_VALUE)
    cut.Build()
    if not cut.IsDone():
        raise _bevel_failed("could not flatten the outer end-cap's own central spherical dome")
    result = cut.Shape()

    # `IsDone()` alone isn't sufficient evidence the booleans above actually
    # produced a real, single, closed solid - confirmed on-device that a
    # marginal-geometry gear (one already flagged by `BRepCheck_Analyzer`
    # before either boolean even runs - the fold-risk regime's own known
    # false-negative, see this module's own top-level docstring) can make
    # `BRepAlgoAPI_Fuse` report `IsDone() == True` while silently returning
    # an empty compound (0 faces, 0 solids) - a hard failure `IsDone()`
    # itself never surfaces. `_assemble_gear_solid`'s own caller falls back
    # to the un-flattened solid (with a warning) if this raises.
    if _single_solid_face_count(result) == 0:
        raise _bevel_failed("end-cap flattening produced an empty or non-solid result")
    return result


def _single_solid_face_count(shape: TopoDS_Shape) -> int:
    """0 if `shape` isn't exactly one closed solid (an empty compound, or
    more than one disjoint piece) - `_flatten_end_caps`'s own post-boolean
    sanity check, not a generic utility."""
    n_solids = 0
    explorer = TopExp_Explorer(shape, TopAbs_SOLID)
    while explorer.More():
        n_solids += 1
        explorer.Next()
    if n_solids != 1:
        return 0
    n_faces = 0
    face_explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while face_explorer.More():
        n_faces += 1
        face_explorer.Next()
    return n_faces


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
    every mesh triangle of a real `BRepMesh_IncrementalMesh` tessellation.

    On-device feedback (bevel-pair timeout investigation): deflection
    raised from a fixed 0.05mm to a fixed 0.3mm - this mesh only feeds the
    volume cross-check above (>2% disagreement warning), not any geometry
    this Feature actually returns, so it doesn't need fine-print accuracy;
    coarsening it cuts triangle count (and therefore tessellation cost) on
    every curved B-spline flank substantially while staying far tighter
    than the 2% comparison tolerance for any realistic gear size. Not
    switched to `isRelative=True` (deflection-as-a-fraction-of-bounding-box)
    despite that scaling more naturally across gear sizes - unverified
    on-device in this session (no pythonocc-core available), so kept as the
    same simple absolute-value knob the original code already used, just
    larger; worth revisiting with real timing data."""
    BRepMesh_IncrementalMesh(solid, 0.3, False, 0.5, True)
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
    §8: an independent mesh-volume cross-check against `BRepGProp`'s own
    analytic volume - run once, after assembly, deliberately NOT gating on
    `BRepCheck_Analyzer.IsValid()` (confirmed wrong for this construction's
    own end-caps, per that doc's §5). Non-blocking, per `00-conventions.md`
    - a disagreement here is a real, but not certainly-fatal, signal worth
    surfacing.

    On-device feedback (bevel-pair timeout investigation): this used to also
    run `BOPAlgo_CheckerSI` (whole-solid self-intersection check) here -
    dropped entirely, not just made cheaper. It was always the more
    expensive of the two checks (cost scales with the assembled solid's
    total face count, `4*tooth_count + 2` for a Bevel Pair's own worse
    member) and this module's own top-level docstring already frames it as
    "a final sanity pass rather than the primary defense" - `_flank_fold_
    warning` (run once, before assembly, on a single flank) is the actual
    primary defense against the real failure mode (a folded/self-
    overlapping tooth flank from too-large face_width), and per `10-bevel-
    gear.md`'s own §7 finding, ring assembly never introduces a fold risk
    `_flank_fold_warning` didn't already catch on that one flank. So
    dropping this redundant, expensive, genuinely-secondary check trades
    away no real coverage."""
    warnings: list[str] = []

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


def _tooth_side_faces_straight(
    basis: ResolvedPlane,
    geometry: BevelGearGeometry,
    tooth_count: int,
    right0: tuple[list[tuple[float, float, float]], list[tuple[float, float, float]]],
    left0: tuple[list[tuple[float, float, float]], list[tuple[float, float, float]]],
    start_colatitude: float,
) -> tuple[list[TopoDS_Face], str | None]:
    """The `4*tooth_count` flank/tip-land/root-land faces for a straight
    (non-spiral) bevel gear - `10-bevel-gear.md`'s own §8 implementation
    sketch, unchanged, extracted out of `_assemble_gear_solid` verbatim so
    that function can branch to `_tooth_side_faces_spiral` below when
    spiral is active (`docs/gear-design/12-spiral-bevel-gear.md`) without
    duplicating the shared sewing/solid-assembly tail."""
    right0_outer, right0_inner = right0
    left0_outer, left0_inner = left0

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
    return faces, fold_warning


def _section_sphere_radius(point: tuple[float, float, float]) -> float:
    """The exact sphere radius a local-frame point lies on - every point
    `bevel_tooth_flank_sections` produces lies exactly on the sphere of its
    own section's `sphere_radius` by construction (a pure rotation about
    the gear axis of a `sample_tredgold_flank` point, itself always
    re-projected onto that exact sphere - `tredgold_bevel_point`'s own
    docstring), so recovering it via the point's own norm needs no extra
    bookkeeping of which section index maps to which radius."""
    x, y, z = point
    return math.sqrt(x * x + y * y + z * z)


def _tooth_side_faces_spiral(
    basis: ResolvedPlane,
    geometry: BevelGearGeometry,
    tooth_count: int,
    right0_sections: list[list[tuple[float, float, float]]],
    left0_sections: list[list[tuple[float, float, float]]],
    start_colatitude: float,
) -> tuple[list[TopoDS_Face], str | None]:
    """`docs/gear-design/12-spiral-bevel-gear.md`: the spiral-aware
    counterpart of `_tooth_side_faces_straight` above - N cross-sections
    (`bevel_tooth_flank_sections`) instead of a fixed 2. The end-cap faces
    still only need the outermost/innermost sections (`right0_sections[0]`/
    `[-1]`, same role `right0_outer`/`right0_inner` play for the straight
    case) - `_assemble_gear_solid`'s own caller passes those separately, no
    change needed to `_spherical_cap_face` itself (per that doc's own
    "End-cap faces: conceptually unchanged" finding).

    Tip-land/root-land: that doc's own "OCCT construction — open
    questions" section names this the one place needing new work -
    `_cone_arc_wire`'s exact-ray-through-the-apex shortcut only holds for a
    straight tooth. The fix used here needs no new curve type though (per
    that same section's own "one 2-parameter family, not a new curve
    type" observation): each cross-section's own tip/root points are
    already exactly where the flank curve's own endpoints sit at that
    section's radius, so tip-land/root-land become N `_cone_arc_wire` arcs
    (one per section, at that section's own `sphere_radius`) lofted via
    `_thru_sections_face_n` - the same idiom the flank itself uses, just
    with arc wires instead of BSpline wires."""
    n_sections = len(right0_sections)
    faces: list[TopoDS_Face] = []
    fold_warning: str | None = None
    for i in range(tooth_count):
        angle = 2 * math.pi * i / tooth_count
        right_sections = [[_rotate_about_z(p, angle) for p in section] for section in right0_sections]
        left_sections = [[_rotate_about_z(p, angle) for p in section] for section in left0_sections]

        right_flank_face = _flank_face_n(basis, right_sections)
        left_flank_face = _flank_face_n(basis, left_sections)
        if i == 0:
            # Same "all teeth identical up to rotation" reasoning as the
            # straight case - checking tooth 0's own flank once is the
            # load-bearing check.
            fold_warning = _flank_fold_warning(right_flank_face)
        faces.append(right_flank_face)
        faces.append(left_flank_face)

        tip_wires = [
            _cone_arc_wire(
                basis,
                _section_sphere_radius(right_sections[k][-1]),
                geometry.face_cone_angle,
                _basis_point3_to_world(basis, *right_sections[k][-1]),
                _basis_point3_to_world(basis, *left_sections[k][-1]),
            )
            for k in range(n_sections)
        ]
        tip_land_face = _thru_sections_face_n(tip_wires)
        if i == 0 and fold_warning is None:
            # `docs/gear-design/12-spiral-bevel-gear.md`'s own "OCCT
            # construction — open questions" flagged the fold-risk
            # thresholds as "tuned for straight/Tredgold-straight teeth...
            # needs re-validation, not carry-forward" - `_flank_fold_
            # warning` is already generic/face-agnostic (walks a UV grid off
            # `BRep_Tool.Surface(face)`, no flank-specific assumption), it
            # was just never called on the root-land/tip-land faces before
            # this session. Checked here too, not just the flank, since
            # tip-land/root-land are now the SAME kind of N-section
            # `ruled=False` loft the flank is (`_thru_sections_face_n`) -
            # the exact-cone shortcut that made the straight-bevel version
            # of these faces immune to this risk no longer applies once
            # spiral is active (this module's own top-level docstring has
            # the full mechanism). `fold_warning is None` short-circuits
            # once the flank check above already found one - one non-
            # blocking warning is this module's own established convention,
            # not a growing list of near-duplicate ones.
            fold_warning = _flank_fold_warning(tip_land_face)
        faces.append(tip_land_face)

        next_angle = 2 * math.pi * ((i + 1) % tooth_count) / tooth_count
        next_right_sections = [[_rotate_about_z(p, next_angle) for p in section] for section in right0_sections]
        root_wires = [
            _cone_arc_wire(
                basis,
                _section_sphere_radius(left_sections[k][0]),
                start_colatitude,
                _basis_point3_to_world(basis, *left_sections[k][0]),
                _basis_point3_to_world(basis, *next_right_sections[k][0]),
            )
            for k in range(n_sections)
        ]
        root_land_face = _thru_sections_face_n(root_wires)
        if i == 0 and fold_warning is None:
            # Same reasoning as the tip-land check above.
            fold_warning = _flank_fold_warning(root_land_face)
        faces.append(root_land_face)
    return faces, fold_warning


def _assemble_gear_solid(
    basis: ResolvedPlane,
    geometry: BevelGearGeometry,
    tooth_count: int,
    points_per_flank: int = _POINTS_PER_FLANK,
    spiral_angle_degrees: float = 0.0,
    spiral_hand: SpiralHand = SpiralHand.RIGHT,
    spiral_section_count: int = DEFAULT_SPIRAL_SECTION_COUNT,
) -> tuple[TopoDS_Shape, list[str]]:
    """The full bevel gear solid - `10-bevel-gear.md`'s own §8
    implementation sketch, in order: collect the `4*tooth_count` (straight)
    or `4*tooth_count` (spiral, same face count - N sections just means
    more wires per `ThruSections` call, not more faces) side faces tooth by
    tooth, append the 2 end-cap faces, `Sewing` -> `ShapeFix_Shell` ->
    `MakeSolid` -> `OrientClosedSolid` (§4's exact sequence - `MakeSolid`
    alone on the raw sewn shell is not sufficient). Root fillet is not
    supported - see `BevelGearFeature`'s own docstring for why (no
    `BRepPrimAPI_MakePrism.Generated()`-equivalent vertex-tracking for a
    `ThruSections`/`Sewing`-built solid).

    `spiral_angle_degrees == 0.0` (the default) is a **literal no-op**:
    takes the exact same `bevel_tooth_flank_pair`/`_tooth_side_faces_
    straight` path this function always has, byte-for-byte unchanged
    (`docs/gear-design/12-spiral-bevel-gear.md`'s own task instructions -
    verified directly in `test_bevel_gear_feature.py`, not just assumed
    from `bevel_tooth_flank_sections`'s own bit-for-bit math reduction).
    Only `spiral_angle_degrees != 0.0` takes the new `bevel_tooth_flank_
    sections`/`_tooth_side_faces_spiral` path, at `max(spiral_section_count,
    spiral_section_count_for_twist(...))` cross-sections
    (`DEFAULT_SPIRAL_SECTION_COUNT = 3`, per that doc's own Spike A §3
    convergence finding, re-validated in `test_bevel_math.py`) -
    `spiral_section_count_for_twist` (`bevel_math.py`) raises that count
    further whenever the per-build twist would otherwise leave the N-
    section root/tip-land loft too far off the true root/tip cone for
    `_flatten_end_caps`'s own fixed margins to reliably cover (this
    module's own top-level docstring has the full root-cause chain from
    `docs/gear-design/12-spiral-bevel-gear.md`'s own documented "end-cap
    flattening failed" cases) - `max(...)`, not a plain override, since a
    caller-supplied `spiral_section_count` above the twist-driven minimum
    (more fidelity than strictly required) is never something this
    should silently reduce."""
    start_colatitude = max(geometry.root_cone_angle, tredgold_base_colatitude(geometry))
    face_colatitude = geometry.face_cone_angle

    if spiral_angle_degrees == 0.0:
        right0, left0 = bevel_tooth_flank_pair(geometry, points_per_flank)
        right0_outer, right0_inner = right0
        left0_outer, left0_inner = left0
        side_faces, fold_warning = _tooth_side_faces_straight(basis, geometry, tooth_count, right0, left0, start_colatitude)
        outer_right, inner_right = right0_outer, right0_inner
        outer_left, inner_left = left0_outer, left0_inner
        twist_per_section = 0.0
    else:
        effective_section_count = max(
            spiral_section_count,
            spiral_section_count_for_twist(geometry, tooth_count, spiral_angle_degrees, spiral_hand, spiral_section_count),
        )
        right0_sections, left0_sections = bevel_tooth_flank_sections(
            geometry, spiral_angle_degrees, spiral_hand, points_per_flank, effective_section_count
        )
        side_faces, fold_warning = _tooth_side_faces_spiral(
            basis, geometry, tooth_count, right0_sections, left0_sections, start_colatitude
        )
        outer_right, inner_right = right0_sections[0], right0_sections[-1]
        outer_left, inner_left = left0_sections[0], left0_sections[-1]

        # `_flatten_end_caps`'s own secondary safety margin - the actual
        # worst-case per-step twist left over after `effective_section_
        # count` above, not just the bound `spiral_section_count_for_twist`
        # targeted (which can differ when a caller-supplied `spiral_
        # section_count` already exceeds the twist-driven minimum). Reuses
        # the identical `spiral_curve_offset_angle` total-twist derivation
        # that function already makes - see its own docstring for why
        # `mean_radius`'s exact value doesn't affect this difference.
        spiral_angle = math.radians(spiral_angle_degrees)
        mean_radius = (geometry.cone_distance + geometry.inner_cone_distance) / 2.0
        total_twist = abs(
            spiral_curve_offset_angle(spiral_angle, geometry.pitch_cone_angle, geometry.cone_distance, mean_radius, spiral_hand)
            - spiral_curve_offset_angle(
                spiral_angle, geometry.pitch_cone_angle, geometry.inner_cone_distance, mean_radius, spiral_hand
            )
        )
        twist_per_section = total_twist / (effective_section_count - 1)

    faces: list[TopoDS_Face] = list(side_faces)
    faces.append(
        _spherical_cap_face(
            basis, geometry.cone_distance, start_colatitude, face_colatitude, tooth_count, outer_right, outer_left
        )
    )
    faces.append(
        _spherical_cap_face(
            basis,
            geometry.inner_cone_distance,
            start_colatitude,
            face_colatitude,
            tooth_count,
            inner_right,
            inner_left,
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
    try:
        flattened = _flatten_end_caps(basis, geometry, start_colatitude, solid, twist_per_section)
    except HTTPException:
        # A real, on-device-confirmed failure mode (`_flatten_end_caps`'s
        # own docstring/`_single_solid_face_count`): an already-marginal
        # gear (one deep in the fold-risk regime, itself already flagged by
        # `BRepCheck_Analyzer` before either boolean even runs) can make
        # `BRepAlgoAPI_Fuse` silently return an empty/non-solid result.
        # Falling back to the un-flattened spherical cap - not re-raising,
        # since an unflattened (still fully valid, just visibly domed/
        # dished) end-cap on an extreme-geometry gear is a real-but-non-
        # fatal degradation, not a reason to refuse the gear outright.
        #
        # On-device feedback (bevel-pair meshing/build-quality investigation):
        # this used to be silent (log-only, no user-facing warning) on the
        # stated assumption this was "a case this rare" it wasn't - a
        # default Bevel Pair's own two members (20/40 teeth, gamma ~63
        # degrees for the 40-tooth member) hit it for one member and not
        # the other, producing two visibly different-looking gear backs
        # (one flat, one still domed/dished) with no indication why. Now a
        # real non-blocking warning, same convention as every other
        # `00-conventions.md` warning this module surfaces.
        logger.warning("Bevel gear end-cap flattening itself failed - falling back to the true spherical cap", exc_info=True)
        warnings.append(
            "This bevel gear's end-cap could not be flattened to a flat disc at the tooth root and is "
            "still visibly domed/dished (a spherical cap) instead - the gear itself is still valid, just "
            "not flat-backed. Try a smaller face_width or a less extreme pitch cone angle."
        )
        flattened = solid
    warnings.extend(_assembly_sanity_warnings(flattened))
    return flattened, warnings


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
    if feature.points_per_flank < 2:
        # Mirrors `app.document.gear.resolve_gear_from_bodies`'s own
        # `points_per_flank must be >= 2` floor (`gear.py:536-543`) - same
        # `sample_tredgold_flank`/`sample_involute_flank` `point_count must
        # be >= 2` requirement underneath, checked here so a bad value fails
        # closed with a clean 422 instead of an uncaught GearGeometryError
        # surfacing as a 500 partway through flank sampling.
        raise _invalid_bevel_parameters(f"points_per_flank must be >= 2, got {feature.points_per_flank!r}")
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
    hub_warning = thin_hub_warning(feature.pitch_cone_angle_degrees)
    if hub_warning:
        warnings.append(hub_warning)
    max_face_width = max_recommended_face_width(geometry.cone_distance)
    if feature.face_width > max_face_width:
        warnings.append(
            f"face_width ({feature.face_width!r}) exceeds the recommended maximum "
            f"({max_face_width!r} = cone_distance / 3) - the tooth thins toward degeneracy near the apex."
        )
    # docs/gear-design/12-spiral-bevel-gear.md's own Spike C §4 cost finding
    # - a real, decided non-blocking warning (item 6 of this workstream's
    # own task scope), not silently unaddressed.
    cost_warning = spiral_build_cost_warning(feature.spiral_angle_degrees)
    if cost_warning:
        warnings.append(cost_warning)

    basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)
    solid, assembly_warnings = _assemble_gear_solid(
        basis,
        geometry,
        feature.tooth_count,
        feature.points_per_flank,
        spiral_angle_degrees=feature.spiral_angle_degrees,
        spiral_hand=_spiral_hand_from_feature(feature.spiral_hand),
    )
    # `assembly_warnings` (fold risk, end-cap-flattening fallback, assembly-
    # sanity volume mismatch) leads the returned list, ahead of the purely
    # advisory warnings collected above (face_width/thin-hub/build-cost) -
    # a full un-flattened dome/dish is the single most visually severe
    # fallback this module surfaces (immediately, obviously wrong on
    # inspection, unlike an advisory margin warning), so it belongs first,
    # not buried after warnings the user is far more likely to shrug off.
    return solid, assembly_warnings + warnings


def resolve_bevel_gear(
    part: Part, feature: BevelGearFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[TopoDS_Shape, list[str]]:
    """Fresh entry point for the router's create/update validation -
    mirrors `app.document.gear.resolve_gear`'s exact shape."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_bevel_gear_from_bodies(feature, part, bodies, excluded_feature_ids | {feature.id})
