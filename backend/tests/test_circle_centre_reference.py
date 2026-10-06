"""Reference identity, item 4 (docs/reference-identity-design.md): the centre of a converted circular edge is a live reference (`kind="circle_centre"`), so the Circle /
Arc built on it follows its hole or boss when an upstream edit moves or resizes it, and is flagged - never silently rebound - when the edge is reshaped or gone.
Needs a real pythonocc-core environment."""

import dataclasses
import json
import math

import pytest

from app.document.extrude import compute_part_bodies
from app.document.native_format import export_native, import_native
from app.document.reference_signature import BodyEdgeMeasurer
from app.document.router import get_part_or_404
from app.document.store import get_document
from app.sketch.reference_signature import EdgeSignature
from app.sketch.store import all_sketches
from tests.test_reference_identity import _feature, _fillet, _json, client


def _cylinder(radius: float = 5.0, depth: float = 10.0):
    """A cylinder from a circle sketch (centre at the origin) extruded `depth`. Returns (part, base sketch, extrude, centre point id, radius point id)."""
    part_id = _json(client.post("/document/parts", json={"name": "P"}))["id"]
    base = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    centre = _json(client.post(f"/sketch/sketches/{base['sketch_id']}/points", json={"x": 0.0, "y": 0.0}))
    circle = _json(client.post(f"/sketch/sketches/{base['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}))
    extrude = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": base["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": depth, "target_body_ids": []},
        )
    )
    return part_id, base, extrude, centre["id"], circle["radius_point_id"]


def _circle_edge_index(part_id: str, body_id: str, z: float) -> int:
    """The circular edge at height `z` that borders the cylinder wall (as the Part stands now)."""
    body = compute_part_bodies(get_part_or_404(part_id))[body_id]
    for i, sig in enumerate(BodyEdgeMeasurer(body).all()):
        if sig.curve_kind == "circle" and abs(sig.centre[2] - z) < 1e-6 and "cylinder" in sig.face_kinds:
            return i
    raise AssertionError("no circular edge at that height")


def _new_sketch(part_id: str):
    return _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))


def _convert_edge(part_id: str, sketch: dict, body_id: str, edge_index: int, **extra):
    return _json(
        client.post(
            f"/document/parts/{part_id}/features/sketch/{sketch['id']}/convert-entities/edge",
            json={"body_id": body_id, "edge_index": edge_index, **extra},
        )
    )


def _points(sketch: dict) -> dict:
    return {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}


def _radius_of(points: dict, circle: dict) -> float:
    c, r = points[circle["center_point_id"]], points[circle["radius_point_id"]]
    return math.hypot(r["x"] - c["x"], r["y"] - c["y"])


def _move_base_circle(base: dict, centre_id: str, radius_id: str, cx: float, cy: float, radius: float):
    _json(client.patch(f"/sketch/sketches/{base['sketch_id']}/points/{centre_id}", json={"x": cx, "y": cy}))
    _json(client.patch(f"/sketch/sketches/{base['sketch_id']}/points/{radius_id}", json={"x": cx + radius, "y": cy}))


# --- the reference ------------------------------------------------------------------------------------------------------


def test_converting_a_circular_edge_makes_its_centre_a_live_reference_with_the_edges_signature():
    part_id, base, extrude, *_ = _cylinder()
    sketch = _new_sketch(part_id)
    result = _convert_edge(part_id, sketch, extrude["id"], _circle_edge_index(part_id, extrude["id"], 0.0))
    circle = result["circle"]
    refs = all_sketches()[sketch["sketch_id"]].external_references
    ref = refs[circle["center_point_id"]]
    assert ref.kind == "circle_centre" and isinstance(ref.signature, EdgeSignature)
    assert ref.signature.curve_kind == "circle" and ref.signature.radius == pytest.approx(5.0)
    assert result["center_point"]["is_locked"] is True
    assert _radius_of(_points(sketch), circle) == pytest.approx(5.0)
    assert not _feature(part_id, sketch["id"])["has_lost_reference"]


