# Bug report 2026-11-17 — investigation, fixes made, and plan for the rest

Source: tester report (flat Flutter client, Android phone with an external monitor in desktop mode, plus an external touch
screen), with two files: `Component 2.didsa` (an L-shaped revolve profile) and `FLANGE_DN50_PN100_001.didsa` (weld-neck
flange, profile sketch with a 23.59° angle dimension).

Written for a **follow-up implementation session**. Code pointers are checked against `main` at `ca6b667`. Line numbers drift,
so search for the named symbol if a line is off. The VR client (DIDSA-VR) was checked for every item. Only item 1 touches it,
through the shared backend. It needs no VR change.

## Already fixed on branch `ccr-452ef966-vye7bw`

| # | Item | Root cause | Fix |
|---|---|---|---|
| 1 | Component 2 sketch shows green (fully constrained) when it is not | A `line_distance` adds a companion `parallel`; between two lines already Vertical it is one **redundant** equation. py-slvs then returns a non-zero result, `_residual_verified_convergence` correctly accepts the solve, but `system.Dof` from a rank-deficient solve read **0** (true DOF 3). Deleting the dimension deleted the companion parallel with it, which is why re-adding "fixed" it. The flange profile sketch had the same false 0. | `backend/app/sketch/solver.py` `_has_free_motion`: on the redundant-but-converged path, when `Dof` reads 0, nudge every unpinned point and re-solve a scratch copy; if anything settles elsewhere, report `dof = 1` (at least one; the exact count is not known there). The sketcher only uses zero / non-zero. `tests/test_dof_with_redundant_constraints.py`. |
| 3 | Polygon Resolution not applied to child occurrences | `_refreshAssemblyMesh` called `getAssemblyMesh(part.id)` without `meshQuality`, and the slider only re-fetched the focused Part's mesh. | `part_screen.dart`: pass `_meshQuality`, re-fetch the assembly mesh on slider change and on returning from settings. VR already sends `quality` on every fetch. |
| 5 | Desktop: dimension labels too small on a big screen | `_dimensionFontSize = 9.5` fixed. | `sketch_constraint_overlay.dart`: label size × system text scale × 1.5 in the desktop layout (`_desktopLabelScale`). |
| 6 | Desktop: dimension lines draw over the top ribbon | In desktop mode the viewport sits under the ribbon in a `Column`; overlay `CustomPaint`s paint wherever the camera projects and nothing clipped them. | `part_viewport.dart`: the viewport's `LayoutBuilder` is wrapped in `ClipRect`. |
| 7 | Edit Alone: Measure returns 422 `missing_reference` | Picks on the focused Part have `occurrenceId: ''` ("the focused Part"), but Measure sent them against the **root** Part id; the root here has no geometry. | `part_screen.dart` `_scheduleMeasureQuery`: all picks on the focused Part → measure in `_focusPartId` (as the Width mate check already did); mixed with picks elsewhere → root, focused picks given `currentOccurrencePath`. |
| 9 | Password manager fills only the API key | Android autofill pairs username + password; the address fields had no hint or only `url`, and the storage / relay fields had none at all. | Address fields `AutofillHints.username` (+`url`), keys `password`, each pair in an `AutofillGroup`, `finishAutofillContext()` on save: `home/server_screen.dart`, `home/storage_screen.dart`, `vr_pairing/headset_pairing_screen.dart` (relay). |
| 10 | AI chat flips between full width and a centred column | `DesktopMaxWidth` only caps in desktop mode, and the mode follows the last pointer, so every touch / mouse switch flipped it. | `ai/ai_modelling_screen.dart`: 900 px cap whatever the mode (a phone is narrower than the cap). |
| 14 | Desktop: "Select Feature" (Pattern / Mirror) does not open the Build tree | While a tool is open, the desktop left pane shows the tool's panel instead of the tree (`_desktopToolPanelOpen`). The plane / profile / path pickers were exempt, the tree pickers were not. "Select Feature" only sets `_featureTreeVisible`, which only the phone layout reads. The same was true of every other tree picker: loft sections, knit, solid from surfaces, thicken, offset surface, the loft-surface / ruled-surface section pickers, and the sketch pickers. | `part_screen.dart`: new `_treePickerActive` (`_treeSketchPickerMode` + `_treeFeaturePickerMode`, now also what `FeatureTreePanel`'s picker flags read). While true, the desktop pane shows the Build tree, even if the user had folded it away or is in the Assembly lens. Desktop test added (fails without the fix). |
| 11 | Save dialog file-name field jitters | The collision check ran on every keystroke, flashing a `LinearProgressIndicator`, and the warning row came and went: the dialog changed height. | `relative_path_dialog.dart`: 300 ms debounce, stale answers dropped, no progress bar, warning in a fixed-height slot. Test updated for the debounce. |

