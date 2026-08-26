"""Tests for the cheap `/gear/preview` endpoint -
`docs/gear-design/08-entry-screen-and-preview.md`. Structurally mirrors
`test_gear_feature.py`/`test_rack_feature.py`'s own shape, but this endpoint
runs only `gear_math` (no OCCT, no tessellation) - real reference-value
checks against known gear dimensions, not just "it runs", same requirement
`test_gear_math.py` already holds itself to.
"""

import math

import pytest
from fastapi.testclient import TestClient

from app.document.gear_chain_math import (
    ChainMemberKind,
    ChainMemberSpec,
    ChainStageSpec,
    meshing_phase_base,
    propagate_meshing_phase,
    resolve_chain,
)
from app.document.gear_math import (
    full_gear_profile_points,
    full_rack_profile_points,
    minimum_profile_shift_to_avoid_undercut,
    planetary_planet_tooth_count,
    rack_tooth_geometry,
    spur_gear_geometry,
)
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _preview(**overrides) -> dict:
    payload = {"gear_kind": "external", "module": 2.0, "tooth_count": 20}
    payload.update(overrides)
    return client.post("/document/gear/preview", json=payload)


# --- External gear -----------------------------------------------------------


def test_external_gear_preview_returns_known_reference_circles():
    response = _preview()
    assert response.status_code == 200, response.json()
    body = response.json()
    assert body["gear_kind"] == "external"
    # Module-2/20-tooth/20-degree spur gear: pitch radius 20mm, addendum
    # radius 22mm (same reference values test_gear_math.py itself checks).
    assert body["pitch_radius"] == 20.0
    assert body["addendum_radius"] == 22.0
    assert body["base_radius"] == math.cos(math.radians(20.0)) * 20.0
    assert body["outer_radius"] is None
    assert body["pitch_line_y"] is None
    assert body["warnings"] == []
    # Auto (the default, profile_shift omitted) resolves to 0.0 here - a
    # 20-tooth gear already clears the undercut-free minimum (~17.1) at
    # 0.0 shift, so auto never raises it - same "byte-identical to before
    # this could auto-resolve" guarantee resolve_gear_profile_shift's own
    # docstring makes.
    assert body["effective_profile_shift"] == 0.0
    assert len(body["outline_points"]) > 0
    # Every outline point should sit within a small tolerance of the
    # addendum/dedendum band - a sanity bound on the returned polyline, not
    # just "it has some points".
    max_radius = max((x**2 + y**2) ** 0.5 for x, y in body["outline_points"])
    assert max_radius <= 22.5


def test_external_gear_preview_warns_on_undercut_risk_with_explicit_zero_shift():
    # A 6-tooth module-2/20-degree gear is well below the undercut-free
    # minimum (~17.1 teeth) - non-blocking per 00-conventions.md, so this
    # must still return 200 with a warning, not a 422. profile_shift=0.0 is
    # explicit here (an "explicit value always wins" override) - without it,
    # auto-resolution below removes this exact warning by default.
    response = _preview(tooth_count=6, profile_shift=0.0)
    assert response.status_code == 200, response.json()
    warnings = response.json()["warnings"]
    assert len(warnings) == 1
    assert "undercut" in warnings[0].lower()
    assert response.json()["effective_profile_shift"] == 0.0


def test_external_gear_preview_auto_resolves_profile_shift_to_clear_undercut_by_default():
    # Same 6-tooth gear as above, but profile_shift omitted (auto, the
    # default) - resolve_gear_profile_shift picks the closed-form minimum
    # shift that clears undercut at tooth_count=6, so the warning that
    # fires at an explicit 0.0 shift above is gone here.
    response = _preview(tooth_count=6)
    assert response.status_code == 200, response.json()
    body = response.json()
    assert body["warnings"] == []
    assert body["effective_profile_shift"] == pytest.approx(
        minimum_profile_shift_to_avoid_undercut(6, pressure_angle_degrees=20.0)
    )
    assert body["effective_profile_shift"] > 0.0


def test_external_gear_preview_explicit_profile_shift_is_returned_as_is():
    response = _preview(tooth_count=20, profile_shift=0.5)
    assert response.status_code == 200, response.json()
    assert response.json()["effective_profile_shift"] == 0.5


