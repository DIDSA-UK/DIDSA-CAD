# Workstream 12 (spike run, schema locked; implementation not yet built): Provenance-Based Edge Selectors

Read `00-conventions.md` first. This started as a scoping doc, like `03`'s
own original "Open design problem" section before its spike ran. **The
spike below has now run for real, against real `pythonocc-core`** (real
`BRepPrimAPI_MakePrism`/`BRepPrimAPI_MakeRevol`/`BRepOffsetAPI_
MakePipeShell` shapes, not a hand-built fixture) - see "Spike findings
(2026-09-01)" below. The mechanism is confirmed and the schema shape is
locked; the backend/`body_cache.py` implementation itself is still real,
not-yet-built work (a follow-up session's job), same "confirmed workable,
not yet wired up" state `03`'s own Spike 2 left its four selectors in
before workstream 4 actually built the translator around them.

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

## Locked schema shape

**Two new selectors, not one** - the spike found the vertex-based one is
strictly simpler and more robust than the edge-based one (see findings
below), so both are worth shipping rather than picking one. Extend
`EdgeSelectorKind` (`ai_plan_schemas.py`):

```python
EDGE_FROM_SKETCH_POINT = "edge_from_sketch_point"  # the safe, primary case
EDGE_FROM_SKETCH_LINE = "edge_from_sketch_line"    # the more powerful, slightly riskier case
```

and give `EdgeSelector` new optional fields, following the exact pattern
`direction` already establishes for `ALL_EDGES_OF_FACE_AT_POSITION`
(required iff that one selector is used, ignored otherwise):

```python
class EdgeSelector(BaseModel):
    selector: EdgeSelectorKind
    of: str
    direction: CardinalDirection | None = None
    # Required iff selector == EDGE_FROM_SKETCH_POINT.
    sketch_point_ref: str | None = None
    # Required iff selector == EDGE_FROM_SKETCH_LINE.
    sketch_line_ref: str | None = None
    # EDGE_FROM_SKETCH_LINE only, optional (default False): the edge as
    # originally drawn, on the profile's own base/start face (False), or
    # its generated counterpart on the swept-to end - Extrude's end face,
    # Revolve's end-angle face, Sweep's path-end face (True). Ignored for
    # EDGE_FROM_SKETCH_POINT, which has no such ambiguity (see findings).
    far: bool = False
```

`sketch_point_ref`/`sketch_line_ref` name an earlier `sketch_point`/
`sketch_line` step's `local_id` - one belonging to the same profile Sketch
that `of`'s Body-producing step consumed (a referential-validity rule for
`05-backend-plan-validation.md` to add, mirroring `revolve.axis_ref`'s
existing "must resolve to a sketch_line step" check). Each resolves to
exactly one edge, never a selector-of-many like the four heuristics.

`chamfer`/`fillet`'s `edges` field shape is completely unchanged - this is
additive to `EdgeSelectorKind`/`EdgeSelector` only, `FilletFeature`/
`ChamferFeature` themselves (which only ever store the final resolved
`SubShapeRef` list) need zero changes.

## Per-Feature-type mechanics (confirmed by the spike)

**Extrude** (`extrude.py`, `BRepPrimAPI_MakePrism`). Confirmed against an
asymmetric quadrilateral profile (a heuristic selector genuinely couldn't
pick one edge of it unambiguously):
- `.Generated(vertex)`/`.Generated(edge)` return **empty** when queried
  against edges/vertices obtained by exploring the *wire* object held
  before `BRepBuilderAPI_MakeFace(wire)` wraps it - a real object-identity
  gotcha, not a dead end: `MakeFace` does not preserve the wire's own edge/
  vertex object identity into the face it builds. The fix is simple and
  makes the eventual implementation easier, not harder: **always
  re-explore edges/vertices from the exact `TopoDS_Face` object actually
  passed into `BRepPrimAPI_MakePrism`** (i.e. `face_for_profile`'s return
  value in the real code, after any transform - never a wire held earlier
  in the pipeline).
- Queried correctly (from the face), `.Generated(vertex)` returns exactly
  one shape, an EDGE - the lateral (vertical) edge at that corner. Clean,
  unambiguous, one call, no further disambiguation needed - this is
  `EDGE_FROM_SKETCH_POINT`, and it's exactly the same idiom
  `gear._apply_root_fillet` already ships. (One real wrinkle, handled
  automatically rather than needing special-casing: `TopExp_Explorer` over
  a face's vertices visits each real corner twice, undeduplicated - both
  duplicate instances of a corner returned bit-identical `Generated()`
  results in every case tested, so either one can be used safely.)
