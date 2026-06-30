# 3D viewport: bug fixes, box-selection removal, selection-highlight tweaks — 2026-06-30

Branch: `claude/new-session-khsgmg`.

This continues the same day's work on top of `docs/status-2026-06-30-prompt-a.md`
(box selection A2, clip distance A3, perspective toggle A4). It covers
everything done in this session: seven viewport bug fixes, two follow-up
attempts to fix box selection, the eventual removal of box selection per
on-device feedback, and two minor selection-highlight visual tweaks.

## Items implemented

| # | Item | Status | Files changed |
|---|------|--------|----------------|
| Bug 1 | Selection submenu / window-vs-crossing toggle | Implemented, then **removed** (see below) | `part_toolbar.dart`, `part_screen.dart`, `part_viewport.dart` |
| Bug 2 | Deferred (300ms) tap-commit to avoid double-tap race | Implemented, then **removed** (see below) | `part_viewport.dart` |
| Bug 3 | Cursor tracks box-drag corner during box selection | Implemented, then **removed** (see below) | `part_viewport.dart` |
| Bug 4/5 | Face hover/selection highlights visible from both sides (back-face culling fix) | Done, kept | `mesh_geometry.dart`, `test/mesh_geometry_test.dart` |
| Bug 6 | Cursor crosshair gets a dark outline stroke for visibility on any background | Done, kept | `part_viewport.dart` |
| Bug 7 | Perspective toggle documents the flutter_scene orthographic limitation | Done, kept | `part_toolbar.dart` |
| — | Box-selection hit-test rewrite #1 (frustum-plane via `screenPointToRay`) | Tried, rejected on-device (selected nothing) | `part_viewport.dart` |
| — | Box-selection hit-test rewrite #2 (direct 2D screen-projection) | Tried, rejected on-device (imprecise) | `part_viewport.dart` |
| — | **Box selection removed**, reverted to single-tap-toggle multi-select | Done | `part_viewport.dart`, `part_toolbar.dart`, `part_screen.dart`, `test/part_viewport_test.dart` |
| — | Selected-edge highlight uses a darker blue, distinct from selected-face/-vertex | Done | `part_viewport.dart` |
| — | Selected-vertex highlight marker diameter reduced (14px → 8px) | Done | `mesh_geometry.dart` |

See `docs/status-2026-06-30-box-selection-report.md` for the full account of
the three box-selection methods tried, their results, and the user's
on-device feedback at each stage.

---

## Bugs 1–7 (commit `5421e68`)

Fixed seven bugs found in the original Prompt A implementation (`0f32a0d`):

- **Bug 4/5 — one-sided face highlights.** `triangleHighlightBuffers` (in
  `mesh_geometry.dart`) now emits each input triangle twice — once with its
  original winding, once reversed — so hover/selection face highlights
  render regardless of which side of a surface the camera is looking from.
  Works around flutter_scene/Impeller's back-face culling, which previously
  made some external faces never visibly highlight. `mesh_geometry_test.dart`
  was updated to expect 6 vertices / 12 indices per pair of input triangles.
- **Bug 6 — cursor crosshair visibility.** `_CursorCrosshairPainter` now
  draws a dark outline stroke (width 4) underneath the coloured inner stroke
  (width 2), so the crosshair stays visible against both dark and light
  backgrounds.
- **Bug 7 — perspective toggle documentation.** The View menu's Perspective
  `ListTile` shows an explanatory subtitle when the toggle is off, noting
  that flutter_scene 0.18.x only provides `PerspectiveCamera` (no
  orthographic camera), so the two settings currently render identically.
- **Bugs 1/2/3** (selection submenu/`containOnly`, deferred tap-commit
  timer, box-drag cursor tracking) were all in service of box selection and
  have since been **removed** along with the rest of that feature — see
  below.

---

## Box selection: two more fix attempts, then removal

Box selection (drag a rectangle to multi-select) went through two further
hit-test rewrites this session, each rejected by the user's on-device
testing:

1. **Frustum-plane rewrite** (`7d0f3da`) — replaced the original
   `_worldToScreen` projection with four frustum side-planes built from
   `screenPointToRay` corner rays. On-device result: *selected nothing at
   all*, at any zoom level.
