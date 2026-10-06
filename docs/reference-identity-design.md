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
| `GET external-references` | New. `[{point_id, body_id, kind, vertex_index, status, reason, method, candidates}]` after a fresh refresh (`kind` is `vertex`, or `circle_centre` where `vertex_index` is a circular EDGE index). |
| `POST external-references/{point_id}/reattach` `{body_id, vertex_index}` or `{body_id, edge_index}` | New. Points an existing reference Point at a different vertex - or, for a `circle_centre` reference, a different circular edge (`edge_index`; the Circle / Arc on it moves and resizes with it); the Point id (and every line / dimension on it) is kept; signature (+ lineage for a vertex) re-captured. 404 if not an external reference of this Sketch, 422 `missing_reference` for a bad index, `edge_required` / `vertex_required` for the wrong payload kind, `not_a_circular_edge`, `not_coplanar`. |
| `POST external-references/{point_id}/confirm` | New. "Yes, that is the right vertex" for a `potentially_moved` reference: re-captures its signature. 409 if lost. |
| `GET features` | `SketchFeatureResponse` gains `lost_reference_point_ids`, `moved_reference_point_ids`, `followed_reference_point_ids`, `reference_reasons`. `has_lost_reference` unchanged in meaning (and now also true for a reference that is lost because it is ambiguous). |

All additions are optional on the wire (defaults `[]` / `{}`), so the VR design table's `sketch_session.gd: ensure_reference` (`convert-entities/vertex` / `edge`) needs no change.

## Edges, and circle centres (item 4)

A converted / referenced straight edge is two vertex references and a (construction) line, reused if present; the line follows its endpoints, so edge identity is the identity of both endpoint references.

