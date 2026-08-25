"""OCCT geometry construction for `BevelPairFeature`
(`docs/gear-design/11-bevel-pair.md`) - two apex-aligned mating bevel gears,
resolved into a `TopoDS_Compound` of exactly 2 Bodies the same way `app.
document.gear_chain`/`app.document.planetary_gear` resolve their own
multi-Body compounds, for `app.document.extrude.compute_part_bodies` to
register via `_register_solids` unchanged.

**Reuses `app.document.bevel`'s own real internals directly** - per
`10-bevel-gear.md`'s own confirmed findings, `bevel._assemble_gear_solid`
was already written to take a plain `basis`/`geometry`/`tooth_count` rather
than a whole `BevelGearFeature`, so this module calls it once per member
with each member's own resolved basis/geometry, without touching `bevel.py`'s
own construction code at all - exactly the "closest precedent" reuse `05-
gear-chain-and-planetary.md`'s `GearChainFeature`/`PlanetaryGearFeature`
already established for `app.document.gear`'s own internals.

**Cone angles are auto-derived, not entered** - `bevel_math.pitch_cone_half_
angles(member_1.tooth_count, member_2.tooth_count, shaft_angle_degrees)`
resolves both members' own pitch cone half-angles in one call, each then fed
into `bevel_math.bevel_gear_geometry` via its `pitch_cone_angle_degrees`
direct-field path (the same path `BevelGearFeature` uses, since a pair
member's own gamma is now a known, resolved value, not something to
re-derive from a mate tooth count a second time).

**Positioning - apex-aligned, the one genuinely new piece**: both members'
cone apexes coincide at `plane_ref`'s own origin. Member 1's axis is `plane_
ref`'s own normal directly (identical basis to a standalone `BevelGearFeature`).
Member 2's axis is member 1's axis rotated by `shaft_angle_degrees` about
`plane_ref`'s own `x_axis` - see `_tilted_basis`'s own docstring for the
exact rotation-axis/sign convention (CCW-positive about `x_axis`, matching
`RevolveFeature.angle`'s own right-hand-rule convention, `00-conventions.md`) -
a genuinely different, larger operation than `app.document.gear._twisted_
basis`/`app.document.gear_chain._positioned_basis`, both of which only ever
rotate `x_axis`/`y_axis` *within* the same plane (about the normal); this
rotates the normal itself out of the original plane.

**No `GearChainFeature`-style non-adjacent-stage interference checking** -
explicit simplification per `11-bevel-pair.md`: with exactly two members
that are always the intended meshing pair, there is no "non-adjacent
stage" case for `GearChainFeature`'s own bent-path interference machinery
to apply to. This does **not** mean no interference checking at all -
`resolve_member_profile_shifts` below and `bevel_math.bevel_pair_mesh_
interference_warning` handle real, measurable tooth-tip interference
between the two members that *do* mesh, a different (and real) problem
`GearChainFeature`'s own machinery was never meant to catch either.

**Meshing phase alignment** (bug fix - on-device feedback: two bevel
pairs' teeth visibly overlapping instead of interlocking in the 3D
viewer). Root cause: `app.document.bevel._assemble_gear_solid` always
centers "tooth 0" at local azimuth 0 (along `basis.x_axis`) for *both*
members, but the true pitch-cone tangency line - where the two cones
actually touch, the one physically meaningful reference direction for
meshing - sits at local azimuth **+-90 degrees from `x_axis`** in each
member's own frame, not 0. This falls straight out of `_tilted_basis`'s
own construction: it rotates member 2's axis *about* `x_axis`, so both
members' axes (and therefore the tangency line, which must be coplanar
with both axes) live entirely in the plane perpendicular to `x_axis` -
i.e. `x_axis` itself is the *normal* of that plane, so the tangency
direction can have no `x_axis` component, azimuth 90 degrees from it,
independent of shaft angle or tooth counts. Confirmed by direct
calculation: in member 1's local frame the tangency direction is
`(0, sin(gamma_1), cos(gamma_1))` (zero `x_axis`/local-x component, by
construction); expressed in member 2's own local frame (dotting with its
`y_axis`/`normal`, both already known in terms of `y_axis_1`/`normal_1`
via `_tilted_basis`) it simplifies via the angle-difference trig identity
to `(0, -sin(gamma_2), cos(gamma_2))` - again zero local-x component, i.e.
azimuth -90 degrees. So with neither member's tooth pattern rotated to
account for this, whichever tooth/gap happens to land near that line is
essentially arbitrary (depends on tooth counts mod 4) - not reliably a
tooth meeting a gap.

Fix: rotate each member's *finished solid* about its own axis
(`_rotated_about_axis`, applied in the same worker that builds it, before
BREP serialization - `bevel.py`'s own construction code stays untouched,
consistent with this module's "closest precedent" reuse above) so a tooth
of member 1 and a gap of member 2 both land exactly on the shared
tangency line: `+pi/2` for member 1 (any tooth can be defined to sit
there, since a standalone gear's own rotational phase is arbitrary to
begin with) and `-pi/2 + pi/tooth_count_2` for member 2 (offsets by half
its own angular pitch from member 1's convention, landing a *gap*, not a
tooth, at its own `-pi/2`).

**Members build concurrently, in separate processes** (on-device feedback,
bevel-pair timeout investigation - the default pair, 20/40 teeth, was
timing out the 3-minute request budget even at the cheapest tooth-curve
precision, since neither that slider nor the diagnostics trimmed in
`app.document.bevel._assembly_sanity_warnings` touch the two dominant costs:
building `4*tooth_count + 2` faces and the end-cap-flattening booleans -
both scale with each member's own tooth count independently). `member_1`/
`member_2` are fully independent builds (different geometry, different
basis) with no shared mutable state, so `_build_member_solid` runs each in
its own OS process via `ProcessPoolExecutor` for genuine multi-core
parallelism - deliberately not a `ThreadPoolExecutor`: whether pythonocc-
core's SWIG-wrapped OCCT calls release the GIL during heavy C++ work isn't
something this session could verify (no on-device access), so a process
pool is the only way to *guarantee* the two builds actually overlap on
separate cores rather than time-slicing one. A `TopoDS_Shape` itself can't
cross a process boundary (not picklable), so each worker round-trips its
own finished solid through a real BREP file via `_shape_to_brep_bytes`/
`_shape_from_brep_bytes` - `ResolvedPlane`/`BevelGearGeometry` (this
function's own inputs) are already plain-dataclass/tuple-of-floats, no
OCCT types, so they pickle across the process boundary for free.

**Spiral bevel pairing** (`docs/gear-design/12-spiral-bevel-gear.md`'s own
Spike C, `13-spiral-bevel-pair.md`'s own go/no-go) - `BevelPairFeature.
spiral_angle_degrees` (pair-level shared - both members physically mesh at
one spiral trace, see that dataclass's own docstring for the field-
placement decision) turns on two things once non-zero: `_build_member_
solid` builds each member's own N-section spiral flank
(`app.document.bevel._assemble_gear_solid`'s own spiral parameters,
unchanged construction code), and `resolve_bevel_pair_from_bodies` runs a
real per-build meshing-phase search (`_search_meshing_phase`, below) in
place of trusting the fixed `+-pi/2`/`-pi/2 + pi/tooth_count_2` convention
outright - that convention is exactly correct for a straight-bevel pair
(Tredgold's own conjugate-action guarantee, `11-bevel-pair.md`'s own
"meshing phase alignment" docstring) but only approximately so once a
curved lengthwise trace is involved. `spiral_angle_degrees == 0.0` skips
the search entirely - the existing straight-bevel code path is untouched,
byte-for-byte.

**Cost/timeout, a real decision, not a silently-absorbed risk**: Spike C's
own on-device numbers (§4) put a single phase-search trial at 1-3s in the
well-behaved regime but up to ~16s near/past a notch, times this module's
own bounded eval budget (`_PHASE_SEARCH_GRID_POINTS` coarse-grid points
plus `_PHASE_SEARCH_REFINE_ITERATIONS` golden-section steps, ~33 trials
worst case) - up to roughly 9 minutes for the search alone in the worst
case, on top of both members' own build cost (which itself grows near a
notch, per `bevel_math.spiral_build_cost_warning`). The client
(`DocumentApiClient`) raises its own request timeout specifically for a
spiral `BevelPairFeature` create/update call (`ApiConfig.
spiralBevelPairRequestTimeout`, not the blanket `documentRequestTimeout`
used everywhere else) rather than raising every `/document` call's own
timeout for a cost that's concentrated in exactly one Feature type's own
worst case - see that constant's own doc comment for the exact budget this
is sized against."""