Verified: backend sketch / constraint / solver tests (778 passed + the new file, which fails without the fix);
`flutter analyze` clean on every changed file; Flutter tests `relative_path_dialog`, `headset_pairing`,
`sketch_constraint_overlay_*`, `ai_modelling_screen`, `server_projects_widget`, `part_screen`, `home_screen` all pass.
**Not verified (needs the device):** label size and clipping as seen on the monitor, autofill with a real password manager,
Measure in Edit Alone against a live backend, the dialog's feel while typing.

## To do (plan)

### Progress

The implementation session updates this table as each part lands (one commit per row, on `ccr-452ef966-vye7bw`).

| Part | Summary | Status | Commit |
|---|---|---|---|
| 4 | Angle dimension: quadrant field, shared ray rule, label on the arc, choices | Done | fb4755c |
| 13 | Desktop never opens the hamburger panel; scene settings dialog | Done | 7f17e9e |
| 12 | Desktop Visibility button and panel; ribbon duplicates removed | Done | 11e74ec |
| 8 | Copy to cloud storage: new or existing project; Open only opens | Done | 8fbbab8 |
| 2A | Backend: face → feature endpoint | Done | 87b0335 |
| M.1 | Backend: Mirror takes several tool features | Done | this commit |
| M.2 | Shared seed rule for Pattern and Mirror (fixes Mirror's Select Feature with a cut) | To do | |
| 2B + M.3 + M.4 | Pattern and Mirror: Feature / Body tabs, face-picked scope, one entry for every pathway | To do | |

Suggested order: **4 → 13 → 12 → 8 → 2**. Item 4 is backend + client with a saved-file field. 13 and 12 are desktop
layout. 8 is a flow change. 2 is the largest: a backend endpoint (2A), the Pattern tool reworked (2B) and Mirror the same way (M);
its own order is at the end of the Mirror part.

### 2. Pattern and Mirror: one tool each, two tabs, scope picked by faces, whichever way it was opened

**The intended behaviour (from the tester, 2026-11-17):**

1. The Pattern tool has two tabs, **Feature** (the default) and **Body**.
2. The user gets the cursor and picks one or more **faces**.
3. Each picked face adds to the pattern's scope:
   - on the **Feature** tab, the feature that made that face (a cut's side wall gives the cut, a boss's face gives the boss);
   - on the **Body** tab, the body the face belongs to.
4. Both ways into the tool give this same tool:
   - **Start > Pattern**: Feature tab, empty scope, cursor ready to pick faces.
   - **Long press a feature in the Build tree > Pattern**: Feature tab, that feature already in scope; more faces can be
     added.

**What it does today** (`viewport3d/part_screen.dart`):
- Start > Pattern opens a separate `pickingBodies` step (`_startPatternPicker`) with a body-only filter
  (`_patternBodyPickerSelectionFilter`) and a `PickerRibbon` with "Select Feature". Only after confirming does the panel open.
- The long press skips that step (`_openPatternPanelFromFeature`).
- The Pattern Body / Pattern Feature pill (`_patternSeedKind`, `PatternPanel.seedKind`) only appears when the seed came from
  features that qualify both ways, and never after a body pick.
- So the two pathways open different UIs, and from Start a tapped body can never become a feature pattern.

What already helps:
- `pattern_seed.dart` `resolvePatternSeed` is already the one rule for turning picked features into the request (a cut or
  boss-into-target → `tool_feature_ids`, a body-making feature → `source_feature_ids`, both kinds together → refused with a
  message).
- The backend already patterns several tool features (PR #368).
- Nothing yet maps a **face** to the feature that made it. That needs a backend endpoint (step A).

#### A. Backend: which feature made each face

- New `POST /document/parts/{part_id}/face-owner-features`, body `{"faces": [SubShapeRef, ...]}` (face refs as the selection
  sends them: body id + face index; `occurrence_id` handling as in Measure). Response `{"features": [{"face": ..., "feature_id":
  "..."}]}`, one per face, in order. 422 `missing_reference` for a face that does not resolve.
- Rule, in a new `app/document/face_owner.py`:
  - Take the features that act on the face's body, latest first: every cut, and every boss whose `target_body_ids` includes
    the body. Use the same eligibility as `tool_feature_qualifies`, and skip features that are hidden or rolled back.
  - For each, get its pre-boolean tool shape the way `_resolve_pattern_tool_shape_and_target` does
    (`resolve_feature_tool_shape` against the snapshot taken just before that feature ran). Factor that snapshot code out and
    share it, don't copy it.
  - The face belongs to the first feature where **every** sample point of the face lies on one of the tool shape's faces
    (distance < 1e-6 × the body's size, `BRepExtrema_DistShapeShape` to the tool's faces). Take 3-5 points: triangle
    centroids from the face's own tessellation, or UV samples clamped inside the face (`BRepClass_FaceClassifier`).
  - Test against the tool's bounded **faces**, not their underlying surfaces. Otherwise the top face of a block wrongly
    matches a hole cut that starts on that face: the hole's cap is coplanar, but it covers only the area the cut removed.
  - No match → the feature that made the body (the body id's base feature, as `body_ids_for_feature_id` names bodies).
- Tests (`tests/test_face_owner_features.py`):
  - block + through hole: the block's top face → the extrude; the hole wall → the cut;
  - block + boss merged into it: boss side face → the boss;
  - a cut whose start plane is the block's top face does not claim the top face;
  - pattern-instance faces → the pattern feature (it is a tool feature in its own right only if it qualifies; otherwise the
    body rule applies).

#### B. Client: one entry, two tabs, face picking for scope

State (replace `_patternStep.pickingBodies` and the `_patternLongPressSeedFeature` pill logic):
- `_patternTab`: `PatternTab.feature` (default) | `PatternTab.body`.
- Scope per tab, kept separately so switching tabs loses nothing: `_patternScopeFeatureIds` (ordered, no duplicates) and
  `_patternScopeBodyIds`. The request uses the active tab's list only. Feature tab → `resolvePatternSeed(bodyIds: [],
  features: scope, …)`. Body tab → `bodyIds: scope`.
- `_patternActiveSlot`: `scope` | `direction1` | `direction2` | `axis`. This extends today's `_patternActiveDirectionSlot`.
  The scope slot is active on opening.

Entry points (both call one `_openPatternTool({List<FeatureDto> seedFeatures = const []})`):
- **Start > Pattern** (`FeaturePickerAction.pattern` → `_startPatternPicker`): `_openPatternTool()`. No `pickingBodies`
  step, no `PickerRibbon`. The panel opens straight away.
- **Long press > Pattern** (`FeatureContextMenuAction.pattern` → `_openPatternPanelFromFeature`):
  `_openPatternTool(seedFeatures: [feature])`, so Feature tab with that feature in scope. The scope slot stays active so faces
  can be added.
- **Selection drawer > Pattern on selected bodies** (`_onPatternTapped`): Body tab with those bodies in scope (the drawer
  only offers it for bodies).
- **Edit an existing pattern** (`_openPatternPanelForEdit`): the tab follows what was saved (`tool_feature_ids` or
  `source_feature_ids` → Feature, `source_body_ids` → Body), and the scope is filled from it.
- Delete `_confirmPatternBodySelection` and the pickingBodies ribbon, and `_patternSeedKind` / `_setPatternSeedKind` and
  `PatternPanel.seedKind` / `onSeedKindChanged` (the tabs replace the pill).

Picking:
- While the scope slot is active, push a **faces-only** selection filter (replacing `_patternBodyPickerSelectionFilter`
  for this tool).
- **Body tab:** a tapped face adds its `bodyId` to `_patternScopeBodyIds` straight away, no server call. Tapping a face of a
  body already in scope removes it (toggle, like the current accumulate behaviour).
- **Feature tab:** a tapped face → `DocumentApiClient.faceOwnerFeatures(partId, [ref])` (new) → add the returned feature id;
  tapping again removes it. Several faces picked in quick succession: one request per tap is fine, guarded by a token like
  `_measureRequestToken`.
- The rest of the viewport highlight stays as it is today for the scope (the source bodies / the features' faces).
- When the scope changes, re-run `resolvePatternSeed` (Feature tab). If it returns `error` (cuts and body-making features
  mixed), show it inline in the panel and disable Confirm. Do not drop the pick: the user can remove one.
- Tapping the Direction / Axis field in the panel makes that slot active, and its edge/face filter applies as today
  (`_patternDirectionSelectionFilter`). Tapping the Scope field makes scope active again.
- "Select Feature" / "Add from Tree" (`_startSourceFeaturePicker(_SourceFeaturePickerTarget.pattern)`) stays as a second way
  to add to the **Feature** tab's scope. On the Body tab it is hidden.

Panel (`viewport3d/pattern_panel.dart`):
- At the top, a `SegmentedButton<PatternTab>`: **Feature** | **Body** (keys `pattern-tab-feature`, `pattern-tab-body`). It
  replaces the `seedKind` segmented button.
- Under it, a **Scope** field (key `pattern-scope-field`), like the Direction fields:
  - "Pick faces" while empty, else chips naming the features (feature display names, as the Build tree shows them) or the
    bodies, each with a remove ×;
  - highlighted while it is the active slot.
- `merge`: Feature tab with tool features forces `fuseIntoOne`, as today (`_resetPatternConfiguringState`); Body tab
  defaults to `keepSeparate`.
- Preview (`_schedulePatternPreview`) runs once the scope is non-empty **and** a direction or axis is set, as today.

Tests (`test/part_screen_test.dart` and `test/pattern_panel_test.dart` if it exists, else new):
- Start > Pattern opens the panel with Feature selected, the scope slot active, and no `PickerRibbon`.
- The long press opens the same panel (same keys present) with that feature in scope.
- Feature tab: tapping a hole wall calls `faceOwnerFeatures` (fake client returns the cut) and the request on Confirm carries
  `tool_feature_ids: [cut]`.
- Body tab: tapping a face puts that body in scope and the request carries `source_body_ids`.
- Switching tabs keeps each tab's scope.
- A cut and a body-making feature together show the message and disable Confirm.
- Editing a saved feature pattern opens on Feature, and a saved body pattern on Body.

The VR client has no Pattern or Mirror tool, so there is nothing to change there.

#### M. Mirror: the same tool shape

Same intended behaviour as Pattern: **Feature** (default) / **Body** tabs, scope picked by faces, and Start > Mirror and the
long press opening one tool.

**What it does today** (`viewport3d/part_screen.dart`, `viewport3d/mirror_panel.dart`):
- **Start > Mirror** (`_startMirrorPicker`): a `pickingBodies` step with a body-only filter
  (`_mirrorBodyPickerSelectionFilter`). Its `PickerRibbon` has **no "Select Feature" button** (Pattern's has), and
  `_confirmMirrorBodySelection` reads bodies only. So from Start, Mirror can only mirror bodies.
- **Long press > Mirror** (`_openMirrorPanelFromFeature`): skips straight to the plane step with the feature as
  `tool_feature_id` (cut / boss-into-target) or `source_feature_ids`. The Pattern Body / Pattern Feature-style pill
  (`_mirrorSeedKind`) shows only when that one feature qualifies both ways.
- **Selection drawer > Mirror on bodies** (`_onMirrorTapped` → `_openMirrorPanel`): Body.
- **"Select Feature" inside the panel** (`MirrorPanel.onPickSourceFeatures` → `_startSourceFeaturePicker(mirror)`):
  `_confirmSourceFeaturePicker` writes the picks straight into `_mirrorSourceFeatureIds`. **That is the bug PR #368 fixed
  for Pattern only:** a picked cut is sent as a feature whose bodies are copied, which a cut has none of, so it mirrors
  nothing. It does not go through `resolvePatternSeed`.
- **Backend:** `MirrorFeature.tool_feature_id` is a single feature (`backend/app/document/models.py`, `mirror.py`). Pattern
  took a list in PR #368 (`tool_feature_ids`, the first still also in `tool_feature_id`, the rest saved as
  `extra_tool_feature_ids`).
- Mirror's own pick after the scope is a **plane** (`_MirrorStep.pickingPlane`, `_mirrorSelectionFilter`). A planar
  **face** is a valid mirror plane, so face picks for the scope and face picks for the plane must not be confused (see the
  active slot below).

**Plan:**
1. **Backend, several tool features** (same shape as PR #368 for Pattern; read `0b8541d`'s diff to `pattern.py`,
   `models.py`, `native_format.py`, `schemas.py`, `router.py`, `graph.py` and copy it):
   - `MirrorFeature.tool_feature_ids` on create / update / response; `tool_feature_id` stays and is the first;
     `extra_tool_feature_ids` in the file (an older file loads with just the first).
   - Each tool feature is mirrored on its own and applied to the one shared target in feature order. Tool features acting on
     different bodies are refused (`tool_features_different_targets`).
   - Add them to the dependency graph (deleting any of them takes the mirror with it) and to the coarse preview.
   - `tests/test_mirror_several_tool_features.py`, modelled on `test_pattern_several_tool_features.py`.
2. **Client, one seed rule.** Rename `pattern_seed.dart` → `pattern_mirror_seed.dart` (`resolveSeed`, used by both
   tools) and use it for Mirror's scope. This fixes the "Select Feature" cut bug above on its own, even before the tabs land,
   so it can go first.
3. **Client, the same tool as Pattern.**
   - `_openMirrorTool({seedFeatures})` from Start (empty scope), the long press (that feature) and the drawer (Body tab with
     those bodies). No `pickingBodies` step and no `PickerRibbon`.
   - `MirrorPanel` gets the **Feature | Body** `SegmentedButton` (keys `mirror-tab-feature`, `mirror-tab-body`) replacing
     `seedKind`, and the same **Scope** field (key `mirror-scope-field`) above the **Mirror plane** field.
   - Active slot `scope` | `plane`, scope active on opening:
     - **scope:** a faces-only filter; a face adds its feature (via `faceOwnerFeatures`, from 2A) on the Feature tab, or its
       body on the Body tab, and tapping again removes it;
     - **plane:** today's `_mirrorSelectionFilter` (reference plane, planar face, plane feature).
     - Tapping the Mirror plane field switches slot; picking a plane while the scope slot is active never happens, because the
       scope filter is faces only and is read as scope.
     - After the first scope pick, **do not** jump to the plane slot automatically. The user may want several faces.
   - Per-tab scopes kept separately, as Pattern. The cut + body-making error is shown inline and Confirm disabled.
   - Edit (`_openMirrorPanelForEdit`): the tab follows what was saved.
   - Remove `_mirrorSeedKind`, `_setMirrorSeedKind`, `_mirrorLongPressSeedFeature`, `MirrorPanel.seedKind` /
     `onSeedKindChanged`, `_confirmMirrorBodySelection` and the pickingBodies ribbon.
   - "Select Feature" / "Add from Tree" stays for the Feature tab (item 14 makes it work on the desktop).
4. **Share, don't copy.** The tabs + Scope field are the same widget in both panels: a `SeedScopeSection` (new, e.g.
   `viewport3d/seed_scope_section.dart`) with the tab, the field and its chips, and a callback per face pick. The face →
   feature / body resolution and the per-tab scope state live in one small controller class used by both tools, not in two
   copies inside `part_screen.dart`.
5. **Tests**, the same list as Pattern's, for Mirror:
   - Start > Mirror opens on Feature with the scope slot active and no `PickerRibbon`;
   - the long press opens the same panel with the feature in scope;
   - a hole wall face → `tool_feature_ids: [cut]`;
   - Body tab → `source_body_ids`;
   - the tab switch keeps both scopes;
   - picking a planar face while the **plane** slot is active sets the plane, not the scope;
   - Select Feature with a cut sends it as a tool feature (the bug in today's code).

Order for 2 + M: **2A** (backend face owner) → **M.1** (backend Mirror several tool features) → **M.2** (shared seed rule,
fixes Mirror's Select Feature cut bug) → **2B + M.3 + M.4** together (the shared section is written once).

### 4. Angle dimension: wrong angle drawn, label off the arc, only one choice offered

Findings (flange profile sketch, constraint `26023942…`, lines `74454fd6` vertical up and `f21632dd` up-left):
- The backend (`solver.py` `_SolverBuilder._angle_needs_supplement`) treats the value as the **unsigned angle between the two
  lines** and picks `value` or `180 - value`, whichever is nearer the current shape. The constraint stores no "which of the
  angles" choice.
- The overlay (`viewport3d/sketch_constraint_overlay.dart` `angleDimensionVertexAndRays`, and the same rule in
  `sketch/label_drag_resolver.dart` `angleVertexAndRays`) draws the arc between the two lines' **outward rays from the
  vertex**. Here those rays are 156.41° apart, so it draws 180 - 23.59.
- Label: with no placed radius, `_paintAngleDimension` places the label on the **chord** between the arc ends
  (`_dimensionLabelPlacement(arcPoint1, arcPoint2, …)`). For a wide arc the chord midpoint is near the vertex, far off the
  arc.
- Offering: creating an angle from two selected lines offers one value only.

Plan:
1. **Backend, saved field.** `AngleConstraint` gains `quadrant: int` (0-3, default 0 = today's outward-rays meaning). Each
   value picks one of the four angles at the vertex: ray1 / ray2 each kept or flipped. Persist it in `native_format.py`
   (default 0 when absent, so old files load unchanged), in the schemas, and in create / update endpoints. In
   `_angle_needs_supplement`, use the quadrant instead of "nearest" whenever the quadrant is given explicitly. Keep "nearest"
   for old files (quadrant absent → nearest, as today). Tests: each quadrant holds its angle through a drag-solve; an old file
   round-trips.
2. **One shared geometry rule (client).** A pure function `angleRays(item, quadrant)` returns the two rays to draw. For
   quadrant absent: start from the outward rays, then flip ray2 if the angle between them is nearer `180 - value` than
   `value`. That alone fixes the tester's case. `sketch_constraint_overlay.dart`, `label_drag_resolver.dart` and the 2D
   `sketch/sketch_canvas.dart` angle painter must all call it. They currently duplicate the rule, so grep `angleVertexAndRays`
   and `_maxAngleIntersectionDistance`.
3. **Label on the arc.** Default placement = the arc's midpoint (vertex + bisector × radius), not the chord midpoint. Keep the
   placed-label path (`_placedAngleLabel`) but make `LabelDragResolver.angleLabelCenter` measure `along` on the arc.
   `ConstraintAngleDimensionItem` needs the value (or the quadrant) to pick the rays; add it.
4. **Offer the choices.** When two lines are selected, the ghost dimension offers the angle under the cursor. Pick the
   quadrant from which of the four sectors around the vertex the cursor is in (θ, 180-θ, and their opposites), the way
   SolidWorks / Onshape do. Show the ghost arc in that sector, and save the quadrant with the constraint.
5. Tests: the flange sketch's constraint draws a 23.59° arc with its label on the arc (a unit test on the shared rule plus the
   overlay item). Each quadrant round-trips create → reload → draw.

### 8. "Add this local project to an existing cloud project" lives under Open

Today the only path is Open > Cloud storage > pick project > "Save current work here" (`_onServerProjectsPressed`, dialog
`server-project-choice`). "Copy this project to cloud storage…" (`_onCopyToServerPressed`) only creates a **new** project
(`showCopyToServerDialog` asks for a name).

Plan:
- `_onCopyToServerPressed` first asks: **New project folder** / **Existing project folder** (a small dialog, keys
  `copy-to-cloud-new` / `copy-to-cloud-existing`).
- New → today's flow, unchanged.
- Existing → `showServerProjectsDialog(context, remote)`, then copy every file of the local project into it.
  `RemoteStorageService.copyProjectToServer` creates the project. Add a sibling `copyProjectIntoServer(local, root, project)`
  (or a flag) that writes into an existing one in one commit, and asks on name clashes (reuse the conflict dialog's Overwrite
  / Skip / Cancel). Then `_adoptServerProject` as today.
- Remove "Save current work here" from the Open flow: Open opens. For an empty project the Open flow can still just adopt
  it, as today, or say "This project has no files". Decided: say so (snack bar "This project has no files yet. Use File >
  Copy this project to cloud storage… to put your work in it.") and do not adopt it.
- The same entry also sits in `_showLocalSessionSheet` (the local-folder quick button) and in the hamburger File menu: both
  call `_onCopyToServerPressed`, so they get it for free.
- Tests in `test/server_projects_widget_test.dart`: both branches; existing-project copy with a name clash.

### 12. Desktop (Android, external monitor): Visibility quick menu unreachable

Cause: the Visibility panel is only drawn `if (_visibilityPanelOpen && _startButtonVisible)`. It is opened only from the
phone layout's quick column (`quick-visibility-fab` in `_quickColumnButtons`), and the desktop layout shows neither.

Plan:
- In `part_viewport.dart`, next to the **Reset view** button (`tooltip: 'Reset view'`, top-right, `right: 8`), add a
  Visibility button directly below it, shown only in the desktop layout. Pass an `onVisibilityPressed` callback and an
  `anythingHidden` badge flag into `PartViewport`; `part_screen.dart` sets `_visibilityPanelOpen = true`.
- Draw the panel in desktop mode too: change the condition to `_visibilityPanelOpen && (_startButtonVisible ||
  _desktopLayout) && !_anyToolSessionActive`. In desktop mode anchor it **top-right under the new button** (`top: 56 + 48,
  right: 8`), width `min(viewportWidth - 88, 420)`, rather than bottom-left where the phone puts it.
- Then remove what the panel duplicates from the desktop View ribbon tab (`RibbonTabData(id: 'view'…)` in `part_screen.dart`).
  Compare it with `_visibilityChips()` / `_visibilityViews()` / the render-mode control: at least **Planes** and the
  render-mode cycle (Shaded / Edges / Wireframe). Keep Fit, View cube, standard views, Perspective, Present.
- Test: desktop layout (`LayoutModeController(mode: desktop)` as other desktop tests do). The button exists, opens the panel
  top-right, the ribbon no longer has the removed commands.

### 13. Desktop: the hamburger menu still opens

Cause: desktop **Options > "Background, colour and scene…"** (`part_screen.dart`, `menu-options` submenu) runs
`setState(() => _toolbarOpen = true)`. That is the phone layout's hamburger panel (`PartToolbar`).

Plan:
- Add a desktop dialog `showSceneSettingsDialog` (new, in `view_prefs_sheets.dart`). Build it from the same controls as
  `PartToolbar`'s View section: Background Colour (`showColourSwatchSheet`), Body Colour, Body Transparency
  (`showBodyOpacitySheet`), Polygon Resolution (`showPolygonResolutionSheet`), Scene (roughness / light / emissive sliders),
  Perspective. Wire it to the existing handlers (`_onBgColourChanged`, `_onMeshQualityChanged`, …). Better still, extract
  PartToolbar's View-section body into a widget used by both.
- Point the Options item at it. Then grep every `_toolbarOpen = true` and make sure none is reachable while
  `_desktopLayout`. Add a guard: in desktop mode, `PartToolbar` is never built (assert in debug).
- Audit that every hamburger item has a desktop home (File menu / ribbon / Options): File (all present in the desktop File
  menu? check New, Open, Save, Save As, Save All, Copy to cloud, Import, Export, Part Properties, Connect a VR headset,
  Exit), View, Selection Filters, Controls. List any gap in the PR.
- Test: desktop layout, Options > Background, colour and scene opens the dialog and `PartToolbar` is not in the tree.

## Notes from the implementation

Decisions the plan left open, recorded as they were made.

- **4, quadrant:** `AngleConstraint.quadrant: int | None` (absent and `null` both mean the old nearest rule; there is no default 0,
  so an old file's constraint behaves exactly as before). Bit 0 flips the first line's outward ray, bit 1 the second's; the value
  is the angle between the two resulting rays, so 0/3 and 1/2 are the same magnitude in opposite sectors (the solver only needs
  the parity; the client draws the named sector). Outward ray = from the lines' intersection towards the segment's midpoint, the
  rule the overlay already drew with (`angle_outward_ray_signs` in `solver.py`, `angle_rays.dart` on the client). `PATCH
  .../constraints/{id}` takes an optional `quadrant` (omitted keeps the saved one). The solver's residual check now accepts the
  supplement as well (a supplement solve lands the lines' directions on 180 - value, the same dimension seen from the other side).
- **4, offering the angle:** the ghost's sector follows the sketch cursor (`SketchController.angleGhostQuadrant`). While the
  cursor is within a tap of either line (as it is just after the second line was picked) no side is chosen: the ghost shows the
  outward rays and no quadrant is sent (old behaviour). The sector is frozen when the ghost is tapped, so moving the pointer to the
  value editor does not change it. Re-dimensioning an existing angle sends the picked quadrant with the new value.
- **4, label:** `DimensionLabelPlacement.along` for an angle is now measured along the arc from its middle (it was along the chord),
  and `radius` is the pointer's distance from the vertex. A saved angle label keeps its arc radius; its `along` reads slightly
  differently (arc length instead of chord distance). The default label is the arc's middle in the 3D view and the flat canvas.
- **13:** the View section's appearance entries are one widget, `ViewAppearanceControls` (`view_appearance_controls.dart`), used by
  `PartToolbar` and by the new `showSceneSettingsDialog` (put in that file rather than `view_prefs_sheets.dart`, which it imports,
  to keep the sheets file free of the toolbar). The dialog also carries Perspective and the far clip. `PartToolbar` is not built in
  the desktop layout; the only opener left (`_openHamburgerPanel`, the phone quick column) asserts it is not desktop. Hamburger
  audit, desktop homes: File menu has every File entry (New, Open, Save, Save As, Save All, Copy to cloud, Import, Export, Part
  properties, Connect a headset, Exit). View: Perspective (ribbon and dialog), reference planes and render mode (ribbon, moved to
  the Visibility panel by item 12), appearance and Scene (dialog), Controls (Options). **Gaps found and closed:** the far clip
  slider had no desktop home (now in the dialog); the Sketch Points / Sketch Lines selection filters had none (now in Options).
- **12:** the Visibility button toggles the panel (a second click closes it). Removed from the desktop View ribbon tab: **Planes**
  and the **Shaded / Edges / Wireframe** group (the panel has the reference-planes chip and the render-mode control). Kept: Fit,
  View cube, Normal to, the standard views, Perspective, the appearance override group, Present. The panel is not drawn while a
  tool session is open, in either layout.
- **8:** `RemoteStorageService.copyProjectIntoServer(local, localRoot, root, onClashes:)` (a sibling of `copyProjectToServer`):
  one commit; clashing names are asked once, all together, through the reworded `showChangedOnDiskDialog` (Overwrite / Skip these
  files / Cancel); an overwrite sends the listed version as its base. Open > Cloud storage on a project with files now goes straight
  to choosing a file. **Choice made here (not in the plan):** after Skip, the session is not marked unsaved (it still holds the
  local folder's version of the skipped files, and Save would write it over the project's); the snack bar says so. The owner's
  13 Nov sequence (a brand-new part into an empty cloud project) is now File > Copy this project to cloud storage… > Existing
  project folder (the old Open-based test is rewritten that way); for a session with no local folder yet this first asks for one
  (`_ensureProjectRoot`), as the New project folder path always did.
- **2A:** the request takes Measure's ref shape (`{occurrence_id, subshape_ref}` or a bare `SubShapeRef`) plus optional
  `rollback_excluded_feature_ids`; the response echoes each face with its `feature_id`. The "as it ran" snapshot is now one function,
  `extrude.resolve_feature_tool_shape_as_it_ran`, used by Pattern, Mirror and `face_owner.py` (Pattern's and Mirror's copies
  removed). Candidates also include Patterns and Mirrors that repeat tool features into the body (their instances / mirrored tools),
  so a patterned or mirrored hole's wall gives the Pattern / Mirror. Mirror's tool half is split out
  (`mirror.mirrored_tool_feature_shapes`) for this. Samples: up to 5 points from a 9x9 UV grid kept inside the face. Full backend
  suite: 3596 passed; 4 `test_planetary_gear_jobs.py` tests failed under `-n 8` and pass alone (job-pool timing, not this change).
- **M.1:** as Pattern in `0b8541d`: `MirrorFeature.extra_tool_feature_ids` / `all_tool_feature_ids`, `tool_feature_ids` on create /
  update / response, saved in the file (an older file loads with the first only), in the dependency graph and in
  `resolve_feature_produces`. The router's `_pattern_tool_ids` / `_validate_pattern_tool_feature_ids` became `_payload_tool_ids` /
  `_validate_tool_feature_ids` with a `kind` argument, shared by both. **Not done, by finding:** "add them to the coarse preview" -
  Mirror has no coarse path (`compute_part_bodies_coarse` has no Mirror branch and there is no Mirror coarse-preview endpoint).

