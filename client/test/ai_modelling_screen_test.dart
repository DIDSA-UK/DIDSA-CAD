import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_modelling_screen.dart';
import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/ai/ai_provider_preferences.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/gear/gear_preset_store.dart';
import 'package:didsa_cad_client/viewport3d/part_screen.dart';

/// AI Modelling workstream 2: widget-level coverage for
/// [AiModellingScreen] - the chat -> plan-detection -> Review & Generate
/// flow, wiring workstream 5's real validate endpoint on Generate, and the
/// save/load-as-preset bolt-on (`02-scoping-conversation.md`). A fake
/// [AiProvider] stands in for the real network call the same way
/// `openai_compatible_provider_test.dart`'s own `MockClient` does for the
/// CAD backend's HTTP client.
class FakeAiProvider implements AiProvider {
  final Future<AiTurnResult> Function(List<AiChatMessage> transcript, String? systemPrompt) handler;

  /// Workstream 10 (image input): configurable per test, so the same fake
  /// covers both the vision-capable-provider and text-only-provider gating
  /// cases `ai_modelling_screen.dart`'s own attach-button visibility relies
  /// on.
  final bool supportsVision;

  /// Workstream 10: only exercised by a test that also sets [supportsVision]
  /// - `extractImageDescription` itself already throws before reaching a
  /// real provider when vision isn't supported, so no fake handler is
  /// needed for that case.
  final Future<String> Function(Uint8List imageBytes, String mimeType)? imageExtractionHandler;

  FakeAiProvider(this.handler, {this.supportsVision = false, this.imageExtractionHandler});

  @override
  AiProviderCapabilities get capabilities =>
      AiProviderCapabilities(supportsStructuredOutput: true, supportsVision: supportsVision);

  @override
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt}) =>
      handler(transcript, systemPrompt);

  @override
  Future<String> extractImageDescription(Uint8List imageBytes, String mimeType) {
    final extractionHandler = imageExtractionHandler;
    if (extractionHandler == null) {
      throw StateError('FakeAiProvider.extractImageDescription called with no imageExtractionHandler stubbed');
    }
    return extractionHandler(imageBytes, mimeType);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  const minimalPlanText = '''
Here's the plan:
```json
{"version": 1, "steps": [
  {"local_id": "g1", "kind": "gear_request", "module": 2, "tooth_count": 20}
]}
```''';

  // A real Feature-tree plan (sketch -> rectangle -> extrude) - workstream
  // 4's translator actually calls the real Document/Sketch API for these,
  // unlike `minimalPlanText`'s gear_request (which the translator only
  // ever detects, never executes - see `ai_plan_translator.dart`'s own
  // top-level doc comment).
  const realPlanText = '''
Here's the plan:
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

  const realPlanLocalIds = ['sk1', 'p1', 'p2', 'p3', 'p4', 'r1', 'f1'];

  /// A [MockClient] handler covering every real HTTP call `realPlanText`'s
  /// plan makes, shared between a [DocumentApiClient] and a
  /// [SketchApiClient] (both point at the same backend in the real app).
  /// [failAtPath] optionally makes one specific request 422 instead of
  /// succeeding, to exercise the real-step-failure path.
  Future<http.Response> Function(http.Request) realPlanHandler({String? failAtPath}) {
    var pointCount = 0;
    return (request) async {
      final path = request.url.path;
      if (failAtPath != null && path == failAtPath) {
        return http.Response(jsonEncode({'detail': {'type': 'geometry_failed'}}), 422);
      }
      if (path == '/document/new') {
        return http.Response(jsonEncode({'document_id': 'doc-1', 'part_ids': []}), 201);
      }
      if (path == '/document/parts') {
        return http.Response(jsonEncode({'id': 'part-1', 'name': 'AI Modelling Part', 'feature_ids': []}), 201);
      }
      if (path.endsWith('/ai-plan/validate')) {
        return http.Response(
          jsonEncode({
            'results': [
              for (final localId in realPlanLocalIds) {'local_id': localId, 'ok': true, 'warnings': [], 'error': null},
            ],
          }),
          200,
        );
      }
      if (path == '/document/parts/part-1/features/sketch') {
        return http.Response(
          jsonEncode({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'}),
          201,
        );
      }
      if (path == '/sketch/sketches/sketch-1/points') {
        pointCount++;
        return http.Response(
          jsonEncode({'id': 'point-$pointCount', 'x': 0.0, 'y': 0.0}),
          201,
        );
      }
      if (path == '/sketch/sketches/sketch-1/rectangles') {
        return http.Response(
          jsonEncode({
            'id': 'rect-1',
            'corner_point_ids': ['point-1', 'point-2', 'point-3', 'point-4'],
            'line_ids': ['line-1', 'line-2', 'line-3', 'line-4'],
            'axis_aligned': true,
          }),
          201,
        );
      }
      if (path == '/document/parts/part-1/extrude-features') {
        return http.Response(
          jsonEncode({
            'type': 'extrude',
            'id': 'feat-extrude1',
            'locked': false,
            'sketch_feature_id': 'feat-sk1',
            'extrude_type': 'boss',
            'start_distance': 0.0,
            'end_distance': 10.0,
            'target_body_ids': [],
          }),
          201,
        );
      }
      if (path.contains('/cascade')) {
        return http.Response(jsonEncode({'deleted_feature_ids': ['feat-extrude1', 'feat-sk1'], 'deleted_sketch_ids': ['sketch-1']}), 200);
      }
      return http.Response('not found', 404);
    };
  }

  Future<void> sendMessage(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('aiModellingInput')), text);
    await tester.tap(find.byKey(const Key('aiModellingSend')));
    await tester.pumpAndSettle();
  }

  group('provider-configured guard (fix 1 from the `02` doc\'s real end-to-end exercise)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AiProviderPreferences.load();
    });

    testWidgets('shows a dialog on a fresh, unconfigured launch (no provider override)', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AiModellingScreen()));
      await tester.pumpAndSettle();

      expect(find.text('No AI provider configured yet'), findsOneWidget);
    });

    testWidgets('does not show a dialog once the active provider is configured', (tester) async {
      await AiProviderPreferences.saveLocal(baseUrl: 'http://localhost:11434/v1', model: 'llama3');

      await tester.pumpWidget(const MaterialApp(home: AiModellingScreen()));
      await tester.pumpAndSettle();

      expect(find.text('No AI provider configured yet'), findsNothing);
    });

    testWidgets('a provider override bypasses the guard entirely, configured or not', (tester) async {
      final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: 'hi'));

      await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
      await tester.pumpAndSettle();

      expect(find.text('No AI provider configured yet'), findsNothing);
    });

    testWidgets('dismissing with "Not now" greys out Send and shows inline text', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AiModellingScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      final sendButton = tester.widget<IconButton>(find.byKey(const Key('aiModellingSend')));
      expect(sendButton.onPressed, isNull);
      expect(find.textContaining('No AI provider configured'), findsOneWidget);
    });

    testWidgets('"Open Settings" navigates to AiProviderSettingsScreen and re-checks on return', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AiModellingScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();

      expect(find.text('AI Provider Settings'), findsOneWidget);
      // Configure directly via preferences (mirrors what a real Test
      // Connection & Save would persist) then pop back, as if the user
      // cancelled out of the settings screen after saving another way.
      await AiProviderPreferences.saveLocal(baseUrl: 'http://localhost:11434/v1', model: 'llama3');
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('No AI provider configured yet'), findsNothing);
      final sendButton = tester.widget<IconButton>(find.byKey(const Key('aiModellingSend')));
      expect(sendButton.onPressed, isNotNull);
    });
  });

  testWidgets('sending a message shows both the user and assistant turns in the chat', (tester) async {
    final provider = FakeAiProvider((transcript, systemPrompt) async {
      expect(systemPrompt, isNotNull);
      expect(transcript.last.text, 'Design me a bracket');
      return const AiTurnResult(assistantText: 'What thickness would you like?');
    });

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await sendMessage(tester, 'Design me a bracket');

    expect(find.text('Design me a bracket'), findsOneWidget);
    expect(find.text('What thickness would you like?'), findsOneWidget);
  });

  group('image upload gating (workstream 10)', () {
    testWidgets('attach-image button is shown when the active provider supports vision', (tester) async {
      final provider = FakeAiProvider(
        (transcript, systemPrompt) async => const AiTurnResult(assistantText: 'ok'),
        supportsVision: true,
      );

      await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('aiModellingAttachImage')), findsOneWidget);
      expect(find.textContaining('Image upload needs a vision-capable provider'), findsNothing);
    });

    testWidgets('attach-image button is hidden with an explanatory note when vision is unsupported', (tester) async {
      final provider = FakeAiProvider(
        (transcript, systemPrompt) async => const AiTurnResult(assistantText: 'ok'),
        supportsVision: false,
      );

      await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('aiModellingAttachImage')), findsNothing);
      expect(find.textContaining('Image upload needs a vision-capable provider'), findsOneWidget);
    });
  });

  group('voice input gating (workstream 11)', () {
    testWidgets('mic button is hidden on Linux - the only platform this CI test suite itself runs on, and the one '
        'speech_to_text has no implementation for at all', (tester) async {
      final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: 'ok'));

      await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
      await tester.pumpAndSettle();

      // Sanity-check the assumption this test (and `flutter test` on this
      // project's own CI, `runs-on: ubuntu-latest`) relies on - if this
      // ever fails, it's running somewhere other than Linux and the
      // `findsNothing` expectation below no longer means what this test
      // says it means.
      expect(Platform.isLinux, isTrue);
      expect(find.byKey(const Key('aiModellingMic')), findsNothing);
    });
  });

  testWidgets('a detected plan in the assistant reply switches to Review & Generate with a literal-value summary', (
    tester,
  ) async {
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: minimalPlanText));

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await sendMessage(tester, 'External spur gear, module 2, 20 teeth');

    expect(find.text('Proposed plan'), findsOneWidget);
    expect(find.textContaining('module=2'), findsOneWidget);
    expect(find.textContaining('tooth_count=20'), findsOneWidget);
    expect(find.text('Generate'), findsOneWidget);
    expect(find.text('Adjust'), findsOneWidget);
  });

  testWidgets('Generate reuses the created Part for real execution and shows success + Undo', (tester) async {
    final requestedPaths = <String>[];
    final mock = MockClient((request) async {
      requestedPaths.add(request.url.path);
      return realPlanHandler()(request);
    });
    final client = DocumentApiClient(httpClient: mock);
    final sketchClient = SketchApiClient(httpClient: mock);
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: realPlanText));

    await tester.pumpWidget(
      MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client, sketchApi: sketchClient)),
    );
    await sendMessage(tester, 'A 60x40x10mm block');

    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    expect(requestedPaths, contains('/document/parts'));
    expect(requestedPaths, contains('/document/parts/part-1/ai-plan/validate'));
    expect(requestedPaths, contains('/document/parts/part-1/features/sketch'));
    expect(requestedPaths, contains('/sketch/sketches/sketch-1/rectangles'));
    expect(requestedPaths, contains('/document/parts/part-1/extrude-features'));
    // Real execution reuses the one Part `createPart` made - never a second one.
    expect(requestedPaths.where((p) => p == '/document/parts').length, 1);
    expect(find.textContaining('Generated - every step created successfully'), findsOneWidget);
    expect(find.text('Undo this generation'), findsOneWidget);
  });

  testWidgets(
      'Existing-Part editing: Generate never calls startNewDocument/createPart when existingPartId is set '
      '(docs/ai-modelling/09-existing-part-editing.md - the single easiest thing to get wrong here)', (tester) async {
    final requestedPaths = <String>[];
    final mock = MockClient((request) async {
      requestedPaths.add('${request.method} ${request.url.path}');
      if (request.method == 'GET' && request.url.path == '/document/parts/part-1/features') {
        return jsonResponse([]);
      }
      return realPlanHandler()(request);
    });
    final client = DocumentApiClient(httpClient: mock);
    final sketchClient = SketchApiClient(httpClient: mock);
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: realPlanText));

    await tester.pumpWidget(
      MaterialApp(
        home: AiModellingScreen(
          provider: provider,
          documentApi: client,
          sketchApi: sketchClient,
          existingPartId: 'part-1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await sendMessage(tester, 'Add a rectangular boss to this part');

    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    // The one invariant that matters most here: reusing the real, already-
    // open Part - never wiping the session's Document, never creating a
    // second, unrelated Part.
    expect(requestedPaths, isNot(contains('POST /document/new')));
    expect(requestedPaths, isNot(contains('POST /document/parts')));
    expect(requestedPaths, contains('GET /document/parts/part-1/features'));
    expect(requestedPaths, contains('POST /document/parts/part-1/ai-plan/validate'));
    expect(requestedPaths, contains('POST /document/parts/part-1/features/sketch'));
    expect(requestedPaths, contains('POST /document/parts/part-1/extrude-features'));
    expect(find.textContaining('Generated - every step created successfully'), findsOneWidget);
  });

  testWidgets('Existing-Part editing: the system prompt carries the real Feature summary, echoable via existing:<id>',
      (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/document/parts/part-9/features') {
          return jsonResponse([
            {'type': 'sketch', 'id': 'feat-sk9', 'locked': false, 'sketch_id': 'sketch-9', 'produces': 'sketch'},
            {
              'type': 'extrude',
              'id': 'feat-ex9',
              'locked': false,
              'extrude_type': 'boss',
              'start_distance': 0.0,
              'end_distance': 10.0,
              'produces': 'body',
            },
          ]);
        }
        return http.Response('not found', 404);
      }),
    );
    String? capturedSystemPrompt;
    final provider = FakeAiProvider((transcript, systemPrompt) async {
      capturedSystemPrompt = systemPrompt;
      return const AiTurnResult(assistantText: 'What change would you like?');
    });

    await tester.pumpWidget(
      MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client, existingPartId: 'part-9')),
    );
    await tester.pumpAndSettle();
    await sendMessage(tester, 'Add a fillet');

    expect(capturedSystemPrompt, contains('Editing an existing Part'));
    expect(capturedSystemPrompt, contains('existing:feat-sk9'));
    expect(capturedSystemPrompt, contains('existing:feat-ex9'));
  });

  testWidgets(
      'Fix 5: a successful Generate offers "View Part", which pushes (not replaces) PartScreen with the real Part id',
      (tester) async {
    final mock = MockClient((request) async => realPlanHandler()(request));
    final client = DocumentApiClient(httpClient: mock);
    final sketchClient = SketchApiClient(httpClient: mock);
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: realPlanText));

    await tester.pumpWidget(
      MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client, sketchApi: sketchClient)),
    );
    await sendMessage(tester, 'A 60x40x10mm block');
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    expect(find.text('View Part'), findsOneWidget);

    await tester.ensureVisible(find.text('View Part'));
    await tester.tap(find.text('View Part'));
    // The pushed PartScreen's own mesh/feature/sketch fetches aren't
    // stubbed here (irrelevant to what this test is checking - the
    // navigation itself). `pumpAndSettle` would never observe a settled
    // state - once mounted, `PartViewport`'s own render loop keeps
    // requesting frames - so the push transition is driven by a fixed
    // number of pumps instead.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Pushed, not replaced - both screens are still in the widget tree.
    expect(find.byType(AiModellingScreen), findsOneWidget);
    final partScreen = tester.widget<PartScreen>(find.byType(PartScreen));
    expect(partScreen.initialPartId, 'part-1');

    // Popping back returns to `AiModellingScreen` with its state (the Undo
    // banner) intact - a one-way `pushReplacement` would have destroyed it.
    // Not `tester.pageBack()`: it looks for a standard platform back-button
    // widget type, but `PartScreen`'s own `AppBar` uses a custom leading
    // action (its toolbar/plane-selection-mode back handling), so popping
    // directly through the `Navigator` is the reliable way to trigger it in
    // a test.
    Navigator.of(tester.element(find.byType(PartScreen))).pop();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Undo this generation'), findsOneWidget);
  });

  testWidgets('Generate on a validation failure shows the per-step report and never executes anything for real', (
    tester,
  ) async {
    final requestedPaths = <String>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'AI Modelling Part', 'feature_ids': []});
        }
        return jsonResponse({
          'results': [
            {
              'local_id': 'g1',
              'ok': false,
              'warnings': [],
              'error': {'type': 'unknown_local_id'},
            },
          ],
        });
      }),
    );
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: minimalPlanText));

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client)));
    await sendMessage(tester, 'External spur gear, module 2, 20 teeth');
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    expect(find.textContaining('unknown_local_id'), findsOneWidget);
    expect(find.textContaining('1 of 1 step(s) failed validation - nothing was created'), findsOneWidget);
    // Only the create-Part and validate calls happened - no execution.
    expect(requestedPaths, ['/document/new', '/document/parts', '/document/parts/part-1/ai-plan/validate']);
  });

  testWidgets(
      'Fix 3a: a validation report shows the resolved edge count on an ok Fillet/Chamfer row (`02` doc exercise)',
      (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'AI Modelling Part', 'feature_ids': []});
        }
        return jsonResponse({
          'results': [
            {
              'local_id': 'f1',
              'ok': true,
              'warnings': [],
              'error': null,
              'resolved_edges': [
                {'body_id': 'f1', 'shape_type': 'edge', 'index': 0},
                {'body_id': 'f1', 'shape_type': 'edge', 'index': 1},
              ],
            },
            {
              'local_id': 'g1',
              'ok': false,
              'warnings': [],
              'error': {'type': 'unknown_local_id'},
            },
          ],
        });
      }),
    );
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: minimalPlanText));

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client)));
    await sendMessage(tester, 'External spur gear, module 2, 20 teeth');
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    expect(find.textContaining('f1: ok (2 edges)'), findsOneWidget);
    expect(find.textContaining('unknown_local_id'), findsOneWidget);
  });

  testWidgets(
      'Fix 3b: a validation report shows the real hole count on an ok Extrude/Revolve/Sweep row (`02` doc exercise)',
      (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'AI Modelling Part', 'feature_ids': []});
        }
        return jsonResponse({
          'results': [
            {'local_id': 'f1', 'ok': true, 'warnings': [], 'error': null, 'hole_count': 1},
            {
              'local_id': 'g1',
              'ok': false,
              'warnings': [],
              'error': {'type': 'unknown_local_id'},
            },
          ],
        });
      }),
    );
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: minimalPlanText));

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client)));
    await sendMessage(tester, 'External spur gear, module 2, 20 teeth');
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    expect(find.textContaining('f1: ok — includes 1 hole'), findsOneWidget);
  });

  testWidgets(
      'Fix 6: a genuinely all-ok validation response still renders its annotations on a fully successful run',
      (tester) async {
    // Every prior fix-3a/3b test's mocked validate response includes a
    // failing step (the real gap fix 6 closes: `preflightResults` used to
    // be `validationFailed`-only, so a clean run's own `ok: true` rows -
    // this test's whole point - never made it to the panel at all).
    final mock = MockClient((request) async {
      if (request.url.path.endsWith('/ai-plan/validate')) {
        return jsonResponse({
          'results': [
            for (final localId in realPlanLocalIds)
              if (localId == 'f1')
                {'local_id': 'f1', 'ok': true, 'warnings': [], 'error': null, 'hole_count': 1}
              else
                {'local_id': localId, 'ok': true, 'warnings': [], 'error': null},
          ],
        });
      }
      return realPlanHandler()(request);
    });
    final client = DocumentApiClient(httpClient: mock);
    final sketchClient = SketchApiClient(httpClient: mock);
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: realPlanText));

    await tester.pumpWidget(
      MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client, sketchApi: sketchClient)),
    );
    await sendMessage(tester, 'A 60x40x10mm block');
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    // Both the success outcome and the ok-row annotation render together -
    // the panel no longer forces a choice between "see what was built" and
    // "see the hole-count annotation" (fix 6's own reasoning for bundling
    // with fix 5).
    expect(find.textContaining('Generated - every step created successfully'), findsOneWidget);
    expect(find.textContaining('f1: ok — includes 1 hole'), findsOneWidget);
  });

  testWidgets('Generate on a real step failure stops immediately, keeps earlier Features, and offers Undo via chat', (
    tester,
  ) async {
    final mock = MockClient(realPlanHandler(failAtPath: '/document/parts/part-1/extrude-features'));
    final client = DocumentApiClient(httpClient: mock);
    final sketchClient = SketchApiClient(httpClient: mock);
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: realPlanText));

    await tester.pumpWidget(
      MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client, sketchApi: sketchClient)),
    );
    await sendMessage(tester, 'A 60x40x10mm block');
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    // Back in chat mode - the failure is a new turn the user can send back
    // to the LLM (04's own "Real execution and failure handling" section).
    expect(find.text('Proposed plan'), findsNothing);
    expect(find.textContaining('Execution stopped'), findsOneWidget);
    expect(find.textContaining('geometry_failed'), findsOneWidget);
    // The Sketch/Rectangle steps before the failed Extrude are still real -
    // Undo is offered from chat mode, not just the Review & Generate panel.
    expect(find.text('Undo this generation'), findsOneWidget);
  });

  testWidgets('Generate on a gear_request-only plan stops before executing and never fakes a success', (tester) async {
    final requestedPaths = <String>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'AI Modelling Part', 'feature_ids': []});
        }
        return jsonResponse({
          'results': [
            {'local_id': 'g1', 'ok': true, 'warnings': [], 'error': null},
          ],
        });
      }),
    );
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: minimalPlanText));

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client)));
    await sendMessage(tester, 'External spur gear, module 2, 20 teeth');
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    expect(find.text('Proposed plan'), findsNothing);
    expect(find.textContaining("AI Modelling can't create one automatically yet"), findsOneWidget);
    // Nothing beyond create-Part + validate - a gear_request step is never
    // itself executed against the real backend.
    expect(requestedPaths, ['/document/new', '/document/parts', '/document/parts/part-1/ai-plan/validate']);
    // No Features were ever created, so no Undo is offered.
    expect(find.text('Undo this generation'), findsNothing);
  });

  testWidgets('Adjust returns to chat mode with the transcript (including the proposed plan) preserved', (tester) async {
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: minimalPlanText));

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await sendMessage(tester, 'External spur gear, module 2, 20 teeth');
    expect(find.text('Proposed plan'), findsOneWidget);

    await tester.tap(find.text('Adjust'));
    await tester.pumpAndSettle();

    expect(find.text('Proposed plan'), findsNothing);
    expect(find.text('External spur gear, module 2, 20 teeth'), findsOneWidget);
    // The plan-bearing assistant turn is still part of the visible transcript.
    expect(find.textContaining('gear_request'), findsOneWidget);
  });

  testWidgets('Save as preset then Load preset round-trips the plan through GearPresetStore', (tester) async {
    await GearPresetStore.load();
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: minimalPlanText));

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await sendMessage(tester, 'External spur gear, module 2, 20 teeth');
    expect(find.text('Proposed plan'), findsOneWidget);

    await tester.tap(find.text('Save as preset'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'My gear plan');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(GearPresetStore.forKind(aiModellingPlanPresetKind), hasLength(1));
    expect(GearPresetStore.forKind(aiModellingPlanPresetKind).single.name, 'My gear plan');

    // Fresh screen, fresh conversation - Load preset should be offered and
    // should jump straight to Review & Generate without re-running the chat.
    // A distinct Key forces a brand-new State rather than Flutter reusing
    // the still-mounted one from the pump above (same widget type/position).
    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(key: UniqueKey(), provider: provider)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Load preset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My gear plan'));
    await tester.pumpAndSettle();

    expect(find.text('Proposed plan'), findsOneWidget);
    expect(find.textContaining('module=2'), findsOneWidget);
  });
}
