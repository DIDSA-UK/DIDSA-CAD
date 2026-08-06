# Workstream 1: Provider Abstraction + Settings

Read `00-conventions.md` first. This workstream has no dependencies —
everything else needs it.

## The `AiProvider` interface

```dart
abstract class AiProvider {
  /// Sends the full conversation so far and gets back either another
  /// clarifying turn or a finished structured plan. Every call is a
  /// complete, stateless HTTP request — the full transcript is sent every
  /// time (see 02's own note on why: providers themselves are stateless
  /// HTTP APIs regardless of client-direct vs. backend-broker, so this
  /// isn't a cost specific to the client-direct decision).
  Future<AiTurnResult> sendScopingTurn(List<AiChatMessage> transcript, {String? systemPrompt});

  /// What this configured provider can be relied on for - drives UI
  /// gating (workstream 2's "is this provider ready to receive a plan
  /// request" and workstream 6's future image-upload gating).
  AiProviderCapabilities get capabilities;
}
```

**Correction (workstream 1 implementation)**: the interface as originally
written above took only `transcript` - but `AnthropicProvider`'s own
section below already describes translating "`system` as a top-level field
rather than a message role," which presupposes a system prompt exists
somewhere. Nothing in the original spec actually threaded workstream 2's
system prompt through this call. Fixed by adding the optional
`systemPrompt` parameter shown above: `OpenAiCompatibleProvider` sends it
as a leading `role: "system"` entry in the wire-level `messages` array (a
wire-level role, not one of `AiMessageRole`'s two values -
`AiChatMessage` still only models user/assistant turns),
`AnthropicProvider` sends it as the native top-level `system` field.
Workstream 2 passes its constructed system prompt here directly; it never
has to know which wire shape it becomes.

```dart
class AiChatMessage {
  final AiMessageRole role; // user | assistant
  final String text;
  // Workstream 6 extends this with an optional image payload.
}

class AiTurnResult {
  final String assistantText; // shown in the chat panel either way
  final AiGenerationPlan? plan; // non-null only once scoping is complete
}

class AiProviderCapabilities {
  final bool supportsStructuredOutput;
  final bool supportsVision; // workstream 6
}
```

`AiGenerationPlan` is workstream 3's schema, deserialized here but owned
there.

## `OpenAiCompatibleProvider`

Configured with `baseUrl`, `apiKey` (nullable — local typically has none),
`model`. Builds `POST {baseUrl}/chat/completions` per the OpenAI wire
shape. Covers **two** of the three configured provider slots:

- **OpenAI cloud**: `baseUrl` fixed to `https://api.openai.com/v1`,
  `apiKey` required.
- **Local**: `baseUrl` user-entered (e.g. `http://192.168.1.50:11434/v1`
  for a real, self-hosted Ollama instance's own OpenAI-compatible
  endpoint), `apiKey` optional, `model` whatever the user has pulled
  locally.
  - **Correction/refinement**: Ollama Cloud does **not** require a local
    Ollama install or LAN reachability at all — its OpenAI-compatible
    endpoint is directly reachable at `https://ollama.com/v1` with an
    `apiKey` from ollama.com, exactly like OpenAI/Anthropic cloud are.
    (An earlier version of this note assumed it always needed a local
    daemon acting as an authenticated proxy — that path also exists
    [`ollama signin` + `http://localhost:11434/v1`], but is strictly
    worse than the direct path for a client with no reachable local/LAN
    host, e.g. a phone-only client with no server infra stood up yet.)
    This makes Ollama Cloud a genuine fourth quasi-cloud option
    reachable from the exact same `OpenAiCompatibleProvider`
    implementation — frontier-scale open-weight models (GLM, DeepSeek,
    Kimi) at zero cost, zero local component, `baseUrl`/`apiKey` filled
    in like any other cloud provider despite living in the "local"
    conceptual bucket (open-weight models) rather than the curated
    OpenAI/Anthropic slot. Worth surfacing as its own preset option in
    the settings screen rather than only documented as a manual
    local-`baseUrl` override.

`supportsStructuredOutput` for this implementation: `true` for OpenAI
cloud (JSON mode is a real, documented feature there); for local, treat as
**unknown per-model** rather than a blanket true/false — surface a
"structured output not confirmed for this model" note in settings
(workstream 2's plan-detection logic already has to be robust to a model
that doesn't reliably honour JSON mode, per the fallback below, so this is
advisory rather than a hard gate).

## `AnthropicProvider`

