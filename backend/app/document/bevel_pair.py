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
interference machinery to apply to."""

import math
from dataclasses import replace

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape

from app.document.bevel import _assemble_gear_solid
from app.document.bevel_math import (
    BevelGearGeometry,
    GearGeometryError,
    bevel_gear_geometry,
    max_recommended_face_width,
    pitch_cone_half_angles,
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
        max_face_width = max_recommended_face_width(geometry.cone_distance)
        if feature.face_width > max_face_width:
            warnings.append(
                f"{label}: face_width ({feature.face_width!r}) exceeds the recommended maximum "
                f"({max_face_width!r} = cone_distance / 3) - the tooth thins toward degeneracy near the apex."
            )

    basis_1 = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)
    basis_2 = _tilted_basis(basis_1, math.radians(feature.shaft_angle_degrees))

    solid_1, warnings_1 = _assemble_gear_solid(
        basis_1, geometry_1, feature.member_1.tooth_count, feature.points_per_flank
    )
    solid_2, warnings_2 = _assemble_gear_solid(
        basis_2, geometry_2, feature.member_2.tooth_count, feature.points_per_flank
    )
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
