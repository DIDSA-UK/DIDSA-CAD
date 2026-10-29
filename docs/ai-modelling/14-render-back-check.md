# Workstream 14: Checking the result against the drawing

Read `00-conventions.md` first. Depends on 4 (translator), 5 (dry run) and 10 (image input).

**Built.** It came out of testing AI Modelling with hand sketches (`tools/ai_eval/`). Hand sketches went through the real prompt, translator and a local backend, and the built parts were scored against each drawing. Most failures were one of three kinds. This workstream adds one fix for each.

| Failure seen | Fix |
|---|---|
| A plan failed the dry run, and nothing told the model why. Single-part mode added nothing to the chat, and Assembly mode said only "please propose a revised plan". | Validation feedback plus one automatic retry |
| The model misread the drawing: dimensions to the wrong reference point, a round end read as a hole, a missing size not looked for in the other views. | Drafting conventions in the prompt |
| A plan built cleanly but was the wrong shape, and nothing checked. | Render-back check |

## 1. Validation feedback and automatic retry

`describeAiPlanValidationFailure` (`client/lib/ai/ai_validation_feedback.dart`) turns the dry run's per-step results into a `user` turn:
- It lists each step that failed in its own right, with its kind and the error's message or details.
- It only counts the steps that failed because they depend on one of those.

In single-part generation (`_generate`), a validation failure sends that turn and asks for a corrected plan straight away. It does this once (`aiAutoRetriesOnValidationFailure`), then builds the reply's plan as usual. If the corrected plan also fails, the turn is left in the chat, so a user who replies "try again" sends the errors along.

Assembly mode does the same once per part cycle and once for the assembly cycle (`_autoRetriedValidation`). Its old message carried no errors at all.

Cost: at most one extra provider turn, only after a validation failure.

## 2. Drafting conventions

`_drawingConventions` is a new locked block in the system prompt (`ai_scoping_prompt.dart`). It covers:
- 3rd and 1st angle view layout;
- what hidden lines mean, including that a circle with no hidden lines elsewhere is an outer edge, not a hole;
- tube dimensions to centrelines;
- sheet-metal dimensions to outside faces, with inside versus outside bend radius;
- TYP, =X=, PCD, THK, Ø and R;
- written dimensions over sketch proportions;
- checking every view before calling a size missing.

The image-analysis prompt (`aiImageExtractionPrompt`) now asks for three things:
- for each dimension, which view it is in and which edges it runs between;
- the projection layout;
- a check of every view before saying a size is missing.

These were written from the failures seen on the test sketches. Judge them on new sketches as well, so the prompt is not just fitted to the test set (see `tools/ai_eval/README.md`).

## 3. Render-back check

After a successful build of a **fresh** Part from **attached drawing(s)**, with a **vision-capable** provider:

1. `GET /document/parts/{id}/drawing.png` (`backend/app/document/line_drawing.py`) draws the Part as a 3rd angle line drawing. Front view bottom left, top view above it, right view to its right, isometric top right. It uses OCCT's hidden-line removal on the exact B-rep, with hidden edges dashed.
   - It needs no GL context and no new dependency: the PNG is written with `zlib`.
   - The header `X-Bounding-Box` gives the overall size in mm, since the drawing has no dimensions.
   - It is drawn like a drawing, not shaded like a viewport, so the model compares like with like.
2. `runAiModelCheck` (`client/lib/ai/ai_model_check.dart`) sends the user's images, then that drawing, with a fixed prompt through the new `AiProvider.askAboutImages`. That is a one-shot vision call outside the transcript; `extractImageDescription` now uses it too.
   - The model must answer `MATCH` or `MISMATCH` with a list of differences.
   - Orientation does not count as a difference.
3. The panel shows the verdict. On a mismatch, or a reply that is neither, **Ask the AI to fix it** sends the differences as a `user` turn and asks for a complete corrected plan. That plan waits for the user's own Generate, which rebuilds a fresh Part.

The check is skipped for existing-Part editing ("Continue with AI"). There, a fix would mean patching a Part the user may have changed by hand.

The check costs one extra vision call per such build. A failed check, from the drawing endpoint or the provider, is shown as one line and never undoes or blocks the build.

### Not covered

- The check is advisory: the model can be wrong in either direction, so the fix is a button, not automatic. On the evaluation sketches (2026-10-29), the same model that built the part caught 5 of 7 wrong parts, but raised 3 false alarms on 23 right ones. Two of those false alarms led Sonnet to break a correct part when asked to fix it (`tools/ai_eval/README.md`).
- Multi-part and Assembly mode builds are not checked.
- Handedness: a mirrored part is the same as a rotated one only for symmetric prisms, so the prompt does not excuse mirroring. Whether models flag it correctly has not been measured.

## Tests

- `backend/tests/test_line_drawing.py`
- `client/test/ai_model_check_test.dart`
- `client/test/ai_validation_feedback_test.dart`
- the retry cases in `client/test/ai_modelling_screen_test.dart` and `client/test/ai_modelling_screen_orchestration_test.dart`

The before and after numbers on the sketch set are in `tools/ai_eval/README.md`.
