# Sketcher Overhaul — Scoping Document

Companion to the "Sketcher tuning package" section of `docs/roadmap.md`.
That section captures the raw requirements; this document breaks them
into engineering workstreams against the *actual current implementation*
(verified by reading the code, not assumed), with proposed approach,
affected files, complexity/risk, and a suggested delivery order.

Client: `client/lib/sketch/*`, `client/lib/viewport3d/*`.
Backend: `backend/app/sketch/*` (FastAPI + py-slvs, SolveSpace's
Newton-Raphson constraint solver, wrapped by `solver.py`/`constraints.py`).

---

## Phase 1 — Interaction model fixes (client-only, no backend changes)

Highest value, lowest risk: all four items live entirely in
`sketch_canvas.dart` / `sketch_controller.dart` and don't touch the
solver or data model.

### 1.1 Replace "double-tap/double-click to drag" with an explicit drag-mode FAB
- **Current state**: there's no real double-tap gesture today. A tap
  fires on pointer-up if travel < 10px (`sketch_canvas.dart:588-591`),
  and a *second* pointer-down within 350ms (`_doubleClickTimeout`,
  `:98`) over a draggable point is reinterpreted as a drag-start
  (`_tryStartEntityDrag`, `:420-440`). This 350ms window is exactly the
  reported false-positive source: select-tap immediately followed by a
  drag-intent tap gets misread as the second half of a click-drag.
- **Proposed approach**: add a persistent mode toggle FAB, bottom-left
  of the canvas (a new sibling to `sketch_speed_dial.dart`'s stack, or
  a small standalone `FloatingActionButton` positioned via
  `Alignment.bottomLeft`). While the mode is active, a single pointer-down
  on a hit-testable point starts a drag directly — no timing race, no
  second tap needed. Off, taps behave as plain select. Remove
  `_doubleClickTimeout`/`_tryStartEntityDrag`'s timing-based path
  entirely rather than layering the FAB on top of it, so there's one
  unambiguous drag-trigger path.
- **Files**: `sketch_canvas.dart` (gesture dispatch), `sketch_controller.dart`
  (mode state), new small widget or extend `sketch_speed_dial.dart`.
- **Risk**: low. Existing tests (`sketch_canvas_ghost_editor_test.dart`
  or similar) will need updating for the new trigger path.

### 1.2 Shrink point hit-radius / detach from the midpoint false-positive problem
- **Current state**: `minTapHitRadiusPixels = 14.0` (`sketch_controller.dart:274`),
  with an extra `pointHitRadiusMultiplier = 1.6` applied to points only
  (`:279`, used in `_entityAt`, `:814`) — so a point's *effective* radius
  is 22.4px, competing with nearby midpoint hit-testing
  (`_nearestLineMidpointId`, `:883`).
- **Proposed approach**: reduce `pointHitRadiusMultiplier` (needs a
  concrete number — recommend user-testing 1.0–1.2 rather than guessing)
  and/or add explicit priority ordering when a point and a midpoint both
  hit-test positive within the same gesture (endpoints should generally
  win over midpoints at equal distance, since midpoints are a derived
  convenience target). Since hover and tap-select already share one
  code path (`_entityAt`, confirmed unified — see `:862-871`'s own
  comment about a prior "bug-fix round 3" that fixed this exact
  divergence), no separate hover-vs-select reconciliation is needed here,
  just radius/priority tuning.
- **Files**: `sketch_controller.dart` only.
- **Risk**: low, but needs real device/finger testing to pick a good
  constant — this is a tuning task, not a structural change.

### 1.3 Confirm hit-radius zoom-scaling is already consistent (no code change expected)
- **Current state**: `hitRadiusForPixelsPerUnit` (`sketch_controller.dart:284-287`)
  already converts the fixed pixel radius through the live
  `pixelsPerUnit` zoom factor from `ViewTransform`
  (`view_transform.dart:15-28`, `sketch_viewport.dart:33-36`), and this
  is the *same* `pixelsPerUnit` used for rendering. On inspection this
  item from the roadmap notes appears to already be handled correctly.
- **Action**: verify on-device at extreme zoom levels (very zoomed in
  and very zoomed out) before assuming this is done — the `snapRadius`
  floor of 0.5 sketch-units (`:261`) could still feel inconsistent when
  heavily zoomed in, since the radius stops shrinking in screen-pixel
  terms below that floor. Worth a quick manual check rather than new
  engineering.

