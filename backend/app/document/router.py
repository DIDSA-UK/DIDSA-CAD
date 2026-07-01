import uuid

from fastapi import APIRouter, HTTPException, Query
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

from app.document.extrude import compute_part_solid
from app.document.mesh import DEFAULT_MESH_QUALITY, MeshData, tessellate_shape
from app.document.models import ExtrudeFeature, Feature, Part, SketchFeature
from app.document.schemas import (
    CascadeDeleteResponse,
    ExtrudeFeatureCreate,
    ExtrudeFeatureResponse,
    ExtrudeFeatureUpdate,
    FeatureResponse,
    MeshVertexData,
    PartCreate,
    PartMeshResponse,
    PartResponse,
    SketchFeatureCreate,
    SketchFeatureResponse,
)
from app.document.store import get_document, get_part_or_404
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.store import create_sketch, delete_sketch, get_sketch_or_404

router = APIRouter(prefix="/document", tags=["document"])


def _get_feature_or_404(part: Part, feature_id: str) -> Feature:
    feature = part.get_feature(feature_id)
    if feature is None:
        raise HTTPException(status_code=404, detail="Feature not found")
    return feature


def _part_response(part: Part) -> PartResponse:
    return PartResponse(id=part.id, name=part.name, feature_ids=[f.id for f in part.features])


def _feature_response(part: Part, feature: Feature) -> FeatureResponse:
    if isinstance(feature, SketchFeature):
        return SketchFeatureResponse(
            id=feature.id,
            sketch_id=feature.sketch_id,
            locked=part.is_locked(feature.id),
        )
    if isinstance(feature, ExtrudeFeature):
        return ExtrudeFeatureResponse(
            id=feature.id,
            sketch_feature_id=feature.sketch_feature_id,
            extrude_type=feature.extrude_type,
            start_distance=feature.start_distance,
            end_distance=feature.end_distance,
            locked=part.is_locked(feature.id),
        )
    raise NotImplementedError(f"No response mapping for feature type: {feature.type}")


def _mesh_vertex_data(mesh_data: MeshData) -> MeshVertexData:
    return MeshVertexData(
        vertices=mesh_data.vertices,
        normals=mesh_data.normals,
        triangle_indices=[(t.a, t.b, t.c) for t in mesh_data.triangles],
        edges=mesh_data.edges,
        face_ids=mesh_data.face_ids,
        edge_ids=mesh_data.edge_ids,
        topology_vertices=mesh_data.topology_vertices,
        topology_vertex_ids=mesh_data.topology_vertex_ids,
    )


def _validate_extrude_distances(start_distance: float, end_distance: float) -> None:
    """The only validation Stage 10a requires for start_distance/end_distance:
    the extrude must span a positive distance (end_distance > start_distance),
    since both are now signed offsets along the plane normal and the solid
    spans literally from one to the other (see app.document.extrude)."""
    if end_distance <= start_distance:
        raise HTTPException(
            status_code=400,
            detail="end_distance must be greater than start_distance",
        )


def _require_closed_sketch_feature(part: Part, sketch_feature_id: str) -> SketchFeature:
    """Validates that `sketch_feature_id` resolves to a SketchFeature in
    `part` whose Sketch has an extrudable Profile - a single 400 for every
    way this can fail, per the brief ("Validate ... return a clear 400
    error if not"). CLOSED_LOOP (a single nested profile, C1) and
    MULTIPLE_LOOPS (a MultiProfile of disjoint outer profiles, C2) are both
    extrudable - see app.document.extrude._solid_for_extrude_feature, which
    this must stay in sync with."""
    feature = part.get_feature(sketch_feature_id)
    if not isinstance(feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="sketch_feature_id does not refer to a SketchFeature in this Part",
        )
    sketch = get_sketch_or_404(feature.sketch_id)
    result = detect_profile(sketch)
    if result.status not in (ProfileStatus.CLOSED_LOOP, ProfileStatus.MULTIPLE_LOOPS):
        raise HTTPException(
            status_code=400,
            detail=f"Sketch does not contain a closed profile (status: {result.status.value})",
        )
    return feature


@router.post("/parts", response_model=PartResponse, status_code=201)
def create_part(payload: PartCreate) -> PartResponse:
    part = get_document().add_part(payload.name)
    return _part_response(part)


@router.get("/parts/{part_id}", response_model=PartResponse)
def get_part(part_id: str) -> PartResponse:
    return _part_response(get_part_or_404(part_id))


@router.get("/parts/{part_id}/features", response_model=list[FeatureResponse])
def list_features(part_id: str) -> list[FeatureResponse]:
    part = get_part_or_404(part_id)
    return [_feature_response(part, feature) for feature in part.features]


@router.get("/parts/{part_id}/features/{feature_id}", response_model=FeatureResponse)
def get_feature(part_id: str, feature_id: str) -> FeatureResponse:
    part = get_part_or_404(part_id)
    return _feature_response(part, _get_feature_or_404(part, feature_id))


