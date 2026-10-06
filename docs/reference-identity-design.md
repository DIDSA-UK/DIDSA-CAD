# Reference identity: how a Sketch follows upstream geometry

Written 2026-10-06 (Session A of `DIDSA-VR/docs/handover-references-overhaul.md`). Implements the fix for the findings in `docs/roadmap.md` "Reference drift".
Code: `backend/app/sketch/reference_signature.py` (pure rules), `backend/app/document/reference_signature.py` (OCCT measuring),
`backend/app/document/reference_history.py` (OCCT history), `refresh_external_references` / `make_external_vertex_reference` in `backend/app/document/create_plane.py`,
the routes in `backend/app/document/router.py`. Tests: `backend/tests/test_reference_identity.py`, `backend/tests/test_reference_follows_upstream_topology_change.py`.

## The problem

A Sketch's `external_references` entry was `body_id` + a raw OCCT vertex index (`topexp.MapShapes` order). Any upstream edit that changes topology (a fillet moved to
another edge, a second edge added) renumbers the vertices. The reference then still *resolved*, to a different corner, and `has_lost_reference` stayed false:
"succeeds, wrongly". SolidWorks does not do this: identity comes from the feature history, with geometric matching as a fallback, and a reference that cannot be
found is loud (a dangling dimension) and recoverable (re-attach).

## What a reference carries now

`ExternalVertexReference` = `body_id`, `vertex_index` (unchanged) plus two optional, `compare=False` fields (so re-pick idempotence still matches on the first two):

* **`signature: VertexSignature`**, captured at creation and refreshed whenever the reference is confirmed healthy:
  * `position` in the Body frame (the Part-local frame every Body shape is in; an assembly placement is applied outside, so it never disturbs this);
  * the **topological fingerprint**: `valence` (distinct incident edges) and, per adjacent face, the outward unit normal at the vertex and the surface kind
    (plane / cylinder / ...). Position is *not* part of the fingerprint: a depth change or dimension edit moves a vertex without changing what it is;
  * `edge_directions`: unsigned unit tangents of the incident edges at the vertex. **This is where an edge's direction lives.** An edge reference is two vertex
    references plus a construction line (see "Edges" below), so no separate edge signature exists; the tangents are only a tie-break;
  * `body_diagonal`: the Body's bounding-box diagonal at capture. **Every tolerance is relative to it** (a 10 mm bracket and a 10 m frame behave the same).
* **`lineage: LineageOrigin`** (OCCT history, below): the first Feature whose output *created* the vertex, the vertex's index in that output, its signature there.

Both are persisted in the native format (`native_format.py`, `external_references[*].signature` / `.lineage`, written only when present). A file without them loads
exactly as before (`None`); its first refresh adopts the signature of whatever the index names (trust once), and lineage appears the next time the reference is made or re-attached.
No schema-version bump: the change is additive.

## Re-validation on every refresh

`refresh_external_references(part, sketch, bodies, excluded_ids, history)` runs on every `GET .../features` (via the SketchFeature response), against the Part *as it
stood at the Sketch's place in the feature history* (`excluded_feature_ids_after`: later features never move a Sketch's references; this is SolidWorks' behaviour and
unchanged). For each reference, in order:

1. **Fast path** (measures only the one vertex): the stored index names a vertex with the same fingerprint, within 5 % of the diagonal of where it was -> `ok`.
2. **Signature decision** (`decide_reference`, measures every vertex of that Body):
   * index still has the fingerprint, and no identical-looking twin is nearer to the old position -> `ok` (a big parametric move is fine);
   * exactly one vertex has the fingerprint -> `followed` if within 5 % of the diagonal of the old position, else `potentially_moved` (`unique_fingerprint_far`:
     it may be the same vertex after a large move, or the look-alike twin of one that is gone);
   * several have it -> the nearest one if it is within 5 % **and** at least 3x nearer than the runner-up (`potentially_moved`, `nearest_of_identical_vertices`), otherwise
     **lost, `ambiguous`**, with the candidates listed;
   * none has it -> a lone vertex within 1 % of the old position is `potentially_moved` (`fingerprint_changed_in_place`: the corner was reshaped in place); otherwise **lost** (`no_match`).
3. **OCCT history** (only when the reference has a lineage, only on this slow path; see below) refines the signature decision.

Outcomes: `ok`, `followed` (re-found at a new index; informational), `potentially_moved` (bound on weaker evidence: look at it), `lost` (never rebound). The new index is
persisted; a refreshed `ok` / `followed` also refreshes the signature (the vertex legitimately moves with parametric edits); `potentially_moved` keeps its *old* signature until
the user confirms it. A lost reference keeps its Point at the last known position (so the Sketch does not visually collapse) and is not touched until it resolves again or is re-attached.
The decisions of the last refresh live on `sketch.external_reference_decisions` (transient).

## OCCT history (c)

While a Part replays, operations that expose OCCT history report themselves (`note_operation`): `BRepFilletAPI_MakeFillet` / `MakeChamfer`, `BRepAlgoAPI_Cut`, `BRepAlgoAPI_Fuse`
(when its operands were not converted), `ShapeUpgrade_UnifySameDomain.History()`. `_apply_feature_to_bodies` closes each Feature step into a `StepRecord` (Body before, Body
after, the operations in between) **only while a trace is being recorded**, i.e. never on the normal cached path.

*Carrying a vertex across a step* (`HistoryTrace.forward`): the same TShape still in the result survives; else whatever `Modified()` / `Generated()` says it became; else, if the
step had no history for it (an operation without a hook: Shell, Mirror, Move Face, ...), a lone vertex of the result at exactly the same position; else it was consumed.
`IsDeleted()` is deliberately not used to decide survival: measured on OCCT 7.9, `BRepFilletAPI_MakeFillet.IsDeleted()` is True for vertices the fillet never touched.

