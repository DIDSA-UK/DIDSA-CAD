# Workstream 3: Structured Plan Schema

Read `00-conventions.md` first.

**Locked (this session)**: the schema below is the final, authoritative
shape — real Pydantic models in `backend/app/document/ai_plan_schemas.py`,
which is now the actual source of truth; this section is a summary of it,
not a second independent spec. The "Open design problem" this file used
to carry (edge selection for Fillet/Chamfer) is resolved — see "Edge
selection for Fillet/Chamfer" below. Workstream 5's validate endpoint
(`backend/app/document/ai_plan.py`) implements and exercises every `kind`
value against real OCCT geometry (`backend/tests/test_ai_plan_validate.py`).

## Shape

```json
{
  "version": 1,
  "steps": [
    { "local_id": "sk1", "kind": "sketch", "plane": "XY" },
    { "local_id": "p1", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 0, "y": 0 },
    { "local_id": "p2", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 60, "y": 0 },
    { "local_id": "p3", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 60, "y": 40 },
    { "local_id": "p4", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 0, "y": 40 },
    { "local_id": "r1", "kind": "sketch_rectangle", "sketch_feature_id": "sk1",
      "corner_point_ids": ["p1", "p2", "p3", "p4"] },
    { "local_id": "f1", "kind": "extrude", "sketch_feature_id": "sk1",
      "extrude_type": "boss", "start_distance": 0, "end_distance": 10 },
    { "local_id": "f2", "kind": "fillet",
      "edges": { "selector": "top_face_edges", "of": "f1" }, "radius": 5 }
  ]
}
```

Every step has a `local_id` (plan-local, never a real backend id — nothing
is created until the translator runs, per `00-conventions.md`) and a
`kind`. Later steps reference earlier ones by `local_id`.

**Naming convention (locked)**: every field that would hold a real
`SketchEntityRef`/`SubShapeRef`/backend id in the corresponding
`...FeatureCreate` schema (`backend/app/document/schemas.py`) instead
holds a plan-local `local_id` string (or list of them) here, under the
*exact same field name* — e.g. `ExtrudeFeatureCreate.sketch_feature_id`
(a real id) becomes `ExtrudeStep.sketch_feature_id` (a `local_id`) here.
Only the *value*'s meaning changes; the field name doesn't, so
workstream 4's translator maps one-to-one by name. Note this corrects the
original draft's example above, which used ad hoc short names (`"sketch"`,
`"profile"`) inconsistent with this rule and — for `sketch_rectangle` —
a `corner`/`width`/`height` convenience shape the real backend API has no
equivalent for at all (`RectangleCreate.corner_point_ids` always
references 4 existing Points; there is no server-side corner+width+height
math). A plan wanting a rectangle emits 4 `sketch_point` steps first, same
as the client always has to.

**`kind` values for v1**, one per allowed entity/Feature type from
`00-conventions.md`'s scope-boundary list — exact field shapes are the
Pydantic models in `backend/app/document/ai_plan_schemas.py`, not repeated
here:
- Sketch entities: `sketch` (creates the SketchFeature + Sketch, mirrors
  `SketchFeatureCreate`), `sketch_point`, `sketch_line`, `sketch_circle`,
  `sketch_arc`, `sketch_ellipse`, `sketch_rectangle`, `sketch_polygon`,
  `sketch_slot` — field shapes mirror `app.sketch.schemas`' own
  `PointCreate`/`LineCreate`/`CircleCreate`/etc. parameter lists directly.
