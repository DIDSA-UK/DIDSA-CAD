"""AI Modelling workstream 3: the locked structured-plan schema, as real
Pydantic models - see docs/ai-modelling/03-structured-plan-schema.md for
the authoritative shape/rationale this file implements.

Every step names earlier steps by `local_id` (plan-local, never a real
backend id - nothing is created against the real backend until workstream
4's translator runs for real) rather than a real `SketchEntityRef`/
`SubShapeRef` - those types don't exist yet when a plan is authored, since
the Body/Sketch-entity they'd point at hasn't been created. Every field
that would hold a real ref/id in the corresponding `...FeatureCreate`
schema (`app.document.schemas`) instead holds a plan-local `local_id`
string (or list of them) here, under the *same field name* - so a field's
name always matches its real-schema counterpart; only the value's meaning
(local_id vs. real id) differs.

Client-side mirror: `client/lib/ai/ai_plan.dart` (parsing/display only, not
re-validated there - see that file's own doc comment). System-prompt
vocabulary reference: `client/lib/ai/ai_scoping_prompt.dart`, a hand-
maintained copy of this file's shape per `docs/ai-modelling/02-scoping-
conversation.md`'s own maintenance note - a field or `kind` added here
needs a matching manual update in both, or they silently drift.
"""

from enum import Enum
from typing import Annotated, Literal, Union

from pydantic import BaseModel, ConfigDict, Field

from app.document.models import (
    BooleanOperation,
    ExtrudeType,
    FixedAxis,
    LoftMode,
    MateType,
    MergeMode,
    PatternType,
    PlaneType,
    RevolveMode,
    SweepMode,
)
from app.document.schemas import ComponentPatternAxisSchema, PlaneRefSchema, PointRefSchema, SubShapeRefSchema
from app.sketch.models import Plane


class SketchStep(BaseModel):
    local_id: str
    kind: Literal["sketch"] = "sketch"
    plane: Plane | None = None
    plane_feature_id: str | None = None


class SketchPointStep(BaseModel):
    local_id: str
    kind: Literal["sketch_point"] = "sketch_point"
    sketch_feature_id: str
    x: float
    y: float


class SketchLineStep(BaseModel):
    local_id: str
    kind: Literal["sketch_line"] = "sketch_line"
    sketch_feature_id: str
    start_point_id: str
    end_point_id: str | None = None
    length: float | None = None
    # Degrees, per 00-conventions.md's "degrees for every angle" - despite
    # the real `LineCreate.angle` this ultimately drives being radians,
    # `ai_plan.py`'s handler converts before calling it. Don't pass this
    # value to a radians-expecting call unconverted.
    angle: float | None = None
    construction: bool = False


class SketchCircleStep(BaseModel):
    local_id: str
    kind: Literal["sketch_circle"] = "sketch_circle"
    sketch_feature_id: str
    center_point_id: str
    radius_point_id: str | None = None
    radius: float | None = None
    # Degrees - see `SketchLineStep.angle`'s identical note.
    angle: float | None = None
    construction: bool = False


class SketchArcStep(BaseModel):
    local_id: str
    kind: Literal["sketch_arc"] = "sketch_arc"
    sketch_feature_id: str
    center_point_id: str
    start_point_id: str
    end_point_id: str | None = None
    # Degrees - see `SketchLineStep.angle`'s identical note.
    end_angle: float | None = None
    construction: bool = False


class SketchEllipseStep(BaseModel):
    local_id: str
    kind: Literal["sketch_ellipse"] = "sketch_ellipse"
    sketch_feature_id: str
    center_point_id: str
    major_point_id: str | None = None
    major_radius: float | None = None
    # Degrees - see `SketchLineStep.angle`'s identical note.
    angle: float | None = None
    minor_radius: float
    construction: bool = False


class SketchPolygonStep(BaseModel):
    local_id: str
    kind: Literal["sketch_polygon"] = "sketch_polygon"
    sketch_feature_id: str
    center_point_id: str
    first_vertex_point_id: str
    sides: int
    construction: bool = False
    reference_circles: bool = False


class SketchSlotStep(BaseModel):
    local_id: str
    kind: Literal["sketch_slot"] = "sketch_slot"
    sketch_feature_id: str
    center1_point_id: str
    center2_point_id: str
    radius: float
    construction: bool = False


