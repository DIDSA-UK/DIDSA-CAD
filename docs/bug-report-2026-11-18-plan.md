# Bug report 2026-11-18: investigation, fixes made, and plan for the rest

Source: tester report on the flat Flutter client (sketcher in the 3D viewport, desktop and touch). Four items: the sketcher's
hamburger menu, the angle dimension's "?" flag, the angle dimension's extension lines, and the clipped Visibility panel.

Written for a **follow-up implementation session**. Line numbers drift, so search for the named symbol. Nothing here touches
the backend. The VR client (DIDSA-VR) was checked: it has no angle-quadrant UI and no Visibility panel, so it needs no change.

## Already fixed on branch `ccr-5fd5d437-1l26qn`

| # | Item | Root cause | Fix |
|---|---|---|---|
| 1 | Sketcher: the hamburger FAB holds only view options, sits alone top left | Historical: Stage 23f's menu panel, anchored to its own top-left button. | `sketch/sketch_screen.dart`: the hamburger is gone. A **Visibility** button (`sketch-visibility-fab`, eye icon, badge while the reference body is hidden) is the last button of the top-right FAB column, under Return to Default View, as the 3D viewport's Visibility sits under Reset view. The view-options panel opens beside that column (`right: 64`). The standalone 2D Drawing keeps Save / Open / Exit under a top-left **File** button (`sketch-file-fab`, standalone only). The top-left corner is now free for the feature tree (part B below). |
| 2a | Angle dimension: the "?" flag jumps back to its default side as the pointer reaches it | `SketchController._angleQuadrantUnderCursor` returns null (no side chosen, so the outward rays) whenever the cursor is within the tap band (14 px) of **either line's infinite extension**. The ghost arc is drawn at 32 px from the vertex (`_defaultAngleArcRadius`), so the flag at its middle is `32 * sin(angle / 2)` px from each line: inside the band for every angle under about 52°, and the chip's edges are inside it for much wider ones. Moving toward the flag therefore reset the sector and the flag moved away. | The chosen sector is now **sticky**: `_stickyAngleQuadrant` remembers the last sector for that line pair; inside the band (or on the vertex) it is kept, and only another sector's open area changes it. Reset when a new line pair is picked (`_buildLinePairGhosts`). Test in `sketch_controller_test.dart` (angle ghost group). |
| 2b | Angle dimension: the extension line is drawn over the sketch line when the arrowhead lands on it | Both painters drew the extension from the segment's **far** endpoint to the arc point, whatever the arc radius, so whenever the arc crossed the segment the line just covered the sketch line. | New `angleExtensionLineStart` in `sketch/angle_rays.dart`: none when the arc point lies on the drawn segment; beyond it, from the far end; short of it (between vertex and segment), from the near end. Used by `sketch_canvas.dart` `_paintAngleDimension` and `viewport3d/sketch_constraint_overlay.dart` `_paintAngleDimension` (screen space along the ray, valid under perspective). Unit tests in `angle_dimension_quadrant_test.dart`. |
| 4 | 3D viewport (desktop): the Visibility panel is clipped and the mouse wheel does not scroll it | Each row was a horizontal `SingleChildScrollView` in a card capped at 420 px. A mouse wheel sends vertical scroll, which a horizontal scroll view ignores, and a desktop mouse cannot drag-scroll by default, so the clipped buttons were unreachable. | `viewport3d/visibility_panel.dart`: new `wrap` flag; rows become `Wrap`s, so every button is shown. `part_screen.dart`: desktop layout passes `wrap: true` and widens the panel to `min(screen - 16, 760)`. The touch layout is unchanged: small panel, rows swipe sideways. Test in `visibility_panel_test.dart`. |

Verified: `flutter analyze` clean on every changed file; the whole client suite passes (`flutter test`: 4119 passed, 63 skipped),
including the updated `sketch_screen_orbit_view_test.dart` (Menu tooltip is now Visibility / File).
**Not verified (needs a person at the screen):** how the flag feels to chase and tap with mouse and finger, the look of the new
button column and panel position on phone and desktop, the extension lines on real sketches in both views.

## To do (plan)

### A. Dimension tool: place by click (SolidWorks / Onshape style)

**Recommendation: do it, for every dimension type, as one change.** Fix 2a removes the reported blocker, but the underlying flow
still asks the user to chase a small target whose position depends on the pointer. Today: pick entities, one or more "?" ghosts
appear (a point pair offers aligned, horizontal and vertical at once; a circle offers radius and diameter), the angle ghost moves
between sectors with the pointer, then the user must **tap the ghost's label** to open the value editor. The proposed flow:

