import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_provider_preferences.dart';
import 'package:didsa_cad_client/ai/ai_provider_settings_screen.dart';
import 'package:didsa_cad_client/ai/ai_system_prompt_settings_screen.dart';

/// AI Modelling workstream 1: widget-level coverage for
/// [AiProviderSettingsScreen] - provider switching, the Ollama
/// model-list-fetch bolt-on's silent-fallback-on-failure behaviour, and
/// "Test Connection & Save" only persisting after a successful call, same
/// health-check-before-save convention `connection_screen.dart` already
/// establishes.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  testWidgets('defaults to the Local segment with empty fields on first launch', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiProviderSettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('API Key'), findsNothing); // local's key field is labeled "(optional)"
    expect(find.text('API Key (optional)'), findsOneWidget);
  });

  testWidgets('switching to OpenAI shows the fixed-baseUrl API key/model fields', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiProviderSettingsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();

    expect(find.text('Base URL'), findsNothing);
    expect(find.text('API Key'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
  });

  testWidgets('switching to Anthropic shows its own API key/model fields', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiProviderSettingsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Anthropic'));
    await tester.pumpAndSettle();

    expect(find.text('Base URL'), findsNothing);
    expect(find.text('API Key'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
  });

  testWidgets('Ollama Cloud preset button fills the local baseUrl field', (tester) async {
    final client = MockClient((request) async => http.Response('not ollama', 404));
    await tester.pumpWidget(MaterialApp(home: AiProviderSettingsScreen(httpClient: client)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ollama Cloud'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final baseUrlField = tester.widget<TextField>(find.widgetWithText(TextField, 'Base URL'));
    expect(baseUrlField.controller?.text, 'https://ollama.com/v1');
  });

  testWidgets('Gemini preset button fills the local baseUrl, a default model, and checks vision support',
      (tester) async {
    // The vision checkbox sits below this ListView's default build extent
    // (same lazy-mounting gap documented on the dedicated vision-checkbox
    // test below) - a tall viewport avoids needing to scroll to reach it.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final client = MockClient((request) async => http.Response('not ollama', 404));
    await tester.pumpWidget(MaterialApp(home: AiProviderSettingsScreen(httpClient: client)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Gemini'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final baseUrlField = tester.widget<TextField>(find.widgetWithText(TextField, 'Base URL'));
    expect(baseUrlField.controller?.text, 'https://generativelanguage.googleapis.com/v1beta/openai');
    final modelField = tester.widget<TextField>(find.widgetWithText(TextField, 'Model'));
    expect(modelField.controller?.text, 'gemini-2.5-flash');
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('aiLocalSupportsVision'))).value, isTrue);
  });

  testWidgets('Groq preset button fills the local baseUrl field', (tester) async {
    final client = MockClient((request) async => http.Response('not ollama', 404));
    await tester.pumpWidget(MaterialApp(home: AiProviderSettingsScreen(httpClient: client)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Groq'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final baseUrlField = tester.widget<TextField>(find.widgetWithText(TextField, 'Base URL'));
    expect(baseUrlField.controller?.text, 'https://api.groq.com/openai/v1');
  });

  testWidgets('a successful Ollama /api/tags fetch replaces the free-text model field with a dropdown',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/api/tags')) {
        return jsonResponse({
          'models': [
            {'name': 'llama3:latest'},
            {'name': 'gpt-oss:20b'},
          ],
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(MaterialApp(home: AiProviderSettingsScreen(httpClient: client)));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Base URL'), 'http://localhost:11434/v1');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
  });

  testWidgets('a failed /api/tags fetch silently keeps the free-text model field (no error shown)', (tester) async {
    final client = MockClient((request) async => http.Response('connection refused', 500));

    await tester.pumpWidget(MaterialApp(home: AiProviderSettingsScreen(httpClient: client)));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Base URL'), 'http://192.168.1.50:11434/v1');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.widgetWithText(TextField, 'Model'), findsOneWidget);
    expect(find.textContaining('Could not reach'), findsNothing);
  });

  testWidgets('Test Connection & Save only persists preferences after a successful call', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/api/tags')) return http.Response('n/a', 404);
      return http.Response('{"error":"invalid api key"}', 401);
    });

    await tester.pumpWidget(MaterialApp(home: AiProviderSettingsScreen(httpClient: client)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'API Key'), 'bad-key');
    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'gpt-5');

    await tester.tap(find.text('Test Connection & Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Request failed (401)'), findsOneWidget);
    // Still on the settings screen (no pop), and nothing was persisted.
    expect(find.byType(AiProviderSettingsScreen), findsOneWidget);
    await AiProviderPreferences.load();
    expect(AiProviderPreferences.openAiApiKey, isEmpty);
  });

  testWidgets(
      'first launch pre-fills the local fields to the free Gemini preset, so only an API key is needed',
      (tester) async {
    // Same reasoning as the Gemini-preset test above: a tall viewport
    // avoids the vision checkbox's lazy-mounting gap below this ListView's
    // default build extent.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final client = MockClient((request) async => http.Response('not ollama', 404));
    await tester.pumpWidget(MaterialApp(home: AiProviderSettingsScreen(httpClient: client)));
    await tester.pumpAndSettle();
    // This synthetic pre-fill deliberately bypasses the baseUrl listener
    // (see `_load()`'s own comment), so no Ollama-model-fetch debounce is
    // in flight here - no extra pump needed before reading the fields back.

    final baseUrlField = tester.widget<TextField>(find.widgetWithText(TextField, 'Base URL'));
    expect(baseUrlField.controller?.text, 'https://generativelanguage.googleapis.com/v1beta/openai');
    final modelField = tester.widget<TextField>(find.widgetWithText(TextField, 'Model'));
    expect(modelField.controller?.text, 'gemini-2.5-flash');
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('aiLocalSupportsVision'))).value, isTrue);
    // The one thing left for the user - never pre-filled.
    final apiKeyField = tester.widget<TextField>(find.widgetWithText(TextField, 'API Key (optional)'));
    expect(apiKeyField.controller?.text, isEmpty);
  });

  testWidgets('local supportsVision checkbox defaults on (Gemini preset) and persists once toggled off and saved',
      (tester) async {
    // The screen's content (explanatory paragraphs, preset buttons, the
    // vision checkbox, Save) is taller than the default test viewport, and
    // scrollUntilVisible proved unreliable here once the Ollama-model-fetch
    // debounce (below) can reflow layout mid-test - scrollUntilVisible
    // itself found the target widget, but a follow-up tap() sometimes
    // landed on a still-mid-scroll-physics frame and hit a different
    // RenderObject instead ("would not hit test on the specified widget").
    // A tall enough surface sidesteps scrolling entirely, same fix already
    // proven for ai_system_prompt_settings_screen_test.dart's add-on test.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final client = MockClient((request) async {
      if (request.url.path.endsWith('/api/tags')) return http.Response('n/a', 404);
      return jsonResponse({
        'choices': [
          {
            'message': {'content': 'ok'},
          },
        ],
      });
    });

    await tester.pumpWidget(MaterialApp(home: AiProviderSettingsScreen(httpClient: client)));
    await tester.pumpAndSettle();
    // (The Gemini pre-fill on load bypasses the baseUrl listener - see
    // `_load()`'s own comment - so no debounced fetch is in flight yet.)

    expect(
      tester.widget<CheckboxListTile>(find.byKey(const Key('aiLocalSupportsVision'))).value,
      isTrue,
    );

    // Switching to a plain local endpoint that is NOT vision-capable - the
    // user turns the checkbox back off, and that choice must persist too.
    await tester.enterText(find.widgetWithText(TextField, 'Base URL'), 'http://localhost:11434/v1');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'llama3');
    await tester.tap(find.byKey(const Key('aiLocalSupportsVision')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test Connection & Save'));
    await tester.pumpAndSettle();

    await AiProviderPreferences.load();
    expect(AiProviderPreferences.localSupportsVision, isFalse);
  });

  testWidgets('AI System Prompt entry navigates to AiSystemPromptSettingsScreen', (tester) async {
    // Same reasoning as the vision-checkbox test above: a tall viewport
    // instead of scrollUntilVisible, now that this screen's content has
    // grown enough for scroll-timing to become genuinely flaky.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MaterialApp(home: AiProviderSettingsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('aiSystemPromptSettingsEntry')));
    await tester.pumpAndSettle();

    expect(find.byType(AiSystemPromptSettingsScreen), findsOneWidget);
  });

  testWidgets('Test Connection & Save persists preferences and pops on success', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/api/tags')) return http.Response('n/a', 404);
      return jsonResponse({
        'choices': [
          {
            'message': {'content': 'ok'},
          },
        ],
      });
    });

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AiProviderSettingsScreen(httpClient: client)),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'API Key'), 'sk-good');
    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'gpt-5');

    await tester.tap(find.text('Test Connection & Save'));
    await tester.pumpAndSettle();

    expect(find.byType(AiProviderSettingsScreen), findsNothing);
    await AiProviderPreferences.load();
    expect(AiProviderPreferences.openAiApiKey, 'sk-good');
    expect(AiProviderPreferences.openAiModel, 'gpt-5');
    expect(AiProviderPreferences.activeProvider, 'openai');
  });
}
