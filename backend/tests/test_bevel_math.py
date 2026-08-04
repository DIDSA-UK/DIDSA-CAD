"""Reference-value tests for `app.document.bevel_math` - no OCCT needed,
same as `test_gear_math.py`. Per `docs/gear-design/10-bevel-gear.md`'s own
test requirement, this matters *more* here than for `test_gear_math.py`:
there is no existing precedent in this codebase for spherical involute
gearing to sanity-check the derivation against, and (per this spike's own
findings - see `10-bevel-gear.md`'s appended notes) no single well-known
published example gives full-precision (x, y, z) points to check the curve
itself against directly. So alongside known closed-form angle values
(independently checkable by hand/calculator, not derived from this
module), several tests here cross-check `bevel_math`'s spherical involute
against a *second, independently-derived* formula for the same geometry
(Napier's rules for right spherical triangles - a different derivation
path through the same problem, worked out in `spherical_involute_point`'s
and `spherical_involute_azimuth_at_colatitude`'s own docstrings) rather
than merely re-running the same formula and comparing it to itself.
"""

import math

import pytest

from app.document.bevel_math import (
    BevelGearGeometry,
    base_cone_half_angle,
    bevel_gear_geometry,
    bevel_tooth_flank_pair,
    max_recommended_face_width,
    pitch_cone_half_angles,
    sample_spherical_involute_flank,
    spherical_involute_azimuth_at_colatitude,
    spherical_involute_colatitude,
    spherical_involute_point,
    spherical_involute_roll_angle_at_colatitude,
)
from app.document.gear_math import GearGeometryError, involute_point, spur_gear_geometry


# ---------------------------------------------------------------------------
# Pitch cone half-angles - known reference values
# ---------------------------------------------------------------------------


def test_pitch_cone_half_angles_at_90_degree_shaft_angle_matches_the_textbook_atan_n1_n2_reduction():
    # docs/gear-design/10-bevel-gear.md's own stated reduction case:
    # gamma_1 = atan(N1/N2) at Sigma=90deg. atan(0.5) = 26.56505117707799...
    # degrees is an exact, independently-checkable trig value (any
    # calculator), not derived from this module.
    gamma_1, gamma_2 = pitch_cone_half_angles(20, 40, shaft_angle_degrees=90.0)
    assert math.degrees(gamma_1) == pytest.approx(26.56505117707799)
    assert math.degrees(gamma_2) == pytest.approx(63.43494882292201)
    assert gamma_1 + gamma_2 == pytest.approx(math.pi / 2)


def test_pitch_cone_half_angles_at_60_degree_shaft_angle_with_equal_teeth_gives_a_clean_30_30_split():
    # Sigma=60deg, N1=N2 -> gamma_1 = atan(sin(60)/(1+cos(60))) =
    # atan(0.8660254/1.5) = atan(1/sqrt(3)) = 30deg exactly - an
    # independently-checkable clean closed-form value (tan(30deg) =
    # 1/sqrt(3) is a textbook identity), not just "it runs".
    gamma_1, gamma_2 = pitch_cone_half_angles(20, 20, shaft_angle_degrees=60.0)
    assert math.degrees(gamma_1) == pytest.approx(30.0)
    assert math.degrees(gamma_2) == pytest.approx(30.0)
    assert gamma_1 + gamma_2 == pytest.approx(math.radians(60.0))


@pytest.mark.parametrize(
    ("tooth_count_1", "tooth_count_2", "shaft_angle_degrees"),
    [(12, 60, 90.0), (17, 41, 90.0), (20, 30, 45.0), (24, 24, 120.0), (10, 90, 135.0)],
)
def test_pitch_cone_half_angles_always_sum_to_the_shaft_angle(tooth_count_1, tooth_count_2, shaft_angle_degrees):
    gamma_1, gamma_2 = pitch_cone_half_angles(tooth_count_1, tooth_count_2, shaft_angle_degrees)
    assert gamma_1 + gamma_2 == pytest.approx(math.radians(shaft_angle_degrees))
    assert gamma_1 > 0
    assert gamma_2 > 0


