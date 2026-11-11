"""Item 5 (Flutter-testing feedback 2026-11-11): a thin Revolve - the profile's wire is offset in 2D and the ring is revolved
(`app.document.thin_profile`), including a single open chain (a cup, bowl or bell wall). Real OCCT, so it needs pythonocc-core
(the conda env from `tools/`); the volumes are Pappus: V = 2 pi * the integral of x dA about the Y axis."""

import math

import pytest
from fastapi.testclient import TestClient
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer

from app.document.extrude import compute_part_bodies
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

TWO_PI = 2 * math.pi


# --- helpers ---------------------------------------------------------------------------------------------------------------


def _part() -> str:
    response = client.post("/document/parts", json={"name": "Part 1"})
    assert response.status_code == 201
    return response.json()["id"]


def _sketch(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _point(sketch_id: str, x: float, y: float) -> str:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()["id"]


def _line(sketch_id: str, a: str, b: str) -> str:
    response = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a, "end_point_id": b})
    assert response.status_code == 201
    return response.json()["id"]


def _polyline(sketch_id: str, points: list[tuple[float, float]], closed: bool) -> list[str]:
    ids = [_point(sketch_id, x, y) for x, y in points]
    pairs = list(zip(ids, ids[1:])) + ([(ids[-1], ids[0])] if closed else [])
    return [_line(sketch_id, a, b) for a, b in pairs]


def _rect_sketch(part_id: str, x0: float, y0: float, w: float, h: float) -> dict:
    feature = _sketch(part_id)
    _polyline(feature["sketch_id"], [(x0, y0), (x0 + w, y0), (x0 + w, y0 + h), (x0, y0 + h)], closed=True)
    return feature


def _chain_sketch(part_id: str, points: list[tuple[float, float]]) -> dict:
    feature = _sketch(part_id)
    _polyline(feature["sketch_id"], points, closed=False)
    return feature


def _y_axis(part_id: str) -> dict:
    """A one-line Sketch on the Y axis (x = 0), its own Sketch so it is not part of the profile."""
    feature = _sketch(part_id)
    line = _line(feature["sketch_id"], _point(feature["sketch_id"], 0.0, -5.0), _point(feature["sketch_id"], 0.0, 40.0))
    return {"sketch_id": feature["sketch_id"], "entity_type": "line", "entity_id": line}


def _revolve(part_id: str, sketch_feature_id: str, axis: dict, **extra):
    body = {"sketch_feature_id": sketch_feature_id, "axis_ref": axis, "angle": 360.0, "mode": "boss", "target_body_ids": []}
    body.update(extra)
    return client.post(f"/document/parts/{part_id}/revolve-features", json=body)


def _volumes(part_id: str) -> list[float]:
    out = []
    for shape in compute_part_bodies(get_part_or_404(part_id), frozenset()).values():
        props = GProp_GProps()
        brepgprop.VolumeProperties(shape, props)
        out.append(props.Mass())
    return out


def _face_count(part_id: str) -> int:
    (shape,) = compute_part_bodies(get_part_or_404(part_id), frozenset()).values()
    explorer, n = TopExp_Explorer(shape, TopAbs_FACE), 0
    while explorer.More():
        n += 1
        explorer.Next()
    return n


def _closed_setup(x0=30.0, w=20.0, h=10.0):
    part_id = _part()
    sketch = _rect_sketch(part_id, x0, 0.0, w, h)
    return part_id, sketch, _y_axis(part_id)


# --- closed profile: exact volumes ----------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "direction,expected",
    [
        ("outward", 5440.0),  # [28,52]x[-2,12] minus the profile
        ("inward", 4160.0),  # the profile minus [32,48]x[2,8]
        ("symmetric", 4800.0),  # [29,51]x[-1,11] minus [31,49]x[1,9]
    ],
)
def test_thin_closed_revolve_360_has_the_exact_ring_volume(direction, expected):
    part_id, sketch, axis = _closed_setup()
    response = _revolve(part_id, sketch["id"], axis, thickness=2.0, thickness_direction=direction)
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["thickness"] == 2.0 and body["thickness_direction"] == direction
    (volume,) = _volumes(part_id)
    assert volume == pytest.approx(TWO_PI * expected, rel=1e-6)


def test_thin_revolve_at_90_degrees_is_a_quarter_with_flat_end_faces():
    part_id, sketch, axis = _closed_setup()
    assert _revolve(part_id, sketch["id"], axis, thickness=2.0, thickness_direction="outward", angle=90.0).status_code == 201
    (volume,) = _volumes(part_id)
    assert volume == pytest.approx(TWO_PI * 5440.0 / 4, rel=1e-6)
    # An 8-edge ring (the outer and the inner rectangle) -> 8 swept faces + the two flat end faces.
    assert _face_count(part_id) == 10


