import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';

/// Part A of docs/bug-report-2026-11-18-plan.md, the item left open: the system back button (Android) goes back one dimension step, like Esc
/// and right-click, and only leaves the sketch once there is nothing to cancel. The test binding's `handlePopRoute` stands in for the button.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('back cancels the dimension editor, then the preview, and only then leaves the sketch', (tester) async {
    final controller = SketchController(
      api: SketchApiClient(
        httpClient: MockClient((request) async {
          if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
            return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201);
          }
          return http.Response('not found: ${request.method} ${request.url.path}', 404);
        }),
      ),
    );
    await controller.ensureSketch();
    controller.points['pa'] = const SketchPointView(id: 'pa', x: 2, y: 2);
    controller.points['pb'] = const SketchPointView(id: 'pb', x: 12, y: 7);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => SketchScreen(controller: controller, standalone: true)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SketchScreen), findsOneWidget);

    controller.enterDimensionMode();
    await controller.handleCanvasTap(2, 2);
    await controller.handleCanvasTap(12, 7);
    controller.dropPendingDimension();
    await tester.pump();
    expect(controller.activeGhostKey, isNotNull, reason: 'the value editor is open');

    // Back 1: editor -> live preview. The sketch stays.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(controller.activeGhostKey, isNull);
    expect(controller.pendingDimensionOptions, isNotEmpty);
    expect(find.byType(SketchScreen), findsOneWidget);

    // Back 2: preview -> picking.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(controller.pendingDimensionOptions, isEmpty);
    expect(controller.dimensionSelection, isEmpty);
    expect(find.byType(SketchScreen), findsOneWidget);

    // Back 3: nothing left to cancel, so the sketch is left.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SketchScreen), findsNothing);
  });

  testWidgets('outside the dimension tool back leaves the sketch at once', (tester) async {
    final controller = SketchController(
      api: SketchApiClient(
        httpClient: MockClient((request) async {
          if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
            return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201);
          }
          return http.Response('not found', 404);
        }),
      ),
    );
    await controller.ensureSketch();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => SketchScreen(controller: controller, standalone: true)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SketchScreen), findsNothing);
  });
}
