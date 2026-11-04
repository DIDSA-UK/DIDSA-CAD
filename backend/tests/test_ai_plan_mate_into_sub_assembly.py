"""A mate reference into a placed sub-assembly (AI Modelling, an imported zip with sub-assemblies): the dry run accepts
`existing:<outer>/<inner>`, the `/`-joined path a real Mate into a sub-assembly is stored with, and resolves a
face_selector against the innermost component's own geometry."""
from tests.test_ai_plan_assembly_steps import (
    _add_box_body,
    _create_part,
    _export_part,
    _face_ref,
    _import_composed,
    _occurrence_dict,
    _results_by_local_id,
    _validate,
)


def _setup_top_with_a_sub_assembly() -> tuple[str, str]:
    """Top places `sub` (the sub-assembly Part, no Bodies of its own), which places `inner` (a 10x10x15 box Part).
    Returns `(top_part_id, inner_body_id)`."""
    top = _create_part("Top")
    sub = _create_part("Castor")
    wheel = _create_part("Wheel")
    wheel_body_id = _add_box_body(wheel["id"], size=10.0, depth=15.0)
    top_export = _export_part(top["id"])
    top_part = top_export["document"]["parts"][0]
    top_part["occurrences"] = [_occurrence_dict("sub", sub["id"], "CASTOR_001.didsa")]
    top_part["mates"] = []
    sub_part = _export_part(sub["id"])["document"]["parts"][0]
    sub_part["occurrences"] = [_occurrence_dict("inner", wheel["id"], "WHEEL_001.didsa")]
    sub_part["mates"] = []
    wheel_export = _export_part(wheel["id"])
    _import_composed(
        {
            "schema_version": top_export["schema_version"],
            "document": {
                "id": "composed-doc",
                "root_part_id": top["id"],
                "parts": [top_part, sub_part, wheel_export["document"]["parts"][0]],
            },
            "sketches": top_export["sketches"] + wheel_export["sketches"],
        }
    )
    return top["id"], wheel_body_id


def _mate_on(occurrence_id: str) -> dict:
    return {
        "local_id": "mate1",
        "kind": "mate",
        "type": "coincident",
        "references": [{"occurrence_id": occurrence_id, "face_selector": {"direction": "+z"}}, _face_ref("")],
    }


def test_a_path_into_a_sub_assembly_resolves_the_face_on_the_inner_component():
    top_id, wheel_body_id = _setup_top_with_a_sub_assembly()
    result = _results_by_local_id(_validate(top_id, [_mate_on("existing:sub/inner")]))["mate1"]
    assert result["ok"] is True, result
    assert result["resolved_mate_references"][0]["body_id"] == wheel_body_id


def test_a_path_through_an_unknown_inner_id_is_an_unknown_existing_id():
    top_id, _ = _setup_top_with_a_sub_assembly()
    result = _results_by_local_id(_validate(top_id, [_mate_on("existing:sub/nope")]))["mate1"]
    assert result["ok"] is False
    assert result["error"]["type"] == "unknown_existing_id"


def test_a_path_must_start_with_existing():
    top_id, _ = _setup_top_with_a_sub_assembly()
    result = _results_by_local_id(_validate(top_id, [_mate_on("sub/inner")]))["mate1"]
    assert result["ok"] is False
    assert "existing:" in result["error"]["message"]


def test_the_sub_assembly_itself_has_no_face_to_select():
    top_id, _ = _setup_top_with_a_sub_assembly()
    result = _results_by_local_id(_validate(top_id, [_mate_on("existing:sub")]))["mate1"]
    assert result["ok"] is False
    assert "0 Bodies" in result["error"]["message"]
