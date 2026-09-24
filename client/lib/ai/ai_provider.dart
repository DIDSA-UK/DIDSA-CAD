/// AI Modelling workstream 1: the one interface every consumer above the
/// concrete provider implementations (`OpenAiCompatibleProvider`,
/// `AnthropicProvider`) talks to - see `docs/ai-modelling/01-provider-
/// abstraction.md`. Selected at runtime by `AiProviderPreferences`.
library;

import 'dart:typed_data';

/// Who authored a given turn in the scoping conversation. Workstream 10
/// (image input) adds an optional image payload to [AiChatMessage] alongside
/// this - no new role is needed for that (an image rides along with a `user`
/// turn).
enum AiMessageRole { user, assistant }

/// One attached image - bytes plus the mime type they were encoded as.
/// Split out of [AiChatMessage] in the multi-part/assembly overhaul's Phase
/// B (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`) so a message
/// can carry more than one.
class AiImageAttachment {
  final Uint8List bytes;
  final String mimeType;

  const AiImageAttachment({required this.bytes, required this.mimeType});
}

/// One turn of the scoping conversation, in the provider-agnostic shape
/// every [AiProvider] implementation translates its own wire format to/from.
///
/// [images] (workstream 10, `docs/ai-modelling/10-image-input.md`; widened
/// from a single scalar pair to a list in Phase B of the multi-part/
/// assembly overhaul, `docs/ai-modelling/13-multi-part-assembly-overhaul.md`
/// - a request may show several distinct parts across several images, or a
/// single image may show a whole assembly) lets a `user` turn carry
/// attached hand sketch/engineering-drawing images - already downscaled/
/// compressed client-side (`AiModellingScreen`'s own attach flow) before
/// reaching here. Empty (the default) for every ordinary text-only turn.
/// When non-empty, each concrete [AiProvider] encodes every entry as that
/// provider's own native multimodal wire shape in
/// [AiProvider.sendScopingTurn] - every image is resent on every future turn
/// for as long as this message stays in the transcript (the app always
/// resends the full transcript - see [AiProvider.sendScopingTurn]'s own doc
/// comment), which is what keeps them "pinned"/visible to the model for the
/// rest of the conversation, not just the turn they were attached on.
class AiChatMessage {
  final AiMessageRole role;
  final String text;
  final List<AiImageAttachment> images;

  const AiChatMessage({required this.role, required this.text, this.images = const []});
}

/// The result of one `sendScopingTurn` call. [plan] is non-null only once
/// the scoping conversation has produced a complete, schema-conformant
/// structured plan (workstream 3's `AiGenerationPlan`, deserialized here but
/// owned there) - until then, every turn is conversational-only and
/// [assistantText] is shown in the chat panel either way.
class AiTurnResult {
  final String assistantText;
  final Object? plan;

  const AiTurnResult({required this.assistantText, this.plan});
}

/// What a configured provider can be relied on for - drives UI gating
/// (workstream 2's "is this provider ready to receive a plan request" and
/// workstream 10's image-upload gating, `10-image-input.md`).
class AiProviderCapabilities {
  final bool supportsStructuredOutput;
  final bool supportsVision;

  const AiProviderCapabilities({required this.supportsStructuredOutput, required this.supportsVision});
}

/// Raised for any provider call that fails - unreachable host, timeout, or a
/// non-2xx response - mirroring `ApiException`'s own shape
/// (`client/lib/api/sketch_api_client.dart`) for the same reason: one
/// consistent error type callers can catch regardless of which concrete
/// provider is active.
class AiProviderException implements Exception {
  final String message;
  final int? statusCode;

