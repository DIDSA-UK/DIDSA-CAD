# Workstream 5: Backend Plan Validation

Read `00-conventions.md` first. Depends on workstream 3 (needs the plan
schema's step shapes to validate against). This is the **only** backend
change in this whole feature.

**Built and tested (this session)**: the endpoint, its schemas, and the
edge-selector resolver are real, committed code —
`backend/app/document/ai_plan.py` (engine), `ai_plan_schemas.py` (request/
response Pydantic models), `ai_plan_edges.py` (Fillet/Chamfer selector
resolution), wired into `router.py`, tested in
`backend/tests/test_ai_plan_validate.py` against a real `pythonocc-core`
environment. The rest of this file is updated to describe what was
actually built, not a forward-looking spec anymore.

## Why a backend endpoint at all, given client-direct

The AI call itself is client-direct (`00-conventions.md`). This endpoint
isn't part of that — it's a plain, ordinary compute-only endpoint of the
same kind this backend already has plenty of (`/gear/preview`, the mesh/
export endpoints): given the real, currently-stored Part and a list of
*hypothetical* next Features, report whether each would resolve
successfully, without creating or persisting anything. It exists so most
schema/reference mistakes in an LLM-produced plan get caught and fed back
into the chat *before* the user's real Part is touched at all — see
`00-conventions.md`'s two-layer failure-handling section.

## Endpoint

```
POST /document/parts/{part_id}/ai-plan/validate
```

Request body: `{"version": 1, "steps": [...]}` — workstream 3's own
locked plan schema (`PlanValidateRequest`/`PlanStep` in
`backend/app/document/ai_plan_schemas.py`), the *same* steps the client
sends to the LLM-facing side of the feature, unmodified. This corrects
this section's own original framing: the request body is **not** the
real `...FeatureCreate` schemas with pre-translated ids — those schemas
expect real backend ids that don't exist yet for a not-yet-executed plan
(the whole reason workstream 3's `local_id` scheme exists at all). This
endpoint does its own local_id -> real-scratch-id resolution internally
(`app.document.ai_plan`'s `_PlanValidator`), building real `Feature`
dataclasses itself as it walks the plan in order — the same translation
work workstream 4's real translator does, just against a scratch Part
instead of the real one. Workstream 4 does **not** need to pre-translate
anything before calling this endpoint; it sends the plan as-is.

Response: one entry per step —

```json
{
  "results": [
    { "local_id": "sk1", "ok": true, "warnings": [], "error": null },
    { "local_id": "f2", "ok": false, "warnings": [],
      "error": { "type": "invalid_distances", "message": "end_distance must be greater than start_distance" } }
  ]
}
```

**Workstream 4 addition**: a successful `fillet`/`chamfer` result also
carries `resolved_edges` — the real Body edges its `EdgeSelector`
heuristic resolved to (`[{"body_id": "f1", "shape_type": "edge", "index": 3}, ...]`),
`null` for every other step kind. This is the *only* way the client can
ever get concrete edge refs for a Fillet/Chamfer step at all — the
heuristics in `ai_plan_edges.py` need real OCCT topology, never available
client-side — so workstream 4's translator reuses this dry-run's own
resolution for real execution instead of re-deriving it. Each entry's
`body_id` is deliberately the plan's own `edges.of` local_id (plus any
`#N` multi-solid suffix), never this endpoint's own scratch Feature id —
the translator substitutes the real id at the point of use, exactly like
every other local_id reference. Reusing the `index` values against real
execution is only valid because both walk the same step sequence from the
same empty starting Part (`00-conventions.md`'s "v1 always starts a fresh
Part") — the same assumption this endpoint already relies on for "a step
that dry-run-passes here behaves identically once workstream 4's
translator executes it for real."

`error` is always a structured `{"type": "...", ...}` object (never a
bare string) — every domain error in this codebase is already
`HTTPException(422/400, detail={"type": ...})`, and this endpoint's own
hand-raised errors (`unknown_local_id`, `wrong_kind_reference`,
`depends_on_failed_step`, `gear_body_not_validatable`,
`edge_selector_no_matching_face`/`edge_selector_no_matching_edges`/
`edge_selector_missing_direction`, plus payload-shape checks like
`invalid_distances`/`invalid_step_payload` that mirror the real router's
own `_validate_extrude_distances`/etc.) follow the identical shape for
consistency, correcting this section's own original example (a bare
string), which didn't match the rest of this codebase's own convention.

## Implementation shape

Looks up the real `Part` via the existing `get_part_or_404(part_id)`.
Builds a **scratch copy** of the Part's Feature list (`Part(id=part.id,
name=part.name, features=list(part.features))` — a shallow copy is
enough, since no resolver ever mutates an existing `Feature` object) and
appends each step's own real (freshly-`uuid4()`-id'd) Feature object to
the copy once that step validates, so later steps depend on earlier ones
exactly like a real sequential create would. Calls the *existing*
`resolve_X`/`resolve_X_from_bodies` functions — the exact same ones the
six-part Feature-tree checklist (`docs/gear-design/00-conventions.md`)
already established for every Feature type this plan can use — against
that scratch copy, per the candidate Feature **not yet appended**, the
same pattern every real create-Feature router endpoint already uses
(`create_fillet_feature`, etc.): resolve first, append only on success.
**Never** calls `replace_document`, `part.add_feature` on the *real*
Part, or anything else that mutates real stored state. This is why it
doesn't compromise the project's stateless-backend principle: it's a
pure function of (currently-stored Part, hypothetical step list), same
"compute, don't persist" contract as `/gear/preview`.

**One real asymmetry, confirmed during implementation**: unlike Fillet/
Chamfer/Revolve/Sweep/Mirror/Pattern/CreatePlane, `ExtrudeFeature` has no
standalone `resolve_extrude(part, feature, ...)` wrapper in this
codebase — the real create-Extrude router endpoint doesn't eagerly
resolve OCCT geometry either, deferring construction to `/mesh`. Since
this endpoint's whole purpose is to catch construction failures before
they touch the real Part, it doesn't mirror that laziness: it appends the
candidate `ExtrudeFeature` to the scratch Part tentatively, computes
`bodies_so_far` via `compute_part_bodies` (excluding the candidate's own
id), and calls `app.document.extrude.resolve_feature_tool_shape` directly
(the same shared entry point `RevolveFeature`/`SweepFeature`/`GearFeature`
already use, and the one `compute_part_bodies`'s own `ExtrudeFeature`
branch calls internally) — rolling the candidate back out of the scratch
Part (`part.delete_feature`) on any failure or a `None` result (no
extrudable profile). Every Sketch-entity step (`sketch_point`/
`sketch_line`/etc.) is handled similarly outside the `resolve_X` family
entirely: since Sketches live in `app.sketch.store`'s own global
singleton dict (not inside `Part`), a `sketch` step registers a real
scratch `Sketch` there (fresh uuid, cleaned up in a `finally` once
validation finishes) and later `sketch_*` steps mutate it directly via
its own `add_point`/`add_line`/etc. methods, catching `KeyError`/
`ValueError` the same way the real `app.sketch.router` endpoints already
do.

Each step is validated **in the order given**, short-circuiting on the
first structural failure a later step's own reference would need (e.g. if
step 2 fails, step 3 which references step 2's output is reported as
`ok: false` with a "depends on failed step sk1" error rather than a
misleading resolver exception) — mirrors how the real translator
(workstream 4) also stops at the first real failure, so dry-run and real
execution behave the same way given the same plan.

## Feature-tree checklist applicability

No new Feature type, so only checklist item 6 (router endpoint) is new.
Items 1-5 (dataclass, `depends_on`, `resolve_X` module, `compute_part_
bodies` branch, schemas) are all reused as-is from whichever existing
Feature types a given plan happens to use — this endpoint adds no new
geometry logic anywhere.

## Real finding from workstream 4 (2026-08-06): sketch-entity angle fields were radians, not degrees

`00-conventions.md` promises "degrees for every angle" and
`ai_plan_summary.dart`'s Review & Generate panel already labelled
`sketch_line`/`sketch_circle`/`sketch_arc`/`sketch_ellipse`'s
`angle`/`end_angle` fields with a literal "°" — but this endpoint's
handlers passed the value straight through to `Sketch.add_line`/
`add_circle`/`add_arc`/`add_ellipse`, whose own docstrings are explicit
that they expect **radians**. Never caught by this file's own tests
(structural dry-run success doesn't care whether an angle value is
numerically sensible — any float succeeds), and irrelevant to plan
*validity* on its own, but a real correctness bug for anything built from
an angle-bearing sketch entity: the geometry silently wouldn't match what
the degrees value said, and (workstream 4's own new concern) it would
have made dry-run's internally-modeled geometry diverge from the
translator's real execution wherever the translator correctly interpreted
the value as degrees — breaking the `resolved_edges` index-reuse guarantee
above. Fixed with a `math.radians()` conversion at each of the four call
sites; see `ai_plan_schemas.py`'s own field-level comments and
`test_ai_plan_validate.py::test_sketch_line_angle_is_degrees_not_radians`.

## Real finding from spike 1 (2026-08-06): reference *kind*-checking, not just existence-checking

`03-structured-plan-schema.md`'s own spike findings surfaced a genuine
gap this endpoint must not repeat: the throwaway spike script's own
structural validator confirmed a step reference (e.g. an `extrude`
step's `profile`) resolved to *some* earlier `local_id`, but never
checked that the referenced step was the *right kind* of thing to
reference — a real spike run produced a plan where an `extrude.profile`
pointed directly at its parent `sketch` step's `local_id` rather than a
specific sketch-entity step (`sketch_rectangle`, etc.) within it, and
the spike's validator waved it through.

This endpoint's own implementation must check reference *kind*
correctness, not just that a `local_id` exists among earlier steps — see
`03-structured-plan-schema.md`'s own "Reference kind-checking (locked
schema rule)" section for the exact, final rule set (which supersedes the
draft summary this section used to carry).

**Resolved during implementation**: this endpoint needs its own explicit
pre-check, not just reliance on `resolve_X` naturally rejecting a
wrong-kind reference. Since this endpoint resolves a `local_id` to a real
scratch object *before* building the real `Feature`/`SketchEntityRef`
(there's no other way to turn a `local_id` into a real id at all), the
kind check happens at that resolution step — `app.document.ai_plan`'s
`_PlanValidator._lookup`/`_lookup_body`, which take an explicit
`expected_kinds` set per field and raise a structured
`wrong_kind_reference` error (naming the field, the offending `local_id`,
its actual kind, and the expected kinds) before a malformed `Feature`
object is ever constructed — never a generic `resolve_X`-raised error a
client would have to reverse-engineer.
