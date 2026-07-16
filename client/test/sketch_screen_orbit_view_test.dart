import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/sketch/sketch_speed_dial.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/render_mode.dart';

/// Phase 4.2's Orbit View toggle. A minimal fake backend - [ensureSketch]
/// only ever calls `POST /sketch/sketches` (see
/// `SketchController._adoptSketchDto`, which needs nothing else to set
/// `plane`), so nothing further is stubbed - plus, since Phase 5, the
/// orientation-picker sheet's own PATCH.
http.Response _handle(http.Request request) {
  if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
    return http.Response(
      jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}),
      201,
    );
  }
  // Sketcher-roadmap Phase 5: echoes back whatever flip/rotation_quarter_
  // turns was sent, same as the real backend's Sketch.set_orientation -
  // the mod-4 normalization itself is a domain-model concern already
  // tested at that layer (test_stage2_sketch.py's own orientation tests),
  // not re-verified through this fake.
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
  return http.Response('not found: ${request.method} ${request.url.path}', 404);
}

Future<SketchController> _freshController() async {
  final mockClient = MockClient((request) async => _handle(request));
  final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
  await controller.ensureSketch();
  return controller;
}

/// Mirrors `part_viewport_test.dart`'s own `_pumpUntil` helper: a
/// [PartViewport]'s `Scene.initializeStaticResources()` GPU setup is a real,
/// un-mockable async `Future` (it fails on this CI runner - no Impeller -
/// but still only resolves, one way or the other, after a real async gap),
/// so every test that mounts a [PartViewport] must pump until its loading
/// spinner clears *before* doing anything else (tapping, asserting, or
/// ending the test) - otherwise that `Future` resolves later, calls
/// `setState` on an already-disposed/reused Element, and throws into
/// whichever test happens to be running when it finally lands.
Future<void> _settlePartViewport(WidgetTester tester, {int maxPumps = 100}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Flushes `_exitOrbitView`'s `await animateToPlane(...)` to completion,
/// plus the `setState` that follows it - bounded, condition-driven pumping
/// (mirrors `_settlePartViewport`/`part_viewport_test.dart`'s own
/// `_pumpUntil`), not `pumpAndSettle`. `pumpAndSettle` actually timed out
/// here on CI: once the GPU/scene setup has failed, something keeps
/// scheduling further frames indefinitely (the same underlying class of
/// issue as `part_viewport_test.dart`'s own documented "Fix 4" flake,
/// presumably in flutter_scene/gpu's own error-path machinery) - "wait
/// until literally nothing is scheduled" never resolves, so this instead
/// waits only for the specific condition that matters: the widget tree
/// actually swapping back to [SketchCanvas].
Future<void> _pumpExitAnimation(WidgetTester tester, {int maxPumps = 50}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (find.byType(SketchCanvas).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
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
    await _settlePartViewport(tester);

    expect(find.byType(SketchCanvas), findsNothing);
    expect(find.byType(PartViewport), findsOneWidget);
    expect(find.byTooltip('Exit Orbit View'), findsOneWidget);

    // Exiting now animates the camera back to the plane before swapping
    // (see _exitOrbitView) - a single no-duration pump only advances one
    // frame, not enough for the 400ms default animateToPlane duration.
    await tester.tap(find.byTooltip('Exit Orbit View'));
    await _pumpExitAnimation(tester);

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
    await _settlePartViewport(tester);

    await tester.tap(find.byTooltip('Exit Orbit View'));
    await tester.pump(const Duration(milliseconds: 50)); // mid-animation

    expect(find.byType(PartViewport), findsOneWidget, reason: 'still animating back to the plane');
    expect(find.byType(SketchCanvas), findsNothing);

    await _pumpExitAnimation(tester); // animation completes

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
    await _settlePartViewport(tester);

    expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodyOpacity, 0.75);

    // Change transparency away from the default via the 3D View menu.
    // Drives the Slider/Apply button's own callbacks directly rather than
    // a synthetic drag/tap gesture at a computed screen position - the
    // Body Transparency bottom sheet's on-screen geometry proved
    // environment-fragile in this headless CI runner (consistently
    // positioned outside the hit-testable render tree regardless of the
    // test surface's size), and this is what's actually under test here
    // (does picking a new value and applying it change bodyOpacity, and
    // does re-entering Orbit View reset it) rather than pixel-perfect
    // gesture targeting.
    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    await tester.tap(find.text('Body Transparency'));
    await tester.pump();
    tester.widget<Slider>(find.byType(Slider)).onChanged!(80); // 80% transparency -> opacity 0.2
    await tester.pump();
    tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed!();
    await tester.pump();

    expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodyOpacity, isNot(0.75));

    // The hamburger menu panel/scrim stays open underneath the modal
    // bottom sheet - Apply only dismisses the sheet, not the menu itself
    // - so it needs closing explicitly before the "Exit Orbit View" FAB
    // underneath its scrim becomes tappable again.
    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();

    // Leave (through the return animation) and re-enter.
    await tester.tap(find.byTooltip('Exit Orbit View'));
    await _pumpExitAnimation(tester);
    await tester.tap(find.byTooltip('Orbit View'));
    await tester.pump();
    await _settlePartViewport(tester);

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
    await _settlePartViewport(tester);

    final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
    // initialViewPlane was generalized to initialViewBasis (a SketchPlaneBasis,
    // covering custom Feature-anchored planes too, not just the three fixed
    // ReferencePlaneKinds) - see PartViewport's own doc comment on the two
    // fields' relationship. A fixed XY sketch's basis is exactly
    // SketchPlaneBasis.fixed(ReferencePlaneKind.xy).
    final basis = viewport.initialViewBasis;
    expect(basis, isNotNull);
    expect(basis!.origin, vm.Vector3.zero());
    expect(basis.xAxis, vm.Vector3(1, 0, 0));
    expect(basis.yAxis, vm.Vector3(0, 1, 0));
    expect(basis.normal, vm.Vector3(0, 0, 1));
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
    await _settlePartViewport(tester);

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
    await _settlePartViewport(tester);

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
      'on-device feedback: outside Orbit View, no PartViewport is ever mounted - the shaded-body '
      'backdrop this used to check for was removed (a perspective camera synced to the flat, '
      'orthographic 2D canvas was an unfixable mismatch - see SketchScreen._buildBaseLayer\'s own '
      'doc comment); Orbit View is now the only place a Sketch\'s real Body geometry is shown',
      (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();

    expect(find.byType(SketchCanvas), findsOneWidget);
    expect(find.byType(PartViewport), findsNothing);
  });

  testWidgets(
      'the Hide Reference Body toggle flips SketchCanvas.referenceBodyHidden, which gates the '
      'projected reference-body ghost overlay drawn on the canvas itself - its only remaining '
      'purpose now that there is no more shaded body backdrop to hide alongside it', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(
      MaterialApp(
        home: SketchScreen(
          controller: controller,
          referenceGhostSegments: const [((0.0, 0.0), (1.0, 1.0))],
        ),
      ),
    );
    await tester.pump();

    expect(tester.widget<SketchCanvas>(find.byType(SketchCanvas)).referenceBodyHidden, isFalse);

    await tester.tap(find.byTooltip('Hide Reference Body'));
    await tester.pump();

    expect(tester.widget<SketchCanvas>(find.byType(SketchCanvas)).referenceBodyHidden, isTrue);
  });

  // The 'Sketch Orientation (Sketcher-roadmap Phase 5)' group that used to
  // live here tested a hamburger-menu 'Sketch Orientation' entry inside
  // *this* widget (SketchScreen). Task #95 ("Move sketch orientation UI:
  // hamburger -> tree long-press, use 3D viewport control") relocated it
  // entirely: the entry now lives in PartScreen's own Feature-tree
  // long-press context menu (feature_context_menu.dart's
  // showRedefineOrientation), opening the same 3D-viewport orientation-
  // confirm bottom sheet _addSketchFeature shows for a brand new Sketch
  // (rotate/flip/Continue-or-Done - see PartScreen's own
  // _confirmingSketchOrientation) - nothing under this widget offers it any
  // more. These 5 tests silently went stale (never caught until this
  // branch's first real CI run) rather than failing loudly, since
  // `find.text('Sketch Orientation')` just never matched here and every
  // assertion after it read as "not found" instead of surfacing the actual
  // relocation. Removed rather than patched; no replacement coverage exists
  // yet for the relocated flow - _FakeSketchBackend in part_screen_test.dart
  // doesn't stub the orientation PATCH endpoint at all, so writing one needs
  // that extended first. Flagged as a real gap, not silently dropped.
}