### 1.4 Auto-create coincident constraint when a dragged point is dropped on another point
- **Current state**: this already exists for the **point-placement
  tool** (`_clickPointTool`, `sketch_controller.dart:2722-2754`, via
  `_existingPointIdNear` + `_api.createCoincidentConstraint`) but is
  **missing from drag-and-drop** — `endPointDrag`
  (`:1144-1163`) has no equivalent snap-and-constrain logic.
  `CoincidentConstraint` itself is fully implemented server-side
  (`constraints.py:270-287`, `router.py:405-406`), so this is UI-glue
  only, not new backend work.
- **Proposed approach**: in `endPointDrag`, reuse the existing
  `_existingPointIdNear`-style proximity check against the drop
  position, and call the same `createCoincidentConstraint` API if a hit
  is found (with a confirmation/undo-friendly UX — auto-adding a
  constraint the user didn't explicitly ask for should be easy to
  reverse).
- **Files**: `sketch_controller.dart` only.
- **Risk**: low.

---

## Phase 2 — Drag-solve semantics (client + backend)

### 2.1 "Dragged point stays put, others move to accommodate" during solve
- **Current state**: no pinning concept exists anywhere. `update_point`
  (`router.py:258-266`) is a raw coordinate overwrite with no re-solve.
  `endPointDrag` (`sketch_controller.dart:1144-1163`) only *then* calls
  a whole-sketch, unconstrained-in-that-sense `solve_sketch` (one-shot
  py-slvs batch solve, `solver.py:209-296`). The solver has no
  `fixed_point_id`/anchor parameter — the only entity that's ever hard-fixed
  today is the sketch origin (`_FIXED_GROUP`, `solver.py:79-97`).
- **Proposed approach**: add an optional `anchor_point_id` (or list) to
  `solve_sketch`, which temporarily adds that point to the fixed group
  (same mechanism already used for the origin) for that one solve call,
  then removes it. Wire `endPointDrag` to pass the just-dragged point's
  id as the anchor. This directly reuses an existing mechanism rather
  than inventing a new solver mode — the main risk is *which* point wins
  when the anchor conflicts with an explicit dimensional constraint on
  that same point (e.g. user dragged a point that has a fixed-length
  dimension to another point) — needs a documented fallback (likely:
  anchor loses to explicit numeric constraints, since those are
  intentional design values).
- **Files**: `solver.py`, `router.py` (pass-through param), `schemas.py`
  (request field), `sketch_api_client.dart`, `sketch_controller.dart`.
- **Risk**: medium — this is the first item that touches the solver's
  core contract, needs solver-level test coverage (`backend/tests/`)
  for the anchor-vs-constraint conflict case specifically.

---

## Phase 3 — Constraint visual feedback

