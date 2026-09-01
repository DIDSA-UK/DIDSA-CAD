"""OCCT geometry construction for `PlanetaryGearFeature`
(`docs/gear-design/05-gear-chain-and-planetary.md`) - the OCCT-dependent
half of `app.document.gear_math`'s pure math (`planetary_planet_tooth_
count`/`validate_planetary_assembly`), mirroring the `*_math.py`/OCCT-
construction split every other gear Feature module here keeps
(`docs/gear-design/00-conventions.md`).

Reuses `app.document.gear`'s own real internals directly (`_gear_outline_
wire`/`_gear_face`/`spur_gear_geometry`), same reuse `app.document.
gear_chain` already established for `GearChainFeature`. Static/positioned
only - sun, ring, and every planet are built once and placed, no
kinematics/rotation (per that Feature's own docstring).

**Members build concurrently, in separate processes** (LOD Phase 2 chunk 1,
`docs/lod-strategy/00-status.md` Finding 2 - "the fix `bevel_pair.py`
applied for its 2-member case, never applied here"). `sun_solid`/`ring_
solid`/every `planet_solids[i]` are fully independent builds (different
geometry/basis, no shared mutable state - identical property `app.document.
bevel_pair.resolve_bevel_pair_from_bodies`'s own 2-member pool already
relies on), so `_build_member_solid` runs each in its own OS process via a
`ProcessPoolExecutor`, mirroring that module's pattern exactly: `spawn`
context (OCCT is not fork-safe - see `bevel_pair.py`'s own top-level
docstring for the on-device-reproduced deadlock this avoids), and a real
BREP-bytes round-trip (now `app.document.occt_process_utils`, promoted out
of `bevel_pair.py` this same session so both modules share one
serialization path instead of duplicating it) since a `TopoDS_Shape` itself
can't cross a process boundary.

**Worker count, deliberately NOT `bevel_pair.py`'s own fixed
`max_workers=2`**: a planetary set can have anywhere from `2 + planet_count`
(2 to a handful of planets is typical, but the field has no upper bound)
independent builds to submit, not always exactly 2 - `_planetary_pool_worker_
count` scales with `os.cpu_count()` the same way `bevel_pair.py`'s own
phase-search pool (`_phase_search_worker_count`) already does for its own
variable-sized batch of trials, for the identical reason (more independent
units of work than a hardcoded small constant could ever schedule).

Every build's own validation (`planetary_planet_tooth_count`/`spur_gear_
geometry`/`validate_planetary_assembly`/the `face_width`/`ring_outer_
diameter` checks) stays exactly where it was - synchronous, in the calling
process, before any pool ever opens - only the solid *construction* itself
(`_build_member_solid`) moves to the pool. A worker-raised exception (e.g.
`GearGeometryError` from a race the pre-flight checks above didn't already
catch) is a plain picklable `ValueError` subclass, so it crosses the
`ProcessPoolExecutor` boundary unchanged, same as `bevel_pair.py`'s own
documented `GearGeometryError` cross-process behavior - no `_MemberBuildFailed`-
style wrapper is needed here since `_build_member_solid` itself never
raises an `HTTPException` (unlike `bevel.py`'s `_assemble_gear_solid`)."""

import math
import multiprocessing
import os
from concurrent.futures import ProcessPoolExecutor

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.gp import gp_Vec
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape

from app.document.create_plane import resolve_plane_ref
from app.document.extrude import basis_normal, compute_part_bodies
from app.document.gear import _gear_face, _gear_outline_wire, coarse_gear_radius_from_geometry, coarse_gear_solid
from app.document.gear_chain import _positioned_basis
from app.document.gear_chain_math import ChainMemberKind, meshing_phase_base, propagate_meshing_phase
from app.document.gear_math import (
    GearGeometryError,
    SpurGearGeometry,
    planetary_planet_tooth_count,
    spur_gear_geometry,
    validate_planetary_assembly,
)
from app.document.job_cancellation import CancellationToken, shutdown_pool_quietly
from app.document.job_cancellation import cancellation_scope as _cancellation_scope
from app.document.models import Part, PlanetaryGearFeature, ResolvedPlane
from app.document.occt_process_utils import shape_from_brep_bytes as _shape_from_brep_bytes
from app.document.occt_process_utils import shape_to_brep_bytes as _shape_to_brep_bytes

_POINTS_PER_FLANK = 12


