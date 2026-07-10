import math
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum
from typing import Literal

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
    SplineTangentConstraint,
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
    connectivity graph - a Circle is always its own standalone closed
    profile, detected independently of any Line-chain loops in the same
    Sketch and then nested against them by centroid containment (a Circle
    fully inside a Line-chain polygon becomes a hole in it, and vice
    versa). See `profile.py`'s `detect_profile`/`_classify_nesting`.
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
class Arc(SketchEntity):
    """A circular arc defined by three referenced Points: a center Point
    and a start/end Point pair on the arc's own circle. All three are
    real, independently addressable Points, same as Line's/Circle's own
    defining Points.

    The radius is a real solver constraint, not a stored number - exactly
    like Circle's, just doubled: `add_arc` creates a DistanceConstraint
    pinning the start Point's distance from center, and a second
    DistanceConstraint pinning the end Point's distance from center to the
    *same* value, so a drag of either Point (or the center) keeps both
    ends on the same circle after the next solve. There is no dedicated
    py-slvs arc entity or "equal radius" constraint involved - two
    independent DistanceConstraints sharing one initial value achieves the
    same result with zero new solver primitives, mirroring the project's
    "reuse existing constraint types" approach to Circle.

    DOES override `endpoint_point_ids()` (unlike Circle): an Arc's
    start/end Points ARE real chain-connection points for closed-loop
    detection purposes, exactly like a Line's - a Line-and-Arc chain that
    closes into a loop (e.g. a rounded-corner rectangle) is a valid
    profile, detected by the same generic connectivity walk `profile.py`
    already runs over any entity with a non-None `endpoint_point_ids()`.
    The center Point is deliberately excluded from that tuple - it is not
    a chain-connection point, only start/end are.

    The arc traced from start to end is always the one going
    counter-clockwise around center as seen along the sketch plane's
    normal (matching gp_Circ's own parametrization convention) - both the
    client's 2D rendering and `app.document.extrude.wire_for_profile`'s
    OCCT edge construction must agree on this, since a circle has two
    possible arcs between any two points on it and only one is "the" Arc.
    """

    id: str
    center_point_id: str
    start_point_id: str
    end_point_id: str
    radius_constraint_id: str
    end_radius_constraint_id: str

    @property
    def type(self) -> str:
        return "arc"

    def endpoint_point_ids(self) -> tuple[str, str]:
        return (self.start_point_id, self.end_point_id)

    def radius(self, points: dict[str, Point]) -> float:
        center = points[self.center_point_id]
        start = points[self.start_point_id]
        return math.hypot(start.x - center.x, start.y - center.y)


@dataclass
class Ellipse(SketchEntity):
    """An ellipse defined by a center Point, a major-axis Point (a real,
    independently addressable Point on the ellipse along its major axis -
    its distance from center is the semi-major radius, its direction from
    center is the major axis's own rotation, exactly mirroring Circle's
    own center/radius Point pair), and a semi-minor radius stored as a
    plain float rather than a second Point.

    That asymmetry (one radius is solver-tracked via a Point +
    DistanceConstraint, the other is a bare stored number) is deliberate,
    not an oversight: a true ellipse's minor axis must stay exactly
    perpendicular to its major axis, and there is no existing constraint
    primitive here for "these two Points' directions from a shared origin
    stay perpendicular" without adding real spoke Line entities purely to
    hang a PerpendicularConstraint off of them - real complexity for a
    relationship a plain stored scalar sidesteps entirely. Editing
    `minor_radius` is a direct PATCH (see `EllipseUpdate`), the same shape
    Line's own `length` field already uses for a derived-but-directly-
    editable dimension. `major_radius` must always be >= `minor_radius`
    (OCCT's own `gp_Elips` requirement, enforced at creation/update time -
    see `Sketch.add_ellipse`/`app.sketch.router.update_ellipse`).

    Does NOT override `endpoint_point_ids()`, for the same reason Circle
    doesn't: an Ellipse is always its own standalone closed profile, never
    part of a Line/Arc chain's connectivity graph - see `profile.py`'s
    `_ellipse_profile`/`_is_ellipse_profile`, mirroring Circle's own
    standalone-profile handling.

    No dedicated py-slvs entity is involved (py-slvs 1.0.6 has no ellipse
    primitive at all, confirmed by inspecting the installed solver module -
    unlike Arc, which at least has an unused one) - this is pure Point +
    DistanceConstraint reuse, same as Circle/Arc.
    """

    id: str
    center_point_id: str
    major_point_id: str
    major_constraint_id: str
    minor_radius: float

    @property
    def type(self) -> str:
        return "ellipse"

    def major_radius(self, points: dict[str, Point]) -> float:
        center = points[self.center_point_id]
        major = points[self.major_point_id]
        return math.hypot(major.x - center.x, major.y - center.y)

    def rotation(self, points: dict[str, Point]) -> float:
        """The major axis's direction from center, in radians from the +x
        axis - the same angle `app.document.extrude.wire_for_profile` uses
        to orient the ellipse's OCCT `gp_Elips` (via its X reference
        direction), and the client uses to rotate its own rendering."""
        center = points[self.center_point_id]
        major = points[self.major_point_id]
        return math.atan2(major.y - center.y, major.x - center.x)


