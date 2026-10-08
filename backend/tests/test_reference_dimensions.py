"""DIDSA-VR plan, phase 3 (R-B): persistent reference (driven) dimensions: a separate list on the Sketch (kind + the entities measured), the value computed on read,
CRUD routes, the value in the solve-and-refresh bundle, a native-file round trip (an older file loads), no effect on the solver, and the value following the part when
the part is edited upstream. Needs a real pythonocc-core environment for the part-following tests."""

import json
import math

import pytest

from app.document.native_format import export_native, import_native
from app.document.store import get_document
from app.sketch.store import all_sketches
from tests.test_circle_centre_reference import _new_sketch
from tests.test_reference_helpers import _convert, _plate, _plate_with_blind_hole, _face
from tests.test_reference_identity import _feature, _json, client


def _point(sketch_id: str, x: float, y: float) -> dict:
    return _json(client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}))


def _line(sketch_id: str, a: dict, b: dict) -> dict:
    return _json(client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}))


def _dim(sketch_id: str, kind: str, refs: list[tuple[str, str]], expect: int = 201):
    response = client.post(f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": kind, "refs": [{"type": t, "id": i} for t, i in refs]})
    assert response.status_code == expect, response.text
    return response.json()


@pytest.fixture
def bare():
    sketch = _json(client.post("/sketch/sketches", json={"plane": "XY"}))
    return sketch["id"]


def test_each_kind_measures_what_it_says(bare):
    a, b, c, d = _point(bare, 0, 0), _point(bare, 30, 40), _point(bare, 0, 10), _point(bare, 20, 10)
    base = _line(bare, a, d)  # (0,0)-(20,10)
    ab = _line(bare, a, b)  # (0,0)-(30,40)
    cd = _line(bare, c, d)  # (0,10)-(20,10): horizontal
    ac = _line(bare, a, c)  # (0,0)-(0,10): vertical
    circle = _json(client.post(f"/sketch/sketches/{bare}/circles", json={"center_point_id": c["id"], "radius": 7.0, "angle": 0.0}))
    assert _dim(bare, "distance", [("point", a["id"]), ("point", b["id"])])["value"] == pytest.approx(50.0)
    assert _dim(bare, "horizontal", [("point", a["id"]), ("point", b["id"])])["value"] == pytest.approx(30.0)
    assert _dim(bare, "vertical", [("point", a["id"]), ("point", b["id"])])["value"] == pytest.approx(40.0)
    assert _dim(bare, "distance", [("line", ab["id"])])["value"] == pytest.approx(50.0)
    assert _dim(bare, "distance", [("point", d["id"]), ("line", ab["id"])])["value"] == pytest.approx(abs(20 * 40 - 10 * 30) / 50.0)
    assert _dim(bare, "distance", [("line", ab["id"]), ("point", d["id"])])["value"] == pytest.approx(abs(20 * 40 - 10 * 30) / 50.0)
    assert _dim(bare, "radius", [("circle", circle["id"])])["value"] == pytest.approx(7.0)
    assert _dim(bare, "diameter", [("circle", circle["id"])])["value"] == pytest.approx(14.0)
    assert _dim(bare, "angle", [("line", cd["id"]), ("line", ac["id"])])["value"] == pytest.approx(90.0)
    assert _dim(bare, "angle", [("line", base["id"]), ("line", cd["id"])])["value"] == pytest.approx(math.degrees(math.atan2(10, 20)))
    assert _dim(bare, "distance", [("line", cd["id"]), ("line", ac["id"])], expect=400)["detail"].startswith("Those two lines are not parallel")


def test_nonsense_is_refused_with_a_reason(bare):
    a, b = _point(bare, 0, 0), _point(bare, 3, 4)
    assert "radius dimension measures" in _dim(bare, "radius", [("point", a["id"]), ("point", b["id"])], expect=400)["detail"]
    assert "not found" in _dim(bare, "distance", [("point", a["id"]), ("point", "nope")], expect=400)["detail"]
    assert client.post(f"/sketch/sketches/{bare}/reference-dimensions", json={"kind": "bogus", "refs": []}).status_code == 422
    assert _json(client.get(f"/sketch/sketches/{bare}/reference-dimensions")) == []


def test_the_same_dimension_twice_is_one(bare):
    a, b = _point(bare, 0, 0), _point(bare, 3, 4)
    first = _dim(bare, "distance", [("point", a["id"]), ("point", b["id"])])
    second = _dim(bare, "distance", [("point", a["id"]), ("point", b["id"])])
    assert first["id"] == second["id"]
    assert len(_json(client.get(f"/sketch/sketches/{bare}/reference-dimensions"))) == 1


def test_edit_and_delete(bare):
    a, b, c = _point(bare, 0, 0), _point(bare, 3, 4), _point(bare, 6, 8)
    made = _dim(bare, "distance", [("point", a["id"]), ("point", b["id"])])
    edited = _json(client.patch(f"/sketch/sketches/{bare}/reference-dimensions/{made['id']}", json={"refs": [{"type": "point", "id": a["id"]}, {"type": "point", "id": c["id"]}]}))
    assert edited["id"] == made["id"] and edited["value"] == pytest.approx(10.0)
    horizontal = _json(client.patch(f"/sketch/sketches/{bare}/reference-dimensions/{made['id']}", json={"kind": "horizontal"}))
    assert horizontal["kind"] == "horizontal" and horizontal["value"] == pytest.approx(6.0)
    assert client.patch(f"/sketch/sketches/{bare}/reference-dimensions/nope", json={"kind": "vertical"}).status_code == 404
    assert client.delete(f"/sketch/sketches/{bare}/reference-dimensions/{made['id']}").status_code == 204
    assert client.delete(f"/sketch/sketches/{bare}/reference-dimensions/{made['id']}").status_code == 404
    assert _json(client.get(f"/sketch/sketches/{bare}/reference-dimensions")) == []


def test_the_value_comes_with_solve_and_refresh_and_a_dimension_of_a_deleted_thing_is_dropped(bare):
    a, b = _point(bare, 0, 0), _point(bare, 3, 4)
    line = _line(bare, a, b)
    made = _dim(bare, "distance", [("line", line["id"])])
    state = _json(client.post(f"/sketch/sketches/{bare}/solve-and-refresh"))
    assert [(d["id"], d["value"]) for d in state["reference_dimensions"]] == [(made["id"], pytest.approx(5.0))]
    assert client.delete(f"/sketch/sketches/{bare}/lines/{line['id']}").status_code == 200
    assert _json(client.post(f"/sketch/sketches/{bare}/solve-and-refresh"))["reference_dimensions"] == []


def test_it_never_reaches_the_solver(bare):
    a, b = _point(bare, 0, 0), _point(bare, 3, 4)
    _line(bare, a, b)
    _dim(bare, "distance", [("point", a["id"]), ("point", b["id"])])
    solved = _json(client.post(f"/sketch/sketches/{bare}/solve-and-refresh"))
    assert solved["constraints"] == [] and solved["solve"]["dof"] == 4 + 0  # two free points: four degrees of freedom, as without the dimension
    points = {p["id"]: p for p in solved["points"]}
    assert (points[b["id"]]["x"], points[b["id"]]["y"]) == (3.0, 4.0)


def test_it_survives_a_save_and_open_of_the_sketch_and_an_older_file_loads(bare):
    a, b = _point(bare, 0, 0), _point(bare, 3, 4)
    made = _dim(bare, "distance", [("point", a["id"]), ("point", b["id"])])
    exported = json.loads(json.dumps(_json(client.get(f"/sketch/sketches/{bare}/export"))))
    assert exported["reference_dimensions"] == [{"id": made["id"], "kind": "distance", "refs": [{"type": "point", "id": a["id"]}, {"type": "point", "id": b["id"]}]}]
    opened = _json(client.post("/sketch/sketches/import", json=exported))
    again = _json(client.get(f"/sketch/sketches/{opened['id']}/reference-dimensions"))
    assert [(d["kind"], d["value"]) for d in again] == [("distance", pytest.approx(5.0))]
    del exported["reference_dimensions"]
    older = _json(client.post("/sketch/sketches/import", json=exported))
    assert _json(client.get(f"/sketch/sketches/{older['id']}/reference-dimensions")) == []


def test_a_part_sketchs_dimensions_survive_the_documents_native_save_and_open():
    part_id, base, extrude, ids = _plate()
    sketch = _new_sketch(part_id)
    a = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    b = next(
        c
        for c in (_json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=i, reference=True)) for i in range(1, 4))
        if (c["x"], c["y"]) != (a["x"], a["y"])
    )
    made = _dim(sketch["sketch_id"], "distance", [("point", a["id"]), ("point", b["id"])])
    data = json.loads(json.dumps(export_native(get_document(), all_sketches(), part_id)))
    entry = next(e for e in data["sketches"] if e["id"] == sketch["sketch_id"])
    assert entry["reference_dimensions"][0]["id"] == made["id"]
    _, sketches = import_native(data)
    assert sketches[sketch["sketch_id"]].reference_dimensions[made["id"]].kind == "distance"
    entry.pop("reference_dimensions")
    _, old = import_native(data)
    assert old[sketch["sketch_id"]].reference_dimensions == {}


