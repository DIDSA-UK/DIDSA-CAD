# External-AI multi-part zip import - build notes and findings

Session of 2026-10-30. Branch `claude/didsa-cad-external-ai-import-c6e5t6`, PR #324.
Trigger: a multi-part frame (long rail, short rail, post, gusset, assembly)
authored by an external AI via "Share with external AI", returned as a zip of
JSON files.

## What was built

**Zip import** (`client/lib/ai/ai_plan_bundle.dart`, `ai_modelling_screen.dart`)
- "Import plan" accepts `.zip`: one `part_manifest`, one plan per part, one
  assembly plan. Files are classified by content (the plan containing
  `add_component` steps is the assembly; the rest are part plans, taken in
  file-name order and matched to the manifest by position).
- The manifest lands on the existing confirm-parts panel. "Confirm & Generate
  All" then runs the normal part/assembly cycles with the imported plans
  instead of provider turns (`_importedBundle`).
- The assembly's `add_component` `relative_path`s are rewritten to the names
  the parts were actually saved under (matched by `<TYPE_PREFIX>_NNN` against
  the manifest's original prefix), so a collision-avoiding rename doesn't
  break the assembly.
- Retry is disabled for a failed imported plan (re-running a fixed plan can't
  succeed); only a cancelled save is retryable.
- `archive` is now a direct client dependency (was transitive, same locked
  version).

## Findings

1. **Hole-loop corners could not be filleted** (fixed).
   `edge_from_sketch_point`/`edge_from_sketch_line` resolve through a
   provenance map built by `_profile_boundary_shapes` (`extrude.py`), which
   only matched `profile.point_ids` - the outer loop. Corners of
   `profile.inner_loops` (e.g. the inner rectangle of a hollow section drawn
   in the same Sketch, exactly what the prompt recommends) had no entry, so a
   fillet on them failed `edge_selector_no_matching_edges`. The LLM followed
   the documented rules; the validator disagreed with them. Now every loop is
   matched. Revolve shares the function; Sweep passes only the outer wire, so
   hole-loop corners still don't resolve there.
   Test: `test_edge_from_sketch_point_selects_a_corner_of_a_hole_loop`.

2. **The in-app AI's "fix" for finding 1 was a different failure.** It moved
   the inner profile into a second sketch plus a cut, then hit `missing_body`
   on the next fillet (the tube no longer existed as a body after the cut).
   Cause not established - never reproduced, and the failing plan's cut
   parameters were not captured. Worth re-checking now that finding 1 removes
   the reason to take that route.

3. **`move_component` on the grounded first component** (dry run fixed;
   importer not).
   The first component placed in an assembly is auto-`fixed`; the real
   endpoint 422s `occurrence_is_fixed`. The external AI's assembly moved it
   (120 degrees about (1,1,1)), the dry run accepted that, and generation
   failed at step 2 after building step 1. Now the dry run rejects it, and the
   Assembly editing prompt says the first component is the reference frame and
   must not be moved. Not the file extension: `add_component` accepted
   `LONG_RAIL_001.DIDSAprt`. Test:
   `test_move_component_on_the_grounded_first_component_is_rejected_in_the_dry_run`.

## Update 2026-11-04: the hand-off now asks for the zip

The importer existed, but the instructions an external AI was given (`ai_plan_export.dart`) still asked for one
`plan.json`, so a zip only arrived when an external AI invented one. In Assembly mode the hand-off now has its own
preamble describing exactly what `AiPlanBundle.fromZipBytes` reads: `00_manifest.json` (the part_manifest, every
`type_prefix` different), `01_<TYPE_PREFIX>.json`... one plan per part in manifest order, and `99_assembly.json`
with `add_component` paths `<TYPE_PREFIX>_001.didsa`, the first component unmoved, and placements only - no mates,
since an imported assembly gets no mates turn (`13-multi-part-assembly-overhaul.md`, "Mates turn and stated
assumptions"); they are added in the app. `ai_plan_export_test.dart` builds a zip to that layout and checks the
importer reads it. Not tested with a real external chat.

**Superseded 2026-11-04 (`16-assembly-mates-gaps-plan.md`, Phase 1):** the hand-off now asks for the mates too, at the
end of `99_assembly.json`, naming components by their `add_component` `local_id`; the app places the components, then
rewrites those ids and builds the mates (`ai_plan_split.dart`). The "no mate steps" wording above is what was true
for the first version only.

## Update 2026-11-04: sub-assemblies in the same zip

Reported from testing the castor drawings (wheel and bush as a sub-assembly): the hand-off allowed one assembly per zip,
so the external AI said a sub-assembly needed two zips imported in order. Now one zip carries them:

- **Format** (`ai_plan_export.dart`, the Assembly-mode preamble). The manifest may add `"sub_assemblies": [{name,
  type_prefix, summary}]`, in build order; their parts stay in `"parts"`. One assembly plan per sub-assembly,
  `90_<TYPE_PREFIX>.json`, `91_...`, written like `99_assembly.json` (placements, then mates, its own frame). A later
  assembly places a sub-assembly with one `add_component` of `<TYPE_PREFIX>_001.didsa`. A mate to a part inside it uses a
  path of local ids, `castor/wheel`.
- **Importer** (`ai_plan_bundle.dart`). Assembly plans are still found by content; the last by file name is the top
  level, the ones before it are the manifest's `sub_assemblies` by order. A count mismatch (including two assembly plans
  and no `sub_assemblies`) is a clear error. `subAssemblyPlanFor` / `assemblyPlanFor(savedSubAssemblyPaths:)` repoint
  sub-assembly references like part ones; `assemblyComponents` lists a sub-assembly's parts by path for the mates-fix
  package.
- **Screen** (`ai_modelling_screen.dart`). After the parts, `_runAssemblyCycle` builds each sub-assembly first
  (`_runImportedSubAssemblyCycle`: placements, its own mates, a save prompt proposing `<TYPE_PREFIX>_NNN`), then the top
  level. Each gets a row on the progress panel; the confirm panel lists them. A cancelled sub-assembly save retries as a
  save; any other failure stops the run (imported plans are fixed, as before).
- **Mate paths** (`ai_plan_split.dart`). `rewriteMateOccurrenceIds(nested:)` turns `castor/wheel` into
  `existing:<real castor id>/<real wheel id>`, using what each sub-assembly's build placed (`PlacedComponentIds`).
  "Import mates" reads paths too.
- **Backend** (`ai_plan.py`, `_lookup_mate_occurrence`). The dry run accepts `existing:<outer>/<inner>` in a mate
  reference (the `/` path a real Mate into a sub-assembly is already stored with) and resolves `face_selector` against
  the innermost component. Only for mates; `move_component` etc. still take a top-level component.
- **Translator** (`ai_plan_translator.dart`). `add_component` of a file that places components is composed with the
  files it references (`AssemblyGraphComposer`, as the Part screen's Add Component does), so the sub-assembly's parts
  arrive resolved. A solve after a mate on a nested path solves its top-level component.

Verified: unit tests (`ai_plan_sub_assembly_test.dart`, `test_ai_plan_mate_into_sub_assembly.py`), a screen test with a
mocked backend (`ai_modelling_screen_orchestration_test.dart`, "an imported zip with a sub-assembly ..."), the existing AI and
assembly client tests and the backend `ai_plan`/mate tests, and a hand-written castor zip
(`tools/ai_eval/selftest/asm_castor_sub`, bracket + axle + a wheel-and-bush sub-assembly) built end to end through the
eval harness against a live backend: every part, the sub-assembly and its 2 mates, the top level and its 4 mates (two of
them into `castor/bush`), 4 solids, no overlap, only the declared spins free. Not verified: the screen driving a run against a
real backend (the harness and the mocked screen test stand in for it), a real external chat writing such a zip, and the castor drawings themselves.
The in-app flow (no zip) still has no sub-assemblies: its manifest turn does not ask for them.

## Open / not done

- **The zip importer does not repair finding 3.** An imported assembly that
  moves its first component now fails validation with a clear error. A fix is
  to re-express the whole assembly in the first component's frame: apply the
  inverse of its placement to every other component's placement. Left for the
  planned assembly testing.
- *Update 2026-11-04:* one imported zip (hand-written, for `asm_pin_block`, with mates) has now been built end to end
  against a live backend through the eval harness (`tools/ai_eval`, `eval.sh import`); that is not a real external
  chat. The remaining point below stands for the app screen itself.
- Real end-to-end verification of an imported multi-part zip (Generate All
  through the assembly) has not been done; this session had no Flutter SDK
  that ran, no OpenCascade, and no display. Client behaviour was verified only
  by CI (`ai_plan_bundle_test.dart`, compile of the screen), and the parser
  against the real sample zip in a scratch Dart project.
- Not confirmed: whether `add_component` should also accept `.didsa` where
  `.DIDSAprt` is listed (raised from earlier testing; not reproduced here).

## CI notes

- The first client run failed to compile: `plan` was assigned in two branches
  so Dart stopped promoting it to non-null inside `setState` closures. Fixed
  by binding `final plan = detectedPlan;` after the null check.
- From this sandbox the Actions log download host is blocked; the full job log
  can still be fetched through the GitHub tool with a large `tail_lines` (it
  is saved to a file), then filtered for the failure marker.
