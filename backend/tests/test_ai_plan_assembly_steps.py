"""Assembly support Phase 8 (`docs/assembly-scope.md` §2k): the AI plan
pipeline's occurrence-targeting `PlanStep` kinds -
`mate`/`move_component`/`hide_component`/`isolate_component`/
`pattern_component`. Every one of them can reference an *already-existing*
Occurrence on the Part being edited (`existing:<occurrence_id>`) - so most
tests here set up their Part's real Occurrences directly (mirroring
`test_occurrence_transform_update.py`'s own composed-payload convention)
before validating a plan against them.

Phase 18 (`docs/assembly-scope.md` §6 `[2]`) added `add_component` - the
first `PlanStep` kind that *places* a brand-new Occurrence rather than only
ever referencing one a human already placed by hand - see the `# ---
add_component ---` section below for its own tests, including a later step
in the same plan referencing its plan-local `local_id` directly (no
`existing:` prefix).

Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see docs/status.md's dated entries for whether a real
on-device/CI pass has actually run by the time this is read)."""

from fastapi.testclient import TestClient

from app.document.ai_plan import _PlanValidator
from app.document.ai_plan_schemas import (
    AddComponentStep,
    HideComponentStep,
    IsolateComponentStep,
    MateEntityRefStep,
    MateStep,
    MoveComponentStep,
    PatternComponentStep,
    SketchStep,
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


def _add_box_body(part_id: str, *, size: float = 10.0, depth: float = 10.0) -> str:
    """Phase 14 (`docs/assembly-scope.md` §6 `[3]`): extrudes a real
    `size` x `size` x `depth` box (corner at the origin) directly onto
    `part_id` - unlike this file's own pre-Phase-14 tests (structural-only,
    no real OCCT resolution ever happened for a Mate reference before this
    phase), an `edge_selector` genuinely needs real Body topology to
    resolve against. Returns the real `body_id`."""
    sketch_response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]
    corners = [_add_point(sketch_id, x, y) for x, y in [(0, 0), (size, 0), (size, size), (0, size)]]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])
    extrude_response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_response.json()["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": depth,
            "target_body_ids": [],
        },
    )
    assert extrude_response.status_code == 201
    mesh = client.get(f"/document/parts/{part_id}/mesh").json()
    return mesh[0]["body_id"]


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


def _setup_top_with_box_and_two_occurrences() -> tuple[str, str, str, str]:
    """Phase 14 (`docs/assembly-scope.md` §6 `[3]`): `_setup_top_with_two_
    occurrences`'s own sibling, plus a real 10x10x25 box Body on `top`
    itself (needed for `edge_selector`'s own real OCCT resolution) - a
    non-cubic depth deliberately makes a vertical edge's own length (25.0)
    distinguishable from a horizontal one's (10.0) without needing a
    straight edge's own `axis` (Phase 13, `docs/assembly-scope.md` §6
    `[15]`, a separate, independently-mergeable branch not assumed present
    here - `length` alone, already real behavior with no such dependency,
    is enough to confirm which edge actually resolved). Returns
    `(top_part_id, top_body_id, occurrence_id_1, occurrence_id_2)`."""
    top = _create_part("Top")
    top_body_id = _add_box_body(top["id"], size=10.0, depth=25.0)
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
        "sketches": top_export["sketches"],
    }
    _import_composed(composed_payload)
    return top["id"], top_body_id, "occ-a", "occ-b"


def _validate(part_id: str, steps: list[dict]) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/ai-plan/validate",
        json={"version": 1, "steps": steps},
    )
    assert response.status_code == 200
    return response.json()


def _results_by_local_id(response: dict) -> dict[str, dict]:
    return {result["local_id"]: result for result in response["results"]}


# --- add_component (Phase 18, docs/assembly-scope.md §6 [2]) ---------------