@dataclass
class Spline(SketchEntity):
    """An open, piecewise-cubic curve through 2+ real, independently
    addressable "through-points" (`through_point_ids`) - the Points a user
    actually tapped, each one lying exactly on the curve. Between each
    consecutive pair of through-points sits one cubic Bezier segment, with
    its own 2 control-handle Points (also real, draggable Points, held in
    `control_point_ids`, 2 per segment in segment order) - a Spline with N
    through-points always has exactly `2 * (N - 1)` control points.

    Unlike Circle/Arc/Ellipse (which all sidestep py-slvs's specialized
    curve entities entirely, decomposing into plain Points +
    DistanceConstraints instead), a Spline genuinely uses py-slvs's own
    cubic Bezier primitive (`SLVS_E_CUBIC`, via `SolverBuilder.cubic`) for
    each segment, plus a real `SplineTangentConstraint` at every interior
    through-point (there are `N - 2` of them, one per "join" between two
    segments) enforcing that the segments meet tangent-continuously rather
    than kinking - see that constraint's own doc comment for exactly how,
    including the empirically-verified py-slvs boolean semantics involved.
    This is a deliberate, higher-effort choice over the simpler
    plain-Points-with-derived-curve approach every other curved entity
    here uses (py-slvs does expose a real cubic-curve primitive, unlike
    Circle/Arc/Ellipse's workarounds - see `SolverBuilder.cubic`'s own
    doc comment) - it buys genuine solver-enforced tangent continuity as
    through-points are dragged, at the cost of being the first entity in
    this codebase to actually create py-slvs curve entities rather than
    only Points/Lines/Constraints.

    DOES override `endpoint_point_ids()` (like Arc, unlike Circle/Ellipse):
    a Spline's first/last through-points ARE real chain-connection points
    for closed-loop detection, so a Line/Arc/Spline chain that closes into
    a loop is a valid profile via the same generic connectivity walk
    `profile.py` already runs. A *closed* spline (looping back on itself,
    standalone like Circle/Ellipse) is not supported - a Spline is always
    one open edge in a larger chain, or, with only 2 through-points and no
    other chain members, would need an explicit closing entity same as any
    2-Point-only shape would.
    """

    id: str
    through_point_ids: list[str]
    control_point_ids: list[str]
    tangent_constraint_ids: list[str]

    @property
    def type(self) -> str:
        return "spline"

    def endpoint_point_ids(self) -> tuple[str, str]:
        return (self.through_point_ids[0], self.through_point_ids[-1])

    def segments(self) -> list[tuple[str, str, str, str]]:
        """Every cubic segment's 4 defining Point ids (start, control 1,
        control 2, end), in order - shared by `add_to_solver`-adjacent
        code (building `SplineTangentConstraint`s at creation time) and
        `app.document.extrude.wire_for_profile` (building one OCCT edge
        per segment)."""
        return [
            (
                self.through_point_ids[i],
                self.control_point_ids[2 * i],
                self.control_point_ids[2 * i + 1],
                self.through_point_ids[i + 1],
            )
            for i in range(len(self.through_point_ids) - 1)
        ]


