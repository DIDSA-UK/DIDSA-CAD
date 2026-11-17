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
| 11 | Save dialog file-name field jitters | The collision check ran on every keystroke, flashing a `LinearProgressIndicator`, and the warning row came and went: the dialog changed height. | `relative_path_dialog.dart`: 300 ms debounce, stale answers dropped, no progress bar, warning in a fixed-height slot. Test updated for the debounce. |

Verified: backend sketch / constraint / solver tests (778 passed + the new file, which fails without the fix);
`flutter analyze` clean on every changed file; Flutter tests `relative_path_dialog`, `headset_pairing`,
`sketch_constraint_overlay_*`, `ai_modelling_screen`, `server_projects_widget`, `part_screen`, `home_screen` all pass.
**Not verified (needs the device):** label size and clipping as seen on the monitor, autofill with a real password manager,
Measure in Edit Alone against a live backend, the dialog's feel while typing.

## To do (plan)

Suggested order: **4 → 13 → 12 → 8 → 2**. Item 4 is backend + client with a saved-file field. 13 and 12 are desktop
layout. 8 is a flow change. 2 has an open question.

### 2. Pattern: Start > Pattern vs long press differ (Pattern Body / Pattern Feature pill)

Findings. PR #368 (`0b8541d`, 15 Nov) already made one seed rule (`viewport3d/pattern_seed.dart` `resolvePatternSeed`) and
shows the pill for any pick that qualifies for both kinds. But the pill (`_patternSeedKind` in `part_screen.dart`) still
only appears when `_patternLongPressSeedFeature` is non-empty and **no body** is picked. Start > Pattern opens a **Body**
picker (`_startPatternPicker`, filter `_patternBodyPickerSelectionFilter`). A user who taps a body there gets a body pattern,
with no pill and no way to reach Pattern Feature. Only the ribbon's "Select Feature" button leads to a feature seed.

**Question for the tester before implementing:** was this seen on a build with PR #368? Was a body tapped in the viewport, or
a feature chosen with "Select Feature"?

Plan (if a body was tapped):
- When `_confirmPatternBodySelection` has exactly the picked bodies and no features, resolve each body to the feature that
  last made or modified it. Use the body-id naming the client already relies on: `baseFeatureId(bodyId)`, see
  `_patternEffectiveSourceCount`. Set `_patternLongPressSeedFeature` to those features, so `_patternSeedKind` shows the pill
  exactly as after a long press.
- `_patternSeedKind`: drop the `(_patternSourceBodyIds ?? const []).isNotEmpty → null` early return for this case.
  `_setPatternSeedKind`'s body branch must then restore the original body ids (keep them in a field) rather than set
  `source_feature_ids`.
- Widget test in `test/part_screen_test.dart`: Start > Pattern, tap a body made by an extrude-boss, confirm. The pill shows.
  Switching to Pattern Feature sends `tool_feature_ids` (check the request body in the fake client).

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
  it, as today, or say "This project has no files" (tester to choose; recommend saying so).
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