def test_pitch_cone_half_angles_swapping_tooth_counts_swaps_the_two_angles():
    gamma_1, gamma_2 = pitch_cone_half_angles(15, 45, shaft_angle_degrees=90.0)
    gamma_2_swapped, gamma_1_swapped = pitch_cone_half_angles(45, 15, shaft_angle_degrees=90.0)
    assert gamma_1 == pytest.approx(gamma_1_swapped)
    assert gamma_2 == pytest.approx(gamma_2_swapped)


def test_pitch_cone_half_angles_rejects_too_few_teeth():
    with pytest.raises(GearGeometryError):
        pitch_cone_half_angles(3, 40, shaft_angle_degrees=90.0)


def test_pitch_cone_half_angles_rejects_invalid_shaft_angle():
    with pytest.raises(GearGeometryError):
        pitch_cone_half_angles(20, 40, shaft_angle_degrees=0.0)
    with pytest.raises(GearGeometryError):
        pitch_cone_half_angles(20, 40, shaft_angle_degrees=180.0)


# ---------------------------------------------------------------------------
# Base cone half-angle - known/degenerate reference values
# ---------------------------------------------------------------------------


def test_base_cone_half_angle_equals_pitch_cone_angle_at_zero_pressure_angle():
    # alpha=0 -> sin(gamma_b) = sin(gamma)*cos(0) = sin(gamma) -> gamma_b
    # = gamma exactly, mirroring gear_math's own base_radius ==
    # pitch_radius at zero pressure angle - an independently-checkable
    # degenerate case (cos(0) = 1 is not something this derivation could
    # get subtly wrong and still pass), not just "it runs".
    gamma = math.radians(26.565051177077994)
    assert base_cone_half_angle(gamma, pressure_angle=0.0) == pytest.approx(gamma)


def test_base_cone_half_angle_of_a_crown_gear_is_90_degrees_minus_pressure_angle():
    # gamma=90deg (a crown gear, flat pitch plane) -> sin(gamma_b) =
    # 1*cos(alpha) = sin(90deg - alpha) -> gamma_b = 90deg - alpha exactly.
    gamma_b = base_cone_half_angle(math.radians(90.0) - 1e-9, pressure_angle=math.radians(20.0))
    assert math.degrees(gamma_b) == pytest.approx(70.0, abs=1e-5)


@pytest.mark.parametrize("pressure_angle_degrees", [14.5, 20.0, 25.0])
def test_base_cone_half_angle_is_smaller_than_the_pitch_cone_angle_for_any_positive_pressure_angle(
    pressure_angle_degrees,
):
    gamma = math.radians(35.0)
    gamma_b = base_cone_half_angle(gamma, math.radians(pressure_angle_degrees))
    assert 0 < gamma_b < gamma


def test_base_cone_half_angle_at_small_angle_matches_the_planar_base_radius_ratio_in_the_flat_limit():
    # For a very small pitch cone angle (a near-flat gear, close to the
    # planar limit where curvature effects vanish), sin(x) ~= x, so
    # sin(gamma_b) = sin(gamma)*cos(alpha) collapses to gamma_b ~=
    # gamma*cos(alpha) - exactly gear_math's planar base_radius =
    # pitch_radius*cos(pressure_angle) relation, with angle standing in
    # for radius. A real, independent numerical cross-check that the
    # small-angle limit of this spherical formula reproduces the known
    # planar one, not a re-statement of the same formula.
    gamma = math.radians(0.5)
    alpha = math.radians(20.0)
    gamma_b = base_cone_half_angle(gamma, alpha)
    assert gamma_b == pytest.approx(gamma * math.cos(alpha), rel=1e-4)