- Features: `extrude`, `revolve`, `sweep`, `fillet`, `chamfer`, `pattern`,
  `mirror`, `create_plane` — field shapes mirror
  `app.document.schemas`' own `ExtrudeFeatureCreate`/etc. parameter lists,
  **with one v1 scope narrowing**: `create_plane`, `pattern`'s
  `direction_1`/`direction_2`/`axis`, and `mirror`'s `mirror_plane` all
  drop whichever of their real ref options need a Body face/edge/vertex
  `SubShapeRef` (`face_ref`/`edge_ref`/`vertex_ref`) — the same "doesn't
  exist yet at plan-authoring time" problem Fillet/Chamfer's edges have,
  for which no selector heuristic has been designed outside the Fillet/
  Chamfer case. Only the plan-expressible options remain: `create_plane`
  is restricted to `NORMAL_TO_LINE_AT_POINT`/`THREE_POINTS` (the two
  `PlaneType`s built from Sketch points/lines alone); Pattern's
  `direction_1`/`direction_2` and Mirror's `mirror_plane` are restricted to
  `fixed_axis`/`fixed_plane` or a `sketch_line_ref`/`plane_feature_id`.
  Pattern's `axis` is narrower still, and for a different reason (bug
  found while implementing workstream 4, not a v1 scope choice): the real
  `PatternAxisRef` it mirrors resolves to a full world-space axis (an
  origin point *and* a direction — a Circular Pattern rotates around a
  real pivot, not just along a direction) and has **no** `fixed_axis`
  option at all, unlike `PatternDirectionRef`'s plain direction — `axis`
  must always be a `sketch_line_ref`. A real, deliberate scope narrowing
  everywhere else, not an oversight.
- Routing: `gear_request` — carries gear parameters (type, module, tooth
  count, etc.) rather than a Feature-tree step at all; the translator
  (workstream 4) intercepts this kind before normal execution and hands
  off to the existing Gear Design screens instead. Workstream 5's
  validator always reports `ok: true` for a `gear_request` step without
  attempting any real resolution (there is nothing to resolve — see that
  doc's own handling), and reports a dedicated
  `gear_body_not_validatable` error for any later step that names a
  `gear_request` step's `local_id` as a Body reference (a real reference-
  kind match, since a routed gear request does produce a real Body once
  the translator runs it for real, but not something this endpoint can
  dry-run).

References to earlier steps (a Fillet's edges, an Extrude's profile) use
`local_id` strings, resolved by the translator's `local_id -> real id` map
as it executes steps in order — never a real `SubShapeRef`/
`SketchEntityRef` in the plan itself, since those don't exist until the
real backend call happens.

## Reference kind-checking (locked schema rule)

A step reference must resolve to the *right kind* of earlier step, not
just any earlier `local_id` — this is a schema rule every implementation
(workstream 5's validator, and workstream 4's real translator) must
enforce, not just something workstream 5's validator happens to check as
an implementation detail. The spike run that surfaced this gap (see
"Spike findings" below) found a real plan where an `extrude`'s
`sketch_feature_id`-equivalent field pointed at a `sketch_rectangle`
step's own `local_id` instead of the `sketch` step that owns it, and a
throwaway validator that only checked "does this `local_id` exist among
earlier steps" waved it through.

The exact rules (implemented in `backend/app/document/ai_plan.py`, the
same file every rule name below is drawn from):
- `sketch_feature_id` fields (`sketch_point`/etc.'s own, `extrude`'s,
  `revolve`'s, `sweep`'s) must resolve to a `sketch` step — never any
  other kind.
