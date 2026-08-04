"""Pure-Python involute gear geometry - no OCCT dependency, mirroring the
OCCT-free/OCCT-dependent module split `docs/gear-design/00-conventions.md`
describes (same split as `app.document.mesh_import` vs
`app.document.import_geometry`, and `app.document.sweep`'s own
pure-Python path-resolution helpers vs its OCCT construction). This repo's
dev sandbox has never had `pythonocc-core` installed, so keeping this
math OCCT-free means it's directly unit-testable here; only the eventual
OCCT curve/solid construction (`app.document.gear`, Workstream 2 -
`docs/gear-design/02-gear-feature.md`) needs real CI to verify.

Implements `docs/gear-design/01-gear-math-core.md`'s spec: involute
sampling, spur/internal gear dimensions, rack tooth geometry, pair
center-distance formulas, and planetary assembly validation. Formulas
follow standard metric-module involute gear conventions (AGMA/ISO 21771)
- verified against known reference values in
`backend/tests/test_gear_math.py`, not just "it runs" (see that
workstream doc's own test requirement).

Every domain failure here raises `GearGeometryError` (a plain `ValueError`
subclass) - mirrors `app.sketch.models.NoIntersectionFoundError`'s own
pattern. Converting to a structured HTTP error is the router layer's job
(Workstream 2+), not this module's - this module has no FastAPI
dependency at all.
"""

import math
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class GearGeometryError(ValueError):
    """A gear parameter combination that doesn't yield valid, meshable
    geometry - fail closed rather than silently producing a non-meshing or
    self-colliding model, per `01-gear-math-core.md`."""


# ---------------------------------------------------------------------------
# Involute-of-a-circle primitives
# ---------------------------------------------------------------------------


def involute_point(base_radius: float, roll_angle: float) -> tuple[float, float]:
    """One point on the involute-of-a-circle at roll angle `t` (radians),
    in the local frame where the involute starts at `(base_radius, 0)` and
    unwinds counter-clockwise as `t` increases: the standard parametrization
    `x = r_b(cos t + t sin t)`, `y = r_b(sin t - t cos t)` named in
    `01-gear-math-core.md`."""
    cos_t = math.cos(roll_angle)
    sin_t = math.sin(roll_angle)
    return (
        base_radius * (cos_t + roll_angle * sin_t),
        base_radius * (sin_t - roll_angle * cos_t),
    )


def involute_roll_angle_at_radius(base_radius: float, radius: float) -> float:
    """Inverse of the involute's own radius function `r(t) = r_b * sqrt(1 +
    t^2)` -> `t = sqrt((r / r_b)^2 - 1)`. `radius` must be at or outside the
    base circle - the involute is only defined outside it (the string
    hasn't started unwinding yet at `radius < base_radius`)."""
    if radius < base_radius:
        raise GearGeometryError(
            f"radius {radius!r} is inside the base circle (radius {base_radius!r}) - "
            "not reachable by the involute"
        )
    ratio = radius / base_radius
    return math.sqrt(max(ratio * ratio - 1.0, 0.0))


def involute_function(pressure_angle: float) -> float:
    """The standard "involute function" `inv(a) = tan(a) - a` - the polar
    angle (radians) from the involute's own start direction (`t=0`, on the
    base circle) to the point where the involute crosses the circle at
    which the local pressure angle equals `pressure_angle`. Used to place a
    tooth's centerline relative to where its flank's involute construction
    "starts" - see `_flank_start_offset_angle`."""
    return math.tan(pressure_angle) - pressure_angle


def sample_involute_flank(
    base_radius: float, start_radius: float, end_radius: float, point_count: int = 12
) -> list[tuple[float, float]]:
    """Evenly-spaced-by-roll-angle sample of one involute flank between
    `start_radius` and `end_radius` (order preserved - the returned list
    runs from `start_radius` to `end_radius`, not necessarily low-to-high).
    `point_count` defaults to the middle of `01-gear-math-core.md`'s own
    "~10-20 sampled points per flank" target."""
    if point_count < 2:
        raise GearGeometryError(f"point_count must be >= 2, got {point_count}")
    t_start = involute_roll_angle_at_radius(base_radius, start_radius)
    t_end = involute_roll_angle_at_radius(base_radius, end_radius)
    return [
        involute_point(base_radius, t_start + (t_end - t_start) * i / (point_count - 1))
        for i in range(point_count)
    ]


