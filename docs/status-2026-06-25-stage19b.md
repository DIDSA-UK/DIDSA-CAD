# Stage 19b status — 2026-06-25

Branch: `claude/new-session-wh9dee`.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 0 | Revert Stage 19a Item 1 (edge back-face cull) | Complete | `mesh_geometry.dart`, `part_viewport.dart`, `orbit_camera.dart`, `part_toolbar.dart`, `part_viewport.dart` |
| 1 | Feature tree: dedicated FAB | Complete | `part_screen.dart` |
| 2 | 3D view: contextual options → fly-up bottom sheet | Complete | `part_screen.dart`, `plane_context_sheet.dart` |
| 3 | Add FAB: Feature button → second-level picker | Complete | `add_button_menu.dart`, `feature_picker_sheet.dart`, `part_screen.dart` |
| 4 | Sketcher: undo | Complete (adapted design, see below) | `sketch_controller.dart`, `sketch_screen.dart` |
| 5 | Sketcher: select all | Complete | `sketch_controller.dart`, `sketch_screen.dart` |
| 6 | Sketcher line context menu: Set Length | Complete | `sketch_controller.dart`, `sketch_ribbon.dart` |
| extra | Auto-hide Sketch once used by a Feature | Complete | `part_screen.dart` |

## What changed, by item

**0 — Revert 19a Item 1**: User feedback after using the build: the
back-face edge cull made edges disappear on faces visible *through* a
transparent body, an unacceptable trade-off versus the original
bleed-through it was meant to fix. `cullBackFacingSegments` (and its call
sites in `part_viewport.dart`'s `_syncEdgesNode`/`_resyncEdgesAfterOrbit`,
and its four dedicated tests in `mesh_geometry_test.dart`) were removed
entirely, restoring the pre-19a edge rendering. All other Stage 19a items
(opaque alpha at full opacity, edge stroke width, off-white background,
default render mode + persistence, camera distance, autofill) were
confirmed still working as desired and left untouched.

**1 — Feature tree FAB**: Removed "Show Feature Tree" from the hamburger
View sub-menu; added a small secondary FAB (`FloatingActionButton.small`,
`Icons.account_tree_outlined`, tooltip `'Feature tree'`) positioned directly
below the hamburger button, toggling the same Feature tree panel
(`_toggleFeatureTree`) that the removed menu entry used to.

**2 — Contextual fly-up bottom sheet**: Tapping a reference plane or a
mesh body/face no longer opens the hamburger drawer. It now opens a
`showModalBottomSheet` (rounded top corners,
`BorderRadius.vertical(top: Radius.circular(16))`) with a drag handle, a
title row, and the same contextual actions that used to live in the
drawer, unchanged in behaviour — just relocated. New
`plane_context_sheet.dart` for the plane case; the body/face case is
inlined in `part_screen.dart`.

**3 — Feature picker FAB entry**: The Add FAB's flyout gained a `Feature`
entry (`Icons.layers_outlined`). Tapping it opens
`feature_picker_sheet.dart`'s second-level picker: Extrude
(`Icons.move_to_inbox_outlined`, enabled, wired to the existing extrude
flow), Revolve/Sweep/Fillet/Chamfer (disabled, `Theme.of(context).disabledColor`,
no `onTap`). Same rounded-top sheet shape as Item 2.

**4 — Sketcher undo**: The brief's literal suggestion — push a full
`SketchDto` snapshot before every mutation, pop and restore on undo —
doesn't fit this codebase's architecture. `SketchController` already treats
the backend as the sole source of truth: every mutating method calls a
`SketchApiClient` method and then re-syncs local state from the response
(`_refreshAllPoints()` updates existing points' positions only;
`_refreshConstraints()` does a full clear-and-repopulate from
`listConstraints`). There is no client-held "previous full state" to snapshot
from, and reconstructing one parallel to the backend would risk drifting
out of sync with it.

Implemented instead as a **command/inverse-action stack**: every mutating
call site (`createPoint`/`createLine`/`createCircle`,
`createXConstraint`/`updateConstraintValue`, point drag, entity/constraint
delete) pushes a closure onto `_undoStack` (capped at 50, oldest dropped)
that performs the literal backend-and-local inverse of what it just did —
e.g. creating a Line pushes "delete this Line"; updating a constraint's
value pushes "set it back to the old value". `undo()` pops the most recent
closure, runs it, then re-solves and refreshes exactly like any other
mutation (`_solveAndTrackDof()` → `_refreshAllPoints()` →
`_refreshConstraints()`), so the result is indistinguishable from a normal
edit as far as the rest of the controller is concerned.

Deleting one or more selected entities is the one non-trivial inverse:
`deleteSelected()` now captures full copies of every Point/Line/Circle/
Constraint about to be deleted *before* deleting them, and pushes a single
combined undo that recreates them all via a new `_restoreDeletedEntities`.
Recreating assigns fresh backend ids, so `_restoreDeletedEntities` builds an
old-id → new-id map as it goes (Points, then Lines/Circles, then
Constraints, in that order, since later entities reference earlier ones)
and substitutes mapped ids when recreating each one.
`_recreateConstraint` dispatches across all 10 `ConstraintDto` subtypes to
call the matching `create*Constraint` API method.

