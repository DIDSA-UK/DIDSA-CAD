"""Sketcher-roadmap Phase 11: line-line/line-circle/line-arc intersection
geometry for the trim/extend tool - see `Sketch.trim_or_extend_line`, the
only caller.

Nothing here existed anywhere in this codebase before Phase 11: the only
prior intersection-related code is `profile.py`'s `_segments_intersect`, a
*boolean* orientation test used for closed-loop overlap validation, not a
coordinate solve. Deliberately plain `(x, y)` tuples throughout, not
`Point`/`Sketch` - this module is pure geometry, decoupled from the domain
model the same way `_segments_intersect` already is.

Splines and Ellipses are out of scope for v1 (no closed-form line
intersection without curve-specific root-finding) - only Line/Circle/Arc
are supported as intersection targets, and only a Line can be the entity
actually trimmed/extended (see `Sketch.trim_or_extend_line`'s own doc
comment for why trimming an Arc/Circle itself is a materially bigger
problem, deferred rather than half-built here).
"""

import math

Point2D = tuple[float, float]


def line_vs_segment(a1: Point2D, a2: Point2D, seg_start: Point2D, seg_end: Point2D) -> tuple[float, Point2D] | None:
    """Where the *infinite* line through (a1, a2) crosses the *finite*
    segment (seg_start, seg_end), or None if they're parallel (or too
    close to it to be numerically meaningful) or the crossing falls outside
    the segment's own span. Returns `(t, point)` where `t` is the parameter
    along (a1, a2) itself - `a1 + t * (a2 - a1)` - deliberately
    unconstrained (can be < 0 or > 1 either side of a1/a2); the caller
    decides which range of `t` counts as a valid trim/extend target for
    *its* own line, since that depends on which end is being moved. The
    target segment, by contrast, is always clipped to its own actual
    drawn extent - trim/extend targets real geometry as drawn, not an
    unrelated Line's own infinite extension.

    The parametric derivation (solving `a1 + t*A = seg_start + u*B` for the
    2x2 system in `t`/`u` via Cramer's rule, `A`/`B` the two segments' own
    direction vectors) was cross-checked directly against
    `sketch_canvas.dart`'s existing private `_lineIntersectionScreen` (same
    algebra, screen-pixel space there, sketch space here, and that one
    doesn't clip against either segment - used only for the angle-ghost
    arc, where clipping doesn't matter).
    """
    ax1, ay1 = a1
    ax2, ay2 = a2
    bx1, by1 = seg_start
    bx2, by2 = seg_end
    dir_a = (ax2 - ax1, ay2 - ay1)
    dir_b = (bx2 - bx1, by2 - by1)
    to_b = (bx1 - ax1, by1 - ay1)
    denominator = dir_b[0] * dir_a[1] - dir_a[0] * dir_b[1]
    if abs(denominator) < 1e-9:
        return None
    t = (dir_b[0] * to_b[1] - to_b[0] * dir_b[1]) / denominator
    u = (dir_a[0] * to_b[1] - to_b[0] * dir_a[1]) / denominator
    tolerance = 1e-9
    if u < -tolerance or u > 1 + tolerance:
        return None
    point = (ax1 + t * dir_a[0], ay1 + t * dir_a[1])
    return (t, point)


def line_vs_circle(a1: Point2D, a2: Point2D, center: Point2D, radius: float) -> list[tuple[float, Point2D]]:
    """Every point (0, 1, or 2, tangent counting as a repeated 1) where the
    infinite line through (a1, a2) crosses the circle at `center`/`radius` -
    the standard line-circle quadratic, substituting the line's own
    parametric form into the circle's implicit equation. Unlike
    [line_vs_segment], a circle has no "ends" to clip against - the whole
    circle is always the target, so every real root is a valid candidate.
    """
    ax1, ay1 = a1
    ax2, ay2 = a2
    cx, cy = center
    dx, dy = ax2 - ax1, ay2 - ay1
    a = dx * dx + dy * dy
    if a < 1e-12:
        return []
    fx, fy = ax1 - cx, ay1 - cy
    b = 2 * (fx * dx + fy * dy)
    c = fx * fx + fy * fy - radius * radius
    discriminant = b * b - 4 * a * c
    if discriminant < 0:
        return []
    sqrt_discriminant = math.sqrt(discriminant)
    results = []
    for t in ((-b - sqrt_discriminant) / (2 * a), (-b + sqrt_discriminant) / (2 * a)):
        results.append((t, (ax1 + t * dx, ay1 + t * dy)))
    return results


def line_vs_arc(
    a1: Point2D,
    a2: Point2D,
    center: Point2D,
    radius: float,
    arc_start: Point2D,
    arc_end: Point2D,
) -> list[tuple[float, Point2D]]:
    """[line_vs_circle], filtered to the arc's own swept portion of that
    circle - `arc_start`/`arc_end` are real Point coordinates (not
    pre-computed angles - this stays a pure coordinate API, matching
    [line_vs_segment]/[line_vs_circle]), converted to angles here the same
    way `Arc`'s own docstring already defines the sweep: always the
    counter-clockwise arc from `arc_start` to `arc_end` around `center`.
    """
    candidates = line_vs_circle(a1, a2, center, radius)
    if not candidates:
        return []
    cx, cy = center
    start_angle = math.atan2(arc_start[1] - cy, arc_start[0] - cx)
    end_angle = math.atan2(arc_end[1] - cy, arc_end[0] - cx)
    return [
        (t, point)
        for t, point in candidates
        if _angle_in_ccw_sweep(math.atan2(point[1] - cy, point[0] - cx), start_angle, end_angle)
    ]


def _angle_in_ccw_sweep(angle: float, start_angle: float, end_angle: float) -> bool:
    """Whether `angle` lies on the counter-clockwise sweep from
    `start_angle` to `end_angle` - normalizes all three into `[0, 2*pi)`
    and checks containment on a circular interval, wrapping through 0 when
    `start_angle > end_angle` (the sweep crosses the +x axis)."""
    two_pi = 2 * math.pi
    tolerance = 1e-9
    normalized_angle = angle % two_pi
    normalized_start = start_angle % two_pi
    normalized_end = end_angle % two_pi
    if normalized_start <= normalized_end:
        return normalized_start - tolerance <= normalized_angle <= normalized_end + tolerance
    return normalized_angle >= normalized_start - tolerance or normalized_angle <= normalized_end + tolerance
