# Stage 23 status — 2026-06-26

Branch: `claude/didsa-cad-stage-23-j25i32`.

Note: `docs/stage23-background.md`, referenced by the brief, does not exist
anywhere in this repo (checked the working tree and `git log` for the path) -
proceeded directly from the brief's own item descriptions and from reading
the existing `client/lib/sketch/` source instead.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 23a | Fix Set Length dialog `_dependents.isEmpty` crash | Complete | `sketch_ribbon.dart` |
| 23b | Reset View → Zoom to Fit, remove hardcoded zoom-out limit | Complete | `sketch_viewport.dart`, `sketch_canvas.dart`, `sketch_controller.dart` |
| 23c | Shorten constraint button labels | Complete | `sketch_controller.dart` |
| 23d | Remove tap-empty-canvas Exit Sketch surf | Complete | `sketch_controller.dart`, `sketch_ribbon.dart` |
| 23e | Constraint labels/tap-select for every constraint type | Complete | `sketch_canvas.dart` |
| 23f | Hamburger drawer: Exit Sketch + View submenu | Complete | `sketch_screen.dart` |
| 23g | Long-press marquee selection | Complete | `sketch_canvas.dart`, `sketch_controller.dart` |
| 23h | Selected Entities list in the flyout | Complete | `sketch_ribbon.dart`, `sketch_controller.dart` |

## What changed, by item

**23a — Set Length dialog crash**: The crash was a focus-teardown race, not
a Provider/InheritedWidget issue (there is no `provider` package anywhere in
this codebase - state flows through `ChangeNotifier` + `AnimatedBuilder`
only). `_SetLengthDialog`'s `TextField` used `autofocus: true` with no
explicit `FocusNode`, so Flutter's deferred focus-grant could still be
in flight when `_submit`/`_cancel` synchronously popped the dialog route,
tripping a `_dependents.isEmpty` assertion as the focus scope tore down
mid-rebuild. Fixed by giving the field its own `FocusNode`, calling
`.unfocus()` synchronously *before* `Navigator.pop()` in both `_submit` and
the (previously-missing) `_cancel` handler, and disposing the node in
`dispose()`.

