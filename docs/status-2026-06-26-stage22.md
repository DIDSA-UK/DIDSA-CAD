# Stage 22 status — 2026-06-26

Branch: `claude/prompt-item-1-camera-gvbptx`.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Backend: native `at_midpoint` constraint (`SLVS_C_AT_MIDPOINT`) | Complete | `constraints.py`, `solver.py`, `models.py`, `schemas.py`, `router.py` |
| 2 | Client: `atMidpoint` constraint type, wired to midpoint snap | Complete | `sketch_api_client.dart`, `sketch_controller.dart` |
| 2c | Constraint display: no badge for `at_midpoint` | Complete (no code change needed) | `sketch_canvas.dart` |
| 3 | FAB z-order fix while toolbar is open | Complete | `part_screen.dart` |

## What changed, by item

**1 — Backend `at_midpoint` constraint**: Per the user's explicit
instruction, the installed py-slvs version/binding was verified before
writing any solver code — `backend/environment.yml` pins `py-slvs==1.0.6`;
the actual wheel was downloaded and inspected (`py_slvs/slvs.py`), which
confirmed:

```python
SLVS_C_AT_MIDPOINT = _slvs.SLVS_C_AT_MIDPOINT
...
def addMidPoint(self, pt, line, wrkpln=0, group=0, h=0):
    return _slvs.System_addMidPoint(self, pt, line, wrkpln, group, h)
```

This is a higher-level per-primitive wrapper with the exact same calling
convention this codebase already uses for `addPointOnLine`/
`addPointLineDistance` (see `_PySlvsBuilder.point_on_line`/
`point_line_distance` in `solver.py`). The brief's own Item 1a pseudocode
(`sys.add_constraint(SLVS_C_AT_MIDPOINT, workplane, 0.0, ...)`) is a
generic/low-level form that doesn't match this codebase's architecture —
no existing constraint type calls `add_constraint`/`addConstraintV`
directly, they all use the per-primitive wrapper methods. Used
`system.addMidPoint(pt, line, wrkpln=self._workplane, group=_SOLVE_GROUP)`
instead, matching the existing pattern.

Wired through the same five-layer pattern every other constraint type
follows, mirroring `PointLineDistanceConstraint` minus the numeric value:

- `backend/app/sketch/constraints.py` — added `at_midpoint` to the
  `SolverBuilder` Protocol, and a new `AtMidpointConstraint` dataclass
  (`point_id`, `line_id`, plus captured `line_start_id`/`line_end_id`;
  `type` returns `"at_midpoint"`; no `distance` field — pure geometric
  constraint, like `Coincident`/`Parallel`/`Perpendicular`/`EqualLength`/
  `Collinear`).
- `backend/app/sketch/solver.py` — `_PySlvsBuilder.at_midpoint` calling
  `self._system.addMidPoint(...)`.
- `backend/app/sketch/models.py` — `Sketch.add_at_midpoint_constraint(point_id, line_id)`,
  same point/line validation (`KeyError`) as `add_point_line_distance_constraint`.
- `backend/app/sketch/schemas.py` — `AtMidpointConstraintCreate`/
  `AtMidpointConstraintResponse`, appended to both `ConstraintCreate` and
  `ConstraintResponse` Unions.
- `backend/app/sketch/router.py` — dispatch branches in `create_constraint`
  and `_constraint_response`. No branch added to `update_constraint_value`
  — `at_midpoint` has no numeric value, so it falls through to the
  existing 422 (`"{type} constraints have no numeric value to update"`),
  consistent with Vertical/Horizontal/Coincident/Parallel/etc. `delete_constraint`
  is already fully generic (works off `sketch.constraints[id]` directly), so
  no change was needed there either.

