"""DIDSA-VR plan, phase 2: the reference flag on what the convert-entities routes make, `convert-entities/face` (a perpendicular flat face as a line, a round face
whose axis is perpendicular as a live centre, even for a blind hole whose rim is not in the sketch plane), and the clean-up of helpers nothing depends on any more.
Needs a real pythonocc-core environment."""

import json
import math

import pytest

from app.document.extrude import compute_part_bodies
from app.document.native_format import export_native, import_native
from app.document.reference_signature import BodyFaceMeasurer
from app.document.router import get_part_or_404
from app.document.store import get_document
from app.sketch.store import all_sketches
from tests.test_circle_centre_reference import _new_sketch, _points
from tests.test_reference_identity import _feature, _json, _polygon_extrude, client


def _plate_with_blind_hole(depth_from: float = 4.0):
    """A 20 x 20 x 10 plate (XY, z 0..10) with a radius-3 hole at (10, 10) cut from the TOP down to z = `depth_from`: its wall is a cylinder whose rim (z 10) is NOT in
    the XY sketch plane. Returns (part id, body id, hole sketch feature, hole cut feature)."""
    part_id, _sketch, extrude, _ = _polygon_extrude([(0, 0), (20, 0), (20, 20), (0, 20)])
    hole = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    centre = _json(client.post(f"/sketch/sketches/{hole['sketch_id']}/points", json={"x": 10.0, "y": 10.0}))
    circle = _json(client.post(f"/sketch/sketches/{hole['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": 3.0, "angle": 0.0}))
    cut = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": hole["id"], "extrude_type": "cut", "start_distance": depth_from, "end_distance": 10.0, "target_body_ids": [extrude["id"]]},
        )
    )
    return part_id, extrude["id"], hole, cut, centre["id"], circle["radius_point_id"]


def _face(part_id: str, body_id: str, kind: str, pick=lambda sig: True) -> int:
    body = compute_part_bodies(get_part_or_404(part_id))[body_id]
    measurer = BodyFaceMeasurer(body)
    for i in range(measurer.count):
        sig = measurer.signature(i)
        if sig.surface_kind == kind and pick(sig):
            return i
    raise AssertionError(f"no {kind} face")


def _convert(part_id: str, sketch: dict, route: str, **payload):
    return client.post(f"/document/parts/{part_id}/features/sketch/{sketch['id']}/convert-entities/{route}", json=payload)


def _export(sketch: dict) -> dict:
    return _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/export"))


def _plate():
    return _polygon_extrude([(0, 0), (20, 0), (20, 20), (0, 20)])


# --- 2.1 the flag -------------------------------------------------------------------------------------------------------


def test_a_reference_convert_flags_what_it_makes_and_an_ordinary_one_does_not():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    flagged = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    plain = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=1))
    assert flagged["is_reference"] is True and plain["is_reference"] is False
    assert set(_export(sketch)["reference_ids"]) == {flagged["id"]}


def test_an_ordinary_convert_takes_a_flagged_helper_over_as_real_geometry():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    flagged = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    again = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0))
    assert again["id"] == flagged["id"] and again["is_reference"] is False
    assert "reference_ids" not in _export(sketch)


def test_a_reference_convert_of_an_existing_real_point_does_not_make_it_a_helper():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    real = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0))
    again = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    assert again["id"] == real["id"] and again["is_reference"] is False


def test_the_flag_survives_save_and_open_and_an_old_file_without_it_loads():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    flagged = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    data = json.loads(json.dumps(export_native(get_document(), all_sketches(), part_id)))
    _, sketches = import_native(data)
    assert sketches[sketch["sketch_id"]].reference_ids == {flagged["id"]}
    for entry in data["sketches"]:
        entry.pop("reference_ids", None)
    _, old = import_native(data)
    assert old[sketch["sketch_id"]].reference_ids == set()


def test_the_flag_is_on_the_point_listing_too():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    flagged = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    solved = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/solve-and-refresh"))
    assert {p["id"]: p["is_reference"] for p in solved["points"]}[flagged["id"]] is True


