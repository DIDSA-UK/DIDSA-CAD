# DIDSA-CAD Status Summary — 2026-06-23 (Stage 13)

## What this covers

Stage 13 — Sketcher UX: Tap-to-Place, Dimension Workflow & Constraint
Selection. Backend gains a PATCH endpoint for editing an existing
constraint's numeric value (closing the gap noted at the end of the
Stage 12 status doc). Client gets tap-to-place point input, a
two-level FAB ("Sketch Entities" / "Dimensions") replacing the old flat
tool row, a full client-side ghost-dimension workflow (length, V/H
distance, radius/diameter) that confirms into real constraints, and
multi-entity selection with Vertical/Horizontal added to the
constraint flyout.

## Backend — complete and tested

- `backend/app/sketch/schemas.py`: new `ConstraintValueUpdate(value:
  float)`.
- `backend/app/sketch/router.py`: `PATCH
  /sketch/sketches/{sketch_id}/constraints/{constraint_id}`. Looks up
  the constraint, sets `DistanceConstraint.distance` or
  `AngleConstraint.angle_degrees` from `payload.value`, re-solves, and
  returns the same `SolveResultResponse` shape as `POST .../solve` and
  every constraint-creation endpoint (so the client can refresh points
  off the response the same way it already does elsewhere).
  Vertical/Horizontal constraints have no numeric value and get a 422
  instead.
- `backend/tests/test_stage12_constraints.py` gained coverage for the
  new endpoint (PATCH on a Distance constraint changes the solved
  geometry; PATCH on a Vertical constraint 422s).
- Verified: `178 passed` for the full backend suite (`pytest -q` from
  `backend/`), no regressions.

## Client — items 3–6 complete

All client work this session builds on the Stage 12 codebase and is
**uncommitted in the working tree** as of this writing — see "Branch /
commit state" below.

### Item 3 — tap-to-place point input (done)

- `client/lib/sketch/sketch_controller.dart`: `kTapToPlace = true`
  feature-flag constant (kept as a stub per the prompt — there is no
  alternate code path behind it; tap-to-place *is* the only input
  method now, replacing the old button-driven placement).
- Single entry point `Future<void> handleCanvasTap(double sketchX,
  double sketchY, [double? hitRadius])` dispatches by `mode` to
  select/draw/dimension handlers. Draw-mode placement (line chaining,
  circle center+radius) now happens directly off the tapped
  coordinate; existing snap-to-origin / snap-to-chain-start logic is
  unchanged.
- `client/lib/sketch/sketch_canvas.dart`: `minTapHitRadiusPixels =
  22.0` and `hitRadiusForPixelsPerUnit(pixelsPerUnit)` enforce a
  44×44-logical-pixel minimum hit target regardless of zoom — the
  canvas converts the tap's pixel position to sketch space and passes
  this radius through to select/dimension-mode hit testing (draw mode
  keeps using the fixed `snapRadius`, since its targets — origin,
  chain start — are deliberately small and zoom-independent).

### Item 4 — FAB restructure (done)

- `client/lib/sketch/sketch_controller.dart`: new `FabMenuState`
  enum (`closed` / `categories` / `sketchEntities`) plus
  `openFabMenu`/`closeFabMenu`/`showSketchEntitiesCategory`/
  `backToFabCategories`. Lives on the controller (not local widget
  state) specifically so `SketchScreen`'s tap-outside barrier can
  close the menu independently of the FAB widget itself.
