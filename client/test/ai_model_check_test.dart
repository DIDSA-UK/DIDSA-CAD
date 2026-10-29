import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/ai/ai_model_check.dart';
import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';

class _VisionProvider implements AiProvider {
  _VisionProvider({this.supportsVision = true, this.reply = 'MATCH'});

  final bool supportsVision;
  final String reply;
  List<AiImageAttachment>? askedImages;
  String? askedPrompt;

  @override
  AiProviderCapabilities get capabilities =>
      AiProviderCapabilities(supportsStructuredOutput: true, supportsVision: supportsVision);

  @override
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt}) =>
      throw UnimplementedError();

  @override
  Future<String> extractImageDescription(List<AiImageAttachment> images) => throw UnimplementedError();

  @override
  Future<String> askAboutImages(List<AiImageAttachment> images, String prompt) async {
    askedImages = images;
    askedPrompt = prompt;
    return reply;
  }
}

final _sketch = AiImageAttachment(bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/jpeg');
final _drawingPng = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

DocumentApiClient _drawingServer(List<String> paths) => DocumentApiClient(
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response.bytes(_drawingPng, 200, headers: {'x-bounding-box': '67.00,50.00,200.00'});
      }),
    );

void main() {
  group('parseAiModelCheck', () {
    test('MATCH on the first line is a pass', () {
      final result = parseAiModelCheck('MATCH\n');
      expect(result.matches, isTrue);
    });

    test('MISMATCH keeps the listed differences as details', () {
      final result = parseAiModelCheck('MISMATCH\n- the drawing shows a round end; the model has a hole\n');
      expect(result.matches, isFalse);
      expect(result.details, '- the drawing shows a round end; the model has a hole');
    });

    test('decoration around the verdict word is tolerated', () {
      expect(parseAiModelCheck('**MISMATCH**\n- x').matches, isFalse);
      expect(parseAiModelCheck('Match.').matches, isTrue);
    });

    test('a reply without a verdict is inconclusive, never a pass', () {
      final result = parseAiModelCheck('The model looks broadly similar.');
      expect(result.matches, isNull);
      expect(result.details, 'The model looks broadly similar.');
    });
  });

  test('the prompt names the image order and the overall size', () {
    final prompt = buildAiModelCheckPrompt(sketchCount: 2, boundingBoxSize: [67, 50, 200.5]);
    expect(prompt, contains('The first 2 images are'));
    expect(prompt, contains('The LAST image is a line drawing'));
    expect(prompt, contains('67 x 50 x 200.5 mm'));
    expect(prompt, contains('MATCH or MISMATCH'));
  });

  group('runAiModelCheck', () {
    test('sends every attached sketch, then the Part drawing last, and parses the reply', () async {
      final paths = <String>[];
      final provider = _VisionProvider(reply: 'MISMATCH\n- one leg is missing');
      final result = await runAiModelCheck(
        provider: provider,
        documentApi: _drawingServer(paths),
        partId: 'part-1',
        transcript: [
          AiChatMessage(role: AiMessageRole.user, text: 'model this', images: [_sketch]),
          const AiChatMessage(role: AiMessageRole.assistant, text: 'plan'),
        ],
      );
      expect(paths, ['/document/parts/part-1/drawing.png']);
      expect(provider.askedImages!.length, 2);
      expect(provider.askedImages!.first.bytes, _sketch.bytes);
      expect(provider.askedImages!.last.bytes, _drawingPng);
      expect(provider.askedImages!.last.mimeType, 'image/png');
      expect(provider.askedPrompt, contains('67 x 50 x 200 mm'));
      expect(result!.matches, isFalse);
      expect(result.details, '- one leg is missing');
    });

    test('makes no call at all without an attached image', () async {
      final paths = <String>[];
      final provider = _VisionProvider();
      final result = await runAiModelCheck(
        provider: provider,
        documentApi: _drawingServer(paths),
        partId: 'part-1',
        transcript: [const AiChatMessage(role: AiMessageRole.user, text: 'a 10mm cube')],
      );
      expect(result, isNull);
      expect(paths, isEmpty);
      expect(provider.askedImages, isNull);
    });

    test('makes no call at all when the provider has no vision', () async {
      final paths = <String>[];
      final result = await runAiModelCheck(
        provider: _VisionProvider(supportsVision: false),
        documentApi: _drawingServer(paths),
        partId: 'part-1',
        transcript: [AiChatMessage(role: AiMessageRole.user, text: 'model this', images: [_sketch])],
      );
      expect(result, isNull);
      expect(paths, isEmpty);
    });
  });
}
