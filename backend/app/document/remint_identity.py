"""Backend twin of the Flutter client's `client/lib/assembly/
remint_identity.dart` - keep the two in matching shape.

Why this exists (bug report 2026-10-14, item 3): a native file's `document.id`,
Part ids and sketch ids are minted once, when the Part is first created, and
then trusted verbatim on every later import (`native_format.py`'s
`_part_from_dict`/`sketch_from_dict`). Both the in-memory Document (parts keyed
by id) and the sketch store (keyed by id) are *session-global*, so two
different files that happen to carry the same ids (the usual cause is "Save
As" copying a Part byte-for-byte and the copy then being edited) silently
overwrite one another the moment they share a session: the merge paths dedup
by id on the assumption that the same id means the same file.

`remint_native_identity` is the fix for both halves of that: Save As runs it so
copies never share ids to begin with, and the merge paths run it on an
incoming payload whose ids already exist in the session with different
content (files already on disk, written before Save As re-minted).
"""

from __future__ import annotations

import uuid


def collect_native_identity_ids(payload: dict) -> set[str]:
    """Every session-global id in `payload`: `document.id`, each Part id and
    each sketch id. Feature, entity and point ids are deliberately absent -
    they are scoped to their Part or sketch (routes are `/parts/{part_id}/
    features/{feature_id}`, the body cache is keyed by Part id), so a copy
    keeping them cannot collide with anything."""
    ids: set[str] = set()
    document = payload.get("document")
    if isinstance(document, dict):
        document_id = document.get("id")
        if isinstance(document_id, str):
            ids.add(document_id)
        for part in document.get("parts") or []:
            part_id = part.get("id") if isinstance(part, dict) else None
            if isinstance(part_id, str):
                ids.add(part_id)
    for sketch in payload.get("sketches") or []:
        sketch_id = sketch.get("id") if isinstance(sketch, dict) else None
        if isinstance(sketch_id, str):
            ids.add(sketch_id)
    return ids


def remint_native_identity(payload: dict, only_ids: set[str] | None = None) -> dict:
    """Returns a deep copy of `payload` where `document.id`, every Part id and
    every sketch id (restricted to `only_ids` when given) is replaced by a
    fresh UUID v4, and every *reference* to one of them follows.

    References are found by walking the whole JSON tree and replacing every
    string **value** exactly equal to an old id, rather than by listing the
    reference sites (`SketchFeature.sketch_id`, `profile_refs[].sketch_id`,
    `root_part_id`, an Occurrence's `resolved_part_id`, anything added later):
    UUIDs are unique strings, so an exact match is never a false positive.
    Dict **keys** are left alone - the only id-keyed maps in the format are
    keyed by Part-scoped feature ids, which this does not touch."""
    candidates = collect_native_identity_ids(payload)
    if only_ids is not None:
        candidates &= set(only_ids)
    mapping = {old: str(uuid.uuid4()) for old in candidates}
    return _replace(payload, mapping)


def _replace(node, mapping: dict[str, str]):
    if isinstance(node, str):
        return mapping.get(node, node)
    if isinstance(node, list):
        return [_replace(item, mapping) for item in node]
    if isinstance(node, dict):
        return {key: _replace(value, mapping) for key, value in node.items()}
    return node
