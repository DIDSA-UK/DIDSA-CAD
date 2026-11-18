# Bug report 2026-11-18: investigation, fixes made, and plan for the rest

Source: tester report on the flat Flutter client (sketcher in the 3D viewport, desktop and touch). Four items: the sketcher's
hamburger menu, the angle dimension's "?" flag, the angle dimension's extension lines, and the clipped Visibility panel.

Written for a **follow-up implementation session**. Line numbers drift, so search for the named symbol. The fixes already made
are client only; the VR client (DIDSA-VR) has no angle-quadrant UI and no Visibility panel, so they need no VR change. The
planned parts C and D change the backend; their VR impact is noted in each.

Suggested order: A (dimension flow), B (tree in the sketcher), then D (one type per commit) and C (C1, C2, C3). A and B are
client only; C and D are mostly backend.

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
`backend/app/sketch/constraints.py` and the reference-dimension kinds in `reference_dimensions.py`), compared with
SolidWorks' Smart Dimension. Default first. "Now" means the sketcher offers it today; "client only" means the backend
constraint already exists and only the sketcher needs to offer it; **D** means a new constraint type from part D.

| Selection | Options | Status |
|---|---|---|
| 1 line | **Length**, Horizontal length, Vertical length, Angle to horizontal | Length now; H / V client only (`DistanceConstraint.orientation` on the line's endpoints); angle to horizontal **D** |
| 1 circle | **Diameter**, Radius | now (default changes to diameter) |
| 1 arc | **Radius**, Diameter, Arc length | radius / diameter now; arc length **D** |
| 1 ellipse / elliptical arc | **Major radius**, Minor radius (and their diameters) | now |
| 2 points | **by cursor**: Horizontal / Vertical / Aligned | now |
| 3 points (pick the vertex first) | **Angle** at the first point (sector by cursor) | **D** |
| point + line | **Perpendicular distance**, Horizontal, Vertical (to the line's nearer end) | H / V / aligned to the nearer end now; perpendicular is client only (`PointLineDistanceConstraint`) and becomes the default, as in SolidWorks |
| 2 parallel lines | **Distance** | now |
| 2 non-parallel lines | **Angle** (sector by cursor) | now |
| point + circle / arc | **Centre distance** by cursor (H / V / Aligned), Minimum distance, Maximum distance | centre: client only (a point-pair dimension on the centre point); min / max **D** |
| line + circle / arc | **Perpendicular distance from the centre**, Tangent distance (nearest side), Far-side distance | centre: client only (`PointLineDistanceConstraint` on the centre); tangent / far side **D** |
| 2 circles / arcs | **Centre distance** by cursor (H / V / Aligned), Minimum distance, Maximum distance | centre: client only; min / max **D** |

Spline, text, a lone point and constraint selections have no dimension (as now). Rows marked **D** need the new constraint
types of part D: the drawer offers them once D has landed (A can ship first without them).

**Work items**

* `sketch_controller.dart`: a single pending dimension: `pendingDimensionOptions` (the table, from the selection),
  `pendingDimensionKind` (chosen in the drawer, else the default / cursor rule), `pendingPlacementFromCursor()`, and
  `dropPendingDimension()` (freeze, open the editor as `tapGhost` does). Keep `_ghosts` as a one-element list at first so
  `dimensionGhostOverlayItems` and both painters change little. New `GhostKind`s for perpendicular point-line and the
  centre-based options; `confirmGhostValue` creates the matching constraint.
* Both views send the dimension-mode commit click to `dropPendingDimension()` when a preview exists and the click is not on an
  entity: 2D, the `sketch_canvas.dart` tap handler; 3D, `sketch_screen.dart` `_handleEmbeddedSketchTap` (the ghost no longer
  needs `preferConstraintOverlayHitOnCommit`, since the label is at the cursor and must not catch the click).
* `SketchDimensionBar`: the option chips; the selected one highlighted; tooltip text when nothing is picked (as now). It is
  the same bar on phone and desktop (it is not gated by the layout), so one change serves both.
* Existing dimensions are untouched: dragging a placed label, editing an existing value, and the driven (reference)
  dimensions keep their current behaviour.
* Tests: controller tests per row of the table (selection → options and default; cursor → kind and placement; drop → editor
  open with the frozen values; confirm → constraint and placement saved); one widget test per view for click-to-drop.

Size: medium-large. Suitable for a Sonnet session with this section as the brief.

#### Notes from the implementation of A (2026-11-18)

* **One pending dimension.** `SketchController._ghosts` still holds the candidates, now called the *options* (`pendingDimensionOptions`,
  default first); `ghosts` returns only the previewed one, `pendingDimensionGhost` (the drawer's choice, else the cursor rule, else the
  first option). `tapGhost(key)` and `confirmGhostValue(key, ...)` still take any option's key, so the ribbon's Length / Radius /
  Diameter chips (`addRadiusDimensionFor`) still open the editor straight away, with no dropped placement.
* **Placement.** `pendingPlacementFromCursor()` / `ghostPlacement(ghost)` call `LabelDragResolver` (`linear`, `lineDistance`, `radial`,
  `angle`), so a dropped dimension and a dragged one agree; the angle's sector is the sticky one from fix 2a. `dropPendingDimension()`
  freezes the placement and the sector and opens the editor; `confirmGhostValue` writes the placement under the new constraint's id and
  saves it (`PUT .../label`) after the solve. An Ellipse axis is previewed tip to tip (as it is drawn once confirmed) and placed with the
  linear rule on those tips.
* **Where the click goes.** `_handleDimensionTap` drops when nothing is under the cursor and a preview exists; a click on another entity
  still changes the pick, and with nothing previewed the old rules hold (clear the pick, then leave the tool). With the editor open a
  click away from it cancels the edit (2D `_dispatchTap`; 3D `_handleEmbeddedConstraintOverlayTap`, which is now only asked while an
  editor is open, so the label at the cursor never catches the dropping click). Esc, right-click (both views) and
  `cancelDimensionStep()` go back one step: editor to preview, preview to picking. The Android back button was not touched.
* **Flat canvas.** The old private ghost layout (`_layoutGhost`, `_GhostLayout`) is gone. The preview is the controller's synthetic
  constraint (`ghostAsConstraint`) drawn by the very painters a confirmed dimension uses, with a "?" for the value; the editor anchors at
  the label centre those painters give.
* **The table.** Line: Length, Horizontal length, Vertical length. Circle: Diameter (default), Radius. Arc: Radius, Diameter. Ellipse:
  Major / Minor radius and diameter. Two points: Aligned / Horizontal / Vertical by cursor (above or below the pair's box: horizontal;
  left or right: vertical; inside or a corner region: aligned). Point + line: Perpendicular (a `PointLineDistanceConstraint`, the
  default), Horizontal, Vertical, Aligned to the nearer end; none when the point is an end of the line. Two parallel lines: Distance.
  Two other lines: Angle. Point / circle / arc against a point, circle or arc: centre distance by cursor (a point-pair dimension on the
  centre Point). Line + circle / arc: perpendicular distance from the centre. Not offered until part D: arc length, angle to
  horizontal, three-point angle, minimum / maximum / tangent / far-side distances.
* **Not done.** The Android back button; the third pick for a three-point angle (D).

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

### C. Convert Entities: real projection, from bodies and from other sketches

Owner, 2026-11-18: project properly onto the sketch plane, from any angle, and allow a whole sketch (picked in the tree) as the
source. SolidWorks does both: Convert Entities projects edges normal to the sketch plane, and a sketch picked in the
FeatureManager tree converts all of its entities.

**What is there today**

* Backend: `convert-entities/vertex|edge|face` (`document/router.py`, `_convert_body_vertex` / `_convert_body_edge` /
  `convert_body_face`) resolve a Body vertex or edge against `compute_part_bodies(part, excluded)` and keep it live through
  `ExternalVertexReference` (`sketch/models.py`), which `refresh_external_references` (`document/create_plane.py`) re-finds
  by topology signature on every rebuild. A curved edge is only handled when it lies **in** the sketch plane
  (`resolve_circular_edge_arc`, `resolve_full_circular_edge`, `resolve_full_elliptical_edge`); any other curved edge falls back
  to a straight **chord** between its end points. So body-edge convert is already "half done" in the same way: fixing
  projection fixes both sources at once.
* There is no reference kind for "entity E of sketch S".
* Client: `stageConvertVertex / Edge / FaceEdges` take `(bodyId, index)` only. Other sketches are drawn in the sketcher
  (`SketchScreen.otherSketchGeometries`) but cannot be picked.
* Reusable code: the Intersection curve (`document/curve.py`) already turns a sketch into real 3D OCCT edges in its own plane:
  `_profile_or_open_chain_wire` → `wire_for_profile` (`extrude.py`) / `wire_for_open_chain` (`loft.py`) with
  `resolve_sketch_basis`. That is exactly the "sketch → 3D edges" half. It is the part to reuse, but generalised: it needs
  **every** entity of the sketch (not one profile or one chain), keyed by entity id so each result can be traced back.
  The section / prism half (`_prism_shell`, `BRepAlgoAPI_Section`) is not needed. As the owner says it is lightly tested, so
  the new module gets its own tests and the curve feature's tests are run too.

**Design**

1. **`app/sketch/projection.py` (new), one function for both sources:** `project_edge_onto_sketch(edge: TopoDS_Edge, basis)
   -> list[ProjectedEntity]`. Takes the edge's 3D curve (`BRep_Tool.Curve` + its parameter range) and projects it along the
   sketch plane's normal with `GeomProjLib.ProjectOnPlane(curve, plane, normal, True)`, which is exact for conics. Then
   classify with `GeomAdaptor_Curve(...).GetType()` and convert into sketch-plane coordinates (`basis`):
   * line → Line; a line along the normal → a single Point;
   * circle → Circle / Arc (planes parallel);
   * circle seen at an angle → **Ellipse / EllipseArc** (the sketch has both entity types, `add_ellipse` / `add_ellipse_arc`);
     a circle seen edge-on → a Line (its extreme points);
   * ellipse → Ellipse / EllipseArc (or a Circle when the projection happens to be round);
   * B-spline, Bézier or anything else → a **Spline** through sampled points (`add_spline`, through-point interpolation;
     sample count from the curve's length and curvature, with a test that the max deviation stays under 1e-3 mm);
   * arc direction: the sketch's Arc / EllipseArc run counter-clockwise about the sketch normal (`Arc` docstring); a
     projection that reverses orientation (seen from behind) swaps start and end.
2. **Body edges** (`_convert_body_edge`): keep the existing exact in-plane paths (they carry live centre references), and
   replace the **chord fallback** with `project_edge_onto_sketch`. End points stay live vertex references as now. The
   projected curve's shape (an ellipse centre, spline through-points) is pinned like today's converted ellipse (Fixed), and
   is recomputed in `refresh_external_references` from the same edge reference so it follows the body (new
   `ExternalVertexReference.kind = "projected_curve"`, or a sibling `ExternalCurveReference`, holding the edge's sub-shape ref
   and signature and the ids of the entities it made).
3. **Sketch sources**: new reference kind `sketch_entity` (source sketch feature id + source entity id). `sketch_edges(part,
   sketch_feature) -> dict[entity_id, TopoDS_Edge]` (new, generalising the curve code's wire builders to every entity,
   construction geometry included or not by a flag) gives the 3D edges; each goes through `project_edge_onto_sketch`. Points
   of the source (sketch points, a circle's centre) project as Points. On rebuild, `refresh_external_references` re-projects
   from the source sketch's solved geometry, so the copy follows; a deleted source entity is reported **lost** through the
   existing lost-reference path.
4. **Order**: only sketches earlier in the tree than the one being edited (`excluded_feature_ids_after`), or a rebuild could
   loop. The route refuses a later sketch with a message.
5. **Routes**: `POST .../convert-entities/sketch` with `{source_sketch_feature_id, entity_ids?: [...], construction,
   reference}` (all entities when `entity_ids` is absent); the response lists everything made, in the same shapes as
   `ConvertEdgeResponse` plus `ellipse_arc` and `spline`, which the edge route can now also return.
6. **Client**: Convert mode accepts (a) a sketch picked in the sketcher's tree (needs B) → whole sketch, and (b) picking the
   drawn entities of another sketch in the viewport (`otherSketchGeometries` made pickable in `PartViewport`'s convert
   filter) → those entities. Both stage into the convert bar like body picks and convert on Tick
   (`confirmConvertSelection`). `SketchApiClient` gets `convertSketchEntities`, and the edge response parser learns
   `ellipse_arc` and `spline`.
7. **Source content**: pattern and mirror instances are expanded first (`Sketch.expand_pattern_and_mirror_instances`, as the
   curve code does); Text entities are skipped with a note in the response (their outlines are not sketch geometry); points
   that belong to no entity are projected as Points; construction geometry is included only when asked (a flag on the route).
8. **Saved files**: the new reference kinds (`projected_curve`, `sketch_entity`) are written by `native_format.py`; a file
   without them is written exactly as before, and an older app opening a newer file is not a goal (as for earlier additions).
9. **Undo**: one convert can now make many entities. The client's undo for it is one step that deletes everything the call
   made (today each converted point pushes its own undo entry).
10. **VR client (DIDSA-VR)**: it calls `convert-entities/edge` for references (`part_references.gd`,
   `sketch_session.gd` ~1069). Today a non-coplanar curve comes back as a Line; afterwards it may come back as an ellipse,
   ellipse arc or spline. Check the VR handles those response shapes (or ignores them cleanly) before merging; no VR feature
   work is needed.

**Tests**: `projection.py` unit tests on real OCCT for every row of the classification list (a circle tilted 30° gives an
ellipse with minor = r·cos 30°; an edge-on circle a line; a helix segment a spline within tolerance; a reversed view swaps
arc ends); route tests for a body edge at an angle (before: chord; after: ellipse arc), a whole sketch on a parallel plane,
on a tilted plane, a later sketch refused, the source sketch edited then the target rebuilt (follows), a source entity deleted
(lost), a source with a pattern (instances converted) and with text (skipped), save and reopen (references still live); the
Intersection curve's existing tests still pass; client tests for staging a sketch / sketch entities and for one-step undo.

Size: large, mostly backend. Do it after B (the tree pick). Can be split: C1 projection module + body-edge chord replacement;
C2 sketch sources and route; C3 client picks.

### D. New dimension types (arc length, minimum / maximum and tangent distances, three-point angle, angle to horizontal)

Owner, 2026-11-18: add the missing ones. Each is a new backend constraint (and reference-dimension kind, for the driven
version), solved with what py-slvs 1.0.6 offers. Checked against the vendored SolveSpace fork's `src/swig/slvs_swig.hpp`
(submodule `tools/solvespace-reference/vendor`, commit 73a181b): it has `addArcOfCircle`, `addEqualLineArcLength`,
`addLengthDifference`, `addPointOnCircle`, `addDiameter`, besides what `solver.py` already uses.

Ground rules found in the code:
* The solver has **no arc or circle entities**: an Arc is three points plus a radius `DistanceConstraint` and an
  `EqualRadiusConstraint` (`models.py` `Arc`). New constraints must fit that model.
* Helper points are allowed: `solver.py` already makes solver-only points (`_fixed_ref_point`, the fresh-point path in the
  point adapter). Any helper must add **zero net DOF** (each helper point's 2 parameters are taken by exactly 2 equations),
  or the sketch's under / fully constrained colour breaks. Every new type gets a DOF test.
* Redundancy makes py-slvs distrust convergence (see the 2026-11-17 DOF fix): a new construction must not duplicate an
  equation the sketch already has.
* The client has its own constraint models: the drag projector (`sketch/projector/sketch_projector.dart`; a constraint it
  has no model for clamps the drag, `_clampDragFrame`, which is safe, so projector support can follow), `dof_analysis.dart`,
  the API DTOs and both painters.
* Constraints are found by the points they use: each type's `point_ids()` (`constraints.py`) drives the delete cascade (delete
  a point or entity → its constraints go) and the point merge (`sketch/point_merge.py`, client `point_merge_rule.dart`). A
  new type must list **every** sketch point it depends on (an arc length: centre, start, end; a circle distance: the centre and
  the radius point), never the solver-only helpers.
* The app does **not** contain the solver (`LICENSING.md`: AGPL / GPL decoupling). Solving happens only in the backend; the
  client's drag projector (`client/lib/sketch/projector/`) and `dof_analysis.dart` (a per-constraint-type DOF table) are the
  project's own pure-Dart models and need an entry for each new type. Write those from the maths in this plan and the HTTP data
  shapes, never by copying backend or SolveSpace code (`LICENSING.md` rule 1). `tools/solvespace-reference/` (GPL, test only)
  is where the SolveSpace API was checked; adding the new calls to its FFI shim is optional, only if the projector
  cross-check tests should cover the new types.

| Type | Entities | How it is solved | Notes |
|---|---|---|---|
| **Arc length** | 1 arc | For an arc carrying one: add a py-slvs `ArcOfCircle` (centre, start, end; counter-clockwise, which matches the sketch's Arc convention) and a helper Line between two **constant** points (a group that is never solved) whose length is the value, then `addEqualLineArcLength(helper, arc)`. | The `ArcOfCircle` entity itself keeps the end on the start's circle, so the arc's own `EqualRadiusConstraint` must be left out of the solve for that arc (else redundant). Value > 0 and < 2πr; a value the radius cannot meet fails as any conflicting dimension does. |
| **Angle to horizontal** | 1 line | `addAngle` between the line and the existing fixed horizontal reference line (`_horizontal_ref_line_handle`), with the same quadrant handling as the two-line angle (`angle_rays.dart` / `_angle_needs_supplement`). | Cheap; reuses everything from the angle work. |
| **Three-point angle** | vertex point + 2 points | Two solver-only line segments (vertex→p1, vertex→p2) on existing points (no new points, no DOF), then `addAngle` with the quadrant rule. | Drawn like the two-line angle with the vertex given. |
| **Minimum / maximum distance, point–circle** | point + circle / arc | Helper H on the line through the point and the centre (`point_on_line` on a solver-only segment), at the circle's radius from the centre (`equal_length` with the radius segment), then `distance(P, H) = value`. Minimum: H seeded on the point's side; maximum: the far side. | H: 2 params, 2 equations → 0 net DOF. After the solve, check H is still on the chosen side; if the solve flipped it, report not converged (as any wrong branch). |
| **Minimum / maximum distance, circle–circle** | 2 circles / arcs | H1 on the centre line at r1 from c1, H2 on it at r2 from c2 (each as above), then `distance(H1, H2) = value`. Seeds pick min (both inside the gap) or max (both outside). | 0 net DOF. Same side check. Overlapping circles: minimum is refused with a message. |
| **Tangent / far-side distance, line–circle** | line + circle / arc | Foot F of the centre on the line (`point_on_line` + `perpendicular` of segment centre→F with the line), H on segment centre→F at the radius (`point_on_line` + `equal_length`), then `distance(H, F) = value`. Tangent side: H between centre and line; far side: beyond the centre. | F and H: 4 params, 4 equations → 0 net DOF. |

Selection: the dimension tool keeps at most two picks today (`handleDimensionTap`: a third pick restarts the selection).
The three-point angle needs it to keep three when all three are points; any other third pick still restarts.

Out of scope: the AI modelling plan (`client/lib/ai/`, `backend/app/document/ai_plan*.py`) keeps its current constraint set;
it neither creates nor needs to read the new types (a sketch it edits that holds one is passed through unchanged; add a test).

Per type, the full set of changes: `constraints.py` (dataclass, `point_ids()`, `add_to_solver`, value update), `schemas.py` and the sketch
router (create / patch / response), `native_format.py` (saved and loaded; a file without the new types is written exactly as
before), `reference_dimensions.py` (driven kind and `measure`), the client DTO and
`sketch_api_client.dart`, the controller's ghost kinds and `confirmGhostValue`, both painters (canvas and 3D overlay), the
`LabelDragResolver` layout, `dof_analysis.dart`, the projector model (or the safe clamp until it has one) and the drawer rows of
part A. The VR client ignores constraint types it does not know
(`sketch_session.gd` `dimension_value` returns not-ok), so nothing breaks there; showing them in VR is a separate task.

**Tests**: per type, backend solve tests (value met, DOF count before and after, conflicting value refused, file round trip,
driven measure), the branch / side check for the helper-point types, and client tests (option offered for the selection,
create, label drawn in both views).

Size: large but regular; best done one type per commit, in the table's order (arc length first, as the owner named it). Can
run in parallel with A once A's drawer exists, or after it.

### Progress

| Part | Summary | Status | Commit |
|---|---|---|---|
| 1, 2a, 2b, 4 | Fixes above | Done | (this branch) |
| A | Dimension preview at the cursor, drawer, click to drop | **Done, client only** (every row marked "now" or "client only"; the D rows are left out, see "Notes from the implementation of A") | (this branch) |
| B | Feature tree in the sketcher | **Done, client only** (`SketchScreen.featureTreeBuilder` + `SketchReferenceSource`; `FeatureTreePanel.lockedReason`; see "Notes from the implementation of B") | (this branch) |
| C | Convert Entities: real projection, bodies and other sketches (C1 projection + body edges, C2 sketch sources, C3 client picks) | To do after B | |
| D | New dimension types (arc length, angle to horizontal, three-point angle, min / max / tangent distances) | **Done, backend and client** (six types, one commit each; see "Notes from the implementation of D") | 225ebd7, d4cfa24, 2bc694f, 5786134, 2334061, 6d4e299 |

### Notes from the implementation of B

- `SketchScreen` takes `featureTreeBuilder` (`Widget Function(BuildContext, VoidCallback onClose)`) and `referenceSource` (`SketchReferenceSource`, a `ChangeNotifier` holding the current `bodies` and `otherSketchGeometries`). `sketch-tree-fab` (top left, same tree icon) toggles the tree: phone, slides over the viewport (mounted only while open, 200 ms slide in, no slide out); desktop, a `DesktopLeftPane` beside the viewport (resizable). Closed by default. No builder, no button (the standalone 2D Drawing keeps its File button; if both exist the tree button sits to its right).
- Following changes: `PartScreen.build` calls `_pingSketchSource`, which after the frame hands the source the current `_visibleBodies` and the other sketches' geometry (this sketch's own entry left out) and notifies; `SketchScreen` rebuilds, so the tree and the sketcher's bodies follow a visibility toggle. The ghost outline (`referenceGhostSegments` / `Vertices` / `Edges`, projected when the sketch opened) is **not** refreshed: hiding a body in the tree does not remove its outline from the flat ghost, and dimension picks on it still resolve.
- Read-mostly: `FeatureTreePanel.lockedReason` ("Exit the sketch first"). Feature, plane-feature, body, surface and curve rows have no tap, long-press, right-click menu or multi-select, and show the reason as a tooltip (hover on a mouse, long press on touch). Each row has a Hide / Show eye (`onToggleVisibility`, `tree-visibility-<id>`) instead; the sketch being edited is highlighted and has no eye. The XY / XZ / YZ eyes work as before. `PartScreen._buildSketchTreePanel` builds it (not `_buildFeatureTreePanel`, so no picker or multi-select state can leak in); the eyes call `_toggleFeatureVisibility`, so they use the same saved-visibility path as the Part's tree.
- Tests: `test/sketch_screen_feature_tree_test.dart` (button only with a builder, phone overlay, desktop pane, source change rebuilds), `test/feature_tree_panel_test.dart` ("locked" group), `test/part_screen_test.dart` (opening a sketch from the Part: tree closed, then open, sketch highlighted, another row does not open, eye hides).

### Notes from the implementation of D

- **Types (wire names).** `arc_length` (`ArcLengthConstraint`), `horizontal_angle` (`HorizontalAngleConstraint`), `point_angle` (`PointAngleConstraint`), `point_circle_distance`, `circle_distance` and `line_circle_distance` (each with `side` "min" / "max"; for a line, "min" is the tangent side and "max" the far side). Driven kinds: `arc_length`, `horizontal_angle`, `point_angle`, and `min_distance` / `max_distance`, which take a point and a circle / arc, two circles / arcs, or a line and a circle / arc, in either order. Saved through the existing generic constraint list: a file without them is written as before.
- **Solving.** As the table, with two departures. Arc length: as planned (ArcOfCircle + `addEqualLineArcLength` on a fixed-group helper line; the arc's own end-radius EqualRadius left out, `solver.arc_entity_replaced_constraint_ids`); py-slvs only follows a small change of sweep, so a value edit turns the arc's free end to the new sweep before solving. Tangent / far side: one helper on the circle with its radius square to the line (`perpendicular` + `equal_length`) and a signed `point_line_distance`, instead of the foot point F plus H - same zero net DOF, one helper fewer, and no zero-length segment with the centre on the line. Angle to horizontal: quadrant bit 0 picks the end the angle is drawn at (the line's ray from there), bit 1 the horizontal ray (+x / -x).
- **Side check, generalised.** Every new type is a `MeasuredDimension`: after any solve that would be reported converged, `solver._measured_dimensions_hold` re-measures each one on the solved Points (pure geometry, `app/sketch/dimension_geometry.py`). A helper on the wrong side, or circles that came to overlap where a gap was asked for, read as not converged. This re-measure is what lets the new types sit in `_REDUNDANCY_SAFE_CONSTRAINT_TYPES` (needed: an arc whose centre and end are fixed with its radius dimensioned is result 5 with or without an arc length).
- **Client.** One pure-Dart module, `client/lib/sketch/dimension_types.dart` (value, label placement, a sketch-unit layout, create body), drawn by both the flat canvas and the 3D overlay (`ConstraintLaidOutDimensionItem`). Ghosts are `GhostKind.typed` with the constraint as a template; for the two angle types the pointer picks the quadrant (`dimensionFollowingPointer`) until a drop freezes it. Drawer rows: Arc length (arc), Angle to horizontal (line), Angle (three Points, the first the vertex: the dimension tool now keeps a third pick when all three are Points), Minimum / Maximum distance (point or circle with a circle / arc; "Minimum" only for circles that do not overlap), Tangent / Far-side distance (line and circle / arc; "Tangent" only while the line misses it). The projector has a residual for each (branch kept from the reference frame), so no type falls back to the safe clamp.
- **Not done.** The VR client: its `dimension_value` returns not-ok for the new types, and its delete cascade (`sketch_session.gd` `delete_cascade`) drops any constraint whose string fields name a doomed Point, which covers them; showing them in VR is separate work. The optional SolveSpace FFI cross-check (`tools/solvespace-reference`) was not extended.

