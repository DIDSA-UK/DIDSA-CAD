import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_modelling_screen.dart';
import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_lens.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';
import 'package:didsa_cad_client/viewport3d/part_screen.dart';

class _FakeAiProvider implements AiProvider {
  final Future<AiTurnResult> Function(List<AiChatMessage> transcript, String? systemPrompt) handler;

  _FakeAiProvider(this.handler);

  @override
  AiProviderCapabilities get capabilities =>
      const AiProviderCapabilities(supportsStructuredOutput: true, supportsVision: false);

  @override
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt}) =>
      handler(transcript, systemPrompt);

  @override
  Future<String> extractImageDescription(List<AiImageAttachment> images) => throw UnimplementedError();
}

/// A minimal in-memory [StorageService] - `listFiles`/`resolve`/`writeFile`
/// cover Phase D's own orchestration path (`nextAvailablePartName` +
/// `showRelativePathPromptDialog`'s own collision check +
/// `AssemblyDocumentClient.savePart`); `readFile` covers Phase E's own
/// `add_component` steps reading a just-saved part's file straight back
/// (`AiAddComponentStep`'s own `storage.resolve` + `storage.readFile` call,
/// never HTTP - see `ai_plan_translator.dart`). Every other method throws if
/// reached, the same "fail loud on an unexpected call" posture
/// `ai_plan_translator_test.dart`'s own `_FakeStorageService` already uses.
class _FakeStorageService implements StorageService {
  final Map<String, Uint8List> writtenFiles = {};

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async => writtenFiles.keys.toList();

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    if (!writtenFiles.containsKey(relativePath)) return null;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) async {
    writtenFiles[relativePath] = bytes;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() => throw UnimplementedError();

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) => throw UnimplementedError();

  @override
  Future<Uint8List> readFile(FileHandle handle) async => writtenFiles[(handle as DesktopFileHandle).relativePath]!;

  @override
  Future<DateTime?> lastModified(FileHandle handle) => throw UnimplementedError();

  @override
  Future<bool> exists(FileHandle handle) => throw UnimplementedError();
}

const _manifestText = '''
I found two distinct parts.
```json
{"kind": "part_manifest", "parts": [
  {"name": "Mounting Plate", "type_prefix": "PLATE", "summary": "60x40x10mm plate"},
  {"name": "Support Tube", "type_prefix": "TUBE", "summary": "40mm OD tube"}
]}
```''';

const _onePartPlanText = '''
Here is the plan.
```json
{"version": 1, "steps": [
  {"local_id": "sk1", "kind": "sketch", "plane": "XY"},
  {"local_id": "p1", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 0, "y": 0},
  {"local_id": "p2", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 60, "y": 0},
  {"local_id": "p3", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 60, "y": 40},
  {"local_id": "p4", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 0, "y": 40},
  {"local_id": "r1", "kind": "sketch_rectangle", "sketch_feature_id": "sk1", "corner_point_ids": ["p1", "p2", "p3", "p4"]},
  {"local_id": "f1", "kind": "extrude", "sketch_feature_id": "sk1", "extrude_type": "boss", "start_distance": 0, "end_distance": 10}
]}
```''';

/// Phase E's own assembly plan - an `add_component` step per part saved by
/// the two preceding cycles, referencing the exact `relative_path`s those
/// cycles' own save-confirm dialogs produce below (`PLATE_001.DIDSAprt`/
/// `TUBE_001.DIDSAprt`). No `mate` step here - `_runAssemblyCycle` treats
/// `add_component`/`mate` identically (both are ordinary `PlanStep`s,
/// unchanged from Phase D's own translator call), so this keeps the fixture
/// backend small without weakening what this test actually exercises: the
/// orchestration wiring from "all parts saved" through a real assembly
/// create/execute/save/open cycle.
const _assemblyPlanText = '''
Here is the assembly plan.
```json
{"version": 1, "steps": [
  {"local_id": "ac1", "kind": "add_component", "relative_path": "PLATE_001.DIDSAprt"},
  {"local_id": "ac2", "kind": "add_component", "relative_path": "TUBE_001.DIDSAprt"}
]}
```''';

