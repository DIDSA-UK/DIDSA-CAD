import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/ai/anthropic_provider.dart';

/// AI Modelling workstream 1: [AnthropicProvider] tests against a fake
/// [MockClient] - covers the translation to/from Anthropic's native
/// Messages API shape (`x-api-key`/`anthropic-version` headers, `system` as
/// a top-level field, `content` as a list of typed blocks) per
/// `01-provider-abstraction.md`.
void main() {
  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  test('posts to /v1/messages with x-api-key and anthropic-version headers', () async {
    Uri? capturedUri;
    Map<String, String> capturedHeaders = {};
    final provider = AnthropicProvider(
      apiKey: 'sk-ant-test',
      model: 'claude-opus-5',
      httpClient: MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return jsonResponse({
          'content': [
            {'type': 'text', 'text': 'Hello there'},
          ],
        });
      }),
    );

    await provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]);

    expect(capturedUri.toString(), 'https://api.anthropic.com/v1/messages');
    expect(capturedHeaders['x-api-key'], 'sk-ant-test');
    expect(capturedHeaders['anthropic-version'], '2023-06-01');
  });

  test('sends model/max_tokens/messages and parses the first text content block', () async {
    Map<String, dynamic> capturedBody = {};
    final provider = AnthropicProvider(
      apiKey: 'sk-ant-test',
      model: 'claude-opus-5',
      httpClient: MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({
          'content': [
            {'type': 'text', 'text': 'Sure, here is a plan.'},
          ],
        });
      }),
    );

    final result = await provider.sendScopingTurn(
      const [AiChatMessage(role: AiMessageRole.user, text: 'Design a bracket')],
    );

    expect(capturedBody['model'], 'claude-opus-5');
    expect(capturedBody['max_tokens'], isNotNull);
    expect(capturedBody['messages'], [
      {'role': 'user', 'content': 'Design a bracket'},
    ]);
    expect(capturedBody.containsKey('system'), isFalse);
    expect(result.assistantText, 'Sure, here is a plan.');
  });

  test('sends systemPrompt as the top-level system field, never as a message', () async {
    Map<String, dynamic> capturedBody = {};
    final provider = AnthropicProvider(
      apiKey: 'sk-ant-test',
      model: 'claude-opus-5',
      httpClient: MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
        });
      }),
    );

    await provider.sendScopingTurn(
      const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')],
      systemPrompt: 'You are a CAD scoping assistant.',
    );

    expect(capturedBody['system'], 'You are a CAD scoping assistant.');
    expect(capturedBody['messages'], [
      {'role': 'user', 'content': 'Hi'},
    ]);
  });

  test('translates assistant transcript turns to role: assistant', () async {
    Map<String, dynamic> capturedBody = {};
    final provider = AnthropicProvider(
      apiKey: 'sk-ant-test',
      model: 'claude-opus-5',
      httpClient: MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
        });
      }),
    );

    await provider.sendScopingTurn(const [
      AiChatMessage(role: AiMessageRole.user, text: 'Hi'),
      AiChatMessage(role: AiMessageRole.assistant, text: 'What dimensions?'),
      AiChatMessage(role: AiMessageRole.user, text: '60x40x10mm'),
    ]);

    expect(capturedBody['messages'], [
      {'role': 'user', 'content': 'Hi'},
      {'role': 'assistant', 'content': 'What dimensions?'},
      {'role': 'user', 'content': '60x40x10mm'},
    ]);
  });

  test('finds the text block even when a non-text block precedes it', () async {
    final provider = AnthropicProvider(
      apiKey: 'sk-ant-test',
      model: 'claude-opus-5',
      httpClient: MockClient((request) async => jsonResponse({
            'content': [
              {'type': 'thinking', 'thinking': 'internal reasoning'},
              {'type': 'text', 'text': 'the actual reply'},
            ],
          })),
    );

    final result = await provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]);

    expect(result.assistantText, 'the actual reply');
  });

  test('throws AiProviderException with the status code on a non-2xx response', () async {
    final provider = AnthropicProvider(
      apiKey: 'bad-key',
      model: 'claude-opus-5',
      httpClient: MockClient((request) async => http.Response('{"error":{"message":"invalid x-api-key"}}', 401)),
    );

    await expectLater(
      provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]),
      throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'statusCode', 401)),
    );
  });

  test('throws AiProviderException when the request fails at the network level', () async {
    final provider = AnthropicProvider(
      apiKey: 'sk-ant-test',
      model: 'claude-opus-5',
      httpClient: MockClient((request) async => throw Exception('timed out')),
    );

    await expectLater(
      provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]),
      throwsA(isA<AiProviderException>()),
    );
  });

  test('capabilities.supportsStructuredOutput is always true', () {
    final provider = AnthropicProvider(apiKey: 'sk-ant-test', model: 'claude-opus-5');
    expect(provider.capabilities.supportsStructuredOutput, isTrue);
  });
}
