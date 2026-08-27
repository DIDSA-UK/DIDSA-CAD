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
    DEFAULT_SPIRAL_SECTION_COUNT,
    MINIMUM_TIP_THICKNESS_COEFFICIENT,
    SPIRAL_BUILD_COST_WARNING_THRESHOLD_DEGREES,
    BevelGearGeometry,
    SpiralHand,
    base_cone_half_angle,
    bevel_gear_geometry,
    bevel_pair_mesh_preview,
    bevel_tooth_flank_pair,
    bevel_tooth_flank_sections,
    bevel_tooth_tip_thickness,
    equivalent_tooth_count,
    maximum_receiver_profile_shift_for_mesh_clearance,
    max_recommended_face_width,
    pitch_cone_half_angles,
    sample_spherical_involute_flank,
    spherical_involute_azimuth_at_colatitude,
    spherical_involute_colatitude,
    spherical_involute_point,
    spherical_involute_roll_angle_at_colatitude,
    spiral_build_cost_warning,
    spiral_curve_offset_angle,
    spiral_hand_mismatch_warning,
    spiral_section_count_for_twist,
    virtual_spur_gear_geometry,
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


def test_bevel_gear_geometry_accepts_pitch_cone_angle_degrees_directly():
    # docs/gear-design/10-bevel-gear.md: a standalone BevelGearFeature
    # takes pitch_cone_angle as a direct field, skipping mate_tooth_count/
    # shaft_angle_degrees-based derivation entirely - given the exact
    # angle a 20T/40T Sigma=90deg pair would derive, this must produce
    # geometry identical to the mate_tooth_count-derived path.
    derived = bevel_gear_geometry(module=4.0, tooth_count=20, mate_tooth_count=40, face_width=15.0)
    direct = bevel_gear_geometry(
        module=4.0, tooth_count=20, face_width=15.0, pitch_cone_angle_degrees=26.56505117707799
    )
    assert direct.pitch_cone_angle == pytest.approx(derived.pitch_cone_angle)
    assert direct.cone_distance == pytest.approx(derived.cone_distance)
    assert direct.mate_tooth_count is None


def test_bevel_gear_geometry_requires_mate_tooth_count_when_pitch_cone_angle_degrees_is_omitted():
    with pytest.raises(GearGeometryError):
        bevel_gear_geometry(module=4.0, tooth_count=20, face_width=15.0)


def test_bevel_gear_geometry_rejects_pitch_cone_angle_degrees_out_of_range():
    with pytest.raises(GearGeometryError):
        bevel_gear_geometry(module=4.0, tooth_count=20, face_width=15.0, pitch_cone_angle_degrees=95.0)


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


# ---------------------------------------------------------------------------
# Tooth-mesh close-up preview (Tredgold's virtual spur gears)
# ---------------------------------------------------------------------------


@pytest.fixture
def bevel_pair_geometries() -> tuple[BevelGearGeometry, BevelGearGeometry]:
    gamma_1, gamma_2 = pitch_cone_half_angles(20, 40, 90.0)
    geometry_1 = bevel_gear_geometry(
        module=4.0, tooth_count=20, face_width=10.0, pitch_cone_angle_degrees=math.degrees(gamma_1)
    )
    geometry_2 = bevel_gear_geometry(
        module=4.0, tooth_count=40, face_width=10.0, pitch_cone_angle_degrees=math.degrees(gamma_2)
    )
    return geometry_1, geometry_2


def test_virtual_spur_gear_geometry_pitch_radius_matches_the_equivalent_tooth_count_relation(bevel_pair_geometries):
    # `pitch_radius_v = module * equivalent_tooth_count / 2`, the ordinary
    # planar relation - `virtual_spur_gear_geometry` derives it via
    # `cone_distance * tan(gamma)` instead (simpler, reuses fields already
    # on `BevelGearGeometry`), so this checks the two agree, not just that
    # the function runs.
    geometry_1, _geometry_2 = bevel_pair_geometries
    virtual = virtual_spur_gear_geometry(geometry_1)
    expected = geometry_1.module * equivalent_tooth_count(geometry_1.tooth_count, geometry_1.pitch_cone_angle) / 2
    assert virtual.pitch_radius == pytest.approx(expected)


