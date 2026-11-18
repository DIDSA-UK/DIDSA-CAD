"""Bug report 2026-11-18 plan part C1: Convert Entities projects a Body edge that is not in the sketch plane square onto it (`convert-entities/edge`), where
it used to draw the chord. An arc seen at an angle becomes an elliptical arc between the edge's two live vertex references; a whole circle seen at an angle
an ellipse; one seen edge-on a line; a straight edge along the normal one Point. The copy keeps following the edge when the part is rebuilt, and after a
save and reopen. Needs a real pythonocc-core environment."""

import math

import pytest

from app.document.extrude import compute_part_bodies
from app.document.reference_signature import BodyEdgeMeasurer
from app.document.router import get_part_or_404
from app.sketch.store import all_sketches
from tests.test_reference_identity import _feature, _json, client

COS30 = math.cos(math.radians(30.0))


def _part():
    return _json(client.post("/document/parts", json={"name": "P"}))["id"]


def _half_disc(part_id: str, radius: float = 5.0, depth: float = 10.0):
    """A half disc on XY (an arc from (r, 0) round through (0, r) to (-r, 0), closed by the diameter) extruded `depth`. Returns (base sketch, extrude,
    {centre, start, end} point ids)."""
    base = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    sid = base["sketch_id"]
    centre = _json(client.post(f"/sketch/sketches/{sid}/points", json={"x": 0.0, "y": 0.0}))
    start = _json(client.post(f"/sketch/sketches/{sid}/points", json={"x": radius, "y": 0.0}))
    arc = _json(client.post(f"/sketch/sketches/{sid}/arcs", json={"center_point_id": centre["id"], "start_point_id": start["id"], "end_angle": math.pi}))
    _json(client.post(f"/sketch/sketches/{sid}/lines", json={"start_point_id": arc["end_point_id"], "end_point_id": start["id"]}))
    extrude = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": base["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": depth, "target_body_ids": []},
        )
    )
    return base, extrude, {"centre": centre["id"], "start": start["id"], "end": arc["end_point_id"]}


def _cylinder(part_id: str, radius: float = 5.0, depth: float = 10.0):
    base = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    centre = _json(client.post(f"/sketch/sketches/{base['sketch_id']}/points", json={"x": 0.0, "y": 0.0}))
    _json(client.post(f"/sketch/sketches/{base['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}))
    return _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": base["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": depth, "target_body_ids": []},
        )
    )


def _tilted_sketch(part_id: str):
    """A Sketch on a plane through the x axis tilted 30 degrees from XY (normal (0, -sin 30, cos 30)), made from three Sketch Points."""
    xy = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    yz = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "YZ"}))
    a = _json(client.post(f"/sketch/sketches/{xy['sketch_id']}/points", json={"x": 0.0, "y": 0.0}))
    b = _json(client.post(f"/sketch/sketches/{xy['sketch_id']}/points", json={"x": 10.0, "y": 0.0}))
    c = _json(client.post(f"/sketch/sketches/{yz['sketch_id']}/points", json={"x": 10 * COS30, "y": 5.0}))

    def ref(s, p):
        return {"sketch_point_ref": {"sketch_id": s["sketch_id"], "entity_type": "point", "entity_id": p["id"]}}

    plane = _json(client.post(f"/document/parts/{part_id}/create-plane-features", json={"plane_type": "three_points", "point_refs": [ref(xy, a), ref(xy, b), ref(yz, c)]}))
    assert plane["normal"] == pytest.approx([0.0, -0.5, COS30])
    return _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane_feature_id": plane["id"]}))


def _edge(part_id: str, body_id: str, pick) -> int:
    body = compute_part_bodies(get_part_or_404(part_id))[body_id]
    for i, sig in enumerate(BodyEdgeMeasurer(body).all()):
        if pick(sig):
            return i
    raise AssertionError("no such edge")


def _bottom_arc(sig) -> bool:
    return sig.curve_kind == "circle" and abs(sig.centre[2]) < 1e-6


def _convert(part_id: str, sketch: dict, body_id: str, edge_index: int, **extra):
    return client.post(f"/document/parts/{part_id}/features/sketch/{sketch['id']}/convert-entities/edge", json={"body_id": body_id, "edge_index": edge_index, **extra})


