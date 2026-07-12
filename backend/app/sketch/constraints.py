from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Literal, Protocol


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

    def horizontal_distance(self, point_a_id: str, point_b_id: str, value: float) -> int:
        """Pin only the X (workplane U) separation between two Points to
        `value` (a non-negative magnitude), leaving their Y separation
        free. Takes Point ids rather than already-resolved handles (unlike
        `distance` above) because the underlying py-slvs primitive is
        sign-sensitive - see solver.py's `_PySlvsBuilder.horizontal_
        distance` for why the sign is chosen from each Point's *current*
        position rather than being a fixed convention."""
        ...

    def vertical_distance(self, point_a_id: str, point_b_id: str, value: float) -> int:
        """Same as `horizontal_distance`, but pins the Y (workplane V)
        separation instead, leaving X free."""
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

    def equal_length_point_line_distance(
        self, point_handle: int, radius_line_handle: int, tangent_line_handle: int
    ) -> int:
        """Add a py-slvs constraint (addEqualLengthPointLineDistance,
        SLVS_C_EQ_LEN_PT_LINE_D) forcing `radius_line_handle`'s own length to
        equal the perpendicular distance from `point_handle` to
        `tangent_line_handle`, returning the resulting py-slvs constraint
        handle. Verified empirically against the installed py-slvs (no
        usable documentation exists for this primitive in the upstream
        SolveSpace header either): a virtual centre-to-rim line segment
        (length = radius) and a free line, constrained this way with
        `point_handle` = that same centre point, converged to the free line
        sitting exactly at perpendicular distance = radius from centre -
        i.e. genuine circle/arc-to-line tangency, expressed with zero new
        py-slvs entity types (no arc-of-circle entity needed - see
        TangentConstraint's own doc comment for why that path was avoided)."""
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

    def at_midpoint(self, point_handle: int, line_handle: int) -> int:
        """Add a py-slvs constraint pinning a point handle to the geometric
        midpoint of a line-segment entity handle (py-slvs's addMidPoint -
        the SLVS_C_AT_MIDPOINT primitive), returning the resulting py-slvs
        constraint handle. AtMidpointConstraint uses this in place of the
        Stage 21 PointLineDistanceConstraint+DistanceConstraint pair, since
        py-slvs has a native primitive for this exact relationship."""
        ...

    def cubic(
        self, p0_handle: int, p1_handle: int, p2_handle: int, p3_handle: int
    ) -> int:
        """Return a py-slvs cubic Bezier curve entity handle (py-slvs's
        addCubic, SLVS_E_CUBIC) spanning 4 point handles - `p0`/`p3` are the
        curve's own on-curve endpoints, `p1`/`p2` the two control handles
        (standard cubic Bezier convention, confirmed against the installed
        py-slvs by direct empirical test - see SplineTangentConstraint's
        own doc comment). Creating it (rather than skipping straight to
        plain Point/DistanceConstraint decomposition, as every other curved
        entity in this codebase does) is a deliberate choice for Spline
        specifically: py-slvs has no equivalent of "these 4 points trace a
        smooth curve" expressible any other way, and Spline's whole point
        is the tangent-continuity SplineTangentConstraint below builds on
        top of this."""
        ...

    def curves_tangent(
        self, at_end1: bool, at_end2: bool, curve1_handle: int, curve2_handle: int
    ) -> int:
        """Add a py-slvs constraint (addCurvesTangent, SLVS_C_CURVE_CURVE_
        TANGENT) forcing curve1's tangent direction at one of its own ends
        to match curve2's tangent direction at one of its own ends,
        returning the resulting py-slvs constraint handle. `at_end1`/
        `at_end2` select *which* end of each curve - True for a curve's own
        end (its 4th/`p3` point), False for its own start (`p0`) - verified
        empirically against the installed py-slvs (no usable documentation
        exists for these two booleans in the wrapped C library's docs): a
        two-segment test cubic chain sharing an endpoint, with mismatched
        initial control-handle directions, converged to a perfectly
        tangent-continuous join (measured tangent-direction dot product of
        1.0000) only with `at_end1=True, at_end2=False` - i.e. "curve1's
        end meets curve2's start" - every other boolean combination left a
        visible kink (dot product well under 1). SplineTangentConstraint
        always calls this with the earlier segment as curve1 (at its own
        end) and the later segment as curve2 (at its own start), matching
        that verified combination."""
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
    """Pins the distance between two Points to a fixed value.

    `orientation` selects what "distance" means: "linear" (default) is the
    plain Euclidean distance; "horizontal"/"vertical" pin only the X or Y
    separation respectively, leaving the other axis free - the solver-level
    counterpart of the sketcher's horizontal/vertical dimension tools (see
    SolverBuilder.horizontal_distance/vertical_distance).
    """

    id: str
    point_a_id: str
    point_b_id: str
    distance: float
    orientation: Literal["linear", "horizontal", "vertical"] = field(default="linear")
    # True for a size-defining DistanceConstraint auto-created by a shape
    # tool (Circle/Arc/Ellipse/Slot/Polygon radius etc.) purely to pin the
    # geometry rigid at placement time, before the user has actually chosen
    # a size - not because the user asked for a dimension. A provisional
    # constraint is skipped entirely by the solver (see solver.py's main
    # constraint loop) so it removes zero DOF and the shape correctly
    # reports as under-constrained until either a real value is confirmed
    # (see update_constraint_value, which clears this flag) or the user
    # adds their own dimension. Always False for constraints the user
    # created or confirmed themselves.
    provisional: bool = field(default=False)

    @property
    def type(self) -> str:
        return "distance"

    def point_ids(self) -> tuple[str, str]:
        return (self.point_a_id, self.point_b_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        if self.orientation == "horizontal":
            return builder.horizontal_distance(self.point_a_id, self.point_b_id, self.distance)
        if self.orientation == "vertical":
            return builder.vertical_distance(self.point_a_id, self.point_b_id, self.distance)
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
class TangentConstraint(Constraint):
    """Forces a Circle or Arc to be tangent to a Line - the perpendicular
    distance from the Circle/Arc's own centre to the Line equals its
    radius.

    Expressed via SolverBuilder.equal_length_point_line_distance rather
    than py-slvs's native arc-of-circle entity/addArcLineTangent (the more
    "obvious"-looking primitive): this codebase's own Arc model already
    avoids the native arc entity entirely (see Arc's own docstring - "zero
    new solver primitives"), and empirically (see
    equal_length_point_line_distance's own doc comment) the native arc
    entity is unreliable in the installed py-slvs build in this
    environment, while this point-line-distance approach converges
    cleanly. `center_point_id`/`radius_point_id` define a virtual
    centre-to-rim line segment whose length *is* the Circle/Arc's own
    radius (the same real, solver-tracked radius its own
    DistanceConstraint(s) already maintain) - this constraint introduces no
    new numeric value, it only ties an existing radius to an existing
    Line's distance from that same centre.
    """

    id: str
    center_point_id: str
    radius_point_id: str
    line_id: str
    line_start_id: str
    line_end_id: str

    @property
    def type(self) -> str:
        return "tangent"

    def point_ids(self) -> tuple[str, str, str, str]:
        return (self.center_point_id, self.radius_point_id, self.line_start_id, self.line_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        center = builder.point2d(self.center_point_id)
        radius_line = builder.line_segment(center, builder.point2d(self.radius_point_id))
        tangent_line = builder.line_segment(
            builder.point2d(self.line_start_id), builder.point2d(self.line_end_id)
        )
        return builder.equal_length_point_line_distance(center, radius_line, tangent_line)


@dataclass
class EqualRadiusConstraint(Constraint):
    """Forces two Circles/Arcs to share the same radius - e.g. a Slot's two
    end-cap Arcs.

    Expressed via SolverBuilder.equal_length on each one's own virtual
    centre-to-rim line segment (the same real, solver-tracked radius each
    Circle's/Arc's own DistanceConstraint(s) already maintain) - no native
    py-slvs "equal radius" entity-level primitive needed, mirroring
    TangentConstraint's own reasoning for avoiding the native arc entity.
    """

    id: str
    center1_point_id: str
    radius1_point_id: str
    center2_point_id: str
    radius2_point_id: str

    @property
    def type(self) -> str:
        return "equal_radius"

    def point_ids(self) -> tuple[str, str, str, str]:
        return (self.center1_point_id, self.radius1_point_id, self.center2_point_id, self.radius2_point_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        line1 = builder.line_segment(
            builder.point2d(self.center1_point_id), builder.point2d(self.radius1_point_id)
        )
        line2 = builder.line_segment(
            builder.point2d(self.center2_point_id), builder.point2d(self.radius2_point_id)
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


@dataclass
class PointLineDistanceConstraint(Constraint):
    """Pins the perpendicular distance from an arbitrary Point to a Line to
    a fixed value, via SolverBuilder.point_line_distance - generalizes
    LineDistanceConstraint's shape (which is anchored at a second Line's
    own start Point) to any Point id. Stage 21 item 3's midpoint fix uses
    this at distance 0 to pin a Point onto a Line's infinite extension
    (a "point-on-line" constraint), paired with a DistanceConstraint to the
    Line's own endpoint to fix the Point's position along it - together
    the correct, solver-stable definition of a midpoint, unlike a pair of
    plain point-to-point DistanceConstraints (which only pin distance from
    each endpoint and let the Point swing off the Line in an arc).

    References the Line's id for display/API purposes; its endpoint Point
    ids are captured at creation time, same rationale as
    LineDistanceConstraint above.
    """

    id: str
    point_id: str
    line_id: str
    distance: float
    line_start_id: str
    line_end_id: str

    @property
    def type(self) -> str:
        return "point_line_distance"

    def point_ids(self) -> tuple[str, str, str]:
        return (self.point_id, self.line_start_id, self.line_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        point = builder.point2d(self.point_id)
        line = builder.line_segment(
            builder.point2d(self.line_start_id), builder.point2d(self.line_end_id)
        )
        return builder.point_line_distance(point, line, self.distance)


@dataclass
class AtMidpointConstraint(Constraint):
    """Pins a Point to the geometric midpoint of a Line, via
    SolverBuilder.at_midpoint (py-slvs's native SLVS_C_AT_MIDPOINT
    primitive). Replaces the Stage 21 PointLineDistanceConstraint(distance=0)
    + DistanceConstraint(half-length) pair with a single solver-native
    constraint - same geometric result, but the Point's position along the
    Line is no longer pinned by a separate fixed half-length value, so it
    tracks the midpoint correctly as the Line's own length changes.

    No numeric value field - this is a pure geometric constraint, like
    Coincident/Parallel/Perpendicular/EqualLength/Collinear.

    References the Line's id for display/API purposes; its endpoint Point
    ids are captured at creation time, same rationale as
    PointLineDistanceConstraint above.
    """

    id: str
    point_id: str
    line_id: str
    line_start_id: str
    line_end_id: str

    @property
    def type(self) -> str:
        return "at_midpoint"

    def point_ids(self) -> tuple[str, str, str]:
        return (self.point_id, self.line_start_id, self.line_end_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        point = builder.point2d(self.point_id)
        line = builder.line_segment(
            builder.point2d(self.line_start_id), builder.point2d(self.line_end_id)
        )
        return builder.at_midpoint(point, line)


@dataclass
class SplineTangentConstraint(Constraint):
    """Pins two adjacent cubic Bezier segments of a Spline to meet
    tangent-continuously (no visible kink) at their shared through-point -
    `add_spline`'s own internal implementation detail, one of these per
    interior through-point of a Spline with 3+ through-points, auto-created
    alongside it and auto-cascaded by `delete_spline`, exactly like Arc's
    own pair of radius DistanceConstraints.

    Each segment is defined by 4 Points (start, control 1, control 2, end -
    see SolverBuilder.cubic's own doc comment); `segment_a_*` is the
    earlier segment (its own end, `segment_a_p3`, is the shared
    through-point) and `segment_b_*` is the later one (its own start,
    `segment_b_p0`, is that same shared through-point - always equal to
    `segment_a_p3`, captured separately only so this dataclass doesn't need
    special-case field access). Cubic entities are rebuilt fresh from their
    4 Points on every solve (see SolverBuilder.cubic), the same "no
    persistent solver-side entity, rebuilt every call" convention every
    other curved entity here already follows for Line segments.
    """

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

    @property
    def type(self) -> str:
        return "spline_tangent"

    def point_ids(self) -> tuple[str, ...]:
        return (
            self.segment_a_p0,
            self.segment_a_p1,
            self.segment_a_p2,
            self.segment_a_p3,
            self.segment_b_p1,
            self.segment_b_p2,
            self.segment_b_p3,
        )

    def add_to_solver(self, builder: SolverBuilder) -> int:
        segment_a = builder.cubic(
            builder.point2d(self.segment_a_p0),
            builder.point2d(self.segment_a_p1),
            builder.point2d(self.segment_a_p2),
            builder.point2d(self.segment_a_p3),
        )
        segment_b = builder.cubic(
            builder.point2d(self.segment_b_p0),
            builder.point2d(self.segment_b_p1),
            builder.point2d(self.segment_b_p2),
            builder.point2d(self.segment_b_p3),
        )
        return builder.curves_tangent(True, False, segment_a, segment_b)
