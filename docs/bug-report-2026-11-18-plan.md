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

### A. Dimension tool: preview at the cursor, choose in a drawer, click to drop

Agreed with the owner (2026-11-18). Every dimension type, as one change, and all of it with the cursor: the mouse on desktop,
the cursor crosshair on touch (Orbit View's cursor mode, `_orbitCursorActive`; the flat canvas's own cursor), so there is no
separate touch gesture to design.

**Flow**

1. **Pick** the entities (unchanged: `SketchController.handleDimensionTap`, `_dimensionSelection`, `_rebuildDimensionGhosts`).
2. **Preview at the cursor**: one dimension of the current kind is drawn live, with its dimension and extension lines, and
   its "?" label sits at the cursor. Its layout comes from the cursor through the rules the label drag already uses, so a
   dropped dimension and a dragged one agree: `LabelDragResolver.linear` (offset), `.lineDistance`, `.radial` (angle, leg),
   the angle's sector from `_angleQuadrantUnderCursor` (sticky, fix 2a) and its radius / along from the angle resolver.
3. **Drawer**: at the same time the dimension bar (`SketchDimensionBar`, the existing non-modal fly-up, which already does not
   block canvas taps) lists the kinds that fit the selection (table below), the current one highlighted. Clicking another kind
   switches the preview; the cursor keeps placing it. Until one is clicked, the default in the table is used. For a point pair
   the default follows the cursor (SolidWorks' rule): horizontal when the cursor is above or below the pair's bounding box,
   vertical when left or right of it, aligned otherwise. Once a kind is clicked in the drawer it stays.
4. **Drop**: a click anywhere that is not another entity freezes kind, placement and (angle) quadrant, and opens the value
   editor at the label. `GhostValueEditor` (`sketch_canvas.dart`) already opens with the whole value selected, so typing
   replaces it; check it also takes keyboard focus at once in both views. A click on another entity still changes the
   selection (step 1) instead of dropping. Esc / right-click / back cancels the preview back to step 1.
5. **Confirm** writes the constraint with the frozen kind, quadrant **and placement**: `confirmGhostValue` already saves the
   quadrant; it must also put the placement into `_labelPlacements` under the new constraint's id (as a label drag does), so
   the dimension stays where it was dropped.

The ribbon's Length / Radius / Diameter chips (`addRadiusDimensionFor` and friends) keep jumping straight to the editor.

**Options per selection** (worked out from the code: `_rebuildDimensionGhosts`, the backend constraint types in
`backend/app/sketch/constraints.py` and the reference-dimension kinds in `reference_dimensions.py`). Default first. "Now"
means the sketcher offers it today; "client only" means the backend constraint already exists and only the sketcher needs to
offer it; "backend" needs a new constraint type, so it is left out of this part.

| Selection | Options | Status |
|---|---|---|
| 1 line | **Length**, Horizontal length, Vertical length | Length now; H / V client only (`DistanceConstraint.orientation` on the line's endpoints) |
| 1 circle | **Diameter**, Radius | now (default changes to diameter) |
| 1 arc | **Radius**, Diameter | now; arc length is backend, later |
| 1 ellipse / elliptical arc | **Major radius**, Minor radius (and their diameters) | now |
| 2 points | **by cursor**: Horizontal / Vertical / Aligned | now |
| point + line | **Perpendicular distance**, Horizontal, Vertical (to the line's nearer end) | H / V / aligned to the nearer end now; perpendicular is client only (`PointLineDistanceConstraint`) and should be the default, as in SolidWorks |
| 2 parallel lines | **Distance** | now |
| 2 non-parallel lines | **Angle** (sector by cursor) | now |
| point + circle / arc | **Centre distance** by cursor: Horizontal / Vertical / Aligned | client only (a point-pair dimension on the centre point) |
| line + circle / arc | **Perpendicular distance** from the centre | client only (`PointLineDistanceConstraint` on the centre) |
| 2 circles / arcs | **Centre distance** by cursor: Horizontal / Vertical / Aligned | client only; min / max (tangent) distance is backend, later |

Spline, text, a lone point and constraint selections have no dimension (as now). The owner may add to this table before the
work starts; anything marked backend is a separate task.

**Work items**

* `sketch_controller.dart`: a single pending dimension: `pendingDimensionOptions` (the table, from the selection),
  `pendingDimensionKind` (chosen in the drawer, else the default / cursor rule), `pendingPlacementFromCursor()`, and
  `dropPendingDimension()` (freeze, open the editor as `tapGhost` does). Keep `_ghosts` as a one-element list at first so
  `dimensionGhostOverlayItems` and both painters change little. New `GhostKind`s for perpendicular point-line and the
  centre-based options; `confirmGhostValue` creates the matching constraint.
* Both views send the dimension-mode commit click to `dropPendingDimension()` when a preview exists and the click is not on an
  entity: 2D, the `sketch_canvas.dart` tap handler; 3D, `sketch_screen.dart` `_handleEmbeddedSketchTap` (the ghost no longer
  needs `preferConstraintOverlayHitOnCommit`, since the label is at the cursor and must not catch the click).
* `SketchDimensionBar`: the option chips; the selected one highlighted; tooltip text when nothing is picked (as now).
* Tests: controller tests per row of the table (selection → options and default; cursor → kind and placement; drop → editor
  open with the frozen values; confirm → constraint and placement saved); one widget test per view for click-to-drop.

Size: medium-large. Suitable for a Sonnet session with this section as the brief.

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

Size: medium.

### C. Convert Entities from another sketch (picking a whole sketch in the tree)

Asked by the owner: would picking a whole sketch in the tree work for Convert? **Yes, it fits, and it is how SolidWorks
does it** (select a sketch in the FeatureManager tree, then Convert Entities takes all of its entities). But it is new work
on both sides, not just a tree pick, because today Convert only reads **Bodies**:

* Backend: the three routes `convert-entities/vertex|edge|face` (`document/router.py`) resolve a Body vertex or edge against
  `compute_part_bodies(part, excluded)` and store an `ExternalVertexReference` (`sketch/models.py`) that
  `refresh_external_references` (`document/create_plane.py`) re-finds by topology signature on every rebuild. There is no
  reference kind for "entity E of sketch S", and nothing that projects sketch geometry from one plane onto another.
* Client: `stageConvertVertex / Edge / FaceEdges` take `(bodyId, index)` only. Other sketches are already **drawn** in the
  sketcher (`SketchScreen.otherSketchGeometries`), but only as pictures: they cannot be picked.

What it would take:

1. Backend: a reference kind `sketch_entity` (source sketch feature id + entity id, or the whole sketch), resolved from the
   source sketch's solved geometry on every rebuild, so the copy follows when the source changes (associative, like the
   Body references), and reported lost when the source entity is deleted (the existing lost-reference indicator).
2. Only sketches **earlier in the tree** than the one being edited (`excluded_feature_ids_after` already defines that), or the
   rebuild order could loop.
3. Geometry: when the two sketch planes are parallel, lines, arcs and circles map one to one (shift and in-plane rotation);
   that covers the usual case (an offset plane, the same plane). Non-parallel planes turn circles into ellipses and need a real
   projection: refuse with a message in the first version.
4. Route `convert-entities/sketch` (whole sketch, optional entity id list); client: a tree pick in Convert mode (needs B) and,
   later, picking the drawn entities of another sketch in the viewport.

Size: medium-large, mostly backend. Do it after B. Open question for the owner: is "parallel planes only" acceptable for the
first version?

### Progress

| Part | Summary | Status | Commit |
|---|---|---|---|
| 1, 2a, 2b, 4 | Fixes above | Done | (this branch) |
| A | Dimension preview at the cursor, drawer, click to drop | To do (agreed 2026-11-18) | |
| B | Feature tree in the sketcher | To do | |
| C | Convert Entities from another sketch | To do after B (question open) | |
