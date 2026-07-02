# Prompt B — Sketcher fixes — status — 2026-06-30

Branch: `claude/new-session-g0yfjn` (cut from `main`, which already had Prompts
A/C/D merged — the attached background doc's "Current branch" /
"Upcoming" sections were stale relative to `main`'s actual HEAD).

## Items implemented

| # | Item | Status | Files changed |
|---|------|--------|----------------|
| B0 | Cursor boundary clamping in the sketcher | Done | `sketch_controller.dart`, `sketch_canvas.dart`, `sketch_controller_test.dart` |
| B1 | H/V constraints on center/corner rectangles (not perpendicular) | Done | `sketch_controller.dart`, `sketch_controller_test.dart` |
| B2 | Construction geometry + center point on center/corner rectangles | Done | `sketch_controller.dart`, `sketch_controller_test.dart`, `test_stage12_constraints.py`, `test_stage15_constraints.py` |
| B3 | H/V dimension preserves its nature after solve | Done | `constraints.py`, `solver.py`, `models.py`, `schemas.py`, `router.py`, `sketch_api_client.dart`, `sketch_controller.dart`, `test_stage15_constraints.py`, `sketch_controller_test.dart` |
| B4 | Coincident constraint auto-created when point placed on existing point | Done | `sketch_controller.dart`, `sketch_canvas.dart`, `sketch_controller_test.dart` |
| B5 | Fully-constrained indicator | Done | `sketch_canvas.dart`, `test_stage15_constraints.py`, `sketch_canvas_indicator_test.dart` (new) |

---

## B0 — Cursor boundary clamping

`clampCursorToCanvas(Offset candidate, Size canvasSize)` added as a top-level
pure function in `sketch_controller.dart`, exactly matching the prompt's
spec (snap-to-centre, boundary counts as in-bounds).

The cursor (`cursorX`/`cursorY`) is sketch-space, not screen pixels, so the
helper alone isn't enough — `SketchController.clampCursorToBounds(Size,
ViewTransform)` converts the cursor to screen space via
`transform.sketchToScreen`, runs it through `clampCursorToCanvas`, and
converts back only if it actually escaped. Wired in:

- `moveCursorRelative`/`moveCursorAbsoluteScreen` gained optional
  `canvasSize`/`transform` params (defaulting to off, so existing
  call-sites/tests that don't pass them are unaffected) — clamp after
  applying the delta/absolute position.
- `sketch_canvas.dart`'s touch-relative drag, mouse-hover/down/move, and
  the right-click-drag pan branch (which moves the viewport but never
  itself updates the cursor's sketch-space position — exactly the "pan
  while cursor sits near an edge" drift case the prompt describes) all
  pass `size`/`transform` through and clamp.
- Pinch-pan (`_applyPinchPan`) and scroll-wheel zoom (`_handlePointerSignal`)
  also clamp afterward, since both can shift/rescale the view out from
  under a stationary cursor.
- `_onEdgePanTick`'s own re-pinning was left alone (it already keeps the
  cursor pinned to the exact same screen pixel by construction, so it can
  never escape) and `handleCanvasTap` was left alone (a tap's coordinates
  always originate inside the canvas widget's own hit-test area, so it
  cannot already be out of bounds).

**Tests**: `clampCursorToCanvas` unit tests for in-bounds/all four
escape directions/exact-boundary, plus `moveCursorRelative` tests for the
clamp-when-provided and no-clamp-when-omitted (back-compat) cases.

---

## B1 — H/V constraints on center/corner rectangles

`_buildRectangle` (shared by all three rectangle construction methods)
gained an `axisAligned` parameter (default `true`). For the two-corner and
centre-corner methods (both of which always produce corners in the same
winding order — corner0/corner1 share a Y, corner1/corner2 share an X, and
so on), this applies `Horizontal` to line1/line3 and `Vertical` to
line2/line4 directly, replacing the old 3 `Perpendicular` constraints. The
3-point method (the only one that supports a non-axis-aligned result)
passes `axisAligned: false` and keeps the original 3-Perpendicular
behaviour unchanged, per the prompt.

**Tests**: existing two-corner/centre-corner/corner-snap rectangle tests
updated to assert 2 Horizontal + 2 Vertical + 0 Perpendicular; the 3-point
tests are untouched and still assert 3 Perpendicular.

---

## B2 — Construction geometry + center point

Backend support for this already existed end-to-end before this prompt
(`Line.construction`, profile detection's construction filter, the
`AtMidpoint` constraint/solver primitive) — Stage 12's construction-flag
work and Stage 22's `AtMidpoint` migration cover it. B2 is purely client
wiring: inside `_buildRectangle`'s `axisAligned` branch, after the 4 sides
and their H/V constraints:

1. Two construction `Line`s (`construction: true`) — diagonals corner0↔corner2
   and corner1↔corner3.
2. One new, non-construction `Point` at the average of the four corners
   (the initial guess — the spec's "average of the four corner coordinates").
3. Two `AtMidpoint` constraints pinning that Point to each diagonal's
   midpoint, so it tracks correctly as the rectangle is resized/dragged.

**Tests added**:
- Backend (`test_stage12_constraints.py`): a closed loop of 4 regular Lines
  plus 2 construction diagonals crossing through it still resolves to
  `CLOSED_LOOP` naming only the 4 regular Lines (the existing
  Stage-12 tests already covered the "construction-only" and
  "construction-closes-the-loop" cases, but not "construction coexists
  with a separate valid loop", which is exactly the rectangle's shape).
- Backend (`test_stage15_constraints.py`): a Point pinned to the midpoint
  of two different Lines (the two diagonals) via two `AtMidpoint`
  constraints converges with both midpoint relationships holding
  simultaneously (asserted as a relative invariant against the diagonals'
  own solved endpoints, not fixed coordinates, matching this file's
  existing convention for tests whose corner Points are themselves free).
- Client: two-corner/centre-corner rectangle tests assert 6 lines (4 sides
  + 2 construction diagonals), 6 points (+1 center), 2 `AtMidpoint`
  constraints; a new test asserts the new center Point's *initial* x/y
  equal the average of the 4 corner coordinates exactly (the fake test
  backend doesn't actually solve, so this is the pre-solve value, which is
  exactly what the spec calls "the initial guess").

---

## B3 — H/V dimension preserves its nature after solve

**The prompt's assumed py-slvs methods don't exist.** `addPointsHorizDistance`/
`addPointsVertDistance` are not in the installed `py-slvs==1.0.6` wheel
(verified by downloading and inspecting the actual wheel's `slvs.py` and
its `SLVS_C_*` constant list in this sandbox, since the backend's conda
environment isn't materialized in this environment) — the only relevant
primitive is `addPointsProjectDistance(d, p1, p2, line, group)`
(`SLVS_C_PROJ_PT_DISTANCE`), which measures the projected distance between
two points along an arbitrary reference line's direction.

**Implementation**: `_PySlvsBuilder` lazily creates one fixed (never
solved) horizontal reference line ((0,0)–(1,0)) and one fixed vertical
reference line ((0,0)–(0,1)) in workplane coordinates, cached per-solve so
at most one of each exists regardless of how many H/V `DistanceConstraint`s
reference them. `horizontal_distance`/`vertical_distance` call
`addPointsProjectDistance` against the matching reference line. This was
verified directly against the real wheel (not just reasoned about) — a
standalone script confirmed `addPointsProjectDistance` against a fixed
horizontal/vertical reference line pins exactly the X or Y separation
while leaving the other axis free, matching the spec's required behaviour.

`DistanceConstraint` gained `orientation: Literal["linear", "horizontal",
"vertical"] = "linear"`, threaded through `constraints.py` →
`SolverBuilder` protocol → `solver.py` → `models.add_distance_constraint`
→ `schemas.py` (`DistanceConstraintCreate`/`Response`, both optional with
a `"linear"` default so old requests/responses are unaffected) →
`router.py` (`create_constraint` passes it through;
`update_constraint_value` already only ever mutates `.distance`, so it
preserves `.orientation` automatically — no change needed there beyond
the schema/model support).

Client: `DistanceConstraintDto`/`createDistanceConstraint` gained
`orientation` (default `"linear"`). `confirmGhostValue` now derives
`orientation` from the ghost's `GhostKind` (`horizontal`/`vertical`/else
`"linear"`) and passes it through on creation. Also fixed
`_recreateConstraint` (the undo-restore path for deleted entities) to
preserve `orientation` when replaying a `DistanceConstraint` — it would
otherwise have silently dropped back to `"linear"` on undo/redo of a
deletion.

**Tests added**: backend domain + solver-integration tests for both
orientations (pin one axis, leave the other free — pinning the pinned
point via `Coincident` to the fixed origin Point, not a zero-distance
constraint, since `addPointsDistance` at distance 0 is a singular
configuration for py-slvs's gradient), an API-level creation test, and an
`update_constraint_value` test confirming orientation survives a PATCH.
Client tests confirm `confirmGhostValue('v'/'h'/'linear', ...)` sends the
matching orientation.

---

## B4 — Coincident constraint auto-created when point placed on existing point

**This changes existing, tested behaviour by design — see rationale
below.** Every point-placement path in this codebase (Line/Circle/
Rectangle endpoints, the Point tool) already runs through a shared
`_pointIdAt` helper that **reuses** an existing Point's id outright when
the target lands within `snapRadius` of it — meaning the literal scenario
the prompt describes ("placing a new point... creates two independent,
spatially coincident points with no geometric link") cannot occur via that
shared path: there is structurally never a moment where a *new*,
*distinct* Point exists at that location to link. Hooking the
auto-Coincident check in after `_pointIdAt`'s own `_api.createPoint` call
(as the prompt's wording most literally suggests) would therefore be dead
code — it only runs once `_pointIdAt` has already established no existing
Point is nearby.

Given the prompt explicitly describes `createCoincidentConstraint(newPointId,
existingPointId)` as two *different* ids, B4 is implemented specifically
for the standalone **Point tool** (`_clickPointTool`/`SketchTool.point`):
unlike a Line/Circle/Rectangle endpoint (where reuse is the right call — an
endpoint genuinely *is* the same geometry as whatever it shares), the Point
tool's whole purpose is placing an independently-addressable reference
Point, so silently collapsing it into whatever it lands on defeats that.
`_clickPointTool` now:

1. Still snaps onto a nearby Line's midpoint via the existing
   `_materializeMidpoint` (unchanged — Stage 21/22 behaviour).
2. Otherwise always creates a genuinely new Point (bypassing `_pointIdAt`'s
   existing-Point reuse for this one tool only — every other entity's
   endpoint-sharing behaviour is untouched).
3. Checks `_existingPointIdNear` (same `snapRadius` constant every other
   snap in the sketcher uses — no new magic number) excluding the new
   Point itself; nearest wins if more than one is in range.
4. If found, calls `createCoincidentConstraint(newId, existingId)`, pushed
   onto the undo stack as its own step (consistent with how every other
   multi-call mutation in this codebase pushes one undo entry per API
   call, e.g. the rectangle tools) — so undo first removes just the
   constraint, a second undo removes the Point too.
5. Records the new Point's id in `autoCoincidentIndicatorPointId`, cleared
   by the next `handleCanvasTap` (any tap, any mode) — the canvas paints a
   brief highlight at that location, reusing the exact same cyan
   ring/fill styling `_paintSnapCandidateHighlight` already uses for the
   pre-commit snap-candidate hover (per the prompt's "reuse it" guidance),
   via a new `_paintAutoCoincidentIndicator`.

**Tests**: the old "the point tool snaps onto an existing Point instead of
creating a duplicate" test (which asserted the now-superseded reuse
behaviour) was replaced with one asserting the new distinct-Point +
auto-Coincident behaviour; added tests for the no-match case (no spurious
constraint), the two-step undo, and the indicator clearing on the next
tap.

---

## B5 — Fully-constrained indicator

Backend already returns `dof: int` in `SolveResultResponse` (`solver.py`'s
`system.Dof`, present since this field's introduction) — no backend change
needed for this item; only test coverage was missing.

**Backend tests added**: a fully-constrained 2-Point/1-Line sketch (one
Point pinned to the origin via `Coincident`, the other pinned by a
`Vertical` constraint on the Line plus a plain `DistanceConstraint` — 2
independent equations for its 2 unknowns) asserts `dof == 0`, both as a
direct `solve_sketch()` call and over the `/solve` API; a separately
under-constrained sketch (one free `DistanceConstraint` between two
otherwise-free Points) asserts `dof > 0`.

**Client**: `sketch_canvas.dart`'s line-paint fallback color (previously
always `Colors.blueGrey.shade700` once selection/hover/construction don't
apply) now renders `Colors.black` instead when
`!controller.isUnderConstrained` (the existing `_dof > 0` getter, already
used elsewhere for drag-gating) — i.e. once the most recent solve reports
`dof == 0`. Per the prompt, this is sketch-wide and lines-only; circles and
per-entity colouring are explicitly deferred. A new `_FullyConstrainedBadge`
widget (a small dark pill with `Icons.lock` + "Fully constrained" text) is
positioned top-right of the canvas (the zoom-to-fit button already owns
top-left, the plane indicator already owns bottom-left), shown only while
`!isUnderConstrained`.

**Tests added**: a new `sketch_canvas_indicator_test.dart` widget test file
(following the existing `sketch_canvas_ghost_editor_test.dart`'s
trimmed-fake-backend pattern) confirms the padlock+label render when the
fake's `dof` is 0 and don't render when it's 1.

---

## Test/analyze results

This sandbox has neither the Flutter SDK nor the backend's conda
environment (`py-slvs`, `pythonocc-core`) preinstalled — both had to be
bootstrapped locally (see "Environment note" below). None of this
bootstrapping is committed.

**Backend** (`pytest`, OCC stubbed out — see note):
- `pytest tests/test_stage15_constraints.py` — 45 passed (was 36 before
  this prompt; +9 new: 5 for B3's orientation, 2 for B2's two-diagonal
  midpoint, 2 for B5's DOF, plus existing ones unaffected).
- `pytest tests/test_stage12_constraints.py` — 8 passed (+1 new, B2's
  construction-alongside-a-closed-loop test).
- `pytest` (whole suite) — 208 passed, 25 failed. All 25 failures are in
  `test_stage0_occt.py`/`test_stage7_document.py`/`test_stage9_extrude.py`/
  `test_stage11_edges.py`/`test_stage23_mesh_ids.py` — every one is a real
  OCCT geometry test hitting this sandbox's necessarily-fake OCC stub (see
  below), not a sketch/constraint file, and not something this prompt
  touched.

**Client** (`flutter analyze`/`flutter test`):
- `flutter analyze lib/sketch/sketch_controller.dart lib/sketch/sketch_canvas.dart lib/api/sketch_api_client.dart test/sketch_controller_test.dart test/sketch_canvas_indicator_test.dart` — no issues.
- `flutter test test/sketch_controller_test.dart` — 123 passed, 4 failed.
  All 4 failures are pre-existing bugs in this one test file, unrelated to
  any Prompt B item (`addCollinearConstraint`/`addEqualLengthConstraint`/
  `applyConstraintOption(collinear)` not clearing the selection set as
  expected, and `dragTargetPointIdAt` returning the origin id instead of
  `null`) — see "Known gaps" below for why these are newly *visible* in
  this run rather than newly *introduced*.
- `flutter test test/sketch_canvas_indicator_test.dart` — 2 passed (new).
- `flutter test` (whole suite) — 140 passed, 17 failed. All 17 are
  `flutter_scene`/`flutter_gpu` compile errors in viewport3d-dependent
  files (`clip_distance_test.dart`, `mesh_geometry_test.dart`,
  `orbit_camera_test.dart`, `part_screen_test.dart`,
  `part_viewport_test.dart`, `reference_planes_test.dart`,
  `selection_actions_test.dart`, `selection_hit_test_test.dart`,
  `selection_list_drawer_test.dart`, `sketch_geometry_3d_test.dart`,
  `triad_test.dart`) — the same pre-existing, documented (see Prompt D's
  status doc) `flutter_scene ^0.18.1` vs. this sandbox's bootstrapped
  `master`-channel engine snapshot incompatibility, in files this prompt
  never touched.

### Environment note

Neither the Flutter SDK nor the backend's conda toolchain (`py-slvs`,
`pythonocc-core`) was present in this container.

- **Flutter**: bootstrapped the same way as Prompt D's session (no working
  `git clone` of `flutter/flutter` — the in-container git proxy only
  allows `didsa-uk/didsa-cad` — so a `stable`-branch tarball was
  downloaded and unpacked, with a synthesized single-commit git history
  and a `FLUTTER_PREBUILT_ENGINE_VERSION` override pointed at the
  artifact hash actually published in `bin/internal/engine.version`,
  since `update_engine_version.sh`'s git-derived hash fallback produces a
  bogus value against a synthesized one-commit history). `flutter_scene`
  is incompatible with whatever engine snapshot results, per Prompt D's
  note — hence the 17 unrelated failures above.
- **Backend**: `py-slvs==1.0.6` was `pip install`able directly (no native
  build step), so B3's solver work was verified against the *real* wheel,
  not guessed from documentation — this is also how the
  `addPointsHorizDistance`/`addPointsVertDistance` absence was confirmed.
  `pythonocc-core` has no pip wheel (conda-only) and was not installed;
  `app.main` (and therefore the `TestClient`-based API tests in every
  `test_stage*.py` file) imports it at module level, so a minimal stub
  package (classes/functions matching the exact names imported by
  `app/main.py`/`app/document/{router,extrude,mesh}.py`, each a no-op)
  was placed ahead of it on `PYTHONPATH` purely so pytest can *collect*
  those files — every test that actually exercises real OCCT geometry
  (the 25 failures above) fails against the stub as expected; every
  sketch/constraint/profile test (which never reaches OCCT) passes
  normally. None of this stub is committed.

---

## Known gaps

- **The 4 pre-existing `sketch_controller_test.dart` failures** (listed
  above) were *invisible* until this prompt's work: that file's tests
  could never previously run in this kind of sandbox at all (`Rect`/`Size`
  were referenced without an import — a `flutter/widgets.dart` import was
  missing from the test file itself, unrelated to any application code).
  Fixing that one import (needed anyway for this prompt's own new B0
  tests) let the file load for what looks like the first time in any
  bootstrapped sandbox — Prompt D's own status doc lists this exact file
  as a "(load errors)" entry in its whole-suite run. That surfaced two
  separate, genuinely pre-existing bugs: (1) `addCollinearConstraint`/
  `addEqualLengthConstraint`/`applyConstraintOption(collinear)` not
  clearing `selectionSet`/closing the ribbon in this test's exact
  selection scenario, and (2) `dragTargetPointIdAt` offering the origin
  Point as a drag target when it shouldn't. Neither is touched by any
  Prompt B item; not investigated or fixed here as out of scope, but
  flagged since they were not visible before this branch.
- Two other test-fixture-only bugs *were* fixed here because they
  directly blocked verifying this prompt's own new tests: `_FakeBackend`
  (in `sketch_controller_test.dart`) had no `at_midpoint` case (falling
  into a `default` branch that unconditionally cast a non-existent
  `distance` field, crashing) and hardcoded every created Line's
  `construction` response field to `false` regardless of the request body.
  Both are test-only (no production code path was affected) and were
  silently never exercised before, for the same "this file never loaded"
  reason above.
- B5's fully-constrained colouring is sketch-wide and binary (per the
  prompt's own "acceptable simplified approach for this stage" framing) —
  no per-entity constrained colouring, no numeric DOF readout in the UI.
- B4's "two-step undo" choice (constraint first, then the Point) was
  picked over a single combined undo step because every other multi-call
  mutation already in this codebase (rectangles, midpoint materialization)
  uses the same one-entry-per-API-call convention — documented here per
  the prompt's "either is acceptable, document which."
