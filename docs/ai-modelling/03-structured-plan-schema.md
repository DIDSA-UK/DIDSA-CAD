# Workstream 3: Structured Plan Schema

Read `00-conventions.md` first. No dependencies, but this is the riskiest,
most foundational artifact in the whole doc set — resolve its own flagged
open problem (below) before locking the schema for real implementation.

## Shape

```json
{
  "version": 1,
  "steps": [
    { "local_id": "sk1", "kind": "sketch", "plane": "XY" },
    { "local_id": "e1", "kind": "sketch_rectangle", "sketch": "sk1",
      "corner": [0, 0], "width": 60, "height": 40 },
    { "local_id": "f1", "kind": "extrude", "profile": "e1",
      "start_distance": 0, "end_distance": 10, "mode": "boss" },
    { "local_id": "f2", "kind": "fillet", "edges": { "selector": "top_face_edges", "of": "f1" },
      "radius": 5 }
  ]
}
```

Every step has a `local_id` (plan-local, never a real backend id — nothing
is created until the translator runs, per `00-conventions.md`) and a
`kind`. Later steps reference earlier ones by `local_id`.

**`kind` values for v1**, one per allowed entity/Feature type from
`00-conventions.md`'s scope-boundary list:
- Sketch entities: `sketch` (creates the SketchFeature + Sketch),
  `sketch_point`, `sketch_line`, `sketch_circle`, `sketch_arc`,
  `sketch_ellipse`, `sketch_rectangle`, `sketch_polygon`, `sketch_slot` —
  field shapes mirror `SketchApiClient`'s own `createLine`/`createCircle`/
  etc. parameter lists directly (workstream 4 maps one-to-one).
- Features: `extrude`, `revolve`, `sweep`, `fillet`, `chamfer`, `pattern`,
  `mirror`, `create_plane` — field shapes mirror
  `DocumentApiClient`'s own `createExtrudeFeature`/etc. parameter lists.
- Routing: `gear_request` — carries gear parameters (type, module, tooth
  count, etc.) rather than a Feature-tree step at all; the translator
  (workstream 4) intercepts this kind before normal execution and hands
  off to the existing Gear Design screens instead.

References to earlier steps (a Fillet's edges, an Extrude's profile) use
`local_id` strings, resolved by the translator's `local_id -> real id` map
as it executes steps in order — never a real `SubShapeRef`/
`SketchEntityRef` in the plan itself, since those don't exist until the
real backend call happens.

## Open design problem: edge selection for Fillet/Chamfer

**Not resolved by this scoping session — needs its own design pass before
implementation starts on this workstream.**

Fillet/Chamfer's `edge_refs` are `SubShapeRef`s (`body_id` + `shape_type`
+ `index`) that only exist after a Body has been computed/tessellated by
the backend. Sketch entities get a plan-local id *before* any backend call
(the translator assigns real ids only once it creates them for real), but
a Body's edges have no such luxury — the LLM can't name "edge 7 of body
X" in a plan authored before that body exists.

Two candidate resolutions, named here so the next implementation session
doesn't have to rediscover them:

