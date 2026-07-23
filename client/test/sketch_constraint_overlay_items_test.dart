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

  test(
      'an Angle constraint becomes a ConstraintAngleDimensionItem carrying both Lines\' own '
      'endpoints (bug fix: this used to be a plain floating "N.N°" chip with no leader/extension '
      'lines at all)', () {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 0, y: 0);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 0, y: 5);
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p2', endPointId: 'p3');
    controller.constraints['c0'] = const AngleConstraintDto(
      id: 'c0',
      line1Id: 'l0',
      line2Id: 'l1',
      angleDegrees: 90.0,
    );

    final items = controller.constraintOverlayItems();

    expect(items, hasLength(1));
    final item = items.single as ConstraintAngleDimensionItem;
    expect(item.text, '90.0°');
    expect(item.line1Start, (0.0, 0.0));
    expect(item.line1End, (5.0, 0.0));
    expect(item.line2Start, (0.0, 0.0));
    expect(item.line2End, (0.0, 5.0));
    expect(item.sketchLocalArcRadius, isNull);
  });

  test(
      'a PointLineDistance constraint becomes a ConstraintLinearDimensionItem between the Point '
      'and its own perpendicular foot on the Line - clamped-inside-the-segment case (bug fix: '
      'this used to be a plain floating chip with no extension lines at all)', () {
    controller.points['pt'] = const SketchPointView(id: 'pt', x: 2, y: 3);
    controller.constraints['c0'] = const PointLineDistanceConstraintDto(
      id: 'c0',
      pointId: 'pt',
      lineId: 'l0',
      distance: 3.0,
    );

    final items = controller.constraintOverlayItems();

    expect(items, hasLength(1));
    final item = items.single as ConstraintLinearDimensionItem;
    expect(item.text, '3.00');
    expect(item.pointA, (2.0, 3.0));
    expect(item.pointB.$1, closeTo(2.0, 1e-9));
    expect(item.pointB.$2, closeTo(0.0, 1e-9));
    expect(item.orientation, isNull);
  });

  test(
      'a PointLineDistance constraint\'s perpendicular foot is NOT clamped to the drawn Line '
      'segment - it measures onto the Line\'s own infinite extension, matching the constrained '
      'value', () {
    controller.points['pt'] = const SketchPointView(id: 'pt', x: 15, y: 3);
    controller.constraints['c0'] = const PointLineDistanceConstraintDto(
      id: 'c0',
      pointId: 'pt',
      lineId: 'l0', // l0 runs (0,0)-(5,0); its own foot for x=15 falls well beyond its own end
      distance: 3.0,
    );

    final items = controller.constraintOverlayItems();

    final item = items.single as ConstraintLinearDimensionItem;
    expect(item.pointB.$1, closeTo(15.0, 1e-9));
    expect(item.pointB.$2, closeTo(0.0, 1e-9));
  });

  test('a missing referenced Point/Line is skipped rather than throwing', () {
    controller.constraints['c0'] =
        const VerticalConstraintDto(id: 'c0', lineId: 'ghost-line', pointAId: 'p0', pointBId: 'ghost-point');

    expect(controller.constraintOverlayItems(), isEmpty);
  });
}
