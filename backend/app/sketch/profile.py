import math
from dataclasses import dataclass, field
from enum import Enum

from app.sketch.constraints import CoincidentConstraint
from app.sketch.models import Circle, Ellipse, Sketch, TextEntity
from app.sketch.text_geometry import place_local_point, text_to_polygons


class ProfileStatus(str, Enum):
    """Outcome of closed-loop detection over a Sketch's entities.

    NO_LOOP covers both "no connectable entities at all" and "an open
    chain" - in both cases there is nothing closed to report. BRANCH,
    MULTIPLE_LOOPS, and INVALID_NESTING are reported distinctly because
    they need different fixes from the sketch's author (remove a
    T-junction, pick one loop, or un-nest a hole-inside-a-hole).

    MULTIPLE_LOOPS (C2's "MultiProfile") means 2+ disjoint outer profiles -
    each may itself carry inner holes (C1), surfaced via
    `ProfileDetectionResult.loops`. See `_classify_nesting`.
    """

    CLOSED_LOOP = "closed_loop"
    NO_LOOP = "no_loop"
    BRANCH = "branch"
    MULTIPLE_LOOPS = "multiple_loops"
    # C1: two or more loops each claim to contain another loop's centroid
    # (a hole nested inside another hole) - deferred per the prompt's scope,
    # so this is reported as a distinct, descriptive error rather than
    # silently picking one nesting interpretation.
    INVALID_NESTING = "invalid_nesting"
    # C1: a loop's centroid lies inside a larger loop (so it looks like a
    # candidate hole), but part of its own boundary pokes outside that
    # loop, or touches/crosses it - not a valid hole. Reported distinctly
    # from INVALID_NESTING since the fix is different (redraw the loop
    # fully inside its container, not remove a level of nesting).
    OVERLAPPING_LOOPS = "overlapping_loops"


@dataclass
class Profile:
    """An ordered closed loop of Points/entities, ready for a later Extrude
    module to consume. point_ids[i] connects to point_ids[i + 1] via
    line_ids[i], wrapping around (point_ids[-1] connects to point_ids[0]
    via line_ids[-1]).

    C1: `inner_loops` holds this profile's holes - other closed loops fully
    nested inside this one (e.g. a circular hole in a rectangular plate).
    Empty for a simple profile with no holes. Only ever one level deep -
    an inner loop never itself carries inner_loops (see INVALID_NESTING).

    `text_vertices`/`text_contour_index`/`text_hole_index` are only ever
    set for a Text contour (see `_text_profile`) - a Text entity has no
    real Points to read polygon vertices from via `point_ids` the way
    every other entity here does (see `app.sketch.models.TextEntity`'s
    own docstring: glyph geometry is never decomposed into Points), so
    `text_vertices` carries this loop's own tessellated `(x, y)` polygon
    directly instead, and `text_contour_index`/`text_hole_index`
    identify exactly which glyph/wire `app.document.extrude.
    wire_for_profile` should re-derive the *exact* (non-tessellated)
    curve for. `text_hole_index` is None for a contour's own outer loop,
    or the index into that contour's own holes for one of its
    `inner_loops`.
    """

    sketch_id: str
    point_ids: list[str]
    line_ids: list[str]
    inner_loops: list["Profile"] = field(default_factory=list)
    text_vertices: list[tuple[float, float]] | None = None
    text_contour_index: int | None = None
    text_hole_index: int | None = None


@dataclass
class ProfileDetectionResult:
    status: ProfileStatus
    detail: str
    profile: Profile | None = None
    branch_point_ids: list[str] = field(default_factory=list)
    loops: list[Profile] = field(default_factory=list)