@dataclass
class TextEntity(SketchEntity):
    """A string of text, rendered via a bundled font's outline as one or
    more closed contours (each glyph, plus that glyph's own inner holes
    like the counters in "o"/"e"/"a"/"g") for cutting/embossing - see the
    Text tool's own scoping notes in docs/sketcher-overhaul-scope.md
    6.2.6.

    Deliberately NOT decomposed into constrainable Points/Lines/Splines
    the way every other entity here is: a single word already produces
    dozens of contours and curve segments, and nobody hand-tweaks the
    curve of a single serif - every mainstream CAD tool treats sketch
    text the same way, an opaque, regenerate-on-edit object. The only
    real, independently addressable, draggable/constrainable Point is
    `anchor_point_id` (the same role Circle's center Point plays) - the
    glyph geometry itself is never persisted as Points, it regenerates
    fresh from `content`/`font`/`size`/`rotation_degrees` on every read
    via `app.sketch.text_geometry.text_to_shape`, the same
    recompute-from-parametric-inputs principle every other feature/
    extrude/fillet in this app already follows.

    `font` is restricted to `app.sketch.text_geometry.FONT_ALLOWLIST` (a
    small backend-bundled set, not arbitrary system/uploaded fonts - see
    that module's own docstring) - enforced at creation/update time, not
    here (a bare dataclass has no validation of its own, matching every
    other entity in this file).

    `rotation_degrees` is a plain, directly user-set value (unlike
    Ellipse's own `rotation()`, which is *derived* from a second Point) -
    there is no second Point here to derive an angle from, so this is
    edited the same direct-PATCH way Ellipse's `minor_radius` is.

    Does NOT override `endpoint_point_ids()` (inherits the base class's
    `None`, same as Circle/Ellipse): Text is always its own standalone
    closed-loop-producing entity (in fact potentially several, one per
    glyph), never part of a Line/Arc/Spline chain's connectivity graph -
    see `profile.py`'s `_text_profile`.
    """

    id: str
    content: str
    font: str
    size: float
    anchor_point_id: str
    rotation_degrees: float = 0.0

    @property
    def type(self) -> str:
        return "text"


class SketchEntityType(str, Enum):
    """Which kind of Sketch entity a `SketchEntityRef` (below) points at.
    Mirrors app.document.models.SubShapeType's str-Enum pattern so it
    round-trips through pydantic the same way once a future Feature (e.g.
    Create Plane's "Normal to Line at Point" reference) embeds one in its
    own payload schema."""

    POINT = "point"
    LINE = "line"
    CIRCLE = "circle"
    ARC = "arc"
    ELLIPSE = "ellipse"
    SPLINE = "spline"
    TEXT = "text"


@dataclass(frozen=True)
class SketchEntityRef:
    """C1: a reference to one specific Point/Line/Circle inside one specific
    Sketch - the Sketch-domain counterpart to `app.document.models.SubShapeRef`,
    for a future Feature that needs to persist "this specific sketch entity"
    (e.g. Create Plane's "Normal to Line at Point"). Deliberately not routed
    through anything resembling `resolve_subshape`: Points/Lines/Circles
    already carry their own stable id assigned at creation time (`Point.id`,
    `SketchEntity.id`), so resolution is a direct dict lookup against the
    Sketch's own collections, not an OCCT topology re-derivation - simpler
    than `SubShapeRef` by construction, with no risk of the "same index,
    different sub-shape" fragility that motivates `SubShapeRef`'s fail-closed
    index revalidation.

    Frozen/hashable like `SubShapeRef`, since this is a plain value type, not
    an owned entity."""

    sketch_id: str
    entity_type: SketchEntityType
    entity_id: str