/// A [MockClient] handler covering every real HTTP call a full Phases D+E
/// orchestration run makes - mirrors `ai_modelling_screen_test.dart`'s own
/// `realPlanHandler`, but mints a genuinely unique Part id per `createPart`
/// call (Phase D creates one real Part per manifest entry plus one more for
/// Phase E's own assembly, never reusing `part-1` the way the single-part
/// fixture always does). `/document/export/native` is part-id-aware (each
/// saved file's bytes carry *that* part's own real id, the way
/// `AiAddComponentStep`'s own `mergeComponentIntoDocument` call requires
/// when it later reads a saved part's file back) and `/document/import
/// /native` covers `add_component`'s own merge-and-replace call.
/// `ai-plan/validate` echoes back whichever `local_id`s the request body
/// actually names, since each part's plan and the assembly's own plan use
/// different step sets.
Future<http.Response> Function(http.Request) _fullOrchestrationHandler() {
  var partCount = 0;
  var pointCount = 0;
  return (request) async {
    final path = request.url.path;
    if (path == '/document/parts' && request.method == 'POST') {
      partCount++;
      return http.Response(jsonEncode({'id': 'part-$partCount', 'name': 'part', 'feature_ids': []}), 201);
    }
    if (path.endsWith('/ai-plan/validate')) {
      final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;
      final steps = ((body['steps'] as List?) ?? []).cast<Map<String, dynamic>>();
      return http.Response(
        jsonEncode({
          'results': [
            for (final step in steps) {'local_id': step['local_id'], 'ok': true, 'warnings': [], 'error': null},
          ],
        }),
        200,
      );
    }
    if (RegExp(r'^/document/parts/part-\d+/features/sketch$').hasMatch(path)) {
      return http.Response(
        jsonEncode({'type': 'sketch', 'id': 'feat-sk-$partCount', 'locked': false, 'sketch_id': 'sketch-$partCount'}),
        201,
      );
    }
    if (RegExp(r'^/sketch/sketches/sketch-\d+/points$').hasMatch(path)) {
      pointCount++;
      return http.Response(jsonEncode({'id': 'point-$pointCount', 'x': 0.0, 'y': 0.0}), 201);
    }
    if (RegExp(r'^/sketch/sketches/sketch-\d+/rectangles$').hasMatch(path)) {
      return http.Response(
        jsonEncode({
          'id': 'rect-$partCount',
          'corner_point_ids': ['point-1', 'point-2', 'point-3', 'point-4'],
          'line_ids': ['line-1', 'line-2', 'line-3', 'line-4'],
          'axis_aligned': true,
        }),
        201,
      );
    }
    if (RegExp(r'^/document/parts/part-\d+/extrude-features$').hasMatch(path)) {
      return http.Response(
        jsonEncode({
          'type': 'extrude',
          'id': 'feat-extrude-$partCount',
          'locked': false,
          'sketch_feature_id': 'feat-sk-$partCount',
          'extrude_type': 'boss',
          'start_distance': 0.0,
          'end_distance': 10.0,
          'target_body_ids': [],
        }),
        201,
      );
    }
    if (path == '/document/export/native') {
      final partId = request.url.queryParameters['part_id'] ?? 'part-$partCount';
      return http.Response(
        jsonEncode({
          'schema_version': 1,
          'document': {
            'id': 'doc-$partId',
            'root_part_id': partId,
            'parts': [
              {'id': partId, 'occurrences': []},
            ],
          },
          'sketches': [],
        }),
        200,
      );
    }
    if (path == '/document/import/native' && request.method == 'POST') {
      return http.Response(
        jsonEncode({
          'document_id': 'doc-merged',
          'part_ids': ['part-$partCount', 'part-1', 'part-2'],
        }),
        200,
      );
    }
    return http.Response('not found', 404);
  };
}

