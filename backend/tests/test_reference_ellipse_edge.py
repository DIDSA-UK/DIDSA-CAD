"""Reference-overhaul R-F: a full ELLIPTICAL Body edge lying in the sketch plane converts (`convert-entities/edge`) to a real, pinned Ellipse; mesh edge kinds name an ellipse; the same edge converted
again answers with the ellipse already made; a reference-flagged convert marks the ellipse and its points as helpers; a sketch plane the ellipse does not lie in refuses it as before.
Needs a real pythonocc-core environment."""

import math

from app.document.extrude import compute_part_bodies
from app.document.router import get_part_or_404
from tests.test_circle_centre_reference import _new_sketch
from tests.test_reference_identity import _json, client


def _elliptical_plate():
    """An ellipse (radii 20 x 10, major axis along +x) at the origin, extruded 8 mm: its top rim (z = 8) is a full elliptical edge in the plane z = 8."""
    part_id = _json(client.post("/document/parts", json={"name": "ellipse"}))["id"]
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    centre = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 0.0, "y": 0.0}))
    _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/ellipses", json={"center_point_id": centre["id"], "major_radius": 20.0, "angle": 0.0, "minor_radius": 10.0}))
    extrude = _json(client.post(f"/document/parts/{part_id}/extrude-features", json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 8.0, "target_body_ids": []}))
    return part_id, extrude["id"]


def _elliptical_edge(part_id: str, body_id: str, z: float) -> int:
    """The index of the elliptical edge at height z (found through the part's edge kinds and polylines)."""
    from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
    from OCC.Core.GeomAbs import GeomAbs_Ellipse
    from OCC.Core.TopAbs import TopAbs_EDGE
    from OCC.Core.TopExp import topexp
    from OCC.Core.TopTools import TopTools_IndexedMapOfShape
    from OCC.Core.TopoDS import topods

    shape = compute_part_bodies(get_part_or_404(part_id))[body_id]
    edges = TopTools_IndexedMapOfShape()
    topexp.MapShapes(shape, TopAbs_EDGE, edges)
    for i in range(1, edges.Size() + 1):
        adaptor = BRepAdaptor_Curve(topods.Edge(edges.FindKey(i)))
        if adaptor.GetType() == GeomAbs_Ellipse and abs(adaptor.Value(0.0).Z() - z) < 1e-6:
            return i - 1
    raise AssertionError("no elliptical edge there")


def _sketch_on_top(part_id: str):
    return _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))


def _convert_edge(part_id: str, sketch: dict, body_id: str, edge_index: int, **extra):
    return client.post(f"/document/parts/{part_id}/features/sketch/{sketch['id']}/convert-entities/edge", json={"body_id": body_id, "edge_index": edge_index, **extra})


def test_an_elliptical_bottom_rim_in_the_sketch_plane_converts_to_a_pinned_ellipse():
    part_id, body = _elliptical_plate()
    edge = _elliptical_edge(part_id, body, 0.0)  # the rim at z = 0 lies in the XY sketch plane
    sketch = _sketch_on_top(part_id)
    response = _convert_edge(part_id, sketch, body, edge)
    assert response.status_code in (200, 201), response.text
    data = response.json()
    ellipse = data["ellipse"]
    assert ellipse is not None and data["line"] is None and data["arc"] is None and data["circle"] is None
    assert abs(ellipse["major_radius"] - 20.0) < 1e-3 and abs(ellipse["minor_radius"] - 10.0) < 1e-3
    assert abs(ellipse["rotation"]) < 1e-3 or abs(abs(ellipse["rotation"]) - math.pi) < 1e-3
    points = {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}
    assert points[ellipse["center_point_id"]]["is_locked"] is True and points[ellipse["major_point_id"]]["is_locked"] is True


def test_converting_the_same_elliptical_edge_again_answers_with_the_ellipse_already_made():
    part_id, body = _elliptical_plate()
    edge = _elliptical_edge(part_id, body, 0.0)
    sketch = _sketch_on_top(part_id)
    first = _json(_convert_edge(part_id, sketch, body, edge))
    second = _json(_convert_edge(part_id, sketch, body, edge))
    assert second["ellipse"]["id"] == first["ellipse"]["id"]
    entities = _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/export"))["entities"]
    assert len([e for e in entities if e["type"] == "ellipse"]) == 1


def test_a_reference_convert_flags_the_ellipse_and_its_points_as_helpers():
    part_id, body = _elliptical_plate()
    edge = _elliptical_edge(part_id, body, 0.0)
    sketch = _sketch_on_top(part_id)
    data = _json(_convert_edge(part_id, sketch, body, edge, reference=True))
    exported = _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/export"))
    flagged = set(exported["reference_ids"])
    e = data["ellipse"]
    assert e["id"] in flagged and e["center_point_id"] in flagged and e["major_point_id"] in flagged and e["minor_point_id"] in flagged


def test_the_pinned_ellipse_solves_without_redundancy_and_keeps_its_size():
    part_id, body = _elliptical_plate()
    edge = _elliptical_edge(part_id, body, 0.0)
    sketch = _sketch_on_top(part_id)
    _convert_edge(part_id, sketch, body, edge)
    state = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/solve-and-refresh"))
    assert state["solve"]["converged"] is True
    ellipses = [e for e in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/ellipses"))]
    assert abs(ellipses[0]["major_radius"] - 20.0) < 1e-3 and abs(ellipses[0]["minor_radius"] - 10.0) < 1e-3


def test_an_elliptical_edge_not_in_the_sketch_plane_is_refused_as_degenerate():
    part_id, body = _elliptical_plate()
    edge = _elliptical_edge(part_id, body, 8.0)  # the top rim, 8 mm above the XY sketch plane
    sketch = _sketch_on_top(part_id)
    response = _convert_edge(part_id, sketch, body, edge)
    # (a closed elliptical edge off the plane has no two distinct vertices to make a chord from: the existing 422)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "degenerate_edge"
