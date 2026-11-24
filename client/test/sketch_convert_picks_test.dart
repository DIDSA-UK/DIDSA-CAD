import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/selection_filter.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';

/// Bug report 2026-11-18, plan part C3: Convert Entities' client picks - the drawn entities of another sketch in the viewport. (A sketch row in
/// the sketcher's feature tree is in `sketch_feature_tree_test.dart`.) (The controller side - staging, the Tick, every shape drawn, one-step undo - is in `sketch_controller_test.dart`.)
/// Not covered here: a real tap through the GPU viewport (a headless test cannot render the scene); the viewport's own hit test is covered at the
/// function it calls (`hitTestBodies`), and the screen's handler through the viewport's callbacks.
Future<SketchController> _freshController() async {
  final mockClient = MockClient((request) async {
    if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
      return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201);
    }
    return http.Response('not found: ${request.method} ${request.url.path}', 404);
  });
  final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
  await controller.ensureSketch();
  return controller;
}

Future<void> _settlePartViewport(WidgetTester tester, {int maxPumps = 100}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('the other sketches in the viewport', () {
    Future<(SketchController, PartViewport Function())> openOrbit(WidgetTester tester) async {
      final controller = await _freshController();
      await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
      for (var i = 0; i < 50; i++) {
        if (find.byType(PartViewport).evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 20));
      }
      await _settlePartViewport(tester);
      return (controller, () => tester.widget<PartViewport>(find.byType(PartViewport)));
    }

    testWidgets("the viewport picks other sketches' geometry only in Convert mode", (tester) async {
      final (controller, viewport) = await openOrbit(tester);
      expect(viewport().preferEntityPickIncludesOtherSketches, isFalse);

      controller.enterConvertEntitiesMode();
      await tester.pump();
      expect(viewport().preferEntityPick, isTrue);
      expect(viewport().preferEntityPickIncludesOtherSketches, isTrue);

      controller.enterDimensionMode();
      await tester.pump();
      expect(viewport().preferEntityPickIncludesOtherSketches, isFalse);
      controller.enterOffsetMode();
      await tester.pump();
      expect(viewport().preferEntityPickIncludesOtherSketches, isFalse);
    });

    testWidgets('a pick of another sketch\'s entity stages it (a pattern copy by its expanded id); a later sketch is refused with a message',
        (tester) async {
      final (controller, viewport) = await openOrbit(tester);
      controller.convertSourceSketchFeatureIds = {'early'};
      controller.enterConvertEntitiesMode();
      await tester.pump();
      final tap = viewport().onSketchEntityTap!;

      tap(const SelectionEntityRef(kind: SelectionEntityKind.sketchLine, sketchFeatureId: 'early', sketchEntityId: 'line-a'));
      tap(const SelectionEntityRef(kind: SelectionEntityKind.sketchCircle, sketchFeatureId: 'early', sketchEntityId: 'inst-1#2#circle-b'));
      tap(const SelectionEntityRef(kind: SelectionEntityKind.sketchPoint, sketchFeatureId: 'early', sketchEntityId: 'point-c'));
      expect(controller.pendingConvertSketchEntities, [('early', 'line-a'), ('early', 'inst-1#2#circle-b'), ('early', 'point-c')]);

      tap(const SelectionEntityRef(kind: SelectionEntityKind.sketchSpline, sketchFeatureId: 'later', sketchEntityId: 'spline-z'));
      await tester.pump();
      expect(controller.pendingConvertSketchEntities, hasLength(3));
      expect(controller.errorMessage, SketchController.convertSourceAfterSketchMessage);
      expect(find.text(SketchController.convertSourceAfterSketchMessage), findsOneWidget);
    });

    testWidgets('outside Convert mode a pick of another sketch\'s entity stages nothing', (tester) async {
      final (controller, viewport) = await openOrbit(tester);
      controller.enterDimensionMode();
      await tester.pump();
      viewport().onSketchEntityTap!(
        const SelectionEntityRef(kind: SelectionEntityKind.sketchLine, sketchFeatureId: 'early', sketchEntityId: 'line-a'),
      );
      expect(controller.hasPendingConvertSelection, isFalse);
    });

    test("the viewport's hit test (what preferEntityPickIncludesOtherSketches turns on) finds another sketch's entity with the id the backend knows", () {
      // One other sketch ('early') with a Line, and a Circle that is a pattern copy (expanded id), drawn in the z = 0 plane.
      final geometry = SketchGeometry3D(
        lineSegments: [(vm.Vector3(-1, 0, 0), vm.Vector3(1, 0, 0))],
        lineIds: const ['line-a'],
        points: const [],
        pointIds: const [],
        circlePolygons: [
          [for (var i = 0; i <= 32; i++) vm.Vector3(5 + 2 * i / 32 - 1, 3, 0)],
        ],
        circleIds: const ['inst-1#2#circle-b'],
      );
      final viewportSize = const Size(800, 600);
      HoverHit? pickAt(double x, double y, {Map<String, SketchGeometry3D>? sketches}) => hitTestBodies(
            ray: vm.Ray.originDirection(vm.Vector3(x, y, -10), vm.Vector3(0, 0, 1)),
            viewportSize: viewportSize,
            bodies: const [],
            sketchGeometries: sketches ?? {'early': geometry},
            filter: const SelectionFilterState(vertex: true, edge: true, face: true, body: false),
          );

      final line = pickAt(0, 0)!;
      expect(line.entity.kind, SelectionEntityKind.sketchLine);
      expect(line.entity.sketchFeatureId, 'early');
      expect(line.entity.sketchEntityId, 'line-a');
      final circle = pickAt(5, 3)!;
      expect(circle.entity.kind, SelectionEntityKind.sketchCircle);
      expect(circle.entity.sketchEntityId, 'inst-1#2#circle-b');
      // With none handed over (the default when the flag is off) nothing of any sketch is hit.
      expect(pickAt(0, 0, sketches: const {}), isNull);
    });
  });
}
