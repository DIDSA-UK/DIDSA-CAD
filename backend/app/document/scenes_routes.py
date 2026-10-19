"""Scenes' HTTP routes (`docs/scenes-scope.md` section 5): GET / POST `/parts/{id}/scenes`, GET / PATCH / DELETE
`/parts/{id}/scenes/{scene_id}`, their validation (section 4), the unresolved-path report (D8) and the delete cascade.

Composition (what a shown scene looks like) is a client job in v1; its reference is `app.document.scene_compose`. Split out of
`router.py` like `appearance_routes.py`; `router.py` includes `scenes_router`."""

from __future__ import annotations

import math
import uuid
from dataclasses import replace

from fastapi import APIRouter, HTTPException, Response

from app.document.appearance_routes import appearance_or_422, current_face_index, face_ref_or_422
from app.document.extrude import compute_part_bodies
from app.document.models import Document, Part, RigidTransform, Scene, SceneOverride, SceneViewpoint, SubShapeRef
from app.document.occurrence_paths import path_goes_through, path_uses_pattern, resolve_path
from app.document.schemas import (
    RigidTransformResponse,
    SceneCreate,
    SceneOverrideSchema,
    SceneResponse,
    SceneUnresolved,
    SceneUpdate,
    SceneViewpointSchema,
    SubShapeRefSchema,
)
from app.document.store import get_document, get_part_or_404

scenes_router = APIRouter()


# --- validation ---------------------------------------------------------------------------------------------------


def _overrides_or_422(document: Document, part: Part, payload: list[SceneOverrideSchema], previous: list[SceneOverride]) -> list[SceneOverride]:
    """Section 4's checks: each path resolves from this Part (`#pattern:` copies allowed), no (path, body, face) twice, a transform
    passes the occurrence transform check, an appearance passes the Appearance tool's, a transform or `hidden` is never on a body or
    face nor on the Part's own bodies (path ""), a body exists on the Part the path names, a face is a face of that body."""
    out: list[SceneOverride] = []
    seen: set[tuple] = set()
    bodies_cache: dict[str, dict] = {}
    for position, o in enumerate(payload):
        where = f"overrides[{position}]"
        if o.transform is None and o.hidden is None and o.appearance is None:
            raise HTTPException(status_code=422, detail=f"{where}: an override must set a transform, hidden or an appearance")
        subshape = o.body_id is not None or o.face is not None
        if subshape and (o.transform is not None or o.hidden is not None):
            raise HTTPException(status_code=422, detail=f"{where}: a body or face takes an appearance only (it never moves or hides on its own)")
        if o.path == "" and (o.transform is not None or o.hidden is not None):
            raise HTTPException(status_code=422, detail=f"{where}: the Part's own bodies (path \"\") take an appearance only")
        key = (o.path, o.body_id or (o.face.body_id if o.face else None), o.face.index if o.face else None)
        if key in seen:
            raise HTTPException(status_code=422, detail=f"{where}: the scene names {key} twice")
        seen.add(key)
        resolution = resolve_path(document, part, o.path) if o.path else None
        if resolution is not None and resolution.error is not None:
            raise HTTPException(status_code=422, detail={"type": resolution.error, "path": o.path, "where": where})
        transform = None
        if o.transform is not None:
            axis = o.transform.rotation_axis
            if o.transform.rotation_angle_degrees != 0.0 and math.isclose(sum(v * v for v in axis), 0.0, abs_tol=1e-18):
                raise HTTPException(status_code=422, detail=f"{where}: rotation_axis must not be the zero vector when rotation_angle_degrees is non-zero")
            transform = RigidTransform(
                translation=tuple(o.transform.translation),
                rotation_axis=tuple(o.transform.rotation_axis),
                rotation_angle_degrees=o.transform.rotation_angle_degrees,
            )
        appearance = appearance_or_422(o.appearance, where=f"{where}.appearance") if o.appearance is not None else None
        body_id = o.body_id
        face: SubShapeRef | None = None
        if subshape:
            target = part if o.path == "" else resolution.part
            if target is None:
                raise HTTPException(status_code=422, detail={"type": "part_not_resolved", "path": o.path, "where": where})
            if target.id not in bodies_cache:
                bodies_cache[target.id] = compute_part_bodies(target)
            bodies = bodies_cache[target.id]
            body_id = body_id if body_id is not None else o.face.body_id
            if body_id not in bodies:
                raise HTTPException(status_code=422, detail={"type": "body_not_found", "body_id": body_id, "where": where})
            if o.face is not None:
                kept = next((p.face for p in previous if p.face is not None and (p.path, p.face.body_id, p.face.index) == (o.path, o.face.body_id, o.face.index)), None)
                face = kept if kept is not None else face_ref_or_422(bodies, o.face, o.body_id)
        out.append(SceneOverride(path=o.path, transform=transform, hidden=o.hidden, appearance=appearance, body_id=body_id, face=face))
    return out