1. Pick the entities (unchanged: `SketchController.handleDimensionTap`, `_dimensionSelection`, `_rebuildDimensionGhosts`).
2. **One** ghost follows the pointer. Its type and layout come from where the pointer is, using the same rules the label drag
   already uses, so a placed dimension and a dropped one agree:
   * angle: sector = `_angleQuadrantUnderCursor` (sticky, as now), arc radius and label position = `LabelDragResolver.angle*`
     from the pointer;
   * point pair / point-line: horizontal when the pointer is above or below the pair's bounding box, vertical when left or right of
     it, aligned when roughly perpendicular to the pair (SolidWorks' rule); offset from `LabelDragResolver.linear`;
   * parallel lines: distance, offset from `LabelDragResolver.lineDistance`;
   * circle / arc: diameter by default for a circle, radius for an arc (Shift or a ribbon toggle swaps); label angle and leg from
     `LabelDragResolver.radial`.
3. **A click anywhere drops it**: the placement (`DimensionLabelPlacement`) and, for an angle, the quadrant are frozen, and the
   value editor opens at the label, as `tapGhost` does now. Esc / right-click / back cancels to step 1.
4. Confirm writes the constraint with that placement (`confirmGhostValue` already saves quadrant; it must also store the
   placement under the new constraint's id, the way a label drag does via `_labelPlacements`).

Work items:

* `sketch_controller.dart`: replace the multi-ghost list with a single "pending dimension" whose kind is derived from the cursor
  (`currentPendingKind()`), and a `placePendingDimension()` that freezes kind, quadrant and placement, then opens the editor.
  Keep `_ghosts` as a one-element list at first so the painters and `dimensionGhostOverlayItems` change little.
* Both views route their commit tap in dimension mode to `placePendingDimension()` when a pending dimension exists and the tap
  is not on another entity: 2D `sketch_canvas.dart` tap handler; 3D `sketch_screen.dart` `_handleEmbeddedSketchTap` /
  `_handleEmbeddedConstraintOverlayTap` (with `preferConstraintOverlayHitOnCommit` no longer needed for ghosts).
* Touch: a tap is both "move the pointer" and "click", so on touch place on **release** after the drag cursor has moved, or keep
  a tap on the ghost label as the drop. Decide with the owner (question below).
* The ribbon's Radius / Diameter / Length chips (`addRadiusDimensionFor` and friends) keep jumping straight to the editor.
* Tests: controller tests per kind (cursor position → kind, click → placement saved with the constraint), a widget test per view.

Size: medium-large (controller state machine plus both views). Suitable for a Sonnet session with this section as the brief.

Questions for the owner before starting:
1. Touch: drop on finger release, or keep tap-the-label on touch and use click-to-drop only with a mouse?
2. Circle: diameter or radius by default?
3. Point pair: should the aligned / horizontal / vertical choice follow the pointer (SolidWorks), or stay as separate ghosts?

### B. Feature tree available inside the sketcher

The sketcher is a separate route (`PartScreen._openSketch` pushes `SketchScreen`), so the Part's `FeatureTreePanel` is not on
screen while sketching. The top-left corner is free since fix 1.

1. `SketchScreen`: new optional parameter `featureTreeBuilder` (a `Widget Function(BuildContext, VoidCallback onClose)`), so the
   sketcher does not need to know the tree's ~60 parameters. When given, a top-left FAB (`sketch-tree-fab`, the same tree icon
   `part_screen.dart` uses for its feature-tree FAB) toggles it: phone, sliding over the viewport as in `PartScreen`; desktop,
   a left pane beside the viewport (as `PartScreen`'s docked tree). The standalone 2D Drawing passes none and keeps its File button.
2. `PartScreen._openSketch`: pass a builder that returns `_buildFeatureTreePanel(docked: ...)` in a **read-mostly** mode: the
   sketch being edited highlighted; visibility toggles allowed (they change what the sketcher's `bodies` /
   `otherSketchGeometries` show, so `SketchScreen` must take these as a listenable or rebuild from a callback); actions that would
   change the feature list while the sketch is open (delete, reorder, rollback, edit another feature) disabled, with a tooltip
   "Exit the sketch first".
3. Tests: the FAB shows only when a builder is passed; tapping it shows the tree; an editing action is disabled.

Size: medium. Needs one decision: **which tree actions should work from inside the sketcher?** (Visibility only, or also
selecting a body edge / sketch to project or convert, which would be the most useful.)

### Progress

| Part | Summary | Status | Commit |
|---|---|---|---|
| 1, 2a, 2b, 4 | Fixes above | Done | (this branch) |
| A | Place dimensions by click | To do (questions open) | |
| B | Feature tree in the sketcher | To do (question open) | |
