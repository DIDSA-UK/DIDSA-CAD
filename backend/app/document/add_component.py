"""Backend port of the Flutter client's own `client/lib/assembly/
add_component.dart::mergeComponentIntoDocument` - see that file's own
docstring for the full "why does this exist, why not go through
AssemblyGraphComposer" rationale, which applies identically here: the VR
client (`DIDSA-UK/DIDSA-VR`, this backend's other real consumer) has no
`StorageService`/`ProjectRoot` of its own either, and - unlike the Flutter
client - can't run this Dart code to do the merge itself. Porting the pure
dict-transform lets the *backend* do it once, so both clients get an
"add a component to the live session" path without either duplicating the
logic (or the VR client waiting on the much larger, still-unscoped
server-side multi-file-storage question - see `docs/assembly-scope.md`'s
"Other open items" - to get real Occurrences to test Mates against at
all).

This only ever merges an already-fetched component payload the caller
handed it - never resolves a path or reads a filesystem itself
(`docs/assembly-scope.md` decision #6 unchanged: the caller, whichever
client it is, is responsible for getting the component's own
`export_native`-shaped payload, e.g. by reading a local file)."""

from __future__ import annotations


class AddComponentError(ValueError):
    """Raised for anything that stops `merge_component_into_document` from
    producing a usable merged payload - never a partial/corrupt result.
    Mirrors `add_component.dart`'s own `AddComponentException`."""


def merge_component_into_document(
    *,
    current_payload: dict,
    component_payload: dict,
    root_part_id: str,
    occurrence_id: str,
    external_ref: str | None = None,
    name_override: str | None = None,
) -> dict:
    """Merges `component_payload` (another native file's own exported JSON -
    the same shape `GET /document/export/native` returns, `part_id` given or
    not) into `current_payload` (this session's own full snapshot, `GET
    /document/export/native` with no `part_id`), adding one new Occurrence
    naming `occurrence_id` onto whichever Part in `current_payload` has id
    `root_part_id`.

    A direct, field-for-field port of `add_component.dart`'s
    `mergeComponentIntoDocument` - same dedup-by-persisted-Part-id
    behaviour, same "first Occurrence gets `fixed=True`" grounding rule, same
    sketch-merge bug fix - kept in matching shape so the two clients' actual
    behaviour never quietly diverges. See that file's own docstring for the
    full rationale behind each of these.

    Raises `AddComponentError` for a `schema_version` mismatch, a file with
    no Parts at all, a self-reference (the component's own root Part id
    already equals `root_part_id`), or `root_part_id` not actually being
    present in `current_payload`."""
    current_schema = current_payload.get("schema_version")
    component_schema = component_payload.get("schema_version")
    if component_schema is None or component_schema != current_schema:
        raise AddComponentError("Unsupported or mismatched native file version")

    component_document = component_payload.get("document")
    if not isinstance(component_document, dict):
        raise AddComponentError("Not a valid native project file")
    component_parts = component_document.get("parts")
    if not isinstance(component_parts, list) or not component_parts:
        raise AddComponentError("File contains no Parts")
    component_root_part_id = component_document.get("root_part_id") or component_parts[0]["id"]

    if component_root_part_id == root_part_id:
        raise AddComponentError("Cannot insert a Part into itself")

    current_document = current_payload.get("document")
    if not isinstance(current_document, dict):
        raise AddComponentError("Current session has no document to add to")
    current_parts: list[dict] = current_document.get("parts") or []
    if not any(part.get("id") == root_part_id for part in current_parts):
        raise AddComponentError("Current Part is missing from its own session snapshot")
    current_part_ids = {part["id"] for part in current_parts}

    merged_parts = list(current_parts) + [part for part in component_parts if part["id"] not in current_part_ids]

    # Bug fix ported from `add_component.dart` (same reasoning applies here):
    # `sketches` lives alongside `document`, not inside it - dropping the
    # component's own sketches leaves any SketchFeature on the newly-merged
    # Part pointing at a sketch id this session's store never received, so
    # the new Occurrence would show up in the tree but never render.
    current_sketches: list[dict] = current_payload.get("sketches") or []
    component_sketches: list[dict] = component_payload.get("sketches") or []
    current_sketch_ids = {sketch["id"] for sketch in current_sketches}
    merged_sketches = list(current_sketches) + [
        sketch for sketch in component_sketches if sketch["id"] not in current_sketch_ids
    ]

    # A Mate-driven placement is only ever meaningful relative to at least
    # one fixed reference - ported from `add_component.dart`'s own
    # "first component added is grounded by convention" rule.
    current_root_part = next(part for part in current_parts if part["id"] == root_part_id)
    existing_occurrences = current_root_part.get("occurrences") or []
    is_first_occurrence = len(existing_occurrences) == 0

    new_occurrence = {
        "id": occurrence_id,
        "external_ref": external_ref,
        "resolved_part_id": component_root_part_id,
        "name_override": name_override,
        "transform": None,
        "suppressed": False,
        "hidden": False,
        "fixed": is_first_occurrence,
    }

    updated_parts = [
        {**part, "occurrences": [*(part.get("occurrences") or []), new_occurrence]}
        if part["id"] == root_part_id
        else part
        for part in merged_parts
    ]

    return {
        **current_payload,
        "document": {**current_document, "parts": updated_parts},
        "sketches": merged_sketches,
    }
