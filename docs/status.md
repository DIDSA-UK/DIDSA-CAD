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

## 2026-07-03 — Client fix: Body selection filter made exclusive against vertex/edge/face

Client-only, `client/lib/viewport3d/part_screen.dart` and `part_toolbar.dart`. Raised by the user while discussing the View submenu's four selection-filter toggles (Prompt A2): with all four independently combinable, there is no click that lands "on the body" without also landing on one of its own faces/edges/vertices, and `hitTestBodies` (`selection_hit_test.dart`) always tries vertex, then edge, before ever considering body. So with the defaults (vertex/edge/face on, body off) plus a user simply also checking Bodies, a body pick could never actually happen wherever a vertex or edge was in range - precisely where people naturally click (corners, edges). Enabling Body was effectively a no-op unless the user also remembered to manually turn the other three off first.

**Fix**: Body is now exclusive, not additive. `PartScreen._setBodyFilter` (previously a plain `copyWith(body: value)`) now, on turning Body on, forces `vertex/edge/face` all to `false` in the same `setState`; turning Body back off restores all three to `true` (matching `SelectionFilterState.defaults`). `PartToolbar`'s three other filter rows now pass `onChanged: selectionFilter.body ? null : on...FilterChanged`, and `_filterToggle` gained an explicit `enabled: onChanged != null` on its `ListTile` - greys the row visually, not just disables the tap (a null `onTap` alone doesn't restyle a `ListTile`, `enabled: false` is what actually does).

No changes needed to `selection_hit_test.dart`/`hitTestBodies` itself - it was already fully filter-state-driven (`filter.vertex`/`filter.edge`/`filter.body` each independently gate whether that tier's hit-test even runs), so forcing the other three off at the state-management layer is sufficient on its own to guarantee every click within a body's silhouette now resolves to that body.

**Testing.** Same `flutter_scene`/`flutter_gpu` sandbox constraint as A2/A3 - `PartScreen`/`PartToolbar` can't be widget-tested here (documented in `docs/roadmap.md`'s "No Flutter CI job" item):
- `flutter analyze lib/viewport3d/part_screen.dart lib/viewport3d/part_toolbar.dart` - clean, zero issues.
- `selection_filter_test.dart` (pure `SelectionFilterState` logic, no `flutter_scene` dependency) - re-ran for real, still 6/6 passed; this change didn't touch `SelectionFilterState` itself.
- The actual exclusivity behaviour (`_setBodyFilter`'s new logic, the toolbar's greying) is only exercised inside `PartScreen`/`PartToolbar`, both of which transitively pull in `flutter_scene` and can't load under this sandbox's stable SDK - same untestable-here category as A2's View-submenu toggle check and A3's on-device items.

**On-device confirmation: done.** User confirmed toggling Bodies on/off behaves as designed.

## 2026-07-03 — Client: split Selection Filters out of the View sub-menu

Client-only, `client/lib/viewport3d/part_toolbar.dart`. Raised by the user directly after confirming the Body-exclusivity fix above: the four selection-filter toggles (Vertices/Edges/Faces/Bodies) lived inside the View `ExpansionTile` alongside unrelated display/appearance settings (Perspective, far clip, render mode, background/body colour). Moved them into a new third top-level `ExpansionTile`, "Selection Filters" (`_buildSelectionFilterMenu`, `Icons.filter_alt_outlined`), alongside File and View in `PartToolbar`'s menu column. Pure reorganisation - `SelectionFilterState`, `PartScreen`'s filter state/handlers, and `hitTestBodies`/`hitTestMeshEntities` are all untouched; only which `ExpansionTile` the four `_filterToggle` rows render under changed, including the Body-exclusivity behaviour from the entry above (still greys out Vertices/Edges/Faces exactly the same way, just under the new menu).

**Testing**: `flutter analyze lib/viewport3d/part_toolbar.dart` - clean, zero issues. No widget-level test exists for `PartToolbar`'s menu structure (same `flutter_scene` sandbox constraint as above) - the one `part_screen_test.dart` case that opens the View sub-menu only exercises the Perspective toggle, which stayed in View, so it's unaffected either way. Needs on-device confirmation that the new "Selection Filters" menu appears alongside File/View and the four toggles work identically there.

## 2026-07-03 — Prompt A4: client Boss/Cut target-body picking flow

Client-only, closes out the DAG/multi-body phase (A1-A4). Wires A2's filter override and A3's body selection into actually creating a Boss/Cut, per the A4 brief - until this, `target_body_ids` was fully built and tested on the backend (A1) but never sent by the client at all: every Boss silently always started a brand-new Body, and Cut always 400'd (`Cut requires at least one target_body_ids entry`) since there was no way to pick one.

**Design.** The picker is not a separate sub-flow with its own Confirm - it's woven into the Extrude panel's existing session. `_openExtrudePanel` now also stashes whatever was in `_selectedEntities` into a new `_entitiesBeforeExtrude` (mirroring `_meshBeforeExtrude`'s identical null-vs-empty "never captured yet" convention) and rebinds `_selectedEntities` itself to be the target-body picker's own selection for the panel's whole lifetime, pushing a bodies-only override onto `_selectionFilterOverrides` (A2) so every viewport tap during that time can only ever resolve to a `SelectionEntityKind.body` hit. This was a deliberate choice over a parallel `Set<String>` field: reusing `_selectedEntities` directly means `PartViewport`'s existing highlight rendering and `SelectionListDrawer`'s removable-entry list (already filtering out chamfer/fillet/create-plane actions for any body-kind selection, from A3's own `contextActionsFor` guard) work for target-body picks with zero new plumbing - the one adjustment needed was hiding `SelectionListDrawer` itself while the panel is open (`if (!_extrudeActive)`), since it's a bottom-docked `DraggableScrollableSheet` that would otherwise visually collide with `ExtrudePanel`'s own bottom-docked Confirm/Cancel row - a collision that could never happen before this prompt, since `_selectedEntities` and an open Extrude panel were previously mutually exclusive. `PartViewport.selectionMode` is forced `true` for the panel's duration regardless of the general Stage 23 toggle (irrelevant either way - the mode-toggle FAB is already hidden whenever the panel is open).

**Requirements, in order:**
1. *Enter picking mode*: `_openExtrudePanel` (above). A top-center pill banner (`_targetBodyPickerBannerText`, same `Material`/`Positioned` convention as the existing plane-selection-mode banner - judged the closer structural analog to the brief's "reuse the picker-banner conventions" than Prompt D's Sketch-picker banner, since A4's picking happens via viewport taps, not list rows like Prompt D's) names the mode and offers Cancel, wired to `_cancelExtrude` directly (there's no separate "picking-only" cancel - Cancel always cancels the whole pending Extrude, consistent with the rest of this flow).
2. *Multi-select accumulate*: free - `_toggleSelectedEntity`/`_clearSelectedEntities` already implement exactly this toggle semantics (Stage 23), now also rescheduling the debounced live-preview re-solve (`_scheduleExtrudePreview`, refactored out of `_onExtrudeValuesChanged` so both a field edit and a body pick funnel through the same debounce) whenever `_extrudeActive`, so picking a body updates the preview mesh the same way changing a distance does.
3. *Boss vs Cut rules*: `ExtrudePanel` gained a `required int targetBodyCount` prop (read live every build, unlike `initialType`/`initial*Distance` which only seed local state once) and a `_canConfirm` getter - Confirm is disabled whenever depth is invalid (pre-existing) *or* `type == cut && targetBodyCount == 0` (new), with an inline error/count line matching the existing depth-validation text's style.
4. *Cancel*: existing `_cancelExtrude`, now also restoring `_selectedEntities`/popping the filter override (see State cleanup).
5. *State cleanup*: both `_confirmExtrude` and `_cancelExtrude` now unconditionally (not gated on whether anything was actually picked) restore `_selectedEntities = _entitiesBeforeExtrude ?? {}`, null out `_entitiesBeforeExtrude`, and pop `_selectionFilterOverrides` - explicitly audited against the exact Prompt D addendum bug the brief calls out (`_selectedFeatureId` not clearing on both paths), and both paths now handle it identically. `target_body_ids` itself reaches the backend via `_currentTargetBodyIds()` (de-duplicated `_selectedEntities.map((e) => e.bodyId)`), threaded through `_ensureExtrudeFeatureExists`'s new fourth parameter into both `DocumentApiClient.createExtrudeFeature`/`updateExtrudeFeature` (new `targetBodyIds` params - create defaults `const []`, update stays nullable/omit-means-unchanged to preserve A1's None-vs-`[]` distinction for the PATCH schema). `FeatureDto` also now parses `target_body_ids` back (defaults `[]`) for round-trip completeness.

**Testing.** Two genuinely real, executable slices this time, not just `ast.parse`/`flutter analyze` - `extrude_panel.dart` and the relevant half of `document_api_client.dart` have zero `flutter_scene` dependency, unlike most client UI touched in this whole DAG/multi-body phase:
- New `test/extrude_panel_test.dart` (6 widget tests, real `flutter_test` pumps, no mocked network) - Boss with 0/N target bodies stays enabled; Cut with 0 is disabled, with 1+ enabled; switching the segmented button from Boss to Cut live-disables Confirm; an invalid depth disables Confirm regardless of target-body count. All 6 passed for real.
- New tests in `test/document_api_client_test.dart` (4 tests) - `createExtrudeFeature` defaults `target_body_ids` to `[]` and sends explicit picks verbatim (round-tripping through `FeatureDto.targetBodyIds`); `updateExtrudeFeature` omits the key entirely when not supplied vs. sending a real empty list when explicitly passed `const []` - the None-vs-`[]` distinction A1's backend actually depends on. All 4 passed for real.
- `flutter analyze lib test/extrude_panel_test.dart test/document_api_client_test.dart` - clean, zero new issues (3 pre-existing unrelated `avoid_print` infos in `part_viewport.dart`).
- Full pre-existing pure-Dart suites re-ran for real, no regressions: `document_api_client_test.dart` 11/11, `selection_filter_test.dart` 6/6, `override_stack_test.dart` 9/9.
- Everything actually requiring `PartScreen`/`PartViewport`/`PartToolbar` (the banner rendering, the viewport highlight-while-picking, `SelectionListDrawer` correctly hiding, the live-preview mesh actually reflecting a real Cut against a real picked Body) - same `flutter_scene`/`flutter_gpu` sandbox wall as every other prompt in this phase; `flutter test test/part_screen_test.dart` fails to even load, confirmed as the identical pre-existing `gpu.VertexLayout not found` compile error, not anything newly broken by this change.

**Needs on-device confirmation** (this is the actual gate, not a formality - A4's own stop condition is explicit that Prompt B does not start until this comes back): enter picking mode for a Boss and a Cut; the "Selection Filters" menu already being Body-only-forced during picking is expected (matches the exclusivity fix above) and should show as such; multi-select accumulate (pick two, remove one by tapping again); Cancel mid-pick restores whatever was selected before, if anything, and creates nothing; a Boss confirmed with zero picks still starts a fresh Body (pre-A4 behaviour, must not have regressed); a Cut with 1+ real Bodies picked actually subtracts from them via real OCCT (CI already proved the backend geometry is correct - this checks the client is actually sending the right ids for a real multi-body Part); the previous general selection (if any) reappears correctly once the panel closes either way.

This closes out the DAG/multi-body phase (A1-A4) pending that on-device pass. Not starting Prompt B (sub-shape refs, tree categories, cascade delete, earlier-feature editing) in this session, per A4's explicit stop condition.

## 2026-07-03 — Bug fix: A4's target-body picking banner overflowed and sat under the FAB

On-device testing of A4 (screenshot) found two real layout bugs in the new picking-mode banner, both in `part_screen.dart`:

- **Overflow**: the banner's `Row` had `mainAxisSize: MainAxisSize.min` with a plain (non-wrapping) `Text` inside an unconstrained `Center` - fine for the pre-existing plane-selection-mode banner's short fixed string, but A4's longer, count-dependent text (e.g. "Select bodies to merge into (optional)") overflowed past the screen edge (Flutter's yellow/black `RenderFlex` overflow stripe, "RIGHT OVERFLOWED BY 364"). Fixed by wrapping the `Text` in `Flexible` (so it wraps onto a second line instead) inside a `ConstrainedBox` capping the pill to `screen width - 32`. Also shortened the banner strings themselves (e.g. dropped the parenthetical "confirm with none selected to start a new body" explanation) to reduce how often wrapping is even needed.
- **Sitting under the FAB**: the top-left FAB column (hamburger + feature-tree toggle) is only suppressed during Feature-tree-visible and plane-selection modes (`if (!_featureTreeVisible && !_planeSelectionMode)`) - Prompt A4 never added itself to that condition, so the feature-tree FAB kept rendering at its usual `top: 8, left: 8` directly underneath/overlapping the new banner. The plane-selection-mode banner already avoids this exact collision by being in that condition; A4's banner just needed the same treatment. Fixed by adding `&& !_extrudeActive` to the condition.

**Testing**: `flutter analyze lib/viewport3d/part_screen.dart` - clean. Both are pure layout fixes with no state/logic change, so the existing `extrude_panel_test.dart`/`document_api_client_test.dart` coverage from the A4 entry above is unaffected and wasn't re-run for new cases - this needs the same on-device confirmation as the rest of A4, now covering the fixed layout too.

## 2026-07-03 — Prompt B1: backend body-scoped sub-shape references + `produces` tag

Backend-only. First of the new B1-B4 prompt sequence, unblocked by A1-A4's on-device confirmation. Two independent additions, no client changes.

