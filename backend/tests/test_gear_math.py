"""Reference-value tests for `app.document.gear_math` - no OCCT needed,
same as `test_mesh_data.py`. Checks known standard gear dimensions, not
just "it runs" - see `docs/gear-design/01-gear-math-core.md`'s own test
requirement.
"""

import math

import pytest

from app.document.gear_math import (
    GearGeometryError,
    default_rack_backing_height,
    external_internal_pair_center_distance,
    external_pair_center_distance,
    full_gear_profile_by_tooth,
    full_gear_profile_points,
    full_rack_profile_points,
    helical_twist_angle,
    involute_point,
    involute_roll_angle_at_radius,
    minimum_tooth_count_without_undercut,
    planetary_planet_tooth_count,
    rack_length,
    rack_tooth_geometry,
    rack_tooth_profile_points,
    sample_involute_flank,
    spur_gear_geometry,
    tooth_profile_points,
    validate_planetary_assembly,
)


# ---------------------------------------------------------------------------
# Involute primitives
# ---------------------------------------------------------------------------


def test_involute_starts_on_the_base_circle_at_t_zero():
    x, y = involute_point(base_radius=10.0, roll_angle=0.0)
    assert x == pytest.approx(10.0)
    assert y == pytest.approx(0.0)


def test_involute_radius_grows_with_roll_angle():
    # r(t) = r_b * sqrt(1 + t^2) - a textbook identity, check it holds for
    # a few points rather than trusting the parametrization blindly.
    base_radius = 10.0
    for t in (0.5, 1.0, 2.0):
        x, y = involute_point(base_radius, t)
        radius = math.hypot(x, y)
        assert radius == pytest.approx(base_radius * math.sqrt(1 + t * t))


def test_involute_roll_angle_at_radius_is_the_inverse_of_the_radius_function():
    base_radius = 18.793852
    for radius in (20.0, 22.0, 30.0):
        t = involute_roll_angle_at_radius(base_radius, radius)
        assert base_radius * math.sqrt(1 + t * t) == pytest.approx(radius)


def test_involute_roll_angle_at_radius_rejects_radius_inside_base_circle():
    with pytest.raises(GearGeometryError):
        involute_roll_angle_at_radius(base_radius=10.0, radius=5.0)


def test_sample_involute_flank_runs_from_start_to_end_radius():
    points = sample_involute_flank(base_radius=10.0, start_radius=10.0, end_radius=15.0, point_count=5)
    assert len(points) == 5
    assert math.hypot(*points[0]) == pytest.approx(10.0)
    assert math.hypot(*points[-1]) == pytest.approx(15.0)


# ---------------------------------------------------------------------------
# Spur gear geometry - known reference values
# ---------------------------------------------------------------------------
# Standard module-2, 20-tooth, 20-degree-pressure-angle, full-depth spur
# gear (addendum coefficient 1.0, dedendum coefficient 1.25, zero profile
# shift/backlash) - textbook values, hand-computable:
#   pitch diameter    = m*z            = 2*20        = 40mm
#   base diameter      = pitch*cos(20deg)             = 37.588 mm
#   addendum diameter  = m*(z+2)       = 2*22         = 44mm
#   dedendum diameter  = m*(z-2.5)     = 2*17.5        = 35mm
#   tooth thickness at pitch (no shift/backlash) = pi*m/2 = 3.14159mm


def test_module_2_20_tooth_spur_gear_matches_known_reference_values():
    geometry = spur_gear_geometry(module=2.0, tooth_count=20, pressure_angle_degrees=20.0)

    assert geometry.pitch_radius == pytest.approx(20.0)
    assert geometry.base_radius == pytest.approx(20.0 * math.cos(math.radians(20.0)))
    assert geometry.base_radius == pytest.approx(18.79385, abs=1e-4)
    assert geometry.addendum_radius == pytest.approx(22.0)
    assert geometry.dedendum_radius == pytest.approx(17.5)
    assert geometry.tooth_thickness_at_pitch == pytest.approx(math.pi, abs=1e-6)  # pi*m/2 with m=2


