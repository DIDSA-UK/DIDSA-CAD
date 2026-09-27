"""`POST /document/parts/{root_part_id}/add-component` - the backend port of
the Flutter client's own `add_component.dart::mergeComponentIntoDocument`,
built for the VR client (`DIDSA-UK/DIDSA-VR`), which has no Dart runtime to
call that function itself and otherwise has no way to add a second
Occurrence to its live session's assembly short of a full-replace
`/import/native` (see `app.document.add_component`'s own module docstring).
Mirrors `test_assembly_mesh_glb.py`'s own box-part fixture convention.

Needs a real pythonocc-core environment, same caveat as every other
extrude-backed fixture in this test suite."""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> None:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201


def _make_box_part(name: str, *, size: float = 10.0) -> dict:
    part = _create_part(name)
    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]
    corners = [_add_point(sketch_id, x, y) for x, y in [(0, 0), (size, 0), (size, size), (0, size)]]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])
    extrude_response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": sketch_response.json()["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 10.0,
            "target_body_ids": [],
        },
    )
    assert extrude_response.status_code == 201
    return part


def _export_part(part_id: str) -> dict:
    response = client.get("/document/export/native", params={"part_id": part_id})
    assert response.status_code == 200
    return response.json()


def test_add_component_places_first_occurrence_fixed():
    root = _make_box_part("Mount")
    bolt = _make_box_part("Bolt", size=2.0)
    bolt_payload = _export_part(bolt["id"])

    response = client.post(f"/document/parts/{root['id']}/add-component", json={"component": bolt_payload})
    assert response.status_code == 200
    body = response.json()
    assert body["occurrence_id"]
    assert set(body["part_ids"]) >= {root["id"], bolt["id"]}

    occurrences = client.get(f"/document/parts/{root['id']}/occurrences")
    assert occurrences.status_code == 200
    [occurrence] = occurrences.json()
    assert occurrence["id"] == body["occurrence_id"]
    assert occurrence["resolved_part_id"] == bolt["id"]
    assert occurrence["fixed"] is True  # first Occurrence is grounded by convention


def test_add_component_second_occurrence_is_not_fixed():
    root = _make_box_part("Mount 2")
    bolt = _make_box_part("Bolt 2", size=2.0)
    bolt_payload = _export_part(bolt["id"])

    client.post(f"/document/parts/{root['id']}/add-component", json={"component": bolt_payload})
    second = client.post(f"/document/parts/{root['id']}/add-component", json={"component": bolt_payload})
    assert second.status_code == 200

    occurrences = client.get(f"/document/parts/{root['id']}/occurrences").json()
    assert len(occurrences) == 2
    assert [o["fixed"] for o in occurrences] == [True, False]
    # Dedup, same as `mergeComponentIntoDocument`: two Occurrences of one
    # underlying Part, not two Part entries.
    assert {o["resolved_part_id"] for o in occurrences} == {bolt["id"]}
    part_ids = client.post(f"/document/parts/{root['id']}/add-component", json={"component": bolt_payload}).json()[
        "part_ids"
    ]
    assert part_ids.count(bolt["id"]) == 1


def test_add_component_does_not_discard_other_session_parts():
    root = _make_box_part("Mount 3")
    bolt = _make_box_part("Bolt 3", size=2.0)
    untouched = _make_box_part("Untouched")
    bolt_payload = _export_part(bolt["id"])

    response = client.post(f"/document/parts/{root['id']}/add-component", json={"component": bolt_payload})
    assert response.status_code == 200
    # Unlike `/import/native` (a full replace), an unrelated Part already
    # live in this session must survive an add-component call untouched.
    assert untouched["id"] in response.json()["part_ids"]
    assert client.get(f"/document/parts/{untouched['id']}").status_code == 200


def test_add_component_rejects_self_reference():
    root = _make_box_part("Mount 4")
    root_payload = _export_part(root["id"])

    response = client.post(f"/document/parts/{root['id']}/add-component", json={"component": root_payload})
    assert response.status_code == 422


def test_add_component_rejects_unknown_root_part():
    bolt = _make_box_part("Bolt 5", size=2.0)
    bolt_payload = _export_part(bolt["id"])

    response = client.post("/document/parts/not-a-real-part/add-component", json={"component": bolt_payload})
    assert response.status_code == 404


def test_add_component_rejects_empty_component_file():
    root = _make_box_part("Mount 6")

    response = client.post(
        f"/document/parts/{root['id']}/add-component",
        json={"component": {"schema_version": 1, "document": {"id": "x", "parts": []}, "sketches": []}},
    )
    assert response.status_code == 422
