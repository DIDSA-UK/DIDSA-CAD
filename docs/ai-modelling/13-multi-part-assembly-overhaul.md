# Workstream 13: Multi-Part & Assembly Overhaul

Read `00-conventions.md` first. Depends on 1, 2, 3, 5 (the core pipeline)
and cross-references `docs/assembly-scope.md` throughout (Phase 15's
multi-file save flow, Phase 18's `add_component`/`StorageService.listFiles`,
Phase 14's mate edge-selector heuristic) - the two doc sets describe the
same underlying assembly data model/pipeline from two different angles
(this one from the AI-authoring side, that one from the manual-UI side) and
should be read together for this workstream specifically.

**Status**: Phases A, B, C **implemented** (this session). Phases D, D2, E
are planned, locked in design, **not yet built** - see each section below.

## Context

Every AI plan before this workstream targets exactly one Part, always
freshly created (`00-conventions.md`'s "v1 always starts a fresh Part" / "No
multi-Part assemblies"). `ai_plan_schemas.py`'s `PlanStep` union (29 kinds
as of this session), `_PlanValidator` (`backend/app/document/ai_plan.py`),
and `PlanTranslator` (`client/lib/ai/ai_plan_translator.dart`) are all
single-Part-scoped throughout - confirmed directly against the code, not
assumed from doc prose, before any of this workstream's design was locked.

The goal: go from a photo/rendering/description of a whole assembly (or
several distinct parts) to a saved, mated, real multi-file assembly, opened
and ready to use. None of that existed before this workstream.

**The finding that reshaped the whole plan**:
`backend/app/document/extrude.py`'s `compute_part_bodies` already tracks a
Part's Bodies in a dict keyed by stable Body id - a Part already natively
supports several independent, non-boolean-merged Bodies, with **zero**
schema or translator change needed. So a **"Multi-body Part" mode**
(several recognized sub-parts modeled as independent Sketch->Extrude
chains inside *one* ordinary Part, never merged) is almost entirely a
prompt/UX problem, not an architecture one. The much larger lift is
entirely in **"Assembly" mode** (separate files, auto-named, mated
together). The user-requested UI toggle between the two maps directly onto
this real architectural fork, and gives a genuinely small, safe first phase
(Multi-body Part) that validates the LLM's part-recognition prompting
before the much larger assembly-orchestration work is attempted.

## Locked decisions

- **Multi-part authoring architecture (Phases D/E)**: orchestrate **N
  sequential single-Part plan/dry-run/execute/save cycles** from
  `AiModellingScreen`, reusing today's existing schema/`_PlanValidator`/
  `PlanTranslator` completely unchanged per cycle - never redesign the plan
  schema to be natively multi-Part. Each part cycle ends with a real
  save-to-disk before the next cycle starts, so the assembly cycle's
  `add_component` step (already shipped, `docs/assembly-scope.md` §2t)
  references it by that now-real `relative_path` - no new plan-local
  "just-written-to-disk" mechanism is needed.
- **Save gate**: the AI proposes a convention-following, collision-checked
  filename; a human confirms/edits it before anything is written to disk -
  matches this app's existing no-silent-writes posture
  (`docs/assembly-scope.md` §2r's relative-path dialog).
- **Project folder**: required up front, at both AI Modelling entry points,
  before the conversation can start (Phase C, implemented).
- **Undo/cleanup**: this workstream does not attempt to delete a file it
  already wrote as part of an undo. "Undo this generation" keeps its
  existing scope (in-memory Features/Occurrences not yet saved); a saved
  file is manual cleanup, same posture as the rest of the app. A disclosed,
  deliberate v1 limitation, not an oversight.
- **Mate edge/face resolution on freshly-placed assembly components
  (Phase D2)**: widen `_PlanValidator`/the dry-run endpoint to be
  **Document-scoped**, not Part-scoped. A real, currently-open gap, not a
  hypothetical - `backend/app/document/ai_plan.py`'s
  `_resolve_mate_edge_selector` hard-rejects a Mate step's `edge_selector`
  for any `occurrence_id` other than `""` (the currently-open Part's own
  root content): `"{field}.edge_selector is only supported for
  occurrence_id == '' (the currently-open Part's own root content)"`,
  because `_PlanValidator.__init__` takes exactly one `part: Part` and has
  no `Document`/multi-Part access at all. `docs/assembly-scope.md` §2q
  (Phase 14) built the selector mechanism for Mates but explicitly scoped
  it to the root Part only, flagging the cross-Part case as a known,
  unclosed limitation - never picked up since, because `add_component`/
  assembly-mode generation didn't exist yet to need it. A real prerequisite
  for Phase E: mating two just-created components requires resolving each
  one's mate face/edge against *its own* target Part's real geometry, not
  the assembly's root Part.

## Phase breakdown

```
A: Mode toggle + multi-body-part mode  ──┐
B: Multi-image upload per turn           ├──> D: Multi-part orchestration --> E: Assembly creation + mate + open
C: Mandatory project folder + naming     ──┘                                  ^
D2: Document-scoped mate edge/face resolution (backend, independent) --------/
```

A, B, C, and D2 are mutually independent and can ship in any order. D needs
A (the toggle is Assembly mode's entry point) and C (naming/folder); B
materially improves D/E's real-world usefulness (a photo of a whole
assembly) but isn't a hard blocker for D's text-only path. D2 is pure
backend work with no dependency on D's client orchestration - it can be
built in parallel with A/B/C/D, but E cannot author a real mate between two
just-created components until D2 ships. E is a strict follow-on to D **and**
D2.

---

## Phase A — Mode toggle + multi-body-part generation (implemented)

New segmented toggle (`Key('aiModellingModeToggle')`) in
`AiModellingScreen`'s chat body, **Multi-body Part** vs **Assembly**, shown
only for a fresh conversation (`widget.existingPartId == null` - "Continue
with AI" already targets one specific existing Part, which neither mode's
"recognize several distinct parts" framing fits). Persisted as a default
preference (`AiGenerationModePreferences`, new
`client/lib/ai/ai_generation_mode.dart`, mirroring
`AiSystemPromptPreferences`'s `shared_preferences` load()/getter/setter
pattern exactly - `AiGenerationModePreferences.load()` wired into
`connection_screen.dart`'s existing startup choke point alongside the other
AI preference loads) with a per-conversation override (`_mode` state,
initialized from the default, changed via `_setMode`, which both updates
local state and persists the new default immediately - the toggle itself
*is* the settings UI for this value, no separate settings screen entry).

**Multi-body Part mode** (the default - the smaller, fully-built mode):

- `ai_scoping_prompt.dart` gains `multiBodyPartVocabularyText`, appended by
  `buildAiScopingSystemPrompt`'s new `multiBodyPartMode` parameter
  (default `false`, so every pre-Phase-A caller is unaffected). Instructs
  the LLM to recognize distinct sub-parts in the request, confirm the
  count/breakdown with the user before proposing a plan (the same "ask
  before guessing" discipline the existing prompt already uses for missing
  dimensions), then build one plan whose steps produce one independent Body
  per recognized part - separate `sketch`->`extrude`(+further Feature)
  chains, never merged via `boolean`/`merge`/shared `target_body_ids`
  unless the user explicitly asks for that. Positioning reuses whatever the
  plan schema already exposes (`create_plane`, `move_body`, sketch-plane
  placement) - **no new PlanStep kind**.
- **No backend change, no translator change, no storage change.** The
  resulting Part is ordinary - ordinary manual Save/Save As afterward. This
  phase's whole job is proving multi-part *recognition* prompting works
  before Phase D risks any save/orchestration machinery on top of it.

**Assembly mode** (the toggle's other branch) is a **stub** this phase -
selecting it shows an inline amber banner ("Assembly mode is not built yet
... see Phases D/D2/E") and disables Send, both via the Send button's own
`onPressed` gating *and* a guard inside `_send()` itself (the text field's
`onSubmitted` reaches `_send()` directly on Enter, bypassing the button
entirely - a real bypass path found and closed during implementation, not
assumed safe).

**Files**: `client/lib/ai/ai_generation_mode.dart` (new),
`client/lib/ai/ai_modelling_screen.dart` (toggle UI/state, `_setMode`,
Send-button/`_send()` gating), `client/lib/ai/ai_scoping_prompt.dart`
(`multiBodyPartVocabularyText`, `buildAiScopingSystemPrompt`'s new param),
`client/lib/connection_screen.dart` (startup load wiring).

**Tests**: `test/ai_generation_mode_test.dart` (preference round-trip, incl.
a stored-but-unknown value falling back to the default rather than
crashing), `test/ai_scoping_prompt_test.dart`'s new `multiBodyPartMode`
group, `test/ai_modelling_screen_mode_toggle_test.dart` (new file,
deliberately kept separate from the much larger
`ai_modelling_screen_test.dart` - see this doc's own Appendix, item A-1).

---

## Phase B — Multi-image upload per turn (implemented)

Verified before implementing, not assumed: every layer was hard-wired to
exactly one image - `AiChatMessage.imageBytes`/`imageMimeType`
(`client/lib/ai/ai_provider.dart`) were scalars, `sendScopingTurn`/
`extractImageDescription` took one image, both `OpenAiCompatibleProvider`/
`AnthropicProvider` built a fixed 2-element content array, and
`AiModellingScreen._attachImage()` used `FilePicker...pickFiles` with no
`allowMultiple` and asserted `result.files.single`. The underlying wire
protocols (OpenAI's `content` array, Anthropic's content-block list) already
supported N image blocks per message - this was a code-level gap only, not
a protocol one.

- `AiChatMessage.imageBytes`/`imageMimeType` replaced outright by `images:
  List<AiImageAttachment>` (new class, `bytes`+`mimeType`, default `const
  []`) - a widening, not an additive second field, so every call site had
  to actually update rather than silently keep working against a
  now-unused old field.
- `AiProvider.extractImageDescription` widened from `(Uint8List
  imageBytes, String mimeType)` to `(List<AiImageAttachment> images)`.
- Both providers' `_contentFor`/extraction builders now emit one content
  block per image via a `for` loop instead of a fixed pair; both throw a
  clear `AiProviderException` if called with an empty image list.
- The two providers' extraction prompts were **byte-for-byte duplicated**
  before this phase (their own doc comments already said so) - factored
  into one shared `aiImageExtractionPrompt` constant in `ai_provider.dart`
  rather than kept as two copies now both needing the same multi-
  image/multi-part rewrite. The rewritten prompt explicitly asks the model
  to first decide whether it's looking at multiple views of one part,
  several distinct parts, or a whole assembly, rather than assuming a
  single part's multiple views the way the pre-Phase-B wording did.
- `_attachImage()` gains `allowMultiple: true`; pending-image state becomes
  `List<_PendingImage>` (new private class); one file failing to process
  never aborts the others (each processed independently, folded into
  `_imageError` without discarding whichever already succeeded - matches
  this codebase's existing "one failure doesn't abort the rest" convention,
  e.g. `AssemblyDocumentClient.saveAll`). The single fixed preview row
  became a horizontal thumbnail strip (`ListView.separated`), each
  thumbnail individually removable. `_ChatBubble` renders the same strip
  for a sent message's own images (was a single fixed `Image.memory`).
- The single extraction call per send now sends **every** pending image in
  one call (not one call per image) - the images likely relate to each
  other (several parts of one assembly), so a single call reasoning across
  all of them at once is both cheaper and more accurate than N independent
  calls.
- No new `AiProviderCapabilities` flag was added - both curated providers
  (OpenAI-compatible, Anthropic) support multi-image structurally; flagged
  here as a place a future, more limited provider might need gating.

**Files**: `client/lib/ai/ai_provider.dart` (`AiImageAttachment`, widened
interface, shared `aiImageExtractionPrompt`),
`client/lib/ai/openai_compatible_provider.dart`,
`client/lib/ai/anthropic_provider.dart`,
`client/lib/ai/ai_modelling_screen.dart` (`_PendingImage`, `_attachImage`,
`_send`, `_buildPendingImagePreview`, `_ChatBubble`).

**Tests**: `test/openai_compatible_provider_test.dart`/
`test/anthropic_provider_test.dart` gained multi-image cases for both
`sendScopingTurn`/`extractImageDescription` (image ordering per provider's
own convention preserved - OpenAI: text then images; Anthropic: images
then text); every pre-existing single-image case updated to the new
`images: [AiImageAttachment(...)]` shape (the old `imageBytes:`/
`imageMimeType:` named params no longer exist - this was a breaking
signature change, not an additive one, so every existing caller needed a
real edit, not just new tests). `test/ai_modelling_screen_test.dart`'s
`FakeAiProvider.imageExtractionHandler` widened to match.

---

## Phase C — Mandatory project folder + naming convention (implemented)

- `ToolChooserScreen`'s "AI Modelling" tile (previously `const
  AiModellingScreen()` - zero storage/root params, confirmed directly
  against the code before this phase) and `PartScreen`'s "Continue with AI"
  action (already passed `storageService`, but `projectRoot` could still be
  `null` until `_ensureProjectRoot()` had run) both now resolve a project
  root **before navigating** - `ToolChooserScreen` via a new shared
  `ensureProjectRoot()` function (`client/lib/storage/
  ensure_project_root.dart`, the same "already have one, else last-used,
  else prompt" order `PartScreen._ensureProjectRoot` established first,
  factored out for a caller with no `State` of its own); `PartScreen`
  itself continues using its own unchanged `_ensureProjectRoot()`, just
  called earlier (before pushing `AiModellingScreen`, not after). A
  cancelled picker is a silent no-op - no navigation happens at all, the
  same convention `_ensureProjectRoot` already established.
  `ToolChooserScreen` gained an optional `storageServiceFactory`
  constructor param (test-injectable, same "inject the real dependency,
  substitute a fake for tests" convention this codebase already uses for
  `documentApi`/`storageService` elsewhere).
- New pure naming helper, `client/lib/ai/ai_part_naming.dart`,
  `nextAvailablePartName(existingRelativePaths, {typePrefix, padWidth =
  3})` - scans for `<PREFIX>_<digits>` collisions (case-insensitive on the
  prefix) via whatever `StorageService.listFiles` already returned, and
  returns the lowest unused sequence number as a zero-padded name (e.g.
  `PLATE_004`). Sanitizes a loosely-formatted LLM-proposed prefix (spaces/
  punctuation) into a clean `UPPER_SNAKE_CASE` one. No prior art for this
  existed anywhere in this codebase before this phase (confirmed by a
  broad grep during design) - genuinely new, small, pure logic. Returns a
  candidate name only, never writes anything - per the Locked "save gate"
  decision, a human still confirms/edits it before any real
  `StorageService.writeFile` call (that confirm-dialog wiring is Phase D's
  own scope, once there's an actual save flow to attach it to).

**Files**: `client/lib/storage/ensure_project_root.dart` (new),
`client/lib/ai/ai_part_naming.dart` (new),
`client/lib/tool_chooser_screen.dart`,
`client/lib/viewport3d/part_screen.dart` (the "Continue with AI"
`IconButton.onPressed` closure only - `_ensureProjectRoot()` itself
untouched).

**Tests**: `test/ai_part_naming_test.dart` (collision-avoidance, gap
handling, case-insensitivity, prefix sanitization, subdirectory/
non-sequenced-name filtering, configurable pad width, double-digit
sequences), `test/ensure_project_root_test.dart` (the three-way
fallback order, and the cancelled-picker-returns-null case),
`test/tool_chooser_screen_test.dart`'s new "AI Modelling tile
project-folder gate" group (reuses a known last-used root without
prompting; falls back to the picker when none is known; never navigates
when the picker is cancelled).

---

## Phase D — Multi-part orchestration (planned, not built)

Needs a real design spike before the full build, the same way
`docs/assembly-scope.md`'s Phase 20 budgeted real design time for its own
per-Part-scoped-state question - the "N sequential cycles" approach is
Locked above, but the concrete state-machine shape inside
`AiModellingScreen` (today built around one `_activePartId`/one
transcript/one Review-&-Generate panel) needs real design time, not a
mechanical extension.

Planned shape: once the scoping conversation and the user's confirmation
(Phase A/B's "I see N parts - proceed?", already built into
`multiBodyPartVocabularyText`'s discipline and extendable to Assembly
mode's own vocabulary) settle on a part list, run the *existing*
single-Part flow once per part - `createPart(proposedName)` -> dry-run
validate -> execute -> propose a filename via Phase C's
`nextAvailablePartName` -> save-confirm dialog (reusing
`docs/assembly-scope.md` §2r's `relative_path_dialog.dart` shape) ->
`StorageService.writeFile`. A step failure mid-cycle uses the existing
no-auto-rollback posture within that one part's cycle; a whole-cycle
failure stops the orchestration before advancing, never silently
proceeding to the assembly step with a part missing.

---

## Phase D2 — Document-scoped mate edge/face resolution (planned, not built)

Backend-only, independent of Phase D's client orchestration. See the
Locked decision above for the exact confirmed gap
(`ai_plan.py`'s `occurrence_id == ''`-only `edge_selector` resolution).
Sized on the order of `docs/assembly-scope.md` §2p (Phase 13's mate-solver
work) - widen `_PlanValidator` (or add a sibling used only for
assembly-mode plans) to accept the composed multi-file `Document` the
client already builds via `AssemblyGraphComposer.compose`
(`docs/assembly-scope.md` §2c), so a Mate step's `edge_selector` with a
non-empty `occurrence_id` can resolve `Occurrence.resolved_part_id` -> the
real target `Part` -> `compute_part_bodies` -> the selector, the same
deterministic resolution already used for the root Part today. Needs a
real spike on the wire-payload shape (whole composed graph per dry-run
call vs. just the specific target Parts a plan's `mate` steps reference) -
explicitly flagged as unresolved, not assumed.

---

## Phase E — Assembly creation, insert, mate, open (planned, not built)

Depends on D **and** D2. After Phase D's per-part cycles finish, run one
more plan/execute cycle targeting a new-or-reused assembly Part, authored
by the LLM against a system prompt listing exactly the parts Phase D just
saved (their real `relative_path`s) via `add_component` steps (unchanged,
`docs/assembly-scope.md` §2t) followed by `mate` steps - `add_component`
itself is already fully wired end to end; a `mate` step naming an
`edge_selector` on either just-placed component only works once Phase D2
ships. On completion, navigate into `PartScreen` for the assembly Part
with `AssemblyLens.assembly` active.

### Not built this round (disclosed, not silently dropped)

- File-level undo (Locked decision - explicitly deferred).
- `gear_request` full hand-off inside a multi-part/assembly plan - already
  a pre-existing, separately-tracked gap
  (`04-translator-and-execution.md`); this workstream doesn't attempt to
  close it.
- A richer interactive folder/file browser for the save-confirm dialog -
  reuses the existing typed-prompt-plus-collision-warning shape
  (`docs/assembly-scope.md` §2r), not a new browser widget.

---

## Appendix: gaps & emergent work tracker

Started alongside this workstream's own implementation, mirroring
`docs/assembly-scope.md` §5's own "pulled out specifically so it gets a
real look later, not buried in a 'Verified' paragraph" convention. Update
this section, don't silently let it go stale, as further phases land.

### Open gaps (real, disclosed, not yet closed)

- **A-1: `ai_modelling_screen_mode_toggle_test.dart` was deliberately kept
  as a separate file from `ai_modelling_screen_test.dart`.**
  `AiGenerationModePreferences`'s default is process-wide static state
  (mirrors `AiSystemPromptPreferences`'s own shape) - a test that switches
  the toggle mutates that static field for the rest of whatever file it
  runs in, since Dart's test runner doesn't reset static state between
  tests within one file/isolate. Rather than risk polluting the much
  larger, already-extensive `ai_modelling_screen_test.dart` (audited but
  not proven immune to this by every one of its ~40 tests), the new
  toggle-specific tests live in their own file with their own `tearDown`
  resetting the default. Worth revisiting if `AiGenerationModePreferences`
  ever needs broader test coverage inside the main file.
- **C-1: no widget-level test exercises `PartScreen`'s "Continue with AI"
  mandatory-folder-gate change directly.** `part_screen_test.dart` had no
  pre-existing coverage of this call site at all (confirmed before this
  phase), and its `_FakeDocumentBackend`/`_storageService` injection
  harness is large enough that adding real coverage here was judged
  disproportionate to what it would additionally catch, given
  `_ensureProjectRoot()` itself (the actual logic doing the work) is
  unchanged and already covered indirectly by Phase 15/16's own tests in
  that file (Save All/Open Project's use of the same method). The change
  itself (call `_ensureProjectRoot()` before navigating, abort if it
  returns `null`) is small and mechanically mirrors an already-tested
  pattern, but is not independently regression-tested at the "Continue
  with AI" call site specifically.
- **A-2: the naming convention's `padWidth` (default 3) and the
  `UPPER_SNAKE_CASE` sanitization rule are fixed, not user-configurable.**
  No settings-screen control exists for either. Revisit if real usage
  shows 3 digits or the sanitization rule doesn't fit a real project's own
  naming convention.
- **Assembly mode's "coming soon" banner has no test asserting its exact
  wording stays in sync with whichever phase actually closes it** - a
  cosmetic risk (the banner could go stale once Phase D/E ship, still
  claiming to be unbuilt), not a functional one, since `_mode ==
  AiGenerationMode.assembly` gating Send is independently tested and isn't
  itself hardcoded to the banner text.

### Emergent work (found during implementation, not in the original plan)

- **Provider extraction prompt de-duplication.** The two providers'
  `_imageExtractionPrompt` constants were already byte-for-byte identical
  before this workstream (each provider's own doc comment already said
  so) - rather than keep two copies and update both identically for
  Phase B's multi-image/multi-part rewrite, they were factored into one
  shared `aiImageExtractionPrompt` constant in `ai_provider.dart`. Not
  originally scoped, but the lower-risk choice once duplicating the
  rewrite was the visible alternative.
- **The `onSubmitted` Send-gating bypass.** Phase A's plan only mentioned
  disabling the Send button while Assembly mode is selected; implementing
  it surfaced that the chat `TextField`'s `onSubmitted` callback calls
  `_send()` directly, bypassing the Send button's own `onPressed` gating
  entirely (pressing Enter would have still sent a message in Assembly
  mode). Fixed by adding the same guard inside `_send()` itself, not just
  the button.
- **`ToolChooserScreen` needed a new test-injection seam
  (`storageServiceFactory`) that didn't exist before this phase** - it was
  a `StatelessWidget` with a hardcoded tile and no override points at all.
  Added following this codebase's existing "inject the real dependency,
  substitute a fake for tests" convention rather than leaving Phase C's
  new mandatory-folder-gate behavior untested.
- **The multi-image thumbnail-removal UI** needed a per-image `Key`
  (`aiModellingRemoveImage_$index`) rather than reusing the old single
  fixed key (`aiModellingRemoveImage`) - not called out in the original
  plan's UI sketch, found while implementing the thumbnail strip.
