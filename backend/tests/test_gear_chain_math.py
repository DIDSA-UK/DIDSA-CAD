"""Reference-value tests for `app.document.gear_chain_math` - no OCCT
needed, same as `test_gear_math.py`. Checks against Workstream 5 Spike 1's
own hand-verified worked example (`docs/gear-design/05-gear-chain-and-
planetary.md`, "Spike 1 findings"), not just "it runs".
"""

import math

import pytest

from app.document.gear_chain_math import (
    BoundingCircle,
    BoundingRect,
    ChainMemberKind,
    ChainMemberSpec,
    ChainStageSpec,
    GearGeometryError,
    check_chain_interference,
    chain_overall_ratio,
    circle_circle_gap,
    circle_rect_gap,
    compound_axial_overlap,
    compound_transition_ratio,
    mesh_link_ratio,
    meshing_phase_base,
    pitch_radius,
    propagate_meshing_phase,
    rack_meshing_phase_base,
    rect_rect_gap,
    resolve_chain,
    resolve_chain_positions,
    thin_member_warning,
)


def _external(module: float, teeth: int, face_width: float = 5.0, pressure_angle_degrees: float = 20.0) -> ChainMemberSpec:
    return ChainMemberSpec(ChainMemberKind.EXTERNAL, module, pressure_angle_degrees, teeth, face_width)


def _internal(
    module: float, teeth: int, outer_diameter: float, face_width: float = 5.0, pressure_angle_degrees: float = 20.0
) -> ChainMemberSpec:
    return ChainMemberSpec(ChainMemberKind.INTERNAL, module, pressure_angle_degrees, teeth, face_width, outer_diameter)


def _rack(module: float, teeth: int, face_width: float = 5.0, pressure_angle_degrees: float = 20.0) -> ChainMemberSpec:
    return ChainMemberSpec(ChainMemberKind.RACK, module, pressure_angle_degrees, teeth, face_width)


# ---------------------------------------------------------------------------
# Part 1: bent-path positioning - Spike 1's own 5-stage worked example
# ---------------------------------------------------------------------------

_SPIKE1_STAGES = [
    ChainStageSpec(member=_external(2.0, 20)),
    ChainStageSpec(turn_angle_degrees=0, member=_external(2.0, 15)),
    ChainStageSpec(turn_angle_degrees=90, member=_external(2.0, 10)),
    ChainStageSpec(turn_angle_degrees=-30, member=_external(2.0, 25)),
    ChainStageSpec(turn_angle_degrees=0, member=_internal(2.0, 60, outer_diameter=140.0)),
]

_SPIKE1_EXPECTED_CENTERS = [
    (0.0, 0.0),
    (35.0, 0.0),
    (60.0, 0.0),
    (60.0, 35.0),
    (77.5, 65.310889),
]
_SPIKE1_EXPECTED_SEGMENT_DIRECTIONS_DEGREES = [0.0, 0.0, 90.0, 60.0]


def test_resolve_chain_positions_matches_spike_1_worked_example():
    resolved = resolve_chain_positions(_SPIKE1_STAGES, start_direction_degrees=0.0)
    assert len(resolved) == 5

    for stage, expected_center in zip(resolved, _SPIKE1_EXPECTED_CENTERS):
        assert stage.center[0] == pytest.approx(expected_center[0], abs=1e-5)
        assert stage.center[1] == pytest.approx(expected_center[1], abs=1e-5)

    segment_directions = [
        stage.outgoing_direction for stage in resolved[:-1]
    ]
    for actual, expected_degrees in zip(segment_directions, _SPIKE1_EXPECTED_SEGMENT_DIRECTIONS_DEGREES):
        assert math.degrees(actual) == pytest.approx(expected_degrees, abs=1e-6)

    assert resolved[0].incoming_direction is None
    assert resolved[-1].outgoing_direction is None


def test_resolve_chain_positions_last_stage_centre_matches_hand_calculation():
    # 60 + 35*cos(60deg), 35 + 35*sin(60deg) - Spike 1's own hand check.
    resolved = resolve_chain_positions(_SPIKE1_STAGES, start_direction_degrees=0.0)
    expected_x = 60 + 35 * math.cos(math.radians(60))
    expected_y = 35 + 35 * math.sin(math.radians(60))
    assert resolved[-1].center[0] == pytest.approx(expected_x)
    assert resolved[-1].center[1] == pytest.approx(expected_y)


