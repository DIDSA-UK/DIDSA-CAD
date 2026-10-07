// Drag-clamp measurements for docs/sketch-drag-projector.md (S10): per-frame cost vs sketch size, rejected frames, and the
// "feel" metrics of docs/constrained-drag-smoothness-study.md (step ratio of the grabbed point, jerk of everything else),
// for the bundled projector and - where the host SolveSpace build exists - the real solver as the reference.
//
//   DIDSA_SKETCH_BENCH=1 flutter test test/sketch_drag_bench_test.dart        # prints the tables
//
// Without the variable only a small smoke case runs (it asserts the projector path is taken and accepts every frame).
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/local_solver/slvs_bindings.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final bool _bench = Platform.environment['DIDSA_SKETCH_BENCH'] == '1';

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

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Just enough backend to open a sketch; every other call 404s (the drag path under test makes none while it is clamped).
Future<SketchController> _controller({required bool solveSpace}) async {
  final client = MockClient((request) async {
    if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
      return _json({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}, 201);
    }
    return http.Response('not found', 404);
  });
  SlvsNativeBindings? bindings;
  if (solveSpace) bindings = SlvsNativeBindings(ffi.DynamicLibrary.open(_hostLibrary()!));
  final controller = SketchController(api: SketchApiClient(httpClient: client), localSolverBindings: bindings);
  await controller.ensureSketch();
  controller.points['origin-1'] = const SketchPointView(id: 'origin-1', x: 0, y: 0);
  controller.debugSetBackendDof(5);
  return controller;
}

class _Result {
  final String label;
  final String stats;
  final double maxStepRatio;
  final double maxFollowerJerk;
  final double meanTipError;
  final Map<String, (double, double)> finalPoints;
  _Result(this.label, this.stats, this.maxStepRatio, this.maxFollowerJerk, this.meanTipError, this.finalPoints);
}

/// An arm of [links] segments of length 5 anchored at the origin, every segment a distance dimension. The tip is dragged
/// along a circle of radius `0.7 reach`, then out and back past the reach (the wall).
Future<_Result> _arm(int links, {required bool solveSpace, int frames = 90}) async {
  final c = await _controller(solveSpace: solveSpace);
  final ids = <String>['origin-1'];
  for (var i = 1; i <= links; i++) {
    final id = 'p$i';
    c.points[id] = SketchPointView(id: id, x: 5.0 * i, y: 0);
    ids.add(id);
  }
  for (var i = 1; i <= links; i++) {
    c.lines['l$i'] = SketchLineView(id: 'l$i', startPointId: ids[i - 1], endPointId: ids[i]);
    c.constraints['d$i'] = DistanceConstraintDto(id: 'd$i', pointAId: ids[i - 1], pointBId: ids[i], distance: 5);
  }
  final tip = ids.last;
  final reach = 5.0 * links;
  final path = <(double, double)>[];
  for (var f = 0; f < frames; f++) {
    final t = f / (frames - 1);
    // circle at 0.7 reach for the first half, then radial out to 1.3 reach and back
    if (t < 0.5) {
      final a = t * 2 * 2 * math.pi * 0.25;
      path.add((0.7 * reach * math.cos(a), 0.7 * reach * math.sin(a)));
    } else {
      final u = (t - 0.5) * 2;
      final r = reach * (0.7 + 0.6 * math.sin(u * math.pi));
      final a = math.pi / 2;
      path.add((r * math.cos(a), r * math.sin(a)));
    }
  }
  c.cursorX = 5.0 * links;
  c.cursorY = 0;
  expect(c.beginPointDrag(tip), isTrue);
  c.dragStats.reset();
  final shown = <List<(double, double)>>[];
  var maxRatio = 0.0, maxJerk = 0.0, tipError = 0.0;
  Map<String, (double, double)> prev = {for (final e in c.points.entries) e.key: (e.value.x, e.value.y)};
  Map<String, double>? prevStep;
  (double, double) prevCursor = (5.0 * links, 0);
  for (final (cx, cy) in path) {
    await c.updatePointDrag(cx, cy);
    final now = {for (final e in c.points.entries) e.key: (e.value.x, e.value.y)};
    final step = <String, double>{
      for (final e in now.entries) e.key: math.sqrt(math.pow(e.value.$1 - prev[e.key]!.$1, 2) + math.pow(e.value.$2 - prev[e.key]!.$2, 2)),
    };
    final hand = math.sqrt(math.pow(cx - prevCursor.$1, 2) + math.pow(cy - prevCursor.$2, 2));
    if (hand > 1e-9) maxRatio = math.max(maxRatio, step[tip]! / hand);
    if (prevStep != null) {
      for (final id in ids) {
        if (id == tip) continue;
        maxJerk = math.max(maxJerk, (step[id]! - prevStep[id]!).abs());
      }
    }
    final p = now[tip]!;
    tipError += math.sqrt(math.pow(p.$1 - cx, 2) + math.pow(p.$2 - cy, 2));
    prev = now;
    prevStep = step;
    prevCursor = (cx, cy);
    shown.add([p]);
  }
  final stats = c.dragStats.toString();
  return _Result('arm $links links (${links + 1} pts) ${solveSpace ? 'SolveSpace' : 'projector '}', stats, maxRatio, maxJerk,
      tipError / frames, prev);
}

