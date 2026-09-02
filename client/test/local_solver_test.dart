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

  test(
      'soft-drag (live-clamp/dragged[] mechanism): dragging one Point of a confirmed-distance pair '
      'whose *other* Point is genuinely free lets that other Point move to satisfy the Constraint, '
      'rather than hard-pinning the dragged Point exactly where it was seeded even when that '
      'violates the Constraint (the older, now-retired behaviour a prior version of this test '
      'asserted directly - see the spike behind this mechanism: client/native/slvs/patches/0001-'
      'system-solve-dragged-params.patch) - the "if it\'s not anchored, the shape should move" case', () {
    // Mirrors the Circle scenario the soft-drag spike validated directly
    // against the native System class: a=(0,0) starts as a valid centre for
    // a radius-5 circle through b=(5,0); b is then dragged toward (8,3),
    // off the circle - 'a' is a perfectly ordinary, undragged free Point
    // (not locked/pinned), so it's free to move to keep the distance exact.
    final points = {'a': (0.0, 0.0), 'b': (8.0, 3.0)};
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'b', distance: 5.0),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(const {}, id),
      anchorPointIds: {'b'},
    );

    expect(result.converged, isTrue);
    final (ax, ay) = result.solvedPoints['a']!;
    final (bx, by) = result.solvedPoints['b']!;
    final dist = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    expect(dist, closeTo(5.0, 1e-6), reason: 'the Constraint is never violated, unlike the old hard-pin behaviour');
    expect((bx - 8.0).abs() + (by - 3.0).abs(), lessThan(0.5),
        reason: 'the dragged Point still tracks close to where it was dragged to');
    expect((ax - 0.0).abs() + (ay - 0.0).abs(), greaterThan(0.5),
        reason: 'unlike a hard-pinned drag, the free Point actually moves to accommodate the drag - '
            'this is the "if it\'s not anchored, the shape should move" behaviour');
  });

  test(
      'soft-drag with the *other* Point locked (never movable): the dragged Point slides to the '
      'nearest point still satisfying the Constraint instead of teleporting to an arbitrary root or '
      'being forced exactly onto the (invalid) drag target - the "slides within the limits of the '
      'dimensions and constraints" case', () {
    final points = {'a': (0.0, 0.0), 'b': (8.0, 3.0)};
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'b', distance: 5.0),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(const {}, id),
      anchorPointIds: {'b'},
      lockedPointIds: {'a'},
    );

    expect(result.converged, isTrue);
    final (ax, ay) = result.solvedPoints['a']!;
    expect(ax, closeTo(0.0, 1e-9), reason: 'a is locked - never moved by this solve');
    expect(ay, closeTo(0.0, 1e-9));
    final (bx, by) = result.solvedPoints['b']!;
    final dist = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    expect(dist, closeTo(5.0, 1e-6));
    // Nearest point on the radius-5 circle around the locked centre to the
    // (8,3) drag target: (8,3) normalised, scaled to length 5.
    final norm = math.sqrt(8.0 * 8.0 + 3.0 * 3.0);
    expect(bx, closeTo(8.0 / norm * 5.0, 1e-3));
    expect(by, closeTo(3.0 / norm * 5.0, 1e-3));
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
      'ellipse, ground truth captured from the same real py-slvs build via lockedPointIds (true '
      'fixed-group placement, never varied by the solve regardless of any Constraint - unlike '
      'anchorPointIds\' own soft-drag semantics, which would let a Constraint pull these away from '
      'their seed - so this isolates the construction itself)', () {
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
      lockedPointIds: {'center', 'major', 'minor'},
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

  test(
      'EllipseArc constraint set (Distance x2 + Perpendicular + PointOnEllipse x2) - the exact '
      'constraint graph app.sketch.models.add_ellipse_arc builds server-side - converges locally '
      'with both start/end Points landing exactly on the curve. No new local-solver dispatch code '
      'was needed for EllipseArc itself (unlike PointOnEllipseConstraint above): it composes '
      'entirely from constraint types the dispatch table already handles generically.', () {
    const centerXY = (1.0, -2.0);
    const majorRadius = 7.0, minorRadius = 3.0;
    final rotation = math.pi / 6;
    final majorXY = (
      centerXY.$1 + majorRadius * math.cos(rotation),
      centerXY.$2 + majorRadius * math.sin(rotation),
    );
    final minorXY = (
      centerXY.$1 + minorRadius * math.cos(rotation + math.pi / 2),
      centerXY.$2 + minorRadius * math.sin(rotation + math.pi / 2),
    );
    final points = {
      'center': centerXY,
      'major': majorXY,
      'minor': minorXY,
      'start': (3.0, -4.0),
      'end': (-2.0, 1.0),
    };
    final lines = {
      'majorAxis': ('center', 'major'),
      'minorAxis': ('center', 'minor'),
    };
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'majorDist', pointAId: 'center', pointBId: 'major', distance: majorRadius),
      const DistanceConstraintDto(id: 'minorDist', pointAId: 'center', pointBId: 'minor', distance: minorRadius),
      const PerpendicularConstraintDto(id: 'perp', line1Id: 'majorAxis', line2Id: 'minorAxis'),
      const PointOnEllipseConstraintDto(
        id: 'startOnEllipse',
        pointId: 'start',
        ellipseId: 'arc1',
        centerPointId: 'center',
        majorPointId: 'major',
        minorPointId: 'minor',
      ),
      const PointOnEllipseConstraintDto(
        id: 'endOnEllipse',
        pointId: 'end',
        ellipseId: 'arc1',
        centerPointId: 'center',
        majorPointId: 'major',
        minorPointId: 'minor',
      ),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
      // Deliberately anchorPointIds (soft-drag), not lockedPointIds: unlike
      // the PointOnEllipseConstraintDto test above (an exact analytic
      // seed, genuinely wants zero give), this fixture's own
      // majorXY/minorXY seed is only *approximately* perpendicular/on-
      // radius (trig-derived, floating-point-inexact) - true rigid pinning
      // leaves no slack to resolve that inexactness and fails to converge
      // (resultCode 5, unhandled by any redundancy override this dispatch
      // set qualifies for); the small give soft-drag allows is exactly
      // what lets it settle.
      anchorPointIds: {'center', 'major', 'minor'},
    );

    expect(result.converged, isTrue, reason: 'resultCode=${result.resultCode}');
    double residualFor(String pointId) {
      final (cx, cy) = result.solvedPoints['center']!;
      final (mx, my) = result.solvedPoints['major']!;
      final (nx, ny) = result.solvedPoints['minor']!;
      final (px, py) = result.solvedPoints[pointId]!;
      final a = math.sqrt((mx - cx) * (mx - cx) + (my - cy) * (my - cy));
      final b = math.sqrt((nx - cx) * (nx - cx) + (ny - cy) * (ny - cy));
      final angle = math.atan2(my - cy, mx - cx);
      final dx = px - cx, dy = py - cy;
      final ca = math.cos(-angle), sa = math.sin(-angle);
      final u = dx * ca - dy * sa;
      final v = dx * sa + dy * ca;
      return (u / a) * (u / a) + (v / b) * (v / b) - 1.0;
    }

    expect(residualFor('start'), closeTo(0.0, 1e-6));
    expect(residualFor('end'), closeTo(0.0, 1e-6));
  });

  test(
      'bug fix (on-device feedback: "the elliptical arc is not as the user draws it... solver '
      'changes the shape after drawing"): a freshly-drawn EllipseArc - every Point placed exactly '
      'where app.sketch.models.add_ellipse_arc would place it, nothing anchored (the real shape '
      'right after the draw tool places it and calls solve, before any drag) - solves with '
      'negligible drift on every Point, not just start/end. Unlike the test above, this leaves '
      'centre/major/minor free too, so it actually exercises the rigid-frame slack the bad trammel '
      'seed used to leak into.', () {
    const centerXY = (1.0, -2.0);
    const majorRadius = 7.0, minorRadius = 3.0;
    final rotation = math.pi / 6;
    const startAngle = 0.4, endAngle = 2.3;
    (double, double) pointOnEllipse(double localAngle) {
      final u = majorRadius * math.cos(localAngle);
      final v = minorRadius * math.sin(localAngle);
      final ca = math.cos(rotation), sa = math.sin(rotation);
      return (centerXY.$1 + u * ca - v * sa, centerXY.$2 + u * sa + v * ca);
    }

    final majorXY = (
      centerXY.$1 + majorRadius * math.cos(rotation),
      centerXY.$2 + majorRadius * math.sin(rotation),
    );
    final minorXY = (
      centerXY.$1 + minorRadius * math.cos(rotation + math.pi / 2),
      centerXY.$2 + minorRadius * math.sin(rotation + math.pi / 2),
    );
    final points = {
      'center': centerXY,
      'major': majorXY,
      'minor': minorXY,
      'start': pointOnEllipse(startAngle),
      'end': pointOnEllipse(endAngle),
    };
    final lines = {
      'majorAxis': ('center', 'major'),
      'minorAxis': ('center', 'minor'),
    };
    final constraints = <ConstraintDto>[
      const DistanceConstraintDto(id: 'majorDist', pointAId: 'center', pointBId: 'major', distance: majorRadius),
      const DistanceConstraintDto(id: 'minorDist', pointAId: 'center', pointBId: 'minor', distance: minorRadius),
      const PerpendicularConstraintDto(id: 'perp', line1Id: 'majorAxis', line2Id: 'minorAxis'),
      const PointOnEllipseConstraintDto(
        id: 'startOnEllipse',
        pointId: 'start',
        ellipseId: 'arc2',
        centerPointId: 'center',
        majorPointId: 'major',
        minorPointId: 'minor',
      ),
      const PointOnEllipseConstraintDto(
        id: 'endOnEllipse',
        pointId: 'end',
        ellipseId: 'arc2',
        centerPointId: 'center',
        majorPointId: 'major',
        minorPointId: 'minor',
      ),
    ];

    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: (id) => _lineEndpoints(lines, id),
      anchorPointIds: const {},
    );

    expect(result.converged, isTrue, reason: 'resultCode=${result.resultCode}');
    for (final id in points.keys) {
      final (sx, sy) = points[id]!;
      final (rx, ry) = result.solvedPoints[id]!;
      expect(rx, closeTo(sx, 1e-6), reason: '$id.x drifted');
      expect(ry, closeTo(sy, 1e-6), reason: '$id.y drifted');
    }
  });

  group(
      'Polygon soft-drag validation (follow-up to the Circle soft-drag spike - validating the '
      'mechanism against a Polygon\'s own real constraint graph before rerouting its confirmed-'
      'dimension drag off the closed-form path the way CircleDragMode already was): the CURRENT '
      'production graph from Sketch.add_polygon (backend/app/sketch/models.py) - a confirmed '
      'DistanceConstraint(center, v0, radius) + EqualRadiusConstraint per other vertex + '
      'AngleConstraint(radial[i-1], radial[i], 360/sides) per adjacent radial-line pair - NOT the '
      'older edge-to-edge EqualLength/Angle design the "residual-verified convergence" test above '
      'exercises deliberately for its own, different reason (see that test\'s own doc comment)', () {
    const sides = 5;
    const radius = 10.0;
    final lines = <String, (String, String)>{
      for (var i = 0; i < sides; i++) 'radial$i': ('center', 'v$i'),
    };
    Map<String, (double, double)> regularPentagon() {
      final points = <String, (double, double)>{'center': (0.0, 0.0)};
      for (var i = 0; i < sides; i++) {
        final angle = 2 * math.pi * i / sides;
        points['v$i'] = (radius * math.cos(angle), radius * math.sin(angle));
      }
      return points;
    }

    List<ConstraintDto> polygonConstraints() => [
          const DistanceConstraintDto(id: 'radius', pointAId: 'center', pointBId: 'v0', distance: radius),
          for (var i = 1; i < sides; i++)
            EqualRadiusConstraintDto(
                id: 'er$i', center1PointId: 'center', radius1PointId: 'v0', center2PointId: 'center', radius2PointId: 'v$i'),
          for (var i = 1; i < sides; i++)
            AngleConstraintDto(id: 'ang$i', line1Id: 'radial${i - 1}', line2Id: 'radial$i', angleDegrees: 360.0 / sides),
        ];

    void expectIntact(Map<String, (double, double)> solved) {
      final (cx, cy) = solved['center']!;
      for (var i = 0; i < sides; i++) {
        final (vx, vy) = solved['v$i']!;
        final r = math.sqrt(math.pow(vx - cx, 2) + math.pow(vy - cy, 2));
        expect(r, closeTo(radius, 1e-4), reason: 'v$i radius drifted - the confirmed dimension must be exact');
      }
      for (var i = 1; i < sides; i++) {
        final (v0x, v0y) = solved['v${i - 1}']!;
        final (v1x, v1y) = solved['v$i']!;
        final a0 = math.atan2(v0y - cy, v0x - cx);
        final a1 = math.atan2(v1y - cy, v1x - cx);
        var delta = (a1 - a0) * 180 / math.pi;
        while (delta < 0) {
          delta += 360;
        }
        while (delta > 180) {
          delta -= 360;
        }
        expect(delta.abs(), closeTo(360.0 / sides, 1e-2), reason: 'central angle v${i - 1}->v$i drifted');
      }
    }

    test('free centre: dragging v0 translates the whole Polygon rather than resizing/distorting it', () {
      final points = regularPentagon();
      points['v0'] = (radius + 6.0, 4.0); // seeded straight at the drag target
      final result = solveSketchLocally(
        bindings: bindings,
        points: points,
        constraints: polygonConstraints(),
        lineEndpoints: (id) => _lineEndpoints(lines, id),
        anchorPointIds: {'v0'},
      );
      expect(result.converged, isTrue, reason: 'resultCode=${result.resultCode}');
      expectIntact(result.solvedPoints);
      final (v0x, v0y) = result.solvedPoints['v0']!;
      expect((v0x - (radius + 6.0)).abs() + (v0y - 4.0).abs(), lessThan(1.0),
          reason: 'the dragged vertex still tracks close to the drag target');
      final (cx, cy) = result.solvedPoints['center']!;
      expect(cx.abs() + cy.abs(), greaterThan(1.0),
          reason: 'unlike a hard pin, the free centre actually moves - "if unanchored, the shape moves"');
    });

    test('locked centre: dragging v0 rotates the whole Polygon (every vertex slides together) '
        'instead of resizing it or teleporting to an unrelated root', () {
      final points = regularPentagon();
      points['v0'] = (radius + 6.0, 4.0);
      final result = solveSketchLocally(
        bindings: bindings,
        points: points,
        constraints: polygonConstraints(),
        lineEndpoints: (id) => _lineEndpoints(lines, id),
        anchorPointIds: {'v0'},
        lockedPointIds: {'center'},
      );
      expect(result.converged, isTrue, reason: 'resultCode=${result.resultCode}');
      final (cx, cy) = result.solvedPoints['center']!;
      expect(cx, closeTo(0.0, 1e-9), reason: 'centre is locked - never moved by this solve');
      expect(cy, closeTo(0.0, 1e-9));
      expectIntact(result.solvedPoints);
      // Nearest point on the radius-10 circle around the locked centre to
      // the (16,4) drag target.
      final norm = math.sqrt(16.0 * 16.0 + 4.0 * 4.0);
      final (v0x, v0y) = result.solvedPoints['v0']!;
      // A looser tolerance than Circle's own single-equation locked-centre
      // case (1e-3) - Polygon's longer EqualRadius/Angle chain doesn't
      // converge quite as tightly to the ideal nearest-point formula, but
      // is still well within any real visual threshold.
      expect(v0x, closeTo(16.0 / norm * radius, 0.05));
      expect(v0y, closeTo(4.0 / norm * radius, 0.05));
    });

    test('centre and v0 both locked (zero remaining freedom): dragging a different vertex resists '
        'entirely rather than distorting the Polygon or snapping to a far-away root', () {
      // A small, realistic per-frame drag delta - not an arbitrary large
      // jump. Found empirically during this validation pass that a large
      // single-frame jump here can flip AngleConstraint's own pre-solve
      // supplement disambiguation (solver_builder.dart's own
      // _angleNeedsSupplement, which picks whichever of {72, 108} degrees
      // is closer to the *raw, pre-solve* measured angle) to the wrong
      // value entirely, before Newton ever runs - not a soft-drag defect,
      // but a real reason to keep drag deltas realistic in these fixtures.
      final points = regularPentagon();
      final (v2x, v2y) = points['v2']!;
      points['v2'] = (v2x + 0.5, v2y + 0.3);
      final result = solveSketchLocally(
        bindings: bindings,
        points: points,
        constraints: polygonConstraints(),
        lineEndpoints: (id) => _lineEndpoints(lines, id),
        anchorPointIds: {'v2'},
        lockedPointIds: {'center', 'v0'},
      );
      expect(result.converged, isTrue, reason: 'resultCode=${result.resultCode}');
      expectIntact(result.solvedPoints);
      final original = regularPentagon();
      final (ox, oy) = original['v2']!;
      final (rx, ry) = result.solvedPoints['v2']!;
      expect((rx - ox).abs() + (ry - oy).abs(), lessThan(1e-3),
          reason: 'zero DOF left - the drag target is ignored, v2 stays at its one valid position');
    });
  });

  group(
      'Slot soft-drag validation (follow-up to the Circle soft-drag spike): the full production '
      'graph from Sketch.add_slot (backend/app/sketch/models.py) - confirmed radius Distance + '
      'both arcs\' own end-radius EqualRadius ties + the 2 cross-arc EqualRadius ties + all 4 '
      'TangentConstraints + both ParallelConstraints (line1/line2 to the centreline) - the last 2 '
      'of the 4 Tangents and the 2 Parallels are all individually redundant/root-selecting, per '
      'that method\'s own doc comment, not load-bearing for determinacy on their own. Finding from '
      'this validation pass: this redundant, Tangent-heavy graph has a noticeably smaller Newton '
      'convergence basin than Circle\'s single-equation one - a small, realistic per-frame drag '
      'delta converges cleanly, but an unrealistically large single-frame jump (tried first, before '
      'settling on the deltas below) can fail to converge outright (resultCode 1). Not a new risk '
      'soft-drag introduces - solveSketchLocally\'s own retry-without-anchor, then '
      '_trySolveDuringDragLocally\'s blow-up/residual guards, then the network fallback already '
      'exist precisely to catch a rare non-convergent local solve - but worth a real per-frame delta '
      'in these fixtures rather than an arbitrary one, so a passing test actually reflects what a '
      'real drag looks like.', () {
    const c1 = (0.0, 0.0), c2 = (20.0, 0.0), radius = 5.0;
    Map<String, (double, double)> intactSlot() => {
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
      'centerline': ('c1p', 'c2p'),
    };
    List<ConstraintDto> slotConstraints() => const [
          DistanceConstraintDto(id: 'radius', pointAId: 'c1p', pointBId: 'a', distance: radius),
          EqualRadiusConstraintDto(id: 'er_arc1', center1PointId: 'c1p', radius1PointId: 'a', center2PointId: 'c1p', radius2PointId: 'b'),
          EqualRadiusConstraintDto(id: 'er_arc2', center1PointId: 'c2p', radius1PointId: 'c', center2PointId: 'c2p', radius2PointId: 'd'),
          EqualRadiusConstraintDto(id: 'er_cross1', center1PointId: 'c1p', radius1PointId: 'a', center2PointId: 'c2p', radius2PointId: 'c'),
          EqualRadiusConstraintDto(id: 'er_cross2', center1PointId: 'c1p', radius1PointId: 'a', center2PointId: 'c2p', radius2PointId: 'd'),
          TangentConstraintDto(id: 't1', centerPointId: 'c1p', radiusPointId: 'a', lineId: 'line1'),
          TangentConstraintDto(id: 't2', centerPointId: 'c1p', radiusPointId: 'a', lineId: 'line2'),
          TangentConstraintDto(id: 't3', centerPointId: 'c2p', radiusPointId: 'c', lineId: 'line1'),
          TangentConstraintDto(id: 't4', centerPointId: 'c2p', radiusPointId: 'c', lineId: 'line2'),
          ParallelConstraintDto(id: 'par1', line1Id: 'line1', line2Id: 'centerline'),
          ParallelConstraintDto(id: 'par2', line1Id: 'line2', line2Id: 'centerline'),
        ];

    void expectRadiiHold(Map<String, (double, double)> solved) {
      double r(String centerId, String radiusId) {
        final (cx, cy) = solved[centerId]!;
        final (rx, ry) = solved[radiusId]!;
        return math.sqrt(math.pow(rx - cx, 2) + math.pow(ry - cy, 2));
      }

      for (final pair in [('c1p', 'a'), ('c1p', 'b'), ('c2p', 'c'), ('c2p', 'd')]) {
        expect(r(pair.$1, pair.$2), closeTo(radius, 1e-3), reason: '${pair.$2}\'s own radius drifted');
      }
    }

    test('both centres locked: dragging a is heavily constrained by Tangent+Parallel against the '
        'fixed centreline, converges without a wrong-side/self-intersecting root', () {
      final points = intactSlot();
      points['a'] = (c1.$1 + 0.5, c1.$2 + radius + 0.3); // a small, realistic per-frame drag nudge
      final result = solveSketchLocally(
        bindings: bindings,
        points: points,
        constraints: slotConstraints(),
        lineEndpoints: (id) => _lineEndpoints(lines, id),
        anchorPointIds: {'a'},
        lockedPointIds: {'c1p', 'c2p'},
      );
      expect(result.converged, isTrue, reason: 'resultCode=${result.resultCode}');
      final (c1x, c1y) = result.solvedPoints['c1p']!;
      expect(c1x, closeTo(c1.$1, 1e-9));
      expect(c1y, closeTo(c1.$2, 1e-9));
      final (c2x, c2y) = result.solvedPoints['c2p']!;
      expect(c2x, closeTo(c2.$1, 1e-9));
      expect(c2y, closeTo(c2.$2, 1e-9));
      expectRadiiHold(result.solvedPoints);
      // Both centres fixed leaves genuinely zero remaining freedom (see the
      // comment at this group's own top) - a's drag target is ignored, it
      // stays at its one valid position.
      final (ax, ay) = result.solvedPoints['a']!;
      expect(ax, closeTo(c1.$1, 1e-2));
      expect(ay, closeTo(c1.$2 + radius, 1e-2));
    });

    test(
        'KNOWN LIMITATION, not yet safe for a production reroute: with neither centre locked, the '
        'dragged corner\'s own soft-drag bias is nowhere near strong enough to keep the solve near '
        'the nearby, intuitive solution - Slot\'s own constraint graph never pins the centre-to-centre distance '
        'at all (see this group\'s own doc comment - nothing in Sketch.add_slot constrains it), so '
        'the redundant Tangent/Parallel system has a genuinely under-conditioned direction even '
        'though py-slvs itself reports dof 0 for it (the exact quirk solveSketchLocally\'s own '
        '"provisional-DOF floor" already works around for an *unconfirmed* radius - this is the '
        'same underlying quirk, just with a confirmed one, which that floor does not cover). Even '
        'soft-dragging the *near* centre too (not just the corner) and hard-locking only the far '
        'one - tried directly below, before settling on documenting this as a limitation rather '
        'than a fix - still jumped to a wildly different (if still individually valid: radius and '
        'parallelism both still hold exactly) configuration for a tiny nudge. The one combination '
        'that reliably behaves (see the test above) is BOTH centres locked - so a Slot corner drag '
        'should stay on the closed-form path, or lock both centres outright, rather than rerouting '
        'to the general soft-drag path the way Circle\'s confirmed-dimension case could.', () {
      final points = intactSlot();
      points['a'] = (c1.$1 + 0.5, c1.$2 + radius + 0.3); // a small, realistic per-frame drag nudge
      final result = solveSketchLocally(
        bindings: bindings,
        points: points,
        constraints: slotConstraints(),
        lineEndpoints: (id) => _lineEndpoints(lines, id),
        anchorPointIds: {'a'},
      );
      // Still a genuinely valid Slot (this isn't the false-positive-
      // convergence class of bug the CurveTangentConstraint investigation
      // found earlier this session - see solver.py's own doc comment on
      // _REDUNDANCY_SAFE_CONSTRAINT_TYPES) - every radius and parallelism
      // relationship really is satisfied exactly, just at an unexpected,
      // far-away position nothing here asked for.
      expect(result.converged, isTrue, reason: 'resultCode=${result.resultCode}');
      expectRadiiHold(result.solvedPoints);
      final (c1x, c1y) = result.solvedPoints['c1p']!;
      final (line1sx, line1sy) = result.solvedPoints['b']!;
      final (line1ex, line1ey) = result.solvedPoints['c']!;
      final (c2x, c2y) = result.solvedPoints['c2p']!;
      final centerlineDir = (c2x - c1x, c2y - c1y);
      final line1Dir = (line1ex - line1sx, line1ey - line1sy);
      final cross = centerlineDir.$1 * line1Dir.$2 - centerlineDir.$2 * line1Dir.$1;
      expect(cross.abs(), lessThan(1e-3), reason: 'line1 really is still parallel to the centreline');
    });
  });
}
