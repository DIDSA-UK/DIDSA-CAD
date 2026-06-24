# Stage 16 status — 2026-06-24

Branch: `claude/new-session-qvt039` (tracks `origin/claude/new-session-qvt039`).
Builds on Stage 15 (merged to `main` via PR #30).

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | 3D viewport far/near clip planes scale to model size | Complete | `OrbitCamera` |
| 2 | Remove zoom-in restriction for large models | Complete | `OrbitCamera` |
| 3 | Remove white reference cube, keep reference planes/triad | Complete | `PartScreen` |
| 4 | Sketch origin point: snappable but fixed | Complete | `SketchController` |
| 5 | Fix point-drag jump on double-tap begin | Complete | `SketchController` |
| 6 | Fix edge-pan firing while finger stationary | Complete | `SketchCanvas` |
| 7 | Move constraint buttons to selection ribbon; add Collinear | Complete | client + backend |
| 8 | Feature tree auto-hides during Extrude | Complete | `PartScreen`/`FeatureTreePanel` |
| 9 | Line-to-line distance dimension + leader-line fix | Complete | client + backend |

All 9 items from the Stage 16 prompt are implemented.

## What changed, by item

**1 — Clip planes**: `OrbitCamera.setZoomBoundsForRadius` now also derives
`farClip = max(1000.0, radius * 4.0)` and `nearClip = farClip / 10000.0`,
fed into `PerspectiveCamera`'s `fovNear`/`fovFar` via `cameraFor`. Recomputed
on every call site that already called `setZoomBoundsForRadius` (initial
load, after every extrude confirm), so no new call sites were needed.

**2 — Zoom-in restriction**: `minDistance` is no longer a fixed
radius-derived floor; it's now `nearClip * 2`, so it shrinks along with the
near clip plane for small models instead of stopping the user from zooming
in close on them.

**3 — Reference cube removal**: the backend's `GET .../mesh` endpoint
already returns `source: "placeholder"` for a Part with no `ExtrudeFeature`
yet (a deliberate "uniform response shape" implementation detail, not real
user geometry). `PartScreen._refreshMesh` now discards that response
(`_mesh = null`) instead of rendering it, so an empty Part's viewport shows
only the reference planes/triad, never a stray cube.

**4 — Fixed origin point**: the sketch's origin Point is excluded from
`_existingPointIdNear`'s general "snap onto any nearby Point" lookup's
*selection* path but still resolves for snapping geometry to it; it's
permanently rendered at (0,0), is solved in py-slvs's fixed group (already
true since an earlier stage), and is excluded from delete/selection by id
check.

**5 — Point-drag jump fix**: `beginPointDrag` now only records
`_dragOriginCursorX/Y` and `_dragOriginPointX/Y` — no PATCH is sent at
drag-begin. `updatePointDrag` computes the new position as
`originPoint + (currentCursor - originCursor)` (a delta from the recorded
origin), instead of jumping the point straight to the cursor's current
position, which was the source of the visible jump on the double-tap that
starts a drag.

**6 — Edge-pan stationary-finger fix**: `_SketchCanvasState` adds
`_edgePanMoveThreshold` (1.5px) and `_lastPointerPosition`; pointer-move
events only refresh `_lastCursorMoveTime` (the signal `_onEdgePanTick`'s
existing idle check reads) when the cursor has actually moved more than the
threshold, so resting a finger at the canvas edge no longer keeps panning.

**7 — Constraint buttons moved + Collinear added**: Coincident/Parallel/
Perpendicular/EqualLength buttons moved out of the dimension tool into a
selection-driven ribbon/flyout, gated by `availableConstraintOptions`'s
selection-shape table (`canApplyConstraint` delegates to it, with one test
per table row). Dimension tool now offers only Distance/Angle/Length. New
**Collinear** constraint added end-to-end: backend
`CollinearConstraint`/`Sketch.add_collinear_constraint` (pins both of Line
2's endpoints onto Line 1 via two `point_on_line` calls — py-slvs has no
single "two lines collinear" primitive), schema/router wiring, and client
`CollinearConstraintDto`/`createCollinearConstraint`/ribbon button.

**8 — Feature tree auto-hide during Extrude**: new `_extrudeActive` getter
on `_PartScreenState` (`_extrudeSketchFeature != null`); `FeatureTreePanel`'s
`visible` is now `_featureTreeVisible && !_extrudeActive`. `FeatureTreePanel`
already had a 200ms `AnimatedSlide` keyed off `visible`, so no new animation
code was needed — gating the existing flag was sufficient. Restores
automatically on Confirm/Cancel since both null out `_extrudeSketchFeature`.

**9 — Line-to-line distance dimension + leader line**: two independent
fixes.

