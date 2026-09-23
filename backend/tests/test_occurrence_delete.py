"""Assembly-audit gap `[27]` (`docs/assembly-scope.md`): `DELETE
/parts/{part_id}/occurrences/{occurrence_id}` - the first delete an
Occurrence has ever had (every prior mutation was a `PATCH`; Mates/
ComponentPatterns both had real `DELETE` endpoints long before an
Occurrence itself did) - and `POST /parts/{part_id}/occurrences`, its
own client-supplied-id restore counterpart (Assembly-lens "Undo" after a
delete). Mirrors `test_occurrence_transform_update.py`'s own setup-helper
conventions.

Needs a real pythonocc-core environment - see that file's own note."""

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


def _occurrence_dict(occurrence_id: str, resolved_part_id: str, external_ref: str) -> dict:
    return {
        "id": occurrence_id,
        "external_ref": external_ref,
        "resolved_part_id": resolved_part_id,
        "name_override": None,
        "transform": {
            "translation": [0.0, 0.0, 0.0],
            "rotation_axis": [0.0, 0.0, 1.0],
            "rotation_angle_degrees": 0.0,
        },
        "suppressed": False,
        "hidden": False,
        "fixed": False,
    }


def _setup_top_with_two_occurrences() -> tuple[str, str, str]:
    """Returns (top_part_id, occ_1_id, occ_2_id) - a Top Part with two real
    Occurrences (`occ-bolt-1`/`occ-bolt-2`, both placing the same Bolt Part
    - Phase 2's own "one Part, several Occurrences" dedup precedent)
    already imported."""
    top = _create_part("Top")
    bolt = _create_part("Bolt")
    top_export = _export_part(top["id"])
    bolt_export = _export_part(bolt["id"])
    top_part_dict = top_export["document"]["parts"][0]
    top_part_dict["occurrences"] = [
        _occurrence_dict("occ-bolt-1", bolt["id"], "parts/bolt.didsa"),
        _occurrence_dict("occ-bolt-2", bolt["id"], "parts/bolt.didsa"),
    ]
    top_part_dict["mates"] = []
    top_part_dict["component_patterns"] = []
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
    return top["id"], "occ-bolt-1", "occ-bolt-2"


def _create_mate_referencing(top_id: str, occurrence_id: str) -> str:
    """A structurally-valid Mate (never solved in these tests, so no real
    Body geometry is needed) - one side names `occurrence_id` via a
    `fixed_plane` `PlaneRef` (validated only structurally by `create_mate`,
    never resolved against real geometry until a `solve` call this test
    never makes), the other side is the root's own content (`""`,
    `_validate_mate_entity_ref`'s own convention)."""
    response = client.post(
        f"/document/parts/{top_id}/mates",
        json={
            "type": "coincident",
            "references": [
                {"occurrence_id": occurrence_id, "plane_ref": {"fixed_plane": "XY"}},
                {"occurrence_id": "", "plane_ref": {"fixed_plane": "XY"}},
            ],
        },
    )
    assert response.status_code == 201
    return response.json()["id"]


def _create_pattern_sourced_from(top_id: str, occurrence_ids: list[str]) -> str:
    response = client.post(
        f"/document/parts/{top_id}/component-patterns",
        json={
            "source_occurrence_ids": occurrence_ids,
            "pattern_type": "linear",
            "direction": [1.0, 0.0, 0.0],
            "count": 3,
            "spacing": 10.0,
        },
    )
    assert response.status_code == 201
    return response.json()["id"]


# --- DELETE /parts/{part_id}/occurrences/{occurrence_id} -----------------


def test_deleting_an_unreferenced_occurrence_leaves_everything_else_alone():
    top_id, occ_1, occ_2 = _setup_top_with_two_occurrences()
    mate_id = _create_mate_referencing(top_id, occ_2)
    pattern_id = _create_pattern_sourced_from(top_id, [occ_2])

    response = client.delete(f"/document/parts/{top_id}/occurrences/{occ_1}")
    assert response.status_code == 204

    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    assert [o["id"] for o in occurrences] == [occ_2]

    mates = client.get(f"/document/parts/{top_id}/mates").json()
    assert [m["id"] for m in mates] == [mate_id]

    patterns = client.get(f"/document/parts/{top_id}/component-patterns").json()
    assert [p["id"] for p in patterns] == [pattern_id]


def test_deleting_an_occurrence_cascades_the_mate_that_references_it():
    top_id, occ_1, occ_2 = _setup_top_with_two_occurrences()
    _create_mate_referencing(top_id, occ_1)
    unrelated_mate_id = _create_mate_referencing(top_id, occ_2)

    response = client.delete(f"/document/parts/{top_id}/occurrences/{occ_1}")
    assert response.status_code == 204

    mates = client.get(f"/document/parts/{top_id}/mates").json()
    assert [m["id"] for m in mates] == [unrelated_mate_id]