def _invalid_planetary_parameters(detail: str) -> HTTPException:
    """A planetary parameter combination `gear_math` (or this module
    itself) rejects - includes a non-integer/non-positive derived planet
    tooth count, which `00-conventions.md`'s validation-banner exception
    treats as BLOCKING (there is no valid planet gear to draw at all),
    same status code as every other structured-validation-error case in
    this codebase (422) - the blocking behaviour comes from this always
    being raised *before* the Feature is ever persisted (the router calls
    `resolve_planetary` before `part.add_feature`, same "validate before
    persisting" discipline every other gear Feature here already uses),
    not from a special status code."""
    return HTTPException(status_code=422, detail={"type": "invalid_planetary_parameters", "detail": detail})


def _build_member_solid(
    basis: ResolvedPlane, geometry: SpurGearGeometry, is_internal: bool, outer_diameter: float | None, face_width: float
) -> TopoDS_Shape:
    wire, _root_corner_vertices = _gear_outline_wire(basis, geometry, _POINTS_PER_FLANK)
    face = _gear_face(basis, is_internal, outer_diameter, geometry, wire)
    normal = basis_normal(basis)
    prism_vector = gp_Vec(normal.X(), normal.Y(), normal.Z()).Multiplied(face_width)
    return BRepPrimAPI_MakePrism(face, prism_vector).Shape()


class _MemberBuildFailed(Exception):
    """A plain, guaranteed-cleanly-picklable stand-in for the `HTTPException`
    `_gear_face`'s own internal-gear branch can raise (`outer_diameter` not
    exceeding the tooth profile's own dedendum reach) - mirrors `app.
    document.bevel_pair._MemberBuildFailed`'s own docstring/reasoning
    exactly (an `HTTPException` risks losing `status_code` across a real
    `spawn`-context pickle round-trip). In practice this specific branch is
    already unreachable for the ring member by the time `_build_member_
    solid_worker` runs it - `resolve_planetary_from_bodies`'s own pre-flight
    `ring_outer_diameter` check below enforces the identical condition
    first, synchronously, before any pool ever opens - kept here as the
    same defense-in-depth `bevel_pair.py` already establishes for its own
    analogous worker, not because a live code path reaches it today."""


def _build_member_solid_worker(
    basis: ResolvedPlane, geometry: SpurGearGeometry, is_internal: bool, outer_diameter: float | None, face_width: float
) -> bytes:
    """The `ProcessPoolExecutor` worker entry point - module-level
    (picklable by reference), picklable-only inputs (`ResolvedPlane`/
    `SpurGearGeometry` are both plain dataclasses of primitives), BREP-bytes
    output (a `TopoDS_Shape` itself can't cross a process boundary) -
    mirrors `app.document.bevel_pair._build_member_solid`'s own worker
    shape. Runs the exact same `_build_member_solid` the old sequential code
    called directly, just inside a worker process now. A `GearGeometryError`
    this module's own pre-flight checks below didn't already catch is a
    plain, cleanly-picklable exception that crosses the `ProcessPoolExecutor`
    boundary and surfaces from `Future.result()` unchanged, same as `app.
    document.bevel_pair`'s own documented cross-process `GearGeometryError`
    behavior; any `HTTPException` `_gear_face` itself raises is caught and
    re-raised as `_MemberBuildFailed` instead, for the same reason that
    class's own docstring gives."""
    try:
        solid = _build_member_solid(basis, geometry, is_internal, outer_diameter, face_width)
    except HTTPException as exc:
        raise _MemberBuildFailed(str(exc.detail)) from None
    return _shape_to_brep_bytes(solid)


def _planetary_pool_worker_count(member_count: int) -> int:
    """Worker count for the sun/ring/planets pool - deliberately NOT `app.
    document.bevel_pair`'s own fixed `max_workers=2` (that module always
    has exactly 2 members; a planetary set has `2 + planet_count`, which
    varies), so this scales with `os.cpu_count()` the same way that
    module's own variable-sized phase-search pool
    (`_phase_search_worker_count`) already does, for the identical reason.
    `os.cpu_count() - 1` leaves one core free for the phone's own UI/
    Termux/proot overhead while the pool runs (same judgment call that
    function's own docstring already makes, not independently
    on-device-validated here); floored at 2 (never worth a single-worker
    "pool") and capped at `member_count` (no reason to spin up more workers
    than there are independent builds to submit)."""
    cpu_count = os.cpu_count() or 2
    return max(2, min(cpu_count - 1, member_count))