def detect_profile(sketch: Sketch) -> ProfileDetectionResult:
    """Detect the closed loop(s) formed by a Sketch's entities, classifying
    multiple loops as nested (C1: outer profile + hole(s)) or disjoint
    (C2: separate outer profiles, a "MultiProfile") via `_classify_nesting`.

    Operates only through SketchEntity.endpoint_point_ids(), so it knows
    nothing about how Line-chain entities were created (per the project
    brief's Profile module description) - any future entity type that
    connects two Points (e.g. Arc) participates automatically. Circles are
    handled separately (see below) since a Circle has no endpoints to walk.

    Construction entities are filtered out here, at the entry point, before
    any of the graph-walking logic below ever sees them - a construction
    Line or Circle that would otherwise close a loop is invisible to
    profile detection, full stop, rather than being a special case threaded
    through the adjacency/branch/loop-tracing/nesting logic.

    Prompt G: classifies each *connected component* of the entity graph
    independently, rather than requiring the whole sketch to be one clean
    degree-2-everywhere structure - a stray open chain or a branch/
    T-junction sitting elsewhere in the sketch no longer fails detection
    for closed loops that exist independently of it (previously, *any*
    degree-1 or degree-3+ point anywhere in the sketch reported BRANCH/
    NO_LOOP for the entire sketch, even past a genuinely closed, usable
    loop). A connected component is a usable closed loop exactly when every
    point in it has degree exactly 2 (a connected 2-regular graph is always
    a single simple cycle) - any other component (containing a degree-1
    "open end" point, a degree-3+ branch point, or both) is simply not a
    candidate profile and is excluded, not reported as an error, as long as
    *some* other component (or Circle) yields a usable loop. `BRANCH` is
    still reported (with `branch_point_ids`, for a more specific message
    than the generic `NO_LOOP`) when a branch point exists *and* no usable
    closed loop exists anywhere in the sketch - see the bottom of this
    function - matching this module's existing "branch takes priority over
    open-chain" message-detail precedent for the fully-unusable case, the
    only case previously distinguishable.
    """
    real_entities = [entity for entity in sketch.entities.values() if not entity.construction]

    # Two Points linked by a CoincidentConstraint (e.g. a corner "closed" by
    # dragging one Point onto another, per _autoCoincideIfNear on the
    # client) are still two distinct Point ids in the model - only pinned
    # to the same position by the solver, never merged into one shared
    # reference. Left alone, that means the adjacency graph below sees two
    # unconnected nodes at that corner and reports the loop as open, even
    # though it visibly looks closed. Canonicalizing each Point id through
    # this union-find before building adjacency treats Coincident Points as
    # the same graph node for connectivity purposes - closing the loop
    # exactly like a real shared Point would, with no change to the
    # Point/Line/Circle data model itself (still fully reversible by
    # deleting the CoincidentConstraint).
    canonical_point_id = _coincident_canonical_ids(sketch)

    connections: list[tuple[str, tuple[str, str]]] = []
    for entity in real_entities:
        endpoints = entity.endpoint_point_ids()
        if endpoints is None:
            continue
        a, b = endpoints
        connections.append((entity.id, (canonical_point_id.get(a, a), canonical_point_id.get(b, b))))

    line_loops: list[Profile] = []
    any_branch_point = False
    if connections:
        adjacency: dict[str, list[tuple[str, str]]] = {}
        for entity_id, (a, b) in connections:
            adjacency.setdefault(a, []).append((entity_id, b))
            adjacency.setdefault(b, []).append((entity_id, a))

        any_branch_point = any(len(edges) > 2 for edges in adjacency.values())

        visited: set[str] = set()
        for start_point_id in adjacency:
            if start_point_id in visited:
                continue
            component = _connected_component(start_point_id, adjacency)
            visited.update(component)
            if all(len(adjacency[point_id]) == 2 for point_id in component):
                point_ids, line_ids = _trace_loop(start_point_id, adjacency)
                line_loops.append(Profile(sketch_id=sketch.id, point_ids=point_ids, line_ids=line_ids))
            # else: this component has an open end and/or a branch point -
            # not a candidate profile, simply excluded (not an error) as
            # long as some other component/Circle yields a usable loop.

    # C1: standalone Circles are now folded in alongside Line-chain loops
    # (previously only considered when there were no Lines at all - see
    # the Circle class docstring's "known, documented gap"), so a
    # Line-chain outer boundary with a Circle hole inside it (the
    # plate-with-a-round-hole case) is detected correctly below.
    circle_loops = [_circle_profile(sketch, circle) for circle in real_entities if isinstance(circle, Circle)]
    # C1: Ellipses are folded in the same way as Circles - a standalone
    # closed loop with no endpoints to walk (see Ellipse.endpoint_point_ids,
    # inherited unset from SketchEntity, same as Circle's).
    ellipse_loops = [
        _ellipse_profile(sketch, ellipse) for ellipse in real_entities if isinstance(ellipse, Ellipse)
    ]
    # Text is folded in the same way as Circle/Ellipse, except a single
    # Text entity can contribute several standalone loops at once (one
    # per glyph contour, each already carrying its own holes - see
    # _text_profile) rather than exactly one.
    text_loops = [
        loop
        for text in real_entities
        if isinstance(text, TextEntity)
        for loop in _text_profile(sketch, text)
    ]
    loops = line_loops + circle_loops + ellipse_loops + text_loops

    if not loops:
        if any_branch_point:
            branch_point_ids = sorted(
                point_id for point_id, edges in adjacency.items() if len(edges) > 2
            )
            return ProfileDetectionResult(
                status=ProfileStatus.BRANCH,
                detail=f"{len(branch_point_ids)} point(s) are used by more than two entities.",
                branch_point_ids=branch_point_ids,
            )
        return ProfileDetectionResult(
            status=ProfileStatus.NO_LOOP,
            detail="Sketch has no connectable entities (e.g. lines or circles).",
        )

    if len(loops) == 1:
        return ProfileDetectionResult(
            status=ProfileStatus.CLOSED_LOOP,
            detail="Single closed loop detected.",
            profile=loops[0],
        )

    return _classify_nesting(sketch, loops)


