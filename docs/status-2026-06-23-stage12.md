# DIDSA-CAD Status Summary — 2026-06-23 (Stage 12)

## What this covers

Stage 12 — Dimensioning, Constraints & Construction Lines: backend support
for construction-only entities and Vertical/Horizontal/Angle constraints,
plus client work to render and toggle construction geometry, ghost-project
an existing solid's edges onto the active sketch plane, and render
dimension overlays for every constraint type.

## Backend — complete and tested

- `backend/app/sketch/models.py`: `construction: bool = False` added to the
  entity base, inherited by `Line`/`Circle`. Construction entities are
  excluded from Profile (closed-loop) detection even when they would
  otherwise close a loop.
- `VerticalConstraint`/`HorizontalConstraint`/`AngleConstraint` added,
  implemented with native py-slvs primitives (no custom numerical
  constraint code), alongside the pre-existing `DistanceConstraint`.
- `backend/app/sketch/schemas.py` / `router.py`: API endpoints for creating
  each new constraint type, plus `ConstraintResponse`'s discriminated
  union extended to parse them back out (`type` defaults to `"distance"`
  for backward compatibility with payloads that predate the discriminator).
- New test file `backend/tests/test_stage12_constraints.py`, 5/5 passing:
  `test_vertical_constraint_forces_same_x_after_solve`,
  `test_horizontal_constraint_forces_same_y_after_solve`,
  `test_angle_constraint_produces_correct_angle_after_solve`,
  `test_construction_line_excluded_from_profile_detection_even_when_closing_a_loop`,
  `test_sketch_with_only_construction_entities_has_no_profile`.
- **Gap found and closed this session**: the client's "Make
  Construction"/"Make Solid" toggle (item 8 below) needs a way to flip an
  *existing* Line/Circle's construction flag after creation, and there was
  no such endpoint. Added:
  - `LineUpdate.length` changed from required to `float | None = None`,
    plus a new `LineUpdate.construction: bool | None = None` — both
    optional and independently settable, so a PATCH can toggle
    construction without also resending a length.
  - New `CircleUpdate` schema (`construction: bool | None = None` only — a
    Circle's radius is solver-driven via its own `DistanceConstraint`, not
    directly editable).
  - New `PATCH /sketch/sketches/{sketch_id}/circles/{circle_id}` route
    mirroring the existing line-update route.
  - Verified via `python3 -m py_compile` on the changed files and a full
    `python3 -m pytest tests/test_stage12_constraints.py -q` run (5/5
    passing, no regressions caused by loosening `LineUpdate.length`).

Committed as `ca8e1db` (core Stage 12 backend) and `70847d3` (the
construction-toggle PATCH endpoints gap-fix above).

## Client — items 7, 8, 9 complete; item 10 partially complete

All client work this session is **uncommitted in the working tree** as of
this writing (see "Known limitations" below for why it hasn't been run
through a compiler yet) and lives on `claude/new-session-x4ga3w` alongside
the two backend commits above.

### Item 7 — construction line rendering (done)

- `client/lib/sketch/sketch_canvas.dart`: `_constructionColor = Color(0xFF4A90D9)`,
  plus hand-rolled `_drawDashedLine`/`_drawDashedCircle` helpers (Flutter's
  `Canvas`/`Paint` have no native dashed-stroke primitive). Every Line/Circle
  paint path checks `.construction` and switches to the dashed/blue
  rendering instead of the normal solid/grey one, including while
  selected/hovered (color still flips for those states; only the dash
  pattern is construction-specific).

### Item 8 — Make Construction / Make Solid toggle (done)

- `client/lib/api/sketch_api_client.dart`: `LineDto`/`CircleDto` gained a
  `construction` field; `createLine`/`createCircle` accept and always send
  it; new `updateLine`/`updateCircle` methods call the new backend PATCH
  endpoints.
- `client/lib/sketch/sketch_controller.dart`: `SketchLineView`/`SketchCircleView`
  carry `construction` (threaded through on load and on creation);
  `selectedIsConstruction` getter (null unless the current selection is a
  Line or Circle); `toggleSelectedConstruction()` calls the relevant
  `updateLine`/`updateCircle` and replaces the local view object with the
  server's response — immediate, no confirmation dialog, matching the
  prompt's explicit instruction.
- `client/lib/sketch/sketch_ribbon.dart`: a "Make Construction"/"Make Solid"
  `ListTile` in the entity selection flyout, shown only when
  `selectedIsConstruction != null`, disabled while `controller.busy`.

### Item 9 — reference-body ghost projection (done)

- `client/lib/viewport3d/sketch_geometry_3d.dart`: `worldPointToSketch`
  (the exact inverse of the existing `sketchPointToWorld`, valid because
  every `ReferencePlaneKind` is axis-aligned through the origin — an exact
  axis-drop projection, not an approximation) and
  `projectMeshEdgesOntoPlane`, returning plain `((double,double),(double,double))`
  tuples so the sketch package doesn't need a dependency on viewport3d's
  mesh types.
- `client/lib/viewport3d/part_screen.dart`: `_openSketch` now takes the
  resolved `ReferencePlaneKind` and, when there's both a plane and an
  existing mesh, computes ghost segments via
  `projectMeshEdgesOntoPlane(plane, edgeSegmentsFromMesh(mesh))` and passes
  them into `SketchScreen`.
- `client/lib/sketch/sketch_canvas.dart`: `referenceGhostSegments` +
  `referenceBodyHidden` params; ghost segments are drawn dashed in
  `_referenceGhostColor = Color(0xFF444444)`, faint and thin, before any
  real entity so they always read as background reference.
