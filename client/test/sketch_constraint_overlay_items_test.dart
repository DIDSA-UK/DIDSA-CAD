import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SketchController controller;

  setUp(() {
    controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
    controller.points['p1'] = const SketchPointView(id: 'p1', x: 5, y: 0);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
  });

  test('a Vertical constraint becomes a bare V label at the point-pair midpoint', () {
    controller.constraints['c0'] = const VerticalConstraintDto(id: 'c0', lineId: 'l0', pointAId: 'p0', pointBId: 'p1');

    final items = controller.constraintOverlayItems();

    expect(items, hasLength(1));
    final item = items.single as ConstraintLabelItem;
    expect(item.text, 'V');
    expect(item.anchorA, (0.0, 0.0));
    expect(item.anchorB, (5.0, 0.0));
    expect(item.plainBlackText, isFalse);
    expect(item.selected, isFalse);
  });

  test('a plain Distance constraint becomes a linear dimension with the solved value', () {
    controller.constraints['c0'] =
        const DistanceConstraintDto(id: 'c0', pointAId: 'p0', pointBId: 'p1', distance: 5.0);

    final items = controller.constraintOverlayItems();

    expect(items, hasLength(1));
    final item = items.single as ConstraintLinearDimensionItem;
    expect(item.text, '5.00');
    expect(item.pointA, (0.0, 0.0));
    expect(item.pointB, (5.0, 0.0));
    expect(item.orientation, 'linear');
  });

  test('a provisional Distance constraint is skipped entirely', () {
    controller.constraints['c0'] =
        const DistanceConstraintDto(id: 'c0', pointAId: 'p0', pointBId: 'p1', distance: 5.0, provisional: true);

    expect(controller.constraintOverlayItems(), isEmpty);
  });

  test('a Circle radius Distance constraint becomes a radial dimension, not a linear one', () {
    controller.points['center'] = const SketchPointView(id: 'center', x: 10, y: 10);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 14, y: 10);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.constraints['c0'] =
        const DistanceConstraintDto(id: 'c0', pointAId: 'center', pointBId: 'rim', distance: 4.0);

    final items = controller.constraintOverlayItems();

    expect(items, hasLength(1));
    final item = items.single as ConstraintRadialDimensionItem;
    expect(item.text, 'R4.00');
    expect(item.center, (10.0, 10.0));
    expect(item.rim, (14.0, 10.0));
    expect(item.radius, 4.0);
    expect(item.isDiameter, isFalse);
  });

  test('a zero-distance cardinal-axis constraint is skipped entirely', () {
    controller.points['center'] = const SketchPointView(id: 'center', x: 10, y: 10);
    controller.points['north'] = const SketchPointView(id: 'north', x: 10, y: 14);
    controller.circles['circ'] = const SketchCircleView(
      id: 'circ',
      centerPointId: 'center',
      radiusPointId: 'north',
      cardinalPointIds: ['north'],
    );
    controller.constraints['c0'] =
        const DistanceConstraintDto(id: 'c0', pointAId: 'center', pointBId: 'north', distance: 0.0);

    expect(controller.constraintOverlayItems(), isEmpty);
  });

  test('a Parallel constraint becomes a bare ∥ glyph at the line-midpoint pair', () {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 0, y: 3);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 5, y: 3);
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p2', endPointId: 'p3');
    controller.constraints['c0'] = const ParallelConstraintDto(id: 'c0', line1Id: 'l0', line2Id: 'l1');

    final items = controller.constraintOverlayItems();

    expect(items, hasLength(1));
    final item = items.single as ConstraintLabelItem;
    expect(item.text, '∥');
    expect(item.anchorA, (2.5, 0.0));
    expect(item.anchorB, (2.5, 3.0));
  });

  test('a LineDistance constraint becomes a ConstraintLineDistanceDimensionItem carrying both lines\' endpoints', () {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 0, y: 3);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 5, y: 3);
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p2', endPointId: 'p3');
    controller.constraints['c0'] =
        const LineDistanceConstraintDto(id: 'c0', line1Id: 'l0', line2Id: 'l1', distance: 3.0);

    final items = controller.constraintOverlayItems();

    expect(items, hasLength(1));
    final item = items.single as ConstraintLineDistanceDimensionItem;
    expect(item.text, '3.00');
    expect(item.line1Start, (0.0, 0.0));
    expect(item.line1End, (5.0, 0.0));
    expect(item.line2Start, (0.0, 3.0));
    expect(item.line2End, (5.0, 3.0));
  });

  test('a missing referenced Point/Line is skipped rather than throwing', () {
    controller.constraints['c0'] =
        const VerticalConstraintDto(id: 'c0', lineId: 'ghost-line', pointAId: 'p0', pointBId: 'ghost-point');

    expect(controller.constraintOverlayItems(), isEmpty);
  });
}
