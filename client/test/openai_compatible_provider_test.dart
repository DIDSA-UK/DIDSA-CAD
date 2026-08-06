import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/ai/openai_compatible_provider.dart';

/// AI Modelling workstream 1: [OpenAiCompatibleProvider] tests against a
/// fake [MockClient] - same convention `document_api_client_test.dart`
/// already uses for the CAD backend's own HTTP client - no real network.
void main() {
  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  test('sends messages to POST {baseUrl}/chat/completions and parses the assistant text', () async {
    Uri? capturedUri;
    Map<String, dynamic> capturedBody = {};
    final provider = OpenAiCompatibleProvider(
      baseUrl: 'http://localhost:11434/v1',
      model: 'llama3',
      httpClient: MockClient((request) async {
        capturedUri = request.url;
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'Hello there'},
            },
          ],
        });
      }),
    );

    final result = await provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]);

    expect(capturedUri.toString(), 'http://localhost:11434/v1/chat/completions');
    expect(capturedBody['model'], 'llama3');
    expect(capturedBody['messages'], [
      {'role': 'user', 'content': 'Hi'},
    ]);
    expect(result.assistantText, 'Hello there');
  });

  test('strips a trailing slash from baseUrl before appending the endpoint path', () async {
    Uri? capturedUri;
    final provider = OpenAiCompatibleProvider(
      baseUrl: 'https://api.openai.com/v1/',
      model: 'gpt-5',
      httpClient: MockClient((request) async {
        capturedUri = request.url;
        return jsonResponse({
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
        });
      }),
    );

    await provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]);

    expect(capturedUri.toString(), 'https://api.openai.com/v1/chat/completions');
  });

  test('sends the systemPrompt as a leading system-role wire message', () async {
    Map<String, dynamic> capturedBody = {};
    final provider = OpenAiCompatibleProvider(
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'sk-test',
      model: 'gpt-5',
      httpClient: MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
        });
      }),
    );

    await provider.sendScopingTurn(
      const [AiChatMessage(role: AiMessageRole.user, text: 'Design a bracket')],
      systemPrompt: 'You are a CAD scoping assistant.',
    );

    expect(capturedBody['messages'], [
      {'role': 'system', 'content': 'You are a CAD scoping assistant.'},
      {'role': 'user', 'content': 'Design a bracket'},
    ]);
  });

  test('sends an Authorization bearer header only when apiKey is set', () async {
    Map<String, String> capturedHeaders = {};
    final provider = OpenAiCompatibleProvider(
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'sk-test',
      model: 'gpt-5',
      httpClient: MockClient((request) async {
        capturedHeaders = request.headers;
        return jsonResponse({
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
        });
      }),
    );

    await provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]);

    expect(capturedHeaders['Authorization'], 'Bearer sk-test');
  });

  test('omits the Authorization header when apiKey is null (typical local endpoint)', () async {
    Map<String, String> capturedHeaders = {};
    final provider = OpenAiCompatibleProvider(
      baseUrl: 'http://localhost:11434/v1',
      model: 'llama3',
      httpClient: MockClient((request) async {
        capturedHeaders = request.headers;
        return jsonResponse({
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
        });
      }),
    );

    await provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]);

    expect(capturedHeaders.containsKey('Authorization'), isFalse);
  });

  test('throws AiProviderException with the status code on a non-2xx response', () async {
    final provider = OpenAiCompatibleProvider(
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'bad-key',
      model: 'gpt-5',
      httpClient: MockClient((request) async => http.Response('{"error":"invalid api key"}', 401)),
    );

    await expectLater(
      provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]),
      throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'statusCode', 401)),
    );
  });

  test('throws AiProviderException when the request fails at the network level', () async {
    final provider = OpenAiCompatibleProvider(
      baseUrl: 'http://192.168.1.50:11434/v1',
      model: 'llama3',
      httpClient: MockClient((request) async => throw Exception('connection refused')),
    );

    await expectLater(
      provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]),
      throwsA(isA<AiProviderException>()),
    );
  });

  test('capabilities.supportsStructuredOutput reflects the constructor flag', () {
    final openAi = OpenAiCompatibleProvider(
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-5',
      supportsStructuredOutput: true,
    );
    final local = OpenAiCompatibleProvider(baseUrl: 'http://localhost:11434/v1', model: 'llama3');

    expect(openAi.capabilities.supportsStructuredOutput, isTrue);
    expect(local.capabilities.supportsStructuredOutput, isFalse);
  });
}