- `client/lib/sketch/sketch_speed_dial.dart`: rewritten as a stateless
  widget driven entirely by `fabMenu`. Tapping the main FAB toggles
  `categories`; tapping "Sketch Entities" expands in place into
  Line/Circle/Finish (Finish only shown mid-chain) plus a Back action;
  tapping "Dimensions" calls `enterDimensionMode()` directly (no
  intermediate tool list — there's only one dimension mode).
- `client/lib/sketch/sketch_screen.dart`: added an opaque
  `Positioned.fill` `GestureDetector` beneath the FAB in the `Stack`
  that closes the menu on any tap outside it, present only while
  `fabMenu != closed`.

### Item 5 — dimension workflow (done)

- `client/lib/sketch/sketch_controller.dart`: `SketchMode.dimension`
  (separate from `select`/`draw`; `modeLabel` returns `'Dimension'`).
  `_handleDimensionTap`: tapping a Line builds a single length ghost;
  tapping a Circle builds simultaneous radius + diameter ghosts; a
  first Point tap followed by a second, distinct Point tap builds
  simultaneous vertical + horizontal distance ghosts (intentionally
  Point-only — Stage 13 didn't ask for line-to-line or point-to-line
  distance dimensioning, and the existing entity model gives no
  unambiguous "distance between a point and a line" semantics to
  invent on the spot). Tapping empty canvas with nothing picked exits
  to select mode; tapping empty canvas after a partial pick clears
  just the pick.
- `DimensionGhost`/`GhostKind` model the client-side-only preview:
  `tapGhost(key)`/`cancelGhostEdit()` toggle which ghost has its inline
  editor open; `currentGhostValue(ghost)` prefills that editor from any
  *existing* matching constraint (a circle's radius ghost, for
  instance, prefills from the radius `DistanceConstraint` the backend
  auto-creates on circle creation) — the floating ghost label itself is
  always the literal `'?'` (or `'⌀?'` for diameter), regardless of any
  existing value, by design: the label is a "tap here to dimension"
  affordance, not a value display: the inline editor is the only place
  a number ever appears before confirmation.
  `confirmGhostValue(key, value)` halves the value for
  `GhostKind.diameter` (diameter is always stored as a halved-radius
  `DistanceConstraint`, there being no separate diameter-constraint
  type), PATCHes an existing matching constraint if one is found
  (`_findDistanceConstraint`, checked both point-id orders) or
  otherwise POSTs a new one and explicitly solves, then refreshes
  points/constraints and clears all ghost state.
- `client/lib/sketch/sketch_canvas.dart`: shared `_GhostLayout`/
  `_layoutGhost` function used by both the ghost painter and the
  tap-hit-tester (`_ghostKeyAt`), so a ghost's rendered label position
  and its tappable area can never drift apart. Dashed `#888888`
  default ghost color, `#4A90D9` for the actively-edited ghost,
  `#555555` for other ghosts while one is active, dark semi-transparent
  pill behind the white label text — per the prompt's visual spec.
  `_dispatchTap` checks for a ghost-label hit before falling through to
  `controller.handleCanvasTap`.
- `client/lib/sketch/sketch_screen.dart`: a mode-label pill (shown
  whenever `mode != select`, i.e. also covers `draw`, unchanged from
  Stage 12) doubles as the dimension-mode exit affordance — tapping it
  calls `exitToSelectMode()`.

### Item 6 — constraint UX (done)

- `client/lib/sketch/sketch_controller.dart`: `selectionSet` (list,
  exposed read-only) replaces the old single-entity `selection`
  (`selection` is kept as a `.first`-or-null compatibility getter).
  Tapping a new entity while the ribbon is already open adds to the
  set instead of replacing it. `availableConstraintOptions` returns a
  `ConstraintOption{type, label, wired}` list keyed off the current
  selection-set shape: a single Line offers wired Vertical/Horizontal;
  two Lines offer unwired Parallel/Perpendicular/Equal Length; two
  Circles offer unwired Concentric/Equal Radius; a Circle+Line offer
  unwired Tangent (there is no Arc entity in this codebase — Circle is
  the standing substitute everywhere the original ask said "arc," per
  the same scoping call made in earlier stages); a Point alongside
  another Point or Line offers unwired Coincident. `wired:false`
  options render greyed-out/non-tappable in the ribbon — only
  Vertical/Horizontal actually call through to constraint creation in
  this stage, matching what the backend and prompt actually specify;
  the rest are visible-but-inert placeholders for a future stage.
- `client/lib/sketch/sketch_ribbon.dart`: rewritten chip row ordering —
  Construction toggle (if applicable) → constraint options → Delete
  last — in a horizontally-scrolling `Row` so more than ~4 chips don't
  overflow. Tapping empty canvas with no selection still dismisses the
  ribbon and clears the selection (unchanged from Stage 12, now
  clearing the whole set).
- `client/lib/sketch/sketch_canvas.dart`: painter's selection
  highlighting changed from "is this the one selected entity" to "is
  this entity in the selection set," applied at all four
  entity-rendering sites (lines, circles, origin, regular points).

## Test coverage

`client/test/sketch_controller_test.dart` was rewritten against the
new controller API (the old version called now-removed `click()`/
`setTool()` methods and a no-arg `handleCanvasTap()`). All previously
existing behavioral coverage was preserved, re-expressed against
`selectDrawTool`/`handleCanvasTap(x, y)`/`exitToSelectMode`, plus new
coverage for: the FAB state machine; `selectDrawTool`/
`enterDimensionMode`/`exitToSelectMode` mode transitions and their
"abandon any in-progress chain/circle, start clean" behavior (a
deliberate Stage 13 change from Stage 12, where switching tools
mid-chain left the chain alone — now mutually exclusive by
construction, since chains only exist in draw mode and switching tools
or modes always clears draw-mode-local state); `availableConstraintOptions`
content for single-line and single-point selections; `applyConstraintOption`
for Vertical/Horizontal; the line-length, two-point V/H, and
circle radius/diameter ghost workflows, including the diameter-confirm
path that PATCHes a circle's pre-existing auto-created radius
constraint and halves the stored value; `cancelGhostEdit`; and the two
empty-canvas-in-dimension-mode exit behaviors. Two Stage-12-era tests
were retired because they describe states the new design makes
unreachable: "selecting a different tool doesn't disturb an
in-progress chain" (now false by design, replaced with a test of the
actual new behavior) and "handleCanvasTap is a no-op mid-chain" (chains
and select-mode taps can no longer coexist at all).

