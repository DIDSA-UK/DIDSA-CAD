# Workstream 9: Existing-Part Editing ("Continue with AI")

Read `00-conventions.md` first. **Built** (2026-08-20 session) - the third
of five extensions planned on top of the v1 feature (see `07-editable-
system-prompt.md`'s own ordering note: this workstream follows 7 and 8).

## The problem

`00-conventions.md`'s "v1 always starts a fresh Part" was a deliberate v1
scope boundary, not an oversight - `AiModellingScreen._generate()` always
called `startNewDocument()` + `createPart()`, so there was no way for the
AI to see or edit a Part that already exists. This workstream is the
deferred follow-up that deliberately breaks that rule, on purpose, for a
brand-new entry point only - `ToolChooserScreen`'s "AI Modelling" tile
(the original "start fresh" path) is completely untouched.

## What this adds

A new "Continue with AI" app-bar action on `PartScreen`, next to the Part
name, that pushes `AiModellingScreen(existingPartId: part.id, documentApi:
widget.documentApi)`. When `existingPartId` is set, the screen:

- Fetches the Part's current Features once (`initState`), builds a
  prompt-facing summary of them, and threads it into every scoping turn's
  system prompt.
- On Generate, reuses `existingPartId` directly for both the dry-run
  validate call and `PlanTranslator.execute` - **never** calls
  `startNewDocument()`/`createPart()` in this mode. Getting this wrong
  would silently wipe (`startNewDocument`) or orphan (`createPart`) the
  user's real Document/Part - the single easiest thing to get wrong in
  this whole workstream, called out explicitly in code comments and
  guarded by its own widget test (see "Tests" below).

## The `existing:` prefix convention (core mechanism)

Every plan-step field that already holds a local_id string
(`sketch_feature_id`, `target_body_ids`, `edges.of`, `axis_ref`,
`plane_feature_id`, etc.) may *also* hold a string of the form
`existing:<real_id>`, naming a real backend Feature id instead of a
plan-local one. **No Pydantic/Dart field-shape change anywhere** - every
such field was already a plain `str`/`str?` (or a list of them), so only
the *resolution logic* on both sides changed, not the schema.

**Scope narrowing (deliberate)**: `existing:` references are allowed
**only** for:

- A Feature that produces a solid Body (any type - `produces == 'body'`,
  matching `FeatureDto.produces`/the backend's `Produces.BODY`, not just
  the narrower `extrude`/`revolve`/`sweep`/`pattern`/`mirror`/
  `gear_request` set a *plan-local* body reference is restricted to - an
  already-real Fillet/Chamfer/GearFeature is just as valid a Body target
  as an Extrude, since it has real, already-computed geometry, unlike a
  plan-local fillet/chamfer step, which the schema deliberately excludes
  for ordering reasons that don't apply to something already built) - as
  `target_body_ids`/`source_body_ids`/`tool_feature_id`, or a fillet/
  chamfer edges selector's `of`.
- A Feature that produces a construction Plane - as a `plane_feature_id`.
- A whole existing Sketch - as the `sketch_feature_id` anchor for **new**
  sketch-entity steps (`sketch_point`/`sketch_line`/etc.) defined fresh in
  the same plan.

Individual old Sketch entities (existing Points/Lines/Circles) are **never**
directly referenceable - new geometry into an old Sketch is always
expressed as new local `sketch_point`/`sketch_line`/etc. steps anchored to
that existing Sketch via `existing:<sketch_feature_id>`.

A step's own `local_id` can never itself start with `existing:` - that
prefix is reserved (`reserved_local_id_prefix`).

## Backend changes (`backend/app/document/ai_plan.py`)

- `_PlanValidator.__init__` builds `self._existing_by_id` (every real
  Feature already in the Part, by id) once, rather than re-scanning
  `part.features` per lookup.
- `_lookup` gained an `existing:` branch, checked *before* the local-id
  lookup, delegating to a new `_lookup_existing`. `_lookup_body` needed no
  change at all - it already calls `_lookup(local_id, _BODY_PRODUCING_
  KINDS, field)`, so the new branch is exercised through it automatically.
- `_lookup_existing` resolves the real Feature via `self._existing_by_id`
  and decides which of the three buckets above it falls into using the
  Feature's own `.produces` (`app.document.models.Produces` - the exact
  tag `FeatureDto.produces` mirrors client-side), never by re-deriving it
  from the Feature's Python type name. A body-producing existing Feature
  resolves to a `_Resolved` with a sentinel `kind="extrude"` - not a claim
  it's literally an Extrude, just enough for `_lookup_body`'s own
  `kind == "gear_request"` "not yet resolvable" check to never misfire for
  it (an existing Feature, unlike a plan-local `gear_request` step, always
  has real, already-computed geometry, whatever its own type).
- For an existing SketchFeature specifically, `_lookup_existing` also
  carries its real `sketch_id` in the returned `_Resolved` - so a new
  `sketch_point`/etc. step naming it as `sketch_feature_id` flows through
  the **completely unmodified** `_handle_sketch_point`/etc. handlers (they
  just call `get_sketch_or_404(sk.sketch_id)` and mutate, exactly as they
  already did for a brand-new scratch Sketch) - no special-casing needed
  in any of the seven sketch-entity handlers.
- New `_StepError` types: `reserved_local_id_prefix` (a step's own
  `local_id` starts with `existing:`, checked in `_run_step` before the
  handler runs), `unknown_existing_id` (the real id doesn't resolve to any
  Feature in the Part), `existing_id_not_allowed_here` (the Feature
  resolved, but its `.produces` doesn't match what this field accepts -
  the `existing:`-reference equivalent of `wrong_kind_reference`, reported
  with `actual_produces` since there's no plan-local `_Resolved.kind` to
  name an `actual_kind` from).

### The real-state-mutation problem (and how it's avoided)

Routing a new sketch-entity step through the unmodified `_handle_sketch_
point`/etc. handlers means those handlers mutate whatever real `Sketch`
object `get_sketch_or_404` resolves to - for a brand-new scratch Sketch
this is already safe (registered temporarily, deleted whole at the end via
`_scratch_sketch_ids`), but for an *existing* Sketch this would otherwise
mean a dry-run validate call permanently adding real Points/Lines/etc. into
the user's real, persisted Sketch - a direct violation of this module's own
"never mutates real stored state" docstring guarantee, and a real
correctness bug (an abandoned or merely-previewed plan would leave orphan
geometry behind).

Fixed by snapshotting every existing SketchFeature's real Sketch (via
`sketch_to_dict`, the exact same serialization native-file save/load
already uses) once, in `_PlanValidator.__init__`, and restoring it (via
`sketch_from_dict` + `add_sketch`, swapping the pristine reconstruction
back into the store under the same id) in `run()`'s own `finally` block -
alongside the pre-existing `_scratch_sketch_ids` cleanup, not instead of
it. Reusing the real native-format round-trip rather than hand-rolling a
snapshot/restore of `Sketch` internals is the same "reuse the real
functions, don't reimplement their logic to keep in sync by hand"
discipline `08-dimension-driven-sketches.md`'s own design choices already
established for `_confirm_radius`/`_create_distance`. Confirmed directly
by a real test (`test_existing_sketch_feature_anchors_new_sketch_entity_
steps`) that adds real points to an existing Sketch mid-dry-run and then
asserts the real Sketch's point count is back to its pre-dry-run value
once `run()` returns.

