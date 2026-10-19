"""The Appearance tool's HTTP routes (`docs/appearance-tool-scope.md` section 6): an assembly's appearance overrides
(PUT / GET `/parts/{id}/appearance-overrides`), the checks a Part's own appearance passes (PATCH `/parts/{id}`), the
resolution model `assembly-mesh.glb` paints its materials from, and the delete cascade.

Split out of `app/document/router.py` like `gears_routes.py`: import `app.document.router` (which includes
`appearance_router` once its own helpers exist), not this module directly."""

from __future__ import annotations

from dataclasses import replace

from fastapi import APIRouter, HTTPException
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import topexp
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.appearance import SCOPE_PATTERN, SCOPE_SAME_PART, SCOPES, Appearance, appearance_errors, override_key
from app.document.extrude import compute_part_bodies
from app.document.models import AppearanceOverride, Document, FaceAppearance, Occurrence, Part, SubShapeRef, SubShapeType
from app.document.occurrence_paths import (
    last_segment_owner,
    parse_pattern_segment,
    path_goes_through,
    path_uses_pattern,
    placements_of,
    resolve_path,
)
from app.document.schemas import (
    AppearanceOverrideResponse,
    AppearanceOverrideSchema,
    AppearanceOverridesResponse,
    FaceAppearanceSchema,
    SubShapeRefSchema,
)
from app.document.store import get_document, get_part_or_404
from app.document.subshape_identity import decide_subshape, measure_signature

appearance_router = APIRouter()


# --- the appearance record ----------------------------------------------------------------------------------------


def appearance_or_422(data: object, where: str = "appearance") -> Appearance:
    errors = appearance_errors(data)
    if errors:
        raise HTTPException(status_code=422, detail={"type": "invalid_appearance", "where": where, "errors": errors})
    return Appearance.from_dict(data)  # type: ignore[arg-type]


# --- faces --------------------------------------------------------------------------------------------------------


def _face_count(body) -> int:
    shape_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_FACE, shape_map)
    return shape_map.Size()


def current_face_index(bodies: dict, face: SubShapeRef) -> tuple[int | None, str | None]:
    """Where `face` is now on its body: `(index, None)`, or `(None, reason)` when it can't be re-found (reported and
    kept, never moved, as `mate_health` does for a mate's face)."""
    body = bodies.get(face.body_id)
    if body is None:
        return None, "body_not_found"
    decision = decide_subshape(face, body)
    if decision.index is None:
        return None, decision.reason or "no_match"
    return decision.index, None


def face_ref_or_422(bodies: dict, schema: SubShapeRefSchema, body_id: str | None) -> SubShapeRef:
    """A new face reference from a client: a face of an existing body (the one `body_id` names, when given), with its
    signature measured now so it can be re-found after an edit."""
    if schema.shape_type != SubShapeType.FACE:
        raise HTTPException(status_code=422, detail="An appearance face must have shape_type=face")
    if body_id is not None and schema.body_id != body_id:
        raise HTTPException(status_code=422, detail="An appearance face must be a face of its body_id")
    body = bodies.get(schema.body_id)
    if body is None:
        raise HTTPException(status_code=422, detail={"type": "body_not_found", "body_id": schema.body_id})
    if not 0 <= schema.index < _face_count(body):
        raise HTTPException(
            status_code=422, detail={"type": "missing_reference", "body_id": schema.body_id, "shape_type": "face", "index": schema.index}
        )
    ref = SubShapeRef(body_id=schema.body_id, shape_type=SubShapeType.FACE, index=schema.index)
    return SubShapeRef(
        body_id=ref.body_id, shape_type=ref.shape_type, index=ref.index, signature=measure_signature(body, ref, ref.index)
    )


def _face_schema(face: SubShapeRef) -> SubShapeRefSchema:
    return SubShapeRefSchema(body_id=face.body_id, shape_type=face.shape_type, index=face.index)


# --- a Part's own appearance (PATCH /parts/{id}) ------------------------------------------------------------------


