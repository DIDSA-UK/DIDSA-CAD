import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// AI Modelling workstream 1: covers both configured provider slots that
/// speak the OpenAI `POST {baseUrl}/chat/completions` wire shape - OpenAI
/// cloud and any local/Ollama-style endpoint (including Ollama Cloud, which
/// lives in the "local" conceptual bucket per `01-provider-abstraction.md`
/// despite being reachable at a fixed cloud `baseUrl`) - see that file's own
/// section for why one implementation covers both. Never used for Anthropic
/// (`AnthropicProvider`'s own file), whose native Messages API isn't
/// wire-compatible with this shape.
class OpenAiCompatibleProvider implements AiProvider {
  final String baseUrl;
  final String? apiKey;
  final String model;

  /// `01`'s own advisory stance: `true` for OpenAI cloud (JSON mode is a
  /// real, documented feature there); for local/Ollama Cloud, callers should
  /// pass `false` (or leave the settings screen's own "not confirmed for
  /// this model" note visible) since honouring a JSON-only instruction is
  /// per-model, not something this implementation can verify.
  final bool supportsStructuredOutput;

  /// Overridable for tests, so a real call never hits the network.
  final http.Client? httpClient;

  OpenAiCompatibleProvider({
    required this.baseUrl,
    this.apiKey,
    required this.model,
    this.supportsStructuredOutput = false,
    this.httpClient,
  });

  @override
  AiProviderCapabilities get capabilities => AiProviderCapabilities(
        supportsStructuredOutput: supportsStructuredOutput,
        supportsVision: false, // workstream 6
      );

  static String _trimTrailingSlash(String url) => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  @override
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt}) async {
    final client = httpClient ?? http.Client();
    try {
      final messages = <Map<String, String>>[
        if (systemPrompt != null && systemPrompt.isNotEmpty) {'role': 'system', 'content': systemPrompt},
        for (final turn in transcript)
          {'role': turn.role == AiMessageRole.user ? 'user' : 'assistant', 'content': turn.text},
      ];

      final response = await client
          .post(
            Uri.parse('${_trimTrailingSlash(baseUrl)}/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({'model': model, 'messages': messages}),
          )
          .timeout(aiProviderRequestTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiProviderException(
          'Request failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = decoded['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        throw AiProviderException('Provider response had no choices');
      }
      final message = (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?;
      final content = message?['content'] as String? ?? '';
      return AiTurnResult(assistantText: content);
    } on AiProviderException {
      rethrow;
    } catch (e) {
      throw AiProviderException('Could not reach provider: $e');
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
