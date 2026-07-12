from typing import Literal, Union

from pydantic import BaseModel, model_validator

from app.sketch.models import Plane
from app.sketch.profile import ProfileStatus
from app.sketch.text_fonts import DEFAULT_FONT, FONT_ALLOWLIST


class SketchCreate(BaseModel):
    plane: Plane
    # Sketcher-roadmap Phase 5 - see app.sketch.models.Sketch's own
    # docstring for what these mean; ignored (never applied) for a
    # None-plane Sketch, but this endpoint always creates a fixed-plane one.
    flip: bool = False
    rotation_quarter_turns: int = 0


class SketchResponse(BaseModel):
    id: str
    # C3: null for a Sketch anchored to a custom CreatePlaneFeature via the
    # Document layer (see app.sketch.models.Sketch's own docstring) - always
    # populated for a Sketch created through the standalone /sketch API.
    plane: Plane | None
    origin_point_id: str
    flip: bool = False
    rotation_quarter_turns: int = 0


class SketchOrientationUpdate(BaseModel):
    """Sketcher-roadmap Phase 5: the request body for `PATCH .../orientation`
    - both fields required (not optional-and-partial like most other PATCH
    bodies in this file) since flip/rotation are only ever meaningful set
    together as a single new orientation, not independently patched."""

    flip: bool
    rotation_quarter_turns: int


class PointCreate(BaseModel):
    x: float
    y: float


class PointUpdate(BaseModel):
    x: float
    y: float


class PointResponse(BaseModel):
    id: str
    x: float
    y: float


class LineCreate(BaseModel):
    """Create a line from an existing start Point, plus either an existing
    end Point's id (explicit sharing - no coordinate-matching/auto-merge)
    or a length and direction angle (radians from the +x axis), which
    creates a new end Point."""

    start_point_id: str
    end_point_id: str | None = None
    length: float | None = None
    angle: float | None = None
    construction: bool = False

    @model_validator(mode="after")
    def check_creation_mode(self) -> "LineCreate":
        if self.end_point_id is not None:
            if self.length is not None or self.angle is not None:
                raise ValueError("Provide either 'end_point_id', or 'length' and 'angle', not both")
        elif self.length is None or self.angle is None:
            raise ValueError("Provide either 'end_point_id', or both 'length' and 'angle'")
        return self


class LineUpdate(BaseModel):
    """Update a line's length and/or its construction flag. `length` moves
    the end Point along the existing direction (see PATCH .../points/{id}
    to move an endpoint directly). `construction` is optional so the
    client can toggle Make-Construction/Make-Solid without also resending
    a length - omitted fields are left unchanged."""

    length: float | None = None
    construction: bool | None = None


# `type` is a discriminator so that when Circle/Arc entities are added,
# the entity collection response becomes Union[LineResponse, CircleResponse, ...]
# without restructuring the API layer.
class LineResponse(BaseModel):
    type: Literal["line"] = "line"
    id: str
    start_point_id: str
    end_point_id: str
    length: float
    construction: bool = False


class CircleCreate(BaseModel):
    """Create a circle from an existing center Point, plus one of three
    ways to define the radius Point: an existing Point's id (explicit
    sharing), a radius and angle (radians from the +x axis) which creates a
    new Point at that position, or - the centre-point circle tool's own
    mode - a bare radius with no angle at all, which creates the new Point
    as the circle's own north cardinal point (vertically above centre) -
    see `Sketch.add_circle`'s own doc comment."""

    center_point_id: str
    radius_point_id: str | None = None
    radius: float | None = None
    angle: float | None = None
    construction: bool = False

    @model_validator(mode="after")
    def check_creation_mode(self) -> "CircleCreate":
        if self.radius_point_id is not None:
            if self.radius is not None or self.angle is not None:
                raise ValueError("Provide either 'radius_point_id', or 'radius' (optionally with 'angle'), not both")
        elif self.radius is None:
            raise ValueError("Provide either 'radius_point_id', or 'radius' (optionally with 'angle')")
        return self


class CircleResponse(BaseModel):
    type: Literal["circle"] = "circle"
    id: str
    center_point_id: str
    radius_point_id: str
    radius: float
    construction: bool = False
    # [north, east, south, west] - see the backend's Circle.cardinal_point_ids
    # docstring for how each is solver-locked.
    cardinal_point_ids: list[str]


