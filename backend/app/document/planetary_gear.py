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
kinematics/rotation (per that Feature's own docstring)."""

import math

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
from app.document.models import Part, PlanetaryGearFeature, ResolvedPlane

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


def resolve_planetary_from_bodies(
    feature: PlanetaryGearFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
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
    `GearFeature`/`GearChainFeature` already use."""
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
    sun_solid = _build_member_solid(basis, sun_geometry, False, None, feature.face_width)

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
    ring_solid = _build_member_solid(ring_basis, ring_geometry, True, feature.ring_outer_diameter, feature.face_width)

    orbit_radius = sun_geometry.pitch_radius + planet_geometry.pitch_radius
    planet_solids = []
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
        planet_basis = _positioned_basis(basis, px, py, rotation=planet_rotation)
        planet_solids.append(_build_member_solid(planet_basis, planet_geometry, False, None, feature.face_width))

    compound = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(compound)
    for solid in (sun_solid, ring_solid, *planet_solids):
        builder.Add(compound, solid)
    return compound


def resolve_planetary(
    part: Part, feature: PlanetaryGearFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.gear_chain.resolve_gear_chain`'s own self-exclusion
    convention exactly."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_planetary_from_bodies(feature, part, bodies, all_excluded)


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