- Queried correctly, `.Generated(edge)` returns exactly one shape, a FACE
  (the lateral wall swept from that edge) - always exactly 4 edges for a
  straight profile edge: the original edge itself, its far/generated
  counterpart, and two vertical connectors. The far edge is picked by a
  purely topological rule, confirmed on every edge of the test profile:
  **the one edge of those 4 that shares no vertex with the originally-
  queried edge** - no coordinate/vector-direction math needed at all,
  which matters because it should generalize cleanly to Revolve's curved
  counterpart edges too (confirmed below). This is `EDGE_FROM_SKETCH_LINE`
  with `far=True`; `far=False` is just the original queried edge itself,
  needing no `.Generated()` call at all (only mapping it into the final
  Body's own real edge index, straightforward since it's still present
  unmodified in the result).
- For every case above, the resolved edge's `topexp.MapShapes`-based index
  (the same 0-based scheme `ai_plan_edges.py` already uses) was confirmed
  directly against the real coordinates of the edge OCCT returned - it is
  a valid, directly-usable `SubShapeRef.index`.
- `wire_for_profile`'s Circle/Ellipse/Text single-entity profiles need no
  mapping at all (the whole wire is unambiguously "that one entity"); the
  `BRepBuilderAPI_MakePolygon` fast path and the mixed Line/Arc/Spline path
  both need a `(sketch_entity_id -> face vertex/edge)` map built at
  construction time (not confirmed for the mixed-chain path specifically
  in this spike, which used the polygon path only - a real, disclosed gap
  for the implementation session to close, not expected to behave
  differently in principle since it also produces a straight-edge wire).

**Revolve** (`revolve.py`, `BRepPrimAPI_MakeRevol`). Confirmed against an
asymmetric trapezoidal profile (a bushing-style cross-section), for both a
90° partial revolve and a full 360° revolve:
- `.Generated(vertex)` behaves identically to Extrude - exactly one
  generated EDGE (the circular/helical arc that vertex swept through) -
  in **both** the partial and full case. `EDGE_FROM_SKETCH_POINT` is
  equally clean and reliable on Revolve.
- `.Generated(edge)` behaves like Extrude for a **partial** revolve
  (exactly one generated FACE, 4 edges, same "shares no vertex" far-edge
  rule applies) - **but for a full 360° revolve, a profile edge lying
  radially (perpendicular to the revolution axis, both endpoints at
  different radii) can generate zero shapes at all** - the flat annular
  face it sweeps into apparently isn't tracked as "generated from" that
  edge the way a curved lateral face is. **This must fail closed**
  (`edge_selector_no_matching_edges`, matching `ai_plan_edges.py`'s
  existing convention exactly - the four heuristics already fail this way
  rather than returning an empty selection silently), not attempt a
  fallback guess. `EDGE_FROM_SKETCH_LINE` is real and mostly reliable on
  Revolve, with this one confirmed, boundable, disclosed exception -
  `EDGE_FROM_SKETCH_POINT` has no equivalent gap and should be considered
  the safer default recommendation to the LLM for Revolve bodies.

**Sweep** (`sweep.py`, `BRepOffsetAPI_MakePipeShell`). Confirmed against a
straight path with an asymmetric quadrilateral section - and, contrary to
this doc's original "highest risk" framing, **this was the cleanest of the
three**: `.Generated(edge)`/`.Generated(vertex)` both work correctly when
queried directly against the *original* section wire's own edges/vertices
(no `MakeFace`-style object-identity gotcha - `pipe_maker.Add(wire)` keeps
the wire's own edges/vertices addressable, unlike `MakePrism`'s face-
wrapping step). Both selectors work exactly as they do for Extrude's
polygon fast path. Not yet tested: a curved (Arc/Spline) path or section,
or the multi-hop `MakePipeShell.Add()`-per-edge pattern `sweep.py`'s own
comments describe for a mixed-entity path - a real, disclosed gap for the
implementation session, not expected to change the underlying idiom.

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

## Spike findings (2026-09-01): confirmed against real OCCT geometry