# ---------------------------------------------------------------------------
# Spur gear (external or internal) dimensions
# ---------------------------------------------------------------------------


@dataclass
class SpurGearGeometry:
    """Fully-resolved dimensions for one involute spur gear (external or
    internal), derived from module/tooth-count/pressure-angle/profile-shift.
    All linear dimensions in mm; `pressure_angle` in radians (every other
    angle-shaped field too, unless named `*_degrees`)."""

    module: float
    tooth_count: int
    pressure_angle: float
    profile_shift: float
    backlash: float
    is_internal: bool
    pitch_radius: float
    base_radius: float
    addendum_radius: float
    dedendum_radius: float
    tooth_thickness_at_pitch: float
    root_fillet_radius: float


def spur_gear_geometry(
    *,
    module: float,
    tooth_count: int,
    pressure_angle_degrees: float = 20.0,
    profile_shift: float = 0.0,
    backlash: float = 0.0,
    addendum_coefficient: float = 1.0,
    dedendum_coefficient: float = 1.25,
    root_fillet_radius: float = 0.0,
    is_internal: bool = False,
) -> SpurGearGeometry:
    """Resolve a spur gear's defining circles + pitch-circle tooth
    thickness from its generative parameters. `addendum_coefficient`/
    `dedendum_coefficient` default to the standard full-depth values
    (1.0 / 1.25, i.e. 0.25 module clearance) - the same convention nearly
    every metric involute gear reference table assumes.

    For an internal gear, addendum points *inward* (toward the centre) and
    dedendum points *outward* (toward the rim) - the sign of that
    inversion is `is_internal`'s only effect here; `02-gear-feature.md`'s
    OCCT construction is what turns this into an annulus rather than a
    disc."""
    if module <= 0:
        raise GearGeometryError(f"module must be positive, got {module!r}")
    if tooth_count < 4:
        raise GearGeometryError(f"tooth_count must be >= 4 to form a gear, got {tooth_count!r}")
    if not (0 < pressure_angle_degrees < 90):
        raise GearGeometryError(f"pressure_angle_degrees must be in (0, 90), got {pressure_angle_degrees!r}")
    if backlash < 0:
        raise GearGeometryError(f"backlash must be >= 0, got {backlash!r}")

    pressure_angle = math.radians(pressure_angle_degrees)
    pitch_radius = module * tooth_count / 2
    base_radius = pitch_radius * math.cos(pressure_angle)

    addendum_height = module * (addendum_coefficient + profile_shift)
    dedendum_height = module * (dedendum_coefficient - profile_shift)
    sign = -1.0 if is_internal else 1.0
    addendum_radius = pitch_radius + sign * addendum_height
    dedendum_radius = pitch_radius - sign * dedendum_height

    if not is_internal and dedendum_radius <= 0:
        raise GearGeometryError(
            f"dedendum_radius {dedendum_radius!r} is non-positive - module {module!r}/tooth_count "
            f"{tooth_count!r}/profile_shift {profile_shift!r} don't form a valid gear"
        )
    if dedendum_radius <= base_radius and not is_internal:
        # Root inside the base circle is common and fine (the root-to-base
        # flank segment isn't a pure involute there - 02-gear-feature.md's
        # OCCT construction handles that transition) - only a genuinely
        # non-positive radius above is a hard failure.
        pass

    circular_pitch = math.pi * module
    tooth_thickness_at_pitch = (
        circular_pitch / 2 + 2 * profile_shift * module * math.tan(pressure_angle) - backlash
    )
    if tooth_thickness_at_pitch <= 0:
        raise GearGeometryError(
            f"tooth_thickness_at_pitch {tooth_thickness_at_pitch!r} is non-positive - "
            f"backlash {backlash!r} is too large for module {module!r}"
        )
    angular_tooth_thickness = tooth_thickness_at_pitch / pitch_radius
    if angular_tooth_thickness >= 2 * math.pi / tooth_count:
        raise GearGeometryError(
            "tooth_thickness_at_pitch exceeds the space available per tooth - "
            f"tooth_count {tooth_count!r} is too low for module {module!r}/profile_shift {profile_shift!r}"
        )

    return SpurGearGeometry(
        module=module,
        tooth_count=tooth_count,
        pressure_angle=pressure_angle,
        profile_shift=profile_shift,
        backlash=backlash,
        is_internal=is_internal,
        pitch_radius=pitch_radius,
        base_radius=base_radius,
        addendum_radius=addendum_radius,
        dedendum_radius=dedendum_radius,
        tooth_thickness_at_pitch=tooth_thickness_at_pitch,
        root_fillet_radius=root_fillet_radius,
    )


