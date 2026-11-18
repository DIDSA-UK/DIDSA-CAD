import 'dart:math' as math;

/// The one rule for which two rays an angle dimension is drawn between (bug report 2026-11-17 item 4). Used by the 3D sketch overlay
/// (`angleDimensionVertexAndRays`), the label drag ([LabelDragResolver]) and the flat 2D canvas, so they cannot disagree.
///
/// The vertex is where the two lines' infinite extensions meet. Each line's **outward ray** points from the vertex towards that line's own
/// drawn segment (its midpoint), so the arc anchors to the real segments wherever the vertex sits. Then:
///
/// * [quadrant] given (`AngleConstraint.quadrant` on the backend): bit 0 flips the first ray, bit 1 the second. The four values are the
///   four sectors around the vertex; the value is the angle between the two resulting rays.
/// * no quadrant but a [valueDegrees] (a constraint saved before the field existed): start from the outward rays and flip the second
///   when the angle between them is nearer `180 - value` than `value`, so the arc shows the angle the number names. This is the backend's
///   "nearest" rule seen from the drawing side.
/// * neither (a ghost before the cursor has chosen a side): the outward rays.
///
/// Null for (near-)parallel lines. Unit rays.
({(double, double) vertex, (double, double) ray1, (double, double) ray2})? angleRays({
  required (double, double) line1Start,
  required (double, double) line1End,
  required (double, double) line2Start,
  required (double, double) line2End,
  double? valueDegrees,
  int? quadrant,
}) {
  final outward = angleOutwardRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End);
  if (outward == null) return null;
  var (vertex, ray1, ray2) = (outward.vertex, outward.ray1, outward.ray2);
  if (quadrant != null) {
    if (quadrant & 1 != 0) ray1 = (-ray1.$1, -ray1.$2);
    if (quadrant & 2 != 0) ray2 = (-ray2.$1, -ray2.$2);
  } else if (valueDegrees != null) {
    final between = angleBetweenRaysDegrees(ray1, ray2);
    final value = valueDegrees.abs() % 360;
    if (((180 - value) - between).abs() < (value - between).abs()) ray2 = (-ray2.$1, -ray2.$2);
  }
  return (vertex: vertex, ray1: ray1, ray2: ray2);
}

/// The vertex and the two outward unit rays (see [angleRays]), with no flipping. Null for (near-)parallel lines.
({(double, double) vertex, (double, double) ray1, (double, double) ray2})? angleOutwardRays({
  required (double, double) line1Start,
  required (double, double) line1End,
  required (double, double) line2Start,
  required (double, double) line2End,
}) {
  final p1 = line1Start, p2 = line1End, p3 = line2Start, p4 = line2End;
  final d1x = p2.$1 - p1.$1, d1y = p2.$2 - p1.$2;
  final d2x = p4.$1 - p3.$1, d2y = p4.$2 - p3.$2;
  final denom = d1x * d2y - d1y * d2x;
  if (denom.abs() < 1e-9) return null;
  final t = ((p3.$1 - p1.$1) * d2y - (p3.$2 - p1.$2) * d2x) / denom;
  final vertex = (p1.$1 + t * d1x, p1.$2 + t * d1y);

  (double, double) outwardRay(double dx, double dy, (double, double) a, (double, double) b) {
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-9) return (1.0, 0.0);
    final ux = dx / len, uy = dy / len;
    final midX = (a.$1 + b.$1) / 2 - vertex.$1;
    final midY = (a.$2 + b.$2) / 2 - vertex.$2;
    final dot = ux * midX + uy * midY;
    return dot >= 0 ? (ux, uy) : (-ux, -uy);
  }

  return (vertex: vertex, ray1: outwardRay(d1x, d1y, p1, p2), ray2: outwardRay(d2x, d2y, p3, p4));
}

/// The angle (0-180 degrees) between two unit rays.
double angleBetweenRaysDegrees((double, double) a, (double, double) b) {
  final dot = (a.$1 * b.$1 + a.$2 * b.$2).clamp(-1.0, 1.0);
  return math.acos(dot) * 180 / math.pi;
}

/// Which of the four sectors around [vertex] the point [p] is in, as an [angleRays] quadrant, given the two OUTWARD rays (unflipped):
/// [p] - vertex is written as `a * ray1 + b * ray2`, and a negative `a` / `b` means that ray is flipped. Null when [p] is on the vertex
/// or the rays are parallel.
int? angleQuadrantAt({
  required (double, double) vertex,
  required (double, double) outwardRay1,
  required (double, double) outwardRay2,
  required (double, double) p,
}) {
  final dx = p.$1 - vertex.$1, dy = p.$2 - vertex.$2;
  if (dx * dx + dy * dy < 1e-18) return null;
  final det = outwardRay1.$1 * outwardRay2.$2 - outwardRay1.$2 * outwardRay2.$1;
  if (det.abs() < 1e-12) return null;
  final a = (dx * outwardRay2.$2 - dy * outwardRay2.$1) / det;
  final b = (outwardRay1.$1 * dy - outwardRay1.$2 * dx) / det;
  return (a < 0 ? 1 : 0) | (b < 0 ? 2 : 0);
}

/// Which end of a line an angle dimension's extension line starts from, or null for none (bug report 2026-11-18): [alongA] and [alongB]
/// are the line's two endpoints' distances from the vertex along the arc's ray (negative behind the vertex), [arcRadius] the arc's radius
/// in the same units. When the arc's arrowhead lands on the drawn segment itself the extension line would only lie over the sketch line, so
/// there is none; beyond the segment it runs from the farther end, short of it (between the vertex and the segment) from the nearer end.
/// 0 means the first endpoint, 1 the second.
int? angleExtensionLineStart(double alongA, double alongB, double arcRadius) {
  final lo = math.min(alongA, alongB), hi = math.max(alongA, alongB);
  if (arcRadius >= lo && arcRadius <= hi) return null;
  final fromHigh = arcRadius > hi;
  return (alongA >= alongB) == fromHigh ? 0 : 1;
}
