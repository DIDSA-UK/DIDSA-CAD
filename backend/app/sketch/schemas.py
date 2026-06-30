from typing import Literal, Union

from pydantic import BaseModel, model_validator

from app.sketch.models import Plane
from app.sketch.profile import ProfileStatus


class SketchCreate(BaseModel):
    plane: Plane


class SketchResponse(BaseModel):
    id: str
    plane: Plane
    origin_point_id: str


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
    """Create a circle from an existing center Point, plus either an
    existing radius Point's id (explicit sharing) or a radius and angle
    (radians from the +x axis), which creates a new radius Point -
    mirroring LineCreate's existing-vs-computed-point pattern."""

    center_point_id: str
    radius_point_id: str | None = None
    radius: float | None = None
    angle: float | None = None
    construction: bool = False

    @model_validator(mode="after")
    def check_creation_mode(self) -> "CircleCreate":
        if self.radius_point_id is not None:
            if self.radius is not None or self.angle is not None:
                raise ValueError("Provide either 'radius_point_id', or 'radius' and 'angle', not both")
        elif self.radius is None or self.angle is None:
            raise ValueError("Provide either 'radius_point_id', or both 'radius' and 'angle'")
        return self


class CircleResponse(BaseModel):
    type: Literal["circle"] = "circle"
    id: str
    center_point_id: str
    radius_point_id: str
    radius: float
    construction: bool = False


class CircleUpdate(BaseModel):
    """Update a circle's construction flag - mirrors LineUpdate. There is
    no radius field here: a circle's radius is driven by its
    DistanceConstraint (see Sketch.add_circle), not edited directly."""

    construction: bool | None = None


SketchEntityResponse = Union[LineResponse, CircleResponse]


class ProfileResponse(BaseModel):
    point_ids: list[str]
    line_ids: list[str]


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