@router.post(
    "/parts/{part_id}/features/sketch", response_model=SketchFeatureResponse, status_code=201
)
def create_sketch_feature(part_id: str, payload: SketchFeatureCreate) -> SketchFeatureResponse:
    part = get_part_or_404(part_id)
    sketch = create_sketch(payload.plane)
    feature = SketchFeature(id=str(uuid.uuid4()), sketch_id=sketch.id)
    part.add_feature(feature)
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/extrude-features", response_model=ExtrudeFeatureResponse, status_code=201
)
def create_extrude_feature(part_id: str, payload: ExtrudeFeatureCreate) -> ExtrudeFeatureResponse:
    part = get_part_or_404(part_id)
    _require_closed_sketch_feature(part, payload.sketch_feature_id)
    _validate_extrude_distances(payload.start_distance, payload.end_distance)
    feature = ExtrudeFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        extrude_type=payload.extrude_type,
        start_distance=payload.start_distance,
        end_distance=payload.end_distance,
    )
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_extrude_feature_or_404(part: Part, feature_id: str) -> ExtrudeFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, ExtrudeFeature):
        raise HTTPException(status_code=404, detail="Extrude feature not found")
    return feature


@router.patch("/parts/{part_id}/extrude-features/{feature_id}", response_model=ExtrudeFeatureResponse)
def update_extrude_feature(
    part_id: str, feature_id: str, payload: ExtrudeFeatureUpdate
) -> ExtrudeFeatureResponse:
    part = get_part_or_404(part_id)
    feature = _get_extrude_feature_or_404(part, feature_id)
    if part.is_locked(feature_id):
        raise HTTPException(
            status_code=400,
            detail="Only the last Feature in a Part can be edited - it is locked because a "
            "later Feature exists.",
        )
    new_start = payload.start_distance if payload.start_distance is not None else feature.start_distance
    new_end = payload.end_distance if payload.end_distance is not None else feature.end_distance
    _validate_extrude_distances(new_start, new_end)

    if payload.extrude_type is not None:
        feature.extrude_type = payload.extrude_type
    feature.start_distance = new_start
    feature.end_distance = new_end
    return _feature_response(part, feature)


@router.delete("/parts/{part_id}/features/{feature_id}", status_code=204)
def delete_feature(part_id: str, feature_id: str) -> None:
    part = get_part_or_404(part_id)
    _get_feature_or_404(part, feature_id)
    if part.is_locked(feature_id):
        raise HTTPException(
            status_code=400,
            detail="Only the last Feature in a Part can be deleted - it is locked because a "
            "later Feature exists. Delete the later Feature(s) first.",
        )
    part.delete_feature(feature_id)


@router.delete(
    "/parts/{part_id}/features/{feature_id}/cascade", response_model=CascadeDeleteResponse
)
def delete_feature_cascade(part_id: str, feature_id: str) -> CascadeDeleteResponse:
    """Deletes `feature_id` and every Feature after it, regardless of
    locking - this is the only way to remove a locked Feature, since
    removing it always also removes everything later that depends on it
    being in the history. Distinct from `delete_feature` above (which
    only ever removes a single, unlocked, last Feature) precisely so a
    client can't trigger a multi-Feature deletion by accident through the
    single-delete endpoint.

    Each deleted SketchFeature's underlying Sketch is deleted too, since
    a Sketch created via this Document/Part/Feature flow is owned solely
    by the SketchFeature that wraps it - nothing else references it, so
    nothing else needs it once that SketchFeature is gone. (Sketches
    created directly via the standalone /sketch API, bypassing a Part
    entirely, are never touched here - the only Sketches this loop ever
    sees are the ones already attached to a Feature this Part is deleting.)
    """
    part = get_part_or_404(part_id)
    _get_feature_or_404(part, feature_id)
    deleted_features = part.delete_feature_cascade(feature_id)

    deleted_sketch_ids = []
    for feature in deleted_features:
        if isinstance(feature, SketchFeature):
            delete_sketch(feature.sketch_id)
            deleted_sketch_ids.append(feature.sketch_id)

    return CascadeDeleteResponse(
        deleted_feature_ids=[f.id for f in deleted_features],
        deleted_sketch_ids=deleted_sketch_ids,
    )


@router.get("/parts/{part_id}/mesh", response_model=PartMeshResponse)
def get_part_mesh(
    part_id: str, hidden_feature_ids: list[str] = Query(default=[])
) -> PartMeshResponse:
    """Placeholder mesh (a fixed box) while the Part has no ExtrudeFeature
    yet, per `Part.produces_solid_geometry`. Once it does, this instead
    accumulates every non-hidden ExtrudeFeature's real OCCT solid (Boss/Cut,
    in order - see app.document.extrude.compute_part_solid) and tessellates
    that. A Part whose only ExtrudeFeature(s) all skipped (e.g. a Cut with no
    prior Boss, or every ExtrudeFeature hidden) still gets
    `source="computed"`, just with an empty mesh - it has "real" geometry in
    intent, there's just nothing to show yet.

    `hidden_feature_ids` is the client's Hide/Show state (see
    PartScreen._hiddenFeatureIds) - purely client-side, never persisted here;
    the client re-sends it on every mesh fetch so a hidden body's
    contribution to the displayed solid (and so to its bounding box, used
    for camera centering/zoom - see OrbitCamera) drops out immediately."""
    part = get_part_or_404(part_id)

    if not part.produces_solid_geometry:
        box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
        mesh_data = tessellate_shape(box, DEFAULT_MESH_QUALITY)
        return PartMeshResponse(source="placeholder", mesh=_mesh_vertex_data(mesh_data))

    solid = compute_part_solid(part, frozenset(hidden_feature_ids))
    if solid is None:
        return PartMeshResponse(
            source="computed",
            mesh=MeshVertexData(vertices=[], normals=[], triangle_indices=[], edges=[]),
        )

    mesh_data = tessellate_shape(solid, DEFAULT_MESH_QUALITY)
    return PartMeshResponse(source="computed", mesh=_mesh_vertex_data(mesh_data))
