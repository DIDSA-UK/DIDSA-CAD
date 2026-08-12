import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

/// On-device follow-up ("check the screenshot, the patterned circle under
/// the cursor is not highlighted and will not select"): the screenshot
/// turned out to be the embedded 3D (Orbit View) sketch editor, a wholly
/// separate rendering/hit-test pipeline (`PartViewport`, GPU-based) from
/// `sketch_canvas.dart`'s own flat 2D `CustomPainter` canvas, which had
/// already been fixed for the identical complaint there - Pattern/Mirror
/// instance selection had never been wired up for the embedded 3D view at
/// all (explicitly called out as a known gap in the old
/// `_embeddedSelectionEntityKind`'s own doc comment). This is a real widget
/// test (mounts the actual `SketchScreen` in Orbit View, not just
/// `SketchController`) verifying the id-resolution glue
/// (`_handleEmbeddedSelectionToggle`) that converts a 3D ray-hit back into
/// a real `SketchController` selection - the ray-hit-testing math itself is
/// covered separately and more thoroughly by `selection_hit_test_test.dart`.
///
/// Nav/UI cleanup: Orbit View is now the unconditional default for a
/// Part-anchored `SketchScreen` (the old `SketcherPreferences.use3DSketcher`
/// device setting this test used to force is gone entirely - see
/// `sketch_screen.dart`'s own `_loadInitialOrbitViewPreference`), so this
/// test no longer needs to opt into it.
http.Response _handle(http.Request request) {
  if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
    return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201);
  }
  if (request.url.path == '/sketch/sketches/sketch-1/orientation' && request.method == 'PATCH') {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        'id': 'sketch-1',
        'plane': 'XY',
        'origin_point_id': 'origin-1',
        'flip': body['flip'],
        'rotation_quarter_turns': body['rotation_quarter_turns'],
      }),
      200,
    );
  }
  if (request.url.path == '/sketch/sketches/sketch-1/pattern-instances' && request.method == 'POST') {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        'id': 'pat-1',
        'source_entity_ids': body['source_entity_ids'],
        'direction_1': body['direction_1'],
        'count_1': body['count_1'],
        'spacing_1': body['spacing_1'],
        'reverse_1': body['reverse_1'] ?? false,
        'direction_2': null,
        'count_2': 1,
        'spacing_2': 0.0,
        'reverse_2': false,
      }),
      201,
    );
  }
  return http.Response('not found: ${request.method} ${request.url.path}', 404);
}

Future<SketchController> _freshController() async {
  final mockClient = MockClient((request) async => _handle(request));
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
  testWidgets(
    'tapping a committed pattern instance\'s own derived copy in the embedded 3D view '
    'selects it (SelectionKind.patternInstance), the same way the flat 2D canvas already does',
    (tester) async {
      final controller = await _freshController();

      controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
      controller.points['p1'] = const SketchPointView(id: 'p1', x: 10, y: 0);
      controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');

      controller.enterPatternMode();
      await controller.handleCanvasTap(5, 0);
      controller.finishPatternPick();
      controller.setPatternDirectionFixedAxis('x');
      controller.setPatternSpacing1(5.0);
      controller.setPatternCount1(3);
      await controller.confirmPatternMirrorPreview();
      expect(controller.patternInstances, hasLength(1));
      final instanceId = controller.patternInstances.keys.single;

      controller.exitToSelectMode();
      expect(controller.mode, SketchMode.select);

      await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
      for (var i = 0; i < 50; i++) {
        if (find.byType(PartViewport).evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 20));
      }
      await _settlePartViewport(tester);
      expect(tester.takeException(), isNull);

      final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      // Feeds real geometry into a hit-test in every other test file - here
      // we only need the id-resolution glue (_handleEmbeddedSelectionToggle),
      // already isolated and covered by `selection_hit_test_test.dart` for
      // the ray-math itself, so the callback is invoked directly with the
      // shape a real ray-hit would have produced.
      expect(viewport.patternMirrorGhostSegments, contains(instanceId));
      viewport.onSelectionToggle!(SelectionEntityRef(
        kind: SelectionEntityKind.sketchPatternMirrorInstance,
        sketchFeatureId: viewport.patternMirrorSketchFeatureId,
        sketchEntityId: instanceId,
      ));

      expect(controller.selectionSet, hasLength(1));
      expect(controller.selectionSet.single.kind, SelectionKind.patternInstance);
      expect(controller.selectionSet.single.id, instanceId);
    },
  );
}
