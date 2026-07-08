import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';

http.Response _jsonResponse(Map<String, dynamic> body, {int statusCode = 200}) =>
    http.Response(jsonEncode(body), statusCode);

void main() {
  testWidgets('App boots, creates a sketch on startup, and shows controls', (tester) async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
        return _jsonResponse(
          {'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'},
          statusCode: 201,
        );
      }
      return http.Response('not found', 404);
    });

    final controller = SketchController(api: SketchApiClient(httpClient: mockClient));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SketchCanvas(controller: controller)),
            ],
          ),
        ),
      ),
    );

    await controller.ensureSketch();
    await tester.pump();

    expect(controller.sketchId, 'sketch-1');
    expect(controller.errorMessage, isNull);
  });

  testWidgets('SketchScreen collapses to a single main FAB and expands into tool actions on tap', (tester) async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
        return _jsonResponse(
          {'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'},
          statusCode: 201,
        );
      }
      return http.Response('not found', 404);
    });
    final controller = SketchController(api: SketchApiClient(httpClient: mockClient));

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();

    // Collapsed: only the main toggle FAB ("+") shows - the two-level
    // Categories/Sketch Entities menu (SketchSpeedDial's own FabMenuState)
    // has nothing else rendered until it's opened.
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byTooltip('Line').hitTestable(), findsNothing);
    expect(find.byTooltip('Circle').hitTestable(), findsNothing);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    // First level: categories, not individual tools yet.
    expect(find.byTooltip('Sketch Entities').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Dimensions').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Circle').hitTestable(), findsNothing);

    await tester.tap(find.byTooltip('Sketch Entities').hitTestable());
    await tester.pump();

    // Second level: the individual tools, reached via Sketch Entities.
    expect(find.byTooltip('Line').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Circle').hitTestable(), findsOneWidget);
    // No chain in progress yet, so there is nothing to Finish.
    expect(find.byTooltip('Finish').hitTestable(), findsNothing);

    await tester.tap(find.byTooltip('Circle').hitTestable());
    await tester.pump();
    expect(controller.activeTool, SketchTool.circle);
  });
}