**`SubShapeRef`** (`app/document/models.py`, zero OCCT imports, same as the rest of this file): frozen dataclass, `body_id: str` (required - a sub-shape reference without a body is ambiguous now that bodies are plural per A1/A3), `shape_type: SubShapeType` (new str-Enum, `EDGE`/`FACE`, mirrors `ExtrudeType`'s pattern), `index: int`. A pure value type, not a Feature - no consumer exists yet (Fillet's `edge_refs`, Create Plane's `face_ref` land in C/D/E), so this prompt builds and tests the type and its resolver in isolation, exactly as scoped. Frozen/hashable like `app.document.graph.GraphNode`, for the same "plain value type, not an owned entity" reason.

**`resolve_subshape(part, ref, hidden_feature_ids=frozenset())`** (`app/document/extrude.py`, new function, alongside `compute_part_bodies` which it calls directly): looks up `ref.body_id` in a *fresh* `compute_part_bodies(part, hidden_feature_ids)` call (not a cached shape), then re-walks `topexp.MapShapes(body, TopAbs_EDGE|TopAbs_FACE, ...)` - the same indexed-map pattern `app/document/mesh.py`'s `_extract_edges`/`_extract_topology_vertices` already use for faces/edges/vertices - and returns the sub-shape at `ref.index` (0-based; `TopTools_IndexedMapOfShape` itself is 1-based, so `index + 1` is passed to `FindKey`). Works against any body_id in the Part's history, not just the most recent, since `compute_part_bodies` already recomputes every Body regardless of how far upstream it sits - satisfying the prompt's explicit requirement on this point by construction, not by a special case.

**Structured `missing_reference` error**: `resolve_subshape` raises `fastapi.HTTPException(422, detail={"type": "missing_reference", "body_id", "shape_type", "index"})` directly (a new `_missing_reference` helper in `extrude.py`) whenever `ref.body_id` doesn't exist among the Part's current Bodies, or `ref.index` is out of range (including negative) for that Body's current sub-shape count. Fails closed, no silent fallback to a "closest" sub-shape, per the prompt's explicit instruction.

**Flagging one deliberate deviation from this codebase's existing layering**, the same way A1 flagged its own 400-vs-422 conflict: every other OCCT-touching module (`extrude.py`, `mesh.py`) has zero `fastapi` imports today - `HTTPException`-raising has so far lived exclusively in `router.py` (`_validate_target_body_ids`, `_validate_extrude_distances`), with `extrude.py` itself only ever logging-and-skipping on a bad reference, never raising. `resolve_subshape` breaks that split by raising `HTTPException` itself. Chose this over a plain domain exception (e.g. a `MissingReferenceError` that some future router endpoint would catch and translate) because: (a) there is no consumer endpoint yet to own that translation - C/D/E's future routes can just let `resolve_subshape`'s `HTTPException` propagate unchanged, the same way FastAPI already lets any raised `HTTPException` propagate from a route handler regardless of which module raised it; (b) the prompt's own instruction to "match whatever structured-error envelope A1 already established for `target_body_ids` validation" is most literally satisfied by reusing the exact same `HTTPException(status_code=..., detail=...)` call shape `_validate_target_body_ids` uses, just with a `dict` `detail` instead of a plain string (A1's own status doc already established "no custom error envelope" is this codebase's only convention - a `dict` `detail` is still that same envelope, not an invented wrapper type). Flagging this in case a stricter router-only-raises-HTTPException layering was actually intended.

**`produces` tag** (`app/document/models.py`): new `Produces` str-Enum (`BODY`/`PLANE`/`SURFACE`/`SKETCH`/`NONE`), a new `Feature.produces` property (default `NONE`, mirroring `produces_solid_geometry`'s existing default-then-override pattern). `SketchFeature.produces -> SKETCH`, `ExtrudeFeature.produces -> BODY` (both Boss and Cut). Added to `SketchFeatureResponse`/`ExtrudeFeatureResponse` (`schemas.py`) and populated in `router._feature_response`.

**Investigated rather than assumed**: is Sketch a Feature-graph node in its own right, or just an upstream reference from Extrude (the open question the prompt asked to record for B3)? Confirmed via `app.document.extrude.build_feature_graph`: it iterates `part.features` unconditionally and appends a `GraphNode` for *every* Feature, including `SketchFeature` (with `depends_on=()`, since a Sketch depends on nothing) - so a `SketchFeature` genuinely is its own node in the dependency graph `topological_order` walks, not merely something an `ExtrudeFeature`'s edge points at. This is why `SketchFeature.produces` is `SKETCH` rather than `NONE` - **B3 should group `produces: "sketch"` into its own section (or leave it in the plain sequential list, per B3's own wording "match whatever B1's status doc recorded"), not fold it silently into `body`.**

**Testing.** Same real-OCCT-required constraint as every prior backend prompt in this project (A1/A3's own entries above) - `import OCC` fails, no conda/micromamba, and `docker build` against `backend/Dockerfile` failed this session too (`docker info` reports no daemon reachable at `/var/run/docker.sock`, same class of failure as A1's original attempt, not the policy-denial class A1's later curl-pass entry hit):

- **Genuinely executed, zero OCCT dependency**: new `tests/test_stage_b1_model.py` (6 tests, imports only `app.document.models` - the one file this prompt touches that has no OCCT import) - `Produces`/`SubShapeType` enum membership, `SketchFeature`/`ExtrudeFeature.produces` values, `SubShapeRef` value-type equality/hashing/field round-trip. **6/6 passed for real.** Re-ran `test_stage_a1_graph.py` (13/13, unaffected) to confirm no regression on the only other OCCT-free test file.
- **`ast.parse`-verified plus manual line-by-line review, not executed** (needs real `pythonocc-core`): every changed/added OCCT-touching file (`extrude.py`, `mesh.py` unchanged, `schemas.py`, `router.py`) and the new `tests/test_stage_b1_subshape.py` (11 tests: `resolve_subshape` success for both a face and an edge of a plain 10x10x10 Boss box, verified against an independently-recomputed ground truth via `BRepGProp.SurfaceProperties`/`LinearProperties` rather than object identity - `compute_part_bodies` rebuilds fresh OCCT shapes on every call, so two independent recomputes never share object identity even when geometrically identical; `missing_reference` for an unknown `body_id`, a hidden body, an out-of-range face index, an out-of-range edge index, and a negative index; `produces` over the live API for Sketch/Boss/Cut and across `GET .../features`). Every new OCCT API call this file introduces beyond what's already proven working elsewhere in this codebase (`topexp.MapShapes`, `TopTools_IndexedMapOfShape`, `.Size()`/`.FindKey()` - all already exercised for real by `mesh.py`'s `_extract_edges`/`_extract_topology_vertices`) is limited to `BRepGProp.SurfaceProperties`/`LinearProperties` + `GProp_GProps` in the test file only (not production code) - the standard, long-stable OCCT area/length idiom, used here only to build the tests' own ground truth.
- **Deliberately did not attempt a genuine "topology shrinks" fixture** (e.g. a boolean op that reduces a Body's face count) for the out-of-range-index failure test, unlike the prompt's own suggested scenario - engineering a real `BRepAlgoAPI_Fuse`/`Cut` result with a *smaller* face count than its inputs is not something I could verify with confidence without a live OCCT environment (unlike a plain box's exact 6-faces/12-edges, which is a first-principles certainty this whole project's prior test suites already rely on). Used a plain out-of-range index against an unchanged box instead (index 6/12 against a 6-face/12-edge box) - this exercises the exact same `resolve_subshape` branch (`ref.index` outside the body's *current* sub-shape count), just reached via a simpler, fully deterministic setup rather than a fragile boolean-geometry assumption. Flagging this simplification explicitly rather than shipping an assertion I can't actually verify here.
- CI (`.github/workflows/backend-verify.yml`) will run on push, real OCCT, both architectures - same as every prior backend prompt. This is the actual proof for everything above the "genuinely executed" bullet, per this prompt's own testing section.

Not proceeding to B2 in this session, per B1's explicit stop condition: waiting for CI confirmation (job logs, not just the `conclusion` field, both `linux/amd64` and `linux/arm64`) before starting B2's cascade-delete work.

## 2026-07-03 — B1 CI follow-up: first push failed, real bug in the test file itself

First push (`885a3aa`) came back **red** on `linux/amd64` - pulled the actual job logs (`mcp__github__get_job_logs`), not just the `conclusion` field: `296 passed, 2 failed`. `linux/arm64` was cancelled as a consequence of `amd64`'s failure (GitHub's default `fail-fast` behaviour on a matrix job), so it never got a chance to run either.

**Root cause**: exactly the two new "success path" tests in `test_stage_b1_subshape.py` (`test_resolve_subshape_face/edge_matches_..._captured_at_creation`) - both used `from OCC.Core.BRepGProp import BRepGProp`, which doesn't exist in this pythonocc-core version: `ImportError: cannot import name 'BRepGProp' from 'OCC.Core.BRepGProp'`. All 296 other tests passed, including every other new B1 test (all 9 remaining `test_stage_b1_subshape.py` cases - `missing_reference` for an unknown/hidden body, out-of-range face/edge/negative index, and every `produces`-over-the-API case - plus all 6 `test_stage_b1_model.py` cases) and the full pre-existing suite. This was a bug in this prompt's own test code, not in `resolve_subshape`/`produces` themselves - `ast.parse` (what I could actually run in-sandbox) only catches syntax errors, not a wrong import name, which is exactly the gap real CI exists to close.

**Fix**: rather than guess a second time at `BRepGProp`'s real call surface in this version (likely a lowercase `brepgprop` singleton, mirroring `topexp`'s already-proven pattern - but unverified), rewrote both tests to compare sorted, rounded topology-vertex coordinates (`BRep_Tool.Pnt` + `topods.Vertex` + `topexp.MapShapes`/`TopTools_IndexedMapOfShape`) between the "ground truth" and `resolve_subshape`'s result instead of `GProp` area/mass - every one of those APIs is already proven working in this exact CI run (`app.document.mesh._extract_topology_vertices` uses the identical pattern, and my own `test_resolve_subshape_body_and_solid_counts_are_the_documented_box_shape` already passed using `topexp.MapShapes` for faces/edges). This closes the gap without re-risking a second unverified OCCT API call. Pushed as `cb276f1`.

**Re-run confirmed green on both architectures** (job logs pulled directly via `mcp__github__get_job_logs`, not just the `conclusion` field, run `28678513650`): `linux/amd64` - **298 passed in 4.88s**; `linux/arm64` - **298 passed in 58.95s** (slower under QEMU emulation, identical pass count, expected and consistent with every prior arm64 run in this project). Every individual B1 test (`test_stage_b1_model.py`'s 6, `test_stage_b1_subshape.py`'s 11, including both fixed success-path cases) is confirmed `PASSED` by name in both architectures' logs, not just the aggregate count.

**Answering the checklist directly, item by item:**
1. SubShapeRef resolves correctly when upstream topology is unchanged - **PASS** (after the fix above; failed on the first CI attempt due to a test-code bug, not a `resolve_subshape` bug).
2. SubShapeRef resolution fails when the target body's face/edge count shrinks upstream - **PASS, with a caveat**: covered via an out-of-range index against an unchanged box rather than a genuine shrinking-boolean-op fixture - same validation branch, simpler/more reliable setup (reasoning above).
3. SubShapeRef resolution fails when the target body is deleted/hidden entirely - **PASS**.
4. `produces` field present on Feature list/detail responses - **PASS**.
5. Sketch `produces` value matches what the status doc records - **PASS** (`sketch`, since Sketch is confirmed a real graph node).
6. CI green on both architectures (real OCCT) - **PASS** (298/298 both architectures, confirmed above).
7. `missing_reference` error shape confirmed over live HTTP (curl/Swagger) - **NOT DONE, deferred by design**: no consumer endpoint exists yet that would let a client trigger `resolve_subshape` over real HTTP (Fillet/Chamfer/Create Plane are C/D/E) - unit-tested directly against the Python function instead. This is the one checklist row B1 cannot close on its own.

B1's stop condition (CI confirmation on both architectures) is now satisfied. Ready to start B2 when asked.

## 2026-07-03 — Prompt B2: backend graph-aware cascade delete

Backend-only. Replaces `/parts/{id}/features/{id}/cascade`'s cascade-delete behaviour, which turned out to still be exactly the pre-A1 "delete this Feature and everything after it in the list" heuristic - A1 introduced real dependency-graph edges (`target_body_ids` can reach back past the immediately preceding Feature) but nothing had updated cascade delete to actually walk them, so it was silently wrong for any Part where list order and dependency order diverge. Confirmed this by reading `models.py` before writing any code, per this prompt's own instruction - the bug was real and already shipped, not hypothetical.

**Real graph walk** (`app.document.graph.transitive_dependents`, new): given the same `GraphNode`/`depends_on` edges `topological_order` already walks forward, builds the reverse (`dependents`) adjacency and does a worklist traversal from the deleted Feature's id, returning it plus every id that transitively depends on it. A Feature with no dependents deletes alone; a Sketch feeding two independent Extrudes takes both down if the Sketch itself is deleted, but deleting one Extrude alone never touches the Sketch or its sibling.

**Moved `build_feature_graph`/`base_feature_id` from `app.document.extrude` into `app.document.graph`.** Neither function touches any OCCT API - they only read `Feature` dataclass fields (`sketch_feature_id`, `target_body_ids`, `isinstance` checks) - but they previously lived in `extrude.py`, which imports OCCT at module level for unrelated geometry-construction reasons, so importing them at all required a real `pythonocc-core` environment. Moving them into `graph.py` (already OCCT-free, already the home of `topological_order`) means the actual graph-building logic behind B2's headline requirement - "walks the same dependency-graph edges recompute already walks" - is now genuinely unit-testable in this sandbox, not just `ast.parse`-reviewable. `extrude.py`/`router.py` updated to import both from their new home; no behaviour change to either function, confirmed by re-running the untouched A1 pure-graph suite (`test_stage_a1_graph.py`, 13/13) after the move.

**`Part.delete_feature_cascade(feature_id)` → `Part.delete_features(feature_ids: set[str])`** (`models.py`): the Part-level method is now deliberately graph-*agnostic* - it just partitions `self.features` by membership in a given id set (returning the deleted Features, in original order, and keeping the rest in original order) - all graph-closure computation happens one layer up, in the router, via `transitive_dependents(build_feature_graph(part), feature_id)`. This keeps the "which ids does this delete touch" question and the "how are Features actually removed from the list" mechanic cleanly separated, and keeps `Part` itself simple enough to still unit-test with plain id sets rather than needing graph fixtures at that layer too.

**Response/recompute**: `CascadeDeleteResponse` schema unchanged (`deleted_feature_ids`, `deleted_sketch_ids`) - only what determines membership changed, not the response shape. Recompute needs no new code at all: since `part.delete_features` genuinely removes the Feature objects from `part.features`, any subsequent `GET /mesh` call's own `build_feature_graph`/`compute_part_bodies` simply never sees the deleted Features or their edges again - "no dangling references from Features that no longer exist" falls out for free from the deletion being real, the same way A3's status doc noted a similar for-free behaviour for `hidden_feature_ids`.

**No confirm dialog / undo**: both explicitly out of scope for this backend-only prompt (per B2's own text) - undo already lives entirely in the client's existing command/inverse-action stack (Flutter), which restores prior state from what it captured before the API call; a cascade delete is already exactly one API call, so it's already exactly one push onto that stack with no backend involvement needed for the "atomic single undo" property. Nothing to build or verify here beyond confirming (above) that the response accurately reflects everything that was actually deleted, which is what the client's restore step would need.

**Existing tests updated for correct behaviour, not just re-passed as-is**: `test_stage7_document.py`'s three pure `Part`-level cascade tests and two API-level tests assumed the *old*, list-position behaviour using three mutually-independent `SketchFeature`s (no real dependency edges between them at all) - under true graph semantics, deleting the first of three unrelated Sketches must now delete only itself, not the other two. Rewrote these to assert the corrected behaviour explicitly (`test_cascade_delete_of_an_independent_earlier_feature_deletes_only_itself_over_the_api`, and `test_cascade_delete_of_a_locked_feature_is_allowed_unlike_single_delete`'s assertion that the untouched sibling survives) rather than silently leaving a test that encoded the very bug this prompt fixes.

**Testing.**
- **Genuinely executed, zero OCCT dependency** (new `tests/test_stage_b2_graph.py`, 14 tests): `transitive_dependents` directly against raw `GraphNode` fixtures (leaf/no-dependents, shared-root fan-out, multi-step chains, a diamond dependency deleted from the root vs. from one side, unrelated branches, an unknown id) *and* end-to-end against `build_feature_graph` over real `SketchFeature`/`ExtrudeFeature` dataclasses (shared-sketch-two-extrudes, sibling-extrude-off-a-shared-sketch, a leaf Cut, a `target_body_ids`-chain cascade, three independent Sketches not cascading into each other) - **14/14 passed for real**, this sandbox's strongest verification yet for a B-prompt's core logic. Re-ran `test_stage_a1_graph.py` (13/13) and `test_stage_b1_model.py` (6/6) - no regressions from the `graph.py` move.
- Manually verified `Part.delete_features`'s partition logic with a standalone pure-Python snippet (not part of the committed suite, since `test_stage7_document.py`'s own coverage of it needs `app.main`/OCCT to even import - see below) - confirms non-contiguous id-set deletion preserves both deleted-order and survivor-order correctly.
- **`ast.parse`-verified plus manual review, not executed** (needs real `pythonocc-core`, same constraint as every OCCT-touching file in this project): `router.py`'s endpoint wiring, `models.py`'s `delete_features`, the updated `test_stage7_document.py` cases, and new `tests/test_stage_b2_cascade.py` (5 tests: shared-sketch cascade, sibling-extrude survival, leaf delete, a `target_body_ids`-chain cascade, and two fully-independent Boss branches not touching each other - each asserting both the `/cascade` response shape *and* a subsequent `GET /mesh` recomputes cleanly with exactly the surviving bodies).
- CI (`.github/workflows/backend-verify.yml`) will run on push, real OCCT, both architectures - the actual proof for the OCCT-touching half, per every prior backend prompt's own standard.

Not proceeding to B3 in this session, per B2's explicit stop condition: waiting for CI confirmation (actual job logs, both `linux/amd64` and `linux/arm64`) before starting B3's client work.

## 2026-07-03 — B2 CI follow-up: one test bug, real logic unaffected

First push (`f0a4a56`) came back **red** on `linux/amd64` (`linux/arm64` cancelled as a fail-fast consequence, same pattern as B1's first attempt) - pulled the actual job logs: **316 passed, 1 failed**. Every graph-walk test (`test_stage_b2_graph.py`'s 14, fully pure-Python) and 4 of `test_stage_b2_cascade.py`'s 5 OCCT-touching tests passed; only `test_deleting_an_upstream_boss_cascades_through_a_target_body_ids_chain` failed.