class CircleUpdate(BaseModel):
    """Update a circle's construction flag - mirrors LineUpdate. There is
    no radius field here: a circle's radius is driven by its
    DistanceConstraint (see Sketch.add_circle), not edited directly."""

    construction: bool | None = None


class ArcCreate(BaseModel):
    """Create an arc from an existing center Point and an existing start
    Point (together fixing the radius), plus either an existing end
    Point's id (explicit sharing) or an end angle (radians from the +x
    axis), which creates a new end Point on the same circle - mirroring
    CircleCreate's existing-vs-computed-point pattern, one Point further
    along."""

    center_point_id: str
    start_point_id: str
    end_point_id: str | None = None
    end_angle: float | None = None
    construction: bool = False

    @model_validator(mode="after")
    def check_creation_mode(self) -> "ArcCreate":
        if self.end_point_id is not None:
            if self.end_angle is not None:
                raise ValueError("Provide either 'end_point_id' or 'end_angle', not both")
        elif self.end_angle is None:
            raise ValueError("Provide either 'end_point_id' or 'end_angle'")
        return self


class ArcResponse(BaseModel):
    type: Literal["arc"] = "arc"
    id: str
    center_point_id: str
    start_point_id: str
    end_point_id: str
    radius: float
    construction: bool = False


class ArcUpdate(BaseModel):
    """Update an arc's construction flag - mirrors CircleUpdate. There is
    no radius field here either: an arc's radius is driven by its two
    DistanceConstraints (see Sketch.add_arc), not edited directly."""

    construction: bool | None = None


class EllipseCreate(BaseModel):
    """Create an ellipse from an existing center Point, plus either an
    existing major-axis Point's id (explicit sharing) or a major radius
    and angle (radians from the +x axis), which creates a new major-axis
    Point - mirrors CircleCreate's existing-vs-computed-point pattern.
    `minor_radius` always places a brand-new minor-axis Point exactly
    perpendicular to the major axis (see the backend's
    `app.sketch.models.Ellipse` docstring - there is no existing-minor-
    Point sharing option, since a minor-axis Point can only ever come from
    an Ellipse's own creation) and must not exceed the major radius."""

    center_point_id: str
    major_point_id: str | None = None
    major_radius: float | None = None
    angle: float | None = None
    minor_radius: float
    construction: bool = False

    @model_validator(mode="after")
    def check_creation_mode(self) -> "EllipseCreate":
        if self.major_point_id is not None:
            if self.major_radius is not None or self.angle is not None:
                raise ValueError("Provide either 'major_point_id', or 'major_radius' and 'angle', not both")
        elif self.major_radius is None or self.angle is None:
            raise ValueError("Provide either 'major_point_id', or both 'major_radius' and 'angle'")
        return self


class EllipseResponse(BaseModel):
    type: Literal["ellipse"] = "ellipse"
    id: str
    center_point_id: str
    major_point_id: str
    major_point_neg_id: str
    minor_point_id: str
    minor_point_neg_id: str
    major_axis_line_id: str
    minor_axis_line_id: str
    major_radius: float
    minor_radius: float
    rotation: float
    construction: bool = False


class EllipseUpdate(BaseModel):
    """Update an ellipse's construction flag. There is no radius field
    here: like Circle/Arc, both of an Ellipse's radii are now driven by
    real DistanceConstraints (see the Ellipse class docstring) - PATCH
    `major_constraint_id`/`minor_constraint_id` via the ordinary
    `/constraints/{id}` endpoint instead."""

    construction: bool | None = None


class SplineCreate(BaseModel):
    """Create a spline through 2+ existing Points, in order - see the
    backend's `app.sketch.models.Spline` docstring for what this creates
    alongside the Spline itself (2 control-handle Points per segment, plus
    a `SplineTangentConstraint` per interior through-point). Unlike
    Circle/Arc/Ellipse, there is no existing-vs-computed-point choice
    here: every through-point must already exist (created via the
    ordinary `/points` endpoint first), mirroring how a Line chain's own
    Points are each placed individually before the Line connecting them is
    created."""

    through_point_ids: list[str]
    construction: bool = False

    @model_validator(mode="after")
    def check_point_count(self) -> "SplineCreate":
        if len(self.through_point_ids) < 2:
            raise ValueError("A spline needs at least 2 through-points")
        return self


