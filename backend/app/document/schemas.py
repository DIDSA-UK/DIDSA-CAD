from typing import Literal, Union

from pydantic import BaseModel

from app.document.models import (
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
    (the defaults) reproduce every pre-Workstream-4a gear byte-identically."""

    plane_ref: PlaneRefSchema | None = None
    gear_type: GearType
    is_internal: bool
    module: float
    tooth_count: int
    face_width: float
    pressure_angle_degrees: float = 20.0
    profile_shift: float = 0.0
    backlash: float = 0.0
    root_fillet_radius: float = 0.0
    outer_diameter: float | None = None
    target_body_ids: list[str] = []
    helix_angle_degrees: float = 0.0
    herringbone: bool = False


class GearFeatureUpdate(BaseModel):
    """Partial update, same omitted-vs-current-value convention as
    `ExtrudeFeatureUpdate`/`MirrorFeatureUpdate`."""

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
    profile_shift: float
    backlash: float
    root_fillet_radius: float
    outer_diameter: float | None = None
    target_body_ids: list[str] = []
    helix_angle_degrees: float = 0.0
    herringbone: bool = False
    locked: bool
    # B1: see SketchFeatureResponse.produces above - always BODY for a
    # GearFeature.
    produces: Produces
    # Non-blocking - a requested root_fillet_radius that was silently
    # honoured-in-name-only (didn't converge, or unsupported on a
    # helical/herringbone tooth) - see app.document.gear.resolve_gear_
    # from_bodies. Same convention as LoftFeatureResponse.warnings/
    # GearChainFeatureResponse.warnings below.
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


class LoftSectionSchema(BaseModel):
    """`docs/gear-design/04-helical-herringbone-loft.md` (4b): the wire
    counterpart to `app.document.models.LoftSection` - see that dataclass's
    own docstring for `reference_point`'s alignment semantics."""

    sketch_feature_id: str
    profile_refs: list[SketchEntityRefSchema] = []
    reference_point: SketchEntityRefSchema | None = None


class LoftFeatureCreate(BaseModel):
    """Creates a `LoftFeature` lofting between `sections` (2+ required - see
    `app.document.router._validate_loft_sections`) via `BRepOffsetAPI_
    ThruSections`. Boss/Cut + `target_body_ids` follow `SweepFeatureCreate`'s
    exact convention."""

    sections: list[LoftSectionSchema]
    mode: LoftMode
    ruled: bool = False
    target_body_ids: list[str] = []


class LoftFeatureUpdate(BaseModel):
    """Partial update for live-preview re-solves, same omitted-vs-current-
    value convention as `SweepFeatureUpdate`."""

    sections: list[LoftSectionSchema] | None = None
    mode: LoftMode | None = None
    ruled: bool | None = None
    target_body_ids: list[str] | None = None


class LoftFeatureResponse(BaseModel):
    type: Literal["loft"] = "loft"
    id: str
    sections: list[LoftSectionSchema]
    mode: LoftMode
    ruled: bool
    target_body_ids: list[str] = []
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


class GearPreviewRequest(BaseModel):
    """`docs/gear-design/08-entry-screen-and-preview.md`: the cheap
    `/gear/preview` endpoint's request - runs only `gear_math`, no OCCT, so
    it's cheap enough to call on every debounced keystroke while the entry
    screen's form is still being edited. `gear_kind` is the discriminator
    (`"external"`/`"internal"`/`"rack"` today - the only two Feature types
    that exist yet, per this workstream's own scoped-down v1; a future
    gear type adds one more literal value here plus a new branch in
    `app.document.router._gear_preview_response`, not a new endpoint).

    Deliberately excludes anything `plane_ref`/positioning-related (the
    preview is always drawn in its own local 2D frame, centred on the
    origin - positioning only matters once "Create" builds the real
    Feature) and `root_fillet_radius` (cosmetic only at the OCCT
    construction stage - `gear_math.tooth_profile_points` never uses it,
    so it has no effect on this endpoint's own output)."""

    gear_kind: Literal["external", "internal", "rack"]
    module: float
    tooth_count: int
    pressure_angle_degrees: float = 20.0
    profile_shift: float = 0.0
    backlash: float = 0.0
    # Required when gear_kind == "internal" (the ring's own rim diameter),
    # meaningless otherwise - same rule as `GearFeatureCreate.outer_diameter`.
    outer_diameter: float | None = None
    # Rack only; None resolves to `default_rack_backing_height(module)`,
    # same convention as `RackFeatureCreate.backing_height`.
    backing_height: float | None = None


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
    all, matching that same doc's stated blocking exception."""

    gear_kind: Literal["external", "internal", "rack"]
    outline_points: list[tuple[float, float]]
    pitch_radius: float | None = None
    base_radius: float | None = None
    addendum_radius: float | None = None
    dedendum_radius: float | None = None
    outer_radius: float | None = None
    pitch_line_y: float | None = None
    addendum_line_y: float | None = None
    dedendum_line_y: float | None = None
    rack_length: float | None = None
    warnings: list[str] = []


FeatureResponse = Union[
    SketchFeatureResponse,
    ExtrudeFeatureResponse,
    CreatePlaneFeatureResponse,
    FilletFeatureResponse,
    ChamferFeatureResponse,
    RevolveFeatureResponse,
    SweepFeatureResponse,
    MirrorFeatureResponse,
    PatternFeatureResponse,
    ImportFeatureResponse,
    GearFeatureResponse,
    RackFeatureResponse,
    LoftFeatureResponse,
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