def test_add_component_step_creates_a_structural_occurrence_dry_run():
    top_id, _, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    before_count = len(real_part.occurrences)

    results = _PlanValidator(real_part).run(
        [AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt")]
    )

    assert all(r.ok for r in results), results
    # Never persisted against the real Part - scratch-only, per every other
    # handler's own contract.
    assert len(get_part_or_404(top_id).occurrences) == before_count


def test_add_component_first_occurrence_is_auto_fixed():
    top = _create_part("Top")
    real_part = get_part_or_404(top["id"])
    validator = _PlanValidator(real_part)

    results = validator.run([AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt")])

    assert all(r.ok for r in results), results
    assert validator._local_occurrence_by_id["ac1"].fixed is True


def test_add_component_second_occurrence_is_not_auto_fixed():
    top_id, _, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    validator = _PlanValidator(real_part)

    results = validator.run([AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt")])

    assert all(r.ok for r in results), results
    assert validator._local_occurrence_by_id["ac1"].fixed is False


def test_add_component_rejects_empty_relative_path():
    top = _create_part("Top")

    response = _validate(top["id"], [{"local_id": "ac1", "kind": "add_component", "relative_path": "   "}])
    results = _results_by_local_id(response)

    assert results["ac1"]["ok"] is False
    assert results["ac1"]["error"]["type"] == "invalid_step_payload"


def test_add_component_over_http():
    top = _create_part("Top")

    response = _validate(
        top["id"],
        [{"local_id": "ac1", "kind": "add_component", "relative_path": "parts/bracket.DIDSAprt", "name_override": "Bracket"}],
    )
    results = _results_by_local_id(response)

    assert results["ac1"]["ok"] is True, results["ac1"]


def test_add_component_then_move_component_references_the_plan_local_occurrence():
    top = _create_part("Top")
    real_part = get_part_or_404(top["id"])
    validator = _PlanValidator(real_part)

    results = validator.run(
        [
            AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt"),
            MoveComponentStep(local_id="m1", occurrence_id="ac1", translation=(1.0, 2.0, 3.0)),
        ]
    )

    assert all(r.ok for r in results), results
    scratch = validator._local_occurrence_by_id["ac1"]
    assert scratch.transform.translation == (1.0, 2.0, 3.0)


def test_add_component_then_hide_component_references_the_plan_local_occurrence():
    top = _create_part("Top")
    real_part = get_part_or_404(top["id"])
    validator = _PlanValidator(real_part)

    results = validator.run(
        [
            AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt"),
            HideComponentStep(local_id="h1", occurrence_id="ac1"),
        ]
    )

    assert all(r.ok for r in results), results
    assert validator._local_occurrence_by_id["ac1"].hidden is True


def test_add_component_then_isolate_component_references_the_plan_local_occurrence():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    validator = _PlanValidator(real_part)

    results = validator.run(
        [
            AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt"),
            IsolateComponentStep(local_id="i1", occurrence_id="ac1"),
        ]
    )

    assert all(r.ok for r in results), results
    new_occurrence = validator._local_occurrence_by_id["ac1"]
    assert new_occurrence.hidden is False
    scratch_a = next(o for o in validator.part.occurrences if o.id == occ_a)
    assert scratch_a.hidden is True


def test_add_component_then_mate_references_the_plan_local_occurrence():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    validator = _PlanValidator(real_part)

    results = validator.run(
        [
            AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt"),
            MateStep(
                local_id="mate1",
                type=MateType.COINCIDENT,
                references=[
                    MateEntityRefStep(occurrence_id=f"existing:{occ_a}", subshape_ref={"body_id": "b1", "shape_type": "face", "index": 0}),
                    MateEntityRefStep(occurrence_id="ac1", subshape_ref={"body_id": "b1", "shape_type": "face", "index": 0}),
                ],
            ),
        ]
    )

    assert all(r.ok for r in results), results
    new_occurrence = validator._local_occurrence_by_id["ac1"]
    assert any(m.references[1].occurrence_id == new_occurrence.id for m in validator.part.mates)


def test_add_component_then_pattern_component_references_the_plan_local_occurrence():
    top = _create_part("Top")
    real_part = get_part_or_404(top["id"])
    validator = _PlanValidator(real_part)

    results = validator.run(
        [
            AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt"),
            PatternComponentStep(local_id="p1", source_occurrence_ids=["ac1"], pattern_type="linear", direction=(1.0, 0.0, 0.0), count=3),
        ]
    )

    assert all(r.ok for r in results), results
    new_occurrence = validator._local_occurrence_by_id["ac1"]
    assert any(p.source_occurrence_ids == [new_occurrence.id] for p in validator.part.component_patterns)


def test_pattern_component_accepts_mixed_existing_and_plan_local_source_occurrence_ids():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    validator = _PlanValidator(real_part)

    results = validator.run(
        [
            AddComponentStep(local_id="ac1", relative_path="parts/bracket.DIDSAprt"),
            PatternComponentStep(
                local_id="p1",
                source_occurrence_ids=[f"existing:{occ_a}", "ac1"],
                pattern_type="linear",
                direction=(1.0, 0.0, 0.0),
                count=3,
            ),
        ]
    )

    assert all(r.ok for r in results), results


def test_move_component_wrong_kind_reference_when_naming_a_non_occurrence_local_id():
    """A bare plan-local id that resolves to a Feature-producing step's own
    `local_id` (never an Occurrence) is a `wrong_kind_reference`, not the
    generic `occurrence_requires_existing_prefix` fallback - a clearer error
    than blaming a missing `existing:` prefix on something that was never
    going to be an Occurrence reference at all."""
    top = _create_part("Top")
    real_part = get_part_or_404(top["id"])
    validator = _PlanValidator(real_part)

    results = validator.run(
        [
            SketchStep(local_id="s1", plane="XY"),
            MoveComponentStep(local_id="m1", occurrence_id="s1"),
        ]
    )

    assert results[0].ok is True, results[0]
    assert results[1].ok is False
    assert results[1].error["type"] == "wrong_kind_reference"
    assert results[1].error["actual_kind"] == "sketch"


def test_move_component_depends_on_failed_add_component_step():
    top = _create_part("Top")
    real_part = get_part_or_404(top["id"])
    validator = _PlanValidator(real_part)

    results = validator.run(
        [
            AddComponentStep(local_id="ac1", relative_path="   "),
            MoveComponentStep(local_id="m1", occurrence_id="ac1"),
        ]
    )

    assert results[0].ok is False
    assert results[1].ok is False
    assert results[1].error["type"] == "depends_on_failed_step"


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


def test_move_component_rejects_a_nonzero_angle_with_a_zero_length_axis():
    """§6 roadmap Phase 10 (`[4]`): `_validate_occurrence_transform_payload`
    is reused from `_handle_move_component`'s own dry-run path, not just the
    real PATCH endpoint - a `move_component` step with a degenerate rotation
    is rejected at validate time, the same way it would be rejected for real
    execution."""
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "m1",
                "kind": "move_component",
                "occurrence_id": f"existing:{occ_a}",
                "rotation_axis": [0.0, 0.0, 0.0],
                "rotation_angle_degrees": 30.0,
            }
        ],
    )
    results = _results_by_local_id(response)

    assert results["m1"]["ok"] is False


def test_move_component_dry_run_rejection_does_not_persist_against_the_real_part():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)

    results = _PlanValidator(real_part).run(
        [
            MoveComponentStep(
                local_id="m1",
                occurrence_id=f"existing:{occ_a}",
                translation=(9.0, 9.0, 9.0),
                rotation_axis=(0.0, 0.0, 0.0),
                rotation_angle_degrees=30.0,
            )
        ]
    )

    assert not any(r.ok for r in results), results
    after = next(o for o in get_part_or_404(top_id).occurrences if o.id == occ_a)
    assert after.transform.translation == (0.0, 0.0, 0.0)


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


# --- mate edge_selector (Phase 14, docs/assembly-scope.md §6 [3]) ----------


def _edge_ref(occurrence_id: str, body_id: str, *, edge_selector: dict | None = None) -> dict:
    ref = {"occurrence_id": occurrence_id, "subshape_ref": {"body_id": body_id, "shape_type": "edge", "index": 0}}
    if edge_selector is not None:
        ref["edge_selector"] = edge_selector
    return ref


def test_mate_edge_selector_resolves_against_the_root_parts_own_real_body():
    top_id, top_body_id, occ_a, _ = _setup_top_with_box_and_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [
                    _edge_ref("", top_body_id, edge_selector={"selector": "vertical_edges", "of": ""}),
                    _face_ref(f"existing:{occ_a}"),
                ],
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["mate1"]["ok"] is True, results["mate1"]
    # Resolved to a real edge index, surfaced back for the translator - the
    # driven side (index 1, the face ref) never used a selector, so its own
    # entry is null.
    resolved = results["mate1"]["resolved_mate_references"]
    assert resolved is not None
    assert resolved[0]["body_id"] == top_body_id
    assert resolved[0]["shape_type"] == "edge"
    assert isinstance(resolved[0]["index"], int)
    assert resolved[1] is None


def test_mate_edge_selector_direct_call_resolves_to_a_real_vertical_edge():
    """Same assertion as the HTTP test above, but exercised directly through
    `_PlanValidator` (mirrors this file's own `_lookup_occurrence`-only
    tests' convention of also covering the non-HTTP path) - confirms the
    resolved index really is a real, current vertical edge of the box, not
    just "some" edge, by cross-checking it via the real Measure endpoint."""
    top_id, top_body_id, occ_a, _ = _setup_top_with_box_and_two_occurrences()
    real_part = get_part_or_404(top_id)

    results = _PlanValidator(real_part).run(
        [
            MateStep(
                local_id="mate1",
                type=MateType.COINCIDENT,
                references=[
                    MateEntityRefStep.model_validate(
                        _edge_ref("", top_body_id, edge_selector={"selector": "vertical_edges", "of": ""})
                    ),
                    MateEntityRefStep.model_validate(_face_ref(f"existing:{occ_a}")),
                ],
            )
        ]
    )
    assert all(r.ok for r in results), results

    resolved_index = results[0].resolved_mate_references[0].index
    measure_response = client.post(
        f"/document/parts/{top_id}/measure",
        json={"refs": [{"body_id": top_body_id, "shape_type": "edge", "index": resolved_index}]},
    )
    assert measure_response.status_code == 200
    # A vertical edge of this box (10x10 base, 25 tall) is 25.0 long - a
    # horizontal (top/bottom perimeter) edge would be 10.0, so this alone
    # confirms the resolved index really is one of the 4 vertical edges,
    # not a horizontal one, with no dependency on Phase 13's own straight-
    # edge `axis` support (a separate, independently-mergeable branch).
    assert measure_response.json()["length"] == 25.0


def test_mate_edge_selector_rejects_a_placed_occurrence_reference():
    """`[3]`'s own real scope limit: a placed Occurrence's own target Part
    is a different Part this single-Part-scoped validator has no geometry
    access to at all - `edge_selector` is only supported for
    `occurrence_id == ""`."""
    top_id, top_body_id, occ_a, _ = _setup_top_with_box_and_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [
                    _edge_ref(f"existing:{occ_a}", top_body_id, edge_selector={"selector": "vertical_edges", "of": ""}),
                    _face_ref(""),
                ],
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["mate1"]["ok"] is False
    assert results["mate1"]["error"]["type"] == "invalid_step_payload"


def test_mate_edge_selector_rejects_a_provenance_selector_kind():
    top_id, top_body_id, occ_a, _ = _setup_top_with_box_and_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [
                    _edge_ref("", top_body_id, edge_selector={"selector": "edge_from_sketch_point", "of": ""}),
                    _face_ref(f"existing:{occ_a}"),
                ],
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["mate1"]["ok"] is False
    assert results["mate1"]["error"]["type"] == "invalid_step_payload"


def test_mate_edge_selector_rejects_a_non_edge_subshape_ref():
    top_id, top_body_id, occ_a, _ = _setup_top_with_box_and_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [
                    {
                        "occurrence_id": "",
                        "subshape_ref": {"body_id": top_body_id, "shape_type": "face", "index": 0},
                        "edge_selector": {"selector": "vertical_edges", "of": ""},
                    },
                    _face_ref(f"existing:{occ_a}"),
                ],
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["mate1"]["ok"] is False
    assert results["mate1"]["error"]["type"] == "invalid_step_payload"


def test_mate_without_edge_selector_leaves_resolved_mate_references_null():
    """Regression guard: `resolved_mate_references` must stay absent (not
    e.g. `[null, null]`) for the overwhelmingly common case of a Mate that
    never uses `edge_selector` at all - see `_handle_mate`'s own doc
    comment on why."""
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
    assert results["mate1"]["resolved_mate_references"] is None


# --- pattern_component (Phase 14, docs/assembly-scope.md §6 [1] partial) ---


def test_pattern_component_step_creates_a_structural_component_pattern():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "p1",
                "kind": "pattern_component",
                "source_occurrence_ids": [f"existing:{occ_a}"],
                "pattern_type": "linear",
                "direction": [1.0, 0.0, 0.0],
                "count": 4,
                "spacing": 10.0,
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["p1"]["ok"] is True, results["p1"]


def test_pattern_component_dry_run_does_not_persist_against_the_real_part():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()
    real_part = get_part_or_404(top_id)
    assert real_part.component_patterns == []

    results = _PlanValidator(real_part).run(
        [
            PatternComponentStep(
                local_id="p1",
                source_occurrence_ids=[f"existing:{occ_a}"],
                pattern_type="linear",
                direction=(1.0, 0.0, 0.0),
                count=3,
                spacing=5.0,
            )
        ]
    )

    assert all(r.ok for r in results), results
    assert get_part_or_404(top_id).component_patterns == []


def test_pattern_component_multiple_source_occurrences():
    top_id, occ_a, occ_b = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "p1",
                "kind": "pattern_component",
                "source_occurrence_ids": [f"existing:{occ_a}", f"existing:{occ_b}"],
                "pattern_type": "circular",
                "axis": {"origin": [0.0, 0.0, 0.0], "direction": [0.0, 0.0, 1.0]},
                "count_angular": 4,
                "angle_total": 360.0,
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["p1"]["ok"] is True, results["p1"]


def test_pattern_component_requires_existing_prefix():
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "p1",
                "kind": "pattern_component",
                "source_occurrence_ids": [occ_a],
                "count": 3,
                "spacing": 5.0,
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["p1"]["ok"] is False
    assert results["p1"]["error"]["type"] == "occurrence_requires_existing_prefix"


def test_pattern_component_unknown_existing_occurrence_rejected():
    top_id, _, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "p1",
                "kind": "pattern_component",
                "source_occurrence_ids": ["existing:not-a-real-occurrence"],
                "count": 3,
                "spacing": 5.0,
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["p1"]["ok"] is False
    assert results["p1"]["error"]["type"] == "unknown_existing_id"


def test_pattern_component_rejects_count_below_two():
    """Reuses `_validate_component_pattern_payload` directly - the same
    real-backend validation the real `POST .../component-patterns` endpoint
    enforces, not a separate, potentially-drifting re-implementation."""
    top_id, occ_a, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [
            {
                "local_id": "p1",
                "kind": "pattern_component",
                "source_occurrence_ids": [f"existing:{occ_a}"],
                "pattern_type": "linear",
                "count": 1,
                "spacing": 5.0,
            }
        ],
    )
    results = _results_by_local_id(response)
    assert results["p1"]["ok"] is False


def test_pattern_component_rejects_empty_source_occurrence_ids():
    top_id, _, _ = _setup_top_with_two_occurrences()

    response = _validate(
        top_id,
        [{"local_id": "p1", "kind": "pattern_component", "source_occurrence_ids": [], "count": 3, "spacing": 5.0}],
    )
    results = _results_by_local_id(response)
    assert results["p1"]["ok"] is False
