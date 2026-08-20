# Workstream 10: Image Input (Hand Sketches / Engineering Drawings)

Read `00-conventions.md` first, then `06-image-input-deferred.md` - this
workstream implements what that file deferred, and deliberately diverges
from one of its recorded decisions (see "A disclosed divergence" below).
**Built** (2026-08-20 session) - the fourth of five extensions planned on
top of the v1 feature (see `07-editable-system-prompt.md`'s own ordering
note: this workstream follows 7, 8, 9).

## The problem

`00-conventions.md`'s v1 scope was text-only: `AiChatMessage` carried a
`role`/`text` pair and nothing else, and neither concrete `AiProvider`
implementation had any way to send an image. `06-image-input-deferred.md`
recorded real decisions from an earlier scoping pass (single-view only, no
photos of real physical objects, the image must stay visible for the whole
conversation, `AiProviderCapabilities.supportsVision` gates the affordance)
but explicitly left the extraction mechanism itself unresolved, pending "a
real design pass" and real research into OCR/CV options.

## A disclosed divergence from `06`'s recorded lean

`06-image-input-deferred.md`'s first recorded decision was **"a dedicated
vision/OCR extraction step, not reliance on provider-native multimodal
understanding"** - the user's own call in that earlier session, understood
even then as "real, separate computer-vision engineering... genuinely bigger
scope than anything else in this doc set."

This session did not build that. Instead: **`AiProvider.extractImageDescription`
calls the *active provider's own* vision capability directly** (OpenAI's
`image_url` content blocks, Anthropic's native `image` content blocks) via a
narrowly-scoped, one-shot call with its own fixed extraction prompt, kept
out of the main scoping-conversation transcript. Its plain-text output seeds
the ordinary text-only conversation as a new turn.

**Why**: building genuine provider-independent OCR/CV (a real vision
pipeline, not just calling someone else's) is large, unscoped engineering -
exactly what `06` itself flagged as out of reach for a first pass. Reusing
the already-viable client-direct multimodal path (the same HTTP calls
`sendScopingTurn` already makes, just with an image content block added) is
small, bounded, and consistent with `00-conventions.md`'s whole
client-direct architecture, at the cost of being provider-dependent - a
local/open model with no vision support at all simply can't offer this
feature (see capability gating below), and a weak local vision model will
produce weak extractions, with no engine-swap possible to compensate.

**This is a real design choice, not a neutral implementation detail** - it
overrides `06`'s own explicit prior decision. Flagged here per this task's
own instruction to disclose rather than silently commit to it. If a future
session wants genuine provider-independent OCR (the original lean), this
extraction call is the one place that would need replacing -
`AiProvider.extractImageDescription`'s contract (bytes/mimeType in, plain
text out) was deliberately kept generic enough that a different
implementation could sit behind the same interface method without touching
any caller.

## What this adds

- An attach-image button in `AiModellingScreen`'s input row, gated entirely
  on `AiProviderCapabilities.supportsVision` (hidden, with an explanatory
  note, when the active provider isn't vision-capable - matches `06`'s own
  recorded gating decision).
- Picking an image downscales/compresses it client-side (longest edge
  bounded to ~1568px) before it ever reaches a provider.
- Sending a turn with an attached image runs the one-shot extraction call
  first, appends its text as a new `user`-role turn, then sends the
  ordinary scoping turn (now including that context) exactly as before.
- The image itself rides along on its own original `AiChatMessage` and is
  resent (as a real multimodal content block) on every future turn for the
  rest of the conversation - not consumed after one turn, matching `06`'s
  UX carryover from the original scoping conversation.

## New/modified files

- **`client/lib/ai/ai_provider.dart`**: `AiChatMessage` gains optional
  `Uint8List? imageBytes` / `String? imageMimeType` (an image rides along
  with a `user` turn). `AiProvider` gains
  `Future<String> extractImageDescription(Uint8List imageBytes, String mimeType)`
  - throws `AiProviderException` if `!capabilities.supportsVision`.