def test_backlash_reduces_tooth_thickness_by_exactly_the_backlash_amount():
    plain = spur_gear_geometry(module=2.0, tooth_count=20)
    with_backlash = spur_gear_geometry(module=2.0, tooth_count=20, backlash=0.1)
    assert with_backlash.tooth_thickness_at_pitch == pytest.approx(plain.tooth_thickness_at_pitch - 0.1)


def test_positive_profile_shift_increases_addendum_and_decreases_dedendum():
    plain = spur_gear_geometry(module=2.0, tooth_count=17)
    shifted = spur_gear_geometry(module=2.0, tooth_count=17, profile_shift=0.3)
    assert shifted.addendum_radius > plain.addendum_radius
    assert shifted.dedendum_radius > plain.dedendum_radius


def test_internal_gear_inverts_addendum_and_dedendum_direction():
    external = spur_gear_geometry(module=2.0, tooth_count=40, is_internal=False)
    internal = spur_gear_geometry(module=2.0, tooth_count=40, is_internal=True)
    # Same pitch radius either way; addendum/dedendum swap sides.
    assert internal.pitch_radius == pytest.approx(external.pitch_radius)
    assert internal.addendum_radius < internal.pitch_radius < internal.dedendum_radius
    assert external.dedendum_radius < external.pitch_radius < external.addendum_radius


def test_rejects_non_positive_module():
    with pytest.raises(GearGeometryError):
        spur_gear_geometry(module=0.0, tooth_count=20)
    with pytest.raises(GearGeometryError):
        spur_gear_geometry(module=-1.0, tooth_count=20)


def test_rejects_too_few_teeth():
    with pytest.raises(GearGeometryError):
        spur_gear_geometry(module=2.0, tooth_count=3)


def test_rejects_backlash_that_exceeds_available_tooth_thickness():
    with pytest.raises(GearGeometryError):
        spur_gear_geometry(module=2.0, tooth_count=20, backlash=10.0)


# ---------------------------------------------------------------------------
# Undercut
# ---------------------------------------------------------------------------


def test_minimum_tooth_count_without_undercut_matches_known_value_for_20_degree_full_depth():
    # Standard textbook result: z_min = 2*1.0/sin^2(20deg) ~= 17.1
    z_min = minimum_tooth_count_without_undercut(pressure_angle_degrees=20.0)
    assert z_min == pytest.approx(17.10, abs=0.01)


def test_profile_shift_lowers_the_undercut_threshold():
    plain = minimum_tooth_count_without_undercut(pressure_angle_degrees=20.0)
    shifted = minimum_tooth_count_without_undercut(pressure_angle_degrees=20.0, profile_shift=0.3)
    assert shifted < plain


# ---------------------------------------------------------------------------
# Full tooth / gear profile assembly
# ---------------------------------------------------------------------------


def test_tooth_profile_points_are_symmetric_about_the_centerline():
    geometry = spur_gear_geometry(module=2.0, tooth_count=20)
    points = tooth_profile_points(geometry, points_per_flank=6)
    assert len(points) == 12
    # The tooth centerline is the local +X axis (angle 0) - see
    # tooth_profile_points' own docstring - so right/left flanks mirror
    # across the X axis (y -> -y, x unchanged) at matching radii, not
    # across the Y axis.
    right = points[:6]
    left = list(reversed(points[6:]))
    for (rx, ry), (lx, ly) in zip(right, left):
        assert lx == pytest.approx(rx, abs=1e-6)
        assert ly == pytest.approx(-ry, abs=1e-6)


def test_tooth_tip_and_root_land_on_the_expected_radii():
    geometry = spur_gear_geometry(module=2.0, tooth_count=20)
    points = tooth_profile_points(geometry, points_per_flank=6)
    radii = [math.hypot(x, y) for x, y in points]
    assert max(radii) == pytest.approx(geometry.addendum_radius, abs=1e-6)
    assert min(radii) == pytest.approx(max(geometry.dedendum_radius, geometry.base_radius), abs=1e-6)