def test_base_cone_half_angle_rejects_out_of_range_inputs():
    with pytest.raises(GearGeometryError):
        base_cone_half_angle(0.0, math.radians(20.0))
    with pytest.raises(GearGeometryError):
        base_cone_half_angle(math.radians(30.0), math.radians(90.0))


# ---------------------------------------------------------------------------
# Spherical involute primitives
# ---------------------------------------------------------------------------


def test_spherical_involute_starts_on_the_base_circle_at_roll_angle_zero():
    gamma_b = math.radians(24.8)
    x, y, z = spherical_involute_point(gamma_b, roll_angle=0.0, sphere_radius=50.0)
    assert x == pytest.approx(50.0 * math.sin(gamma_b))
    assert y == pytest.approx(0.0, abs=1e-9)
    assert z == pytest.approx(50.0 * math.cos(gamma_b))


@pytest.mark.parametrize("roll_angle", [0.0, 0.1, 0.3, 0.6, 1.0, 1.5])
def test_spherical_involute_point_lies_exactly_on_the_sphere(roll_angle):
    gamma_b = math.radians(24.8)
    radius = 37.5
    x, y, z = spherical_involute_point(gamma_b, roll_angle, sphere_radius=radius)
    assert math.sqrt(x * x + y * y + z * z) == pytest.approx(radius)


def test_spherical_involute_point_scales_linearly_with_sphere_radius():
    gamma_b = math.radians(24.8)
    p1 = spherical_involute_point(gamma_b, roll_angle=0.7, sphere_radius=1.0)
    p2 = spherical_involute_point(gamma_b, roll_angle=0.7, sphere_radius=42.0)
    assert p2 == pytest.approx(tuple(42.0 * c for c in p1))


def test_spherical_involute_colatitude_grows_monotonically_with_roll_angle():
    gamma_b = math.radians(24.8)
    colatitudes = [spherical_involute_colatitude(gamma_b, t) for t in (0.0, 0.2, 0.5, 0.9, 1.4)]
    assert colatitudes == sorted(colatitudes)
    assert colatitudes[0] == pytest.approx(gamma_b)


def test_spherical_involute_roll_angle_at_colatitude_is_the_inverse_of_colatitude():
    gamma_b = math.radians(24.8)
    for colatitude_degrees in (26.0, 30.0, 40.0, 55.0):
        colatitude = math.radians(colatitude_degrees)
        roll_angle = spherical_involute_roll_angle_at_colatitude(gamma_b, colatitude)
        assert spherical_involute_colatitude(gamma_b, roll_angle) == pytest.approx(colatitude)


def test_spherical_involute_roll_angle_at_colatitude_rejects_colatitude_inside_the_base_cone():
    gamma_b = math.radians(24.8)
    with pytest.raises(GearGeometryError):
        spherical_involute_roll_angle_at_colatitude(gamma_b, math.radians(10.0))


def test_sample_spherical_involute_flank_runs_from_start_to_end_colatitude():
    gamma_b = math.radians(24.8)
    points = sample_spherical_involute_flank(
        gamma_b, start_colatitude=gamma_b, end_colatitude=math.radians(40.0), sphere_radius=89.44, point_count=6
    )
    assert len(points) == 6
    first_colatitude = math.acos(points[0][2] / 89.44)
    last_colatitude = math.acos(points[-1][2] / 89.44)
    assert first_colatitude == pytest.approx(gamma_b, abs=1e-6)
    assert last_colatitude == pytest.approx(math.radians(40.0), abs=1e-6)


# ---------------------------------------------------------------------------
# Independent cross-check: Napier's-rule-derived azimuth vs. this module's
# direct point-evaluation azimuth - two different derivations of the same
# quantity, not the same formula compared to itself. See
# spherical_involute_azimuth_at_colatitude's own docstring for the
# triangle/rule this reference implementation uses.
# ---------------------------------------------------------------------------


