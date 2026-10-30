import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/appearance/appearance_panel.dart';
import 'package:didsa_cad_client/appearance/appearance_rule.dart' show appearanceErrors;
import 'package:didsa_cad_client/appearance/scenes_panel.dart';
import 'package:didsa_cad_client/assembly/assembly_document_client.dart';
import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/assembly/assembly_lens.dart';
import 'package:didsa_cad_client/assembly/reference_report.dart';
import 'package:didsa_cad_client/assembly/relative_path.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_panel.dart';
import 'package:didsa_cad_client/viewport3d/extrude_panel.dart';
import 'package:didsa_cad_client/viewport3d/feature_picker_sheet.dart' show kFeatureGroups;
import 'package:didsa_cad_client/viewport3d/measurement_panel.dart';
import 'package:didsa_cad_client/viewport3d/feature_context_menu.dart';
import 'package:didsa_cad_client/viewport3d/mirror_panel.dart';
import 'package:didsa_cad_client/viewport3d/multi_select_action_bar.dart';
import 'package:didsa_cad_client/viewport3d/assembly_component_selection_drawer.dart';
import 'package:didsa_cad_client/viewport3d/component_gizmo.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/part_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_toolbar.dart';
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
/// A `FileCache` that never touches `path_provider` or the real filesystem:
/// real async I/O does not settle inside `testWidgets`' fake-async pump loop
/// (`docs/flutter-widget-test-lessons.md`), and the composer writes to the
/// cache on every read.
class _NoopFileCache extends FileCache {
  @override
  Future<void> put(ProjectRoot root, String relativePath, Uint8List bytes, {DateTime? lastKnownModified}) async {}

  @override
  Future<CachedFile?> get(ProjectRoot root, String relativePath) async => null;