## Client changes

- **New** `client/lib/ai/ai_existing_part_summary.dart` -
  `summarizeExistingPartForPrompt(SketchApiClient, List<FeatureDto>)`: one
  line per Feature in creation order, each printing the literal
  `existing:<id>` token the LLM must echo back verbatim, plus a short
  human-ish description (extrude distances, fillet radius, etc. - literal
  values, same "surface real numbers" discipline `03`'s own spike findings
  established for the Review & Generate summary) and a referenceability
  annotation derived from `FeatureDto.produces` (`produces == 'body'` for
  Body targets, matching the task's own "use `produces`, don't re-derive it
  from type names" guidance). **Addendum (on-device feedback, see below)**:
  now also `async` and takes a `SketchApiClient`, since it fetches each
  Sketch Feature's own real entities.
- `ai_scoping_prompt.dart` - `buildAiScopingSystemPrompt` gains a new
  `String? existingPartSummary` parameter, alongside (not replacing)
  workstream 7's `assistantInstructionsOverride`/`enabledAddOns`. When
  non-blank, a new locked block (`_existingPartEditingBlock`) explaining
  the `existing:` convention and its scope restriction is unconditionally
  appended - same "structural contract, never user-editable" reasoning
  `07`'s plan-termination footer already established, since a user
  override that accidentally dropped or contradicted this convention would
  silently corrupt every plan the conversation produces. The default
  assistant instructions' "there is no current part" sentence is now
  conditional (`_defaultAssistantInstructionsFor`) - swapped for a short
  existing-Part note when a summary is present, so the (editable) default
  text no longer flatly contradicts the (locked) existing-Part block. The
  locked vocabulary reference's own "there is no existing part" claim (in
  its "What you cannot generate" section) was also softened to stay true
  in both modes, since that block is shared, unconditional prompt content.
  `defaultAssistantInstructions` (the public getter the settings screen
  uses for its own reset/compare baseline) deliberately keeps returning
  the fresh-Part variant regardless of any particular conversation's
  existing-Part context - it's a global settings concept, not scoped to
  one conversation.
