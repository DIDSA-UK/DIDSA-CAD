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

**No interference checking at all** - explicit simplification per `11-bevel-
pair.md`: with exactly two members that are always the intended meshing
pair, there is no "non-adjacent stage" case for `GearChainFeature`'s own
interference machinery to apply to.

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
OCCT types, so they pickle across the process boundary for free."""

import math
import multiprocessing
import os
import tempfile
from concurrent.futures import ProcessPoolExecutor
from dataclasses import replace

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.BRepTools import breptools
from OCC.Core.gp import gp_Ax1, gp_Dir, gp_Pnt, gp_Trsf
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape

from app.document.bevel import _assemble_gear_solid
from app.document.bevel_math import (
    BevelGearGeometry,
    GearGeometryError,
    bevel_gear_geometry,
    bevel_pair_mesh_interference_warning,
    max_recommended_face_width,
    pitch_cone_half_angles,
    thin_hub_warning,
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
    basis: ResolvedPlane, geometry: BevelGearGeometry, tooth_count: int, points_per_flank: int, phase_offset: float
) -> tuple[bytes, list[str]]:
    """The `ProcessPoolExecutor` worker entry point - module-level (picklable
    by reference) and picklable-only inputs/outputs, per this module's own
    top-level "members build concurrently" docstring. Runs the exact same
    `app.document.bevel._assemble_gear_solid` the old sequential code called
    directly, then applies the meshing-phase rotation (`_rotated_about_
    axis`, `phase_offset` radians about this member's own axis - see this
    module's own top-level "meshing phase alignment" docstring) before
    serializing - so `bevel.py`'s construction code itself stays untouched.
    Any `HTTPException` `_assemble_gear_solid` itself raises (`_bevel_
    failed`, real but rare) is caught and re-raised as `_MemberBuildFailed`
    - see that class's own docstring for why."""
    try:
        solid, warnings = _assemble_gear_solid(basis, geometry, tooth_count, points_per_flank)
    except HTTPException as exc:
        raise _MemberBuildFailed(str(exc.detail)) from None
    solid = _rotated_about_axis(solid, basis, phase_offset)
    return _shape_to_brep_bytes(solid), warnings


def _member_geometry(feature: BevelPairFeature, tooth_count: int, profile_shift: float, gamma: float) -> BevelGearGeometry:
    return bevel_gear_geometry(
        module=feature.module,
        tooth_count=tooth_count,
        face_width=feature.face_width,
        pressure_angle_degrees=feature.pressure_angle_degrees,
        backlash=feature.backlash,
        profile_shift=profile_shift,
        pitch_cone_angle_degrees=math.degrees(gamma),
    )


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
        geometry_1 = _member_geometry(feature, feature.member_1.tooth_count, feature.member_1.profile_shift, gamma_1)
        geometry_2 = _member_geometry(feature, feature.member_2.tooth_count, feature.member_2.profile_shift, gamma_2)
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
    # calibrated against.
    mesh_warning = bevel_pair_mesh_interference_warning(geometry_1, geometry_2, feature.shaft_angle_degrees)
    if mesh_warning:
        warnings.append(mesh_warning)

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
        )
        future_2 = executor.submit(
            _build_member_solid,
            basis_2,
            geometry_2,
            feature.member_2.tooth_count,
            feature.points_per_flank,
            -math.pi / 2 + math.pi / feature.member_2.tooth_count,
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
