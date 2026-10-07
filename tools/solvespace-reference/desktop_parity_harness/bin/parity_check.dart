// Milestone B desktop parity harness (sketcher restructure plan Phase 1).
//
// Loads the host-built didsa_slvs_ffi shared library and reproduces the
// spike's two on-device parity cases (docs/sketcher-spikes-ffi-and-plane-
// sketch.md, Track 1 verdict) against real backend ground truth:
//   1. Two points + one distance constraint (the "simple case").
//   2. A Slot's 2-Arc/2-Line/Tangent+EqualRadius construction (the "hard
//      case" - the most structurally fragile shape in the system, and the
//      one that actually exercises redundant-constraint handling).
//
// Run with: dart run bin/parity_check.dart <path-to-didsa_slvs_ffi.dll>
//
// Both cases replicate backend/app/sketch/solver.py's _solve_sketch_once
// exactly: a fixed-group workplane (origin + normal), Points/constraints in
// the solve group. Expected values were captured from real runs of the
// backend's own solve_sketch()/py-slvs directly (not argued for) - see each
// case's own comment for the exact source. This harness's job is confirming
// the FFI shim reproduces that, not re-deriving it.
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

const int fixedGroup = 1;
const int solveGroup = 2;

typedef CreateNative = ffi.Pointer<ffi.Void> Function();
typedef CreateDart = ffi.Pointer<ffi.Void> Function();

typedef DestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef DestroyDart = void Function(ffi.Pointer<ffi.Void>);

typedef AddParamVNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Double, ffi.Uint32);
typedef AddParamVDart = int Function(ffi.Pointer<ffi.Void>, double, int);

typedef AddPoint3dVNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Double, ffi.Double, ffi.Uint32);
typedef AddPoint3dVDart = int Function(ffi.Pointer<ffi.Void>, double, double, double, int);

typedef AddNormal3dVNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Double, ffi.Double, ffi.Double, ffi.Uint32);
typedef AddNormal3dVDart = int Function(ffi.Pointer<ffi.Void>, double, double, double, double, int);

typedef AddWorkplaneNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddWorkplaneDart = int Function(ffi.Pointer<ffi.Void>, int, int, int);

typedef AddPoint2dNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPoint2dDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddLineSegmentNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddLineSegmentDart = int Function(ffi.Pointer<ffi.Void>, int, int, int);

typedef AddPointsDistanceNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPointsDistanceDart = int Function(ffi.Pointer<ffi.Void>, double, int, int, int, int);

typedef AddEqualLengthNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddEqualLengthDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddEqualLengthPointLineDistanceNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddEqualLengthPointLineDistanceDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int, int);

typedef SolveNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Int32);
typedef SolveDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef GetDofNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef GetDofDart = int Function(ffi.Pointer<ffi.Void>);

