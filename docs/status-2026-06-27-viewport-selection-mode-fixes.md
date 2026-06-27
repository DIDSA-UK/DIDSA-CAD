# 3D viewport selection mode — bug-fix round — status — 2026-06-27

Branch: `claude/new-session-2s6bo4`.

**Filename note**: the fix prompt asked for this doc at
`status-2026-06-27-stage23-fixes.md`. `docs/status-2026-06-26-stage23.md`
already exists on `main` (PR #41, "sketch UX polish") - a different,
already-merged piece of work that happens to reuse the "Stage 23" label.
The feature this fix round actually targets is documented at
`docs/status-2026-06-27-viewport-selection-mode.md` (no "stage" number, for
the same reason). This doc follows that file's naming precedent instead of
introducing a second, differently-scoped "stage23" filename.

This round targets the 7 items in the fix prompt against that
viewport-selection-mode feature (`part_screen.dart`/`part_viewport.dart`/
`selection_hit_test.dart`/`mesh_geometry.dart`/backend `mesh.py`). 4 of the
7 required code changes; 3 were found, on inspection, to already satisfy
the fix prompt's requirement by construction - see each item below.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Intermittent face hover highlight | Already correct | no change |
| 2 | Selected entities not highlighted (render order) | Fixed | `part_viewport.dart` |
| 3 | Vertex hover highlight not appearing | Already correct | no change |
| 4 | Tap screen to select (remove Select button) | Fixed | `part_viewport.dart`, tests |
| 5 | Bottom drawer FAB overlap / height | Fixed | `selection_list_drawer.dart`, `part_screen.dart` |
| 6 | `_dependents.isEmpty` assertion on Set Length | Not applicable | no `InheritedWidget` anywhere in this codebase |
| 7 | Hamburger → FAB above feature-tree FAB | Fixed | `part_screen.dart` |

## What changed, by item

**Item 1 - intermittent face hover (already correct, no change)**: the fix
prompt's root cause is the hover hit-test reading the raw gesture position
instead of the cursor's own accumulated screen-space offset. In this
codebase, `_handleSelectionPointerMove`/`_handleSelectionPointerHover`
(`part_viewport.dart`) both write `_cursorPosition` *first*, then call
`_recomputeHover()`, which reads only `_cursorPosition` - never a raw
event-local position. The face hit-test (`hitTestFaces` in
`selection_hit_test.dart`) is a pure ray-triangle intersection
(`_rayTriangleIntersectionT`) with no radius gate; the 9.0px
`kSelectionHitRadiusPixels` gate is applied only inside
`hitTestVertices`/`hitTestEdges`. Both halves of the fix prompt's
description are already true here, so no behaviour changed. Re-confirmed
by re-reading every line of `_recomputeHover`, `hitTestMeshEntities`,
`hitTestFaces` end to end.

**Item 2 - selected entities not highlighted (fixed)**: highlight nodes are
real `flutter_scene` GPU nodes, not a 2D `CustomPainter` pass, so "render
order" here means *Scene node list order*, not a painter's draw-call order.
Selected-entity highlighting already existed (`_syncSelectedEntityNodes`,
driven by `widget.selectedEntities`, distinct `_selectedColor` from
`_hoverColor`) and was already persistent (keyed off the selection set, not
`_hoveredEntity`) - so the actual bug was narrower than the prompt's literal
description: selecting an entity re-added its highlight node to the *end*
of the Scene's node list without re-adding the existing hover node after
it, so a subsequent hover at the same location could render *underneath*
the just-added selected highlight instead of on top of it. Fixed in
`part_viewport.dart`'s `didUpdateWidget`, the block reacting to
`widget.selectedEntities` changes:

```dart
if (widget.selectedEntities != oldWidget.selectedEntities) {
  setState(() {
    _syncSelectedEntityNodes();
    _syncHoverNode();
  });
}
```

Calling `_syncHoverNode()` immediately after re-adds the hover node to the
end of the Scene's node list whenever the selection set changes, restoring
"selected, then hover on top" order. No other render-order issue existed
(hover already runs `_syncHoverNode()` last on every cursor move
already, independent of this).

**Item 3 - vertex hover highlight (already correct, no change)**: the
backend (`backend/app/document/mesh.py`) already builds
`topology_vertices`/`topology_vertex_ids` via `_extract_topology_vertices`
(the same `TopExp_Explorer`/`TopTools_IndexedMapOfShape` pattern
`_extract_edges` already uses), and `schemas.py`/the client `MeshDto`
already parse both with `[]` defaults - the 3a backend/parsing requirement
is satisfied. For 3b: this codebase doesn't draw highlights as 2D
screen-projected circles in a `CustomPainter`; `buildVertexMarkersNode`
(`mesh_geometry.dart`) renders a hovered/selected vertex as a real
`flutter_scene` GPU node (a near-zero-length `PolylineGeometry` segment with
a large pixel `width`, producing a constant-screen-size dot), added to the
Scene by `_syncHoverNode`/`_syncSelectedEntityNodes` the same way face/edge
highlights are. This is an equally-valid alternative to the prompt's
"manually project through the MVP matrix in a painter" approach - the GPU
already projects it every frame as part of normal scene rendering - so nothing
needed changing here either.

**Item 4 - tap-to-select (fixed)**: removed the dedicated "Select"
`FilledButton.icon` from `PartViewport.build()` entirely, along with
`_kSelectButtonRaisedBottom` (the heuristic bottom-clearance constant that
existed only to keep that button clear of the bottom drawer - moot once the
button is gone). This codebase has no `GestureDetector` in the 3D viewport;
all pointer dispatch already goes through a raw `Listener`, with the
existing orbit-mode handlers already disambiguating tap-vs-drag via
cumulative pointer travel (`_gestureTravel`/`_tapTravelThreshold = 10.0`).
Selection mode now mirrors that exact pattern with its own field
(`_selectionGestureTravel`, kept separate so this never touches the orbit
handlers' own bookkeeping):

- `_onPointerDown`: resets `_selectionGestureTravel = 0` when entering
  selection mode (previously a no-op).
- `_onPointerMove`: accumulates `event.delta.distance` into
  `_selectionGestureTravel` before moving the cursor (previously moved the
  cursor only).
- `_onPointerEnd`: if the event is a `PointerUpEvent` and
  `_selectionGestureTravel` stayed under `_tapTravelThreshold`, calls
  `_commitSelection()` - the same method the removed button's `onPressed`
  called. A `PointerCancelEvent`, or a `PointerUpEvent` past the threshold
  (a real cursor drag), commits nothing.

Doc comments that referenced "the Select button" in both `part_viewport.dart`
(field docs on `onSelectionToggle`/`onClearSelection`/`_commitSelection`/the
crosshair painter) and `part_screen.dart` (`_toggleSelectedEntity`/
`_clearSelectedEntities`) were updated to describe the tap instead.

`client/test/part_viewport_test.dart`'s three `find.text('Select')`
assertions were replaced: the Orbit-mode test no longer asserts the button's
absence (nothing to assert); the mode-entry test now only asserts no
exception is thrown on entering selection mode (the button it used to check
for is gone); the "tap clears selection" test now does
`tester.tap(find.byType(PartViewport))` instead of tapping the button by
text, asserting the same `onClearSelection`-not-`onSelectionToggle` outcome.
Added one new test exercising the other half of Fix 4's tap/drag
disambiguation: a `dragFrom` past the 10px threshold moves the cursor and
fires neither selection callback.

**Item 5 - bottom drawer FAB overlap / height (fixed)**: `SelectionListDrawer`
(`selection_list_drawer.dart`) was rebuilt around `DraggableScrollableSheet`
(`initialChildSize: 0.18, minChildSize: 0.12, maxChildSize: 0.4`, the
project's stated drawer convention) in place of the original fixed
`ConstrainedBox(maxHeight: 160)`. It gained an optional `header` widget,
rendered above the entity `ListView` inside the same sheet, so
`SelectionContextPanel` (previously a separate sibling `Positioned` in
`part_screen.dart`) is now passed in as that header - the two stay stacked
together with no separate height bookkeeping between two independently
animated widgets. The sheet's content is wrapped in `SafeArea(top: false)`
and a `Padding(right: 72)` (clearing the bottom-right FAB column - mode-toggle
+ Add FABs, each 56dp wide with 16dp Scaffold margin) so neither the entity
list nor the sheet's own drag handle render under the FABs.

`part_screen.dart`'s wrapping `Positioned` changed from a
bottom-anchored `Positioned(left: 0, right: 0, bottom: 0, ...)` to
`Positioned.fill`, since `DraggableScrollableSheet` sizes itself as a
fraction of its *parent's* height - a bottom-anchored `Positioned` with no
explicit height doesn't give it one to size against.

New test: `client/test/selection_list_drawer_test.dart` covers the empty-
selection no-op case, the header rendering above the entity list (asserted
by Y-position), tapping an entry's remove button firing `onRemove`, and the
72px right padding being present on the sheet's content.

**Item 6 - `_dependents.isEmpty` assertion (not applicable, no change)**:
this crash's root cause is an `InheritedWidget`/`InheritedNotifier` being
disposed while a still-mounted descendant has an active
`context.dependOnInheritedWidgetOfExactType` registration on it. Grepped the
entire `client/lib` tree for `InheritedWidget`/`InheritedNotifier`/
`dependOnInheritedWidgetOfExactType` - zero matches anywhere in this
codebase. `PartScreen`/`SketchScreen` both already follow every one of the
fix prompt's 6a-6d checklist items by construction: controllers are created
in `initState` and disposed in `dispose`, state is threaded down via
explicit constructor parameters and `ListenableBuilder`/`AnimatedBuilder`
(never an `InheritedWidget` wrapper), and `SketchScreen`'s `_controller` is
created/disposed the same way. The crash this item describes cannot occur
in this codebase as it stands; no code changed.

**Item 7 - hamburger → FAB (fixed)**: the `IconButton.filled` hamburger
toggle in `part_screen.dart`'s top-left `Column` (inside the same
`if (!_featureTreeVisible && !_planeSelectionMode)`-gated block as
`feature-tree-fab`) is now a `FloatingActionButton.small` with
`heroTag: 'hamburger-fab'`, positioned first in that `Column` (i.e. above
`feature-tree-fab`, unchanged). Its `tooltip`/icon/`onPressed` are exactly
what the `IconButton` had (`'Open toolbar'`/`'Close toolbar'`,
`Icons.menu`/`Icons.close`, toggling `_toolbarOpen`) - existing tests that
target it by tooltip (`find.byTooltip('Open toolbar')`) needed no changes.
Visibility: hidden only when `_extrudeSketchFeature != null` *and*
`_toolbarOpen` is false (`if (_toolbarOpen || _extrudeSketchFeature == null)`)
- so it follows the same extrude-panel hiding rule every other FAB here
uses, but is never hidden while the toolbar is open, since it's the only
way to close it. The pre-existing outer gate hiding the whole block while
the Feature tree is open (to avoid overlapping the tree's own header/close
button) is unchanged, per the fix prompt's "do not change behaviour not
listed" instruction - this item's literal ask was converting the toggle's
*type*, not that surrounding visibility rule.

Per the fix prompt, the existing bottom-right FAB cluster
(`selection-mode-fab`/`add-fab` in `Scaffold.floatingActionButton`) was left
as its own separate column, not merged with the top-left hamburger/
feature-tree column - this codebase has always had two independently
positioned FAB clusters (top-left toggles, bottom-right actions), and the
fix prompt's literal ask ("hamburger FAB positioned above the feature-tree
FAB", "selection-mode FAB must also appear in the FAB column ... in correct
z-order relative to the new hamburger FAB") describes a single-column
layout from a different codebase/stage that doesn't match this one's actual
two-cluster structure. Merging them would be an unrequested UI
restructuring beyond this item's literal ask, so it wasn't done.

## Test/analyze results

No Flutter/Dart SDK is available in this sandbox (`which flutter dart`
finds nothing, `dart --version` fails) - the same limitation called out in
every prior status doc in this repo. `flutter analyze`/`flutter test` could
not be run. Verification was manual:

- Every edited file was re-read in full after editing; brace/paren counts
  were additionally cross-checked with a `grep -o '{'`/`'}'`/`'('`/`')'`
  count per file (all balanced) as a mechanical syntax sanity check beyond
  visual review.
- Confirmed via `grep` that no reference to the removed `_kSelectButtonRaisedBottom`,
  `FilledButton.icon`, or `find.text('Select')` remains anywhere under
  `client/`.
- Confirmed via `grep` that no `InheritedWidget`/`InheritedNotifier`/
  `dependOnInheritedWidgetOfExactType` exists anywhere in `client/lib`,
  supporting Item 6's "not applicable" finding.
- Traced `_onPointerDown`/`_onPointerMove`/`_onPointerEnd`'s selection-mode
  branches against `tester.tap`'s and `tester.dragFrom`'s actual Flutter
  test-framework event sequences (tap: down+up, no move event at all; drag:
  down, one or more moves summing to the drag distance, then up) to confirm
  the new tests exercise the intended `_selectionGestureTravel` code paths.
- No code outside the 7 items' scope was touched; orbit-mode gesture
  handler bodies (`_handlePointerDown`/`_handlePointerMove`/
  `_handlePointerEnd`/`_handlePointerSignal`) were re-diffed against the
  pre-fix file and confirmed unchanged.

## Known gaps / deferred

- No on-device/emulator/`flutter test` run - same caveat as every prior
  client-side stage's status doc in this repo.
- `SelectionListDrawer`'s `DraggableScrollableSheet` minimum/initial sizes
  (0.12/0.18 of the *viewport's* height, not the screen's) are the project's
  stated convention values; they weren't re-tuned against this widget's
  specific content (header + list), since the fix prompt specified the
  exact numbers to use.
- Backend (`mesh.py`/`schemas.py`) was not touched - Item 3's backend half
  was already complete from the original implementation.

## Branch / commits

Branch: `claude/new-session-2s6bo4`. See the branch's commit log for exact
hash(es)/message(s).