def test_resolve_chain_positions_requires_at_least_two_stages():
    with pytest.raises(GearGeometryError):
        resolve_chain_positions([ChainStageSpec(member=_external(2.0, 20))])


def test_resolve_chain_positions_rejects_mismatched_module_between_adjacent_members():
    stages = [
        ChainStageSpec(member=_external(2.0, 20)),
        ChainStageSpec(member=_external(3.0, 15)),
    ]
    with pytest.raises(GearGeometryError):
        resolve_chain_positions(stages)


def test_resolve_chain_positions_rejects_two_consecutive_racks():
    stages = [ChainStageSpec(member=_rack(2.0, 10)), ChainStageSpec(member=_rack(2.0, 10))]
    with pytest.raises(GearGeometryError):
        resolve_chain_positions(stages)


def test_rack_stage_positioned_at_neighbouring_gears_pitch_radius():
    # Spike 1's own convention: a rack's reference point sits `pitch_radius`
    # away from its one neighbouring gear's centre, along the segment
    # direction; its own bounding rect's length axis is perpendicular to
    # that direction.
    stages = [ChainStageSpec(member=_external(2.0, 20)), ChainStageSpec(member=_rack(2.0, 10))]
    resolved = resolve_chain_positions(stages, start_direction_degrees=0.0)
    gear_pitch_radius = 2.0 * 20 / 2
    assert resolved[1].center[0] == pytest.approx(gear_pitch_radius)
    assert resolved[1].center[1] == pytest.approx(0.0)

    rack_shape = resolved[1].members[0].bounding_shape
    assert isinstance(rack_shape, BoundingRect)
    # Segment direction is 0 (along +x) -> rack length axis perpendicular
    # to it, i.e. angle = 90 degrees.
    assert math.degrees(rack_shape.angle) % 180 == pytest.approx(90.0, abs=1e-6)


# ---------------------------------------------------------------------------
# Part 2: interference checking - Spike 1's own worked gap-function numbers
# ---------------------------------------------------------------------------


def test_circle_circle_gap_worked_examples():
    a = BoundingCircle((0, 0), 22)
    assert circle_circle_gap(a, BoundingCircle((50, 0), 22)) == pytest.approx(6.0)
    assert circle_circle_gap(a, BoundingCircle((44.1, 0), 22)) == pytest.approx(0.1, abs=1e-9)
    assert circle_circle_gap(a, BoundingCircle((40, 0), 22)) == pytest.approx(-4.0)


def test_circle_rect_gap_worked_examples():
    # 10-tooth module-2 rack: half_length=31.4159, half_width=2.25, rect
    # centred at (0, -0.25).
    rect = BoundingRect((0, -0.25), 0.0, 31.4159, 2.25)
    assert circle_rect_gap(BoundingCircle((0, 24), 22), rect) == pytest.approx(0.0, abs=1e-9)
    assert circle_rect_gap(BoundingCircle((0, 100), 22), rect) == pytest.approx(76.0)


def test_rect_rect_gap_worked_examples():
    r1 = BoundingRect((0, 0), 0.0, 100, 2.25)
    assert rect_rect_gap(r1, BoundingRect((0, 10), 0.0, 100, 2.25)) == pytest.approx(5.5)
    assert rect_rect_gap(r1, BoundingRect((0, 4.5), 0.0, 100, 2.25)) == pytest.approx(0.0, abs=1e-9)
    assert rect_rect_gap(r1, BoundingRect((0, 3), 0.0, 100, 2.25)) == pytest.approx(-1.5)


def test_check_chain_interference_reproduces_spike_1_worked_example():
    chain = resolve_chain(_SPIKE1_STAGES, start_direction_degrees=0.0)
    findings = {(f.stage_index_a, f.stage_index_b) for f in chain.interference_findings}
    assert findings == {(1, 3), (1, 4), (2, 4)}
    assert all(f.kind == "overlap" for f in chain.interference_findings)


def test_check_chain_interference_skips_every_consecutive_pair():
    resolved = resolve_chain_positions(_SPIKE1_STAGES)
    findings = check_chain_interference(resolved)
    consecutive_pairs = {(i, i + 1) for i in range(len(_SPIKE1_STAGES) - 1)}
    found_pairs = {(f.stage_index_a, f.stage_index_b) for f in findings}
    assert not (found_pairs & consecutive_pairs)


