"""Variable-pitch Helix (`CurveFeature.pitch_points`): the pitch stated at axial distances, varying
smoothly between them (bug report: "state pitch at different lengths and pitch varies smoothly
between values"). The pitch maths (`app.document.helix_profile`) and the real-OCCT curve, through the
router like `test_curve_features.py`."""

import math

import pytest
from fastapi.testclient import TestClient

from app.document.helix_profile import pchip, pitch_at_height, samples_to_height, samples_to_turns
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _helix_payload(**overrides) -> dict:
    payload = {
        "curve_type": "helix",
        "axis_ref": {"fixed_plane": "XY"},
        "radius": 5.0,
        "pitch_points": [{"at": 0.0, "pitch": 1.0}, {"at": 10.0, "pitch": 3.0}],
        "right_handed": True,
    }
    payload.update(overrides)
    return payload


def _create_helix(part_id: str, **overrides) -> dict:
    response = client.post(f"/document/parts/{part_id}/curve-features", json=_helix_payload(**overrides))
    assert response.status_code == 201, response.text
    return response.json()


def _ends(part_id: str, curve_id: str):
    from app.document.curve import point_and_tangent_at_fraction, resolve_curve
    from app.document.store import get_part_or_404

    part = get_part_or_404(part_id)
    resolved = resolve_curve(part, part.get_feature(curve_id))
    start, _ = point_and_tangent_at_fraction(resolved.wire, resolved.length, 0.0)
    end, _ = point_and_tangent_at_fraction(resolved.wire, resolved.length, 1.0)
    return (start.X(), start.Y(), start.Z()), (end.X(), end.Y(), end.Z())


# --- The pitch maths ---------------------------------------------------------


def test_pchip_passes_through_the_values_and_never_overshoots_them():
    curve = pchip([0.0, 5.0, 10.0], [2.0, 6.0, 2.0])
    assert curve(0.0) == 2.0 and curve(5.0) == pytest.approx(6.0) and curve(10.0) == pytest.approx(2.0)
    values = [curve(x / 10) for x in range(101)]
    assert max(values) <= 6.0 + 1e-12 and min(values) >= 2.0 - 1e-12
    # Smooth: no kink at the middle point.
    assert curve(5.0 - 1e-6) == pytest.approx(curve(5.0 + 1e-6), abs=1e-5)


def test_pchip_of_two_points_is_the_straight_line():
    curve = pchip([0.0, 10.0], [1.0, 3.0])
    assert curve(2.5) == pytest.approx(1.5)


def test_samples_to_height_follow_the_pitch_exactly():
    # dz/dt = 1 + z / 5  ->  t(z) = 5 ln(1 + z / 5): 5 ln 3 turns to reach z = 10.
    samples = samples_to_height(pitch_at_height([0.0, 10.0], [1.0, 3.0]), 10.0)
    assert samples[-1].z == 10.0
    assert samples[-1].t == pytest.approx(5 * math.log(3), rel=1e-8)
    middle = samples[len(samples) // 2]
    assert middle.t == pytest.approx(5 * math.log(1 + middle.z / 5), rel=1e-8)


def test_samples_to_turns_integrate_a_pitch_given_by_turns():
    samples = samples_to_turns(lambda t: 2.0 + t, 4.0)  # z = 2t + t^2 / 2
    assert samples[-1].t == pytest.approx(4.0)
    assert samples[-1].z == pytest.approx(16.0, rel=1e-9)


# --- The curve -----------------------------------------------------------------


def test_constant_pitch_points_make_the_same_helix_as_a_segment():
    part = _create_part()
    by_points = _create_helix(part["id"], pitch_points=[{"at": 0.0, "pitch": 2.0}, {"at": 6.0, "pitch": 2.0}])
    by_segment = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json=_helix_payload(pitch_points=[], segments=[{"pitch": 2.0, "turns": 3.0}]),
    ).json()
    assert by_points["length"] == pytest.approx(by_segment["length"], rel=1e-6)
    assert by_points["total_turns"] == pytest.approx(3.0, rel=1e-9)
    assert by_points["total_height"] == pytest.approx(6.0)
    start, end = _ends(part["id"], by_points["id"])
    assert start == pytest.approx((5.0, 0.0, 0.0), abs=1e-6)
    assert end == pytest.approx((5.0, 0.0, 6.0), abs=1e-5)


