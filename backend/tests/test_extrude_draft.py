"""Extrude draft option: real-OCCT tests for `ExtrudeFeature.draft_angle`/
`draft_outward` (`app.document.extrude._apply_draft`/`_drafted_prism_for_
face`) plus the router's `_validate_draft_payload` (angle range, mutual
exclusion with thin-wall `thickness`, single-profile restriction).

The neutral plane is always the Sketch plane: the cross-section there stays
exactly the sketched size, and each lateral wall tilts by `draft_angle` -
outward (wider away from the plane) or inward (narrower). For a w x l
rectangle prismed a height h with per-side offset growing at rate
t = +/-tan(angle), the volume is the integral of (w + 2tz)(l + 2tz) dz:
    h*w*l + t*h^2*(w + l) + 4*t^2*h^3/3
which the tests below check against directly."""

import math

import pytest
from fastapi.testclient import TestClient
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GProp import GProp_GProps

from app.document.extrude import compute_part_bodies
from app.document.models import ExtrudeFeature, ExtrudeType
from app.document.native_format import _feature_from_dict, _feature_to_dict
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers -----------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201
    return response.json()


def _add_rectangle(sketch_id: str, x0: float, y0: float, width: float, height: float) -> None:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + width, y0), (x0 + width, y0 + height), (x0, y0 + height)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])


def _create_rectangle_sketch_feature(part_id: str, *, width: float = 20.0, height: float = 10.0) -> dict:
    feature = _create_sketch_feature(part_id, "XY")
    _add_rectangle(feature["sketch_id"], 0.0, 0.0, width, height)
    return feature


