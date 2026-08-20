import 'dart:convert';
import 'dart:typed_data';

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

  /// Workstream 10 (`10-image-input.md`): same advisory-only stance as
  /// [supportsStructuredOutput] above, just for vision - `true` for OpenAI
  /// cloud (its own current models are multimodal); for local, the settings
  /// screen only sets this `true` when the user has explicitly confirmed the
  /// configured model actually accepts images (there is no way for this
  /// class to verify that itself for an arbitrary OpenAI-compatible
  /// endpoint).
  final bool supportsVision;

  /// Overridable for tests, so a real call never hits the network.
  final http.Client? httpClient;

  OpenAiCompatibleProvider({
    required this.baseUrl,
    this.apiKey,
    required this.model,
    this.supportsStructuredOutput = false,
    this.supportsVision = false,
    this.httpClient,
  });

  @override
  AiProviderCapabilities get capabilities =>
      AiProviderCapabilities(supportsStructuredOutput: supportsStructuredOutput, supportsVision: supportsVision);

  static String _trimTrailingSlash(String url) => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  /// The wire `content` value for one transcript turn - a plain string for
  /// an ordinary text-only turn (unchanged shape, so every pre-existing
  /// caller/test keeps working byte-for-byte), or OpenAI's own vision
  /// content-block list (`text` block + `image_url` block with a base64
  /// data URL) when [AiChatMessage.imageBytes] is set.
  static Object _contentFor(AiChatMessage turn) {
    final imageBytes = turn.imageBytes;
    if (imageBytes == null) return turn.text;
    return [
      {'type': 'text', 'text': turn.text},
      {
        'type': 'image_url',
        'image_url': {'url': 'data:${turn.imageMimeType};base64,${base64Encode(imageBytes)}'},
      },
    ];
  }

  Future<http.Response> _postChatCompletions(http.Client client, Map<String, dynamic> body) => client
      .post(
        Uri.parse('${_trimTrailingSlash(baseUrl)}/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
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
    final choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw AiProviderException('Provider response had no choices');
    }
    final message = (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?;
    return message?['content'] as String? ?? '';
  }

  @override
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt}) async {
    final client = httpClient ?? http.Client();
    try {
      final messages = <Map<String, dynamic>>[
        if (systemPrompt != null && systemPrompt.isNotEmpty) {'role': 'system', 'content': systemPrompt},
        for (final turn in transcript)
          {'role': turn.role == AiMessageRole.user ? 'user' : 'assistant', 'content': _contentFor(turn)},
      ];

      final response = await _postChatCompletions(client, {'model': model, 'messages': messages});
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
  /// competing plan-generation path.
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
      final response = await _postChatCompletions(client, {
        'model': model,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': _imageExtractionPrompt},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:$mimeType;base64,${base64Encode(imageBytes)}'},
              },
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
