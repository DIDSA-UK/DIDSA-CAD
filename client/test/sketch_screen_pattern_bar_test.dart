import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';

/// On-device feedback ("start sketch pattern tool > select entities>
/// confirm selection > nothing happens, no toolbar appears"): [PatternValueBar]
/// (`sketch_pattern_bar.dart`) was rebuilt on the shared `ResizableToolPanel`
/// (see that class's own doc comment), which needs a genuinely *bounded*
/// incoming height from its parent - `sketch_screen.dart`'s own bar area used
/// to be a shrink-wrapped `Positioned(left, right, bottom)` with no `top`,
/// which handed it unbounded height and threw a layout exception, silently
/// aborting the whole bar's build. Fixed in `sketch_screen.dart` by making
/// that `Positioned` fill the whole body and individually bottom-`Align`ing
/// every *other* bar to keep their own previous shrink-wrapped sizing. This
/// is a real widget test (mounts the actual [SketchScreen]/[PatternValueBar]
/// tree), not just a `SketchController`-level one, since the bug was purely
/// in that layout wiring, invisible to controller-only tests.
void main() {
  testWidgets(
    'finishing a Pattern pick actually renders the PatternValueBar (regression: used to silently show nothing)',
    (tester) async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}),
            201,
          );
        }
        return http.Response('not found: ${request.method} ${request.url.path}', 404);
      });
      final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
      await controller.ensureSketch();

      controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
      controller.points['p1'] = const SketchPointView(id: 'p1', x: 10, y: 0);
      controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');

      await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
      await tester.pump();

      controller.enterPatternMode();
      await controller.handleCanvasTap(5, 0);
      expect(controller.selectionSet, hasLength(1));
      controller.finishPatternPick();
      expect(controller.patternPreviewTargets, hasLength(1));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(tester.takeException(), isNull);
      expect(find.text('Pattern'), findsWidgets);
      expect(find.byKey(const Key('patternValueBarResizableArea')), findsOneWidget);
    },
  );

  testWidgets(
    'on-device feedback fix ("the text input lines for count and spacing are miss aligned"): '
    'the Count and Spacing fields render at the same vertical position',
    (tester) async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}),
            201,
          );
        }
        return http.Response('not found: ${request.method} ${request.url.path}', 404);
      });
      final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
      await controller.ensureSketch();

      controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
      controller.points['p1'] = const SketchPointView(id: 'p1', x: 10, y: 0);
      controller.lines['l0'] = const SketchLineView(id: 'l0', startPointId: 'p0', endPointId: 'p1');

      await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
      await tester.pump();

      controller.enterPatternMode();
      await controller.handleCanvasTap(5, 0);
      controller.finishPatternPick();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final countField = find.widgetWithText(TextField, 'Count');
      final spacingField = find.widgetWithText(TextField, 'Spacing');
      expect(countField, findsOneWidget);
      expect(spacingField, findsOneWidget);
      // Two fields side by side in the same Row, both driven by an
      // identical `labelText`-only InputDecoration now (see
      // `sketch_pattern_bar.dart`'s own fix) - a mismatched decoration
      // (one `labelText`, the other `hintText`) used to give them
      // different heights/text baselines even though this same top-left
      // `dy` check would already catch it (Row centers unequal-height
      // children, so a height mismatch always shows up here first).
      expect(tester.getTopLeft(countField).dy, tester.getTopLeft(spacingField).dy);
      expect(tester.getSize(countField).height, tester.getSize(spacingField).height);
    },
  );
}
