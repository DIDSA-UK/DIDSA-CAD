# Stage 20 status — 2026-06-26

Branch: `claude/prompt-item-1-camera-gvbptx`.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Camera distance | Skipped per explicit user instruction | Already applied manually in a prior commit; `orbit_camera.dart` untouched this stage |
| 2 | Fix delete-selected dependency order | Complete | `sketch_controller.dart` |
| 3 | Diagnose/fix framework assertion crash | Inconclusive — defensive guard added, no reproducible root cause found | `sketch_ribbon.dart` (see write-up below) |
| 4 | AppBar logo + name layout | Complete | `part_screen.dart`, `sketch_screen.dart` |
| 5 | Point tool icon | Complete | `sketch_speed_dial.dart` |
| 6 | Midpoint constraint | Complete | `sketch_controller.dart` |
| 7 | Stale-solve-after-drag visual bug | Complete | `sketch_controller.dart` |

## What changed, by item

**2 — Delete dependency order**: `deleteSelected()` previously deleted
whatever was in the selection set in selection order, which could send a
delete-Point request before a Line/Circle (or a delete-Line request before
a Constraint) that still referenced it — the backend correctly rejects
this with a 400. Fixed by bucketing the selection into three groups
(constraints, lines/circles, points) and deleting in that order
regardless of original selection order — the reverse of creation order,
and the mirror image of `_restoreDeletedEntities`'s own (forward) Points →
Lines/Circles → Constraints recreation order, which was already correct
and is left unchanged.

**3 — Crash investigation**: The reported crash is a Flutter framework
assertion (`'_dependents.isEmpty': is not true` at `framework.dart:6279`),
which fires inside `InheritedElement.unmount()` when an `Element` that
still depends on an `InheritedWidget` ancestor (`Theme.of`, `MediaQuery.of`,
etc. — nothing custom exists in this codebase) is still registered as a
dependent at the moment that ancestor unmounts. This class of bug is
usually caused by an Element being removed from the tree without being
properly deactivated first (stale `GlobalKey` reparenting,
`AutomaticKeepAlive`/`PageView`/`TabBarView` keeping a subtree alive past
its InheritedWidget ancestor's lifetime, or a `BuildContext` captured
across an `await` and used after its owning widget was torn down).

Audited this stage, with no bug found:
- Every `GlobalKey` in the codebase (`_viewportKey` in `part_screen.dart`
  — the only one that exists) — used in exactly one place, no reparenting.
- Every `showModalBottomSheet`/`showDialog` call site and its post-`await`
  continuation: `part_screen.dart` (`_addSketchFeature`, `_onPlaneTap`,
  `_showPlaneContextSheet`, `_onAddPressed`, `_onFeaturePressed`,
  `_extrudeSelectedFeature`, `_onFeatureLongPress`,
  `_checkExtrudeEligibility`, the cascade-delete confirm flow),
  `plane_context_sheet.dart`, `feature_picker_sheet.dart`,
  `feature_context_menu.dart`, `add_button_menu.dart`,
  `view_prefs_sheets.dart`, `extrude_panel.dart`, `part_toolbar.dart`'s
  colour/opacity pickers, `cascade_delete_dialog.dart`,
  `sketch_construction_method_bar.dart`, `sketch_dimension_bar.dart`,
  `sketch_ribbon.dart`'s `_showSetLengthDialog` — every one already
  guards with `mounted`/`context.mounted` before touching context-derived
  state after an `await`, except one (see fix below).
- No `ListView`/`PageView`/`TabBarView`/`IndexedStack`/`AutomaticKeepAlive`/
  `Hero` usage anywhere except a single plain `ListView.builder` in
  `feature_tree_panel.dart` with no per-item keys and no keep-alive
  mixins — not a plausible source of stale dependents.
- `_SketchPainter.shouldRepaint()` always returns `true` and every
  `CustomPaint`/`AnimatedBuilder` pairing in `sketch_canvas.dart`,
  `sketch_screen.dart`, and `sketch_ribbon.dart` is correctly scoped — no
  stale-painter or stale-listener theory holds up either.

The one genuine gap found: `sketch_ribbon.dart`'s `_showSetLengthDialog`
is a freestanding function (not a `State` method, so no `mounted`
getter) that awaits `showDialog` and then unconditionally proceeds to
call `controller.setLineLength`. It happens not to touch `context`
itself after the await today, so it isn't a live bug, but it's the kind
of pattern that turns into one the next time someone edits it. Added a
`context.mounted` guard immediately after the dialog await, before any
further code runs, closing off that path defensively as the brief allows
when no concrete reproducible cause can be pinned down.

No other concrete root cause was identified despite this exhaustive,
read-only pass across every Stage 19b-introduced UI surface. If this
crash recurs, the next productive step would be to capture the actual
device stack trace beyond the single assertion line, since the
assertion's location alone doesn't indicate *which* InheritedWidget or
*which* dependent Element is involved — that would narrow the search
dramatically versus auditing call sites by inspection.

**4 — AppBar logo + name**: `PartScreen` and `SketchScreen`'s AppBar
`title` changed from a plain `Text` to a `Row`
(`MainAxisAlignment.spaceBetween`) with the DIDSA logo
(`Image.asset('assets/images/didsa_logo.png', height: 28)`) on the left
and the existing name `Text` on the right, matching the `errorBuilder`
fallback pattern already used in `connection_screen.dart` (falls back to
bold `'DIDSA'` text if the asset fails to load). Verified the asset file
exists and `assets/images/` is already registered in `pubspec.yaml`, so
the fallback path won't normally trigger.