- *Backend*: previously a line-to-line distance dimension materialized a
  real Point at each Line's midpoint and pinned a plain point-to-point
  `DistanceConstraint` between them — the documented limitation of
  `_materializeMidpoint` ("not kept coincident if the Line is later
  resized/moved") meant dragging the dimension never actually moved the
  Lines. New `LineDistanceConstraint` (backend: `constraints.py`/
  `solver.py`/`models.py`/`schemas.py`/`router.py`) uses py-slvs's
  `addPointLineDistance` (`SLVS_C_PT_LINE_DISTANCE`) directly against the
  two Lines' own endpoints — no Points are created, and the constraint's
  value is PATCH-editable via the existing `update_constraint_value`
  endpoint (new branch added there too).
- *Client*: `confirmGhostValue`'s `lineDistance` branch no longer calls
  `_materializeMidpoint`; it now looks up an existing `LineDistanceConstraintDto`
  via a new `_findLineDistanceConstraint(lineAId, lineBId)` (mirrors
  `_findAngleConstraint`) and either PATCHes it or calls the new
  `SketchApiClient.createLineDistanceConstraint`. `_paintDimensionOverlays`
  gained a `LineDistanceConstraintDto` case (`_paintLineDistanceDimension`,
  anchored at each Line's current screen-space midpoint) — previously this
  case fell through `default: break` and the dimension wouldn't have
  rendered at all once the backend stopped reusing `DistanceConstraintDto`
  for it. `_constraintLabelCenter` (`dimensionLabelAt`'s hit-test geometry)
  got the matching case.
- *Leader-line bug*: separately, dragging *any* dimension's label
  (Distance/Axis/Angle/LineDistance) moved only the label chip —
  `_paintDistanceDimension` et al. drew the dimension/extension lines at
  their fixed default anchor and never connected them to wherever the label
  had actually been dragged to, so a far-dragged label looked detached from
  its dimension. New shared `_drawLeaderLine(canvas, anchor, labelOffset,
  color)` draws a connecting segment from the default anchor to the
  offset label position whenever `labelOffset != Offset.zero`; wired into
  `_paintDistanceDimension`, `_paintAxisIndicator`, `_paintAngleDimension`,
  and the new `_paintLineDistanceDimension`.

## Known bugs / deferred items

None newly introduced. One pre-existing gap was found and fixed while
touching adjacent code: `sketch_controller_test.dart`'s `_FakeBackend` test
double's constraint-creation switch had no `'collinear'` case (added in
Stage 16 item 7) — it fell through to a `default:` branch that force-casts
a `'distance'` field that Collinear's request body never sends, which would
have thrown at runtime the first time that test actually executed. Added
both the missing `'collinear'` case and the new `'line_distance'` case in
the same fix.

## Test/analyze results

**Sandbox limitation (environment, not code)**: this execution environment
has no Flutter/Dart SDK installed at all (`dart`/`flutter` are not on
`PATH`). `flutter analyze` and `flutter test` could not be run here. Every
client-side change in this session was verified by careful manual reading
of the diff plus reasoning about call sites and existing test patterns, but
**none of it has been executed**. This should be run in CI or a real
Flutter environment before merging:

```
cd client && flutter analyze && flutter test
```

New/changed client tests this session (in `client/test/sketch_controller_test.dart`,
unexecuted — see above):
- Rewrote the lineDistance-ghost-confirm test to assert a `LineDistanceConstraintDto`
  is created with no new backend Points (was: asserted the old midpoint-`DistanceConstraint`
  behavior this session's fix removed).
- Added a PATCH-on-reconfirm test for `LineDistanceConstraint`, mirroring the
  existing Angle one.
- Added a `dimensionLabelAt` test for `LineDistanceConstraintDto`'s label
  anchor and its post-drag offset position (the leader-line hit-test
  geometry).
- Fixed the `_FakeBackend` gap described above (`'collinear'`/`'line_distance'`
  cases).

**Backend (`pytest`)**: this sandbox also has no `pythonocc-core` (`OCC`)
installed (re-confirmed this session; `pip show pythonocc-core` reports not
found). `backend/app/main.py` imports `OCC.Core.BRepPrimAPI` at module
level, so any test module that imports `app.main` (directly, or transitively
via `from app.main import app`) fails to *collect* — this is a pre-existing,
unresolved sandbox limitation, not something introduced this session.

```
$ python3 -m pytest tests/ -q --continue-on-collection-errors
...
1 failed, 10 passed, 1 warning, 11 errors in 0.46s
```

- 10 passed / 1 failed (`test_stage2_profile.py::test_profile_detection_over_the_api`,
  also an `app.main`/OCC import failure inside the test body — pre-existing,
  unrelated to this session).
- 11 collection errors, all `ModuleNotFoundError: No module named 'OCC'` —
  every module that imports `app.main`, including
  `backend/tests/test_stage15_constraints.py`, where this session's new
  `LineDistanceConstraint` tests live
  (`test_add_line_distance_constraint_between_two_existing_lines`,
  `test_line_distance_constraint_moves_lines_apart_without_creating_points`,
  `test_create_line_distance_constraint_over_the_api`). These are
  syntactically valid (`python3 -m py_compile` passes on every touched
  backend file) and were verified semantically via a direct-import script
  bypassing `app.main`/OCC:

  ```
  $ python3 -c "
  from app.sketch.models import Sketch, Plane
  from app.sketch.solver import solve_sketch
  ... (two horizontal Lines 30 units apart, LineDistanceConstraint(50))
  "
  converged True dof 5
  points unchanged: True
  line1 y: 40.0 40.0
  line2 y: -10.0 -10.0
  gap: 50.0
  ```

  i.e. the solve converges, creates no new Points, and the two Lines move
  apart to exactly the constrained 50-unit gap — but this has not run
  through the actual `pytest` test file in this sandbox, and won't until
  `pythonocc-core` is installed (or `app.main`'s OCC import is made lazy/
  optional for test collection — out of scope for this session).

The 10 collectible-and-passing modules are unaffected by this session's
changes (`test_stage2a_solver.py` and others that don't import `app.main`).

## Branch / commits

Branch: `claude/new-session-qvt039`, pushed to `origin/claude/new-session-qvt039`.

- `f26dae0` — Stage 16 item 9 (backend): add LineDistanceConstraint via SLVS_C_PT_LINE_DISTANCE
- `e196481` — Stage 16 items 1/2/3/8: viewport clip planes, zoom limit, reference cube, Extrude tree auto-hide
- `70d3501` — Stage 16 items 4/5/6/7/9 (client): sketch interaction fixes, Collinear, line distance, leader lines
