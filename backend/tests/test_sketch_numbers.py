"""Parity follow-ups F4 / A1: the number every sketch point, entity, dimension and relation carries, and the names the error texts use.

The numbers live on the Sketch (`numbers`, `number_counters`), are given in stored order, never reused, come back on an undo's create, ride along in every
response and in the native export, and are back-filled on load for a sketch from before they existed. Also the `show` field of the label record (decision 10).
"""

import json

from fastapi.testclient import TestClient

from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.main import app
from app.sketch.models import Plane, Sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _new_sketch() -> str:
    return client.post("/sketch/sketches", json={"plane": "XY"}).json()["id"]


def _point(sketch_id: str, x: float, y: float, **extra) -> dict:
    return client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y, **extra}).json()


def _line(sketch_id: str, a: str, b: str, **extra) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a, "end_point_id": b, **extra})
    assert response.status_code == 201, response.text
    return response.json()


def _constraint(sketch_id: str, **body) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/constraints", json=body)
    assert response.status_code == 201, response.text
    return response.json()


def _three_lines(sketch_id: str):
    p = [_point(sketch_id, float(i * 10), 0.0) for i in range(4)]
    return p, [_line(sketch_id, p[i]["id"], p[i + 1]["id"]) for i in range(3)]


# --- Assignment and the model ------------------------------------------------


def test_each_kind_counts_from_one_in_creation_order():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    assert [x["number"] for x in p] == [1, 2, 3, 4]  # the origin is not a numbered point
    assert [x["number"] for x in lines] == [1, 2, 3]
    circle = client.post(f"/sketch/sketches/{sketch_id}/circles", json={"center_point_id": p[0]["id"], "radius": 3}).json()
    assert circle["number"] == 1


def test_the_origin_has_no_number_and_is_named_origin():
    sketch = Sketch(id="s", plane=Plane.XY)
    origin = sketch.origin_point()
    assert sketch.number_of(origin.id) is None
    assert sketch.name_of(origin.id) == "Origin"


def test_names_read_kind_and_number():
    sketch = Sketch(id="s", plane=Plane.XY)
    a, b = sketch.add_point(0.0, 0.0), sketch.add_point(5.0, 0.0)
    line = sketch.add_line(a.id, b.id)
    assert sketch.name_of(a.id) == "Point 1"
    assert sketch.name_of(line.id) == "Line 1"
    assert sketch.name_of("no-such-id") is None
    assert sketch.describe("no-such-id") == "that item"


def test_dimensions_share_one_counter_and_relations_count_per_type():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    d1 = _constraint(sketch_id, type="distance", point_a_id=p[0]["id"], point_b_id=p[1]["id"], distance=10)
    r1 = _constraint(sketch_id, type="horizontal", line_id=lines[0]["id"])
    angle = _constraint(sketch_id, type="angle", line1_id=lines[0]["id"], line2_id=lines[1]["id"], angle_degrees=90)
    r2 = _constraint(sketch_id, type="horizontal", line_id=lines[2]["id"])
    r3 = _constraint(sketch_id, type="coincident", point_a_id=p[1]["id"], point_b_id=p[2]["id"])
    assert (d1["number"], angle["number"]) == (1, 2)  # one `D` counter: D1, D2
    assert (r1["number"], r2["number"]) == (1, 2)  # Horizontal 1, Horizontal 2
    assert r3["number"] == 1  # Coincident 1

    sketch = _store(sketch_id)
    assert sketch.name_of(d1["id"]) == "D1"
    assert sketch.name_of(angle["id"]) == "D2"
    assert sketch.name_of(r2["id"]) == "Horizontal 2"
    assert sketch.name_of(r3["id"]) == "Coincident 1"


def test_a_reference_dimension_shares_the_dimension_counter():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    d1 = _constraint(sketch_id, type="distance", point_a_id=p[0]["id"], point_b_id=p[1]["id"], distance=10)
    reference = client.post(
        f"/sketch/sketches/{sketch_id}/reference-dimensions", json={"kind": "distance", "refs": [{"type": "point", "id": p[2]["id"]}, {"type": "point", "id": p[3]["id"]}]}
    ).json()
    assert d1["number"] == 1 and reference["number"] == 2
    assert _store(sketch_id).name_of(reference["id"]) == "(D2)"


