# Assembly crash, AI-plan mates and phone UI tidy-up: plan

Source: the owner's report and requests of 2026-11-08 (Flutter client and backend). This plan is for the implementation session.
Code pointers were checked against `main` at `f9ffd1a`. Line numbers drift, so search for the named symbol if a line is off.
Nothing here has been built yet. **Decisions** at the end each have a recommended answer. Where the owner has already
answered, it says **Owner**. For the rest, ask the owner first, or build the recommended answer and say that you did.

The owner's test case: a 6 m, 25 t platform (two identical welded tower modules and a deck with guardrails) made with AI
Modelling from an external-AI zip. Its saved files and the zip's plans are in `tools/ai_eval/fixtures/plt-platform-6m-25t/`
(the `.didsa` files the app saved; `plan/` = the zip's plans, unzipped). `tools/ai_eval/replay_bundle_mates.py` replays any of
its mate plans against the backend in process (usage in the script's docstring).

| Item | Summary | Kind | Size |
|---|---|---|---|
| A1 | Draw each body's edges as one batched `LineSegmentsGeometry` instead of one `PolylineGeometry` per segment | Crash fix | Medium (client) |
| A2 | Build edge geometry once per Part body, share it across instances, and stop rebuilding edges when the camera moves | Crash fix | Medium (client) |
| A3 | Optional safety valve: a toggle and a slider (in Controls settings) that hide edges while the view moves on models above N edge segments | Feature | Small (client) |
| B1 | Near-redundant mates: accept a solve that misses only by a tiny, bounded amount, and show those mates **yellow** in the tree | Feature + bug | Medium (backend + client) |
| B2 | An AI plan's mates are not all-or-nothing: build every valid mate, never store a mate whose solve fails, report the rest | Bug | Small-medium (client) |
| B3 | `face_selector` without `body_id` on a multi-body component: choose the body by the nearest match instead of refusing | Bug | Small (backend) |
| B4 | A Boss whose target body was split into pieces (`<id>#0`, `<id>#1`) still joins those pieces instead of starting a new body | Bug | Small-medium (backend) |
| B5 | Small fixes: a wrong error message; tell the user when the backend is too old for a plan; AI prompt rules | Polish | Small |
| C1 | Edit Alone's "Editing ... / Done" pill moves into the tree, under its header | UI | Small (client) |
| C2 | Visibility panel: a row of Shaded / Shaded + Edges / Wireframe buttons between Show and View; drop the View row's fold chevron | UI | Small (client) |
| C3 | Hamburger View section: drop the long subtitles; the Override appearance switch moves onto its header line | UI | Small (client) |

## Progress

| Item | State | Notes |
|---|---|---|
| A1 | Done (client) | `LineSegmentsGeometry` per body (`buildBatchedEdgesGeometry`); width and depth offset set per frame in `_updateBatchedEdges`. Pure logic in `viewport3d/edge_batching.dart`, tests `edge_batching_test.dart`. GPU result not testable here. |
| A2 | Done (client) | `EdgeBatchCache` (`edge_batching.dart`): geometry built once per `(part, body, mesh)`, shared by all instances (node transform differs); per instance and per section only while a section is on. Camera moves rebuild no edges (`_resyncCameraDependentOverlays` keeps only the section-gizmo rescale; the turntable rebuilds nothing). Width in perspective is set per node from its own centre distance, but a geometry shared by several nodes has one width (the last node's), see status. |
| A3 | Done (client) | Controls > Performance: switch "Hide edges while moving on large models" (default off) and slider "Edge limit" (5k to 200k, default 50k, disabled while the switch is off), "This model: N" under it. `shouldHideEdges` is the gate; the viewport marks the view as moving on orbit / pan / zoom / pinch / animation / turntable steps and for 160 ms after, and sets edge nodes `visible = false` while over the limit. Tests in `controls_settings_test.dart` and `edge_batching_test.dart`. |
| B1 | Done (backend + client) | `app/document/mate_tolerance.py`: after the strict solve fails, the least-squares result is accepted only if every mate is within 0.01 mm (linear) and its angle moves the far end (angle x the larger bounding radius) by at most 0.01 mm and is at most 1e-4 rad, all measured in physical units from per-row kinds (`row_kinds`), not by thresholding solver rows. Couplers and held limits are never accepted this way. Status `ok`/`near`/`broken` computed per listing (`mate_status.py`), `status_residual_mm` (far-end mm) and `status_residual_deg` on `MateResponse`, `X-Mate-Tolerance: near` (+ `X-Mate-Residual-Mm/Deg`) on create / edit / `/solve`. Client: amber tile (`AiPalette.warning`), subtitle "Within tolerance: 0.006 mm / 0.0002°", tooltip, amber over-constrained badge when its mates are all near, AI note "N within tolerance (largest X mm)". Replay of `90_PLT_MODULE.json`: 93 built, 0 failures; the four braces' two conflicting mates each are `near` = 8 near mates (not 4), 0.004 mm / 0.0001° each. Tests: `test_mate_tolerance.py`, `assembly_tree_panel_test.dart`, `ai_validation_feedback_test.dart`. |
| B2 | Done (client) | `PlanTranslator.execute(bestEffortMates: true)`, used by `_executeMatesPlan` (imported zips, the in-app mates turn, the follow-up turn): mates refused by the dry run are skipped, every other mate is created atomically (`solve=auto`, driving the second reference's occurrence, the other side if that one is grounded), a mate whose solve fails is never stored and later mates still build. New outcome `completedWithFailures` with `failures` (local id, stage, reason); the note says "Built X of N mates; K could not be built" and lists each. When no mate passes validation it is still `validationFailed` (the in-app turn's provider retry). Tests: `ai_mates_best_effort_test.dart`. The in-app turn no longer retries when only some mates fail validation (it builds the valid ones and reports). |
| B3 | Done (backend) | A `face_selector` with no `body_id` on a component of several Bodies resolves on every Body and takes the one with the face nearest `near` (`_resolve_mate_face_selector_across_bodies`); refused with 422 (Bodies listed) when there is no `near`, no Body matches, or two tie within 1e-6 of the part size. Replay of `91_PLT_DECK.json`: 72/72 validate (was 60/72). Tests in `test_ai_plan_mate_face_selector.py`. |
| B4 | Done (backend) | `_apply_boss_or_cut` treats a Boss target id that no longer exists as also naming its split pieces (`<id>#n`), fuses into all of them, and registers the result under the NAMED id, so re-joined pieces get back the id they had before the split (ids do not grow a suffix per fuse; an id that exists, or one naming nothing, behaves as before). Cut targets are NOT changed (a Cut on a split id still skips it, as before). Replay: `PLT_RAIL_A_001` 17 bodies to 1, `PLT_RAIL_B_001` 7 to 1. Tests: `test_boss_split_target.py`. |
| B5 | Done (backend + client) | (1) `_resolve_occurrence_target_part` names the failed selector (`face_selector` / `edge_selector`). (2) `GET /health` has `api_features` (`ai_plan.face_selector.normal`, `ai_plan.mate_paths`, `ai_plan.face_selector.nearest_body`, `mate.status_near`, `boss.split_targets`); `DocumentApiClient.apiFeatures()`; `_executeMatesPlan` checks what the plan uses (`ai_plan_features.dart`: a `normal` selector, an `outer/inner` path) and, when the backend answers without them, builds nothing and says "The backend is older than this app: update it to build these mates"; a failed `/health` call blocks nothing. (3) Prompt rules in `ai_scoping_prompt.dart`: overlap joined features by at least 0.1 mm, exact angled values, do not fix the same rotation twice (in-app vocabulary and external hand-off guidance), `body_id` optional with `near`. No `tools/ai_eval` case added: its harness needs model runs, which cannot be done here. |
| C1 | Not started | |
| C2 | Not started | |
| C3 | Not started | |

Suggested order: **A1 → A2 → A3**, then **B2 → B3 → B4 → B1 → B5**, then **C1-C3** (independent, any order). A is the crash
and comes first. In B, B2 makes a plan's good mates survive its bad ones, so it goes before the rest.

DIDSA-VR: none of A or C touches it. VR reads mate `status` and treats anything but `"broken"` as fine
(`scripts/mates_tool.gd`), so B1's new `"near"` status is safe there; showing it yellow in VR is a follow-up (not in this plan).

---

## Part A: the crash when orbiting fast or zooming in

**Confirmed by the owner:** with edges turned off (View: Shaded) the platform orbits and zooms smoothly and does not crash.
With the default Shaded + Edges it crashes on both backends (the camera never calls the backend).

**Cause.** `buildMeshEdgesNode` (`client/lib/viewport3d/mesh_geometry.dart`) makes **one `MeshPrimitive` with its own
`PolylineGeometry` per edge segment**. The platform's assembly mesh has 133 bodies and 6,628 triangles but **11,918 edge
segments** (measured from `GET .../assembly-mesh` on the fixture). In flutter_scene 0.24.3:

- A `PolylineGeometry` is `GeometryStorage.updatable`: 6 vertex streams x a 4-deep ring + an index buffer = **25 GPU device
  buffers per segment, about 298,000 for this model**, plus one draw call per segment.
- Every frame, `_ScenePainter.paint` (`part_viewport.dart`) calls `updateForCamera` on every one of them (a `Matrix4.inverted`,
  fresh lists, two `Float32List` copies and two buffer uploads each): **6.5 ms per frame on a desktop CPU** for the CPU part
  alone (benchmark of `expandPolyline` x 11,918), several times that on a phone, plus about 24,000 uploads per frame.
- `_resyncCameraDependentOverlays` throws every edge node away and builds them again (another ~298,000 buffers) at **every
  gesture end**: each pointer up, each scroll-wheel tick (`_onPointerSignal`), each pinch end, the end of every view
  animation, and **every 16 ms while the turntable runs** (`setTurntable`). The old buffers go only when Dart's GC finalises
  them. Repeated fast swipes or pinches stack these up until memory runs out or the UI thread stalls.

The reason it rebuilds is the towards-camera depth bias (`biasSegmentsTowardCamera`, used in Shaded + Edges): the bias moves
every point towards the camera, so it is baked per camera position.

### A1. One batched edge geometry per body

flutter_scene 0.24.3 has `LineSegmentsGeometry` (`lib/src/geometry/line_segments_geometry.dart`): disconnected segments,
expanded into camera-facing quads **in the vertex shader**, drawn in **one instanced call**, from one static buffer. Its input,
`LineSegmentData(positions: Float32List)` (six floats per segment), is exactly the backend's `mesh.edges` layout, so no
conversion is needed. Its `width` is in world units and can be set every frame (no rebuild).

- Replace `buildMeshEdgesNode`'s per-segment primitives with one `LineSegmentsGeometry` per body. Keep the material
  (`NormalDepthUnlitMaterial`, opaque, double-sided, the mode's edge colour).
- Pixel width: set `width` each frame to `kEdgeStrokeWidth` x world-units-per-pixel. Orthographic: exactly
  `2 * halfHeight / viewportHeight`. Perspective: `2 * d * tan(fovY / 2) / viewportHeight`, with `d` the camera's distance to
  the node's bounding-sphere centre (edges nearer the camera than that come out slightly thicker; accept, or see Decision A-b).
  Only set it when it changes by more than ~1 % (the setter rescans the endpoints for bounds).
- Use it for the root Part's own edges (`_syncEdgesNode`) and for placed instances (`_syncAssemblyInstanceEdgesNode`).
  Leave sketch geometry, gizmos and highlights on `PolylineGeometry`: they need joins, caps or dashes and are small.
- Take the batched nodes out of the `polylineCarryingNodes` list in `build` (nothing to update per frame).
- Width check: the shader's quad must still read as the old 1.5 px line on a phone (compare against a screenshot from `main`).

### A2. Build once per Part body, never on camera moves

- Cache edge geometry by `(partId, bodyId, mesh identity)`: an instance node reuses the Part body's geometry with its own
  `localTransform` (`matrix4FromRigidTransform(instance.worldTransform)`), so the platform's 20 foot pads share one geometry.
  Clear the cache when `assemblyGeometry` changes (a mesh resync), not per instance.
- Section planes: `clipSegmentsByPlanes` makes the segments instance-specific. While a section is on, build per instance (as
  now), keyed by the section planes too; rebuild only when the section changes.
- **Depth bias without rebuilding:** stop baking `biasSegmentsTowardCamera` into the points. Per frame, offset each edge node
  by `kEdgeDepthBias` along the unit vector from the target towards the camera (one matrix per node per frame, ~130 for this
  model). If the owner sees edges fighting the faces on a device, fall back to Decision A-c.
- `_resyncCameraDependentOverlays` stops calling `_syncEdgesNode` / `_syncAssemblyInstanceEdgesNode`; it keeps the section
  gizmo rescale. Grep every caller of those two (`_endMarquee`, selection end, `setTurntable`'s timer, the view animations,
  the scroll handler) and drop the camera-only ones. Mesh, instance, render-mode, focus, solo, hide and section changes still
  rebuild.
- The turntable then rebuilds nothing per tick (it sets the camera and repaints).

### A3. Optional safety valve: hide edges while moving on big models (Owner: optional, toggle + slider)

The owner asked for this as an option, because the right limit differs between devices.

- Controls settings (`controls_settings_screen.dart`, opened from the View menu's Controls): a new **Performance** section
  with a switch **"Hide edges while moving on large models"** and a slider **"Edge limit"** (segments; log steps, e.g. 5k,
  10k, 20k, 50k, 100k, 200k). Show the current model's count under it ("This model: 11,918").
- Persist both like the other preferences (`ControlsPreferences` / `shared_preferences`; defaults in Decision A-a).
- Behaviour: when on and the visible edge segment count exceeds the limit, set the edge nodes' `visible = false` from
  pointer down / animation start to gesture end / animation end. No geometry is rebuilt (A2), so showing them again is free.

### Tests for A

GPU-bound code cannot run in `flutter test` here (the viewport tests skip without a GPU), so split the logic out and test that:
- a pure function for world-units-per-pixel (both projections);
- the edge cache: one build per Part body however many instances, no rebuild on a camera-only change, a rebuild on a mesh /
  section / render-mode change (count builds through an injectable builder);
- A3's gate (count vs limit, on / off) and the settings round trip;
- a regression test on the fixture's numbers: build the edge data for 133 bodies / 11,918 segments and assert the node and
  geometry count is per body, not per segment.

Owner check on a device (cannot be done here): orbit fast, pinch-zoom hard and run the turntable on the platform in Shaded +
Edges. Lines must look as they do on `main` (width, no flicker through faces).

---

## Part B: the AI plan's mates

Every file the owner's run saved has **zero mates**. Replaying the zip's three mate plans against the current backend with
`replay_bundle_mates.py`:

| Plan | Result on current `main` | Why |
|---|---|---|
| `90_PLT_MODULE.json` (93) | 93/93 validate; **89 build, 4 do not solve**: m27, m51, m75, m93 (each face's brace "190 lap" distance) | The AI rounded the gusset sketch to 3 decimals: its edges are at 41.3498 / 41.3500 / 41.3502 deg, the brace is placed at 41.3499 deg. The brace's m26 (distance to one gusset edge) and m27 (distance to the perpendicular edge) both force parallel faces, so the brace's rotation is fixed twice, about 3.5e-6 rad apart, and the solve reports "No placement satisfies these mates together". Without m26, m27 solves. |
| `91_PLT_DECK.json` (72) | **12 of 72 fail validation**, so none are built (the plan is all-or-nothing) | The guardrail parts came out as **17 and 7 bodies**, not one, and the selectors have no `body_id` ("face_selector needs body_id: that component has 17 Bodies"). See B3 and B4. |
| `99_assembly.json` (6) | 6/6 build | — (paths like `upper/bp0` work since 2026-11-04) |

On current `main` the module would have saved its first 26 mates (the translator stops at m27 and does not undo), and the top
level all 6. The owner's files have none, so **the owner's backends (laptop and Termux) are probably older than 2026-11-04**,
when `face_selector.normal` (`10d992c`) and mate paths into sub-assemblies (`3bef414`) landed. The owner should update both
before re-testing. B5 makes the app say so.

### B1. Near-redundant mates: solve within a bounded tolerance, flag them yellow (Owner: yes, yellow in the tree)

**Accuracy rule (this is engineering): nothing is loosened silently, and a dimension that is wrong still fails.**

- The strict solve is unchanged and always tried first (`_SOLVE_TOL` 1e-7, converged at `_NOISE_TOL` 1e-6 in
  `backend/app/document/assembly_group.py`).
- Only when it does not converge, take the least-squares result it reached and measure **each mate's residual in physical
  units**: a distance in mm and an angle in radians. **Do not compare the solver's internal weighted rows to a threshold**;
  convert first (read `_mate_residual_vector` and `_metric` to see what the rows are).
- Accept that result, with the over-tolerance mates marked **near**, only if every mate's residual is within **both**:
  - linear: **0.01 mm** (Decision B-a), and
  - angular: the angle times the **larger of the two parts' bounding radii** is within the same 0.01 mm, and never more than
    1e-4 rad in absolute terms.

  An angular limit on its own is not safe: 1e-4 rad is 0.6 mm across 6 m. Bounding the displacement at the part's far end
  keeps it at 0.01 mm everywhere on the part. The owner's case is 3.5e-6 rad x ~1.8 m = **about 0.006 mm**, so it passes.
  A brace entered at 191 instead of 190 (1 mm out) still fails.
- Never change a stored mate value, a part's geometry or a sketch. The poses stored are the least-squares compromise, which is
  inside the tolerance by construction.
- The mate's status is computed on every listing, never stored, like `broken`. `MateStatus` in
  `backend/app/document/mate_status.py` becomes `"ok" | "near" | "broken"`: `ok` up to `_NOISE_TOL`, `near` above that up to
  the B1 limits, `broken` beyond. Add `status_residual_mm` and `status_residual_deg` to the mate response (null when `ok`).
  The group solve, the atomic `create_mate(solve=...)` and `/occurrences/{id}/solve` all accept a "near" result and say so
  (a response header or field, e.g. `X-Mate-Tolerance: near`).
- Client (`assembly_tree_panel.dart`, `_buildMateTile`): a `near` mate gets an amber warning icon and title (a theme token,
  not a hard-coded colour: add one if `didsa` theming has none), subtitle "Within tolerance: 0.006 mm / 0.0002°". The tooltip
  says what that means: "These mates over-define the part and disagree by this much. Remove one, or make the geometry
  exact." The occurrence's constraint badge (`_buildConstraintBadge`) stays as computed, but an over-constrained part whose
  conflicts are all near mates shows the amber icon, not the red one. `MateDto` gets `isNear`.
- The AI import summary counts them: "93 mates built, 4 within tolerance (largest 0.006 mm)".
- Tests: the brace case from the fixture (module plan: m27 builds, status `near`, residual reported); the same mate with
  value 191 fails; an angle mismatch over a long part that would pass 1e-4 rad but exceeds 0.01 mm at its end fails; an
  exact model stays `ok` everywhere; `mate_statuses` listing; client tile rendering and parsing.

### B2. A plan's mates are not all-or-nothing

Today `_executeMatesPlan` (`client/lib/ai/ai_modelling_screen.dart`) validates the whole mates plan and builds nothing if one
fails validation, and `PlanTranslator` (`ai_plan_translator.dart`, `case AiMateStep()`) stops at the first solve failure and
leaves that failed mate stored, which then blocks every later solve in the same group (m28 to m32 in the module all failed
after m27).

- Validate, then build every mate that validated, in plan order; report the ones that did not, with their errors.
- Create each mate with the atomic create (`POST .../mates?solve=auto&occurrence_id=...`, already used for Width mates): a
  mate whose solve does not converge is then never stored. Record it as failed and carry on.
- The note and transcript list built / near / failed counts and each failure's local id and reason.
- Imported zips, the in-app mates turn and the follow-up turn all go through `_executeMatesPlan`, so all get this.
- Tests: a plan with one invalid mate builds the others; a non-converging mate is not stored and later mates still build.

### B3. `face_selector` without `body_id` on a multi-body component

`_resolve_mate_face_selector` (`backend/app/document/ai_plan.py`) refuses when the component has more than one body. Instead,
resolve the selector on every body and take the single nearest candidate to `near`; refuse (422, listing the bodies) only
when there is no `near` or two bodies tie within 1e-6 of the part size. This is deterministic and exact (it picks a real face,
it does not approximate one). The deck's 12 rail mates then validate even if B4 is not fixed.

### B4. A Boss whose target body has been split

`_apply_boss_or_cut` (`backend/app/document/extrude.py`, the "none of its target_body_ids currently exist" warning): when a
fuse leaves disconnected solids, `_register_solids` stores them as `<id>#0`, `<id>#1`; a later Boss with
`target_body_ids: ["<id>"]` then finds no body and starts a new one, so every later rail tube in `PLT_RAIL_A` became its own
body (17). Treat a target id as also naming its split pieces (`<id>#n`) and fuse into all of them, which also re-joins the
pieces once the new solid bridges them. Check `docs/reference-identity-design.md` for how body ids are expected to evolve
first, and keep old files' body ids stable. Likely trigger here: the handrail tube is exactly tangent to the post tops
(post ends at 1075.85, tube radius 24.15, rail centre at 1100), so the fuse touches along a line only. Tests: two boxes that
only touch, then a Boss targeting the first that bridges both, gives one body; the fixture's `11_PLT_RAIL_A.json` gives one
body (or say why not).

### B5. Small fixes

- `_resolve_occurrence_target_part`'s error says `edge_selector` when a `face_selector` failed; name the field that failed.
- **Backend too old:** add `api_features` to `GET /health` (e.g. `["ai_plan.face_selector.normal", "ai_plan.mate_paths"]`).
  Before running an imported zip, the AI screen checks that the backend has what the plan uses and, if not, says "The backend
  is older than this app: update it to build these mates" instead of failing each mate.
- AI prompt (`client/lib/ai/ai_scoping_prompt.dart`, the mates and part rules): (1) do not fix the same rotation twice (two
  distance or coincident mates whose faces are both forced parallel); prefer one face pair plus a point or edge distance;
  (2) joined features must overlap by at least 0.1 mm, never just touch; (3) write angled geometry from exact values (give
  the angle and lengths, not rounded coordinates). Add `tools/ai_eval` cases if that harness has a slot for them.

---

## Part C: phone UI tidy-up

### C1. Edit Alone pill into the tree

`_buildEditAlonePill` (`part_screen.dart`) sits at the top centre (`Positioned(top: 8, left: 56, right: 56)` with the View
override chip) and covers the tree on a phone. Move it into the tree as a row **directly under the tree's header row**
(`_buildParentPartRow` in `assembly_tree_panel.dart`; and the Part lens's feature tree if Edit Alone can show that one):
"Editing **<label>**" with the Done button at the right, the same `edit-alone-pill` / `edit-alone-done` keys. The View
override chip stays where it is. When no tree is open, see Decision C-a.

### C2. Visibility panel: render-mode buttons, no fold chevron

`VisibilityPanel` (`visibility_panel.dart`), opened from the quick column's Visibility button:
- A new row between **Show** and **View**: three buttons, Shaded, Shaded + Edges, Wireframe (each `ViewportRenderMode`'s
  `svgAsset` and `label`), the current one shown selected, keys `vis-mode-<mode.name>`. New params `renderMode` and
  `onRenderModeChanged`, wired in `part_screen.dart` to the same handler the View menu uses. Row label: Decision C-b.
- Remove the View row's fold chevron (`vis-fold-views`) and the `viewsFolded` / `onViewsFoldedChanged` params, and
  `_visibilityViewsFolded` in `part_screen.dart`. Keep the 24 dp leading space so the rows line up.

### C3. Hamburger View section

The owner's screenshot (phone, the View section of the hamburger menu, `part_toolbar.dart`):
- Remove the subtitles under **Override appearance**, **Body Colour** and **Body Transparency** ("Off: showing the model's own
  colours", "Overriding: ..."). `kViewOverrideOffText` / `viewOverrideColourSubtitle` / `viewOverrideOpacitySubtitle` go if
  nothing else uses them (grep: the ribbon and phone Start menu may; drop them there too for consistency, or ask).
- "Override appearance" appears twice (a bold header and the switch's title) and the switch's title wraps mid-word
  ("appearanc / e"). Make the **header line itself the switch**: "Override appearance" on the left, the `Switch` at the right
  (key `view-override-switch`), and delete the separate `SwitchListTile`. The header text must not wrap at the menu's phone
  width (`maxLines: 1`).
- Shorten the ribbon tooltip in `part_screen.dart` ("Override appearance: one colour and transparency over everything (display
  only)") to "Override appearance".
- Update `part_toolbar_test.dart` / `part_screen_test.dart` for the removed subtitles and the moved switch.

---

## Decisions

- **A-a** A3's defaults. Recommended: **off**, limit **50,000** segments (A1 and A2 should fix the crash on their own; this is
  the owner's safety valve).
- **A-b** Perspective edge width is exact at one depth only. Recommended: use the node's bounding-sphere centre, per node.
  (Alternative: a custom vertex shader for true pixel width; more work, not needed unless it looks wrong.)
- **A-c** If the per-node towards-camera offset lets edges fight the faces: recommended fallback is a depth-bias material (a
  small `NormalDepthUnlitMaterial` subclass that offsets clip-space z); last resort is the old CPU bias, but rebuilt at most
  once per gesture end and only when the camera moved more than a threshold.
- **B-a** B1's tolerance. Recommended **0.01 mm** at the part's far end (linear, and angular x radius), capped at 1e-4 rad.
  The owner suggested 1e-4 rad; on its own that allows 0.6 mm across 6 m, hence the displacement bound. Confirm with the
  owner before building.
- **C-a** Edit Alone with no tree open. Recommended: show the current pill only while no tree panel is open (nothing to cover
  then); the moment a tree opens it moves into the tree.
- **C-b** The Visibility panel's new row label. Recommended **"Style"** (the other rows are "Show" and "View").

## What was verified and what was not (2026-11-08 investigation)

- **Ran here:** the three mate plans against the backend (conda env, OCCT 8.0.1.2) with `replay_bundle_mates.py`; the
  edge-segment counts from `GET .../assembly-mesh`; a `flutter test` benchmark of `expandPolyline` (Flutter 3.47.9).
- **Owner confirmed on a device:** no crash and smooth with edges off.
- **Not verified:** GPU memory and time on a device (the buffer counts are from flutter_scene's source); the exact message the
  owner's run showed for the mates; the owner's backend versions; which feature split the rail body.