def test_deleting_one_of_several_pattern_sources_removes_the_whole_pattern():
    """Cascade removes the whole feature it's found in, never a partial
    mutation of `source_occurrence_ids` - keeps the client's own pre-delete
    warning dialog simple and exhaustively enumerable (`docs/assembly-
    scope.md`)."""
    top_id, occ_1, occ_2 = _setup_top_with_two_occurrences()
    _create_pattern_sourced_from(top_id, [occ_1, occ_2])
    unrelated_pattern_id = _create_pattern_sourced_from(top_id, [occ_2])

    response = client.delete(f"/document/parts/{top_id}/occurrences/{occ_1}")
    assert response.status_code == 204

    patterns = client.get(f"/document/parts/{top_id}/component-patterns").json()
    assert [p["id"] for p in patterns] == [unrelated_pattern_id]


def test_deleting_an_occurrence_referenced_by_both_a_mate_and_a_pattern_removes_both():
    top_id, occ_1, _occ_2 = _setup_top_with_two_occurrences()
    _create_mate_referencing(top_id, occ_1)
    _create_pattern_sourced_from(top_id, [occ_1])

    response = client.delete(f"/document/parts/{top_id}/occurrences/{occ_1}")
    assert response.status_code == 204

    assert client.get(f"/document/parts/{top_id}/mates").json() == []
    assert client.get(f"/document/parts/{top_id}/component-patterns").json() == []


def test_deleted_occurrence_no_longer_appears_in_assembly_mesh():
    top_id, occ_1, occ_2 = _setup_top_with_two_occurrences()
    client.delete(f"/document/parts/{top_id}/occurrences/{occ_1}")

    mesh = client.get(f"/document/parts/{top_id}/assembly-mesh").json()
    paths = [i["occurrence_path"] for i in mesh["instances"]]
    assert [occ_1] not in paths
    assert [occ_2] in paths


def test_deleting_an_occurrence_on_an_unknown_part_returns_404():
    response = client.delete("/document/parts/does-not-exist/occurrences/occ-1")
    assert response.status_code == 404


def test_deleting_an_unknown_occurrence_on_a_real_part_returns_404():
    top = _create_part("Lonely Top")
    response = client.delete(f"/document/parts/{top['id']}/occurrences/does-not-exist")
    assert response.status_code == 404


# --- POST /parts/{part_id}/occurrences (restore, for Undo) ---------------


def test_restoring_a_deleted_occurrence_round_trips_its_full_field_set():
    top_id, occ_1, _occ_2 = _setup_top_with_two_occurrences()
    client.patch(f"/document/parts/{top_id}/occurrences/{occ_1}", json={"color": "#AABBCC", "hidden": True})
    before = next(
        o for o in client.get(f"/document/parts/{top_id}/occurrences").json() if o["id"] == occ_1
    )

    assert client.delete(f"/document/parts/{top_id}/occurrences/{occ_1}").status_code == 204
    assert occ_1 not in [o["id"] for o in client.get(f"/document/parts/{top_id}/occurrences").json()]

    response = client.post(
        f"/document/parts/{top_id}/occurrences",
        json={
            "id": before["id"],
            "external_ref": before["external_ref"],
            "name_override": before["name_override"],
            "transform": before["transform"],
            "suppressed": before["suppressed"],
            "hidden": before["hidden"],
            "fixed": before["fixed"],
            "color": before["color"],
        },
    )
    assert response.status_code == 201
    restored = response.json()
    assert restored["id"] == occ_1
    assert restored["color"] == "#AABBCC"
    assert restored["hidden"] is True
    # `resolved_part_id` is deliberately not part of `OccurrenceCreate` (it
    # is never client-settable, only ever populated by `import_native`'s own
    # cross-reference resolution) - a restored Occurrence is unresolved
    # until a later full-graph reimport resolves it again, the same
    # single-file-round-trip behavior every other Occurrence already has.
    assert restored["resolved_part_id"] is None

    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    assert sorted(o["id"] for o in occurrences) == sorted([occ_1, _occ_2])


def test_restoring_with_a_duplicate_id_is_rejected():
    top_id, occ_1, _occ_2 = _setup_top_with_two_occurrences()

    response = client.post(
        f"/document/parts/{top_id}/occurrences",
        json={"id": occ_1, "transform": None},
    )
    assert response.status_code == 409


def test_restoring_on_an_unknown_part_returns_404():
    response = client.post(
        "/document/parts/does-not-exist/occurrences",
        json={"id": "occ-1", "transform": None},
    )
    assert response.status_code == 404


def test_restoring_with_no_transform_defaults_to_identity():
    top = _create_part("Lonely Top")
    response = client.post(
        f"/document/parts/{top['id']}/occurrences",
        json={"id": "occ-restored"},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["transform"]["translation"] == [0.0, 0.0, 0.0]
    assert body["transform"]["rotation_angle_degrees"] == 0.0