- `extrude.profile_refs`/`revolve.profile_refs`/`sweep.profile_refs`/
  `sweep.path_refs` entries must resolve to a `sketch_line`/
  `sketch_circle`/`sketch_arc`/`sketch_ellipse` step — never a bare
  `sketch` step, and never a `sketch_rectangle`/`sketch_polygon`/
  `sketch_slot` step directly (the real backend's own `select_profiles`
  only accepts a Line/Circle/Arc/Ellipse/Spline/Text anchor; a composite
  entity's own boundary Lines stand in for it instead).
- `revolve.axis_ref` must resolve to a `sketch_line` step specifically
  (never `sketch_circle`/`sketch_arc`/etc. — mirrors the real
  `RevolveFeature.axis_ref`'s own "must be a Line" constraint).
- `fillet.edges.of`/`chamfer.edges.of`/`target_body_ids`/
  `source_body_ids`/`tool_feature_id` entries must resolve to a step kind
  that actually produces a Body (`extrude`, `revolve`, `sweep`,
  `pattern`, `mirror`, `gear_request`) — never a `sketch`, `create_plane`,
  `fillet`, or `chamfer` step.
- `create_plane.line_ref`/Pattern-or-Mirror's own `sketch_line_ref` must
  resolve to a `sketch_line` step; `create_plane.point_ref`/`point_refs`
  must resolve to `sketch_point` steps; `create_plane.plane_feature_id`/
  Mirror's own `mirror_plane.plane_feature_id`/`sketch.plane_feature_id`
  must resolve to a `create_plane` step.

A reference to an unknown `local_id`, or to a `local_id` whose owning
step already failed validation, are each their own distinct error
(`unknown_local_id`, `depends_on_failed_step`) — see
`05-backend-plan-validation.md`'s own short-circuiting rule.

## Edge selection for Fillet/Chamfer (locked)

**Resolved, and confirmed independently twice.** Real spike 2 testing
(2026-08-06, a separate concurrent session — see "Spike 2 findings"
below) confirmed option (b)'s four selectors against real OCCT geometry
via a `MeshData`-based implementation (triangle centroids/normals,
`face_edge_ids`). This workstream 3/5 implementation session
independently re-confirmed the same four selectors work, via a different
implementation (`backend/app/document/ai_plan_edges.py`, plain OCCT
`TopExp_Explorer`/`BRepAdaptor_Surface` face/edge queries, not the mesh
layer), exercised end-to-end by `backend/tests/test_ai_plan_validate.py`
and against a fillet-then-select-again multi-step case. Two independent
methods landing on the same four selector definitions is stronger
evidence than either alone. (Historical note: this file used to carry
this as an "Open design problem" with two named candidates; kept below
for the record, since the "why not (a)" reasoning is still the reason (b)
was chosen.)

Fillet/Chamfer's `edge_refs` are `SubShapeRef`s (`body_id` + `shape_type`
+ `index`) that only exist after a Body has been computed by the backend.
Sketch entities get a plan-local id *before* any backend call (the
translator assigns real ids only once it creates them for real), but a
Body's edges have no such luxury — the LLM can't name "edge 7 of body X"
in a plan authored before that body exists.

- **(a) Mid-execution LLM turn** (not chosen). The translator creates the
  Extrude for real first, fetches the resulting Body's mesh/edge data,
  then makes a second, narrowly-scoped LLM call before continuing. Most
  flexible, but breaks the "translator execution is LLM-call-free and
  deterministic" property the rest of this doc set relies on (see `04`'s
  own framing), and needs a second real network round-trip per Fillet/
  Chamfer step.
- **(b) Coarse plan-level selectors, resolved deterministically —
  chosen.** The plan names an edge *selector* instead of a specific edge;
  a small, fixed set of deterministic heuristics resolves the selector
  against the real Body topology once it exists, no LLM call involved.

**The four selectors** (`EdgeSelectorKind` in `ai_plan_schemas.py`),
resolved by `ai_plan_edges.resolve_edge_selector` via plain OCCT face/
edge queries (`TopExp_Explorer`/`BRepAdaptor_Surface`), not through
`MeshDto`'s own dense id scheme (see that module's own docstring for why
the two id spaces can disagree for a Body with a degenerate edge):
- `top_face_edges` / `bottom_face_edges`: every edge of whichever planar
  face's outward normal most closely aligns with `+z`/`-z`.
- `vertical_edges`: every straight edge whose direction is parallel to
  the global Z axis.
- `all_edges_of_face_at_position: <direction>`: every edge of whichever
  planar face's outward normal most closely aligns with the given
  `CardinalDirection` (`+x`/`-x`/`+y`/`-y`/`+z`/`-z`).