- **(a) Mid-execution LLM turn.** The translator creates the Extrude for
  real first, fetches the resulting Body's mesh/edge data from the
  backend, then makes a second, narrowly-scoped LLM call ("here are the
  12 edges of the Body you just described, by position — which ones did
  you mean by 'the top edges'?") before continuing. Most flexible, but
  breaks the "translator execution is LLM-call-free and deterministic"
  property the rest of this doc set relies on (see `04`'s own framing),
  and needs a second real network round-trip per Fillet/Chamfer step.
- **(b) Coarse plan-level selectors, resolved deterministically.** The
  plan names an edge *selector* (`"top_face_edges"`, `"bottom_face_edges"`,
  `"vertical_edges"`, `"all_edges_of_face_at_position: <face selector>"`)
  instead of a specific edge — a small, fixed set of deterministic
  heuristics in the translator resolves the selector against the real
  mesh/topology once the Body exists, no LLM call involved. The example
  schema above (`"selector": "top_face_edges"`) assumes this option.

**Recommend (b)** — it keeps workstream 4's execution loop fully
LLM-call-free (matching the "safer, reviewable" reasoning that won the
generation-mechanism decision in the original scoping conversation), at
the cost of a real, separate design task: enumerating which selectors v1
actually needs and how each resolves against `MeshDto`'s `faceIds`/
`edgeIds`/`faceEdgeIds` data (the same hit-testing data the Fillet flow's
own "tap a face to select its whole edge loop" UI already consumes, per
`document_api_client.dart`'s own `MeshDto.faceEdgeIds` doc comment — a
real, existing precedent to build the heuristic set against, not a cold
start).

## Excluded on purpose

Restated from `00-conventions.md` for this file's own completeness:
Spline, Text, Loft, GearChain, Planetary, BevelGear, BevelPair, Import are
not `kind` values in v1's schema at all. A future workstream extending
this schema (e.g. adding Loft once there's a real user need) follows the
same pattern: a new `kind`, new fields mirroring that Feature's own
`createXFeature` signature, no change to the schema's shape.

## Spike findings (2026-08-06)

Real, throwaway-script spike 1 run against **Gemini only**
(`gemini-flash-lite-latest`, via its OpenAI-compatible endpoint) — Groq
and Ollama Cloud, the intended second/weaker model data point, were
blocked by this session's own outbound network egress policy (not the
providers or the keys) and never got tested. **This is a real gap
against spike 1's original goal of testing a spread of models, not
closed** — re-run against at least one non-Gemini model before treating
these findings as final. System prompt used the exact five-component
shape from `02-scoping-conversation.md` (role/premise, this file's
vocabulary as of this session, units convention, one worked few-shot
example, conversation rules), draft `kind` set narrowed slightly from
the shape shown earlier in this file for the spike (fewer optional
fields) — re-align the two before locking anything for real.

**Three scenarios, one model:**

- **Fully-specified single-turn request** ("60x40x10mm block, 5mm
  fillets on top edges"): clean pass. Valid, schema-conformant plan on
  the first response, no clarifying questions needed or asked, sensibly
  centered geometry (rectangle corner correctly derived from the stated
  width/height to center it on the sketch origin — not something the
  prompt stated explicitly, a reasonable inferred default).
- **Gear-shaped request** ("external spur gear, module 2, 20 teeth,
  10mm face width, 20° pressure angle"): clean pass. Correctly emitted a
  single `gear_request` step rather than attempting freeform Sketch/
  Extrude generation — the routing instruction in the system prompt
  worked as intended.
- **Ambiguous request** ("Can you make me a mounting bracket?"): asked a
  real, relevant clarifying question first (dimensions, shape, hole
  placement) rather than guessing or immediately proposing a plan —
  matches the intended "ask before generating" behavior. On the
  follow-up turn (a fuller but still real-world-ambiguous description:
  "L-shaped bracket, 60x60x5mm thick, four M4 clearance holes near the
  corners, 3mm fillet on outer corners"), produced a plan that passed
  every structural/referential check (schema-valid `kind`s, no
  forward/dangling `local_id` references, valid edge selectors) —
  **but the boss `extrude` step's `end_distance` was `40`, not the
  stated `5` (mm)**. Everything else in the plan was correct or
  reasonable (hole positions, radii, fillet selector/radius).

**The important finding: this exact error reproduced identically across
two independent runs** (with the few-shot example in the system prompt,
and with it stripped entirely) — not a one-off random hallucination,
a repeatable failure mode on this prompt/model pairing. Consequences:

1. **Schema/referential validity does not imply dimensional/requirement
   correctness.** Workstream 5's dry-run validation endpoint checks
   structural resolvability (do references resolve, does geometry
   construct) — it would very likely **not** have caught this, since
   `end_distance=40` is a perfectly valid, resolvable Extrude on its
   own. This is a materially different failure class than anything
   `00-conventions.md`'s two-layer failure-handling section currently
   accounts for.
2. **Real design consequence for workstream 2**: the Review & Generate
   plan summary (`02-scoping-conversation.md`) needs to surface literal
   numeric values prominently and human-readably ("Extrude 0→40mm"),
   not just step *types* ("1. Sketch  2. Rectangle  3. Extrude  4.
   Fillet") — the whole point being that a human skimming real numbers
   next to what they just typed is currently the only layer that would
   have caught this specific error before it touched a real Part. Worth
   promoting from "nice to have" to an explicit requirement in that
   workstream given this finding.
3. **Few-shot example impact was inconclusive-to-slightly-negative on
   this one test**, contrary to this doc set's original assumption that
   examples would clearly help: the without-example run was arguably
   *more* structurally sound (a single sketch containing the outline and
   all four holes together, correctly read as one flat L-shaped profile)
   than the with-example run (which split holes across two sketches on
   two different planes, apparently over-interpreting "L-shaped" as a
   real bent double-flange bracket rather than a flat L-profile plate) —
   while both made the identical thickness error regardless. **Don't
   treat the few-shot-examples decision as settled** from this one
   model/one prompt-pair; needs testing across more models and more
   prompts before concluding either way, and possibly needs the example
   itself revised (its own bracket-adjacent wording may be part of what
   nudged the "bent bracket" misreading).

**Spike 2 (edge-selector heuristic): not run this session.** Needs a
real OCCT-backed test box or a fixture `MeshDto` — this sandbox has
never had `pythonocc-core` installed (same standing caveat as this
project's own Text-tool font work, `docs/roadmap.md`'s Text tool entry)
— deferred to a session with real backend/CI access.

**Not yet done, before this schema/prompt can be considered validated:**
non-Gemini model coverage (Groq and/or Ollama Cloud, once reachable),
more adversarial/underspecified prompts, and the edge-selector spike.

## Spike findings continued (2026-08-06, Ollama Cloud coverage)

Same session's continuation, run locally (not sandboxed) specifically to
reach the non-Gemini models the first pass couldn't. Same system-prompt
five-component shape and structural validator (kind membership, no
forward/dangling `local_id` refs, edge-selector membership) as the first
pass; scratch script again not committed, per this project's spike
convention.

**Groq: confirmed genuinely unreachable from this machine, not a sandbox
artifact.** Every request — with or without a real API key, `GET` or
`POST`, against `api.groq.com` — returns `HTTP 403` with body
`{"error":{"message":"Access denied. Please check your network settings."}}`.
That message and behavior is distinct from a normal missing/bad-key `401`
and appeared identically before and after supplying a real key, so this
reads as a network/IP/region-level block on Groq's own side for this
connection, not the sandboxed session's org-policy block from the first
pass and not an auth problem. **Groq stays untested** — dropped for this
session by user decision in favor of two Ollama Cloud models instead of
delaying further.

**Ollama Cloud: fully reachable** (`https://ollama.com/v1`, confirmed with
a plain `GET /models` returning `200` even unauthenticated). Ran the same
three scenarios from the first pass against two models on this endpoint:

- **`gpt-oss:20b`** (weak/fast tier — the "local-class" comparison point
  the original spike wanted).
- **`gpt-oss:120b`** (frontier-scale tier). **Correction to this doc set's
  own free-tier assumptions**: `glm-5.2`, `deepseek-v4-flash:preview`,
  `kimi-k2.6`, and `qwen3.5:397b` — the specific frontier models named in
  `README.md`'s "Testing without cost" section — all now return
  `HTTP 403 "this model requires a subscription"` on Ollama Cloud's free
  tier as of this session, contrary to that section's claim of reaching
  them at $0. Confirmed still-free on the same account: `gpt-oss:120b`,
  `nemotron-3-super`, `gemma4:31b`, `minimax-m3`. `README.md` itself
  wasn't updated this session (out of scope per this session's brief) —
  worth a follow-up correction pass.

**Fully-specified request and gear-shaped request: clean pass on both
models**, same as Gemini — valid schema-conformant plans first response,
gear request correctly routed to a single `gear_request` step, sensible
centered rectangle geometry on the block request.

**The L-shaped-bracket ambiguous scenario: the specific 40mm-vs-5mm
thickness error did NOT reproduce on either `gpt-oss` model, across five
total attempts** (both models × with/without few-shot, plus three extra
repeat runs on `gpt-oss:20b`/with-few-shot to check reproducibility — two
of those five hit transient read-timeouts, not a model-behavior data
point either way). Instead, across the runs that completed:

- **One run produced a schema-valid plan with the *correct* `end_distance`
  (5mm on both of its two extrude steps)** — `gpt-oss:20b`, with the
  few-shot example, first attempt. Structurally valid per this session's
  validator, though one extrude step's `profile` field referenced the
  parent `sketch` step's `local_id` directly rather than a specific
  rectangle entity within it — not caught as an error by the validator
  (it only confirms a reference resolves to *some* earlier `local_id`, not
  that it's the *right kind* of step to reference), a real gap in the
  validation logic worth carrying into workstream 5's design, not just a
  one-off quirk of this run.
- **The other completed runs (three of five) asked a further, genuinely
  relevant clarifying question instead of guessing** — e.g. "is this a
  square with a corner notch, or an L-profile plate?", "what's the width
  of each leg of the L?" — rather than silently picking a wrong number.
  Both `gpt-oss:20b` and `gpt-oss:120b` did this at least once each,
  with and without the few-shot example.

**Consequence for the open question from the first pass**: this is
evidence the Gemini thickness error is more likely **model-specific than
a universal structured-output weakness** — the `gpt-oss` family, when
uncertain on the identical prompt, tended to ask rather than confidently
emit a wrong number, which is the better failure mode of the two.
Caveat: both tested models share one family/lineage (`gpt-oss` at two
sizes), not independent architectures, so this doesn't yet rule out the
error being common to *some* other class of model — a real third,
architecturally distinct model (e.g. once Groq or a subscription-tier
Ollama Cloud model is reachable) is still needed before calling this
settled. Workstream 2's "surface literal values prominently" consequence
from the first pass stands regardless of this finding — a human-legible
safety net matters even when it fires less often than Gemini's runs
suggested.

**New observation — non-determinism across identical repeat runs**: unlike
Gemini's identically-reproduced error across 2 runs in the first pass, the
same model/prompt/temperature(0.2) pairing here produced three genuinely
different turn-2 behaviors across five attempts on `gpt-oss:20b` alone
(valid-correct plan, two different specific clarifying questions, two
timeouts). Single runs are not a reliable signal for these models —
future spike sessions should budget for repeat runs per scenario rather
than treating one pass/fail as final, a methodology gap in the first
pass's own single-run-per-scenario approach.

**Spike 2 (edge-selector heuristic): still not run** — same standing
blocker as the first pass (no `pythonocc-core`/real `MeshDto` fixture in
either sandboxed or local sessions so far).

**Not yet done, updated:** Groq coverage (still genuinely blocked from
every session tried so far — needs a different network path, not just a
different session type); a third, architecturally-independent model
(neither Gemini nor `gpt-oss`) to settle the thickness-error
model-specificity question; more adversarial/underspecified prompts
beyond the one bracket scenario; the edge-selector spike; the
validator-gap fix (reject a step reference that points at a `local_id` of
the wrong kind, e.g. an `extrude.profile` pointing at a `sketch` step
instead of a sketch-entity step); and a `README.md` correction pass for
the now-subscription-gated Ollama Cloud model list.