class SketchRectangleStep(BaseModel):
    local_id: str
    kind: Literal["sketch_rectangle"] = "sketch_rectangle"
    sketch_feature_id: str
    # Exactly 4 local_ids of earlier `sketch_point` steps, in order
    # (corner0 -> corner1 -> corner2 -> corner3 -> corner0) - mirrors
    # `RectangleCreate.corner_point_ids` exactly (real backend Rectangle
    # creation always references 4 existing Points, there is no
    # corner+width+height convenience at the API layer - a plan wanting a
    # rectangle must emit 4 `sketch_point` steps first).
    corner_point_ids: list[str]
    axis_aligned: bool = True
    construction: bool = False
    # Workstream "dimension-driven sketches"
    # (docs/ai-modelling/08-dimension-driven-sketches.md): purely advisory
    # - never consumed by `sketch.add_rectangle` itself (the 4 corner Points
    # already fully determine the geometry, same as before this field
    # existed). When given, the translator/dry-run validator turns it into
    # a real, non-provisional DistanceConstraint between corner0/corner1
    # (width) and corner1/corner2 (height) - the same edges `axis_aligned`
    # already pins Horizontal/Vertical, so this only adds a length to an
    # edge whose *direction* was already fixed, never a redundant/
    # conflicting constraint. `width` is corner0->corner1's own length;
    # `height` is corner1->corner2's. Left `None` (the default) leaves the
    # rectangle exactly as before - implicitly sized by its corner Points'
    # own coordinates only, no real dimension.
    width: float | None = None
    height: float | None = None


class ExtrudeStep(BaseModel):
    local_id: str
    kind: Literal["extrude"] = "extrude"
    sketch_feature_id: str
    extrude_type: ExtrudeType
    start_distance: float
    end_distance: float
    target_body_ids: list[str] = []
    # local_ids of earlier Line/Circle/Arc/Ellipse steps in the same
    # Sketch - never a `sketch_rectangle`/`sketch_polygon`/`sketch_slot`
    # step directly (the real `select_profiles` only accepts an anchor
    # entity of type Line/Circle/Arc/Ellipse/Spline/Text; a composite
    # entity's own boundary Lines are what stand in for it). Empty (the
    # default) uses every outer profile the Sketch currently has, exactly
    # like the real `ExtrudeFeatureCreate.profile_refs` default.
    profile_refs: list[str] = []


class RevolveStep(BaseModel):
    local_id: str
    kind: Literal["revolve"] = "revolve"
    sketch_feature_id: str
    axis_ref: str  # local_id of a `sketch_line` step - must be a Line, never any other entity kind
    angle: float
    mode: RevolveMode
    target_body_ids: list[str] = []
    profile_refs: list[str] = []


class SweepStep(BaseModel):
    local_id: str
    kind: Literal["sweep"] = "sweep"
    sketch_feature_id: str
    # local_ids of earlier Line/Arc/Ellipse steps (Spline excluded - out of
    # v1 generation scope per 00-conventions.md), at least one required.
    path_refs: list[str]
    mode: SweepMode
    target_body_ids: list[str] = []
    profile_refs: list[str] = []


class EdgeSelectorKind(str, Enum):
    """The four deterministic edge-selector heuristics adopted for v1
    (see 03-structured-plan-schema.md's "Open design problem" section,
    option (b)) - resolved against a Body's real, already-computed
    topology by `app.document.ai_plan_edges`, never by a second LLM call -
    plus two more (Workstream 12, `docs/ai-modelling/12-provenance-edge-
    selectors.md`) resolving a *specific single* edge by tracing it back to
    the sketch entity that produced it (via OCCT's own `.Generated()`/
    `.Modified()` shape-history query), rather than a geometric heuristic
    over the finished Body - see that doc's own "Spike findings" for the
    exact mechanics and confirmed limits per Feature type."""

    TOP_FACE_EDGES = "top_face_edges"
    BOTTOM_FACE_EDGES = "bottom_face_edges"
    VERTICAL_EDGES = "vertical_edges"
    ALL_EDGES_OF_FACE_AT_POSITION = "all_edges_of_face_at_position"
    # Workstream 12: the safe, primary provenance selector - a corner
    # sketch_point local_id names the single lateral edge generated at
    # that corner. Confirmed clean (no failure case found) on Extrude,
    # partial Revolve, full-360 Revolve, and Sweep.
    EDGE_FROM_SKETCH_POINT = "edge_from_sketch_point"
    # Workstream 12: the more powerful, slightly riskier provenance
    # selector - a sketch_line local_id names either that edge as
    # originally drawn (far=False) or its generated counterpart on the
    # swept-to end (far=True). Real, confirmed working, with one disclosed
    # exception: a full-360 Revolve's radially-oriented profile edges can
    # have no far-edge result at all (fails closed, never a silent guess).
    EDGE_FROM_SKETCH_LINE = "edge_from_sketch_line"


