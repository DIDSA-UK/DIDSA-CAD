"""Pure-Python plane-geometry math for CreatePlaneFeature's NORMAL_TO_LINE_
AT_POINT case (C2) - deliberately has no OCCT/pythonocc-core import anywhere
in this file (only app.sketch.models/store, themselves OCCT-free), so the
point-on-line/off-line validation this prompt's own testing instructions
call out can run for real in this sandbox, unlike almost every other
backend prompt's geometry construction. See app.document.create_plane for
the OFFSET_FACE case, which does need OCCT (a planarity check has no
OCCT-free equivalent).
"""

import math

from fastapi import HTTPException

from app.document.models import ResolvedPlane
from app.sketch.models import Line, Plane, Point, SketchEntityRef
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity


# Deliberately duplicates (does not import) app.document.extrude's own
# sketch_point_to_world - that version returns an OCCT gp_Pnt, and importing
# it would force this whole module to require OCCT at load time, defeating
# the point of keeping NORMAL_TO_LINE_AT_POINT OCCT-free. Both must stay in
# sync with each other and with the client's own sketchPointToWorld
# (client/lib/viewport3d/sketch_geometry_3d.dart) - the same fixed XY/XZ/YZ
# embedding used everywhere else in this project.
def _sketch_point_to_world(plane: Plane, x: float, y: float) -> tuple[float, float, float]:
    return {
        Plane.XY: (x, y, 0.0),
        Plane.XZ: (x, 0.0, y),
        Plane.YZ: (0.0, x, y),
    }[plane]


def _point_not_on_line(line_ref: SketchEntityRef, point_ref: SketchEntityRef) -> HTTPException:
    """C2: the structured `point_not_on_line` validation error - a plain
    HTTPException with a structured `detail` dict, same 422 envelope B1/C1
    already established for `missing_reference`. Raised when `point_ref`'s
    `entity_id` is not literally the resolved Line's own `start_point_id`
    or `end_point_id` - an id comparison, not a distance/tolerance check,
    consistent with this project's no-auto-merge/no-implicit-coincidence
    principle (see this prompt's own scope doc)."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "point_not_on_line",
            "sketch_id": line_ref.sketch_id,
            "line_id": line_ref.entity_id,
            "point_id": point_ref.entity_id,
        },
    )


def resolve_normal_to_line_at_point(
    line_ref: SketchEntityRef, point_ref: SketchEntityRef
) -> ResolvedPlane:
    """C2: resolves a NORMAL_TO_LINE_AT_POINT CreatePlaneFeature - a plane
    normal to `line_ref`'s direction, passing through `point_ref`'s
    position. Fully determined by the two references alone, no numeric
    input (per this prompt's own scope). Resolves both refs via C1's
    `resolve_sketch_entity` (fails closed with `missing_reference` for an
    unknown sketch/entity id, same as every other consumer of that
    resolver), then validates `point_ref` is literally one of the resolved
    Line's own endpoints - fails closed with `point_not_on_line` otherwise
    (see `_point_not_on_line`).

    The line's direction vector maps into world space via
    `_sketch_point_to_world` applied to the (dx, dy) delta directly, not
    just to positions - correct because every fixed reference plane's
    embedding is linear (origin-preserving: (0, 0) always maps to the
    world origin), so mapping a delta gives exactly the same result as
    mapping the two endpoints and subtracting."""
    line = resolve_sketch_entity(line_ref)
    assert isinstance(line, Line)  # entity_type already validated LINE by resolve_sketch_entity
    point = resolve_sketch_entity(point_ref)
    assert isinstance(point, Point)  # entity_type already validated POINT by resolve_sketch_entity

    if point_ref.entity_id not in (line.start_point_id, line.end_point_id):
        raise _point_not_on_line(line_ref, point_ref)

    sketch = get_sketch_or_404(line_ref.sketch_id)
    start = sketch.points[line.start_point_id]
    end = sketch.points[line.end_point_id]

    dx, dy = end.x - start.x, end.y - start.y
    direction = _sketch_point_to_world(sketch.plane, dx, dy)
    length = math.sqrt(sum(c * c for c in direction))
    normal = tuple(c / length for c in direction)

    origin = _sketch_point_to_world(sketch.plane, point.x, point.y)
    return ResolvedPlane(origin=origin, normal=normal)
