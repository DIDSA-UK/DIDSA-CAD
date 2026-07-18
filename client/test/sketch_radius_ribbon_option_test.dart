import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SketchController controller;

  setUp(() {
    controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['center'] = const SketchPointView(id: 'center', x: 0, y: 0);
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 4, y: 0);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'center', radiusPointId: 'rim');
  });

  test('a lone Circle with no radius dimension yet offers Radius and Diameter options', () {
    controller.selectEntity(const SketchSelection(kind: SelectionKind.circle, id: 'circ'));

    final options = controller.availableConstraintOptions;

    expect(options, hasLength(2));
    expect(options[0].type, ConstraintOptionType.radius);
    expect(options[0].wired, isTrue);
    expect(options[1].type, ConstraintOptionType.diameter);
    expect(options[1].wired, isTrue);
  });

  test('a Circle that already has a radius dimension offers nothing', () {
    controller.constraints['c0'] =
        const DistanceConstraintDto(id: 'c0', pointAId: 'center', pointBId: 'rim', distance: 4.0);
    controller.selectEntity(const SketchSelection(kind: SelectionKind.circle, id: 'circ'));

    expect(controller.availableConstraintOptions, isEmpty);
  });

  test(
      'P44d bug fix: a freshly-drawn Circle from the centre-point tool (whose radius Point is also '
      'its own north cardinal point) still offers Radius/Diameter, even though the backend auto-adds '
      'a second, non-provisional, always-zero axis-pin DistanceConstraint sharing the exact same '
      'center/rim point pair as the real radius constraint - on-device feedback: "can\'t see the new '
      'buttons", reproduced on a circle drawn moments earlier, not just an old already-dimensioned one',
      () {
    // Mirrors Sketch.add_circle's own `radius_point_is_north` branch
    // (backend/app/sketch/models.py): the radius Point doubles as the
    // circle's own north cardinal point, and the backend creates an
    // always-zero, non-provisional axis-pin DistanceConstraint between
    // that exact same (center, rim) pair - completely separate from (and
    // in addition to) the real, still-provisional radius constraint every
    // circle also gets.
    controller.circles['circ'] = const SketchCircleView(
      id: 'circ',
      centerPointId: 'center',
      radiusPointId: 'rim',
      cardinalPointIds: ['rim'],
    );
    controller.constraints['radius0'] =
        const DistanceConstraintDto(id: 'radius0', pointAId: 'center', pointBId: 'rim', distance: 4.0, provisional: true);
    controller.constraints['axisPin'] = const DistanceConstraintDto(
      id: 'axisPin',
      pointAId: 'center',
      pointBId: 'rim',
      distance: 0.0,
      orientation: 'vertical',
    );
    controller.selectEntity(const SketchSelection(kind: SelectionKind.circle, id: 'circ'));

    final options = controller.availableConstraintOptions;
    expect(options, hasLength(2));
    expect(options[0].type, ConstraintOptionType.radius);
    expect(options[1].type, ConstraintOptionType.diameter);
  });

  test('a lone Arc with no radius dimension yet also offers Radius and Diameter options', () {
    controller.points['arcCenter'] = const SketchPointView(id: 'arcCenter', x: 10, y: 10);
    controller.points['arcStart'] = const SketchPointView(id: 'arcStart', x: 14, y: 10);
    controller.points['arcEnd'] = const SketchPointView(id: 'arcEnd', x: 10, y: 14);
    controller.arcs['arc1'] =
        const SketchArcView(id: 'arc1', centerPointId: 'arcCenter', startPointId: 'arcStart', endPointId: 'arcEnd');
    controller.selectEntity(const SketchSelection(kind: SelectionKind.arc, id: 'arc1'));

    final options = controller.availableConstraintOptions;
    expect(options, hasLength(2));
    expect(options[0].type, ConstraintOptionType.radius);
    expect(options[1].type, ConstraintOptionType.diameter);
  });

  // addRadiusDimensionFor's own mode-transition behavior needs a real
  // sketch id (it's gated on `_sketchId != null`, same as every other
  // mutating controller method) - covered instead in
  // sketch_controller_test.dart, which already has a fake-backend harness
  // set up via ensureSketch().

  test('a two-Point selection still offers nothing new (Radius stays Circle/Arc-only)', () {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 1, y: 1);
    controller.selectEntity(const SketchSelection(kind: SelectionKind.point, id: 'center'));
    controller.selectEntity(const SketchSelection(kind: SelectionKind.point, id: 'p2'));

    final options = controller.availableConstraintOptions;
    expect(options.any((o) => o.type == ConstraintOptionType.radius), isFalse);
  });
}
