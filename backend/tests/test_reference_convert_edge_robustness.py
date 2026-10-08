"""Phase 1 of the DIDSA-VR implementation plan (R-A, R-E): a sketch that holds a converted hole rim still accepts `at_midpoint` on a pinned construction line
(`solve-and-refresh` converges, nothing is blamed), and converting the same circular edge twice gives back the same Circle / Arc. Needs a real pythonocc-core environment."""

import pytest

from app.document.extrude import compute_part_bodies
from app.document.reference_signature import BodyEdgeMeasurer
from app.document.router import get_part_or_404
from tests.test_circle_centre_reference import _convert_edge, _json, _new_sketch, client
from tests.test_reference_identity import _polygon_extrude


def _plate_with_hole():
    """A 20 x 20 x 10 plate (XY, z 0..10) with a radius-3 hole cut through it. Returns (part id, the plate's body id)."""
    part_id, sketch, extrude, _ = _polygon_extrude([(0, 0), (20, 0), (20, 20), (0, 20)])
    hole = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    centre = _json(client.post(f"/sketch/sketches/{hole['sketch_id']}/points", json={"x": 10.0, "y": 10.0}))
    _json(client.post(f"/sketch/sketches/{hole['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": 3.0, "angle": 0.0}))
    _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": hole["id"], "extrude_type": "cut", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": [extrude["id"]]},
        )
    )
    return part_id, extrude["id"]


def _edge_at_bottom(part_id: str, body_id: str, curve_kind: str, pick=lambda sig: True) -> int:
    """The index of an edge of `curve_kind` at the bottom (z = 0) that `pick` accepts. A line's `position` is its midpoint, a circle's `centre` its centre."""
    body = compute_part_bodies(get_part_or_404(part_id))[body_id]
    for i, sig in enumerate(BodyEdgeMeasurer(body).all()):
        at = sig.centre if curve_kind == "circle" else sig.position
        if sig.curve_kind == curve_kind and abs(at[2]) < 1e-6 and pick(sig):
            return i
    raise AssertionError("no such edge")


def _solve(sketch: dict) -> dict:
    return _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/solve-and-refresh"))["solve"]


def test_at_midpoint_on_a_pinned_edge_converges_next_to_a_converted_hole():
    part_id, body_id = _plate_with_hole()
    sketch = _new_sketch(part_id)
    _convert_edge(part_id, sketch, body_id, _edge_at_bottom(part_id, body_id, "circle"), construction=True)
    line = _convert_edge(part_id, sketch, body_id, _edge_at_bottom(part_id, body_id, "line", lambda s: abs(s.position[1]) < 1e-6 and abs(s.direction[0]) > 0.99), construction=True)["line"]
    before = _solve(sketch)
    assert before["converged"] is True, before
    point = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 9.0, "y": 1.0}))
    _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/constraints", json={"type": "at_midpoint", "point_id": point["id"], "line_id": line["id"]}))
    after = _solve(sketch)
    assert after["converged"] is True, after
    assert not after.get("blamed_constraint_ids")
    points = {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}
    start, end = points[line["start_point_id"]], points[line["end_point_id"]]
    midpoint = ((start["x"] + end["x"]) / 2, (start["y"] + end["y"]) / 2)
    assert (start["x"], start["y"], end["x"], end["y"]) == pytest.approx((0.0, 0.0, 20.0, 0.0)) or (start["x"], start["y"], end["x"], end["y"]) == pytest.approx((20.0, 0.0, 0.0, 0.0))
    assert (points[point["id"]]["x"], points[point["id"]]["y"]) == pytest.approx(midpoint)


def test_converting_the_same_circular_edge_twice_gives_one_circle():
    part_id, body_id = _plate_with_hole()
    sketch = _new_sketch(part_id)
    edge = _edge_at_bottom(part_id, body_id, "circle")
    first = _convert_edge(part_id, sketch, body_id, edge, construction=True)["circle"]
    second = _convert_edge(part_id, sketch, body_id, edge, construction=True)["circle"]
    assert first["id"] == second["id"]
    circles = _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/circles"))
    assert len(circles) == 1


def test_converting_the_same_straight_edge_twice_gives_one_line():
    part_id, body_id = _plate_with_hole()
    sketch = _new_sketch(part_id)
    edge = _edge_at_bottom(part_id, body_id, "line", lambda s: abs(s.position[1]) < 1e-6 and abs(s.direction[0]) > 0.99)
    first = _convert_edge(part_id, sketch, body_id, edge, construction=True)["line"]
    second = _convert_edge(part_id, sketch, body_id, edge, construction=True)["line"]
    assert first["id"] == second["id"]
    assert len(_json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/lines"))) == 1