def test_check_chain_interference_clear_case_reports_nothing():
    # A straight 3-stage chain of small, well-separated external gears -
    # genuinely clear, not just "no consecutive pairs to check".
    stages = [
        ChainStageSpec(member=_external(1.0, 12)),
        ChainStageSpec(member=_external(1.0, 12)),
        ChainStageSpec(member=_external(1.0, 12)),
    ]
    resolved = resolve_chain_positions(stages)
    findings = check_chain_interference(resolved)
    assert findings == []


def test_check_chain_interference_margin_produces_clearance_not_overlap():
    a = BoundingCircle((0, 0), 22)
    b = BoundingCircle((44.1, 0), 22)
    from app.document.gear_chain_math import ResolvedChainMember, ResolvedChainStage

    stages = [
        ResolvedChainStage(0, (0, 0), None, 0.0, [ResolvedChainMember(0, "single", (0, 0), a)]),
        ResolvedChainStage(1, (25, 0), 0.0, 0.0, [ResolvedChainMember(1, "single", (25, 0), BoundingCircle((25, 0), 1.0))]),
        ResolvedChainStage(2, (44.1, 0), 0.0, None, [ResolvedChainMember(2, "single", (44.1, 0), b)]),
    ]
    findings = check_chain_interference(stages, print_clearance_margin=0.2)
    assert len(findings) == 1
    assert findings[0].kind == "clearance"
    assert findings[0].gap == pytest.approx(0.1, abs=1e-9)


# ---------------------------------------------------------------------------
# Compound-station pure-math checks (Spike 2 findings)
# ---------------------------------------------------------------------------


def test_compound_axial_overlap_positive_when_members_overlap():
    assert compound_axial_overlap(member_a_face_width=6.0, axial_offset=5.0) == pytest.approx(1.0)


def test_compound_axial_overlap_zero_or_negative_when_flush_or_gapped():
    assert compound_axial_overlap(member_a_face_width=6.0, axial_offset=6.0) == pytest.approx(0.0)
    assert compound_axial_overlap(member_a_face_width=6.0, axial_offset=7.0) == pytest.approx(-1.0)


def test_thin_member_warning_flags_below_the_minimum():
    warning = thin_member_warning(0.3, "stage 1 member a")
    assert warning is not None
    assert "0.3" in warning


def test_thin_member_warning_silent_above_the_minimum():
    assert thin_member_warning(5.0, "stage 1 member a") is None


# ---------------------------------------------------------------------------
# Ratio/rotation-direction (08-entry-screen-and-preview.md's "two cheap
# numbers from the same math")
# ---------------------------------------------------------------------------


def test_mesh_link_ratio_external_external_reverses():
    link = mesh_link_ratio(_external(2, 20), _external(2, 40))
    assert link.reverses is True
    assert link.ratio == pytest.approx(2.0)  # driven(40)/driving(20)
    assert link.linear_mm_per_revolution is None


def test_mesh_link_ratio_external_internal_does_not_reverse():
    link = mesh_link_ratio(_external(2, 20), _internal(2, 60, outer_diameter=140))
    assert link.reverses is False
    assert link.ratio == pytest.approx(3.0)


def test_mesh_link_ratio_rack_link_reverses_and_reports_linear_travel():
    link = mesh_link_ratio(_external(2, 20), _rack(2, 10))
    assert link.reverses is True
    assert link.ratio is None
    assert link.linear_mm_per_revolution == pytest.approx(math.pi * 2 * 20)

    reverse_order = mesh_link_ratio(_rack(2, 10), _external(2, 20))
    assert reverse_order.linear_mm_per_revolution == pytest.approx(math.pi * 2 * 20)


def test_compound_transition_ratio_never_reverses():
    link = compound_transition_ratio(_external(1, 20), _external(5, 10))
    assert link.reverses is False
    assert link.ratio == pytest.approx(0.5)  # member_b(10)/member_a(20)


def test_chain_overall_ratio_telescopes_across_pure_gear_links():
    links = [mesh_link_ratio(_external(2, 20), _external(2, 40)), mesh_link_ratio(_external(2, 40), _external(2, 10))]
    # 40/20 * 10/40 = 0.5
    assert chain_overall_ratio(links) == pytest.approx(0.5)


