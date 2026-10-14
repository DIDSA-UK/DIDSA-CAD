"""`POST /document/parts/{root_part_id}/add-component` - the backend port of
the Flutter client's own `add_component.dart::mergeComponentIntoDocument`,
built for the VR client (`DIDSA-UK/DIDSA-VR`), which has no Dart runtime to
call that function itself and otherwise has no way to add a second
Occurrence to its live session's assembly short of a full-replace
`/import/native` (see `app.document.add_component`'s own module docstring).
Mirrors `test_assembly_mesh_glb.py`'s own box-part fixture convention.

Needs a real pythonocc-core environment, same caveat as every other
extrude-backed fixture in this test suite."""

import json
from pathlib import Path

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


_DATA = Path(__file__).parent / "data"


def _load_fixture(name: str) -> dict:
    return json.loads((_DATA / name).read_text())


def _boss_end_distance(part_id: str) -> float:
    exported = _export_part(part_id)
    features = exported["document"]["parts"][0]["features"]
    first_extrude = next(f for f in features if f.get("type") == "extrude")
    return first_extrude["end_distance"]


def test_add_component_keeps_two_files_that_share_ids_apart():
    """Bug report 2026-10-14, item 3: Frame_B is a Save-As copy of Frame_A
    (same document, Part and sketch ids) edited to 1600 mm. Adding A then B
    used to dedup B away, leaving both occurrences on A's 800 mm Part."""
    root = _create_part("Assembly")
    frame_a = _load_fixture("frame_a_save_as_source.DIDSAprt")
    frame_b = _load_fixture("frame_b_save_as_copy.DIDSAprt")

    first = client.post(
        f"/document/parts/{root['id']}/add-component",
        json={"component": frame_a, "external_ref": "Frame_A.DIDSAprt"},
    )
    assert first.status_code == 200, first.text
    second = client.post(
        f"/document/parts/{root['id']}/add-component",
        json={"component": frame_b, "external_ref": "Frame_B.DIDSAprt"},
    )
    assert second.status_code == 200, second.text

    occurrences = client.get(f"/document/parts/{root['id']}/occurrences").json()
    resolved = [o["resolved_part_id"] for o in occurrences]
    assert len(resolved) == 2 and resolved[0] != resolved[1]
    assert {_boss_end_distance(part_id) for part_id in resolved} == {800.0, 1600.0}
    assert _boss_end_distance(resolved[0]) == 800.0
    assert _boss_end_distance(resolved[1]) == 1600.0


def test_add_component_same_file_twice_still_dedups_with_shared_ids():
    root = _create_part("Assembly 2")
    frame_a = _load_fixture("frame_a_save_as_source.DIDSAprt")
    for _ in range(2):
        response = client.post(
            f"/document/parts/{root['id']}/add-component",
            json={"component": frame_a, "external_ref": "Frame_A.DIDSAprt"},
        )
        assert response.status_code == 200, response.text
    occurrences = client.get(f"/document/parts/{root['id']}/occurrences").json()
    assert len({o["resolved_part_id"] for o in occurrences}) == 1
    assert response.json()["part_ids"].count(occurrences[0]["resolved_part_id"]) == 1


def test_add_component_colliding_file_added_twice_reuses_its_reminted_copy():
    root = _create_part("Assembly 3")
    frame_a = _load_fixture("frame_a_save_as_source.DIDSAprt")
    frame_b = _load_fixture("frame_b_save_as_copy.DIDSAprt")
    for payload, ref in [(frame_a, "A.DIDSAprt"), (frame_b, "B.DIDSAprt"), (frame_b, "B.DIDSAprt")]:
        response = client.post(
            f"/document/parts/{root['id']}/add-component", json={"component": payload, "external_ref": ref}
        )
        assert response.status_code == 200, response.text
    occurrences = client.get(f"/document/parts/{root['id']}/occurrences").json()
    resolved = [o["resolved_part_id"] for o in occurrences]
    assert resolved[1] == resolved[2] != resolved[0]
    # root + A + one re-minted B, not a second copy of B.
    assert len(response.json()["part_ids"]) >= 3
    assert response.json()["part_ids"].count(resolved[2]) == 1


def test_add_component_save_as_copy_of_open_part_is_insertable():
    """A pre-fix Save-As copy of the *open* Part carries the open Part's own
    id but different content: that is not a self-reference once re-minted."""
    frame_a = _load_fixture("frame_a_save_as_source.DIDSAprt")
    frame_b = _load_fixture("frame_b_save_as_copy.DIDSAprt")
    imported = client.post("/document/import/native", json=frame_a)
    assert imported.status_code == 200, imported.text
    root_id = imported.json()["part_ids"][0]

    response = client.post(
        f"/document/parts/{root_id}/add-component",
        json={"component": frame_b, "external_ref": "Frame_B.DIDSAprt"},
    )
    assert response.status_code == 200, response.text
    occurrence = client.get(f"/document/parts/{root_id}/occurrences").json()[0]
    assert occurrence["resolved_part_id"] != root_id
    assert _boss_end_distance(occurrence["resolved_part_id"]) == 1600.0
    assert _boss_end_distance(root_id) == 800.0
