# DIDSA-CAD Status (Consolidated)

This is a single chronological consolidation of ~30 dated per-stage status
reports that accumulated in `docs/` between 2026-06-21 and 2026-07-02. The
originals are preserved verbatim under `docs/archive/` (moved with `git mv`,
so their history survives). This document exists so a future reader (or a
future Claude session) doesn't have to open 30 files to understand where the
project stands. Entries are ordered oldest-first; the most recent entry
(the still-open C3 rendering bug) is last. See `docs/roadmap.md` for
forward-looking open work; see `docs/project-brief.md` for the original
project spec (not a status log, left in place, not summarized here).

Recurring environment caveat, stated once here rather than in every entry:
for most of this project's history, sandbox sessions had no Flutter SDK, no
GPU/display, and no working `pythonocc-core`/`py-slvs` install, so client
changes were frequently verified only by manual code review (`flutter
analyze` when an SDK was bootstrapped) rather than `flutter test`/on-device
runs, and backend OCCT changes were sometimes verified only by `py_compile`/
`ast.parse` until real CI or a bootstrapped conda toolchain caught real bugs.
Where this materially affected confidence in a change, it's called out
per-entry below.

---

## Stage 2b — Wiring the constraint solver into the Sketch model (undated, precedes 2026-06-21)

Connected the Stage 2 Sketch data model (`Point`/`SketchEntity`/`Line`/
`Plane`/`Sketch`, closed-loop profile detection) to the Stage 2a `py-slvs`
spike. Added `backend/app/sketch/constraints.py` (`Constraint` ABC +
`DistanceConstraint`), `solver.py` (`solve_sketch`, returns `converged`/
`result_code`/`dof`/`blamed_constraint_ids`/`solver_reported_failed_constraint_ids`),
and `Sketch.constraints`/`add_distance_constraint`. Four new endpoints:
create/list/delete constraint, `POST .../solve`. Solving is explicit and
batched — nothing solves automatically on point edits.

Confirmed empirically (deliberately over-constrained triangle) that
`py-slvs`'s `system.Failed` returns every constraint in an inconsistent
system, not a single culprit — so "blame the newest constraint" is
documented as a UX convention, not a diagnosis.

Independent review caught `add_distance_constraint` missing the same-point
validation `add_line` already had; fixed pre-merge. CI: 59/59 passed on both
`linux/amd64` and `linux/arm64`. Merged via PR #4.

---

## 2026-06-21 — Stages 1–7 recap

