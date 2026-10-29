# Point Merge, and the VR sketcher catching up: plan

This doc finishes item 2b of [`sketcher-feedback-2026-10-29-plan.md`](sketcher-feedback-2026-10-29-plan.md) (a Merge action for
two points) and folds in the VR side of that doc's handoff: the DIDSA-VR design-table sketcher gets the line-end and loop-closing
rules, the inferred relationships, the alignment guides and Merge. It is written for the session that implements it.

Checked against DIDSA-CAD `main` at `c7014a5` and DIDSA-VR `main` at `d7c7fb4`. Line numbers drift, so search for the named symbol.
Nothing in this plan has been run. Every finding below comes from reading the code.

"Inferred relationships" are the constraints a sketcher adds by itself while you draw: horizontal, parallel, tangent and so on.
The owner's decisions on the open points are at the [end](#decisions-owner-2026-10-29); they are folded into the steps.

## Order and size

| Step | Repo | What | Depends on | Size |
|---|---|---|---|---|
| **M1** | CAD backend | `POST /sketches/{id}/points/merge` and `PUT /sketches/{id}/state` (restore, for undo) | nothing | medium |
| **M2** | CAD client | Merge in the flyout, undo, ways to reach two stacked points | M1 | small to medium |
| **V1** | VR | Fix what is there: origin welding, unheld midpoint and on-curve snaps, chain not ending on a closed loop | nothing | small |
| **V2** | VR | Line end resolved where the ghost shows it (port of flat item 2): snapped end re-tested against points, closing edge gets H/V | V1 | small |
| **V3** | VR | Inferred relationships: tangent, point on curve, collinear, parallel, perpendicular on a line end; concentric on centres | V2 | medium |
| **V4** | VR | Alignment guides (port of flat item 3) | V2 | small to medium |
| **V5** | VR | Merge in the Select menu, stacked-point picking | M1, V1 | small |
| M3 (deferred, not now) | both | "Close gaps": merge every pair of unjoined points closer than the snap radius, in one call | M1, M2, V5 | small |