def test_a_shape_tools_provisional_size_takes_no_dimension_number_until_confirmed():
    sketch_id = _new_sketch()
    centre = _point(sketch_id, 0, 0)
    circle = client.post(f"/sketch/sketches/{sketch_id}/circles", json={"center_point_id": centre["id"], "radius": 5}).json()
    sizing = circle["radius_constraint_id"]
    constraints = {c["id"]: c for c in client.get(f"/sketch/sketches/{sketch_id}/constraints").json()}
    assert constraints[sizing]["provisional"] is True and constraints[sizing]["number"] is None
    client.patch(f"/sketch/sketches/{sketch_id}/constraints/{sizing}", json={"value": 6})
    confirmed = {c["id"]: c for c in client.get(f"/sketch/sketches/{sketch_id}/constraints").json()}[sizing]
    assert confirmed["provisional"] is False and confirmed["number"] == 1


def _store(sketch_id: str) -> Sketch:
    from app.sketch.store import get_sketch_or_404

    return get_sketch_or_404(sketch_id)


# --- Keeping: a delete leaves the others alone, numbers are never reused ------


def test_a_delete_leaves_the_others_names_alone_and_the_number_is_not_reused():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    assert client.delete(f"/sketch/sketches/{sketch_id}/lines/{lines[1]['id']}").status_code == 200
    remaining = {x["id"]: x["number"] for x in client.get(f"/sketch/sketches/{sketch_id}/lines").json()}
    assert remaining == {lines[0]["id"]: 1, lines[2]["id"]: 3}  # Line 3 is still Line 3
    fresh = _line(sketch_id, p[1]["id"], p[3]["id"])
    assert fresh["number"] == 4  # Line 2 is not handed out again
    assert [x["number"] for x in client.get(f"/sketch/sketches/{sketch_id}/lines").json()] == [1, 3, 4]


def test_deleting_the_newest_does_not_hand_its_number_to_the_next_either():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    client.delete(f"/sketch/sketches/{sketch_id}/lines/{lines[2]['id']}")
    assert _line(sketch_id, p[0]["id"], p[2]["id"])["number"] == 4
    # The counter is updated when the numbers are next given: a GET in between must not change the answer.
    sketch_id_b = _new_sketch()
    p, lines = _three_lines(sketch_id_b)
    client.get(f"/sketch/sketches/{sketch_id_b}/lines")
    client.delete(f"/sketch/sketches/{sketch_id_b}/lines/{lines[2]['id']}")
    client.get(f"/sketch/sketches/{sketch_id_b}/lines")
    assert _line(sketch_id_b, p[0]["id"], p[2]["id"])["number"] == 4


def test_a_dimension_deleted_keeps_the_other_dimensions_names():
    sketch_id = _new_sketch()
    p, _ = _three_lines(sketch_id)
    ids = [_constraint(sketch_id, type="distance", point_a_id=p[i]["id"], point_b_id=p[i + 1]["id"], distance=10)["id"] for i in range(3)]
    client.delete(f"/sketch/sketches/{sketch_id}/constraints/{ids[0]}")
    numbers = {c["id"]: c["number"] for c in client.get(f"/sketch/sketches/{sketch_id}/constraints").json()}
    assert numbers == {ids[1]: 2, ids[2]: 3}


# --- Undo: the optional number on create -------------------------------------


def test_a_create_with_the_number_it_had_gets_that_name_back():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    client.delete(f"/sketch/sketches/{sketch_id}/lines/{lines[1]['id']}")  # Line 2 goes
    undone = _line(sketch_id, p[1]["id"], p[2]["id"], number=2)  # the undo re-creates it
    assert undone["number"] == 2
    # ... and the counter did not move on for it: the next new line is Line 4, not Line 5.
    assert _line(sketch_id, p[2]["id"], p[3]["id"])["number"] == 4


def test_the_restored_number_is_refused_when_another_line_has_it():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    again = _line(sketch_id, p[0]["id"], p[3]["id"], number=1)  # Line 1 is taken: it gets the next free one
    assert again["number"] == 4


def test_a_constraint_and_a_point_take_the_number_they_had_too():
    sketch_id = _new_sketch()
    p, _ = _three_lines(sketch_id)
    gone = _constraint(sketch_id, type="distance", point_a_id=p[0]["id"], point_b_id=p[1]["id"], distance=10)
    other = _constraint(sketch_id, type="distance", point_a_id=p[1]["id"], point_b_id=p[2]["id"], distance=10)
    client.delete(f"/sketch/sketches/{sketch_id}/constraints/{gone['id']}")
    back = _constraint(sketch_id, type="distance", point_a_id=p[0]["id"], point_b_id=p[1]["id"], distance=10, number=1)
    assert (back["number"], other["number"]) == (1, 2)
    assert _point(sketch_id, 50, 0, number=2)["number"] == 5  # taken (Point 2 exists): the next free number


