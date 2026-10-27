import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';

/// Desktop layout D6 (`docs/desktop-layout-scope.md` section 3): the sketch
/// screen's ribbon and status bar, and the phone layout unchanged.
Future<SketchController> _pump(WidgetTester tester, {required bool desktop}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
  Widget home = SketchScreen(controller: controller);
  if (desktop) {
    home = LayoutModeScope(
      controller: LayoutModeController(
        preference: LayoutPreference.desktop,
        windowSize: const Size(1280, 800),
        mouseActive: true,
      ),
      child: home,
    );
  }
  await tester.pumpWidget(MaterialApp(home: home));
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('the phone layout keeps the speed dial and has no ribbon', (tester) async {
    await _pump(tester, desktop: false);
    expect(find.byKey(const ValueKey('desktop-ribbon')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-status-bar')), findsNothing);
    expect(find.byType(FloatingActionButton), findsWidgets);
    expect(find.byTooltip('Exit Sketch'), findsOneWidget);
  });

  testWidgets('the desktop layout shows the tool ribbon and status bar, and no speed dial or exit FAB', (tester) async {
    await _pump(tester, desktop: true);
    expect(find.byKey(const ValueKey('desktop-ribbon')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-status-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('ribbon-Line')), findsOneWidget);
    expect(find.byKey(const ValueKey('ribbon-Dimension')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-exit-sketch')), findsOneWidget);
    expect(find.byTooltip('Exit Sketch'), findsNothing);
    expect(find.text('Select'), findsOneWidget);
  });

  testWidgets('ribbon buttons pick the same tools the speed dial does, and show the active one', (tester) async {
    final controller = await _pump(tester, desktop: true);
    await tester.tap(find.byKey(const ValueKey('ribbon-Circle')));
    await tester.pump();
    expect(controller.mode, SketchMode.draw);
    expect(controller.activeTool, SketchTool.circle);
    expect(find.text('Draw: circle'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ribbon-Trim')));
    await tester.pump();
    expect(controller.mode, SketchMode.trim);
    expect(find.text('Trim / Extend'), findsOneWidget);
  });
}