def _coincident_canonical_ids(sketch: Sketch) -> dict[str, str]:
    """Maps every Point id that's a party to a CoincidentConstraint to a
    single canonical id shared with every other Point it's (transitively)
    Coincident with - standard union-find, path-compressed on lookup. A
    Point with no CoincidentConstraint at all is simply absent from the
    returned mapping (callers fall back to the Point's own id via `.get`).
    """
    parent: dict[str, str] = {}

    def find(point_id: str) -> str:
        parent.setdefault(point_id, point_id)
        root = point_id
        while parent[root] != root:
            root = parent[root]
        while parent[point_id] != root:
            parent[point_id], point_id = root, parent[point_id]
        return root

    for constraint in sketch.constraints.values():
        if isinstance(constraint, CoincidentConstraint):
            a, b = find(constraint.point_a_id), find(constraint.point_b_id)
            if a != b:
                parent[a] = b

    return {point_id: find(point_id) for point_id in parent}


def _connected_component(start_point_id: str, adjacency: dict[str, list[tuple[str, str]]]) -> set[str]:
    """Every point id reachable from `start_point_id` via any entity in
    `adjacency` - a plain point-to-point BFS, ignoring which entity connects
    them (entity identity doesn't matter for component membership, only for
    tracing the loop itself afterward - see `_trace_loop`)."""
    visited = {start_point_id}
    frontier = [start_point_id]
    while frontier:
        current = frontier.pop()
        for _entity_id, neighbor in adjacency[current]:
            if neighbor not in visited:
                visited.add(neighbor)
                frontier.append(neighbor)
    return visited