def resolve_planetary_from_bodies(
    feature: PlanetaryGearFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
    cancellation: CancellationToken | None = None,
) -> TopoDS_Shape:
    """The real OCCT compound for one `PlanetaryGearFeature` - sun (centre),
    ring (concentric with the sun), and `feature.planet_count` planets
    (evenly spaced around the sun at the assembly's own orbit radius),
    assembled into one `TopoDS_Compound` the same way `app.document.
    gear_chain.resolve_gear_chain_from_bodies` does, for the caller
    (`app.document.extrude.compute_part_bodies`) to register via
    `_register_solids` unchanged. Raises a structured `HTTPException`
    rather than returning `None` on any failure - a `PlanetaryGearFeature`
    has no "temporarily has nothing to build" state, same reasoning
    `GearFeature`/`GearChainFeature` already use.

    `cancellation` (LOD Phase 2 chunk 3, `app.document.job_cancellation`) is
    `None` for every synchronous caller (`resolve_planetary`'s own default)
    - a pure no-op in that case, byte-for-byte the same behavior as before
    job-mode existed for this Feature type. `app.document.jobs`'s own job
    runner is the only caller that ever passes a real `CancellationToken`,
    threaded down into the one `ProcessPoolExecutor` this function can open
    (below) - mirrors `app.document.bevel_pair.resolve_bevel_pair_from_
    bodies`'s own identical parameter/reasoning exactly, sharing the same
    `cancellation_scope` hook rather than duplicating it."""
    try:
        planet_tooth_count = planetary_planet_tooth_count(feature.sun_tooth_count, feature.ring_tooth_count)
    except GearGeometryError as exc:
        raise _invalid_planetary_parameters(str(exc)) from exc

    try:
        sun_geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=feature.sun_tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            is_internal=False,
        )
        ring_geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=feature.ring_tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            is_internal=True,
        )
        planet_geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=planet_tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            is_internal=False,
        )
    except GearGeometryError as exc:
        raise _invalid_planetary_parameters(str(exc)) from exc

    try:
        validate_planetary_assembly(
            sun_teeth=feature.sun_tooth_count,
            ring_teeth=feature.ring_tooth_count,
            planet_count=feature.planet_count,
            planet_pitch_radius=planet_geometry.pitch_radius,
            planet_addendum_radius=planet_geometry.addendum_radius,
        )
    except GearGeometryError as exc:
        raise _invalid_planetary_parameters(str(exc)) from exc

    if feature.face_width <= 0:
        raise _invalid_planetary_parameters(f"face_width must be positive, got {feature.face_width!r}")
    if feature.ring_outer_diameter / 2 <= ring_geometry.dedendum_radius:
        raise _invalid_planetary_parameters(
            f"ring_outer_diameter ({feature.ring_outer_diameter!r}) must exceed the ring's own tooth "
            f"profile outer reach (dedendum diameter {ring_geometry.dedendum_radius * 2!r})"
        )

    basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)

    # Meshing-phase alignment (`app.document.bevel_pair`'s own "Meshing
    # phase alignment" fix, generalized here the same way `app.document.
    # gear_chain` generalizes it to a sequential chain - see that module's
    # own module-level note for the real-OCCT counterexample that ruled
    # out a naive, uncorrected local rule). The sun sits at this
    # assembly's own zero-reference (rotation 0.0, arbitrary but fixed -
    # `app.document.gear_chain`'s stage-0 convention, reused here since a
    # planetary set has no "stage 0" of its own, only a sun to anchor on).
    # Each planet's rotation is then fully determined by its own meshing
    # with the sun (`meshing_phase_base` + `propagate_meshing_phase`, sun
    # as predecessor, `phi` - this planet's own orbital azimuth - as the
    # junction's `incoming_direction`) - a planet has exactly one rotational
    # degree of freedom and the sun-mesh constraint alone fully consumes
    # it, so there is nothing left to independently choose to also satisfy
    # the ring - the ring side is instead solved for, once, from planet 0's
    # own resulting rotation (treated as predecessor, the ring as
    # successor, at the ring's own azimuth `phi_0 + pi` - directly opposite
    # planet 0's own azimuth, since the ring is concentric with the sun).
    # `validate_planetary_assembly`'s already-enforced assembly condition
    # (`(sun_teeth + ring_teeth) % planet_count == 0`) is exactly the
    # condition under which this SAME ring rotation also correctly meshes
    # every *other* planet, not just planet 0 - confirmed by direct real-
    # OCCT measurement (0.000000 mm^3 sun/ring overlap against all of 4
    # evenly-spaced planets at once, for tooth counts clear of the
    # low-tooth-count "involute tip interference" limitation documented in
    # `app.document.gear_chain_math`'s own module note - not re-derived
    # symbolically here, since the existing assembly-condition check is
    # already the standard textbook criterion for this).
    sun_rotation = 0.0

    planet_0_azimuth = 0.0
    planet_0_base = meshing_phase_base(planet_tooth_count, ChainMemberKind.EXTERNAL, planet_0_azimuth)
    planet_0_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL,
        sun_geometry.pitch_radius,
        sun_rotation,
        ChainMemberKind.EXTERNAL,
        planet_geometry.pitch_radius,
        planet_0_azimuth,
        planet_0_base,
    )
    ring_azimuth = planet_0_azimuth + math.pi
    ring_base = meshing_phase_base(feature.ring_tooth_count, ChainMemberKind.EXTERNAL, ring_azimuth)
    ring_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL,
        planet_geometry.pitch_radius,
        planet_0_rotation,
        ChainMemberKind.INTERNAL,
        ring_geometry.pitch_radius,
        ring_azimuth,
        ring_base,
    )
    ring_basis = _positioned_basis(basis, 0.0, 0.0, rotation=ring_rotation)

    orbit_radius = sun_geometry.pitch_radius + planet_geometry.pitch_radius
    planet_bases = []
    for i in range(feature.planet_count):
        phi = 2 * math.pi * i / feature.planet_count
        planet_base = meshing_phase_base(planet_tooth_count, ChainMemberKind.EXTERNAL, phi)
        planet_rotation = propagate_meshing_phase(
            ChainMemberKind.EXTERNAL,
            sun_geometry.pitch_radius,
            sun_rotation,
            ChainMemberKind.EXTERNAL,
            planet_geometry.pitch_radius,
            phi,
            planet_base,
        )
        px, py = orbit_radius * math.cos(phi), orbit_radius * math.sin(phi)
        planet_bases.append(_positioned_basis(basis, px, py, rotation=planet_rotation))

    # Every member build is independent (different geometry/basis, no
    # shared mutable state) - submitted to a real `ProcessPoolExecutor` for
    # genuine multi-core parallelism, mirroring `app.document.bevel_pair.
    # resolve_bevel_pair_from_bodies`'s own pooling exactly (this module's
    # own top-level docstring has the full reasoning: `spawn` context,
    # BREP-bytes round-trip, why a process pool rather than threads). Only
    # the solid *construction* moves to the pool - every validation check
    # above already ran, synchronously, before this point, unchanged.
    mp_context = multiprocessing.get_context("spawn")
    member_count = 2 + feature.planet_count
    executor = ProcessPoolExecutor(max_workers=_planetary_pool_worker_count(member_count), mp_context=mp_context)
    try:
        with _cancellation_scope(cancellation, executor):
            sun_future = executor.submit(_build_member_solid_worker, basis, sun_geometry, False, None, feature.face_width)
            ring_future = executor.submit(
                _build_member_solid_worker, ring_basis, ring_geometry, True, feature.ring_outer_diameter, feature.face_width
            )
            planet_futures = [
                executor.submit(_build_member_solid_worker, planet_basis, planet_geometry, False, None, feature.face_width)
                for planet_basis in planet_bases
            ]
            try:
                sun_solid = _shape_from_brep_bytes(sun_future.result())
                ring_solid = _shape_from_brep_bytes(ring_future.result())
                planet_solids = [_shape_from_brep_bytes(future.result()) for future in planet_futures]
            except _MemberBuildFailed as exc:
                raise _invalid_planetary_parameters(str(exc)) from exc
    finally:
        # `shutdown_pool_quietly`, not a plain `with executor:` - see that
        # function's own docstring for the real, on-device-confirmed
        # concurrent-shutdown race with `_kill_pool_workers`'s own call this
        # swallows (found via this exact module's own real cancellation
        # test, LOD Phase 2 chunk 3).
        shutdown_pool_quietly(executor)

    compound = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(compound)
    for solid in (sun_solid, ring_solid, *planet_solids):
        builder.Add(compound, solid)
    return compound


