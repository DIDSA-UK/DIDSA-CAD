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