def minimum_tooth_count_without_undercut(
    pressure_angle_degrees: float = 20.0,
    profile_shift: float = 0.0,
    addendum_coefficient: float = 1.0,
) -> float:
    """Standard undercut-avoidance formula: `z_min = 2 * (h_a* - x) /
    sin^2(a)`. A gear cut below this tooth count has its addendum-cutter
    path dig into the flank below the base circle (undercut) - not a hard
    failure (an undercut gear still meshes, just weaker at the root), so
    callers should use this for the non-blocking validation-banner warning
    per `00-conventions.md`, not to reject creation."""
    pressure_angle = math.radians(pressure_angle_degrees)
    return 2 * (addendum_coefficient - profile_shift) / (math.sin(pressure_angle) ** 2)


def _flank_start_offset_angle(geometry: SpurGearGeometry) -> float:
    """The angle (radians) from a tooth's own centerline to the point on
    the base circle where that flank's involute construction "starts"
    (`t=0`) - half the tooth's angular thickness at the pitch circle, plus
    `involute_function` evaluated at the pitch radius's own local pressure
    angle (which is exactly `geometry.pressure_angle` by definition of the
    pressure angle as "the local pressure angle at the pitch circle").
    Shared by both `tooth_profile_points` and anything else that needs to
    place a flank relative to its tooth's centerline."""
    half_thickness_angle = geometry.tooth_thickness_at_pitch / (2 * geometry.pitch_radius)
    return half_thickness_angle + involute_function(geometry.pressure_angle)


def tooth_profile_points(
    geometry: SpurGearGeometry, points_per_flank: int = 12
) -> list[tuple[float, float]]:
    """One full tooth's outline (right flank root-to-tip, then left flank
    tip-to-root - root-to-root across the *next* tooth's gap is
    `full_gear_profile_points`'s job, not this function's), in a local
    frame where the tooth's own centerline is the **+X axis** (angle 0)
    and the gear's centre is at the origin - so the right/left flanks are
    each other's mirror image across the X axis (`y -> -y`), not the Y
    axis. Root fillet is represented only as `geometry.root_fillet_radius`
    (a value for `02-gear-feature.md`'s OCCT construction to apply when
    rounding the root corners) - this function samples the ideal
    flank/tip only, not a trochoidal undercut curve."""
    offset = _flank_start_offset_angle(geometry)
    tip_radius = geometry.addendum_radius
    root_radius = max(geometry.dedendum_radius, geometry.base_radius)

    right_flank = sample_involute_flank(geometry.base_radius, root_radius, tip_radius, points_per_flank)
    right_flank_rotated = [_rotate(p, -offset) for p in right_flank]

    left_flank = sample_involute_flank(geometry.base_radius, tip_radius, root_radius, points_per_flank)
    # Left flank is the right flank's mirror image about the (+X-axis)
    # tooth centerline - mirroring the raw involute sample about its own
    # natural X-axis before rotating by +offset is equivalent to rotating
    # right_flank by -offset and then mirroring it (R(o) . M = M . R(-o)
    # for a mirror about the X axis), which is the construction actually
    # wanted here - verified by test_tooth_profile_points_are_symmetric_
    # about_the_centerline.
    left_flank_rotated = [_rotate((p[0], -p[1]), offset) for p in left_flank]

    return right_flank_rotated + left_flank_rotated


def _rotate(point: tuple[float, float], angle: float) -> tuple[float, float]:
    """Rotate `point` counter-clockwise by `angle` radians about the origin
    - the standard 2D rotation matrix, shared by every flank-placement call
    in this module so the convention (CCW-positive) stays in exactly one
    place."""
    x, y = point
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    return (x * cos_a - y * sin_a, x * sin_a + y * cos_a)


def full_gear_profile_points(
    geometry: SpurGearGeometry, points_per_flank: int = 12
) -> list[tuple[float, float]]:
    """The whole gear's closed-loop outline (every tooth, all the way
    around) in world coordinates (gear centre at the origin) - what
    `08-entry-screen-and-preview.md`'s `/gear/preview` endpoint returns for
    the live 2D canvas, and what `02-gear-feature.md`'s OCCT construction
    turns into a wire. One `tooth_profile_points` call per tooth, rotated
    to that tooth's angular position (`2*pi / tooth_count` apart)."""
    angular_pitch = 2 * math.pi / geometry.tooth_count
    points: list[tuple[float, float]] = []
    for tooth_index in range(geometry.tooth_count):
        tooth_angle = tooth_index * angular_pitch
        points.extend(_rotate(p, tooth_angle) for p in tooth_profile_points(geometry, points_per_flank))
    return points


