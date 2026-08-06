import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_modelling_screen.dart';
import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/gear/gear_preset_store.dart';

/// AI Modelling workstream 2: widget-level coverage for
/// [AiModellingScreen] - the chat -> plan-detection -> Review & Generate
/// flow, wiring workstream 5's real validate endpoint on Generate, and the
/// save/load-as-preset bolt-on (`02-scoping-conversation.md`). A fake
/// [AiProvider] stands in for the real network call the same way
/// `openai_compatible_provider_test.dart`'s own `MockClient` does for the
/// CAD backend's HTTP client.
class FakeAiProvider implements AiProvider {
  final Future<AiTurnResult> Function(List<AiChatMessage> transcript, String? systemPrompt) handler;

  FakeAiProvider(this.handler);

  @override
  AiProviderCapabilities get capabilities =>
      const AiProviderCapabilities(supportsStructuredOutput: true, supportsVision: false);

  @override
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt}) =>
      handler(transcript, systemPrompt);
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
    expect(requestedPaths, ['/document/parts', '/document/parts/part-1/ai-plan/validate']);
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
    expect(requestedPaths, ['/document/parts', '/document/parts/part-1/ai-plan/validate']);
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
