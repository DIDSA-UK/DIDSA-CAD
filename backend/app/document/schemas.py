from typing import Literal, Union

from pydantic import BaseModel

from app.document.models import ExtrudeType, PlaneType, Produces, RevolveMode, SubShapeType, SweepMode
from app.sketch.models import Plane, SketchEntityType


class PartCreate(BaseModel):
    name: str


class PartResponse(BaseModel):
    id: str
    name: str
    feature_ids: list[str]


class SketchFeatureCreate(BaseModel):
    """Creates a SketchFeature wrapping a brand-new, empty Sketch, either on
    one of the three fixed reference planes (`plane`) or (C3) anchored to an
    existing `CreatePlaneFeature` (`plane_feature_id`) - exactly one of the
    two must be supplied (see
    `app.document.router._validate_sketch_feature_payload`, same "payload
    shape validated by the API layer" split every other mutually-exclusive
    Feature field already uses). There is no "wrap an existing Sketch" mode,
    since the out-of-scope "tap a locked Feature to re-edit its sketch" flow
    is the only case that would need one."""

    plane: Plane | None = None
    plane_feature_id: str | None = None


# `type` is a discriminator, same pattern as app.sketch.schemas'
# SketchEntityResponse.
class SketchFeatureResponse(BaseModel):
    type: Literal["sketch"] = "sketch"
    id: str
    sketch_id: str
    # C3: echoes SketchFeature.plane_feature_id - null for a Sketch on one of
    # the three fixed reference planes (the common case, unchanged from
    # before C3), set for one anchored to a custom plane instead.
    plane_feature_id: str | None = None
    locked: bool
    # B1: what this Feature contributes, for the client tree's grouping
    # (B3) - see app.document.models.Feature.produces.
    produces: Produces