class CardinalDirection(str, Enum):
    """A world-axis direction, used by `all_edges_of_face_at_position` to
    name which face to select (the one whose outward normal most closely
    aligns with this direction). v1 limitation, stated explicitly: this is
    always a world/global axis, never a Sketch-local or Body-local one -
    see `app.document.ai_plan_edges`'s own module docstring."""

    PLUS_X = "+x"
    MINUS_X = "-x"
    PLUS_Y = "+y"
    MINUS_Y = "-y"
    PLUS_Z = "+z"
    MINUS_Z = "-z"


class EdgeSelector(BaseModel):
    selector: EdgeSelectorKind
    # local_id of an earlier Body-producing step (extrude/revolve/sweep/
    # pattern/mirror/gear_request) - required for a `fillet`/`chamfer` step
    # (`ai_plan.py._resolve_edges` raises `invalid_step_payload` if omitted
    # there), but *ignored* when this `EdgeSelector` is instead
    # `MateEntityRefStep.edge_selector` (Phase 14, `docs/assembly-scope.md`
    # §6 `[3]`) - a Mate reference names its Body directly via `subshape_ref.
    # body_id`, so there is no plan-local Body-producing step to name in the
    # first place. Optional at the schema level (rather than two near-
    # identical schemas) so one `EdgeSelector` type serves both call sites,
    # the same "one schema reused, per-caller validation" convention
    # `MateEntityRefStep`'s own docstring already establishes for its three
    # ref fields.
    of: str | None = None
    # Required iff selector == ALL_EDGES_OF_FACE_AT_POSITION; unused (and
    # ignored) for every other selector.
    direction: CardinalDirection | None = None
    # Required iff selector == EDGE_FROM_SKETCH_POINT: local_id of a
    # sketch_point step belonging to the same profile Sketch `of`'s
    # Body-producing step consumed. Unused otherwise.
    sketch_point_ref: str | None = None
    # Required iff selector == EDGE_FROM_SKETCH_LINE: local_id of a
    # sketch_line step, same Sketch requirement as sketch_point_ref above.
    # Unused otherwise.
    sketch_line_ref: str | None = None
    # EDGE_FROM_SKETCH_LINE only, optional (default False): False selects
    # the edge as originally drawn, on the profile's own base/start face;
    # True selects its generated counterpart on the swept-to end (Extrude's
    # end face, Revolve's end-angle face, Sweep's path-end face). Ignored
    # for every other selector, including EDGE_FROM_SKETCH_POINT (which has
    # no such ambiguity - a corner generates exactly one lateral edge).
    far: bool = False


class FilletStep(BaseModel):
    local_id: str
    kind: Literal["fillet"] = "fillet"
    edges: EdgeSelector
    radius: float


class ChamferStep(BaseModel):
    local_id: str
    kind: Literal["chamfer"] = "chamfer"
    edges: EdgeSelector
    distance: float


class PatternDirectionStep(BaseModel):
    """Mirrors `PatternDirectionRef`, minus its `edge_ref` option - a Body
    edge doesn't exist at plan-authoring time, the same problem Fillet/
    Chamfer's edges have, and no selector heuristic has been designed for
    a pattern direction the way one has for Fillet/Chamfer's edges (see
    03's own scope note). Exactly one of the two fields must be set."""

    fixed_axis: FixedAxis | None = None
    sketch_line_ref: str | None = None  # local_id of a `sketch_line` step