**5 — Point tool icon**: `sketch_speed_dial.dart`'s Point tool action
changed from `Icons.fiber_manual_record` to `Icons.control_point` (this
was the only occurrence of the old icon in the codebase).

**6 — Midpoint constraint**: The backend's `ConstraintDto` discriminated
union (`vertical`/`horizontal`/`angle`/`coincident`/`parallel`/
`perpendicular`/`equal_length`/`collinear`/`line_distance`/`distance`) has
no native midpoint type, so this is implemented client-side in
`_materializeMidpoint` — the single shared funnel every midpoint-snap
point placement already goes through (point tool, select-mode taps,
dimension-mode taps alike) — as two `DistanceConstraint`s from the new
midpoint Point to each of the Line's endpoints, each at half the Line's
current length:

```dart
// NOTE: mid-point implemented as two equal half-length distance constraints (backend has no SLVS_C_AT_MIDPOINT)
final halfLength = line.length / 2;
final toStart = await _api.createDistanceConstraint(_sketchId!, created.id, line.startPointId, halfLength);
_pushUndo(() async => _api.deleteConstraint(_sketchId!, toStart.id));
final toEnd = await _api.createDistanceConstraint(_sketchId!, created.id, line.endPointId, halfLength);
_pushUndo(() async => _api.deleteConstraint(_sketchId!, toEnd.id));
```

Each constraint creation pushes its own delete-undo, consistent with
every other constraint-creation call site in the controller — undoing a
midpoint placement removes both constraints (and, via the existing
delete-Point undo pushed earlier in the same method, the Point itself),
in the correct reverse order. `_recreateConstraint`'s existing dispatch
already handles plain `DistanceConstraintDto` generically, so redo/undo
recreation needs no special-casing for these two.

Also fixed a related gap found while wiring this up: `_clickPointTool()`
never called solve/refresh after placing a point, unlike every sibling
draw-tool method (line/circle). This was harmless for a plain point (no
constraints to solve), but a midpoint-snapped point now creates two new
constraints that would otherwise sit uncommitted-looking in
`constraints`/`dof` state until some unrelated later mutation forced a
refresh. Added the same `_solveAndTrackDof()` → `_refreshAllPoints()` →
`_refreshConstraints()` sequence every other tool already runs.

**7 — Stale solve after drag**: Root cause identified: `updatePointDrag`
fires an unawaited PATCH per pointer-move event during a drag. If a
move-event PATCH straggles in flight past pointer-up, it can resolve
*after* `endPointDrag`'s synchronous clear of `_draggingPointId` and
its subsequent solve+refresh — at which point applying the straggler's
response clobbers the just-solved, constraint-satisfying position with
the stale unconstrained drag position. This is exactly what made a
constraint (e.g. Vertical) appear visually violated until some unrelated
later mutation forced a fresh refresh. Fixed with a staleness guard in
`updatePointDrag`, made possible by the fact `endPointDrag` already
clears `_draggingPointId` synchronously before doing anything async:

```dart
if (_draggingPointId != pointId) return;
```

## Test/analyze results

Same sandbox limitation as every prior stage: no Flutter/Dart SDK on
`PATH` in this environment (`which flutter` / `which dart` both resolve
to nothing), so `flutter analyze` and `flutter test` could not be run.
All verification this stage was manual code reading and
cross-referencing of method signatures/call sites only — consistent with
every prior stage's documented limitation.

No existing tests were altered: Items 2 and 7 change internal control
flow only (no signature/behavioural change observable from existing
tests); Items 4/5 are pure UI/asset changes with no existing test
coverage of AppBar title widgets or tool icons; Item 6 adds new
constraint-creation calls inside an existing private method with no
direct test coverage today (consistent with Stage 19b's documented gap —
`sketch_controller_test.dart` has no coverage of the midpoint-snap path
or of constraint creation generally).

## Known gaps / deferred

- Item 3's crash has no confirmed reproduction or concrete root cause —
  see the write-up above. The added `context.mounted` guard closes one
  real (if currently dormant) gap, but should not be read as "the fix"
  with confidence; a real device-captured stack trace (full assertion
  context, not just the single failing line) is the highest-leverage
  next step if this recurs.
- No new automated test coverage was added for Items 2, 6, or 7
  (delete-order bucketing, midpoint constraint creation, or the
  drag-staleness guard) — worth adding to `sketch_controller_test.dart`
  next time the Flutter toolchain is available: a mixed-selection delete
  that previously would have 400'd, a midpoint-snap placement asserting
  both new `DistanceConstraint`s exist with the right half-length value,
  and a drag scenario asserting a stale `updatePointDrag` response is
  dropped once `_draggingPointId` has moved on.
- No real on-device verification of any visual change this stage (AppBar
  logo layout, Point tool icon, midpoint constraint visually holding
  under drag, the drag-staleness fix's actual on-screen effect) — every
  claim above is based on manual code reading only, per this sandbox's
  lack of a Flutter/Dart SDK or GPU.

## Branch / commits

Branch: `claude/prompt-item-1-camera-gvbptx`. Commit pending as of this
doc's writing — see the branch's actual commit log for the final
message.