import math
import multiprocessing
import os
import tempfile
from concurrent.futures import ProcessPoolExecutor
from dataclasses import replace

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Common
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepTools import breptools
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax1, gp_Dir, gp_Pnt, gp_Trsf
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape

from app.document.bevel import _assemble_gear_solid, _spiral_hand_from_feature
from app.document.bevel_math import (
    MESH_MARGIN_SAFETY_BUFFER_DEGREES,
    BevelGearGeometry,
    GearGeometryError,
    SpiralHand,
    bevel_gear_geometry,
    bevel_pair_mesh_interference_warning,
    max_recommended_face_width,
    maximum_receiver_profile_shift_for_mesh_clearance,
    minimum_intruder_profile_shift_for_mesh_clearance,
    pitch_cone_half_angles,
    spiral_build_cost_warning,
    spiral_hand_mismatch_warning,
    thin_hub_warning,
    worst_bevel_pair_mesh_margin_degrees,
)
from app.document.create_plane import resolve_plane_ref
from app.document.extrude import compute_part_bodies
from app.document.models import BevelPairFeature, Part, ResolvedPlane

_MEMBER_LABELS = ("member_1", "member_2")


def _invalid_bevel_pair_parameters(detail: str) -> HTTPException:
    """A bevel pair parameter combination `bevel_math` (or this module
    itself) rejects - mirrors `app.document.bevel._invalid_bevel_parameters`'s
    own convention."""
    return HTTPException(status_code=422, detail={"type": "invalid_bevel_pair_parameters", "detail": detail})


class _MemberBuildFailed(Exception):
    """A plain, guaranteed-cleanly-picklable stand-in for the `HTTPException`
    `_assemble_gear_solid` can raise (`_bevel_failed`, a real but rare OCCT
    construction failure) - `_build_member_solid` catches that and raises
    this instead before it can cross the `ProcessPoolExecutor` worker
    boundary. Not just tidiness: Starlette's `HTTPException.__init__` sets
    `self.args` from `detail` alone, not `status_code` too, so pickling it
    for real cross-process transport (not verified on-device in this
    session - no pythonocc-core available) risks losing `status_code` on
    unpickling or failing outright, surfacing as an opaque broken-process-
    pool error instead of the clean 422 `resolve_bevel_pair_from_bodies`'s
    own callers expect. A single-string-argument exception like this one
    round-trips through the default `Exception.__reduce__` correctly no
    matter what pythonocc-core/Starlette version is running."""


