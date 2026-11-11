"""Sketch alignment (docs/flutter-testing-feedback-2026-11-11-plan.md item 2): `SketchFeature.x_axis_ref`, a straight Body edge or a Sketch Line of an earlier Sketch
whose direction (projected into the anchor plane) becomes the Sketch's +X axis, BEFORE flip / rotation. A live reference with the lost-reference fallback. The response
carries the resolved frame. Needs a real pythonocc-core environment, like every other OCCT-touching test here."""

import math

import pytest

from app.document.create_plane import _resolve_planar_face
from app.document.extrude import compute_part_bodies, edge_endpoint_vertex_refs
from app.document.models import SketchOrEdgeRef, SubShapeRef, SubShapeType
from app.document.native_format import export_native, import_native
from app.document.router import get_part_or_404
from app.document.store import get_document
from tests.test_reference_identity import _feature, _json, _polygon_extrude, client
from tests.test_reference_follows_upstream_topology_change import _vertex_positions

C30, S30 = math.cos(math.radians(30)), math.sin(math.radians(30))


def _part() -> str:
    return _json(client.post("/document/parts", json={"name": "P"}))["id"]


def _sketch(part_id: str, plane: str = "XY", **extra) -> dict:
    return _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane, **extra}))


def _line(sketch: dict, a: tuple[float, float], b: tuple[float, float]) -> dict:
    pa = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": a[0], "y": a[1]}))
    pb = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": b[0], "y": b[1]}))
    line = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": pa["id"], "end_point_id": pb["id"]}))
    return {"line": line, "points": (pa, pb)}


def _line_ref(sketch: dict, line_id: str) -> dict:
    return {"sketch_id": sketch["sketch_id"], "entity_type": "line", "entity_id": line_id}  # SketchOrEdgeRefSchema is flat


def _align(part_id: str, feature_id: str, ref, expect: int = 200):
    response = client.patch(f"/document/parts/{part_id}/features/{feature_id}/sketch-alignment", json={"x_axis_ref": ref})
    assert response.status_code == expect, (response.status_code, response.text[:300])
    return response.json()


def _orient(sketch: dict, flip: bool, turns: int) -> None:
    _json(client.patch(f"/sketch/sketches/{sketch['sketch_id']}/orientation", json={"flip": flip, "rotation_quarter_turns": turns}))


def _close(a, b, tol=1e-6) -> bool:
    return a is not None and all(abs(x - y) <= tol for x, y in zip(a, b))


def _angled_line_sketches(angle_deg=30.0):
    """An XY Sketch with one line at `angle_deg` through the origin, then a second (later) XY Sketch. Returns (part id, line sketch, line id, later sketch)."""
    part_id = _part()
    first = _sketch(part_id)
    a = math.radians(angle_deg)
    made = _line(first, (0.0, 0.0), (10.0 * math.cos(a), 10.0 * math.sin(a)))
    later = _sketch(part_id)
    return part_id, first, made["line"]["id"], later


# --- the frame ---------------------------------------------------------------------------------------------------------------------


def test_every_sketch_reports_its_frame_and_a_new_one_is_unaligned():
    part_id = _part()
    sketch = _sketch(part_id)
    assert sketch["x_axis_ref"] is None
    assert _close(sketch["resolved_x_axis"], (1, 0, 0)) and _close(sketch["resolved_y_axis"], (0, 1, 0)) and _close(sketch["resolved_normal"], (0, 0, 1))
    assert _close(sketch["resolved_frame_origin"], (0, 0, 0)) and sketch["resolved_origin"] is None


def test_aligning_to_a_30_degree_sketch_line_puts_x_at_30_degrees_and_keeps_the_frame_right_handed():
    part_id, first, line_id, later = _angled_line_sketches()
    aligned = _align(part_id, later["id"], _line_ref(first, line_id))
    assert _close(aligned["resolved_x_axis"], (C30, S30, 0)) and _close(aligned["resolved_y_axis"], (-S30, C30, 0)) and _close(aligned["resolved_normal"], (0, 0, 1))
    assert aligned["x_axis_ref"]["entity_id"] == line_id
    assert _close(aligned["aligned_x_axis"], (C30, S30, 0)) and _close(aligned["aligned_y_axis"], (-S30, C30, 0))
    assert not aligned["has_lost_reference"] and aligned["lost_references"] == []
    # Going back to null is the plain frame again.
    plain = _align(part_id, later["id"], None)
    assert plain["x_axis_ref"] is None and _close(plain["resolved_x_axis"], (1, 0, 0))


