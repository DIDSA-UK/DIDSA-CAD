"""Standalone "2D Drawing" tool save/open: `GET /sketch/sketches/{id}/export`
and `POST /sketch/sketches/import` - a bare Sketch's own full-state
save/open, independent of the Document/Part/Feature layer's native-file
format (which only ever serializes a Sketch that's referenced by a
SketchFeature inside a Part - see `app.document.native_format.export_native`).
Both endpoints just call `app.document.native_format.sketch_to_dict`/
`sketch_from_dict` directly - this module tests the router-level wiring
(fresh id on import, 422 on malformed input, content round-trips), not the
serialization itself (already covered by
`tests/test_stage_phase43_external_references.py`'s own round-trip tests).
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201
    return response.json()


def test_export_returns_the_sketchs_full_state_as_a_plain_dict():
    sketch = _create_sketch()
    a = _add_point(sketch["id"], 0.0, 0.0)
    b = _add_point(sketch["id"], 10.0, 0.0)
    line = _add_line(sketch["id"], a["id"], b["id"])

    response = client.get(f"/sketch/sketches/{sketch['id']}/export")
    assert response.status_code == 200
    data = response.json()
    assert data["id"] == sketch["id"]
    assert data["plane"] == "XY"
    point_ids = {p["id"] for p in data["points"]}
    assert a["id"] in point_ids and b["id"] in point_ids
    entity_ids = {e["id"] for e in data["entities"]}
    assert line["id"] in entity_ids


def test_export_of_an_unknown_sketch_id_is_a_404():
    response = client.get("/sketch/sketches/no-such-sketch/export")
    assert response.status_code == 404


def test_import_creates_a_new_sketch_with_a_fresh_id_and_the_same_content():
    sketch = _create_sketch()
    a = _add_point(sketch["id"], 1.0, 2.0)
    b = _add_point(sketch["id"], 3.0, 4.0)
    _add_line(sketch["id"], a["id"], b["id"])
    exported = client.get(f"/sketch/sketches/{sketch['id']}/export").json()

    response = client.post("/sketch/sketches/import", json=exported)
    assert response.status_code == 201
    imported = response.json()
    assert imported["id"] != sketch["id"], "a fresh id, not the exported file's own id"

    reimported_export = client.get(f"/sketch/sketches/{imported['id']}/export").json()
    assert reimported_export["id"] == imported["id"]
    # Every other field round-trips unchanged - same points/entities/
    # constraints content, just under the new top-level sketch id.
    assert {p["id"] for p in reimported_export["points"]} == {p["id"] for p in exported["points"]}
    assert {(p["x"], p["y"]) for p in reimported_export["points"]} == {
        (p["x"], p["y"]) for p in exported["points"]
    }
    assert {e["id"] for e in reimported_export["entities"]} == {e["id"] for e in exported["entities"]}


def test_import_does_not_disturb_the_sketch_it_was_exported_from():
    sketch = _create_sketch()
    a = _add_point(sketch["id"], 5.0, 6.0)
    b = _add_point(sketch["id"], 7.0, 8.0)
    _add_line(sketch["id"], a["id"], b["id"])
    exported = client.get(f"/sketch/sketches/{sketch['id']}/export").json()

    client.post("/sketch/sketches/import", json=exported)

    original_still_there = client.get(f"/sketch/sketches/{sketch['id']}").json()
    assert original_still_there["id"] == sketch["id"]
    original_points = client.get(f"/sketch/sketches/{sketch['id']}/points").json()
    assert {(p["x"], p["y"]) for p in original_points} >= {(5.0, 6.0), (7.0, 8.0)}


def test_importing_twice_produces_two_independent_sketches_not_a_collision():
    sketch = _create_sketch()
    _add_point(sketch["id"], 9.0, 9.0)
    exported = client.get(f"/sketch/sketches/{sketch['id']}/export").json()

    first = client.post("/sketch/sketches/import", json=exported).json()
    second = client.post("/sketch/sketches/import", json=exported).json()
    assert first["id"] != second["id"]
    # Both are independently fetchable and independently mutable.
    _add_point(first["id"], 1.0, 1.0)
    second_points = client.get(f"/sketch/sketches/{second['id']}/points").json()
    assert (1.0, 1.0) not in {(p["x"], p["y"]) for p in second_points}


def test_import_of_a_malformed_payload_is_a_422():
    response = client.post("/sketch/sketches/import", json={"not": "a real sketch export"})
    assert response.status_code == 422
    assert "Invalid sketch file" in response.json()["detail"]


def test_import_of_a_non_dict_payload_is_a_422():
    response = client.post("/sketch/sketches/import", json="just a string")
    assert response.status_code == 422
