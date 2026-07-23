import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/sketch/sketch_speed_dial.dart';
import 'package:didsa_cad_client/sketch/sketcher_preferences.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/render_mode.dart';
import 'package:didsa_cad_client/viewport3d/selection_filter.dart';

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

/// P19 on-device feedback: entering Orbit View is no longer a live,
/// in-session FAB tap (see [SketchScreen._orbitCursorActive]'s own doc
/// comment) - it now happens purely from [SketcherPreferences.use3DSketcher]
/// during [SketchScreen.initState]'s own async
/// `_loadInitialOrbitViewPreference`. Pumps a mounted [SketchScreen] until
/// [PartViewport] actually appears (bounded, condition-driven, mirroring
/// [_settlePartViewport] itself rather than `pumpAndSettle` - see that
/// helper's own doc comment for why `pumpAndSettle` isn't safe here), then
/// settles its GPU spinner the same way every other test in this file
/// already does.
Future<void> _openInOrbitView(WidgetTester tester, SketchController controller) async {
  SharedPreferences.setMockInitialValues({SketcherPreferences.use3DSketcherPrefKey: true});
  await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
  for (var i = 0; i < 50; i++) {
    if (find.byType(PartViewport).evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 20));
  }
  await _settlePartViewport(tester);
}

void main() {
  testWidgets(
      'a standalone SketchScreen (the "2D Drawing" tool) never enters Orbit View, even when '
      'use3DSketcher is set - that default is for in-Part sketching, not a flat drafting tool '
      'with no Bodies/planes of its own to show', (tester) async {
    final controller = await _freshController();
    SharedPreferences.setMockInitialValues({SketcherPreferences.use3DSketcherPrefKey: true});
    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller, standalone: true)));
    // Bounded settle, same reasoning as _openInOrbitView's own doc comment -
    // long enough for _loadInitialOrbitViewPreference's async load to
    // resolve if it were going to act, short of anything that would need
    // PartViewport's own un-mockable GPU init to actually finish.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(PartViewport), findsNothing);
  });

  testWidgets(
      'a standalone SketchScreen\'s hamburger menu offers Save/Open for this Sketch\'s own file, '
      'unlike an ordinary (Part-anchored) SketchScreen, which has neither', (tester) async {
    final controller = await _freshController();
    SharedPreferences.setMockInitialValues({SketcherPreferences.use3DSketcherPrefKey: false});

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller, standalone: true)));
    await tester.pump();
    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('an ordinary (Part-anchored) SketchScreen\'s hamburger menu has no Save/Open entries',
      (tester) async {
    final controller = await _freshController();
    SharedPreferences.setMockInitialValues({SketcherPreferences.use3DSketcherPrefKey: false});

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();
    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    expect(find.text('Save'), findsNothing);
    expect(find.text('Open'), findsNothing);
  });

  testWidgets(
      'the orbit/cursor toggle FAB appears once Orbit View is active (driven by the '
      'use3DSketcher preference, not a live enter/exit tap), starting in cursor sub-mode and '
      'flipping PartViewport.selectionMode off when swapped to orbit sub-mode', (tester) async {
    final controller = await _freshController();
    await _openInOrbitView(tester, controller);

    expect(find.byType(PartViewport), findsOneWidget);
    // "Cursor-first": P16-P18's cursor+ghost+commit model is active on
    // entry. On-device feedback ("point tool shouldn't start when opening
    // a sketch"): _enterOrbitView no longer force-selects the Point tool,
    // so entry stays in SketchMode.select (selectionMode), not
    // SketchMode.draw (drawCursorMode) - see _enterOrbitView's own doc
    // comment.
    expect(find.byTooltip('Switch to Orbit'), findsOneWidget);
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectionMode, isTrue);
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).drawCursorMode, isFalse);

    await tester.tap(find.byTooltip('Switch to Orbit'));
    await tester.pump();
    // Lets the FAB's own tap-ripple (InkSparkle) animation finish inside
    // this test, rather than leaving a live Ticker for the next test in
    // this file to trip over (both share one SchedulerBinding for the
    // whole isolate) - a bounded settle, not `pumpAndSettle` (see
    // `_settlePartViewport`'s own doc comment for why that's unsafe here).
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byTooltip('Switch to Cursor'), findsOneWidget);
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectionMode, isFalse);

    await tester.tap(find.byTooltip('Switch to Cursor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byTooltip('Switch to Orbit'), findsOneWidget);
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectionMode, isTrue);
  });

  // P19 on-device feedback: "the orbit button is supposed to swap between
  // cursor control and orbit mode" - the FAB that used to enter/exit Orbit
  // View outright (tested by two removed tests that lived here: one
  // exercising the return-to-plane exit animation, one exercising a
  // leave-then-re-enter body-opacity reset) was repurposed to toggle
  // SketchScreen._orbitCursorActive instead (see that field's own doc
  // comment for the full rationale, including why SketcherPreferences.
  // use3DSketcher is now the only way back to the flat 2D canvas). Neither
  // an exit animation nor a leave-then-re-enter cycle exist to test any
  // more within one mounted SketchScreen - removed rather than patched, no
  // replacement needed since the underlying behaviour is gone, not
  // relocated.

  testWidgets(
      'the embedded PartViewport starts facing the sketch\'s own plane (so entering Orbit View '
      'never visibly jumps the camera) and defaults to Shaded + Edges, matching on-device '
      'feedback that edges should be visible', (tester) async {
    final controller = await _freshController();
    await _openInOrbitView(tester, controller);

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
      'sketcher restructure Phase 2 / P20: while Orbit View is active, the tool speed dial stays '
      'available (restricted to every tool except Text) rather than being replaced, and "Return '
      'to Default View" appears alongside the orbit/cursor toggle instead of occupying the speed '
      'dial\'s slot', (tester) async {
    final controller = await _freshController();
    await _openInOrbitView(tester, controller);

    expect(find.byType(SketchSpeedDial), findsOneWidget);
    final speedDial = tester.widget<SketchSpeedDial>(find.byType(SketchSpeedDial));
    expect(speedDial.restrictToEmbeddedTools, isTrue);
    expect(find.byTooltip('Return to Default View'), findsOneWidget);
    // On-device feedback ("point tool shouldn't start when opening a
    // sketch"): Orbit View now starts in SketchMode.select, not
    // SketchMode.draw - the drag-mode FAB (Select-mode-only, and P24
    // on-device feedback made it reachable in Orbit View's own cursor
    // sub-mode too) is now visible on entry instead of hidden, the inverse
    // of what a Draw-mode default used to leave true here.
    expect(find.byTooltip('Drag mode off - tap to drag entities'), findsOneWidget);
  });

  testWidgets(
      'on-device feedback: while Orbit View is active, the hamburger menu offers the same '
      'View controls as the 3D viewport (render mode, body colour, transparency), and '
      'picking a render mode is reflected on the embedded PartViewport', (tester) async {
    final controller = await _freshController();
    await _openInOrbitView(tester, controller);

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
    // On-device feedback ("when I tap a sketch in the tree, it sends me to
    // the old 2d editor"): SketcherPreferences.defaultUse3DSketcher flipped
    // to true, so this test (which specifically wants the 2D-canvas path)
    // must force it explicitly now, rather than relying on the ambient
    // default - same convention _openInOrbitView's own doc comment already
    // established for the opposite case.
    SharedPreferences.setMockInitialValues({SketcherPreferences.use3DSketcherPrefKey: false});
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SketchCanvas), findsOneWidget);
    expect(find.byType(PartViewport), findsNothing);
  });

  testWidgets(
      'the Hide Reference Body toggle flips SketchCanvas.referenceBodyHidden, which gates the '
      'projected reference-body ghost overlay drawn on the canvas itself - its only remaining '
      'purpose now that there is no more shaded body backdrop to hide alongside it', (tester) async {
    // Same forced-2D reasoning as the test above - this one specifically
    // exercises SketchCanvas.referenceBodyHidden.
    SharedPreferences.setMockInitialValues({SketcherPreferences.use3DSketcherPrefKey: false});
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
    await tester.pump();

    expect(tester.widget<SketchCanvas>(find.byType(SketchCanvas)).referenceBodyHidden, isFalse);

    await tester.tap(find.byTooltip('Hide Reference Body'));
    await tester.pump();

    expect(tester.widget<SketchCanvas>(find.byType(SketchCanvas)).referenceBodyHidden, isTrue);
  });

  testWidgets(
      'bug fix (on-device feedback: "I still can\'t use the convert entities tool as it doesn\'t '
      'give me a cursor"): drawCursorMode is true for SketchMode.convert, matching every other '
      'Tools mode - it was missing from PartViewport\'s own gate despite a doc comment claiming '
      'otherwise', (tester) async {
    final controller = await _freshController();
    await _openInOrbitView(tester, controller);

    controller.enterConvertEntitiesMode();
    await tester.pump();

    expect(tester.widget<PartViewport>(find.byType(PartViewport)).drawCursorMode, isTrue);
  });

  testWidgets(
      'bug fix (on-device feedback: "when in selecting edges, vertices, faces to convert or '
      'offset, there should be dynamic highlight so the user knows what will need selected"): '
      'the hover selectionFilter now enables Body vertex/edge (and face, for Convert only) for '
      'Dimension/Convert/Offset, matching what the tap path already targets - it used to be '
      'permanently off, so nothing but Sketch entities ever hover-highlighted', (tester) async {
    final controller = await _freshController();
    await _openInOrbitView(tester, controller);

    SelectionFilterState currentFilter() =>
        tester.widget<PartViewport>(find.byType(PartViewport)).selectionFilter;

    // SketchMode.select (the default on entry): unchanged - Body geometry
    // was never a hover target here, only Sketch entities.
    expect(currentFilter().vertex, isFalse);
    expect(currentFilter().edge, isFalse);
    expect(currentFilter().face, isFalse);

    controller.enterDimensionMode();
    await tester.pump();
    expect(currentFilter().vertex, isTrue);
    expect(currentFilter().edge, isTrue);
    expect(currentFilter().face, isFalse);

    controller.enterConvertEntitiesMode();
    await tester.pump();
    expect(currentFilter().vertex, isTrue);
    expect(currentFilter().edge, isTrue);
    expect(currentFilter().face, isTrue);

    controller.enterOffsetMode();
    await tester.pump();
    expect(currentFilter().vertex, isTrue);
    expect(currentFilter().edge, isTrue);
    expect(currentFilter().face, isFalse);

    // Trim/Extend never references Body geometry at all - stays off.
    controller.enterTrimMode();
    await tester.pump();
    expect(currentFilter().vertex, isFalse);
    expect(currentFilter().edge, isFalse);
    expect(currentFilter().face, isFalse);
  });

  testWidgets(
      'on-device feedback: OffsetValueBar appears once picking is finished, drives a live ghost '
      'preview via typed distance, and disappears again once cancelled', (tester) async {
    final controller = await _freshController();
    await _openInOrbitView(tester, controller);

    controller.points['point-a'] = const SketchPointView(id: 'point-a', x: 0, y: 0);
    controller.points['point-b'] = const SketchPointView(id: 'point-b', x: 10, y: 0);
    controller.lines['line-a'] = const SketchLineView(id: 'line-a', startPointId: 'point-a', endPointId: 'point-b');
    controller.enterOffsetMode();
    await tester.pump();

    // Not visible yet - picking isn't finished.
    expect(find.widgetWithText(TextField, 'Distance'), findsNothing);

    await controller.handleCanvasTap(3, 0); // picks line-a, off its exact midpoint
    controller.finishOffsetChain();
    await tester.pump();

    expect(find.widgetWithText(TextField, 'Distance'), findsOneWidget);
    expect(controller.offsetPreviewGhosts, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, 'Distance'), '2');
    await tester.pump();

    expect(controller.offsetPreviewDistance, 2.0);
    expect(controller.offsetPreviewGhosts, hasLength(1));

    controller.cancelOffsetPreview();
    await tester.pump();

    expect(controller.offsetPreviewTargets, isNull);
    expect(find.widgetWithText(TextField, 'Distance'), findsNothing);
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
