import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/sketch/sketch_speed_dial.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';

/// Phase 4.2's Orbit View toggle. A minimal fake backend - [ensureSketch]
/// only ever calls `POST /sketch/sketches` (see
/// `SketchController._adoptSketchDto`, which needs nothing else to set
/// `plane`), so nothing further is stubbed.
http.Response _handle(http.Request request) {
  if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
    return http.Response(
      jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}),
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

void main() {
  testWidgets('the Orbit View toggle FAB appears once the sketch plane has loaded', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();

    expect(find.byTooltip('Orbit View'), findsOneWidget);
  });

  testWidgets(
      'tapping Orbit View swaps the flat 2D SketchCanvas for a read-only 3D PartViewport, '
      'and tapping it again (now "Exit Orbit View") swaps back', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();

    expect(find.byType(SketchCanvas), findsOneWidget);
    expect(find.byType(PartViewport), findsNothing);

    await tester.tap(find.byTooltip('Orbit View'));
    await tester.pump();

    expect(find.byType(SketchCanvas), findsNothing);
    expect(find.byType(PartViewport), findsOneWidget);
    expect(find.byTooltip('Exit Orbit View'), findsOneWidget);

    await tester.tap(find.byTooltip('Exit Orbit View'));
    await tester.pump();

    expect(find.byType(SketchCanvas), findsOneWidget);
    expect(find.byType(PartViewport), findsNothing);
  });

  testWidgets(
      'while Orbit View is active, editing controls are hidden and the "Return to Default View" '
      'button replaces the draw/dimension speed dial', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();

    expect(find.byType(SketchSpeedDial), findsOneWidget);
    expect(find.byTooltip('Return to Default View'), findsNothing);

    await tester.tap(find.byTooltip('Orbit View'));
    await tester.pump();

    expect(find.byType(SketchSpeedDial), findsNothing);
    expect(find.byTooltip('Return to Default View'), findsOneWidget);
    expect(find.byTooltip('Drag mode off - tap to drag entities'), findsNothing);
  });
}
