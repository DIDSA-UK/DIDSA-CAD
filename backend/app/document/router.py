import uuid

from fastapi import APIRouter, HTTPException
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

from app.document.mesh import DEFAULT_MESH_QUALITY, tessellate_shape
from app.document.models import Feature, Part, SketchFeature
from app.document.schemas import (
    CascadeDeleteResponse,
    FeatureResponse,
    MeshVertexData,
    PartCreate,
    PartMeshResponse,
    PartResponse,
    SketchFeatureCreate,
    SketchFeatureResponse,
)
from app.document.store import get_document, get_part_or_404
from app.sketch.store import create_sketch, delete_sketch

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
    raise NotImplementedError(f"No response mapping for feature type: {feature.type}")


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
def get_part_mesh(part_id: str) -> PartMeshResponse:
    """Placeholder mesh for the Stage 7 3D viewport: a fixed box, tessellated
    via the real OCCT pipeline in app.document.mesh. NOT derived from the
    Part's actual Feature tree - there is no ExtrudeFeature yet, so this
    cannot reflect real modeled geometry. `source` is "placeholder" so
    clients can tell the difference once real geometry exists."""
    get_part_or_404(part_id)

    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    mesh_data = tessellate_shape(box, DEFAULT_MESH_QUALITY)
    return PartMeshResponse(
        mesh=MeshVertexData(
            vertices=mesh_data.vertices,
            normals=mesh_data.normals,
            triangle_indices=[(t.a, t.b, t.c) for t in mesh_data.triangles],
        )
    )
