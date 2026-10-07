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
import 'support/slvs_reference/slvs_bindings.dart';
import 'support/slvs_reference/solvespace_clamp.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final bool _bench = Platform.environment['DIDSA_SKETCH_BENCH'] == '1';

String? _hostLibrary() {
  for (final relative in [
    '../tools/solvespace-reference/build-host/libdidsa_slvs_ffi.dll',
    '../tools/solvespace-reference/build-host/libdidsa_slvs_ffi.so',
    '../tools/solvespace-reference/build-host/libdidsa_slvs_ffi.dylib',
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
  final controller = SketchController(api: SketchApiClient(httpClient: client), dragClampOverride: solveSpaceDragClamp(bindings));
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
  final double maxTipError;
  final double meanHandStep;
  _Result(this.label, this.stats, this.maxStepRatio, this.maxFollowerJerk, this.meanTipError, this.finalPoints,
      [this.maxTipError = 0, this.meanHandStep = 0]);
}

/// Minimum-jerk interpolation 0..1.
double _mj(double t) => t * t * t * (10 - 15 * t + 6 * t * t);

/// An arm of [links] segments of length 5 anchored at the origin, every segment a distance dimension. The hand (min-jerk
/// segments, [frames] frames in all) takes the tip in from the stretched start to 0.7 reach, a quarter turn about the origin,
/// then out past the reach (the wall) and back. Ground truth is analytic: the tip should be the cursor clamped to the reach disc.
Future<_Result> _arm(int links, {required bool solveSpace, int frames = 120}) async {
  final c = await _controller(solveSpace: solveSpace);
  final ids = <String>['origin-1'];
  // A gentle curl (3 degrees more per link) rather than a perfectly straight arm: a straight one is a bifurcation (the tip
  // cannot move inwards at first order), which both engines handle badly and which says nothing about normal dragging.
  var px = 0.0, py = 0.0;
  for (var i = 1; i <= links; i++) {
    final a = i * 3 * math.pi / 180;
    px += 5 * math.cos(a);
    py += 5 * math.sin(a);
    final id = 'p$i';
    c.points[id] = SketchPointView(id: id, x: px, y: py);
    ids.add(id);
  }
  for (var i = 1; i <= links; i++) {
    c.lines['l$i'] = SketchLineView(id: 'l$i', startPointId: ids[i - 1], endPointId: ids[i]);
    c.constraints['d$i'] = DistanceConstraintDto(id: 'd$i', pointAId: ids[i - 1], pointBId: ids[i], distance: 5);
  }
  final tip = ids.last;
  final reach = 5.0 * links;
  final startTip = (px, py);
  final seg = frames ~/ 3;
  final path = <(double, double)>[];
  for (var f = 1; f <= frames; f++) {
    if (f <= seg) {
      final k = _mj(f / seg);
      path.add((startTip.$1 + (0.7 * reach - startTip.$1) * k, startTip.$2 * (1 - k)));
    } else if (f <= 2 * seg) {
      final a = _mj((f - seg) / seg) * math.pi / 2;
      path.add((0.7 * reach * math.cos(a), 0.7 * reach * math.sin(a)));
    } else {
      final r = reach * (0.7 + 0.6 * math.sin(_mj((f - 2 * seg) / (frames - 2 * seg)) * math.pi));
      path.add((0, r));
    }
  }
  (double, double) ideal((double, double) cur) {
    final r = math.sqrt(cur.$1 * cur.$1 + cur.$2 * cur.$2);
    return r <= reach ? cur : (cur.$1 * reach / r, cur.$2 * reach / r);
  }

  c.cursorX = startTip.$1;
  c.cursorY = startTip.$2;
  expect(c.beginPointDrag(tip), isTrue);
  c.dragStats.reset();
  var maxRatio = 0.0, maxJerk = 0.0, errSum = 0.0, errMax = 0.0, handSum = 0.0;
  var prev = {for (final e in c.points.entries) e.key: (e.value.x, e.value.y)};
  Map<String, double>? prevStep;
  var prevIdeal = startTip;
  for (final cursor in path) {
    await c.updatePointDrag(cursor.$1, cursor.$2);
    final now = {for (final e in c.points.entries) e.key: (e.value.x, e.value.y)};
    final step = <String, double>{
      for (final e in now.entries)
        e.key: math.sqrt(math.pow(e.value.$1 - prev[e.key]!.$1, 2) + math.pow(e.value.$2 - prev[e.key]!.$2, 2)),
    };
    final want = ideal(cursor);
    final idealStep = math.sqrt(math.pow(want.$1 - prevIdeal.$1, 2) + math.pow(want.$2 - prevIdeal.$2, 2));
    handSum += idealStep;
    if (idealStep > 0.05 * reach / frames) maxRatio = math.max(maxRatio, step[tip]! / idealStep);
    if (prevStep != null) {
      for (final id in ids) {
        if (id == tip) continue;
        maxJerk = math.max(maxJerk, (step[id]! - prevStep[id]!).abs());
      }
    }
    final p = now[tip]!;
    final err = math.sqrt(math.pow(p.$1 - want.$1, 2) + math.pow(p.$2 - want.$2, 2));
    errSum += err;
    // ignore: avoid_print
    if (Platform.environment['DIDSA_ARM_TRACE'] == '$links') print('${solveSpace ? 'SS' : 'PJ'} cursor=(${cursor.$1.toStringAsFixed(1)},${cursor.$2.toStringAsFixed(1)}) tip=(${p.$1.toStringAsFixed(2)},${p.$2.toStringAsFixed(2)}) err=${err.toStringAsFixed(3)} iters=${c.dragStats.lastIterations}');
    errMax = math.max(errMax, err);
    prev = now;
    prevStep = step;
    prevIdeal = want;
  }
  return _Result('arm $links links (${links + 1} pts) ${solveSpace ? 'SolveSpace' : 'projector '}', c.dragStats.toString(), maxRatio,
      maxJerk, errSum / frames, prev, errMax, handSum / frames);
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
    final result = await _arm(6, solveSpace: false, frames: 60);
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
        for (final solveSpace in engines) {
          final r = await _arm(links, solveSpace: solveSpace);
          out.writeln('${r.label}: ${r.stats}\n    stepRatio(max)=${r.maxStepRatio.toStringAsFixed(2)} '
              'followerJerk(max)=${r.maxFollowerJerk.toStringAsFixed(3)} tipErr(mean/max)=${r.meanTipError.toStringAsFixed(3)}/'
              '${r.maxTipError.toStringAsFixed(3)} handStep(mean)=${r.meanHandStep.toStringAsFixed(3)}');
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