def apply_part_appearance_update(part: Part, payload) -> None:
    """`PartUpdate`'s three appearance fields (see its docstring). Body ids must name current bodies of this Part."""
    fields_set = payload.model_fields_set
    if "appearance" in fields_set:
        part.appearance = None if payload.appearance is None else appearance_or_422(payload.appearance)
    if payload.body_appearances is None and payload.face_appearances is None:
        return
    bodies = compute_part_bodies(part)
    if payload.body_appearances is not None:
        body_appearances = {}
        for body_id, data in payload.body_appearances.items():
            if body_id not in bodies:
                raise HTTPException(status_code=422, detail={"type": "body_not_found", "body_id": body_id})
            body_appearances[body_id] = appearance_or_422(data, where=f"body_appearances.{body_id}")
        part.body_appearances = body_appearances
    if payload.face_appearances is not None:
        entries: list[FaceAppearance] = []
        seen: set[tuple[str, int]] = set()
        for position, entry in enumerate(payload.face_appearances):
            key = (entry.face.body_id, entry.face.index)
            if key in seen:
                raise HTTPException(status_code=422, detail=f"face_appearances names the face {key} twice")
            seen.add(key)
            previous = next((e for e in part.face_appearances if (e.face.body_id, e.face.index) == key), None)
            # A face already stored keeps its signature (it is the same face); a new one is measured now.
            face = previous.face if previous is not None else face_ref_or_422(bodies, entry.face, None)
            entries.append(FaceAppearance(face=face, appearance=appearance_or_422(entry.appearance, where=f"face_appearances[{position}]")))
        part.face_appearances = entries


def part_appearance_fields(part: Part) -> dict:
    """The appearance fields of `PartResponse`."""
    bodies = compute_part_bodies(part) if part.face_appearances else {}
    face_appearances = []
    for entry in part.face_appearances:
        index, reason = current_face_index(bodies, entry.face)
        face_appearances.append(
            FaceAppearanceSchema(face=_face_schema(entry.face), appearance=entry.appearance.to_dict(), current_index=index, unresolved=reason)
        )
    return {
        "appearance": part.appearance.to_dict() if part.appearance is not None else None,
        "body_appearances": {body_id: a.to_dict() for body_id, a in part.body_appearances.items()},
        "face_appearances": face_appearances,
    }


# --- an assembly's overrides --------------------------------------------------------------------------------------


def _legacy_key(occurrence: Occurrence) -> tuple:
    return (occurrence.id, None, None, None, None, None)


def _domain_key(override: AppearanceOverride) -> tuple:
    return override_key(_override_model_dict(override, face_index=override.face.index if override.face else None))


def _target_part(document: Document, part: Part, override) -> tuple[Part | None, str | None]:
    """The Part an override's body / face belongs to, or why its target can't be found. Works on the schema or the
    domain record (same field names)."""
    if override.scope == SCOPE_SAME_PART:
        target = document.parts.get(override.part_id or "")
        if target is None:
            return None, "part_not_resolved"
        if placements_of(document, part, target.id) == 0:
            return None, "part_not_placed"
        return target, None
    if override.path == "":
        return part, None
    resolution = resolve_path(document, part, override.path)
    if resolution.error is not None:
        return None, resolution.error
    if override.scope == SCOPE_PATTERN:
        owner = resolution.owner
        source_id = override.path.rsplit("/", 1)[-1]
        pattern = next((p for p in owner.component_patterns if p.id == override.pattern_id), None) if owner else None
        if pattern is None or source_id not in pattern.source_occurrence_ids:
            return None, "pattern_not_found"
    return resolution.part, None


def _validate_override_shape(payload: AppearanceOverrideSchema) -> None:
    if payload.scope is not None and payload.scope not in SCOPES:
        raise HTTPException(status_code=422, detail=f"scope must be one of {', '.join(SCOPES)} (or null)")
    if payload.scope == SCOPE_SAME_PART:
        if not payload.part_id or payload.path or payload.pattern_id:
            raise HTTPException(status_code=422, detail="A same_part override needs part_id, an empty path and no pattern_id")
    elif payload.part_id is not None:
        raise HTTPException(status_code=422, detail="part_id is only used with scope same_part")
    if payload.scope == SCOPE_PATTERN:
        if not payload.pattern_id or not payload.path or parse_pattern_segment(payload.path.rsplit("/", 1)[-1]) is not None:
            raise HTTPException(
                status_code=422, detail="A pattern override needs pattern_id and a path whose last segment is the pattern's source occurrence"
            )
    elif payload.pattern_id is not None:
        raise HTTPException(status_code=422, detail="pattern_id is only used with scope pattern")


def _override_model_dict(override: AppearanceOverride, face_index: int | None) -> dict:
    """An override in the resolution model's shape (`app.document.appearance`), its face at `face_index`."""
    data: dict = {"path": override.path, "appearance": override.appearance.to_dict()}
    for key in ("scope", "pattern_id", "part_id", "body_id"):
        if getattr(override, key) is not None:
            data[key] = getattr(override, key)
    if override.face is not None:
        data["body_id"] = override.face.body_id
        data["face"] = {"body_id": override.face.body_id, "index": face_index}
    return data


