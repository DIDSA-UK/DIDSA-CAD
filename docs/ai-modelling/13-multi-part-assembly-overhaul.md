# Workstream 13: Multi-Part & Assembly Overhaul

Read `00-conventions.md` first. Depends on 1, 2, 3, 5 (the core pipeline)
and cross-references `docs/assembly-scope.md` throughout (Phase 15's
multi-file save flow, Phase 18's `add_component`/`StorageService.listFiles`,
Phase 14's mate edge-selector heuristic) - the two doc sets describe the
same underlying assembly data model/pipeline from two different angles
(this one from the AI-authoring side, that one from the manual-UI side) and
should be read together for this workstream specifically.

**Status**: Phases A, B, C, D, D2, E **implemented** - this workstream is
complete. Phase D's own scope was narrowed during implementation to end at
"every recognized part generated and saved as its own file" - it
deliberately did **not** attempt the assembly-insert/mate step itself, that
was left to Phase E. D2 closed the real, confirmed gap in the existing mate
edge-selector resolution (a Mate's `edge_selector` couldn't resolve against
a placed Occurrence's own target Part at all before this phase) with **zero
new wire payload** - the fix turned out to be pure backend wiring, not the
Document-scoped-payload redesign the plan's own original framing expected
(see Phase D2's own section for what the spike actually found). Phase E
then closed the loop: once every part from Phase D is saved, one further
plan/execute/save cycle builds the assembly itself (`add_component` +
`mate` steps against the parts D just saved) and opens it directly into
Assembly lens - see its own section below for exactly how.

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
A: Mode toggle + multi-body-part mode  ──┐   [implemented]
B: Multi-image upload per turn           ├──> D: Multi-part orchestration --> E: Assembly creation + mate + open
C: Mandatory project folder + naming     ──┘   [implemented]                  ^         [planned]
D2: Document-scoped mate edge/face resolution (backend, independent) --------/  [implemented]
```

A, B, C, D, and D2 are all **implemented** (D's real scope ends at "every
part saved" - see its own section below for why). D2 turned out to be pure
backend wiring (no new wire payload, no client changes - see its own
section for the spike's real finding) and shipped independently of D's
client orchestration, exactly as planned. E is a strict follow-on to D
**and** D2, both now done - it is the only piece of this workstream still
not built.

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

## Phase D — Multi-part orchestration (implemented, scope ends before assembly creation)

**Scope note, decided during implementation**: the original entry below
(kept for the historical record where it differs) sketched generation
*and* an implied path into assembly creation. Building it surfaced that
authoring real `mate` steps against freshly-placed components needs Phase
D2's Document-scoped mate resolution first (this doc's own dependency
graph already said so) - so this phase's real scope ends at "every
recognized part has been generated and saved as its own file," and stops
there with a clear, honest message rather than attempting a `mate`-bearing
assembly plan that would very likely fail dry-run validation today. This
is a scope *narrowing* found while building, not a silent cut - matches
this doc set's own "verify against the code, not assumed" convention.

### The `part_manifest` mechanism (the design question this phase needed answered)

Assembly mode's scoping conversation doesn't jump straight from prose to
N plans. The LLM first emits a small, distinct structured shape - a
`part_manifest` (new `client/lib/ai/ai_part_manifest.dart`,
`AiPartManifest`/`AiPartManifestEntry`: `name`/`type_prefix`/`summary` per
part) - detected by a new `detectPartManifestInAssistantText`
(`ai_plan_detection.dart`, reusing `detectPlanInAssistantText`'s own
candidate-scanning helpers). The two detectors can never collide: a real
plan has no top-level `kind` field, a manifest has no `steps` field.

Once a manifest is detected, `AiModellingScreen` shows a confirm panel
(`_buildManifestConfirm`) with one editable name/type-prefix row per part
(`_manifestNameControllers`/`_manifestPrefixControllers`) - the LLM's own
breakdown is a starting point, not a final answer, the same "human
confirms/edits before anything real happens" posture the save-gate itself
uses one step later. "Confirm & Generate All"
(`_confirmManifestAndGenerateAll`) folds any edits back in and starts the
orchestration at part 0.

### The orchestration loop (`_runPartCycle`)

Exactly the Locked "N sequential single-Part cycles" architecture, with
**zero** changes to `_PlanValidator`/`PlanTranslator`/the plan schema:

1. Append a synthetic, visible `user`-role turn asking for exactly one
   part's plan ("Please provide the plan for part 2 of 3: ... Reply with
   an ordinary plan for this part only...") - real information exchanged
   with the LLM, shown in the transcript like any other turn, not hidden
   bookkeeping.
2. `detectPlanInAssistantText` on the reply (completely unchanged) - if no
   plan is found, the whole orchestration stops with a clear error (no
   silent retry loop).
3. `DocumentApiClient.createPart(entry.name)` - a real, brand-new Part,
   exactly as the single-Part flow's own `_generate()` already does.
4. `PlanTranslator.execute` (unchanged) - the existing dry-run-then-
   real-execution pair, with progress reflected via a coarse
   `_orchestrationStatus` string rather than a full per-step list (see
   this doc's own Appendix for why the fuller `_stepStatuses` UI wasn't
   duplicated here).
5. `nextAvailablePartName` (Phase C) proposes a filename from whatever
   `StorageService.listFiles` currently reports, filtered to
   `kNativeFileExtension`.
6. `showRelativePathPromptDialog` (Phase 15's own dialog,
   `client/lib/viewport3d/relative_path_dialog.dart`, reused byte-for-byte)
   - the human save-confirm the Locked decision requires. Cancelling stops
   the whole orchestration cleanly (already-saved parts untouched; this
   part's Features exist only in the backend's in-memory session, never
   written to disk, so there is nothing on disk to clean up).
7. `AssemblyDocumentClient.savePart(root, partId, path)` (Phase 15's own
   client, reused as-is) writes the file for real, then recurses into the
   next part.

Any failure at any point (a step failure, a validation failure, a
`gear_request` step, a provider error, a storage error, a cancelled save)
stops the whole run rather than silently skipping ahead - `_orchestrating`
stays `true` so the progress panel keeps showing exactly where and why it
stopped (`_stopOrchestrationWithError`); `_dismissOrchestration` is the
only way back to chat from there (**no retry-this-part action was built
this pass** - see this doc's own Appendix).

Once every part succeeds, the progress panel
(`_buildOrchestrationProgress`) shows an "All parts saved" summary naming
each part's own real `relativePath`, plus an explicit note that assembly
creation isn't built yet and how to do it manually today (Insert Existing
Component / Add Mate in the Assembly lens) - never a silent stop with no
explanation.

**Files**: `client/lib/ai/ai_part_manifest.dart` (new),
`client/lib/ai/ai_plan_detection.dart` (`detectPartManifestInAssistantText`),
`client/lib/ai/ai_scoping_prompt.dart` (`assemblyModeVocabularyText`, the
new `assemblyMode` param), `client/lib/ai/ai_modelling_screen.dart` (the
bulk of the new state machine: manifest state, `_runPartCycle`,
`_confirmManifestAndGenerateAll`, `_stopOrchestrationWithError`,
`_dismissOrchestration`, the two new panel builders, `_buildSystemPrompt`
factored out as a shared helper so `_send`/`_shareExternalHandoff`/
`_runPartCycle` can never drift on how the system prompt gets built).

**Tests**: `test/ai_plan_detection_test.dart`'s new
`detectPartManifestInAssistantText` group (fenced-in-prose detection, the
two detectors never colliding on the same text, empty-parts rejection);
`test/ai_scoping_prompt_test.dart`'s new `assemblyMode` group;
`test/ai_modelling_screen_orchestration_test.dart` (new file, mirroring
`ai_modelling_screen_mode_toggle_test.dart`'s own "keep it separate"
reasoning): manifest-detected-shows-confirm-panel,
cancel-returns-to-chat, a full 2-part happy-path run (through both real
save-confirm dialogs, asserting the exact files written), and a
validation-failure-stops-the-run case.

---

## Phase D2 — Document-scoped mate edge/face resolution (implemented)

Backend-only, no client changes needed at all - confirmed directly, not
assumed (see "The spike's real answer" below).

### The spike's real answer: no new wire payload needed

The plan's own original framing flagged a real open question - "does the
validator need the *whole* composed graph on every dry-run call... or can
it accept just the specific target Parts". Tracing the actual code before
writing anything answered it differently from either option:
`app.document.store.get_document()` is a **per-session singleton**
(`_documents: OrderedDict[str, Document]`, keyed by session id, confirmed
in `store.py`), not a fresh per-request fetch. Once a composed multi-file
assembly graph is imported (`POST /document/import/native`), *every* Part
it contains already lives in that same session's `Document.parts` for as
long as the session stays open - `Occurrence.part_id` already resolves
into it directly, the exact same session-local cross-reference
`native_format.py`'s own `_resolve_occurrence_part_ids` already trusts
elsewhere (confirmed in `docs/assembly-scope.md` §2c/§2s). So the fix is
purely: thread the current session's `Document` through
`_PlanValidator`/`validate_ai_plan`/the router endpoint - **zero** new
request/response fields, zero client-side changes, zero new
`DocumentApiClient` methods.

### The fix

- `_PlanValidator.__init__` gains an optional `document: Document | None =
  None` param (`self.document`) - `None` by default, so every pre-existing
  direct caller (including this module's own tests that build a
  `_PlanValidator` without one) keeps the original, pre-Phase-D2 behavior
  exactly.
- New `_PlanValidator._resolve_occurrence_target_part(occurrence, field)` -
  resolves `occurrence.part_id` into `self.document.parts`, failing closed
  (a clear `invalid_step_payload`) when `self.document` is `None`,
  `occurrence.part_id` is `None` (an unresolved Occurrence, or a plan-local
  `add_component` step's own scratch Occurrence - correctly still
  unresolvable, not a gap this phase introduces), or that id simply isn't
  present in the session's `Document.parts`.
- `_resolve_mate_edge_selector` widened from an implicit `v.part` to an
  explicit `target_part: Part` parameter - `compute_part_bodies(target_part,
  ...)` now runs against whichever Part actually owns the geometry, root or
  placed component alike; the selector heuristics themselves
  (`app.document.ai_plan_edges.resolve_edge_selector`) needed no change at
  all, confirmed directly (they never cared which Part their Body came
  from).
- `_mate_entity_ref_from_step`'s old unconditional rejection
  (`edge_selector is only supported for occurrence_id == ''`) is gone -
  replaced with `target_part = v.part if occurrence is None else
  v._resolve_occurrence_target_part(occurrence, field)`, then the same
  `_resolve_mate_edge_selector` call as before, just against the right
  target.
- `validate_ai_plan(part, steps, disabled_kinds, document=None)` and the
  `POST /parts/{part_id}/ai-plan/validate` router endpoint both gained the
  same optional `document` pass-through, the endpoint always supplying
  `get_document()` (the real fix's only "wiring" step - everything else
  above is the actual resolution logic).

### What's still correctly unresolvable, and why that's not a gap

An Occurrence with no real target Part loaded into the current session
(`part_id is None` - either never resolved at import, or a plan-local
`add_component` step's own scratch Occurrence, which has no real
geometry by design) still correctly fails with a clear error - there is
genuinely no Body to resolve a selector against, not a scope limit this
phase chose to leave in place. Verified directly by a real test
(`test_mate_edge_selector_rejects_an_unresolved_occurrence_reference`).

**Files**: `backend/app/document/ai_plan.py` (`_PlanValidator.__init__`,
`_resolve_occurrence_target_part`, `_resolve_mate_edge_selector`,
`_mate_entity_ref_from_step`, `validate_ai_plan`),
`backend/app/document/router.py` (`validate_ai_plan`'s own endpoint,
`GET .../ai-plan/validate` — threads `get_document()` through). Also
`client/lib/ai/ai_scoping_prompt.dart`'s locked "Assembly editing"
vocabulary (`assemblyVocabularyText`) - its mate `edge_selector` guidance
flatly claimed "only ever usable on the '' (root-content) side... never on
a placed component's own occurrence_id side," which this phase makes
false; corrected to say `edge_selector` now also works on an
`existing:<id>` occurrence (an already-real, already-resolved one) but
still not on a bare plan-local `add_component` reference within the same
plan (that component has no real geometry yet at dry-run time - see
"What's still correctly unresolvable" above). This is a live, user-facing
fix, not prep for Phase E: the "Assembly editing" vocabulary already
drives real "Continue with AI" conversations against an already-open
multi-file assembly today, independent of this workstream's own new
Multi-body-Part/Assembly generation modes.

**Tests**: `backend/tests/test_ai_plan_assembly_steps.py` - a real,
end-to-end positive case
(`test_mate_edge_selector_resolves_against_a_placed_occurrences_own_real_body`,
new fixture `_setup_top_with_occurrence_target_having_its_own_body` gives
the *placed Occurrence's own target Part* a real box Body, distinguishable
by dimension from the root Part's own, and confirms via a real `Measure`
call that the resolved edge belongs to the right Part) plus the two
still-correctly-rejected cases (no `document` passed at all; an
unresolved Occurrence) - the previous test asserting outright rejection
for *any* non-root occurrence was found, while implementing this phase,
to already be passing for the wrong reason (its own fixture's placed
Occurrences target genuinely empty Parts with no Body at all, so the old
assertion happened to still hold post-fix, just via a "body not found"
error instead of the original scope-limit rejection it claimed to test) -
rewritten rather than left silently stale (net +2 tests in this file: one
removed/rewritten, three added). Full targeted run: 44/44 passed in
`test_ai_plan_assembly_steps.py`; full backend suite (`backend/tests/`,
real `pythonocc-core`/`py-slvs`, `pytest -n auto`) reconfirmed clean at
**2399 passed, 0 failed** (15:48 wall-clock). Full client suite
reconfirmed clean too - **2214/2214 passed** (14 GPU-skips, unchanged),
`flutter analyze` clean - covering the corrected prompt text's own new
test (`test/ai_scoping_prompt_test.dart`) alongside the untouched rest of
the client, confirming this phase genuinely needed no other client
change.

---

## Phase E — Assembly creation, insert, mate, open (implemented)

Depends on D **and** D2, both already shipped by the time this phase was
built. Closes the loop Phase D deliberately left open: once every
recognized part is generated and saved to its own file, one further
plan/execute/save cycle builds the assembly itself and opens it - no manual
"now go do Insert Existing Component by hand" step required.

### The assembly cycle (`_runAssemblyCycle`)

Triggered automatically the moment the last part-cycle succeeds
(`_finishPartOrchestration` now calls `unawaited(_runAssemblyCycle())`
instead of just stopping) - never a separate button press, since there is
nothing left for the user to decide before it: every part is already real
and saved. Mirrors `_runPartCycle`'s own shape one level up (one assembly
instead of one part), reusing the exact same primitives with zero changes
to `_PlanValidator`/`PlanTranslator`/the plan schema:

1. Append a synthetic, visible `user`-role turn listing every saved part's
   own real name and `relative_path` and asking for the assembly plan now
   - passed both in this request turn's own text and as this one turn's
   override of the "Available Component Files" system-prompt section
   (rather than the ordinary `_availableComponentFilesSummary`, which is
   only ever refreshed once in `initState` and so could be stale by the
   time an orchestration run actually finishes saving new files - see this
   doc's own D-4 gap on why the request text and the prompt section can
   drift, now closed for this one turn by construction rather than by
   relying on a fresh disk scan).
2. `detectPlanInAssistantText` on the reply (unchanged) - no plan found
   stops the run with a clear error, parts already saved untouched.
3. `DocumentApiClient.createPart('Assembly')` - always a brand-new Part;
   letting the user pick an existing file to add parts into instead was a
   real product question the original plan flagged but this pass doesn't
   attempt (see "Not built this round" below).
4. `PlanTranslator.execute` (unchanged) - the LLM's `add_component` steps
   (`docs/assembly-scope.md` §2t, already fully wired since Phase 18) place
   each saved part; `mate` steps with an `edge_selector` on a just-placed
   component's own `existing:<occurrence_id>` now resolve for real, thanks
   to Phase D2.
5. `nextAvailablePartName(..., typePrefix: 'ASSEMBLY')` (Phase C, reused
   as-is) proposes a collision-free name.
6. `showRelativePathPromptDialog` (Phase 15's dialog, reused byte-for-byte)
   - the same human save-confirm gate every part cycle already used.
   Cancelling stops the run; every part above stays saved.
7. `AssemblyDocumentClient.savePart(root, assemblyPartId, path)` writes the
   assembly file for real.

Any failure at any point uses the identical `_stopOrchestrationWithError`
posture `_runPartCycle` already established - no auto-rollback, whatever
was already saved (every part, and the assembly itself once its own save
succeeds) stays saved.

### Opening the result (`_openAssembly`, `PartScreen.initialLens`)

`PartScreen` gained a new `initialLens` constructor param (default
`AssemblyLens.part`, so every pre-Phase-E caller is unaffected) - when set
to `AssemblyLens.assembly`, `_loadPart` runs the same tree-then-mesh
refresh sequence `_toggleAssemblyLens` already used for a manual switch,
just once, inside the load it's already awaiting, since there's no
"switch lens mid-session" race to worry about this early. Once the
assembly cycle above finishes, the progress panel shows an "Open Assembly"
button; `_openAssembly` pushes a fresh `PartScreen` (mirrors
`_onOpenProjectPressed`'s own "fresh screen, not a reload in place"
precedent) for the assembly Part with `initialLens: AssemblyLens.assembly`
and `initialRelativePathByPartId` carrying every part's own real path
through (the assembly's own included) - so a subsequent "Save All" on the
new screen already knows where each file lives, rather than prompting
again for files this same run just wrote.

**Files**: `client/lib/ai/ai_modelling_screen.dart` (`_runAssemblyCycle`,
`_openAssembly`, the `_buildingAssembly`/`_assemblyPartId`/
`_assemblyRelativePath` state, `_buildOrchestrationProgress`'s new
"Assembly" row and "Open Assembly" button), `client/lib/viewport3d/
part_screen.dart` (`initialLens`, wired into `_loadPart`).

**Tests**: `test/ai_modelling_screen_orchestration_test.dart`'s "confirming
generates and saves every part, then Phase E builds, saves and opens the
assembly" test extends the existing 2-part happy path through a real
assembly create/execute/save cycle (a widened `_fullOrchestrationHandler`
mock backend, part-id-aware `/document/export/native` so each saved part's
own file bytes carry that part's own real id - needed since `add_component`
reads a saved file's bytes straight back via `StorageService`, never HTTP)
and asserts the pushed `PartScreen`'s own constructor params
(`initialPartId`, `initialLens`, `initialRelativePathByPartId`).
`test/part_screen_test.dart` gained its own direct, smaller test for
`initialLens: AssemblyLens.assembly` opening straight into Assembly lens
with no manual toggle tap needed.

### Not built this round (disclosed, not silently dropped)

- File-level undo (Locked decision - explicitly deferred).
- `gear_request` full hand-off inside a multi-part/assembly plan - already
  a pre-existing, separately-tracked gap
  (`04-translator-and-execution.md`); this workstream doesn't attempt to
  close it.
- A richer interactive folder/file browser for the save-confirm dialog -
  reuses the existing typed-prompt-plus-collision-warning shape
  (`docs/assembly-scope.md` §2r), not a new browser widget.
- **Picking an existing file to add parts into, instead of always creating
  a new assembly Part.** The original plan flagged this as "a real product
  question worth a quick confirm at the point this phase is detailed" -
  `_runAssemblyCycle` always creates a fresh Part; see this section's own
  Appendix entry (E-1) below.

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
- ~~**Assembly mode's disclosure banner has no test asserting its exact
  wording stays in sync with whichever phase actually closes the
  insert/mate gap** - a cosmetic risk (the banner could go stale once
  Phase D2/E ship, still claiming assembly creation isn't built), not a
  functional one.~~ - **Closed, gap-closure pass below.** The risk this
  entry flagged actually materialized (the banner still claimed
  insert/mate "is not built yet" after Phase E shipped in this same
  branch) - fixed, and now covered by a direct assertion
  (`ai_modelling_screen_mode_toggle_test.dart`) that the stale wording
  can't silently reappear.
- ~~**D-1: no "retry this part" action.**~~ - **Closed, gap-closure pass
  below.** Rebuilt as "ask the LLM for a revised plan against the same
  Part" (reusing the single-Part flow's own `_pendingRetryPartId`/
  `_appendStoppedRunToTranscript` precedent), not a blind re-run of the
  identical failed steps - see that section for why, and for the
  correctness gap this also closed (a stopped orchestration's "continue
  chatting manually" advice didn't actually work: the in-progress Part id
  was never captured anywhere `_generate()` could reuse).
- ~~**D-2: the per-part progress UI is coarse (one status string), not a
  full per-step list.**~~ - **Closed, gap-closure pass below.**
  `PlanTranslator.execute`'s `onStepStatusChanged` callback is now wired
  through `_runPartCycle`/`_runAssemblyCycle` the same way the single-Part
  flow's own `_stepStatuses` already used it - closed alongside D-1/E-2
  since both touch the same call sites.
- ~~**D-3: no test exercises the assembly-mode `gear_request`-stop or
  provider-error paths inside `_runPartCycle`.**~~ - **Partially closed,
  gap-closure pass below.** New orchestration tests cover a
  `validationFailed`-then-retry-succeeds round trip and a cancelled-save
  retry; a dedicated `gear_request`/`AiProviderException` orchestration
  test was not added this pass (both still share the same
  `_stopOrchestrationWithError`/retry-state wiring the new tests do
  exercise, just not through their own dedicated case).
- ~~**D-4: the assembly-mode vocabulary's per-part request text is
  hand-written prose (`_runPartCycle`'s own `requestMessage`), not itself
  part of `ai_scoping_prompt.dart`.**~~ - **Closed, gap-closure pass
  below.** Moved to `ai_scoping_prompt.dart` as
  `assemblyModePartRequestText`/`assemblyModeAssemblyRequestText` (plus
  new retry variants), alongside `assemblyModeVocabularyText`.
- **D2-1: the "first match wins on ambiguity" limitation from Phase 14
  (`docs/assembly-scope.md` §6 `[3]`'s own writeup) is unchanged by this
  phase.** A selector matching more than one edge on a placed Occurrence's
  own body (e.g. `vertical_edges` on an ordinary box - four matches) still
  silently takes the first in `resolve_edge_selector`'s own stable
  ordering, exactly as it always did for the root Part. D2 only widened
  *which Part* can be searched, not the disambiguation behavior itself -
  worth revisiting together if real usage shows either one is a problem
  worth solving.
- **D2-2: only Mate's `edge_selector` was widened - `move_component`/
  `hide_component`/`isolate_component`/`pattern_component` never had any
  geometry-selector concept to widen** (they reference a whole Occurrence,
  never a specific edge/face on one), so this phase's own scope is
  correctly narrow to Mate alone, not a gap in coverage.
- ~~**E-1: no way to add parts into an existing assembly file -
  `_runAssemblyCycle` always creates a brand-new assembly Part.**~~ -
  **Closed, gap-closure pass below.** The manifest-confirm panel now offers
  "insert into an existing assembly" (a dropdown over the project's
  existing native files) alongside the default "create a new assembly";
  picking one routes `_runAssemblyCycle` through
  `AssemblyDocumentClient.openAssembly` (the exact mechanism the manual
  "Open Project…" UI already uses) instead of `createPart('Assembly')`,
  opened *before* the LLM is asked for a plan (not after) so its own
  `add_component`/`mate` steps can be told what's already placed in that
  assembly and not duplicate it, and the save-confirm dialog is pre-filled
  with the existing file's own path instead of a freshly proposed name.
- ~~**E-2: no "retry the assembly cycle" action, same shape as D-1.**~~ -
  **Closed, gap-closure pass below.** Same `_retryOrchestration`/
  `_assemblyRetryPartId` mechanism as D-1, one level up.
- ~~**E-3: the assembly cycle's own progress row shares
  `_orchestrationStatus` with the per-part rows above it, the same D-2
  coarseness, one level up.**~~ - **Closed, gap-closure pass below**,
  alongside D-2.

---

## Gap-closure pass (post-implementation review)

A separate review pass (not part of the original A-E build above) checked
this workstream's implementation against this doc's own claims and worked
through this Appendix's disclosed gaps. Two things turned up that weren't
in the Appendix at all:

- **The Assembly-mode disclosure banner had actually gone stale** (see the
  Appendix entry above, now closed) - `client/lib/ai/
  ai_modelling_screen.dart`'s banner still told users the insert/mate step
  "is not built yet... use Insert Existing Component/Add Mate afterward"
  even though Phase E (this same branch) made that automatic. Fixed to
  describe what actually happens, with a test locking the corrected
  wording in place.
- **`docs/assembly-scope.md` §2q's "Remaining limitations after this
  phase" section still said the cross-Part mate edge-selector scope limit
  (`[3]`) "is unchanged and still fully open"** - contradicted by this
  workstream's own Phase D2, which closed exactly that limit. Updated with
  a cross-reference.

D-1/D-2/D-4/E-2/E-3 above were closed together, since they all touch the
same `_runPartCycle`/`_runAssemblyCycle`/`_buildOrchestrationProgress` call
sites: a failed part or assembly cycle now offers "Retry", which asks the
LLM for a *revised* plan against the *same* in-progress Part (reusing the
single-Part flow's own `_pendingRetryPartId`/`_appendStoppedRunToTranscript`
precedent - not a blind re-run of the identical steps that just failed),
except for a cancelled save specifically, where "Retry" just re-opens the
save dialog directly (the Part/plan are already valid, no LLM round-trip
needed). This also closed a real correctness gap beyond D-1's own "no
convenient button" framing: before this fix, a stopped orchestration's own
"you can continue this conversation manually" advice didn't actually work -
the in-progress Part's real id was never captured anywhere `_generate()`
could find it, so a later Generate press would silently abandon it and
start a genuinely unrelated fresh Part instead. Per-step progress
(`onStepStatusChanged`) is now wired into the orchestration panel the same
way the single-Part flow's own `_stepStatuses` already used it (D-2/E-3).

D-3 is only partially closed - see its own updated entry above.

A-1, A-2, C-1, D2-1, D2-2 are unchanged from the original build - all
still genuinely deliberate scope cuts per their own entries above, not
revisited this pass.

E-1 was also closed this pass - see its own updated entry above for the
design. The manifest-confirm panel loads the project's existing native
files (`_loadExistingAssemblyFileOptions`, fired once a `part_manifest` is
detected, same best-effort-fetch pattern as `_refreshAvailableComponentFiles`)
and offers them in a dropdown; picking one sets `_assemblyTargetRelativePath`,
which `_runAssemblyCycle` checks *before* requesting a plan from the LLM -
opening the file via `AssemblyDocumentClient.openAssembly` (the same call
the manual "Open Project…" flow already uses) first, so the request text
sent to the LLM (`assemblyModeAssemblyIntoExistingRequestText`, new in
`ai_scoping_prompt.dart`) can list what's already placed in it. A cycle
error while opening (a missing/unreadable file, a genuine reference cycle)
uses the same `_stopOrchestrationWithError`/Retry posture as every other
orchestration failure. **Real limitation found while testing, not part of
the original E-1 scope note**: a widget-level test driving the actual
`openAssembly` call through this sandbox's `testWidgets` pump loop hits the
same real `dart:io`/`FileCache` (`path_provider` platform channel)
slowness/hang `part_screen_test.dart`'s own "Assembly support Phase 16"
group already found and documented for `openAssembly` specifically - so,
following that file's own precedent, this pass tests the new
manifest-confirm dropdown UI directly (no `openAssembly` call involved) and
the new request-text wording as a pure unit test, rather than forcing a
flaky full round-trip widget test; the `openAssembly` call itself is
already covered, composer-level, by `assembly_document_client_test.dart`.

**Files**: `client/lib/ai/ai_modelling_screen.dart` (retry state/methods,
per-step progress wiring, corrected banner, E-1's dropdown/open-existing
wiring), `client/lib/ai/ai_scoping_prompt.dart` (D-4's extracted request
text, E-1's existing-assembly request text),
`client/test/ai_modelling_screen_orchestration_test.dart` (retry tests,
E-1's dropdown tests), `client/test/ai_scoping_prompt_test.dart` (E-1's
request-text unit tests), `client/test/ai_modelling_screen_mode_toggle_test.dart`
(banner wording test), `docs/assembly-scope.md` (§2q update).

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
- **`_shareExternalHandoff` never threaded `multiBodyPartMode`/
  `assemblyMode` through at all until Phase D's own refactor.** Building
  `_runPartCycle` (which also needed the exact same system-prompt
  construction `_send()` already had) surfaced that the "share with
  external AI" hand-off had silently drifted from the in-app prompt the
  moment Phase A shipped - a real, if minor, pre-existing gap from Phase
  A, only found and fixed while factoring out `_buildSystemPrompt()` for
  Phase D's own needs.
- **Phase D's original plan text (this file's own earlier draft) implied
  generation could flow straight into assembly creation.** Confirmed
  false while implementing, not assumed - see the Phase D section's own
  "Scope note" above. The phase's real boundary (stop after every part is
  saved) was decided mid-implementation, not up front.
- **`AiPartManifestEntry`'s `type_prefix` needed its own edit field in the
  confirm panel, not just `name`.** The original UI sketch only mentioned
  reviewing/editing parts generically; implementing the naming-convention
  integration (Phase C's `nextAvailablePartName`) made clear the type
  prefix is exactly as user-facing as the name, since it directly becomes
  the saved file's own name.
- **A pre-existing test was passing for the wrong reason, found only while
  building D2.** `test_ai_plan_assembly_steps.py`'s own
  `test_mate_edge_selector_rejects_a_placed_occurrence_reference` (Phase
  14) asserted `edge_selector` on a non-root `occurrence_id` always fails
  - true before D2, but its own fixture's placed Occurrences (`bolt_a`/
  `bolt_b`) are genuinely empty Parts with no Body at all, so after D2's
  fix the *same* assertion kept passing for an entirely different reason
  (a "body not found" error on an empty target Part, not the original
  scope-limit rejection the test's own name and docstring claimed). Caught
  by actually reading what the fixture set up, not just re-running the
  suite and seeing green - rewritten into a real positive case (a new
  fixture giving the target Part its own real Body) plus a correctly-
  targeted negative case (a genuinely unresolved Occurrence), rather than
  left silently stale. A concrete reminder that "still passes" and "still
  tests what it claims to" are different questions.
- **The spike itself reversed the plan's own original framing.** The plan
  document's own pre-implementation text asked "does the validator need
  the whole composed graph on every dry-run call, or just the specific
  target Parts" - tracing `app.document.store.get_document()` before
  writing any fix code found the real answer was neither: the backend's
  existing per-session `Document` singleton already holds every Part a
  composed graph pulled in, so **no new wire payload was needed at all**.
  A case where reading the actual code changed the shape of the fix, not
  just its size.
- **The orchestration test's `_FakeStorageService.readFile` was never
  implemented before Phase E - it threw `UnimplementedError`, matching the
  file's own doc comment that only `listFiles`/`resolve`/`writeFile` were
  ever reached by anything Phase D exercised.** Phase E's `add_component`
  steps are the first thing in this fixture's history to actually read a
  saved file's bytes back (`AiAddComponentStep`'s own `storage.resolve` +
  `storage.readFile`, never HTTP - see `ai_plan_translator.dart`) - closed
  by implementing it as a lookup into the same in-memory `writtenFiles` map
  `writeFile` already populates.
- **The shared `_orchestrationHandler`/`_onePartLocalIds` test fixtures
  from Phase D couldn't be reused as-is for Phase E's own test.** Phase E's
  `add_component` steps need a saved part's file to actually carry *that*
  part's own real id (`mergeComponentIntoDocument` rejects an empty-Parts
  file), but Phase D's own `_orchestrationHandler` always returned the same
  fixed `{'parts': []}` for `/document/export/native` - fine when nothing
  ever read a saved file's bytes back, wrong once Phase E's own
  `add_component` steps do. Replaced with a part-id-aware
  `_fullOrchestrationHandler` (keyed off the `part_id` query parameter
  `DocumentApiClient.exportNative` sends) and a validate handler that
  echoes back whichever `local_id`s the request body actually names, rather
  than Phase D's own hardcoded list - the assembly plan's own steps
  (`ac1`/`ac2`) are a different set than any one part's plan uses. The now
  entirely-unused `_orchestrationHandler` was deleted rather than left
  alongside its replacement.
- **`find.byType`'s default `skipOffstage: true` hid the just-pushed
  `PartScreen` from the orchestration test, even though it was already
  mounted with every constructor param set.** Driving "Open Assembly"
  with one bounded `tester.pump()` (deliberately not `pumpAndSettle`, to
  avoid needing to also mock every endpoint the new screen's own
  `_loadPart` would otherwise call) leaves the pushed route's page
  transition mid-animation - `flutter_test`'s finders treat that as
  "offstage" by default and skip it. Found by comparing `tester.allWidgets`
  (which did include `PartScreen`) against the failing finder; fixed with
  `find.byType(PartScreen, skipOffstage: false)`.