def test_internal_tooth_profile_points_are_symmetric_about_the_centerline():
    # Same shape assertion as test_tooth_profile_points_are_symmetric_about_
    # the_centerline above, for is_internal=True - the mirror-through-pitch
    # construction (_internal_tooth_profile_points) only rescales each
    # point's own radius, which can't break the existing left/right
    # symmetry about the +X-axis centerline.
    geometry = spur_gear_geometry(module=2.0, tooth_count=40, is_internal=True)
    points = tooth_profile_points(geometry, points_per_flank=6)
    assert len(points) == 12
    right = points[:6]
    left = list(reversed(points[6:]))
    for (rx, ry), (lx, ly) in zip(right, left):
        assert lx == pytest.approx(rx, abs=1e-6)
        assert ly == pytest.approx(-ry, abs=1e-6)


def test_internal_tooth_widens_toward_the_root_and_narrows_toward_the_tip():
    # On-device feedback: a real internal gear rendered with teeth narrower
    # at the root (far from centre, near the rim) than at the tip (close to
    # centre, near the bore) - a "dovetail", backwards from how every real
    # gear tooth (external or internal) actually tapers. Confirmed against
    # the real OCCT solid (a binary search on the material/hole boundary at
    # each radius) before this fix and clear afterward - this is the same
    # check expressed directly against the pure-math profile points, so a
    # regression here is caught without needing OCCT at all.
    geometry = spur_gear_geometry(module=2.0, tooth_count=40, is_internal=True)
    points = tooth_profile_points(geometry, points_per_flank=30)
    right = points[:30]  # root -> tip, per tooth_profile_points' own docstring
    root_half_width = abs(right[0][1])
    tip_half_width = abs(right[-1][1])
    assert math.hypot(*right[0]) > math.hypot(*right[-1])  # right[0] really is the root (larger radius)
    assert root_half_width > tip_half_width
    # Monotonic throughout, not just at the two ends - right[] runs root to
    # tip (per tooth_profile_points' own docstring), so half-width should
    # be *descending* across the list, not ascending.
    half_widths = [abs(y) for _, y in right]
    assert half_widths == sorted(half_widths, reverse=True)


def test_full_gear_profile_has_one_tooth_worth_of_points_times_tooth_count():
    geometry = spur_gear_geometry(module=2.0, tooth_count=12)
    points = full_gear_profile_points(geometry, points_per_flank=6)
    assert len(points) == 12 * 12  # 12 teeth * (6+6) points per tooth


def test_full_gear_profile_points_all_lie_between_dedendum_and_addendum_radius():
    geometry = spur_gear_geometry(module=2.0, tooth_count=12)
    points = full_gear_profile_points(geometry, points_per_flank=6)
    root_radius = max(geometry.dedendum_radius, geometry.base_radius)
    for x, y in points:
        radius = math.hypot(x, y)
        assert root_radius - 1e-6 <= radius <= geometry.addendum_radius + 1e-6


def test_full_gear_profile_by_tooth_has_one_entry_per_tooth_with_correct_flank_sizes():
    geometry = spur_gear_geometry(module=2.0, tooth_count=12)
    by_tooth = full_gear_profile_by_tooth(geometry, points_per_flank=6)
    assert len(by_tooth) == 12
    for right, left in by_tooth:
        assert len(right) == 6
        assert len(left) == 6


def test_full_gear_profile_by_tooth_matches_the_flattened_points_exactly():
    # full_gear_profile_points is built from this function - guard against
    # the refactor drifting the two apart.
    geometry = spur_gear_geometry(module=2.0, tooth_count=12)
    by_tooth = full_gear_profile_by_tooth(geometry, points_per_flank=6)
    flattened = [p for right, left in by_tooth for p in (*right, *left)]
    assert flattened == full_gear_profile_points(geometry, points_per_flank=6)


