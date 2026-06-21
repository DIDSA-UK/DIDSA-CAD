from typing import Literal, Union

from pydantic import BaseModel

from app.sketch.models import Plane


class PartCreate(BaseModel):
    name: str


class PartResponse(BaseModel):
    id: str
    name: str
    feature_ids: list[str]


class SketchFeatureCreate(BaseModel):
    """Creates a SketchFeature wrapping a brand-new, empty Sketch on the
    given plane - there is no "wrap an existing Sketch" mode, since the
    out-of-scope "tap a locked Feature to re-edit its sketch" flow is the
    only case that would need one."""

    plane: Plane


# `type` is a discriminator, same pattern as app.sketch.schemas'
# SketchEntityResponse - becomes a real Union once ExtrudeFeature exists.
class SketchFeatureResponse(BaseModel):
    type: Literal["sketch"] = "sketch"
    id: str
    sketch_id: str
    locked: bool


FeatureResponse = Union[SketchFeatureResponse]


class MeshVertexData(BaseModel):
    vertices: list[tuple[float, float, float]]
    normals: list[tuple[float, float, float]]
    triangle_indices: list[tuple[int, int, int]]


class PartMeshResponse(BaseModel):
    """`source` is "placeholder" for this stage and always will be until a
    real ExtrudeFeature exists - callers must not treat this mesh as the
    Part's actual modeled geometry."""

    source: Literal["placeholder"] = "placeholder"
    mesh: MeshVertexData
