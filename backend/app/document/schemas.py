from typing import Literal, Union

from pydantic import BaseModel

from app.document.models import (
    BevelGearType,
    BooleanOperation,
    ExtrudeType,
    FixedAxis,
    GearChainMemberType,
    GearType,
    ImportSourceFormat,
    LoftMode,
    MergeMode,
    PatternType,
    PlaneType,
    Produces,
    RackType,
    RevolveMode,
    SpiralBevelHand,
    SubShapeType,
    SweepMode,
)
from app.sketch.models import Plane, SketchEntityType
from app.sketch.schemas import ArcResponse, CircleResponse, LineResponse, PointResponse


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
    # Sketcher-roadmap Phase 4.3 v1: true whenever at least one of this
    # Sketch's `external_references` (a Point tracking a Body vertex) no
    # longer resolves against the Part's *current* Bodies - resolved live
    # on every response the same soft-fail-without-raising way
    # `_create_plane_feature_response`'s own `origin`/`normal` fields
    # already are (see `app.document.router._feature_response`'s
    # SketchFeature branch), so one Sketch with a since-broken reference
    # never fails the whole `GET .../features` list. Always false for a
    # Sketch with no external references at all - the common case, and the
    # only case before this field existed.
    has_lost_reference: bool = False


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


class MeasureRequest(BaseModel):
    """Measure tool: the wire payload for POST /parts/{part_id}/measure - 1
    or 2 [SubShapeRefSchema]s (an already-picked vertex/edge/face). Order is
    cosmetic only (which ref becomes point_a/shape1 vs point_b/shape2 in the
    response) - every named result (axis_distance, normal_distance) is
    symmetric in its two inputs, so swapping refs never changes what's
    reported, just which point is labelled A vs B."""

    refs: list[SubShapeRefSchema]


class AxisSchema(BaseModel):
    """A `gp_Ax1` (origin + direction), for a circular edge's or
    cylindrical face's own fitted axis."""

    origin: tuple[float, float, float]
    direction: tuple[float, float, float]


class MeasurementResultSchema(BaseModel):
    """The response to a Measure query - one flat, mostly-optional schema
    (matching this file's existing convention for a multi-shaped response,
    e.g. FeatureResponse) rather than a tagged union, since which fields are
    populated already fully describes what was measured. Single-entity
    fields (point/length/area/radius/diameter/center/axis/normal/
    point_on_face) are set by a 1-ref request; two-entity fields (distance/
    point_a/point_b/delta are always set, axis_distance/axes_parallel/
    normal_distance/faces_parallel only when detected) are set by a 2-ref
    request. See `app.document.measure.MeasurementResult`, this schema's
    plain-dataclass domain counterpart."""

    # Single-entity fields.
    point: tuple[float, float, float] | None = None
    length: float | None = None
    area: float | None = None
    radius: float | None = None
    diameter: float | None = None
    center: tuple[float, float, float] | None = None
    axis: AxisSchema | None = None
    normal: tuple[float, float, float] | None = None
    point_on_face: tuple[float, float, float] | None = None
    # Two-entity fields - distance/point_a/point_b/delta always set for a
    # 2-ref request; the rest only when the specific relationship holds.
    distance: float | None = None
    point_a: tuple[float, float, float] | None = None
    point_b: tuple[float, float, float] | None = None
    delta: tuple[float, float, float] | None = None
    axis_distance: float | None = None
    axes_parallel: bool | None = None
    normal_distance: float | None = None
    faces_parallel: bool | None = None


class ExternalVertexReferenceCreate(BaseModel):
    """Sketcher-roadmap Phase 4.3 v1: the payload for the new materialize-
    a-body-vertex-as-a-Point endpoint - the wire counterpart to
    `app.sketch.models.ExternalVertexReference`. Deliberately its own small
    schema rather than reusing `SubShapeRefSchema` directly (which carries
    a `shape_type` that would always have to be `vertex` here anyway, per
    v1's own explicit scope - see the roadmap doc's own "vertices only in
    v1" reasoning) - `app.document.router` converts this into the domain
    `ExternalVertexReference` at the same boundary every other schema/
    dataclass pair here already converts at."""

    body_id: str
    vertex_index: int


class ExternalEdgeReferenceCreate(BaseModel):
    """Sketcher-roadmap Phase 4.3 v2: the payload for the materialize-a-
    body-edge endpoint - same "deliberately its own small schema, not
    `SubShapeRefSchema`" reasoning as `ExternalVertexReferenceCreate`
    above (`shape_type` would always be `edge` here)."""

    body_id: str
    edge_index: int


class ExternalEdgeReferenceResponse(BaseModel):
    """Sketcher-roadmap Phase 4.3 v2: an edge external reference
    materializes as two Points (each exactly like
    `ExternalVertexReferenceCreate`'s own response would return) plus a
    real Line between them - this bundles all three into one response so
    the client can populate its local Point/Line state from a single
    round trip, the same way `create_line`'s own response already
    carries everything a freshly-created Line's endpoints need."""

    line: LineResponse
    start_point: PointResponse
    end_point: PointResponse


class ConvertVertexCreate(BaseModel):
    """Sketcher-roadmap Phase 9 v2 (Convert Entities): the payload for
    materializing a Body vertex as a real, *associative* Point in the
    active Sketch - deliberately its own schema, not
    `ExternalVertexReferenceCreate`, since the two endpoints create
    genuinely different things even though both are now backed by
    `Sketch.add_or_reuse_external_vertex_reference`: this one's Point is
    meant to participate in ordinary sketch geometry (profile detection,
    Extrude) as real, non-construction geometry, not to be a pinned
    dimensioning target - see `app.document.router.convert_body_vertex`'s
    own doc comment for the full picture, including what "associative"
    means here (staleness detection and the feature-tree lost-reference
    indicator both fall out for free) and its one known limitation
    (inherited, not introduced: dragging one snaps back on the next
    solve, same as every other external-reference Point)."""

    body_id: str
    vertex_index: int


class ConvertEdgeCreate(BaseModel):
    """Convert Entities' edge-shaped sibling to `ConvertVertexCreate` - see
    that schema's own doc comment for why this is a separate concept from
    `ExternalEdgeReferenceCreate` despite the identical wire shape.

    On-device feedback ("when offsetting an edge, a line or curve is
    created on the edge - these lines should be construction"): defaults
    to `False` (real, extrude-participating geometry), matching every
    prior behavior - Convert Entities itself still wants a real, non-
    construction copy of the picked edge. Offset's own edge-to-seed
    conversion (`SketchController.pickBodyEdgeForOffset`) passes `True`
    instead - that seed is never meant to be its own profile boundary,
    only a reference for the offset distance to measure from."""

    body_id: str
    edge_index: int
    construction: bool = False


