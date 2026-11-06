import 'package:flutter_scene/scene.dart' show Node, PolylineCap;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:didsa_cad_client/viewport3d/view_preferences.dart';

/// Outlined sketch lines: the pure description of every sketch primitive (so the core and the dark outline copy are
/// built from one list), and the on/off preference. The GPU side (`buildSketchGeometryNode`) cannot run under
/// `flutter test`; what it looks like on screen can only be checked on a device.
void main() {
  group('sketch outline specs', () {
    final points = [
      PointDto(id: 'p1', x: 0, y: 0),
      PointDto(id: 'p2', x: 10, y: 0),
      PointDto(id: 'p3', x: 0, y: 10),
    ];
    final geometry = sketchGeometry3DFrom(
      basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
      points: points,
      lines: [
        LineDto(id: 'l1', startPointId: 'p1', endPointId: 'p2', length: 10),
        LineDto(id: 'l2', startPointId: 'p1', endPointId: 'p3', length: 10, construction: true),
      ],
      circles: [CircleDto(id: 'c1', centerPointId: 'p1', radiusPointId: 'p2', radius: 10)],
    );

    test('every primitive kind is described: solid, dashed construction, circle and point markers', () {
      final specs = sketchLineSpecsFor(geometry);
      // Solid line + circle, point markers (round caps), and the construction line as several dashes.
      expect(specs.where((s) => s.cap == PolylineCap.round), isNotEmpty);
      expect(specs.where((s) => s.width == sketchLineWidth && s.points.length > 2), isNotEmpty);
      expect(specs.length, greaterThan(5));
    });

    test('core colours: default grey, per-entity override, construction override', () {
      final specs = sketchLineSpecsFor(geometry, entityColors: {'l1': vm.Vector4(0, 1, 0, 1)});
      expect(specs.any((s) => s.color == vm.Vector4(0, 1, 0, 1)), isTrue);
      expect(specs.any((s) => s.color == sketchLineColor), isTrue);
    });

    test('outline list matches the core list one to one, 1.5 (2 x 0.75) pixels wider, dark', () {
      final core = sketchLineSpecsFor(geometry);
      final outline = sketchOutlineSpecsFor(core);
      expect(outline.length, core.length);
      for (var i = 0; i < core.length; i++) {
        expect(outline[i].width, closeTo(core[i].width + 1.5, 1e-9));
        expect(identical(outline[i].points, core[i].points) || outline[i].points == core[i].points, isTrue);
        expect(outline[i].cap, core[i].cap);
        expect(outline[i].color, sketchOutlineColor);
      }
    });

    test('outline constants', () {
      expect(sketchOutlinePixels, 0.75);
      expect(sketchOutlineColor, vm.Vector4(0.08, 0.08, 0.08, 1.0));
    });

    test('draw indicators get the same treatment', () {
      final markers = [
        DrawIndicatorMarker(point: vm.Vector3(1, 2, 3), color: sketchIndicatorAnchorColor, width: 7),
        DrawIndicatorMarker(point: vm.Vector3(4, 5, 6), color: sketchIndicatorSnapColor, width: 9),
      ];
      final core = drawIndicatorSpecsFor(markers);
      final outline = sketchOutlineSpecsFor(core);
      expect(core, isNotEmpty);
      expect(outline.length, core.length);
      expect(core.first.color, sketchIndicatorAnchorColor);
      expect(core.every((s) => s.cap == PolylineCap.round), isTrue);
      expect(outline.map((s) => s.width), core.map((s) => s.width + 1.5));
      expect(outline.every((s) => s.color == sketchOutlineColor), isTrue);
    });

    test('a bare Node can carry renderOrder -1 (no GPU needed)', () {
      final node = Node(name: 'sketch-f1-outline')..renderOrder = -1;
      expect(node.renderOrder, -1);
    });
  });

  group('ViewPreferences.sketchLineOutline', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to on, with the documented key', () async {
      await ViewPreferences.load();
      expect(ViewPreferences.defaultSketchLineOutline, isTrue);
      expect(ViewPreferences.sketchLineOutline, isTrue);
      expect(ViewPreferences.sketchLineOutlinePrefKey, 'view_sketch_line_outline');
    });

    test('round trips off and on', () async {
      await ViewPreferences.setSketchLineOutline(false);
      await ViewPreferences.load();
      expect(ViewPreferences.sketchLineOutline, isFalse);
      await ViewPreferences.setSketchLineOutline(true);
      await ViewPreferences.load();
      expect(ViewPreferences.sketchLineOutline, isTrue);
    });
  });
}
