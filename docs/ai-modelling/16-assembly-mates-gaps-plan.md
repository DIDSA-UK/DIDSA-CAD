# Workstream 16: Assembly mates gaps (plan)

Written 2026-11-04 from the open items at the end of `tools/ai_eval/README.md` ("Where this leaves the evaluation").
Not built. To be implemented by a new session; read this file, `13-multi-part-assembly-overhaul.md` ("Mates turn and
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