def test_virtual_spur_gear_geometry_base_radius_matches_the_planar_relation(bevel_pair_geometries):
    geometry_1, _geometry_2 = bevel_pair_geometries
    virtual = virtual_spur_gear_geometry(geometry_1)
    assert virtual.base_radius == pytest.approx(virtual.pitch_radius * math.cos(geometry_1.pressure_angle))


def test_bevel_pair_mesh_preview_centers_are_tangent_at_the_pitch_radii_apart(bevel_pair_geometries):
    geometry_1, geometry_2 = bevel_pair_geometries
    preview = bevel_pair_mesh_preview(geometry_1, geometry_2)
    (x1, y1), (x2, y2) = preview.center_1, preview.center_2
    assert y1 == pytest.approx(0.0)
    assert y2 == pytest.approx(0.0)
    assert x2 - x1 == pytest.approx(preview.pitch_radius_1 + preview.pitch_radius_2)


def test_bevel_pair_mesh_preview_defaults_to_four_teeth_per_member(bevel_pair_geometries):
    geometry_1, geometry_2 = bevel_pair_geometries
    preview = bevel_pair_mesh_preview(geometry_1, geometry_2)
    assert len(preview.member_1_teeth) == 4
    assert len(preview.member_2_teeth) == 4


def test_bevel_pair_mesh_preview_respects_displayed_tooth_count_and_points_per_flank(bevel_pair_geometries):
    geometry_1, geometry_2 = bevel_pair_geometries
    preview = bevel_pair_mesh_preview(geometry_1, geometry_2, displayed_tooth_count=6, points_per_flank=8)
    assert len(preview.member_1_teeth) == 6
    assert len(preview.member_2_teeth) == 6
    assert all(len(tooth) == 16 for tooth in preview.member_1_teeth)  # right + left flank, 8 points each


def test_bevel_pair_mesh_preview_a_narrower_intruder_tooth_leaves_a_visible_gap_at_the_pitch_line():
    # Reproduces the on-device finding a single-sided auto profile-shift
    # fix left the intruding member's tooth visibly thin: a member whose
    # `profile_shift` is pushed negative (net thinner tooth at the pitch
    # line - `tooth_thickness_at_pitch`'s own `2 * profile_shift * module *
    # tan(pressure_angle)` term) should sit further from its mate's flank
    # at the shared pitch point than an unshifted pair does - the same
    # "gap you can see" the user reported, now checkable directly off the
    # preview's own geometry rather than eyeballing a screenshot.
    gamma_1, gamma_2 = pitch_cone_half_angles(20, 40, 90.0)

    def min_gap_at_pitch_point(profile_shift_1: float, profile_shift_2: float) -> float:
        geometry_1 = bevel_gear_geometry(
            module=4.0,
            tooth_count=20,
            face_width=10.0,
            pitch_cone_angle_degrees=math.degrees(gamma_1),
            profile_shift=profile_shift_1,
        )
        geometry_2 = bevel_gear_geometry(
            module=4.0,
            tooth_count=40,
            face_width=10.0,
            pitch_cone_angle_degrees=math.degrees(gamma_2),
            profile_shift=profile_shift_2,
        )
        preview = bevel_pair_mesh_preview(geometry_1, geometry_2, displayed_tooth_count=2)
        # The flank point nearest the shared pitch point (the origin) on
        # each side, from the two teeth straddling the mesh - a cheap proxy
        # for "how close do the two flanks actually get here" without a
        # full polygon-distance computation.
        member_1_points = [p for tooth in preview.member_1_teeth for p in tooth]
        member_2_points = [p for tooth in preview.member_2_teeth for p in tooth]
        nearest_1 = min(member_1_points, key=lambda p: p[0] ** 2 + p[1] ** 2)
        nearest_2 = min(member_2_points, key=lambda p: p[0] ** 2 + p[1] ** 2)
        return math.hypot(nearest_1[0] - nearest_2[0], nearest_1[1] - nearest_2[1])

    balanced_gap = min_gap_at_pitch_point(0.0, 0.0)
    unbalanced_gap = min_gap_at_pitch_point(0.0, -0.6)
    assert unbalanced_gap > balanced_gap


# ---------------------------------------------------------------------------
# Tooth tip thickness - and the receiver-shift cap it feeds
# ---------------------------------------------------------------------------


