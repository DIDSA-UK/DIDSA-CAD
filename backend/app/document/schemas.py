from typing import Literal, Union

from pydantic import BaseModel

from app.document.models import ExtrudeType, Produces
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
    # B1: what this Feature contributes, for the client tree's grouping
    # (B3) - see app.document.models.Feature.produces.
    produces: Produces


class ExtrudeFeatureCreate(BaseModel):
    """Creates an ExtrudeFeature from an existing SketchFeature's closed
    Profile - the API layer validates `sketch_feature_id` resolves to a
    SketchFeature in this Part with a closed profile before construction
    (see app.document.router._require_closed_sketch_feature).

    A1: `target_body_ids` names which Body/Bodies (by id - see
    app.document.models.ExtrudeFeature's docstring for how Body ids are
    derived) this Feature combines with. Boss: empty starts a brand-new
    Body; non-empty fuses into each named Body. Cut: must be non-empty -
    see app.document.router._validate_target_body_ids, which raises 422 for
    an empty Cut list."""

    sketch_feature_id: str
    extrude_type: ExtrudeType
    start_distance: float
    end_distance: float
    target_body_ids: list[str] = []


class ExtrudeFeatureUpdate(BaseModel):
    """Partial update for live-preview re-solves - any subset of fields may
    be supplied; omitted fields keep their current value. `target_body_ids`
    follows the same omitted-vs-empty-list distinction as the other
    fields: omitted (None) leaves the Feature's current targets untouched;
    an explicit `[]` replaces them with an empty list (rejected for Cut,
    same as on create)."""

    extrude_type: ExtrudeType | None = None
    start_distance: float | None = None
    end_distance: float | None = None
    target_body_ids: list[str] | None = None


class ExtrudeFeatureResponse(BaseModel):
    type: Literal["extrude"] = "extrude"
    id: str
    sketch_feature_id: str
    extrude_type: ExtrudeType
    start_distance: float
    end_distance: float
    locked: bool
    target_body_ids: list[str] = []
    # B1: see SketchFeatureResponse.produces above - always BODY for an
    # ExtrudeFeature today (Boss and Cut alike).
    produces: Produces


FeatureResponse = Union[SketchFeatureResponse, ExtrudeFeatureResponse]


class MeshVertexData(BaseModel):
    vertices: list[tuple[float, float, float]]
    normals: list[tuple[float, float, float]]
    triangle_indices: list[tuple[int, int, int]]
    # Stage 11: flat [x1,y1,z1, x2,y2,z2, ...] edge polyline segments, sampled
    # from the shape's real OCCT curves - see app.document.mesh._extract_edges.
    edges: list[float]
    # Stage 23: stable per-triangle/per-edge-segment/per-topology-vertex ids -
    # foundation for the 3D viewport's selection mode hit-testing (face/edge/
    # vertex pick -> entity id). Defaulted to [] for backward compatibility
    # with any client mesh fixture built before this stage. Only stable
    # within one response - see app.document.mesh.MeshData's own field docs.
    face_ids: list[int] = []
    edge_ids: list[int] = []
    topology_vertices: list[tuple[float, float, float]] = []
    topology_vertex_ids: list[int] = []


class BodyMeshResponse(BaseModel):
    """A1: one entry of `GET /parts/{id}/mesh`'s response, which is now an
    array of these (one per Body) rather than a single combined mesh - see
    app.document.router.get_part_mesh. `body_id` is the same stable,
    deterministic id described in app.document.models.ExtrudeFeature's
    docstring - stable across recomputes as long as the Body itself isn't
    merged into another. `face_ids`/`edge_ids`/`topology_vertex_ids` inside
    `mesh` are only unique within this one Body's own tessellation, same
    per-request-only stability caveat as before A1 (see
    app.document.mesh.MeshData's field docs) - they do not need to be
    globally unique across the whole array.

    `source` is "placeholder" while the Part has no ExtrudeFeature yet (see
    `Part.produces_solid_geometry`), in which case the array has exactly
    one entry (the fixed dev-time stand-in box) - and "computed" once real
    Feature-derived geometry is being returned instead, one entry per
    actual Body (zero entries if every ExtrudeFeature so far has been
    skipped/hidden)."""

    body_id: str
    source: Literal["placeholder", "computed"]
    mesh: MeshVertexData


class CascadeDeleteResponse(BaseModel):
    """What got deleted by a cascade-delete: the target Feature and every
    Feature after it, plus the Sketch each deleted SketchFeature owned -
    in deletion order, so a client can confirm the backend's view matches
    what it just asked for (or refresh from it directly)."""

    deleted_feature_ids: list[str]
    deleted_sketch_ids: list[str]
