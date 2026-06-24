from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Protocol


class SolverBuilder(Protocol):
    """What a Constraint needs from the solver-integration layer (solver.py)
    to express itself in py-slvs terms.

    Constraint subtypes call back into this rather than importing py_slvs
    directly, so this module stays a plain domain model with no solver
    library dependency - mirroring how models.py stays free of OCCT/FastAPI
    specifics.
    """

    def point2d(self, point_id: str) -> int:
        """Return the py-slvs entity handle for a Sketch Point, creating it
        (from that Point's current x/y as the initial guess) on first use."""
        ...

    def distance(self, point_a_handle: int, point_b_handle: int, value: float) -> int:
        """Add a distance constraint between two py-slvs point handles,
        returning the resulting py-slvs constraint handle."""
        ...

    def vertical(self, point_a_handle: int, point_b_handle: int) -> int:
        """Add a py-slvs constraint forcing two point handles to share the
        same X (workplane U) coordinate, returning the resulting py-slvs
        constraint handle."""
        ...

    def horizontal(self, point_a_handle: int, point_b_handle: int) -> int:
        """Same as `vertical`, but for the Y (workplane V) coordinate."""
        ...

    def line_segment(self, point_a_handle: int, point_b_handle: int) -> int:
        """Return a py-slvs line-segment entity handle spanning two point
        handles, creating it on first use. Needed by AngleConstraint, whose
        underlying py-slvs primitive (addAngle) takes line entities rather
        than points directly."""
        ...

    def angle(self, line_a_handle: int, line_b_handle: int, degrees: float) -> int:
        """Add a py-slvs angle constraint between two line-segment entity
        handles (target angle in degrees), returning the resulting py-slvs
        constraint handle."""
        ...

    def coincident(self, point_a_handle: int, point_b_handle: int) -> int:
        """Add a py-slvs constraint forcing two point handles to the same
        position, returning the resulting py-slvs constraint handle."""
        ...

    def parallel(self, line_a_handle: int, line_b_handle: int) -> int:
        """Add a py-slvs constraint forcing two line-segment entity handles
        to be parallel, returning the resulting py-slvs constraint handle."""
        ...

    def perpendicular(self, line_a_handle: int, line_b_handle: int) -> int:
        """Add a py-slvs constraint forcing two line-segment entity handles
        to be perpendicular, returning the resulting py-slvs constraint
        handle."""
        ...

    def equal_length(self, line_a_handle: int, line_b_handle: int) -> int:
        """Add a py-slvs constraint forcing two line-segment entity handles
        to share the same length, returning the resulting py-slvs constraint
        handle."""
        ...

    def point_on_line(self, point_handle: int, line_handle: int) -> int:
        """Add a py-slvs constraint forcing a point handle onto a
        line-segment entity handle (the point may lie anywhere along the
        line, not just between its endpoints), returning the resulting
        py-slvs constraint handle. CollinearConstraint calls this twice
        (once per endpoint of the second Line) since py-slvs has no single
        "two lines collinear" primitive - constraining both of one line's
        endpoints onto the other line is the standard SolveSpace
        equivalent."""
        ...

    def point_line_distance(self, point_handle: int, line_handle: int, value: float) -> int:
        """Add a py-slvs constraint pinning the perpendicular distance from
        a point handle to a line-segment entity handle (py-slvs's
        addPointLineDistance - the SLVS_C_PT_LINE_DISTANCE primitive),
        returning the resulting py-slvs constraint handle. LineDistanceConstraint
        uses this - rather than DistanceConstraint's addPointsDistance
        between two materialized midpoint Points - so a line-to-line
        dimension moves the lines themselves and creates no new Points."""
        ...


class Constraint(ABC):
    """Base type for anything that can live in a Sketch's constraint
    collection.

    Constraints are independent objects that reference Point ids directly -
    Line and other SketchEntity subclasses have no knowledge of constraints
    that reference their points. DistanceConstraint is the only concrete
    type today; future types (Angle, Coincident, Parallel, ...) subclass
    this without requiring changes to Sketch or solver.py.
    """

    id: str

    @property
    @abstractmethod
    def type(self) -> str:
        ...

    @abstractmethod
    def point_ids(self) -> tuple[str, ...]:
        """Every Point id this constraint references."""
        ...

    @abstractmethod
    def add_to_solver(self, builder: SolverBuilder) -> int:
        """Express this constraint via the given SolverBuilder, returning
        the resulting py-slvs constraint handle."""
        ...