def test_converting_the_same_edge_twice_shares_one_live_centre():
    part_id, base, extrude, *_ = _cylinder()
    sketch = _new_sketch(part_id)
    edge = _circle_edge_index(part_id, extrude["id"], 0.0)
    first = _convert_edge(part_id, sketch, extrude["id"], edge)["circle"]
    second = _convert_edge(part_id, sketch, extrude["id"], edge)["circle"]
    assert first["center_point_id"] == second["center_point_id"]
    refs = all_sketches()[sketch["sketch_id"]].external_references
    assert sum(1 for r in refs.values() if r.kind == "circle_centre") == 1


# --- following ----------------------------------------------------------------------------------------------------------


def test_the_converted_circle_follows_its_hole_when_an_upstream_edit_moves_and_resizes_it():
    part_id, base, extrude, centre_id, radius_id = _cylinder()
    sketch = _new_sketch(part_id)
    circle = _convert_edge(part_id, sketch, extrude["id"], _circle_edge_index(part_id, extrude["id"], 0.0))["circle"]
    _move_base_circle(base, centre_id, radius_id, 4.0, 3.0, 7.0)

    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"] and feature["moved_reference_point_ids"] == []
    points = _points(sketch)
    assert (points[circle["center_point_id"]]["x"], points[circle["center_point_id"]]["y"]) == pytest.approx((4.0, 3.0))
    assert _radius_of(points, circle) == pytest.approx(7.0)
    north, east, south, west = (points[i] for i in circle["cardinal_point_ids"])
    assert (north["x"], north["y"]) == pytest.approx((4.0, 10.0)) and (east["x"], east["y"]) == pytest.approx((11.0, 3.0))
    assert (south["x"], south["y"]) == pytest.approx((4.0, -4.0)) and (west["x"], west["y"]) == pytest.approx((-3.0, 3.0))
    # everything on the circle stays pinned, and a solve keeps it where it was put
    assert all(points[i]["is_locked"] for i in [circle["center_point_id"], circle["radius_point_id"], *circle["cardinal_point_ids"]])
    _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/solve"))
    assert _radius_of(_points(sketch), circle) == pytest.approx(7.0)


def test_a_converted_arc_follows_its_centre_and_both_ends_when_the_part_moves():
    part_id = _json(client.post("/document/parts", json={"name": "P"}))["id"]
    base = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    sid = base["sketch_id"]
    centre = _json(client.post(f"/sketch/sketches/{sid}/points", json={"x": 0.0, "y": 0.0}))
    start = _json(client.post(f"/sketch/sketches/{sid}/points", json={"x": 5.0, "y": 0.0}))
    arc = _json(client.post(f"/sketch/sketches/{sid}/arcs", json={"center_point_id": centre["id"], "start_point_id": start["id"], "end_angle": math.pi}))
    _json(client.post(f"/sketch/sketches/{sid}/lines", json={"start_point_id": arc["end_point_id"], "end_point_id": start["id"]}))
    extrude = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": base["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []},
        )
    )
    body = compute_part_bodies(get_part_or_404(part_id))[extrude["id"]]
    edge = next(i for i, s in enumerate(BodyEdgeMeasurer(body).all()) if s.curve_kind == "circle" and abs(s.centre[2]) < 1e-6)
    sketch = _new_sketch(part_id)
    converted = _convert_edge(part_id, sketch, extrude["id"], edge)["arc"]
    refs = all_sketches()[sketch["sketch_id"]].external_references
    assert {refs[converted[k]].kind for k in ("center_point_id", "start_point_id", "end_point_id")} == {"circle_centre", "vertex"}

    for pid, (x, y) in [(centre["id"], (2.0, 1.0)), (start["id"], (7.0, 1.0)), (arc["end_point_id"], (-3.0, 1.0))]:
        _json(client.patch(f"/sketch/sketches/{sid}/points/{pid}", json={"x": x, "y": y}))
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"], feature
    points = _points(sketch)
    assert (points[converted["center_point_id"]]["x"], points[converted["center_point_id"]]["y"]) == pytest.approx((2.0, 1.0))
    assert (points[converted["start_point_id"]]["x"], points[converted["start_point_id"]]["y"]) == pytest.approx((7.0, 1.0))


def test_the_circle_follows_a_rim_that_moves_with_an_extrude_start_change():
    part_id, base, extrude, *_ = _cylinder()
    sketch = _new_sketch(part_id)
    circle = _convert_edge(part_id, sketch, extrude["id"], _circle_edge_index(part_id, extrude["id"], 0.0))["circle"]
    _json(client.patch(f"/document/parts/{part_id}/extrude-features/{extrude['id']}", json={"start_distance": 3.0}))  # the rim leaves the sketch plane's height
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"] and feature["moved_reference_point_ids"] == []
    assert _radius_of(_points(sketch), circle) == pytest.approx(5.0)


# --- flagged, never silently rebound ------------------------------------------------------------------------------------


def _rim_filleted_upstream():
    """Cylinder; a fillet on its TOP rim; a Sketch referencing the BOTTOM rim. Returns the pieces and a function that moves the fillet onto the bottom rim."""
    part_id, base, extrude, centre_id, radius_id = _cylinder()
    top = _circle_edge_index(part_id, extrude["id"], 10.0)
    bottom = _circle_edge_index(part_id, extrude["id"], 0.0)
    fillet = _fillet(part_id, extrude["id"], top, radius=1.0)
    sketch = _new_sketch(part_id)
    # the bottom rim, in the Part as the Sketch sees it (after the top fillet)
    index = _circle_edge_index(part_id, extrude["id"], 0.0)
    circle = _convert_edge(part_id, sketch, extrude["id"], index)["circle"]

    def reshape_the_bottom_rim():
        _json(
            client.patch(
                f"/document/parts/{part_id}/fillet-features/{fillet['id']}",
                json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": bottom}]},
            )
        )

    return part_id, extrude, sketch, circle, reshape_the_bottom_rim


def test_a_rim_that_is_reshaped_upstream_is_flagged_potentially_moved_not_silently_followed():
    part_id, extrude, sketch, circle, reshape = _rim_filleted_upstream()
    assert not _feature(part_id, sketch["id"])["moved_reference_point_ids"]
    reshape()
    feature = _feature(part_id, sketch["id"])
    centre_id = circle["center_point_id"]
    assert feature["moved_reference_point_ids"] == [centre_id] and not feature["has_lost_reference"]
    assert feature["reference_reasons"][centre_id] == "fingerprint_changed_in_place"


def test_confirming_a_reshaped_circle_centre_clears_the_flag_and_reattaching_picks_another_edge():
    part_id, extrude, sketch, circle, reshape = _rim_filleted_upstream()
    reshape()
    base = f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references"
    centre_id = circle["center_point_id"]
    statuses = _json(client.get(base))
    assert [(s["point_id"], s["kind"], s["status"]) for s in statuses] == [(centre_id, "circle_centre", "potentially_moved")]

    # re-attach to the circle where the cylinder wall now meets the fillet, a smaller-radius-or-higher rim: any circular edge in the XY-parallel plane is valid
    body = compute_part_bodies(get_part_or_404(part_id))[extrude["id"]]
    target = next(i for i, s in enumerate(BodyEdgeMeasurer(body).all()) if s.curve_kind == "circle" and abs(s.centre[2]) > 0.5 and abs(s.centre[2] - 10.0) > 0.5)
    point = _json(client.post(f"{base}/{centre_id}/reattach", json={"body_id": extrude["id"], "edge_index": target}))
    assert point["is_locked"]
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"] and feature["moved_reference_point_ids"] == []
    assert all_sketches()[sketch["sketch_id"]].external_references[centre_id].vertex_index == target

    # a second flag, then Keep
    reshape_again = _json(client.get(base))
    assert [s["status"] for s in reshape_again] == ["ok"]
    ref = all_sketches()[sketch["sketch_id"]].external_references[centre_id]
    stale = dataclasses.replace(ref.signature, face_kinds=("cone", "cone"), face_normals=((1.0, 0.0, 0.0), (0.0, 1.0, 0.0)))
    all_sketches()[sketch["sketch_id"]].external_references[centre_id] = dataclasses.replace(ref, signature=stale)
    assert _feature(part_id, sketch["id"])["moved_reference_point_ids"] == [centre_id]
    _json(client.post(f"{base}/{centre_id}/confirm"))
    assert _feature(part_id, sketch["id"])["moved_reference_point_ids"] == []