def _ellipse_arcs(sketch: dict) -> dict:
    return {e["id"]: e for e in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/ellipse-arcs"))}


def _points(sketch: dict) -> dict:
    return {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}


# --- an edge at an angle ----------------------------------------------------------------------------------------------------


def test_an_arc_edge_seen_at_an_angle_converts_to_an_elliptical_arc_not_a_chord():
    part_id = _part()
    _, extrude, _ = _half_disc(part_id)
    sketch = _tilted_sketch(part_id)
    response = _convert(part_id, sketch, extrude["id"], _edge(part_id, extrude["id"], _bottom_arc))
    assert response.status_code == 201, response.text
    data = response.json()
    # Before part C1 this was the chord: a `line` between the two ends. Now it is the arc as seen square to the tilted plane.
    assert data["line"] is None and data["arc"] is None
    arc = data["ellipse_arc"]
    assert arc["major_radius"] == pytest.approx(5.0) and arc["minor_radius"] == pytest.approx(5.0 * COS30)
    sketch_model = all_sketches()[sketch["sketch_id"]]
    # Its ends are the edge's live vertex references; the rest of it is pinned and follows the edge through an ExternalCurveReference.
    assert {data["start_point"]["id"], data["end_point"]["id"]} == {arc["start_point_id"], arc["end_point_id"]}
    assert arc["start_point_id"] in sketch_model.external_references and arc["end_point_id"] in sketch_model.external_references
    curve = sketch_model.external_curves[arc["id"]]
    assert curve.source == "body_edge" and curve.made_kind == "ellipse_arc" and curve.body_id == extrude["id"] and curve.signature is not None
    points = _points(sketch)
    assert all(points[arc[k]]["is_locked"] for k in ("center_point_id", "major_point_id", "minor_point_id", "start_point_id", "end_point_id"))
    # The ends are on the projected ellipse: (+-5, 0) in the tilted sketch's coordinates (the x axis is shared).
    ends = sorted((points[arc[k]]["x"], points[arc[k]]["y"]) for k in ("start_point_id", "end_point_id"))
    assert ends == [pytest.approx((-5.0, 0.0)), pytest.approx((5.0, 0.0))]
    state = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/solve-and-refresh"))
    assert state["solve"]["converged"] is True, state["solve"]
    assert not _feature(part_id, sketch["id"])["has_lost_reference"]


def test_converting_the_same_angled_edge_again_answers_with_the_copy_already_made():
    part_id = _part()
    _, extrude, _ = _half_disc(part_id)
    sketch = _tilted_sketch(part_id)
    edge = _edge(part_id, extrude["id"], _bottom_arc)
    first = _json(_convert(part_id, sketch, extrude["id"], edge))
    again = _json(_convert(part_id, sketch, extrude["id"], edge))
    assert first["ellipse_arc"]["id"] == again["ellipse_arc"]["id"]
    assert len(_ellipse_arcs(sketch)) == 1


def test_a_reference_convert_flags_the_elliptical_arc_and_its_points():
    part_id = _part()
    _, extrude, _ = _half_disc(part_id)
    sketch = _tilted_sketch(part_id)
    data = _json(_convert(part_id, sketch, extrude["id"], _edge(part_id, extrude["id"], _bottom_arc), reference=True, construction=True))
    arc = data["ellipse_arc"]
    assert arc["is_reference"] is True and data["start_point"]["is_reference"] is True
    flagged = all_sketches()[sketch["sketch_id"]].reference_ids
    assert {arc["id"], arc["center_point_id"], arc["major_point_id"], arc["minor_point_id"]} <= flagged


def test_a_whole_circle_seen_at_an_angle_converts_to_a_pinned_ellipse():
    # A closed edge off the plane used to be refused as `degenerate_edge`.
    part_id = _part()
    extrude = _cylinder(part_id, radius=4.0)
    sketch = _tilted_sketch(part_id)
    data = _json(_convert(part_id, sketch, extrude["id"], _edge(part_id, extrude["id"], lambda s: s.curve_kind == "circle" and abs(s.centre[2] - 10.0) < 1e-6)))
    ellipse = data["ellipse"]
    assert ellipse["major_radius"] == pytest.approx(4.0) and ellipse["minor_radius"] == pytest.approx(4.0 * COS30)
    assert all_sketches()[sketch["sketch_id"]].external_curves[ellipse["id"]].made_kind == "ellipse"


def test_a_circle_seen_edge_on_converts_to_a_line_and_a_vertical_edge_to_a_point():
    part_id = _part()
    _, extrude, _ = _half_disc(part_id, radius=5.0, depth=10.0)
    side = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XZ"}))
    line = _json(_convert(part_id, side, extrude["id"], _edge(part_id, extrude["id"], _bottom_arc)))["line"]
    points = _points(side)
    xs = sorted(points[line[k]]["x"] for k in ("start_point_id", "end_point_id"))
    assert xs == pytest.approx([-5.0, 5.0]) and all(abs(points[line[k]]["y"]) < 1e-9 for k in ("start_point_id", "end_point_id"))

    top = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    vertical = _edge(part_id, extrude["id"], lambda s: s.curve_kind == "line" and abs(abs(s.direction[2]) - 1.0) < 1e-9)
    data = _json(_convert(part_id, top, extrude["id"], vertical))
    assert data["point"] is not None and data["line"] is None
    assert data["start_point"]["id"] == data["end_point"]["id"] == data["point"]["id"]
    assert data["point"]["id"] in all_sketches()[top["sketch_id"]].external_references


def test_an_edge_on_the_sketch_plane_still_takes_the_exact_in_plane_paths():
    # The existing in-plane paths stay: an arc lying in XY is still a real Arc with a live centre, a straight edge a Line.
    part_id = _part()
    _, extrude, _ = _half_disc(part_id)
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    data = _json(_convert(part_id, sketch, extrude["id"], _edge(part_id, extrude["id"], _bottom_arc)))
    assert data["arc"] is not None and data["ellipse_arc"] is None
    assert all_sketches()[sketch["sketch_id"]].external_references[data["arc"]["center_point_id"]].kind == "circle_centre"
    assert not all_sketches()[sketch["sketch_id"]].external_curves


# --- following the edge -----------------------------------------------------------------------------------------------------


def _resize_half_disc(base: dict, ids: dict, radius: float):
    sid = base["sketch_id"]
    _json(client.patch(f"/sketch/sketches/{sid}/points/{ids['start']}", json={"x": radius, "y": 0.0}))
    _json(client.patch(f"/sketch/sketches/{sid}/points/{ids['end']}", json={"x": -radius, "y": 0.0}))


def test_the_elliptical_arc_follows_the_edge_when_the_part_is_rebuilt():
    part_id = _part()
    base, extrude, ids = _half_disc(part_id)
    sketch = _tilted_sketch(part_id)
    arc = _json(_convert(part_id, sketch, extrude["id"], _edge(part_id, extrude["id"], _bottom_arc)))["ellipse_arc"]
    _resize_half_disc(base, ids, 7.0)

    feature = _feature(part_id, sketch["id"])
    assert not feature["has_lost_reference"], feature
    again = _ellipse_arcs(sketch)[arc["id"]]
    assert again["major_radius"] == pytest.approx(7.0) and again["minor_radius"] == pytest.approx(7.0 * COS30)
    points = _points(sketch)
    ends = sorted((points[arc[k]]["x"], points[arc[k]]["y"]) for k in ("start_point_id", "end_point_id"))
    assert ends == [pytest.approx((-7.0, 0.0)), pytest.approx((7.0, 0.0))]
    state = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/solve-and-refresh"))
    assert state["solve"]["converged"] is True
    assert _ellipse_arcs(sketch)[arc["id"]]["major_radius"] == pytest.approx(7.0)


def test_an_edge_that_is_no_longer_there_reports_the_copy_lost():
    part_id = _part()
    base, extrude, _ = _half_disc(part_id)
    sketch = _tilted_sketch(part_id)
    arc = _json(_convert(part_id, sketch, extrude["id"], _edge(part_id, extrude["id"], _bottom_arc)))["ellipse_arc"]
    sketch_model = all_sketches()[sketch["sketch_id"]]
    # Point the reference at an edge index no Body has: the copy cannot be found again, so it is reported, never silently rebound.
    import dataclasses

    sketch_model.external_curves[arc["id"]] = dataclasses.replace(sketch_model.external_curves[arc["id"]], body_id="no-such-body")
    feature = _feature(part_id, sketch["id"])
    assert feature["has_lost_reference"] is True
    assert arc["center_point_id"] in feature["lost_reference_point_ids"]
    assert feature["reference_reasons"][arc["center_point_id"]] == "body_missing"


# --- save and reopen --------------------------------------------------------------------------------------------------------


def test_the_projected_copy_survives_a_save_and_reopen_and_still_follows():
    from app.document.store import get_document, replace_document
    from app.sketch.store import replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part_id = _part()
        base, extrude, ids = _half_disc(part_id)
        sketch = _tilted_sketch(part_id)
        arc = _json(_convert(part_id, sketch, extrude["id"], _edge(part_id, extrude["id"], _bottom_arc)))["ellipse_arc"]
        original = all_sketches()[sketch["sketch_id"]].external_curves[arc["id"]]
        exported = client.get("/document/export/native").json()
        stored = next(s for s in exported["sketches"] if s["id"] == sketch["sketch_id"])
        assert [c["made_id"] for c in stored["external_curves"]] == [arc["id"]]
        assert client.post("/document/import/native", json=exported).status_code == 200

        loaded = all_sketches()[sketch["sketch_id"]].external_curves[arc["id"]]
        assert loaded == original and loaded.signature == original.signature and loaded.lineage == original.lineage
        _resize_half_disc(base, ids, 6.0)
        assert not _feature(part_id, sketch["id"])["has_lost_reference"]
        assert _ellipse_arcs(sketch)[arc["id"]]["minor_radius"] == pytest.approx(6.0 * COS30)
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_a_sketch_without_projected_copies_is_saved_exactly_as_before():
    from app.document.native_format import sketch_to_dict

    part_id = _part()
    _, extrude, _ = _half_disc(part_id)
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    _convert(part_id, sketch, extrude["id"], _edge(part_id, extrude["id"], _bottom_arc))
    assert "external_curves" not in sketch_to_dict(all_sketches()[sketch["sketch_id"]])