def test_external_gear_preview_rejects_invalid_parameters_as_422():
    response = _preview(tooth_count=3)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_preview_parameters"


def test_gear_preview_get_matches_post_for_the_same_parameters():
    post_response = _preview()
    get_response = client.get(
        "/document/gear/preview",
        params={"gear_kind": "external", "module": 2.0, "tooth_count": 20},
    )
    assert get_response.status_code == 200
    assert get_response.json() == post_response.json()


# --- Internal gear -----------------------------------------------------------


def test_internal_gear_preview_requires_outer_diameter():
    response = _preview(gear_kind="internal", tooth_count=40)
    assert response.status_code == 422
    assert "outer_diameter" in response.json()["detail"]["detail"]


def test_internal_gear_preview_returns_outer_radius():
    response = _preview(gear_kind="internal", tooth_count=40, outer_diameter=100.0)
    assert response.status_code == 200, response.json()
    body = response.json()
    assert body["pitch_radius"] == 40.0
    assert body["outer_radius"] == 50.0
    # Internal gears aren't checked for the same cutter-undercut risk, so
    # auto always resolves to 0.0 for one too, regardless of tooth_count.
    assert body["warnings"] == []
    assert body["effective_profile_shift"] == 0.0


# --- Rack ---------------------------------------------------------------------


def test_rack_preview_returns_pitch_line_and_length_not_circles():
    response = _preview(gear_kind="rack", tooth_count=10)
    assert response.status_code == 200, response.json()
    body = response.json()
    assert body["pitch_radius"] is None
    assert body["pitch_line_y"] == 0.0
    assert body["addendum_line_y"] == 2.0  # addendum_coefficient(1.0) * module(2.0)
    assert body["dedendum_line_y"] == -2.5  # dedendum_coefficient(1.25) * module(2.0)
    assert body["rack_length"] == math.pi * 2.0 * 10
    assert len(body["outline_points"]) == 4 * 10