- **`client/lib/ai/openai_compatible_provider.dart`**: refactored
  `sendScopingTurn` to share `_ensureSuccess`/`_assistantTextFrom` helpers
  with the new `extractImageDescription`. A new private `_contentFor(turn)`
  returns a plain string for a text-only turn (byte-for-byte unchanged wire
  shape - every pre-existing test still passes unmodified) or OpenAI's own
  `[{type: text}, {type: image_url, image_url: {url: data:...;base64,...}}]`
  content-block list when the turn carries an image.
  `extractImageDescription` posts a single-message request using the same
  content-block shape, with its own fixed extraction prompt (never the
  scoping system prompt), and returns the assistant's reply text directly -
  never parsed as a plan, never appended to any stored transcript by this
  class itself. New constructor field `supportsVision` (mirrors
  `supportsStructuredOutput`'s own advisory-only stance).
- **`client/lib/ai/anthropic_provider.dart`**: same refactor/shape, using
  Anthropic's own native content-block types - an `image` block (`{type:
  image, source: {type: base64, media_type, data}}`) ahead of the `text`
  block, the order Anthropic's own docs recommend. `capabilities.supportsVision`
  is unconditionally `true` (every current Claude model, 3 and later, is
  multimodal) - no constructor flag needed, unlike the OpenAI-compatible
  slot where vision support genuinely varies by configured model/endpoint.
- **`client/lib/ai/ai_provider_preferences.dart`**: new
  `localSupportsVisionPrefKey`/`localSupportsVision` (defaults `false` -
  opt-in only, since this class has no way to verify an arbitrary
  OpenAI-compatible local/free-tier endpoint's configured model actually
  accepts images, unlike `supportsStructuredOutput` which is at least
  advisory-documented per provider). `saveLocal` gains an optional
  `supportsVision` parameter. `active` passes `supportsVision: true`
  unconditionally for the `openai` slot (OpenAI cloud's own current models
  are multimodal - same advisory stance already established for
  `supportsStructuredOutput: true` there) and `supportsVision:
  _localSupportsVision` for `local`.
- **`client/lib/ai/ai_provider_settings_screen.dart`**: new
  `CheckboxListTile` (`aiLocalSupportsVision`) in the Local provider
  section - **the static warning this task required**, always visible
  regardless of the checkbox's own state: real local/open vision models are
  expected to lag well behind top cloud models specifically at reading hand
  sketches and technical drawings.
- **`client/lib/ai/ai_modelling_screen.dart`**:
  - New `aiImageMaxEdgePx` constant (1568).
  - New pending-image state (`_pendingImageBytes`/`_pendingImageMimeType`/
    `_pendingImageFileName`/`_preparingImage`/`_imageError`) and a small
    preview row (thumbnail + filename + remove button) shown above the
    input row while an image is picked but not yet sent.
  - `_attachImage()`: picks via `FilePicker.platform.pickFiles(type:
    FileType.image)` - the same path-based pattern
    `mesh_viewer_screen.dart`'s own `_pickAndLoad` already established (see
    "Design choices" below for why this matters here too) - then
    downscales/compresses via `flutter_image_compress`. On Linux/Windows
    (no platform implementation in that package - see below), falls back to
    the picked file's raw bytes read directly via `dart:io`, never crashing
    the attach flow.
  - `_send()`: when a pending image exists, runs `extractImageDescription`
    first and appends its result as a second `user`-role turn (same "real
    information fed to the LLM, not something it said" reasoning
    `_appendStoppedRunToTranscript` already established for a stopped-run
    error) - both this and the ordinary `sendScopingTurn` call share the
    same existing `on AiProviderException catch` block, no new error-
    handling path needed. Empty-text-plus-image sends are now allowed (the
    original guard required non-empty text unconditionally).
  - `_ChatBubble` gained an image-aware variant: a thumbnail rendered above
    the text whenever `AiChatMessage.imageBytes` is set - since this bubble
    renders from `_transcript` on every rebuild (not a one-shot render), the
    image stays visibly "pinned" in the scroll history for the rest of the
    conversation, satisfying `06`'s "not consumed after one turn" UX
    requirement without any bespoke always-visible widget.
- **`client/pubspec.yaml`**: new `flutter_image_compress` dependency.

## Design choices worth flagging

- **The extraction text is folded into the transcript as its own turn, not
  appended to the user's typed message.** Considered baking the extraction
  result directly into `userMessage.text` instead, but that would delay
  showing the user's own bubble in the chat until the (potentially slow)
  extraction call finished - a real UX regression against the existing
  "message appears immediately, `_sending` spinner shows while waiting"
  pattern every other turn already has. Splitting it into a second turn
  keeps that pattern intact: the image-carrying `userMessage` appears
  immediately, and the extraction result appears as its own turn once
  ready, exactly mirroring how `_appendStoppedRunToTranscript` already
  injects real-but-not-user-typed information into the conversation.
- **`flutter_image_compress` has no Linux/Windows desktop implementation**
  (confirmed via its own pub.dev platform-support table: Android/iOS/macOS/
  Web only) - a real gap for this app, which targets Android/iOS/Linux/
  Windows (no macOS, no web target exist in this project - confirmed by
  checking `client/`'s own platform directories). Rather than gating the
  whole attach-image affordance by platform (which the task didn't ask for,
  and would be a worse UX than necessary), `_attachImage` catches any
  failure from `compressWithFile` and falls back to the picked file's raw,
  unresized bytes - read via `dart:io` from `file.path`, not through
  `file_picker`'s own `withData` bytes channel. This deliberately reuses
  `mesh_viewer_screen.dart`'s own established discipline for exactly this
  reason: that file's doc comment records a real on-device crash from
  reading a whole file into memory via `file_picker`'s MethodChannel-bytes
  path on Android's small default heap, fixed by always reading large files
  directly via `dart:io` from the path instead. The uncompressed fallback
  means a Linux/Windows upload can be considerably larger than the ~1568px
  cap promises elsewhere - a real, disclosed limitation, not silently
  glossed over.
- **`AiProviderCapabilities.supportsVision` for the local/OpenAI-compatible
  slot is opt-in only, not inferred.** Unlike `supportsStructuredOutput`
  (also advisory-only, but at least documented per-provider in `01`'s own
  notes), there's no way for this app to know whether an arbitrary
  OpenAI-compatible endpoint's configured model accepts images at all - a
  Qwen-VL/llava-style local model does, a plain text Llama does not, and
  both speak the identical wire protocol otherwise. Defaulting to `false`
  until the user explicitly confirms it (the new settings checkbox) avoids
  silently sending an image to a model that will either error or silently
  ignore it - the exact failure mode `06`'s own capability-gating section
  named as the thing to avoid.
- **The fixed extraction prompt asks only for a description, never for CAD
  steps or JSON.** Deliberately kept as a clean text seed for the ordinary
  scoping conversation rather than a second, competing plan-generation
  path - the structured plan still only ever comes from `sendScopingTurn`
  (workstream 3's schema), unchanged.
- **No versioning/migration story** for the new `AiChatMessage` fields or
  the `localSupportsVision` preference - not needed yet (purely additive;
  every pre-existing text-only call path behaves byte-for-byte as before),
  same posture `07`/`08`/`09`'s own "no versioning/migration story" notes
  already established for this doc set.
- **Single-view-only and "no photos of real physical objects" (both `06`'s
  own recorded scope) are enforced by UI copy only, not code** - the attach
  button's tooltip and the settings-screen warning say so, but nothing
  detects or rejects a multi-view composite image or a photo of a real
  part. Matches `06`'s own note that these are UX-level constraints, not
  something to build detection for.

## Tests

- `client/test/openai_compatible_provider_test.dart` - new
  `'image support (workstream 10)'` group: `capabilities.supportsVision`
  reflects the constructor flag; `sendScopingTurn` encodes an imaged turn as
  `[text, image_url]` content blocks with the exact base64 data URL;
  content stays a plain string for text-only turns even when other turns in
  the same transcript carry images; `extractImageDescription` posts a
  single-message request with the fixed extraction prompt and returns the
  reply text; `extractImageDescription` throws `AiProviderException`
  *without* touching the network (a `MockClient` handler flag confirms this)
  when `supportsVision` is false.
- `client/test/anthropic_provider_test.dart` - the equivalent group:
  `capabilities.supportsVision` is always true; `sendScopingTurn` encodes an
  imaged turn as `[image, text]` Anthropic-native content blocks (image
  first); content stays a plain string for text-only turns; extraction
  posts the fixed prompt and returns the reply text.
- `client/test/ai_provider_preferences_test.dart` - four new cases:
  `saveLocal`'s `supportsVision` defaults false and round-trips true after a
  fresh `load()`; `active` builds a local provider whose
  `capabilities.supportsVision` reflects the saved preference; `active`
  builds `openai`/`anthropic` providers with `supportsVision` always true.
- `client/test/ai_provider_settings_screen_test.dart` - one new widget test:
  the local `supportsVision` checkbox defaults off, and toggling it plus
  "Test Connection & Save" persists `true` (read back via a fresh `load()`).
- `client/test/ai_modelling_screen_test.dart` - `FakeAiProvider` gained a
  `supportsVision` constructor flag and an optional
  `imageExtractionHandler`, so it can implement the widened `AiProvider`
  interface (this alone would have been a real compile break otherwise -
  the exact "a mock endpoint a new production code path needed" class of
  gap this session was warned about). Two new widget tests: the attach
  button is present with no gating note when `supportsVision: true`; it's
  absent with the gating note shown when `supportsVision: false`.
- **Deliberately not attempted**: a widget test driving the actual
  `_attachImage()` → `FlutterImageCompress.compressWithFile()` →
  extraction → `_send()` path end-to-end. This codebase has **no existing
  test anywhere** that drives a real `FilePicker.platform.pickFiles`
  interaction (confirmed by checking - there is no
  `mesh_viewer_screen_test.dart` at all, despite `mesh_viewer_screen.dart`
  itself having its own file-picker-driven import flow), so there's no
  established in-repo pattern for mocking that platform channel under
  `flutter test`, and inventing one (e.g. a bespoke test-only backdoor into
  private State fields) felt like exactly the kind of speculative,
  unverifiable-in-this-sandbox surface this session was told to be
  cautious about adding. The `_contentFor`/`extractImageDescription` wire
  behavior the attach flow ultimately depends on is fully covered above;
  the orchestration in `_attachImage`/`_send` that glues file-picking,
  compression, and the extraction call together is the one part of this
  workstream **not** covered by an automated test - a real device/emulator
  pass (this project's own established "on-device feedback round" pattern,
  `README.md`'s delivery-order table) is the natural next-session
  follow-up, same as `08`/`09` both already flagged for their own
  Flutter-side work.

## What could and couldn't be verified this session

**Could verify** (static reasoning + the tests above): every wire-encoding
choice for both providers (content-block shapes, header/body construction,
capability gating logic), the preferences round-trip, the settings-screen
checkbox, and the screen-level capability-gating behavior (button
shown/hidden).

**Could not verify** (no Flutter SDK in this sandbox - `flutter`/`dart` both
absent from `PATH`, the same standing gap every prior AI Modelling session
recorded): none of the tests above were actually run, only written and
reviewed against the existing test files' own conventions. Real
`flutter analyze`/`flutter test` output, and any real on-device behavior of
`file_picker`'s `FileType.image` picker or `flutter_image_compress`'s
`compressWithFile` (including whether `minWidth`/`minHeight` genuinely
behave as an aspect-preserving upper bound the way this session's own web
research concluded, rather than a true floor) - all unverified. The
Linux/Windows fallback path (raw, uncompressed bytes) is reasoned from
`flutter_image_compress`'s own documented platform-support table, not
exercised against a real Linux/Windows build.
