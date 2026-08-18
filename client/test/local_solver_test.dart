// Milestone C verification (sketcher restructure plan Phase 1): pure-Dart
// tests for the SolverBuilder/constraint-dispatch/solveSketch port in
// lib/sketch/local_solver/, run against the same host-built
// didsa_slvs_ffi library Milestone B's desktop parity harness already
// proved matches the real backend (client/native/slvs/build-host/). No
// flutter_scene import here, so unlike part_viewport_test.dart and its
// relatives this file runs under plain `flutter test` in any environment.
//
// Skips (rather than failing outright) if the host library hasn't been
// built - these tests need client/native/slvs/CMakeLists.txt's host build
// step to have run first (see that file's own header comment for the
// two-step recipe); that's a real local build artifact, not something
// `flutter test` can produce on its own.
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/local_solver/local_sketch_solver.dart';
import 'package:didsa_cad_client/sketch/local_solver/slvs_bindings.dart';

String? _findHostLibrary() {
  final candidates = [
    'native/slvs/build-host/libdidsa_slvs_ffi.dll',
    'native/slvs/build-host/libdidsa_slvs_ffi.so',
    'native/slvs/build-host/libdidsa_slvs_ffi.dylib',
  ];
  for (final relative in candidates) {
    final file = File(relative);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}

(String, String) _lineEndpoints(Map<String, (String, String)> lines, String lineId) => lines[lineId]!;

void main() {
  final libraryPath = _findHostLibrary();
  if (libraryPath == null) {
    test('local solver (skipped - host library not built)', () {}, skip: true);
    return;
  }
  final bindings = SlvsNativeBindings(ffi.DynamicLibrary.open(libraryPath));

  test('simple two-point/distance case matches backend ground truth', () {
    // Same case as backend/tests/test_stage2b_solver_integration.py's
    // test_solve_over_the_api_updates_points_and_reports_convergence.
    final points = {'a': (0.0, 0.0), 'b': (1.0, 0.0)};
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'b', distance: 50.0),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(const {}, id),
    );

    expect(result.converged, isTrue);
    expect(result.resultCode, 0);
    expect(result.dof, 3);
    final (ax, ay) = result.solvedPoints['a']!;
    final (bx, by) = result.solvedPoints['b']!;
    final distance = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    expect(distance, closeTo(2500.0, 1e-6)); // 50.0^2
  });

  test('anchor pinning keeps the anchored point fixed (drag-solve semantics)', () {
    final points = {'a': (3.0, 4.0), 'b': (10.0, 0.0)};
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'b', distance: 50.0),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(const {}, id),
      anchorPointIds: {'a'},
    );

    expect(result.converged, isTrue);
    final (ax, ay) = result.solvedPoints['a']!;
    expect(ax, closeTo(3.0, 1e-9));
    expect(ay, closeTo(4.0, 1e-9));
  });

  test('provisional DistanceConstraint contributes zero DOF-removal until confirmed', () {
    // A single Point pinned by only a provisional radius-style Distance
    // constraint from the origin should behave as if unconstrained.
    final points = {'origin': (0.0, 0.0), 'p': (5.0, 0.0)};
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'p', distance: 5.0, provisional: true),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(const {}, id),
      originPointId: 'origin',
    );

    expect(result.converged, isTrue);
    // Both of p's coordinates are still free (origin is pinned, p is not,
    // and the provisional constraint removed nothing) - dof should be 2.
    expect(result.dof, 2);
  });

  test('Slot construction: redundant Tangent+EqualRadius system converges with raw dof 0', () {
    // Mirrors _build_slot in
    // backend/tests/test_bugfix_provisional_size_constraints.py exactly
    // (minus arc1's own provisional radius DistanceConstraint, which the
    // dispatch loop skips before it ever reaches the solver - see that
    // fixture's own doc comment). Ground truth (result_code 5, raw dof 0,
    // positions unchanged from their seeded values) captured from a real
    // py-slvs run on this machine - see client/native/slvs/
    // desktop_parity_harness's own Slot case for the from-scratch version
    // of this same derivation.
    const c1 = (0.0, 0.0), c2 = (20.0, 0.0), radius = 5.0;
    final points = {
      'c1p': c1,
      'c2p': c2,
      'a': (c1.$1, c1.$2 + radius),
      'b': (c1.$1, c1.$2 - radius),
      'c': (c2.$1, c2.$2 - radius),
      'd': (c2.$1, c2.$2 + radius),
    };
    final lines = {
      'line1': ('b', 'c'),
      'line2': ('d', 'a'),
    };
    final constraints = <ConstraintDto>[
      const EqualRadiusConstraintDto(id: 'er1', center1PointId: 'c1p', radius1PointId: 'a', center2PointId: 'c2p', radius2PointId: 'c'),
      const EqualRadiusConstraintDto(id: 'er2', center1PointId: 'c1p', radius1PointId: 'a', center2PointId: 'c2p', radius2PointId: 'd'),
      const TangentConstraintDto(id: 't1', centerPointId: 'c1p', radiusPointId: 'a', lineId: 'line1'),
      const TangentConstraintDto(id: 't2', centerPointId: 'c1p', radiusPointId: 'a', lineId: 'line2'),
      const TangentConstraintDto(id: 't3', centerPointId: 'c2p', radiusPointId: 'c', lineId: 'line1'),
      const TangentConstraintDto(id: 't4', centerPointId: 'c2p', radiusPointId: 'c', lineId: 'line2'),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
    );

    expect(result.converged, isTrue, reason: 'redundant-but-solved override should apply');
    expect(result.resultCode, 5);
    for (final id in points.keys) {
      final (x, y) = result.solvedPoints[id]!;
      final (expectedX, expectedY) = points[id]!;
      expect(x, closeTo(expectedX, 1e-6), reason: '$id.x');
      expect(y, closeTo(expectedY, 1e-6), reason: '$id.y');
    }
  });

  test(
      'residual-verified convergence: a Polygon\'s own already-redundant EqualLength/EqualRadius/'
      'Angle chain plus a further genuinely-implied LineDistanceConstraint on top (an "across '
      'flats" dimension) reports converged - mirrors the same scenario proven server-side in '
      'solver.py, confirming resultCode alone (stays 1, never 4/5) can\'t tell "doubly-redundant '
      'but consistent" from a real conflict, but _residualVerifiedConvergence can', () {
    // A regular hexagon, radius 10, centred at the origin - center + first
    // vertex (10, 0), the rest placed by the same formula add_polygon uses.
    const sides = 6;
    const radius = 10.0;
    final points = <String, (double, double)>{'center': (0.0, 0.0)};
    for (var i = 0; i < sides; i++) {
      final angle = 2 * math.pi * i / sides;
      points['v$i'] = (radius * math.cos(angle), radius * math.sin(angle));
    }
    final lines = <String, (String, String)>{
      for (var i = 0; i < sides; i++) 'line$i': ('v$i', 'v${(i + 1) % sides}'),
    };
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'radius', pointAId: 'center', pointBId: 'v0', distance: radius),
      for (var i = 1; i < sides; i++)
        EqualRadiusConstraintDto(
          id: 'er$i',
          center1PointId: 'center',
          radius1PointId: 'v0',
          center2PointId: 'center',
          radius2PointId: 'v$i',
        ),
      for (var i = 1; i < sides; i++) ...[
        EqualLengthConstraintDto(id: 'el$i', line1Id: 'line${i - 1}', line2Id: 'line$i'),
        AngleConstraintDto(id: 'ang$i', line1Id: 'line${i - 1}', line2Id: 'line$i', angleDegrees: 360.0 / sides),
      ],
    ];

    // Sanity: the polygon's own chain alone already relies on the
    // redundant-but-solved override (a different one than the Tangent/
    // EqualRadius-gated override above - this hits the residual check via
    // the "not converged" branch too, since Angle/EqualLength chains aren't
    // covered by that narrower override's own hasTangentOrEqualRadius gate
    // unless EqualRadius is present, which it is here - either path is
    // fine, only the end result matters for this test).
    final baseline = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
    );
    expect(baseline.converged, isTrue, reason: 'sanity check: the polygon alone must already solve');

    // Across-flats distance for a regular hexagon of this radius: 2 * apothem.
    // Negated (bug fix: LineDistanceConstraintDto.distance is a *signed*
    // perpendicular distance, matching py-slvs's own addPointLineDistance -
    // see backend solver.py's `_signed_point_line_distance` doc comment for
    // why a plain positive magnitude doesn't just solve to the mirrored
    // side, it fails to converge outright; v3 sits on line0's cross-
    // product-negative side for this v0=(radius,0), CCW vertex layout).
    final acrossFlats = 2 * radius * math.cos(math.pi / sides);
    final withDimension = [
      ...constraints,
      LineDistanceConstraintDto(id: 'flats', line1Id: 'line0', line2Id: 'line3', distance: -acrossFlats),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: withDimension,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
    );

    expect(result.converged, isTrue, reason: 'residual-verified override should apply');
    expect(result.resultCode, isNot(0), reason: 'py-slvs itself never cleanly certifies this - the override is what makes it converged');

    // A deliberately wrong across-flats value must still be rejected - the
    // override isn't a rubber stamp. Same (negative) side as above, just
    // the wrong magnitude.
    final withWrongDimension = [
      ...constraints,
      LineDistanceConstraintDto(id: 'flats', line1Id: 'line0', line2Id: 'line3', distance: -(acrossFlats + 5.0)),
    ];
    final wrongResult = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: withWrongDimension,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
    );
    expect(wrongResult.converged, isFalse, reason: 'a genuinely wrong value must not be waved through');
  });

  test(
      'residual-verified convergence respects horizontal/vertical DistanceConstraint orientation, '
      'not plain Euclidean distance - bug fix found while investigating a Circle drag/collapse '
      'report: a Circle\'s own cardinal-point axis pins are always exactly this shape '
      '(orientation horizontal/vertical, distance 0.0), so getting this wrong could both reject a '
      'genuinely satisfied axis pin and, worse, wave through a collapsed/degenerate solve whose '
      'Points happen to also be Euclidean-close', () {
    // Two duplicate horizontal-distance constraints on the same pair force
    // a redundant (non-clean resultCode) solve with nothing else present -
    // isolates the residual check itself, since neither Tangent nor
    // EqualRadius is present to trigger the older, narrower override.
    final points = {'a': (0.0, 0.0), 'b': (5.0, 100.0)};
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'h1', pointAId: 'a', pointBId: 'b', distance: 5.0, orientation: 'horizontal'),
      const DistanceConstraintDto(id: 'h2', pointAId: 'a', pointBId: 'b', distance: 5.0, orientation: 'horizontal'),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => throw UnimplementedError('no Lines in this fixture'),
    );

    expect(result.resultCode, isNot(0), reason: 'sanity check: py-slvs itself must not cleanly certify this');
    expect(result.converged, isTrue,
        reason: 'the horizontal separation (5) is exactly satisfied - only the *Euclidean* distance '
            '(~100.1, since the Points are 100 apart in Y) would wrongly look unsatisfied');
  });

  test(
      'LineDistanceConstraintDto alone leaves Line 2 free to rotate about its own start Point - '
      'genuinely locking the two Lines parallel is the client\'s own job now (a separate, real '
      'ParallelConstraintDto - see the next test), not something baked into this DTO\'s own solver '
      'dispatch (on-device feedback: "adding a dimension between two parallel edges of a rectangle '
      'makes it over constrained" - a first attempt that baked Parallel in here unconditionally '
      'stacked a redundant equation on top of a pair of Lines already forced parallel some other '
      'way, e.g. a rectangle\'s own opposite Horizontal-constrained sides)', () {
    final points = {
      'a1': (0.0, 0.0),
      'a2': (0.0, 10.0),
      'b1': (5.0, 1.0),
      'b2': (6.0, 9.0),
    };
    final lines = {'line1': ('a1', 'a2'), 'line2': ('b1', 'b2')};
    final constraints = <ConstraintDto>[
      const LineDistanceConstraintDto(id: 'dim', line1Id: 'line1', line2Id: 'line2', distance: 5.0),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
      anchorPointIds: {'a1', 'a2'},
    );

    expect(result.converged, isTrue);
    final (a1x, a1y) = result.solvedPoints['a1']!;
    final (a2x, a2y) = result.solvedPoints['a2']!;
    final (b1x, b1y) = result.solvedPoints['b1']!;
    final (b2x, b2y) = result.solvedPoints['b2']!;
    final dir1 = (a2x - a1x, a2y - a1y);
    final dir2 = (b2x - b1x, b2y - b1y);
    final len1 = math.sqrt(dir1.$1 * dir1.$1 + dir1.$2 * dir1.$2);
    final len2 = math.sqrt(dir2.$1 * dir2.$1 + dir2.$2 * dir2.$2);
    final sinAngle = (dir1.$1 * dir2.$2 - dir1.$2 * dir2.$1).abs() / (len1 * len2);
    expect(sinAngle, greaterThan(1e-3),
        reason: 'sanity check: Line 2 must NOT end up parallel from the distance constraint alone');

    // The perpendicular distance itself is still exactly the dimensioned value.
    final dx = a2x - a1x, dy = a2y - a1y;
    final cross = (b1x - a1x) * dy - (b1y - a1y) * dx;
    expect(cross / len1, closeTo(5.0, 1e-6));
  });

  test(
      'LineDistanceConstraintDto plus a separate, real ParallelConstraintDto together genuinely '
      'lock the two Lines parallel - the composition SketchController.confirmGhostValue now uses '
      'for a freeform (not already axis-locked) parallel pair', () {
    final points = {
      'a1': (0.0, 0.0),
      'a2': (0.0, 10.0),
      'b1': (5.0, 1.0),
      'b2': (6.0, 9.0),
    };
    final lines = {'line1': ('a1', 'a2'), 'line2': ('b1', 'b2')};
    final constraints = <ConstraintDto>[
      const LineDistanceConstraintDto(id: 'dim', line1Id: 'line1', line2Id: 'line2', distance: 5.0),
      const ParallelConstraintDto(id: 'par', line1Id: 'line1', line2Id: 'line2'),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
      anchorPointIds: {'a1', 'a2'},
    );

    expect(result.converged, isTrue);
    final (a1x, a1y) = result.solvedPoints['a1']!;
    final (a2x, a2y) = result.solvedPoints['a2']!;
    final (b1x, b1y) = result.solvedPoints['b1']!;
    final (b2x, b2y) = result.solvedPoints['b2']!;
    final dir1 = (a2x - a1x, a2y - a1y);
    final dir2 = (b2x - b1x, b2y - b1y);
    final len1 = math.sqrt(dir1.$1 * dir1.$1 + dir1.$2 * dir1.$2);
    final len2 = math.sqrt(dir2.$1 * dir2.$1 + dir2.$2 * dir2.$2);
    final sinAngle = (dir1.$1 * dir2.$2 - dir1.$2 * dir2.$1).abs() / (len1 * len2);
    expect(sinAngle, closeTo(0.0, 1e-6), reason: 'Line 2 must end up parallel to Line 1');
    final dx = a2x - a1x, dy = a2y - a1y;
    final cross = (b1x - a1x) * dy - (b1y - a1y) * dx;
    expect(cross / len1, closeTo(5.0, 1e-6));
  });

  test(
      'reproduces the on-device "rectangle becomes over constrained" report: a pair of Lines '
      'already forced parallel via matching Horizontal constraints solves cleanly with just a '
      'LineDistanceConstraintDto, but stacking a redundant ParallelConstraintDto on top of that '
      'fails to converge - this is exactly what SketchController.confirmGhostValue\'s own trial-add '
      '+ rollback now guards against', () {
    final points = {
      'a1': (0.0, 0.0),
      'a2': (10.0, 0.0),
      'b1': (0.0, 5.0),
      'b2': (10.0, 5.0),
    };
    final lines = {'line1': ('a1', 'a2'), 'line2': ('b1', 'b2')};
    final baseConstraints = <ConstraintDto>[
      const HorizontalConstraintDto(id: 'h1', lineId: 'line1', pointAId: 'a1', pointBId: 'a2'),
      const HorizontalConstraintDto(id: 'h2', lineId: 'line2', pointAId: 'b1', pointBId: 'b2'),
      const LineDistanceConstraintDto(id: 'dim', line1Id: 'line1', line2Id: 'line2', distance: 5.0),
    ];

    final distanceOnly = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: baseConstraints,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
    );
    expect(distanceOnly.converged, isTrue,
        reason: 'distance alone between two already-Horizontal Lines must converge cleanly');

    final withRedundantParallel = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: [
        ...baseConstraints,
        const ParallelConstraintDto(id: 'par', line1Id: 'line1', line2Id: 'line2'),
      ],
      lineEndpoints: (id) => _lineEndpoints(lines, id),
    );
    expect(withRedundantParallel.converged, isFalse,
        reason: 'a redundant Parallel on top of an already-Horizontal-locked pair must NOT be '
            'silently accepted - this is why confirmGhostValue rolls it back rather than adding it '
            'unconditionally');
  });

  test(
      'PointOnEllipseConstraintDto: the Trammel of Archimedes construction pulls a free Point onto '
      'a fixed Ellipse\'s own curve - mirrors backend test_solving_pulls_a_free_point_onto_a_fixed_'
      'ellipse, ground truth captured from the same real py-slvs build via anchorPointIds (fixed-'
      'group placement - no redundant equation, unlike FixedConstraint\'s own where_dragged, so this '
      'isolates the construction itself)', () {
    const centerXY = (0.0, 0.0);
    const majorRadius = 8.0, minorRadius = 3.0;
    final points = {
      'center': centerXY,
      'major': (centerXY.$1 + majorRadius, centerXY.$2),
      'minor': (centerXY.$1, centerXY.$2 + minorRadius),
      'p': (5.0, 2.0),
    };
    final constraints = <ConstraintDto>[
      const PointOnEllipseConstraintDto(
        id: 'poe',
        pointId: 'p',
        ellipseId: 'ellipse1',
        centerPointId: 'center',
        majorPointId: 'major',
        minorPointId: 'minor',
      ),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(const {}, id),
      anchorPointIds: {'center', 'major', 'minor'},
    );

    expect(result.converged, isTrue);
    expect(result.dof, 1);
    final (cx, cy) = result.solvedPoints['center']!;
    final (mx, my) = result.solvedPoints['major']!;
    final (nx, ny) = result.solvedPoints['minor']!;
    final (px, py) = result.solvedPoints['p']!;
    expect(cx, closeTo(centerXY.$1, 1e-9));
    expect(cy, closeTo(centerXY.$2, 1e-9));
    final a = math.sqrt((mx - cx) * (mx - cx) + (my - cy) * (my - cy));
    final b = math.sqrt((nx - cx) * (nx - cx) + (ny - cy) * (ny - cy));
    final angle = math.atan2(my - cy, mx - cx);
    final dx = px - cx, dy = py - cy;
    final ca = math.cos(-angle), sa = math.sin(-angle);
    final u = dx * ca - dy * sa;
    final v = dx * sa + dy * ca;
    final residual = (u / a) * (u / a) + (v / b) * (v / b) - 1.0;
    expect(residual, closeTo(0.0, 1e-6));
  });
}
