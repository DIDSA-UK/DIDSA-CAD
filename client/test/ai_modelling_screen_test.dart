import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_modelling_screen.dart';
import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
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

  testWidgets('Generate creates a fresh Part and shows workstream 5\'s real per-step validation results', (tester) async {
    final requestedPaths = <String>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'AI Modelling Part', 'feature_ids': []});
        }
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'g1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        return http.Response('not found', 404);
      }),
    );
    final provider = FakeAiProvider((transcript, systemPrompt) async => const AiTurnResult(assistantText: minimalPlanText));

    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider, documentApi: client)));
    await sendMessage(tester, 'External spur gear, module 2, 20 teeth');

    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    expect(requestedPaths, contains('/document/parts'));
    expect(requestedPaths, contains('/document/parts/part-1/ai-plan/validate'));
    expect(find.textContaining('g1: ok'), findsOneWidget);
    expect(find.textContaining('ready to generate once Part generation'), findsOneWidget);
  });

  testWidgets('Generate surfaces a failed step\'s structured error rather than a fake success', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
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
    expect(find.textContaining('1 of 1 step(s) failed validation'), findsOneWidget);
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