def test_a_number_below_one_is_refused_by_the_schema():
    sketch_id = _new_sketch()
    assert client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0, "y": 0, "number": 0}).status_code == 422


# --- Reload: the export and the import keep names -----------------------------


def test_the_export_carries_the_numbers_and_a_reload_keeps_every_name():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    client.delete(f"/sketch/sketches/{sketch_id}/lines/{lines[1]['id']}")
    constraint = _constraint(sketch_id, type="horizontal", line_id=lines[0]["id"])
    exported = client.get(f"/sketch/sketches/{sketch_id}/export").json()
    assert exported["numbers"][lines[0]["id"]] == 1 and exported["numbers"][lines[2]["id"]] == 3
    assert lines[1]["id"] not in exported["numbers"]
    assert exported["number_counters"]["line"] == 3

    imported = client.post("/sketch/sketches/import", json=json.loads(json.dumps(exported))).json()
    again = {x["id"]: x["number"] for x in client.get(f"/sketch/sketches/{imported['id']}/lines").json()}
    assert again == {lines[0]["id"]: 1, lines[2]["id"]: 3}
    assert _line(imported["id"], p[1]["id"], p[3]["id"])["number"] == 4  # the counter came back too: Line 2 is still not reused
    assert {c["id"]: c["number"] for c in client.get(f"/sketch/sketches/{imported['id']}/constraints").json()}[constraint["id"]] == 1


def test_an_old_file_without_numbers_is_numbered_on_load_in_its_stored_order():
    sketch = Sketch(id="s", plane=Plane.XY)
    sketch.origin_point()
    pts = [sketch.add_point(float(i), 0.0) for i in range(3)]
    l1, l2 = sketch.add_line(pts[0].id, pts[1].id), sketch.add_line(pts[1].id, pts[2].id)
    data = json.loads(json.dumps(sketch_to_dict(sketch)))
    del data["numbers"], data["number_counters"]  # what a file from before numbers looks like
    loaded = sketch_from_dict(data)
    assert [loaded.number_of(p.id) for p in pts] == [1, 2, 3]
    assert (loaded.number_of(l1.id), loaded.number_of(l2.id)) == (1, 2)
    assert loaded.number_counters["line"] == 2


def test_numbers_of_ids_that_are_not_in_the_file_are_dropped_and_a_malformed_number_is_replaced():
    sketch = Sketch(id="s", plane=Plane.XY)
    sketch.origin_point()
    a = sketch.add_point(1.0, 1.0)
    data = json.loads(json.dumps(sketch_to_dict(sketch)))
    data["numbers"]["ghost"] = 7
    data["numbers"][a.id] = True  # a bool is not a number: the point is numbered afresh (the saved counter says 1 was given, so it is 2, never reused)
    loaded = sketch_from_dict(data)
    assert "ghost" not in loaded.numbers
    assert loaded.number_of(a.id) == 2


def test_a_state_restore_keeps_the_names():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    state = client.get(f"/sketch/sketches/{sketch_id}/export").json()
    client.delete(f"/sketch/sketches/{sketch_id}/lines/{lines[0]['id']}")
    assert client.put(f"/sketch/sketches/{sketch_id}/state", json=state).status_code == 200
    assert [x["number"] for x in client.get(f"/sketch/sketches/{sketch_id}/lines").json()] == [1, 2, 3]


# --- Error texts use names ----------------------------------------------------


def test_a_delete_refused_names_what_still_uses_the_point():
    sketch_id = _new_sketch()
    p, lines = _three_lines(sketch_id)
    sketch = _store(sketch_id)
    reason = sketch.point_in_use_reason(p[1]["id"], exclude_entity_id=None) if hasattr(sketch, "point_in_use_reason") else None
    if reason is None:  # the method has another name: go through the route
        response = client.delete(f"/sketch/sketches/{sketch_id}/points/{p[1]['id']}")
        assert response.status_code == 400
        reason = response.json()["detail"]
    assert "Line 1" in reason or "Line 2" in reason
    assert lines[0]["id"] not in reason and lines[1]["id"] not in reason