# ---------------------------------------------------------------------------
# Rack (trapezoidal, straight-sided - genuinely different math, not a
# variant of involute sampling)
# ---------------------------------------------------------------------------


@dataclass
class RackToothGeometry:
    """One rack tooth's trapezoidal dimensions, all mm. The rack's pitch
    line sits at y=0 in the local frame `rack_tooth_profile_points` returns;
    addendum points toward +y, dedendum toward -y."""

    module: float
    pressure_angle: float
    addendum_height: float
    dedendum_height: float
    tooth_thickness_at_pitch_line: float
    tooth_pitch: float


def rack_tooth_geometry(
    *,
    module: float,
    pressure_angle_degrees: float = 20.0,
    backlash: float = 0.0,
    addendum_coefficient: float = 1.0,
    dedendum_coefficient: float = 1.25,
) -> RackToothGeometry:
    if module <= 0:
        raise GearGeometryError(f"module must be positive, got {module!r}")
    if not (0 < pressure_angle_degrees < 90):
        raise GearGeometryError(f"pressure_angle_degrees must be in (0, 90), got {pressure_angle_degrees!r}")
    tooth_pitch = math.pi * module
    tooth_thickness = tooth_pitch / 2 - backlash
    if tooth_thickness <= 0:
        raise GearGeometryError(f"backlash {backlash!r} is too large for module {module!r}")
    return RackToothGeometry(
        module=module,
        pressure_angle=math.radians(pressure_angle_degrees),
        addendum_height=module * addendum_coefficient,
        dedendum_height=module * dedendum_coefficient,
        tooth_thickness_at_pitch_line=tooth_thickness,
        tooth_pitch=tooth_pitch,
    )


def rack_tooth_profile_points(geometry: RackToothGeometry) -> list[tuple[float, float]]:
    """One rack tooth's straight-sided trapezoid outline (root-left,
    tip-left, tip-right, root-right), local frame centred on the tooth,
    pitch line at y=0. Straight flanks at `geometry.pressure_angle` from
    vertical - unlike a spur gear's involute flank, a rack tooth's flank
    genuinely is a straight line (the involute of a circle with infinite
    radius degenerates to a straight line, which is exactly why a rack can
    mesh with any tooth count of a matching-module gear)."""
    half_thickness_at_pitch = geometry.tooth_thickness_at_pitch_line / 2
    tan_alpha = math.tan(geometry.pressure_angle)
    half_thickness_at_tip = half_thickness_at_pitch - geometry.addendum_height * tan_alpha
    half_thickness_at_root = half_thickness_at_pitch + geometry.dedendum_height * tan_alpha
    return [
        (-half_thickness_at_root, -geometry.dedendum_height),
        (-half_thickness_at_tip, geometry.addendum_height),
        (half_thickness_at_tip, geometry.addendum_height),
        (half_thickness_at_root, -geometry.dedendum_height),
    ]


# ---------------------------------------------------------------------------
# Pair / mesh validation
# ---------------------------------------------------------------------------


def external_pair_center_distance(module: float, tooth_count_a: int, tooth_count_b: int) -> float:
    """Centre distance for two external gears meshing at standard (zero
    net profile shift) proportions: `C = m * (N1 + N2) / 2`. Does not
    account for profile-shift-adjusted centre distance (a more involved
    equation solving the involute function's own inverse) - out of scope
    per `01-gear-math-core.md`'s own listed formula."""
    if module <= 0:
        raise GearGeometryError(f"module must be positive, got {module!r}")
    if tooth_count_a < 4 or tooth_count_b < 4:
        raise GearGeometryError("both tooth counts must be >= 4")
    return module * (tooth_count_a + tooth_count_b) / 2


