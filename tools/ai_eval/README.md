# AI modelling evaluation

A repeatable test of AI Modelling (`docs/ai-modelling/`) against hand-drawn sketches. A model reads each sketch and writes a plan, and the app's own code builds it against a real backend. The built part is then scored against an answer key for that drawing. Use it before and after any change to the prompts, the plan schema, the translator or the dry run, and keep a change only if the scores hold or improve.

Everything except the model's own replies uses the app's code:
- the prompts are dumped from `ai_scoping_prompt.dart` and `ai_provider.dart`;
- plans go through `detectPlanInAssistantText` and `PlanTranslator`, including the backend dry run;
- the validation-retry turn, the render-back check prompt and the fix turn are built by the same functions the screen uses.

So a run tests what ships, not a copy of it.

## What it does not test

- **The provider wire calls themselves.** The model's replies are produced by hand (see "Running a round"), not through `AnthropicProvider` or `OpenAiCompatibleProvider`. A model run this way also sees a wrapper prompt the app does not send, and gets the system prompt as a file rather than in the system slot. Expect results close to production, not identical.
- **Non-Claude providers**, unless you run their replies through the same steps.
- **Feel and UI.** This tests the generated geometry only.

## Layout

| Path | What |
|---|---|
| `sketches/` | The test drawings, downscaled to 1568 px on the long edge as the app does. `asm_*` are multi-part assemblies (see "Assembly mode"). |
| `sketches/source/` | The reference models the generated assembly sheets are drawn from, and the answer keys come from. |
| `harness/expected.py` | The answer key for each sketch, and the scorer. |
| `harness/expected_assembly.py`, `harness/assembly_keys.json` | The same for the assembly sketches, plus the completeness (`constrained`) comparison against each key's `expected_motion`. |
| `harness/ai_eval_harness_test.dart` | The app-code side, run through `eval.sh`. |
| `harness/inspect_step.py` | Geometry report for a STEP file: volume, bounding box, faces, cylinder radii. |
| `harness/table.py` | Pass table, plus how the render-back check's verdicts compare with the scores. |
| `agent_prompts/` | Instructions for the model standing in for the provider. `model.md` covers the image analysis and the chat; `check.md` covers the render-back check; `model_assembly.md` is `model.md` for Assembly mode; `model_external.md` plays an external chat app for the external route. |
| `eval.sh` | `prompts`, `build`, `verdict` and `table`; for assemblies `prompts-assembly`, `manifest` and `assemble`; for the external route `handoff` and `import`. |
| `selftest/` | A hand-written zip that exercises the external route's code without a model. |
| `runs/`, `prompts/`, `prompts_asm/` | Output (git-ignored). |

## Setup

DIDSA-VR's `tools/setup_test_env.sh backend flutter` installs the backend's conda env and Flutter. Then:
- `source /opt/tools/env.sh`;
- start a throwaway backend with DIDSA-VR's `tools/start_backend.sh` (in-memory, on 127.0.0.1:8000);
- set `CAD_PY=/opt/tools/cad-env/bin/python`.

## Running a round

1. `tools/ai_eval/eval.sh prompts tools/ai_eval/prompts` writes the app's current prompts.
2. For each sketch, model and repeat, make `runs/<sketch>/<model>-r<n>/`. Run a fresh model on `agent_prompts/model.md`, with `{PROMPTS}`, `{IMAGE}` and `{RUN}` filled in.
   - In a Claude Code session, "run the AI eval round" can do this with one sub-agent per run, choosing each sub-agent's model.
   - The model writes `extraction.txt`, `reply1.txt` and, if it asked questions first, `reply2.txt`. The scripted answer is in `model.md`.
3. Copy the reply that holds the plan (`reply2.txt`, else `reply1.txt`) to `reply.txt`, then run `eval.sh build runs/<sketch>/<model>-r<n>`.
4. **Validation failed** (`retry_request.txt` appears): send its text to the same model conversation as the app's automatic retry would, save the reply as `retry/reply.txt`, and run `eval.sh build .../retry`. The app retries once.
5. **Built** (`drawing.png` and `check_prompt.txt` appear): run a fresh model on `agent_prompts/check.md`, the app's one-shot render-back check. That writes `check_reply.txt`; then run `eval.sh verdict <that build dir>`.
   - If it did not match, `fix_request.txt` is what "Ask the AI to fix it" sends. To measure the fix, send it to the model conversation, save the reply as `fixed/reply.txt`, and build `fixed/`.
