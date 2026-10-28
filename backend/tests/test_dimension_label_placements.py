"""Dimension-label placements (docs/dimension-labels-scope.md, P2): where the user moved each dimension's label is saved with the sketch.

Stored beside the constraints (`Sketch.label_placements`), written to the native format only when there are some, returned as `label` on each
constraint response, set and cleared by `PUT` / `DELETE .../constraints/{id}/label`. The solver never sees it.
"""

import json

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.main import app
from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.sketch.models import Plane, Sketch
from app.sketch.schemas import LabelPlacementUpdate
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _sketch_with_distance() -> tuple[Sketch, str]:
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    constraint = sketch.add_distance_constraint(a.id, b.id, 10.0)
    return sketch, constraint.id


def _api_sketch_with_distance() -> tuple[str, str]:
    sketch_id = client.post("/sketch/sketches", json={"plane": "XY"}).json()["id"]
    a = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0, "y": 0}).json()["id"]
    b = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10, "y": 0}).json()["id"]
    constraint = client.post(
        f"/sketch/sketches/{sketch_id}/constraints", json={"type": "distance", "point_a_id": a, "point_b_id": b, "distance": 10}
    ).json()
    return sketch_id, constraint["id"]


def _label_of(sketch_id: str, constraint_id: str):
    constraints = client.get(f"/sketch/sketches/{sketch_id}/constraints").json()
    return next(c for c in constraints if c["id"] == constraint_id)["label"]


def test_native_round_trip_keeps_placements():
    sketch, cid = _sketch_with_distance()
    sketch.label_placements[cid] = {"offset": 4.5, "along": -1.25}

    data = json.loads(json.dumps(sketch_to_dict(sketch)))
    assert data["label_placements"] == {cid: {"offset": 4.5, "along": -1.25}}

    loaded = sketch_from_dict(data)
    assert loaded.label_placements == {cid: {"offset": 4.5, "along": -1.25}}


def test_no_placements_means_no_key_in_the_file():
    sketch, _ = _sketch_with_distance()
    assert "label_placements" not in sketch_to_dict(sketch)


def test_a_file_without_the_key_loads_with_no_placements():
    sketch, _ = _sketch_with_distance()
    data = sketch_to_dict(sketch)
    assert "label_placements" not in data
    assert sketch_from_dict(data).label_placements == {}


def test_a_placement_for_a_missing_constraint_is_neither_saved_nor_loaded():
    sketch, cid = _sketch_with_distance()
    sketch.label_placements["gone"] = {"offset": 1.0}
    sketch.label_placements[cid] = {"offset": 2.0}
    assert sketch_to_dict(sketch)["label_placements"] == {cid: {"offset": 2.0}}

    data = sketch_to_dict(sketch)
    data["label_placements"]["also-gone"] = {"offset": 3.0}
    assert sketch_from_dict(data).label_placements == {cid: {"offset": 2.0}}


def test_deleting_the_constraint_drops_its_placement():
    sketch_id, cid = _api_sketch_with_distance()
    assert client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 2.0}).status_code == 204

    assert client.delete(f"/sketch/sketches/{sketch_id}/constraints/{cid}").status_code == 204

    exported = client.get(f"/sketch/sketches/{sketch_id}/export").json()
    assert "label_placements" not in exported


def test_put_saves_and_list_returns_the_label():
    sketch_id, cid = _api_sketch_with_distance()
    assert _label_of(sketch_id, cid) is None

    response = client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 3.0, "along": 1.5})
    assert response.status_code == 204
    assert _label_of(sketch_id, cid) == {"offset": 3.0, "along": 1.5}

    # A second PUT replaces the whole placement.
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": -2.0})
    assert _label_of(sketch_id, cid) == {"offset": -2.0}


def test_delete_label_clears_it():
    sketch_id, cid = _api_sketch_with_distance()
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 3.0})

    assert client.delete(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label").status_code == 204
    assert _label_of(sketch_id, cid) is None


def test_put_rejects_unknown_keys_empty_bodies_and_non_finite_numbers():
    sketch_id, cid = _api_sketch_with_distance()
    url = f"/sketch/sketches/{sketch_id}/constraints/{cid}/label"

    assert client.put(url, json={"colour": 1.0}).status_code == 422
    assert client.put(url, json={}).status_code == 422
    assert client.put(url, json={"offset": "wide"}).status_code == 422
    assert _label_of(sketch_id, cid) is None


def test_the_placement_model_refuses_non_finite_numbers():
    # Checked on the model: over the wire FastAPI cannot even echo a NaN back in its 422 body (a framework limit shared by every float field here),
    # and the app's own clients cannot send one.
    for bad in (float("nan"), float("inf"), float("-inf")):
        with pytest.raises(ValidationError):
            LabelPlacementUpdate(offset=bad)


def test_put_and_delete_404_for_unknown_ids():
    sketch_id, cid = _api_sketch_with_distance()
    assert client.put(f"/sketch/sketches/{sketch_id}/constraints/nope/label", json={"offset": 1.0}).status_code == 404
    assert client.put(f"/sketch/nope/constraints/{cid}/label", json={"offset": 1.0}).status_code == 404
    assert client.delete(f"/sketch/sketches/{sketch_id}/constraints/nope/label").status_code == 404


def test_solve_and_refresh_carries_the_label():
    sketch_id, cid = _api_sketch_with_distance()
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 3.0})

    state = client.post(f"/sketch/sketches/{sketch_id}/solve-and-refresh").json()

    assert next(c for c in state["constraints"] if c["id"] == cid)["label"] == {"offset": 3.0}


def test_saving_does_not_change_the_solve():
    sketch_id, cid = _api_sketch_with_distance()
    before = client.post(f"/sketch/sketches/{sketch_id}/solve").json()
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 3.0})
    assert client.post(f"/sketch/sketches/{sketch_id}/solve").json() == before


def test_sketch_export_and_import_keep_placements():
    sketch_id, cid = _api_sketch_with_distance()
    client.put(f"/sketch/sketches/{sketch_id}/constraints/{cid}/label", json={"offset": 3.0, "along": 0.5})
    exported = client.get(f"/sketch/sketches/{sketch_id}/export").json()

    imported_id = client.post("/sketch/sketches/import", json=exported).json()["id"]

    assert imported_id != sketch_id
    assert _label_of(imported_id, cid) == {"offset": 3.0, "along": 0.5}
