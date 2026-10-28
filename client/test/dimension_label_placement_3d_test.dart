import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';
import 'package:didsa_cad_client/viewport3d/screen_projection.dart';
import 'package:didsa_cad_client/viewport3d/sketch_constraint_overlay.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:didsa_cad_client/viewport3d/sketch_plane_hit_test.dart';
import 'package:flutter/widgets.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The 3D sketch view lays a dimension out from the same saved placement as the flat canvas: drag to a sketch point and the label is
/// drawn on that point, from any camera, so it stays attached to the geometry when the view orbits.
void main() {
  late SketchController controller;
  final basis = SketchPlaneBasis(
    origin: vm.Vector3.zero(),
    xAxis: vm.Vector3(1, 0, 0),
    yAxis: vm.Vector3(0, 1, 0),
    normal: vm.Vector3(0, 0, 1),
  );
  const viewportSize = Size(800, 600);
  final cameras = [
    OrthographicCamera(position: vm.Vector3(6, 4, 30), target: vm.Vector3.zero(), up: vm.Vector3(0, 1, 0), halfHeight: 30),
    OrthographicCamera(position: vm.Vector3(-20, 25, 18), target: vm.Vector3.zero(), up: vm.Vector3(0, 1, 0), halfHeight: 30),
    OrthographicCamera(position: vm.Vector3(30, -12, 14), target: vm.Vector3.zero(), up: vm.Vector3(0, 1, 0), halfHeight: 20),
  ];

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
    controller.lines['top'] = const SketchLineView(id: 'top', startPointId: 'e', endPointId: 'f');
    controller.circles['circle'] = const SketchCircleView(id: 'circle', centerPointId: 'ctr', radiusPointId: 'rim');
  });

  void dragTo(String id, (double, double) p) {
    expect(controller.beginLabelDrag(id), isTrue);
    controller.dragLabelToPointer(p.$1, p.$2);
    controller.endLabelDrag();
  }

  void expectLabelAt(String id, (double, double) p) {
    final item = controller.constraintOverlayItems().singleWhere((i) => i.constraintId == id);
    for (final camera in cameras) {
      final center = constraintOverlayItemLabelCenter(camera, viewportSize, basis, item);
      final wanted = worldToScreen(camera, viewportSize, sketchPointToWorld(basis, p.$1, p.$2))!;
      expect(center, isNotNull);
      expect(center!.dx, closeTo(wanted.dx, 1e-4), reason: '$id x from ${camera.position}');
      expect(center.dy, closeTo(wanted.dy, 1e-4), reason: '$id y from ${camera.position}');
    }
  }

  test('linear (diagonal), with the points either way round', () {
    for (final (a, b) in [('a', 'b'), ('b', 'a')]) {
      controller.constraints['dim'] = DistanceConstraintDto(id: 'dim', pointAId: a, pointBId: b, distance: 10.8);
      for (final p in [(3.0, 9.0), (14.0, -3.0), (-4.0, 6.0)]) {
        dragTo('dim', p);
        expectLabelAt('dim', p);
      }
    }
  });

  test('horizontal and vertical, with the points either way round', () {
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

  test('line to line', () {
    controller.constraints['dim'] = const LineDistanceConstraintDto(id: 'dim', line1Id: 'l1', line2Id: 'l2', distance: 5);
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

  test('radius and diameter', () {
    const radius = DistanceConstraintDto(id: 'dim', pointAId: 'ctr', pointBId: 'rim', distance: 5);
    controller.constraints['dim'] = radius;
    for (final p in [(-10.0, -4.0), (-26.0, -10.0), (-20.0, -22.0), (-18.0, -8.0)]) {
      dragTo('dim', p);
      expectLabelAt('dim', p);
    }
  });

  test('angle', () {
    controller.constraints['dim'] = const AngleConstraintDto(id: 'dim', line1Id: 'l1', line2Id: 'top', angleDegrees: 50);
    for (final p in [(14.0, 17.0), (18.0, 19.0), (12.0, 15.0)]) {
      dragTo('dim', p);
      expectLabelAt('dim', p);
    }
  });

  test('an unplaced dimension carries no sketch-unit placement, so each view keeps its own default', () {
    controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'a', pointBId: 'b', distance: 10.8);
    final item = controller.constraintOverlayItems().whereType<ConstraintLinearDimensionItem>().single;
    expect(item.sketchLocalOffsetDistance, isNull);
    expect(item.sketchLocalAlongOffset, isNull);
    expect(item.labelOffset, Offset.zero);
  });

  test('a mouse press-drag on the label from any camera: the label follows the pointer and keeps its place under it', () {
    controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'a', pointBId: 'b', distance: 10.8);
    // What the viewport does on a mouse press that drags: find the label under the press, take the plane point under the press and under
    // the label's centre, grab with the difference, then feed the plane point under the pointer for every move.
    (double, double) planePoint(OrthographicCamera camera, Offset screen) {
      final hit = hitTestSketchPlane(camera.screenPointToRay(screen, viewportSize), basis)!;
      return worldPointToSketch(basis, hit.$1);
    }

    for (final camera in cameras) {
      controller.setLabelPlacementForTesting('dim', null);
      var items = controller.constraintOverlayItems();
      final labelScreen = constraintOverlayItemLabelCenter(camera, viewportSize, basis, items.single)!;
      final press = labelScreen + const Offset(7, 3); // off-centre, still on the chip
      expect(constraintOverlayItemAt(camera, viewportSize, basis, items, press), 'dim');

      final pressSketch = planePoint(camera, press);
      final labelSketch = planePoint(camera, labelScreen);
      expect(controller.beginLabelDrag('dim', grabOffset: (labelSketch.$1 - pressSketch.$1, labelSketch.$2 - pressSketch.$2)), isTrue);
      var pointer = press;
      for (final step in [const Offset(15, -10), const Offset(25, -20), const Offset(40, -25)]) {
        pointer = press + step;
        final moved = planePoint(camera, pointer);
        controller.dragLabelToPointer(moved.$1, moved.$2);
      }
      controller.endLabelDrag();

      items = controller.constraintOverlayItems();
      final after = constraintOverlayItemLabelCenter(camera, viewportSize, basis, items.single)!;
      expect(after.dx, closeTo(labelScreen.dx + 40, 1e-4), reason: 'from ${camera.position}');
      expect(after.dy, closeTo(labelScreen.dy - 25, 1e-4), reason: 'from ${camera.position}');
    }
  });

  test('orbiting after a drag does not move the label off its place on the geometry', () {
    controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'a', pointBId: 'b', distance: 10.8);
    dragTo('dim', (3.0, 9.0));
    final item = controller.constraintOverlayItems().single;
    // Same sketch point, every camera: that is "attached to the geometry" - the check above, from a camera that did not do the dragging.
    for (final camera in cameras) {
      final centre = constraintOverlayItemLabelCenter(camera, viewportSize, basis, item)!;
      final wanted = worldToScreen(camera, viewportSize, sketchPointToWorld(basis, 3.0, 9.0))!;
      expect((centre - wanted).distance, lessThan(1e-4));
    }
  });
}