def test_rack_preview_rejects_non_positive_backing_height():
    response = _preview(gear_kind="rack", tooth_count=10, backing_height=0.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_preview_parameters"


# --- Chain (docs/gear-design/05-gear-chain-and-planetary.md's own preview
# extension, 08-entry-screen-and-preview.md's "Chain/planetary/bevel-pair
# preview" section) --------------------------------------------------------


def _chain_preview(**overrides) -> dict:
    payload = {
        "gear_kind": "chain",
        "chain": {
            "groups": [{"id": "g1", "module": 2.0, "pressure_angle_degrees": 20.0}],
            "stages": [
                {"member": {"member_type": "external", "group_id": "g1", "tooth_count": 20, "face_width": 5.0}},
                {"member": {"member_type": "external", "group_id": "g1", "tooth_count": 15, "face_width": 5.0}},
            ],
            "start_direction_degrees": 0.0,
        },
    }
    payload.update(overrides)
    return client.post("/document/gear/preview", json=payload)


def test_chain_preview_two_external_gears_positions_ratio_and_reversal():
    response = _chain_preview()
    assert response.status_code == 200, response.json()
    body = response.json()
    chain = body["chain"]
    assert len(chain["members"]) == 2
    assert chain["members"][0]["center"] == [0.0, 0.0]
    # center distance = module*(20+15)/2 = 35
    assert chain["members"][1]["center"] == [35.0, 0.0]
    assert chain["interference_findings"] == []
    assert len(chain["links"]) == 1
    link = chain["links"][0]
    assert link["kind"] == "mesh"
    assert link["reverses_direction"] is True
    assert link["ratio"] == 15 / 20
    assert chain["overall_ratio"] == 15 / 20


def test_chain_preview_external_internal_link_does_not_reverse():
    response = _chain_preview(
        chain={
            "groups": [{"id": "g1", "module": 2.0, "pressure_angle_degrees": 20.0}],
            "stages": [
                {"member": {"member_type": "external", "group_id": "g1", "tooth_count": 20, "face_width": 5.0}},
                {
                    "member": {
                        "member_type": "internal",
                        "group_id": "g1",
                        "tooth_count": 60,
                        "face_width": 5.0,
                        "outer_diameter": 140.0,
                    }
                },
            ],
        }
    )
    assert response.status_code == 200, response.json()
    link = response.json()["chain"]["links"][0]
    assert link["reverses_direction"] is False
    assert link["ratio"] == 60 / 20


def test_chain_preview_reproduces_spike_1_worked_example_interference():
    # 05-gear-chain-and-planetary.md's own hand-verified 5-stage worked
    # example: ext20/ext15/ext10(+90deg turn)/ext25(-30deg turn)/int60.
    response = _chain_preview(
        chain={
            "groups": [{"id": "g1", "module": 2.0, "pressure_angle_degrees": 20.0}],
            "stages": [
                {"member": {"member_type": "external", "group_id": "g1", "tooth_count": 20, "face_width": 5.0}},
                {
                    "turn_angle_degrees": 0,
                    "member": {"member_type": "external", "group_id": "g1", "tooth_count": 15, "face_width": 5.0},
                },
                {
                    "turn_angle_degrees": 90,
                    "member": {"member_type": "external", "group_id": "g1", "tooth_count": 10, "face_width": 5.0},
                },
                {
                    "turn_angle_degrees": -30,
                    "member": {"member_type": "external", "group_id": "g1", "tooth_count": 25, "face_width": 5.0},
                },
                {
                    "turn_angle_degrees": 0,
                    "member": {
                        "member_type": "internal",
                        "group_id": "g1",
                        "tooth_count": 60,
                        "face_width": 5.0,
                        "outer_diameter": 140.0,
                    },
                },
            ],
        }
    )
    assert response.status_code == 200, response.json()
    chain = response.json()["chain"]
    assert len(chain["members"]) == 5
    last_center = chain["members"][4]["center"]
    assert last_center[0] == pytest.approx(77.5, abs=1e-4)
    assert last_center[1] == pytest.approx(65.310889, abs=1e-4)
    pairs = {(f["stage_index_a"], f["stage_index_b"]) for f in chain["interference_findings"]}
    assert pairs == {(1, 3), (1, 4), (2, 4)}


# --- Chain preview meshing-phase alignment ----------------------------------
#
# `app.document.gear_chain`'s own real `GearChainFeature` construction fix
# (`gear_chain_math.meshing_phase_base`/`propagate_meshing_phase`, verified
# there via real OCCT boolean intersection) rotates every non-first round
# member so a tooth *gap*, not a tooth, meets its neighbour - but that fix
# only ever touched the OCCT-dependent `resolve_gear_chain_from_bodies`
# construction path, leaving this preview endpoint (a completely separate
# code path, per this module's own established "duplicate the cheap math"
# convention - see `_preview_rack_rotation`'s docstring in router.py)
# silently unrotated: every round member's `outline_points` came back at
# rotation 0.0 regardless of what its neighbours actually needed, which is
# exactly the symptom a user reported directly (tooth-on-tooth, not
# tooth-to-gap, in the 2D preview - the real construction was already
# correct). These tests assert the preview's own `outline_points` reflect
# the identical rotation `meshing_phase_base`/`propagate_meshing_phase`
# predict - not a re-verification of the formula itself (already covered,
# with real OCCT, by `test_gear_chain_math.py`/`test_gear_chain_feature.py`),
# just that the preview actually calls it now.


def _rotated_translated_points(points, center, rotation):
    """Mirrors `router._preview_transform_profile`'s own rotate-then-
    translate formula exactly - the independent expected-value computation
    these tests check the preview's `outline_points` against."""
    cos_a, sin_a = math.cos(rotation), math.sin(rotation)
    return [(center[0] + x * cos_a - y * sin_a, center[1] + x * sin_a + y * cos_a) for x, y in points]


def _assert_points_match(actual, expected, *, abs_tol=1e-6):
    assert len(actual) == len(expected)
    for (ax, ay), (ex, ey) in zip(actual, expected):
        assert ax == pytest.approx(ex, abs=abs_tol)
        assert ay == pytest.approx(ey, abs=abs_tol)


def test_chain_preview_applies_meshing_phase_rotation_on_a_bent_three_stage_chain():
    """The same bent 3-stage case (36T/40T at a -60deg turn/48T, module 3)
    that `test_gear_chain_feature.py`'s own `test_three_stage_chain_with_a_
    turn_meshes_without_overlap` uses for the real construction - the exact
    real-OCCT counterexample that drove `propagate_meshing_phase`'s own
    predecessor-rotation-aware, bent-junction-aware correction (a per-
    junction-only rule passes at the first junction but leaves real overlap
    at the second - see that module's own notes). Stage 0 always stays at
    this module's 0.0 zero-reference (no predecessor); stages 1 and 2 each
    need their own nonzero, junction-specific rotation - a preview that
    still hardcoded rotation=0.0 (this bug, before the fix) would leave all
    three outlines unrotated, which this test's own sanity-check assertions
    on the independently-computed expected rotations rule out."""
    module = 3.0
    tooth_counts = (36, 40, 48)
    specs = [
        ChainStageSpec(member=ChainMemberSpec(ChainMemberKind.EXTERNAL, module, 20.0, tooth_counts[0], 10.0)),
        ChainStageSpec(
            turn_angle_degrees=-60.0,
            member=ChainMemberSpec(ChainMemberKind.EXTERNAL, module, 20.0, tooth_counts[1], 10.0),
        ),
        ChainStageSpec(member=ChainMemberSpec(ChainMemberKind.EXTERNAL, module, 20.0, tooth_counts[2], 10.0)),
    ]
    resolved = resolve_chain(specs, 0.0, 0.5)

    stage0_rotation = 0.0
    stage1_base = meshing_phase_base(tooth_counts[1], ChainMemberKind.EXTERNAL, resolved.stages[1].incoming_direction)
    stage1_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL,
        module * tooth_counts[0] / 2,
        stage0_rotation,
        ChainMemberKind.EXTERNAL,
        module * tooth_counts[1] / 2,
        resolved.stages[1].incoming_direction,
        stage1_base,
    )
    stage2_base = meshing_phase_base(tooth_counts[2], ChainMemberKind.EXTERNAL, resolved.stages[2].incoming_direction)
    stage2_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL,
        module * tooth_counts[1] / 2,
        stage1_rotation,
        ChainMemberKind.EXTERNAL,
        module * tooth_counts[2] / 2,
        resolved.stages[2].incoming_direction,
        stage2_base,
    )
    rotations = (stage0_rotation, stage1_rotation, stage2_rotation)
    # A broken, still-hardcoded-to-0.0 preview would trivially satisfy
    # "stage0 == 0.0" but not this - both junction corrections are real,
    # nonzero, and distinct from each other (the bent-junction case this
    # combination exists to exercise).
    assert stage1_rotation != pytest.approx(0.0, abs=1e-9)
    assert stage2_rotation != pytest.approx(stage1_rotation, abs=1e-9)

    response = _chain_preview(
        chain={
            "groups": [{"id": "g1", "module": module, "pressure_angle_degrees": 20.0}],
            "stages": [
                {"member": {"member_type": "external", "group_id": "g1", "tooth_count": tooth_counts[0], "face_width": 10.0}},
                {
                    "turn_angle_degrees": -60.0,
                    "member": {"member_type": "external", "group_id": "g1", "tooth_count": tooth_counts[1], "face_width": 10.0},
                },
                {"member": {"member_type": "external", "group_id": "g1", "tooth_count": tooth_counts[2], "face_width": 10.0}},
            ],
        }
    )
    assert response.status_code == 200, response.json()
    members = response.json()["chain"]["members"]
    assert len(members) == 3

    for member, tooth_count, rotation in zip(members, tooth_counts, rotations):
        geometry = spur_gear_geometry(module=module, tooth_count=tooth_count, pressure_angle_degrees=20.0, is_internal=False)
        expected = _rotated_translated_points(full_gear_profile_points(geometry), member["center"], rotation)
        _assert_points_match(member["outline_points"], expected)