def _bevel_pair_failed(detail: str) -> HTTPException:
    """Mirrors `app.document.bevel._bevel_failed`'s own convention - the
    pair-level wrapper `resolve_bevel_pair_from_bodies` re-raises through
    after catching a worker's own `_MemberBuildFailed`."""
    return HTTPException(status_code=422, detail={"type": "bevel_failed", "detail": detail})


def _tilted_basis(basis: ResolvedPlane, angle: float) -> ResolvedPlane:
    """A `ResolvedPlane` identical to `basis` except with its `normal`
    (and the `y_axis` orthogonal to the rotation axis) rotated by `angle`
    radians about `basis`'s own `x_axis` - CCW-positive/right-hand-rule
    about `x_axis`, the same convention `RevolveFeature.angle` uses
    (`gp_Trsf.SetRotation(gp_Ax1(origin, direction), angle)` rotates
    positively from the axis's own perpendicular "first" direction toward
    its "second" - `app.document.revolve.resolve_revolve_from_bodies`).
    `origin` is unchanged (both members' cone apexes coincide there) and
    `x_axis` itself is unchanged (it's the rotation axis).

    Treating `(x_axis, y_axis, normal)` as a standard right-handed `(x, y,
    z)` frame (`ResolvedPlane`'s own "full right-handed in-plane basis"
    docstring - `normal = x_axis cross y_axis`), rotating by `angle` about
    +x follows the standard rotation-about-x matrix `y' = y*cos(angle) -
    z*sin(angle)`, `z' = y*sin(angle) + z*cos(angle)`: `x cross y' =
    cos(angle)*(x cross y) - sin(angle)*(x cross z) = cos(angle)*normal -
    sin(angle)*(x cross normal)`, and `x cross normal = x cross (x cross
    y) = x*(x . y) - y*(x . x) = -y` (orthonormal), so `x cross y' =
    cos(angle)*normal + sin(angle)*y = z'` - the rotated frame stays
    orthonormal and right-handed, confirming `rotated_normal`/`rotated_
    y_axis` below are still a valid `ResolvedPlane` basis together with
    the unchanged `x_axis`.

    A pure math helper (no OCCT types), unlike `app.document.gear.
    _twisted_basis`/`app.document.gear_chain._positioned_basis` (which
    only ever rotate `x_axis`/`y_axis` *within* the same plane, about the
    normal) - this rotates the normal itself out of the original plane, a
    genuinely different, larger operation `docs/gear-design/11-bevel-
    pair.md` calls out explicitly as the one new piece this workstream
    needed."""
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    nx, ny, nz = basis.normal
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    rotated_y_axis = (cos_a * yx - sin_a * nx, cos_a * yy - sin_a * ny, cos_a * yz - sin_a * nz)
    rotated_normal = (sin_a * yx + cos_a * nx, sin_a * yy + cos_a * ny, sin_a * yz + cos_a * nz)
    return replace(basis, y_axis=rotated_y_axis, normal=rotated_normal)


def _rotated_about_axis(shape: TopoDS_Shape, basis: ResolvedPlane, angle: float) -> TopoDS_Shape:
    """Rigidly rotates `shape` by `angle` radians (CCW/right-hand-rule)
    about `basis`'s own axis (`origin`, `normal`) - the meshing-phase
    alignment this module's own top-level docstring derives (`+pi/2` for
    member 1, `-pi/2 + pi/tooth_count_2` for member 2). Applied to the
    *finished* solid rather than threaded into `app.document.bevel._
    assemble_gear_solid`'s own tooth-placement math - deliberately, so
    `bevel.py`'s construction code stays untouched (this module's own
    "closest precedent" reuse principle), and reuses the same `gp_Trsf`-
    rotation + `BRepBuilderAPI_Transform` pattern `app.document.pattern.
    _circular_instances` already established for rotating a solid about an
    arbitrary axis."""
    ox, oy, oz = basis.origin
    nx, ny, nz = basis.normal
    trsf = gp_Trsf()
    trsf.SetRotation(gp_Ax1(gp_Pnt(ox, oy, oz), gp_Dir(nx, ny, nz)), angle)
    return BRepBuilderAPI_Transform(shape, trsf, True).Shape()


# ---------------------------------------------------------------------------
# Spiral meshing-phase search (`docs/gear-design/12-spiral-bevel-gear.md`'s
# own Spike C, extended here into a real `BevelPairFeature` implementation
# per `13-spiral-bevel-pair.md`) - replaces the fixed `+-pi/2`/`-pi/2 +
# pi/tooth_count_2` phase convention above with a small per-build search
# ONLY once `BevelPairFeature.spiral_angle_degrees != 0.0`; a straight
# (non-spiral) pair is unaffected, byte-for-byte, since Tredgold's own
# construction already makes the fixed convention exactly correct there
# (11-bevel-pair.md's own "meshing phase alignment" docstring) - there is
# nothing for a search to improve on.
#
# Algorithm (Spike C §1/§3, validated against a real parameter sweep
# there): a coarse grid pre-scan across a window sized to HALF the angular
# tooth pitch of the member being searched over (`180 / tooth_count_2`
# degrees - Spike C's own §3 finding that the phase-vs-overlap landscape is
# not globally unimodal past a notch, so a plain wide-window golden-section
# alone is NOT sound), followed by a local golden-section refine within one
# grid step of the best grid point (sound there specifically because Spike
# B's own low-beta stable-optimum finding shows the landscape IS smooth
# within one such narrow band). Each trial is one rigid rotation
# (`_rotated_about_axis`, already-built solids, no rebuild) plus one real
# `BRepAlgoAPI_Common` - "cheap" in the well-behaved regime (Spike C's own
# 1-3s/trial) but genuinely expensive near/past a notch (up to ~16s/trial
# there) - see `resolve_bevel_pair_from_bodies`'s own docstring for how the
# eval budget below and the client's own request timeout were sized against
# that real cost.
_PHASE_SEARCH_GRID_POINTS = 21
_PHASE_SEARCH_REFINE_ITERATIONS = 10
_GOLDEN_RATIO = (math.sqrt(5) - 1) / 2