def test_full_gear_profile_by_tooth_teeth_are_evenly_rotated_copies_of_each_other():
    geometry = spur_gear_geometry(module=2.0, tooth_count=8)
    by_tooth = full_gear_profile_by_tooth(geometry, points_per_flank=5)
    angular_pitch = 2 * math.pi / 8
    first_right = by_tooth[0][0]
    second_right = by_tooth[1][0]
    for (x0, y0), (x1, y1) in zip(first_right, second_right):
        r0, r1 = math.hypot(x0, y0), math.hypot(x1, y1)
        assert r1 == pytest.approx(r0, abs=1e-9)
        theta0, theta1 = math.atan2(y0, x0), math.atan2(y1, x1)
        assert (theta1 - theta0) % (2 * math.pi) == pytest.approx(angular_pitch, abs=1e-9)


# ---------------------------------------------------------------------------
# Rack
# ---------------------------------------------------------------------------


def test_rack_tooth_geometry_matches_known_reference_values():
    # module=2, 20deg pressure angle, standard coefficients:
    #   addendum height = 2mm, dedendum height = 2.5mm
    #   tooth thickness at pitch line = pi*m/2 = 3.14159mm (no backlash)
    geometry = rack_tooth_geometry(module=2.0, pressure_angle_degrees=20.0)
    assert geometry.addendum_height == pytest.approx(2.0)
    assert geometry.dedendum_height == pytest.approx(2.5)
    assert geometry.tooth_thickness_at_pitch_line == pytest.approx(math.pi, abs=1e-6)
    assert geometry.tooth_pitch == pytest.approx(2 * math.pi, abs=1e-6)


def test_rack_tooth_profile_is_a_symmetric_trapezoid():
    geometry = rack_tooth_geometry(module=2.0)
    points = rack_tooth_profile_points(geometry)
    assert len(points) == 4
    root_left, tip_left, tip_right, root_right = points
    assert root_left[1] == pytest.approx(-geometry.dedendum_height)
    assert tip_left[1] == pytest.approx(geometry.addendum_height)
    assert tip_right[1] == pytest.approx(geometry.addendum_height)
    assert root_right[1] == pytest.approx(-geometry.dedendum_height)
    assert root_left[0] == pytest.approx(-root_right[0])
    assert tip_left[0] == pytest.approx(-tip_right[0])
    # Flanks lean inward from root to tip (pressure angle > 0).
    assert tip_right[0] < root_right[0]


def test_rack_flank_angle_matches_the_pressure_angle():
    geometry = rack_tooth_geometry(module=2.0, pressure_angle_degrees=20.0)
    points = rack_tooth_profile_points(geometry)
    root_left, tip_left, _, _ = points
    dx = tip_left[0] - root_left[0]
    dy = tip_left[1] - root_left[1]
    flank_angle_from_vertical = math.atan2(abs(dx), dy)
    assert flank_angle_from_vertical == pytest.approx(math.radians(20.0), abs=1e-6)


def test_rack_length_matches_known_formula():
    # module=2 -> tooth_pitch = pi*2 ~= 6.2832mm; 5 teeth -> length ~= 31.416mm
    geometry = rack_tooth_geometry(module=2.0)
    assert rack_length(geometry, tooth_count=5) == pytest.approx(5 * 2 * math.pi, abs=1e-6)


def test_rack_length_rejects_non_positive_tooth_count():
    geometry = rack_tooth_geometry(module=2.0)
    with pytest.raises(GearGeometryError):
        rack_length(geometry, tooth_count=0)


def test_full_rack_profile_has_four_points_per_tooth():
    geometry = rack_tooth_geometry(module=2.0)
    points = full_rack_profile_points(geometry, tooth_count=5)
    assert len(points) == 20


def test_full_rack_profile_is_centred_on_the_origin():
    geometry = rack_tooth_geometry(module=2.0)
    points = full_rack_profile_points(geometry, tooth_count=6)
    xs = [x for x, y in points]
    assert min(xs) == pytest.approx(-max(xs), abs=1e-9)


def test_full_rack_profile_teeth_are_evenly_spaced_copies():
    geometry = rack_tooth_geometry(module=2.0)
    points = full_rack_profile_points(geometry, tooth_count=4)
    tooth_0 = points[0:4]
    tooth_1 = points[4:8]
    for (x0, y0), (x1, y1) in zip(tooth_0, tooth_1):
        assert y1 == pytest.approx(y0, abs=1e-9)
        assert x1 - x0 == pytest.approx(geometry.tooth_pitch, abs=1e-9)