def test_chain_preview_rack_rotation_is_unaffected_by_the_meshing_phase_fix():
    """`_preview_rack_rotation` (a rack's own perpendicular-to-the-segment
    orientation, unrelated to tooth phase) was already correct before this
    fix and must stay byte-identical. A 2-stage chain has only one segment,
    whose direction is `start_direction_degrees` regardless of either
    stage's own `turn_angle_degrees` (`resolve_chain_positions`'s own
    `k == 0` special case - a per-stage turn only steers the segment
    *leaving* a stage from the second segment onward), so this uses a
    nonzero `start_direction_degrees` directly to get a genuinely bent
    (not axis-aligned) segment."""
    response = _chain_preview(
        chain={
            "groups": [{"id": "g1", "module": 3.0, "pressure_angle_degrees": 20.0}],
            "stages": [
                {"member": {"member_type": "external", "group_id": "g1", "tooth_count": 36, "face_width": 10.0}},
                {"member": {"member_type": "rack", "group_id": "g1", "tooth_count": 15, "face_width": 10.0}},
            ],
            "start_direction_degrees": 25.0,
        }
    )
    assert response.status_code == 200, response.json()
    members = response.json()["chain"]["members"]
    rack_member = members[1]
    # Same formula `_preview_rack_rotation`/`gear_chain._rack_rotation`
    # already used pre-fix: incoming_direction + pi/2 (the rack's own
    # length axis, perpendicular to the segment it sits on).
    incoming_direction = math.radians(25.0)
    expected_rotation = incoming_direction + math.pi / 2
    rack_geometry = rack_tooth_geometry(module=3.0, pressure_angle_degrees=20.0)
    expected = _rotated_translated_points(
        full_rack_profile_points(rack_geometry, 15), rack_member["center"], expected_rotation
    )
    _assert_points_match(rack_member["outline_points"], expected)