def _common_overlap_volume(shape_1: TopoDS_Shape, shape_2: TopoDS_Shape) -> float | None:
    """Real `BRepAlgoAPI_Common` overlap volume between two solids, or
    `None` if the boolean itself fails OR (Spike C's own §1 robustness
    finding) `GProp_GProps.Mass()` comes back negative - not numerical
    noise near zero, a real, large-magnitude "no usable signal" reading
    from a geometrically marginal input solid. Both cases are treated
    identically by every caller below: worse than any real reading, never
    a candidate a minimizer can select - the exact guard Spike C's own
    first search implementation lacked, which let a genuinely broken trial
    "win" by looking like negative (better-than-zero) overlap."""
    try:
        common = BRepAlgoAPI_Common(shape_1, shape_2)
        common.Build()
    except Exception:  # noqa: BLE001 - a marginal boolean can raise outright, not just fail IsDone()
        return None
    if not common.IsDone():
        return None
    props = GProp_GProps()
    brepgprop.VolumeProperties(common.Shape(), props)
    mass = props.Mass()
    if mass < 0:
        return None
    return mass


def _golden_section_minimize(f, lo: float, hi: float, iterations: int) -> tuple[float, float]:
    """Minimizes `f` (returning `math.inf` for an invalid/unusable trial,
    per `_common_overlap_volume`'s own guard) over `[lo, hi]` - sound only
    because the caller (`_search_meshing_phase`) already narrowed `[lo,
    hi]` to one coarse-grid step around that scan's own best point, not
    because the search AS A WHOLE is unimodal (`12-spiral-bevel-gear.md`'s
    own Spike C §1: it provably isn't, past a notch)."""
    gr = _GOLDEN_RATIO
    c = hi - gr * (hi - lo)
    d = lo + gr * (hi - lo)
    fc, fd = f(c), f(d)
    for _ in range(iterations):
        if fc < fd:
            hi, d, fd = d, c, fc
            c = hi - gr * (hi - lo)
            fc = f(c)
        else:
            lo, c, fc = c, d, fd
            d = lo + gr * (hi - lo)
            fd = f(d)
    return (c, fc) if fc < fd else (d, fd)


_MARGINAL_SOLID_WARNING_MARKERS = ("fold back on itself", "could not be flattened", "analytic volume disagrees")


def _member_solid_is_marginal(warnings: list[str]) -> bool:
    """Whether `warnings` (one member's own `app.document.bevel._assemble_
    gear_solid` return value, at the DEFAULT fixed phase, before any search
    delta is applied) already flags genuinely marginal geometry - Spike
    C's own §4: "gate the search itself on the underlying per-member
    solid's own validity... before trusting a search result at all, not
    just guard against the negative-value symptom" - a `BRepAlgoAPI_Common`
    reading against an already-marginal solid isn't trustworthy regardless
    of its own sign, so `_search_meshing_phase` is skipped entirely (not
    just guarded per-trial) whenever either member's own baseline solid
    already carries one of these findings."""
    return any(any(marker in w for marker in _MARGINAL_SOLID_WARNING_MARKERS) for w in warnings)


def _search_meshing_phase(
    solid_1: TopoDS_Shape, solid_2_base: TopoDS_Shape, basis_2: ResolvedPlane, tooth_count_2: int
) -> tuple[float, float | None]:
    """Coarse-grid-plus-golden-section-refine search for the extra phase
    delta (radians, applied on top of `solid_2_base`'s own already-baked-in
    fixed-convention rotation) that minimizes real measured overlap between
    `solid_1` and a rotated `solid_2_base` - `docs/gear-design/12-spiral-
    bevel-gear.md`'s own Spike C, go/no-go: GO.

    Window: `+-(180 / tooth_count_2)` degrees - half the angular tooth
    pitch of member 2 (the member being rotated) - Spike C's own §3 finding
    that this scales correctly with tooth count and is confirmed sufficient
    to bracket the true optimum even in a genuinely bad-default-alignment
    case, unlike a fixed absolute window. The grid always includes the
    existing fixed convention itself (delta=0, `_PHASE_SEARCH_GRID_POINTS`
    is odd) as one of its own candidates, so this search can never do worse
    than not searching at all.

    Returns `(best_delta_radians, best_overlap_mm3)`. `best_overlap_mm3` is
    `None` if not even one grid point produced a usable (non-`None`,
    non-negative) `BRepAlgoAPI_Common` reading anywhere in the window - the
    "no usable signal ANYWHERE," not just per-trial, case - in which case
    `best_delta_radians` is `0.0` (the unchanged fixed convention) and the
    caller should surface this as a real, non-blocking warning rather than
    silently trusting an unsearched default."""
    half_pitch = math.radians(180.0 / tooth_count_2)

    def overlap_at(delta: float) -> float | None:
        rotated = _rotated_about_axis(solid_2_base, basis_2, delta)
        return _common_overlap_volume(solid_1, rotated)

    grid_deltas = [
        -half_pitch + 2 * half_pitch * i / (_PHASE_SEARCH_GRID_POINTS - 1)
        for i in range(_PHASE_SEARCH_GRID_POINTS)
    ]
    scored = [(overlap_at(delta), delta) for delta in grid_deltas]
    usable = [(overlap, delta) for overlap, delta in scored if overlap is not None]
    if not usable:
        return 0.0, None
    best_overlap, best_delta = min(usable, key=lambda pair: pair[0])

    step = 2 * half_pitch / (_PHASE_SEARCH_GRID_POINTS - 1)

    def f(delta: float) -> float:
        overlap = overlap_at(delta)
        return overlap if overlap is not None else math.inf

    refined_delta, refined_overlap = _golden_section_minimize(
        f, best_delta - step, best_delta + step, _PHASE_SEARCH_REFINE_ITERATIONS
    )
    if refined_overlap < best_overlap:
        return refined_delta, refined_overlap
    return best_delta, best_overlap