def _mirror_legacy_colour(part: Part, override_path: str) -> None:
    """D2: the base colour of a top-level occurrence's own override is mirrored into `Occurrence.color`, so an older
    client still shows it."""
    occurrence = next((o for o in part.occurrences if o.id == override_path), None)
    if occurrence is None:
        return
    record = next((o for o in part.appearance_overrides if _domain_key(o) == _legacy_key(occurrence)), None)
    if record is None:
        occurrence.color = None
    elif record.appearance.colour is not None:
        occurrence.color = record.appearance.colour
    # else: an override that sets no colour keeps the legacy colour under it (`appearance.effective_overrides`).


def set_legacy_colour(part: Part, occurrence: Occurrence, colour: str | None) -> None:
    """PATCH occurrence `color` (the legacy alias): sets the field and keeps an override with the same target in step."""
    occurrence.color = colour
    for position, record in enumerate(part.appearance_overrides):
        if _domain_key(record) != _legacy_key(occurrence):
            continue
        updated = Appearance.from_dict({**record.appearance.to_dict(), "colour": colour})
        if updated.is_empty():
            del part.appearance_overrides[position]
        else:
            part.appearance_overrides[position] = replace(record, appearance=updated)
        return


def _bodies_for(part: Part, cache: dict[str, dict]) -> dict:
    if part.id not in cache:
        cache[part.id] = compute_part_bodies(part)
    return cache[part.id]


def _override_response(document: Document, part: Part, override: AppearanceOverride, cache: dict) -> AppearanceOverrideResponse:
    target, reason = _target_part(document, part, override)
    face_index = None
    if reason is None and (override.body_id or override.face):
        if target is None:
            reason = "part_not_resolved"
        else:
            bodies = _bodies_for(target, cache)
            body_id = override.body_id or override.face.body_id
            if body_id not in bodies:
                reason = "body_not_found"
            elif override.face is not None:
                face_index, reason = current_face_index(bodies, override.face)
    return AppearanceOverrideResponse(
        path=override.path,
        scope=override.scope,
        pattern_id=override.pattern_id,
        part_id=override.part_id,
        body_id=override.body_id,
        face=_face_schema(override.face) if override.face else None,
        appearance=override.appearance.to_dict(),
        unresolved=reason,
        face_current_index=face_index,
    )


def appearance_overrides_response(document: Document, part: Part) -> AppearanceOverridesResponse:
    cache: dict[str, dict] = {}
    explicit_keys = {_domain_key(o) for o in part.appearance_overrides}
    legacy = [
        AppearanceOverrideResponse(path=o.id, appearance={"colour": o.color}, legacy=True)
        for o in part.occurrences
        if o.color and _legacy_key(o) not in explicit_keys
    ]
    return AppearanceOverridesResponse(
        overrides=legacy + [_override_response(document, part, o, cache) for o in part.appearance_overrides]
    )


@appearance_router.get("/parts/{part_id}/appearance-overrides", response_model=AppearanceOverridesResponse)
def list_appearance_overrides(part_id: str) -> AppearanceOverridesResponse:
    """Every override this assembly paints, legacy `Occurrence.color`s included (`legacy: true`), each with the reason
    its target can't be found now, if any (kept but ignored, as scenes do)."""
    part = get_part_or_404(part_id)
    return appearance_overrides_response(get_document(), part)


