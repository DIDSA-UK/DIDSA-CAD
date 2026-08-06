# Workstream 4: Translator + Execution

Read `00-conventions.md` first. Depends on workstreams 1, 2, 3, and 5 (the
dry-run validation call is part of this workstream's own "Generate" flow).

**Built and tested (this session)**: `client/lib/ai/ai_plan_translator.dart`
(`PlanTranslator`), wired into `AiModellingScreen._generate()`, tested in
`client/test/ai_plan_translator_test.dart` (fixture plans, no LLM
involved) and `client/test/ai_modelling_screen_test.dart` (the screen
wiring). The rest of this file describes what was actually built, not a
forward-looking spec anymore — corrected in three places below where real
implementation found the original spec wrong.

## `PlanTranslator`

Client-side (Dart), takes a validated `AiGenerationPlan` (workstream 3)
and a real `partId`. Walks `plan.steps` **in order**, maintaining a
`Map<String, String> localIdToRealId` it populates as each step succeeds.

For each step, calls the *exact same* `DocumentApiClient`/
`SketchApiClient` methods a human-driven screen would call —
`createSketchFeature`, `createPoint`/`createLine`/`createRectangle`/etc.,
`createExtrudeFeature`, `createFilletFeature`, and so on — substituting
real ids resolved from `localIdToRealId` wherever the plan step referenced
an earlier `local_id`. This is deliberately not a new code path into the
backend; it's the same API surface, called programmatically instead of
from button presses.

**Correction 1 — Part creation stays with `AiModellingScreen`, not
`PlanTranslator`.** The original wording above ("takes ... the currently-
open Part, or creates one via `createPart` first if none is open") was
generic boilerplate copied from the Gear Design entry screens' own
convention, and doesn't fit this app's actual, already-shipped
`AiModellingScreen._generate()` — which already creates a fresh Part to
run workstream 5's dry-run validation against (`00-conventions.md`'s "v1
always starts a fresh Part"), *before* this workstream existed to execute
anything. `PlanTranslator.execute` therefore takes `partId` as a required
parameter and never calls `createPart` itself — its whole reason to exist
is to let `_generate()` **reuse that same Part id** for real execution
rather than creating a second, orphaned one (the exact gap
`_generate()`'s own doc comment used to name before this workstream was
built).

**Correction 2 — sketch-entity steps that compute a derived point
(`sketch_line.length`+`angle`, `sketch_circle.radius`+`angle`,
`sketch_arc.end_angle`, `sketch_ellipse.major_radius`+`angle`) are
resolved client-side, not via a wire-level "length/angle" create call.**
`SketchApiClient` has no such call at all — every existing screen always
ends up with two explicit Points (a human always taps/computes a real
coordinate), so no wrapper method for the backend's own length/angle
creation mode was ever built. Rather than add new, never-otherwise-used
API surface, the translator computes the derived point's coordinates
itself (`center/start + radius/length * (cos, sin)`, converting the
plan's degrees to radians once, at this one point — see Correction 3),
using the plan's own literal `sketch_point` step coordinates (never a
network round-trip to look them up), then calls `createPoint` followed by
the ordinary explicit-point-id create call. Produces identical geometry
to the backend's own internal computation (same formula), and stays
truer to "the exact same calls a human-driven screen would make" than a
new wire mode nothing else in this app uses.

**Correction 3 — a real, separate bug found and fixed while implementing
this**: `00-conventions.md` promises "degrees for every angle", but
`ai_plan.py`'s dry-run validator was passing `SketchLineStep.angle`/etc.
straight through to the real Sketch API, which is **radians** by its own
docstrings. `RevolveStep.angle`/`PatternStep.angle_total` really are
degrees (the real Document/Feature API's own convention); only the
Sketch-entity-level fields were wrong. Fixed server-side
(`math.radians()` conversion in `ai_plan.py`, `SubShapeRefSchema`'s
`resolved_edges` reused it for `resolved_edges`' own index-reuse
guarantee) and mirrored client-side (Correction 2's own conversion) - see
`05-backend-plan-validation.md`'s "Real finding from workstream 4"
section for the full writeup, and the regression tests each side gained.
A second, independent bug in the same area: `PatternAxisStep` used to
also accept `fixed_axis` (copied from `PatternDirectionStep`'s shape
without checking `PatternAxisRef`, the real type it mirrors, has no such
field) - would have crashed with an unhandled `TypeError` the moment a
plan actually used it. Fixed by removing the option entirely (see
`03-structured-plan-schema.md`'s own corresponding note) - `axis` must
always be a `sketch_line_ref`.

**Correction 4 — `gear_request` is detected, not executed; the "hand off
to the existing Gear Design screens" half of this workstream's original
scope was deliberately not built.** Confirmed by direct check while
implementing this: `GearDesignScreen`/`GearChainDesignScreen`/
`BevelDesignScreen` have no "target an existing Part" concept at all -
each unconditionally calls `createPart` itself
(`GearDesignScreen._create`, and its siblings' own equivalents) and
navigates into `PartScreen` on success. Making a `gear_request` step's
hand-off land in the *same* Part this translator is building would mean
reworking three already-shipped, tested screens' creation/navigation flow
- real, separate scope this session deliberately didn't take on alongside
the translator engine itself (see "Real scope of `gear_request`
handling" below for what was built instead). A real, deliberate v1 gap,
not an oversight - flagged here the same way this doc set flags every
other deliberate scope narrowing.

**New, not in the original spec at all — Fillet/Chamfer's `resolved_edges`
dependency.** The translator has no client-side way to resolve an
`EdgeSelector` into real Body edges at all (the heuristics in
`app.document.ai_plan_edges` need real OCCT topology, never available
client-side) - the original spec didn't address this gap. Fixed by
extending workstream 5's `StepResult` with a `resolved_edges` field (see
`05-backend-plan-validation.md`), which the translator's own pre-flight
call (below) already fetches for free and reuses directly when it later
executes a `fillet`/`chamfer` step for real.

## Pre-flight

Before executing step 1 for real, the translator calls workstream 5's
dry-run validation endpoint with the whole plan, unmodified (`05`'s own
correction: the request body is the plan as-is, not pre-translated into
real create-endpoint shapes — the endpoint does its own local_id
resolution internally). On any `ok: false` entry, execution never starts
— nothing is created. **Refinement over the original spec**: this state
stays in the Review & Generate panel (workstream 2), showing the same
per-step ok/error list the pre-workstream-4 validate-only "Generate" used
to show, with "Adjust" still available to drop back into chat — not
pushed into the chat transcript as its own turn the way a *real* step
failure is (below). Keeps the structural, easy-to-scan per-step report
visible without an extra mechanism duplicating what the panel already
does well; a real failure needs the chat push because by that point
there's also new, unstructured information (the real backend's own error
text, and which Features actually got created) worth feeding back to the
LLM as context for a revision.

## Real execution and failure handling

Steps execute sequentially against the real backend. **On any step's real
HTTP failure** (a genuine geometry error the dry run's simplified checks
didn't catch — e.g. a numeric edge case in a fillet radius vs. available
material):

1. Execution stops immediately. No further steps run.
2. Every Feature already created up to that point **stays in place** — no
   automatic rollback (`00-conventions.md`'s own explicit reasoning for
   this call).
3. The real error text is appended to the chat transcript as a new turn
   ("Execution stopped at step 3. Extrude 0→10mm (boss):
   `<real backend error>`. Every step before this one was created
   successfully..."), and the panel drops back into chat mode - the next
   message the user sends resends this as context automatically (the same
   "next message replays the full transcript" mechanism `02`'s own
   "Adjust" already relies on, so no extra bookkeeping was needed). Sent
   as a `user`-role turn, not `assistant` - it's real information being
   fed *to* the LLM, not something it said. The user can either type a
   follow-up asking for a revised plan covering the remaining steps, or
   leave the conversation there and clean up/finish manually - including
   via the "Undo this generation" bolt-on below, still offered from chat
   mode (not just the Review & Generate panel), since this app has no
   general Feature-tree Undo to fall back on otherwise.
4. A `gear_request` step reached mid-plan (Correction 4 above) stops the
   same way, with its own explanation text instead of a backend error -
   see `ai_plan_translator.dart`'s own top-level doc comment.

## Real scope of `gear_request` handling

Per Correction 4 above, the full "hand off to the existing Gear Design
screens, pre-filled, targeting this same Part" scope wasn't built this
session - would need `GearDesignScreen`/`GearChainDesignScreen`/
`BevelDesignScreen` reworked to accept an existing Part id in the first
place, real separate scope. What *was* built: `PlanTranslator` detects a
`gear_request` step and stops cleanly at it (same "leave everything
already created in place, no rollback" shape as a real failure), and
`AiModellingScreen` surfaces a clear, honest message explaining the gear
step can't be created automatically yet and suggesting the user either
use the Gear Design tool separately or ask the LLM for a revised plan
without it - never a broken or wrong-Part hand-off. A real, deliberate v1
gap; the natural next-session pickup if this needs closing later.

## Bolt-on: "Undo this generation"

This app has no Feature-tree-level Undo mechanism at all (confirmed by
direct check — only per-interaction undo elsewhere, e.g. a sweep-path
pick, plus manual delete/cascade-delete). Since `PlanTranslator` already
tracks every real Feature id it created, in creation order — exposing one
button that deletes them **in reverse order** is nearly free given that
tracking already exists for translation purposes. Uses the **cascade**
delete endpoint specifically, not the plain single-Feature one - confirmed
during implementation that plain delete (`Part.delete_feature`) only pops
the Part's Feature list and never cleans up a deleted SketchFeature's own
Sketch, which would otherwise leak an orphaned Sketch on every undo of a
Feature sequence that included one. Safe to use per-Feature despite cascade
delete's own "also deletes transitive dependents" behavior: reverse
creation order guarantees nothing depending on a given Feature still
exists by the time its turn comes, so each call's own cascade is always
empty beyond that Feature (and its owned Sketch) itself. Offered after
any generation run (full success, partial success after a stopped
failure or a `gear_request` stop, or a run the user simply changes their
mind about) — from the Review & Generate panel on success, and
persistently from chat mode too once the panel switches back after a
stopped run — the only clean way to back out a whole AI-generated
sequence in this app.

## Progress UI

Each step in the Review & Generate panel (workstream 2) transitions
pending → in-progress → done/failed as the translator works through the
list — mirrors this app's existing eager-feature-preview convention
(`docs/roadmap.md`'s own "eager feature preview" line item) rather than a
single opaque spinner for the whole plan.

## Why this loop is LLM-call-free (and why that matters)

Once a plan is approved, executing it involves zero further LLM calls —
every step is a deterministic translation from plan data to an existing
API call. This was a deliberate design constraint carried from the
structured-plan-vs-tool-calling decision (`README.md`'s key decisions):
predictable, boundable, and cheap to retry the *dry-run* pass repeatedly
without burning provider calls. It's also why workstream 3's edge-
selection problem recommends option (b) (deterministic selectors) over
option (a) (a mid-execution LLM call) — (a) would be the one place this
property breaks.