Added pure-domain, solver-integration, and API-level tests to
`backend/tests/test_stage15_constraints.py` (the file every prior stage's
constraint tests have accumulated in, including Stage 21's
`PointLineDistanceConstraint` trio — kept the convention rather than
starting a new per-stage file):
- `test_add_at_midpoint_constraint_between_a_point_and_a_line`
- `test_add_at_midpoint_constraint_with_unknown_point_raises`
- `test_at_midpoint_constraint_pins_point_to_midpoint_after_solve` — point
  starts off-line; after solving with the line's length and orientation
  pinned, asserts it lands exactly at `(a+b)/2`.
- `test_at_midpoint_constraint_tracks_midpoint_as_line_length_changes` —
  regresses against the actual Stage 21 bug this replaces: solves once at
  length 10, then mutates the `DistanceConstraint`'s `distance` to 40 and
  re-solves, asserting the point still lands at the new midpoint (a fixed
  half-length `DistanceConstraint`, as Stage 21 used, would *not* track this).
- `test_create_at_midpoint_constraint_over_the_api`
- `test_patch_at_midpoint_constraint_value_is_422`
- `test_delete_at_midpoint_constraint_over_the_api`

**2 — Client `atMidpoint` wiring**: Added to
`client/lib/api/sketch_api_client.dart`:
- `AtMidpointConstraintDto` (`pointId`, `lineId`, no value), wired into
  `ConstraintDto.fromJson`'s switch under `case 'at_midpoint'`.
- `SketchApiClient.createAtMidpointConstraint(sketchId, pointId, lineId)`,
  POSTing `{ "type": "at_midpoint", "point_id": ..., "line_id": ... }`.

In `client/lib/sketch/sketch_controller.dart`:
- `_recreateConstraint` gained an `AtMidpointConstraintDto` branch (needed
  so undo-of-delete correctly recreates the constraint), inserted right
  after the `PointLineDistanceConstraintDto` branch.
- `_materializeMidpoint` rewritten: removed the Stage 21
  `createPointLineDistanceConstraint(..., 0.0)` + `createDistanceConstraint(...,
  halfLength)` pair (and the now-unused `halfLength` calculation) and
  replaced with a single call:

  ```dart
  // Midpoint: SLVS_C_AT_MIDPOINT — solver maintains point at geometric
  // midpoint of line as endpoints move
  final midpointConstraint = await _api.createAtMidpointConstraint(_sketchId!, created.id, lineId);
  _pushUndo(() async => _api.deleteConstraint(_sketchId!, midpointConstraint.id));
  ```

  This is a strict improvement over Stage 21's workaround: the old
  half-length `DistanceConstraint` baked in a fixed value at creation time,
  so the materialized point would stop tracking the true midpoint once the
  line's length changed independently afterward (see the new
  `test_at_midpoint_constraint_tracks_midpoint_as_line_length_changes`
  regression test above). The native `SLVS_C_AT_MIDPOINT` primitive has no
  such fixed value, so it keeps tracking correctly. The method's doc
  comment was also updated to describe the new behavior instead of the old
  "one-off snapshot... backend has no midpoint constraint type" wording.
  `math` import in `sketch_controller.dart` remains used elsewhere in the
  file (confirmed via grep), so no unused-import issue.

**2c — No badge for `at_midpoint`**: Required zero code changes. Both
constraint-badge switch statements in `client/lib/sketch/sketch_canvas.dart`
(`_constraintLabelCenter` and the dimension-overlay paint loop) are typed
`switch` statements that only handle `{Distance, Vertical, Horizontal,
Angle, LineDistance}` and default to "no badge" for every other DTO type —
exactly how `Coincident`/`Parallel`/`Perpendicular`/`EqualLength`/
`Collinear`/`PointLineDistance` already render today. `AtMidpointConstraintDto`
falls into that same default with no new case needed.

**3 — FAB z-order fix**: The brief's "hamburger drawer" doesn't map to a
literal Flutter `Scaffold.drawer` in this codebase — `PartScreen` has none.
It refers to `PartToolbar`, a body-`Stack`-internal overlay toggled by the
existing `_toolbarOpen` boolean (not `onDrawerChanged`, which only applies
to a real `Scaffold.drawer`). Two independent overlap bugs were found and
fixed in `client/lib/viewport3d/part_screen.dart`:

