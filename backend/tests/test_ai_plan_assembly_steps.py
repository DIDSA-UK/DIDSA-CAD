"""Assembly support Phase 8 (`docs/assembly-scope.md` §2k): the AI plan
pipeline's four new occurrence-targeting `PlanStep` kinds -
`mate`/`move_component`/`hide_component`/`isolate_component`. Every one of
them can only ever reference an *already-existing* Occurrence on the Part
being edited (`existing:<occurrence_id>`) - no `PlanStep` kind places a new
one yet (`add_component`'s own client-side file-discovery gap) - so every
test here sets up its Part's real Occurrences directly (mirroring
`test_occurrence_transform_update.py`'s own composed-payload convention)
before validating a plan against them.

Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see docs/status.md's dated entries for whether a real
on-device/CI pass has actually run by the time this is read)."""

from fastapi.testclient import TestClient

from app.document.ai_plan import _PlanValidator
from app.document.ai_plan_schemas import (
    HideComponentStep,
    IsolateComponentStep,
    MateEntityRefStep,
    MateStep,
    MoveComponentStep,
)
from app.document.models import MateType
from app.document.store import get_part_or_404
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
    }


def _setup_top_with_two_occurrences() -> tuple[str, str, str]:
    """Returns (top_part_id, occurrence_id_1, occurrence_id_2) - a Top Part
    with two real top-level Occurrences (of two different Bolt-like Parts)
    already imported."""
    top = _create_part("Top")
    bolt_a = _create_part("BoltA")
    bolt_b = _create_part("BoltB")
    top_export = _export_part(top["id"])
    top_part_dict = top_export["document"]["parts"][0]
    top_part_dict["occurrences"] = [
        _occurrence_dict("occ-a", bolt_a["id"], "parts/bolt_a.didsa"),
        _occurrence_dict("occ-b", bolt_b["id"], "parts/bolt_b.didsa"),
    ]
    top_part_dict["mates"] = []
    composed_payload = {
        "schema_version": top_export["schema_version"],
        "document": {
            "id": "composed-doc",
            "root_part_id": top["id"],
            "parts": [top_part_dict, _export_part(bolt_a["id"])["document"]["parts"][0], _export_part(bolt_b["id"])["document"]["parts"][0]],
        },
        "sketches": [],
    }
    _import_composed(composed_payload)
    return top["id"], "occ-a", "occ-b"


def _validate(part_id: str, steps: list[dict]) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/ai-plan/validate",
        json={"version": 1, "steps": steps},
    )
    assert response.status_code == 200
    return response.json()


def _results_by_local_id(response: dict) -> dict[str, dict]:
    return {result["local_id"]: result for result in response["results"]}


# --- move_component --------------------------------------------------------


def test_move_component_step_ok_over_http():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "m1",
                "kind": "move_component",
                "occurrence_id": f"existing:{occ_a}",
                "translation": [5.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 90.0,
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["m1"]["ok"] is True, results["m1"]


def test_move_component_dry_run_does_not_persist_against_the_real_part():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    before = next(o for o in real_part.occurrences if o.id == occ_a)
    assert before.transform.translation == (0.0, 0.0, 0.0)

    results = _PlanValidator(real_part).run(
        [MoveComponentStep(local_id="m1", occurrence_id=f"existing:{occ_a}", translation=(9.0, 9.0, 9.0))]
    )

    assert all(r.ok for r in results), results
    after = next(o for o in get_part_or_404(top_id).occurrences if o.id == occ_a)
    assert after.transform.translation == (0.0, 0.0, 0.0)


def test_move_component_requires_existing_prefix():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [{"local_id": "m1", "kind": "move_component", "occurrence_id": occ_a}],
    )
    results = _results_by_local_id(response)

    assert results["m1"]["ok"] is False
    assert results["m1"]["error"]["type"] == "occurrence_requires_existing_prefix"


def test_move_component_unknown_existing_occurrence_rejected():
    top_id, _, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [{"local_id": "m1", "kind": "move_component", "occurrence_id": "existing:not-a-real-occurrence"}],
    )
    results = _results_by_local_id(response)

    assert results["m1"]["ok"] is False
    assert results["m1"]["error"]["type"] == "unknown_existing_id"


# --- hide_component / isolate_component -------------------------------------


def test_hide_component_step_ok_and_does_not_persist():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)

    results = _PlanValidator(real_part).run([HideComponentStep(local_id="h1", occurrence_id=f"existing:{occ_a}")])

    assert all(r.ok for r in results), results
    assert next(o for o in get_part_or_404(top_id).occurrences if o.id == occ_a).hidden is False


