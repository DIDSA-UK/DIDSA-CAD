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
import 'package:didsa_cad_client/viewport3d/pattern_panel.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/render_mode.dart';
import 'package:didsa_cad_client/viewport3d/resizable_tool_panel.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';
import 'package:didsa_cad_client/viewport3d/svg_icon.dart';

/// A tiny in-memory fake of the backend's `/document` API - just enough of
/// Part/Feature/mesh to drive [PartScreen] without a real network call.
/// Locking is simulated the same way the real backend enforces it: every
/// Feature except the most-recently-added one is locked.
class _FakeDocumentBackend {
  late int _nextFeatureId;
  final List<Map<String, dynamic>> features;

  /// Pattern/Mirror scoping's Phase 6: the most recent pattern-features PATCH
  /// body, for tests that need to assert on a field (e.g. `source_feature_
  /// ids`) this fake doesn't otherwise expose any other way.
  Map<String, dynamic>? lastPatternPatchBody;

  /// Bug fix regression coverage ("patterns have stopped showing in the
  /// feature tree... this was working before"): how many times `GET
  /// .../features` has actually been called - proves [PartScreen] really
  /// re-fetches the Feature list on Confirm, not just that a freshly-loaded
  /// `_features` happens to already contain what the test expects.
  int featuresGetCount = 0;

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
    // Skip-instances redesign: `hitTestFaces` indexes `mesh.faceIds`
    // parallel to `mesh.triangleIndices` (see `MeshDto.faceIds`'s own doc
    // comment) - without this, a hover ray that happens to actually
    // intersect this triangle (now plausible once the Pattern mesh handler
    // below returns more than one Body sharing this exact placeholder
    // geometry) throws a RangeError instead of returning no hit.
    'face_ids': [0],
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
      //
      // Skip-instances redesign: a `pattern` Feature is the one exception -
      // its own instance Bodies need *real*, scheme-correct ids (mirroring
      // `compute_part_bodies`'s own `feature.id`/`feature.id#index` naming -
      // see `extrude.py`'s doc comment there) for the viewport-tap-to-toggle
      // tests below to target a specific instance, and its own stored
      // `skip_indices` needs to actually filter the returned array (mirrors
      // the real backend) so the "editing reveals every instance, Confirm
      // re-applies the real selection" sequencing is observable end to end.
      final patternFeature = features.firstWhere((f) => f['type'] == 'pattern', orElse: () => const {});
      if (patternFeature.isNotEmpty) {
        final seedId = (patternFeature['source_body_ids'] as List).first as String;
        final isCircular = patternFeature['pattern_type'] == 'circular';
        final totalCount = isCircular
            ? (patternFeature['count_angular'] as num).toInt()
            : (patternFeature['count_1'] as num).toInt() * (patternFeature['count_2'] as num).toInt();
        final skipIndices = ((patternFeature['skip_indices'] as List?) ?? const [])
            .map((n) => (n as num).toInt())
            .toSet();
        final featureId = patternFeature['id'] as String;
        final nonSeedIndices = [
          for (var i = 1; i < totalCount; i++)
            if (!skipIndices.contains(i)) i,
        ];
        return _json([
          {'body_id': seedId, 'source': 'placeholder', 'mesh': _placeholderMesh},
          for (final i in nonSeedIndices)
            {
              'body_id': nonSeedIndices.length == 1 ? featureId : '$featureId#$i',
              'source': 'placeholder',
              'mesh': _placeholderMesh,
            },
        ], 200);
      }
      return _json([
        {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': _placeholderMesh},
      ], 200);
    }

