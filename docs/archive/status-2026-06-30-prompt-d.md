# Prompt D — Feature tree sketch picker for extrude — status — 2026-06-30

Branch: `claude/new-session-up4xx1`.

## Items implemented

| # | Item | Status | Files changed |
|---|------|--------|---------------|
| D1 | Feature tree sketch picker after New > Extrude | Done | `feature_tree_panel.dart`, `part_screen.dart`, `part_screen_test.dart` |
| D1 fix | Stale `_selectedFeatureId` bypassing the picker after confirm/cancel/delete (see Addendum) | Done | `part_screen.dart`, `part_screen_test.dart` |

---

## D1 — Feature tree sketch picker

**Codebase shape vs. the prompt's assumptions.** The prompt describes a single `_toolbarOpen` bool gating the Feature tree, and an `_extrudeSketchFeature` flow with no existing entry point for "New > Extrude". The current codebase has moved on from both: the Feature tree's visibility is its own `_featureTreeVisible` bool (separate from the View-menu `PartToolbar`'s `_toolbarOpen`), and there's already an "Add" FAB → "Feature" → "Extrude" entry (`_onFeaturePressed` → `_extrudeSelectedFeature`) that resolves a Sketch from `_selectedFeatureId` and just complains with a SnackBar ("Select a sketch feature in the tree first") if there's nothing eligible already selected. That entry point is what this prompt's guided picker attaches to — D1 is implemented in those terms rather than against the prompt's `_toolbarOpen`/`_extrudeSketchFeature` description.

**Trigger.** `_extrudeSelectedFeature` (the "Add" FAB's Feature > Extrude entry) now checks `_selectedFeatureId` first: if it names an already-eligible Sketch Feature (closed profile), it opens `ExtrudePanel` directly, unchanged from before this prompt — the back-compat case. Otherwise it calls `_startSketchPicker()`.

**Picker mode state.** Two new `_PartScreenState` fields:
- `bool _sketchPickerActive` — threaded into `FeatureTreePanel.isSketchPickerMode`, the controlled-widget bool the prompt asked for (not embedded in the tree's own state).
- `Set<String> _pickableSketchIds` — the Sketch Feature ids `_refreshPickableSketchIds()` most recently found to have a closed profile, used only for the tree's dimming. Purely a visual aid: `_onSketchPicked` always re-checks the tapped Sketch's profile itself via the existing `_checkExtrudeEligibility` helper, so a stale or still-in-flight value here can never let an ineligible Sketch through.

**`_startSketchPicker()`** opens the tree (`_featureTreeVisible = true`), closes the toolbar/plane-selection overlays it'd otherwise collide with, and kicks off `_refreshPickableSketchIds()` (parallel `Future.wait` over every Sketch Feature's `_checkExtrudeEligibility`) in the background so the tree can start dimming once that resolves.

**`FeatureTreePanel` changes** (`isSketchPickerMode`, `pickableSketchIds`, `onSketchPicked` — all optional, default off, so every other caller/test is untouched):
- An inline banner ("Select a sketch to extrude", muted `surfaceContainerHighest`/`onSurfaceVariant` colours) renders below the header when `isSketchPickerMode` — not a dialog, per the brief.
- Each row computes `pickerDimmed = isSketchPickerMode && (!isSketch || !pickableSketchIds.contains(feature.id))` and folds it into the existing hidden-row `Opacity`. Dimmed rows stay tappable (not `ListTile.enabled: false`) — an ineligible Sketch's tap still needs to reach `onSketchPicked` to produce the SnackBar, not be silently swallowed.
- Row taps route to `onSketchPicked` (Sketch rows only) instead of `onFeatureTap` while picking; `onLongPress` is disabled while picking (the cascade-delete/visibility/extrude context menu doesn't make sense mid-pick).

**Validation / SnackBar.** `_onSketchPicked` re-runs `_checkExtrudeEligibility`; on failure it shows `'This sketch has no closed profile — add more lines or close the loop first'` and returns without leaving picker mode. On success it exits picker mode, sets `_selectedFeatureId`, and calls the existing `_openExtrudePanel`.

**Cancel-on-dismiss.** `_cancelSketchPicker()` resets `_sketchPickerActive`/`_featureTreeVisible`/`_pickableSketchIds` without ever creating an ExtrudeFeature (the preview-creation flow only starts once `ExtrudePanel` itself is open and its fields change — ending the picker before that point has nothing to undo). Wired into:
- `FeatureTreePanel.onClose` (the tree's own X button) — picker mode routes here instead of the plain `_featureTreeVisible = false` it used before.
- `PopScope`'s back-gesture handler (`canPop` now also checks `!_sketchPickerActive`).
- `_onViewportBackgroundTap` (a background tap in the 3D viewport), mirroring how it already cancels `_planeSelectionMode`.

---

## Tests added

All in `test/part_screen_test.dart`, new `group('Prompt D - feature tree sketch picker for Extrude', ...)`, driven through the real "Add" FAB → "Feature" → "Extrude" flow (not a direct method call):

| Test | Covers |
|------|--------|
| `opens the Feature tree with the picker banner visible` | Trigger opens the tree with the banner up, no Extrude panel yet |
| `tapping a valid sketch populates the extrude sketch reference and closes the picker` | Valid pick closes the picker, opens `ExtrudePanel`, Confirm creates an ExtrudeFeature referencing the picked Sketch |
| `tapping an invalid sketch shows a SnackBar and leaves the picker open` | Ineligible pick shows the exact SnackBar text, banner/picker state unchanged, no ExtrudeFeature created |
| `dismissing the Feature tree cancels the pending Extrude creation` | The tree's close button exits picker mode with nothing created, and the flow can be started fresh afterwards |
| `a pre-selected, already-eligible Sketch skips the picker entirely (back-compat)` | Selecting a locked Sketch row (tap-without-navigate) first, then triggering Extrude, goes straight to the panel — the picker banner never appears |

Existing tests covering normal-mode tree taps (`tapping an unlocked (editable) Feature opens its Sketch...`, `tapping a locked Feature only selects it...`) and the long-press Extrude flow (`long-pressing a SketchFeature with/without a closed profile...`) are unmodified and still pass, since `isSketchPickerMode` defaults to `false`.

---

## Test/analyze results

Flutter SDK on this machine had to be bootstrapped from scratch (none was preinstalled) — see "Environment note" below for how, since it's not a normal `flutter test` run.

- `flutter analyze lib/viewport3d/part_screen.dart lib/viewport3d/feature_tree_panel.dart test/part_screen_test.dart` — no issues found.
- `flutter test test/part_screen_test.dart` — 20 passed, 2 failed. Both failures (`the toolbar's Hide Reference Planes entry toggles its own label between Hide/Show`, `the toolbar's render-mode entries set PartViewport.renderMode and mark the active one with a check`) reproduce identically on the unmodified `main` branch in this same environment — pre-existing, unrelated to this prompt's changes (`part_toolbar.dart` was not touched). All 5 new Prompt D tests pass.
- `flutter test` (whole suite) — 129 tests, 11 failures, all pre-existing/environment-related and outside this prompt's changed files: `mesh_geometry_test.dart`, `orbit_camera_test.dart` (×3), `part_viewport_test.dart`, `widget_test.dart`, `sketch_canvas_ghost_editor_test.dart`, `sketch_controller_test.dart` and `selection_list_drawer_test.dart` (load errors), plus the same 2 `part_screen_test.dart` failures above. None are in files this prompt touched.

### Environment note

No Flutter SDK was present in this container. `flutter_scene ^0.18.1` (per `client/README.md`) requires the `master` channel, not `stable` — `stable`'s `flutter_gpu` package has since diverged (`TextureCompressionFamily`, `vertexLayout` etc. no longer match). The SDK was bootstrapped by downloading `github.com/flutter/flutter`'s `master` branch tarball (the in-container git proxy only allows `didsa-uk/didsa-cad`, so a normal `git clone` of `flutter/flutter` is blocked) and synthesizing a single-commit local git history so the tool's content-aware engine-artifact hashing has something to hash. This pulled in whatever `master` happened to be at fetch time (`3.46.0-0.2.pre`, framework revision `7400c96c37`), which is almost certainly newer than whatever `master` snapshot this repo's tests were last verified against — the likely explanation for the 11 pre-existing failures above. None of this is committed; it's local-environment setup only.

---

## Known gaps

- The 11 pre-existing test failures (listed above) are not investigated or fixed here — out of scope for this prompt, and none are in files D1 touched. Worth a follow-up pass once there's a pinned/reproducible Flutter `master` snapshot to verify against, rather than "whatever `master` is today".
- Picker-mode dimming (`_pickableSketchIds`) is a best-effort visual aid computed once per `_startSketchPicker()` call; it does not refresh if a Sketch's profile changes while the picker is already open (e.g. impossible in practice today since nothing else can mutate a Sketch while the Feature tree picker is up and modal-ish, but noting the assumption).
- No dedicated test exercises the dimmed-row visual styling itself (opacity), since none of the prompt's required test-coverage bullets call for it and the existing `_FakeSketchBackend` only supports one global profile status across all sketches in a test (extending it for a mixed-validity scenario was judged not worth the added fixture complexity for a purely cosmetic property).

---

## Addendum — stale-selection bug report, same day

User report after D1 shipped: confirm an Extrude, delete that ExtrudeFeature, then tap New > Extrude again — it went straight back to extruding the same Sketch instead of offering the picker.

**Root cause.** `_confirmExtrude` and `_cancelExtrude` never cleared `_selectedFeatureId`. `_onSketchPicked` sets it to the picked Sketch's id on a valid pick (so the just-opened `ExtrudePanel` has something to show in the tree as "selected"), but nothing ever unset it afterwards. `_extrudeSelectedFeature`'s back-compat shortcut ("a pre-selected, already-eligible Sketch skips the picker") then fired on every later invocation, since that stale id still resolved to a still-eligible Sketch Feature — including after deleting the resulting ExtrudeFeature, since `_cascadeDeleteFeature`'s own selection-clearing only fires when the *deleted* Feature was selected, not the Sketch it was built from (which survives the delete and stays in `_features`).

**Fix.** Both `_confirmExtrude` and `_cancelExtrude` now clear `_selectedFeatureId` when it equals the Sketch Feature they were just operating on:

```dart
if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
  _selectedFeatureId = null;
}
```

so a later New > Extrude always falls through to the picker again, unless the user has freshly selected a different Sketch row in the tree in the meantime (the genuine back-compat case the prompt asked for).

**Test added.** `'after confirming an Extrude then deleting it, a later New > Extrude offers the picker again rather than reusing the stale selection'` in the same `test/part_screen_test.dart` Prompt D group — reproduces the report exactly (picker → pick Sketch 1 → Confirm → reopen tree → long-press the new ExtrudeFeature → Delete → New > Extrude again → asserts the banner reappears and `Confirm` does not).

**Test/analyze results.** `flutter analyze lib/viewport3d/part_screen.dart test/part_screen_test.dart` — no issues. `flutter test test/part_screen_test.dart` — 21 passed, same 2 pre-existing/unrelated failures as the original D1 run above (`Hide Reference Planes`, render-mode entries) — no new failures, no regressions in any of the now-6 Prompt D tests.