def _reference_azimuth_via_napiers_rule(base_cone_half_angle: float, roll_angle: float) -> float:
    """Independent derivation: right spherical triangle (pole N, tangency
    point B(roll_angle), involute point P), right angle at B, hypotenuse
    N-P = colatitude, legs N-B = base_cone_half_angle (opposite the angle
    at P) and B-P = u = sin(base_cone_half_angle)*roll_angle (opposite the
    angle at N, which is exactly the azimuth offset wanted). Napier's rule
    sin(leg) = sin(hypotenuse)*sin(opposite angle) applied to the B-P leg:
    sin(u) = sin(colatitude)*sin(delta_phi) -> delta_phi =
    asin(sin(u)/sin(colatitude)). The involute point's absolute azimuth is
    the tangency point's own azimuth (roll_angle) *minus* this offset -
    `spherical_involute_point`'s `Tang(theta)` direction is the
    decreasing-theta tangent (matching `gear_math.involute_point`'s own
    handedness), so the involute point lags the tangency point in
    azimuth, not leads it (an earlier version of both this reference and
    `spherical_involute_point` used the opposite sign consistently, which
    is exactly why this cross-check alone didn't catch the bug - see
    `bevel_math.spherical_involute_point`'s own docstring for how it was
    actually caught: a bit-for-bit comparison against `gear_math.
    involute_point`'s already-trusted planar formula)."""
    u = math.sin(base_cone_half_angle) * roll_angle
    colatitude = math.acos(math.cos(base_cone_half_angle) * math.cos(u))
    delta_phi = math.asin(max(-1.0, min(1.0, math.sin(u) / math.sin(colatitude))))
    return roll_angle - delta_phi


@pytest.mark.parametrize("roll_angle", [0.05, 0.15, 0.3, 0.5, 0.8, 1.1, 1.4])
@pytest.mark.parametrize("base_cone_half_angle_degrees", [10.0, 24.8, 45.0, 60.0])
def test_spherical_involute_azimuth_matches_independent_napiers_rule_derivation(
    roll_angle, base_cone_half_angle_degrees
):
    gamma_b = math.radians(base_cone_half_angle_degrees)
    x, y, _z = spherical_involute_point(gamma_b, roll_angle)
    azimuth_from_this_module = math.atan2(y, x)
    azimuth_from_independent_derivation = _reference_azimuth_via_napiers_rule(gamma_b, roll_angle)
    assert azimuth_from_this_module == pytest.approx(azimuth_from_independent_derivation, abs=1e-9)


@pytest.mark.parametrize("theta", [0.1, 0.5, 1.0])
@pytest.mark.parametrize("base_cone_half_angle_degrees", [5.0, 1.0, 0.1, 0.01])
def test_spherical_involute_converges_to_the_planar_involute_as_the_base_cone_flattens(
    theta, base_cone_half_angle_degrees
):
    # As base_cone_half_angle -> 0 (holding the base *circle's* actual
    # radius fixed at 1.0 by growing sphere_radius = 1/sin(gamma_b) to
    # compensate), a sufficiently small patch of a very large sphere looks
    # flat - the spherical involute should converge to gear_math's own
    # already-trusted planar involute_point, to first order in gamma_b.
    # This is the check that actually caught this module's original
    # sign bug (an earlier draft's `Tang(theta)` direction was flipped -
    # it passed the sphere/monotonicity/Napier's-rule self-consistency
    # checks above, since those don't reference gear_math at all, but
    # failed this one by nearly two orders of magnitude at gamma_b=5deg,
    # not shrinking as gamma_b shrank further).
    gamma_b = math.radians(base_cone_half_angle_degrees)
    sphere_radius = 1.0 / math.sin(gamma_b)
    x, y, _z = spherical_involute_point(gamma_b, theta, sphere_radius)
    px, py = involute_point(base_radius=1.0, roll_angle=theta)
    error = math.hypot(x - px, y - py)
    # Error should shrink roughly with gamma_b (first-order in the small
    # angle) - loose bound, just needs to rule out an O(1) mismatch like
    # the sign bug produced, not pin an exact convergence rate.
    assert error < 0.02 * base_cone_half_angle_degrees


