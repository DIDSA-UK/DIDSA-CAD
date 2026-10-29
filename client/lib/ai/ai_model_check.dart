/// AI Modelling's render-back check (`docs/ai-modelling/14-render-back-
/// check.md`): after a plan built successfully from an attached drawing, the
/// Part's own line drawing goes back to the provider with the user's drawing
/// and this fixed prompt, so a shape the assistant misread (a round end
/// built as a hole, a leg left out) is caught before the user has to spot it.
library;

import '../api/document_api_client.dart';
import 'ai_provider.dart';

/// The check prompt. The user's drawing(s) come first, the Part's drawing
/// (`DocumentApiClient.getPartDrawing`) last.
String buildAiModelCheckPrompt({required int sketchCount, List<double>? boundingBoxSize}) {
  final drawings = sketchCount == 1 ? 'The first image is' : 'The first $sketchCount images are';
  final size = boundingBoxSize == null
      ? ''
      : ' The model\'s overall size is ${boundingBoxSize.map(_mm).join(' x ')} mm (world X x Y x Z).';
  return '$drawings the user\'s original drawing or sketch of a part. The LAST image is a line drawing '
      'of the CAD model that was built from it, in 3rd angle projection: front view bottom left, top view '
      'above it, right side view to its right, and an isometric view top right. Visible edges are solid, '
      'hidden edges dashed. That drawing has no dimensions, so use the stated size and its proportions.$size\n\n'
      'The model may be oriented differently from the drawing (rotated, or seen from another side), so do '
      'not count orientation, or which view shows what, as a difference. Compare the shape: the overall form '
      'and proportions; every feature (holes, slots, bends, fillets, chamfers, cut-outs, bosses), its count, '
      'size and position; and the overall dimensions against those written on the drawing.\n\n'
      'Reply with exactly MATCH or MISMATCH on the first line. For MISMATCH, then list each difference on its '
      'own line starting with "- ", saying what the drawing shows and what the model has instead. Do not '
      'mention anything that matches, and do not propose CAD steps.';
}

String _mm(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// The provider's verdict. [matches] is null when the reply did not start
/// with MATCH or MISMATCH - shown to the user as-is, never treated as a pass.
class AiModelCheckResult {
  final bool? matches;
  final String details;

  const AiModelCheckResult({required this.matches, required this.details});
}

AiModelCheckResult parseAiModelCheck(String reply) {
  final lines = reply.trim().split('\n');
  final first = lines.isEmpty ? '' : lines.first.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  final rest = lines.skip(1).join('\n').trim();
  if (first.startsWith('MISMATCH')) return AiModelCheckResult(matches: false, details: rest);
  if (first.startsWith('MATCH')) return AiModelCheckResult(matches: true, details: rest);
  return AiModelCheckResult(matches: null, details: reply.trim());
}

/// The `user`-role turn "Ask the AI to fix it" sends: the differences, and a
/// request for a complete plan (the Part is rebuilt from scratch, not
/// patched). Leaves the assistant free to disagree - the check can be wrong.
String aiModelCheckFixRequest(String details) =>
    'The built model was compared with the drawing and does not appear to match:\n$details\n\n'
    'Please check these against the drawing and reply with a complete corrected plan for the whole part '
    '(it will be rebuilt from scratch). If you think the model is right after all, say so instead.';

/// Runs the check for [partId] against every image the user attached in
/// [transcript]. Returns null - no call made - when there is no image or
/// [provider] has no vision. Throws what [DocumentApiClient.getPartDrawing]
/// and [AiProvider.askAboutImages] throw.
Future<AiModelCheckResult?> runAiModelCheck({
  required AiProvider provider,
  required DocumentApiClient documentApi,
  required String partId,
  required List<AiChatMessage> transcript,
}) async {
  final sketches = [
    for (final message in transcript)
      if (message.role == AiMessageRole.user) ...message.images,
  ];
  if (sketches.isEmpty || !provider.capabilities.supportsVision) return null;
  final drawing = await documentApi.getPartDrawing(partId);
  final reply = await provider.askAboutImages(
    [...sketches, AiImageAttachment(bytes: drawing.png, mimeType: 'image/png')],
    buildAiModelCheckPrompt(sketchCount: sketches.length, boundingBoxSize: drawing.boundingBoxSize),
  );
  return parseAiModelCheck(reply);
}
