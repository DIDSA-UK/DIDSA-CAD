from typing import Literal

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


SketchEntityResponse = LineResponse


class ProfileResponse(BaseModel):
    point_ids: list[str]
    line_ids: list[str]


class ProfileDetectionResponse(BaseModel):
    status: ProfileStatus
    detail: str
    profile: ProfileResponse | None = None
    branch_point_ids: list[str] = []
    loops: list[ProfileResponse] = []