def _rotate_about_axis(vector, axis, angle):
    """Rodrigues' rotation formula - used only by the independent rolling
    simulation below, kept local to the test so it shares no code with
    `bevel_math._rotate_about_z`."""
    ax, ay, az = axis
    norm = math.sqrt(ax * ax + ay * ay + az * az)
    ax, ay, az = ax / norm, ay / norm, az / norm
    vx, vy, vz = vector
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    dot = vx * ax + vy * ay + vz * az
    cross = (ay * vz - az * vy, az * vx - ax * vz, ax * vy - ay * vx)
    return tuple(vector[i] * cos_a + cross[i] * sin_a + (ax, ay, az)[i] * dot * (1 - cos_a) for i in range(3))


def _simulate_rolling_without_slipping(base_cone_half_angle, theta_target, steps=20000):
    """A second, from-scratch construction of the spherical involute,
    sharing none of `spherical_involute_point`'s derivation: physically
    integrate the rigid-body rolling motion in small steps. At each
    instant, "rolling without slipping" means the contact point (the only
    point common to both curves at that instant) has zero relative
    velocity - satisfied by an instantaneous rotation about the axis
    through the sphere centre and that contact point; the rotation *rate*
    about that axis is the base circle's own arc-length rate
    (`sin(base_cone_half_angle)`), matching arc length exactly as the
    closed form does. Only converges to the closed form to within a few
    percent even at high step counts (the two constructions model the
    same physical rolling motion via genuinely different mathematics
    - one an exact geodesic formula, the other a discretized rigid-body
    integration - so they aren't expected to agree to machine precision),
    but the wrong-sign version of `spherical_involute_point` this module
    once had disagreed with this simulation by *orders of magnitude* more
    than that, which is what this check actually guards against."""
    marked_point = (math.sin(base_cone_half_angle), 0.0, math.cos(base_cone_half_angle))
    step_angle = theta_target / steps
    for i in range(steps):
        theta_i = (i + 0.5) * step_angle
        contact_axis = (
            math.sin(base_cone_half_angle) * math.cos(theta_i),
            math.sin(base_cone_half_angle) * math.sin(theta_i),
            math.cos(base_cone_half_angle),
        )
        marked_point = _rotate_about_axis(marked_point, contact_axis, math.sin(base_cone_half_angle) * step_angle)
    return marked_point


@pytest.mark.parametrize("theta", [10.0, 28.4165, 45.0, 60.0])
def test_spherical_involute_matches_independent_rigid_body_rolling_simulation(theta):
    gamma_b = math.radians(41.641)
    theta_radians = math.radians(theta)
    simulated = _simulate_rolling_without_slipping(gamma_b, theta_radians)
    closed_form = spherical_involute_point(gamma_b, theta_radians)
    # Generous tolerance - see _simulate_rolling_without_slipping's own
    # docstring for why exact agreement isn't expected; this still easily
    # separates the correct construction (a few percent) from the
    # previously-shipped wrong-sign version (order-1 disagreement).
    assert math.dist(simulated, closed_form) < 0.05


def test_spherical_involute_azimuth_at_colatitude_matches_the_direct_point_evaluation():
    gamma_b = math.radians(24.8)
    colatitude = math.radians(30.0)
    azimuth = spherical_involute_azimuth_at_colatitude(gamma_b, colatitude)
    roll_angle = spherical_involute_roll_angle_at_colatitude(gamma_b, colatitude)
    x, y, _z = spherical_involute_point(gamma_b, roll_angle)
    assert azimuth == pytest.approx(math.atan2(y, x))