def _classify_nesting(sketch: Sketch, loops: list[Profile]) -> ProfileDetectionResult:
    """C1/C2: split 2+ closed loops into outer profile(s) and, for each,
    the holes nested inside it, using the point-in-polygon test below.

    A loop is a hole of exactly the one other loop whose boundary contains
    its centroid *and* whose area is larger; a loop contained by *no*
    other (larger) loop is itself an outer profile. The area tie-break
    matters for the common case of a hole centred on its container: the
    container's own centroid then also lies inside the (small) hole, so a
    centroid-only test would see each contain the other - comparing area
    resolves this the way anyone would expect (the bigger loop is always
    the container, never the other way round).

    A single outer loop (with 0+ holes) is C1's nested-profile case
    (status CLOSED_LOOP); 2+ outer loops is C2's disjoint-profiles case
    (status MULTIPLE_LOOPS, one MultiProfile sub-profile per outer loop,
    each already carrying its own holes) - both land in the same
    ProfileDetectionResult shape, differing only in whether `profile` or
    `loops` is populated, so callers (extrude.py) branch on `status` alone.

    A loop contained by 2+ others (a hole nested inside another hole) is
    rejected outright as ProfileStatus.INVALID_NESTING - deferred per the
    prompt's explicit scope, and not distinguishable here from genuinely
    self-intersecting/overlapping geometry, so it is treated the same way.

    A loop whose *centroid* lies inside a single larger loop is only a
    valid hole if its *entire* boundary does too (checked by
    `_loop_fully_contains`, below) - centroid-only containment is not
    enough. Without this, a loop that merely overlaps its container (e.g.
    its far edge pokes outside, or an edge exactly touches the container's
    boundary) would still be classified as a hole by the centroid test
    above and handed to `extrude.py` as-is, which builds an OCCT face by
    adding it as a literal inner wire - a wire that is not strictly
    interior to the outer one there produces an invalid/partial face
    (some triangles tessellate, some don't) instead of a clean rejection.
    This was caught by real on-device testing, not anticipated up front.
    """
    centroids = [_loop_centroid(sketch, loop) for loop in loops]
    areas = [_loop_area(sketch, loop) for loop in loops]
    containing_indices = [
        [
            j
            for j, container in enumerate(loops)
            if j != i and areas[j] > areas[i] and _loop_contains_point(sketch, container, centroid)
        ]
        for i, centroid in enumerate(centroids)
    ]

    if any(len(containers) >= 2 for containers in containing_indices):
        return ProfileDetectionResult(
            status=ProfileStatus.INVALID_NESTING,
            detail="A hole nested inside another hole is not supported.",
        )

    for loop, containers in zip(loops, containing_indices):
        if containers and not _loop_fully_contains(sketch, loops[containers[0]], loop):
            return ProfileDetectionResult(
                status=ProfileStatus.OVERLAPPING_LOOPS,
                detail="An inner loop's boundary is not fully contained within its outer loop.",
            )

    outer_loops = [loop for loop, containers in zip(loops, containing_indices) if not containers]
    if not outer_loops:
        return ProfileDetectionResult(
            status=ProfileStatus.INVALID_NESTING,
            detail="Could not determine an outer profile among overlapping loops.",
        )

    for loop, containers in zip(loops, containing_indices):
        if containers:
            loops[containers[0]].inner_loops.append(loop)

    if len(outer_loops) == 1:
        outer = outer_loops[0]
        detail = (
            "Single closed loop detected."
            if not outer.inner_loops
            else f"Outer profile with {len(outer.inner_loops)} inner hole(s) detected."
        )
        return ProfileDetectionResult(status=ProfileStatus.CLOSED_LOOP, detail=detail, profile=outer)

    return ProfileDetectionResult(
        status=ProfileStatus.MULTIPLE_LOOPS,
        detail=f"{len(outer_loops)} disjoint outer profiles found in this sketch.",
        loops=outer_loops,
    )


def _is_text_profile(profile: Profile) -> bool:
    return profile.text_vertices is not None


def _profile_vertices(sketch: Sketch, profile: Profile) -> list[tuple[float, float]]:
    """`profile`'s own polygon vertices, from `text_vertices` for a Text
    contour (see `Profile`'s own docstring - it has no real Points to read
    from) or from `sketch.points[point_id]` for every other polygon-
    shaped profile. Only ever called for a profile that isn't itself a
    standalone Circle/Ellipse (those are handled by their own dedicated
    branches wherever this would otherwise be called) - a Text contour is
    never a Circle/Ellipse, so it always resolves here."""
    if _is_text_profile(profile):
        return profile.text_vertices
    return [(sketch.points[point_id].x, sketch.points[point_id].y) for point_id in profile.point_ids]


def _loop_centroid(sketch: Sketch, profile: Profile) -> tuple[float, float]:
    if _is_circle_profile(sketch, profile):
        center = sketch.points[sketch.entities[profile.line_ids[0]].center_point_id]
        return (center.x, center.y)
    if _is_ellipse_profile(sketch, profile):
        center = sketch.points[sketch.entities[profile.line_ids[0]].center_point_id]
        return (center.x, center.y)
    vertices = _profile_vertices(sketch, profile)
    xs = [x for x, _y in vertices]
    ys = [y for _x, y in vertices]
    return (sum(xs) / len(xs), sum(ys) / len(ys))