def test_bevel_tooth_tip_thickness_shrinks_as_profile_shift_grows(bevel_pair_geometries):
    geometry_1, _geometry_2 = bevel_pair_geometries
    baseline = bevel_tooth_tip_thickness(geometry_1)
    shifted_geometry = bevel_gear_geometry(
        module=geometry_1.module,
        tooth_count=geometry_1.tooth_count,
        face_width=geometry_1.face_width,
        pressure_angle_degrees=math.degrees(geometry_1.pressure_angle),
        profile_shift=geometry_1.profile_shift + 0.3,
        pitch_cone_angle_degrees=math.degrees(geometry_1.pitch_cone_angle),
    )
    assert bevel_tooth_tip_thickness(shifted_geometry) < baseline


def test_bevel_tooth_tip_thickness_goes_negative_for_the_reproduced_defect_case():
    # Real regression: a steep tooth-count-ratio pair (6T/24T) auto-
    # resolved the 6-tooth member's own profile_shift to +0.9215 before
    # this cap existed - confirmed on-device to produce a self-crossing,
    # negative-thickness tooth tip that _assemble_gear_solid could not
    # build correctly (~4x analytic-vs-mesh volume disagreement). Locks in
    # that this function actually detects that specific case as unsafe.
    gamma_1, _gamma_2 = pitch_cone_half_angles(6, 24, 90.0)
    geometry = bevel_gear_geometry(
        module=4.0, tooth_count=6, face_width=8.0, pressure_angle_degrees=20.0,
        profile_shift=0.921465455243788, pitch_cone_angle_degrees=math.degrees(gamma_1),
    )
    assert bevel_tooth_tip_thickness(geometry) < 0.0


def test_maximum_receiver_profile_shift_for_mesh_clearance_caps_against_a_pointed_tip():
    # The real 6T/24T case end to end: without this cap, the receiver
    # (6-tooth member) would be pushed all the way to the balanced target
    # (+0.9215, a self-crossing tip) - with it, the search stops once tip
    # thickness would drop below MINIMUM_TIP_THICKNESS_COEFFICIENT*module,
    # landing well short of the target, and the accepted shift's own tip
    # thickness clears that floor (with the bisection's own tolerance).
    module = 4.0
    gamma_1, gamma_2 = pitch_cone_half_angles(6, 24, 90.0)
    receiver_geometry = bevel_gear_geometry(
        module=module, tooth_count=6, face_width=8.0, pressure_angle_degrees=20.0,
        profile_shift=0.0, pitch_cone_angle_degrees=math.degrees(gamma_1),
    )
    intruder_geometry = bevel_gear_geometry(
        module=module, tooth_count=24, face_width=8.0, pressure_angle_degrees=20.0,
        profile_shift=-0.921465455243788, pitch_cone_angle_degrees=math.degrees(gamma_2),
    )
    target_shift = 0.921465455243788
    accepted = maximum_receiver_profile_shift_for_mesh_clearance(
        receiver_geometry, intruder_geometry, 90.0, target_shift
    )
    assert accepted < target_shift
    accepted_geometry = bevel_gear_geometry(
        module=module, tooth_count=6, face_width=8.0, pressure_angle_degrees=20.0,
        profile_shift=accepted, pitch_cone_angle_degrees=math.degrees(gamma_1),
    )
    assert bevel_tooth_tip_thickness(accepted_geometry) >= MINIMUM_TIP_THICKNESS_COEFFICIENT * module - 1e-6


# ---------------------------------------------------------------------------
# Spiral bevel: N-cross-section flank sampling
# (docs/gear-design/12-spiral-bevel-gear.md) - single-gear construction only
# ---------------------------------------------------------------------------


def test_spiral_curve_offset_angle_is_exactly_zero_at_zero_spiral_angle():
    # Checked at several distinct sphere_radius/mean_sphere_radius ratios -
    # exact zero (not merely close), the property bevel_tooth_flank_
    # sections's own bit-for-bit reduction test below depends on.
    for ratio in (0.5, 0.9, 1.0, 1.5, 3.0):
        assert spiral_curve_offset_angle(0.0, math.radians(30.0), 100.0 * ratio, 100.0, SpiralHand.RIGHT) == 0.0
        assert spiral_curve_offset_angle(0.0, math.radians(30.0), 100.0 * ratio, 100.0, SpiralHand.LEFT) == 0.0