The `_FakeBackend` test fixture was extended to handle constraint
creation (vertical/horizontal/distance, inferring point ids from the
referenced line for V/H) and the new PATCH-by-value endpoint.

Verified:
- `flutter analyze` — 0 issues across the whole client.
- `flutter test test/sketch_controller_test.dart` — 52/52 passing.
- `flutter test` (full suite) — the same pre-existing, unrelated
  failures as on `main`/this branch's base (see "Known limitations"):
  `mesh_geometry_test.dart`, `orbit_camera_test.dart`,
  `part_screen_test.dart`, `reference_planes_test.dart`, and 3 others
  all fail to *load* due to a `flutter_scene`/`flutter_gpu` version
  mismatch in this environment's pub cache, unrelated to anything
  Sketch-related and confirmed to fail identically with this session's
  changes stashed out.
- `backend`: `178 passed`.

## Known limitations

- The `flutter_scene 0.18.1` package in this environment's pub cache
  calls `flutter_gpu` APIs (`VertexLayout`, `VertexAttribute`,
  `TextureCompressionFamily`, etc.) that don't exist in the
  `flutter_gpu` shipped with this environment's Flutter SDK build —
  this is a pre-existing environment/dependency mismatch (confirmed to
  reproduce identically with this session's changes stashed out),
  unrelated to Stage 13, and blocks the four 3D-viewport-adjacent test
  files from loading at all. None of this session's changes touch
  `flutter_scene`/3D rendering.
- Per Stage 13's scope, the two-entity dimension flow only recognizes
  Point+Point taps (building V/H distance ghosts). Point-to-line or
  line-to-line distance dimensioning was not requested and isn't
  implemented.
- `wired:false` constraint options (Parallel, Perpendicular, Equal
  Length, Concentric, Equal Radius, Tangent, Coincident) render in the
  flyout but are non-functional placeholders — neither the prompt nor
  the backend specifies their creation semantics for this stage.
- No on-device/visual verification was possible in this sandbox setup
  beyond what `flutter analyze`/`flutter test` can check — ghost
  label/pill legibility, dash spacing, and FAB animation feel are
  reasoned through against the prompt's visual spec but not eyeballed
  on a running app.

## Branch / commit state

Backend (`ConstraintValueUpdate` schema, PATCH endpoint, new test
coverage) and client (Items 3–6, plus the full `sketch_controller_test.dart`
rewrite) are both complete and verified as of this writing, but
**uncommitted** in the working tree on `claude/new-session-4x25e8`.

## What's next

- Commit and push this stage's backend + client changes.
- If a future stage wires up the currently-inert constraint options
  (Parallel, Perpendicular, Equal Length, Concentric, Equal Radius,
  Tangent, Coincident), both the backend constraint types/endpoints and
  `applyConstraintOption`'s dispatch will need extending together.
- The `flutter_scene`/`flutter_gpu` version mismatch blocking four
  unrelated test files predates this stage and should be tracked as
  its own follow-up (likely a pub cache / SDK version pin fix) rather
  than addressed piecemeal per-stage.
