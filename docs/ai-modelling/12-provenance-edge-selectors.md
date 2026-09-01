# Workstream 12 (proposed, not built): Provenance-Based Edge Selectors

Read `00-conventions.md` first. This is a **scoping doc, like `03`'s own
original "Open design problem" section before its spike ran** - it
proposes a schema/backend shape and names the exact spike that needs to
run against real `pythonocc-core` before any of it is built for real. No
code changes accompany this doc.

## The problem this adds to, precisely

`03-structured-plan-schema.md`'s "Edge selection for Fillet/Chamfer
(locked)" section resolved v1's real, narrower problem: a Body's edges
don't exist at plan-authoring time, so a plan can't name one by index.
The four selectors it locked (`top_face_edges`/`bottom_face_edges`/
`vertical_edges`/`all_edges_of_face_at_position`) are geometric
heuristics, resolved against real topology once a Body exists
(`app.document.ai_plan_edges.resolve_edge_selector`) - not a naming/id
scheme at all, and on-device testing (`docs/status.md`'s 2026-09-01 entry)
confirms this: it's a real ceiling, not a bug. There is no way today to
name **one single specific edge** - only "every edge of the face closest
to +Z" and similar whole-face/whole-direction grabs.

This same shape of gap is already documented, independently, in two other
places in the schema itself - not a new observation, just an
under-connected one:

- `PatternDirectionStep`'s own docstring: "a Body edge doesn't exist at
  plan-authoring time, the same problem Fillet/Chamfer's edges have, and
  no selector heuristic has been designed for a pattern direction."
- `CreatePlaneStep`'s own docstring: the four `PlaneType` values needing a
  real Body face/edge/vertex (`OFFSET_FACE`, `MIDPLANE`,
  `NORMAL_TO_EDGE_THROUGH_VERTEX`, `PARALLEL_TO_FACE_THROUGH_VERTEX`) are
  excluded from v1 for exactly this reason.

So a single resolution mechanism, done once, has three real consumers
waiting on it - this doc scopes the mechanism itself against its primary
consumer (Fillet/Chamfer), and names the other two as real, disclosed
follow-on payoff rather than folding them in and making this harder to
review.

## The core idea: resolve by sketch lineage, not by post-hoc geometry guess

A plan already gives the LLM one thing it can name *before* any Body
exists: the sketch entity (`sketch_line`/`sketch_point`/etc. `local_id`)
that a profile is built from. Extrude/Revolve/Sweep all consume that exact
sketch geometry to build their Body - so the resulting Body edge a given
sketch line "became" is, in principle, directly derivable from the same
OCCT construction call that built the Body in the first place, via OCCT's
own shape-history query API (`BRepBuilderAPI_MakeShape.Generated(subshape)`
/`.Modified(subshape)` - available on any "history-producing" builder,
which `BRepPrimAPI_MakePrism`/`BRepPrimAPI_MakeRevol`/
`BRepOffsetAPI_MakePipeShell` all are).

**This is not a new idiom for this codebase.** Two real, committed
precedents already do exactly this:

- `app.document.gear._apply_root_fillet`/`_apply_root_fillet_to_loft`: maps
  an original tooth-profile wire vertex to the lateral edge
  `BRepPrimAPI_MakePrism.Generated()`/`BRepOffsetAPI_ThruSections.
  Generated()` says it became, then fillets exactly that edge - real,
  shipped, single-edge targeting via provenance, not a heuristic.
- `app.sketch.models.Sketch.external_references`/`ExternalVertexReference`
  plus `app.document.create_plane.refresh_external_references`: a Sketch
  Point can already carry a live reference to a specific Body vertex,
  re-resolved every time the Body's topology changes, flagged as "lost"
  (never silently wrong) if it stops resolving.

Industry framing, for context: this is the same family of technique real
CAD kernels use for their own "persistent naming problem" (tracing a
result back to *what created it*, not to a raw topology index, which is
notoriously unstable across most real OCCT/Parasolid/ACIS operations) -
OCCT's own OCAF/`TNaming` framework is the general-purpose version of this
same idea. This app doesn't use OCAF; the proposal below is a narrow,
purpose-built version of the same concept, scoped to exactly the cases
this schema needs.

## Proposed schema shape

Extend `EdgeSelectorKind` (`ai_plan_schemas.py`) with one new value:

```python
EDGE_FROM_SKETCH_LINE = "edge_from_sketch_line"
```

and give `EdgeSelector` one new optional field, following the exact
pattern `direction` already establishes for
`ALL_EDGES_OF_FACE_AT_POSITION` (required iff that one selector is used,
ignored otherwise):

```python
class EdgeSelector(BaseModel):
    selector: EdgeSelectorKind
    of: str
    direction: CardinalDirection | None = None
    # Required iff selector == EDGE_FROM_SKETCH_LINE; unused otherwise.
    sketch_line_ref: str | None = None
```

`sketch_line_ref` names an earlier `sketch_line` step's `local_id` - one
belonging to the same profile Sketch that `of`'s Body-producing step
consumed (a referential-validity rule for `05-backend-plan-validation.md`
to add, mirroring `revolve.axis_ref`'s existing "must resolve to a
sketch_line step" check). Resolves to exactly one edge (or, for a
Revolve - see below - the caller may get a face back and this selector's
own contract needs to define what "the edge" means there), never a
selector-of-many like the four heuristics.

`chamfer`/`fillet`'s `edges` field shape is completely unchanged - this is
additive to `EdgeSelectorKind`/`EdgeSelector` only, `FilletFeature`/
`ChamferFeature` themselves (which only ever store the final resolved
`SubShapeRef` list) need zero changes.

## Per-Feature-type mechanics (what the spike below needs to confirm)

**Extrude** (`extrude.py`). `_prism_for_profile`/`wire_for_profile` build
the profile wire, then discard the `BRepPrimAPI_MakePrism` builder after
taking `.Shape()`. Two real sub-cases inside `wire_for_profile` itself:
- The common "pure Line-chain polygon" fast path builds the wire via
  `BRepBuilderAPI_MakePolygon.Add(point)` per vertex - it never retains a
  per-edge `(sketch_line_id -> wire edge)` mapping today; one would need
  to be built alongside it (ordered pairing of `profile.point_ids`/
  `profile.line_ids`, one hop per line - needs confirming this pairing is
  always 1:1 for every real profile shape, not just the simple ones
  tested so far).
- The mixed Line/Arc/Spline path already builds each hop as its own edge
  individually before stitching via `BRepBuilderAPI_MakeWire` - a parallel
  `(sketch_entity_id -> edge)` list is a much smaller add here, since each
  edge already exists as its own local variable at construction time.
- The Circle/Ellipse/Text single-entity profiles need no mapping at all -
  the whole wire is unambiguously "that one entity."

**Revolve** (`revolve.py`, `BRepPrimAPI_MakeRevol`). A profile *edge*
sweeps into a *face*, not another edge - `.Generated(profile_edge)` needs
confirming against real OCCT for exactly what it returns (a single lateral
face is the expected case; the spike needs to check this for both a
partial-angle revolve, which also creates two new cap faces bounded partly
by the original profile edges, and a full 360° revolve, which doesn't).
`edge_from_sketch_line` on a Revolve body most likely needs to mean "an
edge of the generated lateral face" rather than the face itself - which
specific edge (the far one, at the swept end?) needs a real decision once
the spike shows what `.Generated()` actually returns, not guessed here.

**Sweep** (`sweep.py`, `BRepOffsetAPI_MakePipeShell`). The highest-risk of
the three - `sweep.py`'s own comments already document real, hard-won
`MakePipeShell` quirks specific to this codebase (natural-parametrization
surprises, single-wire-only `.Add()`, needing `BRepLib.BuildCurves3d`
workarounds elsewhere in this codebase for edge cases with pcurves - see
`bevel.py`'s own gotcha). `.Generated()`'s behavior on a
`MakePipeShell`-produced shell needs its own dedicated confirmation, not
an assumption it behaves like `MakePrism`/`MakeRevol` just because the API
name is similar.

**Pattern/Mirror/gear_request bodies - explicitly excluded.** A Pattern
instance's edges have no single simple sketch lineage (multiplied by
instance count, and a circular/rectangular pattern's own per-instance
transform sits between the sketch and the final edge); a Mirror's mirrored
copy is one more transform removed again; `gear_request` bodies aren't
built from this schema's own Sketch primitives at all. None of these are
good `of` targets for this selector - real, disclosed scope-narrowing,
not an oversight. The LLM should target the *source* body's edge (before
patterning/mirroring) when that's what it actually means, and the four
existing heuristic selectors remain the only tool for the patterned/
mirrored result itself.

**A second Fillet/Chamfer targeting an edge a prior Fillet/Chamfer
created - also explicitly excluded, permanently, not just for v1.** A
fillet-created rounded edge is pure construction with no sketch lineage at
all - there is nothing for this mechanism to trace back to. This is the
same fundamental limit real CAD kernels hit for the identical reason, not
a gap this workstream can close. The four existing heuristic selectors
(confirmed in `03`'s own Spike 2 to work correctly against a body a prior
fillet already modified) stay the right tool for this case, unchanged,
used *alongside* the new provenance selector rather than replaced by it.

## Where the resolution logic lives (the real open design question)

`ai_plan_edges.resolve_edge_selector(body, body_id, selector, direction)`
today only ever sees the *already-computed* Body shape - it has no access
to the Sketch, the owning Feature, or (critically) a live builder object
mid-construction. A provenance selector needs strictly more context than
that signature carries. Two structural options:

**Option 1 - resolve provenance eagerly, cache it alongside the Body
(recommended).** Extend `_prism_for_profile`/`resolve_revolve_from_bodies`/
`resolve_sweep_from_bodies` to also return a
`dict[sketch_entity_local_id, real_edge_index]` alongside the Body shape -
mirroring the `(shape, warnings)` tuple-return convention `resolve_loft`/
`resolve_gear` already use elsewhere in this same codebase, just with a
provenance dict instead of a warnings list. `body_cache.py`'s per-step
`bodies` snapshot is already exactly the right seam to hang this on - it
already stores one cached value per step, invalidated by the same
Feature-fingerprint-mismatch trigger already governing the Body itself, so
a parallel `edge_provenance` snapshot needs no new invalidation logic of
its own. `ai_plan_edges`'s new selector branch becomes a plain dict
lookup, not a second geometric heuristic - strictly more reliable than
option 2 below, at the cost of widening `body_cache.py`'s own per-step
snapshot shape (a real, contained change, not a rewrite - see that
module's own docstring for the "never-wrong-direction" invariant this
must not weaken).

**Option 2 - resolve provenance lazily, by rebuilding.** Since
`compute_part_bodies` is already fully deterministic (identical Feature
fingerprints always produce a byte-identical Body - `body_cache.py`'s own
stated guarantee), a resolver could instead re-run just the one Extrude/
Revolve/Sweep step's construction fresh, purely to read `.Generated()`/
`.Modified()` off its own throwaway builder - then needs to correlate that
result back to the real persisted Body's own edge index by geometric
coincidence (matching endpoints/curve), since a `TopoDS_Edge`'s own
identity does not survive a second, independent construction call even
given byte-identical geometric input. That last step is real, added
matching logic - arguably reinventing exactly the class of heuristic risk
this whole workstream exists to get away from - so option 1 is the
stronger choice unless a spike finds option 1 genuinely can't be threaded
through `body_cache.py` cleanly.

## Spike needed before any of this is built

Same "spike before committing" discipline `03`'s own "Spike 2" already
established for the original four selectors - this proposal is
unconfirmed against real geometry and should stay that way in this doc
until one runs. Concretely, against a real `pythonocc-core` environment
(bootstrap recipe: `03`'s own "Environment note for future sessions"),
confirm:

1. `BRepPrimAPI_MakePrism.Generated(edge)`/`.Modified(edge)`, given a wire
   edge identified via a real `(sketch_line_id -> wire edge)` mapping
   built through both `wire_for_profile` branches above, reliably returns
   the single correct lateral edge - for a plain rectangular profile
   *and* for an asymmetric profile where a heuristic selector genuinely
   couldn't disambiguate (the case that actually justifies this
   workstream).
2. The same idiom against `BRepPrimAPI_MakeRevol`, resolving the open
   "what does `.Generated()` return, and which edge of it counts as *the*
   edge" question above, for both a partial and a full 360° revolve.
3. The same idiom against `BRepOffsetAPI_MakePipeShell`, specifically
   because `sweep.py`'s own prior on-device-feedback history shows this
   API has already surprised this codebase more than once.
4. Whether option 1's `body_cache.py` extension can carry the provenance
   dict cleanly through its existing checkpoint-chain reuse logic, or
   whether a real complication (e.g. a step whose cached snapshot is
   reused across calls needing its provenance dict reconstructed
   identically) forces a rethink.

If the spike finds `.Generated()`/`.Modified()` behave inconsistently
enough on any one of the three Feature types (Sweep is the likely
candidate, per its own history above), landing this for Extrude/Revolve
only - and leaving Sweep on heuristic selectors alone, explicitly
disclosed as a known gap - is a legitimate partial-build outcome, not a
failure of the workstream.

## Payoff beyond Fillet/Chamfer (real, not this workstream's job to wire up)

Once the resolution mechanism above exists and is trusted,
`PatternDirectionStep.sketch_line_ref`'s equivalent for a Body `edge_ref`
and `PatternAxisStep`'s own currently-excluded `edge_ref`/`face_ref`
options (both already flagged in their own docstrings as "the same
problem Fillet/Chamfer's edges have") become straightforward extensions
of the identical mechanism - as would, eventually, a `face_from_sketch_
entity` counterpart unlocking `CreatePlaneStep`'s currently-excluded
`OFFSET_FACE`/`PARALLEL_TO_FACE_THROUGH_VERTEX` plane types. Listed here
so a future session doesn't have to rediscover the connection - not
scoped or designed here.

## Explicitly out of scope for this workstream

- Face selectors of any kind (needed for the `CreatePlaneStep` payoff
  above) - same underlying mechanism, real follow-on scope, kept out to
  keep this pass reviewable.
- Pattern/Mirror/gear_request bodies as `of` targets (see above - not a
  temporary v1 narrowing, a real structural limit of "trace back to a
  sketch entity").
- Resolving an edge a prior Fillet/Chamfer created (see above - permanent,
  not a gap this mechanism can close for any CAD kernel).
- Any mid-execution LLM call - this stays fully within `03`'s "translator
  execution is LLM-call-free and deterministic" property; the LLM only
  ever needs to know a sketch entity's `local_id`, which it already has at
  plan-authoring time under the existing schema.

## Tests (once the spike confirms real behavior)

Mirroring `03`'s own Spike 2 discipline (`backend/tests/test_ai_plan_
validate.py`'s existing "fillet-then-select-again multi-step case"
pattern): for each Feature type the spike confirms, a test building a
deliberately asymmetric profile (so a heuristic selector genuinely
couldn't have picked the same edge unambiguously) and confirming
`edge_from_sketch_line` resolves to the geometrically correct single edge,
plus a negative test confirming a `sketch_line_ref` naming a line from the
*wrong* Sketch (or a non-`sketch_line` step) fails plan validation with a
clear referential error, matching every other `local_id` reference's
existing failure mode in `05-backend-plan-validation.md`.
