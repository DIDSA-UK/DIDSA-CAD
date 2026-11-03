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
| `harness/expected_assembly.py`, `harness/assembly_keys.json` | The same for the assembly sketches. |
| `harness/ai_eval_harness_test.dart` | The app-code side, run through `eval.sh`. |
| `harness/inspect_step.py` | Geometry report for a STEP file: volume, bounding box, faces, cylinder radii. |
| `harness/table.py` | Pass table, plus how the render-back check's verdicts compare with the scores. |
| `agent_prompts/` | Instructions for the model standing in for the provider. `model.md` covers the image analysis and the chat; `check.md` covers the render-back check; `model_assembly.md` is `model.md` for Assembly mode. |
| `eval.sh` | `prompts`, `build`, `verdict` and `table`; for assemblies `prompts-assembly`, `manifest` and `assemble`. |
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

One run per sketch and model; sketches added one round at a time, simplest first.

| Sketch | Parts (components) | Haiku | Sonnet | Opus |
|---|---|---|---|---|
| `asm_pin_block` | 2 (2) | P | P | P |
| `asm_block_pins` (owner's sketch, key unconfirmed) | 2 (5) | P | P | P |
| `asm_wheel_bracket` (2 sheets, one part used twice) | 4 (5) | P | P | P |

Every model named the parts right first time, asked no questions and needed no retries.

- **Lug holes (fixed).** All three `asm_wheel_bracket` runs first failed the same way: the upright (a rectangle
  with an R40 arc top and a hole at the arc's centre) came out as two solids, the hole extruded as a plug. Profile
  detection treated an Arc edge as its chord, and the hole's centre sat on that chord, so it was not seen as
  inside the outline. `app/sketch/profile.py` now samples arcs for its containment, area and centroid tests
  (`test_stage16_arc.py`). The same replies rebuilt after the fix all pass.
- **No mates.** Every assembly plan placed components with `move_component` and no `mate`. The prompt leaves no
  other way: a component added earlier in the same plan cannot take an `edge_selector`, and its real face ids are
  not known when the plan is written, and Assembly mode always adds every component in that one plan. Placement
  is right, but nothing constrains it. Open: resolve selectors on a same-plan `add_component` once it has run, or
  send a second assembly turn listing the placed components' real ids.
- Haiku twice tried to call a messaging tool the harness had not offered it (refused; nothing sent). Not an app
  issue.

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