    if (path == '/document/parts/part-1/features' && method == 'GET') {
      featuresGetCount++;
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

    final patternPatchMatch =
        RegExp(r'^/document/parts/part-1/pattern-features/([^/]+)$').firstMatch(path);
    if (patternPatchMatch != null && method == 'PATCH') {
      final featureId = patternPatchMatch.group(1);
      final feature = features.firstWhere((f) => f['id'] == featureId, orElse: () => {});
      if (feature.isEmpty) return http.Response('not found: feature', 404);
      for (final key in [
        'source_body_ids',
        'source_feature_ids',
        'count_1',
        'spacing_1',
        'reverse_1',
        'count_2',
        'spacing_2',
        'reverse_2',
        'count_angular',
        'angle_total',
        'reverse_angular',
        'skip_indices',
      ]) {
        if (body.containsKey(key)) feature[key] = body[key];
      }
      lastPatternPatchBody = body;
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

    // The toolbar's own max height is now capped to a third of the
    // screen's height (was a fixed 520px), so an entry this far down the
    // expanded View menu can be scrolled out of the visible, clipped area
    // even though it's still in the tree - ensureVisible scrolls the
    // ancestor SingleChildScrollView first, same as any other test
    // targeting content that may not already be on-screen.
    await tester.ensureVisible(find.text('Hide Reference Planes'));
    await tester.pump();
    await tester.tap(find.text('Hide Reference Planes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Show Reference Planes'), findsOneWidget);
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).referencePlanesHidden, isTrue);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Show Reference Planes'));
    await tester.pump();
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
    // On-device feedback ("we now have the ability to edit parent features
    // and parametric flow is working" - the Locked badge was removed):
    // every row shows "Editable" regardless of lock state now, not just the
    // last (previously "unlocked") one.
    expect(find.text('Editable'), findsNWidgets(2));

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

