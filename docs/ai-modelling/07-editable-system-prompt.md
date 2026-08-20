# Workstream 7: Editable System Prompt + Design-Context Add-Ons

Read `00-conventions.md` first. **Built** (2026-08-20 session) — the first of
five extensions planned on top of the v1 feature (see that planning
session's own ordering: this workstream first, since it's the smallest and
most self-contained, followed by dimension-driven sketches, then
existing-Part editing, then image upload, then voice input).

## What this adds

`ai_scoping_prompt.dart`'s system prompt was five hardcoded, concatenated
string constants with no user-facing surface at all. This splits it into:

- **Locked core** (never user-editable): the vocabulary reference, units
  convention, few-shot examples, and — critically — a new
  `_planTerminationFooter` carrying the "final reply must be a single
  fenced JSON block" instruction. This last piece is the LLM's only
  structural contract with `detectPlanInAssistantText`
  (`ai_plan_detection.dart`) - a user override that accidentally dropped it
  would silently break every future scoping conversation, so it's
  unconditionally appended last regardless of what the user's override
  contains.
- **Editable "assistant instructions"** (`_defaultAssistantInstructions`):
  role/premise plus the two conversational-style guidance paragraphs (ask
  before guessing, prefer gear-request routing). A user can override this
  block entirely via `AiSystemPromptPreferences.override` - changes tone
  and process, never the model's schema knowledge or reply-format contract.
- **Design-context add-ons** (`ai_prompt_addons.dart`): seven togglable text
  blocks (Structural, Plastic, Casting, Weldments, 3D Print, Sheet Metal,
  Machining), each a manufacturing-consideration nudge appended after the
  editable block, before the locked footer. **Prompt-guidance text only** -
  this tool has no Sheet Metal/Weldment/Casting Feature type at all, so an
  add-on can only change what the AI *asks about* and *chooses* within the
  existing plan schema (wall thickness, fillet radii, overhang warnings),
  never what it's able to generate.

## New files

- `client/lib/ai/ai_prompt_addons.dart` - the `aiPromptAddOns` map. Keys are
  persisted (`AiSystemPromptPreferences.enabledAddOns`) - never rename one
  once shipped.
- `client/lib/ai/ai_system_prompt_preferences.dart` - `shared_preferences`-
  backed, exact `AiProviderPreferences` load()/setX()/getter shape.
  `override` (nullable `String`) and `enabledAddOns` (`Set<String>`, stored
  via `setStringList`/`getStringList` - no JSON encoding needed, unlike
  `GearPresetStore`'s field pattern, since a flat string list is already a
  native `shared_preferences` type).
- `client/lib/ai/ai_system_prompt_settings_screen.dart` - reached via a new
  list entry inside `AiProviderSettingsScreen` (same "CAD Settings"-adjacent
  placement convention `00-conventions.md` established for that screen
  itself). Editable multi-line field for the assistant instructions,
  Reset-to-default, Save, one `SwitchListTile` per add-on, and a collapsed
  read-only view of the locked content.

## Modified files

- `ai_scoping_prompt.dart` - `buildAiScopingSystemPrompt` gains
  `{String? assistantInstructionsOverride, Set<String> enabledAddOns}`.
  Also exposes `defaultAssistantInstructions` and
  `lockedSystemPromptContent` as public getters for the settings screen.
- `ai_modelling_screen.dart` - `_send()` reads
  `AiSystemPromptPreferences.override`/`.enabledAddOns` and threads them
  through on every turn.
- `connection_screen.dart` - `AiSystemPromptPreferences.load()` added
  alongside the existing `AiProviderPreferences.load()` call at the app's
  one real startup/revisit choke point (same bug class that call itself was
  originally added to fix - see that file's own doc comment).

## Design choices worth flagging

- **Blank-or-unchanged-from-default override is stored as "no override"**
  (`setOverride`'s own trim-and-compare handling, mirrored by the settings
  screen's own save logic) - avoids a stored override that's byte-for-byte
  identical to the default silently surviving a future default-text change.
- **No versioning/migration story** for a saved override drifting out of
  sync with a future change to the locked sections - not needed yet (only
  one shipped default so far), worth a real look if the locked content ever
  changes materially.
- Future workstreams (existing-Part editing, dimension-driven sketches)
  each need their own always-on, unconditionally-appended prompt component
  - this workstream's locked/editable split is built with that shape in
  mind (append after the editable block, before the footer), so neither
  should require touching this file's core assembly logic.

## Tests

- `client/test/ai_system_prompt_preferences_test.dart` - preferences
  round-trip.
- `client/test/ai_scoping_prompt_test.dart` - assembly order, the
  locked-footer-survives-an-override invariant, add-on inclusion/unknown-id
  skipping.
- `client/test/ai_system_prompt_settings_screen_test.dart` - widget-level
  edit/save/reset/toggle round-trips.
- `client/test/ai_provider_settings_screen_test.dart` - one new test
  confirming the new list entry navigates correctly.
