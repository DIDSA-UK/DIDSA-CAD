from pydantic import BaseModel, model_validator


class PointModel(BaseModel):
    x: float
    y: float


class LineCreate(BaseModel):
    """Create a line either from two endpoints, or from a start point plus
    a length and direction angle (radians, measured from the +x axis)."""

    start: PointModel
    end: PointModel | None = None
    length: float | None = None
    angle: float | None = None

    @model_validator(mode="after")
    def check_creation_mode(self) -> "LineCreate":
        if self.end is not None:
            if self.length is not None or self.angle is not None:
                raise ValueError("Provide either 'end', or 'length' and 'angle', not both")
        elif self.length is None or self.angle is None:
            raise ValueError("Provide either 'end', or both 'length' and 'angle'")
        return self


class LineUpdate(BaseModel):
    """Update a line either by setting its length (recalculates the second
    endpoint) or by setting both endpoints directly."""

    start: PointModel | None = None
    end: PointModel | None = None
    length: float | None = None

    @model_validator(mode="after")
    def check_update_mode(self) -> "LineUpdate":
        has_endpoints = self.start is not None or self.end is not None
        if has_endpoints and self.length is not None:
            raise ValueError("Provide either endpoints or length, not both")
        if has_endpoints and (self.start is None or self.end is None):
            raise ValueError("Updating endpoints requires both 'start' and 'end'")
        if not has_endpoints and self.length is None:
            raise ValueError("Provide either endpoints or a length to update")
        return self


class LineResponse(BaseModel):
    id: str
    start: PointModel
    end: PointModel
    length: float
