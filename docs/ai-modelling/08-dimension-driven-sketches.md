# Workstream 8: Dimension-Driven Sketches

Read `00-conventions.md` first. **Built** (2026-08-20 session) - the second
of five extensions planned on top of the v1 feature (see `07-editable-
system-prompt.md`'s own ordering note: this workstream was next).

## The problem

`PlanTranslator` (`client/lib/ai/ai_plan_translator.dart`) placed every
sketch point at a literal x/y and computed every derived point (a
`sketch_line`'s length+angle, a `sketch_circle`'s radius+angle, etc.) via
client-side trig - correct geometry, but backed by nothing: no
`DistanceConstraint` was ever created via the sketch constraint API
(`SketchApiClient.createDistanceConstraint`/`.updateConstraintValue`). An
AI-generated sketch looked right but had no real dimension a user could
select and edit via the existing dimension bar
(`client/lib/sketch/sketch_dimension_bar.dart`), unlike one drawn by hand.

Worse than a missing convenience: for Circle/Arc/Ellipse/Polygon/Slot this
was a genuine **correctness** gap, not just an editability one.
`Sketch.add_circle`/`add_arc`/`add_ellipse`/`add_polygon`/`add_slot` already
auto-create their own size-defining `DistanceConstraint`(s), but always
`provisional=True` - a provisional `DistanceConstraint` is **skipped
entirely by the solver** until a real value confirms it (see
`DistanceConstraint.provisional`'s own doc comment in
`backend/app/sketch/constraints.py`). Since the old translator never
confirmed anything, every AI-generated Circle/Arc/Ellipse/Polygon/Slot's
radius was left completely unconstrained - free to drift on the next solve,
not just "not user-editable yet."

## What this adds

Wherever the plan already carries (or, for Circle/Arc/Ellipse/Polygon/Slot,
already implies via two real Points) a literal numeric size, the
translator now attaches a real, non-provisional constraint - reusing the
sketch API's existing constraint machinery exactly, the same calls a human
confirming a freshly-drawn shape's size already makes:

- **Circle/Arc/Ellipse/Polygon/Slot radius.** Each already gets a
  provisional radius `DistanceConstraint` (or, for Ellipse, two - major and
  minor) at creation time. Right after creation, the translator calls
  `SketchApiClient.updateConstraintValue(sketchId, radiusConstraintId,
  radius)` using the entity's own just-returned radius - which sets the
  value **and** clears `provisional` in one call, identical to how a human
  confirms a size via the dimension bar. Done **unconditionally**, not only
  when the plan step happened to carry a literal `radius`/`major_radius`/
  `minor_radius` field: `sketch_arc` and `sketch_polygon` have no such
  field in the schema at all (an Arc's radius always follows from
  `center_point_id`/`start_point_id`'s own coordinates; a Polygon's from
  `center_point_id`/`first_vertex_point_id`'s), but those coordinates are
  themselves always literal `sketch_point` values in this schema - so the
  resulting radius is always a real, known number either way. This is a
  deliberate broadening from the original "when the step gives a literal
  radius" framing: confirming unconditionally is what actually closes the
  under-constrained-geometry gap above for every one of these five entity
  kinds, not just the subset whose step schema happens to spell the number
  out directly.
- **Line length.** Unlike the five above, a Line has no automatic
  constraint at all. When a `sketch_line` step gives a literal `length`,
  the translator calls `createDistanceConstraint(sketchId, startId, endId,
  length, orientation: 'linear', provisional: false)` - a brand-new,
  already-non-provisional constraint, never something to later confirm. An
  explicit `end_point_id` with no `length` stays exactly as unconstrained
  as it already was (matches a human drawing a two-point line with no
  dimension added). **`angle`-only dimensioning is out of scope for this
  pass** - a real, disclosed limitation: there is no second reference line
  yet for an `AngleConstraint` to measure against, and inventing one
  (construction geometry, a global-axis reference) is real, separate scope.
- **Rectangle width/height.** New optional `width`/`height` fields on
  `sketch_rectangle` (schema change - see below). When given, the
  translator creates two `createDistanceConstraint` calls: `width` between
  `corner_point_ids[0]`/`[1]`, `height` between `[1]`/`[2]` - the same two
  edges `add_rectangle(axis_aligned=True)` already pins Horizontal/Vertical
  via its own direction constraints. Orientation is `'horizontal'`/
  `'vertical'` when `axis_aligned` is true (matching those direction
  constraints exactly), or `'linear'` when false (a rotated rectangle has
  no global horizontal/vertical to pin - a plain edge-length distance is
  still correct and unambiguous regardless of rotation). Confirmed safe
  alongside the axis-aligned direction constraints by a real solve (see
  "Verification" below) - pinning an edge's *length* is an orthogonal DOF
  from pinning its *direction*, never redundant.

## Schema/DTO changes

- `backend/app/document/ai_plan_schemas.py` - `SketchRectangleStep` gains
  `width: float | None = None`, `height: float | None = None`. Purely
  advisory: never consumed by `sketch.add_rectangle` itself, which is still
  driven entirely by the 4 corner Points (no corner+width+height shorthand
  at the real geometry-construction layer - unchanged from `03`'s own
  locked decision on that point).
- `client/lib/ai/ai_plan.dart` - `AiSketchRectangleStep` gains matching
  `width`/`height` fields.
- **A real gap found while implementing, not assumed from the kickoff
  framing**: the kickoff description of this workstream said Polygon/Slot's
  DTOs might be missing `radiusConstraintId` client-side "backend already
  has it" - checking `backend/app/sketch/router.py`'s own
  `_polygon_response`/`_slot_response`/`_ellipse_response` builders showed
  the backend *model* dataclasses (`Polygon.radius_constraint_id`,
  `Slot.radius_constraint_id`, `Ellipse.major_constraint_id`/
  `minor_constraint_id`) already existed, but the wire-facing
  `PolygonResponse`/`SlotResponse`/`EllipseResponse` Pydantic schemas never
  exposed them at all - unlike `CircleResponse`/`ArcResponse`, which already
  did. Fixed by extending all three response schemas
  (`backend/app/sketch/schemas.py`) and their builder functions
  (`backend/app/sketch/router.py`) to include the missing field(s),
  confirmed live via the real HTTP API (see "Verification" below) before
  wiring the client up to depend on them. `client/lib/api/sketch_api_client.dart`'s
  `PolygonDto`/`SlotDto` gain a nullable `radiusConstraintId`; `EllipseDto`
  gains nullable `majorConstraintId`/`minorConstraintId` - nullable for the
  same existing-call-site-compatibility reason `CircleDto.radiusConstraintId`
  already documents (tests/hand-built DTOs that predate this field keep
  compiling and simply skip the confirm step, matching this workstream's
  own defensive `_confirmRadius`/`_confirm_radius` no-op-on-null design).

## Translator / dry-run changes

- `client/lib/ai/ai_plan_translator.dart` - a new private `_confirmRadius`
  helper (no-ops if the DTO's constraint id is null) called right after
  Circle/Arc/Ellipse(x2)/Polygon/Slot creation; the Line and Rectangle
  branches gain their own `createDistanceConstraint` calls, guarded on the
  plan step's own `length`/`width`/`height` being non-null.
- `backend/app/document/ai_plan.py` (`_PlanValidator`) - two shared
  module-level helpers, `_confirm_radius`/`_create_distance`, reusing
  `app.sketch.router.update_constraint_value`/`create_constraint` directly
  (the exact same functions the real `PATCH .../constraints/{id}/`
  `POST .../constraints` endpoints call) rather than reimplementing their
  scaling/first-dimension logic - the dry run must mirror what the real
  translator does exactly (`00-conventions.md`'s own invariant), and
  reusing the literal router functions is the only way to guarantee that
  by construction rather than by keeping two implementations in sync by
  hand. Called from each `_handle_sketch_*` handler right after the scratch
  entity is created, mirroring the client-side call order exactly.

## Spike: confirming the exact scratch-Sketch API shape

Per this workstream's own brief, spiked before writing the real handlers -
not guesswork. This sandbox had no `pythonocc-core`/`py-slvs` environment
at session start (the standing caveat every prior AI Modelling session
before this one recorded); this session bootstrapped one for real via the
project's own documented recipe (`miniforge` + `mamba env create -f
backend/environment.yml`, per `03-structured-plan-schema.md`'s "Environment
note for future sessions"). With that in place:

- Confirmed `app.sketch.router.update_constraint_value` and
  `create_constraint` are ordinary importable Python functions (FastAPI's
  `@router.patch`/`@router.post` decorators don't wrap or prevent direct
  calls) - callable directly from `ai_plan.py` against the scratch Sketch
  already registered in the shared store by `create_sketch`, with no
  circular-import risk (`app.sketch.router` imports nothing from
  `app.document`).
- Confirmed directly against a real scratch `Sketch`/constraint solver
  (`_PlanValidator` driven by hand, not through the HTTP layer) that
  `_confirm_radius` correctly flips `provisional` to `False` for all five
  radius-bearing kinds - Circle, Arc, Ellipse (both major and minor),
  Polygon, and Slot - each returning `provisional: False` with the correct
  confirmed value.
- Confirmed via the real HTTP API (`TestClient`, real endpoints, not just
  direct model calls) that: a Rectangle's width/height constraints post
  successfully alongside its existing axis-aligned Horizontal/Vertical
  constraints with no 400/422 rejection; a Circle's radius constraint PATCH
  clears `provisional` and reports `converged: true`; and the fixed
  `PolygonResponse`/`SlotResponse`/`EllipseResponse` schemas now genuinely
  carry the new constraint id field(s) on the wire.
- Ran this project's **full existing backend test suite** (not just the
  new/touched tests) against the freshly-bootstrapped environment first, to
  confirm the environment itself wasn't the source of any finding:
  **1662 passed**, no failures, `pytest -n auto` (~7m40s wall-clock).

## Design choices worth flagging

- **Confirm unconditionally, not only when a literal field is present.**
  See "What this adds" above - the more complete fix given `provisional`'s
  own "skipped by the solver until confirmed" semantics. Considered instead
  only confirming when the plan step literally named a `radius`/etc. field
  (closer to a literal reading of "when the step gives a literal radius"),
  but that would leave Arc and Polygon - which have *no* such field in the
  schema at all - permanently under-constrained, missing the actual bug
  this workstream exists to fix for two of its five listed entity kinds.
- **Reuse the router functions directly server-side, not reimplement their
  logic.** `update_constraint_value`/`create_constraint` both carry real,
  non-trivial first-dimension scaling/reseeding logic
  (`_scale_sketch_for_first_dimension`/`_reseed_distance_constraint_free_point`)
  that a hand-rolled dry-run equivalent would have to duplicate and keep in
  sync by hand - a real drift risk `00-conventions.md`'s "dry-run matches
  real execution" invariant exists specifically to avoid. Importing and
  calling them directly (they're ordinary functions once past FastAPI's
  route-registration decorator) makes that invariant true by construction.
- **Rectangle orientation follows `axis_aligned`, not a separate flag.**
  A rotated (`axis_aligned: false`) rectangle's width/height still becomes
  a real dimension, just via `'linear'` orientation instead of
  `'horizontal'`/`'vertical'` - correct regardless of rotation angle, since
  it's still exactly that edge's own straight-line length between the same
  two corner Points either way.
- **No versioning/migration story** for the new Polygon/Slot/Ellipse
  response fields or the Rectangle schema's new optional fields - not
  needed yet (purely additive, all-optional/all-nullable), same posture
  `07`'s own "no versioning/migration story" note already established for
  this doc set.

## Explicitly out of scope (real, disclosed limitations)

- **Line `angle`-only dimensioning.** No `AngleConstraint` is created for a
  `sketch_line`'s `angle` field - there is no second reference line yet to
  measure the angle against. A future pass could introduce a construction
  reference line (a fixed-axis one, or one shared across a whole sketch)
  specifically to give `angle` a real dimension too.
- **Ellipse `rotation`.** Not part of this pass's scope (the plan schema
  never carries a literal rotation value to begin with - `angle` only
  places the major-axis Point, mirroring `sketch_circle`'s own `angle`
  field).
- **Non-axis-aligned Rectangle `width`/`height` still uses two independent
  `'linear'` distance constraints**, not a dedicated "rectangle size"
  concept - correct and unambiguous, but two separate constraints a user
  edits independently, same as any other two-dimension shape.

## Tests

- `backend/tests/test_ai_plan_validate.py` - five new cases, run against
  this session's real bootstrapped `pythonocc-core`/`py-slvs` environment
  (all passing, alongside the full 1662-test pre-existing suite):
  - `test_sketch_line_length_creates_a_real_non_provisional_distance_constraint`
  - `test_sketch_line_without_length_creates_no_constraint`
  - `test_sketch_rectangle_width_height_create_real_axis_aligned_constraints`
    (includes a real `solve_sketch` call confirming convergence - no
    over-constraint)
  - `test_sketch_rectangle_without_width_height_creates_no_distance_constraint`
  - `test_sketch_circle_radius_point_confirms_a_real_non_provisional_radius_constraint`
- `client/test/ai_plan_translator_test.dart` - four new cases in a new
  `'PlanTranslator.execute - dimension-driven sketches (real constraints,
  not raw coordinates)'` group: Line length creates a constraint, Line
  without length creates none, Rectangle width/height creates both
  horizontal and vertical constraints against the correct corner pairs,
  Circle confirms its provisional radius constraint via
  `updateConstraintValue`. **Not run this session** - this sandbox has no
  Flutter SDK installed (`flutter`/`dart` both absent from `PATH`), the
  same standing gap every prior AI Modelling session recorded for client-
  side verification; written and reviewed against the existing test file's
  own `MockClient`-based conventions, not executed.
- Arc/Ellipse/Polygon/Slot radius confirmation was verified directly
  against a real scratch Sketch (see "Spike" above) rather than via a
  committed test for each - the Circle/Rectangle/Line cases above already
  exercise the shared `_confirm_radius`/`_create_distance` helpers end to
  end; a dedicated regression test per remaining entity kind is a
  reasonable low-cost follow-up, not done this session to keep the test
  additions focused on the two cases the workstream brief called out
  explicitly (Rectangle width/height, Line length) plus one representative
  radius-confirmation case (Circle).

## Manual/scripted end-to-end verification

Ran directly against the real HTTP API (`TestClient`, not just the dry-run
validator) this session:

- A full `sketch -> 4 points -> rectangle(width=60, height=40) -> extrude`
  plan through `POST /document/parts/{id}/ai-plan/validate` - every step
  `ok: true`, including the `extrude` step after the newly-dimensioned
  rectangle (confirms the new constraints don't break profile detection).
- A real (non-dry-run) rectangle created via `POST .../rectangles`, then
  both width and height `DistanceConstraint`s created via
  `POST .../constraints` with `orientation: horizontal`/`vertical` - both
  `201`, no conflict with the rectangle's own axis-aligned direction
  constraints.
- A real Circle, then its radius constraint confirmed via
  `PATCH .../constraints/{id}` - response shows `provisional: False`,
  `converged: true`, and a follow-up `GET .../constraints` shows the same
  constraint with the confirmed value persisted.
- Real Ellipse/Polygon/Slot creation via their own endpoints, confirming
  the new `major_constraint_id`/`minor_constraint_id`/`radius_constraint_id`
  fields are genuinely present in each response body.

**Not done this session** (disclosed, not silently skipped): driving an
actual end-to-end AI generation from a real LLM prompt through the Flutter
UI's dimension bar - this sandbox has no Flutter SDK and no display to
drive `AiModellingScreen` interactively. The HTTP-level verification above
exercises the identical backend calls the real translator makes, but a
device/emulator pass (matching this project's own "on-device feedback
round" pattern named in `README.md`'s delivery-order table) is the natural
next-session follow-up before calling this fully proven end-to-end.
