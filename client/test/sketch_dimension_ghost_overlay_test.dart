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

  test('two picked Points preview one linear dimension at a time (Part A); the drawer switches the kind, each with "?" text',
      () async {
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);

    expect(controller.dimensionGhostOverlayItems(), hasLength(1));
    final seen = <String?>{};
    for (final key in ['linear', 'h', 'v']) {
      controller.selectPendingDimensionKind(key);
      final items = controller.dimensionGhostOverlayItems();
      expect(items, hasLength(1));
      final item = items.single as ConstraintLinearDimensionItem;
      seen.add(item.orientation);
      expect(item.text, '?');
      expect(item.pointA, (0.0, 0.0));
      expect(item.pointB, (5.0, 0.0));
    }
    expect(seen, {'linear', 'horizontal', 'vertical'});
  });

  test('a picked Circle previews its diameter ("⌀?") first; the drawer switches to the radius ("R?")', () async {
    controller.points['center'] = const SketchPointView(id: 'center', x: 10, y: 10);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 14, y: 10);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.enterDimensionMode();
    // 45deg on the circle's own boundary (radius 4), away from its Points.
    await controller.handleCanvasTap(10 + 4 * 0.70710678, 10 + 4 * 0.70710678);

    final diameterItem = controller.dimensionGhostOverlayItems().single as ConstraintRadialDimensionItem;
    expect(diameterItem.isDiameter, isTrue);
    expect(diameterItem.text, '⌀?');
    expect(diameterItem.radius, closeTo(4.0, 1e-9));

    controller.selectPendingDimensionKind('radius');
    final radiusItem = controller.dimensionGhostOverlayItems().single as ConstraintRadialDimensionItem;
    expect(radiusItem.isDiameter, isFalse);
    expect(radiusItem.text, 'R?');
    expect(radiusItem.radius, closeTo(4.0, 1e-9));
    expect(radiusItem.center, (10.0, 10.0));
    expect(radiusItem.rim, (14.0, 10.0));
  });

  test(
      'P47 bug fix (kept for the ribbon chips, which open the editor with no dropped placement): radius and diameter get a distinct '
      'default leader angle, so they never sit on top of each other', () async {
    controller.points['center'] = const SketchPointView(id: 'center', x: 10, y: 10);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 14, y: 10);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10 + 4 * 0.70710678, 10 + 4 * 0.70710678);

    controller.tapGhost('radius');
    final radiusItem = controller.dimensionGhostOverlayItems().single as ConstraintRadialDimensionItem;
    controller.tapGhost('diameter');
    final diameterItem = controller.dimensionGhostOverlayItems().single as ConstraintRadialDimensionItem;
    expect(radiusItem.center, diameterItem.center);
    expect(radiusItem.rim, diameterItem.rim);
    expect(radiusItem.labelOffset, diameterItem.labelOffset);
    expect(radiusItem.defaultAngleOffsetDegrees, isNot(diameterItem.defaultAngleOffsetDegrees));
  });

  test(
      'P44f (reworked for Part A): a radial ghost\'s leader angle and leg come from the cursor through the label-drag rule, in sketch '
      'units, and labelOffset stays zero (no screen-pixel component left to drift under orbit)', () async {
    controller.points['center'] = const SketchPointView(id: 'center', x: 10, y: 10);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 14, y: 10);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10 + 4 * 0.70710678, 10 + 4 * 0.70710678);

    controller.moveCursorToSketchPoint(10, 20); // straight above the centre, 6 beyond the circle
    final placement = controller.pendingPlacementFromCursor()!;
    expect(placement.angle, closeTo(90.0, 1e-9)); // from the rim point's direction (east) to north
    expect(placement.leg, closeTo(6.0, 1e-9));
    final item = controller.dimensionGhostOverlayItems().single as ConstraintRadialDimensionItem;
    expect(item.defaultAngleOffsetDegrees, placement.angle);
    expect(item.sketchLocalLegLength, placement.leg);
    expect(item.labelOffset, Offset.zero);
  });

  test(
      'P52 (reworked for Part A): a linear ghost\'s sketchLocalOffsetDistance / along follow the cursor until a click drops it, then hold',
      () async {
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    controller.selectPendingDimensionKind('h');

    controller.moveCursorToSketchPoint(1, 3);
    var item = controller.dimensionGhostOverlayItems().single as ConstraintLinearDimensionItem;
    expect(item.sketchLocalOffsetDistance, 3.0); // above the points (a horizontal dimension is measured from their larger y)
    expect(item.sketchLocalAlongOffset, closeTo(-1.5, 1e-9)); // from the points' midpoint (2.5)

    controller.moveCursorToSketchPoint(4, -2);
    item = controller.dimensionGhostOverlayItems().single as ConstraintLinearDimensionItem;
    expect(item.sketchLocalOffsetDistance, -2.0);

    await controller.handleCanvasTap(4, -2); // empty space: drop
    controller.moveCursorToSketchPoint(30, 30);
    item = controller.dimensionGhostOverlayItems().single as ConstraintLinearDimensionItem;
    expect(item.sketchLocalOffsetDistance, -2.0); // frozen where it was dropped
    expect(item.selected, isTrue);
  });

  test('the previewed ghost is not "selected"; the one whose editor is open (tapGhost) is', () async {
    controller.points['center'] = const SketchPointView(id: 'center', x: 0, y: 0);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 3, y: 0);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
    controller.enterDimensionMode();
    await controller.handleCanvasTap(2.121, 2.121); // 45deg on the circle's boundary
    expect((controller.dimensionGhostOverlayItems().single as ConstraintRadialDimensionItem).selected, isFalse);

    controller.tapGhost('radius');

    final item = controller.dimensionGhostOverlayItems().single as ConstraintRadialDimensionItem;
    expect(item.isDiameter, isFalse);
    expect(item.selected, isTrue);
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
    expect(items.single, isA<ConstraintAngleDimensionItem>());
    expect((items.single as ConstraintAngleDimensionItem).text, '?');
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

  test(
      'P52 follow-up (reworked for Part A): a lineDistance ghost\'s sketchLocalOffsetDistance comes from the cursor through the '
      'line-distance rule, and holds once dropped',
      () async {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 0, y: 3);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 5, y: 3);
    controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p2', endPointId: 'p3');
    controller.enterDimensionMode();
    await controller.handleCanvasTap(1.5, 0);
    await controller.handleCanvasTap(1.5, 3);

    controller.moveCursorToSketchPoint(4, 1.5);
    final expected = controller.pendingPlacementFromCursor()!;
    var item = controller.dimensionGhostOverlayItems().single as ConstraintLineDistanceDimensionItem;
    expect(item.sketchLocalOffsetDistance, expected.offset);
    expect(item.sketchLocalAlongOffset, expected.along);

    await controller.handleCanvasTap(4, 1.5);
    controller.moveCursorToSketchPoint(-8, -8);
    item = controller.dimensionGhostOverlayItems().single as ConstraintLineDistanceDimensionItem;
    expect(item.sketchLocalOffsetDistance, expected.offset);
  });
}
