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
    ExtrudeType,
    FixedAxis,
    MergeMode,
    PatternType,
    PlaneType,
    RevolveMode,
    SweepMode,
)
from app.document.schemas import SubShapeRefSchema
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
    of: str  # local_id of an earlier Body-producing step (extrude/revolve/sweep/pattern/mirror/gear_request)
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
    ],
    Field(discriminator="kind"),
]


class PlanValidateRequest(BaseModel):
    version: Literal[1] = 1
    steps: list[PlanStep]


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


class PlanValidateResponse(BaseModel):
    results: list[StepResult]