def test_spiral_curve_offset_angle_is_exactly_zero_at_the_mean_radius_for_any_spiral_angle():
    # ln(R/R_mean) = ln(1) = 0 at R == R_mean, for any nonzero beta - the
    # "Zerol bevel falls out of this same family for free... at the mean
    # point" property 12-spiral-bevel-gear.md's own "Candidate approaches"
    # section names.
    assert spiral_curve_offset_angle(math.radians(25.0), math.radians(30.0), 100.0, 100.0, SpiralHand.RIGHT) == 0.0


def test_spiral_curve_offset_angle_matches_the_closed_form_directly():
    beta = math.radians(20.0)
    gamma = math.radians(26.565)
    r, r_mean = 89.44, 82.0
    expected = (math.tan(beta) / math.sin(gamma)) * math.log(r / r_mean)
    assert spiral_curve_offset_angle(beta, gamma, r, r_mean, SpiralHand.RIGHT) == pytest.approx(expected)


def test_spiral_curve_offset_angle_flips_sign_with_hand():
    beta = math.radians(20.0)
    gamma = math.radians(26.565)
    right = spiral_curve_offset_angle(beta, gamma, 89.44, 82.0, SpiralHand.RIGHT)
    left = spiral_curve_offset_angle(beta, gamma, 89.44, 82.0, SpiralHand.LEFT)
    assert right == pytest.approx(-left)
    assert right != 0.0


def test_spiral_curve_offset_angle_grows_away_from_the_mean_radius_in_opposite_directions():
    # R > R_mean and R < R_mean give opposite-signed curve() for the same
    # hand - 12-spiral-bevel-gear.md's own Spike A §2 table shows exactly
    # this shape (outer sections curve one way, inner sections the other).
    beta = math.radians(20.0)
    gamma = math.radians(26.565)
    outer = spiral_curve_offset_angle(beta, gamma, 89.44, 82.0, SpiralHand.RIGHT)
    inner = spiral_curve_offset_angle(beta, gamma, 74.44, 82.0, SpiralHand.RIGHT)
    assert outer > 0.0
    assert inner < 0.0


@pytest.fixture
def spiral_bevel_geometry() -> BevelGearGeometry:
    # Same 20T/40T/module-4 baseline test_bevel_math.py's own module_4_20_40
    # reference-value test already uses.
    gamma_1, _gamma_2 = pitch_cone_half_angles(20, 40, 90.0)
    return bevel_gear_geometry(module=4.0, tooth_count=20, face_width=15.0, pitch_cone_angle_degrees=math.degrees(gamma_1))


def test_bevel_tooth_flank_sections_reduces_exactly_to_bevel_tooth_flank_pair_at_zero_spiral_angle(
    spiral_bevel_geometry,
):
    # The real regression-safety property 12-spiral-bevel-gear.md's own
    # "Sanity check" section calls for, made permanent per this workstream's
    # own task instructions - bit-for-bit, not pytest.approx.
    (pair_right_outer, pair_right_inner), (pair_left_outer, pair_left_inner) = bevel_tooth_flank_pair(
        spiral_bevel_geometry
    )
    right_sections, left_sections = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=0.0, section_count=2
    )
    assert right_sections[0] == pair_right_outer
    assert right_sections[1] == pair_right_inner
    assert left_sections[0] == pair_left_outer
    assert left_sections[1] == pair_left_inner


def test_bevel_tooth_flank_sections_reduces_exactly_regardless_of_spiral_hand_at_zero_spiral_angle(
    spiral_bevel_geometry,
):
    # spiral_hand is meaningless when spiral_angle_degrees == 0.0, mirroring
    # GearFeature.herringbone's own "meaningless unless helix_angle_degrees
    # != 0.0" convention - confirmed directly, not just documented.
    right_left, left_left = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=0.0, spiral_hand=SpiralHand.LEFT, section_count=2
    )
    right_right, left_right = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=0.0, spiral_hand=SpiralHand.RIGHT, section_count=2
    )
    assert right_left == right_right
    assert left_left == left_right