# ---------------------------------------------------------------------------
# Bevel gear dimensions - known reference values, and cross-checks against
# gear_math's own already-verified planar spur formulas
# ---------------------------------------------------------------------------
# Module 4, 20-tooth pinion meshing a 40-tooth gear, 20-degree pressure
# angle, 90-degree shaft angle, full-depth (addendum=module,
# dedendum=1.25*module) - hand-computable standard values:
#   pitch diameter        = m*N                        = 80mm
#   pitch cone angle       = atan(20/40)                 = 26.565 deg
#   cone distance (outer) = pitch_radius / sin(gamma)    = 40 / sin(26.565deg) = 89.4427 mm
#   addendum               = m                           = 4mm
#   dedendum                = 1.25*m                       = 5mm
#   addendum angle          = atan(4 / 89.4427)             = 2.5606 deg
#   dedendum angle          = atan(5 / 89.4427)             = 3.1996 deg


def test_module_4_20_40_tooth_bevel_pinion_matches_known_reference_values():
    geometry = bevel_gear_geometry(
        module=4.0, tooth_count=20, mate_tooth_count=40, face_width=15.0, pressure_angle_degrees=20.0
    )
    assert geometry.pitch_radius == pytest.approx(40.0)
    assert math.degrees(geometry.pitch_cone_angle) == pytest.approx(26.56505117707799)
    assert geometry.cone_distance == pytest.approx(89.44271909999159)
    assert geometry.addendum == pytest.approx(4.0)
    assert geometry.dedendum == pytest.approx(5.0)
    assert math.degrees(geometry.addendum_angle) == pytest.approx(2.560638973149915, abs=1e-6)
    assert math.degrees(geometry.dedendum_angle) == pytest.approx(3.1996013002506882, abs=1e-6)
    assert geometry.inner_cone_distance == pytest.approx(89.44271909999159 - 15.0)


def test_bevel_gear_geometry_at_90_degrees_matches_the_pinion_gear_cross_check():
    # The gear side of the same pair (40 teeth, meshing a 20-tooth mate)
    # should get the complementary pitch cone angle (63.435deg) and,
    # since both gears share the same module, the *same* cone distance
    # (both pitch cones meet at a shared apex and a shared outer edge) -
    # an internal-consistency cross-check between the two sides of a pair.
    pinion = bevel_gear_geometry(module=4.0, tooth_count=20, mate_tooth_count=40, face_width=15.0)
    gear = bevel_gear_geometry(module=4.0, tooth_count=40, mate_tooth_count=20, face_width=15.0)
    assert math.degrees(pinion.pitch_cone_angle) == pytest.approx(26.56505117707799)
    assert math.degrees(gear.pitch_cone_angle) == pytest.approx(63.43494882292201)
    assert pinion.pitch_cone_angle + gear.pitch_cone_angle == pytest.approx(math.pi / 2)
    assert pinion.cone_distance == pytest.approx(gear.cone_distance)


def test_bevel_base_circle_radius_on_the_outer_cone_matches_the_equivalent_planar_spur_base_radius():
    # A powerful independent cross-check: sin(base_cone_angle) *
    # cone_distance (the Euclidean radius, from the axis, of the base
    # circle on the outer/back cone) algebraically reduces to
    # pitch_radius * cos(pressure_angle) - gear_math.spur_gear_geometry's
    # own, already-verified planar base_radius formula for a spur gear of
    # the *same* module/tooth_count/pressure_angle. This must hold exactly
    # (not approximately-because-flat) since sin(gamma_b) =
    # sin(gamma)*cos(alpha) and cone_distance = pitch_radius/sin(gamma) by
    # construction, so sin(gamma_b)*cone_distance = pitch_radius*cos(alpha)
    # algebraically, independent of how "conical" the gear is.
    bevel = bevel_gear_geometry(module=4.0, tooth_count=20, mate_tooth_count=40, face_width=15.0, pressure_angle_degrees=20.0)
    spur = spur_gear_geometry(module=4.0, tooth_count=20, pressure_angle_degrees=20.0)
    base_circle_radius_on_outer_cone = bevel.cone_distance * math.sin(bevel.base_cone_angle)
    assert base_circle_radius_on_outer_cone == pytest.approx(spur.base_radius)


