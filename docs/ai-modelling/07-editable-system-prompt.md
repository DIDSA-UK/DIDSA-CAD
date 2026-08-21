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

## Addendum: prompt-content overhaul (2026-08-20, second session)

The locked/editable *split* this workstream built was sound, but the
prompt *content* itself stayed thin as later workstreams landed on top of
it - two worked examples total (a plain extrude+fillet block, and a gear
route), neither ever updated to demonstrate revolve, dimension-driven
fields, or the `existing:<id>` convention, despite all three landing in
the schema/vocabulary since. On-device feedback flagged this directly: a
real conversation's model reported it couldn't reason about a Sketch's own
shape from the Feature tree alone (a *different*, since-fixed gap - see
`09-existing-part-editing.md`'s own addendum) and the prompt gave it
nothing to anchor an `existing:<id>` reply against beyond prose rules.

Four additions, split correctly across the locked/editable boundary this
workstream established:

- **Locked** (`_fewShotExamples`): a new worked revolve example (a
  bushing, axis_ref pointing at a dedicated `construction: true`
  sketch_line, profile offset from the axis so the revolve doesn't
  self-intersect) - the first example touching anything beyond
  extrude/gear_request. The original block+fillet example now also gives
  its rectangle real `width`/`height` fields instead of bare corner
  points, so dimension-driven-sketches (workstream 8) gets a concrete
  example too, not just prose.
- **Locked** (`_unitsConvention`): a new sentence requiring the model to
  convert non-mm/degree input (inches, radians, etc.) itself and name the
  conversion in its own "Assumptions:" line, rather than leaving unit
  handling unspecified.
- **Locked** (`_existingPartEditingBlock`, conditional): a worked
  `existing:<id>` example (a fillet naming a real Feature id from the
  summary above it) - this block is schema-usage content exactly like the
  vocabulary reference, so it belongs locked even though it's inside the
  conditionally-appended block, not `_fewShotExamples` itself; keeping it
  there (rather than in the always-present `_fewShotExamples`) avoids
  paying its token cost on every ordinary fresh-Part conversation, where
  it would never apply.
- **Editable** (`_assistantInstructionsRest`): a self-consistency-check
  paragraph - directly targets `03-structured-plan-schema.md`'s own
  documented Gemini failure (a hallucinated thickness that passed
  structural validation), asking the model to re-verify its own numbers
  against what the user actually stated before finalizing, since a plan
  can be structurally valid and still dimensionally wrong.

`client/test/ai_scoping_prompt_test.dart` gained five new cases covering
all four additions plus the conditional (present only with an
`existingPartSummary`) worked example - each asserting on wrap-safe
substrings rather than exact multi-line text, so a future prose rewrap
doesn't spuriously break the test.