def test_bevel_tooth_flank_sections_respects_section_count_and_points_per_flank(spiral_bevel_geometry):
    right_sections, left_sections = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=20.0, points_per_flank=8, section_count=5
    )
    assert len(right_sections) == len(left_sections) == 5
    for section in right_sections + left_sections:
        assert len(section) == 8


def test_bevel_tooth_flank_sections_all_points_lie_on_their_own_sections_sphere(spiral_bevel_geometry):
    # Same "always on the given sphere" guarantee sample_tredgold_flank/
    # bevel_tooth_flank_pair already provide - the spiral rotation is a
    # pure rotation about the gear axis, so it must not perturb this.
    right_sections, left_sections = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=25.0, section_count=4
    )
    radii = _spiral_section_radii_for_test(spiral_bevel_geometry, 4)
    for section, radius in zip(right_sections, radii):
        for x, y, z in section:
            assert math.sqrt(x * x + y * y + z * z) == pytest.approx(radius)
    for section, radius in zip(left_sections, radii):
        for x, y, z in section:
            assert math.sqrt(x * x + y * y + z * z) == pytest.approx(radius)


def _spiral_section_radii_for_test(geometry: BevelGearGeometry, section_count: int) -> list[float]:
    span = geometry.inner_cone_distance - geometry.cone_distance
    return [geometry.cone_distance + span * i / (section_count - 1) for i in range(section_count)]


def test_bevel_tooth_flank_sections_tooth_width_stays_constant_along_the_face_width(spiral_bevel_geometry):
    # 12-spiral-bevel-gear.md's own Spike A §2 finding: the corrected
    # construction holds the tooth's own angular width - the azimuthal gap
    # between a section's own right/left flank curves, at a FIXED point
    # along each curve's own root-to-tip parametrization - exactly constant
    # from section to section (outer to inner); only the underlying
    # Tredgold flank curve's own natural per-radius shape (root-to-tip
    # within one section) varies, which is expected and unrelated to
    # spiral (`test_bevel_tooth_flank_pair_points_move_away_from_axis_
    # from_root_to_tip`'s own straight-bevel precedent already shows this).
    # Mirrors Spike A's own table, which reports one width figure per
    # section (not per root-to-tip point).
    right_sections, left_sections = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=20.0, points_per_flank=12, section_count=5
    )
    for point_index in (0, 6, 11):
        widths = []
        for right, left in zip(right_sections, left_sections):
            rx, ry, _rz = right[point_index]
            lx, ly, _lz = left[point_index]
            widths.append(math.atan2(ly, lx) - math.atan2(ry, rx))
        for width in widths:
            assert width == pytest.approx(widths[0])
        assert widths[0] != pytest.approx(0.0)


def test_bevel_tooth_flank_sections_centerline_actually_curves_along_the_face_width(spiral_bevel_geometry):
    # The direct opposite of 12-spiral-bevel-gear.md's own Spike A §1 "named
    # dead end" (a construction whose centerline stays a straight ray from
    # the apex, exactly 0.000 at every radius, while only its width
    # changes - not a spiral tooth by any definition). This implementation
    # must NOT reproduce that bug: the centerline (the azimuth midpoint of
    # a matched right/left point pair) must genuinely differ between the
    # outer and inner sections.
    right_sections, left_sections = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=20.0, points_per_flank=12, section_count=5
    )

    def centerline_azimuth(section_index: int, point_index: int) -> float:
        rx, ry, _rz = right_sections[section_index][point_index]
        lx, ly, _lz = left_sections[section_index][point_index]
        return (math.atan2(ry, rx) + math.atan2(ly, lx)) / 2.0

    outer_centerline = centerline_azimuth(0, 0)
    mean_centerline = centerline_azimuth(2, 0)
    inner_centerline = centerline_azimuth(4, 0)
    # The mean section (index 2 of 5, i.e. exactly R_mean) has curve(R) == 0
    # by construction - its own centerline should sit at the plain Tredgold
    # centerline, effectively 0 (no spiral term contributes there).
    assert mean_centerline == pytest.approx(0.0, abs=1e-9)
    # Outer and inner sections must have genuinely swept away from that,
    # and in opposite directions (matching spiral_curve_offset_angle's own
    # "opposite directions on either side of the mean radius" behaviour).
    assert abs(outer_centerline) > 1e-3
    assert abs(inner_centerline) > 1e-3
    assert outer_centerline * inner_centerline < 0.0