def test_a_variable_pitch_helix_ends_where_its_pitch_says():
    part = _create_part()
    curve = _create_helix(part["id"])
    turns = 5 * math.log(3)
    assert curve["pitch_points"] == [{"at": 0.0, "pitch": 1.0}, {"at": 10.0, "pitch": 3.0}]
    assert curve["segments"] == []
    assert curve["total_height"] == pytest.approx(10.0)
    assert curve["total_turns"] == pytest.approx(turns, rel=1e-7)
    _, end = _ends(part["id"], curve["id"])
    angle = 2 * math.pi * turns
    assert end == pytest.approx((5 * math.cos(angle), 5 * math.sin(angle), 10.0), abs=1e-5)


def test_negative_pitches_go_down_the_axis_and_a_taper_angle_uses_the_height():
    part = _create_part()
    curve = _create_helix(
        part["id"],
        pitch_points=[{"at": 0.0, "pitch": -2.0}, {"at": 8.0, "pitch": -2.0}],
        taper_angle_degrees=10.0,
    )
    assert curve["total_height"] == pytest.approx(-8.0)
    assert curve["end_radius"] == pytest.approx(5.0 + 8.0 * math.tan(math.radians(10.0)))
    _, end = _ends(part["id"], curve["id"])
    assert end[2] == pytest.approx(-8.0, abs=1e-6)
    assert math.hypot(end[0], end[1]) == pytest.approx(curve["end_radius"], abs=1e-5)


@pytest.mark.parametrize(
    "pitch_points, message",
    [
        ([{"at": 0.0, "pitch": 2.0}], "at least two"),
        ([{"at": 1.0, "pitch": 2.0}, {"at": 5.0, "pitch": 2.0}], "at 0"),
        ([{"at": 0.0, "pitch": 2.0}, {"at": 5.0, "pitch": 2.0}, {"at": 5.0, "pitch": 3.0}], "further along"),
        ([{"at": 0.0, "pitch": 2.0}, {"at": 5.0, "pitch": 0.0}], "non-zero"),
        ([{"at": 0.0, "pitch": 2.0}, {"at": 5.0, "pitch": -2.0}], "same way"),
    ],
)
def test_bad_pitch_points_are_refused(pitch_points, message):
    part = _create_part()
    response = client.post(
        f"/document/parts/{part['id']}/curve-features", json=_helix_payload(pitch_points=pitch_points)
    )
    assert response.status_code == 422
    assert message in response.text


def test_segments_and_pitch_points_together_are_refused():
    part = _create_part()
    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json=_helix_payload(segments=[{"pitch": 2.0, "turns": 1.0}]),
    )
    assert response.status_code == 422
    assert "not both" in response.text


def test_an_update_switches_between_segments_and_pitch_points():
    part = _create_part()
    curve = _create_helix(part["id"])
    url = f"/document/parts/{part['id']}/curve-features/{curve['id']}"
    as_segments = client.patch(url, json={"segments": [{"pitch": 2.0, "turns": 4.0}]}).json()
    assert as_segments["pitch_points"] == [] and as_segments["total_turns"] == pytest.approx(4.0)
    back = client.patch(url, json={"pitch_points": [{"at": 0.0, "pitch": 1.0}, {"at": 10.0, "pitch": 3.0}]})
    assert back.status_code == 200, back.text
    assert back.json()["segments"] == [] and back.json()["total_height"] == pytest.approx(10.0)
    radius_only = client.patch(url, json={"radius": 6.0}).json()  # keeps the pitch points
    assert radius_only["pitch_points"] == back.json()["pitch_points"]


def test_pitch_points_survive_the_native_round_trip():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native variable helix")
        curve = _create_helix(part["id"], right_handed=False)
        exported = client.get("/document/export/native").json()
        stored = next(f for p in exported["document"]["parts"] for f in p["features"] if f["id"] == curve["id"])
        assert stored["pitch_points"] == curve["pitch_points"]
        assert client.post("/document/import/native", json=exported).status_code == 200
        again = next(f for f in client.get(f"/document/parts/{part['id']}/features").json() if f["id"] == curve["id"])
        assert again["pitch_points"] == curve["pitch_points"]
        assert again["length"] == pytest.approx(curve["length"], rel=1e-9)
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_a_file_from_before_pitch_points_still_loads():
    from app.document.native_format import import_native

    document, _ = import_native(
        {
            "schema_version": 1,
            "document": {
                "id": "d",
                "root_part_id": "p",
                "parts": [
                    {
                        "id": "p",
                        "name": "Part 1",
                        "features": [
                            {
                                "type": "curve",
                                "id": "c",
                                "curve_type": "helix",
                                "axis_ref": {"fixed_plane": "XY"},
                                "radius": 5.0,
                                "end_radius": None,
                                "segments": [{"pitch": 2.0, "turns": 3.0}],
                                "right_handed": True,
                            }
                        ],
                    }
                ],
            },
            "sketches": [],
        }
    )
    assert document.parts["p"].features[0].pitch_points == []