  testWidgets('tapping a Pattern row in the Feature tree opens it for editing', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'pattern',
          'id': 'feature-2',
          'source_body_ids': ['body-1'],
          'pattern_type': 'rectangular',
          'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'},
          'count_1': 3,
          'spacing_1': 10.0,
          'reverse_1': false,
          'direction_2': null,
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': [],
          'locked': false,
        },
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

    expect(find.text('Pattern 1'), findsOneWidget);

    await tester.tap(find.text('Pattern 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Edit Pattern'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // PatternPanel's own initState eagerly re-emits its initial field
    // values (see its own doc comment on why), which schedules a debounced
    // live-preview PATCH - pump past it so no Timer is left pending when
    // this test tears down.
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-pressing a Pattern row offers Delete, same as any other Feature type', (tester) async {
    // The Pattern is deliberately *not* the last Feature here (cascade
    // deletes it and everything after it) - the trailing Sketch means the
    // confirmation dialog covers 2 Features ("Delete all"), matching the
    // already-passing "long-pressing a Feature shows a confirmation
    // dialog..." test's own shape, rather than the single-Feature
    // ("Delete") case a lone last Feature would hit.
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {
          'type': 'pattern',
          'id': 'feature-1',
          'source_body_ids': ['body-1'],
          'pattern_type': 'rectangular',
          'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'},
          'count_1': 3,
          'spacing_1': 10.0,
          'reverse_1': false,
          'direction_2': null,
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': [],
          'locked': true,
        },
        {'type': 'sketch', 'id': 'feature-2', 'sketch_id': 'sketch-1', 'locked': false},
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

    await tester.longPress(find.text('Pattern 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await _pumpUntil(tester, () => find.text('Delete all').evaluate().isNotEmpty);

    await tester.tap(find.text('Delete all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await _pumpUntil(tester, () => find.text('Pattern 1').evaluate().isEmpty);

    expect(backend.features, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Pattern/Mirror scoping Phase 6: "Add from Tree" opens the Build Tree as a multi-select '
      'Feature picker, and confirming a pick sends it as source_feature_ids', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'extrude',
          'id': 'feature-2',
          'sketch_feature_id': 'feature-1',
          'extrude_type': 'boss',
          'start_distance': 0.0,
          'end_distance': 10.0,
          'locked': true,
        },
        {
          'type': 'pattern',
          'id': 'feature-3',
          'source_body_ids': ['body-1'],
          'source_feature_ids': <String>[],
          'pattern_type': 'rectangular',
          'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'},
          'count_1': 3,
          'spacing_1': 10.0,
          'reverse_1': false,
          'direction_2': null,
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': [],
          'locked': false,
        },
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

    await tester.tap(find.text('Pattern 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Edit Pattern'), findsOneWidget);
    // PatternPanel's own initState eager debounced update - see the "tapping
    // a Pattern row..." test above for why this pump is needed here too.
    await tester.pump(const Duration(milliseconds: 600));

    await tester.ensureVisible(find.text('Add from Tree'));
    await tester.tap(find.text('Add from Tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // The Build Tree is now up as a multi-select Feature picker, not the
    // ordinary read-only tree - PatternPanel itself is hidden underneath.
    expect(find.text('Select source Features'), findsOneWidget);
    expect(find.text('Edit Pattern'), findsNothing);

    await tester.tap(find.text('Extrude 1'));
    await tester.pump();
    expect(find.text('Select source Features - 1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Confirm Feature selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // PatternPanel is back immediately (the picker's own confirm/cancel are
    // synchronous UI state) - the debounced live-preview PATCH this
    // triggers (see [_confirmSourceFeaturePicker]) lands separately, after
    // its own 500ms debounce.
    expect(find.text('Edit Pattern'), findsOneWidget);
    expect(find.text('1 Feature added from the Build Tree'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.lastPatternPatchBody?['source_feature_ids'], ['feature-2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Bug fix: confirming a Pattern edit re-fetches the Feature list, so it '
      'still shows in the Build Tree afterward ("patterns have stopped showing '
      'in the feature tree" on-device feedback)', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'pattern',
          'id': 'feature-2',
          'source_body_ids': ['body-1'],
          'pattern_type': 'rectangular',
          'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'},
          'count_1': 3,
          'spacing_1': 10.0,
          'reverse_1': false,
          'direction_2': null,
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': [],
          'locked': false,
        },
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
    await tester.tap(find.text('Pattern 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Edit Pattern'), findsOneWidget);
    // PatternPanel's own initState eager debounced update.
    await tester.pump(const Duration(milliseconds: 600));

    final featuresGetCountBeforeConfirm = backend.featuresGetCount;

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(backend.featuresGetCount, greaterThan(featuresGetCountBeforeConfirm));
    expect(tester.takeException(), isNull);

    // The tree still shows the Pattern, proving _features itself was
    // actually updated with the fresh fetch's own result, not merely that
    // a network call happened.
    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Pattern 1'), findsOneWidget);
  });

  testWidgets(
      'Pattern/Mirror scoping Phase 6: long-pressing a body-producing Feature row offers '
      'Pattern, and tapping it opens PatternPanel seeded from that Feature', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'extrude',
          'id': 'feature-2',
          'sketch_feature_id': 'feature-1',
          'extrude_type': 'boss',
          'start_distance': 0.0,
          'end_distance': 10.0,
          'locked': false,
        },
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

    await tester.longPress(find.text('Extrude 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Pattern'), findsOneWidget);

    await tester.tap(find.text('Pattern'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Straight to `configuring` for a brand-new PatternFeature (title
    // 'Pattern', not 'Edit Pattern' - nothing already existed to edit), no
    // pickingBodies ribbon/step in between - mirrors the ambient
    // SelectionContextPanel entry's own shape.
    expect(find.byType(PatternPanel), findsOneWidget);
    expect(find.text('Edit Pattern'), findsNothing);
    expect(find.text('Select Body to Pattern'), findsNothing);
    expect(tester.takeException(), isNull);

    // PatternPanel's own initState eagerly re-emits its initial field
    // values, which schedules a debounced live-preview PATCH - pump past
    // it so no Timer is left pending when this test tears down.
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Pattern/Mirror scoping Phase 6: long-pressing a non-body-producing Feature row (a '
      'Sketch) does not offer Pattern', (tester) async {
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

    expect(find.text('Pattern'), findsNothing);
  });

  testWidgets(
      'Pattern/Mirror scoping Phase 6 UX: the pickingBodies ribbon\'s "Select Feature" button '
      'opens the Build Tree picker, and a confirmed pick is reflected back in the ribbon',
      (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'extrude',
          'id': 'feature-2',
          'sketch_feature_id': 'feature-1',
          'extrude_type': 'boss',
          'start_distance': 0.0,
          'end_distance': 10.0,
          'locked': false,
        },
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

    await tester.tap(find.byTooltip('Add'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Feature'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Pattern'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Select Body to Pattern'), findsOneWidget);
    expect(find.text('Select Feature'), findsOneWidget);

    await tester.tap(find.text('Select Feature'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // The Build Tree's own multi-select picker is up instead of the
    // ribbon now.
    expect(find.text('Select source Features'), findsOneWidget);
    expect(find.text('Select Body to Pattern'), findsNothing);

    await tester.tap(find.text('Extrude 1'));
    await tester.pump();
    expect(find.text('Select source Features - 1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Confirm Feature selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Back at the pickingBodies ribbon, now reflecting the picked Feature -
    // still `pickingBodies`, not advanced to `configuring` (no Body was
    // ever tapped, and the ribbon's own confirm is a separate, explicit
    // step - see PartScreen._confirmPatternBodySelection).
    expect(find.text('1 feature(s) selected - tap checkmark to confirm'), findsOneWidget);
    expect(find.byType(PatternPanel), findsNothing);
    expect(tester.takeException(), isNull);

    // [_confirmSourceFeaturePicker] unconditionally reschedules the
    // debounced live-preview PATCH (harmlessly a no-op here, since
    // `_patternSourceBodyIds` is still null throughout `pickingBodies` -
    // see [_schedulePatternPreview]'s own guard) - pump past it so no
    // Timer is left pending when this test tears down.
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Bug fix: toggling the orbit/select-mode FAB does not reset a resizable tool panel\'s own '
      'pulled height (the panel\'s own Positioned slot needs a stable Key, since an unrelated '
      'sibling elsewhere in the same Stack appearing/disappearing shifts every unkeyed one after '
      'it)', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'pattern',
          'id': 'feature-2',
          'source_body_ids': ['body-1'],
          'pattern_type': 'rectangular',
          'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'},
          'count_1': 3,
          'spacing_1': 10.0,
          'reverse_1': false,
          'direction_2': null,
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': [],
          'locked': false,
        },
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
    await tester.tap(find.text('Pattern 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Edit Pattern'), findsOneWidget);
    // PatternPanel's own initState eager debounced update.
    await tester.pump(const Duration(milliseconds: 600));

    // Pull the panel taller than its default height.
    await tester.drag(find.byKey(const Key('patternPanelDragHandle')), const Offset(0, -150));
    await tester.pump();
    final heightAfterDrag = tester.getSize(find.byKey(const Key('patternPanelResizableArea'))).height;

    // Toggling orbit <-> selection mode is what used to reset it.
    await tester.tap(find.byTooltip('Switch to orbit mode'));
    await tester.pump();
    await tester.tap(find.byTooltip('Switch to selection mode'));
    await tester.pump();

    final heightAfterToggling = tester.getSize(find.byKey(const Key('patternPanelResizableArea'))).height;
    expect(heightAfterToggling, heightAfterDrag);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'editing a Pattern with skip_indices reveals every instance for editing, and Confirm '
      're-applies the real skip selection', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'pattern',
          'id': 'feature-2',
          'source_body_ids': ['body-1'],
          'pattern_type': 'rectangular',
          'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'},
          'count_1': 3,
          'spacing_1': 10.0,
          'reverse_1': false,
          'direction_2': null,
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': [1],
          'locked': false,
        },
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

    await tester.tap(find.text('Pattern 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Edit Pattern'), findsOneWidget);

    // The force-reveal update ([_openPatternPanelForEdit]'s own doc
    // comment) plus PatternPanel's own initState-eager debounced update
    // both fire skip_indices: [] - pump well past both.
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    final pattern = backend.features.firstWhere((f) => f['id'] == 'feature-2');
    expect(pattern['skip_indices'], isEmpty);

    // Fetch the mesh again to confirm every instance really is present
    // (not just that the stored value is empty) while editing.
    await _pumpUntil(tester, () {
      final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      return viewport.bodies.any((b) => b.bodyId == 'feature-2#1') &&
          viewport.bodies.any((b) => b.bodyId == 'feature-2#2');
    });

    // PatternPanel now has a bounded, resizable height (pull handle) with
    // genuinely scrollable content - ensureVisible scrolls Confirm into
    // view first, same as any other scrollable-panel test in this suite.
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(pattern['skip_indices'], [1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'tapping a Pattern instance Body in the viewport toggles its own skip/keep state, '
      'and Confirm sends that real selection to the backend', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'pattern',
          'id': 'feature-2',
          'source_body_ids': ['body-1'],
          'pattern_type': 'rectangular',
          'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'},
          'count_1': 3,
          'spacing_1': 10.0,
          'reverse_1': false,
          'direction_2': null,
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': [],
          'locked': false,
        },
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

    await tester.tap(find.text('Pattern 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Edit Pattern'), findsOneWidget);

    final pattern = backend.features.firstWhere((f) => f['id'] == 'feature-2');
    expect(pattern['skip_indices'], isEmpty);

    tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
          const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'feature-2#1'),
        );
    await tester.pump();

    // Purely local - no PATCH fires for the toggle itself.
    expect(pattern['skip_indices'], isEmpty);
    expect(
      tester.widget<PartViewport>(find.byType(PartViewport)).skippedPreviewBodyIds,
      {'feature-2#1'},
    );

    // Tapping the same instance again clears it back to kept.
    tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
          const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'feature-2#1'),
        );
    await tester.pump();
    expect(tester.widget<PartViewport>(find.byType(PartViewport)).skippedPreviewBodyIds, isEmpty);

    // Toggle it skip again, then confirm - the real selection is only ever
    // sent once, right here.
    tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
          const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'feature-2#1'),
        );
    await tester.pump();

    // PatternPanel now has a bounded, resizable height (pull handle) with
    // genuinely scrollable content - ensureVisible scrolls Confirm into
    // view first, same as any other scrollable-panel test in this suite.
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(pattern['skip_indices'], [1]);
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
      // On-device feedback ("the tooltip at the top of the screen blocks
      // the FABs"): the target-body-picker banner's own separate Cancel
      // button is gone now, its text folded into ExtrudePanel's own title
      // row - see the sibling test in this same file for the full note.
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await _pumpUntil(tester, () => find.text('Extrude 1').evaluate().isNotEmpty);

      expect(find.text('Extrude 1'), findsOneWidget);
      expect(backend.features.where((f) => f['type'] == 'extrude'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'on-device feedback ("the tooltip at the top of the screen blocks the FABs to recentre and to '
    'switch between select/orbit"): the target-body-picking status text lives inside '
    "ExtrudePanel's own [ResizableToolPanel] title row, not a separate full-width banner "
    'floating over the corner FABs',
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Extrude'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Boss (the default type) with nothing picked yet.
      final bannerText = find.text('Select bodies to merge into (optional)');
      expect(bannerText, findsOneWidget);
      expect(
        find.ancestor(of: bannerText, matching: find.byType(ResizableToolPanel)),
        findsOneWidget,
        reason: 'this status text used to float in its own top-level Positioned banner - it must '
            "now be reached only through ExtrudePanel's own ResizableToolPanel shell",
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'on-device feedback ("I do want select/orbit-mode switching available while a tool panel is '
    'open"): the select/orbit FAB stays visible and functions once Extrude is active, unlike the '
    "hamburger/feature-tree column, which still hides during a tool session",
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Extrude'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Still hidden - opening either would abandon the in-progress Extrude.
      expect(find.byTooltip('Feature tree'), findsNothing);
      expect(find.byTooltip('Open toolbar'), findsNothing);
      expect(find.byTooltip('Close toolbar'), findsNothing);

      // But the select/orbit toggle is still there and still works. Extrude
      // defaults _selectionMode to true on open (target-body picking needs
      // it), so the FAB starts showing the orbit-mode entry point.
      expect(find.byTooltip('Switch to orbit mode'), findsOneWidget);
      await tester.tap(find.byTooltip('Switch to orbit mode'));
      await tester.pump();

      expect(find.byTooltip('Switch to selection mode'), findsOneWidget);
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
      // On-device feedback ("the tooltip at the top of the screen blocks
      // the FABs"): Prompt A4's target-body-picker banner used to add its
      // own separate Cancel button alongside ExtrudePanel's own (both
      // wired to the same _cancelExtrude) - that banner is gone now, its
      // text folded into ExtrudePanel's own title row, so there's only
      // ever the one Cancel.
      expect(find.text('Cancel'), findsOneWidget);

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
      // The pop's page-route transition (a fade wrapping both the outgoing
      // and incoming route, per the default transitions builder) needs to
      // fully finish - and its cleanup (removing the outgoing route's
      // RenderObjects from the Overlay) needs a frame *after* that - before
      // the FAB underneath is actually hit-testable at its resting offset.
      // The 'add-fab' FloatingActionButton itself is a poor completion
      // signal here: it's the same persistent widget the whole time (never
      // rebuilt - PartScreen's own State outlives the push/pop), so a
      // widget-count/find check on it is satisfied instantly, before the
      // transition even starts. pumpAndSettle can't be used either -
      // confirmed on CI to time out here (PartViewport's Scene render loop
      // keeps scheduling frames indefinitely, same reason it's avoided
      // elsewhere in this file for the *initial* mesh-loading spinner).
      // Pumping many small steps (rather than one large jump) gives each
      // intermediate frame's post-frame callbacks - where the Overlay
      // actually drops the finished route's RenderObjects - a chance to run.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
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