def _shape_to_brep_bytes(shape: TopoDS_Shape) -> bytes:
    """Round-trips `shape` through a real BREP file (`breptools.Write` has
    no in-memory/string overload confirmed available in this session - no
    on-device pythonocc-core to check against, so a real temp file is the
    one guaranteed-available serialization path) - the only way to move a
    `TopoDS_Shape` (a SWIG-wrapped C++ object, not picklable) across a
    `ProcessPoolExecutor` worker boundary. A modest bevel gear solid's own
    BREP text is small (tens to low hundreds of KB) and local disk I/O on
    this app's own Pi 5 target hardware is far cheaper than the minutes-
    scale OCCT construction this is unblocking, so the extra round-trip
    cost here is not the bottleneck this workstream is chasing."""
    fd, path = tempfile.mkstemp(suffix=".brep")
    os.close(fd)
    try:
        breptools.Write(shape, path)
        with open(path, "rb") as f:
            return f.read()
    finally:
        os.unlink(path)


def _shape_from_brep_bytes(data: bytes) -> TopoDS_Shape:
    """Inverse of `_shape_to_brep_bytes` - the main process's own half of
    the round-trip, reconstructing a real `TopoDS_Shape` from a worker
    process's finished solid."""
    fd, path = tempfile.mkstemp(suffix=".brep")
    os.close(fd)
    try:
        with open(path, "wb") as f:
            f.write(data)
        shape = TopoDS_Shape()
        builder = BRep_Builder()
        breptools.Read(shape, path, builder)
        return shape
    finally:
        os.unlink(path)


def _build_member_solid(
    basis: ResolvedPlane,
    geometry: BevelGearGeometry,
    tooth_count: int,
    points_per_flank: int,
    phase_offset: float,
    spiral_angle_degrees: float = 0.0,
    spiral_hand: SpiralHand = SpiralHand.RIGHT,
) -> tuple[bytes, list[str]]:
    """The `ProcessPoolExecutor` worker entry point - module-level (picklable
    by reference) and picklable-only inputs/outputs, per this module's own
    top-level "members build concurrently" docstring. Runs the exact same
    `app.document.bevel._assemble_gear_solid` the old sequential code called
    directly - now spiral-aware (`spiral_angle_degrees`/`spiral_hand`,
    `docs/gear-design/13-spiral-bevel-pair.md`; `0.0` stays the exact
    unmodified straight-bevel path, per that function's own no-op
    guarantee) - then applies the FIXED meshing-phase rotation
    (`_rotated_about_axis`, `phase_offset` radians about this member's own
    axis - see this module's own top-level "meshing phase alignment"
    docstring) before serializing - so `bevel.py`'s construction code
    itself stays untouched. For a spiral pair, this fixed rotation is only
    the SEARCH'S OWN starting point, not the final phase -
    `resolve_bevel_pair_from_bodies` applies `_search_meshing_phase`'s own
    additional delta on top, in the main process, once both members'
    solids are back (a rotation-only refinement needs both solids
    together, which a single worker never has). Any `HTTPException`
    `_assemble_gear_solid` itself raises (`_bevel_failed`, real but rare)
    is caught and re-raised as `_MemberBuildFailed` - see that class's own
    docstring for why."""
    try:
        solid, warnings = _assemble_gear_solid(
            basis,
            geometry,
            tooth_count,
            points_per_flank,
            spiral_angle_degrees=spiral_angle_degrees,
            spiral_hand=spiral_hand,
        )
    except HTTPException as exc:
        raise _MemberBuildFailed(str(exc.detail)) from None
    solid = _rotated_about_axis(solid, basis, phase_offset)
    return _shape_to_brep_bytes(solid), warnings


def _member_geometry(
    *,
    module: float,
    tooth_count: int,
    face_width: float,
    pressure_angle_degrees: float,
    backlash: float,
    profile_shift: float,
    gamma: float,
) -> BevelGearGeometry:
    return bevel_gear_geometry(
        module=module,
        tooth_count=tooth_count,
        face_width=face_width,
        pressure_angle_degrees=pressure_angle_degrees,
        backlash=backlash,
        profile_shift=profile_shift,
        pitch_cone_angle_degrees=math.degrees(gamma),
    )