@pytest.mark.parametrize("flip", [False, True])
@pytest.mark.parametrize("turns", [0, 1, 2, 3])
def test_flip_and_turns_act_relative_to_the_edge(flip: bool, turns: int):
    part_id, first, line_id, later = _angled_line_sketches()
    _align(part_id, later["id"], _line_ref(first, line_id))
    _orient(later, flip, turns)
    frame = _feature(part_id, later["id"])
    assert _close(frame["aligned_x_axis"], (C30, S30, 0)), "the aligned anchor axes do not include flip / turns"
    x, y = (C30, S30, 0.0), (-S30, C30, 0.0)  # independent restatement of apply_orientation on the aligned frame
    if flip:
        x = tuple(-c for c in x)
    for _ in range(turns):
        x, y = y, tuple(-c for c in x)
    assert _close(frame["resolved_x_axis"], x) and _close(frame["resolved_y_axis"], y)
    mirrored = flip
    cross = (x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0])
    assert (cross[2] < 0) == mirrored, "a flipped frame is left-handed (x cross y = -normal)"


def test_an_extrude_of_a_rectangle_at_the_local_origin_comes_out_rotated_30_degrees():
    part_id, first, line_id, later = _angled_line_sketches()
    _align(part_id, later["id"], _line_ref(first, line_id))
    sketch_id = later["sketch_id"]
    corners = [(0, 0), (10, 0), (10, 5), (0, 5)]
    ids = [_json(client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}))["id"] for x, y in corners]
    for a, b in zip(ids, ids[1:] + ids[:1]):
        _json(client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a, "end_point_id": b}))
    _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": later["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 4.0, "target_body_ids": []},
        )
    )
    (body_id,) = compute_part_bodies(get_part_or_404(part_id)).keys()
    positions = _vertex_positions(part_id, body_id)
    expected = {(round(10 * C30, 3), round(10 * S30, 3)), (round(10 * C30 - 5 * S30, 3), round(10 * S30 + 5 * C30, 3)), (round(-5 * S30, 3), round(5 * C30, 3)), (0.0, 0.0)}
    assert {(p[0], p[1]) for p in positions.values()} == expected


def test_the_line_is_live_moving_its_end_follows_it():
    part_id = _part()
    first = _sketch(part_id)
    made_line = _line(first, (0.0, 0.0), (10.0 * C30, 10.0 * S30))
    later = _sketch(part_id)
    made = _align(part_id, later["id"], _line_ref(first, made_line["line"]["id"]))
    assert _close(made["resolved_x_axis"], (C30, S30, 0))
    end_point = made_line["points"][1]
    _json(client.patch(f"/sketch/sketches/{first['sketch_id']}/points/{end_point['id']}", json={"x": 0.0, "y": 10.0}))
    assert _close(_feature(part_id, later["id"])["resolved_x_axis"], (0, 1, 0))


# --- refusals --------------------------------------------------------------------------------------------------------------------


def test_a_sketch_arc_or_circle_is_422_alignment_edge_not_straight():
    part_id = _part()
    first = _sketch(part_id)
    centre = _json(client.post(f"/sketch/sketches/{first['sketch_id']}/points", json={"x": 0.0, "y": 0.0}))
    circle = _json(client.post(f"/sketch/sketches/{first['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": 5.0}))
    later = _sketch(part_id)
    ref = {"sketch_id": first["sketch_id"], "entity_type": "circle", "entity_id": circle["id"]}
    assert _align(part_id, later["id"], ref, expect=422)["detail"]["type"] == "alignment_edge_not_straight"


def test_a_line_of_a_later_sketch_or_of_the_sketch_itself_is_422_not_upstream():
    part_id = _part()
    early = _sketch(part_id)
    late = _sketch(part_id)
    late_line = _line(late, (0, 0), (10, 3))["line"]["id"]
    assert _align(part_id, early["id"], _line_ref(late, late_line), expect=422)["detail"]["type"] == "alignment_reference_not_upstream"
    assert _align(part_id, late["id"], _line_ref(late, late_line), expect=422)["detail"]["type"] == "alignment_reference_not_upstream"