def test_reattaching_a_circle_centre_needs_a_circular_edge_and_a_vertex_reference_needs_a_vertex():
    part_id, base_sketch, extrude, *_ = _cylinder()
    sketch = _new_sketch(part_id)
    circle = _convert_edge(part_id, sketch, extrude["id"], _circle_edge_index(part_id, extrude["id"], 0.0))["circle"]
    base = f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references/{circle['center_point_id']}/reattach"
    assert client.post(base, json={"body_id": extrude["id"], "vertex_index": 0}).status_code == 422  # edge_required
    body = compute_part_bodies(get_part_or_404(part_id))[extrude["id"]]
    seam = next(i for i, s in enumerate(BodyEdgeMeasurer(body).all()) if s.curve_kind == "line")
    refused = client.post(base, json={"body_id": extrude["id"], "edge_index": seam})
    assert refused.status_code == 422 and refused.json()["detail"]["type"] == "not_a_circular_edge"
    assert client.post(base, json={"body_id": extrude["id"], "edge_index": 999}).status_code == 422

    # a vertex reference refuses an edge-only payload
    vertex_sketch = _new_sketch(part_id)
    point = _json(
        client.post(
            f"/document/parts/{part_id}/features/sketch/{vertex_sketch['id']}/external-references",
            json={"body_id": extrude["id"], "vertex_index": 0},
        )
    )
    vertex_url = f"/document/parts/{part_id}/features/sketch/{vertex_sketch['id']}/external-references/{point['id']}/reattach"
    assert client.post(vertex_url, json={"body_id": extrude["id"], "edge_index": 0}).status_code == 422


def test_an_old_arc_style_centre_without_a_reference_still_loads_and_behaves_as_before():
    part_id, base_sketch, extrude, *_ = _cylinder()
    sketch = _new_sketch(part_id)
    circle = _convert_edge(part_id, sketch, extrude["id"], _circle_edge_index(part_id, extrude["id"], 0.0))["circle"]
    obj = all_sketches()[sketch["sketch_id"]]
    del obj.external_references[circle["center_point_id"]]  # as a file saved before this overhaul has it: a plain, FixedConstraint-pinned centre
    obj.add_fixed_constraint(circle["center_point_id"])
    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"] and feature["lost_reference_point_ids"] == []


# --- persistence ---------------------------------------------------------------------------------------------------------


def test_a_circle_centre_reference_survives_a_native_save_and_load():
    part_id, base_sketch, extrude, *_ = _cylinder()
    sketch = _new_sketch(part_id)
    circle = _convert_edge(part_id, sketch, extrude["id"], _circle_edge_index(part_id, extrude["id"], 0.0))["circle"]
    original = all_sketches()[sketch["sketch_id"]].external_references[circle["center_point_id"]]
    data = json.loads(json.dumps(export_native(get_document(), all_sketches(), part_id)))
    _, sketches = import_native(data)
    loaded = sketches[sketch["sketch_id"]].external_references[circle["center_point_id"]]
    assert loaded.kind == "circle_centre" and loaded.signature == original.signature and isinstance(loaded.signature, EdgeSignature)
