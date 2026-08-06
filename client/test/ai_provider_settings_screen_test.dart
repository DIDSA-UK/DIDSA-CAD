import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_provider_preferences.dart';
import 'package:didsa_cad_client/ai/ai_provider_settings_screen.dart';

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