def test_chain_preview_rejects_fewer_than_two_stages_as_422():
    response = _chain_preview(
        chain={
            "groups": [{"id": "g1", "module": 2.0, "pressure_angle_degrees": 20.0}],
            "stages": [{"member": {"member_type": "external", "group_id": "g1", "tooth_count": 20, "face_width": 5.0}}],
        }
    )
    assert response.status_code == 422


def test_chain_preview_rejects_unknown_group_id_as_422():
    response = _chain_preview(
        chain={
            "groups": [{"id": "g1", "module": 2.0, "pressure_angle_degrees": 20.0}],
            "stages": [
                {"member": {"member_type": "external", "group_id": "g1", "tooth_count": 20, "face_width": 5.0}},
                {"member": {"member_type": "external", "group_id": "unknown", "tooth_count": 15, "face_width": 5.0}},
            ],
        }
    )
    assert response.status_code == 422


# --- Planetary ---------------------------------------------------------------


def _planetary_preview(**overrides) -> dict:
    payload = {
        "gear_kind": "planetary",
        "planetary": {
            "module": 2.0,
            "sun_tooth_count": 20,
            "ring_tooth_count": 60,
            "planet_count": 4,
            "face_width": 5.0,
            "ring_outer_diameter": 140.0,
        },
    }
    payload.update(overrides)
    return client.post("/document/gear/preview", json=payload)


# --- Planetary preview meshing-phase alignment ------------------------------
#
# `app.document.planetary_gear.resolve_planetary_from_bodies`'s own real
# construction fix (sun anchors the zero-reference; each planet's rotation
# comes from its own sun mesh; the ring's rotation is solved once from
# planet 0 - verified there via real OCCT boolean intersection, per that
# module's own inline comment) never touched this preview's separate code
# path either - see the chain preview's own equivalent section above for
# the full story (same bug, same fix shape, generalized here from a
# sequential chain to sun/ring/N-planets).


def _planetary_expected_rotations(*, module, sun_teeth, ring_teeth, planet_count):
    """Mirrors `planetary_gear.resolve_planetary_from_bodies`'s own phase-
    computation block exactly (see that function's inline comment for the
    full derivation) - the independent expected-value computation these
    tests check the preview's `outline_points` against."""
    planet_teeth = planetary_planet_tooth_count(sun_teeth, ring_teeth)
    sun_pitch_radius = module * sun_teeth / 2
    ring_pitch_radius = module * ring_teeth / 2
    planet_pitch_radius = module * planet_teeth / 2

    sun_rotation = 0.0
    planet_0_azimuth = 0.0
    planet_0_base = meshing_phase_base(planet_teeth, ChainMemberKind.EXTERNAL, planet_0_azimuth)
    planet_0_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL, sun_pitch_radius, sun_rotation,
        ChainMemberKind.EXTERNAL, planet_pitch_radius, planet_0_azimuth, planet_0_base,
    )
    ring_azimuth = planet_0_azimuth + math.pi
    ring_base = meshing_phase_base(ring_teeth, ChainMemberKind.EXTERNAL, ring_azimuth)
    ring_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL, planet_pitch_radius, planet_0_rotation,
        ChainMemberKind.INTERNAL, ring_pitch_radius, ring_azimuth, ring_base,
    )

    planet_rotations = []
    for i in range(planet_count):
        phi = 2 * math.pi * i / planet_count
        planet_base = meshing_phase_base(planet_teeth, ChainMemberKind.EXTERNAL, phi)
        planet_rotations.append(
            propagate_meshing_phase(
                ChainMemberKind.EXTERNAL, sun_pitch_radius, sun_rotation,
                ChainMemberKind.EXTERNAL, planet_pitch_radius, phi, planet_base,
            )
        )
    return sun_rotation, ring_rotation, planet_rotations


