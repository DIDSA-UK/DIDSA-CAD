from typing import Literal, Union

from pydantic import BaseModel

from app.document.models import ExtrudeType
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
# SketchEntityResponse.
class SketchFeatureResponse(BaseModel):
    type: Literal["sketch"] = "sketch"
    id: str
    sketch_id: str
    locked: bool


class ExtrudeFeatureCreate(BaseModel):
    """Creates an ExtrudeFeature from an existing SketchFeature's closed
    Profile - the API layer validates `sketch_feature_id` resolves to a
    SketchFeature in this Part with a closed profile before construction
    (see app.document.router._require_closed_sketch_feature)."""

    sketch_feature_id: str
    extrude_type: ExtrudeType
    start_distance: float
    end_distance: float


class ExtrudeFeatureUpdate(BaseModel):
    """Partial update for live-preview re-solves - any subset of fields may
    be supplied; omitted fields keep their current value."""

    extrude_type: ExtrudeType | None = None
    start_distance: float | None = None
    end_distance: float | None = None


class ExtrudeFeatureResponse(BaseModel):
    type: Literal["extrude"] = "extrude"
    id: str
    sketch_feature_id: str
    extrude_type: ExtrudeType
    start_distance: float
    end_distance: float
    locked: bool


FeatureResponse = Union[SketchFeatureResponse, ExtrudeFeatureResponse]


class MeshVertexData(BaseModel):
    vertices: list[tuple[float, float, float]]
    normals: list[tuple[float, float, float]]
    triangle_indices: list[tuple[int, int, int]]


class PartMeshResponse(BaseModel):
    """`source` is "placeholder" while the Part has no ExtrudeFeature yet
    (see `Part.produces_solid_geometry`), and "computed" once real
    Feature-derived geometry is being returned instead - callers can use
    this to tell a fixed dev-time stand-in apart from the Part's actual
    modeled geometry."""

    source: Literal["placeholder", "computed"]
    mesh: MeshVertexData


class CascadeDeleteResponse(BaseModel):
    """What got deleted by a cascade-delete: the target Feature and every
    Feature after it, plus the Sketch each deleted SketchFeature owned -
    in deletion order, so a client can confirm the backend's view matches
    what it just asked for (or refresh from it directly)."""

    deleted_feature_ids: list[str]
    deleted_sketch_ids: list[str]