typedef GetEntityParamNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Int32);
typedef GetEntityParamDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef GetParamValueNative = ffi.Double Function(ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef GetParamValueDart = double Function(ffi.Pointer<ffi.Void>, int);

class SlvsBindings {
  final CreateDart create;
  final DestroyDart destroy;
  final AddParamVDart addParamV;
  final AddPoint3dVDart addPoint3dV;
  final AddNormal3dVDart addNormal3dV;
  final AddWorkplaneDart addWorkplane;
  final AddPoint2dDart addPoint2d;
  final AddLineSegmentDart addLineSegment;
  final AddPointsDistanceDart addPointsDistance;
  final AddEqualLengthDart addEqualLength;
  final AddEqualLengthPointLineDistanceDart addEqualLengthPointLineDistance;
  final SolveDart solve;
  final GetDofDart getDof;
  final GetEntityParamDart getEntityParam;
  final GetParamValueDart getParamValue;

  SlvsBindings(ffi.DynamicLibrary lib)
      : create = lib.lookupFunction<CreateNative, CreateDart>('slvs_system_create'),
        destroy = lib.lookupFunction<DestroyNative, DestroyDart>('slvs_system_destroy'),
        addParamV = lib.lookupFunction<AddParamVNative, AddParamVDart>('slvs_add_param_v'),
        addPoint3dV = lib.lookupFunction<AddPoint3dVNative, AddPoint3dVDart>('slvs_add_point3d_v'),
        addNormal3dV = lib.lookupFunction<AddNormal3dVNative, AddNormal3dVDart>('slvs_add_normal3d_v'),
        addWorkplane = lib.lookupFunction<AddWorkplaneNative, AddWorkplaneDart>('slvs_add_workplane'),
        addPoint2d = lib.lookupFunction<AddPoint2dNative, AddPoint2dDart>('slvs_add_point2d'),
        addLineSegment = lib.lookupFunction<AddLineSegmentNative, AddLineSegmentDart>('slvs_add_line_segment'),
        addPointsDistance =
            lib.lookupFunction<AddPointsDistanceNative, AddPointsDistanceDart>('slvs_add_points_distance'),
        addEqualLength = lib.lookupFunction<AddEqualLengthNative, AddEqualLengthDart>('slvs_add_equal_length'),
        addEqualLengthPointLineDistance = lib.lookupFunction<AddEqualLengthPointLineDistanceNative,
            AddEqualLengthPointLineDistanceDart>('slvs_add_equal_length_point_line_distance'),
        solve = lib.lookupFunction<SolveNative, SolveDart>('slvs_solve'),
        getDof = lib.lookupFunction<GetDofNative, GetDofDart>('slvs_get_dof'),
        getEntityParam =
            lib.lookupFunction<GetEntityParamNative, GetEntityParamDart>('slvs_get_entity_param'),
        getParamValue = lib.lookupFunction<GetParamValueNative, GetParamValueDart>('slvs_get_param_value');

  /// Standard fixed-group workplane every case below starts from -
  /// identity origin/normal, exactly matching solver.py's
  /// _solve_sketch_once (the workplane's own orientation is display-only,
  /// irrelevant to the 2D solve).
  int addWorkplaneFixed(ffi.Pointer<ffi.Void> sys) {
    final origin = addPoint3dV(sys, 0, 0, 0, fixedGroup);
    final normal = addNormal3dV(sys, 1, 0, 0, 0, fixedGroup);
    return addWorkplane(sys, origin, normal, fixedGroup);
  }

  int addSolvePoint(ffi.Pointer<ffi.Void> sys, int workplane, double x, double y) {
    final pu = addParamV(sys, x, solveGroup);
    final pv = addParamV(sys, y, solveGroup);
    return addPoint2d(sys, workplane, pu, pv, solveGroup);
  }

  (double, double) readPoint(ffi.Pointer<ffi.Void> sys, int point) {
    final x = getParamValue(sys, getEntityParam(sys, point, 0));
    final y = getParamValue(sys, getEntityParam(sys, point, 1));
    return (x, y);
  }
}

int _failures = 0;

void check(bool cond, String label) {
  if (!cond) {
    _failures++;
    stderr.writeln('FAIL: $label');
  }
}

/// Backend ground truth (real solve_sketch call, not argued for) - see
/// backend/tests/test_stage2b_solver_integration.py's
/// test_solve_over_the_api_updates_points_and_reports_convergence, which
/// exercises the identical sketch over the real API: converged (result_code
/// 0), dof 3 (2 free Points x2 coords = 4, minus 1 equation from the one
/// Distance constraint = 3), and the two Points end up exactly 50.0 apart.
void runSimpleCase(SlvsBindings b) {
  final sys = b.create();
  try {
    final workplane = b.addWorkplaneFixed(sys);
    final pointA = b.addSolvePoint(sys, workplane, 0.0, 0.0);
    final pointB = b.addSolvePoint(sys, workplane, 1.0, 0.0);
    b.addPointsDistance(sys, 50.0, pointA, pointB, workplane, solveGroup);

    final resultCode = b.solve(sys, solveGroup, 1);
    final dof = b.getDof(sys);
    final (ax, ay) = b.readPoint(sys, pointA);
    final (bx, by) = b.readPoint(sys, pointB);
    final distance = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));

    stdout.writeln('[simple] result_code=$resultCode dof=$dof distance=$distance');
    check(resultCode == 0, 'simple case: expected result_code == 0, got $resultCode');
    check(dof == 3, 'simple case: expected dof == 3, got $dof');
    check((distance - 50.0).abs() < 1e-6, 'simple case: expected distance ~= 50.0, got $distance');
  } finally {
    b.destroy(sys);
  }
}