/// Multi-part/assembly overhaul, Phases D+E
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the N
/// sequential single-Part orchestration cycle - manifest detection, the
/// confirm-parts panel, per-part generate+save - followed by Phase E's own
/// one further assembly create/execute/save/open cycle once every part is
/// saved. Kept in its own file (mirrors `ai_modelling_screen_mode_toggle_test
/// .dart`'s own reasoning), since a real end-to-end orchestration run needs
/// a much larger fake backend/storage fixture than any existing test in
/// `ai_modelling_screen_test.dart` sets up.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('a part_manifest reply shows the confirm panel with one editable row per part', (tester) async {
    final provider = _FakeAiProvider((_, __) async => const AiTurnResult(assistantText: _manifestText));
    final storage = _FakeStorageService();
    await tester.pumpWidget(
      MaterialApp(
        home: AiModellingScreen(provider: provider, storageService: storage, projectRoot: const DesktopProjectRoot('/tmp/project')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A plate and a tube');
    await tester.tap(find.byKey(const Key('aiModellingSend')));
    await tester.pumpAndSettle();

    expect(find.text('Found 2 part(s)'), findsOneWidget);
    expect(find.byKey(const Key('aiModellingManifestName_0')), findsOneWidget);
    expect(find.byKey(const Key('aiModellingManifestName_1')), findsOneWidget);
    final nameField = tester.widget<TextFormField>(find.byKey(const Key('aiModellingManifestName_0')));
    expect(nameField.controller!.text, 'Mounting Plate');
  });

  testWidgets('"Back to chat" from the confirm panel discards the manifest', (tester) async {
    final provider = _FakeAiProvider((_, __) async => const AiTurnResult(assistantText: _manifestText));
    final storage = _FakeStorageService();
    await tester.pumpWidget(
      MaterialApp(
        home: AiModellingScreen(provider: provider, storageService: storage, projectRoot: const DesktopProjectRoot('/tmp/project')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A plate and a tube');
    await tester.tap(find.byKey(const Key('aiModellingSend')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('aiModellingManifestCancel')));
    await tester.pumpAndSettle();

    expect(find.text('Found 2 part(s)'), findsNothing);
    // Back in ordinary chat - the exchange that produced the manifest is
    // still visible in the transcript.
    expect(find.textContaining('A plate and a tube'), findsOneWidget);
  });

  testWidgets(
    'confirming generates and saves every part, then Phase E builds, saves and opens the assembly',
    (tester) async {
      final client = DocumentApiClient(httpClient: MockClient(_fullOrchestrationHandler()));
      final sketchClient = SketchApiClient(httpClient: MockClient(_fullOrchestrationHandler()));
      final storage = _FakeStorageService();
      const root = DesktopProjectRoot('/tmp/project');

      var turnCount = 0;
      final provider = _FakeAiProvider((_, __) async {
        turnCount++;
        // Turn 1: the manifest. Turns 2-3: each part's own plan, in order.
        // Turn 4: the assembly plan, once `_finishPartOrchestration` kicks
        // off `_runAssemblyCycle` automatically.
        return AiTurnResult(
          assistantText: switch (turnCount) {
            1 => _manifestText,
            2 || 3 => _onePartPlanText,
            _ => _assemblyPlanText,
          },
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: AiModellingScreen(
            provider: provider,
            documentApi: client,
            sketchApi: sketchClient,
            storageService: storage,
            projectRoot: root,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assembly'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A plate and a tube');
      await tester.tap(find.byKey(const Key('aiModellingSend')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('aiModellingManifestConfirm')));
      await tester.pumpAndSettle();

      // First part's save-confirm dialog.
      expect(find.text('Save "Mounting Plate" as…'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Second part's save-confirm dialog.
      expect(find.text('Save "Support Tube" as…'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Phase E: both parts are saved, so the assembly cycle starts on its
      // own - no further tap needed - ending at its own save-confirm
      // dialog, proposing a collision-free ASSEMBLY_### name exactly like
      // each part's own cycle did.
      expect(find.text('Save assembly as…'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Assembly ready'), findsOneWidget);
      expect(find.textContaining('ASSEMBLY_001'), findsOneWidget);
      expect(
        storage.writtenFiles.keys,
        containsAll(['PLATE_001.DIDSAprt', 'TUBE_001.DIDSAprt', 'ASSEMBLY_001.DIDSAprt']),
      );

      final dismissButton = tester.widget<FilledButton>(find.byKey(const Key('aiModellingOrchestrationDismiss')));
      expect(dismissButton.onPressed, isNotNull);

      // "Open Assembly" navigates straight into `PartScreen` with Assembly
      // lens already active, carrying every saved part's own relative path
      // through - `_openAssembly`'s own contract (mirrors
      // `_onOpenProjectPressed`'s existing `initialRelativePathByPartId`
      // convention). One bounded `pump` (not `pumpAndSettle`) is enough to
      // build the pushed route and inspect its constructor params, without
      // needing to also mock every endpoint the new screen's own
      // `_loadPart` would otherwise call.
      await tester.tap(find.byKey(const Key('aiModellingOpenAssembly')));
      await tester.pump();

      // `skipOffstage: false` - one bare `pump()` builds the pushed route
      // but doesn't run its page-transition animation to completion, so the
      // default `find.byType` (which only ever matches "onstage" - i.e.
      // fully transitioned-in - elements) misses it here even though it's
      // already mounted with every constructor param set.
      final pushedScreen = tester.widget<PartScreen>(find.byType(PartScreen, skipOffstage: false).last);
      expect(pushedScreen.initialPartId, 'part-3');
      expect(pushedScreen.initialLens, AssemblyLens.assembly);
      expect(pushedScreen.initialProjectRoot, root);
      expect(pushedScreen.initialRelativePathByPartId, {
        'part-1': 'PLATE_001.DIDSAprt',
        'part-2': 'TUBE_001.DIDSAprt',
        'part-3': 'ASSEMBLY_001.DIDSAprt',
      });
    },
  );

  testWidgets('a validation failure on one part stops the whole run with a visible error, dismiss enabled',
      (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/document/parts' && request.method == 'POST') {
          return http.Response(jsonEncode({'id': 'part-1', 'name': 'part', 'feature_ids': []}), 201);
        }
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'local_id': 'sk1',
                  'ok': false,
                  'warnings': [],
                  'error': {'type': 'invalid_step_payload', 'message': 'bad plan'},
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    final storage = _FakeStorageService();
    const root = DesktopProjectRoot('/tmp/project');

    var turnCount = 0;
    final provider = _FakeAiProvider((_, __) async {
      turnCount++;
      return AiTurnResult(assistantText: turnCount == 1 ? _manifestText : _onePartPlanText);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AiModellingScreen(provider: provider, documentApi: client, storageService: storage, projectRoot: root),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A plate and a tube');
    await tester.tap(find.byKey(const Key('aiModellingSend')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('aiModellingManifestConfirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Validation failed for "Mounting Plate"'), findsOneWidget);
    final dismissButton = tester.widget<FilledButton>(find.byKey(const Key('aiModellingOrchestrationDismiss')));
    expect(dismissButton.onPressed, isNotNull);
    // Gap-closure (`13-...md`'s own D-1): "Retry" is now offered alongside
    // "Dismiss" instead of stopping being the only way forward.
    expect(find.byKey(const Key('aiModellingOrchestrationRetry')), findsOneWidget);
    expect(storage.writtenFiles, isEmpty);
  });

  testWidgets('Retry after a validation failure re-asks the LLM and reuses the same Part, not a new one',
      (tester) async {
    var createPartCalls = 0;
    var validateCalls = 0;
    Future<http.Response> handler(http.Request request) async {
      {
        final path = request.url.path;
        if (path == '/document/parts' && request.method == 'POST') {
          createPartCalls++;
          return http.Response(jsonEncode({'id': 'part-1', 'name': 'part', 'feature_ids': []}), 201);
        }
        if (path.endsWith('/ai-plan/validate')) {
          validateCalls++;
          final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;
          final steps = ((body['steps'] as List?) ?? []).cast<Map<String, dynamic>>();
          // First validate call fails outright (mirrors the test above);
          // every later call (the retry) succeeds.
          final ok = validateCalls > 1;
          return http.Response(
            jsonEncode({
              'results': [
                for (final step in steps)
                  {
                    'local_id': step['local_id'],
                    'ok': ok,
                    'warnings': [],
                    'error': ok ? null : {'type': 'invalid_step_payload', 'message': 'bad plan'},
                  },
              ],
            }),
            200,
          );
        }
        if (RegExp(r'^/document/parts/part-\d+/features/sketch$').hasMatch(path)) {
          return http.Response(jsonEncode({'type': 'sketch', 'id': 'feat-sk-1', 'locked': false, 'sketch_id': 'sketch-1'}), 201);
        }
        if (RegExp(r'^/sketch/sketches/sketch-\d+/points$').hasMatch(path)) {
          return http.Response(jsonEncode({'id': 'point-1', 'x': 0.0, 'y': 0.0}), 201);
        }
        if (RegExp(r'^/sketch/sketches/sketch-\d+/rectangles$').hasMatch(path)) {
          return http.Response(
            jsonEncode({
              'id': 'rect-1',
              'corner_point_ids': ['point-1', 'point-1', 'point-1', 'point-1'],
              'line_ids': ['line-1', 'line-2', 'line-3', 'line-4'],
              'axis_aligned': true,
            }),
            201,
          );
        }
        if (RegExp(r'^/document/parts/part-\d+/extrude-features$').hasMatch(path)) {
          return http.Response(
            jsonEncode({
              'type': 'extrude',
              'id': 'feat-extrude-1',
              'locked': false,
              'sketch_feature_id': 'feat-sk-1',
              'extrude_type': 'boss',
              'start_distance': 0.0,
              'end_distance': 10.0,
              'target_body_ids': [],
            }),
            201,
          );
        }
        if (path == '/document/parts/part-1/occurrences') {
          return http.Response(jsonEncode([]), 200);
        }
        return http.Response('not found', 404);
      }
    }

    final client = DocumentApiClient(httpClient: MockClient(handler));
    final sketchClient = SketchApiClient(httpClient: MockClient(handler));
    final storage = _FakeStorageService();
    const root = DesktopProjectRoot('/tmp/project');

    const onePartManifestText = '''
I found one distinct part.
```json
{"kind": "part_manifest", "parts": [
  {"name": "Mounting Plate", "type_prefix": "PLATE", "summary": "60x40x10mm plate"}
]}
```''';

    var turnCount = 0;
    final provider = _FakeAiProvider((transcript, __) async {
      turnCount++;
      // Turn 1: manifest. Turn 2: the initial (failing) plan. Turn 3: the
      // retry's own revised-plan request - the failure must already be in
      // the transcript as its own turn by this point (D-1's whole point).
      if (turnCount == 3) {
        expect(
          transcript.map((m) => m.text),
          anyElement(contains('Validation failed for "Mounting Plate"')),
          reason: "the failure must be fed back to the LLM before it's asked to retry",
        );
        expect(transcript.last.text, contains('Please propose a revised plan for "Mounting Plate"'));
        expect(transcript.last.role, AiMessageRole.user);
      }
      return AiTurnResult(assistantText: turnCount == 1 ? onePartManifestText : _onePartPlanText);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AiModellingScreen(
          provider: provider,
          documentApi: client,
          sketchApi: sketchClient,
          storageService: storage,
          projectRoot: root,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A single plate');
    await tester.tap(find.byKey(const Key('aiModellingSend')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('aiModellingManifestConfirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Validation failed for "Mounting Plate"'), findsOneWidget);
    expect(createPartCalls, 1);

    await tester.tap(find.byKey(const Key('aiModellingOrchestrationRetry')));
    await tester.pumpAndSettle();

    // The retry succeeded this time - straight through to the save dialog,
    // still for the *same* real Part ("part-1") `createPartCalls` proves was
    // only ever created once.
    expect(find.text('Save "Mounting Plate" as…'), findsOneWidget);
    expect(createPartCalls, 1);
    expect(validateCalls, 2);
  });

  testWidgets('Retry after a cancelled save re-opens the save dialog directly, without another LLM turn',
      (tester) async {
    var createPartCalls = 0;
    Future<http.Response> handler(http.Request request) async {
      final path = request.url.path;
      if (path == '/document/parts' && request.method == 'POST') {
        createPartCalls++;
        return http.Response(jsonEncode({'id': 'part-1', 'name': 'part', 'feature_ids': []}), 201);
      }
      if (path.endsWith('/ai-plan/validate')) {
        final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;
        final steps = ((body['steps'] as List?) ?? []).cast<Map<String, dynamic>>();
        return http.Response(
          jsonEncode({
            'results': [
              for (final step in steps) {'local_id': step['local_id'], 'ok': true, 'warnings': [], 'error': null},
            ],
          }),
          200,
        );
      }
      if (RegExp(r'^/document/parts/part-\d+/features/sketch$').hasMatch(path)) {
        return http.Response(jsonEncode({'type': 'sketch', 'id': 'feat-sk-1', 'locked': false, 'sketch_id': 'sketch-1'}), 201);
      }
      if (RegExp(r'^/sketch/sketches/sketch-\d+/points$').hasMatch(path)) {
        return http.Response(jsonEncode({'id': 'point-1', 'x': 0.0, 'y': 0.0}), 201);
      }
      if (RegExp(r'^/sketch/sketches/sketch-\d+/rectangles$').hasMatch(path)) {
        return http.Response(
          jsonEncode({
            'id': 'rect-1',
            'corner_point_ids': ['point-1', 'point-1', 'point-1', 'point-1'],
            'line_ids': ['line-1', 'line-2', 'line-3', 'line-4'],
            'axis_aligned': true,
          }),
          201,
        );
      }
      if (RegExp(r'^/document/parts/part-\d+/extrude-features$').hasMatch(path)) {
        return http.Response(
          jsonEncode({
            'type': 'extrude',
            'id': 'feat-extrude-1',
            'locked': false,
            'sketch_feature_id': 'feat-sk-1',
            'extrude_type': 'boss',
            'start_distance': 0.0,
            'end_distance': 10.0,
            'target_body_ids': [],
          }),
          201,
        );
      }
      if (path == '/document/parts/part-1/occurrences') {
        return http.Response(jsonEncode([]), 200);
      }
      if (path == '/document/export/native') {
        return http.Response(
          jsonEncode({
            'schema_version': 1,
            'document': {
              'id': 'doc-part-1',
              'root_part_id': 'part-1',
              'parts': [
                {'id': 'part-1', 'occurrences': []},
              ],
            },
            'sketches': [],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }

    final client = DocumentApiClient(httpClient: MockClient(handler));
    final sketchClient = SketchApiClient(httpClient: MockClient(handler));
    final storage = _FakeStorageService();
    const root = DesktopProjectRoot('/tmp/project');

    const onePartManifestText = '''
I found one distinct part.
```json
{"kind": "part_manifest", "parts": [
  {"name": "Mounting Plate", "type_prefix": "PLATE", "summary": "60x40x10mm plate"}
]}
```''';

    var turnCount = 0;
    final provider = _FakeAiProvider((_, __) async {
      turnCount++;
      return AiTurnResult(assistantText: turnCount == 1 ? onePartManifestText : _onePartPlanText);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AiModellingScreen(
          provider: provider,
          documentApi: client,
          sketchApi: sketchClient,
          storageService: storage,
          projectRoot: root,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A single plate');
    await tester.tap(find.byKey(const Key('aiModellingSend')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('aiModellingManifestConfirm')));
    await tester.pumpAndSettle();

    // The part itself built successfully - only the save prompt is
    // dismissed.
    expect(find.text('Save "Mounting Plate" as…'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Save cancelled for "Mounting Plate"'), findsOneWidget);
    expect(find.byKey(const Key('aiModellingOrchestrationRetry')), findsOneWidget);
    expect(createPartCalls, 1);
    final turnCountAtCancel = turnCount;

    await tester.tap(find.byKey(const Key('aiModellingOrchestrationRetry')));
    await tester.pumpAndSettle();

    // Straight back to the save dialog - no new LLM turn, no new Part.
    expect(find.text('Save "Mounting Plate" as…'), findsOneWidget);
    expect(turnCount, turnCountAtCancel);
    expect(createPartCalls, 1);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(storage.writtenFiles.keys, contains('PLATE_001.DIDSAprt'));
  });


  // Gap-closure (`13-...md`'s own E-1): a real end-to-end widget test
  // driving `_runAssemblyCycle`'s new `AssemblyDocumentClient.openAssembly`
  // branch through this sandbox's `testWidgets` pump loop was attempted and
  // dropped - the same real `dart:io`/`FileCache` (`path_provider`'s
  // platform channel, unavailable in a widget test) that
  // `part_screen_test.dart`'s own "Assembly support Phase 16" group already
  // found "reliably too slow/flaky" for `openAssembly` specifically (see
  // that group's own comment) hangs here too, for the identical reason.
  // Following that file's own precedent: the manifest-confirm panel's new
  // UI is covered directly below (no `openAssembly` call involved at all -
  // selecting an option is pure widget state), and the new request-text
  // wording `_runAssemblyCycle` sends once it *has* opened an existing
  // assembly is covered as a pure unit test in `ai_scoping_prompt_test.dart`
  // (`assemblyModeAssemblyIntoExistingRequestText`) - together these cover
  // everything genuinely new here except the `openAssembly` call itself,
  // which is exactly the part already covered, composer-level, by
  // `assembly_document_client_test.dart`.
  testWidgets(
    'Gap-closure E-1: the manifest-confirm panel offers inserting into an existing assembly file, '
    'defaulting to "create a new assembly"',
    (tester) async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          if (request.url.path == '/document/parts' && request.method == 'POST') {
            return http.Response(jsonEncode({'id': 'part-1', 'name': 'part', 'feature_ids': []}), 201);
          }
          return http.Response('not found', 404);
        }),
      );
      final storage = _FakeStorageService();
      const root = DesktopProjectRoot('/tmp/project');
      // A pre-existing native file under the project root - discovered by
      // `_loadExistingAssemblyFileOptions` (fired once a manifest is
      // detected) via the ordinary `StorageService.listFiles` this app
      // already uses everywhere else for this, no real file I/O beyond
      // that.
      storage.writtenFiles['EXISTING_ASM.DIDSAprt'] = Uint8List.fromList(utf8.encode('{}'));

      var turnCount = 0;
      final provider = _FakeAiProvider((_, __) async {
        turnCount++;
        return AiTurnResult(assistantText: turnCount == 1 ? _manifestText : _onePartPlanText);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: AiModellingScreen(provider: provider, documentApi: client, storageService: storage, projectRoot: root),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assembly'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A plate and a tube');
      await tester.tap(find.byKey(const Key('aiModellingSend')));
      await tester.pumpAndSettle();

      // Defaults to "create a new assembly" - the pre-E-1 behavior - not
      // the existing file, even though one is available.
      final dropdownFinder = find.byKey(const Key('aiModellingManifestAssemblyTarget'));
      expect(dropdownFinder, findsOneWidget);
      expect(find.text('Create a new assembly file'), findsOneWidget);

      await tester.tap(dropdownFinder);
      await tester.pumpAndSettle();
      expect(find.text('Insert into "EXISTING_ASM.DIDSAprt"'), findsWidgets);
      await tester.tap(find.text('Insert into "EXISTING_ASM.DIDSAprt"').last);
      await tester.pumpAndSettle();

      // The selection stuck - the dropdown's own closed-state label now
      // shows it (asserted by key, `_assemblyTargetRelativePath` is a
      // private field with no test-visible getter, matching this
      // codebase's own "assert on what the user sees" convention for
      // other panel state, e.g. the mode toggle's own tests).
      expect(
        find.descendant(of: dropdownFinder, matching: find.text('Insert into "EXISTING_ASM.DIDSAprt"')),
        findsOneWidget,
      );

      // "Back to chat" clears the selection, same as every other
      // manifest-confirm field.
      await tester.tap(find.byKey(const Key('aiModellingManifestCancel')));
      await tester.pumpAndSettle();
      expect(dropdownFinder, findsNothing);
    },
  );

  testWidgets('Gap-closure E-1: no existing native files means no assembly-target dropdown at all', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/document/parts' && request.method == 'POST') {
          return http.Response(jsonEncode({'id': 'part-1', 'name': 'part', 'feature_ids': []}), 201);
        }
        return http.Response('not found', 404);
      }),
    );
    final storage = _FakeStorageService();
    const root = DesktopProjectRoot('/tmp/project');

    var turnCount = 0;
    final provider = _FakeAiProvider((_, __) async {
      turnCount++;
      return AiTurnResult(assistantText: turnCount == 1 ? _manifestText : _onePartPlanText);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AiModellingScreen(provider: provider, documentApi: client, storageService: storage, projectRoot: root),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A plate and a tube');
    await tester.tap(find.byKey(const Key('aiModellingSend')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('aiModellingManifestAssemblyTarget')), findsNothing);
  });
}