def test_planetary_preview_returns_sun_ring_and_evenly_spaced_planets():
    module, sun_teeth, ring_teeth, planet_count = 2.0, 20, 60, 4
    response = _planetary_preview()
    assert response.status_code == 200, response.json()
    planetary = response.json()["planetary"]
    # planet tooth count = (60-20)/2 = 20
    members = planetary["members"]
    assert len(members) == 2 + 4
    sun, ring = members[0], members[1]
    assert sun["label"] == "sun"
    assert sun["pitch_radius"] == 20.0
    assert ring["label"] == "ring"
    assert ring["pitch_radius"] == 60.0
    assert ring["outer_radius"] == 70.0
    planets = members[2:]
    # orbit radius = sun pitch radius (20) + planet pitch radius (20) = 40
    assert planets[0]["center"] == [40.0, 0.0]
    assert planets[1]["center"][0] == pytest.approx(0.0, abs=1e-9)
    assert planets[1]["center"][1] == pytest.approx(40.0, abs=1e-9)
    assert planetary["sun_to_planet_ratio"] == 1.0
    assert planetary["planet_to_ring_ratio"] == 3.0

    # Tooth-phase check for the user's own exact reported combination
    # (module=2, sun=20T, ring=60T, planet_count=4) - low enough tooth
    # counts that real involute tip interference is a separate, expected,
    # pre-existing confound (out of scope here, see this module's own
    # meshing-phase section notes), so this only checks the *rotation*
    # applied to each outline, not real geometric clearance.
    sun_rotation, ring_rotation, planet_rotations = _planetary_expected_rotations(
        module=module, sun_teeth=sun_teeth, ring_teeth=ring_teeth, planet_count=planet_count
    )
    sun_geometry = spur_gear_geometry(module=module, tooth_count=sun_teeth, pressure_angle_degrees=20.0, is_internal=False)
    ring_geometry = spur_gear_geometry(module=module, tooth_count=ring_teeth, pressure_angle_degrees=20.0, is_internal=True)
    planet_teeth = planetary_planet_tooth_count(sun_teeth, ring_teeth)
    planet_geometry = spur_gear_geometry(module=module, tooth_count=planet_teeth, pressure_angle_degrees=20.0, is_internal=False)

    _assert_points_match(
        sun["outline_points"], _rotated_translated_points(full_gear_profile_points(sun_geometry), sun["center"], sun_rotation)
    )
    _assert_points_match(
        ring["outline_points"], _rotated_translated_points(full_gear_profile_points(ring_geometry), ring["center"], ring_rotation)
    )
    for planet, rotation in zip(planets, planet_rotations):
        _assert_points_match(
            planet["outline_points"],
            _rotated_translated_points(full_gear_profile_points(planet_geometry), planet["center"], rotation),
        )