def _create_extrude(part_id: str, sketch_feature_id: str, **overrides):
    payload = {
        "sketch_feature_id": sketch_feature_id,
        "extrude_type": "boss",
        "start_distance": 0.0,
        "end_distance": 10.0,
        "target_body_ids": [],
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/extrude-features", json=payload)


def _single_body(part_id: str):
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200, response.text
    body_ids = [entry["body_id"] for entry in response.json()]
    assert len(body_ids) == 1
    shape = compute_part_bodies(get_part_or_404(part_id))[body_ids[0]]
    assert BRepCheck_Analyzer(shape).IsValid()
    return shape


def _volume(shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


def _bbox(shape) -> tuple[float, float, float, float, float, float]:
    box = Bnd_Box()
    brepbndlib.Add(shape, box, False)
    return box.Get()


def _expected_volume(width: float, length: float, height: float, angle_deg: float, outward: bool) -> float:
    t = math.tan(math.radians(angle_deg)) * (1 if outward else -1)
    return height * width * length + t * height**2 * (width + length) + 4 * t**2 * height**3 / 3


# --- Geometry ----------------------------------------------------------------


def test_outward_draft_grows_the_far_end_and_keeps_the_sketch_plane_section():
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"], width=20.0, height=10.0)
    response = _create_extrude(part["id"], sketch["id"], draft_angle=5.0, draft_outward=True)
    assert response.status_code == 201, response.text
    assert response.json()["draft_angle"] == 5.0
    assert response.json()["draft_outward"] is True

    shape = _single_body(part["id"])
    grow = 10.0 * math.tan(math.radians(5.0))
    xmin, ymin, zmin, xmax, ymax, zmax = _bbox(shape)
    # Widest at the far end (z=10), exactly the sketched size at z=0.
    assert xmin == pytest.approx(-grow, abs=1e-3)
    assert xmax == pytest.approx(20.0 + grow, abs=1e-3)
    assert ymax == pytest.approx(10.0 + grow, abs=1e-3)
    assert zmin == pytest.approx(0.0, abs=1e-3)
    assert zmax == pytest.approx(10.0, abs=1e-3)
    assert _volume(shape) == pytest.approx(_expected_volume(20.0, 10.0, 10.0, 5.0, True), rel=1e-4)
    assert _volume(shape) > 20.0 * 10.0 * 10.0


def test_inward_draft_shrinks_the_far_end():
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"], width=20.0, height=10.0)
    response = _create_extrude(part["id"], sketch["id"], draft_angle=5.0, draft_outward=False)
    assert response.status_code == 201, response.text

    shape = _single_body(part["id"])
    xmin, ymin, zmin, xmax, ymax, zmax = _bbox(shape)
    # The sketch-plane section is the widest part - untouched.
    assert xmin == pytest.approx(0.0, abs=1e-3)
    assert xmax == pytest.approx(20.0, abs=1e-3)
    assert _volume(shape) == pytest.approx(_expected_volume(20.0, 10.0, 10.0, 5.0, False), rel=1e-4)
    assert _volume(shape) < 20.0 * 10.0 * 10.0


def test_symmetric_outward_draft_widens_both_ends_away_from_the_sketch_plane():
    """A span straddling the Sketch plane (-5..5) drafts each side away from
    the plane - both ends widen, the sketch-plane section is the narrowest."""
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"], width=20.0, height=10.0)
    response = _create_extrude(
        part["id"], sketch["id"], start_distance=-5.0, end_distance=5.0, draft_angle=5.0
    )
    assert response.status_code == 201, response.text

    shape = _single_body(part["id"])
    grow = 5.0 * math.tan(math.radians(5.0))
    xmin, _ymin, zmin, xmax, _ymax, zmax = _bbox(shape)
    assert xmin == pytest.approx(-grow, abs=1e-3)
    assert xmax == pytest.approx(20.0 + grow, abs=1e-3)
    assert zmin == pytest.approx(-5.0, abs=1e-3)
    assert zmax == pytest.approx(5.0, abs=1e-3)
    assert _volume(shape) == pytest.approx(2 * _expected_volume(20.0, 10.0, 5.0, 5.0, True), rel=1e-4)


def test_draft_behind_the_sketch_plane_still_tapers_away_from_it():
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"], width=20.0, height=10.0)
    response = _create_extrude(
        part["id"], sketch["id"], start_distance=-10.0, end_distance=0.0, draft_angle=5.0, draft_outward=True
    )
    assert response.status_code == 201, response.text

    shape = _single_body(part["id"])
    grow = 10.0 * math.tan(math.radians(5.0))
    xmin, _ymin, zmin, xmax, _ymax, zmax = _bbox(shape)
    assert xmax == pytest.approx(20.0 + grow, abs=1e-3)
    assert zmin == pytest.approx(-10.0, abs=1e-3)
    assert zmax == pytest.approx(0.0, abs=1e-3)
    assert _volume(shape) == pytest.approx(_expected_volume(20.0, 10.0, 10.0, 5.0, True), rel=1e-4)


def test_no_draft_is_unchanged_default():
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"], width=20.0, height=10.0)
    response = _create_extrude(part["id"], sketch["id"])
    assert response.status_code == 201
    assert response.json()["draft_angle"] is None
    assert response.json()["draft_outward"] is True
    assert _volume(_single_body(part["id"])) == pytest.approx(2000.0, rel=1e-6)


def test_over_steep_inward_draft_fails_with_draft_extrude_failed():
    """A 10mm-wide profile drafted inward at 45 degrees over 20mm would have
    its opposite walls cross at z=5 - OCCT can't build that."""
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"], width=20.0, height=10.0)
    response = _create_extrude(
        part["id"], sketch["id"], end_distance=20.0, draft_angle=45.0, draft_outward=False
    )
    assert response.status_code == 201
    mesh = client.get(f"/document/parts/{part['id']}/mesh")
    assert mesh.status_code == 422
    assert mesh.json()["detail"]["type"] == "draft_extrude_failed"


# --- Validation --------------------------------------------------------------


@pytest.mark.parametrize("angle", [0.0, 90.0, -5.0, 120.0])
def test_draft_angle_outside_open_range_is_rejected(angle):
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"])
    response = _create_extrude(part["id"], sketch["id"], draft_angle=angle)
    assert response.status_code == 400


def test_draft_and_thickness_are_mutually_exclusive_on_create():
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"])
    response = _create_extrude(part["id"], sketch["id"], draft_angle=5.0, thickness=1.0)
    assert response.status_code == 422
    assert "mutually exclusive" in response.json()["detail"]


def test_draft_and_thickness_are_mutually_exclusive_on_update_unless_thickness_is_cleared():
    part = _create_part()
    sketch = _create_rectangle_sketch_feature(part["id"])
    created = _create_extrude(part["id"], sketch["id"], thickness=1.0)
    assert created.status_code == 201
    url = f"/document/parts/{part['id']}/extrude-features/{created.json()['id']}"

    # Omitted `thickness` keeps the stored thin wall -> conflict.
    conflict = client.patch(url, json={"draft_angle": 5.0})
    assert conflict.status_code == 422

    # An explicit null clears the thin wall in the same PATCH.
    switched = client.patch(url, json={"draft_angle": 5.0, "draft_outward": False, "thickness": None})
    assert switched.status_code == 200, switched.text
    assert switched.json()["thickness"] is None
    assert switched.json()["draft_angle"] == 5.0
    assert switched.json()["draft_outward"] is False

    # Omitting draft_angle keeps it; explicit null turns it off again.
    kept = client.patch(url, json={"end_distance": 12.0})
    assert kept.json()["draft_angle"] == 5.0
    cleared = client.patch(url, json={"draft_angle": None})
    assert cleared.status_code == 200
    assert cleared.json()["draft_angle"] is None


def test_draft_is_rejected_for_a_multi_profile_sketch():
    part = _create_part()
    sketch = _create_sketch_feature(part["id"], "XY")
    _add_rectangle(sketch["sketch_id"], 0.0, 0.0, 10.0, 10.0)
    _add_rectangle(sketch["sketch_id"], 20.0, 0.0, 10.0, 10.0)
    response = _create_extrude(part["id"], sketch["id"], draft_angle=5.0)
    assert response.status_code == 422
    assert "single profile" in response.json()["detail"]

    # Without draft the same two-loop sketch is still a valid Extrude.
    plain = _create_extrude(part["id"], sketch["id"])
    assert plain.status_code == 201
    # ...and turning draft on for it via PATCH is rejected the same way.
    patched = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{plain.json()['id']}", json={"draft_angle": 5.0}
    )
    assert patched.status_code == 422


def test_native_format_round_trips_draft_fields():
    feature = ExtrudeFeature(
        id="e1",
        sketch_feature_id="s1",
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=10.0,
        draft_angle=7.5,
        draft_outward=False,
    )
    restored = _feature_from_dict(_feature_to_dict(feature))
    assert restored.draft_angle == 7.5
    assert restored.draft_outward is False

    legacy = _feature_to_dict(feature)
    del legacy["draft_angle"], legacy["draft_outward"]
    restored_legacy = _feature_from_dict(legacy)
    assert restored_legacy.draft_angle is None
    assert restored_legacy.draft_outward is True