class SplineResponse(BaseModel):
    type: Literal["spline"] = "spline"
    id: str
    through_point_ids: list[str]
    control_point_ids: list[str]
    construction: bool = False


class SplineUpdate(BaseModel):
    """Update a spline's construction flag - mirrors ArcUpdate/CircleUpdate.
    There is no shape field here: a spline's shape is driven entirely by
    its through-points/control-handle Points' own positions and its
    SplineTangentConstraints, not edited directly."""

    construction: bool | None = None


class TextCreate(BaseModel):
    """Create a Text entity anchored to an existing Point - mirrors
    `SplineCreate`: unlike Circle/Arc/Ellipse's existing-vs-computed-point
    choice, the anchor Point must already exist (created via the ordinary
    `/points` endpoint first), since a Text entity has exactly one Point
    and no derived-from-radius placement to compute. `font` must be one
    of `app.sketch.text_fonts.FONT_ALLOWLIST`'s small backend-bundled set
    (see `app.sketch.models.TextEntity`'s own docstring for why) -
    checked here rather than deferred to the (materially more expensive)
    actual OCCT conversion, so an unknown font is rejected immediately
    with a clear 422 rather than surfacing later as a confusing failure
    from profile detection or extrude."""

    content: str
    anchor_point_id: str
    font: str = DEFAULT_FONT
    size: float = 10.0
    rotation_degrees: float = 0.0
    construction: bool = False

    @model_validator(mode="after")
    def check_content(self) -> "TextCreate":
        if not self.content:
            raise ValueError("Text content cannot be empty")
        if self.size <= 0:
            raise ValueError("Text size must be positive")
        if self.font not in FONT_ALLOWLIST:
            raise ValueError(f"Unknown font: {self.font!r}")
        return self


class TextResponse(BaseModel):
    type: Literal["text"] = "text"
    id: str
    content: str
    font: str
    size: float
    anchor_point_id: str
    rotation_degrees: float = 0.0
    construction: bool = False


class TextUpdate(BaseModel):
    """Update any of a Text entity's own directly-editable fields -
    mirrors EllipseUpdate/SplineUpdate's "construction flag, plus
    whatever fields have no backing solver constraint of their own"
    shape. Every field here is a plain direct edit (see TextEntity's own
    docstring: none of `content`/`font`/`size`/`rotation_degrees` is
    solver-tracked) - omitted fields are left unchanged."""

    content: str | None = None
    font: str | None = None
    size: float | None = None
    rotation_degrees: float | None = None
    construction: bool | None = None

    @model_validator(mode="after")
    def check_values(self) -> "TextUpdate":
        if self.content is not None and not self.content:
            raise ValueError("Text content cannot be empty")
        if self.size is not None and self.size <= 0:
            raise ValueError("Text size must be positive")
        if self.font is not None and self.font not in FONT_ALLOWLIST:
            raise ValueError(f"Unknown font: {self.font!r}")
        return self


class TextContourResponse(BaseModel):
    """One glyph's own closed boundary (`outer`) plus its own inner holes
    (`holes`, e.g. the counter in "o"/"e"/"a"/"g") - both as sketch-local
    `(x, y)` polylines, already positioned/rotated per the owning Text
    entity's own anchor Point and `rotation_degrees` (the client draws
    these directly with its existing sketch-space rendering, no extra
    transform needed). Each polyline is closed but does not repeat its
    first point."""

    outer: list[tuple[float, float]]
    holes: list[list[tuple[float, float]]] = []


class TextPreviewResponse(BaseModel):
    """A Text entity's full tessellated outline - one `TextContourResponse`
    per glyph (see `app.sketch.profile._text_profile`) - for client
    rendering only (see the Text tool's own scoping notes: no font-outline
    renderer belongs in Flutter, so the client fetches/caches/draws this
    real server-tessellated outline instead of approximating one)."""

    contours: list[TextContourResponse]


SketchEntityResponse = Union[
    LineResponse, CircleResponse, ArcResponse, EllipseResponse, SplineResponse, TextResponse
]


class ProfileResponse(BaseModel):
    point_ids: list[str]
    line_ids: list[str]
    # C1: this profile's holes (nested closed loops), each itself a
    # ProfileResponse. Empty for a simple profile with no holes; only ever
    # one level deep (see ProfileStatus.INVALID_NESTING).
    inner_loops: list["ProfileResponse"] = []