Run in a freshly-bootstrapped real backend environment (`miniforge` +
`mamba env create -f backend/environment.yml`, the same recipe `03`'s own
"Environment note for future sessions" and this project's prior gear-
design/bevel spikes all used - `pythonocc-core=7.9.3=novtk*`, confirmed
importable). Full existing backend test suite re-run against the fresh
environment first, per this project's own standing practice, to rule out
the environment itself as a source of any finding below - see this doc's
own "Full-suite verification" section. Scripts themselves are scratch,
not committed, per this project's spike convention - built real
`BRepPrimAPI_MakePrism`/`BRepPrimAPI_MakeRevol`/`BRepOffsetAPI_
MakePipeShell` shapes directly (no shortcut access to anything the real
`extrude.py`/`revolve.py`/`sweep.py` code paths wouldn't also have), using
deliberately asymmetric profiles specifically so a heuristic selector
could not have picked the same edge - the case that actually justifies
this workstream, not just a plain box repeating `03`'s own Spike 2.

**Headline result: the mechanism works, for both new selectors, on all
three Feature types**, with two confirmed real gotchas (both now written
into the "Per-Feature-type mechanics" section above, not left as open
questions):

1. `BRepPrimAPI_MakePrism`/`BRepPrimAPI_MakeRevol` require querying
   `.Generated()`/`.Modified()` against edges/vertices re-explored from
   the exact `TopoDS_Face` object actually passed into the builder - a
   separately-held wire reference from earlier in the pipeline returns
   empty results, silently, rather than an error. This is a real
   implementation-order constraint (re-derive the sketch-entity mapping
   from the *same* face object right before/as the builder runs), not a
   dead end - and `BRepOffsetAPI_MakePipeShell` doesn't share this
   constraint at all (see below), so it's specific to the face-wrapping
   step `MakePrism`/`MakeRevol` both need and `MakePipeShell` doesn't.
2. A full 360° revolve's radially-oriented profile edges (perpendicular
   to the axis) can have no `.Generated()` result at all for
   `EDGE_FROM_SKETCH_LINE` - confirmed, bounded, and must fail closed
   (`edge_selector_no_matching_edges`) rather than guess. This has no
   effect on `EDGE_FROM_SKETCH_POINT`, which had zero failures across
   every case tested (partial revolve, full revolve, Extrude, Sweep) -
   this is why the schema above ships both selectors rather than
   `EDGE_FROM_SKETCH_LINE` alone, and why `EDGE_FROM_SKETCH_POINT` is the
   one worth recommending to the LLM by default in the system prompt once
   built.

**Genuinely surprising result, reversing this doc's original risk
ranking**: Sweep (`BRepOffsetAPI_MakePipeShell`) was the *cleanest* of the
three, not the riskiest as originally flagged from `sweep.py`'s own prior
API-gotcha history - `.Generated()` worked directly against the section
wire's own original edges/vertices with no object-identity gotcha at all.
Extrude and Revolve share the face-wrapping gotcha (both go through
`face_for_profile`); Sweep's `pipe_maker.Add(wire)` doesn't wrap into a
face first, so it doesn't inherit that constraint. Worth remembering for
future spikes on this codebase: an API's *prior* history of surprises in
one context doesn't reliably predict how it behaves for a materially
different query (shape history vs. the pipe-shell construction quirks
`sweep.py`'s own comments document, which are about section/transition
handling, not `.Generated()`).

**Not yet tested, real disclosed gaps for the implementation session**:
the mixed Line/Arc/Spline wire-construction path (only the
`BRepBuilderAPI_MakePolygon` straight-edge fast path was spiked); a curved
Sweep path or section; and whether option 1's `body_cache.py` extension
(the provenance dict riding alongside the existing per-step snapshot)
threads cleanly through its checkpoint-chain reuse logic end to end - this
spike confirmed the OCCT query mechanics in isolation, not the full
per-step-cache wiring, which is real implementation work still ahead
rather than a spiked-and-confirmed fact.

If a future implementation pass finds the mixed-chain path or curved
Sweep genuinely doesn't extend cleanly, landing this for the straight-
edge/straight-path cases confirmed here - disclosing the rest as a known
gap - is a legitimate partial-build outcome, not a failure of the
workstream, matching the standing allowance this doc already carried.

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

## Tests (once the implementation lands)

Mirroring `03`'s own Spike 2 discipline (`backend/tests/test_ai_plan_
validate.py`'s existing "fillet-then-select-again multi-step case"
pattern): for each Feature type confirmed above, a test building the same
kind of deliberately asymmetric profile this spike used and confirming
both `edge_from_sketch_point` and `edge_from_sketch_line` (`far=False` and
`far=True`) resolve to the geometrically correct single edge; a full-360°
Revolve test confirming a radial `edge_from_sketch_line` fails closed with
`edge_selector_no_matching_edges` rather than silently returning nothing;
a multi-step test mirroring Spike 2's own "fillet-then-select-again" case,
confirming a provenance selector still resolves correctly against a body a
prior Fillet already modified, as long as it targets a different original
sketch entity; and a negative test confirming a `sketch_point_ref`/
`sketch_line_ref` naming an entity from the *wrong* Sketch (or the wrong
step kind) fails plan validation with a clear referential error, matching
every other `local_id` reference's existing failure mode in
`05-backend-plan-validation.md`.

## Full-suite verification (this spike session)

`pytest -n auto` re-run against the freshly-bootstrapped environment
before any spike script ran, to confirm the environment itself wasn't a
confound: **1941 passed, 0 failed** (25m19s wall-clock) - clean, so
nothing in the spike findings above is attributable to the environment
build itself.