The **centre** of a converted circular edge (a hole, a boss, a cylinder's rim, an arc) used to be a plain, non-associative Point: an upstream edit that moved or resized the hole left the sketch circle behind, with no flag. It is now a
reference of `kind="circle_centre"` (`ExternalVertexReference.kind`; `vertex_index` then indexes the circular EDGE) carrying an `EdgeSignature` (curve kind, axis, adjacent faces; centre and radius ride along, not part of the fingerprint).
`refresh_external_references` re-finds the edge with the same rules as a vertex, then **moves the Circle with it**: the centre Point goes to the edge's centre and every other defining Point of the Circle (radius Point, the four cardinal Points) is
translated and scaled about it to the edge's new radius; an Arc only has its centre to move (its ends are vertex references). The provisional radius dimension is re-synced to the geometry. If the edge no longer lies in the Sketch's plane
(axis not parallel to the plane normal) the reference is **lost**, reason `not_coplanar`. `convert-entities/edge` makes the centre this way for both the full-circle and the arc branch (reused if the same edge is converted again); an
Arc's `FixedConstraint` is no longer needed (every Point of it is a live reference). A circle centre carries the EDGE lineage (OCCT history per edge): a rim consumed by an upstream fillet is therefore `consumed_by_<fillet>` (lost; the new circular edges are different edges even when one shares the centre), and only a reference without lineage (an old file, an untraced Part) falls back to the signature search's "potentially moved, `fingerprint_changed_in_place`". Re-attach picks a circular EDGE (`edge_index`); the flat app
lets the user tap one (the banner says so).

## SubShapeRef consumers (item 1)

The same silent-rebind failure existed wherever a raw `SubShapeRef` index was stored and resolved after an upstream topology change. Every `SubShapeRef` held by a Part's Features now has the sketch references' treatment, through ONE
mechanism (`app/document/subshape_identity.py`), not one per consumer:

* `SubShapeRef.signature` (`compare=False`, `repr=False`: equality, hashing and the body-cache fingerprint are unchanged) holds a `VertexSignature`, `EdgeSignature` or `FaceSignature`. Edge: curve kind, unsigned direction (axis for a circle), adjacent
  faces' normals / kinds at the midpoint; face: surface kind and the outward normal (planes, signed) or axis. Length, radius, area are not fingerprint. **Distances are measured so that trimming does not read as moving** (`shape_distance`): a
  straight edge by its distance from the stored LINE (a neighbouring fillet shortens it and shifts its midpoint), a circle by its centre, a plane by its offset along the normal, a cylinder / cone by its distance from the axis.
* `resolve_subshape_from_bodies` - the one function every consumer resolves through - honours a signature: the stored index is trusted while it still names a sub-shape with that fingerprint nearby, else the unique match is used, else it
  **fails closed** with the usual `missing_reference` 422, now carrying a `reason` (`no_match` | `ambiguous`). Nothing silently resolves to a look-alike any more, in replay or at create / update.
* Stamping and refreshing happen when a Feature's response is built (`_feature_response`: create, update and every `GET .../features`). A reference with no signature is stamped from the Bodies the Feature saw as its input
  (`bodies_before_feature`, read from the body-cache checkpoint chain, no replay) - at creation that is exactly the right moment; a file saved before signatures existed adopts on first view. A signed one is re-validated, the re-found index and a
  refreshed signature are persisted, and the response says what happened.
* Every Feature response (`FeatureResponseBase`, all 38) can carry `has_lost_reference`, `lost_references` / `moved_references` / `followed_references` (paths inside the Feature: `edge_refs[0]`, `face_refs[1].face_ref`, `edge_ref`, ...) and
  `reference_reasons`. A Feature whose reference is lost keeps being skipped during replay as before (Fillet / Chamfer log and skip), but is now **flagged** instead of silent. The way out is to re-select in its own edit panel (the tree says so);
  there is no separate re-attach route for these.
* Covered by walking every dataclass field of every Feature, so Fillet / Chamfer `edge_refs` and `ChamferEdgeOptions.face_ref`, Create Plane (`face_refs`, `edge_ref`, `vertex_ref`, `point_refs`), Pattern direction / axis refs, Mirror
  `mirror_plane`, Shell / Delete Face / Move Face selections, Offset Surface, ... are all in. BODY references (nothing to sign) and assembly mate references (another Part's Bodies) are not.
* Native format: signatures are saved with each `SubShapeRef` (tagged by kind), a file without them loads unsigned.

* **OCCT history, per edge and face** (the same machinery as for sketch vertices, generalised by sub-shape kind - see "OCCT history" above). A reference stamped while the Part has at most `HISTORY_MAX_FEATURES` (80) Features also stores a
  `LineageOrigin` (`SubShapeRef.lineage`, `repr=False`, saved in the native format): the Feature whose output created the sub-shape. The stamp comes from ONE recorded replay of the whole Part (`HistoryTrace.inputs` keeps the Bodies each Feature found,
  so a mid-history reference can start its backward walk from them), shared through the trace memo by every reference of every Feature. When a stored index goes stale the refresh carries the origin forward to the Feature's own input with
  `Modified()` / `Generated()` (measured on OCCT 7.9: a Fillet reports the faces next to the rounded edge as Modified, the rounded edge as consumed with only a *generated face*; a Cut reports split edges / faces as Modified and removed ones as nothing): one
  survivor is followed, none is `consumed_by_<feature>`, several are narrowed by signature. **A consumed sub-shape is also recorded on the reference (`SubShapeRef.lost_reason`, in `repr` so the body cache is invalidated)** and replay then fails closed on it - the
  case that matters: an edge or face consumed upstream while an identical-looking twin remains, which the signature search alone would have bound (flagged "potentially moved") or called ambiguous. The marker is cleared by the next refresh that finds the
  sub-shape again (an undone edit heals). Replay itself stays signature-only. Circle centres use the edge lineage too.

Limits of this half: the history verdict is only recorded by a refresh, so after an upstream edit that consumes a sub-shape the Feature keeps replaying signature-only until the next `GET .../features` (the client refreshes features after every edit); a Part above the feature cap is not traced (signature search only);
every reference creation / first view makes one recorded replay (uncached, memoised per Part state); the PATCH routes validate an edit's edge indices against the Part as it
stands INCLUDING later features, which is pre-existing and unchanged (it can refuse or misread an index when editing a non-last feature); a coplanar split of a face leaves two identical-looking faces (flagged ambiguous, by design).

## Open decisions / limits

* A `followed` outcome persists the new index silently apart from the informational list; if a stricter "always ask" mode is wanted, make `followed` also `potentially_moved`.
* A vertex consumed by an edit *and* an identical twin existing is lost (history) or ambiguous (signature), never rebound; the cost is a flag after some edits a human would call fine.
* Tolerances (`SEARCH_TOLERANCE_REL` 0.05, `UNAMBIGUOUS_RATIO` 3, `SOFT_TOLERANCE_REL` 0.01, `NORMAL_TOLERANCE_DEGREES` 8) are first cuts, named constants in `reference_signature.py`; no on-device tuning yet.
* Cost: a refresh on the fast path measures one vertex per reference; the slow path measures a whole Body and (for a lineage reference) replays the Part once per edit (memoised).
  A very heavy Part (a complex herringbone gear) pays one uncached replay the first time one of its references goes stale.
