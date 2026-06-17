import math
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum

from app.sketch.constraints import Constraint, DistanceConstraint


class Plane(str, Enum):
    """The three fixed reference planes a Sketch can live on, all through
    the origin. Arbitrary/custom planes are explicitly deferred."""

    XY = "XY"
    XZ = "XZ"
    YZ = "YZ"


@dataclass
class Point:
    """An (x, y) coordinate in a Sketch's local 2D space, with its own id.

    Points are shared explicitly: two Lines reference the same Point only
    when deliberately created with that Point's id. There is no
    coordinate-matching or auto-merge of coincident Points.
    """

    id: str
    x: float
    y: float


class SketchEntity(ABC):
    """Base type for anything that can live in a Sketch's entity collection.

    Line is the only concrete entity today; Circle/Arc will subclass this
    later without requiring changes to Sketch, Profile detection, or the
    API layer.
    """

    id: str

    @property
    @abstractmethod
    def type(self) -> str:
        ...

    def endpoint_point_ids(self) -> tuple[str, str] | None:
        """The (start, end) Point ids this entity connects, if it has that
        notion at all. Closed-loop detection is built on this method alone,
        so it knows nothing about Line specifically - any future entity
        (e.g. Arc) that connects two Points slots in automatically."""
        return None


@dataclass
class Line(SketchEntity):
    """A straight Sketch entity defined by two referenced Points (not
    coordinates). Editing the length dimension moves the end Point,
    preserving direction from the start Point - since Points are shared
    objects, this moves every other Line that references the same end
    Point too, which is the natural and expected behaviour of a shared
    Point.
    """

    id: str
    start_point_id: str
    end_point_id: str

    @property
    def type(self) -> str:
        return "line"

    def endpoint_point_ids(self) -> tuple[str, str]:
        return (self.start_point_id, self.end_point_id)

    def length(self, points: dict[str, Point]) -> float:
        start = points[self.start_point_id]
        end = points[self.end_point_id]
        return math.hypot(end.x - start.x, end.y - start.y)

    def set_length(self, points: dict[str, Point], length: float) -> None:
        start = points[self.start_point_id]
        end = points[self.end_point_id]
        dx = end.x - start.x
        dy = end.y - start.y
        current_length = math.hypot(dx, dy)
        if current_length == 0:
            raise ValueError("Cannot set length: line direction is undefined (zero-length line)")
        scale = length / current_length
        end.x = start.x + dx * scale
        end.y = start.y + dy * scale


@dataclass
class Sketch:
    """An independent 2D sketch on one of the three fixed reference planes.

    Each Sketch owns its own Points and entities - nothing is shared
    between Sketches. The plane is stored but not yet used for any 3D
    transform/embedding (that becomes relevant once there's a 3D viewport
    and/or Extrude needs it).
    """

    id: str
    plane: Plane
    points: dict[str, Point] = field(default_factory=dict)
    entities: dict[str, SketchEntity] = field(default_factory=dict)
    constraints: dict[str, Constraint] = field(default_factory=dict)

    def add_point(self, x: float, y: float) -> Point:
        point = Point(id=str(uuid.uuid4()), x=x, y=y)
        self.points[point.id] = point
        return point

    def add_line(
        self,
        start_point_id: str,
        end_point_id: str | None = None,
        *,
        length: float | None = None,
        angle: float | None = None,
    ) -> Line:
        """Add a Line from an existing start Point to either an existing
        end Point (explicit sharing) or a new Point computed from a length
        and angle (radians from the +x axis)."""
        start = self.points[start_point_id]
        if end_point_id is None:
            end_point_id = self.add_point(
                start.x + length * math.cos(angle),
                start.y + length * math.sin(angle),
            ).id
        elif end_point_id not in self.points:
            raise KeyError(end_point_id)

        if start_point_id == end_point_id:
            raise ValueError("A line cannot start and end at the same point")

        line = Line(id=str(uuid.uuid4()), start_point_id=start_point_id, end_point_id=end_point_id)
        self.entities[line.id] = line
        return line

    def lines(self) -> list[Line]:
        return [entity for entity in self.entities.values() if isinstance(entity, Line)]

    def add_distance_constraint(
        self, point_a_id: str, point_b_id: str, distance: float
    ) -> DistanceConstraint:
        if point_a_id not in self.points:
            raise KeyError(point_a_id)
        if point_b_id not in self.points:
            raise KeyError(point_b_id)
        if point_a_id == point_b_id:
            raise ValueError("A distance constraint cannot reference the same point twice")

        constraint = DistanceConstraint(
            id=str(uuid.uuid4()),
            point_a_id=point_a_id,
            point_b_id=point_b_id,
            distance=distance,
        )
        self.constraints[constraint.id] = constraint
        return constraint
