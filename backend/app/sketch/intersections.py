"""Sketcher-roadmap Phase 11 (+ on-device feedback follow-up): line-line/
line-circle/line-arc/circle-circle/circle-arc/arc-arc intersection geometry
for the trim/extend tool - see `Sketch.trim_or_extend_line`/
`trim_or_extend_arc`/`trim_circle`/`split_trim_line`, the only callers.

Nothing here existed anywhere in this codebase before Phase 11: the only
prior intersection-related code is `profile.py`'s `_segments_intersect`, a
*boolean* orientation test used for closed-loop overlap validation, not a
coordinate solve. Deliberately plain `(x, y)` tuples throughout, not
`Point`/`Sketch` - this module is pure geometry, decoupled from the domain
model the same way `_segments_intersect` already is.

Splines and Ellipses are still out of scope (no closed-form intersection
without curve-specific root-finding/numerical subdivision - a materially
bigger, separate undertaking) - neither is ever an intersection target, and
neither can itself be trimmed/extended. Line/Circle/Arc are now all valid
both as intersection targets AND as the entity trimmed/extended - Phase 11
only supported Line as the trimmed entity; the on-device feedback round
that added `circle_vs_circle`/`circle_vs_arc`/`arc_vs_arc` below (plus
`Sketch.trim_or_extend_arc`/`trim_circle`) closed that gap for Circle/Arc.
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


def line_vs_line(a1: Point2D, a2: Point2D, b1: Point2D, b2: Point2D) -> Point2D | None:
    """Where the *infinite* lines through (a1, a2) and (b1, b2) cross, or
    None if they're parallel (or too close to it to be numerically
    meaningful). Unlike [line_vs_segment], *neither* line is clipped to its
    own segment's span - used by `Sketch.offset_chain`'s corner-join, where
    two Lines that met at a real corner before offsetting generally need to
    be extended or trimmed past their own raw offset endpoints to meet
    again, which is exactly what an unclipped intersection gives. Same
    Cramer's-rule algebra as [line_vs_segment], with the `u`-bound clip
    check dropped.
    """
    ax1, ay1 = a1
    ax2, ay2 = a2
    bx1, by1 = b1
    bx2, by2 = b2
    dir_a = (ax2 - ax1, ay2 - ay1)
    dir_b = (bx2 - bx1, by2 - by1)
    to_b = (bx1 - ax1, by1 - ay1)
    denominator = dir_b[0] * dir_a[1] - dir_a[0] * dir_b[1]
    if abs(denominator) < 1e-9:
        return None
    t = (dir_b[0] * to_b[1] - to_b[0] * dir_b[1]) / denominator
    return (ax1 + t * dir_a[0], ay1 + t * dir_a[1])


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
        if angle_in_ccw_sweep(math.atan2(point[1] - cy, point[0] - cx), start_angle, end_angle)
    ]


def angle_in_ccw_sweep(angle: float, start_angle: float, end_angle: float) -> bool:
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


def circle_vs_circle(center1: Point2D, radius1: float, center2: Point2D, radius2: float) -> list[Point2D]:
    """Every point (0, 1 tangent, or 2) where two full circles cross -
    standard radical-line construction: the two circles' intersection
    points both lie on the line perpendicular to the centre-to-centre axis,
    at distance `a` from `center1` along that axis (solved from the two
    circle equations' difference) and `h` off it either side.

    Unlike [line_vs_circle]/[line_vs_arc], neither circle has an "end" to
    clip against on this side either - every real solution is a valid
    candidate; a caller trimming an *Arc* (not a full Circle) is
    responsible for filtering to its own sweep itself (see
    [circle_vs_arc]/[arc_vs_arc] below, which do exactly that).
    """
    c1x, c1y = center1
    c2x, c2y = center2
    dx, dy = c2x - c1x, c2y - c1y
    d = math.hypot(dx, dy)
    if d < 1e-9:
        return []  # concentric circles - either coincident (infinite) or no crossing; neither is a usable candidate
    if d > radius1 + radius2 + 1e-9 or d < abs(radius1 - radius2) - 1e-9:
        return []  # too far apart, or one strictly contains the other, with no crossing either way
    a = (radius1 * radius1 - radius2 * radius2 + d * d) / (2 * d)
    h_sq = radius1 * radius1 - a * a
    h = math.sqrt(h_sq) if h_sq > 0 else 0.0
    mid_x = c1x + a * dx / d
    mid_y = c1y + a * dy / d
    if h < 1e-9:
        return [(mid_x, mid_y)]  # externally/internally tangent - one repeated root
    perp_x, perp_y = -dy / d, dx / d
    return [
        (mid_x + h * perp_x, mid_y + h * perp_y),
        (mid_x - h * perp_x, mid_y - h * perp_y),
    ]


def circle_vs_arc(
    circle_center: Point2D,
    circle_radius: float,
    arc_center: Point2D,
    arc_radius: float,
    arc_start: Point2D,
    arc_end: Point2D,
) -> list[Point2D]:
    """[circle_vs_circle], filtered to the Arc's own swept portion of its
    circle - mirrors [line_vs_arc]'s identical relationship to
    [line_vs_circle]."""
    candidates = circle_vs_circle(circle_center, circle_radius, arc_center, arc_radius)
    if not candidates:
        return []
    acx, acy = arc_center
    start_angle = math.atan2(arc_start[1] - acy, arc_start[0] - acx)
    end_angle = math.atan2(arc_end[1] - acy, arc_end[0] - acx)
    return [
        point
        for point in candidates
        if angle_in_ccw_sweep(math.atan2(point[1] - acy, point[0] - acx), start_angle, end_angle)
    ]


def arc_vs_arc(
    center1: Point2D,
    radius1: float,
    start1: Point2D,
    end1: Point2D,
    center2: Point2D,
    radius2: float,
    start2: Point2D,
    end2: Point2D,
) -> list[Point2D]:
    """[circle_vs_circle], filtered to *both* Arcs' own swept portions -
    mirrors [circle_vs_arc], just clipped from both sides instead of one."""
    candidates = circle_vs_circle(center1, radius1, center2, radius2)
    if not candidates:
        return []
    c1x, c1y = center1
    c2x, c2y = center2
    start_angle1 = math.atan2(start1[1] - c1y, start1[0] - c1x)
    end_angle1 = math.atan2(end1[1] - c1y, end1[0] - c1x)
    start_angle2 = math.atan2(start2[1] - c2y, start2[0] - c2x)
    end_angle2 = math.atan2(end2[1] - c2y, end2[0] - c2x)
    return [
        point
        for point in candidates
        if angle_in_ccw_sweep(math.atan2(point[1] - c1y, point[0] - c1x), start_angle1, end_angle1)
        and angle_in_ccw_sweep(math.atan2(point[1] - c2y, point[0] - c2x), start_angle2, end_angle2)
    ]