# --- on a part: what the dimension measures follows the part ----------------------------------------------------------


def test_a_dimension_between_two_part_corners_follows_the_part_and_keeps_its_helpers_alive():
    part_id, base, extrude, ids = _plate()
    sketch = _new_sketch(part_id)
    a = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    corners = [_json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=i, reference=True)) for i in range(1, 4)]
    other = next(c for c in corners if (c["x"], c["y"]) != (a["x"], a["y"]) and abs(c["x"] - a["x"]) > 1)
    dimension = _dim(sketch["sketch_id"], "horizontal", [("point", a["id"]), ("point", other["id"])])
    assert dimension["value"] == pytest.approx(20.0)
    # the helpers are held by the dimension: a deletion elsewhere does not take them
    dummy = _point(sketch["sketch_id"], 1, 1)
    c2 = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/constraints", json={"type": "distance", "point_a_id": a["id"], "point_b_id": dummy["id"], "distance": 3.0}))
    client.delete(f"/sketch/sketches/{sketch['sketch_id']}/constraints/{c2['id']}")
    remaining = {p["id"] for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}
    assert a["id"] in remaining and other["id"] in remaining
    # the base polygon is made 10 wider: both far corners follow, the value follows
    for point in ids:
        p = next(q for q in _json(client.get(f"/sketch/sketches/{base['sketch_id']}/points")) if q["id"] == point)
        if p["x"] > 10:
            _json(client.patch(f"/sketch/sketches/{base['sketch_id']}/points/{point}", json={"x": p["x"] + 10.0, "y": p["y"]}))
    _feature(part_id, sketch["id"])  # reading the features refreshes the sketch's references against the edited part
    value = next(d for d in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/reference-dimensions")) if d["id"] == dimension["id"])["value"]
    assert value == pytest.approx(30.0)


def test_removing_the_dimension_removes_the_helper_it_alone_kept_alive():
    part_id, base, extrude, ids = _plate()
    sketch = _new_sketch(part_id)
    a = _json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=0, reference=True))
    b = next(
        c
        for c in (_json(_convert(part_id, sketch, "vertex", body_id=extrude["id"], vertex_index=i, reference=True)) for i in range(1, 4))
        if (c["x"], c["y"]) != (a["x"], a["y"])
    )
    made = _dim(sketch["sketch_id"], "distance", [("point", a["id"]), ("point", b["id"])])
    assert client.delete(f"/sketch/sketches/{sketch['sketch_id']}/reference-dimensions/{made['id']}").status_code == 204
    remaining = {p["id"] for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}
    assert a["id"] not in remaining and b["id"] not in remaining
    assert all_sketches()[sketch["sketch_id"]].external_references == {}