class SketchEntityRefSchema(BaseModel):
    """C2: the wire counterpart to `app.sketch.models.SketchEntityRef` (C1)
    - same "no schema until a real consumer exists" story as
    `SubShapeRefSchema` below. Moved above the Extrude/Revolve schemas
    (Prompt G) since `ExtrudeFeatureCreate`/`RevolveFeatureCreate`'s own new
    `profile_refs` field needs it defined first - Pydantic resolves
    annotations at class-creation time in this file (no `from __future__
    import annotations`), so forward-referencing a not-yet-defined class
    would raise `NameError` at import."""

    sketch_id: str
    entity_type: SketchEntityType
    entity_id: str


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
    an empty Cut list.

    Prompt G: `profile_refs` names which outer profile(s) of the Sketch to
    use - empty (the default) means every outer profile currently detected,
    exactly the pre-Prompt-G behaviour; see
    app.document.extrude.select_profiles."""

    sketch_feature_id: str
    extrude_type: ExtrudeType
    start_distance: float
    end_distance: float
    target_body_ids: list[str] = []
    profile_refs: list[SketchEntityRefSchema] = []


class ExtrudeFeatureUpdate(BaseModel):
    """Partial update for live-preview re-solves - any subset of fields may
    be supplied; omitted fields keep their current value. `target_body_ids`
    follows the same omitted-vs-empty-list distinction as the other
    fields: omitted (None) leaves the Feature's current targets untouched;
    an explicit `[]` replaces them with an empty list (rejected for Cut,
    same as on create). Prompt G: `profile_refs` follows the identical
    omitted-vs-empty-list convention - omitted keeps the Feature's current
    selection, an explicit `[]` reverts to "every outer profile"."""

    extrude_type: ExtrudeType | None = None
    start_distance: float | None = None
    end_distance: float | None = None
    target_body_ids: list[str] | None = None
    profile_refs: list[SketchEntityRefSchema] | None = None


class ExtrudeFeatureResponse(BaseModel):
    type: Literal["extrude"] = "extrude"
    id: str
    sketch_feature_id: str
    extrude_type: ExtrudeType
    start_distance: float
    end_distance: float
    locked: bool
    target_body_ids: list[str] = []
    profile_refs: list[SketchEntityRefSchema] = []
    # B1: see SketchFeatureResponse.produces above - always BODY for an
    # ExtrudeFeature today (Boss and Cut alike).
    produces: Produces


class SubShapeRefSchema(BaseModel):
    """C2: the wire (pydantic) counterpart to `app.document.models.
    SubShapeRef` - B1 built that dataclass and its resolver with no consumer
    yet, so no pydantic schema existed for it either; this is the first
    Feature payload to embed one (`CreatePlaneFeatureCreate.face_ref`).
    Converted to/from the domain dataclass in `app.document.router`, the
    same plain-BaseModel-vs-dataclass split every other schema/model pair
    in this file already keeps."""

    body_id: str
    shape_type: SubShapeType
    index: int


class PointRefSchema(BaseModel):
    """C4: the wire counterpart to `app.document.models.PointRef` - exactly
    one of `vertex_ref`/`sketch_point_ref` should be supplied, matching
    `PointRef`'s own "one of two optional fields" convention (see its
    docstring); not enforced here, checked by
    `app.document.router._validate_create_plane_payload`."""

    vertex_ref: SubShapeRefSchema | None = None
    sketch_point_ref: SketchEntityRefSchema | None = None


class PlaneRefSchema(BaseModel):
    """C5: the wire counterpart to `app.document.models.PlaneRef` - exactly
    one of `face_ref`/`fixed_plane`/`plane_feature_id` should be supplied,
    matching `PlaneRef`'s own "one of three optional fields" convention
    (see its docstring); not enforced here, checked by
    `app.document.router._validate_plane_ref`. Lets OFFSET_FACE/MIDPLANE/
    PARALLEL_TO_FACE_THROUGH_VERTEX reference a Body face, a fixed
    reference plane, or an existing CreatePlaneFeature, instead of only a
    Body face as in C2-C4."""

    face_ref: SubShapeRefSchema | None = None
    fixed_plane: Plane | None = None
    plane_feature_id: str | None = None


class CreatePlaneFeatureCreate(BaseModel):
    """Creates a CreatePlaneFeature (C2/C3/C4/C5) - exactly one combination
    of fields should be supplied, matching `plane_type`:
    - `OFFSET_FACE`: `face_refs` (one entry), `offset`.
    - `MIDPLANE`: `face_refs` (two entries).
    - `NORMAL_TO_LINE_AT_POINT`: `line_ref`, `point_ref`.
    - `NORMAL_TO_EDGE_THROUGH_VERTEX`: `edge_ref`, `vertex_ref`.
    - `PARALLEL_TO_FACE_THROUGH_VERTEX`: `face_refs` (one entry), `vertex_ref`.
    - `THREE_POINTS`: `point_refs` (three entries).
    See `app.document.router._validate_create_plane_payload` for the exact
    combination check (not encoded here, mirroring `ExtrudeFeatureCreate`'s
    own Boss-vs-Cut `target_body_ids` split).

    `face_ref` (C2, singular) became `face_refs` (C3, a list) so MIDPLANE
    (and, C4, PARALLEL_TO_FACE_THROUGH_VERTEX) can reuse the same field as
    OFFSET_FACE. `vertex_ref` (C4) is likewise shared between
    NORMAL_TO_EDGE_THROUGH_VERTEX and PARALLEL_TO_FACE_THROUGH_VERTEX.
    `face_refs` entries became `PlaneRefSchema` (C5, was `SubShapeRefSchema`)
    so each entry can be a Body face, a fixed reference plane, or an
    existing CreatePlaneFeature."""

    plane_type: PlaneType
    face_refs: list[PlaneRefSchema] = []
    offset: float | None = None
    line_ref: SketchEntityRefSchema | None = None
    point_ref: SketchEntityRefSchema | None = None
    edge_ref: SubShapeRefSchema | None = None
    vertex_ref: SubShapeRefSchema | None = None
    point_refs: list[PointRefSchema] = []


class CreatePlaneFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `ExtrudeFeatureUpdate` - `plane_type` itself is never changed by an
    update (switching plane-construction method is a delete+recreate, not
    an edit); only the refs/offset for whichever type the Feature already
    is can be revised. Unlike `ExtrudeFeatureUpdate.target_body_ids`, there
    is no "omitted vs. explicit empty" distinction to make here - a
    CreatePlaneFeature's refs are never legitimately cleared to nothing
    while staying valid, so `None` unambiguously means "not provided,
    keep the current value" for every field below."""

    face_refs: list[PlaneRefSchema] | None = None
    offset: float | None = None
    line_ref: SketchEntityRefSchema | None = None
    point_ref: SketchEntityRefSchema | None = None
    edge_ref: SubShapeRefSchema | None = None
    vertex_ref: SubShapeRefSchema | None = None
    point_refs: list[PointRefSchema] | None = None