**23b — Zoom to Fit**: `SketchController.geometryBoundingBox` (new getter)
computes the sketch-space bounding box of every Point plus every Circle's
full extent (center ± radius - a circle's own Points are just its center and
radius handle, not its rim). `SketchViewport.zoomToFit(boundingBox, size,
{padding})` fits that box into the canvas with a 12.5%-per-side margin,
falling back to `reset()` when there's no geometry. The old fixed `minZoom =
0.2` constant (screen-size-independent, so it could show far less than
1000mm on a small canvas) was replaced with `minZoomFor(Size)`, which derives
the zoom floor from the canvas's shorter side so the most-zoomed-out state
always shows at least 1000mm on both axes regardless of window size. The
canvas's top-left button was renamed "Zoom to fit" and is now always visible
(previously it only appeared once `zoom != 1`), with its `onPressed` calling
`_viewport.zoomToFit(widget.controller.geometryBoundingBox, size)`.

**23c — Shorter constraint labels**: In
`SketchController.availableConstraintOptions`: `Vertical → Vert.`,
`Horizontal → Horiz.`, `Perpendicular → Perp.`, `Coincident → Coinc.`. Left
`Parallel`, `Equal`, `Collinear`, `Concentric`, `Tangent` as-is since they
were already short. The ribbon's own "Set Length" chip label (not a
`ConstraintOption`, so not touched by the above) was shortened to "Length"
in `sketch_ribbon.dart`.

**23d — No more tap-to-exit on blank canvas**: `SketchController.
_handleSelectTap`'s blank-canvas branch no longer sets `_ribbonVisible =
true` - a tap on blank canvas while the ribbon is already closed is now a
pure no-op (it still closes the ribbon, as before, if one was open).
`SketchRibbon._body`'s empty-selection branch (which used to render the
"Exit Sketch" `ListTile`) now returns `SizedBox.shrink()`; that branch is
unreachable in practice post-23d, but is kept rather than asserted against,
since `selectionSet` is plain client state and a future regression
shouldn't crash the widget tree.

**23e — All constraint types get labels**: `_constraintLabelCenter`
(hit-testing) and the dimension-overlay paint loop in `sketch_canvas.dart`
previously only switched on `{Distance, Vertical, Horizontal, Angle,
LineDistance}`, falling through to "no badge" for everything else. Added
cases for `Coincident`, `Parallel`, `Perpendicular`, `EqualLength`,
`Collinear`, and `PointLineDistance`:
- `Coincident` reuses the existing point-pair-midpoint anchor (same as
  Vertical/Horizontal) with the label `Coinc.`.
- `Parallel`/`Perpendicular`/`EqualLength`/`Collinear` all anchor at the
  midpoint *between* the two constrained Lines' own midpoints (new
  `_twoLineMidpointScreen` helper), with glyphs `∥`, `⟂`, `=`, `Collin.`.
- `PointLineDistance` anchors between the Point and the Line's midpoint,
  labeled with its numeric distance (mirrors `_paintDistanceDimension`'s
  convention).
`AtMidpointConstraintDto` is deliberately still excluded from both switches
- Stage 22 decided it renders no badge at all (a pure construction-time
fixup with nothing to label or delete from the canvas), and that decision is
unchanged here.

**23f — Hamburger drawer**: `SketchScreen` gained a `Scaffold.drawer`,
opened via a new AppBar menu `IconButton` (a `GlobalKey<ScaffoldState>` is
used to call `.openDrawer()`, since the AppBar's own `build` context sits
above the `Scaffold` it returns). The drawer has "Exit Sketch" as the first,
most prominent tile (closes the drawer, then pops the route - same path the
back button already used), then a `View` `ExpansionTile` (expanded by
default) with:
- A `Constraint Labels` `SwitchListTile` (default on, plumbed into
  `SketchCanvas.constraintLabelsVisible`, which gates
  `_paintDimensionOverlays` entirely when off - tap-to-select on a label is
  left as-is, since the brief only asked for hiding the rendering).
- A `Canvas Colour` picker (bottom sheet of 5 swatches, plumbed into
  `SketchCanvas.canvasColor`).
- A `Canvas Transparency` slider (0-100% in 5% steps, plumbed into
  `SketchCanvas.canvasOpacity`, applied via `canvasColor.withValues(alpha:
  canvasOpacity)` when painting the background).
All three are in-memory/session-only state owned by `_SketchScreenState`,
matching the brief ("no persistence, unlike `viewport3d`'s
`ViewPreferences`").

**23g — Long-press marquee selection**: Added to `_SketchCanvasState`'s
existing hand-rolled `Listener`-based gesture state machine (this codebase
has no `GestureDetector`/`LongPressGestureRecognizer` anywhere in this file
- everything is raw `PointerDownEvent`/`PointerMoveEvent`/pointer-end
dispatch, so the new gesture had to be built the same way to coexist with
tap, double-click-drag, pan, and pinch-zoom):
- `_maybeStartLongPress` starts a 500ms `Timer` only when the pointer-down
  lands on truly empty canvas in `SketchMode.select` (checked via new
  `SketchController.hasEntityNear`, which reuses the existing `_entityAt`
  hit-test core including the origin Point, so a long-press near *any*
  selectable thing - or the origin - never turns into a marquee).
- If the pointer travels more than `_tapTravelThreshold` (10px, the
  existing tap/drag threshold) before the timer fires, `_cancelLongPress`
  kills it.
- Once the timer fires, `_startMarquee` flips `_marqueeActive = true`,
  shows a swell-and-pop circle (a new 350ms `AnimationController` - required
  switching `_SketchCanvasState` from `SingleTickerProviderStateMixin` to
  the broader `TickerProviderStateMixin`, since `_edgePanTicker` already
  occupies the single-ticker slot), and from then on
  `_handlePointerMove`/`_handlePointerEnd` divert entirely to marquee
  handling (live rectangle tracking, then `_endMarquee` on release).
- `_endMarquee` converts both screen-space corners to sketch space via
  `ViewTransform.screenToSketch` and calls the new
  `SketchController.selectInRect(Rect)`, which wholesale-replaces
  `selectionSet` with every Point/Line/Circle *fully* inside the rect
  (a Line/Circle counts as inside only when both endpoints, or the full
  bounding box for a Circle, are inside) - the origin Point is excluded,
  same as `selectAll`. Unlike `selectAll`, `selectInRect` does **not**
  auto-include each selected entity's Constraints (see the method's own doc
  comment) - this matches the brief's literal "entities fully inside the
  box" and the existing tap-based multi-select path's same limitation,
  rather than introducing new special-casing.
- Two new `CustomPainter`s (`_MarqueePainter`, `_LongPressPopPainter`),
  both wrapped in `IgnorePointer` so they never intercept pointer events
  meant for the `Listener` beneath them.
- Caught and fixed two bugs during self-review before they shipped: (1) an
  early draft canceled the pending long-press timer (nulling the anchor)
  *before* checking whether a marquee was active, which would have made
  every marquee selection a no-op; (2) the marquee-active branch in
  `_handlePointerEnd` was missing `_activeTouches.remove(event.pointer)`,
  which every sibling branch in that method already does - left in, it
  would have left a stale touch-pointer id corrupting the next gesture's
  single-vs-multi-touch detection.
- Known, accepted limitation (not fixed, by design): `_handlePointerEnd`'s
  marquee-active check isn't pointer-id-scoped, so an unrelated second
  finger touching down and lifting mid-drag would end the marquee
  prematurely. The pre-existing `_draggingPointId`/`_draggingLabelId`
  branches in the same method have an identical simplification, so this
  matches established codebase behavior rather than introducing a new gap.

**23h — Selected Entities list**: `SketchController.deselect(SketchSelection)`
removes one entity from `selectionSet` without touching the rest (closing
the ribbon if it was the last one); `SketchController.selectionLabel
(SketchSelection)` returns a short name ("Line 2", "Point 1", ...) derived
from each entity map's plain iteration order (these maps are
insertion-order-preserving `LinkedHashMap`s, seeded from the backend once
and only ever appended to - see `_loadExistingContent`/draw-tool methods) -
session-only, not a persisted number. Point numbering excludes the origin
Point, matching every other selection path. `SketchRibbon._body` now shows
a new `_SelectedEntitiesList` (a height-capped `ListView.builder`, one
`ListTile` per selected entity with a × calling `deselect`) above the usual
chip row, but only once `selectionSet.length >= 2` - a single selection is
already named by the panel's own heading, so the list would be redundant.

## New test coverage

`selectAll` (Stage 19b) itself had no dedicated unit test before this
stage, so this codebase's controller-method test coverage isn't uniformly
exhaustive - but given how easy these four new methods are to verify and
how cheap the insurance is, added a new group to the end of
`client/test/sketch_controller_test.dart` covering all four:
- `hasEntityNear` near geometry vs. on empty canvas, and near the origin
  Point specifically.
- `selectInRect` selecting a fully-inside Line (and both its endpoints)
  while excluding one outside the rect; never selecting the origin Point
  even when the rect contains it; and selecting a Circle only once its
  full bounding box - not just its center - is inside.
- `deselect` removing one entity from a multi-selection without disturbing
  the rest, then closing the ribbon once the last one is removed.
- `selectionLabel` naming a Line/Point/Circle by creation order, confirming
  Point numbering skips the origin.

No widget-level test coverage exists (or was added) for the `sketch_canvas.dart`
gesture/painter changes or the `sketch_ribbon.dart` list widget itself -
there is no `sketch_canvas_test.dart`/`sketch_ribbon_test.dart` in this repo
to extend, and building one from scratch (simulating raw pointer event
sequences against a real `Listener` tree) was judged out of scope for this
stage; this is a pre-existing gap, not one introduced here.

## Test/analyze results

Same sandbox limitation as every prior stage in this repo's history: no
Flutter/Dart SDK is installed (`which flutter dart` finds nothing, and a
filesystem sweep for a Dart SDK turns up empty), so `flutter analyze` and
`flutter test` could not actually be run here. All verification was manual:
- A small Python brace/paren/bracket balance script, run via Bash, against
  every touched file (`sketch_controller.dart`, `sketch_canvas.dart`,
  `sketch_ribbon.dart`, `sketch_screen.dart`, `sketch_viewport.dart`,
  `sketch_controller_test.dart`) - all reported a final depth of 0 (no
  mismatches).
- Full `git diff` review of every touched file, line by line, cross-checking
  method signatures, field names, and control flow against the surrounding
  unedited code.
- Confirmed via `grep` that every new alpha-blended `Color` in this stage's
  changes uses `withValues(alpha:)`, never the deprecated `withOpacity()`
  (and that no `withOpacity` calls exist anywhere in `sketch_canvas.dart`
  at all).
- No coordinate-tolerance point merging was introduced anywhere (`selectInRect`'s
  "fully inside" check is a plain inequality against the rect's exact
  bounds, with no snapping/fuzzing).
- The CI workflow in this repo (`.github/workflows/backend-verify.yml`)
  only builds/tests the Python backend - there's no Flutter CI job, so a
  push to this branch gives no automated signal on the client changes
  either. Real verification of `flutter analyze`/`flutter test` passing
  will have to happen wherever this branch is next opened with the Flutter
  SDK available.

## Known gaps / deferred

- No on-device/emulator verification of any of the above - every claim is
  based on manual code reading only, same caveat as every prior stage's
  status doc.
- 23g's `selectInRect` omits Stage 21 item 4's constraint-auto-inclusion
  that `selectAll` has (deliberate, documented scope decision - see the
  method's doc comment in `sketch_controller.dart`).
- 23g's `_handlePointerEnd` marquee-end check isn't pointer-id-scoped (see
  above) - a pre-existing-pattern simplification, not a new regression.
- No widget-level test coverage for `sketch_canvas.dart`'s new gesture/
  painter code or `sketch_ribbon.dart`'s new list widget (see "New test
  coverage" above).
- `docs/stage23-background.md`, which the original brief said to read
  before starting, does not exist anywhere in this repo's working tree or
  history - flagged here in case it was meant to be added separately and
  never landed.

## Branch / commits

Branch: `claude/didsa-cad-stage-23-j25i32`. All of Stage 23 (23a-23h) is
included in this branch's commit(s) - see the branch's commit log for exact
hash(es)/message(s).