**v1 limitation, stated explicitly since it's real**: every selector is
relative to the *global* X/Y/Z axes, never a Sketch's own local plane
normal or a Body's own actual extrusion direction — correct for the
common case this v1 scope is built around (an XY-plane Sketch extruded
along Z), not a fully general resolver for a Body built on a tilted
custom plane. A selector matching zero edges, or a face selector matching
zero/no unambiguous face, is a real validation failure (`edge_selector_
no_matching_face`/`edge_selector_no_matching_edges`), never a silent
empty selection.

## Spike 2 findings (2026-08-06): edge-selector heuristics, confirmed against real OCCT geometry

Run in a freshly-bootstrapped real backend environment (`miniforge` +
`mamba env create -f backend/environment.yml`, same recipe this
project's own bevel-gear spike used previously — no sandbox/session so
far had `pythonocc-core` installed until this one; built it rather than
working around its absence). Full existing backend test suite re-run
against the fresh environment first to confirm it wasn't itself the
source of any finding below: **1527 passed, 0 failed** (`pytest -n
auto`, 3:59 wall-clock). Script itself is scratch, not committed, per
this project's
spike convention - built a real `BRepPrimAPI_MakeBox` shape, tessellated
it via the real `app.document.mesh.tessellate_shape`, and derived
selector logic purely from the same `MeshData` fields a real client
response already carries (`triangles`/`normals`/`face_ids`/`edges`/
`edge_ids`/`face_edge_ids`) - no shortcut access to OCCT face/edge
objects the real client-side translator wouldn't also have.

**Concrete selector definitions, confirmed working:**

- **`top_face_edges` / `bottom_face_edges`**: the face whose *triangle-
  centroid average* has the max/min Z, then that face's own
  `face_edge_ids` entry. Needs only `face_ids` + `vertices` (for the
  centroid) + the existing `face_edge_ids` array - no new mesh data.
- **`vertical_edges`**: an edge where *every* one of its polyline
  segments keeps (x, y) constant across both endpoints (checking every
  segment, not just first-to-last endpoints, so a curved-but-vertical
  edge - not possible on an axis-aligned box, but a real generalization
  - wouldn't false-negative). Needs only `edges` + `edge_ids`.
- **`all_edges_of_face_at_position: <direction>`**: generalizes top/
  bottom to any of the 6 cardinal directions (`+X`/`-X`/`+Y`/`-Y`/`+Z`/
  `-Z` for now) - the face whose *triangle-normal average* has the
  highest dot product with the requested direction, rejecting if no
  face's normal is within a tolerance of it (handles a shape with no
  face actually facing that way, e.g. after a chamfer removed it).
  `top_face_edges`/`bottom_face_edges` are just this selector fixed to
  `+Z`/`-Z` - one implementation, not two.

**Case 1 (plain 60×40×10 box, matching spike 1's own test dimensions for
continuity)**: all three selectors resolved correctly and **exactly
partitioned the box's 12 real edges with zero overlap** - 4 top-perimeter
+ 4 bottom-perimeter + 4 vertical, matching real box topology exactly
(each vertical edge is shared by two *side* faces, never top/bottom, so
this partition isn't a coincidence of a simple shape - it's the actual
topology). `all_edges_of_face_at_position(+X)` also resolved to the
correct 4-edge face.

