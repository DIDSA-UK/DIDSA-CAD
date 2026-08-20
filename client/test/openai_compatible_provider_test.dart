import 'dart:convert';
import 'dart:typed_data';

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

  test('capabilities.supportsVision reflects the constructor flag', () {
    final vision = OpenAiCompatibleProvider(baseUrl: 'https://api.openai.com/v1', model: 'gpt-5', supportsVision: true);
    final noVision = OpenAiCompatibleProvider(baseUrl: 'http://localhost:11434/v1', model: 'llama3');

    expect(vision.capabilities.supportsVision, isTrue);
    expect(noVision.capabilities.supportsVision, isFalse);
  });

  group('image support (workstream 10)', () {
    final fakeImageBytes = Uint8List.fromList([1, 2, 3, 4]);

    test('sendScopingTurn encodes an imaged turn as text + image_url content blocks', () async {
      Map<String, dynamic> capturedBody = {};
      final provider = OpenAiCompatibleProvider(
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5',
        supportsVision: true,
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

      await provider.sendScopingTurn([
        AiChatMessage(
          role: AiMessageRole.user,
          text: 'What is this?',
          imageBytes: fakeImageBytes,
          imageMimeType: 'image/jpeg',
        ),
      ]);

      final messages = capturedBody['messages'] as List<dynamic>;
      final message = messages.single as Map<String, dynamic>;
      expect(message['role'], 'user');
      final content = message['content'] as List<dynamic>;
      expect(content[0], {'type': 'text', 'text': 'What is this?'});
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(fakeImageBytes)}'},
      });
    });

    test('sendScopingTurn keeps content a plain string for a text-only turn even when other turns carry images', () async {
      Map<String, dynamic> capturedBody = {};
      final provider = OpenAiCompatibleProvider(
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5',
        supportsVision: true,
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

      await provider.sendScopingTurn([
        AiChatMessage(role: AiMessageRole.user, text: 'Look at this', imageBytes: fakeImageBytes, imageMimeType: 'image/jpeg'),
        const AiChatMessage(role: AiMessageRole.assistant, text: 'What am I looking at?'),
        const AiChatMessage(role: AiMessageRole.user, text: 'A bracket'),
      ]);

      final messages = capturedBody['messages'] as List<dynamic>;
      expect((messages[1] as Map<String, dynamic>)['content'], 'What am I looking at?');
      expect((messages[2] as Map<String, dynamic>)['content'], 'A bracket');
    });

    test('extractImageDescription posts a one-shot call with the fixed extraction prompt and returns the reply text', () async {
      Map<String, dynamic> capturedBody = {};
      final provider = OpenAiCompatibleProvider(
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5',
        supportsVision: true,
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'choices': [
              {
                'message': {'content': 'A bracket with two mounting holes, 60mm x 40mm.'},
              },
            ],
          });
        }),
      );

      final description = await provider.extractImageDescription(fakeImageBytes, 'image/png');

      expect(description, 'A bracket with two mounting holes, 60mm x 40mm.');
      final messages = capturedBody['messages'] as List<dynamic>;
      expect(messages.length, 1);
      final content = (messages.single as Map<String, dynamic>)['content'] as List<dynamic>;
      expect((content[0] as Map<String, dynamic>)['type'], 'text');
      expect((content[0] as Map<String, dynamic>)['text'], contains('hand sketch or engineering drawing'));
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,${base64Encode(fakeImageBytes)}'},
      });
    });

    test('extractImageDescription throws without hitting the network when supportsVision is false', () async {
      var called = false;
      final provider = OpenAiCompatibleProvider(
        baseUrl: 'http://localhost:11434/v1',
        model: 'llama3',
        httpClient: MockClient((request) async {
          called = true;
          return jsonResponse({});
        }),
      );

      await expectLater(
        provider.extractImageDescription(fakeImageBytes, 'image/jpeg'),
        throwsA(isA<AiProviderException>()),
      );
      expect(called, isFalse);
    });
  });
}
