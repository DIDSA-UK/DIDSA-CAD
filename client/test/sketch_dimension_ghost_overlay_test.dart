import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SketchController controller;

  setUp(() {
    controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
    controller.points['p1'] = const SketchPointView(id: 'p1', x: 5, y: 0);
  });

  test('nothing picked in Dimension mode produces no ghost overlay items', () {
    controller.enterDimensionMode();
    expect(controller.dimensionGhostOverlayItems(), isEmpty);
  });

  test('two picked Points produce vertical/horizontal/linear ghost items with "?" placeholder text',
      () async {
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);

    final items = controller.dimensionGhostOverlayItems();
    expect(items, hasLength(3));
    final byOrientation = {
      for (final item in items.cast<ConstraintLinearDimensionItem>()) item.orientation: item,
    };
    expect(byOrientation.keys.toSet(), {'vertical', 'horizontal', 'linear'});
    for (final item in byOrientation.values) {
      expect(item.text, '?');
      expect(item.pointA, (0.0, 0.0));
      expect(item.pointB, (5.0, 0.0));
    }
  });

  test('a picked Circle produces radius ("R?") and diameter ("⌀?") ghost items', () async {
    controller.points['center'] = const SketchPointView(id: 'center', x: 10, y: 10);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 14, y: 10);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.enterDimensionMode();
    // 45deg on the circle's own boundary (radius 4), away from its Points.
    await controller.handleCanvasTap(10 + 4 * 0.70710678, 10 + 4 * 0.70710678);

    final items = controller.dimensionGhostOverlayItems();
    expect(items, hasLength(2));
    final radial = items.cast<ConstraintRadialDimensionItem>();
    final radiusItem = radial.singleWhere((i) => !i.isDiameter);
    final diameterItem = radial.singleWhere((i) => i.isDiameter);
    expect(radiusItem.text, 'R?');
    expect(diameterItem.text, '⌀?');
    expect(radiusItem.radius, closeTo(4.0, 1e-9));
    expect(diameterItem.radius, closeTo(4.0, 1e-9));
    expect(radiusItem.center, (10.0, 10.0));
    expect(radiusItem.rim, (14.0, 10.0));
  });

  test(
      'P47 bug fix: radius and diameter ghosts get a distinct default leader angle, so their '
      'computed label positions never collide and diameter never silently wins every hit-test',
      () async {
    controller.points['center'] = const SketchPointView(id: 'center', x: 10, y: 10);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 14, y: 10);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10 + 4 * 0.70710678, 10 + 4 * 0.70710678);

    final items = controller.dimensionGhostOverlayItems();
    final radial = items.cast<ConstraintRadialDimensionItem>();
    final radiusItem = radial.singleWhere((i) => !i.isDiameter);
    final diameterItem = radial.singleWhere((i) => i.isDiameter);
    // Same center/rim (so the same base direction/radius) and the same
    // (un-dragged) labelOffset, yet a different defaultAngleOffsetDegrees
    // is enough on its own to guarantee a different final label position
    // regardless of camera angle or circle size - see
    // dimensionGhostOverlayItems' own P47 doc comment.
    expect(radiusItem.center, diameterItem.center);
    expect(radiusItem.rim, diameterItem.rim);
    expect(radiusItem.labelOffset, diameterItem.labelOffset);
    expect(radiusItem.defaultAngleOffsetDegrees, isNot(diameterItem.defaultAngleOffsetDegrees));
  });

  test(
      'P44f bug fix: once a ghost\'s leader angle has been set via setRadialAngleOffset (the '
      'embedded 3D view\'s own camera-independent drag persistence), it wins over the P47 default '
      'separation, and labelOffset stays zero (no screen-pixel component left to drift under orbit)',
      () async {
    controller.points['center'] = const SketchPointView(id: 'center', x: 10, y: 10);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 14, y: 10);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10 + 4 * 0.70710678, 10 + 4 * 0.70710678);

    controller.setRadialAngleOffset('diameter', 137.0);

    final items = controller.dimensionGhostOverlayItems();
    final diameterItem = items.cast<ConstraintRadialDimensionItem>().singleWhere((i) => i.isDiameter);

    expect(diameterItem.defaultAngleOffsetDegrees, 137.0);
    expect(diameterItem.labelOffset, Offset.zero);
    expect(controller.radialAngleOffsetFor('diameter'), 137.0);
    expect(controller.radialAngleOffsetFor('radius'), isNull, reason: 'radius was never dragged');
  });

  test('the active ghost (tapGhost) is flagged selected; its siblings are not', () async {
    controller.points['center'] = const SketchPointView(id: 'center', x: 0, y: 0);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 3, y: 0);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.enterDimensionMode();
    await controller.handleCanvasTap(2.121, 2.121); // 45deg on the circle's boundary
    controller.tapGhost('radius');

    final items = controller.dimensionGhostOverlayItems();
    final radial = items.cast<ConstraintRadialDimensionItem>();
    expect(radial.singleWhere((i) => !i.isDiameter).selected, isTrue);
    expect(radial.singleWhere((i) => i.isDiameter).selected, isFalse);
  });

  test('two non-parallel Lines produce a single angle ghost label with "?" text', () async {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 0, y: 5);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 5, y: 8);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p2', endPointId: 'p3');
    controller.enterDimensionMode();
    // 30% along each line - away from both its own endpoints (a Point
    // always outranks a Line in Dimension mode's own hit-test priority)
    // and its exact midpoint (Dimension mode separately snaps a tap right
    // at a Line's own midpoint into materializing a new Point there
    // instead of picking the Line itself - see
    // SketchController._resolveSelectableAt's own dispatch order).
    await controller.handleCanvasTap(1.5, 0); // 30% along l0
    await controller.handleCanvasTap(1.5, 5.9); // 30% along l1

    final items = controller.dimensionGhostOverlayItems();
    expect(items, hasLength(1));
    expect(items.single, isA<ConstraintLabelItem>());
    expect((items.single as ConstraintLabelItem).text, '?');
  });

  test('two parallel Lines produce a single lineDistance ghost item with "?" text', () async {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 0, y: 3);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 5, y: 3);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p2', endPointId: 'p3');
    controller.enterDimensionMode();
    await controller.handleCanvasTap(1.5, 0); // 30% along l0, away from its own midpoint/endpoints
    await controller.handleCanvasTap(1.5, 3); // 30% along l1

    final items = controller.dimensionGhostOverlayItems();
    expect(items, hasLength(1));
    expect(items.single, isA<ConstraintLineDistanceDimensionItem>());
    expect((items.single as ConstraintLineDistanceDimensionItem).text, '?');
  });
}
