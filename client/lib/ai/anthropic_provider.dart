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
        supportsVision: true, // every current Claude model (3+) is multimodal
      );

  /// The wire `content` value for one transcript turn - a plain string for
  /// an ordinary text-only turn (unchanged shape, so every pre-existing
  /// caller/test keeps working byte-for-byte), or Anthropic's own native
  /// content-block list (one `image` block per attached image, ahead of the
  /// `text` block - the order Anthropic's own docs recommend) when
  /// [AiChatMessage.images] is non-empty. Widened from a single fixed pair
  /// to N image blocks in Phase B of the multi-part/assembly overhaul
  /// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`) - the wire
  /// shape (a plain content-block array) already supported this; only this
  /// function's own fixed-pair assumption didn't.
  static Object _contentFor(AiChatMessage turn) {
    if (turn.images.isEmpty) return turn.text;
    return [
      for (final image in turn.images)
        {
          'type': 'image',
          'source': {'type': 'base64', 'media_type': image.mimeType, 'data': base64Encode(image.bytes)},
        },
      {'type': 'text', 'text': turn.text},
    ];
  }

  Future<http.Response> _postMessages(http.Client client, Map<String, dynamic> body) => client
      .post(
        Uri.parse('$baseUrl/v1/messages'),
        headers: {'Content-Type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': _anthropicVersion},
        body: jsonEncode(body),
      )
      .timeout(aiProviderRequestTimeout);

  static void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiProviderException(
        'Request failed (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  static String _assistantTextFrom(http.Response response) {
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final content = decoded['content'] as List<dynamic>?;
    if (content == null) {
      throw AiProviderException('Provider response had no content');
    }
    final textBlock = content.cast<Map<String, dynamic>>().firstWhere(
          (block) => block['type'] == 'text',
          orElse: () => const {},
        );
    return textBlock['text'] as String? ?? '';
  }

  @override
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt}) async {
    final client = httpClient ?? http.Client();
    try {
      final messages = [
        for (final turn in transcript)
          {'role': turn.role == AiMessageRole.user ? 'user' : 'assistant', 'content': _contentFor(turn)},
      ];

      final response = await _postMessages(client, {
        'model': model,
        'max_tokens': _maxResponseTokens,
        if (systemPrompt != null && systemPrompt.isNotEmpty) 'system': systemPrompt,
        'messages': messages,
      });
      _ensureSuccess(response);
      return AiTurnResult(assistantText: _assistantTextFrom(response));
    } on AiProviderException {
      rethrow;
    } catch (e) {
      throw AiProviderException('Could not reach provider: $e');
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<String> extractImageDescription(List<AiImageAttachment> images) async {
    if (!capabilities.supportsVision) {
      throw AiProviderException(
        'The active provider is not configured for vision - enable it in AI Provider Settings before attaching an image.',
      );
    }
    if (images.isEmpty) {
      throw AiProviderException('extractImageDescription called with no images');
    }
    final client = httpClient ?? http.Client();
    try {
      final response = await _postMessages(client, {
        'model': model,
        'max_tokens': _maxResponseTokens,
        'messages': [
          {
            'role': 'user',
            'content': [
              for (final image in images)
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': image.mimeType, 'data': base64Encode(image.bytes)},
                },
              {'type': 'text', 'text': aiImageExtractionPrompt},
            ],
          },
        ],
      });
      _ensureSuccess(response);
      return _assistantTextFrom(response);
    } on AiProviderException {
      rethrow;
    } catch (e) {
      throw AiProviderException('Could not reach provider: $e');
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
