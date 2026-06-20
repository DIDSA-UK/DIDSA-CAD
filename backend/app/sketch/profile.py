from dataclasses import dataclass, field
from enum import Enum

from app.sketch.models import Circle, Sketch


class ProfileStatus(str, Enum):
    """Outcome of closed-loop detection over a Sketch's entities.

    NO_LOOP covers both "no connectable entities at all" and "an open
    chain" - in both cases there is nothing closed to report. BRANCH and
    MULTIPLE_LOOPS are reported distinctly because they need different
    fixes from the sketch's author (remove a T-junction vs. pick one loop).
    """

    CLOSED_LOOP = "closed_loop"
    NO_LOOP = "no_loop"
    BRANCH = "branch"
    MULTIPLE_LOOPS = "multiple_loops"


@dataclass
class Profile:
    """An ordered closed loop of Points/entities, ready for a later Extrude
    module to consume. point_ids[i] connects to point_ids[i + 1] via
    line_ids[i], wrapping around (point_ids[-1] connects to point_ids[0]
    via line_ids[-1])."""

    sketch_id: str
    point_ids: list[str]
    line_ids: list[str]


@dataclass
class ProfileDetectionResult:
    status: ProfileStatus
    detail: str
    profile: Profile | None = None
    branch_point_ids: list[str] = field(default_factory=list)
    loops: list[Profile] = field(default_factory=list)


def detect_profile(sketch: Sketch) -> ProfileDetectionResult:
    """Detect whether a Sketch's entities form exactly one closed loop.

    Operates only through SketchEntity.endpoint_point_ids(), so it knows
    nothing about how the entities were created (per the project brief's
    Profile module description) - any future entity type that connects two
    Points (e.g. Arc) participates automatically.
    """
    connections: list[tuple[str, tuple[str, str]]] = [
        (entity.id, endpoints)
        for entity in sketch.entities.values()
        if (endpoints := entity.endpoint_point_ids()) is not None
    ]
    if not connections:
        # No Lines (or other chain-connecting entities) at all - check for
        # standalone Circles instead. Each Circle is its own valid closed
        # profile (a Circle's two points are never "open" the way a Line
        # chain can be), so this is a separate check rather than folding
        # Circles into the line-chain adjacency graph above. Scoped to the
        # no-Lines case only, by design: a Sketch mixing Lines and Circles
        # does not yet get its Circles included in profile detection - a
        # known, documented gap rather than an attempt to generalize ahead
        # of need.
        circles = sketch.circles()
        if len(circles) == 1:
            return ProfileDetectionResult(
                status=ProfileStatus.CLOSED_LOOP,
                detail="Standalone circle detected as its own closed profile.",
                profile=_circle_profile(sketch, circles[0]),
            )
        if len(circles) > 1:
            return ProfileDetectionResult(
                status=ProfileStatus.MULTIPLE_LOOPS,
                detail=f"{len(circles)} standalone circles, each its own closed profile.",
                loops=[_circle_profile(sketch, circle) for circle in circles],
            )
        return ProfileDetectionResult(
            status=ProfileStatus.NO_LOOP,
            detail="Sketch has no connectable entities (e.g. lines or circles).",
        )

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

    # Every point now has degree exactly 2, so every connected component is
    # a simple cycle - trace each one out.
    visited: set[str] = set()
    loops: list[Profile] = []
    for start_point_id in adjacency:
        if start_point_id in visited:
            continue
        point_ids, line_ids = _trace_loop(start_point_id, adjacency)
        visited.update(point_ids)
        loops.append(Profile(sketch_id=sketch.id, point_ids=point_ids, line_ids=line_ids))

    if len(loops) == 1:
        return ProfileDetectionResult(
            status=ProfileStatus.CLOSED_LOOP,
            detail="Single closed loop detected.",
            profile=loops[0],
        )

    return ProfileDetectionResult(
        status=ProfileStatus.MULTIPLE_LOOPS,
        detail=f"{len(loops)} disjoint closed loops found in this sketch.",
        loops=loops,
    )


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
