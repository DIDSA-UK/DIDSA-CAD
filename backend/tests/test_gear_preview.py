"""Tests for the cheap `/gear/preview` endpoint -
`docs/gear-design/08-entry-screen-and-preview.md`. Structurally mirrors
`test_gear_feature.py`/`test_rack_feature.py`'s own shape, but this endpoint
runs only `gear_math` (no OCCT, no tessellation) - real reference-value
checks against known gear dimensions, not just "it runs", same requirement
`test_gear_math.py` already holds itself to.
"""

import math

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