def test_planetary_preview_applies_meshing_phase_rotation_at_tooth_counts_clear_of_the_undercut_confound():
    """`test_planetary_gear_feature.py`'s own real-OCCT-verified safe
    combination (sun 40T, ring 120T, planet_count 4, module 3) - clear of
    the low-tooth-count involute tip interference confound its own
    `test_sun_ring_and_four_planets_mesh_without_overlap` docstring
    documents, so this test's own phase check can't be confused with that
    separate, unrelated limitation."""
    module, sun_teeth, ring_teeth, planet_count = 3.0, 40, 120, 4
    response = _planetary_preview(
        planetary={
            "module": module,
            "sun_tooth_count": sun_teeth,
            "ring_tooth_count": ring_teeth,
            "planet_count": planet_count,
            "face_width": 10.0,
            "ring_outer_diameter": module * (ring_teeth + 10),
        }
    )
    assert response.status_code == 200, response.json()
    members = response.json()["planetary"]["members"]
    sun, ring = members[0], members[1]
    planets = members[2:]
    assert len(planets) == planet_count

    sun_rotation, ring_rotation, planet_rotations = _planetary_expected_rotations(
        module=module, sun_teeth=sun_teeth, ring_teeth=ring_teeth, planet_count=planet_count
    )
    sun_geometry = spur_gear_geometry(module=module, tooth_count=sun_teeth, pressure_angle_degrees=20.0, is_internal=False)
    ring_geometry = spur_gear_geometry(module=module, tooth_count=ring_teeth, pressure_angle_degrees=20.0, is_internal=True)
    planet_teeth = planetary_planet_tooth_count(sun_teeth, ring_teeth)
    planet_geometry = spur_gear_geometry(module=module, tooth_count=planet_teeth, pressure_angle_degrees=20.0, is_internal=False)

    _assert_points_match(
        sun["outline_points"], _rotated_translated_points(full_gear_profile_points(sun_geometry), sun["center"], sun_rotation)
    )
    _assert_points_match(
        ring["outline_points"], _rotated_translated_points(full_gear_profile_points(ring_geometry), ring["center"], ring_rotation)
    )
    for planet, rotation in zip(planets, planet_rotations):
        _assert_points_match(
            planet["outline_points"],
            _rotated_translated_points(full_gear_profile_points(planet_geometry), planet["center"], rotation),
        )
    # Regression guard for the actual bug (every round member silently
    # unrotated) - a broken preview would make every planet's rotation
    # (and the ring's) come back as 0.0 regardless of its own orbital
    # position; none of these do, and not every planet shares the same
    # raw rotation value either (planet 0 vs planet 1, 90 degrees apart in
    # orbit, land 180 degrees apart in raw rotation here).
    assert ring_rotation != pytest.approx(0.0, abs=1e-9)
    assert all(r != pytest.approx(0.0, abs=1e-9) for r in planet_rotations)
    assert planet_rotations[0] != pytest.approx(planet_rotations[1], abs=1e-9)