@appearance_router.put("/parts/{part_id}/appearance-overrides", response_model=AppearanceOverridesResponse)
def put_appearance_override(part_id: str, payload: AppearanceOverrideSchema) -> AppearanceOverridesResponse:
    """Sets the override with this target (`path`, `scope`, `pattern_id`, `part_id`, `body_id`, `face`), replacing
    the one there; `appearance: null` clears it. One call is one undo step in the clients. Validation
    (`docs/appearance-tool-scope.md` section 5): the path resolves from this Part (`#pattern:` copies allowed), the body
    is a current body of the Part it names, a face is a face of that body, the scope's fields fit, the appearance's
    ranges hold. Returns the whole list."""
    document = get_document()
    part = get_part_or_404(part_id)
    _validate_override_shape(payload)
    target, reason = _target_part(document, part, payload)
    if reason is not None:
        raise HTTPException(status_code=422, detail={"type": reason, "path": payload.path})
    face: SubShapeRef | None = None
    if payload.body_id is not None or payload.face is not None:
        if target is None:
            raise HTTPException(status_code=422, detail={"type": "part_not_resolved", "path": payload.path})
        bodies = compute_part_bodies(target)
        body_id = payload.body_id if payload.body_id is not None else payload.face.body_id
        if body_id not in bodies:
            raise HTTPException(status_code=422, detail={"type": "body_not_found", "body_id": body_id})
        if payload.face is not None:
            stored = next(
                (
                    o.face
                    for o in part.appearance_overrides
                    if o.face is not None
                    and (o.path, o.scope, o.pattern_id, o.part_id, o.face.body_id, o.face.index)
                    == (payload.path, payload.scope, payload.pattern_id, payload.part_id, payload.face.body_id, payload.face.index)
                ),
                None,
            )
            face = stored if stored is not None else face_ref_or_422(bodies, payload.face, payload.body_id)
        payload_body_id = body_id
    else:
        payload_body_id = None
    record = AppearanceOverride(
        appearance=Appearance(),
        path=payload.path,
        body_id=payload_body_id,
        face=face,
        scope=payload.scope,
        pattern_id=payload.pattern_id,
        part_id=payload.part_id,
    )
    key = _domain_key(record)
    position = next((i for i, o in enumerate(part.appearance_overrides) if _domain_key(o) == key), None)
    if payload.appearance is None:
        if position is not None:
            del part.appearance_overrides[position]
    else:
        record = replace(record, appearance=appearance_or_422(payload.appearance))
        if position is None:
            part.appearance_overrides.append(record)
        else:
            part.appearance_overrides[position] = record
    if payload.scope is None and payload.body_id is None and payload.face is None and payload.path and "/" not in payload.path and "#" not in payload.path:
        _mirror_legacy_colour(part, payload.path)
    return appearance_overrides_response(document, part)


# --- the delete cascade -------------------------------------------------------------------------------------------


def drop_overrides_through_occurrence(document: Document, owner: Part, occurrence_id: str) -> None:
    """Delete of an occurrence: every override (in any Part of the session) whose path goes through it is dropped, the
    Mate cascade's rule (scenes D8). A `same_part` override names a Part, not a placement, and stays."""
    for part in document.parts.values():
        part.appearance_overrides = [
            o for o in part.appearance_overrides if o.scope == SCOPE_SAME_PART or not path_goes_through(document, part, o.path, owner.id, occurrence_id)
        ]


def drop_overrides_of_pattern(document: Document, owner: Part, pattern_id: str) -> None:
    """Delete of a component pattern: its copies' overrides and its `scope: "pattern"` overrides are dropped."""
    for part in document.parts.values():
        kept = []
        for o in part.appearance_overrides:
            if o.scope != SCOPE_SAME_PART and path_uses_pattern(document, part, o.path, owner.id, pattern_id):
                continue
            if o.scope == SCOPE_PATTERN and o.pattern_id == pattern_id:
                pattern_owner = last_segment_owner(document, part, o.path)
                if pattern_owner is not None and pattern_owner.id == owner.id:
                    continue
            kept.append(o)
        part.appearance_overrides = kept


# --- the resolution model `assembly-mesh.glb` paints from ---------------------------------------------------------


def resolution_model(document: Document) -> dict:
    """Every loaded Part in `app.document.appearance`'s resolution-model shape, faces at their current index (a face
    that can't be re-found, or whose target is gone, is left out: it paints nothing until it resolves again)."""
    cache: dict[str, dict] = {}
    parts: dict[str, dict] = {}
    for part in document.parts.values():
        entry: dict = {
            "occurrences": {
                o.id: {"part_id": o.part_id, "color": o.color} for o in part.occurrences if not o.suppressed and o.part_id is not None
            }
        }
        if part.appearance is not None:
            entry["appearance"] = part.appearance.to_dict()
        if part.body_appearances:
            entry["body_appearances"] = {body_id: a.to_dict() for body_id, a in part.body_appearances.items()}
        faces = []
        for face_entry in part.face_appearances:
            index, _reason = current_face_index(_bodies_for(part, cache), face_entry.face)
            if index is not None:
                faces.append({"face": {"body_id": face_entry.face.body_id, "index": index}, "appearance": face_entry.appearance.to_dict()})
        if faces:
            entry["face_appearances"] = faces
        overrides = []
        for override in part.appearance_overrides:
            face_index = None
            if override.face is not None:
                target, reason = _target_part(document, part, override)
                if target is None:
                    continue
                face_index, reason = current_face_index(_bodies_for(target, cache), override.face)
                if face_index is None:
                    continue
            overrides.append(_override_model_dict(override, face_index))
        if overrides:
            entry["appearance_overrides"] = overrides
        parts[part.id] = entry
    return {"parts": parts}
