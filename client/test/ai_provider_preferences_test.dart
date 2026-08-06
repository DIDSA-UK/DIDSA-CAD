import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_provider_preferences.dart';
import 'package:didsa_cad_client/ai/anthropic_provider.dart';
import 'package:didsa_cad_client/ai/openai_compatible_provider.dart';

/// AI Modelling workstream 1: [AiProviderPreferences] round-trip tests -
/// `shared_preferences` mocked the same way `gear_preset_store_test.dart`'s
/// own setUp does (no real platform channel under `flutter test`).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load defaults to local with empty fields on first-ever launch', () async {
    await AiProviderPreferences.load();

    expect(AiProviderPreferences.activeProvider, 'local');
    expect(AiProviderPreferences.localBaseUrl, isEmpty);
    expect(AiProviderPreferences.localApiKey, isNull);
    expect(AiProviderPreferences.localModel, isEmpty);
  });

  test('saveLocal persists baseUrl/apiKey/model and load reads them back after a fresh load()', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveLocal(
      baseUrl: 'http://192.168.1.50:11434/v1',
      apiKey: 'local-key',
      model: 'llama3',
    );

    expect(AiProviderPreferences.localBaseUrl, 'http://192.168.1.50:11434/v1');
    expect(AiProviderPreferences.localApiKey, 'local-key');
    expect(AiProviderPreferences.localModel, 'llama3');

    await AiProviderPreferences.load();
    expect(AiProviderPreferences.localBaseUrl, 'http://192.168.1.50:11434/v1');
    expect(AiProviderPreferences.localApiKey, 'local-key');
    expect(AiProviderPreferences.localModel, 'llama3');
  });

  test('saveLocal with no apiKey stores null, not an empty string', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveLocal(baseUrl: 'http://localhost:11434/v1', model: 'llama3');

    expect(AiProviderPreferences.localApiKey, isNull);

    await AiProviderPreferences.load();
    expect(AiProviderPreferences.localApiKey, isNull);
  });

  test('saveLocal clears a previously-saved apiKey when called again with none', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveLocal(baseUrl: 'http://localhost:11434/v1', apiKey: 'key', model: 'llama3');
    expect(AiProviderPreferences.localApiKey, 'key');

    await AiProviderPreferences.saveLocal(baseUrl: 'http://localhost:11434/v1', model: 'llama3');
    expect(AiProviderPreferences.localApiKey, isNull);

    await AiProviderPreferences.load();
    expect(AiProviderPreferences.localApiKey, isNull);
  });

  test('saveOpenAi persists apiKey/model independently of the local slot', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveOpenAi(apiKey: 'sk-openai', model: 'gpt-5');

    expect(AiProviderPreferences.openAiApiKey, 'sk-openai');
    expect(AiProviderPreferences.openAiModel, 'gpt-5');

    await AiProviderPreferences.load();
    expect(AiProviderPreferences.openAiApiKey, 'sk-openai');
    expect(AiProviderPreferences.openAiModel, 'gpt-5');
  });

  test('saveAnthropic persists apiKey/model independently of the other slots', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveAnthropic(apiKey: 'sk-ant', model: 'claude-opus-5');

    expect(AiProviderPreferences.anthropicApiKey, 'sk-ant');
    expect(AiProviderPreferences.anthropicModel, 'claude-opus-5');

    await AiProviderPreferences.load();
    expect(AiProviderPreferences.anthropicApiKey, 'sk-ant');
    expect(AiProviderPreferences.anthropicModel, 'claude-opus-5');
  });

  test('setActiveProvider persists the choice across a fresh load()', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.setActiveProvider('anthropic');

    expect(AiProviderPreferences.activeProvider, 'anthropic');

    await AiProviderPreferences.load();
    expect(AiProviderPreferences.activeProvider, 'anthropic');
  });

  test('active builds an AnthropicProvider when anthropic is the active provider', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveAnthropic(apiKey: 'sk-ant', model: 'claude-opus-5');
    await AiProviderPreferences.setActiveProvider('anthropic');

    expect(AiProviderPreferences.active, isA<AnthropicProvider>());
    final provider = AiProviderPreferences.active as AnthropicProvider;
    expect(provider.apiKey, 'sk-ant');
    expect(provider.model, 'claude-opus-5');
  });

  test('active builds an OpenAiCompatibleProvider with the fixed cloud baseUrl for openai', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveOpenAi(apiKey: 'sk-openai', model: 'gpt-5');
    await AiProviderPreferences.setActiveProvider('openai');

    expect(AiProviderPreferences.active, isA<OpenAiCompatibleProvider>());
    final provider = AiProviderPreferences.active as OpenAiCompatibleProvider;
    expect(provider.baseUrl, AiProviderPreferences.openAiBaseUrl);
    expect(provider.apiKey, 'sk-openai');
    expect(provider.model, 'gpt-5');
    expect(provider.capabilities.supportsStructuredOutput, isTrue);
  });

  test('active builds an OpenAiCompatibleProvider with the user-entered baseUrl for local', () async {
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveLocal(baseUrl: 'http://localhost:11434/v1', model: 'llama3');
    await AiProviderPreferences.setActiveProvider('local');

    expect(AiProviderPreferences.active, isA<OpenAiCompatibleProvider>());
    final provider = AiProviderPreferences.active as OpenAiCompatibleProvider;
    expect(provider.baseUrl, 'http://localhost:11434/v1');
    expect(provider.model, 'llama3');
  });

  test('active defaults to local when the stored active-provider value is unrecognized', () async {
    SharedPreferences.setMockInitialValues({'ai_active_provider': 'something-unexpected'});
    await AiProviderPreferences.load();
    await AiProviderPreferences.saveLocal(baseUrl: 'http://localhost:11434/v1', model: 'llama3');

    expect(AiProviderPreferences.active, isA<OpenAiCompatibleProvider>());
    final provider = AiProviderPreferences.active as OpenAiCompatibleProvider;
    expect(provider.baseUrl, 'http://localhost:11434/v1');
  });
}
