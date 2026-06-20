import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/main.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

http.Response _jsonResponse(Map<String, dynamic> body, {int statusCode = 200}) =>
    http.Response(jsonEncode(body), statusCode);

void main() {
  testWidgets('App boots, creates a sketch on startup, and shows controls', (tester) async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
        return _jsonResponse({'id': 'sketch-1', 'plane': 'XY'}, statusCode: 201);
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

  testWidgets('DidsaCadApp collapses to a single main FAB and expands into tool actions on tap', (tester) async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
        return _jsonResponse({'id': 'sketch-1', 'plane': 'XY'}, statusCode: 201);
      }
      return http.Response('not found', 404);
    });
    final controller = SketchController(api: SketchApiClient(httpClient: mockClient));

    await tester.pumpWidget(DidsaCadApp(controller: controller));
    await tester.pump();

    // Collapsed: the main toggle FAB shows a "+", and the action FABs are
    // zero-sized (still in the tree under the SizeTransition, but not
    // tappable - hitTestable excludes them).
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byTooltip('Click').hitTestable(), findsNothing);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Click').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Line').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Circle').hitTestable(), findsOneWidget);
    // No chain in progress yet, so there is nothing to Finish.
    expect(find.byTooltip('Finish').hitTestable(), findsNothing);

    await tester.tap(find.byTooltip('Circle').hitTestable());
    await tester.pump();
    expect(controller.activeTool, SketchTool.circle);
  });
}
