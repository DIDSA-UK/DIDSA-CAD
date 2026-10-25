"""Gears-and-motion plan M1: `bore_diameter` on `GearFeature` and
`BevelGearFeature` - a through bore on the gear's own axis (real OCCT,
through the router)."""

import math

from fastapi.testclient import TestClient
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GeomAbs import GeomAbs_Cylinder
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import topods

from app.document.extrude import compute_part_bodies
from app.document.native_format import _feature_from_dict, _feature_to_dict
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Bore Part") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_gear(part_id: str, **overrides):
    payload = {"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": 20, "face_width": 5.0}
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/gear-features", json=payload)


def _create_bevel(part_id: str, **overrides):
    payload = {
        "bevel_type": "boss",
        "module": 4.0,
        "tooth_count": 20,
        "face_width": 15.0,
        "pitch_cone_angle_degrees": 26.565,
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/bevel-gear-features", json=payload)


def _shape(part_id: str):
    bodies = compute_part_bodies(get_part_or_404(part_id))
    assert len(bodies) == 1
    return next(iter(bodies.values()))


def _volume(shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return abs(props.Mass())


def _cylinder_radii(shape) -> list[float]:
    radii = []
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while explorer.More():
        surface = BRepAdaptor_Surface(topods.Face(explorer.Current()))
        if surface.GetType() == GeomAbs_Cylinder:
            radii.append(surface.Cylinder().Radius())
        explorer.Next()
    return radii


def test_external_gear_bore_has_a_cylindrical_face_and_removes_the_expected_volume():
    solid_part = _create_part()
    assert _create_gear(solid_part["id"]).status_code == 201
    solid_volume = _volume(_shape(solid_part["id"]))

    part = _create_part()
    response = _create_gear(part["id"], bore_diameter=8.0)
    assert response.status_code == 201, response.json()
    assert response.json()["bore_diameter"] == 8.0
    shape = _shape(part["id"])
    assert any(abs(r - 4.0) < 1e-6 for r in _cylinder_radii(shape))
    expected = math.pi * 4.0**2 * 5.0
    assert abs((solid_volume - _volume(shape)) - expected) / expected < 1e-3


def test_bore_zero_is_the_original_gear_and_a_helical_gear_takes_a_bore():
    a = _create_part()
    b = _create_part()
    assert _create_gear(a["id"]).status_code == 201
    assert _create_gear(b["id"], bore_diameter=0.0).status_code == 201
    assert _volume(_shape(a["id"])) == _volume(_shape(b["id"]))
    assert _create_gear(a["id"]).json()["bore_diameter"] == 0.0

    helical = _create_part()
    plain = _create_part()
    assert _create_gear(plain["id"], helix_angle_degrees=15.0).status_code == 201
    response = _create_gear(helical["id"], helix_angle_degrees=15.0, bore_diameter=8.0)
    assert response.status_code == 201, response.json()
    shape = _shape(helical["id"])
    assert any(abs(r - 4.0) < 1e-6 for r in _cylinder_radii(shape))
    assert _volume(_shape(plain["id"])) - _volume(shape) > 0.9 * math.pi * 16 * 5.0


def test_bore_validation_errors():
    part = _create_part()
    response = _create_gear(part["id"], bore_diameter=-1.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_bore"
    response = _create_gear(part["id"], is_internal=True, tooth_count=60, outer_diameter=140.0, bore_diameter=8.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "bore_on_internal_gear"
    response = _create_gear(part["id"], bore_diameter=38.0)  # root diameter is 35
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "bore_too_large"
    assert get_part_or_404(part["id"]).features == []


def test_gear_bore_can_be_updated_and_the_coarse_preview_has_the_hole():
    part = _create_part()
    feature_id = _create_gear(part["id"]).json()["id"]
    response = client.patch(f"/document/parts/{part['id']}/gear-features/{feature_id}", json={"bore_diameter": 6.0})
    assert response.status_code == 200, response.json()
    assert response.json()["bore_diameter"] == 6.0
    assert any(abs(r - 3.0) < 1e-6 for r in _cylinder_radii(_shape(part["id"])))
    payload = {"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": 20, "face_width": 5.0}
    coarse = client.post(
        f"/document/parts/{part['id']}/gear-features/coarse-preview", json={**payload, "bore_diameter": 8.0}
    )
    assert coarse.status_code == 200, coarse.json()
    bad = client.post(
        f"/document/parts/{part['id']}/gear-features/coarse-preview", json={**payload, "bore_diameter": 38.0}
    )
    assert bad.status_code == 422


def test_native_round_trip_writes_bore_only_when_set():
    part = _create_part()
    gear = _create_gear(part["id"], bore_diameter=8.0).json()
    plain_part = _create_part()
    plain = _create_gear(plain_part["id"]).json()
    features = {f.id: f for f in get_part_or_404(part["id"]).features}
    as_dict = _feature_to_dict(features[gear["id"]])
    assert as_dict["bore_diameter"] == 8.0
    assert _feature_from_dict(as_dict).bore_diameter == 8.0

    plain_feature = get_part_or_404(plain_part["id"]).features[0]
    assert plain_feature.id == plain["id"]
    plain_dict = _feature_to_dict(plain_feature)
    assert "bore_diameter" not in plain_dict
    assert _feature_from_dict(plain_dict).bore_diameter == 0.0


def test_bevel_gear_bore():
    plain = _create_part()
    assert _create_bevel(plain["id"]).status_code == 201
    part = _create_part()
    response = _create_bevel(part["id"], bore_diameter=10.0)
    assert response.status_code == 201, response.json()
    assert response.json()["bore_diameter"] == 10.0
    shape = _shape(part["id"])
    assert any(abs(r - 5.0) < 1e-6 for r in _cylinder_radii(shape))
    assert _volume(shape) < _volume(_shape(plain["id"]))
    too_big = _create_bevel(part["id"], bore_diameter=200.0)
    assert too_big.status_code == 422
    assert too_big.json()["detail"]["type"] == "bore_too_large"
    negative = _create_bevel(part["id"], bore_diameter=-2.0)
    assert negative.json()["detail"]["type"] == "invalid_bore"