class PatternAxisStep(BaseModel):
    """Mirrors `PatternAxisRef`, minus its `edge_ref`/`face_ref` options -
    same "doesn't exist at plan-authoring time" reasoning as
    `PatternDirectionStep` above, but *not* a `fixed_axis` option like that
    one: bug found while implementing workstream 4 - unlike
    `PatternDirectionRef` (a plain direction, expressible as a bare world
    axis), `PatternAxisRef` resolves to a full world-space axis (an origin
    point *and* a direction - a Circular Pattern rotates around a real
    pivot, not just along a direction) and genuinely has no `fixed_axis`
    field at all on the real backend dataclass; the original version of
    this class copied `PatternDirectionStep`'s shape without checking that
    difference, and would have raised an unhandled `TypeError` (not even a
    structured validation error) the moment a plan actually used it.
    `sketch_line_ref` is `PatternAxisRef`'s only plan-authorable option as
    a result - required, not optional, since it's the only field left."""

    sketch_line_ref: str  # local_id of a `sketch_line` step


class PatternStep(BaseModel):
    local_id: str
    kind: Literal["pattern"] = "pattern"
    source_body_ids: list[str]
    pattern_type: PatternType = PatternType.RECTANGULAR
    direction_1: PatternDirectionStep | None = None
    count_1: int = 1
    spacing_1: float = 0.0
    reverse_1: bool = False
    direction_2: PatternDirectionStep | None = None
    count_2: int = 1
    spacing_2: float = 0.0
    reverse_2: bool = False
    axis: PatternAxisStep | None = None
    count_angular: int = 1
    angle_total: float = 360.0
    reverse_angular: bool = False
    skip_indices: list[int] = []
    merge: MergeMode = MergeMode.KEEP_SEPARATE
    tool_feature_id: str | None = None


class MirrorPlaneStep(BaseModel):
    """Mirrors `PlaneRef`, minus its `face_ref` option - same "doesn't
    exist yet at plan-authoring time" reasoning as `PatternDirectionStep`.
    Exactly one of the two fields must be set."""

    fixed_plane: Plane | None = None
    plane_feature_id: str | None = None


class MirrorStep(BaseModel):
    local_id: str
    kind: Literal["mirror"] = "mirror"
    source_body_ids: list[str]
    mirror_plane: MirrorPlaneStep
    merge: MergeMode = MergeMode.KEEP_SEPARATE
    tool_feature_id: str | None = None


class CreatePlaneStep(BaseModel):
    """v1 scope: only the two `PlaneType` values expressible via plan-
    local Sketch references (`NORMAL_TO_LINE_AT_POINT`, `THREE_POINTS`) -
    the other four (`OFFSET_FACE`, `MIDPLANE`, `NORMAL_TO_EDGE_THROUGH_
    VERTEX`, `PARALLEL_TO_FACE_THROUGH_VERTEX`) all need a real Body face/
    edge/vertex `SubShapeRef`, which - like Fillet/Chamfer's edges -
    doesn't exist until a Body has been computed, and no selector
    heuristic has been designed for faces/vertices the way one has for
    Fillet/Chamfer's edges (a real, deliberate v1 scope-narrowing
    consequence, not an oversight - see 03's own scope note, which
    generalizes the "Open design problem" beyond just Fillet/Chamfer)."""

    local_id: str
    kind: Literal["create_plane"] = "create_plane"
    plane_type: Literal[PlaneType.NORMAL_TO_LINE_AT_POINT, PlaneType.THREE_POINTS]
    line_ref: str | None = None  # local_id of a `sketch_line` step (NORMAL_TO_LINE_AT_POINT)
    point_ref: str | None = None  # local_id of a `sketch_point` step (NORMAL_TO_LINE_AT_POINT)
    point_refs: list[str] = []  # exactly 3 local_ids of `sketch_point` steps (THREE_POINTS)


class GearRequestStep(BaseModel):
    """Routing only (00-conventions.md's "Gear-request routing") - the
    translator hands this off to the existing Gear Design screens instead
    of executing it as a Feature-tree step, so this endpoint never
    resolves it against real geometry (always `ok: true`, no OCCT call -
    see `app.document.ai_plan`'s own handling). A later step's `edges.of`/
    `target_body_ids`/`source_body_ids` naming a `gear_request` step's
    `local_id` is a real reference-kind match (a routed gear request does
    produce a real Body once the translator runs it for real) but cannot
    be dry-run validated here - reported as its own `gear_body_not_
    validatable` error rather than silently skipped or falsely passed.
    Parameters are carried opaquely (gear type, module, tooth count, etc.
    - shaped by workstream 2's own routing instruction, not by this
    schema) since this endpoint never inspects them."""

    model_config = ConfigDict(extra="allow")

    local_id: str
    kind: Literal["gear_request"] = "gear_request"