  AiProviderException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Shared across both concrete providers - LLM completions routinely take
/// much longer than the CAD backend's own calls (`ApiConfig.requestTimeout`
/// is 15s), especially against a local/Ollama model with no dedicated GPU,
/// so this is deliberately generous rather than matched to that constant.
///
/// Bug fix (on-device feedback): 60s, this constant's original value, was
/// still too short in practice - a full structured-plan turn (`01`'s own
/// `sendScopingTurn`, `_maxResponseTokens = 8192` on the Anthropic side)
/// is a large completion by LLM standards, and a user reported the 60s
/// timeout firing while the model was, by their own observation, still
/// actively generating - not stalled. Raised to 300s, the same "raise it,
/// document why, once real usage shows the existing allowance is
/// insufficient" pattern `ApiConfig.documentRequestTimeout`
/// (`client/lib/config.dart`, 90s -> 180s) and `spiralBevelPairRequestTimeout`
/// (a dedicated 720s) already established for a slow-but-bounded backend
/// call, applied here for the identical reason on the provider side - a
/// non-streaming `POST`, so the whole completion must land inside one
/// window with no partial-progress signal to extend it by.
const Duration aiProviderRequestTimeout = Duration(seconds: 300);

/// Fixed extraction prompt (workstream 10, `docs/ai-modelling/10-image-
/// input.md`), shared by both concrete providers - the prompt itself is
/// provider-agnostic, only the wire encoding differs, so it lives here
/// rather than as two independently-maintained copies (their pre-Phase-B
/// history: two byte-for-byte duplicate `const` strings, one per provider
/// file). Widened in Phase B of the multi-part/assembly overhaul
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`) to reason about
/// more than one attached image and about images that might show more than
/// one distinct part or a whole assembly, rather than assuming a single
/// part's multiple *views* the way the pre-Phase-B wording did. Deliberately
/// asks only for a literal description, never for CAD steps/JSON, so this
/// stays a clean text seed for the ordinary scoping conversation rather than
/// a second, competing plan-generation path.
const String aiImageExtractionPrompt =
    'You are looking at one or more images of a mechanical/CAD design - this could be a single '
    'part shown from multiple views (e.g. front/top/side, or a folded-profile view plus a flat '
    'view), several distinct separate parts (laid out together in one photo, or one part per '
    'image), or a photo/rendering of a whole assembled unit made of more than one part. Decide '
    'which of these you are looking at from the images themselves - do not assume a single part '
    'by default. If you can tell there is more than one distinct physical part, say so explicitly '
    'up front, give each part a short descriptive name, and describe each one\'s own shape, '
    'features, and dimensions separately, rather than blending them into one description. If it '
    'looks like an assembled unit, also describe how the parts appear to fit/attach together. '
    'Then, for whichever parts you identified, describe each in careful technical detail for '
    'someone who will use your description to plan a 3D CAD model: overall shape and proportions, '
    'distinct features (holes, fillets, chamfers, ribs, bosses, slots, etc.), any dimension '
    'callouts or measurements you can read (quote them exactly as written, including units), and '
    'anything ambiguous or illegible. If a drawing states a projection convention (e.g. "1st '
    'angle" or "3rd angle projection") or labels any axes, quote that exactly too, and say which '
    'view is which (front/top/side/etc.) rather than assuming. For every view, describe hole/'
    'feature positions as distances from that view\'s own labelled edges or corners (e.g. "8mm '
    'from the right edge, 8mm from the top edge") - never as bare "left"/"right"/"top"/"bottom" '
    'without saying which edge, since a photo may be rotated relative to how you are reading it. '
    'Explicitly state how each view lines up with the others (e.g. which edge or feature in one '
    'view corresponds to which in another) so positions given in one view can be placed correctly '
    'relative to geometry defined in a different view. If any view or its text/labels appears '
    'rotated or upside-down in a photo, say so explicitly. Do not propose CAD modelling steps or '
    'JSON - only describe what you see.';

/// The provider-agnostic interface every AI Modelling consumer (the scoping-
/// conversation UI, the translator) talks to - never a concrete provider
/// type directly.
abstract class AiProvider {
  /// Sends the full conversation so far and gets back either another
  /// clarifying turn or a finished structured plan. Every call is a
  /// complete, stateless HTTP request - the full transcript is sent every
  /// time (see workstream 2's own note on why: providers themselves are
  /// stateless HTTP APIs regardless of client-direct vs. backend-broker, so
  /// this isn't a cost specific to the client-direct decision).
  ///
  /// [systemPrompt] is a late addition against `01-provider-abstraction.md`'s
  /// literal interface (which took only [transcript]) - the spec never
  /// threads workstream 2's system prompt through this call despite
  /// `AnthropicProvider`'s own section describing where it goes ("system as
  /// a top-level field rather than a message role"), which presupposes a
  /// system prompt exists somewhere. Added here as optional so each
  /// implementation can place it correctly on the wire (a `system` message
  /// in `OpenAiCompatibleProvider`'s array vs. `AnthropicProvider`'s
  /// top-level `system` field) without workstream 2 having to know the
  /// difference.
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt});

  /// Workstream 10 (`docs/ai-modelling/10-image-input.md`): a one-shot call
  /// against this provider's own vision capability, with its own fixed
  /// extraction prompt - deliberately **not** folded into the main scoping
  /// transcript [sendScopingTurn] drives. Returns a plain-text description
  /// of [images] (already downscaled/compressed by the caller) that the
  /// caller then seeds into the ordinary text-only conversation as context
  /// (a new transcript turn), rather than this call itself becoming part of
  /// that conversation's history. Widened from a single image to a list in
  /// Phase B of the multi-part/assembly overhaul
  /// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`) - [images]
  /// must be non-empty.
  ///
  /// Throws [AiProviderException] if `!capabilities.supportsVision` or
  /// [images] is empty.
  Future<String> extractImageDescription(List<AiImageAttachment> images);

  AiProviderCapabilities get capabilities;
}
