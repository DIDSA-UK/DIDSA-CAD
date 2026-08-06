import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// AI Modelling workstream 1: the one provider slot that doesn't speak the
/// OpenAI-compatible wire shape `OpenAiCompatibleProvider` covers - a
/// separate adapter per `01-provider-abstraction.md`, translating
/// Anthropic's native Messages API (`POST /v1/messages`, `x-api-key` +
/// `anthropic-version` headers, `system` as a top-level request field rather
/// than a message role) to the same `AiChatMessage`/`AiTurnResult` shapes
/// `OpenAiCompatibleProvider` produces, so nothing above this interface ever
/// branches on which provider is active.
class AnthropicProvider implements AiProvider {
  static const String baseUrl = 'https://api.anthropic.com';
  static const String _anthropicVersion = '2023-06-01';

  /// A generous ceiling on the assistant's reply/plan, not a token budget
  /// tuned against real usage - the scoping conversation's replies and the
  /// structured plan it eventually emits are both text-shaped, not
  /// bounded by any hard app-side limit.
  static const int _maxResponseTokens = 8192;

  final String apiKey;
  final String model;

  /// Overridable for tests, so a real call never hits the network.
  final http.Client? httpClient;

  AnthropicProvider({required this.apiKey, required this.model, this.httpClient});

  @override
  AiProviderCapabilities get capabilities => const AiProviderCapabilities(
        supportsStructuredOutput: true, // Anthropic's own structured-output support
        supportsVision: false, // workstream 6
      );

  @override
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt}) async {
    final client = httpClient ?? http.Client();
    try {
      final messages = [
        for (final turn in transcript)
          {'role': turn.role == AiMessageRole.user ? 'user' : 'assistant', 'content': turn.text},
      ];

      final response = await client
          .post(
            Uri.parse('$baseUrl/v1/messages'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': _anthropicVersion,
            },
            body: jsonEncode({
              'model': model,
              'max_tokens': _maxResponseTokens,
              if (systemPrompt != null && systemPrompt.isNotEmpty) 'system': systemPrompt,
              'messages': messages,
            }),
          )
          .timeout(aiProviderRequestTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiProviderException(
          'Request failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final content = decoded['content'] as List<dynamic>?;
      if (content == null) {
        throw AiProviderException('Provider response had no content');
      }
      final textBlock = content.cast<Map<String, dynamic>>().firstWhere(
            (block) => block['type'] == 'text',
            orElse: () => const {},
          );
      final text = textBlock['text'] as String? ?? '';
      return AiTurnResult(assistantText: text);
    } on AiProviderException {
      rethrow;
    } catch (e) {
      throw AiProviderException('Could not reach provider: $e');
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
