# Workstream 16: Assembly mates gaps (plan)

Written 2026-11-04 from the open items at the end of `tools/ai_eval/README.md` ("Where this leaves the evaluation").
Implementation status is in "What was built" at the end of this file (Phases 1-3 built; Phase 4 harness work built, its model rounds not run).
Written to be implemented by a new session; read this file, `13-multi-part-assembly-overhaul.md` ("Mates turn and
stated assumptions") and `15-external-ai-zip-import-findings.md` first.

## The gaps

1. **External route not tried with a real external AI.** The Assembly-mode hand-off asks for a zip
   (`ai_plan_export.dart`), `AiPlanBundle` reads it, but no real external chat has produced one since.
2. **Imported zips get no mates turn.** `_runAssemblyCycle` skips `_runMateTurn` when `_importedBundle != null`, and
   the hand-off preamble tells the external AI "no mate steps". An imported assembly is placed but nothing holds it.
3. **No mate-completeness check.** Nothing reports whether the mates fully constrain each component. The dovetail
   plates got one seat mate each (before `face_selector.normal` existed) and can still slide in their slots.
4. **Second runs: none.** The 2026-11-04 tables are one run per sketch and model: direction, not pass rates.

The owner's priority is mates through an external AI app.

## The idea: the external AI writes the mates in the zip; the app splits the plan

The in-app flow needs two turns because a mate's `face_selector` cannot resolve against a component added in the same
plan: the dry run's scratch occurrence for an `add_component` has no target Part (`ai_plan.py`,
`_resolve_occurrence_target_part`). The in-app model also does not need anything from the first turn except the real
occurrence ids, which `summarizePlacedComponentsForMates` lists.

An external AI that wrote the whole zip already has everything a mate needs:
- every part's geometry, in that part's own coordinates, because it wrote each part plan. `face_selector`
  (`direction` / `normal` / `cylinder_radius` / `near`) is in exactly those coordinates;
- a name for every component: the `local_id` of its `add_component` step, which a `mate` reference may already
  name (`MateEntityRefStep.occurrence_id`, Phase 18).

So **a trip back to the external chat is not needed for the normal case.** The app can run the imported assembly plan
in two parts itself:
1. the placement steps (`add_component`, `move_component`, everything but `mate`) as one plan; this records each
   `add_component` `local_id` -> real occurrence id;
2. the `mate` steps as a second plan, with every reference to an `add_component` `local_id` rewritten to
   `existing:<real id>`, validated and run exactly as `_runMateTurn` runs the in-app model's mates plan.

No backend change and no wire change: step 2 is the same plan shape the in-app mates turn already sends, so
`face_selector` resolution, Closest branches and the grounded-side handling all apply unchanged.

The round trip back to the external chat is then kept for repair only (Phase 3): when the mates fail validation or
leave a component free that should not be.

Considered and not chosen:
- **Resolve `face_selector` on a same-plan `add_component` in the dry run** (pass `{relative_path: part_id}` for the
  parts this session built). It would make one plan valid as written, but it rests on the merged copy of a component
  having the same face indices as the Part the selector was resolved on, which nobody has checked, and it is a
  backend change. The client-side split gets the same result with code that already works.
- **Always a round trip** (export the placed components, the external AI replies with mates). Doubles the user's
  copy-paste trips and needs the real occurrence ids to survive a chat; the local ids the external AI chose itself
  are better names. Kept as the repair path only.
- **Run the in-app provider's mates turn on an imported zip.** Fine as an extra when an API key is configured
  (Phase 3, last item), but it defeats the point of the external route (its usage limits).

## Phase 1: mates in the imported zip

Client only.

