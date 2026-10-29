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
| `sketches/` | The test drawings, downscaled to 1568 px on the long edge as the app does. |
| `harness/expected.py` | The answer key for each sketch, and the scorer. |
| `harness/ai_eval_harness_test.dart` | The app-code side, run through `eval.sh`. |
| `harness/inspect_step.py` | Geometry report for a STEP file: volume, bounding box, faces, cylinder radii. |
| `harness/table.py` | Pass table, plus how the render-back check's verdicts compare with the scores. |
| `agent_prompts/` | Instructions for the model standing in for the provider. `model.md` covers the image analysis and the chat; `check.md` covers the render-back check. |
| `eval.sh` | `prompts`, `build`, `verdict` and `table`. |
| `runs/`, `prompts/` | Output (git-ignored). |

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

The latest round, with validation feedback, drafting conventions and the render-back check (`docs/ai-modelling/14-render-back-check.md`), is recorded in that doc once run.