**Case 2 (the realistic multi-step stress test - not in the original
spike-2 brief, added because it's the actual use case that matters):**
applied a **real fillet** (radius 2mm) to the box's own `top_face_edges`
result first (resolving the selector to real `TopoDS_Edge`s and calling
`BRepFilletAPI_MakeFillet`, not a shortcut), producing a body with 10
faces and 20 edges (the rounded corners add new fillet-surface faces and
edges). Then ran `vertical_edges` **against that already-modified body**
- correctly found exactly 4 vertical edges again, none of them
mistakenly picking up any of the new fillet-arc edges. This is the case
that actually matters for a real multi-step plan ("fillet the top edges,
then chamfer the vertical edges") - confirms the heuristic isn't only
correct against a pristine, single-feature body.

**Consequence**: the "Open design problem" above is resolved for v1's
selector set (`top_face_edges`, `bottom_face_edges`, `vertical_edges`,
`all_edges_of_face_at_position`) - option (b) is confirmed workable
against real geometry, not just theoretically preferred. Workstream 3's
schema can lock these four selectors as-is. **Not yet tested**: a
non-axis-aligned or curved-primary-geometry shape (e.g. a shape built on
a rotated `CreatePlaneFeature`, or a cylinder where "vertical" isn't
obviously the right concept at all) - the selector definitions above are
written in world-space X/Y/Z, which is correct for everything in v1's
own scope (Sketches only exist on XY/XZ/YZ fixed planes or a
`CreatePlaneFeature`, and `vertical_edges`/`top_face_edges` are natural
concepts for boxy, extruded-along-Z-ish parts) but would need
revisiting before ever generalizing past that.

**Environment note for future sessions**: this environment now has a
real `didsacad` conda env at `/tmp/miniforge` with `pythonocc-core`
installed - but per this container's own ephemeral-session lifecycle,
that's **not persisted** and won't exist in a future session. The
bootstrap recipe (`miniforge` installer via GitHub release asset
redirect - `micro.mamba.pm` itself is blocked, but
`github.com/.../releases/latest/download/...` works through this
session's proxy - then `mamba env create -f backend/environment.yml`)
is worth keeping as the known-working recipe for the next session that
needs real OCCT, rather than rediscovering it.

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

**Correction/update (2026-08-06, workstream 3/5 implementation session):
at the moment this implementation session started reading this file,
spike 2 genuinely had not yet run in *any* session it could see — the
record above states so twice, unambiguously, and the kickoff prompt this
session was given ("the four real selector definitions from spike 2")
didn't match that record. That gap has since closed for real: a separate,
concurrent session ran spike 2 properly (see "Spike 2 findings" above,
inserted right after this file's own "Edge selection for Fillet/Chamfer"
section) while this implementation session was independently building and
testing the same four selectors against real OCCT geometry via a
different method (`app.document.ai_plan_edges`, exercised by
`backend/tests/test_ai_plan_validate.py`). Both landed on the same four
selector definitions. Left here for the record as a real example of this
doc set's own "verify the doc's current state, don't trust a kickoff
prompt's framing of it" discipline paying off — the discrepancy was real
at the time it was flagged, not a false alarm, even though it resolved
itself before this session finished.

**Not yet done, updated:** Groq coverage (still genuinely blocked from
every session tried so far — needs a different network path, not just a
different session type); more adversarial/underspecified prompts beyond
the one bracket scenario.

**Closed since the above**: the `README.md` correction pass and the
validator-gap fix both landed — see `README.md`'s "Testing without cost"
section and `05-backend-plan-validation.md`'s own new "Real finding from
spike 1" section (the dry-run endpoint's design now explicitly requires
reference *kind*-checking, not just existence-checking).

## Third-model attempt (2026-08-06): Anthropic, blocked on billing, deferred by decision

Attempted from the sandboxed session directly (`api.anthropic.com` is
reachable there, unlike Groq/Ollama Cloud) using a real API key. Auth
succeeded — the key itself is valid — but the account had no usable
credit: `"Your credit balance is too low to access the Anthropic API."`
A different blocker class than Groq's network-level denial or the
sandbox's own policy denial: billing, not reachability.

**User decision: skip topping up credit for this, concept is considered
proven from the two models already tested.** Not pursued further this
round. A third, architecturally-independent model (neither Gemini nor
`gpt-oss`) to fully settle the thickness-error model-specificity
question **remains a real open item**, deliberately deferred rather than
closed — worth picking up opportunistically in a future session (e.g.
once Anthropic credit exists for other reasons, or Groq's block gets
resolved) rather than a dedicated session of its own.
