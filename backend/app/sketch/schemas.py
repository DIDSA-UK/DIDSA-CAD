from typing import Literal, Union

from pydantic import BaseModel, model_validator

from app.sketch.models import Plane
from app.sketch.profile import ProfileStatus


class SketchCreate(BaseModel):
    plane: Plane


class SketchResponse(BaseModel):
    id: str
    plane: Plane


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

    @model_validator(mode="after")
    def check_creation_mode(self) -> "LineCreate":
        if self.end_point_id is not None:
            if self.length is not None or self.angle is not None:
                raise ValueError("Provide either 'end_point_id', or 'length' and 'angle', not both")
        elif self.length is None or self.angle is None:
            raise ValueError("Provide either 'end_point_id', or both 'length' and 'angle'")
        return self


class LineUpdate(BaseModel):
    """Update a line's length - the end Point moves along the existing
    direction. To move an endpoint directly, update the Point itself
    (PATCH .../points/{point_id}); since Points are shared, that moves
    every Line referencing it."""

    length: float


# `type` is a discriminator so that when Circle/Arc entities are added,
# the entity collection response becomes Union[LineResponse, CircleResponse, ...]
# without restructuring the API layer.
class LineResponse(BaseModel):
    type: Literal["line"] = "line"
    id: str
    start_point_id: str
    end_point_id: str
    length: float


class CircleCreate(BaseModel):
    """Create a circle from an existing center Point, plus either an
    existing radius Point's id (explicit sharing) or a radius and angle
    (radians from the +x axis), which creates a new radius Point -
    mirroring LineCreate's existing-vs-computed-point pattern."""

    center_point_id: str
    radius_point_id: str | None = None
    radius: float | None = None
    angle: float | None = None

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
    point_a_id: str
    point_b_id: str
    distance: float


# DistanceConstraint is the only Constraint type for now - this becomes a
# discriminated union (like SketchEntityResponse) once more are added.
ConstraintCreate = DistanceConstraintCreate


class ConstraintResponse(BaseModel):
    type: Literal["distance"] = "distance"
    id: str
    point_a_id: str
    point_b_id: str
    distance: float


class SolveResultResponse(BaseModel):
    converged: bool
    dof: int
    result_code: int
    blamed_constraint_ids: list[str]
    solver_reported_failed_constraint_ids: list[str]
    detail: str