def resolve_planetary(
    part: Part,
    feature: PlanetaryGearFeature,
    excluded_feature_ids: frozenset[str] = frozenset(),
    cancellation: CancellationToken | None = None,
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.gear_chain.resolve_gear_chain`'s own self-exclusion
    convention exactly. `cancellation` defaults to `None` (every synchronous
    caller) - only `app.document.jobs`'s own job runner ever passes a real
    `CancellationToken`."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_planetary_from_bodies(feature, part, bodies, all_excluded, cancellation)


# ---------------------------------------------------------------------------
# Coarse (LOD) construction - `docs/lod-strategy/01-design.md` SS3: reuses
# `app.document.gear`'s own coarse cylinder builder for the sun, ring, and
# every planet - real tooth construction is never built for any member.
# Skips the real construction's own meshing-phase rotation math
# (`meshing_phase_base`/`propagate_meshing_phase`) entirely - a plain
# cylinder is rotationally symmetric about its own axis, so a member's
# rotation has no visual effect on its coarse stand-in (unlike the real,
# toothed solid, where getting that rotation right is the entire point of
# that machinery); only each member's *position* (sun at the origin, ring
# concentric with it, each planet at its own orbital `(x, y)`) still
# matters and is preserved exactly. Still runs `planetary_planet_tooth_
# count`/`validate_planetary_assembly` (cheap pure-Python structural
# checks - there is no valid assembly to draw at all, coarse or full, if
# these fail, per `PlanetaryGearFeature`'s own "no valid planet gear" BLOCKING
# treatment). **Never persisted, never enters the Feature graph** - see
# `app.document.gear`'s own matching section for the full invariant.


def resolve_planetary_coarse_from_bodies(
    feature: PlanetaryGearFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The coarse stand-in for one `PlanetaryGearFeature` - sun/ring/every
    planet, each a plain cylinder (`app.document.gear.coarse_gear_solid`),
    positioned at the same real `(x, y)` orbital locations `resolve_
    planetary_from_bodies` uses (rotation omitted - see this section's own
    top-level docstring for why a cylinder never needs it)."""
    try:
        planet_tooth_count = planetary_planet_tooth_count(feature.sun_tooth_count, feature.ring_tooth_count)
    except GearGeometryError as exc:
        raise _invalid_planetary_parameters(str(exc)) from exc

    try:
        sun_geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=feature.sun_tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            is_internal=False,
        )
        ring_geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=feature.ring_tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            is_internal=True,
        )
        planet_geometry = spur_gear_geometry(
            module=feature.module,
            tooth_count=planet_tooth_count,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            is_internal=False,
        )
    except GearGeometryError as exc:
        raise _invalid_planetary_parameters(str(exc)) from exc

    try:
        validate_planetary_assembly(
            sun_teeth=feature.sun_tooth_count,
            ring_teeth=feature.ring_tooth_count,
            planet_count=feature.planet_count,
            planet_pitch_radius=planet_geometry.pitch_radius,
            planet_addendum_radius=planet_geometry.addendum_radius,
        )
    except GearGeometryError as exc:
        raise _invalid_planetary_parameters(str(exc)) from exc

    if feature.face_width <= 0:
        raise _invalid_planetary_parameters(f"face_width must be positive, got {feature.face_width!r}")
    if feature.ring_outer_diameter / 2 <= ring_geometry.dedendum_radius:
        raise _invalid_planetary_parameters(
            f"ring_outer_diameter ({feature.ring_outer_diameter!r}) must exceed the ring's own tooth "
            f"profile outer reach (dedendum diameter {ring_geometry.dedendum_radius * 2!r})"
        )

    basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)

    sun_radius = coarse_gear_radius_from_geometry(False, None, sun_geometry)
    sun_solid = coarse_gear_solid(basis, sun_radius, feature.face_width)

    ring_radius = coarse_gear_radius_from_geometry(True, feature.ring_outer_diameter, ring_geometry)
    ring_solid = coarse_gear_solid(basis, ring_radius, feature.face_width)

    planet_radius = coarse_gear_radius_from_geometry(False, None, planet_geometry)
    orbit_radius = sun_geometry.pitch_radius + planet_geometry.pitch_radius
    planet_solids = []
    for i in range(feature.planet_count):
        phi = 2 * math.pi * i / feature.planet_count
        px, py = orbit_radius * math.cos(phi), orbit_radius * math.sin(phi)
        planet_basis = _positioned_basis(basis, px, py)
        planet_solids.append(coarse_gear_solid(planet_basis, planet_radius, feature.face_width))

    compound = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(compound)
    for solid in (sun_solid, ring_solid, *planet_solids):
        builder.Add(compound, solid)
    return compound


def resolve_planetary_coarse(
    part: Part, feature: PlanetaryGearFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for a not-yet-created `PlanetaryGearFeature`
    payload (the coarse-preview endpoint) or for `tier=coarse` mesh serving
    - mirrors `resolve_planetary`'s own self-exclusion convention exactly."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_planetary_coarse_from_bodies(feature, part, bodies, all_excluded)