Stages 1–6 (merged, PRs #1–#9): Line entity scaffold; Sketch foundation
(`Point`/`SketchEntity`/`Plane`/`detect_profile`); `py-slvs` wired in (Stage
2b, above); `X-API-Key` auth on every route; first Flutter client
(persistent cursor, click-to-commit lines, snap-to-close, live solve);
Circle entity + radius constraint + FAB tool switcher + pan/zoom; DELETE
endpoints (dependency-safe) + client selection/hover/ribbon/delete.

Unreleased-as-of-this-doc: `Document`/`Part`/`Feature` model with
Feature-locking + placeholder mesh endpoint; first 3D viewport
(`OrbitCamera`, `flutter_scene` mesh rendering). `flutter_scene` bumped
`0.5.0-0` → `^0.18.1` this session (Flutter SDK moved to `master` channel;
old version's Native Assets build hook was incompatible), dropping the old
`flutter_scene_importer` dependency chain.

Design decisions established here and unchanged since: Points are
first-class shared entities (no coordinate-matching auto-merge — entities
connect only by sharing a Point id); Circle's center/radius points don't
join the Line-chain adjacency graph (mixed Line+Circle profile detection
was an explicit gap, later closed in Stage 15/Prompt C).

Verified: Backend CI green. Client: `flutter analyze` clean, `flutter test`
51/51 passed, including the first-ever confirmation that `flutter_scene`
0.18.1's GPU-bound `uploadVertexData` call runs without throwing headlessly.

Branch state: main green through PR #9; `claude/new-session-ie585q` 3 commits
ahead (ribbon fix, Document/Part/Feature model, Stage 7 viewport), no PR yet.

---

## 2026-06-22 — Stage 7f: reference planes, triad, plane selection

Closed three gaps from Stage 7 real-device testing: reference planes
weren't visible, no XYZ orientation triad (3D viewport or 2D sketch
canvas), no way to see/choose a Sketch's plane.

- `reference_planes.dart`: XY/XZ/YZ as 20×20-unit translucent rectangles,
  visible by default on an empty Part; analytic per-axis ray-plane hit
  testing.
- `triad.dart`: screen-space XYZ triad overlay (bottom-left, always on top)
  — chosen over world-space specifically so it never rotates out of clear
  view. Axis-to-screen projection hand-verified against `flutter_scene`'s
  actual view-matrix convention (`right = up.cross(forward)`).
- `plane_indicator.dart`: small XY/XZ/YZ label + 2-axis arrows on the 2D
  sketch canvas.
- Tapping a plane highlights it and offers "New Sketch on `<plane>`".

Tests: 79/79 passed (+20 new), `flutter analyze` clean. A live
gesture-through-`PartViewport`/`Scene` test was attempted and abandoned —
intermittent `Flutter GPU requires Impeller` exceptions from inside `Scene`
construction, a pre-existing sandbox limitation.

Branch `claude/new-session-ie585q` merged with `claude/reference-planes-triad-plane-select`
(one real conflict in `part_viewport.dart`, resolved). Pushed, no PR opened.

---

## 2026-06-23 — Stage 9: Extrude (Boss + Cut)

First real OCCT geometry operation, replacing the placeholder box mesh.

- Backend: `ExtrudeFeature` model; `extrude.py` builds a prism via
  `BRepPrimAPI_MakePrism` then fuses (Boss) or cuts (Cut) against the
  accumulated solid; `/mesh` endpoint tessellates the real solid, falling
  back to the placeholder box only when no Extrude Feature exists yet.
- Client: `extrude_panel.dart` (Boss/Cut, start/end distance, 500ms
  debounce → create/PATCH → refetch mesh); live preview rendered
  translucent orange (`AlphaMode.blend`, alpha 0.45); Confirm/Cancel.

Tests: backend 159/159 (via micromamba `cadtest` env — bare pip/venv can't
import `pythonocc-core`). Client: 93/93, `flutter analyze` clean. Not yet
verified on a real device.

Branch `claude/didsa-cad-next-stage-dshvd7`, pushed, no PR/merge yet.

---

## 2026-06-23 — Stage 10a: signed distances, Hide/Show affects mesh, zoom bounds

1. **Signed Extrude distances**: `start_distance`/`end_distance` are now
   both signed offsets along the sketch normal, spanning literally from one
   to the other (previously `start_distance` was a magnitude used in the
   wrong direction). Validated server-side (`end_distance > start_distance`).
2. **Hide/Show now affects the body mesh**: `/mesh` accepts repeated
   `hidden_feature_ids`; the accumulated solid skips matching
   `ExtrudeFeature`s. Client-side only state, resent on every fetch.
3. **Zoom bounds scale to the mesh**: `OrbitCamera.setZoomBoundsForRadius(radius)`
   derives min/max distance from the mesh's bounding-sphere radius.

Backend: 166/166 passed. Client: **no Flutter SDK available this session**
— all Dart changes unverified by any test run. One flagged risk: a Python
quaternion simulation suggested `orbitByScreenDelta`'s upside-down drag
direction might not satisfy its own test, but this was left unchanged
(safer than risking a regression against unverified hand-rolled math).

Branch `claude/project-background-next-actions-larhyt`, pushed.

---

## 2026-06-23 — Stage 10b: UX additions

- "Hide Reference Planes" toggle in the flyout toolbar.
- "Add" FAB → flyout menu → "New Sketch" enters plane-selection mode (tap a
  plane to create+navigate; Cancel banner or back gesture exits).
- Add FAB hidden while the Extrude panel is open.

No backend changes. No Flutter SDK available — unverified by any test run
(new `part_screen_test.dart` tests were never executed). Committed
`ae0be4a` on `stage-10b-ux-additions`, pushed, PR opened but explicitly
left unmerged for review.

---

## 2026-06-23 — Stage 11: Edge rendering & wireframe toggle

- Backend: `MeshData.edges` (flat `[x,y,z,...]`), extracted via
  `TopTools_IndexedMapOfShape` + `topexp.MapShapes` (not a plain
  `TopExp_Explorer`, which would double-count shared edges), sampled via
  `BRepAdaptor_Curve` + `GCPnts_TangentialDeflection`. A box always reports
  exactly 12 edges regardless of triangulation fineness.
- Client: `ViewportRenderMode` enum (shaded / shaded+edges / wireframe);
  `nudgeSegmentsOutward` as a z-fighting mitigation (no native GPU depth-bias
  API in this `flutter_scene` version) — later superseded, see Prompt C/C3
  below.
- Geometry audit of reference-plane/sketch/extrude coordinate mapping: no
  bugs found, but documented a latent risk (`_sample_edge` doesn't apply
  `TopLoc_Location`, would silently break if a future change stopped baking
  transforms via `BRepBuilderAPI_Transform(..., True)`).

**Post-merge CI (PR #24) caught two real API bugs** neither manual review
nor `py_compile` could catch, since this sandbox had no working OCCT
binding: `OCC.Core.TopExp` has no `TopExp` class (fixed to the lowercase
`topexp` singleton); `TopTools_IndexedMapOfShape` has no `.Extent()`/
call-indexing (fixed to `.Size()`/`.FindKey(i)`). Both fixed, CI green,
171/171 passed, merged to `main`.

---

## 2026-06-23 — Stage 12: Dimensioning, constraints & construction lines

- Backend: `construction: bool` on Line/Circle (excluded from profile
  detection); `Vertical`/`Horizontal`/`Angle` constraints via native
  py-slvs primitives. Gap found+closed: no PATCH existed to flip an
  existing entity's construction flag — added `LineUpdate.construction`,
  new `CircleUpdate`, new PATCH route for circles. 5/5 + follow-up tests
  passed.
- Client (uncommitted as of this doc): dashed rendering for construction
  geometry; Make Construction/Make Solid ribbon toggle; reference-body
  ghost projection (`worldPointToSketch`, exact inverse of
  `sketchPointToWorld` since reference planes are axis-aligned through the
  origin); dimension overlays for Distance/Angle/V/H via a type-pattern
  switch.
- Explicit scope gap: no PATCH for editing a constraint's *value* yet
  (closed next stage) — dimension overlays were render-only this stage.

No Flutter SDK available — all client work unverified by any test run.

---

## 2026-06-24 — Stage 13: Tap-to-place, dimension workflow, constraint selection

- Backend: `PATCH .../constraints/{id}` (`ConstraintValueUpdate`) — edits
  Distance/Angle values, re-solves; Vertical/Horizontal get a 422. 178/178
  backend tests passed.
- Client: tap-to-place is now the only entity-input method (no more
  button-driven placement); two-level FAB (Sketch Entities / Dimensions)
  replacing a flat tool row; full ghost-dimension workflow (length, V/H
  distance, radius/diameter) confirming into real constraints; multi-entity
  selection with a `wired`/`unwired` constraint-option table (only
  Vertical/Horizontal actually create constraints this stage — Parallel/
  Perpendicular/EqualLength/Concentric/EqualRadius/Tangent/Coincident
  render as inert placeholders).

`sketch_controller_test.dart` rewritten against the new controller API.
`flutter analyze` clean, `sketch_controller_test.dart` 52/52 passed. Full
suite: 4 unrelated pre-existing `flutter_scene`/`flutter_gpu` version
mismatch failures (first documented here, recurs in every subsequent
client-side stage until fixed much later).

---

## 2026-06-24 — Stage 14: Point tool, universal snapping, selectable dimensions, drag

Pure client-side, no backend changes.

- `SketchTool.point`: single self-terminating tap, reuses existing snap
  logic.
- Universal point/midpoint snapping generalized to every placement path;
  tapping near a Line's midpoint materializes a real backend Point there
  (once, on first use).
- Constraints became selectable (hit-test + ribbon value editor for
  Distance/Angle).
- Dimension-mode revamp: multi-select picking with a fly-up bar
  (`sketch_dimension_bar.dart`) replacing the old at-most-two-taps model;
  covers line-distance (materializes midpoints) and angle (non-parallel
  lines) in addition to the earlier cases.
- Double-click-and-drag on under-constrained Points: whole-sketch
  `dof > 0` gates dragging (coarse, no per-entity freedom check exists);
  live-PATCH-without-solving during drag, re-solve on release.

`sketch_controller_test.dart` grew 52 → 72, all passing. `flutter analyze`
clean.

---

## 2026-06-24 — Stage 15

| Item | Outcome |
|---|---|
| Entity placement ghost preview | Done — dashed preview via `activeDrawGhost` |
| Double-tap-drag dimension/constraint labels | Done — client-side-only `_labelOffsets` |
| RTS edge-pan only while cursor moving | Done — idle threshold (150ms) |
| Snap-point hover highlight | Done |
| Wire Coincident/Parallel/Perpendicular/EqualLength | Done |
| Rectangle sketch tool | Done — Two Corner / Centre+Corner / Three Point |
| Closed-profile area fill | Done — translucent green fill + outline |

`sketch_controller_test.dart`: 95/95. Full suite: 106 passed, 7 failed (same
pre-existing `flutter_scene`/`flutter_gpu` mismatch, no regressions).

---

## 2026-06-24 — Stage 16

| Item | Outcome |
|---|---|
| Clip planes scale to model size | `farClip = max(1000, radius*4)`, `nearClip = farClip/10000` |
| Remove zoom-in restriction | `minDistance = nearClip * 2` |
| Sketch origin: snappable but fixed | excluded from selection, still resolves for snapping |
| Point-drag jump on double-tap begin | fixed — delta-from-recorded-origin, no PATCH at drag-begin |
| Edge-pan firing while stationary | fixed — 1.5px move threshold before refreshing idle timer |
| Constraint buttons → selection ribbon; add Collinear | done — new `CollinearConstraint` (two `point_on_line` calls, no single SLVS primitive) |
| Feature tree auto-hides during Extrude | done |
| Line-to-line distance dimension + leader-line fix | new `LineDistanceConstraint` via `SLVS_C_PT_LINE_DISTANCE` directly on endpoints (no materialized midpoint Points, so it stays correct if a Line moves); leader-line bug (dragged label detached from its dimension line) fixed with a shared `_drawLeaderLine` |

Sandbox had no Flutter/Dart SDK and no `pythonocc-core` — verified by
manual review; a solver-level claim (`LineDistanceConstraint` converges
correctly) was independently confirmed via a direct-import script bypassing
`app.main`/OCC.

---

## 2026-06-24 — Stage 17: device-testing fixups

Real-device (Android/touch) follow-up to Stage 16:

1. Point tool now gets the same fly-up tool bar (with Exit) as other tools.
2. **Touch point-drag tracking bug**: root cause was a coordinate-space
   mismatch — the drag branch fed raw absolute screen position through the
   1:1 mouse mapping (`screenToSketch`) instead of the desensitized
   "trackpad" `moveCursorRelative` mapping every other touch interaction
   uses. Fixed by branching on `event.kind`.
3. **Origin not selectable for constraints**: Stage 16's origin-exclusion
   in `_entityAt` broke selection entirely (including pre-existing tests)
   and blocked legitimate Coincident-to-origin constraints. Fixed with an
   `includeOrigin` parameter — drag targeting still excludes it, selection
   now includes it; deletion was already independently blocked.

---

## 2026-06-25 — Stage 18: menu restructure, viewport polish, connection screen

- Hamburger menu → File/View `ExpansionTile`s. File: 7 disabled
  placeholders + enabled "Connection Settings". View: existing entries +
  Background/Body Colour swatch pickers + Body Transparency slider.
- Viewport visual polish: new defaults (background `#1E1E2E`, body
  `#B0B8C1`), applied live and persisted via `shared_preferences`. Body
  "specular highlight" left as an explicit `// TODO` — `UnlitMaterial` has
  no roughness/metallic parameter to set, not implementable with the
  current `flutter_scene` material type.
- New `ConnectionScreen`: runtime server URL + API key config (previously
  compile-time constants), `GET /health` check with 15s timeout, persists
  via `shared_preferences`.

No Flutter SDK — verified by manual reading only.

---

## 2026-06-25 — Stage 19a: edge bleed-through (attempt 1, later reverted), defaults, camera framing

| Item | Outcome |
|---|---|
| Edge bleed-through on solid geometry | Implemented `cullBackFacingSegments` (back-face heuristic using bounding-sphere-center-to-midpoint direction as a normal stand-in) — **reverted in 19b**, see below |
| Body transparency edge visibility | Already correct from Stage 18, no fix needed |
| Edge line thickness | `kEdgeStrokeWidth` narrowed 2.0 → 1.1px |
| Default background → Off-white | `#F5F5F0` (only affects fresh installs) |
| Default render mode → Shaded+Edges, persisted | new `view_render_mode` pref key |
| Initial camera distance | `_defaultDistance` 30 → 48, so reference planes fill ~25% of screen area (derived from real 45° FOV + 20-unit plane size) |
| Autofill on Connection Screen | `AutofillGroup` + `AutofillHints.url`/`.password` |

Investigated the render pipeline directly against upstream `flutter_scene`
source: confirmed the opaque pass already does depth write + `lessEqual`
test, so no app-level draw-order bug was found. The back-face cull was
implemented as an *approximation* (not exact for concave bodies), fully
documented as such.

---

## 2026-06-25 — Stage 19b: revert the cull; feature-tree FAB; undo; select-all; Set Length

- **Item 0**: reverted Stage 19a's back-face edge cull entirely — user
  feedback: it made edges disappear on faces visible *through* a
  transparent body, an unacceptable trade-off versus the original
  bleed-through. (The bleed-through bug itself stayed unresolved here; it
  resurfaces and is eventually root-caused much later — see Prompt C/C3.)
- Feature tree got a dedicated small FAB (removed from the View sub-menu).
- 3D-view/plane context menus moved from the hamburger drawer into a
  fly-up bottom sheet.
- Add FAB → Feature entry → second-level picker (Extrude enabled;
  Revolve/Sweep/Fillet/Chamfer disabled placeholders).
- **Sketcher undo**: not a full-snapshot stack (doesn't fit this
  architecture, where the backend is the sole source of truth) — a
  **command/inverse-action stack** instead: every mutation pushes a closure
  that performs its literal backend-and-local inverse. Delete recreates
  full copies with an old-id→new-id remap. No redo (`// TODO`).
- Select all (excludes origin); Set Length ribbon chip (PATCHes/creates a
  plain `DistanceConstraint` between a Line's endpoints).
- Extra: confirming an Extrude now auto-hides the consumed Sketch.

No SDK — manual verification only; Items 4–6 got no test coverage.

---

## 2026-06-26 — Stage 20

| Item | Outcome |
|---|---|
| Camera distance | Skipped — already applied manually in a prior commit |
| Delete-selected dependency order | Fixed — bucket into constraints → lines/circles → points regardless of selection order (backend 400'd otherwise) |
| Framework assertion crash (`_dependents.isEmpty`) | Inconclusive — full audit of every `GlobalKey`/`showModalBottomSheet`/`mounted` guard found one real gap (`sketch_ribbon.dart`'s `_showSetLengthDialog` had no `context.mounted` guard); fixed defensively, root cause not confirmed (recurs later — see Stage 23-fixes addendum) |
| AppBar logo + name | Done — **broken by a `Row`-in-`title` layout bug, fixed next stage** |
| Point tool icon | `Icons.fiber_manual_record` → `Icons.control_point` |
| Midpoint constraint | v1: two half-length `DistanceConstraint`s from `_materializeMidpoint` — **later found not to constrain collinearity at all, replaced twice (Stage 21, then Stage 22)** |
| Stale-solve-after-drag | Root cause: an unawaited per-move-event PATCH could resolve after `endPointDrag`'s solve+refresh, clobbering the constrained position with a stale one. Fixed with a `_draggingPointId` staleness guard |

Manual-only verification missed a real compile error in item 6
(`line.length` doesn't exist) — caught by the user's on-device `flutter
run`, not this sandbox.

---

## 2026-06-26 — Stage 21

- **AppBar layout fix**: Stage 20's `Row`-with-`spaceBetween` `title`
  doesn't work — `title` is a narrow centered slot. Fixed by moving the
  logo into `AppBar.leading` (widened) and right-aligning the title text.
  New shared `DidsaLogoButton` widget (tap → website).
- Dark logo asset variant for contrast against the light AppBar.
- **Midpoint constraint v2**: replaced Stage 20's two-half-length-distances
  hack with a new backend constraint type, `PointLineDistanceConstraint`
  (generic point-to-line distance via `addPointLineDistance`/
  `SLVS_C_PT_LINE_DISTANCE`) — used as perpendicular-distance-0 (point on
  line) + one half-length distance to an endpoint. This is the first
  *correct* solver-stable midpoint definition (the v1 pair never
  constrained collinearity, only distance from each endpoint, letting the
  point swing freely in an arc).
- **Select-all → delete still 400ing**: root cause — `selectAll()` never
  included Constraints, so a Line's leftover `VerticalConstraint` (not
  auto-deleted with the Line) blocked the subsequent Point delete. Fixed
  by having `selectAll()` also select every Constraint in the sketch.

**Post-push CI bug**: a new test failed (`y≈0.333` instead of expected
`0.0`). First hypothesis (wrong): suspected py-slvs needed
`SLVS_C_AT_MIDPOINT` special-casing at distance-exactly-0 — pushed a fix,
CI failed identically, proving the primitive wasn't the issue. Real cause:
the test's own Points were completely unconstrained free points, so the
system was legitimately underdetermined (4 excess DOF) and the solver was
free to move the whole line to satisfy the constraints — the test's
absolute-coordinate assertions were wrong, not the solver. Reverted the
special-case, rewrote the test to assert relative geometric invariants
(matching the codebase's existing convention for underdetermined
solver-integration tests).

No Python backend environment in-sandbox this session — this bug was only
caught via real GitHub Actions CI.

---

## 2026-06-26 — Stage 22

- **Native `at_midpoint` constraint (`SLVS_C_AT_MIDPOINT`)**: verified
  directly against the installed `py-slvs==1.0.6` wheel (`addMidPoint`) —
  a proper per-primitive wrapper matching the existing pattern. Wired
  through the full 5-layer stack. This is the final, correct midpoint
  implementation (v3) — unlike v1/v2, it has no fixed baked-in value, so it
  keeps tracking the true midpoint as the line's length changes
  independently (regression-tested explicitly against this exact failure
  mode).
- Client: `_materializeMidpoint` simplified to one `createAtMidpointConstraint`
  call. No constraint badge needed for `at_midpoint` (falls through
  existing default-case switches with zero code change).
- **FAB z-order fix**: two independent overlap bugs in `part_screen.dart` —
  the small Feature-tree FAB painted over the open toolbar panel (fixed
  with a visibility guard); the main Add FAB, being `Scaffold.floatingActionButton`,
  always painted above the body `Stack` regardless of internal ordering
  (fixed by nulling it while the toolbar is open, same pattern as the
  Extrude-panel gating).

---

## 2026-06-26 — Stage 23: sketcher UX polish (23a–23h)

| Item | Outcome |
|---|---|
| 23a — Set Length dialog crash | Root cause: `TextField(autofocus: true)` with no explicit `FocusNode` — Flutter's deferred focus-grant could still be in flight when the dialog synchronously popped. Fixed with an explicit `FocusNode` + `.unfocus()` before pop. **Later found insufficient — see Stage 23-fixes below.** |
| 23b — Reset View → Zoom to Fit | new `geometryBoundingBox`/`zoomToFit`; zoom floor now derived from canvas size instead of a fixed constant |
| 23c — Shorter constraint labels | Vert./Horiz./Perp./Coinc. |
| 23d — Remove tap-empty-canvas Exit Sketch | blank-canvas tap while ribbon closed is now a pure no-op |
| 23e — Labels/tap-select for every constraint type | added Coincident/Parallel/Perpendicular/EqualLength/Collinear/PointLineDistance badges (AtMidpoint deliberately still excluded — no badge, per Stage 22) |
| 23f — Hamburger drawer: Exit Sketch + View submenu | Constraint Labels toggle, Canvas Colour, Canvas Transparency — session-only, no persistence |
| 23g — Long-press marquee selection | 500ms timer, hand-rolled (no `GestureDetector`/`LongPressGestureRecognizer` — everything in this file is raw `Listener` pointer dispatch) |
| 23h — Selected Entities list in the flyout | shown once 2+ entities selected |

New `sketch_controller_test.dart` group for `hasEntityNear`/`selectInRect`/
`deselect`/`selectionLabel`. No Flutter SDK — verified by manual review +
a brace/paren-balance script.

Note: `docs/stage23-background.md`, referenced by the brief, never existed
in this repo.

---

## 2026-06-27 — Stage 23 fixes, and the separate "3D viewport selection mode" feature

Two independently-developed, differently-scoped pieces of work landed
around the same date and both initially collided on the filename
`status-2026-06-26-stage23.md` (already taken by the sketcher-UX-polish
work above). The 3D-viewport selection-mode feature and its fixes used
non-colliding filenames instead; all of it is consolidated here.

### 3D viewport selection mode (new feature)

Orbit/Selection mode toggle FAB; persistent on-screen cursor while in
selection mode; hover hit-testing (backend `mesh.py` gained `face_ids`/
`edge_ids`/`topology_vertices`/`topology_vertex_ids` parallel arrays,
stable only within one response); toggle/accumulate/clear selection
semantics; a draggable bottom sheet listing selected entities; a context
action panel (`contextActionsFor`, composition table for Chamfer/Fillet/
Create Plane based on what's selected — all permanently disabled
placeholders this stage). Orbit-mode gesture handler bodies were
deliberately never edited — all new logic lives in wrapper methods,
confirmed by re-diffing line-by-line.

### Stage 23 fix-prompt round (targeting both pieces of work)

Of 7 requested items, most were found already correct on inspection; real
fixes: selected-entity highlight render order (re-add the hover node after
`_syncSelectedEntityNodes` so "selected then hover on top" ordering holds);
removed the dedicated "Select" button in favor of tap-to-select (mirroring
the orbit handlers' existing tap/drag travel-threshold disambiguation);
`SelectionListDrawer` rebuilt around `DraggableScrollableSheet` with FAB
clearance padding; hamburger toggle converted to a small FAB positioned
above the feature-tree FAB. Item 6 (`_dependents.isEmpty`) was marked "not
applicable" — no `InheritedWidget` exists anywhere in this codebase.

### Addenda — real-device reports falsified two "confirmed correct" verdicts

- **The Set Length crash (23a) still reproduced live.** Real root cause:
  `FocusNode.unfocus()` only *schedules* a focus change (applied on the
  next frame's pre-build phase) — both fix sites called it and then
  immediately, synchronously, removed the focused widget in the same call,
  racing the deferred change. Fixed by deferring the actual removal
  (`Navigator.pop`, the controller call) into
  `WidgetsBinding.instance.addPostFrameCallback`, guaranteeing a full frame
  elapses first.
- **Vertex hover/selection almost never won over an edge.** Root cause: the
  vertex-vs-edge tie-break required the vertex to be *at least as close* as
  any in-range edge, but an edge's closest-point calculation can always
  slide toward the cursor while a vertex is fixed — so an edge won for
  nearly every cursor position except dead-center on the vertex's exact
  pixel. Fixed: a vertex within its own (wider) radius now wins
  unconditionally.
- Two more found afterward: vertex highlight dots use `PolylineCap.butt`
  (the `flutter_scene` default), which renders literally nothing for a
  near-zero-length segment — only `PolylineCap.round`'s end-cap disc is
  visible; fixed by passing `cap: PolylineCap.round` for vertex markers.
  Sketch screen's menu FAB was bottom-right (inconsistent with the 3D
  viewport's top-left convention) and painted behind the ribbon — both
  fixed. 2D sketcher's point hit-box was too small relative to line/circle
  hit-boxes (a point is one location vs. an entire length/circumference) —
  added a `pointHitRadiusMultiplier = 1.6`.

None of this round's fixes were verified via `flutter test` (no SDK) —
manual reasoning against documented `FocusManager` frame-scheduling
behavior and worked-out pixel-distance math only.

---

## 2026-06-30 — Prompt A: 3D viewport fixes

| Item | Outcome |
|---|---|
| A2 — Box selection | Implemented (double-tap-then-drag, geometric frustum projection) — **later fully removed, see Box Selection Report below** |
| A3 — Clip distance constants, auto-fit, slider | `kDefaultNearClip`/`kDefaultFarClip`, persisted, log-scale View-menu slider, auto-fit on Reset View based on mesh AABB diagonal |
| A4 — Perspective toggle | State/persistence/UI fully wired; `flutter_scene` 0.18.x has no `OrthographicCamera` and no settable FOV, so the two modes currently render identically (documented `TODO`) |

Constraint maintained throughout: all four orbit gesture handler bodies
stayed line-for-line unchanged; every new behavior lives in wrapper methods.

---

## 2026-06-30 — Box selection: three attempts, all rejected on-device, feature parked

| # | Approach | On-device result |
|---|---|---|
| 1 | Hand-rolled `_worldToScreen` (original A2) | Selected the wrong corner/region — systematic projection bug |
| 2 | Frustum-plane test via `screenPointToRay` corner rays | Selected nothing at all, any zoom level |
| 3 | Direct 2D screen-projection (camera-axis dot products) | Selected *something* but unreliably — missed some inside the box, included some outside |

User's verbatim decision: *"Not robust enough to rely on. let's park it for
now."* Box selection was fully removed (state, gestures, hit-test, toolbar
UI, tests); the viewport reverted to single-tap-toggle multi-select. No
local Flutter/Dart toolchain meant each iteration could only be validated
by the user's on-device testing — a slow loop that produced three
different failure modes in three attempts. Any future revisit should
budget for on-device/screenshot verification rather than code-review-only
iteration.

---

## 2026-06-30 — Viewport bug-fix round (same session as Prompt A)

Seven bugs fixed, two kept as real fixes after box selection's removal:

- **One-sided face highlights**: `triangleHighlightBuffers` now emits each
  triangle twice (both windings) so hover/selection highlights render
  regardless of which side the camera views — works around
  `flutter_scene`/Impeller back-face culling.
- Cursor crosshair got a dark outline stroke for visibility on any
  background.
- Perspective toggle documents its current no-op status inline.
- Selected-edge highlight given its own darker blue (`#0D47A1`), distinct
  from selected-face/-vertex; selected-vertex marker diameter reduced
  14px → 8px.
- Box-selection-only state/menu items (the "Contain Only" toggle, deferred
  tap-commit timer, box-drag cursor tracking) all removed along with the
  feature itself.

---

## 2026-06-30 — Prompt D: Feature tree sketch picker for Extrude

New > Extrude, with no eligible Sketch already selected, now opens the
Feature tree in a guided picker mode (banner + dimmed-ineligible rows)
instead of just complaining via SnackBar. Tapping an eligible Sketch closes
the picker and opens `ExtrudePanel` directly; an ineligible tap shows an
inline error and stays in picker mode. Canceling (tree close button, back
gesture, background tap) creates nothing.

**Addendum bug, same day**: confirming or canceling an Extrude never
cleared `_selectedFeatureId`, so a later New > Extrude re-used the stale
selection and skipped the picker entirely — including after deleting the
resulting Extrude. Fixed by clearing `_selectedFeatureId` in both
`_confirmExtrude`/`_cancelExtrude` when it names the just-operated-on
Sketch.

Flutter SDK bootstrapped from a `master`-branch tarball this session (the
in-container git proxy blocks a real `flutter/flutter` clone); 11
pre-existing failures elsewhere in the suite attributed to this snapshot
being newer than whatever `master` the rest of the suite was last verified
against.

---

## 2026-06-30 — Prompt B: Sketcher fixes (B0–B5)

| Item | Outcome |
|---|---|
| B0 — Cursor boundary clamping | `clampCursorToCanvas` + wiring through every pan/zoom/drag path — **later found to fight with RTS edge-pan and replaced with a "disappear, don't snap" model, see bugfixes below** |
| B1 — H/V on center/corner rectangles | 2 Horizontal + 2 Vertical constraints replace 3 Perpendicular (3-point rectangles keep Perpendicular — no fixed axis alignment to assume) |
| B2 — Construction geometry + center point on rectangles | 2 construction diagonal Lines + a center Point pinned via AtMidpoint constraints |
| B3 — H/V dimensions preserve orientation after solve | The prompt's assumed py-slvs methods (`addPointsHorizDistance`/`addPointsVertDistance`) don't exist in the installed 1.0.6 wheel — verified by downloading and inspecting it directly. Used `addPointsProjectDistance` against one cached fixed horizontal/vertical reference line instead. New `DistanceConstraint.orientation` field threaded through the full stack |
| B4 — Auto-Coincident when a point lands on an existing point | The shared placement path already reuses existing-point ids outright (no "two independent coincident points" scenario can occur there) — implemented specifically for the standalone Point tool, whose purpose is placing an independently-addressable point |
| B5 — Fully-constrained indicator | Backend `dof` field already existed; added missing test coverage + client-side line-color/badge wiring |

Backend: 208 passed, 25 failed — all 25 in OCCT-geometry files hitting this
sandbox's necessarily-fake OCC stub, none in sketch/constraint files. This
run also surfaced two *pre-existing* bugs in `sketch_controller_test.dart`
(a missing `flutter/widgets.dart` import had silently prevented the whole
file from ever loading in any prior sandbox) — flagged but not fixed, out
of scope.

---

## 2026-06-30 / 2026-07-01 — Prompt B device-testing bug-fix rounds (15 items)

Four consecutive rounds of real on-device bug reports against Prompt B,
same branch.

**Round 1 (2026-06-30), items 1–8:**

1. Cursor clamping erratic / RTS edge-pan feel — root cause: B0 snapped the
   cursor to center on *every* in-flight delta, not just once genuinely
   off-canvas, fighting the edge-pan compensation. New model: panning never
   touches the cursor; it's simply left wherever it drifts and disappears
   (`isCursorVisible`) rather than being forced back; a fresh drag
   gesture resets to center only if it starts already-hidden.
2. "Fully constrained" always showing / lines never grey — **real backend
   bug**: `solve_sketch()` short-circuited to a canned `dof=0` whenever a
   sketch had zero Constraints, regardless of how much free unconstrained
   geometry existed. Fixed to always build/solve the full system (every
   Point registered, not just constraint-referenced ones). Also added a
   `hasGeometry` gate so a genuinely empty sketch doesn't show "fully
   constrained" either.
3. Indicator hidden behind Exit Sketch — moved from a canvas-overlay badge
   to a plain lock icon in the AppBar title.
4. Double-tap drag not working — same root cause as #2 (drag was gated on
   `isUnderConstrained`, which was never truthfully nonzero).
5. Selection hit box vs. hover highlight sizing inconsistent — unified
   `kSelectionHitRadiusPixels`/`kVertexSelectionHitRadiusPixels` to the
   same `12.5px` (midpoint of the old 9/16 split).
6. 3D viewport pinch-zoom/two-finger-pan broken in selection mode — the
   selection-mode pointer wrapper had no multi-touch branch at all; fixed
   by routing 2+ active touches to the existing (unmodified) `_applyPinchPan`.
7. Dimension orientation reverting to linear after solve — `_findDistanceConstraint`
   matched by point-pair alone, ignoring orientation, so confirming a new
   orientation for an existing pair silently PATCHed the wrong constraint's
   value instead of replacing it. Fixed with an orientation-aware lookup
   plus a delete-and-recreate fallback.
8. Feature tree text color after deleting last Feature — investigated at
   length, no bug found or reproduced; regression test added defensively.

**Rounds 2–4 (2026-07-01), items 9–15** (three of these are items 1/7/8
above turning out to be incomplete or misdiagnosed on retest):

9. Cursor still teleporting mid-drag — item 1's fix ran its "reset if
   hidden" check on *every* delta during a drag, not once per gesture.
   Moved into a dedicated `resetCursorToCentreIfHidden`, called exactly
   once from `_handlePointerDown`.
10. Stale DOF after deleting a Circle — deleting a Circle cascades to
    delete its radius Constraint server-side, but the client only
    re-solved when the *directly* deleted entity was itself a Constraint.
    Fixed: always re-solve after any deletion.
11. **A real, previously-undetected solver bug**: B2's rectangle
    construction pinned its diagonals' shared center with *two*
    `AtMidpoint` constraints; once the H/V side constraints already forced
    both diagonals through the same point, the second constraint became
    redundant *and* singular — py-slvs failed to converge
    (`converged == False`) but still reported `dof == 0`, so a solve
    failure displayed as "most constrained possible," exactly backwards.
    Fixed at both ends: rectangles now create only one `AtMidpoint`
    constraint, and `isUnderConstrained` no longer trusts `dof` when the
    last solve didn't converge.
12. Sketcher hover/tap hit-box mismatch — `hoveredEntity` used a flat
    unscaled radius while `handleCanvasTap` used a zoom-scaled one. Unified
    on the zoom-scaled calculation; also shrank `minTapHitRadiusPixels`
    22px → 14px.
13. H/V dimensions rendering as diagonal after solve — **not a solver bug,
    a rendering bug**: the underlying constraint was already
    orientation-aware (from B3); `_paintDistanceDimension`/
    `_constraintLabelCenter` simply never read `orientation` and always
    used the generic diagonal layout once confirmed (the ghost *preview*
    got it right; only the confirmed render didn't). Fixed to match.
14. Sketch stays hidden after deleting its Extrude — `_cascadeDeleteFeature`
    only ever cleared hidden-feature ids for Features that no longer exist;
    the auto-hidden Sketch still exists (just unlocked again), so its id
    stayed hidden forever. Fixed to also un-hide the newly-unlocked Sketch.
15. No visual distinction between "under-constrained" and "not yet
    evaluated"; title bar overflow. Fixed: indicator now always shows
    `lock_open` (under-constrained) or `lock` (fully constrained) once
    there's geometry; title wrapped in `Flexible` with ellipsis.

Also confirmed: Equal Length constraint reports, previously flaky, came
back clean once item 11's redundant/singular constraint was removed —
same root cause, no separate fix needed.

This is also where the recurring `flutter_scene 0.18.1` vs. sandbox-engine
incompatibility was first fully diagnosed: `flutter_scene` needs
`flutter_gpu` APIs only present in Flutter **master** channel builds from
2026-06-09 or later (stated in its own pubspec); every bootstrapped stable
SDK in this project's sandboxes predates that, so any `flutter_scene`-importing
test file fails to even compile under `flutter test` here, though
`flutter analyze` (pure static analysis) is unaffected. Documented as
sandbox-only — the real CI/build environment already targets a compatible
Flutter version.

---

## 2026-07-01 — Prompt C: Nested profiles, multi-body extrude, and edge bleed-through (round 1)

### C1/C2 — Nested and multi-profile detection

`detect_profile` rewritten: trace every Line-chain loop *and* every
standalone Circle into one flat list of closed loops, then classify via
new `_classify_nesting` (centroid-in-polygon test with an area tie-break —
needed because a hole centered on its own container makes each loop's
centroid fall inside the other, so area, not just centroid containment,
decides which is the container). One outer loop + 0+ holes = `CLOSED_LOOP`
with `Profile.inner_loops` populated (C1); 2+ outer loops reuses the
existing `MULTIPLE_LOOPS`/`loops` shape (C2), each entry itself possibly
carrying its own holes. A loop nested inside 2+ others is rejected as new
`ProfileStatus.INVALID_NESTING`.

`extrude.py`: `_face_for_profile` builds the face via
`BRepBuilderAPI_MakeFace(outerWire).Add(innerWire)` per hole, with each
inner wire's winding checked against the outer's real surface normal
(`_wire_normal`, via `BRepAdaptor_Surface`) rather than reasoned about
analytically — necessary because a Circle's fixed winding direction is
*not* the same handedness relative to the plane normal on all three
reference planes (XZ mirrors XY/YZ). Multiple outer loops combine into a
`TopoDS_Compound`. `mesh.py` needed no changes — `TopExp_Explorer`/
`topexp.MapShapes` already traverse into compounds transparently.

This session had a **real conda/micromamba toolchain working** (a first
for this project — `conda.anaconda.org`'s package artifacts are reachable
even though the wider Anaconda API/installer isn't) — so all 13 new tests
ran against genuine OCCT geometry construction, not a stub. This is how the
area/centroid tie-break bug was actually caught (a real test failure, not
inspection). Backend: 249/249 passed.

### C3 — Edge bleed-through (attempt)

Evaluated three approaches from the prompt's own preferred order: (1) a
separate always-on-top depth-disabled pass — not achievable, `flutter_scene`
0.18.1 has no per-material depth toggle and no second render pass API; (2)
**chosen** — bias each edge vertex towards the camera (replacing the old
"away from mesh center" nudge, which barely helped at grazing angles since
"away from center" and "towards camera" can be nearly perpendicular); (3)
enlarge the bias only on near-face-parallel segments — not attempted, no
edge-to-face adjacency exists in the mesh data to test against.

`kEdgeDepthBias = 0.001` expressed as a *fraction of the mesh's
bounding-sphere radius* (scaling with model size, mirroring Prompt A's
auto-fit far clip) — **this specific choice was wrong, see round 1
bugfixes below**. Re-synced on every completed camera gesture (not every
frame), so the bias direction can be briefly stale mid-drag (disclosed
trade-off).

A working Flutter SDK (official stable 3.44.4) was available this session
for the first time via reachable `storage.googleapis.com`/`pub.dev` —
`flutter analyze` is a real run, not just reasoning from source. `flutter
test` still blocked by the same pre-existing `flutter_gpu` mismatch (stable
channel predates the master-only APIs `flutter_scene` needs).

---

## 2026-07-01 — Prompt C on-device bug-fix round 1

1. **Overlapping/touching inner loop produces a broken solid instead of an
   error.** Root cause: centroid-only containment isn't sufficient — a
   loop whose centroid is inside its container can still share/cross the
   container's own boundary (the reported case: a hole sharing a whole
   edge with the outer rectangle). A vertex-only containment check didn't
   catch it either (ray-casting classifies an on-edge point as "inside").
   Fixed with `_loop_fully_contains`: vertex containment **plus** a
   segment-intersection check between every candidate/container edge pair.
   New `ProfileStatus.OVERLAPPING_LOOPS`, reported distinctly from
   `INVALID_NESTING`.
2. **MultiProfile sketches never offered for extrude.** The backend gate
   (`_require_closed_sketch_feature`) already accepted `MULTIPLE_LOOPS`,
   but the *client's own pre-check* (`_checkExtrudeEligibility`) only ever
   looked at `isClosedLoop` — so the UI rejected it before the (already
   correct) backend was ever reached. Fixed with a new
   `ProfileDetectionDto.isExtrudable` (`closed_loop` OR `multiple_loops`).
3. **Far-side edges and highlighted faces bleeding through solid
   geometry.** Root cause: the new `kEdgeDepthBias`, scaled to the *whole
   mesh's* bounding-sphere radius, ignored that a stepped/notched part's
   local features can be much shallower than that global radius — so the
   bias could push a far wall's edges in front of a nearer wall by more
   than the feature's own depth. Fixed by reverting to a small **fixed**
   world-space amount (`0.02`, matching the original pre-Prompt-C nudge's
   magnitude) — the original z-fighting bug was always attributed to
   *direction*, never magnitude, so this keeps the corrected direction
   while restoring the known-safe magnitude.

Backend: 252/252 passed (real OCCT/py-slvs environment, not a stub).

---

## 2026-07-01 — Prompt C on-device bug-fix round 2

1. **Sketch canvas doesn't highlight multiple closed profiles.** Root
   cause: the client DTO only ever parsed the single `profile` field
   (`null` for `multiple_loops`) — a gap from before C1/C2 existed, never
   revisited once they landed (same category as round 1 item 2). Fixed:
   `ProfileDetectionDto.fillableLoops` parses every outer loop (from either
   `profile` or `loops`) recursively with inner loops; canvas fill now uses
   an even-odd fill rule so holes render correctly punched out — a genuine
   new capability, not just a multi-profile fix.
   - **Follow-up**: a standalone Circle profile's fill still didn't render.
     Two compounding bugs: a defensive `>= 3` point-count filter silently
     dropped every Circle "loop" (reported as exactly 2 points: center +
     radius point), and even past that, the canvas always called
     `Path.addPolygon` regardless of shape. Fixed: filter loosened to
     `>= 2`; new `_addLoopBoundary` draws a real circle (`Path.addOval`)
     for a 2-point loop, a polygon for 3+.
2. **Internal faces/hidden edges showing through solid bodies — investigated
   in depth.** Read `flutter_scene`'s actual render pipeline source
   directly: confirmed the engine's opaque/translucent split *is*
   architecturally correct (shared depth buffer, proper test/write
   semantics) — **not an inherent flutter_scene limitation**. Found and
   fixed one real, confirmed contributor: `buildMeshEdgesNode` used
   `AlphaMode.opaque`, which depth-*writes* — combined with the
   towards-camera bias, this could corrupt what a later translucent
   highlight's depth test saw at the same pixels. Fixed to `AlphaMode.blend`
   (still depth-tested, no longer depth-written; also fixed a latent bug
   where `_selectedEdgeColor`'s partial alpha was silently rendered fully
   opaque under the old mode). **On-device retest: symptom persisted.**
   Traced one level deeper (`scene_pass.dart`): confirmed the engine builds
   exactly one `RenderTarget`/one `SceneEncoder` per frame — ruling out a
   render-graph/pass-structure explanation too. This round's fix was real
   and worth keeping, but evidently not the only factor; investigation
   handed off with concrete next-step questions (does it reproduce with no
   highlight active at all? does nudging transparency off exactly 0% change
   anything?) since further progress needed a live GPU, unavailable in any
   sandbox to date.

Backend unaffected this round (252/252, unchanged). Client: 151 passed
(+3 new), 17 failed (same pre-existing `flutter_scene`/`flutter_gpu` set).

---

## 2026-07-02 — C3 rendering investigation, continued

After the two prior rounds above, on-device testing continued to show
edges and highlighted/selected faces bleeding through opaque geometry that
should hide them. Findings this round, in order:

1. Traced `flutter_scene` 0.18.1's `scene_pass.dart` (`ScenePass.execute`)
   and confirmed it builds exactly one `RenderTarget`/one `SceneEncoder`
   per frame — ruling out a render-graph/pass-structure explanation
   entirely (suspected but unproven at the end of round 2).
2. Pivoted to an MSAA hypothesis: `Scene`'s default `AntiAliasingMode.auto`
   enables MSAA when the GPU reports `doesSupportOffscreenMSAA=true`
   (confirmed true on the test device — Samsung Galaxy S23 Ultra /
   SM-S918B, Adreno 740). Added an explicit `flutter_gpu` dependency to
   `client/pubspec.yaml` and forced
   `Scene()..antiAliasingMode = AntiAliasingMode.none` in
   `part_viewport.dart`'s `initState`. **Confirmed partial improvement**:
   fixed the "gross/total" bleed-through, leaving a smaller residual —
   dashed/broken hidden edges visible in a graduated pattern.
3. Iteratively tuned `kEdgeDepthBias` chasing the residual: 0.02 → 0.1 →
   0.3 → back to 0.05. At 0.3, a new regression appeared: edges leapfrogging
   through thin/closely-spaced features (a comb/serrated part, a
   disc-with-square-hole part) — precisely described as "when the edges
   are behind 1 face they're visible, behind 2 faces they're visible,
   behind 3 faces they're no longer visible." Reverted to 0.05
   (commit `8c29b32`) to avoid the overshoot regression.
4. **Critical finding**: retested at 0.05 and the *exact same*
   "1–2 occluding faces insufficient, 3+ sufficient" pattern was still
   present, completely unchanged from 0.3 — falsifying "bias
   magnitude/overshoot" as the explanation on its own.
5. Verified via a debug log line
   (`[PartViewport][RenderDebug] scene: antiAliasingMode=...
   effectiveAntiAliasingMode=...`) that `AntiAliasingMode.none` genuinely
   takes effect at runtime — logcat confirmed
   `effectiveAntiAliasingMode=AntiAliasingMode.none`. (Getting this log
   required switching two startup diagnostic lines from `debugPrint` to
   plain `print`, since Flutter's default `debugPrintThrottled` buffer was
   burying/delaying them behind this file's high volume of per-frame
   `debugPrint` calls elsewhere.)
6. Checked (and later re-confirmed) that Android's system-level "Force 4x
   MSAA" developer option makes no difference either on or off — ruling
   out a system-level override of the in-app AA setting.
7. **Decisive experiment**: a throwaway branch
   (`claude/diagnostic-extreme-edge-bias`, since deleted) set
   `kEdgeDepthBias = 2.0` — a 40x increase over the shipped 0.05,
   deliberately large enough to be an obvious diagnostic. On-device: the
   *exact same* "1–2 occluding faces visible, 3+ hidden" pattern persisted
   completely unchanged, confirmed independently on both test parts,
   viewed statically. This conclusively rules out bias magnitude as the
   mechanism — a 40x range with zero effect on the qualitative pattern is
   not consistent with a depth-precision/z-fighting explanation.
   - Side note: at bias=2.0, orbiting produced a separate, fully-explained
     artifact — a translucent "preview-like" floating wireframe, caused by
     the one-frame lag between camera movement and `_syncEdgesNode`
     recomputing the bias against the new camera position (imperceptible
     at 0.05, obvious at 2.0). Confirms the bias is genuinely being
     applied; not the bug under test.

**Current theory (unresolved, not yet fixed)**: with MSAA, bias direction,
bias magnitude (0.05 through 2.0), and render-graph/depth-buffer-sharing
all ruled out or verified-correct, the leading explanation is a GPU
hardware/driver behavior below the level `flutter_gpu`'s public API
exposes — specifically Adreno GPUs' hierarchical/low-resolution early-Z
rejection hardware ("LRZ"), which has a documented history of exactly this
failure signature on Qualcomm hardware: a single occluding depth write
failing to properly populate/be respected by the coarse Z structure, while
several occluding writes converge to the correct (occluded) result. There
is no public API in `flutter_gpu`/`flutter_scene` 0.18.1 to disable or
influence this. **This is an open, unresolved item — see `docs/roadmap.md`.**

Decision: `kEdgeDepthBias` stays at `0.05` and `AntiAliasingMode.none`
stays in place on `claude/new-session-s8daac` — both are net improvements
over earlier states even though neither fixes the residual bug, and
reverting either would only reintroduce previously-fixed regressions for
no benefit.

---

## 2026-07-03 — Prompt A1: backend Feature dependency graph + multi-body identity

Backend-only. First of a new four-part prompt sequence (A1–A4, distinct
from the earlier lettered "Prompts A–D" already summarized above) that
replaces implicit list-order recompute with an explicit dependency graph
and introduces multi-body identity so Boss/Cut can target specific bodies
instead of one implicit accumulated solid. A2–A4 (client-side selection
filter framework, body-as-selectable-entity, Boss/Cut target-body picking)
are explicitly out of scope for this entry and have not been started.

**Dependency graph** (`backend/app/document/graph.py`, new file, zero
OCCT/pythonocc-core imports): `GraphNode(id, depends_on)` + Kahn's-algorithm
`topological_order()`. Ties among simultaneously-ready nodes are broken by
original input order, which was the deliberate design choice that makes
the regression requirement hold *by construction*: for any Part whose
Features have no dependency edge reaching back past the immediately
preceding Feature (i.e. every pre-A1 single-body scenario), the sort
reduces to exactly the old list order. `CycleError` is raised for a
malformed/cyclic graph, though the public API can't currently construct
one (a Feature can only ever reference ids that already exist by the time
it's created).

`app/document/extrude.py` gained `build_feature_graph(part)` (edges: every
`ExtrudeFeature` depends on its `sketch_feature_id` plus every id in
`target_body_ids`) and `compute_part_bodies(part, hidden_feature_ids)`,
which replaces the old `compute_part_solid` — walks Features in
topological order instead of raw list order and returns `dict[body_id,
TopoDS_Shape]` instead of one accumulated shape.

**Multi-body identity.** A Body's id is **the id of the `ExtrudeFeature`
that created it** — a Boss with empty `target_body_ids` starts a new Body
identified by its own feature id. This was the deliberate design choice
that makes `target_body_ids` entries *already be* Feature ids, so no
separate Body↔Feature lookup/table was needed anywhere (mesh endpoint,
graph edges, validation all just deal in Feature ids). **Merge rule**
(documented in `ExtrudeFeature`'s docstring and `compute_part_bodies`):
when a Boss's `target_body_ids` names 2+ existing Bodies, they're fused
with the new solid into one Body, which keeps whichever named id belongs
to the Feature that appears earliest in `Part.features` — a single,
deterministic tie-break, not left ad hoc. Covered by
`test_boss_merge_survivor_id_is_the_earliest_target_regardless_of_argument_order`
(survivor is independent of `target_body_ids` list order).

`ExtrudeFeature` gained `target_body_ids: list[str]`. Boss: empty → new
Body; non-empty → fuse into each named Body. Cut: empty is rejected with
**422** (`_validate_target_body_ids` in `router.py`) — the prompt spec
named 422 explicitly and also said to reuse "the same shape as the
`end_distance > start_distance` check"; that existing check is actually a
**400**, not 422 (confirmed in `test_stage9_extrude.py` before this
change). Read literally, those two instructions conflict on status code;
resolved by using 422 (stated twice — once in the prompt, once in the
on-device testing checklist) and matching only the *body shape* of the
existing check (`HTTPException(status_code=..., detail="plain string")`,
no custom error envelope — which is what "same shape" most plausibly
means, since that's the only convention this codebase has). Flagging this
explicitly in case 400 was actually intended. Every `target_body_ids`
entry (Boss or Cut) is also validated at create/update time to resolve to
an `ExtrudeFeature` already in the Part → 400 if not, mirroring the
existing `sketch_feature_id` validation pattern.

**`/mesh` endpoint** is now `list[BodyMeshResponse]` (was a single
`PartMeshResponse` object) — one entry per Body, each with its own
`body_id`, `source`, and `mesh` (vertices/triangles/`face_ids`/`edge_ids`/
`topology_vertex_ids`, scoped to that Body's own tessellation only, same
per-request-only id-stability caveat as before A1). The placeholder-box
case (`Part.produces_solid_geometry == False`) returns a single-entry
array (`body_id="placeholder"`). A Part with nothing computed (every
ExtrudeFeature skipped or hidden away) now returns `[]` — a real,
intentional behavior change from the old response, which still returned
one object with `source="computed"` and empty mesh arrays for that case;
there's no single "the" Body left to attach an empty mesh to once Bodies
are a real array, so "nothing to show" is now the absence of any array
entry rather than one empty one. Flagged in both `test_stage23_mesh_ids.py`
and `test_stage11_edges.py`, which each replace their old
"`empty_computed_mesh`" test with
`test_body_with_a_skipped_cut_and_no_other_geometry_is_absent_from_the_array`.

**Test changes** (`backend/tests/`): `test_stage9_extrude.py`,
`test_stage23_mesh_ids.py`, `test_stage11_edges.py`, and
`test_stage7_document.py` all updated for the array-wrapped `/mesh`
response — every direct `client.get(.../mesh).json()` call site now goes
through a local `_get_bodies`/`_single_body` helper. Cut-creating call
sites now pass an explicit `target_body_ids`. One premise genuinely
disappeared: "Cut with no prior Boss is skipped gracefully" is no longer
expressible, since Cut requires a named target at creation time — replaced
by `test_cut_with_empty_target_body_ids_is_rejected_with_422` (the new
required behavior) and `test_cut_targeting_a_hidden_body_is_skipped_gracefully`
(the new equivalent "nothing to cut from" case: a real target that's
hidden away at recompute time). New file `test_stage_a1_graph.py` (13
tests, pure Python, no OCCT) covers `topological_order` directly — chains,
independent-node order-preservation, far-back dependency edges, diamond
dependencies, unknown/duplicate/self-referencing dependency ids, direct and
transitive cycles, and a Boss/Cut-shaped fan-in/fan-out scenario. New file
`test_stage_a1_multibody.py` covers every A1 testing-checklist scenario:
Boss new/fuse-one/fuse-multiple, merge-survivor determinism, Cut
empty→422, Cut only touching its named target(s) (not other bodies), Cut
against multiple targets at once, unknown-target-id→400 for both Boss and
Cut, PATCH clearing `target_body_ids` on a Cut→422, two independent bodies
in one `/mesh` response (confirming `face_ids` are dense/self-contained
per body, not offset by other bodies), and `target_body_ids` round-tripping
through create/GET.

**Verification — real OCCT/py-slvs environment not available in this
sandbox** (`import OCC` fails; no `conda`/`micromamba`; `docker build`
against `backend/Dockerfile` failed — no Docker daemon reachable, and
`dockerd` doesn't start in this container). What was actually verified:
- `test_stage_a1_graph.py` — installed `pytest` directly (no OCCT
  dependency in `graph.py`) and ran it for real: **13/13 passed.**
- Every other changed/added file (`models.py`, `extrude.py`, `mesh.py`,
  `schemas.py`, `router.py`, and all four OCCT-touching test files) —
  `ast.parse`-verified (syntactically valid) plus manual line-by-line logic
  review; **not executed**, since that requires real `pythonocc-core`.
- This is a materially bigger verification gap than most prior entries in
  this log, precisely because A1's stop condition exists to close it before
  A2 starts: **CI must run and a manual `curl`/Postman pass against
  Boss/Cut/`target_body_ids`/`/mesh` must confirm this before any client
  work (A2+) is built on top of it.** See `docs/roadmap.md`.

Not started/stopped here per A1's own instructions: A2 (client selection
filter framework) and everything after it. Fillet/Chamfer/Create Plane and
Prompt B (sub-shape refs, tree categories, cascade delete, earlier-feature
editing) remain explicitly out of scope, unchanged from before.

**CI follow-up (same day):** `.github/workflows/backend-verify.yml` ran
against commit `3992055` (both the `push` and `pull_request` triggers) and
came back green on both `linux/amd64` and `linux/arm64` — confirmed by
pulling the actual job logs, not just the run's `conclusion` field:
`278 passed in 4.01s` (amd64) and `278 passed in 60.47s` (arm64, slower
under QEMU emulation), identical pass count on both. Every new/updated A1
test (`test_stage_a1_graph.py`'s 13 cases, `test_stage_a1_multibody.py`,
and the array-response updates across `test_stage9_extrude.py`/
`test_stage23_mesh_ids.py`/`test_stage11_edges.py`/`test_stage7_document.py`)
is individually visible as `PASSED` in the log output, executed against
real `pythonocc-core` inside the Docker image this time (this sandbox
still can't do that itself). This closes the verification gap flagged
above — the manual `curl`/Postman API sanity pass is still outstanding,
but the automated half of A1's stop condition is now genuinely confirmed,
not just assumed.

---

## 2026-07-03 — Manual curl sanity pass against a live A1 server

Closes the remaining half of A1's stop condition. `docker build` against
`backend/Dockerfile` was attempted again and genuinely failed on policy
grounds this time (not "no daemon" as in the original A1 entry) —
confirmed via the sandbox's egress-proxy status endpoint, which recorded
explicit `403` policy denials for `production.cloudfront.docker.com`
(Docker Hub's CDN, needed for the `mambaorg/micromamba` base image) and
`micro.mamba.pm` (the micromamba installer, tried as a Docker-free
fallback). A raw `github.com` release-asset download (Miniforge, a third
fallback) also came back `403`, but from GitHub's own API, not the proxy —
this session's GitHub scope is `DIDSA-UK/DIDSA-CAD` only, so unrelated
repos/assets are out of reach. Real `pythonocc-core` is unreachable from
this sandbox by any path tried.

Given that, and that every new piece of A1 validation logic
(`target_body_ids` checks, distance checks, locking) runs in pure Python
*before* any OCCT call — only `/mesh`'s actual tessellation needs real
geometry — a minimal **fake OCCT shim** (`OCC.Core.*` stub package,
scratch-space only, never committed) was built with just enough surface
for `app.main` to import and boot: fixed fake box shapes (6 faces/12
edges/8 vertices, arbitrary coordinates), `BRepAlgoAPI_Fuse`/`Cut`
returning fresh fake shapes, `BRepMesh_IncrementalMesh`/`TopExp_Explorer`
producing structurally-valid (not geometrically accurate) triangulation
data. This proves the **API contract** — status codes, response shape,
body-id derivation/merge logic, array-of-bodies wiring — via genuine HTTP
round-trips against the real, unmodified FastAPI app; it does not and
cannot prove geometric correctness, which is what the real-OCCT CI run
above already confirmed.

`pip install fastapi==0.115.*/uvicorn==0.34.*/httpx==0.27.*/py-slvs==1.0.6`
(all reachable — PyPI is proxy-allowlisted) plus the fake `OCC` package on
`PYTHONPATH` let `app.main` boot for real. Ran `uvicorn app.main:app` and
curled it directly (not `TestClient`, not pytest — an actual live HTTP
server on `127.0.0.1:8123`):

- `/health` without `X-API-Key` → `401`; with it → `200`.
- `GET /mesh` on a Part with no ExtrudeFeature → array of exactly **one**
  entry, `body_id="placeholder"`, `source="placeholder"` — confirms the
  array-wrapping applies even to the placeholder-box path, not just
  `source="computed"`.
- Boss with `target_body_ids: []` → `201`; `GET /mesh` afterward returns
  exactly one Body whose `body_id` **equals the Boss feature's own id** —
  confirms the "Body id = creating Feature's id" rule end-to-end over
  real HTTP, not just inside a test process.
- Cut with `target_body_ids: []` → **`422`**,
  `{"detail": "Cut requires at least one target_body_ids entry..."}`.
- Boss/Cut naming an unknown `target_body_ids` entry → **`400`**,
  `{"detail": "target_body_ids entry 'does-not-exist' does not refer to
  an ExtrudeFeature in this Part"}`.
- Cut with a valid target → `201`; `GET /mesh` still shows exactly one
  Body, same `body_id` as the Boss it targeted (Cut never changes body
  identity).
- `PATCH` clearing `target_body_ids` to `[]` on an existing Cut → `422`,
  same message as create-time.
- Two independent Bosses (no shared target) on one Part → `GET /mesh`
  returns exactly **two** array entries with two distinct `body_id`s.
- A third Boss naming both of those bodies in `target_body_ids` (listed
  in reverse creation order, `[boss2, boss1]`) → `GET /mesh` afterward
  shows exactly **one** Body, and its `body_id` is `boss1`'s — confirms
  the deterministic "earliest-created target survives" merge tie-break is
  independent of `target_body_ids` argument order, over real HTTP, not
  just inside `test_boss_merge_survivor_id_is_the_earliest_target_regardless_of_argument_order`.
- Hiding the Boss feature via `?hidden_feature_ids=<id>` → `GET /mesh`
  returns `[]`, not a single entry with empty mesh arrays — confirms the
  documented "nothing computed = empty array, not an empty Body" behavior
  change end-to-end.
- `/openapi.json` schema inspection: `BodyMeshResponse` has exactly
  `body_id`/`source`/`mesh`; `ExtrudeFeatureCreate` has
  `target_body_ids` alongside the pre-existing fields; the `/mesh` GET
  response schema is a bare JSON array of `BodyMeshResponse`, not an
  object wrapping one.

All of the above matched the intended behavior exactly, with no
surprises relative to what the code review and CI run already implied.
Every temporary artifact (fake `OCC` package, live server process, the
`dockerd` instance started to attempt the real build) was torn down
afterward — nothing from this pass is committed to the repository.

**A1's stop condition is now fully satisfied**: real-OCCT CI is green
(278/278 across both architectures) and the manual API sanity pass above
has independently confirmed the same endpoints respond correctly over a
real HTTP connection. A2 can begin.

---

## 2026-07-03 — Prompt A2: client selection filter framework + push/pop override mechanism

Client-only, no backend changes. Wires up vertex/edge/face/body selection
filter toggles in the 3D viewport's View submenu and builds a reusable
push/pop override primitive - no modal flow consumes the override yet
(that's A4).

**Correction to A2's own premise**: the prompt describes "wiring up the
existing placeholder selection-type filter toggles... in the 3D viewport
menu." Investigated first and found this isn't accurate - a disabled
"Selection Filter" placeholder *did* exist at one point but was removed
during the box-selection cleanup (see this doc's 2026-06-30 entry,
"`part_toolbar.dart`: removed... the entire `_buildSelectionMenu`
ExpansionTile... along with its call site"). Confirmed via grep across
`part_toolbar.dart`/`part_screen.dart`/`part_viewport.dart`: no vertex/
edge/face/body toggle UI, no `CheckboxListTile`/similar, anywhere. Built
the whole thing from scratch rather than wiring up something already
there - flagging this since the prompt's premise didn't match the
codebase, not silently treating it as "found and wired" when it wasn't.

**Filter state** (`client/lib/viewport3d/selection_filter.dart`, new):
`SelectionFilterState` - immutable value class, `vertex`/`edge`/`face`/
`body` bools, `SelectionFilterState.defaults` (vertex/edge/face on, body
off, matching hit-testing's pre-A2 behaviour of always considering
vertex/edge/face). Session-only: lives as a plain field
(`_PartScreenState._selectionFilterBase`) mutated via `setState`, the same
convention `SketchScreen`'s Canvas Colour/Transparency toggles use - not
`ViewPreferences`, which is the *persisted*, `shared_preferences`-backed
convention and deliberately not what this prompt asked for.

**Push/pop override mechanism** (`client/lib/viewport3d/override_stack.dart`,
new): `OverrideStack<T>` - generic, zero-Flutter-dependency push/pop stack;
`current`/`isActive`/`depth`/`push`/`pop`/`clear`. `_PartScreenState` owns
`_selectionFilterOverrides = OverrideStack<SelectionFilterState>()`;
`_selectionFilter` (what hit-testing/the View submenu actually use) is
always `_selectionFilterOverrides.current ?? _selectionFilterBase`. Nothing
pushes onto this stack yet in A2 (that's A4's Boss/Cut target-body picker) -
per the prompt's own scope note, this prompt only builds and exercises the
primitive itself, so no dead "push an override" UI/method was added
speculatively; A4 will call `.push()`/`.pop()` on this field directly, the
same way the migration below already does.

**Migrated plane-selection mode to `OverrideStack<bool>`** (Stage 10b's
`_planeSelectionMode`, `part_screen.dart`): per the prompt's explicit
invitation ("if migrating plane-selection mode itself to use this new
primitive is straightforward, do it... a real-world correctness check on
the mechanism"). Turned out straightforward: this mode only ever had one
push/one pop, at exactly 5 call sites (1 entry, 4 "exit" sites - confirm-tap,
background-tap, sketch-picker-entry defensively closing it, and the
explicit Cancel handler). Replaced the plain `bool` field with
`final OverrideStack<bool> _planeSelectionModeStack`, kept
`_planeSelectionMode` as a read-only getter (`.isActive`) so every existing
*read* site (`if (_planeSelectionMode)`, the `PopScope.canPop` check, the
banner-visibility check) is untouched, and replaced only the 5 write sites
(`= true` → `.push(true)`, `= false` → `.pop()`, `.pop()`'s existing
no-op-on-empty semantics matching the old idempotent-`= false`
behaviour exactly). No behaviour change intended or expected.

**Hit-test gating** (`client/lib/viewport3d/selection_hit_test.dart`):
`hitTestMeshEntities` gained a `filter` parameter
(`SelectionFilterState filter = SelectionFilterState.defaults`) - a kind
whose flag is off is skipped *entirely* (not merely deprioritized), so
turning vertices off lets a hover land on an edge/face a nearby vertex
would otherwise have won outright. `PartViewport` gained a
`selectionFilter` prop, threaded through `_recomputeHover` (the single
choke point both hover-highlight and tap-select-commit already read from -
see `_hoverHit`/`_commitSelection` - so gating it here covers both without
touching either). `SelectionFilterState.body` has no effect on hit-testing
at all - there's no body-level hit-test yet (Prompt A3) - so the toggle
exists and does nothing observable, per the prompt's explicit instruction
not to stub fake body-selection behaviour early.

**View submenu UI** (`part_toolbar.dart`): four new toggle rows ("Vertices"/
"Edges"/"Faces"/"Bodies") added to `_buildViewMenu`, right after the
render-mode picker. Used the checkbox-icon `ListTile` convention this exact
menu's "Perspective" entry already established (`leading: Icon(value ?
Icons.check_box : Icons.check_box_outline_blank)`), not the `SwitchListTile`
`SketchScreen`'s View submenu uses elsewhere - matching the local file's
own existing convention over the sibling screen's, since they're two
different menus that happen to share a name.

**Testing.** No Flutter/Dart SDK was present in this sandbox (this
project's recurring caveat, stated at the top of this doc) - bootstrapped
one this session: Flutter 3.44.4 stable, downloaded directly from
`storage.googleapis.com`'s release manifest (reachable through the proxy,
confirmed via `curl`; SHA256 verified against the manifest before
extracting), the same version a past session used successfully. This
allowed **real** `flutter analyze` and `flutter test` runs, not just
`ast.parse`-equivalent static checks:
- `flutter analyze`: **zero new issues** anywhere in `lib/` or `test/` -
  the only findings are 3 pre-existing `avoid_print` infos in
  `part_viewport.dart` (unrelated debug logging from the C3 investigation)
  and 2 pre-existing errors in `selection_list_drawer_test.dart` (a
  `const Set` of `SelectionEntityRef`, a type with custom `==`/`hashCode` -
  not a file this prompt touched).
- New file `client/test/override_stack_test.dart` (9 tests) and
  `client/test/selection_filter_test.dart` (6 tests) - both **pure Dart,
  zero `flutter_scene`/`flutter_gpu` dependency** - ran for real:
  **15/15 passed.** Covers empty-stack state, single push/pop, nested
  push/pop restoring in exact order, no-op pop on empty, `clear`,
  re-use after fully draining, genericity, `SelectionFilterState.defaults`,
  `copyWith` (both "changes only the named field" and "omitted fields keep
  their current value, not a default"), and value equality.
- New filter-gating cases added to `client/test/selection_hit_test_test.dart`
  (vertex-off falls through to edge even when nearer; vertex+edge-off falls
  through to face; everything-off always returns null even where geometry
  exists; edge-off alone doesn't disturb vertex priority; face-off turns a
  would-be face fallback into `null`) - **`flutter analyze`-clean but not
  executed**: this file (like `mesh_geometry_test.dart`,
  `clip_distance_test.dart`, `orbit_camera_test.dart`, `part_screen_test.dart`,
  `part_viewport_test.dart`, `reference_planes_test.dart`,
  `selection_actions_test.dart`, `selection_list_drawer_test.dart`,
  `sketch_geometry_3d_test.dart`, `triad_test.dart`, and 6 more - 17 files
  total) fails to *load* under this Flutter 3.44.4 stable SDK because it
  transitively imports `flutter_scene` (via `mesh_geometry.dart`, itself
  needed for `edgeSegmentsFromMesh`), and `flutter_scene` 0.18.1 requires
  `flutter_gpu` APIs that don't exist on the stable channel this SDK
  ships (`ColorAttachment`/`vertexLayout`/`TextureCompressionFamily`/etc
  compile errors, all inside `flutter_scene`'s own source, not this
  project's) - **the exact same pre-existing constraint already documented
  earlier in this file** ("`flutter test` has been blocked by the same
  pre-existing `flutter_gpu` mismatch... even when a stable SDK was
  available"). Confirmed this isn't something A2 introduced: every one of
  the 17 failing-to-load files either predates this prompt entirely
  (`mesh_geometry_test.dart`, `triad_test.dart`, etc. - files this prompt
  never touched) or fails for the identical transitive-import reason
  (`selection_hit_test_test.dart` imports `selection_hit_test.dart`, which
  has imported `mesh_geometry.dart` since long before this prompt).
  Full suite: **167 passed, 17 failed-to-load** (all 17 pre-existing,
  0 newly broken).
- Toggle-wiring/on-device behaviour (the View submenu's four entries
  actually appearing and flipping state, hit-testing visibly respecting
  them on a real device) could not be exercised here for the same
  `flutter_scene`/`flutter_gpu` reason - `PartToolbar`/`PartScreen`
  transitively import `flutter_scene` via `orbit_camera.dart`'s
  `kDefaultFarClip`, so there's no way to widget-test even the toolbar in
  isolation without hitting the same compile wall. Per the prompt's own
  testing section, this is exactly the on-device check that's still
  outstanding.

Not started/stopped here per A2's own instructions: A3 (body as a
selectable entity) and everything after it.

---

## 2026-07-03 — Prompt A3: client body-as-selectable-entity (started early, off a real bug report)

Client-only. Landed out of the normal "wait for on-device confirmation of A2" sequence: on-device testing of A1+A2 hit a real bug ("can't create a body, Extrude Confirm does nothing") that turned out to be exactly A1's deferred client-side gap - investigated first, confirmed the root cause, then went straight into A3 since it's the actual fix.

**Root cause (confirmed, not assumed)**: A1 changed `GET /mesh` from one `{source, mesh}` object to a JSON array. The client's `PartMeshDto.fromJson(body as Map<String, dynamic>)` still expected the old object shape - casting the new array to a `Map` throws a Dart `TypeError`. `_ensureExtrudeFeatureExists` create/PATCHes the ExtrudeFeature successfully (2xx), then calls `_refreshMesh()`, which is where the throw happens. `ExtrudePanel.onConfirm` is a plain `VoidCallback` wired to the `async` `_confirmExtrude`, called fire-and-forget with nothing awaiting/catching its `Future` - so the `TypeError` became a genuinely uncaught async error (Dart's zone-level handler just logs it), never reaching `_runGuarded`'s `on ApiException catch` (wrong exception type) or the UI's `_errorMessage` display. Net effect: the Feature *is* created server-side, but the client never shows it and the panel never closes - "press Confirm, nothing happens," exactly as reported.

**Fix (this prompt's actual scope, not a patch - A1 explicitly deferred this client work to A3):**

- `document_api_client.dart`: `PartMeshDto` replaced with `BodyMeshDto` (`bodyId`/`source`/`mesh`); `getPartMesh` now returns `Future<List<BodyMeshDto>>`, parsing the top-level JSON as a `List`.
- `mesh_geometry.dart`: new `boundsOfBodies(List<BodyMeshDto>)` - a true AABB union across every Body's real vertices (not an approximation from unioning bounding spheres), the multi-body counterpart to `boundsOfMesh`.
- `part_viewport.dart` (the bulk of this prompt): `PartViewport.mesh: MeshDto?` → `bodies: List<BodyMeshDto>`. `_meshNode`/`_edgesNode` (single `Node?`) became `Map<String, Node>` keyed by `bodyId`, rebuilt wholesale on every sync call - the same pattern `_planeNodes`/`_sketchNodes` already used, not a new one. `_syncMeshNode`/`_syncEdgesNode` kept their names (renaming ~15 call sites/doc comments across the file for a cosmetic plural would have been pure churn) but now loop `widget.bodies`. Existing per-Feature hide/show needed **no new client logic** - confirmed by reading the backend: `hidden_feature_ids` is still a server-side filter, a hidden Feature's Body simply doesn't appear in the array, so this "fell out for free" once the array was parsed correctly.
- **Body as a selectable entity** (`selection_hit_test.dart`): `SelectionEntityKind` gained `body`. `SelectionEntityRef` gained a `bodyId` field (default `''`, fully backward-compatible with every existing test construction, since face/edge/vertex ids from A1 are only unique *within* one Body's tessellation, not globally). New `hitTestBodies` is the real multi-body entry point `PartViewport` now uses - vertex/edge priority is unchanged, just extended across every Body's nearest candidate; **Body is not a fourth hit-test tier alongside vertex/edge/face** - toggling A2's Body filter on changes what a face-ray-intersection *means* (resolves to the owning Body instead of the tapped face) rather than adding a competing kind, and Body deliberately takes precedence over a plain face pick whenever both filters are on. A face-intersection test runs whenever either `face` or `body` is enabled, specifically so a future "bodies only" picking mode (A4) still has a working ray test even with `face` itself off.
- Whole-body highlighting (`part_viewport.dart`'s `_buildEntityHighlightNode`/`_syncSelectedEntityNodes`) reuses the existing "selected faces" highlight `Node` - a Body-kind entity just contributes *every* triangle in its mesh into the same accumulator a Face-kind entity's single face would, rather than inventing a fourth highlight-node type.
- `selection_list_drawer.dart`: Body icon/label added to both exhaustive switches (Dart's enum-exhaustiveness caught both automatically once `body` was added). Sort comparator gained a `bodyId` tiebreak - face/edge/vertex ids collide across Bodies now, so `(kind, id)` alone was no longer a stable sort key. A Body row shows a shortened `bodyId` (first 8 characters) instead of a meaningless `#0`.
- `selection_actions.dart`: added a guard so a Body-only selection returns no context actions, rather than falling through every composition branch to the final "alone" case and nonsensically offering "Create Plane" against a whole Body - a real correctness gap this prompt's own `body` kind newly made reachable, not something previously possible.

**Testing.** Flutter 3.44.4 (bootstrapped in A2, still present this session):
- `flutter analyze`: **zero new issues** - same 2 pre-existing `selection_list_drawer_test.dart` errors as A1/A2 (a file this prompt didn't touch structurally, still just the `const Set` custom-equality issue), same 3 pre-existing `avoid_print` infos.
- New file `client/test/document_api_client_test.dart` (7 tests, **zero `flutter_scene` dependency - ran for real**): `BodyMeshDto.fromJson` directly, plus `getPartMesh` end-to-end via a `MockClient` - single computed Body, multiple independent Bodies, the single-entry placeholder array, an empty array (everything hidden), and confirming `hidden_feature_ids` is still sent correctly. This is the test suite that directly covers the actual bug fix.
- New `hitTestBodies` group in `selection_hit_test_test.dart` (10 tests: body-id tagging, same-local-id-different-bodies non-collision, body-filter face-precedence, vertex priority preserved across bodies, empty-list/miss-ray null cases) - **`flutter analyze`-clean but not executed**, since this file transitively imports `flutter_scene` via `mesh_geometry.dart` (the same pre-existing 17-file constraint documented in A2's entry, unchanged by this prompt). Worth flagging one subtlety caught while writing these: pixel-distance-based nearest-hit comparison does **not** simply favor whichever Body is closer in world-Z - `_worldUnitsPerPixelAtDepth` scales with depth, so a fixed world-space offset maps to a *larger* pixel distance the closer it is to the camera. The fixture had to use deliberately different-sized offsets per Body to produce an unambiguous, correctly-reasoned expected winner; an initial equal-offset version would have asserted the wrong Body if actually run.
- Full suite: **174 passed** (167 from A2 + 7 new, all genuinely executed), **17 failed-to-load** - identical file set to A2's entry, confirmed unchanged (same `flutter_gpu`/`flutter_scene` stable-channel mismatch, not something this prompt introduced).
- Not verified here (needs the flutter_scene issue resolved, or a real device): on-device confirmation that the original bug is actually fixed (Extrude Confirm now works), that multi-body rendering looks correct, and that tapping a face in body-filter mode selects/highlights the whole body.

Not started/stopped here per A3's own instructions: A4 (Boss/Cut target-body
picking flow). Wait for on-device confirmation that the original bug is
fixed and that multi-body rendering/body selection are both correct before
target-body picking is built on top of them.

---

## 2026-07-03 — Backend amendment: a Body is always one connected solid

Backend-only, amending A1's original body-identity rule. Off another real on-device finding while testing A3: extruding two disjoint profiles from one sketch in a single Boss showed as *one* selectable Body spanning both unrelated-looking shapes (a disc and a plate) - one tap highlighted both, the selection list showed exactly one entry. Confirmed that was exactly what A1 shipped and tested (`test_extruding_two_disjoint_squares_produces_a_compound_of_two_solids` explicitly asserted one Body containing a 2-solid compound) - not a bug, but a real product decision. Asked the user directly rather than silently picking a side: keep "one Feature = one Body" (as shipped), or match mainstream CAD tool behaviour where each disjoint solid is its own independently-selectable Body even from one Extrude operation. **User chose the latter.**

**New rule**: a Body is always exactly one maximally-connected solid, not "whatever one Boss/Cut operation produced." Every Boss/Cut result (new, fused, or cut) is now decomposed via `TopExp_Explorer(shape, TopAbs_SOLID)` before being registered - a multi-profile Boss with disjoint outer loops, or a **Cut that severs a Body into disconnected pieces** (a new case that couldn't even arise under the old rule), both now produce multiple Bodies from one operation.

**Id scheme** (`app/document/extrude.py`): unchanged for the common case - a single connected solid still gets the plain id it always did (creating Feature's id, or the merge-survivor id). N>1 connected solids get `f"{base_id}#{i}"` suffixes, in `TopExp_Explorer`'s deterministic order (`_register_solids`, new). `base_feature_id()` (new, public) strips a `#N` suffix to resolve a composite id back to its owning Feature - used by the merge-survivor tie-break, `build_feature_graph`'s dependency edges, and (critically) `router._validate_target_body_ids`, which was fixed to call it before the `part.get_feature(...)` lookup - **without this fix, a client sending back a composite id it saw in a `/mesh` response would have been incorrectly rejected with a 400**, since no literal Feature has an id like `"abc-123#0"`. Caught this by design review before it ever shipped, not by a bug report.

No schema or endpoint shape changes - `target_body_ids`/`body_id` are still plain strings throughout; a composite id is just a string with a `#N` in it, opaque to every other layer (the mesh response, the graph, the client). Confirmed the A3 client needs **zero changes** for this: `SelectionEntityRef.bodyId`, `_bodyFor`, and the drawer's truncated-id display already treat `bodyId` as fully opaque, with no assumption it matches a Feature id format.

**Testing.** Same environment constraints as A1/A3 (no real `pythonocc-core`/Docker locally):
- Pure-graph tests (`test_stage_a1_graph.py`) unaffected, re-ran for real: 13/13 passed (this change doesn't touch `graph.py`).
- Updated `test_stage9_extrude.py`'s three multi-profile tests (previously asserting one compound Body) to assert two separate single-solid Bodies with split-suffixed ids and the correct per-Body face counts.
- New tests in `test_stage_a1_multibody.py`: a Cut with a full-through slot that provably severs a 20x10x10 box into two 6-faced halves (`{boss_id}#0`/`#1`); a composite id from a split being independently targetable by a *later* Cut (only the targeted half changes, the other is bit-for-bit untouched); a composite id whose base Feature doesn't exist still correctly 400s.
- `ast.parse`-verified, not executed - same fallback as always for OCCT-touching code in this sandbox.
- **Manual live sanity pass** (same fake-OCCT-shim technique as A1's, extended this round: the shim's `TopExp_Explorer(shape, TopAbs_SOLID)` previously returned bare `object()` placeholders, which would have crashed the very first face/edge/vertex explorer call against them now that *every* Boss/Cut result is exploded via this path - fixed to return real fake-tessellable shapes). Confirmed over genuine HTTP: (1) the common single-solid case is fully regression-free - a plain Boss still gets an un-suffixed `body_id` exactly as before; (2) the actual validation bug found above is real and was really fixed - a `POST .../extrude-features` naming `{boss_id}#0` in `target_body_ids` (a composite id, base feature real) returns `201`, while one naming `does-not-exist#5` (composite, base feature absent) returns `400` with the full original string quoted in the error; (3) a target_body_ids entry that doesn't currently exist in the recomputed `bodies` dict (expected here, since this fake kernel can't organically produce real disjoint geometry) is still skipped gracefully, server stays healthy.
- **CI (real OCCT, both architectures) now confirms the actual splitting behaviour for real.** Pulled actual job logs, not just the `conclusion` field, via `mcp__github__get_job_logs`. amd64 (`backend-verify`, run 28660924294): `281 passed in 4.41s`. arm64 (same run, job 85001051565): `281 passed in 66.66s (0:01:06)` - identical total to amd64. All 6 new/renamed tests individually confirmed `PASSED` on both architectures: `test_extruding_two_disjoint_squares_produces_two_separate_single_solid_bodies`, `test_extruding_two_disjoint_squares_produces_two_separate_computed_meshes`, `test_multi_profile_sub_profile_with_a_hole_produces_two_separate_bodies`, `test_cut_that_severs_a_body_produces_two_separate_bodies`, `test_composite_body_id_from_a_split_can_be_targeted_by_a_later_cut`, `test_boss_naming_a_composite_id_whose_base_feature_does_not_exist_is_rejected`. This closes the "needs real OCCT" gap entirely - a real disjoint Cut/Boss genuinely produces N>1 real solids on both target architectures.

Not proceeding to A4 yet - CI (real OCCT) has now confirmed the splitting behaviour on both architectures, but still waiting on on-device confirmation that the original A3 bug fix plus this Body-identity amendment both look right together.