class LoftSectionStep(BaseModel):
    """Mirrors `LoftSectionSchema`/`LoftSection` with plan-local `local_id`s
    in place of real refs - each section may name a different `sketch`
    step, exactly like `SweepStep.path_refs` may span multiple sketches -
    this is what makes a square-to-round transition between two independent
    Sketches possible at all."""

    sketch_feature_id: str
    profile_refs: list[str] = []
    reference_point: str | None = None
    alignment_point: str | None = None


class LoftStep(BaseModel):
    local_id: str
    kind: Literal["loft"] = "loft"
    sections: list[LoftSectionStep]
    mode: LoftMode
    ruled: bool = False
    target_body_ids: list[str] = []
    thickness: float | None = None
    # local_ids of earlier Line/Arc/Ellipse steps (Spline excluded - out of
    # v1 generation scope, same restriction SweepStep.path_refs already has).
    guide_curve_refs: list[str] = []


class MergeStep(BaseModel):
    local_id: str
    kind: Literal["merge"] = "merge"
    body_ids: list[str]


class BooleanStep(BaseModel):
    local_id: str
    kind: Literal["boolean"] = "boolean"
    operation: BooleanOperation
    target_body_ids: list[str]
    tool_body_ids: list[str]
    consume_tool_bodies: bool = True


class DeleteBodyStep(BaseModel):
    local_id: str
    kind: Literal["delete_body"] = "delete_body"
    body_ids: list[str]


class ScaleBodyStep(BaseModel):
    local_id: str
    kind: Literal["scale_body"] = "scale_body"
    body_id: str
    factor: float = 1.0


class MoveBodyStep(BaseModel):
    local_id: str
    kind: Literal["move_body"] = "move_body"
    body_id: str
    delta: tuple[float, float, float] = (0.0, 0.0, 0.0)
    # Reuses PatternAxisStep verbatim - identical shape/purpose to Pattern's
    # own `axis` field (a plan-local sketch_line reference).
    rotation_axis: PatternAxisStep | None = None
    rotation_angle_degrees: float = 0.0
    make_copy: bool = False


class AddComponentStep(BaseModel):
    """Assembly support Phase 18 (`docs/assembly-scope.md` §6 `[2]`): the
    first `PlanStep` kind that places a brand-new Occurrence rather than
    only ever referencing one a human already placed by hand. Mirrors
    `add_component.dart`'s own `mergeComponentIntoDocument` shape - the real
    insertion this validator's dry run never performs itself, since this
    backend is stateless (`docs/assembly-scope.md` decision #6: no
    filesystem/SAF access at all) and can never open `relative_path` to
    discover the real target Part's geometry. `relative_path` is stored
    verbatim into the resulting scratch Occurrence's own `external_ref`
    (never parsed/validated against a real file beyond a bare non-empty
    check) - the client's own real execution (`PlanTranslator`) resolves it
    for real against `StorageService`/`ProjectRoot` and fails with a clear
    error if it doesn't exist, exactly like a human-picked "Insert Existing
    Component" file. `name_override`, if given, becomes the new Occurrence's
    own `name_override` verbatim.

    A later `mate`/`move_component`/`hide_component`/`isolate_component`/
    `pattern_component` step may reference this step's own `local_id`
    directly (bare, no `existing:` prefix) as an occurrence reference - see
    `_PlanValidator._lookup_occurrence`'s own widened docstring for the
    exact resolution rule."""

    local_id: str
    kind: Literal["add_component"] = "add_component"
    relative_path: str
    name_override: str | None = None