def test_isolate_component_hides_every_other_occurrence_in_the_scratch_copy():
    top_id, occ_a, occ_b = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    validator = _PlanValidator(real_part)

    results = validator.run([IsolateComponentStep(local_id="i1", occurrence_id=f"existing:{occ_a}")])

    assert all(r.ok for r in results), results
    scratch_a = next(o for o in validator.part.occurrences if o.id == occ_a)
    scratch_b = next(o for o in validator.part.occurrences if o.id == occ_b)
    assert scratch_a.hidden is False
    assert scratch_b.hidden is True
    # Never persisted against the real Part.
    real_a = next(o for o in get_part_or_404(top_id).occurrences if o.id == occ_a)
    real_b = next(o for o in get_part_or_404(top_id).occurrences if o.id == occ_b)
    assert real_a.hidden is False
    assert real_b.hidden is False


def test_hide_component_over_http():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(top_id, [{"local_id": "h1", "kind": "hide_component", "occurrence_id": f"existing:{occ_a}"}])
    results = _results_by_local_id(response)

    assert results["h1"]["ok"] is True, results["h1"]


# --- mate --------------------------------------------------------------


def _face_ref(occurrence_id: str, body_id: str = "b1", index: int = 0) -> dict:
    return {"occurrence_id": occurrence_id, "subshape_ref": {"body_id": body_id, "shape_type": "face", "index": index}}


def test_mate_step_creates_a_structural_mate_between_two_existing_occurrences():
    top_id, occ_a, occ_b = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [_face_ref(f"existing:{occ_a}"), _face_ref(f"existing:{occ_b}")],
            }
        ],
    )
    results = _results_by_local_id(response)

    assert results["mate1"]["ok"] is True, results["mate1"]


def test_mate_step_dry_run_does_not_persist_against_the_real_part():
    top_id, occ_a, occ_b = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    assert real_part.mates == []

    results = _PlanValidator(real_part).run(
        [
            MateStep(
                local_id="mate1",
                type=MateType.COINCIDENT,
                references=[
                    MateEntityRefStep.model_validate(_face_ref(f"existing:{occ_a}")),
                    MateEntityRefStep.model_validate(_face_ref(f"existing:{occ_b}")),
                ],
            )
        ]
    )

    assert all(r.ok for r in results), results
    assert get_part_or_404(top_id).mates == []


def test_mate_step_rejects_the_same_occurrence_referenced_twice():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [_face_ref(f"existing:{occ_a}"), _face_ref(f"existing:{occ_a}", body_id="b2")],
            }
        ],
    )
    results = _results_by_local_id(response)

    assert results["mate1"]["ok"] is False
    assert results["mate1"]["error"]["type"] == "invalid_step_payload"


def test_mate_step_distance_requires_a_value():
    top_id, occ_a, occ_b = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "distance",
                "references": [_face_ref(f"existing:{occ_a}"), _face_ref(f"existing:{occ_b}")],
            }
        ],
    )
    results = _results_by_local_id(response)

    assert results["mate1"]["ok"] is False
    assert results["mate1"]["error"]["type"] == "invalid_step_payload"


def test_mate_step_root_part_content_reference_via_empty_occurrence_id():
    """`occurrence_id: ""` means "this Part's own root content" - the same
    convention a real Mate's own `_validate_mate_entity_ref` already allows,
    mirrored here for the AI-authored equivalent."""
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [_face_ref(""), _face_ref(f"existing:{occ_a}")],
            }
        ],
    )
    results = _results_by_local_id(response)

    assert results["mate1"]["ok"] is True, results["mate1"]


def test_mate_step_unknown_existing_occurrence_rejected():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [_face_ref(f"existing:{occ_a}"), _face_ref("existing:not-a-real-occurrence")],
            }
        ],
    )
    results = _results_by_local_id(response)

    assert results["mate1"]["ok"] is False
    assert results["mate1"]["error"]["type"] == "unknown_existing_id"


def test_mate_step_wrong_number_of_references_rejected():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [{"local_id": "mate1", "kind": "mate", "type": "coincident", "references": [_face_ref(f"existing:{occ_a}")]}],
    )
    results = _results_by_local_id(response)

    assert results["mate1"]["ok"] is False
    assert results["mate1"]["error"]["type"] == "invalid_step_payload"