def test_inward_wall_thicker_than_the_profile_is_a_422():
    part_id, sketch, axis = _closed_setup()
    response = _revolve(part_id, sketch["id"], axis, thickness=6.0, thickness_direction="inward")  # the profile is 10 high
    assert response.status_code == 422
    assert response.json()["detail"] == {"type": "thin_revolve_failed", "reason": "inward_collapsed"}


def test_outward_ring_that_crosses_the_axis_is_a_422():
    part_id, sketch, axis = _closed_setup(x0=3.0, w=10.0)
    response = _revolve(part_id, sketch["id"], axis, thickness=4.0, thickness_direction="outward")
    assert response.status_code == 422
    assert response.json()["detail"] == {"type": "thin_revolve_failed", "reason": "crosses_axis"}


def test_zero_or_negative_thickness_is_a_400():
    part_id, sketch, axis = _closed_setup()
    assert _revolve(part_id, sketch["id"], axis, thickness=0.0).status_code == 400
    assert _revolve(part_id, sketch["id"], axis, thickness=-1.0).status_code == 400


def test_a_thin_cut_removes_a_wall_shaped_groove():
    part_id = _part()
    box = _sketch(part_id)
    _polyline(box["sketch_id"], [(0, 0), (100, 0), (100, 100), (0, 100)], closed=True)
    client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={"sketch_feature_id": box["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 50.0, "target_body_ids": []},
    ).raise_for_status()
    (box_volume,) = _volumes(part_id)
    body_id = client.get(f"/document/parts/{part_id}/mesh").json()[0]["body_id"]
    # A ring section well inside the box, revolved about the Y axis (x = 0) which passes through the box's edge.
    groove = _rect_sketch(part_id, 30.0, 20.0, 20.0, 10.0)
    axis = _y_axis(part_id)
    response = _revolve(
        part_id, groove["id"], axis, thickness=2.0, thickness_direction="inward", mode="cut", target_body_ids=[body_id]
    )
    assert response.status_code == 201, response.text
    volume = sum(_volumes(part_id))  # the groove can leave the part in more than one piece
    # The full ring (4160 * 2 pi) is swept about Y; the box occupies x, z >= 0 (a quarter of that turn) and the ring stays inside it.
    assert box_volume - volume == pytest.approx(TWO_PI * 4160.0 / 4, rel=1e-6)
    assert len(client.get(f"/document/parts/{part_id}/mesh").json()) >= 1


def test_native_round_trip_and_old_files_without_thickness_stay_solid():
    part_id, sketch, axis = _closed_setup()
    thin = _revolve(part_id, sketch["id"], axis, thickness=2.0, thickness_direction="symmetric").json()
    solid_sketch = _rect_sketch(part_id, 60.0, 0.0, 5.0, 5.0)
    solid = _revolve(part_id, solid_sketch["id"], axis).json()
    exported = client.get("/document/export/native", params={"part_id": part_id}).json()
    features = {f["id"]: f for f in exported["document"]["parts"][0]["features"]}
    assert features[thin["id"]]["thickness"] == 2.0 and features[thin["id"]]["thickness_direction"] == "symmetric"
    assert "thickness" not in features[solid["id"]] and "thickness_direction" not in features[solid["id"]]

    assert client.post("/document/import/native", json=exported).status_code in (200, 201)
    again = client.get(f"/document/parts/{part_id}/features").json()
    by_id = {f["id"]: f for f in again}
    assert by_id[thin["id"]]["thickness"] == 2.0 and by_id[thin["id"]]["thickness_direction"] == "symmetric"
    assert by_id[solid["id"]]["thickness"] is None and by_id[solid["id"]]["thickness_direction"] == "outward"


def test_update_with_thickness_null_goes_back_to_a_solid_revolve():
    part_id, sketch, axis = _closed_setup()
    created = _revolve(part_id, sketch["id"], axis, thickness=2.0).json()
    (thin_volume,) = _volumes(part_id)
    # Omitted keeps it ...
    kept = client.patch(f"/document/parts/{part_id}/revolve-features/{created['id']}", json={"angle": 180.0})
    assert kept.status_code == 200 and kept.json()["thickness"] == 2.0
    # ... an explicit null clears it.
    cleared = client.patch(f"/document/parts/{part_id}/revolve-features/{created['id']}", json={"thickness": None, "angle": 360.0})
    assert cleared.status_code == 200 and cleared.json()["thickness"] is None
    (solid_volume,) = _volumes(part_id)
    assert solid_volume == pytest.approx(TWO_PI * 8000.0, rel=1e-6)  # the 20 x 10 rectangle, solid: integral of x dA = 10 * 800
    assert solid_volume > thin_volume


# --- open chain --------------------------------------------------------------------------------------------------------------


def test_l_chain_with_its_base_end_on_the_axis_makes_a_closed_bottom_cup():
    part_id = _part()
    chain = _chain_sketch(part_id, [(0, 0), (20, 0), (20, 15)])
    response = _revolve(part_id, chain["id"], _y_axis(part_id), thickness=2.0, thickness_direction="symmetric")
    assert response.status_code == 201, response.text
    volumes = _volumes(part_id)
    assert len(volumes) == 1
    # union of [0,21]x[-1,1] and [19,21]x[1,15]: integral of x dA = 441 + 560
    assert volumes[0] == pytest.approx(TWO_PI * 1001.0, rel=1e-6)


def test_open_chain_away_from_and_toward_the_axis_put_the_wall_on_the_right_side():
    part_id = _part()
    chain = _chain_sketch(part_id, [(10, 0), (30, 0), (30, 15)])
    axis = _y_axis(part_id)
    away = _revolve(part_id, chain["id"], axis, thickness=2.0, thickness_direction="outward").json()
    (away_volume,) = _volumes(part_id)
    # the wall grows to x in [30, 32] and y in [-2, 0]: [10,32]x[-2,0] union [30,32]x[0,15]
    assert away_volume == pytest.approx(TWO_PI * 1854.0, rel=1e-6)
    client.patch(f"/document/parts/{part_id}/revolve-features/{away['id']}", json={"thickness_direction": "inward"}).raise_for_status()
    (toward_volume,) = _volumes(part_id)
    # toward the axis: x in [28, 30] and y in [0, 2]: [10,30]x[0,2] union [28,30]x[2,15]
    assert toward_volume == pytest.approx(TWO_PI * 1554.0, rel=1e-6)


def test_open_chain_with_both_ends_off_the_axis_is_an_open_tube():
    part_id = _part()
    chain = _chain_sketch(part_id, [(30, 0), (30, 15)])  # a straight vertical line: a tube
    response = _revolve(part_id, chain["id"], _y_axis(part_id), thickness=2.0, thickness_direction="symmetric")
    assert response.status_code == 201, response.text
    (volume,) = _volumes(part_id)
    assert volume == pytest.approx(math.pi * (31**2 - 29**2) * 15, rel=1e-6)


def test_open_chain_across_the_axis_is_a_422():
    part_id = _part()
    chain = _chain_sketch(part_id, [(-10, 0), (10, 0), (10, 15)])
    response = _revolve(part_id, chain["id"], _y_axis(part_id), thickness=2.0)
    assert response.status_code == 422
    assert response.json()["detail"] == {"type": "thin_revolve_failed", "reason": "crosses_axis"}


def test_open_chain_end_almost_on_the_axis_is_refused_as_near_axis():
    part_id = _part()
    chain = _chain_sketch(part_id, [(0.001, 0), (20, 0), (20, 15)])
    response = _revolve(part_id, chain["id"], _y_axis(part_id), thickness=2.0)
    assert response.status_code == 422
    assert response.json()["detail"] == {"type": "thin_revolve_failed", "reason": "near_axis"}


def test_a_sketch_with_a_closed_profile_and_an_open_chain_revolves_the_closed_profile():
    part_id = _part()
    sketch = _rect_sketch(part_id, 30.0, 0.0, 20.0, 10.0)
    _polyline(sketch["sketch_id"], [(70, 0), (90, 0), (90, 15)], closed=False)  # a separate open chain in the same Sketch
    assert _revolve(part_id, sketch["id"], _y_axis(part_id), thickness=2.0, thickness_direction="outward").status_code == 201
    (volume,) = _volumes(part_id)
    assert volume == pytest.approx(TWO_PI * 5440.0, rel=1e-6)


def test_an_open_chain_without_thickness_keeps_the_existing_no_profile_error():
    part_id = _part()
    chain = _chain_sketch(part_id, [(10, 0), (30, 0), (30, 15)])
    response = _revolve(part_id, chain["id"], _y_axis(part_id))
    assert response.status_code == 400
    assert "closed profile" in response.json()["detail"]


def test_sketch_profile_endpoint_reports_a_single_open_chain():
    part_id = _part()
    chain = _chain_sketch(part_id, [(10, 0), (30, 0), (30, 15)])
    assert client.get(f"/sketch/sketches/{chain['sketch_id']}/profile").json()["open_chain"] is True
    closed = _rect_sketch(part_id, 30.0, 0.0, 20.0, 10.0)
    assert client.get(f"/sketch/sketches/{closed['sketch_id']}/profile").json()["open_chain"] is False
    empty = _sketch(part_id)
    assert client.get(f"/sketch/sketches/{empty['sketch_id']}/profile").json()["open_chain"] is False