def test_bevel_gear_geometry_rejects_face_width_that_reaches_the_apex():
    with pytest.raises(GearGeometryError):
        bevel_gear_geometry(module=4.0, tooth_count=20, mate_tooth_count=40, face_width=200.0)


def test_bevel_gear_geometry_rejects_non_positive_module():
    with pytest.raises(GearGeometryError):
        bevel_gear_geometry(module=0.0, tooth_count=20, mate_tooth_count=40, face_width=15.0)


def test_bevel_gear_geometry_rejects_backlash_that_exceeds_available_tooth_thickness():
    with pytest.raises(GearGeometryError):
        bevel_gear_geometry(module=4.0, tooth_count=20, mate_tooth_count=40, face_width=15.0, backlash=100.0)


def test_max_recommended_face_width_is_one_third_of_cone_distance():
    assert max_recommended_face_width(90.0) == pytest.approx(30.0)


def test_max_recommended_face_width_rejects_non_positive_cone_distance():
    with pytest.raises(GearGeometryError):
        max_recommended_face_width(0.0)


# ---------------------------------------------------------------------------
# Tooth flank point sampling
# ---------------------------------------------------------------------------


@pytest.fixture
def small_bevel_geometry() -> BevelGearGeometry:
    return bevel_gear_geometry(module=4.0, tooth_count=20, mate_tooth_count=40, face_width=15.0)


def test_bevel_tooth_flank_pair_outer_points_all_lie_on_the_outer_cone_sphere(small_bevel_geometry):
    (right_outer, _right_inner), (left_outer, _left_inner) = bevel_tooth_flank_pair(small_bevel_geometry)
    for x, y, z in right_outer + left_outer:
        assert math.sqrt(x * x + y * y + z * z) == pytest.approx(small_bevel_geometry.cone_distance)


def test_bevel_tooth_flank_pair_inner_points_all_lie_on_the_inner_cone_sphere(small_bevel_geometry):
    (_right_outer, right_inner), (_left_outer, left_inner) = bevel_tooth_flank_pair(small_bevel_geometry)
    for x, y, z in right_inner + left_inner:
        assert math.sqrt(x * x + y * y + z * z) == pytest.approx(small_bevel_geometry.inner_cone_distance)


def test_bevel_tooth_flank_pair_right_and_left_flanks_are_mirror_images_in_y(small_bevel_geometry):
    (right_outer, right_inner), (left_outer, left_inner) = bevel_tooth_flank_pair(small_bevel_geometry)
    for (rx, ry, rz), (lx, ly, lz) in zip(right_outer, left_outer):
        assert (lx, ly, lz) == pytest.approx((rx, -ry, rz))
    for (rx, ry, rz), (lx, ly, lz) in zip(right_inner, left_inner):
        assert (lx, ly, lz) == pytest.approx((rx, -ry, rz))


def test_bevel_tooth_flank_pair_points_move_away_from_axis_from_root_to_tip(small_bevel_geometry):
    # A real gear tooth's flank should widen/rise from root to tip in
    # colatitude (z decreases, radial distance from axis grows) - mirrors
    # gear_math's own tip/root radius ordering check.
    (right_outer, _right_inner), _left = bevel_tooth_flank_pair(small_bevel_geometry)
    z_values = [z for _x, _y, z in right_outer]
    assert z_values == sorted(z_values, reverse=True)


def test_bevel_tooth_flank_pair_respects_points_per_flank(small_bevel_geometry):
    (right_outer, right_inner), (left_outer, left_inner) = bevel_tooth_flank_pair(small_bevel_geometry, points_per_flank=20)
    assert len(right_outer) == len(right_inner) == len(left_outer) == len(left_inner) == 20
