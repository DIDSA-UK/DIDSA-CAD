import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';

/// Desktop input D3 (`docs/desktop-input-scope.md` R3): the sketch screen's
/// keyboard shortcuts - tool keys, Esc back to Select, Esc on an open
/// sketch bar, Ctrl+A.
Future<SketchController> _pumpSketch(WidgetTester tester) async {
  final mockClient = MockClient((request) async {
    if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
      return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201);
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
  return controller;
}

void main() {
  testWidgets('L / C pick the Line and Circle tools; Esc goes back to Select', (tester) async {
    final controller = await _pumpSketch(tester);
    expect(controller.mode, SketchMode.select);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(controller.mode, SketchMode.draw);
    expect(controller.activeTool, SketchTool.line);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(controller.activeTool, SketchTool.circle);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.mode, SketchMode.select);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+A selects all; Esc clears it', (tester) async {
    final controller = await _pumpSketch(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.selectionSet, isNotEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.selectionSet, isEmpty);
  });

  testWidgets('Esc cancels an open sketch bar (the Pattern bar) like its Cancel button', (tester) async {
    final controller = await _pumpSketch(tester);
    controller.enterPatternMode();
    await controller.handleCanvasTap(5, 0);
    controller.finishPatternPick();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('patternValueBarResizableArea')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('patternValueBarResizableArea')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
