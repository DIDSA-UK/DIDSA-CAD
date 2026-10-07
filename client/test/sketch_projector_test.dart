// Golden cases for the solver-free sketch projector (lib/sketch/local_solver/sketch_projector.dart).
//
// Every supported constraint type gets a one-point case: the grabbed point `d` is wished somewhere that violates the
// constraint, every other point is pinned, so the nearest feasible point is unique. Each case is checked three ways:
//   * against an independent, hand-written residual of the constraint (runs everywhere, no solver needed);
//   * against the known nearest point (`expected`), where it is easy to state;
//   * against the real SolveSpace answer for the same input, when the host library is built (see
//     client/native/slvs/CMakeLists.txt) - the reference the projector replaced.
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'support/slvs_reference/local_sketch_solver.dart';
import 'package:didsa_cad_client/sketch/projector/sketch_projector.dart';
import 'support/slvs_reference/slvs_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Pt = (double, double);

String? _hostLibrary() {
  for (final relative in [
    'native/slvs/build-host/libdidsa_slvs_ffi.dll',
    'native/slvs/build-host/libdidsa_slvs_ffi.so',
    'native/slvs/build-host/libdidsa_slvs_ffi.dylib',
  ]) {
    final file = File(relative);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}

double _dist(Pt a, Pt b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

/// Signed distance, SolveSpace's convention: `((p - s) x (e - s)) / |e - s|`.
double _signed(Pt p, Pt s, Pt e) {
  final dx = e.$1 - s.$1, dy = e.$2 - s.$2;
  return ((p.$1 - s.$1) * dy - (p.$2 - s.$2) * dx) / math.sqrt(dx * dx + dy * dy);
}

class _Case {
  final String name;
  final Map<String, Pt> points;
  final Map<String, (String, String)> lines;
  final List<ConstraintDto> constraints;
  final Pt wish;

  /// Independent residuals of the constraint at the answer (all ~0).
  final List<double> Function(Map<String, Pt>) residuals;

  /// The nearest feasible point, when easy to state.
  final Pt? expected;
  const _Case(this.name, this.points, this.lines, this.constraints, this.wish, this.residuals, {this.expected});
}

final List<_Case> _cases = [
  _Case(
    'distance',
    {'a': (0, 0), 'd': (10, 0)},
    {},
    [DistanceConstraintDto(id: 'c', pointAId: 'a', pointBId: 'd', distance: 10)],
    (7, 7),
    (p) => [_dist(p['a']!, p['d']!) - 10],
    expected: (10 * 7 / math.sqrt(98), 10 * 7 / math.sqrt(98)),
  ),
  _Case(
    'horizontal distance',
    {'a': (0, 0), 'd': (10, 2)},
    {},
    [DistanceConstraintDto(id: 'c', pointAId: 'a', pointBId: 'd', distance: 10, orientation: 'horizontal')],
    (12, 5),
    (p) => [p['d']!.$1 - p['a']!.$1 - 10],
    expected: (10, 5),
  ),
  _Case(
    'vertical distance, negative side kept',
    {'a': (0, 0), 'd': (3, -10)},
    {},
    [DistanceConstraintDto(id: 'c', pointAId: 'a', pointBId: 'd', distance: 10, orientation: 'vertical')],
    (6, -4),
    (p) => [p['d']!.$2 - p['a']!.$2 + 10],
    expected: (6, -10),
  ),
  _Case(
    'horizontal',
    {'a': (0, 0), 'd': (10, 0)},
    {'l': ('a', 'd')},
    [HorizontalConstraintDto(id: 'c', lineId: 'l', pointAId: 'a', pointBId: 'd')],
    (8, 5),
    (p) => [p['d']!.$2 - p['a']!.$2],
    expected: (8, 0),
  ),
  _Case(
    'vertical',
    {'a': (0, 0), 'd': (0, 10)},
    {'l': ('a', 'd')},
    [VerticalConstraintDto(id: 'c', lineId: 'l', pointAId: 'a', pointBId: 'd')],
    (4, 8),
    (p) => [p['d']!.$1 - p['a']!.$1],
    expected: (0, 8),
  ),
  _Case(
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
  _Case(
    'coincident',
    {'b': (5, 5), 'd': (6, 5)},
    {},
    [CoincidentConstraintDto(id: 'c', pointAId: 'b', pointBId: 'd')],
    (9, 1),
    (p) => [p['d']!.$1 - p['b']!.$1, p['d']!.$2 - p['b']!.$2],
    expected: (5, 5),
  ),
  _Case(
    'concentric',
    {'b': (5, 5), 'd': (6, 5)},
    {},
    [ConcentricConstraintDto(id: 'c', entity1Id: 'e1', entity2Id: 'e2', center1PointId: 'b', center2PointId: 'd')],
    (9, 1),
    (p) => [p['d']!.$1 - p['b']!.$1, p['d']!.$2 - p['b']!.$2],
    expected: (5, 5),
  ),
  _Case(
    'parallel',
    {'a': (0, 0), 'b': (10, 0), 'c': (0, 5), 'd': (10, 5)},
    {'l1': ('a', 'b'), 'l2': ('c', 'd')},
    [ParallelConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2')],
    (12, 9),
    (p) => [p['d']!.$2 - p['c']!.$2],
    expected: (12, 5),
  ),
  _Case(
    'perpendicular',
    {'a': (0, 0), 'b': (10, 0), 'c': (5, 0), 'd': (5, 8)},
    {'l1': ('a', 'b'), 'l2': ('c', 'd')},
    [PerpendicularConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2')],
    (9, 9),
    (p) => [p['d']!.$1 - p['c']!.$1],
    expected: (5, 9),
  ),
  _Case(
    'equal length',
    {'a': (0, 0), 'b': (10, 0), 'c': (0, 5), 'd': (10, 5)},
    {'l1': ('a', 'b'), 'l2': ('c', 'd')},
    [EqualLengthConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2')],
    (20, 5),
    (p) => [_dist(p['c']!, p['d']!) - 10],
    expected: (10, 5),
  ),
  _Case(
    'line tangent to a circle (radius point moves)',
    {'a': (-20, 0), 'b': (20, 0), 'c': (5, 4), 'd': (9, 4)},
    {'l': ('a', 'b')},
    [TangentConstraintDto(id: 'k', centerPointId: 'c', radiusPointId: 'd', lineId: 'l')],
    (5, 12),
    (p) => [_dist(p['c']!, p['d']!) - 4],
    expected: (5, 8),
  ),
  _Case(
    'two curves tangent at a shared point',
    {'c1': (0, 0), 'c2': (10, 0), 'd': (6, 0)},
    {},
    [CurveTangentConstraintDto(id: 'k', entity1Id: 'e1', entity2Id: 'e2', center1PointId: 'c1', center2PointId: 'c2', sharedPointId: 'd')],
    (4, 3),
    (p) => [p['d']!.$2],
    expected: (4, 0),
  ),
  _Case(
    'equal radius',
    {'c1': (0, 0), 'r1': (5, 0), 'c2': (20, 0), 'd': (25, 0)},
    {},
    [EqualRadiusConstraintDto(id: 'k', center1PointId: 'c1', radius1PointId: 'r1', center2PointId: 'c2', radius2PointId: 'd')],
    (20, 9),
    (p) => [_dist(p['c2']!, p['d']!) - 5],
    expected: (20, 5),
  ),
  _Case(
    'line distance (signed, from the second line start)',
    {'a': (0, 0), 'b': (10, 0), 'd': (0, 5), 'e': (10, 5)},
    {'l1': ('a', 'b'), 'l2': ('d', 'e')},
    // ((d - a) x (b - a)) / |b - a| = -5 at the start, so the stored distance is -5
    [LineDistanceConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2', distance: -5)],
    (3, 9),
    (p) => [_signed(p['d']!, p['a']!, p['b']!) + 5],
    expected: (3, 5),
  ),
  _Case(
    'point-line distance',
    {'a': (0, 0), 'b': (10, 0), 'd': (4, 3)},
    {'l': ('a', 'b')},
    [PointLineDistanceConstraintDto(id: 'k', pointId: 'd', lineId: 'l', distance: -3)],
    (6, 8),
    (p) => [_signed(p['d']!, p['a']!, p['b']!) + 3],
    expected: (6, 3),
  ),
  _Case(
    'collinear',
    {'a': (0, 0), 'b': (10, 0), 'd': (3, 1), 'e': (7, 0)},
    {'l1': ('a', 'b'), 'l2': ('d', 'e')},
    [CollinearConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2')],
    (3, 4),
    (p) => [_signed(p['d']!, p['a']!, p['b']!), _signed(p['e']!, p['a']!, p['b']!)],
    expected: (3, 0),
  ),
  _Case(
    'at midpoint',
    {'a': (0, 0), 'b': (10, 4), 'd': (4, 2)},
    {'l': ('a', 'b')},
    [AtMidpointConstraintDto(id: 'k', pointId: 'd', lineId: 'l')],
    (9, 9),
    (p) => [p['d']!.$1 - 5, p['d']!.$2 - 2],
    expected: (5, 2),
  ),
  _Case(
    'point on line',
    {'a': (0, 0), 'b': (10, 10), 'd': (3, 3)},
    {'l': ('a', 'b')},
    [PointOnLineConstraintDto(id: 'k', pointId: 'd', lineId: 'l')],
    (6, 5),
    (p) => [_signed(p['d']!, p['a']!, p['b']!)],
    expected: (5.5, 5.5),
  ),
  _Case(
    'point on circle',
    {'c': (0, 0), 'r': (5, 0), 'd': (0, 5)},
    {},
    [PointOnCircleConstraintDto(id: 'k', pointId: 'd', circleOrArcId: 'e', centerPointId: 'c', radiusPointId: 'r')],
    (6, 8),
    (p) => [_dist(p['c']!, p['d']!) - 5],
    expected: (3, 4),
  ),
  _Case(
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

SketchProjection _project(_Case c, {Map<String, Pt>? points, Set<String>? pinned, Pt? wish}) {
  final pts = Map<String, Pt>.of(points ?? c.points);
  final start = Map<String, Pt>.of(pts);
  pts['d'] = wish ?? c.wish;
  return projectSketch(
    points: pts,
    reference: start,
    constraints: c.constraints,
    lineEndpoints: (id) => c.lines[id]!,
    anchorPointIds: {'d'},
    pinnedPointIds: pinned ?? {for (final id in c.points.keys) if (id != 'd') id},
  );
}

void main() {
  group('projector: one grabbed point, everything else pinned', () {
    for (final c in _cases) {
      test(c.name, () {
        final r = _project(c);
        // ignore: avoid_print
        if (Platform.environment['DIDSA_PROJ_TRACE'] == '1') print('${c.name}: walks=${r.walks} rejected=${r.rejectedSteps} exit=${r.exit} it=${r.iterations}');
        expect(r.unsupported, isFalse);
        expect(r.converged, isTrue, reason: 'residual ${r.residualInf}');
        final solved = {...c.points, ...r.points};
        for (final res in c.residuals(solved)) {
          expect(res.abs(), lessThan(1e-5), reason: 'independent residual of ${c.name}');
        }
        // pinned points never move
        for (final id in c.points.keys) {
          if (id == 'd') continue;
          expect(r.points.containsKey(id), isFalse, reason: 'pinned $id is not a variable');
        }
        final want = c.expected;
        if (want != null) {
          expect(r.points['d']!.$1, closeTo(want.$1, 1e-4));
          expect(r.points['d']!.$2, closeTo(want.$2, 1e-4));
        }
      });
    }
  });

  group('projector: behaviour', () {
    test('only the dragged point\'s connected group is solved', () {
      final r = projectSketch(
        points: {'a': (0, 0), 'd': (10, 3), 'x': (50, 50), 'y': (60, 50)},
        reference: {'a': (0, 0), 'd': (10, 0), 'x': (50, 50), 'y': (60, 50)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'x', pointBId: 'y', distance: 10),
        ],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'d'},
        pinnedPointIds: {'a'},
      );
      expect(r.points.keys, ['d']);
      expect(r.variablePoints, 1);
      expect(r.rows, 1);
    });

    test('a pinned point does not link two groups', () {
      // d - a(pinned) - x: x is not part of d's group
      final r = projectSketch(
        points: {'a': (0, 0), 'd': (10, 3), 'x': (-10, 0)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'x', distance: 10),
        ],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'d'},
        pinnedPointIds: {'a'},
      );
      expect(r.points.keys, ['d']);
    });

    test('followers absorb the correction, the grabbed point keeps the cursor', () {
      // a(pinned) - f - d, both links 10; d is wished to (25, 0): f and d cannot both stay; the grabbed point should be
      // clamped to the reach (20), not pulled short by the follower going the wrong way.
      final r = projectSketch(
        points: {'a': (0, 0), 'f': (10, 0.5), 'd': (25, 0)},
        reference: {'a': (0, 0), 'f': (10, 0.5), 'd': (20, 0.5)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'f', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'f', pointBId: 'd', distance: 10),
        ],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'d'},
        pinnedPointIds: {'a'},
      );
      expect(r.converged, isTrue);
      expect(_dist(r.points['f']!, (0, 0)), closeTo(10, 1e-5));
      expect(_dist(r.points['f']!, r.points['d']!), closeTo(10, 1e-5));
      expect(r.points['d']!.$1, greaterThan(19.5));
    });

    test('consistent redundant constraints are harmless', () {
      // the same distance twice, plus a coincident-implied duplicate through a third point
      final r = projectSketch(
        points: {'a': (0, 0), 'd': (7, 7)},
        reference: {'a': (0, 0), 'd': (10, 0)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'd', pointBId: 'a', distance: 10),
        ],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'d'},
        pinnedPointIds: {'a'},
      );
      expect(r.converged, isTrue);
      expect(_dist(r.points['d']!, (0, 0)), closeTo(10, 1e-6));
    });

    test('conflicting constraints do not converge', () {
      final r = projectSketch(
        points: {'a': (0, 0), 'd': (10, 0)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'd', distance: 12),
        ],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'d'},
        pinnedPointIds: {'a'},
      );
      expect(r.converged, isFalse);
    });

    test('a provisional dimension only applies when the caller gives it a value', () {
      final constraint = DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10, provisional: true);
      final off = projectSketch(
        points: {'a': (0, 0), 'd': (7, 7)},
        constraints: [constraint],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'d'},
        pinnedPointIds: {'a'},
      );
      expect(off.rows, 0);
      expect(off.points.containsKey('d'), isTrue);
      expect(off.points['d']!.$1, 7);
      final on = projectSketch(
        points: {'a': (0, 0), 'd': (7, 7)},
        constraints: [constraint],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'d'},
        pinnedPointIds: {'a'},
        provisionalDistances: {'c1': 5},
      );
      expect(on.rows, 1);
      expect(_dist(on.points['d']!, (0, 0)), closeTo(5, 1e-6));
    });

    test('a spline tangency in the dragged group is reported unsupported', () {
      final r = projectSketch(
        points: {for (final id in ['a0', 'a1', 'a2', 'a3', 'b0', 'b1', 'b2', 'b3']) id: (0.0, 0.0)},
        constraints: [
          const SplineTangentConstraintDto(
            id: 'k',
            splineId: 's',
            segmentAP0: 'a0',
            segmentAP1: 'a1',
            segmentAP2: 'a2',
            segmentAP3: 'a3',
            segmentBP0: 'b0',
            segmentBP1: 'b1',
            segmentBP2: 'b2',
            segmentBP3: 'b3',
          ),
        ],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'a3'},
      );
      expect(r.unsupported, isTrue);
    });

    test('a wish beyond a wall lands on the wall, feasible, not rejected', () {
      final r = projectSketch(
        points: {'a': (0, 0), 'f': (10, 0.2), 'd': (60, 0)},
        reference: {'a': (0, 0), 'f': (10, 0.2), 'd': (20, 0.2)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'f', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'f', pointBId: 'd', distance: 10),
        ],
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'d'},
        pinnedPointIds: {'a'},
      );
      expect(r.converged, isTrue);
      expect(_dist(r.points['d']!, (0, 0)), closeTo(20, 1e-3));
    });

    test('a cost sanity bound: a 200-point connected chain projects well inside a frame budget', () {
      final pts = <String, Pt>{'p0': (0, 0)};
      final cons = <ConstraintDto>[];
      for (var i = 1; i < 200; i++) {
        pts['p$i'] = (5.0 * i, 0.3 * math.sin(i.toDouble()));
        cons.add(DistanceConstraintDto(id: 'c$i', pointAId: 'p${i - 1}', pointBId: 'p$i', distance: 5));
      }
      final reference = Map<String, Pt>.of(pts);
      pts['p199'] = (pts['p199']!.$1, pts['p199']!.$2 + 2);
      final watch = Stopwatch()..start();
      final r = projectSketch(
        points: pts,
        reference: reference,
        constraints: cons,
        lineEndpoints: (_) => throw StateError('no lines'),
        anchorPointIds: {'p199'},
        pinnedPointIds: {'p0'},
      );
      watch.stop();
      expect(r.converged, isTrue);
      // generous: the point is that it is not seconds (the JIT in a debug test run is several times slower than AOT)
      expect(watch.elapsedMilliseconds, lessThan(500));
    });
  });

  final library = _hostLibrary();
  group('projector vs SolveSpace (reference engine)', () {
    if (library == null) {
      test('compare with SolveSpace (skipped - host didsa_slvs_ffi library not built)', () {}, skip: true);
      return;
    }
    final bindings = SlvsNativeBindings(ffi.DynamicLibrary.open(library));
    // Types where SolveSpace's Newton step lands on the nearest point too: the answers must agree. For the others it returns
    // a feasible but not nearest point (angle, perpendicular: where its minimum-norm step in parameter space ends up) or
    // cannot solve the one-point case at all (collinear: redundant), so the projector must be feasible and at least as near.
    const sameAnswer = {
      'distance', 'horizontal distance', 'vertical distance, negative side kept', 'horizontal', 'vertical', 'coincident',
      'concentric', 'parallel', 'equal length', 'line tangent to a circle (radius point moves)',
      'two curves tangent at a shared point', 'equal radius', 'line distance (signed, from the second line start)',
      'point-line distance', 'at midpoint', 'point on line', 'point on circle',
    };
    for (final c in _cases) {
      test(c.name, () {
        final pts = Map<String, Pt>.of(c.points);
        pts['d'] = c.wish;
        final reference = solveSketchLocally(
          bindings: bindings,
          points: pts,
          constraints: c.constraints,
          lineEndpoints: (id) => c.lines[id]!,
          anchorPointIds: {'d'},
          lockedPointIds: {for (final id in c.points.keys) if (id != 'd') id},
        );
        final projected = _project(c);
        expect(projected.converged, isTrue);
        final a = projected.points['d']!;
        if (!reference.converged) {
          expect(sameAnswer.contains(c.name), isFalse, reason: 'SolveSpace failed on a case it should solve');
          return;
        }
        final b = reference.solvedPoints['d']!;
        if (sameAnswer.contains(c.name)) {
          expect(_dist(a, b), lessThan(1e-3), reason: 'projector $a vs SolveSpace $b');
        } else {
          for (final res in c.residuals({...c.points, 'd': b})) {
            expect(res.abs(), lessThan(1e-3), reason: 'SolveSpace answer is feasible');
          }
          expect(_dist(a, c.wish), lessThanOrEqualTo(_dist(b, c.wish) + 1e-6),
              reason: 'projector $a must be at least as near the wish ${c.wish} as SolveSpace $b');
        }
      });
    }
  });
}