class MateEntityRefStep(BaseModel):
    """Mirrors `MateEntityRefResponse` (`app.document.schemas`) - one side of
    a `MateStep`. `occurrence_id` is either `""` (this Part's own root
    content, the same convention `_validate_mate_entity_ref` already allows
    for a real Mate), `existing:<occurrence_id>` (a real Occurrence already
    on the Part being edited), or a bare plan-local `local_id` naming an
    `AddComponentStep` earlier in this same plan (Phase 18, `docs/assembly-
    scope.md` §6 `[2]`) - never any other step kind's `local_id`, see
    `_PlanValidator._lookup_occurrence`'s own docstring for the exact
    resolution rule. `subshape_ref`/`plane_ref`/`point_ref` are
    reused verbatim from the real schema and are always literal, already-real
    refs into that Occurrence's own resolved target Part's geometry - never a
    plan-local id either, since that Part's Bodies aren't built by this plan
    at all (they're assumed to already exist, the same way an `existing:`
    Feature reference assumes the Part being edited already has one).
    Exactly one of the three ref fields must be set.

    `edge_selector` (Phase 14, `docs/assembly-scope.md` §6 `[3]`): optional,
    only meaningful alongside `subshape_ref` (`shape_type == "edge"`) -
    resolved *instead of* `subshape_ref.index` when set, the same benefit
    `FilletStep`/`ChamferStep`'s own `edges: EdgeSelector` already gives a
    Fillet/Chamfer edge pick (a heuristic name - "the top face's edges,"
    "the vertical edges" - instead of guessing a raw topology index).
    `ai_plan.py`'s own resolution only ever reaches `v.part`'s real, current
    Body geometry (`compute_part_bodies`), so this is only honored for
    `occurrence_id == ""` (the currently-open Part's own root content) -
    `existing:<id>` names a placed Occurrence's own *different* target Part,
    which this single-Part-scoped validator has no geometry access to at
    all, so `edge_selector` there is rejected with a clear
    `invalid_step_payload` rather than silently ignored. Only the four
    non-provenance selectors (`top_face_edges`/`bottom_face_edges`/
    `vertical_edges`/`all_edges_of_face_at_position`) are supported here -
    `edge_from_sketch_point`/`edge_from_sketch_line` need a real Feature id
    to trace lineage from, which `EdgeSelector.of`'s own doc comment already
    explains this call site has no equivalent of."""

    occurrence_id: str
    subshape_ref: SubShapeRefSchema | None = None
    plane_ref: PlaneRefSchema | None = None
    point_ref: PointRefSchema | None = None
    edge_selector: EdgeSelector | None = None


class MateStep(BaseModel):
    """Assembly support Phase 8 (`docs/assembly-scope.md` §2k): mirrors
    `MateCreate` (`app.document.schemas`) - creates a Mate between two
    Occurrences on the Part being edited. Each reference may name an
    already-placed Occurrence (`existing:<id>`) or a bare `local_id` naming
    an `AddComponentStep` earlier in this same plan (Phase 18, `docs/
    assembly-scope.md` §6 `[2]`) - see `MateEntityRefStep.occurrence_id`'s
    own docstring."""

    local_id: str
    kind: Literal["mate"] = "mate"
    type: MateType
    references: list[MateEntityRefStep]
    value: float | None = None
    flipped: bool = False


class MoveComponentStep(BaseModel):
    """Assembly support Phase 8 (`docs/assembly-scope.md` §2k): follows
    `MoveBodyStep`'s template one level up - components instead of bodies -
    but its own placement shape mirrors `RigidTransform`/
    `OccurrenceTransformUpdate` directly rather than `MoveBodyStep`'s
    delta+`PatternAxisStep`+`make_copy` shape: an Occurrence's placement is a
    whole-value replace with a free world-space rotation axis (`RigidTransform`'s
    own docstring - "not resolved from any geometry"), never a sketch-line-
    derived axis the way a Body's own rotation is, and there is no "make a
    copy" concept for a component (patterning is `pattern_component`'s own,
    separately-scoped concern - see that item's note in §3). `occurrence_id`
    is `existing:<occurrence_id>` or a bare `AddComponentStep` `local_id`
    from earlier in this same plan (Phase 18) - see `MateEntityRefStep`'s
    own docstring."""

    local_id: str
    kind: Literal["move_component"] = "move_component"
    occurrence_id: str
    translation: tuple[float, float, float] = (0.0, 0.0, 0.0)
    rotation_axis: tuple[float, float, float] = (0.0, 0.0, 1.0)
    rotation_angle_degrees: float = 0.0


