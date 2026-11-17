import 'dart:math' as math;

import '../api/dimension_label_placement.dart';
import 'angle_rays.dart';

typedef SketchPoint = (double, double);

/// The one routine that turns "the pointer is at sketch-plane point P" into a [DimensionLabelPlacement] for the dimension being dragged
/// (docs/dimension-labels-scope.md, section 2.4). Pure sketch-unit maths with no pixels and no camera: the flat canvas feeds it the cursor in
/// sketch coordinates and the 3D sketch view feeds it the plane point under the pointer (`hitTestSketchPlane`), so a drag cannot depend on
/// the zoom or the orbit, and the two views agree on where a dimension sits.
///
/// Each `resolve…` has a `…LabelCenter` partner that does the reverse - placement back to the label's centre - which is how the tests check the
/// pair: drag to a point, read the parameters, lay the label out, expect it at that point. (The painters work from screen positions and have
/// their own defaults for an unset placement; these partners describe a *set* placement only.)
///
/// What each field means (all sketch units, so camera-independent):
///
/// * **Linear (point to point, or point to line):** the measured segment runs A to B. `offset` is how far the dimension line sits from it along
///   the left-hand normal of A to B (a 90 degree counter-clockwise turn of the direction), `along` how far the label sits from the dimension
///   line's midpoint towards B.
/// * **Horizontal / vertical:** the dimension line runs along the locked axis. `offset` is its coordinate past the larger of the two points'
///   coordinates on the other axis (so a horizontal dimension's line is at `max(A.y, B.y) + offset`, a vertical one's at `max(A.x, B.x) + offset`);
///   `along` is the label's distance from the points' midpoint in the positive direction of the locked axis (right, or up).
/// * **Line to line:** `offset` slides the connecting dimension line along line 1 from line 1's midpoint, `along` moves the label along the
///   connector (from its midpoint, towards line 2).
/// * **Radius / diameter:** `angle` is the leader's direction in degrees counter-clockwise from the rim point's direction, `leg` the label's
///   distance beyond the circle.
/// * **Angle:** `radius` is the arc's radius about the lines' intersection, `along` the label's distance along the arc from its middle,
///   towards the second line (so the label stays on the arc).
class LabelDragResolver {
  const LabelDragResolver._();

  // ---- linear -----------------------------------------------------------

  /// [orientation] is the constraint's `linear` / `horizontal` / `vertical` (null counts as linear). Null for a zero-length segment.
  static DimensionLabelPlacement? linear({
    required SketchPoint a,
    required SketchPoint b,
    String? orientation,
    required SketchPoint p,
  }) {
    switch (orientation) {
      case 'vertical':
        return DimensionLabelPlacement(
          offset: p.$1 - math.max(a.$1, b.$1),
          along: p.$2 - (a.$2 + b.$2) / 2,
        );
      case 'horizontal':
        return DimensionLabelPlacement(
          offset: p.$2 - math.max(a.$2, b.$2),
          along: p.$1 - (a.$1 + b.$1) / 2,
        );
    }
    final frame = _linearFrame(a, b);
    if (frame == null) return null;
    final (t, n) = frame;
    final mid = ((a.$1 + b.$1) / 2, (a.$2 + b.$2) / 2);
    return DimensionLabelPlacement(
      offset: _dot((p.$1 - a.$1, p.$2 - a.$2), n),
      along: _dot((p.$1 - mid.$1, p.$2 - mid.$2), t),
    );
  }

  static SketchPoint? linearLabelCenter({
    required SketchPoint a,
    required SketchPoint b,
    String? orientation,
    required DimensionLabelPlacement placement,
  }) {
    final offset = placement.offset ?? 0.0;
    final along = placement.along ?? 0.0;
    switch (orientation) {
      case 'vertical':
        return (math.max(a.$1, b.$1) + offset, (a.$2 + b.$2) / 2 + along);
      case 'horizontal':
        return ((a.$1 + b.$1) / 2 + along, math.max(a.$2, b.$2) + offset);
    }
    final frame = _linearFrame(a, b);
    if (frame == null) return null;
    final (t, n) = frame;
    final mid = ((a.$1 + b.$1) / 2, (a.$2 + b.$2) / 2);
    return (mid.$1 + n.$1 * offset + t.$1 * along, mid.$2 + n.$2 * offset + t.$2 * along);
  }

  /// The unit direction A to B and its left-hand normal, null for a zero-length segment. Public so the painters use the very same frame.
  static (SketchPoint tangent, SketchPoint normal)? linearFrame(SketchPoint a, SketchPoint b) => _linearFrame(a, b);

