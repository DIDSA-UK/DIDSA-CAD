"""Assembly support Phase 3: the live, editable counterparts to the
assembly-mesh endpoint (`test_assembly_mesh.py`) - `GET /parts/{part_id}/
occurrences`, `GET /parts/{part_id}/mates`, and `PartResponse`'s new
`occurrence_ids`/`mate_ids` summary fields. What the Assembly tree panel
(Phase 3's client-side UI) actually reads from, as opposed to the
geometry-focused assembly-mesh response.

Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see docs/status.md's dated entries for whether a real
on-device/CI pass has actually run by the time this is read)."""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _export_part(part_id: str) -> dict:
    response = client.get("/document/export/native", params={"part_id": part_id})
    assert response.status_code == 200
    return response.json()


def _import_composed(payload: dict) -> None:
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200


def test_a_freshly_created_part_has_no_occurrences_or_mates():
    part = _create_part("Fresh Part")

    part_response = client.get(f"/document/parts/{part['id']}").json()
    assert part_response["occurrence_ids"] == []
    assert part_response["mate_ids"] == []

    assert client.get(f"/document/parts/{part['id']}/occurrences").json() == []
    assert client.get(f"/document/parts/{part['id']}/mates").json() == []


def test_occurrences_and_mates_appear_in_both_the_summary_and_the_full_list():
    top = _create_part("Top")
    bolt = _create_part("Bolt")
    bracket = _create_part("Bracket")

    top_export = _export_part(top["id"])
    bolt_export = _export_part(bolt["id"])
    bracket_export = _export_part(bracket["id"])
    top_part_dict = top_export["document"]["parts"][0]
    top_part_dict["occurrences"] = [
        {
            "id": "occ-bolt-1",
            "external_ref": "parts/bolt.didsa",
            "resolved_part_id": bolt["id"],
            "name_override": None,
            "transform": {
                "translation": [5.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "suppressed": False,
            "hidden": False,
        },
        {
            "id": "occ-bracket-1",
            "external_ref": "parts/bracket.didsa",
            "resolved_part_id": bracket["id"],
            "name_override": "My Bracket",
            "transform": {
                "translation": [0.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "suppressed": False,
            "hidden": True,
        },
    ]
    top_part_dict["mates"] = [
        {
            "id": "mate-1",
            "type": "coincident",
            "references": [
                {
                    "occurrence_id": "occ-bolt-1",
                    "subshape_ref": {"body_id": "body-1", "shape_type": "face", "index": 0},
                    "plane_ref": None,
                    "point_ref": None,
                },
                {
                    "occurrence_id": "occ-bracket-1",
                    "subshape_ref": {"body_id": "body-2", "shape_type": "face", "index": 1},
                    "plane_ref": None,
                    "point_ref": None,
                },
            ],
            "value": None,
            "flipped": False,
            "suppressed": False,
        }
    ]

    composed_payload = {
        "schema_version": top_export["schema_version"],
        "document": {
            "id": "composed-doc",
            "root_part_id": top["id"],
            "parts": [top_part_dict, bolt_export["document"]["parts"][0], bracket_export["document"]["parts"][0]],
        },
        "sketches": [],
    }
    _import_composed(composed_payload)

    part_response = client.get(f"/document/parts/{top['id']}").json()
    assert set(part_response["occurrence_ids"]) == {"occ-bolt-1", "occ-bracket-1"}
    assert part_response["mate_ids"] == ["mate-1"]

    occurrences = client.get(f"/document/parts/{top['id']}/occurrences").json()
    occurrences_by_id = {o["id"]: o for o in occurrences}
    assert occurrences_by_id["occ-bolt-1"]["resolved_part_id"] == bolt["id"]
    assert occurrences_by_id["occ-bolt-1"]["transform"]["translation"] == [5.0, 0.0, 0.0]
    assert occurrences_by_id["occ-bracket-1"]["hidden"] is True
    assert occurrences_by_id["occ-bracket-1"]["name_override"] == "My Bracket"

    mates = client.get(f"/document/parts/{top['id']}/mates").json()
    assert len(mates) == 1
    assert mates[0]["type"] == "coincident"
    assert len(mates[0]["references"]) == 2
    assert mates[0]["references"][0]["occurrence_id"] == "occ-bolt-1"
    assert mates[0]["references"][0]["subshape_ref"]["body_id"] == "body-1"


def test_occurrences_and_features_coexist_on_the_same_part_response():
    """The exact model-correction scenario (docs/assembly-scope.md
    decision #2): a Part with both a local Feature and an Occurrence shows
    both in its own PartResponse summary."""
    top = _create_part("Mixed Part")
    mount_sketch = client.post(f"/document/parts/{top['id']}/features/sketch", json={"plane": "XY"})
    assert mount_sketch.status_code == 201

    bolt = _create_part("Bolt")
    top_export = _export_part(top["id"])
    bolt_export = _export_part(bolt["id"])
    top_part_dict = top_export["document"]["parts"][0]
    assert len(top_part_dict["features"]) == 1  # the sketch feature
    top_part_dict["occurrences"] = [
        {
            "id": "occ-bolt-1",
            "external_ref": "parts/bolt.didsa",
            "resolved_part_id": bolt["id"],
            "name_override": None,
            "transform": {
                "translation": [0.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "suppressed": False,
            "hidden": False,
        }
    ]
    top_part_dict["mates"] = []

    composed_payload = {
        "schema_version": top_export["schema_version"],
        "document": {
            "id": "composed-doc-2",
            "root_part_id": top["id"],
            "parts": [top_part_dict, bolt_export["document"]["parts"][0]],
        },
        "sketches": top_export["sketches"],
    }
    _import_composed(composed_payload)

    part_response = client.get(f"/document/parts/{top['id']}").json()
    assert len(part_response["feature_ids"]) == 1
    assert part_response["occurrence_ids"] == ["occ-bolt-1"]