### 3.1 Fully-constrained line/curve turns dark green
- **Current state**: `SolveResult` already surfaces `dof`
  (`solver.py:26-57`, from py-slvs's `system.Dof`) and `converged`, but
  there's no *per-entity* constrained/unconstrained flag — `dof` is a
  whole-sketch scalar. No `over_constrained`/`fully_constrained` field
  exists in `schemas.py` at all today (`SolveResultResponse`,
  `schemas.py:360-366`).
- **Proposed approach (v1, heuristic)**: per-entity "fully constrained"
  isn't something py-slvs gives for free — a real answer needs
  structural DOF decomposition (which points/lines are pinned down by
  the constraint graph vs. still free), which is genuine new solver
  work, not a client-side derivation. Recommend a v1 heuristic instead:
  color a line/curve green once *both* its endpoints have zero
  remaining freedom under the current constraint set, approximated by
  re-solving with that entity's points perturbed and checking they
  snap back (expensive) — **or**, cheaper and likely good enough,
  green once each endpoint participates in constraints that fully
  pin its two coordinates (e.g. coincident-to-fixed, or both an
  H/V + a dimension). This needs a short design spike before
  committing to an approach; flag as the riskiest single item in the
  whole package.
- **Files**: likely new logic in `solver.py` (whichever heuristic wins)
  plus `sketch_canvas.dart` rendering (color per entity).
- **Risk**: medium-high — genuinely underspecified, needs a design
  decision before implementation, not just coding.

### 3.2 Over-constrained entities turn red and disallow drag on their defining points
- **Current state**: py-slvs's own `Failed` constraint list exists
  (`solver_reported_failed_constraint_ids`, `solver.py:264-268`) but is
  explicitly documented as unreliable for root-cause attribution — "tends
  to list every constraint in an inconsistent system rather than a
  single culprit" (`solver.py:40-45,283-286`); the existing
  `blamed_constraint_ids` is just "most recently added," a placeholder
  heuristic, not a real diagnosis.
- **Proposed approach**: same root problem as 3.1 — real over-constraint
  attribution needs proper DOF/rigidity analysis on the constraint
  graph. Until that exists, a defensible v1: when `dof < 0` /
  `converged == false` overall, mark the constraints in
  `blamed_constraint_ids` (and the points/entities they reference) red
  and block drag on those points, clearly labelled as best-effort rather
  than exact. Revisit with real graph-based DOF analysis as a follow-up
  if the heuristic proves misleading in practice.
- **Files**: `solver.py` (expose which entities to flag),
  `sketch_canvas.dart` (red rendering + drag-disable check).
- **Risk**: shares 3.1's underlying uncertainty; ship the heuristic
  version and treat exact attribution as a separate, later backlog item.

---

## Phase 4 — 3D context while sketching

### 4.1 Show existing bodies behind the canvas, default ~25% transparent
- **Current state**: already fully implemented and user-adjustable.
  `SketchCanvas.canvasOpacity` (`sketch_canvas.dart:49,60`,
  applied at `:1795`) defaults to `1.0` (fully opaque); `sketch_screen.dart`
  already has a working opacity slider bottom sheet (`_CanvasOpacitySheet`,
  `:422-513`) reachable from a toolbar icon (`:377`).
- **Proposed approach**: this is a **one-line default change** — set
  the initial `_canvasOpacity` in `sketch_screen.dart:62` to `0.75`
  (25% transparent, 75% opaque) instead of the current default. No new
  UI needed.
- **Files**: `sketch_screen.dart`.
- **Risk**: none — smallest item in the whole package, verify the
  default actually reads `1.0` today before changing (confirmed above).

### 4.2 Orbit-view button + animated return-to-default-view button
- **Current state**: the sketcher uses a flat 2D `SketchViewport`
  (pan/zoom only, `sketch_viewport.dart`), not the 3D `OrbitCamera`
  used by the part viewer (`viewport3d/orbit_camera.dart`). However,
  `OrbitCamera` already has everything needed for reuse:
  `orientationFacingPlane(ReferencePlaneKind)` computes the
  quaternion facing a given plane (`:276-280`), and
  `PartViewport.animateToPlane` already animates the camera to a plane
  orientation via an `AnimationController` (`part_viewport.dart:786-792`),
  used today for the camera-animation-into-sketch transition
  (`part_screen.dart:2484,3000`). `OrbitCamera.reset()` backs an
  existing "Reset view" button elsewhere in the app
  (`part_viewport.dart:1122-1126,1460`).
- **Proposed approach**: treat orbit-view as a **temporary inspection
  mode**, not simultaneous 2D-editing-in-3D — matches the actual ask
  ("a button to change to orbit view so user can see where they are
  sketching... a button to return to default view... should animate").
  Toggle to a read-only 3D `OrbitCamera` view (reusing the part
  viewer's camera plumbing) showing the sketch's existing
  `sketch_geometry_3d.dart` projection alongside bodies; "return to
  default" calls the same `animateToPlane`/orientation-facing logic
  already proven for entering sketch mode. Editing stays on the 2D
  canvas; orbit is look-only.
- **Files**: `sketch_screen.dart` (mode toggle + camera lifecycle),
  reuses `orbit_camera.dart`, `part_viewport.dart` patterns,
  `sketch_geometry_3d.dart` (already renders sketch entities in 3D
  world space, confirmed reusable as-is).
- **Risk**: medium — mostly integration work reusing proven
  components, main complexity is state management for switching
  between two camera/input models cleanly.

### 4.3 Dimensioning from body edges/points + yellow "lost reference" tree indicator
- **Current state**: not supported at all today. Sketch constraints and
  dimensions only ever reference in-sketch `PointDto`/`LineDto`
  entities; there is no concept of a sketch entity referencing external
  body geometry (edges/vertices from other features) anywhere in
  `models.py`, `constraints.py`, or the client dimension code. Separately,
  the feature-tree already has a reusable pattern for this kind of
  status color: `feature_tree_panel.dart:449-464` conditionally colors a
  feature's icon (grey when `locked`) — a direct template to extend
  with a `hasLostReference` yellow state.
- **Proposed approach**: this is the largest, most structural item in
  the package. Needs: (a) a new backend concept of an "external
  reference" on a sketch (edge/vertex id + snapshot of its geometry at
  reference time, so a dimension can still render/solve even before
  the live lookup resolves), (b) staleness detection when the
  referenced feature is edited/deleted (re-resolve on model change,
  flag `hasLostReference` if the id no longer resolves), (c) client
  picking UI to let the user select body edges/points while placing a
  dimension, (d) the tree-icon yellow state reusing the existing
  color-branch pattern. Recommend scoping this as its own follow-up
  design doc rather than folding into the rest of this package — it's
  materially bigger than every other item here and touches the core
  data model (a sketch referencing something outside itself for the
  first time).
- **Files**: `models.py`, `schemas.py`, `solver.py` (external refs feed
  the solve as fixed inputs), `router.py`, `sketch_dimension_bar.dart`,
  `sketch_controller.dart`, `feature_tree_panel.dart`.
- **Risk**: high — new data model concept, cross-feature staleness
  tracking, and new picking UX all at once. Treat as its own
  mini-project.

---

## Phase 5 — Sketch orientation control

### 5.1 Flip / rotate sketch axes, reference-axis alignment, retrospective redefine
- **Current state**: `Sketch.plane` is only a fixed enum
  (`Plane.XY|XZ|YZ`, `models.py:25-31,208`) or `None` when anchored to a
  custom `CreatePlaneFeature` — there is no independent
  orientation/flip/rotate/reference-axis state on a sketch at all. The
  solver hardcodes its workplane normal direction per canonical plane
  (`solver.py:234-236`). The existing `plane_indicator.dart` widget
  (bottom-left axis-arrows + label, matching the roadmap's described
  position) is purely cosmetic today — axes are hardcoded per plane
  (`_axesByPlane`, lines 19-32), not derived from any stored
  orientation state, and there's no flip/rotate logic anywhere in the
  sketch files.
- **Proposed approach**: add orientation fields to `Sketch`
  (e.g. a flip flag + rotation step, or store an explicit U/V basis
  pair derived from the plane's default axes plus applied
  flip/rotation — the latter is more general and handles the
  reference-axis-alignment case uniformly) and thread that basis
  through `solve_sketch`'s workplane construction instead of the
  hardcoded normal. Client: extend `plane_indicator.dart` to read the
  live basis rather than a hardcoded per-plane table, add flip/rotate
  buttons during sketch creation, wire an optional edge/line pick
  (reusing hit-testing infra from the sketcher itself) to set the
  reference axis, and add a long-press handler on a sketch (tree or
  canvas) that re-enters this same orientation UI retrospectively —
  requires re-solving/re-projecting existing sketch geometry against
  the new basis when redefined after the fact, which is the trickiest
  sub-piece (existing point coordinates are plane-relative already, so
  a basis change is a re-projection, not a re-entry of geometry, but
  needs care around any *external* references from Phase 4.3 if that's
  shipped by then).
- **Files**: `models.py`, `schemas.py`, `solver.py`,
  `plane_indicator.dart`, `sketch_screen.dart` (creation flow),
  `feature_tree_panel.dart` or canvas (long-press entry point).
- **Risk**: medium-high — real data-model addition plus a retrospective
  edit path that has to stay correct against existing sketch geometry;
  sequence after Phase 4.3 if both are in flight, since retrospective
  redefinition interacts with external references.

---

## Phase 6 — Drawing tool additions

### 6.1 Line tool: snap to horizontal/vertical + auto-constrain on placement
- **Current state**: Horizontal/Vertical constraints are fully
  implemented but only ever user-invoked explicitly
  (`addHorizontalConstraint`/`addVerticalConstraint`,
  `sketch_controller.dart:1939,1955`, wired to ribbon shortcuts
  `:1914-1917`). There's no angle-threshold auto-snap during line
  placement today — existing snap behavior only covers point/midpoint/
  chain-start coincidence (`sketch_canvas.dart:1644-1934`).
- **Proposed approach**: during the line tool's drag/preview, compute
  the angle to horizontal/vertical and snap the preview endpoint when
  within a threshold (a few degrees), mirroring the existing
  point-snap visual pattern; on placement while snapped, call the
  existing `addHorizontalConstraint`/`addVerticalConstraint` methods
  automatically — no new constraint machinery needed, just new
  triggering logic.
- **Files**: `sketch_controller.dart`, `sketch_canvas.dart`.
- **Risk**: low — additive, reuses existing constraint calls.

### 6.2 New shape/curve tools: arc, ellipse, slot, polygon, spline, text
- **Current state**: today's tools are point, line, circle, rectangle
  (`sketch_speed_dial.dart:43-99`). None of arc/ellipse/slot/polygon/
  spline/text exist client- or backend-side.
- **Proposed approach**: treat as a backlog of independent tool
  additions, not one lump of work, roughly in order of increasing
  complexity:
  1. **Arc** — moderate; py-slvs supports arc entities directly, similar
     shape to the existing circle tool's client/backend pattern.
  2. **Polygon** — moderate; likely composed of line entities plus
     equal-length/angle constraints generated at creation time, no new
     solver entity type needed.
  3. **Slot** — moderate; composite of two arcs + two tangent lines,
     buildable from arc + line primitives once (1) lands.
  4. **Ellipse** — moderate-high; need to confirm py-slvs's constraint
     support for ellipse entities (may be more limited than
     circle/arc) before committing to an approach.
  5. **Spline** — high; needs a new curve entity type end-to-end
     (model, solver representation, rendering, hit-testing/dragging of
     control points) — confirm what curve types py-slvs actually
     exposes before scoping further, this may need its own design doc.
  6. **Text (outline, for cutting/embossing)** — highest; effectively a
     separate feature from the rest of the sketcher — needs font
     outline extraction (e.g. via a font-parsing/path library) to turn
     glyphs into sketch curve geometry, unrelated to the constraint
     solver. Recommend scoping and estimating this one entirely
     separately from the rest of the sketcher package.
- **Files**: backend `models.py`/`constraints.py`/`solver.py` (new
  entity + constraint types per shape), `sketch_controller.dart`,
  `sketch_canvas.dart`, `sketch_speed_dial.dart`, `sketch_api_client.dart`
  for each.
- **Risk**: low→high across the list; sequence in the order above and
  stop to re-scope before spline/text specifically.

---

## Suggested delivery order

1. **Phase 1** (interaction fixes) — do first, self-contained, fixes
   the most-reported daily annoyances, no backend risk.
2. **Phase 2** (drag-pin solve semantics) — natural follow-on to Phase 1
   since it changes what "drag" means; touches the solver but reuses an
   existing fixed-group mechanism.
3. **Phase 4.1** (canvas opacity default) — trivial, do any time,
   possibly bundle into Phase 1's PR since it's a one-line change.
4. **Phase 6.1** (line snap) — small, independent, can slot in anywhere.
5. **Phase 4.2** (orbit view) — medium, mostly integration of existing
   `OrbitCamera`/`animateToPlane` code.
6. **Phase 5** (sketch orientation) — do before Phase 4.3 if both are
   planned, since 4.3's retrospective-redefine interaction is simpler
   against an already-generalized orientation model.
7. **Phase 3** (constraint color feedback) — needs a short design spike
   first (3.1/3.2's heuristic approach) before estimating; not blocked
   on anything else, but the *decision* of what heuristic to ship
   should happen before implementation starts.
8. **Phase 4.3** (external body references) — biggest structural item;
   recommend its own scoping doc when the team is ready to pick it up.
9. **Phase 6.2** (new shape tools) — ongoing backlog, pick off in the
   listed complexity order; spline and text need their own scoping
   passes when reached.

Open questions for the user before implementation starts:
- Phase 3: acceptable to ship a heuristic (not exact) over/under-constrained
  indicator first, with real DOF-graph analysis as a later follow-up?
- Phase 4.2: confirmed that orbit should be a *look-only* temporary mode
  rather than full 3D editing?
- Phase 5: flip/rotate as discrete steps (e.g. 90°) or free rotation?
- Phase 6.2: any priority order preference among arc/ellipse/slot/polygon/
  spline/text, or is the complexity-based ordering above fine?
