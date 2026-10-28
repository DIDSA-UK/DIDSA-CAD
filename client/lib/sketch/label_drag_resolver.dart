import 'dart:math' as math;

import '../api/dimension_label_placement.dart';

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
/// * **Angle:** `radius` is the arc's radius about the lines' intersection, `along` the label's distance from the middle of the arc's chord,
///   towards the second line.
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

  /// The point the two lines meet at (their infinite extensions) and the unit rays from it towards each line's own end of the drawn segment.
  /// Null for (near-)parallel lines. Same rule as the 3D overlay's `angleDimensionVertexAndRays`.
  static (SketchPoint vertex, SketchPoint ray1, SketchPoint ray2)? angleVertexAndRays({
    required SketchPoint line1Start,
    required SketchPoint line1End,
    required SketchPoint line2Start,
    required SketchPoint line2End,
  }) {
    final p1 = line1Start, p2 = line1End, p3 = line2Start, p4 = line2End;
    final d1x = p2.$1 - p1.$1, d1y = p2.$2 - p1.$2;
    final d2x = p4.$1 - p3.$1, d2y = p4.$2 - p3.$2;
    final denom = d1x * d2y - d1y * d2x;
    if (denom.abs() < 1e-9) return null;
    final t = ((p3.$1 - p1.$1) * d2y - (p3.$2 - p1.$2) * d2x) / denom;
    final vertex = (p1.$1 + t * d1x, p1.$2 + t * d1y);

    SketchPoint outwardRay(double dx, double dy, SketchPoint a, SketchPoint b) {
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 1e-9) return (1.0, 0.0);
      final ux = dx / len, uy = dy / len;
      final midX = (a.$1 + b.$1) / 2 - vertex.$1;
      final midY = (a.$2 + b.$2) / 2 - vertex.$2;
      final dot = ux * midX + uy * midY;
      return dot >= 0 ? (ux, uy) : (-ux, -uy);
    }

    return (vertex, outwardRay(d1x, d1y, p1, p2), outwardRay(d2x, d2y, p3, p4));
  }

  /// Null for parallel lines, or when [p] is not on the side of the vertex the angle opens towards.
  static DimensionLabelPlacement? angle({
    required SketchPoint line1Start,
    required SketchPoint line1End,
    required SketchPoint line2Start,
    required SketchPoint line2End,
    required SketchPoint p,
  }) {
    final basis = angleVertexAndRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End);
    if (basis == null) return null;
    final (vertex, ray1, ray2) = basis;
    final dx = p.$1 - vertex.$1;
    final dy = p.$2 - vertex.$2;
    // The label sits at vertex + radius * m + along * chord, where m is the middle of the two rays and the chord runs across them at right
    // angles to m, so the point under the pointer splits into the two exactly.
    final mx = (ray1.$1 + ray2.$1) / 2;
    final my = (ray1.$2 + ray2.$2) / 2;
    final mLength = math.sqrt(mx * mx + my * my);
    final chord = _angleChord(ray1, ray2);
    if (mLength < 1e-6 || chord == null) {
      // Rays (nearly) opposite or equal: no chord to slide along, so the radius is just the distance.
      final distance = math.sqrt(dx * dx + dy * dy);
      return distance < 1e-6 ? null : DimensionLabelPlacement(radius: distance);
    }
    final radius = (dx * mx + dy * my) / (mLength * mLength);
    if (radius < 1e-6) return null;
    return DimensionLabelPlacement(radius: radius, along: _dot((dx, dy), chord));
  }

  static SketchPoint? angleLabelCenter({
    required SketchPoint line1Start,
    required SketchPoint line1End,
    required SketchPoint line2Start,
    required SketchPoint line2End,
    required DimensionLabelPlacement placement,
  }) {
    final basis = angleVertexAndRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End);
    final radius = placement.radius;
    if (basis == null || radius == null) return null;
    final (vertex, ray1, ray2) = basis;
    final mid = (vertex.$1 + radius * (ray1.$1 + ray2.$1) / 2, vertex.$2 + radius * (ray1.$2 + ray2.$2) / 2);
    final chord = _angleChord(ray1, ray2) ?? (0.0, 0.0);
    final along = placement.along ?? 0.0;
    return (mid.$1 + chord.$1 * along, mid.$2 + chord.$2 * along);
  }

  /// The unit direction of the arc's chord, from the first ray's end to the second's. Null when the rays coincide.
  static SketchPoint? _angleChord(SketchPoint ray1, SketchPoint ray2) {
    final dx = ray2.$1 - ray1.$1;
    final dy = ray2.$2 - ray1.$2;
    final length = math.sqrt(dx * dx + dy * dy);
    return length < 1e-9 ? null : (dx / length, dy / length);
  }

  static double _dot(SketchPoint a, SketchPoint b) => a.$1 * b.$1 + a.$2 * b.$2;
}
