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
    final acrossFlats = 2 * radius * math.cos(math.pi / sides);
    final withDimension = [
      ...constraints,
      LineDistanceConstraintDto(id: 'flats', line1Id: 'line0', line2Id: 'line3', distance: acrossFlats),
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
    // override isn't a rubber stamp.
    final withWrongDimension = [
      ...constraints,
      LineDistanceConstraintDto(id: 'flats', line1Id: 'line0', line2Id: 'line3', distance: acrossFlats + 5.0),
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
}