  @override
  Future<void> evict(ProjectRoot root, String relativePath) async {}
}

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

  /// Every Curve feature PATCH body, in order (the Helix edit test).
  final List<Map<String, dynamic>> curvePatchBodies = [];

  /// Every Spring feature POST / PATCH body, in order (the Spring tests).
  final List<Map<String, dynamic>> springBodies = [];

  /// LOD Phase 1 chunks 3/4/5 follow-up fix: every `GET .../mesh` request's
  /// query parameters, in call order - lets tests assert exactly when (and
  /// with what filters) a `tier=coarse` request fires alongside the
  /// ordinary full-tier one, instead of only ever seeing the latter's
  /// response.
  final List<Map<String, String>> meshRequests = [];

  /// Assembly support Phase 20 (`docs/assembly-scope.md` §6 `[24]`):
  /// [meshRequests]'/[featuresGetCount]'s own sibling for a non-`part-1`
  /// Part id - proves Feature-authoring/mesh-refresh really targets the
  /// *focused* Part once one is focused, not always the root.
  final Map<String, List<Map<String, String>>> meshRequestsByPartId = {};
  final Map<String, int> featuresGetRequestsByPartId = {};

  // Starts past every seeded Feature's id (seeds are always "feature-N" in
  // creation order) so a newly-created Feature's id never collides with a
  // seeded one.
  _FakeDocumentBackend({
    List<Map<String, dynamic>>? seedFeatures,
    List<Map<String, dynamic>>? seedOccurrences,
    List<Map<String, dynamic>>? seedMates,
    List<Map<String, dynamic>>? seedComponentPatterns,
  })  : features = seedFeatures ?? [],
        occurrences = seedOccurrences ?? [],
        mates = seedMates ?? [],
        componentPatterns = seedComponentPatterns ?? [] {
    _nextFeatureId = features.length + 1;
  }

  /// §6 roadmap Phase 10 (`[5]`): a minimal, mutable stand-in for a Part's
  /// own `occurrences` list, real enough to drive Hide/Show/Isolate's now-
  /// real `updateOccurrenceHidden` PATCH end to end through this harness -
  /// the gap `docs/assembly-scope.md` §2e/§2f/§2g/§2j each flagged and
  /// deferred, closed here as this phase's own one-time cost (future phases
  /// in the roadmap reuse it too). Each entry mirrors `OccurrenceDto.
  /// fromJson`'s own wire shape (`id`/`external_ref`/`resolved_part_id`/
  /// `name_override`/`transform`/`suppressed`/`hidden`).
  final List<Map<String, dynamic>> occurrences;

  /// Constrained drag (S7): every `mate-motion` request body (plus its grabbed occurrence id under
  /// `_occurrence_id`), the number of raw occurrence PATCHes that carried a `transform`, and the scripted answer.
  final List<Map<String, dynamic>> mateMotionRequests = [];
  int transformPatchCount = 0;
  http.Response Function(Map<String, dynamic> body, String occurrenceId)? mateMotionHandler;

  /// Assembly-audit gap `[27]` (`docs/assembly-scope.md`): [occurrences]'
  /// own siblings, needed for real end-to-end coverage of the cascade-
  /// delete warning and its Undo - previously this fake's own `GET .../
  /// mates`/`GET .../component-patterns` routes always answered `[]`
  /// unconditionally (no test before this gap ever needed a real Mate/
  /// ComponentPattern tracked here). Each entry mirrors `MateDto.fromJson`/
  /// `ComponentPatternDto.fromJson`'s own wire shape.
  final List<Map<String, dynamic>> mates;
  final List<Map<String, dynamic>> componentPatterns;

  /// The Appearance tool / scenes (V3 / S3): each Part's appearance overrides, every PUT body, `part-1`'s scenes and the
  /// scene POST / PATCH bodies.
  final Map<String, List<Map<String, dynamic>>> appearanceOverrides = {};
  final List<Map<String, dynamic>> appearancePuts = [];
  final List<Map<String, dynamic>> scenes = [];
  final List<Map<String, dynamic>> scenePosts = [];
  final List<Map<String, dynamic>> scenePatches = [];

  /// `GET .../constraint-status` for `part-1` (item 7) and how often it was
  /// asked - the tree refreshes it next to the occurrence list.
  final Map<String, dynamic> constraintStatus = {};
  int constraintStatusRequests = 0;
  int _nextMateId = 1;
  int _nextPatternId = 1;

  /// The current name of `part-1` itself - only ever changed by a real
  /// `POST /document/import/native` re-import (Phase 15's "Create
  /// Component"/"Save All"), never by the initial `createPart` alone.
  String partOneName = 'Part 1';

  /// Phase 15 (`docs/assembly-scope.md` §6): every Part id `POST
  /// /document/parts` has minted beyond the session's first ("Create
  /// Component…"), each a minimal stand-in (`id`/`name`/mutable
  /// `occurrences`) real enough to drive `export/native`/`import/native`
  /// end to end through this harness - the same one-time-cost precedent
  /// Phase 10 already set for [occurrences] itself.
  final Map<String, Map<String, dynamic>> extraParts = {};
  int _nextExtraPartId = 2;
  bool _createdPartOne = false;

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

    if (path == '/document/new' && method == 'POST') {
      // Bug fix (on-device feedback): `PartScreen._loadPart` now calls
      // this before its first `createPart` whenever `initialPartId` is
      // null - see `DocumentApiClient.startNewDocument`'s own doc
      // comment. Every test here that constructs a plain `PartScreen()`
      // with no `initialPartId` hits this first.
      return _json({'document_id': 'doc-1', 'part_ids': <String>[]}, 201);
    }

    if (path == '/document/parts' && method == 'POST') {
      // First call in any test is [_loadPart]'s own initial "part-1" -
      // every later call (Phase 15's "Create Component…") mints a genuinely
      // new id, matching the real backend's [Document.add_part] (never the
      // hardcoded-`'part-1'` shortcut this fake used to take, which would
      // have made a second-created Part collide with the first and trip
      // `mergeComponentIntoDocument`'s own self-reference guard).
      if (!_createdPartOne) {
        _createdPartOne = true;
        partOneName = body['name'] as String? ?? partOneName;
        return _json({
          'id': 'part-1',
          'name': partOneName,
          'feature_ids': features.map((f) => f['id']).toList(),
        }, 201);
      }
      final id = 'part-${_nextExtraPartId++}';
      extraParts[id] = {'id': id, 'name': body['name'], 'occurrences': <Map<String, dynamic>>[]};
      return _json({'id': id, 'name': body['name'], 'feature_ids': <String>[]}, 201);
    }

    final getPartMatch = RegExp(r'^/document/parts/([^/]+)$').firstMatch(path);
    if (getPartMatch != null && method == 'GET') {
      final id = getPartMatch.group(1);
      if (id == 'part-1') {
        return _json({
          'id': 'part-1',
          'name': partOneName,
          'feature_ids': features.map((f) => f['id']).toList(),
          'occurrence_ids': occurrences.map((o) => o['id']).toList(),
        }, 200);
      }
      final extra = extraParts[id];
      if (extra == null) return http.Response('not found: part', 404);
      return _json({
        'id': extra['id'],
        'name': extra['name'],
        'feature_ids': <String>[],
        'occurrence_ids': (extra['occurrences'] as List).map((o) => o['id']).toList(),
      }, 200);
    }

    // Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
    // §3.2): the assembly tree's own Rename action's `updatePart(name:...)`
    // call - only `name` is modeled here (this fake has no Part Properties
    // fields of its own to update).
    if (getPartMatch != null && method == 'PATCH') {
      final id = getPartMatch.group(1);
      final newName = body['name'] as String?;
      if (id == 'part-1') {
        if (newName != null) partOneName = newName;
        return _json({
          'id': 'part-1',
          'name': partOneName,
          'feature_ids': features.map((f) => f['id']).toList(),
        }, 200);
      }
      final extra = extraParts[id];
      if (extra == null) return http.Response('not found: part', 404);
      if (newName != null) extra['name'] = newName;
      return _json({'id': extra['id'], 'name': extra['name'], 'feature_ids': <String>[]}, 200);
    }

    // Phase 15 (`docs/assembly-scope.md` §6): `AssemblyDocumentClient.savePart`/
    // `saveAll`'s own `exportNative`/`importNative` round trip - real enough
    // to drive "Create Component…"/"Save All"/"Open Project…" end to end.
    // `part-1`'s own export reuses [features]/[occurrences] verbatim (this
    // fake's existing state, already wired to every other `part-1` route);
    // an extra Part (see [extraParts]) has no Feature machinery modeled at
    // all here, only the `id`/`name`/`occurrences` this phase's own flows
    // actually touch.
    if (path == '/document/export/native' && method == 'GET') {
      Map<String, dynamic> partDict(String id) => id == 'part-1'
          ? {
              'id': 'part-1',
              'name': partOneName,
              'features': features,
              'occurrences': occurrences,
              'mates': <dynamic>[],
              'component_patterns': <dynamic>[],
            }
          : {
              'id': id,
              'name': extraParts[id]!['name'],
              'features': <dynamic>[],
              'occurrences': extraParts[id]!['occurrences'],
              'mates': <dynamic>[],
              'component_patterns': <dynamic>[],
            };
      final requestedPartId = request.url.queryParameters['part_id'];
      final parts = requestedPartId == null
          ? [partDict('part-1'), for (final id in extraParts.keys) partDict(id)]
          : (requestedPartId == 'part-1' || extraParts.containsKey(requestedPartId))
              ? [partDict(requestedPartId)]
              : null;
      if (parts == null) return http.Response('not found: part', 404);
      return _json({
        'schema_version': 1,
        'document': {'id': 'doc-1', 'root_part_id': requestedPartId ?? 'part-1', 'parts': parts},
        'sketches': <dynamic>[],
      }, 200);
    }
    if (path == '/document/import/native' && method == 'POST') {
      final parts = ((body['document'] as Map?)?['parts'] as List?) ?? const [];
      for (final partRaw in parts) {
        if (partRaw is! Map) continue;
        final id = partRaw['id'] as String?;
        if (id == null) continue;
        // Real `native_format.py` defaults a missing/null `transform`
        // (and `suppressed`/`hidden`/`fixed`) on import to exactly what a
        // freshly-placed Occurrence already has (Phase 0's own §2) -
        // `mergeComponentIntoDocument`'s own newly-added Occurrence always
        // sends `'transform': null`, relying on that backend default; this
        // fake must apply the same default or `OccurrenceDto.fromJson`
        // (a real, non-nullable `transform`) throws on the next `GET
        // .../occurrences` this fake's own routes serve back out.
        final importedOccurrences = ((partRaw['occurrences'] as List?) ?? const [])
            .map((o) => Map<String, dynamic>.from(o as Map))
            .map(
              (o) => {
                ...o,
                'transform': o['transform'] ??
                    {
                      'translation': [0.0, 0.0, 0.0],
                      'rotation_axis': [0.0, 0.0, 1.0],
                      'rotation_angle_degrees': 0.0,
                    },
                'suppressed': o['suppressed'] ?? false,
                'hidden': o['hidden'] ?? false,
                'fixed': o['fixed'] ?? false,
              },
            )
            .toList();
        if (id == 'part-1') {
          occurrences
            ..clear()
            ..addAll(importedOccurrences);
          partOneName = partRaw['name'] as String? ?? partOneName;
        } else {
          extraParts[id] = {
            'id': id,
            'name': partRaw['name'] as String? ?? extraParts[id]?['name'] ?? 'Component',
            'occurrences': importedOccurrences,
          };
        }
      }
      return _json({'document_id': 'doc-1', 'part_ids': ['part-1', ...extraParts.keys]}, 200);
    }

    // Assembly support Phase 20 (`docs/assembly-scope.md` §6 `[24]`): the
    // mesh/feature-tree GET routes above were hardcoded to `part-1` only -
    // no test could previously distinguish "which Part's own mesh/features
    // got fetched," the exact thing Phase 20's `focusPartId` routing needs
    // proven. Additive-only (an extra branch ahead of the existing
    // `part-1`-only handlers below, never touching their own logic) -
    // returns a body/feature-id containing the requested Part's own id so a
    // test can tell them apart, and records every such request by Part id.
    final extraPartMeshMatch = RegExp(r'^/document/parts/([^/]+)/mesh$').firstMatch(path);
    if (extraPartMeshMatch != null && method == 'GET' && extraPartMeshMatch.group(1) != 'part-1') {
      final requestedId = extraPartMeshMatch.group(1)!;
      meshRequestsByPartId.putIfAbsent(requestedId, () => []).add(request.url.queryParameters);
      return _json([
        {'body_id': 'placeholder-$requestedId', 'source': 'placeholder', 'mesh': _placeholderMesh},
      ], 200);
    }
    final extraPartFeaturesMatch = RegExp(r'^/document/parts/([^/]+)/features$').firstMatch(path);
    if (extraPartFeaturesMatch != null && method == 'GET' && extraPartFeaturesMatch.group(1) != 'part-1') {
      featuresGetRequestsByPartId.putIfAbsent(extraPartFeaturesMatch.group(1)!, () => 0);
      featuresGetRequestsByPartId[extraPartFeaturesMatch.group(1)!] =
          featuresGetRequestsByPartId[extraPartFeaturesMatch.group(1)]! + 1;
      return _json(<Map<String, dynamic>>[], 200);
    }

    if (path == '/document/parts/part-1/mesh' && method == 'GET') {
      meshRequests.add(request.url.queryParameters);
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
      final patternSourceBodyIds =
          patternFeature.isNotEmpty ? (patternFeature['source_body_ids'] as List) : const [];
      // Pattern/Mirror scoping Phase 6: a Pattern seeded purely via
      // `source_feature_ids` has an empty `source_body_ids` - this fake
      // doesn't model resolving `source_feature_ids` into real instance
      // Body ids, so it falls through to the generic single-placeholder
      // mesh below instead of the scheme-correct instance-naming path.
      if (patternFeature.isNotEmpty && patternSourceBodyIds.isNotEmpty) {
        final seedId = patternSourceBodyIds.first as String;
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

    if (path == '/document/parts/part-1/merge-features' && method == 'POST') {
      for (final feature in features) {
        feature['locked'] = true;
      }
      final feature = {
        'type': 'merge',
        'id': 'feature-${_nextFeatureId++}',
        'body_ids': body['body_ids'],
        'locked': false,
      };
      features.add(feature);
      return _json(feature, 201);
    }

    if (path == '/document/parts/part-1/boolean-features' && method == 'POST') {
      for (final feature in features) {
        feature['locked'] = true;
      }
      final feature = {
        'type': 'boolean',
        'id': 'feature-${_nextFeatureId++}',
        'operation': body['operation'],
        'target_body_ids': body['target_body_ids'],
        'tool_body_ids': body['tool_body_ids'],
        'consume_tool_bodies': body['consume_tool_bodies'],
        'locked': false,
      };
      features.add(feature);
      return _json(feature, 201);
    }

    if (path == '/document/parts/part-1/split-features' && method == 'POST') {
      for (final feature in features) {
        feature['locked'] = true;
      }
      final feature = {
        'type': 'split',
        'id': 'feature-${_nextFeatureId++}',
        'target_body_id': body['target_body_id'],
        'tool': body['tool'],
        'locked': false,
      };
      features.add(feature);
      return _json(feature, 201);
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

    if (path == '/document/parts/part-1/spring-features' && method == 'POST') {
      springBodies.add(Map<String, dynamic>.from(body));
      final feature = {
        'type': 'spring',
        'id': 'spring-${springBodies.length}',
        ...body,
        'plane_ref': body['plane_ref'] ?? {'fixed_plane': 'XY'},
        'active_pitch': 4.0,
        'total_coils': 7.0,
        'solid_length': 6.5,
        'locked': false,
      };
      features.add(feature);
      return _json(feature, 201);
    }
    final springPatchMatch = RegExp(r'^/document/parts/part-1/spring-features/([^/]+)$').firstMatch(path);
    if (springPatchMatch != null && method == 'PATCH') {
      final feature = features.firstWhere((f) => f['id'] == springPatchMatch.group(1), orElse: () => {});
      if (feature.isEmpty) return http.Response('not found: feature', 404);
      springBodies.add(Map<String, dynamic>.from(body));
      feature.addAll(body);
      return _json(feature, 200);
    }

    final curvePatchMatch = RegExp(r'^/document/parts/part-1/curve-features/([^/]+)$').firstMatch(path);
    if (curvePatchMatch != null && method == 'PATCH') {
      final featureId = curvePatchMatch.group(1);
      final feature = features.firstWhere((f) => f['id'] == featureId, orElse: () => {});
      if (feature.isEmpty) return http.Response('not found: feature', 404);
      curvePatchBodies.add(Map<String, dynamic>.from(body));
      for (final key in ['radius', 'end_radius', 'segments', 'right_handed']) {
        if (body.containsKey(key)) feature[key] = body[key];
      }
      return _json(feature, 200);
    }

    final filletPatchMatch =
        RegExp(r'^/document/parts/part-1/fillet-features/([^/]+)$').firstMatch(path);
    if (filletPatchMatch != null && method == 'PATCH') {
      final featureId = filletPatchMatch.group(1);
      final feature = features.firstWhere((f) => f['id'] == featureId, orElse: () => {});
      if (feature.isEmpty) return http.Response('not found: feature', 404);
      if (body.containsKey('edge_refs')) feature['edge_refs'] = body['edge_refs'];
      if (body.containsKey('radius')) feature['radius'] = body['radius'];
      return _json(feature, 200);
    }

    final chamferPatchMatch =
        RegExp(r'^/document/parts/part-1/chamfer-features/([^/]+)$').firstMatch(path);
    if (chamferPatchMatch != null && method == 'PATCH') {
      final featureId = chamferPatchMatch.group(1);
      final feature = features.firstWhere((f) => f['id'] == featureId, orElse: () => {});
      if (feature.isEmpty) return http.Response('not found: feature', 404);
      if (body.containsKey('edge_refs')) feature['edge_refs'] = body['edge_refs'];
      if (body.containsKey('distance')) feature['distance'] = body['distance'];
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

    // §6 roadmap Phase 10 (`[5]`): the Assembly tree's own real fetch trio
    // (`_refreshAssemblyTree`), plus the mesh fetch Hide/Show/Isolate's own
    // PATCH-then-refetch also triggers - see [occurrences]'s own doc
    // comment. Keyed by *any* `part_id` (not just `part-1`), since "Make
    // Focus" re-fetches against whichever Part the focused Occurrence's own
    // `resolved_part_id` names - this fake only ever seeds real content for
    // `part-1` itself, every other `part_id` (a focused-into sub-Part this
    // fake never separately modeled) gets an empty-but-valid response.
    final occurrencesGetMatch = RegExp(r'^/document/parts/([^/]+)/occurrences$').firstMatch(path);
    if (occurrencesGetMatch != null && method == 'GET') {
      return _json(occurrencesGetMatch.group(1) == 'part-1' ? occurrences : <dynamic>[], 200);
    }
    // Item 7: the Assembly tree's constraint badge. Scripted by tests via
    // [constraintStatus]; empty by default (no badge, plain fixed pin).
    final constraintStatusMatch = RegExp(r'^/document/parts/([^/]+)/constraint-status$').firstMatch(path);
    if (constraintStatusMatch != null && method == 'GET') {
      constraintStatusRequests++;
      return _json(constraintStatusMatch.group(1) == 'part-1' ? constraintStatus : <String, dynamic>{}, 200);
    }
    final matesGetMatch = RegExp(r'^/document/parts/([^/]+)/mates$').firstMatch(path);
    if (matesGetMatch != null && method == 'GET') {
      return _json(matesGetMatch.group(1) == 'part-1' ? mates : <dynamic>[], 200);
    }
    if (matesGetMatch != null && method == 'POST') {
      final mate = {
        'id': 'mate-${_nextMateId++}',
        'type': body['type'],
        'references': body['references'],
        'value': body['value'],
        'flipped': body['flipped'] ?? false,
        'suppressed': false,
        'allow_rotation': body['allow_rotation'] ?? true,
      };
      mates.add(mate);
      return _json(mate, 201);
    }
    final mateDeleteMatch = RegExp(r'^/document/parts/part-1/mates/([^/]+)$').firstMatch(path);
    if (mateDeleteMatch != null && method == 'DELETE') {
      final mateId = mateDeleteMatch.group(1);
      final index = mates.indexWhere((m) => m['id'] == mateId);
      if (index == -1) return http.Response('not found: mate', 404);
      mates.removeAt(index);
      return http.Response('', 204);
    }
    final patternsGetMatch = RegExp(r'^/document/parts/([^/]+)/component-patterns$').firstMatch(path);
    if (patternsGetMatch != null && method == 'GET') {
      return _json(patternsGetMatch.group(1) == 'part-1' ? componentPatterns : <dynamic>[], 200);
    }
    if (patternsGetMatch != null && method == 'POST') {
      final pattern = {
        'id': 'pattern-${_nextPatternId++}',
        'source_occurrence_ids': body['source_occurrence_ids'],
        'pattern_type': body['pattern_type'] ?? 'linear',
        'direction': body['direction'] ?? [1.0, 0.0, 0.0],
        'count': body['count'] ?? 1,
        'spacing': body['spacing'] ?? 0.0,
        'reverse': body['reverse'] ?? false,
        'direction_2': body['direction_2'] ?? [0.0, 1.0, 0.0],
        'count_2': body['count_2'] ?? 1,
        'spacing_2': body['spacing_2'] ?? 0.0,
        'reverse_2': body['reverse_2'] ?? false,
        'axis': body['axis'],
        'count_angular': body['count_angular'] ?? 1,
        'angle_total': body['angle_total'] ?? 360.0,
        'reverse_angular': body['reverse_angular'] ?? false,
        'skip_indices': body['skip_indices'] ?? <dynamic>[],
        'orient_with_rotation': body['orient_with_rotation'] ?? true,
        'suppressed': false,
      };
      componentPatterns.add(pattern);
      return _json(pattern, 201);
    }
    final patternDeleteMatch =
        RegExp(r'^/document/parts/part-1/component-patterns/([^/]+)$').firstMatch(path);
    if (patternDeleteMatch != null && method == 'DELETE') {
      final patternId = patternDeleteMatch.group(1);
      final index = componentPatterns.indexWhere((p) => p['id'] == patternId);
      if (index == -1) return http.Response('not found: pattern', 404);
      componentPatterns.removeAt(index);
      return http.Response('', 204);
    }
    // The Appearance tool (V3): a Part's override list, kept per Part; PUT replaces the target's entry (null clears).
    final overridesMatch = RegExp(r'^/document/parts/([^/]+)/appearance-overrides$').firstMatch(path);
    if (overridesMatch != null) {
      final list = appearanceOverrides.putIfAbsent(overridesMatch.group(1)!, () => []);
      if (method == 'PUT') {
        appearancePuts.add(Map<String, dynamic>.from(body));
        String key(Map r) => '${r['path']}|${r['scope']}|${r['pattern_id']}|${r['part_id']}|${r['body_id']}|${(r['face'] as Map?)?['index']}';
        list.removeWhere((r) => key(r) == key(body));
        if (body['appearance'] != null) list.add(Map<String, dynamic>.from(body));
      }
      return _json({'overrides': list}, 200);
    }
    // Scenes (S3): `part-1`'s scenes; POST mints the id, PATCH replaces each field given.
    final scenesMatch = RegExp(r'^/document/parts/part-1/scenes(?:/([^/]+))?$').firstMatch(path);
    if (scenesMatch != null) {
      final sceneId = scenesMatch.group(1);
      if (sceneId == null && method == 'GET') return _json(scenes, 200);
      if (sceneId == null && method == 'POST') {
        scenePosts.add(Map<String, dynamic>.from(body));
        final scene = {'id': 'scene-${scenes.length + 1}', 'section_planes': <dynamic>[], 'viewpoint': null, ...body, 'unresolved': <dynamic>[]};
        scenes.add(scene);
        return _json(scene, 201);
      }
      final index = scenes.indexWhere((sc) => sc['id'] == sceneId);
      if (index == -1) return http.Response('not found: scene', 404);
      if (method == 'PATCH') {
        scenePatches.add(Map<String, dynamic>.from(body));
        scenes[index] = {...scenes[index], ...body};
        return _json(scenes[index], 200);
      }
      if (method == 'DELETE') {
        scenes.removeAt(index);
        return http.Response('', 204);
      }
    }
    final assemblyMeshMatch = RegExp(r'^/document/parts/([^/]+)/assembly-mesh$').firstMatch(path);
    if (assemblyMeshMatch != null && method == 'GET') {
      final forRoot = assemblyMeshMatch.group(1) == 'part-1';
      return _json({
        'geometry': <dynamic>[],
        'instances': [
          if (forRoot)
            for (final occurrence in occurrences)
              {
                'occurrence_path': [occurrence['id']],
                'part_id': occurrence['resolved_part_id'] ?? 'unresolved',
                'world_transform': occurrence['transform'],
                'hidden': occurrence['hidden'],
                'color': occurrence['color'],
              },
        ],
      }, 200);
    }
    final occurrencePatchMatch =
        RegExp(r'^/document/parts/part-1/occurrences/([^/]+)$').firstMatch(path);
    if (occurrencePatchMatch != null && method == 'PATCH') {
      final occurrenceId = occurrencePatchMatch.group(1);
      final occurrence = occurrences.firstWhere((o) => o['id'] == occurrenceId, orElse: () => const {});
      if (occurrence.isEmpty) return http.Response('not found: occurrence', 404);
      if (body.containsKey('transform')) {
        occurrence['transform'] = body['transform'];
        transformPatchCount++;
      }
      if (body.containsKey('hidden')) occurrence['hidden'] = body['hidden'];
      if (body.containsKey('fixed')) occurrence['fixed'] = body['fixed'];
      if (body.containsKey('color')) occurrence['color'] = (body['color'] as String).isEmpty ? null : body['color'];
      if (body.containsKey('name_override')) {
        occurrence['name_override'] = (body['name_override'] as String).isEmpty ? null : body['name_override'];
      }
      return _json(occurrence, 200);
    }
    // Assembly-audit gap `[27]` (`docs/assembly-scope.md`): the cascade
    // delete and its own client-supplied-id restore (Undo).
    if (occurrencesGetMatch != null && method == 'POST') {
      final id = body['id'] as String;
      if (occurrences.any((o) => o['id'] == id)) {
        return http.Response('already exists', 409);
      }
      final restored = {
        'id': id,
        'external_ref': body['external_ref'],
        'resolved_part_id': null,
        'name_override': body['name_override'],
        'transform': body['transform'] ??
            {
              'translation': [0.0, 0.0, 0.0],
              'rotation_axis': [0.0, 0.0, 1.0],
              'rotation_angle_degrees': 0.0,
            },
        'suppressed': body['suppressed'] ?? false,
        'hidden': body['hidden'] ?? false,
        'fixed': body['fixed'] ?? false,
        'color': body['color'],
      };
      occurrences.add(restored);
      return _json(restored, 201);
    }
    final mateMotionMatch =
        RegExp(r'^/document/parts/part-1/occurrences/([^/]+)/mate-motion$').firstMatch(path);
    if (mateMotionMatch != null && method == 'POST') {
      final handler = mateMotionHandler;
      if (handler == null) return http.Response('no mate-motion handler', 500);
      final id = mateMotionMatch.group(1)!;
      mateMotionRequests.add({...body, '_occurrence_id': id});
      return handler(body, id);
    }
    final occurrenceDeleteMatch =
        RegExp(r'^/document/parts/part-1/occurrences/([^/]+)$').firstMatch(path);
    if (occurrenceDeleteMatch != null && method == 'DELETE') {
      final occurrenceId = occurrenceDeleteMatch.group(1);
      final index = occurrences.indexWhere((o) => o['id'] == occurrenceId);
      if (index == -1) return http.Response('not found: occurrence', 404);
      mates.removeWhere(
        (m) => (m['references'] as List)
            .any((r) => (r as Map<String, dynamic>)['occurrence_id'] == occurrenceId),
      );
      componentPatterns.removeWhere(
        (p) => (p['source_occurrence_ids'] as List).contains(occurrenceId),
      );
      occurrences.removeAt(index);
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

/// Assembly support Phase 15 (`docs/assembly-scope.md` §6): a minimal fake
/// `StorageService`, same "copy the small fake, don't share it" convention
/// `assembly_document_client_test.dart`'s own `_FakeStorageService` already
/// establishes - `pickOrCreateProjectRoot` returns a fixed root immediately
/// rather than showing a real platform picker, so "Save All"/"Create
/// Component…"'s own [PartScreen] flows can be driven end to end here.
class _FakeStorageService implements StorageService {
  final Map<String, Uint8List> files = {};
  final DesktopProjectRoot root = const DesktopProjectRoot('/fake/project');

  /// Save/project overhaul Phase 3 (`docs/save-project-overhaul-scope.md`
  /// §3.3): how many times [writeFile] wrote to each relative path - lets a
  /// test confirm plain Save only ever rewrites the currently-focused
  /// Part's own file, never every loaded Part's (that's Save All's job).
  final Map<String, int> writeCounts = {};

  /// Phase 16 (`docs/assembly-scope.md` §2s): how many times
  /// [pickOrCreateProjectRoot] was actually invoked - lets a test confirm
  /// [presetLastUsedRoot] genuinely short-circuits the picker rather than
  /// merely returning the same root either way.
  int pickOrCreateProjectRootCallCount = 0;

  /// Phase 16: `null` by default (every pre-Phase-16 test's own behavior,
  /// unchanged) - set by a test to a specific [ProjectRoot] (or left `null`
  /// to simulate "nothing persisted yet") to drive `PartScreen
  /// ._ensureProjectRoot`'s new `lastUsedProjectRoot`-first path.
  ProjectRoot? presetLastUsedRoot;

  /// Item 2: simulates the user cancelling the SAF folder picker (the real
  /// services signal cancel by throwing, never by returning null).
  bool pickerCancels = false;

  /// Item 2: relative paths whose [writeFile] throws [StorageException] - a
  /// revoked grant, or a file deleted/moved since the last Save.
  final Set<String> failOnWrite = {};

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) async {
    pickOrCreateProjectRootCallCount++;
    if (pickerCancels) throw StorageException('No folder was selected');
    return root;
  }

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() async => presetLastUsedRoot;

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    if (!files.containsKey(relativePath)) return null;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async => files[handle.relativePath]!;

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) async {
    if (failOnWrite.contains(relativePath)) throw StorageException('Permission denied');
    files[relativePath] = bytes;
    writeCounts[relativePath] = (writeCounts[relativePath] ?? 0) + 1;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async => null;

  @override
  Future<bool> exists(FileHandle handle) async => files.containsKey(handle.relativePath);

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async => files.keys.toList();

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) async {
    if (!files.containsKey(relativePath)) {
      throw StorageException('Cannot rename $relativePath: no such file');
    }
    final newRelativePath = siblingRelativePath(relativePath, newFileName);
    if (files.containsKey(newRelativePath)) {
      throw StorageException('A file already exists at $newRelativePath');
    }
    files[newRelativePath] = files.remove(relativePath)!;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: newRelativePath, path: newRelativePath);
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

/// The phone layout's Start button.
final _startFab = find.byKey(const ValueKey('start-fab'));

Future<void> _settleSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

/// Opens the phone layout's Start menu (taps the Start button).
Future<void> openStartMenu(WidgetTester tester) async {
  await tester.tap(_startFab);
  await _settleSheet(tester);
}

/// Taps [label]'s tile in the Start menu - opening the menu first unless it is open, and choosing the tab [tab] (a
/// `RibbonTabData.id`: features, sketch, assembly, evaluate, view) when the tile is not on the lens's first tab. The menu
/// closes and the command runs, as for a user.
Future<void> tapStartCommand(WidgetTester tester, String label, {String? tab}) async {
  if (find.byKey(const ValueKey('start-menu')).evaluate().isEmpty) await openStartMenu(tester);
  if (tab != null) {
    await tester.tap(find.byKey(ValueKey('ribbon-tab-$tab')));
    await _settleSheet(tester);
  }
  final tile = find.byKey(ValueKey('start-tile-$label'));
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await _settleSheet(tester);
}

/// Opens the Start button's quick column the way a user can without a precise swipe: a long press on Start.
Future<void> openQuickColumn(WidgetTester tester) async {
  if (find.byKey(const ValueKey('quick-column')).evaluate().isNotEmpty) return;
  await tester.longPress(_startFab);
  await _settleSheet(tester);
}

/// Taps the quick-column button [key] (opening the column first), then lets it close.
Future<void> tapQuickButton(WidgetTester tester, String key) async {
  await openQuickColumn(tester);
  await tester.tap(find.byKey(ValueKey(key)));
  await _settleSheet(tester);
}

/// Flips Orbit / Select through the quick column.
Future<void> toggleSelectionMode(WidgetTester tester) => tapQuickButton(tester, 'quick-selection-mode-fab');

/// Opens the toolbar (File, View, Selection Filters) through the quick column's Menu button.
Future<void> openToolbar(WidgetTester tester) => tapQuickButton(tester, 'quick-menu-fab');

/// Switches the lens through the Start menu's Part / Assembly switch ([to] is 'Part' or 'Assembly') and closes the menu.
Future<void> switchLens(WidgetTester tester, String to) async {
  await openStartMenu(tester);
  await tester.tap(find.descendant(of: find.byKey(const ValueKey('start-lens')), matching: find.text(to)));
  await _settleSheet(tester);
  await tester.tap(find.byKey(const ValueKey('start-menu-close')));
  await _settleSheet(tester);
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
    await tapStartCommand(tester, 'New Sketch');
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
      // The button now lives in the Start button's quick column (a long press opens it).
      await openQuickColumn(tester);
      expect(find.byTooltip('Switch to selection mode'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is SvgIcon && w.asset == 'assets/icons/viewport/viewport_selection_mode.svg',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Switch to selection mode'));
      await _settleSheet(tester);

      // Every quick button closes the column once it has run: reopen it to read the new state.
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);
      await openQuickColumn(tester);
      expect(find.byTooltip('Switch to orbit mode'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is SvgIcon && w.asset == 'assets/icons/viewport/viewport_orbit_mode.svg',
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);

      // Switching back to Orbit mode removes the FAB's active styling and
      // the viewport's tinted border again.
      await tester.tap(find.byTooltip('Switch to orbit mode'));
      await _settleSheet(tester);

      await openQuickColumn(tester);
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

      await tapStartCommand(tester, 'New Sketch');
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

  group('New Sketch plane picking', () {
    Future<void> open(WidgetTester tester) async {
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
    }

    Future<void> startNewSketch(WidgetTester tester) async {
      await tapStartCommand(tester, 'New Sketch');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    bool planesHidden(WidgetTester tester) => tester.widget<PartViewport>(find.byType(PartViewport)).referencePlanesHidden;

    testWidgets('hidden reference planes are shown while a plane is being picked, and hidden again after Cancel', (
      tester,
    ) async {
      await open(tester);
      await openToolbar(tester);
      await tester.tap(find.text('View'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Hide Reference Planes'));
      await tester.pump();
      await tester.tap(find.text('Hide Reference Planes'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('toolbar-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(planesHidden(tester), isTrue, reason: 'the user hid them');

      await startNewSketch(tester);
      expect(planesHidden(tester), isFalse, reason: 'there has to be a plane to tap');

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(planesHidden(tester), isTrue, reason: 'back to what the user chose');
      expect(tester.takeException(), isNull);
    });

    testWidgets('in Selection mode a plane tap starts the sketch instead of just selecting the plane', (tester) async {
      await open(tester);
      await toggleSelectionMode(tester);
      await startNewSketch(tester);

      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
        const SelectionEntityRef(kind: SelectionEntityKind.referencePlane, referencePlaneKind: ReferencePlaneKind.xy),
      );
      await _pumpUntil(tester, () => find.text('Continue').evaluate().isNotEmpty);
      expect(find.text('Continue'), findsOneWidget, reason: 'the sketch orientation step, as an Orbit mode tap gives');
      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities,
        isEmpty,
        reason: 'the plane was not left selected',
      );
      await tester.tap(find.text('Continue'));
      await _pumpUntil(tester, () => find.text('DIDSA-CAD Sketch').evaluate().isNotEmpty);
      expect(find.text('DIDSA-CAD Sketch'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

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

    await openToolbar(tester);

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

      await openToolbar(tester);

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

  testWidgets('the Start button is hidden while the Extrude panel is open', (tester) async {
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
    expect(find.byTooltip('Start'), findsOneWidget);

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Extrude'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Confirm'), findsOneWidget);
    expect(find.byTooltip('Start'), findsNothing);
    expect(tester.takeException(), isNull);

    // Prompt A4's target-body-picker banner adds its own Cancel button
    // (top of the screen) alongside ExtrudePanel's own - both wired to the
    // same _cancelExtrude, so either one works; `.last` picks a single
    // widget rather than leaving the finder ambiguous.
    await tester.ensureVisible(find.text('Cancel').last);
    await tester.tap(find.text('Cancel').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byTooltip('Start'), findsOneWidget);
  });

  group('Start menu (phone layout)', () {
    Future<void> pumpScreen(WidgetTester tester) async {
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
    }

    testWidgets('the Part lens offers Features, Sketch, Evaluate and View, and Features lists every feature', (tester) async {
      await pumpScreen(tester);
      await openStartMenu(tester);
      for (final id in ['features', 'sketch', 'evaluate', 'view']) {
        expect(find.byKey(ValueKey('ribbon-tab-$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const ValueKey('ribbon-tab-assembly')), findsNothing);
      expect(find.byKey(const ValueKey('start-tile-New Sketch')), findsOneWidget);
      // The group titles and every tile come from the picker's own table.
      final list = find.descendant(of: find.byKey(const ValueKey('start-menu')), matching: find.byType(Scrollable)).first;
      for (final group in kFeatureGroups) {
        await tester.scrollUntilVisible(find.text(group.title), 200, scrollable: list);
        for (final entry in group.entries) {
          await tester.scrollUntilVisible(find.byKey(ValueKey('start-tile-${entry.label}')), 200, scrollable: list);
        }
      }
    });

    testWidgets('Measure and Section are Evaluate tiles, and the old Measure, Section and lens buttons are gone', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(find.byTooltip('Measure'), findsNothing);
      expect(find.byTooltip('Section'), findsNothing);
      expect(find.byTooltip('Assembly tree'), findsNothing);
      await openStartMenu(tester);
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-evaluate')));
      await tester.pump();
      expect(find.byKey(const ValueKey('start-tile-Measure')), findsOneWidget);
      expect(find.byKey(const ValueKey('start-tile-Section')), findsOneWidget);
    });

    testWidgets('the lens switch swaps the tabs in place, and the Assembly lens drops the Part-only tabs', (tester) async {
      await pumpScreen(tester);
      await openStartMenu(tester);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('start-lens')), matching: find.text('Assembly')));
      await _settleSheet(tester);
      expect(find.byKey(const ValueKey('start-menu')), findsOneWidget, reason: 'the sheet stays open');
      expect(find.byKey(const ValueKey('ribbon-tab-assembly')), findsOneWidget);
      expect(find.byKey(const ValueKey('ribbon-tab-features')), findsNothing);
      expect(find.byKey(const ValueKey('ribbon-tab-sketch')), findsNothing);
      expect(find.byKey(const ValueKey('start-tile-Add Component')), findsOneWidget);
      expect(find.byKey(const ValueKey('start-tile-Mate')), findsOneWidget);
    });

    testWidgets('a tile closes the sheet, then runs its command (Measure opens the Measure panel and Start hides)', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tapStartCommand(tester, 'Measure', tab: 'evaluate');
      expect(find.byKey(const ValueKey('start-menu')), findsNothing);
      expect(find.byType(MeasurementPanel), findsOneWidget);
      expect(find.byTooltip('Start'), findsNothing);
    });

    testWidgets('Start shows an X while its menu is open', (tester) async {
      await pumpScreen(tester);
      expect(find.descendant(of: _startFab, matching: find.byIcon(Icons.close)), findsNothing);
      await openStartMenu(tester);
      expect(find.descendant(of: _startFab, matching: find.byIcon(Icons.close)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('start-menu-close')));
      await _settleSheet(tester);
      expect(find.descendant(of: _startFab, matching: find.byIcon(Icons.close)), findsNothing);
    });

    testWidgets('an idle phone screen has no top-right buttons, no hamburger and no stand-alone Orbit / Select', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(find.byTooltip('Reset view'), findsNothing, reason: 'Fit is in the quick column');
      expect(find.byTooltip('Switch to selection mode'), findsNothing);
      expect(find.byTooltip('Open toolbar'), findsNothing);
      expect(find.byTooltip('Feature tree'), findsOneWidget, reason: 'the tree button stays top left');
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);
    });

    testWidgets('a long press opens the quick column: Menu, Fit and Orbit / Select, nearest Start first', (tester) async {
      await pumpScreen(tester);
      await openQuickColumn(tester);
      final start = tester.getTopLeft(_startFab).dy;
      final menu = tester.getTopLeft(find.byKey(const ValueKey('quick-menu-fab'))).dy;
      final fit = tester.getTopLeft(find.byKey(const ValueKey('quick-fit-fab'))).dy;
      final select = tester.getTopLeft(find.byKey(const ValueKey('quick-selection-mode-fab'))).dy;
      expect(menu, lessThan(start));
      expect(fit, lessThan(menu));
      expect(select, lessThan(fit));
    });

    testWidgets('a swipe up from Start opens the column', (tester) async {
      await pumpScreen(tester);
      await tester.drag(_startFab, const Offset(0, -80));
      await _settleSheet(tester);
      expect(find.byKey(const ValueKey('quick-column')), findsOneWidget);
      expect(find.byKey(const ValueKey('start-menu')), findsNothing, reason: 'a swipe is not a tap');
    });

    testWidgets('Menu opens the toolbar and closes the column; the toolbar closes with its own icon', (tester) async {
      await pumpScreen(tester);
      await openToolbar(tester);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);
      expect(tester.widget<PartToolbar>(find.byType(PartToolbar)).visible, isTrue);
      await tester.tap(find.byKey(const ValueKey('toolbar-close')));
      await _settleSheet(tester);
      expect(tester.widget<PartToolbar>(find.byType(PartToolbar)).visible, isFalse);
    });

    testWidgets('Fit closes the column', (tester) async {
      await pumpScreen(tester);
      await tapQuickButton(tester, 'quick-fit-fab');
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Orbit / Select flips the mode, closes the column, and Start shows the mode', (tester) async {
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('start-mode-badge')), findsNothing);
      await toggleSelectionMode(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectionMode, isTrue);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);
      expect(find.byKey(const ValueKey('start-mode-badge')), findsOneWidget);
      await toggleSelectionMode(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectionMode, isFalse);
      expect(find.byKey(const ValueKey('start-mode-badge')), findsNothing);
    });

    testWidgets('tapping X closes the column, and tapping Start with the column closed opens the menu', (tester) async {
      await pumpScreen(tester);
      await openQuickColumn(tester);
      await tester.tap(_startFab);
      await _settleSheet(tester);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);
      expect(find.byKey(const ValueKey('start-menu')), findsNothing, reason: 'X never opens the menu');
      await openStartMenu(tester);
      expect(find.byKey(const ValueKey('start-menu')), findsOneWidget);
    });

    testWidgets('the column closes when a tool session starts and is still closed when it ends', (tester) async {
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
      await openQuickColumn(tester);
      expect(find.byKey(const ValueKey('quick-column')), findsOneWidget);

      await tester.tap(find.byTooltip('Feature tree'));
      await _settleSheet(tester);
      await tester.longPress(find.text('Sketch 1'));
      await _settleSheet(tester);
      await tester.tap(find.byTooltip('More actions'));
      await _settleSheet(tester);
      await tester.tap(find.text('Extrude'));
      await _settleSheet(tester);
      expect(find.byTooltip('Start'), findsNothing, reason: 'the Extrude session hides Start');
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);

      await tester.ensureVisible(find.text('Cancel').last);
      await tester.tap(find.text('Cancel').last);
      await _settleSheet(tester);
      expect(find.byTooltip('Start'), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing, reason: 'it does not come back by itself');
    });

    testWidgets('the Start menu opening closes the column', (tester) async {
      await pumpScreen(tester);
      await openQuickColumn(tester);
      // The X closes the column; Start (now idle) opens the menu. A column that was left open never survives the menu.
      await tester.tap(_startFab);
      await _settleSheet(tester);
      await openStartMenu(tester);
      await tester.tap(find.byKey(const ValueKey('start-menu-close')));
      await _settleSheet(tester);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);
    });

    testWidgets('the last tab used is remembered per lens for the session', (tester) async {
      await pumpScreen(tester);
      await openStartMenu(tester);
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-view')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('start-menu-close')));
      await _settleSheet(tester);
      await openStartMenu(tester);
      expect(find.byKey(const ValueKey('start-tile-Fit')), findsOneWidget, reason: 'reopened on View');
    });
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

    // The toolbar's Menu button is left out of the quick column while the tree is open (the tree's own X button is the
    // way to close it instead); the column's other buttons are still there.
    await openQuickColumn(tester);
    expect(find.byKey(const ValueKey('quick-menu-fab')), findsNothing);
    expect(find.byKey(const ValueKey('quick-fit-fab')), findsOneWidget);
    expect(find.byTooltip('Close toolbar'), findsNothing);
    await tester.tap(_startFab); // the X closes the column again
    await _settleSheet(tester);

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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // Bug fix: a Sketch row's context menu now also offers "Extrude
    // Surface", pushing Delete further down - off the fixed 800x600 test
    // viewport - than it sat before.
    await tester.ensureVisible(find.text('Delete'));
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

  testWidgets(
    'desktop input D4: a mouse right click on a Build Tree row opens the row menu as a popup at the cursor, '
    'without entering multi-select; a touch long-press still enters it',
    (tester) async {
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

      final row = tester.getCenter(find.text('Sketch 1'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await mouse.down(row);
      await mouse.up();
      await _pumpUntil(tester, () => find.byType(PopupMenuItem<FeatureContextMenuAction>).evaluate().isNotEmpty);

      expect(find.byType(BottomSheet), findsNothing, reason: 'a mouse gets the popup, not the touch sheet');
      expect(find.widgetWithText(PopupMenuItem<FeatureContextMenuAction>, 'Delete'), findsOneWidget);
      expect(find.byTooltip('More actions'), findsNothing, reason: 'a right click does not start multi-select');
      await tester.pump(const Duration(milliseconds: 400)); // (the menu scales in)
      final popup = tester.getTopLeft(find.byType(PopupMenuItem<FeatureContextMenuAction>).first);
      // (A tall menu is moved up to fit the 600 px test screen, so only the x of the cursor is checked.)
      expect((popup.dx - row.dx).abs(), lessThan(40), reason: 'the popup opens at the cursor');

      // A click outside closes it, then a touch long-press behaves as before.
      await tester.tapAt(const Offset(790, 590));
      await _pumpUntil(tester, () => find.byType(PopupMenuItem<FeatureContextMenuAction>).evaluate().isEmpty);
      expect(find.byType(PopupMenuItem<FeatureContextMenuAction>), findsNothing);
      await tester.longPress(find.text('Sketch 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('More actions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop input D5: Space opens the view cube, a click on it closes it; Ctrl+8 with nothing selected does nothing',
    (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
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

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byKey(const Key('view-cube')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpUntil(tester, () => find.byKey(const Key('view-cube')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('view-cube')), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Normal To')).onPressed, isNull);

      await tester.tap(find.byKey(const Key('view-cube')));
      await _pumpUntil(tester, () => find.byKey(const Key('view-cube')).evaluate().isEmpty);
      expect(find.byKey(const Key('view-cube')), findsNothing);
      // The pick turns the view over 400 ms: let it finish before the test ends.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop input D5: a double-click on a Feature row opens it once, not twice', (tester) async {
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

    // Two clicks on the row before anything has had time to open.
    final row = tester.getCenter(find.text('Sketch 1'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 2; i++) {
      await mouse.down(row);
      await mouse.up();
    }
    await _pumpUntil(tester, () => find.text('DIDSA-CAD Sketch').evaluate().isNotEmpty);
    expect(find.text('DIDSA-CAD Sketch'), findsOneWidget);
    expect(find.byType(SketchScreen), findsOneWidget, reason: 'one Sketch screen on the stack, not two');
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // Bug fix: a Sketch row's context menu now also offers "Extrude
    // Surface", pushing Delete further down - off the fixed 800x600 test
    // viewport - than it sat before.
    await tester.ensureVisible(find.text('Delete'));
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

  testWidgets('Bug fix: tapping a Merge row in the Feature tree opens it for editing', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'merge',
          'id': 'feature-2',
          'body_ids': ['body-1', 'body-2'],
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

    // No "Booleans" section anymore - the Merge row lives only in the
    // ordinary, always-expanded Features section.
    expect(find.text('Merge 1'), findsOneWidget);

    await tester.tap(find.text('Merge 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Edit Merge'), findsOneWidget);
    expect(find.text('Merging 2 bodies'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Boolean family, Subtract/Common: tapping a Subtract row in the Feature tree opens it for editing',
      (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'boolean',
          'id': 'feature-2',
          'operation': 'subtract',
          'target_body_ids': ['body-1'],
          'tool_body_ids': ['body-2'],
          'consume_tool_bodies': true,
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

    // No dedicated Booleans section - the Subtract row lives only in the
    // ordinary, always-expanded Features section, same as Merge's own row.
    expect(find.text('Subtract 1'), findsOneWidget);

    await tester.tap(find.text('Subtract 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Edit Subtract'), findsOneWidget);
    expect(find.text('Subtracting 1 tool body from 1 target body'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bug fix: tapping a Surface row in the Feature tree opens it for editing', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'surface',
          'id': 'feature-2',
          'sketch_feature_id': 'feature-1',
          'start_distance': 0.0,
          'end_distance': 5.0,
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

    expect(find.text('Surface 1'), findsOneWidget);

    await tester.tap(find.text('Surface 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Edit Surface'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Bug fix: long-pressing a SketchFeature shows "Extrude Surface", always enabled '
    'even when the Sketch has no closed profile (a Surface accepts open wires too)',
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
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final surfaceTile = find.widgetWithText(ListTile, 'Extrude Surface');
      expect(surfaceTile, findsOneWidget);
      expect(tester.widget<ListTile>(surfaceTile).enabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Bug fix: long-pressing a non-Sketch Feature row does not show "Extrude Surface"', (
    tester,
  ) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {
          'type': 'extrude',
          'id': 'feature-1',
          'sketch_feature_id': 'sketch-feature-0',
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Extrude Surface'), findsNothing);
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // Boolean family, Subtract/Common: the context menu now offers two more
    // entries (Subtract/Common, alongside Merge) for any body-producing
    // Feature row - Delete sits low enough in the taller sheet to land
    // outside the fixed 800x600 test viewport, same class of failure this
    // branch's own earlier "scroll before tapping" fixes already hit.
    await tester.ensureVisible(find.text('Delete'));
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

  testWidgets('a Spring is created from the Add picker and edited from the Build Tree', (tester) async {
    final backend = _FakeDocumentBackend(seedFeatures: []);
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

    await tapStartCommand(tester, 'Spring');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Create Spring'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('spring-wire')), '0.3');
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await _pumpUntil(tester, () => backend.springBodies.isNotEmpty);
    final created = backend.springBodies.single;
    expect(created['wire_diameter'], 0.3);
    expect(created['mean_diameter'], 10.0);
    expect(created['start_end'], 'closed_ground');
    expect(created['plane_ref'], {'fixed_plane': 'XY'});
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Spring 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Edit Spring'), findsOneWidget);
    expect(find.byKey(const ValueKey('spring-readout')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('spring-length')), '25');
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await _pumpUntil(tester, () => backend.springBodies.length == 2);
    expect(backend.springBodies.last['free_length'], 25.0);
    expect(backend.springBodies.last['wire_diameter'], 0.3);
  });

  testWidgets('bug report: a Helix opens for editing from the Build Tree, in diameters, and PATCHes radii',
      (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {
          'type': 'curve',
          'id': 'feature-1',
          'curve_type': 'helix',
          'axis_ref': {'fixed_plane': 'XY'},
          'radius': 5.0,
          'end_radius': null,
          'segments': [
            {'pitch': 2.0, 'turns': 10.0},
          ],
          'right_handed': true,
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
    expect(find.text('Imported'), findsNothing); // shown as editable
    await tester.tap(find.text('Helix 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Edit Helix'), findsOneWidget);
    expect(find.text('Axis: XY plane'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('helix-diameter-field'))).controller!.text, '10');

    await tester.enterText(find.byKey(const ValueKey('helix-diameter-field')), '12');
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await _pumpUntil(tester, () => backend.curvePatchBodies.isNotEmpty);

    final patch = backend.curvePatchBodies.single;
    expect(patch['radius'], 6.0);
    expect(patch.containsKey('end_radius'), isTrue); // explicit null: still constant
    expect(patch['end_radius'], isNull);
    expect(patch['segments'], [
      {'pitch': 2.0, 'turns': 10.0},
    ]);
  });

  testWidgets(
      'Bug fix: confirming a Fillet edit re-fetches the Feature list, so it '
      'still shows in the Build Tree afterward (identical latent gap to the '
      'Pattern/Mirror "stopped showing in the feature tree" bug, carried '
      'over to Fillet/Chamfer)', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'fillet',
          'id': 'feature-2',
          'edge_refs': [
            {'body_id': 'placeholder', 'shape_type': 'edge', 'index': 0},
          ],
          'radius': 2.0,
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
    await tester.tap(find.text('Fillet 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Edit Fillet'), findsOneWidget);
    // FilletPanel's own initState eager debounced update - see the Pattern
    // regression test above for why this pump is needed here too.
    await tester.pump(const Duration(milliseconds: 600));

    final featuresGetCountBeforeConfirm = backend.featuresGetCount;

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(backend.featuresGetCount, greaterThan(featuresGetCountBeforeConfirm));
    expect(tester.takeException(), isNull);

    // The tree still shows the Fillet, proving _features itself was
    // actually updated with the fresh fetch's own result, not merely that
    // a network call happened.
    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Fillet 1'), findsOneWidget);
  });

  testWidgets(
      'Bug fix: confirming a Chamfer edit re-fetches the Feature list, so it '
      'still shows in the Build Tree afterward (identical latent gap to the '
      'Pattern/Mirror "stopped showing in the feature tree" bug, carried '
      'over to Fillet/Chamfer)', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'chamfer',
          'id': 'feature-2',
          'edge_refs': [
            {'body_id': 'placeholder', 'shape_type': 'edge', 'index': 0},
          ],
          'distance': 1.0,
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
    await tester.tap(find.text('Chamfer 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Edit Chamfer'), findsOneWidget);
    // ChamferPanel's own initState eager debounced update - see the Pattern
    // regression test above for why this pump is needed here too.
    await tester.pump(const Duration(milliseconds: 600));

    final featuresGetCountBeforeConfirm = backend.featuresGetCount;

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(backend.featuresGetCount, greaterThan(featuresGetCountBeforeConfirm));
    expect(tester.takeException(), isNull);

    // The tree still shows the Chamfer, proving _features itself was
    // actually updated with the fresh fetch's own result, not merely that
    // a network call happened.
    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Chamfer 1'), findsOneWidget);
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Pattern'), findsNothing);
  });

  testWidgets(
      'Pattern/Mirror scoping Phase 9: long-pressing an eligible Cut Feature still offers the '
      'plain "Pattern"/"Mirror" entries, and tapping "Pattern" opens PatternPanel seeded via '
      'tool_feature_id by default, with the Body/Feature toggle shown', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'extrude',
          'id': 'feature-2',
          'sketch_feature_id': 'feature-1',
          'extrude_type': 'cut',
          'start_distance': 0.0,
          'end_distance': 10.0,
          'target_body_ids': ['feature-0'],
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // Phase 9: the old separate "Pattern into Target"/"Mirror into Target"
    // entries are gone - a tool-feature-eligible Cut/Boss now shows the
    // exact same "Pattern"/"Mirror" entries as any other body-producing
    // Feature (see FeatureContextMenuAction's own doc comment).
    expect(find.text('Pattern'), findsOneWidget);
    expect(find.text('Mirror'), findsOneWidget);
    expect(find.text('Pattern into Target'), findsNothing);
    expect(find.text('Mirror into Target'), findsNothing);

    await tester.tap(find.text('Pattern'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Straight to `configuring` (no pickingBodies ribbon/step). Extrude 1
    // qualifies for both seed kinds (body-producing *and* tool-feature-
    // eligible), so it defaults to tool_feature_id mode (its own status
    // line replaces the ordinary merge toggle/sourceFeatureIds row - see
    // PatternPanel.toolFeatureSummary) and shows the Body/Feature toggle.
    expect(find.byType(PatternPanel), findsOneWidget);
    expect(find.text('Edit Pattern'), findsNothing);
    expect(find.text('Select Body to Pattern'), findsNothing);
    expect(find.textContaining('Patterning Extrude 1 into its own target'), findsOneWidget);
    expect(find.text('Pattern Body'), findsOneWidget);
    expect(find.text('Pattern Feature'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Toggling to Body mode swaps the seed field and status line, still
    // seeded from the same Extrude 1 Feature.
    await tester.tap(find.text('Pattern Body'));
    await tester.pump();
    expect(find.textContaining('Patterning Extrude 1 into its own target'), findsNothing);
    expect(find.text('1 Feature added from the Build Tree'), findsOneWidget);

    // direction_1 is still unset, so the debounced live-preview never
    // actually fires a network call - pump past it so no Timer is left
    // pending when this test tears down (mirrors the Phase 6 precedent
    // test's own identical note).
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Pattern/Mirror scoping Phase 9: tapping "Mirror" on an eligible Cut Feature opens '
      'MirrorPanel directly at the pickingPlane step, seeded via tool_feature_id by default '
      '(the entry-point asymmetry fix - Mirror never had this long-press entry before)',
      (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {
          'type': 'extrude',
          'id': 'feature-2',
          'sketch_feature_id': 'feature-1',
          'extrude_type': 'cut',
          'start_distance': 0.0,
          'end_distance': 10.0,
          'target_body_ids': ['feature-0'],
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('Mirror'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // MirrorPanel opens immediately (mirror_plane still required in
    // tool_feature_id mode), showing its own status line, the Body/Feature
    // toggle (Extrude 1 qualifies for both), and no plane picked yet -
    // Confirm stays disabled until one is.
    expect(find.byType(MirrorPanel), findsOneWidget);
    expect(find.text('Edit Mirror'), findsNothing);
    expect(find.textContaining('Mirroring Extrude 1 into its own target'), findsOneWidget);
    expect(find.text('Mirror Body'), findsOneWidget);
    expect(find.text('Mirror Feature'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);

    // Toggling to Body mode swaps the seed field and status line.
    await tester.tap(find.text('Mirror Body'));
    await tester.pump();
    expect(find.textContaining('Mirroring Extrude 1 into its own target'), findsNothing);
    expect(find.text('1 Feature added from the Build Tree'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Unlike Pattern's own debounce, [PartScreen._scheduleMirrorPreview]
    // always starts its Timer regardless of whether a plane is picked yet
    // (the "nothing to preview" guard only runs once the Timer fires) - pump
    // past it so no Timer is left pending when this test tears down.
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Pattern/Mirror scoping Phase 9: long-pressing a targetless Boss (body-producing but not '
      'tool-feature-eligible) still offers "Pattern"/"Mirror", opening in source_feature_ids '
      'mode with the Body/Feature toggle hidden (only qualifies for one seed kind)',
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

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.longPress(find.text('Extrude 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Still offers the unified "Pattern"/"Mirror" entries - the old,
    // separate tool_feature_id-mode entries are gone entirely (Phase 9).
    expect(find.text('Pattern'), findsOneWidget);
    expect(find.text('Mirror'), findsOneWidget);
    expect(find.text('Pattern into Target'), findsNothing);
    expect(find.text('Mirror into Target'), findsNothing);

    await tester.tap(find.text('Pattern'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // A targetless Boss isn't tool-feature-eligible, so this opens in the
    // ordinary source_feature_ids mode by default, with no Body/Feature
    // toggle at all (nothing to toggle - it only qualifies for one kind).
    expect(find.byType(PatternPanel), findsOneWidget);
    expect(find.text('1 Feature added from the Build Tree'), findsOneWidget);
    expect(find.textContaining('into its own target'), findsNothing);
    expect(find.text('Pattern Body'), findsNothing);
    expect(find.text('Pattern Feature'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
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

    await tapStartCommand(tester, 'Pattern');

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
      'Bug fix: a Pattern seeded purely from a source Feature (empty source_body_ids) still opens '
      'for edit and still sends its live-preview PATCH ("trying to pattern a feature produced no new '
      'bodies, no new entry in the tree, no preview is shown - fails silently" on-device feedback)',
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
          'locked': true,
        },
        {
          'type': 'pattern',
          'id': 'feature-3',
          'source_body_ids': <String>[],
          'source_feature_ids': ['feature-2'],
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

    // Before the fix, [_openPatternPanelForEdit]'s own `sourceBodyIds.
    // isEmpty` guard bailed out (`false`, no panel) for exactly this shape -
    // tapping the row did nothing at all, silently.
    expect(find.text('Edit Pattern'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // PatternPanel's own initState eagerly re-emits its initial field
    // values, scheduling a debounced live-preview PATCH. Before the fix,
    // [_schedulePatternPreview]'s own guard bailed out here too (empty
    // `_patternSourceBodyIds`, regardless of `_patternSourceFeatureIds`),
    // so nothing was ever sent.
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(backend.lastPatternPatchBody, isNotNull);
    expect(backend.lastPatternPatchBody?['source_feature_ids'], ['feature-2']);
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
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

  // LOD Phase 1 chunks 3/4/5 follow-up fix: a coordinator review of PR #175
  // found `_refreshMesh` firing its background `tier=coarse` fetch
  // unconditionally, on every one of its ~38 call sites, rather than only
  // `01-design.md` SS4/SS5's "re-opening a Part" flow. The two tests below
  // pin the fix down.
  testWidgets(
      'the initial Part load fires exactly one tier=coarse mesh fetch; a routine post-edit '
      'refresh (Hide/Show) fetches the full mesh again but never re-fires the coarse one', (tester) async {
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
    // Lets the fire-and-forget `_refreshCoarseOverlay` triggered by the
    // initial load settle before the counts below are read.
    await tester.pump(const Duration(milliseconds: 250));

    final coarseRequestsAfterLoad = backend.meshRequests.where((q) => q['tier'] == 'coarse').length;
    expect(coarseRequestsAfterLoad, 1, reason: 'initial load must fire exactly one coarse-tier fetch');
    final totalMeshRequestsAfterLoad = backend.meshRequests.length;

    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Hide'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // The routine Hide/Show edit still goes through `_refreshMesh` (its
    // full-tier fetch must still fire, same as before this fix)...
    expect(backend.meshRequests.length, greaterThan(totalMeshRequestsAfterLoad));
    // ...but must never fire another `tier=coarse` request - that's the
    // regression this fix closes.
    expect(backend.meshRequests.where((q) => q['tier'] == 'coarse').length, coarseRequestsAfterLoad);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the initial-load coarse-tier mesh fetch passes the same hiddenFeatureIds/'
      'rollbackExcludedFeatureIds/meshQuality filters as the full-tier fetch it runs alongside',
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
          initialHiddenFeatureIds: const ['feature-1'],
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 250));

    final coarseRequest = backend.meshRequests.firstWhere((q) => q['tier'] == 'coarse');
    final fullRequest = backend.meshRequests.firstWhere((q) => q['tier'] != 'coarse');

    expect(coarseRequest['hidden_feature_ids'], 'feature-1');
    expect(coarseRequest['hidden_feature_ids'], fullRequest['hidden_feature_ids']);
    expect(coarseRequest['rollback_excluded_feature_ids'], fullRequest['rollback_excluded_feature_ids']);
    expect(coarseRequest['quality'], isNotNull);
    expect(coarseRequest['quality'], fullRequest['quality']);
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
    'Bug fix ("XYZ triad hidden behind any open tool panel", docs/roadmap.md): '
    'PartViewport.anchorTriadAtOrigin is false with no tool panel open, true while the New '
    'Sketch plane picker or an Extrude panel is open (two different tools, not just '
    'Pattern/Mirror), and false again once that session ends',
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

      bool anchored() => tester.widget<PartViewport>(find.byType(PartViewport)).anchorTriadAtOrigin;

      // Baseline: nothing open yet.
      expect(anchored(), isFalse);

      // Tool 1: the "New Sketch" plane picker (a PickerRibbon-backed mode,
      // not a full ResizableToolPanel, but still a Stack overlay covering
      // the viewport's own bottom-left corner).
      await tapStartCommand(tester, 'New Sketch');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(anchored(), isTrue);

      tester.widget<PartViewport>(find.byType(PartViewport)).onBackgroundTap();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(anchored(), isFalse);

      // Tool 2: ExtrudePanel, via the same long-press "Extrude" flow the
      // sibling test below exercises in full.
      await tester.tap(find.byTooltip('Feature tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.longPress(find.text('Sketch 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Extrude'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(ExtrudePanel), findsOneWidget);
      expect(anchored(), isTrue);

      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(anchored(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

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
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
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

      await tester.ensureVisible(find.text('Confirm'));
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
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
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
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Extrude'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Still hidden - opening either would abandon the in-progress Extrude.
      expect(find.byTooltip('Feature tree'), findsNothing);
      expect(find.byKey(const ValueKey('quick-menu-fab')), findsNothing);
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
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final extrudeTile = find.widgetWithText(ListTile, 'Extrude');
      expect(extrudeTile, findsOneWidget);
      expect(tester.widget<ListTile>(extrudeTile).enabled, isFalse);
      // Revolve/Sweep share Extrude's own eligibility check (see
      // _onFeatureLongPress) and so show the identical disabled-reason
      // subtitle alongside it - three, not one.
      expect(find.text('Sketch does not contain a closed profile'), findsNWidgets(3));
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
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
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
      await tapStartCommand(tester, 'Extrude');
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

      await tester.ensureVisible(find.text('Confirm'));
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
        await tester.ensureVisible(find.text('Confirm'));
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
        // Feature 1 (tree multi-select): long-press now enters multi-select;
        // the row's own context menu is behind the action bar's "More".
        await tester.tap(find.byTooltip('More actions'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        // Boolean family, Subtract/Common: the context menu now offers two
        // more entries (Subtract/Common, alongside Merge) for any body-
        // producing Feature row - Delete sits low enough in the taller sheet
        // to land outside the fixed 800x600 test viewport, same class of
        // failure this branch's own earlier "scroll before tapping" fixes
        // already hit.
        await tester.ensureVisible(find.text('Delete'));
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
        await tester.ensureVisible(find.text('Confirm'));
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
        // Feature 1 (tree multi-select): long-press now enters multi-select;
        // the row's own context menu is behind the action bar's "More".
        await tester.tap(find.byTooltip('More actions'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        // Boolean family, Subtract/Common: mirrors the identical fix in the
        // test just above - Delete now sits outside the fixed 800x600 test
        // viewport once Subtract/Common join the context menu.
        await tester.ensureVisible(find.text('Delete'));
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
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
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
    await tester.ensureVisible(find.text('Cancel').last);
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
      await openToolbar(tester);

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

  // Direct Editing family: all five (Delete Body, Scale Body, Move Body,
  // Delete Face, Move Face) were ambient-entry-only before this - reachable
  // only by selecting a Body/face in the viewport first, with no path from
  // the "Add" FAB's Feature picker at all. This group covers the new guided
  // entries reaching the same state the ambient path already does - Delete
  // Body/Scale Body/Move Body open their own picking-step [PickerRibbon]
  // (mirrors `tapAddFeatureExtrude`'s own "Add > Feature > section > entry"
  // navigation, generalized to the "Direct Edit" section), Delete Face/Move
  // Face open their own panel directly with zero faces yet (mirrors
  // [_startFilletPicker]'s identical shape) - none of these need a real
  // Body/face in the fake backend, since reaching a picking state (not
  // actually completing one) is as far as this suite's own viewport-tap
  // simulation goes for every other guided "Add" FAB entry in this file
  // (Merge/Boolean/Split/Pattern's own guided body-picking steps have no
  // simulated-viewport-tap coverage here either).
  group('Direct Editing family - guided "Add" FAB entries', () {
    Future<void> tapAddFeatureDirectEdit(WidgetTester tester, String entryLabel) async {
      await tapStartCommand(tester, entryLabel);
    }

    Future<void> pumpPartScreen(WidgetTester tester) async {
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
    }

    testWidgets('Delete Body opens a picking ribbon requiring 1+ Bodies', (tester) async {
      await pumpPartScreen(tester);
      await tapAddFeatureDirectEdit(tester, 'Delete Body');

      expect(find.text('Select body/bodies to delete'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Scale Body opens a single-tap-auto-advance picking ribbon', (tester) async {
      await pumpPartScreen(tester);
      await tapAddFeatureDirectEdit(tester, 'Scale Body');

      expect(find.text('Select a body to scale'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Move/Copy Body opens a single-tap-auto-advance picking ribbon', (tester) async {
      await pumpPartScreen(tester);
      await tapAddFeatureDirectEdit(tester, 'Move/Copy Body');

      expect(find.text('Select a body to move'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Delete Face opens the real panel directly with zero faces picked', (tester) async {
      await pumpPartScreen(tester);
      await tapAddFeatureDirectEdit(tester, 'Delete Face');

      expect(find.text('Delete Face'), findsWidgets);
      expect(find.text('Tap one or more faces of the same body to delete'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete')).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Move Face opens the real panel directly with zero faces picked', (tester) async {
      await pumpPartScreen(tester);
      await tapAddFeatureDirectEdit(tester, 'Move Face');

      expect(find.text('Tap one or more faces of the same body to move'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      // [MoveFacePanel]'s own `initState` postFrameCallback fires
      // `onOffsetChanged` for the default offset, which schedules a 500ms
      // debounce (a no-op here - _ensureMoveFaceFeatureExists skips a still-
      // empty face_refs) - let it settle before the test ends, or the
      // pending-timer invariant check fails (mirrors every other debounce-
      // triggering test in this file's own `milliseconds: 600` convention).
      await tester.pump(const Duration(milliseconds: 600));
    });
  });

  // Bug fix (on-device feedback, re-tested live after this round's other
  // fixes: "clicking a flat face or plane should set the section position
  // and orientation to be coplanar with the selected face or plane" stopped
  // working partway through an ordinary session): `PartViewport`'s own
  // `_handleTap`-based Section-placement logic only ever runs from the
  // Orbit-mode-only tap path, unreachable whenever `PartScreen._selectionMode`
  // is on - and since ~50 of this file's own call sites turn that on (vs. 2
  // that ever turn it back off), a perfectly ordinary "use Extrude, then open
  // Section" session already leaves it on for the rest of that session. See
  // `PartScreen._tryHandleSectionPlacementToggle`'s own doc comment for the
  // full root-cause writeup. `onSelectionToggle` is the one dispatcher every
  // viewport tap reaches regardless of Selection mode (mirrors this file's
  // own Skip-instances-redesign tests just above, which drive the same
  // callback directly rather than simulating a raw pointer gesture) - this
  // exercises the exact code path a real tap takes while Selection mode is
  // on, the case the old Orbit-mode-only implementation could never reach.
  group('Sectioning Tool bug fix: face tap reanchors regardless of Selection mode', () {
    testWidgets(
        'onSelectionToggle with a face entity reanchors the active section to '
        "that face's own plane", (tester) async {
      // Two single-triangle faces with distinct, known normals/positions -
      // face 0 a "top" cap (normal +Z, through z=10), face 1 a "side" wall
      // (normal +X, through x=5) - enough to prove a tap re-derives the
      // plane from the *tapped* face, not just leaves whatever was already
      // there (the bug's own failure mode: the tap silently no-ops).
      final mesh = {
        'vertices': [
          [0.0, 0.0, 10.0],
          [1.0, 0.0, 10.0],
          [0.0, 1.0, 10.0],
          [5.0, 0.0, 0.0],
          [5.0, 1.0, 0.0],
          [5.0, 0.0, 1.0],
        ],
        'normals': [
          [0.0, 0.0, 1.0],
          [0.0, 0.0, 1.0],
          [0.0, 0.0, 1.0],
          [1.0, 0.0, 0.0],
          [1.0, 0.0, 0.0],
          [1.0, 0.0, 0.0],
        ],
        'triangle_indices': [
          [0, 1, 2],
          [3, 4, 5],
        ],
        'face_ids': [0, 1],
      };
      final backend = _FakeDocumentBackend();
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async {
          if (request.url.path == '/document/parts/part-1/mesh' && request.method == 'GET') {
            // 'computed' (not 'placeholder') - a single-entry `source:
            // "placeholder"` response is `PartScreen`'s own "no real Bodies
            // yet" signal (see `_refreshMesh`'s own `isPlaceholder` check),
            // which discards the entry entirely rather than treating it as
            // a real Body.
            return http.Response(
              jsonEncode([
                {'body_id': 'body-1', 'source': 'computed', 'mesh': mesh},
              ]),
              200,
            );
          }
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
      await _pumpUntil(
        tester,
        () => tester.widget<PartViewport>(find.byType(PartViewport)).bodies.isNotEmpty,
      );

      await tapStartCommand(tester, 'Section', tab: 'evaluate');
      await tester.tap(find.widgetWithText(FilledButton, 'Add Section'));
      await tester.pump();

      // Sanity check: the freshly-added section's own default plane is not
      // already coplanar with face 1 (normal +X through x=5) - otherwise a
      // no-op bug could masquerade as a pass.
      final before = tester.widget<PartViewport>(find.byType(PartViewport)).sectionPlanes.single;
      expect(before.normal.x, isNot(closeTo(1.0, 1e-6)));

      // The exact callback a real tap reaches via `PartViewport.
      // onSelectionToggle` regardless of `_selectionMode` - see this
      // group's own header comment for why that's the scenario worth
      // covering (not `PartViewport`'s own separate Orbit-mode `_handleTap`,
      // already covered by that widget's own hit-testing unit tests).
      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
            const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'body-1', id: 1),
          );
      await tester.pump();

      final after = tester.widget<PartViewport>(find.byType(PartViewport)).sectionPlanes.single;
      expect(after.normal.x, closeTo(1.0, 1e-6));
      expect(after.normal.y, closeTo(0.0, 1e-6));
      expect(after.normal.z, closeTo(0.0, 1e-6));
      expect(after.origin.x, closeTo(5.0, 1e-6));
    });
  });

  // Assembly support Phase 4 (`docs/assembly-scope.md` §3): a whole-
  // component viewport tap (`PartViewport.onSelectionToggle` with a
  // [SelectionEntityKind.component] entity) has entirely different
  // semantics from every other kind - it must never reach the generic
  // accumulate-into-[Set<SelectionEntityRef>] toggle every other kind
  // shares (see `_toggleSelectedEntity`'s own doc comment on this early-
  // return). The fake backend used throughout this file has no
  // `listOccurrences`/`listMates`/`getAssemblyMesh` route implemented (see
  // `docs/assembly-scope.md` §2e's own note on why a full lens-toggle round
  // trip through this harness is a disproportionate addition), so this
  // stays scoped to what's independently verifiable without one: that the
  // dispatch itself is correctly separated, exactly like the sibling
  // `onSelectionToggle`/`skippedPreviewBodyIds` tests above verify their
  // own kind's dispatch without needing a real Pattern feature behind
  // every case.
  group('Assembly support Phase 4: component selection toggle', () {
    // Bug fix ("selecting a component doesn't highlight it in 3D"): a
    // component entity now DOES land in `selectedEntities` - that's the only
    // thing `PartViewport._syncSelectedEntityNodes`'s own already-working
    // `component` case reads to actually highlight it. Renamed/inverted from
    // this test's old assertion, which encoded the bug being fixed here.
    testWidgets('a component entity lands in PartViewport.selectedEntities so it highlights', (tester) async {
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

      const entity = SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'occ-1');
      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(entity);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities, {entity});
    });

    testWidgets('an ordinary face entity still accumulates into selectedEntities as before', (tester) async {
      // Regression guard for the early-return itself: proves the component
      // branch's `return` doesn't somehow also swallow every other kind.
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

      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
            const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'body-1', id: 1),
          );
      await tester.pump();

      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities,
        {const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'body-1', id: 1)},
      );
    });

    // §6 roadmap Phase 10 (`[11]`), appendix item 8's own suggested smaller
    // fix: a derived `ComponentPattern` instance's synthetic occurrencePath
    // segment always contains "#pattern:" and never names a real Occurrence
    // - tapping one in the viewport must be rejected before it reaches
    // `_selectedOccurrenceId`, with a clear reason, rather than silently
    // "selecting" something a later "Pattern Component" attempt would only
    // fail against with a generic 422.
    testWidgets('a synthetic pattern-instance component tap is rejected with a clear message', (tester) async {
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

      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
            const SelectionEntityRef(
              kind: SelectionEntityKind.component,
              occurrenceId: 'occ-1#pattern:pat-1:2',
            ),
          );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('derived pattern instance'), findsOneWidget);
    });
  });

  // §6 roadmap Phase 10 (`[5]`): Hide/Show/Isolate wired to the real
  // `updateOccurrenceHidden` PATCH (Phase 8's own persistence path,
  // previously only exercised by `ai_plan_translator_test.dart`, never
  // through this screen's own long-press menu) - the one-time
  // `_FakeDocumentBackend` cost (`occurrences`/the four new routes above)
  // this phase pays so this harness can finally drive a real end-to-end
  // round trip, mirroring the gizmo's own already-real PATCH-then-refetch
  // coverage.
  group('Assembly support Phase 10: manual Hide/Show/Isolate persistence', () {
    Map<String, dynamic> occurrence(String id, {bool hidden = false, bool fixed = false}) => {
          'id': id,
          'external_ref': 'parts/$id.didsa',
          'resolved_part_id': '$id-part',
          'name_override': null,
          'transform': {
            'translation': [0.0, 0.0, 0.0],
            'rotation_axis': [0.0, 0.0, 1.0],
            'rotation_angle_degrees': 0.0,
          },
          'suppressed': false,
          'hidden': hidden,
          'fixed': fixed,
        };

    Future<_FakeDocumentBackend> openInAssemblyLens(
      WidgetTester tester, {
      required List<Map<String, dynamic>> seedOccurrences,
    }) async {
      final backend = _FakeDocumentBackend(seedOccurrences: seedOccurrences);
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => backend.handle(request)),
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

      await switchLens(tester, 'Assembly');
      return backend;
    }

    testWidgets(
      'initialLens: AssemblyLens.assembly opens directly into Assembly lens, no manual toggle needed',
      (tester) async {
        // Multi-part/assembly overhaul, Phase E (`docs/ai-modelling/13-
        // multi-part-assembly-overhaul.md`): AI Modelling's own
        // `_openAssembly` navigates straight into Assembly lens on a
        // freshly-mated assembly rather than making the user tap "Assembly
        // tree" by hand - unlike `openInAssemblyLens` above, this never taps
        // the toggle at all; the tree panel must already be showing once
        // `_loadPart` finishes.
        final backend = _FakeDocumentBackend(seedOccurrences: [occurrence('occ-1')]);
        final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              initialLens: AssemblyLens.assembly,
            ),
          ),
        );
        await _pumpUntil(tester, () => find.byType(AssemblyTreePanel).evaluate().isNotEmpty);

        expect(find.byType(AssemblyTreePanel), findsOneWidget);
        final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
        expect(panel.occurrences.single.id, 'occ-1');
      },
    );

    testWidgets('item 7: the tree fetches constraint-status with the occurrence list and passes it to the panel', (
      tester,
    ) async {
      final backend = _FakeDocumentBackend(seedOccurrences: [occurrence('occ-1')]);
      backend.constraintStatus['occ-1'] = {'status': 'under_constrained', 'dof': 3};
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
      await switchLens(tester, 'Assembly');

      expect(backend.constraintStatusRequests, greaterThan(0));
      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.constraintStatusByOccurrenceId['occ-1']?.state, ConstraintState.underConstrained);
      expect(panel.constraintStatusByOccurrenceId['occ-1']?.dof, 3);
    });

    testWidgets('item 4: multi-select shows the action bar in the tree header, with no bottom sheet over the tree', (
      tester,
    ) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1')]);

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final inPanel = find.descendant(of: find.byType(AssemblyTreePanel), matching: find.byType(MultiSelectActionBar));
      expect(inPanel, findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('Hide PATCHes hidden:true and the tree reflects it after refetch', (tester) async {
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1')]);

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.occurrences.single.hidden, isFalse);
      panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('Hide'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences.single['hidden'], isTrue);
      final refreshed = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(refreshed.occurrences.single.hidden, isTrue);
    });

    testWidgets('Show PATCHes hidden:false, truly clearing a backend-hidden Occurrence', (tester) async {
      // Appendix item 1's remaining manual-UI half: unlike the old
      // client-only overlay (which could only ever OR onto a backend-true
      // `hidden`, never clear it - `docs/assembly-scope.md` §5 item 1), this
      // seeds the Occurrence already hidden *from the backend* and confirms
      // Show genuinely un-hides it, not just this session's own view of it.
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1', hidden: true)]);

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.occurrences.single.hidden, isTrue);
      panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Show'), findsOneWidget);
      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences.single['hidden'], isFalse);
      final refreshed = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(refreshed.occurrences.single.hidden, isFalse);
    });

    testWidgets('Isolate hides every other top-level Occurrence and shows this one', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')],
      );

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
      panel.onOccurrenceLongPress(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('Isolate'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final byId = {for (final o in backend.occurrences) o['id'] as String: o['hidden'] as bool};
      expect(byId['occ-1'], isFalse);
      expect(byId['occ-2'], isTrue);
    });

    testWidgets('Isolate again on the already-isolated Occurrence shows every sibling', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1'), occurrence('occ-2', hidden: true)],
      );

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
      panel.onOccurrenceLongPress(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('Isolate'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final byId = {for (final o in backend.occurrences) o['id'] as String: o['hidden'] as bool};
      expect(byId['occ-1'], isFalse);
      expect(byId['occ-2'], isFalse);
    });

    // Bug report (assembly testing): "I can't find a method of applying a
    // fix on a part" - Fix/Float wired the same PATCH-then-refetch way
    // Hide/Show above already are, through `_setOccurrenceFixed`.
    testWidgets('Fix PATCHes fixed:true and the tree reflects it after refetch', (tester) async {
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1')]);

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.occurrences.single.fixed, isFalse);
      panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('Fix'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences.single['fixed'], isTrue);
      final refreshed = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(refreshed.occurrences.single.fixed, isTrue);
    });

    testWidgets('Float PATCHes fixed:false, and Move/Rotate re-enables', (tester) async {
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1', fixed: true)]);

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.occurrences.single.fixed, isTrue);
      panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Fixed, so Move/Rotate renders disabled - same guard
      // `component_context_menu_test.dart` already covers directly.
      final moveRotateTile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Move/Rotate'), matching: find.byType(ListTile)),
      );
      expect(moveRotateTile.enabled, isFalse);

      expect(find.text('Float'), findsOneWidget);
      await tester.tap(find.text('Float'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences.single['fixed'], isFalse);
      final refreshed = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(refreshed.occurrences.single.fixed, isFalse);

      refreshed.onOccurrenceLongPress(refreshed.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final reenabledTile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Move/Rotate'), matching: find.byType(ListTile)),
      );
      expect(reenabledTile.enabled, isTrue);
    });

    // Bug fix: "Move/Rotate" used to be a pure no-op case body (selecting
    // the Occurrence already made the gizmo target it) - but the gizmo's
    // own handle hit-test only ever wins priority over whichever *ordinary*
    // gesture dispatch is next in line; it doesn't change what that
    // fallback actually is. Selection mode's own dispatch has no orbit
    // gesture at all (a quick single-finger drag arms nothing, a two-finger
    // drag only ever pinch-pans), so a Selection-mode session left on from
    // any earlier picker-based tool (nothing in this file resets it back
    // off on its own) broke the camera orbit needed to even find a handle
    // to grab. "Move/Rotate" now forces Selection mode off, the same
    // "one-time default on open" contract `_openExtrudePanel` already uses
    // in the opposite direction.
    testWidgets('Move/Rotate forces Selection mode off so the camera can orbit to find a handle', (
      tester,
    ) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1')]);

      // `openInAssemblyLens` only ever switches lens (`_toggleAssemblyLens`
      // never touches `_featureTreeVisible`) - the selection-mode FAB is
      // already reachable, same as every other test in this group reaches
      // `AssemblyTreePanel.onOccurrenceLongPress` directly rather than via
      // an on-screen tap into the (slid-off-by-default) tree.
      await toggleSelectionMode(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectionMode, isTrue);

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('Move/Rotate'));
      await tester.pump();

      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectionMode, isFalse);
    });
  });

  // Constrained drag (plan S7): a gizmo drag of a MATED occurrence goes through `mate-motion` (grab anchor, live
  // group poses, ONE commit on release, one undo entry for every member); an unmated one keeps the raw PATCH.
  group('Constrained drag S7: gizmo drag of a mated occurrence', () {
    Map<String, dynamic> occ(String id, double x) => {
          'id': id,
          'external_ref': 'parts/$id.didsa',
          'resolved_part_id': '$id-part',
          'name_override': null,
          'transform': {
            'translation': [x, 0.0, 0.0],
            'rotation_axis': [0.0, 0.0, 1.0],
            'rotation_angle_degrees': 0.0,
          },
          'suppressed': false,
          'hidden': false,
          'fixed': false,
        };

    Map<String, dynamic> mateBetween(String a, String b) => {
          'id': 'mate-1',
          'type': 'coincident',
          'references': [
            {'occurrence_id': a},
            {'occurrence_id': b},
          ],
          'value': null,
          'flipped': false,
          'suppressed': false,
          'allow_rotation': true,
        };

    Map<String, dynamic> tf(double x, double y, double z) => {
          'translation': [x, y, z],
          'rotation_axis': [0.0, 0.0, 1.0],
          'rotation_angle_degrees': 0.0,
        };

    /// Flat-face group {occ-1 (grabbed), occ-2 (rides along in x)}; `commit` stores unless [failCommit].
    http.Response Function(Map<String, dynamic>, String) flatGroup(_FakeDocumentBackend b, {bool failCommit = false}) {
      return (body, grabbed) {
        final wish = (body['transform'] as Map<String, dynamic>?)?['translation'] as List? ??
            ((b.occurrences.firstWhere((o) => o['id'] == grabbed)['transform'] as Map)['translation'] as List);
        final o1 = b.occurrences.firstWhere((o) => o['id'] == 'occ-1');
        final o2 = b.occurrences.firstWhere((o) => o['id'] == 'occ-2');
        final x1 = (o1['transform']['translation'] as List)[0] as num;
        final x2 = (o2['transform']['translation'] as List)[0] as num;
        final nx = (wish[0] as num).toDouble(), ny = (wish[1] as num).toDouble();
        final commit = body['commit'] == true;
        if (commit && failCommit) {
          return http.Response(jsonEncode({'converged': false, 'members': [], 'quality': {'residual_inf': 5.0}}), 200);
        }
        final dx = nx - x1;
        final m1 = tf(nx, ny, 0), m2 = tf(x2 + dx, 0, 0);
        if (commit) {
          o1['transform'] = m1;
          o2['transform'] = m2;
        }
        final r = 1 / 1.4142135623730951;
        return http.Response(
          jsonEncode({
            'converged': true,
            'dof': 3,
            'grounded': true,
            'members': [
              {'occurrence_id': 'occ-1', 'transform': m1, 'mobility': 3},
              {'occurrence_id': 'occ-2', 'transform': m2, 'mobility': 1},
            ],
            'basis': [
              [r, 0, 0, 0, 0, 0, r, 0, 0, 0, 0, 0],
              [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            ],
            'chart': {'kind': 'se3_owner_frame', 'lever_arm': 10.0},
            'quality': {'residual_inf': 1e-12, 'sigma_gap': 1e4},
            'diagnostics': {'solve_ms': 1.0},
            'committed': commit,
          }),
          200,
        );
      };
    }

    Future<_FakeDocumentBackend> openWithGizmo(
      WidgetTester tester, {
      required List<Map<String, dynamic>> seedOccurrences,
      required List<Map<String, dynamic>> seedMates,
      required String target,
      http.Response Function(Map<String, dynamic>, String)? handler,
    }) async {
      final backend = _FakeDocumentBackend(seedOccurrences: seedOccurrences, seedMates: seedMates)
        ..mateMotionHandler = handler;
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
      await switchLens(tester, 'Assembly');
      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      panel.onOccurrenceLongPress(panel.occurrences.firstWhere((o) => o.id == target));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Move/Rotate'));
      await tester.pump();
      return backend;
    }

    RigidTransformDto wish(double x, double y, double z) =>
        RigidTransformDto(translation: [x, y, z], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('grab anchors, every member is drawn live, release sends ONE commit, ONE undo entry reverses all', (
      tester,
    ) async {
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
      );
      backend.mateMotionHandler = flatGroup(backend);
      var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewport.selectedOccurrenceTransform, isNotNull, reason: 'the gizmo is on');

      viewport.onComponentGizmoDragStart!();
      await settle(tester);
      expect(backend.mateMotionRequests.length, 1);
      expect(backend.mateMotionRequests.first['transform'], isNull, reason: 'grab anchor asks for the stored pose');
      expect(backend.mateMotionRequests.first['commit'], false);

      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragUpdate!(wish(4, 6, 9)); // 9 off-plane is blocked
      await tester.pump();
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      final live = {for (final i in viewport.assemblyInstances) i.occurrencePath.last: i.worldTransform};
      expect(live['occ-1']!.translation[0], closeTo(4, 1e-3));
      expect(live['occ-1']!.translation[1], closeTo(6, 1e-3));
      expect(live['occ-1']!.translation[2], closeTo(0, 1e-6), reason: 'off-plane motion blocked');
      expect(live['occ-2']!.translation[0], closeTo(34, 1e-3), reason: 'the follower is drawn moving too');
      expect(backend.transformPatchCount, 0, reason: 'no raw PATCH while dragging');

      viewport.onComponentGizmoDragEnd!();
      await settle(tester);
      expect(backend.transformPatchCount, 0, reason: 'release is the mate-motion commit, not the raw PATCH');
      final commits = backend.mateMotionRequests.where((r) => r['commit'] == true).toList();
      expect(commits.length, 1);
      expect((commits.single['transform'] as Map)['translation'], [4.0, 6.0, 9.0], reason: 'the release-time WISH');
      expect((backend.occurrences[0]['transform'] as Map)['translation'], [4.0, 6.0, 0.0]);
      expect((backend.occurrences[1]['transform'] as Map)['translation'], [34.0, 0.0, 0.0]);
      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.occurrences.firstWhere((o) => o.id == 'occ-2').transform.translation[0], closeTo(34, 1e-9));
      expect(find.byTooltip('Undo move'), findsOneWidget);

      // One undo reverses the grabbed occurrence AND the follower.
      await tester.tap(find.byTooltip('Undo move'));
      await settle(tester);
      expect((backend.occurrences[0]['transform'] as Map)['translation'], [0.0, 0.0, 0.0]);
      expect((backend.occurrences[1]['transform'] as Map)['translation'], [30.0, 0.0, 0.0]);
      expect(backend.transformPatchCount, 2);
      expect(find.byTooltip('Undo move'), findsNothing, reason: 'exactly one entry was pushed');
    });

    testWidgets('desktop input D3: Ctrl+Z undoes the move as the Undo button does; Esc deselects the component', (
      tester,
    ) async {
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
      );
      backend.mateMotionHandler = flatGroup(backend);
      var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragStart!();
      await settle(tester);
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragUpdate!(wish(4, 6, 0));
      await tester.pump();
      viewport.onComponentGizmoDragEnd!();
      await settle(tester);
      expect((backend.occurrences[0]['transform'] as Map)['translation'], [4.0, 6.0, 0.0]);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect((backend.occurrences[0]['transform'] as Map)['translation'], [0.0, 0.0, 0.0]);
      expect(find.byTooltip('Undo move'), findsNothing);

      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewport.selectedOccurrenceTransform, isNotNull, reason: 'occ-1 is still selected');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewport.selectedOccurrenceTransform, isNull, reason: 'Esc clears the selection');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a commit that does not converge stores nothing, restores every member and pushes no undo entry', (
      tester,
    ) async {
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
      );
      backend.mateMotionHandler = flatGroup(backend, failCommit: true);
      var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragStart!();
      await settle(tester);
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragUpdate!(wish(4, 6, 0));
      await tester.pump();
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragEnd!();
      await settle(tester);
      expect((backend.occurrences[0]['transform'] as Map)['translation'], [0.0, 0.0, 0.0]);
      expect((backend.occurrences[1]['transform'] as Map)['translation'], [30.0, 0.0, 0.0]);
      expect(find.byTooltip('Undo move'), findsNothing);
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      final shown = {for (final i in viewport.assemblyInstances) i.occurrencePath.last: i.worldTransform};
      expect(shown['occ-1']!.translation, [0.0, 0.0, 0.0], reason: 'back at the pre-grab pose');
      expect(shown['occ-2']!.translation, [30.0, 0.0, 0.0]);
      expect(find.textContaining("Couldn't keep that move"), findsOneWidget);
    });

    /// A scripted anchor for occ-1 (+ occ-2): `basis` rows are over 12 columns (occ-1 then occ-2).
    http.Response Function(Map<String, dynamic>, String) anchor({
      required int dof,
      required List<List<double>> basis,
      bool grounded = true,
      int mobility = 3,
    }) {
      return (body, grabbed) => http.Response(
            jsonEncode({
              'converged': true,
              'dof': dof,
              'grounded': grounded,
              'members': [
                {'occurrence_id': 'occ-1', 'transform': tf(0, 0, 0), 'mobility': mobility},
                {'occurrence_id': 'occ-2', 'transform': tf(30, 0, 0), 'mobility': 1},
              ],
              'basis': basis,
              'chart': {'kind': 'se3_owner_frame', 'lever_arm': 10.0},
              'quality': {'residual_inf': 1e-12, 'sigma_gap': 1e4},
              'diagnostics': {'solve_ms': 1.0},
              'committed': false,
            }),
            200,
          );
    }

    final slideXY = <List<double>>[
      [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ];

    testWidgets('S8: the gizmo shows what the mates allow - z locked, x/y free, plane handle, group DOF in the panels', (
      tester,
    ) async {
      await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
        handler: anchor(dof: 2, basis: slideXY),
      );
      await settle(tester);
      final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      final cues = viewport.componentGizmoCues!;
      expect(cues[ComponentGizmoHandleKind.translateX]!.free, isTrue);
      expect(cues[ComponentGizmoHandleKind.translateY]!.free, isTrue);
      expect(cues[ComponentGizmoHandleKind.translateZ]!.locked, isTrue);
      expect(cues[ComponentGizmoHandleKind.rotateX]!.locked, isTrue);
      expect(cues.planeNormal!.z.abs(), closeTo(1, 1e-6), reason: 'in-plane handle for the free x/y plane');
      expect(viewport.selectedOccurrenceTransform, isNotNull);
      expect(find.byKey(const ValueKey('move-rotate-status')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('move-rotate-status'))).data, 'Group: 2 DOF');
      expect(tester.widget<Text>(find.byKey(const ValueKey('assembly-motion-summary'))).data, 'Group: 2 DOF');
    });

    testWidgets('S8: 0 DOF hides the gizmo and says why; not grounded is stated', (tester) async {
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
        handler: anchor(dof: 0, basis: const [], mobility: 0),
      );
      await settle(tester);
      var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewport.selectedOccurrenceTransform, isNull, reason: 'no gizmo for a component nothing can move');
      expect(viewport.componentGizmoCues, isNull);
      expect(tester.widget<Text>(find.byKey(const ValueKey('move-rotate-status'))).data, contains('Fully constrained'));
      expect(backend.mateMotionRequests.length, 1, reason: 'one anchor for the selection, not one per rebuild');
    });

    testWidgets('S8: an ungrounded group says so', (tester) async {
      await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
        handler: anchor(dof: 6, grounded: false, basis: [
          for (var i = 0; i < 6; i++) [for (var j = 0; j < 12; j++) j == i ? 1.0 : 0.0],
        ]),
      );
      await settle(tester);
      expect(tester.widget<Text>(find.byKey(const ValueKey('assembly-motion-summary'))).data, 'Group: 6 DOF - not grounded');
      final cues = tester.widget<PartViewport>(find.byType(PartViewport)).componentGizmoCues!;
      expect(cues[ComponentGizmoHandleKind.translateZ]!.free, isTrue);
      expect(cues.planeNormal, isNull);
    });

    testWidgets('S8: an unmated target fetches nothing and shows no cues; a failed fetch leaves every handle as usual', (
      tester,
    ) async {
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30), occ('occ-3', 60)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-3',
        handler: anchor(dof: 0, basis: const [], mobility: 0),
      );
      await settle(tester);
      expect(backend.mateMotionRequests, isEmpty);
      var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewport.componentGizmoCues, isNull);
      expect(viewport.selectedOccurrenceTransform, isNotNull);
      expect(find.byKey(const ValueKey('move-rotate-status')), findsNothing);
    });

    testWidgets('S8: a converged:false anchor is never read as locked or free: no cues, gizmo unchanged', (tester) async {
      await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
        handler: (body, id) => http.Response(jsonEncode({'converged': false, 'members': [], 'quality': {'residual_inf': 5.0}}), 200),
      );
      await settle(tester);
      final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewport.componentGizmoCues, isNull);
      expect(viewport.selectedOccurrenceTransform, isNotNull);
    });

    testWidgets('deselecting a component (empty-space tap) closes its context drawer; Move/Rotate keeps its target', (tester) async {
      final backend = _FakeDocumentBackend(
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
      )..mateMotionHandler = anchor(dof: 2, basis: slideXY);
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
      await switchLens(tester, 'Assembly');

      // Plain selection (a tap on the tree row): the component's context drawer shows.
      var panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      panel.onOccurrenceTap(panel.occurrences.firstWhere((o) => o.id == 'occ-1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(AssemblyComponentSelectionDrawer), findsOneWidget);

      // An empty-space tap deselects it and the drawer goes away.
      tester.widget<PartViewport>(find.byType(PartViewport)).onClearSelection!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(AssemblyComponentSelectionDrawer), findsNothing);
      panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.selectedOccurrenceId, isNull);
    });

    testWidgets('fixing another member of the group refreshes the cues (found driving the real app)', (tester) async {
      var plateFixed = false;
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
        handler: (body, id) => anchor(
          dof: plateFixed ? 1 : 2,
          basis: plateFixed ? [slideXY.first] : slideXY,
        )(body, id),
      );
      await settle(tester);
      expect(backend.mateMotionRequests.length, 1);
      expect(tester.widget<Text>(find.byKey(const ValueKey('move-rotate-status'))).data, 'Group: 2 DOF');

      // The plate gets fixed (here: straight in the backend) and the tree refreshed. The Start button is hidden while the
      // Move/Rotate panel is open, so no lens round trip: a tree row's eye toggle refreshes the tree just the same.
      plateFixed = true;
      backend.occurrences[1]['fixed'] = true;
      final tree = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      tree.onOccurrenceVisibilityToggle!(tree.occurrences.firstWhere((o) => o.id == 'occ-2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await settle(tester);
      expect(backend.mateMotionRequests.length, 2, reason: 'a new anchor was fetched for the changed group');
      expect(tester.widget<Text>(find.byKey(const ValueKey('move-rotate-status'))).data, 'Group: 1 DOF');
    });

    testWidgets('an empty-space tap does not pull the target out from under an open Move/Rotate gizmo', (tester) async {
      await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-1',
        handler: anchor(dof: 2, basis: slideXY),
      );
      await settle(tester);
      tester.widget<PartViewport>(find.byType(PartViewport)).onClearSelection!();
      await tester.pump();
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectedOccurrenceTransform, isNotNull);
    });

    testWidgets('an unmated occurrence keeps the raw PATCH path: no mate-motion request at all', (tester) async {
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30), occ('occ-3', 60)],
        seedMates: [mateBetween('occ-1', 'occ-2')],
        target: 'occ-3',
      );
      backend.mateMotionHandler = flatGroup(backend);
      var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragStart!();
      viewport.onComponentGizmoDragUpdate!(wish(61, 2, 3));
      await tester.pump();
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragEnd!();
      await settle(tester);
      expect(backend.mateMotionRequests, isEmpty);
      expect(backend.transformPatchCount, 1);
      expect((backend.occurrences[2]['transform'] as Map)['translation'], [61.0, 2.0, 3.0]);
    });
  });

  // §6 roadmap Phase 10 (`[19]`): the Focus/Exit-Focus label's own latent
  // quirk (`docs/assembly-scope.md` §5 appendix item 4's "noticed but out of
  // scope" note) - `focusStack.current == resolvedPartId` could only ever be
  // true for a self-referencing Occurrence (forbidden by cycle detection),
  // so the menu could never actually show "Exit Focus" for a real nested
  // focus. `currentOccurrencePath.contains(occurrence.id)` fixes this.
  group('Assembly support Phase 10: Focus/Exit-Focus label', () {
    testWidgets('long-pressing the just-focused Occurrence again offers Exit Focus, not Make Focus', (
      tester,
    ) async {
      final occurrenceJson = {
        'id': 'occ-1',
        'external_ref': 'parts/bolt.didsa',
        'resolved_part_id': 'bolt-part',
        'name_override': null,
        'transform': {
          'translation': [0.0, 0.0, 0.0],
          'rotation_axis': [0.0, 0.0, 1.0],
          'rotation_angle_degrees': 0.0,
        },
        'suppressed': false,
        'hidden': false,
      };
      final backend = _FakeDocumentBackend(seedOccurrences: [occurrenceJson]);
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => backend.handle(request)),
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
      await switchLens(tester, 'Assembly');

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      final occurrence = panel.occurrences.single;

      // First long-press: unfocused, offers Make Focus - taking it pushes
      // the focus stack (this Occurrence's own `resolvedPartId` becomes the
      // new primary Part, and `AssemblyFocusStack.currentOccurrencePath`
      // records `occurrence.id`).
      panel.onOccurrenceLongPress(occurrence);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Make Focus'), findsOneWidget);
      await tester.tap(find.text('Make Focus'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Second long-press on the *same* Occurrence: the old
      // `focusStack.current == resolvedPartId` comparison could never be
      // true here (the Assembly tree only ever shows a Part's own
      // *children* - this Occurrence itself was never re-listed as a
      // child of the Part it now names), so the menu would incorrectly
      // still offer "Make Focus" again. The fixed `currentOccurrencePath`
      // check correctly recognizes this Occurrence as the one just focused.
      final refreshedPanel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      final sameOccurrence = refreshedPanel.occurrences.firstWhere(
        (o) => o.id == occurrence.id,
        orElse: () => occurrence,
      );
      refreshedPanel.onOccurrenceLongPress(sameOccurrence);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Exit Focus'), findsOneWidget);
      expect(find.text('Make Focus'), findsNothing);
    });
  });

  group('Assembly-audit gap [27]: occurrence delete + cascade + undo', () {
    Map<String, dynamic> occurrence(String id) => {
          'id': id,
          'external_ref': 'parts/$id.didsa',
          'resolved_part_id': '$id-part',
          'name_override': null,
          'transform': {
            'translation': [0.0, 0.0, 0.0],
            'rotation_axis': [0.0, 0.0, 1.0],
            'rotation_angle_degrees': 0.0,
          },
          'suppressed': false,
          'hidden': false,
          'fixed': false,
        };

    Future<_FakeDocumentBackend> openInAssemblyLens(
      WidgetTester tester, {
      required List<Map<String, dynamic>> seedOccurrences,
      List<Map<String, dynamic>>? seedMates,
      List<Map<String, dynamic>>? seedComponentPatterns,
    }) async {
      final backend = _FakeDocumentBackend(
        seedOccurrences: seedOccurrences,
        seedMates: seedMates,
        seedComponentPatterns: seedComponentPatterns,
      );
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => backend.handle(request)),
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

      await switchLens(tester, 'Assembly');
      return backend;
    }

    Map<String, dynamic> mateReferencing(String id, String occurrenceId) => {
          'id': id,
          'type': 'coincident',
          'references': [
            {
              'occurrence_id': occurrenceId,
              'subshape_ref': null,
              'plane_ref': {'face_ref': null, 'fixed_plane': 'XY', 'plane_feature_id': null},
              'point_ref': null,
            },
            {
              'occurrence_id': '',
              'subshape_ref': null,
              'plane_ref': {'face_ref': null, 'fixed_plane': 'XY', 'plane_feature_id': null},
              'point_ref': null,
            },
          ],
          'value': null,
          'flipped': false,
          'suppressed': false,
          'allow_rotation': true,
        };

    Map<String, dynamic> patternSourcedFrom(String id, List<String> sourceOccurrenceIds) => {
          'id': id,
          'source_occurrence_ids': sourceOccurrenceIds,
          'pattern_type': 'linear',
          'direction': [1.0, 0.0, 0.0],
          'count': 3,
          'spacing': 10.0,
          'reverse': false,
          'direction_2': [0.0, 1.0, 0.0],
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': <dynamic>[],
          'orient_with_rotation': true,
          'suppressed': false,
        };

    testWidgets('the warning dialog names every affected mate and pattern', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')],
        seedMates: [mateReferencing('mate-1', 'occ-1')],
        seedComponentPatterns: [patternSourcedFrom('pattern-1', ['occ-1'])],
      );

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
      panel.onOccurrenceLongPress(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('1 mate(s)'), findsOneWidget);
      expect(find.textContaining('1 pattern(s)'), findsOneWidget);
      // Cancelling leaves everything untouched.
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(backend.occurrences, hasLength(2));
      expect(backend.mates, hasLength(1));
      expect(backend.componentPatterns, hasLength(1));
    });

    testWidgets('confirming deletes the occurrence and cascades its mate and pattern', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')],
        seedMates: [mateReferencing('mate-1', 'occ-1'), mateReferencing('mate-2', 'occ-2')],
        seedComponentPatterns: [patternSourcedFrom('pattern-1', ['occ-1'])],
      );

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
      panel.onOccurrenceLongPress(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('Delete').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences.map((o) => o['id']), ['occ-2']);
      expect(backend.mates.map((m) => m['id']), ['mate-2']);
      expect(backend.componentPatterns, isEmpty);
    });

    testWidgets('Undo restores the deleted occurrence, mate, and pattern with a preserved id', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1')],
        seedMates: [mateReferencing('mate-1', 'occ-1')],
        seedComponentPatterns: [patternSourcedFrom('pattern-1', ['occ-1'])],
      );

      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Delete').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences, isEmpty);
      expect(backend.mates, isEmpty);
      expect(backend.componentPatterns, isEmpty);

      expect(find.byTooltip('Undo delete'), findsOneWidget);
      await tester.tap(find.byTooltip('Undo delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences.map((o) => o['id']), ['occ-1']);
      expect(backend.mates, hasLength(1));
      expect(
        (backend.mates.single['references'] as List)
            .map((r) => (r as Map<String, dynamic>)['occurrence_id']),
        contains('occ-1'),
      );
      expect(backend.componentPatterns, hasLength(1));
      expect(backend.componentPatterns.single['source_occurrence_ids'], ['occ-1']);
    });
  });

  // Assembly support Phase 20 (`docs/assembly-scope.md` §6 `[24]`): Part-lens
  // Feature-authoring/mesh-refresh now targets whichever Part is focused,
  // not always the root - `meshRequestsByPartId`/`featuresGetRequestsByPartId`
  // (this file's own additive fake-backend routes) are what make this
  // observable through this harness for the first time.
  group('Assembly support Phase 20: in-context Feature editing targets the focused Part', () {
    testWidgets('Make Focus immediately re-fetches the focused Part\'s own mesh/features, not the root\'s', (
      tester,
    ) async {
      final occurrenceJson = {
        'id': 'occ-1',
        'external_ref': 'parts/bracket.didsa',
        'resolved_part_id': 'part-2',
        'name_override': null,
        'transform': {
          'translation': [5.0, 0.0, 0.0],
          'rotation_axis': [0.0, 0.0, 1.0],
          'rotation_angle_degrees': 0.0,
        },
        'suppressed': false,
        'hidden': false,
      };
      final backend = _FakeDocumentBackend(seedOccurrences: [occurrenceJson]);
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => backend.handle(request)),
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

      // Baseline: only the root's own routes have been hit so far (the
      // initial `_loadPart` sequence) - nothing for `part-2` yet.
      expect(backend.meshRequestsByPartId['part-2'], isNull);
      expect(backend.featuresGetRequestsByPartId['part-2'], isNull);
      final rootMeshRequestsBeforeFocus = backend.meshRequests.length;
      final rootFeaturesGetCountBeforeFocus = backend.featuresGetCount;

      await switchLens(tester, 'Assembly');
      final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Make Focus'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // The real Phase 20 behavior: focusing a component re-fetches Part-lens
      // content for *that* Part right away, not only the Assembly tree - see
      // `_refreshFocusTargetContent`'s own doc comment for why this needed
      // fixing alongside the mechanical `focusPartId` swap itself (Make
      // Focus previously only ever called `_refreshAssemblyTree`).
      expect(backend.meshRequestsByPartId['part-2'], isNotNull);
      expect(backend.meshRequestsByPartId['part-2'], isNotEmpty);
      expect(backend.featuresGetRequestsByPartId['part-2'], greaterThanOrEqualTo(1));
      // And the root's own routes stop being re-hit meanwhile - every
      // further mesh/features fetch while focused targets `part-2` only.
      expect(backend.meshRequests.length, rootMeshRequestsBeforeFocus);
      expect(backend.featuresGetCount, rootFeaturesGetCountBeforeFocus);

      // Exit Focus: back to the root - its own routes are hit again.
      final refocusedPanel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      final sameOccurrence = refocusedPanel.occurrences.firstWhere(
        (o) => o.id == 'occ-1',
        orElse: () => panel.occurrences.single,
      );
      refocusedPanel.onOccurrenceLongPress(sameOccurrence);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Exit Focus'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.meshRequests.length, greaterThan(rootMeshRequestsBeforeFocus));
      expect(backend.featuresGetCount, greaterThan(rootFeaturesGetCountBeforeFocus));
    });

    // Colour-during-focus fix (`docs/assembly-scope.md`): before this fix,
    // `PartViewport.focusOccurrenceColorHex` didn't exist at all, so a
    // colored component's tint silently reverted to the global default for
    // the whole focus session. `_focusOccurrenceColorHex` reuses the exact
    // same `_gizmoParentInstance` lookup `_focusWorldTransformMatrix` above
    // already relies on, so this only needs to confirm the wiring, not a
    // second, independent lookup.
    testWidgets(
      "focusing a coloured component threads its colour into PartViewport, "
      'clearing on Exit Focus',
      (tester) async {
        final occurrenceJson = {
          'id': 'occ-1',
          'external_ref': 'parts/bracket.didsa',
          'resolved_part_id': 'part-2',
          'name_override': null,
          'transform': {
            'translation': [0.0, 0.0, 0.0],
            'rotation_axis': [0.0, 0.0, 1.0],
            'rotation_angle_degrees': 0.0,
          },
          'suppressed': false,
          'hidden': false,
          'color': '#AABBCC',
        };
        final backend = _FakeDocumentBackend(seedOccurrences: [occurrenceJson]);
        final documentApi = DocumentApiClient(
          httpClient: MockClient((request) async => backend.handle(request)),
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

        expect(tester.widget<PartViewport>(find.byType(PartViewport)).focusOccurrenceColorHex, isNull);

        await switchLens(tester, 'Assembly');
        final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
        panel.onOccurrenceLongPress(panel.occurrences.single);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        // Feature 1 (tree multi-select): long-press now enters multi-select;
        // the row's own context menu is behind the action bar's "More".
        await tester.tap(find.byTooltip('More actions'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('Make Focus'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(tester.widget<PartViewport>(find.byType(PartViewport)).focusOccurrenceColorHex, '#AABBCC');

        final refocusedPanel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
        final sameOccurrence = refocusedPanel.occurrences.firstWhere(
          (o) => o.id == 'occ-1',
          orElse: () => panel.occurrences.single,
        );
        refocusedPanel.onOccurrenceLongPress(sameOccurrence);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        // Feature 1 (tree multi-select): long-press now enters multi-select;
        // the row's own context menu is behind the action bar's "More".
        await tester.tap(find.byTooltip('More actions'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('Exit Focus'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(tester.widget<PartViewport>(find.byType(PartViewport)).focusOccurrenceColorHex, isNull);
      },
    );
  });

  // §6 roadmap Phase 15 (`docs/assembly-scope.md`): the multi-file save
  // flow - "Create Component…" (top-down, a brand-new empty Part) and
  // "Save All" (writes every Part currently loaded back to its own file,
  // correctly stamping `external_ref` first). Both need a real
  // `StorageService`/`AssemblyDocumentClient`, previously untestable
  // through this harness - `_FakeStorageService` plus this fake backend's
  // own new `export/native`/`import/native`/`POST .../parts` (unique id)
  // routes are the one-time cost that makes that possible, the same
  // precedent Phase 10 already set for `occurrences`/`mates`/
  // `component-patterns`/`assembly-mesh`.
  group('Assembly support Phase 15: multi-file save flow', () {
    testWidgets(
      'Create Component creates an auto-named, auto-pathed Part as a fixed top-level Occurrence '
      '(save/project overhaul Phase 1 - no dialog at all)',
      (tester) async {
        final backend = _FakeDocumentBackend();
        final storage = _FakeStorageService();
        final documentApi = DocumentApiClient(
          httpClient: MockClient((request) async => backend.handle(request)),
        );
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () =>
                  SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              storageService: storage,
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        await switchLens(tester, 'Assembly');

        await tapStartCommand(tester, 'Create Component');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // docs/save-project-overhaul-scope.md §3.1: no "name it" dialog and
        // no "save it" prompt any more - the component is created, named
        // ("Component 1", `_nextComponentName`'s auto-generated default),
        // and pathed immediately.
        expect(find.text('Create Component'), findsNothing);
        expect(find.text('Skip - save later'), findsNothing);

        expect(backend.extraParts, hasLength(1));
        final newPartId = backend.extraParts.keys.single;
        expect(backend.extraParts[newPartId]!['name'], 'Component 1');

        expect(backend.occurrences, hasLength(1));
        expect(backend.occurrences.single['resolved_part_id'], newPartId);
        expect(backend.occurrences.single['name_override'], 'Component 1');
        // First-ever Occurrence on this Part is auto-`fixed` (`add_component.dart`'s
        // own "first component is grounded by convention" rule).
        expect(backend.occurrences.single['fixed'], isTrue);

        final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
        expect(panel.occurrences, hasLength(1));

        // Both the new component and its parent ("Part 1") were silently
        // given a path in the same step - Save All needs no further prompt
        // for either (the gap `docs/save-project-pipeline-findings.md` §3
        // originally flagged: only the child ever used to get one).
        await openToolbar(tester);
        await tester.tap(find.text('File'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.ensureVisible(find.text('Save All'));
        await tester.pump();
        await tester.tap(find.text('Save All'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Saved 2 file(s)'), findsOneWidget);
        expect(storage.files.keys, containsAll(['Part 1.didsa', 'Component 1.didsa']));
      },
    );

    testWidgets(
      'an auto-assigned path treats a legacy X.DIDSAprt in the folder as the same name (item 9)',
      (tester) async {
        final backend = _FakeDocumentBackend();
        final storage = _FakeStorageService()
          ..files['Component 1.DIDSAprt'] = Uint8List.fromList(utf8.encode('{}'));
        final documentApi = DocumentApiClient(
          httpClient: MockClient((request) async => backend.handle(request)),
        );
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () =>
                  SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              storageService: storage,
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        await switchLens(tester, 'Assembly');
        await tapStartCommand(tester, 'Create Component');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        await openToolbar(tester);
        await tester.tap(find.text('File'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.ensureVisible(find.text('Save All'));
        await tester.pump();
        await tester.tap(find.text('Save All'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // `Component 1.didsa` would look like a duplicate of the legacy file
        // in the Open list, so the next free name is used instead.
        expect(storage.files.keys, containsAll(['Component 1 (2).didsa', 'Part 1.didsa']));
        expect(storage.files.keys, isNot(contains('Component 1.didsa')));
      },
    );

    testWidgets(
      'Save All prompts for each un-pathed Part, stamps external_ref, and writes every file',
      (tester) async {
        final backend = _FakeDocumentBackend(
          seedOccurrences: [
            {
              'id': 'occ-1',
              'external_ref': 'stale.DIDSAprt',
              'resolved_part_id': 'part-2',
              'name_override': null,
              'transform': null,
              'suppressed': false,
              'hidden': false,
            },
          ],
        )..extraParts['part-2'] = {'id': 'part-2', 'name': 'Bracket', 'occurrences': <Map<String, dynamic>>[]};
        final storage = _FakeStorageService();
        final documentApi = DocumentApiClient(
          httpClient: MockClient((request) async => backend.handle(request)),
        );
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () =>
                  SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              storageService: storage,
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        await openToolbar(tester);

        await tester.tap(find.text('File'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        await tester.ensureVisible(find.text('Save All'));
        await tester.pump();
        await tester.tap(find.text('Save All'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // First prompt: `part-1` itself (this session's own root Part) -
        // has no known path yet either.
        expect(find.text('Save "Part 1" as…'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), 'top.DIDSAprt');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Second prompt: `part-2` (the Occurrence's own target Part).
        expect(find.text('Save "Bracket" as…'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), 'bracket.DIDSAprt');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Saved 2 file(s)'), findsOneWidget);
        expect(storage.files.keys, containsAll(['top.DIDSAprt', 'bracket.DIDSAprt']));

        // The critical correctness step (`stampExternalRefs`): the written
        // `top.DIDSAprt` now names `bracket.DIDSAprt` as the Occurrence's
        // own `external_ref`, not the stale value the session started with -
        // without this, the saved files couldn't resolve as a real
        // assembly on a later "Open Project…".
        final writtenTop = jsonDecode(utf8.decode(storage.files['top.DIDSAprt']!)) as Map<String, dynamic>;
        final writtenPartOne = (writtenTop['document']['parts'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((p) => p['id'] == 'part-1');
        final writtenOccurrence = (writtenPartOne['occurrences'] as List).single as Map<String, dynamic>;
        expect(writtenOccurrence['external_ref'], 'bracket.DIDSAprt');
      },
    );
  });

  // §6 roadmap Phase 16 (`docs/assembly-scope.md` §2s): the spike this
  // phase's own roadmap entry called for confirmed gap `[22]` isn't a real
  // defect - `assembly_document_client_test.dart`'s own new "Phase 16"
  // group pins the actual round-trip property (`openAssembly` called twice
  // in one session never leaks state) directly at the composer/client
  // level, real `AssemblyGraphComposer`/temp-dir `FileCache` and all. A
  // third, widget-level "Open Project… through the real screen" test was
  // attempted here too, but real `dart:io` file I/O combined with
  // `testWidgets`' own fake-async pump loop proved reliably too slow/flaky
  // in this sandbox (consistently hit the 10-minute per-test timeout even
  // after removing every other moving part) - dropped rather than kept
  // flaky, since the property it would have added on top of the
  // composer-level tests is already covered there. These two tests instead
  // cover what the spike found *along the way*: `[25]` (Open Project…
  // never guarded against discarding unsaved changes) and `[26]`
  // (`lastUsedProjectRoot` never actually wired into `_ensureProjectRoot`) -
  // both fast, reliable, and driven through the real screen.
  group('Assembly support Phase 16: Open Project hardening', () {
    testWidgets('Open Project… asks to confirm before navigating away, per [25]', (tester) async {
      final backend = _FakeDocumentBackend();
      final storage = _FakeStorageService();
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => backend.handle(request)),
      );
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
            // Save/project overhaul Phase 6 (`docs/save-project-overhaul-scope.md`
            // §5): "Open…"/"Open Project…" are now one unified entry that
            // branches on platform - forced away from the real, unmockable
            // `FilePicker.platform` desktop path so this test (running on
            // this repo's Linux-hosted harness, which would otherwise always
            // take that branch) can still exercise the `StorageService`-driven
            // one, exactly as it always could back when "Open Project…" was
            // its own always-reachable menu entry with no platform gate.
            canPersistFilePathForReuse: false,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      // Save/project overhaul Phase 4 (`docs/save-project-overhaul-scope.md`
      // §3.4): a freshly-loaded, untouched Part is no longer considered
      // dirty (see the sibling "no confirmation" test below), so this test
      // makes a real change first - creating a component, same zero-dialog
      // flow Phase 1's own tests exercise - to genuinely put something at
      // risk of being lost.
      await switchLens(tester, 'Assembly');
      await tapStartCommand(tester, 'Create Component');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Open…'));
      await tester.pump();
      await tester.tap(find.text('Open…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Exit this project?'), findsOneWidget);
      // Create Component (used above to dirty the session) already
      // resolved a `ProjectRoot` once of its own accord (auto-path
      // assignment, §3.1) - the call count captured here is that one, not
      // Open Project's own.
      final callCountBeforeCancel = storage.pickOrCreateProjectRootCallCount;
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Cancelling never reached `_ensureProjectRoot` a second time for
      // Open Project's own sake - the folder picker was never shown again,
      // and the "Part 1" screen is still here (now showing its own root
      // Part's row alongside the just-created component - findsWidgets,
      // not findsOneWidget, since Create Component's own assembly tree is
      // still open, unlike the original pre-Phase-4 version of this test).
      expect(storage.pickOrCreateProjectRootCallCount, callCountBeforeCancel);
      expect(find.text('Open Project'), findsNothing);
      expect(find.text('Part 1'), findsWidgets);
    });

    testWidgets(
      'Open Project… skips the confirmation entirely when nothing has changed since load '
      '(save/project overhaul Phase 4)',
      (tester) async {
        final backend = _FakeDocumentBackend();
        final storage = _FakeStorageService();
        final documentApi = DocumentApiClient(
          httpClient: MockClient((request) async => backend.handle(request)),
        );
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () =>
                  SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              storageService: storage,
              // See the sibling "asks to confirm" test's own comment for why.
              canPersistFilePathForReuse: false,
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        await openToolbar(tester);
        await tester.tap(find.text('File'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.ensureVisible(find.text('Open…'));
        await tester.pump();
        await tester.tap(find.text('Open…'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // No warning - straight to the folder picker / relative-path
        // prompt, since nothing changed since this Part was loaded.
        expect(find.text('Exit this project?'), findsNothing);
        expect(storage.pickOrCreateProjectRootCallCount, 1);
      },
    );

    testWidgets('Save All skips the folder picker when a valid last-used root is known, per [26]', (
      tester,
    ) async {
      final backend = _FakeDocumentBackend();
      final storage = _FakeStorageService()..presetLastUsedRoot = const DesktopProjectRoot('/fake/project');
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async => backend.handle(request)),
      );
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Save All'));
      await tester.pump();
      await tester.tap(find.text('Save All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Save "Part 1" as…'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'top.DIDSAprt');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Saved 1 file(s)'), findsOneWidget);
      // The preset last-used root was used directly - the native picker
      // (`pickOrCreateProjectRoot`) was never invoked.
      expect(storage.pickOrCreateProjectRootCallCount, 0);
    });
  });

  // Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
  // §3.2): the assembly tree's own Rename action - keeps the Occurrence's
  // display name, its underlying Part's own name, and its on-disk file (if
  // it has one) in sync, except when that Part is instanced more than once
  // in the session, where only the display name changes.
  group('Save/project overhaul Phase 2: Rename', () {
    Map<String, dynamic> occurrence(String id, {String? nameOverride}) => {
          'id': id,
          'external_ref': null,
          'resolved_part_id': 'part-2',
          'name_override': nameOverride,
          'transform': {
            'translation': [0.0, 0.0, 0.0],
            'rotation_axis': [0.0, 0.0, 1.0],
            'rotation_angle_degrees': 0.0,
          },
          'suppressed': false,
          'hidden': false,
          'fixed': false,
        };

    testWidgets(
      'Renaming a singly-instanced component renames its label, its Part, and its file',
      (tester) async {
        final backend = _FakeDocumentBackend(seedOccurrences: [occurrence('occ-1')])
          ..extraParts['part-2'] = {'id': 'part-2', 'name': 'Bracket', 'occurrences': <Map<String, dynamic>>[]};
        final storage = _FakeStorageService();
        final documentApi = DocumentApiClient(
          httpClient: MockClient((request) async => backend.handle(request)),
        );
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () =>
                  SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              storageService: storage,
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        // Save All first, so `part-2` already has a known on-disk file for
        // Rename to also rename.
        await openToolbar(tester);
        await tester.tap(find.text('File'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.ensureVisible(find.text('Save All'));
        await tester.pump();
        await tester.tap(find.text('Save All'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Save "Part 1" as…'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), 'top.DIDSAprt');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Save "Bracket" as…'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), 'bracket.DIDSAprt');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Saved 2 file(s)'), findsOneWidget);
        expect(storage.files.keys, contains('bracket.DIDSAprt'));

        await switchLens(tester, 'Assembly');

        final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
        panel.onOccurrenceLongPress(panel.occurrences.single);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.byTooltip('More actions'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        await tester.tap(find.text('Rename'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // No "used more than once" note for a singly-instanced component.
        expect(find.textContaining('used more than once'), findsNothing);

        await tester.enterText(find.byType(TextFormField), 'Left Bracket');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(backend.occurrences.single['name_override'], 'Left Bracket');
        expect(backend.extraParts['part-2']!['name'], 'Left Bracket');
        // Item 9: rename keeps the file's own (here legacy, typed) extension.
        expect(storage.files.keys, contains('Left Bracket.DIDSAprt'));
        expect(storage.files.keys, isNot(contains('bracket.DIDSAprt')));
      },
    );

    testWidgets(
      'Renaming a component instanced more than once only changes its own label',
      (tester) async {
        final backend = _FakeDocumentBackend(
          seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')],
        )..extraParts['part-2'] = {'id': 'part-2', 'name': 'Bracket', 'occurrences': <Map<String, dynamic>>[]};
        final storage = _FakeStorageService();
        final documentApi = DocumentApiClient(
          httpClient: MockClient((request) async => backend.handle(request)),
        );
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () =>
                  SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              storageService: storage,
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        await switchLens(tester, 'Assembly');

        final panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
        final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
        panel.onOccurrenceLongPress(target);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.byTooltip('More actions'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        await tester.tap(find.text('Rename'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Two Occurrences resolve to `part-2` - Renaming this one must say
        // so, and must never touch the shared Part name/file.
        expect(find.textContaining('used more than once'), findsOneWidget);

        await tester.enterText(find.byType(TextFormField), 'Left Bracket');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        final renamed = backend.occurrences.firstWhere((o) => o['id'] == 'occ-1');
        final untouched = backend.occurrences.firstWhere((o) => o['id'] == 'occ-2');
        expect(renamed['name_override'], 'Left Bracket');
        expect(untouched['name_override'], isNull);
        expect(backend.extraParts['part-2']!['name'], 'Bracket');
      },
    );
  });

  // Save/project overhaul Phase 3 (`docs/save-project-overhaul-scope.md`
  // §3.3): once a Project exists, plain Save only writes back the
  // currently-focused Part's own file (never every loaded Part - that's
  // Save All's job), and Save As saves the focused Part's current content
  // under a newly-chosen path and rebinds future Saves to it.
  group('Save/project overhaul Phase 3: Save/Save As', () {
    testWidgets('plain Save writes only the focused Part, not every loaded Part', (tester) async {
      final backend = _FakeDocumentBackend(
        seedOccurrences: [
          {
            'id': 'occ-1',
            'external_ref': null,
            'resolved_part_id': 'part-2',
            'name_override': null,
            'transform': {
              'translation': [0.0, 0.0, 0.0],
              'rotation_axis': [0.0, 0.0, 1.0],
              'rotation_angle_degrees': 0.0,
            },
            'suppressed': false,
            'hidden': false,
            'fixed': false,
          },
        ],
      )..extraParts['part-2'] = {'id': 'part-2', 'name': 'Bracket', 'occurrences': <Map<String, dynamic>>[]};
      final storage = _FakeStorageService();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      // Save All first, to establish the Project and give both Parts a
      // known path.
      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Save All'));
      await tester.pump();
      await tester.tap(find.text('Save All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Save "Part 1" as…'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'top.DIDSAprt');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Save "Bracket" as…'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'bracket.DIDSAprt');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Saved 2 file(s)'), findsOneWidget);
      expect(storage.writeCounts['top.DIDSAprt'], 1);
      expect(storage.writeCounts['bracket.DIDSAprt'], 1);
      // Let the first SnackBar fully dismiss (its default ~4s display
      // duration) before triggering a second one below - `ScaffoldMessenger`
      // queues a new SnackBar behind one still showing rather than
      // replacing it, so the next "Saved" check would otherwise see the
      // first SnackBar's own text, or find the second one still queued.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      // Plain Save, still focused on the root Part ("Part 1") - only its
      // own file should be rewritten. Invoked directly via `PartToolbar`'s
      // own callback (same "grab the widget, call its callback" approach
      // `AssemblyTreePanel.onOccurrenceLongPress` calls already use above),
      // rather than re-navigating the sliding toolbar panel's own File
      // sub-menu a second time in one test - `PartToolbar` itself always
      // exists in the tree regardless of `visible`, so this is exactly
      // what tapping "Save" would do without needing to fight the
      // panel's open/close animation for a second round.
      tester.widget<PartToolbar>(find.byType(PartToolbar)).onSaveNative!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // No per-Part prompt - both Parts already had a known path.
      expect(find.text('Save "Part 1" as…'), findsNothing);
      expect(find.text('Saved'), findsOneWidget);
      expect(storage.writeCounts['top.DIDSAprt'], 2);
      expect(storage.writeCounts['bracket.DIDSAprt'], 1);
    });

    testWidgets('Save As saves the focused Part under a new path and rebinds future Saves to it', (
      tester,
    ) async {
      final backend = _FakeDocumentBackend();
      final storage = _FakeStorageService();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
            assemblyDocumentClient: AssemblyDocumentClient(
              storageService: storage,
              documentApiClient: documentApi,
              composer: AssemblyGraphComposer(storageService: storage, fileCache: _NoopFileCache()),
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      // Save All first, to establish the Project and a known path.
      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Save All'));
      await tester.pump();
      await tester.tap(find.text('Save All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Save "Part 1" as…'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'top.DIDSAprt');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Saved 1 file(s)'), findsOneWidget);
      // Let the first SnackBar fully dismiss before triggering a second one
      // below - see the sibling "plain Save" test's own comment for why.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      // Save As - a new path for the same Part. Invoked directly via
      // `PartToolbar`'s own callback (see the sibling "plain Save" test's
      // own comment for why) rather than re-navigating the sliding
      // toolbar panel's File sub-menu a second time in one test.
      final toolbar = tester.widget<PartToolbar>(find.byType(PartToolbar));
      toolbar.onSaveAsNative!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Save "Part 1" as…'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'renamed-top.DIDSAprt');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.widgetWithText(FilledButton, 'Save As'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(storage.files.keys, contains('renamed-top.DIDSAprt'));
      // The old file is left in place (no delete primitive exists) rather
      // than silently discarded.
      expect(storage.files.keys, contains('top.DIDSAprt'));

      // Bug report 2026-10-14, item 3: the copy was written under a fresh
      // identity, so it can never collide with the original in an assembly.
      Map<String, dynamic> read(String path) => jsonDecode(utf8.decode(storage.files[path]!)) as Map<String, dynamic>;
      String partIdIn(Map<String, dynamic> payload) =>
          (((payload['document'] as Map)['parts'] as List).first as Map)['id'] as String;
      final originalId = partIdIn(read('top.DIDSAprt'));
      final copyId = partIdIn(read('renamed-top.DIDSAprt'));
      expect(copyId, isNot(originalId));
      expect((read('renamed-top.DIDSAprt')['document'] as Map)['root_part_id'], copyId);

      // Root Part: the session *became* the new file (it was reopened), so
      // a later plain Save targets the new path, not the old one.
      // The reopened screen replaces this one (page transition, then its own
      // load) - wait for exactly one screen to be left before driving it.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await _pumpUntil(tester, () => find.byType(PartToolbar).evaluate().length == 1);
      // Item 1: the title follows the new file.
      expect(find.text('renamed-top'), findsOneWidget);
      tester.widget<PartToolbar>(find.byType(PartToolbar)).onSaveNative!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(storage.writeCounts['renamed-top.DIDSAprt'], 2);
      expect(storage.writeCounts['top.DIDSAprt'], 1);
    });

    testWidgets('Save As to the path the Part already lives at is a plain Save: no re-mint, no reopen', (tester) async {
      final backend = _FakeDocumentBackend();
      final storage = _FakeStorageService();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Save All'));
      await tester.pump();
      await tester.tap(find.text('Save All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(find.byType(TextFormField), 'top.DIDSAprt');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      final originalBytes = utf8.decode(storage.files['top.DIDSAprt']!);

      tester.widget<PartToolbar>(find.byType(PartToolbar)).onSaveAsNative!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(find.byType(TextFormField), 'top.DIDSAprt');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.widgetWithText(FilledButton, 'Save As'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Saved'), findsOneWidget);
      expect(storage.files.keys, hasLength(1));
      expect(storage.writeCounts['top.DIDSAprt'], 2);
      // Same ids as before: nothing was re-minted over the original.
      final partIds = RegExp(r'"id":"([^"]+)"');
      expect(
        partIds.firstMatch(utf8.decode(storage.files['top.DIDSAprt']!))!.group(1),
        partIds.firstMatch(originalBytes)!.group(1),
      );
    });
  });

  // Bug report 2026-10-14, item 2: on Android a Save with no known file fell
  // back to `FilePicker.saveFile` (ACTION_CREATE_DOCUMENT, which can never
  // overwrite), so every Save was a Save As and `Frame_A (1)`, `(2)` piled up.
  // Now every native Save on mobile goes through the persisted folder grant.
  // `canPersistFilePathForReuse: false` selects the mobile branch.
  group('item 2: first Save goes through the project folder', () {
    Future<PartToolbar Function()> pumpFresh(
      WidgetTester tester,
      _FakeStorageService storage, {
      _FakeDocumentBackend? backend,
    }) async {
      final fake = backend ?? _FakeDocumentBackend();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => fake.handle(request)));
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
            canPersistFilePathForReuse: false,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      return () => tester.widget<PartToolbar>(find.byType(PartToolbar));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    Future<void> answerNamePrompt(WidgetTester tester, String name, {String button = 'Save'}) async {
      expect(find.text('Save "Part 1" as…'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), name);
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, button));
      await settle(tester);
    }

    testWidgets('no remembered folder: picks the folder once, asks the name once, writes once; re-Save is silent', (
      tester,
    ) async {
      final storage = _FakeStorageService();
      final toolbar = await pumpFresh(tester, storage);

      toolbar().onSaveNative!();
      await settle(tester);
      // The prompt shows which folder it will write into.
      expect(find.textContaining('Folder: '), findsOneWidget);
      await answerNamePrompt(tester, 'Frame 1.5m');

      expect(storage.pickOrCreateProjectRootCallCount, 1);
      // A dotted name still gets the native extension (item 9).
      expect(storage.files.keys, ['Frame 1.5m.didsa']);
      expect(storage.writeCounts['Frame 1.5m.didsa'], 1);
      expect(find.text('Saved to Frame 1.5m.didsa'), findsOneWidget);
      // The title follows the new file (item 1).
      expect(find.text('Frame 1.5m'), findsOneWidget);

      // Second Save: no picker, no prompt, the same file overwritten.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      toolbar().onSaveNative!();
      await settle(tester);
      expect(find.text('Save "Part 1" as…'), findsNothing);
      expect(storage.pickOrCreateProjectRootCallCount, 1);
      expect(storage.writeCounts['Frame 1.5m.didsa'], 2);
      expect(storage.files, hasLength(1));
    });

    testWidgets('a remembered folder skips the picker and only asks for the name', (tester) async {
      final storage = _FakeStorageService();
      storage.presetLastUsedRoot = storage.root;
      final toolbar = await pumpFresh(tester, storage);

      toolbar().onSaveNative!();
      await settle(tester);
      await answerNamePrompt(tester, 'bracket');

      expect(storage.pickOrCreateProjectRootCallCount, 0);
      expect(storage.files.keys, ['bracket.didsa']);
    });

    testWidgets('cancelling the folder picker writes nothing and changes nothing', (tester) async {
      final storage = _FakeStorageService()..pickerCancels = true;
      final toolbar = await pumpFresh(tester, storage);

      toolbar().onSaveNative!();
      await settle(tester);

      expect(find.text('Save "Part 1" as…'), findsNothing);
      expect(storage.files, isEmpty);
    });

    testWidgets('cancelling the name prompt writes nothing and does not keep the folder as the root', (tester) async {
      final storage = _FakeStorageService();
      final toolbar = await pumpFresh(tester, storage);

      toolbar().onSaveNative!();
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      expect(storage.files, isEmpty);

      // The next Save asks again (a stale root would auto-name it silently).
      toolbar().onSaveNative!();
      await settle(tester);
      expect(find.text('Save "Part 1" as…'), findsOneWidget);
    });

    testWidgets('the written file carries the root Part\'s client-only extras', (tester) async {
      final storage = _FakeStorageService();
      final toolbar = await pumpFresh(tester, storage);

      toolbar().onSaveNative!();
      await settle(tester);
      await answerNamePrompt(tester, 'extras');

      final written = jsonDecode(utf8.decode(storage.files['extras.didsa']!)) as Map<String, dynamic>;
      expect(written, containsPair('hidden_feature_ids', isA<List>()));
      expect(written, containsPair('section_planes', isA<List>()));
    });

    testWidgets('a failed overwrite shows the error, keeps the Part dirty and falls back to Save As', (tester) async {
      final storage = _FakeStorageService();
      final toolbar = await pumpFresh(tester, storage);

      toolbar().onSaveNative!();
      await settle(tester);
      await answerNamePrompt(tester, 'Frame');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      storage.failOnWrite.add('Frame.didsa');
      toolbar().onSaveNative!();
      await settle(tester);

      expect(find.textContaining("Couldn't write Frame.didsa"), findsOneWidget);
      // The Save As flow is offered, with the folder re-validated.
      expect(find.text('Save "Part 1" as…'), findsOneWidget);
      expect(toolbar().hasUnsavedChanges, isTrue);
    });
  });

  // Bug report 2026-10-14, item 1: Open on a single-Part (project-shaped) file
  // never seeded `initialFileName`, so the title fell back to the backend Part
  // name, always "Part 1".
  group('title follows the root Part\'s file (item 1)', () {
    Future<void> pumpOpened(
      WidgetTester tester,
      _FakeDocumentBackend backend,
      String rootPath,
    ) async {
      final storage = _FakeStorageService();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
            initialPartId: 'part-1',
            initialProjectRoot: storage.root,
            initialRelativePathByPartId: {'part-1': rootPath},
          ),
        ),
      );
    }

    String appBarTitle(WidgetTester tester) =>
        tester.widget<Text>(find.descendant(of: find.byType(AppBar), matching: find.byType(Text)).last).data!;

    testWidgets('a legacy .DIDSAprt file shows its base name, not "Part 1"', (tester) async {
      final backend = _FakeDocumentBackend();
      await pumpOpened(tester, backend, 'sub/Frame_A.DIDSAprt');
      await _pumpUntil(tester, () => find.text('Frame_A').evaluate().isNotEmpty);
      expect(appBarTitle(tester), 'Frame_A');
    });

    testWidgets('a current .didsa file shows its base name too', (tester) async {
      final backend = _FakeDocumentBackend();
      await pumpOpened(tester, backend, 'sub/Frame_C.didsa');
      await _pumpUntil(tester, () => find.text('Frame_C').evaluate().isNotEmpty);
      expect(appBarTitle(tester), 'Frame_C');
    });
  });

  // Follow-up to the Linux build test report: Save writes every Part that
  // needs it, the tree marks them, and a failure says which file and why.
  group('assembly-aware Save', () {
    Future<PartToolbar Function()> pumpWithComponent(WidgetTester tester, _FakeStorageService storage) async {
      final backend = _FakeDocumentBackend();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      await switchLens(tester, 'Assembly');
      await tapStartCommand(tester, 'Create Component');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      return () => tester.widget<PartToolbar>(find.byType(PartToolbar));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    testWidgets('Create Component asks for the folder first: cancelling creates nothing', (tester) async {
      final storage = _FakeStorageService()..pickerCancels = true;
      await pumpWithComponent(tester, storage);

      expect(find.byType(AssemblyTreePanel), findsOneWidget);
      expect(tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel)).occurrences, isEmpty);
    });

    testWidgets('plain Save writes the new component and its parent, and the tree marks both until then', (
      tester,
    ) async {
      final storage = _FakeStorageService();
      final toolbar = await pumpWithComponent(tester, storage);

      var panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.neverSavedPartIds, hasLength(1));
      expect(panel.parentUnsaved, isTrue);
      expect(find.byKey(const Key('unsaved-dot-new')), findsOneWidget);
      expect(storage.files, isEmpty);

      toolbar().onSaveNative!();
      await settle(tester);

      expect(storage.files.keys, containsAll(['Part 1.didsa', 'Component 1.didsa']));
      expect(find.text('Saved 2 files'), findsOneWidget);
      panel = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      expect(panel.neverSavedPartIds, isEmpty);
      expect(panel.unsavedPartIds, isEmpty);
      expect(panel.parentUnsaved, isFalse);
      expect(find.byKey(const Key('unsaved-dot-new')), findsNothing);
      expect(toolbar().hasUnsavedChanges, isFalse);
    });

    testWidgets('a file that will not write is named, and stays marked unsaved', (tester) async {
      final storage = _FakeStorageService()..failOnWrite.add('Component 1.didsa');
      final toolbar = await pumpWithComponent(tester, storage);

      toolbar().onSaveNative!();
      await settle(tester);

      expect(find.text("Couldn't save 1 file"), findsOneWidget);
      expect(find.textContaining('Component 1.didsa'), findsWidgets);
      expect(find.textContaining('Permission denied'), findsOneWidget);
      expect(storage.files.keys, contains('Part 1.didsa'));
      await tester.tap(find.text('Close'));
      await settle(tester);
      expect(toolbar().hasUnsavedChanges, isTrue);
      expect(tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel)).neverSavedPartIds, hasLength(1));
    });

    testWidgets('leaving with unsaved parts names them', (tester) async {
      final storage = _FakeStorageService();
      await pumpWithComponent(tester, storage);

      final context = tester.element(find.byType(PartScreen));
      final popped = Navigator.of(context).maybePop();
      await settle(tester);

      expect(find.textContaining('Unsaved: '), findsOneWidget);
      expect(find.textContaining('Component 1'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(await popped, isTrue);
    });
  });

  // Desktop layout D6 (`docs/desktop-layout-scope.md`): the part screen's ribbon, docked tree and status bar, and that
  // the phone layout is untouched without them.
  group('desktop layout (D6)', () {
    Future<void> pumpScreen(WidgetTester tester, {LayoutModeController? layout}) async {
      final backend = _FakeDocumentBackend();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();
      Widget screen = PartScreen(
        documentApi: documentApi,
        sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        storageService: _FakeStorageService(),
      );
      if (layout != null) screen = LayoutModeScope(controller: layout, child: screen);
      await tester.pumpWidget(MaterialApp(home: screen));
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
    }

    LayoutModeController desktop() =>
        LayoutModeController(preference: LayoutPreference.desktop, windowSize: const Size(1280, 800), mouseActive: true);

    void bigWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('the phone layout has none of the desktop chrome', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('desktop-ribbon')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-status-bar')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-left-pane')), findsNothing);
      expect(find.byTooltip('Start'), findsOneWidget);
    });

    testWidgets('the desktop layout shows the ribbon, the docked tree and the status bar, and drops the FABs', (
      tester,
    ) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      expect(find.byKey(const ValueKey('desktop-ribbon')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-status-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-left-pane')), findsOneWidget);
      expect(find.text('Build Tree'), findsOneWidget);
      expect(find.byTooltip('Start'), findsNothing);
      expect(find.byKey(const ValueKey('quick-menu-fab')), findsNothing);
      expect(find.text('Nothing selected'), findsOneWidget);
      // The tree is docked, so it carries no Close button.
      expect(find.byTooltip('Close'), findsNothing);
    });

    testWidgets('ribbon tabs switch the buttons, and the lens switch follows into the Assembly tab', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      expect(find.byKey(const ValueKey('ribbon-Extrude')), findsOneWidget);
      expect(find.byKey(const ValueKey('ribbon-Add Component')), findsNothing);

      await tester.ensureVisible(find.byKey(const ValueKey('ribbon-tab-evaluate')));
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-evaluate')));
      await tester.pump();
      expect(find.byKey(const ValueKey('ribbon-Measure')), findsOneWidget);
      expect(find.byKey(const ValueKey('ribbon-Extrude')), findsNothing);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('ribbon-lens')), matching: find.text('Assembly')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('ribbon-Add Component')), findsOneWidget);
      expect(find.text('Assembly Tree'), findsOneWidget);
    });

    testWidgets('the New Sketch button starts the plane picker, as the Add menu does', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      await tester.tap(find.byKey(const ValueKey('ribbon-New Sketch')));
      await tester.pump();
      expect(find.text('Tap a reference plane for the new sketch'), findsOneWidget);
    });

    testWidgets('the tree pane can be folded away and brought back, and dragged wider', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      final pane = find.byKey(const ValueKey('desktop-left-pane'));
      final before = tester.getSize(pane).width;
      await tester.drag(find.byKey(const ValueKey('desktop-pane-divider')), const Offset(80, 0));
      await tester.pump();
      expect(tester.getSize(pane).width, closeTo(before + 80, 1));

      await tester.tap(find.byTooltip('Hide the tree'));
      await tester.pump();
      expect(pane, findsNothing);
      await tester.tap(find.byTooltip('Show the tree'));
      await tester.pump();
      expect(pane, findsOneWidget);
    });

    testWidgets('a tool panel docks at the left in place of the tree, and the tree comes back on Cancel', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      await tester.ensureVisible(find.byKey(const ValueKey('ribbon-tab-evaluate')));
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-evaluate')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ribbon-Measure')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('docked-tool-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-left-pane')), findsNothing);
      final panel = tester.getRect(find.byKey(const ValueKey('docked-tool-panel')));
      expect(panel.left, 0);
      expect(panel.width, 340);

      await tester.tap(find.byKey(const ValueKey('ribbon-Measure')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('docked-tool-panel')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-left-pane')), findsOneWidget);
    });

    testWidgets('the Options menu holds the settings, and View is only the ribbon tab', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      expect(find.byKey(const ValueKey('menu-view')), findsNothing);
      expect(find.byKey(const ValueKey('ribbon-tab-view')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('menu-options')));
      await tester.pump();
      for (final label in ['Select edges', 'Tree pane', 'Controls…', 'Keyboard shortcuts']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Isometric'), findsNothing);
    });

    testWidgets('the File menu lists the file actions', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      await tester.tap(find.byKey(const ValueKey('menu-file')));
      await tester.pump();
      for (final label in ['New', 'Open…', 'Save', 'Save As…', 'Save All', 'Export…', 'Exit']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
    });
  });

  // Save/project overhaul Phase 4 (`docs/save-project-overhaul-scope.md`
  // §3.4): the toolbar's own small "unsaved changes" indicator next to
  // Save - `PartToolbar.hasUnsavedChanges`, mirroring `PartScreen._isDirty`.
  group('Save/project overhaul Phase 4: unsaved-changes indicator', () {
    testWidgets('shows after a real change, and clears once Save All succeeds', (tester) async {
      final backend = _FakeDocumentBackend();
      final storage = _FakeStorageService();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();

      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: storage,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

      // Checked directly on `PartToolbar` itself (always in the tree
      // regardless of `visible`, same "grab the widget" approach the
      // Phase 3 tests above use) rather than by repeatedly opening the
      // sliding File sub-menu, which this suite's own harness struggles to
      // reopen reliably more than once or twice in a single test.
      PartToolbar toolbar() => tester.widget<PartToolbar>(find.byType(PartToolbar));

      // Nothing changed since load - no indicator yet.
      expect(toolbar().hasUnsavedChanges, isFalse);

      // Create a component - a real, guarded change.
      await switchLens(tester, 'Assembly');
      await tapStartCommand(tester, 'Create Component');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(toolbar().hasUnsavedChanges, isTrue);

      // Save All - both Parts were already auto-pathed by Create Component
      // itself (§3.1), so this succeeds with no further prompt - a full,
      // un-failed save clears the indicator.
      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Save All'));
      await tester.pump();
      await tester.tap(find.text('Save All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Saved 2 file(s)'), findsOneWidget);
      expect(toolbar().hasUnsavedChanges, isFalse);
    });
  });

  // Save/project overhaul Phase 6 (`docs/save-project-overhaul-scope.md`
  // §5, Phase 6): the unified "Open…" entry - reads the picked file first
  // and routes to whichever reader its own shape actually needs, rather
  // than making the user pick the right menu entry up front.
  group('Save/project overhaul Phase 6: unified Open', () {
    testWidgets(
      'opening a legacy multi-Part Bundle imports it directly and restores hidden features/sections, '
      'with no Project attached',
      (tester) async {
        final backend = _FakeDocumentBackend();
        final storage = _FakeStorageService();
        storage.files['bundle.DIDSAprt'] = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'schema_version': 1,
              'document': {
                'id': 'doc-1',
                'root_part_id': 'part-1',
                'parts': [
                  {
                    'id': 'part-1',
                    'name': 'Part 1',
                    'features': <dynamic>[],
                    'occurrences': <dynamic>[],
                    'mates': <dynamic>[],
                    'component_patterns': <dynamic>[],
                  },
                  {
                    'id': 'part-2',
                    'name': 'Bracket',
                    'features': <dynamic>[],
                    'occurrences': <dynamic>[],
                    'mates': <dynamic>[],
                    'component_patterns': <dynamic>[],
                  },
                ],
              },
              'sketches': <dynamic>[],
              'hidden_feature_ids': ['feature-abc'],
              'section_planes': [
                {
                  'id': 'section-1',
                  'origin': [0.0, 0.0, 0.0],
                  'normal': [0.0, 0.0, 1.0],
                  'anchor_origin': [0.0, 0.0, 0.0],
                  'flipped': false,
                  'enabled': true,
                },
              ],
            }),
          ),
        );
        final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
        final sketchBackend = _FakeSketchBackend();

        await tester.pumpWidget(
          MaterialApp(
            home: PartScreen(
              documentApi: documentApi,
              sketchApiFactory: () =>
                  SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              storageService: storage,
              canPersistFilePathForReuse: false,
            ),
          ),
        );
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

        await openToolbar(tester);
        await tester.tap(find.text('File'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.ensureVisible(find.text('Open…'));
        await tester.pump();
        await tester.tap(find.text('Open…'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Phase 5's listFiles-backed picker lists the one seeded file -
        // tapping it resolves immediately, no free-text entry needed.
        expect(find.text('bundle.DIDSAprt'), findsOneWidget);
        await tester.tap(find.text('bundle.DIDSAprt'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 250));

        // `pushReplacement`'s own transition briefly holds both the old and
        // new screen in the tree - `.last` is the one just pushed.
        final pushedScreen = tester.widgetList<PartScreen>(find.byType(PartScreen)).last;
        expect(pushedScreen.initialPartId, 'part-1');
        expect(pushedScreen.initialHiddenFeatureIds, ['feature-abc']);
        expect(pushedScreen.initialSectionPlanes, hasLength(1));
        expect(pushedScreen.initialSectionPlanes.single.id, 'section-1');
        // A Bundle never gets a Project attached - it stays exactly the
        // single-file session it always was.
        expect(pushedScreen.initialProjectRoot, isNull);
        expect(pushedScreen.initialRelativePathByPartId, isEmpty);
      },
    );

    // The Project-shaped (single-Part, composed-graph) half of the unified
    // Open entry is deliberately not tested here through the real screen -
    // confirmed directly during this phase's own implementation that even
    // a single-Part, zero-Occurrence file's `_openComposedProject` (real
    // `AssemblyGraphComposer` + real `AssemblyDocumentClient` against a
    // `MockClient`-backed backend) never settles inside this suite's own
    // `testWidgets` pump loop, the exact "real dart:io/HTTP-shaped async
    // chain + testWidgets' own fake-async pump loop" combination the Phase
    // 16 group's own doc comment above already found reliably too slow/
    // flaky to drive through the real screen (its own dedicated "Open
    // Project… through the real screen" test was dropped for the same
    // reason). Coverage for what actually changed in this phase is split
    // instead: `native_file_shape_test.dart` unit-tests the new
    // `isBundleShapedNativeFile` routing decision directly (promoted to a
    // free function specifically so it could be), the Bundle half of the
    // dispatch is exercised end-to-end just above (it never reaches
    // `_openComposedProject` at all), and the graph composition itself
    // already has its own real, non-flaky coverage in
    // `assembly_graph_composer_test.dart`/`assembly_document_client_test.dart`.
  });

  // The Appearance tool (`docs/appearance-tool-scope.md` V3) and scenes (`docs/scenes-scope.md` S3) in the assembly lens.
  group('The Appearance tool and scenes in the assembly lens', () {
    Map<String, dynamic> occurrence(String id) => {
          'id': id,
          'external_ref': 'parts/$id.didsa',
          'resolved_part_id': '$id-part',
          'name_override': null,
          'transform': {
            'translation': [0.0, 0.0, 0.0],
            'rotation_axis': [0.0, 0.0, 1.0],
            'rotation_angle_degrees': 0.0,
          },
          'suppressed': false,
          'hidden': false,
          'fixed': false,
        };

    Future<_FakeDocumentBackend> openAssembly(WidgetTester tester) async {
      final backend = _FakeDocumentBackend(seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
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
      await switchLens(tester, 'Assembly');
      return backend;
    }

    PartViewport viewport(WidgetTester tester) => tester.widget<PartViewport>(find.byType(PartViewport));

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('the colour disc opens the Appearance panel; a row paints into the root; hover previews; undo clears', (tester) async {
      final backend = await openAssembly(tester);
      final tree = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      tree.onOccurrenceColorTap!(tree.occurrences.first);
      await settle(tester);
      expect(find.byKey(const ValueKey('appearance-panel-slot')), findsOneWidget);
      final panel = tester.widget<AppearancePanel>(find.byType(AppearancePanel));
      expect(panel.rows.map((r) => r.id), ['part', 'whole'], reason: 'a component from the tree: its Part row and Whole assembly');
      expect(panel.rows.first.label, 'Part · occ-1-part');

      panel.onBrushChanged({'colour': '#3498DB', 'metallic': 0.9});
      await settle(tester);
      final rows = tester.widget<AppearancePanel>(find.byType(AppearancePanel)).rows;
      tester.widget<AppearancePanel>(find.byType(AppearancePanel)).onPaintRow(rows.first);
      await settle(tester);
      expect(backend.appearancePuts.single, {'path': 'occ-1', 'appearance': {'colour': '#3498DB', 'metallic': 0.9}});
      expect(backend.occurrences.first['color'], isNull, reason: 'the paint is an override in the root, not the occurrence');
      expect(viewport(tester).assemblyInstanceLooks['occ-1']!.whole, {'colour': '#3498DB', 'metallic': 0.9});
      expect(viewport(tester).assemblyInstanceLooks['occ-2']!.isEmpty, isTrue);

      // Hovering Whole assembly previews it on every part, nothing sent; leaving it puts the looks back.
      final whole = tester.widget<AppearancePanel>(find.byType(AppearancePanel)).rows.last;
      tester.widget<AppearancePanel>(find.byType(AppearancePanel)).onBrushChanged({'colour': '#E63946'});
      await settle(tester);
      tester.widget<AppearancePanel>(find.byType(AppearancePanel)).onPreviewRow(whole);
      await settle(tester);
      expect(viewport(tester).assemblyInstanceLooks['occ-2']!.whole['colour'], '#E63946');
      expect(viewport(tester).assemblyInstanceLooks['occ-1']!.whole['colour'], '#3498DB', reason: 'the part keeps its own (more specific) colour');
      expect(backend.appearancePuts, hasLength(1));
      tester.widget<AppearancePanel>(find.byType(AppearancePanel)).onPreviewRow(null);
      await settle(tester);
      expect(viewport(tester).assemblyInstanceLooks['occ-2']!.isEmpty, isTrue);

      await tester.tap(find.byKey(const ValueKey('appearance-undo')));
      await settle(tester);
      expect(backend.appearancePuts.last, {'path': 'occ-1', 'appearance': null});
      expect(viewport(tester).assemblyInstanceLooks['occ-1']!.isEmpty, isTrue);

      await tester.tap(find.byKey(const ValueKey('appearance-close')));
      await settle(tester);
      expect(find.byKey(const ValueKey('appearance-panel-slot')), findsNothing);
    });

    testWidgets('a scene: Hide is on screen only, Save as new sends it, Back to default and Show', (tester) async {
      final backend = await openAssembly(tester);
      await tapStartCommand(tester, 'Scenes', tab: 'evaluate');
      await settle(tester);
      expect(find.byKey(const ValueKey('scenes-panel-slot')), findsOneWidget);
      expect(find.text('No scenes in this assembly yet.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scenes-new')));
      await settle(tester);
      expect(find.textContaining('New scene from the default'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scenes-close')));
      await settle(tester);

      // Hide occ-1 while the scene shows: the viewport hides it, the model doesn't.
      final tree = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      tree.onOccurrenceLongPress(tree.occurrences.first);
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await settle(tester);
      await tester.tap(find.text('Hide'));
      await settle(tester);
      expect(backend.occurrences.first['hidden'], isFalse, reason: 'nothing sent: the scene hides it');
      expect(viewport(tester).assemblyInstances.firstWhere((i) => i.occurrencePath.join('/') == 'occ-1').hidden, isTrue);
      expect(viewport(tester).assemblyInstances.firstWhere((i) => i.occurrencePath.join('/') == 'occ-2').hidden, isFalse);

      // Save as new: the hidden part is the scene's one override.
      await tapStartCommand(tester, 'Scenes', tab: 'evaluate');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('scenes-save-new')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('scene-name-field')), 'Without one');
      await tester.tap(find.byKey(const ValueKey('scene-name-ok')));
      await settle(tester);
      expect(backend.scenePosts.single['name'], 'Without one');
      expect(backend.scenePosts.single['overrides'], [
        {'path': 'occ-1', 'hidden': true},
      ]);
      expect(find.textContaining('Showing "Without one"'), findsOneWidget);

      // Back to default: everything as the model has it.
      await tester.tap(find.byKey(const ValueKey('scenes-back')));
      await settle(tester);
      expect(viewport(tester).assemblyInstances.every((i) => !i.hidden), isTrue);
      expect(find.textContaining('Showing the default'), findsOneWidget);

      // Show it again from the list.
      // (The panel's own callbacks: in the 800x600 test window a snackbar can sit over the list.)
      final scenesPanel = tester.widget<ScenesPanel>(find.byType(ScenesPanel));
      scenesPanel.onShow(scenesPanel.scenes.firstWhere((sc) => sc['id'] == 'scene-1'));
      await settle(tester);
      expect(viewport(tester).assemblyInstances.firstWhere((i) => i.occurrencePath.join('/') == 'occ-1').hidden, isTrue);
    });

    testWidgets('leaving a changed scene asks Update / Discard / Stay', (tester) async {
      final backend = await openAssembly(tester);
      backend.scenes.add({'id': 'scene-1', 'name': 'Shown', 'overrides': <dynamic>[], 'section_planes': <dynamic>[], 'viewpoint': null, 'unresolved': <dynamic>[]});
      await tapStartCommand(tester, 'Scenes', tab: 'evaluate');
      await settle(tester);
      // (The panel's own callbacks: in the 800x600 test window a snackbar can sit over the list.)
      final scenesPanel = tester.widget<ScenesPanel>(find.byType(ScenesPanel));
      scenesPanel.onShow(scenesPanel.scenes.firstWhere((sc) => sc['id'] == 'scene-1'));
      await settle(tester);
      tester.widget<ScenesPanel>(find.byType(ScenesPanel)).onClose();
      await settle(tester);
      final tree = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
      tree.onOccurrenceLongPress(tree.occurrences.last);
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await settle(tester);
      await tester.tap(find.text('Hide'));
      await settle(tester);

      await tapStartCommand(tester, 'Scenes', tab: 'evaluate');
      await settle(tester);
      expect(find.textContaining('(changed since shown)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scenes-back')));
      await settle(tester);
      expect(find.text('Unsaved scene changes'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scene-leave-stay')));
      await settle(tester);
      expect(find.textContaining('Showing "Shown"'), findsOneWidget, reason: 'Stay keeps the scene on screen');

      await tester.tap(find.byKey(const ValueKey('scenes-back')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('scene-leave-update')));
      await settle(tester);
      expect(backend.scenePatches.single['overrides'], [
        {'path': 'occ-2', 'hidden': true},
      ]);
      expect(find.textContaining('Showing the default'), findsOneWidget);
      expect(backend.occurrences.last['hidden'], isFalse);
    });
  });
  testWidgets('a project opened with moved references shows the banner, and Review lists them', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final documentApi = DocumentApiClient(
      httpClient: MockClient((request) async => _FakeDocumentBackend().handle(request)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          initialReferenceReports: const [
            ReferenceReport(
              parentPartId: 'root',
              parentPath: 'root.didsa',
              occurrenceId: 'o-frame',
              requestedPath: 'Frame_A.didsa',
              storedPartId: 'frame',
              outcome: ReferenceOutcome.movedById,
              foundPath: 'parts/frames/Frame_A.didsa',
            ),
            ReferenceReport(
              parentPartId: 'root',
              parentPath: 'root.didsa',
              occurrenceId: 'o-gone',
              requestedPath: 'Gone.didsa',
              storedPartId: 'gone',
              outcome: ReferenceOutcome.missing,
            ),
          ],
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
    await _pumpUntil(tester, () => find.byKey(const Key('references-banner')).evaluate().isNotEmpty);

    await tester.pump(const Duration(milliseconds: 500)); // the banner slides in
    expect(find.text('1 file was found in new places, 1 needs you'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await _pumpUntil(tester, () => find.byKey(const Key('reference-o-frame')).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 500)); // the sheet slides up
    expect(find.byKey(const Key('reference-o-frame')), findsOneWidget);
    expect(find.byKey(const Key('reference-o-gone')), findsOneWidget);
    expect(find.byKey(const Key('locate-o-gone')), findsOneWidget);

    // Leave missing drops that row; the one found by id has nothing to leave.
    await tester.tap(find.byKey(const Key('leave-o-gone')));
    await tester.pump();
    expect(find.byKey(const Key('reference-o-gone')), findsNothing);
    expect(find.byKey(const Key('reference-o-frame')), findsOneWidget);
  });

  testWidgets('leaving every reference closes the Review sheet, never the screen under it', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final documentApi = DocumentApiClient(
      httpClient: MockClient((request) async => _FakeDocumentBackend().handle(request)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          initialReferenceReports: const [
            ReferenceReport(
              parentPartId: 'root',
              parentPath: 'root.didsa',
              occurrenceId: 'o-gone',
              requestedPath: 'Gone.didsa',
              storedPartId: 'gone',
              outcome: ReferenceOutcome.missing,
            ),
          ],
        ),
      ),
    );
    await _pumpUntil(tester, () => find.byKey(const Key('references-banner')).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Review'));
    await _pumpUntil(tester, () => find.byKey(const Key('reference-o-gone')).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('leave-o-gone')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const Key('reference-o-gone')), findsNothing, reason: 'the sheet closed');
    expect(find.text('Part 1'), findsOneWidget, reason: 'the screen under it is still there');
  });

  // Stress by simulated input on the whole screen: seeded random sequences of what a person does with the Appearance panel, the Scenes
  // panel, the tree and the dialogs between them. Asserts no exception and that nothing invalid was sent to the backend.
  group('Appearance and scenes under random user input', () {
    Map<String, dynamic> occurrence(String id) => {
          'id': id,
          'external_ref': 'parts/$id.didsa',
          'resolved_part_id': '$id-part',
          'name_override': null,
          'transform': {'translation': [0.0, 0.0, 0.0], 'rotation_axis': [0.0, 0.0, 1.0], 'rotation_angle_degrees': 0.0},
          'suppressed': false,
          'hidden': false,
          'fixed': false,
        };

    for (final seed in [1, 2, 3, 4, 5, 6]) {
      testWidgets('seed $seed: 250 random operations', (tester) async {
        tester.view.physicalSize = Size(seed.isEven ? 1280 : 480, seed.isEven ? 800 : 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final backend = _FakeDocumentBackend(seedOccurrences: [occurrence('occ-1'), occurrence('occ-2'), occurrence('occ-3')]);
        final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
        final sketchBackend = _FakeSketchBackend();
        await tester.pumpWidget(MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ));
        await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
        await switchLens(tester, 'Assembly');
        await tester.pump(const Duration(milliseconds: 300));

        final rng = math.Random(seed);
        final log = <String>[];
        Future<void> settle() async {
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        Future<void> tapKey(String key) async {
          final f = find.byKey(ValueKey(key));
          if (f.evaluate().isEmpty) return;
          log.add('tap $key');
          await tester.tap(f, warnIfMissed: false);
          await settle();
        }

        final ops = <String, Future<void> Function()>{
          'open appearance via disc': () async {
            if (find.byType(AssemblyTreePanel).evaluate().isEmpty) return;
            final tree = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
            if (tree.occurrences.isEmpty) return;
            tree.onOccurrenceColorTap!(tree.occurrences[rng.nextInt(tree.occurrences.length)]);
            await settle();
          },
          'brush a colour': () async {
            if (find.byType(AppearancePanel).evaluate().isEmpty) return;
            final panel = tester.widget<AppearancePanel>(find.byType(AppearancePanel));
            panel.onBrushChanged(rng.nextBool() ? {'colour': '#3498DB'} : {'opacity': 0.5, 'metallic': 0.3});
            await settle();
          },
          'paint a row': () async {
            if (find.byType(AppearancePanel).evaluate().isEmpty) return;
            final panel = tester.widget<AppearancePanel>(find.byType(AppearancePanel));
            if (panel.rows.isEmpty) return;
            panel.onPaintRow(panel.rows[rng.nextInt(panel.rows.length)]);
            await settle();
          },
          'hover a row': () async {
            if (find.byType(AppearancePanel).evaluate().isEmpty) return;
            final panel = tester.widget<AppearancePanel>(find.byType(AppearancePanel));
            if (panel.rows.isEmpty) return;
            panel.onPreviewRow(rng.nextBool() ? panel.rows[rng.nextInt(panel.rows.length)] : null);
            await settle();
          },
          'undo paint': () => tapKey('appearance-undo'),
          'close appearance': () => tapKey('appearance-close'),
          'open scenes': () async {
            if (find.byKey(const ValueKey('scenes-panel-slot')).evaluate().isNotEmpty) return;
            final start = _startFab;
            if (start.evaluate().isEmpty) return;
            await tester.tap(start, warnIfMissed: false);
            await settle();
            final evaluateTab = find.byKey(const ValueKey('ribbon-tab-evaluate'));
            if (evaluateTab.evaluate().isNotEmpty) {
              await tester.tap(evaluateTab, warnIfMissed: false);
              await settle();
            }
            final item = find.byKey(const ValueKey('start-tile-Scenes'));
            if (item.evaluate().isNotEmpty) {
              log.add('open scenes');
              await tester.tap(item, warnIfMissed: false);
              await settle();
            } else if (find.byKey(const ValueKey('start-menu-close')).evaluate().isNotEmpty) {
              await tester.tap(find.byKey(const ValueKey('start-menu-close')), warnIfMissed: false);
              await settle();
            }
          },
          'new scene': () => tapKey('scenes-new'),
          'update scene': () => tapKey('scenes-update'),
          'save scene as new': () => tapKey('scenes-save-new'),
          'back to default': () => tapKey('scenes-back'),
          'close scenes': () => tapKey('scenes-close'),
          'show a scene': () async {
            final rows = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('scene-row-'));
            if (rows.evaluate().isEmpty) return;
            log.add('show scene');
            await tester.tap(rows.at(rng.nextInt(rows.evaluate().length)), warnIfMissed: false);
            await settle();
          },
          'hide a component (long press)': () async {
            if (find.byType(AssemblyTreePanel).evaluate().isEmpty) return;
            final tree = tester.widget<AssemblyTreePanel>(find.byType(AssemblyTreePanel));
            if (tree.occurrences.isEmpty) return;
            tree.onOccurrenceLongPress(tree.occurrences[rng.nextInt(tree.occurrences.length)]);
            await settle();
          },
          'answer a dialog': () async {
            if (find.byType(AlertDialog).evaluate().isEmpty) return;
            final field = find.byType(TextField);
            if (field.evaluate().isNotEmpty && rng.nextBool()) await tester.enterText(field.first, rng.nextBool() ? 'Scene ${rng.nextInt(99)}' : '   ');
            final buttons = find.descendant(of: find.byType(AlertDialog), matching: find.byType(ButtonStyleButton));
            if (buttons.evaluate().isEmpty) return;
            log.add('dialog button');
            await tester.tap(buttons.at(rng.nextInt(buttons.evaluate().length)), warnIfMissed: false);
            await settle();
          },
          'tap anywhere': () async {
            final size = tester.view.physicalSize;
            await tester.tapAt(Offset(rng.nextDouble() * size.width, rng.nextDouble() * size.height));
            await settle();
          },
          'drag the viewport': () async {
            final size = tester.view.physicalSize;
            await tester.dragFrom(Offset(size.width / 2, size.height / 2), Offset(rng.nextDouble() * 200 - 100, rng.nextDouble() * 200 - 100));
            await settle();
          },
          'toggle viewpoint switches': () async {
            await tapKey(rng.nextBool() ? 'scenes-use-viewpoint' : 'scenes-save-view');
          },
        };
        // Weighted: the panels' own controls are most of what a person does; stray taps and drags are the minority.
        final names = [
          for (final name in ops.keys) ...List.filled(name.startsWith('tap anywhere') || name.startsWith('drag') ? 1 : 4, name),
        ];
        for (var step = 0; step < 250; step++) {
          final name = names[rng.nextInt(names.length)];
          log.add('#$step $name');
          await ops[name]!();
          final error = tester.takeException();
          if (error != null) fail('after ${log.skip(log.length > 8 ? log.length - 8 : 0).join(' > ')}: $error');
        }
        // ignore: avoid_print
        print('STRESS seed $seed: ${log.where((l) => !l.startsWith('#')).length} effective actions, ${backend.appearancePuts.length} paints sent, ${backend.scenePatches.length} scene patches');
        for (final put in backend.appearancePuts) {
          final appearance = put['appearance'];
          expect(appearance == null || appearanceErrors(appearance).isEmpty, isTrue, reason: 'invalid appearance sent: $put');
        }
      });
    }
  });
}