class ProfileDetectionResponse(BaseModel):
    status: ProfileStatus
    detail: str
    profile: ProfileResponse | None = None
    branch_point_ids: list[str] = []
    loops: list[ProfileResponse] = []


class DistanceConstraintCreate(BaseModel):
    # `type` defaults to "distance" (rather than being required) so existing
    # clients/tests that predate Stage 12 and never sent a `type` field keep
    # working unmodified - Pydantic's smart-mode union resolution (no
    # explicit `discriminator=`) falls back to this default when `type` is
    # absent from the request body. The three new constraint types below
    # have no sensible default (Vertical/Horizontal share an identical
    # `line_id`-only shape, so a `type` value is the only thing that tells
    # them apart) and so require it.
    type: Literal["distance"] = "distance"
    point_a_id: str
    point_b_id: str
    distance: float
    # "linear" (default) is plain Euclidean distance; "horizontal"/"vertical"
    # pin only the X/Y separation, leaving the other axis free. Optional
    # with a default so pre-Prompt-B clients/tests that never send this
    # field keep working unmodified.
    orientation: Literal["linear", "horizontal", "vertical"] = "linear"


class VerticalConstraintCreate(BaseModel):
    type: Literal["vertical"]
    line_id: str


class HorizontalConstraintCreate(BaseModel):
    type: Literal["horizontal"]
    line_id: str


class AngleConstraintCreate(BaseModel):
    type: Literal["angle"]
    line1_id: str
    line2_id: str
    angle_degrees: float


class CoincidentConstraintCreate(BaseModel):
    type: Literal["coincident"]
    point_a_id: str
    point_b_id: str


class ParallelConstraintCreate(BaseModel):
    type: Literal["parallel"]
    line1_id: str
    line2_id: str


class PerpendicularConstraintCreate(BaseModel):
    type: Literal["perpendicular"]
    line1_id: str
    line2_id: str


class EqualLengthConstraintCreate(BaseModel):
    type: Literal["equal_length"]
    line1_id: str
    line2_id: str


class CollinearConstraintCreate(BaseModel):
    type: Literal["collinear"]
    line1_id: str
    line2_id: str


class LineDistanceConstraintCreate(BaseModel):
    type: Literal["line_distance"]
    line1_id: str
    line2_id: str
    distance: float


class PointLineDistanceConstraintCreate(BaseModel):
    type: Literal["point_line_distance"]
    point_id: str
    line_id: str
    distance: float


class AtMidpointConstraintCreate(BaseModel):
    type: Literal["at_midpoint"]
    point_id: str
    line_id: str


class TangentConstraintCreate(BaseModel):
    type: Literal["tangent"]
    circle_or_arc_id: str
    line_id: str


class EqualRadiusConstraintCreate(BaseModel):
    type: Literal["equal_radius"]
    entity1_id: str
    entity2_id: str
    radius2_point_id: str | None = None


class EqualRadiusPointsConstraintCreate(BaseModel):
    """The raw-Point counterpart to EqualRadiusConstraintCreate, for callers
    with no Circle/Arc entity id to pass - see
    Sketch.add_equal_radius_constraint_from_points."""

    type: Literal["equal_radius_points"]
    center1_point_id: str
    radius1_point_id: str
    center2_point_id: str
    radius2_point_id: str


ConstraintCreate = Union[
    DistanceConstraintCreate,
    VerticalConstraintCreate,
    HorizontalConstraintCreate,
    AngleConstraintCreate,
    CoincidentConstraintCreate,
    ParallelConstraintCreate,
    PerpendicularConstraintCreate,
    EqualLengthConstraintCreate,
    CollinearConstraintCreate,
    LineDistanceConstraintCreate,
    PointLineDistanceConstraintCreate,
    AtMidpointConstraintCreate,
    TangentConstraintCreate,
    EqualRadiusConstraintCreate,
    EqualRadiusPointsConstraintCreate,
]


class DistanceConstraintResponse(BaseModel):
    type: Literal["distance"] = "distance"
    id: str
    point_a_id: str
    point_b_id: str
    distance: float
    orientation: Literal["linear", "horizontal", "vertical"] = "linear"


