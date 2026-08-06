# Workstream 5: Backend Plan Validation

Read `00-conventions.md` first. Depends on workstream 3 (needs the plan
schema's step shapes to validate against). This is the **only** backend
change in this whole feature.

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

Request body: the plan's steps, in the same shapes the real
`...FeatureCreate` schemas already accept (`ExtrudeFeatureCreate`,
`FilletFeatureCreate`, etc.) — the client-side translator (workstream 4)
is responsible for turning workstream 3's plan-local-id references into
this shape before calling this endpoint, the same translation step it
does for the real create calls, just run once speculatively first.

Response: one entry per step —

```json
{
  "results": [
    { "local_id": "sk1", "ok": true, "warnings": [] },
    { "local_id": "f2", "ok": false, "error": "end_distance must be greater than start_distance" }
  ]
}
```

## Implementation shape

Looks up the real `Part` via the existing `get_part_or_404(part_id)`.
Builds a **scratch copy** of the Part's Feature list (append each
pending step's Feature object to the copy as it validates the next one,
so later steps can depend on earlier ones exactly like a real sequential
create would) and calls the *existing* `resolve_X`/`resolve_X_from_bodies`
functions — the exact same ones the six-part Feature-tree checklist
(`docs/gear-design/00-conventions.md`) already established for every
Feature type this plan can use — against that scratch copy. **Never**
calls `replace_document` or anything else that mutates the real stored
Part. This is why it doesn't compromise the project's stateless-backend
principle: it's a pure function of (currently-stored Part, hypothetical
step list), same "compute, don't persist" contract as `/gear/preview`.

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
correctness, not just that a `local_id` exists among earlier steps —
e.g. `extrude.profile`/`revolve.profile`/`sweep.profile` must resolve to
a sketch-entity `kind` (`sketch_line`, `sketch_circle`,
`sketch_rectangle`, etc.), never to a bare `sketch` step itself;
`fillet.edges.of`/`chamfer.edges.of` must resolve to a Feature `kind`
that actually produces a Body (`extrude`, `revolve`, `sweep`, `pattern`,
`mirror`, `gear_request`), never to a `sketch` or another `fillet`/
`chamfer` step's raw output in a way the real backend wouldn't accept
either. Whether the real backend's own `resolve_X` calls already reject
this class of mistake with a clear error (likely, since a `sketch`
step's id presumably isn't a valid `SketchEntityRef` shape at all) or
whether it needs an explicit pre-check in this endpoint for a clearer
error message than whatever `resolve_X` naturally raises is worth
confirming during implementation, not assumed either way.
