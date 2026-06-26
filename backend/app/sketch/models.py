import math
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum

from app.sketch.constraints import (
    AngleConstraint,
    AtMidpointConstraint,
    CoincidentConstraint,
    CollinearConstraint,
    Constraint,
    DistanceConstraint,
    EqualLengthConstraint,
    HorizontalConstraint,
    LineDistanceConstraint,
    ParallelConstraint,
    PerpendicularConstraint,
    PointLineDistanceConstraint,
    VerticalConstraint,
)


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


@dataclass
class SketchEntity(ABC):
    """Base type for anything that can live in a Sketch's entity collection.

    Line is the only concrete entity today; Circle/Arc will subclass this
    later without requiring changes to Sketch, Profile detection, or the
    API layer.

    `construction` is persisted in the client's JSON model and round-tripped
    through the API as-is - the backend never sets it itself, only reads it
    (e.g. Profile detection excludes construction entities, see profile.py).
    It's `kw_only` so subclasses (Line, Circle) can add their own required
    fields after it without violating dataclass field-ordering rules.
    """

    id: str
    construction: bool = field(default=False, kw_only=True)

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
class Circle(SketchEntity):
    """A circle defined by two referenced Points: a center Point and a
    radius Point (a point on the circle's edge). Both are real, independently
    addressable Points - shareable with other entities via explicit id
    reference, same as Line's start/end Points.

    Does NOT override `endpoint_point_ids()` (inherits the base class's
    `None`): unlike a Line, a Circle's center/radius Points are not
    "connection" points in the chain-walking sense used by closed-loop
    detection. Sharing a Circle's center or radius Point with a Line is
    still allowed (it's just point-sharing, same as any two entities can
    share a Point), but it does not make the Circle part of a Line chain's
    connectivity graph - a Circle is either its own standalone closed
    profile, or (for now) not part of profile detection at all. See
    `profile.py` for how a standalone Circle is detected separately.
    """

    id: str
    center_point_id: str
    radius_point_id: str
    radius_constraint_id: str

    @property
    def type(self) -> str:
        return "circle"

    def radius(self, points: dict[str, Point]) -> float:
        center = points[self.center_point_id]
        radius_point = points[self.radius_point_id]
        return math.hypot(radius_point.x - center.x, radius_point.y - center.y)


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
    _origin_point_id: str | None = field(default=None, repr=False)

    def add_point(self, x: float, y: float) -> Point:
        point = Point(id=str(uuid.uuid4()), x=x, y=y)
        self.points[point.id] = point
        return point

    @property
    def origin_point_id(self) -> str | None:
        """The origin Point's id if it has been created (via `origin_point`)
        already, or None otherwise - unlike `origin_point`, never creates it,
        so callers that only need to special-case the origin *when present*
        (e.g. the solver pinning it in place, see solver.py) don't force its
        creation as a side effect."""
        return self._origin_point_id

    def origin_point(self) -> Point:
        """The real, addressable Point at (0, 0) in this Sketch's local
        coordinates - lazily created on first access (not at construction
        time) so that bare `Sketch(...)` construction in tests/elsewhere
        never implicitly gains a Point, and so pre-existing Sketches (from
        before this concept existed) get backfilled automatically the
        first time anyone asks for it, with no migration step needed."""
        if self._origin_point_id is None or self._origin_point_id not in self.points:
            self._origin_point_id = self.add_point(0.0, 0.0).id
        return self.points[self._origin_point_id]

    def add_line(
        self,
        start_point_id: str,
        end_point_id: str | None = None,
        *,
        length: float | None = None,
        angle: float | None = None,
        construction: bool = False,
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

        line = Line(
            id=str(uuid.uuid4()),
            start_point_id=start_point_id,
            end_point_id=end_point_id,
            construction=construction,
        )
        self.entities[line.id] = line
        return line

    def lines(self) -> list[Line]:
        return [entity for entity in self.entities.values() if isinstance(entity, Line)]

    def add_circle(
        self,
        center_point_id: str,
        radius_point_id: str | None = None,
        *,
        radius: float | None = None,
        angle: float | None = None,
        construction: bool = False,
    ) -> Circle:
        """Add a Circle from an existing center Point to either an existing
        radius Point (explicit sharing) or a new Point computed from a
        radius and angle (radians from the +x axis), mirroring add_line's
        existing-vs-computed-point pattern.

        The radius is a real solver constraint, not just a stored number:
        this always creates a DistanceConstraint between the center and
        radius Points (reusing the existing constraint type as-is, since a
        radius IS a distance constraint), so subsequent solves keep it
        accurate as either Point moves.
        """
        center = self.points[center_point_id]
        if radius_point_id is None:
            radius_point_id = self.add_point(
                center.x + radius * math.cos(angle),
                center.y + radius * math.sin(angle),
            ).id
            distance = radius
        elif radius_point_id not in self.points:
            raise KeyError(radius_point_id)
        else:
            radius_point = self.points[radius_point_id]
            distance = math.hypot(radius_point.x - center.x, radius_point.y - center.y)

        if center_point_id == radius_point_id:
            raise ValueError("A circle cannot have the same center and radius point")

        radius_constraint = self.add_distance_constraint(center_point_id, radius_point_id, distance)
        circle = Circle(
            id=str(uuid.uuid4()),
            center_point_id=center_point_id,
            radius_point_id=radius_point_id,
            radius_constraint_id=radius_constraint.id,
            construction=construction,
        )
        self.entities[circle.id] = circle
        return circle

    def circles(self) -> list[Circle]:
        return [entity for entity in self.entities.values() if isinstance(entity, Circle)]

    def delete_line(self, line_id: str) -> None:
        """Remove a Line. Its endpoint Points are left untouched - they may
        be shared with other Lines, so only an explicit Point deletion can
        remove them (see `delete_point`)."""
        if not isinstance(self.entities.get(line_id), Line):
            raise KeyError(line_id)
        del self.entities[line_id]

    def delete_circle(self, circle_id: str) -> None:
        """Remove a Circle and the radius DistanceConstraint that `add_circle`
        always creates alongside it (that constraint is an internal
        implementation detail of the Circle, not something the user added
        independently, so it is the one exception to "never auto-delete
        what a deletion didn't explicitly target"). The center/radius
        Points themselves are left untouched, same as `delete_line`."""
        circle = self.entities.get(circle_id)
        if not isinstance(circle, Circle):
            raise KeyError(circle_id)
        del self.entities[circle_id]
        self.constraints.pop(circle.radius_constraint_id, None)

    def _point_deletion_blocker(self, point_id: str) -> str | None:
        """A human-readable reason this Point cannot be deleted, or None if
        deletion is safe. A Point is only ever deleted explicitly, never as
        an automatic side effect of deleting something that references it -
        so deletion is blocked outright while anything still depends on it."""
        if point_id == self._origin_point_id:
            return "Cannot delete the sketch's origin point"
        for entity in self.entities.values():
            if isinstance(entity, Line) and point_id in entity.endpoint_point_ids():
                return f"Point is still referenced by line {entity.id}"
            if isinstance(entity, Circle) and point_id in (entity.center_point_id, entity.radius_point_id):
                return f"Point is still referenced by circle {entity.id}"
        for constraint in self.constraints.values():
            if point_id in constraint.point_ids():
                return f"Point is still referenced by constraint {constraint.id}"
        return None

    def delete_point(self, point_id: str) -> None:
        if point_id not in self.points:
            raise KeyError(point_id)
        blocker = self._point_deletion_blocker(point_id)
        if blocker is not None:
            raise ValueError(blocker)
        del self.points[point_id]

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

    def add_vertical_constraint(self, line_id: str) -> VerticalConstraint:
        line = self.entities.get(line_id)
        if not isinstance(line, Line):
            raise KeyError(line_id)

        constraint = VerticalConstraint(
            id=str(uuid.uuid4()),
            line_id=line_id,
            point_a_id=line.start_point_id,
            point_b_id=line.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_horizontal_constraint(self, line_id: str) -> HorizontalConstraint:
        line = self.entities.get(line_id)
        if not isinstance(line, Line):
            raise KeyError(line_id)

        constraint = HorizontalConstraint(
            id=str(uuid.uuid4()),
            line_id=line_id,
            point_a_id=line.start_point_id,
            point_b_id=line.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_angle_constraint(self, line1_id: str, line2_id: str, angle_degrees: float) -> AngleConstraint:
        line1 = self.entities.get(line1_id)
        if not isinstance(line1, Line):
            raise KeyError(line1_id)
        line2 = self.entities.get(line2_id)
        if not isinstance(line2, Line):
            raise KeyError(line2_id)
        if line1_id == line2_id:
            raise ValueError("An angle constraint cannot reference the same line twice")

        constraint = AngleConstraint(
            id=str(uuid.uuid4()),
            line1_id=line1_id,
            line2_id=line2_id,
            angle_degrees=angle_degrees,
            line1_start_id=line1.start_point_id,
            line1_end_id=line1.end_point_id,
            line2_start_id=line2.start_point_id,
            line2_end_id=line2.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_coincident_constraint(self, point_a_id: str, point_b_id: str) -> CoincidentConstraint:
        if point_a_id not in self.points:
            raise KeyError(point_a_id)
        if point_b_id not in self.points:
            raise KeyError(point_b_id)
        if point_a_id == point_b_id:
            raise ValueError("A coincident constraint cannot reference the same point twice")

        constraint = CoincidentConstraint(
            id=str(uuid.uuid4()), point_a_id=point_a_id, point_b_id=point_b_id
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def _two_lines_or_raise(self, line1_id: str, line2_id: str) -> tuple[Line, Line]:
        line1 = self.entities.get(line1_id)
        if not isinstance(line1, Line):
            raise KeyError(line1_id)
        line2 = self.entities.get(line2_id)
        if not isinstance(line2, Line):
            raise KeyError(line2_id)
        if line1_id == line2_id:
            raise ValueError("A constraint cannot reference the same line twice")
        return line1, line2

    def add_parallel_constraint(self, line1_id: str, line2_id: str) -> ParallelConstraint:
        line1, line2 = self._two_lines_or_raise(line1_id, line2_id)

        constraint = ParallelConstraint(
            id=str(uuid.uuid4()),
            line1_id=line1_id,
            line2_id=line2_id,
            line1_start_id=line1.start_point_id,
            line1_end_id=line1.end_point_id,
            line2_start_id=line2.start_point_id,
            line2_end_id=line2.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_perpendicular_constraint(self, line1_id: str, line2_id: str) -> PerpendicularConstraint:
        line1, line2 = self._two_lines_or_raise(line1_id, line2_id)

        constraint = PerpendicularConstraint(
            id=str(uuid.uuid4()),
            line1_id=line1_id,
            line2_id=line2_id,
            line1_start_id=line1.start_point_id,
            line1_end_id=line1.end_point_id,
            line2_start_id=line2.start_point_id,
            line2_end_id=line2.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_equal_length_constraint(self, line1_id: str, line2_id: str) -> EqualLengthConstraint:
        line1, line2 = self._two_lines_or_raise(line1_id, line2_id)

        constraint = EqualLengthConstraint(
            id=str(uuid.uuid4()),
            line1_id=line1_id,
            line2_id=line2_id,
            line1_start_id=line1.start_point_id,
            line1_end_id=line1.end_point_id,
            line2_start_id=line2.start_point_id,
            line2_end_id=line2.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_line_distance_constraint(
        self, line1_id: str, line2_id: str, distance: float
    ) -> LineDistanceConstraint:
        line1, line2 = self._two_lines_or_raise(line1_id, line2_id)

        constraint = LineDistanceConstraint(
            id=str(uuid.uuid4()),
            line1_id=line1_id,
            line2_id=line2_id,
            distance=distance,
            line1_start_id=line1.start_point_id,
            line1_end_id=line1.end_point_id,
            line2_start_id=line2.start_point_id,
            line2_end_id=line2.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_collinear_constraint(self, line1_id: str, line2_id: str) -> CollinearConstraint:
        line1, line2 = self._two_lines_or_raise(line1_id, line2_id)

        constraint = CollinearConstraint(
            id=str(uuid.uuid4()),
            line1_id=line1_id,
            line2_id=line2_id,
            line1_start_id=line1.start_point_id,
            line1_end_id=line1.end_point_id,
            line2_start_id=line2.start_point_id,
            line2_end_id=line2.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_point_line_distance_constraint(
        self, point_id: str, line_id: str, distance: float
    ) -> PointLineDistanceConstraint:
        if point_id not in self.points:
            raise KeyError(point_id)
        line = self.entities.get(line_id)
        if not isinstance(line, Line):
            raise KeyError(line_id)

        constraint = PointLineDistanceConstraint(
            id=str(uuid.uuid4()),
            point_id=point_id,
            line_id=line_id,
            distance=distance,
            line_start_id=line.start_point_id,
            line_end_id=line.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_at_midpoint_constraint(self, point_id: str, line_id: str) -> AtMidpointConstraint:
        if point_id not in self.points:
            raise KeyError(point_id)
        line = self.entities.get(line_id)
        if not isinstance(line, Line):
            raise KeyError(line_id)

        constraint = AtMidpointConstraint(
            id=str(uuid.uuid4()),
            point_id=point_id,
            line_id=line_id,
            line_start_id=line.start_point_id,
            line_end_id=line.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint
