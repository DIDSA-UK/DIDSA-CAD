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