def resolve_member_profile_shifts(
    *,
    module: float,
    tooth_count_1: int,
    tooth_count_2: int,
    face_width: float,
    pressure_angle_degrees: float,
    shaft_angle_degrees: float,
    backlash: float,
    profile_shift_1: float | None,
    profile_shift_2: float | None,
    gamma_1: float,
    gamma_2: float,
) -> tuple[float, float]:
    """Resolves both members' own `profile_shift` (each `float | None` -
    `None` meaning "auto", `BevelPairMemberSpec`'s own docstring) to
    concrete floats. Takes plain params rather than a whole `BevelPair
    Feature` (mirrors `app.document.rack.rack_outline_points`'s own
    "promote to an explicit-params helper once a second caller needs it"
    refactor - `app.document.router._gear_preview_bevel_pair_response`'s
    preview payload has no `BevelPairFeature` of its own to pass, just the
    same values by different field paths) - `resolve_bevel_pair_from_
    bodies` below and that preview endpoint both call this so they derive
    identical geometry for identical inputs, the same guarantee this
    module's own top-level docstring already establishes for cone angles.

    Two-pass: first builds baseline geometry with any `None` field treated
    as `0.0` (no shift) to find which member's tooth tip is the worse-
    margin "intruder" (`bevel_math.worst_bevel_pair_mesh_margin_degrees`) -
    if that's already clear, neither field is touched. Otherwise, *if* the
    intruder's own `profile_shift` is still `None`, `bevel_math.minimum_
    intruder_profile_shift_for_mesh_clearance` finds the smallest negative
    shift `-X` that clears the margin, and (on-device feedback: a single-
    sided shift alone visibly "looks like a lot of backlash" - the
    intruder's tooth genuinely is that much thinner, with nothing filling
    the gap it leaves) the *receiver* gets the exact complementary `+X`
    too, *if its own `profile_shift` is also still `None`* (an explicit
    receiver value is never auto-adjusted, same "explicit always wins"
    rule as the intruder's own field).

    This complementary shift is not just a cosmetic compromise - it's
    provably backlash-neutral at the pitch line, for any `X`: tooth_
    thickness_at_pitch is `circular_pitch/2 + 2*profile_shift*module*tan
    (pressure_angle) - backlash` (`bevel_gear_geometry`), so shifting the
    intruder by `-X` and the receiver by `+X` changes each one's own
    thickness by the *same* `2*X*module*tan(pressure_angle)` in opposite
    directions. Since `circular_pitch` (hence "gap = circular_pitch - own
    tooth_thickness") is shared (`module` is a pair-level field, identical
    for both members), the receiver's new tooth_thickness lands exactly on
    the intruder's new gap width - the same identity that already holds at
    `X = 0` (unshifted, tooth width equals mating gap width by definition
    of a zero-backlash design) - not an approximation that degrades as `X`
    grows. `minimum_intruder_profile_shift_for_mesh_clearance`'s own search
    already keeps the intruder's own addendum positive; the receiver's
    complementary `+X` is checked two ways before being applied in full: a
    real `GearGeometryError` (e.g. `dedendum <= 0` at extreme `X`) falls
    back to the single-sided shift entirely, and even short of that,
    `maximum_receiver_profile_shift_for_mesh_clearance` caps how much of
    `+X` the receiver actually gets - growing the receiver's own addendum
    can itself flip it into the new intruder in the *opposite* direction
    at a low shared pressure angle (on-device: this project's own default
    pair at 14.5 degrees), so the receiver only gets as much of the
    balancing shift as it can absorb without creating that new problem."""
    baseline_shift_1 = profile_shift_1 if profile_shift_1 is not None else 0.0
    baseline_shift_2 = profile_shift_2 if profile_shift_2 is not None else 0.0
    geometry_kwargs = {
        "module": module,
        "face_width": face_width,
        "pressure_angle_degrees": pressure_angle_degrees,
        "backlash": backlash,
    }
    baseline_geometry_1 = _member_geometry(
        tooth_count=tooth_count_1, profile_shift=baseline_shift_1, gamma=gamma_1, **geometry_kwargs
    )
    baseline_geometry_2 = _member_geometry(
        tooth_count=tooth_count_2, profile_shift=baseline_shift_2, gamma=gamma_2, **geometry_kwargs
    )

    worst_margin, member_2_is_intruder = worst_bevel_pair_mesh_margin_degrees(
        baseline_geometry_1, baseline_geometry_2, shaft_angle_degrees
    )
    if worst_margin >= MESH_MARGIN_SAFETY_BUFFER_DEGREES:
        return baseline_shift_1, baseline_shift_2

    if member_2_is_intruder:
        intruder_shift_input, receiver_shift_input = profile_shift_2, profile_shift_1
        receiver_tooth_count, receiver_gamma = tooth_count_1, gamma_1
        intruder_geometry, receiver_geometry = baseline_geometry_2, baseline_geometry_1
    else:
        intruder_shift_input, receiver_shift_input = profile_shift_1, profile_shift_2
        receiver_tooth_count, receiver_gamma = tooth_count_2, gamma_2
        intruder_geometry, receiver_geometry = baseline_geometry_1, baseline_geometry_2

    if intruder_shift_input is not None:
        # User pinned the intruder's own shift explicitly - can't auto-fix
        # (the warning surfaces this instead).
        return baseline_shift_1, baseline_shift_2

    auto_intruder_shift = minimum_intruder_profile_shift_for_mesh_clearance(
        intruder_geometry, receiver_geometry, shaft_angle_degrees
    )
    if auto_intruder_shift is None:
        return baseline_shift_1, baseline_shift_2

    auto_receiver_shift = receiver_geometry.profile_shift
    if receiver_shift_input is None:
        delta = auto_intruder_shift - intruder_geometry.profile_shift
        candidate_receiver_shift = receiver_geometry.profile_shift - delta
        try:
            _member_geometry(
                tooth_count=receiver_tooth_count, profile_shift=candidate_receiver_shift, gamma=receiver_gamma,
                **geometry_kwargs,
            )
        except GearGeometryError:
            pass  # keep the receiver at its own baseline - single-sided, but still a real fix
        else:
            # The full balanced delta can over-correct at a low shared
            # pressure angle, growing the receiver's own addendum enough
            # to flip *it* into the new intruder in the opposite direction
            # (on-device: the default pair at 14.5deg pressure angle) -
            # cap the receiver's own step at whatever the reverse margin
            # actually tolerates, rather than applying it unconditionally.
            auto_receiver_shift = maximum_receiver_profile_shift_for_mesh_clearance(
                receiver_geometry, intruder_geometry, shaft_angle_degrees, candidate_receiver_shift
            )

    if member_2_is_intruder:
        return auto_receiver_shift, auto_intruder_shift
    return auto_intruder_shift, auto_receiver_shift