*At creation* the steps are walked backwards from the picked vertex to the step that created it (nothing in that step's input maps to it) -> `LineageOrigin`.
*On a slow-path refresh* the Part is replayed with recording on (uncached, memoised per Part + feature fingerprints, 4 entries), the origin vertex is re-located in the origin
Feature's new output by signature, and walked forward through every later step to the final Body: one survivor -> `followed` (`method=history`); none -> **lost,
`consumed_by_<feature id>`** (and it is *not* rebound to a look-alike, which is what the plain signature search would have done); several -> narrowed by signature, else ambiguous.

Not wired (falls back to position-at-the-step, then signature): Shell, Draft/thicken, Move/Delete Face, Mirror/Pattern, Loft/Sweep/Revolve internals, Split, and a Fuse whose operand
needed Bezier preparation. Adding a hook is one `note_operation(maker)` call after the operation succeeded.

## Never silent

* `lost` -> `has_lost_reference` true and the Point ids in `lost_reference_point_ids`.
* `potentially_moved` -> `moved_reference_point_ids` (bound, so the Sketch still solves; the client shows a warning).
* `followed` -> `followed_reference_point_ids` (informational).
* `reference_reasons[point_id]` carries the machine-readable reason (`no_match`, `ambiguous`, `body_missing`, `sketch_plane_unresolved`, `refresh_failed`,
  `consumed_by_<feature>`, `unique_fingerprint_far`, `nearest_of_identical_vertices`, `fingerprint_changed_in_place`, `history`, `unique_fingerprint`).

## Routes (all under `/document/parts/{part_id}/features/sketch/{feature_id}`)

| Route | Notes |
|---|---|
| `POST external-references`, `POST external-references/edge`, `POST convert-entities/vertex`, `POST convert-entities/edge` | **Unchanged wire shape.** Now capture signature + lineage, and resolve against the Sketch's causal snapshot (the Part as it stood after the features before the Sketch) rather than the final Part; identical for a last-in-history Sketch. Convert is still re-pick idempotent and a re-pick does no extra work. |
| `GET external-references` | New. `[{point_id, body_id, vertex_index, status, reason, method, candidates}]` after a fresh refresh. |
| `POST external-references/{point_id}/reattach` `{body_id, vertex_index}` | New. Points an existing reference Point at a different vertex; the Point id (and every line / dimension on it) is kept; signature + lineage re-captured. 404 if not an external reference of this Sketch, 422 `missing_reference` for a bad vertex. |
| `POST external-references/{point_id}/confirm` | New. "Yes, that is the right vertex" for a `potentially_moved` reference: re-captures its signature. 409 if lost. |
| `GET features` | `SketchFeatureResponse` gains `lost_reference_point_ids`, `moved_reference_point_ids`, `followed_reference_point_ids`, `reference_reasons`. `has_lost_reference` unchanged in meaning (and now also true for a reference that is lost because it is ambiguous). |

All additions are optional on the wire (defaults `[]` / `{}`), so the VR design table's `sketch_session.gd: ensure_reference` (`convert-entities/vertex` / `edge`) needs no change.

## Edges

A converted / referenced edge is two vertex references and a (construction) line, reused if present; the line follows its endpoints, so edge identity is the identity of both
endpoint references (and each endpoint's `edge_directions` carry the edge direction). The centre Point of a converted Arc / Circle is still a plain, non-associative Point
(unchanged, noted in the VR handover): it has no signature and does not follow.

## SubShapeRef consumers with the same weakness (listed, not changed)

The same silent-rebind failure is possible wherever a raw `SubShapeRef` index is stored and resolved after an upstream topology change. Not done here (each needs a signature field on
`SubShapeRef`, its schema, native-format and several routes; the machinery above is reusable: `BodyVertexMeasurer`, `decide_reference`, `ReferenceHistory`, and face / edge analogues of
the signature):

* `FilletFeature.edge_refs`, `ChamferFeature.edge_refs` (+ `ChamferEdgeOptions.face_ref`) - highest value: moving an upstream fillet can silently move a downstream one.
* `CreatePlaneFeature.face_refs` / `edge_ref` / `vertex_ref` / `point_refs` (the 2026-07-31 drift fix handled the causal snapshot, not a mismatch within it).
* `PatternDirectionRef.edge_ref` / `PatternAxisRef`, `MirrorFeature.mirror_plane` face refs.
* Shell / Delete Face / Move Face / Draft face selections, Measure and Mate topology refs (mates reference Occurrence faces).

## Open decisions / limits

* A `followed` outcome persists the new index silently apart from the informational list; if a stricter "always ask" mode is wanted, make `followed` also `potentially_moved`.
* A vertex consumed by an edit *and* an identical twin existing is lost (history) or ambiguous (signature), never rebound; the cost is a flag after some edits a human would call fine.
* Tolerances (`SEARCH_TOLERANCE_REL` 0.05, `UNAMBIGUOUS_RATIO` 3, `SOFT_TOLERANCE_REL` 0.01, `NORMAL_TOLERANCE_DEGREES` 8) are first cuts, named constants in `reference_signature.py`; no on-device tuning yet.
* Cost: a refresh on the fast path measures one vertex per reference; the slow path measures a whole Body and (for a lineage reference) replays the Part once per edit (memoised).
  A very heavy Part (a complex herringbone gear) pays one uncached replay the first time one of its references goes stale.