class VerticalConstraintResponse(BaseModel):
    type: Literal["vertical"] = "vertical"
    id: str
    line_id: str
    point_a_id: str
    point_b_id: str


class HorizontalConstraintResponse(BaseModel):
    type: Literal["horizontal"] = "horizontal"
    id: str
    line_id: str
    point_a_id: str
    point_b_id: str


class AngleConstraintResponse(BaseModel):
    type: Literal["angle"] = "angle"
    id: str
    line1_id: str
    line2_id: str
    angle_degrees: float


class CoincidentConstraintResponse(BaseModel):
    type: Literal["coincident"] = "coincident"
    id: str
    point_a_id: str
    point_b_id: str


class ParallelConstraintResponse(BaseModel):
    type: Literal["parallel"] = "parallel"
    id: str
    line1_id: str
    line2_id: str


class PerpendicularConstraintResponse(BaseModel):
    type: Literal["perpendicular"] = "perpendicular"
    id: str
    line1_id: str
    line2_id: str


class EqualLengthConstraintResponse(BaseModel):
    type: Literal["equal_length"] = "equal_length"
    id: str
    line1_id: str
    line2_id: str


class CollinearConstraintResponse(BaseModel):
    type: Literal["collinear"] = "collinear"
    id: str
    line1_id: str
    line2_id: str


class LineDistanceConstraintResponse(BaseModel):
    type: Literal["line_distance"] = "line_distance"
    id: str
    line1_id: str
    line2_id: str
    distance: float


class PointLineDistanceConstraintResponse(BaseModel):
    type: Literal["point_line_distance"] = "point_line_distance"
    id: str
    point_id: str
    line_id: str
    distance: float


class AtMidpointConstraintResponse(BaseModel):
    type: Literal["at_midpoint"] = "at_midpoint"
    id: str
    point_id: str
    line_id: str


class SplineTangentConstraintResponse(BaseModel):
    type: Literal["spline_tangent"] = "spline_tangent"
    id: str
    spline_id: str
    segment_a_p0: str
    segment_a_p1: str
    segment_a_p2: str
    segment_a_p3: str
    segment_b_p0: str
    segment_b_p1: str
    segment_b_p2: str
    segment_b_p3: str


class TangentConstraintResponse(BaseModel):
    type: Literal["tangent"] = "tangent"
    id: str
    center_point_id: str
    radius_point_id: str
    line_id: str


class EqualRadiusConstraintResponse(BaseModel):
    type: Literal["equal_radius"] = "equal_radius"
    id: str
    center1_point_id: str
    radius1_point_id: str
    center2_point_id: str
    radius2_point_id: str


ConstraintResponse = Union[
    DistanceConstraintResponse,
    VerticalConstraintResponse,
    HorizontalConstraintResponse,
    AngleConstraintResponse,
    CoincidentConstraintResponse,
    ParallelConstraintResponse,
    PerpendicularConstraintResponse,
    EqualLengthConstraintResponse,
    CollinearConstraintResponse,
    LineDistanceConstraintResponse,
    PointLineDistanceConstraintResponse,
    AtMidpointConstraintResponse,
    SplineTangentConstraintResponse,
    TangentConstraintResponse,
    EqualRadiusConstraintResponse,
]


class ConstraintValueUpdate(BaseModel):
    """Updates a DistanceConstraint's `distance` or an AngleConstraint's
    `angle_degrees`. Vertical/Horizontal constraints have no numeric value
    and reject this with a 422 (see router.update_constraint_value)."""

    value: float


class SolveResultResponse(BaseModel):
    converged: bool
    dof: int
    result_code: int
    blamed_constraint_ids: list[str]
    solver_reported_failed_constraint_ids: list[str]
    detail: str


class SolveRequest(BaseModel):
    """Optional body for POST .../solve. `anchor_point_ids` are pinned for
    this one solve exactly like the sketch's own origin already is (see
    `solver.solve_sketch`'s doc comment) - drag-solve semantics: a Point the
    client just dragged (or, for a dragged Line, both its endpoints) stays
    at exactly the position it was dropped at, and the rest of the sketch
    settles around it, instead of every Point (including the one the user
    was just holding) being equally free to move. Never persisted - each
    solve call is independent, and omitting the body entirely (as every
    caller did before this field existed) is equivalent to an empty list."""

    anchor_point_ids: list[str] = []
