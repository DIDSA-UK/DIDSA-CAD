# DIDSA-CAD Status (Consolidated)

Chronological consolidation of ~30 dated per-stage status reports that accumulated in `docs/` between 2026-06-21 and 2026-07-02. Originals preserved verbatim under `docs/archive/`. Oldest-first. See `docs/roadmap.md` for forward-looking open work; `docs/project-brief.md` for the original project spec.

This is a condensed version (~60% smaller) of the full narrative history, rewritten to stay under Claude's own file-read size limits - every dated entry survives, but with prose tightened into terse takeaways rather than full reasoning/narrative. The verbatim original, with complete reasoning/investigation detail for every entry, is preserved at `docs/archive/status-full-2026-07-21.md`.

Recurring environment caveat (stated once, not per-entry): for most of this project's history, sandbox sessions had no Flutter SDK, no GPU/display, and no working `pythonocc-core`/`py-slvs`, so client changes were often verified only by manual review (`flutter analyze` when an SDK was available) rather than `flutter test`/on-device runs, and backend OCCT changes were sometimes verified only by `py_compile`/`ast.parse` until real CI or a bootstrapped conda toolchain caught real bugs. Materially-affecting cases are still called out per entry below.

---

## Stage 2b — Wiring the constraint solver into the Sketch model (undated, precedes 2026-06-21)

Connected the Stage 2 Sketch data model (`Point`/`SketchEntity`/`Line`/`Plane`/`Sketch`, closed-loop profile detection) to the `py-slvs` spike. Added `backend/app/sketch/constraints.py` (`Constraint` ABC + `DistanceConstraint`), `solver.py` (`solve_sketch` → `converged`/`result_code`/`dof`/`blamed_constraint_ids`), `Sketch.constraints`/`add_distance_constraint`. 4 new endpoints incl. explicit `POST .../solve` (nothing auto-solves on edit).

Confirmed empirically: `py-slvs`'s `system.Failed` returns every constraint in an inconsistent system, not one culprit — "blame the newest constraint" is a UX convention, not a diagnosis.

Independent review caught `add_distance_constraint` missing the same-point validation `add_line` had; fixed pre-merge. CI 59/59 both archs. Merged via PR #4.

---

## 2026-06-21 — Stages 1–7 recap

Stages 1–6 (merged, PR #1–#9): Line entity scaffold; Sketch foundation (`Point`/`SketchEntity`/`Plane`/`detect_profile`); py-slvs wired in (Stage 2b); `X-API-Key` auth everywhere; first Flutter client (persistent cursor, click-to-commit lines, snap-to-close, live solve); Circle + radius constraint + FAB tool switcher + pan/zoom; DELETE endpoints (dependency-safe) + client selection/hover/ribbon/delete.

Unreleased as of this doc: `Document`/`Part`/`Feature` model with Feature-locking + placeholder mesh endpoint; first 3D viewport (`OrbitCamera`, `flutter_scene` mesh rendering). `flutter_scene` bumped `0.5.0-0` → `^0.18.1` (Flutter SDK moved to `master` channel; old Native Assets build hook was incompatible), dropping `flutter_scene_importer`.

Design decisions established here, unchanged since: Points are first-class shared entities (no coordinate-matching auto-merge, entities connect only by sharing a Point id); Circle's center/radius points don't join the Line-chain adjacency graph (mixed Line+Circle profile detection was an explicit gap, closed later in Stage 15/Prompt C).

Branch state: main green through PR #9; `claude/new-session-ie585q` 3 commits ahead, no PR yet.

---

## 2026-06-22 — Stage 7f: reference planes, triad, plane selection

Closed 3 gaps from real-device testing: reference planes invisible, no XYZ triad, no way to see/choose a Sketch's plane.

- `reference_planes.dart`: XY/XZ/YZ as 20×20-unit translucent rectangles, visible by default on empty Part; analytic per-axis ray-plane hit testing.
- `triad.dart`: screen-space XYZ triad overlay (bottom-left, always on top) — chosen over world-space so it never rotates out of view. Verified against `flutter_scene`'s actual view-matrix convention (`right = up.cross(forward)`).
- `plane_indicator.dart`: XY/XZ/YZ label + 2-axis arrows on 2D sketch canvas.
- Tapping a plane highlights it, offers "New Sketch on `<plane>`".

A live gesture-through-`PartViewport`/`Scene` test was attempted and abandoned — intermittent `Flutter GPU requires Impeller` exceptions, a pre-existing sandbox limitation.

Merged `claude/new-session-ie585q` with `claude/reference-planes-triad-plane-select` (one conflict in `part_viewport.dart`, resolved). Pushed, no PR opened.

---

## 2026-06-23 — Stage 9: Extrude (Boss + Cut)

First real OCCT geometry op, replacing placeholder box mesh.

- Backend: `ExtrudeFeature` model; `extrude.py` builds a prism via `BRepPrimAPI_MakePrism` then fuses (Boss) or cuts (Cut) against the accumulated solid; `/mesh` tessellates the real solid, falling back to the placeholder box only when no Extrude exists.
- Client: `extrude_panel.dart` (Boss/Cut, start/end distance, 500ms debounce → create/PATCH → refetch mesh); live preview translucent orange (`AlphaMode.blend`, alpha 0.45); Confirm/Cancel.

Backend 159/159 (via micromamba `cadtest` env). Not yet verified on a real device. Branch `claude/didsa-cad-next-stage-dshvd7`, pushed, no PR/merge yet.

---

## 2026-06-23 — Stage 10a: signed distances, Hide/Show affects mesh, zoom bounds

1. **Signed Extrude distances**: `start_distance`/`end_distance` now both signed offsets along the sketch normal (previously `start_distance` was a magnitude used the wrong way). Validated server-side (`end_distance > start_distance`).
2. **Hide/Show affects the body mesh**: `/mesh` accepts repeated `hidden_feature_ids`; accumulated solid skips matching `ExtrudeFeature`s. Client-side state, resent every fetch.
3. **Zoom bounds scale to mesh**: `OrbitCamera.setZoomBoundsForRadius(radius)` derives min/max distance from the mesh's bounding-sphere radius.

No Flutter SDK this session — Dart changes unverified by test run. One flagged risk: a Python quaternion simulation suggested `orbitByScreenDelta`'s drag direction might not satisfy its own test; left unchanged (safer than an unverified fix).

---

## 2026-06-23 — Stage 10b: UX additions

"Hide Reference Planes" toggle in flyout toolbar. Add FAB → flyout → "New Sketch" enters plane-selection mode (tap a plane to create+navigate; Cancel banner or back exits). Add FAB hidden while Extrude panel open. No backend changes. No Flutter SDK — unverified by any test run. Committed `ae0be4a` on `stage-10b-ux-additions`, pushed, PR opened but left unmerged for review.

---

## 2026-06-23 — Stage 11: Edge rendering & wireframe toggle

- Backend: `MeshData.edges` (flat `[x,y,z,...]`) via `TopTools_IndexedMapOfShape` + `topexp.MapShapes` (not `TopExp_Explorer`, which double-counts shared edges), sampled via `BRepAdaptor_Curve` + `GCPnts_TangentialDeflection`. A box always reports exactly 12 edges.
- Client: `ViewportRenderMode` enum (shaded/shaded+edges/wireframe); `nudgeSegmentsOutward` as a z-fighting mitigation (no native GPU depth-bias API in this `flutter_scene` version) — later superseded (see Prompt C/C3).
- Geometry audit of plane/sketch/extrude coordinate mapping: no bugs, but flagged latent risk (`_sample_edge` doesn't apply `TopLoc_Location`, would silently break if transforms stopped baking via `BRepBuilderAPI_Transform(..., True)`).

**Post-merge CI (PR #24) caught two real API bugs** neither manual review nor `py_compile` could catch (no working OCCT binding in-sandbox): `OCC.Core.TopExp` has no `TopExp` class (fixed to lowercase `topexp` singleton); `TopTools_IndexedMapOfShape` has no `.Extent()`/indexing (fixed to `.Size()`/`.FindKey(i)`). Both fixed, CI green, 171/171, merged to main.

---

## 2026-06-23 — Stage 12: Dimensioning, constraints & construction lines

- Backend: `construction: bool` on Line/Circle (excluded from profile detection); `Vertical`/`Horizontal`/`Angle` via native py-slvs primitives. Gap found+closed: no PATCH existed to flip an entity's construction flag — added `LineUpdate.construction`, new `CircleUpdate`, new circle PATCH route.
- Client (uncommitted as of this doc): dashed rendering for construction geometry; Make Construction/Solid ribbon toggle; reference-body ghost projection (`worldPointToSketch`, exact inverse of `sketchPointToWorld`); dimension overlays for Distance/Angle/V/H.
- Explicit scope gap: no PATCH for editing a constraint's *value* yet (closed next stage) — dimension overlays render-only this stage.

No Flutter SDK — client work unverified by any test run.

---

## 2026-06-24 — Stage 13: Tap-to-place, dimension workflow, constraint selection

- Backend: `PATCH .../constraints/{id}` (`ConstraintValueUpdate`) — edits Distance/Angle values, re-solves; Vertical/Horizontal get 422.
- Client: tap-to-place is now the only entity-input method; two-level FAB (Sketch Entities/Dimensions) replaces flat tool row; full ghost-dimension workflow (length, V/H distance, radius/diameter) confirming into real constraints; multi-entity selection with wired/unwired constraint-option table (only Vertical/Horizontal actually create constraints this stage — Parallel/Perpendicular/EqualLength/Concentric/EqualRadius/Tangent/Coincident are inert placeholders).

`sketch_controller_test.dart` rewritten against new controller API, 52/52. Full suite: 4 unrelated pre-existing `flutter_scene`/`flutter_gpu` version-mismatch failures (first documented here, recurs every subsequent client stage until fixed much later).

---

## 2026-06-24 — Stage 14: Point tool, universal snapping, selectable dimensions, drag

Pure client-side, no backend changes.

- `SketchTool.point`: single self-terminating tap, reuses snap logic.
- Universal point/midpoint snapping generalized to every placement path; tapping near a Line's midpoint materializes a real backend Point (once, on first use).
- Constraints became selectable (hit-test + ribbon value editor for Distance/Angle).
- Dimension-mode revamp: multi-select fly-up bar (`sketch_dimension_bar.dart`) replaces at-most-two-taps model; covers line-distance (materializes midpoints) and angle (non-parallel lines).
- Double-click-drag on under-constrained Points: whole-sketch `dof > 0` gates dragging (coarse, no per-entity check); live-PATCH-without-solving during drag, re-solve on release.

`sketch_controller_test.dart` grew 52 → 72, all passing.

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

`sketch_controller_test.dart`: 95/95. Full suite: 106 passed, 7 failed (same pre-existing GPU mismatch).

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
| Line-to-line distance dimension + leader-line fix | new `LineDistanceConstraint` via `SLVS_C_PT_LINE_DISTANCE` directly on endpoints (no materialized midpoint, stays correct if a Line moves); leader-line detach bug fixed with shared `_drawLeaderLine` |

No Flutter/Dart SDK, no `pythonocc-core` — verified by manual review; the `LineDistanceConstraint` convergence claim independently confirmed via a direct-import script bypassing `app.main`/OCC.

---

## 2026-06-24 — Stage 17: device-testing fixups

1. Point tool now gets the same fly-up tool bar (with Exit) as other tools.
2. **Touch point-drag tracking bug**: root cause was a coordinate-space mismatch — drag branch fed raw absolute screen position through the 1:1 mouse mapping (`screenToSketch`) instead of the desensitized "trackpad" `moveCursorRelative` mapping every other touch interaction uses. Fixed by branching on `event.kind`.
3. **Origin not selectable for constraints**: Stage 16's origin-exclusion in `_entityAt` broke selection entirely (incl. pre-existing tests) and blocked legitimate Coincident-to-origin constraints. Fixed with `includeOrigin` param — drag targeting still excludes it, selection now includes it; deletion already independently blocked.

---

## 2026-06-25 — Stage 18: menu restructure, viewport polish, connection screen

- Hamburger menu → File/View `ExpansionTile`s. File: 7 disabled placeholders + "Connection Settings". View: existing entries + Background/Body Colour swatch pickers + Body Transparency slider.
- Viewport polish: new defaults (background `#1E1E2E`, body `#B0B8C1`), live-applied + persisted via `shared_preferences`. Body "specular highlight" left `// TODO` — `UnlitMaterial` has no roughness/metallic param.
- New `ConnectionScreen`: runtime server URL + API key config (was compile-time), `GET /health` check with 15s timeout, persisted.

No Flutter SDK — verified by manual reading only.

---

## 2026-06-25 — Stage 19a: edge bleed-through attempt 1 (reverted), defaults, camera framing

| Item | Outcome |
|---|---|
| Edge bleed-through on solid geometry | `cullBackFacingSegments` (back-face heuristic, bounding-sphere-center-to-midpoint as normal stand-in) — **reverted in 19b** |
| Body transparency edge visibility | Already correct from Stage 18 |
| Edge line thickness | `kEdgeStrokeWidth` 2.0 → 1.1px |
| Default background → Off-white | `#F5F5F0` (fresh installs only) |
| Default render mode → Shaded+Edges, persisted | new `view_render_mode` pref key |
| Initial camera distance | `_defaultDistance` 30 → 48, so reference planes fill ~25% of screen (45° FOV + 20-unit plane size) |
| Autofill on Connection Screen | `AutofillGroup` + `AutofillHints.url`/`.password` |

Confirmed via `flutter_scene` source that the opaque pass already does depth write + `lessEqual` test — no app-level draw-order bug found. The back-face cull was an approximation, documented as such (not exact for concave bodies).

---

## 2026-06-25 — Stage 19b: revert the cull; feature-tree FAB; undo; select-all; Set Length

- Reverted 19a's back-face cull entirely — user feedback: made edges disappear on faces visible *through* a transparent body, worse than the original bleed-through (bleed-through itself stayed unresolved; root-caused much later, see Prompt C/C3).
- Feature tree got its own small FAB (removed from View sub-menu).
- 3D-view/plane context menus moved from hamburger drawer to fly-up bottom sheet.
- Add FAB → Feature entry → second-level picker (Extrude enabled; Revolve/Sweep/Fillet/Chamfer disabled placeholders).
- **Sketcher undo**: not full-snapshot (backend is sole source of truth) — a **command/inverse-action stack**: every mutation pushes a closure performing its literal inverse. Delete recreates full copies with old-id→new-id remap. No redo.
- Select all (excludes origin); Set Length ribbon chip (PATCHes/creates plain `DistanceConstraint` between endpoints).
- Confirming an Extrude now auto-hides the consumed Sketch.

No SDK — manual verification only; items 4–6 got no test coverage.

---

## 2026-06-26 — Stage 20

| Item | Outcome |
|---|---|
| Camera distance | Skipped — already applied manually in a prior commit |
| Delete-selected dependency order | Fixed — bucket into constraints → lines/circles → points regardless of selection order (backend 400'd otherwise) |
| Framework assertion crash (`_dependents.isEmpty`) | Inconclusive — audit found one real gap (`sketch_ribbon.dart`'s `_showSetLengthDialog` had no `context.mounted` guard), fixed defensively, root cause not confirmed (recurs later, see Stage 23-fixes) |
| AppBar logo + name | Done — **broken by a `Row`-in-`title` layout bug, fixed next stage** |
| Point tool icon | `Icons.fiber_manual_record` → `Icons.control_point` |
| Midpoint constraint v1 | two half-length `DistanceConstraint`s from `_materializeMidpoint` — **later found not to constrain collinearity at all, replaced twice (Stage 21, then 22)** |
| Stale-solve-after-drag | Root cause: unawaited per-move PATCH could resolve after `endPointDrag`'s solve+refresh, clobbering the constrained position. Fixed with `_draggingPointId` staleness guard |

Manual-only verification missed a real compile error (item 6, `line.length` doesn't exist) — caught by the user's on-device `flutter run`, not this sandbox.

---

## 2026-06-26 — Stage 21

- **AppBar layout fix**: Stage 20's `Row`-with-`spaceBetween` `title` doesn't work (`title` is a narrow centered slot). Fixed by moving logo into `AppBar.leading` (widened), right-aligning title text. New shared `DidsaLogoButton` (tap → website). Dark logo variant for AppBar contrast.
- **Midpoint constraint v2**: replaced Stage 20's two-half-distance hack with new backend `PointLineDistanceConstraint` (generic point-to-line distance via `SLVS_C_PT_LINE_DISTANCE`) — used as perpendicular-distance-0 (point on line) + one half-length distance to an endpoint. First *correct* solver-stable midpoint (v1 never constrained collinearity, only let the point swing freely in an arc).
- **Select-all → delete still 400ing**: root cause — `selectAll()` never included Constraints, so a Line's leftover `VerticalConstraint` blocked the Point delete. Fixed by having `selectAll()` also select every Constraint.

**Post-push CI bug**: a new test failed (`y≈0.333` instead of `0.0`). Wrong first hypothesis (py-slvs needing `SLVS_C_AT_MIDPOINT` special-casing) pushed and failed identically. Real cause: test's own Points were completely unconstrained free points — system legitimately underdetermined (4 excess DOF), solver was free to move the line. Reverted special-case, rewrote test to assert relative geometric invariants (matching the codebase's convention for underdetermined solver tests). No Python backend env in-sandbox — caught only via real GitHub Actions CI.

---

## 2026-06-26 — Stage 22

- **Native `at_midpoint` constraint (`SLVS_C_AT_MIDPOINT`)**: verified directly against installed `py-slvs==1.0.6` (`addMidPoint`) — proper per-primitive wrapper. Wired through full 5-layer stack. Final, correct midpoint (v3) — no fixed baked-in value, tracks the true midpoint as line length changes (regression-tested against exactly this failure mode).
- Client: `_materializeMidpoint` simplified to one `createAtMidpointConstraint` call. No constraint badge needed (falls through default-case switches).
- **FAB z-order fix**: two independent overlap bugs in `part_screen.dart` — small Feature-tree FAB painted over open toolbar panel (fixed with visibility guard); main Add FAB, being `Scaffold.floatingActionButton`, always painted above body `Stack` (fixed by nulling it while toolbar open, same pattern as Extrude-panel gating).

---

## 2026-06-26 — Stage 23: sketcher UX polish (23a–23h)

| Item | Outcome |
|---|---|
| 23a — Set Length dialog crash | Root cause: `TextField(autofocus: true)` with no explicit `FocusNode` — deferred focus-grant could still be in flight when dialog synchronously popped. Fixed with explicit `FocusNode` + `.unfocus()` before pop. **Later found insufficient — see Stage 23-fixes below.** |
| 23b — Reset View → Zoom to Fit | new `geometryBoundingBox`/`zoomToFit`; zoom floor derived from canvas size instead of fixed constant |
| 23c — Shorter constraint labels | Vert./Horiz./Perp./Coinc. |
| 23d — Remove tap-empty-canvas Exit Sketch | blank-canvas tap while ribbon closed is now a no-op |
| 23e — Labels/tap-select for every constraint type | added Coincident/Parallel/Perpendicular/EqualLength/Collinear/PointLineDistance badges (AtMidpoint deliberately still excluded) |
| 23f — Hamburger drawer: Exit Sketch + View submenu | Constraint Labels toggle, Canvas Colour, Canvas Transparency — session-only |
| 23g — Long-press marquee selection | 500ms timer, hand-rolled (raw `Listener` pointer dispatch throughout this file) |
| 23h — Selected Entities list in flyout | shown once 2+ entities selected |

New `sketch_controller_test.dart` group for `hasEntityNear`/`selectInRect`/`deselect`/`selectionLabel`. No Flutter SDK — verified by manual review + a brace/paren-balance script.

Note: `docs/stage23-background.md`, referenced by the brief, never existed in this repo.

---

## 2026-06-27 — Stage 23 fixes, and "3D viewport selection mode"

Two independently-developed pieces of work landed the same date, consolidated here.

### 3D viewport selection mode (new feature)

Orbit/Selection mode toggle FAB; persistent on-screen cursor; hover hit-testing (backend `mesh.py` gained `face_ids`/`edge_ids`/`topology_vertices`/`topology_vertex_ids` parallel arrays, stable only within one response); toggle/accumulate/clear selection; draggable bottom sheet listing selected entities; context action panel (composition table for Chamfer/Fillet/Create Plane — all disabled placeholders this stage). Orbit-mode gesture handler bodies deliberately never edited — all new logic in wrapper methods, confirmed by re-diffing.

### Stage 23 fix-prompt round (targeting both pieces)

Of 7 requested items, most already correct on inspection; real fixes: highlight render order; removed a dedicated "Select" button for tap-to-select; drawer rebuilt around `DraggableScrollableSheet` with FAB clearance; hamburger toggle became a small FAB. One item marked "not applicable" — no `InheritedWidget` exists anywhere in this codebase.

### Addenda — real-device reports falsified two "confirmed correct" verdicts

- **Set Length crash still reproduced live.** `FocusNode.unfocus()` only *schedules* a focus change — both fix sites removed the focused widget synchronously in the same call, racing it. Fixed by deferring into `addPostFrameCallback`.
- **Vertex hover/selection almost never won over an edge.** Tie-break required the vertex to be at least as close as any in-range edge, but an edge's closest-point can always slide toward the cursor while a vertex is fixed. Fixed: a vertex within its own wider radius now wins unconditionally.
- Vertex highlight dots used a cap style that renders nothing for a near-zero segment — fixed. Sketch menu FAB inconsistent placement and z-order — fixed. 2D point hit-box too small vs line/circle — widened.

None of this round verified via `flutter test` (no SDK) — manual reasoning only.

---

## 2026-06-30 — Prompt A: 3D viewport fixes

| Item | Outcome |
|---|---|
| A2 — Box selection | Implemented (double-tap-then-drag, geometric frustum projection) — **later fully removed, see Box Selection Report below** |
| A3 — Clip distance constants, auto-fit, slider | `kDefaultNearClip`/`kDefaultFarClip`, persisted, log-scale View-menu slider, auto-fit on Reset View based on mesh AABB diagonal |
| A4 — Perspective toggle | State/persistence/UI fully wired; `flutter_scene` 0.18.x has no `OrthographicCamera`/settable FOV, so the two modes currently render identically (documented `TODO`) |

Constraint maintained throughout: all four orbit gesture handler bodies stayed line-for-line unchanged; new behavior lives in wrapper methods.

---

## 2026-06-30 — Box selection: three attempts, all rejected on-device, feature parked

| # | Approach | On-device result |
|---|---|---|
| 1 | Hand-rolled `_worldToScreen` (original A2) | Selected the wrong corner/region — systematic projection bug |
| 2 | Frustum-plane test via `screenPointToRay` corner rays | Selected nothing at all, any zoom level |
| 3 | Direct 2D screen-projection (camera-axis dot products) | Selected *something* but unreliably — missed some inside, included some outside |

User: *"Not robust enough to rely on. let's park it for now."* Fully removed (state, gestures, hit-test, toolbar UI, tests); viewport reverted to single-tap-toggle multi-select. No local Flutter/Dart toolchain meant each iteration could only be validated by the user's on-device testing — three different failure modes in three attempts. Future revisit should budget for on-device/screenshot verification rather than code-review-only iteration.

---

## 2026-06-30 — Viewport bug-fix round (same session as Prompt A)

Seven bugs fixed, two kept as real fixes after box selection's removal:

- **One-sided face highlights**: `triangleHighlightBuffers` now emits each triangle twice (both windings) so hover/selection highlights render regardless of camera side — works around `flutter_scene`/Impeller back-face culling.
- Cursor crosshair got a dark outline stroke for visibility on any background.
- Perspective toggle documents its no-op status inline.
- Selected-edge highlight given its own darker blue (`#0D47A1`); selected-vertex marker diameter reduced 14px → 8px.
- Box-selection-only state/menu items ("Contain Only" toggle, deferred tap-commit timer, box-drag cursor tracking) all removed with the feature.

---

## 2026-06-30 — Prompt D: Feature tree sketch picker for Extrude

New > Extrude with no eligible Sketch selected now opens the Feature tree in a guided picker mode (banner + dimmed-ineligible rows) instead of a SnackBar complaint. Tapping an eligible Sketch closes the picker and opens `ExtrudePanel`; ineligible tap shows inline error, stays in picker mode. Canceling creates nothing.

**Addendum bug, same day**: confirming or canceling an Extrude never cleared `_selectedFeatureId`, so a later New > Extrude reused stale selection and skipped the picker — including after deleting the resulting Extrude. Fixed by clearing it in both `_confirmExtrude`/`_cancelExtrude`.

Flutter SDK bootstrapped from a `master`-branch tarball this session; 11 pre-existing failures attributed to this snapshot being newer than whatever the rest of the suite was last verified against.

---

## 2026-06-30 — Prompt B: Sketcher fixes (B0–B5)

| Item | Outcome |
|---|---|
| B0 — Cursor boundary clamping | `clampCursorToCanvas` wired through every pan/zoom/drag path — **later found to fight RTS edge-pan, replaced with "disappear, don't snap", see bugfixes below** |
| B1 — H/V on center/corner rectangles | 2 Horizontal + 2 Vertical replace 3 Perpendicular (3-point rectangles keep Perpendicular) |
| B2 — Construction geometry + center point on rectangles | 2 construction diagonal Lines + center Point pinned via AtMidpoint |
| B3 — H/V dimensions preserve orientation after solve | Prompt's assumed py-slvs methods (`addPointsHorizDistance`/`addPointsVertDistance`) don't exist in installed 1.0.6 (verified by downloading and inspecting the wheel). Used `addPointsProjectDistance` against a cached fixed reference line instead. New `DistanceConstraint.orientation` field threaded through |
| B4 — Auto-Coincident when a point lands on an existing point | shared placement path already reuses existing-point ids; implemented specifically for the standalone Point tool |
| B5 — Fully-constrained indicator | Backend `dof` field already existed; added missing test coverage + client line-color/badge wiring |

Backend: 208 passed, 25 failed — all 25 in OCCT-geometry files hitting this sandbox's fake OCC stub, none in sketch/constraint files. Surfaced (flagged, not fixed) two pre-existing bugs in `sketch_controller_test.dart` (missing `flutter/widgets.dart` import had silently prevented the whole file from loading in any prior sandbox).

---

## 2026-06-30 / 2026-07-01 — Prompt B device-testing bug-fix rounds (15 items)

Four consecutive on-device bug-report rounds against Prompt B, same branch.

**Round 1 (06-30), items 1–8:**

1. Cursor clamping erratic / fighting RTS edge-pan — B0 snapped cursor to center on every in-flight delta, not just once off-canvas. New model: panning never touches the cursor; it drifts and disappears; a fresh drag resets to center only if it starts already-hidden.
2. "Fully constrained" always showing — **real backend bug**: `solve_sketch()` short-circuited to canned `dof=0` whenever a sketch had zero Constraints. Fixed to always build/solve the full system; added a `hasGeometry` gate.
3. Indicator hidden behind Exit Sketch — moved to a lock icon in the AppBar title.
4. Double-tap drag not working — same root cause as #2 (gated on `isUnderConstrained`).
5. Selection hit box vs hover highlight sizing inconsistent — unified to `12.5px`.
6. 3D viewport pinch-zoom broken in selection mode — no multi-touch branch existed; routed to the existing `_applyPinchPan`.
7. Dimension orientation reverting to linear after solve — constraint lookup matched by point-pair alone, ignoring orientation, silently PATCHing the wrong constraint. Fixed with orientation-aware lookup + delete-recreate fallback.
8. Feature tree text color after deleting last Feature — no bug reproduced; defensive regression test added.

**Rounds 2–4 (07-01), items 9–15** (3 of these are items 1/7/8 turning out incomplete on retest):

9. Cursor still teleporting mid-drag — item 1's check ran on every delta during a drag, not once per gesture. Moved into a dedicated method called once from pointer-down.
10. Stale DOF after deleting a Circle — cascades to delete its radius Constraint, but client only re-solved when the *directly* deleted entity was a Constraint. Fixed: always re-solve after any deletion.
11. **A real, previously-undetected solver bug**: B2's rectangle construction pinned diagonals' shared center with *two* `AtMidpoint` constraints; once H/V side constraints already forced both through the same point, the second became redundant *and* singular — py-slvs failed to converge but still reported `dof == 0`. Fixed both ends: one `AtMidpoint` only; `isUnderConstrained` no longer trusts `dof` on a non-converged solve.
12. Hover/tap hit-box mismatch — unified on the zoom-scaled radius; shrank the minimum tap radius.
13. H/V dimensions rendering diagonal after solve — **rendering bug, not solver**: the constraint was already orientation-aware, the paint code just never read it.
14. Sketch stays hidden after deleting its Extrude — cascade-delete only cleared hidden-ids for Features that no longer exist; fixed to also un-hide the now-unlocked Sketch.
15. No visual distinction "under-constrained" vs "not yet evaluated"; title overflow. Fixed: indicator always shows lock state once there's geometry; title wrapped with ellipsis.

Also: previously-flaky Equal Length came back clean once item 11's redundant constraint was removed — same root cause.

This is also where the recurring `flutter_scene`/`flutter_gpu` sandbox incompatibility was first fully diagnosed: `flutter_scene` needs APIs only in Flutter **master** builds from 2026-06-09+; every bootstrapped stable SDK here predates that, so any importing test file fails to compile under `flutter test`, though `flutter analyze` is unaffected. Sandbox-only.

---

## 2026-07-01 — Prompt C: Nested profiles, multi-body extrude, edge bleed-through (round 1)

### C1/C2 — Nested and multi-profile detection

`detect_profile` rewritten: trace every Line-chain loop *and* standalone Circle into one flat list of closed loops, classify via new `_classify_nesting` (centroid-in-polygon + area tie-break — needed because a hole centered on its own container makes each loop's centroid fall inside the other). One outer loop + 0+ holes = `CLOSED_LOOP` with `Profile.inner_loops` (C1); 2+ outer loops reuses `MULTIPLE_LOOPS`/`loops` (C2), each possibly with its own holes. A loop nested inside 2+ others → new `ProfileStatus.INVALID_NESTING`.

`extrude.py`: `_face_for_profile` builds via `BRepBuilderAPI_MakeFace(outerWire).Add(innerWire)` per hole, each inner wire's winding checked against the outer's real surface normal (`_wire_normal`, via `BRepAdaptor_Surface`) rather than reasoned analytically — a Circle's fixed winding isn't the same handedness relative to plane normal on all three reference planes (XZ mirrors XY/YZ). Multiple outer loops combine into a `TopoDS_Compound`. `mesh.py` needed no changes.

First session with a **real conda/micromamba toolchain working** — all 13 new tests ran against genuine OCCT construction, not a stub; this is how the area/centroid tie-break bug was actually caught (a real test failure). Backend 249/249.

### C3 — Edge bleed-through (attempt)

Evaluated three approaches: (1) separate always-on-top depth-disabled pass — not achievable, `flutter_scene` 0.18.1 has no per-material depth toggle/second pass; (2) **chosen** — bias each edge vertex towards the camera (replacing "away from mesh center", which barely helped at grazing angles); (3) enlarge bias only on near-face-parallel segments — not attempted, no edge-to-face adjacency in mesh data.

`kEdgeDepthBias = 0.001` as a fraction of the mesh's bounding-sphere radius — **this specific choice was wrong, see round 1 bugfixes below**. Re-synced on every completed camera gesture (not every frame) — disclosed trade-off (bias direction can be briefly stale mid-drag).

Working Flutter SDK (stable 3.44.4) available for the first time via reachable `storage.googleapis.com`/`pub.dev` — `flutter analyze` a real run. `flutter test` still blocked by the pre-existing `flutter_gpu` mismatch.

---

## 2026-07-01 — Prompt C on-device bug-fix round 1

1. **Overlapping/touching inner loop produces a broken solid instead of an error.** Centroid-only containment isn't sufficient — a loop whose centroid is inside its container can still share/cross the container's boundary (a hole sharing a whole edge with the outer rectangle). Vertex-only containment doesn't catch it either (ray-casting classifies an on-edge point as "inside"). Fixed with `_loop_fully_contains`: vertex containment **plus** segment-intersection between candidate/container edge pairs. New `ProfileStatus.OVERLAPPING_LOOPS`.
2. **MultiProfile sketches never offered for extrude.** Backend gate already accepted `MULTIPLE_LOOPS`, but the client's own pre-check (`_checkExtrudeEligibility`) only looked at `isClosedLoop`. Fixed with `ProfileDetectionDto.isExtrudable` (`closed_loop` OR `multiple_loops`).
3. **Far-side edges and highlighted faces bleeding through solid geometry.** `kEdgeDepthBias`, scaled to the *whole mesh's* radius, ignored that a stepped/notched part's local features can be much shallower — bias could push a far wall's edges in front of a nearer wall by more than the feature's own depth. Fixed by reverting to a small **fixed** world-space amount (`0.02`, matching the original pre-Prompt-C nudge magnitude) — the original bug was always attributed to *direction*, never magnitude.

Backend: 252/252 (real OCCT/py-slvs env).

---

## 2026-07-01 — Prompt C on-device bug-fix round 2

1. **Sketch canvas doesn't highlight multiple closed profiles.** Client DTO only ever parsed the single `profile` field (`null` for `multiple_loops`) — never revisited since C1/C2. Fixed: `ProfileDetectionDto.fillableLoops` parses every outer loop recursively with inner loops; canvas fill uses even-odd rule so holes render punched out — a genuine new capability.
   - **Follow-up**: a standalone Circle profile's fill still didn't render — two compounding bugs: a defensive `>= 3` point-count filter dropped every Circle "loop" (2 points: center + radius), and the canvas always called `Path.addPolygon` regardless of shape. Fixed: filter loosened to `>= 2`; new `_addLoopBoundary` draws a real circle (`Path.addOval`) for 2-point loops.
2. **Internal faces/hidden edges showing through solid bodies — investigated in depth.** Read `flutter_scene`'s render pipeline source directly: the opaque/translucent split *is* architecturally correct (shared depth buffer) — **not an inherent flutter_scene limitation**. Found and fixed one real contributor: `buildMeshEdgesNode` used `AlphaMode.opaque` (depth-writes) — combined with the towards-camera bias, could corrupt what a later translucent highlight's depth test saw. Fixed to `AlphaMode.blend` (depth-tested, not depth-written; also fixed a latent bug where `_selectedEdgeColor`'s partial alpha was silently rendered fully opaque under the old mode). **On-device retest: symptom persisted.** Traced one level deeper (`scene_pass.dart`): confirmed exactly one `RenderTarget`/`SceneEncoder` per frame — ruling out a render-graph explanation too. This round's fix was real and kept, but not the only factor; handed off with concrete next-step questions since further progress needed a live GPU.

Backend unaffected (252/252). Client: 151 passed (+3 new), 17 failed (same pre-existing GPU set).

---

## 2026-07-02 — C3 rendering investigation, continued

On-device testing continued to show edges/highlighted faces bleeding through opaque geometry. Findings, in order:

1. Traced the render source — confirmed exactly one `RenderTarget`/`SceneEncoder` per frame, ruling out render-graph/pass-structure entirely.
2. Pivoted to MSAA (enabled by default on the Adreno 740 test device). Forced `AntiAliasingMode.none`. **Confirmed partial improvement**: fixed the "gross" bleed-through, leaving dashed/broken hidden edges in a graduated pattern.
3. Iteratively tuned `kEdgeDepthBias`: 0.02→0.1→0.3→back to 0.05. At 0.3, a new regression appeared — edges leapfrogging through thin/closely-spaced features ("behind 1-2 faces visible, behind 3+ not"). Reverted to 0.05.
4. **Critical finding**: retested at 0.05 — the exact same pattern persisted unchanged from 0.3, falsifying "bias magnitude" as the explanation.
5. Verified via a debug log that `AntiAliasingMode.none` genuinely took effect at runtime.
6. Android's "Force 4x MSAA" dev option made no difference — rules out a system-level override.
7. **Decisive experiment**: a throwaway branch set the bias to 40x the shipped value. On-device: the exact same pattern persisted, confirmed on both test parts — conclusively rules out bias magnitude as the mechanism.

**Current theory (unresolved)**: with MSAA, bias direction/magnitude, and render-graph all ruled out, the leading explanation is a GPU driver behavior below `flutter_gpu`'s public API — specifically Adreno GPUs' hierarchical early-Z rejection ("LRZ"), documented on Qualcomm hardware with exactly this failure signature. No public API to disable it. **Open, unresolved — see `docs/roadmap.md`.**

Decision: `kEdgeDepthBias` stays `0.05`, `AntiAliasingMode.none` stays — both net improvements even though neither fixes the residual.

---

## 2026-07-03 — Prompt A1: backend Feature dependency graph + multi-body identity

Backend-only. First of A1–A4: replaces implicit list-order recompute with an explicit dependency graph, introduces multi-body identity so Boss/Cut can target specific bodies instead of one accumulated solid.

**Dependency graph** (`graph.py`, new, zero OCCT): `GraphNode(id, depends_on)` + Kahn's-algorithm `topological_order()`. Ties broken by original input order, so any pre-A1 single-body scenario reduces to exactly the old list order by construction.

`build_feature_graph(part)` (edges: Extrude depends on its Sketch + every `target_body_ids` entry) and `compute_part_bodies` (replaces `compute_part_solid`) walk topological order, return `dict[body_id, shape]`.

**Multi-body identity.** A Body's id is **the id of the ExtrudeFeature that created it** — deliberate, so `target_body_ids` entries already *are* Feature ids, no separate lookup table needed. **Merge rule**: a Boss naming 2+ existing Bodies fuses them into one, keeping the id of whichever's Feature is earliest in `Part.features` — deterministic, order-independent.

`ExtrudeFeature` gained `target_body_ids`. Boss empty→new Body, non-empty→fuse. Cut empty→**422** (the prompt's own two instructions conflicted on status code vs an existing 400 precedent; resolved via 422 per the explicit statements — flagged in case 400 was intended). Unknown target id → 400.

**`/mesh`** now `list[BodyMeshResponse]` (was one object). A Part with nothing computed now returns `[]` — a real, intentional behavior change from the old single-empty-object response, flagged and covered by renamed tests.

**Verification gap**: no real OCCT/py-slvs env here — only the pure-Python graph tests (13/13) genuinely ran; everything else `ast.parse` + review only. Flagged as bigger than most prior entries — CI + a manual curl pass must confirm before A2.

**CI follow-up (same day)**: green both archs, 278/278 each, every new test individually confirmed `PASSED`. Automated half closed; manual curl pass still outstanding.

---

## 2026-07-03 — Manual curl sanity pass against a live A1 server

Closes the remaining half of A1's stop condition. `docker build` failed again, this time on policy grounds (403s from Docker Hub CDN and micromamba's installer via the sandbox's egress proxy; a GitHub release-asset fallback also 403'd, scope-restricted to `DIDSA-UK/DIDSA-CAD` only). Real `pythonocc-core` unreachable by any path tried.

Since every new A1 validation runs in pure Python before any OCCT call, built a minimal **fake OCCT shim** (scratch-space only, never committed) with just enough surface for `app.main` to boot: fixed fake box shapes, `BRepAlgoAPI_Fuse`/`Cut` returning fresh fake shapes, structurally-valid (not geometrically accurate) triangulation. Proves the **API contract** (status codes, response shape, body-id derivation/merge logic) via genuine HTTP round-trips against the real, unmodified FastAPI app — not geometric correctness, which the real-OCCT CI run already confirmed.

Ran `uvicorn app.main:app`, curled directly (not TestClient):
- `/health` without key → 401; with → 200.
- `GET /mesh` on a Part with no ExtrudeFeature → one entry, `body_id="placeholder"`, `source="placeholder"`.
- Boss `target_body_ids: []` → 201; mesh's Body id equals the Boss feature's own id.
- Cut `target_body_ids: []` → **422**.
- Unknown `target_body_ids` entry → **400**.
- Cut with valid target → 201; mesh still one Body, same id as the Boss it targeted.
- PATCH clearing `target_body_ids` on an existing Cut → 422.
- Two independent Bosses → mesh returns two distinct Bodies.
- A third Boss naming both (reverse order `[boss2, boss1]`) → mesh shows one Body, id is `boss1`'s — confirms merge tie-break is order-independent over real HTTP.
- Hiding the Boss feature → mesh returns `[]`, not an empty-Body entry.
- `/openapi.json`: `BodyMeshResponse` exactly `body_id`/`source`/`mesh`; `/mesh` GET is a bare array.

All matched intended behavior, no surprises. Every temporary artifact torn down, nothing committed. **A1's stop condition fully satisfied** — real-OCCT CI green (278/278 both archs) + manual API pass both confirm. A2 can begin.

---

## 2026-07-03 — Prompt A2: client selection filter framework + push/pop override mechanism

Client-only. Wires up vertex/edge/face/body selection filter toggles in the View submenu; builds a reusable push/pop override primitive — no modal flow consumes it yet (that's A4).

**Correction to A2's own premise**: prompt assumed a disabled placeholder existed to wire up — confirmed removed during box-selection cleanup. Built from scratch instead.

**Filter state** (new): `SelectionFilterState` — immutable, `vertex`/`edge`/`face`/`body` bools, `.defaults` (vertex/edge/face on, body off, matching pre-A2 behavior). Session-only, not the persisted `ViewPreferences` convention.

**Push/pop override** (new): generic `OverrideStack<T>`. Nothing pushes onto it yet in A2 (that's A4).

**Migrated plane-selection mode to `OverrideStack<bool>`** per the prompt's own invitation, as a real-world correctness check — only one push/one pop at 5 call sites, no behaviour change.

**Hit-test gating**: a kind whose flag is off is skipped *entirely* (not deprioritized). `SelectionFilterState.body` has no hit-test effect yet (no body-level hit-test until A3) — per instruction not to stub fake behavior early.

**Testing**: bootstrapped Flutter 3.44.4 for real. `flutter analyze` zero new issues. New pure-Dart tests genuinely ran 15/15. New hit-test cases analyze-clean but blocked by the standing `flutter_gpu`/`flutter_scene` wall (confirmed none newly broken). Full suite 167 passed, 17 failed-to-load (all pre-existing).

---

## 2026-07-03 — Prompt A3: client body-as-selectable-entity (started early, off a real bug report)

Client-only. Started out of sequence: on-device testing of A1+A2 hit a real bug ("can't create a body, Extrude Confirm does nothing") — turned out to be A1's deferred client-side gap.

**Root cause (confirmed)**: A1 changed `GET /mesh` from one object to a JSON array. The client's DTO still expected the old shape — casting the array to a `Map` threw. The create call succeeded (2xx) then the mesh refresh threw, and the fire-and-forget confirm wiring meant the error was never caught anywhere the UI could show it. Feature created server-side, client never showed it, panel never closed.

**Fix**: `PartMeshDto` → `BodyMeshDto`, `getPartMesh` returns a list. New `boundsOfBodies` — true AABB union across every Body. `PartViewport.mesh` → `bodies: List<BodyMeshDto>`; mesh/edge nodes became maps keyed by `bodyId` (same pattern planes/sketches already used). Existing hide/show needed no new logic — a hidden Feature's Body simply doesn't appear in the array.

**Body as a selectable entity**: `SelectionEntityKind` gained `body`; new `hitTestBodies` is the real multi-body entry point — Body is not a fourth hit-test tier, toggling the Body filter changes what a face-intersection *means* (resolves to the owning Body) rather than adding a competing kind.

**Testing**: `flutter analyze` clean. New DTO tests (7, zero `flutter_scene` dep) ran for real — the suite that directly covers the bug fix. New hit-test cases analyze-clean but blocked (same wall). Full suite 174 passed. Not verified here: on-device confirmation the bug is fixed, multi-body rendering, body-filter tap-selects-whole-body.

---

## 2026-07-03 — Backend amendment: a Body is always one connected solid

Backend-only, amending A1's body-identity rule. Off a real on-device finding while testing A3: extruding two disjoint profiles from one sketch in a single Boss showed as *one* selectable Body spanning both unrelated shapes — exactly what A1 shipped and tested, not a bug, a real product decision. Asked directly: keep "one Feature = one Body," or match mainstream CAD where each disjoint solid is its own Body. **User chose the latter.**

**New rule**: a Body is always exactly one maximally-connected solid. Every Boss/Cut result is now decomposed via `TopExp_Explorer(shape, TopAbs_SOLID)` before registration — a disjoint-loop Boss or a **Cut that severs a Body into pieces** (a new case) both now produce multiple Bodies from one operation.

**Id scheme**: common case unchanged; N>1 solids get `#N` suffixes in deterministic order. New public `base_feature_id()` strips the suffix — used by the merge tie-break, graph edges, and (critically) target-id validation, fixed to call it before the Feature lookup — **without this, a client sending back a composite id would have been incorrectly 400'd.** Caught by design review before shipping. No schema changes — a composite id is just an opaque string elsewhere.

**Testing**: pure-graph tests unaffected. Updated 3 multi-profile tests to assert split ids. New tests for a severing Cut, a composite-id-targetable-by-a-later-Cut, and an unknown base Feature still 400ing. Manual live sanity pass confirmed regression-free. **CI (real OCCT, both archs) confirmed the splitting behaviour for real**: 281/281 both archs, all 6 new/renamed tests `PASSED`.

Not proceeding to A4 yet — waiting on confirmation the A3 fix + this amendment both look right together.

## 2026-07-03 — Client fix: Body selection filter made exclusive against vertex/edge/face

Client-only. Raised by the user: with all four filter toggles independently combinable, there was no click that lands "on the body" without also landing on one of its own faces/edges/vertices (`hitTestBodies` always tries vertex, then edge, before body) — enabling Body was effectively a no-op unless the other three were also manually turned off.

**Fix**: Body is now exclusive, not additive. `PartScreen._setBodyFilter` now forces `vertex/edge/face` all `false` when Body turns on; turning Body off restores all three. `PartToolbar`'s three other filter rows pass `onChanged: selectionFilter.body ? null : ...`, `_filterToggle` gained explicit `enabled: onChanged != null` (greys the row visually — `enabled: false` is what actually restyles a `ListTile`, a null `onTap` alone doesn't). No changes needed to `hitTestBodies` itself — already fully filter-state-driven.

**Testing**: `flutter analyze` clean on the two touched files. `selection_filter_test.dart` re-ran 6/6, unaffected. The actual exclusivity behaviour is only exercisable inside `PartScreen`/`PartToolbar`, both `flutter_scene`-blocked. **On-device confirmation: done** — user confirmed toggling Bodies on/off behaves as designed.

## 2026-07-03 — Client: split Selection Filters out of the View sub-menu

Client-only, `part_toolbar.dart`. Raised right after confirming the Body-exclusivity fix: the four selection-filter toggles lived inside View alongside unrelated display settings. Moved into a new third top-level `ExpansionTile`, "Selection Filters" (`_buildSelectionFilterMenu`). Pure reorganisation — no state/hit-test logic touched.

**Testing**: `flutter analyze` clean. No widget-level test exists for `PartToolbar`'s menu structure (same sandbox constraint). Needs on-device confirmation the new menu appears and behaves identically.

## 2026-07-03 — Prompt A4: client Boss/Cut target-body picking flow

Client-only, closes the DAG/multi-body phase (A1–A4). Wires A2's filter override and A3's body selection into actually creating a Boss/Cut — until this, `target_body_ids` was built/tested on the backend but never sent: every Boss silently started a new Body, every Cut 400'd.

**Design.** The picker is woven into the Extrude panel's existing session, not a separate sub-flow: opening the panel stashes the current selection and rebinds it to the target-body picker's own for the panel's lifetime, pushing a bodies-only filter override. Reuses the viewport's existing highlight rendering and the drawer's removable-entry list with zero new plumbing (one adjustment: hiding the drawer itself while the panel is open, since both are bottom-docked and would collide).

**Requirements**: top-center banner + Cancel; multi-select accumulate is free via the existing toggle method, now also rescheduling the live-preview debounce; Confirm disabled when Cut has zero targets; both Confirm/Cancel now unconditionally restore selection state and pop the filter override — explicitly audited against the Prompt D `_selectedFeatureId` addendum bug. `target_body_ids` reaches the backend via a de-duplicated helper (create defaults `[]`, update stays nullable to preserve A1's None-vs-`[]` PATCH distinction).

**Testing.** Two genuinely executable slices (zero `flutter_scene` dep): new widget tests (6) and DTO round-trip tests (4) all passed. `flutter analyze` clean. Everything requiring `PartScreen`/`PartViewport`/`PartToolbar` still blocked.

**Needs on-device confirmation** (A4's gate, blocks Prompt B): picking mode for Boss and Cut; Body-only-forced filter during picking; multi-select accumulate/remove; Cancel restores prior selection and creates nothing; a zero-pick Boss still starts a fresh Body; a Cut with picks actually subtracts via real OCCT; prior selection reappears once the panel closes either way.

## 2026-07-03 — Bug fix: A4's target-body picking banner overflowed and sat under the FAB

On-device screenshot found two layout bugs in `part_screen.dart`: **Overflow** — the banner's `Row` had `mainAxisSize: min` with a non-wrapping `Text` in an unconstrained `Center`, fine for the short plane-selection-mode string but not A4's longer, count-dependent text ("RIGHT OVERFLOWED BY 364"). Fixed by wrapping in `Flexible` inside a `ConstrainedBox` capping the pill to `screen width - 32`; also shortened the banner strings. **Sitting under the FAB** — the top-left FAB column is only suppressed during Feature-tree-visible/plane-selection modes; A4 never added itself to that condition. Fixed by adding `&& !_extrudeActive`.

**Testing**: `flutter analyze` clean. Pure layout fixes, no state/logic change — existing A4 coverage unaffected. Needs the same on-device confirmation as the rest of A4, now covering the fixed layout too.

## 2026-07-03 — Prompt B1: backend body-scoped sub-shape references + `produces` tag

Backend-only, first of B1-B4, unblocked by A1-A4's on-device confirmation.

**`SubShapeRef`** (`models.py`, zero OCCT imports): frozen dataclass, `body_id`, `shape_type` (new `SubShapeType` str-Enum, `EDGE`/`FACE`), `index`. Pure value type, no consumer yet (Fillet/Create Plane land in C/D/E).

**`resolve_subshape(part, ref, hidden_feature_ids=frozenset())`** (`extrude.py`): looks up `ref.body_id` in a *fresh* `compute_part_bodies` call, re-walks `topexp.MapShapes` (same indexed-map pattern `mesh.py` already uses), returns the sub-shape at `ref.index` (0-based; OCCT's map is 1-based, so `index+1` passed to `FindKey`). Works against any body_id in the Part's history since `compute_part_bodies` recomputes every Body regardless of recency.

Raises structured `HTTPException(422, detail={"type": "missing_reference", ...})` for an unknown body or out-of-range index. Fails closed, no silent fallback. **Flagged deviation**: every other OCCT module has zero `fastapi` imports (HTTPException-raising has lived only in `router.py`) — `resolve_subshape` breaks that split because no consumer endpoint exists yet to own the translation.

**`produces` tag**: new `Produces` str-Enum (`BODY`/`PLANE`/`SURFACE`/`SKETCH`/`NONE`), `Feature.produces` property. Confirmed via `build_feature_graph`: a `SketchFeature` genuinely is its own dependency-graph node (not just an upstream reference), so `SketchFeature.produces -> SKETCH`.

**Testing**: `test_stage_b1_model.py` (6, zero OCCT) genuinely ran. `test_stage_b1_subshape.py` (11, real-OCCT) `ast.parse`-verified only. Deliberately did not attempt a genuine "topology shrinks" boolean-op fixture for the out-of-range test — used a plain out-of-range index against an unchanged box instead, flagged as a simplification. CI is the real proof.

## 2026-07-03 — B1 CI follow-up: first push failed, real bug in the test file itself

First push (`885a3aa`) came back red on amd64 (arm64 cancelled, fail-fast): 296 passed, 2 failed — both new "success path" tests used `from OCC.Core.BRepGProp import BRepGProp`, which doesn't exist in this pythonocc-core version. Bug in the test code, not `resolve_subshape`/`produces` — `ast.parse` only catches syntax errors, not a wrong import name.

**Fix**: rewrote both tests to compare sorted/rounded topology-vertex coordinates (`BRep_Tool.Pnt`/`topexp.MapShapes`) instead of guessing at `BRepGProp`'s real call surface a second time — every API used is already proven working elsewhere in this CI run. Pushed `cb276f1`. **Re-run green both archs**: 298/298 (amd64 4.88s, arm64 58.95s). Checklist item 7 (`missing_reference` shape over live HTTP) explicitly deferred — no consumer endpoint exists yet. B1's stop condition satisfied.

## 2026-07-03 — Prompt B2: backend graph-aware cascade delete

Backend-only. Replaced `/cascade`'s behaviour, which turned out to still be the pre-A1 "delete this Feature and everything after it in the list" heuristic — A1 introduced real dependency edges but nothing had updated cascade delete to walk them, silently wrong wherever list order and dependency order diverge. Confirmed by reading `models.py` first — a real, already-shipped bug.

**`graph.transitive_dependents`** (new): reverse-adjacency worklist traversal from the deleted Feature's id. A Sketch feeding two independent Extrudes takes both down if deleted; deleting one Extrude alone never touches its sibling.

**Moved `build_feature_graph`/`base_feature_id` from `extrude.py` into `graph.py`** — neither touches OCCT, but previously lived in a module that imports OCCT at module level, making them untestable without a real environment. No behaviour change, confirmed by re-running the untouched A1 pure-graph suite.

**`Part.delete_feature_cascade(id)` → `Part.delete_features(ids: set)`**: deliberately graph-*agnostic* — just partitions by id-set membership; all graph-closure computation moved up to the router (`transitive_dependents(build_feature_graph(part), id)`).

**Existing tests updated for correct behaviour, not just re-passed**: `test_stage7_document.py`'s cascade tests assumed old list-position behaviour using three mutually-independent Sketches — under true graph semantics, deleting the first must now delete only itself. Rewritten rather than left encoding the bug this prompt fixes.

**Testing**: `test_stage_b2_graph.py` (14, pure-Python) genuinely ran, this sandbox's strongest verification yet for a B-prompt's core logic. Rest `ast.parse`-only. CI is the proof.

## 2026-07-03 — B2 CI follow-up: one test bug, real logic unaffected

First push (`f0a4a56`) red on amd64: 316 passed, 1 failed. Root cause: my own test asserted `GET /mesh` returns `[]` after cascade-deleting every ExtrudeFeature — wrong; per `Part.produces_solid_geometry`, a Part with **no** ExtrudeFeature at all falls back to the placeholder box, not `[]` (that's reserved for "ExtrudeFeatures exist but all skipped/hidden," per A1's own distinction). The sibling test right above it already got this right. Fixed the assertion. **Re-run green both archs**: 317/317. B2's stop condition satisfied.

## 2026-07-03 — Prompt B3: client feature-tree categorization (Bodies/Planes/Surfaces)

Client-only. Groups `FeatureTreePanel` rows by B1's `produces` tag into Bodies/Planes/Surfaces sections plus a sequential list for the rest, instead of one flat list. Bootstrapped Flutter 3.44.4 for real this session.

**`groupFeaturesByProduces`** (`feature_tree_grouping.dart`, new, zero `flutter_scene` dep): pure function, stable partition (each group keeps its own creation/graph order). `'sketch'`/`'none'`/unrecognized land in `other`.

**`FeatureTreePanel`**: flat `ListView.builder` became `_buildGroupedTree` — an `ExpansionTile` per non-empty group (`bodies`/`planes`/`surfaces`, empty ones omitted entirely), followed by `other`'s rows unchanged. Row rendering itself untouched, just factored out and shared. `featureDisplayName`'s ordinal numbering still computed against the full ungrouped list — grouping is display-only.

**Multi-body awareness needed no new code**: `groupFeaturesByProduces` operates over Features, never Bodies — a split ExtrudeFeature was already exactly one tree node before this prompt.

**Testing**: `feature_tree_grouping_test.dart` (7) + `feature_tree_panel_test.dart` (5, real widget pumps — this panel has **no transitive `flutter_scene` dependency**, unlike `PartScreen`/`PartToolbar`/`PartViewport`) both genuinely ran, 12/12. Full suite 196 passed, 17 failed-to-load (unchanged file set). Needs on-device confirmation before B4.

## 2026-07-03 — B3 revision: "Build Tree" with real Body nodes (on-device feedback)

On-device testing surfaced a real design reversal: an Extrude that splits into multiple Bodies was showing as one row — correct per B3's own text, but wrong per what the user actually wanted once they saw it. Also caught a pre-existing bug: two split-Body rows both read the same truncated id (8-char truncation never reaches the `#0`/`#1` suffix).

**Confirmed design** (mirroring A3's precedent of asking directly): panel retitled "Build Tree," two independently-collapsible sections: **Bodies** (real produced objects) and **Features** (unfiltered list, unchanged) — both shown, not one replacing the other. Tapping a Body row reuses the same selection path a viewport tap uses. Body naming shared everywhere via one helper, closing the duplicate-name bug as a side effect. **B4 amendment, confirmed for later**: earlier-feature editing will use **true SolidWorks-style rollback** — reverses B4's own original text, flagged explicitly as a scope contradiction, not implemented yet.

`groupFeaturesByProduces` and its tests removed entirely — superseded. New `body_naming.dart` orders by creation-index then split index via a `LinkedHashMap` (not re-sorted from display-name strings, which would sort "Body 10" before "Body 2").

**Testing**: new tests (6+7, incl. the exact split-Body regression case) genuinely ran. Full suite 197 passed. Still needs on-device confirmation; B4 now needs the true-rollback design.

## 2026-07-03 — Prompt B4: earlier-feature editing, true SolidWorks-style rollback

User confirmed the B3 revision, moved to B4 — implements the confirmed rollback amendment, not B4's original text.

**Real backend gap found and closed — B4 could not have been client-only.** The pre-B4 "only the last Feature is editable" lock was actively enforced server-side in two places (Extrude PATCH, a dozen sketch-mutation call sites) — both reject with a real 400 today. Removed both entirely. Delete gating (`is_locked`) untouched — cascade-delete remains the only way to remove a non-last Feature; only *editing* stopped requiring "last Feature."

**Rollback is list-position-based, not dependency-graph-based — deliberate.** B2 made cascade-*delete* graph-aware to avoid over-deleting siblings; rollback is different by nature (a literal SolidWorks timeline-position concept). New `featureIdsAfter` returns every Feature after the tapped one in list order — deliberately not B2's `transitive_dependents`.

**Client rollback reuses A1's existing `hidden_feature_ids`, not a new concept**: merges `featureIdsAfter` into it (stashing the pre-rollback set first) — a named Feature is fully excluded from backend recompute, a real rollback not a rendering trick.

**Tapping any Feature now opens something, regardless of lock state**: a Sketch opens the 2D canvas with rollback wrapped around it; an Extrude reopens `ExtrudePanel` prefilled from stored values — pre-B4, tapping an Extrude did nothing, this capability had to be built.

**Confirm/Cancel extended for edit sessions**: Confirm skips auto-hiding the consumed Sketch when editing. Cancel **must never delete** the Feature being edited (unlike create-new) — PATCHes the stashed original values back instead. Both unconditionally clear edit state and end rollback.

**Testing**: new pure-Dart tests genuinely ran. **CI confirmed green both archs**: 320/320. Closes Prompt B (B1-B4) pending on-device confirmation, before Prompt C.

## 2026-07-04 — Prompt C1: Sketch point & line selection in the 3D viewport

Inserted ahead of the original Prompt C (now C2) — Create Plane's "Normal to Line at Point" type needs picking a Sketch Line/Point directly in the 3D viewport, nothing before this could. Started on top of B1-B4 without waiting on their own confirmation gate, per explicit instruction — C1's own confirmation becomes the new gate before C2.

**Backend** (zero OCCT): new `SketchEntityType`/`SketchEntityRef`, mirroring `SubShapeRef`. `resolve_sketch_entity` — a direct dict lookup with an `isinstance` check (not OCCT re-derivation), same 422 envelope. 6 new tests, genuinely ran, no OCCT needed.

**Client, rendering**: found the 3D viewport already rendered Lines/Circles pre-existing (the prompt's "Missing" framing was stale) — real gap narrower: Points were never rendered at all (added via the existing vertex-marker trick); a consumed Sketch was fully excluded rather than dimmed (fixed with a new auto-hidden set, special-cased off during rollback) — also fixed a latent B4 rollback-plumbing staleness gap as a side effect.

**Client, hit-testing**: extended to accept sketch geometry — Sketch Point ties with Body Vertex at top priority, Sketch Line ties with Body Edge next, decided by nearest-pixel-distance (the prompt's own recommended tie rule, unconfirmed on-device).

**Client, selection framework**: filter state gained `sketchPoint`/`sketchLine`; Body-exclusive overrides force these off too; a guard added against a lone sketch entity offering nonsensical "Create Plane" (real wiring is C2's job).

**Testing**: `flutter analyze` clean (drive-by fixed one unrelated pre-existing diagnostic). New pure-Dart tests genuinely ran 17/17. Full suite 207 passed.

**C1's on-device confirmation came back positive** — C2 started next.

## 2026-07-04 — Prompt C2: Create Plane

Two v1 plane methods: OFFSET_FACE (planar Body face + signed offset) and NORMAL_TO_LINE_AT_POINT (Sketch Line + one of its own endpoint Points) — both reference-only (no solid geometry).

**Backend**, split by OCCT dependency (established pattern): `PlaneType`/`CreatePlaneFeature`/`ResolvedPlane` OCCT-free in `models.py`. New OCCT-free `plane_geometry.py` resolves NORMAL_TO_LINE_AT_POINT via C1's entity resolver + plain 2D vector math (deliberately duplicates rather than imports `extrude.py`'s OCCT-typed point-to-world, to keep this module OCCT-free) — new `point_not_on_line` 422 via exact endpoint-id comparison. New OCCT-needing `create_plane.py` resolves OFFSET_FACE via `resolve_subshape` + a planarity check — new `non_planar_reference` 422 for a curved face.

**A design gap caught and closed before it could bite**: `build_feature_graph` only built edges for `ExtrudeFeature` — cascade-deleting a referenced Body/Sketch would otherwise silently leave a Plane dangling, the same bug class B2 fixed, for a new reference kind. Fixed with the matching dependency edges, verified directly.

Router unlocked from the start. List responses soft-fail to null origin/normal on a since-broken reference rather than failing the whole Feature list.

**Testing**: 11 OCCT-free tests genuinely ran; 14 real-HTTP tests `ast.parse`-only. OCCT-free suite 68/70 (2 pre-existing unrelated failures).

**Client**: new `create_plane_geometry_3d.dart` renders a Plane as a translucent amber quad (reuses `reference_planes.dart`'s geometry). New `create_plane_panel.dart` mirroring `ExtrudePanel`. `contextActionsFor` gained the real enabling rules. Flow mirrors Extrude's create-eagerly/PATCH-on-edit pattern exactly, incl. B4 rollback. Auto-closes the panel if creation fails (the one thing client validation can't rule out ahead of time — a curved face). Tree gained a **Planes** section.

**Testing**: `flutter analyze` clean. New coverage (8+8 cases) genuinely ran standalone; a full-suite-batch compiler-choke flake on one test file noted but not chased (isolated runs consistently pass). Full suite 239 passed, 16 failed-to-load (unchanged set + 2 expected).

**Out of scope**: sketching on a created Plane; three-point/tangent/angled types; tolerance-based point-on-line detection.

## 2026-07-04 — Prompt C3 (informal): Feature-menu Plane entry, Midplane, sketch-on-created-plane, tappable Planes

Before C2's confirmation returned, the user expanded scope: "Plane" as a Feature-picker entry, a third type (Midplane, two parallel faces), tappable/selectable created Planes with a context menu ("Create Sketch on Plane"/"Delete Plane"). Asked how much "Create Sketch on Plane" to build — **user chose "Full support now."**

**Backend, `ResolvedPlane` generalized to a full orthonormal basis**: `x_axis`/`y_axis` added alongside `origin`/`normal` — what a Sketch anchored to a custom plane embeds its local (x,y) through. **Hand-verified, not formula-derived, for the fixed planes**: a naive cross-product formula does *not* reproduce the already-shipped XZ convention (its basis triple is left-handed, an accident baked into every existing XZ Sketch) — new lookup table hardcodes all three explicitly. New `_arbitrary_perpendicular_basis(normal)` for the two plane types with no natural in-plane reference.

**`PlaneType.MIDPLANE`**: `face_ref` generalized to `face_refs: list`. New `faces_not_parallel` 422. Both OFFSET_FACE's and MIDPLANE's in-plane basis now come from OCCT's own `gp_Ax3.XDirection()`/`YDirection()` directly.

**Circular-import/infinite-recursion solved via a `_from_bodies` core / fresh-wrapper split**: needed because `_solid_for_extrude_feature` must resolve a Sketch's own anchor plane potentially recursively (a Plane can sit on faces from an earlier Extrude) *from inside* `compute_part_bodies`'s own loop — a fresh top-level call there would recurse forever. Threading the loop's in-progress `bodies` accumulator through works because topological order already guarantees the face-owning Extrude is processed first.

**`SketchFeature.plane_feature_id`**: a Sketch now anchors to either a fixed `Plane` or a `CreatePlaneFeature` (mutually exclusive). `build_feature_graph` gained the matching dependency edge.

**Testing**: 12 new OCCT-free tests genuinely ran. OCCT-free suite 80 passed, unchanged 2 pre-existing failures.

**Client**: DTO renames (`faceRef`→`faceRefs`, `xAxis`/`yAxis`, `planeFeatureId`). **`sketchPointToWorld` generalized to a new `SketchPlaneBasis`** — a custom plane's basis comes straight from the backend's resolved values. **Closes a real, otherwise-silent gap**: without it, a custom-plane Sketch would have been invisible/unpickable in the 3D viewport despite extruding correctly server-side. `createPlaneTransform` rebuilt on the real basis instead of the old `Quaternion.fromTwoVectors` guess.

**Client, Midplane/Feature-picker/tappable Planes**: needed no new picking machinery — Create Plane's ambient-selection already covers every combo. A widget test caught the un-scrolled six-row picker sheet overflowing a short viewport — fixed with `SingleChildScrollView`. New `hitTestCreatePlanes` + context sheet ("Create Sketch on Plane"/"Delete Plane" both reuse existing generic paths, no new logic needed).

**Testing**: `flutter analyze` clean, new coverage genuinely ran. Full suite unchanged 13-file failing set, 231 passed.

**Out of scope**: no camera-animation for a custom-plane Sketch; no highlight beyond the existing quad brightening; degenerate Midplane (same face twice) not specially rejected.

## 2026-07-04 — Bug fix: consumed Sketch only "partially" hid after Extrude

On-device testing surfaced a real UX bug: confirming an Extrude greys out its consumed Sketch in the tree (correct) but the geometry stayed fully visible in the 3D viewport. This was C1's own *deliberate* design (dim-but-selectable, so Lines/Points stayed pickable for Create Plane's line/point reference) — not a rendering defect. Asked the user which they wanted (dim-but-selectable vs fully hidden, with the tradeoff stated); **user chose fully hidden.**

**Change**: consumed Sketches now excluded from `_visibleSketchGeometries` exactly like a manually-hidden Feature. Dimming became dead code end-to-end — `dimmedSketchFeatureIds`/`sketchLineDimmedColor` and all wiring removed entirely rather than left unreachable.

**Testing**: `flutter analyze` clean. Full suite re-ran 231 passed, unaffected. Needs on-device confirmation both plane types create/render correctly, curved-face rejection is clean, Planes tree section works, rollback-edit of a Plane re-resolves correctly. Do not start Prompt D (Fillet) until positive.

## 2026-07-04 — Prompt C4: three more Create Plane methods (edge+vertex, face+vertex, three points)

Asked "are edges and vertices usable?" — they're selectable but wired to nothing real. Asked which to build — **user chose the two already-scaffolded types (edge+vertex, face+vertex) + a 3-point plane.**

**Backend**: `SubShapeType.VERTEX` resolves via the same `topexp.MapShapes` scheme `mesh.py` uses. New `PointRef` (either `vertex_ref` or `sketch_point_ref`, never both) lets THREE_POINTS mix Body vertices and Sketch Points freely. `NORMAL_TO_EDGE_THROUGH_VERTEX` (curved edge → `non_linear_edge` 422) and `PARALLEL_TO_FACE_THROUGH_VERTEX` (vertex position becomes `origin` directly). `THREE_POINTS` (pure Python): `x_axis` = normalized p0→p1 (tied to selection order so the plane doesn't spin between requests); new `collinear_points` 422 via an **exact** zero-cross-product check (no tolerance, per the project's no-implicit-inference principle). Router validation factored through one shared helper instead of duplicating checks across 6 branches.

**Testing**: 7 OCCT-free tests genuinely ran; real-OCCT file `ast.parse`-only. Fixed one stale enum test. OCCT-free suite 86 passed.

**Client**: DTOs/panel modes/`contextActionsFor` rules for all three combos, checked ahead of their disabled fallbacks. New "exactly 3 points, any mix" rule checked before the sketch-entity-only branch (would otherwise swallow a mixed combo incorrectly).

**Testing**: `flutter analyze` clean, new coverage genuinely ran standalone. Full suite 242 passed, unchanged failing set.

Needs on-device confirmation before Prompt D: all three types create/render correctly; curved-edge/face rejections clean; Three Points rejects near-collinear picks; rollback-edit of all three re-resolves correctly.

## 2026-07-05 — Build Tree UI: smaller non-wrapping text, drag-to-resize, Bodies/Planes collapsed by default

On-device feedback (screenshot): the default 40%-width panel wrapped row text mid-word ("Extrude 1" → "Extru"/"de 1"), no way to widen it, every section opened expanded regardless of use frequency.

**`feature_tree_panel.dart` converted to `StatefulWidget`**: holds `_widthFraction`, adjustable via a 14px invisible drag handle (`MouseRegion`+`GestureDetector`, resize cursor on desktop/web) clamped to `[0.28, 0.75]`. Every row/section title now `maxLines: 1` + ellipsis at reduced font sizes, `dense`/compact throughout — wrapping never acceptable for one line of tree structure. `_buildBodiesSection`/`_buildPlanesSection` now default collapsed; `_buildFeaturesSection` stays expanded (the one section every edit/rollback/delete targets).

**Testing**: `flutter analyze` clean. `feature_tree_panel_test.dart` updated (3 existing tests now expand the section first; +1 new collapsed-by-default test), 8/8 genuinely ran. Full suite 245 passed, unchanged GPU-blocked set.

## 2026-07-05 — Bug fix: hiding a Body broke any Plane/Sketch/Extrude still depending on it

On-device repro: extrude a rectangle (Body A), Midplane on two of its faces, hide the rectangle's Extrude, sketch+extrude on the Midplane — the new Extrude's mesh refresh 422'd, *and Body A itself vanished from the Build Tree* despite being fine. Deleting the Plane "fixed" it.

**Root cause**: `hidden_feature_ids` (Hide/Show) and B4 rollback's own exclusion set were literally the same client-side set and backend parameter — `compute_part_bodies` skipped a hidden ExtrudeFeature *entirely*, as if it weren't in history. Correct for rollback; wrong for Hide/Show, which never anticipated a still-visible Feature legitimately referencing a hidden Body's face. Once hidden, the Midplane's face ref couldn't resolve — and since `/mesh` is one all-or-nothing computation, that failure blanked every Body, including the unrelated fine one.

Presented three fix-scope options; **user chose the full fix.**

**Backend**: params renamed `hidden_feature_ids`→`excluded_feature_ids` throughout (pure rename). `get_part_mesh` now takes two separate query params: `rollback_excluded_feature_ids` (unchanged B4 semantics) and `hidden_feature_ids` (now purely cosmetic — every Body always fully computed, a hidden one filtered from the response only afterward).

**Accepted trade-off**: a Cut (or a fused Boss) owns no standalone Body to filter — hiding a Cut no longer "un-subtracts" it, an accidental side effect of the old conflation that was never a designed capability. Flagged, covered by a test.

**Client**: the two concepts now sent as separate params; a new union getter drives client-only visibility concerns that don't need the distinction.

**Testing**: new backend test reproduces the exact repro end to end, OCCT-free suite unchanged 86 passed. Client +3 cases, full suite 245 passed.

Needs on-device confirmation: the repro now completes cleanly; true rollback still correctly suppresses a chain.

## 2026-07-05 — On-device follow-ups: mode-toggle FAB during panels, hidden Bodies stay in the tree

Two more reports on the same screen plus a third, larger request scoped separately below.

**1. Orbit/Selection mode-toggle FAB was unreachable while the Extrude or Create Plane panel was open** — hidden for the panel's whole lifetime purely to avoid visual collision, but that also blocked orbiting to review a preview, or leaving/re-entering Selection mode to pick a different target Body. Fixed: FAB now only hides while the toolbar is open (the one genuine z-order conflict); a `Padding` bumps it 180px clear of an open panel. Extrude's own forced-true `selectionMode` override (which would've made the now-visible FAB a no-op) removed too.

**2. Hidden Bodies disappeared from the Build Tree entirely** (from the immediately preceding fix) since `get_part_mesh` still *dropped* a hidden Body's entry rather than tagging it. Backend: `BodyMeshResponse` gained `hidden: bool`; every computed Body always included (tessellation already happened before the old filter ran — free). Client: new `_visibleBodies` getter (minus hidden) feeds the 3D viewport/ghost overlay; `_computedBodyIds`/`_bodyNames` (Build Tree's source) stay unfiltered so a hidden Body keeps its row, dimmed with an eye-slash icon. Long-press now toggles it via `onBodyLongPress`.

**Testing**: backend tests updated for "tagged hidden, still present" instead of "absent," 86/86, identical blocked set. Client: `feature_tree_panel_test.dart` +4, `document_api_client_test.dart` +2, full suite 251 passed.

Needs on-device confirmation: FAB reachable/no overlap at real sizes; hidden Body row legible, long-press works.

**Scoped separately, not built yet**: a third report asked for Create Plane's OFFSET_FACE/MIDPLANE to also accept a fixed or custom Plane as a reference ("offset from XY plane," "midplane between a Plane and a Face") — needs a new mixed reference type plus reconciling two separate client selection subsystems (tapping a reference plane today starts a new Sketch, not a Create Plane pick). Deferred pending scoping.

## 2026-07-05 — Prompt C5: Create Plane referencing a Plane

Builds the previously-deferred feature — user confirmed full generalization (fixed planes + existing custom Planes, not just Body faces).

**Backend**: new `PlaneRef` (three-way union: `face_ref`/`fixed_plane`/`plane_feature_id`, mirrors C4's `PointRef`). `CreatePlaneFeature.face_refs` is now `list[PlaneRef]` (used by OFFSET_FACE/MIDPLANE/PARALLEL_TO_FACE_THROUGH_VERTEX). New `_resolve_plane_ref` dispatcher unifies all three kinds — a Plane reference recurses into `resolve_create_plane_from_bodies` against the same `bodies` accumulator already in hand (never a fresh compute, same anti-recursion reasoning as C3). Cycle-safety needs no new code — Feature creation is append-only, so `PlaneRef`'s graph is a DAG by construction; `graph.py`'s existing `CycleError` is the backstop. New `_plane_ref_dependency` in `graph.py`. `_validate_plane_ref` enforces exactly-one-of-three (422) and a `plane_feature_id`'s existence as a real Feature (400).

**Testing (backend)**: pre-existing pure-Python tests updated for the new wrapper type, re-verified. New `test_stage_c5_graph.py` genuinely ran. New real-OCCT test file `ast.parse`-only. OCCT-free suite 90 passed.

**Client**: new `PlaneRefDto`; `SelectionEntityKind` gained `referencePlane`/`createPlane`; `contextActionsFor` generalized via new `planeLikeCount` (faces + referencePlanes + createPlanes), deliberately kept separate from `hasFace` so Chamfer/Fillet's Body-only rules stay untouched.

**Testing (client)**: `document_api_client_test.dart` +4, 39/39 genuinely ran. `selection_actions_test.dart`/`selection_hit_test_test.dart` new cases analyze-clean but blocked (same standing wall). Full suite 251 passed unaffected + 4 new genuinely-run cases.

Needs on-device confirmation: selecting a fixed/existing Plane alongside a face (or two planes) surfaces the right action with correct geometry; the plane highlight-while-selected renders distinctly from "context sheet open."

## 2026-07-05 — Bug fix: planes weren't actually reachable from Selection mode's cursor at all

User follow-up ("are planes selectable with cursor, is dynamic highlight working?") caught two real gaps C5 got wrong.

**Gap 1 (discoverability)**: the Feature-picker "Plane" entry never switched the viewport into Selection mode — a tap from Orbit mode silently orbited instead. Fixed: `_startPlanePicker` now sets `_selectionMode = true`; stale hint text reworded.

**Gap 2 (the real bug)**: C5's own Selection-mode gating in `_onPlaneTap`/`_onCreatePlaneFeatureTap` was **dead code that could never run**. `PartViewport`'s pointer dispatch calls `_commitSelection()` and returns immediately while `selectionMode` is true — it never falls through to where those two callbacks are invoked, which are Orbit-mode-only, full stop. Planes were never actually selectable via the crosshair, and had no dynamic hover highlight either — the entire C5 client "selection-mode gating" story was aspirational code that never executed.

**Real fix**: reference/created Planes now flow through the *same* cursor/hover/commit pipeline every mesh entity uses. `ReferencePlaneHit`/`CreatePlaneHit` gained a `rayT` field (discarded internally before); new `_hoverHitTestPlanes` wraps both hit-tests as a `HoverHit`; `_recomputeHover` now also computes this and keeps whichever of mesh-hit/plane-hit has the smaller `rayT` (correct front-to-back resolution). `_commitSelection()` needed no change (already generic). Highlight builders' previously-`null` plane cases now build a real amber-tint quad. Dead `if (_selectionMode)` branches in `part_screen.dart` removed, doc comments corrected.

**Testing**: `flutter analyze` clean. The new `rayT` field is purely additive, existing tests unaffected. Core fix lives in `part_viewport.dart` (`flutter_scene`-blocked) — verified by careful manual pointer-dispatch trace, the same rigor that caught the bug.

Needs on-device confirmation: crosshair hover shows the amber highlight; front/behind resolution against a Body face is correct; full plane+face/plane+plane flow works end to end via the crosshair.

## 2026-07-05 — Prompt D: Fillet

User confirmed the C5 fix, provided the full Fillet and Chamfer briefs directly. Multi-edge Fillet, one shared radius (v1, no per-edge/variable fillets).

**Body-identity decision (per the brief)**: Fillet *modifies* a Body's shape rather than creating a new one — keeps the target Body's existing id, preserving A1's guarantee that later references keep resolving.

**Backend**: new `FilletFeature`. New `fillet.py`: `resolve_fillet_from_bodies` checks every edge shares one Body (new `mixed_body_selection` 422 — OCCT's fillet API operates on one solid at a time), builds via `.Add(radius, edge)` per edge then `.Build()`, raises structured `fillet_failed` on failure (never an uncaught OCCT exception). The router's resolver excludes the Feature's own id in addition to any caller exclusion — editing validates against the pre-fillet shape, not stacked on the prior result (re-resolving against its own output would double-apply it). `compute_part_bodies` dispatches via function-local import (same circular-import pattern as `create_plane.py`); an unresolvable Fillet is skipped with a warning, mirroring Cut's resilience.

**Testing**: pure-Python graph tests genuinely ran; real-OCCT tests `ast.parse`-only, covering success/rejections/re-validation/self-exclusion/cascade-delete. OCCT-free suite 95 passed.

**Client**: `SelectionContextAction` gained `disabledReason` (tooltip) for a same-kind-wrong-property selection. `contextActionsFor` gained a shared "edges, same Body" branch (serves both Fillet and, per instruction, Chamfer later). New `FilletPanel` (mirrors `CreatePlanePanel`, one radius field). Full create/edit/confirm/cancel flow mirroring Create Plane's.

**Testing**: new coverage genuinely ran, 44/44 + 9/9. Full suite 269 passed.

Needs on-device confirmation (blocks Chamfer): edges enable Fillet; live preview updates; cross-body selection blocked with tooltip; result renders and survives a rollback edit.

## 2026-07-05 — Bug fixes: Prompt D on-device feedback (mesh refresh, edit-mode rollback, Body context menu)

Four problems reported from the same session; three fixed, one flagged as a scope question.

**Fix 1 — live preview and post-confirm geometry never appeared**: Fillet's create/PATCH/delete call sites only ever called `_refreshFeatures()` (Feature list only), never `_refreshMesh()` — matching the user's own diagnosis ("hiding the feature seems to prompt a rebuild"). `_ensureExtrudeFeatureExists` already got this right; Fillet's four call sites now match.

**Fix 2 — editing an existing Fillet showed the already-filleted body**: `_onFeatureTap`'s B4 rollback preamble rolls back Features *after* the tapped one, but a Fillet modifies its own target Body *in place* — the tapped Fillet's own contribution was never excluded. `_openFilletPanelForEdit` now also rolls back `{feature.id}` itself (additive, stacks fine).

**Fix 3 (side note) — Body row long-press now opens a context menu instead of directly toggling Hide/Show**: mirrors the Feature long-press pattern, kept as its own enum for future Body-specific entries.

**Not fixed — flagged as scope**: corner treatment when 2+ selected edges share a vertex. OCCT already blends a shared vertex into one smooth corner when all edges meeting there are added to the same builder call — a real, distinct-from-buggy OCCT behavior, not a defect. Exposing a corner-treatment choice in the panel is genuine v2 scope, not built.

**Testing**: `flutter analyze` clean. Existing suites re-ran unaffected. `part_screen.dart`/`feature_context_menu.dart` unverifiable in this sandbox — verified by direct trace against already-working patterns.

Needs on-device confirmation: live preview now updates without a Hide/Show workaround; edit shows pre-fillet body with original edges selectable; Body row long-press shows the menu.

## 2026-07-05 — Follow-up: Fillet selection filter, "Add" FAB entry, live edge editing, corner-treatment investigation

Same feedback thread, three asks plus a clarifying question asked before coding.

**Clarified first**: (1) tapping a Face while picking Fillet edges should select the whole boundary loop at once — confirmed worth building (needs new backend face→edge adjacency). (2) whether corners should always round fully needs investigation, not a guess — **user chose "investigate first."**

**Investigation finding (no code change)**: `resolve_fillet_from_bodies` already uses the textbook-correct approach — one builder, every edge added before one `.Build()`, exactly what makes OCCT blend a shared vertex. The kernel's only shape-level option controls cross-sectional profile, not vertex blending — it cannot make a partial-edge selection look like a full one, since the unfilleted edge is still there and sharp. **Conclusion: correct, differently-shaped result, not a bug** (reasoned from documented OCCT behavior, unverified — no OCCT here). The practical fix is reliable full-loop *selection*, via the Face-tap feature below.

**Backend**: new `MeshData.face_edge_ids`, dense in the same order `face_ids` uses, sharing a helper so both id spaces always agree.

**Client**: new locked-down edge/face-only filter pushed for the *entire* Fillet flow. New "Fillet" Feature-picker entry mirroring the existing guided-picking shape. **Fillet's edge selection is now live for the whole panel session**, mirroring Extrude's live target-body picking — opening the panel now seeds the selection instead of clearing it; every pick reschedules the debounce into a generalized create-or-update. New method toggles a whole face's edge loop as one unit.

**Testing**: backend suite unaffected 95 passed. Client: new coverage genuinely ran. `part_screen.dart`'s new logic traced against already-working patterns, unverifiable here.

Needs on-device confirmation: FAB entry hands off correctly; face-tap selects the whole loop; edges addable/removable live with preview updating; the locked filter doesn't block anything needed mid-flow.

## 2026-07-05 — Follow-up bug fixes: planes still selectable during Fillet, "Add" FAB entry didn't fly up the panel

User confirmed "big improvement," reported two remaining bugs.

**Bug 1 — reference/created Planes stayed selectable while picking Fillet edges**: `SelectionFilterState` never had a `plane` field at all — C5 shipped `_hoverHitTestPlanes` with no filter check whatsoever. New `SelectionFilterState.plane` (default true) gates both reference-plane and created-Plane hits in one field (no picking mode has ever needed to tell them apart). `_filletSelectionFilter` sets it false.

**Bug 2 — the "Add" FAB's Fillet entry only showed a picker banner, not the panel**: the previous follow-up's picking-mode-then-panel two-step read as "did nothing." Unified the two entry points: `_openFilletPanel` (FAB's zero-edges case and the ambient button's already-has-edges case) now opens `FilletPanel` immediately either way, mirroring `_openExtrudePanel`. Separate `_filletPickerActive` flag/banner/pop-then-push hand-off all removed — `_filletActive` alone now covers the whole session. `_ensureFilletFeatureExists` generalized to create-or-update so the Feature is created lazily on the first pick.

**Testing**: `flutter analyze` clean. `selection_filter_test.dart` +4 (10/10). All prior suites re-ran unaffected. Core fix (`_hoverHitTestPlanes`, the flow merge) unverifiable here — traced against already-working patterns.

Needs on-device confirmation: Planes no longer hoverable/selectable while picking Fillet edges; "Fillet" from the Add FAB flies the panel up immediately with the banner shown until first pick; the rest of the live-editing/face-loop behavior still works under the new entry flow.

## 2026-07-05 — Bug fix: adding/removing edges after the first live-preview update crashed with `missing_reference`

User hit a real 422 after adjusting a Fillet's edge selection, with a sharp diagnosis: "the preview goes too far and actually changes the body... preview should only be a visual representation."

**Root cause**: `_ensureFilletFeatureExists`'s create branch (new from the previous round's live-editing rework) never excluded the Fillet's own effect the way editing an *existing* Fillet already did. The very first create+refresh flipped the shown/tappable body to the **post**-fillet topology (renumbered/removed edges/faces). Every subsequent pick sent an edge id from that topology, but `resolve_fillet`'s self-exclusion validates against the **pre**-fillet body — a seemingly valid tap came back `missing_reference`.

**Fix**: the create branch now adds the newly-created Feature's own id to `_rollbackExcludedFeatureIds` immediately, before the first refresh — the shown/interactive body for the whole session (create or edit) is now always the stable pre-fillet topology. **Trade-off, stated plainly**: no more live rounded-corner visual while adjusting — correctness of edge selection wins over the live visual, per the user's own words.

**Testing**: `flutter analyze` clean. Same suites re-run passing, none exercise this exact path (needs a running backend) — verified by trace against the already-working edit-mode pattern.

Needs on-device confirmation: adding/removing edges or radius after creation no longer 422s; the body shown while live-editing is the stable pre-fillet shape throughout.

## 2026-07-05 — Live rounded-corner visual preview, without disturbing the stable pick body

User asked to reinstate the live visual the previous fix traded away, with an explicit note to build it generically so Chamfer (still blocked pending Fillet's sign-off) can reuse it later.

**Design**: two meshes, fetched separately, never conflated — **the stable mesh** (unchanged, drives hit-testing/picking/highlights, must never show the rounded result) and **a new preview-only mesh** (same `/mesh` endpoint, this Feature's id *not* excluded, purely visual, never touched by hit-testing).

**Backend**: no changes — reuses the existing `rollback_excluded_feature_ids` param with two different exclusion sets from the client.

**Client**: `PartViewport` gained `previewOverlayBodyId`/`previewOverlayMesh` — a per-Body alternative to the existing global Extrude-only `isPreviewMesh` flag; substitutes rendering only, `bodies` itself (and every hit-test/highlight path) untouched. New `_refreshFilletPreviewMesh()`/`_currentFilletBodyId()`; `_ensureFilletFeatureExists` now runs both mesh refreshes concurrently via `Future.wait` so the extra recompute doesn't double wall-clock latency (still doubles backend CPU cost per edit — flagged as a real trade-off for whoever builds Chamfer next).

**Testing**: `flutter analyze` clean. Same suites re-run unaffected. `part_viewport_test.dart` still can't run here — unverifiable beyond analyze + trace.

Needs on-device confirmation: rounded-corner result visible while adjusting; edges stay pickable/removable without regression; preview overlay disappears and the real result appears after Confirm.

## 2026-07-05 — Audit: bringing every "preview" in line, plus a reference doc for the next one

User asked whether Extrude/Create Plane's preview mechanisms should match Fillet's new pattern, and whether the pattern is documented well enough to reuse without re-deriving it.

**Audit finding — no code changes needed for either existing Feature**: Extrude picks Bodies (stable ids across re-solves by construction), never exposed to Fillet's bug class — retrofitting would cost a recompute for zero benefit. Create Plane never modifies Body geometry and doesn't let re-picking happen live at all — nothing to preview, nothing to break.

**New `docs/live-preview-pattern.md`**: a decision tree (does it touch Body geometry → does live-edit re-pick sub-shapes of the Body being modified) plus an exact mirror-list of which Fillet methods/fields to replicate, which parts are already generic/reusable as-is, cross-linked from the three places a future agent would actually be reading.

**Testing**: `flutter analyze` clean (doc-comment-only client changes). `pyflakes` clean. No code change — investigation + documentation only.

## 2026-07-05 — Prompt E: Chamfer, rolled out as a full mirror of Fillet

User asked to roll out Chamfer using Fillet as the template, including every on-device fix layered onto Fillet since Prompt D, not just the original spec. Built as Chamfer's own full mirror of Fillet (matching the codebase's separate-not-shared-base convention), without touching Fillet's own code.

**Backend**: `ChamferFeature` (same body-identity-in-place decision, justified since a Fillet and Chamfer can both apply to one Body in either order). New `chamfer.py` mirrors `fillet.py` exactly (`BRepFilletAPI_MakeChamfer`/`distance` swapped in), including the identical self-exclusion convention. Dispatch/dependency/router all mirror Fillet's shape.

**Testing**: pure-Python graph tests mirror Fillet's, genuinely ran. Real-OCCT tests mirror Fillet's plus one new case: a Body with both a Fillet and a Chamfer recomputes correctly each time. OCCT-free suite 100 passed.

**Client**: `ChamferPanel` structurally identical to `FilletPanel`. `onChamfer` wired for real for the first time — the same-body rule already served both buttons from Prompt D's own work, zero logic changes needed. `part_screen.dart`: Chamfer gets its own complete, separate state/method block — a method-for-method mirror of Fillet's including the self-exclusion-on-create fix and the concurrent dual-mesh preview fetch, so Chamfer never has to earn those fixes the hard way.

**Testing**: new coverage genuinely ran (12+8). `selection_actions_test.dart` already had full Chamfer coverage from Fillet's own work.

Needs on-device confirmation (closes C/D/E): Chamfer enables independently of Fillet; live bevel preview; both applied to one Body (either order) recomputes correctly; cross-body selection blocked the same way; Add-FAB entry flies the panel up immediately.

## 2026-07-06 — On-device confirmation: Chamfer working, closing the C/D/E sequence

User tested Chamfer directly, reported "working well on device" — the gate every entry back through Fillet and C2/C3/C4 had been deferring to. Confirmation-only entry, no code changed.

Since Chamfer was built as a full mirror of Fillet's already-fixed implementation, this single pass effectively re-confirms both Features at once — live preview, no Hide/Show workaround needed, edit shows the pre-feature body, Add-FAB entry, plane-filter exclusion, face-loop selection, no more `missing_reference` mid-edit, dual-mesh overlay, both-features-on-one-Body recompute.

**The one item left deliberately open**: the corner-treatment question (whether the panel should expose a choice for 2+ edges sharing a vertex) — the investigation already concluded there's no kernel-level switch for it; the shipped answer is reliable full-loop *selection*, not a UI toggle. Remains a genuine v2-scope design question, tracked in `docs/roadmap.md`.

**Net effect**: no CAD-feature work remains blocked on an on-device gate. Create Plane (C2-C5) → Fillet (D) → Chamfer (E) is done.

## 2026-07-06 — Prompt F: Revolve, Boss/Cut parity with Extrude

Next Feature in the Revolve → Sweep → Boolean sequence. New `RevolveFeature`/`RevolveMode`, `app/document/revolve.py` (`BRepPrimAPI_MakeRevol`, `invalid_axis_ref`/`revolve_failed` structured errors), `graph.py` edges (profile Sketch + axis Sketch — cross-sketch axis explicitly allowed, confirmed by the user rather than assumed), `POST`/`PATCH .../revolve-features`. Boss/Cut dispatch shared with Extrude via a new `_apply_boss_or_cut` helper rather than duplicated — the same sharing precedent later reused for Sweep.

**Client**: `FeatureDto` gained `axisRef`/`angle`/`mode`; new `RevolvePanel`; a full separate Revolve state/method block mirroring Extrude's, including a combined `sketchLine`+`body` selection filter for simultaneously picking an axis Line and target Body. Enabled via the Feature-tree long-press menu and Add FAB picker.

**Testing**: 7 new pure-Python graph tests genuinely ran. Real-OCCT HTTP surface `ast.parse`-only. Pending on-device confirmation before Sweep.

## 2026-07-06 — Bug fixes: viewport camera jump, Sketch Circle selectability, multi-profile Sketch selection (Prompt G)

Three on-device bugs testing Revolve, plus a scoped Prompt G feature fixing one root cause:

- **Stale mesh repaints**: several refresh methods mutated state with no `setState` of their own, relying on an incidental later `setState` elsewhere in the frame — fragile (reported: a Fillet added after an existing Chamfer didn't render). Each now wraps its own mutation in `setState`.
- **Viewport camera jump**: `_visibleBodies` rebuilt a fresh `List` on every access, so any unrelated `setState` looked like a Body change and re-centered the camera, discarding pans. Memoized against `_bodies`' own identity.
- **Sketch Circles weren't independently tappable in 3D** — a Prompt C1 gap (Circles were drawable, not selectable). Added `SelectionEntityKind.sketchCircle` end-to-end; fixed two non-exhaustive switches a real Flutter build caught.
- This is why Revolve's profile picker looked broken for a Sketch mixing a Line-chain with a Circle profile — nothing tappable for the Circle loop. Also fixed `_confirmProfilePicker` hardcoding `entityType: 'line'` for every picked loop, which would 422 a Circle-only loop.

**Prompt G proper**: `detect_profile` now classifies each connected component independently — a stray open chain no longer fails detection for an independently-existing closed loop, only erroring when zero usable loops exist anywhere. New `profile_refs` on `ExtrudeFeature`/`RevolveFeature` lets a Feature pick which outer profile(s) of a multi-profile Sketch to use, via new shared `select_profiles` + `invalid_profile_ref`. Client: new profile-picking mode (2+ usable loops only) — hover highlights a whole loop, tap toggles it, checkmark FAB confirms.

**Testing**: pure-Python tests genuinely ran; client changes verified by analyze + trace. Confirmed working on-device, closing this round.

## 2026-07-06 — Sweep: Profile swept along an ordered, cross-Sketch path

Third Feature in the sequence, Boss/Cut parity throughout. Scoped via back-and-forth: path built from individually-tapped, *ordered* Sketch Line picks (not a whole-Sketch chain), each pick may name a Line in a different Sketch (chained by 3D world-space endpoint position, since two Sketches never share Point ids), open and closed paths both in scope.

**Backend**: `SweepFeature`/`SweepMode`, `sweep.py` (originally `BRepOffsetAPI_MakePipe`, later swapped — see below), graph edges (profile Sketch + every distinct path Sketch), CRUD, `compute_part_bodies` wiring.

**Client**: `path_refs` support; new `SweepPanel`; path-picking mode entered automatically after profile-picking.

### Bug fixes found rolling Sweep out

- **Path picker only extended from one fixed end** — both backend tracer and client picker tracked a single running chain end. Fixed by tracking both open ends.
- **Profile wasn't staying normal to the path at corners** — `MakePipe` doesn't reorient cross-section at direction changes (a circular profile hid this by being radially symmetric). Switched to `BRepOffsetAPI_MakePipeShell` with `SetTransitionMode(RightCorner)`. Implemented from OCCT API knowledge, unverifiable here.
- **Real 500 on-device: `MakePipeShell.Add` wants a Wire, not a Face**. Passed the outer wire instead of the full face. A Profile *with holes* had no verified way through a Wire section — explicitly rejected (`sweep_profile_has_holes`, 422) rather than silently swept wrong.
- **Hollow (annular) profile support** — a common case, not worth permanently rejecting. Now sweeps the outer wire and each hole's wire independently (both proven single-wire sweeps) and Boolean-cuts the holes out via the same op every Cut-mode Boss/Cut already uses.
- **CI regression**: a rollback-exclusion test regressed 200→422. Prompt G's fix had wrapped extrude resolution in a blanket exception catch (to tolerate a stale profile pick) that also swallowed a `missing_reference` from true rollback — which must still propagate. Narrowed the catch to the specific error type on both the Extrude and Sweep branches; Revolve has the same latent risk, untouched, flagged in the roadmap.

**On-device confirmation**: CI green (526/526), confirmed working on-device — closes Sweep.

## 2026-07-06 — Native Save/Load project file format

New phase. Backend: `app/document/native_format.py` (`export_native`/`import_native`, pure dict↔dataclass, no OCCT), full-replace import store accessors, `GET .../export/native`/`POST .../import/native`. Client: `file_picker` dependency; Save/Load wired into the File menu using native OS dialogs.

**Bug fixes**: native-format HTTP test's `part_ids` assertion broke under shared CI test state (isolation issue, not a product bug). Native Open's file picker greyed out the app's own previously-saved files — fixed the extension filter. Hide/Show state wasn't persisted in a saved file — `hidden_feature_ids` now round-trips; also renamed the file extension to `.DIDSAprt` for a clearer branded identity (was `.didsacad`, also the cause of the greyed-out-files bug until the filter matched).

**Testing**: backend tests genuinely ran; client UI verified by analyze + review only. Confirmed working on-device.

## 2026-07-07 — STEP/STL/OBJ/glTF export

Backend: `app/document/mesh_export.py` (OCCT-free hand-rolled `encode_stl`/`encode_obj`/`encode_glb`) and STEP export via `STEPControl_Writer` (AP242 schema). `GET .../export/{step|stl|obj|glb}`. Client: export UI, one entry per format, native save-file dialog.

**Bug fix**: STEP export wrote AP214 instead of AP242 — `Interface_Static.SetCVal("write.step.schema", ...)` was called *before* `STEPControl_Writer()` existed, and OCCT only registers that param during the writer's own init, so setting it earlier was a silent no-op. Fixed by constructing the writer first. Caught by CI's own test asserting on the file's actual `FILE_SCHEMA` content, not just HTTP status.

**Testing**: new pure-Python encoder tests genuinely ran; STEP export itself CI-only. Confirmed green in CI.

## 2026-07-07 — STEP/STL/OBJ/glTF import, as a fixed non-parametric Body

New `ImportFeature`/`ImportSourceFormat`: wraps an external file's bytes as a fixed, non-parametric Body — no Boss/Cut mode, no `target_body_ids`, always exactly one new Body. STEP import via `STEPControl_Reader` builds a real B-rep solid (usable everywhere a normal Body is: Boss/Cut target, Fillet/Chamfer edge source, Create Plane face reference). Mesh import (STL/OBJ/glTF) decodes via new `app/document/mesh_import.py` (inverse of the export encoders, cross-checked by round-trip tests) and rebuilds a surface-less, triangulation-only `TopoDS_Face` via `BRep_Builder`/`Poly_Triangulation` — the same convention OCCT's own STL import uses. Documented limitation: not guaranteed to survive a Boolean op the way a real solid does.

`POST .../import-features` takes the file as base64-in-JSON (no multipart dependency/precedent in this codebase). Client: Import UI, `file_picker` base64-encodes the chosen file's bytes.

**Bug fix**: imported mesh Bodies vanished from `/mesh` entirely — `compute_part_bodies` routed `ImportFeature` through the Boss/Cut-shared `_register_solids` path, which splits by `TopAbs_SOLID` count; a mesh import's bare surface-less face has zero solids, so it silently registered zero Bodies. Fixed by not routing `ImportFeature` through that shared path — always registers as exactly one Body keyed by its own Feature id.

**Testing**: new `test_mesh_import.py` (pure-Python, round-trips through the export encoders) genuinely ran; real-OCCT import HTTP surface CI-only. Confirmed green in CI.

## 2026-07-07 — On-device feedback round: five fixes after real device testing of Save/Load/Import/Export

1. **"Editable" wrongly shown for `ImportFeature`** — the locked/unlocked subtitle was a blanket check predating any Feature type without a real edit panel. Fixed with a `_hasEditPanel` negative-check; shows "Imported" instead.
2. **Cascade-delete confirmation listed the wrong Features** — a stale pre-graph assumption. New read-only `GET .../cascade-preview` runs the real `transitive_dependents` computation; client calls it instead of guessing. Docstring fixed too.
3. **Mesh-imported Bodies had no visible wireframe in any render mode** — bare surface-less face has zero real B-rep edges. New OCCT-free `synthesize_wireframe_edges_from_triangles` fallback draws each triangle's own 3 sides, reusing the existing edge pipeline.
4. **glTF import didn't work for real-world `.gltf` files** — `decode_glb` only understood the binary container; the common form is plain-JSON `.gltf` with URI-referenced buffers. Renamed to `decode_gltf`, widened to accept both; an embedded `data:` URI decodes inline, an external `.bin` reference is rejected clearly (no sibling-file access from a single picked file).
5. **Save As/New wired up** — both were disabled placeholders. `New` confirms then pushes a fresh `PartScreen`. Save/Save As share one helper; Android SAF has no true silent-overwrite without deeper URI-permission integration (flagged out of scope), so the real distinction is default suggested filename.

**Testing**: 17 new genuinely-executable pure-Python tests (a few CI-only OCCT/HTTP tests among them). Items 1/5 client-only Dart, unverifiable here. Confirmed green in CI.

## 2026-07-07 — "View Complex Mesh": a fully on-device, backend-free viewer for photogrammetry-scale meshes

User hit a real on-device `TimeoutException after 0:00:15` importing a large mesh through the normal `ImportFeature` pipeline. Concluded a mesh this large has no business surviving a base64-JSON HTTP round-trip or an OCCT Python-loop construction when the user only wants to *look* at it.

New `client/lib/mesh_viewer/` — a second, parallel client path, no server round-trip:
- `mesh_data.dart` (OCCT-free, GPU-free, pure Dart): `decodeStl`/`decodeObj`/`decodeGltf` re-implement the backend's own formats client-side; `decimateToTriangleBudget` caps triangle count via stride/skip (never merges vertices, so never distorts a texture).
- `mesh_viewer_render.dart` (GPU-touching): batches into multiple `MeshPrimitive`s to stay under `flutter_scene`'s 16-bit vertex-index limit; downsamples a base-color texture *during* decode.
- `mesh_viewer_screen.dart`: standalone screen, own minimal `OrbitCamera`, reachable from `ConnectionScreen`'s cold-launch screen, not gated behind Connect. Decode runs via `compute()` on a background isolate.

**Scope cuts, documented**: GLB built/tested first (self-contained); OBJ decodes geometry+UV but not a `.mtl` texture; GLB node transforms/scene graph not walked (assumes one untransformed mesh). Tunables are starting points, not benchmarked.

**Bugs caught by the first real on-device build** (no Flutter SDK in this sandbox — every one of these needed a real compile): `Texture.overwrite` takes `ByteData` directly (not a `Uint8List` view), returns `void` not a success flag. `UnlitMaterial`'s real texture slot is `baseColorTexture` (confirmed against the actual installed source), not the guessed `colorTexture`. A genuine ordering bug: `UnlitMaterial`'s constructor throws until `Scene.initializeStaticResources()` has run once, but the material was built before the viewport mounted. Fixed with a single memoized `ensureSceneResourcesLoaded()` future both places await.

**Testing**: new pure-Dart tests, logic-only, not run in this sandbox. Confirmed loading/rendering an STL on-device after the fixes; user then reported the render is flat/unlit (`UnlitMaterial` ignores scene lighting by design) — the next phase's open item.

## 2026-07-07 — Real PBR lighting/shading across the whole app, plus a Scene menu

User asked to fix flat/unlit rendering "for real" — whole-app since `PartViewport` shares the mesh viewer's limitation. Fresh branch, after merging the prior Save/Load/Export/Import + View Complex Mesh phase (PR #93).

**Research finding**: no `flutter_scene` upgrade needed — 0.18.1 already includes `PhysicallyBasedMaterial`, `Scene.directionalLight`, `EnvironmentMap.studio()`, SSAO.

**Built**: both viewports now build a real `PhysicallyBasedMaterial` instead of `UnlitMaterial` for confirmed geometry (`metallicFactor` fixed non-metal, not adjustable). Live-operation preview overlays deliberately stay `UnlitMaterial` (flat "in-progress" indicator). Both set `EnvironmentMap.studio()` + a fixed-direction directional light.

New `ScenePreferences` (`shared_preferences`, mirrors `ViewPreferences`): `roughness`/`lightIntensity`/`emissiveIntensity`. Body-colour default changed `#B0B8C1` → mid-grey `#808080`.

New shared `SceneControlsPanel` embedded two ways (`PartToolbar`'s new "Scene" menu; `MeshViewerScreen`'s new File/View AppBar menu). Also fixed: the mesh viewer's file picker greyed out every format but `.stl` on Android (SAF MIME-filtering) — switched to `FileType.any` + post-pick validation.

**Bugs caught by the first real on-device build**: round 1 — three compile errors in the main-app copy of the same `Texture.overwrite`/`baseColorTexture`/scene-resources-ordering bugs already fixed once in the mesh viewer. Round 2 — Scene sheet sliders didn't visually move while dragging (a `StatefulBuilder` var declared inside the callback reset itself every rebuild; underlying state was fine) — fixed via a real `StatefulWidget`. Some meshes rendered one side opaque/one see-through (backface culling + inconsistent winding) — fixed with `doubleSided = true` in the mesh viewer.

**This second fix's assumed scope turned out wrong**: first assumed external-file-specific, left untouched in `part_viewport.dart` — user then reported the identical symptom on an ordinary Extrude Cut Body. Applied there too, confirming backface culling is general `PhysicallyBasedMaterial` behaviour, not winding-source-specific (`UnlitMaterial`, used everywhere before, apparently never culled).

Also: **File > Exit** replaces the old "Connection Settings" entry.

**On-device confirmation**: user tested the full round, confirmed working.

## 2026-07-07 — C3 residual edge/face-highlight occlusion bug: resolved, and the leading theory was wrong

Closes the C3 bug first investigated 2026-07-01/07-02, this project's one standing open rendering bug through the entire Create Plane → Fillet → Chamfer → Revolve → Sweep → Save/Load/Export/Import → View Complex Mesh arc. Symptom: edges/highlighted faces on the far side of solid geometry rendered through it, worse with fewer occluding layers ("behind 1 face visible, behind 2 visible, behind 3 not visible").

**The standing theory (Adreno LRZ hardware quirk) is now known incorrect** — or at least not the actual mechanism.

**The real cause**: `flutter_scene`/Impeller performs backface culling by default (already known from the highlight-buffer workaround), and this app's regular Body-rendering path never accounted for it. Wherever backface culling silently dropped a triangle, it left a *gap* in the depth buffer at those pixels — an edge "behind" the Body wasn't failing an occlusion test, there was simply nothing there to occlude against. Directly explains the graduated "N layers needed" pattern that never fit a real z-fighting bug (which should be binary): with 1-2 layers, enough triangles could be gap-culled that no depth was ever written; enough layers eventually guaranteed some surviving triangle covered the gap.

**The fix**: `PhysicallyBasedMaterial.doubleSided = true` on `part_viewport.dart`'s Body material — the same fix from the entry directly above, added only to fix the "one side opaque" symptom, with no expectation it would also resolve this much older bug. User confirmed on-device: "this actually solves a historic problem I thought was occluded edges bleeding through... this has fixed it."

**Retrospective**: every earlier ruled-out cause (render-graph, MSAA, edge depth-bias direction/magnitude, edge alpha-mode) remains correctly ruled out — none were ever the real mechanism; the mitigations built along the way (`kEdgeDepthBias = 0.05`, `AntiAliasingMode.none`) were real, independent improvements worth keeping. The bug lived in the *opaque face* geometry the edges were tested against, not in the edge-rendering code being debugged. `docs/roadmap.md`'s C3 section removed.

## 2026-07-07 — Real-world mesh viewer crash: two fixes (a spec gap, and decimate-during-decode)

User tried a real OpenDroneMap `.glb` export, hit `type 'Null' is not a subtype of type 'int' in type cast`. A separate, larger model crashed the whole app to the home screen.

**Fix 1 - the ODM crash**: per spec, an accessor's `bufferView` is legally optional (means all-zero data) — `readAccessor`/`readIndices` force-cast it to `int`, crashing on any accessor lacking one. Fixed: a vertex accessor with no `bufferView` returns spec-correct zero-filled data; an index accessor (no sensible "all zeros" interpretation) is rejected with a clear error instead.

**Fix 2 - crash-to-home-screen, memory exhaustion**: decoders fully decoded the *entire* source triangle count before decimating, so peak memory scaled with source size, not target budget — a genuinely huge file could exhaust memory before the safety net engaged. All three decoders now take `maxTriangles` and decimate *during* decode: binary STL/glTF know their exact count upfront (skip a triangle's bytes outright); ASCII STL/OBJ do a cheap pre-pass count first. New `DecodedMesh.sourceTriangleCount` tracks the pre-decimation count for the viewer's "showing X of Y" banner. Post-hoc `decimateToTriangleBudget` kept as a standalone utility for other callers, no longer used in the viewer's own pipeline (can't fix a memory problem that already happened).

**Known remaining limitation**: the source file's raw bytes are still read fully into memory in one shot via `file_picker`'s `withData: true` before decode starts — this fix bounds decoded memory, not raw file memory. A gigabyte-scale source would need a streaming file-read API, flagged not attempted.

**Testing**: new pure-Dart tests for each format's `maxTriangles`/`sourceTriangleCount` and the two `bufferView`-missing cases, not run in this sandbox.

## 2026-07-07 — Same ODM file, real root cause found: Draco mesh compression

The two fixes above weren't the end of it — the same file still failed (now with the index-accessor rejection specifically), and a separate 69MB file still crashed.

**Diagnosis**: almost certainly `KHR_draco_mesh_compression`, a standard glTF extension photogrammetry pipelines commonly use — an accessor declares its real logical count but has no `bufferView`, since the geometry lives compressed in an extension block this decoder never implemented, not the spec's legitimate "all-zero" case. This also explains the 69MB crash: POSITION/NORMAL/TEXCOORD_0 accessors likewise lack `bufferView` and were being zero-filled per their declared count — for a much larger mesh, a multi-gigabyte allocation attempt for data that was never going to be used.

**Fix**: check `extensionsUsed` once up front, before any accessor is touched — `KHR_draco_mesh_compression` or `EXT_meshopt_compression` now fails immediately with a specific, actionable error naming the extension.

**Not implemented**: actually decoding Draco/meshopt — real binary codecs, no pure-Dart package available, a native/FFI dependency would be a materially bigger change. Open question for the user; re-exporting without compression is the immediate workaround.

**Testing**: new test asserting a Draco-flagged document fails with the specific message, not run in this sandbox.

## 2026-07-07 — glTF node transforms: fixes mirrored geometry and wrong-looking shading on Blender exports

User re-exported from Blender: the smaller file now opened (confirming the Draco fix), but reported "the textures are messed up and the model seems mirrored"; the larger file still crashed.

**Diagnosis**: the decoder read raw accessor data directly, entirely ignoring the glTF scene graph's node TRS transforms. Blender's exporter applies its Z-up-to-Y-up axis correction as exactly this kind of node transform (a wrapping root node), not baked into vertex data — a decoder ignoring node transforms reads pre-correction data straight through. Wrong axis reads as "mirrored"; wrong normals (invisible under flat `UnlitMaterial` before, now visible under real PBR lighting) break shading.

**Fix**: walk `scenes[scene].nodes` (root nodes only — no recursion into `children` yet) and apply each root node's TRS to every position/normal it contributes. Documents with no scene graph fall back to one identity instance per mesh (preserves prior behaviour). A `matrix`-based node is rejected with a clear error rather than silently ignored. Normals scaled by scale's reciprocal before rotating, renormalized after (correct for a diagonal, shear-free scale).

**Scope cuts**: only root-level transforms applied (a deeper nested-transform hierarchy isn't composed — the one real motivating case doesn't need it, or so it seemed, see next entry); `matrix`-based nodes rejected not decomposed.

**Not yet resolved**: the larger file's crash — needs its own report.

**Testing**: new tests for translation/scale/rotation-only root nodes, a `matrix`-rejection case, a mesh-less-root-skip case — pure-Dart, not run in this sandbox.

## 2026-07-08 — glTF node transforms, round 2: the deliberate root-nodes-only scope cut was the actual bug

User re-tested: still mirrored, larger file still crashed.

**Root cause of "still mirrored"**: the "root nodes only" scope cut wasn't safe — a mesh-bearing node in a real Blender export is very often *not* itself a scene root; the axis-correction/object transform frequently lives on a parent "Empty" node one or more levels up, with the mesh-referencing node nested underneath. The previous implementation skipped any root node without a direct `mesh` field, with no recursion into `children` — both the ancestor's transform and the nested mesh node's own were silently dropped, reproducing the exact "raw geometry" bug the first fix was meant to remove.

**Fix**: full recursive walk of the scene graph, composing each ancestor's transform into a running total via real matrix multiplication (`_NodeTransform` changed from a bare T/R/S triple to a composed position matrix + normal matrix + translation) rather than nested T/R/S. A `matrix`-based node anywhere in the hierarchy is still rejected.

**The larger file's crash remains unresolved** — no new information this round; needs an actual crash log (`adb logcat`) to progress, since a crash-to-home-screen with no visible in-app error is usually native-level (OOM/GPU fault), not a catchable Dart exception.

**Testing**: new test for a mesh node nested one level under a transformed non-mesh root ancestor — exactly this round's real bug shape. Existing root-level tests unaffected. Pure-Dart, not run here.

## 2026-07-08 — Three small fixes: eager feature preview, saved-name banner, mesh viewer Facets/Mesh toggle

**Fix 1 - live preview didn't appear until a value changed**: all four panels (Extrude/Revolve/Fillet/Chamfer) report edits via `onChanged`-style callbacks, but never fired that callback for their own *initial* values, only on a genuine user edit. Fixed identically in all four: `initState` schedules a post-frame callback firing once with the initial value(s), mirroring what a first edit would trigger. Confirmed safe — none of `PartScreen`'s corresponding handlers call `setState` synchronously.

**Fix 2 - AppBar always said "Part 1"**: banner was bound to backend `Part.name`, hardcoded server-side for every new Part; Save/Save As never renamed the Part itself. New `_displayPartName` getter prefers the last-saved filename (stripped of `.DIDSAprt`) over `Part.name`, falling back only when nothing's been saved/opened this session.

**Feature - "Facets"/"Mesh" View-menu toggles in the mesh viewer**: two new toggles alongside "Scene." "Mesh" builds a wireframe overlay from the same triangle soup (every triangle's own 3 edges, undeduped — cheaper than a hash dedup for a cosmetic toggle). At photogrammetry scale that's tens of millions of line primitives — new `kMaxWireframeTriangles` (200,000) disables the toggle above that count (greyed out, "too many triangles") rather than hanging the frame.

## 2026-07-08 — Investigated: complex glTF mesh still reported mirrored, "is decimation involved?"

User confirmed a simple mesh imports correctly but a complex one is still mirrored, asked directly whether decimation is the cause.

**Decimation ruled out by code review**: decimation only ever decides whether to keep or skip a *whole* triangle — never reads/writes/reorders a vertex coordinate. Mathematically rules out decimation regardless of the correlation with file complexity.

**Node-transform matrix math re-verified by hand** — no error found, implementation matches the standard composition rules.

**Not yet resolved** — no further progress possible from static review alone. Candidates not yet ruled in/out: a genuine negative-scale (legitimate reflection) node, a deeper hierarchy/multi-primitive interaction not covered by test fixtures, or something unrelated to node transforms entirely. Needs the actual file's JSON or a reduced repro to progress without guessing a third time.

## 2026-07-08 — Real diagnosis: 39 materials/primitives, not decimation or node transforms; plus the actual root node had no transform at all

User confirmed the earlier "simple mesh not mirrored" test was invalid — that file round-tripped through DIDSA-CAD's own exporter, which always writes an identity-transform node, never exercising the node-transform code. A small Python script extracted just a `.glb`'s scene-graph JSON so a large file could be inspected without a full transfer.

**The dump revealed the real shape**: the root node has no transform (confirming both node-transform rounds were correctly a no-op) — but the mesh has **39 separate primitives, each with its own material index**. An ordinary real-world shape this decoder had never been tested against — every existing fixture has one primitive/one material.

**The real bug**: texture extraction only ever read the first material — all 39 primitives rendered with material 0's texture, 38 showing an unrelated section's texture over their own UV space ("patchy and wrong in different areas").

**Fix**: new `MeshMaterialGroup` (contiguous triangle range + its own texture). Decoder records one group per primitive that contributed a kept triangle, resolving each one's own material texture instead of always the first. Render side takes a list of materials, batching each group's range against its own.

**Still open, separately**: the actual mirroring/orientation issue. User clarified: "everything went down into the ground instead of up into the sky (although the model is actually on its side)" — root node confirmed transform-free, no per-format axis-swap code exists anywhere in the pipeline (this app's camera and backend both already use Y-up, matching glTF's spec), so a simple up-axis mismatch doesn't obviously explain it. Sent an enhanced diagnostic script pulling each POSITION accessor's bounding box to identify the file's true "up" axis directly rather than guess a third time.

## 2026-07-08 — Root cause found: the file's own data isn't Y-up, plus a manual Up-axis fix and two settings

The bounding-box dump showed Z's range (17.4) far smaller than X/Y's (73-78) — the opposite of a correct Y-up export. A screenshot of the viewer's fixed oblique camera showed a straight-down aerial view instead of 3/4 angle — only possible if the model's real vertical axis aligns with the camera's line-of-sight (Z), not its up vector (Y). Both agree: **this file's real "up" lives in Z, not Y**, almost certainly because Blender's "+Y Up" export conversion checkbox was skipped — a genuine, self-consistent round trip through Blender that its own viewport never notices. Not a bug in this decoder (already independently re-verified twice) — this specific file's data doesn't follow the format's own spec. No reliable way to auto-detect it (a correct and a mislabeled file are structurally identical), so it needs a manual choice.

**Fix**: `MeshUpAxis` (`y`/`z`) + `applyUpAxis` — `y` is a no-op; `z` applies `(x,y,z) -> (x,z,-y)`, the same permutation Blender's own exporter uses, applied a second time for a file that skipped it once. Deliberately a proper rotation (determinant +1), not a bare axis swap (determinant -1, which would "fix" up-axis at the cost of introducing a genuine mirror — exactly the bug this is meant to avoid).

Wired into a new View menu entry, keeping `_rawMesh`/`_mesh` (derived) so toggling re-derives without re-decoding. Runs via `compute()` (still potentially millions of vertices post-decimation).

**Also added, per explicit request**: a decimation-triangle-budget slider (previously a hardcoded 3,000,000 constant) via new `MeshViewerPreferences` (`shared_preferences`-backed, 250,000-10,000,000) plus a persisted up-axis default. New settings screen, reachable via a gear icon next to "View a mesh file."

**Testing**: new tests for the no-op `y` case, the exact `z` output, four-applications-returns-to-original (confirming a proper rotation not a reflection). Pure-Dart, not run here.

## 2026-07-08 — Up axis toggle confirmed working on-device; connection-screen button overflow fixed; genuine mirroring still unresolved

User confirmed the toggle works — the file now stands upright, matching the real property scan.

**Connection-screen overflow, real bug**: the "View a mesh file" button + gear pair overflowed on some screen widths (a genuine Flutter overflow banner). Fixed per explicit request: single obround button split 80/20 (mesh viewer / settings gear), each half its own `InkWell`, `VerticalDivider` between. Label shortened for margin.

**Genuine mirroring reported, not yet actioned**: after the Up-axis fix, user reported the model is still a true mirror ("the garage is on the wrong side of the house"). `applyUpAxis` never touches X, so this isn't something the Up-axis work introduced — either pre-existing in the raw decode, or (an alternative not yet ruled out) simply the default camera viewing from the "back," which for an asymmetric building would *also* put a wing on the apparent "wrong" side with no real reflection bug involved. Asked the user to orbit ~180° first to rule out the cheaper explanation before building a speculative fix — this session's second/third rounds on the earlier orientation bug both started with a wrong specific guess, so isolating a definitive test first was intentional.

## 2026-07-08 — Actual root cause of the genuine mirroring found: a left-handed XZ plane basis in `plane_geometry.py` — fixed; reference-plane colours also fixed

Orbiting 180° ruled out the camera-angle explanation — the reflection was real. Off-Flutter mathematical analysis (raw byte parsing, winding-vs-normal checks, a chirality proof that composing `applyUpAxis` with Blender's own conversion can never produce a reflection since both are proper rotations) **definitively ruled out the mesh-viewer decode/correction code**, leaving the actual bug unexplained since both files round-tripped correctly through Blender itself.

The breakthrough came from the user's own observation on a blank "Part 1" screen: the reference planes' colours looked swapped (YZ green instead of red, XZ red instead of green) — leading to the correct hypothesis of an X/Y axis swap that "only occurs on certain planes."

That pointed at `plane_geometry.py`'s `_PLANE_BASIS` table — the source of truth for how a Sketch's local (x,y) embeds into 3D, used by Extrude/Revolve/Sweep uniformly. Checking each fixed plane's handedness (`x_axis × y_axis` must equal `normal`) found **XZ alone was left-handed** — already flagged in an existing code comment as known-but-unaddressed from an earlier stage; this investigation connected it to a real symptom for the first time. A genuine first-party bug in Sketch-to-3D embedding, unrelated to glTF/Blender — explains every mirroring symptom reported this session provided the Sketch was drawn on XZ (a common default, often "Front").

**Fix**: negated XZ's `x_axis` in both backend and the client's duplicated table; `y_axis` deliberately unchanged (only flips the horizontal local direction, not "up"). New regression test asserting XZ's basis is right-handed. OCCT-free suite 157 passed, 3 pre-existing unrelated failures.

**Backward-compatibility note**: any existing Part with an XZ-plane Sketch now builds with different (corrected) geometry — intentional, not neutral; previously-saved XZ features will look mirrored until re-saved.

**Reference-plane colours, separately**: the "swap" was actually a deliberate Stage 18 choice (following an early named-view table) rather than axis-matching. Switched to full axis-matching — cosmetic, unrelated to the geometry fix.

**Not yet verified on-device** — no Flutter SDK/OCCT in this sandbox.

## 2026-07-08 — The mesh viewer's own mirroring bug was separate all along; new "Mirror" toggle, confirmed with the real file

The XZ basis fix only applies to DIDSA-CAD-built Parts — user confirmed the mesh viewer's own `Nightingales.glb` is still mirrored, which it can't explain since the mesh viewer never touches Sketches.

Checked directly against the real bytes. `asset.generator` confirms a genuine Blender export (real property scan, matching the earlier investigation). Every remaining decoder step re-checked against the actual bytes: no swap on read, a true identity scene-node transform, `applyUpAxis` a proper rotation, decimation only skips whole triangles, no UV flip, GPU upload copies verbatim — every step is either a no-op or a proper rotation, no point in this pipeline can introduce a mirror.

So whatever chirality is baked into the raw `POSITION` data is exactly what's displayed. All 217,465 vertices decoded directly in Python and rendered as a top-down footprint two ways (as the app produces it, and X-negated) — sent to the user for ground-truth comparison. **Confirmed: the X-negated version matches the real house.** The raw file itself is a genuine mirror image of the property, not a decoder bug (and, per the user, also not present opening the same file in Blender — unexplained, plausibly a manual correction made in Blender at some point that a fresh byte-read wouldn't inherit).

No reliable way to detect a mirrored file from its bytes (same problem as up-axis) — needed the same treatment: a manual toggle.

**Fix**: new `applyMirror(mesh, bool)` — negates world X only for positions/normals, leaving winding untouched (every mesh-viewer material already sets `doubleSided = true`, so there's no culling left for a winding flip to break). Both correction functions now run in one isolate hop instead of two. New "Mirror" View-menu entry + settings control, mirroring Up-axis's pattern.

**Testing**: new tests for the no-op case, exact negated output, twice-idempotent-to-original. Pure-Dart, not run here.

**Mirror toggle confirmed on-device**: "working, model looks correct once mirrored." Why the file opens un-mirrored in Blender remains an unexplained mystery.

## 2026-07-08 — Texture-memory budget for the mesh viewer: the likely cause of the still-unexplained larger-file crash

Separately, the earlier-reported larger-file crash came back into scope when the user asked directly: "could the issue be related to lots of high resolution textures?"

**Yes - a real, previously uncapped gap, found by code review**: `buildMeshViewerMaterials` decodes/uploads *every* material group's texture eagerly, unconditionally, all staying resident for the mesh's whole lifetime. Each individual texture was already capped at 4096px, but there was no budget on the *sum* across a file's materials — a larger file with more primitives near the cap could plausibly reach several GiB (100 materials at 4096² RGBA8 each is ~6.4 GiB), exactly matching the reported crash signature (a native OOM kill bypasses this app's try/catch, surfacing as a silent crash-to-home-screen).

**Fix**: new `kMaxTotalTextureBytes` (512 MiB, a tuning starting point) and `_textureDimensionBudget(textureCount)` — shrinks each texture's own decode dimension (floor 256px) so the total stays under budget. A file with few materials (the common case) is unaffected.

**Not yet confirmed against the actual crashing file** — too large for the user to upload; this is a plausible, concretely-reasoned mechanism (and a real, previously-uncapped gap regardless) rather than a confirmed fix. No automated test — GPU-touching code, needs on-device confirmation.

## 2026-07-08 — The real, confirmed cause of the crash: `file_picker`'s `withData: true`, not textures at all

The texture theory above was reasonable but a real `adb logcat` capture (filtered at capture time via `tag:priority *:S` rather than post-hoc grep) turned up the actual stack trace: `java.lang.OutOfMemoryError: Failed to allocate a 150384072 byte allocation...` inside `StandardMessageCodec.writeValue`/`FilePickerPlugin`.

This is a genuine Java-level OOM on Android's small (~256 MiB) default app heap, happening entirely inside the `file_picker` plugin *before* any of this app's own Dart code runs. `withData: true` makes the plugin read the whole file into a native byte array, then re-encode it through a `MethodChannel` reply (`StandardMessageCodec`, which grows a `ByteArrayOutputStream` by repeated doubling) — for a large file that transiently needs roughly *twice* its size on a 256 MiB heap. The crash log's own numbers confirm it exactly. The texture theory, while a real and worthwhile fix in its own right, never got the chance to run — the crash happens while the file is still being handed from native code to Dart.

**Fix**: `_pickAndLoad` no longer passes `withData: true` — reads `PlatformFile.path` instead (file_picker copies content-provider URIs to a real cache file even without `withData`, reliably non-null on this app's mobile/desktop targets — no web target exists here). The decode isolate now reads the file itself via `File(path).readAsBytesSync()`. File bytes now cross into Dart via ordinary `dart:io` file access, never through a `MethodChannel` envelope, never bound by the small Java heap regardless of file size.

**Also confirmed on-device this round**: the Mirror toggle working correctly.

**Not yet re-tested** — needs the user to retry the same larger file now that the actual cause is fixed; the texture-memory budget remains in place as a real, independent improvement regardless.

## 2026-07-08 — Confirmed: file_picker fix resolved the large-file crash. New feature: export the decimated/reduced mesh as a real file

User confirmed the fix worked. Asked for an export feature writing the currently-decimated/corrected mesh as a real, smaller file. Two scoping questions first: user chose both GLB and STL (picked at export time), and downsampling textures to match the viewer's own display resolution.

**New pure encoders** (reverse of the decoders, same pure-Dart split): `encodeMeshAsStl` averages per-vertex normals into one facet normal (STL has no per-vertex concept). `encodeMeshAsGlb` — one primitive per material group, no index buffer (same triangle-soup convention as the backend's encoder); an untextured group gets a plain grey default. Real bug caught during implementation: a GLB's embedded binary chunk backs exactly one buffer per spec — an earlier draft used two, spec-invalid; fixed to append every group's image bytes after vertex data in one buffer. Tested via a strong check: encode then decode back through the already-tested decoder, asserting an exact round-trip.

**Texture downsampling for export**: re-encodes at the same budgeted dimension the viewer already shows on-screen, as PNG (`dart:ui` has no JPEG encoder).

**UI**: new File-menu GLB/STL export entries. Byte-encoding runs via `compute()`; bytes handed to `saveFile`. Deliberately re-treads the platform-channel territory that caused the earlier import OOM — but the export is already-decimated/budget-capped, bounded by preference settings rather than an unbounded source file, so the channel cost is small by design.

**Testing**: new tests for exact STL byte layout, GLB round-trip for both untextured and mixed meshes, and a check that an untextured mesh's glTF has no image arrays. Pure-Dart, not run here.

## 2026-07-08 — Export confirmed working for normal files, but failed silently on the largest textured file - same root cause as the earlier import crash, fixed the same way

Export worked on-device for ordinary files but failed silently (no error at all) on the same very large, heavily-textured file that previously crashed on import.

**Root cause, by re-applying the same lesson rather than guessing fresh**: `saveFile`'s `bytes` parameter still crosses into native code via the same `StandardMessageCodec`/`MethodChannel` mechanism, bound by the same small Java heap — the earlier "already decimated" reasoning underestimated scale: the default 3,000,000-triangle budget alone is ~275 MiB of geometry before a single texture byte, plus up to 512 MiB of textures. A large enough export can still be several hundred MiB, hitting the identical class of failure in the opposite (Dart-to-native) direction — manifesting as a swallowed/silently-failed call here rather than import's hard crash.

**Fix**: `_exportMesh` no longer uses `saveFile` at all — writes the encoded bytes to a real file via plain `dart:io` in the app's own sandboxed temp directory (`path_provider`, no permission needed), then hands only the *file path* to `share_plus`'s share sheet so the user can save/send it anywhere. Neither step puts the file's bytes through a platform channel. New dependencies: `path_provider`, `share_plus`.

**Not yet re-tested** — needs the user to confirm export now succeeds (and the share sheet appears) for the same large file.

## 2026-07-08 — Added a Flutter CI workflow - the client had none at all

User asked how CI was looking; checking turned up the repo's only workflow (`backend-verify.yml`) is path-filtered to `backend/**` — every Dart change this entire session had only ever been checked by manual structural review in this SDK-less sandbox, with on-device testing by the user as the only real verification. **Added** `.github/workflows/client-verify.yml`, mirroring the backend workflow's shape (checkout, Flutter setup via `subosito/flutter-action@v2` `channel: stable`, `pub get`, `analyze`, `test`), path-filtered to `client/**`.

**Known risk, flagged rather than silently discovered**: `docs/roadmap.md` already documents pre-existing, never-actually-fixed test failures — the first real CI run may surface these (and possibly others, first time the entire suite runs from scratch) unrelated to this session's changes. Deliberately not fixed proactively — better to let the workflow establish ground truth than guess at fixes for tests never seen failing for real.

**The first real run happened immediately** — `pub get` succeeded, but `flutter analyze` failed with two real compile errors: (1) **a genuine bug this session introduced**: `SharePlus.instance.share(ShareParams(...))` isn't part of `share_plus 10.1.4`'s actual API (that unified surface exists only in a later major version) — only `Share.shareXFiles(...)` exists. Exactly the risk of writing Flutter code with no compiler to check it against. **Fixed**: switched to `Share.shareXFiles`. (2) **a genuine pre-existing bug, unrelated**: a test fixture constructs `SketchGeometry3D` without the now-required `circleIds` argument — one more instance of the "known but only visible in a real sandbox" class the roadmap already anticipated. **Fixed**: added the missing arg. Also cleaned up two minor lints while touching these files.

**Not yet re-verified** — pushed a fix commit; next CI run is the real confirmation.

## 2026-07-08 — The second CI run found something much bigger: `flutter_scene 0.18.1` doesn't compile against current Flutter stable at all

`flutter analyze` now passed cleanly, and `flutter test` ran for real for the first time this session: 332 passed, 19 failed. Nearly all 19 trace to one root cause unrelated to this repo's code: `flutter_scene 0.18.1` fails to compile against the `flutter_gpu` bundled with Flutter stable 3.44.5 — core types (`gpu.VertexLayout`, `gpu.VertexFormat`, etc.) don't exist in that build. Broke `part_viewport_test.dart` (failed to compile) and `part_screen_test.dart` (compiler crashed outright), accounting for the bulk. One further failure looked unrelated.

`flutter_gpu` is Flutter's still-experimental GPU layer, known to move even within a "stable" release — the trap a third-party package built against its internals falls into. Asked the user what Flutter version they actually build/run with: `Flutter 3.46.0-1.0.pre-223`, channel **master**, not stable (matching `.metadata`'s own tracked revision). The CI failure wasn't "this repo's code doesn't work on modern Flutter" — it was "this workflow grabbed the wrong channel."

**Fix**: `client-verify.yml` now uses `channel: master`, with a comment explaining this is *not* a general recommendation — the only channel that currently reflects how this project is actually built.

**Not yet re-verified** — the separate unrelated failure still needs its own look regardless.

## 2026-07-08 — `channel: master` confirmed: the flutter_scene/flutter_gpu compile break is gone. CI now shows the real state of this test suite for the first time ever

`channel: master` resolved it completely — `analyze` clean, `test` now compiles and runs every file. Total jumped 351 → 534. **Result: 508 passed, 26 failed** — none in any file touched by this session's own commits, real ground truth for the first time. Breakdown: 4 in `sketch_controller_test.dart` (exactly the failures the roadmap already documented as known-but-never-fixed); 14 in `part_screen_test.dart` (one shared root cause suspected, not yet confirmed); 3 in `orbit_camera_test.dart` (new discovery, unrelated to this session); 1 each in 5 other files. Given the scope, flagged back to the user for priority rather than fixed unilaterally.

## 2026-07-08 — `part_screen_test.dart`'s 14 failures: several distinct root causes, all in the test file itself (no app bugs among them) plus one real UI overflow bug found along the way

All 14 traced to the test file being stale against real, intentional product changes — not app regressions:

1. **`ExpansionTile` expand-tap missing (2 tests)** — two tests never tapped "View" open before searching its children. Fixed by adding the tap.
2. **Duplicate "Cancel" button, genuinely new (5 tests)** — Prompt A4 added a second Cancel (banner) alongside the panel's own. Fixed via `.last`/`findsNWidgets(2)`.
3. **Revolve/Sweep joining Extrude's long-press menu, genuinely new (1 test)** — a disabled-reason string now appears 3x not once. Fixed the count.
4. **Stale pre-B4 assertion (2 tests)** — B4's true-rollback means tapping *any* Feature, locked or not, always opens it for editing; one test's whole premise ("tapping a locked Feature does nothing") directly contradicted already-shipped behavior. Rewritten to match.
5. **A genuine, real bug found in the process — `feature_context_menu.dart`'s bottom sheet overflowed**: with Revolve/Sweep now joining, the long-press menu can show 5 `ListTile`s with no scroll wrapper — a real `RenderFlex overflowed` on a short screen, masked until a test checked an ineligible Sketch (all 3 subtitles at once). **Fixed**: wrapped in `SingleChildScrollView`.
6. **One test tapped the wrong dialog button** — a standalone test bug, fixed.
7. **~3 remaining failures** not independently broken on inspection — very likely collateral from the same B4/animation-ticker-leak issue (a Feature tap that never waits for its camera animation before the test ends leaves a `Ticker` active, corrupting the *next* test's frame scheduling too). Left as-is pending the next real CI run.

## 2026-07-08 — The remaining 12 pre-existing CI failures (outside part_screen_test.dart): all diagnosed and fixed

Same pattern throughout: almost all test-file staleness, a small number of genuine small app bugs, found by reading each failure's actual code.

- `orbit_camera_test.dart` (3): one real bug — `_defaultDistance` was `80`, directly contradicting its own doc comment's worked-out math ("~48"). **Fixed** to `48`. One stale test — `setZoomBoundsForRadius` expectations were against pre-Prompt-A3 defaults; Prompt A3 intentionally bumped `kDefaultFarClip` to 3000, test never updated. **Fixed**.
- `sketch_controller_test.dart` (4): one real bug — `dragTargetPointIdAt`'s Line/Circle-resolves-to-nearest-endpoint path didn't exclude the origin the way the direct-point-hit path already did. Three test-coordinate bugs — taps meant to avoid a nearby snap target actually landed inside a widened hit radius or a midpoint-materialization radius, silently changing what got selected. All fixed (geometry moved, or the origin case corrected).
- Five single-file failures, all stale tests, no app bugs: a `SafeArea`-internal-padding false match, a permanently-running `Ticker` needing a bounded pump instead of `pumpAndSettle`, stale disabled-tile expectations for now-fully-wired Revolve/Sweep, a test targeting UI elements ("Click" tool, a flat speed dial) that no longer exist, and an ambiguous "spinner gone" wait condition that could also match a GPU-init error fallback state.

All 26 originally-documented failures diagnosed and fixed. Not yet re-verified by a real CI run.

## 2026-07-08 — First real re-run: 524 passed, 11 failed, down from 26 - all 11 were bugs in this session's own just-applied fixes, not new discoveries

Genuine progress (26→11), but every one of the 11 was a mistake in this session's own test-only fixes: a scroll-visibility gap after the expand-tap fix; 5 cascade-delete dialog tests needing to wait for an awaited network round trip rather than a fixed pump; a tooltip-based finder resolving to an internal overlay surrogate instead of the real FAB; the `dragTargetPointIdAt` fix itself wrong twice over (first pass substituted the *other* point when the nearer one was the origin, breaking two older passing tests that correctly expected the origin — the right fix was simpler: return `null` outright when the nearer point is the origin, and move the older tests' geometry away from the origin entirely); an unscoped `find.byType(Listener)` matching an ambient Scaffold-internal listener, not `PartViewport`'s own, reproducing the exact race the fix was meant to close (rescoped to a descendant find). Pushed again.

## 2026-07-08 — Third real re-run: 528 passed, 7 failed, down from 11 - one genuine, longstanding test-fixture gap found

Six of seven shared one real root cause: the test file's in-memory backend fake had never implemented `GET .../cascade-preview` — every long-press-Delete flow had been hitting a 404 on that call before the confirmation dialog could even show, silently setting an error and never showing the dialog. No amount of pump-waiting was ever going to fix that. **Fixed**: added the missing handler. The seventh was a real animation-timing gap — the Sketch screen's page-transition slide-in can still be in flight when the title text is already in the tree; tapping "Exit Sketch" too early misses. **Fixed** with an extra settle pump.

`part_viewport_test.dart`'s "Fix 4" continues as the one holdout — even properly scoped, its Scene-setup wait sometimes never resolves within budget, looking like genuine CI-sandbox GPU-init flakiness rather than a code-correctness issue. Bumped the pump budget as a pragmatic attempt. Pushed again.

## 2026-07-08 — Fourth real re-run: 530 passed, 5 failed - the cascade-preview fix itself introduced one new class of bug, plus one confirmed environment-flakiness finding

Making the preview call succeed exposed a real ambiguity the previous `_pumpUntil` fix didn't account for: the closing context-menu's own "Delete" tile can still be mid-exit-animation exactly when the new dialog's own "Delete" button appears, so a plain text search briefly matches both. **Fixed** (3 tests): scope the tap to `find.descendant(of: find.byType(AlertDialog), ...)`. One more animation-timing gap, symmetric with the earlier push-side fix, now on the pop side. **Fixed** with the same settle pump.

`part_viewport_test.dart`'s holdout now conclusively diagnosed: Scene setup genuinely resolves to the known "Flutter GPU requires Impeller" error for this exact test (not a hang), while the adjacent test only passes reliably because its own assertions happen to be satisfied either way — real, external GPU-init flakiness in this CI sandbox's software renderer, not a reachable bug. Flagged as a known limitation. Pushed again.

## 2026-07-08 — Fifth and sixth re-runs: 3 → 2 → 1 failure, then confirmed green

Two more real bugs: the `AlertDialog`-scoping fix worked for 2 of 3 remaining cascade-delete tests but exposed one more ambiguity in the third, plus a genuine timing gap in the un-hide bookkeeping's own visibility-icon update — both fixed with the same scoped-find/extra-settle-pump techniques. The "pre-selected Sketch" test's own `find.byTooltip('Add')` had the identical unreliable-tooltip-position issue as `Exit Sketch` — switched to `find.widgetWithIcon`, which surfaced one more layer (a Hero-flight duplicate FAB mid-transition) — fixed by waiting for the flight to actually finish instead of guessing a duration.

**Final confirmed result: 534 passed, 1 failed** — the already-diagnosed CI-sandbox GPU-init flake, not new. All 26 originally-flagged failures resolved for real, confirmed by CI itself — nine total CI round-trips across the four failure clusters, catching (and re-catching) mistakes in this session's own fixes along the way.

## 2026-07-08 — Widget-test lessons written up as a standalone reference

Everything learned above about writing/fixing Flutter widget tests correctly — tooltip-tap unreliability, `pumpAndSettle()` vs permanently-running Tickers, the `_pumpUntil` pattern, proxy-signal waits, unscoped finders, Hero-flight duplicates, fake-backend endpoint coverage, stale-vs-real-bug diagnosis — distilled into `docs/flutter-widget-test-lessons.md`, matching the project's convention of splitting reusable how-to knowledge out of dated narrative entries (see `docs/live-preview-pattern.md`). Read that file first before touching any widget test in this repo.

## 2026-07-08 — One more real CI bug found after "green": `flutter analyze` had been failing every run, masked by only checking the test step

Every prior CI-progress entry checked only the test-run step's pass/fail count, never the `Analyze` step's own conclusion — which had actually been failing (`analyze` exits 1 on any issue, including info-level) on every run, including the ones already reported "534 passed, 1 failed." Real cause: 3 pre-existing `avoid_print` findings in `part_viewport.dart`'s diagnostic logging (deliberately `print`, not `debugPrint`, per that code's own comment). **Fixed**: added `// ignore: avoid_print` above each rather than removing them, since the reasoning for using `print` there is still valid. Confirmed via the next real run: `Analyze` now succeeds, only the same already-diagnosed GPU-init flake remains.

**Branch merged to `main` via PR #94** — closing out the full lighting/shading-upgrade branch (PBR rollout, mesh viewer decimation/materials/Up-axis/mirroring fixes, native Save/Load and STEP/STL/OBJ/glTF export/import, Revolve/Sweep, the new Flutter CI workflow, and all 26 pre-existing test failures it surfaced).

## 2026-07-14 — Polygon promoted from a client-only shortcut to a real, persisted entity (`claude/sketcher-roadmap-tuning-7z3shf`)

Resumed the sketcher-tuning package's last deferred item: reinterpreting a Polygon vertex drag as a circumradius edit instead of an unconstrained 2D point move. Investigating first confirmed the constraint graph alone couldn't reliably identify "this Point is a Polygon vertex" — `EqualRadiusConstraint` has no discriminating field between Polygon's raw-point path and Arc/Slot's entity-based path. Given three options, **user picked the most thorough: a real Polygon entity**, matching Arc/Ellipse/Slot.

**Backend**: new `Polygon(SketchEntity)` (center Point, `sides` vertex Points, edge Lines, own constraint-id bookkeeping) and `Sketch.add_polygon`/`polygons()`/`delete_polygon`, mirroring the Arc/Ellipse five-endpoint shape. `add_polygon` creates the whole regular-polygon constraint chain atomically (one circumradius `DistanceConstraint`, `sides-1` `EqualRadiusConstraint`s, `sides-1` pairs of `EqualLengthConstraint`+`AngleConstraint`), replacing the old client-orchestrated multi-call sequence. 16 new backend tests.

**Client**: `SketchController` replaced session-only `PlacedPolygon` bookkeeping with a real API-loaded `SketchPolygonView` map; `_clickPolygonTool` now one `createPolygon` call; delete/undo gained full Polygon support. Drag handlers now detect a Polygon vertex and, once its circumradius constraint is confirmed, PATCH that constraint's value to `distance(center, cursor)` instead of the raw position — reusing the existing throttled mid-drag-solve infrastructure.

Verified: `flutter analyze` clean, `flutter test` at established 442/-19 sandbox baseline (19 pre-existing sandbox-only GPU incompatibilities). Four commits pushed.

## 2026-07-14 — On-device feedback found a real regression in the drag fix above: it was silently over-confirming the dimension it edited

User reported: adding an "across flats" dimension to a Polygon over-constrained it with nothing visible explaining why. Root cause: the drag-as-circumradius-edit fix called `updateConstraintValue` on every drag tick, and that endpoint unconditionally clears the constraint's `provisional` flag as a documented side effect — so an ordinary "nudge this to look right" drag silently confirmed a real, DOF-removing dimension the user never explicitly set. A second explicit dimension on top then genuinely over-constrained the sketch, and the now-confirmed circumradius constraint didn't render as a readable dimension to explain why (`isRadiusDistanceConstraint` only recognized Circle/Arc, falling through to a misleading generic linear dimension with no drawn edge).

**Fixed**: a vertex drag is now only reinterpreted as a dimension edit once the circumradius constraint is *already* confirmed — while still provisional (the common unconfigured case), it removes zero DOF, so an ordinary drag already resizes correctly via the equal-radius chain with nothing to confirm. Also taught the recognizer to render a confirmed circumradius as a proper radial leader, matching Circle/Arc.

Same report flagged that a Polygon's auto-created angle ties/equal-length glyphs are implicit structure, not user dimensions, and shouldn't surface unless the shape is broken. **Fixed**: new `isImplicitPolygonEdgeTie` (true when both Lines are edges of the same still-existing Polygon) wired into both paint and hit-testing so these ties are neither rendered nor selectable while intact — deliberately forward-looking, since `delete_polygon` currently cascades everything together (a future trim/extend that removes just one edge would make them real information again).

Also scoped (not implemented) a trim/extend tool — researched the actual gap (no line-line/line-circle/line-arc intersection math exists anywhere; naively moving a shared endpoint would silently drag every other entity anchored to it) and wrote it up as **Phase 11** in `docs/sketcher-overhaul-scope.md`.

Verified: `flutter analyze` clean; `flutter test` at 447/-19 (5 new tests).

## 2026-07-14 — Removed the broken 3D backdrop, added New Sketch on Face, reworked the sketch-start camera sequence

Four more on-device requests, same branch. Status audit first confirmed which roadmap phases were actually shipped vs still-open (genuinely open: Phase 5 reference-axis alignment, Phases 8/9/10/11).

**Removed the shaded-body backdrop behind the flat 2D sketch canvas** — root-caused why it never worked: its camera was necessarily perspective (`flutter_scene` has no orthographic camera), synced to the 2D canvas's pan/zoom at only one target depth — anything off that plane showed real perspective foreshortening a flat orthographic canvas can never reproduce. Removed outright along with Canvas Transparency (whose sole purpose was revealing it); the sketch's own profile fill is untouched; Orbit View remains the only place real Body geometry shows.

**Added "New Sketch on Face"** — selecting a single Body face now offers this alongside "Create Plane": one tap creates a zero-offset `CreatePlaneFeature` flush against the face and immediately starts the orientation-confirm flow.

**New sketch-start camera sequence**: New Sketch → animate to isometric for orientation definition → confirm → animate to the chosen orientation → sketcher (previously cut straight to face-on before orientation-confirm even appeared; custom planes got no animation at all). New `OrbitCamera.isometricOrientation()` (true `asin(1/sqrt(3))` ≈ 35.264° isometric, plane-independent) plays first for every new sketch.

Verification note: every touched file transitively imports `flutter_scene`, unexecutable in this sandbox — `flutter analyze`-clean and manually reviewed (plus a hand-verified isometric-angle unit test), real confirmation still outstanding for all four items.

## 2026-07-14 — Phase 11 implemented: trim/extend a Line

Same branch/day. Resolved the scope doc's three open design questions via documented code comments: multiple crossing candidates resolve to whichever is nearest the dragged endpoint's current position; reach capped at 10000 sketch units (mirrors an existing precedent); a Polygon's own edges rejected as trim targets outright for v1 (demoting a Polygon to loose geometry is real scope, deferred).

**Backend**: new `app/sketch/intersections.py` — plain-tuple line/circle/arc intersection math, ported from the client's own private screen-space algebra for the line-line case, standard quadratics for circle/arc. `Sketch.trim_or_extend_line` scans every other Line/Circle/Arc, picks the nearest valid crossing, moves the dragged endpoint — in place if provably unshared, otherwise via a fresh Point (reusing the existing shared-endpoint-check helper, generalized). New `POST .../lines/{id}/trim`; distinct `NoIntersectionFoundError` → 422. 20 new tests.

**Client**: `trimLine` + new `SketchMode.trim` — tap handler hit-tests only Lines, reinterprets the tap as "which end is closer" (mainstream CAD convention), stays active across repeated picks. Undo of a shared-endpoint trim deletes the trimmed Line/new Point and recreates the original fresh (no API exists to repoint a Line's endpoint id directly). 7 new controller tests.

Verified: backend 20/20 new, full suite unchanged at 9 pre-existing failures; client `flutter test` 454/-19 (7 new).

## 2026-07-14 — On-device round: seven fixes surfaced by real use of the trim/extend + New-Sketch-on-Face rollouts

Batch of on-device reports, six fixed and pushed, one needed a follow-up clarifying question:

- **"New Sketch" missing when selecting a Plane** — the earlier addition only covered a Body face, not a lone Plane. Mirrored the face case.
- **Orbit View gone for a custom-plane sketch** — camera/rendering was hard-wired to a fixed `ReferencePlaneKind`. Generalized the whole path to `SketchPlaneBasis`. Also fixed a related bug where a custom-plane sketch's own flip/rotation was silently dropped on re-open.
- **Polygon still breaks when dragging an edge, not just a vertex** — a rigid-body translation of a chord almost never equals a pure rotation about the center. Redirected edge-drag to the already-correct vertex-drag scaling gesture.
- **Over-constrained / stale-fully-constrained until re-entering the sketch** — three call sites that PATCH an existing constraint's value only re-solved on their sibling "create new" branch, never on re-confirm. Now all solve unconditionally.
- **Angle dimension not offered between two Lines** — an absolute rejection threshold in the intersection math guarded only near-parallel blow-up; two Lines far apart with a shallow angle could produce a valid-but-far-outside-canvas intersection. Ghost layout now falls back to straight-line-to-midpoint when unreasonably far.
- **Dimension-mode picks weren't highlighted** — the selection check only read Select-mode's set, not Dimension mode's separate pick set. Fixed to check both.
- **Ghost/projected body outline never shaded** — only the Sketch's own profile got shading, not the projected ghost wireframe (no id/topology). New `closedGhostLoops` recovers real closed loops itself (snap-merge endpoints, keep degree-2-node edges, walk each component) — v1, no nested-hole punch-out.

Verified: `flutter analyze` clean throughout; `flutter test` climbed 454→467/-19 across 5 commits, no regressions.

## 2026-07-14 — Two more on-device findings from the same round

**Materialized Body-edge references were solid geometry, not construction** — `create_external_edge_reference`'s own line-add call never passed `construction=True`, so a projected Body edge behaved as real drawn geometry (eligible for profile/extrude detection) instead of a dimensioning reference. One-line fix plus a backend assertion.

**"Face the plane" camera animations never recentred, only reoriented** — the shared orientation-animation helper only ever slerped the camera's orientation, never its target — if the user had panned before the animation ran, the camera ended up facing correctly but still centred on the old pan position. Both `animateToPlane`/`animateToBasis` now also animate `target` back to the plane's own origin.

Verified: backend confirmed against a real conda pythonocc-core env (3 passing, same 2 pre-existing unrelated failures); client change `flutter analyze`-clean with a passing regression test, camera fix itself unexecutable here.

## 2026-07-14 — Slot "fully constrained too early" root-caused and fixed

Two more on-device Slot reports: (1) a freshly-drawn Slot showed fully-constrained with only a Horizontal constraint on its centerline, before its radius was ever signed; (2) a screenshot showed a wrong extrude body (two circles joined by a twisted saddle instead of a stadium prism).

**Correction to a prior assumption in this file**: pythonocc-core **is** actually importable in this sandbox's conda env — the persistent "not available here" caveat on OCCT tests earlier in this file was stale, not currently true. Let both reports be reproduced and root-caused directly.

**Root cause of #2 was a bug in the reproduction script, not the product** — an early repro grabbed the wrong Line (construction centerline instead of perimeter) via list-index lookups instead of capturing ids from creation responses the way the real client does. Once fixed, extrude produced a correct stadium body every time. No product bug found — flagged in case the same shape resurfaces on-device.

**Root cause of #1 was real**, reproduces from Slot creation alone. `solve_sketch`'s existing `REDUNDANT_OKAY` override trusts `system.Dof` even though py-slvs's naive param-minus-equation count is exactly what that override exists to route around — for this specific redundant system it reports `dof: 0` regardless of whether the radius has ever been confirmed (a reporting bug, not a geometry bug — Point positions stayed correct throughout).

**Fixed**: whenever `solve_sketch` converges and any `DistanceConstraint` is still provisional, `dof` is floored to `max(system.Dof, 1)`. Harmless everywhere else (a clean non-redundant solve already reports correctly).

2 new tests. Full backend suite: 799 passed (was 797), same 9 pre-existing unrelated failures.

## 2026-07-15 — Session close-out: wrote a standalone sketcher architecture/UX-rethink scoping document

Requested directly: the user is still unhappy with sketcher UX (how entities/shapes resolve when moving things), asked for a separate document covering every tool's full functionality, every design decision's rationale, and options for a dedicated LLM scoping session. Three concrete ideas named: moving sketch solving onto the client (push to backend only on exit); changing how translations work when moving/editing; ensuring shapes are created with correct relationships from the start.

Researched via two parallel deep dives (client tool flows; backend entity/constraint/solver architecture) rather than reconstructed from memory. **New file** `docs/sketcher-architecture-ux-scoping.md` — full entity/constraint/solver model, every tool's exact round-trip-counted flow (Slot most expensive at ~20-25 round trips per placement, tied to having no real backend entity of its own), a drag/move deep-dive, a round-trip/latency inventory flagging `_refreshAllPoints`'s N+1 pattern as the biggest scaling cost, a design-decisions log, and an options section addressing all three named ideas plus lower-risk items. No code changes.

## 2026-07-16 — PR #95's first real CI run: fixed 20 client test failures, all stale for the sandbox's own reasons

First real execution ever of the `part_screen_test.dart`/`sketch_screen_orbit_view_test.dart`/`sketch_orientation_indicator_test.dart` files (still transitively `flutter_scene`-blocked in every sandbox — every prior "passing" claim for these meant analyze + review only). Surfaced 20 failures accumulated silently across earlier sessions.

Two shared root causes covered the bulk: (1) an SVG-icon migration left several `find.byIcon` finders stale (an `SvgIcon` isn't a named `IconData`); (2) an orientation-confirm step ahead of every new-Sketch creation meant several older tests timed out never tapping "Continue" first. A viewport field rename broke one more. An orientation-UI relocation (hamburger → Feature-tree long-press) left a whole 5-test group silently testing a menu entry that no longer exists — removed with a comment flagging the acknowledged coverage gap (no replacement test exists yet).

The last failure took three CI round-trips: a widget-count check plus a guessed settle pump tapped the wrong target since the FAB is the *same persistent widget* across a push/pop; `pumpAndSettle` timed out outright since `PartViewport`'s render loop schedules frames indefinitely in this sandbox; fixed with many small manual pumps instead of one big jump, giving post-frame callbacks a chance to run.

Verified via real CI on the final commit: client 699 passed, 1 failed (the accepted GPU flake); backend 799 passed, 9 failed (the same established baseline). PR #95 CI-clean, ready to merge.

## 2026-07-17 — Rollout step 3, Phase 0 + Phase 1 Milestones A–E: FFI solver lands in the real client, gated on real on-device confirmation

Milestone plan: A round-trip reduction, B native foundation, C Dart solver port, D Android build wiring, E wire into the live drag path, F on-device confirmation. Miniforge/pythonocc-core installed on this physical Windows laptop (same one the earlier spike used) so the backend suite could run here for real.

**A**: `_refreshAllPoints`'s N+1 per-point GET replaced with one `listPoints` call. New `POST .../solve-and-refresh` bundles solve+points+constraints+profile into one response, collapsing ~26 call sites' triples into one call each. Backend 801 passed, 10 failed (confirmed all pre-existing, a Windows-native py-slvs quirk vs the Linux CI baseline, flagged not chased). Client 698/699.

**B**: vendored `realthunder/solvespace` as a pinned submodule. Wrote `slvs_ffi_shim.cpp`/`.h` (30 `extern "C"` functions, each catching at the FFI boundary — a C++ exception must never unwind across `dart:ffi`, per the earlier spike's finding). Two-step CMake build (vendored lib built standalone first; shim links the resulting archive directly, since `find_library` doesn't work against the NDK's restricted search). Two Windows-only snags fixed (Android-only spike never hit them): `SLVS_STATIC_LIB` must be defined for static linking; MinGW needs explicit export macros. Desktop parity harness reproduces both of the spike's on-device parity cases against fresh real backend ground truth.

**C** (`client/lib/sketch/local_solver/`): full FFI bindings, a literal port of the Python constraint builder (handle-memoization caches, sign-preserving distance projection, angle-supplement disambiguation), dispatch for all 15 `ConstraintDto` types reusing the client's existing DTOs, and `solveSketchLocally` (port of `solve_sketch` incl. the redundancy-safe convergence override and the Slot-fix provisional-DOF floor). Not yet ported: circle cardinal-point sign-fixing (flagged, out of scope here). 4 new tests incl. the Slot construction end to end, all pass.

**D**: skipped Gradle's `externalNativeBuild` (doesn't fit the two-step recipe) for the spike's proven prebuilt-`.so`-in-`jniLibs` pattern. Built for `arm64-v8a`; confirmed depends only on `libc`/`libdl`/`libm`, exports all 30 symbols; a real release APK confirmed the `.so` is bundled (492KB stripped). Not yet automated into any build graph.

**E** (`sketch_controller.dart`): `updatePointDrag`'s mid-drag reflow now tries the in-process solver first (no throttle needed), falling back to the server round trip if the native lib isn't loadable or local solve throws. `endPointDrag`'s final PATCH stays server-side unchanged. Scoped to `updatePointDrag` only ("one narrow path first") — `updateLineDrag` untouched. New test confirms zero `/solve` requests during a locally-solved drag. All 703 pre-existing tests unchanged, confirming the fallback is invisible.

**Not done, deliberately: Milestone F** — needs the user to connect the device.

## 2026-07-17 — Milestone F: real on-device confirmation, and a genuine release-build networking bug found along the way

Connected the real test device (S23 Ultra) over wireless ADB, installed a real release build. First connection attempt to the production backend failed with a generic "Could not reach server."

**Root-caused rather than guessed at**: ruled out, in order with real evidence — the backend itself (curled directly, 200 OK); the stored API key; a stale autofilled key; Private DNS; the VPN/meshnet; per-app network/battery restrictions. None of it. A temporary diagnostic `print` (release builds strip debug logging) surfaced the real exception: `SocketException: Failed host lookup` for this app's process specifically, while the same phone/network resolved the hostname fine in a browser at the same moment.

**Actual root cause: the app has never had the `INTERNET` permission in a real release build.** The base `AndroidManifest.xml` never declared it — it only ever existed in the debug/profile manifests, added there specifically for Flutter's hot-reload/DevTools connection. `flutter run` (debug) always worked because of that; a genuine `flutter build apk --release` never had network access at all. Confirmed both ways via `aapt2 dump permissions` before/after adding `<uses-permission android:name="android.permission.INTERNET"/>` to the main manifest. This is the first time in the project's history a real release APK was built and network-tested against a live backend, and it surfaced a gap nobody had hit before for exactly that reason.

**Verified, real, on-device**: connection succeeded; dragging a plain Point was confirmed noticeably smoother — the actual thing Phase 1 exists to fix. Also confirmed and expected (not a regression): a Polygon vertex or Slot's own points still feel exactly as slow, since Milestone E deliberately only wired the local solver into the plain-Point drag path. User explicitly deferred widening this: "let's finish the changes we're already doing before solving this."

## 2026-07-17 — Phase 2 (plane-embedded 3D sketching), milestones P1-P5: tap-to-place Point/Line lands inside Orbit View itself

Moving sketch interaction into the same 3D viewport/camera as Orbit View instead of a separate flat 2D canvas. Researched first: backend needs zero changes (Points always flat local 2D, solver never sees 3D); Orbit View's embedded viewport already existed half-built, read-only, gated only on the earlier lack of an orthographic camera — now resolved. Four decisions confirmed first: rollout via a **persisted setting** (2D stays available until 3D is proven); **Point + Line only**; **tap-to-place only** (sidesteps orbit-vs-drag ambiguity); **orthographic as default** — this last one grew mid-conversation, since `isPerspective` had been a no-op flag everywhere, not just here; user confirmed "let it apply everywhere," so the rollout goes app-wide.

**P1**: new `SketcherPreferences`/settings screen, one bool `use3DSketcher`. Orbit View toggle now seeds from it.

**P2**: promoted the spike's `OrthographicProjection`/`OrthographicCamera` into production unchanged. `cameraFor()` now actually branches on `isPerspective` for the first time; every call site widened to match. Mesh viewer pins perspective explicitly, unaffected.

**P3**: new `hitTestSketchPlane` — simpler than `hitTestReferencePlanes` (only one candidate plane here). Pure function, unit-tested.

**P4**: viewport gained a sketch-plane tap handler converting the world-space hit to local (x,y) and feeding it into the *same* `handleCanvasTap` every 2D tap already uses — zero controller/tool logic changed. Speed dial restricted to Point/Line while embedded (Dimensions/Trim rely on 2D-only ghost-picking).

**P5 (verified already-correct, no code needed)**: every existing snap path already works once P4 converts a 3D tap into the same coordinate space; live rendering already wired via the existing `AnimatedBuilder`.

Verified: `flutter analyze` clean; `flutter test` 708, same one flake. **P6 (on-device confirmation) is the remaining gated step.**

## 2026-07-17 — P6 confirmed on-device; P7-P10: real Bodies now shape the sketch-plane surface, grid, and Dimension-mode picking

**P6.** Confirmed on-device: "sketcher now feels connected to the model and viewer" — tap-to-place works, bodies visible behind the sketch plane for the first time. Phase 2's P1-P6 scope complete.

That pass immediately surfaced three follow-on needs (canvas transparency has something to see through now; embedded background should match the main viewport's; the plane needs visual structure with no flat canvas under it) plus real Body edges/vertices being directly pickable, starting with Dimension. Scoped as a P7-P11 batch via planning before building.

**P7**: the embedded viewport was silently discarding the persisted background colour — fixed.

**P8**: no rendered surface existed for the active plane while embedded-sketching. New surface builder (translucent fill + border, mirrors `reference_planes.dart` but built directly in world space since a custom plane has no fixed rotation table). New Orbit View menu entries reusing existing colour/opacity sheets.

**P9**: no grid-rendering precedent existed anywhere. New pure grid-line function (fixed finite extent — a camera-following "infinite grid" would need a shader, deferred) plus a GPU builder mirroring the existing geometry/builder split. New toggle, default on.

Both P8/P9 sit at the same depth as real drawn geometry — pushed a small render-only epsilon backward to avoid z-fighting (never fed into hit-testing/coordinate conversion).

**P10**: tap-priority lives in the viewport layer (the controller never sees ray coordinates), mirroring the flat canvas's existing Dimension-mode priority. On a miss against Sketch entities, runs the existing vertex/edge-only Body hit-test (face excluded, no ghost-face-pick method exists) and calls the already-existing ghost-pick methods directly — zero backend/controller changes, only a new trigger point.

Verified: `flutter analyze` clean; `flutter test` 711, same one flake. Real-device-only for the actual feel.

## 2026-07-17 — On-device round on P7-P10: grid/surface fade, a genuine tap-priority answer, and two unrelated bugs caught along the way

User also explicitly deprioritized the flat 2D canvas ("it will probably get killed off"), mooting an open architecture question about toggling Orbit View off.

**Grid/surface fade + border removal**: the hard-edged border didn't suit a see-through surface, and both stopped abruptly instead of fading. `UnlitMaterial` has no per-vertex gradient, so both approximate one via constant-alpha primitives: the surface layers 5 concentric squares; the grid splits each line into 6 pieces faded by distance from origin.

**Tap priority — real bug found and fixed**: `hitTestBodies`'s filter defaults to `face: true`, but P10 left it at default — a Dimension-mode tap on a Body face resolved to a face hit with no handling case, silently swallowing the tap instead of falling through to the plane-tap miss. Fixed with an explicit face-excluded filter.

**Feature-tree "long-press a Plane row > Hide" wasn't wired at all** — the Planes-section shortcut row never got the same long-press the Features-section row already had. Added for parity.

**New: origin/reference planes auto-hide after the first real Body** — a placement aid for an empty Part, clutter once a Body exists.

**New: default view orientation rebuilt to a Z-up CAD convention** — explicit ask. The old `pitch*yaw` camera composition targeted a Y-centric scheme; both presets rebuilt from the desired world-space screen axes directly. Hit a genuine `vector_math` quirk along the way, confirmed by a numeric probe: `Quaternion.rotate()` computes the opposite multiplication order from what's commonly assumed — a bare construction rotated axes to the wrong world directions; `.conjugated()` compensates.

Verified: `flutter analyze` clean; `flutter test` 712, same one flake. Real-device-only.

## 2026-07-17 — Cursor/select mode for the embedded 3D sketcher (P12-P14), and a real depth-sort bug found and fixed

User asked to roll out 2D-sketcher features to the viewport sketcher, starting with cursor/select mode. Planning first reframed it from "build a selection system" to "wire up one that already exists": hover/highlight machinery, selection-driven controller actions, and `SketchRibbon` were all already screen-agnostic or built, just conditionally hidden during Orbit View.

**P12**: mode-indicator pill un-hidden during Orbit View, viewport selection mode now follows the controller's own state, restricted filter (sketchPoint/sketchLine only).

**P13**: found the reusable precedent — `selectConstraint`'s own body already implements "add-to-selection-vs-replace." Extracted into a public `selectEntity`; new adapter methods convert between the two selection representations.

**P14**: dropped `SketchRibbon`'s Orbit-View gate (a plain screen-space overlay with no 2D dependency) — brings Delete/Make Construction/relational-constraint chips/Length-edit across essentially for free.

**A real depth-sort bug, found and fixed along the way.** Two reports on the previous round's grid/surface work: grid rendering behind the surface (should be in front), and the fade shape wrong. The fade was a straightforward math rework. The depth-order bug led to reading `flutter_scene`'s own depth-sort source: the translucent pass sorts by a Node's *transform origin*, not its mesh vertices — but the surface/grid builders left Nodes at identity transform with world-space positions baked into vertex data, so every primitive sorted as if at the world origin, falling back to insertion order. Fixed by moving all position data into each Node's own `localTransform`.

**Fade shape rework**: full alpha through 80% of radius, linear taper over the remaining 20%, replacing the fade-from-centre approach.

Verified: `flutter analyze` clean; `flutter test` 711, same one flake. Real-device-only for the actual feel.

## 2026-07-17 — Camera rollback, orientation-tool orbit-mode fix, grid-fade edge-distance fix

On-device feedback: the previous round's Z-up camera rewrite made things worse. User asked for a clean rollback plus a better way to nail the exact desired view than more screenshot comparisons.

**Camera rolled back** to the exact pre-session code, diffed directly against git history to be certain — back to the original `pitch*yaw` composition. Two orientation tests reverted to match, keeping only the unrelated (and still correct) `cameraFor()`-signature-widening fix from P2.

**Suggested a better calibration method**: have the app report the live camera's exact numbers while the user manually orbits to precisely the desired view, rather than more screenshot guessing — offered as a temporary debug readout, not yet built.

**Sketch-orientation tool now forces orbit mode, restoring cursor mode after** — a real on-device-found bug: entering orientation-confirm never touched `_selectionMode`; if cursor/select mode was active, orbit gestures (needed to judge a pending orientation from multiple angles) were silently unavailable the whole time. Fixed at both entry and both exit points.

**Grid fade fixed to use edge-distance, not centre-distance** — the previous fade used Euclidean distance from centre, correct for a circle but wrong for a square (a corner is `extent*sqrt(2)` from centre, an edge midpoint only `extent`) — corners faded out well before edges, an asymmetry the user caught directly. Fixed to Chebyshev distance, reaching the extent uniformly along the whole square boundary.

Verified: `flutter analyze` clean; `flutter test` at 710 (net -1), same one flake.

## 2026-07-17 — Camera calibration: a real debug tool, a real sign bug it found, and the isometric default finally correct

User ran a genuine confidence test with the offered debug readout: orbit to a known orientation (checked against the on-screen triad as ground truth), read the tool's numbers, confirm they match. Immediately found a real bug: **every axis's "right" value had the wrong sign** — plus supplied a reference capture of the actual desired default view, asking for "the nearest isometric view" to those numbers.

**Root cause, found by deriving `triadAxes` algebraically**: `OrbitCamera.right`/`.up` are the camera's own local-frame vectors, not necessarily what renders as screen-right/up. `triadAxes` derives its own independently — working through the algebra shows `triadRight = -OrbitCamera.right` exactly, while `triadUp` is unchanged. The debug tool now reproduces `triadAxes`'s own formula directly instead of reading `OrbitCamera.right`/`.up`. **This also explained why the earlier (already-rolled-back) Z-up rewrite looked wrong despite passing its own unit tests**: those tests checked internal self-consistency, never cross-checked against `triadAxes`'s negated-for-"right" convention — a mirrored-on-screen result could pass every test.

**The new isometric default**, *numerically pre-validated this time* (a throwaway scratch test checked against the user's actual captured numbers before touching real code): X+/Y+ both read screen-left, Z+ reads pure screen-up. Also structural, not just numeric: the old `pitch*yaw` composition can *only* ever produce an `up` vector with a zero world-X component — mathematically incapable of reaching this corner, confirming the general vector-construction approach (used, minus its wrong target vectors from the rolled-back attempt) was the right tool. Default and true-isometric are now the same view (previously deliberately different).

Since `MeshViewerScreen` never overrides the camera's default orientation, this fix reaches it automatically too.

Verified: `flutter analyze` clean; `flutter test` at 711, same one flake. User confirmed on-device: "the values in the debugger are now correct according to the axes on the triad."

## 2026-07-17 — Settings screens split by area; camera debug readout promoted to a real toggle in each; sketch-orientation default flip for XY/XZ

Three asks: (1) split the combined Mesh Viewer + Sketcher settings menu into two independent ones; (2) the debug readout should become a real persisted toggle in both settings screens, not a hardcoded `const bool`; (3) a new Sketch's default orientation on XY/XZ should start pre-flipped.

**Settings split**: Connect itself restyled into the same 80/20 stadium-split shape the Mesh Viewer bar already uses (Connect / gear → Sketcher settings); Mesh Viewer's own gear goes straight to its settings screen. The intermediary list screen deleted (confirmed zero remaining references first).

**`SketcherSettingsScreen` retitled "CAD Settings"** — now also holds a setting unrelated to sketching specifically (the debug toggle).

**Camera debug readout promoted to a real, persisted toggle - and given to the mesh viewer too**, which has its own entirely separate camera (confirmed via its own doc comment: deliberately not reusing `PartViewport`). Shared computation/widget moved into `triad.dart` next to `triadAxes` — keeps the "must match the trusted triad, not raw camera vectors" invariant in one place. Two new independent persisted booleans, one per viewport, so each readout toggles independently.

**Sketch-orientation default flip for XZ/YZ**: the un-flipped default reads backwards specifically on XZ and YZ. Caught a real follow-on correctness issue while implementing: `createSketchFeature` always creates with `flip=false`/`rotation=0` server-side — previously harmless since the client's old default matched, but with a non-zero default now possible, opening a Sketch without touching flip/rotate would leave the *rendered* view flipped while the *persisted* record still said unflipped, silently reverting on next reload. Fixed by sending one PATCH before opening, only when the confirmed values actually differ from the just-created defaults.

Verified: `flutter analyze` clean; `flutter test` at 711, same one flake.

## 2026-07-17 — Sketch-orientation default flip: stopped guessing, computed it

The XZ/YZ fix got feedback that oscillated ("XZ and YZ need flipping" → "XY and XZ now require flipping... each time you fix this another breaks") — a genuine whack-a-mole signal that hand-derivation was the wrong tool, same failure mode already caught once this session on the camera work. Asked for exact numeric target readouts per plane instead of continuing on verbal descriptions.

**Stopped hand-deriving, computed instead**: a throwaway scratch test called the real, unmodified orientation function for all 3 planes × both flip states × all 4 rotation values (24 combos), diffed against the user's 3 captured targets programmatically.

**Findings**: YZ's unmodified default was already an *exact* match — every previous round's guess to flip it was wrong. XY and XZ: *no* currently-supported combination exactly matches either target — `flip=true` is closer for both, but the in-plane axes still don't fully match; getting them exactly right needs a non-zero default rotation too, which nothing currently sets. Flagged as real, separate follow-up.

Default flip corrected to XY/XZ only (YZ back to unflipped). User separately flagged some camera *animations* also "ended up looking the wrong way" — flagged as very likely the same root cause (an animation slerping toward a wrong computed target looks wrong at the destination without the animation mechanism itself being at fault), pending confirmation.

Verified: `flutter analyze` clean; `flutter test` at 711, same flake.

**Follow-up same day: the default camera view itself had been dropped.** The original calibration message actually contained four targets — only the per-plane three got investigated. Caught when the user asked directly. A scratch test confirmed the new target *before* any production edit this time: the exact negation of the previous round's right/up (a 180° yaw), same isometric elevation. `_isometricOrientation`'s right/up vectors flipped accordingly; test updated. Verified, fresh build installed.

## 2026-07-17 — The actual root cause of the whole plane-orientation saga: `orientationFacingBasis` couldn't represent a flipped view at all

User gave an exact target for XY's default and asked for a full audit of all 8 orientations × 3 planes. Given the fix-one-plane-break-another pattern of the last several rounds, treated this as a signal to find the actual root cause instead of patching defaults again.

**Found it, computed rather than guessed.** A scratch test checked, for every plane/flip/rotation combination, whether `xAxis × yAxis` actually equals `basis.normal`. Result: **`flip=true` makes the basis left-handed for every plane, unconditionally.** `orientationFacingBasis` built its camera matrix from `basis.normal` directly, ignoring this — but the quaternion construction can only represent a proper rotation; handed a left-handed input, it silently produces a wrong result. This is why every previous per-plane flip guess kept "breaking another plane" — the function was fundamentally incapable of representing *any* flipped state, for *any* plane.

**The fix**: derive viewing direction from the basis's own actual handedness instead of trusting `normal` blindly — a no-op for every already-correct case.

**Verified exhaustively**: all 24 combinations diffed against the three independently-captured targets — all three now match exactly, confirming a true no-op on the one that was already right. Every other combination now forms a clean predictable pattern instead of erratic "stuck" values.

**Code changes**: fixed the function; the per-plane default is now a proper `(bool, int)` pair (previously only ever varied flip, never rotation — exactly why two planes were unreachable through guessing alone). New tests covering all 24 combinations plus the three real targets as a regression guard.

Verified: `flutter analyze` clean; `flutter test` 738 (27 new), same one flake. Also directly explains the earlier "some animations looked wrong" report — every plane-facing animation calls this same function.

## 2026-07-18 — Face-selection contrast, and Fillet/Chamfer directly from a selected face

Face selection used the same mid-saturation blue as vertex/edge selection, hard to tell apart — switched to a brighter, more opaque accent blue of its own. A lone selected face now also offers Fillet and Chamfer directly in the context menu, resolved against that face's own boundary edge loop, instead of requiring hunting down individual edges by hand.

## 2026-07-18 — Convert Entities v1 (Sketcher-roadmap Phase 9): pull Body vertices/edges into a sketch as real geometry

New "Convert Entities" tool lets a sketch pick a sibling Body's vertex or straight edge and materialize it as an ordinary, editable Point/Line — a frozen, one-time copy distinct from Phase 4.3's live-pinned dimensioning references. Reuses that feature's own OCCT vertex-resolution machinery via two new endpoints, so this carries no new coordinate-precision risk.

`Sketch.add_or_reuse_point` lets two separately-converted edges sharing a Body vertex end up sharing one real Point, so the result can register as a closed profile for Extrude — same reasoning as an earlier `trim_circle` fix.

Scope note (v1, later superseded — see 2026-07-21): a curved Body edge converts as its own straight chord, not its true curve, left as an explicit fast-follow.

## 2026-07-18 — Offset Entities v1 (Sketcher-roadmap Phase 9): parallel/concentric copy of a Line/Circle/Arc

New "Offset" ribbon action for a single selected Line/Circle/Arc — prompts for a signed distance, creates a real independently-editable parallel (Line) or concentric (Circle/Arc) copy. Pure 2D math, zero OCCT dependency, so every geometry test runs for real.

`Sketch.add_or_reuse_point` keeps two collinear offset Lines connected at their shared join. A wrong assumption caught while writing tests: two Lines meeting at a real angle do *not* share a point after independent offsetting (no corner-join logic yet) — confirmed as the correct v1 boundary via a dedicated test (corner-joining landed the next day as v2).

## 2026-07-18 — Convert Entities v2: associative/live-linked Body vertex/edge references

`convert_body_vertex`/`convert_body_edge` now create real, non-construction geometry with associative endpoint Points instead of frozen copies — reusing Phase 4.3's existing external-references/pinning/staleness machinery verbatim (none of it is construction-status-aware). Staleness detection and the tree's "lost reference" indicator now work for Convert-Entities geometry with zero additional code. Re-pick idempotency is now identity-based (exact Body vertex match) rather than position-epsilon based.

Replaced v1 at the same endpoints/wire shapes. Known, inherited (not introduced) limitation: `dragTargetPointIdAt` has no exclusion for external-reference Points — dragging one visually works but snaps back on the next solve, same as any pinned reference.

## 2026-07-19 — Auto-prune orphaned Points on delete/trim (on-device feedback)

"When deleting lines, curves, trimming I end up with floating, redundant points" — deleting an entity had always deliberately left its defining Points behind (might still be shared), correct as a default but leaving genuine orphans forever. Most visible via `trim_circle` (converting a Circle to an Arc only reuses the center Point).

New `Sketch._prune_orphaned_points` (OCC-free, real tests) runs after every delete/trim endpoint, removing each entity's defining Points that the existing deletion-blocker check finds no remaining reference to — never touches a still-shared Point.

The 7 DELETE endpoints changed from bare 204 to 200 + `pruned_point_ids` (a real wire-contract change); client's `deleteSelected` folds this into its existing capture/undo system.

## 2026-07-19 — Backend crash fixed: forward-referenced response schemas broke server startup

Pydantic evaluates type annotations at class-definition time in this file (no `from __future__ import annotations`) — the previous entry's `OffsetCircleResponse`/`OffsetArcResponse` were placed before `CircleResponse`/`ArcResponse` are defined further down, causing a `NameError` on every server startup. Exactly the forward-reference pitfall already documented elsewhere in this file's own doc comments — missed because the only verification available for OCC-dependent files in this sandbox is AST syntax parsing, which checks grammar not name-resolution order. Fixed by reordering; added a script-based ordering-aware check (flags any field/signature referencing a not-yet-defined name), run clean against every file touched in this stretch.

## 2026-07-19 — On-device feedback round: body-edge dimensioning fix, 2D-editor default flip, Offset cursor mode, Tools FAB grouping

**Real bug, predating this stretch (not caused by Convert Entities)**: Dimension mode's body-edge/vertex picking had silently stopped working once Orbit View's cursor-precision model started covering Dimension mode — the tap handler actually used there was never taught to consult the real-Body hit-test path; only the older, now-unreachable path was. Fixed at the root, so Convert Entities and the new Offset mode get real-Body picking for free too.

**Fix: "tapping a sketch in the tree opens the old 2D editor."** There was never a second route — the 3D-sketcher default preference was still `false`, so any device that had never visited Settings landed every Sketch in the flat 2D canvas. Flipped to `true` now that 3D has real feature parity; 2D stays reachable via the in-sketch toggle FAB.

**New: Offset mode** — the cursor can now pick a Line/Circle/Arc directly via a new hand-off the UI reacts to with the same distance dialog the ribbon action already used.

**New: "Tools" FAB category** groups Dimensions/Trim/Extend/Convert Entities/Offset one level down (mirroring "Sketch Entities"'s own two-level shape), plus a persistent "Finish" button for all four modes.

## 2026-07-19 — On-device feedback: hide the draw cursor while dragging an entity in Orbit View

"When I grab something to drag, the cursor should disappear and it should feel like I'm moving the entity around." New `suppressDrawCursor`, true while something is actually grabbed — hides the crosshair entirely so the moving entity itself reads as what's being dragged. The crosshair's screen position keeps updating throughout (it drives the drag), so it simply reappears at the drop location with no extra plumbing.

## 2026-07-19 — Convert Entities picks a whole face's edges; Offset picks a Body edge directly; a real body-visibility toggle

**Convert Entities**: selecting a Face now converts every one of its boundary edges in one tap (sequential, not concurrent — the backend's point-reuse only works correctly if the first edge's conversion has actually completed before the second's request goes out, since adjacent edges share a Body vertex). New filter widening includes Face for this mode only.

**Offset mode** can now pick a Body edge directly — converts it (same associative mechanism) then hands the result straight to the offset flow, so one cursor tap reaches the distance prompt instead of a separate Convert-then-Offset session.

**"Show/Hide Reference Body"** now also toggles the real 3D body meshes in Orbit View, not just the 2D canvas's projected ghost overlay. New `bodiesHidden` suppresses only rendered mesh/edge Nodes — real-Body hit-testing and camera framing stay fully intact while hidden.

## 2026-07-19 — Fix: linear dimensions sliding along the line during camera orbit

Linear dimension labels visibly drifted each frame while orbiting, because their dragged offset was a raw screen-pixel delta reinterpreted through a normal that rotates with the camera. Mirrors an earlier radial-dimension fix: stores a camera-independent, sketch-local perpendicular distance instead, resolved via a sketch-plane raycast, with the renderer re-deriving a fresh screen offset each frame. Scoped to the default linear case only, per the reported symptom — widened in a follow-up round.

## 2026-07-19 — A pulsing "glow" added to the selected-face highlight, then reverted the same day

A static tint was still hard to notice even after an earlier contrast pass. Added a repeating brighten-toward-white pulse (mutates the material color in place each tick, no geometry rebuild). The very next on-device round found this read as "moving," not "lit up" as intended, and reverted it in favor of a palette-distance approach (see below).

## 2026-07-19 — Offset Entities v2: chain-aware, corner-joining multi-entity Offset

"Offset should allow multiple entities and operate intuitively — if the origin lines are connected, the offset lines should be connected, effectively trimming/extending the new lines to their intersect."

**Backend**: new `Sketch.offset_chain` offsets each entity independently (same math/sign convention as before), then for every original Point shared by exactly two of the given entities, resolves their new intersection and uses it as the shared corner (nearest-to-original tiebreak when a curve gives two candidates). A branch/T-junction point (3+) or an unshared end just keeps its raw offset. New endpoint + schemas. 16 new, fully executable tests (no OCCT dependency), including hand-verified exact corner coordinates.

**Client**: Offset's cursor pick now accumulates Line/Arc taps into a selection set instead of showing the dialog immediately (a Circle tap still goes straight to the single-entity dialog — no chain endpoints to join). Finish button submits: zero picks exits, exactly one uses the existing fast path, two+ hand off to the new chain endpoint.

## 2026-07-19 — On-device feedback round: face-highlight contrast take 2, face occlusion, linear-dimension slide follow-up, Convert Entities cursor mode

**Face highlight**: reverted the pulsing glow (wrong read) in favor of picking whichever of a small high-saturation palette is furthest (RGB distance) from the user's own Body Colour, so it can't collide with an arbitrary chosen body color the way the old fixed blue could.

**Real occlusion bug fixed**: `hitTestBodies` let a far-side vertex/edge win purely on 2D screen-space proximity, with no regard for a nearer face rendered in front of it — "picking edges through faces." Added an opt-in face-occlusion check (only when render mode shows filled faces and bodies aren't hidden) dropping a candidate sitting behind the nearest face along the ray.

**Linear dimension camera-slide, part 2**: the original fix only covered the general-direction point-to-point case. Extended the same camera-independent technique to the vertical/horizontal-orientation case and to the separate Line-to-Line distance dimension, which the original fix never touched.

**Fixed Convert Entities never showing a cursor**: the crosshair's own mode gate was missing that mode entirely, despite an existing doc comment claiming it had been added — a real regression, not a design gap.

## 2026-07-19 — On-device feedback round: dynamic hover highlight, non-modal Offset value bar with live ghost preview, Tools flyup 2-row layout

**Hover highlighting fixed for Dimension/Convert Entities/Offset**: the filter feeding hover computation was a permanently vertex/edge/face-off constant, so nothing but Sketch entities ever hover-highlighted in those modes even though the tap path already targeted real Body geometry via its own separate filter. Made it mode-aware to match what's actually tappable.

**Offset tool overhauled**: replaced the modal distance dialog with a non-modal bottom fly-up bar (mirroring the existing dimension bar's "taps still reach the canvas" shape) driven by a live preview distance, with a live dashed ghost preview (reusing the existing draw-tool ghost types) so flipping the typed value's sign visibly flips which side the offset lands on. Unified the previous single/multi-entity one-shot hand-offs into one persistent target list, since the value bar needs to stay populated for the whole editing session.

**Tools flyup** now lays out two rows of two, matching Sketch Entities' own grid.

## 2026-07-19 — On-device feedback: eyeball FAB actually toggles bodies now, face highlight fixed against a translucent Body, edge line thickness bumped

**"Show/Hide Reference Body" FAB fixed**: it flipped state but the viewport's widget-update diff never checked it, so neither mesh nor edge sync ever re-ran — the toggle had no visible effect. Added to both trigger conditions.

**Root-caused "dynamic face highlight isn't working"**: the embedded sketcher's Orbit View defaults Body opacity below 100%, routing the Body's material onto the translucent render pass — the same pass this codebase already found has an unreliable on-device depth test (documented for edges elsewhere). A face highlight sits at the same depth as the surface, so the translucent Body could redraw over it. Added a triangle-bias-toward-camera fix (mirroring the existing edge-bias fix) applied everywhere a face highlight is built.

Edge stroke width bumped 1.1 → 1.4.

## 2026-07-21 — Curved Body edges convert as real Arcs instead of always flattening to a chord

"When I offset a curved edge it creates a straight line." Convert Entities'/Offset's edge conversion had always flattened a circular Body edge to a chord — the v1 scope note from 2026-07-18, never revisited until now.

**New pure-math layer** (`plane_geometry.py`, OCCT-free): `signed_distance_to_plane`; `resolve_planar_circle` (checks both axis-parallel and centre-on-plane, since either alone is insufficient); `resolve_ccw_arc_endpoints` (a real OCCT edge sweeps whichever direction it sweeps, no guarantee it matches the Sketch model's own always-CCW convention — resolved by sampling a genuine third point on the curve). 10 new tests, all executable here.

**OCCT-bound glue**: pulls a Body edge's real curve type/circle params/a sample point, delegates every decision to the pure-math layer — `None` for anything not circular or not coplanar, falling back to the existing chord behaviour exactly.

**Wiring**: tries the Arc path first, falls back to chord on `None`. Response carries exactly one of line/arc plus a center Point (v1 limitation: unlike associative endpoints, the centre is a plain non-associative Point). A full circle still 422s before curve-type detection — real Circle extraction is a separate follow-up.

**Client**: new kind-aware DTO replaces the old always-a-Line one, with full undo for the Arc case. Also fixed: picking a Body edge for Offset used to hand the result straight to the value bar (correct pre-v2, never updated once chain picking landed) — now accumulates into the same pick set as any other tap. Line thickness nudged up again per feedback.

Verified: 10/10 new backend tests pass; full client suite at 288/288 (this sandbox still has no `pythonocc-core`, so the OCCT-bound half of this fix - `resolve_circular_edge_arc` itself - is untested here by the same long-standing environment gap noted throughout this document; the pure-math layer it delegates to is fully covered). Installed on the real test device (Galaxy S918B) over wireless ADB.

## 2026-07-21 — Session covering 14 on-device reports: planes, dimensions, drag/solver, Sweep, tree UX

A single large session working through 14 separate on-device reports, batched by subsystem. Not yet confirmed on-device for most items - see each batch's own note below.

**Visibility:** hiding a user-created Plane (`create_plane` Feature) only ever wired the feature-tree eye-icon UI, never the actual render/hit-test path (`_recomputeCreatePlaneGeometries` built its geometry map unconditionally) - a prior fix attempt only got half of this. Fixed by filtering that map by the existing hidden-id set, same pattern `_visibleSketchGeometries` already used. Separately, other Sketches were never visible while orbiting inside the embedded 3D sketcher (`_embeddedSketchGeometries` only ever built geometry for the *active* Sketch) - now merges in every other Sketch, gated by the same "Hide/Show Reference Body" toggle that already covers Bodies, per the on-device ask ("the same hide/show button... should also hide and show other sketches").

**Rendering:** a reference/user-created plane's border rendered with a visible kink/gap at one corner - `PolylineGeometry`'s per-vertex miter never wraps around an open point list, so the shared start/end corner of the closed-loop border got two different, unbisected tangents instead of one shared miter. Fixed by padding the point list with a wrap-around neighbour on each side before handing it to `PolylineGeometry`, purely for the border geometry (the fill quad is unaffected). Sketch line colour (`_unconstrainedColor`) is now derived from the canvas background's own estimated brightness (`ThemeData.estimateBrightnessForColor`) instead of a fixed charcoal, so it reads as black or white depending on light/dark background, per the on-device ask for higher contrast.

**Sweep:** four issues, all in the same path-picking/wire-construction code. Only `Line` was ever a valid path segment - an Arc could be selected (hit-tested) but never actually added to the path (`_toggleSelectedEntity`'s dispatch only routed `sketchLine`), and a second router-level payload gate (`_validate_sweep_path_refs`) independently rejected anything but `line` even after the dispatch gap was closed - both fixed, plus generalized to Ellipse (always closed/standalone, so only valid as a lone complete path, never chained) and Spline. Backend wire construction (`app.document.sweep._resolve_path_segment`) now builds real Arc/Ellipse/Spline OCCT edges per segment, reusing `app.document.extrude.wire_for_profile`'s already-proven math (mirror-aware Arc P1/P2 swap, Spline Bezier poles) rather than re-deriving it. Also fixed: `SweepPanel` was missing the same initial-`onChanged`-kick `ExtrudePanel`/`RevolvePanel` already have, so its live preview never appeared until an unrelated click. 22/22 sweep backend tests pass (18 existing + 4 new, run against a real OCCT build via Docker); full backend suite unchanged at 861 passing / 28 pre-existing failures (confirmed unrelated by re-running against the unmodified code).

**Feature tree:** now auto-collapses after confirming or cancelling any feature edit (Extrude/Revolve/Sweep/CreatePlane/Fillet/Chamfer), mirroring the existing open-to-pick/close-once-picked pattern the Sweep/Revolve sketch-picker sub-step already had, so the user sees the feature they just worked on instead of the tree covering it.

**Dimensions:** the drag-direction-inverted and can't-regrab-after-move reports traced to the same root cause - the painter and the hit-tester used two different position formulas for a linear/line-distance dimension's label, and the painter's own perpendicular-offset normal was derived from arbitrary Point-creation order (swapping which Point is "A" flips the offset direction). Unified into one shared position function (`_dimensionLabelPlacement`) both now call, and made the normal canonical (a fixed screen-relative convention, not order-dependent) - fixes both reports at once, confirmed via an updated/new unit test. Also implemented the requested "move anywhere" overhaul: a linear/line-distance dimension's label can now slide along the dimension line too (not just its perpendicular offset), growing a short leader back to the line once it does - mirroring the radial dimension's own already-existing shoulder-and-landing-leg pattern, not a new design. Separately fixed: adding a horizontal dimension between two Points that already had a vertical one deleted the vertical one (`confirmGhostValue` treated *any* differently-oriented existing constraint as superseded, when only a generic `'linear'` one actually is - vertical and horizontal are complementary, not conflicting). And: both dimension-value text editors (the ghost editor and the ribbon's re-edit editor) now pre-select their whole value on open instead of just prefilling it, so typing immediately overwrites.

**Drag/solver:** discovered mid-session that `docs/sketcher-restructure-plan.md`'s Phase 1 (in-process FFI SolveSpace solver, `client/lib/sketch/local_solver/`) was already partially shipped - `updatePointDrag`'s mid-drag reflow already tries it before falling back to the network path, but `updateLineDrag` never did. Extended it there, which surfaced a real, previously-latent bug: a Horizontal/Vertical Constraint between two simultaneously-anchored Points, combined with any other Constraint reaching from one of them to a free Point, could make the native solver silently move an "anchored" Point anyway (not yet root-caused at the FFI/SLVS level). Fixed with a safety check - verify every anchor landed within tolerance before trusting/applying the rest of a local solve's result, otherwise fall back to the network path - extending `_trySolveDuringDragLocally`'s existing "never partially applied" contract to cover an internally-inconsistent success, not only an outright failure. Verified via 2 new tests against the real native library (already built at `client/native/slvs/build-host/`), one confirming the extension, one reproducing the bug and confirming the fallback.

**Sketch origin grounding:** investigated but not fixed - audited every basis-resolution path on both sides of the wire (backend `basis_for_sketch`, client `SketchPlaneBasis`, "New Sketch on Face") and all of it reads consistent; no reproducible bug found via static reading alone. The design question itself has an answer: the origin is already a real, pinned backend Point, not a good candidate for the Convert-Entities-style external-reference mechanism (the world origin isn't a Body vertex to reference). Flagged as needing an on-device repro to make further progress, not guess-fixed.

**Offset curved edge:** investigated, not fixed - the exact reported symptom ("offset a curved edge creates a straight line") already has a fix in the 2026-07-21 entry above; re-read the whole pipeline and found nothing further to fix without a specific repro.

Verified: `flutter analyze` clean project-wide; full client suite 865/866 (the 1 failure is the pre-existing CI-sandbox Impeller/GPU flakiness already documented above, reproduced identically without any of this session's changes); full backend suite 861/889 passing, the 28 failures confirmed pre-existing and unrelated (same failures reproduce against the unmodified code). None of this has been confirmed on a real device yet.

## 2026-07-21 — 3D-embedded dimension parity port + new standalone "2D Drawing" tool (thin v1)

Follow-up to the session above: asked whether that session's dimension-overhaul fixes actually reached the app's default sketching experience. They hadn't - `sketch_canvas.dart` (the flat 2D canvas) and `sketch_constraint_overlay.dart` (the 3D-embedded sketcher's own, independent dimension-overlay renderer/hit-tester) are two separate implementations, and only the former was fixed. `SketcherPreferences.defaultUse3DSketcher = true` confirms the 3D-embedded one is what users actually see by default.

**Part 1 - ported the dimension fixes to `sketch_constraint_overlay.dart`:** the diagonal-case order-dependent normal sign, and the paint/hit-test unification (`_dimensionLabelPlacement`, giving linear/line-distance dimensions the same free-label-placement-with-leader the radial dimension already had). Also found and fixed a **second, 3D-only bug this port surfaced**: an earlier fix (P52, camera-independent offset scaling via `sketchLocalOffsetDistance`) updated the painter but never updated `constraintOverlayItemLabelCenter`, its hit-test twin - the two disagreed the instant the camera moved since a dimension was last dragged, breaking regrab in a way the flat 2D canvas never had (no camera to move). Also ported the sketch-line-contrast fix (`_computeEmbeddedSketchEntityColors`'s fallback, now derived from `ViewPreferences.bgColourHex` the same way the 2D canvas's fix uses its own `canvasColor`). 6 new/extended tests in `sketch_constraint_overlay_hit_test_test.dart`.

**Part 2 - new standalone "2D Drawing" tool, thin v1.** User's idea: rather than deprecating the flat 2D canvas once the 3D-embedded sketcher covers in-Part sketching, repurpose it as a standalone tool for floor plans and other Part-free 2D drawings, with an eventual DXF export pipeline. Investigated first: a bare `SketchScreen()` with no Part args already works standalone today (nothing hard-requires a Part; it's what `ensureSketch()`'s default XY-plane sketch already is) - confirmed the right foundation, not the 3D-embedded UI (which would drag in a whole unneeded `flutter_scene`/`OrbitCamera`/Body-mesh stack). DXF export, a backend "my drawings" list, and drafting fundamentals (units/layers/sheets) are all genuinely greenfield - scoped out of this thin v1 deliberately.

Shipped this pass:
- **Backend**: `app.document.native_format.sketch_to_dict`/`sketch_from_dict` made public (were already exactly the right serialization, just private to the Part-level native-file format) and reused directly by two new endpoints - `GET /sketch/sketches/{id}/export`, `POST /sketch/sketches/import` (always a fresh id, 422 on malformed input) - rather than inventing a second persistence layer. 7 new tests.
- **Client**: `SketchScreen.standalone` (skips auto-entering Orbit View regardless of the device-wide 3D-sketcher default; adds Save/Open to the hamburger menu, mirroring `part_screen.dart`'s own native-file `FilePicker` pattern exactly). New `ToolChooserScreen`, inserted between `ConnectionScreen`'s successful Connect and what used to be a direct jump to `PartScreen` - now offers "3D Part Design" or "2D Drawing". 5 new tests.

## 2026-07-21 — The same-day Z-mirror render fix was over-applied; reverted for the Part Modeller

Same day, later. User reported Boss/Sweep/Revolve all appearing to build in the wrong Z direction, and the on-screen triad looking backwards, immediately after the "app-wide 3D viewport Z-mirror bug" fix earlier today (`renderMirrorCorrectedMesh`, `mesh_geometry.dart`). Ruled out the camera/triad first (`triad.dart` and `orbit_camera.dart`'s ordinary `cameraFor()` path weren't touched by today's fix, and were independently cross-checked against real on-screen geometry throughout the July 17 calibration sessions - not the cause).

**Confirmed by a controlled on-device test, not guessed**: sketched a rectangle on the XY plane, extruded (Boss) in the positive direction. The rendered grey body appeared on the *negative* Z side, but hovering over where the body would be if it had built in the positive direction produced real hover highlights (selectable), and tapping the visible grey body did nothing. This is decisive: `hitTestBodies`/`boundsOfBodies` (`part_viewport.dart`) read `body.mesh` raw, never through `renderMirrorCorrectedMesh` - so the *rendered* mesh and the *hit-testable* mesh had silently diverged into two different coordinate spaces the instant `_syncMeshNode`/the edge-sync function started applying that correction. The raw (hit-test) data landed exactly where the user expected; the render-corrected data didn't.

**Root cause of the over-application**: `renderMirrorCorrectedMesh` was built and validated against a single labeled-reference-STEP-file *import* test, then applied "uniformly regardless of Body source (Import, Extrude, Revolve, Sweep)" on the reasoning that every Body source shares the same client-side mesh-upload code path. No on-device report, across this entire project's history, ever flagged Extrude/Revolve/Sweep rendering mirrored before that fix landed - only imported files and the separate, already-resolved mesh-viewer glTF/GLB sagas. That absence, plus today's direct repro, points at the original bug being specific to Import, not universal - the backend's own `BodyMeshResponse.source` (`"placeholder"`/`"computed"`) currently has no way to distinguish an Import-produced Body from any other kind, so a correctly source-scoped fix isn't possible without a small backend addition first.

**Fix**: `part_viewport.dart`'s `_syncMeshNode` and its edge-sync counterpart no longer call `renderMirrorCorrectedMesh` - both read `body.mesh`/`previewOverlayMesh` directly again, matching every other consumer in this file (`hitTestBodies`, `boundsOfBodies`, `_doRecentre`'s bounds scan, dimension/Convert-Entities vertex-position resolution) that was never touched by the correction in the first place. `renderMirrorCorrectedMesh` itself is left defined and tested (not deleted) - the function's own math is still correct for whatever *does* need it, but doc-commented as currently unused pending a properly source-scoped re-diagnosis for Import specifically. The Mesh Viewer's own, separate `applyRenderMirrorCorrection` (`mesh_data.dart`) is untouched - unrelated screen, no evidence it's wrong, and it already has user-facing Up-axis/Mirror toggles rather than an automatic uniform correction.

**Not yet re-tested on-device** - needs the user to confirm a fresh Boss/Sweep/Revolve now builds and renders on the expected side, and that Fillet/Chamfer preview (which also went through `renderMirrorCorrectedMesh` via `previewOverlayMesh`) still looks correct. Whether Import still needs its own correction (and, if so, what backend field should discriminate it) remains open - flagged in `roadmap.md`.

`flutter analyze` clean on the two changed files; full client suite 873/874 (same one pre-existing GPU-sandbox flake as every other round, reproduced identically against the unmodified code before this fix).

## 2026-07-22 — The real root cause found: a genuine, confirmed mirror bug in `flutter_scene` 0.18.1's own view-matrix construction, not this app's data anywhere

Follow-up to the entry above, same investigation continued. On-device test of the revert: a fresh Boss extrude now renders self-consistently with hit-testing (fixed), but the user separately reported the *original* mirroring problem was back too - a labeled SolidWorks STEP import renders as a genuine mirror image, confirmed by orbiting a full turn (an asymmetric feature never lands correctly from any angle - ruling out a camera-angle illusion, the same test this project's mesh-viewer saga established as necessary before concluding "genuine reflection"). Then, decisively: a **from-scratch DIDSA-CAD Boss (no import involved at all) is *also* a genuine mirror** against SolidWorks - "DIDSA-CAD parts are wrong, they are mirrored... these are facts."

**Ruled out, in order, each with hard verification (not assumed):**
- `plane_geometry.py`'s `_PLANE_BASIS` table - hand-verified right-handed for all three fixed planes using the literal standard `(1,0,0)`/`(0,1,0)`/`(0,0,1)` world axes (`x_axis cross y_axis == normal` holds for XY, XZ, YZ simultaneously, which is the actual mathematical definition of a right-handed system - not just each plane self-consistent with itself).
- `import_geometry.py`'s `_shape_from_step` - read directly: a completely vanilla `STEPControl_Reader`, zero coordinate transform of any kind.
- `step_export.py`'s `export_step` - read directly: a completely vanilla `STEPControl_Writer`, same.
- `mesh.py`'s `tessellate_shape`/`_append_face_triangles` - read directly: correctly handles OCCT's `TopAbs_REVERSED` face flag for winding/normals, but never touches vertex *positions*.

None of that code can introduce a reflection, and there's a hard mathematical backstop: two right-handed coordinate systems (which DIDSA-CAD's own basis and the STEP standard both provably are) can only ever differ by a *rotation* from each other, never a *reflection*. Combined with the user's own orbit test (a genuine, un-rotatable mirror, self-consistent with hit-testing throughout) - self-consistency without absolute correctness is exactly what you'd get from a mirror baked into the *camera itself*, since forward-rendering and its own inverse (`screenPointToRay`, used for hit-testing) share the same camera object and are tautologically consistent with each other regardless of any reflection baked into that shared camera - render-vs-hit-test agreement can never detect a camera-level mirror, only a data-level mismatch *between* two different code paths (which is what the entry above actually fixed).

**Root cause, found by reading `flutter_scene` 0.18.1's actual source** (`package:flutter_scene/src/camera.dart`, resolved via the local pub cache) rather than assuming: its private `_matrix4LookAt` (used by `PerspectiveCamera.getViewMatrix()`) computes `right = up.cross(forward)` - the wrong cross-product order for a right-handed view space (the standard convention, e.g. OpenGL's own `gluLookAt`, uses `forward.cross(up)`). `up.cross(forward) = -(forward.cross(up))` is a general vector-algebra identity, true for *any* up/forward, not a one-off case - so this is an exact negation of the standard right vector for every camera orientation, confirmed with a concrete numeric example (forward=(0,0,1), up=(0,1,0): flutter_scene's own formula gives right=(1,0,0); the standard formula gives right=(-1,0,0) for identical inputs). This is baked into the view-matrix *construction itself* - no camera position/target/up choice can compensate for it (negating the `up` input flips both the computed right *and* up together, a 180-degree in-plane rotation, not an un-mirror) - exactly matching the reported symptom: a real, un-fixable-by-orbiting mirror, for literally everything ever rendered through an ordinary `PerspectiveCamera` in this app.

This explains the whole day's saga in one shot, and several older ones too: `triad.dart`'s `triadAxes` already independently reimplemented this *same* buggy `up.cross(forward)` formula, specifically because it has to match whatever actually renders (its own doc comment already said as much); `orientationFacingBasis` (`orbit_camera.dart`) already explicitly negated its own target-right vector "because of" this exact bug, predating today by nearly two weeks (2026-07-10) - correctly compensating for a bug nobody had yet traced back to `flutter_scene` itself. Nothing ever looked wrong *from inside* DIDSA-CAD because every self-authored view (the isometric default, per-plane sketch-facing animations) was calibrated by eye against this same, consistently-mirrored rendering, across weeks of camera-calibration sessions that only ever checked self-consistency (does the debug readout match the on-screen triad, does the triad match what I said out loud) - never against an external, standards-compliant reference. Only today's STEP-file/SolidWorks comparisons ever did that.

**Fix, applied once at the actual root**: `orthographic_camera.dart` gains `correctedLookAt` (the same `_matrix4LookAt` structure, with the corrected `right = forward.cross(up)` order) and `FixedPerspectiveCamera` - a drop-in replacement for flutter_scene's own `PerspectiveCamera` (can't subclass/override that package's own private `_matrix4LookAt`, so this reimplements the same position/target/up/fovRadiansY/fovNear/fovFar shape with a corrected `getViewMatrix()`; reuses flutter_scene's own `PerspectiveProjection` unchanged, since the projection matrix is diagonal/scale-only and doesn't affect handedness). `OrbitCamera.cameraFor()` now returns `FixedPerspectiveCamera` instead of flutter_scene's own; `OrthographicCamera.getViewMatrix()` (this app's own pre-existing `Camera` subclass, which had deliberately reimplemented the *same* buggy formula to stay consistent with `PerspectiveCamera` before this was traced) now calls the shared `correctedLookAt` too. Since `Camera.screenPointToRay`/`getViewTransform`/`getFrustum` are all implemented generically on the base class in terms of `getViewMatrix()`, hit-testing and frustum culling are automatically fixed along with rendering - no changes needed anywhere else in the app (mesh rendering, sketch overlay, reference planes, dimensions, Convert Entities/Fillet/Chamfer picking all just consume whatever `Camera` object `cameraFor()` returns).

**`triad.dart`** (`triadAxes`/`debugCameraOrientationText`) updated to the matching `forward.cross(up)` order, so the on-screen compass stays in sync with what now actually renders.

**`orientationFacingBasis`** (the "look normal to this sketch plane" camera function) re-derived: its `targetRight`/`targetBack` negations existed solely to compensate for the render bug, now removed. Hand-verified via vector algebra (not guessed) that this keeps its *external* contract identical - `renderRight` still equals `basis.xAxis`, `renderUp` still equals `basis.yAxis`, for every plane/flip/rotation combination - only the camera's internal target values (and which physical side of the plane it ends up on: now the intuitive `+normal` side looking back through `-normal`, instead of the old `-normal` side looking through `+normal`) changed. This means the sketch-orientation confirm flow's per-plane flip/rotation defaults (`part_screen.dart`'s `_defaultPendingOrientationFor`) need **no changes** - they were tuned against `orientationFacingBasis`'s external behavior, which is provably unchanged.

**Explicitly NOT touched, and expected to look different on-device as a direct, correct consequence**: `OrbitCamera._isometricOrientation()`/`_defaultOrientation()` - the raw, hardcoded cold-start camera quaternion, built directly from `Matrix3.columns(right, up, back)` with no compensating logic at all (unlike `orientationFacingBasis`). This will now render as a genuine left-right mirror of whatever it showed before (same orientation, corrected camera) - which is the *intended* effect of fixing a real mirror bug, but means the "nicest isometric corner" aesthetic choice, calibrated by eye over multiple July 17 sessions against the buggy renderer, may want a fresh on-device look now that the renderer itself is trustworthy. Flagged in `roadmap.md` rather than guessed at further this round.

**Verification**: every stale test caught by this - `orbit_camera_test.dart`'s "matches the on-screen triad exactly" (hardcoded a *duplicate* of the old `up.cross(forward)` formula, not a call to the real `triadAxes` - updated to the corrected formula and re-derived expected values, negating only the right-column numbers per the proven "only right flips, up is unchanged" identity), `orientation_facing_plane_test.dart` (three separate hardcoded-formula duplicates, all updated the same way; the per-plane-default group's `expectedZReading`/`.z` components needed negating too - the "toward camera" reading genuinely flips since the camera now sits on the opposite physical side of the plane), and `triad_test.dart`'s own direct `triadAxes` unit test. All re-verified to pass *meaningfully* (matching the hand-derivation, not just re-passing tautologically). `flutter analyze` clean project-wide; full client suite 874 total, same one pre-existing GPU-sandbox flake (confirmed identical against the unmodified code, same as every other round this project has ever run).

**Not yet confirmed on a real device** - needs the user to re-check the labeled SolidWorks STEP import, a fresh Boss/Sweep/Revolve, and the default cold-start camera angle (expected to look mirrored-from-before, not a bug).

## 2026-07-22 — Confirmed on-device; two direct follow-ups from the camera fix, plus Import menu consolidation

User confirmed the SolidWorks STEP import now renders correctly. Two pieces of expected fallout, flagged the entry above but left for on-device confirmation, both reported and fixed the same day:

**Orbit drag direction inverted (horizontal only).** `OrbitCamera.orbitByScreenDelta`'s yaw term (`-dxPixels`) was hand-tuned entirely by feel against the *old*, buggy `PerspectiveCamera` - `_right`/`_up`/`orientation`'s own math never changed, only how a given orientation actually renders, so the same drag now visibly swings the model the opposite way. Fixed by flipping the sign back to `+dxPixels` (pitch's `+dyPixels` untouched - on-device feedback confirmed only horizontal orbit felt backwards, consistent with the render fix only mirroring the horizontal axis).

**The sketch-orientation tool's initial isometric view looked wrong.** `OrbitCamera._isometricOrientation()` - the raw hardcoded quaternion behind both the general viewport's cold-start view and the "New Sketch" orientation tool's first preview - has no compensating logic at all (unlike `orientationFacingBasis`, which was re-derived the entry above to keep its exact prior behavior). Mechanically re-derived (not guessed, not re-captured on-device) via the same vector-algebra approach as `orientationFacingBasis`'s own fix: negating its `right` vector (`(1, 1, 0)`, was `(-1, -1, 0)`) exactly cancels the render fix's effect on this specific hardcoded orientation, reproducing the identical on-screen corner as before the whole 2026-07-21/22 investigation. Confirmed by `orbit_camera_test.dart`'s own "matches the on-screen triad exactly" test: its expected values are back to their *original* (pre-investigation) numbers now that both the camera fix and this fix are in place together - a real regression in either fix alone would have shown up as a mismatch here, which is why this was trusted without needing a second on-device round-trip.

**Import menu consolidated**, per direct request: the File menu's single "Import…" entry used to silently guess the format from whichever file's extension the user picked (`FileType.any`, since `FileType.custom`/`allowedExtensions` has an already-documented Android MIME-filtering bug - see the mesh viewer's own identical workaround). New `import_format_dialog.dart`'s `showImportFormatDialog` prompts for STEP/STL/OBJ/glTF first (mirroring Export's own explicit format choice, but as one dialog instead of Export's four separate ListTiles); `PartScreen._importGeometry` then validates the picked file's extension against the chosen format instead of inferring it, surfacing a specific mismatch error instead of a wrong guess.

**Same day, follow-up: the user had actually meant Export, not Import.** The Import consolidation above was kept (a reasonable improvement on its own, doesn't hurt), and the same one-entry-plus-dialog shape was built for Export too. `part_toolbar.dart`'s File menu drops its `_exportFormats`-driven loop of four "Export STEP"/"Export STL"/"Export OBJ"/"Export glTF" ListTiles for a single "Export…" entry; `onExportPart` narrows from `void Function(String format)?` to a plain `VoidCallback?`. New `export_format_dialog.dart`'s `showExportFormatDialog` mirrors `showImportFormatDialog`'s shape (kept as a separate, not shared, implementation - export has no extensions-for-validation concern, so the two dialogs' data shapes genuinely differ, not just their direction). `PartScreen._exportPart` (now no-arg) shows the format dialog first, then proceeds to the existing folder/filename picker exactly as before.

Verified: `flutter analyze` clean project-wide; full client suite 874/875 (same one pre-existing GPU-sandbox flake). No dedicated test existed for `_importGeometry`/the File menu's Import entry, so nothing needed updating there.

## 2026-07-22 — The Mesh Viewer's own "same bug" fix from 2026-07-21 was the same mistake, for the same reason

Before rebuilding to confirm the camera root-cause fix, the user reported it caused a *new* mirroring specifically in the Mesh Viewer - suspecting a conflict with "an incorrect fix made before this session." Correct diagnosis: `mesh_viewer_screen.dart`'s `_applyCorrectionsIsolate` was still calling `applyRenderMirrorCorrection` (`mesh_data.dart`), the Mesh Viewer's own sibling to `viewport3d/mesh_geometry.dart`'s `renderMirrorCorrectedMesh` - built the same day (2026-07-21) from the same now-disproven diagnosis, and never touched by yesterday's revert (which only ever covered the Part Modeller). Since `MeshViewerScreen` shares the exact same `OrbitCamera` class the Part Modeller does (confirmed - it never overrides the default orientation), the Mesh Viewer's rendering was *also* silently fixed by the camera root-cause fix - meaning `applyRenderMirrorCorrection`'s own unconditional world-Z negation, previously coincidentally cancelling out the camera bug for whatever pose its original test happened to use, now had nothing left to cancel, and mirrored the model on its own.

**Fix**: `_applyCorrectionsIsolate` no longer calls `applyRenderMirrorCorrection` - now just `applyMirror(applyUpAxis(mesh, upAxis), mirrorFlag)`, matching the Part Modeller's own revert exactly. `applyRenderMirrorCorrection` itself left defined and tested (not deleted), doc-commented as unused for the same reason `renderMirrorCorrectedMesh` was. `applyUpAxis`/`applyMirror` (the two genuinely user-facing, independently-validated corrections) are untouched - both were calibrated against real file bytes via an out-of-band Python ground-truth comparison, entirely outside this app's own camera/GPU pipeline, so neither was ever actually entangled with the camera bug. `_exportMesh` reads the same corrected `_mesh` the viewer displays, so exported files are fixed along with the on-screen view with no separate change needed.

Verified: `flutter analyze` clean; full client suite 874/875 (same pre-existing flake). Not yet re-confirmed on-device - the user hadn't yet grabbed the new build when this was reported (comparing against the previous, `renderMirrorCorrectedMesh`-reverted-but-`applyRenderMirrorCorrection`-still-active build).

## 2026-07-22 — Two-finger pan also reversed (horizontal only); systematic sweep for anything else needing the same fix

Same day. User reported two-finger drag panning also reversed left/right, asked to re-confirm the default cold-start view and default sketch orientations were compensated, and asked for a systematic sweep of the rest of the client for anything else still needing the same class of fix.

**Pan fixed the same way as orbit and the isometric default**: `OrbitCamera.panByScreenDelta`'s horizontal term (`+_right * dxPixels`) sign-flipped to `-_right * dxPixels` (`+_up * dyPixels` untouched) - `_right`/`_up` are unrelated to and unchanged by the render fix, so a two-finger pan hand-tuned by feel against the old, mirrored renderer now visibly drags the scene the opposite way horizontally for the same gesture. `mesh_viewer_screen.dart` calls the same `OrbitCamera.panByScreenDelta`/`orbitByScreenDelta`, so this fixes the Mesh Viewer's own pan/orbit too, with no separate change needed there (same propagation as the render fix itself).

**Default cold-start view and default sketch orientations were already fixed**, in the same commit as the orbit-direction fix (`_isometricOrientation`'s `right` vector negation) - re-verified rather than re-guessed: `OrbitCamera`'s constructor always calls `_defaultOrientation() -> _isometricOrientation()` (already fixed), and the sketch-orientation tool's first preview goes through `PartViewport.animateToIsometric() -> OrbitCamera.isometricOrientation()`, the identical function. The per-plane confirmed defaults (`part_screen.dart`'s `_defaultPendingOrientationFor`: `XY: (true, 1)`, `XZ: (true, 0)`, `YZ: (false, 0)`) route through `orientationFacingBasis`, already re-derived to keep its exact external behavior (`renderRight == basis.xAxis`, `renderUp == basis.yAxis`) unchanged for every flip/rotation combination - confirmed again directly against these three specific values via `orientation_facing_plane_test.dart`'s own dedicated regression group, which still passes with its right/up numbers unchanged. No code change needed for either - flagged to the user that they were likely still testing a build from before that commit.

**Sweep, systematic not spot-checked**: grepped the whole client for every `.cross(` call (the operation at the heart of the actual bug) and for every consumer of `orientationFacingBasis`/`isometricOrientation`/`animateToPlane`/`animateToBasis`/`initialViewBasis`. Everything outside `orbit_camera.dart`/`orthographic_camera.dart`/`triad.dart` (all already fixed) either routes through those same, already-fixed functions (`part_viewport.dart`, `sketch_screen.dart`) or is unrelated to camera/view handedness entirely: `mesh_geometry.dart`'s triangle-normal cross product, `selection_hit_test.dart`'s Möller-Trumbore ray-triangle intersection (pure world-space geometry, no view-space assumption), and `sketch_orientation_indicator.dart`'s 2D arrow overlay (derived from `SketchPlaneBasis` directly, never re-derives camera right/up). One remaining `up.cross(forward)` in `b1_tap_test_screen.dart` - explicitly unwired reference/prototype code (per its own promotion history into `orthographic_camera.dart`), not reachable from the app, left as-is.

Verified: `flutter analyze` clean; full client suite 874/875 (same pre-existing flake, unrelated).

## 2026-07-22 — Isometric default re-calibrated a second time against a fresh on-device reading

Follow-up to the entry above. Rather than leave `_isometricOrientation` restored to its exact pre-investigation picture (the previous round's fix), the user captured a fresh reading from the now-trusted debug camera-orientation overlay and asked for the default view to match it exactly:

```
X: right=0.71 up=-0.41 out=0.58
Y: right=-0.00 up=0.82 out=0.58
Z: right=-0.71 up=-0.41 out=0.58
```

Read directly as `right=(0.71, -0.00, -0.71)`/`up=(-0.41, 0.82, -0.41)` (each column is one world axis's own right/up component) - verified orthonormal before touching any code (`right·up = 0`, both unit length), and confirmed self-consistent with `FixedPerspectiveCamera`'s own corrected formula (`right.cross(up)` comes out proportional to `(-1,-1,-1)`, matching the captured `out=(0.58,0.58,0.58)` reading) - proof the user captured this from the already-fixed build, not a stale one. Matched to exact vectors `(1, 0, -1)` and `(-1, 2, -1)` (both normalized) - still a true-isometric-magnitude corner (the same `sqrt(2/3)` "tall" component as the previous corner, just landing on a different axis), not a new/different kind of view.

**Fix**: `_isometricOrientation` rebuilt directly from these two vectors (same `back = right.cross(up)`/`Quaternion.fromRotation(...).conjugated()` construction as before, just with new inputs - no re-derivation of the construction itself needed, since that part was already proven correct against the now-fixed renderer in the entry above). `orbit_camera_test.dart`'s "matches the on-screen triad exactly" test updated to this reading's own numbers directly (not re-derived from the old ones) - passes meaningfully, confirming the new default reproduces exactly what the user captured.

Verified: `flutter analyze` clean; full client suite 884/885 (same one pre-existing GPU-sandbox flake, unrelated - a couple of new tests appear to have landed from a separate session running in parallel).

## 2026-07-22 — Per-plane sketch-orientation defaults re-calibrated against fresh on-device readings

Follow-up to the entry above - the user separately captured fresh debug-overlay readings for each fixed plane's own first-offered sketch orientation (post the render fix), rather than trusting the previous round's "same picture as before" restoration of `orientationFacingBasis`'s external contract:

```
ZX (XZ): X: right=1.00 up=0.00 out=0.00 | Y: right=0.00 up=0.00 out=1.00 | Z: right=0.00 up=-1.00 out=0.00
YX (XY): X: right=1.00 up=0.00 out=0.00 | Y: right=0.00 up=1.00 out=0.00 | Z: right=0.00 up=0.00 out=1.00
YZ:      X: right=0.00 up=0.00 out=1.00 | Y: right=0.00 up=1.00 out=0.00 | Z: right=-1.00 up=0.00 out=0.00
```

Each reading was matched to a `(flip, rotationQuarterTurns)` pair by hand-computing `SketchPlaneBasis.withOrientation`'s exact formula (`sketch_geometry_3d.dart`: flip negates `xAxis` first, then each quarter turn maps `xAxis -> yAxis`, `yAxis -> -xAxis`) for all 8 combinations per plane, not guessed - each plane had exactly one matching combination:
- XY: `(false, 0)` (was `(true, 1)`)
- XZ: `(false, 2)` (was `(true, 0)`)
- YZ: `(false, 3)` (was `(false, 0)`)

All three genuinely changed from the previous round, confirming the earlier "no code change needed, `orientationFacingBasis`'s contract is unchanged" answer was correct as far as it went but incomplete: that contract preservation only guarantees the *same* `(flip, rotation)` pair renders the *same* way as before - it says nothing about whether that pair is still the one the user actually wants to see by default, which is a separate, purely aesthetic question only a fresh on-device capture can answer.

**Fix**: `part_screen.dart`'s `_defaultPendingOrientationFor` updated to the three new pairs. `orientation_facing_plane_test.dart`'s "the three per-plane defaults match their own independently-captured on-device targets" group updated to the new `(flip, rotation)` inputs and the exact captured readings.

**Animations checked, not just the resting orientations**: `PartViewport._animateOrientationTo` (the shared slerp-tween machinery `animateToPlane`/`animateToIsometric`/`animateToBasis` all use) is generic quaternion interpolation with its own already-fixed "double-cover" hemisphere correction (forces `to` onto the same hemisphere as `from` before slerping, so the camera always takes the short way around) - this has no dependency on which specific orientation is being animated *to*, only that it's a valid unit quaternion, which both `orientationFacingBasis` and `_isometricOrientation` still produce. No code change needed there; confirmed by inspection rather than assumed, since there's no dedicated test for this GPU/widget-level mechanism to run.

Verified: `flutter analyze` clean; `orientation_facing_plane_test.dart` 30/30 passing meaningfully (matching the hand-derivation, not tautologically). Full suite not re-run here - three pre-existing failures observed at the time (`adoptSketch`/`isCardinalAxisConstraint` in `sketch_controller_test.dart`) traced to a separate session's concurrent, uncommitted work on `sketch_controller.dart`/backend sketch files (confirmed via `git status`/`git diff` - `part_screen.dart`'s own diff contains only this session's change, no overlap), not this fix - left untouched, not this session's to resolve.

## 2026-07-22 — Sketch drag/solve rebuilt on closed-form geometry for Polygon/Slot; general solver hardened as the fallback

Separate session, following up on live on-device reports that dragging a Slot still flipped a tangent to the wrong branch and dragging a raw (undimensioned) Polygon still reported "over constrained," despite three reactive guards shipped earlier the same week (anchor-drift, magnitude blow-up, EqualLength/EqualRadius residual, Arc chord-side - see the two entries above this one in the archive covering that pass). Asked to research the actual cause rather than patch further.

**Research, grounded in the vendored SolveSpace C++ source this app compiles against** (`client/native/slvs/vendor/src/system.cpp`/`mouse.cpp`, not guessed): `System::NewtonSolve` has no "pick the correct root" logic anywhere - which of a constraint system's several valid solutions it lands in is decided entirely by proximity to the seed. The reference implementation's own drag robustness comes from re-solving on every literal mouse-move pixel, i.e. pure continuation. Two real gaps found in this app's own drag pipeline: mid-drag local-solve reflow only ever updated the client's own state, never PATCHed the backend, so `endPointDrag`'s final solve handed the backend a single blind jump from "everything at rest" to "the dropped shape" on every drag; and a rejected local-solve frame didn't pause the dragged Point, so the gap it had to close next frame only grew.

**The actual fix - closed-form geometry, not a better guard.** A regular Polygon and a Slot aren't arbitrary constraint graphs that happen to look regular; they're shapes with an exact formula. Rebuilt from the ground up:

- **Slot got a real backend entity** (`app.sketch.models.Slot`, `Sketch.add_slot`, `/sketch/sketches/{id}/slots` CRUD) mirroring `Polygon`'s own history exactly - `Polygon`'s class docstring already documented having gone through this same "client-only shortcut -> atomic server-side entity" fix once before, for the same reason (reliably recognizing "these pieces form one shape" later). Slot never got it; `_clickSlotTool` composed ~8 raw API calls with nothing tying them together server-side. 16 new backend tests.
- **Closed-form drag path** (`SketchController._closedFormPolygonVertices`/`_closedFormSlotGeometry`): while a Polygon/Slot is *intact* (every Point/Line/Arc it was built from still present, checked live against `points`/`lines`/`arcs` - no stored flag, so a trim or an individual delete is picked up automatically with zero extra bookkeeping), dragging any of its own vertices/corners recomputes the whole shape directly from its own formula - no constraint solver involved at all, so there is no wrong root to find. Purely local and synchronous mid-drag (zero network/FFI calls per frame); `endPointDrag` syncs the final positions to the backend and, only if the shape's one real radius dimension is already confirmed, also updates that Constraint's value (Task #94's existing "drag edits the dimension" semantics, preserved). Undo reuses the identical closed-form path targeting the original position, so it can't reintroduce a wrong root either. The moment a shape is trimmed, dragging its remnants silently falls through to the ordinary general-solver path - confirmed with a dedicated regression test (dragging after a Line delete no longer moves sibling corners synchronously).
- Also fixed the actual "fails over constrained with no dimensions" report directly: `beginPointDrag`'s over/fully-constrained refusal gate used to exempt only a *confirmed* Polygon radius; a raw one's own legitimately-redundant constraint chain could trip it and refuse the grab before a drag ever reached the (already-correct) drag logic at all. Now exempted for any intact Polygon/Slot, confirmed or not.
- **General path hardened too** (still the necessary fallback for hand-built constraint combinations and post-trim remnants): every Point a mid-drag local solve reflows is now tracked (`_dragReflowedPointIds`) and synced to the backend right before `endPointDrag`'s/`endLineDrag`'s final solve, closing the blind-jump gap above for the general case as well.

Deliberately not done this pass (documented in `roadmap.md` as follow-ups, not silently dropped): bisection/sub-step retry and a reflect-based self-heal for the general path's own branch-flip case (the backend already has the right template for this, `solver.py`'s `_fix_circle_cardinal_point_signs`, confirmed not yet ported to the client's local solver); ghost-preview drag (decoupling live rendering from the authoritative solve) - the closed-form rebuild already removes the "wrong root flashing mid-drag" risk for the two shapes actually reported broken, so this is now optional polish for the general path rather than a fix for a live bug. Slot's own delete-cascade-with-undo integration (multi-select delete cleanly removing a whole Slot rather than leaving it a dangling entity if only its Lines/Arcs are selected) also deferred, mirroring the same real gap Polygon itself had for a while after its own entity landed.

Verified: `flutter analyze` clean; full client suite 876/877 (same pre-existing unrelated flake); full backend suite 884/912 (28 failures, all confirmed pre-existing and unrelated by reproducing them identically against the unmodified code). Not yet confirmed on-device - the debug APK was rebuilt and ready to install, but the phone's wireless-ADB port had gone stale by the time of the reinstall attempt; also flagged that the backend server the device connects to needs the new `/slots` endpoints deployed/restarted before Slot creation will work on-device at all, separately from the client rebuild.

## 2026-07-22 — Same-day follow-up: parallel-line dimensioning fixed, Polygon "across flats" over-constrained root-caused and fixed, hover-only construction points added

Confirmed on-device (Slot/Polygon resizing "feel" preserved, as asked) before this round started. Four items, researched via two focused code passes before any changes:

**Parallel-line dimension picking a Slot's two sides offered a mismatched midpoint-to-endpoint distance instead of the correct line-to-line one.** Root cause: `_resolveSelectableAt` resolves each of the two taps independently - one landing near a Line's middle materializes its midpoint into a real Point, one landing nearer a Line's own end (here, shared with the adjacent Arc) resolves straight to that endpoint Point - both come back as `SelectionKind.point`, so `_rebuildDimensionGhosts` fell through to an ordinary point-to-point ghost instead of the parallel-Line one. Fixed with `_linesForDimensionPoint`/`_parallelLinePairForPoints` (`sketch_controller.dart`): when both picks are Points, checks whether each is "on" some Line (its own endpoint, or exactly at its current midpoint) and re-routes to the existing `_buildLinePairGhosts` path if there's a pair of different, parallel Lines involved - reuses `_linesAreParallel`, already proven for the plain two-Line case.

**Polygon "across flats" reported over-constrained even with the exactly-correct value** - confirmed directly against the real solver: a Polygon's own baked-in EqualLength/EqualRadius/AngleConstraint chain is already redundant by py-slvs's own detection (only reads as converged via the existing narrow `result_code in (4, 5)` override). Stacking a second, genuinely-implied `LineDistanceConstraint` on top pushes past what that override catches - `result_code=1`, **identical** to what a deliberately wrong value produces, confirming `result_code` alone cannot tell "doubly-redundant but consistent" from a real conflict here. Fixed with a residual-based fallback (`_residual_verified_convergence` in `solver.py`, ported to `local_sketch_solver.dart` as `_residualVerifiedConvergence`) alongside the existing narrow override: when a solve doesn't cleanly converge, recomputes every Distance/EqualLength/EqualRadius/Angle/Tangent/LineDistanceConstraint's own residual directly from the attempted solution - if every one is satisfied within tolerance, it's a real (if redundant) solution regardless of what `result_code` says. Closed allowlist, same conservative shape as the existing narrow override (falls through to ordinary failure reporting if any Constraint present isn't one of the checkable types). As a side effect, also fixed a second pre-existing bug of the identical class: a confirmed `DistanceConstraint` between two already-pinned external-reference Points matching their real distance used to report not-converged too (`test_a_dimension_between_the_two_materialized_edge_points_works_unmodified`, previously failing, now passes unmodified).

**New hover/select-only-visible construction points for an intact Slot**, confirmed with the user: the centreline's own midpoint (already reachable via the existing generic Line-midpoint mechanism - construction Lines were never excluded from it) and each end-cap Arc's own apex ("the midpoint of the arc... also the end points of the construction line" extended - a new point, `center - radius` along the extended centreline direction, computed by `_slotArcApex`). Both wired through one shared `_nearestConstructionSnapAt`/materialize entry point so `_resolveSelectableAt` (dimension/select-mode picking) gets both for free; falls through to the general path automatically once a Slot is trimmed (live intactness check, no stored flag).

**Circle/Polygon centre points changed from always-rendered to hover/select-only-visible.** Previously drawn unconditionally, every frame, with no gating at all. Now: hovering any part of the shape (its own curve, or - for a Polygon - any of its own Lines) reveals that shape's centre Point immediately (`SketchController.revealedShapeCenterPointId`, updated from all three cursor-movement entry points so both the 2D canvas and 3D-embedded view get it identically), staying visible for 3 seconds after the cursor leaves (reset-on-re-hover `Timer`, the same cancel/reschedule idiom `part_screen.dart`'s existing debounce Timers already use) before hiding again - plus visible whenever actually selected. `sketch_canvas.dart`'s per-point draw loop and `sketch_screen.dart`'s `_pointDtosFrom` (which builds the 3D view's own point list) both gate on the same rule.

Verified: `flutter analyze` clean; full client suite 885/886 (same pre-existing unrelated flake), including new `fakeAsync`-driven tests for the delayed-hide timer (added `fake_async` as a direct dev dependency - it was already present transitively); full backend suite 888/915 (27 failures, one fewer than the prior baseline - the residual-fallback side-effect fix above - all confirmed pre-existing/unrelated by reproducing against the unmodified code). Rebuilt the debug APK; not yet reinstalled - the phone's wireless-ADB port had gone stale again by the time of the reinstall attempt (second time this has happened this session - flagging in case the connection itself is worth investigating, separately from the app).

---

## 2026-07-23 — Placing a Polygon near the origin collapsed it to a single invisible point

User report: "when I place a polygon it looks like it collapses to a single invisible point." No details on where in the sketch - reproduced directly against the real backend solver (`py-slvs`, not the client's fake test backend) rather than guessed.

**Root cause, isolated by direct experiment against `solve_sketch`:** a freshly-placed regular Polygon's rigidity rests entirely on its baked-in `EqualRadiusConstraint`/`EqualLengthConstraint`/`AngleConstraint` chain (`Sketch.add_polygon`) - its one real circumradius `DistanceConstraint` starts `provisional=True` (solver-skipped) until the user confirms an actual dimension, by design, so a fresh Polygon still reports under-constrained. That chain is scale-invariant (equal-ness holds at *any* uniform scale, including zero), so the whole shape has exactly one genuinely free DOF: uniform scale about its own centre. Confirmed this is stable on its own - a freshly-placed Polygon solved in isolation reproduces its exact placed geometry, no drift, run 30x in a row. But feeding the *same* solve a second, unrelated task - moving the centre Point a small-but-nonzero distance to satisfy a fresh `CoincidentConstraint` - reliably knocked that free-scale DOF into the degenerate all-vertices-at-centre solution instead of preserving the placed size: reproduced with every vertex landing within `1e-7` of the pin point, exactly the reported symptom. An exact-zero-distance pin left it untouched (radius exact); anything from ~0.3 sketch units up collapsed it outright.

That "moved a small-but-nonzero distance to satisfy a fresh CoincidentConstraint" trigger is new as of the previous entry's own origin-decoupling fix: `_pointIdAt`'s `_createPointCoincidentWithExisting` (client) creates a brand-new Point *near* the origin - within `snapRadius`, at the raw tapped position, not necessarily exactly on it - then ties it to the origin with a `CoincidentConstraint`, rather than reusing the origin's own id directly (the older behaviour, which needed no such reconciling solve at all). Placing a Polygon's centre anywhere within snap radius of the sketch origin - an extremely common first action - hits this exactly.

**Fix, at the actual source of the nudge rather than special-casing Polygon**: `_createPointCoincidentWithExisting` now creates the new Point exactly at the target's own current `(x, y)` instead of the raw tapped position - the fresh `CoincidentConstraint` starts already satisfied (zero residual), so the reconciling solve has nothing left to do, removing the trigger for every entity, not just Polygon. `sketch_controller_test.dart`'s existing "tapping within the snap radius of the origin creates a new, distinct Point" test extended to assert the new Point lands exactly on `(0, 0)`, not the raw `(0.1, 0.1)` tap.

Verified against the real backend solver directly (`app.sketch.solver.solve_sketch`, stubbing only the OCCT-dependent text/profile imports `app.main` pulls in transitively - no `pythonocc-core`/`py-slvs` wheel available in this sandbox either, matching this doc's own recurring environment caveat): the exact reproduction above, re-run with the Point created at the target's coordinates instead of the raw tap, no longer collapses (radius preserved exactly). No Flutter SDK in this sandbox to run `flutter analyze`/`flutter test`; reviewed the diff by hand instead - the fake test backend echoes `createPoint`'s given `x`/`y` directly, so the new test assertion exercises the real client code path even without the real solver behind it.

**Same-day follow-up: `part_viewport_test.dart`'s own "Fix 4... over empty space" test made to skip, not fail, when this CI sandbox's GPU/Impeller setup doesn't come up.** PR #98's CI hit this test's already-documented pre-existing flake three runs in a row - the test already knew and commented on exactly why (`PartViewport` renders a plain error `Text` with no `Listener` at all when `Scene.initializeStaticResources()` fails, which it reliably does with no real Impeller backend in this sandbox), and already waited up to 300 pumps for the real `Listener` to confirm the interactive tree was actually up before tapping - but the wait helper (`_pumpUntil`) returned `void`, so a wait that gave up empty-handed was indistinguishable from one that succeeded, and the test barrelled into `tester.tap`/`expect(cleared, isTrue)` regardless, reading as a hard failure identical to a genuine tap-dispatch regression. Root cause confirmed directly from this run's own job logs: `[PartViewport][RenderDebug] GPU capability query failed: Exception: Flutter GPU requires the Impeller rendering backend, but Impeller is not enabled.`

**Fix**: `_pumpUntil` now returns whether its condition actually became true within the pump budget; the "Fix 4... over empty space" test checks that and calls `markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox')` instead of proceeding, the same capability-missing-skips-rather-than-fails shape `sketch_controller_test.dart` already uses five times for the host `didsa_slvs_ffi` library not being built. No coverage lost on a real device/CI with a working GPU backend - the test still runs and asserts fully there; this only stops it from crying wolf in a sandbox that structurally can't run it. The other four `_pumpUntil` call sites in this file are unaffected (still bare `await`, discarding the now-`bool` return, which is valid).

No Flutter SDK in this sandbox to run `flutter analyze`/`flutter test`; reviewed the diff by hand - `markTestSkipped` is already used from the identical `package:flutter_test/flutter_test.dart` import elsewhere in the suite, and the other four `_pumpUntil` callers don't capture its return value so the signature change (`Future<void>` → `Future<bool>`) doesn't affect them.

## 2026-07-23 — Pattern/Mirror scoping doc, then Phase 1 (Mirror about a fixed plane or Body face) implemented

New session. Asked first to investigate adding Pattern/Mirror to DIDSA-CAD (mirror about plane/face, rectangular/circular pattern, skip instances, direction from straight/curved edges and axis lines, patterning bodies/features, sketch-level patterning, merge options), then to implement Phase 1 of whatever plan came out of it.

**Investigation**: `docs/pattern-mirror-scope.md` - confirmed via exhaustive grep that Pattern/Mirror is genuinely greenfield (no prior code, schema, or even a planning stub beyond one illustrative word in a feature-tree diagram), designed the backend/client approach per required item against the actual current Feature-checklist architecture (reusing `SubShapeRef`/`PlaneRef`/`resolve_circular_edge_arc`/`RevolveFeature._resolve_axis` rather than inventing new reference types), surveyed adjacent CAD-tool features with an explicit in/out-of-scope call for each, and laid out an 8-phase rollout (Mirror → Rectangular pattern → Skip instances → Circular pattern → Merge options → Multi-body/feature seeds → Sketch-level pattern/mirror → explicitly-deferred items).

**Phase 1 implementation: Mirror about a fixed plane or Body face, single-Body seed, always-separate output.**

Backend, following the established six-part Feature checklist exactly (dataclass → graph dependency edges → geometry module → `compute_part_bodies` branch → schemas → router endpoints):
- `MirrorFeature` (`app/document/models.py`) - `source_body_ids: list[str]` (exactly one entry in Phase 1), `mirror_plane: PlaneRef` (reused verbatim - the single biggest reuse win in the whole design, since it already unifies "a fixed plane," "a Body face," and "an existing Plane feature" behind one field with zero new resolution code), `source_feature_ids` reserved unused for Phase 6.
- `app.document.create_plane._resolve_plane_ref` promoted to public `resolve_plane_ref` - Mirror is a second real consumer outside that module, same "promote on second consumer" convention `sketch_feature_id_for_sketch` already established.
- New `app/document/mirror.py`: `resolve_mirror_from_bodies`/`resolve_mirror` mirror Chamfer's `_from_bodies`/fresh-wrapper split exactly, `gp_Trsf.SetMirror(gp_Ax2(...))` (the plane-mirror overload, not `gp_Ax1`'s line-mirror one) via `BRepBuilderAPI_Transform`. Self-excludes its own id in the fresh wrapper even though Phase 1 alone doesn't strictly need it yet (Mirror never modifies its source in place) - forward-looking for Phase 5's merge option, which will.
- `compute_part_bodies` (`extrude.py`) gets a `MirrorFeature` branch registering the mirrored shape via `_register_solids` under the Feature's own id - Boss-with-no-target semantics, not `_apply_boss_or_cut` (Mirror has no `target_body_ids`/merge concept until Phase 5).
- `graph.py`: `_mirror_dependencies` (depends on `source_body_ids`' owning Extrude/Revolve/Sweep/Import Features, plus whatever `mirror_plane` depends on via the existing `_plane_ref_dependency`) - cascade delete works for free once these edges are correct.
- `schemas.py`/`router.py`: `MirrorFeatureCreate`/`Update`/`Response`, `_validate_mirror_source_body_ids` (exactly one entry, must resolve to a real body-producing Feature - deliberately not yet accepting a `MirrorFeature` itself as a producer, since chaining is Phase 6), create/update endpoints mirroring Chamfer's validate→construct→eager-resolve→persist shape exactly.
- `native_format.py`: `MirrorFeature` added to the Save/Load round-trip (`_feature_to_dict`/`_feature_from_dict`) - missed on a first pass, caught by checking every place `ChamferFeature` appears, not just the schema/router files a `grep MirrorFeature` alone would have found.

Client, following the Fillet/Revolve panel-and-selection conventions:
- **Real constraint found and designed around**: `hitTestBodies` (`selection_hit_test.dart`) treats `filter.body`/`filter.face` as mutually exclusive at the whole-hit-test level - turning `body` on promotes *every* face intersection to a `body`-kind pick, never a `face`-kind one. This rules out a Revolve-style single filter letting the user pick a source Body and a mirror-plane face at once (Revolve's axis pick is a `sketchLine`, hit-tested via a completely separate code path from its own `body` target picks, so those two *can* coexist). Mirror instead captures the source Body once, into its own field, at the moment the "Mirror" button is tapped (from a pre-existing single-Body selection), then switches `_selectedEntities` over to a face/referencePlane/createPlane-only filter for the rest of the panel's session - a genuinely two-stage flow, not a copy of either existing pattern.
- `selection_actions.dart`: `contextActionsFor`'s old blanket "any Body in the selection offers nothing" guard narrowed to "a Body mixed with anything else offers nothing" - a *lone* Body (exactly one, nothing else) now offers Mirror, the first real operation a Body-only selection has ever enabled. Updated the one existing test that specifically asserted a lone-Body selection was empty (`selection_actions_test.dart`) to reflect the new intended behaviour, and added coverage for the new branch and its two still-suppressed cases (two Bodies together; a Body mixed with a sub-shape).
- New `mirror_panel.dart` (`MirrorPanel`, cloned from `FilletPanel`'s shell) - no numeric field at all in Phase 1 (the only parameter is the plane pick itself), Confirm gated on `hasPlanePicked` instead.
- `part_screen.dart`: new Mirror state-field section (mirrors Revolve's field shapes, Fillet's trigger shape), `_setMirrorPlane` (mirrors `_setRevolveAxis`'s replace-not-accumulate single-pick semantics, generalized to three plane-like kinds), `_onMirrorTapped`/`_openMirrorPanel`/`_openMirrorPanelForEdit`/`_ensureMirrorFeatureExists`/`_scheduleMirrorPreview`/`_confirmMirror`/`_cancelMirror`, plus every `!_xActive`-style visibility guard list and the `_onFeatureTap` B4 edit dispatcher extended with `_mirrorActive`/`'mirror'`. Confirmed via `docs/live-preview-pattern.md`'s own decision tree that Mirror takes the simple `isPreviewMesh` path (no dual-mesh preview-overlay machinery) - it never lets the user re-pick sub-shapes of the very Body it produces, only of an upstream, already-final seed Body.
- `document_api_client.dart`: `FeatureDto.sourceBodyIds`/`mirrorPlane`, `createMirrorFeature`/`updateMirrorFeature` mirroring `createChamferFeature`/`updateChamferFeature` exactly.
- `feature_tree_panel.dart`: `'mirror'` added to both the display-name and tree-icon switches (new `assets/icons/feature/feature_mirror.svg` - a dashed mirror line with a shape and its reflection on each side, matching the existing minimal-line-icon style).

**Verification, honestly split by what this sandbox can actually run** (no `pythonocc-core`/`py-slvs`/conda in this environment - confirmed via `docker build` also failing here, no daemon available to fall back on either - and no Flutter/Dart SDK at all):
- Backend graph logic (`app.document.graph`) has zero OCCT dependency by design - `pip install fastapi httpx` (both pure-Python, no OCCT pulled in transitively) was enough to actually *run* `test_stage_i_mirror_graph.py` (7 new tests: dependency edges for a plain source, a split `#N` body id, a Body-face mirror plane, an existing-Plane mirror plane, and three cascade-delete shapes) for real, plus the full existing pure-Python suite (83 tests, all still passing - confirmed my changes didn't regress `graph.py`'s existing behaviour). `native_format.py` is also OCCT-free by its own design (confirmed by grep and a real import) - extended `test_stage_native_format.py`'s existing "round trips every feature type" test with a `feat-mirror` entry and ran it for real too (9/10 passing; the 10th, `test_export_import_native_over_http`, fails on the same pre-existing `No module named 'OCC'` every OCCT-touching test in this sandbox hits, unrelated to this change).
- Everything touching `OCC.Core.*` directly (`mirror.py`, the `extrude.py`/`router.py` changes, the full HTTP-level `test_stage_i_mirror.py`) - and the entire client side, since there is no Dart/Flutter SDK here at all - is `ast.parse`-verified (Python side) and hand-reviewed against the exact precedent each piece claims to mirror (Chamfer/Revolve/Fillet's own resolvers, panel shells, and state-field shapes, read directly rather than assumed), matching this doc's recurring caveat for every prior OCCT-touching or Flutter-only prompt. Confirmed the 45 pre-existing sandbox-only collection failures (`No module named 'OCC'`/`py_slvs`) are unchanged in cause by this session's edits, not a new regression. Needs real CI (backend) and a real on-device/desktop build (client) to confirm beyond that.

## 2026-07-24 — Real toolchains installed to verify Phase 1 for real, then a guided "New > Mirror" flow (multi-body pulled forward from Phase 6) built on top

Same overall Pattern/Mirror effort, two follow-up passes in one session. First asked to "install whatever you need to carry out tests and monitor CI" - closing out the previous entry's `ast.parse`-only caveat with real toolchains instead of another review pass. Then asked to add a guided "New > Mirror" entry point with a specific two-step UX (pick Body/Bodies → confirm → pick a mirror plane, reference planes temporarily shown) that explicitly required multi-body support.

**Real local toolchains, bypassing this sandbox's network restrictions**: `docker build`/`docker run` unavailable (no dockerd, no root to start one). `micro.mamba.pm` (the documented micromamba installer) is proxy-blocked (403) in this sandbox, but its GitHub release asset isn't - installed micromamba from `github.com/mamba-org/micromamba-releases` instead, built a `didsacad` conda-forge env with real `pythonocc-core`, and ran the full backend `pytest` suite against genuine OCCT for the first time this Pattern/Mirror effort (988 tests, all passing, including every `test_stage_i_mirror*.py` file). Flutter's own `flutter-action`/subosito tooling wasn't available either - cloned the Flutter SDK's `master` branch directly from `storage.googleapis.com` (reachable, unlike `micro.mamba.pm`) and ran `flutter analyze`/`flutter test` for real against the full client suite. Direct `curl` to `api.github.com` for CI polling returned unusably empty status fields in this sandbox (likely needs an auth path plain `curl` here doesn't have); switched to the `mcp__github__actions_get`/`actions_list` MCP tools instead, which do carry real auth, and confirmed both `Backend - build and test` and `Client - build and test` green on the pushed branch.

**Guided "New > Mirror" flow + multi-body seeding pulled forward from Phase 6.** On-device feedback: "select body/bodies (multiple bodies should be supported)" - explicit, not a nice-to-have - so this widened `MirrorFeature.source_body_ids` from Phase 1's original exactly-one to 1+ rather than deferring it to Phase 6 as originally scoped (see `docs/pattern-mirror-scope.md`'s own updated Phase 1/6 entries for the full reasoning).

Backend:
- `mirror.py` rewritten: `resolve_mirror_from_bodies`/`resolve_mirror` now return `list[TopoDS_Shape]` (one per `source_body_ids` entry, all reflected across the same resolved plane) instead of a single shape.
- `extrude.py`'s `compute_part_bodies` `MirrorFeature` branch registers either one Body (`feature.id` directly, unchanged single-source shape) or N Bodies (`f"{feature.id}#{i}"` per source, mirroring `_register_solids`'s own single-vs-multiple suffix convention, just applied across sources instead of within one shape's own solid-splitting).
- `router.py`'s `_validate_mirror_source_body_ids` now requires "at least one" instead of "exactly one"; `graph.py`'s `_mirror_dependencies` needed zero changes (it already looped over every `source_body_ids` entry via a set comprehension - already generic).
- New test `test_mirroring_two_source_bodies_produces_two_independent_mirrored_bodies` (two Bodies at different x-offsets mirrored about YZ in one call → 4 total Bodies, each pair's x-range independently verified); the old `test_two_source_body_ids_is_rejected_in_phase_1` removed (no longer true).

Client - the two-step wizard itself, driven by the same `hitTestBodies` constraint the previous entry already found (`filter.body`/`filter.face` mutually exclusive at the whole-hit-test level, so Body-picking and plane-picking can never share one filter):
- `feature_picker_sheet.dart`: `FeaturePickerAction.mirror` + a "Mirror" tile in the "Add" FAB's Feature sheet (reusing the already-present `feature_mirror.svg`).
- `part_screen.dart`: `_mirrorSourceBodyId` (singular) replaced with `_mirrorSourceBodyIds` (`List<String>?`); a new `_MirrorStep { pickingBodies, pickingPlane }` enum replaces the plain `bool _mirrorActive` (kept as a derived getter, `_mirrorStep != null`, so every existing guard site kept working unchanged). New `_mirrorBodyPickerSelectionFilter` (`body: true` only). `_startMirrorPicker()` (the guided entry - opens `pickingBodies` with an empty selection) and `_confirmMirrorBodySelection()` (captures every selected Body, swaps the filter to `_mirrorSelectionFilter`, advances to `pickingPlane`, forces reference planes temporarily visible) are new; Body taps during `pickingBodies` need no special-casing at all - they fall straight into the existing generic accumulate-toggle since the Body-only filter already guarantees nothing else can be hit-tested. `_onMirrorTapped` (the ambient `SelectionContextPanel` entry) now collects every selected Body and skips `pickingBodies` entirely, jumping straight to `pickingPlane` with them pre-captured. Two new top banners mirror Fillet/Chamfer's guided-entry banner convention exactly ("Select Body to Mirror" / N selected with a confirm-FAB hint, Cancel-only; "Select Mirror Plane or Face", Cancel-only, disappearing the instant a plane pick creates the preview Feature) plus a new checkmark FAB (mirroring the profile/path pickers' own) confirming the body-pick step. `referencePlanesHidden` is overridden to `false` specifically at the `PartViewport` render call site (not `PartToolbar`'s, so the toolbar's own toggle keeps reflecting the user's real preference) for the whole `pickingPlane` step.
- `selection_actions.dart`: `contextActionsFor`'s Mirror branch widened from "exactly one Body, nothing else" to "1+ Bodies, nothing else" to match; `selection_actions_test.dart`'s "two Bodies together still suppress everything" test flipped to assert Mirror is now offered.

Verified for real, using the toolchains installed earlier this session: full backend `pytest` suite 988/988 (including the new multi-body test); `flutter analyze` clean on the whole client project; full client `flutter test` suite 937/937 (7 skipped, all pre-existing GPU/Impeller-unavailable skips unrelated to this change). Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-24 — Same-day follow-up: Phase 2 (Rectangular pattern) implemented, with a guided "New > Pattern" flow matching Mirror's own

Asked to proceed with Phase 2 of `docs/pattern-mirror-scope.md` and to give it a guided UX path similar to the one just added for Mirror.

**Real design decision the scope doc's own Phase 2 pseudocode had left ambiguous**: does a pattern of `count_1` instances mean `count_1` *new* Bodies (on top of the untouched seed), or `count_1` *total* Bodies including the seed at its own zero-offset "instance 0"? Resolved in favor of the latter - mainstream CAD tools (SolidWorks, Fusion) always count the original feature as instance 1, so `count_1 * count_2` is the *total* instance count; the flattened linear index `i*count_2+j` reserves index 0 for the seed Body itself, which is never re-created (it already exists, registered under its own id by whichever earlier Feature produced it) - the Feature only ever registers the other `count_1*count_2-1` instances as brand-new Bodies. Verified directly against the real backend: a 3-instance pattern along a fixed axis produces exactly 3 total Bodies (1 seed + 2 new), not 4.

**Scope decisions, made explicit rather than silently assumed:**
- Unlike Mirror's own Phase 1 revision (multi-body seeding pulled forward from Phase 6 on explicit on-device feedback), Pattern's `source_body_ids` stays constrained to exactly one entry in Phase 2 - Pattern never got that same feedback, and multi-body-per-source instance-naming is a real added-complexity problem (source × instance grid, not just a flat instance list) worth deferring to Phase 6 on its own terms rather than copying Mirror's revision reflexively.
- Client v1 exposes only two of the three backend-supported direction sources (a straight Body edge, tapped live in the viewport; a fixed world X/Y/Z axis, via panel buttons) - a Sketch Line direction is fully implemented and tested server-side (`PatternDirectionRef.sketch_line_ref`, mirroring `RevolveFeature.axis_ref`'s own resolution) but not yet reachable from the client panel, since (unlike a Body edge, always present in the viewport) a Sketch Line usable as a direction isn't guaranteed to already be visible - Revolve solves this for its own axis pick with a dedicated Sketch-picker flow this panel doesn't yet reuse. Tracked as a fast-follow, not silently dropped.

**Backend**, following the six-part Feature checklist exactly, mirroring `MirrorFeature`'s own Phase 1 shape throughout:
- `PatternFeature`/`PatternDirectionRef`/`FixedAxis` (`app/document/models.py`) - `direction_1`/`count_1`/`spacing_1`/`reverse_1` required, `direction_2`/`count_2`/`spacing_2`/`reverse_2` optional (only ever read by the resolver when `count_2 > 1`, so a stale/unset `direction_2` is harmlessly inert rather than needing a separate "omitted vs. explicitly cleared" PATCH convention - a real simplification found while designing `PatternFeatureUpdate`).
- New `app/document/pattern.py`: `resolve_pattern_from_bodies`/`resolve_pattern` mirror `mirror.py`'s own `_from_bodies`/fresh-wrapper split; `_direction_vector` handles all three `PatternDirectionRef` cases - straight-edge check reuses `create_plane.py`'s exact `GeomAbs_Line` idiom, Sketch-Line resolution mirrors `revolve.py`'s own `_resolve_axis` (minus the axis origin, since a translation direction needs no pivot), fixed-axis is a plain lookup table.
- `compute_part_bodies` (`extrude.py`) gets a `PatternFeature` branch registering every non-zero instance from the flattened grid, `feature.id` alone for exactly one new instance or `f"{feature.id}#{index}"` per instance otherwise - deliberately keyed by the pattern's own linear index (not reindexed 0..N-1), so a future Phase 3 skip-instance picker can address the exact same indices without renumbering anything.
- `graph.py`: `_pattern_dependencies`/`_pattern_direction_dependency` mirror `_mirror_dependencies`/`_plane_ref_dependency`'s own three-way shape.
- `schemas.py`/`router.py`: `PatternFeatureCreate`/`Update`/`Response`, `_validate_pattern_source_body_ids` (exactly one entry), `_validate_pattern_direction_ref` (exactly one of `edge_ref`/`sketch_line_ref`/`fixed_axis`), `_validate_pattern_counts_and_direction_2` (`count_1`/`count_2 >= 1`, their product `>= 2` - otherwise the Feature would be a pure no-op beyond the untouched seed - and `direction_2` required exactly when `count_2 > 1`), create/update endpoints mirroring `create_mirror_feature`/`update_mirror_feature` exactly.
- `native_format.py`: `PatternFeature`/`PatternDirectionRef` added to the Save/Load round-trip.
- New `backend/tests/test_stage_j_pattern.py` (26 tests): fixed-axis/edge/Sketch-Line direction success cases (verified as pure rigid translations via a bounding-box-extent-and-shift check, axis-agnostic since a box's own edges aren't predictably aligned to one world axis), reverse, two-direction grids, the single-vs-`#N`-suffix naming convention, every validation rejection (zero/one source, bad direction-ref shape, non-linear edge via a real cylinder body, invalid Sketch-Line refs, the no-op-count and missing-`direction_2` cases), PATCH/rollback editing, and cascade delete (via the owning Extrude and via a Sketch-Line direction's own owning Sketch).

**Client**, following Mirror's own guided two-step wizard shape, simplified for Pattern's exactly-one-Body scope:
- New `pattern_panel.dart` (`PatternPanel`) - two near-identical "Direction" sections (Direction 1 required, Direction 2 optional), each with X/Y/Z fixed-axis buttons, count/spacing fields, and an `Icons.flip` reverse toggle. Because Direction 1 and Direction 2 can each independently come from a viewport edge tap, a `SegmentedButton` "active direction slot" toggle (shown only once a second direction is enabled) disambiguates which one the next edge tap fills - a genuinely new interaction-design problem Mirror's own single-plane-pick shape never had to solve.
- `part_screen.dart`: `_PatternStep { pickingBody, configuring }` mirrors `_MirrorStep` structurally, but `pickingBody` immediately advances to `configuring` the moment a single Body is tapped (no separate confirm step - Phase 2 only ever has one valid choice, unlike Mirror's own multi-select `pickingBodies`). New `_patternBodyPickerSelectionFilter`/`_patternDirectionSelectionFilter`, `_startPatternPicker`/`_confirmPatternBodySelection`/`_onPatternTapped`/`_openPatternPanel`/`_openPatternPanelForEdit`, direction-slot bookkeeping (`_setPatternDirectionFromEdge`/`_setPatternFixedAxis`/`_setPatternActiveDirectionSlot`/`_setPatternHasSecondDirection`), `_ensurePatternFeatureExists`/`_schedulePatternPreview`/`_confirmPattern`/`_cancelPattern`, two new top banners ("Select Body to Pattern" / "Select an Edge or a Fixed Axis for Direction", both Cancel-only - no confirm-FAB the way Mirror's own body-picking step needs one). `_clearSelectedEntities` (an empty-space tap) now preserves Pattern's own picked-direction highlight entities instead of wiping `_selectedEntities` down to nothing - the one real behavioral wrinkle from Pattern needing two independent viewport picks where every other flow here needs at most one.
- `document_api_client.dart`: `PatternDirectionRefDto`, `FeatureDto`'s `direction1`/`count1`/`spacing1`/`reverse1`/`direction2`/`count2`/`spacing2`/`reverse2`, `createPatternFeature`/`updatePatternFeature`.
- `selection_actions.dart`: `contextActionsFor`'s Body-selection branch now also offers "Pattern" for exactly one Body (disabled with a reason for 2+, Prompt D's own "explain, don't silently omit" convention).
- `feature_picker_sheet.dart`/`feature_tree_panel.dart`: `FeaturePickerAction.pattern` + a "Pattern" tile (new `assets/icons/feature/feature_pattern.svg` - a solid seed square followed by two dashed instance squares, matching the existing minimal-line-icon style) and tree-row glyph/label.
- New `pattern_panel_test.dart` (18 tests): Confirm-enablement (no direction, count-of-1-with-no-second-direction, second-direction-enabled-but-unpicked), X/Y/Z button taps, the reverse toggle, the second-direction toggle showing/hiding its own section and the active-slot chip, title/Cancel.

Verified for real, using the same local toolchains from the same-day Mirror revision above: full backend `pytest` suite 1014/1014 (988 prior + 26 new); `flutter analyze` clean on the whole client project; full client `flutter test` suite 955/955 (937 prior + 18 new). Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-28 — Phase 4 (Circular pattern) implemented, folded into the same "New > Pattern" flow as a mode toggle

Asked to implement Phase 4 of `docs/pattern-mirror-scope.md`: add Circular pattern, exposed as a Rectangular/Circular mode choice inside the existing guided "Pattern" UX path (not a separate feature), with Pattern features (both modes) editable from the Build Tree.

**Backend**, following the six-part Feature checklist exactly, mirroring Phase 2's own shape throughout:
- `PatternType` enum (`RECTANGULAR`/`CIRCULAR`, defaulting to `RECTANGULAR` for round-trip compatibility with Phase-2-era saves) added to `PatternFeature`, alongside `PatternAxisRef` (`edge_ref`/`face_ref`/`sketch_line_ref`, "exactly one of three" - generalizes `PatternDirectionRef`'s own convention to faces too) and `axis`/`count_angular`/`angle_total`/`reverse_angular`. `direction_1`/`count_1`/`spacing_1` widened from required to optional at the dataclass level - which group is actually required is validated by the router (`_validate_pattern_payload`, dispatching on `pattern_type`), not the dataclass, mirroring `CreatePlaneFeature`'s own "one dataclass, many construction methods" convention that `docs/didsa-longterm-vision-and-model.md` §6 explicitly calls for here.
- New `_axis_from_ref` in `pattern.py`: a circular Body edge via `BRepAdaptor_Curve`/`GeomAbs_Circle` (new `non_circular_edge` error); a cylindrical Body face via `BRepAdaptor_Surface`/`GeomAbs_Cylinder` (new `non_cylindrical_face` error - the one genuinely new OCCT path this phase needed); a Sketch Line mirrors `RevolveFeature._resolve_axis`'s own machinery, returning a full `gp_Ax1` (origin + direction) instead of a bare direction. `_circular_instances` uses `gp_Trsf.SetRotation(axis, radians(angle_total/count_angular) * i)` in place of Phase 2's `SetTranslation`, sharing the exact same index-0-is-the-untouched-seed convention (`count_angular` is the *total* instance count including the seed, matching `count_1 * count_2`'s own convention).
- **Real design decision**: verifying rotation geometry without assuming OCCT's CW/CCW convention for a given `gp_Ax1` direction. Resolved with a direction-agnostic, set-based test - a 4-way, 360° circular pattern of a small offset box around a *different* body's own circular edge asserts the SET of 4 resulting bounding-box quadrant positions matches expectations exactly, rather than asserting a specific instance index lands at a specific position (a CW vs. CCW sweep only permutes which index lands in which quadrant, never which quadrants are used).
- Confirmed the axis reference is allowed to point at a body *different* from the one being patterned - neither `_validate_pattern_axis_ref` nor `_axis_from_ref`/`_pattern_axis_dependency` restrict this, verified directly with a cascade-delete test (deleting the axis body's owning Extrude, not the patterned body's own, correctly cascades the Pattern feature away too).
- `graph.py`/`schemas.py`/`router.py`/`native_format.py` follow the established plumbing pattern: `_pattern_axis_dependency` mirrors `_pattern_direction_dependency`; `_validate_pattern_rectangular_payload`/`_validate_pattern_circular_payload` (dispatched by the new `_validate_pattern_payload`) replace the old single validator - Circular requires `count_angular >= 2` (a single-instance pattern is a no-op, same reasoning as Rectangular's product-`>= 2` check) and `0 < angle_total <= 360`; `pattern_type` is immutable via PATCH (switching modes is delete+recreate, mirroring `CreatePlaneFeatureUpdate.plane_type`'s own convention) - `update_pattern_feature` always validates against the Feature's own existing `pattern_type`, never a payload-supplied one (there is no such field on `PatternFeatureUpdate`).
- New `backend/tests/test_stage_k_pattern_circular.py` (26 tests): circular-edge/cylindrical-face/sketch-line axis success cases, the quadrant-position-set geometric test, reverse-angular, partial `angle_total`, every validation rejection (no axis, `count_angular` of 0/1, `angle_total` of 0/361, malformed axis refs, a straight edge/planar face used as an axis, rectangular's own `direction_1` requirement still enforced), PATCH/rollback editing, and cascade delete via both the axis body's owning Extrude and a sketch-line axis's owning Sketch.

**Client**, extending Phase 2's own guided flow rather than adding a new one:
- `pattern_panel.dart`: new `PatternMode` enum (`apiValue`/`fromApiValue`, mirroring `RevolveMode`'s own str-enum convention) and a Rectangular/Circular `SegmentedButton`, shown only when `canChangeMode` is true - false while editing an existing Feature, since `pattern_type` is immutable server-side (mirrors `CreatePlaneFeatureUpdate.plane_type`'s own reasoning, applied to the client toggle itself). Circular's own fields (`_circularFields()`): an axis status line, Count/Angle(degrees) text fields, a reverse toggle - deliberately **no** fixed-world-axis button the way Direction 1/2 have X/Y/Z buttons, since a circular pattern needs a real pivot point a bare direction can't supply; the axis is picked exclusively via a viewport tap on an edge or a face.
- `part_screen.dart` gained a parallel axis-picking state section alongside Phase 2's own direction-picking one: `_patternMode`, `_patternAxis`/`_patternAxisEntity`, `_patternCountAngular`/`_patternAngleTotal`/`_patternReverseAngular`, a new `_patternAxisSelectionFilter` (edge **and** face enabled together - confirmed `filter.edge`/`filter.face` coexist fine in `hitTestBodies`, unlike `filter.body`/`filter.face`'s mutual exclusivity), `_setPatternMode` (swaps the pushed selection filter and clears whichever mode's fields are being left), `_setPatternAxisFromEntity` (single-slot replace-not-accumulate pick, mirroring `_setMirrorPlane`). `_openPatternPanelForEdit` now branches on the edited Feature's own `pattern_type` (defaulting to Rectangular for backward compatibility) to reconstruct either Direction 1/2 state or axis state and push the matching filter - `feature_tree_panel.dart` itself needed no changes at all, since it keys purely on the generic `feature.type == 'pattern'`, unaware of `pattern_type`.
- `document_api_client.dart`: `PatternAxisRefDto`, `FeatureDto`'s `patternType`/`axis`/`countAngular`/`angleTotal`/`reverseAngular`, `createPatternFeature`/`updatePatternFeature` widened with the new circular fields (`updatePatternFeature` deliberately has no `patternType` parameter at all, since the backend never accepts one on update).
- `pattern_panel_test.dart` widened with 15 new tests: the mode toggle's own show/hide-by-`canChangeMode` and tap-to-switch behavior, Circular Confirm-enablement (no axis, `count_angular` of 1, invalid `angle_total`), the axis hint/summary text, Count/Angle field edits, the reverse toggle, and confirming no fixed-axis button exists in Circular mode.

Verified for real, using the same local toolchains from every prior Phase's own verification pass: full backend `pytest` suite 1040/1040 (1014 prior + 26 new); `flutter analyze` clean on the whole client project; full client `flutter test` suite 970/970 (955 prior + 15 new). Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-28 — Same-day follow-up: Sketch Lines exposed as Linear pattern directions, Sketch Lines and straight Body edges exposed as Circular pattern axes

Asked directly: "linear pattern: make sketch lines a valid target for pattern direction" and "circular pattern: make sketch lines and straight edges of bodies a valid target as the axis around which to pattern." A Sketch-Line direction/axis was already fully backend-supported (both phases had deliberately deferred exposing it in the client, for the reason below); a straight Body edge as a Circular Pattern axis was a genuinely new backend capability.

**Backend** (`app/document/pattern.py`, `backend/tests/test_stage_k_pattern_circular.py`):
- `_axis_from_ref`'s `edge_ref` branch now accepts a straight edge (`BRepAdaptor_Curve.GetType() == GeomAbs_Line`) as well as a circular one, resolving a `gp_Ax1` from the edge's own `gp_Lin.Location()`/`Direction()` - the same idea as a real axle running along that edge. The original `non_circular_edge` error was renamed to `unsupported_axis_edge` (still raised for a curve that's neither circular nor straight, e.g. elliptical/Bezier/BSpline - verified with a new test extruding an Ellipse-profile Sketch).
- **Bug found and fixed while adding the straight-edge test**: every OCCT circular extrusion has a straight seam edge connecting its top/bottom circular caps (a parametric-surface artifact, not something either the app or its tests created deliberately). `_first_circular_edge_index`'s brute-force probe previously only checked "did creating the pattern succeed" as proof an edge was circular - true before this revision (only a genuinely circular edge could succeed at all), but no longer, since the seam edge is now *also* a valid (if off-axis) `edge_ref`. Several existing geometry-correctness tests (the quadrant-position test, the reverse-direction test, the partial-angle test) started silently picking the seam edge instead of the true centre axis, producing wrong-but-plausible-looking rotated positions - caught by their own exact-position assertions failing. Fixed by having the probe verify the resulting self-rotated instance's bounding box is still centred near the world origin (true only for the Body's own true axis of rotational symmetry, never for an off-centre seam edge) rather than trusting success alone.
- New tests: a straight-edge-axis success test (verified geometrically via the same quadrant-position technique the circular-edge test uses, using a dedicated axis-defining box whose `(0, 0)` corner sits at the world origin, brute-forced by index since edge-to-index correspondence isn't part of the API's contract) and an elliptical-edge rejection test. Net: 1041/1041 backend tests (1040 prior - 1 replaced + 2 new).

**Client** (`part_screen.dart`, `pattern_panel.dart`):
- `_patternDirectionSelectionFilter`/`_patternAxisSelectionFilter` both gained `sketchLine: true` (already established safe to combine with `edge`/`face` - confirmed during the original Phase 4 investigation that `hitTestBodies`'s mesh-edge and Sketch-Line hit-test passes are fully independent, never mutually exclusive the way `body`/`face` are).
- `_setPatternDirectionFromEdge` was generalized and renamed `_setPatternDirectionFromEntity`; `_setPatternAxisFromEntity` was widened - both now build a `sketch_line_ref` (resolving the real Sketch id via the existing `_sketchIdForFeatureId`, the same conversion `_currentRevolveAxisRef` already does for Revolve's own axis) when the tapped entity is a Sketch Line, via new shared `_patternDirectionRefDtoFor`/`_patternAxisRefDtoFor` helpers. `_patternEdgeEntityFor`/`_patternAxisEntityFor` (B4 edit-mode reconstruction) were widened symmetrically, resolving a stored `sketch_line_ref`'s Sketch id back to a Sketch Feature id via the existing `_sketchFeatureIdForSketchId`, so re-opening an existing Sketch-Line-driven Pattern for editing now correctly highlights the Sketch Line in the viewport instead of showing no highlight at all.
- No dedicated Sketch-picker flow was built - this reuses the exact same live-viewport-tap mechanism Revolve's own axis pick already uses (`_setRevolveAxis`), leaving Sketch visibility entirely up to the user's existing eyeball toggle, same as Revolve's own axis pick already requires.
- `pattern_panel.dart`'s hint text and doc comments updated to mention Sketch Line/straight-edge availability (no functional change - `hasDirection1`/`hasAxis`/`direction1Summary`/`axisSummary` were already generic over the underlying ref shape from the very first Phase 4 implementation).
- `pattern_panel_test.dart`'s two hint-text assertions updated to match. Net: 970/970 client tests (no count change - only text updated, no tests added/removed).

Verified for real: full backend `pytest` suite 1041/1041; `flutter analyze` clean on the whole client project; full client `flutter test` suite 970/970. Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-28 — Merged Phase 4 + revision to main via PR #103, then Phase 3 (Skip instances) implemented for both Rectangular and Circular

Asked to merge the existing Pattern/Mirror branch to `main`, then start Phase 3 - explicitly noting Phase 4 (Circular pattern) was already implemented and might affect Phase 3's own design.

**Merge**: PR #101 (this branch's own earlier Phase 2 merge) had already landed on 2026-07-24; `main` had since advanced with an unrelated PR (#102, sketcher UI fixes). Rebased the branch's 3 new commits (Phase 4 + the Sketch-Line/straight-edge revision + the banner overflow fix) onto latest `main` (clean, no conflicts), re-verified locally (backend 1059/1059, client 971/971, `flutter analyze` clean), opened a fresh PR (#103, since #101 was already closed/merged and can't be reused), waited for its CI to go green (all 6 checks: backend amd64/arm64 x2 triggers, client analyze-and-test x2 triggers), then merged it. Reset the local designated branch to the new `main` tip per this session's own "merged PR -> restart from latest default branch" branch instructions.

**Phase 3 design check**: re-read `docs/pattern-mirror-scope.md`'s own §2.4/Phase 3 section before writing any code - it already anticipated both Rectangular (rectangular grid) and Circular (radial ring) variants from the very first scoping pass, even though Circular didn't exist yet at the time. No redesign was needed, only implementation against the now-real `PatternFeature`/`PatternPanel`.

**Backend** (`models.py`, `pattern.py`, `router.py`, `schemas.py`, `native_format.py`, new `test_stage_l_pattern_skip.py`):
- `skip_indices: list[int] = field(default_factory=list)` added to `PatternFeature`. `_rectangular_instances`/`_circular_instances` (`pattern.py`) filter `index in skip_indices` (as a `set`, computed once per call) alongside the existing `index == 0` seed check, before ever building a `BRepBuilderAPI_Transform` - a skipped instance never even briefly exists as a shape.
- New `app.document.router._validate_pattern_skip_indices(skip_indices, total_count)`, called from the shared `_validate_pattern_payload` entry point with whichever total count the resolved `pattern_type` implies (`count_1 * count_2` or `count_angular`) - rejects `0` (the seed, never created in the first place) and anything `>= total_count` outright.
- `PatternFeatureUpdate.skip_indices: list[int] | None` gets its own `None`-vs-`[]` distinction (mirrors `ExtrudeFeatureUpdate.target_body_ids`'s own convention) - `None` (omitted) leaves the current skip set untouched, `[]` explicitly un-skips everything.
- New `test_stage_l_pattern_skip.py` (14 tests): success (Rectangular 2D-grid skip, skipping every new instance leaves only the seed, Circular skip), a rigorous geometric test exploiting the fact that a 4-way circular pattern's index-2 (180°) instance lands in the same quadrant regardless of OCCT's own CW/CCW rotation convention (skipping it therefore has one single, fully-predictable expected outcome - the full 4-quadrant set minus the diametrically-opposite one), PATCH updates/omission-preserves/empty-list-clears, PATCH rejecting an invalid index leaves the original unchanged, and every rejection (index 0, `>= total_count`, negative, circular `>= count_angular`). Full backend suite: 1073/1073 (1059 prior + 14 new).

**Client** (`document_api_client.dart`, new `pattern_skip_grid.dart`, `pattern_panel.dart`, `part_screen.dart`, new `pattern_skip_grid_test.dart`, widened `pattern_panel_test.dart`):
- `FeatureDto.skipIndices`, `createPatternFeature`/`updatePatternFeature` widened (`updatePatternFeature`'s own `List<int>? skipIndices` mirrors the backend's `None`-vs-`[]` split exactly).
- New `pattern_skip_grid.dart` (`PatternSkipGrid`): a `PatternSkipGridLayout.rectangular`/`.radial` toggle - **a deliberate simplification from this doc's own original design note**, which suggested a `CustomPainter` for the radial case; plain `Positioned` dot widgets inside a `Stack` give the identical visual ring layout with free hit-testing (no custom painting/pointer-math needed), so that's what got built instead. Index `0` (the seed) always renders filled and non-interactive (`onTap: null`); every other index is tappable, filled when active and hollow (`Colors.transparent`) when skipped. The radial layout's dot spacing follows `angle_total`, not always a full circle.
- `pattern_panel.dart` gained `skipIndices`/`onSkipToggled` props and a shared `_skipInstancesSection()` helper (hidden when the pattern's own current total count is `<= 1`), called from both `_rectangularFields()`/`_circularFields()` using the panel's own live `_count1`/`_count2`/`_countAngular`/`_angleTotal` state.
- `part_screen.dart` gained `_patternSkipIndices`/`_onPatternSkipToggled`, wired into `_ensurePatternFeatureExists` (clamped to the pattern's own *current* total count right before every send - shrinking a count after some indices were already skipped could otherwise send an out-of-range index alongside the smaller count in the same request, which the backend would reject outright), `_openPatternPanelForEdit` (both modes, reconstructing from `feature.skipIndices`), and the confirm/cancel/reset paths.
- New `pattern_skip_grid_test.dart` (8 tests) plus 6 new tests in `pattern_panel_test.dart` covering the wired-in section (hidden/shown by total count, correct layout/totalCount per mode, tap-to-toggle, reflecting `skipIndices`). Full client suite: 985/985 (971 prior + 8 + 6 new), `flutter analyze` clean.

Verified for real, using the same local toolchains from every prior Phase's own verification pass: full backend `pytest` suite 1073/1073; `flutter analyze` clean on the whole client project; full client `flutter test` suite 985/985. Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-28 — Same-day UX revision: skip-instances moved into the viewport, toolbar/FAB layout fixes, Pattern build-tree edit/delete verified

Direct feedback on the just-shipped Phase 3 UI, plus three smaller UX asks, all bundled into one request:
1. "the area in the UI where instances are toggled is too big... allow the user to click the preview bodies to skip/keep them. change colour to show if it will be kept or skipped." (a fourth ask, a small clickable "cubic node" marker at each instance's centroid as a secondary toggle target, was scoped but **not built this pass** - see below.)
2. "max height for the toolbar should be 1/3 of screen."
3. "move the orbit/select fab just above the toolbar."
4. "pattern should be a feature that appears in the build tree so the user can edit or delete the pattern feature."

**Item 4 first, since it changed nothing**: re-read `_onFeatureTap`'s existing `feature.type == 'pattern'` branch and the generic cascade-delete flow - both already worked correctly for Pattern with zero special-casing, going all the way back to Phase 2. Added two `part_screen_test.dart` regression tests ("tapping a Pattern row in the Feature tree opens it for editing", "long-pressing a Pattern row offers Delete, same as any other Feature type") to lock this in, rather than changing any production code.

**Items 2/3** (`part_toolbar.dart`, `part_screen.dart`): the toolbar's `BoxConstraints(maxHeight: 520)` became `MediaQuery.sizeOf(context).height / 3`. The `selection-mode-fab` moved from the bottom-right `floatingActionButton` Column into the top-left `Positioned` Column (above the hamburger/feature-tree FABs), as a `FloatingActionButton.small`, unconditionally visible (its old hide conditions - "would cover the open toolbar panel" / "would cover the orientation-confirm banner" - were both bottom-right-specific and no longer apply). Follow-on fix: `PartToolbar`'s own top padding (56 -> 104) to clear the now-two-FAB-tall top-left stack.

**Item 1 - the skip-instances redesign** (`part_screen.dart`, `part_viewport.dart`, `pattern_panel.dart`; deleted `pattern_skip_grid.dart`/`pattern_skip_grid_test.dart`):
- The backend's `skip_indices` field/validation/filtering (Phase 3, same day) is entirely unchanged - only the client's own sequencing of when it sends the real selection changed. While a Pattern is being configured, `_ensurePatternFeatureExists` now always sends `skip_indices: []` on every debounced create/update call (gained an optional `skipIndices` parameter defaulting to `const []`), so every instance stays present - and tappable - in the live mesh throughout editing regardless of the user's actual selection. Toggling an instance is now a purely local `_patternSkipIndices` mutation with no network round-trip. The real selection is only ever sent once: `_confirmPattern` now computes the real, clamped skip list and issues one final `_ensurePatternFeatureExists(skipIndices: real)` PATCH before its own state teardown. `_openPatternPanelForEdit` force-reveals every instance the same way (fires an immediate `_ensurePatternFeatureExists()` call) the moment an existing skip-carrying Pattern is opened for editing.
- New `_patternInstanceIndexForBodyId(bodyId)`/`_patternSkippedBodyIds` helpers recover a tapped Body's own pattern-instance linear index (and the reverse: skip-index-set -> body-id-set) purely from the body id's own naming scheme - `compute_part_bodies`'s existing `feature.id`/`feature.id#index` convention (`extrude.py`), reversed client-side with zero backend changes. A new special case in `_toggleSelectedEntity` (gated on `_patternStep == configuring && entity.kind == body`) routes a tap on one of the pattern's own instances (excluding index `0`, the seed) to a local `_togglePatternSkipIndex` instead of the generic accumulate-select fallback.
- `PartViewport` gained `skippedPreviewBodyIds` (a `Set<String>`, defaults `{}`) - in `_syncMeshNode`, a Body whose id is a member gets a distinct, more-transparent pale-grey `UnlitMaterial` tint instead of the ordinary translucent preview-orange, so kept vs. skipped instances read apart at a glance; wired from `part_screen.dart` via `skippedPreviewBodyIds: _patternSkippedBodyIds`.
- `pattern_panel.dart`'s `skipIndices`/`onSkipToggled` props and `_skipInstancesSection` (the dot-grid) were removed outright, replaced by a one-line `_skipInstancesHint` ("Tap an instance in the viewport to skip or keep it"), shown/hidden under the same `totalCount <= 1` guard the grid used.
- **Not built this pass**: the "cubic node at the centre of each instance" marker (a secondary, always-reachable toggle target for small/thin instances where a direct Body tap is fiddly). It would need a genuinely new screen-space hit-test - a Body's own centroid is occluded from every existing ray-based hit-test function by the Body's own surface (see `facesOccludeOtherHits`) - unlike the Body-tap interaction, which reuses the existing ray-based `hitTestFaces`/body-kind-selection pipeline unchanged. Left as a scoped follow-up (`docs/pattern-mirror-scope.md`'s Phase 3 "revised same-day" note), not scheduled.
- Test-fixture fix found along the way: `part_screen_test.dart`'s shared `_placeholderMesh` had `triangle_indices` but no `face_ids` - `hitTestFaces` indexes `mesh.faceIds` parallel to the triangle list (see `MeshDto.faceIds`'s own doc comment), so a hover ray that happens to actually intersect that triangle throws a `RangeError` instead of returning no hit. This was a dormant landmine (no existing test's default hover state ever intersected the tiny placeholder triangle); it surfaced once the fake `/mesh` endpoint below started returning multiple Bodies sharing that same geometry. Fixed by adding `'face_ids': [0]` to the fixture.
- Test/doc changes: `pattern_skip_grid_test.dart` deleted; `pattern_panel_test.dart`'s skip-grid test group (6 tests) replaced with a 4-test hint-visibility group; the fake backend's `/mesh` GET handler in `part_screen_test.dart` was made Pattern-aware (synthesizes real per-instance body ids from a seeded `pattern` Feature's own stored fields, filtered by its own stored `skip_indices` - mirrors the real backend's behavior exactly) so two new integration tests could exercise this end to end: "editing a Pattern with skip_indices reveals every instance for editing, and Confirm re-applies the real skip selection", and "tapping a Pattern instance Body in the viewport toggles its own skip/keep state, and Confirm sends that real selection to the backend" (also verifies the toggle itself never PATCHes). Net client suite: 979/979 (985 prior + 2 new Feature-tree tests from Item 4's verification pass above = 987, - 8 deleted `pattern_skip_grid_test.dart` - 2 net from the rewritten `pattern_panel_test.dart` group + 2 new viewport-toggle integration tests = 979), `flutter analyze` clean.

Verified for real: full backend `pytest` suite 1073/1073 (unchanged - no backend files touched this pass); `flutter analyze` clean on the whole client project; full client `flutter test` suite 979/979. Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-29 — Phase 5 (Merge options) implemented for both Mirror and Pattern

New session. Asked to implement Phase 5 of `docs/pattern-mirror-scope.md` (§2.10/§4): a `MergeMode` (`KEEP_SEPARATE` default, `FUSE_INTO_ONE`) field on both `MirrorFeature` and `PatternFeature`, fusing via `BRepAlgoAPI_Fuse` the same way `_apply_boss_or_cut`'s existing multi-target fuse already does. Read `docs/pattern-mirror-scope.md` in full and every dated `docs/status.md` entry from 2026-07-23 onward first, per the task's own instruction, before writing any code.

**Branch note**: the designated branch (`claude/didsa-pattern-mirror-implementation-19l4wc`) had already been merged to `main` via PR #106 (the prior session's Phase 3 UX redesign) - per this session's own branch instructions, restarted it fresh from `origin/main`'s current tip rather than stacking on top of already-merged history.

**Backend**, following the established six-part Feature-checklist pattern every prior phase used:
- `MergeMode` enum (`app/document/models.py`) - `KEEP_SEPARATE`/`FUSE_INTO_ONE`, str-Enum mirroring `PatternType`/`FixedAxis`'s own convention. `merge: MergeMode = MergeMode.KEEP_SEPARATE` added to both `MirrorFeature` and `PatternFeature` (additive, default-preserving).
- New `app.document.extrude._fuse_realized_instances(bodies, feature_index, base_ids, realized_shapes)`, placed directly after `_apply_boss_or_cut` (the two `MirrorFeature`/`PatternFeature` `compute_part_bodies` branches were already inline in `extrude.py`, not delegated to `mirror.py`/`pattern.py`, so this follows the same placement): fuses every already-transformed shape in `realized_shapes` (Mirror's own mirrored copies, or Pattern's own non-seed/non-skipped instances) together with every existing Body named in `base_ids` (Mirror's `source_body_ids`; Pattern's single-entry seed) via repeated `BRepAlgoAPI_Fuse` - the same call `_apply_boss_or_cut`'s own multi-target fuse already uses. The surviving Body id mirrors `_apply_boss_or_cut`'s own tie-break exactly: whichever `base_ids` entry's owning Feature sorts lowest in `feature_index` - the fused result inherits an existing Body's identity rather than minting a brand-new one, same as a Boss fused into a target. Every other `base_ids` entry is deleted from `bodies`; the fused shape is (re)registered via `_register_solids`, so a fuse producing more than one disconnected solid still splits correctly.
- `compute_part_bodies`'s `MirrorFeature`/`PatternFeature` branches each gained a `feature.merge == MergeMode.FUSE_INTO_ONE` case dispatching to `_fuse_realized_instances`, alongside the existing single-vs-`#N`-suffix `KEEP_SEPARATE` registration (now the `elif`/`else` branch, unchanged).
- `schemas.py`/`router.py`: `merge` threaded through `MirrorFeatureCreate/Update/Response` and `PatternFeatureCreate/Update/Response` exactly like every other field - no new validation needed (Pydantic's own enum parsing rejects an invalid string as a 422 for free). `_feature_response` and both create/update endpoints (for both Feature types) updated to read/write it.
- `native_format.py`: `merge` added to both Features' `_feature_to_dict`/`_feature_from_dict`, defaulting a missing `"merge"` key to `KEEP_SEPARATE` on import (`data.get("merge", MergeMode.KEEP_SEPARATE.value)`) for backward compatibility with every pre-Phase-5 save.
- New `backend/tests/test_stage_m_merge.py` (16 tests): Mirror's default/explicit `KEEP_SEPARATE`, `FUSE_INTO_ONE` producing a single touching-geometry Body (verified via bounding-box union), a disconnected-mirror case still splitting into two Bodies, a two-source case confirming the survivor id is the earlier-created source (via a chain-connected geometry setup - `mirrored_b` touches `mirrored_a` touches `body_a` touches `body_b`, all one solid, so the split-count ambiguity a naively-disjoint two-source case would have is avoided), PATCH toggling merge on an existing Feature, PATCH omitting `merge` leaving it unchanged, and an invalid `merge` string rejected with 422 - then the same shape for Pattern (Rectangular: default, fuse producing one overlapping-instance Body, fuse respecting `skip_indices` - a skipped instance is never part of the merge either, fuse of fully-disjoint instances splitting into three, PATCH toggle, invalid value rejected) plus one Circular fuse test (reusing `test_stage_k_pattern_circular.py`'s own quadrant-position box-around-a-cylinder-axis setup, confirming a fuse of non-touching quadrant instances still splits into four separate Bodies at the expected positions). Also extended `test_stage_native_format.py`: the existing "every feature type" round-trip's `MirrorFeature` now carries a non-default `merge=FUSE_INTO_ONE` (so the round trip actually exercises the field, not two matching defaults), a new dedicated `PatternFeature` round-trip test (`PatternFeature` had never been added to that file's own "every feature type" tree, a pre-existing gap not otherwise in this phase's scope - fixed narrowly, scoped to `merge` plus enough surrounding fields to prove the whole Feature round-trips), and a backward-compatibility test importing hand-crafted legacy dicts with no `"merge"` key at all for both Feature types, confirming they default to `KEEP_SEPARATE` rather than raising.

**Toolchain bootstrap**: no `pythonocc-core`/Flutter SDK preinstalled in this sandbox (same starting point every prior phase's own session hit). Installed micromamba from `github.com/mamba-org/micromamba-releases`' `latest/download` asset URL (the `api.github.com` release-metadata endpoint is blocked in this sandbox's GitHub scoping - only repos explicitly attached to the session are reachable through it - but the direct `github.com/.../releases/latest/download/...` asset redirect isn't gated the same way and works fine), built the same `didsacad` conda-forge env from `backend/environment.yml`, and ran the full backend `pytest` suite against genuine OCCT. For the client, `storage.googleapis.com`'s stable-channel Flutter archive installs fine but fails to compile (`flutter_scene` 0.18.1 needs `flutter_gpu` API surface - `VertexLayout`/`VertexFormat`/`TextureCompressionFamily`/etc. - that stable Flutter doesn't have yet); `.github/workflows/client-verify.yml`'s own comment already documents this and pins CI to `channel: master` for exactly this reason, so this session `git clone --depth 1 --branch master https://github.com/flutter/flutter.git` instead (matching CI's own toolchain), which built and ran cleanly.

**Client**, following Mirror/Pattern's own established panel-and-`part_screen.dart`-wiring conventions:
- New `MergeMode` enum in `document_api_client.dart` (`keepSeparate`/`fuseIntoOne`, `apiValue`/`fromApiValue` mirroring `PatternMode`'s own convention) - placed here rather than duplicated per-panel like `RevolveMode`/`PatternMode` are, since (unlike those, which each pick between two *disjoint field groups*) this is a simple two-way toggle both Mirror and Pattern share verbatim. `FeatureDto.merge` stays a raw `String` (matching `mode`/`patternType`'s own convention), defaulting to `'keep_separate'`.
- `createMirrorFeature`/`updateMirrorFeature`/`createPatternFeature`/`updatePatternFeature` all widened with a `MergeMode merge`/`MergeMode? merge` parameter, serialized via `.apiValue`.
- `mirror_panel.dart`/`pattern_panel.dart` both gained a `merge`/`onMergeChanged` prop pair and a `SegmentedButton<MergeMode>` ("Keep Separate" / "Merge into One Body") - Pattern's own toggle sits below whichever mode's fields are showing (shared by both Rectangular and Circular), Mirror's sits below the plane-pick hint text, both just above the Confirm/Cancel row.
- `part_screen.dart`: `_mirrorMerge`/`_patternMerge` state (reset to `MergeMode.keepSeparate` at the start of every fresh session - `_startMirrorPicker`/`_openMirrorPanel`/`_resetPatternConfiguringState` - and on confirm/cancel teardown; reconstructed from the edited Feature's own stored `merge` value in `_openMirrorPanelForEdit`/`_openPatternPanelForEdit`), added to both Features' own B4 edit-snapshot record types (`_mirrorEditSnapshot`/`_patternEditSnapshot`) so Cancel's revert-PATCH restores it correctly, `_setMirrorMerge`/`_setPatternMerge` setters (mirroring `_setMirrorPlane`'s own "update state, reschedule the debounced preview" shape) wired into `_ensureMirrorFeatureExists`/`_ensurePatternFeatureExists`'s create/update calls and into the `MirrorPanel`/`PatternPanel` widget construction sites.
- New tests: `mirror_panel_test.dart` gained a "merge toggle" group (3 tests: default-selected, reflects `fuseIntoOne`, tapping "Merge into One Body" fires `onMergeChanged`) - every existing `MirrorPanel(...)` construction in the file widened with the two new required params. `pattern_panel_test.dart`'s shared `harness()` builder gained `merge`/`onMergeChanged` parameters (only one real construction site, so no repetitive widening needed), plus a new "merge toggle" group (4 tests: default-selected in Rectangular, reflects `fuseIntoOne`, tap fires `onMergeChanged`, shown in Circular mode too).

Verified for real, using the freshly-bootstrapped toolchains above: full backend `pytest` suite 1091/1091 (1073 prior + 16 new `test_stage_m_merge.py` + 2 new native-format tests); `flutter analyze` clean on the whole client project; full client `flutter test` suite 992/992 (7 skipped, pre-existing GPU/Impeller-unavailable skips unrelated to this change). Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-29 — Same-day follow-up: PatternPanel made pull-to-resize, with genuinely scrollable content

Direct on-device feedback: "make the tool ribbon for pattern feature pullable with a handle at the top of the ribbon to extend, retract it also make the contents scrollable." Same session as Phase 5's own merge-options work above, continued with the same local toolchains still available (micromamba backend env, `master`-channel Flutter clone).

**Real bug this fixes, not just a cosmetic ask**: `pattern_panel.dart`'s own `SingleChildScrollView` was already present, but with no bounded height anywhere above it in the tree (`Align` → `SafeArea` → `Material` → `SingleChildScrollView`, none of which constrain height), an unbounded `SingleChildScrollView` just sizes to fit its child - it never actually had anything to scroll *within*. A tall configuration (Rectangular with a second direction enabled, plus the Phase 5 merge toggle) could push Confirm/Cancel off the bottom of a short/landscape viewport with no way to reach them at all.

**Fix** (`client/lib/viewport3d/pattern_panel.dart`): the panel now has a genuinely bounded, resizable height - `_heightFraction` (a fraction of the available viewport height, defaulting to `0.5`, clamped to `_minHeightFraction`/`_maxHeightFraction` = `0.25`/`0.85`) mirrors `FeatureTreePanel._widthFraction`'s own drag-to-resize convention exactly, just vertical instead of horizontal. `build()` is now wrapped in a `LayoutBuilder` to read the available height, computes `panelHeight = (_heightFraction * totalHeight).clamp(...)`, and wraps the `Material` in a `SizedBox(height: panelHeight)` (keyed `patternPanelResizableArea` for testability) - the `SingleChildScrollView` is now a genuinely bounded `Expanded` child of a `Column` inside that fixed-height `Material`, so it actually scrolls once content exceeds whatever height the user has left it at. New `_buildDragHandle` (keyed `patternPanelDragHandle`) - a `MouseRegion`/`GestureDetector` top-of-panel grip (a 56×4 pill, matching `FeatureTreePanel`'s own visible-grip styling, inside a 20px-tall full-width invisible hit target for touch comfort) - `onVerticalDragUpdate` adjusts `_heightFraction` by `-details.delta.dy / totalHeight` (dragging up extends, dragging down retracts, same sign convention `FeatureTreePanel`'s own horizontal handle uses, just flipped to vertical), clamped the same way. `MirrorPanel` (Mirror's own panel, which the request didn't name) was left untouched - its own content is short enough not to have this problem, and the ask was scoped specifically to Pattern's own ribbon.

**Test fallout, all expected and fixed**: giving the panel a real bounded height means several existing tests' `tester.tap(...)` calls on Confirm/Cancel/"Remove second direction"/the merge toggle now land below the default-height fold in a small test viewport (800×600) - `tester.ensureVisible(...)` (already this codebase's own established fix for exactly this situation, per `part_screen_test.dart`'s and `widget_test.dart`'s own prior usage) added before each affected tap in `pattern_panel_test.dart` (4 tests) and `part_screen_test.dart` (2 Pattern-editing integration tests). New `PatternPanel drag-to-resize handle` test group (6 tests): the handle/resizable-area both present, dragging up grows the panel's measured height, dragging down shrinks it, an extreme drag in either direction clamps rather than overflowing/throwing/going to zero, and content dragged down to the minimum height is still reachable via `ensureVisible` (proving the scroll view is genuinely bounded and functional, not just present).

Verified for real, same toolchains: full backend `pytest` suite unchanged at 1091/1091 (no backend files touched this pass); `flutter analyze` clean; full client `flutter test` suite 998/998 (992 prior + 6 new drag-handle tests, 7 skipped, pre-existing GPU/Impeller-unavailable skips unrelated to this change). Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-29 — Phase 6 (Multi-feature seed selection + Pattern's own multi-body) implemented, closing out the Pattern/Mirror effort's originally-scoped phases

New session. Asked to implement Phase 6 of `docs/pattern-mirror-scope.md` (§4/§2.8): widen `PatternFeature.source_body_ids` from exactly-one to 1+ (mirroring `MirrorFeature`'s own Phase 1 revision), add `source_feature_ids` (Feature-tree entries as selection sources) to both Mirror and Pattern, and wire the client's own multi-select accumulator into Pattern's panel plus a Feature-tree multi-select entry point for `source_feature_ids` on both. Read `docs/pattern-mirror-scope.md` in full and every dated `docs/status.md` entry from 2026-07-23 onward first, per the task's own instruction.

**Branch note**: the designated branch (`claude/pattern-mirror-phase-6-nluo5e`) already existed locally, up to date with `origin/main`'s current tip (`be253f5`) and not yet merged - worked directly on it rather than restarting.

**Backend**, following the established six-part Feature-checklist pattern every prior phase used:
- `PatternFeature` (`app/document/models.py`) gained `source_feature_ids: list[str]` (mirrors `MirrorFeature`'s own field, added in Phase 1 but left unused until now); both classes' docstrings updated to describe the combined-and-deduplicated resolution.
- `app/document/graph.py`: new `body_ids_for_feature_id(body_ids, feature_id)` - the scope doc's own one-line `{bid for bid in bodies if base_feature_id(bid) == fid}` lookup, generalized to an order-preserving list (Pattern/Mirror need deterministic per-source Body registration, a bare set doesn't give that). `_mirror_dependencies`/`_pattern_dependencies` now also add every `source_feature_ids` entry directly as a dependency edge (already a bare Feature id, no `base_feature_id` mapping needed) - cascade delete works for both `source_body_ids` and `source_feature_ids` sources.
- `app/document/mirror.py`/`pattern.py`: new `effective_mirror_source_body_ids`/`effective_pattern_source_body_ids` - combine `source_body_ids` with every Body each `source_feature_ids` entry currently resolves to (via `body_ids_for_feature_id`), deduplicated preserving order, raising a structured `missing_reference` (keyed by `feature_id`) for an entry that resolves to zero Bodies. `resolve_mirror_from_bodies` now iterates the effective list instead of the raw field. `resolve_pattern_from_bodies` was restructured more substantially - Pattern's own multi-body widening means it can no longer assume a single seed: it now returns `dict[str, dict[int, TopoDS_Shape]]` (source id → that source's own linear-index → instance map) instead of a bare `dict[int, TopoDS_Shape]`, looping the existing `_rectangular_instances`/`_circular_instances` once per effective source - every source shares the identical instance-transform grid (same direction/axis/count/spacing/skip_indices), so no per-source parameter variation was needed, just per-source iteration.
- `app/document/extrude.py`'s `compute_part_bodies`: the `MirrorFeature` branch's `FUSE_INTO_ONE` case now passes `effective_mirror_source_body_ids(bodies, feature)` to `_fuse_realized_instances` instead of the raw `feature.source_body_ids` - a Feature-tree-picked source's own real Body must be absorbed into the fuse too, not just literal `source_body_ids` entries. The `PatternFeature` branch was rewritten for the new per-source-dict return shape: a single effective source keeps the *exact* pre-Phase-6 naming (`feature.id` alone for one new instance, `feature.id#{index}` otherwise) completely unchanged - verified deliberately, since this is what keeps every pre-Phase-6 persisted Pattern's own Body ids identical, and what the Phase 3 skip-instance viewport-tap-to-toggle client logic depends on parsing correctly; 2+ sources use a new `feature.id#{source_index}_{index}` scheme.
- **Real design decision, not in the original scope doc**: widened the accepted-producer-type set for both `source_body_ids` and (the new) `source_feature_ids` on both Feature types to include `MirrorFeature`/`PatternFeature` themselves, alongside the original `ExtrudeFeature`/`RevolveFeature`/`SweepFeature`/`ImportFeature`. Phase 1's own docstring had explicitly said chaining a Mirror off another Mirror's own output was "deliberately not (yet) an accepted producer... since chaining a Mirror off another Mirror's own output is still Phase 6 scope" - this phase is where that was actually supposed to land, and leaving it out would have meant closing out Phase 6 without ever delivering the "Pattern seed = pattern (nested patterns)" survey-table item §3 called "structurally unblocked already". New `_validate_source_feature_ids` (`app.document.router`) shares this widened accepted-type set with both `_validate_mirror_source_body_ids`/`_validate_pattern_source_body_ids`'s own `source_body_ids` per-entry checks (which were widened identically) - a bare 400 rejection for the wrong Feature type, same shape `_validate_target_body_ids` already established.
- `router.py`/`schemas.py`/`native_format.py`: `source_feature_ids` threaded through `PatternFeatureCreate/Update/Response` (Mirror's own three already had it, just unused); `_validate_mirror_source_body_ids`/`_validate_pattern_source_body_ids` now take `source_feature_ids` too and require *at least one entry between* `source_body_ids`/`source_feature_ids` combined (not `source_body_ids` alone) - a Mirror/Pattern seeded purely from the Feature tree, with zero direct Body picks, is now a legitimate payload shape. `native_format.py`'s `PatternFeature` export/import gained `source_feature_ids` (defaults to `[]` on import for any pre-Phase-6 save, same convention every other additive field here uses).
- New `backend/tests/test_stage_n_multi_source.py` (20 tests, real OCCT): Mirror's `source_feature_ids` alone / combined with `source_body_ids` / deduped when a Body is named both ways / rejecting an unknown or wrong-type (a SketchFeature) `source_feature_ids` entry / accepting another MirrorFeature as a nested source / PATCH updating `source_feature_ids`; Pattern's own 2-source `source_body_ids` widening (verified via independent bbox-shift-per-source, since each source translates along the same direction from its own different starting position) / `source_feature_ids` alone / combined-and-deduped / multi-source `skip_indices` applying identically to every source (verified via total Body count) / multi-source `FUSE_INTO_ONE` absorbing every source and every instance into one survivor Body (confirmed via `_apply_boss_or_cut`'s own survivor-id tie-break, `base_feature_id`-mapped) / PATCH updating `source_feature_ids`; cascade delete via a `source_feature_ids`-only source, for both Feature types. Also extended `test_stage_native_format.py`'s existing Phase-5 Pattern round-trip test with a non-empty `source_feature_ids`, and its existing legacy-dict backward-compatibility test to assert both Feature types default `source_feature_ids` to `[]` when the key is entirely absent (a pre-Phase-6 save).

**Toolchain bootstrap**: no `pythonocc-core`/Flutter SDK preinstalled in this sandbox (same starting point every prior phase's own session hit). Installed micromamba from `github.com/mamba-org/micromamba-releases`' `latest/download` asset URL, built the `didsacad` conda-forge env from `backend/environment.yml`, ran the full backend `pytest` suite against genuine OCCT throughout. For the client, `git clone --depth 1 --branch master https://github.com/flutter/flutter.git` (matching `.github/workflows/client-verify.yml`'s own `channel: master` pin - `stable` fails to compile against `flutter_scene`'s `flutter_gpu` API needs, per that workflow's own comment).

**Client** - the harder-than-originally-estimated half, per the scope doc's own flagged uncertainty:
- **On-device/real check performed first, as instructed, before estimating further**: read `feature_tree_panel.dart` in full. Confirmed it had zero multi-select mechanism of any kind - every existing mode (`isSketchPickerMode`, used identically by the Extrude/Revolve/Sweep Sketch pickers) is single-pick, committing immediately on tap. This meant the Feature-tree-as-`source_feature_ids`-selection-source piece needed real new machinery, not just wiring an existing one in.
- New `FeatureTreePanel.isFeaturePickerMode` (`pickableFeaturePickerIds`/`selectedFeaturePickerIds`/`onFeaturePickerToggle`): a tap on a pickable row toggles set membership instead of committing; a non-pickable row is dimmed and fully inert (no tap callback at all - simpler than the sketch picker's own SnackBar-on-ineligible-tap feedback, since dimming alone communicates it here); a selected row shows a trailing check-circle icon; a top banner names the running selection count. Confirming/cancelling is a `PartScreen`-owned checkmark FAB / the panel's own close (X) button, not a control embedded in the tree panel itself - mirrors Mirror's own `pickingBodies` step shape (confirm via FAB, not a button in the picked-thing's own list).
- `part_screen.dart`: new `_SourceFeaturePickerTarget { mirror, pattern }` state (`_sourceFeaturePickerTarget`/`_selectedSourceFeatureIds`), `_startSourceFeaturePicker`/`_sourceFeaturePickerPickableIds` (mirrors the backend's own widened accepted-type set, excluding whichever Mirror/Pattern is currently being configured itself)/`_toggleSourceFeaturePick`/`_confirmSourceFeaturePicker` (applies the selection back into `_mirrorSourceFeatureIds`/`_patternSourceFeatureIds` and reschedules that panel's own live-preview debounce)/`_cancelSourceFeaturePicker` - shared by both Mirror and Pattern rather than duplicated per-panel, since the mechanism is identical, only which field it writes back to differs. `FeatureTreePanel`'s own `visible` condition widened to show it whenever this picker session is active (overriding the `!_mirrorActive`/`!_patternActive` guards that would otherwise hide it, since this is opened *from inside* an already-active Mirror/Pattern panel); `MirrorPanel`/`PatternPanel` themselves hidden for the duration (`_sourceFeaturePickerTarget != _SourceFeaturePickerTarget.mirror/.pattern` added to their own `if` guards) rather than stacked underneath. `mirror_panel.dart`/`pattern_panel.dart` both gained a `sourceFeatureIds`/`onPickSourceFeatures` prop pair - a summary line ("N Feature(s) added from the Build Tree") plus an "Add from Tree" `TextButton.icon`.
- **Pattern's own multi-body widening** (the client's "feed the existing accumulator into the panel" half): `_PatternStep.pickingBody` (singular) became `pickingBodies` (plural), restructured to mirror `_MirrorStep.pickingBodies`'s own multi-select-then-confirm shape exactly rather than Phase 2's original "one tap immediately advances" one - `_confirmPatternBodySelection` is now a no-arg function reading every currently-selected Body out of `_selectedEntities` (same as Mirror's own), triggered by a new checkmark FAB, not a per-tap handler. `_patternSourceBodyId: String?` became `_patternSourceBodyIds: List<String>?` throughout - every picker/reset/edit/confirm/cancel function, `_ensurePatternFeatureExists`/`_schedulePatternPreview`. The trickiest part: `_patternInstanceIndexForBodyId`/`_patternSkippedBodyIds` (the Phase 3 viewport-tap-to-skip machinery, reversing the backend's own Body-naming scheme client-side) had to learn *two* naming schemes - the pre-Phase-6 single-source one (`feature.id`/`feature.id#index`, left completely unchanged when there's exactly one effective source) and the new multi-source `feature.id#{sourceIndex}_{index}` one, dispatching on `_patternSourceBodyIds!.length`. `selection_actions.dart`'s ambient `contextActionsFor` Pattern branch widened from "exactly one Body, else disabled with a reason" to "1+ Bodies, nothing else" - now byte-for-byte identical to Mirror's own branch, so the two were collapsed to return the same two-action list directly rather than duplicating the shape with different `enabled` values.
- New/widened tests: `feature_tree_panel_test.dart` gained a 7-test `isFeaturePickerMode` group (banner text with/without a count, tap-toggles-via-callback on a pickable row, a non-pickable row's tap is fully inert, the check-circle icon on a selected row, long-press disabled while picking). `mirror_panel_test.dart`/`pattern_panel_test.dart` each gained a "source Features from tree" group (3-4 tests: empty/non-empty summary text, the Add-from-Tree tap firing its callback, shown in Circular mode too for Pattern's). `selection_actions_test.dart`'s old "two Bodies together offer Mirror enabled but Pattern disabled" test replaced with one asserting both are now enabled. New `part_screen_test.dart` integration test: opens the Build Tree Feature picker from inside an already-editing `PatternPanel`, confirms `PatternPanel` itself hides and the tree shows the picker banner instead, toggles a pickable `ExtrudeFeature` row, confirms via the FAB, and asserts the resulting debounced PATCH body actually carries `source_feature_ids: ['feature-2']` (the fake test backend's own `pattern-features` PATCH handler widened to also honor `source_body_ids`/`source_feature_ids`, matching the real backend's update-endpoint field set, plus a captured `lastPatternPatchBody` for exactly this assertion) - the one integration-level test covering the picker end-to-end, since no prior phase had built out fake-backend POST-creation infrastructure for Mirror/Pattern to extend for a fuller guided-flow integration test, matching this project's own established "guided-picker flows verified at the panel-unit-test level plus code review, not deep part_screen integration tests" precedent.

Verified for real, using the freshly-bootstrapped toolchains above: full backend `pytest` suite 1115/1115 (1095 prior + 20 new `test_stage_n_multi_source.py`); `flutter analyze` clean on the whole client project; full client `flutter test` suite 1016/1016 (7 skipped, pre-existing GPU/Impeller-unavailable skips unrelated to this change). Not yet confirmed on a real device - no phone attached to this sandbox session.

This closes out every phase `docs/pattern-mirror-scope.md` originally scheduled (Phase 1 Mirror through Phase 6 Multi-feature seed selection) - Phase 7 (sketch-level Pattern/Mirror) and Phase 8+ (explicitly deferred items) remain open, per that doc's own phased plan.

## 2026-07-30 — On-device feedback round: Pattern-in-tree regression fix, long-press "Pattern" entry, pickingBodies "Select Feature" button, resizable-panel-reset bug fix

Same session, after PR #114 (Phase 6) and PR #115 (a sibling session's own Phase 8 scoping-doc-only PR) both merged to `main`. Four pieces of direct on-device feedback: (1) "patterns have stopped showing in the feature tree... this was working before", (2) "user should now be able to start pattern from long press a feature in the tree", (3) a UX addition - the guided "New > Pattern" flow's own `pickingBodies` ribbon should get a "Select Feature" button opening the tree, (4) a resizable tool panel's pulled-open height resets when the orbit/select-mode FAB is toggled.

**Root-caused all four directly against the current code** (no blind guessing) before touching anything:

- **(1) Pattern-in-tree regression**: `_confirmPattern()`/`_confirmMirror()` never called `_refreshFeatures()` - both rely solely on `_endRollback()`, which only refreshes the mesh and is a no-op entirely unless a B4 edit session engaged rollback (never true for a brand-new Mirror/Pattern created via the guided flow, since rollback is only ever engaged by `_onFeatureTap` when tapping an *existing* Feature row to edit it). Confirmed this is a genuinely pre-existing gap also shared by Fillet/Chamfer/CreatePlane's own confirm handlers (all mirror the same shape) - Extrude/Revolve/Sweep are the only three that already call `_refreshFeatures()` explicitly on confirm, which is why *those* three "just worked". Fixed Pattern and Mirror specifically (Fillet/Chamfer/CreatePlane share the identical latent bug but weren't reported and were out of this session's scope - Fillet/Chamfer's own copy fixed 2026-07-30 in a later entry below; CreatePlane's remains open) by adding an unconditional `await _runGuarded(_refreshFeatures);` to both confirm handlers, mirroring `_confirmSweep`'s own refresh-before-teardown shape.
- **(2) Long-press "Pattern" entry**: `FeatureContextMenuAction` gained a `pattern` case; `showFeatureContextMenu` gained a `showPattern` param rendering a "Pattern" `ListTile` (always enabled when shown - no eligibility check needed, `source_feature_ids` resolves against whatever the Feature currently produces at solve time). `_onFeatureLongPress` gates it on a new shared top-level `_bodyProducingFeatureTypes` constant (`extrude`/`revolve`/`sweep`/`import`/`mirror`/`pattern` - mirrors the backend's own `_PATTERN_MIRROR_SOURCE_FEATURE_TYPES`, factored out of the Build Tree's own `_sourceFeaturePickerPickableIds` so the two never drift apart on which types are eligible). New `_openPatternPanelFromFeature(feature)` opens `PatternPanel` directly in `configuring`, seeded via `source_feature_ids: [feature.id]` rather than a Body pick - mirrors `_openPatternPanel`'s own "skip `pickingBodies` entirely" shape.
- **(3) "Select Feature" button on the `pickingBodies` ribbon**: `PickerRibbon` gained an optional `extraActionLabel`/`onExtraAction` slot (omitted entirely when null, same "omit, don't just disable" convention `showConfirm` already uses) - Pattern's own `pickingBodies` ribbon wires it to `_startSourceFeaturePicker(_SourceFeaturePickerTarget.pattern)`, the exact same Build-Tree multi-select picker `PatternPanel.onPickSourceFeatures` already opens from `configuring`. Turned out to need surprisingly little new plumbing: `_confirmSourceFeaturePicker` already just writes into `_patternSourceFeatureIds` and then calls `_schedulePatternPreview()`, whose own existing guard (`_patternSourceBodyIds == null` during `pickingBodies`) already no-ops safely with zero changes needed there. `_confirmPatternBodySelection` (the ribbon's own checkmark) was widened to require *either* a Body tap or a Feature pick (previously Body-only), and to carry `_patternSourceFeatureIds` forward into `configuring` unchanged instead of resetting it to `[]` - `_resetPatternConfiguringState` gained an optional `sourceFeatureIds` parameter (default `[]`) shared by all three of its callers (`_confirmPatternBodySelection`, `_openPatternPanel`, and (2)'s new `_openPatternPanelFromFeature`). New `_patternHasAnyPickedSource`/`_patternPickingBodiesSummary()` helpers replace the old Body-count-only gating/tooltip-text logic.
- **(4) Resizable-panel-reset bug**: root-caused to `PartScreen`'s own body `Stack`'s `children` list containing `if (_selectionMode) Positioned.fill(...)` (the selection-mode border overlay) positioned *before* every tool panel, with no `Key` of its own. Toggling the orbit/select-mode FAB flips whether that conditional item exists at all, shifting every *unkeyed* sibling positioned after it in the list by one index - Flutter's own child-list reconciliation only matches a shifted child to its previous Element by identity when that child carries a `Key`; an unkeyed `Positioned.fill` there gets torn down and rebuilt from scratch, which is what was resetting `ResizableToolPanel`'s own `_heightFraction` State back to its default on every toggle (the Fillet/Chamfer/Mirror/Pattern/Revolve/Sweep/Extrude/CreatePlane panel each already had a stable `key:` on the panel *widget itself*, but that key lives on `MirrorPanel`/`PatternPanel`/etc., a descendant of the unkeyed `Positioned.fill` wrapper - the Stack's own reconciliation operates on its *direct* children, so a key several levels down doesn't help). Fixed by giving each of those eight `Positioned.fill` wrappers its own stable, constant `key:` (e.g. `const ValueKey('pattern-panel-slot')`) distinct from the panel's own dynamic one (which still correctly re-seeds fields when switching *which* Feature is being edited) - Flutter can now find and reuse the exact same Element regardless of where it lands in the list.

**New/widened tests**: `picker_ribbon_test.dart` gained a 2-test group for `extraActionLabel`/`onExtraAction` (omitted by default; shown and fires the callback when set). `part_screen_test.dart` gained 5 new tests: confirming a Pattern edit re-fetches the Feature list and the Pattern still shows in the tree afterward (a `featuresGetCount` call-counter added to the fake backend, since the existing fake infra has no other way to distinguish "the list happened to already be right" from "it was genuinely re-fetched"); long-pressing a body-producing Feature (an Extrude) offers Pattern and opens `PatternPanel` seeded from it directly (skipping `pickingBodies`), plus the negative case (a Sketch offers no Pattern entry); the `pickingBodies` ribbon's "Select Feature" button opens the Build Tree picker, and a confirmed pick is reflected back in the ribbon's own tooltip text without advancing past `pickingBodies`; and the resizable-panel-reset regression itself (drag `patternPanelDragHandle` taller, toggle the orbit/select-mode FAB twice, assert `patternPanelResizableArea`'s measured height is unchanged). Full creation-flow coverage for Mirror's own identical `_confirmMirror` fix wasn't added - the fake test backend still has no `POST .../mirror-features`/`.../pattern-features` handler (only `PATCH` against an already-seeded Feature), a pre-existing gap noted in the previous entry, not newly introduced here.

Verified for real, using the same local `master`-channel Flutter SDK clone as every prior client-touching entry (no backend files touched this pass, so the backend `pytest` suite wasn't re-run): `flutter analyze` clean; full client `flutter test` suite 1034/1034 (1027 prior + 7 new, 7 skipped, pre-existing GPU/Impeller-unavailable skips unrelated to this change). Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-30 — Fix regression from the previous on-device round: Pattern-from-Feature silently no-op'd, PickerRibbon overflow

Same session, after the previous entry's four fixes (PR #116) merged to `main`. New on-device feedback, with a screenshot: (1) "pattern still works with a body but trying to pattern a feature produced no new bodies, no new entry in the tree, no preview is shown. fails silently", (2) "the select ribbon with tool tip shows overflow error. move buttons to next line. match ribbon style used else where" (screenshot showed a "RIGHT OVERFLOWED BY 2.6 PIXELS" debug banner and severely wrapped tooltip text).

**Branch note**: the designated branch had already been merged to `main` via PR #116, so per the established convention it was restarted fresh from `origin/main`'s current tip (`git reset --hard origin/main` after stashing this round's own in-progress work, then popping the stash back on top) rather than stacking on already-merged history.

**Root cause of (1)**: the previous round's own `_openPatternPanelFromFeature`/pickingBodies "Select Feature" button seed a Pattern purely via `source_feature_ids`, leaving `_patternSourceBodyIds` as `[]` (empty, not `null`). Every guard added across this feature's plumbing checked `sourceBodyIds.isEmpty` alone as an unconditional bail-out, silently short-circuiting before any network call:
- `_ensurePatternFeatureExists` returned immediately, so Confirm never created or updated anything.
- `_schedulePatternPreview` returned immediately, so the debounced live-preview PATCH never even got scheduled.
- `_openPatternPanelForEdit` (and the identical pre-existing bug in `_openMirrorPanelForEdit`, sharing the same root cause though not newly introduced) returned `false` for re-opening an *already-created* Feature-only-sourced Mirror/Pattern for edit - the tree row tap did nothing at all, since the caller's fallback on `false` is just `_endRollback()`.

All four guards widened to also check `_patternSourceFeatureIds`/`feature.sourceFeatureIds` isn't empty, matching the class of fix Phase 6 already established elsewhere (`_confirmPatternBodySelection`'s own "Body tap OR Feature pick" gating).

Also audited (and fixed) a secondary bug in the same class: `_patternInstanceIndexForBodyId`/`_patternSkippedBodyIds` (the Phase 3 viewport-tap-to-skip machinery) computed the multi-source-naming dispatch via `_patternSourceBodyIds?.length ?? 1` alone, which is `0` for a Feature-only-seeded Pattern regardless of how many Bodies that source Feature actually resolves to server-side (a source Feature that is itself a Mirror/Pattern can produce 2+) - wrongly falling into the single-source naming branch. New `_patternEffectiveSourceCount()` helper counts `_patternSourceBodyIds` entries plus, for each `_patternSourceFeatureIds` entry, however many current Bodies match that Feature's own naming convention in `_bodies` (`bodyId == featureId` or `startsWith('$featureId#')`), mirroring the backend's own `body_ids_for_feature_id` without a round-trip.

**Root cause of (2)**: `PickerRibbon`'s title, divider, tooltip, the previous round's own new `extraActionLabel` button, Cancel, and Confirm all shared one `Row` - fine until `extraActionLabel` was non-null and the tooltip text had any real length, which is exactly Pattern's `pickingBodies` step's own shape now that it has a "Select Feature" button. Restructured into a `Column`: the title/divider/tooltip row (unchanged, still wraps the tooltip in an `Expanded`, matching `ResizableToolPanel._buildTitleRow`'s own convention) and a second, right-aligned button row below it (matching every panel's own `mainAxisAlignment: MainAxisAlignment.end` Cancel/Confirm row, e.g. `PatternPanel`'s). The button row itself uses `Wrap` rather than `Row` so it degrades to a second line instead of re-overflowing on the very narrowest phone widths where `extraActionLabel` plus Cancel plus Confirm still don't fit on one line together.

**New/widened tests**: `picker_ribbon_test.dart` gained a regression test pumping `PickerRibbon` at a 320-wide surface with `extraActionLabel` set and asserting zero overflow exceptions. `part_screen_test.dart` gained a test seeding a `pattern` Feature with `source_body_ids: []`/`source_feature_ids: ['feature-2']`, confirming it now opens for edit (previously silently didn't) and that its own live-preview PATCH actually fires with the expected `source_feature_ids` body (previously never sent) - the fake backend's `/mesh` handler was widened to fall through to its generic single-placeholder response when a seeded pattern Feature has empty `source_body_ids`, since it has no machinery to resolve `source_feature_ids` into real instance Body ids itself.

Verified for real, using the same local `master`-channel Flutter SDK clone as every prior client-touching entry (no backend files touched this pass, so the backend `pytest` suite wasn't re-run): `flutter analyze` clean; full client `flutter test` suite 1036/1036 (1034 prior + 2 new, 7 skipped, pre-existing GPU/Impeller-unavailable skips unrelated to this change). Not yet confirmed on a real device - no phone attached to this sandbox session.

## 2026-07-30 — Phase 7 (Sketch-level Pattern and Mirror) implemented

New session, new branch (`claude/pattern-mirror-phase-7-k8ltfv`, from latest `main`, already containing PR #116/#117's own fixes). Asked to implement Phase 7 of `docs/pattern-mirror-scope.md` (§2.9/§4): 2D, sketch-level Pattern/Mirror - lightweight, non-independent instances inside the sketcher, distinct from Phase 1-6's 3D Feature-tree Mirror/Pattern. Explicitly told Phase 7 has no "Status: scoped" marker yet (unlike Phase 8), so real design time was budgeted up front rather than assuming §2.9's write-up was implementation-ready - read `docs/pattern-mirror-scope.md` in full and every dated `docs/status.md` entry from 2026-07-23 onward first, per the task's own instruction, then read `app/sketch/models.py`, `profile.py`, `router.py`, and the client's Offset implementation (`sketch_controller.dart`'s `SketchMode.offset`, `sketch_offset_bar.dart`) end to end before writing any code, since Offset is explicitly the interaction-shape template for this phase.

**Design pass, before any code**: confirmed §2.9's "Option 2 - lightweight, non-solved instances, expanded only on read" recommendation was sound, but found and revised two real gaps in its own write-up (both documented in `docs/pattern-mirror-scope.md`'s own updated Phase 7 section, not just here) - see that section for the full reasoning on each:
1. A same-Sketch direction/mirror-line reference doesn't need §2.9's suggested full `SketchEntityRef` (that type's own cross-Sketch generality is unnecessary and a bit dangerous here) - simplified to a bare `line_id: str`.
2. v1 scope narrowed to linear Pattern only (fixed X/Y axis or an existing Line's own direction; no circular/two-direction-grid/skip-instances, no Body-edge direction source) - a deliberate, bounded first cut mirroring how the 3D `PatternFeature` itself only grew those across several later, separately-scoped phases, not a speculative full build now.

**Backend**, pure 2D math, no OCCT/py-slvs solver involvement at all (`app/sketch/models.py`):
- `SketchPatternInstance`/`SketchMirrorInstance`/`SketchPatternDirection`/`SketchFixedAxis` - new lightweight dataclasses; `Sketch` gained `pattern_instances`/`mirror_instances` dicts (both `default_factory=dict`, additive).
- `Sketch.add_pattern_instance`/`update_pattern_instance`/`delete_pattern_instance` and the Mirror-shaped siblings - validate (non-empty/Line-Circle-Arc-only `source_entity_ids`, exactly-one-of-two direction, `count >= 2`, non-zero `spacing`), construct, mutate; PATCH re-validates the fully-merged result so a partial update can never leave an instance invalid.
- `Sketch.expand_pattern_and_mirror_instances()` - the one place an instance ever becomes real (transient) geometry: returns `self` unchanged (same object) when there are nothing to expand (the overwhelmingly common case, and the guarantee that keeps every pre-Phase-7 sketch's behavior byte-for-byte unaffected), otherwise a shallow-copied `Sketch` whose `points`/`entities` additionally carry each instance's own derived Line/Circle/Arc copies - deterministic synthetic ids (`f"{instance.id}#{index}#{original_id}"`) so calling this twice against the same underlying state always agrees, never written back into `self.points`/`self.entities` so instances never become independently draggable/selectable/deletable.
- **Real bug found via testing, not anticipated by the original design**: a transformed Point landing back on its own source Point's exact position (always true for a Mirror instance's own axis-crossing Points, the fixed points of a reflection) now reuses that Point's own id instead of minting a synthetic one - without this, mirroring a half-profile drawn up to its own centerline (arguably *the* most common real-world reason to mirror a sketch at all) produced two disjoint open chains that only visually looked connected, never a genuine closed loop, since `detect_profile`'s connectivity walk is purely id-based. Also found and fixed: a mirrored Arc needs its start/end Points swapped (a reflection reverses apparent winding) to keep tracing the correct, non-reflex visual arc - the same fix `app.document.extrude.wire_for_profile`'s own `is_mirrored_basis` handling already applies for the 3D case, ported to 2D.
- `detect_profile` (`app/sketch/profile.py`) reassigns its own `sketch` parameter to `sketch.expand_pattern_and_mirror_instances()` as its first line. Since that reassignment is local to its own call frame, every downstream caller that goes on to build an OCCT wire from the result needed the identical explicit re-expansion: `app.document.extrude`/`revolve`/`sweep`'s own `detect_profile(sketch)` call sites each gained a `sketch = sketch.expand_pattern_and_mirror_instances()` line right after, before `_prism_for_profile`/`face_for_profile`/`wire_for_profile` reads `sketch.points`/`sketch.entities` (cheap and safe to call twice - a no-instance sketch returns the identical object both times). `app.document.router`'s own two `detect_profile` call sites needed no change (neither builds a wire, and `profile_refs` can only ever name a real, stored entity).
- New CRUD endpoints (`app/sketch/router.py`/`schemas.py`): `GET`/`POST`/`PATCH`/`DELETE .../pattern-instances[/{id}]` and `.../mirror-instances[/{id}]`, mirroring `create_circle`/`update_circle`/`delete_circle`'s own validate→construct/mutate→respond shape and `KeyError`→404/`ValueError`→400 translation exactly.
- `native_format.py`: `pattern_instances`/`mirror_instances` added to `sketch_to_dict`/`sketch_from_dict`'s round trip, defaulting a missing key to `[]` on import for backward compatibility with every pre-Phase-7 save.
- New `backend/tests/test_stage_o_sketch_pattern_mirror.py` (37 tests, three sections): model-level validation/math (direction resolution, translated/reflected Line/Circle/Arc copies, the shared-corner-of-a-picked-chain welding, the Point-welding fix's own dedicated regression test mirroring a half-profile into one closed hexagonal loop, a Pattern-of-a-Circle producing genuinely independent `MULTIPLE_LOOPS`, stale-reference drift tolerance, update/delete); `detect_profile` integration (unaffected-when-empty, the welded-mirror closed-loop case, a standalone mirrored Circle as its own disjoint loop, a construction direction/mirror Line never itself closing a loop); and full HTTP-endpoint round trips via `TestClient` (create/list/get/update/delete for both kinds, 400/404/422 validation).

**Client** (`client/lib/sketch/`), reusing Offset's exact interaction shape end to end:
- `SketchMode.pattern` (new enum value) + `SketchPatternMirrorOperation { pattern, mirror }` - one mode entry covers both operations via the value bar's own `SegmentedButton`, per the scope doc's own design.
- `SketchController`: `enterPatternMode`/`_handlePatternTap`/`finishPatternPick` mirror `enterOffsetMode`/`_handleOffsetTap`/`finishOffsetChain` exactly (accumulate Line/Circle/Arc picks into `selectionSet`, Finish opens the value bar); while the bar is open (non-modal, same as Offset's own), a further canvas tap on a Line sets the pattern direction or mirror line directly - no separate wizard step, dispatched on `patternMirrorOperation`. `confirmPatternMirrorPreview` commits to the backend, records the result in new `patternInstances`/`mirrorInstances` maps, and pushes a single-step undo (delete + local-map removal), mirroring `offsetLine`'s own undo shape. `patternMirrorGhosts` - a second, independent client-side implementation of the identical 2D translate/reflect math (same accepted-duplication precedent `offsetPreviewGhosts`'s own doc comment already established for this codebase's live-preview code) - covers both the live in-progress configuration *and* every already-committed instance, recomputed fresh from current `points`/`lines`/`circles`/`arcs` on every access (full associativity: dragging a source Point moves every derived ghost with it, confirmed by a dedicated test). `adoptSketch`/`_loadExistingContent` fetches existing pattern/mirror instances alongside every other entity collection, so a re-entered Sketch keeps showing them.
- New `sketch_pattern_bar.dart` (`PatternPickBar` cloned from `OffsetPickBar`, `PatternValueBar` cloned from `OffsetValueBar`, widened with the Pattern/Mirror toggle and Pattern's own Count/Spacing/X-Y-direction/reverse fields).
- `patternMirrorGhosts` wired into both `sketch_canvas.dart`'s 2D painter (`_paintPatternMirrorGhosts`, sharing `_paintOffsetPreviewGhosts`'s own Line/Circle/Arc-ghost rendering via a small extracted `_paintLineCircleArcGhosts` helper) and `sketch_screen.dart`'s embedded-3D-view ghost list - unlike Offset's own mode-exclusive ghosts, this renders unconditionally (every mode), since it also covers already-committed instances, not just a live in-progress pick.
- `sketch_speed_dial.dart`: a "Pattern" tile in the Tools flyup (reusing the existing 3D Pattern feature's own `feature_pattern.svg` icon - the closest existing glyph in this codebase's minimal-line-icon style).
- `sketch_api_client.dart`: `SketchPatternDirectionDto`/`SketchPatternInstanceDto`/`SketchMirrorInstanceDto` plus the eight new CRUD methods, matching every other sketch entity's own snake_case JSON wire shape.
- **Deliberately not built this pass**: a client UI for re-opening an already-created instance's own fields for editing (only create/delete are wired into the tool itself; the backend's own PATCH endpoints exist and are tested, ready for a follow-up panel) - matches §2.9's own explicit v1 non-goal ("an individual instance can't be independently edited... only the source or the whole pattern's own parameters").
- New `SketchController` tests (15, `sketch_controller_test.dart`): mode entry/label, pick accumulation (Line/Circle/Arc accepted, Point rejected, toggle-off), Finish with/without picks, cancel, Confirm-enablement gating, a configuring-phase Line tap setting the direction, create+undo for both Pattern and Mirror (via the fake backend's own new `/pattern-instances`/`/mirror-instances` routes), live-preview ghost math (count/spacing/axis), an incomplete configuration previewing nothing, associativity (moving a source Point moves an already-committed instance's own ghost), and re-adopting a Sketch loading its existing instances. **Also required widening `_FakeBackend`** (the shared test harness `sketch_controller_test.dart` already uses for every sketch-level test) with fake `GET`/`POST`/`PATCH`/`DELETE` routes for both new endpoint families - `adoptSketch` now fetches them unconditionally for *every* Sketch, so without this every one of the ~1000 pre-existing sketch-controller tests that call `adoptSketch` would have 404'd; caught immediately by the first full-suite run (2 failures, both exactly this), fixed before it became a real regression.

**Toolchain bootstrap**: no `pythonocc-core`/Flutter SDK preinstalled in this sandbox (same starting point every prior phase's own session hit). Installed micromamba from `github.com/mamba-org/micromamba-releases`' `latest/download` asset URL, built the `didsacad` conda-forge env from `backend/environment.yml`, ran the full backend `pytest` suite against genuine OCCT throughout. For the client, `git clone --depth 1 --branch master https://github.com/flutter/flutter.git` (matching `.github/workflows/client-verify.yml`'s own `channel: master` pin).

Verified for real: full backend `pytest` suite 1152/1152 (1115 prior + 37 new); `flutter analyze` clean on the whole client project; full client `flutter test` suite 1051/1051 (1036 prior + 15 new, 7 skipped, pre-existing GPU/Impeller-unavailable skips unrelated to this change). Not yet confirmed on a real device - no phone attached to this sandbox session.

This closes out Phase 7 of `docs/pattern-mirror-scope.md`'s own phased plan. Phase 8 (Feature pattern/mirror, Cut/Boss into a shared target) remains scoped-but-not-started; Phase 9+ remain explicitly deferred.

## 2026-07-30 — Fix the same Pattern/Mirror "doesn't show up after creation" bug in Fillet/Chamfer

Follow-up to this same day's earlier entry, which fixed `_confirmPattern`/`_confirmMirror` but explicitly left `_confirmFillet`/`_confirmChamfer` (and `_confirmCreatePlane`) carrying the identical latent bug, noted there as "weren't reported and are out of this session's scope." Not yet reported on-device, but confirmed real by direct code inspection: `_confirmFillet`/`_confirmChamfer` rely solely on `_endRollback()`, which only refreshes the mesh and is a no-op unless a B4 edit session actually engaged rollback - never true for a brand-new Fillet/Chamfer created via the guided flow (rollback is only ever engaged by `_onFeatureTap` when tapping an *existing* Feature row to edit it). Without an explicit `_refreshFeatures()` call, `_features` (what `FeatureTreePanel` renders) never picks up the just-created/edited Feature until some unrelated later action happens to refresh it.

Fixed identically to Pattern/Mirror: added an unconditional `await _runGuarded(_refreshFeatures);` (plus the `if (!mounted) return;` guard already used by `_confirmMirror`/`_confirmPattern`) to both `_confirmFillet` and `_confirmChamfer`, ahead of their existing teardown `setState`/`_endRollback()` - mirrors `_confirmSweep`'s own refresh-before-teardown shape exactly. `_confirmCreatePlane` still carries the same latent bug and remains unfixed - out of scope for this pass.

**New tests**: `part_screen_test.dart` gained two tests mirroring the existing Pattern-edit regression test's shape (using the fake backend's `featuresGetCount` counter) - one seeding and editing a `fillet` Feature, one seeding and editing a `chamfer` Feature, each confirming that tapping Confirm re-fetches the Feature list and the Feature still shows in the Build Tree afterward. The fake backend (`_FakeDocumentBackend`) gained `PATCH .../fillet-features/{id}` and `PATCH .../chamfer-features/{id}` handlers - it previously had neither, only `pattern-features`/`extrude-features`.

Environment note: no Flutter SDK available in this sandbox session (the recurring caveat noted at the top of this document) - the fix and new tests were verified by careful manual code review (matching `_confirmMirror`'s exact shape line-for-line, and tracing the new tests' event sequence against `FilletPanel`/`ChamferPanel`'s and `_openFilletPanelForEdit`/`_openChamferPanelForEdit`'s actual source) rather than a real `flutter analyze`/`flutter test` run. Flagging this explicitly rather than claiming a verification that didn't happen.

Doc note: the task that produced this fix cited `docs/pattern-mirror-scope.md` §6 as where this gap was tracked as a known carried-over item; on inspection, no such item exists there (§Phase 6 of that doc covers unrelated multi-feature-seed-selection work) - the actual note lives in this file's own entry above ("Fillet/Chamfer/CreatePlane share the identical latent bug but weren't reported and are out of this session's scope"), now updated in place rather than duplicated in `pattern-mirror-scope.md`.

## 2026-07-30 — Phase 7 (Sketch-level Pattern and Mirror) on-device feedback round: toggle bug, ribbon rework, two-direction pattern, green-fill/3D-viewport visibility fixes, select/edit/delete

New session, PR #118 (this same day's earlier Phase 7 entry) already merged to `main` per the branch's own merged-PR convention: restarted `claude/pattern-mirror-phase-7-k8ltfv` fresh from latest `main` (`git checkout -B` onto `origin/main`) rather than stacking on the merged history. A single on-device bug report against the freshly-shipped Phase 7, with a screenshot, listing seven distinct issues - broken into seven tracked tasks and fixed one at a time:

1. **Pattern/Mirror toggle lost its own configuration** (switching Pattern → Mirror → Pattern showed no preview until a field was re-edited). Root cause: `setPatternMirrorOperation` (`sketch_controller.dart`) was resetting the in-progress direction/count/spacing state on every toggle, including a toggle back to the operation already being configured. Fixed by dropping that reset call entirely - the toggle now only switches which operation the same in-progress fields apply to, matching how the 3D `PatternPanel`'s own Pattern/Mirror-adjacent toggles never discard configuration either.
2. **Ribbon rework to match the 3D Pattern tool's own UX** ("extend by pulling and scrollable"). `sketch_pattern_bar.dart`'s `PatternValueBar` was a fixed-height `Material` sheet - rebuilt on `viewport3d/resizable_tool_panel.dart`'s shared `ResizableToolPanel` (the same pull-to-resize, scrollable shell every 3D Feature panel - Extrude/Revolve/Sweep/Fillet/Chamfer/Mirror/Pattern - already uses), so the sketch-level tool finally matches its 3D sibling's own feel instead of looking like a leftover clone of Offset's much simpler bar.
3. **Two-direction pattern** ("allow pattern in two directions, check body pattern tool for UX"), the first genuinely new capability in this round, not just a bug fix:
   - Backend (`app/sketch/models.py`): `SketchPatternInstance` renamed `direction`/`count`/`spacing`/`reverse` → `direction_1`/`count_1`/`spacing_1`/`reverse_1` and gained `direction_2`/`count_2`/`spacing_2`/`reverse_2` (all optional, `count_2` defaulting to 1 - the identical "second direction is inert unless explicitly configured" shape `PatternFeature`'s own `direction_2` already uses). `_expand_pattern_instance` rewritten for row-major 2D grid expansion (`index = i * count_2 + j`, matching `PatternFeature`'s own convention exactly so it collapses to the pre-existing 1D scheme whenever `count_2 == 1`). `schemas.py`/`router.py`/`native_format.py` (with old-key-name backward-compat fallback on import) updated to match; ~11 new tests covering two-direction expansion, validation, and native-format round-trip.
   - Client: `SketchPatternInstanceView`/`SketchPatternInstanceDto` gained the matching `direction2`/`count2`/`spacing2`/`reverse2` fields; `sketch_pattern_bar.dart` gained a Direction 1/Direction 2 section pair with an active-slot toggle and an "Add a second direction" checkbox, mirroring `PatternPanel`'s own two-direction layout.
4. **The green closed-profile fill didn't include patterned/mirrored geometry**, even though an actual Extrude off the same Sketch already did (the backend's `detect_profile` pre-pass, from the original Phase 7 pass, already expands instances before wire-building - this gap was purely in two client-side rendering paths that never got the same treatment). Both `sketch_canvas.dart`'s `_addLoopBoundary` (the 2D sketcher's own painter) and `sketch_controller.dart`'s `profileLoopOutline` (the embedded-in-3D-viewport sketch editor's equivalent, feeding `PartViewport.profileFillOutlines`) resolved a Profile loop's own Point/Arc ids purely against real `controller.points`/`controller.arcs` - a loop that now legitimately references a Pattern/Mirror instance's own synthetic ids (per the backend's `SketchPatternInstance#{index}#{id}` scheme) simply failed to resolve and silently drew nothing for that loop. Both fixed identically: point lookups fall back to `SketchController.committedPatternMirrorExpansion.points` (a new getter, wired for exactly this - expands every committed instance fresh from current source geometry, associative by construction, same guarantee `patternMirrorGhosts` already had) before giving up, and an Arc-hop lookup falls back to a `PatternMirrorEntityKind.arc` entry in that expansion's own `entities` list.
5. **A patterned/mirrored entity was invisible in the Part's 3D viewport** when the Sketch wasn't actively being edited (`part_screen.dart`'s `_refreshSketchGeometries`, which fetches a Sketch's raw Point/Line/Circle/Arc/Ellipse/Spline DTOs and converts them via `sketchGeometry3DFrom` for `PartViewport`'s own rendering - a wholly separate pipeline from both the 2D painter and the embedded-editor outline fixed above, since it renders full entity geometry, not just a closed-profile's own boundary). New `expandPatternMirrorDtos` (`viewport3d/sketch_geometry_3d.dart`) - the DTO-based sibling of `SketchController.committedPatternMirrorExpansion`, sharing the identical `pattern_mirror_expansion.dart` expansion module (three independent consumers of that one shared module now: the 2D painter, the embedded-editor outline, and this) - fetches `listPatternInstances`/`listMirrorInstances` alongside the existing entity lists and merges every derived synthetic Point/Line/Circle/Arc in before the `sketchGeometry3DFrom` call; a no-op (returns the exact same list instances, no new allocation) whenever a Sketch has no Pattern/Mirror instances at all, the overwhelmingly common case.
6. **A patterned/mirrored entity wasn't selectable, and therefore not deletable**, inside the sketch editor itself, with no way to reach its own owning instance's config either. Added `_patternMirrorEntityAt`/`_patternMirrorEntityDistance` hit-testing (`sketch_controller.dart`, reusing `committedPatternMirrorExpansion`) wired into `_resolveSelectableAt`'s existing fallback chain, and two new `SelectionKind` cases (`patternInstance`/`mirrorInstance`) - selecting a derived copy selects its *whole owning instance* (never an individual copy independently, matching `SketchPatternInstance`'s already-documented v1 non-goal). `sketch_ribbon.dart`'s selection-context chip row now offers "Edit Pattern"/"Delete Pattern" (or the Mirror-labeled equivalents) for a single such selection, wired to new `startEditingPatternInstance`/`startEditingMirrorInstance` (reopens the value bar pre-filled, dispatching to an update-not-create `confirmPatternMirrorPreview` path) and `deletePatternInstanceById`/`deleteMirrorInstanceById` (deliberately not pushed through the undo stack, unlike instance creation - a documented v1 cut, matching how deleting other multi-step-created things already works in this codebase).

**Also required** (mechanical, not a design change): every one of the ~9 non-exhaustive-switch compile errors `SelectionKind`'s two new cases surfaced across `sketch_controller.dart`/`sketch_dimension_bar.dart`/`sketch_ribbon.dart`/`sketch_screen.dart` fixed individually - most as explicit "unreachable for this context" no-op cases (e.g. Dimension mode's own selection can never include a Pattern/Mirror instance), a few (like `selectionLabel`, the ribbon's own chip-row logic) with real handling. The `_FakeBackend` test harness's own pattern-instance route handlers (`sketch_controller_test.dart`, added during the original Phase 7 implementation) still used the pre-rename field names (`direction`/`count`/`spacing`/`reverse`) in their fake JSON bodies - updated to the new `_1`/`_2`-suffixed schema; caught immediately by the first full-suite run against the renamed `SketchPatternInstanceDto.fromJson`.

**New tests**: 11 new backend tests (two-direction expansion/validation/native-format, `test_stage_o_sketch_pattern_mirror.py`); 5 new client tests - `sketch_profile_loop_outline_test.dart` (the `profileLoopOutline` synthetic-id fallback) and 4 in `sketch_geometry_3d_test.dart`'s new `expandPatternMirrorDtos` group (no-op identity when empty, a derived Line/Circle copy's own coordinates, and the Mirror welding fix carried through correctly at the DTO level).

Verified for real: full backend `pytest` suite 1163/1163 (all passing, including every renamed/new Phase 7 test); `flutter analyze` clean on the whole client project; full client `flutter test` suite 1058/1058 (1051 the original Phase 7 entry's own baseline + 2 from this same day's concurrently-merged Fillet/Chamfer fix, already in `main` when this branch restarted from it, + 5 new this round, 7 skipped pre-existing GPU/Impeller-unavailable skips unrelated to this change). Not yet confirmed on a real device - no phone attached to this sandbox session, same caveat as the original Phase 7 entry.

`docs/pattern-mirror-scope.md`'s own Phase 7 section updated in place: two-direction pattern and instance edit/delete are no longer listed as deferred v1 non-goals.

## 2026-07-30 — Fix: Pattern tool's value bar silently failed to render after confirming a selection

On-device follow-up to this same day's earlier Phase 7 feedback round: "start sketch pattern tool > select entities > confirm selection > nothing happens, no toolbar appears." Reproduced by tracing the actual widget tree, not just `SketchController` state (which was correct - `patternPreviewTargets` was set fine).

Root cause: `sketch_screen.dart`'s tool-bar area was a shrink-wrapped `Positioned(left, right, bottom)` with no `top` - fine for every bar's own fixed-height `Material` shell (sized purely to its own content), but this same day's earlier round rebuilt `PatternValueBar` (`sketch_pattern_bar.dart`) onto the shared `ResizableToolPanel`, which needs a genuinely *bounded* incoming height (a `LayoutBuilder` computes its own pull-to-resize fraction against `constraints.maxHeight`, then self-aligns to the bottom). Unbounded height there throws a layout exception, which silently aborted that whole bar's build - so after Confirm, the controller's own state was already correct, but nothing at all appeared on screen.

Fixed by making that `Positioned` fill the whole body (`Positioned.fill`) and individually wrapping every *other* bar in its own `Align(alignment: Alignment.bottomCenter, ...)`, preserving their previous shrink-wrapped sizing/position exactly - only the `ResizableToolPanel`-based bar wants the full height, since it already aligns itself to the bottom internally. `IgnorePointer`/`AnimatedSlide`/`AnimatedOpacity` around the whole thing needed no change - an inactive bar's `Align`'d empty space still passes taps through to the canvas underneath (Flutter's own `Align`/`Positioned` hit-testing convention, not something this fix had to add).

**New test**: `sketch_screen_pattern_bar_test.dart` (new file) - a real widget test (mounts the actual `SketchScreen`, not just `SketchController`), since the bug was purely in layout wiring, invisible to controller-only tests. Drives the real pick -> finish -> confirm flow via `handleCanvasTap`/`finishPatternPick`, then asserts no exception was thrown and the `ResizableToolPanel`'s own keyed resizable area actually rendered. Verified this test genuinely catches the regression - it fails with the exact reported symptom (silently caught layout exceptions) against the pre-fix code, and passes with the fix.

Verified: full client `flutter test` suite 1059/1059 (1058 prior + 1 new); `flutter analyze` clean. Backend untouched, not re-run.

## 2026-07-30 — Fix sketch Pattern tool: dynamic highlight, hit-box mismatch, and count/spacing field alignment

Third on-device feedback round the same day: "patterned curves/lines are still not selectable, dynamic hilight isn't working"; "the text input lines for count and spacing are miss aligned"; "there is a miss assignment between hit box for dynamic hilight and select when picking lines/curves in the sketch pattern tool."

Diagnosed with a real diagnostic test before touching any code (kept as a permanent regression test, see below) - it confirmed a committed pattern instance's tap-select via `handleCanvasTap` already worked correctly (`selectionSet` ends up with a genuine `SelectionKind.patternInstance` entry), but `SketchController.hoveredEntity()` returned `null` at the exact same spot. Two real, distinct bugs:

1. `hoveredEntity()` never consulted `_patternMirrorEntityAt` - the fallback `_resolveSelectableAt` (the actual tap-resolution this getter is meant to preview) already has. So hovering a Pattern/Mirror instance's own derived copy in Select mode always previewed nothing, even though tapping it there genuinely selected it - the literal "mis-assignment between hit box for dynamic highlight and select" reported. Fixed by mirroring `_resolveSelectableAt`'s own fallback order and mode gate exactly (real geometry always wins; the synthetic-instance fallback only applies in Select/Dimension mode - every other tool mode's own tap handler, including Pattern's own picking phase, calls bare `_entityAt` with no such fallback, so hovering shouldn't preview one there either).
2. `sketch_canvas.dart`'s `_paintPatternMirrorGhosts` never looked at `hoveredEntity`/`selectionSet` at all - every committed instance's own derived copies always painted in the same flat ghost color, unlike every real Line/Circle/Arc's own paint loop (which already checks both). So even *with* bug 1 fixed, a hovered/selected instance still wouldn't visibly change - indistinguishable from "nothing is selectable" from the user's own point of view. Fixed: new `SketchController.patternMirrorGhostsForInstance(id)` (the existing `patternMirrorGhosts` flat list carries no id to key a highlight off - this is a second, id-scoped query specifically for this), and `_paintPatternMirrorGhosts` now redraws the hovered/selected instance's own ghosts on top in `_hoverColor`/`_selectedColor` at emphasis stroke width, the same convention every other entity kind already uses.

Third bug, unrelated to the two above: `sketch_pattern_bar.dart`'s Count/Spacing `TextField`s used different `InputDecoration` shapes - Count had a floating `labelText` (reserves space above the input, shifting its own text down), Spacing had only a `hintText` (placeholder text sitting right at the top, no reserved space) - two different field heights/text baselines side by side in the same `Row`. Fixed by matching `PatternPanel`'s (the 3D Pattern tool - "match ribbon from other pattern tool" was the very first item in the previous round's own feedback) own Count/Spacing fields exactly: both `labelText`-only, both `Expanded` rather than a fixed width, no `isDense`/`hintText`/`suffixText`.

**New tests**: two in `sketch_controller_test.dart`'s existing Phase 7 group - one confirming `hoveredEntity()` now previews a committed pattern instance in Select mode (id and kind matching what a tap there actually selects), one confirming it still previews nothing for the same spot while in `SketchMode.pattern`'s own picking phase (a synthetic copy must never look pickable as another Pattern's own source). One new widget test in `sketch_screen_pattern_bar_test.dart` - mounts the real `PatternValueBar`, finds both `TextField`s by their own visible label text, and asserts identical `getTopLeft().dy`/height; confirmed this genuinely catches the regression (fails with the exact `8.0`-pixel offset reported against the pre-fix code, passes with the fix).

Verified: full client `flutter test` suite 1062/1062 (1059 prior + 3 new); `flutter analyze` clean. Backend untouched, not re-run.

## 2026-07-30 — Add Pattern/Mirror instance selection to the embedded 3D (Orbit View) sketch editor

Follow-up to the same day's earlier fix: on-device feedback ("check the screenshot, the patterned circle under the cursor is not highlighted and will not select") came with a screenshot. Investigating the rendered colour (a light blue, not `_hoverColor`/`_selectedColor`/`_drawGhostColor`, none of which matched) traced back to `sketch_geometry_3d.dart`'s `sketchGhostLineColor` - the generic ghost colour the **embedded 3D (Orbit View) sketch editor** uses, confirming this screenshot was that view, not the flat 2D `SketchCanvas` already fixed earlier the same day. `PartViewport` is a wholly separate rendering/hit-test pipeline (GPU-based `flutter_scene`, its own ray-hit-testing against real Body/Sketch entity ids) - Pattern/Mirror instance selection had never been implemented there at all, explicitly called out as a known gap in the old `_embeddedSelectionEntityKind`'s own doc comment ("Select-mode's own picking is 2D-canvas-only for now"). Confirmed with the user this was worth building (a real, separate piece of work, not a quick fix) before starting.

**Implementation**, mirroring the existing `sketchLine`/`sketchCircle`/etc. architecture in `viewport3d` exactly, end to end:
- `selection_hit_test.dart`: new `SelectionEntityKind.sketchPatternMirrorInstance`; new `hitTestSketchPatternMirrorInstances` - unlike every other `hitTestSketchXxx` function, takes pre-flattened individual segments (not one polyline per entity), since several segments - even across several different derived copies of a 2-direction pattern - legitimately share one *owning instance* id, the same "resolves to the whole owning instance, never an individual copy" contract `SketchController._patternMirrorEntityAt` already has on the 2D-canvas side. Wired into `hitTestBodies` via a new `patternMirrorGhostSegments`/`patternMirrorSketchFeatureId` parameter pair, at the same priority tier as real Sketch Lines/Circles/Arcs.
- `selection_filter.dart`: new `SelectionFilterState.sketchPatternMirrorInstance` field - defaults `false`, unlike every sibling `sketchXxx` field (which default `true`): a synthetic copy is only ever a valid pick target in Select mode, mirroring `_patternMirrorEntityAt`'s own mode gate.
- `part_viewport.dart`: new `patternMirrorGhostSegments`/`patternMirrorSketchFeatureId` props threaded into both `hitTestBodies` call sites that matter (`_recomputeHover`, `_hasEntityNearScreenPoint`) and a `didUpdateWidget` resync branch; `_buildEntityHighlightNode`/`_syncSelectedEntityNodes` gained a case resolving the owning instance id back into its own segments for hover/selected-colour highlighting, same as every existing `sketchXxx` case.
- `sketch_screen.dart`: new `_embeddedPatternMirrorGhostSegments` getter, built from `SketchController.patternMirrorGhostsForInstance` (an id-scoped query added specifically for this and the earlier flat-2D-canvas fix) - tessellated via the same `ghostPolylines`/`sketchPointToWorld` calls `_embeddedDrawGhostPolylines` already uses for plain rendering, so hit-testing always matches what's actually drawn, then split into individual segments (mirrors `part_viewport.dart`'s own private `_polygonSegments`, duplicated locally rather than exposed across the package boundary for one small helper). `_handleEmbeddedSelectionToggle` special-cased (its target `SelectionKind` isn't a pure per-kind mapping here - resolved by checking which of `patternInstances`/`mirrorInstances` contains the id instead); `_embeddedSelectionEntityKind`'s reverse mapping updated to match (both `SelectionKind.patternInstance`/`.mirrorInstance` now map to the one shared `sketchPatternMirrorInstance` kind, since that side only needs the id back); `_embeddedCursorModeFilter` gated to Select mode only.
- `selection_list_drawer.dart`: icon/label cases for the new kind (reuses the 3D Pattern feature's own glyph; label is a generic "Pattern/Mirror" since this drawer only ever sees a bare `SelectionEntityKind`, with no way to tell Pattern from Mirror apart the way `sketch_ribbon.dart`'s own 2D-canvas equivalent can via the richer `SelectionKind`).

**New tests**: `selection_hit_test_test.dart` gained a `hitTestSketchPatternMirrorInstances` group (in-range/out-of-range/several-segments-one-id) plus a `hitTestBodies` integration group proving the mode gate genuinely works (a ghost segment is hit when the filter flag is on, never hit with `SelectionFilterState.defaults`, where it's off); `selection_filter_test.dart` gained default/copyWith/equality coverage for the new field. A new widget test file (`sketch_screen_pattern_mirror_3d_selection_test.dart`) mounts the real `SketchScreen` in Orbit View end to end, creates a committed pattern instance, and drives `PartViewport.onSelectionToggle` directly with the same `SelectionEntityRef` shape a real ray-hit would produce (the ray-hit math itself is already covered separately and more thoroughly by the pure `selection_hit_test_test.dart` tests) - confirmed it fails to even *compile* against the pre-fix code (missing fields/enum value) and passes with the fix.

Verified: full client `flutter test` suite 1070/1070 (1062 prior + 8 new); `flutter analyze` clean. Backend untouched, not re-run.

## 2026-07-30 — Session close-out: on-device confirmation, roadmap/scope-doc updates

The user confirmed the fourth follow-up round's embedded-3D Pattern/Mirror selection fix (PR #123) works on their own real Android device - the first real-device confirmation for any of this day's Phase 7 work; every prior round was verified sandbox-only (tests + `flutter analyze`, no physical device available in-session). More comprehensive on-device testing planned for later, not done in this session.

Two doc updates requested to close out the session, both docs-only (no code changes):

- **`docs/roadmap.md`**: new "Other open items" entry - sketch-level Pattern/Mirror ended up with the identical translate/reflect/welding math implemented three separate times (the backend's `expand_pattern_and_mirror_instances`, the 2D canvas's `pattern_mirror_expansion.dart`, and the embedded-3D view's `hitTestSketchPatternMirrorInstances`/`_embeddedPatternMirrorGhostSegments`) - each a deliberate instance of this codebase's existing "accepted duplication" convention for live-preview math, but three copies is more than that convention originally anticipated. Flagged for a later investigation into whether the two *client-side* copies could share one implementation - not attempted now, nothing currently enforces the three stay in sync if the math changes again.
- **`docs/pattern-mirror-scope.md`**: Phase 7's own section reorganized - the "Explicit v1 non-goals" bullet split into a permanent-by-design item (an individual derived copy can never be independently edited, only its whole owning instance) and a new, clearly-labeled "Deliberately out of scope for v1" list (circular sketch patterns, skip-instances, a Body edge as a direction/mirror-line source, plus a pointer to the roadmap's new duplication-investigation entry) - this information already existed in prose form from earlier rounds, just not as a single clear callout. The section's own Status line and per-round summaries were also brought up to date to cover all four on-device-feedback follow-up rounds (previously only the first was described) and to record the real-device confirmation above.

Session closed with a ready-to-use kickoff prompt for Phase 8 (Feature pattern/mirror - Cut/Boss into a shared target, already scoped 2026-07-29 per §2.11, not started) handed to the user for their next session.
