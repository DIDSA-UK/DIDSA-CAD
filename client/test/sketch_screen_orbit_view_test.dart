import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';

/// Phase 4.2's Orbit View toggle (the 3D-embedded sketcher). A minimal fake
/// backend - [ensureSketch] only ever calls `POST /sketch/sketches` (see
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

// Nav/UI cleanup: the device-wide "default sketcher" setting (CAD Settings'
// own 2D-canvas/3D-embedded SegmentedButton, backed by the now-removed
// `SketcherPreferences`) used to be the only way a Sketch ever entered
// Orbit View - `SketchScreen._loadInitialOrbitViewPreference` read it on
// every load, and the in-session FAB only ever toggled cursor/orbit
// sub-mode once already inside Orbit View, never entering or exiting it
// outright (see the removed tests that used to live here, in this same
// file's own git history). With that setting gone, a part-embedded Sketch
// always opens on the flat 2D canvas - the same widget the standalone "2D
// Drawing" tool already builds on - and Orbit View itself has no remaining
// entry point. Every test below that exercised the embedded 3D (Orbit
// View) sketch editor was removed rather than patched, since there is no
// longer any way to reach that state through `SketchScreen`'s public API;
// the underlying `PartViewport`-embedding code itself was left in place
// (unreachable, not deleted - see that decision's own rationale in the nav
// cleanup's commit message) since it doubles as shared rendering
// infrastructure this cleanup didn't want to risk touching.
void main() {
  testWidgets(
      'a Sketch never enters Orbit View any more - standalone or Part-anchored, it always opens '
      'on the flat 2D canvas', (tester) async {
    final controller = await _freshController();
    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller, standalone: true)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SketchCanvas), findsOneWidget);
    expect(find.byType(PartViewport), findsNothing);
  });

  testWidgets(
      'a standalone SketchScreen\'s hamburger menu offers Save/Open/Exit for this Sketch\'s own file, '
      'unlike an ordinary (Part-anchored) SketchScreen, which has none of them', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller, standalone: true)));
    await tester.pump();
    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Exit'), findsOneWidget);
  });

  testWidgets('an ordinary (Part-anchored) SketchScreen\'s hamburger menu has no Save/Open/Exit entries',
      (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();
    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    expect(find.text('Save'), findsNothing);
    expect(find.text('Open'), findsNothing);
    expect(find.text('Exit'), findsNothing);
  });

  testWidgets(
      'nav cleanup regression: the top-right "Exit Sketch" FAB shows for an embedded '
      '(Part-anchored) SketchScreen, which is always reached via Navigator.push so .pop() has '
      'somewhere to return to', (tester) async {
    final controller = await _freshController();
    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    await tester.pump();
    expect(find.byTooltip('Exit Sketch'), findsOneWidget);
  });

  testWidgets(
      'nav cleanup regression: the standalone "2D Drawing" tool has no top-right "Exit Sketch" FAB '
      '- a bare .pop() there used to have nothing on the stack to return to (see the standalone '
      'File menu\'s Exit entry instead)', (tester) async {
    final controller = await _freshController();
    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller, standalone: true)));
    await tester.pump();
    expect(find.byTooltip('Exit Sketch'), findsNothing);
  });

  testWidgets(
      'nav cleanup regression: the standalone File menu\'s Exit entry pops back to whatever '
      'pushed this SketchScreen (ToolChooserScreen in the real app)', (tester) async {
    final controller = await _freshController();

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SketchScreen(controller: controller, standalone: true)),
              ),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    expect(find.byType(SketchScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    await tester.tap(find.text('Exit'));
    await tester.pumpAndSettle();

    expect(find.byType(SketchScreen), findsNothing);
    expect(find.text('start'), findsOneWidget);
  });

  testWidgets(
      'the Hide Reference Body toggle flips SketchCanvas.referenceBodyHidden, which gates the '
      'projected reference-body ghost overlay drawn on the canvas itself', (tester) async {
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