def _viewpoint_or_422(v: SceneViewpointSchema | None) -> SceneViewpoint | None:
    if v is None:
        return None
    if math.dist(v.eye, v.target) < 1e-9:
        raise HTTPException(status_code=422, detail="viewpoint: eye must differ from target")
    if math.isclose(sum(c * c for c in v.up), 0.0, abs_tol=1e-18):
        raise HTTPException(status_code=422, detail="viewpoint: up must not be the zero vector")
    return SceneViewpoint(eye=tuple(v.eye), target=tuple(v.target), up=tuple(v.up))


def _name_or_422(name: str) -> str:
    stripped = name.strip()
    if not stripped:
        raise HTTPException(status_code=422, detail="name must not be empty")
    return stripped


# --- responses (with the unresolved report) -------------------------------------------------------------------------


def _unresolved(document: Document, part: Part, scene: Scene) -> list[SceneUnresolved]:
    """D8: overrides kept but not matching the assembly as it is now (an edited sub-assembly file, a pattern now shorter)."""
    out: list[SceneUnresolved] = []
    bodies_cache: dict[str, dict] = {}
    for o in scene.overrides:
        reason = None
        target: Part | None = part
        if o.path:
            resolution = resolve_path(document, part, o.path)
            reason = resolution.error
            target = resolution.part
        if reason is None and (o.body_id is not None or o.face is not None):
            if target is None:
                reason = "part_not_resolved"
            else:
                if target.id not in bodies_cache:
                    bodies_cache[target.id] = compute_part_bodies(target)
                bodies = bodies_cache[target.id]
                if o.body_id not in bodies:
                    reason = "body_not_found"
                elif o.face is not None:
                    _index, reason = current_face_index(bodies, o.face)
        if reason is not None:
            out.append(SceneUnresolved(path=o.path, body_id=o.body_id, reason=reason))
    return out


def _override_schema(o: SceneOverride) -> SceneOverrideSchema:
    return SceneOverrideSchema(
        path=o.path,
        body_id=o.body_id,
        face=SubShapeRefSchema(body_id=o.face.body_id, shape_type=o.face.shape_type, index=o.face.index) if o.face else None,
        transform=RigidTransformResponse(
            translation=o.transform.translation, rotation_axis=o.transform.rotation_axis, rotation_angle_degrees=o.transform.rotation_angle_degrees
        ) if o.transform else None,
        hidden=o.hidden,
        appearance=o.appearance.to_dict() if o.appearance else None,
    )


def scene_response(document: Document, part: Part, scene: Scene) -> SceneResponse:
    return SceneResponse(
        id=scene.id,
        name=scene.name,
        overrides=[_override_schema(o) for o in scene.overrides],
        section_planes=list(scene.section_planes),
        viewpoint=SceneViewpointSchema(eye=scene.viewpoint.eye, target=scene.viewpoint.target, up=scene.viewpoint.up) if scene.viewpoint else None,
        unresolved=_unresolved(document, part, scene),
    )


def _scene_or_404(part: Part, scene_id: str) -> Scene:
    for scene in part.scenes:
        if scene.id == scene_id:
            return scene
    raise HTTPException(status_code=404, detail="Scene not found")


