import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/sketch/sketch_speed_dial.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/render_mode.dart';

BodyMeshDto _fakeBody() => BodyMeshDto(
      bodyId: 'body-1',
      source: 'test',
      mesh: MeshDto(
        vertices: [
          [0, 0, 0],
          [1, 0, 0],
          [0, 1, 0],
        ],
        normals: [
          [0, 0, 1],
          [0, 0, 1],
          [0, 0, 1],
        ],
        triangleIndices: [
          [0, 1, 2],
        ],
      ),
    );

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

    // Exiting now animates the camera back to the plane before swapping
    // (see _exitOrbitView) - a single no-duration pump only advances one
    // frame, not enough for the 400ms default animateToPlane duration.
    await tester.tap(find.byTooltip('Exit Orbit View'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(SketchCanvas), findsOneWidget);
    expect(find.byType(PartViewport), findsNothing);
  });

  testWidgets(
      'on-device feedback: leaving Orbit View keeps the PartViewport mounted (animating back to '
      'the plane) rather than cutting away instantly, only swapping to the 2D canvas once the '
      'return animation completes', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();
    await tester.tap(find.byTooltip('Orbit View'));
    await tester.pump();

    await tester.tap(find.byTooltip('Exit Orbit View'));
    await tester.pump(const Duration(milliseconds: 50)); // mid-animation

    expect(find.byType(PartViewport), findsOneWidget, reason: 'still animating back to the plane');
    expect(find.byType(SketchCanvas), findsNothing);

    await tester.pump(const Duration(milliseconds: 500)); // animation completes

    expect(find.byType(SketchCanvas), findsOneWidget);
    expect(find.byType(PartViewport), findsNothing);
  });

  testWidgets(
      'on-device feedback: entering Orbit View always resets body transparency to ~25%, even if '
      'a previous Orbit View session on this Sketch left it at a different value', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();
    await tester.tap(find.byTooltip('Orbit View'));
    await tester.pump();

    expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodyOpacity, 0.75);

    // Change transparency away from the default via the 3D View menu.
    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    await tester.tap(find.text('Body Transparency'));
    await tester.pump();
    // A large leftward drag clamps the slider to its minimum (0% transparency,
    // i.e. opacity 1.0) regardless of the sheet's exact rendered width.
    await tester.drag(find.byType(Slider), const Offset(-1000, 0));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pump();

    expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodyOpacity, isNot(0.75));

    // Leave (through the return animation) and re-enter.
    await tester.tap(find.byTooltip('Exit Orbit View'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Orbit View'));
    await tester.pump();

    expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodyOpacity, 0.75);
  });

  testWidgets(
      'the embedded PartViewport starts facing the sketch\'s own plane (so entering Orbit View '
      'never visibly jumps the camera) and defaults to Shaded + Edges, matching on-device '
      'feedback that edges should be visible', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();
    await tester.tap(find.byTooltip('Orbit View'));
    await tester.pump();

    final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
    expect(viewport.initialViewPlane, ReferencePlaneKind.xy);
    expect(viewport.renderMode, ViewportRenderMode.shadedWithEdges);
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

  testWidgets(
      'on-device feedback: while Orbit View is active, the hamburger menu offers the same '
      'View controls as the 3D viewport (render mode, body colour, transparency), and '
      'picking a render mode is reflected on the embedded PartViewport', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();
    await tester.tap(find.byTooltip('Orbit View'));
    await tester.pump();

    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();

    expect(find.text('3D View'), findsOneWidget);
    expect(find.text('Constraint Labels'), findsNothing); // the 2D-only menu is replaced, not stacked
    expect(find.text('Body Colour'), findsOneWidget);
    expect(find.text('Body Transparency'), findsOneWidget);
    expect(find.text('Wireframe'), findsOneWidget);

    await tester.tap(find.text('Wireframe'));
    await tester.pump();

    final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
    expect(viewport.renderMode, ViewportRenderMode.wireframe);
  });

  testWidgets(
      'on-device feedback: outside Orbit View, a Part\'s Body renders as a static shaded backdrop '
      'behind the 2D canvas (alongside it, not replacing it), and Canvas Transparency defaults to '
      '~25% so the backdrop is actually visible without the user hunting for the View menu',
      (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller, bodies: [_fakeBody()])));
    await tester.pump();

    expect(find.byType(SketchCanvas), findsOneWidget);
    expect(find.byType(PartViewport), findsOneWidget);
    expect(tester.widget<SketchCanvas>(find.byType(SketchCanvas)).canvasOpacity, 0.75);
  });

  testWidgets('a bodyless Sketch keeps the fully-opaque canvas default and shows no backdrop', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();

    expect(find.byType(PartViewport), findsNothing);
    expect(tester.widget<SketchCanvas>(find.byType(SketchCanvas)).canvasOpacity, 1.0);
  });

  testWidgets('the existing Hide Reference Body toggle also hides the shaded body backdrop', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(
      MaterialApp(
        home: SketchScreen(
          controller: controller,
          bodies: [_fakeBody()],
          referenceGhostSegments: const [((0.0, 0.0), (1.0, 1.0))],
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(PartViewport), findsOneWidget);

    await tester.tap(find.byTooltip('Hide Reference Body'));
    await tester.pump();

    expect(find.byType(PartViewport), findsNothing);
  });
}
