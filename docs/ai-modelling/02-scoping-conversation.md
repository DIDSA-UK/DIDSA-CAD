# Workstream 2: Scoping Conversation

Read `00-conventions.md` first. Depends on workstream 1 (needs an
`AiProvider` to talk to).

## `AiModellingScreen`

Reached from `ToolChooserScreen`'s new "AI Modelling" tile
(`00-conventions.md`'s Entry point section). An inline chat panel —
message list (user/assistant turns) + text input + send button — the
decided UX (see `README.md`'s key decisions: chat panel, not an
LLM-proposed structured form).

Conversation state (`List<AiChatMessage>`) lives entirely in this screen's
Dart state, never persisted server-side anywhere — the whole transcript is
resent on every `sendScopingTurn` call (workstream 1), the same "client
holds the authoritative state, server call is a pure function of what's
sent" shape the Document API itself already uses for Part state, just
applied to a conversation instead of a Feature tree.

## System prompt

Sent as the first message (or the `system` field, for providers that have
one — `AnthropicProvider` maps it there; `OpenAiCompatibleProvider` sends
it as a `system`-role message). Five components, all static/hand-written
for v1 (not derived from any live schema — see the maintenance note at
the end):

1. **Role/premise.** A short framing: "You are a CAD modelling assistant
   for DIDSA-CAD, a parametric 3D CAD tool. Your job is to have a short
   conversation with the user to fully specify a mechanical part, then
   respond with exactly one JSON plan matching the schema below — nothing
   else in that final message." Also states the fresh-Part framing
   plainly (`00-conventions.md`): this always builds a new part, never
   modifies one that already exists.
2. **The exact allowed vocabulary** — a compact, machine-readable
   reference for every `kind` workstream 3's schema supports (Sketch
   entities, Features): name, fields, units, valid enum values. This is
   the model's *only* source of truth for what it can generate — the
   model should be told explicitly what it **can't** (Spline, Text, Loft,
   assemblies, etc.) so a request that needs one of those gets a
   clarifying pushback ("I can approximate this with a Rectangle +
   Fillets, would that work?") rather than a plan referencing a step kind
   the translator doesn't understand.
3. **Units convention**: mm for every length/distance field, degrees for
   every angle — stated explicitly rather than left implicit, since the
   plan schema's numeric fields carry no unit type of their own (matching
   how the underlying Feature API itself has no unit field either).
4. **1-2 worked few-shot examples** — a short example conversation and
   its resulting plan, embedded directly in the prompt. Expected to do
   more for reliable structured output than the instructions above alone,
   especially on weaker local models — this is the first thing to tune
   based on workstream 1's own structured-output reliability spike
   findings (`README.md`).
5. **Ask before generating, gear intent, termination shape**: keep asking
   clarifying questions (missing dimensions, ambiguous features,
   tolerances) until confident — mirrors this very scoping session's own
   working style, the explicit precedent named in the original ask.
   Prefer the gear-routing step kind over a generic Feature sequence when
   the request is gear/rack-shaped. Once ready, respond with *only* the
   plan, fenced/embedded so workstream 1's plan-detection fallback can
   reliably extract it regardless of whether the active provider's
   structured-output support is confirmed.

**Maintenance note**: the vocabulary reference (component 2) is a
hand-maintained copy of workstream 3's real schema, not generated from it
— if a future session adds a field to an existing step `kind`, this
prompt needs a matching manual update or the LLM won't know the field
exists. Worth a code comment pointing back here wherever workstream 3's
schema types are defined, so the two don't silently drift.

## Plan-review handoff