# --- routes -------------------------------------------------------------------------------------------------------


@scenes_router.get("/parts/{part_id}/scenes", response_model=list[SceneResponse])
def list_scenes(part_id: str) -> list[SceneResponse]:
    """This Part's scenes (D6: a scene lives only in its own assembly), each with the overrides it can't place now (D8)."""
    part = get_part_or_404(part_id)
    document = get_document()
    return [scene_response(document, part, scene) for scene in part.scenes]


@scenes_router.get("/parts/{part_id}/scenes/{scene_id}", response_model=SceneResponse)
def get_scene(part_id: str, scene_id: str) -> SceneResponse:
    part = get_part_or_404(part_id)
    return scene_response(get_document(), part, _scene_or_404(part, scene_id))


@scenes_router.post("/parts/{part_id}/scenes", response_model=SceneResponse, status_code=201)
def create_scene(part_id: str, payload: SceneCreate) -> SceneResponse:
    """Save as scene / Save as new: the server mints the id."""
    document = get_document()
    part = get_part_or_404(part_id)
    scene = Scene(
        id=str(uuid.uuid4()),
        name=_name_or_422(payload.name),
        overrides=_overrides_or_422(document, part, payload.overrides, []),
        section_planes=[dict(p) for p in payload.section_planes],
        viewpoint=_viewpoint_or_422(payload.viewpoint),
    )
    part.scenes.append(scene)
    return scene_response(document, part, scene)


@scenes_router.patch("/parts/{part_id}/scenes/{scene_id}", response_model=SceneResponse)
def update_scene(part_id: str, scene_id: str, payload: SceneUpdate) -> SceneResponse:
    """Update scene / rename: each given field replaces that part of the scene whole (see `SceneUpdate`)."""
    document = get_document()
    part = get_part_or_404(part_id)
    scene = _scene_or_404(part, scene_id)
    fields = payload.model_fields_set
    name = _name_or_422(payload.name) if payload.name is not None else scene.name
    overrides = _overrides_or_422(document, part, payload.overrides, scene.overrides) if payload.overrides is not None else scene.overrides
    section_planes = [dict(p) for p in payload.section_planes] if payload.section_planes is not None else scene.section_planes
    viewpoint = _viewpoint_or_422(payload.viewpoint) if "viewpoint" in fields else scene.viewpoint
    updated = replace(scene, name=name, overrides=overrides, section_planes=section_planes, viewpoint=viewpoint)
    part.scenes[part.scenes.index(scene)] = updated
    return scene_response(document, part, updated)


@scenes_router.delete("/parts/{part_id}/scenes/{scene_id}", status_code=204)
def delete_scene(part_id: str, scene_id: str) -> Response:
    part = get_part_or_404(part_id)
    part.scenes.remove(_scene_or_404(part, scene_id))
    return Response(status_code=204)


# --- the delete cascade (D8) ----------------------------------------------------------------------------------------


def drop_scene_overrides_through_occurrence(document: Document, owner: Part, occurrence_id: str) -> None:
    """Delete of an occurrence: every scene override (any Part's scenes) whose path goes through it is dropped. A scene left
    with no overrides is kept until deleted."""
    for part in document.parts.values():
        for i, scene in enumerate(part.scenes):
            kept = [o for o in scene.overrides if not path_goes_through(document, part, o.path, owner.id, occurrence_id)]
            if len(kept) != len(scene.overrides):
                part.scenes[i] = replace(scene, overrides=kept)


def drop_scene_overrides_of_pattern(document: Document, owner: Part, pattern_id: str) -> None:
    """Delete of a component pattern: its copies' scene overrides go."""
    for part in document.parts.values():
        for i, scene in enumerate(part.scenes):
            kept = [o for o in scene.overrides if not path_uses_pattern(document, part, o.path, owner.id, pattern_id)]
            if len(kept) != len(scene.overrides):
                part.scenes[i] = replace(scene, overrides=kept)
