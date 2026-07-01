import math
from dataclasses import dataclass, field
from enum import Enum

from app.sketch.models import Circle, Sketch


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
    """

    sketch_id: str
    point_ids: list[str]
    line_ids: list[str]
    inner_loops: list["Profile"] = field(default_factory=list)


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
    """
    real_entities = [entity for entity in sketch.entities.values() if not entity.construction]

    connections: list[tuple[str, tuple[str, str]]] = [
        (entity.id, endpoints)
        for entity in real_entities
        if (endpoints := entity.endpoint_point_ids()) is not None
    ]

    line_loops: list[Profile] = []
    if connections:
        adjacency: dict[str, list[tuple[str, str]]] = {}
        for entity_id, (a, b) in connections:
            adjacency.setdefault(a, []).append((entity_id, b))
            adjacency.setdefault(b, []).append((entity_id, a))

        branch_point_ids = sorted(point_id for point_id, edges in adjacency.items() if len(edges) > 2)
        if branch_point_ids:
            return ProfileDetectionResult(
                status=ProfileStatus.BRANCH,
                detail=f"{len(branch_point_ids)} point(s) are used by more than two entities.",
                branch_point_ids=branch_point_ids,
            )

        if any(len(edges) == 1 for edges in adjacency.values()):
            return ProfileDetectionResult(
                status=ProfileStatus.NO_LOOP,
                detail="Entities do not connect into a closed loop (open chain).",
            )

        # Every point now has degree exactly 2, so every connected component
        # is a simple cycle - trace each one out.
        visited: set[str] = set()
        for start_point_id in adjacency:
            if start_point_id in visited:
                continue
            point_ids, line_ids = _trace_loop(start_point_id, adjacency)
            visited.update(point_ids)
            line_loops.append(Profile(sketch_id=sketch.id, point_ids=point_ids, line_ids=line_ids))

    # C1: standalone Circles are now folded in alongside Line-chain loops
    # (previously only considered when there were no Lines at all - see
    # the Circle class docstring's "known, documented gap"), so a
    # Line-chain outer boundary with a Circle hole inside it (the
    # plate-with-a-round-hole case) is detected correctly below.
    circle_loops = [_circle_profile(sketch, circle) for circle in real_entities if isinstance(circle, Circle)]
    loops = line_loops + circle_loops

    if not loops:
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


def _loop_centroid(sketch: Sketch, profile: Profile) -> tuple[float, float]:
    if _is_circle_profile(sketch, profile):
        center = sketch.points[sketch.entities[profile.line_ids[0]].center_point_id]
        return (center.x, center.y)
    xs = [sketch.points[point_id].x for point_id in profile.point_ids]
    ys = [sketch.points[point_id].y for point_id in profile.point_ids]
    return (sum(xs) / len(xs), sum(ys) / len(ys))


def _loop_area(sketch: Sketch, profile: Profile) -> float:
    """Unsigned area of `profile`'s boundary - used only to break the
    mutual-centroid-containment tie a centred hole otherwise creates (see
    `_classify_nesting`), so only relative magnitude matters, not sign."""
    if _is_circle_profile(sketch, profile):
        radius = sketch.entities[profile.line_ids[0]].radius(sketch.points)
        return math.pi * radius * radius

    vertices = [(sketch.points[point_id].x, sketch.points[point_id].y) for point_id in profile.point_ids]
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

    x, y = point
    vertices = [(sketch.points[point_id].x, sketch.points[point_id].y) for point_id in profile.point_ids]
    inside = False
    for (x1, y1), (x2, y2) in zip(vertices, vertices[1:] + vertices[:1]):
        if (y1 > y) != (y2 > y):
            x_intersect = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < x_intersect:
                inside = not inside
    return inside


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