class ConvertEdgeResponse(BaseModel):
    """Convert Entities' edge-shaped sibling to `ExternalEdgeReferenceResponse`
    - same "one response carries the new entity and both Points" reasoning.
    `start_point`/`end_point` may each be either a freshly created,
    associative Point or one this Sketch already had tracking the exact
    same Body vertex (see `Sketch.add_or_reuse_external_vertex_reference`)
    - the client should upsert by id either way, same as it already
    treats `create_line`'s own endpoint response.

    On-device feedback ("when I offset a curved edge it creates a straight
    line"): exactly one of `line`/`arc`/`circle` is ever set now - a
    coplanar circular Body edge resolves as a real `arc` instead of always
    `line` (its own chord), matching `PointRef`'s established "exactly one
    of several optional fields" convention. `center_point` is only present
    alongside `arc`/`circle` - v1 limitation, spelled out on
    `router.convert_body_edge`'s own doc comment: unlike `start_point`/
    `end_point`, the center is a plain, non-associative Point (no existing
    mechanism pins a circular edge's own center the way a vertex reference
    does), so it won't itself track a later change to the Body's shape -
    only the Arc's start/end will, via the same 'lost reference' machinery
    every other external reference already has.

    On-device feedback ("offsetting the circular edge of a cylinder fails
    with a degenerate_edge error"): `circle` is set instead of `line`/`arc`
    for a *full* circular Body edge (both topological endpoints the same
    Body vertex, e.g. a cylinder's rim or a drilled hole) - previously
    always rejected with a `degenerate_edge` 422 before curve-type
    detection ever ran, since a full circle has no distinct `start_point`/
    `end_point` for the old chord-Line/Arc shape to hang off of. `start_
    point`/`end_point` are meaningless for this case and are simply set
    equal to `center_point` (kept required on the wire shape rather than
    made optional, so existing clients that always read `start_point`/
    `end_point` don't need a third null-check) - only `circle`/
    `center_point` carry real information here."""

    line: LineResponse | None = None
    arc: ArcResponse | None = None
    circle: CircleResponse | None = None
    start_point: PointResponse
    end_point: PointResponse
    center_point: PointResponse | None = None


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
    - `NORMAL_TO_CURVE_AT_POINT`: `line_ref` (an Arc, despite the field's
      name - see `PlaneType`'s own doc comment), `point_ref`.
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


class MirrorFeatureCreate(BaseModel):
    """Pattern/Mirror scoping's Phase 1/6 (`docs/pattern-mirror-scope.md`
    §2.1/§2.8/§4): creates a MirrorFeature reflecting every Body named in
    `source_body_ids`, combined with every Body each `source_feature_ids`
    entry currently resolves to (Phase 6 - a Feature-tree pick), across
    `mirror_plane`. At least one entry between `source_body_ids`/`source_
    feature_ids` is required (see `app.document.router._validate_mirror_
    source_body_ids`) - multi-body seeding was pulled forward from its
    original Phase 6 scoping into Phase 1 on guided-flow UX feedback;
    multi-*feature* seeding (`source_feature_ids`) is Phase 6. `merge`
    (Phase 5, `docs/pattern-mirror-scope.md` §2.10) defaults to `KEEP_
    SEPARATE`, matching `MirrorFeature`'s own dataclass default."""

    source_body_ids: list[str]
    mirror_plane: PlaneRefSchema
    source_feature_ids: list[str] = []
    merge: MergeMode = MergeMode.KEEP_SEPARATE
    # Phase 8 (`docs/pattern-mirror-scope.md` §2.11/§4): a third, mutually
    # exclusive seed-picking mode - names an upstream Extrude/Revolve/Sweep
    # Cut/Boss-into-target Feature instead of `source_body_ids`/`source_
    # feature_ids` (see `app.document.router._validate_tool_feature_id`).
    tool_feature_id: str | None = None


class MirrorFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `ChamferFeatureUpdate`/`FilletFeatureUpdate`. `tool_feature_id`
    (Phase 8) follows the identical convention - `None` (omitted) keeps
    whatever the Feature already has; there is no supported way to switch
    *out* of `tool_feature_id` mode via update (mirrors `PatternFeature
    Update.pattern_type`'s own immutability - switching modes is delete+
    recreate, not an edit)."""

    source_body_ids: list[str] | None = None
    mirror_plane: PlaneRefSchema | None = None
    source_feature_ids: list[str] | None = None
    merge: MergeMode | None = None
    tool_feature_id: str | None = None


class MirrorFeatureResponse(BaseModel):
    type: Literal["mirror"] = "mirror"
    id: str
    source_body_ids: list[str]
    mirror_plane: PlaneRefSchema
    source_feature_ids: list[str] = []
    merge: MergeMode
    tool_feature_id: str | None = None
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # MirrorFeature.
    produces: Produces


class MergeFeatureCreate(BaseModel):
    """Creates a `MergeFeature` fusing every Body named in `body_ids` (2+
    required - see `app.document.router._validate_merge_body_ids`) into a
    single Body. Symmetric, no target/tool distinction, no options - unlike
    `MirrorFeatureCreate.merge`, there is no mode to pick."""

    body_ids: list[str]


class MergeFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `MirrorFeatureUpdate`/`SurfaceFeatureUpdate`."""

    body_ids: list[str] | None = None


class MergeFeatureResponse(BaseModel):
    type: Literal["merge"] = "merge"
    id: str
    body_ids: list[str]
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # MergeFeature.
    produces: Produces


class BooleanFeatureCreate(BaseModel):
    """Creates a `BooleanFeature` (Boolean family, Subtract/Common) folding
    every Body named by `tool_body_ids` (1+ required) into/against every
    Body named by `target_body_ids` (1+ required, disjoint from
    `tool_body_ids` - see `app.document.router._validate_boolean_body_ids`)
    via `operation` (SUBTRACT/COMMON). `consume_tool_bodies` (default
    `True`, matching `BooleanFeature`'s own dataclass default) mirrors
    `GearFeatureCreate.is_internal`'s plain-bool convention rather than a
    new enum."""

    operation: BooleanOperation
    target_body_ids: list[str]
    tool_body_ids: list[str]
    consume_tool_bodies: bool = True


class BooleanFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `MergeFeatureUpdate`/`MirrorFeatureUpdate`."""

    operation: BooleanOperation | None = None
    target_body_ids: list[str] | None = None
    tool_body_ids: list[str] | None = None
    consume_tool_bodies: bool | None = None


class BooleanFeatureResponse(BaseModel):
    type: Literal["boolean"] = "boolean"
    id: str
    operation: BooleanOperation
    target_body_ids: list[str]
    tool_body_ids: list[str]
    consume_tool_bodies: bool
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # BooleanFeature.
    produces: Produces


class DeleteBodyFeatureCreate(BaseModel):
    """Direct Editing family (first entry): creates a `DeleteBodyFeature`
    removing every Body named in `body_ids` (1+ required - see `app.
    document.router._validate_delete_body_ids`). No "keep" mode - see
    `DeleteBodyFeature`'s own docstring."""

    body_ids: list[str]


class DeleteBodyFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `MergeFeatureUpdate`/`BooleanFeatureUpdate`."""

    body_ids: list[str] | None = None


class DeleteBodyFeatureResponse(BaseModel):
    type: Literal["delete_body"] = "delete_body"
    id: str
    body_ids: list[str]
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always NONE for a
    # DeleteBodyFeature (it removes geometry, never contributes any).
    produces: Produces


class ScaleBodyFeatureCreate(BaseModel):
    """Direct Editing family (second entry): creates a `ScaleBodyFeature`
    uniformly scaling `body_id` by `factor` (> 0 required - see `app.
    document.router._validate_scale_body_factor`) about its own current
    bounding-box centre. No user-pickable origin, no non-uniform X/Y/Z in
    v1 - see `ScaleBodyFeature`'s own docstring."""

    body_id: str
    factor: float = 1.0


class ScaleBodyFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `MergeFeatureUpdate`/`DeleteBodyFeatureUpdate`."""

    body_id: str | None = None
    factor: float | None = None


class ScaleBodyFeatureResponse(BaseModel):
    type: Literal["scale_body"] = "scale_body"
    id: str
    body_id: str
    factor: float
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # ScaleBodyFeature.
    produces: Produces


class SplitToolRefSchema(BaseModel):
    """Boolean family, fourth/last entry: the wire counterpart to `app.
    document.models.SplitToolRef` - exactly one of `plane_ref`/`surface_
    feature_id`/`sketch_line_ref` should be supplied, matching
    `SplitToolRef`'s own "one of three optional fields" convention (see its
    docstring); not enforced here, checked by `app.document.router.
    _validate_split_tool_ref`."""

    plane_ref: PlaneRefSchema | None = None
    surface_feature_id: str | None = None
    sketch_line_ref: SketchEntityRefSchema | None = None


class SplitFeatureCreate(BaseModel):
    """Boolean family, fourth/last entry: creates a `SplitFeature` dividing
    the Body named by `target_body_id` into two independent, surviving
    pieces along `tool` (a Plane, an existing Surface, or a raw Sketch
    line/curve entity - see `SplitToolRefSchema`'s own docstring). The API
    layer validates `target_body_id`
    resolves to a Body-producing Feature in this Part, and `tool` is
    structurally valid and itself resolvable, before construction (see
    `app.document.router._validate_split_tool_ref`/`app.document.split.
    resolve_split`)."""

    target_body_id: str
    tool: SplitToolRefSchema


class SplitFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `MergeFeatureUpdate`/`BooleanFeatureUpdate`."""

    target_body_id: str | None = None
    tool: SplitToolRefSchema | None = None


class SplitFeatureResponse(BaseModel):
    type: Literal["split"] = "split"
    id: str
    target_body_id: str
    tool: SplitToolRefSchema
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # SplitFeature.
    produces: Produces


class PatternDirectionRefSchema(BaseModel):
    """Pattern/Mirror scoping's Phase 2 (`docs/pattern-mirror-scope.md`
    §2.2/§2.5): the wire counterpart to `app.document.models.
    PatternDirectionRef` - exactly one of `edge_ref`/`sketch_line_ref`/
    `fixed_axis` should be supplied, matching `PlaneRefSchema`'s own "one of
    three optional fields" convention (see its docstring); not enforced
    here, checked by `app.document.router._validate_pattern_direction_ref`."""

    edge_ref: SubShapeRefSchema | None = None
    sketch_line_ref: SketchEntityRefSchema | None = None
    fixed_axis: FixedAxis | None = None


class PatternAxisRefSchema(BaseModel):
    """Pattern/Mirror scoping's Phase 4 (`docs/pattern-mirror-scope.md`
    §2.3/§2.7): the wire counterpart to `app.document.models.
    PatternAxisRef` - exactly one of `edge_ref`/`face_ref`/`sketch_line_ref`
    should be supplied, matching `PatternDirectionRefSchema`'s own "one of
    three optional fields" convention; not enforced here, checked by
    `app.document.router._validate_pattern_axis_ref`."""

    edge_ref: SubShapeRefSchema | None = None
    face_ref: SubShapeRefSchema | None = None
    sketch_line_ref: SketchEntityRefSchema | None = None


class MoveBodyFeatureCreate(BaseModel):
    """Direct Editing family (third entry, "Move/Copy Body"): creates a
    `MoveBodyFeature` translating `body_id` by `delta` and/or rotating it
    `rotation_angle_degrees` around `rotation_axis` (reuses
    `PatternAxisRefSchema` verbatim - see `app.document.router._validate_
    pattern_axis_ref` for the same "exactly one of edge_ref/face_ref/
    sketch_line_ref" check Circular Pattern's own `axis` already gets).
    `rotation_axis=None` (the default) means no rotation - translate-only
    is the common case. `make_copy` (default `False`) mirrors
    `BooleanFeature.consume_tool_bodies`'s plain-bool convention. Named
    `make_copy`, not `copy` - `copy` collides with `pydantic.BaseModel.
    copy()`, which `flutter analyze`-equivalent tooling for this backend
    (a runtime `UserWarning` from Pydantic itself) flags immediately; see
    `MoveBodyFeature`'s own domain-dataclass docstring for the full
    "every layer uses the same name" reasoning."""

    body_id: str
    delta: tuple[float, float, float] = (0.0, 0.0, 0.0)
    rotation_axis: PatternAxisRefSchema | None = None
    rotation_angle_degrees: float = 0.0
    make_copy: bool = False


class MoveBodyFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `ScaleBodyFeatureUpdate`."""

    body_id: str | None = None
    delta: tuple[float, float, float] | None = None
    rotation_axis: PatternAxisRefSchema | None = None
    rotation_angle_degrees: float | None = None
    make_copy: bool | None = None


class MoveBodyFeatureResponse(BaseModel):
    type: Literal["move_body"] = "move_body"
    id: str
    body_id: str
    delta: tuple[float, float, float]
    rotation_axis: PatternAxisRefSchema | None
    rotation_angle_degrees: float
    make_copy: bool
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # MoveBodyFeature.
    produces: Produces


class DeleteFaceFeatureCreate(BaseModel):
    """Direct Editing family (fourth entry): creates a `DeleteFaceFeature`
    removing every face named in `face_refs` (1+ entries, all belonging to
    the same Body) and healing the opening(s) closed - see `app.document.
    delete_face`'s own module docstring for the OCCT technique and
    fail-closed contract."""

    face_refs: list[SubShapeRefSchema] = []


class DeleteFaceFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `ScaleBodyFeatureUpdate`."""

    face_refs: list[SubShapeRefSchema] | None = None


class DeleteFaceFeatureResponse(BaseModel):
    type: Literal["delete_face"] = "delete_face"
    id: str
    face_refs: list[SubShapeRefSchema]
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # DeleteFaceFeature.
    produces: Produces


class MoveFaceFeatureCreate(BaseModel):
    """Direct Editing family (fifth/last entry): creates a `MoveFaceFeature`
    moving every face named in `face_refs` (1+ entries, all belonging to
    the same Body) via exactly one of `offset_distance`/`delta`/
    (`direction_ref`+`direction_distance`) - matching `MoveFaceFeature`'s
    own "exactly one of three modes" convention (see that dataclass's own
    docstring); enforced by `app.document.router._validate_move_face_
    payload`, not here. V2: `delta`/`direction_ref`+`direction_distance`
    still require exactly one entry in `face_refs` (also enforced there,
    not here) - see `MoveFaceFeature`'s own docstring for why."""

    face_refs: list[SubShapeRefSchema] = []
    offset_distance: float | None = None
    delta: tuple[float, float, float] | None = None
    direction_ref: PatternDirectionRefSchema | None = None
    direction_distance: float | None = None


class MoveFaceFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `ScaleBodyFeatureUpdate` - note that switching between the three modes
    via PATCH means supplying the new mode's field(s) *and* nulling out
    every other mode's own field(s) in the same request (the router
    doesn't clear a field just because a different mode's field was
    supplied), mirroring how `SplitFeatureUpdate.tool` is always replaced
    as a whole, never partially merged."""

    face_refs: list[SubShapeRefSchema] | None = None
    offset_distance: float | None = None
    delta: tuple[float, float, float] | None = None
    direction_ref: PatternDirectionRefSchema | None = None
    direction_distance: float | None = None


class MoveFaceFeatureResponse(BaseModel):
    type: Literal["move_face"] = "move_face"
    id: str
    face_refs: list[SubShapeRefSchema]
    offset_distance: float | None
    delta: tuple[float, float, float] | None
    direction_ref: PatternDirectionRefSchema | None
    direction_distance: float | None
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # MoveFaceFeature.
    produces: Produces


class SurfaceFeatureCreate(BaseModel):
    """Creates a `SurfaceFeature` extruding an existing SketchFeature's wire
    - open or closed - into a non-solid Surface (see `app.document.models.
    SurfaceFeature`'s own docstring). The API layer validates `sketch_
    feature_id` resolves to a SketchFeature in this Part, and `direction_ref`
    (if set) is structurally valid, before construction (see `app.document.
    router._validate_surface_payload`).

    `start_distance`/`end_distance` share `ExtrudeFeatureCreate`'s own
    signed-distance convention exactly. `direction_ref` reuses
    `PatternDirectionRefSchema` verbatim - omitted (the default) extrudes
    normal to the backing Sketch's own host plane. `profile_refs` mirrors
    `ExtrudeFeatureCreate.profile_refs` exactly - see that field's own
    docstring."""

    sketch_feature_id: str
    start_distance: float
    end_distance: float
    direction_ref: PatternDirectionRefSchema | None = None
    profile_refs: list[SketchEntityRefSchema] = []


class SurfaceFeatureUpdate(BaseModel):
    """Partial update for live-preview re-solves - any subset of fields may
    be supplied; omitted fields keep their current value. `direction_ref`
    follows the same omitted-vs-current-value convention as `mirror_plane`/
    `direction_1` on `MirrorFeatureUpdate`/`PatternFeatureUpdate` - `None`
    (omitted) keeps whatever this Surface already has; there is no
    supported way to clear a real `direction_ref` back to "normal to the
    sketch plane" via update (delete+recreate, same as those two)."""

    sketch_feature_id: str | None = None
    start_distance: float | None = None
    end_distance: float | None = None
    direction_ref: PatternDirectionRefSchema | None = None
    profile_refs: list[SketchEntityRefSchema] | None = None


class SurfaceFeatureResponse(BaseModel):
    type: Literal["surface"] = "surface"
    id: str
    sketch_feature_id: str
    start_distance: float
    end_distance: float
    direction_ref: PatternDirectionRefSchema | None = None
    profile_refs: list[SketchEntityRefSchema] = []
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always SURFACE for a
    # SurfaceFeature.
    produces: Produces


class PatternFeatureCreate(BaseModel):
    """Pattern/Mirror scoping's Phase 2/4 (`docs/pattern-mirror-scope.md`
    §2.2/§2.3/§4): creates a `PatternFeature` repeating the single Body
    named in `source_body_ids`, either Rectangular (`pattern_type=
    "rectangular"`, the default) - along `direction_1` (`count_1`
    instances, `spacing_1` apart), optionally crossed with `direction_2`
    for a 2D grid - or Circular (`pattern_type="circular"`) - `count_
    angular` instances spaced evenly across `angle_total` degrees around
    `axis`. Which of these two field groups is actually required depends
    on `pattern_type` (see `app.document.router._validate_pattern_
    payload`), not encoded here - the same "payload shape validated by the
    API layer, not the schema" split `CreatePlaneFeatureCreate` already
    uses for its own six construction methods.

    `source_body_ids`, combined with every Body each `source_feature_ids`
    entry currently resolves to (Phase 6 - a Feature-tree pick), must have
    at least one entry between them (see `app.document.router._validate_
    pattern_source_body_ids`) - widened from Phase 2/4's original exactly-
    one-`source_body_ids`-entry requirement, mirroring `MirrorFeatureCreate`'s
    own Phase 1 shape (see `PatternFeature`'s own docstring). `merge`
    (Phase 5, `docs/pattern-mirror-scope.md` §2.10) defaults to `KEEP_
    SEPARATE`, matching `PatternFeature`'s own dataclass default."""

    source_body_ids: list[str]
    source_feature_ids: list[str] = []
    pattern_type: PatternType = PatternType.RECTANGULAR
    direction_1: PatternDirectionRefSchema | None = None
    count_1: int = 1
    spacing_1: float = 0.0
    reverse_1: bool = False
    direction_2: PatternDirectionRefSchema | None = None
    count_2: int = 1
    spacing_2: float = 0.0
    reverse_2: bool = False
    axis: PatternAxisRefSchema | None = None
    count_angular: int = 1
    angle_total: float = 360.0
    reverse_angular: bool = False
    skip_indices: list[int] = []
    merge: MergeMode = MergeMode.KEEP_SEPARATE
    # Phase 8 (`docs/pattern-mirror-scope.md` §2.11/§4): mirrors
    # `MirrorFeatureCreate.tool_feature_id`'s own identical shape.
    tool_feature_id: str | None = None


class PatternFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `MirrorFeatureUpdate`/`ChamferFeatureUpdate`. `direction_2` has no
    separate "omitted vs. explicitly cleared" distinction to make (unlike
    `ExtrudeFeatureUpdate.target_body_ids`' own `None`-vs-`[]` split) -
    `direction_2`/`spacing_2`/`reverse_2` are only ever read when
    `count_2 > 1` (see `PatternFeature`'s own docstring and
    `app.document.pattern.resolve_pattern_from_bodies`), so dropping
    `count_2` back to 1 alone already makes any previously-set `direction_2`
    functionally inert - a client toggling "two-direction" off never needs
    to null `direction_2` out explicitly, just stop sending `count_2 > 1`.
    `pattern_type` is never changed by an update (switching Rectangular
    <-> Circular is a delete+recreate, not an edit - mirrors
    `CreatePlaneFeatureUpdate`'s identical "construction method itself
    never changes" convention for `plane_type`).

    `skip_indices` (Phase 3) genuinely does need an omitted-vs-explicitly-
    cleared distinction, unlike `direction_2` above - `None` (omitted)
    leaves the Feature's current skip set untouched, `[]` explicitly
    un-skips every previously-skipped instance, the same `None`-vs-`[]`
    split `ExtrudeFeatureUpdate.target_body_ids` already establishes."""

    source_body_ids: list[str] | None = None
    source_feature_ids: list[str] | None = None
    direction_1: PatternDirectionRefSchema | None = None
    count_1: int | None = None
    spacing_1: float | None = None
    reverse_1: bool | None = None
    direction_2: PatternDirectionRefSchema | None = None
    count_2: int | None = None
    spacing_2: float | None = None
    reverse_2: bool | None = None
    axis: PatternAxisRefSchema | None = None
    count_angular: int | None = None
    angle_total: float | None = None
    reverse_angular: bool | None = None
    skip_indices: list[int] | None = None
    merge: MergeMode | None = None
    # Phase 8: mirrors `MirrorFeatureUpdate.tool_feature_id`'s own identical
    # omitted-vs-current convention (see that field's own doc comment).
    tool_feature_id: str | None = None


class PatternFeatureResponse(BaseModel):
    type: Literal["pattern"] = "pattern"
    id: str
    source_body_ids: list[str]
    source_feature_ids: list[str] = []
    pattern_type: PatternType
    direction_1: PatternDirectionRefSchema | None = None
    count_1: int
    spacing_1: float
    reverse_1: bool
    direction_2: PatternDirectionRefSchema | None = None
    count_2: int
    spacing_2: float
    reverse_2: bool
    axis: PatternAxisRefSchema | None = None
    count_angular: int
    angle_total: float
    reverse_angular: bool
    skip_indices: list[int]
    merge: MergeMode
    tool_feature_id: str | None = None
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # PatternFeature.
    produces: Produces


class ImportFeatureCreate(BaseModel):
    """Creates an ImportFeature (locked-in scope: import as a fixed,
    non-parametric Body) - `data_base64` is the uploaded file's own raw
    bytes, base64-encoded into the JSON body rather than a multipart
    upload, matching this API's existing all-JSON convention (no other
    endpoint here uses multipart) and mirroring how the native file format
    itself already carries binary-ish data as a plain JSON string."""

    source_format: ImportSourceFormat
    data_base64: str


class ImportFeatureResponse(BaseModel):
    type: Literal["import"] = "import"
    id: str
    source_format: ImportSourceFormat
    # The uploaded file's own byte count, for display purposes only - the
    # raw `source_data` itself is never echoed back (no client need for it,
    # and it can be large).
    source_byte_count: int
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for an
    # ImportFeature.
    produces: Produces


class GearFeatureCreate(BaseModel):
    """`docs/gear-design/02-gear-feature.md`: creates a `GearFeature` - an
    external or internal involute spur gear built straight from
    parameters, no backing SketchFeature (`00-conventions.md`'s "gear
    teeth are not Sketch entities" decision). `plane_ref` is a full
    `PlaneRefSchema` (same shape as `MirrorFeatureCreate.mirror_plane`),
    optional here - omitting it defaults to the fixed XY plane at the
    router (`app.document.router._default_plane_ref`), per that
    conventions doc's "always visible [to the client UI], never silently
    chosen" resolution: the *client* always shows and pre-fills XY rather
    than hiding the field, but the API itself stays forgiving of a
    caller/script that omits it entirely.

    `outer_diameter` is required when `is_internal` is True (the ring's
    own rim diameter), meaningless (and rejected) otherwise - see
    `app.document.router._validate_gear_feature_payload`. Boss/Cut +
    `target_body_ids` follow `ExtrudeFeatureCreate`'s exact convention.

    `helix_angle_degrees` (Workstream 4a, default `0.0`) and `herringbone`
    (default `False`) follow `GearFeature`'s own identical fields - see
    that dataclass's docstring for the full construction. `0.0`/`False`
    (the defaults) reproduce every pre-Workstream-4a gear byte-identically.

    `points_per_flank` (default `12`) follows `GearFeature.points_per_
    flank`'s own identical field - a lower value trades tooth-flank
    smoothness for a cheaper OCCT build, most useful for a helical/
    herringbone gear on modest hardware.

    `profile_shift` is optional - omitting it (`None`, the default)
    resolves at build time to whichever value (`0.0`, or a computed
    positive shift) keeps `tooth_count` clear of undercut
    (`app.document.gear.resolve_gear_profile_shift`) - same auto-or-
    override convention as `RackFeatureCreate.backing_height`/
    `BevelPairMemberSpecSchema.profile_shift`."""

    plane_ref: PlaneRefSchema | None = None
    gear_type: GearType
    is_internal: bool
    module: float
    tooth_count: int
    face_width: float
    pressure_angle_degrees: float = 20.0
    profile_shift: float | None = None
    backlash: float = 0.0
    root_fillet_radius: float = 0.0
    outer_diameter: float | None = None
    target_body_ids: list[str] = []
    helix_angle_degrees: float = 0.0
    herringbone: bool = False
    points_per_flank: int = 12


class GearFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `ExtrudeFeatureUpdate`/`MirrorFeatureUpdate` - including for
    `profile_shift`: omitting it (`None`) keeps the Feature's current value
    (which may itself be `None`, i.e. auto), the same "can't null a real
    value back out via Update" limitation every other Optional field here
    already has (e.g. `RackFeatureUpdate.backing_height`)."""

    plane_ref: PlaneRefSchema | None = None
    gear_type: GearType | None = None
    is_internal: bool | None = None
    module: float | None = None
    tooth_count: int | None = None
    face_width: float | None = None
    pressure_angle_degrees: float | None = None
    profile_shift: float | None = None
    backlash: float | None = None
    root_fillet_radius: float | None = None
    outer_diameter: float | None = None
    target_body_ids: list[str] | None = None
    helix_angle_degrees: float | None = None
    herringbone: bool | None = None
    points_per_flank: int | None = None


class GearFeatureResponse(BaseModel):
    type: Literal["gear"] = "gear"
    id: str
    plane_ref: PlaneRefSchema
    gear_type: GearType
    is_internal: bool
    module: float
    tooth_count: int
    face_width: float
    pressure_angle_degrees: float
    profile_shift: float | None = None
    backlash: float
    root_fillet_radius: float
    outer_diameter: float | None = None
    target_body_ids: list[str] = []
    helix_angle_degrees: float = 0.0
    herringbone: bool = False
    points_per_flank: int = 12
    # The *resolved* profile_shift (app.document.gear.resolve_gear_profile_
    # shift) - identical to profile_shift above when it's an explicit
    # value, but the actual computed number (not None) whenever that field
    # is left auto. Cheap (pure gear_math, no OCCT) to compute alongside
    # the response - lets the Gear Design screen show "Auto (0.65)" instead
    # of just "Auto". Mirrors BevelPairFeatureResponse.effective_profile_
    # shift_1/_2's own identical convention.
    effective_profile_shift: float
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # GearFeature.
    produces: Produces
    # Non-blocking - a requested root_fillet_radius that was silently
    # honoured-in-name-only (didn't converge, or unsupported on a
    # helical/herringbone tooth), or a resolved profile_shift that still
    # leaves tooth_count undercut (gear_math.undercut_warning) - see
    # app.document.gear.resolve_gear_from_bodies. Same convention as
    # LoftFeatureResponse.warnings/GearChainFeatureResponse.warnings below.
    warnings: list[str] = []


class RackFeatureCreate(BaseModel):
    """`docs/gear-design/03-rack.md`: creates a `RackFeature` - a standalone
    linear trapezoidal-tooth rack over `tooth_count` teeth, no backing
    SketchFeature (same "gear teeth are not Sketch entities" decision as
    `GearFeatureCreate`). `plane_ref` follows the identical optional/
    defaults-to-XY convention. `backing_height` is optional - omitting it
    (`None`) resolves to `2 * module` at build time
    (`app.document.gear_math.default_rack_backing_height`); a literal 0.0
    would silently produce a degenerate zero-area profile, so unlike the
    other numeric fields there is no plain-float default here. Boss/Cut +
    `target_body_ids` follow `ExtrudeFeatureCreate`'s exact convention."""

    plane_ref: PlaneRefSchema | None = None
    rack_type: RackType
    module: float
    tooth_count: int
    face_width: float
    pressure_angle_degrees: float = 20.0
    backlash: float = 0.0
    backing_height: float | None = None
    target_body_ids: list[str] = []


class RackFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `GearFeatureUpdate`."""

    plane_ref: PlaneRefSchema | None = None
    rack_type: RackType | None = None
    module: float | None = None
    tooth_count: int | None = None
    face_width: float | None = None
    pressure_angle_degrees: float | None = None
    backlash: float | None = None
    backing_height: float | None = None
    target_body_ids: list[str] | None = None


class RackFeatureResponse(BaseModel):
    type: Literal["rack"] = "rack"
    id: str
    plane_ref: PlaneRefSchema
    rack_type: RackType
    module: float
    tooth_count: int
    face_width: float
    pressure_angle_degrees: float
    backlash: float
    backing_height: float | None = None
    target_body_ids: list[str] = []
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # RackFeature.
    produces: Produces


class BevelGearFeatureCreate(BaseModel):
    """`docs/gear-design/10-bevel-gear.md`: creates a `BevelGearFeature` -
    a standalone straight bevel gear built straight from parameters, no
    backing SketchFeature (same "gear teeth are not Sketch entities"
    decision as `GearFeatureCreate`/`RackFeatureCreate`). `plane_ref`
    follows the identical optional/defaults-to-XY convention.
    `pitch_cone_angle_degrees` is required and direct - a standalone bevel
    gear has no meshing partner to derive it from (`11-bevel-pair.md`'s
    own future pairing system does that automatically). Boss/Cut +
    `target_body_ids` follow `GearFeatureCreate`'s exact convention."""

    plane_ref: PlaneRefSchema | None = None
    bevel_type: BevelGearType
    module: float
    tooth_count: int
    face_width: float
    pitch_cone_angle_degrees: float
    pressure_angle_degrees: float = 20.0
    backlash: float = 0.0
    profile_shift: float = 0.0
    target_body_ids: list[str] = []
    # See `GearFeatureCreate.points_per_flank`'s own docstring - identical
    # accuracy/build-cost tradeoff, applied to a bevel tooth's spherical-
    # involute flank instead of a planar involute one.
    points_per_flank: int = 12
    # docs/gear-design/12-spiral-bevel-gear.md - see BevelGearFeature's own
    # docstring for the "0.0 is a literal no-op" contract.
    spiral_angle_degrees: float = 0.0
    spiral_hand: SpiralBevelHand = SpiralBevelHand.RIGHT


class BevelGearFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `GearFeatureUpdate`/`RackFeatureUpdate`."""

    plane_ref: PlaneRefSchema | None = None
    bevel_type: BevelGearType | None = None
    module: float | None = None
    tooth_count: int | None = None
    face_width: float | None = None
    pitch_cone_angle_degrees: float | None = None
    pressure_angle_degrees: float | None = None
    backlash: float | None = None
    profile_shift: float | None = None
    target_body_ids: list[str] | None = None
    points_per_flank: int | None = None
    spiral_angle_degrees: float | None = None
    spiral_hand: SpiralBevelHand | None = None


class BevelGearFeatureResponse(BaseModel):
    type: Literal["bevel_gear"] = "bevel_gear"
    id: str
    plane_ref: PlaneRefSchema
    bevel_type: BevelGearType
    module: float
    tooth_count: int
    face_width: float
    pitch_cone_angle_degrees: float
    pressure_angle_degrees: float
    backlash: float
    profile_shift: float
    target_body_ids: list[str] = []
    points_per_flank: int = 12
    spiral_angle_degrees: float = 0.0
    spiral_hand: SpiralBevelHand = SpiralBevelHand.RIGHT
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # BevelGearFeature.
    produces: Produces
    # Non-blocking - face-width-vs-cone-distance, per-flank fold-risk, and
    # assembled-solid sanity warnings (app.document.bevel.resolve_bevel_
    # gear_from_bodies's own second return value). Same convention as
    # GearFeatureResponse.warnings/LoftFeatureResponse.warnings.
    warnings: list[str] = []


class BevelPairMemberSpecSchema(BaseModel):
    """The wire counterpart to `app.document.models.BevelPairMemberSpec` -
    the legitimately-differing per-member fields only (see that
    dataclass's own docstring for why every other bevel pair dimension is
    flat on `BevelPairFeatureCreate` instead). `profile_shift` is optional -
    omitting it (`None`, the default) resolves at build time to whichever
    value (`0.0`, or a computed negative shift) keeps this member's own
    tooth clear of the other member's material (`app.document.bevel_pair.
    resolve_member_profile_shifts`) - same auto-or-override convention as
    `RackFeatureCreate.backing_height`. `spiral_hand` mirrors `BevelGear
    FeatureCreate.spiral_hand` - see `app.document.models.BevelPairMember
    Spec.spiral_hand`'s own docstring for why hand is per-member while
    `BevelPairFeatureCreate.spiral_angle_degrees` is shared."""

    tooth_count: int
    profile_shift: float | None = None
    spiral_hand: SpiralBevelHand = SpiralBevelHand.RIGHT


class BevelPairFeatureCreate(BaseModel):
    """`docs/gear-design/11-bevel-pair.md`: creates a `BevelPairFeature` -
    two apex-aligned mating bevel gears, exactly 2 members
    (`member_1`/`member_2`), no backing SketchFeature (same "gear teeth
    are not Sketch entities" decision as `BevelGearFeatureCreate`).
    `plane_ref` follows the identical optional/defaults-to-XY convention.
    Cone angles are **not** accepted here - they're auto-derived from both
    members' own tooth counts plus `shaft_angle_degrees` (`app.document.
    bevel_pair.resolve_bevel_pair_from_bodies`), the whole point of
    automated live bevel pairing vs. `BevelGearFeatureCreate`'s own direct
    `pitch_cone_angle_degrees` field. No `target_body_ids`/Boss-Cut `mode`
    at all - a pair always mints two brand-new Bodies (see `BevelPairFeature`'s
    own docstring). `spiral_angle_degrees` (default `0.0`, a literal no-op -
    see `BevelPairFeature`'s own docstring) is pair-level shared, not
    per-member - `BevelPairMemberSpecSchema.spiral_hand` is the per-member
    field instead."""

    plane_ref: PlaneRefSchema | None = None
    module: float
    member_1: BevelPairMemberSpecSchema
    member_2: BevelPairMemberSpecSchema
    face_width: float
    pressure_angle_degrees: float = 20.0
    shaft_angle_degrees: float = 90.0
    backlash: float = 0.0
    # See `BevelGearFeatureCreate.points_per_flank`'s own docstring -
    # applies to both members' own tooth flanks.
    points_per_flank: int = 12
    spiral_angle_degrees: float = 0.0


class BevelPairFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `BevelGearFeatureUpdate`."""

    plane_ref: PlaneRefSchema | None = None
    module: float | None = None
    member_1: BevelPairMemberSpecSchema | None = None
    member_2: BevelPairMemberSpecSchema | None = None
    face_width: float | None = None
    pressure_angle_degrees: float | None = None
    shaft_angle_degrees: float | None = None
    backlash: float | None = None
    points_per_flank: int | None = None
    spiral_angle_degrees: float | None = None


class BevelPairFeatureResponse(BaseModel):
    type: Literal["bevel_pair"] = "bevel_pair"
    id: str
    plane_ref: PlaneRefSchema
    module: float
    member_1: BevelPairMemberSpecSchema
    member_2: BevelPairMemberSpecSchema
    face_width: float
    pressure_angle_degrees: float
    shaft_angle_degrees: float
    backlash: float
    points_per_flank: int = 12
    spiral_angle_degrees: float = 0.0
    # The *resolved* profile_shift for each member (app.document.bevel_
    # pair.resolve_member_profile_shifts) - identical to member_1/member_2's
    # own profile_shift when it's an explicit value, but the actual
    # computed number (not None) whenever that field is left auto. Cheap
    # (pure math, no OCCT) to compute alongside the response - lets the
    # Gear Design screen show "Auto (-0.52)" instead of just "Auto".
    effective_profile_shift_1: float
    effective_profile_shift_2: float
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # BevelPairFeature.
    produces: Produces
    # Non-blocking - face-width-vs-cone-distance, per-flank fold-risk, and
    # assembled-solid sanity warnings, one set per member (label-prefixed -
    # see app.document.bevel_pair.resolve_bevel_pair_from_bodies's own
    # second return value). Same convention as BevelGearFeatureResponse.warnings.
    warnings: list[str] = []


class LoftSectionSchema(BaseModel):
    """`docs/gear-design/04-helical-herringbone-loft.md` (4b): the wire
    counterpart to `app.document.models.LoftSection` - see that dataclass's
    own docstring for `reference_point`'s alignment semantics and
    `alignment_point`'s own, separate translation semantics."""

    sketch_feature_id: str
    profile_refs: list[SketchEntityRefSchema] = []
    reference_point: SketchEntityRefSchema | None = None
    alignment_point: SketchEntityRefSchema | None = None


class LoftFeatureCreate(BaseModel):
    """Creates a `LoftFeature` lofting between `sections` (2+ required - see
    `app.document.router._validate_loft_sections`) via `BRepOffsetAPI_
    ThruSections`. Boss/Cut + `target_body_ids` follow `SweepFeatureCreate`'s
    exact convention. `thickness`, if set (see `app.document.router.
    _validate_loft_thickness`), switches every section from a closed Profile
    to a single open chain and thickens the resulting lofted shell by this
    signed value instead of lofting directly into a solid - see
    `LoftFeature`'s own docstring. `guide_curve_refs`, if set (see
    `app.document.router._validate_loft_guide_curve_refs`), is the same
    ordered, cross-Sketch Line/Arc/Ellipse/Spline chain shape as
    `SweepFeatureCreate.path_refs` - see `LoftFeature.guide_curve_refs`'s
    own docstring for what it does here."""

    sections: list[LoftSectionSchema]
    mode: LoftMode
    ruled: bool = False
    target_body_ids: list[str] = []
    thickness: float | None = None
    guide_curve_refs: list[SketchEntityRefSchema] = []


class LoftFeatureUpdate(BaseModel):
    """Partial update for live-preview re-solves, same omitted-vs-current-
    value convention as `SweepFeatureUpdate` - including for `thickness`:
    omitting it (`None`) keeps the Feature's current value (which may
    itself be `None`, i.e. closed-profile mode), the same "can't null a
    real value back out via Update" limitation every other Optional field
    here already has (e.g. `RackFeatureUpdate.backing_height`). `guide_
    curve_refs` follows the same convention: `None` (the default) keeps
    whatever the Feature already has; passing `[]` explicitly clears it
    back to "no guide curve" (an empty list is itself a real, meaningful
    value here, unlike a bare omission)."""

    sections: list[LoftSectionSchema] | None = None
    mode: LoftMode | None = None
    ruled: bool | None = None
    target_body_ids: list[str] | None = None
    thickness: float | None = None
    guide_curve_refs: list[SketchEntityRefSchema] | None = None


class LoftFeatureResponse(BaseModel):
    type: Literal["loft"] = "loft"
    id: str
    sections: list[LoftSectionSchema]
    mode: LoftMode
    ruled: bool
    target_body_ids: list[str] = []
    thickness: float | None = None
    guide_curve_refs: list[SketchEntityRefSchema] = []
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # LoftFeature.
    produces: Produces
    # `docs/gear-design/04-helical-herringbone-loft.md`'s own Result 2
    # finding: a real, best-effort geometric self-intersection check
    # (`app.document.loft._mid_section_warnings`) - non-blocking, per
    # `00-conventions.md`'s validation-banner convention (empty for the
    # common, non-self-intersecting case).
    warnings: list[str] = []


class GearGroupSchema(BaseModel):
    """`docs/gear-design/05-gear-chain-and-planetary.md`: the wire
    counterpart to `app.document.models.GearGroup` - see that dataclass's
    own docstring."""

    id: str
    module: float
    pressure_angle_degrees: float = 20.0
    display_color: str | None = None


class GearChainMemberSpecSchema(BaseModel):
    """The wire counterpart to `app.document.models.GearChainMemberSpec`."""

    member_type: GearChainMemberType
    group_id: str
    tooth_count: int
    face_width: float
    outer_diameter: float | None = None


class GearChainStageSchema(BaseModel):
    """The wire counterpart to `app.document.models.GearChainStage` - see
    that dataclass's own docstring for the single-vs-compound discriminated-
    union shape and the a/b=incoming/outgoing compound convention."""

    turn_angle_degrees: float = 0.0
    member: GearChainMemberSpecSchema | None = None
    compound_member_a: GearChainMemberSpecSchema | None = None
    compound_member_b: GearChainMemberSpecSchema | None = None
    compound_axial_offset: float = 0.0
    compound_merge: MergeMode = MergeMode.FUSE_INTO_ONE


class GearChainFeatureCreate(BaseModel):
    """`docs/gear-design/05-gear-chain-and-planetary.md`: creates a
    `GearChainFeature` - an ordered list of N>=2 meshing `stages`, no
    backing SketchFeature (same "gear teeth are not Sketch entities"
    decision as `GearFeatureCreate`). `plane_ref` follows the identical
    optional/defaults-to-XY convention. No `target_body_ids`/Boss-Cut
    `mode` at all - a chain always mints brand-new Bodies (see
    `GearChainFeature`'s own docstring)."""

    plane_ref: PlaneRefSchema | None = None
    groups: list[GearGroupSchema]
    stages: list[GearChainStageSchema]
    start_direction_degrees: float = 0.0
    print_clearance_margin: float = 0.2


class GearChainFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `GearFeatureUpdate`."""

    plane_ref: PlaneRefSchema | None = None
    groups: list[GearGroupSchema] | None = None
    stages: list[GearChainStageSchema] | None = None
    start_direction_degrees: float | None = None
    print_clearance_margin: float | None = None


class GearChainFeatureResponse(BaseModel):
    type: Literal["gear_chain"] = "gear_chain"
    id: str
    plane_ref: PlaneRefSchema
    groups: list[GearGroupSchema]
    stages: list[GearChainStageSchema]
    start_direction_degrees: float
    print_clearance_margin: float
    locked: bool
    produces: Produces
    # Non-blocking interference/compound-join findings from `app.document.
    # gear_chain.resolve_gear_chain` - same "known only at create/update
    # time, re-resolved live for a GET" treatment `LoftFeatureResponse.
    # warnings` already gets (see `app.document.router._gear_chain_
    # feature_response`).
    warnings: list[str] = []


class PlanetaryGearFeatureCreate(BaseModel):
    """`docs/gear-design/05-gear-chain-and-planetary.md`: creates a
    `PlanetaryGearFeature` - sun/ring tooth counts are free inputs, planet
    tooth count is derived (not accepted here at all). No `GearGroup`
    concept (one shared `module`/`pressure_angle_degrees` directly on this
    schema - see that Feature's own docstring for why). `ring_outer_
    diameter` is always required (a ring is always present, unlike
    `GearFeatureCreate.outer_diameter`'s internal-only conditional
    requirement)."""

    plane_ref: PlaneRefSchema | None = None
    module: float
    sun_tooth_count: int
    ring_tooth_count: int
    planet_count: int
    face_width: float
    ring_outer_diameter: float
    pressure_angle_degrees: float = 20.0


class PlanetaryGearFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `GearFeatureUpdate`."""

    plane_ref: PlaneRefSchema | None = None
    module: float | None = None
    sun_tooth_count: int | None = None
    ring_tooth_count: int | None = None
    planet_count: int | None = None
    face_width: float | None = None
    ring_outer_diameter: float | None = None
    pressure_angle_degrees: float | None = None


class PlanetaryGearFeatureResponse(BaseModel):
    type: Literal["planetary_gear"] = "planetary_gear"
    id: str
    plane_ref: PlaneRefSchema
    module: float
    sun_tooth_count: int
    ring_tooth_count: int
    planet_count: int
    face_width: float
    ring_outer_diameter: float
    pressure_angle_degrees: float
    locked: bool
    produces: Produces


class JobCreateResponse(BaseModel):
    """`docs/lod-strategy/02-phase2-design.md` SS4: returned immediately by
    a job-mode create endpoint, before the real build has even started -
    genuinely different shape from the matching synchronous `*Response`
    (no resolved geometry/warnings yet), the reason job-mode is a separate
    route rather than a query flag on the existing synchronous one. Shared
    by every job-mode Feature type (`BevelPairFeature`, `PlanetaryGear
    Feature` - LOD Phase 2 chunks 2/3) - this immediate-acknowledgment
    shape never varies by Feature type, so one schema serves all of them
    rather than one per-type duplicate (originally `BevelPairJobCreate
    Response`, generalized here when a second Feature type gained job
    mode)."""

    job_id: str
    status: Literal["running"] = "running"


class JobStatusResponse(BaseModel):
    """`GET /parts/{part_id}/jobs/{job_id}` - shared by every job-mode
    Feature type (originally `BevelPairJobStatusResponse`, generalized when
    `PlanetaryGearFeature` gained job mode too). `result` is only ever set
    once `status == "succeeded"`, and is then the *exact same* response
    shape the matching synchronous create endpoint returns for that job's
    own Feature type (`BevelPairFeatureResponse` or `PlanetaryGearFeature
    Response` - `app.document.router`'s own poll handler dispatches on the
    job's actual Feature type, not this schema), so client result-handling
    code for a given Feature type doesn't need a second code path just
    because the fetch was async. `error` is only ever set once `status ==
    "failed"`, carrying the same structured `{"type": ..., "detail": ...}`
    shape every other structured validation error in this codebase already
    uses."""

    job_id: str
    status: Literal["running", "succeeded", "failed", "cancelled"]
    result: BevelPairFeatureResponse | PlanetaryGearFeatureResponse | None = None
    error: dict | None = None


class JobCancelResponse(BaseModel):
    """Returned by `POST /parts/{part_id}/jobs/{job_id}/cancel` - shared by
    every job-mode Feature type (originally `BevelPairJobCancelResponse`).
    `status` may still read `"running"` immediately after this call (the
    kill request was issued, but the background build thread hasn't
    necessarily noticed and finished yet) - poll `GET .../jobs/{job_id}` to
    observe the actual transition to `"cancelled"`."""

    job_id: str
    status: Literal["running", "succeeded", "failed", "cancelled"]


class GearPreviewChainRequest(BaseModel):
    """`GearPreviewRequest.chain` - reuses `GearGroupSchema`/
    `GearChainStageSchema` verbatim (the same shape `GearChainFeatureCreate`
    itself uses) rather than a parallel duplicate schema set, since the
    preview payload needs to be structurally identical to the real Feature
    payload for everything but `plane_ref` anyway."""

    groups: list[GearGroupSchema]
    stages: list[GearChainStageSchema]
    start_direction_degrees: float = 0.0
    print_clearance_margin: float = 0.2


class GearPreviewPlanetaryRequest(BaseModel):
    """`GearPreviewRequest.planetary` - mirrors `PlanetaryGearFeatureCreate`
    minus `plane_ref`."""

    module: float
    sun_tooth_count: int
    ring_tooth_count: int
    planet_count: int
    face_width: float
    ring_outer_diameter: float
    pressure_angle_degrees: float = 20.0


class GearPreviewMember(BaseModel):
    """One resolved chain/planetary member's own outline + reference-circle
    numbers, for the preview canvas to draw directly - same "no client-side
    gear math" principle `GearPreviewResponse.outline_points` already
    establishes for the single-gear case, just repeated once per member.
    `outline_points`/`center` are already translated (and, for a rack,
    rotated - `app.document.gear_chain._rack_rotation`'s own convention)
    into the chain/assembly's own local 2D frame, so the client applies no
    further per-member transform - only the shared screen-space scale/pan
    every preview canvas already does."""

    stage_index: int
    label: str
    member_type: Literal["external", "internal", "rack"]
    group_id: str | None = None
    display_color: str | None = None
    center: tuple[float, float]
    outline_points: list[tuple[float, float]]
    pitch_radius: float | None = None
    base_radius: float | None = None
    addendum_radius: float | None = None
    dedendum_radius: float | None = None
    outer_radius: float | None = None


class GearPreviewInterferenceFinding(BaseModel):
    """The wire counterpart to `app.document.gear_chain_math.
    InterferenceFinding` - see that dataclass's own docstring."""

    stage_index_a: int
    member_label_a: str
    stage_index_b: int
    member_label_b: str
    gap: float
    kind: Literal["overlap", "clearance"]


class GearPreviewLink(BaseModel):
    """One meshing relationship's ratio/rotation-direction summary - the
    wire counterpart to `app.document.gear_chain_math.LinkRatio`, plus
    which stage(s) it connects. `kind == "mesh"` is an ordinary link
    between two adjacent stages (`from_stage_index`/`to_stage_index` differ
    by 1, `mesh_link_ratio`'s own result); `kind == "compound"` is a
    compound stage's own internal a->b transition (`from_stage_index ==
    to_stage_index`, `compound_transition_ratio`'s own display-only ratio -
    see that function's docstring for why it is not folded into
    `GearPreviewChainResult.overall_ratio`)."""

    from_stage_index: int
    to_stage_index: int
    kind: Literal["mesh", "compound"]
    ratio: float | None = None
    reverses_direction: bool
    linear_mm_per_revolution: float | None = None


class GearPreviewChainResult(BaseModel):
    members: list[GearPreviewMember]
    interference_findings: list[GearPreviewInterferenceFinding]
    links: list[GearPreviewLink]
    # `app.document.gear_chain_math.chain_overall_ratio` - null when any
    # link in the chain is a rack link (no single well-defined angular
    # ratio spans it - see that function's own docstring).
    overall_ratio: float | None = None


class GearPreviewPlanetaryResult(BaseModel):
    members: list[GearPreviewMember]
    # Sun/planet and planet/ring are the two independently meaningful mesh
    # ratios for a planetary set (no single "overall ratio" the way a chain
    # has one, since planetary output depends on which member is held
    # fixed - out of scope here, same static/positioned-only scope
    # `PlanetaryGearFeature` itself has).
    sun_to_planet_ratio: float | None = None
    planet_to_ring_ratio: float | None = None


class GearPreviewBevelGearRequest(BaseModel):
    """`GearPreviewRequest.bevel_gear` - mirrors `BevelGearFeatureCreate`
    minus `plane_ref`/`bevel_type`/`target_body_ids` (positioning and
    Boss/Cut mode don't matter for a preview - see `GearPreviewRequest`'s
    own docstring)."""

    module: float
    tooth_count: int
    face_width: float
    pitch_cone_angle_degrees: float
    pressure_angle_degrees: float = 20.0
    backlash: float = 0.0
    profile_shift: float = 0.0


class GearPreviewBevelPairMemberRequest(BaseModel):
    """The wire counterpart to `app.document.models.BevelPairMemberSpec` -
    see `BevelPairMemberSpecSchema`'s own docstring for why only these two
    fields legitimately differ per member, and for the `profile_shift`
    auto-or-override convention (mirrored here so a preview matches what
    Create would actually produce). `spiral_hand` mirrors `BevelPairMember
    SpecSchema.spiral_hand` - included here (cheap, pure math) so the
    live preview can surface `bevel_math.spiral_hand_mismatch_warning`
    before Create, even though the preview's own axial-cross-section
    envelope can't show spiral curvature itself (`12-spiral-bevel-gear.md`'s
    own "Preview stays unchanged" finding, unaffected by this)."""

    tooth_count: int
    profile_shift: float | None = None
    spiral_hand: SpiralBevelHand = SpiralBevelHand.RIGHT


class GearPreviewBevelPairRequest(BaseModel):
    """`GearPreviewRequest.bevel_pair` - mirrors `BevelPairFeatureCreate`
    minus `plane_ref`. Cone angles are not accepted here either - like the
    real Feature, they're auto-derived from both members' own tooth counts
    plus `shaft_angle_degrees` (`app.document.bevel_math.pitch_cone_half_
    angles`). `spiral_angle_degrees` is shared, mirroring `BevelPairFeature
    Create`'s own field."""

    module: float
    member_1: GearPreviewBevelPairMemberRequest
    member_2: GearPreviewBevelPairMemberRequest
    face_width: float
    pressure_angle_degrees: float = 20.0
    shaft_angle_degrees: float = 90.0
    backlash: float = 0.0
    spiral_angle_degrees: float = 0.0


class GearPreviewBevelMember(BaseModel):
    """One bevel gear's axial cross-section schematic - `10-bevel-gear.md`'s
    own point: a bevel tooth has no flat 2D cut profile at all (its flank
    is a curved surface on a cone), so unlike every other `gear_kind` this
    is *not* a tooth outline. It's the standard bevel-drafting side-view
    envelope instead: the symmetric (about the member's own axis) closed
    shape bounded by the face cone (addendum) and root cone (dedendum)
    generators, between the inner (front) and outer (back) cone distances
    - exactly what a bevel gear catalog/engineering drawing shows for an
    at-a-glance size/proportion reference. `pitch_line` (one reference
    segment, the "upper" half only - the outline itself is already
    symmetric) is the pitch cone generator between the same two cone
    distances.

    `outline_points`/`pitch_line` are in the shared preview's local 2D
    frame: the apex at the origin, this member's own axis pointing along
    `axis_angle_degrees` from local +x (`0` for a standalone bevel gear or
    a pair's `member_1`; `shaft_angle_degrees` for a pair's `member_2` -
    `11-bevel-pair.md`'s own apex-aligned, dual-axis positioning, projected
    into this 2D schematic - both members' apexes coincide at the origin,
    same as their real 3D cone apexes)."""

    label: str  # "single" | "member_1" | "member_2"
    axis_angle_degrees: float
    outline_points: list[tuple[float, float]]
    pitch_line: tuple[tuple[float, float], tuple[float, float]]
    pitch_cone_angle_degrees: float
    cone_distance: float
    inner_cone_distance: float
    pitch_radius: float
    face_width: float
    # The actual profile_shift this schematic was built with - for a
    # standalone bevel gear, identical to the request's own plain float;
    # for a bevel pair member, the *resolved* value (`app.document.bevel_
    # pair.resolve_member_profile_shifts`'s own output) whenever the
    # request left it `None` (auto) - lets the Gear Design screen show the
    # live-computed number next to "Auto" instead of just the word alone.
    effective_profile_shift: float


class BevelPairMeshPreviewResult(BaseModel):
    """`bevel_math.BevelPairMeshPreview`'s wire counterpart - a handful of
    consecutive teeth from each member, meshing as Tredgold's virtual flat
    spur gears predict, for a "picture in picture" close-up inset next to
    the existing axial-cross-section schematic (`GearPreviewBevelMember`,
    which draws each member's drafting-style envelope only, never a real
    tooth). Both `*_teeth` lists are already positioned/rotated into one
    shared local 2D frame (`center_1`/`center_2` on the x-axis, tangent at
    the origin) - a client draws them directly, no gear math of its own."""

    member_1_teeth: list[list[tuple[float, float]]]
    member_2_teeth: list[list[tuple[float, float]]]
    center_1: tuple[float, float]
    center_2: tuple[float, float]
    pitch_radius_1: float
    pitch_radius_2: float


class GearPreviewBevelPairResult(BaseModel):
    members: list[GearPreviewBevelMember]
    shaft_angle_degrees: float
    mesh_preview: BevelPairMeshPreviewResult


class GearPreviewRequest(BaseModel):
    """`docs/gear-design/08-entry-screen-and-preview.md`: the cheap
    `/gear/preview` endpoint's request - runs only `gear_math`/`gear_chain_
    math`, no OCCT, so it's cheap enough to call on every debounced
    keystroke while the entry screen's form is still being edited.
    `gear_kind` is the discriminator (`"external"`/`"internal"`/`"rack"`
    for a single `GearFeature`/`RackFeature`-shaped preview, `"chain"`/
    `"planetary"` for `GearChainFeature`/`PlanetaryGearFeature`'s own
    multi-gear preview via the nested `chain`/`planetary` payloads below,
    `"bevel_gear"`/`"bevel_pair"` for `BevelGearFeature`/`BevelPairFeature`'s
    own axial-cross-section schematic via the nested `bevel_gear`/
    `bevel_pair` payloads - a future gear type still adds one more literal
    value here plus a new branch in `app.document.router._gear_preview_
    response`, not a new endpoint, per this field's own original design).

    Deliberately excludes anything `plane_ref`/positioning-related (the
    preview is always drawn in its own local 2D frame, centred on the
    origin - positioning only matters once "Create" builds the real
    Feature) and `root_fillet_radius` (cosmetic only at the OCCT
    construction stage - `gear_math.tooth_profile_points` never uses it,
    so it has no effect on this endpoint's own output)."""

    gear_kind: Literal["external", "internal", "rack", "chain", "planetary", "bevel_gear", "bevel_pair"]
    # Required for gear_kind in ("external", "internal", "rack"); unused
    # (and ignored) for "chain"/"planetary", which carry their own nested
    # `chain`/`planetary` payload below instead - widened from a plain
    # required field so a single-gear kind's blank/irrelevant value doesn't
    # need a placeholder just to satisfy the schema.
    module: float | None = None
    tooth_count: int | None = None
    pressure_angle_degrees: float = 20.0
    # Only for "external"/"internal" (meaningless/ignored otherwise, same
    # as module/tooth_count above) - None (the default) means "auto", same
    # `GearFeatureCreate.profile_shift` convention, so a live preview
    # matches what Create would actually produce.
    profile_shift: float | None = None
    backlash: float = 0.0
    # Required when gear_kind == "internal" (the ring's own rim diameter),
    # meaningless otherwise - same rule as `GearFeatureCreate.outer_diameter`.
    outer_diameter: float | None = None
    # Rack only; None resolves to `default_rack_backing_height(module)`,
    # same convention as `RackFeatureCreate.backing_height`.
    backing_height: float | None = None
    # Required when gear_kind == "chain"/"planetary" respectively -
    # `08-entry-screen-and-preview.md`'s "Chain/planetary/bevel-pair
    # preview" extension. Each mirrors its real Feature's own Create schema
    # minus `plane_ref` (the preview always draws in its own local frame,
    # same convention the single-gear fields above already document).
    chain: GearPreviewChainRequest | None = None
    planetary: GearPreviewPlanetaryRequest | None = None
    # Required when gear_kind == "bevel_gear"/"bevel_pair" respectively -
    # same nested-payload convention as chain/planetary above.
    bevel_gear: GearPreviewBevelGearRequest | None = None
    bevel_pair: GearPreviewBevelPairRequest | None = None


class GearPreviewResponse(BaseModel):
    """`outline_points` is the full 2D tooth-outline polyline (world/local
    frame, gear or rack centred on the origin) for the live preview canvas
    to draw directly. The rest are the reference-circle overlay's own
    numbers - `pitch_radius`/`base_radius`/`addendum_radius`/
    `dedendum_radius`/`outer_radius` for `"external"`/`"internal"` (a rack
    has no such circles, so these stay null for `gear_kind == "rack"`);
    `pitch_line_y`/`addendum_line_y`/`dedendum_line_y`/`rack_length` for
    `"rack"` instead (null for the two gear kinds). `warnings` carries every
    non-blocking `gear_math` validation (currently just undercut risk) per
    `00-conventions.md`'s validation-banner convention - a `GearGeometryError`
    with no valid geometry at all raises a 422 instead of landing here at
    all, matching that same doc's stated blocking exception.

    `chain`/`planetary` are populated only for the matching `gear_kind`
    (null otherwise, mirroring `outline_points`/`pitch_radius`/etc.'s own
    kind-conditional nullability above) - `GearPreviewChainResult`/
    `GearPreviewPlanetaryResult`'s own multi-member payload, per
    `08-entry-screen-and-preview.md`'s "Chain/planetary/bevel-pair preview"
    extension. `outline_points` and the single-gear reference-circle fields
    all stay null for these two kinds - there is no one outline/circle set
    for a multi-member preview, only each member's own (see
    `GearPreviewMember`)."""

    gear_kind: Literal["external", "internal", "rack", "chain", "planetary", "bevel_gear", "bevel_pair"]
    outline_points: list[tuple[float, float]] = []
    pitch_radius: float | None = None
    base_radius: float | None = None
    addendum_radius: float | None = None
    dedendum_radius: float | None = None
    outer_radius: float | None = None
    pitch_line_y: float | None = None
    addendum_line_y: float | None = None
    dedendum_line_y: float | None = None
    rack_length: float | None = None
    # Populated only for "external"/"internal" - the *resolved*
    # profile_shift (app.document.gear.resolve_gear_profile_shift), same
    # "identical to the request's own explicit value, or the live-computed
    # auto one" convention as GearPreviewBevelMember.effective_profile_
    # shift. Null for every other gear_kind, mirroring pitch_radius/etc.'s
    # own kind-conditional nullability above.
    effective_profile_shift: float | None = None
    warnings: list[str] = []
    chain: GearPreviewChainResult | None = None
    planetary: GearPreviewPlanetaryResult | None = None
    # Populated only for "bevel_gear" (one member, label "single") -
    # `GearPreviewBevelMember`'s own axial-cross-section schematic.
    bevel_gear: GearPreviewBevelMember | None = None
    # Populated only for "bevel_pair" (two members, `11-bevel-pair.md`'s
    # own dual-axis apex-aligned positioning projected into 2D).
    bevel_pair: GearPreviewBevelPairResult | None = None


FeatureResponse = Union[
    SketchFeatureResponse,
    ExtrudeFeatureResponse,
    CreatePlaneFeatureResponse,
    FilletFeatureResponse,
    ChamferFeatureResponse,
    RevolveFeatureResponse,
    SweepFeatureResponse,
    SurfaceFeatureResponse,
    MirrorFeatureResponse,
    MergeFeatureResponse,
    BooleanFeatureResponse,
    DeleteBodyFeatureResponse,
    DeleteFaceFeatureResponse,
    ScaleBodyFeatureResponse,
    MoveBodyFeatureResponse,
    MoveFaceFeatureResponse,
    SplitFeatureResponse,
    PatternFeatureResponse,
    ImportFeatureResponse,
    GearFeatureResponse,
    RackFeatureResponse,
    LoftFeatureResponse,
    BevelGearFeatureResponse,
    BevelPairFeatureResponse,
    GearChainFeatureResponse,
    PlanetaryGearFeatureResponse,
]
"""Pre-existing bug fix (found while verifying LOD Phase 2 chunk 3's own new
`PlanetaryGearFeature` job-mode tests): `GearChainFeatureResponse`/`Planetary
GearFeatureResponse` both existed as real response schemas (`_feature_
response`'s own dispatch in `app.document.router` already builds them
correctly) but were never added to this Union - so `GET /parts/{part_id}/
features` (and anything else typed `list[FeatureResponse]`) 500s with a
`ResponseValidationError` for ANY Part containing a `GearChainFeature` or
`PlanetaryGearFeature`, unconditionally, regardless of job mode. Reproduced
directly against `main` (pre-dating this session's own changes entirely) -
a plain synchronous `POST .../planetary-gear-features` followed by `GET
.../features` 500s the identical way. Never caught before because no prior
test exercised `GET /features` for either of these two Feature types."""


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
    # Bug fix (on-device feedback: "create plane"/"new sketch on face" are
    # offered for a curved face, which can't actually be used with either -
    # see app.document.mesh_data.MeshData's own `face_is_planar` doc
    # comment): per-face planarity, same dense one-entry-per-face shape as
    # `face_edge_ids` above. Defaults to [] for the same backward-
    # compatibility reason as every other id list here.
    face_is_planar: list[bool] = []


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
    hide yet at that point.

    `is_surface` distinguishes a `SurfaceFeature`'s own non-solid shell from
    a real solid Body within this same array - both come back tagged
    `source="computed"` (they're both real, tessellated `compute_part_
    bodies` output), so the client needs this to keep a Surface out of the
    Build Tree's Bodies section (and the viewport's own body-selection
    lists), showing it only under Surfaces instead. `False` for every solid
    Body and for `source="placeholder"`.

    `source="coarse"` (`docs/lod-strategy/01-design.md`) is a real but
    deliberately low-fidelity OCCT solid - a plain cylinder/cone standing in
    for a Gear/BevelGear/BevelPair/GearChain/PlanetaryGear Feature's own
    full construction - returned only when `GET /mesh`'s own `tier=coarse`
    query parameter is set, or by a coarse-preview endpoint for a not-yet-
    created Feature payload. Never persisted, never an input to any
    Boolean/Boss/Cut resolution - purely a rendering-layer stand-in for the
    real geometry `source="computed"` always represents."""

    body_id: str
    source: Literal["placeholder", "computed", "coarse"]
    mesh: MeshVertexData
    hidden: bool = False
    is_surface: bool = False


class NativeImportResponse(BaseModel):
    """What `POST /document/import/native` hands back once the full-replace
    import succeeds - just enough for the client to confirm the new state
    (which Parts now exist) without re-fetching, mirroring
    `CascadeDeleteResponse`'s own "confirm what just happened" purpose."""

    document_id: str
    part_ids: list[str]


class CascadeDeleteResponse(BaseModel):
    """What got deleted by a cascade-delete: the target Feature and every
    Feature that actually transitively depends on it per the real
    dependency graph (B2) - not "every Feature after it in the list", a
    stale pre-B2 description this docstring itself used to carry (on-device
    feedback: the client's own confirmation dialog had the identical stale
    assumption baked in, see `CascadeDeletePreviewResponse` below for the
    fix) - plus the Sketch each deleted SketchFeature owned, in deletion
    order, so a client can confirm the backend's view matches what it just
    asked for (or refresh from it directly)."""

    deleted_feature_ids: list[str]
    deleted_sketch_ids: list[str]


class CascadeDeletePreviewResponse(BaseModel):
    """On-device feedback: a client confirming a cascade delete needs to
    show the user exactly which Features will go *before* they commit -
    the delete endpoint itself is the only place that ran `transitive_
    dependents` previously, so the client's own confirmation dialog had
    fallen back to the stale pre-B2 "every Feature after this one in the
    list" assumption instead. This is a read-only preview of the exact
    same `transitive_dependents(build_feature_graph(part), feature_id)`
    computation `delete_feature_cascade` itself performs, in `part.
    features`' own natural order, mutating nothing."""

    feature_ids: list[str]