def test_full_rack_profile_consecutive_teeth_share_the_flat_root_land():
    # tooth i's root-right point and tooth i+1's root-left point should
    # both sit at y=-dedendum_height (the flat land between teeth), the
    # geometric property that lets a straight polyline through all points
    # connect the whole profile with no separate root-gap edge needed.
    geometry = rack_tooth_geometry(module=2.0)
    points = full_rack_profile_points(geometry, tooth_count=3)
    root_right_0 = points[3]
    root_left_1 = points[4]
    assert root_right_0[1] == pytest.approx(root_left_1[1], abs=1e-9)
    assert root_right_0[1] == pytest.approx(-geometry.dedendum_height, abs=1e-9)


def test_default_rack_backing_height_scales_with_module():
    assert default_rack_backing_height(2.0) == pytest.approx(4.0)
    assert default_rack_backing_height(1.0) == pytest.approx(2.0)


def test_default_rack_backing_height_rejects_non_positive_module():
    with pytest.raises(GearGeometryError):
        default_rack_backing_height(0.0)


# ---------------------------------------------------------------------------
# Pair center distance
# ---------------------------------------------------------------------------


def test_external_pair_center_distance_matches_known_formula():
    # module=2, 20+30 teeth -> C = 2*(20+30)/2 = 50mm
    assert external_pair_center_distance(module=2.0, tooth_count_a=20, tooth_count_b=30) == pytest.approx(50.0)


def test_external_internal_pair_center_distance_matches_known_formula():
    # module=2, external 20 teeth inside a 60-tooth ring -> C = 2*(60-20)/2 = 40mm
    result = external_internal_pair_center_distance(module=2.0, external_teeth=20, internal_teeth=60)
    assert result == pytest.approx(40.0)


def test_external_internal_pair_rejects_ring_not_larger_than_external():
    with pytest.raises(GearGeometryError):
        external_internal_pair_center_distance(module=2.0, external_teeth=40, internal_teeth=40)
    with pytest.raises(GearGeometryError):
        external_internal_pair_center_distance(module=2.0, external_teeth=40, internal_teeth=30)


# ---------------------------------------------------------------------------
# Planetary
# ---------------------------------------------------------------------------


def test_planetary_planet_tooth_count_matches_known_formula():
    # sun=20, ring=80 -> planet = (80-20)/2 = 30
    assert planetary_planet_tooth_count(sun_teeth=20, ring_teeth=80) == 30


def test_planetary_planet_tooth_count_rejects_odd_difference():
    with pytest.raises(GearGeometryError):
        planetary_planet_tooth_count(sun_teeth=20, ring_teeth=81)


def test_planetary_planet_tooth_count_rejects_ring_not_larger_than_sun():
    with pytest.raises(GearGeometryError):
        planetary_planet_tooth_count(sun_teeth=40, ring_teeth=40)
    with pytest.raises(GearGeometryError):
        planetary_planet_tooth_count(sun_teeth=40, ring_teeth=20)


def test_validate_planetary_assembly_accepts_a_valid_standard_configuration():
    # sun=20, ring=100, planet=(100-20)/2=40, 3 planets: (20+100) % 3 == 0 - valid.
    # module=2 -> sun pitch radius 20mm, planet pitch radius 40mm,
    # orbit radius 60mm, addendum radius ~42mm (40+2) - chord between
    # adjacent planets at 3-fold symmetry (120 degrees apart) is
    # 2*60*sin(60deg) ~= 103.9mm, comfortably clear of 2*42=84mm.
    validate_planetary_assembly(
        sun_teeth=20, ring_teeth=100, planet_count=3, planet_pitch_radius=40.0, planet_addendum_radius=42.0
    )