# --- 2.2 faces ----------------------------------------------------------------------------------------------------------


def test_a_perpendicular_flat_face_becomes_a_pinned_line_between_its_extreme_corners():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    face = _face(part_id, extrude["id"], "plane", lambda s: abs(s.direction[1]) > 0.99 and s.position[1] < 1.0)  # the y = 0 side
    result = _json(_convert(part_id, sketch, "face", body_id=extrude["id"], face_index=face, reference=True))
    assert result["kind"] == "line" and result["line"]["construction"] is True and result["line"]["is_reference"] is True
    ends = sorted([(round(result["start_point"]["x"], 6), round(result["start_point"]["y"], 6)), (round(result["end_point"]["x"], 6), round(result["end_point"]["y"], 6))])
    assert ends == [(0.0, 0.0), (20.0, 0.0)]
    assert result["start_point"]["is_locked"] and result["end_point"]["is_locked"]
    assert math.isclose(result["line"]["length"], 20.0)


def test_converting_the_same_face_twice_gives_one_line():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    face = _face(part_id, extrude["id"], "plane", lambda s: abs(s.direction[0]) > 0.99 and s.position[0] > 19.0)  # the x = 20 side
    first = _json(_convert(part_id, sketch, "face", body_id=extrude["id"], face_index=face))
    second = _json(_convert(part_id, sketch, "face", body_id=extrude["id"], face_index=face))
    assert first["line"]["id"] == second["line"]["id"]
    assert len(_json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines"))) == 1


def test_a_flat_face_parallel_to_the_sketch_plane_is_refused():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    top = _face(part_id, extrude["id"], "plane", lambda s: abs(s.direction[2]) > 0.99 and s.position[2] > 5.0)
    response = _convert(part_id, sketch, "face", body_id=extrude["id"], face_index=top)
    assert response.status_code == 422 and response.json()["detail"]["type"] == "face_not_perpendicular"
    assert _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines")) == []


def test_a_blind_holes_wall_gives_a_live_centre_although_its_rim_is_not_in_the_sketch_plane():
    part_id, body_id, *_ = _plate_with_blind_hole()
    sketch = _new_sketch(part_id)
    wall = _face(part_id, body_id, "cylinder")
    result = _json(_convert(part_id, sketch, "face", body_id=body_id, face_index=wall, reference=True))
    assert result["kind"] == "centre" and result["center_point"]["is_reference"] is True
    assert (result["center_point"]["x"], result["center_point"]["y"]) == pytest.approx((10.0, 10.0))
    refs = all_sketches()[sketch["sketch_id"]].external_references
    assert refs[result["center_point"]["id"]].kind == "circle_centre"
    assert _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/circles")) == []  # a centre only: no shape made
    again = _json(_convert(part_id, sketch, "face", body_id=body_id, face_index=wall, reference=True))
    assert again["center_point"]["id"] == result["center_point"]["id"]


def test_the_face_centre_follows_the_hole_when_an_upstream_edit_moves_it():
    part_id, body_id, hole, _cut, centre_id, radius_id = _plate_with_blind_hole()
    sketch = _new_sketch(part_id)
    wall = _face(part_id, body_id, "cylinder")
    centre = _json(_convert(part_id, sketch, "face", body_id=body_id, face_index=wall, reference=True))["center_point"]
    _json(client.patch(f"/sketch/sketches/{hole['sketch_id']}/points/{centre_id}", json={"x": 6.0, "y": 8.0}))
    _json(client.patch(f"/sketch/sketches/{hole['sketch_id']}/points/{radius_id}", json={"x": 9.0, "y": 8.0}))
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"]
    point = _points(sketch)[centre["id"]]
    assert (point["x"], point["y"]) == pytest.approx((6.0, 8.0))


def test_a_face_centre_whose_hole_is_gone_is_flagged_not_silently_moved():
    part_id, body_id, hole, cut, *_ = _plate_with_blind_hole()
    sketch = _new_sketch(part_id)
    wall = _face(part_id, body_id, "cylinder")
    centre = _json(_convert(part_id, sketch, "face", body_id=body_id, face_index=wall, reference=True))["center_point"]
    # the cut now goes right through: the circular edge the reference names (the hole's floor rim) no longer exists
    _json(client.patch(f"/document/parts/{part_id}/extrude-features/{cut['id']}", json={"start_distance": 0.0, "end_distance": 10.0}))
    feature = _feature(part_id, sketch["id"])
    point = _points(sketch)[centre["id"]]
    assert feature["has_lost_reference"] or (point["x"], point["y"]) == pytest.approx((10.0, 10.0))  # flagged, or still correctly on the hole's axis; never elsewhere


# --- 2.3 clean-up --------------------------------------------------------------------------------------------------------


def test_removing_the_last_constraint_on_a_reference_helper_removes_the_helper():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    face = _face(part_id, extrude["id"], "plane", lambda s: abs(s.direction[1]) > 0.99 and s.position[1] < 1.0)
    line = _json(_convert(part_id, sketch, "face", body_id=extrude["id"], face_index=face, reference=True))["line"]
    point = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 9.0, "y": 2.0}))
    constraint = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/constraints", json={"type": "at_midpoint", "point_id": point["id"], "line_id": line["id"]}))
    assert line["id"] in {l["id"] for l in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines"))}
    assert client.delete(f"/sketch/sketches/{sketch['sketch_id']}/constraints/{constraint['id']}").status_code == 204
    assert _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines")) == []
    remaining = {p["id"] for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}
    assert line["start_point_id"] not in remaining and line["end_point_id"] not in remaining and point["id"] in remaining
    assert all_sketches()[sketch["sketch_id"]].external_references == {}
    assert "reference_ids" not in _export(sketch)


def test_a_helper_stays_while_another_constraint_still_uses_it_and_goes_with_the_last_one():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    face = _face(part_id, extrude["id"], "plane", lambda s: abs(s.direction[1]) > 0.99 and s.position[1] < 1.0)
    line = _json(_convert(part_id, sketch, "face", body_id=extrude["id"], face_index=face, reference=True))["line"]
    a = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 9.0, "y": 2.0}))
    b = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 5.0, "y": 3.0}))
    first = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/constraints", json={"type": "at_midpoint", "point_id": a["id"], "line_id": line["id"]}))
    second = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/constraints", json={"type": "point_on_line", "point_id": b["id"], "line_id": line["id"]}))
    client.delete(f"/sketch/sketches/{sketch['sketch_id']}/constraints/{first['id']}")
    assert len(_json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines"))) == 1
    client.delete(f"/sketch/sketches/{sketch['sketch_id']}/constraints/{second['id']}")
    assert _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines")) == []


def test_a_helper_real_geometry_depends_on_is_never_removed():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    corner = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    other = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 5.0, "y": 5.0}))
    _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": corner["id"], "end_point_id": other["id"]}))
    point = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 1.0, "y": 1.0}))
    c = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/constraints", json={"type": "distance", "point_a_id": corner["id"], "point_b_id": point["id"], "distance": 3.0}))
    client.delete(f"/sketch/sketches/{sketch['sketch_id']}/constraints/{c['id']}")
    assert corner["id"] in {p["id"] for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}


def test_a_sketch_with_no_helpers_is_untouched_by_a_deletion():
    part_id, _sk, extrude, _ = _plate()
    sketch = _new_sketch(part_id)
    corner = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0))  # ordinary, not a helper
    point = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 1.0, "y": 1.0}))
    c = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/constraints", json={"type": "distance", "point_a_id": corner["id"], "point_b_id": point["id"], "distance": 3.0}))
    client.delete(f"/sketch/sketches/{sketch['sketch_id']}/constraints/{c['id']}")
    assert corner["id"] in {p["id"] for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}