**Correction (workstream 2 implementation)**: not "once `AiTurnResult.
plan` is non-null" as originally written here — see `01-provider-
abstraction.md`'s own correction: no provider implementation ever
populates that field. The real trigger is the plan-detection fallback
(`detectPlanInAssistantText`) finding a valid plan in the *current* turn's
`assistantText`, run by this screen directly after every `sendScopingTurn`
call. Once that happens, the panel switches from "still chatting" to a
**Review & Generate** state:

- A human-readable summary of the plan's steps (e.g. "1. New Sketch on
  XY  2. Rectangle 60×40mm  3. Extrude 10mm  4. Fillet 4 edges @5mm" —
  derived from the plan data, not raw JSON shown to the user). **Real
  implementation note**: producing this line-for-a-composite-entity shape
  needs real reference resolution, not a per-`kind` template applied in
  isolation — a `sketch_rectangle` step's own fields carry no width/height
  at all (`03-structured-plan-schema.md`'s locked shape only gives it 4
  `corner_point_ids`), so the summary has to look up those `sketch_point`
  steps by `local_id` and compute a bounding box to show a literal
  dimension. `sketch_circle`/`sketch_arc` do the same for a
  `radius_point_id`-only radius. `client/lib/ai/ai_plan_summary.dart`'s
  `summarizeAiPlan` implements this — worth reusing (or at least
  cross-checking against) rather than re-deriving independently once
  workstream 4's translator needs comparable reference resolution for its
  own real execution.
- **Generate** button — runs workstream 5's dry-run validation, then (on
  success) workstream 4's real translator. **Real implementation note**:
  since validation needs a real, currently-stored Part id to validate
  against (workstream 5's endpoint calls `get_part_or_404`), and workstream
  4 doesn't exist yet, this session's "Generate" already does the
  `createPart` half of `00-conventions.md`'s "v1 always starts a fresh
  Part" up front, then validates against that Part, then stops (an
  explicit "ready to generate once Part generation lands" state, not a
  fake success). **Consequence worth knowing before workstream 4 lands**:
  every workstream-2-only "Generate" press leaves a real, permanently-empty
  orphan Part behind in the backend's in-memory store (nothing ever
  populates it, and this app has no "delete an unwanted Part" affordance
  at all yet) — a real, load-bearing side effect of validating before
  execution exists, not a bug in this session's own scope, but worth
  workstream 4 either reusing that same Part id (rather than creating a
  second one) or this whole flow being revisited once real execution
  lands.
- **Adjust** — drops back into chat mode; the next user message is sent
  with the full transcript *plus* the just-proposed plan included as
  context, so the LLM revises rather than starting over. **Real
  implementation note**: this needs no special handling at all — the
  assistant turn the plan was detected in is already part of the
  transcript (it's literally that turn's own raw text) and simply stays
  there when returning to chat mode, so the next `sendScopingTurn` call
  resends it automatically.

## Bolt-on: save plan as preset

Reuses `GearPresetStore`'s exact mechanism (client-local,
`shared_preferences`, one `GearPreset.kind` discriminator string per
screen type) rather than building a new store — add a new kind (e.g.
`'ai_modelling_plan'`) whose `fields` map holds the finished plan JSON
(and optionally the transcript that produced it). Available once a plan
has been proposed (the Review & Generate state above): "Save as preset"
alongside "Generate"/"Adjust," and a "Load preset" entry point when
starting a fresh conversation, pre-populating the Review & Generate state
directly without needing to re-run the scoping conversation at all. Same
"convenience for re-populating, not a live link" framing
`GearPreset`'s own doc comment already establishes — loading a preset and
generating produces an ordinary, independent Feature sequence with no
ongoing relationship to the preset it came from.

## Scope note

No image handling in this workstream — text input only. Workstream 6
extends `AiChatMessage` and this screen's input row once it becomes the
active workstream; nothing here should be built in a way that blocks that
extension (e.g. don't hardcode the input row to text-only in a way that's
awkward to add an attach-image affordance to later), but don't build any
image UI now either.

## Real end-to-end exercise (2026-08-06): four UX gaps found — all fixed (2026-08-07)

With workstreams 1-4 all built, ran a genuine first-time-user trace — a
real Gemini call using the real, locked system prompt
(`ai_scoping_prompt.dart`), the exact request "100mm square plate 10mm
thick with a 20mm hole in the middle and 1mm chamfered edges," then the
resulting plan replayed against a real backend (real Sketch/Extrude/
Chamfer, real OCCT). **The generation pipeline itself produced correct
geometry** (one real body, correct bounding box, hole genuinely cut
through, chamfer correctly covering both the outer and hole edges on the
one annular top face) — no functional bug in the translator/validator.
The gaps are all in what the user sees and is guided toward. Four found,
agreed fixes below — **all implemented and tested on 2026-08-07** (this
session picked them up); each item is annotated with what actually
shipped, since one diverged slightly from the plan below once written.

1. **No provider-configured guard.** `AiModellingScreen` never checks
   whether `AiProviderPreferences.active` is actually usable before
   accepting input — a genuine first-time user (default `local` slot,
   empty `baseUrl`) hits a confusing failure on Send with zero warning
   beforehand. **Fix**: a new `AiProviderPreferences.
   isActiveProviderConfigured` getter (mirrors `ApiConfig.isConfigured`'s
   own shape — non-empty `baseUrl` for `local`, non-empty `apiKey` for
   `openai`/`anthropic`), checked in `AiModellingScreen.initState` via a
   post-frame callback (matches this file's own `_scrollToBottom`
   pattern). If unconfigured: a dialog ("No AI provider configured yet" +
   "Open Settings" / "Not now"), plus a second, cheaper layer — grey out
   Send and show inline text if the user dismisses and tries to type
   anyway, so a dismissed dialog never means silent failure later.
   **Shipped as planned** — `AiProviderPreferences.isActiveProviderConfigured`,
   `AiModellingScreen`'s post-frame guard/dialog, and the grey-out-Send
   belt-and-suspenders layer are all real, tested code. The guard is
   skipped entirely whenever a caller supplies its own `AiProvider`
   override (tests, or any future caller bypassing preferences on
   purpose) — same "only apply to the real preferences-driven path"
   reasoning `_send()` already used for that override.
2. **Gemini/Groq are invisible in Settings.** `AiProviderSettingsScreen`'s
   "Local" tab has one preset button ("Ollama Cloud") and its own
   descriptive text only mentions Ollama — despite `README.md`'s own
   "Testing without cost" section naming Gemini and Groq as the best free
   options. **Fix**: presentation-only, no new provider slot (the "Local"
   tab already *is* the generic "any OpenAI-compatible endpoint" slot,
   correctly) — add 3-4 one-tap presets (Ollama Cloud, Gemini, Groq,
   maybe Zhipu/GLM-Flash) next to the existing button, rewrite the
   helper text to name them.
   **Shipped narrower than planned**: Ollama Cloud, Gemini, and Groq
   presets (the three this doc's own "Testing without cost" section
   actually recommends) — Zhipu/GLM-Flash left out, not because of a
   problem, just not named in the fix's own agreed scope above and no
   real need surfaced to add a fourth.
3. **The plan/validation UI never says whether a nested entity becomes a
   hole, or how many edges a Fillet/Chamfer selector actually resolved
   to.** Two layers:
   - **Cheap, client-only**: the validate response's `resolved_edges`
     (`AiPlanStepResultDto.resolvedEdges`) is already fetched but never
     shown — append "(N edges)" to a Fillet/Chamfer's result row in
     `AiModellingScreen._buildReviewAndGenerate`.
   - **The real fix, needs backend work**: don't reimplement nested-loop/
     profile detection client-side (duplicate geometry reasoning this app
     already has server-side, real drift risk). Extend `StepResult`
     (`ai_plan_schemas.py`, workstream 5) with a `hole_count` field for
     Extrude/Revolve/Sweep steps, sourced from `detect_profile`'s own
     already-computed `MultiProfile.holes` during dry-run resolution —
     real backend truth, not a client-side guess. `summarizeAiPlan`
     appends "— includes N hole(s)" when present.

   **Shipped, one real correction and one deliberate divergence**:
   - `detect_profile`'s actual return shape has no `MultiProfile.holes`
     field (that name doesn't exist in `app.sketch.profile` — verified by
     reading the module, not assumed from this doc's own wording, per
     this project's standing "verify, don't trust docs" discipline). The
     real per-loop hole count is `Profile.inner_loops`'s length, summed
     over whichever profile(s) `app.document.extrude.select_profiles`
     actually selects for the step's own `profile_refs` — a new
     `app.document.ai_plan._hole_count` helper reuses `detect_profile`/
     `select_profiles` directly (the exact functions the real Extrude/
     Revolve/Sweep resolution path already calls internally) rather than
     re-deriving anything. `StepResult.hole_count`/`AiPlanStepResultDto.
     holeCount` land as planned.
   - Surfaced as an annotation on the existing per-step validation row in
     `AiModellingScreen._buildReviewAndGenerate` ("ok — includes N
     hole(s)"), not baked into `summarizeAiPlan`: that function only ever
     sees the plan itself, never a validation result, and the validation
     results panel already exists as the natural home for anything
     `StepResult` reports (it's also where fix 3a's own edge-count
     annotation landed, right above this same row) — threading validation
     data into `summarizeAiPlan` would have meant a new parameter for a
     panel that already renders this data source elsewhere. Real caveat
     carried over from before this fix: that panel (`_validationFailureResults`)
     is currently only ever populated when the plan's own dry-run
     validation reports at least one failing step (see
     `PlanTranslationResult.validationFailed`'s own doc comment) — so
     today, both the edge-count and hole-count annotations are only
     visible on a run with a failure somewhere in it, never on a fully
     clean pass. Real, pre-existing scope gap, not something this fix
     introduced or was asked to close.
4. **The system prompt under-triggers clarifying questions.** Gemini
   asked zero questions on this request despite two real ambiguities
   (through vs. blind hole; which edges "chamfered edges" covers) and
   happened to guess correctly both times — luck, not a guarantee (ties
   back to the first pass's own Gemini finding under "Spike findings" in
   `03-structured-plan-schema.md`). Root cause: the current conversation
   rule only says "do not guess a *number*" — this request never needed
   the model to invent a missing number (the nested-loop approach and the
   literal 1mm both sidestepped that), so it technically complied while
   still silently resolving two real judgment calls. **Fix, two parts**:
   - Broaden the trigger beyond numbers: "...whenever a dimension,
     feature, tolerance, **or scope** (which edges/faces a Fillet or
     Chamfer applies to, whether a hole goes all the way through) is
     missing or has more than one reasonable interpretation."
   - Relax "your FINAL reply must contain nothing but the plan" to allow
     a short "Assumptions:" preamble before the fenced JSON — the
     plan-detection fallback (`detectPlanInAssistantText`) already
     extracts JSON from surrounding prose, so this doesn't break parsing,
     and gives visible reasoning without forcing a question round-trip
     for every judgment call. Pairs with point 3's backend fix: two
     independent visibility layers (what the LLM says it assumed, what
     the backend actually resolved) instead of trusting either alone.

   **Shipped as planned** — `ai_scoping_prompt.dart`'s `_conversationRules`
   now names scope/selector ambiguity explicitly (which edges/faces a
   Fillet/Chamfer applies to, through-vs-blind hole) alongside missing
   dimensions/features/tolerances, and the FINAL-reply rule now allows an
   optional short "Assumptions:" preamble before the fenced plan.
   Confirmed `detectPlanInAssistantText` still finds the plan with a
   preamble present (new regression test) — expected to keep working
   since the fenced-code-block candidate path never depended on the fence
   being the very first thing in the message, but confirmed rather than
   assumed.