- `ai_plan_export.dart`, `_assemblyHandoffPreamble`: replace "Place parts only: no mate steps" with: after the
  placements, add `mate` steps whose references name components by their `add_component` `local_id` and faces by
  `face_selector` in that part's own coordinates (the same rules as the Assembly mode instructions' mates section;
  point at it rather than repeating it). Ask for enough mates to fix every component that should not move, and to
  say in the reply which components are meant to move and how (feeds Phase 2's intended motion). Keep the rule that
  the first component stays unmoved.
- The system prompt contradicts this as it stands. `ai_scoping_prompt.dart`'s Assembly mode section says of the
  assembly plan "No mate steps yet - a component added in this plan has no real faces until it has run", and the
  next paragraph has mates name components by "existing:<id>", which an external chat never sees. The hand-off
  package embeds that same prompt (`_buildSystemPrompt()`), so give `buildAiScopingSystemPrompt` an
  `externalHandoff` flag (threaded from `_shareExternalHandoff` only) that swaps those two paragraphs for the
  external version: mates go at the end of the assembly plan, reference components by `add_component` `local_id`,
  same face_selector rules. Do not rely on the preamble overriding text further down the same package.
- The same section says "Mate each part to the one it actually touches, and do not add a mate the drawing does not
  imply." That is likely part of why the dovetails got one mate. Phase 2's check is the measured answer; meanwhile
  word the external version as "enough mates that each part is held where it is, unless it is meant to move".
- New pure helper (e.g. `ai_plan_split.dart`): `splitPlacementAndMates(AiGenerationPlan)` returns the plan without
  `mate` steps and the `mate` steps; `rewriteMateOccurrenceIds(List<AiMateStep>, Map<String, String> localToReal)`
  returns a plan whose references use `existing:<real id>`. A reference that names neither an `add_component`
  `local_id` nor `existing:` / `""` is left alone (validation reports it).
- The `local_id` -> occurrence id map is already there: `PlanTranslationResult.localIdToRealId`
  (`ai_plan_translator.dart`); the `add_component` case returns the new occurrence id.
- `_runAssemblyCycle`, `bundle != null` branch: split the imported assembly plan; run the placement plan as now; if
  there are mate steps, run them through the same execution and outcome handling as `_runMateTurn` (factor the
  validate/execute/`_mateNote` part out of `_runMateTurn` so both use it; the provider turn and retry stay in-app
  only). A failed mates plan never stops the run: the placed assembly is saved, and `_mateNote` says why, as today.
- Keep the in-app flow's two turns unchanged (12/12 Sonnet and Opus runs passed with it). The split also makes an
  in-app assembly plan that does include mates work instead of failing the dry run; note it, but do not change the
  in-app prompts in this workstream.
- Tests: unit tests for the split and rewrite; `ai_plan_export_test.dart` builds a zip with mates to the new layout
  and checks the importer reads it; an orchestration test (`ai_modelling_screen_orchestration_test.dart`, fake
  backend) that an imported zip with mates creates them after the placements and before the save, and that an
  invalid imported mates plan still saves the placed assembly with a `_mateNote`.

## Phase 2: mate-completeness check

The backend already computes it: `GET .../constraint_status` (`router.py` `get_constraint_status`,
`assembly_group.constraint_status`) gives each occurrence `fixed`, `fully_constrained`, `under_constrained` (with the
member's mobility as `dof`) or `over_constrained`; the client has `DocumentApiClient.getConstraintStatus`. It is used
by the Assembly tree badge, never by AI Modelling.

- **Describe the free motion, not just a count.** "dof 1" does not tell a model what to fix. `analyze_model` already
  has the nullspace `basis`; per member, each basis row is a twist (v, w). Classify it in the component's own part
  frame: w ~ 0 is a slide along v; otherwise a spin about axis w through the point w x v / |w|^2 (plus pitch if
  v . w != 0). Add this as an optional field (e.g. `free_motions: [{"kind": "slide", "direction": [..]}, {"kind":
  "spin", "axis": [..], "through": [..]}]`) on the constraint-status entry, or a separate endpoint if the badge's
  payload should stay small. Mobility above 1 has a basis that is any mix of motions; report the rows as the basis
  gives them and say so ("free motions include ...") rather than pretending they are unique. Backend test: a plate
  with one coincident seat mate reports two slides and one spin; adding the flank mates reports none.
- **Intended motion.** A wheel on an axle or a caster swivel is meant to move; the check must not push the model to
  lock it. Let the mates plan state it: an optional top-level `"intended_motion": [{"component": "<local_id or
  existing:id>", "motion": "spin about its axle"}]`. Check first how `AiGenerationPlan.fromJson` and
  `PlanValidateRequest` treat an unknown top-level field (the backend request model does not set `extra="allow"`;
  Pydantic's default ignores extras, but confirm) and keep it out of the validate payload if needed. Free text is
  enough: it is for the report and the model, not the solver.
- **After any AI-built assembly** (in-app mates turn and imported zip): call `getConstraintStatus` once the mates are
  built, before the save. Show per component in the progress panel under `_mateNote`: fully constrained, or the free
  motions, and the declared intent next to them.
- **In-app: one follow-up turn.** If a component is under-constrained and has no intended motion, send one more mates
  turn (new request text in `ai_scoping_prompt.dart` beside `assemblyModeMatesRequestText`): the components and their
  free motions, "add mates to remove these unless the part is meant to move; if it is, say so in intended_motion".
  One turn only, same never-stop rule. Over-constrained: report it, and send it in the same follow-up as a
  contradiction to remove.
- **Imported: no automatic turn** (there is no provider to ask); the report feeds Phase 3's fix hand-off.
- Tests: backend unit tests for the free-motion classification; client tests that the follow-up turn is sent only
  when a component is free and not declared, and at most once.

## Phase 3: the round trip, for repair

When an imported assembly's mates fail validation, or Phase 2 finds a component free that was not declared, offer
"Fix mates with external AI" in the progress panel.

- Builds a short package (new function in `ai_plan_export.dart`; reuse the system prompt section on mates, not the
  whole system prompt if it can be avoided, since the external chat already has it): the components by the zip's own
  `local_id`s and names, the validation failure text (`describeAiPlanValidationFailure`) or the free-motion report,
  and the instruction to reply with a file `mates.json`: a plan of `mate` steps only, references by the same
  `local_id`s, plus `intended_motion` if any. Copy / share it like `_shareExternalHandoff`.
- "Import mates" accepts that file while the imported assembly is still open in the screen: rewrite the `local_id`s
  through the map kept from Phase 1, validate and run like Phase 1's mates step, re-run the Phase 2 check, then save
  over the same assembly file (`_saveAssemblyAfterExecution` with the fixed path). Whether the reply replaces or adds
  to the existing mates: adds. Say so in the package so the external AI does not repeat mates that already hold.
- Same session only in this workstream: the `local_id` map lives in the screen state. Rebuilding it for an assembly
  reopened later (from each occurrence's `name_override` or `external_ref`) is a follow-up; note it as open.
- An imported zip with **no** mates at all (made with the old preamble, or the external AI ignored it) goes through
  the same button: the package then asks for all the mates. If an in-app provider is configured, also offer "Add mates
  with the in-app AI", which runs the existing `_runMateTurn`.
- Tests: package text for each trigger; import of a `mates.json` against a fake imported assembly.

## Phase 4: evaluation

`tools/ai_eval/` gains the external route and the completeness score, then runs the rounds that were skipped.

- **External route in the harness.** A run gets only what a user would paste: the Assembly-mode hand-off package
  (`buildExternalHandoffPackage(..., assemblyMode: true)` with an empty transcript, dumped by a new
  `eval.sh handoff` command) and the sketch images, and writes the zip's files to `runs/<sketch>/<model>-ext-r<n>/`.
  A new `eval.sh import <run>` zips them and builds through `AiPlanBundle.fromZipBytes`, the part plans, and Phase 1's
  split, in the same harness that `assemble` uses. New agent prompt `agent_prompts/model_external.md`: the model sees
  the package as a pasted user message, not as a system prompt, and gets the harness's scripted owner for
  assumption corrections as in `model_assembly.md`.
- **Completeness in the score.** `assembly_keys.json` gets each component's expected motion (`fixed` / `fully` / a
  named free motion, e.g. the caster wheel's spin and the swivel). `expected_assembly.py` reads the Phase 2 status
  after the mates and reports a `constrained` column next to pass/fail: matches, under (unintended free motion),
  over. Placement still decides pass/fail; completeness is reported separately so the two can be read apart.
- **Rounds, Sonnet and Opus only** (the owner dropped Haiku):
  1. External route, the three hand sketches and the three generated sheets, one run each (12 runs).
  2. A second in-app run of the same six (12 runs), so every cell has two.
  3. Re-score the 2026-11-04 in-app runs for completeness by rebuilding the saved replies (no model tokens).
  At about 80-110k tokens a run, rounds 1 and 2 are roughly 2-2.5M tokens. Confirm with the owner before running
  them; round 3 is free.
- **A real external chat: the owner's step.** A session cannot drive claude.ai, ChatGPT or Gemini. Write a short
  checklist in `tools/ai_eval/README.md`: share the hand-off from the app, attach the sketch, answer the
  assumptions, download the zip (or save the fenced blocks), import, record what broke. One run of `asm_dovetail` and
  one of `asm_wheel_bracket` in at least two chat apps would cover file creation vs fenced blocks.
- Update the README's results and "Where this leaves the evaluation" with whatever is run, one run per cell called
  out as such.

## Order and size

Phase 1 is the owner's priority and stands alone: do it first and ship it. Phase 2's backend part (free motions) can
go in parallel. Phase 3 needs both. Phase 4's harness work needs Phase 1; its completeness column needs Phase 2; its
model rounds need the owner's go-ahead.

## Not checked while writing this plan

- Whether an unknown top-level plan field passes `AiGenerationPlan.fromJson` and the validate endpoint.
- Whether `analyze_model`'s basis rows map cleanly to per-member twists in the part frame (they are in the
  lever-arm-weighted metric, `diag(1,1,1,L,L,L)`; undo the weighting before classifying).
- Nothing here has run. The design rests on reading the code, not on a build.

## Still open after this workstream

- The zip importer's repair of a moved first component (`15-...md`, finding 3).
- Rebuilding the `local_id` map for an imported assembly reopened in a later session.
- A real external chat run is the owner's to do; until then the external route is tested only by a model standing in
  for one.


## What was built

Written as each phase landed, with what changed from the plan above. Nothing here has been tried with a real external
chat app: the external route is covered by unit and widget tests with a fake backend, and (Phase 4) by a model standing
in for the chat, not by claude.ai / ChatGPT / Gemini.

### Phase 1: mates in the imported zip (built)

Client only, as planned.
- `ai_plan_split.dart`: `splitPlacementAndMates`, `rewriteMateOccurrenceIds` (rewrites `occurrence_id` and a Width
  mate's `midplane.b_occurrence_id`), `addComponentLocalIds`. Pure; `test/ai_plan_split_test.dart`.
- `_runAssemblyCycle` splits any assembly plan that carries `mate` steps (an imported zip's, **and** an in-app plan
  that included some, which used to fail the dry run). The placements run as the plan, then the mates run through the
  new `_executeMatesPlan`, which `_runMateTurn` also uses now (the provider turn and its one retry stay in-app only).
  `_runCarriedMates` rewrites the ids and calls it. Only `add_component` local ids are rewritten (the translator's
  `localIdToRealId` also holds a `move_component`'s id, which is not a component). The in-app flow with no mates in its
  plan is unchanged: still the second provider turn.
- A failed mates plan never stops the run: the placed assembly is saved and `_mateNote` says why. For an imported
  zip the note lists the failing steps (`listAiPlanValidationProblems`, a new helper split out of
  `describeAiPlanValidationFailure`: the problem lines without the instruction to a model). An imported zip with no
  mates gets "Saved without mates: the imported assembly plan has none."
- Prompt: `buildAiScopingSystemPrompt(externalHandoff: true)`, set only by `_shareExternalHandoff`, swaps the in-app
  assembly and mates paragraphs for `assemblyModeExternalVocabularyText` (mates at the end of `99_assembly.json`,
  components by `add_component` `local_id`, `face_selector` rules as in-app, "enough mates that each part is held
  where it is, unless it is meant to move"). The in-app text is byte-identical to before (checked).
  - **Changed from the plan:** the "Assembly editing" section of the same prompt also says a `face_selector` is
    "only on an `existing:<id>` occurrence" and that a bare `local_id` cannot take a selector. That contradicts the
    external text, and it is a third place, not one of the two paragraphs the plan named. The external paragraphs say
    plainly that in this plan they replace that rule, rather than editing the shared section (the in-app prompt is
    pinned by the 2026-11-04 runs). Whether an external model reads that override correctly is untested.
- Hand-off preamble: "Place parts only: no mate steps" replaced by the mates instruction. It asks the AI to say which
  components are meant to move; Phase 2 turns that into a field in the JSON, since the importer cannot read a chat
  reply.
- Test hook: `AiModellingScreen(pickImportZip: ...)` replaces the file picker so a widget test can import a zip
  without file I/O.
- Tests: split/rewrite units; `ai_plan_export_test.dart` (the preamble, the embedded paragraphs, a zip with mates
  read and split); `ai_modelling_screen_orchestration_test.dart` (an imported zip builds placements, then mates with
  real occurrence ids, before the save; invalid mates still save with a note; no mates says so; the provider is never
  asked).

Not verified: the split against a real backend's `face_selector` resolution (the widget tests use a fake backend). The
Phase 4 harness `import` command is where that is exercised.

### Phase 2: the completeness check (built)

Backend (`assembly_group.py`, `schemas.py`, `router.py`):
- `constraint_report(document, part)` = `constraint_status` plus, per `under_constrained` occurrence, its free motions
  (`constraint_status` is now a thin wrapper, unchanged for its callers). `GET /parts/{id}/constraint-status` entries
  gain `free_motions: [FreeMotion]` (empty for every other status, so the tree badge's payload only grows for free
  components). Note the route is `constraint-status`, with a hyphen (the plan wrote `constraint_status`).
- `free_motions_for_member` describes them **in the component's own part frame** (the frame `face_selector` uses), as
  `slide {direction}`, `spin {axis, through}` or `screw {axis, through, pitch_per_turn}`. It takes the member's block
  of the nullspace basis, splits pure translations from rotations (SVD of the rotation part), rotates both into the
  part frame, and prefers the coordinate axes inside each subspace, so a seated plate reads as "slide along x, slide
  along y, spin about z". `through` is the point on the spin axis nearest the part origin. With mobility above 1 the
  list is a basis: any mix is free (the client says "any mix").
- **Changed from the plan: the weighting is not undone again.** `GroupAnalysis.basis` is already `null_y / weights`,
  i.e. in plain `[v, w]` (mm, radians) coordinates, although its comment says "orthonormal in metric diag(1,1,1,L,L,L)"
  (which is true of its rows' *norm*, not its entries). Dividing by the weights again scales the spin points wrongly;
  `test_a_pin_in_a_bore_slides_and_spins_about_its_own_axis_even_when_that_axis_is_off_the_origin` fails if it is
  (checked by doing it once). The code multiplies the member's block by the weights only to take a well-scaled SVD.
- The twist convention checked: `v` is the origin's translation and `w` the rotation vector composed on the left (world
  axes), so a free point `q` of the part moves by `v + w x (R q)`; the spin axis in the part frame passes through
  `w_p x v_p / |w_p|^2`.
- Tests (`test_constraint_free_motions.py`): one coincident seat mate = two slides + a spin about its normal; the three
  flank mates = none (`fully_constrained`); an unmated component = three slides and three spins; a box turned 90 degrees
  about x reports its motions in its own frame, not the world's; a pin in a bore = a slide and a spin about an axis off
  the origin; the endpoint's JSON. `test_validate_ignores_an_unknown_top_level_field` (see below).

Unknown top-level plan field (the "check first" item):
- Client: `AiGenerationPlan.fromJson` read only `version` and `steps` and ignored the rest, and `toJson` dropped it.
- Backend: `PlanValidateRequest` is a plain Pydantic model (default `extra="ignore"`); the new test confirms a validate
  request with `intended_motion` returns 200.
- So a plan carrying `intended_motion` was already harmless. It is now parsed (`AiGenerationPlan.intendedMotion`,
  entries `{component, motion}`, malformed entries skipped) and `toJson()` still leaves it out of the validate payload
  (`toJson(includeIntendedMotion: true)` has it). A plan may have **no steps** if it declares an intended motion (a
  follow-up that adds nothing); without one the "Plan has no steps" error is unchanged.

Client (`ai_assembly_report.dart`, `ai_modelling_screen.dart`, `ai_scoping_prompt.dart`):
- `buildCompletenessReport` joins `listOccurrences`, `getConstraintStatus` and the declared intent (a component named by
  real id, `existing:<id>`, name or file name, case-insensitively; an unknown name is ignored). The text per component:
  fixed / fully constrained / "free to move: slide along x, slide along y, spin about z (any mix)" / over-constrained /
  not checked (its mates could not be resolved), plus `(meant to move: "...")` when declared. An assembly of more than
  12 components lists only those that need attention and counts the rest.
- Shown in the progress panel under `_mateNote` ("Mate check") after every AI-built assembly, in-app or imported, once
  the mates are built and before the save.
- In-app follow-up: when a component is free and no `intended_motion` names it, `_runMatesFollowUp` sends ONE more
  mates turn (`assemblyModeMatesFollowUpRequestText`: the free components with their motions, "add only the mates that
  are missing", and the `intended_motion` format), builds what comes back, and checks again. Never a second one (a
  test asserts a seventh provider turn is never sent). Sent only after the first mates turn built something; any
  failure is noted and never stops the run. A reply with `"steps": []` and an `intended_motion` is accepted.
- **Changed from the plan:** an over-constrained component is reported but does not trigger the follow-up and is not
  sent "as a contradiction to remove": the plan schema has no step that deletes a mate, so the model cannot remove one.
  The follow-up only tells it to add no mates to such a component.
- **Changed from the plan:** the in-app system prompt (pinned by the 2026-11-04 runs) does not mention
  `intended_motion`, so the in-app first mates turn cannot declare an intent; the follow-up request text describes the
  field instead. A deliberately free component (a wheel) therefore costs the in-app route one follow-up turn.
- The external route does declare it up front: the external paragraphs and the hand-off preamble ask for a top-level
  `intended_motion` in `99_assembly.json`; the importer carries it through the split (component ids rewritten like the
  mates') into the report. Imported: no automatic turn; the report feeds Phase 3.
- Tests: `ai_assembly_report_test.dart`; `ai_plan_test.dart` (the unknown field, `intended_motion`, empty steps);
  `ai_modelling_screen_orchestration_test.dart` (follow-up sent for a free undeclared component with its motions
  listed, then re-checked; declared intent = no follow-up; at most one follow-up; a follow-up that only declares
  intent; held components = none; an imported zip gets the report with the zip's intent and never a provider turn).

- When the run inserted into an existing assembly file, the check ignores the components that were already in it
  (`_preexistingOccurrenceIds`, taken when the file is opened), so it never asks for mates for the user's own earlier
  work. Not covered by a test of its own.

Not verified: the free-motion description on a real AI-built assembly beyond one hand-written two-part zip through the
eval harness (the backend tests use hand-built scenes); how a
model reacts to the follow-up request (no model was run, see Phase 4).

### Phase 3: "Fix mates with external AI", "Import mates" (built)

Client only. In the progress panel of an assembly that was imported from a zip, once it is saved and while this screen
still holds the import, up to three buttons appear when the mates need another go (none in the zip; failed
validation; stopped part-way; or built but components free and not declared intended):
- **Fix mates with external AI** (`_shareMatesFix`): the same copy / share sheet as the hand-off (`_offerPackage`, now
  shared), with `buildExternalMatesFixPackage` (`ai_plan_export.dart`): the components by the zip's `local_id`s with
  part name and file (`AiPlanBundle.assemblyComponents`), why the app is asking (`ExternalMatesFixReason`), the mates
  rules (`assemblyModeExternalMatesGuidance`, split out of the external prompt paragraph, not the whole system prompt),
  a sample mate step, and the reply format: one `mates.json`, mate steps only, plus `intended_motion`. It says plainly
  what already holds so the reply adds and does not repeat: after a failed validation **none** were built (so it asks
  for all of them); when some were built and one failed, the earlier ones stay; when only components are free, send
  only the missing ones. The free components are listed by local id (`formatFreeComponentsByLocalId`).
- **Import mates** (`_importMates`): reads the file (bare JSON, or fenced in prose as `detectPlanInAssistantText`
  reads), refuses anything but mate steps, rewrites the `local_id`s through the map kept from Phase 1
  (`_importedLocalIdToRealId`), builds them with `_executeMatesPlan`, re-runs the Phase 2 check, and saves over the
  same assembly file (the save dialog pre-filled with its path, the existing overwrite gate). It **adds** to the built
  mates; it never replaces them. A reply that fails validation builds nothing and says why.
- **Add mates with the in-app AI** (`_addMatesWithInAppAi`), only when a provider is configured and the zip's mates
  are missing or failed: runs the existing `_runMateTurn`, then the check with its one follow-up, then the save.
  **Changed from the plan:** it first adds a transcript message holding the part plans from the zip, because the
  in-app model never wrote them and a mate names faces by the part's own geometry; without that it would be naming
  faces blind. Whether that is enough for a model to write good mates is untested.
- Same session only, as planned: the `local_id` map lives in the screen state, so reopening the assembly later (or the
  screen being dismissed) loses the buttons. Rebuilding it from each occurrence's `name_override` / `external_ref` is
  still open.
- If the user cancels the save dialog after an import of mates, the screen shows its usual "Save cancelled" error; the
  Retry that follows proposes a fresh name rather than the existing file's path (the save-only retry reads the
  "insert into existing assembly" target, which an imported zip has not set). Not fixed.
- Test hooks: `AiModellingScreen(pickMatesText: ...)`, with `pickImportZip` from Phase 1.
- Tests: `ai_plan_export_test.dart` (the package text for each reason); `ai_modelling_screen_orchestration_test.dart`
  (failed mates offer the package, which names the zip's ids; import rewrites ids, builds, re-checks and saves over
  the same file; a file with a non-mate step is refused; free components give the "only the missing mates" package;
  no mates also offers the in-app AI, which is given the part plans and builds its mates).

Not verified: with a real external chat. The package is text; whether a real model answers it with a usable
`mates.json`, and in which of the chat apps' file formats, is exactly what the owner's checklist (Phase 4) is for.

### Found while building Phase 4: a schema-invalid mates plan stopped the run (fixed)

Running a hand-written zip with a bad face direction (`"+q"`) through the real backend: `POST .../ai-plan/validate`
answers a request the schema rejects with HTTP 422, not with per-step results, so `DocumentApiClient.validateAiPlan`
throws an `ApiException`. In the app that exception left `_executeMatesPlan` (and, before Phase 1, `_runMateTurn`),
reached `_runAssemblyCycle`'s catch, and stopped the run with the assembly built but not saved: the opposite of "a
failed mates plan never stops the run". `_executeMatesPlan` now catches it and treats the plan as failed validation
(nothing built; the note carries the server's message; the in-app retry turn is told it too). Widget test:
`an imported zip whose mates plan the server rejects outright (HTTP 422) still saves the placed assembly`. A schema-invalid
*placement* plan still stops the run as before (it is in `_runAssemblyCycle`'s own `on ApiException`, with Retry).

### Phase 4: the harness (built; model rounds not run)

`tools/ai_eval/` (details and the owner's checklist in its README, "External route"):
- `eval.sh handoff <dir>` writes the Assembly-mode hand-off package as the app builds it; `eval.sh import <run>` zips a
  run's `files/*.json` (or extracts fenced blocks from `final_reply.txt`), reads the zip with `AiPlanBundle`, builds the
  parts and the assembly with the app's own cycle (placements, the zip's mates with their local ids rewritten, the
  completeness check) and scores it like `assemble`. The harness's assembly build is now shared between the two.
- `agent_prompts/model_external.md`: the model sees the package as a pasted user message, not a system prompt.
- `harness/assembly_keys.json` / `models.py`: `expected_motion` per assembly and part (**my reading, unconfirmed**);
  `expected_assembly.py` reports `constrained` (match / under / over / differs) beside pass/fail without changing it;
  `table_assembly.py` shows the column.
- **Changed from the plan:** the harness does not play the app's one follow-up mates turn, so in-app runs measure the
  completeness of the first mates turn. The plan did not ask for it; noted in the README.
- **Re-scoring the saved 2026-11-04 runs was not possible:** they were never in the repository (`runs/` is
  git-ignored) and this session started from a fresh checkout, so there was nothing to rebuild. The harness can rebuild
  them once the folders are back (README). No model tokens were spent and none are needed for it.
- Verified against a live backend with a hand-written (not model-written) zip for `asm_pin_block`: the full path
  (importer, parts, placements, rewritten face-selector mates, completeness, score) works; the pin is reported free to
  spin about z; the same zip with its seat mate removed is scored `under`; an invalid direction is refused and
  recorded. That is the only run of the external route against a real backend, and it is not evidence about how a model
  or a chat app behaves.

### Model rounds run so far (owner's go-ahead, reduced scope)

Sonnet only, external route, two runs each on `asm_pin_block`, `asm_wheel_bracket` and `asm_caster` (about 0.6M tokens):
6/6 imported, built and passed placement with mates in the zip and no retries; completeness matched on the easy and
medium sketches (2/2, 5/5) and was 4/8 on both caster runs because the swivel was locked (one choice, four `over`
verdicts). Tables and caveats: `tools/ai_eval/README.md`, "External route, Sonnet, 2026-11-04". A model standing in for a
chat app, not a real one.

## What is still open

- The remaining model rounds (Opus, the three hand sketches, a second in-app run), about 2M tokens: waiting for the owner's go-ahead.
- The owner's real-chat run (README checklist). Until it exists, nothing here shows the external route works with a real
  chat app; the importer, prompt and package are exercised only by tests and a stand-in.
- Re-scoring the 2026-11-04 in-app runs for completeness: needs the saved run folders.
- The expected motions in the keys: to be confirmed by the owner.
- Rebuilding the `local_id` map for an imported assembly reopened later; the importer's repair of a moved first
  component (`15-...md` finding 3); after a cancelled save during "Import mates", Retry proposes a new file name.
- Not tried: whether an external model follows the "Assembly mode" paragraphs rather than the "Assembly editing" ones
  where they differ (the external text says plainly that it overrides them).