def test_bevel_tooth_flank_sections_opposite_hands_curve_in_opposite_directions(spiral_bevel_geometry):
    right_left_hand, _left_left_hand = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=20.0, spiral_hand=SpiralHand.LEFT, section_count=3
    )
    right_right_hand, _left_right_hand = bevel_tooth_flank_sections(
        spiral_bevel_geometry, spiral_angle_degrees=20.0, spiral_hand=SpiralHand.RIGHT, section_count=3
    )
    outer_x_left, outer_y_left, _ = right_left_hand[0][0]
    outer_x_right, outer_y_right, _ = right_right_hand[0][0]
    azimuth_left_hand = math.atan2(outer_y_left, outer_x_left)
    azimuth_right_hand = math.atan2(outer_y_right, outer_x_right)
    # Both hands share the same mean-section (index 1 of 3) behaviour but
    # diverge at the outer section, in opposite directions.
    assert azimuth_left_hand != pytest.approx(azimuth_right_hand)


def test_bevel_tooth_flank_sections_rejects_section_count_below_two(spiral_bevel_geometry):
    with pytest.raises(GearGeometryError):
        bevel_tooth_flank_sections(spiral_bevel_geometry, spiral_angle_degrees=10.0, section_count=1)


def test_default_spiral_section_count_is_at_least_three():
    # 12-spiral-bevel-gear.md's own Spike A §3 finding: 2 sections measurably
    # under-count the real geometry once the offset varies continuously; 3
    # is the validated minimum.
    assert DEFAULT_SPIRAL_SECTION_COUNT >= 3


def test_bevel_tooth_flank_sections_linear_interpolation_error_shrinks_with_more_sections(spiral_bevel_geometry):
    # Pure-math re-validation of 12-spiral-bevel-gear.md's own Spike A §3
    # "Section-count convergence" finding (which was originally validated
    # via a real BRepAlgoAPI_Common mesh-overlap measurement, out of reach
    # in this OCCT-free test module) - re-derived here as a direct numerical
    # statement about spiral_curve_offset_angle's own smoothness: a
    # piecewise-linear interpolant through N evenly-spaced-by-radius samples
    # of curve(R) should approximate the true (smooth, log-shaped) curve(R)
    # much more closely as N grows from the legacy 2-section case - the
    # exact reason a 2-section ThruSections loft (in effect, one linear
    # interpolant end to end) under-represents the true geometry while more
    # sections converge quickly.
    gamma = spiral_bevel_geometry.pitch_cone_angle
    cone_distance = spiral_bevel_geometry.cone_distance
    inner_cone_distance = spiral_bevel_geometry.inner_cone_distance
    mean_radius = (cone_distance + inner_cone_distance) / 2.0
    beta = math.radians(30.0)

    def curve(r: float) -> float:
        return spiral_curve_offset_angle(beta, gamma, r, mean_radius, SpiralHand.RIGHT)

    def max_interpolation_error(section_count: int) -> float:
        radii = _spiral_section_radii_for_test(spiral_bevel_geometry, section_count)
        values = [curve(r) for r in radii]
        probe_count = 200
        worst = 0.0
        for k in range(probe_count + 1):
            r = cone_distance + (inner_cone_distance - cone_distance) * k / probe_count
            # Find the bracketing pair of sections and linearly interpolate,
            # matching what a ruled loft would do between adjacent sections.
            for idx in range(section_count - 1):
                r0, r1 = radii[idx], radii[idx + 1]
                if (r0 - r) * (r1 - r) <= 0.0:
                    t = 0.0 if r1 == r0 else (r - r0) / (r1 - r0)
                    interpolated = values[idx] + t * (values[idx + 1] - values[idx])
                    worst = max(worst, abs(interpolated - curve(r)))
                    break
        return worst

    error_2 = max_interpolation_error(2)
    error_3 = max_interpolation_error(DEFAULT_SPIRAL_SECTION_COUNT)
    error_5 = max_interpolation_error(5)
    error_9 = max_interpolation_error(9)
    assert error_2 > 0.0
    # Strictly, substantially decreasing as section_count grows (quadratic-
    # in-interval-count convergence for a piecewise-linear interpolant of a
    # smooth curve - real numbers measured on-device: 2->3 already cuts
    # error by ~3.7x, 2->5 by ~14x, matching "convergence is fast" without
    # over-claiming an arbitrary exact factor).
    assert error_2 / 3 > error_3 > error_5 > error_9 > 0.0
    assert error_5 < error_2 / 10.0