- `ai_modelling_screen.dart` - new `existingPartId` constructor param.
  When set: `initState` fetches `documentApi.listFeatures(existingPartId)`
  once (caught, not fatal - a fetch failure just means no existing-Part
  context in the prompt, surfaced as a small inline error), storing both
  the raw `List<FeatureDto>` and the built summary string; `_send()`
  threads the summary into `buildAiScopingSystemPrompt`. **`_generate()`
  branches on `widget.existingPartId`**: when set, `partId` is
  `widget.existingPartId!` directly, and the `startNewDocument()`/
  `createPart()` calls are skipped entirely; when null (the original
  path), nothing changed. The one Part-list fetch from `initState` is
  reused for `PlanTranslator.execute`'s own `existingFeatures` parameter
  too - nothing else modifies this Part between opening the screen and
  pressing Generate, so a second fetch would only be redundant. AppBar
  title and the empty-chat intro copy both read differently in this mode
  (not "this always starts a brand-new Part").
- `ai_plan_translator.dart`:
  - New private `_resolveId(localId, ids)` helper: an `existing:` prefix
    strips straight to the real id (every field it's used for -
    `target_body_ids`, `source_body_ids`, `tool_feature_id`, `plane_
    feature_id`, a fillet/chamfer edge's `body_id`, a Sketch-entity
    step's own `sketch_feature_id` when read via the Feature-id map -
    already carries the real Feature/entity id verbatim after the
    prefix, no lookup needed); every other call falls back to the
    existing `ids[localId]!` lookup. Every `ids[...]!` call site in
    `_executeStep` and its own helpers (`_entityRef`, `_realSubShapeRef`)
    now goes through this.
  - `execute()` gained an `existingFeatures` parameter (`List<FeatureDto>`,
    default `[]`) and pre-seeds `sketchIds['existing:${f.id}'] =
    f.sketchId!` for every existing Feature with `produces == 'sketch'` -
    `sketchIds` is otherwise only ever populated as a brand-new
    `AiSketchStep` executes, so a sketch-entity step anchored to an
    *existing* Sketch would otherwise have no entry to find.
    Deliberately **not** the same resolution strategy as `_resolveId`:
    `existing:<feature_id>` needs the real Sketch's own id here, not the
    Feature id the prefix carries, so pre-seeding the map (rather than
    stripping) is what keeps every existing `sketchIds[...]!` call site
    correct completely unmodified.

## UI entry point

