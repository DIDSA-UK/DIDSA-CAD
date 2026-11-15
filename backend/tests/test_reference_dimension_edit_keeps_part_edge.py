"""Editing a dimension between a circle centre and a referenced (pinned) edge of the part moves the circle, never the part's edge, whichever way round the two points were picked."""
import pytest
from tests.test_reference_identity import _json, _polygon_extrude, client
from tests.test_circle_centre_reference import _new_sketch


def _pts(sk):
    return {p["id"]: (round(p["x"], 4), round(p["y"], 4)) for p in _json(client.post(f"/sketch/sketches/{sk['sketch_id']}/solve-and-refresh"))["points"]}


def _setup():
    part_id, _s, ext, _ = _polygon_extrude([(0, 0), (40, 0), (40, 20), (0, 20)])
    sk = _new_sketch(part_id)
    c = _json(client.post(f"/sketch/sketches/{sk['sketch_id']}/points", json={"x": 12.0, "y": 9.0}))
    _json(client.post(f"/sketch/sketches/{sk['sketch_id']}/circles", json={"center_point_id": c["id"], "radius": 3.0, "angle": 0.0}))
    # find the y=0 edge
    for i in range(12):
        r = client.post(f"/document/parts/{part_id}/features/sketch/{sk['id']}/convert-entities/edge", json={"body_id": ext["id"], "edge_index": i, "construction": True, "reference": True})
        if r.status_code != 201:
            continue
        j = r.json()
        if j.get("line") and abs(j["start_point"]["y"]) < 1e-6 and abs(j["end_point"]["y"]) < 1e-6 and abs(j["start_point"]["x"] - j["end_point"]["x"]) > 1:
            return sk, c["id"], j
    raise AssertionError("no y=0 edge")


@pytest.mark.parametrize("kind", ["point_line", "linear_ab", "linear_ba", "vertical_ab", "vertical_ba", "horizontal_ab", "horizontal_ba"])
def test_edit(kind):
    sk, centre, edge = _setup()
    a, b = edge["start_point"]["id"], edge["end_point"]["id"]
    line = edge["line"]["id"]
    if kind == "point_line":
        body = {"type": "point_line_distance", "point_id": centre, "line_id": line, "distance": 9.0}
    else:
        orient, order = kind.split("_")
        pa, pb = (a, centre) if order == "ab" else (centre, a)
        before0 = _pts(sk)
        import math
        d = abs(before0[a][1] - before0[centre][1]) if orient == "vertical" else abs(before0[a][0] - before0[centre][0]) if orient == "horizontal" else math.dist(before0[a], before0[centre])
        body = {"type": "distance", "point_a_id": pa, "point_b_id": pb, "distance": d, "orientation": orient}
    con = _json(client.post(f"/sketch/sketches/{sk['sketch_id']}/constraints", json=body))
    before = _pts(sk)
    r = client.patch(f"/sketch/sketches/{sk['sketch_id']}/constraints/{con['id']}", json={"value": 20.0})
    after = _pts(sk)
    assert r.status_code == 200 and r.json()["converged"] is True
    assert after[a] == before[a] and after[b] == before[b], f"{kind}: edge moved"
    assert after[centre] != before[centre], f"{kind}: centre did not move"


def test_a_pinned_point_cannot_be_moved_by_patch_or_drag():
    sk, centre, edge = _setup()
    a = edge["start_point"]["id"]
    assert client.patch(f"/sketch/sketches/{sk['sketch_id']}/points/{a}", json={"x": 3.0, "y": 3.0}).status_code == 400
    assert client.post(f"/sketch/sketches/{sk['sketch_id']}/solve", json={"point_updates": [{"id": a, "x": 3.0, "y": 3.0}]}).status_code == 400
    assert _pts(sk)[a] == (0.0, 0.0)