def test_a_blind_holes_axis_to_an_edge_is_a_reference_dimension_that_follows_the_hole():
    part_id, body_id, hole, _cut, centre_id, radius_id = _plate_with_blind_hole()
    sketch = _new_sketch(part_id)
    wall = _face(part_id, body_id, "cylinder")
    centre = _json(_convert(part_id, sketch, "face", body_id=body_id, face_index=wall, reference=True))["center_point"]
    side = _face(part_id, body_id, "plane", lambda s: abs(s.direction[0]) > 0.99 and s.position[0] < 1.0)  # the x = 0 side
    line = _json(_convert(part_id, sketch, "face", body_id=body_id, face_index=side, reference=True))["line"]
    dimension = _dim(sketch["sketch_id"], "distance", [("point", centre["id"]), ("line", line["id"])])
    assert dimension["value"] == pytest.approx(10.0)
    for p in _json(client.get(f"/sketch/sketches/{hole['sketch_id']}/points")):
        if abs(p["x"]) > 1e-9 or abs(p["y"]) > 1e-9:
            _json(client.patch(f"/sketch/sketches/{hole['sketch_id']}/points/{p['id']}", json={"x": p["x"] + 5.0, "y": p["y"]}))
    _feature(part_id, sketch["id"])
    value = next(d for d in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/reference-dimensions")) if d["id"] == dimension["id"])["value"]
    assert value == pytest.approx(15.0)