`PartScreen` gained a "Continue with AI" app-bar action (an `IconButton`,
`Icons.auto_awesome` - the same icon `ToolChooserScreen`'s own "AI
Modelling" tile already uses, for visual consistency), disabled until
`_part` has loaded, pushing `AiModellingScreen(existingPartId: part.id,
documentApi: widget.documentApi)`. `ToolChooserScreen`'s own "AI Modelling"
tile is untouched - still `const AiModellingScreen()`, still "start
fresh."

## Design choices worth flagging

- **`existing:` is a plan-authoring convention only, never sent over the
  wire as-is.** Both the backend validator and the client translator
  resolve it away before any real API call - `_lookup_existing`
  server-side, `_resolveId`/pre-seeded `sketchIds` client-side. A real
  Feature-creation request never carries the literal string `existing:`
  anywhere in its body.
- **Body-producing existing Features are broader than the plan-local
  `_BODY_PRODUCING_KINDS` set on purpose.** A plan-local reference to a
  fillet/chamfer/gear_request step is restricted by schema-ordering
  concerns that simply don't apply to an *already-built* Feature - an
  existing Fillet is exactly as valid a `target_body_ids` entry as an
  existing Extrude, since both already have real, computed geometry by
  the time a dry run resolves them.
- **No versioning/migration story** for the new `existingPartSummary`
  parameter or the `existing:` convention itself - not needed yet (purely
  additive; a plan with no `existing:` references behaves byte-for-byte
  as before), same posture `07`/`08`'s own "no versioning/migration story"
  notes already established.

## Tests

- `backend/tests/test_ai_plan_validate.py` - seven new cases, run against
  this session's real bootstrapped `pythonocc-core`/`py-slvs` environment
  (miniforge + `mamba env create -f backend/environment.yml`, per `03`'s
  own "Environment note for future sessions" recipe), alongside the full
  pre-existing suite - **1674 passed, 0 failed** (`pytest -n auto`,
  8m32s wall-clock):
  - `test_existing_body_feature_referenced_as_fillet_target` - a plan with
    *only* a fillet step, `edges.of` naming a real, already-built Extrude
    via `existing:<id>` - resolves and reports real `resolved_edges`.
  - `test_existing_body_feature_mixed_with_new_local_ids_as_cut_target` -
    `existing:` mixed with brand-new plan-local steps in the same plan: a
    fresh Sketch/Rectangle/Extrude(cut) targets the real pre-existing Body,
    confirming the cut genuinely resolves against real geometry (not just
    structurally accepted).
  - `test_existing_sketch_feature_anchors_new_sketch_entity_steps` - new
    `sketch_point`/`sketch_rectangle`/`extrude` steps anchored to a real,
    empty existing Sketch via `existing:<sketch_feature_id>`; confirms both
    that the plan validates and that the real Sketch's point count is
    restored to its pre-dry-run value afterward (the mutation-safety
    invariant above).
  - `test_existing_id_on_a_wrong_kind_field_is_rejected` /
    `test_existing_id_wrong_kind_reported_directly` - an existing
    SketchFeature named as a `target_body_ids`/fillet `edges.of` entry is
    rejected with `existing_id_not_allowed_here` and the real
    `actual_produces` value.
  - `test_unknown_existing_id_is_rejected` - `existing:` naming a real id
    that doesn't exist in the Part.
  - `test_step_local_id_cannot_itself_use_the_existing_prefix` - a step's
    own `local_id` starting with `existing:` is rejected with
    `reserved_local_id_prefix`.
- `client/test/ai_plan_translator_test.dart` - two new cases in a new
  `'PlanTranslator.execute - existing-Part editing (existing:<id>
  references)'` group: a fillet-only plan resolving entirely against an
  `existing:` Body (confirms the real request body carries the stripped
  real id, never the `existing:` wrapper), and a new `sketch_point` step
  anchored to an existing Sketch via `existingFeatures` pre-seeding
  (confirms no new SketchFeature is ever created, and the point posts to
  the real existing Sketch's own id).
- `client/test/ai_modelling_screen_test.dart` - two new widget tests: one
  confirming the system prompt carries the "Editing an existing Part"
  block and echoes real Feature ids from a stubbed `listFeatures` response,
  and - **the single most important regression this workstream needs
  guarded** - one confirming `_generate()` never issues `POST
  /document/new` or `POST /document/parts` (the real fresh-Part-creation
  calls) when `existingPartId` is set, only ever the existing Part's own
  scoped endpoints.
- `client/test/ai_scoping_prompt_test.dart` - four new cases: the locked
  block appears (and is placed before the plan-termination footer) when a
  summary is given, is absent (and the fresh-Part sentence survives) when
  it isn't, a blank summary is treated as none, and the block still
  appends under a custom assistant-instructions override.
- **Not run this session**: the Flutter test suite itself - this sandbox
  has no Flutter SDK installed (`flutter`/`dart` both absent from `PATH`),
  the same standing gap every prior AI Modelling session recorded for
  client-side verification. Every client-side test above was written and
  reviewed against the existing test files' own `MockClient`-based
  conventions, not executed.

## Manual/scripted reasoning check

Traced through, by hand, the scenario `00-conventions.md`'s "v1 always
starts a fresh Part" section named as the deferred case: build a part via
AI (fresh-Part path, entirely unaffected by this workstream - still
`createPart` on every Generate), open "Continue with AI" on the resulting
`PartScreen`, ask for "add a 5mm fillet to the top edges." The resulting
plan a real LLM would produce - a single `fillet` step naming
`existing:<the real extrude Feature's id>` as `edges.of` - passes exactly
the path `test_existing_body_feature_referenced_as_fillet_target` exercises
end-to-end against real OCCT geometry: the validator resolves the real
Extrude Feature, `resolve_edge_selector` runs against its real, already-
computed Body shape, and the client translator would post the real
resolved edge refs (with the real Feature id substituted for the `existing:`
wrapper) straight to `POST /document/parts/{id}/fillet-features` - adding
to the *same* Part, never creating a second one.

## Addendum: real Sketch geometry in the existing-Part summary

**On-device feedback**, after this workstream first shipped: the LLM
reported it could see that a Feature-tree entry like `extrude 0->10mm
(boss)` existed, but nothing about the Sketch profile behind it - no shape,
no size, only "a sketch has been extruded." The original
`summarizeExistingPartForPrompt` was Feature-tree-only (`FeatureDto`'s own
fields), and a `sketch` Feature's line never said anything about what was
actually drawn in it.

Fixed by fetching every real (non-construction) entity in each Sketch
Feature via `SketchApiClient`'s own per-type `list*` calls (`listPoints`/
`listLines`/`listCircles`/`listArcs`/`listEllipses`/`listPolygons`/
`listSlots`/`listRectangles` - the same calls `sketch_controller.dart`
itself makes when loading a Sketch for editing; there is no single bulk
"get everything" endpoint) and rendering a compact geometric description
per entity - a real dimension (radius/length directly off the DTO;
Rectangle's width/height computed from its own corner Points via the same
corner0->corner1/corner1->corner2 convention `08`'s dimension-driven-
sketches translator code already uses), never raw point/line ids, which
the model could never reference directly anyway (`existing:` scope stays
exactly as narrow as originally designed - individual Sketch entities are
still never directly referenceable, only the whole Sketch as an anchor).
Every extrude/revolve/sweep Feature's own description now also names the
Sketch it came from (`, from existing:<sketch Feature id>`), so the model
can connect a Body's own boss/cut numbers to the real profile that
produced them without guessing.

This is a real cost increase worth being explicit about: up to 8 extra GET
calls per Sketch Feature in the Part, all made once in `initState` before
the conversation starts (not per turn) - negligible for a normal Part's
sketch count, but scales linearly with how many Sketches the Part has.

`client/test/ai_existing_part_summary_test.dart` (new) covers: a rectangle
profile's real width/height reaching the summary, a circle's real radius
and center, construction-only geometry being excluded, and an empty Sketch
reading as `empty (no real geometry yet)` rather than blank.
