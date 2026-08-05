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
