// The projector's golden cases, shared by `sketch_projector_test.dart` (which checks them against independent residuals, known
// nearest points and, where the host library is built, SolveSpace) and `sketch_vectors_test.dart` (which exports them, with
// drag paths and scenes, to docs/motion/sketch-vectors.json for the VR port; docs/motion/sketch-projector-spec.md).
//
// Every case: one grabbed point `d`, every other point pinned, a wish that violates the constraint, so the nearest feasible
// point is unique.
import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';

typedef Pt = (double, double);

double pointDistance(Pt a, Pt b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

/// Signed distance, SolveSpace's convention: `((p - s) x (e - s)) / |e - s|`.
double signedPointLine(Pt p, Pt s, Pt e) {
  final dx = e.$1 - s.$1, dy = e.$2 - s.$2;
  return ((p.$1 - s.$1) * dy - (p.$2 - s.$2) * dx) / math.sqrt(dx * dx + dy * dy);
}

class ProjectorCase {
  final String name;
  final Map<String, Pt> points;
  final Map<String, (String, String)> lines;
  final List<ConstraintDto> constraints;
  final Pt wish;

  /// Independent residuals of the constraint at the answer (all ~0).
  final List<double> Function(Map<String, Pt>) residuals;

  /// The nearest feasible point, when easy to state.
  final Pt? expected;

  /// How close the projector's answer must come to [expected]. The walk's "arrived" exit at the step-multiplier floor
  /// (`kProjectorMinOmega`) stops a few 1e-4 short on some curved constraints (docs/motion/sketch-projector-spec.md, 7.4).
  final double nearestTolerance;
  const ProjectorCase(this.name, this.points, this.lines, this.constraints, this.wish, this.residuals,
      {this.expected, this.nearestTolerance = 1e-4});
}

final List<ProjectorCase> projectorGoldenCases = [
  ProjectorCase(
    'distance',
    {'a': (0, 0), 'd': (10, 0)},
    {},
    [DistanceConstraintDto(id: 'c', pointAId: 'a', pointBId: 'd', distance: 10)],
    (7, 7),
    (p) => [pointDistance(p['a']!, p['d']!) - 10],
    expected: (10 * 7 / math.sqrt(98), 10 * 7 / math.sqrt(98)),
  ),
  ProjectorCase(
    'horizontal distance',
    {'a': (0, 0), 'd': (10, 2)},
    {},
    [DistanceConstraintDto(id: 'c', pointAId: 'a', pointBId: 'd', distance: 10, orientation: 'horizontal')],
    (12, 5),
    (p) => [p['d']!.$1 - p['a']!.$1 - 10],
    expected: (10, 5),
  ),
  ProjectorCase(
    'vertical distance, negative side kept',
    {'a': (0, 0), 'd': (3, -10)},
    {},
    [DistanceConstraintDto(id: 'c', pointAId: 'a', pointBId: 'd', distance: 10, orientation: 'vertical')],
    (6, -4),
    (p) => [p['d']!.$2 - p['a']!.$2 + 10],
    expected: (6, -10),
  ),
  ProjectorCase(
    'horizontal',
    {'a': (0, 0), 'd': (10, 0)},
    {'l': ('a', 'd')},
    [HorizontalConstraintDto(id: 'c', lineId: 'l', pointAId: 'a', pointBId: 'd')],
    (8, 5),
    (p) => [p['d']!.$2 - p['a']!.$2],
    expected: (8, 0),
  ),
  ProjectorCase(
    'vertical',
    {'a': (0, 0), 'd': (0, 10)},
    {'l': ('a', 'd')},
    [VerticalConstraintDto(id: 'c', lineId: 'l', pointAId: 'a', pointBId: 'd')],
    (4, 8),
    (p) => [p['d']!.$1 - p['a']!.$1],
    expected: (0, 8),
  ),
  ProjectorCase(
    'angle 60 degrees to a fixed line',
    {'a': (0, 0), 'b': (10, 0), 'd': (5, 8.660254037844386)},
    {'l1': ('a', 'b'), 'l2': ('a', 'd')},
    [AngleConstraintDto(id: 'c', line1Id: 'l1', line2Id: 'l2', angleDegrees: 60)],
    (3, 12),
    (p) {
      final d = p['d']!;
      return [math.atan2(d.$2, d.$1) * 180 / math.pi - 60];
    },
    // projection onto the 60 degree ray
    expected: (
      (3 * 0.5 + 12 * math.sqrt(3) / 2) * 0.5,
      (3 * 0.5 + 12 * math.sqrt(3) / 2) * math.sqrt(3) / 2,
    ),
  ),
  ProjectorCase(
    'coincident',
    {'b': (5, 5), 'd': (6, 5)},
    {},
    [CoincidentConstraintDto(id: 'c', pointAId: 'b', pointBId: 'd')],
    (9, 1),
    (p) => [p['d']!.$1 - p['b']!.$1, p['d']!.$2 - p['b']!.$2],
    expected: (5, 5),
  ),
  ProjectorCase(
    'concentric',
    {'b': (5, 5), 'd': (6, 5)},
    {},
    [ConcentricConstraintDto(id: 'c', entity1Id: 'e1', entity2Id: 'e2', center1PointId: 'b', center2PointId: 'd')],
    (9, 1),
    (p) => [p['d']!.$1 - p['b']!.$1, p['d']!.$2 - p['b']!.$2],
    expected: (5, 5),
  ),
  ProjectorCase(
    'parallel',
    {'a': (0, 0), 'b': (10, 0), 'c': (0, 5), 'd': (10, 5)},
    {'l1': ('a', 'b'), 'l2': ('c', 'd')},
    [ParallelConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2')],
    (12, 9),
    (p) => [p['d']!.$2 - p['c']!.$2],
    expected: (12, 5),
  ),
  ProjectorCase(
    'perpendicular',
    {'a': (0, 0), 'b': (10, 0), 'c': (5, 0), 'd': (5, 8)},
    {'l1': ('a', 'b'), 'l2': ('c', 'd')},
    [PerpendicularConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2')],
    (9, 9),
    (p) => [p['d']!.$1 - p['c']!.$1],
    expected: (5, 9),
  ),
  ProjectorCase(
    'equal length',
    {'a': (0, 0), 'b': (10, 0), 'c': (0, 5), 'd': (10, 5)},
    {'l1': ('a', 'b'), 'l2': ('c', 'd')},
    [EqualLengthConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2')],
    (20, 5),
    (p) => [pointDistance(p['c']!, p['d']!) - 10],
    expected: (10, 5),
  ),
  ProjectorCase(
    'line tangent to a circle (radius point moves)',
    {'a': (-20, 0), 'b': (20, 0), 'c': (5, 4), 'd': (9, 4)},
    {'l': ('a', 'b')},
    [TangentConstraintDto(id: 'k', centerPointId: 'c', radiusPointId: 'd', lineId: 'l')],
    (5, 12),
    (p) => [pointDistance(p['c']!, p['d']!) - 4],
    expected: (5, 8),
  ),
  ProjectorCase(
    'two curves tangent at a shared point',
    {'c1': (0, 0), 'c2': (10, 0), 'd': (6, 0)},
    {},
    [CurveTangentConstraintDto(id: 'k', entity1Id: 'e1', entity2Id: 'e2', center1PointId: 'c1', center2PointId: 'c2', sharedPointId: 'd')],
    (4, 3),
    (p) => [p['d']!.$2],
    expected: (4, 0),
  ),
  ProjectorCase(
    'equal radius',
    {'c1': (0, 0), 'r1': (5, 0), 'c2': (20, 0), 'd': (25, 0)},
    {},
    [EqualRadiusConstraintDto(id: 'k', center1PointId: 'c1', radius1PointId: 'r1', center2PointId: 'c2', radius2PointId: 'd')],
    (20, 9),
    (p) => [pointDistance(p['c2']!, p['d']!) - 5],
    expected: (20, 5),
  ),
  ProjectorCase(
    'line distance (signed, from the second line start)',
    {'a': (0, 0), 'b': (10, 0), 'd': (0, 5), 'e': (10, 5)},
    {'l1': ('a', 'b'), 'l2': ('d', 'e')},
    // ((d - a) x (b - a)) / |b - a| = -5 at the start, so the stored distance is -5
    [LineDistanceConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2', distance: -5)],
    (3, 9),
    (p) => [signedPointLine(p['d']!, p['a']!, p['b']!) + 5],
    expected: (3, 5),
  ),
  ProjectorCase(
    'point-line distance',
    {'a': (0, 0), 'b': (10, 0), 'd': (4, 3)},
    {'l': ('a', 'b')},
    [PointLineDistanceConstraintDto(id: 'k', pointId: 'd', lineId: 'l', distance: -3)],
    (6, 8),
    (p) => [signedPointLine(p['d']!, p['a']!, p['b']!) + 3],
    expected: (6, 3),
  ),
  ProjectorCase(
    'collinear',
    {'a': (0, 0), 'b': (10, 0), 'd': (3, 1), 'e': (7, 0)},
    {'l1': ('a', 'b'), 'l2': ('d', 'e')},
    [CollinearConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2')],
    (3, 4),
    (p) => [signedPointLine(p['d']!, p['a']!, p['b']!), signedPointLine(p['e']!, p['a']!, p['b']!)],
    expected: (3, 0),
  ),
  ProjectorCase(
    'at midpoint',
    {'a': (0, 0), 'b': (10, 4), 'd': (4, 2)},
    {'l': ('a', 'b')},
    [AtMidpointConstraintDto(id: 'k', pointId: 'd', lineId: 'l')],
    (9, 9),
    (p) => [p['d']!.$1 - 5, p['d']!.$2 - 2],
    expected: (5, 2),
  ),
  ProjectorCase(
    'point on line',
    {'a': (0, 0), 'b': (10, 10), 'd': (3, 3)},
    {'l': ('a', 'b')},
    [PointOnLineConstraintDto(id: 'k', pointId: 'd', lineId: 'l')],
    (6, 5),
    (p) => [signedPointLine(p['d']!, p['a']!, p['b']!)],
    expected: (5.5, 5.5),
  ),
  ProjectorCase(
    'point on circle',
    {'c': (0, 0), 'r': (5, 0), 'd': (0, 5)},
    {},
    [PointOnCircleConstraintDto(id: 'k', pointId: 'd', circleOrArcId: 'e', centerPointId: 'c', radiusPointId: 'r')],
    (6, 8),
    (p) => [pointDistance(p['c']!, p['d']!) - 5],
    expected: (3, 4),
  ),
  ProjectorCase(
    'point on ellipse',
    {'c': (0, 0), 'maj': (6, 0), 'min': (0, 3), 'd': (0, 3)},
    {},
    [PointOnEllipseConstraintDto(id: 'k', pointId: 'd', ellipseId: 'e', centerPointId: 'c', majorPointId: 'maj', minorPointId: 'min')],
    (5, 5),
    (p) {
      final d = p['d']!;
      return [math.pow(d.$1 / 6, 2) + math.pow(d.$2 / 3, 2) - 1];
    },
  ),
];

Pt _onRay(double degrees, Pt wish, [Pt from = (0, 0)]) {
  final ux = math.cos(degrees * math.pi / 180), uy = math.sin(degrees * math.pi / 180);
  final t = (wish.$1 - from.$1) * ux + (wish.$2 - from.$2) * uy;
  return (from.$1 + t * ux, from.$2 + t * uy);
}

Pt _onCircle(Pt center, double radius, Pt wish) {
  final dx = wish.$1 - center.$1, dy = wish.$2 - center.$2;
  final l = math.sqrt(dx * dx + dy * dy);
  return (center.$1 + radius * dx / l, center.$2 + radius * dy / l);
}

double _degreesOf(Pt v) => math.atan2(v.$2, v.$1) * 180 / math.pi;

/// Bug report 2026-11-18 part D's dimension types (the flat app's arc length, angle to horizontal, three-point angle and
/// minimum / maximum distances), in the same one-grabbed-point form. Kept apart from [projectorGoldenCases] because the
/// SolveSpace comparison has no model of them.
final List<ProjectorCase> projectorPartDCases = [
  ProjectorCase(
    'arc length (alone it fixes the end\'s direction: radius at the start times the sweep)',
    {'c': (0, 0), 's': (5, 0), 'd': (5 * math.cos(1.2), 5 * math.sin(1.2))},
    {},
    [ArcLengthConstraintDto(id: 'k', arcId: 'arc', centerPointId: 'c', startPointId: 's', endPointId: 'd', length: 6)],
    (1, 6),
    (p) => [math.atan2(p['d']!.$2, p['d']!.$1) - 1.2],
    expected: _onRay(1.2 * 180 / math.pi, (1, 6)),
  ),
  ProjectorCase(
    'angle to horizontal, quadrant 0 (30 degrees)',
    {'a': (0, 0), 'd': (10 * math.cos(math.pi / 6), 10 * math.sin(math.pi / 6))},
    {'l': ('a', 'd')},
    [HorizontalAngleConstraintDto(id: 'k', lineId: 'l', lineStartId: 'a', lineEndId: 'd', angleDegrees: 30, quadrant: 0)],
    (8, 6),
    (p) => [_degreesOf(p['d']!) - 30],
    expected: _onRay(30, (8, 6)),
  ),
  ProjectorCase(
    'angle to horizontal, no quadrant: the supplement the reference was nearer to (150 degrees)',
    {'a': (0, 0), 'd': (-10 * math.cos(math.pi / 6), 10 * math.sin(math.pi / 6))},
    {'l': ('a', 'd')},
    [HorizontalAngleConstraintDto(id: 'k', lineId: 'l', lineStartId: 'a', lineEndId: 'd', angleDegrees: 30)],
    (-6, 2),
    (p) => [_degreesOf(p['d']!) - 150],
    expected: _onRay(150, (-6, 2)),
  ),
  ProjectorCase(
    'three-point angle, quadrant 0 (40 degrees, vertex first)',
    {'v': (0, 0), 'a': (10, 0), 'd': (10 * math.cos(40 * math.pi / 180), 10 * math.sin(40 * math.pi / 180))},
    {},
    [PointAngleConstraintDto(id: 'k', vertexPointId: 'v', point1Id: 'a', point2Id: 'd', angleDegrees: 40, quadrant: 0)],
    (6, 9),
    (p) => [_degreesOf(p['d']!) - 40],
    expected: _onRay(40, (6, 9)),
  ),
  ProjectorCase(
    'minimum distance, Point outside a circle',
    {'c': (0, 0), 'r': (0, 5), 'd': (8, 0)},
    {},
    [
      PointCircleDistanceConstraintDto(
          id: 'k', pointId: 'd', circleOrArcId: 'circle', centerPointId: 'c', radiusPointId: 'r', distance: 3, side: 'min'),
    ],
    (6, 7),
    (p) => [pointDistance(p['d']!, (0, 0)) - 8],
    expected: _onCircle((0, 0), 8, (6, 7)),
    nearestTolerance: 1e-3,
  ),
  ProjectorCase(
    'minimum distance, Point inside a circle (kept inside)',
    {'c': (0, 0), 'r': (0, 5), 'd': (2, 0)},
    {},
    [
      PointCircleDistanceConstraintDto(
          id: 'k', pointId: 'd', circleOrArcId: 'circle', centerPointId: 'c', radiusPointId: 'r', distance: 3, side: 'min'),
    ],
    (1, 1),
    (p) => [pointDistance(p['d']!, (0, 0)) - 2],
    expected: _onCircle((0, 0), 2, (1, 1)),
  ),
  ProjectorCase(
    'maximum distance, Point and circle',
    {'c': (0, 0), 'r': (0, 5), 'd': (7, 0)},
    {},
    [
      PointCircleDistanceConstraintDto(
          id: 'k', pointId: 'd', circleOrArcId: 'circle', centerPointId: 'c', radiusPointId: 'r', distance: 12, side: 'max'),
    ],
    (6, 7),
    (p) => [pointDistance(p['d']!, (0, 0)) - 7],
    expected: _onCircle((0, 0), 7, (6, 7)),
    nearestTolerance: 1e-3,
  ),
  ProjectorCase(
    'minimum distance, two circles (the second one\'s rim point moves)',
    {'c1': (0, 0), 'r1': (0, 4), 'c2': (15, 0), 'd': (15, 5)},
    {},
    [
      CircleCircleDistanceConstraintDto(
          id: 'k', entity1Id: 'one', center1PointId: 'c1', radius1PointId: 'r1', entity2Id: 'two', center2PointId: 'c2',
          radius2PointId: 'd', distance: 6, side: 'min'),
    ],
    (18, 7),
    (p) => [pointDistance(p['d']!, (15, 0)) - 5],
    expected: _onCircle((15, 0), 5, (18, 7)),
    nearestTolerance: 1e-3,
  ),
  ProjectorCase(
    'maximum distance, two circles',
    {'c1': (0, 0), 'r1': (0, 4), 'c2': (15, 0), 'd': (15, 3)},
    {},
    [
      CircleCircleDistanceConstraintDto(
          id: 'k', entity1Id: 'one', center1PointId: 'c1', radius1PointId: 'r1', entity2Id: 'two', center2PointId: 'c2',
          radius2PointId: 'd', distance: 22, side: 'max'),
    ],
    (10, 0),
    (p) => [pointDistance(p['d']!, (15, 0)) - 3],
    expected: (12, 0),
    nearestTolerance: 1e-3,
  ),
  ProjectorCase(
    'tangent-side distance, line and circle (the rim point moves)',
    {'a': (-20, 0), 'b': (20, 0), 'c': (2, 10), 'd': (6, 10)},
    {'l': ('a', 'b')},
    [
      LineCircleDistanceConstraintDto(
          id: 'k', lineId: 'l', lineStartId: 'a', lineEndId: 'b', circleOrArcId: 'circle', centerPointId: 'c',
          radiusPointId: 'd', distance: 6, side: 'min'),
    ],
    (2, 17),
    (p) => [pointDistance(p['d']!, (2, 10)) - 4],
    expected: (2, 14),
    nearestTolerance: 1e-3,
  ),
  ProjectorCase(
    'far-side distance, line and circle',
    {'a': (-20, 0), 'b': (20, 0), 'c': (2, 10), 'd': (8, 10)},
    {'l': ('a', 'b')},
    [
      LineCircleDistanceConstraintDto(
          id: 'k', lineId: 'l', lineStartId: 'a', lineEndId: 'b', circleOrArcId: 'circle', centerPointId: 'c',
          radiusPointId: 'd', distance: 16, side: 'max'),
    ],
    (2, 3),
    (p) => [pointDistance(p['d']!, (2, 10)) - 6],
    expected: (2, 4),
    nearestTolerance: 1e-3,
  ),
];
