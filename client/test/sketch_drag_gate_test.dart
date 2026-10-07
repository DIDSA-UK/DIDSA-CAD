// The pre-grab gate asks the constraint Jacobian (analyseSketchMobility) whether a point can move at all, instead of the
// structural union-find count (dof_analysis.dart), which docs/constrained-drag-investigation.md B.4 found wrong both ways.
import 'dart:convert';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<SketchController> _controller() async {
  final client = MockClient((request) async {
    if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
      return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('not found', 404);
  });
  final c = SketchController(api: SketchApiClient(httpClient: client));
  await c.ensureSketch();
  c.points['origin-1'] = const SketchPointView(id: 'origin-1', x: 0, y: 0);
  c.debugSetBackendDof(1); // a solved sketch with a freedom left
  return c;
}

/// Rectangle on the origin, H/V sides and its width dimensioned (the height is the one freedom).
void _rectangle(SketchController c, {bool redundantParallel = false}) {
  const pts = {'a': (10.0, 0.0), 'b': (10.0, 6.0), 'c': (0.0, 6.0)};
  for (final e in pts.entries) {
    c.points[e.key] = SketchPointView(id: e.key, x: e.value.$1, y: e.value.$2);
  }
  final ends = {'l0': ('origin-1', 'a'), 'l1': ('a', 'b'), 'l2': ('b', 'c'), 'l3': ('c', 'origin-1')};
  for (final e in ends.entries) {
    c.lines[e.key] = SketchLineView(id: e.key, startPointId: e.value.$1, endPointId: e.value.$2);
  }
  c.constraints['h0'] = HorizontalConstraintDto(id: 'h0', lineId: 'l0', pointAId: 'origin-1', pointBId: 'a');
  c.constraints['v1'] = VerticalConstraintDto(id: 'v1', lineId: 'l1', pointAId: 'a', pointBId: 'b');
  c.constraints['h2'] = HorizontalConstraintDto(id: 'h2', lineId: 'l2', pointAId: 'b', pointBId: 'c');
  c.constraints['v3'] = VerticalConstraintDto(id: 'v3', lineId: 'l3', pointAId: 'c', pointBId: 'origin-1');
  c.constraints['w'] =
      DistanceConstraintDto(id: 'w', pointAId: 'origin-1', pointBId: 'a', distance: 10, orientation: 'horizontal');
  if (redundantParallel) {
    c.constraints['par'] = ParallelConstraintDto(id: 'par', line1Id: 'l0', line2Id: 'l2');
  }
}

void main() {
  test('a corner pinned by a dimension plus a horizontal is refused, a corner that can still slide is grabbed', () async {
    final c = await _controller();
    _rectangle(c);
    expect(c.beginPointDrag('a'), isFalse, reason: 'x by the width dimension, y by the horizontal: nowhere to go');
    c.cursorX = 10;
    c.cursorY = 6;
    expect(c.beginPointDrag('b'), isTrue, reason: 'the height is free');
  });

  test('a redundant Parallel does not make a movable corner look fully constrained', () async {
    final c = await _controller();
    _rectangle(c, redundantParallel: true);
    c.cursorX = 10;
    c.cursorY = 6;
    expect(c.beginPointDrag('b'), isTrue);
    await c.updatePointDrag(10, 9);
    expect(c.points['b']!.y, closeTo(9, 0.01), reason: 'it follows the hand along its free direction');
    expect(c.points['b']!.x, closeTo(10, 1e-4));
    expect(c.dragStats.rejected, 0);
  });

  test('a fully dimensioned rectangle refuses every corner', () async {
    final c = await _controller();
    _rectangle(c);
    c.constraints['ht'] =
        DistanceConstraintDto(id: 'ht', pointAId: 'origin-1', pointBId: 'c', distance: 6, orientation: 'vertical');
    for (final id in ['a', 'b', 'c']) {
      expect(c.beginPointDrag(id), isFalse, reason: id);
    }
  });

  test('a constraint naming a Line the controller does not know is ignored, never a crash (found by the real app)', () async {
    final c = await _controller();
    _rectangle(c);
    c.constraints['stale'] = ParallelConstraintDto(id: 'stale', line1Id: 'l0', line2Id: 'no-such-line');
    c.cursorX = 10;
    c.cursorY = 6;
    expect(c.beginPointDrag('b'), isTrue);
    await c.updatePointDrag(10, 8);
    expect(c.points['b']!.y, closeTo(8, 0.01));
    expect(c.dragStats.rejected, 0);
  });

  test('axis dimensions (a circle\'s cardinal-point pins: horizontal/vertical distance 0) do not trip the residual guard', () async {
    // Found by driving the real app: the real backend gives every circle such pins; the guard used to compare the
    // Euclidean distance (the radius) with 0 and reject every frame of a drag.
    final c = await _controller();
    c.points['ctr'] = const SketchPointView(id: 'ctr', x: 20, y: 20);
    c.points['north'] = const SketchPointView(id: 'north', x: 20, y: 24);
    c.points['east'] = const SketchPointView(id: 'east', x: 24, y: 20);
    c.constraints['n'] =
        DistanceConstraintDto(id: 'n', pointAId: 'ctr', pointBId: 'north', distance: 0, orientation: 'horizontal');
    c.constraints['e'] =
        DistanceConstraintDto(id: 'e', pointAId: 'ctr', pointBId: 'east', distance: 0, orientation: 'vertical');
    c.constraints['r'] = DistanceConstraintDto(id: 'r', pointAId: 'ctr', pointBId: 'north', distance: 4);
    c.constraints['re'] = EqualRadiusConstraintDto(
        id: 're', center1PointId: 'ctr', radius1PointId: 'north', center2PointId: 'ctr', radius2PointId: 'east');
    c.cursorX = 20;
    c.cursorY = 20;
    expect(c.beginPointDrag('ctr'), isTrue);
    for (final t in [(21.0, 20.0), (23.0, 22.0), (25.0, 25.0)]) {
      await c.updatePointDrag(t.$1, t.$2);
    }
    expect(c.dragStats.rejected, 0);
    expect(c.points['north']!.x, closeTo(c.points['ctr']!.x, 1e-4), reason: 'the axis pin holds');
    expect(c.points['east']!.y, closeTo(c.points['ctr']!.y, 1e-4));
  });
}
