# DIDSA-CAD Status Summary — 2026-06-23 (Stage 10b)

## What this covers

Stage 10b — UX Additions, three small viewport UX features on top of Stage 10a:

1. A "Hide Reference Planes" toggle in the existing flyout toolbar, alongside "Show Feature Tree".
2. The "Add" FAB now opens a flyout menu instead of acting directly; its one entry, "New Sketch", enters a plane-selection mode where tapping any reference plane creates a `SketchFeature` on it and navigates into the sketch canvas. A "Cancel" banner button and the device back gesture both exit the mode without creating anything.
3. The "Add" FAB is hidden while the Extrude panel is open, so it can no longer overlap the panel.

## Client

- `client/lib/viewport3d/add_button_menu.dart` (new) — `AddButtonMenuAction` enum (`newSketch`) and `showAddButtonMenu`, a `showModalBottomSheet` flyout mirroring the existing `feature_context_menu.dart` pattern.
- `client/lib/viewport3d/part_toolbar.dart` — new `referencePlanesHidden` (default `false`) and `onToggleReferencePlanes` props; new `ListTile` between "Show Feature Tree" and the conditional "New Sketch on..." entry, with its icon/label flipping Grid-off/"Hide Reference Planes" ↔ Grid-on/"Show Reference Planes".
- `client/lib/viewport3d/part_viewport.dart` — new `referencePlanesHidden` field (default `false`). `didUpdateWidget` now also re-syncs plane nodes when this flag changes. `_syncReferencePlaneNodes` removes existing plane nodes and, when hidden, leaves `_planeNodes` empty instead of rebuilding them. `_handleTap` skips `hitTestReferencePlanes` entirely when planes are hidden, so a tap can't land on an invisible plane.
- `client/lib/viewport3d/part_screen.dart`:
  - New state: `_referencePlanesHidden` (bool) and `_planeSelectionMode` (bool).
  - `_onPlaneTap` now branches: if `_planeSelectionMode` is true, it exits the mode and calls `_addSketchFeature(plane: plane)` directly; otherwise it falls through to the pre-existing select-plane-and-show-toolbar behavior, unchanged.
  - `_onViewportBackgroundTap` also clears `_planeSelectionMode`.
  - New handlers: `_onAddPressed` (shows the new flyout, enters plane-selection mode on `newSketch`), `_cancelPlaneSelectionMode`, `_onToggleReferencePlanes`.
  - `build()` now wraps the previous body (moved into `_buildScaffold`) in a `PopScope` with `canPop: !_planeSelectionMode`, so the back gesture cancels plane-selection mode instead of popping the screen.
  - FAB wiring changed: `onPressed` now calls `_onAddPressed` instead of `_addSketchFeature` directly; the whole `floatingActionButton` is `null` whenever the Extrude panel (`_extrudeSketchFeature`) is open.
  - The persistent hamburger toggle button is now also hidden while `_planeSelectionMode` is true (alongside the existing feature-tree-visible check), and a top-center banner ("Tap a reference plane for the new sketch" + Cancel button) appears in its place.
  - `PartViewport` and `PartToolbar` now receive `referencePlanesHidden`; `PartToolbar` also receives `onToggleReferencePlanes`.
- `client/test/part_screen_test.dart`:
  - Updated the FAB navigation test to go through the new flyout (tap FAB → tap "New Sketch" → tap a plane) instead of tapping the FAB directly.
  - Added a test that the flyout's "New Sketch" enters plane-selection mode (banner + Cancel visible) and that Cancel exits it without creating any feature.
  - Added a test that the toolbar's "Hide/Show Reference Planes" entry flips its own label and the `PartViewport.referencePlanesHidden` prop correctly across two toggles.
  - Added a test that the FAB is absent while the Extrude panel is open and reappears once the panel is dismissed.

No backend files were touched, per the brief ("No new backend changes expected").

## Known limitation this session

No Flutter/Dart SDK is available in this sandbox (re-verified via `which flutter dart` and a filesystem-wide `find`, both empty), so none of the client changes above could be checked with `flutter analyze` or `flutter test`. All edits were made by carefully reading each full file before and after editing, cross-checking call sites with `grep`, and manually verifying brace balance across all five changed files. As an unrelated sanity check, the backend test suite was run and passed 166/166 — consistent with this stage making no backend changes, but it does not exercise any of the Dart code above.

**This means the new tests in `part_screen_test.dart` have not actually been executed** — they were written to match the existing suite's established patterns (`_FakeDocumentBackend`, `_FakeSketchBackend`, `_pumpUntil`) and reasoned through manually, but a real `flutter test` run is needed before trusting them.

## Branch / merge state

- All Stage 10b work is committed as `ae0be4a` ("Add Stage 10b UX features: hide-planes toggle, Add-button flyout, FAB z-order fix") on branch `stage-10b-ux-additions`, branched from `origin/main`.
- Pushed to `origin/stage-10b-ux-additions`.
- A PR from `stage-10b-ux-additions` into `main` is being opened as part of this session, per the brief's explicit instruction. **It is not to be merged** — left open for human review.

## What's next

- Run a real `flutter analyze` and `flutter test` on this branch (no SDK was available here) to confirm the new/updated tests actually pass and there are no analyzer warnings in the new code.
- Manually exercise the three new flows on-device or in an emulator: the Hide/Show Reference Planes toggle, the Add-button flyout → plane-selection mode → Cancel/back-gesture/plane-tap paths, and confirm the FAB visually disappears (and reappears) around opening/closing the Extrude panel.
- Review the open PR and merge if it looks good — it was deliberately left unmerged.