**Root cause**: my own test asserted `GET /mesh` returns `[]` after cascade-deleting every `ExtrudeFeature` in the Part (only three bare `SketchFeature`s survive) - wrong. Per `Part.produces_solid_geometry` (`any(f.produces_solid_geometry for f in self.features)`), a Part with **no** `ExtrudeFeature` at all falls back to the placeholder box (one entry, `source: "placeholder"`) - `[]` is reserved for the different case of "`ExtrudeFeature`(s) exist but every one is currently skipped/hidden" (see A1's own status doc entry on this exact distinction). The very next test up in the same file (`test_deleting_a_sketch_feeding_two_independent_extrudes_removes_both`) already asserted the placeholder case correctly - this one test just didn't follow its own file's established pattern. Not a `resolve_subshape`/`transitive_dependents`/`delete_features`/router bug - the cascade-delete logic itself was already correct (`deleted_feature_ids` and the surviving Feature set both asserted correctly and passed).

**Fix**: corrected the assertion to expect the single placeholder entry, matching the sibling test above it. Pushed as `391e782`.

**Re-run confirmed green on both architectures** (job logs pulled directly via `mcp__github__get_job_logs`, not just the `conclusion` field, run `28679549795`): `linux/amd64` - **317 passed in 4.87s**; `linux/arm64` - **317 passed in 70.51s** (slower under QEMU emulation, identical pass count). Every individual B2 test (`test_stage_b2_graph.py`'s 14, `test_stage_b2_cascade.py`'s 5 including the fixed one, and `test_stage7_document.py`'s updated cases) is confirmed `PASSED` by name in both architectures' logs.

Answering directly: not every B2 test passed on the first CI attempt - 1 of 317 failed, due to an assertion bug in this prompt's own test code (a wrong expectation about the placeholder-mesh fallback, not a cascade-delete defect). Now fixed and confirmed green on both architectures.

B2's stop condition (CI confirmation on both architectures) is now satisfied. Ready to start B3 (client feature-tree categorization) when asked.

## 2026-07-03 — Prompt B3: client feature-tree categorization (Bodies/Planes/Surfaces)

Client-only, no backend changes. Groups `FeatureTreePanel`'s rows by B1's `produces` tag into Bodies/Planes/Surfaces sections, plus the pre-existing sequential list for everything else (Sketch/none), rather than one flat list.

**Bootstrapped Flutter for real this session** (this project's recurring sandbox caveat) - same version and same technique prior client-side prompts (A2-A4) used: 3.44.4 stable, downloaded directly from `storage.googleapis.com`'s release manifest, SHA256-verified against the manifest before extracting. This let every claim below be genuinely executed, not just `ast.parse`-equivalent review.

**`FeatureDto.produces`** (`document_api_client.dart`): new `String` field (`'body'`/`'plane'`/`'surface'`/`'sketch'`/`'none'`), parsed from the backend's `produces` key with a `'none'` default for any older fixture/fake that omits it - same defaulting convention `targetBodyIds`/`edges`/`faceIds` already established on this DTO.

**`groupFeaturesByProduces`** (`viewport3d/feature_tree_grouping.dart`, new, zero Flutter/`flutter_scene` dependency): a pure function, `List<FeatureDto> -> GroupedFeatures {bodies, planes, surfaces, other}` - a stable partition (each group keeps its own subset's original creation/graph order; nothing is ever re-sorted), matching this prompt's explicit "display grouping only" requirement. `'sketch'`/`'none'`/anything unrecognized all land in `other` - confirmed via B1's own status doc that a SketchFeature really is its own dependency-graph node (not merely an upstream reference from Extrude), so it belongs in the plain sequential list rather than being folded into `bodies`.

**`FeatureTreePanel`** (`viewport3d/feature_tree_panel.dart`): the single flat `ListView.builder` became `_buildGroupedTree`, which renders a `_buildGroupSection` (an `ExpansionTile`, `initiallyExpanded: true`) for each of `bodies`/`planes`/`surfaces` **only when non-empty** (an empty group is omitted entirely, not shown as an empty/error section, per this prompt's explicit requirement), followed by the `other` list's rows unchanged. **Investigated first rather than assumed** (per this prompt's own instruction to check the actual codebase): the tree itself never used `ExpansionTile` before this - that convention lives in `PartToolbar`'s File/View/Selection-Filters menus (confirmed via `grep`, mirrored above as the closest established "expansion widget convention" this prompt's own wording pointed at, since there wasn't one already inside the tree itself). Individual row rendering (`_buildFeatureTile` - icon/lock state/hidden-eye/picker-dimming/tap/long-press) is untouched, just factored out of the old inline `itemBuilder` so a grouped section and the `other` list share the identical tile; `featureDisplayName`'s per-type ordinal numbering ("Extrude 2") is still computed against the full, ungrouped `features` list and the Feature's real index in it (via `indexWhere`), so which display group a Feature lands in never changes what it's called - this is a display grouping only, exactly as required, and doesn't touch `part_screen.dart`'s data flow into the panel at all.

**Multi-body awareness** (requirement 2): needed **no new code at all** - `groupFeaturesByProduces` (and the tree generally) operates over `Feature`s, never `Body`s, so a single `ExtrudeFeature` that happens to produce multiple Bodies server-side (A1/A3's disjoint-solid splitting) was already exactly one tree node before this prompt and stays exactly one after it; there is no per-Body fan-out anywhere in this code for B3 to have introduced. Confirmed with a dedicated test (`feature_tree_panel_test.dart`'s "still render as exactly one row each under Bodies, not duplicated").

**Testing.**
- **New `test/feature_tree_grouping_test.dart`** (7 tests, zero `flutter_scene` dependency) - empty input, body/plane/surface partitioning, sketch+none both landing in `other`, an unrecognized `produces` value falling back to `other` rather than being dropped, stable-partition ordering, and a realistic mixed Part. **7/7 passed for real.**
- **New `test/feature_tree_panel_test.dart`** (5 real `flutter_test` widget-pump tests) - discovered `FeatureTreePanel` itself has **no transitive `flutter_scene` dependency** (unlike `PartScreen`/`PartToolbar`/`PartViewport`, which every prior client prompt in this project found blocked by the `flutter_gpu` stable-channel mismatch), so this prompt's actual rendering could be genuinely widget-tested rather than only reviewed: a "Bodies" header appears with Boss/Cut Features present; empty Planes/Surfaces groups render as nothing (no header, no gap); a Sketch-only Part shows zero group headers; tapping a grouped row still invokes `onFeatureTap`; multiple Extrude Features render as exactly one row each. **5/5 passed for real** - stronger, first-time verification for this specific widget than any prior B/A-prompt achieved for anything tree-adjacent.
- `flutter analyze lib test` - **zero new issues**: the same 5 pre-existing findings every prior client prompt's entry has documented (3 `avoid_print` infos in `part_viewport.dart`, 2 `selection_list_drawer_test.dart` `const Set`/custom-equality errors) - none in any file this prompt touched.
- Full suite: **196 passed** (191 pre-existing + this prompt's 12 new, all genuinely executed), **17 failed-to-load** - identical count and file set to A2/A3/A4's own entries (the `flutter_gpu`/`flutter_scene` stable-channel mismatch, unrelated to and unchanged by this prompt).
- **Not verified here, needs on-device confirmation** (this prompt's actual stop-condition gate, same as every prior client prompt): the "Bodies" section actually appearing correctly in the real running app alongside the real `PartScreen`/`PartToolbar`/3D viewport (which do have the `flutter_scene` dependency and can't be exercised in this sandbox), expand/collapse interaction feeling right on a real device, and overall tree scroll/visual polish.

Not starting B4 (earlier-feature in-place editing) in this session, per B3's explicit stop condition: waiting for on-device confirmation before starting B4's client work, which builds on this tree.

## 2026-07-03 — B3 revision: "Build Tree" with real Body nodes (on-device feedback)

On-device testing of B3 (two screenshots) surfaced a real design reversal, confirmed directly with the user rather than assumed: an Extrude that splits into multiple Bodies (A1's multi-solid amendment) was showing as a single "Extrude 1" tree row - correct per B3's own text ("don't fabricate multiple tree nodes for a single Feature that happens to produce several bodies"), but wrong per the user's actual intent once they saw it. The same screenshots also caught a genuine pre-existing bug: `SelectionListDrawer`'s two rows for that split Body's halves both read "Body 8adb4187" - the "first 8 characters" truncation (A3) only ever reaches the shared base id, never the distinguishing `#0`/`#1` split suffix.

**Confirmed design, via direct questions rather than guessing** (mirroring A3's own precedent of asking the user directly on an architecturally significant fork):
1. The panel is retitled "Build Tree". It now has two top-level, independently collapsible sections in this order: **Bodies** (real produced Body objects, not Feature rows) and **Features** (the full, unfiltered Sketch/Extrude/etc. list, unchanged in content/order from before this revision). A split Extrude now genuinely produces multiple Body rows; the Extrude Feature itself still also appears, once, under Features - both are shown, not one replacing the other.
2. Tapping a Body row selects/highlights it - reuses the exact same `_toggleSelectedEntity`/`SelectionEntityRef(kind: body)` path a viewport tap on that Body already uses, so the two input paths stay fully interchangeable and both drive `SelectionListDrawer` identically.
3. Body naming ("Body 1", "Body 2", ...) is shared everywhere a Body is named - the tree and `SelectionListDrawer` both call the same `bodyDisplayNames`, closing the duplicate-name bug as a side effect of the same change.
4. Planes/Surfaces get their own top-level sections at the same tier as Bodies once C/D/E give them something to list - no such data source exists yet, so nothing was built for them this round (an empty section that can never currently be non-empty would be speculative code, not a real feature).
5. **B4 amendment, confirmed for when B4 starts**: earlier-feature editing will use **true SolidWorks-style rollback** - tapping any earlier Feature (Sketch or Extrude, not just a Sketch with dependents) rolls the viewport back to suppress everything after it, edits happen against that rolled-back state, and Confirm rolls forward + recomputes. This reverses B4's own prompt text ("No rollback-to-here... v1 is in-place edit only... chosen over SolidWorks-style rollback for v1") - flagging this explicitly since it's a direct contradiction of already-written scope, not a clarification of it. Not implemented in this entry - B3 was the deliverable here, and this is recorded so B4 starts from the corrected premise rather than the original text.

**`groupFeaturesByProduces`/`feature_tree_grouping.dart`/its test file (this session's own earlier B3 pass) removed entirely** - the "group Feature rows by produces" model is superseded by "Bodies are real objects, Features are a separate flat list," so the function had no remaining caller. `FeatureDto.produces` itself is left in place (still an accurate mirror of the backend schema, cheap to keep, and every earlier-Feature-editing path added in B4 may still want it) but is no longer consumed by anything client-side today - flagging this rather than silently leaving a now-pointless function around.

**New `body_naming.dart`** (`bodyDisplayNames(features, bodyIds) -> Map<bodyId, displayName>`, zero Flutter dependency): orders Bodies by the creation-order index of the Feature that produced them, then by `#N` split index for a Feature that produced more than one - mirrors backend `base_feature_id`'s suffix-stripping, client-side. A `LinkedHashMap` literal preserves this order, which both call sites (`FeatureTreePanel`'s Bodies section, `SelectionListDrawer`) rely on directly rather than re-deriving/re-sorting it a second time from the display-name *strings* (which would sort "Body 10" before "Body 2").

**`FeatureTreePanel`**: Bodies section omitted entirely when there are no computed Bodies (a placeholder-only Part, or one with no ExtrudeFeature yet) - the dev-time placeholder box (`source: "placeholder"`) is explicitly filtered out client-side (`PartScreen._computedBodyIds`) before it can ever reach either naming map, since it isn't a real Body. Features section is unconditional (an empty `ExpansionTile` is a sane state for a brand-new Part, not an error one).

**`SelectionListDrawer`**: gained an optional `bodyNames` map (defaults to `{}`, falling back to the old truncation only if a bodyId isn't covered - defensive only, every real call site now always supplies the full map from `PartScreen`).

**Testing.**
- **New `test/body_naming_test.dart`** (6 tests, zero Flutter dependency) - empty input, creation-order-not-string-order numbering, split-index ordering within one Feature, an unsplit id sorting before a later Feature's split siblings, the exact on-device duplicate-name scenario from the screenshots (two split Bodies now get distinct names), and a defensive no-matching-Feature case. **6/6 passed for real.**
- **Rewrote `test/feature_tree_panel_test.dart`** (7 tests, real widget pumps) for the new structure: "Build Tree" title, Bodies section hidden when empty, a single-Body Extrude's one row, **a single Extrude that split into two Bodies rendering two distinct rows** (the exact regression this revision fixes), tapping a Body row invoking `onBodyTap` with the right id, a Feature-row tap still calling `onFeatureTap` (not `onBodyTap`), and a Sketch-only Part showing Features with no Bodies section. **7/7 passed for real.**
- Deleted `test/feature_tree_grouping_test.dart` (7 tests) alongside the function it tested.
- `flutter analyze lib test` - **zero new issues**, same 5 pre-existing findings as every prior entry.
- Full suite: **197 passed** (net +1 vs. the original B3 entry's 196 - removed 7, added 6 + 2), **17 failed-to-load**, identical file set - unaffected by this revision.
- **Not verified here, still needs on-device confirmation**: the new "Build Tree" title/two-section layout, a real split-Body Extrude actually showing two tappable Body rows with correct names, and that `SelectionListDrawer` no longer shows duplicate "Body 8adb4187"-style rows for a real split Body.

Still not starting B4 in this session - waiting for on-device confirmation of this revision, and B4 itself now needs the true-rollback design above rather than its originally-written in-place-edit scope.

## 2026-07-03 — Prompt B4: earlier-feature editing, true SolidWorks-style rollback

User confirmed the B3-revision entry above ("ok, looking good") and asked to move to B4. Implements the confirmed amendment from that entry, not B4's original prompt text - true rollback (viewport suppresses everything after the tapped Feature) rather than "in-place edit, no rollback".

**Real backend gap found and closed - B4 could not have been Client-only.** Investigated before writing any client code, per every prompt's own instruction to read the codebase first: the pre-B4 "only the last Feature is editable" lock was actively enforced server-side in two places `PATCH .../extrude-features/{id}` (`app.document.router.update_extrude_feature`) and every Sketch-entity mutation endpoint (`app.sketch.router`'s dozen call sites of `_ensure_sketch_editable`, itself checking `app.document.store.is_sketch_locked`). Neither check exists purely as client-side UX - both reject the request with a real 400 today (confirmed by the pre-existing, now-updated tests `test_patch_on_a_locked_extrude_feature_is_rejected`/`test_mutating_a_sketch_behind_a_locked_feature_is_rejected_over_the_api`). Tapping an earlier Feature client-side would have hit a 400 on the very first PATCH/mutation regardless of any rollback UI built on top. Removed both checks - `update_extrude_feature`'s inline lock check, and `_ensure_sketch_editable` (function + all 12 call sites) entirely. `Part.is_locked`/`is_sketch_locked` themselves are untouched and still back the `locked` response field and single-`DELETE`'s gating (cascade-delete remains the only way to remove a non-last Feature) - only *editing* stopped requiring "last Feature", exactly matching B4's own scope.

**Rollback is list-position-based, not dependency-graph-based - a deliberate choice, not a shortcut.** B2 made cascade-*delete* graph-aware specifically because over-deleting an unrelated sibling is a real correctness bug. Rollback is different by nature: real SolidWorks rollback is a literal timeline-position concept (drag the rollback bar to a point in the tree; everything after that point suppresses, related or not) - "tapping any earlier Feature... suppresses everything after it," per the user's own confirmed wording, is exactly this. `featureIdsAfter` (new, `rollback.dart`, zero Flutter dependency) returns every Feature id positioned after the tapped one in `_features`' own list order - deliberately not B2's `transitive_dependents`.

**Client rollback mechanism reuses A1's existing `hidden_feature_ids`, not a new concept**: `_beginRollback`/`_endRollback` (`part_screen.dart`) merge `featureIdsAfter`'s result into `_hiddenFeatureIds` (stashing the pre-rollback set first, exactly as `_meshBeforeExtrude`/`_entitiesBeforeExtrude` already stash-and-restore for the "create new Extrude" flow) and refresh the mesh - a Feature named there is already excluded entirely from backend recompute (not just hidden visually), so this is a real rollback, not a rendering trick. Restored exactly on exit, discarding only the rollback-only additions (a real manual Hide/Show made *during* the edit is also discarded, matching this file's existing "restore to before this flow started" convention for its own stashes).

**Tapping any Feature now opens something, regardless of lock state** (`_onFeatureTap`, now `async`): a Sketch still opens the 2D canvas (`_openSketchWithAnimation`, no longer gated on `!feature.locked`) with rollback wrapped around the whole `Navigator.push` round trip; an Extrude reopens `ExtrudePanel` via new `_openExtrudePanelForEdit`, prefilled from the Feature's own current stored `extrudeType`/`startDistance`/`endDistance`/`targetBodyIds` (the last mapped into `_selectedEntities` so the target-body picker shows what's already picked, not empty) - pre-B4, tapping an Extrude Feature did nothing at all beyond selecting it; this capability didn't exist to extend, it had to be built. `_previewExtrudeFeatureId` is set to the real Feature's own id upfront, which is what makes every `_ensureExtrudeFeatureExists` call (live-preview debounce included) PATCH it directly - Confirm "PATCHes the existing feature, never creates a new one" by construction, not a special-cased branch.

**Confirm/Cancel state-cleanup, extended for edit sessions** (`_confirmExtrude`/`_cancelExtrude`), explicitly audited against the `_selectedFeatureId`-class bug A4's own status doc flagged, per this prompt's instruction:
- Confirm: skips the "auto-hide the just-consumed Sketch" behavior when editing (`_editingExtrudeFeatureId != null`) - that only makes sense the *first* time a Sketch is consumed by a brand-new Extrude, not on every re-edit of an already-existing one. Rolls forward (`_endRollback`) after the panel's own state is torn down.
- Cancel: **must never delete** the Feature being edited (unlike the create-new flow, where Cancel deletes the just-created preview Feature) - instead PATCHes `_extrudeEditSnapshot`'s stashed original values back, undoing whatever the live-preview debounce already wrote server-side, then rolls forward. "No changes" for an edit session means the Feature ends up exactly as it was, not merely "not deleted."
- Both paths unconditionally clear `_editingExtrudeFeatureId`/`_extrudeEditSnapshot` and call `_endRollback()` (a safe no-op when rollback was never engaged, e.g. editing the actual last Feature) - the same unconditional-regardless-of-what-happened discipline A4's `_confirmExtrude`/`_cancelExtrude` already established for `_selectedEntities`.

**`_openSketch` gained a `_refreshMesh()` call after returning** - pre-B4, a Sketch could only ever be opened here while still the last Feature (nothing downstream yet to recompute), so this was never needed. Editing an *earlier* Sketch with a downstream Extrude (this prompt's own new capability) makes it reachable for the first time: the consuming Extrude needs to recompute against whatever changed.

**`ExtrudePanel`** gained an optional `title` prop (`'Extrude'` default, `'Edit Extrude'` when editing) - purely a label, no behavior change.

**Testing.**
- **New `test/rollback_test.dart`** (6 tests, zero Flutter dependency) - `featureIdsAfter` against a chain, the last Feature (empty), the first Feature, an unknown id, a single-Feature Part, and an empty Part. **6/6 passed for real.**
- **New `extrude_panel_test.dart` cases** (2 tests) - default title, and the edit-mode title. **2/2 passed for real** (this file has zero `flutter_scene` dependency, same as every prior A4/B3 addition to it).
- **New backend `tests/test_stage_b4_earlier_feature_editing.py`** (3 tests, needs real OCCT, `ast.parse`-verified/manually reviewed only in this sandbox): PATCHing an earlier Boss with a downstream Cut targeting it actually recomputes the Cut against the new depth (not a stale cached shape); PATCHing an earlier Extrude's `target_body_ids` is accepted and takes effect; mutating a Sketch behind a locked Extrude is accepted and the consuming Extrude recomputes against the new profile.
- **Updated two existing backend tests** that asserted the *old* rejected behavior (`test_patch_on_a_locked_extrude_feature_is_now_allowed`, `test_mutating_a_sketch_behind_a_locked_feature_is_allowed_over_the_api`) - left as-is they'd have encoded the exact restriction this prompt removes, the same category of stale-test risk B2's revision caught. Every other `locked`-related test (`Part.is_locked`, the response field, single-`DELETE`/cascade-delete gating) is untouched and still passes conceptually, since none of that changed.
- `flutter analyze lib test` - **zero new issues**, same 5 pre-existing findings as every prior entry.
- Full client suite: **205 passed** (197 + 6 + 2), **17 failed-to-load**, identical file set - `PartScreen` itself still can't be widget-tested here (`flutter_scene`), so the actual tap-to-edit/rollback/Confirm/Cancel flow inside it is reviewed, not executed, same constraint A4's own `_confirmExtrude`/`_cancelExtrude` coverage hit.
- Backend pure-Python suite (`test_stage_a1_graph.py`/`test_stage_b1_model.py`/`test_stage_b2_graph.py`) re-ran for real, 33/33, unaffected.
- CI (`.github/workflows/backend-verify.yml`) will run on push, real OCCT, both architectures - the actual proof for the backend half, per every prior backend prompt.

**Left as-is, flagged rather than silently decided**: the tree row's "Locked"/"Editable" subtitle text (`feature_tree_panel.dart`) is unchanged - it still reflects delete-eligibility (accurate, since single-`DELETE` still requires the last Feature), even though *every* row is now tap-editable regardless. Calling a non-last row "Locked" could now read as misleading UX, since tapping it does something. Not changed here since B4's own text never asked for tree visual changes beyond tap behavior - flagging as a possible on-device follow-up rather than deciding unilaterally.

Not verified here, needs on-device confirmation (this prompt's actual stop-condition gate): tapping an earlier Extrude with 1+ downstream dependents actually rolls the viewport back, opens the panel prefilled correctly, and rolls forward with the downstream dependents visibly recomputed on Confirm; Cancel truly leaves the graph unchanged (including a live-preview edit made before cancelling); tapping an earlier Sketch behind a downstream Extrude opens the 2D canvas with everything after it suppressed, and returns/recomputes correctly.

**CI confirmed green on both architectures** (job logs pulled directly via `mcp__github__get_job_logs`, not just the `conclusion` field, run `28685835689`): `linux/amd64` - **320 passed in 5.60s**; `linux/arm64` - **320 passed in 80.61s** (slower under QEMU emulation, identical pass count). All 3 new `test_stage_b4_earlier_feature_editing.py` tests and both updated `test_patch_on_a_locked_extrude_feature_is_now_allowed`/`test_mutating_a_sketch_behind_a_locked_feature_is_allowed_over_the_api` cases are confirmed `PASSED` by name in both architectures' logs - no CI failures on this push, unlike B1/B2's first attempts.

This closes out Prompt B (B1-B4) pending on-device confirmation of the full set, per B4's own stop condition, before starting Prompt C (Create Plane).

## 2026-07-04 — Prompt C1: Sketch point & line selection in the 3D viewport

Inserted ahead of the original Prompt C (now C2, unaffected in content) - Create Plane's "Normal to Line at Point" reference type needs the user to pick a Sketch's Line and Point directly in the 3D viewport, which nothing before this prompt could do. Started on top of B1-B4 (merged, per the user directly) without waiting on their own on-device confirmation gate, per the user's explicit instruction to proceed with this prompt now - C1's own on-device confirmation becomes the new gate in front of C2, same relationship B4's confirmation had to the old Prompt C.

**Backend** (`app/sketch/models.py`/`store.py`, zero OCCT dependency): new `SketchEntityType` str-Enum (`POINT`/`LINE`/`CIRCLE` - included Circle now per the prompt's own recommendation, even though the client side of this prompt only renders/hit-tests Point/Line, per its own explicit scope boundary) and frozen `SketchEntityRef` (`sketch_id`, `entity_type`, `entity_id`), mirroring `SubShapeRef`'s pattern in `app.document.models`. `resolve_sketch_entity(ref)` in `store.py` (which already imports `HTTPException` for `get_sketch_or_404`, so this doesn't introduce a new fastapi-in-a-non-router-module deviation the way B1's `resolve_subshape` had to flag) - a direct dict lookup against `Sketch.points`/`Sketch.entities` with an `isinstance` type-check, not an OCCT re-derivation like `resolve_subshape`, since Points/Lines/Circles already carry stable ids assigned at creation. Fails closed with the same structured 422 `missing_reference` envelope B1 established, for an unknown `sketch_id`, an unknown `entity_id`, or an `entity_id` that resolves to the wrong `entity_type` (a failure mode `SubShapeRef` has no analog for, since its index is always re-derived per `shape_type` rather than looked up in a shared id space).

**Testing (backend)**: new `tests/test_stage_c1_sketch_entity_ref.py` (6 tests) - resolves a real Point/Line/Circle, unknown `sketch_id`, unknown `entity_id`, and the three-way type-mismatch case. **Genuinely executed, 6/6 passed** - unlike almost every other backend prompt in this project, this needed no OCCT at all (confirmed both files still import/compile cleanly standalone), so this is real proof, not `ast.parse`-only review.

**Client, rendering**: found that `sketch_geometry_3d.dart`/`buildSketchGeometryNode` already renders every non-hidden Sketch's Lines/Circles in the 3D viewport (pre-existing, contrary to this prompt's own "Missing" framing, which was written against a stale assumption) - so the real gap was narrower than scoped: (1) Points were never rendered at all, only Lines/Circles: `SketchGeometry3D` gained `points`/`pointIds` (plus `lineIds`, parallel to `lineSegments`, needed for hit-testing below) and `buildSketchGeometryNode` now emits a marker primitive per Point via the same `vertexMarkerSegments` "near-zero segment + round cap" trick `mesh_geometry.dart`'s `buildVertexMarkersNode` uses. (2) a consumed Sketch (auto-hidden into `_hiddenFeatureIds` by `_confirmExtrude`) was fully excluded from `_visibleSketchGeometries`, not just visually de-emphasized - fixed with a new `_autoHiddenSketchFeatureIds` set in `part_screen.dart`, tracking exactly the auto-hide-on-consume case separately from a real user Hide/Show or a B4 rollback suppression (`_beginRollback` never adds to it) - a Feature hidden only via this set stays visible and pickable, rendered dimmed (`sketchLineDimmedColor`, `AlphaMode.blend`) via a new `dimmedSketchFeatureIds` prop threaded through to `PartViewport`. Had to special-case this exception off entirely while a B4 rollback is active (`_hiddenFeatureIdsBeforeRollback != null`) - otherwise a Sketch already auto-hidden before rollback began would wrongly stay visible during the edit, defeating B4's "suppress everything after" invariant; also had to add a `_recomputeVisibleSketchGeometries()` call to `_endRollback` itself, which never previously recomputed the Sketch-visibility maps after restoring `_hiddenFeatureIds`, a latent staleness gap in B4's own rollback plumbing that would otherwise have undermined this prompt's own dimmed/visible logic after every rollback session ended.

**Client, hit-testing**: extended `hitTestBodies` (`selection_hit_test.dart`, the one path `PartViewport._recomputeHover` already calls) to also accept `sketchGeometries`, per the confirmed design - a Sketch Point ties with a Body Vertex at the top priority tier, a Sketch Line ties with a Body Edge at the next, both decided by the same nearest-in-range-pixel-distance comparison already used within each tier (recommended "kind-based tie" from the prompt's own fork, taken without on-device confirmation since that's explicitly this sandbox's limit, not a decision made blind) - new `hitTestSketchPoints`/`hitTestSketchLines` reuse the same math (`_worldUnitsPerPixelAtDepth`, `_closestRaySegmentDistance`) rather than a second hit-test path. Also fixed `_recomputeHover`'s pre-existing `bodies.isEmpty` early return, which skipped hit-testing entirely for a bare Sketch with no Extrude yet - now gated on both `bodies` and `sketchGeometries` being empty.

**Client, selection framework**: `SelectionFilterState` gained `sketchPoint`/`sketchLine` (default on, mirroring vertex/edge/face); the three existing Body-exclusive filter overrides (`_setBodyFilter`, and both A4 target-body-picking pushes) now also force these off, since Sketch entities would otherwise still win a "Body only" pick at the tied top tier. `SelectionEntityKind` gained `sketchPoint`/`sketchLine`; `SelectionEntityRef` gained `sketchFeatureId`/`sketchEntityId` (String, since Sketch entity ids are real backend UUIDs, not the small dense ints mesh entities use) rather than overloading `bodyId`/`id`. Every exhaustive switch over `SelectionEntityKind` updated (`part_viewport.dart`'s highlight builders, `selection_list_drawer.dart`'s icon/label/title). `selection_actions.dart`'s `contextActionsFor` gained a guard returning no actions for a sketch-only selection - without it, a lone sketchPoint would have fallen through to a nonsensical "Create Plane" offer, since `hasFace`/`hasEdge`/`hasVertex` would all be false; wiring the real sketch-entity combos is explicitly C2's job. "Selection Filters" menu gained the two new toggles (`part_toolbar.dart`).

**Testing (client)**: `flutter analyze` - **clean, zero new issues** (bootstrapped Flutter 3.44.4 stable again this session, `storage.googleapis.com` reachable) - caught and fixed one pre-existing, unrelated `const_set_element_not_primitive_equality` diagnostic in `selection_list_drawer_test.dart` (two `const {entity}` set literals predating this prompt, newly flagged by this SDK's analyzer version, nothing to do with `SelectionEntityRef`'s new fields) as a trivial drive-by fix. New pure-Dart coverage with zero `flutter_scene` dependency, confirmed genuinely executed: `selection_filter_test.dart` (+2 cases) and `override_stack_test.dart` (unaffected, re-ran for regression) - **17/17 passed for real**. New cases added to `selection_hit_test_test.dart`/`sketch_geometry_3d_test.dart` (sketch point/line hit-testing, the priority tie, `SelectionEntityRef` equality, Point/line id parallel-array coverage) are `flutter analyze`-clean but - confirmed via `git stash` against the pre-C1 tree - were **already** blocked from execution by the pre-existing `flutter_scene`/`flutter_gpu` stable-channel mismatch before this prompt touched anything (both files already transitively import `flutter_scene` via `mesh_geometry.dart`), so this is not a regression this prompt introduced. Full client suite: **207 passed** (205 + 2), **17 failed-to-load**, identical file set to B4's own count plus the two new filter tests - confirmed via the same `git stash` comparison that this specific 17-file set was unchanged by this prompt. Fixed two now-incorrect pre-existing test assertions in `sketch_geometry_3d_test.dart` that this prompt's own Point-rendering change made wrong (a Sketch with an unresolvable Line/Circle used to assert `isEmpty: true`; now correctly `false`, since its real Points still render/are pickable on their own).

**Left as explicitly out of scope, per the prompt's own boundary**: Circle picking (backend ref type supports it; no client render/hit-test/filter wiring); wiring any specific Point+Line picking-mode combination for Create Plane (C2's job); custom/arbitrary sketch planes.

**Not verified here, needs on-device confirmation (this prompt's own stop-condition gate, same discipline as every prior client-facing prompt)**: Sketch geometry (Points included) actually renders and is tappable in the 3D viewport, including for a just-consumed Sketch (now dimmed rather than invisible); the vertex/point and edge/line priority ties feel right when overlapping; the two new Selection Filters toggles appear and gate hit-testing as expected; `SelectionListDrawer` names sketch entries sensibly. Do not start Prompt C2 (Create Plane) until this comes back positive.

**C1's own on-device confirmation came back positive** (user-confirmed directly) - Prompt C2 (Create Plane) started next in the same session.

## 2026-07-04 — Prompt C2: Create Plane

Two v1 plane-construction methods: OFFSET_FACE (one planar Body face + a signed offset) and NORMAL_TO_LINE_AT_POINT (a Sketch Line + the Point that's one of its own endpoints) - both reference-only (`produces: PLANE`, `produces_solid_geometry: False`), matching the original brief's custom-plane deferral.

**Backend**, split by OCCT dependency the same way B1/C1 already established: `PlaneType`/`CreatePlaneFeature`/`ResolvedPlane` in `app/document/models.py` (OCCT-free, mirrors `SubShapeRef`'s placement) - `CreatePlaneFeature` carries all four of `face_ref`/`offset`/`line_ref`/`point_ref` as optional fields (exactly one pair populated per `plane_type`), validated by the router rather than encoded in the dataclass, same split `ExtrudeFeature`'s Boss-vs-Cut fields already use. `app/document/plane_geometry.py` (new, genuinely OCCT-free) resolves NORMAL_TO_LINE_AT_POINT via C1's `resolve_sketch_entity` plus plain 2D vector math (deliberately duplicates, rather than imports, `extrude.py`'s OCCT-typed `sketch_point_to_world` - importing it would have dragged OCCT into an otherwise-pure module) - raises the new structured `point_not_on_line` error (422, same envelope as `missing_reference`) when the given Point isn't literally the Line's own `start_point_id`/`end_point_id`, an id comparison per the project's no-implicit-coincidence principle. `app/document/create_plane.py` (new, needs OCCT) resolves OFFSET_FACE via B1's `resolve_subshape` plus `BRepAdaptor_Surface`'s planarity check (`GeomAbs_Plane`), raising the new `non_planar_reference` error for a curved reference face - orientation-correction for `TopAbs_REVERSED` mirrors `extrude.py`'s own `_wire_normal` handling of the identical OCCT quirk.

**A design gap caught and closed before it could bite**: `app.document.graph.build_feature_graph` only built dependency edges for `ExtrudeFeature` - without extending it, cascade-deleting the Body/Sketch a `CreatePlaneFeature` references would silently leave it dangling instead of taking it down too, the exact "everything after it in the list" bug class B2 fixed for `target_body_ids`, just for a new reference kind. Fixed: OFFSET_FACE depends on the owning ExtrudeFeature (via `base_feature_id`); NORMAL_TO_LINE_AT_POINT depends on the SketchFeature wrapping its `line_ref.sketch_id` (a new `_sketch_feature_id_for_sketch` helper, since a Sketch's own id and its wrapping SketchFeature's id are different ids). Verified directly (not just by inspection): a real `Part`/`transitive_dependents` test confirms cascade-deleting a SketchFeature takes both an OFFSET_FACE Plane (via its Extrude) and a NORMAL_TO_LINE_AT_POINT Plane (via the Sketch directly) down with it, while deleting only the Extrude leaves the Sketch-referencing Plane untouched.

Router: `POST`/`PATCH .../create-plane-features` mirroring `ExtrudeFeature`'s route shape, unlocked from the start (no lock ever added, per this prompt's own explicit instruction) - validates the payload's field combination and ref-type tags (`_validate_create_plane_payload`) then calls `resolve_create_plane` before ever constructing/mutating the Feature, so an invalid reference is rejected, never persisted. `GET`/list responses resolve geometry live and soft-fail to `origin: null, normal: null` on a since-broken reference (logged, not raised) rather than failing the whole Feature list over one bad Plane - real validation only ever happens at create/update time. New pydantic `SubShapeRefSchema`/`SketchEntityRefSchema` (the first wire schemas for B1's `SubShapeRef`/C1's `SketchEntityRef` - both existed only as domain dataclasses until now, per their own "no consumer yet" framing).

**Testing (backend)**: new `tests/test_stage_c2_plane_geometry.py` (11 tests, zero OCCT) - NORMAL_TO_LINE_AT_POINT resolution (start point, end point, XZ/YZ planes, unit-length normal regardless of line length), `point_not_on_line`/`missing_reference` rejections, and the `build_feature_graph`/cascade-delete coverage described above. **Genuinely executed, 11/11 passed** - confirmed directly (not just `ast.parse`) since, like C1, this needed no OCCT at all. New `tests/test_stage_c2_create_plane.py` (14 tests, real HTTP API surface: offset-from-face success/rejection, normal-to-line-at-point success/rejection, PATCH, list, cascade-delete) needs real OCCT (`app.main` imports OCC directly) - `ast.parse`/manual-review only in this sandbox, same constraint as every other OCCT-touching backend prompt; CI will provide the real proof. Full OCCT-free backend suite re-ran: **68/70 passed** (57 pre-existing + 11 new), same 2 pre-existing OCCT-import failures in `test_stage2_profile.py` as before this prompt - confirmed unrelated and unchanged.

**Client**: `document_api_client.dart` gained `SubShapeRefDto`/`SketchEntityRefDto` (wire counterparts to the backend schemas) and extended `FeatureDto` with `planeType`/`faceRef`/`offset`/`lineRef`/`pointRef`/`origin`/`normal`, plus `createCreatePlaneFeature`/`updateCreatePlaneFeature`. New `create_plane_geometry_3d.dart` renders a created Plane as a translucent bounded quad (amber tint, deliberately distinct from both the RGB-tinted fixed reference planes and Sketch geometry's neutral grey) at an arbitrary world-space origin/normal - reuses `reference_planes.dart`'s existing `doubleSidedQuadBuffers`/`referencePlaneBorderPoints` local geometry unchanged, computing a `Quaternion.fromTwoVectors`-based `Matrix4` transform instead of one of `ReferencePlaneKind`'s three fixed ones (confirmed the anti-parallel/straight-down-normal edge case degrades gracefully via `vector_math`'s own implementation, not a guess). Sizing left as a fixed default (matching `referencePlaneSize`), per this prompt's own "leave exact sizing as an on-device call" instruction - not derived from referencing geometry's bounding box.

New `create_plane_panel.dart` (`CreatePlanePanel`, mirrors `ExtrudePanel`'s Confirm/Cancel shape): an offset field for OFFSET_FACE (Confirm enabled once it parses), no field at all for NORMAL_TO_LINE_AT_POINT (Confirm always enabled - the two refs it needs are already guaranteed selected by the time the button that opened this panel was even enabled). `selection_actions.dart`'s `contextActionsFor` gained the two real enabling rules alongside its existing scaffolded ones: exactly one Body Face alone now returns a real `enabled: true` action (previously this exact selection already fell into a *disabled* placeholder bucket - 2+ faces alone still does); exactly one Sketch Line + one Sketch Point returns one too, but only when the Point is genuinely that Line's own endpoint - a new `PointOnLineChecker` callback parameter threads that lookup in (`contextActionsFor` has no Sketch geometry of its own to consult), backed in `part_screen.dart` by a new `_linesByFeatureId` map (raw `LineDto`s, populated alongside `_allSketchGeometries` - unlike `SketchGeometry3D`'s world-space-only render data, this keeps each Line's real `startPointId`/`endPointId`). `selection_context_panel.dart` wires the enabled Create Plane button to a real `onCreatePlane` callback for the first time (Chamfer/Fillet remain scaffolded `null`s, D/E's job).

`part_screen.dart`'s Create Plane flow mirrors Extrude's "create eagerly on open, PATCH on every field edit (debounced 500ms), Confirm just closes, Cancel deletes-or-reverts" pattern exactly, including B4 rollback wiring (`_openCreatePlanePanelForEdit` parallels `_openExtrudePanelForEdit`) - chosen over a more literal reading of "Confirm is enabled once refs are selected" specifically so the plane renders live in the viewport the moment it's created, before Confirm, the same "see it before you commit to it" UX every other panel in this project already gives. Handles the one real failure mode client-side validation can't rule out ahead of time - a lone selected face passing `contextActionsFor`'s shape check but turning out to be curved once the backend actually checks - by closing the panel back out automatically if creation fails, rather than leaving it stuck open with nothing behind it. `feature_tree_panel.dart` gained a **Planes** section (real produced objects, 1:1 with Features so no separate id/name map like Bodies needs) - shown only when non-empty, per B3's own precedent and this prompt's own explicit "no empty Planes section" requirement; `featureDisplayName`/the Features-section tile icon both extended for the third Feature type.

**Testing (client)**: `flutter analyze` - clean, zero new issues (same 3 pre-existing `avoid_print` infos as C1). New pure-Dart/widget coverage, confirmed genuinely executed standalone: `selection_actions_test.dart` (+9 cases for the two new rules, plus one pre-existing test's expectation corrected - a lone face now legitimately returns `enabled: true`, not the old placeholder) - blocked from running *together with the rest of the suite* by the same pre-existing `flutter_scene` transitive dependency as C1's own `selection_hit_test_test.dart` (confirmed via a fresh `git worktree` diff against the pre-C2 tree: this file was already in that blocked set before this prompt touched it, not a new block). `create_plane_panel_test.dart` (8/8) and `document_api_client_test.dart`'s new cases (8/8, DTO round-trips + `createCreatePlaneFeature`/`updateCreatePlaneFeature` wire-format) both **passed for real when run standalone** - a full-suite batch run intermittently reports `create_plane_panel_test.dart` as failing to load with a generic "Dart compiler exited unexpectedly" error, reproduced twice; isolated re-runs of that exact file pass 8/8 both times, so this reads as this sandbox's compiler choking on the full ~30-file batch under resource pressure, not a defect in the file - flagging honestly rather than hiding it, but not chasing further given the isolated result is unambiguous. New `create_plane_geometry_3d_test.dart` (pure `createPlaneTransform` orientation math, including the anti-parallel-normal edge case) is `flutter analyze`-clean but blocked the same way every GPU-touching test file in this project is. Full-suite counts (excluding the flaky batch re-run above): **239 passed** in a clean run, 16 failed-to-load - confirmed via the same `git worktree` diff that this is the pre-existing 14-file C1 set plus exactly two new, expected additions (`create_plane_geometry_3d_test.dart`, and `create_plane_panel_test.dart` only in its flaky batch runs) - zero regressions, zero previously-passing file newly broken.

**Left as explicitly out of scope, per the prompt's own boundary**: sketching on a created Plane (confirmed by construction - a created Plane was never hooked into `hitTestReferencePlanes`/the "New Sketch on..." flow, which only ever tests the three fixed `ReferencePlaneKind`s, so there is no code path that could offer it); three-point/tangent-to-face/angled-from-face plane types; any coordinate-matching/tolerance-based point-on-line detection.

## 2026-07-04 — Prompt C3 (informal): Feature-menu Plane entry, Midplane, sketch-on-created-plane, tappable Planes

Before C2's own on-device confirmation came back, the user gave feedback expanding its scope: "Plane" should be a Feature-picker entry (not just an ambient selection outcome), a third plane type (Midplane, two parallel faces) should exist, and created Planes should be tappable/selectable with a context menu offering "Create Sketch on Plane"/"Delete Plane". Asked how much of "Create Sketch on Plane" to build now (it forks hard - Sketches only ever lived on the three fixed planes) - **user chose "Full support now"**: a created Plane must be a real, generalized anchor a Sketch can embed onto and an Extrude can build solid geometry on top of, not just a rendered reference object.

**Backend, `ResolvedPlane` generalized to a full orthonormal basis** (`app/document/models.py`): `x_axis`/`y_axis` added alongside the existing `origin`/`normal` - the exact in-plane basis a Sketch anchored to this Plane embeds its local (x, y) geometry through, and what `app/document/extrude.py`'s solid-building embedding now consumes directly instead of a bare `Plane` enum lookup. **Deliberately hand-verified, not formula-derived, for the three fixed planes**: hand-checked that a naive `normal = x_axis × y_axis`-style cross-product formula does *not* reproduce the already-shipped XZ-plane convention (`sketch_point_to_world`'s `(x, y) → (x, 0, y)`) - XZ's own `(x_axis, y_axis, normal)` triple is left-handed, an accident of the original convention now baked into every existing XZ Sketch. `app/document/plane_geometry.py`'s new `_PLANE_BASIS` lookup table (`sketch_basis_for_plane`) hardcodes all three planes' bases explicitly rather than trusting any single formula. For the two plane types with no natural in-plane reference (`NORMAL_TO_LINE_AT_POINT`, `MIDPLANE`), a new `_arbitrary_perpendicular_basis(normal)` picks a deterministic (not formula-fragile) orthonormal pair via a dominant-axis-avoidance + cross-product technique - correct by construction (this is a genuinely new plane with no pre-existing convention to match, unlike the fixed planes above).

**Backend, `PlaneType.MIDPLANE`** (`app/document/create_plane.py`): equidistant between two parallel planar Body faces. `CreatePlaneFeature.face_ref` (singular) generalized to `face_refs: list[SubShapeRef]` so `MIDPLANE` (two entries) can reuse the same field `OFFSET_FACE` (one entry) already had - `_validate_create_plane_payload` extended to a three-way branch. New structured `faces_not_parallel` 422 (same envelope as `missing_reference`/`non_planar_reference`) when the two faces' normals aren't parallel/anti-parallel (`abs(dot) ≈ 1`). Both `OFFSET_FACE`'s and `MIDPLANE`'s in-plane basis now come from OCCT's own `gp_Ax3.XDirection()`/`YDirection()` directly (unlike the fixed planes, there's no pre-existing convention here to protect, so trusting OCCT's own derivation is both correct and simplest) - with the established `TopAbs_REVERSED` correction extended to flip `y_axis` alongside `normal` (not `x_axis`), preserving `normal == x_axis × y_axis`.

**Backend, the circular-import/infinite-recursion problem, solved via a `_from_bodies` core / fresh-wrapper split**: `create_plane.py`'s resolvers were refactored into `resolve_*_from_bodies(bodies, ...)` (never recompute) plus `resolve_*(part, ..., hidden_feature_ids)` (compute `bodies` once, then call the `_from_bodies` core) - `extrude.py` gained the matching `resolve_subshape_from_bodies`/`resolve_subshape` split. This exists because `extrude.py._solid_for_extrude_feature` now must resolve a Sketch's own anchor plane (`create_plane.resolve_sketch_basis`, function-local import to break the module-level cycle `create_plane.py` already has back to `extrude.py`) potentially recursively (a `CreatePlaneFeature` can itself sit on faces from an earlier Extrude) *from inside* `compute_part_bodies`'s own topological-order loop - calling a fresh top-level `compute_part_bodies` from there would recurse forever. Threading the loop's own in-progress `bodies` accumulator through instead is correct because `build_feature_graph`'s topological order already guarantees any face-owning ExtrudeFeature a custom plane depends on is processed (and its Body committed into `bodies`) before the Sketch/Extrude that needs that plane's basis is reached.

**Backend, `SketchFeature.plane_feature_id`**: a Sketch now anchors to either a fixed `Plane` (`Sketch.plane`, relaxed to `Plane | None`) or a `CreatePlaneFeature` (mutually exclusive, enforced by new `_validate_sketch_feature_payload` - confirms the named Plane resolves before ever anchoring a Sketch to it). `build_feature_graph` gained the matching dependency edge (a custom-plane Sketch depends on its anchor Plane) so cascade-deleting the Plane correctly takes the Sketch (and everything downstream of it) with it - the exact "everything after it in the list" bug class B2/C2 already fixed for other reference kinds, now closed for this one too. `app/sketch/schemas.py`'s `SketchResponse.plane`/`app/document/schemas.py`'s new `SketchFeatureCreate.plane_feature_id`/`SketchFeatureResponse.plane_feature_id` follow.

**Testing (backend)**: new `tests/test_stage_c3_plane_basis.py` (7 tests, zero OCCT) and `tests/test_stage_c3_graph.py` (5 tests, zero OCCT) - fixed-plane basis reproduces the exact pre-existing embedding for all three planes, `_arbitrary_perpendicular_basis` is orthonormal/right-handed/deterministic across five normals, a custom-basis resolve offsets by the basis's own origin (not the world origin), the new SketchFeature→CreatePlaneFeature and MIDPLANE→both-faces graph edges (including cascade-delete taking a custom-plane Sketch's own downstream Extrude with it). **Genuinely executed, 12/12 passed.** Full OCCT-free backend suite: **80 passed** (68 pre-existing + 12 new), same 2 pre-existing OCCT-import failures in `test_stage2_profile.py`, confirmed via a `git worktree` diff against the pre-C3 commit - identical failing set both before and after. Existing `test_stage_c2_plane_geometry.py` updated for `resolve_normal_to_line_at_point`'s new explicit `basis` parameter (previously derived internally from `sketch.plane`) and `face_ref`→`face_refs`; `test_stage_c2_create_plane.py` (real-OCCT, `ast.parse`-only in this sandbox) extended with Midplane end-to-end tests, a Sketch-anchored-to-a-custom-plane test, an Extrude-built-on-a-custom-plane-Sketch test (asserting a second real Body appears), and a deep recursion test (a `NORMAL_TO_LINE_AT_POINT` Plane whose Line lives in a Sketch anchored to a *different* custom Plane).

**Client, `document_api_client.dart`**: `FeatureDto.faceRef` → `faceRefs: List<SubShapeRefDto>`, `xAxis`/`yAxis` added, `planeFeatureId` added (on `FeatureDto` and as an optional `createSketchFeature` parameter - exactly one of `plane`/`planeFeatureId` is ever sent). `sketch_api_client.dart`'s `SketchDto.plane` relaxed to `String?` - already-nullable-tolerant call sites (`SketchController._plane`, `PlaneIndicator`, both pre-existing) needed no further changes at all, confirmed by reading both before touching the type.

**Client, `sketchPointToWorld` generalized from a fixed `ReferencePlaneKind` to a new `SketchPlaneBasis`** (`sketch_geometry_3d.dart`) - `.fixed(ReferencePlaneKind)` reproduces the exact three pre-existing embeddings; a custom plane's basis comes straight from the backend's own already-resolved `FeatureDto.origin`/`xAxis`/`yAxis`/`normal` (no client-side re-derivation, no risk of disagreeing with the backend's own convention). `sketchGeometry3DFrom`/`projectMeshEdgesOntoPlane`/`worldPointToSketch` all take a `SketchPlaneBasis` now. **This closes a real, otherwise-silent gap**: without it, `_refreshSketchGeometries` would have called `referencePlaneKindFromApiValue(null)` for any custom-plane Sketch and silently rendered nothing - a Sketch anchored to a created Plane would have been invisible and unpickable in the 3D viewport despite existing and extruding correctly server-side. `part_screen.dart` gained `_customPlaneBasis`/`_sketchPlaneBasisFor` to resolve either kind per-Feature; `_openSketchWithAnimation`/`_addSketchFeature` skip the camera-fly-to-plane animation for a custom plane (no `ReferencePlaneKind` to animate toward - `orientationFacingPlane` stays fixed-plane-only) but still pass the real basis through for the ghost-edge overlay, the same documented "can't resolve, just navigate" degradation this code already used for a fetch failure.

**Client, `create_plane_geometry_3d.dart`'s `createPlaneTransform` rebuilt on the backend's real basis instead of `Quaternion.fromTwoVectors`** - C2 shipped a `normal`-only rotation (a valid but arbitrary in-plane orientation); now that the backend returns a full basis, `Matrix4.columns(xAxis, normal, yAxis, origin)` places the rendered quad in the *exact* orientation a Sketch anchored to it actually embeds through, not just a visually-plausible one. Also simpler: no quaternion/degenerate-case reasoning needed at all.

**Client, Midplane**: `CreatePlaneMode.midplane` added to `create_plane_panel.dart` (no numeric field, always-enabled Confirm, same as `normalToLineAtPoint`); `selection_actions.dart`'s `contextActionsFor` gained "exactly two Faces alone → real, enabled `Create Plane (Midplane)`" ahead of the pre-existing disabled 2+-faces placeholder (which still covers 3+); `part_screen.dart`'s `_onCreatePlaneTapped`/`_openCreatePlanePanel` extended for the third branch (`face_refs: [a, b]`).

**Client, Feature-picker "Plane" entry**: added to `feature_picker_sheet.dart`'s `FeaturePickerAction` enum - turned out to need no new picking-mode machinery at all, since Create Plane's ambient-selection flow (any Face/Line/Point tap already surfaces the enabled button once a valid combo is selected, unchanged since C2) already covers every combo this entry needs; `_startPlanePicker` just clears the current selection and shows a hint SnackBar. The sheet gained a sixth row (Plane) and was wrapped in `SingleChildScrollView` + `isScrollControlled: true` - caught via a widget test that the un-scrolled six-row sheet overflows a short viewport, a real latent bug for a small/split-screen device, not just a test artifact.

**Client, tappable/selectable created Planes**: new pure `hitTestCreatePlanes` (`create_plane_geometry_3d.dart`, mirrors `hitTestReferencePlanes`'s plane-ray algebra but for an arbitrary, not axis-aligned, quad, via dot products against the plane's own orthonormal `xAxis`/`yAxis`) wired into `PartViewport._handleTap` after the three fixed reference planes (which keep first claim on an overlapping tap). New `create_plane_context_sheet.dart` (`CreatePlaneContextSheetAction.newSketch`/`.delete`, mirrors `plane_context_sheet.dart`'s shape) - "Create Sketch on Plane" reuses `_addSketchFeature(planeFeatureId: ...)`; "Delete Plane" reuses the existing generic `_cascadeDeleteFeature`, since a created Plane is just another Feature that may have Sketches (and their own downstream Extrudes) depending on it - no new deletion logic needed at all.

**Testing (client)**: `flutter analyze lib test` - clean, same 3 pre-existing `avoid_print` infos as every prior entry. New/updated coverage confirmed genuinely executed standalone: `document_api_client_test.dart` (+4: `face_refs`/`x_axis`/`y_axis` parsing, a Midplane `FeatureDto`/wire-format round trip, `createSketchFeature`'s `plane`-vs-`planeFeatureId` exclusivity), `feature_picker_sheet_test.dart` (new file, 3/3, zero `flutter_scene` dependency), `create_plane_panel_test.dart` (+1 Midplane case, 9/9 standalone - same pre-existing full-suite-batch flakiness as C2's own entry documented, not a regression). `selection_actions_test.dart`'s stale "two faces still offers only the disabled placeholder" test corrected to reflect the new Midplane rule (+1 new three-faces-placeholder case to keep that scaffolded path covered) - `flutter analyze`-clean but blocked from execution the same pre-existing way as C1/C2's own sketch-entity test additions. `sketch_geometry_3d_test.dart`/`create_plane_geometry_3d_test.dart` updated for the new `SketchPlaneBasis`/four-argument `createPlaneTransform` signatures, confirmed `flutter analyze`-clean, same pre-existing GPU-import block. Full client suite, confirmed via `git worktree` diff against the pre-C3 commit: **identical 13-file failing set both before and after** (zero regressions) - **231 passed** this run (223 pre-existing + net new), fluctuating slightly run-to-run only due to the already-documented `create_plane_panel_test.dart` full-suite-batch flakiness, not any change in this prompt's own code.

**Left as explicitly out of scope / bounded product decisions made without on-device confirmation** (flagged, not hidden): camera animation for a Sketch anchored to a custom plane (skips the fly-to-plane animation entirely rather than attempting a `Quaternion.fromTwoVectors`-based generalization - still navigates correctly, just without the flourish); no visual "selected" highlight state was added for the Feature-tree row of a created Plane beyond the existing viewport-quad brightening; degenerate Midplane input (the same face selected twice) is not specially rejected client- or server-side beyond the existing parallel-faces check, which passes trivially for that case.

**Not verified here, needs on-device confirmation**: the Feature-picker "Plane" entry's selection-hint flow feels right in practice; Midplane's two-face selection and resulting plane placement look correct on a real box; a Sketch drawn on a created Plane renders/extrudes in the expected orientation; tapping a created Plane in the viewport reliably hits it (vs. falling through to background) and its context sheet's two actions behave as expected, including a cascade-delete confirmation for a Plane with dependent Sketches/Extrudes.

## 2026-07-04 — Bug fix: consumed Sketch only "partially" hid after Extrude

On-device testing of the above surfaced a real UX bug: confirming an Extrude greys out its consumed Sketch in the Feature tree (correct), but the Sketch's own geometry stayed fully visible - not even dimmed - in the 3D viewport. Investigating the code confirmed this was Prompt C1's own *deliberate* design (a Feature auto-hidden because it's consumed was kept in `_visibleSketchGeometries` and rendered at reduced opacity via `sketch_geometry_3d.dart`'s `sketchLineDimmedColor`/`AlphaMode.blend`, specifically so its Lines/Points stayed selectable for Create Plane's "normal to line at point" reference) - not a rendering defect. Asked the user which they actually wanted (dim-but-selectable vs. fully hidden, given the tradeoff that full-hide means a consumed Sketch's geometry is no longer tap-selectable for Create Plane until explicitly un-hidden); **user chose fully hidden**.

**Change**: `part_screen.dart`'s `_recomputeVisibleSketchGeometries` no longer special-cases `_autoHiddenSketchFeatureIds` - a consumed Sketch is now excluded from `_visibleSketchGeometries` exactly like a manually-hidden Feature (invisible and unpickable), full stop. `_autoHiddenSketchFeatureIds` itself is kept (still needed to tell "hidden because auto-consumed, safe to auto-restore once its Extrude is deleted" apart from "hidden because the user explicitly hid it, leave it alone" - unrelated to the dim-vs-hide question). Since dimming was only ever reachable through the now-removed exception, it became dead code end to end - removed `PartViewport.dimmedSketchFeatureIds` (prop, `didUpdateWidget` check, and its `_syncSketchNodes` wiring), `buildSketchGeometryNode`'s `dimmed` parameter, and `sketchLineDimmedColor` (`sketch_geometry_3d.dart`) entirely, rather than leaving an unreachable pathway behind.

**Testing**: `flutter analyze lib test` - clean, same 3 pre-existing `avoid_print` infos. Full client suite re-ran: **231 passed**, same 19 failed-to-load / identical 13-file set, confirmed unaffected by this change (all consumers of the removed APIs were within the files touched here; no test referenced `dimmedSketchFeatureIds`/`sketchLineDimmedColor` directly). Updated a stale test description in `part_screen_test.dart` ("...instead of leaving it dimmed forever..." → "...hidden forever...") - its actual assertions (the tree's visibility-off icon) were already about `_hiddenFeatureIds`, not dimming, so needed no logic change.

**Not verified here, needs on-device confirmation**: the consumed Sketch is now genuinely invisible (not just dimmer) in the 3D viewport; un-hiding it via the Feature tree's Hide/Show action correctly restores full visibility and pickability.

**Not verified here, needs on-device confirmation (this prompt's own stop-condition gate)**: both plane types actually create and render correctly (right position, right orientation, right offset direction for positive/negative values); a curved-face attempt is cleanly rejected with a visible message, not a crash or silently-wrong plane; the Planes tree section appears/is tappable; editing an existing Plane via rollback prefills and re-resolves correctly, and Cancel truly restores the original definition. Do not start Prompt D (Fillet) until this comes back positive.

## 2026-07-04 — Prompt C4: three more Create Plane methods (edge+vertex, face+vertex, three points)

Asked "are edges and vertices usable?" - answered that they're fully selectable/hit-testable but wired to nothing real (Fillet/Chamfer are permanently disabled scaffolds; two Create Plane variants involving vertices were scaffolded-but-disabled placeholders too). User: "this seems like a good time to wire up other common methods of creating planes." Asked via `AskUserQuestion` which to build (just the two already-scaffolded types; those two plus a 3-point plane; or a custom set) - **user chose "the two scaffolded ones + 3-point plane"**.

**Backend, `SubShapeType.VERTEX`** (`app/document/models.py`): resolves via the exact same 0-based `topexp.MapShapes(body, TopAbs_VERTEX, ...)` scheme `app.document.mesh._extract_topology_vertices` already uses for the client's `topologyVertexIds` - `extrude.py`'s `_TOPABS_FOR_SUBSHAPE_TYPE` needed only one new dict entry, no new resolution logic.

**Backend, `PointRef`** (`app/document/models.py`): a new value type holding *either* `vertex_ref: SubShapeRef | None` *or* `sketch_point_ref: SketchEntityRef | None` (never both) - lets a single `THREE_POINTS` `CreatePlaneFeature` mix Body vertices and Sketch Points freely (e.g. 2 vertices + 1 sketch point), the most useful real-world case, while keeping the project's "one concrete type, payload shape validated by the router" convention `CreatePlaneFeature` itself already uses. `CreatePlaneFeature` gained `edge_ref`/`vertex_ref`/`point_refs: list[PointRef]` alongside the existing four fields.

**Backend, `PlaneType.NORMAL_TO_EDGE_THROUGH_VERTEX`/`PARALLEL_TO_FACE_THROUGH_VERTEX`** (`app/document/create_plane.py`, needs OCCT): the first is normal to a selected straight Body edge's direction (`BRepAdaptor_Curve.GetType() == GeomAbs_Line`, rejecting a curved edge with a new `non_linear_edge` 422), through a selected Vertex's position (`BRep_Tool.Pnt`); no natural in-plane reference of its own, so its basis comes from the existing `arbitrary_perpendicular_basis` (renamed public from C3's private `_arbitrary_perpendicular_basis`, now shared by both `NORMAL_TO_LINE_AT_POINT` and this). The second is parallel to a selected planar Body face (same `_resolve_planar_face`/`non_planar_reference` machinery `OFFSET_FACE`/`MIDPLANE` already use), through a selected Vertex - the vertex's own position becomes `origin` directly (it lies on the resulting plane by construction, so this is both correct and centers the rendered quad on the point actually picked, rather than projecting through the face's own location).

**Backend, `PlaneType.THREE_POINTS`** (pure-Python math in `app/document/plane_geometry.py`, OCCT-touching ref resolution in `create_plane.py`): `resolve_three_points(p0, p1, p2)` takes `origin = p0`; `x_axis` = normalized `p0→p1` (a natural, deterministic in-plane reference tied to the user's own selection order, so the plane doesn't "spin" between requests); `normal` = normalized cross product of `p0→p1` and `p0→p2`; `y_axis = normal × x_axis`. Rejects collinear/coincident points with a new `collinear_points` 422 via an **exact** zero-length-cross-product check (not a tolerance-based "nearly collinear" one, consistent with the project's no-implicit-inference principle). `create_plane.py`'s `_resolve_point_ref_position`/`resolve_three_points_from_bodies` resolve each `PointRef` entry (a Body vertex directly, or a Sketch Point mapped through its own Sketch's resolved basis via the existing `basis_point`/`_basis_for_sketch`, renamed public alongside `arbitrary_perpendicular_basis`) before handing three plain positions to the OCCT-free math function.

**Backend, router/schema growth handled via one shared helper, not six duplicated checks**: `_validate_create_plane_payload` grew from 4 fields/3 branches to 7 fields/6 branches - factored the repeated "every other field must be empty" check into `_all_other_create_plane_fields_empty(exclude: set[str], ...)`, called via a local closure so call sites don't have to thread all 7 values manually each time. `offset` is checked via `is None` (not falsiness) so a legitimate `offset=0.0` isn't misread as empty. New `PointRefSchema`/wire fields on `CreatePlaneFeatureCreate`/`Update`/`Response` follow the same pattern C2/C3 already established.

**Testing (backend)**: new `tests/test_stage_c4_plane_basis.py` (7 tests, zero OCCT - `resolve_three_points`'s standard-basis case, origin/x_axis convention, orthonormality on an arbitrary triangle, order-dependent normal-flip, collinear + coincident rejection) and `tests/test_stage_c4_create_plane.py` (real-OCCT, `ast.parse`-only in this sandbox per the usual caveat - end-to-end success/rejection for all three new types over the real HTTP API, mirroring `test_stage_c2_create_plane.py`'s brute-force-the-index-mapping style). Fixed one stale pre-existing assertion (`test_stage_b1_model.py`'s `SubShapeType` enum test still expected exactly `{edge, face}`). Full OCCT-free suite: **86 passed** (up from 79 pre-C4 + the fixed test), same 2 pre-existing OCCT-import failures in `test_stage2_profile.py`, confirmed via a `git worktree` diff against the pre-C4 commit - identical failing file set (17 OCCT-blocked files, now 18 with the new real-OCCT test file added) both before and after.

**Client, DTOs** (`document_api_client.dart`): new `PointRefDto` (`vertexRef`/`sketchPointRef`, exactly one populated); `FeatureDto` gained `edgeRef`/`vertexRef`/`pointRefs`; `createCreatePlaneFeature`/`updateCreatePlaneFeature` gained matching optional params.

**Client, `CreatePlaneMode`** (`create_plane_panel.dart`): three new cases, all "no numeric field, always-enabled Confirm" (same as `normalToLineAtPoint`) - the description-text switch extended per mode.

**Client, `contextActionsFor`** (`selection_actions.dart`): the two pre-existing disabled placeholders ("... Through Vertex)") became real, enabled rules for their exact 2-entity shape (1 edge + 1 vertex; 1 face + 1 vertex), checked ahead of their own now-fallback disabled buckets (still covering 2+-of-either mixes) - same precedence pattern the single/two-face `OFFSET_FACE`/`MIDPLANE` checks already use. New "exactly 3 points total, any mix of Vertex/Sketch Point" rule, checked *before* the sketch-entity-only branch (which would otherwise incorrectly swallow e.g. 2 Sketch Points + 1 Vertex as "not exactly 1 line + 1 point, offers nothing") and before the generic vertex-alone bucket.

**Client, `part_screen.dart` wiring**: `_onCreatePlaneTapped` gained three ordered branches (3-points checked first); `_openCreatePlanePanel` extended with `edgeEntity`/`vertexEntity`/`pointEntities` params and a new `_pointRefDtoFor` helper converting a selected vertex- or sketch-point-kind entity into the right `PointRefDto` variant; `_openCreatePlanePanelForEdit`'s mode-mapping switch and the `_createPlaneEditSnapshot` typed record (and `_cancelCreatePlane`'s PATCH-back call) extended with the three new fields; `selection_context_panel.dart`'s label-to-callback switch merged the two now-real labels plus "Three Points" into the enabled group.

**Testing (client)**: `flutter analyze lib test` - clean, same 3 pre-existing `avoid_print` infos. New coverage confirmed genuinely executed standalone: `document_api_client_test.dart` (+9: `PointRefDto` round-trip both variants, `FeatureDto` parsing for all three new plane types, wire-format tests for all three `createCreatePlaneFeature` calls), `create_plane_panel_test.dart` (+3, one per new mode), `selection_actions_test.dart` (2 stale tests corrected from disabled-placeholder to real-enabled expectations, +4 new exact-count-still-disabled guard tests, +6 new Three Points tests). Full client suite, confirmed via `git worktree` diff against the pre-C4 commit: **identical 13-file failing set both before and after** (zero regressions) - **242 passed** this run.

**Not verified here, needs on-device confirmation (this prompt's own stop-condition gate)**: all three new plane types actually create and render correctly for a real selection (right position/orientation); a curved-edge attempt for Normal-to-Edge-Through-Vertex is cleanly rejected, not a crash; a curved-face attempt for Parallel-to-Face-Through-Vertex is likewise cleanly rejected; Three Points correctly resolves for a mix of Body vertices and Sketch Points, and a collinear/near-collinear pick is cleanly rejected with a visible message; editing any of the three via rollback prefills and re-resolves correctly, and Cancel truly restores the original definition. Do not start Prompt D (Fillet) until this comes back positive.

## 2026-07-05 — Build Tree UI: smaller non-wrapping text, drag-to-resize, Bodies/Planes collapsed by default

On-device feedback (screenshot) showed the Build Tree's default 40%-width panel wrapping row text mid-word ("Extrude 1" -> "Extru"/"de 1", "Planes" -> "Plan"/"es") - the panel had no way to widen it, and every section (Bodies/Planes/Features) opened expanded regardless of how often each is actually used.

**`feature_tree_panel.dart` converted from `StatelessWidget` to `StatefulWidget`**: holds `_widthFraction` (starts at the old 40% default), adjustable via a new drag handle - a 14px invisible touch target on the panel's trailing edge (`MouseRegion` + `GestureDetector.onHorizontalDragUpdate`, a `SystemMouseCursors.resizeLeftRight` cursor for desktop/web) with a visible 4×56 grip bar, clamped to `[0.28, 0.75]` of the available width so it can never shrink unreadable or grow to cover the whole viewport. Every row/section title (`Bodies`/`Planes`/`Features` headers and each child `ListTile`'s title/subtitle) now sets `maxLines: 1` + `TextOverflow.ellipsis` at reduced font sizes (14/13/11px) with `dense`/`VisualDensity.compact` throughout - wrapping is never acceptable for one line of tree structure regardless of width; the drag handle is the escape hatch for a user who wants to see a full name. `_buildBodiesSection`/`_buildPlanesSection` now default `initiallyExpanded: false` (derived, read-only sections most sessions don't need open); `_buildFeaturesSection` stays `true` (the one section every edit/rollback/delete action targets).

**Testing**: `flutter analyze lib test` - clean, same 3 pre-existing `avoid_print` infos. `feature_tree_panel_test.dart` updated - three existing tests that asserted on Body rows now expand the (now-collapsed-by-default) Bodies section first via a tap; +1 new test confirming Bodies/Planes start collapsed while Features starts expanded. All 8 tests genuinely executed, 8/8 passed (this file has no `flutter_scene` dependency). Full client suite: 245 passed, identical pre-existing 13-file GPU-blocked set, confirmed via `git worktree` diff.

## 2026-07-05 — Bug fix: hiding a Body broke any Plane/Sketch/Extrude still depending on it

On-device report, with exact repro: extrude a rectangle (Body A), create a Midplane on two of its faces, hide the rectangle's Extrude, sketch a new profile on the Midplane, extrude it - the new Extrude's mesh refresh 422'd with `missing_reference`, *and Body A itself vanished from the Build Tree*, even though nothing was wrong with it. Deleting the Plane "fixed" it. Reporter's own diagnosis ("suspect 2nd extrude tries to consume 1st... should build sequentially if DAG system is working??") correctly ruled out a sequencing bug - `build_feature_graph`'s topological order already processes the base Extrude before the Plane that depends on it.

**Root cause, confirmed by reading `compute_part_bodies`**: `hidden_feature_ids` (the client's plain Hide/Show state) and B4 true-rollback's own "pretend this Feature and everything after it doesn't exist yet" exclusion set were literally the same client-side set and the same backend parameter - `compute_part_bodies` skipped a named ExtrudeFeature *entirely*, "as if it weren't in the Part's history at all". Correct for rollback (a Feature genuinely shouldn't resolve while something it depends on is being edited out from under it); wrong for Hide/Show, which predates Create Plane (C2) and never anticipated a *different, still-visible* Feature legitimately referencing a hidden Body's own face. Once hidden, Extrude 1's Body no longer existed in the `bodies` dict the Midplane's `face_refs` needed - `resolve_subshape_from_bodies` raised `missing_reference`, and since the whole `/mesh` response is one all-or-nothing computation, that one failure blanked every Body, including the unrelated, perfectly fine Body A.

Presented the diagnosis and three fix-scope options (contain the blast radius only; fully separate the two concepts; both, staged) - **user chose the full fix**, accepting the one necessary trade-off it implies (below).

**Backend**: `compute_part_bodies`/`resolve_sketch_basis`/`resolve_create_plane`/every OCCT resolver in `create_plane.py` had their `hidden_feature_ids` parameter renamed to `excluded_feature_ids` (pure rename, no logic change) - it now only ever means "pretend this doesn't exist", never "cosmetically hidden". `get_part_mesh` (`router.py`) now takes two separate query params: `rollback_excluded_feature_ids` (fed into `compute_part_bodies` exactly as before - B4's true-rollback semantics, unchanged) and `hidden_feature_ids` (now purely cosmetic - every Body is always fully computed against the Part's real, unmodified history; a hidden Body is filtered out of *the response only*, afterward, by tracing its `body_id` back to its producing Feature via the existing `base_feature_id` helper).

**Accepted trade-off**: a Cut (or a Boss fused into an existing Body) owns no standalone Body of its own to filter - hiding a Cut Feature specifically no longer "un-subtracts" it the way the old shared mechanism happened to allow. This was never a designed capability (Hide/Show's own docstring only ever promised "drops a Body's contribution to the displayed solid"), just an accidental side effect of the two concepts being conflated - flagged, not hidden, and covered by an updated test (`test_stage9_extrude.py`) documenting the new expected behavior explicitly.

**Client** (`part_screen.dart`/`document_api_client.dart`): `_hiddenFeatureIds` (Hide/Show) and a new `_rollbackExcludedFeatureIds` (B4 rollback, populated by `_beginRollback`/cleared by `_endRollback` - no more stash-and-restore-around-the-edit needed, since rollback no longer touches `_hiddenFeatureIds` at all) are sent to `getPartMesh` as the two separate params. A new `_viewportHiddenFeatureIds` getter (union of both) drives every purely-client-side visibility concern the viewport itself doesn't need to distinguish reasons for (`_recomputeVisibleSketchGeometries`, `FeatureTreePanel.hiddenFeatureIds`) - the *backend* is the only place the two must stay apart.

**Testing (backend)**: new `tests/test_bugfix_hide_vs_rollback_exclusion.py` (real-OCCT, `ast.parse`-only in this sandbox) reproduces the exact on-device scenario end to end - hiding the base Extrude no longer breaks the Midplane/Sketch/second Extrude chain; the hidden Body is provably never deleted (un-hiding restores it byte-for-byte); `rollback_excluded_feature_ids` still correctly breaks the same chain (proving the fix didn't accidentally defang true-rollback too). Updated `test_stage9_extrude.py`/`test_stage11_edges.py`/`test_stage23_mesh_ids.py`/`test_stage_b1_subshape.py` for the parameter rename and the one genuinely-changed Cut-hide behavior. Full OCCT-free suite: **86 passed**, same 2 pre-existing OCCT-import failures, confirmed via `git worktree` diff against the pre-fix commit - identical 18-file OCCT-blocked set (19 with the new test file added).

**Testing (client)**: `flutter analyze lib test` - clean. `document_api_client_test.dart` +3 (`rollback_excluded_feature_ids` sent as its own repeated query param, never merged with `hidden_feature_ids`; no query string at all when both are empty). Full client suite: 245 passed, identical 13-file GPU-blocked set, confirmed via `git worktree` diff.

**Not verified here, needs on-device confirmation**: the exact reported repro (rectangle, Midplane, hide the rectangle's Extrude, sketch + extrude on the Midplane) now completes without error and shows both Bodies once un-hidden; a true B4 rollback onto an earlier Feature still correctly suppresses everything after it, including a Plane/Sketch/Extrude chain built on top.

## 2026-07-05 — On-device follow-ups: mode-toggle FAB during panels, hidden Bodies stay in the tree

Two more on-device reports against the same screen (the Create Plane confirm panel, screenshotted mid-Midplane) plus a third, larger request (Create Plane referencing a Plane, not just a Body face - e.g. offset from XY, midplane between a Plane and a Face) scoped separately below rather than built blind.

**1. The Orbit/Selection mode-toggle FAB was unreachable while the Extrude or Create Plane panel was open.** It used to be hidden for the panel's whole lifetime (`(_extrudeSketchFeature != null || _createPlaneActive || _toolbarOpen) ? null : ...`) purely so it wouldn't visually collide with the panel's own bottom-sheet content - but that also meant a user reviewing a Midplane/Extrude preview had no way to orbit the camera to look at it from another angle, or (for Extrude specifically) to leave Selection mode and back to pick a different target Body. Fixed: the FAB now only hides while the toolbar is open (the one case that's a genuine full-screen z-order conflict, per Stage 22 item 3); a `Padding` bumps it up 180px while a panel is active so it clears that panel's content instead. Extrude's own `selectionMode: _extrudeActive ? true : _selectionMode` forced-true override (which would have made the now-visible FAB a no-op toggle) is gone too - `_openExtrudePanel`/`_openExtrudePanelForEdit` now just set `_selectionMode = true` once, as a starting default, same as any other toggle.

**2. Hidden Bodies disappeared from the Build Tree's own Bodies section entirely**, since `get_part_mesh` (from the immediately preceding hide/rollback fix) still *dropped* a hidden Body's entry from the response rather than merely tagging it - the only way back to Show was remembering which Feature produced it and finding that Feature's own row instead. Backend: `BodyMeshResponse` gained a `hidden: bool` field; `get_part_mesh` now always includes every computed Body (this costs nothing extra - tessellation already happened before the old filter ever ran) and sets `hidden` via the same `base_feature_id` mapping instead of omitting the entry. Client: `BodyMeshDto.hidden` echoes it through; a new `_visibleBodies` getter (`_bodies` minus anything `hidden`) is what actually reaches the 3D viewport and the sketch ghost-edge overlay, while `_computedBodyIds`/`_bodyNames` (the Build Tree's own source) stay unfiltered so a hidden Body keeps its row, dimmed with an eye-slash icon exactly like a hidden Feature row already gets. Long-pressing a Body row now toggles it via a new `onBodyLongPress` (resolves the tapped `body_id` back to its owning Feature through `body_naming.dart`'s now-public `baseFeatureId`, then reuses the existing `_toggleFeatureVisibility`).

**Testing (backend)**: updated the same `hidden_feature_ids`-touching tests from the immediately preceding fix (`test_stage9_extrude.py`/`test_stage11_edges.py`/`test_stage23_mesh_ids.py`/`test_bugfix_hide_vs_rollback_exclusion.py`) for "tagged hidden, still present" instead of "absent" - the observable contract changed (a hidden Body's entry is now always there) even though none of the underlying fix's own reasoning did. 86/86 OCCT-free tests passed, identical 19-file OCCT-blocked set via `git worktree` diff.

**Testing (client)**: `flutter analyze lib test` - clean. `feature_tree_panel_test.dart` +4 (hidden Body row dimmed + eye-slash icon; visible Body has neither; long-press calls `onBodyLongPress`; long-press is a safe no-op when that callback is omitted). `document_api_client_test.dart` +2 (`BodyMeshDto.hidden` parses `true`/defaults `false`). Full client suite: 251 passed, identical 13-file GPU-blocked set, confirmed via `git worktree` diff.

**Not verified here, needs on-device confirmation**: the mode-toggle FAB is actually reachable and doesn't overlap either panel's content at real device sizes (the 180px clearance is an estimate, not measured against the panels' real rendered heights); a hidden Body's row in the tree is legible and its long-press reliably shows it again.

**Scoped separately, not built yet**: a third report asked for Create Plane's OFFSET_FACE/MIDPLANE to accept a Plane (a fixed reference plane, or an existing custom Plane) as a valid reference alongside a Body face - "offset from XY plane", "midplane between a Plane and a Face". This needs a new mixed reference type (a `SubShapeRef`-or-Plane-identifier, the same shape of problem C4's `PointRef` solved for THREE_POINTS) plus reconciling two currently-separate client selection subsystems (tapping a reference Plane today does something entirely different - starts a new Sketch on it - from tapping a Body face for Create Plane purposes) - deferred pending scoping, not attempted blind.

## 2026-07-05 — Prompt C5: Create Plane referencing a Plane

Builds the feature scoped-but-deferred at the end of the previous entry - user confirmed the full generalization ("Fixed planes + existing custom Planes", not just the three fixed reference planes).

**Backend**: new `PlaneRef` frozen dataclass (`app.document.models`) - a three-way union mirroring C4's `PointRef` (`face_ref: SubShapeRef | None`, `fixed_plane: Plane | None`, `plane_feature_id: str | None`, exactly one set). `CreatePlaneFeature.face_refs` is now `list[PlaneRef]` (was `list[SubShapeRef]`) - used by OFFSET_FACE/MIDPLANE/PARALLEL_TO_FACE_THROUGH_VERTEX alike. `create_plane.py` gained `_resolve_plane_ref(part, bodies, ref, excluded_feature_ids) -> ResolvedPlane`, the single dispatcher unifying all three reference kinds: a Body face via the existing OCCT `_resolve_planar_face` (now returning a plain-tuple `ResolvedPlane` instead of raw `gp_Pnt`/`gp_Dir`, dropping `gp_Vec` entirely in favor of plain-tuple arithmetic downstream), a fixed plane via the pure-Python `sketch_basis_for_plane`, or an existing Plane via a *recursive* call to `resolve_create_plane_from_bodies` against the same `bodies` accumulator already in hand - never a fresh `compute_part_bodies` call, avoiding infinite recursion (the same reasoning C3 already established for a custom-plane Sketch's own basis resolution). `resolve_offset_face_from_bodies`/`resolve_midplane_from_bodies`/`resolve_parallel_face_through_vertex_from_bodies` all now take `part`/`excluded_feature_ids` and dispatch through `_resolve_plane_ref` instead of assuming a bare Body face. Cycle-safety needs no extra code: a `plane_feature_id` can only ever name a Feature that already exists in the Part (Feature creation is append-only), so the `PlaneRef` reference graph is a DAG by construction - `graph.py`'s pre-existing `CycleError` stays the same defensive backstop it already was, not a new concern.

`graph.py`: new `_plane_ref_dependency(ref) -> str | None` - the one dependency edge a `PlaneRef` contributes (a face_ref's owning Extrude via `base_feature_id`; a plane_feature_id directly; `None` for a fixed_plane, which depends on nothing). `_create_plane_dependencies`'s OFFSET_FACE/MIDPLANE/PARALLEL_TO_FACE_THROUGH_VERTEX branches now build their dependency set from this instead of assuming every `face_refs` entry names a Body.

`schemas.py`/`router.py`: new `PlaneRefSchema` (mirrors `PointRefSchema`'s own "one of N optional fields" convention); `CreatePlaneFeatureCreate`/`Update`/`Response.face_refs` all changed to `list[PlaneRefSchema]`; new `_plane_ref_to_domain`/`_plane_ref_to_schema` conversion helpers; new `_validate_plane_ref(part, ref)` enforcing exactly-one-of-three-fields-set (422), a `face_ref`'s `shape_type == FACE` (422, unchanged from pre-C5), and a `plane_feature_id`'s existence as a real `CreatePlaneFeature` in this Part (400, mirroring `_validate_sketch_feature_payload`'s own convention) - runs *before* `resolve_create_plane`, so a malformed/dangling reference is this function's own structured error rather than an `AttributeError`/`AssertionError` out of `_resolve_plane_ref`. `_validate_create_plane_payload` now takes `part` and calls `_validate_plane_ref` per `face_refs` entry in place of the old direct `shape_type` check. `_describe_plane_ref(ref) -> dict` replaces the old `body_id_a/index_a/body_id_b/index_b` shape `_faces_not_parallel`'s error detail used, with `{"kind": "face"|"fixed_plane"|"create_plane", ...}` per side (`ref_a`/`ref_b`) - confirmed via grep no client code parsed those old sub-fields, only `.type`, so this is a safe shape change.

**Testing (backend)**: `test_stage_c3_graph.py`/`test_stage_c2_plane_geometry.py` (pre-existing, pure-Python) updated to wrap their bare `SubShapeRef` `face_refs` entries in `PlaneRef(face_ref=...)` per the new type - both fully re-verified, no logic change needed. New `test_stage_c5_graph.py` (pure-Python, genuinely executed) covers `_plane_ref_dependency`'s fixed-plane (no dependency) and plane-feature-id (direct dependency) cases end to end, plus cascade-delete of a Plane a Midplane is anchored to. New `test_stage_c2_create_plane.py`/`test_stage_c4_create_plane.py` HTTP payload fixtures updated to the new `{"face_ref": {...}}` wrapper shape (previously bare `{"body_id": ..., "shape_type": "face", "index": ...}`, now rejected by `_validate_plane_ref` as "no field set"). New `test_stage_c5_create_plane.py` (real-OCCT, `ast.parse`-only in this sandbox) covers OFFSET_FACE from a fixed plane and from an existing Plane, MIDPLANE mixing every pairing of face/fixed-plane/existing-Plane (including the `faces_not_parallel` rejection's new `{"kind": ..., "plane": ...}` detail shape), PARALLEL_TO_FACE_THROUGH_VERTEX from a fixed plane, every `_validate_plane_ref` rejection (no field, two fields, unknown `plane_feature_id`, `plane_feature_id` naming a non-Plane Feature, non-FACE `face_ref`), and a PATCH re-pointing an existing Plane from a fixed plane to another Plane. Full OCCT-free suite: **90 passed** (86 prior + 4 new `test_stage_c5_graph.py`), zero new `pyflakes` warnings across every touched file.

**Client**: new `PlaneRefDto` (`document_api_client.dart`, mirrors `PointRefDto`'s shape) - `FeatureDto.faceRefs` and `createCreatePlaneFeature`/`updateCreatePlaneFeature`'s `faceRefs` parameter both changed from `List<SubShapeRefDto>` to `List<PlaneRefDto>`. `SelectionEntityKind` gained `referencePlane`/`createPlane`; `SelectionEntityRef` gained `referencePlaneKind`/`planeFeatureId` fields (equality/hashCode/toString all updated) - every exhaustive `switch (entity.kind)` in the codebase (`part_viewport.dart`'s `_syncSelectedEntityNodes`/`_buildEntityHighlightNode`, `selection_list_drawer.dart`'s `_iconFor`/`_labelFor`) got explicit cases for both (a plane's highlight is its own quad rendering, not a mesh-overlay Node, so these are no-ops/null by design). `PartScreen._onPlaneTap`/`_onCreatePlaneFeatureTap` now check `_selectionMode` first: while active, a plane tap toggles a `referencePlane`/`createPlane` entity into `_selectedEntities` (via the existing `_toggleSelectedEntity`) instead of always opening its own context sheet - `PartViewport` generalized to highlight a plane whose `SelectionEntityRef` is present in `selectedEntities`, in addition to (not replacing) its pre-existing single-value `selectedPlane`/`selectedCreatePlaneFeatureId` "context sheet is open" highlight. `selection_actions.dart`'s `contextActionsFor` generalized its single-face/two-face/face-plus-vertex Create Plane rules to a new `planeLikeCount` (faces + referencePlanes + createPlanes) - deliberately kept separate from `hasFace`/`faces` themselves, so the unrelated Chamfer/Fillet/`hasEdge && hasFace` rules stay strictly Body-only. `part_screen.dart`'s `_onCreatePlaneTapped`/`_openCreatePlanePanel` mirror the same generalization, plus a new `_planeRefDtoFor(SelectionEntityRef) -> PlaneRefDto` (mirrors `_pointRefDtoFor`) converting whichever of the three kinds was selected.

**Testing (client)**: `flutter analyze` - clean, same 3 pre-existing `avoid_print` infos. `document_api_client_test.dart`: existing `face_refs` fixtures/assertions updated to the new `PlaneRefDto` shape; +4 new cases (three `PlaneRefDto` round-trips, one `createCreatePlaneFeature` wire-format test for a MIDPLANE mixing a `fixedPlane` and a `planeFeatureId`) - **39/39 genuinely executed and passed** (this file has no `flutter_scene` dependency). `selection_actions_test.dart` +7 cases (lone fixed plane/lone existing Plane both offer enabled Create Plane; two fixed planes, a fixed-plane+face, and a fixed-plane+existing-Plane all offer enabled Midplane; a fixed-plane+Vertex offers enabled Parallel-to-Face-Through-Vertex; a plane mixed with an Edge+Face still falls through to the unaffected full Chamfer/Fillet/Create-Plane set) and `selection_hit_test_test.dart` +4 cases (`SelectionEntityRef` equality/inequality for the two new kinds) - both `flutter analyze`-clean but blocked from execution by the same pre-existing `flutter_scene`/`flutter_gpu` stable-channel mismatch every GPU-touching test file in this project hits (confirmed: this exact file set was already blocked before this prompt touched anything). Full client suite: 251 passed unaffected files + the 4 new `document_api_client_test.dart` cases genuinely executed, same pre-existing GPU-blocked file set (no new blocks introduced).

**Not verified here, needs on-device confirmation**: selecting a fixed reference plane (or an existing Plane) alongside a Body face, or two planes together, while in Selection mode actually surfaces the right Create Plane action and produces correct geometry; the plane highlight while selected (as opposed to "context sheet open") renders visibly distinct in the viewport.

## 2026-07-05 — Bug fix: planes weren't actually reachable from Selection mode's cursor at all

User follow-up question ("are planes selectable with cursor, is dynamic highlight working?") caught two real gaps the immediately preceding C5 entry got wrong.

**Gap 1 (discoverability)**: the "Add" FAB's Feature-picker "Plane" entry (`_startPlanePicker`) never switched the viewport into Selection mode - a tap after opening it from Orbit mode silently orbited the camera instead of selecting anything, since Orbit mode's own tap handler (`_handleTap`) has nothing to do with the selection system. Its hint text was also stale, predating both C4's edge/vertex/three-point combos and C5's plane references. Fixed: `_startPlanePicker` now sets `_selectionMode = true`; hint reworded to `'Select a face or plane (or two, for a midplane) to create a plane'`.

**Gap 2 (the real bug)**: C5's own `_onPlaneTap`/`_onCreatePlaneFeatureTap` Selection-mode gating (`if (_selectionMode) { _toggleSelectedEntity(...) }`) was **dead code that could never run**. Tracing `PartViewport`'s pointer dispatch (`_onPointerEnd`) shows the split is architectural, not incidental: while `selectionMode` is true, a confirmed tap calls `_commitSelection()` and returns immediately - it never falls through to `_handlePointerEnd`/`_handleTap`, which is the *only* place `onPlaneTap`/`onCreatePlaneTap` are ever invoked. So those two `PartScreen` callbacks are Orbit-mode-only, full stop; `_selectionMode` is always `false` by the time either of them runs. Planes were never actually selectable via the crosshair cursor, and there was no dynamic hover highlight for them either - the entire C5 client "selection-mode gating" story in the previous entry was aspirational code that never executed.

**Real fix**: reference planes and created Planes now flow through the *same* cursor/hover/commit pipeline every mesh entity already uses, instead of the separate always-Orbit-mode tap path:
- `ReferencePlaneHit`/`CreatePlaneHit` (`reference_planes.dart`/`create_plane_geometry_3d.dart`) gained a `rayT` field (the ray parameter their intersection already computed internally but discarded) so a plane hit can be depth-compared against a mesh/sketch hit.
- New `PartViewportState._hoverHitTestPlanes(ray) -> HoverHit?` wraps `hitTestReferencePlanes`/`hitTestCreatePlanes` (same reference-planes-keep-first-claim precedence `_handleTap` already used) as a `HoverHit`.
- `_recomputeHover()` (the Selection-mode crosshair's own hit-test, previously `hitTestBodies`-only) now also computes this plane hit and keeps whichever of the two has the smaller `rayT` - so a Body face genuinely in front of a plane still wins, and vice versa.
- `_commitSelection()` needed *no* change - it already generically calls `onSelectionToggle(hit.entity)` regardless of kind, so once `_hoverHit` could be a plane, toggling one into `_selectedEntities` just worked.
- `_buildEntityHighlightNode`'s referencePlane/createPlane cases (previously `return null` - "never reached in practice", which was true but for the wrong reason) now build a real highlight quad (new `_buildPlaneHighlightNode`, reusing `doubleSidedQuadBuffers`/`createPlaneTransform` at the same `_hoverColor` amber tint every mesh entity's hover uses) - so hovering a plane now shows the same dynamic highlight, as a translucent overlay on top of the plane's own always-rendered quad.
- `_onPlaneTap`/`_onCreatePlaneFeatureTap` (`part_screen.dart`) had their dead `if (_selectionMode)` branches removed and doc comments corrected to state plainly that they're Orbit-mode-only - the real Selection-mode path is `PartViewport`'s own hover/commit pipeline now, not these callbacks.

**Testing**: `flutter analyze` - clean, same 3 pre-existing `avoid_print` infos. No test constructed `ReferencePlaneHit`/`CreatePlaneHit` directly (both hit-test functions are only exercised via their public `hitTestReferencePlanes`/`hitTestCreatePlanes` entry points in existing tests, which only read `.plane`/`.point`/`.featureId`, never `.rayT`), so the new field is purely additive - `document_api_client_test.dart`'s 39/39 unaffected and still genuinely passing. The core fix (`_recomputeHover`'s merge, `_buildEntityHighlightNode`'s new plane cases) lives entirely in `part_viewport.dart`, which - like every `flutter_scene`-touching file in this project - can't be exercised by a widget test in this sandbox; verified by careful manual trace of the pointer-dispatch code path instead (the same rigor that caught the original bug), not by a runnable test.

**Not verified here, needs on-device confirmation**: hovering a plane with the crosshair actually shows the amber highlight; a plane in front of/behind a Body face along the cursor ray resolves to the visually-nearer one; the full plane+face/plane+plane Create Plane flow now genuinely works end to end via the crosshair (as opposed to just being reachable in principle, which is as far as this entry's own verification could go).

## 2026-07-05 — Prompt D: Fillet

User confirmed the C5 plane-selection fix was working on-device and asked to start the next phase - provided the full Prompt D (Fillet) and Prompt E (Chamfer) briefs directly rather than leaving scope to be inferred, so this builds exactly what those specify: multi-edge Fillet, one shared radius across all selected edges (v1 scope, no per-edge radii/variable fillets), with a resolved design decision on the one open fork the brief itself flagged.

**Body-identity decision (per the brief's own instruction)**: Fillet *modifies* a Body's shape rather than creating a new one, so it keeps the target Body's existing `body_id` in place rather than minting a new one - preserves A1's guarantee that any later Boss/Cut `target_body_ids` entry, or `SubShapeRef`/Fillet `edge_refs` entry, that already named this Body keeps resolving to it after a Fillet is applied.

**Backend**: new `FilletFeature` (`app.document.models`) - `edge_refs: list[SubShapeRef]` (all must be `shape_type=EDGE`), `radius: float`, `produces -> BODY`, `produces_solid_geometry -> True`. New `app/document/fillet.py` module (mirrors `create_plane.py`'s own separation from `router.py`): `resolve_fillet_from_bodies(bodies, feature)` checks every `edge_ref` shares one `body_id` (`mixed_body_selection` structured error on violation - OCCT's `BRepFilletAPI_MakeFillet` operates on one solid at a time), resolves each edge, runs `BRepFilletAPI_MakeFillet.Add(radius, edge)` per edge then `.Build()`, and raises a structured `fillet_failed` (never an uncaught OCCT exception) if `IsDone()` is false. `resolve_fillet(part, feature, excluded_feature_ids)` is the fresh entry point the router uses for validation - computes `bodies` *excluding the Feature's own id* in addition to whatever the caller already excludes, so validating an edit to an existing Fillet's radius/edges is checked against the Body's shape *before* this Fillet's own (about-to-be-replaced) effect, not stacked on top of it (a Fillet modifies in place, so re-resolving against its own prior output would double-apply it).

`extrude.py`'s `compute_part_bodies` (the one place every Body actually gets computed) now dispatches a `FilletFeature` in its own per-feature loop - via a function-local `from app.document.fillet import resolve_fillet_from_bodies` import, breaking the same shape of circular-import problem `create_plane.py`/`extrude.py` already solved this way (`fillet.py` needs `compute_part_bodies`/`resolve_subshape_from_bodies` from `extrude.py` at module level, so `extrude.py` can't import `fillet.py` back at *its* own module level) - and simply reassigns `bodies[body_id]` to the post-fillet shape, keeping the same key. A Fillet that can't currently be resolved (topology drifted since creation) is skipped with a warning rather than raising, mirroring the resilience `compute_part_bodies` already gives a Cut naming a Body that no longer exists - the router's own create/update endpoints validate eagerly instead, so this fallback only matters for topology drift after the fact, not a malformed request ever reaching persistence.

`graph.py`: `FilletFeature` depends on `base_feature_id` of every `edge_refs` entry's `body_id` (deduplicated via a set) - deleting the Extrude that created a Body a Fillet modifies now correctly cascades the Fillet with it.

`schemas.py`/`router.py`: `FilletFeatureCreate`/`Update`/`Response` (mirrors `ExtrudeFeatureResponse`'s simplicity - no derived geometry field the way `CreatePlaneFeatureResponse` needs one, since a Fillet's "geometry" is the whole Body's new shape, not a simple tuple). New `POST/PATCH /parts/{id}/fillet-features[/{feature_id}]`, unlocked from the start (same instruction as C2/C5 - B4 already established "any Feature can be edited" generically). `_validate_fillet_edge_refs` (non-empty, every entry `shape_type=EDGE` - payload-shape checks, 422) and `_validate_fillet_radius` (mirrors `_validate_extrude_distances`'s plain-400 convention) run before `resolve_fillet`, so a malformed payload never reaches the OCCT resolver at all.

**Testing (backend)**: new `test_stage_d_graph.py` (pure-Python, genuinely executed) covers the dependency edge (including the `#N` split-suffix-stripping case and cascade-delete) and a defensive "edges spanning two Bodies still builds *some* dependency edges" case (the mixed-body rejection itself is an OCCT-resolution-time check, not a graph-construction one). New `test_stage_d_fillet.py` (real-OCCT, `ast.parse`-only in this sandbox per the recurring caveat) covers a full-box 12-edge fillet succeeding, the filleted Body keeping its `body_id`, the mesh's geometry actually changing, `mixed_body_selection`/`fillet_failed`/`radius<=0`/empty-`edge_refs`/non-EDGE-`shape_type`/unknown-`body_id` rejections, a PATCH updating the radius (and correctly re-validating a merged candidate without half-updating on failure), editing an earlier Fillet after a later unrelated Extrude exists (proving `resolve_fillet`'s self-exclusion works), and cascade-delete taking the Fillet down with its owning Extrude. Full OCCT-free suite: **95 passed** (90 prior + 5 new `test_stage_d_graph.py`), zero new `pyflakes` warnings across every touched/new file.

**Client**: `FeatureDto` gained `edgeRefs`/`radius` (plain `SubShapeRefDto` list, never a `PlaneRefDto` - a Fillet only ever references Body edges); new `createFilletFeature`/`updateFilletFeature` on `DocumentApiClient`. `SelectionContextAction` gained `disabledReason` (shown as a `Tooltip` on the button when set) - "explain, don't silently omit" for a selection whose *kind* is right (edges) but a specific property isn't (spanning more than one Body), as opposed to every other still-scaffolded disabled action, which has no reason text at all. `selection_actions.dart`'s `contextActionsFor` gained a new "one or more edges, nothing else" branch: enabled (for both Fillet and, per Prompt E's own instruction to reuse the exact same check, Chamfer) when every edge shares one `bodyId` (new shared `_allSameBody` helper), disabled with a reason otherwise - checked before the old generic `hasEdge` catch-all, which now only ever fires for an edge+vertex mix that doesn't match the dedicated Normal-to-Edge-Through-Vertex shape. New `FilletPanel` (mirrors `CreatePlanePanel`'s Confirm/Cancel/live-preview-debounce shape exactly, simpler - one always-shown radius field, no per-mode branching since Fillet has only the one construction method). `part_screen.dart`: full create/edit/confirm/cancel flow mirroring Create Plane's own (`_onFilletTapped`/`_openFilletPanel`/`_openFilletPanelForEdit`/`_onFilletRadiusChanged`/`_confirmFillet`/`_cancelFillet`), `_filletActive` gates the panel/FAB/selection-drawer visibility everywhere `_createPlaneActive` already did (6 call sites, all updated identically); `_onFeatureTap` gained a `'fillet'` branch. `feature_tree_panel.dart`'s `featureDisplayName`/icon switches gained explicit `'fillet'` cases (the old fallback silently mislabeled an unrecognized type as "Sketch" - would have shown a Fillet row as "Sketch N" without this).

**Testing (client)**: `flutter analyze` - clean, same 3 pre-existing `avoid_print` infos. `document_api_client_test.dart` +5 (fillet Feature JSON parsing, `createFilletFeature`/`updateFilletFeature` wire format) - **44/44 genuinely executed and passed**. New `fillet_panel_test.dart` (9 cases, mirrors `create_plane_panel_test.dart`'s own Confirm-enablement coverage) - **confirmed genuinely executed for real** (`fillet_panel.dart` has zero `flutter_scene` dependency, same as `create_plane_panel.dart`), 9/9 passed. `selection_actions_test.dart` +3 new cases plus one existing case's expectation corrected (a same-Body edge selection now legitimately returns `enabled: true` for Chamfer/Fillet, not the old always-disabled placeholder - same "genuinely different behavior, not a bug" precedent C2's own history already set for its first enabled Create Plane case) - `flutter analyze`-clean but blocked by the same pre-existing `flutter_scene`/`flutter_gpu` mismatch every GPU-touching test file in this project hits. Full client suite: 269 passed (251 prior + 5 + 9 + a handful from `sketch_api_client_test.dart`'s own unrelated count drift between runs), identical pre-existing GPU-blocked file set (`create_plane_panel_test.dart` reproduced its own previously-documented batch-run flakiness - confirmed passing 8/8 combined with `fillet_panel_test.dart` in an isolated run - not a regression this prompt introduced).

**Not verified here, needs on-device confirmation (this prompt's own stop condition, per its brief)**: selecting 1+ edges on one Body enables Fillet; the panel's live preview updates as the radius changes; a cross-body edge selection is visibly blocked (button disabled + tooltip) rather than silently wrong; the resulting fillet renders correctly and survives a later edit via rollback. Per the brief's own stop condition: do not start Prompt E (Chamfer) until this comes back positive.

## 2026-07-05 — Bug fixes: Prompt D on-device feedback (mesh refresh, edit-mode rollback, Body context menu)

User's on-device test of Prompt D reported four problems from the same session as the entry above; three are fixed here, one is flagged back as a scope question rather than guessed at.

**Fix 1 — live preview and post-confirm geometry never appeared (`part_screen.dart`)**: `_openFilletPanel`, `_ensureFilletRadiusUpdated`, and both branches of `_cancelFillet` only ever called `await _refreshFeatures()` after creating/patching/deleting the preview `FilletFeature` - and `_refreshFeatures()` only refetches the Feature list (`listFeatures` + `_recomputeCreatePlaneGeometries()`), never the mesh. Mesh data only gets refetched by the separate `_refreshMesh()`, which is why toggling an unrelated Hide/Show (a call path that *does* call `_refreshMesh()`) was the only thing that ever made a fillet visible - exactly the user's own diagnosis ("hiding the fillet feature seems to prompt a rebuild"). `_ensureExtrudeFeatureExists` already gets this right (`await _refreshMesh()` at its own end); Fillet's four call sites now do the same, each with `await _refreshMesh();` added immediately after its existing `_refreshFeatures()` call. Create Plane's own equivalent methods are correctly untouched - a Plane doesn't produce mesh geometry, so they never needed this.

**Fix 2 — editing an existing Fillet showed the already-filleted body, not the rolled-back one**: `_onFeatureTap`'s B4 preamble already rolls back Features *after* the tapped one via `_beginRollback(featureIdsAfter(...))`, but a Fillet modifies its own target Body's shape *in place* - so the tapped Fillet's own contribution was never excluded, and the edit panel opened showing post-fillet topology with none of the original edges left to re-select or deselect. `_openFilletPanelForEdit` is now `async` and additionally calls `await _beginRollback({feature.id})` (the set is additive, so this stacks fine on top of whatever the preamble already began) - `_confirmFillet`/`_cancelFillet`'s existing `await _endRollback()` call already clears the *entire* `_rollbackExcludedFeatureIds` set once the panel closes, so no other method needed to change to correctly re-apply the Fillet afterward.

**Fix 3 (side note) — Body row long-press now opens a context menu instead of directly toggling Hide/Show**: mirrors the existing Feature long-press pattern. New `BodyContextMenuAction` enum + `showBodyContextMenu` (`feature_context_menu.dart`) - a one-entry bottom sheet (Hide/Show only; a Body can't be renamed/deleted directly, that's Feature-scoped) in the same visual style as `showFeatureContextMenu`, deliberately kept as its own enum/function rather than reusing `FeatureContextMenuAction` so a later stage can grow Body-specific entries (e.g. "Select all faces") without touching Feature's menu. `_onBodyLongPress` now shows this menu and dispatches `toggleVisibility` to the same `_toggleFeatureVisibility` it already called directly.

**Not fixed - flagged as a scope question**: corner treatment when 2+ selected edges share a vertex. OCCT's `BRepFilletAPI_MakeFillet` blends a shared vertex into one smooth rounded corner when all edges are added to the *same* builder call, which is what `resolve_fillet_from_bodies` already does for a multi-edge Fillet Feature - this is a real, distinct-from-buggy OCCT behavior, not a defect in the resolver. The user wants a choice between corner treatments exposed in the FilletPanel itself, which is a genuine v2-scope design question (which OCCT `ChFi3d_FilletShape` corner-continuity mode, or "blend" vs. "independent" edges) the original Prompt D brief never specified - not implemented here pending a scoping decision.

**Testing**: `flutter analyze` - clean, same 3 pre-existing `avoid_print` infos, no new warnings. `fillet_panel_test.dart` (9/9) and `document_api_client_test.dart` (44/44) both re-run and still genuinely passing (neither touches the changed `part_screen.dart`/`feature_context_menu.dart` code directly, but confirm no collateral breakage in the types they do share). `selection_actions_test.dart` still blocked from running standalone by the same pre-existing `flutter_scene`/`flutter_gpu` sandbox mismatch documented in every prior entry - not a new regression, and unrelated to any file this fix touches (`part_screen.dart`/`feature_context_menu.dart` aren't in its import chain). `part_screen.dart` and `feature_context_menu.dart` can't be exercised by a widget test in this sandbox at all (same standing `flutter_scene` limitation); verified by direct code trace against the already-working `_ensureExtrudeFeatureExists`/`_beginRollback`/`_endRollback`/`showFeatureContextMenu` patterns instead.

**Not verified here, needs on-device confirmation**: the live radius preview now updates in the viewport as it's typed; a confirmed Fillet renders immediately without needing a Hide/Show toggle; editing an existing Fillet shows the pre-fillet body with its original edges selectable/deselectable; long-pressing a Body row shows the context menu rather than immediately toggling visibility.

## 2026-07-05 — Follow-up: Fillet selection filter, "Add" FAB entry, live edge editing, and the corner-treatment investigation

User follow-up on the same on-device feedback thread, with three asks plus explicit permission to ask a clarifying question first where scope genuinely needed one ("if classification is needed, ask") - asked before writing any code, then implemented per the answers.

**Clarified before implementing**: (1) tapping a Face while picking edges for Fillet should select that face's *whole boundary edge loop* at once (not stay inert) - this needed new backend data (no face→edge adjacency existed), so confirming this was worth building before doing it; (2) whether "corners should always be rounded like the 3-edge picture, not the 2-edge one" needs an auto-expansion fix or is actually correct-but-different OCCT geometry - user chose "investigate first, don't assume" over guessing at either.

**Investigation finding (item 3, no code change)**: `resolve_fillet_from_bodies` already uses the textbook-correct approach - one `BRepFilletAPI_MakeFillet` builder, every selected edge added via `.Add(radius, edge)` before one `.Build()` call, which is exactly what makes OCCT blend a shared vertex into a smooth corner patch when *all* edges meeting there are included. There is no separate "corner type" switch this is missing: `BRepFilletAPI_MakeFillet`'s only shape-level option, `ChFi3d_FilletShape` (Rational/QuasiAngular/Polynomial), controls a fillet's cross-sectional profile curve, not vertex/corner blending - it cannot make a 2-of-3-edges selection look like the 3-edge case, because the third, unfilleted edge is still there and still sharp; the surface transition where it meets the two fillet surfaces is unavoidably different (and reasonably called "worse-looking") than the fully-blended 3-way patch, on purely geometric grounds. **Conclusion: this is not a resolver bug or a missing kernel feature - it's the correct, differently-shaped result of filleting fewer than all the edges around a vertex.** (Not empirically re-verified against real OCCT output in this sandbox - `OCC` isn't importable here, same standing limitation as every other OCCT-touching test in this project; this is a reasoned conclusion from the OCCT API's documented behavior and this resolver's existing, already-correct usage of it, not a runtime observation.) The practical fix is therefore reliable *selection* of a complete edge set, which is what the Face-tap feature below is actually for - not a rendering/geometry change.

**Backend (items 1/2 support - face→edge adjacency)**: new `MeshData.face_edge_ids: list[list[int]]` (`app/document/mesh.py`) - per-face boundary edge ids, dense in the same `TopExp_Explorer(shape, TopAbs_FACE)` order `face_ids` already uses. Refactored the shared "assign dense ids, skipping degenerate edges" logic out of `_extract_edges` into a new `_dense_edge_ids(shape)` helper, reused by both `_extract_edges` and the new `_extract_face_edge_ids` - critical so a `face_edge_ids` entry's edge ids and `edge_ids` itself always agree on the same id space (an edge's id must be identical whichever list it's read from). `MeshVertexData`/`_mesh_vertex_data` (`schemas.py`/`router.py`) pass `face_edge_ids` through to the wire, defaulted to `[]` for the same backward-compatibility reason `face_ids`/`edge_ids`/`topology_vertex_ids` already are.

**Client (items 1/2 - filter, FAB entry, Face-tap-selects-loop, live edge editing)**:
- New `PartScreen._filletSelectionFilter` (`vertex: false, edge: true, face: true, body: false, sketchPoint/sketchLine: false`) - locked in via `_selectionFilterOverrides.push`/`.pop()` for the *entire* Fillet flow now, both while picking (new `_filletPickerActive`, see below) and while the panel is open (`_filletActive`), not just at the moment of the original button tap.
- New `FeaturePickerAction.fillet` + enabled `feature_picker_sheet.dart` "Fillet" entry (was a disabled placeholder) wired to new `PartScreen._startFilletPicker()`/`_cancelFilletPicker()` - mirrors `_startPlanePicker`'s "Add FAB → guided Selection-mode picking, no Feature yet" shape (own top banner + Cancel, PopScope/background-tap "never mind" handling alongside `_sketchPickerActive`/`_planeSelectionMode`'s own), handing off to the existing `_onFilletTapped`/`_openFilletPanel` once 1+ edges are actually picked and the (now-enabled) `SelectionContextPanel` Fillet button is tapped - the filter-override hand-off is exactly one pop before `_openFilletPanel`'s own push, never zero or two layers active at once.
- **Fillet's edge selection is now live for the panel's whole session**, mirroring Extrude's live target-body picking exactly (previously: eager-create-once, then `_selectedEntities` was hard-cleared and never touched again, so - contrary to the "edges can't be added/removed" bug reported in the prior on-device round - there was actually no live-editing wiring at all once the earlier rollback-view bug was fixed). `_openFilletPanel`/`_openFilletPanelForEdit` now seed `_selectedEntities` with the current/existing edges (rather than clearing to `{}`) and push `_filletSelectionFilter`; every subsequent edge tap (`_toggleSelectedEntity`) or Face-loop tap (`_toggleFilletFaceEdges`, see below) reschedules a new `_scheduleFilletPreview()` debounce into the generalized `_ensureFilletFeatureExists(radius, edgeRefs)` (was `_ensureFilletRadiusUpdated(radius)` only) - skips the PATCH entirely while `edgeRefs` is empty (a normal mid-edit state, not an error) rather than surfacing the backend's `422`. `_confirmFillet`/`_cancelFillet` both pop the filter override alongside their existing cleanup.
- New `PartScreen._toggleFilletFaceEdges` - `_toggleSelectedEntity`'s Face special-case while `_filletActive`/`_filletPickerActive`: resolves the tapped face's `BodyMeshDto.mesh.faceEdgeIds[faceIndex]` and toggles the *whole loop* as one unit (fully selected → all removed; otherwise every not-yet-selected edge in the loop is added) - lets a user reliably build a vertex-complete edge selection (e.g. every edge of a box's top face) in one tap, which is the actual, buildable answer to "I want the fully-rounded corner look" the investigation above concluded a kernel switch can't provide.
- `MeshDto.faceEdgeIds` (`document_api_client.dart`) parses the new `face_edge_ids` wire field, defaulted to `[]` for older fixtures.

**Testing**: backend - OCCT-free suite still **95 passed** (`test_stage23_mesh_ids.py` itself needs `OCC`/`TestClient`, so its own new `face_edge_ids` cases are `ast.parse`/`pyflakes`-clean only in this sandbox, same standing caveat as every other OCCT-touching test file; added 5 new cases there: face count matches, every box face has 4 edges, the id space matches `edge_ids` exactly, every edge is shared by exactly 2 faces, and the placeholder-mesh case also includes it). Client - `flutter analyze` clean (same 3 pre-existing `avoid_print` infos); `document_api_client_test.dart` +2 (`faceEdgeIds` parses / defaults to `[]`) - **46/46 genuinely executed and passed**; `fillet_panel_test.dart` unaffected, still 9/9; `feature_picker_sheet_test.dart` updated (Fillet moved out of the disabled-tiles case into its own "resolves `FeaturePickerAction.fillet`" case) - **4/4 genuinely executed and passed**. `part_screen.dart`'s own new logic (`_toggleFilletFaceEdges`, the live-editing rewire, the picker banner) can't be exercised by a widget test in this sandbox (standing `flutter_scene` limitation) - verified by direct code trace against the already-working `_openExtrudePanel`/`_scheduleExtrudePreview`/`_startPlanePicker` patterns it mirrors instead.

**Not verified here, needs on-device confirmation**: starting Fillet from the "Add" FAB actually reaches the picker banner and hands off correctly once edges are picked; tapping a face during Fillet picking/editing really does select its whole edge loop and visibly reflects that in the selection; edges can now genuinely be added to/removed from an in-progress or being-edited Fillet with the preview updating live; the filter staying edge/face-only for the whole flow doesn't block any selection the user actually needs mid-flow.

## 2026-07-05 — Follow-up bug fixes: planes still selectable during Fillet, and the "Add" FAB entry didn't fly up the panel

User confirmed the previous follow-up was "big improvement" and reported two remaining bugs from the same on-device pass.

**Bug 1 - reference/created Planes stayed selectable while picking edges for Fillet**: root cause was that `SelectionFilterState` never had a field for planes at all - C5 shipped `_hoverHitTestPlanes` (`part_viewport.dart`) with no filter check whatsoever, so every picking mode's filter, including the previous entry's `_filletSelectionFilter`, had nothing to actually turn off. New `SelectionFilterState.plane` (defaults `true`, preserving every existing call site's current behavior) gates both reference-plane and created-Plane hits in one field, not a separate pair - no picking mode has ever needed to tell the two apart, and C5's own `contextActionsFor` already treats them as one interchangeable "plane-like" category. `_hoverHitTestPlanes` now returns `null` immediately when `!widget.selectionFilter.plane`. `_filletSelectionFilter` sets `plane: false` alongside its existing `vertex`/`body`/`sketchPoint`/`sketchLine: false`. No View-submenu toggle added for this (none of vertex/edge/face/body/sketchPoint/sketchLine's own toggles cover it either at the picking-mode level, just the global menu) - out of scope for this fix, which is specifically about Fillet's own locked-down filter actually being complete.

**Bug 2 - the "Add" FAB's Fillet entry only showed a picker banner, not the panel**: the previous follow-up's `_startFilletPicker` opened a guided *picking* mode (banner + Cancel) and deferred opening `FilletPanel` itself until edges were picked and the ambient `SelectionContextPanel` button was tapped - an extra, non-obvious step the user correctly read as "this didn't do anything yet." Fixed by unifying the two Fillet entry points: `_openFilletPanel` (both the FAB's zero-edges case and the ambient-button's already-has-edges case) now opens `FilletPanel` immediately either way, mirroring how `_openExtrudePanel` already shows `ExtrudePanel` right away with no target Bodies picked yet rather than gating it behind a separate pre-panel picking phase. `_startFilletPicker` is now a one-line `_openFilletPanel(edgeEntities: const [])`; the separate `_filletPickerActive` flag, its own banner/Cancel, and the pop-then-push filter hand-off in `_onFilletTapped` are all gone - `_filletActive` alone now covers the whole session, exactly like `_extrudeActive`/`_createPlaneActive` already do for their own panels. Since a FilletFeature can't exist with zero edges, `_ensureFilletFeatureExists` (previously PATCH-only) was generalized to create-or-update - mirrors `_ensureExtrudeFeatureExists`'s own branching exactly - so the Feature is created lazily on the first edge/face-loop pick instead of eagerly on open. A new top banner ("Select edges (or a face) to fillet" + Cancel) shows only while `_filletActive && _previewFilletFeatureId == null` (panel open, nothing picked yet), replacing the old picker-only banner; its Cancel is the same `_cancelFillet` the panel's own Cancel button already uses. The back-gesture (`PopScope`) interception added for the old picker mode was removed rather than retargeted at `_filletActive` - Extrude/Create Plane's own always-open panels never intercepted the back gesture either (Confirm/Cancel are the only way out), so this keeps Fillet consistent with that existing precedent instead of adding a one-off exception.

**Testing**: `flutter analyze` - clean, same 3 pre-existing `avoid_print` infos. `selection_filter_test.dart` +4 new cases for the `plane` field (defaults true, independently settable via `copyWith`, participates in equality) - genuinely executed (no `flutter_scene` dependency), now 10/10. `fillet_panel_test.dart` (9/9), `document_api_client_test.dart` (46/46), `feature_picker_sheet_test.dart` (4/4), and `create_plane_panel_test.dart` (12/12) all re-run and still genuinely passing - none touch the changed `_hoverHitTestPlanes`/Fillet-flow-merge logic directly, but confirm no collateral breakage in the shared types/patterns they do exercise. `part_viewport.dart`'s `_hoverHitTestPlanes` change and `part_screen.dart`'s Fillet-flow merge can't be exercised by a widget test in this sandbox (standing `flutter_scene` limitation) - verified by direct code trace instead, cross-checked against the already-working `_openExtrudePanel`/`_ensureExtrudeFeatureExists` patterns both now mirror exactly.

**Not verified here, needs on-device confirmation**: reference/created Planes are no longer hoverable/selectable while picking edges (or an already-selected Plane doesn't stay highlighted) during a Fillet session; tapping "Fillet" from the "Add" FAB now flies the panel straight up with the radius field visible, with the "Select edges..." banner shown until the first edge/face-loop pick; the rest of the previously-reported live-editing/face-loop-selection behavior still works now that the entry flow has changed underneath it.

## 2026-07-05 — Bug fix: adding/removing edges after the first live-preview update crashed with `missing_reference`

User hit a real 422 on-device (`{"type":"missing_reference","body_id":"...","shape_type":"edge","index":15}`) after adjusting a Fillet's edge selection, with the sharp diagnosis: "the preview goes too far and actually changes the body... preview should only be a visual representation and not actually change the body and remove edges/faces."

**Root cause**: `_ensureFilletFeatureExists`'s *create* branch (new as of the previous entry's live-editing rework) never excluded the Fillet's own effect from the mesh the way `_openFilletPanelForEdit` already does for an *existing* Fillet being edited. So the very first successful create+`_refreshMesh()` flipped the shown/tappable body to the **post**-fillet topology - new rounded faces and edges replacing the original straight ones, with different ids. Every edge pick/removal after that sent an edge id from this post-fillet topology, but `resolve_fillet`'s own self-exclusion (added back in Prompt D specifically so an edit doesn't double-apply itself) validates `edge_refs` against the **pre**-fillet body - so a perfectly valid-looking tap on "the same edge" (now renumbered, or gone entirely - replaced by a new fillet face) came back as `missing_reference`. The user's diagnosis was exactly right: the live preview was showing (and letting you interact with) the actually-changed body, not a stable reference to pick against.

**Fix**: `_ensureFilletFeatureExists`'s create branch now adds the newly-created Feature's own id to `_rollbackExcludedFeatureIds` (the same mechanism `_beginRollback`/`_openFilletPanelForEdit` already use, inlined here rather than calling `_beginRollback` directly since this function already runs inside a `_runGuarded` call and `_beginRollback` wraps its own) immediately after creating it, before the first `_refreshMesh()`. This means the shown/interactive body for the *entire* live-edit session - create or edit alike - is now always the stable pre-fillet topology, matching exactly what the backend validates `edge_refs` against; the real, rounded result is only ever shown again once `_confirmFillet`'s `_endRollback()` clears the exclusion. Trade-off, stated plainly: this means there's no longer a live rounded-corner visual while adjusting the radius/edge selection (the very first on-device round's ask) - the two asks are in direct tension (stable edge ids for continued picking vs. showing the actually-changed body for visual feedback), and per the user's own words here, correctness of the edge selection wins over the live visual.

**Testing**: `flutter analyze` clean, same 3 pre-existing `avoid_print` infos. Same Dart suites re-run and passing (81 across `fillet_panel_test.dart`/`document_api_client_test.dart`/`feature_picker_sheet_test.dart`/`selection_filter_test.dart`/`create_plane_panel_test.dart`) - none exercise this exact code path (needs a running backend + real edge picks), verified by direct trace against `_openFilletPanelForEdit`'s already-working identical pattern instead.

**Not verified here, needs on-device confirmation**: adding/removing edges (or adjusting radius) after the Fillet has already been created no longer 422s; the body shown while live-editing is now the stable pre-fillet shape throughout, with the real filleted result appearing only after Confirm.
