import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('polygon loop (Line-only) returns the raw points in order', () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
    controller.points['p1'] = const SketchPointView(id: 'p1', x: 5, y: 0);
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 5, y: 5);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 0, y: 5);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p1', endPointId: 'p2');
    controller.lines['l2'] = const SketchLineView(id: 'l2', startPointId: 'p2', endPointId: 'p3');
    controller.lines['l3'] = const SketchLineView(id: 'l3', startPointId: 'p3', endPointId: 'p0');

    final loop = ProfileLoopDto(pointIds: ['p0', 'p1', 'p2', 'p3'], lineIds: ['l0', 'l1', 'l2', 'l3']);
    final outline = controller.profileLoopOutline(loop);

    expect(outline, [(0.0, 0.0), (5.0, 0.0), (5.0, 5.0), (0.0, 5.0)]);
  });

  test('circle loop tessellates into a closed ring at the right radius', () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['c'] = const SketchPointView(id: 'c', x: 10, y: 10);
    controller.points['r'] = const SketchPointView(id: 'r', x: 14, y: 10); // radius 4
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'c', radiusPointId: 'r');

    final loop = ProfileLoopDto(pointIds: ['c', 'r'], lineIds: ['circ']);
    final outline = controller.profileLoopOutline(loop);

    expect(outline, isNotNull);
    expect(outline!.length, greaterThan(16));
    for (final (x, y) in outline) {
      final dist = math.sqrt((x - 10) * (x - 10) + (y - 10) * (y - 10));
      expect(dist, closeTo(4.0, 1e-6));
    }
    // Implicitly closed (no duplicated final point) - same convention as
    // every other case.
    expect(outline.first, isNot(outline.last));
  });

  test('ellipse loop tessellates into a rotated ellipse ring', () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    // Major axis along +X (unrotated) for a simple, checkable case.
    controller.points['c'] = const SketchPointView(id: 'c', x: 0, y: 0);
    controller.points['maj'] = const SketchPointView(id: 'maj', x: 6, y: 0); // majorRadius 6
    controller.points['majNeg'] = const SketchPointView(id: 'majNeg', x: -6, y: 0);
    controller.points['min'] = const SketchPointView(id: 'min', x: 0, y: 3); // minorRadius 3
    controller.points['minNeg'] = const SketchPointView(id: 'minNeg', x: 0, y: -3);
    controller.ellipses['e'] = const SketchEllipseView(
      id: 'e',
      centerPointId: 'c',
      majorPointId: 'maj',
      majorPointNegId: 'majNeg',
      minorPointId: 'min',
      minorPointNegId: 'minNeg',
      majorAxisLineId: 'majAxis',
      minorAxisLineId: 'minAxis',
      minorRadius: 3,
    );

    final loop = ProfileLoopDto(pointIds: ['c', 'maj'], lineIds: ['e']);
    final outline = controller.profileLoopOutline(loop);

    expect(outline, isNotNull);
    for (final (x, y) in outline!) {
      final normalized = (x * x) / 36 + (y * y) / 9;
      expect(normalized, closeTo(1.0, 1e-6));
    }
  });

  test('mixed Line+Arc loop (rounded corner) tessellates a continuous outline with no gaps', () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    // A "D" shape: straight top+left+bottom edges, a semicircular right cap.
    controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0); // top-left
    controller.points['p1'] = const SketchPointView(id: 'p1', x: 5, y: 0); // arc start (top-right)
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 5, y: 10); // arc end (bottom-right)
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 0, y: 10); // bottom-left
    controller.points['arcCenter'] = const SketchPointView(id: 'arcCenter', x: 5, y: 5);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
    controller.arcs['a0'] =
        const SketchArcView(id: 'a0', centerPointId: 'arcCenter', startPointId: 'p1', endPointId: 'p2');
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p2', endPointId: 'p3');
    controller.lines['l2'] = const SketchLineView(id: 'l2', startPointId: 'p3', endPointId: 'p0');

    final loop = ProfileLoopDto(pointIds: ['p0', 'p1', 'p2', 'p3'], lineIds: ['l0', 'a0', 'l1', 'l2']);
    final outline = controller.profileLoopOutline(loop);

    expect(outline, isNotNull);
    // Straight hops contribute exactly 1 point each (their end anchor);
    // the arc hop contributes many, bulging out to radius 5 from the arc
    // center, past x=5 (proving it swept outward, not just chorded).
    final maxX = outline!.map((p) => p.$1).reduce(math.max);
    expect(maxX, greaterThan(9.9)); // arc center (5,5) + radius 5 = 10 at its apex
    // Implicitly closed: the walk's own last emitted point is p0 (0,0)
    // again, which the method strips - so the true last point is p3, the
    // hop immediately before the final line back to p0.
    expect(outline.last, (0.0, 10.0));
    expect(outline.first, (0.0, 0.0));
  });

  test('mixed Line+Spline loop stays continuous end to end', () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
    controller.points['p1'] = const SketchPointView(id: 'p1', x: 10, y: 0);
    controller.points['c1'] = const SketchPointView(id: 'c1', x: 10, y: 4);
    controller.points['c2'] = const SketchPointView(id: 'c2', x: 0, y: 4);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
    controller.splines['s0'] = const SketchSplineView(
      id: 's0',
      throughPointIds: ['p1', 'p0'],
      controlPointIds: ['c1', 'c2'],
    );

    final loop = ProfileLoopDto(pointIds: ['p0', 'p1'], lineIds: ['l0', 's0']);
    final outline = controller.profileLoopOutline(loop);

    expect(outline, isNotNull);
    // 1 initial anchor + 1 line hop + 16 spline steps, minus the final
    // duplicate-of-first point the method strips for implicit closure.
    expect(outline!.length, 17);
    expect(outline.first, (0.0, 0.0));
    expect(outline[1], (10.0, 0.0)); // the line hop's own endpoint, p1
    // The stripped point (not present) was the spline's own exact
    // endpoint p0 (0,0) - the last point kept is one step short of it.
    expect(outline.last.$1, closeTo(0.0, 1.0));
    expect(outline.last.$2, closeTo(0.0, 1.0));
  });

  test('missing referenced point returns null instead of throwing', () {
    final controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
    final loop = ProfileLoopDto(pointIds: ['p0', 'ghost'], lineIds: ['l0']);
    expect(controller.profileLoopOutline(loop), isNull);
  });
}
