import 'dart:convert';
import 'dart:typed_data';

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
  /// content-block list (an `image` block ahead of the `text` block, the
  /// order Anthropic's own docs recommend) when [AiChatMessage.imageBytes]
  /// is set.
  static Object _contentFor(AiChatMessage turn) {
    final imageBytes = turn.imageBytes;
    if (imageBytes == null) return turn.text;
    return [
      {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': turn.imageMimeType, 'data': base64Encode(imageBytes)},
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

  /// Fixed extraction prompt (workstream 10) - deliberately asks only for a
  /// literal description, never for CAD steps/JSON, so this stays a clean
  /// text seed for the ordinary scoping conversation rather than a second,
  /// competing plan-generation path. Kept identical in wording to
  /// `OpenAiCompatibleProvider`'s own copy - the prompt is provider-agnostic,
  /// only the wire encoding differs between the two implementations.
  static const String _imageExtractionPrompt =
      'You are looking at a hand sketch or engineering drawing of a mechanical/CAD part. '
      'Describe it in careful technical detail for someone who will use your description to '
      'plan a 3D CAD model: overall shape and proportions, distinct features (holes, fillets, '
      'chamfers, ribs, bosses, slots, etc.), any dimension callouts or measurements you can '
      'read (quote them exactly as written, including units), and anything ambiguous or '
      'illegible. Do not propose CAD modelling steps or JSON - only describe what you see.';

  @override
  Future<String> extractImageDescription(Uint8List imageBytes, String mimeType) async {
    if (!capabilities.supportsVision) {
      throw AiProviderException(
        'The active provider is not configured for vision - enable it in AI Provider Settings before attaching an image.',
      );
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
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': mimeType, 'data': base64Encode(imageBytes)},
              },
              {'type': 'text', 'text': _imageExtractionPrompt},
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