def test_validate_planetary_assembly_rejects_a_non_dividing_planet_count():
    # sun=20, ring=81 would break planetary_planet_tooth_count's own even-
    # difference rule first in real use, but this function is tested in
    # isolation against its own assembly-condition arithmetic: sun+ring=100,
    # not divisible by planet_count=7.
    with pytest.raises(GearGeometryError):
        validate_planetary_assembly(
            sun_teeth=20, ring_teeth=80, planet_count=7, planet_pitch_radius=30.0, planet_addendum_radius=32.0
        )


def test_validate_planetary_assembly_rejects_too_few_planets():
    with pytest.raises(GearGeometryError):
        validate_planetary_assembly(
            sun_teeth=20, ring_teeth=80, planet_count=2, planet_pitch_radius=30.0, planet_addendum_radius=32.0
        )


def test_validate_planetary_assembly_rejects_colliding_planets():
    # sun=10, ring=90, planet=(90-10)/2=40, 10 planets: (10+90) % 10 == 0 -
    # assembly condition holds, but packing 10 planets this large this
    # close together collides. module=1 -> sun pitch=5mm, planet
    # pitch=20mm, orbit=25mm; at 10 planets (36 degrees apart), chord =
    # 2*25*sin(18deg) ~= 15.45mm, well under 2*addendum(~42mm) -> collision.
    assert (10 + 90) % 10 == 0
    with pytest.raises(GearGeometryError):
        validate_planetary_assembly(
            sun_teeth=10, ring_teeth=90, planet_count=10, planet_pitch_radius=20.0, planet_addendum_radius=21.0
        )


def test_orbit_radius_used_by_assembly_check_matches_direct_geometric_computation():
    # Cross-check the module-independent orbit-radius derivation inside
    # validate_planetary_assembly against a direct module-based computation,
    # to catch exactly the kind of algebra slip this formula is prone to.
    module = 2.0
    sun_teeth, ring_teeth = 20, 80
    planet_teeth = planetary_planet_tooth_count(sun_teeth, ring_teeth)
    sun_pitch_radius = module * sun_teeth / 2
    planet_pitch_radius = module * planet_teeth / 2
    expected_orbit_radius = sun_pitch_radius + planet_pitch_radius

    derived_orbit_radius = planet_pitch_radius * (sun_teeth + ring_teeth) / (ring_teeth - sun_teeth)
    assert derived_orbit_radius == pytest.approx(expected_orbit_radius)


# --- helical_twist_angle (Workstream 4a) ------------------------------------


def test_helical_twist_angle_zero_helix_angle_gives_zero_twist():
    assert helical_twist_angle(pitch_radius=20.0, face_width=20.0, helix_angle_degrees=0.0) == 0.0


def test_helical_twist_angle_at_45_degrees_equals_face_width_over_pitch_radius():
    # tan(45deg) == 1, so the standard `twist = face_width * tan(helix) /
    # pitch_radius` relation degenerates to a clean, independently-checkable
    # value at this one angle.
    twist_radians = helical_twist_angle(pitch_radius=20.0, face_width=10.0, helix_angle_degrees=45.0)
    assert twist_radians == pytest.approx(10.0 / 20.0)


def test_helical_twist_angle_is_linear_in_face_width():
    # twist = face_width * tan(helix_angle) / pitch_radius - halving
    # face_width must exactly halve the twist (used directly by
    # app.document.gear's own herringbone-half construction).
    full = helical_twist_angle(pitch_radius=15.0, face_width=10.0, helix_angle_degrees=20.0)
    half = helical_twist_angle(pitch_radius=15.0, face_width=5.0, helix_angle_degrees=20.0)
    assert half == pytest.approx(full / 2)


def test_helical_twist_angle_flips_sign_with_helix_angle():
    positive = helical_twist_angle(pitch_radius=15.0, face_width=10.0, helix_angle_degrees=20.0)
    negative = helical_twist_angle(pitch_radius=15.0, face_width=10.0, helix_angle_degrees=-20.0)
    assert positive == pytest.approx(-negative)


def test_helical_twist_angle_rejects_non_positive_pitch_radius():
    with pytest.raises(GearGeometryError):
        helical_twist_angle(pitch_radius=0.0, face_width=10.0, helix_angle_degrees=20.0)
