import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/viewport3d/part_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/render_mode.dart';
import 'package:didsa_cad_client/viewport3d/svg_icon.dart';

/// A tiny in-memory fake of the backend's `/document` API - just enough of
/// Part/Feature/mesh to drive [PartScreen] without a real network call.
/// Locking is simulated the same way the real backend enforces it: every
/// Feature except the most-recently-added one is locked.
class _FakeDocumentBackend {
  late int _nextFeatureId;
  final List<Map<String, dynamic>> features;

  // Starts past every seeded Feature's id (seeds are always "feature-N" in
  // creation order) so a newly-created Feature's id never collides with a
  // seeded one.
  _FakeDocumentBackend({List<Map<String, dynamic>>? seedFeatures}) : features = seedFeatures ?? [] {
    _nextFeatureId = features.length + 1;
  }

  static final Map<String, dynamic> _placeholderMesh = {
    'vertices': [
      [0.0, 0.0, 0.0],
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
    ],
    'normals': [
      [0.0, 0.0, 1.0],
      [0.0, 0.0, 1.0],
      [0.0, 0.0, 1.0],
    ],
    'triangle_indices': [
      [0, 1, 2],
    ],
  };

  http.Response handle(http.Request request) {
    final path = request.url.path;
    final method = request.method;
    final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;

    if (path == '/document/parts' && method == 'POST') {
      return _json({
        'id': 'part-1',
        'name': body['name'],
        'feature_ids': features.map((f) => f['id']).toList(),
      }, 201);
    }

    if (path == '/document/parts/part-1/mesh' && method == 'GET') {
      // Prompt A3: the backend (Prompt A1) now returns an array of Bodies -
      // this fake always returns the single-entry placeholder-box shape,
      // since none of these tests actually exercise real Extrude geometry.
      return _json([
        {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': _placeholderMesh},
      ], 200);
    }

    if (path == '/document/parts/part-1/features' && method == 'GET') {
      return _json(features.map((f) => f).toList(), 200);
    }

    if (path == '/document/parts/part-1/features/sketch' && method == 'POST') {
      // Mirror the real locking rule: adding a new Feature locks every
      // previous one, since only the last Feature in a Part stays editable.
      for (final feature in features) {
        feature['locked'] = true;
      }
      final feature = {
        'type': 'sketch',
        'id': 'feature-${_nextFeatureId++}',
        'sketch_id': 'sketch-$_nextFeatureId',
        'locked': false,
      };
      features.add(feature);
      return _json(feature, 201);
    }

    final cascadePreviewMatch =
        RegExp(r'^/document/parts/part-1/features/([^/]+)/cascade-preview$').firstMatch(path);
    if (cascadePreviewMatch != null && method == 'GET') {
      final featureId = cascadePreviewMatch.group(1);
      final index = features.indexWhere((f) => f['id'] == featureId);
      if (index == -1) {
        return http.Response('not found: feature', 404);
      }
      return _json({
        'feature_ids': features.sublist(index).map((f) => f['id']).toList(),
      }, 200);
    }

    final cascadeMatch = RegExp(r'^/document/parts/part-1/features/([^/]+)/cascade$').firstMatch(path);
    if (cascadeMatch != null && method == 'DELETE') {
      final featureId = cascadeMatch.group(1);
      final index = features.indexWhere((f) => f['id'] == featureId);
      if (index == -1) {
        return http.Response('not found: feature', 404);
      }
      final deleted = features.sublist(index);
      features.removeRange(index, features.length);
      // Mirror the real backend: the new last Feature (if any survive)
      // becomes unlocked again.
      if (features.isNotEmpty) {
        features.last['locked'] = false;
      }
      return _json({
        'deleted_feature_ids': deleted.map((f) => f['id']).toList(),
        'deleted_sketch_ids': deleted.map((f) => f['sketch_id']).toList(),
      }, 200);
    }

    if (path == '/document/parts/part-1/extrude-features' && method == 'POST') {
      for (final feature in features) {
        feature['locked'] = true;
      }
      final feature = {
        'type': 'extrude',
        'id': 'feature-${_nextFeatureId++}',
        'sketch_feature_id': body['sketch_feature_id'],
        'extrude_type': body['extrude_type'],
        'start_distance': body['start_distance'],
        'end_distance': body['end_distance'],
        'locked': false,
      };
      features.add(feature);
      return _json(feature, 201);
    }

    final extrudePatchMatch =
        RegExp(r'^/document/parts/part-1/extrude-features/([^/]+)$').firstMatch(path);
    if (extrudePatchMatch != null && method == 'PATCH') {
      final featureId = extrudePatchMatch.group(1);
      final feature = features.firstWhere((f) => f['id'] == featureId, orElse: () => {});
      if (feature.isEmpty) return http.Response('not found: feature', 404);
      if (body.containsKey('extrude_type')) feature['extrude_type'] = body['extrude_type'];
      if (body.containsKey('start_distance')) feature['start_distance'] = body['start_distance'];
      if (body.containsKey('end_distance')) feature['end_distance'] = body['end_distance'];
      return _json(feature, 200);
    }

    final deleteMatch = RegExp(r'^/document/parts/part-1/features/([^/]+)$').firstMatch(path);
    if (deleteMatch != null && method == 'DELETE') {
      final featureId = deleteMatch.group(1);
      final index = features.indexWhere((f) => f['id'] == featureId);
      if (index == -1) return http.Response('not found: feature', 404);
      features.removeAt(index);
      if (features.isNotEmpty) features.last['locked'] = false;
      return http.Response('', 204);
    }

    return http.Response('not found: $path', 404);
  }

  http.Response _json(dynamic body, int statusCode) => http.Response(jsonEncode(body), statusCode);
}

/// A tiny in-memory fake of the backend's `/sketch` API, just enough to
/// satisfy [SketchController.adoptSketch] for a SketchScreen pushed from
/// [PartScreen].
class _FakeSketchBackend {
  /// The `status` every `/profile` request reports - `closed_loop` by
  /// default (so a Feature's Extrude context-menu entry is enabled in most
  /// tests), overridden by the one test that exercises the disabled case.
  final String profileStatus;