def test_a_line_along_the_plane_normal_is_422_parallel_to_the_normal():
    part_id = _part()
    xz = _sketch(part_id, "XZ")  # a Sketch on XZ: its local line (0,0)->(0,5) lies along world Z, which is IN that plane
    z_line = _line(xz, (0.0, 0.0), (0.0, 5.0))["line"]["id"]
    on_xy = _sketch(part_id, "XY")  # XY's normal is world Z, so that line is parallel to it
    assert _align(part_id, on_xy["id"], _line_ref(xz, z_line), expect=422)["detail"]["type"] == "alignment_edge_parallel_to_normal"


def test_a_malformed_reference_is_422():
    part_id, first, line_id, later = _angled_line_sketches()
    both = {**_line_ref(first, line_id), "edge_ref": {"body_id": "x", "shape_type": "edge", "index": 0}}
    assert client.patch(f"/document/parts/{part_id}/features/{later['id']}/sketch-alignment", json={"x_axis_ref": both}).status_code == 422
    assert client.patch(f"/document/parts/{part_id}/features/{later['id']}/sketch-alignment", json={"x_axis_ref": {}}).status_code == 422


# --- a Body edge -----------------------------------------------------------------------------------------------------------------


def _rotated_box():
    """A 10 x 10 *rotated* square extruded 10 (one of its sides runs along (10, 5)/|..|). Returns (part id, body id)."""
    part_id, _, extrude, _ = _polygon_extrude([(0, 0), (10, 5), (5, 15), (-5, 10)])
    return part_id, extrude["id"]


def _edge_directions(part_id: str, body_id: str) -> dict[int, tuple[tuple, tuple]]:
    bodies = compute_part_bodies(get_part_or_404(part_id))
    positions = _vertex_positions(part_id, body_id)
    out = {}
    for i in range(12):
        start, end = edge_endpoint_vertex_refs(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=i))
        out[i] = (positions[start.index], positions[end.index])
    return out


def _edge_ref(body_id: str, index: int) -> dict:
    return {"edge_ref": {"body_id": body_id, "shape_type": "edge", "index": index}}


def test_aligning_to_a_straight_body_edge_uses_its_start_to_end_direction():
    part_id, body_id = _rotated_box()
    edges = _edge_directions(part_id, body_id)
    index, (a, b) = next((i, e) for i, e in edges.items() if abs(e[0][2]) < 1e-6 and abs(e[1][2]) < 1e-6 and abs(e[1][0] - e[0][0]) > 1)  # a bottom side
    later = _sketch(part_id)
    aligned = _align(part_id, later["id"], _edge_ref(body_id, index))
    direction = (b[0] - a[0], b[1] - a[1], 0.0)
    length = math.hypot(direction[0], direction[1])
    assert _close(aligned["resolved_x_axis"], (direction[0] / length, direction[1] / length, 0.0), 1e-3)
    assert aligned["x_axis_ref"]["edge_ref"]["index"] == index
    # Rotate twice reverses X, as the plan says.
    _orient(later, False, 2)
    assert _close(_feature(part_id, later["id"])["resolved_x_axis"], (-direction[0] / length, -direction[1] / length, 0.0), 1e-3)


def test_a_body_edge_along_the_plane_normal_is_422():
    part_id, body_id = _rotated_box()
    edges = _edge_directions(part_id, body_id)
    vertical = next(i for i, (a, b) in edges.items() if abs(a[2] - b[2]) > 1)
    later = _sketch(part_id)
    assert _align(part_id, later["id"], _edge_ref(body_id, vertical), expect=422)["detail"]["type"] == "alignment_edge_parallel_to_normal"


def test_a_lost_body_edge_falls_back_to_the_unaligned_frame_and_is_reported():
    part_id, body_id = _rotated_box()
    later = _sketch(part_id)
    feature = get_part_or_404(part_id).get_feature(later["id"])
    feature.x_axis_ref = SketchOrEdgeRef(edge_ref=SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=999))
    shown = _feature(part_id, later["id"])
    assert _close(shown["resolved_x_axis"], (1, 0, 0)), "the unaligned frame"
    assert "x_axis_ref.edge_ref" in shown["lost_references"] and shown["has_lost_reference"]


def test_a_deleted_sketch_line_falls_back_and_is_reported():
    part_id, first, line_id, later = _angled_line_sketches()
    _align(part_id, later["id"], _line_ref(first, line_id))
    _json(client.delete(f"/sketch/sketches/{first['sketch_id']}/lines/{line_id}"))
    shown = _feature(part_id, later["id"])
    assert _close(shown["resolved_x_axis"], (1, 0, 0))
    assert "x_axis_ref.sketch_entity_ref" in shown["lost_references"]


