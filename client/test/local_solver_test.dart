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
}