@dataclass
class DistanceConstraint(Constraint):
    """Pins the distance between two Points to a fixed value."""

    id: str
    point_a_id: str
    point_b_id: str
    distance: float

    @property
    def type(self) -> str:
        return "distance"

    def point_ids(self) -> tuple[str, str]:
        return (self.point_a_id, self.point_b_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        point_a = builder.point2d(self.point_a_id)
        point_b = builder.point2d(self.point_b_id)
        return builder.distance(point_a, point_b, self.distance)


@dataclass
class VerticalConstraint(Constraint):
    """Forces a Line's two endpoint Points to share the same X-coordinate
    (the line runs vertically in the sketch plane).

    References the Line's id for display/API purposes, but - like
    DistanceConstraint - solves against Point ids directly: `point_a_id`/
    `point_b_id` are captured from the Line's start/end Point ids at
    creation time (see Sketch.add_vertical_constraint). This is safe
    because a Line's start/end Point ids never change after creation, only
    their coordinates do.
    """

    id: str
    line_id: str
    point_a_id: str
    point_b_id: str

    @property
    def type(self) -> str:
        return "vertical"

    def point_ids(self) -> tuple[str, str]:
        return (self.point_a_id, self.point_b_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        point_a = builder.point2d(self.point_a_id)
        point_b = builder.point2d(self.point_b_id)
        return builder.vertical(point_a, point_b)


@dataclass
class HorizontalConstraint(Constraint):
    """Same pattern as VerticalConstraint, but forces the shared coordinate
    to be Y instead of X (the line runs horizontally in the sketch plane)."""

    id: str
    line_id: str
    point_a_id: str
    point_b_id: str

    @property
    def type(self) -> str:
        return "horizontal"

    def point_ids(self) -> tuple[str, str]:
        return (self.point_a_id, self.point_b_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        point_a = builder.point2d(self.point_a_id)
        point_b = builder.point2d(self.point_b_id)
        return builder.horizontal(point_a, point_b)


@dataclass
class AngleConstraint(Constraint):
    """Pins the angle between two Lines to a fixed value in degrees.

    References both Lines' ids for display/API purposes; each Line's
    endpoint Point ids are captured at creation time (see
    Sketch.add_angle_constraint), same rationale as VerticalConstraint/
    HorizontalConstraint above.
    """

    id: str
    line1_id: str
    line2_id: str
    angle_degrees: float
    line1_start_id: str
    line1_end_id: str
    line2_start_id: str
    line2_end_id: str

    @property
    def type(self) -> str:
        return "angle"

    def point_ids(self) -> tuple[str, str, str, str]:
        return (self.line1_start_id, self.line1_end_id, self.line2_start_id, self.line2_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        line1 = builder.line_segment(
            builder.point2d(self.line1_start_id), builder.point2d(self.line1_end_id)
        )
        line2 = builder.line_segment(
            builder.point2d(self.line2_start_id), builder.point2d(self.line2_end_id)
        )
        return builder.angle(line1, line2, self.angle_degrees)


@dataclass
class CoincidentConstraint(Constraint):
    """Forces two Points to occupy the same position."""

    id: str
    point_a_id: str
    point_b_id: str

    @property
    def type(self) -> str:
        return "coincident"

    def point_ids(self) -> tuple[str, str]:
        return (self.point_a_id, self.point_b_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        point_a = builder.point2d(self.point_a_id)
        point_b = builder.point2d(self.point_b_id)
        return builder.coincident(point_a, point_b)


@dataclass
class ParallelConstraint(Constraint):
    """Forces two Lines to be parallel.

    References both Lines' ids for display/API purposes; each Line's
    endpoint Point ids are captured at creation time, same rationale as
    AngleConstraint above.
    """

    id: str
    line1_id: str
    line2_id: str
    line1_start_id: str
    line1_end_id: str
    line2_start_id: str
    line2_end_id: str

    @property
    def type(self) -> str:
        return "parallel"

    def point_ids(self) -> tuple[str, str, str, str]:
        return (self.line1_start_id, self.line1_end_id, self.line2_start_id, self.line2_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        line1 = builder.line_segment(
            builder.point2d(self.line1_start_id), builder.point2d(self.line1_end_id)
        )
        line2 = builder.line_segment(
            builder.point2d(self.line2_start_id), builder.point2d(self.line2_end_id)
        )
        return builder.parallel(line1, line2)


@dataclass
class PerpendicularConstraint(Constraint):
    """Forces two Lines to be perpendicular. Same shape as ParallelConstraint."""

    id: str
    line1_id: str
    line2_id: str
    line1_start_id: str
    line1_end_id: str
    line2_start_id: str
    line2_end_id: str

    @property
    def type(self) -> str:
        return "perpendicular"

    def point_ids(self) -> tuple[str, str, str, str]:
        return (self.line1_start_id, self.line1_end_id, self.line2_start_id, self.line2_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        line1 = builder.line_segment(
            builder.point2d(self.line1_start_id), builder.point2d(self.line1_end_id)
        )
        line2 = builder.line_segment(
            builder.point2d(self.line2_start_id), builder.point2d(self.line2_end_id)
        )
        return builder.perpendicular(line1, line2)


@dataclass
class EqualLengthConstraint(Constraint):
    """Forces two Lines to share the same length. Same shape as
    ParallelConstraint."""

    id: str
    line1_id: str
    line2_id: str
    line1_start_id: str
    line1_end_id: str
    line2_start_id: str
    line2_end_id: str

    @property
    def type(self) -> str:
        return "equal_length"

    def point_ids(self) -> tuple[str, str, str, str]:
        return (self.line1_start_id, self.line1_end_id, self.line2_start_id, self.line2_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        line1 = builder.line_segment(
            builder.point2d(self.line1_start_id), builder.point2d(self.line1_end_id)
        )
        line2 = builder.line_segment(
            builder.point2d(self.line2_start_id), builder.point2d(self.line2_end_id)
        )
        return builder.equal_length(line1, line2)


@dataclass
class LineDistanceConstraint(Constraint):
    """Pins the perpendicular distance between two Lines to a fixed value,
    via SolverBuilder.point_line_distance (py-slvs's SLVS_C_PT_LINE_DISTANCE
    equivalent) - anchored at Line 2's start Point against Line 1's
    segment, rather than DistanceConstraint's addPointsDistance between two
    separately-materialized midpoint Points. This is the fix for Stage 16
    item 9: dragging the dimension now moves the Lines themselves (no new
    Points are created), the same way every other line-to-line constraint
    here (Parallel, Perpendicular, ...) works directly against the Lines'
    own endpoints.

    References both Lines' ids for display/API purposes; each Line's
    endpoint Point ids are captured at creation time, same rationale as
    ParallelConstraint above.
    """

    id: str
    line1_id: str
    line2_id: str
    distance: float
    line1_start_id: str
    line1_end_id: str
    line2_start_id: str
    line2_end_id: str

    @property
    def type(self) -> str:
        return "line_distance"

    def point_ids(self) -> tuple[str, str, str, str]:
        return (self.line1_start_id, self.line1_end_id, self.line2_start_id, self.line2_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        line1 = builder.line_segment(
            builder.point2d(self.line1_start_id), builder.point2d(self.line1_end_id)
        )
        point2_start = builder.point2d(self.line2_start_id)
        return builder.point_line_distance(point2_start, line1, self.distance)


@dataclass
class CollinearConstraint(Constraint):
    """Forces two Lines onto a single shared line, by pinning both of
    Line 2's endpoints onto Line 1 (see SolverBuilder.point_on_line). Same
    id/point-id capture shape as ParallelConstraint."""

    id: str
    line1_id: str
    line2_id: str
    line1_start_id: str
    line1_end_id: str
    line2_start_id: str
    line2_end_id: str

    @property
    def type(self) -> str:
        return "collinear"

    def point_ids(self) -> tuple[str, str, str, str]:
        return (self.line1_start_id, self.line1_end_id, self.line2_start_id, self.line2_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        line1 = builder.line_segment(
            builder.point2d(self.line1_start_id), builder.point2d(self.line1_end_id)
        )
        point2_start = builder.point2d(self.line2_start_id)
        point2_end = builder.point2d(self.line2_end_id)
        handle = builder.point_on_line(point2_start, line1)
        builder.point_on_line(point2_end, line1)
        return handle
