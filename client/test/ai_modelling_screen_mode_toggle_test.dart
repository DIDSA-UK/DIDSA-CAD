import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_generation_mode.dart';
import 'package:didsa_cad_client/ai/ai_modelling_screen.dart';
import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';

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

/// Multi-part/assembly overhaul, Phase A
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the
/// Assembly/Multi-body Part toggle. Kept in its own file (rather than
/// folded into `ai_modelling_screen_test.dart`) since
/// `AiGenerationModePreferences`'s default is process-wide static state -
/// isolating it here means a test that switches the toggle can never
/// leak into that much larger file's own tests, whatever order they run
/// in within a shared isolate.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    // Belt-and-suspenders: restores the class-level default even though
    // `setUp`'s own `setMockInitialValues({})` already means the *next*
    // `load()` would read the same default - nothing in this file calls
    // `load()` without a preceding `setMockInitialValues`, so this is
    // defensive, not load-bearing.
    await AiGenerationModePreferences.setDefaultMode(AiGenerationMode.multiBodyPart);
  });

  testWidgets('a fresh conversation shows the toggle, defaulting to Multi-body Part', (tester) async {
    final provider = _FakeAiProvider((_, __) async => const AiTurnResult(assistantText: 'hi'));
    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('aiModellingModeToggle')), findsOneWidget);
    expect(find.text('Multi-body Part'), findsOneWidget);
    expect(find.text('Assembly'), findsOneWidget);
    // No "coming soon" banner while Multi-body Part (the default) is selected.
    expect(find.textContaining('Assembly mode is not built yet'), findsNothing);
  });

  testWidgets('"Continue with AI" (existingPartId set) never shows the toggle', (tester) async {
    final client = DocumentApiClient(httpClient: MockClient((request) async => http.Response('not found', 404)));
    final provider = _FakeAiProvider((_, __) async => const AiTurnResult(assistantText: 'hi'));
    await tester.pumpWidget(
      MaterialApp(
        home: AiModellingScreen(provider: provider, documentApi: client, existingPartId: 'part-1'),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('aiModellingModeToggle')), findsNothing);
  });

  testWidgets('selecting Assembly shows the "coming soon" banner and disables Send, without calling the provider',
      (tester) async {
    var callCount = 0;
    final provider = _FakeAiProvider((_, __) async {
      callCount++;
      return const AiTurnResult(assistantText: 'hi');
    });
    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Assembly mode is not built yet'), findsOneWidget);
    final sendButton = tester.widget<IconButton>(find.byKey(const Key('aiModellingSend')));
    expect(sendButton.onPressed, isNull);

    // Guards the `onSubmitted` bypass too (Enter key on the text field
    // reaches `_send()` directly, not through the Send button's own
    // `onPressed` gating) - `_send()` itself must also refuse to call the
    // provider while Assembly mode is selected.
    await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A bracket');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(callCount, 0);
  });

  testWidgets('switching back to Multi-body Part re-enables Send', (tester) async {
    final provider = _FakeAiProvider((_, __) async => const AiTurnResult(assistantText: 'hi'));
    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Multi-body Part'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Assembly mode is not built yet'), findsNothing);
    final sendButton = tester.widget<IconButton>(find.byKey(const Key('aiModellingSend')));
    expect(sendButton.onPressed, isNotNull);
  });

  testWidgets('Multi-body Part mode (the default) threads multiBodyPartMode through to the system prompt',
      (tester) async {
    String? capturedSystemPrompt;
    final provider = _FakeAiProvider((_, systemPrompt) async {
      capturedSystemPrompt = systemPrompt;
      return const AiTurnResult(assistantText: 'hi');
    });
    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('aiModellingInput')), 'A bracket with two plates');
    await tester.tap(find.byKey(const Key('aiModellingSend')));
    await tester.pumpAndSettle();

    expect(capturedSystemPrompt, contains('Multi-body Part mode'));
  });

  testWidgets('selecting a mode persists it as the default for the next fresh conversation', (tester) async {
    final provider = _FakeAiProvider((_, __) async => const AiTurnResult(assistantText: 'hi'));
    await tester.pumpWidget(MaterialApp(home: AiModellingScreen(provider: provider)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Assembly'));
    await tester.pumpAndSettle();

    await AiGenerationModePreferences.load();
    expect(AiGenerationModePreferences.defaultMode, AiGenerationMode.assembly);
  });
}
