# DIDSA-CAD Status Summary — 2026-06-24 (Stage 14)

## What this covers

Stage 14 — Sketcher: Point Tool, Universal Snapping, Selectable
Dimensions/Constraints, Dimension-Mode Revamp, and Drag-to-Reposition.
Pure client-side work package; no backend changes were needed (the
existing Point/Constraint endpoints already cover everything below).
Builds directly on Stage 13's tap-to-place/FAB/ghost-dimension/
constraint-selection foundation.

## Client — complete

### Point tool alongside Line/Circle

- `client/lib/sketch/sketch_controller.dart`: `SketchTool.point` added
  to the existing tool enum. `_clickPointTool()` is a single,
  self-terminating tap — no chain, no construction-method choice
  (there's nothing to choose between for a bare point) — that reuses
  `_pointIdAtCursor()` so it gets the same snap-onto-existing-Point
  behavior as every other placement path for free.
- `client/lib/sketch/sketch_speed_dial.dart`: "Point" added to the
  "Sketch Entities" FAB category next to Line/Circle.
- `client/lib/sketch/sketch_screen.dart`: the bottom construction-method
  bar only shows for Line/Circle (`SketchTool.point` has no
  construction-method choice to present).

### Universal point/midpoint snapping

- `_existingPointIdNear` generalized so *every* entity-placement path
  (line endpoints, circle center/radius, the point tool itself) can
  snap onto any existing Point, not just the chain start/origin special
  cases from earlier stages.
- `_nearestLineMidpointId` + `_materializeMidpoint`: a tap near a Line's
  geometric midpoint (and not already on an existing Point) creates a
  real backend Point at that location on first use and returns its id —
  so "use a line's midpoint when placing a new entity" works exactly
  like snapping onto any other Point, with the materialization cost
  paid only once per midpoint.

### Selectable Dimensions and Constraints

- `client/lib/sketch/sketch_controller.dart`: `selectConstraint(id)`
  adds a `SelectionKind.constraint` selection and opens the ribbon, hit
  via a new constraint-hit-test in `select` mode (`_dispatchTap` checks
  for a constraint hit before falling through to
  `handleCanvasTap`).`selectedConstraintValue`/
  `selectedConstraintHasValue`/`selectedConstraintIsAngle` expose a
  selected value-bearing Constraint's (Distance or Angle) current
  number, suffix unit, and whether it has one at all (Vertical/
  Horizontal don't). `updateSelectedConstraintValue(value)` PATCHes the
  existing constraint and deselects on success.
  `deleteSelected()` now also handles a selected Constraint (DELETE +
  re-solve), alongside the existing Point/Line/Circle cases.
  `SketchApiClient` gained `deleteConstraint`/`createAngleConstraint`
  (`updatePoint` was already added in the prior session for this
  stage's drag feature).
- `client/lib/sketch/sketch_ribbon.dart`: a new `_ConstraintValueEditor`
  renders above the action-chip row whenever exactly one value-bearing
  Constraint is selected — a text field (mirroring the dimension
  ghost's own inline editor) that PATCHes via
  `updateSelectedConstraintValue` on submit. Delete is offered for any
  selection via the existing chip row, now also covering Constraints.

### Dimension-mode revamp: multi-select with a fly-up bar

- `client/lib/sketch/sketch_controller.dart`: `dimensionSelection`
  (ordered list, exposed read-only) replaces the old at-most-two-taps
  ad hoc pick state. Tapping an entity in dimension mode adds it to the
  list (deduplicated); the ghost set shown is recomputed from whatever
  is currently picked, covering: a single Line (length), a single
  Circle (radius + diameter, unchanged from Stage 13), two Points
  (vertical/horizontal/linear distance), a Point + a Line
  (endpoint-substituted — the Line's nearer endpoint stands in for the
  Line itself, so it joins the Point+Point case), two parallel Lines
  (`lineDistance`, between their midpoints — both materialized on
  confirm if not already real Points), and two non-parallel Lines
  (`angle`, via a new `AngleConstraint`/`createAngleConstraint`).
  Confirming any ghost or applying a constraint (the
  point/constraint-selection ribbon path too) now clears the relevant
  selection state and closes the flyout, rather than leaving stale
  picks/ribbon open as in Stage 13.
- `client/lib/sketch/sketch_dimension_bar.dart` (new): the bottom
  fly-up bar shown while `mode == SketchMode.dimension` — an exit
  button plus a live list of the currently-picked entities
  (`dimensionSelection`), replacing the bare mode-label pill as the
  primary "you are in dimension mode, here's what you've picked so far"
  affordance. `sketch_screen.dart` swaps in this bar (vs. the
  construction-method bar) based on mode.

### Double-click-and-drag on under-constrained Points

- `client/lib/sketch/sketch_controller.dart`: tracks the backend
  solver's whole-sketch degrees-of-freedom count after every solve
  (`_solveAndTrackDof`, now used everywhere `_api.solve` used to be
  called directly) and exposes it as `isUnderConstrained` (`dof > 0`) —
  a deliberately coarse, sketch-wide approximation, since the backend
  has no per-entity freedom check to query instead.
  `dragTargetPointIdAt(x, y, radius)` resolves a draggable target only
  in `select` mode while under-constrained: a directly-hit Point as-is,
  or — for a Line/Circle, neither of which has a position of its own —
  whichever of its constituent Points sits nearer the hit.
  `beginPointDrag`/`updatePointDrag`/`endPointDrag` start a drag, PATCH
  the dragged Point's raw position live on every move (no re-solve
  mid-drag, so dragging feels immediate), and re-solve once the drag
  ends so any remaining constraints settle into the dropped position.
- `client/lib/sketch/sketch_canvas.dart`: recognizes the "double-click"
  half of the gesture purely by elapsed time since the last dispatched
  tap (`_doubleClickTimeout`, 350ms) — consistent with this file's
  existing trackpad-style cursor model, where a tap's literal screen
  position is already treated as meaningless everywhere else; the drag
  target is resolved from the controller's persistent cursor position,
  not the second pointer-down's own screen coordinates.
  `_tryStartEntityDrag` wires this into both the mouse and touch
  pointer-down paths; pointer-move and pointer-up branch on whether a
  drag is active before falling through to the normal
  cursor-move/pan/pinch/tap-dispatch handling.
  Independent dimension-value-by-drag (e.g. dragging a Distance/Angle
  label directly to set its number) was deliberately **not**
  implemented — the work package gives no concrete direction-to-value
  mapping for it, and every dimension overlay already tracks its anchor
  Points live, so dragging a Point a dimension references already
  visually drags that dimension along with it.

## Test coverage

`client/test/sketch_controller_test.dart` grew from 52 to 72 tests,
covering: point-tool placement and self-termination; point-tool
snap-onto-existing-Point; a draw-mode tap reusing a materialized Line
midpoint; `selectConstraint`/`deleteSelected` on a Constraint;
`selectedConstraintValue`/`selectedConstraintHasValue`/
`selectedConstraintIsAngle` for both a value-less (Vertical) and a
value-bearing (Distance) constraint; `updateSelectedConstraintValue`;
the two-parallel-Lines `lineDistance` ghost (including midpoint
materialization) and confirm; the two-non-parallel-Lines `angle` ghost
and confirm, including a re-confirm-PATCHes-not-duplicates case; the
Point+Line ghost endpoint-substitution case; and the full
double-click-drag API (`isUnderConstrained` gating by mode and dof,
`dragTargetPointIdAt`'s direct-Point and Line-to-nearer-endpoint
resolution, `beginPointDrag` accept/reject, `updatePointDrag`'s
live-PATCH-without-solving, and `endPointDrag`'s re-solve-and-refresh).

The `_FakeBackend` test fixture was extended with a constraint DELETE
handler, an `'angle'` constraint POST case, a Point PATCH handler, and
a settable `dof` field (driving `isUnderConstrained` in tests, since
that field only ever changes off a real solve response).

Verified:
- `flutter analyze` — 0 issues across the whole client.
- `flutter test test/sketch_controller_test.dart` — 72/72 passing.
- `flutter test` (full suite) — the same pre-existing, unrelated
  `flutter_scene`/`flutter_gpu` version-mismatch failures noted in the
  Stage 13 status doc (`mesh_geometry_test.dart`,
  `orbit_camera_test.dart`, `part_screen_test.dart`,
  `reference_planes_test.dart`, and 3 others fail to *load*); confirmed
  unrelated by checking those files' imports against this stage's
  changed files (no overlap).
- Backend: unchanged this stage — no backend files touched.

## Known limitations

- `isUnderConstrained` is a whole-sketch dof>0 check, not a per-entity
  freedom check — in a sketch with some Points fully constrained and
  others free, dragging is offered (and will be reverted by the
  re-solve on release) even on a Point that individually has no freedom
  left, because the backend doesn't expose anything finer-grained to
  query.
- Dragging only ever repositions a Point directly; dragging a
  Line/Circle drags whichever of its own Points is nearer the original
  click, not some independent "move the whole entity rigidly" behavior
  (there's no such operation in the backend's data model — a Line/
  Circle's shape is entirely defined by the Points it references).
- No on-device/visual verification was possible in this sandbox setup
  beyond what `flutter analyze`/`flutter test` can check.
- The `flutter_scene`/`flutter_gpu` version mismatch noted in the Stage
  13 status doc is still present and still unrelated to the Sketch
  work in this or the prior stage.

## Branch / commit state

Both stage commits are pushed to `claude/new-session-4x25e8`:
- `d452500` — Point tool, point/midpoint snapping, constraint
  selection, dimension-mode revamp.
- `451df0d` — Double-click-drag to reposition under-constrained
  Points.

## What's next

- If a future stage extends dragging to dimension labels directly
  (rather than via their anchor Points), it will need a concrete
  direction-to-value mapping spec first — none exists yet.
- The still-inert constraint options noted in the Stage 13 doc
  (Parallel, Perpendicular, Equal Length, Concentric, Equal Radius,
  Tangent, Coincident) remain unwired; this stage didn't touch them.
- The `flutter_scene`/`flutter_gpu` version mismatch blocking several
  unrelated test files should still be tracked as its own follow-up.
