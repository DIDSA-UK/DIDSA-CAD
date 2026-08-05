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
from app.document.gear import _gear_face, _gear_outline_wire
from app.document.gear_chain import _positioned_basis
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

    sun_solid = _build_member_solid(basis, sun_geometry, False, None, feature.face_width)
    ring_solid = _build_member_solid(basis, ring_geometry, True, feature.ring_outer_diameter, feature.face_width)

    orbit_radius = sun_geometry.pitch_radius + planet_geometry.pitch_radius
    planet_solids = []
    for i in range(feature.planet_count):
        angle = 2 * math.pi * i / feature.planet_count
        px, py = orbit_radius * math.cos(angle), orbit_radius * math.sin(angle)
        planet_basis = _positioned_basis(basis, px, py)
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