@dataclass
class Sketch:
    """An independent 2D sketch, on one of the three fixed reference planes
    or (C3) anchored to a custom `CreatePlaneFeature` instead.

    Each Sketch owns its own Points and entities - nothing is shared
    between Sketches.

    C3: `plane` is `None` for a Sketch created via the Document/Part/Feature
    layer's `SketchFeatureCreate.plane_feature_id` path (see
    `app.document.router.create_sketch_feature`) - its real anchor plane is
    instead resolved live from the owning `SketchFeature.plane_feature_id`
    (see `app.document.create_plane.resolve_sketch_basis`), the same
    "re-derive, don't cache" philosophy `ResolvedPlane` itself already
    follows. Every Sketch created via the standalone `/sketch` API (which
    has no notion of a Part/Feature/CreatePlaneFeature at all) always has a
    real `plane` - `None` only ever appears for a custom-plane-anchored
    Sketch created through the Document layer.
    """

    id: str
    plane: Plane | None
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

    def add_arc(
        self,
        center_point_id: str,
        start_point_id: str,
        end_point_id: str | None = None,
        *,
        end_angle: float | None = None,
        construction: bool = False,
    ) -> Arc:
        """Add an Arc from an existing center Point and an existing start
        Point (together fixing the radius, same as Circle's center/radius
        Point pair) to either an existing end Point (explicit sharing) or
        a new Point computed from the current radius and an end angle
        (radians from the +x axis) - always placed exactly on the circle
        of that radius, mirroring add_circle's existing-vs-computed-point
        pattern.

        Both the start and end Point's distance from center become real
        solver DistanceConstraints, pinned to the *same* radius value at
        creation - keeps the Arc circular under drag exactly like Circle's
        own single radius DistanceConstraint, just applied to both
        defining Points instead of one (see the Arc class docstring).
        """
        center = self.points[center_point_id]
        start = self.points[start_point_id]
        radius = math.hypot(start.x - center.x, start.y - center.y)
        if radius == 0:
            raise ValueError("An arc's start point cannot coincide with its center point")

        if end_point_id is None:
            end_point_id = self.add_point(
                center.x + radius * math.cos(end_angle),
                center.y + radius * math.sin(end_angle),
            ).id
        elif end_point_id not in self.points:
            raise KeyError(end_point_id)

        if len({center_point_id, start_point_id, end_point_id}) != 3:
            raise ValueError("An arc's center, start, and end points must all be distinct")

        radius_constraint = self.add_distance_constraint(center_point_id, start_point_id, radius)
        end_radius_constraint = self.add_distance_constraint(center_point_id, end_point_id, radius)
        arc = Arc(
            id=str(uuid.uuid4()),
            center_point_id=center_point_id,
            start_point_id=start_point_id,
            end_point_id=end_point_id,
            radius_constraint_id=radius_constraint.id,
            end_radius_constraint_id=end_radius_constraint.id,
            construction=construction,
        )
        self.entities[arc.id] = arc
        return arc

    def arcs(self) -> list[Arc]:
        return [entity for entity in self.entities.values() if isinstance(entity, Arc)]

    def add_ellipse(
        self,
        center_point_id: str,
        major_point_id: str | None = None,
        *,
        major_radius: float | None = None,
        angle: float | None = None,
        minor_radius: float,
        construction: bool = False,
    ) -> Ellipse:
        """Add an Ellipse from an existing center Point to either an
        existing major-axis Point (explicit sharing) or a new Point
        computed from a major radius and angle (radians from the +x axis),
        mirroring add_circle's existing-vs-computed-point pattern.
        `minor_radius` is always a plain value (see the Ellipse class
        docstring), never backed by a Point.
        """
        center = self.points[center_point_id]
        if major_point_id is None:
            major_point_id = self.add_point(
                center.x + major_radius * math.cos(angle),
                center.y + major_radius * math.sin(angle),
            ).id
            distance = major_radius
        elif major_point_id not in self.points:
            raise KeyError(major_point_id)
        else:
            major_point = self.points[major_point_id]
            distance = math.hypot(major_point.x - center.x, major_point.y - center.y)

        if center_point_id == major_point_id:
            raise ValueError("An ellipse cannot have the same center and major-axis point")
        if minor_radius <= 0:
            raise ValueError("An ellipse's minor radius must be positive")
        if minor_radius > distance:
            raise ValueError("An ellipse's minor radius cannot exceed its major radius")

        major_constraint = self.add_distance_constraint(center_point_id, major_point_id, distance)
        ellipse = Ellipse(
            id=str(uuid.uuid4()),
            center_point_id=center_point_id,
            major_point_id=major_point_id,
            major_constraint_id=major_constraint.id,
            minor_radius=minor_radius,
            construction=construction,
        )
        self.entities[ellipse.id] = ellipse
        return ellipse

    def ellipses(self) -> list[Ellipse]:
        return [entity for entity in self.entities.values() if isinstance(entity, Ellipse)]

    def add_spline(self, through_point_ids: list[str], *, construction: bool = False) -> Spline:
        """Add a Spline through 2+ existing Points, creating 2 control-
        handle Points per segment (a straight-line-looking 1/3-offset
        initial placement along each segment's own chord - a reasonable
        starting shape before the next solve pulls it, via the
        `SplineTangentConstraint`s created below, into a properly
        tangent-continuous curve) plus one `SplineTangentConstraint` per
        interior through-point. See the Spline class's own docstring for
        why this is built on py-slvs's real cubic-curve primitive rather
        than the plain-Points-only approach every other curved entity here
        uses.
        """
        if len(through_point_ids) < 2:
            raise ValueError("A spline needs at least 2 through-points")
        if len(set(through_point_ids)) != len(through_point_ids):
            raise ValueError("A spline's through-points must all be distinct")
        for point_id in through_point_ids:
            if point_id not in self.points:
                raise KeyError(point_id)

        control_point_ids: list[str] = []
        segments: list[tuple[str, str, str, str]] = []
        for start_id, end_id in zip(through_point_ids, through_point_ids[1:]):
            start = self.points[start_id]
            end = self.points[end_id]
            control1 = self.add_point(
                start.x + (end.x - start.x) / 3, start.y + (end.y - start.y) / 3
            )
            control2 = self.add_point(
                start.x + (end.x - start.x) * 2 / 3, start.y + (end.y - start.y) * 2 / 3
            )
            control_point_ids.append(control1.id)
            control_point_ids.append(control2.id)
            segments.append((start_id, control1.id, control2.id, end_id))

        spline_id = str(uuid.uuid4())
        tangent_constraint_ids: list[str] = []
        for segment_a, segment_b in zip(segments, segments[1:]):
            constraint = SplineTangentConstraint(
                id=str(uuid.uuid4()),
                spline_id=spline_id,
                segment_a_p0=segment_a[0],
                segment_a_p1=segment_a[1],
                segment_a_p2=segment_a[2],
                segment_a_p3=segment_a[3],
                segment_b_p0=segment_b[0],
                segment_b_p1=segment_b[1],
                segment_b_p2=segment_b[2],
                segment_b_p3=segment_b[3],
            )
            self.constraints[constraint.id] = constraint
            tangent_constraint_ids.append(constraint.id)

        spline = Spline(
            id=spline_id,
            through_point_ids=list(through_point_ids),
            control_point_ids=control_point_ids,
            tangent_constraint_ids=tangent_constraint_ids,
            construction=construction,
        )
        self.entities[spline.id] = spline
        return spline

    def splines(self) -> list[Spline]:
        return [entity for entity in self.entities.values() if isinstance(entity, Spline)]

    def add_text(
        self,
        content: str,
        font: str,
        size: float,
        anchor_point_id: str,
        *,
        rotation_degrees: float = 0.0,
        construction: bool = False,
    ) -> TextEntity:
        """Add a Text entity anchored to an existing Point. `content`/
        `font`/`size` validation (non-empty, allow-listed font, positive
        size) happens in `app.sketch.text_geometry.text_to_shape`, called
        lazily wherever the Text's actual geometry is needed (profile
        detection, extrude, the preview-outline endpoint) rather than
        here - this mirrors every other `add_*` here only validating what
        it can cheaply check up front (the anchor Point's existence), not
        pre-flighting a call to what's ultimately a fairly expensive OCCT
        conversion just to validate input at creation time.
        """
        if anchor_point_id not in self.points:
            raise KeyError(anchor_point_id)

        text = TextEntity(
            id=str(uuid.uuid4()),
            content=content,
            font=font,
            size=size,
            anchor_point_id=anchor_point_id,
            rotation_degrees=rotation_degrees,
            construction=construction,
        )
        self.entities[text.id] = text
        return text

    def texts(self) -> list[TextEntity]:
        return [entity for entity in self.entities.values() if isinstance(entity, TextEntity)]

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

    def delete_arc(self, arc_id: str) -> None:
        """Remove an Arc and the two radius DistanceConstraints `add_arc`
        always creates alongside it - same "internal implementation
        detail" exception `delete_circle` already makes for its own radius
        constraint. The center/start/end Points themselves are left
        untouched, same as `delete_line`/`delete_circle`."""
        arc = self.entities.get(arc_id)
        if not isinstance(arc, Arc):
            raise KeyError(arc_id)
        del self.entities[arc_id]
        self.constraints.pop(arc.radius_constraint_id, None)
        self.constraints.pop(arc.end_radius_constraint_id, None)

    def delete_ellipse(self, ellipse_id: str) -> None:
        """Remove an Ellipse and the major-radius DistanceConstraint
        `add_ellipse` always creates alongside it - same "internal
        implementation detail" exception `delete_circle`/`delete_arc`
        already make for their own radius constraint(s). The center/
        major-axis Points themselves are left untouched, same as
        `delete_line`/`delete_circle`/`delete_arc`."""
        ellipse = self.entities.get(ellipse_id)
        if not isinstance(ellipse, Ellipse):
            raise KeyError(ellipse_id)
        del self.entities[ellipse_id]
        self.constraints.pop(ellipse.major_constraint_id, None)

    def delete_spline(self, spline_id: str) -> None:
        """Remove a Spline and every `SplineTangentConstraint` `add_spline`
        created alongside it - same "internal implementation detail"
        exception `delete_circle`/`delete_arc`/`delete_ellipse` already
        make for their own radius constraint(s). Every through-point and
        control-handle Point is left untouched, same as
        `delete_line`/`delete_circle`/`delete_arc`/`delete_ellipse`."""
        spline = self.entities.get(spline_id)
        if not isinstance(spline, Spline):
            raise KeyError(spline_id)
        del self.entities[spline_id]
        for constraint_id in spline.tangent_constraint_ids:
            self.constraints.pop(constraint_id, None)

    def delete_text(self, text_id: str) -> None:
        """Remove a Text entity. Its anchor Point is left untouched, same
        as every other entity's own defining Point(s) - it may be shared
        with other entities via explicit id reference, same as any Point."""
        if not isinstance(self.entities.get(text_id), TextEntity):
            raise KeyError(text_id)
        del self.entities[text_id]

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
            if isinstance(entity, Arc) and point_id in (
                entity.center_point_id,
                entity.start_point_id,
                entity.end_point_id,
            ):
                return f"Point is still referenced by arc {entity.id}"
            if isinstance(entity, Ellipse) and point_id in (entity.center_point_id, entity.major_point_id):
                return f"Point is still referenced by ellipse {entity.id}"
            if isinstance(entity, Spline) and (
                point_id in entity.through_point_ids or point_id in entity.control_point_ids
            ):
                return f"Point is still referenced by spline {entity.id}"
            if isinstance(entity, TextEntity) and point_id == entity.anchor_point_id:
                return f"Point is still referenced by text {entity.id}"
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
        self,
        point_a_id: str,
        point_b_id: str,
        distance: float,
        orientation: Literal["linear", "horizontal", "vertical"] = "linear",
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
            orientation=orientation,
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