def external_internal_pair_center_distance(module: float, external_teeth: int, internal_teeth: int) -> float:
    """Centre distance for an external gear meshing inside an internal
    ring at standard proportions: `C = m * (N_ring - N_external) / 2`.
    Shared by a plain external/internal `GearChainFeature` pair and
    `PlanetaryGearFeature`'s own sun-ring relationship - same formula
    either way, not sun/ring-specific despite the name it's usually quoted
    under."""
    if module <= 0:
        raise GearGeometryError(f"module must be positive, got {module!r}")
    if internal_teeth <= external_teeth:
        raise GearGeometryError(
            f"internal_teeth ({internal_teeth!r}) must exceed external_teeth ({external_teeth!r}) - "
            "an internal gear must have more teeth than what meshes inside it"
        )
    return module * (internal_teeth - external_teeth) / 2


# ---------------------------------------------------------------------------
# Planetary assembly
# ---------------------------------------------------------------------------


def planetary_planet_tooth_count(sun_teeth: int, ring_teeth: int) -> int:
    """A planet's tooth count is not a free input - for one planet to mesh
    with both the sun and the ring simultaneously at the same centre
    distance on each side, it's forced to `N_planet = (N_ring - N_sun) /
    2` (`05-gear-chain-and-planetary.md`'s own resolution: sun/ring are the
    free inputs, planet is computed, same "derived not entered" treatment
    `GearChainFeature`'s centre distance already gets). Raises if the
    result isn't a positive integer - there is no valid planet gear to
    draw at all in that case, not a quality tradeoff (per
    `00-conventions.md`'s validation-banner exception), so this blocks
    rather than warns."""
    difference = ring_teeth - sun_teeth
    if difference <= 0:
        raise GearGeometryError(
            f"ring_teeth ({ring_teeth!r}) must exceed sun_teeth ({sun_teeth!r}) for a valid planetary set"
        )
    if difference % 2 != 0:
        raise GearGeometryError(
            f"ring_teeth - sun_teeth ({difference!r}) must be even - sun_teeth {sun_teeth!r}/ring_teeth "
            f"{ring_teeth!r} don't yield an integer planet tooth count"
        )
    return difference // 2


def validate_planetary_assembly(
    *, sun_teeth: int, ring_teeth: int, planet_count: int, planet_pitch_radius: float, planet_addendum_radius: float
) -> None:
    """Fails closed (raises `GearGeometryError`) rather than silently
    producing a non-assemblable or self-colliding planetary set - covers
    both checks `01-gear-math-core.md` names:

    - **Assembly condition**: `(N_sun + N_ring) mod N_planets == 0` -
      evenly-spaced planets must land on a tooth of both the sun and the
      ring at the same time; if this fails, no rotation of the assembly
      brings every planet into mesh simultaneously.
    - **Interference (minimum planet spacing)**: adjacent planets sit on a
      circle of radius `sun_pitch_radius + planet_pitch_radius` around the
      sun, `2*pi / planet_count` apart - their centre-to-centre chord
      distance must exceed the sum of their addendum diameters, or
      neighbouring planets physically overlap. Computed directly from real
      geometry, not a rule-of-thumb minimum planet count."""
    if planet_count < 3:
        raise GearGeometryError(f"planet_count must be >= 3 for a self-supporting planetary set, got {planet_count!r}")
    if (sun_teeth + ring_teeth) % planet_count != 0:
        raise GearGeometryError(
            f"assembly condition failed: (sun_teeth + ring_teeth) = {sun_teeth + ring_teeth!r} is not "
            f"divisible by planet_count {planet_count!r} - planets can't land in mesh simultaneously"
        )
    # orbit_radius = distance from the assembly centre to each planet's own
    # centre = sun_pitch_radius + planet_pitch_radius. Pitch radius is
    # module*teeth/2 for any gear at a shared module, so
    # sun_pitch_radius/planet_pitch_radius = sun_teeth/planet_teeth =
    # 2*sun_teeth/(ring_teeth-sun_teeth) (planet_teeth = (ring_teeth-
    # sun_teeth)/2) - giving orbit_radius = planet_pitch_radius *
    # (sun_teeth + ring_teeth) / (ring_teeth - sun_teeth) once simplified,
    # without ever needing the module value itself.
    orbit_radius = planet_pitch_radius * (sun_teeth + ring_teeth) / (ring_teeth - sun_teeth)
    chord_between_adjacent_planets = 2 * orbit_radius * math.sin(math.pi / planet_count)
    if chord_between_adjacent_planets <= 2 * planet_addendum_radius:
        raise GearGeometryError(
            f"planet_count {planet_count!r} is too high for these tooth counts - adjacent planets' "
            f"addendum circles overlap (spacing {chord_between_adjacent_planets!r}mm, need > "
            f"{2 * planet_addendum_radius!r}mm)"
        )
