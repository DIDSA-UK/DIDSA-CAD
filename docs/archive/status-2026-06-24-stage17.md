# Stage 17 status — 2026-06-24

Branch: `claude/new-session-qvt039` (same branch as Stage 16, continued).
Follow-up to Stage 16, addressing user-reported regressions/gaps found
during real-device (Android/touch) testing of that stage's work.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Point tool: same fly-up tool bar (with Exit) as Line/Circle/Rectangle | Complete | `sketch_screen.dart`, `sketch_construction_method_bar.dart` |
| 2 | Double-tap-drag of a Point tracks the finger incorrectly (touch only) | Complete | `sketch_canvas.dart` |
| 3 | Sketch origin not selectable, so it can't be used as a constraint target | Complete | `sketch_controller.dart` |

## What changed, by item

**1 — Point tool fly-up bar**: `sketch_screen.dart` previously excluded
`SketchTool.point` from `showConstructionBar` entirely (no construction
method to choose, so the prior reasoning skipped the bar altogether) - now
every draw tool shows the bar (`showConstructionBar = mode ==
SketchMode.draw`, no per-tool exception), giving Point the same Exit button
the other tools have. `SketchConstructionMethodBar` shows a plain
`'Tap to place a point'` message in the chip row's place when
`activeTool == SketchTool.point`, instead of an empty chip row.

**2 — Touch point-drag tracking bug**: root cause was a coordinate-space
mismatch, not the delta-from-origin logic added in Stage 16 item 5 (which
was correct and is unchanged). Every other touch interaction in this app -
panning, drawing, hovering - moves the persistent on-screen cursor via
`SketchController.moveCursorRelative`, a deliberately heavily-desensitized
"trackpad" mapping (`touchSensitivity = 0.05`, further divided by zoom).
But `_handlePointerMove`'s point-drag branch instead fed the touch event's
*raw absolute* screen position through `ViewTransform.screenToSketch` - the
same 1:1 mapping used only for a real mouse - meaning a dragged Point
moved by a completely different (much larger, zoom-dependent-only) amount
than the same finger movement would move the cursor anywhere else in the
app. That mismatch is what made the Point appear to race away from /
"move below" the finger instead of tracking it. Fixed by branching on
`event.kind`: a mouse continues to use the absolute `screenToSketch`
mapping (unchanged), but touch now calls `controller.moveCursorRelative`
with the event's delta and zoom (the exact same call every other touch
interaction makes) and then feeds the *updated* `cursorX`/`cursorY` into
`updatePointDrag` - so the dragged Point now moves by precisely the same
amount, in the same direction, that the cursor itself would for that
gesture, eliminating the drift.

**3 — Origin not selectable for constraints**: Stage 16 item 4 added an
unconditional origin-exclusion to `_entityAt` (the shared hit-test behind
hover, select-mode tap resolution, *and* drag-target resolution), aimed at
making the origin "never selectable or deletable." That broke selection
entirely - including pre-existing tests (`hoveredEntity detects a nearby
Point...`/`handleCanvasTap selects the hovered entity...`, both of which
already asserted the origin is exactly what gets hovered/selected when the
cursor sits on it) - and blocked the legitimate case the user needed: a
Coincident constraint between a regular Point and the origin. `_entityAt`
now takes an `includeOrigin` parameter (default `false`, so
`dragTargetPointIdAt` - which never passes `true` - still excludes it,
keeping the origin un-draggable); `hoveredEntity` and `_resolveSelectableAt`
(behind both select-mode tap resolution and dimension-mode picking) now
pass `includeOrigin: true`. Deletion was already independently blocked via
`selectedPointDeleteBlockedReason`'s explicit `pointId == _originPointId`
check (greys out the flyout's Delete button) regardless of selectability,
so no change was needed there - the origin can now be selected and used as
one half of a Coincident (or any other point-based) constraint, but still
can't be deleted or dragged.

## Test/analyze results

Same sandbox limitation as every prior stage: no Flutter/Dart SDK on
`PATH`, so nothing below was executed - verified by manual reading only.

New/changed tests in `client/test/sketch_controller_test.dart`:
- `the origin is selectable so a Point can be constrained Coincident to it`
  - selects the origin via `handleCanvasTap(0, 0)`, adds a second Point to
    the selection, calls `addCoincidentConstraint()`, and asserts the
    resulting `CoincidentConstraintDto` references the origin's id and the
    second Point's id.
- `dragTargetPointIdAt never offers the origin as a drag target, even
  under-constrained` - guards the one case that must still be excluded
  even after item 3's fix (mirrors the existing `backend.dof = 1` pattern
  used by the other `dragTargetPointIdAt` tests).

No test exists (or previously existed) for `sketch_canvas.dart`'s gesture
handling (item 2) or for the `sketch_screen.dart`/
`sketch_construction_method_bar.dart` widget tree (item 1) - both are
widget-level and outside this project's existing controller-only test
coverage, consistent with prior stages.

## Branch / commits

Branch: `claude/new-session-qvt039`, pushed to
`origin/claude/new-session-qvt039`.