def _loop_area(sketch: Sketch, profile: Profile) -> float:
    """Unsigned area of `profile`'s boundary - used only to break the
    mutual-centroid-containment tie a centred hole otherwise creates (see
    `_classify_nesting`), so only relative magnitude matters, not sign."""
    if _is_circle_profile(sketch, profile):
        radius = sketch.entities[profile.line_ids[0]].radius(sketch.points)
        return math.pi * radius * radius
    if _is_ellipse_profile(sketch, profile):
        ellipse = sketch.entities[profile.line_ids[0]]
        return math.pi * ellipse.major_radius(sketch.points) * ellipse.minor_radius

    vertices = _profile_vertices(sketch, profile)
    signed_area = 0.0
    for (x1, y1), (x2, y2) in zip(vertices, vertices[1:] + vertices[:1]):
        signed_area += x1 * y2 - x2 * y1
    return abs(signed_area) / 2.0


def _loop_contains_point(sketch: Sketch, profile: Profile, point: tuple[float, float]) -> bool:
    """Whether `point` lies inside `profile`'s boundary - a plain
    inside-circle distance check for a standalone Circle profile, or a
    ray-casting point-in-polygon test (even-odd rule) for a Line-chain
    polygon profile. Used only to classify one loop's centroid as nested
    inside another loop for `_classify_nesting` above."""
    if _is_circle_profile(sketch, profile):
        circle = sketch.entities[profile.line_ids[0]]
        center = sketch.points[circle.center_point_id]
        radius = circle.radius(sketch.points)
        return math.hypot(point[0] - center.x, point[1] - center.y) < radius
    if _is_ellipse_profile(sketch, profile):
        ellipse = sketch.entities[profile.line_ids[0]]
        center = sketch.points[ellipse.center_point_id]
        major_radius = ellipse.major_radius(sketch.points)
        rotation = ellipse.rotation(sketch.points)
        dx, dy = point[0] - center.x, point[1] - center.y
        cos_r, sin_r = math.cos(-rotation), math.sin(-rotation)
        local_x = dx * cos_r - dy * sin_r
        local_y = dx * sin_r + dy * cos_r
        return (local_x / major_radius) ** 2 + (local_y / ellipse.minor_radius) ** 2 < 1

    x, y = point
    vertices = _profile_vertices(sketch, profile)
    inside = False
    for (x1, y1), (x2, y2) in zip(vertices, vertices[1:] + vertices[:1]):
        if (y1 > y) != (y2 > y):
            x_intersect = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < x_intersect:
                inside = not inside
    return inside


def _loop_fully_contains(sketch: Sketch, container: Profile, candidate: Profile) -> bool:
    """Whether `candidate`'s entire boundary - not just its centroid - lies
    strictly inside `container`'s boundary, with no shared/touching edges.
    `_classify_nesting` already knows `candidate`'s centroid is inside
    `container` before calling this; this is the follow-up check that
    actually validates the hole is a hole (fully interior), rather than a
    loop that merely overlaps, or exactly touches, its container along
    part of its boundary.

    Vertex-in-polygon containment alone is not enough here: the standard
    even-odd ray-cast test (`_loop_contains_point`) classifies a point
    sitting exactly on a container edge as "inside" for most positions
    along that edge (a well-known convention/limitation of that
    algorithm, not a bug in it) - so a candidate loop that shares a whole
    edge with its container (confirmed by real on-device testing: a hole
    rectangle with one side flush against the outer rectangle's side)
    would pass a vertex-only check yet still isn't a valid, fully-interior
    hole. The segment-intersection check below catches exactly this,
    independently of the vertex check.
    """
    if _is_ellipse_profile(sketch, candidate):
        # No closed-form ellipse/ellipse or ellipse/polygon containment test
        # is implemented here (see `_ellipse_boundary_points`) - sampling
        # the candidate's boundary and reusing `_loop_contains_point`
        # (which already has circle/ellipse/polygon container branches)
        # covers every container kind with one check.
        ellipse = sketch.entities[candidate.line_ids[0]]
        boundary = _ellipse_boundary_points(sketch, ellipse)
        return all(_loop_contains_point(sketch, container, p) for p in boundary)

    if _is_circle_profile(sketch, candidate):
        circle = sketch.entities[candidate.line_ids[0]]
        center_point = sketch.points[circle.center_point_id]
        center = (center_point.x, center_point.y)
        radius = circle.radius(sketch.points)
        if _is_circle_profile(sketch, container):
            container_circle = sketch.entities[container.line_ids[0]]
            container_center = sketch.points[container_circle.center_point_id]
            container_radius = container_circle.radius(sketch.points)
            distance = math.hypot(center[0] - container_center.x, center[1] - container_center.y)
            return distance + radius < container_radius
        if _is_ellipse_profile(sketch, container):
            circle_boundary = [
                (center[0] + radius * math.cos(t), center[1] + radius * math.sin(t))
                for t in (2 * math.pi * i / 64 for i in range(64))
            ]
            return all(_loop_contains_point(sketch, container, p) for p in circle_boundary)
        vertices = _profile_vertices(sketch, container)
        return all(
            _point_to_segment_distance(center, a, b) > radius
            for a, b in zip(vertices, vertices[1:] + vertices[:1])
        )

    candidate_vertices = _profile_vertices(sketch, candidate)
    if not all(_loop_contains_point(sketch, container, vertex) for vertex in candidate_vertices):
        return False

    if _is_circle_profile(sketch, container):
        return True  # A polygon fully inside a circular container has no polygon edges to cross.

    if _is_ellipse_profile(sketch, container):
        return True  # Same convexity argument as the circle-container case above.

    container_vertices = _profile_vertices(sketch, container)
    candidate_edges = list(zip(candidate_vertices, candidate_vertices[1:] + candidate_vertices[:1]))
    container_edges = list(zip(container_vertices, container_vertices[1:] + container_vertices[:1]))
    return not any(
        _segments_intersect(a1, a2, b1, b2) for a1, a2 in candidate_edges for b1, b2 in container_edges
    )