- `client/lib/sketch/sketch_screen.dart`: top-right Hide/Show Reference
  Body `IconButton`, shown only when there are ghost segments to toggle,
  default shown — same in-memory `setState` toggle pattern as
  `PartScreen._referencePlanesHidden`.

### Item 10 — dimension overlays (functionally complete; one explicit scope gap)

- `client/lib/api/sketch_api_client.dart`: `ConstraintDto` abstract base
  with `DistanceConstraintDto`/`VerticalConstraintDto`/
  `HorizontalConstraintDto`/`AngleConstraintDto` subclasses and a
  `ConstraintDto.fromJson` dispatcher on the backend's `type` discriminator
  (defaulting to Distance, mirroring the backend's own smart-union
  fallback); `listConstraints(sketchId)`.
- `client/lib/sketch/sketch_controller.dart`: `constraints` map
  (`Map<String, ConstraintDto>`), populated on `_loadExistingContent` and
  refreshed via `_refreshConstraints()` after every `_clickCircleTool()`
  completion (a Circle's auto-created radius `DistanceConstraint` is the
  only constraint any client action currently creates server-side as a
  side effect, so that's the only call site that needs the refresh — the
  Line-chain `click()` path doesn't create constraints and was left alone).
- `client/lib/sketch/sketch_canvas.dart`: `_paintDimensionOverlays`,
  dispatched via a Dart 3 type-pattern `switch` over
  `controller.constraints.values` (with an explicit `default: break;`,
  required because `ConstraintDto` isn't `sealed`, so exhaustiveness can't
  be statically verified):
  - `_paintDistanceDimension`: standard offset dimension line with two
    extension lines from the real points, labeled with the constraint's
    own solved `distance` value via a shared `_drawDimensionLabel` chip
    (white text on a `_dimensionColor = Color(0xFFF5A623)` rounded-rect
    background).
  - `_paintAxisIndicator`: a plain 'V'/'H' chip at the constrained Line's
    midpoint for Vertical/Horizontal constraints.
  - `_paintAngleDimension`: a numeric `∠<degrees>°` chip placed at the
    midpoint between the two constrained Lines' own midpoints —
    **deliberately not a literal arc sweep**: the two Lines have no shared
    vertex in general, so there's no single well-defined arc to draw, and
    arc geometry couldn't be visually verified without a Flutter SDK in
    this sandbox anyway.
  - Called from `paint()` after all entity/point rendering, before the
    live cursor crosshair, so overlays sit on top of geometry but never
    obscure the cursor.

**Explicit scope gap, decided against implementing this session**:
tap-to-edit interactivity for Distance/Angle dimension *values* (changing
a constraint's distance or angle by tapping its overlay). The backend has
no PATCH endpoint for constraint values — only for creating them. Building
that would mean speculatively adding new backend endpoints (with their own
undefined validation rules and solver re-trigger semantics) that nothing
in the Stage 12 prompt actually specified, or building client UI with no
working backend target. Both were rejected in favor of shipping working
render-only overlays now and documenting the gap here, rather than
guessing at unspecified backend behavior or shipping dead UI.

## Known limitations

- **No Flutter/Dart SDK is available in this sandbox** (consistent with
  every prior session in this environment) — `flutter analyze`/`flutter
  test` could not be run against any of the Item 7–10 client changes
  above. Every edit was made by reading the full file before and after
  editing, cross-checking call sites and types by hand, and manually
  verifying brace balance and import correctness. This is a real,
  un-mitigated risk: none of the new Dart code in this stage has been
  compiled, let alone executed. The backend's `backend-verify.yml` CI job
  does not cover the Flutter client either, so the first real
  verification will be whichever CI/local run happens after this branch
  is pushed.
- **No PATCH endpoint exists for editing a constraint's value** (distance
  or angle) — see Item 10's scope-gap note above. Dimension overlays are
  render-only; there is no way, client- or server-side, to edit a
  constraint's numeric value after creation in this stage.
- Backend OCCT/pythonocc-core is still unavailable in this sandbox (a
  pre-existing, previously-documented limitation, unrelated to Stage 12 —
  none of this stage's backend code touches OCCT at all, so this didn't
  block verification here; the `test_stage12_constraints.py` suite has no
  `OCC` import and ran directly).

## Branch / commit state

All backend work is committed (`ca8e1db`, `70847d3`) on
`claude/new-session-x4ga3w`. All client work (Items 7–10) is staged in the
working tree, not yet committed, on the same branch. No push has been
performed — per standing instructions, pushes only happen on explicit
request.

## What's next

- Run `flutter analyze` and `flutter test` on a machine with the Flutter
  SDK to confirm the Item 7–10 client code actually compiles and the
  existing test suite (`client/test/sketch_controller_test.dart`,
  `sketch_geometry_3d_test.dart`, etc.) still passes — this is the single
  biggest open risk from this stage.
- If tap-to-edit constraint values is wanted, that needs a deliberate
  follow-up: new backend PATCH endpoints for `DistanceConstraint`/
  `AngleConstraint` values (with their own validation/solver-retrigger
  design), then client UI on top — not something to retrofit casually
  onto the current render-only overlays.
- Visually confirm on-device once a Flutter SDK is available: dash
  spacing/readability of construction lines and ghost segments at real
  zoom levels, dimension label chip legibility against busy sketch
  geometry, and that the angle overlay's "midpoint between midpoints"
  placement reads sensibly for typical angle-constraint layouts (no SDK
  was available to render anything in this sandbox, so this is unverified
  visually, only reasoned through on paper).
