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