def test_the_alignment_edge_is_still_followed_after_the_extrude_it_came_from_changes_depth():
    part_id, body_id = _rotated_box()
    edges = _edge_directions(part_id, body_id)
    index = next(i for i, e in edges.items() if abs(e[0][2]) < 1e-6 and abs(e[1][2]) < 1e-6 and abs(e[1][0] - e[0][0]) > 1)
    later = _sketch(part_id)
    before = _align(part_id, later["id"], _edge_ref(body_id, index))["resolved_x_axis"]
    extrude_id = body_id
    _json(client.patch(f"/document/parts/{part_id}/extrude-features/{extrude_id}", json={"end_distance": 25.0}))
    after = _feature(part_id, later["id"])
    assert _close(after["resolved_x_axis"], before, 1e-6) and not after["has_lost_reference"]


# --- native file, old files, the "auto" origin ---------------------------------------------------------------------------------------


def test_native_round_trip_keeps_the_alignment_and_an_old_file_loads_unaligned():
    part_id, first, line_id, later = _angled_line_sketches()
    _align(part_id, later["id"], _line_ref(first, line_id))
    exported = _json(client.get("/document/export/native", params={"part_id": part_id}))
    features = {f["id"]: f for f in exported["document"]["parts"][0]["features"]}
    assert features[later["id"]]["x_axis_ref"]["entity_id"] == line_id
    assert "x_axis_ref" not in features[first["id"]], "written only when set"
    assert client.post("/document/import/native", json=exported).status_code in (200, 201)
    assert _close(_feature(part_id, later["id"])["resolved_x_axis"], (C30, S30, 0))
    # An old file: no key at all.
    del features[later["id"]]["x_axis_ref"]
    assert client.post("/document/import/native", json=exported).status_code in (200, 201)
    shown = _feature(part_id, later["id"])
    assert shown["x_axis_ref"] is None and _close(shown["resolved_x_axis"], (1, 0, 0))


def test_with_an_auto_origin_the_corner_is_recomputed_in_the_aligned_frame():
    part_id, body_id = _rotated_box()
    # The top face: a plane on it, a Sketch with "auto" origin (the bottom-left corner in the oriented frame), then aligned to a different edge: asking "auto" again moves it.
    bodies = compute_part_bodies(get_part_or_404(part_id))
    face_index = None
    for i in range(20):
        try:
            plane = _resolve_planar_face(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=i))
        except Exception:
            continue
        if plane.normal[2] > 0.99 and abs(plane.origin[2] - 10.0) < 1e-6:
            face_index = i
            break
    assert face_index is not None
    plane_feature = _json(
        client.post(
            f"/document/parts/{part_id}/create-plane-features",
            json={"plane_type": "offset_face", "face_refs": [{"face_ref": {"body_id": body_id, "shape_type": "face", "index": face_index}}], "offset": 0.0},
        )
    )
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane_feature_id": plane_feature["id"], "origin": "auto"}))
    first_corner = sketch["resolved_origin"]
    edges = _edge_directions(part_id, body_id)
    top = [(i, e) for i, e in edges.items() if abs(e[0][2] - 10.0) < 1e-6 and abs(e[1][2] - 10.0) < 1e-6]
    index, (a, b) = max(top, key=lambda t: t[1][1][1] - t[1][0][1])  # the top edge climbing most in y: turns the frame a lot
    _align(part_id, sketch["id"], _edge_ref(body_id, index))
    again = _json(client.patch(f"/document/parts/{part_id}/features/{sketch['id']}/sketch-origin", json={"origin": "auto"}))
    frame = _feature(part_id, sketch["id"])
    # The stored origin is a corner of the face, and in the aligned frame it is that frame's bottom-left corner.
    corners = [(p[0], p[1]) for p in _vertex_positions(part_id, body_id).values() if abs(p[2] - 10.0) < 1e-6]
    x, y = frame["resolved_x_axis"], frame["resolved_y_axis"]
    best = min(corners, key=lambda p: (round(p[0] * y[0] + p[1] * y[1], 6), round(p[0] * x[0] + p[1] * x[1], 6)))
    assert _close(again["resolved_origin"][:2], best, 1e-3)
    assert first_corner is not None