/// [count] unconnected rectangles (4 points, H/V on the sides, width and height dimensions) plus the dragged one - what
/// the old solver paid for every frame whatever it dragged.
Future<_Result> _grid(int count, {required bool solveSpace, int frames = 60}) async {
  final c = await _controller(solveSpace: solveSpace);
  for (var r = 0; r < count; r++) {
    final ox = 30.0 * (r % 10) + 20, oy = 30.0 * (r ~/ 10) + 20;
    final p = [for (var i = 0; i < 4; i++) 'r${r}p$i'];
    final xy = [(ox, oy), (ox + 10, oy), (ox + 10, oy + 6), (ox, oy + 6)];
    for (var i = 0; i < 4; i++) {
      c.points[p[i]] = SketchPointView(id: p[i], x: xy[i].$1, y: xy[i].$2);
    }
    for (var i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4];
      c.lines['r${r}l$i'] = SketchLineView(id: 'r${r}l$i', startPointId: a, endPointId: b);
      c.constraints['r${r}c$i'] = i.isEven
          ? HorizontalConstraintDto(id: 'r${r}c$i', pointAId: a, pointBId: b, lineId: 'r${r}l$i')
          : VerticalConstraintDto(id: 'r${r}c$i', pointAId: a, pointBId: b, lineId: 'r${r}l$i');
    }
    c.constraints['r${r}w'] = DistanceConstraintDto(id: 'r${r}w', pointAId: p[0], pointBId: p[1], distance: 10, orientation: 'horizontal');
  }
  final grabbed = 'r0p2';
  final start = c.points[grabbed]!;
  c.cursorX = start.x;
  c.cursorY = start.y;
  expect(c.beginPointDrag(grabbed), isTrue);
  c.dragStats.reset();
  for (var f = 0; f < frames; f++) {
    final a = f / frames * 2 * math.pi;
    await c.updatePointDrag(start.x + 6 * math.sin(a), start.y + 6 * (1 - math.cos(a)));
  }
  return _Result('grid $count rects (${count * 4 + 1} pts) ${solveSpace ? 'SolveSpace' : 'projector '}', c.dragStats.toString(), 0, 0, 0,
      {for (final e in c.points.entries) e.key: (e.value.x, e.value.y)});
}

void main() {
  test('smoke: a 6-link arm dragged through the controller is clamped by the projector on every frame', () async {
    final result = await _arm(6, solveSpace: false, frames: 30);
    // frames that leave the reach may be rejected by the projector only if it fails to converge; none should.
    expect(result.stats, contains('rejected=0'));
    expect(result.stats, contains('unsupported=0'));
  });

  group('bench', () {
    if (!_bench) {
      test('bench (set DIDSA_SKETCH_BENCH=1)', () {}, skip: true);
      return;
    }
    final haveSolveSpace = _hostLibrary() != null;
    final engines = [false, if (haveSolveSpace) true];

    test('arm: cost vs size, rejects, feel', () async {
      final out = StringBuffer('\n== arm (tip dragged on a circle then out past the reach and back) ==\n');
      for (final links in [5, 20, 50, 100, 200]) {
        _Result? ref;
        for (final solveSpace in engines) {
          final r = await _arm(links, solveSpace: solveSpace);
          out.writeln('${r.label}: ${r.stats} | maxStepRatio=${r.maxStepRatio.toStringAsFixed(2)} '
              'maxFollowerJerk=${r.maxFollowerJerk.toStringAsFixed(3)} meanTipErr=${r.meanTipError.toStringAsFixed(3)}');
          if (solveSpace) ref = r;
          if (!solveSpace && ref != null) {}
        }
      }
      // ignore: avoid_print
      print(out);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('grid: unconnected rectangles', () async {
      final out = StringBuffer('\n== grid (drag one rectangle corner among N unconnected rectangles) ==\n');
      for (final count in [1, 10, 50, 100]) {
        for (final solveSpace in engines) {
          final r = await _grid(count, solveSpace: solveSpace);
          out.writeln('${r.label}: ${r.stats}');
        }
      }
      // ignore: avoid_print
      print(out);
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