def _point_to_segment_distance(
    point: tuple[float, float], a: tuple[float, float], b: tuple[float, float]
) -> float:
    px, py = point
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _segments_intersect(
    p1: tuple[float, float],
    p2: tuple[float, float],
    p3: tuple[float, float],
    p4: tuple[float, float],
) -> bool:
    """Whether segment p1-p2 intersects or touches (including endpoints or
    an overlapping/collinear stretch) segment p3-p4 - the standard
    orientation-based segment intersection test, extended with an
    on-segment check for the collinear/touching case."""

    def cross(o: tuple[float, float], a: tuple[float, float], b: tuple[float, float]) -> float:
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    def on_segment(p: tuple[float, float], a: tuple[float, float], b: tuple[float, float]) -> bool:
        tolerance = 1e-9
        return (
            min(a[0], b[0]) - tolerance <= p[0] <= max(a[0], b[0]) + tolerance
            and min(a[1], b[1]) - tolerance <= p[1] <= max(a[1], b[1]) + tolerance
        )

    d1 = cross(p3, p4, p1)
    d2 = cross(p3, p4, p2)
    d3 = cross(p1, p2, p3)
    d4 = cross(p1, p2, p4)

    if ((d1 > 0) != (d2 > 0)) and d1 != 0 and d2 != 0 and ((d3 > 0) != (d4 > 0)) and d3 != 0 and d4 != 0:
        return True

    tolerance = 1e-9
    if abs(d1) < tolerance and on_segment(p1, p3, p4):
        return True
    if abs(d2) < tolerance and on_segment(p2, p3, p4):
        return True
    if abs(d3) < tolerance and on_segment(p3, p1, p2):
        return True
    if abs(d4) < tolerance and on_segment(p4, p1, p2):
        return True
    return False


def _is_circle_profile(sketch: Sketch, profile: Profile) -> bool:
    return len(profile.line_ids) == 1 and isinstance(sketch.entities.get(profile.line_ids[0]), Circle)


def _circle_profile(sketch: Sketch, circle: Circle) -> Profile:
    # Profile.line_ids is reused here to hold the Circle's own entity id
    # (a single-entity "loop") rather than a list of Line ids - there's
    # only ever one entity tracing this profile's boundary, unlike a
    # Line-chain loop's multiple Line ids.
    return Profile(
        sketch_id=sketch.id,
        point_ids=[circle.center_point_id, circle.radius_point_id],
        line_ids=[circle.id],
    )


