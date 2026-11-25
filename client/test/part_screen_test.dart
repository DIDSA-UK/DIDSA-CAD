import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
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
import 'package:didsa_cad_client/storage/routing_storage_service.dart';
import 'package:didsa_cad_client/storage/server/remote_storage_service.dart';
import 'package:didsa_cad_client/storage/server/store_client.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';
import 'support/fake_project_store.dart';
import 'support/in_memory_stores.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_helpers.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_open_store.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';
import 'package:didsa_cad_client/viewport3d/selection_list_drawer.dart';
import 'package:didsa_cad_client/viewport3d/view_preferences.dart';
import 'package:didsa_cad_client/viewport3d/assembly_context_strip.dart';
import 'package:didsa_cad_client/viewport3d/extrude_panel.dart';
import 'package:didsa_cad_client/viewport3d/sketch_feature_tree.dart';
import 'package:didsa_cad_client/viewport3d/feature_picker_sheet.dart' show kFeatureGroups;
import 'package:didsa_cad_client/viewport3d/controls_preferences.dart';
import 'package:didsa_cad_client/viewport3d/mate_panel.dart';
import 'package:didsa_cad_client/viewport3d/measurement_panel.dart';
import 'package:didsa_cad_client/viewport3d/feature_context_menu.dart';
import 'package:didsa_cad_client/viewport3d/mirror_panel.dart';
import 'package:didsa_cad_client/viewport3d/multi_select_action_bar.dart';
import 'package:didsa_cad_client/viewport3d/assembly_component_selection_drawer.dart';
import 'package:didsa_cad_client/viewport3d/component_context_menu.dart';
import 'package:didsa_cad_client/viewport3d/component_gizmo.dart';
import 'package:didsa_cad_client/viewport3d/component_pattern_panel.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/part_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_toolbar.dart';
import 'package:didsa_cad_client/viewport3d/view_appearance_override.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/curve_panel.dart' show CurveMode;
import 'package:didsa_cad_client/viewport3d/pattern_panel.dart';
import 'package:didsa_cad_client/viewport3d/presentation_mode.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/render_mode.dart';
import 'package:didsa_cad_client/viewport3d/visibility_panel.dart';
import 'package:didsa_cad_client/viewport3d/resizable_tool_panel.dart';
import 'package:didsa_cad_client/viewport3d/picker_ribbon.dart';
import 'package:didsa_cad_client/viewport3d/seed_scope.dart';
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
  Future<void> put(ProjectRoot root, String relativePath, Uint8List bytes, {DateTime? lastKnownModified, int? serverVersion}) async {}

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

  /// Bug report 2026-11-17 items 2B / M.3: every POST / PATCH to `pattern-features` / `mirror-features` (coarse previews included), in
  /// order, and what `face-owner-features` answers for a face (`'bodyId:index'` -> feature id).
  final List<({String method, String path, Map<String, dynamic> body})> patternMirrorRequests = [];
  final Map<String, String> faceOwners = {};
  int faceOwnerRequests = 0;

  /// M1: makes `POST .../mates` answer 422.
  bool failMateCreate = false;

  /// M3: what `POST .../occurrences/{id}/preview-mate-solve` answers (null = 404, no preview). A `POST .../mates` carrying `solve` stores the poses of its
  /// `members` on the occurrences, as the backend's atomic create does.
  Map<String, dynamic>? previewMateSolveAnswer;
  int previewMateSolveCount = 0;

  /// Bug fix regression coverage ("patterns have stopped showing in the
  /// feature tree... this was working before"): how many times `GET
  /// .../features` has actually been called - proves [PartScreen] really
  /// re-fetches the Feature list on Confirm, not just that a freshly-loaded
  /// `_features` happens to already contain what the test expects.
  int featuresGetCount = 0;

  /// Hide / Show as Part state (`PATCH .../visibility`): each Part's hidden Feature ids and reference-planes flag, every
  /// request body in order, and a switch that makes the route fail.
  final Map<String, Set<String>> hiddenByPart = {};
  final Map<String, bool> referencePlanesHiddenByPart = {};

  /// Per-plane hidden state ("XY" / "XZ" / "YZ") a `reference_plane_ids` PATCH sets; when a Part has no entry the old
  /// [referencePlanesHiddenByPart] bool stands for all three.
  final Map<String, Set<String>> hiddenPlanesByPart = {};

  Set<String> _hiddenPlanes(String partId) =>
      hiddenPlanesByPart[partId] ?? ((referencePlanesHiddenByPart[partId] ?? false) ? {'XY', 'XZ', 'YZ'} : <String>{});
  final List<Map<String, dynamic>> visibilityRequests = [];
  bool failVisibility = false;

  /// The most recent `POST .../import/native` body (what the Open flows send the backend).
  Map<String, dynamic>? lastImportBody;

  /// Extra placed instances the fake's `assembly-mesh` answers for `part-1` beside one per occurrence (a pattern's copies and what is
  /// nested under them): `occurrence_path` / `part_id` / `world_transform` maps.
  List<Map<String, dynamic>> extraAssemblyInstances = const [];

  /// Part ids the fake's `assembly-mesh` carries (empty) geometry for, so a test can have several Parts in the scene.
  List<String> assemblyGeometryPartIds = const [];

  /// Parts the fake's `assembly-mesh` gives one body to (this mesh), so a test can frame real extents.
  Map<String, Map<String, dynamic>> assemblyBodyMeshes = {};

  /// Occurrences of a sub-assembly (a Part other than `part-1`), by Part id: `GET .../parts/{id}/occurrences` answers them.
  Map<String, List<Map<String, dynamic>>> subOccurrences = {};

  /// Every request that is not a GET, in order (so a test can check that nothing was written).
  final List<String> writes = [];

  /// A4: every PATCH / DELETE of an occurrence that lives in a sub-assembly (`subOccurrences`): `part`, `id`, `method`, `body`.
  final List<Map<String, dynamic>> subOccurrenceWrites = [];

  /// Sketch origin (Item 3b): every `POST .../features/sketch` body, every `origin` a `PATCH .../sketch-origin` sent (`'auto'`, a map, or null), and what the fake
  /// answers with: [autoStored] / [autoResolved] for `'auto'` (null = "no origin", the plane's own), [pickResolved] for a concrete origin.
  final List<Map<String, dynamic>> sketchCreateBodies = [];
  final List<Object?> originPatches = [];

  /// Sketch alignment (item 2 of the 2026-11-11 feedback): every `x_axis_ref` a `PATCH .../sketch-alignment` sent (a map, or null), the aligned anchor axes the fake answers a
  /// concrete alignment with, and an optional refusal (the 422 `type`).
  final List<Object?> alignmentPatches = [];
  List<double> alignedX = const [0.0, 1.0, 0.0];
  List<double> alignedY = const [-1.0, 0.0, 0.0];
  String? alignmentError;
  Map<String, dynamic>? autoStored;
  List<double>? autoResolved;
  List<double> pickResolved = const [11.0, 12.0, 13.0];

  /// When set, `GET .../part-1/mesh` returns these Bodies (`body_id` / `source` / `mesh` maps, optionally
  /// `is_surface` / `is_curve`) with `hidden` worked out from [hiddenByPart] and the `hidden_feature_ids` query parameter,
  /// the way the real route does.
  List<Map<String, dynamic>>? meshBodies;

  /// P2: Parts whose `GET .../mesh` (full detail) answers 500, as a Part with a broken feature would; and the features of Parts other than
  /// `part-1` (empty when not set).
  final Set<String> failMeshFor = {};
  final Map<String, List<Map<String, dynamic>>> extraPartFeatures = {};

  /// P3 (P2 review items): Parts whose full mesh answers 200 with a body that is not JSON (an error that is not the backend's), and Parts
  /// whose `GET .../features` answers 500.
  final Set<String> badMeshFor = {};
  final Set<String> failFeaturesFor = {};

  /// Parts whose `GET .../features` answers 200 with a body that is not JSON.
  final Set<String> badFeaturesFor = {};

  Map<String, dynamic> _visibilityFields(String partId) => {
        'hidden_feature_ids': (hiddenByPart[partId] ?? <String>{}).toList()..sort(),
        'hidden_reference_planes': _hiddenPlanes(partId).toList()..sort(),
        'reference_planes_hidden': _hiddenPlanes(partId).length == 3,
      };

  /// Every Curve feature PATCH body, in order (the Helix edit test).
  final List<Map<String, dynamic>> curvePatchBodies = [];

  /// Every Curve feature POST body, in order (the Helix / Intersection create tests).
  final List<Map<String, dynamic>> curveCreateBodies = [];

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

  /// F2: every dissolve call, `"<part id>/<pattern id>"`.
  final List<String> dissolveCalls = [];

  /// F1: every `PATCH .../component-patterns/{id}` body, and the mates its scripted answer reports as left broken.
  final List<Map<String, dynamic>> patternPatches = [];
  List<String> brokenMateIdsOnPatternEdit = [];

  /// The Appearance tool / scenes (V3 / S3): each Part's appearance overrides, every PUT body, `part-1`'s scenes and the
  /// scene POST / PATCH bodies.
  final Map<String, List<Map<String, dynamic>>> appearanceOverrides = {};
  final List<Map<String, dynamic>> appearancePuts = [];
  final List<Map<String, dynamic>> scenes = [];
  final List<Map<String, dynamic>> scenePosts = [];
  final List<Map<String, dynamic>> scenePatches = [];

  /// `GET .../constraint-status` for `part-1` (item 7) and how often it was
  /// asked - the tree refreshes it next to the occurrence list. A4: the Assembly tree reads it through `assembly-tree?status=true`
  /// (the top level of `part-1`), so this map is what that answers as each occurrence's `constraint`.
  final Map<String, dynamic> constraintStatus = {};
  int constraintStatusRequests = 0;

  /// A4: `GET .../assembly-tree`, answered from [occurrences] and [subOccurrences] (a sub-assembly's occurrences nest under the occurrence
  /// that places it) the way the real route does: every request's query (plus the Part id under `part`), a switch for a backend without
  /// the route (404), and the Part ids' feature counts a part row shows a chevron for.
  final List<Map<String, String>> assemblyTreeRequests = [];
  bool assemblyTreeMissing = false;
  Map<String, int> treeFeatureCounts = {};

  String _treePartName(String partId) => partId == 'part-1' ? partOneName : '${extraParts[partId]?['name'] ?? partId}';

  Map<String, dynamic> assemblyTreeJson(String partId, {required bool status}) {
    final seen = <String, int>{};
    void count(List<dynamic> occs, Set<String> ancestors) {
      for (final o in occs) {
        final resolved = (o as Map)['resolved_part_id'] as String?;
        if (resolved == null) continue;
        seen[resolved] = (seen[resolved] ?? 0) + 1;
        if (!ancestors.contains(resolved)) count(subOccurrences[resolved] ?? const [], {...ancestors, resolved});
      }
    }

    List<Map<String, dynamic>> level(String owner, List<dynamic> occs, List<String> parentPath, Set<String> ancestors) {
      return [
        for (final raw in occs)
          () {
            final o = raw as Map<String, dynamic>;
            final id = o['id'] as String;
            final resolved = o['resolved_part_id'] as String?;
            final path = [...parentPath, id];
            final cycle = resolved != null && ancestors.contains(resolved);
            final subs = resolved == null || cycle ? const <dynamic>[] : (subOccurrences[resolved] ?? const <dynamic>[]);
            final constraint = status && owner == 'part-1' ? constraintStatus[id] : null;
            return <String, dynamic>{
              'occurrence_id': id,
              'path': path,
              'external_ref': o['external_ref'],
              'ref_part_id': resolved,
              'resolved_part_id': resolved,
              'part_name': resolved == null ? null : _treePartName(resolved),
              'name_override': o['name_override'],
              'kind': resolved == null ? 'missing' : (subs.isNotEmpty ? 'assembly' : 'part'),
              'fixed': o['fixed'] ?? false,
              'hidden': o['hidden'] ?? false,
              'suppressed': o['suppressed'] ?? false,
              'color': o['color'],
              if (constraint != null) 'constraint': constraint,
              'feature_count': resolved == null ? null : (treeFeatureCounts[resolved] ?? 0),
              'placements': resolved == null ? null : seen[resolved],
              'cycle': cycle,
              'children': level(resolved ?? '', subs, path, resolved == null ? ancestors : {...ancestors, resolved}),
            };
          }(),
      ];
    }

    // A root that was imported under a new id (a Save As copy reopened) has the occurrences it was imported with.
    final rootOccs = partId == 'part-1' ? occurrences : (subOccurrences[partId] ?? (extraParts[partId]?['occurrences'] as List<dynamic>?) ?? const <dynamic>[]);
    count(rootOccs, {partId});
    final children = level(partId, rootOccs, const [], {partId});
    final mateList = partId == 'part-1' ? mates : const <Map<String, dynamic>>[];
    final patternList = partId == 'part-1' ? componentPatterns : const <Map<String, dynamic>>[];
    return {
      'part_id': partId,
      'part_name': _treePartName(partId),
      'kind': children.isEmpty ? 'part' : 'assembly',
      'feature_count': treeFeatureCounts[partId] ?? 0,
      'status_included': status,
      if (mateList.isNotEmpty)
        'mates': {
          'count': mateList.length,
          if (status) 'broken': mateList.where((m) => m['status'] == 'broken').length,
          if (status) 'near': mateList.where((m) => m['status'] == 'near').length,
        },
      if (patternList.isNotEmpty) 'patterns': {'count': patternList.length},
      'children': children,
      'node_count': children.length,
    };
  }
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
    if (method != 'GET') writes.add('$method $path');
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
          ..._visibilityFields('part-1'),
        }, 200);
      }
      final extra = extraParts[id];
      if (extra == null) return http.Response('not found: part', 404);
      return _json({
        'id': extra['id'],
        'name': extra['name'],
        'feature_ids': <String>[],
        'occurrence_ids': (extra['occurrences'] as List).map((o) => o['id']).toList(),
        ..._visibilityFields(id!),
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

    // Hide / Show (`docs/touch-viewport-ux-plan.md` section 6.1): the real route's rules - ids, categories (a Feature's
    // `produces`, 'none' when a seed leaves it out) and reference planes, an unknown id is a 422.
    final visibilityMatch = RegExp(r'^/document/parts/([^/]+)/visibility$').firstMatch(path);
    if (visibilityMatch != null && method == 'PATCH') {
      visibilityRequests.add({'part_id': visibilityMatch.group(1), ...body});
      if (failVisibility) return http.Response(jsonEncode({'detail': 'visibility refused'}), 500);
      final partId = visibilityMatch.group(1)!;
      final ids = ((body['feature_ids'] as List?) ?? const []).cast<String>();
      final categories = ((body['categories'] as List?) ?? const []).cast<String>();
      final planes = body['reference_planes'] == true;
      final planeIds = ((body['reference_plane_ids'] as List?) ?? const []).cast<String>();
      if (ids.isEmpty && categories.isEmpty && !planes && planeIds.isEmpty) return http.Response(jsonEncode({'detail': 'no target'}), 422);
      final known = features.map((f) => f['id']).toSet();
      if (partId == 'part-1' && ids.any((id) => !known.contains(id))) {
        return http.Response(jsonEncode({'detail': 'Unknown feature ids'}), 422);
      }
      final hidden = body['hidden'] == true;
      final targets = {
        ...ids,
        if (partId == 'part-1')
          for (final f in features)
            if (categories.contains(f['produces'] ?? 'none')) f['id'] as String,
      };
      final set = hiddenByPart.putIfAbsent(partId, () => <String>{});
      hidden ? set.addAll(targets) : set.removeAll(targets);
      if (planes) {
        referencePlanesHiddenByPart[partId] = hidden;
        hiddenPlanesByPart.remove(partId);
      }
      if (planeIds.isNotEmpty) {
        final current = {..._hiddenPlanes(partId)};
        hidden ? current.addAll(planeIds) : current.removeAll(planeIds);
        hiddenPlanesByPart[partId] = current;
      }
      return _json(_visibilityFields(partId), 200);
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
      lastImportBody = body;
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
    final failMeshMatch = RegExp(r'^/document/parts/([^/]+)/mesh$').firstMatch(path);
    if (failMeshMatch != null && method == 'GET' && failMeshFor.contains(failMeshMatch.group(1)) &&
        request.url.queryParameters['tier'] != 'coarse') {
      return _json({'detail': 'The shape could not be built'}, 500);
    }
    if (failMeshMatch != null && method == 'GET' && badMeshFor.contains(failMeshMatch.group(1)) &&
        request.url.queryParameters['tier'] != 'coarse') {
      return http.Response('<html>proxy error</html>', 200);
    }
    final failFeaturesMatch = RegExp(r'^/document/parts/([^/]+)/features$').firstMatch(path);
    if (failFeaturesMatch != null && method == 'GET' && badFeaturesFor.contains(failFeaturesMatch.group(1))) {
      return http.Response('<html>proxy error</html>', 200);
    }
    if (failFeaturesMatch != null && method == 'GET' && failFeaturesFor.contains(failFeaturesMatch.group(1))) {
      return _json({'detail': 'The features could not be read'}, 500);
    }
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
      return _json(extraPartFeatures[extraPartFeaturesMatch.group(1)] ?? <Map<String, dynamic>>[], 200);
    }

    if (path == '/document/parts/part-1/mesh' && method == 'GET' && meshBodies != null) {
      meshRequests.add(request.url.queryParameters);
      final hiddenNow = {
        ...(hiddenByPart['part-1'] ?? <String>{}),
        ...request.url.queryParametersAll['hidden_feature_ids'] ?? const <String>[],
      };
      return _json([
        for (final b in meshBodies!)
          {...b, 'hidden': hiddenNow.contains((b['body_id'] as String).split('#').first)},
      ], 200);
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
      sketchCreateBodies.add(body);
      final feature = <String, dynamic>{
        'type': 'sketch',
        'id': 'feature-${_nextFeatureId++}',
        'sketch_id': 'sketch-$_nextFeatureId',
        'locked': false,
        if (body['plane_feature_id'] != null) 'plane_feature_id': body['plane_feature_id'],
      };
      if (body['origin'] == 'auto' && autoResolved != null) {
        feature['origin'] = autoStored;
        feature['resolved_origin'] = autoResolved;
      }
      features.add(feature);
      return _json(feature, 201);
    }

    final originMatch = RegExp(r'^/document/parts/part-1/features/([^/]+)/sketch-origin$').firstMatch(path);
    if (originMatch != null && method == 'PATCH') {
      final feature = features.firstWhere((f) => f['id'] == originMatch.group(1));
      final origin = body['origin'];
      originPatches.add(origin);
      if (origin == 'auto') {
        feature['origin'] = autoStored;
        feature['resolved_origin'] = autoResolved;
      } else if (origin == null) {
        feature.remove('origin');
        feature.remove('resolved_origin');
      } else {
        feature['origin'] = origin;
        feature['resolved_origin'] = pickResolved;
      }
      return _json(feature, 200);
    }

    final alignmentMatch = RegExp(r'^/document/parts/part-1/features/([^/]+)/sketch-alignment$').firstMatch(path);
    if (alignmentMatch != null && method == 'PATCH') {
      final feature = features.firstWhere((f) => f['id'] == alignmentMatch.group(1));
      final ref = body['x_axis_ref'];
      alignmentPatches.add(ref);
      if (alignmentError != null) {
        return http.Response(jsonEncode({'detail': {'type': alignmentError}}), 422);
      }
      if (ref == null) {
        feature.remove('x_axis_ref');
        feature.remove('aligned_x_axis');
        feature.remove('aligned_y_axis');
      } else {
        feature['x_axis_ref'] = ref;
        feature['aligned_x_axis'] = alignedX;
        feature['aligned_y_axis'] = alignedY;
      }
      return _json(feature, 200);
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

    if (path == '/document/parts/part-1/face-owner-features' && method == 'POST') {
      faceOwnerRequests++;
      final faces = (body['faces'] as List).cast<Map<String, dynamic>>();
      return _json({
        'features': [
          for (final f in faces)
            {'face': f, 'feature_id': faceOwners['${f['subshape_ref']['body_id']}:${f['subshape_ref']['index']}'] ?? 'unknown'},
        ],
      }, 200);
    }
    final patternMirrorMatch = RegExp(r'^/document/parts/part-1/(pattern|mirror)-features(/.*)?$').firstMatch(path);
    if (patternMirrorMatch != null && (method == 'POST' || method == 'PATCH')) {
      patternMirrorRequests.add((method: method, path: path, body: body));
      final suffix = patternMirrorMatch.group(2);
      if (method == 'POST' && suffix == '/coarse-preview') return http.Response('[]', 200);
      if (method == 'POST' && suffix == null) {
        final feature = <String, dynamic>{
          ...body,
          'id': 'feature-${_nextFeatureId++}',
          'type': patternMirrorMatch.group(1),
          'locked': false,
          'produces': 'body',
        };
        features.add(feature);
        return _json(feature, 201);
      }
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

    if (path == '/document/parts/part-1/curve-features' && method == 'POST') {
      curveCreateBodies.add(Map<String, dynamic>.from(body));
      final feature = {
        'type': 'curve',
        'id': 'curve-${curveCreateBodies.length}',
        'locked': false,
        ...body,
      };
      features.add(feature);
      return _json(feature, 201);
    }
    final curvePatchMatch = RegExp(r'^/document/parts/part-1/curve-features/([^/]+)$').firstMatch(path);
    if (curvePatchMatch != null && method == 'PATCH') {
      final featureId = curvePatchMatch.group(1);
      final feature = features.firstWhere((f) => f['id'] == featureId, orElse: () => {});
      if (feature.isEmpty) return http.Response('not found: feature', 404);
      curvePatchBodies.add(Map<String, dynamic>.from(body));
      for (final key in ['radius', 'end_radius', 'segments', 'right_handed', 'sketch_feature_id_a', 'sketch_feature_id_b']) {
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
      final listedPart = occurrencesGetMatch.group(1)!;
      return _json(listedPart == 'part-1' ? occurrences : (subOccurrences[listedPart] ?? <dynamic>[]), 200);
    }
    // Item 7: the Assembly tree's constraint badge. Scripted by tests via
    // [constraintStatus]; empty by default (no badge, plain fixed pin).
    final assemblyTreeMatch = RegExp(r'^/document/parts/([^/]+)/assembly-tree$').firstMatch(path);
    if (assemblyTreeMatch != null && method == 'GET') {
      final treePart = assemblyTreeMatch.group(1)!;
      assemblyTreeRequests.add({...request.url.queryParameters, 'part': treePart});
      if (assemblyTreeMissing) return http.Response('not found', 404);
      return _json(assemblyTreeJson(treePart, status: request.url.queryParameters['status'] == 'true'), 200);
    }
    final constraintStatusMatch = RegExp(r'^/document/parts/([^/]+)/constraint-status$').firstMatch(path);
    if (constraintStatusMatch != null && method == 'GET') {
      constraintStatusRequests++;
      return _json(constraintStatusMatch.group(1) == 'part-1' ? constraintStatus : <String, dynamic>{}, 200);
    }
    final previewMatch = RegExp(r'^/document/parts/part-1/occurrences/([^/]+)/preview-mate-solve$').firstMatch(path);
    if (previewMatch != null && method == 'POST') {
      previewMateSolveCount++;
      final answer = previewMateSolveAnswer;
      return answer == null ? http.Response('no preview', 404) : _json(answer, 200);
    }
    final matesGetMatch = RegExp(r'^/document/parts/([^/]+)/mates$').firstMatch(path);
    if (matesGetMatch != null && method == 'GET') {
      return _json(matesGetMatch.group(1) == 'part-1' ? mates : <dynamic>[], 200);
    }
    if (matesGetMatch != null && method == 'POST') {
      if (failMateCreate) return _json({'detail': 'No placement satisfies these mates together.'}, 422);
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
      if (request.url.queryParameters.containsKey('solve') && previewMateSolveAnswer != null) {
        for (final member in (previewMateSolveAnswer!['members'] as List)) {
          final target = occurrences.firstWhere((o) => o['id'] == member['occurrence_id'], orElse: () => const {});
          if (target.isNotEmpty) target['transform'] = member['transform'];
        }
      }
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
    // F1: `PATCH .../component-patterns/{id}` answers the stored pattern plus the mates the edit left broken (scripted); those mates
    // list as `status: broken` from then on.
    final componentPatternPatchMatch =
        RegExp(r'^/document/parts/part-1/component-patterns/([^/]+)$').firstMatch(path);
    if (componentPatternPatchMatch != null && method == 'PATCH') {
      final index = componentPatterns.indexWhere((p) => p['id'] == componentPatternPatchMatch.group(1));
      if (index == -1) return http.Response('not found: pattern', 404);
      patternPatches.add(Map<String, dynamic>.from(body));
      componentPatterns[index] = {...componentPatterns[index], ...body};
      for (final mate in mates) {
        if (brokenMateIdsOnPatternEdit.contains(mate['id'])) mate['status'] = 'broken';
      }
      return _json({...componentPatterns[index], 'broken_mate_ids': brokenMateIdsOnPatternEdit}, 200);
    }
    // F2: `POST .../component-patterns/{id}/dissolve` - the pattern goes, two new occurrences take its copies' place.
    final patternDissolveMatch =
        RegExp(r'^/document/parts/([^/]+)/component-patterns/([^/]+)/dissolve$').firstMatch(path);
    if (patternDissolveMatch != null && method == 'POST') {
      dissolveCalls.add('${patternDissolveMatch.group(1)}/${patternDissolveMatch.group(2)}');
      final patternId = patternDissolveMatch.group(2);
      final index = componentPatterns.indexWhere((p) => p['id'] == patternId);
      if (index == -1) return http.Response('not found: pattern', 404);
      componentPatterns.removeAt(index);
      final created = [
        for (var i = 1; i <= 2; i++)
          {
            'id': 'dissolved-$i',
            'external_ref': 'parts/dissolved.didsa',
            'resolved_part_id': 'dissolved-part',
            'name_override': null,
            'transform': {'translation': [10.0 * i, 0.0, 0.0], 'rotation_axis': [0.0, 0.0, 1.0], 'rotation_angle_degrees': 0.0},
            'suppressed': false,
            'hidden': false,
            'fixed': false,
          },
      ];
      occurrences.addAll(created);
      return _json({'occurrences': created, 'renamed': {'occ-1#pattern:$patternId:1': 'dissolved-1', 'occ-1#pattern:$patternId:2': 'dissolved-2'}}, 200);
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
        'geometry': [
          for (final id in {...assemblyGeometryPartIds, ...assemblyBodyMeshes.keys})
            {
              'part_id': id,
              'bodies': [
                if (assemblyBodyMeshes[id] != null) {'body_id': 'b', 'source': 'computed', 'mesh': assemblyBodyMeshes[id]},
              ],
            },
        ],
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
          if (forRoot) ...extraAssemblyInstances,
        ],
      }, 200);
    }
    // A4: an occurrence of a sub-assembly (a Part other than `part-1`): the PATCH / DELETE a nested tree row sends to its parent Part.
    final subOccurrenceMatch = RegExp(r'^/document/parts/([^/]+)/occurrences/([^/]+)$').firstMatch(path);
    if (subOccurrenceMatch != null && subOccurrenceMatch.group(1) != 'part-1' && (method == 'PATCH' || method == 'DELETE')) {
      final owner = subOccurrenceMatch.group(1)!;
      final list = subOccurrences[owner] ?? const <Map<String, dynamic>>[];
      final target = list.where((o) => o['id'] == subOccurrenceMatch.group(2)).firstOrNull;
      if (target == null) return http.Response('not found: occurrence', 404);
      subOccurrenceWrites.add({'part': owner, 'id': target['id'], 'method': method, 'body': body});
      if (method == 'DELETE') {
        subOccurrences[owner]!.removeWhere((o) => o['id'] == target['id']);
        return http.Response('', 204);
      }
      if (body.containsKey('hidden')) target['hidden'] = body['hidden'];
      if (body.containsKey('fixed')) target['fixed'] = body['fixed'];
      if (body.containsKey('name_override')) target['name_override'] = (body['name_override'] as String).isEmpty ? null : body['name_override'];
      return _json(target, 200);
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

  /// The profile response's `open_chain` (no closed profile, one open chain: a thin Revolve can use it).
  final bool openChain;

  _FakeSketchBackend({this.profileStatus = 'closed_loop', this.openChain = false});

  /// Every `PATCH .../orientation`: `(flip, rotation_quarter_turns)`.
  final List<(bool, int)> orientationPatches = [];

  http.Response handle(http.Request request) {
    final orientationMatch = RegExp(r'^/sketch/sketches/([^/]+)/orientation$').firstMatch(request.url.path);
    if (orientationMatch != null && request.method == 'PATCH') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      orientationPatches.add((body['flip'] as bool, body['rotation_quarter_turns'] as int));
      return http.Response(
        jsonEncode({
          'id': orientationMatch.group(1),
          'plane': null,
          'origin_point_id': 'origin-1',
          'flip': body['flip'],
          'rotation_quarter_turns': body['rotation_quarter_turns'],
        }),
        200,
      );
    }
    final profileMatch = RegExp(r'^/sketch/sketches/([^/]+)/profile$').firstMatch(request.url.path);
    if (profileMatch != null && request.method == 'GET') {
      return http.Response(
        jsonEncode({'status': profileStatus, 'detail': 'fake', 'branch_point_ids': [], 'loops': [], 'open_chain': openChain}),
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
class _FakeStorageService with FileByFileCommit implements StorageService {
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

  /// Modified times, as a real folder would stamp them: set by every [writeFile] (a later time each write) and by a test that
  /// simulates a file changed outside the app. Files placed directly in [files] have none. (Decision S0-8's check reads these.)
  final Map<String, DateTime> modified = {};
  int _tick = 0;

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
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes, {int? baseVersion}) async {
    if (failOnWrite.contains(relativePath)) throw StorageException('Permission denied');
    files[relativePath] = bytes;
    modified[relativePath] = DateTime(2026, 1, 1).add(Duration(seconds: ++_tick));
    writeCounts[relativePath] = (writeCounts[relativePath] ?? 0) + 1;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async => modified[handle.relativePath];

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
// Bug report 2026-11-17 items 2B / M.3: a part with a body-making boss (`feature-2`, body `feature-2`) and a cut into it
// (`feature-4`), for the Pattern / Mirror scope tests.
const _bossAndCut = [
  {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
  {'type': 'extrude', 'id': 'feature-2', 'sketch_feature_id': 'feature-1', 'extrude_type': 'boss', 'start_distance': 0.0,
   'end_distance': 10.0, 'locked': true},
  {'type': 'sketch', 'id': 'feature-3', 'sketch_id': 'sketch-1', 'locked': true},
  {'type': 'extrude', 'id': 'feature-4', 'sketch_feature_id': 'feature-3', 'extrude_type': 'cut', 'start_distance': 0.0,
   'end_distance': 10.0, 'target_body_ids': ['feature-2'], 'locked': false},
];

Future<_FakeDocumentBackend> _pumpScopeScreen(WidgetTester tester, {List<Map<String, dynamic>> seedFeatures = _bossAndCut}) async {
  final backend = _FakeDocumentBackend(seedFeatures: [for (final f in seedFeatures) Map<String, dynamic>.from(f)]);
  final sketchBackend = _FakeSketchBackend();
  await tester.pumpWidget(
    MaterialApp(
      home: PartScreen(
        documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
        sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
      ),
    ),
  );
  await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
  return backend;
}

/// A tap on face [index] of [bodyId] in the viewport (the route a real tap takes, `PartViewport.onSelectionToggle`).
Future<void> _tapFace(WidgetTester tester, String bodyId, int index) async {
  tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
        SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: bodyId, id: index),
      );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

SeedScopeTab _scopeTab(WidgetTester tester) =>
    tester.widget<SegmentedButton<SeedScopeTab>>(find.byType(SegmentedButton<SeedScopeTab>)).selected.single;

/// The body of the last create (`POST .../pattern-features` or `.../mirror-features`, not a coarse preview).
Map<String, dynamic>? _lastCreate(_FakeDocumentBackend backend, String kind) {
  final creates = [
    for (final r in backend.patternMirrorRequests)
      if (r.method == 'POST' && r.path == '/document/parts/part-1/$kind-features') r.body,
  ];
  return creates.isEmpty ? null : creates.last;
}

Future<void> _openFromLongPress(WidgetTester tester, String row, String entry) async {
  await tester.tap(find.byTooltip('Feature tree'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.longPress(find.text(row));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.byTooltip('More actions'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.text(entry));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

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
/// A4: the old Assembly panel's surface (what its fields said and what its callbacks did), over the real [AssemblyTreeView]: reads come from
/// its model, and a "callback" is the gesture on the row that calls it (a long-press, a tap, a right click).
class _TreeProbe {
  _TreeProbe(this.tester);
  final WidgetTester tester;

  AssemblyTreeView get view => tester.widget<AssemblyTreeView>(find.byType(AssemblyTreeView));
  AssemblyTreeModel get model {
    final m = view.model;
    lastModel = m;
    return m;
  }

  /// The model the view had when it was last read: a folded desktop pane builds no view, but the model is still the screen's.
  static AssemblyTreeModel? lastModel;

  static OccurrenceDto occurrenceOf(AssemblyTreeNodeDto n) => OccurrenceDto(
        id: n.occurrenceId,
        externalRef: n.externalRef,
        resolvedPartId: n.resolvedPartId,
        nameOverride: n.nameOverride,
        transform: RigidTransformDto(translation: const [0.0, 0.0, 0.0], rotationAxis: const [0.0, 0.0, 1.0], rotationAngleDegrees: 0.0),
        suppressed: n.suppressed,
        hidden: n.hidden,
        fixed: n.fixed,
        color: n.color,
      );

  /// The components directly in the tree's root, in order.
  List<OccurrenceDto> get occurrences => [for (final n in model.tree?.children ?? const <AssemblyTreeNodeDto>[]) occurrenceOf(n)];

  /// The top-level selection (an id), or null.
  String? get selectedOccurrenceId {
    final key = model.selectedKey;
    return key == null || key.isEmpty || key.contains('/') || key.contains('#') ? null : key;
  }

  Map<String, ConstraintStatusDto> get constraintStatusByOccurrenceId => topLevelConstraintStatus(model.tree!);

  /// The mates and patterns the folders list, as the host gave them (a mate whose tone is error reads as broken).
  List<AssemblyFolderItem> get mates => model.folderItems('#mates');
  List<AssemblyFolderItem> get patterns => model.folderItems('#patterns');

  /// Keys of the rows that show the unsaved dot (the root's key is the empty string).
  List<String> get unsavedRowKeys => [for (final r in model.visibleRows()) if (r.state == AssemblyRowState.unsaved) r.key];

  Set<String> get flashMateIds => view.flashItemIds;
  int get flashToken => view.flashToken;

  /// A tap on any row, by its key (the row must be listed: open its parents first).
  Future<void> tapRow(String key) async {
    view.onRowTap!(_row(key));
    await tester.pump();
  }

  /// The row's own menu, as a right click opens it, and the entry [label] of it.
  Future<void> menuAction(String key, String label) async {
    view.onRowContextMenu!(_row(key), const Offset(300, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // The popup's own entry (the phone's selection bar has a Hide and an Isolate too).
    final entry = find.descendant(of: find.byType(PopupMenuItem<ComponentContextMenuAction>), matching: find.text(label));
    // The menu opens over 300 ms, and its last rows are not there to hit until it has: the longer the menu, the later.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// The focus strip's second-last crumb: one level out (the floating tree is slid off the screen while closed, so it is called, not tapped).
  Future<void> exitFocus() async {
    view.onFocusCrumb!(view.focusCrumbs.length - 2);
    await tester.pump();
  }

  AssemblyTreeRow _row(String key) => model.visibleRows().firstWhere((r) => r.key == key);

  AssemblyTreeRow _itemRow(AssemblyRowKind kind, AssemblyFolderItem item) => AssemblyTreeRow(
        key: '${kind == AssemblyRowKind.mate ? '#mates' : '#patterns'}#item:${item.id}',
        kind: kind,
        depth: 2,
        label: item.label,
        state: AssemblyRowState.none,
        itemId: item.id,
      );

  // The old panel's callbacks are the view's own: the tests call them as they called the panel's (the floating tree is slid off the
  // screen while closed, so a gesture could not reach its rows).

  /// A long-press on the occurrence's row: the multi-select starts (its "More" opens the row menu).
  Future<void> onOccurrenceLongPress(OccurrenceDto o) async {
    view.onRowLongPress!(_row(o.id));
    await tester.pump();
  }

  Future<void> onOccurrenceTap(OccurrenceDto o) async {
    view.onRowTap!(_row(o.id));
    await tester.pump();
  }

  Future<void> Function(OccurrenceDto)? get onOccurrenceVisibilityToggle => (o) async {
        view.onVisibilityToggle!(_row(o.id));
        await tester.pump();
      };

  /// The old colour disc: now the row menu's Appearance entry (a right click opens it at the cursor).
  Future<void> Function(OccurrenceDto)? get onOccurrenceColorTap => (o) async {
        view.onRowContextMenu!(_row(o.id), const Offset(300, 200));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('Appearance...'));
        await tester.pump();
      };

  Future<void> Function(AssemblyFolderItem)? get onPatternTap => (item) async {
        view.onRowTap!(_itemRow(AssemblyRowKind.pattern, item));
        await tester.pump();
      };

  Future<void> Function(AssemblyFolderItem)? get onPatternLongPress => (item) async {
        view.onRowLongPress!(_itemRow(AssemblyRowKind.pattern, item));
        await tester.pump();
      };
}

/// P2 (`docs/assembly-tree-overhaul-scope.md` 10.6): a tap on a build tree row (the one tree, [AssemblyTreeView]) selects it. A live
/// feature row waits out the double-tap before its tap lands, so this pumps past it.
Future<void> _tapTreeRow(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text(label)));
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
}

/// What the old build tree's tap did (open the feature for editing, rolled back to it): select the row, then the bar's Edit.
Future<void> _editFromTree(WidgetTester tester, String label) async {
  await _tapTreeRow(tester, label);
  await tester.tap(find.byKey(const ValueKey('tree-bar-edit')));
}

Future<void> switchLens(WidgetTester tester, String to) async {
  await openStartMenu(tester);
  await tester.tap(find.descendant(of: find.byKey(const ValueKey('start-lens')), matching: find.text(to)));
  await _settleSheet(tester);
  await tester.tap(find.byKey(const ValueKey('start-menu-close')));
  await _settleSheet(tester);
}

/// The sync status symbol of an open server project lives in the Start button's quick column (it must not cover the triad).
/// Opens the column, reports whether the button is there, and closes the column again.
Future<bool> _syncButtonPresent(WidgetTester tester) async {
  await openQuickColumn(tester);
  final present = find.byKey(const ValueKey('quick-sync-fab')).evaluate().isNotEmpty;
  await tester.tap(find.byKey(const ValueKey('start-fab')));
  await _settleSheet(tester);
  return present;
}

/// The symbol the sync button shows right now (cloud done = synced, upload = to send, warning = clash, cloud off = offline).
Future<IconData?> _syncIcon(WidgetTester tester) async {
  await openQuickColumn(tester);
  final icon = tester.widget<Icon>(
    find.descendant(of: find.byKey(const ValueKey('quick-sync-fab')), matching: find.byType(Icon)).first,
  );
  await tester.tap(find.byKey(const ValueKey('start-fab')));
  await _settleSheet(tester);
  return icon.icon;
}

/// File menu > [entry] (the phone layout's quick-menu panel).
Future<void> _fileMenuTap(WidgetTester tester, String entry) async {
  await openToolbar(tester);
  await tester.tap(find.text('File'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.ensureVisible(find.text(entry));
  await tester.pump();
  await tester.tap(find.text(entry));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
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
    // P2: the one tree's root row names the part too.
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Part 1')), findsOneWidget);
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
      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).showResetViewButton,
        isFalse,
        reason: 'Fit is in the quick column',
      );
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

    testWidgets('Menu panel opens in the bottom-right quadrant, and Back closes it', (tester) async {
      await pumpScreen(tester);
      await openToolbar(tester);
      await _settleSheet(tester);
      final rect = tester.getRect(find.byType(PartToolbar).evaluate().isEmpty
          ? find.byType(Scaffold)
          : find.descendant(
              of: find.byType(PartToolbar),
              matching: find.byWidgetPredicate((w) => w is Material && w.elevation == 4),
            ));
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(rect.center.dx, greaterThan(screen.width / 2));
      expect(rect.center.dy, greaterThan(screen.height / 2));
      expect(rect.height, lessThanOrEqualTo(screen.height * 2 / 3 + 0.01));
      await tester.binding.handlePopRoute();
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

  group('Presentation mode (phone layout)', () {
    final platformCalls = <MethodCall>[];
    _FakeStorageService? storage;

    Future<void> pumpScreen(WidgetTester tester) async {
      platformCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final backend = _FakeDocumentBackend();
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();
      storage = _FakeStorageService();
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
    }

    final presenterButton = find.byKey(const ValueKey('presenter-button'));

    Future<void> present(WidgetTester tester) async {
      await tapStartCommand(tester, 'Present', tab: 'view');
      await tester.pump();
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(presenterButton);
      await _settleSheet(tester);
    }

    bool presenting(WidgetTester tester) => presenterButton.evaluate().isNotEmpty;

    testWidgets('the View tab has Present and Share screen', (tester) async {
      await pumpScreen(tester);
      await openStartMenu(tester);
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-view')));
      await _settleSheet(tester);
      expect(find.byKey(const ValueKey('start-tile-Present')), findsOneWidget);
      expect(find.byKey(const ValueKey('start-tile-Share screen')), findsOneWidget);
    });

    testWidgets('Present hides the editing chrome, Stop presenting puts it back', (tester) async {
      await pumpScreen(tester);
      expect(_startFab, findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      await present(tester);
      expect(presenting(tester), isTrue);
      expect(_startFab, findsNothing);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('Feature tree'), findsNothing);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);

      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('presenter-stop')));
      await _settleSheet(tester);
      expect(presenting(tester), isFalse);
      expect(_startFab, findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('immersive and landscape while presenting, both undone on exit', (tester) async {
      await pumpScreen(tester);
      await present(tester);
      expect(platformCalls.map((c) => c.method), contains('SystemChrome.setEnabledSystemUIMode'));
      expect(platformCalls.firstWhere((c) => c.method == 'SystemChrome.setEnabledSystemUIMode').arguments,
          'SystemUiMode.immersiveSticky');
      expect(platformCalls.firstWhere((c) => c.method == 'SystemChrome.setPreferredOrientations').arguments,
          ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
      platformCalls.clear();
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('presenter-stop')));
      await _settleSheet(tester);
      expect(platformCalls.firstWhere((c) => c.method == 'SystemChrome.setPreferredOrientations').arguments, isEmpty);
      expect(platformCalls.firstWhere((c) => c.method == 'SystemChrome.setEnabledSystemUIMode').arguments,
          'SystemUiMode.edgeToEdge');
    });

    testWidgets('the presenter button fades to a ghost but is still there and tappable', (tester) async {
      await pumpScreen(tester);
      await present(tester);
      double opacity() => tester.widget<AnimatedOpacity>(find.ancestor(of: presenterButton, matching: find.byType(AnimatedOpacity))).opacity;
      expect(opacity(), PresenterButton.activeOpacity);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(opacity(), PresenterButton.fadedOpacity);
      expect(presenterButton.hitTestable(), findsOneWidget);
      await openMenu(tester);
      expect(find.byKey(const ValueKey('presenter-menu')), findsOneWidget);
      expect(opacity(), PresenterButton.activeOpacity);
    });

    testWidgets('the menu lists Open, Show all controls and Stop presenting', (tester) async {
      await pumpScreen(tester);
      await present(tester);
      await openMenu(tester);
      for (final key in ['open', 'turntable', 'reset-view', 'clear-pivot', 'controls', 'stop']) {
        expect(find.byKey(ValueKey('presenter-$key')), findsOneWidget, reason: key);
      }
      expect(find.text('Show all controls'), findsOneWidget);
      // No pivot is set, so there is nothing to clear.
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('presenter-clear-pivot'))).enabled, isFalse);
    });

    testWidgets('Show all controls brings the UI back while still presenting; the button hides it again', (tester) async {
      await pumpScreen(tester);
      await present(tester);
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('presenter-controls')));
      await _settleSheet(tester);
      expect(_startFab, findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(presenting(tester), isTrue, reason: 'still presenting');
      expect(platformCalls.where((c) => c.method == 'SystemChrome.setPreferredOrientations' && (c.arguments as List).isEmpty), isEmpty,
          reason: 'the landscape lock stays');

      await openMenu(tester);
      expect(find.text('Hide controls'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('presenter-controls')));
      await _settleSheet(tester);
      expect(_startFab, findsNothing);
      expect(presenting(tester), isTrue);
    });

    testWidgets('Back: closes the menu, then hides the controls, then asks Stop presenting?', (tester) async {
      await pumpScreen(tester);
      await present(tester);

      // Menu open: Back closes it.
      await openMenu(tester);
      await tester.binding.handlePopRoute();
      await _settleSheet(tester);
      expect(find.byKey(const ValueKey('presenter-menu')), findsNothing);
      expect(presenting(tester), isTrue);

      // Controls shown: Back hides them.
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('presenter-controls')));
      await _settleSheet(tester);
      expect(_startFab, findsOneWidget);
      await tester.binding.handlePopRoute();
      await _settleSheet(tester);
      expect(_startFab, findsNothing);
      expect(presenting(tester), isTrue);

      // Nothing else: it asks, and Keep presenting keeps going.
      await tester.binding.handlePopRoute();
      await _settleSheet(tester);
      expect(find.text('Stop presenting?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('presenting-keep')));
      await _settleSheet(tester);
      expect(presenting(tester), isTrue);

      // And Stop leaves it.
      await tester.binding.handlePopRoute();
      await _settleSheet(tester);
      await tester.tap(find.byKey(const ValueKey('presenting-stop')));
      await _settleSheet(tester);
      expect(presenting(tester), isFalse);
      expect(_startFab, findsOneWidget);
    });

    testWidgets('Open model runs the normal open flow and stays in Presentation mode', (tester) async {
      await pumpScreen(tester);
      await present(tester);
      expect(storage!.pickOrCreateProjectRootCallCount, 0);
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('presenter-open')));
      await _settleSheet(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(storage!.pickOrCreateProjectRootCallCount, 1, reason: 'the project folder picker of the Open flow ran');
      expect(presenting(tester), isTrue);
      expect(_startFab, findsNothing);
    });

    testWidgets('Share screen opens the dialog, and its Present button starts presenting', (tester) async {
      await pumpScreen(tester);
      await tapStartCommand(tester, 'Share screen', tab: 'view');
      await tester.pump();
      expect(find.byKey(const ValueKey('share-screen-dialog')), findsOneWidget);
      expect(presenting(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('share-present')));
      await _settleSheet(tester);
      expect(presenting(tester), isTrue);
    });
  });

  group('Hide / Show is Part state, with the Visibility panel (phone layout)', () {
    final List<Map<String, dynamic>> twoSketches = [
      {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true, 'produces': 'sketch'},
      {'type': 'sketch', 'id': 'feature-2', 'sketch_id': 'sketch-2', 'locked': false, 'produces': 'sketch'},
    ];

    Future<_FakeDocumentBackend> pumpScreen(
      WidgetTester tester,
      _FakeDocumentBackend backend, {
      String? initialPartId,
    }) async {
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            initialPartId: initialPartId,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      return backend;
    }

    Future<void> openPanel(WidgetTester tester) async {
      await tapQuickButton(tester, 'quick-visibility-fab');
    }

    /// The chips scroll sideways when the card is narrower than the row: bring one into view, then tap it.
    Future<void> tapChip(WidgetTester tester, String id) async {
      final chip = find.byKey(ValueKey('vis-chip-$id'));
      await tester.ensureVisible(chip);
      await tester.pump();
      await tester.tap(chip);
    }

    VisibilityChipData chipData(WidgetTester tester, String id) =>
        tester.widget<VisibilityPanel>(find.byType(VisibilityPanel)).chips.firstWhere((c) => c.id == id);

    Future<void> settleRequests(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('the quick column has a Visibility button; it opens the panel, closes the column, and the panel stays', (
      tester,
    ) async {
      await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      expect(find.byType(VisibilityPanel), findsNothing);
      await openPanel(tester);
      expect(find.byType(VisibilityPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing, reason: 'opening it closes the column');
      // It stays while the user works: opening the column again leaves it open.
      await openQuickColumn(tester);
      expect(find.byType(VisibilityPanel), findsOneWidget);
      await tester.tap(_startFab);
      await _settleSheet(tester);
      await tester.tap(find.byKey(const ValueKey('vis-close')));
      await _settleSheet(tester);
      expect(find.byType(VisibilityPanel), findsNothing);
    });

    testWidgets('a chip sends one batch call and applies the response; the chip then reads hidden', (tester) async {
      final backend = await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await openPanel(tester);
      expect(chipData(tester, 'sketch').state, VisibilityChipState.shown);

      await tapChip(tester, 'sketch');
      await settleRequests(tester);

      expect(backend.visibilityRequests, [
        {
          'part_id': 'part-1',
          'hidden': true,
          'feature_ids': <String>[],
          'categories': ['sketch'],
          'reference_planes': false,
        },
      ]);
      expect(backend.hiddenByPart['part-1'], {'feature-1', 'feature-2'});
      expect(chipData(tester, 'sketch').state, VisibilityChipState.hidden);

      await tapChip(tester, 'sketch');
      await settleRequests(tester);
      expect(backend.visibilityRequests.last['hidden'], isFalse);
      expect(backend.hiddenByPart['part-1'], isEmpty);
      expect(chipData(tester, 'sketch').state, VisibilityChipState.shown);
    });

    testWidgets('a chip with nothing in its category is disabled', (tester) async {
      await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await openPanel(tester);
      expect(chipData(tester, 'surface').onTap, isNull);
      expect(chipData(tester, 'body').onTap, isNull);
      expect(chipData(tester, 'sketch').onTap, isNotNull);
    });

    testWidgets('a failed call rolls the chip back and shows the error', (tester) async {
      final backend = _FakeDocumentBackend(seedFeatures: twoSketches)..failVisibility = true;
      await pumpScreen(tester, backend);
      await openPanel(tester);
      await tapChip(tester, 'sketch');
      await settleRequests(tester);
      expect(backend.visibilityRequests, hasLength(1));
      expect(chipData(tester, 'sketch').state, VisibilityChipState.shown, reason: 'back to what the backend holds');
      expect(find.textContaining('visibility refused'), findsOneWidget);
    });

    testWidgets('a tree hide goes through the same call, and shows the chip half-filled', (tester) async {
      final backend = await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await tester.tap(find.byTooltip('Feature tree'));
      await _settleSheet(tester);
      await tester.longPress(find.text('Sketch 1'));
      await _settleSheet(tester);
      await tester.tap(find.byTooltip('More actions'));
      await _settleSheet(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Hide'));
      await settleRequests(tester);
      await _settleSheet(tester);

      expect(backend.visibilityRequests.first, containsPair('feature_ids', ['feature-1']));
      expect(backend.visibilityRequests.first, containsPair('hidden', true));
      expect(backend.hiddenByPart['part-1'], {'feature-1'});
      await tester.tap(find.byTooltip('Close')); // the tree's own X
      await _settleSheet(tester);
      await openPanel(tester);
      expect(chipData(tester, 'sketch').state, VisibilityChipState.partial);

      // A partly hidden category: a tap shows all of it.
      await tapChip(tester, 'sketch');
      await settleRequests(tester);
      expect(backend.visibilityRequests.last, containsPair('hidden', false));
      expect(backend.hiddenByPart['part-1'], isEmpty);
    });

    testWidgets('the reference planes chip sends the planes flag and hides them in the viewport', (tester) async {
      final backend = await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await openPanel(tester);
      await tapChip(tester, 'reference-planes');
      await settleRequests(tester);
      expect(backend.visibilityRequests.single, containsPair('reference_planes', true));
      expect(backend.referencePlanesHiddenByPart['part-1'], isTrue);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).referencePlanesHidden, isTrue);
      expect(chipData(tester, 'reference-planes').state, VisibilityChipState.hidden);
    });

    Set<ReferencePlaneKind> hiddenPlanes(WidgetTester tester) =>
        tester.widget<PartViewport>(find.byType(PartViewport)).hiddenReferencePlanes;

    testWidgets('the tree lists the three default planes under Planes; an eye hides one, the chip then reads partial', (
      tester,
    ) async {
      final backend = await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await tester.tap(find.byTooltip('Feature tree'));
      await _settleSheet(tester);
      await tester.tap(find.text('Planes'));
      await _settleSheet(tester);
      for (final label in ['XY plane', 'XZ plane', 'YZ plane']) {
        expect(find.text(label), findsOneWidget);
      }
      // P2: a phone row has no eye (no buttons in phone rows): a default plane's long-press offers Hide / Show.
      await tester.longPress(find.text('XZ plane'));
      await _settleSheet(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Hide'));
      await settleRequests(tester);
      expect(backend.visibilityRequests.single, containsPair('reference_plane_ids', ['XZ']));
      expect(backend.visibilityRequests.single, containsPair('hidden', true));
      expect(hiddenPlanes(tester), {ReferencePlaneKind.xz});
      await tester.tap(find.byTooltip('Close')); // the tree's own X
      await _settleSheet(tester);
      await openPanel(tester);
      expect(chipData(tester, 'reference-planes').state, VisibilityChipState.partial);

      // The chip with some hidden hides all three, then showing one from the tree leaves it not "hidden".
      await tapChip(tester, 'reference-planes');
      await settleRequests(tester);
      expect(backend.visibilityRequests.last, containsPair('reference_planes', true));
      expect(backend.visibilityRequests.last, containsPair('hidden', true));
      expect(hiddenPlanes(tester), kAllReferencePlanes);
      expect(chipData(tester, 'reference-planes').state, VisibilityChipState.hidden);
    });

    testWidgets('showing one plane from the tree after hiding all three un-hides only that one', (tester) async {
      final backend = _FakeDocumentBackend(seedFeatures: twoSketches)..referencePlanesHiddenByPart['part-1'] = true;
      await pumpScreen(tester, backend, initialPartId: 'part-1');
      expect(hiddenPlanes(tester), kAllReferencePlanes);
      await tester.tap(find.byTooltip('Feature tree'));
      await _settleSheet(tester);
      await tester.tap(find.text('Planes'));
      await _settleSheet(tester);
      await tester.longPress(find.text('YZ plane'));
      await _settleSheet(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Show'));
      await settleRequests(tester);
      expect(backend.visibilityRequests.last, containsPair('reference_plane_ids', ['YZ']));
      expect(backend.visibilityRequests.last, containsPair('hidden', false));
      expect(hiddenPlanes(tester), {ReferencePlaneKind.xy, ReferencePlaneKind.xz});
    });

    testWidgets('what the backend holds when the Part loads is what the screen shows', (tester) async {
      final backend = _FakeDocumentBackend(seedFeatures: twoSketches)
        ..hiddenByPart['part-1'] = {'feature-1'}
        ..referencePlanesHiddenByPart['part-1'] = true;
      // An existing Part opened: its Hide / Show state comes with it from the backend.
      await pumpScreen(tester, backend, initialPartId: 'part-1');
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).referencePlanesHidden, isTrue);
      await openQuickColumn(tester);
      expect(find.byKey(const ValueKey('quick-badge')), findsOneWidget, reason: 'something is hidden');
      await tester.tap(find.byKey(const ValueKey('quick-visibility-fab')));
      await _settleSheet(tester);
      expect(chipData(tester, 'sketch').state, VisibilityChipState.partial, reason: 'one of the two sketches is hidden');
      expect(chipData(tester, 'reference-planes').state, VisibilityChipState.hidden);
    });

    testWidgets('the quick button has no badge while nothing is hidden', (tester) async {
      await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await openQuickColumn(tester);
      expect(find.byKey(const ValueKey('quick-badge')), findsNothing);
    });

    testWidgets('hiding Solids removes the bodies from the viewport', (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true, 'produces': 'sketch'},
          {'type': 'extrude', 'id': 'feature-2', 'locked': false, 'produces': 'body'},
        ],
      )..meshBodies = [
          {'body_id': 'feature-2', 'source': 'computed', 'mesh': _FakeDocumentBackend._placeholderMesh},
        ];
      await pumpScreen(tester, backend);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodies, hasLength(1));
      await openPanel(tester);
      await tapChip(tester, 'body');
      await settleRequests(tester);
      await _settleSheet(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodies, isEmpty);
      expect(chipData(tester, 'body').state, VisibilityChipState.hidden);
    });

    testWidgets('a plane pick shows hidden created planes while it lasts, with the chip locked, and hides them again', (
      tester,
    ) async {
      final Map<String, dynamic> plane = {
        'type': 'create_plane',
        'id': 'feature-3',
        'locked': false,
        'produces': 'plane',
        'origin': [0.0, 0.0, 5.0],
        'normal': [0.0, 0.0, 1.0],
        'x_axis': [1.0, 0.0, 0.0],
        'y_axis': [0.0, 1.0, 0.0],
      };
      final backend = _FakeDocumentBackend(seedFeatures: [...twoSketches, plane]);
      await pumpScreen(tester, backend);
      PartViewport viewport() => tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewport().createPlanes, hasLength(1));

      await openPanel(tester);
      await tapChip(tester, 'plane');
      await settleRequests(tester);
      await _settleSheet(tester);
      expect(viewport().createPlanes, isEmpty, reason: 'hidden');
      expect(chipData(tester, 'plane').locked, isFalse);

      // New Sketch asks for a plane to be tapped: the created plane has to be drawn and pickable meanwhile.
      await tester.tap(find.byKey(const ValueKey('vis-close')));
      await _settleSheet(tester);
      await tapStartCommand(tester, 'New Sketch');
      expect(viewport().createPlanes, hasLength(1), reason: 'forced into view for the pick');
      expect(backend.hiddenByPart['part-1'], {'feature-3'}, reason: 'forcing is display only');
      expect(backend.visibilityRequests, hasLength(1), reason: 'nothing was sent for it');

      await tester.tap(find.text('Cancel'));
      await _settleSheet(tester);
      expect(viewport().createPlanes, isEmpty, reason: 'back to hidden when the pick ends');
    });

    testWidgets('a body pick shows hidden solids while it lasts, and the chip shows the lock', (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true, 'produces': 'sketch'},
          {'type': 'extrude', 'id': 'feature-2', 'locked': false, 'produces': 'body'},
        ],
      )..meshBodies = [
          {'body_id': 'feature-2', 'source': 'computed', 'mesh': _FakeDocumentBackend._placeholderMesh},
        ];
      await pumpScreen(tester, backend);
      PartViewport viewport() => tester.widget<PartViewport>(find.byType(PartViewport));
      await openPanel(tester);
      await tapChip(tester, 'body');
      await settleRequests(tester);
      await _settleSheet(tester);
      expect(viewport().bodies, isEmpty);
      await tester.tap(find.byKey(const ValueKey('vis-close')));
      await _settleSheet(tester);

      await tapStartCommand(tester, 'Mirror');
      expect(viewport().bodies, hasLength(1), reason: 'Mirror picks bodies: they are drawn and pickable meanwhile');
      expect(backend.hiddenByPart['part-1'], {'feature-2'});
    });

    testWidgets('the panel is not drawn while a tool owns the screen and is back when it closes', (tester) async {
      final backend = _FakeDocumentBackend(seedFeatures: twoSketches);
      await pumpScreen(tester, backend);
      await openPanel(tester);
      await tapStartCommand(tester, 'Measure', tab: 'evaluate');
      expect(find.byType(VisibilityPanel), findsNothing, reason: 'Measure owns the bottom of the screen');
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await _settleSheet(tester);
      expect(find.byType(VisibilityPanel), findsOneWidget, reason: 'nothing was lost');
    });

    testWidgets('the View row has the standard views and no fold chevron', (tester) async {
      await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await openPanel(tester);
      for (final name in ['front', 'back', 'left', 'right', 'top', 'bottom', 'isometric']) {
        expect(find.byKey(ValueKey('vis-view-$name')), findsOneWidget, reason: name);
      }
      await tester.tap(find.byKey(const ValueKey('vis-view-top')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100)); // the 400 ms camera move, frame by frame
      }
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vis-fold-views')), findsNothing);
      expect(find.byKey(const ValueKey('vis-view-top')), findsOneWidget);
    });

    testWidgets('C2: the Style row changes the render mode the same way the View menu does', (tester) async {
      await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await openPanel(tester);
      PartViewport viewportNow() => tester.widget<PartViewport>(find.byType(PartViewport));
      final before = viewportNow().renderMode;
      final other = ViewportRenderMode.values.firstWhere((m) => m != before);
      await tester.tap(find.byKey(ValueKey('vis-mode-${other.name}')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(viewportNow().renderMode, other);
      final selected = tester.widget<OutlinedButton>(find.byKey(ValueKey('vis-mode-${other.name}')));
      expect(selected.style?.backgroundColor?.resolve(<WidgetState>{}), isNotNull, reason: 'the panel shows the new mode selected');
    });

    testWidgets('in Assembly lens a chip makes one call for every Part in the scene', (tester) async {
      final backend = _FakeDocumentBackend(
        seedFeatures: twoSketches,
        seedOccurrences: [
          {
            'id': 'occ-1',
            'external_ref': 'a.didsa',
            'resolved_part_id': 'part-2',
            'name_override': null,
            'transform': {
              'translation': [0.0, 0.0, 0.0],
              'rotation_axis': [0.0, 0.0, 1.0],
              'rotation_angle_degrees': 0.0,
            },
            'suppressed': false,
            'hidden': false,
          },
        ],
      )
        ..extraParts['part-2'] = {'id': 'part-2', 'name': 'Part 2', 'occurrences': <Map<String, dynamic>>[]}
        ..assemblyGeometryPartIds = ['part-1', 'part-2'];
      await pumpScreen(tester, backend);
      await switchLens(tester, 'Assembly');
      await openPanel(tester);
      await tapChip(tester, 'sketch');
      await settleRequests(tester);
      expect({for (final r in backend.visibilityRequests) r['part_id']}, {'part-1', 'part-2'});
      expect(backend.visibilityRequests.every((r) => (r['categories'] as List).contains('sketch')), isTrue);
    });

    testWidgets('a hide that is still in flight is not undone by an earlier response', (tester) async {
      final backend = await pumpScreen(tester, _FakeDocumentBackend(seedFeatures: twoSketches));
      await openPanel(tester);
      await tapChip(tester, 'sketch');
      await tapChip(tester, 'sketch');
      await settleRequests(tester);
      expect(backend.visibilityRequests.map((r) => r['hidden']), [true, false]);
      expect(chipData(tester, 'sketch').state, VisibilityChipState.shown);
      expect(backend.hiddenByPart['part-1'], isEmpty);
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
    // P2: a healthy row is one line (no "Editable" subtitle, rule 1 of the scope's section 3); no lock badge either.
    expect(find.text('Editable'), findsNothing);

    // The toolbar's Menu button is left out of the quick column while the tree is open (the tree's own X button is the
    // way to close it instead); the column's other buttons are still there.
    await openQuickColumn(tester);
    expect(find.byKey(const ValueKey('quick-menu-fab')), findsNothing);
    expect(find.byKey(const ValueKey('quick-fit-fab')), findsOneWidget);
    expect(find.byTooltip('Close toolbar'), findsNothing);
    await tester.tap(_startFab); // the X closes the column again
    await _settleSheet(tester);

    await _editFromTree(tester, 'Sketch 1'); // P2: a tap selects; Edit is the bar's
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

    // Two clicks on the row before anything has had time to open. P2: the double-click is Edit (a single click selects), the clicks spaced
    // as a person's are (past the double-tap's minimum). Two mouse clicks of their own: a real mouse gets a new pointer id for each press,
    // a single TestGesture keeps one for both, and the double-tap arena never sees the second.
    final row = tester.getCenter(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('Sketch 1')));
    for (var i = 0; i < 2; i++) {
      await tester.tapAt(row, kind: PointerDeviceKind.mouse);
      if (i == 0) await tester.pump(const Duration(milliseconds: 60));
    }
    await _pumpUntil(tester, () => find.text('DIDSA-CAD Sketch').evaluate().isNotEmpty);
    expect(find.text('DIDSA-CAD Sketch'), findsOneWidget);
    expect(find.byType(SketchScreen), findsOneWidget, reason: 'one Sketch screen on the stack, not two');
    expect(tester.takeException(), isNull);
  });

  testWidgets('bug report 2026-11-18 B: a sketch opened from the Part has the feature tree, read-mostly', (tester) async {
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
    await _editFromTree(tester, 'Sketch 2'); // P2: a tap selects; Edit is the bar's
    await _pumpUntil(tester, () => find.byType(SketchScreen).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 300));

    // The tree is closed until the sketcher's own button opens it.
    expect(find.byKey(const ValueKey('sketch-tree-fab')), findsOneWidget);
    expect(find.descendant(of: find.byType(SketchScreen), matching: find.text('Build Tree')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final tree = find.descendant(of: find.byType(SketchScreen), matching: find.byType(SketchFeatureTree));
    expect(tree, findsOneWidget);
    // P3: the one tree, read-mostly. The sketch being edited is selected; another feature does not open (still one SketchScreen, same sketch),
    // and says why.
    final view = tester.widget<AssemblyTreeView>(find.descendant(of: tree, matching: find.byType(AssemblyTreeView)));
    expect(view.model.selectedKey, '#feature:feature-2');
    await tester.tap(find.descendant(of: tree, matching: find.text('Sketch 1')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SketchScreen), findsOneWidget);
    expect(find.descendant(of: tree, matching: find.text('Exit the sketch first')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-eye:#feature:feature-2')), findsNothing, reason: 'the sketch being edited has no eye');

    // The eye works (the Part screen hides the feature and the sketcher's tree follows): the row offers Show.
    await tester.tap(find.byKey(const ValueKey('tree-eye:#feature:feature-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('tree-eye-off:#feature:feature-1')), findsOneWidget);
    expect(find.descendant(of: tree, matching: find.byTooltip('Show')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // B3 (P3's review): `_buildSketchTreePanel` brought this screen's own tree model up to date from inside the sketcher's build (a side effect of
  // building another route's widget). With the desktop pane folded this screen builds no tree of its own, so the model is the screen's alone
  // and must stay as the screen left it while the sketcher draws its copy.
  testWidgets("building the sketcher's tree changes nothing in the Part screen's own tree model", (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backend = _FakeDocumentBackend();
    final sketchBackend = _FakeSketchBackend();
    final layout = LayoutModeController(preference: LayoutPreference.desktop, windowSize: const Size(1280, 800), mouseActive: true);
    await tester.pumpWidget(
      MaterialApp(
        home: LayoutModeScope(
          controller: layout,
          child: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
    // The screen's own tree model, read while the docked pane shows it; then the pane is folded, so nothing but the sketcher builds a tree.
    final model = _TreeProbe(tester).model;
    final liveBefore = model.livePart;
    expect(liveBefore, isNotNull);
    expect(liveBefore!.features, isEmpty);
    await tester.tap(find.byTooltip('Hide the tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AssemblyTreeView), findsNothing, reason: 'folded: the screen builds no tree of its own');

    // A new sketch (the part gains a feature, which the screen's tree model has not been told about) and the sketcher over it.
    await tester.tap(find.byKey(const ValueKey('ribbon-New Sketch')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    tester.widget<PartViewport>(find.byType(PartViewport)).onPlaneTap(ReferencePlaneKind.xy);
    await _pumpUntil(tester, () => find.text('Continue').evaluate().isNotEmpty);
    await tester.tap(find.text('Continue'));
    await _pumpUntil(tester, () => find.byType(SketchScreen).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The sketcher's tree has the new sketch (it is built from the screen's fields)...
    final tree = find.descendant(of: find.byType(SketchScreen), matching: find.byType(SketchFeatureTree));
    expect(tree, findsOneWidget);
    expect(find.descendant(of: tree, matching: find.text('Sketch 1')), findsOneWidget);
    // ...and the screen's own model is as it was: building the sketcher's tree did not update it.
    expect(identical(model.livePart, liveBefore), isTrue);
    expect(model.livePart!.features, isEmpty);
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

    await _editFromTree(tester, 'Pattern 1'); // P2: a tap selects; Edit is the bar's
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

    await _editFromTree(tester, 'Merge 1'); // P2: a tap selects; Edit is the bar's
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

    await _editFromTree(tester, 'Subtract 1'); // P2: a tap selects; Edit is the bar's
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

    await _editFromTree(tester, 'Surface 1'); // P2: a tap selects; Edit is the bar's
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

  testWidgets('editing a saved feature pattern opens on the Feature tab with its features in scope; "Add from Tree" adds to it '
      '(bug report 2026-11-17 item 2B)', (tester) async {
    final backend = await _pumpScopeScreen(tester, seedFeatures: [
      ..._bossAndCut,
      {'type': 'pattern', 'id': 'feature-5', 'source_body_ids': <String>[], 'source_feature_ids': <String>[], 'tool_feature_id': 'feature-4',
       'tool_feature_ids': ['feature-4'], 'pattern_type': 'rectangular',
       'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'}, 'count_1': 3, 'spacing_1': 10.0, 'reverse_1': false,
       'direction_2': null, 'count_2': 1, 'spacing_2': 0.0, 'reverse_2': false, 'axis': null, 'count_angular': 1, 'angle_total': 360.0,
       'reverse_angular': false, 'skip_indices': [], 'merge': 'fuse_into_one', 'locked': false},
    ]);
    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await _editFromTree(tester, 'Pattern 1'); // P2: a tap selects; Edit is the bar's
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Edit Pattern'), findsOneWidget);
    expect(_scopeTab(tester), SeedScopeTab.feature);
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-4')), findsOneWidget);

    await tester.ensureVisible(find.text('Add from Tree'));
    await tester.tap(find.text('Add from Tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Select source Features - 1 selected'), findsOneWidget, reason: 'the picker starts from the scope');
    await tester.tap(find.byTooltip('Confirm Feature selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-4')), findsOneWidget);
    expect(backend.lastPatternPatchBody?['tool_feature_ids'], ['feature-4']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing a saved body pattern opens on the Body tab (bug report 2026-11-17 item 2B)', (tester) async {
    await _pumpScopeScreen(tester, seedFeatures: [
      ..._bossAndCut,
      {'type': 'pattern', 'id': 'feature-5', 'source_body_ids': ['feature-2'], 'source_feature_ids': <String>[], 'pattern_type': 'rectangular',
       'direction_1': {'edge_ref': null, 'sketch_line_ref': null, 'fixed_axis': 'x'}, 'count_1': 3, 'spacing_1': 10.0, 'reverse_1': false,
       'direction_2': null, 'count_2': 1, 'spacing_2': 0.0, 'reverse_2': false, 'axis': null, 'count_angular': 1, 'angle_total': 360.0,
       'reverse_angular': false, 'skip_indices': [], 'locked': false},
    ]);
    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await _editFromTree(tester, 'Pattern 1'); // P2: a tap selects; Edit is the bar's
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(_scopeTab(tester), SeedScopeTab.body);
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-2')), findsOneWidget);
    expect(find.text('Add from Tree'), findsNothing);
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
    await _editFromTree(tester, 'Pattern 1'); // P2: a tap selects; Edit is the bar's
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
    await _editFromTree(tester, 'Spring 1'); // P2: a tap selects; Edit is the bar's
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
    await _editFromTree(tester, 'Helix 1'); // P2: a tap selects; Edit is the bar's
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

  // Flutter-testing feedback 2026-11-11, item 3: Helix and Intersection are two forms, not a toggle.
  Map<String, dynamic> sk(String id) => {'type': 'sketch', 'id': id, 'sketch_id': 's-$id', 'locked': false};

  Future<void> pumpPart(WidgetTester tester, _FakeDocumentBackend backend) async {
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
  }

  testWidgets('item 3: the Intersection Curve entry opens the intersection form (no toggle) and Confirm creates an intersection curve',
      (tester) async {
    final backend = _FakeDocumentBackend(seedFeatures: [sk('sk-a'), sk('sk-b')]);
    await pumpPart(tester, backend);
    await tapStartCommand(tester, 'Intersection Curve');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Create Intersection Curve'), findsOneWidget);
    expect(find.text('Sketch A'), findsOneWidget);
    expect(find.byKey(const ValueKey('helix-diameter-field')), findsNothing, reason: 'opens on the intersection form, not the Helix one');
    expect(find.byType(SegmentedButton<CurveMode>), findsNothing, reason: 'no Helix / Intersection toggle');

    Future<void> pick(String label, String option) async {
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(option).last);
      await tester.pump(const Duration(milliseconds: 300));
    }

    await pick('Sketch A', 'Sketch 1');
    await pick('Sketch B', 'Sketch 2');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await _pumpUntil(tester, () => backend.curveCreateBodies.isNotEmpty);
    expect(backend.curveCreateBodies.single['curve_type'], 'intersection');
    expect(backend.curveCreateBodies.single['sketch_feature_id_a'], 'sk-a');
    expect(backend.curveCreateBodies.single['sketch_feature_id_b'], 'sk-b');
  });

  testWidgets('item 3: the Helix entry opens the Helix form and Confirm creates a helix', (tester) async {
    final backend = _FakeDocumentBackend();
    await pumpPart(tester, backend);
    await tapStartCommand(tester, 'Helix');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Create Helix'), findsOneWidget);
    expect(find.byType(SegmentedButton<CurveMode>), findsNothing);
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await _pumpUntil(tester, () => backend.curveCreateBodies.isNotEmpty);
    expect(backend.curveCreateBodies.single['curve_type'], 'helix');
  });

  testWidgets('item 3: Edit on an Intersection curve opens on its two Sketches and PATCHes the new ids, clearing that side\'s profile refs',
      (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        sk('sk-a'),
        sk('sk-b'),
        sk('sk-c'),
        {
          'type': 'curve',
          'id': 'curve-x',
          'curve_type': 'intersection',
          'sketch_feature_id_a': 'sk-a',
          'sketch_feature_id_b': 'sk-b',
          'profile_refs_a': <dynamic>[],
          'profile_refs_b': <dynamic>[],
          'locked': false,
        },
        sk('sk-late'), // after the curve: must not be offered
      ],
    );
    await pumpPart(tester, backend);
    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await _editFromTree(tester, 'Intersection Curve 1'); // P2: a tap selects; Edit is the bar's
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Edit Intersection Curve'), findsOneWidget);
    expect(find.text('Sketch 1'), findsWidgets, reason: 'Sketch A opens on the stored Sketch');
    expect(find.text('Sketch 2'), findsWidgets);

    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>).first);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.descendant(of: find.byType(DropdownMenuItem<String>), matching: find.text('Sketch 4')), findsNothing,
        reason: 'a Sketch after the curve is not offered');
    await tester.tap(find.descendant(of: find.byType(DropdownMenuItem<String>), matching: find.text('Sketch 3')).last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await _pumpUntil(tester, () => backend.curvePatchBodies.isNotEmpty);
    final patch = backend.curvePatchBodies.single;
    expect(patch['sketch_feature_id_a'], 'sk-c');
    expect(patch['sketch_feature_id_b'], 'sk-b');
    expect(patch['profile_refs_a'], isEmpty, reason: 're-picking a Sketch clears its profile refs');
    expect(patch.containsKey('profile_refs_b'), isFalse);
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
    await _editFromTree(tester, 'Fillet 1'); // P2: a tap selects; Edit is the bar's
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
    await _editFromTree(tester, 'Chamfer 1'); // P2: a tap selects; Edit is the bar's
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

  testWidgets('Mirror "Add from Tree" with a cut mirrors it as a tool into its body (bug report 2026-11-17 item M.2: it was sent '
      'as a source feature, whose bodies a cut has none of)', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true},
        {'type': 'extrude', 'id': 'feature-2', 'sketch_feature_id': 'feature-1', 'extrude_type': 'boss', 'start_distance': 0.0,
         'end_distance': 10.0, 'locked': true},
        {'type': 'sketch', 'id': 'feature-3', 'sketch_id': 'sketch-1', 'locked': true},
        {'type': 'extrude', 'id': 'feature-4', 'sketch_feature_id': 'feature-3', 'extrude_type': 'cut', 'start_distance': 0.0,
         'end_distance': 10.0, 'target_body_ids': ['feature-2'], 'locked': false},
      ],
    );
    final sketchBackend = _FakeSketchBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    // Mirror started from the boss (a body-making feature): its bodies are the scope.
    await tester.tap(find.byTooltip('Feature tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.longPress(find.text('Extrude 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Mirror'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(MirrorPanel), findsOneWidget);
    expect(tester.widget<MirrorPanel>(find.byType(MirrorPanel)).toolFeatureSummary, isNull);

    // Add from Tree: swap the boss for the cut.
    await tester.ensureVisible(find.text('Add from Tree'));
    await tester.tap(find.text('Add from Tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Select source Features - 1 selected'), findsOneWidget);
    await tester.tap(find.text('Extrude 1'));
    await tester.pump();
    await tester.tap(find.text('Extrude 2'));
    await tester.pump();
    await tester.tap(find.byTooltip('Confirm Feature selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final panel = tester.widget<MirrorPanel>(find.byType(MirrorPanel));
    expect(panel.toolFeatureSummary, 'Extrude 2');
    expect(find.byKey(const ValueKey('mirror-scope-chip-feature-4')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600)); // the preview debounce (no plane yet, so nothing is sent)
    expect(tester.takeException(), isNull);
  });

  testWidgets('the long press on a cut opens the same Pattern tool, Feature tab, with the cut in scope (bug report 2026-11-17 item 2B)',
      (tester) async {
    await _pumpScopeScreen(tester);
    await _openFromLongPress(tester, 'Extrude 2', 'Pattern');
    expect(find.byType(PatternPanel), findsOneWidget);
    expect(find.byType(PickerRibbon), findsNothing);
    expect(_scopeTab(tester), SeedScopeTab.feature);
    expect(find.byKey(const ValueKey('pattern-scope-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-4')), findsOneWidget);
    expect(find.textContaining('Patterning Extrude 2 into its own target'), findsOneWidget);
    expect(find.text('Pattern Body'), findsNothing);

    // The Body tab has its own (empty) scope; coming back keeps the Feature tab's.
    await tester.ensureVisible(find.byKey(const ValueKey('pattern-tab-body')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pattern-tab-body')));
    await tester.pump();
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-4')), findsNothing);
    expect(find.text('Pick faces'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('pattern-tab-feature')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pattern-tab-feature')));
    await tester.pump();
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-4')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the long press on a cut opens the same Mirror tool, Feature tab, with the cut in scope (bug report 2026-11-17 item M.3)',
      (tester) async {
    await _pumpScopeScreen(tester);
    await _openFromLongPress(tester, 'Extrude 2', 'Mirror');
    expect(find.byType(MirrorPanel), findsOneWidget);
    expect(_scopeTab(tester), SeedScopeTab.feature);
    expect(find.byKey(const ValueKey('mirror-scope-chip-feature-4')), findsOneWidget);
    expect(find.textContaining('Mirroring Extrude 2 into its own target'), findsOneWidget);
    expect(find.text('Mirror Body'), findsNothing);
    expect(tester.widget<MirrorPanel>(find.byType(MirrorPanel)).planeActive, isFalse, reason: 'the scope field is active on opening');
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull, reason: 'no plane yet');
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the long press on a body-making boss puts it in the Feature tab\'s scope, copied (not a tool)', (tester) async {
    await _pumpScopeScreen(tester);
    await _openFromLongPress(tester, 'Extrude 1', 'Pattern');
    expect(find.byType(PatternPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-2')), findsOneWidget);
    expect(find.textContaining('into its own target'), findsNothing);
    expect(find.byType(SegmentedButton<MergeMode>), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'desktop layout: Pattern "Add from Tree" shows the Build Tree in the left pane to pick from '
      '(it used to stay replaced by the tool, so there was nothing to pick)', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backend = _FakeDocumentBackend(seedFeatures: [for (final f in _bossAndCut) Map<String, dynamic>.from(f)]);
    final sketchBackend = _FakeSketchBackend();
    final layout =
        LayoutModeController(preference: LayoutPreference.desktop, windowSize: const Size(1280, 800), mouseActive: true);
    await tester.pumpWidget(
      MaterialApp(
        home: LayoutModeScope(
          controller: layout,
          child: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('ribbon-Pattern')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.ensureVisible(find.text('Add from Tree'));
    await tester.tap(find.text('Add from Tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Select source Features'), findsOneWidget);
    await tester.tap(find.text('Extrude 2'));
    await tester.pump();
    expect(find.text('Select source Features - 1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Confirm Feature selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-4')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Start > Pattern opens the panel at once: Feature tab, scope field active, no picking ribbon (bug report 2026-11-17 item 2B)',
      (tester) async {
    await _pumpScopeScreen(tester);
    await tapStartCommand(tester, 'Pattern');
    expect(find.byType(PatternPanel), findsOneWidget);
    expect(find.byType(PickerRibbon), findsNothing);
    expect(_scopeTab(tester), SeedScopeTab.feature);
    expect(find.text('Pick faces'), findsOneWidget);
    // The same keys as the long press opens (one tool, whichever way in).
    expect(find.byKey(const ValueKey('pattern-tab-feature')), findsOneWidget);
    expect(find.byKey(const ValueKey('pattern-scope-field')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pattern, Feature tab: tapping a hole wall asks which feature made it and patterns the cut as a tool', (tester) async {
    final backend = await _pumpScopeScreen(tester);
    backend.faceOwners['feature-2:5'] = 'feature-4';
    await tapStartCommand(tester, 'Pattern');
    await _tapFace(tester, 'feature-2', 5);
    expect(backend.faceOwnerRequests, 1);
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-4')), findsOneWidget);
    await tester.ensureVisible(find.text('X').first);
    await tester.tap(find.text('X').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(_lastCreate(backend, 'pattern')?['tool_feature_ids'], ['feature-4']);
    expect(_lastCreate(backend, 'pattern')?['source_body_ids'], isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pattern, Body tab: a tapped face puts its body in scope (no request); tabs keep their own scopes', (tester) async {
    final backend = await _pumpScopeScreen(tester);
    backend.faceOwners['feature-2:5'] = 'feature-4';
    await tapStartCommand(tester, 'Pattern');
    await _tapFace(tester, 'feature-2', 5); // Feature tab: the cut
    await tester.ensureVisible(find.byKey(const ValueKey('pattern-tab-body')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pattern-tab-body')));
    await tester.pump();
    await _tapFace(tester, 'feature-2', 5); // Body tab: the body
    expect(backend.faceOwnerRequests, 1, reason: 'no request on the Body tab');
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-2')), findsOneWidget);
    await tester.ensureVisible(find.text('X').first);
    await tester.tap(find.text('X').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(_lastCreate(backend, 'pattern')?['source_body_ids'], ['feature-2']);
    expect(_lastCreate(backend, 'pattern')?.containsKey('tool_feature_ids'), isFalse);
    await tester.ensureVisible(find.byKey(const ValueKey('pattern-tab-feature')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pattern-tab-feature')));
    await tester.pump();
    expect(find.byKey(const ValueKey('pattern-scope-chip-feature-4')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pattern: a cut and a body-making feature together show the message and disable Confirm; removing one clears it',
      (tester) async {
    final backend = await _pumpScopeScreen(tester);
    backend.faceOwners['feature-2:5'] = 'feature-4';
    backend.faceOwners['feature-2:0'] = 'feature-2';
    await tapStartCommand(tester, 'Pattern');
    await _tapFace(tester, 'feature-2', 5);
    await _tapFace(tester, 'feature-2', 0);
    expect(find.byKey(const ValueKey('pattern-scope-error')), findsOneWidget);
    await tester.ensureVisible(find.text('X').first);
    await tester.tap(find.text('X').first);
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
    await _tapFace(tester, 'feature-2', 0); // the same face again removes the boss
    expect(find.byKey(const ValueKey('pattern-scope-error')), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Start > Mirror opens on the Feature tab with the scope active; a face then the plane: the plane field takes the face as '
      'the plane, not the scope (bug report 2026-11-17 item M.3)', (tester) async {
    final backend = await _pumpScopeScreen(tester);
    backend.faceOwners['feature-2:5'] = 'feature-4';
    await tapStartCommand(tester, 'Mirror');
    expect(find.byType(MirrorPanel), findsOneWidget);
    expect(find.byType(PickerRibbon), findsNothing);
    expect(_scopeTab(tester), SeedScopeTab.feature);
    expect(find.byKey(const ValueKey('mirror-scope-field')), findsOneWidget);
    await _tapFace(tester, 'feature-2', 5);
    expect(find.byKey(const ValueKey('mirror-scope-chip-feature-4')), findsOneWidget);
    expect(tester.widget<MirrorPanel>(find.byType(MirrorPanel)).planeActive, isFalse, reason: 'no jump to the plane after a pick');

    await tester.ensureVisible(find.byKey(const ValueKey('mirror-plane-field')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mirror-plane-field')));
    await tester.pump();
    await _tapFace(tester, 'feature-2', 2);
    expect(backend.faceOwnerRequests, 1, reason: 'a plane pick is not a scope pick');
    expect(tester.widget<MirrorPanel>(find.byType(MirrorPanel)).hasPlanePicked, isTrue);
    expect(find.byKey(const ValueKey('mirror-scope-chip-feature-4')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    expect(_lastCreate(backend, 'mirror')?['tool_feature_ids'], ['feature-4']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mirror, Body tab: a face puts its body in scope and the request carries source_body_ids', (tester) async {
    final backend = await _pumpScopeScreen(tester);
    await tapStartCommand(tester, 'Mirror');
    await tester.ensureVisible(find.byKey(const ValueKey('mirror-tab-body')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mirror-tab-body')));
    await tester.pump();
    await _tapFace(tester, 'feature-2', 5);
    expect(find.byKey(const ValueKey('mirror-scope-chip-feature-2')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('mirror-plane-field')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mirror-plane-field')));
    await tester.pump();
    await _tapFace(tester, 'feature-2', 2);
    await tester.pump(const Duration(milliseconds: 700));
    expect(_lastCreate(backend, 'mirror')?['source_body_ids'], ['feature-2']);
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

    await _editFromTree(tester, 'Pattern 1'); // P2: a tap selects; Edit is the bar's
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
    await _editFromTree(tester, 'Pattern 1'); // P2: a tap selects; Edit is the bar's
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

    await _editFromTree(tester, 'Pattern 1'); // P2: a tap selects; Edit is the bar's
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

    await _editFromTree(tester, 'Pattern 1'); // P2: a tap selects; Edit is the bar's
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

    await _editFromTree(tester, 'Sketch 2'); // P2: a tap selects; Edit is the bar's
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

    expect(find.byKey(const ValueKey('tree-eye-off:#feature:feature-1')), findsNothing);

    await tester.longPress(find.text('Sketch 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // Feature 1 (tree multi-select): long-press now enters multi-select;
    // the row's own context menu is behind the action bar's "More".
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Not yet hidden - the context menu's toggle entry must offer "Hide".
    expect(find.widgetWithText(ListTile, 'Hide'), findsOneWidget);
    expect(find.text('Show'), findsNothing);

    await tester.tap(find.widgetWithText(ListTile, 'Hide'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Hidden now - the tree row shows the eye-slash trailing icon.
    expect(find.byKey(const ValueKey('tree-eye-off:#feature:feature-1')), findsOneWidget);
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
    expect(find.widgetWithText(ListTile, 'Show'), findsOneWidget);
    expect(find.text('Hide'), findsNothing);

    await tester.tap(find.widgetWithText(ListTile, 'Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const ValueKey('tree-eye-off:#feature:feature-1')), findsNothing);
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
    await tester.tap(find.widgetWithText(ListTile, 'Hide'));
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

  // Item 5 (thin Revolve of an open profile): a Sketch with no closed profile but one open chain is not refused by Revolve.
  testWidgets('item 5: Revolve on an open-chain Sketch is enabled (Extrude stays disabled) and opens the panel with Thin locked on', (tester) async {
    final backend = _FakeDocumentBackend(
      seedFeatures: [
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false},
      ],
    );
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    final sketchBackend = _FakeSketchBackend(profileStatus: 'no_loop', openChain: true);
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
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Extrude')).enabled, isFalse);
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Revolve')).enabled, isTrue);
    await tester.tap(find.widgetWithText(ListTile, 'Revolve'));
    await _pumpUntil(tester, () => find.text('An open profile revolves as a thin wall').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('An open profile revolves as a thin wall'), findsOneWidget);
    expect(find.text('Away from axis'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // the panel's debounced preview timer (no axis picked: it does nothing)
  });

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

      // P2: the picker is a rule of the tree's model: an ineligible sketch is locked and the banner says why (it was a SnackBar).
      expect(find.byKey(const ValueKey('tree-picker-reason')), findsOneWidget);
      expect(find.text('Pick a sketch with a closed profile'), findsOneWidget);
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

      // P2: a tap on Sketch 1 selects it (no Sketch screen opens): the selection is what the Add menu's Extrude reads.
      await _tapTreeRow(tester, 'Sketch 1');
      expect(find.text('DIDSA-CAD Sketch'), findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

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
        expect(find.byKey(const ValueKey('tree-eye-off:#feature:feature-1')), findsOneWidget);

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

        expect(find.byKey(const ValueKey('tree-eye-off:#feature:feature-1')), findsNothing);
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

      // B5: the banner is dismissible.
      await tester.tap(find.byKey(const ValueKey('error-banner-dismiss')));
      await tester.pump();
      expect(find.textContaining('derived pattern instance'), findsNothing);
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
        // P2: the tree is built in both lenses (a part's own tree is there before the answer): wait for the answer's component.
        await _pumpUntil(tester, () => _TreeProbe(tester).model.tree?.children.isNotEmpty ?? false);

        expect(find.byType(AssemblyTreeView), findsOneWidget);
        final panel = _TreeProbe(tester);
        expect(panel.occurrences.single.id, 'occ-1');
      },
    );

    SelectionEntityRef mateFace(String occ, int id) =>
        SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'body-$occ', occurrenceId: occ, id: id);

    Future<void> pickTwoFaces(WidgetTester tester) async {
      final toggle = tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!;
      toggle(mateFace('occ-1', 1));
      await tester.pump();
      toggle(mateFace('occ-2', 1));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('M1: Next creates the mate and keeps the tool open (type kept, picks cleared); OK creates and closes',
        (tester) async {
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      await tapStartCommand(tester, 'Mate');
      expect(find.byType(MatePanel), findsOneWidget);
      expect(find.text('Cancel'), findsWidgets);

      tester.widget<MatePanel>(find.byType(MatePanel)).onMateTypeChanged('parallel');
      await tester.pump();
      await pickTwoFaces(tester);
      final next = tester.widget<MatePanel>(find.byType(MatePanel)).onNext;
      expect(next, isNotNull);
      next!();
      await _pumpUntil(tester, () => backend.mates.length == 1);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(MatePanel), findsOneWidget, reason: 'Next keeps the tool open');
      expect(find.byType(ModalBarrier).evaluate().length, lessThanOrEqualTo(1));
      var panel = tester.widget<MatePanel>(find.byType(MatePanel));
      expect(panel.mateType, 'parallel', reason: 'the type is kept');
      expect(panel.selectedEntities, isEmpty, reason: 'the picks are cleared');
      expect(panel.addedCount, 1);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('1 mate added'), findsOneWidget);

      await pickTwoFaces(tester);
      tester.widget<MatePanel>(find.byType(MatePanel)).onConfirm!();
      await _pumpUntil(tester, () => backend.mates.length == 2);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MatePanel), findsNothing, reason: 'OK closes the tool');
    });

    // M3: the glide preview. The fake answers the preview with occ-2 moved 30 mm along x.
    Map<String, dynamic> previewMoving(double x) => {
          'converged': true,
          'transform': {'translation': [x, 0.0, 0.0], 'rotation_axis': [0.0, 0.0, 1.0], 'rotation_angle_degrees': 0.0},
          'members': [
            {
              'occurrence_id': 'occ-2',
              'transform': {'translation': [x, 0.0, 0.0], 'rotation_axis': [0.0, 0.0, 1.0], 'rotation_angle_degrees': 0.0},
            },
          ],
        };

    double shownX(WidgetTester tester, String id) => tester
        .widget<PartViewport>(find.byType(PartViewport))
        .assemblyInstances
        .firstWhere((i) => i.occurrencePath.last == id)
        .worldTransform
        .translation[0];

    Future<_FakeDocumentBackend> openForPreview(WidgetTester tester, {required bool glide}) async {
      SharedPreferences.setMockInitialValues({ControlsPreferences.matePreviewGlidePrefKey: glide});
      await ControlsPreferences.load();
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      backend.previewMateSolveAnswer = previewMoving(30);
      await tapStartCommand(tester, 'Mate');
      await pickTwoFaces(tester);
      await _pumpUntil(tester, () => backend.previewMateSolveCount > 0);
      await tester.pump(const Duration(milliseconds: 600)); // the glide (0.25 s) is over
      return backend;
    }

    testWidgets('M3: the preview glides the REAL part to the solved pose, leaves an outline at its stored pose, stores nothing; Cancel glides it back', (tester) async {
      final backend = await openForPreview(tester, glide: true);
      expect(shownX(tester, 'occ-2'), closeTo(30, 1e-6), reason: 'the part itself moved');
      expect(shownX(tester, 'occ-1'), 0, reason: 'the part not in the answer did not');
      final outline = tester.widget<PartViewport>(find.byType(PartViewport)).matePreviewMembers;
      expect(outline.length, 1);
      expect(outline.single.previous.translation[0], 0, reason: 'the outline is at the stored pose');
      expect(outline.single.next.translation[0], 0);
      expect(((backend.occurrences.firstWhere((o) => o['id'] == 'occ-2')['transform'] as Map)['translation'] as List)[0], 0.0, reason: 'a preview stores nothing');
      tester.widget<MatePanel>(find.byType(MatePanel)).onCancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(shownX(tester, 'occ-2'), closeTo(0, 1e-6), reason: 'Cancel glides it home');
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).matePreviewMembers, isEmpty);
    });

    testWidgets('M3: Confirm keeps the part where the preview put it (nothing jumps back) and the outline goes', (tester) async {
      final backend = await openForPreview(tester, glide: true);
      tester.widget<MatePanel>(find.byType(MatePanel)).onConfirm!();
      await _pumpUntil(tester, () => backend.mates.length == 1);
      await tester.pump(const Duration(milliseconds: 600));
      expect(shownX(tester, 'occ-2'), closeTo(30, 1e-6));
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).matePreviewMembers, isEmpty);
      expect(((backend.occurrences.firstWhere((o) => o['id'] == 'occ-2')['transform'] as Map)['translation'] as List)[0], 30.0, reason: 'the backend stored it');
    });

    testWidgets('M3: a failed Confirm glides the part back (the mate was refused, so the part must not stay moved)', (tester) async {
      final backend = await openForPreview(tester, glide: true);
      backend.failMateCreate = true;
      tester.widget<MatePanel>(find.byType(MatePanel)).onConfirm!();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 600));
      expect(backend.mates, isEmpty);
      expect(shownX(tester, 'occ-2'), closeTo(30, 1e-6), reason: 'the preview is still showing (nothing was committed), Cancel would put it back');
      tester.widget<MatePanel>(find.byType(MatePanel)).onCancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(shownX(tester, 'occ-2'), closeTo(0, 1e-6));
    });

    testWidgets('M3: with "Mate preview: move the part" off the old ghost shows at the solved pose and the part stays at its stored pose', (tester) async {
      await openForPreview(tester, glide: false);
      expect(shownX(tester, 'occ-2'), 0, reason: 'the real part does not move');
      final ghost = tester.widget<PartViewport>(find.byType(PartViewport)).matePreviewMembers;
      expect(ghost.single.next.translation[0], 30);
      expect(ghost.single.previous.translation[0], 0);
      SharedPreferences.setMockInitialValues({});
      await ControlsPreferences.load();
    });

    testWidgets('M3: a preview that does not converge moves nothing', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ControlsPreferences.load();
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      backend.previewMateSolveAnswer = {'converged': false, 'transform': null, 'members': <dynamic>[]};
      await tapStartCommand(tester, 'Mate');
      await pickTwoFaces(tester);
      await _pumpUntil(tester, () => backend.previewMateSolveCount > 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(shownX(tester, 'occ-2'), 0);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).matePreviewMembers, isEmpty);
    });

    Future<void> openSelectOther(WidgetTester tester) async {
      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectOtherRequested!(
        [
          HoverHit(entity: mateFace('occ-1', 1), rayT: 1),
          HoverHit(entity: mateFace('occ-2', 2), rayT: 2),
        ],
        const Offset(200, 200),
      );
      await tester.pump();
    }

    testWidgets('S1: Select Other is non-modal (no new barrier), a viewport tap closes it without selecting, Esc closes it',
        (tester) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      final barriersBefore = find.byType(ModalBarrier).evaluate().length;
      await openSelectOther(tester);
      expect(find.byKey(const ValueKey('select-other-panel')), findsOneWidget);
      expect(find.byType(ModalBarrier).evaluate().length, barriersBefore, reason: 'no new barrier');
      expect(find.byType(PartViewport).hitTestable(), findsOneWidget, reason: 'the viewport still receives pointers');
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).suppressHoverFallback, isTrue);

      // A viewport tap (entity hit) closes it and is not a pick.
      final before = tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities;
      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(mateFace('occ-1', 9));
      await tester.pump();
      expect(find.byKey(const ValueKey('select-other-panel')), findsNothing);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities, before);

      // An empty-space tap closes it too, leaving the selection alone.
      await openSelectOther(tester);
      tester.widget<PartViewport>(find.byType(PartViewport)).onClearSelection!();
      await tester.pump();
      expect(find.byKey(const ValueKey('select-other-panel')), findsNothing);

      // Esc closes it.
      await openSelectOther(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('select-other-panel')), findsNothing);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).highlightOverride, isNull);
    });

    testWidgets('S1: a row pick selects and closes; a row preview feeds highlightOverride and close clears it', (tester) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      await openSelectOther(tester);
      final gesture = await tester.startGesture(tester.getCenter(find.text('Face #2')));
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).highlightOverride, mateFace('occ-2', 2));
      await gesture.up();
      await tester.pump();
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).highlightOverride, isNull);

      await tester.tap(find.text('Face #1'));
      await tester.pump();
      expect(find.byKey(const ValueKey('select-other-panel')), findsNothing);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities, contains(mateFace('occ-1', 1)));
    });

    testWidgets('S1: while Select Other is open the viewport is told a tap only dismisses it', (tester) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).tapDismissesOverlay, isFalse);
      await openSelectOther(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).tapDismissesOverlay, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).tapDismissesOverlay, isFalse);
    });

    testWidgets('S1: a second Select Other gesture while open replaces the list and leaves the selection alone', (tester) async {
      // With `tapDismissesOverlay` the viewport turns the gesture's first click into `onClearSelection` (no toggle to
      // undo), then the hold requests the new list. Before the fix the click toggled, the screen swallowed that as a
      // dismiss, and the hold's "undo" toggle then really selected the entity.
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      await openSelectOther(tester);
      final before = tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities;
      tester.widget<PartViewport>(find.byType(PartViewport)).onClearSelection!();
      await tester.pump();
      await openSelectOther(tester);
      expect(find.byKey(const ValueKey('select-other-panel')), findsOneWidget, reason: 'the new list is open');
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities, before);
    });

    testWidgets('S1: opening a tool closes Select Other', (tester) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      await openSelectOther(tester);
      await tapStartCommand(tester, 'Mate');
      expect(find.byKey(const ValueKey('select-other-panel')), findsNothing);
    });

    testWidgets('M1: a Next whose create fails keeps the picks and shows the error', (tester) async {
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')]);
      backend.failMateCreate = true;
      await tapStartCommand(tester, 'Mate');
      await pickTwoFaces(tester);
      tester.widget<MatePanel>(find.byType(MatePanel)).onNext!();
      await _pumpUntil(tester, () => find.textContaining('No placement satisfies').evaluate().isNotEmpty);
      final panel = tester.widget<MatePanel>(find.byType(MatePanel));
      expect(panel.selectedEntities.length, 2, reason: 'the picks are kept');
      expect(panel.addedCount, 0);
      expect(backend.mates, isEmpty);
    });

    testWidgets('B7: Pattern Component opens with nothing selected, on the Direction step, without an error banner', (
      tester,
    ) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1')]);
      await tapStartCommand(tester, 'Pattern');

      expect(find.byType(ComponentPatternPanel), findsOneWidget);
      expect(find.text('Select a component first to pattern it'), findsNothing);
      final panel = tester.widget<ComponentPatternPanel>(find.byType(ComponentPatternPanel));
      expect(panel.sourceOccurrenceNames, isEmpty);
      expect(panel.pickingDirectionSlot, 1);
      expect(panel.confirmDisabledReason, 'Choose a direction first');
      expect(find.textContaining('pick an edge'), findsOneWidget);

      // Choosing a preset direction advances to the Components step.
      panel.onDirectionChanged(ComponentPatternAxisPreset.z);
      await tester.pump();
      final after = tester.widget<ComponentPatternPanel>(find.byType(ComponentPatternPanel));
      expect(after.pickingMoreSources, isTrue);
      expect(after.confirmDisabledReason, 'Pick at least one component');
    });

    testWidgets('B6: in the Components step a viewport component tap toggles a source; a copy tap shows an inline hint',
        (tester) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1')]);
      await tapStartCommand(tester, 'Pattern');
      tester.widget<ComponentPatternPanel>(find.byType(ComponentPatternPanel)).onDirectionChanged(
            ComponentPatternAxisPreset.z,
          );
      await tester.pump();

      void tap(String id) => tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
            SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: id),
          );
      tap('occ-1');
      await tester.pump();
      var panel = tester.widget<ComponentPatternPanel>(find.byType(ComponentPatternPanel));
      expect(panel.sourceOccurrenceNames.length, 1);
      expect(panel.confirmDisabledReason, isNull);
      tap('occ-1');
      await tester.pump();
      panel = tester.widget<ComponentPatternPanel>(find.byType(ComponentPatternPanel));
      expect(panel.sourceOccurrenceNames, isEmpty);

      tap('occ-1#pattern:pat-1:1');
      await tester.pump();
      expect(find.byKey(const ValueKey('component-pattern-inline-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('error-banner-dismiss')), findsNothing, reason: 'not the global banner');
    });

    testWidgets('item 7 (A4): the tree reads constraint status with assembly-tree?status=true, after the structure', (
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

      // The structure first (no status), then the status in the background; each part of the answer lands in the rows.
      expect(backend.assemblyTreeRequests.map((r) => r['status']), [null, 'true']);
      final panel = _TreeProbe(tester);
      expect(panel.constraintStatusByOccurrenceId['occ-1']?.state, ConstraintState.underConstrained);
      expect(panel.constraintStatusByOccurrenceId['occ-1']?.dof, 3);
    });

    testWidgets('item 4: multi-select shows the action bar in the tree header, with no bottom sheet over the tree', (
      tester,
    ) async {
      await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1')]);

      final panel = _TreeProbe(tester);
      await panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final inPanel = find.descendant(of: find.byType(AssemblyTreeView), matching: find.byType(MultiSelectActionBar));
      expect(inPanel, findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('Hide PATCHes hidden:true and the tree reflects it after refetch', (tester) async {
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1')]);

      final panel = _TreeProbe(tester);
      expect(panel.occurrences.single.hidden, isFalse);
      await panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.widgetWithText(ListTile, 'Hide'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences.single['hidden'], isTrue);
      final refreshed = _TreeProbe(tester);
      expect(refreshed.occurrences.single.hidden, isTrue);
    });

    testWidgets('Show PATCHes hidden:false, truly clearing a backend-hidden Occurrence', (tester) async {
      // Appendix item 1's remaining manual-UI half: unlike the old
      // client-only overlay (which could only ever OR onto a backend-true
      // `hidden`, never clear it - `docs/assembly-scope.md` §5 item 1), this
      // seeds the Occurrence already hidden *from the backend* and confirms
      // Show genuinely un-hides it, not just this session's own view of it.
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1', hidden: true)]);

      final panel = _TreeProbe(tester);
      expect(panel.occurrences.single.hidden, isTrue);
      await panel.onOccurrenceLongPress(panel.occurrences.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.widgetWithText(ListTile, 'Show'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'Show'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.occurrences.single['hidden'], isFalse);
      final refreshed = _TreeProbe(tester);
      expect(refreshed.occurrences.single.hidden, isFalse);
    });

    testWidgets('Isolate hides every other top-level Occurrence and shows this one', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')],
      );

      final panel = _TreeProbe(tester);
      final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
      await panel.onOccurrenceLongPress(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.widgetWithText(ListTile, 'Isolate'));
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

      final panel = _TreeProbe(tester);
      final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
      await panel.onOccurrenceLongPress(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Feature 1 (tree multi-select): long-press now enters multi-select;
      // the row's own context menu is behind the action bar's "More".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.widgetWithText(ListTile, 'Isolate'));
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

      final panel = _TreeProbe(tester);
      expect(panel.occurrences.single.fixed, isFalse);
      await panel.onOccurrenceLongPress(panel.occurrences.single);
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
      final refreshed = _TreeProbe(tester);
      expect(refreshed.occurrences.single.fixed, isTrue);
    });

    testWidgets('Float PATCHes fixed:false, and Move/Rotate re-enables', (tester) async {
      final backend = await openInAssemblyLens(tester, seedOccurrences: [occurrence('occ-1', fixed: true)]);

      final panel = _TreeProbe(tester);
      expect(panel.occurrences.single.fixed, isTrue);
      await panel.onOccurrenceLongPress(panel.occurrences.single);
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
      final refreshed = _TreeProbe(tester);
      expect(refreshed.occurrences.single.fixed, isFalse);

      await refreshed.onOccurrenceLongPress(refreshed.occurrences.single);
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

      final panel = _TreeProbe(tester);
      await panel.onOccurrenceLongPress(panel.occurrences.single);
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
      List<Map<String, dynamic>>? seedPatterns,
      List<Map<String, dynamic>> extraInstances = const [],
    }) async {
      final backend = _FakeDocumentBackend(
        seedOccurrences: seedOccurrences,
        seedMates: seedMates,
        seedComponentPatterns: seedPatterns,
      )
        ..extraAssemblyInstances = extraInstances
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
      final panel = _TreeProbe(tester);
      await panel.onOccurrenceLongPress(panel.occurrences.firstWhere((o) => o.id == target));
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
      // (A4: the tree's rows carry no transforms; the follower's pose is the backend's, checked just above.)
      expect(find.byTooltip('Undo move'), findsOneWidget);

      // One undo reverses the grabbed occurrence AND the follower.
      await tester.tap(find.byTooltip('Undo move'));
      await settle(tester);
      expect((backend.occurrences[0]['transform'] as Map)['translation'], [0.0, 0.0, 0.0]);
      expect((backend.occurrences[1]['transform'] as Map)['translation'], [30.0, 0.0, 0.0]);
      expect(backend.transformPatchCount, 2);
      expect(find.byTooltip('Undo move'), findsNothing, reason: 'exactly one entry was pushed');
    });

    // S2 (docs/pattern-followers-smoothness-plan.md): a dragged source's copies (and what is nested under them) move live with it.
    Map<String, dynamic> linearPattern({bool suppressed = false, List<int> skip = const []}) => {
          'id': 'pat-1',
          'source_occurrence_ids': ['occ-1'],
          'pattern_type': 'linear',
          'direction': [1.0, 0.0, 0.0],
          'count': 3,
          'spacing': 300.0,
          'reverse': false,
          'direction_2': [0.0, 1.0, 0.0],
          'count_2': 1,
          'spacing_2': 0.0,
          'reverse_2': false,
          'axis': null,
          'count_angular': 1,
          'angle_total': 360.0,
          'reverse_angular': false,
          'skip_indices': skip,
          'orient_with_rotation': true,
          'suppressed': suppressed,
        };

    Map<String, dynamic> instanceAt(List<String> path, double x, double y, double z) =>
        {'occurrence_path': path, 'part_id': 'occ-1-part', 'world_transform': tf(x, y, z), 'hidden': false};

    Future<Map<String, List<double>>> dragSourceAndRead(WidgetTester tester, {required bool suppressed, List<int> skip = const []}) async {
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 330)],
        // occ-2 is mated to the FIRST COPY of occ-1: that is a mate on occ-1 (the source), so the drag goes through mate-motion
        seedMates: [
          {
            ...mateBetween('occ-2', 'occ-1#pattern:pat-1:1'),
          },
        ],
        seedPatterns: [linearPattern(suppressed: suppressed, skip: skip)],
        extraInstances: [
          instanceAt(['occ-1#pattern:pat-1:1'], 300, 0, 0),
          instanceAt(['occ-1#pattern:pat-1:1', 'inner'], 305, 2, 0),
          instanceAt(['occ-1#pattern:pat-1:2'], 600, 0, 0),
        ],
        target: 'occ-1',
      );
      backend.mateMotionHandler = flatGroup(backend);
      var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragStart!();
      await settle(tester);
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragUpdate!(wish(4, 6, 9)); // 9 off-plane is blocked by the scripted group
      await tester.pump();
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      return {for (final i in viewport.assemblyInstances) i.occurrencePath.join('/'): i.worldTransform.translation};
    }

    testWidgets('S2: dragging a source moves its copies and what is nested under them live, and the part mated to a copy with them', (
      tester,
    ) async {
      final live = await dragSourceAndRead(tester, suppressed: false);
      expect(live['occ-1']![0], closeTo(4, 1e-3));
      expect(live['occ-1']![1], closeTo(6, 1e-3));
      expect(live['occ-1']![2], closeTo(0, 1e-6), reason: 'off-plane motion blocked');
      // copy i = step (300 i along x) after the source's live pose (4, 6, 0)
      expect(live['occ-1#pattern:pat-1:1']![0], closeTo(304, 1e-3));
      expect(live['occ-1#pattern:pat-1:1']![1], closeTo(6, 1e-3));
      expect(live['occ-1#pattern:pat-1:2']![0], closeTo(604, 1e-3));
      expect(live['occ-1#pattern:pat-1:2']![1], closeTo(6, 1e-3));
      // an instance nested under a copy moves by the same delta (4, 6, 0)
      expect(live['occ-1#pattern:pat-1:1/inner']![0], closeTo(309, 1e-3));
      expect(live['occ-1#pattern:pat-1:1/inner']![1], closeTo(8, 1e-3));
      // the part mated to the copy rides with the group (the scripted group slides it along x with the grabbed one)
      expect(live['occ-2']![0], closeTo(334, 1e-3), reason: 'the follower moved with the group, next to the live copy');
    });

    testWidgets('S2: a suppressed pattern\'s copies stay where the server drew them', (tester) async {
      final suppressed = await dragSourceAndRead(tester, suppressed: true);
      expect(suppressed['occ-1']![0], closeTo(4, 1e-3));
      expect(suppressed['occ-1#pattern:pat-1:1'], [300.0, 0.0, 0.0]);
      expect(suppressed['occ-1#pattern:pat-1:1/inner'], [305.0, 2.0, 0.0]);
      expect(suppressed['occ-1#pattern:pat-1:2'], [600.0, 0.0, 0.0]);
    });

    Future<List<RigidTransformDto>> circularPreview(WidgetTester tester, {required bool orient}) async {
      await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 200)],
        seedMates: const [],
        seedPatterns: [
          {
            ...linearPattern(),
            'pattern_type': 'circular',
            'axis': {'origin': [0.0, 0.0, 0.0], 'direction': [0.0, 0.0, 1.0]},
            'count_angular': 4,
            'angle_total': 360.0,
            'orient_with_rotation': orient,
          },
        ],
        target: 'occ-1',
      );
      final panel = _TreeProbe(tester);
      await panel.onPatternTap!(panel.patterns.single); // opens the Pattern panel on the stored pattern: its orient_with_rotation is the preview's
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      return [
        for (final p in viewport.componentPatternPreviewInstances)
          RigidTransformDto(
            translation: [p.worldTransform.storage[12], p.worldTransform.storage[13], p.worldTransform.storage[14]],
            rotationAxis: const [0, 0, 1],
            // the yaw of the copy: atan2 of the rotated x axis
            rotationAngleDegrees: math.atan2(p.worldTransform.storage[1], p.worldTransform.storage[0]) * 180 / math.pi,
          ),
      ];
    }

    testWidgets('S2: the Pattern panel\'s ghost preview turns each copy with the step when the pattern orients', (tester) async {
      final oriented = await circularPreview(tester, orient: true);
      expect(oriented, hasLength(3));
      expect(oriented[0].translation[0], closeTo(0, 1e-3)); // 200 mm out, a quarter turn about z: (0, 200)
      expect(oriented[0].translation[1], closeTo(200, 1e-3));
      expect(oriented[0].rotationAngleDegrees, closeTo(90, 1e-3), reason: 'turned with the step');
      expect(oriented[1].rotationAngleDegrees.abs(), closeTo(180, 1e-3));
    });

    testWidgets('S2: ... and keeps the source\'s rotation when orient_with_rotation is false (the old preview always turned it)', (tester) async {
      final kept = await circularPreview(tester, orient: false);
      expect(kept, hasLength(3));
      expect(kept[0].translation[0], closeTo(0, 1e-3), reason: 'repositioned around the circle the same way');
      expect(kept[0].translation[1], closeTo(200, 1e-3));
      for (final copy in kept) {
        expect(copy.rotationAngleDegrees, closeTo(0, 1e-3));
      }
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
      var panel = _TreeProbe(tester);
      await panel.onOccurrenceTap(panel.occurrences.firstWhere((o) => o.id == 'occ-1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(AssemblyComponentSelectionDrawer), findsOneWidget);

      // An empty-space tap deselects it and the drawer goes away.
      tester.widget<PartViewport>(find.byType(PartViewport)).onClearSelection!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(AssemblyComponentSelectionDrawer), findsNothing);
      panel = _TreeProbe(tester);
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
      final tree = _TreeProbe(tester);
      await tree.onOccurrenceVisibilityToggle!(tree.occurrences.firstWhere((o) => o.id == 'occ-2'));
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

    testWidgets('a source whose only mates are on its COPIES counts as mated: its gizmo drag goes through mate-motion', (tester) async {
      // occ-2 is mated to a face of a copy of occ-1 (`occ-1#pattern:pat-1:1`): the copy follows occ-1, so occ-1 is mated.
      final backend = await openWithGizmo(
        tester,
        seedOccurrences: [occ('occ-1', 0), occ('occ-2', 30)],
        seedMates: [mateBetween('occ-2', 'occ-1#pattern:pat-1:1')],
        target: 'occ-1',
      );
      backend.mateMotionHandler = flatGroup(backend);
      var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragStart!();
      await settle(tester);
      expect(backend.mateMotionRequests.length, 1, reason: 'the grab anchor: the drag is a constrained one');
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragUpdate!(wish(4, 6, 0));
      await tester.pump();
      viewport = tester.widget<PartViewport>(find.byType(PartViewport));
      viewport.onComponentGizmoDragEnd!();
      await settle(tester);
      expect(backend.transformPatchCount, 0, reason: 'never a bare transform PATCH for a source with mated copies');
      expect(backend.mateMotionRequests.where((r) => r['commit'] == true).length, 1);
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
    testWidgets('after Make Focus the tree shows the focused Part, and its Exit row walks back one level', (
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

      final panel = _TreeProbe(tester);
      final occurrence = panel.occurrences.single;

      // First long-press: unfocused, offers Make Focus - taking it pushes
      // the focus stack (this Occurrence's own `resolvedPartId` becomes the
      // new primary Part, and `AssemblyFocusStack.currentOccurrencePath`
      // records `occurrence.id`).
      await panel.onOccurrenceLongPress(occurrence);
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

      // B3: the whole tree stays and the focused component is a row in it (the focus path says which); above it the breadcrumb strip names the
      // levels, and its first crumb (the root) is the way back out.
      expect(find.byKey(const ValueKey('focus-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('focus-crumb:0')), findsOneWidget);
      expect(find.byKey(const ValueKey('focus-crumb:1')), findsOneWidget);
      expect(_TreeProbe(tester).model.focusPath, [occurrence.id]);
      expect(_TreeProbe(tester).occurrences.map((o) => o.id), [occurrence.id], reason: 'the root still lists its component');
      await _TreeProbe(tester).exitFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('focus-strip')), findsNothing);
      expect(_TreeProbe(tester).model.focusPath, isEmpty);
      expect(_TreeProbe(tester).occurrences.map((o) => o.id), [occurrence.id]);
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
      // The component menu has grown (Zoom to selection): its last rows need a taller window than 800 x 600.
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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

    testWidgets('a pattern edit that leaves mates broken flashes their rows and says so in a SnackBar', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')],
        seedMates: [mateReferencing('mate-1', 'occ-2')],
        seedComponentPatterns: [patternSourcedFrom('pattern-1', ['occ-1'])],
      );
      backend.brokenMateIdsOnPatternEdit = ['mate-1'];
      var panel = _TreeProbe(tester);
      expect(panel.mates.single.tone, isNull);
      expect(panel.flashMateIds, isEmpty);

      await panel.onPatternTap!(panel.patterns.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      tester
          .widget<ButtonStyleButton>(find.ancestor(of: find.text('Save'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)))
          .onPressed!();
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(backend.patternPatches, hasLength(1));
      panel = _TreeProbe(tester);
      expect(panel.mates.single.tone, AssemblyItemTone.error, reason: 'the refreshed tree carries the mate\'s status');
      expect(panel.flashMateIds, {'mate-1'});
      expect(panel.flashToken, 1);
      expect(find.text('Pattern updated - 1 mate could not be kept'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600)); // mid-pulse: the row's background is tinted
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining("Broken - can't be satisfied"), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // let the pulse and the SnackBar finish
    });

    testWidgets('a pattern edit that breaks nothing shows no flash and no SnackBar', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1')],
        seedComponentPatterns: [patternSourcedFrom('pattern-1', ['occ-1'])],
      );
      var panel = _TreeProbe(tester);
      await panel.onPatternTap!(panel.patterns.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      tester
          .widget<ButtonStyleButton>(find.ancestor(of: find.text('Save'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)))
          .onPressed!();
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(backend.patternPatches, hasLength(1));
      panel = _TreeProbe(tester);
      expect(panel.flashMateIds, isEmpty);
      expect(find.textContaining('could not be kept'), findsNothing);
    });

    testWidgets('a Patterns row long-press offers Edit / Dissolve / Delete; Dissolve asks first and calls the focused part once', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1')],
        seedComponentPatterns: [patternSourcedFrom('pattern-1', ['occ-1'])],
      );
      var panel = _TreeProbe(tester);
      await panel.onPatternLongPress!(panel.patterns.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Dissolve'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Dissolve'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Dissolve pattern?'), findsOneWidget);
      expect(backend.dissolveCalls, isEmpty, reason: 'asks first');
      await tester.tap(find.widgetWithText(TextButton, 'Dissolve'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));

      expect(backend.dissolveCalls, ['part-1/pattern-1'], reason: 'one call, routed through the focused part');
      panel = _TreeProbe(tester);
      expect(panel.patterns, isEmpty, reason: 'the tree was refreshed');
      expect(panel.occurrences.map((o) => o.id), containsAll(['occ-1', 'dissolved-1', 'dissolved-2']));
    });

    testWidgets('cancelling the dissolve confirmation makes no call', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1')],
        seedComponentPatterns: [patternSourcedFrom('pattern-1', ['occ-1'])],
      );
      final panel = _TreeProbe(tester);
      await panel.onPatternLongPress!(panel.patterns.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Dissolve'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(backend.dissolveCalls, isEmpty);
      expect(_TreeProbe(tester).patterns, hasLength(1));
    });

    testWidgets('Dissolve is disabled for a suppressed pattern (and makes no call when tapped)', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1')],
        seedComponentPatterns: [
          {...patternSourcedFrom('pattern-1', ['occ-1']), 'suppressed': true},
        ],
      );
      final panel = _TreeProbe(tester);
      await panel.onPatternLongPress!(panel.patterns.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final dissolve = tester.widget<ListTile>(find.ancestor(of: find.text('Dissolve'), matching: find.byType(ListTile)));
      expect(dissolve.enabled, isFalse);
      await tester.tap(find.text('Dissolve'));
      await tester.pump();
      expect(find.text('Dissolve pattern?'), findsNothing);
      expect(backend.dissolveCalls, isEmpty);
    });

    testWidgets('the warning dialog names every affected mate and pattern', (tester) async {
      final backend = await openInAssemblyLens(
        tester,
        seedOccurrences: [occurrence('occ-1'), occurrence('occ-2')],
        seedMates: [mateReferencing('mate-1', 'occ-1')],
        seedComponentPatterns: [patternSourcedFrom('pattern-1', ['occ-1'])],
      );

      final panel = _TreeProbe(tester);
      final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
      await panel.onOccurrenceLongPress(target);
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

      final panel = _TreeProbe(tester);
      final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
      await panel.onOccurrenceLongPress(target);
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

      final panel = _TreeProbe(tester);
      await panel.onOccurrenceLongPress(panel.occurrences.single);
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
      final panel = _TreeProbe(tester);
      await panel.onOccurrenceLongPress(panel.occurrences.single);
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
      // A4: the way out is the tree's own "Focused on ..." row (its Exit).
      await _TreeProbe(tester).exitFocus();
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
        final panel = _TreeProbe(tester);
        await panel.onOccurrenceLongPress(panel.occurrences.single);
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

        // A4: the way out is the tree's own "Focused on ..." row (its Exit).
        await _TreeProbe(tester).exitFocus();
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
  // Shared storage S2 (`docs/shared-storage-scope.md` sections 6 and 7): the PartScreen's side of server projects - the File menu
  // entries, Save All as one commit, the conflict dialog, the offline queue and the sync chip - against a fake store, and decision
  // S0-8's "changed on disk meanwhile?" question for a local folder. The service logic is `remote_storage_service_test.dart`.
  group('Shared storage S2: server projects in the PartScreen', () {
    late FakeProjectStore store;
    late RemoteStorageService remote;
    late ServerProjectRoot root;

    setUp(() {
      store = FakeProjectStore();
      store.createProject('Gearbox');
      remote = RemoteStorageService(
        settings: () => const StoreSettings(url: 'https://store.test', apiKey: 'store-key', deviceName: 'Desktop'),
        httpClient: store.client,
        syncStore: InMemorySyncStore(),
        fileCache: InMemoryFileCache(),
        treeTtl: Duration.zero,
      );
      root = remote.rootFor('Gearbox');
      remote.beginSession(root);
    });

    Future<_FakeDocumentBackend> pumpServerScreen(WidgetTester tester) async {
      final backend = _FakeDocumentBackend();
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: RoutingStorageService(local: _FakeStorageService(), remote: remote),
            initialProjectRoot: root,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      await switchLens(tester, 'Assembly');
      await tapStartCommand(tester, 'Create Component');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      return backend;
    }

    Future<void> tapFileMenu(WidgetTester tester, String entry) async {
      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text(entry));
      await tester.pump();
      await tester.tap(find.text(entry));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    testWidgets('one Open entry: no separate Server projects entry, and Copy to cloud storage is in the File menu', (tester) async {
      await pumpServerScreen(tester);
      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Open…'), findsOneWidget);
      expect(find.text('Server projects…'), findsNothing);
      expect(find.byKey(const ValueKey('file-server-projects')), findsNothing);
      expect(find.text('Copy this project to cloud storage…'), findsOneWidget);
    });

    testWidgets('a screen with no project store service shows neither entry', (tester) async {
      final backend = _FakeDocumentBackend();
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: _FakeStorageService(),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      expect(await _syncButtonPresent(tester), isFalse);
      await openToolbar(tester);
      await tester.tap(find.text('File'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Server projects…'), findsNothing);
      expect(find.text('Copy this project to cloud storage…'), findsNothing);
    });

    testWidgets('Save All on a server project is ONE commit, and the chip says Synced', (tester) async {
      await pumpServerScreen(tester);
      expect(await _syncButtonPresent(tester), isTrue);

      await tapFileMenu(tester, 'Save All');

      await tester.pump(const Duration(milliseconds: 600)); // the previous note leaves, then this one is shown
      expect(find.text('Saved 2 file(s)'), findsOneWidget);
      expect(store.livePaths('Gearbox'), containsAll(['Part 1.didsa', 'Component 1.didsa']));
      expect(store.count('POST /projects/Gearbox/commit'), 1);
      expect(store.count('PUT'), 0);
      expect(await _syncIcon(tester), Icons.cloud_done_outlined);
    });

    Future<void> openCloudFromMenu(WidgetTester tester) async {
      await tapFileMenu(tester, 'Open…');
      await tester.tap(find.byKey(const ValueKey('open-source-cloud')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    // The owner's sequence (13 Nov): a brand-new part, then File > Server projects into a new (empty) project: there is no file to
    // open, so the session must start saving into the project - before this, nothing was sent and no chip appeared.
    Future<void> pumpNewSession(WidgetTester tester) async {
      final backend = _FakeDocumentBackend();
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: RoutingStorageService(local: _FakeStorageService(), remote: remote),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
    }

    // Bug report 2026-11-17 item 8: Open only opens. Putting the current work into a cloud project (the owner's 13 Nov sequence: a
    // brand-new part into a new, empty project) is File > Copy this project to cloud storage… > Existing project folder.
    testWidgets('Open > Cloud storage on an empty project opens nothing and says where to go instead', (tester) async {
      await pumpNewSession(tester);
      await openCloudFromMenu(tester);
      await tester.tap(find.byKey(const ValueKey('server-project-Gearbox')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('server-project-empty')), findsOneWidget);
      expect(find.textContaining('This project has no files yet'), findsOneWidget);
      expect(await _syncButtonPresent(tester), isFalse);
    });

    testWidgets('Open > Cloud storage on a project with files goes straight to choosing a file: no "Save current work here"', (tester) async {
      store.writeJson('Gearbox', 'Existing.didsa', {'schema_version': 1, 'document': {'id': 'd', 'root_part_id': 'x', 'parts': []}});
      await pumpNewSession(tester);
      await openCloudFromMenu(tester);
      await tester.tap(find.byKey(const ValueKey('server-project-Gearbox')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('server-project-choice')), findsNothing);
      expect(find.text('Save current work here'), findsNothing);
      expect(find.text('Open Project'), findsOneWidget);
    });

    testWidgets('Copy to cloud storage > Existing project folder: the session saves into it, and Save All sends the file', (tester) async {
      await pumpNewSession(tester);
      expect(await _syncButtonPresent(tester), isFalse);

      await tapFileMenu(tester, 'Copy this project to cloud storage…');
      expect(find.byKey(const ValueKey('copy-to-cloud-target-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('copy-to-cloud-existing')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('server-project-Gearbox')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(await _syncButtonPresent(tester), isTrue);
      expect(find.textContaining('now saves into "Gearbox"'), findsOneWidget);

      await tapFileMenu(tester, 'Save All');
      expect(find.textContaining('Save "Part 1" as'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.livePaths('Gearbox'), ['Part 1.didsa'], reason: 'requests: ${store.requests}');
      expect(await _syncIcon(tester), Icons.cloud_done_outlined);
    });

    testWidgets('Copy to cloud storage > New project folder is the name prompt, as before', (tester) async {
      await pumpNewSession(tester);
      await tapFileMenu(tester, 'Copy this project to cloud storage…');
      await tester.tap(find.byKey(const ValueKey('copy-to-cloud-new')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('copy-to-server-dialog')), findsOneWidget);
    });

    testWidgets('a local-folder session shows a folder symbol (not synced), and it leads to Server projects', (tester) async {
      await pumpNewSession(tester);
      await openQuickColumn(tester);
      expect(find.byKey(const ValueKey('quick-sync-fab')), findsNothing);
      expect(find.byKey(const ValueKey('quick-local-fab')), findsOneWidget);
      expect(tester.widget<Icon>(find.descendant(of: find.byKey(const ValueKey('quick-local-fab')), matching: find.byType(Icon)).first).icon, Icons.folder_outlined);

      await tester.tap(find.byKey(const ValueKey('quick-local-fab')));
      await _settleSheet(tester);
      expect(find.byKey(const ValueKey('local-session-sheet')), findsOneWidget);
      expect(find.textContaining('Nothing is being synced'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-sheet-server-projects')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('server-projects-dialog')), findsOneWidget);
    });

    testWidgets('a screen with no project store shows no folder symbol either', (tester) async {
      final backend = _FakeDocumentBackend();
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            storageService: _FakeStorageService(),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      await openQuickColumn(tester);
      expect(find.byKey(const ValueKey('quick-local-fab')), findsNothing);
    });

    // The desktop layout has no quick menu: the same symbols sit in the top bar, next to Save.
    Future<void> pumpDesktop(WidgetTester tester, {required StorageService storage, ProjectRoot? initialRoot}) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = _FakeDocumentBackend();
      final sketchBackend = _FakeSketchBackend();
      final layout =
          LayoutModeController(preference: LayoutPreference.desktop, windowSize: const Size(1280, 800), mouseActive: true);
      await tester.pumpWidget(
        MaterialApp(
          home: LayoutModeScope(
            controller: layout,
            child: PartScreen(
              documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
              sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
              storageService: storage,
              initialProjectRoot: initialRoot,
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
    }

    testWidgets('desktop layout: a server project shows the cloud symbol in the top bar, and it opens the sync sheet', (tester) async {
      await pumpDesktop(tester, storage: RoutingStorageService(local: _FakeStorageService(), remote: remote), initialRoot: root);
      expect(find.byKey(const ValueKey('desktop-sync-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-local-button')), findsNothing);
      expect(
        tester.widget<Icon>(find.descendant(of: find.byKey(const ValueKey('desktop-sync-button')), matching: find.byType(Icon)).first).icon,
        Icons.cloud_done_outlined,
      );
      await tester.tap(find.byKey(const ValueKey('desktop-sync-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('server-sync-sheet')), findsOneWidget);
    });

    testWidgets('desktop layout: a local session with a store set up shows the folder symbol', (tester) async {
      await pumpDesktop(tester, storage: RoutingStorageService(local: _FakeStorageService(), remote: remote));
      expect(find.byKey(const ValueKey('desktop-sync-button')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-local-button')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop-local-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Nothing is being synced'), findsOneWidget);
    });

    testWidgets('desktop layout: no project store, no symbol', (tester) async {
      await pumpDesktop(tester, storage: _FakeStorageService());
      expect(find.byKey(const ValueKey('desktop-sync-button')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-local-button')), findsNothing);
    });

    testWidgets('Open with cloud storage set up asks where: this device or cloud storage', (tester) async {
      await pumpNewSession(tester);
      await tapFileMenu(tester, 'Open…');
      expect(find.byKey(const ValueKey('open-source-dialog')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-source-device')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-source-cloud')), findsOneWidget);
      expect(find.text('store.test'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('open-source-cloud')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('server-projects-dialog')), findsOneWidget);
    });

    testWidgets('plain Save on a server project sends the file to the store', (tester) async {
      await pumpServerScreen(tester);

      await tapFileMenu(tester, 'Save');
      await tester.pump(const Duration(milliseconds: 600));

      expect(store.livePaths('Gearbox'), isNotEmpty, reason: 'requests: ${store.requests}');
    });

    testWidgets('a clash on Save All writes nothing, shows who changed it, and Keep mine then lands the commit', (tester) async {
      final backend = await pumpServerScreen(tester);
      await tapFileMenu(tester, 'Save All');
      expect(store.versionOf('Gearbox', 'Part 1.didsa'), 1);

      // Another device saves Part 1; this session then renames its Part and Saves All.
      store.writeJson('Gearbox', 'Part 1.didsa', {'schema_version': 1, 'document': {'id': 'd', 'root_part_id': 'x', 'parts': []}}, device: 'Quest 3');
      backend.partOneName = 'Edited here';
      await tapFileMenu(tester, 'Save All');

      expect(find.byKey(const ValueKey('sync-conflict-dialog')), findsOneWidget);
      expect(find.textContaining('Changed by Quest 3'), findsOneWidget);
      expect(store.versionOf('Gearbox', 'Part 1.didsa'), 2, reason: 'nothing was written');
      expect(remote.statusOf(root).value.clash, 1);

      await tester.tap(find.byKey(const ValueKey('conflict-keepMine-Part 1.didsa')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('conflict-apply')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(store.versionOf('Gearbox', 'Part 1.didsa'), 3);
      expect(jsonDecode(utf8.decode(store.bytesOf('Gearbox', 'Part 1.didsa')!))['document']['parts'][0]['name'], 'Edited here');
      expect(await _syncIcon(tester), Icons.cloud_done_outlined);
    });

    testWidgets('a first Save All that clashes still keys the rows by the root file (queued, then Keep mine)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final backend = await pumpServerScreen(tester);
      final key = 'assembly_tree_open:project:${root.persistedKey}|Part 1.didsa';
      Future<Set<String>> storedKeys() async =>
          (await tester.runAsync(() async => (await SharedPreferences.getInstance()).getKeys().where((k) => k.startsWith('assembly_tree_open:'))))!.toSet();

      // A real row (P2 review: keys of rows that do not exist are not stored): the part's own Planes folder.
      _TreeProbe(tester).model.setOpen('#planes', true);
      await tester.pump();
      expect(await storedKeys(), isEmpty, reason: 'no file yet: no key');

      // Another device wrote the file before this session's first save: the save is queued as a clash.
      store.writeJson('Gearbox', 'Part 1.didsa', {'schema_version': 1, 'document': {'id': 'd', 'root_part_id': 'x', 'parts': []}}, device: 'Quest 3');
      backend.partOneName = 'Edited here';
      await tapFileMenu(tester, 'Save All');
      expect(find.byKey(const ValueKey('sync-conflict-dialog')), findsOneWidget);
      await tester.pump();
      expect(await storedKeys(), contains(key), reason: 'the root file is in the queue: the rows are keyed by it, and the rows follow');

      await tester.tap(find.byKey(const ValueKey('conflict-keepMine-Part 1.didsa')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('conflict-apply')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      Future<String?> text() async => tester.runAsync<String?>(() async => (await SharedPreferences.getInstance()).getString(key));
      expect(await text(), contains('#planes'));
      _TreeProbe(tester).model.setOpen('#planes', false);
      await tester.pump();
      expect(await text(), '[]', reason: 'and a change after Keep mine is stored under it');
    });

    testWidgets('Decide later leaves the clash queued: nothing written, and the chip offers the dialog again', (tester) async {
      final backend = await pumpServerScreen(tester);
      await tapFileMenu(tester, 'Save All');
      store.writeJson('Gearbox', 'Part 1.didsa', {'schema_version': 1, 'document': {'id': 'd', 'root_part_id': 'x', 'parts': []}}, device: 'Quest 3');
      backend.partOneName = 'Edited here';
      await tapFileMenu(tester, 'Save All');

      await tester.tap(find.byKey(const ValueKey('conflict-later')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(store.versionOf('Gearbox', 'Part 1.didsa'), 2);
      expect(await _syncIcon(tester), Icons.warning_amber_rounded);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('Nothing was written'), findsOneWidget);
      // The note sits where the chip is: let it go, as a user would, before tapping the chip.
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await openQuickColumn(tester);
      await tester.tap(find.byKey(const ValueKey('quick-sync-fab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('sync-sheet-resolve')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('sync-conflict-dialog')), findsOneWidget);
    });

    testWidgets('Save All while the store is unreachable queues the save and says so; Sync now sends it', (tester) async {
      final backend = await pumpServerScreen(tester);
      await tapFileMenu(tester, 'Save All');
      backend.partOneName = 'Edited offline';
      store.offline = true;

      await tapFileMenu(tester, 'Save All');

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('Saved on this device'), findsOneWidget);
      expect(await _syncIcon(tester), Icons.cloud_upload_outlined);
      expect(store.versionOf('Gearbox', 'Part 1.didsa'), 1);

      store.offline = false;
      await openQuickColumn(tester);
      await tester.tap(find.byKey(const ValueKey('quick-sync-fab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('sync-sheet-sync')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(store.versionOf('Gearbox', 'Part 1.didsa'), 2);
      expect(await _syncIcon(tester), Icons.cloud_done_outlined);
    });
  });

  // Decision S0-8: Save All on a LOCAL folder no longer overwrites, silently, a file that changed on disk since this session read
  // or wrote it (DIDSA-VR's `project_save.gd` has the same check, by modified time).
  group('Shared storage S0-8: Save All on a local folder asks before overwriting a file changed on disk', () {
    Future<(_FakeDocumentBackend, _FakeStorageService)> savedOnce(WidgetTester tester) async {
      final backend = _FakeDocumentBackend();
      final storage = _FakeStorageService();
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
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
      await _fileMenuTap(tester, 'Save All');
      expect(find.text('Saved 2 file(s)'), findsOneWidget);
      // Something else (a sync client, another program) changes the file after this session wrote it.
      storage.files['Part 1.didsa'] = Uint8List.fromList(utf8.encode('{"changed":"outside"}'));
      storage.modified['Part 1.didsa'] = DateTime(2026, 6, 1);
      backend.partOneName = 'Edited here';
      return (backend, storage);
    }

    testWidgets('Skip these files writes the others and leaves the changed file as it is on disk', (tester) async {
      final (_, storage) = await savedOnce(tester);
      await _fileMenuTap(tester, 'Save All');

      expect(find.byKey(const ValueKey('changed-on-disk-dialog')), findsOneWidget);
      expect(find.text('• Part 1.didsa'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('changed-skip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(utf8.decode(storage.files['Part 1.didsa']!), '{"changed":"outside"}');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('left 1 that changed on disk'), findsOneWidget);
    });

    testWidgets('Overwrite writes everything, as Save All always did', (tester) async {
      final (_, storage) = await savedOnce(tester);
      await _fileMenuTap(tester, 'Save All');
      await tester.tap(find.byKey(const ValueKey('changed-overwrite')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(jsonDecode(utf8.decode(storage.files['Part 1.didsa']!))['document']['parts'][0]['name'], 'Edited here');
    });

    testWidgets('Cancel writes nothing at all', (tester) async {
      final (_, storage) = await savedOnce(tester);
      final writesBefore = Map.of(storage.writeCounts);
      await _fileMenuTap(tester, 'Save All');
      await tester.tap(find.byKey(const ValueKey('changed-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(storage.writeCounts, writesBefore);
      expect(utf8.decode(storage.files['Part 1.didsa']!), '{"changed":"outside"}');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('nothing was written'), findsOneWidget);
    });

    testWidgets('a file that did not change on disk is saved with no question', (tester) async {
      final backend = _FakeDocumentBackend();
      final storage = _FakeStorageService();
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
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
      await _fileMenuTap(tester, 'Save All');
      backend.partOneName = 'Edited here';
      await _fileMenuTap(tester, 'Save All');
      expect(find.byKey(const ValueKey('changed-on-disk-dialog')), findsNothing);
      expect(jsonDecode(utf8.decode(storage.files['Part 1.didsa']!))['document']['parts'][0]['name'], 'Edited here');
    });
  });

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

        final panel = _TreeProbe(tester);
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

        final panel = _TreeProbe(tester);
        await panel.onOccurrenceLongPress(panel.occurrences.single);
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

        final panel = _TreeProbe(tester);
        final target = panel.occurrences.firstWhere((o) => o.id == 'occ-1');
        await panel.onOccurrenceLongPress(target);
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

    testWidgets('the written file carries the root Part\'s client-only section planes, and no client hidden set', (tester) async {
      final storage = _FakeStorageService();
      final toolbar = await pumpFresh(tester, storage);

      toolbar().onSaveNative!();
      await settle(tester);
      await answerNamePrompt(tester, 'extras');

      final written = jsonDecode(utf8.decode(storage.files['extras.didsa']!)) as Map<String, dynamic>;
      expect(written, containsPair('section_planes', isA<List>()));
      // Hide / Show is Part state now: the backend's own export carries it (and the legacy top-level key), the client
      // stash does not.
      expect(written, isNot(contains('hidden_feature_ids')));
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

      expect(find.byType(AssemblyTreeView), findsOneWidget);
      expect(_TreeProbe(tester).occurrences, isEmpty);
    });

    testWidgets('plain Save writes the new component and its parent, and the tree marks both until then', (
      tester,
    ) async {
      final storage = _FakeStorageService();
      final toolbar = await pumpWithComponent(tester, storage);

      // A4: one unsaved dot per row (a never-saved Part is unsaved too): the new component, and the root it was added to.
      var panel = _TreeProbe(tester);
      expect(panel.unsavedRowKeys, hasLength(2));
      expect(panel.unsavedRowKeys, contains(''), reason: 'the parent');
      expect(find.byKey(const ValueKey('tree-state::unsaved')), findsOneWidget);
      expect(storage.files, isEmpty);

      toolbar().onSaveNative!();
      await settle(tester);

      expect(storage.files.keys, containsAll(['Part 1.didsa', 'Component 1.didsa']));
      expect(find.text('Saved 2 files'), findsOneWidget);
      panel = _TreeProbe(tester);
      expect(panel.unsavedRowKeys, isEmpty);
      expect(find.byKey(const ValueKey('tree-state::unsaved')), findsNothing);
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
      expect(_TreeProbe(tester).unsavedRowKeys, isNotEmpty);
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
      expect(find.byTooltip('Add'), findsNothing);
      expect(find.byTooltip('Open toolbar'), findsNothing);
      expect(find.text('Nothing selected'), findsOneWidget);
      // The tree is docked, so it carries no Close button.
      expect(find.byTooltip('Close'), findsNothing);
    });

    testWidgets('Options > Background, colour and scene opens a dialog, never the phone hamburger panel (bug report 2026-11-17 item 13)', (
      tester,
    ) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      expect(find.byType(PartToolbar), findsNothing);
      await tester.tap(find.byKey(const ValueKey('menu-options')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Every hamburger selection filter has a desktop home too.
      expect(find.text('Select sketch points'), findsOneWidget);
      expect(find.text('Select sketch lines'), findsOneWidget);
      await tester.tap(find.text('Background, colour and scene…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('scene-settings-dialog')), findsOneWidget);
      expect(find.byType(PartToolbar), findsNothing);
      for (final label in ['Perspective', 'Background Colour', 'Body Colour', 'Body Transparency', 'Polygon Resolution', 'Scene']) {
        expect(find.descendant(of: find.byKey(const ValueKey('scene-settings-dialog')), matching: find.text(label)), findsOneWidget,
            reason: label);
      }
      // A change shows in the dialog straight away and reaches the screen.
      final before = tester.widget<SwitchListTile>(find.byKey(const ValueKey('scene-settings-perspective'))).value;
      await tester.tap(find.byKey(const ValueKey('scene-settings-perspective')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('scene-settings-perspective'))).value, !before);
      await tester.tap(find.byKey(const ValueKey('view-override-switch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<Switch>(find.byKey(const ValueKey('view-override-switch'))).value, isTrue);
      expect(find.byKey(const ValueKey('view-override-chip')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scene-settings-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('scene-settings-dialog')), findsNothing);
      expect(find.byType(PartToolbar), findsNothing);
    });

    testWidgets('a Visibility button under Reset view opens the Visibility panel top right; the ribbon drops what it duplicates '
        '(bug report 2026-11-17 item 12)', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      // The button itself is drawn by PartViewport next to Reset view, over the 3D scene, which a headless test does not build;
      // the screen hands it the callback and the badge.
      final viewportWidget = tester.widget<PartViewport>(find.byType(PartViewport));
      expect(viewportWidget.onVisibilityPressed, isNotNull);
      expect(viewportWidget.showResetViewButton, isTrue);
      expect(find.byType(VisibilityPanel), findsNothing);

      viewportWidget.onVisibilityPressed!();
      await tester.pump();
      expect(find.byType(VisibilityPanel), findsOneWidget);
      // Docked top right of the viewport, under the Reset view (top 8) and Visibility (top 56) buttons.
      final panel = tester.getRect(find.byType(VisibilityPanel));
      final viewport = tester.getRect(find.byType(PartViewport));
      expect(panel.right, closeTo(viewport.right - 8, 1));
      expect(panel.top, closeTo(viewport.top + 104, 1));

      await tester.ensureVisible(find.byKey(const ValueKey('ribbon-tab-view')));
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-view')));
      await tester.pump();
      for (final label in ['Planes', 'Shaded', 'Edges', 'Wireframe']) {
        expect(find.byKey(ValueKey('ribbon-$label')), findsNothing, reason: label);
      }
      for (final label in ['Fit', 'View cube', 'Front', 'Isometric', 'Perspective', 'Present']) {
        expect(find.byKey(ValueKey('ribbon-$label')), findsOneWidget, reason: label);
      }
    });

    testWidgets('the phone layout has no viewport Visibility button (it has the quick column)', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).onVisibilityPressed, isNull);
    });

    testWidgets('Presentation mode hides the ribbon, tree pane and status bar, and leaves the desktop layout alone on exit', (
      tester,
    ) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      await tester.ensureVisible(find.byKey(const ValueKey('ribbon-tab-view')));
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-view')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ribbon-Present')));
      await tester.pump();
      for (final key in ['desktop-ribbon', 'desktop-status-bar', 'desktop-left-pane']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const ValueKey('presenter-button')), findsOneWidget);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).showResetViewButton, isFalse);

      // Esc steps back the same way Back does: no menu, no controls, so it asks.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Stop presenting?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('presenting-stop')));
      await tester.pump(const Duration(milliseconds: 300));
      for (final key in ['desktop-ribbon', 'desktop-status-bar', 'desktop-left-pane']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).showResetViewButton, isTrue);
    });

    testWidgets('the desktop layout has no Start button or quick column and keeps its Reset view button', (tester) async {
      bigWindow(tester);
      // (The button itself is drawn by the 3D scene, which the test runner cannot start: check what the screen asks for.)
      await pumpScreen(tester, layout: desktop());
      expect(find.byKey(const ValueKey('start-fab')), findsNothing);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).showResetViewButton, isTrue);
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('start-fab')), findsOneWidget, reason: 'the phone layout has it');
      expect(
        tester.widget<PartViewport>(find.byType(PartViewport)).showResetViewButton,
        isFalse,
        reason: 'Fit is in the phone layout\'s quick column',
      );
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

    testWidgets('B5: a latched error banner clears when the user switches lens (a new tool context)', (tester) async {
      bigWindow(tester);
      await pumpScreen(tester, layout: desktop());
      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
            const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'occ-1#pattern:pat-1:2'),
          );
      await tester.pump();
      expect(find.textContaining('derived pattern instance'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('ribbon-lens')), matching: find.text('Assembly')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('derived pattern instance'), findsNothing);
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
      'opening a legacy multi-Part Bundle imports it directly (hidden features go to the backend with it) and restores sections, '
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
        // Hide / Show is Part state: the whole file (its legacy top-level hidden_feature_ids included) goes to the backend's
        // import, which moves it into the Part, and the new screen reads it back from the Part.
        expect(pushedScreen.initialHiddenFeatureIds, isEmpty);
        expect(backend.lastImportBody, containsPair('hidden_feature_ids', ['feature-abc']));
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
      final tree = _TreeProbe(tester);
      await tree.onOccurrenceColorTap!(tree.occurrences.first);
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
      final tree = _TreeProbe(tester);
      await tree.onOccurrenceLongPress(tree.occurrences.first);
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await settle(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Hide'));
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
      final tree = _TreeProbe(tester);
      await tree.onOccurrenceLongPress(tree.occurrences.last);
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await settle(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Hide'));
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

  // Item 1a (Flutter-testing feedback 2026-11-11): Use on a level-1 reference adds the references found INSIDE that file to the sheet.
  testWidgets('Use on a level-1 reference adds its nested (level-2) references to the open Review sheet', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Uint8List native(String id, {List<Map<String, dynamic>> occurrences = const []}) => Uint8List.fromList(utf8.encode(jsonEncode({
          'schema_version': 1,
          'document': {
            'id': 'doc-$id',
            'root_part_id': id,
            'parts': [
              {'id': id, 'name': id, 'features': [], 'occurrences': occurrences, 'mates': []},
            ],
          },
          'sketches': [],
        })));
    final storage = _FakeStorageService()
      ..presetLastUsedRoot = const DesktopProjectRoot('/fake/project')
      ..files['proj/parts/Sub.didsa'] = native('sub', occurrences: [
        {'id': 'o-leaf', 'external_ref': 'parts/Leaf.didsa', 'transform': null, 'suppressed': false, 'hidden': false},
      ])
      ..files['proj/parts/Leaf.didsa'] = native('leaf');
    final backend = _FakeDocumentBackend(seedOccurrences: [
      {
        'id': 'o-sub',
        'external_ref': 'parts/Sub.didsa',
        'resolved_part_id': null,
        'name_override': null,
        'transform': {'translation': [0.0, 0.0, 0.0], 'rotation_axis': [0.0, 0.0, 1.0], 'rotation_angle_degrees': 0.0},
        'suppressed': false,
        'hidden': false,
        'fixed': false,
      },
    ]);
    final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
    await tester.pumpWidget(
      MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          storageService: storage,
          assemblyDocumentClient: AssemblyDocumentClient(
            storageService: storage,
            documentApiClient: documentApi,
            composer: AssemblyGraphComposer(storageService: storage, fileCache: _NoopFileCache()),
          ),
          initialProjectRoot: const DesktopProjectRoot('/fake/project'),
          initialReferenceReports: const [
            ReferenceReport(
              parentPartId: 'part-1',
              parentPath: 'proj/root.didsa',
              occurrenceId: 'o-sub',
              requestedPath: 'parts/Sub.didsa',
              storedPartId: null,
              outcome: ReferenceOutcome.likely,
              foundPath: 'proj/parts/Sub.didsa',
              candidates: ['proj/parts/Sub.didsa'],
            ),
          ],
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
    await _pumpUntil(tester, () => find.byKey(const Key('references-banner')).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Review'));
    await _pumpUntil(tester, () => find.byKey(const Key('reference-o-sub')).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('reference-o-leaf')), findsNothing, reason: 'level 2 is not in the list before Use');

    await tester.tap(find.byKey(const Key('use-o-sub-proj/parts/Sub.didsa')));
    await _pumpUntil(tester, () => find.byKey(const Key('reference-o-leaf')).evaluate().isNotEmpty);
    await _pumpUntil(tester, () => find.byKey(const Key('reference-o-sub')).evaluate().isEmpty);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('reference-o-sub')), findsNothing, reason: 'the level-1 row is dealt with');
    expect(find.byKey(const Key('reference-o-leaf')), findsOneWidget, reason: 'its own reference joined the list');
    expect(find.text('in Sub.didsa'), findsOneWidget);
    expect(find.textContaining('Found 1 more reference inside Sub.didsa'), findsOneWidget);
    expect(find.byKey(Key('use-o-leaf-proj/parts/Leaf.didsa')), findsOneWidget);
  });

  group('item 1c: bulk actions in the Review sheet relink in one merge', () {
    Uint8List native(String id) => Uint8List.fromList(utf8.encode(jsonEncode({
          'schema_version': 1,
          'document': {
            'id': 'doc-$id',
            'root_part_id': id,
            'parts': [
              {'id': id, 'name': id, 'features': [], 'occurrences': [], 'mates': []},
            ],
          },
          'sketches': [],
        })));
    Map<String, dynamic> occ(String id, String ref) => {
          'id': id,
          'external_ref': ref,
          'resolved_part_id': null,
          'name_override': null,
          'transform': {'translation': [0.0, 0.0, 0.0], 'rotation_axis': [0.0, 0.0, 1.0], 'rotation_angle_degrees': 0.0},
          'suppressed': false,
          'hidden': false,
          'fixed': false,
        };
    ReferenceReport report(String letter, ReferenceOutcome outcome) => ReferenceReport(
          parentPartId: 'part-1',
          parentPath: 'proj/root.didsa',
          occurrenceId: 'o-$letter',
          requestedPath: 'parts/$letter.didsa',
          storedPartId: null,
          outcome: outcome,
          foundPath: 'proj/parts/$letter.didsa',
          candidates: ['proj/parts/$letter.didsa'],
        );

    Future<int Function()> pump(WidgetTester tester, List<ReferenceReport> reports) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final storage = _FakeStorageService()..presetLastUsedRoot = const DesktopProjectRoot('/fake/project');
      for (final letter in ['A', 'B', 'C']) {
        storage.files['proj/parts/$letter.didsa'] = native(letter.toLowerCase());
      }
      final backend = _FakeDocumentBackend(seedOccurrences: [occ('o-A', 'parts/A.didsa'), occ('o-B', 'parts/B.didsa'), occ('o-C', 'parts/C.didsa')]);
      var imports = 0;
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async {
        if (request.url.path == '/document/import/native') imports++;
        return backend.handle(request);
      }));
      await tester.pumpWidget(
        MaterialApp(
          home: PartScreen(
            documentApi: documentApi,
            storageService: storage,
            assemblyDocumentClient: AssemblyDocumentClient(
              storageService: storage,
              documentApiClient: documentApi,
              composer: AssemblyGraphComposer(storageService: storage, fileCache: _NoopFileCache()),
            ),
            initialProjectRoot: const DesktopProjectRoot('/fake/project'),
            initialReferenceReports: reports,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      await _pumpUntil(tester, () => find.byKey(const Key('references-banner')).evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Review'));
      await _pumpUntil(tester, () => find.byKey(const Key('reference-o-A')).evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      return () => imports;
    }

    testWidgets('Use all single suggestions relinks every one-candidate row with one import', (tester) async {
      final imports = await pump(tester, [
        report('A', ReferenceOutcome.likely),
        report('B', ReferenceOutcome.likely),
        report('C', ReferenceOutcome.likely),
      ]);
      final before = imports();
      expect(find.text('Use all single suggestions (3)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('use-all-single')));
      await _pumpUntil(tester, () => find.byKey(const Key('reference-o-A')).evaluate().isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      expect(imports() - before, 1, reason: 'three relinks, one merge, one importNative');
      expect(find.byKey(const Key('reference-o-B')), findsNothing);
      expect(find.byKey(const Key('reference-o-C')), findsNothing);
    });

    testWidgets('Use on one row offers the same folder change for the others, applied in one import', (tester) async {
      final imports = await pump(tester, [
        report('A', ReferenceOutcome.likely),
        report('B', ReferenceOutcome.missing),
        report('C', ReferenceOutcome.missing),
      ]);
      await tester.tap(find.byKey(const Key('use-o-A-proj/parts/A.didsa')));
      await _pumpUntil(tester, () => find.byKey(const Key('apply-folder-change')).evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Apply the same folder change to 2 other references'), findsOneWidget);
      final before = imports();
      await tester.tap(find.byKey(const Key('apply-folder-change')));
      await _pumpUntil(tester, () => find.byKey(const Key('reference-o-B')).evaluate().isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      expect(imports() - before, 1);
      expect(find.byKey(const Key('reference-o-C')), findsNothing);
    });
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
    // P2: the one tree's root row names the part too: the app bar's title is the screen's.
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Part 1')), findsOneWidget, reason: 'the screen under it is still there');
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
            if (find.byType(AssemblyTreeView).evaluate().isEmpty) return;
            final tree = _TreeProbe(tester);
            if (tree.occurrences.isEmpty) return;
            await tree.onOccurrenceColorTap!(tree.occurrences[rng.nextInt(tree.occurrences.length)]);
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
            if (find.byType(AssemblyTreeView).evaluate().isEmpty) return;
            final tree = _TreeProbe(tester);
            if (tree.occurrences.isEmpty) return;
            await tree.onOccurrenceLongPress(tree.occurrences[rng.nextInt(tree.occurrences.length)]);
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

  group('View appearance override (Item 1 of the view-override plan)', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
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

    ViewAppearanceOverride? current(WidgetTester tester) =>
        tester.widget<PartViewport>(find.byType(PartViewport)).appearanceOverride;

    testWidgets('starts off; picking Body Colour turns it on; the chip turns it off', (tester) async {
      await pumpScreen(tester);
      expect(current(tester), isNull);
      expect(find.byKey(const ValueKey('view-override-chip')), findsNothing);

      await openToolbar(tester);
      await tester.tap(find.text('View'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.byKey(const ValueKey('view-override-colour')));
      await tester.tap(find.byKey(const ValueKey('view-override-colour')));
      await _settleSheet(tester);
      await tester.tap(find.text('Orange'));
      await _settleSheet(tester);

      expect(current(tester), const ViewAppearanceOverride(colourHex: '#E8834A', opacity: 1.0));
      expect(find.byKey(const ValueKey('view-override-chip')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('view-override-chip')));
      await tester.pump();
      expect(current(tester), isNull);
      expect(find.byKey(const ValueKey('view-override-chip')), findsNothing);
    });

    testWidgets('the View tab\'s Override command switches it on and off, and its colour stays', (tester) async {
      await pumpScreen(tester);
      await openStartMenu(tester);
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-view')));
      await _settleSheet(tester);
      expect(find.byKey(const ValueKey('start-tile-Body colour')), findsOneWidget);
      expect(find.byKey(const ValueKey('start-tile-Transparency')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('start-tile-Override')));
      await _settleSheet(tester);
      expect(current(tester), isNotNull);
      await openStartMenu(tester);
      await tester.tap(find.byKey(const ValueKey('ribbon-tab-view')));
      await _settleSheet(tester);
      await tester.tap(find.byKey(const ValueKey('start-tile-Override')));
      await _settleSheet(tester);
      expect(current(tester), isNull);
    });
  });

  // Edit Alone (Item 2 of `docs/view-override-edit-alone-sketch-origin-plan.md`).
  group('Edit Alone', () {
    Map<String, dynamic> occurrence(String id, {String? partId = 'unset'}) => {
          'id': id,
          'external_ref': 'parts/$id.didsa',
          'resolved_part_id': partId == 'unset' ? '$id-part' : partId,
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

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// occ-1 is a part, occ-2 a sub-assembly holding occ-3 (a part), occ-4 is unresolved.
    Future<_FakeDocumentBackend> open(WidgetTester tester) async {
      final backend = _FakeDocumentBackend(
        seedOccurrences: [occurrence('occ-1'), occurrence('occ-2'), occurrence('occ-4', partId: null)],
      )..subOccurrences = {
          'occ-2-part': [occurrence('occ-3')],
        };
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
      backend.writes.clear();
      return backend;
    }

    PartViewport viewport(WidgetTester tester) => tester.widget<PartViewport>(find.byType(PartViewport));

    /// Long press a tree row, then the menu entry (a long press enters multi-select; the menu is behind More actions).
    Future<void> menuAction(WidgetTester tester, String occurrenceId, String label) async {
      final tree = _TreeProbe(tester);
      await tree.onOccurrenceLongPress(tree.occurrences.firstWhere((o) => o.id == occurrenceId));
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await settle(tester);
      await tester.tap(find.text(label));
      await settle(tester);
    }

    final pill = find.byKey(const ValueKey('edit-alone-pill'));
    final done = find.byKey(const ValueKey('edit-alone-done'));

    testWidgets('the menu lists Edit Alone first, above Make Focus', (tester) async {
      await open(tester);
      final tree = _TreeProbe(tester);
      await tree.onOccurrenceLongPress(tree.occurrences.first);
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await settle(tester);
      expect(find.text('Edit Alone'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Edit Alone')).dy, lessThan(tester.getTopLeft(find.text('Make Focus')).dy));
    });

    testWidgets('on a part: focus +1, Part lens, soloFocus, the pill names it; Done undoes it and writes nothing', (tester) async {
      final backend = await open(tester);
      expect(viewport(tester).soloFocus, isFalse);
      await menuAction(tester, 'occ-1', 'Edit Alone');
      expect(viewport(tester).soloFocus, isTrue);
      expect(viewport(tester).focusedOccurrencePath, ['occ-1']);
      expect(pill, findsOneWidget);
      expect(find.descendant(of: pill, matching: find.textContaining('Editing', findRichText: true)), findsOneWidget);
      // P2: one tree in both lenses; the Part lens makes the edited part (the tree's root here) live.
      expect(_TreeProbe(tester).view.title, 'Build Tree', reason: 'Part lens');
      expect(_TreeProbe(tester).model.liveKey, '', reason: 'the part being edited alone is the live root');
      // The way back is a button on the pill, and in the ribbon.
      expect(done, findsOneWidget);

      await tester.tap(done);
      await settle(tester);
      expect(viewport(tester).soloFocus, isFalse);
      expect(viewport(tester).focusedOccurrencePath, isEmpty);
      expect(pill, findsNothing);
      expect(_TreeProbe(tester).view.title, 'Assembly Tree', reason: 'the lens before (Assembly) is back');
      expect(_TreeProbe(tester).model.liveKey, isNull, reason: 'the Assembly lens has no live row');
      expect(backend.writes, isEmpty, reason: 'entering and leaving never write (no hidden flags)');
    });

    testWidgets('on a sub-assembly: Assembly lens and the tree shows its children', (tester) async {
      final backend = await open(tester);
      await menuAction(tester, 'occ-2', 'Edit Alone');
      expect(viewport(tester).soloFocus, isTrue);
      expect(viewport(tester).focusedOccurrencePath, ['occ-2']);
      final tree = _TreeProbe(tester);
      expect(tree.occurrences.map((o) => o.id), ['occ-3']);
      await tester.tap(done);
      await settle(tester);
      expect(viewport(tester).focusedOccurrencePath, isEmpty);
      expect(backend.writes, isEmpty);
    });

    testWidgets('Make Focus inside Edit Alone, then Done: back to the start in one step; no nested Edit Alone', (tester) async {
      await open(tester);
      await menuAction(tester, 'occ-2', 'Edit Alone');
      final tree = _TreeProbe(tester);
      await tree.onOccurrenceLongPress(tree.occurrences.single);
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await settle(tester);
      expect(find.text('Edit Alone'), findsNothing, reason: 'inside Edit Alone it is the same as Make Focus');
      await tester.tap(find.text('Make Focus'));
      await settle(tester);
      expect(viewport(tester).focusedOccurrencePath, ['occ-2', 'occ-3']);
      expect(viewport(tester).soloFocus, isTrue);
      await tester.tap(done);
      await settle(tester);
      expect(viewport(tester).focusedOccurrencePath, isEmpty);
      expect(viewport(tester).soloFocus, isFalse);
    });

    testWidgets('C1: with a tree open the pill moves into the tree, under its header; closed, it is the pill at the top again', (tester) async {
      await open(tester);
      await menuAction(tester, 'occ-1', 'Edit Alone');
      // No tree open: the pill is the floating one at the top, outside any tree.
      expect(pill, findsOneWidget);
      expect(find.descendant(of: find.byType(AssemblyTreeView), matching: pill), findsNothing);
      final topPill = tester.widget<EditAloneStrip>(pill);
      expect(topPill.pill, isTrue);

      await tester.tap(find.byTooltip('Feature tree'));
      await settle(tester);
      // Tree open (Part lens: the Build Tree): exactly one row, inside the tree, directly under the header row, not floating.
      expect(pill, findsOneWidget);
      expect(find.descendant(of: find.byType(AssemblyTreeView), matching: pill), findsOneWidget);
      expect(tester.widget<EditAloneStrip>(pill).pill, isFalse);
      expect(tester.getTopLeft(pill).dy, greaterThan(tester.getTopLeft(find.text('Build Tree')).dy));
      // B3: the strip stands for the root row (rule 5: nothing twice), so it is above the first row listed, the live part's folders.
      expect(find.byKey(const ValueKey('tree-row:')), findsNothing);
      expect(tester.getTopLeft(pill).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('tree-row:#planes'))).dy));
      expect(find.descendant(of: pill, matching: find.textContaining('Editing', findRichText: true)), findsOneWidget);

      await tester.tap(done);
      await settle(tester);
      expect(viewport(tester).soloFocus, isFalse);
      expect(pill, findsNothing);
    });

    testWidgets('Back closes the Menu panel first, then leaves Edit Alone', (tester) async {
      await open(tester);
      await menuAction(tester, 'occ-1', 'Edit Alone');
      await openToolbar(tester);
      await _settleSheet(tester);
      expect(tester.widget<PartToolbar>(find.byType(PartToolbar)).visible, isTrue);
      await tester.binding.handlePopRoute();
      await _settleSheet(tester);
      expect(tester.widget<PartToolbar>(find.byType(PartToolbar)).visible, isFalse);
      expect(viewport(tester).soloFocus, isTrue, reason: 'the first Back only closed the panel');
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(viewport(tester).soloFocus, isFalse);
      expect(pill, findsNothing);
    });

    testWidgets('the selected component\'s drawer has an Edit Alone button first', (tester) async {
      await open(tester);
      final tree = _TreeProbe(tester);
      await tree.onOccurrenceTap(tree.occurrences.firstWhere((o) => o.id == 'occ-1'));
      await settle(tester);
      final button = find.byKey(const ValueKey('component-edit-alone'));
      expect(button, findsOneWidget);
      // (In the 800x600 test window the sheet's first row sits below the fold: call the button's own callback.)
      tester.widget<FilledButton>(button).onPressed!();
      await settle(tester);
      expect(viewport(tester).soloFocus, isTrue);
      expect(viewport(tester).focusedOccurrencePath, ['occ-1']);
    });

    testWidgets('an unresolved component is refused', (tester) async {
      await open(tester);
      await menuAction(tester, 'occ-4', 'Edit Alone');
      expect(viewport(tester).soloFocus, isFalse);
      expect(pill, findsNothing);
      expect(find.textContaining('unresolved component'), findsOneWidget);
    });

    testWidgets('refused while a scene is shown', (tester) async {
      await open(tester);
      await tapStartCommand(tester, 'Scenes', tab: 'evaluate');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('scenes-new')));
      await settle(tester);
      expect(find.textContaining('New scene from the default'), findsOneWidget, reason: 'a scene is being shown');
      await tester.tap(find.byKey(const ValueKey('scenes-close')));
      await settle(tester);
      await menuAction(tester, 'occ-1', 'Edit Alone');
      expect(viewport(tester).soloFocus, isFalse);
      expect(pill, findsNothing);
    });
  });

  // Sketch origin, 3b (Item 3 of the view-override plan): the Pick origin button in the orientation step, both for a new Sketch and for an existing one's.
  group('Sketch origin in the orientation step', () {
    final planeFeature = <String, dynamic>{
      'type': 'create_plane',
      'id': 'feature-3',
      'locked': false,
      'produces': 'plane',
      'origin': [0.0, 0.0, 5.0],
      'normal': [0.0, 0.0, 1.0],
      'x_axis': [1.0, 0.0, 0.0],
      'y_axis': [0.0, 1.0, 0.0],
    };
    final pickButton = find.byKey(const ValueKey('sketch-orientation-pick-origin'));

    Future<void> pump(WidgetTester tester, _FakeDocumentBackend backend, _FakeSketchBackend sketchBackend) async {
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
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

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// New Sketch on the created Plane (a tap on it, then "Create Sketch on Plane"): the orientation step opens.
    Future<void> newSketchOnPlane(WidgetTester tester) async {
      tester.widget<PartViewport>(find.byType(PartViewport)).onCreatePlaneTap!('feature-3');
      await settle(tester);
      await tester.tap(find.text('Create Sketch on Plane'));
      await _pumpUntil(tester, () => find.text('Continue').evaluate().isNotEmpty);
    }

    PartViewport viewport(WidgetTester tester) => tester.widget<PartViewport>(find.byType(PartViewport));

    // Flutter-testing feedback 2026-11-11, item 4: the pill's row scrolled past its rounded ends.
    testWidgets('on a 360 dp phone the orientation pill clips its row, every control is reachable, and Continue taps', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final backend = _FakeDocumentBackend(seedFeatures: [planeFeature]);
      await pump(tester, backend, _FakeSketchBackend());
      await newSketchOnPlane(tester);

      final pill = find.ancestor(of: find.byKey(const ValueKey('sketch-orientation-pill-row')), matching: find.byType(Material)).first;
      final material = tester.widget<Material>(pill);
      expect(material.clipBehavior, isNot(Clip.none), reason: 'scrolled buttons must not draw past the rounded ends');
      expect(material.shape, isA<StadiumBorder>());
      expect(find.byKey(const ValueKey('sketch-orientation-cancel')), findsOneWidget);
      expect(find.byKey(const ValueKey('sketch-orientation-cancel')).evaluate().single.widget, isA<IconButton>(),
          reason: 'below 400 dp Cancel is an icon button');

      // Everything is reachable by scrolling; Continue ends up tappable.
      await tester.ensureVisible(find.text('Continue'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Continue'));
      await settle(tester);
      expect(find.text('Continue'), findsNothing, reason: 'the orientation step ended');
    });

    testWidgets('a new Sketch sends origin auto and the pill has Pick origin; the axes sit at the resolved origin', (tester) async {
      final backend = _FakeDocumentBackend(seedFeatures: [planeFeature])
        ..autoStored = {'point_ref': {'vertex_ref': {'body_id': 'b', 'shape_type': 'vertex', 'index': 1}}}
        ..autoResolved = [3.0, 4.0, 5.0];
      await pump(tester, backend, _FakeSketchBackend());
      await newSketchOnPlane(tester);
      expect(backend.sketchCreateBodies.single, {'plane_feature_id': 'feature-3', 'origin': 'auto'});
      expect(pickButton, findsOneWidget);
      expect(viewport(tester).sketchOrientationBasis!.origin.x, 3.0, reason: 'the orientation axes are drawn from the resolved corner');
      expect(viewport(tester).sketchOrientationBasis!.origin.z, 5.0);
    });

    testWidgets('a Sketch on a fixed plane asks for auto too (the backend answers: the plane\'s own origin) and shows Pick origin', (tester) async {
      final backend = _FakeDocumentBackend();
      await pump(tester, backend, _FakeSketchBackend());
      await tapStartCommand(tester, 'New Sketch');
      tester.widget<PartViewport>(find.byType(PartViewport)).onPlaneTap(ReferencePlaneKind.xy);
      await _pumpUntil(tester, () => find.text('Continue').evaluate().isNotEmpty);
      expect(backend.sketchCreateBodies.single, {'plane': 'XY', 'origin': 'auto'});
      expect(pickButton, findsOneWidget);
      expect(viewport(tester).sketchOrientationBasis!.origin.length, 0.0);
    });

    testWidgets('flip after Auto asks for auto again; after a manual pick it does not', (tester) async {
      final sketchBackend = _FakeSketchBackend();
      final backend = _FakeDocumentBackend(seedFeatures: [planeFeature])
        ..autoStored = {'point_ref': {'vertex_ref': {'body_id': 'b', 'shape_type': 'vertex', 'index': 1}}}
        ..autoResolved = [3.0, 4.0, 5.0];
      await pump(tester, backend, sketchBackend);
      await newSketchOnPlane(tester);
      expect(backend.originPatches, isEmpty);

      await tester.tap(find.byTooltip('Flip'));
      await settle(tester);
      expect(sketchBackend.orientationPatches.last.$1, isTrue);
      expect(backend.originPatches, ['auto'], reason: 'still on the default: asked again so it follows the flip');

      // A manual pick: a Body corner.
      await tester.tap(pickButton);
      await settle(tester);
      expect(find.text('Sketch origin'), findsOneWidget);
      viewport(tester).onSelectionToggle!(const SelectionEntityRef(kind: SelectionEntityKind.vertex, bodyId: 'b', id: 7));
      await settle(tester);
      expect(backend.originPatches.last, {
        'point_ref': {'vertex_ref': {'body_id': 'b', 'shape_type': 'vertex', 'index': 7}},
      });
      expect(find.text('Sketch origin'), findsNothing, reason: 'back to the pill after a pick');
      expect(viewport(tester).sketchOrientationBasis!.origin.x, 11.0);

      final patchesBefore = backend.originPatches.length;
      await tester.tap(find.byTooltip('Un-flip'));
      await settle(tester);
      expect(backend.originPatches, hasLength(patchesBefore), reason: 'a manual pick is left alone by flip and rotate');
      expect(viewport(tester).sketchOrientationBasis!.origin.x, 11.0);
    });

    testWidgets('Plane origin sends null, Auto sends auto; Cancel of the picker keeps the pill and the origin', (tester) async {
      final backend = _FakeDocumentBackend(seedFeatures: [planeFeature])
        ..autoStored = {'point_ref': {'vertex_ref': {'body_id': 'b', 'shape_type': 'vertex', 'index': 1}}}
        ..autoResolved = [3.0, 4.0, 5.0];
      await pump(tester, backend, _FakeSketchBackend());
      await newSketchOnPlane(tester);
      await tester.tap(pickButton);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('sketch-origin-plane-origin')));
      await settle(tester);
      expect(backend.originPatches.last, isNull);
      expect(viewport(tester).sketchOrientationBasis!.origin.x, 0.0, reason: 'null: the Plane\'s own origin, (0, 0, 5)');
      expect(viewport(tester).sketchOrientationBasis!.origin.z, 5.0);

      await tester.tap(pickButton);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('sketch-origin-auto')));
      await settle(tester);
      expect(backend.originPatches.last, 'auto');

      await tester.tap(pickButton);
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.text('Sketch origin'), findsNothing);
      expect(pickButton, findsOneWidget, reason: 'Cancel of the picker leaves the orientation step open');
    });

    testWidgets('a Sketch Point of this or a later Sketch is refused with a note and nothing is sent', (tester) async {
      final backend = _FakeDocumentBackend(seedFeatures: [planeFeature]);
      await pump(tester, backend, _FakeSketchBackend());
      await newSketchOnPlane(tester);
      await tester.tap(pickButton);
      await settle(tester);
      final own = backend.features.last['id'] as String;
      viewport(tester).onSelectionToggle!(SelectionEntityRef(kind: SelectionEntityKind.sketchPoint, sketchFeatureId: own, sketchEntityId: 'p1'));
      await settle(tester);
      expect(backend.originPatches, isEmpty);
      expect(find.textContaining('this sketch or a later one'), findsOneWidget);
    });

    // Item 2 of the 2026-11-11 feedback: align a sketch axis to an edge or line in the orientation step.
    group('Align (sketch X axis to an edge or line)', () {
      final alignButton = find.byKey(const ValueKey('sketch-orientation-align'));
      final earlierSketch = {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false};

      Future<_FakeDocumentBackend> openNew(WidgetTester tester, {bool earlier = false}) async {
        final backend = _FakeDocumentBackend(seedFeatures: [if (earlier) ...[earlierSketch, {...earlierSketch, 'id': 'feature-2', 'sketch_id': 'sketch-2'}], planeFeature]);
        await pump(tester, backend, _FakeSketchBackend());
        await newSketchOnPlane(tester);
        return backend;
      }

      testWidgets('the pill has Align in a new Sketch\'s step and in an existing one\'s', (tester) async {
        await openNew(tester);
        expect(alignButton, findsOneWidget);
        expect(find.byTooltip('Align the sketch X axis to an edge or line'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await settle(tester);

        final backend = _FakeDocumentBackend(seedFeatures: [earlierSketch]);
        await tester.pumpWidget(const SizedBox());
        await pump(tester, backend, _FakeSketchBackend());
        await tester.tap(find.byTooltip('Feature tree'));
        await settle(tester);
        await tester.longPress(find.text('Sketch 1'));
        await settle(tester);
        await tester.tap(find.byTooltip('More actions'));
        await settle(tester);
        await tester.tap(find.text('Sketch Orientation'));
        await _pumpUntil(tester, () => alignButton.evaluate().isNotEmpty);
        expect(find.text('Done'), findsOneWidget);
        expect(alignButton, findsOneWidget);
      });

      testWidgets('picking a sketch line of an earlier sketch sends the reference and turns the orientation axes; flip afterwards keeps it', (tester) async {
        final backend = await openNew(tester, earlier: true);
        await tester.tap(alignButton);
        await settle(tester);
        expect(find.text('Align sketch'), findsOneWidget);
        expect(find.byKey(const ValueKey('sketch-alignment-clear')), findsOneWidget);
        viewport(tester).onSelectionToggle!(
          const SelectionEntityRef(kind: SelectionEntityKind.sketchLine, sketchFeatureId: 'feature-1', sketchEntityId: 'line-9'),
        );
        await settle(tester);
        expect(backend.alignmentPatches.single, {'sketch_id': 'sketch-1', 'entity_type': 'line', 'entity_id': 'line-9'});
        final basis = viewport(tester).sketchOrientationBasis!;
        expect((basis.xAxis.x, basis.xAxis.y), (0.0, 1.0), reason: 'the orientation axes use the backend\'s aligned axes');
        expect((basis.yAxis.x, basis.yAxis.y), (-1.0, 0.0));
        expect(find.text('Align sketch'), findsNothing, reason: 'back to the pill');
        expect(tester.widget<IconButton>(alignButton).isSelected, isTrue);

        await tester.tap(find.byTooltip('Flip'));
        await settle(tester);
        expect(backend.alignmentPatches, hasLength(1), reason: 'flip refines the aligned frame, it does not touch the reference');
        expect(viewport(tester).sketchOrientationBasis!.xAxis.y, -1.0, reason: 'flip reverses X relative to the edge');
      });

      testWidgets('a Body edge sends an edge_ref', (tester) async {
        final backend = await openNew(tester);
        await tester.tap(alignButton);
        await settle(tester);
        viewport(tester).onSelectionToggle!(const SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: 'b', id: 5));
        await settle(tester);
        expect(backend.alignmentPatches.single, {
          'edge_ref': {'body_id': 'b', 'shape_type': 'edge', 'index': 5},
        });
      });

      testWidgets('Clear alignment sends null', (tester) async {
        final backend = await openNew(tester);
        await tester.tap(alignButton);
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('sketch-alignment-clear')));
        await settle(tester);
        expect(backend.alignmentPatches.single, isNull);
        expect(find.text('Align sketch'), findsNothing);
      });

      testWidgets('a line of this or a later sketch is refused with a note and nothing is sent; a curved edge shows the backend refusal', (tester) async {
        final backend = await openNew(tester);
        await tester.tap(alignButton);
        await settle(tester);
        final own = backend.features.last['id'] as String;
        viewport(tester).onSelectionToggle!(SelectionEntityRef(kind: SelectionEntityKind.sketchLine, sketchFeatureId: own, sketchEntityId: 'l1'));
        await settle(tester);
        expect(backend.alignmentPatches, isEmpty);
        expect(find.textContaining('this sketch or a later one'), findsOneWidget);

        backend.alignmentError = 'alignment_edge_not_straight';
        viewport(tester).onSelectionToggle!(const SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: 'b', id: 7));
        await settle(tester);
        expect(backend.alignmentPatches, hasLength(1));
        expect(find.textContaining('not straight'), findsOneWidget);
        expect(find.text('Align sketch'), findsOneWidget, reason: 'the sub-step stays open');
      });

      testWidgets('editing an aligned Sketch starts from its aligned axes; Cancel puts the old alignment back', (tester) async {
        final stored = {'sketch_id': 'sketch-1', 'entity_type': 'line', 'entity_id': 'old-line'};
        final backend = _FakeDocumentBackend(
          seedFeatures: [
            earlierSketch,
            {
              'type': 'sketch',
              'id': 'feature-2',
              'sketch_id': 'sketch-2',
              'locked': false,
              'x_axis_ref': stored,
              'aligned_x_axis': [0.0, 1.0, 0.0],
              'aligned_y_axis': [-1.0, 0.0, 0.0],
            },
          ],
        );
        final sketchBackend = _FakeSketchBackend();
        await pump(tester, backend, sketchBackend);
        await tester.tap(find.byTooltip('Feature tree'));
        await settle(tester);
        await tester.longPress(find.text('Sketch 2'));
        await settle(tester);
        await tester.tap(find.byTooltip('More actions'));
        await settle(tester);
        await tester.tap(find.text('Sketch Orientation'));
        await _pumpUntil(tester, () => alignButton.evaluate().isNotEmpty);
        expect(tester.widget<IconButton>(alignButton).isSelected, isTrue, reason: 'it is aligned now');
        final basis = viewport(tester).sketchOrientationBasis!;
        expect((basis.xAxis.x, basis.xAxis.y), (0.0, 1.0), reason: 'the axes start from the aligned frame');

        backend.alignedX = const [1.0, 1.0, 0.0];
        await tester.tap(alignButton);
        await settle(tester);
        viewport(tester).onSelectionToggle!(
          const SelectionEntityRef(kind: SelectionEntityKind.sketchLine, sketchFeatureId: 'feature-1', sketchEntityId: 'new-line'),
        );
        await settle(tester);
        expect(backend.alignmentPatches.single, {'sketch_id': 'sketch-1', 'entity_type': 'line', 'entity_id': 'new-line'});

        await tester.tap(find.text('Cancel'));
        await settle(tester);
        expect(backend.alignmentPatches.last, stored, reason: 'Cancel restores the alignment the Sketch had');
      });
    });

    testWidgets('editing an existing Sketch\'s orientation has Pick origin too; Cancel puts the old origin back', (tester) async {
      final stored = {'circle_centre_ref': {'body_id': 'b', 'shape_type': 'edge', 'index': 2}};
      final backend = _FakeDocumentBackend(
        seedFeatures: [
          {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': false, 'origin': stored, 'resolved_origin': [1.0, 2.0, 0.0]},
        ],
      );
      final sketchBackend = _FakeSketchBackend();
      await pump(tester, backend, sketchBackend);
      await tester.tap(find.byTooltip('Feature tree'));
      await settle(tester);
      await tester.longPress(find.text('Sketch 1'));
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await settle(tester);
      await tester.tap(find.text('Sketch Orientation'));
      await _pumpUntil(tester, () => pickButton.evaluate().isNotEmpty);
      expect(find.text('Done'), findsOneWidget, reason: 'the redefine mode of the step');
      expect(viewport(tester).sketchOrientationBasis!.origin.x, 1.0, reason: 'the axes start at the Sketch\'s stored origin');

      await tester.tap(find.byTooltip('Flip'));
      await settle(tester);
      expect(backend.originPatches, isEmpty, reason: 'flip does not move a stored origin unless Auto is asked for');

      await tester.tap(pickButton);
      await settle(tester);
      viewport(tester).onSelectionToggle!(const SelectionEntityRef(kind: SelectionEntityKind.vertex, bodyId: 'b', id: 4));
      await settle(tester);
      expect(backend.originPatches.single, isNotNull);
      expect(viewport(tester).sketchOrientationBasis!.origin.x, 11.0);

      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(backend.originPatches.last, stored, reason: 'Cancel restores the origin the Sketch had');
      expect(sketchBackend.orientationPatches.last, (false, 0), reason: '...and the orientation, as before');
    });
  });

  // A4 (`docs/assembly-tree-overhaul-scope.md` 9.6): the Assembly tree is `AssemblyTreeView` over `GET /parts/{id}/assembly-tree`, with
  // selection and actions by path. The fixture: `asm-1` and `asm-2` both place the sub-assembly `sub` (children `c1`, `c2`), beside `plate`.
  group('Assembly tree (A4)', () {
    Map<String, dynamic> occ(String id, {String? part, bool fixed = false, bool hidden = false, String? ref, String? name}) => {
          'id': id,
          'external_ref': ref ?? 'parts/$id.didsa',
          'resolved_part_id': part ?? '$id-part',
          'name_override': name,
          'transform': {
            'translation': [0.0, 0.0, 0.0],
            'rotation_axis': [0.0, 0.0, 1.0],
            'rotation_angle_degrees': 0.0,
          },
          'suppressed': false,
          'hidden': hidden,
          'fixed': fixed,
        };

    Map<String, dynamic> instance(List<String> path) => {
          'occurrence_path': path,
          'part_id': '${path.last}-part',
          'world_transform': {
            'translation': [0.0, 0.0, 0.0],
            'rotation_axis': [0.0, 0.0, 1.0],
            'rotation_angle_degrees': 0.0,
          },
          'hidden': false,
        };

    /// Opens the fixture in the Assembly lens. [around] sees every request after the fake has answered it (the answer is fixed by then) and
    /// may hold it, to make an answer arrive late.
    Future<_FakeDocumentBackend> openNested(WidgetTester tester,
        {Future<void> Function(http.Request request)? around,
        void Function(_FakeDocumentBackend backend)? configure,
        String? filePath,
        String? fileName,
        ProjectRoot? projectRoot,
        Map<String, String> relativePaths = const {},
        _FakeStorageService? storage,
        LayoutModeController? layout,
        bool waitForTree = true}) async {
      final backend = _FakeDocumentBackend(seedOccurrences: [
        occ('asm-1', part: 'sub', ref: 'parts/sub.didsa'),
        occ('asm-2', part: 'sub', ref: 'parts/sub.didsa'),
        occ('plate'),
      ]);
      backend.subOccurrences = {
        'sub': [occ('c1'), occ('c2')],
      };
      backend.extraAssemblyInstances = [
        for (final a in ['asm-1', 'asm-2'])
          for (final c in ['c1', 'c2']) instance([a, c]),
      ];
      if (configure != null) configure(backend);
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async {
          final response = backend.handle(request);
          if (around != null) await around(request);
          return response;
        }),
      );
      final sketchBackend = _FakeSketchBackend();
      if (layout != null) {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
      }
      Widget screen = PartScreen(
            documentApi: documentApi,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
            initialFilePath: filePath,
            initialFileName: fileName,
            initialProjectRoot: projectRoot,
            initialRelativePathByPartId: relativePaths,
            storageService: storage,
            assemblyDocumentClient: storage == null
                ? null
                : AssemblyDocumentClient(
                    storageService: storage,
                    documentApiClient: documentApi,
                    composer: AssemblyGraphComposer(storageService: storage, fileCache: _NoopFileCache()),
                  ),
          );
      if (layout != null) screen = LayoutModeScope(controller: layout, child: screen);
      await tester.pumpWidget(MaterialApp(home: screen));
      await _pumpUntil(tester, () => find.text('Part 1').evaluate().isNotEmpty);
      if (layout != null) {
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('ribbon-lens')), matching: find.text('Assembly')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
      } else {
        await switchLens(tester, 'Assembly');
      }
      if (waitForTree) await _pumpUntil(tester, () => _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
      return backend;
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    List<String> rowKeys(WidgetTester tester) => [for (final r in _TreeProbe(tester).model.visibleRows()) r.key];

    List<AssemblyOccurrenceInstanceDto> instances(WidgetTester tester) => tester.widget<PartViewport>(find.byType(PartViewport)).assemblyInstances;

    bool instanceHidden(WidgetTester tester, List<String> path) =>
        instances(tester).firstWhere((i) => i.occurrencePath.join('/') == path.join('/')).hidden;

    testWidgets('the tree is read in two calls: the structure first, then the status; nested components are rows, collapsed below the first level',
        (tester) async {
      final backend = await openNested(tester);
      expect(backend.assemblyTreeRequests.map((r) => r['status']), [null, 'true']);
      expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'plate']);
      final probe = _TreeProbe(tester);
      expect(probe.model.nodeAtPath(const ['asm-1', 'c1']), isNotNull, reason: 'the whole hierarchy is in the model, open or not');
      expect(probe.model.grouping, isTrue, reason: 'grouping is on by default');
    });

    testWidgets('a pick under the second placement of a sub-assembly reveals the second branch, not the first', (tester) async {
      await openNested(tester);

      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
            const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'asm-2/c1'),
          );
      await settle(tester);

      expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'asm-2/c1', 'asm-2/c2', 'plate']);
      expect(_TreeProbe(tester).model.selectedKey, 'asm-2/c1');
      expect(_TreeProbe(tester).model.selectedPath, ['asm-2', 'c1']);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities, {
        const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'asm-2/c1'),
      });
    });

    testWidgets('a row tap selects by path: the same child under the other placement stays unselected', (tester) async {
      await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1', 'asm-2']);

      await probe.tapRow('asm-1/c1');
      await settle(tester);

      expect(_TreeProbe(tester).model.selectedKey, 'asm-1/c1');
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).selectedEntities, {
        const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'asm-1/c1'),
      });

      await _TreeProbe(tester).tapRow('asm-2/c1');
      await settle(tester);
      expect(_TreeProbe(tester).model.selectedKey, 'asm-2/c1');
    });

    testWidgets('hiding a nested row hides only that placement: nothing is PATCHed, and the viewport follows by path', (tester) async {
      final backend = await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1', 'asm-2']);
      final writesBefore = backend.writes.length;

      probe.view.onVisibilityToggle!(probe.model.visibleRows().firstWhere((r) => r.key == 'asm-2/c1'));
      await settle(tester);

      expect(backend.writes.length, writesBefore, reason: 'a nested Hide is for this session: the shared occurrence is not written');
      expect(backend.subOccurrenceWrites, isEmpty);
      expect(instanceHidden(tester, ['asm-2', 'c1']), isTrue);
      expect(instanceHidden(tester, ['asm-1', 'c1']), isFalse, reason: 'the same child under the other placement stays shown');
      expect(instanceHidden(tester, ['asm-2', 'c2']), isFalse);
      final rows = _TreeProbe(tester).model.visibleRows();
      expect(rows.firstWhere((r) => r.key == 'asm-2/c1').hidden, isTrue);
      expect(rows.firstWhere((r) => r.key == 'asm-1/c1').hidden, isFalse);

      // The eye again shows it.
      _TreeProbe(tester).view.onVisibilityToggle!(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'asm-2/c1'));
      await settle(tester);
      expect(instanceHidden(tester, ['asm-2', 'c1']), isFalse);
    });

    testWidgets('Isolate on a nested row isolates that placement: its siblings and the rest of the assembly are hidden', (tester) async {
      await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1', 'asm-2']);

      await probe.menuAction('asm-1/c1', 'Isolate');

      expect(instanceHidden(tester, ['asm-1', 'c2']), isTrue);
      expect(instanceHidden(tester, ['asm-1', 'c1']), isFalse);
      // A4.1: isolate hides everything else, so the other placement goes too (that placement alone is isolated).
      expect(instanceHidden(tester, ['asm-2', 'c2']), isTrue, reason: 'the other placement is hidden with the rest');
      expect(instanceHidden(tester, ['asm-2', 'c1']), isTrue);
    });

    /// Three levels: asm-1 and asm-2 place `sub` (a part c1 and a sub-assembly g that holds d1 and d2), beside a lone `plate`.
    Future<_FakeDocumentBackend> openDeep(WidgetTester tester, {bool plateHidden = false}) async {
      final backend = _FakeDocumentBackend(seedOccurrences: [
        occ('asm-1', part: 'sub', ref: 'parts/sub.didsa'),
        occ('asm-2', part: 'sub', ref: 'parts/sub.didsa'),
        occ('plate', hidden: plateHidden),
      ]);
      backend.subOccurrences = {
        'sub': [occ('c1'), occ('g', part: 'inner', ref: 'parts/inner.didsa')],
        'inner': [occ('d1'), occ('d2')],
      };
      backend.extraAssemblyInstances = [
        for (final a in ['asm-1', 'asm-2']) ...[
          instance([a, 'c1']),
          instance([a, 'g']),
          instance([a, 'g', 'd1']),
          instance([a, 'g', 'd2']),
        ],
      ];
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
      await _pumpUntil(tester, () => _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
      _TreeProbe(tester).model.openAll(const ['asm-1', 'asm-2', 'asm-1/g', 'asm-2/g']);
      await settle(tester);
      return backend;
    }

    Set<String> hiddenInstances(WidgetTester tester) => {
          for (final i in instances(tester))
            if (i.hidden) i.occurrencePath.join('/'),
        };

    Set<String> highlighted(WidgetTester tester) => tester.widget<PartViewport>(find.byType(PartViewport)).highlightedInstanceKeys;

    testWidgets('a row tap highlights its parts by full path: a sub-assembly row all of its own, the root row everything', (tester) async {
      await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1', 'asm-2']);

      await probe.tapRow('asm-2/c1');
      await settle(tester);
      expect(highlighted(tester), {'asm-2/c1'}, reason: 'a row under the second placement highlights that placement only');

      await _TreeProbe(tester).tapRow('asm-2');
      await settle(tester);
      expect(highlighted(tester), {'asm-2', 'asm-2/c1', 'asm-2/c2'}, reason: 'a sub-assembly row highlights every part in it, not the other placement');

      await _TreeProbe(tester).tapRow('plate');
      await settle(tester);
      expect(highlighted(tester), {'plate'});

      await _TreeProbe(tester).tapRow('');
      await settle(tester);
      expect(highlighted(tester), {for (final i in instances(tester)) i.occurrencePath.join('/')}, reason: 'the root row is everything');
      expect(_TreeProbe(tester).model.selectedKey, '');
    });

    testWidgets('hiding a nested sub-assembly hides everything in it (that placement only); showing it restores its children, except one hidden on its own',
        (tester) async {
      final backend = await openDeep(tester);
      final probe = _TreeProbe(tester);
      final writesBefore = backend.writes.length;

      // d1 is hidden on its own first.
      probe.view.onVisibilityToggle!(probe.model.visibleRows().firstWhere((r) => r.key == 'asm-1/g/d1'));
      await settle(tester);
      expect(hiddenInstances(tester), {'asm-1/g/d1'});

      _TreeProbe(tester).view.onVisibilityToggle!(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'asm-1/g'));
      await settle(tester);
      expect(hiddenInstances(tester), {'asm-1/g', 'asm-1/g/d1', 'asm-1/g/d2'}, reason: 'the sub-assembly and every child; the other placement and c1 are shown');
      expect(backend.writes.length, writesBefore, reason: 'a nested Hide is for this session');

      _TreeProbe(tester).view.onVisibilityToggle!(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'asm-1/g'));
      await settle(tester);
      expect(hiddenInstances(tester), {'asm-1/g/d1'}, reason: 'showing the parent restores the children except the one hidden on its own');
    });

    testWidgets('hiding a top-level sub-assembly (the backend flag) hides everything in it, even when the mesh does not say so; Show brings it back',
        (tester) async {
      final backend = await openDeep(tester);
      final probe = _TreeProbe(tester);

      probe.view.onVisibilityToggle!(probe.model.visibleRows().firstWhere((r) => r.key == 'asm-1'));
      await _pumpUntil(tester, () => backend.writes.any((w) => w.contains('/part-1/occurrences/asm-1')));
      await settle(tester);
      expect(hiddenInstances(tester), {'asm-1', 'asm-1/c1', 'asm-1/g', 'asm-1/g/d1', 'asm-1/g/d2'});
      expect(instanceHidden(tester, ['asm-2', 'g', 'd1']), isFalse);

      _TreeProbe(tester).view.onVisibilityToggle!(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'asm-1'));
      await _pumpUntil(tester, () => backend.writes.where((w) => w.contains('/part-1/occurrences/asm-1')).length == 2);
      await settle(tester);
      expect(hiddenInstances(tester), isEmpty);
    });

    testWidgets('Isolate on a sub-assembly shows it and all its children and hides everything else; isolating it again restores what was hidden before',
        (tester) async {
      await openDeep(tester, plateHidden: true);
      final probe = _TreeProbe(tester);
      // d2 hidden on its own before the isolate: the undo must give it back as it was.
      probe.view.onVisibilityToggle!(probe.model.visibleRows().firstWhere((r) => r.key == 'asm-1/g/d2'));
      await settle(tester);
      expect(hiddenInstances(tester), {'plate', 'asm-1/g/d2'});

      await _TreeProbe(tester).menuAction('asm-1', 'Isolate');
      await settle(tester);
      expect(hiddenInstances(tester), {'asm-2', 'asm-2/c1', 'asm-2/g', 'asm-2/g/d1', 'asm-2/g/d2', 'plate'},
          reason: 'asm-1 and all of its children are shown (d2 too); every other component is hidden');

      await _TreeProbe(tester).menuAction('asm-1', 'Isolate');
      await settle(tester);
      expect(hiddenInstances(tester), {'plate', 'asm-1/g/d2'}, reason: 'the visibility from before the isolate is back');
    });

    testWidgets('Isolate on a nested sub-assembly isolates that placement only, and the undo restores the earlier state', (tester) async {
      await openDeep(tester);
      await _TreeProbe(tester).menuAction('asm-1/g', 'Isolate');
      await settle(tester);
      expect(hiddenInstances(tester), {'asm-1/c1', 'asm-2', 'asm-2/c1', 'asm-2/g', 'asm-2/g/d1', 'asm-2/g/d2', 'plate'},
          reason: 'g and its children under asm-1 are shown (so is asm-1 itself); the other placement, c1 and plate are hidden');

      // Isolating a part below it moves the isolate, and one undo goes back to the very start.
      await _TreeProbe(tester).menuAction('asm-1/g/d1', 'Isolate');
      await settle(tester);
      expect(hiddenInstances(tester).contains('asm-1/g/d2'), isTrue);
      expect(hiddenInstances(tester).contains('asm-1/g/d1'), isFalse);
      expect(hiddenInstances(tester).contains('asm-1/g'), isFalse, reason: 'the parents on the way down stay shown');

      await _TreeProbe(tester).menuAction('asm-1/g/d1', 'Isolate');
      await settle(tester);
      expect(hiddenInstances(tester), isEmpty);
    });

    testWidgets('Zoom to selection frames the selected row: a nested part, a sub-assembly by path, several rows, and the root row', (tester) async {
      // One 1 x 1 triangle per part, placed apart: asm-1's parts at x 10 and 20, asm-2's at y 50 and 60.
      final triangle = {
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
      Map<String, dynamic> at(List<String> path, double x, double y) => {
            ...instance(path),
            'world_transform': {
              'translation': [x, y, 0.0],
              'rotation_axis': [0.0, 0.0, 1.0],
              'rotation_angle_degrees': 0.0,
            },
          };
      await openNested(tester, configure: (backend) {
        backend.assemblyBodyMeshes = {'c1-part': triangle, 'c2-part': triangle};
        backend.extraAssemblyInstances = [
          at(['asm-1', 'c1'], 10, 0),
          at(['asm-1', 'c2'], 20, 0),
          at(['asm-2', 'c1'], 0, 50),
          at(['asm-2', 'c2'], 0, 60),
        ];
      });
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1', 'asm-2']);
      await settle(tester);

      PartViewportState viewport() => tester.state<PartViewportState>(find.byType(PartViewport));
      void expectTarget(double x, double y, String reason) {
        final t = viewport().debugCameraTarget;
        expect(t.x, closeTo(x, 1e-6), reason: reason);
        expect(t.y, closeTo(y, 1e-6), reason: reason);
      }

      // A nested part: its own triangle (x 10..11, y 0..1).
      await probe.menuAction('asm-1/c1', 'Zoom to selection');
      expectTarget(10.5, 0.5, 'asm-1/c1 alone');

      // A sub-assembly by path: both of its parts (x 10..21), not asm-2's.
      await _TreeProbe(tester).tapRow('asm-1');
      await settle(tester);
      await _TreeProbe(tester).menuAction('asm-1', 'Zoom to selection');
      expectTarget(15.5, 0.5, 'asm-1 and its children');

      // The second placement frames the second placement.
      await _TreeProbe(tester).menuAction('asm-2', 'Zoom to selection');
      expectTarget(0.5, 55.5, 'asm-2 and its children');

      // The root row frames everything (x 0..21, y 0..61).
      await _TreeProbe(tester).tapRow('');
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);
      expectTarget(10.5, 30.5, 'the root row, by the Shift+F shortcut');
    });

    testWidgets('the tree header has no Switch; the grouping icon is the button, with a tooltip and a clear on / off look', (tester) async {
      await openNested(tester);
      final header = find.descendant(of: find.byType(AssemblyTreeView), matching: find.byType(Switch));
      expect(header, findsNothing);

      final toggle = find.byKey(const ValueKey('tree-grouping-toggle'));
      expect(toggle, findsOneWidget);
      expect(tester.widget<IconButton>(toggle).isSelected, isTrue);
      expect(tester.widget<IconButton>(toggle).tooltip, contains('on'));
      expect(_TreeProbe(tester).model.grouping, isTrue);

      // The floating tree is slid off the screen while closed, so the button is pressed, not tapped.
      tester.widget<IconButton>(toggle).onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(_TreeProbe(tester).model.grouping, isFalse);
      expect(tester.widget<IconButton>(toggle).isSelected, isFalse);
      expect(tester.widget<IconButton>(toggle).tooltip, contains('off'));
      expect(ViewPreferences.assemblyTreeGrouping, isFalse, reason: 'saved, as the switch was');
      SharedPreferences.setMockInitialValues({});
      await ViewPreferences.load();
    });

    testWidgets('Fix on a nested row PATCHes its parent Part, and the row says so at once', (tester) async {
      final backend = await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1', 'asm-2']);

      await probe.menuAction('asm-1/c1', 'Fix');
      await _pumpUntil(tester, () => backend.subOccurrenceWrites.isNotEmpty);
      await settle(tester);

      expect(backend.subOccurrenceWrites, hasLength(1));
      expect(backend.subOccurrenceWrites.single['part'], 'sub', reason: 'the occurrence lives on the sub-assembly Part, not on the root');
      expect(backend.subOccurrenceWrites.single['id'], 'c1');
      expect(backend.subOccurrenceWrites.single['body'], containsPair('fixed', true));
      expect(backend.writes.where((w) => w.startsWith('PATCH') && w.contains('/part-1/occurrences')), isEmpty);
      expect(_TreeProbe(tester).model.nodeAtPath(const ['asm-1', 'c1'])!.fixed, isTrue);
    });

    testWidgets('Rename and Delete on a nested row go to its parent Part; Delete warns that it changes every placement (used 2\u00D7)',
        (tester) async {
      final backend = await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1', 'asm-2']);

      await probe.menuAction('asm-2/c2', 'Delete');
      expect(find.textContaining('used 2\u00D7'), findsOneWidget);
      expect(find.textContaining('every placement'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await _pumpUntil(tester, () => backend.subOccurrenceWrites.isNotEmpty);
      await settle(tester);

      expect(backend.subOccurrenceWrites.single, containsPair('method', 'DELETE'));
      expect(backend.subOccurrenceWrites.single, containsPair('part', 'sub'));
      expect(backend.subOccurrenceWrites.single, containsPair('id', 'c2'));
      expect(_TreeProbe(tester).model.nodeAtPath(const ['asm-1', 'c2']), isNull, reason: 'gone under both placements');
      expect(_TreeProbe(tester).model.nodeAtPath(const ['asm-2', 'c2']), isNull);
    });

    testWidgets('Make Focus from a nested row pushes each level and keeps the whole tree; a crumb walks back', (tester) async {
      final backend = await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1', 'asm-2']);

      await probe.menuAction('asm-1/c1', 'Make Focus');
      await settle(tester);

      expect(tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath, ['asm-1', 'c1']);
      // B3: the tree is still the document's; the focus is a row in it.
      expect(_TreeProbe(tester).model.tree!.partId, 'part-1', reason: 'the whole tree stays');
      expect(_TreeProbe(tester).model.focusPath, ['asm-1', 'c1']);
      expect(_TreeProbe(tester).view.focusCrumbs.length, 3, reason: 'the root and each pushed level');
      expect(backend.assemblyTreeRequests.every((r) => r['part'] == 'part-1'), isTrue, reason: 'no tree is fetched for a focused Part');

      await _TreeProbe(tester).exitFocus();
      await settle(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath, ['asm-1']);
      expect(_TreeProbe(tester).model.tree!.partId, 'part-1');
      expect(_TreeProbe(tester).model.focusPath, ['asm-1']);
      expect(rowKeys(tester), containsAll(['asm-1', 'asm-1/c1', 'asm-1/c2']));

      await _TreeProbe(tester).exitFocus();
      await settle(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath, isEmpty);
      expect(_TreeProbe(tester).model.tree!.partId, 'part-1');
      expect(_TreeProbe(tester).view.focusCrumbs, isEmpty, reason: 'nothing focused: no strip');
    });

    // B3 (`docs/assembly-tree-overhaul-scope.md` 10.6): Focus keeps the whole tree, dims the outside and rails the branch; the strip names the
    // levels; Edit Alone re-roots the tree on its target under one strip.
    group('Focus and Edit Alone context (B3)', () {
      Future<void> openTree(WidgetTester tester) async {
        await tester.tap(find.byTooltip('Feature tree'));
        await settle(tester);
      }

      AssemblyFocusRole role(WidgetTester tester, String key) {
        final model = _TreeProbe(tester).model;
        return model.focusRoleOf(model.visibleRows().firstWhere((r) => r.key == key));
      }

      List<String> focusPath(WidgetTester tester) => tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath;

      testWidgets('Make Focus on a nested row keeps the root\'s rows, dims the outside, rails the branch and reveals the focused row', (tester) async {
        await openNested(tester);
        final probe = _TreeProbe(tester);
        probe.model.openAll(const ['asm-1', 'asm-2']);
        await openTree(tester);
        await _TreeProbe(tester).menuAction('asm-1/c1', 'Make Focus');
        await settle(tester);
        await settle(tester);

        final model = _TreeProbe(tester).model;
        expect(model.tree!.partId, 'part-1', reason: 'the tree is still the whole document');
        expect(rowKeys(tester), containsAll(['asm-1', 'asm-1/c1', 'asm-1/c2', 'asm-2', 'asm-2/c1', 'plate']));
        expect(role(tester, 'asm-1/c1'), AssemblyFocusRole.focused);
        expect(role(tester, 'asm-1'), AssemblyFocusRole.ancestor, reason: 'on the way down: context, not dimmed');
        for (final key in ['asm-1/c2', 'asm-2', 'asm-2/c1', 'plate']) {
          expect(role(tester, key), AssemblyFocusRole.outside, reason: key);
        }
        // Drawn: the outside rows are dimmed, the focused branch carries the rail, the way down and the root do not.
        for (final key in ['asm-1/c2', 'asm-2', 'asm-2/c1', 'plate']) {
          expect(find.byKey(ValueKey('tree-dimmed:$key')), findsOneWidget, reason: key);
          expect(find.byKey(ValueKey('tree-focus-rail:$key')), findsNothing, reason: key);
        }
        expect(find.byKey(const ValueKey('tree-focus-rail:asm-1/c1')), findsOneWidget);
        expect(find.byKey(const ValueKey('tree-dimmed:asm-1')), findsNothing);
        expect(find.byKey(const ValueKey('tree-focus-rail:asm-1')), findsNothing);
        // The strip stands for the root row: it is not drawn twice.
        expect(find.byKey(const ValueKey('focus-strip')), findsOneWidget);
        expect(find.byKey(const ValueKey('tree-row:')), findsNothing);
        expect(_TreeProbe(tester).view.focusCrumbs, ['Part 1', model.labelAtPath(['asm-1'])!, model.labelAtPath(['asm-1', 'c1'])!]);
      });

      testWidgets('a crumb pops the focus to that level: two levels at once, or one', (tester) async {
        await openNested(tester);
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await openTree(tester);
        await _TreeProbe(tester).menuAction('asm-1/c1', 'Make Focus');
        await settle(tester);
        expect(focusPath(tester), ['asm-1', 'c1']);

        await tester.tap(find.byKey(const ValueKey('focus-crumb:1')));
        await settle(tester);
        await settle(tester);
        expect(focusPath(tester), ['asm-1']);
        expect(_TreeProbe(tester).model.focusPath, ['asm-1']);

        await _TreeProbe(tester).menuAction('asm-1/c1', 'Make Focus');
        await settle(tester);
        expect(focusPath(tester), ['asm-1', 'c1']);
        await tester.tap(find.byKey(const ValueKey('focus-crumb:0')));
        await settle(tester);
        await settle(tester);
        expect(focusPath(tester), isEmpty, reason: 'the root crumb pops two levels at once');
        expect(find.byKey(const ValueKey('focus-strip')), findsNothing);
        expect(find.byKey(const ValueKey('tree-row:')), findsOneWidget, reason: 'nothing focused: the root row is drawn again');
        expect(_TreeProbe(tester).model.tree!.partId, 'part-1');
      });

      testWidgets('a tap on a dimmed row selects it and offers "Focus here", which pops and pushes the focus to that path', (tester) async {
        await openNested(tester);
        _TreeProbe(tester).model.openAll(const ['asm-1', 'asm-2']);
        await openTree(tester);
        await _TreeProbe(tester).menuAction('asm-1/c1', 'Make Focus');
        await settle(tester);
        expect(find.byKey(const ValueKey('tree-focus-here')), findsNothing, reason: 'nothing outside is selected');

        await _TreeProbe(tester).tapRow('asm-2/c1');
        await settle(tester);
        expect(_TreeProbe(tester).model.selectedKey, 'asm-2/c1');
        expect(find.byKey(const ValueKey('tree-focus-here')), findsOneWidget, reason: 'the row is outside the focus');
        await tester.tap(find.byKey(const ValueKey('tree-focus-here')));
        await settle(tester);
        await settle(tester);
        expect(focusPath(tester), ['asm-2', 'c1'], reason: 'popped out of asm-1 and pushed into asm-2');
        expect(_TreeProbe(tester).model.tree!.partId, 'part-1');
        expect(role(tester, 'asm-2/c1'), AssemblyFocusRole.focused);
        expect(role(tester, 'asm-1/c1'), AssemblyFocusRole.outside);
        expect(find.byKey(const ValueKey('tree-focus-here')), findsNothing, reason: 'the selected row is the focused one now');

        // From the focused row to a row higher up: pops.
        await _TreeProbe(tester).tapRow('plate');
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('tree-focus-here')));
        await settle(tester);
        await settle(tester);
        expect(focusPath(tester), ['plate']);
      });

      testWidgets('Edit Alone re-roots the tree on the target: its subtree only, "in ..." above it and "used 2 x"', (tester) async {
        await openNested(tester);
        await _TreeProbe(tester).menuAction('asm-1', 'Edit Alone');
        await _pumpUntil(tester, () => _TreeProbe(tester).model.tree?.partId == 'sub');
        await settle(tester);
        await openTree(tester);

        final model = _TreeProbe(tester).model;
        expect(model.tree!.partId, 'sub');
        expect(rowKeys(tester), ['', 'c1', 'c2'], reason: 'nothing upstream gets a row');
        expect(find.byKey(const ValueKey('tree-row:')), findsNothing, reason: 'the strip stands for the root row');
        expect(find.byKey(const ValueKey('tree-row:plate')), findsNothing);
        final strip = find.byKey(const ValueKey('edit-alone-pill'));
        expect(find.descendant(of: find.byType(AssemblyTreeView), matching: strip), findsOneWidget);
        expect(find.descendant(of: strip, matching: find.textContaining('Editing', findRichText: true)), findsOneWidget);
        expect(tester.widget<EditAloneStrip>(strip).inLabels, ['Part 1']);
        expect(find.descendant(of: strip, matching: find.byKey(const ValueKey('edit-alone-crumb:0'))), findsOneWidget);
        expect(find.descendant(of: strip, matching: find.text('used 2 \u00D7')), findsOneWidget,
            reason: 'the Part is placed twice (asm-1 and asm-2): an edit changes both');
      });

      testWidgets('a part placed once says nothing about its use', (tester) async {
        await openNested(tester);
        await _TreeProbe(tester).menuAction('plate', 'Edit Alone');
        await settle(tester);
        await settle(tester);
        await openTree(tester);
        expect(find.byKey(const ValueKey('edit-alone-pill')), findsOneWidget);
        expect(find.byKey(const ValueKey('edit-alone-used')), findsNothing);
      });

      testWidgets('a crumb of the Edit Alone line leaves Edit Alone at that level', (tester) async {
        await openNested(tester);
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await _TreeProbe(tester).menuAction('asm-1/c1', 'Edit Alone');
        await _pumpUntil(tester, () => focusPath(tester).length == 2);
        await settle(tester);
        await settle(tester);
        await openTree(tester);
        final strip = tester.widget<EditAloneStrip>(find.byKey(const ValueKey('edit-alone-pill')));
        expect(strip.inLabels.length, 2, reason: 'in Part 1 > the sub-assembly');
        expect(strip.usedCount, 2, reason: "c1's Part is placed under both sub-assemblies");

        // The second crumb: the sub-assembly the target is in.
        await tester.tap(find.byKey(const ValueKey('edit-alone-crumb:1')));
        await settle(tester);
        await settle(tester);
        await settle(tester);
        expect(find.byKey(const ValueKey('edit-alone-pill')), findsNothing, reason: 'Edit Alone is over');
        expect(focusPath(tester), ['asm-1'], reason: 'left at that level: that sub-assembly is focused');
        expect(tester.widget<PartViewport>(find.byType(PartViewport)).soloFocus, isFalse);
        expect(_TreeProbe(tester).model.tree!.partId, 'part-1');
        expect(find.byKey(const ValueKey('focus-strip')), findsOneWidget);

        // And the first: the root.
        await _TreeProbe(tester).menuAction('asm-1/c1', 'Edit Alone');
        await _pumpUntil(tester, () => focusPath(tester).length == 2);
        await settle(tester);
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('edit-alone-crumb:0')));
        await settle(tester);
        await settle(tester);
        await settle(tester);
        expect(find.byKey(const ValueKey('edit-alone-pill')), findsNothing);
        expect(focusPath(tester), isEmpty);
      });

      // Manager review of #406, items 1 and 2: with a deeper focus and no row for it in the backend's tree, the tree is the focused Part's own.
      testWidgets('a focus the backend tree has no row for (assembly-tree failed) roots the tree at the focused Part, and keeps a child selected', (tester) async {
        final backend = await openNested(tester);
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        backend.assemblyTreeMissing = true;
        await switchLens(tester, 'Part');
        await _TreeProbe(tester).menuAction('asm-1', 'Make Focus');
        await settle(tester);
        await settle(tester);
        final model = _TreeProbe(tester).model;
        expect(model.tree!.partId, 'sub', reason: 'rooted at the focused Part, as before B3');
        await _pumpUntil(tester, () => _TreeProbe(tester).model.liveKey != null);
        expect(_TreeProbe(tester).model.liveKey, '', reason: 'the focused Part is the live row');
        expect(rowKeys(tester), containsAll(['c1', 'c2']));
        await _TreeProbe(tester).tapRow('c1');
        await settle(tester);
        expect(_TreeProbe(tester).model.selectedKey, 'c1');
        await switchLens(tester, 'Part');
        await switchLens(tester, 'Assembly');
        await settle(tester);
        expect(_TreeProbe(tester).model.selectedKey, 'c1', reason: 'a refresh does not clear a focus child\'s selection');
      });

      testWidgets("the focused Part's components are never put at the root under another Part's id", (tester) async {
        var failRootOccurrences = false;
        final backend = await openNested(tester, around: (request) async {
          if (failRootOccurrences && request.url.path == '/document/parts/part-1/occurrences' && request.method == 'GET') {
            throw http.ClientException('down');
          }
        });
        failRootOccurrences = true;
        backend.assemblyTreeMissing = true;
        await _TreeProbe(tester).menuAction('asm-1', 'Make Focus');
        await settle(tester);
        await settle(tester);
        final model = _TreeProbe(tester).model;
        expect(model.tree!.partId, isNot('part-1'), reason: "no tree rooted at the root Part holds the focused Part's list");
        expect(rowKeys(tester), isNot(contains('plate')));
        expect(model.tree!.children.map((n) => n.occurrenceId), ['c1', 'c2']);
      });

      testWidgets('"used N x" is not claimed from a tree built from the lists', (tester) async {
        await openNested(tester, configure: (b) => b.assemblyTreeMissing = true);
        await _TreeProbe(tester).menuAction('asm-1', 'Edit Alone');
        await settle(tester);
        await settle(tester);
        await openTree(tester);
        expect(find.byKey(const ValueKey('edit-alone-pill')), findsOneWidget);
        expect(find.byKey(const ValueKey('edit-alone-used')), findsNothing, reason: 'the lists show one level: the count is not known');
      });

      testWidgets('while focused, a component placed twice keeps its <n> in the drawer header', (tester) async {
        await openNested(tester, configure: (b) {
          b.subOccurrences = {
            'sub': [occ('b1', part: 'bolt', ref: 'parts/bolt.didsa'), occ('b2', part: 'bolt', ref: 'parts/bolt.didsa')],
          };
        });
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await _TreeProbe(tester).menuAction('asm-1', 'Make Focus');
        await settle(tester);
        await settle(tester);
        await _TreeProbe(tester).tapRow('asm-1/b2');
        await settle(tester);
        expect(find.descendant(of: find.byType(AssemblyComponentSelectionDrawer), matching: find.text('bolt <2>')), findsWidgets);
      });

      testWidgets('Show on a row outside the focus whose backend flag is hidden PATCHes its parent Part', (tester) async {
        final backend = await openNested(tester, configure: (b) {
          b.subOccurrences['sub']![0]['hidden'] = true;
        });
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await _TreeProbe(tester).menuAction('plate', 'Make Focus');
        await settle(tester);
        final row = _TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'asm-1/c1');
        expect(row.hidden, isTrue);
        _TreeProbe(tester).view.onVisibilityToggle!(row);
        await _pumpUntil(tester, () => backend.subOccurrenceWrites.isNotEmpty);
        await settle(tester);
        expect(backend.subOccurrenceWrites, hasLength(1));
        expect(backend.subOccurrenceWrites.single['part'], 'sub');
        expect(backend.subOccurrenceWrites.single['body'], containsPair('hidden', false));
      });

      testWidgets('Edit Alone on a part shows the strip in the Part lens, over the live part at the root', (tester) async {
        await openNested(tester);
        await _TreeProbe(tester).menuAction('plate', 'Edit Alone');
        await settle(tester);
        await settle(tester);
        await openTree(tester);
        final view = _TreeProbe(tester).view;
        expect(view.title, 'Build Tree', reason: 'a part opens in the Part lens');
        expect(view.editAlone, isNotNull);
        expect(_TreeProbe(tester).model.liveKey, '', reason: 'the target is the root of the re-rooted tree, and live');
        expect(find.descendant(of: find.byType(AssemblyTreeView), matching: find.byKey(const ValueKey('edit-alone-pill'))), findsOneWidget);
        expect(find.byKey(const ValueKey('tree-row:')), findsNothing, reason: 'the strip stands for the root row');
        expect(find.byKey(const ValueKey('tree-row:#planes')), findsOneWidget);
      });
    });

    testWidgets('names read `Bolt <2>` for a Part placed twice, in the tree and in the component drawer alike', (tester) async {
      final backend = _FakeDocumentBackend(seedOccurrences: [
        occ('b1', part: 'bolt', ref: 'parts/bolt.didsa'),
        occ('b2', part: 'bolt', ref: 'parts/bolt.didsa'),
        occ('lone'),
      ]);
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
      await _pumpUntil(tester, () => find.byType(AssemblyTreeView).evaluate().isNotEmpty && _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
      final model = _TreeProbe(tester).model;
      expect(model.labelAtPath(const ['b1']), 'bolt <1>');
      expect(model.labelAtPath(const ['b2']), 'bolt <2>');
      expect(model.labelAtPath(const ['lone']), 'lone-part');

      await _TreeProbe(tester).onOccurrenceTap(_TreeProbe(tester).occurrences.firstWhere((o) => o.id == 'b2'));
      await settle(tester);
      expect(find.text('bolt <2>'), findsWidgets);
    });

    testWidgets('the grouping switch is saved in view preferences (on by default) and read again on the next open', (tester) async {
      await openNested(tester);
      expect(ViewPreferences.assemblyTreeGrouping, isTrue);

      final probe = _TreeProbe(tester);
      probe.model.grouping = false; // what the switch does before it reports
      probe.view.onGroupingChanged!(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect((await SharedPreferences.getInstance()).getBool(ViewPreferences.assemblyTreeGroupingPrefKey), isFalse);
      expect(ViewPreferences.assemblyTreeGrouping, isFalse);

      // A new screen reads it back.
      await tester.pumpWidget(const SizedBox());
      await openNested(tester);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_TreeProbe(tester).model.grouping, isFalse);
      SharedPreferences.setMockInitialValues({});
      await ViewPreferences.load();
    });

    testWidgets('a status answer that arrives after a Fix is dropped: the row keeps what the Fix said', (tester) async {
      var holdStatus = true;
      final release = Completer<void>();
      final backend = _FakeDocumentBackend(seedOccurrences: [occ('plate')]);
      backend.constraintStatus['plate'] = {'status': 'under_constrained', 'dof': 3};
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async {
          final response = backend.handle(request);
          if (holdStatus && request.url.path.endsWith('/assembly-tree') && request.url.queryParameters['status'] == 'true') {
            holdStatus = false; // only the first one
            await release.future;
          }
          return response;
        }),
      );
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
      await _pumpUntil(tester, () => find.byType(AssemblyTreeView).evaluate().isNotEmpty && _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
      // The structure is drawn while the status is still out: the row claims no state (absent, not wrong).
      var row = _TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'plate');
      expect(row.state, AssemblyRowState.none);
      expect(_TreeProbe(tester).model.statusIncluded, isFalse);

      // Fix: the backend now says fixed; the row says so at once and the load that follows carries it.
      backend.constraintStatus['plate'] = {'status': 'fixed', 'dof': 0};
      await _TreeProbe(tester).menuAction('plate', 'Fix');
      await _pumpUntil(tester, () => _TreeProbe(tester).model.statusIncluded);
      await settle(tester);
      row = _TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'plate');
      expect(row.state, AssemblyRowState.fixed);

      // Now the old status answer (computed before the Fix: under-constrained, not fixed) lands.
      release.complete();
      await settle(tester);
      await settle(tester);
      row = _TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'plate');
      expect(row.state, AssemblyRowState.fixed, reason: 'the stale answer is dropped');
      expect(_TreeProbe(tester).model.nodeAtPath(const ['plate'])!.fixed, isTrue);
      expect(_TreeProbe(tester).constraintStatusByOccurrenceId['plate']!.state, ConstraintState.fixed);
    });

    testWidgets('a structure answer that arrives after a Fix is dropped too', (tester) async {
      Completer<void>? release;
      var holdNextStructure = false;
      final backend = _FakeDocumentBackend(seedOccurrences: [occ('plate')]);
      final documentApi = DocumentApiClient(
        httpClient: MockClient((request) async {
          final response = backend.handle(request);
          if (holdNextStructure && request.url.path.endsWith('/assembly-tree') && request.url.queryParameters['status'] != 'true') {
            holdNextStructure = false;
            release = Completer<void>();
            await release!.future;
          }
          return response;
        }),
      );
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
      await _pumpUntil(tester, () => find.byType(AssemblyTreeView).evaluate().isNotEmpty && _TreeProbe(tester).model.tree?.children.isNotEmpty == true);

      // Hide starts a reload whose structure answer is held (it is computed after the Hide, before the Fix).
      holdNextStructure = true;
      await _TreeProbe(tester).menuAction('plate', 'Hide');
      await _pumpUntil(tester, () => release != null);
      // Fix while that is out: its own reload answers at once.
      await _TreeProbe(tester).menuAction('plate', 'Fix');
      await _pumpUntil(tester, () => (_TreeProbe(tester).model.nodeAtPath(const ['plate'])?.fixed ?? false) && backend.occurrences.single['fixed'] == true);
      await settle(tester);
      expect(_TreeProbe(tester).model.nodeAtPath(const ['plate'])!.fixed, isTrue);

      final requestsBefore = backend.assemblyTreeRequests.length;
      release!.complete();
      await settle(tester);
      await settle(tester);
      // A dropped answer starts nothing: no status call follows it (one that was applied would ask for its status and heal the row).
      expect(backend.assemblyTreeRequests.length, requestsBefore);
      final node = _TreeProbe(tester).model.nodeAtPath(const ['plate'])!;
      expect(node.fixed, isTrue, reason: 'the older structure answer (not fixed) was dropped');
      expect(node.hidden, isTrue);
    });

    testWidgets('review: a nested pick at the document root is named by its tree label, not its raw id, in the selection panels', (tester) async {
      await openNested(tester);
      tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
            const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'asm-1/c1'),
          );
      await settle(tester);
      // The Part lens's selection list reads the same names (the tree's own row, off screen, also says it).
      await switchLens(tester, 'Part');
      await settle(tester);
      expect(find.descendant(of: find.byType(SelectionListDrawer), matching: find.textContaining('c1-part')), findsWidgets);
    });

    testWidgets('review: a nested row hidden at the root reads hidden after Make Focus into its parent; Show drops it and PATCHes nothing', (tester) async {
      final backend = await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1']);
      probe.view.onVisibilityToggle!(probe.model.visibleRows().firstWhere((r) => r.key == 'asm-1/c1'));
      await settle(tester);
      expect(instanceHidden(tester, ['asm-1', 'c1']), isTrue);

      await _TreeProbe(tester).menuAction('asm-1', 'Make Focus');
      await settle(tester);
      // B3: the tree is still the document's, so the row keeps its key.
      expect(_TreeProbe(tester).model.focusPath, ['asm-1']);
      final row = _TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'asm-1/c1');
      expect(row.hidden, isTrue, reason: 'hidden for this session, whatever the focus');

      _TreeProbe(tester).view.onVisibilityToggle!(row);
      await settle(tester);
      expect(backend.subOccurrenceWrites, isEmpty, reason: 'Show drops the session hide; nothing is written');
      expect(instanceHidden(tester, ['asm-1', 'c1']), isFalse);
      expect(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == 'asm-1/c1').hidden, isFalse);
    });

    testWidgets('review: a backend without assembly-tree still has its constraint status read', (tester) async {
      final backend = _FakeDocumentBackend(seedOccurrences: [occ('plate')]);
      backend.assemblyTreeMissing = true;
      backend.constraintStatus['plate'] = {'status': 'under_constrained', 'dof': 3, 'rigid_set': 'plate'};
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          initialLens: AssemblyLens.assembly,
        ),
      ));
      await _pumpUntil(tester, () => backend.constraintStatusRequests > 0);
      expect(backend.constraintStatusRequests, greaterThan(0));
    });

    testWidgets('review: Edit Alone from a nested row pushes every level, and Done ends it from there', (tester) async {
      await openNested(tester);
      final probe = _TreeProbe(tester);
      probe.model.openAll(const ['asm-1']);
      await probe.menuAction('asm-1/c1', 'Edit Alone');
      await _pumpUntil(tester, () => tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath.length == 2);
      await settle(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath, ['asm-1', 'c1']);
      await tester.tap(find.byKey(const ValueKey('edit-alone-done')).first);
      await settle(tester);
      await settle(tester);
      expect(tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath, isEmpty);
    });

    testWidgets('review: any failure of the tree call (not only an ApiException) falls back to the lists', (tester) async {
      await openNested(tester, around: (request) async {
        if (request.url.path.endsWith('/assembly-tree')) throw StateError('boom');
      });
      expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'plate']);
    });

    testWidgets('review: a tap on a folder row keeps its mark (the screen only overwrites the selection when its own changed)', (tester) async {
      final backend = _FakeDocumentBackend(seedOccurrences: [occ('plate')], seedMates: [
        {'id': 'm1', 'type': 'coincident', 'references': <dynamic>[], 'suppressed': false, 'flipped': false, 'allow_rotation': true},
      ]);
      final documentApi = DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)));
      final sketchBackend = _FakeSketchBackend();
      await tester.pumpWidget(MaterialApp(
        home: PartScreen(
          documentApi: documentApi,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          initialLens: AssemblyLens.assembly,
        ),
      ));
      await _pumpUntil(tester, () => find.byType(AssemblyTreeView).evaluate().isNotEmpty && _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
      final probe = _TreeProbe(tester);
      probe.model.selectedKey = '#mates'; // what the view does on the tap
      probe.view.onRowTap!(probe.model.visibleRows().firstWhere((r) => r.key == '#mates'));
      await settle(tester);
      await settle(tester);
      expect(_TreeProbe(tester).model.selectedKey, '#mates');
    });

    testWidgets('review: Delete at the document root asks for no whole-tree count', (tester) async {
      final backend = await openNested(tester);
      final before = backend.assemblyTreeRequests.length;
      await _TreeProbe(tester).menuAction('plate', 'Delete');
      expect(find.textContaining('used'), findsNothing);
      expect(backend.assemblyTreeRequests.length, before);
    });

    testWidgets('a backend without the endpoint still shows its components, one level', (tester) async {
      final backend = _FakeDocumentBackend(seedOccurrences: [occ('plate'), occ('lid')]);
      backend.assemblyTreeMissing = true;
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
      await _pumpUntil(tester, () => find.byType(AssemblyTreeView).evaluate().isNotEmpty && _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
      expect(rowKeys(tester), ['', 'plate', 'lid']);
    });

    // B2: remembered open rows (spec section 12).
    group('remembered open rows', () {
      Completer<void>? gate;

      /// Holds the first answer of `assembly-tree` without `status` (the structure) until [gate] completes.
      Future<void> holdStructure(http.Request request) async {
        if (gate != null && request.url.path.endsWith('/assembly-tree') && request.url.queryParameters['status'] != 'true') {
          await gate!.future;
        }
      }

      Future<void> closeScreen(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }

      /// A header button of the tree, pressed as the person would (the floating tree is slid off the screen while closed, so it is called, not tapped).
      void pressTreeButton(WidgetTester tester, String key) => tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed!();

      Future<List<String>?> storedKey(WidgetTester tester, String key) async {
        final keys = await tester.runAsync(() => AssemblyTreeOpenStore.read(key));
        return keys;
      }

      Future<List<String>?> stored(WidgetTester tester, String path) => storedKey(tester, 'file:$path');

      setUp(() {
        SharedPreferences.setMockInitialValues({});
        _TreeProbe.lastModel = null;
      });
      tearDown(() => gate = null);

      testWidgets('open rows survive closing the document and opening it again; another document does not get them', (tester) async {
        await openNested(tester, filePath: '/docs/a.didsa');
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await tester.pump();
        expect(await stored(tester, '/docs/a.didsa'), ['asm-1']);
        await closeScreen(tester);

        await openNested(tester, filePath: '/docs/a.didsa');
        expect(rowKeys(tester), ['', 'asm-1', 'asm-1/c1', 'asm-1/c2', 'asm-2', 'plate'], reason: 'the same document: its rows are open again');
        expect(_TreeProbe(tester).model.selectedKey, isNull, reason: 'restoring does not select anything');
        expect(_TreeProbe(tester).model.openKeysTouched, isFalse);
        await closeScreen(tester);

        await openNested(tester, filePath: '/docs/b.didsa');
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'plate'], reason: 'another document starts collapsed');
        await closeScreen(tester);

        await openNested(tester); // no file yet: nothing to remember under
        _TreeProbe(tester).model.openAll(const ['asm-2']);
        await tester.pump();
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'asm-2/c1', 'asm-2/c2', 'plate']);
        expect(await tester.runAsync(() async => (await SharedPreferences.getInstance()).getKeys().where((k) => k.contains('asm-2'))), isEmpty);
      });

      testWidgets('keys of rows that are gone are dropped from what is restored, and a refresh of the same tree does not restore again', (tester) async {
        SharedPreferences.setMockInitialValues({
          'assembly_tree_open:file:/docs/a.didsa': jsonEncode(['asm-1', 'gone', 'asm-2/c1#feature:f1', 'plate', '']),
        });
        final backend = await openNested(tester, filePath: '/docs/a.didsa');
        expect(_TreeProbe(tester).model.openKeys, {'asm-1'});

        // The person closes it; a later load of the same tree (the lens switched away and back) must not open it again.
        _TreeProbe(tester).model.setOpen('asm-1', false);
        await tester.pump();
        final before = backend.assemblyTreeRequests.length;
        await switchLens(tester, 'Part');
        await switchLens(tester, 'Assembly');
        await _pumpUntil(tester, () => backend.assemblyTreeRequests.length >= before + 2);
        expect(backend.assemblyTreeRequests.length, greaterThanOrEqualTo(before + 2), reason: 'the tree was loaded again');
        await settle(tester);
        expect(_TreeProbe(tester).model.openKeys, isEmpty);
      });

      testWidgets('collapse all and expand to selection are stored, and the stored rows come back', (tester) async {
        await openNested(tester, filePath: '/docs/a.didsa');
        final probe = _TreeProbe(tester);
        probe.model.openAll(const ['asm-1', 'asm-2']);
        await tester.pump();
        expect(await stored(tester, '/docs/a.didsa'), unorderedEquals(['asm-1', 'asm-2']));

        await probe.tapRow('asm-2/c1');
        await settle(tester);
        pressTreeButton(tester, 'tree-collapse-all');
        await tester.pump();
        // Collapse all keeps the selected row listed (its ancestors reopen), so that is what is remembered.
        expect(await stored(tester, '/docs/a.didsa'), ['asm-2']);
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'asm-2/c1', 'asm-2/c2', 'plate']);

        probe.model.setOpen('asm-2', false);
        await tester.pump();
        expect(await stored(tester, '/docs/a.didsa'), isEmpty, reason: 'everything collapsed is remembered too');
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'plate']);

        pressTreeButton(tester, 'tree-expand-to-selection');
        await tester.pump();
        await tester.pump();
        expect(await stored(tester, '/docs/a.didsa'), ['asm-2']);
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'asm-2/c1', 'asm-2/c2', 'plate']);
        expect(_TreeProbe(tester).model.selectedKey, 'asm-2/c1');
      });

      testWidgets('a tree answer for the previous document is dropped: it neither opens its rows in the new one nor stores over it', (tester) async {
        SharedPreferences.setMockInitialValues({
          'assembly_tree_open:file:/docs/a.didsa': jsonEncode(['asm-1']),
          'assembly_tree_open:file:/docs/b.didsa': jsonEncode(['asm-2']),
        });
        gate = Completer<void>();
        await openNested(tester, filePath: '/docs/a.didsa', around: holdStructure, waitForTree: false);
        await tester.pump(const Duration(milliseconds: 200));
        expect(_TreeProbe(tester).model.tree?.children ?? const [], isEmpty, reason: 'document A has not heard back yet (P2: the part\'s own root is there)');

        // The person opens document B in its place (a new screen: the previous document's state is gone).
        await closeScreen(tester);
        final late = gate!;
        gate = null;
        await openNested(tester, filePath: '/docs/b.didsa');
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'asm-2/c1', 'asm-2/c2', 'plate'], reason: 'B has its own rows, not A\'s');

        late.complete(); // A's answer lands now
        await settle(tester);
        await settle(tester);
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'asm-2/c1', 'asm-2/c2', 'plate']);
        expect(await stored(tester, '/docs/a.didsa'), ['asm-1']);
        expect(await stored(tester, '/docs/b.didsa'), ['asm-2']);
      });

      testWidgets('an older load that lands after a newer one changes nothing: rows the person closed after the restore stay closed', (tester) async {
        SharedPreferences.setMockInitialValues({'assembly_tree_open:file:/docs/a.didsa': jsonEncode(['asm-1'])});
        var held = 0;
        final first = Completer<void>();
        Future<void> holdFirst(http.Request request) async {
          if (request.url.path.endsWith('/assembly-tree') && request.url.queryParameters['status'] != 'true' && held++ == 0) await first.future;
        }

        await openNested(tester, filePath: '/docs/a.didsa', around: holdFirst, waitForTree: false);
        await tester.pump(const Duration(milliseconds: 200));
        // A second load (the lens switched away and back) answers first, and restores.
        await switchLens(tester, 'Part');
        await switchLens(tester, 'Assembly');
        await _pumpUntil(tester, () => _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
        expect(_TreeProbe(tester).model.openKeys, {'asm-1'});
        _TreeProbe(tester).model.setOpen('asm-1', false);
        await tester.pump();

        first.complete();
        await settle(tester);
        await settle(tester);
        expect(_TreeProbe(tester).model.openKeys, isEmpty, reason: 'the first load is stale now');
        expect(await stored(tester, '/docs/a.didsa'), isEmpty);
      });

      testWidgets('what the person opened or closed before the first answer is kept, and stored over the old rows', (tester) async {
        SharedPreferences.setMockInitialValues({'assembly_tree_open:file:/docs/a.didsa': jsonEncode(['asm-1'])});
        gate = Completer<void>();
        await openNested(tester, filePath: '/docs/a.didsa', around: holdStructure, waitForTree: false);
        await tester.pump(const Duration(milliseconds: 200));
        expect(_TreeProbe(tester).model.tree?.children ?? const [], isEmpty);

        // Before anything is listed the person asks for everything collapsed.
        pressTreeButton(tester, 'tree-collapse-all');
        await tester.pump();
        gate!.complete();
        await _pumpUntil(tester, () => _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
        await settle(tester);
        expect(_TreeProbe(tester).model.openKeys, isEmpty, reason: 'the stored asm-1 does not overwrite the person\'s collapse all');
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'plate']);
        expect(await stored(tester, '/docs/a.didsa'), isEmpty);
      });

      testWidgets('an open made before the first answer is kept and not merged with the stored rows', (tester) async {
        SharedPreferences.setMockInitialValues({'assembly_tree_open:file:/docs/a.didsa': jsonEncode(['asm-1'])});
        gate = Completer<void>();
        await openNested(tester, filePath: '/docs/a.didsa', around: holdStructure, waitForTree: false);
        await tester.pump(const Duration(milliseconds: 200));
        _TreeProbe(tester).model.setOpen('asm-2', true);
        gate!.complete();
        await _pumpUntil(tester, () => _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
        await settle(tester);
        expect(_TreeProbe(tester).model.openKeys, {'asm-2'});
        expect(await stored(tester, '/docs/a.didsa'), ['asm-2']);
      });

      testWidgets('a project-shaped document (opened through its project folder and root file, not a file path) remembers its rows', (tester) async {
        const root = DesktopProjectRoot('/fake/project');
        const key = 'project:/fake/project|top.didsa';
        await openNested(tester, projectRoot: root, relativePaths: const {'part-1': 'top.didsa'});
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await tester.pump();
        expect(await storedKey(tester, key), ['asm-1']);
        await closeScreen(tester);

        await openNested(tester, projectRoot: root, relativePaths: const {'part-1': 'top.didsa'});
        expect(_TreeProbe(tester).model.openKeys, {'asm-1'}, reason: 'the same project file: its rows are open again');
        await closeScreen(tester);

        await openNested(tester, projectRoot: root, relativePaths: const {'part-1': 'other.didsa'});
        expect(_TreeProbe(tester).model.openKeys, isEmpty, reason: 'another file of the project');
      });

      testWidgets('a document known only by a bare file name stores nothing (the same name in two folders would share rows)', (tester) async {
        await openNested(tester, fileName: 'a.didsa');
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await tester.pump();
        final keys = await tester.runAsync(() async => (await SharedPreferences.getInstance()).getKeys().where((k) => k.startsWith('assembly_tree_open')));
        expect(keys, isEmpty);
      });

      testWidgets('an expand to selection that opens nothing, before the first answer, does not stop the restore', (tester) async {
        SharedPreferences.setMockInitialValues({'assembly_tree_open:file:/docs/a.didsa': jsonEncode(['asm-1'])});
        gate = Completer<void>();
        await openNested(tester, filePath: '/docs/a.didsa', around: holdStructure, waitForTree: false);
        await tester.pump(const Duration(milliseconds: 200));
        expect(_TreeProbe(tester).model.tree?.children ?? const [], isEmpty);

        expect(_TreeProbe(tester).model.expandToSelection(), isFalse, reason: 'no tree, nothing selected: nothing to open');
        gate!.complete();
        await _pumpUntil(tester, () => _TreeProbe(tester).model.tree?.children.isNotEmpty == true);
        await settle(tester);
        expect(_TreeProbe(tester).model.openKeys, {'asm-1'}, reason: 'the stored rows were restored, not overwritten with none');
        expect(await stored(tester, '/docs/a.didsa'), ['asm-1']);
      });

      testWidgets('Save As keeps the restored rows for the copy, though the person touched nothing; the copy opens with them', (tester) async {
        final storage = _FakeStorageService();
        SharedPreferences.setMockInitialValues({
          'assembly_tree_open:project:/fake/project|top.DIDSAprt': jsonEncode(['asm-1']),
        });
        await openNested(tester, projectRoot: storage.root, relativePaths: const {'part-1': 'top.DIDSAprt'}, storage: storage, configure: (b) {
          // No file to look for, so the reopened copy keeps these components as they are.
          for (final o in [...b.occurrences, for (final l in b.subOccurrences.values) ...l]) {
            o['external_ref'] = null;
          }
        });
        expect(_TreeProbe(tester).model.openKeys, {'asm-1'}, reason: 'restored');
        expect(_TreeProbe(tester).model.openKeysTouched, isFalse);

        tester.widget<PartToolbar>(find.byType(PartToolbar)).onSaveAsNative!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.enterText(find.byType(TextFormField), 'copy.DIDSAprt');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.widgetWithText(FilledButton, 'Save As'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(storage.files.keys, contains('copy.DIDSAprt'));
        // The copy opens in its own screen; its first answer stores what it restored (its tree has the same components, so the rows stay).
        expect(await storedKey(tester, 'project:/fake/project|copy.DIDSAprt'), ['asm-1'], reason: 'the rows follow the document to its new file');
        await closeScreen(tester);

        // What the reopened copy is handed: its project folder and its root file.
        await openNested(tester, projectRoot: storage.root, relativePaths: const {'part-1': 'copy.DIDSAprt'});
        expect(_TreeProbe(tester).model.openKeys, {'asm-1'});
      });

      testWidgets('a document opened by name, then Create Component, stores nothing: the root Create Component picks up is not where the document is', (tester) async {
        final storage = _FakeStorageService();
        await openNested(tester, fileName: 'a.didsa', storage: storage);
        await tapStartCommand(tester, 'Create Component');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final keys = await tester.runAsync(() async => (await SharedPreferences.getInstance()).getKeys().where((k) => k.startsWith('assembly_tree_open')));
        expect(keys, isEmpty, reason: 'no key the next session could compute again');
      });

      testWidgets('Save All of a new document keys its rows by the file it wrote; reopening that file opens them', (tester) async {
        final storage = _FakeStorageService();
        await openNested(tester, storage: storage);
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await tester.pump();
        expect(await tester.runAsync(() async => (await SharedPreferences.getInstance()).getKeys().where((k) => k.startsWith('assembly_tree_open'))), isEmpty,
            reason: 'no file yet: nothing to key by');

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
        expect(storage.files.keys, contains('top.DIDSAprt'));

        expect(await storedKey(tester, 'project:/fake/project|top.DIDSAprt'), ['asm-1'], reason: 'the rows follow the document to the file it was just written to');
        await closeScreen(tester);

        await openNested(tester, projectRoot: storage.root, relativePaths: const {'part-1': 'top.DIDSAprt'});
        expect(_TreeProbe(tester).model.openKeys, {'asm-1'});
      });

      /// A right click on the top-level component [id] in the viewport, and the menu's entry [label] (null: only look at the menu).
      Future<void> viewportMenu(WidgetTester tester, String id, String? label) async {
        tester.widget<PartViewport>(find.byType(PartViewport)).onContextMenuRequested!(
              HoverHit(entity: SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: id), rayT: 1),
              const Offset(600, 400),
            );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 100));
        if (label == null) return;
        await tester.tap(find.descendant(of: find.byType(PopupMenuItem<ComponentContextMenuAction>), matching: find.text(label)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
      }

      testWidgets('desktop, pane hidden, an older selection in the tree: Expand to selection works from the pressed row, not the older one', (tester) async {
        await openNested(tester, filePath: '/docs/a.didsa', layout: LayoutModeController(preference: LayoutPreference.desktop, windowSize: const Size(1280, 800), mouseActive: true));
        // An older selection, nested: a pick in 3D opens its branch.
        tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
              const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'asm-2/c1'),
            );
        await settle(tester);
        expect(_TreeProbe(tester).model.selectedKey, 'asm-2/c1');
        final pane = find.byKey(const ValueKey('desktop-left-pane'));
        await tester.tap(find.byTooltip('Hide the tree'));
        await tester.pump();
        expect(pane, findsNothing, reason: 'folded away: the tree is not built, so its selection is not kept up to date');
        final model = _TreeProbe.lastModel!;
        model.setOpen('asm-2', false);
        expect(model.selectedKey, 'asm-2/c1', reason: 'the stale selection the menu must not use');

        await viewportMenu(tester, 'asm-1', 'Expand to selection');
        expect(pane, findsOneWidget, reason: 'the tree comes back, or nothing is seen to happen');
        expect(_TreeProbe(tester).model.selectedKey, 'asm-1', reason: 'the pressed row, as the tree would show it');
        expect(_TreeProbe(tester).model.isOpen('asm-2'), isFalse, reason: 'the older selection is not revealed');
        expect(await stored(tester, '/docs/a.didsa'), isEmpty, reason: 'and what is stored is what is open');
      });

      testWidgets('the Part lens: the menu has no Expand to selection (no tree to show)', (tester) async {
        await openNested(tester);
        await switchLens(tester, 'Part');
        await viewportMenu(tester, 'asm-1', null);
        expect(find.descendant(of: find.byType(PopupMenuItem<ComponentContextMenuAction>), matching: find.text('Zoom to selection')), findsOneWidget, reason: 'the menu is open');
        expect(find.text('Expand to selection'), findsNothing);
      });

      testWidgets('Expand to selection in the 3D menu opens a closed tree first (the phone\'s overlay)', (tester) async {
        await openNested(tester);
        tester.widget<PartViewport>(find.byType(PartViewport)).onSelectionToggle!(
              const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'asm-2/c1'),
            );
        await settle(tester);
        final probe = _TreeProbe(tester);
        expect(probe.view.visible, isFalse, reason: 'the overlay is closed');

        await probe.menuAction('asm-2/c1', 'Expand to selection');
        await settle(tester);
        expect(_TreeProbe(tester).view.visible, isTrue, reason: 'it opens, or nothing is seen to happen');
        expect(_TreeProbe(tester).model.selectedKey, 'asm-2/c1');
      });

      testWidgets('a document that was set up survives any number of untouched opens of others: an open writes nothing', (tester) async {
        final before = AssemblyTreeOpenStore.maxDocuments;
        AssemblyTreeOpenStore.maxDocuments = 3;
        addTearDown(() => AssemblyTreeOpenStore.maxDocuments = before);
        await tester.runAsync(() => AssemblyTreeOpenStore.write('file:/docs/keep.didsa', ['asm-1']));
        for (var i = 0; i < 5; i++) {
          await openNested(tester, filePath: '/docs/other$i.didsa');
          await closeScreen(tester);
        }
        expect(await stored(tester, '/docs/keep.didsa'), ['asm-1'], reason: 'five untouched opens, room for three documents');
        final index = await tester.runAsync(() async => (await SharedPreferences.getInstance()).getStringList('assembly_tree_open_documents'));
        expect(index, ['file:/docs/keep.didsa']);

        // A document that was opened and changed does count.
        await openNested(tester, filePath: '/docs/other.didsa');
        _TreeProbe(tester).model.openAll(const ['asm-1']);
        await tester.pump();
        expect(await stored(tester, '/docs/other.didsa'), ['asm-1']);
      });

      testWidgets('a Save As before the first tree answer moves the stored rows to the copy, and stores no defaults in their place', (tester) async {
        final storage = _FakeStorageService();
        const keyA = 'assembly_tree_open:project:/fake/project|top.DIDSAprt';
        const keyB = 'assembly_tree_open:project:/fake/project|copy.DIDSAprt';
        SharedPreferences.setMockInitialValues({keyA: jsonEncode(['asm-1'])});
        gate = Completer<void>();
        final held = gate!;
        await openNested(tester, projectRoot: storage.root, relativePaths: const {'part-1': 'top.DIDSAprt'}, storage: storage, around: holdStructure, waitForTree: false, configure: (b) {
          for (final o in [...b.occurrences, for (final l in b.subOccurrences.values) ...l]) {
            o['external_ref'] = null;
          }
        });
        await tester.pump(const Duration(milliseconds: 200));
        expect(_TreeProbe(tester).model.tree?.children ?? const [], isEmpty, reason: 'the first answer is held (P2: the part\'s own root is there)');
        gate = null; // the copy's own screen is not held

        tester.widget<PartToolbar>(find.byType(PartToolbar)).onSaveAsNative!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.enterText(find.byType(TextFormField), 'copy.DIDSAprt');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.widgetWithText(FilledButton, 'Save As'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(storage.files.keys, contains('copy.DIDSAprt'));

        held.complete(); // the first screen's answer lands now (it was replaced by the copy's screen)
        await settle(tester);
        await settle(tester);
        Future<String?> raw(String key) async => await tester.runAsync<String?>(() async => (await SharedPreferences.getInstance()).getString(key));
        expect(await raw(keyB), '["asm-1"]', reason: 'the copy has the rows of the document it was saved from');
        expect(await raw(keyA), '["asm-1"]', reason: 'and the original keeps its own');
      });

      testWidgets('a tree built from the lists (the endpoint failed) neither restores nor stores', (tester) async {
        SharedPreferences.setMockInitialValues({'assembly_tree_open:file:/docs/a.didsa': jsonEncode(['asm-1'])});
        await openNested(tester, filePath: '/docs/a.didsa', configure: (b) => b.assemblyTreeMissing = true);
        expect(_TreeProbe(tester).model.openKeys, isEmpty);
        _TreeProbe(tester).model.setOpen('asm-2', true);
        await tester.pump();
        expect(await stored(tester, '/docs/a.didsa'), ['asm-1'], reason: 'a one-level tree must not rewrite what the real tree remembered');
      });
    });

    // P2 (`docs/assembly-tree-overhaul-scope.md` 10.6): the Part lens draws the one tree. A part opened alone is the live root; inside an
    // assembly the focused Part is live; a tap selects (Edit is the bar's, a double-tap's and the menu's).
    group('Build tree (P2)', () {
      final partFeatures = <Map<String, dynamic>>[
        {'type': 'sketch', 'id': 'feature-1', 'sketch_id': 'sketch-1', 'locked': true, 'produces': 'sketch'},
        {
          'type': 'extrude', 'id': 'feature-2', 'sketch_feature_id': 'feature-1', 'extrude_type': 'boss', 'start_distance': 0.0,
          'end_distance': 10.0, 'locked': true, 'produces': 'body',
        },
        {
          'type': 'create_plane', 'id': 'feature-3', 'locked': false, 'produces': 'plane', 'origin': [0.0, 0.0, 5.0],
          'normal': [0.0, 0.0, 1.0], 'x_axis': [1.0, 0.0, 0.0], 'y_axis': [0.0, 1.0, 0.0],
        },
      ];

      /// A part on its own (no components), in the Part lens, with its tree open. [around] sees each answer and may hold it.
      Future<_FakeDocumentBackend> openPart(WidgetTester tester,
          {List<Map<String, dynamic>>? features,
          String? filePath,
          Future<void> Function(http.Request request)? around,
          List<Map<String, dynamic>> extraBodies = const [],
          bool desktop = false,
          bool openTree = true,
          void Function(_FakeDocumentBackend backend)? configure}) async {
        final backend = _FakeDocumentBackend(seedFeatures: [for (final f in features ?? partFeatures) {...f}])
          ..meshBodies = [
            {'body_id': 'feature-2', 'source': 'computed', 'mesh': _FakeDocumentBackend._placeholderMesh},
            ...extraBodies,
          ];
        configure?.call(backend);
        final documentApi = DocumentApiClient(
          httpClient: MockClient((request) async {
            final response = backend.handle(request);
            if (around != null) await around(request);
            return response;
          }),
        );
        final sketchBackend = _FakeSketchBackend();
        Widget screen = PartScreen(
          documentApi: documentApi,
          initialFilePath: filePath,
          sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
        );
        if (desktop) {
          tester.view.physicalSize = const Size(1280, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          screen = LayoutModeScope(
            controller: LayoutModeController(preference: LayoutPreference.desktop, windowSize: const Size(1280, 800), mouseActive: true),
            child: screen,
          );
        }
        await tester.pumpWidget(MaterialApp(home: screen));
        await _pumpUntil(tester, () => _TreeProbe(tester).model.liveKey != null);
        if (openTree) {
          await tester.tap(find.byTooltip('Feature tree'));
          await settle(tester);
        }
        return backend;
      }

      PartViewport viewport(WidgetTester tester) => tester.widget<PartViewport>(find.byType(PartViewport));

      testWidgets('a part opened alone: the part is the live root, its folders then its features in build order', (tester) async {
        await openPart(tester);
        final probe = _TreeProbe(tester);
        expect(probe.view.title, 'Build Tree');
        expect(probe.model.liveKey, '');
        expect(rowKeys(tester), ['', '#bodies', '#planes', '#feature:feature-1', '#feature:feature-2', '#feature:feature-3']);
        final rows = {for (final r in probe.model.visibleRows()) r.key: r};
        expect(rows['#bodies']!.kind, AssemblyRowKind.bodiesFolder);
        expect(rows['#bodies']!.open, isFalse, reason: 'folders start collapsed');
        expect(rows['#feature:feature-2']!.label, 'Extrude 1');
        expect(rows['#feature:feature-2']!.type, 'extrude');
        await _tapTreeRow(tester, 'Bodies');
        await _tapTreeRow(tester, 'Planes');
        expect(rowKeys(tester), [
          '', '#bodies', '#body:feature-2', '#planes', '#plane:xy', '#plane:xz', '#plane:yz', '#plane:feature:feature-3',
          '#feature:feature-1', '#feature:feature-2', '#feature:feature-3',
        ]);
        expect(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('Body 1')), findsOneWidget);
      });

      testWidgets('a tap selects the feature and highlights what it made; it opens no panel and rolls nothing back', (tester) async {
        final backend = await openPart(tester);
        final meshCalls = backend.meshRequests.length;
        await _tapTreeRow(tester, 'Extrude 1');
        await settle(tester);
        expect(_TreeProbe(tester).model.selectedKey, '#feature:feature-2');
        expect(viewport(tester).selectedEntities, {const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'feature-2')});
        expect(find.byType(ExtrudePanel), findsNothing);
        expect(backend.meshRequests.length, meshCalls, reason: 'no rollback');
        // The phone bar of a feature row.
        expect(find.byKey(const ValueKey('tree-bar-edit')), findsOneWidget);
        expect(find.byKey(const ValueKey('tree-bar-hide')), findsOneWidget);
        expect(find.byKey(const ValueKey('tree-bar-more')), findsOneWidget);
        expect(find.byKey(const ValueKey('tree-bar-rollback')), findsNothing, reason: 'no rollback point exists to set yet (#17)');

        // A plane feature highlights its plane; a body row its body.
        await _tapTreeRow(tester, 'Plane 1');
        expect(viewport(tester).selectedEntities,
            {const SelectionEntityRef(kind: SelectionEntityKind.createPlane, planeFeatureId: 'feature-3')});
        await _tapTreeRow(tester, 'Bodies');
        await _tapTreeRow(tester, 'Body 1');
        expect(_TreeProbe(tester).model.selectedKey, '#body:feature-2');
        expect(viewport(tester).selectedEntities, {const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'feature-2')});
        expect(find.byKey(const ValueKey('tree-bar-zoom')), findsOneWidget);
        expect(find.byKey(const ValueKey('tree-bar-edit')), findsNothing);
      });

      testWidgets('Edit from the bar opens the panel at the rollback point; a double-tap edits too', (tester) async {
        final backend = await openPart(tester);
        await _editFromTree(tester, 'Extrude 1');
        await settle(tester);
        expect(find.byType(ExtrudePanel), findsOneWidget);
        expect(backend.meshRequests.last['rollback_excluded_feature_ids'], 'feature-3', reason: 'rolled back to Extrude 1');
        await tester.pump(const Duration(milliseconds: 600));
      });

      testWidgets('a double-tap on a feature row is Edit, without the bar', (tester) async {
        await openPart(tester);
        final row = find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('Extrude 1'));
        await tester.tap(row);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(row);
        await settle(tester);
        expect(find.byType(ExtrudePanel), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 600));
      });

      testWidgets('Hide from the bar, on a feature and on a body (through its feature)', (tester) async {
        final backend = await openPart(tester);
        await _tapTreeRow(tester, 'Sketch 1');
        await tester.tap(find.byKey(const ValueKey('tree-bar-hide')));
        await settle(tester);
        expect(backend.hiddenByPart['part-1'], {'feature-1'});
        expect(find.byKey(const ValueKey('tree-eye-off:#feature:feature-1')), findsOneWidget);
        expect(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == '#feature:feature-1').state, AssemblyRowState.hidden);

        await _tapTreeRow(tester, 'Bodies');
        await _tapTreeRow(tester, 'Body 1');
        await tester.tap(find.byKey(const ValueKey('tree-bar-hide')));
        await settle(tester);
        await settle(tester);
        expect(backend.hiddenByPart['part-1'], {'feature-1', 'feature-2'});
        expect(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == '#body:feature-2').hidden, isTrue);
        // Show again from the same bar.
        await tester.tap(find.byKey(const ValueKey('tree-bar-hide')));
        await settle(tester);
        await settle(tester);
        expect(backend.hiddenByPart['part-1'], {'feature-1'});
      });

      testWidgets('a default plane: its long-press offers Hide / Show only; its tap opens the plane sheet', (tester) async {
        final backend = await openPart(tester);
        await _tapTreeRow(tester, 'Planes');
        await tester.longPress(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('XZ plane')));
        await _settleSheet(tester);
        expect(find.text('Delete'), findsNothing, reason: 'a default plane is not a feature');
        // The planes hid themselves when the first body appeared: the menu offers Show.
        expect(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == '#plane:xz').hidden, isTrue);
        await tester.tap(find.widgetWithText(ListTile, 'Show'));
        await settle(tester);
        await settle(tester);
        expect(backend.visibilityRequests.last, containsPair('reference_plane_ids', ['XZ']));
        expect(backend.visibilityRequests.last, containsPair('hidden', false));
        expect(_TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == '#plane:xz').hidden, isFalse);

        await tester.tap(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('XY plane')));
        await _settleSheet(tester);
        expect(find.text('New Sketch on XY'), findsOneWidget, reason: 'the plane sheet, as a tap on the plane in the viewport');
        expect(_TreeProbe(tester).model.selectedKey, '#plane:xy');
      });

      testWidgets("Extrude's sketch picker is the tree's picker: ineligible rows locked with the reason, the sketch picked", (tester) async {
        await openPart(tester, openTree: false);
        await tapStartCommand(tester, 'Extrude');
        final model = _TreeProbe(tester).model;
        expect(model.picker, isNotNull);
        expect(find.byKey(const ValueKey('tree-picker-banner')), findsOneWidget);
        expect(find.byKey(const ValueKey('tree-selection-bar')), findsNothing, reason: 'the banner replaces the bar');
        final rows = {for (final r in model.visibleRows()) r.key: r};
        expect(rows['#feature:feature-1']!.pick, AssemblyPickState.pickable);
        expect(rows['#feature:feature-2']!.pick, AssemblyPickState.locked);
        await tester.tap(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('Extrude 1')));
        await settle(tester);
        expect(find.byKey(const ValueKey('tree-picker-reason')), findsOneWidget);
        expect(find.byType(ExtrudePanel), findsNothing);
        await tester.tap(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('Sketch 1')));
        await settle(tester);
        expect(find.byType(ExtrudePanel), findsOneWidget);
        expect(_TreeProbe(tester).model.picker, isNull, reason: 'the picker closed with the pick');
        await tester.pump(const Duration(milliseconds: 600));
      });

      testWidgets('multi-select by row keys: a long-press starts it, rows tick, Delete removes both', (tester) async {
        final backend = await openPart(tester);
        await tester.longPress(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('Plane 1')));
        await settle(tester);
        expect(_TreeProbe(tester).view.isMultiSelectMode, isTrue);
        expect(_TreeProbe(tester).view.selectedKeys, {'#feature:feature-3', '#plane:feature:feature-3'}, reason: 'both rows of the plane');
        await tester.tap(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('Extrude 1')));
        await settle(tester);
        expect(_TreeProbe(tester).view.selectedKeys, {'#feature:feature-3', '#plane:feature:feature-3', '#feature:feature-2'});
        await tester.tap(find.descendant(of: find.byType(MultiSelectActionBar), matching: find.text('Delete')));
        await _pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
        expect(find.text('Delete 2 features?'), findsOneWidget);
        await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete all')));
        await _pumpUntil(tester, () => find.text('Plane 1').evaluate().isEmpty);
        await settle(tester);
        expect([for (final f in backend.features) f['id']], ['feature-1']);
        expect(rowKeys(tester).where((k) => k.contains('#feature:')), ['#feature:feature-1']);
      });

      testWidgets('a body or face picked in the viewport marks its feature\'s row and opens the tree down to it', (tester) async {
        await openPart(tester);
        final model = _TreeProbe(tester).model;
        model.setOpen('', false); // the root never closes; a live root is open anyway
        viewport(tester).onSelectionToggle!(const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'feature-2', id: 3));
        await settle(tester);
        expect(model.selectedKey, '#feature:feature-2');
        expect(model.indexOf('#feature:feature-2'), greaterThan(0));
      });

      testWidgets('switching lens keeps the open rows, the scroll and the selection; it is not the person\'s change and writes nothing',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        await openPart(tester, filePath: '/docs/p.didsa', features: [
          ...partFeatures,
          for (var i = 0; i < 30; i++) {'type': 'sketch', 'id': 'more-$i', 'sketch_id': 'sketch-1', 'locked': false, 'produces': 'sketch'},
        ]);
        final model = _TreeProbe(tester).model;
        await _tapTreeRow(tester, 'Bodies'); // the person's change: stored
        await _tapTreeRow(tester, 'Body 1');
        final list = find.byKey(const ValueKey('assembly-tree-list'));
        await tester.drag(list, const Offset(0, -300));
        await settle(tester);
        final scroll = tester.widget<ListView>(list).controller!;
        final offset = scroll.offset;
        expect(offset, greaterThan(0));
        // Anything the switch wrote would replace this.
        await tester.runAsync(() async => (await SharedPreferences.getInstance())
            .setString('assembly_tree_open:file:/docs/p.didsa', jsonEncode(['sentinel'])));
        final touched = model.openKeysTouched;

        await switchLens(tester, 'Assembly');
        await settle(tester);
        expect(_TreeProbe(tester).view.title, 'Assembly Tree');
        expect(_TreeProbe(tester).model.liveKey, isNull, reason: 'the Assembly lens has no live row');
        expect(rowKeys(tester).where((k) => k.contains('#body')), isEmpty);
        await switchLens(tester, 'Part');
        await settle(tester);

        final after = _TreeProbe(tester).model;
        expect(identical(after, model), isTrue, reason: 'the same tree');
        expect(after.openKeys, contains('#bodies'));
        expect(after.selectedKey, '#body:feature-2');
        expect(after.openKeysTouched, touched);
        expect(tester.widget<ListView>(list).controller!.offset, offset, reason: 'the same list, scrolled where it was');
        expect(await tester.runAsync(() => AssemblyTreeOpenStore.read('file:/docs/p.didsa')), ['sentinel'], reason: 'nothing was stored');
      });

      // ----- Review round 1 -----

      testWidgets('open live folders come back when the document is opened again, in either lens', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await openPart(tester, filePath: '/docs/p.didsa');
        await _tapTreeRow(tester, 'Bodies');
        await _tapTreeRow(tester, 'Planes');
        expect(await tester.runAsync(() => AssemblyTreeOpenStore.read('file:/docs/p.didsa')), ['#bodies', '#planes']);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        // Again in the Part lens: restored once the stored rows are read back.
        await openPart(tester, filePath: '/docs/p.didsa', openTree: false);
        await _pumpUntil(tester, () => _TreeProbe(tester).model.isOpen('#planes'));
        expect(_TreeProbe(tester).model.openKeys, {'#bodies', '#planes'});
        expect(_TreeProbe(tester).model.openKeysTouched, isFalse);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        // Opened straight into the Assembly lens (the restore runs while the live part is hidden), then the Part lens.
        final backend = _FakeDocumentBackend(seedFeatures: [for (final f in partFeatures) {...f}])
          ..meshBodies = [
            {'body_id': 'feature-2', 'source': 'computed', 'mesh': _FakeDocumentBackend._placeholderMesh},
          ];
        final sketchBackend = _FakeSketchBackend();
        await tester.pumpWidget(MaterialApp(
          home: PartScreen(
            documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request))),
            initialFilePath: '/docs/p.didsa',
            initialLens: AssemblyLens.assembly,
            sketchApiFactory: () => SketchApiClient(httpClient: MockClient((r) async => sketchBackend.handle(r))),
          ),
        ));
        await _pumpUntil(tester, () => _TreeProbe(tester).model.isOpen('#planes'));
        expect(_TreeProbe(tester).model.liveKey, isNull, reason: 'the Assembly lens');
        expect(_TreeProbe(tester).model.openKeys, {'#bodies', '#planes'});
        await switchLens(tester, 'Part');
        await settle(tester);
        expect(rowKeys(tester), containsAll(['#body:feature-2', '#plane:xy']));
      });

      testWidgets('a plane feature ticks in both places it is listed', (tester) async {
        await openPart(tester);
        await _tapTreeRow(tester, 'Planes');
        await tester.longPress(find.descendant(of: find.byType(AssemblyTreeView), matching: find.text('Plane 1')).first);
        await settle(tester);
        expect(_TreeProbe(tester).view.selectedKeys, {'#feature:feature-3', '#plane:feature:feature-3'});
      });

      testWidgets('Thicken picks a surface from its row in Surfaces, which stands for the feature that made it', (tester) async {
        await openPart(tester, openTree: false, desktop: true, features: [
          ...partFeatures,
          {'type': 'surface', 'id': 'surf-1', 'sketch_feature_id': 'feature-1', 'locked': false, 'produces': 'surface'},
        ], extraBodies: [
          {'body_id': 'surf-1', 'source': 'computed', 'is_surface': true, 'mesh': _FakeDocumentBackend._placeholderMesh},
        ]);
        await tester.tap(find.byKey(const ValueKey('ribbon-All features')));
        await _settleSheet(tester);
        await tester.ensureVisible(find.text('From Surfaces'));
        await tester.tap(find.text('From Surfaces'));
        await _settleSheet(tester);
        await tester.ensureVisible(find.text('Thicken'));
        await tester.tap(find.text('Thicken'));
        await settle(tester);
        await settle(tester);
        final model = _TreeProbe(tester).model;
        expect(model.picker, isNotNull);
        await _tapTreeRow(tester, 'Surfaces');
        final row = _TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == '#surface:surf-1');
        expect(row.pick, AssemblyPickState.pickable);
        // Its feature's build-order row has the same name: the Surfaces folder's row, by its key.
        await tester.tap(find.byKey(const ValueKey('tree-row:#surface:surf-1')));
        await settle(tester);
        expect(find.text('Thicken'), findsWidgets, reason: 'the Thicken panel');
        // The pick committed (Thicken picks one surface): its panel holds the desktop pane now, and the picker is gone.
        expect(find.byType(AssemblyTreeView), findsNothing);
        expect(find.text('Select a surface to thicken'), findsNothing);
        await tester.pump(const Duration(milliseconds: 600));
      });

      testWidgets('P2 review: a part whose mesh fails at load still lists its features, and the failure is in the banner', (tester) async {
        await openPart(tester, configure: (b) => b.failMeshFor.add('part-1'));
        await settle(tester);
        final model = _TreeProbe(tester).model;
        expect(model.liveKey, '', reason: 'the load carried on past the mesh: the features came and the tree was seeded');
        expect(rowKeys(tester), containsAll(['#feature:feature-1', '#feature:feature-2', '#feature:feature-3']));
        expect(find.textContaining('The shape could not be built'), findsOneWidget);
      });

      testWidgets('manager review: a mesh answer that is not JSON at load ends in the banner as a short message, not an uncaught error',
          (tester) async {
        await openPart(tester, configure: (b) => b.badMeshFor.add('part-1'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(_TreeProbe(tester).model.liveKey, '');
        expect(rowKeys(tester), contains('#feature:feature-2'), reason: 'the features still came');
        expect(find.textContaining("Could not read the server's answer"), findsOneWidget);
        expect(find.textContaining('proxy error'), findsNothing, reason: 'not the raw response body');
        expect(find.textContaining('FormatException'), findsNothing);
      });

      testWidgets('manager review: mesh and features answers that are not JSON at load: the short message once, nothing uncaught', (tester) async {
        final backend = _FakeDocumentBackend(seedFeatures: [for (final f in partFeatures) {...f}])
          ..badMeshFor.add('part-1')
          ..badFeaturesFor.add('part-1');
        await tester.pumpWidget(MaterialApp(
          home: PartScreen(documentApi: DocumentApiClient(httpClient: MockClient((request) async => backend.handle(request)))),
        ));
        await _pumpUntil(tester, () => find.textContaining("Could not read the server's answer").evaluate().isNotEmpty);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining("Could not read the server's answer"), findsOneWidget);
        expect(find.textContaining('proxy error'), findsNothing);
      });

      testWidgets('manager review: a guarded action whose mesh answer is not JSON shows the short message (Hide from the bar)', (tester) async {
        final backend = await openPart(tester);
        backend.badMeshFor.add('part-1');
        await _tapTreeRow(tester, 'Sketch 1');
        await tester.tap(find.byKey(const ValueKey('tree-bar-hide')));
        await settle(tester);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining("Could not read the server's answer"), findsOneWidget);
        expect(find.textContaining('proxy error'), findsNothing);
      });

      for (final coarseLate in [false, true]) {
        testWidgets('P2 review: a failed mesh leaves no coarse stand-in or pending detail (the coarse answer ${coarseLate ? 'after' : 'before'} it)',
            (tester) async {
          Completer<void>? holdCoarse = coarseLate ? Completer<void>() : null;
          Completer<void>? holdFull = coarseLate ? null : Completer<void>();
          final coarseDone = Completer<void>();
          await openPart(
            tester,
            features: [
              ...partFeatures,
              {'type': 'loft', 'id': 'loft-1', 'locked': false, 'produces': 'body'},
            ],
            extraBodies: [
              {'body_id': 'loft-1', 'source': 'computed', 'mesh': _FakeDocumentBackend._placeholderMesh},
            ],
            configure: (b) => b.failMeshFor.add('part-1'),
            around: (request) async {
              if (!request.url.path.endsWith('/mesh')) return;
              if (request.url.queryParameters['tier'] == 'coarse') {
                if (holdCoarse != null) await holdCoarse.future;
                if (!coarseDone.isCompleted) coarseDone.complete();
              } else if (holdFull != null) {
                // The full mesh fails only once the coarse answer is in.
                await coarseDone.future;
                await Future<void>.delayed(Duration.zero);
              }
            },
          );
          holdFull = null;
          holdCoarse?.complete();
          holdCoarse = null;
          await settle(tester);
          await settle(tester);
          expect(viewport(tester).coarseOverlayMeshes, isEmpty, reason: 'no full detail is coming to replace a stand-in');
          final rows = {for (final r in _TreeProbe(tester).model.visibleRows()) r.key: r};
          expect(rows['#feature:loft-1']!.state, isNot(AssemblyRowState.pendingDetail));
        });
      }

      testWidgets('P2 review: Pattern\'s source picker leaves surface rows locked (only the surface pickers take them)', (tester) async {
        await openPart(tester, openTree: false, desktop: true, features: [
          ...partFeatures,
          {'type': 'surface', 'id': 'surf-1', 'sketch_feature_id': 'feature-1', 'locked': false, 'produces': 'surface'},
        ], extraBodies: [
          {'body_id': 'surf-1', 'source': 'computed', 'is_surface': true, 'mesh': _FakeDocumentBackend._placeholderMesh},
        ]);
        await tester.tap(find.byKey(const ValueKey('ribbon-Pattern')));
        await settle(tester);
        await tester.ensureVisible(find.text('Add from Tree'));
        await tester.tap(find.text('Add from Tree'));
        await settle(tester);
        expect(find.text('Select source Features'), findsOneWidget);
        await _tapTreeRow(tester, 'Surfaces');
        final rows = {for (final r in _TreeProbe(tester).model.visibleRows()) r.key: r};
        expect(rows['#feature:surf-1']!.pick, AssemblyPickState.pickable, reason: 'the surface feature is a source');
        expect(rows['#surface:surf-1']!.pick, AssemblyPickState.locked, reason: 'its surface row is not (Pattern picks features)');
        await tester.pump(const Duration(milliseconds: 600));
      });

      testWidgets('no Edit for a feature without an edit panel (an import): not in the bar, not on a double-tap', (tester) async {
        await openPart(tester, features: [
          {'type': 'import', 'id': 'imp-1', 'locked': false, 'produces': 'body'},
          ...partFeatures,
        ]);
        final label = _TreeProbe(tester).model.visibleRows().firstWhere((r) => r.key == '#feature:imp-1').label;
        await _tapTreeRow(tester, label);
        expect(_TreeProbe(tester).model.selectedKey, '#feature:imp-1');
        expect(find.byKey(const ValueKey('tree-bar-edit')), findsNothing);
        expect(find.byKey(const ValueKey('tree-bar-hide')), findsOneWidget);
        // Extrude 1 has one.
        await _tapTreeRow(tester, 'Extrude 1');
        expect(find.byKey(const ValueKey('tree-bar-edit')), findsOneWidget);
      });
    });

    group('Build tree (P2) in an assembly', () {
      /// [openNested] without the switch to the Assembly lens: the Part lens, the tree open.
      Future<_FakeDocumentBackend> openNestedInPartLens(WidgetTester tester,
          {Future<void> Function(http.Request request)? around, void Function(_FakeDocumentBackend backend)? configure}) async {
        final backend = await openNested(tester, around: around, configure: configure);
        await switchLens(tester, 'Part');
        await tester.tap(find.byTooltip('Feature tree'));
        await settle(tester);
        return backend;
      }

      /// Make Focus on the plate (a part directly in the root) and wait until the focus has landed (B3: the tree stays the document's, so
      /// there is no other tree to wait for).
      Future<void> focusPlate(WidgetTester tester) async {
        await _TreeProbe(tester).menuAction('plate', 'Make Focus');
        await _pumpUntil(tester, () => tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath.join('/') == 'plate');
        await settle(tester);
      }

      testWidgets('P2 review: Make Focus on a Part whose mesh fails with a non-backend error and whose features fail: both in the banner',
          (tester) async {
        final backend = await openNestedInPartLens(tester);
        backend.badMeshFor.add('plate-part');
        backend.failFeaturesFor.add('plate-part');
        await focusPlate(tester);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'neither error escapes the focus change');
        expect(find.textContaining('The features could not be read'), findsOneWidget);
        expect(find.textContaining("Could not read the server's answer"), findsOneWidget,
            reason: "the mesh's error is shown too, though it is not an ApiException: a short message");
        expect(find.textContaining('proxy error'), findsNothing, reason: 'not the raw response body');
      });

      testWidgets('a focused Part whose mesh fails to load still lists its features as the live row', (tester) async {
        final backend = await openNestedInPartLens(tester, configure: (b) {
          b.meshBodies = [
            {'body_id': 'root-body', 'source': 'computed', 'mesh': _FakeDocumentBackend._placeholderMesh},
          ];
        });
        expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodies.map((b) => b.bodyId), ['root-body']);
        backend.extraPartFeatures['plate-part'] = [
          {'type': 'sketch', 'id': 'plate-sketch', 'sketch_id': 'sketch-1', 'locked': false, 'produces': 'sketch'},
        ];
        backend.failMeshFor.add('plate-part');
        await focusPlate(tester);
        await settle(tester);
        final model = _TreeProbe(tester).model;
        expect(model.liveKey, 'plate', reason: 'the features alone make the live row when the mesh failed (B3: the plate is a row of the whole tree)');
        expect(rowKeys(tester), contains('plate#feature:plate-sketch'));
        expect(rowKeys(tester).where((k) => k.contains('#body')), isEmpty, reason: 'no bodies: those in hand were the root\'s');
        expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodies, isEmpty,
            reason: 'the root\'s bodies are not offered as the plate\'s (to pick, to edit)');
        expect(find.textContaining('The shape could not be built'), findsOneWidget, reason: 'the failure is in the banner');
      });

      testWidgets('after Make Focus the new live row does not list the previous Part\'s features while its own are on their way', (tester) async {
        Completer<void>? holdPlateFeatures;
        await openNested(tester, configure: (b) {
          b.features.add({'type': 'sketch', 'id': 'root-sketch', 'sketch_id': 'sketch-1', 'locked': false, 'produces': 'sketch'});
        }, around: (request) async {
          if (holdPlateFeatures != null && request.url.path == '/document/parts/plate-part/features') await holdPlateFeatures.future;
        });
        await switchLens(tester, 'Part');
        await settle(tester);
        expect(_TreeProbe(tester).model.liveFeatureKey('root-sketch'), '#feature:root-sketch');
        final held = holdPlateFeatures = Completer<void>();
        await focusPlate(tester);
        final model = _TreeProbe(tester).model;
        expect(model.liveKey, isNull, reason: 'no live row until the focused Part\'s own features and bodies are in');
        expect(rowKeys(tester).where((k) => k.contains('root-sketch')), isEmpty, reason: 'the root\'s features are not the plate\'s');
        held.complete();
        await settle(tester);
        await settle(tester);
        expect(_TreeProbe(tester).model.liveKey, 'plate');
        expect(rowKeys(tester).where((k) => k.contains('root-sketch')), isEmpty);
      });

      testWidgets('the Part lens shows the whole tree with the focused Part live, and the lens switches which row is live', (tester) async {
        await openNestedInPartLens(tester);
        final model = _TreeProbe(tester).model;
        expect(_TreeProbe(tester).view.title, 'Build Tree');
        expect(model.liveKey, '', reason: 'nothing focused: the document root is the focused Part');
        expect(rowKeys(tester), ['', 'asm-1', 'asm-2', 'plate', '#mates', '#planes'].where(rowKeys(tester).contains).toList());
        expect(rowKeys(tester), containsAll(['asm-1', 'asm-2', 'plate', '#planes']));
        expect(rowKeys(tester).indexOf('#planes'), greaterThan(rowKeys(tester).indexOf('plate')),
            reason: "the live root's folders follow its components");

        // Make Focus on a part: the focused Part's row is the live row, and the tree is still the whole document's (B3).
        await focusPlate(tester);
        expect(_TreeProbe(tester).model.tree?.partId, 'part-1');
        expect(_TreeProbe(tester).model.liveKey, 'plate');
        expect(rowKeys(tester), containsAll(['asm-1', 'asm-2', 'plate', 'plate#planes']));
        expect(rowKeys(tester), isNot(contains('#planes')), reason: "the root's own folders are not the plate's");
      });

      testWidgets('a late features answer for the Part focused before is dropped; the focused Part keeps its own', (tester) async {
        Completer<void>? holdRootFeatures;
        Completer<void>? holdPlateFeatures;
        final backend = await openNestedInPartLens(tester, around: (request) async {
          final p = request.url.path;
          if (holdRootFeatures != null && p == '/document/parts/part-1/features' && request.method == 'GET') await holdRootFeatures.future;
          if (holdPlateFeatures != null && p == '/document/parts/plate-part/features' && request.method == 'GET') {
            await holdPlateFeatures.future;
          }
        });
        // Focus the plate, and come back: the way back asks for the root's features, which is held.
        await focusPlate(tester);
        backend.features.add({'type': 'sketch', 'id': 'feature-late', 'sketch_id': 'sketch-1', 'locked': false});
        final late = holdRootFeatures = Completer<void>();
        await _TreeProbe(tester).exitFocus();
        await _pumpUntil(tester, () => tester.widget<PartViewport>(find.byType(PartViewport)).focusedOccurrencePath.isEmpty);
        await settle(tester);
        // The root's features are on their way when the plate is focused again (its own are held, so the live row has none to show yet).
        holdRootFeatures = null;
        holdPlateFeatures = Completer<void>();
        await focusPlate(tester);
        late.complete();
        await settle(tester);
        await settle(tester);
        bool lateShown() => _TreeProbe(tester).model.livePart?.features.any((f) => f.id == 'feature-late') ?? false;
        expect(lateShown(), isFalse, reason: "the root's answer landed after the focus moved: it is dropped");
        holdPlateFeatures.complete();
        await settle(tester);
        await settle(tester);
        expect(lateShown(), isFalse);
        expect(_TreeProbe(tester).model.liveKey, 'plate');
      });

      testWidgets('a late mesh answer for the Part focused before is dropped', (tester) async {
        Completer<void>? holdRootMesh;
        Completer<void>? holdPlateMesh;
        final backend = await openNestedInPartLens(tester, around: (request) async {
          final p = request.url.path;
          if (holdRootMesh != null && p == '/document/parts/part-1/mesh' && request.url.queryParameters['tier'] != 'coarse') {
            await holdRootMesh.future;
          }
          if (holdPlateMesh != null && p == '/document/parts/plate-part/mesh' && request.url.queryParameters['tier'] != 'coarse') {
            await holdPlateMesh.future;
          }
        });
        backend.meshBodies = [
          {'body_id': 'root-body', 'source': 'computed', 'mesh': _FakeDocumentBackend._placeholderMesh},
        ];
        await focusPlate(tester);
        final late = holdRootMesh = Completer<void>();
        await _TreeProbe(tester).exitFocus();
        await settle(tester);
        await settle(tester);
        holdRootMesh = null;
        holdPlateMesh = Completer<void>();
        await focusPlate(tester);
        late.complete();
        await settle(tester);
        expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodies.map((b) => b.bodyId), isNot(contains('root-body')),
            reason: "the root's bodies landed after the focus moved: dropped");
        holdPlateMesh.complete();
        await settle(tester);
        await settle(tester);
        expect(tester.widget<PartViewport>(find.byType(PartViewport)).bodies.map((b) => b.bodyId), isNot(contains('root-body')));
      });

      testWidgets('a tree answer that lands after a lens switch is applied to the same tree: the open rows, the selection and the live row stay',
          (tester) async {
        Completer<void>? hold;
        await openNestedInPartLens(tester, around: (request) async {
          if (hold != null && request.url.path == '/document/parts/part-1/assembly-tree') await hold.future;
        });
        final model = _TreeProbe(tester).model;
        await _tapTreeRow(tester, 'Planes');
        await _tapTreeRow(tester, 'XY plane');
        await _settleSheet(tester);
        await tester.tapAt(const Offset(400, 20)); // the plane sheet the tap opened
        await _settleSheet(tester);
        final touched = model.openKeysTouched;
        // Entering the Assembly lens reloads the tree; its answer is held until the Part lens is back.
        final late = hold = Completer<void>();
        await switchLens(tester, 'Assembly');
        await switchLens(tester, 'Part');
        hold = null;
        late.complete();
        await settle(tester);
        await settle(tester);
        final after = _TreeProbe(tester).model;
        expect(identical(after, model), isTrue);
        expect(after.liveKey, '');
        expect(after.openKeys, contains('#planes'));
        expect(after.selectedKey, '#plane:xy');
        expect(after.openKeysTouched, touched);
      });

      testWidgets('an older tree load that lands after a newer one is dropped, across a focus change', (tester) async {
        Completer<void>? hold;
        final backend = await openNestedInPartLens(tester, around: (request) async {
          if (hold != null && request.url.path == '/document/parts/part-1/assembly-tree') await hold.future;
        });
        backend.constraintStatus['plate'] = {'status': 'under_constrained', 'dof': 3, 'rigid_set': 'plate'};
        // The root's tree (the Assembly lens asks for it) is on its way, with the plate under-constrained, when the plate is focused and the
        // backend has meanwhile fixed it: the newer load's answer is what stays.
        final late = hold = Completer<void>();
        await switchLens(tester, 'Assembly');
        backend.constraintStatus['plate'] = {'status': 'fully_constrained', 'dof': 0, 'rigid_set': 'plate'};
        hold = null;
        await focusPlate(tester);
        late.complete();
        await settle(tester);
        await settle(tester);
        final model = _TreeProbe(tester).model;
        expect(model.tree?.partId, 'part-1');
        expect(model.nodeAtPath(['plate'])?.constraint?.status, ConstraintState.fullyConstrained,
            reason: "the older load's answer (under-constrained) did not replace the newer one's");
        expect(model.focusPath, ['plate']);
      });
    });
  });

}