def test_chain_overall_ratio_none_when_any_link_is_a_rack_link():
    links = [mesh_link_ratio(_external(2, 20), _external(2, 40)), mesh_link_ratio(_external(2, 40), _rack(2, 10))]
    assert chain_overall_ratio(links) is None


# --- Meshing-phase alignment ------------------------------------------------
# Reference values from this workstream's own real-OCCT derivation (see
# `propagate_meshing_phase`'s own docstring): a 40T predecessor sitting at
# 175.5 degrees (correct for its own, different, incoming junction) meshing
# a 48T successor whose own junction has `incoming_direction = -60 degrees`.


def test_meshing_phase_base_matches_the_textbook_symmetric_case_at_zero_direction():
    # angular_pitch(48T) = 7.5deg; azimuth = 0 + 180 = 180deg; base = 180 - 3.75 = 176.25deg
    base = meshing_phase_base(48, ChainMemberKind.EXTERNAL, 0.0)
    assert math.degrees(base) == pytest.approx(176.25)


def test_meshing_phase_base_flips_azimuth_for_an_internal_predecessor():
    # No `+ pi`: internal tangency puts the contact point on the same side
    # as `incoming_direction`, not the opposite side - see the function's
    # own worked numeric example.
    base_external_pred = meshing_phase_base(48, ChainMemberKind.EXTERNAL, math.radians(30.0))
    base_internal_pred = meshing_phase_base(48, ChainMemberKind.INTERNAL, math.radians(30.0))
    assert math.degrees(base_internal_pred) == pytest.approx(math.degrees(base_external_pred) - 180.0)


def test_rack_meshing_phase_base_is_zero_for_even_tooth_count_and_half_pitch_for_odd():
    tooth_pitch = 12.0
    assert rack_meshing_phase_base(14, tooth_pitch) == pytest.approx(0.0)
    assert rack_meshing_phase_base(15, tooth_pitch) == pytest.approx(6.0)


def test_propagate_meshing_phase_is_a_no_op_when_predecessor_sits_at_its_own_native_reference():
    # predecessor_phase == 0 and incoming_direction == 0 together mean "no
    # correction needed" - propagate_meshing_phase should hand back
    # base_value unchanged.
    base = meshing_phase_base(48, ChainMemberKind.EXTERNAL, 0.0)
    result = propagate_meshing_phase(ChainMemberKind.EXTERNAL, 60.0, 0.0, ChainMemberKind.EXTERNAL, 72.0, 0.0, base)
    assert result == pytest.approx(base)


def test_propagate_meshing_phase_matches_the_real_occt_verified_bent_junction_example():
    """The exact reproduction from this fix's own real-OCCT verification: a
    40T predecessor already at 175.5 degrees (correct for its own upstream
    junction), meshing a 48T successor whose own junction sits at -60
    degrees - `propagate_meshing_phase`'s corrected result (2.5 degrees mod
    the 48T member's own 7.5 degree pitch) measured exactly 0mm^3 overlap
    via a fine-grained real-OCCT sweep across the full pitch; the naive
    (uncorrected-for-direction) 116.25 degrees measured ~420mm^3."""
    module = 3.0
    r40 = pitch_radius(_external(module, 40))
    r48 = pitch_radius(_external(module, 48))
    d = math.radians(-60.0)
    theta_predecessor = math.radians(175.5)
    base = meshing_phase_base(48, ChainMemberKind.EXTERNAL, d)
    result = propagate_meshing_phase(ChainMemberKind.EXTERNAL, r40, theta_predecessor, ChainMemberKind.EXTERNAL, r48, d, base)
    assert math.degrees(result) % 7.5 == pytest.approx(2.5, abs=1e-6)


def test_propagate_meshing_phase_reverses_for_two_non_internal_members_but_not_when_one_is_internal():
    d = math.radians(10.0)
    base = 1.0  # arbitrary base_value, isolating the correction term's own sign
    ext_ext = propagate_meshing_phase(ChainMemberKind.EXTERNAL, 40.0, 2.0, ChainMemberKind.EXTERNAL, 60.0, d, base)
    ext_int = propagate_meshing_phase(ChainMemberKind.EXTERNAL, 40.0, 2.0, ChainMemberKind.INTERNAL, 60.0, d, base)
    # The correction term's own sign flips between the two (reverses vs not) -
    # so the two results move in opposite directions away from `base`, and by
    # the same magnitude (only `sign` differs between the two calls).
    assert (ext_ext - base) == pytest.approx(-(ext_int - base))