class HideComponentStep(BaseModel):
    """Assembly support Phase 8 (`docs/assembly-scope.md` §2k): sets
    `occurrence_id`'s own `hidden` flag - the first time an AI plan step
    (or, transitively, this phase's own widened `OccurrenceTransformUpdate`,
    see that schema's own docstring) has ever persisted `Occurrence.hidden`
    at all, closing §5's appendix item 1's real gap as a side effect of
    giving this step somewhere real to write to."""

    local_id: str
    kind: Literal["hide_component"] = "hide_component"
    occurrence_id: str


class IsolateComponentStep(BaseModel):
    """Assembly support Phase 8 (`docs/assembly-scope.md` §2k): the real,
    persisted counterpart to the client's own session-only Isolate overlay
    (`docs/assembly-scope.md` §2f) - hides every *other* top-level Occurrence
    of the Part `occurrence_id` belongs to and un-hides `occurrence_id`
    itself. Unlike the client's own toggle-to-undo Isolate, this is a plain
    one-shot mutation (matching `hide_component`'s own shape) - there is no
    "isolate again to restore everything" concept at the AI-plan level, since
    an AI plan has no notion of "the isolation this step itself started" to
    toggle off later."""

    local_id: str
    kind: Literal["isolate_component"] = "isolate_component"
    occurrence_id: str


class PatternComponentStep(BaseModel):
    """Phase 14 (`docs/assembly-scope.md` §6 `[1] partial`): mirrors
    `ComponentPatternCreate` (`app.document.schemas`) directly - creates a
    `ComponentPattern` repeating one or more already-placed Occurrences.

    `source_occurrence_ids` entries are `existing:<occurrence_id>` or a bare
    `local_id` naming an `AddComponentStep` earlier in this same plan
    (Phase 18, `docs/assembly-scope.md` §6 `[2]`, landed) - the same
    convention `MateEntityRefStep.occurrence_id` uses.
    `_PlanValidator._lookup_occurrence`'s own widening (Phase 18) covers
    this handler transparently - `_handle_pattern_component` itself needed
    no change at all, since it already resolves every entry through that
    same generic lookup. This closes only the *achievable* half of the
    original deferred note below - a plan can pattern an Occurrence a human
    already placed by hand, or one an earlier `add_component` step in the
    same plan just placed; Phase 19's own remaining scope is the client-side
    prompt/vocabulary wording and end-to-end testing of this exact
    combination, not new validator logic here.

    Former deferred-scope note, restated for why this was ever left out in
    the first place: every Occurrence a plan *can* reference (via
    `existing:<id>`) is already a real, persisted top-level Occurrence - one
    the real, already-shipped `POST /parts/{part_id}/component-patterns`
    endpoint (Phase 7, §2j) could already pattern directly, with no
    AI-plan-authored step strictly *needed* to reach it. Added anyway once
    genuinely useful on its own terms (an AI plan chaining "mate this bolt,
    then pattern it 4 times around the flange" in one request, rather than
    requiring a separate manual step after the plan finishes) - not because
    the original blocker was ever removed for the *full* version."""

    local_id: str
    kind: Literal["pattern_component"] = "pattern_component"
    source_occurrence_ids: list[str]
    pattern_type: Literal["linear", "circular"] = "linear"
    direction: tuple[float, float, float] = (1.0, 0.0, 0.0)
    count: int = 1
    spacing: float = 0.0
    reverse: bool = False
    # Bug report (assembly testing): the optional second direction, mirrors
    # `ComponentPatternCreate`'s own identical fields - see
    # `app.document.models.ComponentPattern`'s doc comment on these four.
    direction_2: tuple[float, float, float] = (0.0, 1.0, 0.0)
    count_2: int = 1
    spacing_2: float = 0.0
    reverse_2: bool = False
    axis: ComponentPatternAxisSchema | None = None
    count_angular: int = 1
    angle_total: float = 360.0
    reverse_angular: bool = False
    skip_indices: list[int] = []
    orient_with_rotation: bool = True