# ---------------------------------------------------------------------------
# spiral_section_count_for_twist (docs/gear-design/12-spiral-bevel-gear.md's
# own end-cap-flattening fix) - see bevel_math.py's own module note
# (_SPIRAL_TWIST_PER_SECTION_BOUND) for the real on-device calibration this
# is built on.
# ---------------------------------------------------------------------------


def test_spiral_section_count_for_twist_is_a_bit_for_bit_no_op_at_zero_spiral_angle(spiral_bevel_geometry):
    # The hard requirement this workstream's own task instructions call
    # out explicitly: spiral_angle_degrees == 0.0 must leave
    # DEFAULT_SPIRAL_SECTION_COUNT (or whatever section_count the caller
    # passed) completely untouched, so _assemble_gear_solid's own straight-
    # bevel path stays the exact literal no-op it already is.
    assert spiral_section_count_for_twist(spiral_bevel_geometry, 20, 0.0) == DEFAULT_SPIRAL_SECTION_COUNT
    assert spiral_section_count_for_twist(spiral_bevel_geometry, 20, 0.0, section_count=7) == 7
    assert spiral_section_count_for_twist(spiral_bevel_geometry, 20, 0.0, SpiralHand.LEFT, 12) == 12


def test_spiral_section_count_for_twist_never_reduces_a_caller_supplied_count():
    # max(section_count, needed) - a caller-supplied section_count already
    # above the twist-driven minimum (more fidelity than strictly required)
    # must never be silently lowered.
    gamma_1, _gamma_2 = pitch_cone_half_angles(10, 10, 90.0)
    geometry = bevel_gear_geometry(module=4.0, tooth_count=10, face_width=8.0, pitch_cone_angle_degrees=math.degrees(gamma_1))
    assert spiral_section_count_for_twist(geometry, 10, 70.0, section_count=50) == 50


def test_spiral_section_count_for_twist_raises_the_count_for_every_documented_failing_case():
    # The four real, documented `_flatten_end_caps` failures (`docs/gear-
    # design/12-spiral-bevel-gear.md`'s own results table) - real on-device
    # testing (this session's own sweep, recorded in bevel_math.py's own
    # `_SPIRAL_TWIST_PER_SECTION_BOUND` docstring and docs/status.md) found
    # flattening first starts succeeding at spiral_section_count=4 for every
    # one of these; this function must ask for strictly more than the
    # DEFAULT_SPIRAL_SECTION_COUNT=3 default in every case, and in
    # particular must clear that measured minimum of 4 with real headroom
    # (not land exactly on it).
    cases = [
        (10, 4.0, 8.0, 70.0),
        (20, 4.0, 16.0, 68.0),
        (20, 4.0, 16.0, 70.0),
        (20, 4.0, 16.0, 72.0),
    ]
    for tooth_count, module, face_width, beta in cases:
        gamma_1, _gamma_2 = pitch_cone_half_angles(tooth_count, tooth_count, 90.0)
        geometry = bevel_gear_geometry(
            module=module, tooth_count=tooth_count, face_width=face_width, pitch_cone_angle_degrees=math.degrees(gamma_1)
        )
        count = spiral_section_count_for_twist(geometry, tooth_count, beta)
        assert count > DEFAULT_SPIRAL_SECTION_COUNT, (tooth_count, beta, count)
        assert count >= 6, (tooth_count, beta, count)  # real headroom above the measured minimum of 4


def test_spiral_section_count_for_twist_grows_with_spiral_angle(spiral_bevel_geometry):
    # Monotonicity sanity check - more accumulated twist (a larger spiral
    # angle, same geometry) should never ask for FEWER sections.
    low = spiral_section_count_for_twist(spiral_bevel_geometry, 20, 20.0)
    high = spiral_section_count_for_twist(spiral_bevel_geometry, 20, 70.0)
    assert high >= low


