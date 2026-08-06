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
    assert len(body["outline_points"]) > 0
    # Every outline point should sit within a small tolerance of the
    # addendum/dedendum band - a sanity bound on the returned polyline, not
    # just "it has some points".
    max_radius = max((x**2 + y**2) ** 0.5 for x, y in body["outline_points"])
    assert max_radius <= 22.5


def test_external_gear_preview_warns_on_undercut_risk_without_blocking():
    # A 6-tooth module-2/20-degree gear is well below the undercut-free
    # minimum (~17.1 teeth) - non-blocking per 00-conventions.md, so this
    # must still return 200 with a warning, not a 422.
    response = _preview(tooth_count=6)
    assert response.status_code == 200, response.json()
    warnings = response.json()["warnings"]
    assert len(warnings) == 1
    assert "undercut" in warnings[0].lower()


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
    # Internal gears aren't checked for the same cutter-undercut risk.
    assert body["warnings"] == []


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


def test_planetary_preview_returns_sun_ring_and_evenly_spaced_planets():
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