def test_a_trim_that_cannot_happen_names_the_line_not_its_id():
    sketch_id = _new_sketch()
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 10, 0)
    line = _line(sketch_id, a["id"], b["id"])
    response = client.post(f"/sketch/sketches/{sketch_id}/lines/{line['id']}/trim", json={"moved_point_id": a["id"], "target_entity_ids": []})
    text = json.dumps(response.json())
    assert line["id"] not in text and a["id"] not in text


def test_an_unknown_id_is_not_echoed_in_the_message():
    sketch_id = _new_sketch()
    a = _point(sketch_id, 0, 0)
    response = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a["id"], "end_point_id": "no-such-point-0123"})
    assert response.status_code == 404
    assert "no-such-point-0123" not in response.text


# --- The label record's `show` field (decision 10) ----------------------------


def _distance(sketch_id: str) -> str:
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 40, 0)
    return _constraint(sketch_id, type="distance", point_a_id=a["id"], point_b_id=b["id"], distance=40)["id"]


def _label(sketch_id: str, cid: str):
    return next(c for c in client.get(f"/sketch/sketches/{sketch_id}/constraints").json() if c["id"] == cid)["label"]


def test_show_is_saved_with_the_label_and_read_back():
    sketch_id = _new_sketch()
    cid = _distance(sketch_id)
    assert _label(sketch_id, cid) is None
    assert client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 2.0, "show": "diameter"}).status_code == 204
    assert _label(sketch_id, cid) == {"offset": 2.0, "show": "diameter"}


def test_show_alone_is_a_valid_record_and_leaves_the_placement_alone():
    sketch_id = _new_sketch()
    cid = _distance(sketch_id)
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 2.0, "along": 1.0})
    assert client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"show": "full"}).status_code == 204
    assert _label(sketch_id, cid) == {"offset": 2.0, "along": 1.0, "show": "full"}


def test_moving_a_label_without_a_show_keeps_the_choice_so_an_older_client_cannot_wipe_it():
    sketch_id = _new_sketch()
    cid = _distance(sketch_id)
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"show": "semi"})
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 3.0})
    assert _label(sketch_id, cid) == {"offset": 3.0, "show": "semi"}


def test_putting_the_label_back_in_its_default_place_keeps_how_it_is_read():
    sketch_id = _new_sketch()
    cid = _distance(sketch_id)
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 3.0, "show": "diameter"})
    assert client.delete(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label").status_code == 204
    assert _label(sketch_id, cid) == {"show": "diameter"}


def test_an_unknown_show_value_and_an_empty_record_are_refused():
    sketch_id = _new_sketch()
    cid = _distance(sketch_id)
    assert client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"show": "huge"}).status_code == 422
    assert client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={}).status_code == 422


def test_the_show_choice_survives_an_export_and_import_and_goes_with_its_constraint():
    sketch_id = _new_sketch()
    cid = _distance(sketch_id)
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"show": "diameter"})
    exported = client.get(f"/sketch/sketches/{sketch_id}/export").json()
    assert exported["label_shows"] == {cid: "diameter"}
    imported = client.post("/sketch/sketches/import", json=json.loads(json.dumps(exported))).json()
    assert _label(imported["id"], cid) == {"show": "diameter"}
    client.delete(f"/sketch/sketches/{sketch_id}/constraints/{cid}")
    assert "label_shows" not in client.get(f"/sketch/sketches/{sketch_id}/export").json()


# --- Every constraint type is classified --------------------------------------


def test_every_constraint_type_is_either_a_dimension_or_a_named_relation():
    """A new constraint class must be put in one list or the other in `app.sketch.numbering`, or it would be called by a made-up name."""
    import app.sketch.models  # noqa: F401  (loads every constraint class)
    from app.sketch import numbering
    from app.sketch.constraints import Constraint

    def leaves(cls):
        for sub in cls.__subclasses__():
            yield sub
            yield from leaves(sub)

    types = set()
    for cls in leaves(Constraint):
        try:
            types.add(cls.type.fget(object.__new__(cls)))
        except Exception:  # an abstract helper, not a real constraint
            continue
    assert len(types) >= 20
    unclassified = {t for t in types if t not in numbering.DIMENSION_CONSTRAINT_TYPES and t not in numbering._RELATION_LABELS}
    assert unclassified == set(), unclassified
