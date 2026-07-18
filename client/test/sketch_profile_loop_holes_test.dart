import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:flutter_test/flutter_test.dart';

double _polygonArea(List<(double, double)> polygon) {
  var area = 0.0;
  for (var i = 0; i < polygon.length; i++) {
    final (x1, y1) = polygon[i];
    final (x2, y2) = polygon[(i + 1) % polygon.length];
    area += x1 * y2 - x2 * y1;
  }
  return area.abs() / 2;
}

double _triangulatedArea(List<(double, double)> polygon, List<int> indices) {
  var total = 0.0;
  for (var t = 0; t + 2 < indices.length; t += 3) {
    final (x1, y1) = polygon[indices[t]];
    final (x2, y2) = polygon[indices[t + 1]];
    final (x3, y3) = polygon[indices[t + 2]];
    total += ((x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)).abs() / 2;
  }
  return total;
}

void main() {
  test('P42: a single square hole is subtracted from the outer square\'s own triangulated area',
      () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
    controller.points['p1'] = const SketchPointView(id: 'p1', x: 10, y: 0);
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 10, y: 10);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 0, y: 10);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p1', endPointId: 'p2');
    controller.lines['l2'] = const SketchLineView(id: 'l2', startPointId: 'p2', endPointId: 'p3');
    controller.lines['l3'] = const SketchLineView(id: 'l3', startPointId: 'p3', endPointId: 'p0');
    controller.points['h0'] = const SketchPointView(id: 'h0', x: 3, y: 3);
    controller.points['h1'] = const SketchPointView(id: 'h1', x: 7, y: 3);
    controller.points['h2'] = const SketchPointView(id: 'h2', x: 7, y: 7);
    controller.points['h3'] = const SketchPointView(id: 'h3', x: 3, y: 7);
    controller.lines['m0'] = const SketchLineView(id: 'm0', startPointId: 'h0', endPointId: 'h1');
    controller.lines['m1'] = const SketchLineView(id: 'm1', startPointId: 'h1', endPointId: 'h2');
    controller.lines['m2'] = const SketchLineView(id: 'm2', startPointId: 'h2', endPointId: 'h3');
    controller.lines['m3'] = const SketchLineView(id: 'm3', startPointId: 'h3', endPointId: 'h0');

    final hole = ProfileLoopDto(pointIds: ['h0', 'h1', 'h2', 'h3'], lineIds: ['m0', 'm1', 'm2', 'm3']);
    final loop = ProfileLoopDto(
      pointIds: ['p0', 'p1', 'p2', 'p3'],
      lineIds: ['l0', 'l1', 'l2', 'l3'],
      innerLoops: [hole],
    );

    final bridged = controller.profileLoopOutlineWithHoles(loop);
    expect(bridged, isNotNull);

    final indices = earClipTriangleIndices(bridged!);
    final triangulated = _triangulatedArea(bridged, indices);
    final outerArea = _polygonArea([
      (0.0, 0.0),
      (10.0, 0.0),
      (10.0, 10.0),
      (0.0, 10.0),
    ]);
    final holeArea = _polygonArea([(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)]);

    expect(triangulated, closeTo(outerArea - holeArea, 1e-6));
  });

  test('P42: a circular hole inside a circular outer profile is also subtracted correctly', () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['c'] = const SketchPointView(id: 'c', x: 0, y: 0);
    controller.points['r'] = const SketchPointView(id: 'r', x: 10, y: 0);
    controller.circles['outer'] = const SketchCircleView(id: 'outer', centerPointId: 'c', radiusPointId: 'r');
    controller.points['hc'] = const SketchPointView(id: 'hc', x: 0, y: 0);
    controller.points['hr'] = const SketchPointView(id: 'hr', x: 4, y: 0);
    controller.circles['inner'] = const SketchCircleView(id: 'inner', centerPointId: 'hc', radiusPointId: 'hr');

    final hole = ProfileLoopDto(pointIds: ['hc', 'hr'], lineIds: ['inner']);
    final loop = ProfileLoopDto(pointIds: ['c', 'r'], lineIds: ['outer'], innerLoops: [hole]);

    final bridged = controller.profileLoopOutlineWithHoles(loop);
    expect(bridged, isNotNull);

    final indices = earClipTriangleIndices(bridged!);
    final triangulated = _triangulatedArea(bridged, indices);
    final expectedArea = math.pi * (10 * 10 - 4 * 4);

    // Polygon-approximated circles (48 segments each, per the profile
    // tessellation's own constant) - a looser tolerance than the exact
    // straight-edge case above, matching the same approximation error
    // circle tessellation always carries.
    expect(triangulated, closeTo(expectedArea, expectedArea * 0.01));
  });

  test('P42: profileLoopOutlineWithHoles falls back to the plain outline when there are no holes', () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
    controller.points['p1'] = const SketchPointView(id: 'p1', x: 5, y: 0);
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 5, y: 5);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p1', endPointId: 'p2');
    controller.lines['l2'] = const SketchLineView(id: 'l2', startPointId: 'p2', endPointId: 'p0');

    final loop = ProfileLoopDto(pointIds: ['p0', 'p1', 'p2'], lineIds: ['l0', 'l1', 'l2']);

    expect(
      controller.profileLoopOutlineWithHoles(loop),
      controller.profileLoopOutline(loop),
    );
  });
}