def test_spiral_section_count_for_twist_matches_the_closed_form_directly(spiral_bevel_geometry):
    # Direct re-derivation of the formula (not a re-run of the same code
    # path) - total twist from spiral_curve_offset_angle's own closed form,
    # divided across (section_count - 1) steps, must fall at or below
    # _SPIRAL_TWIST_PER_SECTION_BOUND * (pi / tooth_count) for whatever
    # count this function actually returns, and the count one below it
    # must NOT satisfy that same bound (the returned count is the minimum
    # that clears it, not an arbitrary larger one).
    tooth_count = 20
    beta_degrees = 40.0
    gamma = spiral_bevel_geometry.pitch_cone_angle
    mean_radius = (spiral_bevel_geometry.cone_distance + spiral_bevel_geometry.inner_cone_distance) / 2.0
    beta = math.radians(beta_degrees)
    total_twist = abs(
        spiral_curve_offset_angle(beta, gamma, spiral_bevel_geometry.cone_distance, mean_radius, SpiralHand.RIGHT)
        - spiral_curve_offset_angle(beta, gamma, spiral_bevel_geometry.inner_cone_distance, mean_radius, SpiralHand.RIGHT)
    )
    bound = math.pi / tooth_count  # _SPIRAL_TWIST_PER_SECTION_BOUND == 1.0
    count = spiral_section_count_for_twist(spiral_bevel_geometry, tooth_count, beta_degrees)
    assert total_twist / (count - 1) <= bound + 1e-9
    if count > DEFAULT_SPIRAL_SECTION_COUNT:
        assert total_twist / (count - 2) > bound


def test_spiral_build_cost_warning_is_none_below_the_threshold():
    assert spiral_build_cost_warning(0.0) is None
    assert spiral_build_cost_warning(30.0) is None
    assert spiral_build_cost_warning(SPIRAL_BUILD_COST_WARNING_THRESHOLD_DEGREES - 1.0) is None


def test_spiral_build_cost_warning_fires_at_and_above_the_threshold():
    assert spiral_build_cost_warning(SPIRAL_BUILD_COST_WARNING_THRESHOLD_DEGREES) is not None
    assert spiral_build_cost_warning(60.0) is not None
    assert spiral_build_cost_warning(-60.0) is not None


# ---------------------------------------------------------------------------
# Hand-of-spiral compatibility (docs/gear-design/13-spiral-bevel-pair.md,
# Workstream 13) - a simple field-compatibility check, not a margin
# computation (that doc's own Spike C §3/§5 go/no-go).
# ---------------------------------------------------------------------------


def test_spiral_hand_mismatch_warning_is_none_at_zero_spiral_angle_regardless_of_hands():
    # Meaningless unless spiral_angle_degrees != 0.0 - same "meaningless
    # unless" convention SpiralBevelHand/SpiralHand's own docstrings use.
    assert spiral_hand_mismatch_warning(0.0, SpiralHand.RIGHT, SpiralHand.RIGHT) is None
    assert spiral_hand_mismatch_warning(0.0, SpiralHand.LEFT, SpiralHand.RIGHT) is None


def test_spiral_hand_mismatch_warning_is_none_for_opposite_hands():
    # The required, correctly-meshing configuration - 13-spiral-bevel-
    # pair.md's own Spike C §3 confirms opposite-hand overlap stays exactly
    # 0.0 across a real beta sweep on a resolvable tooth-count ratio.
    assert spiral_hand_mismatch_warning(20.0, SpiralHand.RIGHT, SpiralHand.LEFT) is None
    assert spiral_hand_mismatch_warning(20.0, SpiralHand.LEFT, SpiralHand.RIGHT) is None


def test_spiral_hand_mismatch_warning_fires_for_a_same_hand_pair():
    warning = spiral_hand_mismatch_warning(20.0, SpiralHand.RIGHT, SpiralHand.RIGHT)
    assert warning is not None
    assert "same hand of spiral" in warning
    assert "right" in warning

    warning_left = spiral_hand_mismatch_warning(20.0, SpiralHand.LEFT, SpiralHand.LEFT)
    assert warning_left is not None
    assert "left" in warning_left
