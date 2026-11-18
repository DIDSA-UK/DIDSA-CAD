"""Plain geometry for the dimension types of bug report 2026-11-18 part D (arc length, angle to horizontal, three-point angle, minimum /
maximum and tangent distances to circles). One place for "what is this dimension's value on these points", used by the solver's residual
check and side check, the reference (driven) dimensions and the value-update reseeds. Points are `(x, y)` tuples; nothing here imports the
solver or the Sketch model."""

from __future__ import annotations

import math

XY = tuple[float, float]


def ccw_sweep(center: XY, start: XY, end: XY) -> float:
    """The counter-clockwise angle (radians) from `start` to `end` about `center`, in (0, 2*pi]: the sweep of a sketch Arc, which always runs
    counter-clockwise from its start to its end (see `Arc`). Coincident start and end read as a full turn."""
    a0 = math.atan2(start[1] - center[1], start[0] - center[0])
    a1 = math.atan2(end[1] - center[1], end[0] - center[0])
    sweep = (a1 - a0) % (2.0 * math.pi)
    return sweep if sweep > 1e-12 else 2.0 * math.pi


def arc_length(center: XY, start: XY, end: XY) -> float:
    """Length of the counter-clockwise arc from `start` to `end` about `center`, with the radius taken at `start`."""
    return math.dist(center, start) * ccw_sweep(center, start, end)


def rotate_about(center: XY, point: XY, radians: float) -> XY:
    c, s = math.cos(radians), math.sin(radians)
    dx, dy = point[0] - center[0], point[1] - center[1]
    return (center[0] + c * dx - s * dy, center[1] + s * dx + c * dy)


def angle_between_degrees(u: XY, v: XY) -> float | None:
    """Unsigned angle (0-180) between two directions; None when either has no length."""
    nu, nv = math.hypot(*u), math.hypot(*v)
    if nu < 1e-12 or nv < 1e-12:
        return None
    cosine = max(-1.0, min(1.0, (u[0] * v[0] + u[1] * v[1]) / (nu * nv)))
    return math.degrees(math.acos(cosine))


def horizontal_angle_rays(start: XY, end: XY, quadrant: int | None) -> tuple[XY, XY, XY]:
    """The vertex and the two rays of an angle-to-horizontal dimension (`HorizontalAngleConstraint.quadrant`): bit 0 clear, the vertex is
    the line's start and its ray runs to the end; set, the vertex is the end and the ray runs to the start. Bit 1 clear, the horizontal
    ray is +x; set, -x. Returns (vertex, line ray, horizontal ray). No quadrant reads as 0."""
    q = quadrant or 0
    if q & 1:
        vertex, ray = end, (start[0] - end[0], start[1] - end[1])
    else:
        vertex, ray = start, (end[0] - start[0], end[1] - start[1])
    return vertex, ray, (-1.0 if q & 2 else 1.0, 0.0)


def point_circle_distance(point: XY, center: XY, rim: XY, side: str) -> float | None:
    """The distance from `point` to the circle about `center` through `rim`: "min" the nearest (|d - r|), "max" the farthest (d + r).
    None with the point on the centre (no direction to measure along)."""
    d = math.dist(point, center)
    if d < 1e-12:
        return None
    r = math.dist(center, rim)
    return abs(d - r) if side == "min" else d + r


def circle_circle_distance(center1: XY, rim1: XY, center2: XY, rim2: XY, side: str) -> float | None:
    """Between two circles along their centre line: "min" the gap between them (d - r1 - r2, negative where they overlap), "max" the
    farthest points apart (d + r1 + r2). None for concentric circles (no centre line)."""
    d = math.dist(center1, center2)
    if d < 1e-12:
        return None
    r1, r2 = math.dist(center1, rim1), math.dist(center2, rim2)
    return d - r1 - r2 if side == "min" else d + r1 + r2


def line_circle_distance(line_start: XY, line_end: XY, center: XY, rim: XY, side: str) -> float | None:
    """From a Line (its infinite extension) to a circle, square to the line: "min" the tangent side (centre distance minus radius,
    negative where the line cuts the circle), "max" the far side (centre distance plus radius). None for a Line with no length."""
    dx, dy = line_end[0] - line_start[0], line_end[1] - line_start[1]
    length = math.hypot(dx, dy)
    if length < 1e-12:
        return None
    d = abs((center[0] - line_start[0]) * dy - (center[1] - line_start[1]) * dx) / length
    r = math.dist(center, rim)
    return d - r if side == "min" else d + r