Configured with `apiKey`, `model` (baseUrl fixed to
`https://api.anthropic.com`). Builds `POST /v1/messages` per Anthropic's
own schema (`x-api-key` header, `anthropic-version` header, `system` as a
top-level field rather than a message role) — translates request/response
to/from the same `AiChatMessage`/`AiTurnResult` shapes
`OpenAiCompatibleProvider` produces, so workstream 2 never branches on
which provider is active. `supportsStructuredOutput: true`
(Anthropic's own structured-output support).

## Plan-detection fallback (matters for both implementations)

Not every provider/model reliably honours a "respond with only this JSON
shape" instruction, especially weaker local models. The scoping-turn
parser (workstream 2) must not assume the assistant's response is either
purely conversational or purely a plan — attempt to extract a fenced/
embedded JSON object matching the plan schema from the response text
regardless of what else surrounds it, and fall back to treating the whole
response as a conversational turn if no valid plan object is found. This
is the mechanism that makes the "advisory, not a hard gate"
`supportsStructuredOutput` stance in the section above actually safe.

**Correction (workstream 2 implementation)**: `AiTurnResult.plan` (as built
in workstream 1) is typed as a bare `Object?` and neither concrete
provider ever assigns it — `OpenAiCompatibleProvider`/`AnthropicProvider`
both always return `AiTurnResult(assistantText: ...)` with `plan` left
null; extracting a plan is entirely workstream 2's own job, done by
calling the plan-detection fallback directly against `AiTurnResult.
assistantText` (`client/lib/ai/ai_plan_detection.dart`'s
`detectPlanInAssistantText`), never by reading `result.plan`. This matches
this section's own framing ("The scoping-turn parser (workstream 2) must
not assume...") — `result.plan` itself just isn't the field that
framing runs through in the real implementation. Worth flagging
explicitly since the field's presence on `AiTurnResult` could otherwise
read as "already populated somewhere" to a future session skimming the
interface rather than this section.

## `AiProviderPreferences`

```dart
class AiProviderPreferences {
  AiProviderPreferences._();

  // shared_preferences keys, one set per provider slot, mirroring
  // ApiConfig's own flat-key style:
  //   ai_active_provider: 'local' | 'openai' | 'anthropic'
  //   ai_local_base_url, ai_local_api_key, ai_local_model
  //   ai_openai_api_key, ai_openai_model
  //   ai_anthropic_api_key, ai_anthropic_model

  static Future<void> load() async { /* ... */ }
  static Future<void> setActiveProvider(String provider) async { /* ... */ }
  static Future<void> saveLocal({required String baseUrl, String? apiKey, required String model}) async { /* ... */ }
  static Future<void> saveOpenAi({required String apiKey, required String model}) async { /* ... */ }
  static Future<void> saveAnthropic({required String apiKey, required String model}) async { /* ... */ }

  static AiProvider get active { /* builds the right concrete provider from stored prefs */ }
}
```

## `AiProviderSettingsScreen`

New entry inside `SketcherSettingsScreen` ("CAD Settings" — see
`00-conventions.md` for why there, not a new `ConnectionScreen` icon).
Provider picker (`SegmentedButton`-style, matching
`SketcherSettingsScreen`'s own `Local` / `OpenAI` / `Anthropic` toggle
convention), per-provider fields shown conditionally, a "Test connection"
action mirroring `ConnectionScreen._handleConnect`'s own
"health-check-before-save, never silently save an unverified value"
convention — here, a minimal real API call (e.g. a 1-token completion)
rather than a `/health` endpoint, since none of these providers expose one
uniformly. Include a one-line note on the local-provider reachability
caveat from `00-conventions.md` (LAN-only address won't work if the
client itself is remote).

## Bolt-on: Ollama model-list fetch

The local-provider model field is free text by default (any string the
user's endpoint accepts), but Ollama specifically exposes a native
(non-OpenAI-compat) `GET {baseUrl}/api/tags` listing every model actually
pulled on that server. Opportunistically fetch it when the local
`baseUrl` field changes: on success, replace the free-text model field
with a dropdown of real options; on failure (not Ollama, unreachable, or
any non-2xx) fall back to the plain text field silently, no error shown —
this is a convenience layer on top of the free-text field, not a
requirement, and shouldn't block configuring a non-Ollama local endpoint
that doesn't expose this. Deliberately outside the OpenAI-compatible
unification `OpenAiCompatibleProvider` itself relies on — this fetch is a
settings-screen-only nicety, never part of the actual chat-completion
call path.