6. `eval.sh table tools/ai_eval/runs` prints the results.

Two runs per sketch and model shows consistent errors, not small differences. Use more runs or new sketches before trusting a few points either way.

**Cost:** about 80-100k tokens per run per model, mostly reading the system prompt. A render-back check adds a few thousand.

## Assembly mode

The `asm_*` sketches test Assembly mode (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the model names
the parts in a `part_manifest`, the app asks for each part's plan in turn and saves each one to its own file, then
asks for one assembly plan of `add_component` and `mate` steps against those files. The harness does the same with
the app's code: the same request turns, the same file names the save dialog proposes, a real project folder, and
every part and the assembly built in one backend document.

1. `tools/ai_eval/eval.sh prompts-assembly tools/ai_eval/prompts_asm`.
2. Run a fresh model on `agent_prompts/model_assembly.md` with `{PROMPTS}`, `{IMAGES}` (every sheet of the sketch)
   and `{RUN}` filled in. It writes `extraction.txt`, `reply1.txt` and maybe `reply2.txt`.
3. Copy the reply with the manifest to `reply.txt` and run `eval.sh manifest <run>`. That writes `requests/`: one
   turn per part, the assembly turn, and the section the assembly turn's system prompt gains.
4. Send the same model conversation the part turns in order, then the assembly turn, with the system-prompt
   section; it writes `part_NN_reply.txt` and `assembly_reply.txt`. The app sends each part turn after the
   previous part is built; nothing in a reply depends on that build unless it fails, so they can go together.
5. `eval.sh assemble <run>` builds and scores. A failure writes `part_NN_retry_request.txt` or
   `assembly_retry_request.txt` (the turn the app would send); the reply goes to `..._retry_reply.txt` and
   `assemble` is run again.

Scoring (`expected_assembly.py`): each distinct part is matched by volume, bounding box and radii; the assembly by
solid count, bounding box, union volume (parts that overlap make it smaller) and placement (each component's
distance from the assembly's centroid). A nested sub-assembly is scored flattened, since Assembly mode can only
build one level.

Assembly mode has no render-back check in the app (only the single-part flow has one), so these runs have none.

## External route (the hand-off and the zip)

Assembly mode's "Share with external AI" gives a user a package to paste into another chat app, and the app's
"Import plan" reads back the zip that app produces (`docs/ai-modelling/15-external-ai-zip-import-findings.md`, and
`16-assembly-mates-gaps-plan.md` for the mates in it). The harness plays that route with the app's own code, with a
model standing in for the chat app. **It is a stand-in: nothing here has been run against claude.ai, ChatGPT or
Gemini** (see "A real external chat" below).

1. `tools/ai_eval/eval.sh handoff tools/ai_eval/prompts_ext` writes `handoff.md`: the Assembly-mode hand-off package
   exactly as the app builds it with nothing said yet. That plus the sketch image(s) is all a user has to paste.
2. Make `runs/<sketch>/<model>-ext-r<n>/`. Run a fresh model on `agent_prompts/model_external.md` with `{HANDOFF}`,
   `{IMAGES}` and `{RUN}` filled in. It treats the package as a pasted user message (no system prompt, no image-analysis
   step), writes `reply1.txt` (and `reply2.txt` after the scripted "use your best reading"), and delivers the zip's files:
   the JSON files in `<run>/files/`, or, for a chat app that cannot create files, fenced blocks in `final_reply.txt`
   (the harness extracts them, as the user would save them). Its assumptions are answered by the harness as the owner
   in the in-app rounds: correct only what contradicts the owner's reading, confirm the rest.
3. `eval.sh import <run>` zips `files/*.json`, reads the zip with `AiPlanBundle.fromZipBytes`, builds every part into one
   backend document and project folder, then the assembly the way the app does (`AiModellingScreen._runAssemblyCycle`):
   the placements, then the zip's own mates with their `add_component` `local_id`s rewritten to the real occurrence ids,
   then the completeness check. Same outputs and score as `assemble`; a failure is recorded, not retried (an imported
   plan is fixed). `eval.sh table` lists `-ext-` runs with the others.

`eval.sh assemble` now takes the same path for an in-app assembly plan that carries its own mates: placements, then the
mates, as the app does.

### Completeness (the `constrained` column)

After the mates, the harness reads the app's per-component mate check (`GET .../constraint-status`, with each free
component's free motions in its own part frame) into `completeness.json` and `completeness.txt`. `expected_assembly.py`
compares each component with its part's `expected_motion` in `assembly_keys.json` and reports `constrained`, e.g.
`11/12`, with the `under` / `over` / `differs` ones in `score.json`. **It never changes pass/fail**: placement decides
that, completeness is read beside it.

- Vocabulary: `held` (fixed or fully constrained), `spin` / `2spin` (free to spin about one / two axes and nothing else:
  motion is absolute, so a wheel on a swivelling fork also swivels and is `2spin`), `slide+spin`, `2slide+spin`, `free`.
  Alternatives with `|`: a round pin, bolt, washer or nut in a hole is `held|spin`.
- `under`: the component can move more than any alternative allows (the gap this check was built for: the dovetail
  plate's one seat mate leaves it `2slide+spin` where `held` is expected). `over`: held more than expected, or its
  mates contradict each other. `differs`: as much freedom, a different motion.
- **The expected motions are my reading, not the owner's** (they live in `sketches/source/models.py`
  `EXPECTED_MOTION`, copied into `assembly_keys.json`): please check them with the answer keys above, above all the
  caster (fork `spin`, wheel `2spin`) and whether a round pin should count as `held` or `spin`.
- The harness measures the first mates turn. It does not play the app's one follow-up turn for a free component (the app
  sends it in-app only), so in-app runs show what the model left free *before* that turn.
- Harness self-test (2026-11-04; the zip is kept in `selftest/`, see its README): a hand-written zip for `asm_pin_block` (written by hand, **not** a model run) built
  through `import` against a live backend: parts and assembly built, placement passed, both mates built, the pin reported
  `free to spin about z` and scored `2/2`; the same zip with its seat mate removed reported `slide along z, spin about z`
  and scored `under`; one with an invalid face direction was refused by the server with HTTP 422 and recorded, with the
  placed assembly still built. That 422 case exposed a gap in the app (a schema-invalid mates plan threw instead of being
  recorded as a failed plan), fixed in `_executeMatesPlan`.

### A real external chat: the owner's checklist

A session cannot drive a chat app, and the external route has not been tried with one. To do it by hand, once per chat
app (at least two, to cover file creation against fenced blocks), for `asm_dovetail` and `asm_wheel_bracket`:

1. In DIDSA-CAD, open AI Modelling, switch to **Assembly**, and use **Share with external AI** (the toolbar share
   button): **Copy text**, or **Share / Save file**. Nothing has to be said in the conversation first.
2. In a fresh chat of the app under test, attach the sketch(es) (`sketches/asm_dovetail.jpg`, or both
   `asm_wheel_bracket_*.png`) and paste the package as the message. Note which model and plan the chat was using.
3. Answer its assumptions as you would: correct what is wrong, confirm the rest.
4. Take its final reply. If the chat app offers a **.zip** or the JSON files for download, download them; otherwise save
   each fenced block under the file name it gave, and zip the files yourself (flat, no folder).
5. In DIDSA-CAD, AI Modelling, Assembly mode: **Import plan**, pick the zip, confirm the parts, **Confirm & Generate
   All**, save each file when asked.
6. Read the progress panel: the mates note (how many were built, or why not) and the **Mate check** (each component
   fixed, fully constrained, or what it can still do). If mates failed or components are free, try **Fix mates with
   external AI**, paste its package into the same chat, bring back the `mates.json` with **Import mates** (same session
   only: do not dismiss the screen between), and note whether the file arrived usable.
7. Record for each chat app, and send back: which app and model; **file route or fenced blocks**; whether the zip
   imported and which error if not; whether `99_assembly.json` had mates at the end, named components by `local_id`
   and faces by `face_selector` (a screenshot of the progress panel is enough); whether it declared
   `intended_motion` for the wheel; the Mate check text; whether the fix round trip worked; and anything the chat
   app did to the JSON (truncation, a changed quote, an added comment, a renamed file).

What to look for first, since the app has never seen real external output: JSON the importer cannot read (the chat
app's own commentary inside a file, trailing commas, smart quotes), an assembly plan whose mates come before its
placements, `local_id`s reused or missing, a `face_selector` direction that is not one of the six axes (the server
refuses the whole mates plan with HTTP 422: the placed assembly is still saved, the note shows the server's message),
and whether the model follows the "Assembly mode" paragraphs over the "Assembly editing" ones about naming components.

## Answer keys: please confirm

Each key in `harness/expected.py` is one reading of its drawing, written while building this tool. **None has been confirmed by the drawings' author yet** (`"confirmed": False`). Until one is, "pass" means "matches that reading", and a wrong key would mark correct models wrong. The readings:

| Sketch | Reading |
|---|---|
| `zbracket` | Z section 3 thk, bends R3 inside and R6 outside; flanges 30 and 40 to the web's far face; 50 overall height; 200 long |
| `slot_bracket` | The Z-bracket plus 4× Ø5 holes, 8 from each flange's free edge and 8 from each end; R10 slot through the web, centres 150 apart, centred, 25 up |
| `flanged_bend` | Ø30 × 3 tube with an R100 centreline bend; both 400s to centrelines (horizontal from either face of the flange); flange Ø80 × 10 with a Ø24 bore and 8× Ø8 on a 60 PCD |
| `tube_3d` | Ø40 × 2 tube, legs along three axes: 250 to the first bend's centreline (R50), 200 between the first and last legs (R100), 300 from the middle leg to the end; centreline radii |
| `rect_round` | Solid, 200 long, from an 80 wide × 100 high rectangle to a Ø40 round end on the same axis |
| `notch_block` | 200 × 80 × 100 block; 40 × 40 × 50 deep notch at the top front right; R5 on the back right vertical edge only |
| `z_noheight` | No height is given anywhere: the right answer is to ask for it (scored on the first reply) |

The assembly keys are in `harness/expected_assembly.py`. The generated sheets' keys come from the models they are
drawn from; `asm_dovetail` and `asm_frame` follow the owner's reading (2026-11-03); `asm_block_pins` is still
unconfirmed.

Add a new sketch by putting the image in `sketches/` and its key in `EXPECTED`. Best of all is a part you have already modelled, so the key comes from your model rather than a reading. Prompt changes written from these sketches' failures should also be judged on sketches they were not written from.

## Results so far

Claude models, two runs per cell unless noted, scored against the unconfirmed keys above. P = pass.

| When | Change | Haiku | Sonnet | Opus |
|---|---|---|---|---|
| 2026-10-28 | Before any fixes (5 sketches) | 3/10 | 3/10 | 10/10 |
| 2026-10-28 | Merge-of-moved-bodies fix, line dimensions, two prompt gaps | 3/10 | 6/10 | 9/10 |
| 2026-10-28 | Plus joined-body ids and the `create_plane` point rule (tube and notch only, 2+2 runs) | 4/4 | 4/4 | 4/4 |
| 2026-10-29 | Plus drawing conventions and validation feedback (5 sketches, first build) | 4/10 | 9/10 | 10/10 |
| 2026-10-29 | The same runs after the render-back check and "Ask the AI to fix it" on every mismatch | 4/10 | 8/10 | 10/10 |

In the 2026-10-29 round no plan failed validation, so the automatic retry was not exercised. Sonnet now reads `rect_round` right, citing the hidden-line convention.

### Assembly mode, 2026-11-03

One run per sketch and model, added one round at a time, simplest first. Every run built (no validation failure,
no retry); a fail is the wrong geometry. Each build also renders to `assembly.png`.

| Sketch | Parts (components) | Haiku | Sonnet | Opus |
|---|---|---|---|---|
| `asm_pin_block` | 2 (2) | P | P | P |
| `asm_block_pins` (owner's sketch; key unconfirmed) | 2 (5) | P | P | P |
| `asm_wheel_bracket` (2 sheets, one part used twice) | 4 (5) | P | P | P |
| `asm_dovetail` (owner's sketch, owner's reading) | 2 (2) | parts 0/2 | base 1/2 | P |
| `asm_frame` (owner's sketch, owner's reading) | 4 (36) | parts 1/4 | parts 4/4, 8 gussets | parts 4/4, 16 gussets |
| `asm_caster` (3 sheets, nested sub-assembly) | 8 (8) | P | P | P |

- **The drawn sheets are solved.** Every model gets the generated drawings right, including the 8-part caster
  (each flattens its sub-assembly: Assembly mode can only build one level). The rough hand sketches separate
  the models: Haiku stacks the dovetail plate on an unslotted block and frames with 1200 posts that overlap the
  rails; Sonnet reads the dovetail base as a square block. The frame's gusset count ("@ every corner") is
  ambiguous: Sonnet and Opus both asked before building, then guessed 8 and 16 when told to use their judgement;
  the owner's reading is 24 (three per corner). Their members match the key exactly.
- **Lug holes (fixed).** All three `asm_wheel_bracket` runs first failed the same way: the upright (a rectangle
  with an R40 arc top and a hole at the arc's centre) came out as two solids, the hole extruded as a plug. Profile
  detection treated an Arc edge as its chord, and the hole's centre sat on that chord, so it was not seen as
  inside the outline. `app/sketch/profile.py` now samples arcs for its containment, area and centroid tests
  (`test_stage16_arc.py`).
- **Twisted lofts (fixed).** Opus's dovetail plate first failed: its foot, a loft from a 160x50 to a 150x20
  rectangle, came out twisted and 19% small. Loft auto-alignment matched the sections by equal arc-length samples,
  which drift when the outlines' proportions differ, and moved the top section's start off a corner. Two
  straight-edged outlines with as many corners are now paired corner to corner (`loft.py`,
  `test_loft_feature.py`).
- Both fixes were checked by rebuilding the same replies: no model tokens.
- **No mates.** Every assembly plan placed components with `move_component` and no `mate`. The prompt leaves no
  other way: a component added earlier in the same plan cannot take an `edge_selector`, its real face ids are not
  known when the plan is written, and Assembly mode adds every component in that one plan. Placement is right, but
  nothing constrains it. Open: resolve selectors on a same-plan `add_component` once it has run, or send a second
  assembly turn listing the placed components' real ids.
- Cost: about 80-110k tokens per run (Haiku the most), most of it reading the system prompt once; part and
  assembly turns add little.

### Assembly mode with mates and stated assumptions, 2026-11-04

After the mates turn, `face_selector` and stated assumptions (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`,
"Mates turn and stated assumptions"). The owner's three hand sketches, one run per model. The harness played the
owner: it corrected only the assumptions a model stated that contradict the owner's reading, and confirmed the rest.

| Sketch | Haiku | Sonnet | Opus |
|---|---|---|---|
| `asm_block_pins` | P, 8 mates | P, 8 mates | P, 8 mates |
| `asm_dovetail` | plate wrong (stem 25 too tall), 1 mate | P, 1 mate | P, 1 mate (no correction needed) |
| `asm_frame` (36 components) | rails wrong, 14 mates | P, 72 mates | P, 96 mates |

7 of 9, against 1 of 9 on the same sketches before (the 2026-11-03 table, re-scored with the corrected pin key).

- **Stated assumptions caught the misreadings.** Every model that had misread a sketch before now listed that reading
  as an assumption: the pin shank "read as 30" (Sonnet, Opus), the dovetail base read as a plain block or the
  wrong height (Haiku, Sonnet), the gusset count (all three), Haiku's 1200 posts. One correction each and the
  revised manifest built right. Opus read the dovetail exactly as the owner did, with no correction.
- **Mates.** Every run now mates its parts, and in every passing run the mates hold the parts where they were
  placed (a wrong mate moves a part and fails the score). Pins get a concentric and a shoulder mate each; the
  frames seat posts and gussets.
- **Found and fixed while running** (each rebuilt from the same replies, no model tokens):
  - Flat faces made by a Revolve read as facing +z (their plane axis has no fixed sign), so a selector could not
    find a revolved pin's shoulder and the solver could not seat it. The sign now comes from the face's surface
    derivatives (`face_normal.py`), in the selectors, the mate solver, Move Face and sketch-on-face planes.
  - A mate whose second side is the grounded first component failed (`occurrence_is_fixed`): the translator now
    solves the other side.
  - The mates listing gave every body-producing Feature as a body id, and the models guessed which was "the" Body;
    it now lists components only, and a one-Body component's Body is found by the selector.
  - A selector could only name the six axis directions, so sloped faces (dovetail flanks, mitres) could not be
    mated: `face_selector.normal` names any planar face. These batch-1 runs predate it, which is why the dovetails
    have only a seat mate.
- Haiku still misreads the rough sketches after correction (dovetail stem, frame rails); Sonnet and Opus do not.

### Assembly mode with mates, the generated sheets, 2026-11-04

The same build as above plus `face_selector.normal`, Closest mate branches and the components-only mates listing.
One run per model; every model's assumptions on these fully dimensioned sheets were right and confirmed unchanged.

| Sketch | Haiku | Sonnet | Opus |
|---|---|---|---|
| `asm_pin_block` | P, 2 mates | P, 2 mates | P, 2 mates |
| `asm_wheel_bracket` | P, 7 mates | P, 7 mates | P, 11 mates |
| `asm_caster` (8 parts) | fork wrong | P, 14 mates | P, 14 mates |

Across both 2026-11-04 tables Sonnet and Opus pass all 12 runs, with mates that hold every part where it was
placed; Haiku fails 3 of 6, each on a part it built wrong. Opus's wheel bracket first failed: its flush mates
(upright side level with the plate edge, faces pointing the same way) were created with the deprecated
`flipped: false`, read as anti-aligned, and turned the uprights over. Plan mates now take the branch nearest the
current pose; the same reply passes, and every other run rebuilds the same. Haiku's caster fork came out as three
Bodies, so its mates needed `body_id`s (the dry run named them); the run was stopped there.

**Where this leaves the evaluation.** The owner dropped Haiku after these runs. Not done (token cost): a second
run per sketch and model, so the 2026-11-04 tables are one run each - read them as direction, not rates.

Since then (`docs/ai-modelling/16-assembly-mates-gaps-plan.md`, built; model rounds not run):
- An imported zip now carries its own mates (the hand-off asks for them at the end of `99_assembly.json`) and the app
  builds them after the placements; a completeness check shows what each component can still do; `eval.sh handoff` and
  `import` play that route; the `constrained` column scores completeness (see "External route").
- **Not done, and why:** (1) *Most model rounds.* Only the Sonnet external route on three sketches was run (see the
  table above, about 0.6M tokens). Not run: Opus, the three hand sketches, a second in-app run of the same six
  (together about 2M more tokens), which wait for the owner's go-ahead. (2) *Re-scoring the 2026-11-04 in-app runs for completeness: not possible from this repository.*
  `runs/` is git-ignored and was not kept, so the saved replies are not available to rebuild. The harness can do it as
  soon as they are: copy each run folder back under `runs/`, run `eval.sh assemble <run>` (it rebuilds from the saved
  `*_reply.txt` files with no model call and now writes `completeness.json`, `completeness.txt` and the `constrained`
  field), then `eval.sh table`. Note it measures the first mates turn only, as before the app's follow-up. (3) *A real
  external chat* is the owner's step: see "A real external chat: the owner's checklist". Until it is done the external
  route is tested only by unit and widget tests, one hand-written zip through the harness (see the self-test above),
  and a model standing in for the chat app once rounds are run.
- Still open in the app: the zip importer's repair of a moved first component (finding 3 in `15-...md`); rebuilding the
  `local_id` map for an imported assembly reopened in a later session.

### External route, Sonnet, 2026-11-04 (first model rounds of the external route)

Sonnet standing in for an external chat app (`agent_prompts/model_external.md`, the hand-off package as a pasted message),
two runs per sketch, three sketches chosen to save tokens: easy (`asm_pin_block`, 2 parts), medium (`asm_wheel_bracket`,
4 parts, one used twice) and most complex (`asm_caster`, 8 parts). Every run took the file route (a zip's JSON files);
the fenced-block route was not exercised. About 0.6M tokens in all (85-120k a run). The scripted owner only said "go
with your best reading": these are the fully dimensioned generated sheets, whose assumptions need no correction.

| Sketch | Run 1 | Run 2 |
|---|---|---|
| `asm_pin_block` | P, 2 mates, constrained 2/2 | P, 2 mates, constrained 2/2 |
| `asm_wheel_bracket` | P, 11 mates, constrained 5/5 | P, 10 mates, constrained 5/5 |
| `asm_caster` | P, 18 mates, constrained 4/8 | P, 17 mates, constrained 4/8 |

- **Placement and import: 6 of 6.** Every zip was read by the importer, every part built first time (no validation
  failure, no retry), every mates plan built (no `face_selector` or local-id error), and every assembly passed the
  placement score. Mates named components by their `add_component` `local_id`, as the external paragraphs ask.
- **Completeness: matches on the easy and medium sketches, not on the caster.** Both caster runs locked the swivel:
  the fork came out `fully constrained` where the key expects `spin` about the kingpin. That one choice cascades: the
  wheel is then free only about its own axle (`spin`, key `2spin`), and the bolt and nut are held (`held`, key
  `spin|2spin`), so the 4 `over` verdicts are one decision counted four times. Both runs left the wheel, bushing, washer
  and kingpin free and declared them in `intended_motion`; the swivel itself was never declared or left free. Whether
  a locked swivel is a modelling error or a fair reading of the drawing is for the owner (and the key is my unconfirmed
  reading, see above).
- Every run declared `intended_motion` for its wheel as asked, and also for round pins and axles ("nothing stops it
  turning"), which the key allows.
- **Read as direction, not rates**: two runs per cell, a model standing in for a chat app, no run against claude.ai,
  ChatGPT or Gemini. Each sub-agent also ran one `mkdir` through a shell tool despite being told to use file tools only
  (it changed no file content). The app's one follow-up turn was not played, so a locked swivel is what the first
  mates turn left, before any follow-up. Not run: Opus, the hand sketches (`asm_dovetail`, `asm_frame`, `asm_block_pins`),
  the in-app second runs.

### Render-back check, 2026-10-29

Each build was checked by the same model that built it (`docs/ai-modelling/14-render-back-check.md`), and every mismatch was sent back as the fix turn.

| Outcome | Haiku | Sonnet | Opus |
|---|---|---|---|
| Catch (wrong part flagged) | 4 | 1 | 0 |
| Miss (wrong part passed) | 2 | 0 | 0 |
| False alarm (right part flagged) | 1 | 2 | 0 |
| OK (right part passed) | 3 | 7 | 10 |

What the fix turn did:
- **Catches, 5:** one became right (Sonnet `tube_3d` r1: its 300 was to the centreline, as the check said). Haiku's four got closer but still fail: `slot_bracket` gained its R3/R6 bends and lost the stray pins, and `rect_round` stayed a revolve with a bore because Haiku still reads the Ø40 as a hole.
- **False alarms, 3:** Haiku `tube_3d` r1 said its model was right and kept it (still right). Both Sonnet `flanged_bend` runs accepted a wrong reading of the 400s and broke a correct part.
- **Misses, 2:** Haiku `flanged_bend` r2 and `tube_3d` r2 have the same centreline error the Sonnet check caught; a Haiku check reads the drawing the way Haiku's build did.

So a check by the model that built the part mostly repeats its reading of the drawing, and a model that does not trust its own reading gives in to a wrong critique. The fix stays a button the user chooses, not automatic.