UI: `Icons.undo` button added to the sketcher's `AppBar.actions` (leftmost,
nearest the back button), always visible, disabled via `_controller.canUndo`
when the stack is empty. No redo — `// TODO: redo` left in
`sketch_controller.dart` per the brief. The stack is a plain instance field
on `SketchController`, so it's naturally fresh per sketch session/screen
instance — never shared across sketches.

**5 — Select all**: New `SketchController.selectAll()` selects every Point
(excluding the origin point), Line, and Circle into `_selectionSet`, then
opens the ribbon. Only callable in select mode (no-op in draw mode). UI:
`Icons.select_all` button in the same `AppBar.actions`, hidden entirely
(not just disabled) outside select mode via an `AnimatedBuilder` that
returns `SizedBox.shrink()` when `mode != SketchMode.select`.

**6 — Set Length**: New `SketchController.lineLength(lineId)` (Euclidean
distance between a Line's two endpoint Points) and `setLineLength(lineId,
value)`. The backend has no dedicated "line length" constraint type — a
Line's length is represented the same way the existing dimension-ghost flow
already represents it: a plain `DistanceConstraint` between its two
endpoints. `setLineLength` finds an existing one and PATCHes it, or creates
one if none exists yet, with undo wired both ways (no prior callable method
existed for this exact "set length from the ribbon" entry point, so this is
the new method the brief asked for). UI: a `Set Length` chip
(`Icons.straighten`) added as the first/leftmost chip in the ribbon's action
row, shown only when exactly one Line is selected, ahead of Make
Construction/Vertical/Horizontal/Delete. Tapping it opens a small
`AlertDialog` (`_SetLengthDialog` in `sketch_ribbon.dart`) pre-filled with
the current length to 2dp, validates the entered text parses as a positive
number (inline `errorText`, no silent failure), and calls `setLineLength` on
confirm.

**Extra — auto-hide Sketch on Feature use**: `_confirmExtrude` now adds the
consumed Sketch's feature id to `_hiddenFeatureIds` as part of confirming
the extrude, so the profile sketch disappears from the 3D viewport
automatically instead of requiring a manual hide from the Feature tree.
Cancelling the extrude leaves the Sketch visible, unchanged.

## Test/analyze results

Same sandbox limitation as every prior stage: no Flutter/Dart SDK on `PATH`
in this environment, so nothing below was executed — verified by manual
reading and cross-referencing of method signatures/DTOs only.

- `test/mesh_geometry_test.dart`: the four `cullBackFacingSegments` tests
  added in Stage 19a were removed along with the function itself, restoring
  the file to its pre-19a-Item-1 state.
- `test/part_screen_test.dart`: updated for Items 1–3 and the auto-hide
  extra (FAB-driven feature tree toggle, bottom-sheet contextual actions,
  Feature picker flow, hidden-after-extrude assertion) in an earlier
  segment of this stage.
- No new tests were added for Items 4–6 (`sketch_controller_test.dart` has
  no coverage yet for `canUndo`/`undo`/`selectAll`/`lineLength`/
  `setLineLength`, and there is no `sketch_ribbon_test.dart`/
  `sketch_screen_test.dart`), consistent with this project's existing gap
  in controller/widget-level test coverage for the sketcher (no tests
  exercise drag, ghost-dimension confirm, or constraint creation flows
  either, predating this stage). Existing tests were not changed by Items
  4–6's additions, since every change is additive (new fields/methods, new
  optional UI) rather than altering any existing method's external
  behaviour or return type in a way callers/tests would observe.
- `flutter analyze`/`flutter test` were not run (no SDK in this sandbox).

## Known gaps / deferred

- Items 4–6 have no automated test coverage (see above) — worth adding
  `sketch_controller_test.dart` cases for a create→undo round trip, a
  delete→undo round trip (including the id-remap path), and `selectAll`
  excluding the origin point, next time the Flutter toolchain is
  available.
- No redo — explicitly out of scope per the brief (`// TODO: redo` left in
  `sketch_controller.dart`).
- No real on-device verification of any visual change in this stage (FAB
  placement, bottom-sheet appearance/dismissal, dialog validation, the
  restored edge rendering) — every claim above is based on manual code
  reading only, since this sandbox has no Flutter/Dart SDK or GPU. Worth a
  real-device pass next session, particularly confirming the reverted edge
  rendering looks right again and that the undo stack behaves correctly
  through a long mixed sequence of operations (not just the single-step
  cases reasoned through here).
- Revolve/Sweep/Fillet/Chamfer remain disabled placeholders in the Feature
  picker, per the brief.

## Branch / commits

Branch: `claude/new-session-wh9dee`. Commit pending as of this doc's
writing — see the branch's actual commit log for the final message.
