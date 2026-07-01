# Prompt B — device-testing bug-fix round — status — 2026-06-30 / 2026-07-01

Branch: `claude/new-session-g0yfjn` (same branch as Prompt B itself - these
fixes follow directly from on-device testing of that work, plus a couple of
longer-standing 3D-viewport issues raised in the same report). This doc now
covers four consecutive rounds of on-device bug reports and fixes, all on
the same branch: items 1–8 (2026-06-30), then items 9–14 (2026-07-01),
found by continuing to test each round's fixes on a real device/server and
reporting back what still didn't work.

## Round 1 (2026-06-30) — items 1–8

| # | Report | Status | Files changed |
|---|--------|--------|----------------|
| 1 | Cursor clamping erratic/jumps to centre; RTS edge-pan feel | Fixed | `sketch_controller.dart`, `sketch_canvas.dart`, `sketch_controller_test.dart` |
| 2 | "Fully constrained" always shows, even with no geometry; lines never grey | Fixed | `solver.py`, `sketch_controller.dart`, `test_stage15_constraints.py` |
| 3 | "Fully constrained" label hidden behind Exit Sketch button | Fixed | `sketch_canvas.dart`, `sketch_screen.dart`, `sketch_canvas_indicator_test.dart` |
| 4 | Double-tap drag on entities not working | Fixed (same root cause as #2) | (no additional change) |
| 5 | Selection hit box too big vs. hover highlight | Fixed | `selection_hit_test.dart`, `selection_hit_test_test.dart` |
| 6 | 3D viewport: pinch-zoom/two-finger-pan broken in selection mode | Fixed | `part_viewport.dart` |
| 7 | Dimension orientation reverts to linear after solve | Fixed | `sketch_controller.dart`, `sketch_controller_test.dart` |
| 8 | Feature tree text stays grey after deleting the last Feature | Investigated, no bug found; regression test added | `part_screen_test.dart` |

## Round 2–4 (2026-07-01) — items 9–14

Item 1's cursor fix and item 7's dimension-orientation fix both turned out
to be incomplete once retested for real - see items 9 and 13 below. Item 8
turned out to have a real bug after all, just not in the place the first
investigation looked - see item 14.

| # | Report | Status | Files changed |
|---|--------|--------|----------------|
| 9 | Cursor still teleports to centre mid-drag during RTS panning | Fixed | `sketch_controller.dart`, `sketch_canvas.dart` |
| 10 | Stale DOF after deleting a Circle (its radius constraint cascade-deletes too) | Fixed | `sketch_controller.dart` |
| 11 | Clearly under-constrained rectangle shown as "fully constrained" | Fixed (real solver bug) | `sketch_controller.dart` (rectangle construction), `test_stage15_constraints.py` |
| 12 | 2D sketcher hover highlight and tap-select hit boxes mismatched, both too large | Fixed | `sketch_controller.dart`, `sketch_canvas.dart`, `sketch_controller_test.dart` |
| 13 | Horizontal/vertical dimensions render as a diagonal linear dimension after solving | Fixed (rendering bug, not solver) | `sketch_canvas.dart`, `sketch_controller_test.dart` |
| 14 | Sketch stays greyed out/hidden after deleting the Extrude that consumed it | Fixed | `part_screen.dart`, `part_screen_test.dart` |
| 15 | No visual way to tell "under-constrained" apart from "not yet fully constrained" in the title bar; title bar overflow | Fixed | `sketch_screen.dart`, `sketch_canvas_indicator_test.dart` |

Also reported and independently confirmed fixed with no further change
needed: the Equal Length constraint, which was not behaving correctly
before item 11's fix - once the rectangle's redundant/singular constraint
(the actual cause of solve failures being misreported as `dof == 0`) was
removed, Equal Length reports came back clean on retest.

---

## 1 — Cursor clamping / RTS panning

**Root cause.** Prompt B's B0 item snapped the cursor to canvas centre the
instant a delta would push it out of bounds - including during ordinary
single-finger dragging near an edge, and every pan/zoom gesture, which
directly contradicted `SketchCanvas`'s own pre-existing class doc comment:
*"the controller's cursor stays in sketch-space coordinates throughout...
unaffected by how the view is panned or zoomed."* Snapping on every
in-flight delta (rather than only once genuinely off-canvas) is what
produced the reported "jumps to the middle, feels erratic" - most visibly
while RTS edge-pan was compensating for a fast drag one frame behind, so a
single oversized delta would trip the snap before the pan caught up.

**New model**, matching the requested behaviour exactly:
- Panning/zooming (two-finger drag, pinch, scroll-wheel, mouse right-drag)
  never touches the cursor's sketch-space position at all any more - it's
  simply left wherever it was, which may drift off-canvas as the view
  moves. `SketchController.clampCursorToBounds` (the mutating,
  snap-to-centre method) is gone.
- `SketchController.isCursorVisible(canvasSize, transform)` is a new pure
  query (built on the existing `clampCursorToCanvas` bounds check) - the
  canvas painter now skips drawing the crosshair entirely when this is
  false, i.e. the cursor "disappears" rather than being forced back.
- `moveCursorRelative` (single-finger touch drag) checks this *before*
  applying its own delta: if the cursor was already invisible, this call
  resets it to canvas centre and applies no delta (the "next interaction
  brings it back to centre" rule); otherwise the delta is applied
  normally, even if that pushes it off-canvas this time (it'll simply
  disappear, per the point above, rather than being caught mid-flight).
- `moveCursorAbsoluteScreen` (mouse) dropped its `canvasSize` parameter
  entirely - a real pointer event's position is always inside the
  canvas's own hit-test area already, so there was never anything to
  reconcile there.

**RTS edge-pan itself** (`_onEdgePanTick`'s idle-threshold/margin-speed
logic) was reviewed against the requested "pulled along while pushing past
the edge; not stationary" behaviour and already matches it - it re-anchors
the cursor to the same screen pixel each tick while `_lastCursorMoveTime`
is recent (a real, above-noise-threshold move within the last 150ms) and
the cursor sits in the edge margin, and stops the moment the finger
genuinely stops moving. No changes were needed there once the B0 snap
bug above (which fought with it) was removed.

**Tests**: replaced the old "snaps to centre" unit tests with ones
asserting the cursor is left off-canvas (not forced back) after a single
push-past-bounds delta, that a *second* delta while already off-canvas
resets to centre instead of resuming from off-screen, and that omitting
`canvasSize`/`transform` still never touches bounds at all (back-compat
for callers that don't care, e.g. most of the existing test suite). Added
an `isCursorVisible` unit-test group.

---

## 2 — "Fully constrained" always showing / lines never grey

**Root cause - a real backend bug, not just a UI gap.** `solve_sketch()`
short-circuited to a canned `dof=0` result whenever a Sketch had *zero*
Constraints, regardless of how much free, totally unconstrained geometry
it had. This was harmless before `dof` had any UI meaning, but every
entity-placement tool (Line/Circle/Rectangle/Point) calls solve once right
after creating something - so a sketch consisting of nothing but freshly
drawn, completely unconstrained lines reported `dof == 0` ("fully
constrained") to the client, which is backwards. This explains **both**
"fully constrained always shows" and "lines never render grey" (the same
symptom) - `isUnderConstrained` was reading `_dof > 0`, and `_dof` was
essentially never truthfully nonzero for ordinary freehand sketching.

**Fix.** `solve_sketch()` now always builds and solves the full system -
registering every Point (not just ones a Constraint happens to reference)
so its free parameters count toward `dof` - rather than skipping straight
past the solver. Verified directly against the installed py-slvs 1.0.6
wheel that solving an otherwise-constraint-free system is safe (no crash)
and reports the correct free-parameter count (e.g. 2 free Points → `dof ==
4`). The existing `"No constraints to solve."` detail message (which one
older test explicitly checks for) is preserved, now just reported
alongside a real `dof` instead of a hardcoded one.

**Also fixed - the "no geometry" case.** Even with the above fix, a truly
*empty* Sketch (nothing drawn at all) legitimately has `dof == 0` (nothing
but the pinned origin Point has any freedom to report) - which would make
the indicator light up before the user has drawn anything, exactly the
second half of the report ("does it lock on when there is no geometry? It
should be invisible"). Added `SketchController.hasGeometry` (`lines
.isNotEmpty || circles.isNotEmpty`), and the indicator now requires both
`!isUnderConstrained` *and* `hasGeometry`.

**Tests**: a new backend test asserts two free Points with zero
Constraints report `dof == 4`, not `0`; existing DOF tests re-verified
unaffected (63/63 passed in `test_stage15_constraints.py` +
`test_stage2b_solver_integration.py` together). Client-side coverage is
under item 3 below (the indicator moved location, so its tests moved with
it).

---

## 3 — Indicator hidden behind Exit Sketch / remove text, move to title bar

Removed the canvas-overlay badge (`_FullyConstrainedBadge`, a `Positioned`
top-right of `SketchCanvas` - which the Exit Sketch FAB, also top-right,
was drawn on top of) entirely. The indicator is now a plain `Icon(Icons
.lock)` - no text label - placed directly in `SketchScreen`'s `AppBar`
title `Row`, before the "DIDSA-CAD Sketch" text, shown only while
`!isUnderConstrained && hasGeometry`.

**Tests**: `sketch_canvas_indicator_test.dart` rewritten to pump the full
`SketchScreen` (rather than a bare `SketchCanvas`) and look for
`Icons.lock` in the title bar; added a fake `/lines` endpoint to its
trimmed backend so a test sketch can have actual geometry (the old test
placed only a standalone Point, which - correctly, per item 2's fix - no
longer counts as `hasGeometry`). Three cases: dof==0 with geometry shows
the icon, dof>0 doesn't, and a genuinely empty sketch with dof==0 doesn't
either.

---

## 4 — Double-tap drag on entities not working

No additional code change - `SketchCanvas._tryStartEntityDrag` only starts
a drag via `SketchController.dragTargetPointIdAt`, which is gated on
`isUnderConstrained` (the same `_dof > 0` flag item 2 above found was
essentially always false for ordinary unconstrained sketches, due to the
backend's old zero-constraints short-circuit). Fixing item 2 fixes this
directly: dragging is only ever offered for a sketch with genuine slack,
and the backend was never truthfully reporting that slack before.
(Double-tap-drag also requires being in Select mode, not Draw mode, which
is pre-existing/intentional and worth confirming on retest.)

---

## 5 — Selection hit box vs. hover highlight sizing

**Root cause.** `kSelectionHitRadiusPixels` (edges, 9px) and
`kVertexSelectionHitRadiusPixels` (vertices, 16px) were deliberately
different by design (a vertex is a single-point target needing more
forgiveness than a line/area target) - but hover and tap-to-select both
already read off the exact same `HoverHit` computation
(`_recomputeHover`/`_commitSelection` in `part_viewport.dart`), so the
"hover highlight" and "selection hit box" were never actually two
different targets, just an inconsistent one depending on what part of the
mesh you were near. On-device testing found the 9px/16px split felt
inconsistent, with a "sweet spot" somewhere between the two.

**Fix.** Both constants now equal `12.5` (the exact midpoint of the old
9/16 values) - `kVertexSelectionHitRadiusPixels` is now defined as `=
kSelectionHitRadiusPixels` rather than its own literal, so they can never
drift apart again by accident. The vertex-wins-over-nearer-edge priority
logic in `hitTestMeshEntities` (vertex in-range always beats a merely
raw-closer edge) is unaffected - that behaviour doesn't depend on the two
radii being different, only equal-or-not-equal doesn't matter to it.

**Tests**: updated `selection_hit_test_test.dart`'s two tests that
explicitly exercised the old 9px/16px gap - their numeric fixtures still
correctly hit the new unified 12.5px radius, so only their comments (which
described the now-removed "wider vertex radius" rationale) needed
correcting, not their assertions.

---

## 6 — 3D viewport: pinch/pan broken in selection mode

**Root cause.** `PartViewportState._onPointerMove` (the selection-mode
wrapper) unconditionally routed every non-mouse pointer-move into
single-finger relative cursor movement, with no multi-touch branch at all
- so a second finger touching down while in selection mode was never
recognised, and pinch-zoom/two-finger-pan (which orbit mode gets via
`_handlePointerMove`/`_applyPinchPan`) was unreachable whenever
`selectionMode` was on.

**Fix**, respecting the file's existing "never edit the orbit handler
bodies (`_handlePointerDown`/`_handlePointerMove`/`_handlePointerEnd`),
only the wrapper methods" rule:
- `_onPointerDown`'s selection-mode branch now also calls the existing
  `_handlePointerDown` (unmodified - it's pure `_activeTouches`
  bookkeeping, no camera side effect) so a second touch is tracked.
- `_onPointerMove`'s selection-mode branch now checks
  `_activeTouches.length >= 2` and, if so, calls the existing
  `_applyPinchPan` directly (the same method orbit mode's own
  `_handlePointerMove` calls) instead of treating the move as
  cursor-drag.
- `_onPointerEnd`'s selection-mode branch now removes the lifted pointer
  from `_activeTouches` (previously never cleaned up in selection mode at
  all) and gates its tap-commit on `!_hadMultiTouch`, mirroring orbit
  mode's own tap-vs-pinch-tail disambiguation exactly, so releasing one
  finger at the end of a pinch is never mistaken for a selection tap.

**Not tested here**: `part_viewport_test.dart` (and every other
`flutter_scene`-dependent test file) fails to even compile in this
sandbox - a pre-existing, documented (see Prompt D's status doc)
incompatibility between `flutter_scene ^0.18.1` and this environment's
bootstrapped Flutter engine snapshot, unrelated to this change.
`flutter analyze` on `part_viewport.dart` is clean.

---

## 7 — Dimension orientation reverting to linear after solve

**A real client bug, found on inspection.**
`SketchController._findDistanceConstraint(pointAId, pointBId)` matched an
existing `DistanceConstraint` by point-pair alone, ignoring orientation
entirely. Since `_buildPointDistanceGhosts` always offers all three
(vertical/horizontal/linear) ghosts simultaneously for the same two
points, confirming a *different* orientation than an already-existing
constraint between those points (e.g. placing a horizontal dimension
where a linear one already existed from an earlier pass) matched the old
one and only PATCHed its *value* - `update_constraint_value` never
touches `orientation` - so the dimension silently kept its original
(wrong) orientation no matter which ghost was actually tapped.

**Fix.** `_findDistanceConstraint` gained an optional `orientation`
parameter for an exact match. `confirmGhostValue` now looks up an
orientation-matching constraint first (PATCH its value as before, if
found); failing that, it separately checks for a same-point-pair
constraint of *any* orientation and, if one exists, deletes it (pushing
an undo that recreates it with its original value/orientation) before
creating the newly-requested one - so switching a dimension's
orientation for the same two points actually replaces it, rather than
silently keeping the old one.

**If this still reproduces after this fix**: the client always sends the
new `orientation` field on every distance-constraint request/expects it on
every response (see Prompt B's B3 item) - if the backend container
serving the device hasn't been rebuilt/redeployed with this branch's
backend changes yet, it will silently ignore the field (Pydantic ignores
unknown extra fields by default) and always solve/report a plain linear
distance, producing the exact same symptom for a completely different
reason. Worth ruling out before assuming there's a further client bug.

**Tests**: added a test placing a linear dimension between two points,
then re-picking the same pair and confirming a horizontal one instead -
asserts the old linear constraint is gone (not left in place as a second,
conflicting constraint) and the surviving one is the new horizontal one
with the newly-confirmed value.

---

## 8 — Feature tree text colour after deleting the last Feature

**Investigated at length; could not find or reproduce a bug.** Traced the
full path: `Part.is_locked` (backend) is computed live from the current
feature list on every request, not cached; `_cascadeDeleteFeature`
(client) always re-fetches the feature list via `_refreshFeatures()`
after any delete (explicitly "re-fetch rather than trim local state, so
the tree always reflects genuine backend state") inside a `_runGuarded`
block that does call `setState` once the fetch completes; the row
widget's lock icon colour reads `feature.locked` directly with no
caching or memoization in between. Nothing in this chain looks stale.

Added a regression test (`part_screen_test.dart`) that seeds two
Features, deletes the last (already-unlocked) one via the same
long-press-delete flow as the existing cascade-delete test, and asserts
the icon on the newly-last Feature is no longer grey/`Icons.lock`
afterward. Could not execute it in this sandbox (`part_screen_test.dart`
is one of the `flutter_scene`-incompatible files - see item 6's note);
`flutter analyze` is clean. Based on the code review above, this looks
like it should already pass - if the symptom persists on-device after
this branch is deployed, it likely needs a live repro (real device/
DevTools) to diagnose further, since nothing in the refresh pipeline
itself appears broken by inspection.

---

## 9 — Cursor still teleporting mid-drag during RTS panning

**Root cause.** Item 1's fix moved the "reset to centre" check into the
right method (`moveCursorRelative`), but left it running on *every* delta
during a drag, not just once at gesture start - so the instant a fast RTS
edge-pan pushed the cursor off-canvas for even one frame, the very next
touch-move event would see it as "already hidden" and snap it back to
centre, then immediately resume tracking from there. Visually this looked
exactly like the original bug: a teleport back to centre mid-drag,
followed by tracking resuming normally.

**Fix.** The reset check now lives in its own method,
`resetCursorToCentreIfHidden(Size canvasSize, ViewTransform transform)`,
called exactly once - from `_handlePointerDown`, at the start of a new
single-finger touch - rather than from inside `moveCursorRelative` on
every delta. `moveCursorRelative` itself goes back to the simple form: no
`canvasSize`/`transform` params, no reset logic, just apply the delta.

**Tests**: replaced the old per-delta reset test with one confirming
`moveCursorRelative` never resets or clamps regardless of how far
off-canvas the delta pushes the cursor, and a new `resetCursorToCentreIfHidden`
test group covering "does nothing while the cursor is already visible" and
"resets to centre once, from `_handlePointerDown`, when it isn't".

---

## 10 — Stale DOF after deleting a Circle

**Root cause.** `deleteSelected()` only called `_solveAndTrackDof()`
(which updates the client's cached `_dof`/`_lastSolveConverged`, driving
`isUnderConstrained`) when the thing just deleted was itself a
`Constraint`. Deleting a Circle cascades server-side to also delete its
radius `Constraint`, changing the sketch's real DOF - but the client-side
gate never saw a `Constraint` in the deleted-entity list (it saw a
`Circle`), so it skipped re-solving and kept showing the pre-delete DOF.

**Fix.** `deleteSelected()` now always calls `_solveAndTrackDof()` and
`_refreshConstraints()` after any deletion, regardless of what kind of
entity was deleted - simpler and correct, since every deletion can
potentially change DOF via cascade, not just a direct Constraint delete.

---

## 11 — Clearly under-constrained rectangle shown as "fully constrained"

**A real, previously-undetected solver bug**, found by testing the
rectangle's exact constraint set directly against the installed py-slvs
1.0.6 wheel rather than just re-reading the client code. B2's rectangle
construction (see Prompt B's own status doc) pins the construction
diagonals' shared centre Point with **two** `AtMidpoint` constraints - one
per diagonal. Once the four sides' H/V constraints force the two
diagonals to already share a midpoint by construction, the second
`AtMidpoint` constraint becomes redundant - and, worse, its Jacobian
becomes singular at that configuration. py-slvs then fails to converge
(`result.converged == False`, `result.result_code == 5`) but still
reports `result.dof == 0` - `Dof` and convergence are two independent
fields, and a failed solve does not reset `Dof` to a "not applicable"
value. The client was reading `dof == 0` alone as "fully constrained",
so a solve that had actually *failed* was shown as the most-constrained
state possible - exactly backwards, and exactly what the screenshot showed
(a draggable, clearly under-constrained rectangle with the padlock
locked).

**Fix, at both ends:**
- **Source**: `_buildRectangle` now creates only one `AtMidpoint`
  constraint (on the first diagonal) - one is sufficient once the H/V
  constraints already force both diagonals through the same point, so
  the second was never doing useful work, only introducing a singularity.
- **Defensive**: `SketchController.isUnderConstrained` no longer trusts
  `dof` when the last solve didn't converge - `_dof > 0 || !_lastSolveConverged`
  - so even an *unrelated* future solve failure can never again present
    itself as "fully constrained".

**Tests**: a new backend test reproduces the exact two-`AtMidpoint`
rectangle configuration and asserts it fails to converge (`result_code !=
0`); a second confirms one `AtMidpoint` constraint is sufficient and
converges cleanly with the expected DOF and centre-point position. Client
tests updated to expect 1 `AtMidpointConstraintDto` per rectangle instead
of 2.

---

## 12 — Sketcher hover/tap hit box mismatch, both too large

**Root cause.** `hoveredEntity` (continuous mouse/cursor hover) always
used the flat, unscaled `snapRadius` constant regardless of zoom, while
`handleCanvasTap`'s hit-test used a separate, zoom-scaled radius
(`hitRadiusForPixelsPerUnit`) - so the highlighted-on-hover entity and the
entity an actual tap would select could disagree, and neither matched what
felt like the right size on-device.

**Fix.** `hoveredEntity` is now a method taking an optional
`pixelsPerUnit` - when the canvas passes its current zoom through, it uses
the exact same `hitRadiusForPixelsPerUnit` calculation `handleCanvasTap`
already uses, so hover and tap now agree by construction rather than by
coincidence. Also reduced `minTapHitRadiusPixels` from `22.0` to `14.0` -
the shared value (now used by both) was too large on-device even once
unified.

**Tests**: a new test confirms `hoveredEntity(pixelsPerUnit)` finds a Line
at a distance the old flat-`snapRadius` behaviour would have missed, using
the identical radius `hitRadiusForPixelsPerUnit`/`handleCanvasTap` compute.

---

## 13 — Horizontal/vertical dimensions render as a diagonal linear dimension

**Not a solver bug - a rendering bug.** The underlying `DistanceConstraint`
solving was already orientation-aware from Prompt B's B3 item (verified
again here against real backend tests: pinning only the X or Y separation,
leaving the other axis free, exactly as designed). The bug was entirely in
`sketch_canvas.dart`'s rendering: `_paintDistanceDimension` (draws a
*confirmed* dimension) and `_constraintLabelCenter` (used for its label's
drag/hit-testing) both ignored `DistanceConstraintDto.orientation`
entirely and always used the generic "linear" layout - an offset line
running parallel to the two points, which is diagonal whenever the points
aren't already level or plumb. The ghost *preview* (`_layoutGhost`, before
confirming) already laid out horizontal/vertical dimensions correctly with
a proper offset-perpendicular dimension line - so the user would see a
correctly-oriented ghost while placing the dimension, then watch it
"become linear" the instant it was confirmed, even though the solver was
constraining it correctly the whole time.

**Fix.** Both `_paintDistanceDimension` and `_constraintLabelCenter` now
switch on `orientation` and lay out a proper horizontal/vertical dimension
line (extension lines to a fixed offset row/column, per the same math
`_layoutGhost` already used for the preview), instead of always falling
through to the diagonal linear layout.

**Tests**: two new tests confirm a confirmed horizontal/vertical
`DistanceConstraint` renders and hit-tests at its orientation-aware
anchor position, not the old diagonal-layout midpoint.

---

## 14 — Sketch stays hidden/greyed out after deleting its Extrude

**Root cause.** Confirming an Extrude auto-hides the Sketch it was built
from (`_confirmExtrude` adds the Sketch Feature's id to
`_hiddenFeatureIds`, so the consumed profile doesn't clutter the view
under the resulting solid). Cascade-deleting that Extrude only ever
cleared hidden ids belonging to Features that **no longer exist**
(`_hiddenFeatureIds.removeWhere((id) => !_features.any(...))`) - but the
Sketch still exists, it's just unlocked again - so its id stayed in the
hidden set forever. On-device this showed up exactly as reported: the
Feature tree row (and the 3D viewport) kept the Sketch dimmed/hidden even
once it was editable again.

**Fix.** `_cascadeDeleteFeature` now additionally un-hides the new last
Feature whenever it comes back unlocked - the Sketch was only ever hidden
because something depended on it; once nothing does, there's nothing left
making it redundant clutter.

**Tests**: a new test confirms/extrudes a Sketch (auto-hiding it), deletes
the resulting Extrude, and asserts the eye-slash "hidden" indicator is
gone from the tree afterward.

---

## 15 — Padlock indicator gap; title bar overflow

**Report.** A visibly under-constrained rectangle (a shape with 2 real
free DOF, confirmed by manually counting constraints against the
screenshot) showed *no* padlock at all - which is actually correct given
item 3/11's design (padlock only ever showed once fully constrained,
hidden otherwise), but meant there was no way to tell "genuinely
under-constrained" apart from "hasn't finished solving yet" just by
looking at the title bar. Separately, the title bar itself was visibly
overflowing (Flutter's debug yellow/black overflow banner, cutting through
the middle of "Sketch").

**Fix.**
- The indicator now always shows an icon once there's geometry:
  `Icons.lock_open` while under-constrained, `Icons.lock` once fully
  constrained - hidden only for a genuinely empty sketch (unchanged from
  item 3).
- The title `Text` is now wrapped in `Flexible` with ellipsis overflow -
  a plain `Text` inside a `mainAxisSize.min` `Row` had no way to shrink,
  so it could exceed the AppBar's available width by a couple of pixels
  on some device/text-scale combination and trip a `RenderFlex` overflow.

**Tests**: `sketch_canvas_indicator_test.dart`'s three cases updated -
closed padlock at `dof == 0`, **open** padlock (not "no icon") at
`dof > 0`, neither icon for an empty sketch.

---

## Test/analyze results

Same sandbox limitations as Prompt B's own status doc (no Flutter SDK or
backend conda toolchain preinstalled - see that doc's "Environment note"
for how both were bootstrapped locally; nothing from that bootstrapping is
committed).

**Round 1 (items 1–8):**
- Backend: `pytest` (whole suite) - 209 passed, 25 failed, same 25
  pre-existing OCC-stub-only failures as before (unrelated files, not
  touched here).
- Client: `flutter analyze` across every changed file - no issues.
  `flutter test` (whole suite) - 145 passed, 17 failed, all in
  `flutter_scene`-dependent files that fail to even compile in this
  sandbox (pre-existing, documented in Prompt D's status doc) -
  `part_viewport.dart`/`part_screen_test.dart`/`selection_hit_test_test
  .dart` changes could only be verified via `flutter analyze`, not
  `flutter test`, for this reason.
- `sketch_controller_test.dart` on its own: 129 passed, 4 failed - the
  same 4 pre-existing, unrelated failures documented in Prompt B's own
  status doc (`addCollinearConstraint`/`addEqualLengthConstraint`/
  `applyConstraintOption(collinear)` selection-clearing, and
  `dragTargetPointIdAt` offering the origin) - not investigated further
  here, out of scope for this bug-fix round.
- `sketch_canvas_ghost_editor_test.dart`'s one test
  ("Confirming a ghost-dimension value removes the still-focused inline
  editor without crashing") fails with a `pumpAndSettle` timeout -
  confirmed via a clean worktree checkout of the prior commit (before any
  of this round's changes) that this already failed identically before
  today's work; not a regression introduced here, and not investigated
  further as it's unrelated to any of the 8 items above.

**Rounds 2–4 (items 9–15, 2026-07-01):**
- Backend: item 11's new `test_stage15_constraints.py` tests pass (both
  the reproduction of the singular two-`AtMidpoint` configuration failing
  to converge, and the single-`AtMidpoint` fix converging cleanly).
- Client: `flutter analyze` across every changed file - no issues
  throughout all four rounds.
  `flutter test test/sketch_controller_test.dart` - 130/134 passed
  throughout items 9–13, same 4 pre-existing/unrelated failures as Round 1
  (not the same 4 by coincidence - confirmed by re-running against a clean
  checkout of each round's base commit with the round's own changes
  stashed out, each time reproducing identically).
  `flutter test test/sketch_canvas_indicator_test.dart` - 3/3 passed
  (item 15's open/closed/neither padlock cases).
- `part_screen_test.dart` (items 14's regression test): `flutter analyze`
  clean; `flutter test` still cannot execute this file at all in this
  sandbox - confirmed the failure is identical with or without this
  round's changes (a `flutter_gpu` API mismatch inside `flutter_scene`
  itself, unrelated to anything in this codebase - see "Known limitations"
  below), so item 14 could only be verified by `flutter analyze` plus
  manual trace of `_hiddenFeatureIds`'s full lifecycle, not by execution.
- `widget_test.dart`'s one test ("SketchScreen collapses to a single main
  FAB...") fails with a hit-testing error - confirmed via `git stash` to
  fail identically before item 15's changes; pre-existing, not a
  regression, not investigated further as out of scope.

## Known limitations - the `flutter_scene`/`flutter_gpu` sandbox mismatch

`flutter_scene ^0.18.1` (the 3D viewport's rendering package) requires
`flutter_gpu` APIs (`TextureCompressionFamily`, `GpuContext
.supportsTextureCompression`, several `PixelFormat` members, a
`vertexLayout` named parameter) that only exist in Flutter **master**
channel builds from 2026-06-09 or later - stated explicitly in
`flutter_scene`'s own `pubspec.yaml` (`flutter: ">=3.44.0"` is only there
so pub.dev, which scores against stable, can resolve the package; the real
requirement is master post-06-09). `flutter_gpu` ships bundled inside the
Flutter engine binary itself, not as a separately pinnable pub dependency.

This sandbox's bootstrapped Flutter SDK is a **stable 3.44.4** tarball
(built to work around this environment's git-history-based engine-version
detection failing against a synthesized single-commit repo), which
predates those master-only features - so any file that imports
`flutter_scene`/`viewport3d` fails to even compile under `flutter test`
here (11 files: `part_screen_test.dart`, `part_viewport_test.dart`,
`mesh_geometry_test.dart`, `orbit_camera_test.dart`, and others).
`flutter analyze` is unaffected, since it's pure static analysis with no
engine binary involved - every 3D-viewport-adjacent change in this branch
was verified that way instead, plus manual code review, and confirmed via
real on-device testing by the user. This is a sandbox-only limitation
(first documented in Prompt D's status doc), not present in the actual
build/CI environment, which already targets the Flutter version
`flutter_scene` requires.