1. The small "Feature tree" `FloatingActionButton.small` (`heroTag:
   'feature-tree-fab'`) sits in the body `Stack` *after* `PartToolbar`, so
   it already painted on top of the open toolbar panel. Fixed by wrapping
   it in `if (!_toolbarOpen) FloatingActionButton.small(...)` — it
   disappears while the toolbar is open and reappears when closed. The
   hamburger toggle `IconButton.filled` directly above it in the same
   `Column` is *not* hidden, since it remains the only way to close the
   toolbar.
2. The main "Add" FAB is `Scaffold.floatingActionButton`, not part of the
   body `Stack` at all — Flutter's `Scaffold` always paints
   `floatingActionButton` after (on top of) the entire `body`, regardless
   of the body's own internal `Stack` child order, so it would always sit
   on top of `PartToolbar` whenever both were visible no matter how the
   body `Stack` was reordered. Fixed by extending the existing Extrude-panel
   visibility condition: `floatingActionButton: (_extrudeSketchFeature !=
   null || _toolbarOpen) ? null : FloatingActionButton(...)`.

Both FABs disappear while the toolbar is open and reappear when it closes
— consistent with the brief's stated rationale ("they are not usable while
the drawer is open anyway").

## Test/analyze results

Same sandbox limitations as every prior stage:
- No Flutter/Dart SDK on `PATH` — `flutter analyze`/`flutter test` could
  not be run. All three Dart-touched files
  (`sketch_api_client.dart`/`sketch_controller.dart`/`part_screen.dart`)
  were instead verified by full `git diff` review for brace/paren balance,
  correct Stack/Column structural nesting, and confirming no
  newly-unused imports or locals (`math` in `sketch_controller.dart`
  confirmed still used elsewhere via grep).
- No Python backend environment (`fastapi`/`py_slvs` not importable,
  no `pytest` on `PATH`) — every touched backend file
  (`constraints.py`/`solver.py`/`models.py`/`schemas.py`/`router.py`/
  `tests/test_stage15_constraints.py`) was checked for syntactic validity
  via `ast.parse`, not actually executed. The py-slvs `addMidPoint`
  binding itself was verified directly against the real installed wheel
  (1.0.6, downloaded and inspected in the scratchpad), not just read from
  the brief's pseudocode or guessed — this was the one item the user
  explicitly flagged as version-sensitive.
- As with every prior stage, real verification will come from the GitHub
  Actions CI run on push (job logs via `mcp__github__get_job_logs`) — this
  remains the only feedback loop for solver-level correctness in this
  sandbox.

## Known gaps / deferred

- No on-device/emulator verification that the FAB z-order fix actually
  looks correct in the running app, or that midpoint placement actually
  holds correctly under a live drag — every claim above is based on
  manual code reading only, same caveat as every prior stage's status doc.
- No new Flutter-side test coverage was added for either the
  `_materializeMidpoint` rewrite or the FAB visibility change —
  `sketch_controller_test.dart` still has no coverage of the midpoint path
  (a pre-existing gap flagged in Stage 21's status doc, still open), and
  there's no existing Flutter widget-test harness for `PartScreen` to
  extend for the FAB visibility behavior.
- If CI surfaces a solver-convergence issue specific to
  `SLVS_C_AT_MIDPOINT` (e.g. degenerate behavior at certain line
  orientations), the first thing to check is whether `addMidPoint`'s
  internal equation set behaves differently from
  `addPointLineDistance`/`addPointOnLine` for already-degenerate inputs
  (e.g. a zero-length line) — untested edge case, not covered by the new
  tests above.

## Branch / commits

Branch: `claude/prompt-item-1-camera-gvbptx`. Stage 22 implementation
committed as a single commit — see the branch's commit log for the exact
hash/message.