2. **2D screen-projection rewrite** (`0755f6c`) — replaced the frustum-plane
   approach with direct camera-axis dot-product projection (the same
   approach `selection_hit_test.dart` already uses for single-tap
   hit-testing). On-device result: selected *something*, but unreliably —
   missed entities inside the box and/or included entities outside it.

Per explicit user instruction (*"Not robust enough to rely on. let's park it
for now... remove the box select from 3d view port for the time being.
revert to multi select."*), box selection has been **fully removed**:

- `part_viewport.dart`: removed `containOnly` (widget field/constructor
  param), all box-drag state (`_boxAnchor`, `_boxCurrent`,
  `_doubleTapDetected`, `_boxMinDragDistance`), the deferred-commit
  `Timer`/`dispose()` override, `_onDoubleTapDown`/`_finalizeBoxSelection`/
  `_cancelBoxSelection`/`_hitTestEntitiesInBox`, the `GestureDetector`
  double-tap wrapper around the `Listener` (reverted to a bare `Listener`),
  the box-selection overlay in `build()`, and the `_BoxSelectionPainter`
  class. `_onPointerEnd` reverts to its pre-box-select form: a tap (pointer-up
  under the travel threshold) calls `_commitSelection()` immediately, with no
  deferral.
- `part_toolbar.dart`: removed `containOnly`/`onContainOnlyChanged`
  (widget fields/constructor params) and the entire `_buildSelectionMenu`
  ExpansionTile (the "Contain Only" toggle and disabled "Selection Filter"
  placeholder), along with its call site in `build()`.
- `part_screen.dart`: removed the `_containOnly` field,
  `_onContainOnlyChanged` method, and both `containOnly:` prop-passing call
  sites (to `PartViewport` and `PartToolbar`).
- `test/part_viewport_test.dart`: removed the two box-selection-specific
  tests ("double-tap-then-drag... box hit-test" and "double-tap with no
  drag... commits no box selection"). The four remaining tests (orbit-mode
  drag, selection-mode cursor reset, empty-space-clears-selection, drag-past-
  threshold) are unaffected and still exercise the now-restored immediate
  tap-commit path.

The result is the original Fix-4 single-tap-toggle selection model: each tap
on an entity calls `onSelectionToggle`, which `PartScreen` accumulates into
its `selectedEntities` set — i.e. "multi select" via repeated taps, with no
box, no double-tap, and no `containOnly` toggle.

---

## Selection-highlight visual tweaks

- **Selected-edge colour.** `_syncSelectedEntityNodes()` in
  `part_viewport.dart` now renders selected edges in a new, darker blue
  (`_selectedEdgeColor`, `#0D47A1`, Material Blue 900) instead of sharing
  `_selectedColor` (`#2196F3`, Material Blue 500) with selected faces and
  vertices — a selected line is now visually distinct from a selected face's
  tint. Hover highlights (`_hoverColor`, amber) and selected
  faces/vertices are unaffected.
- **Selected-vertex marker size.** `kVertexMarkerWidth` in
  `mesh_geometry.dart` reduced from `14.0` to `8.0` — shrinks the "fake dot"
  circle `buildVertexMarkersNode` draws for both hover and selected vertex
  highlights, per feedback that the highlight circle was too large.
  Consistent with the existing `kHighlightEdgeStrokeWidth` precedent (hover
  vs. selected states are told apart by colour, not size), this single
  shared constant was reduced rather than splitting it by state.

---

## Constraint compliance

All orbit handler bodies (`_handlePointerDown`, `_handlePointerMove`,
`_handlePointerEnd`, `_handlePointerSignal`) remain line-for-line unchanged
throughout this session's work, consistent with the constraint established
in `docs/status-2026-06-30-prompt-a.md`.

## Verification

No Flutter/Dart toolchain is available in this sandboxed environment
(`flutter analyze`/`dart analyze`/`flutter test` all report "command not
found"), so all changes in this document were verified by careful manual
code review and `git diff` inspection only, not by running the app or test
suite. The box-selection rewrites in particular were pushed without
device-side verification, which is part of why two iterations were needed
before the feature was parked — see
`docs/status-2026-06-30-box-selection-report.md`.