class CreatePlaneFeatureResponse(BaseModel):
    type: Literal["create_plane"] = "create_plane"
    id: str
    plane_type: PlaneType
    # Echo of whichever refs/values were supplied - for edit-mode prefill,
    # same purpose B4's Extrude edit-prefill serves.
    face_refs: list[PlaneRefSchema] = []
    offset: float | None = None
    line_ref: SketchEntityRefSchema | None = None
    point_ref: SketchEntityRefSchema | None = None
    edge_ref: SubShapeRefSchema | None = None
    vertex_ref: SubShapeRefSchema | None = None
    point_refs: list[PointRefSchema] = []
    # Resolved world-space geometry (see app.document.models.ResolvedPlane)
    # for rendering - null when it can't currently be resolved (e.g. a
    # referenced Body/Sketch was deleted out from under it), rather than
    # failing the whole list/get response over one bad Feature. Always
    # non-null right after a successful create/update, since those
    # endpoints validate resolvability before ever constructing the
    # Feature - see app.document.router._validate_create_plane_payload.
    origin: tuple[float, float, float] | None = None
    normal: tuple[float, float, float] | None = None
    # C3: the plane's own in-plane basis, for a Sketch anchored to it (see
    # app.document.models.ResolvedPlane) to embed its local geometry, and
    # for the client to orient its rendered quad consistently with that
    # embedding rather than deriving its own (possibly different)
    # arbitrary in-plane orientation. Null exactly when origin/normal are.
    x_axis: tuple[float, float, float] | None = None
    y_axis: tuple[float, float, float] | None = None
    locked: bool
    produces: Produces


class FilletFeatureCreate(BaseModel):
    """Prompt D: rounds every edge named in `edge_refs` (all must resolve to
    the same Body - see `app.document.fillet._mixed_body_selection`) with
    one shared `radius`. See `app.document.router._validate_fillet_payload`
    for the exact checks (non-empty `edge_refs`, each entry's `shape_type
    == EDGE`, `radius > 0`) - not encoded here, mirroring every other
    Feature's own "payload shape validated by the API layer" split."""

    edge_refs: list[SubShapeRefSchema] = []
    radius: float


class FilletFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `ExtrudeFeatureUpdate`/`CreatePlaneFeatureUpdate` - `None` means "not
    provided, keep the current value" for both fields below."""

    edge_refs: list[SubShapeRefSchema] | None = None
    radius: float | None = None


class FilletFeatureResponse(BaseModel):
    type: Literal["fillet"] = "fillet"
    id: str
    edge_refs: list[SubShapeRefSchema] = []
    radius: float
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # FilletFeature (it modifies, rather than creates, a Body).
    produces: Produces


class ChamferFeatureCreate(BaseModel):
    """Prompt E: mirrors `FilletFeatureCreate` exactly, substituting
    `distance` for `radius` - see `app.document.router.
    _validate_chamfer_edge_refs`/`_validate_chamfer_distance` for the
    payload-shape checks (non-empty `edge_refs`, each entry's `shape_type
    == EDGE`, `distance > 0`)."""

    edge_refs: list[SubShapeRefSchema] = []
    distance: float


class ChamferFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `FilletFeatureUpdate`."""

    edge_refs: list[SubShapeRefSchema] | None = None
    distance: float | None = None


class ChamferFeatureResponse(BaseModel):
    type: Literal["chamfer"] = "chamfer"
    id: str
    edge_refs: list[SubShapeRefSchema] = []
    distance: float
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # ChamferFeature (it modifies, rather than creates, a Body).
    produces: Produces


class RevolveFeatureCreate(BaseModel):
    """Prompt F: creates a RevolveFeature from an existing SketchFeature's
    closed Profile - mirrors `ExtrudeFeatureCreate` exactly (same
    `sketch_feature_id`/`target_body_ids` Boss-vs-Cut shape, same 422-if-Cut-
    is-empty check in `app.document.router._validate_target_body_ids`,
    generalized to accept a Body from either an ExtrudeFeature or a
    RevolveFeature), substituting `axis_ref`/`angle` for
    `start_distance`/`end_distance`. `axis_ref`'s Sketch is not required to
    be the same Sketch as `sketch_feature_id`'s (confirmed explicitly - see
    `app.document.models.RevolveFeature`'s own docstring). Prompt G:
    `profile_refs` mirrors `ExtrudeFeatureCreate.profile_refs` exactly."""

    sketch_feature_id: str
    axis_ref: SketchEntityRefSchema
    angle: float
    mode: RevolveMode
    target_body_ids: list[str] = []
    profile_refs: list[SketchEntityRefSchema] = []


class RevolveFeatureUpdate(BaseModel):
    """Partial update for live-preview re-solves, same omitted-vs-current-
    value convention as `ExtrudeFeatureUpdate` - `sketch_feature_id` is never
    revised (same as `ExtrudeFeatureUpdate` never revising its own source
    Sketch), only the axis/angle/mode/targets/profile selection of whichever
    Sketch this Feature already revolves."""

    axis_ref: SketchEntityRefSchema | None = None
    angle: float | None = None
    mode: RevolveMode | None = None
    target_body_ids: list[str] | None = None
    profile_refs: list[SketchEntityRefSchema] | None = None


class RevolveFeatureResponse(BaseModel):
    type: Literal["revolve"] = "revolve"
    id: str
    sketch_feature_id: str
    axis_ref: SketchEntityRefSchema
    angle: float
    mode: RevolveMode
    locked: bool
    target_body_ids: list[str] = []
    profile_refs: list[SketchEntityRefSchema] = []
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # RevolveFeature (Boss and Cut alike, mirroring ExtrudeFeature).
    produces: Produces


class SweepFeatureCreate(BaseModel):
    """Creates a SweepFeature from an existing SketchFeature's closed
    Profile - mirrors `ExtrudeFeatureCreate`/`RevolveFeatureCreate` exactly
    (same `sketch_feature_id`/`target_body_ids` Boss-vs-Cut shape, same
    422-if-Cut-is-empty check in `app.document.router._validate_target_
    body_ids`, generalized to accept a Body from any of Extrude/Revolve/
    Sweep), substituting `path_refs` for `start_distance`/`end_distance`/
    `axis_ref`/`angle`.

    `path_refs` is an *ordered* list of Sketch Line references, each
    possibly naming a different Sketch (confirmed explicitly - not
    restricted to one Sketch the way a single `axis_ref` is one Line) -
    must name at least one entry (see `app.document.router._validate_
    sweep_path_refs`); whether the named Lines actually resolve and chain
    into one connected path (open or closed) is checked by
    `app.document.sweep.resolve_sweep` instead, mirroring every other
    structured Feature error in this codebase's "payload shape in the
    router, resolution in the OCCT module" split.

    `profile_refs` mirrors `ExtrudeFeatureCreate.profile_refs` exactly."""

    sketch_feature_id: str
    path_refs: list[SketchEntityRefSchema]
    mode: SweepMode
    target_body_ids: list[str] = []
    profile_refs: list[SketchEntityRefSchema] = []


class SweepFeatureUpdate(BaseModel):
    """Partial update for live-preview re-solves, same omitted-vs-current-
    value convention as `ExtrudeFeatureUpdate`/`RevolveFeatureUpdate` -
    `sketch_feature_id` is never revised, only the path/mode/targets/
    profile selection of whichever Sketch this Feature already sweeps."""

    path_refs: list[SketchEntityRefSchema] | None = None
    mode: SweepMode | None = None
    target_body_ids: list[str] | None = None
    profile_refs: list[SketchEntityRefSchema] | None = None


class SweepFeatureResponse(BaseModel):
    type: Literal["sweep"] = "sweep"
    id: str
    sketch_feature_id: str
    path_refs: list[SketchEntityRefSchema] = []
    mode: SweepMode
    locked: bool
    target_body_ids: list[str] = []
    profile_refs: list[SketchEntityRefSchema] = []
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # SweepFeature (Boss and Cut alike, mirroring ExtrudeFeature/
    # RevolveFeature).
    produces: Produces


FeatureResponse = Union[
    SketchFeatureResponse,
    ExtrudeFeatureResponse,
    CreatePlaneFeatureResponse,
    FilletFeatureResponse,
    ChamferFeatureResponse,
    RevolveFeatureResponse,
    SweepFeatureResponse,
]


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
    # Fillet follow-up: face_edge_ids[face_id] is the sorted list of edge_ids
    # bounding that face - see app.document.mesh._extract_face_edge_ids.
    # Defaults to [] for the same backward-compatibility reason as the ids
    # above.
    face_edge_ids: list[list[int]] = []


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
    skipped by the Part's own graph, e.g. a Cut with no target left after a
    genuine deletion - never merely hidden, see `hidden` below).

    On-device feedback (post-C4 hide/rollback fix): every computed Body is
    now always included here, `hidden` set instead of the entry being
    dropped - the Build Tree's own Bodies section needs to keep listing a
    hidden Body (so Show can be reached again from the tree, not only from
    whichever Feature originally produced it), which an omitted entry can't
    support. `source="placeholder"` is never `hidden` - there is nothing to
    hide yet at that point."""

    body_id: str
    source: Literal["placeholder", "computed"]
    mesh: MeshVertexData
    hidden: bool = False


class NativeImportResponse(BaseModel):
    """What `POST /document/import/native` hands back once the full-replace
    import succeeds - just enough for the client to confirm the new state
    (which Parts now exist) without re-fetching, mirroring
    `CascadeDeleteResponse`'s own "confirm what just happened" purpose."""

    document_id: str
    part_ids: list[str]


class CascadeDeleteResponse(BaseModel):
    """What got deleted by a cascade-delete: the target Feature and every
    Feature after it, plus the Sketch each deleted SketchFeature owned -
    in deletion order, so a client can confirm the backend's view matches
    what it just asked for (or refresh from it directly)."""

    deleted_feature_ids: list[str]
    deleted_sketch_ids: list[str]
