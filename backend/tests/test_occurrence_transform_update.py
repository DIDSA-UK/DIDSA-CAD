"""Assembly support Phase 5 (`docs/assembly-scope.md`): `PATCH
/parts/{part_id}/occurrences/{occurrence_id}` - the first mutation
endpoint an Occurrence has ever had, added specifically so the Move/Rotate
gizmo has somewhere real to persist a drag to. Mirrors
`test_assembly_tree_endpoints.py`'s own setup helpers/composed-payload
convention.

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


def _setup_top_with_one_occurrence() -> tuple[str, str]:
    """Returns (top_part_id, occurrence_id) - a Top Part with one real
    Occurrence (`occ-bolt-1`, placing a Bolt Part) already imported,
    mirroring `test_assembly_tree_endpoints.py`'s own composed-payload
    setup."""
    top = _create_part("Top")
    bolt = _create_part("Bolt")
    top_export = _export_part(top["id"])
    bolt_export = _export_part(bolt["id"])
    top_part_dict = top_export["document"]["parts"][0]
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
            "id": "composed-doc",
            "root_part_id": top["id"],
            "parts": [top_part_dict, bolt_export["document"]["parts"][0]],
        },
        "sketches": [],
    }
    _import_composed(composed_payload)
    return top["id"], "occ-bolt-1"


def test_patching_the_transform_updates_it_and_returns_the_full_occurrence():
    top_id, occurrence_id = _setup_top_with_one_occurrence()

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [5.0, 1.0, -2.0],
                "rotation_axis": [0.0, 1.0, 0.0],
                "rotation_angle_degrees": 90.0,
            }
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["id"] == occurrence_id
    assert body["transform"]["translation"] == [5.0, 1.0, -2.0]
    assert body["transform"]["rotation_axis"] == [0.0, 1.0, 0.0]
    assert body["transform"]["rotation_angle_degrees"] == 90.0
    # Every other field is untouched by a transform-only PATCH.
    assert body["name_override"] is None
    assert body["suppressed"] is False
    assert body["hidden"] is False


def test_the_updated_transform_is_visible_on_a_subsequent_get_and_export():
    top_id, occurrence_id = _setup_top_with_one_occurrence()

    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [3.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 45.0,
            }
        },
    )

    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    updated = next(o for o in occurrences if o["id"] == occurrence_id)
    assert updated["transform"]["translation"] == [3.0, 0.0, 0.0]
    assert updated["transform"]["rotation_angle_degrees"] == 45.0

    exported = _export_part(top_id)
    exported_occurrence = exported["document"]["parts"][0]["occurrences"][0]
    assert exported_occurrence["transform"]["translation"] == [3.0, 0.0, 0.0]
    assert exported_occurrence["transform"]["rotation_angle_degrees"] == 45.0


def test_patching_an_unknown_part_returns_404():
    response = client.patch(
        "/document/parts/does-not-exist/occurrences/occ-1",
        json={
            "transform": {
                "translation": [0.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )
    assert response.status_code == 404


def test_patching_an_unknown_occurrence_on_a_real_part_returns_404():
    top = _create_part("Lonely Top")
    response = client.patch(
        f"/document/parts/{top['id']}/occurrences/does-not-exist",
        json={
            "transform": {
                "translation": [0.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )
    assert response.status_code == 404


def test_patching_leaves_every_other_occurrence_summary_field_alone():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    part_response = client.get(f"/document/parts/{top_id}").json()
    assert part_response["occurrence_ids"] == [occurrence_id]

    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [9.0, 9.0, 9.0],
                "rotation_axis": [1.0, 0.0, 0.0],
                "rotation_angle_degrees": 30.0,
            }
        },
    )

    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    assert len(occurrences) == 1
    assert occurrences[0]["transform"]["translation"] == [9.0, 9.0, 9.0]
