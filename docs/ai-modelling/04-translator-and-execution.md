# Workstream 4: Translator + Execution

Read `00-conventions.md` first. Depends on workstreams 1, 2, 3, and 5 (the
dry-run validation call is part of this workstream's own "Generate" flow).

## `PlanTranslator`

Client-side (Dart), takes a validated `AiGenerationPlan` (workstream 3)
and the currently-open Part (or creates one via `createPart` first if none
is open — matches the Gear Design entry screens' own lazy-Part-creation
convention). Walks `plan.steps` **in order**, maintaining a
`Map<String, String> localIdToRealId` it populates as each step succeeds.

For each step, calls the *exact same* `DocumentApiClient`/
`SketchApiClient` methods a human-driven screen would call —
`createSketchFeature`, `createLine`/`createCircle`/`createRectangle`/etc.,
`createExtrudeFeature`, `createFilletFeature`, and so on — substituting
real ids resolved from `localIdToRealId` wherever the plan step referenced
an earlier `local_id`. This is deliberately not a new code path into the
backend; it's the same API surface, called programmatically instead of
from button presses.

`gear_request` steps are intercepted **before** normal execution (per
`03`'s routing note) — the translator hands the parsed parameters to the
existing `GearDesignScreen`/`GearChainDesignScreen`/`BevelDesignScreen`
pre-filled, rather than looping them through `localIdToRealId` at all.

## Pre-flight

Before executing step 1 for real, the translator calls workstream 5's
dry-run validation endpoint with the whole plan (translated into the same
request shapes the real create endpoints accept, minus any that need a
real prior step's id — the endpoint itself resolves that layer, see `05`).
On any `ok: false` entry, execution never starts; the errors are surfaced
back into the chat (workstream 2) as a new assistant-directed turn asking
for a revision, exactly like a real-execution failure would be (below) —
same user-facing shape either way, just before vs. after anything real
touched the Part.

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
   ("Step 4 (Fillet, 5mm on 4 edges) failed: `<real backend error>`"),
   and the user can either send it back to the LLM for a revised plan
   covering the remaining steps, or clean up/finish manually with this
   app's ordinary Undo/delete-Feature tools.

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