/// Backend ground truth captured from a real, direct py-slvs run against
/// this exact construction (mirrors _build_slot in
/// backend/tests/test_bugfix_provisional_size_constraints.py, minus arc1's
/// own radius DistanceConstraint - that one is `provisional`, and
/// solve_sketch's loop skips provisional DistanceConstraints entirely
/// before they ever reach the solver, so it's correctly absent here too):
/// result_code 5 (REDUNDANT_OK - the same code the spike's Track 1 verdict
/// found for this fork, upstream calls this 4), raw dof 0, and every rim
/// Point stays exactly at its seeded position (the construction is already
/// exactly tangent, so nothing needs to move).
void runSlotCase(SlvsBindings b) {
  final sys = b.create();
  try {
    final workplane = b.addWorkplaneFixed(sys);

    const c1 = (0.0, 0.0);
    const c2 = (20.0, 0.0);
    const radius = 5.0;
    final dx = c2.$1 - c1.$1, dy = c2.$2 - c1.$2;
    final length = math.sqrt(dx * dx + dy * dy);
    final dirx = dx / length, diry = dy / length;
    final nx = -diry, ny = dirx;

    final c1p = b.addSolvePoint(sys, workplane, c1.$1, c1.$2);
    final c2p = b.addSolvePoint(sys, workplane, c2.$1, c2.$2);
    final ap = b.addSolvePoint(sys, workplane, c1.$1 + nx * radius, c1.$2 + ny * radius);
    final bp = b.addSolvePoint(sys, workplane, c1.$1 - nx * radius, c1.$2 - ny * radius);
    final cp = b.addSolvePoint(sys, workplane, c2.$1 - nx * radius, c2.$2 - ny * radius);
    final dp = b.addSolvePoint(sys, workplane, c2.$1 + nx * radius, c2.$2 + ny * radius);

    // EqualRadius: arc1 (center c1p, radius point a - an Arc's radius point
    // always defaults to its own start_point_id, see models.py's
    // _center_radius_point_ids) tied to arc2's two rim points c and d.
    final lineC1A = b.addLineSegment(sys, c1p, ap, solveGroup);
    final lineC2C = b.addLineSegment(sys, c2p, cp, solveGroup);
    final lineC2D = b.addLineSegment(sys, c2p, dp, solveGroup);
    b.addEqualLength(sys, lineC1A, lineC2C, workplane, solveGroup);
    b.addEqualLength(sys, lineC1A, lineC2D, workplane, solveGroup);

    // Tangent: line1 = b->c, line2 = d->a (the Slot's two straight sides).
    // Each Arc's radius point is its own fixed start_point_id (a for arc1,
    // c for arc2) regardless of which line it's tied to - either rim point
    // works, both are equidistant from center by construction.
    final line1 = b.addLineSegment(sys, bp, cp, solveGroup);
    final line2 = b.addLineSegment(sys, dp, ap, solveGroup);
    void tangent(int center, int radiusPoint, int tangentLine) {
      final radiusLine = b.addLineSegment(sys, center, radiusPoint, solveGroup);
      b.addEqualLengthPointLineDistance(sys, center, radiusLine, tangentLine, workplane, solveGroup);
    }

    tangent(c1p, ap, line1);
    tangent(c1p, ap, line2);
    tangent(c2p, cp, line1);
    tangent(c2p, cp, line2);

    final resultCode = b.solve(sys, solveGroup, 1);
    final dof = b.getDof(sys);
    stdout.writeln('[slot] result_code=$resultCode dof=$dof');
    check(resultCode == 5, 'slot case: expected result_code == 5 (REDUNDANT_OK), got $resultCode');
    check(dof == 0, 'slot case: expected raw dof == 0, got $dof');

    final expected = {
      'c1p': (c1p, 0.0, 0.0),
      'ap': (ap, 0.0, 5.0),
      'bp': (bp, 0.0, -5.0),
      'c2p': (c2p, 20.0, 0.0),
      'cp': (cp, 20.0, -5.0),
      'dp': (dp, 20.0, 5.0),
    };
    for (final entry in expected.entries) {
      final (handle, expectedX, expectedY) = entry.value;
      final (x, y) = b.readPoint(sys, handle);
      stdout.writeln('[slot] ${entry.key}=($x,$y)');
      check((x - expectedX).abs() < 1e-6 && (y - expectedY).abs() < 1e-6,
          'slot case: ${entry.key} expected ~=($expectedX,$expectedY), got ($x,$y)');
    }
  } finally {
    b.destroy(sys);
  }
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run bin/parity_check.dart <path-to-didsa_slvs_ffi shared library>');
    exit(2);
  }
  final lib = ffi.DynamicLibrary.open(args[0]);
  final bindings = SlvsBindings(lib);

  runSimpleCase(bindings);
  runSlotCase(bindings);

  if (_failures == 0) {
    stdout.writeln('PASS: both parity cases match backend ground truth');
  } else {
    stderr.writeln('$_failures check(s) failed');
    exit(1);
  }
}