  static (SketchPoint, SketchPoint)? _linearFrame(SketchPoint a, SketchPoint b) {
    final dx = b.$1 - a.$1;
    final dy = b.$2 - a.$2;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 1e-9) return null;
    final t = (dx / length, dy / length);
    return (t, (-t.$2, t.$1));
  }

  // ---- line to line -----------------------------------------------------

  /// [line2Start] stands for line 2 as a whole (the two lines are parallel). Null when line 1 has no length or line 2 lies on line 1.
  static DimensionLabelPlacement? lineDistance({
    required SketchPoint line1Start,
    required SketchPoint line1End,
    required SketchPoint line2Start,
    required SketchPoint p,
  }) {
    final frame = _lineDistanceFrame(line1Start, line1End, line2Start);
    if (frame == null) return null;
    final (midA, midB, u, tangent) = frame;
    final anchor = ((midA.$1 + midB.$1) / 2, (midA.$2 + midB.$2) / 2);
    return DimensionLabelPlacement(
      offset: _dot((p.$1 - midA.$1, p.$2 - midA.$2), u),
      along: _dot((p.$1 - anchor.$1, p.$2 - anchor.$2), tangent),
    );
  }

  static SketchPoint? lineDistanceLabelCenter({
    required SketchPoint line1Start,
    required SketchPoint line1End,
    required SketchPoint line2Start,
    required DimensionLabelPlacement placement,
  }) {
    final frame = _lineDistanceFrame(line1Start, line1End, line2Start);
    if (frame == null) return null;
    final (midA, midB, u, tangent) = frame;
    final anchor = ((midA.$1 + midB.$1) / 2, (midA.$2 + midB.$2) / 2);
    final offset = placement.offset ?? 0.0;
    final along = placement.along ?? 0.0;
    return (anchor.$1 + u.$1 * offset + tangent.$1 * along, anchor.$2 + u.$2 * offset + tangent.$2 * along);
  }

  /// (line 1 midpoint, the foot of the perpendicular from it onto line 2, line 1's unit direction, the unit direction from the first towards the second).
  /// Public so the painters use the very same frame.
  static (SketchPoint, SketchPoint, SketchPoint, SketchPoint)? lineDistanceFrame(
    SketchPoint line1Start,
    SketchPoint line1End,
    SketchPoint line2Start,
  ) =>
      _lineDistanceFrame(line1Start, line1End, line2Start);

  static (SketchPoint, SketchPoint, SketchPoint, SketchPoint)? _lineDistanceFrame(
    SketchPoint line1Start,
    SketchPoint line1End,
    SketchPoint line2Start,
  ) {
    final dx = line1End.$1 - line1Start.$1;
    final dy = line1End.$2 - line1Start.$2;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 1e-9) return null;
    final u = (dx / length, dy / length);
    final perp = (-u.$2, u.$1);
    final midA = ((line1Start.$1 + line1End.$1) / 2, (line1Start.$2 + line1End.$2) / 2);
    final t = _dot((line2Start.$1 - midA.$1, line2Start.$2 - midA.$2), perp);
    if (t.abs() < 1e-9) return null;
    final midB = (midA.$1 + perp.$1 * t, midA.$2 + perp.$2 * t);
    final side = t < 0 ? -1.0 : 1.0;
    return (midA, midB, u, (perp.$1 * side, perp.$2 * side));
  }

  // ---- radius / diameter --------------------------------------------------

  /// Null when [p] is on the centre (no direction to speak of).
  static DimensionLabelPlacement? radial({
    required SketchPoint center,
    required SketchPoint rim,
    required double radius,
    required SketchPoint p,
  }) {
    final dx = p.$1 - center.$1;
    final dy = p.$2 - center.$2;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance < 1e-9) return null;
    final rimAngle = math.atan2(rim.$2 - center.$2, rim.$1 - center.$1);
    var delta = math.atan2(dy, dx) - rimAngle;
    while (delta > math.pi) {
      delta -= 2 * math.pi;
    }
    while (delta <= -math.pi) {
      delta += 2 * math.pi;
    }
    return DimensionLabelPlacement(angle: delta * 180.0 / math.pi, leg: distance - radius);
  }

  static SketchPoint radialLabelCenter({
    required SketchPoint center,
    required SketchPoint rim,
    required double radius,
    required DimensionLabelPlacement placement,
  }) {
    final rimAngle = math.atan2(rim.$2 - center.$2, rim.$1 - center.$1);
    final angle = rimAngle + (placement.angle ?? 0.0) * math.pi / 180.0;
    final distance = radius + (placement.leg ?? 0.0);
    return (center.$1 + distance * math.cos(angle), center.$2 + distance * math.sin(angle));
  }

  // ---- angle --------------------------------------------------------------

  /// The point the two lines meet at (their infinite extensions) and the two unit rays the angle is drawn between: the shared rule in
  /// `angle_rays.dart` ([angleRays]), so [valueDegrees] / [quadrant] pick the sector exactly as the painters do. Null for (near-)parallel
  /// lines.
  static (SketchPoint vertex, SketchPoint ray1, SketchPoint ray2)? angleVertexAndRays({
    required SketchPoint line1Start,
    required SketchPoint line1End,
    required SketchPoint line2Start,
    required SketchPoint line2End,
    double? valueDegrees,
    int? quadrant,
  }) {
    final rays = angleRays(
      line1Start: line1Start,
      line1End: line1End,
      line2Start: line2Start,
      line2End: line2End,
      valueDegrees: valueDegrees,
      quadrant: quadrant,
    );
    return rays == null ? null : (rays.vertex, rays.ray1, rays.ray2);
  }

  /// The arc's radius is the pointer's distance from the vertex and `along` its distance ALONG THE ARC from the arc's midpoint (positive
  /// towards the second ray), so the label sits on the arc. Null for parallel lines, or when [p] is behind the vertex (on the far side
  /// from the sector the angle opens into).
  static DimensionLabelPlacement? angle({
    required SketchPoint line1Start,
    required SketchPoint line1End,
    required SketchPoint line2Start,
    required SketchPoint line2End,
    required SketchPoint p,
    double? valueDegrees,
    int? quadrant,
  }) {
    final basis = angleVertexAndRays(
      line1Start: line1Start,
      line1End: line1End,
      line2Start: line2Start,
      line2End: line2End,
      valueDegrees: valueDegrees,
      quadrant: quadrant,
    );
    if (basis == null) return null;
    final (vertex, ray1, ray2) = basis;
    final dx = p.$1 - vertex.$1;
    final dy = p.$2 - vertex.$2;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance < 1e-6) return null;
    final mid = _arcMiddle(ray1, ray2);
    if (_dot((dx, dy), mid) <= 1e-9 * distance) return null;
    final sweepSign = _sweepSign(ray1, ray2);
    var delta = math.atan2(dy, dx) - math.atan2(mid.$2, mid.$1);
    while (delta <= -math.pi) {
      delta += 2 * math.pi;
    }
    while (delta > math.pi) {
      delta -= 2 * math.pi;
    }
    return DimensionLabelPlacement(radius: distance, along: delta * sweepSign * distance);
  }

  static SketchPoint? angleLabelCenter({
    required SketchPoint line1Start,
    required SketchPoint line1End,
    required SketchPoint line2Start,
    required SketchPoint line2End,
    required DimensionLabelPlacement placement,
    double? valueDegrees,
    int? quadrant,
  }) {
    final basis = angleVertexAndRays(
      line1Start: line1Start,
      line1End: line1End,
      line2Start: line2Start,
      line2End: line2End,
      valueDegrees: valueDegrees,
      quadrant: quadrant,
    );
    final radius = placement.radius;
    if (basis == null || radius == null) return null;
    final (vertex, ray1, ray2) = basis;
    final mid = _arcMiddle(ray1, ray2);
    final angle = math.atan2(mid.$2, mid.$1) + _sweepSign(ray1, ray2) * (placement.along ?? 0.0) / radius;
    return (vertex.$1 + radius * math.cos(angle), vertex.$2 + radius * math.sin(angle));
  }

  /// The unit direction from the vertex to the middle of the (non-reflex) arc between two unit rays. For opposite rays (a straight
  /// angle) the arc's middle is a quarter turn counter-clockwise from the first.
  static SketchPoint _arcMiddle(SketchPoint ray1, SketchPoint ray2) {
    final mx = ray1.$1 + ray2.$1;
    final my = ray1.$2 + ray2.$2;
    final length = math.sqrt(mx * mx + my * my);
    if (length < 1e-9) return (-ray1.$2, ray1.$1);
    return (mx / length, my / length);
  }

  /// +1 when the arc from the first ray to the second turns counter-clockwise, -1 when clockwise.
  static double _sweepSign(SketchPoint ray1, SketchPoint ray2) => ray1.$1 * ray2.$2 - ray1.$2 * ray2.$1 < 0 ? -1.0 : 1.0;

  static double _dot(SketchPoint a, SketchPoint b) => a.$1 * b.$1 + a.$2 * b.$2;
}