  _FakeSketchBackend({this.profileStatus = 'closed_loop'});

  http.Response handle(http.Request request) {
    final profileMatch = RegExp(r'^/sketch/sketches/([^/]+)/profile$').firstMatch(request.url.path);
    if (profileMatch != null && request.method == 'GET') {
      return http.Response(
        jsonEncode({'status': profileStatus, 'detail': 'fake', 'branch_point_ids': [], 'loops': []}),
        200,
      );
    }
    final match = RegExp(r'^/sketch/sketches/([^/]+)$').firstMatch(request.url.path);
    if (match != null && request.method == 'GET') {
      return http.Response(
        jsonEncode({'id': match.group(1), 'plane': 'XY', 'origin_point_id': 'origin-1'}),
        200,
      );
    }
    return http.Response('not found: ${request.url.path}', 404);
  }
}

/// [WidgetTester.pumpAndSettle] never settles while [PartScreen] shows its
/// loading spinner - a [CircularProgressIndicator] with no explicit value
/// animates indefinitely - so this pumps a bounded number of times instead,
/// stopping early once [done] is satisfied.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done, {int maxPumps = 100}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (done()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // PartScreen now loads Stage 18's view preferences (background/body
  // colour, opacity) via shared_preferences on initState - without a mock
  // store, that call hits a real platform channel that doesn't exist under
  // flutter test and throws.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('PartScreen loads the placeholder mesh and Add Sketch Feature navigates to SketchScreen', (
    tester,
  ) async {
    final documentApi = DocumentApiClient(
      httpClient: MockClient((request) async => _FakeDocumentBackend().handle(request)),
    );
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    // The placeholder mesh loaded and rendered without throwing - this is
    // the real test of whether flutter_scene's GPU-bound
    // UnskinnedGeometry.uploadVertexData can execute at all in this
    // sandbox's headless `flutter test` runner.
    expect(find.text('Part 1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Stage 10b: the FAB now opens a flyout rather than acting directly -
    // "New Sketch" enters plane-selection mode, then a plane tap creates the
    // Feature and navigates, same as before. Stage 19b Item 1 added a second
    // (small, "Feature tree") FAB, so target the main "Add" one by tooltip
    // rather than by type.
    await tester.tap(find.byTooltip('Add'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('New Sketch'), findsOneWidget);

    await tester.tap(find.text('New Sketch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    tester.widget<PartViewport>(find.byType(PartViewport)).onPlaneTap(ReferencePlaneKind.xy);
    // A plane tap creates the SketchFeature and animates to the isometric
    // preset for the orientation-confirm step (_addSketchFeature) - the
    // sketch itself only opens once that step's "Continue" is tapped (see
    // PartScreen's own _confirmingSketchOrientation doc comment).
    await _pumpUntil(tester, () => find.text('Continue').evaluate().isNotEmpty);
    await tester.tap(find.text('Continue'));
    await _pumpUntil(tester, () => find.text('DIDSA-CAD Sketch').evaluate().isNotEmpty);

    expect(find.text('DIDSA-CAD Sketch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Stage 23 Item 1: the mode-toggle FAB switches tooltip/icon between Orbit and Selection mode',
    (tester) async {
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => _FakeDocumentBackend().handle(request)),
      );
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () =>
                SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      // Defaults to Orbit mode: the FAB's tooltip names the mode a tap will
      // switch *into* (Selection), and the viewport carries no tinted
      // border yet. The FAB's glyph is an SVG asset, not a named IconData
      // (see the 'exit-sketch-fab' heroTag predicate comment below) - byIcon
      // no longer matches it, so this checks the SvgIcon's own asset path.
      expect(find.byTooltip('Switch to selection mode'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is SvgIcon && w.asset == 'assets/icons/viewport/viewport_selection_mode.svg',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Switch to selection mode'));
      await tester.pump();

      expect(find.byTooltip('Switch to orbit mode'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is SvgIcon && w.asset == 'assets/icons/viewport/viewport_orbit_mode.svg',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Switching back to Orbit mode removes the FAB's active styling and
      // the viewport's tinted border again.
      await tester.tap(find.byTooltip('Switch to orbit mode'));
      await tester.pump();

      expect(find.byTooltip('Switch to selection mode'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the "Add" FAB flyout\'s New Sketch entry enters plane-selection mode, and Cancel exits it without creating anything',
    (tester) async {
      final backend = _FakeDocumentBackend();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tester.tap(find.byTooltip('Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('New Sketch'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Tap a reference plane for the new sketch'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Tap a reference plane for the new sketch'), findsNothing);
      expect(backend.features, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the toolbar\'s Hide Reference Planes entry toggles its own label between Hide/Show', (
    tester,
  ) async {
    final documentApi = DocumentApiClient(
      httpClient: MockClient((request) async => _FakeDocumentBackend().handle(request)),
    );
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('Open toolbar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // The toolbar's "View" section is an ExpansionTile, collapsed by
    // default - its children (including "Hide Reference Planes") aren't
    // in the render tree at all until it's expanded, matching the
    // already-passing "A4: Perspective toggle" test's own pattern below.
    await tester.tap(find.text('View'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Hide Reference Planes'), findsOneWidget);
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).referencePlanesHidden, isFalse);

    await tester.tap(find.text('Hide Reference Planes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Show Reference Planes'), findsOneWidget);
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).referencePlanesHidden, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Show Reference Planes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Hide Reference Planes'), findsOneWidget);
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).referencePlanesHidden, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    "the toolbar's render-mode entries set PartViewport.renderMode and mark the active one with a check",
    (tester) async {
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => _FakeDocumentBackend().handle(request)),
      );
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () =>
                SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tester.tap(find.byTooltip('Open toolbar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // The toolbar's "View" section is an ExpansionTile, collapsed by
      // default - its children (including the render-mode entries) aren't
      // in the render tree at all until it's expanded.
      await tester.tap(find.text('View'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Shaded'), findsOneWidget);
      expect(find.text('Shaded + Edges'), findsOneWidget);
      expect(find.text('Wireframe'), findsOneWidget);
      // Stage 19a Item 5: the default render mode is now Shaded + Edges
      // (was Shaded), so that's the active entry on first load.
      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).renderMode,
        ViewportRenderMode.shadedWithEdges,
      );

      // The toolbar's own SingleChildScrollView means "Wireframe" (the third
      // render-mode entry) can sit below the test's fixed 600px viewport - a
      // plain tap() would land off-screen and silently miss.
      await tester.ensureVisible(find.text('Wireframe'));
      await tester.pump();
      await tester.tap(find.text('Wireframe'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).renderMode,
        ViewportRenderMode.wireframe,
      );
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Wireframe')).trailing, isNotNull);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Shaded'));
      await tester.pump();
      await tester.tap(find.text('Shaded'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).renderMode,
        ViewportRenderMode.shaded,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the "Add" FAB is hidden while the Extrude panel is open', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    // Stage 19b Item 1 added a second (small, "Feature tree") FAB, so target
    // the main "Add" one by tooltip rather than by type.
    expect(find.byTooltip('Add'), findsOneWidget);

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Extrude'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Confirm'), findsOneWidget);
    expect(find.byTooltip('Add'), findsNothing);
    expect(tester.takeException(), isNull);

    // Prompt A4's target-body-picker banner adds its own Cancel button
    // (top of the screen) alongside ExtrudePanel's own - both wired to the
    // same _cancelExtrude, so either one works; `.last` picks a single
    // widget rather than leaving the finder ambiguous.
    await tester.tap(find.text('Cancel').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byTooltip('Add'), findsOneWidget);
  });

  testWidgets('tapping a locked Feature still selects it and opens its Sketch (B4: no longer gated on lock state)', (
    tester,
  ) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {'type': 'sketch', 'id': 'feature-2', 'sketch_id': 'sketch-2', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    // The Feature tree is hidden by default - open it via the toolbar
    // before it can be found/tapped below. pumpAndSettle can't be used here
    // (per the _pumpUntil doc comment above: PartViewport's own loading
    // spinner can keep scheduling frames indefinitely), so each tap is
    // followed by an explicit zero-duration frame - to apply the tap's
    // setState and let the AnimatedSlide pick up its new target offset -
    // then a frame past its 200ms duration to let it finish sliding in.
    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Sketch 1'), findsOneWidget);
    expect(find.text('Locked'), findsOneWidget);
    expect(find.text('Editable'), findsOneWidget);

    // The hamburger toggle sits in the same top-left corner as the tree's
    // header, so it's hidden while the tree is open to avoid overlapping
    // its text - the tree's own X button is the way to close it instead.
    expect(find.byTooltip('Open toolbar'), findsNothing);
    expect(find.byTooltip('Close toolbar'), findsNothing);

    await tester.tap(find.text('Sketch 1'));
    // B4: true SolidWorks-style rollback means a tap on a locked Feature no
    // longer does nothing - it always selects and opens it for editing (see
    // _onFeatureTap's doc comment), mirroring "tapping an unlocked (editable)
    // Feature..." below exactly, since lock state no longer gates this at
    // all. _pumpUntil (not a fixed pump) carries the tester through both the
    // camera animation into the Sketch plane and the eventual SketchScreen
    // load.
    await _pumpUntil(tester, () => find.text('DIDSA-CAD Sketch').evaluate().isNotEmpty);

    expect(find.text('DIDSA-CAD Sketch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-pressing a Feature shows a confirmation dialog naming every Feature that will be deleted', (
    tester,
  ) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {'type': 'sketch', 'id': 'feature-2', 'sketch_id': 'sketch-2', 'locked': true},
        {'type': 'sketch', 'id': 'feature-3', 'sketch_id': 'sketch-3', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Long-pressing the *first* (locked) Feature opens its context menu
    // first, not the dialog directly - tap its Delete entry to reach the
    // cascade-delete confirmation dialog.
    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    // The cascade-delete preview is an awaited network round trip before the
    // confirmation dialog even shows - pump past it rather than a single
    // fixed-duration frame.
    await _pumpUntil(tester, () => find.text('Delete all').evaluate().isNotEmpty);

    // Must name every Feature from it onward - all three - not just itself
    // or a generic message.
    expect(find.textContaining('Sketch 1\nSketch 2\nSketch 3'), findsOneWidget);
    expect(find.text('Delete all'), findsOneWidget);

    // Cancelling must delete nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Sketch 1'), findsOneWidget);
    expect(find.text('Sketch 2'), findsOneWidget);
    expect(find.text('Sketch 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming the cascade-delete dialog deletes the Feature and everything after it', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {'type': 'sketch', 'id': 'feature-2', 'sketch_id': 'sketch-2', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Long-press the locked first Feature - cascade-delete must be
    // available on a locked Feature too, unlike a single delete. Opens the
    // context menu first; tap its Delete entry to reach the dialog.
    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    // The cascade-delete preview is an awaited network round trip before the
    // confirmation dialog even shows - pump past it rather than a single
    // fixed-duration frame.
    await _pumpUntil(tester, () => find.text('Delete all').evaluate().isNotEmpty);

    await tester.tap(find.text('Delete all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await _pumpUntil(tester, () => find.text('Sketch 1').evaluate().isEmpty);

    // Both Features are gone, and the tree shows an empty list rather than
    // an error - the backend genuinely has zero Features for this Part now.
    expect(find.text('Sketch 1'), findsNothing);
    expect(find.text('Sketch 2'), findsNothing);
    expect(backend.features, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bug-fix round: deleting the last Feature returns the new-last Feature to its '
      'unlocked (black icon/"Editable") appearance, not stuck grey/"Locked"', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {'type': 'sketch', 'id': 'feature-2', 'sketch_id': 'sketch-2', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Before deleting: Sketch 1 locked (grey lock icon), Sketch 2 unlocked
    // (primary-colour edit icon).
    Icon iconFor(String label) =>
        tester.widget<Icon>(find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)), matching: find.byType(Icon)));
    expect(iconFor('Sketch 1').color, Colors.grey);
    expect(iconFor('Sketch 1').icon, Icons.lock);
    expect(iconFor('Sketch 2').color, isNot(Colors.grey));

    // Long-press the last (unlocked) Feature and delete just it - nothing
    // depends on the last Feature, so this cascades to exactly one Feature
    // and the dialog's confirm button reads "Delete" (not "Delete all") -
    // see showCascadeDeleteDialog's own count == 1 branch.
    await tester.longPress(find.text('Sketch 2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    // The cascade-delete preview is an awaited network round trip before the
    // confirmation dialog even shows - pump past it rather than a single
    // fixed-duration frame. Waits for the AlertDialog itself (not just any
    // "Delete" text) since the closing context-menu sheet's own ListTile can
    // still be mid-exit-animation and briefly coexist with the dialog,
    // making a plain text search ambiguous.
    await _pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await _pumpUntil(tester, () => find.text('Sketch 2').evaluate().isEmpty);

    // Sketch 1 is now the last Feature - it must render unlocked (black/
    // primary-colour edit icon), not still show the grey lock icon it had
    // while Sketch 2 existed.
    expect(find.text('Sketch 1'), findsOneWidget);
    expect(iconFor('Sketch 1').color, isNot(Colors.grey));
    expect(iconFor('Sketch 1').icon, isNot(Icons.lock));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tapping a reference plane opens a fly-up sheet with a New Sketch action, '
    'and confirming it creates a SketchFeature on that plane',
    (tester) async {
      final backend = _FakeDocumentBackend();
      final requests = <http.Request>[];
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async {
          requests.add(request);
          return backend.handle(request);
        }),
      );
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      // PartViewport's real screen-tap -> ray -> plane hit-test is exercised
      // directly in part_viewport_test.dart against a known camera/viewport
      // size; here, calling its onPlaneTap straight from the widget tree
      // stands in for "the 3D viewport reported a tap on the YZ plane" -
      // exactly the "mocked camera/viewport acceptable" the project brief
      // allows for this end-to-end toolbar/navigation flow.
      tester.widget<PartViewport>(find.byType(PartViewport)).onPlaneTap(ReferencePlaneKind.yz);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('New Sketch on YZ'), findsOneWidget);

      await tester.tap(find.text('New Sketch on YZ'));
      await tester.pump();
      // The plane tap creates the SketchFeature and animates to the
      // isometric preset for the orientation-confirm step
      // (_addSketchFeature) - the sketch itself only opens once that step's
      // "Continue" is tapped.
      await _pumpUntil(tester, () => find.text('Continue').evaluate().isNotEmpty);
      await tester.tap(find.text('Continue'));
      await _pumpUntil(tester, () => find.text('DIDSA-CAD Sketch').evaluate().isNotEmpty);

      expect(find.text('DIDSA-CAD Sketch'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final createRequest = requests.firstWhere((r) => r.url.path == '/document/parts/part-1/features/sketch');
      expect(jsonDecode(createRequest.body)['plane'], 'YZ');
    },
  );

  testWidgets('tapping an unlocked (editable) Feature opens its Sketch, animating the camera first', (
    tester,
  ) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {'type': 'sketch', 'id': 'feature-2', 'sketch_id': 'sketch-2', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('Sketch 2'));
    // The camera-animation-into-the-Sketch-plane runs (and must complete)
    // before navigation - _pumpUntil's bounded pumping carries the tester
    // through both that animation and the eventual SketchScreen load.
    await _pumpUntil(tester, () => find.text('DIDSA-CAD Sketch').evaluate().isNotEmpty);

    expect(find.text('DIDSA-CAD Sketch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Hide/Show context-menu action dims a Feature row and flips its label/icon', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(Icons.visibility_off), findsNothing);

    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Not yet hidden - the context menu's toggle entry must offer "Hide".
    expect(find.text('Hide'), findsOneWidget);
    expect(find.text('Show'), findsNothing);

    await tester.tap(find.text('Hide'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Hidden now - the tree row shows the eye-slash trailing icon.
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // The menu now offers "Show" instead, reflecting the toggled state.
    expect(find.text('Show'), findsOneWidget);
    expect(find.text('Hide'), findsNothing);

    await tester.tap(find.text('Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(Icons.visibility_off), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping outside the plane fly-up sheet dismisses it and clears the plane selection', (
    tester,
  ) async {
    final documentApi = DocumentApiClient(
      httpClient: MockClient((request) async => _FakeDocumentBackend().handle(request)),
    );
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
    viewport.onPlaneTap(ReferencePlaneKind.xy);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('New Sketch on XY'), findsOneWidget);

    // The sheet is a modal route; tapping its barrier (away from the sheet's
    // own bottom-aligned content) dismisses it like a background tap would,
    // and PartScreen clears _selectedPlane once that dismissal resolves.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('New Sketch on XY'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long-pressing a SketchFeature with a closed profile offers an enabled Extrude action, and '
    'confirming it creates an ExtrudeFeature shown in the tree',
    (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
        ],
      );
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tester.tap(find.byTooltip('Feature tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.longPress(find.text('Sketch 1'));
      // The closed-profile check is an awaited network round trip before
      // the menu even shows - pump past it rather than a single frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final extrudeTile = find.widgetWithText(ListTile, 'Extrude');
      expect(extrudeTile, findsOneWidget);
      expect(tester.widget<ListTile>(extrudeTile).enabled, isTrue);

      await tester.tap(find.text('Extrude'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Confirm'), findsOneWidget);
      // Prompt A4's target-body-picker banner adds its own Cancel button
      // alongside ExtrudePanel's own - both wired to the same
      // _cancelExtrude, so two is the real, current count.
      expect(find.text('Cancel'), findsNWidgets(2));

      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await _pumpUntil(tester, () => find.text('Extrude 1').evaluate().isNotEmpty);

      expect(find.text('Extrude 1'), findsOneWidget);
      expect(backend.features.where((f) => f['type'] == 'extrude'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    "long-pressing a SketchFeature without a closed profile shows Extrude disabled, "
    "with an explanatory subtitle",
    (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
        ],
      );
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend(profileStatus: 'no_loop');

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tester.tap(find.byTooltip('Feature tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.longPress(find.text('Sketch 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final extrudeTile = find.widgetWithText(ListTile, 'Extrude');
      expect(extrudeTile, findsOneWidget);
      expect(tester.widget<ListTile>(extrudeTile).enabled, isFalse);
      // Revolve/Sweep share Extrude's own eligibility check (see
      // _onFeatureLongPress) and so show the identical disabled-reason
      // subtitle alongside it - three, not one. textContaining, not an
      // exact match: _checkExtrudeEligibility appends the backend's own
      // `profile.detail` after a colon, which this fake's exact wording
      // isn't asserted against here.
      expect(find.textContaining('Sketch does not contain a closed profile'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    "long-pressing a SketchFeature with a MultiProfile (C2's disjoint-outer-loops "
    "'multiple_loops' status) shows Extrude enabled, not disabled",
    (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
        ],
      );
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend(profileStatus: 'multiple_loops');

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tester.tap(find.byTooltip('Feature tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.longPress(find.text('Sketch 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final extrudeTile = find.widgetWithText(ListTile, 'Extrude');
      expect(extrudeTile, findsOneWidget);
      expect(tester.widget<ListTile>(extrudeTile).enabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  // Prompt D: the "Add" FAB's Feature > Extrude entry, with no eligible
  // Sketch already selected, opens the Feature tree as a guided picker
  // instead of just complaining there's nothing to extrude.
  group('Prompt D - feature tree sketch picker for Extrude', () {
    /// Drives the "Add" FAB through its flyout's "Feature" entry to the
    /// second-level picker's "Extrude" entry - the trigger every test below
    /// shares.
    Future<void> tapAddFeatureExtrude(WidgetTester tester) async {
      // find.byTooltip taps at the Tooltip's own computed showing position,
      // not necessarily the wrapped FAB's actual center - unreliable enough
      // in this file (see the identical "Exit Sketch" fix above) that the
      // "one pre-selected Sketch" test in this group, which reaches this
      // helper after a full push/pop through the Sketch screen, kept
      // missing. A heroTag predicate targets the real rendered button
      // directly (find.widgetWithIcon no longer works now that the FAB's
      // glyph is an SVG asset, not a named IconData - same fix as the
      // 'exit-sketch-fab' case below).
      await tester.tap(
        find.byWidgetPredicate((w) => w is FloatingActionButton && w.heroTag == 'add-fab'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Feature'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Extrude'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    testWidgets('opens the Feature tree with the picker banner visible', (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
        ],
      );
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tapAddFeatureExtrude(tester);

      expect(find.text('Select a sketch to extrude'), findsOneWidget);
      expect(find.text('Sketch 1'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a valid sketch populates the extrude sketch reference and closes the picker', (
      tester,
    ) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
        ],
      );
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tapAddFeatureExtrude(tester);
      expect(find.text('Select a sketch to extrude'), findsOneWidget);

      await tester.tap(find.text('Sketch 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Select a sketch to extrude'), findsNothing);
      expect(find.text('Confirm'), findsOneWidget);
      // Prompt A4's target-body-picker banner adds its own Cancel button
      // alongside ExtrudePanel's own - both wired to the same
      // _cancelExtrude, so two is the real, current count.
      expect(find.text('Cancel'), findsNWidgets(2));

      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await _pumpUntil(tester, () => find.text('Extrude 1').evaluate().isNotEmpty);

      expect(backend.features.where((f) => f['type'] == 'extrude' && f['sketch_feature_id'] == 'feature-1'), hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping an invalid sketch shows a SnackBar and leaves the picker open', (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
        ],
      );
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend(profileStatus: 'no_loop');

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tapAddFeatureExtrude(tester);
      expect(find.text('Select a sketch to extrude'), findsOneWidget);

      await tester.tap(find.text('Sketch 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.text('This sketch has no closed profile — add more lines or close the loop first'),
        findsOneWidget,
      );
      // Still in picker mode - the banner is still up and no Extrude panel
      // opened.
      expect(find.text('Select a sketch to extrude'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      expect(backend.features.where((f) => f['type'] == 'extrude'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissing the Feature tree cancels the pending Extrude creation', (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
        ],
      );
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tapAddFeatureExtrude(tester);
      expect(find.text('Select a sketch to extrude'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Select a sketch to extrude'), findsNothing);
      expect(find.text('Confirm'), findsNothing);
      expect(backend.features.where((f) => f['type'] == 'extrude'), isEmpty);
      expect(tester.takeException(), isNull);

      // The picker is fully exited, not just hidden - the same flow can be
      // started fresh.
      await tapAddFeatureExtrude(tester);
      expect(find.text('Select a sketch to extrude'), findsOneWidget);
    });

    testWidgets('a pre-selected, already-eligible Sketch skips the picker entirely (back-compat)', (
      tester,
    ) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
          {'type': 'sketch', 'id': 'feature-2', 'sketch_id': 'sketch-2', 'locked': false},
        ],
      );
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await tester.tap(find.byTooltip('Feature tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // B4: tapping Sketch 1 (locked or not) always selects it and now also
      // opens its Sketch screen - so getting back to a "pre-selected but on
      // PartScreen" state means exiting that Sketch afterward, the same way
      // a real user would; _selectedFeatureId (all _extrudeSelectedFeature
      // actually reads) stays set to feature-1 across the round trip since
      // PartScreen's own State is never rebuilt, just covered/uncovered.
      await tester.tap(find.text('Sketch 1'));
      await _pumpUntil(tester, () => find.text('DIDSA-CAD Sketch').evaluate().isNotEmpty);
      // The title text is in the tree as soon as the route is pushed, but
      // the page-transition slide-in animation may still be in progress -
      // a FAB positioned via right:8 during that slide can genuinely sit
      // outside the test viewport's bounds until it settles.
      await tester.pump(const Duration(milliseconds: 300));

      // find.byTooltip resolves to the tooltip overlay's own positioning
      // surrogate here, not the actual FAB - which can sit outside the test
      // viewport's bounds and silently miss. A heroTag predicate targets
      // the real rendered button directly (find.widgetWithIcon no longer
      // works now that the FAB's glyph is an SVG asset, not a named
      // IconData).
      await tester.tap(find.byWidgetPredicate(
        (w) => w is FloatingActionButton && w.heroTag == 'exit-sketch-fab',
      ));
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      // The "Add" FAB carries heroTag: 'add-fab' - while the pop's Hero
      // flight is still in progress, a temporary in-flight copy coexists
      // with the destination route's own static FAB, so a plain fixed pump
      // isn't reliable (this ambiguity showed up intermittently at 300ms).
      // Wait for the flight to actually finish - exactly one 'add-fab' left
      // - rather than guessing a duration. find.widgetWithIcon no longer
      // works now that the FAB's glyph is an SVG asset, not a named
      // IconData.
      await _pumpUntil(
        tester,
        () => find
                .byWidgetPredicate((w) => w is FloatingActionButton && w.heroTag == 'add-fab')
                .evaluate()
                .length ==
            1,
      );
      expect(find.text('Part 1'), findsOneWidget);

      await tapAddFeatureExtrude(tester);

      // Straight to the panel - the picker banner never appears.
      expect(find.text('Select a sketch to extrude'), findsNothing);
      expect(find.text('Confirm'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'after confirming an Extrude then deleting it, a later New > Extrude offers the picker again '
      'rather than reusing the stale selection',
      (tester) async {
        final backend = _FakeDocumentBackend(
          seedFeatures: [
            {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
          ],
        );
        final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        // Picker -> pick Sketch 1 -> confirm, exactly like the "valid pick"
        // test above - this is what sets _selectedFeatureId to feature-1
        // along the way.
        await tapAddFeatureExtrude(tester);
        await tester.tap(find.text('Sketch 1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('Confirm'));
        await tester.pump();
        await _pumpUntil(tester, () => find.text('Extrude 1').evaluate().isNotEmpty);

        // Picking a Sketch closes the Feature tree along with the picker -
        // reopen it to reach the new ExtrudeFeature's row.
        await tester.tap(find.byTooltip('Feature tree'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Delete the ExtrudeFeature just created - a single Feature, so the
        // dialog's confirm button reads "Delete" (not "Delete all").
        await tester.longPress(find.text('Extrude 1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('Delete'));
        await tester.pump();
        // The cascade-delete preview is an awaited network round trip before
        // the confirmation dialog even shows - pump past it rather than a
        // single fixed-duration frame. Waits for the AlertDialog itself (not
        // just any "Delete" text), since the closing context-menu sheet's
        // own ListTile can still be mid-exit-animation and briefly coexist
        // with the dialog, making a plain text search ambiguous.
        await _pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
        await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
        await tester.pump();
        await _pumpUntil(tester, () => find.text('Extrude 1').evaluate().isEmpty);
        expect(backend.features.where((f) => f['type'] == 'extrude'), isEmpty);

        // The regression: without clearing _selectedFeatureId on confirm,
        // this would silently reopen the panel for the same already-deleted
        // pairing's Sketch instead of offering the picker.
        await tapAddFeatureExtrude(tester);

        expect(find.text('Select a sketch to extrude'), findsOneWidget);
        expect(find.text('Confirm'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'bug-fix: deleting the ExtrudeFeature that auto-hid its Sketch un-hides that Sketch again, '
      'instead of leaving it hidden forever even once it is editable',
      (tester) async {
        final backend = _FakeDocumentBackend(
          seedFeatures: [
            {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
          ],
        );
        final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        await tapAddFeatureExtrude(tester);
        await tester.tap(find.text('Sketch 1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('Confirm'));
        await tester.pump();
        await _pumpUntil(tester, () => find.text('Extrude 1').evaluate().isNotEmpty);

        // Confirming the Extrude auto-hides the Sketch it consumed (Stage
        // 19b) - reopen the tree to see it.
        await tester.tap(find.byTooltip('Feature tree'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byIcon(Icons.visibility_off), findsOneWidget);

        // Delete the ExtrudeFeature - Sketch 1 becomes the last (editable)
        // Feature again, so it should no longer be hidden either.
        await tester.longPress(find.text('Extrude 1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('Delete'));
        await tester.pump();
        // The cascade-delete preview is an awaited network round trip before
        // the confirmation dialog even shows - pump past it rather than a
        // single fixed-duration frame. Waits for the AlertDialog itself (not
        // just any "Delete" text), since the closing context-menu sheet's
        // own ListTile can still be mid-exit-animation and briefly coexist
        // with the dialog, making a plain text search ambiguous.
        await _pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
        await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
        await tester.pump();
        await _pumpUntil(tester, () => find.text('Extrude 1').evaluate().isEmpty);
        // "Extrude 1" disappears as soon as _refreshFeatures's own rebuild
        // lands, but the un-hide bookkeeping right after it in the same
        // guarded body (see _cascadeDeleteFeature) can still land on a later
        // frame - an extra settle pump avoids reading the icon mid-update.
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.byIcon(Icons.visibility_off), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('cancelling the Extrude panel after a live-preview update deletes the preview ExtrudeFeature', (
    tester,
  ) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Extrude'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.enterText(find.widgetWithText(TextField, 'End distance'), '20');
    // Past the 500ms debounce, plus enough extra pumps for the resulting
    // create-ExtrudeFeature-then-refetch-mesh network round trip to land.
    await _pumpUntil(tester, () => backend.features.any((f) => f['type'] == 'extrude'));

    expect(backend.features.where((f) => f['type'] == 'extrude'), hasLength(1));

    // Prompt A4's target-body-picker banner adds its own Cancel button
    // alongside ExtrudePanel's own - both wired to the same _cancelExtrude,
    // so `.last` just needs to pick one, not the specific one.
    await tester.tap(find.text('Cancel').last);
    await _pumpUntil(tester, () => backend.features.every((f) => f['type'] != 'extrude'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(backend.features.where((f) => f['type'] == 'extrude'), isEmpty);
    expect(find.text('Confirm'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A4: PartScreen starts with orthographic projection (isPerspective = false) and toggling Perspective in View menu switches it',
    (tester) async {
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => _FakeDocumentBackend().handle(request)),
      );
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () =>
                SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      // A4: the viewport starts with orthographic as default - check
      // isPerspective = false is forwarded to the PartViewport widget.
      final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewport.isPerspective, isFalse);

      // Open the toolbar via the hamburger toggle button.
      await tester.tap(find.byTooltip('Open toolbar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Expand the View sub-menu.
      await tester.tap(find.text('View'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Toggle Perspective on.
      await tester.tap(find.text('Perspective'));
      await tester.pump();

      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).isPerspective,
        isTrue,
      );
      expect(tester.takeException(), isNull);

      // Toggle Perspective back off.
      await tester.tap(find.text('Perspective'));
      await tester.pump();

      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).isPerspective,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