def resolve_bevel_pair_from_bodies(
    feature: BevelPairFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> tuple[TopoDS_Shape, list[str]]:
    """The real OCCT compound for one `BevelPairFeature` - both members'
    solids, built by calling `app.document.bevel._assemble_gear_solid`
    once per member against that member's own resolved geometry/basis,
    assembled into one `TopoDS_Compound` for the caller (`app.document.
    extrude.compute_part_bodies`) to register via `_register_solids`
    unchanged - mirrors `app.document.planetary_gear.resolve_planetary_
    from_bodies`'s own shape exactly. Raises a structured `HTTPException`
    rather than returning `None` on any failure - a `BevelPairFeature` has
    no "temporarily has nothing to build" state, same reasoning every
    other gear-family Feature here already uses."""
    if feature.points_per_flank < 2:
        # Mirrors `app.document.bevel.resolve_bevel_gear_from_bodies`'s own
        # identical guard - applies to both members here, built via the same
        # `_assemble_gear_solid` call.
        raise _invalid_bevel_pair_parameters(f"points_per_flank must be >= 2, got {feature.points_per_flank!r}")

    try:
        gamma_1, gamma_2 = pitch_cone_half_angles(
            feature.member_1.tooth_count, feature.member_2.tooth_count, feature.shaft_angle_degrees
        )
    except GearGeometryError as exc:
        raise _invalid_bevel_pair_parameters(str(exc)) from exc

    if feature.face_width <= 0:
        raise _invalid_bevel_pair_parameters(f"face_width must be positive, got {feature.face_width!r}")

    try:
        profile_shift_1, profile_shift_2 = resolve_member_profile_shifts(
            module=feature.module,
            tooth_count_1=feature.member_1.tooth_count,
            tooth_count_2=feature.member_2.tooth_count,
            face_width=feature.face_width,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            shaft_angle_degrees=feature.shaft_angle_degrees,
            backlash=feature.backlash,
            profile_shift_1=feature.member_1.profile_shift,
            profile_shift_2=feature.member_2.profile_shift,
            gamma_1=gamma_1,
            gamma_2=gamma_2,
        )
        geometry_1 = _member_geometry(
            module=feature.module,
            tooth_count=feature.member_1.tooth_count,
            face_width=feature.face_width,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            backlash=feature.backlash,
            profile_shift=profile_shift_1,
            gamma=gamma_1,
        )
        geometry_2 = _member_geometry(
            module=feature.module,
            tooth_count=feature.member_2.tooth_count,
            face_width=feature.face_width,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            backlash=feature.backlash,
            profile_shift=profile_shift_2,
            gamma=gamma_2,
        )
    except GearGeometryError as exc:
        raise _invalid_bevel_pair_parameters(str(exc)) from exc

    warnings: list[str] = []
    for label, geometry in zip(_MEMBER_LABELS, (geometry_1, geometry_2)):
        hub_warning = thin_hub_warning(math.degrees(geometry.pitch_cone_angle))
        if hub_warning:
            warnings.append(f"{label}: {hub_warning}")
        max_face_width = max_recommended_face_width(geometry.cone_distance)
        if feature.face_width > max_face_width:
            warnings.append(
                f"{label}: face_width ({feature.face_width!r}) exceeds the recommended maximum "
                f"({max_face_width!r} = cone_distance / 3) - the tooth thins toward degeneracy near the apex."
            )

    # Pair-level (not per-member) - checks the two members' geometry
    # *against each other*, not either one in isolation, so it lives outside
    # the per-member loop above. See `bevel_pair_mesh_interference_warning`'s
    # own docstring for the on-device measurements this predictive check is
    # calibrated against. `docs/gear-design/13-spiral-bevel-pair.md`'s own
    # Spike C §2/§4: this radial-only system is provably unaffected by
    # spiral (a pure azimuthal rotation) and, once the phase search below
    # resolves meshing phase for a resolvable tooth-count ratio, is the
    # ENTIRE real interference story - no separate tangential margin proxy
    # is needed (that doc's own §5 go/no-go, revising Spike A/B's earlier
    # "required" conclusion).
    mesh_warning = bevel_pair_mesh_interference_warning(geometry_1, geometry_2, feature.shaft_angle_degrees)
    if mesh_warning:
        warnings.append(mesh_warning)

    spiral_hand_1 = _spiral_hand_from_feature(feature.member_1.spiral_hand)
    spiral_hand_2 = _spiral_hand_from_feature(feature.member_2.spiral_hand)
    hand_warning = spiral_hand_mismatch_warning(feature.spiral_angle_degrees, spiral_hand_1, spiral_hand_2)
    if hand_warning:
        warnings.append(hand_warning)
    # `docs/gear-design/12-spiral-bevel-gear.md`'s own Spike C §4 cost
    # finding, extended to the pair: real, decided, non-blocking (item 6 of
    # this workstream's own task scope), not silently absorbed - see this
    # module's own top-level docstring / `resolve_bevel_pair`'s own client-
    # timeout note for the numbers this is based on.
    cost_warning = spiral_build_cost_warning(feature.spiral_angle_degrees)
    if cost_warning:
        warnings.append(
            cost_warning + " Building a spiral Bevel Pair also runs a real per-build meshing-phase "
            "search on top of each member's own build cost, which can itself take several minutes near "
            "a high spiral angle - budget extra time for Create/Save at a high spiral angle."
        )

    basis_1 = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)
    basis_2 = _tilted_basis(basis_1, math.radians(feature.shaft_angle_degrees))

    # Two independent builds, genuinely run in parallel across 2 processes -
    # see this module's own top-level docstring for why a process pool
    # (not threads) and why a BREP round-trip. `max_workers=2`: exactly 2
    # members, always - no reason to spin up more. The trailing angle each
    # call passes is the meshing-phase offset - see this module's own
    # top-level "meshing phase alignment" docstring for the derivation:
    # member 1 gets a tooth exactly on the shared tangency line, member 2
    # gets a gap there instead, so the two interlock rather than collide.
    #
    # `mp_context=spawn`, not the platform-default `fork` on Linux -
    # confirmed on-device this is a real, reproducible deadlock, not a
    # theoretical concern: a *second* `BevelPairFeature` build within the
    # same server process (e.g. two `create_bevel_pair_feature` requests, or
    # simply the real pytest suite's own several bevel-pair tests running in
    # one session) would hang indefinitely with the default `fork` context -
    # reproduced directly (`pytest tests/test_bevel_pair_feature.py -v` gets
    # through the *first* bevel-pair-building test fine, then hangs forever
    # on the *second* one), and confirmed fixed by switching to `spawn`.
    # Root cause: OCCT (a large native C++ library, imported into this same
    # process for the *first* build) is not `fork()`-safe across repeated
    # forks - some global/static state it holds gets left in a state that
    # deadlocks a subsequent fork, the well-documented general hazard
    # Python's own `multiprocessing` docs warn about for "programs that use
    # threads or other complex libraries" under `fork`. `spawn` starts each
    # worker as a genuinely fresh interpreter (re-imports everything, no
    # inherited memory/locks from this process at all) - slower to start per
    # worker (a fresh Python + OCCT import, not free, but a small, bounded
    # cost next to the multi-second-plus builds this is parallelizing), but
    # immune to this whole class of post-fork corruption.
    mp_context = multiprocessing.get_context("spawn")
    with ProcessPoolExecutor(max_workers=2, mp_context=mp_context) as executor:
        future_1 = executor.submit(
            _build_member_solid,
            basis_1,
            geometry_1,
            feature.member_1.tooth_count,
            feature.points_per_flank,
            math.pi / 2,
            feature.spiral_angle_degrees,
            spiral_hand_1,
        )
        future_2 = executor.submit(
            _build_member_solid,
            basis_2,
            geometry_2,
            feature.member_2.tooth_count,
            feature.points_per_flank,
            -math.pi / 2 + math.pi / feature.member_2.tooth_count,
            feature.spiral_angle_degrees,
            spiral_hand_2,
        )
        try:
            solid_1_brep, warnings_1 = future_1.result()
            solid_2_brep, warnings_2 = future_2.result()
        except _MemberBuildFailed as exc:
            raise _bevel_pair_failed(str(exc)) from exc
    solid_1 = _shape_from_brep_bytes(solid_1_brep)
    solid_2 = _shape_from_brep_bytes(solid_2_brep)
    warnings.extend(f"member_1: {w}" for w in warnings_1)
    warnings.extend(f"member_2: {w}" for w in warnings_2)

    # `docs/gear-design/12-spiral-bevel-gear.md`'s own Spike C, wired into
    # real construction here per `13-spiral-bevel-pair.md`'s own go/no-go:
    # the fixed phase convention baked into `solid_1`/`solid_2` above
    # (`_build_member_solid`'s own `phase_offset`) is exactly correct for a
    # straight-bevel pair (Tredgold's own conjugate-action guarantee), but
    # only close-to-correct for a spiral one - a real per-build search over
    # a small additional rotation of `solid_2` finds the true local optimum
    # instead of trusting a convention calibrated for a tooth whose
    # centerline never moves. Skipped entirely (not just at spiral_angle_
    # degrees == 0.0) when either member's own baseline solid is already
    # flagged marginal - a BRepAlgoAPI_Common reading against a marginal
    # solid isn't trustworthy regardless of its own sign (Spike C §4).
    if feature.spiral_angle_degrees != 0.0:
        if _member_solid_is_marginal(warnings_1) or _member_solid_is_marginal(warnings_2):
            warnings.append(
                "the meshing-phase search for this spiral bevel pair was skipped because a member's own "
                "solid is already flagged as geometrically marginal - using the default phase alignment "
                "instead, which may not mesh cleanly."
            )
        else:
            phase_delta, best_overlap = _search_meshing_phase(
                solid_1, solid_2, basis_2, feature.member_2.tooth_count
            )
            if best_overlap is None:
                warnings.append(
                    "could not find any valid meshing-phase alignment for this spiral bevel pair within "
                    "the search window - using the default phase alignment, which may not mesh cleanly."
                )
            elif phase_delta != 0.0:
                solid_2 = _rotated_about_axis(solid_2, basis_2, phase_delta)

    compound = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(compound)
    builder.Add(compound, solid_1)
    builder.Add(compound, solid_2)
    return compound, warnings


def resolve_bevel_pair(
    part: Part, feature: BevelPairFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[TopoDS_Shape, list[str]]:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.planetary_gear.resolve_planetary`'s own self-exclusion
    convention exactly."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_bevel_pair_from_bodies(feature, part, bodies, all_excluded)
