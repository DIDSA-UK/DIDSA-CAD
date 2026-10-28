import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart' show dimensionLabelAt, dimensionLabelCenterScreen;
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/view_transform.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every dimension kind, laid out by the flat canvas's painters from a saved placement, must put the label where the user dragged it,
/// at any zoom - and an unplaced dimension must keep drawing where it always did.
void main() {
  late SketchController controller;

  setUp(() {
    controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['a'] = const SketchPointView(id: 'a', x: 0, y: 0);
    controller.points['b'] = const SketchPointView(id: 'b', x: 10, y: 4);
    controller.points['c'] = const SketchPointView(id: 'c', x: 1, y: 8);
    controller.points['d'] = const SketchPointView(id: 'd', x: 12, y: 9);
    controller.points['e'] = const SketchPointView(id: 'e', x: 0, y: 20);
    controller.points['f'] = const SketchPointView(id: 'f', x: 14, y: 20);
    controller.points['ctr'] = const SketchPointView(id: 'ctr', x: -20, y: -10);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: -15, y: -10);
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'a', endPointId: 'b');
    controller.lines['l2'] = const SketchLineView(id: 'l2', startPointId: 'c', endPointId: 'd');
    controller.lines['horizontal1'] = const SketchLineView(id: 'horizontal1', startPointId: 'a', endPointId: 'b');
    controller.lines['top'] = const SketchLineView(id: 'top', startPointId: 'e', endPointId: 'f');
    controller.lines['below'] = const SketchLineView(id: 'below', startPointId: 'a', endPointId: 'f');
    controller.circles['circle'] = const SketchCircleView(id: 'circle', centerPointId: 'ctr', radiusPointId: 'rim');
  });

  // Drags [id]'s label to sketch point [p] with the pointer on its centre.
  void dragTo(String id, (double, double) p) {
    expect(controller.beginLabelDrag(id), isTrue);
    controller.dragLabelToPointer(p.$1, p.$2);
    controller.endLabelDrag();
  }

  void expectLabelAt(String id, (double, double) p, {double tolerance = 1e-6}) {
    for (final ppu in [8.0, 20.0, 64.0]) {
      final transform = ViewTransform(pixelsPerUnit: ppu, originScreen: const Offset(300, 400));
      final center = dimensionLabelCenterScreen(controller, transform, id);
      final wanted = transform.sketchToScreen(p.$1, p.$2);
      expect(center, isNotNull, reason: '$id at $ppu px/unit');
      expect(center!.dx, closeTo(wanted.dx, tolerance), reason: '$id x at $ppu px/unit');
      expect(center.dy, closeTo(wanted.dy, tolerance), reason: '$id y at $ppu px/unit');
    }
  }

  group('a dragged label is drawn where it was dropped, at any zoom', () {
    test('linear (diagonal)', () {
      controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'a', pointBId: 'b', distance: 10.8);
      for (final p in [(3.0, 9.0), (14.0, -3.0), (-4.0, 6.0)]) {
        dragTo('dim', p);
        expectLabelAt('dim', p);
      }
    });

    test('linear with the points stored the other way round', () {
      controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'b', pointBId: 'a', distance: 10.8);
      for (final p in [(3.0, 9.0), (14.0, -3.0)]) {
        dragTo('dim', p);
        expectLabelAt('dim', p);
      }
    });

    test('horizontal and vertical, whichever point is A', () {
      for (final (orientation, a, b) in [
        ('horizontal', 'a', 'b'),
        ('horizontal', 'b', 'a'),
        ('vertical', 'a', 'b'),
        ('vertical', 'b', 'a'),
      ]) {
        controller.constraints['dim'] =
            DistanceConstraintDto(id: 'dim', pointAId: a, pointBId: b, distance: 10, orientation: orientation);
        for (final p in [(3.0, 9.0), (14.0, -3.0), (-4.0, 6.0)]) {
          dragTo('dim', p);
          expectLabelAt('dim', p);
        }
      }
    });

    test('line to line, whichever side the second line is on', () {
      controller.constraints['dim'] = const LineDistanceConstraintDto(id: 'dim', line1Id: 'l1', line2Id: 'l2', distance: 5);
      for (final p in [(7.0, 12.0), (2.0, -6.0), (20.0, 3.0)]) {
        dragTo('dim', p);
        expectLabelAt('dim', p);
      }
      controller.constraints['dim'] = const LineDistanceConstraintDto(id: 'dim', line1Id: 'l2', line2Id: 'l1', distance: 5);
      for (final p in [(7.0, 12.0), (2.0, -6.0), (20.0, 3.0)]) {
        dragTo('dim', p);
        expectLabelAt('dim', p);
      }
    });

    test('point to line', () {
      controller.constraints['dim'] = const PointLineDistanceConstraintDto(id: 'dim', pointId: 'c', lineId: 'l1', distance: 4);
      for (final p in [(-6.0, 3.0), (9.0, 13.0), (20.0, -4.0)]) {
        dragTo('dim', p);
        expectLabelAt('dim', p);
      }
    });

    test('radius and diameter (the leader follows the label, whatever side of the circle it is dragged to)', () {
      const radius = DistanceConstraintDto(id: 'dim', pointAId: 'ctr', pointBId: 'rim', distance: 5);
      controller.constraints['dim'] = radius;
      expect(controller.isRadiusDistanceConstraint(radius), isTrue, reason: 'this must go through the radial layout');
      for (final p in [(-10.0, -4.0), (-26.0, -10.0), (-20.0, -22.0), (-18.0, -8.0)]) {
        dragTo('dim', p);
        expectLabelAt('dim', p);
      }
    });

    test('angle', () {
      controller.constraints['dim'] = const AngleConstraintDto(id: 'dim', line1Id: 'l1', line2Id: 'top', angleDegrees: 50);
      // Lines l1 (0,0)-(10,4) and top (0,20)-(14,20) meet at (50, 20); the angle opens to the left, so drag the label there.
      for (final p in [(14.0, 17.0), (18.0, 19.0), (12.0, 15.0)]) {
        dragTo('dim', p);
        expect(controller.labelPlacementFor('dim')?.radius, isNotNull, reason: 'the lines meet at (50, 20), so $p is inside the opening');
        expectLabelAt('dim', p, tolerance: 1e-5);
      }
    });
  });

  test('an unplaced dimension keeps its default look (no pixel offset)', () {
    controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'a', pointBId: 'b', distance: 10.8);
    controller.constraints['line'] = const LineDistanceConstraintDto(id: 'line', line1Id: 'l1', line2Id: 'l2', distance: 5);
    for (final id in ['dim', 'line']) {
      expect(controller.labelPlacementFor(id), isNull);
    }
    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(300, 400));
    // The default linear label: the dimension line 18px off the segment, the label at its middle.
    final center = dimensionLabelCenterScreen(controller, transform, 'dim')!;
    final a = transform.sketchToScreen(0, 0);
    final b = transform.sketchToScreen(10, 4);
    final middle = (a + b) / 2;
    expect((center - middle).distance, closeTo(18, 1e-9));
  });

  test('hit-testing follows a placed label and ignores its old default place', () {
    controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'a', pointBId: 'b', distance: 10.8);
    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(300, 400));
    final before = dimensionLabelCenterScreen(controller, transform, 'dim')!;
    expect(dimensionLabelAt(controller, transform, before, 5), 'dim');

    dragTo('dim', (3.0, 9.0));

    final after = transform.sketchToScreen(3, 9);
    expect(dimensionLabelAt(controller, transform, after, 5), 'dim');
    expect(dimensionLabelAt(controller, transform, before, 5), isNull);
  });

  test('a placed label holds still in sketch space when the view zooms about the origin', () {
    controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'a', pointBId: 'b', distance: 10.8);
    dragTo('dim', (3.0, 9.0));
    const origin = Offset(300, 400);
    final near = dimensionLabelCenterScreen(controller, const ViewTransform(pixelsPerUnit: 10, originScreen: origin), 'dim')!;
    final far = dimensionLabelCenterScreen(controller, const ViewTransform(pixelsPerUnit: 40, originScreen: origin), 'dim')!;
    // Screen distance from the origin scales exactly with the zoom: the label is fixed to the geometry, not to the screen.
    expect((far - origin).distance / (near - origin).distance, closeTo(4, 1e-9));
  });
}
