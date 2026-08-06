/// AI Modelling workstream 1: the one interface every consumer above the
/// concrete provider implementations (`OpenAiCompatibleProvider`,
/// `AnthropicProvider`) talks to - see `docs/ai-modelling/01-provider-
/// abstraction.md`. Selected at runtime by `AiProviderPreferences`.
library;

/// Who authored a given turn in the scoping conversation. Workstream 6 adds
/// an optional image payload to [AiChatMessage] alongside this - no new role
/// is needed for that (an image rides along with a `user` turn).
enum AiMessageRole { user, assistant }

/// One turn of the scoping conversation, in the provider-agnostic shape
/// every [AiProvider] implementation translates its own wire format to/from.
class AiChatMessage {
  final AiMessageRole role;
  final String text;

  const AiChatMessage({required this.role, required this.text});
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
/// workstream 6's future image-upload gating).
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
const Duration aiProviderRequestTimeout = Duration(seconds: 60);

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

  AiProviderCapabilities get capabilities;
}
