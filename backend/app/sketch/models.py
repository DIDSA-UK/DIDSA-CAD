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
    EqualRadiusConstraint,
    HorizontalConstraint,
    LineDistanceConstraint,
    ParallelConstraint,
    PerpendicularConstraint,
    PointLineDistanceConstraint,
    SplineTangentConstraint,
    TangentConstraint,
    VerticalConstraint,
)
from app.sketch.intersections import (
    arc_vs_arc,
    circle_vs_arc,
    circle_vs_circle,
    line_vs_arc,
    line_vs_circle,
    line_vs_segment,
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


@dataclass(frozen=True)
class ExternalVertexReference:
    """Sketcher-roadmap Phase 4.3 v1: names a Body vertex from *outside*
    this Sketch entirely - `body_id` plus a plain OCCT `topexp.MapShapes`
    vertex index, the same 0-based scheme `app.document.models.SubShapeRef`
    already uses for `SubShapeType.VERTEX`.

    Deliberately a small, sketch-layer-only value type rather than importing
    `SubShapeRef` itself - the sketch layer never depends on the document
    layer anywhere in this codebase (the reverse is true throughout: e.g.
    `app.document.create_plane` imports `app.sketch.models`, never the other
    way around), so the document layer converts to/from this type at its
    own API boundary (`app.document.router`'s external-reference endpoint)
    instead of this module reaching upward for a document-layer type.

    See `Sketch.external_references`'s own doc comment for how a Point
    carrying one of these is created and kept in sync.
    """

    body_id: str
    vertex_index: int


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

    On-device feedback: a Circle's only edge-Point was `radius_point_id`,
    wherever it happened to land when the Circle was drawn - a poor snap/
    connection target since it sits at an arbitrary angle, not one a user
    would predict. `cardinal_point_ids` adds four more, real, independently
    addressable Points at the circle's own North/East/South/West (angles
    90/0/270/180 degrees from +x, i.e. always aligned to the *sketch's*
    global axes, not to wherever `radius_point_id` sits) - in that fixed
    `[north, east, south, west]` order, mirroring `Spline`'s own
    `through_point_ids`/`control_point_ids` list-of-Points convention
    rather than four separate named fields. Each is solver-locked (see
    `add_circle`) via an `EqualRadiusConstraint` against the circle's own
    `radius_point_id` (so it always stays exactly on the circle, in sync
    with any radius edit - no separate, independently-driftable radius
    value) plus a zero-value `DistanceConstraint` pinning it to the correct
    global axis through center (`orientation="horizontal"` for North/South,
    `"vertical"` for East/West - a `DistanceConstraint` of exactly 0 along
    the fixed reference direction `SolverBuilder.horizontal_distance`/
    `vertical_distance` project onto, not a Euclidean/near-degenerate
    zero-length constraint). `cardinal_constraint_ids` holds all eight of
    those auxiliary constraints' ids (four EqualRadius, four zero-distance),
    order not significant - see `Sketch.delete_circle` for why they need to
    be tracked at all (cleaned up alongside the Circle itself, same
    "internal implementation detail" exception `radius_constraint_id`
    already gets).
    """

    id: str
    center_point_id: str
    radius_point_id: str
    radius_constraint_id: str
    cardinal_point_ids: list[str]
    cardinal_constraint_ids: list[str]

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
    like Circle's: `add_arc` creates a single DistanceConstraint
    (`radius_constraint_id`) pinning the start Point's distance from
    center, plus an EqualRadiusConstraint (`end_radius_constraint_id`,
    despite the name - kept for API/serialization stability) tying the end
    Point's distance from center to that *same* solver-tracked value, so a
    drag of either Point (or the center) keeps both ends on the same
    circle after the next solve, with only one independently-editable
    radius dimension (feedback round: a plain second DistanceConstraint
    here meant an Arc showed two separate, confusingly-independent radius
    dimensions instead of one). There is no dedicated py-slvs arc entity
    involved - EqualRadiusConstraint's own centre-to-rim virtual line
    segment trick (see its own docstring) achieves the same result with no
    new solver primitives, mirroring the project's "reuse existing
    constraint types" approach to Circle.

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
    """An ellipse defined by a center Point and two pairs of axis-tip
    Points (`major_point_id`/`major_point_neg_id`, `minor_point_id`/
    `minor_point_neg_id`) - all five real, independently addressable
    Points. Each axis's *positive* tip is solver-tracked via its own
    DistanceConstraint to center (its distance is that axis's radius, its
    direction from center is that axis's own rotation), exactly mirroring
    Circle's own center/radius Point pair. Its *negative* tip is the
    reflection of the positive one through center, pinned there via an
    AtMidpointConstraint (`major_midpoint_constraint_id`/
    `minor_midpoint_constraint_id`) that forces center to be the midpoint
    of the full axis Line spanning tip-to-tip - so both axes are real,
    full-diameter construction Lines (`major_axis_line_id`/
    `minor_axis_line_id`) with a genuine Point at all 4 axis/ellipse
    intersections, not center-to-tip spokes (feedback round). A
    PerpendicularConstraint between the two full axis Lines
    (`perpendicular_constraint_id`) keeps the minor axis exactly
    perpendicular to the major axis under drag.

    `major_radius`/`minor_radius` must always satisfy major >= minor
    (OCCT's own `gp_Elips` requirement, enforced at creation time - see
    `Sketch.add_ellipse`). Both are edited the same way Circle/Arc's own
    radius is: PATCHing the underlying DistanceConstraint
    (`major_constraint_id`/`minor_constraint_id`) via
    `app.sketch.router.update_constraint_value`, not a field on the
    Ellipse itself.

    Does NOT override `endpoint_point_ids()`, for the same reason Circle
    doesn't: an Ellipse is always its own standalone closed profile, never
    part of a Line/Arc chain's connectivity graph - see `profile.py`'s
    `_ellipse_profile`/`_is_ellipse_profile`, mirroring Circle's own
    standalone-profile handling. Its two axis Lines are always
    `construction=True`, so `profile.py`'s `real_entities` filter already
    excludes them from that chain-walking graph on its own.

    No dedicated py-slvs entity is involved (py-slvs 1.0.6 has no ellipse
    primitive at all, confirmed by inspecting the installed solver module -
    unlike Arc, which at least has an unused one) - this is pure Point +
    DistanceConstraint/AtMidpointConstraint reuse, same as Circle/Arc.
    """

    id: str
    center_point_id: str
    major_point_id: str
    major_point_neg_id: str
    major_constraint_id: str
    major_midpoint_constraint_id: str
    minor_point_id: str
    minor_point_neg_id: str
    minor_constraint_id: str
    minor_midpoint_constraint_id: str
    major_axis_line_id: str
    minor_axis_line_id: str
    perpendicular_constraint_id: str

    @property
    def type(self) -> str:
        return "ellipse"

    def major_radius(self, points: dict[str, Point]) -> float:
        center = points[self.center_point_id]
        major = points[self.major_point_id]
        return math.hypot(major.x - center.x, major.y - center.y)

    def minor_radius(self, points: dict[str, Point]) -> float:
        center = points[self.center_point_id]
        minor = points[self.minor_point_id]
        return math.hypot(minor.x - center.x, minor.y - center.y)

    def rotation(self, points: dict[str, Point]) -> float:
        """The major axis's direction from center, in radians from the +x
        axis - the same angle `app.document.extrude.wire_for_profile` uses
        to orient the ellipse's OCCT `gp_Elips` (via its X reference
        direction), and the client uses to rotate its own rendering."""
        center = points[self.center_point_id]
        major = points[self.major_point_id]
        return math.atan2(major.y - center.y, major.x - center.x)


@dataclass
class Polygon(SketchEntity):
    """A regular N-gon defined by a center Point and `sides` vertex Points
    (`vertex_point_ids`, in order, connected in a cycle by `line_ids`) -
    real, independently addressable Points/Lines, same as every other
    entity here.

    Bug fix (sketcher-roadmap feedback round): a Polygon used to be a
    client-only shortcut with no persisted entity of its own - just plain
    Points/Lines/Constraints the client orchestrated across several
    sequential API calls, with nothing server-side to reliably identify
    "these N points + these constraints form a Polygon" later (e.g. to
    reinterpret dragging a vertex as a circumradius edit rather than an
    unconstrained 2D point move - see `SketchController`'s own drag
    handling). `add_polygon` now creates everything atomically in one call,
    mirroring Arc/Ellipse.

    The first vertex's (`vertex_point_ids[0]`) distance from center is the
    Polygon's one real, independently-editable radius DistanceConstraint
    (`radius_constraint_id`) - exactly like Circle/Arc/Ellipse's own single-
    editable-radius design. Every other vertex is tied to that same value
    via its own EqualRadiusConstraint (`equal_radius_constraint_ids`, one
    per remaining vertex, via `add_equal_radius_constraint_from_points`
    since a Polygon has no owning Circle/Arc to resolve a center/rim pair
    from). Consecutive edges are pinned to equal length
    (`equal_length_constraint_ids`) and to the same exterior angle,
    `360/sides` degrees (`angle_constraint_ids`) - `sides - 1` of each
    (the last pair's equality follows by transitivity) - which together
    keep the shape genuinely rigid/regular under an incremental drag (see
    the regular-hexagon convergence test this mirrors).

    Does NOT override `endpoint_point_ids()` (unlike Arc): a Polygon's own
    Lines already form a closed loop by themselves, so it's always its own
    standalone closed profile, never part of a larger Line chain's
    connectivity graph - same reasoning as Circle/Ellipse.
    """

    id: str
    center_point_id: str
    vertex_point_ids: list[str]
    line_ids: list[str]
    radius_constraint_id: str
    equal_radius_constraint_ids: list[str]
    equal_length_constraint_ids: list[str]
    angle_constraint_ids: list[str]
    sides: int

    @property
    def type(self) -> str:
        return "polygon"

    def radius(self, points: dict[str, Point]) -> float:
        center = points[self.center_point_id]
        vertex = points[self.vertex_point_ids[0]]
        return math.hypot(vertex.x - center.x, vertex.y - center.y)


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
    edited the same direct-PATCH way Line's own `length` field is.

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
    POLYGON = "polygon"
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


class NoIntersectionFoundError(ValueError):
    """Sketcher-roadmap Phase 11: `Sketch.trim_or_extend_line` raises this
    specifically (a `ValueError` subclass, so any existing bare `except
    ValueError` elsewhere still catches it as a fallback) when no valid
    trim/extend target exists - a real, expected outcome the router surfaces
    as 422, distinct from every other `ValueError` this method raises
    (invalid endpoint, Polygon-owned edge), which stay ordinary 400s."""


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

    Sketcher-roadmap Phase 5: `flip`/`rotation_quarter_turns` are this
    Sketch's own orientation *within* its fixed `plane` - meaningless (and
    ignored) for a `plane is None` Sketch, whose anchor is instead a full,
    independently-orientable `CreatePlaneFeature` basis. Deliberately kept
    as two small discrete fields rather than baking the flip/rotation into
    every Point's stored (x, y) - the solver only ever sees this Sketch's
    flat local (x, y) space (see `solver.py`'s own workplane, which is
    orientation-agnostic - always the identity origin/normal regardless of
    `plane`), so nothing about constraint-solving needs to change here at
    all, and "redefining" a Sketch's orientation after the fact (long-press
    re-entry into the same picker) is just flipping these two fields, not a
    re-projection of any existing geometry - see
    `app.document.plane_geometry.oriented_basis_for_plane`, the one place
    that actually turns `(flip, rotation_quarter_turns)` into a real
    world-space basis, for how a fixed-plane Sketch's local (x, y) maps
    into 3D. `rotation_quarter_turns` is always normalized into `0..3` (a
    90-degree-CCW-per-step rotation of the plane's own default in-plane
    basis, applied after `flip`); values outside that range are never
    stored (see `Sketch.set_orientation`).
    """

    id: str
    plane: Plane | None
    points: dict[str, Point] = field(default_factory=dict)
    entities: dict[str, SketchEntity] = field(default_factory=dict)
    constraints: dict[str, Constraint] = field(default_factory=dict)
    flip: bool = False
    rotation_quarter_turns: int = 0
    # Sketcher-roadmap Phase 4.3 v1: Point id -> the Body vertex it tracks.
    # Such a Point is real and ordinary in every other respect (any existing
    # DistanceConstraint/ghost/undo/persistence code path works against it
    # unmodified - see the roadmap doc's own "materialize rather than
    # invent a parallel system" reasoning) except two things this dict
    # drives: `solve_sketch` always pins every id in here into the fixed
    # solver group, the same way the origin already is (see that function's
    # own doc comment), and the document layer re-resolves/refreshes each
    # one's (x, y) from the Body's *current* topology at its own natural
    # touch points (a Sketch has no OCCT access itself to do this on its
    # own - see `app.document.create_plane.refresh_external_references`),
    # leaving the Point at its last-known position (and reporting the id as
    # lost) whenever a reference no longer resolves.
    external_references: dict[str, ExternalVertexReference] = field(default_factory=dict)
    _origin_point_id: str | None = field(default=None, repr=False)

    def set_orientation(self, *, flip: bool, rotation_quarter_turns: int) -> None:
        """The one mutator for `flip`/`rotation_quarter_turns` - normalizes
        `rotation_quarter_turns` into `0..3` (a quarter-turn count has no
        meaningful value outside that range; -1 and 3 are the same physical
        orientation) so every reader can assume that range without its own
        modulo."""
        self.flip = flip
        self.rotation_quarter_turns = rotation_quarter_turns % 4

    def add_point(self, x: float, y: float) -> Point:
        point = Point(id=str(uuid.uuid4()), x=x, y=y)
        self.points[point.id] = point
        return point

    def add_external_vertex_reference(self, x: float, y: float, ref: ExternalVertexReference) -> Point:
        """Sketcher-roadmap Phase 4.3 v1: materializes `ref` as a real Point
        at its already-resolved-and-projected `(x, y)` (the document layer
        computes this - see `app.document.create_plane.
        resolve_external_vertex_position` - since resolving a Body vertex
        needs OCCT/Part access this Sketch itself never has), and records
        the mapping in `external_references` so `solve_sketch` pins it and
        the document layer can later refresh/validate it."""
        point = self.add_point(x, y)
        self.external_references[point.id] = ref
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
        radius Point (explicit sharing), a new Point computed from a radius
        and angle (radians from the +x axis), or - when [angle] is omitted
        entirely alongside a bare [radius] - the centre-point circle tool's
        own mode: the new Point becomes the circle's north cardinal point
        directly (see `_add_cardinal_points`'s own doc comment) rather than
        a fifth, separately-floating Point, so it's vertically above centre
        by construction and a single radius dimension plus grounding the
        centre is enough to fully constrain the whole circle.

        The radius is a real solver constraint, not just a stored number:
        this always creates a DistanceConstraint between the center and
        radius Points (reusing the existing constraint type as-is, since a
        radius IS a distance constraint), so subsequent solves keep it
        accurate as either Point moves. It starts `provisional=True` - it
        pins the shape rigid for editing/rendering purposes, but is skipped
        by the solver's DOF accounting until the user actually confirms a
        radius value (see DistanceConstraint.provisional), so a freshly
        drawn circle correctly reports as under-constrained rather than
        fully constrained with no user-visible dimension.
        """
        center = self.points[center_point_id]
        radius_point_is_north = radius_point_id is None and angle is None
        if radius_point_is_north:
            if radius is None:
                raise ValueError("Provide either 'radius_point_id', or 'radius' (optionally with 'angle')")
            radius_point_id = self.add_point(center.x, center.y + radius).id
            distance = radius
        elif radius_point_id is None:
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

        radius_constraint = self.add_distance_constraint(
            center_point_id, radius_point_id, distance, provisional=True
        )
        if radius_point_is_north:
            # North already has its real radius Distance constraint (just
            # created above) - only needs the same axis-alignment pin every
            # cardinal point gets, not an EqualRadius tie back to itself.
            axis_constraint = self.add_distance_constraint(
                center_point_id, radius_point_id, 0.0, orientation=self._CARDINAL_ORIENTATIONS[0]
            )
            other_point_ids, other_constraint_ids = self._add_cardinal_points(
                center_point_id, radius_point_id, distance, skip_north=True
            )
            cardinal_point_ids = [radius_point_id, *other_point_ids]
            cardinal_constraint_ids = [axis_constraint.id, *other_constraint_ids]
        else:
            cardinal_point_ids, cardinal_constraint_ids = self._add_cardinal_points(
                center_point_id, radius_point_id, distance
            )
        circle = Circle(
            id=str(uuid.uuid4()),
            center_point_id=center_point_id,
            radius_point_id=radius_point_id,
            radius_constraint_id=radius_constraint.id,
            cardinal_point_ids=cardinal_point_ids,
            cardinal_constraint_ids=cardinal_constraint_ids,
            construction=construction,
        )
        self.entities[circle.id] = circle
        return circle

    # North/East/South/West, in that fixed order - see Circle's own
    # `cardinal_point_ids` doc comment.
    _CARDINAL_ANGLES: tuple[float, ...] = (math.pi / 2, 0.0, 3 * math.pi / 2, math.pi)
    _CARDINAL_ORIENTATIONS: tuple[Literal["horizontal", "vertical"], ...] = (
        "horizontal",  # North: pin X to match center, Y free (set by EqualRadius)
        "vertical",  # East: pin Y to match center, X free
        "horizontal",  # South
        "vertical",  # West
    )

    def _add_cardinal_points(
        self, center_point_id: str, radius_point_id: str, radius: float, *, skip_north: bool = False
    ) -> tuple[list[str], list[str]]:
        """Creates North/East/South/West Points `add_circle` gives every new
        Circle (see `Circle.cardinal_point_ids`'s own doc comment) - each
        solver-locked onto the circle at its own fixed global-axis angle via
        an `EqualRadiusConstraint` against [radius_point_id] (stays in sync
        with any later radius edit) plus a zero-value `DistanceConstraint`
        pinning it to the correct axis through center. Returns
        `(point_ids, constraint_ids)`, both in the shape
        `Circle.cardinal_point_ids`/`cardinal_constraint_ids` expect.

        [skip_north] omits North from this loop entirely - used by
        `add_circle`'s own centre-point-circle-tool mode, where
        [radius_point_id] already *is* North (real Distance constraint, no
        EqualRadius needed against itself) and this only needs to add the
        remaining East/South/West.
        """
        center = self.points[center_point_id]
        point_ids: list[str] = []
        constraint_ids: list[str] = []
        angles_orientations = list(zip(self._CARDINAL_ANGLES, self._CARDINAL_ORIENTATIONS))
        if skip_north:
            angles_orientations = angles_orientations[1:]
        for angle, orientation in angles_orientations:
            point = self.add_point(
                center.x + radius * math.cos(angle),
                center.y + radius * math.sin(angle),
            )
            equal_radius = EqualRadiusConstraint(
                id=str(uuid.uuid4()),
                center1_point_id=center_point_id,
                radius1_point_id=radius_point_id,
                center2_point_id=center_point_id,
                radius2_point_id=point.id,
            )
            self.constraints[equal_radius.id] = equal_radius
            axis_constraint = self.add_distance_constraint(
                center_point_id, point.id, 0.0, orientation=orientation
            )
            point_ids.append(point.id)
            constraint_ids.append(equal_radius.id)
            constraint_ids.append(axis_constraint.id)
        return point_ids, constraint_ids

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

        The start Point's distance from center becomes the Arc's one real,
        independently-editable radius DistanceConstraint; the end Point is
        tied to that same value via an EqualRadiusConstraint instead of a
        second independent DistanceConstraint - keeps the Arc circular
        under drag with a single radius dimension (see the Arc class
        docstring).
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

        radius_constraint = self.add_distance_constraint(
            center_point_id, start_point_id, radius, provisional=True
        )
        end_radius_constraint = EqualRadiusConstraint(
            id=str(uuid.uuid4()),
            center1_point_id=center_point_id,
            radius1_point_id=start_point_id,
            center2_point_id=center_point_id,
            radius2_point_id=end_point_id,
        )
        self.constraints[end_radius_constraint.id] = end_radius_constraint
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

        `minor_radius` places a new minor-axis Point exactly perpendicular
        to the major axis (never an explicit-sharing option - there is no
        pre-existing minor-axis Point a caller could already know the id
        of). Both axis Points get their own real DistanceConstraint to
        center; a second Point per axis, placed diametrically opposite and
        pinned there via AtMidpointConstraint (center = the midpoint of the
        full tip-to-tip axis Line), gives each axis a real, full-diameter
        construction Line with a Point at all 4 axis/ellipse intersections
        (see the Ellipse class docstring) - tied together by a
        PerpendicularConstraint so both axes stay perpendicular under drag.
        """
        center = self.points[center_point_id]
        if major_point_id is None:
            major_point_id = self.add_point(
                center.x + major_radius * math.cos(angle),
                center.y + major_radius * math.sin(angle),
            ).id
            distance = major_radius
            major_angle = angle
        elif major_point_id not in self.points:
            raise KeyError(major_point_id)
        else:
            major_point = self.points[major_point_id]
            distance = math.hypot(major_point.x - center.x, major_point.y - center.y)
            major_angle = math.atan2(major_point.y - center.y, major_point.x - center.x)

        if center_point_id == major_point_id:
            raise ValueError("An ellipse cannot have the same center and major-axis point")
        if minor_radius <= 0:
            raise ValueError("An ellipse's minor radius must be positive")
        if minor_radius > distance:
            raise ValueError("An ellipse's minor radius cannot exceed its major radius")

        minor_angle = major_angle + math.pi / 2
        minor_point_id = self.add_point(
            center.x + minor_radius * math.cos(minor_angle),
            center.y + minor_radius * math.sin(minor_angle),
        ).id
        major_point_neg_id = self.add_point(
            center.x - distance * math.cos(major_angle),
            center.y - distance * math.sin(major_angle),
        ).id
        minor_point_neg_id = self.add_point(
            center.x - minor_radius * math.cos(minor_angle),
            center.y - minor_radius * math.sin(minor_angle),
        ).id

        major_constraint = self.add_distance_constraint(
            center_point_id, major_point_id, distance, provisional=True
        )
        minor_constraint = self.add_distance_constraint(
            center_point_id, minor_point_id, minor_radius, provisional=True
        )
        major_axis_line = self.add_line(major_point_neg_id, major_point_id, construction=True)
        minor_axis_line = self.add_line(minor_point_neg_id, minor_point_id, construction=True)
        major_midpoint = self.add_at_midpoint_constraint(center_point_id, major_axis_line.id)
        minor_midpoint = self.add_at_midpoint_constraint(center_point_id, minor_axis_line.id)
        perpendicular = self.add_perpendicular_constraint(major_axis_line.id, minor_axis_line.id)

        ellipse = Ellipse(
            id=str(uuid.uuid4()),
            center_point_id=center_point_id,
            major_point_id=major_point_id,
            major_point_neg_id=major_point_neg_id,
            major_constraint_id=major_constraint.id,
            major_midpoint_constraint_id=major_midpoint.id,
            minor_point_id=minor_point_id,
            minor_point_neg_id=minor_point_neg_id,
            minor_constraint_id=minor_constraint.id,
            minor_midpoint_constraint_id=minor_midpoint.id,
            major_axis_line_id=major_axis_line.id,
            minor_axis_line_id=minor_axis_line.id,
            perpendicular_constraint_id=perpendicular.id,
            construction=construction,
        )
        self.entities[ellipse.id] = ellipse
        return ellipse

    def ellipses(self) -> list[Ellipse]:
        return [entity for entity in self.entities.values() if isinstance(entity, Ellipse)]

    def add_polygon(
        self,
        center_point_id: str,
        first_vertex_point_id: str,
        sides: int,
        *,
        construction: bool = False,
    ) -> Polygon:
        """Add a regular Polygon from an existing center Point and an
        existing first-vertex Point (together fixing the circumradius and
        rotation, same as Arc's center/start pair) - every other vertex is
        computed here (same regular-polygon math the client's own
        `_polygonVertices` ghost-preview uses: `center + radius *
        (cos(baseAngle + 2*pi*i/sides), sin(...))`, `baseAngle` being the
        first vertex's own angle from center) and created as a brand new
        Point, mirroring Arc's own `end_angle` path - there is no existing-
        Point-sharing option for these, since a regular polygon's other
        vertices can only ever come from its own creation.

        See the Polygon class docstring for what the constraint chain does
        and why."""
        if sides < 3:
            raise ValueError("A polygon must have at least 3 sides")
        center = self.points[center_point_id]
        first_vertex = self.points[first_vertex_point_id]
        radius = math.hypot(first_vertex.x - center.x, first_vertex.y - center.y)
        if radius == 0:
            raise ValueError("A polygon's first vertex cannot coincide with its center point")
        base_angle = math.atan2(first_vertex.y - center.y, first_vertex.x - center.x)

        vertex_point_ids = [first_vertex_point_id]
        for i in range(1, sides):
            angle = base_angle + 2 * math.pi * i / sides
            vertex_point_ids.append(
                self.add_point(center.x + radius * math.cos(angle), center.y + radius * math.sin(angle)).id
            )

        line_ids = [
            self.add_line(vertex_point_ids[i], vertex_point_ids[(i + 1) % sides]).id for i in range(sides)
        ]

        # Provisional: pins the shape rigid for editing/rendering, but the
        # solver skips it until the user confirms a real radius value (see
        # DistanceConstraint.provisional) - the polygon tool is a shortcut,
        # not itself a dimensioning action.
        radius_constraint = self.add_distance_constraint(
            center_point_id, first_vertex_point_id, radius, provisional=True
        )
        equal_radius_constraint_ids = [
            self.add_equal_radius_constraint_from_points(
                center_point_id, first_vertex_point_id, center_point_id, vertex_point_ids[i]
            ).id
            for i in range(1, sides)
        ]

        # Equal side lengths alone leave a regular-looking polygon free to
        # collapse into a non-regular (even self-intersecting) shape under
        # drag - equal radii (above) rule out that particular degenerate
        # branch, but not all of them (confirmed directly against the
        # solver: equal-length + equal-radius alone can still converge with
        # non-adjacent vertices coincident). Pinning the angle between every
        # consecutive pair of edges to the same exterior angle (360/sides
        # degrees) closes that gap and keeps the shape genuinely
        # rigid/regular under an incremental drag - see the regular-hexagon
        # convergence test this mirrors.
        exterior_angle_degrees = 360.0 / sides
        equal_length_constraint_ids = []
        angle_constraint_ids = []
        for i in range(sides - 1):
            equal_length_constraint_ids.append(
                self.add_equal_length_constraint(line_ids[i], line_ids[i + 1]).id
            )
            angle_constraint_ids.append(
                self.add_angle_constraint(line_ids[i], line_ids[i + 1], exterior_angle_degrees).id
            )

        polygon = Polygon(
            id=str(uuid.uuid4()),
            center_point_id=center_point_id,
            vertex_point_ids=vertex_point_ids,
            line_ids=line_ids,
            radius_constraint_id=radius_constraint.id,
            equal_radius_constraint_ids=equal_radius_constraint_ids,
            equal_length_constraint_ids=equal_length_constraint_ids,
            angle_constraint_ids=angle_constraint_ids,
            sides=sides,
            construction=construction,
        )
        self.entities[polygon.id] = polygon
        return polygon

    def polygons(self) -> list[Polygon]:
        return [entity for entity in self.entities.values() if isinstance(entity, Polygon)]

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

    # Sketcher-roadmap Phase 11: a sane bound on how far a trim/extend
    # target can be from where the Line currently ends, in sketch units -
    # guards against a genuinely-but-uselessly-distant result from a
    # near-parallel target (the same "wildly distant, useless result"
    # concern `sketch_canvas.dart`'s own `_maxAngleIntersectionDistance`
    # constant already guards against for the angle-ghost arc, just in
    # sketch space here rather than screen pixels).
    _TRIM_MAX_DISTANCE = 10000.0

    def trim_or_extend_line(self, line_id: str, moved_point_id: str) -> tuple[Line, Point, bool]:
        """Trims `line_id` back to, or extends it out to reach, the nearest
        Line/Circle/Arc it crosses - the same operation either way (see
        `app.sketch.router`'s trim endpoint doc comment): only whether the
        found intersection lies inside or outside the Line's current span
        differs, and this method doesn't need to know which case it is
        either.

        `moved_point_id` identifies which of the Line's own two endpoints
        is being adjusted - the *other* end stays fixed and anchors the
        direction searched along, from the fixed end through and beyond
        the moved end (never back past the fixed end - a trim/extend that
        would need to flip the Line's own direction makes no sense). Every
        other Line/Circle/Arc entity in the Sketch is checked for a
        crossing against that direction, always against each target's own
        actual, finite extent (a Line's real segment, an Arc's real sweep)
        - never another entity's own infinite extension. Among valid
        candidates within `_TRIM_MAX_DISTANCE` of the current position, the
        one nearest it wins - the standard CAD "nearest to where you
        already are" trim/extend convention, naturally covering both
        directions (a nearer candidate trims the Line shorter; a farther
        one, beyond the current end, extends it).

        Splines/Ellipses are never intersection targets (see
        `app.sketch.intersections`'s own module doc comment - no
        closed-form solve without curve-specific root-finding, out of
        scope for v1), and only a Line can be the entity trimmed/extended
        at all - trimming an Arc/Circle's own sweep would need to redefine
        that entity's own topology (its start/end Points, its
        EqualRadiusConstraint chain), a materially bigger problem than
        repointing one end of a Line, deliberately deferred rather than
        half-built here.

        Raises `KeyError` if `line_id` isn't a Line, `ValueError` if
        `moved_point_id` isn't one of its own two endpoints or the Line
        belongs to a Polygon (trimming one edge out from under a regular
        Polygon's own rigid constraint chain needs real entity-demotion
        support this doesn't have yet - a v1 scope decision, rejected
        rather than silently corrupting the Polygon's own bookkeeping), or
        `NoIntersectionFoundError` (itself a `ValueError` subclass) if no
        valid intersection is found within range at all - a real, expected
        outcome a caller should surface distinctly from every other case
        here (see the router's own 400 vs
        422 split).

        Returns `(line, moved_point, created_new_point)` - `moved_point` is
        always a real Point at the new position (`line.start_point_id`/
        `line.end_point_id` already reflects it); `created_new_point` is
        True when `moved_point_id`'s original Point was shared with other
        geometry/constraints - moving it in place would have silently
        dragged whatever else referenced it, exactly the class of bug
        `add_polygon`'s own history already went through several rounds
        fixing - so a fresh Point was created at the new position and only
        this Line's own end repointed to it, leaving the original Point
        exactly where it was (see `_point_deletion_blocker`'s own doc
        comment on its `exclude_entity_id` parameter, reused here for the
        same "is this Point shared" question).
        """
        line = self.entities.get(line_id)
        if not isinstance(line, Line):
            raise KeyError(line_id)
        if moved_point_id == line.start_point_id:
            fixed_point_id = line.end_point_id
        elif moved_point_id == line.end_point_id:
            fixed_point_id = line.start_point_id
        else:
            raise ValueError(f"Point {moved_point_id} is not an endpoint of line {line_id}")
        for entity in self.entities.values():
            if isinstance(entity, Polygon) and line_id in entity.line_ids:
                raise ValueError(f"Cannot trim/extend line {line_id} - it is an edge of polygon {entity.id}")

        fixed_point = self.points[fixed_point_id]
        moved_point = self.points[moved_point_id]
        fixed_xy = (fixed_point.x, fixed_point.y)
        moved_xy = (moved_point.x, moved_point.y)
        line_length = math.hypot(moved_xy[0] - fixed_xy[0], moved_xy[1] - fixed_xy[1])
        if line_length < 1e-9:
            raise ValueError(f"Cannot trim/extend a zero-length line {line_id}")
        current_t = 1.0  # by construction: fixed_xy + 1.0 * (moved_xy - fixed_xy) == moved_xy

        candidates: list[tuple[float, tuple[float, float]]] = []
        for entity in self.entities.values():
            if entity.id == line_id:
                continue
            if isinstance(entity, Line):
                other_start = self.points[entity.start_point_id]
                other_end = self.points[entity.end_point_id]
                hit = line_vs_segment(
                    fixed_xy, moved_xy, (other_start.x, other_start.y), (other_end.x, other_end.y)
                )
                if hit is not None:
                    candidates.append(hit)
            elif isinstance(entity, Circle):
                center = self.points[entity.center_point_id]
                candidates.extend(
                    line_vs_circle(fixed_xy, moved_xy, (center.x, center.y), entity.radius(self.points))
                )
            elif isinstance(entity, Arc):
                center = self.points[entity.center_point_id]
                start = self.points[entity.start_point_id]
                end = self.points[entity.end_point_id]
                candidates.extend(
                    line_vs_arc(
                        fixed_xy,
                        moved_xy,
                        (center.x, center.y),
                        entity.radius(self.points),
                        (start.x, start.y),
                        (end.x, end.y),
                    )
                )

        valid = []
        for t, point in candidates:
            if t <= 1e-6 or abs(t - current_t) <= 1e-9:
                continue  # behind the fixed end, or exactly the current position - not a real target
            if abs(t - current_t) * line_length > self._TRIM_MAX_DISTANCE:
                continue
            valid.append((t, point))
        if not valid:
            raise NoIntersectionFoundError(f"No intersection found to trim/extend line {line_id} to")
        _, best_point = min(valid, key=lambda candidate: abs(candidate[0] - current_t))

        # On-device feedback (closed-profile bug fix): see
        # `_existing_point_at`'s own doc comment - `best_point` is a purely
        # geometric target, with no awareness on its own of whether some
        # other entity's Point already sits there (e.g. trimming/extending
        # this Line to meet a Circle that itself gets trimmed at the very
        # same spot later). Looked up before mutating anything, so there's
        # nothing to accidentally self-match.
        if self._point_deletion_blocker(moved_point_id, exclude_entity_id=line_id) is not None:
            existing = self._existing_point_at(*best_point)
            new_point = self.add_point(*best_point)
            if existing is not None:
                self.add_coincident_constraint(new_point.id, existing.id)
            if moved_point_id == line.start_point_id:
                line.start_point_id = new_point.id
            else:
                line.end_point_id = new_point.id
            return (line, new_point, True)
        existing = self._existing_point_at(*best_point, exclude_ids=frozenset({moved_point_id}))
        moved_point.x, moved_point.y = best_point
        if existing is not None:
            self.add_coincident_constraint(moved_point_id, existing.id)
        return (line, moved_point, False)

    def _line_candidates_against(self, a_xy: tuple[float, float], b_xy: tuple[float, float], exclude_id: str):
        """Every `(t, point)` where some other entity crosses the *infinite*
        line through `a_xy`/`b_xy`, `t` the parameter along `a_xy -> b_xy` -
        the exact candidate-gathering loop `trim_or_extend_line` already
        used, factored out so [split_trim_line] can reuse it unmodified
        rather than duplicating it."""
        candidates: list[tuple[float, tuple[float, float]]] = []
        for entity in self.entities.values():
            if entity.id == exclude_id:
                continue
            if isinstance(entity, Line):
                other_start = self.points[entity.start_point_id]
                other_end = self.points[entity.end_point_id]
                hit = line_vs_segment(a_xy, b_xy, (other_start.x, other_start.y), (other_end.x, other_end.y))
                if hit is not None:
                    candidates.append(hit)
            elif isinstance(entity, Circle):
                center = self.points[entity.center_point_id]
                candidates.extend(line_vs_circle(a_xy, b_xy, (center.x, center.y), entity.radius(self.points)))
            elif isinstance(entity, Arc):
                center = self.points[entity.center_point_id]
                start = self.points[entity.start_point_id]
                end = self.points[entity.end_point_id]
                candidates.extend(
                    line_vs_arc(
                        a_xy, b_xy, (center.x, center.y), entity.radius(self.points), (start.x, start.y), (end.x, end.y)
                    )
                )
        return candidates

    def split_trim_line(self, line_id: str, click_x: float, click_y: float) -> tuple[Line, Line]:
        """On-device feedback ("trim/extend should prioritize the part of
        the line clicked, it maybe the middle, eg. a line completely
        crossing through a circle"): [trim_or_extend_line] only ever moves
        one of the Line's own two existing endpoints - it can shorten or
        lengthen the Line, but can never remove a *middle* segment while
        keeping both outer pieces, because there is only ever one Line
        entity to move an end of. This is the real, separate operation that
        case needs: [click_x]/[click_y] is projected onto the Line's own
        infinite extension exactly the way [trim_or_extend_line]'s own
        candidates are gathered (see [_line_candidates_against]), and if
        the click falls strictly between two *interior* crossings (real
        intersections found on both sides of it, neither at the Line's own
        original start/end), the clicked segment between them is removed by
        splitting the Line into two new Lines - `[start, nearer-crossing]`
        and `[farther-crossing, end]` - and deleting the original.

        Raises `NoIntersectionFoundError` if the click isn't bracketed by
        two interior crossings (the click's own cell touches an original
        endpoint instead, or there's no crossing on one side at all) - the
        caller (see `app.sketch.router`'s trim endpoint) falls back to
        [trim_or_extend_line]'s own single-endpoint-move behaviour for
        that case, unchanged.

        A real, documented limitation, not a crash risk: any Vertical/
        Horizontal/Parallel/... constraint that captured this Line's own
        id (not just its Point ids - see `VerticalConstraint`'s own
        docstring for why solving is unaffected) goes visually dangling
        once the Line is deleted - the solve itself stays correct (those
        constraints solve against captured Point ids, which are untouched),
        but the client's own rendering already degrades that gracefully
        (skips a constraint whose entity id no longer resolves, per
        `SketchController.constraintOverlayItems`'s own null-guards) rather
        than crashing, so this is accepted rather than blocked outright -
        matching this method's own "additive, not a rewrite of the
        existing single-endpoint path" scope.
        """
        line = self.entities.get(line_id)
        if not isinstance(line, Line):
            raise KeyError(line_id)
        for entity in self.entities.values():
            if isinstance(entity, Polygon) and line_id in entity.line_ids:
                raise ValueError(f"Cannot split line {line_id} - it is an edge of polygon {entity.id}")

        a = self.points[line.start_point_id]
        b = self.points[line.end_point_id]
        a_xy = (a.x, a.y)
        b_xy = (b.x, b.y)
        dx, dy = b_xy[0] - a_xy[0], b_xy[1] - a_xy[1]
        length_sq = dx * dx + dy * dy
        if length_sq < 1e-18:
            raise ValueError(f"Cannot split a zero-length line {line_id}")
        click_t = ((click_x - a_xy[0]) * dx + (click_y - a_xy[1]) * dy) / length_sq

        candidates = self._line_candidates_against(a_xy, b_xy, exclude_id=line_id)
        tolerance = 1e-6
        interior = sorted((t, point) for t, point in candidates if tolerance < t < 1 - tolerance)

        left = None
        right = None
        for t, point in interior:
            if t <= click_t:
                left = (t, point)
            elif right is None:
                right = (t, point)
                break
        if left is None or right is None:
            raise NoIntersectionFoundError(
                f"Click on line {line_id} isn't bracketed by two interior crossings to split at"
            )

        left_point = self.add_point(*left[1])
        right_point = self.add_point(*right[1])
        line1 = self.add_line(line.start_point_id, left_point.id, construction=line.construction)
        line2 = self.add_line(right_point.id, line.end_point_id, construction=line.construction)
        self.delete_line(line_id)
        return (line1, line2)

    def _circle_candidates_against(self, center: tuple[float, float], radius: float, exclude_id: str) -> list[tuple[float, float]]:
        """Every point where some other entity crosses the full circle at
        `center`/`radius` - shared by [trim_or_extend_arc] (which further
        filters by angular sweep distance from its own fixed endpoint) and
        [trim_circle] (which brackets them around the click angle
        instead). Mirrors [_line_candidates_against]'s exact same
        per-entity-type dispatch, just from the circle's own perspective:
        a Line target is clipped to its own real segment (`line_vs_circle`
        doesn't clip on the line side by itself); a Circle/Arc target needs
        no clipping beyond what [circle_vs_circle]/[circle_vs_arc]
        themselves already apply.
        """
        points: list[tuple[float, float]] = []
        for entity in self.entities.values():
            if entity.id == exclude_id:
                continue
            if isinstance(entity, Line):
                other_start = self.points[entity.start_point_id]
                other_end = self.points[entity.end_point_id]
                for t, point in line_vs_circle(
                    (other_start.x, other_start.y), (other_end.x, other_end.y), center, radius
                ):
                    if -1e-9 <= t <= 1 + 1e-9:
                        points.append(point)
            elif isinstance(entity, Circle):
                other_center = self.points[entity.center_point_id]
                points.extend(
                    circle_vs_circle(center, radius, (other_center.x, other_center.y), entity.radius(self.points))
                )
            elif isinstance(entity, Arc):
                other_center = self.points[entity.center_point_id]
                other_start = self.points[entity.start_point_id]
                other_end = self.points[entity.end_point_id]
                points.extend(
                    circle_vs_arc(
                        center,
                        radius,
                        (other_center.x, other_center.y),
                        entity.radius(self.points),
                        (other_start.x, other_start.y),
                        (other_end.x, other_end.y),
                    )
                )
        return points

    def trim_or_extend_arc(self, arc_id: str, moved_point_id: str) -> tuple["Arc", "Point", bool]:
        """[trim_or_extend_line]'s own algorithm, ported to an Arc's angular
        sweep instead of a Line's linear extent - on-device feedback ("trim/
        extend should work on circles curves and splines"; this is the
        "curves" half, Circle's own conversion lives in [trim_circle]).

        `moved_point_id` identifies which of the Arc's own start/end Points
        is being adjusted, mirroring [trim_or_extend_line]'s identical
        contract exactly; the *other* end (`fixed_point_id`) anchors the
        angle searched from. Since an Arc's own sweep is always
        counter-clockwise from start to end (see the `Arc` class
        docstring), the search direction is CCW from the fixed angle when
        `end_point_id` is being moved (that already matches the arc's own
        growing-sweep direction) and CW when `start_point_id` is being
        moved (searching CCW from the *end* instead would measure the wrong
        way around) - `direction` below picks between them, and
        `_signed_sweep` folds every angle (candidates and the moved point's
        own current position alike) into "how far around, in the search
        direction, from the fixed angle" so both cases compare on the same
        footing, the same way [trim_or_extend_line]'s own `current_t`/`t`
        pair does for a straight line.

        Every other Line/Circle/Arc in the Sketch is checked for a crossing
        against this Arc's own *full* underlying circle (not just its
        current sweep - an extend target may currently lie outside it),
        then filtered/ranked exactly like [trim_or_extend_line]: skip
        anything behind the fixed end or at the current position, skip
        anything farther than `_TRIM_MAX_DISTANCE` (arc length, not a
        straight line, but the same guard), and take whichever remains
        nearest the current position.
        """
        arc = self.entities.get(arc_id)
        if not isinstance(arc, Arc):
            raise KeyError(arc_id)
        if moved_point_id == arc.start_point_id:
            fixed_point_id = arc.end_point_id
            direction = -1.0
        elif moved_point_id == arc.end_point_id:
            fixed_point_id = arc.start_point_id
            direction = 1.0
        else:
            raise ValueError(f"Point {moved_point_id} is not an endpoint of arc {arc_id}")

        center = self.points[arc.center_point_id]
        center_xy = (center.x, center.y)
        radius = arc.radius(self.points)
        if radius < 1e-9:
            raise ValueError(f"Cannot trim/extend a degenerate arc {arc_id}")

        fixed_point = self.points[fixed_point_id]
        moved_point = self.points[moved_point_id]
        fixed_angle = math.atan2(fixed_point.y - center.y, fixed_point.x - center.x)
        two_pi = 2 * math.pi

        def signed_sweep(x: float, y: float) -> float:
            return ((math.atan2(y - center.y, x - center.x) - fixed_angle) * direction) % two_pi

        current_t = signed_sweep(moved_point.x, moved_point.y)

        candidate_points = self._circle_candidates_against(center_xy, radius, exclude_id=arc_id)
        valid = []
        for px, py in candidate_points:
            t = signed_sweep(px, py)
            if t <= 1e-9 or abs(t - current_t) <= 1e-9:
                continue
            if abs(t - current_t) * radius > self._TRIM_MAX_DISTANCE:
                continue
            valid.append((t, (px, py)))
        if not valid:
            raise NoIntersectionFoundError(f"No intersection found to trim/extend arc {arc_id} to")
        _, best_point = min(valid, key=lambda candidate: abs(candidate[0] - current_t))

        # On-device feedback (closed-profile bug fix): see
        # `_existing_point_at`'s own doc comment / `trim_or_extend_line`'s
        # identical comment - same reasoning, ported to an Arc's endpoint.
        if self._point_deletion_blocker(moved_point_id, exclude_entity_id=arc_id) is not None:
            existing = self._existing_point_at(*best_point)
            new_point = self.add_point(*best_point)
            if existing is not None:
                self.add_coincident_constraint(new_point.id, existing.id)
            if moved_point_id == arc.start_point_id:
                arc.start_point_id = new_point.id
            else:
                arc.end_point_id = new_point.id
            return (arc, new_point, True)
        existing = self._existing_point_at(*best_point, exclude_ids=frozenset({moved_point_id}))
        moved_point.x, moved_point.y = best_point
        if existing is not None:
            self.add_coincident_constraint(moved_point_id, existing.id)
        return (arc, moved_point, False)

    def trim_circle(self, circle_id: str, click_x: float, click_y: float) -> "Arc":
        """On-device feedback ("trim/extend should work on circles curves
        and splines"): a Circle has no "end" to move the way
        [trim_or_extend_line]/[trim_or_extend_arc] do - trimming it instead
        means converting it into an Arc that excludes whichever segment was
        clicked, the standard CAD convention for trimming a closed curve.

        Every other Line/Circle/Arc's crossing against this Circle is
        found (see [_circle_candidates_against]) and converted to an angle
        around the centre; at least 2 are required; the two angularly
        nearest the click (bracketing it - one reached by sweeping CCW from
        the click, one by sweeping CW) become the new Arc's own start/end,
        chosen so the Arc's own CCW start->end sweep goes the *other* way
        around, deliberately excluding the click's own neighbourhood -
        exactly the segment "under the cursor" is what gets removed, the
        rest survives as the new Arc.

        Delegates the new Arc's own construction to [add_arc] (reusing the
        Circle's existing centre Point, two freshly-placed boundary Points)
        rather than hand-building its constraint scaffolding - see
        [add_arc]'s own doc comment for exactly what that creates. The
        original Circle (and its own radius/cardinal constraints) is then
        removed via the existing [delete_circle], unmodified.
        """
        circle = self.entities.get(circle_id)
        if not isinstance(circle, Circle):
            raise KeyError(circle_id)
        center = self.points[circle.center_point_id]
        center_xy = (center.x, center.y)
        radius = circle.radius(self.points)
        if radius < 1e-9:
            raise ValueError(f"Cannot trim a degenerate circle {circle_id}")

        candidate_points = self._circle_candidates_against(center_xy, radius, exclude_id=circle_id)
        two_pi = 2 * math.pi
        angles = sorted({math.atan2(py - center.y, px - center.x) % two_pi for px, py in candidate_points})
        if len(angles) < 2:
            raise NoIntersectionFoundError(f"Fewer than 2 crossings found to trim circle {circle_id} at")

        click_angle = math.atan2(click_y - center.y, click_x - center.x) % two_pi
        next_angle = next((a for a in angles if a > click_angle + 1e-9), angles[0])
        prev_angle = next((a for a in reversed(angles) if a < click_angle - 1e-9), angles[-1])

        start_xy = (center.x + radius * math.cos(next_angle), center.y + radius * math.sin(next_angle))
        end_xy = (center.x + radius * math.cos(prev_angle), center.y + radius * math.sin(prev_angle))
        # On-device feedback (closed-profile bug fix): looked up *before*
        # creating the new Points below, so there's nothing for either
        # lookup to accidentally match against itself - see
        # `_existing_point_at`'s own doc comment for why this whole step
        # exists (a Line previously trimmed/extended to meet this Circle
        # left its own Point sitting at this exact spot; without tying the
        # two together, the resulting Arc+Line loop looks closed but isn't,
        # topologically).
        existing_at_start = self._existing_point_at(*start_xy)
        existing_at_end = self._existing_point_at(*end_xy)
        new_start = self.add_point(*start_xy)
        new_end = self.add_point(*end_xy)
        if existing_at_start is not None:
            self.add_coincident_constraint(new_start.id, existing_at_start.id)
        if existing_at_end is not None:
            self.add_coincident_constraint(new_end.id, existing_at_end.id)
        arc = self.add_arc(circle.center_point_id, new_start.id, new_end.id, construction=circle.construction)
        self.delete_circle(circle_id)
        return arc

    def delete_circle(self, circle_id: str) -> None:
        """Remove a Circle and every constraint `add_circle` always creates
        alongside it - the radius DistanceConstraint plus the eight
        cardinal-point constraints (see `Circle.cardinal_constraint_ids`'s
        own doc comment) - all internal implementation details of the
        Circle, not something the user added independently, so they are
        the one exception to "never auto-delete what a deletion didn't
        explicitly target". The center/radius/cardinal Points themselves
        are left untouched, same as `delete_line`."""
        circle = self.entities.get(circle_id)
        if not isinstance(circle, Circle):
            raise KeyError(circle_id)
        del self.entities[circle_id]
        self.constraints.pop(circle.radius_constraint_id, None)
        for constraint_id in circle.cardinal_constraint_ids:
            self.constraints.pop(constraint_id, None)

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
        """Remove an Ellipse and everything `add_ellipse` always creates
        alongside it - both radius DistanceConstraints, both
        AtMidpointConstraints, the PerpendicularConstraint tying its two
        axes together, and both full-diameter axis construction Lines -
        same "internal implementation detail" exception `delete_circle`/
        `delete_arc` already make for their own radius constraint(s). The
        center/major/minor/major-neg/minor-neg Points themselves are left
        untouched, same as `delete_line`/`delete_circle`/`delete_arc`."""
        ellipse = self.entities.get(ellipse_id)
        if not isinstance(ellipse, Ellipse):
            raise KeyError(ellipse_id)
        del self.entities[ellipse_id]
        # `.pop(id, None)` rather than `del`, matching the constraint
        # cleanup below: an axis Line can also be deleted directly (its own
        # `DELETE /lines/{id}` has no notion of "still owned by an
        # Ellipse"), so it may already be gone by the time this runs -
        # that should be a silent no-op here, not a KeyError.
        self.entities.pop(ellipse.major_axis_line_id, None)
        self.entities.pop(ellipse.minor_axis_line_id, None)
        self.constraints.pop(ellipse.major_constraint_id, None)
        self.constraints.pop(ellipse.minor_constraint_id, None)
        self.constraints.pop(ellipse.major_midpoint_constraint_id, None)
        self.constraints.pop(ellipse.minor_midpoint_constraint_id, None)
        self.constraints.pop(ellipse.perpendicular_constraint_id, None)

    def delete_polygon(self, polygon_id: str) -> None:
        """Remove a Polygon and everything `add_polygon` always creates
        alongside it - all `sides` edge Lines and every constraint in its
        radius/equal-radius/equal-length/angle chain - same "internal
        implementation detail" exception `delete_circle`/`delete_arc`/
        `delete_ellipse` already make for their own radius constraint(s).
        The center and every vertex Point (including the `sides - 1` this
        Polygon itself created fresh) are left untouched, same as
        `delete_line`/`delete_circle`/`delete_arc`/`delete_ellipse` -
        consistent with this codebase's own "an entity never auto-deletes
        the Points it's built from, even ones only it ever created" rule."""
        polygon = self.entities.get(polygon_id)
        if not isinstance(polygon, Polygon):
            raise KeyError(polygon_id)
        del self.entities[polygon_id]
        # `.pop(id, None)` rather than `del`, matching `delete_ellipse`'s own
        # axis-line cleanup: a Polygon's own Line can also be deleted
        # directly (its own `DELETE /lines/{id}` has no notion of "still
        # owned by a Polygon"), so it may already be gone by the time this
        # runs - that should be a silent no-op here, not a KeyError.
        for line_id in polygon.line_ids:
            self.entities.pop(line_id, None)
        self.constraints.pop(polygon.radius_constraint_id, None)
        for constraint_id in (
            *polygon.equal_radius_constraint_ids,
            *polygon.equal_length_constraint_ids,
            *polygon.angle_constraint_ids,
        ):
            self.constraints.pop(constraint_id, None)

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

    def _existing_point_at(
        self, x: float, y: float, *, exclude_ids: frozenset[str] = frozenset(), epsilon: float = 1e-6
    ) -> "Point | None":
        """The first existing Point within `epsilon` of `(x, y)` whose id
        isn't in `exclude_ids`, or None.

        On-device feedback (a Line trimmed/extended to meet a Circle, then
        that Circle itself trimmed at the very same spot, formed a wedge
        that visually looked closed but never registered as a closed
        profile): `trim_or_extend_line`/`trim_or_extend_arc`/`trim_circle`
        all place a fresh (or moved) Point at a *computed* target position -
        purely geometric, with no awareness of whether some other entity's
        Point already sits there. Two different Point objects at the same
        `(x, y)` are not topologically connected on their own, so
        `detect_profile`'s connectivity walk (`app.sketch.profile`) never
        saw the two as one loop.

        This is the lookup half of the fix - each trim/extend call site
        checks this *before* creating/moving its own Point, then ties the
        result together with `add_coincident_constraint` if found (see each
        call site). Uses a real Constraint rather than merging the Point
        objects themselves, consistent with how this Sketch always
        represents coincidence elsewhere (`add_coincident_constraint`'s own
        doc comment) - and `_coincident_canonical_ids` (`app.sketch.
        profile`) already treats any such pair as one graph node for loop
        detection, so no change was needed there at all.
        """
        for point in self.points.values():
            if point.id in exclude_ids:
                continue
            if math.hypot(point.x - x, point.y - y) <= epsilon:
                return point
        return None

    def _point_deletion_blocker(self, point_id: str, *, exclude_entity_id: str | None = None) -> str | None:
        """A human-readable reason this Point cannot be deleted, or None if
        deletion is safe. A Point is only ever deleted explicitly, never as
        an automatic side effect of deleting something that references it -
        so deletion is blocked outright while anything still depends on it.

        [exclude_entity_id], when given, skips that one entity in the
        traversal - not for deletion itself (nothing else calls this with
        it set), but reused as-is by `trim_or_extend_line` to answer a
        different question with the exact same logic: "is this Point
        referenced by anything *other than* the Line I'm about to repoint"
        (the Line obviously references its own endpoint - that's not
        sharing, it's the entity being modified). Constraint references are
        never excluded, even ones that happen to be about this same Line
        (e.g. its own length dimension) - any constraint reference at all
        means the Point is meaningfully constrained/shared, the same
        conservative default `trim_or_extend_line` needs."""
        if point_id == self._origin_point_id:
            return "Cannot delete the sketch's origin point"
        for entity in self.entities.values():
            if entity.id == exclude_entity_id:
                continue
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
            if isinstance(entity, Ellipse) and point_id in (
                entity.center_point_id,
                entity.major_point_id,
                entity.major_point_neg_id,
                entity.minor_point_id,
                entity.minor_point_neg_id,
            ):
                return f"Point is still referenced by ellipse {entity.id}"
            if isinstance(entity, Polygon) and point_id in (
                entity.center_point_id,
                *entity.vertex_point_ids,
            ):
                return f"Point is still referenced by polygon {entity.id}"
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
        self.external_references.pop(point_id, None)

    def add_distance_constraint(
        self,
        point_a_id: str,
        point_b_id: str,
        distance: float,
        orientation: Literal["linear", "horizontal", "vertical"] = "linear",
        *,
        provisional: bool = False,
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
            provisional=provisional,
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

    def _center_radius_point_ids(
        self, entity_id: str, *, radius_point_id: str | None = None
    ) -> tuple[str, str]:
        """Resolves a Circle or Arc id to its (center, radius-defining rim)
        Point id pair - either rim Point works for TangentConstraint/
        EqualRadiusConstraint's purposes (both are already equidistant from
        center by construction, see Circle's/Arc's own radius
        DistanceConstraint(s)). `radius_point_id` optionally picks which of
        an Arc's two rim Points (start or end) to resolve to - needed when
        more than one independent tie to the same Arc's radius is required
        (e.g. a Slot's second end-cap Arc, whose two rim Points each need
        their own EqualRadiusConstraint back to the first arc, since unlike
        Circle an Arc has no single "the" rim Point)."""
        entity = self.entities.get(entity_id)
        if isinstance(entity, Circle):
            if radius_point_id is not None and radius_point_id != entity.radius_point_id:
                raise ValueError(f"{radius_point_id} is not a rim point of circle {entity_id}")
            return entity.center_point_id, entity.radius_point_id
        if isinstance(entity, Arc):
            if radius_point_id is not None:
                if radius_point_id not in (entity.start_point_id, entity.end_point_id):
                    raise ValueError(f"{radius_point_id} is not a rim point of arc {entity_id}")
                return entity.center_point_id, radius_point_id
            return entity.center_point_id, entity.start_point_id
        raise KeyError(entity_id)

    def add_tangent_constraint(self, circle_or_arc_id: str, line_id: str) -> TangentConstraint:
        center_point_id, radius_point_id = self._center_radius_point_ids(circle_or_arc_id)
        line = self.entities.get(line_id)
        if not isinstance(line, Line):
            raise KeyError(line_id)

        constraint = TangentConstraint(
            id=str(uuid.uuid4()),
            center_point_id=center_point_id,
            radius_point_id=radius_point_id,
            line_id=line_id,
            line_start_id=line.start_point_id,
            line_end_id=line.end_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_equal_radius_constraint(
        self, entity1_id: str, entity2_id: str, *, radius2_point_id: str | None = None
    ) -> EqualRadiusConstraint:
        """Ties entity2's radius to entity1's. `radius2_point_id` optionally
        selects which of entity2's rim Points to tie (see
        _center_radius_point_ids) - call this twice with each of an Arc's
        two rim Points to keep it fully circular when both its own radius
        DistanceConstraints have been replaced by ties to another entity
        (e.g. a Slot's second end-cap Arc)."""
        if entity1_id == entity2_id:
            raise ValueError("A constraint cannot reference the same Circle/Arc twice")
        center1_point_id, radius1_point_id = self._center_radius_point_ids(entity1_id)
        center2_point_id, resolved_radius2_point_id = self._center_radius_point_ids(
            entity2_id, radius_point_id=radius2_point_id
        )

        constraint = EqualRadiusConstraint(
            id=str(uuid.uuid4()),
            center1_point_id=center1_point_id,
            radius1_point_id=radius1_point_id,
            center2_point_id=center2_point_id,
            radius2_point_id=resolved_radius2_point_id,
        )
        self.constraints[constraint.id] = constraint
        return constraint

    def add_equal_radius_constraint_from_points(
        self,
        center1_point_id: str,
        radius1_point_id: str,
        center2_point_id: str,
        radius2_point_id: str,
    ) -> EqualRadiusConstraint:
        """The raw-Point counterpart to `add_equal_radius_constraint`, for
        callers with no Circle/Arc entity to resolve a center/rim pair from -
        e.g. a Polygon (Point/Line/Constraint-only, per the client's own
        Sketch.add_polygon-equivalent) tying each of its vertices to a
        common center at the same radius, one EqualRadiusConstraint per
        extra vertex, the same "single real DistanceConstraint + N-1
        EqualRadiusConstraint ties" shape Arc/Ellipse/Slot already use for
        their own single-editable-radius design."""
        for point_id in (center1_point_id, radius1_point_id, center2_point_id, radius2_point_id):
            if point_id not in self.points:
                raise KeyError(point_id)
        if center1_point_id == radius1_point_id or center2_point_id == radius2_point_id:
            raise ValueError("A radius tie cannot use the same Point for its center and radius")

        constraint = EqualRadiusConstraint(
            id=str(uuid.uuid4()),
            center1_point_id=center1_point_id,
            radius1_point_id=radius1_point_id,
            center2_point_id=center2_point_id,
            radius2_point_id=radius2_point_id,
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