def test_planetary_preview_blocks_when_planet_tooth_count_is_not_a_positive_even_difference():
    # ring(21) - sun(20) = 1, odd -> no valid planet tooth count, blocks.
    response = _planetary_preview(
        planetary={
            "module": 2.0,
            "sun_tooth_count": 20,
            "ring_tooth_count": 21,
            "planet_count": 4,
            "face_width": 5.0,
            "ring_outer_diameter": 140.0,
        }
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_preview_parameters"


def test_planetary_preview_blocks_when_assembly_condition_fails():
    # (sun+ring) mod planet_count != 0: (20+60) mod 3 = 80 mod 3 = 2 != 0.
    response = _planetary_preview(
        planetary={
            "module": 2.0,
            "sun_tooth_count": 20,
            "ring_tooth_count": 60,
            "planet_count": 3,
            "face_width": 5.0,
            "ring_outer_diameter": 140.0,
        }
    )
    assert response.status_code == 422


# --- Bevel gear / bevel pair (docs/gear-design/10-bevel-gear.md,
# 11-bevel-pair.md - 08-entry-screen-and-preview.md's "Chain/planetary/
# bevel-pair preview" section) ----------------------------------------------


def _bevel_gear_preview(**overrides) -> dict:
    payload = {
        "gear_kind": "bevel_gear",
        "bevel_gear": {
            "module": 4.0,
            "tooth_count": 20,
            "face_width": 14.9,
            "pitch_cone_angle_degrees": 26.56505117707799,
            "pressure_angle_degrees": 20.0,
        },
    }
    payload.update(overrides)
    return client.post("/document/gear/preview", json=payload)


def test_bevel_gear_preview_returns_axial_cross_section_schematic():
    response = _bevel_gear_preview()
    assert response.status_code == 200, response.json()
    body = response.json()
    member = body["bevel_gear"]
    assert member["label"] == "single"
    assert member["axis_angle_degrees"] == 0.0
    assert member["pitch_radius"] == 40.0
    assert member["cone_distance"] == pytest.approx(89.4427, abs=1e-3)
    assert len(member["outline_points"]) == 8
    # Every outline point sits at either the inner or the outer cone
    # distance from the apex (the origin) - a real geometric property of
    # this schematic, not just "it has 8 points".
    for x, y in member["outline_points"]:
        radius = (x**2 + y**2) ** 0.5
        assert radius == pytest.approx(member["cone_distance"], abs=1e-6) or radius == pytest.approx(
            member["inner_cone_distance"], abs=1e-6
        )
    assert body["warnings"] == []


def test_bevel_gear_preview_warns_when_face_width_exceeds_recommended_maximum():
    # max_recommended_face_width(cone_distance=89.4427) = cone_distance/3 ~= 29.81
    response = _bevel_gear_preview(bevel_gear={
        "module": 4.0,
        "tooth_count": 20,
        "face_width": 35.0,
        "pitch_cone_angle_degrees": 26.56505117707799,
    })
    assert response.status_code == 200, response.json()
    assert len(response.json()["warnings"]) == 1
    assert "face_width" in response.json()["warnings"][0]


def test_bevel_gear_preview_rejects_invalid_parameters_as_422():
    response = _bevel_gear_preview(bevel_gear={
        "module": 4.0,
        "tooth_count": 20,
        "face_width": 100.0,  # >= cone_distance - invalid
        "pitch_cone_angle_degrees": 26.56505117707799,
    })
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_preview_parameters"


def _bevel_pair_preview(**overrides) -> dict:
    payload = {
        "gear_kind": "bevel_pair",
        "bevel_pair": {
            "module": 4.0,
            "member_1": {"tooth_count": 20},
            "member_2": {"tooth_count": 40},
            "face_width": 14.9,
            "shaft_angle_degrees": 90.0,
        },
    }
    payload.update(overrides)
    return client.post("/document/gear/preview", json=payload)


def test_bevel_pair_preview_auto_derives_cone_angles_and_dual_axis():
    response = _bevel_pair_preview()
    assert response.status_code == 200, response.json()
    pair = response.json()["bevel_pair"]
    assert pair["shaft_angle_degrees"] == 90.0
    assert len(pair["members"]) == 2
    member_1, member_2 = pair["members"]
    assert member_1["label"] == "member_1"
    assert member_1["axis_angle_degrees"] == 0.0
    assert member_2["label"] == "member_2"
    assert member_2["axis_angle_degrees"] == 90.0
    # Known-value case: gamma_1 = atan(N1/N2) at Sigma=90deg (10-bevel-gear.md).
    assert member_1["pitch_cone_angle_degrees"] == pytest.approx(math.degrees(math.atan(20 / 40)), abs=1e-6)
    assert member_2["pitch_cone_angle_degrees"] == pytest.approx(90.0 - member_1["pitch_cone_angle_degrees"], abs=1e-6)
    # A meshing pair always shares the same cone distance (real geometric
    # property, confirmed directly in this project's own BevelPairFeature
    # test suite - reproduced here for the preview's own math).
    assert member_1["cone_distance"] == pytest.approx(member_2["cone_distance"], abs=1e-6)
    assert member_1["pitch_radius"] == 40.0  # module(4) * tooth_count(20) / 2
    assert member_2["pitch_radius"] == 80.0
    mesh_preview = pair["mesh_preview"]
    assert len(mesh_preview["member_1_teeth"]) == 4
    assert len(mesh_preview["member_2_teeth"]) == 4
    x1, _y1 = mesh_preview["center_1"]
    x2, _y2 = mesh_preview["center_2"]
    assert x2 - x1 == pytest.approx(mesh_preview["pitch_radius_1"] + mesh_preview["pitch_radius_2"])


def test_bevel_pair_preview_rejects_tooth_counts_below_four():
    response = _bevel_pair_preview(
        bevel_pair={
            "module": 4.0,
            "member_1": {"tooth_count": 2},
            "member_2": {"tooth_count": 40},
            "face_width": 14.9,
        }
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_preview_parameters"