def _is_ellipse_profile(sketch: Sketch, profile: Profile) -> bool:
    return len(profile.line_ids) == 1 and isinstance(sketch.entities.get(profile.line_ids[0]), Ellipse)


def _ellipse_profile(sketch: Sketch, ellipse: Ellipse) -> Profile:
    # Same "line_ids reused to hold the entity's own id" convention as
    # _circle_profile above.
    return Profile(
        sketch_id=sketch.id,
        point_ids=[ellipse.center_point_id, ellipse.major_point_id],
        line_ids=[ellipse.id],
    )


def _text_profile(sketch: Sketch, text: TextEntity) -> list[Profile]:
    """Every one of `text`'s own glyph contours, each already a fully-
    formed outer-loop-with-its-own-holes `Profile` - OCCT's own font-to-
    BRep conversion resolves each glyph's own nesting itself (confirmed
    by direct on-device testing: e.g. "o" -> one Face with 2 wires, an
    outer ring and its own inner counter - see `text_geometry`'s own
    docstring), so nothing here needs to reimplement point-in-polygon
    hole detection for a single Text entity's own glyphs the way
    `_classify_nesting` does for *unrelated* loops. Folded into
    `detect_profile`'s top-level loop list exactly like
    `_circle_profile`/`_ellipse_profile`'s single loop each, just
    potentially many per Text entity instead of exactly one - nesting a
    Text entity's own loops against *other* sketch geometry (e.g. text
    sitting inside a plate) is still handled generically by
    `_classify_nesting` afterward, via every polygon-math function in
    this module's own `_is_text_profile`/`_profile_vertices` branches.
    """
    anchor = sketch.points[text.anchor_point_id]

    def placed(local: tuple[float, float]) -> tuple[float, float]:
        return place_local_point(anchor.x, anchor.y, text.rotation_degrees, local[0], local[1])

    profiles = []
    for contour_index, (outer, holes) in enumerate(text_to_polygons(text.content, text.font, text.size)):
        profile = Profile(
            sketch_id=sketch.id,
            point_ids=[],
            line_ids=[text.id],
            text_vertices=[placed(p) for p in outer],
            text_contour_index=contour_index,
        )
        profile.inner_loops = [
            Profile(
                sketch_id=sketch.id,
                point_ids=[],
                line_ids=[text.id],
                text_vertices=[placed(p) for p in hole],
                text_contour_index=contour_index,
                text_hole_index=hole_index,
            )
            for hole_index, hole in enumerate(holes)
        ]
        profiles.append(profile)
    return profiles


def _ellipse_boundary_points(sketch: Sketch, ellipse: Ellipse, steps: int = 64) -> list[tuple[float, float]]:
    """Samples `steps` points evenly around `ellipse`'s boundary in sketch
    space. Used as a practical stand-in for exact curve math wherever an
    Ellipse needs to be tested against another loop's boundary (nesting/
    containment classification in `_loop_fully_contains`) - a closed-form
    ellipse/segment or ellipse/ellipse containment test is materially more
    involved than the polygon and circle cases this module already
    handles, and sampling at this density is accurate enough for that
    purpose (an accepted v1 approximation, not exact)."""
    center = sketch.points[ellipse.center_point_id]
    major_radius = ellipse.major_radius(sketch.points)
    minor_radius = ellipse.minor_radius
    rotation = ellipse.rotation(sketch.points)
    cos_r, sin_r = math.cos(rotation), math.sin(rotation)
    points = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        local_x = major_radius * math.cos(t)
        local_y = minor_radius * math.sin(t)
        points.append((center.x + local_x * cos_r - local_y * sin_r, center.y + local_x * sin_r + local_y * cos_r))
    return points


def _trace_loop(
    start_point_id: str, adjacency: dict[str, list[tuple[str, str]]]
) -> tuple[list[str], list[str]]:
    point_ids = [start_point_id]
    line_ids: list[str] = []
    came_from_entity: str | None = None
    current = start_point_id

    while True:
        next_entity_id, next_point_id = next(
            edge for edge in adjacency[current] if edge[0] != came_from_entity
        )
        line_ids.append(next_entity_id)
        if next_point_id == start_point_id:
            break
        point_ids.append(next_point_id)
        came_from_entity = next_entity_id
        current = next_point_id

    return point_ids, line_ids