PlanStep = Annotated[
    Union[
        SketchStep,
        SketchPointStep,
        SketchLineStep,
        SketchCircleStep,
        SketchArcStep,
        SketchEllipseStep,
        SketchPolygonStep,
        SketchSlotStep,
        SketchRectangleStep,
        ExtrudeStep,
        RevolveStep,
        SweepStep,
        FilletStep,
        ChamferStep,
        PatternStep,
        MirrorStep,
        CreatePlaneStep,
        GearRequestStep,
        LoftStep,
        MergeStep,
        BooleanStep,
        DeleteBodyStep,
        ScaleBodyStep,
        MoveBodyStep,
        AddComponentStep,
        MateStep,
        MoveComponentStep,
        HideComponentStep,
        IsolateComponentStep,
        PatternComponentStep,
    ],
    Field(discriminator="kind"),
]


class PlanValidateRequest(BaseModel):
    version: Literal[1] = 1
    steps: list[PlanStep]
    # Tool-toggle enforcement (AI Settings -> Tools): plan-step `kind`
    # strings the client has currently turned off. A step whose kind
    # appears here fails with `{"type": "kind_disabled", "kind": ...}`
    # before it is ever dispatched - see `_PlanValidator._run_step`. Empty
    # (the default) disables nothing, identical to every caller before this
    # field existed.
    disabled_kinds: list[str] = []


class StepResult(BaseModel):
    local_id: str
    ok: bool
    warnings: list[str] = []
    # Always a structured `{"type": "...", ...}` dict on failure (never a
    # bare string) - every domain error in this codebase is already
    # HTTPException(422/400, detail={"type": ...}), and this endpoint's
    # own hand-raised errors (unknown/wrong-kind local_id references,
    # depends-on-failed-step short-circuiting, edge-selector failures)
    # follow the identical shape for consistency.
    error: dict | None = None
    # Workstream 4: only present (and only meaningful) on a successful
    # `fillet`/`chamfer` step - the real Body edges its `EdgeSelector`
    # heuristic resolved to, so the translator can reuse this dry-run's
    # own resolution for real execution instead of re-deriving it (there is
    # no other way for the client to resolve an EdgeSelector at all - the
    # heuristics in `app.document.ai_plan_edges` need real OCCT topology,
    # never available client-side). Each entry's `body_id` is deliberately
    # the plan's own `edges.of` local_id (plus any `#N` multi-solid suffix
    # `_resolve_body_shape` added), never this validator's own scratch
    # Feature id - the translator substitutes its real id at the point of
    # use, exactly like every other local_id reference. `index` values are
    # only valid reused against real execution because both walk the same
    # step sequence from the same empty starting Part (00-conventions.md's
    # "v1 always starts a fresh Part") - the same assumption this endpoint's
    # own module docstring already relies on ("a step that dry-run-passes
    # here behaves identically once workstream 4's translator executes it
    # for real").
    resolved_edges: list[SubShapeRefSchema] | None = None
    # `02-scoping-conversation.md`'s own "Real end-to-end exercise" fix 3b:
    # only present (and only meaningful) on a successful `extrude`/
    # `revolve`/`sweep` step - the real number of holes (nested inner
    # loops) its selected profile(s) carry, sourced from `app.sketch.
    # profile.detect_profile`'s own already-computed `Profile.inner_loops`
    # during this endpoint's own dry-run resolution (see `app.document.
    # ai_plan._hole_count`) - real backend truth, not a client-side guess
    # (the client has no OCCT topology to reason about this with at all).
    hole_count: int | None = None
    # Phase 14 (`docs/assembly-scope.md` §6 `[3]`): only present (and only
    # meaningful) on a successful `mate` step that used `edge_selector` on
    # at least one of its two `references` - exactly 2 entries, in the same
    # order as `step.references`, `None` for whichever side (if either)
    # didn't use a selector (send that side's own `subshape_ref` unchanged).
    # Unlike `resolved_edges`' own `body_id`-is-a-local_id indirection, each
    # entry's `body_id` here is already the same real/plan-local-scratch
    # value the step's own `references[i].subshape_ref.body_id` supplied -
    # a Mate reference has no `edges.of`-style separate body-producing-step
    # field to resolve through, `subshape_ref.body_id` already names it
    # directly - so the translator substitutes only `index`, not `body_id`,
    # at the point of use.
    resolved_mate_references: list[SubShapeRefSchema | None] | None = None


class PlanValidateResponse(BaseModel):
    results: list[StepResult]