V1 to V4 do not need M1, so the VR work can start in parallel with the backend. Do one commit per step. Each step ends with its
test gate green (see [Verification](#verification)).

## Progress

Built in the order of the table above, one commit per step, on branch `ccr-a2e167db-tvjb7l` in both repos (DIDSA-CAD: M1, M2; DIDSA-VR: V1 to V5). Each step's gate was green
before the next. **Nothing was looked at on a headset or a device.**

| Step | Repo | What landed | Tests |
|---|---|---|---|
| M1 | CAD | `app/sketch/point_merge.py` (`merge_keep_order`, `merge_points`, the collapse table in `_collapse`), `Sketch.copy_state_from`, the routes `POST /sketch/sketches/{id}/points/merge` and `PUT /sketch/sketches/{id}/state`, `points_referenced_by_features` in `app/document/graph.py` (walks every Part feature generically for a `SketchEntityRef` of type point) | `backend/tests/test_sketch_point_merge.py` (46): the generic "no absorbed id left in `sketch_to_dict`" test (it fails if the rewrite skips list fields: checked by breaking it), one test per collapse row and per refusal (`sketch_to_dict` equal to `before` after each), the kept-point rule (Fix, external reference, a Loft's `reference_point`, a rectangle corner over a loose end, provisional and Coincident not counted, a tie), a three-way corner, `conflict` rolled back, the restore round trip, the `SketchFeature` still resolving its sketch. Core suite 2721 passed, gears 413 (bevel pairs not re-run) |
| M2 | CAD | Merge in the flyout (`ConstraintOptionType.merge`), `point_merge_rule.dart` (the Dart `mergeKeepOrder`), the kept-point ring on the flat canvas and in Orbit View, snapshot undo (`mergePoints` / `restoreSketchState`, `_reloadLocalSketch`), pick cycling on stacked points, Merge from a selected Coincident glyph | `sketch_controller_test.dart` group "Point Merge" (10; the fake backend has both routes on its own model), `sketch_point_merge_rule_test.dart` (5, the backend's kept-point cases). `flutter test` 3326 passed, 43 skipped; `flutter analyze` 222 infos, all the SDK's `material.dart` deprecation, none new |
| V1 | VR | origin not welded, held midpoint and on-curve snaps, a closed run ends | `design_table_logic.gd`, `sketch_session.gd`, `e2e_sketch_select.gd` follows the unwelded start |
| V2 | VR | the line end resolved where the ghost shows it, closing side with H/V | `design_table_logic.gd`, `sketch_session.gd` |
| V3 | VR | inferred relationships, woken lines, concentric centres, the Infer switch | `design_table_logic.gd` (the resolver and `woken_lines.gd`), `sketch_session.gd`, `design_table_editing.gd`, new `e2e_sketch_infer.gd` |
| V4 | VR | alignment guides | same files |
| V5 | VR | Merge in Select, kept-point ring and name, pick cycling, "2 points here" | `sketch_session.gd` (with the fake's two new routes), `design_table_editing.gd`, new `e2e_sketch_merge.gd` against a backend with M1 |
| M3 | both | **Not built** (owner, 2026-10-29) | |

**Where the code differed from the plan** (the code was followed):

- `Sketch.merge_points` is a module, `app/sketch/point_merge.py`, not a method in `models.py`: its last step needs `app.sketch.solver`, which imports `models`. `Sketch` got
  `copy_state_from` instead, shared by the rollback and by `PUT .../state`.
- The routes sit under the sketch router's `/sketch` prefix: `/sketch/sketches/{id}/points/merge`, not `/sketches/{id}/points/merge`.
- An Ellipse's four axis ends (major, minor and their negatives) are refused as quadrant points, with a Circle's cardinal points. The plan said "cardinal (quadrant) point"; the code
  has no separate name for the ellipse's.
- A provisional `DistanceConstraint` that ends up measuring a point to itself is **dropped** and reported, not refused as `dimension_between`: it is a shape tool's placeholder size,
  not a dimension the user wrote, and the solver skips it. Any other self-distance is refused as planned.
- The flat client's inference toggle ("suppress for this tool", `toggleInferenceSuppressed`) is not reset anywhere on a tool change: it stays as set until toggled, the same as the
  VR Infer switch. No difference to note.
- The plan names the icon `tool_infer` while the deck's utility buttons use plain names (`snap`, `eye`): the VR icons are `infer` and `infer_off`.
- The plan expected the flat canvas to have no tappable Coincident glyph; it does draw one (`sketch_canvas.dart`, `_constraintLabelCenter`) and selecting it goes through the same `selectConstraint`, so
  Merge from a selected Coincident glyph works on the flat canvas as well as in Orbit View, besides pick cycling.
- The environment: today's Flutter master (`6e16887f`, 29 Oct) crashes at start-up when run as root ("Dependency cycle detected: Analytics -> Cache -> Xcode"), so the client was
  tested on master of 27 Oct (`4e9c63a8`) with a local tag for its version. CI uses its own pinned setup.

**Not verified (needs a headset or a device):** the 15 mm inference reach and the 6 mm alignment tolerance in VR; whether the "woken" lines feel natural with a laser; the look of
the dashed guides, the lit woken lines and the glyph on the sheet; the stacked-point "pull twice" flow and the "2 points here" line; the ring round the kept point in either client;
the Infer switch's size and place on the deck; the flat client's pick cycling and ring on a device. The rest of the numbers (4 and 6 degrees, 12 mm) are the flat app's.

---

## 1. What is there, checked for validity, best practice and intuitive use

### 1.1 The 2b sketch: what holds and what has to change

2b was a first sketch. Reading the model code changes six things.

1. **The sketch import route cannot be the undo snapshot.** `POST /sketches/import` (`router.py`, `import_sketch`) always gives the
   sketch a **new id** ("never the id the export happened to carry"). A Part's `SketchFeature` points at the sketch by id, so undo
   through import would orphan the feature. `sketch_to_dict` / `sketch_from_dict` (`app/document/native_format.py`) do keep every
   point, entity and constraint id, and cover reference ids, reference dimensions, label placements and pattern / mirror instances.
   So the serialisation is fine. What is missing is a route that puts it back **in place**. M1 adds `PUT /sketches/{id}/state`.
2. **"Keep the one with more references" needs to be exact, and visible.** Owner's decision (2026-10-29): rank the points, then
   fall back to selection order. Anchored first, then the point with more constraints on it, then the first selected (exact rule in
   M1). The kept point stays where it is and the others move onto it. Both clients highlight the point that will be kept while
   Merge is offered, so the rule is never a surprise.
3. **The refusal list was too wide in one place and too narrow in others.**
   - Too wide: "two defining points of the same Rectangle, Polygon or Slot" was listed, but merging a rectangle corner with a
     *loose* line end is the main use case and is fine. The real rule is "**any one entity** uses two of the points". That covers
     line ends, arc centre and end, a rectangle's two corners, a polygon's centre and vertex, a slot's two centres and a spline's
     through points in one check (`_entity_defining_point_ids`).
   - Too narrow: a **dimension between the two points** (a `DistanceConstraint` of 12 mm, say) contradicts the merge. Refuse and
     say which dimension to delete. Also refuse when the merge would leave **two entities on top of each other** (two lines that end
     up sharing both end points), and when **two** of the points are anchored.
   - Missing: **Part features can reference sketch points.** `SketchEntityRef` with `entity_type == POINT` is used by Loft
     (`reference_point`, `alignment_point`, `app/document/loft.py`) and by Create Plane's `PointRef.sketch_point_ref`
     (`app/document/create_plane.py`). Absorbing such a point would break the feature. The sketch layer cannot see features (it
     never imports `app.document`), so the route asks the document layer, the same function-local import pattern
     `export_sketch` already uses.
4. **The origin: do not quietly do a Coincident instead.** An action called Merge that adds a constraint is a surprise. Do not
   offer Merge when the origin is in the selection. Coincident is already offered next to it. The server refuses it as well.
5. **"Drops constraints that collapse" needs a precise table and a dedupe.** A constraint that names one point in two roles after the
   rewrite is either already satisfied (drop it) or degenerate (refuse). Two constraints that become identical must be reduced to one,
   because duplicate constraints are redundant and can stop the solver converging. See the table in M1.
6. **Two stacked points are the common case, and they cannot be picked one by one.** The usual reason to merge is two points on top
   of each other (a profile that looks closed and is not, which is what the item 2 bug produced). A tap only ever picks one of them.
   M2 and V5 add ways to reach the second one.

Kept from 2b: Merge sits next to Coincident and is offered for selected points only. It is atomic on the server. Undo is a snapshot
restore, not an inverse call. Coincident already closes a profile for extrude (`_coincident_canonical_ids` in
`app/sketch/profile.py`), so Merge is about tidiness: one point to drag, select and dimension instead of two plus a constraint.

### 1.2 The flat client's inference (what V3 ports)

`_combinedLineInference` (`sketch_controller.dart`) is the source to port. Its order is: existing point, then tangent or point on curve
(`_tangentOrPointOnCurveInference`), then the line's own H/V, then collinear (only with a line through the anchor point), then
parallel or perpendicular. Its tolerances are `lineSnapAngleDegrees` 4, `parallelPerpendicularSnapAngleDegrees` 4,
`collinearSnapAngleDegrees` 4, `tangentSnapAngleDegrees` 6, and 18 px for tangent, point on curve and concentric. The alignment
guides added by item 3 sit beside the line's own H/V.

One thing should **not** be copied as is. Parallel and perpendicular are tested against **every line in the sketch**
("any matching angle anywhere counts"). With a mouse and 4 degrees that is acceptable. With a laser, which shakes by a few
millimetres at arm's length, it means a 40 mm line drawn near some unrelated line's angle quietly becomes parallel to it. That is a
surprise constraint, and in a busy sketch an over-constraint. SOLIDWORKS and Onshape both require the reference line to be
"woken" first (you pass over it). V3 does that in VR. Whether the flat client should follow is a separate question, not part of this
plan.

Everything else in the flat inference is sound and is ported unchanged: the end is created where the ghost shows it, a point snap
beats any inference, and a measuring-only tap never aligns or infers.

### 1.3 The VR sketcher today

The VR design table draws through `scripts/design_table/snap_resolver.gd` (pure, unit tested) and `sketch_session.gd` (the calls).
The snap radius is already a size in the world (`table_editor.gd` `SNAP_RADIUS` = 12 mm, divided by `view.canvas_scale`), so it
already shrinks in sketch units as you zoom in. That is the VR equivalent of the flat client's 14 px and needs no change. The
problems are these:

| # | Finding | Where | Why it matters | Fixed in |
|---|---|---|---|---|
| a | **The origin is welded.** A snap to the origin returns its id and `_point` uses it directly, so a line or circle is built *on* the origin point | `sketch_session.gd` `_point`; resolver kind `origin` | The flat client stopped doing this (`_pointIdAtUntracked`: "the user can't decouple the entity from the origin"). The two clients build different sketches from the same taps, and in VR the shape can never be freed from the origin | V1 |
| b | **A sketch line's midpoint snap makes a loose point.** The position is exact, but nothing holds it there | resolver `Kind.MIDPOINT`; the header comment says "a later step here can add" the constraint | Change the line and the "midpoint" stays behind. The flat client makes the point and an `at_midpoint` (`_materializeMidpoint`), and VR already does that for a *part* edge's midpoint | V1 |
| c | **A snap onto a sketch line, circle or arc makes a loose point** | resolver `Kind.CURVE` | Same: it looks on the curve and is not. The flat client adds point-on-line / point-on-circle (`_pointOnCurveTarget`), and VR does it for part edges | V1 |
| d | **Closing a chain does not end it.** After a line, `pending` is always the end point, so after landing on the first point the next pull starts another segment from there | `_make_line` (`pending = [{... b}]`) | The flat client ends the chain on a closed loop (`chainInProgress` false). A stray pull adds an unwanted line | V1 |
| e | **H/V is decided after the point snap, on the raw position, and the snapped end is never re-tested against points.** Exactly the flat item 2 bug: the ghost shows the end on the first point, a new point is created a little off it, and H is added. The result is two points and an open profile | `SnapResolver.resolve`, last block | The same "looks closed, is not" report will come from VR | V2 |
| f | **Closing the loop never adds H/V**, because the point snap returns before any inference is computed | same | The flat client now adds H/V to a closing edge within 4 degrees | V2 |
| g | Only H/V is inferred | resolver; `_make_line` takes `infer` as a plain string | Tangent, parallel, perpendicular, collinear, point on curve and concentric are missing | V3 |
| h | No alignment guides | none | | V4 |
| i | No Merge, and no way to pick the second of two stacked points (`nearest_entity` returns only the nearest) | `sketch_session.gd` `nearest_entity`, `select` | | V5 |

What is good and should be kept. The resolver is pure and tested in `tests/design_table_logic.gd`. Its order (an existing point, then
the part's corners and centres, then midpoints, then along a curve) is the right order. Part references already carry their
constraints. The radius is world-scaled. The deck's Snap toggle turns everything off. Undo is a list of calls, which a snapshot
restore fits as one more call (`[METHOD_PUT, path, body]`; `undo()` already passes `entry[2]` as the body).

---

## M1. Backend: merge and restore

### Routes

```
POST /sketches/{sketch_id}/points/merge
  {"point_ids": ["<first selected>", "<second>", ...]}       2 or more distinct ids, in selection order
-> 200 {"kept_id": str,
        "absorbed_ids": [str],
        "dropped_constraint_ids": [str],
        "dropped_reference_dimension_ids": [str],
        "converged": bool,
        "before": "<json.dumps(sketch_to_dict(sketch)) before the merge, as a STRING>"}
-> 404 unknown sketch or point
-> 400 {"detail": {"type": "merge_refused", "reason": "<code>", "message": "<plain words>", "ids": [...]}}

PUT /sketches/{sketch_id}/state
  <the "before" text, sent unchanged as the request body>     a sketch_to_dict object; its "id" must equal sketch_id
-> 200 SketchResponse                                         the live Sketch object is updated in place
-> 422 {"detail": "Invalid sketch file: ..."}                 same wording as import
```

`before` is a JSON **string**, not an embedded object, so that a client sends it back byte for byte. Godot reads every JSON
number as a float and re-serialising turns `rotation_quarter_turns: 0` into `0.0`, which the backend refuses (DIDSA-VR
`docs/design-table.md`, native files). VR's `cad_api.gd` `_send` already sends a `String` body as it is.

Register `/points/merge` before any `/points/{point_id}` route. No POST route exists on that pattern today, but keep the order safe
anyway. Return `before` from the merge itself rather than having the client GET `/export` first. That saves a round trip, which
matters in VR, and the snapshot is taken inside the same request as the change.

**Why 400 and not 409 or 422.** The sketch router reports every model refusal as 400 (`delete_point`, 31 uses, no 409 anywhere).
Follow that, and put the reason code in `detail` so a client can choose its wording.

### Which point is kept

1. An **anchored** point is kept. Anchored means `is_point_locked` (an external reference or a `FixedConstraint`), or referenced
   by a Part feature (see below). If **two or more** points are anchored, refuse (`two_anchored`).
2. Otherwise the point with the **most constraints** on it: the number of constraints whose `point_ids()` include it, not counting
   a provisional dimension (`DistanceConstraint.provisional`, which the solver skips) or a Coincident between two of the selected
   points (the merge removes it anyway). A shape's own constraints count. A rectangle corner, with its H and V, outranks a loose
   line end, so the rectangle stays and the line comes to it, which is what a user expects.
3. On a tie, the **first** id in `point_ids` (the first selected).

Why a count and not something cleverer. No constraint is lost whichever point is kept: the rewrite moves every one of them onto
the kept point. So the choice only decides which geometry moves *before* the solve, and where the solve starts from. A point whose
position is fully decided by its constraints ends up in the same place either way. The count is a cheap stand-in for "which point is
more settled", which is what decides what visibly jumps. A true per-point degrees-of-freedom test would be better in theory, but the
solver reports only the sketch's total DOF (`SolveResult.dof`), and the flat client's `dof_analysis.dart` is advisory and
client-only. Do not build a per-point DOF check for this.

Put the rule in one function (`merge_keep_order(sketch, point_ids, anchored_ids) -> list[str]`, kept first). The response's
`kept_id` is its first entry. Each client computes the same rule locally, from the constraints it already holds, to highlight
the point that will be kept (it does not know about feature references, so the server's answer wins in that rare case).

The kept point does not move during the merge. Every absorbed point's references move to it, then the sketch is solved, and the
geometry that hung on the absorbed points follows. When the points were already coincident nothing visibly moves.

**Feature references.** Add `points_referenced_by_features(sketch_id) -> set[str]` to the document layer (for example in
`app/document/graph.py`, next to `sketch_feature_id_for_sketch`). It walks every Part of the current document and collects
`SketchEntityRef`s with `entity_type == POINT` and this `sketch_id`. Walk the feature dataclasses generically (any field holding a
`SketchEntityRef`, or a `PointRef` with `sketch_point_ref`, at any depth) rather than listing Loft and Create Plane by hand, so a
future feature is covered. The sketch router imports it inside the function, the way `export_sketch` imports `native_format`.
A standalone sketch (no document) returns the empty set.

### Refusals (checked before anything changes)

| `reason` | When | Message (the client may reword it) |
|---|---|---|
| `too_few` | fewer than 2 distinct ids | "Select two or more points to merge." |
| `origin` | the origin is among them | "The origin can't be merged. Use Coincident to tie a point to it." |
| `two_anchored` | 2 or more anchored points | "Two of these points are pinned (to the part, a Fix or a feature), so they can't become one." |
| `same_entity` | one entity uses two of the points (`_entity_defining_point_ids`) | "These points both belong to the same {line, arc, rectangle, ...}: merging them would collapse it." |
| `quadrant` | a circle's or ellipse's cardinal (quadrant) point is among them | "A circle's quadrant point can't be merged. Use Coincident." |
| `dimension_between` | a `DistanceConstraint` or a `PointLineDistanceConstraint` would end up measuring from the kept point to itself | "A dimension holds these points {value} apart. Delete it first." `ids` = that constraint |
| `degenerate_constraint` | any other constraint in the "refuse" column below | "This would break the {type} on them." `ids` = that constraint |
| `stacked_entities` | after the rewrite, two entities of one type would have the same set of defining points (two lines on the same two points) | "Two {lines} would end up on top of each other. Delete one first." |
| `conflict` | the sketch converged before and does not after the merge (the merge is rolled back) | "That conflicts with the other constraints, so the points weren't merged." |

The quadrant refusal is cautious. Cardinal points belong to their circle (`cardinal_constraint_ids`), and the trim and delete paths
treat them as the circle's own. Allowing them needs its own test pass, so leave it out of v1 and list it as a follow-up.

### The rewrite

Implement `Sketch.merge_points(keep_id, absorb_ids) -> MergeResult` in `models.py`. Work on a copy, or take the `before` snapshot
first and restore it on any failure, so that a refusal found part-way leaves the sketch untouched.

1. **Entities and constraints: rewrite generically.** For every entity and every constraint, go over `dataclasses.fields(obj)`.
   Replace any `str` field equal to an absorbed id with `keep_id`, and do the same for each element of a `list[str]` field. Ids are
   uuid4s, so a string equal to a point id *is* that point whatever the field is called. This covers `Line.start_point_id`, a
   rectangle's `corner_point_ids`, a spline's lists, `FixedConstraint.fixed_point_ids`, and the denormalised ends that every
   line-pair constraint stores (`line1_start_id` and so on). Do not list fields by hand: the next entity type would be missed.
2. **Collapsed constraints.** After the rewrite, check each constraint whose point roles now coincide:

   | Constraint | Collapsed roles | Action |
   |---|---|---|
   | Coincident | a = b | drop |
   | Concentric | centre1 = centre2 | drop |
   | PointOnLine | point = a line end | drop (satisfied) |
   | PointOnCircle | point = radius point | drop |
   | PointOnEllipse | point = major or minor point | drop |
   | Fixed | the same id twice in `fixed_point_ids` | de-duplicate the list |
   | Distance (any orientation), PointLineDistance | measured from the point to itself | refuse `dimension_between` |
   | AtMidpoint | point = a line end | refuse (it would force zero length) |
   | PointOnCircle / PointOnEllipse | point = centre | refuse (zero radius) |
   | Tangent, CurveTangent, EqualRadius (from points) | a centre equals a radius, line-end or shared point | refuse |
   | Any line-pair constraint (Parallel, Angle, ...) | the two *lines* share the kept point | **nothing**: that is just two connected lines |

   `same_entity` has already ruled out a point repeated inside one line or arc, so these are the only cases left. Put the table in a
   single function with one test per row.
3. **Duplicates.** Two constraints of the same type over the same arguments (order-insensitive for the symmetric ones: Coincident,
   Parallel, Perpendicular, Equal, Concentric, Collinear) keep the first and drop the rest. This happens when both points were
   coincident with a third point, or both lines were already H.
4. **Sketch-level state.** Delete each absorbed id from `points`, `external_references`, `external_reference_decisions` and
   `reference_ids`. An absorbed point is never anchored, so nothing pinned is lost. Rewrite `("point", absorbed)` in
   `reference_dimensions` refs. A reference dimension that now measures from the kept point to itself is dropped and reported
   (it is driven, so it never constrains, so dropping it is safe). `label_placements` needs nothing, because entries for dropped
   constraints are already ignored by `live_label_placements`. Pattern and mirror instances hold entity ids only and are unaffected.
5. **Solve.** Run `solve_sketch`. If it converged before the merge (solve once first, on the snapshot, or reuse the last result)
   and does not now, restore the snapshot and refuse with `conflict`. If it did not converge before either, keep the merge and
   return `converged: false`. Refusing would block a user who is fixing an already broken sketch.
6. Run the `_prune_reference_helpers_after` dependency on the route, like `delete_point`.

### The restore route

`PUT /sketches/{id}/state` calls `sketch_from_dict`, checks the id, then **copies the fields onto the live `Sketch` object** rather
than replacing the dict entry, so anything holding the object keeps a valid reference. `external_reference_decisions` is transient
and is cleared. The next `refresh_external_references` recomputes it. Session scope is the same as every other sketch route.

The route is generic. It also gives VR an undo for Trim ("Trim can't be undone here yet") and the flat client a snapshot undo for
anything else that has no inverse call. Do not use it for those in this plan, but note it in `docs/status.md` as now possible.

**Risk to note, not solve.** A restore puts back the whole sketch, so an edit made by *another* client on the same session between
the merge and its undo is lost. Every undo in both clients already assumes a single editor, so this is not new. Write it in the
route's docstring.

### Backend tests (`backend/tests/test_sketch_point_merge.py`, new)

- Two loose line ends merge. The two lines share the kept point. `absorbed` is gone. `detect_profile` sees a closed loop for a
  rectangle drawn as four separate lines with one corner left as two points.
- **The generic safety net.** Build a sketch with one of every entity type and every constraint type that references a point. Merge
  a free point into the point each one uses (where allowed). Then assert `absorbed_id not in json.dumps(sketch_to_dict(sketch))`.
  This catches any field the generic rewrite misses, now and later.
- One test per row of the collapse table, and one per refusal (`ids` and `reason` checked). After a refusal,
  `sketch_to_dict` equals `before`.
- The kept-point rule: a FixedConstraint point kept even when listed second; an external-reference point kept; a point
  referenced by a Loft's `reference_point` kept; two anchored points refused; a rectangle corner kept over a loose line end
  whatever the order; a provisional dimension and a Coincident between the pair not counted; a tie keeps the first id.
- Three points in one call (a three-way corner).
- `conflict`: a merge that contradicts an H and a dimension rolls back.
- `PUT /state` round trip: merge, restore with `before`, then `sketch_to_dict` equals the original (ids included), and the
  `SketchFeature` still resolves its sketch. A mismatched id returns 422.

---

## M2. Flat client: the Merge action

- **Offer.** Add `merge` to `ConstraintOptionType` (label "Merge", a new `assets/icons/ribbon/ribbon_merge.svg`, wired). Offer it
  in `availableConstraintOptions` next to Coincident when the selection is 2 or more points and none is the origin. Do the cheap
  checks locally so the button is not offered when it would be refused: two points of one entity (the controller has every entity's
  point ids), or a quadrant point. Leave the rest (feature references, dimensions between, conflicts) to the server and show its
  `message` in `errorMessage`. `_everyPointPinned` already hides everything when all points are pinned.
- **Show which point stays.** While Merge is offered, draw the point the rule will keep with a ring (the snap-candidate style), on
  both the flat canvas and Orbit View. Compute it with a Dart port of `merge_keep_order` (anchored = locked; feature references are
  not known here). Test it on the same cases as the backend.
- **Apply.** `SketchApiClient.mergePoints(sketchId, ids)` and `restoreSketchState(sketchId, snapshot)`. `mergeSelectedPoints()`
  runs `_runGuarded`, calls merge, pushes
  `_pushUndo(() async { await _api.restoreSketchState(id, before); await _reloadLocalSketch(); })`, then **reloads the local
  maps** (points removed, entities' point ids changed) and calls `_solveAndTrackDof`. Factor `_reloadLocalSketch` out of whatever
  re-entering a sketch does (it clears the maps, then `_loadExistingContent`). Clear the selection and hide the ribbon. Drop any
  absorbed id from `_transientPointUndo` and `_lockedPointIds`.
- **Older undo entries stay valid.** They are inverse calls by id. One that names an absorbed point (say "delete point X" from
  drawing X) only runs after the merge itself has been undone, because the stack is last in, first out, and by then X is back.
  Add a test anyway: draw, merge, undo, undo.
- **Reaching two stacked points** (finding 1.1.6). Do two things, both small:
  1. **Pick cycling on a stack.** When a tap's nearest point is already selected and another, unselected point sits on top of it
     (within a quarter of the pick radius of it), the tap selects that one instead of deselecting. A second tap on a stacked pair
     then adds the other point. Anywhere else a tap on a selected point still deselects it, as today.
  2. **Merge from a Coincident glyph.** Orbit View can tap overlay items (`onConstraintOverlayItemTap`). Selecting a Coincident
     glyph offers "Merge points", which merges its two points. Where the flat canvas has no tappable coincident glyph, pick cycling
     covers it.
- **Do not** change what dropping a dragged point on another does (`_autoCoincideIfNear` makes a Coincident). That is
  reversible with an ordinary undo and needs no snapshot, and the glyph's Merge is one tap away.
- **Tests** (`sketch_controller_test.dart`, with the fake backend given both routes, implemented like the real ones on its
  in-memory model): offered and not offered (origin, same line, one point); merge reloads, `points.length` drops by one, both lines
  reference the kept id; undo restores both points; a refusal shows the message and changes nothing; pick cycling selects the second
  stacked point. `flutter analyze`, `flutter test` in `client/`.

---

## V1. VR: fix what is there

All in `scripts/design_table/`. The flat client's behaviour is the reference in each case.

- **(a) Origin.** In `sketch_session.gd` `_point`, when the pick's id is the origin (`is_origin`), create a new point **exactly at
  the origin** and a `coincident` constraint to it (the flat `_createPointCoincidentWithExisting`; exactly on it, so the polygon
  collapse that note describes cannot happen). Add both to `created` / the undo calls. The cursor still says "origin". Check
  `e2e_sketch_*` and `design_table_*` tests that expect the origin id on an entity, and update them.
- **(b) Sketch midpoints.** A pick of kind `midpoint` carries the line id. Reuse a point already held at that line's midpoint (an
  `at_midpoint` on that line), else create a point plus `at_midpoint`. Mirror `_materializeMidpoint`.
  `_point_on_reference` already does the same for a part edge, so share its shape.
- **(c) On a sketch curve.** A pick of kind `curve` carries the entity. Create the point, then `point_on_line` or `point_on_circle`
  (an arc uses `point_on_circle` with `circle_or_arc_id`). **Except** the second end of a line once V3 lands, which gets these from
  the line inference instead. That is the flat rule (`inferPointOnCurve: false`) which avoids a second, contradicting constraint.
- **(d) Chain end on a closed loop.** Remember the chain's first point id in the session (set on a chain's first tap, cleared by
  `finish_chain` and on a tool change). When a line's end is that point, clear `pending` and say "Closed." on the status line.
- **Resolver output.** `resolve` returns the target with each pick: `{"target": {"kind": "line", "id": ...}}` for (b) and (c), so
  the session knows what to constrain. Keep `kind` for the cursor label.
- **Tests.** `tests/design_table_logic.gd` (resolver: the target is returned) and `tests/sketch_session.gd` (fake backend: exact
  call sequences for an origin start, a midpoint, a point on a circle, a closed rectangle chain ending, and undo removing each).

## V2. VR: the line end resolved where the ghost shows it

This is flat item 2, ported into the pure resolver.

- In `SnapResolver.resolve`, when `line_start` is set, compute the end in this order (the flat `_resolveLineEnd` / `_lineEndTarget`):
  1. An existing point within the radius of the **raw** position wins (the chain's first point included).
  2. The part's references, midpoints and curves, as today.
  3. Otherwise compute the inference (H/V now, the full list after V3). If the **snapped** end is within the radius of an existing
     point, that point wins. If it is the chain's first point, the loop closes.
  4. Otherwise a new point **at the snapped position**.
- **Closing edge.** When the end resolves to the chain's first point and the closing segment is within `AXIS_DEGREES` of horizontal
  or vertical, still set `infer` to `horizontal` / `vertical` (H/V only, never parallel or tangent on a closing edge, as in the flat
  client). The resolver needs the chain's first point id for this, so pass it in alongside `line_start`.
- The ghost (`view.set_preview`) already draws to `_snap["uv"]`, so ghost and commit agree once the resolver decides.
- The midpoint method's free end (`_make_line_from_middle`) goes through the same path.
- **Tests** (`design_table_logic.gd`): a rectangle's last side with the raw aim 6 mm under the first point and an H snap closes onto
  it and carries `horizontal`; outside the radius and off-axis gives a new point at the snapped position; zoomed in, two corners
  0.1 mm apart in sketch units, but with a small world radius, do not merge. `sketch_session.gd`: the closing line reuses the first
  point's id, adds one Horizontal, and the chain ends.

## V3. VR: inferred relationships

### Line end (second tap, and the midpoint method's free end)

The order, highest first (the flat order with VR's part references slotted in where the resolver already has them):

1. an existing point (raw, then snapped, as in V2);
2. the part's corners, hole centres and face axes; midpoints (sketch or part edge);
3. **tangent** to a sketch circle or arc, or **point on curve** (the end lands on a sketch line, circle or arc, or a part edge);
4. the line's own **H/V**, plus an **alignment** (V4) on the other axis;
5. **collinear** with a line through the start point (the chain's previous segment, or any line ending at the start);
6. **parallel** or **perpendicular** to a **woken** line (below).

`infer` becomes `{"kind": ..., "target": {"kind": ..., "id": ...}}` (target absent for H/V). `_make_line` creates the constraint
after the line (`parallel` / `perpendicular` / `collinear`: `line1_id`, `line2_id`; `tangent`: `circle_or_arc_id`, `line_id`;
`point_on_line` / `point_on_circle` for the end point), and adds its delete to the undo calls. Read the request bodies from
`_bodies_for`, which already builds every one of them for the Select menu.

**Woken lines (recommended; this is the main departure from the flat client).** Parallel and perpendicular are only tested against:
the chain's previous segment (perpendicular to it is the most common case), and the last **three** sketch lines the laser passed
within the pick radius of while this tool was active, kept for **5 seconds**. Light a woken line faintly so the user can see what
the next inference is relative to. Collinear already only uses lines through the start point. Tangent and point on curve need the
end to be on the curve, so they need no waking.

**Tolerances.** Angles as in the flat client: H/V 4 degrees (`AXIS_DEGREES`), parallel, perpendicular and collinear 4, tangent 6.
Reach, in world metres divided by `view.canvas_scale` like `SNAP_RADIUS`: points 12 mm (as now), tangent, point on curve and
concentric 15 mm (18 px over 14 px, times 12 mm). These are first guesses: feel needs a headset.

**Feedback.** The cursor label already names the snap kind (`view.set_cursor(uv, kind)`). Give each inference a kind
(`parallel`, `perpendicular`, `collinear`, `tangent`, `on curve`) and its glyph from the constraint glyph set, drawn at the marker
point (the tangent point, the nearest point on the curve, the middle of the target line). Highlight the target entity the way
hover does. Ghost and commit use the same snapped end.

**A conflict does not cost the line.** After the line and its inferred constraint, if the solve does not converge, delete only the
inferred constraint, keep the line, and say "Couldn't keep it {parallel}: it conflicted." `_apply_constraint` already takes a
conflicting constraint back out this way.

### Other tools

- **Concentric.** A circle or arc centre (and an ellipse centre, if the backend's `concentric` takes it: check
  `add_concentric_constraint`) placed within 15 mm of an existing circle or arc centre, but outside the 12 mm point snap: a new
  centre point plus `concentric` to that entity. Inside 12 mm the point is reused, which is concentric with no constraint (the
  flat `_concentricTarget` note).
- **Point on curve** for every other placed point comes from V1(c).
- **No inference on measuring taps** (a radius, a sweep end, a slot width, an ellipse's minor radius), as in the flat client.

### Turning it off

Owner's decision (2026-10-29): **a toggle switch, readily available while sketching.**

- **An "Infer" toggle on the deck,** next to Snap in the right-hand utility column (`table_ui.gd`, `_utility("infer", "Infer", true)`,
  on by default, a `infer_toggled` signal, `design_table.gd` `infer_enabled`). Reuse the flat client's look: a link icon, broken
  when off (`sketch_screen.dart`'s Inference command uses `Icons.link` / `Icons.link_off`). Add a `tool_infer` icon to
  `scripts/ui/ui_icons.gd`.
- **What it turns off:** every constraint the sketcher would add by itself (H/V, collinear, parallel, perpendicular, tangent, point
  on curve, concentric, the at-midpoint of a midpoint snap) and the angle snaps that go with them, and the alignment guides. **What
  stays:** snapping onto existing points, the part's corners, centres and edges, midpoints and curves (position only, a plain point).
  Snap off still turns everything off, Infer included.
- **It stays as set** until switched back, across tools, for the rest of the table session. It is a toggle, not a hold. Show it
  on the status line while it is off ("Infer off: nothing is added automatically"), so a forgotten toggle explains itself.
- The flat client's command reads "suppress for this tool". Check whether it resets on a tool change. If it does, that is a
  difference between the two apps. Note it in the PR; do not change the flat app in this plan.
- The resolver takes `infer_enabled` beside `enabled`. Tests: with Infer off, a line drawn near horizontal is not snapped to the
  axis and makes no constraint, a midpoint snap makes a plain point, and an existing point is still reused.

### Tests

`design_table_logic.gd` (pure): each inference kind found and its snapped end; the priority order (a point beats tangent, H beats
parallel, collinear beats parallel); parallel is **not** inferred against an unwoken line and is after a pass over it, which expires
after 5 s; tolerances at the edges. `sketch_session.gd` (fake backend): the constraint call after the line, its undo, and a
conflicting inferred constraint removed with the line kept. One `e2e_` test against the real backend: draw an L with a
perpendicular second leg and a tangent line to a circle, then read the constraints back.

## V4. VR: alignment guides

This is flat item 3, as a snapping aid only, with **no constraint** (the owner's answer for the flat client).

- Port `_alignToPoints` into the resolver: for x and y independently, the nearest other point whose coordinate is within **6 mm**
  world (the flat 7 px against 14 px, times 12 mm). It snaps that coordinate.
- **References.** Sketch points and the origin. Exclude circle and ellipse cardinal points, reference helper points
  (`is_reference`), and the line's own start. Part corners are left out of v1, which keeps the result predictable. Adding the
  projected part vertices later is a one-line change, and worth asking about after a headset session.
- **Where it applies.** The same taps as the flat client: the line end (with its own H fixing y, so only x aligns), a line's first
  point, Point, rectangle corners, circle, arc, polygon, slot, ellipse and ellipse arc centres and defining points, spline points, the
  midpoint method's anchor. Never on taps that only measure.
- **Priority.** Existing point > part references and midpoints > tangent and on curve > own H/V plus alignment > collinear,
  parallel and perpendicular (dropped when an alignment applies).
- **The visual.** At most two dashed lines in `sketch_view.gd`, from the reference point to the snapped cursor, in the H/V snap
  green, with a constant on-screen width (scale by `canvas_scale` like the cursor). Draw them on the sheet, not floating, so they
  are clipped like the rest of the sketch.
- **Tests.** Pure: x aligns, both axes from two points, tolerance, cardinal and own-start excluded, a point snap wins, Snap off.
  Session: a Point placed aligned makes no constraint.

## V5. VR: Merge

- **Offer.** Add `merge` to `SelectMenuIds` (`table_editor.gd`), next to `coincident`, shown when Select's selection is 2 or more
  points, none the origin, and the same local checks as M2 (same entity, quadrant). It is not a constraint, so it does not go
  through `_bodies_for`. Special-case it the way `delete` and `construction` are.
- **Apply.** `sketch_session.gd` `merge_selected()`: POST `points/merge` with the selected ids in order. On 200 the undo step is
  `{"label": "merge", "calls": [[HTTPClient.METHOD_PUT, SKETCH + sketch_id + "/state", before]]}`, then `refresh(true)` and
  `sync_undo_redo`. `before` is a string (M1), so it goes back unchanged
  (`_send` sends a `String` body as it is). On 400 show `detail.message` on the status line. Read it explicitly: `cad_api.gd`'s
  error text prefers `detail.type` over `detail.message`, so the generic path would show "merge_refused".
- **Show which point stays.** While Merge is in the menu, ring the point the rule will keep (the same rule, ported to GDScript,
  tested on the backend's cases), and name it on the status line ("Merge: the rectangle corner stays").
- **Stacked points.** Pick cycling on a stack as in M2: in Select, a pull whose nearest point is already selected, with an unselected
  point within a quarter of the pick radius of it, selects that one. Otherwise a pull on a selected point deselects it, as today. The status line says "2 points here" when the aim is on a stack, so the user knows to pull twice.
- **Fake backend.** `tests/helpers/fake_cad.gd` gets both routes, applied to its model like the real ones.
- **Tests.** `tests/sketch_session.gd`: the call, the undo PUT carrying the `before` string unchanged (integers stay integers), a refusal message, pick
  cycling. A new `tests/e2e_sketch_merge.gd` against the real backend: draw two lines ending a hair apart, merge, check the profile is
  closed, undo, check it is open again. Add it to `tests/run_all.sh`, `tests/e2e_ci_list.txt` and a row in `tests/README.md`.

## M3 (deferred). Close gaps

**Not now** (owner, 2026-10-29). Kept here so it is not lost. A sketch-level action, "Close gaps", that merges every pair of points not already joined (not the
same point, not coincident) closer than a tolerance. `POST /sketches/{id}/points/merge-near {"tolerance": mm}` groups them, applies
the M1 rules to each group, skips refused groups and reports them, and returns one `before`. The client passes its current point
snap radius as the tolerance. It is one tap to repair the "looks closed, is not" sketches that the old item 2 bug made, and imported
DXF, without hunting for stacked points.

---

## Verification

- **CAD:** the backend pytest suite, `flutter analyze` and `flutter test` in `client/` (what `client-verify.yml` runs).
- **VR:** `tests/run_all.sh`, `tests/ci.sh` (fails on any false SMOKE line), and `tests/ci_e2e.sh` against a backend from
  `tools/start_backend.sh` **with M1 in it** (the e2e list runs against the branch's backend, so V5's e2e test waits for M1).
  Every new VR test file goes in `tests/run_all.sh` and `tests/README.md` (CLAUDE.md rule). Tests that load `main.tscn` set
  `secrets_file_path` to a missing file and run with `DIDSA_NO_LANDING=1`.
- **Cannot be judged headless:** the 15 mm inference reach and 6 mm alignment tolerance, whether "woken" lines feel natural with a
  laser, the guide's look on the sheet, and the stacked-point "pull twice" flow. Say so in the PRs and in `docs/status.md`. Do not
  write that anything works on the headset.

## Docs to update when building

- CAD: this file's progress table (add one as the flat plan has), the handoff section of `sketcher-feedback-2026-10-29-plan.md`
  (mark 2b done), `docs/status.md`.
- VR: `docs/backend-api-notes.md` (both new routes and the float trap for `before`), `docs/design-table.md` (the snapping and
  inference rules and Merge in Select), `docs/design-table-gaps.md` row 7(4) "inference", `docs/status.md`, `tests/README.md`.
  Update the header comment of `snap_resolver.gd`: its "a later step here can add" note is closed by V1.

## Decisions (owner, 2026-10-29)

1. "Inverted relationships" was a typo for **inferred** relationships.
2. VR parallel and perpendicular only against **woken** lines, as recommended.
3. The kept point: **anchored, then most constraints, then selection order** (M1), with the kept point highlighted in both clients.
4. Quadrant points **refused** in v1, as recommended.
5. M3 "Close gaps": **not now**.
6. An **Infer toggle on the VR deck**, next to Snap, sticky (V3, "Turning it off").
