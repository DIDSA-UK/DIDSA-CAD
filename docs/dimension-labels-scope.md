# Dimension labels: saved placement, one drag routine, no minus signs - scope

**Status:** built 28 Oct 2026 on `claude/flutter-desktop-mode-ui-pxmq0q` (P1 to P5; see "As built" at the end for what differs from this plan and what was not verified). Follows the mouse sketch-entity drag (`docs/desktop-input-scope.md`,
"Mouse drag of sketch entities"), which left dimension labels out in the 3D sketch view.

**Owner's decisions (28 Oct 2026):**

1. Label positions are saved **on the backend, with the sketch** (in the `.didsa` file), not in client-only file extras.
2. The minus-sign bug is fixed by **showing magnitude everywhere and keeping the sign internally**.
3. Moving a label is **not undoable** (not part of the undo stack).
4. Mouse label dragging in the 3D view is **folded into this rework**, not built separately first.

## 1. What is wrong today

### 1.1 Placement is two models, held in six session-only maps

| What the user moves | Held as | Where |
|---|---|---|
| any label, 2D canvas | raw screen-pixel offset, rescaled by the zoom it was set at | `SketchController._labelOffsets` + `_labelOffsetZoomReference` (`labelOffsetForZoom`) |
| linear, line-distance, angle label, 3D view | sketch-unit perpendicular offset, "along" offset, arc radius | `_linearAlongOffsets`, `_lineDistanceAlongOffsets`, `_angleAlongOffsets`, plus the perpendicular offset resolved from the pixel offset each frame |
| radius / diameter leader, 3D view | angle in degrees about the rim, leg length in sketch units | `_radialAngleOffsets`, `_radialLegLengths` |

- The 3D view cannot keep pixel offsets (they go stale when the camera orbits), so `PartViewport` converts the cursor to sketch
  units every frame (`part_viewport.dart` around line 6079, with the `onRadial/Linear/LineDistance/AngleLabel…Dragged` callbacks);
  the 2D canvas keeps pixels. The same dimension therefore has **two different positions**, one per view.
- None of the maps is serialised: the backend has no field for them (`backend/app/sketch/constraints.py`,
  `document/native_format.py`), so every label goes back to its default place when the sketch is closed or the app restarted.
- Moving a label is a drag-mode gesture only. A mouse cannot do it in the 3D view yet (the controller's `beginLabelDrag` is reached
  through the toggle's tap path).

### 1.2 The minus sign

- `LineDistanceConstraint` (and the point-line distance it uses) is **signed**: py-slvs's point-to-line distance takes the side of
  the line. A dimension on the "other" side stores a negative value and the label prints it.
- The label text is built by `c.distance.toStringAsFixed(2)` in about eleven places: `sketch_canvas.dart` (the linear, radial,
  diameter, line-distance, point-line and angle painters, about lines 3034 to 3478), `sketch_controller.dart` (the 3D overlay items,
  about lines 17747, 17834, 17923, and the ghost labels near 17974), and `GhostValueEditor`'s pre-filled text
  (`sketch_canvas.dart` about line 2302, `currentGhostValue`).

## 2. Target model

### 2.1 One placement per dimension, in sketch units

A `DimensionLabelPlacement` stored per constraint id, camera-independent, the same in the 2D canvas and the 3D view:

| Dimension kind | Parameters (sketch units unless noted) |
|---|---|
| linear / horizontal / vertical / line-distance / point-line | `offset` (perpendicular to the measured direction), `along` (position along it) |
| radius / diameter | `angle` (degrees about the rim), `leg` (distance from the circle) |
| angle | `radius` (of the arc), `along` (position along the chord) |

Unset parameters mean "use the default placement" (a new dimension, or a file saved before this change). Pixel offsets and the
zoom-reference map are removed; the painters convert placement to screen with the transform they already have.

### 2.2 Backend

- `Sketch` gets `label_placements: dict[constraint_id, dict[str, float]]`, **not** a field on every constraint subclass (about 20
  dataclasses; `_constraint_to_dict` uses `dataclasses.asdict`). A sibling map keeps the constraint classes untouched.
- Native format: written as `"label_placements"` next to `"constraints"` in each sketch dict, only when non-empty, read with
  `.get(..., {})`. Additive, so **no `SCHEMA_VERSION` bump** (the `component_patterns` and appearance precedent in
  `native_format.py`). An older client reading a newer file ignores the key.
- A placement is deleted with its constraint (delete, cascade delete, undo of creation) and copied with it where constraints are
  copied (sketch duplicate / import).
- API: `PUT /sketch/sketches/{id}/constraints/{cid}/label` with the parameter object (validated: known keys only, finite numbers),
  and `ConstraintResponse` gains an optional `label` object so a list call returns placements. `DELETE` clears one. It does not
  re-solve (the solver never sees it).

### 2.3 Client

- `ConstraintDto` carries `label`; `SketchController` holds `Map<String, DimensionLabelPlacement>` filled by the constraint list
  call and `adoptSketch`.
- A drag updates the controller map live (no network per move) and writes once on release (`PUT`), debounced if the same label is
  moved again within a moment. Not undoable (decision 3): the write does not touch the undo stack.
- The 3D overlay items (`ConstraintLinearDimensionItem` and siblings) are built from the placement; the pixel-based fields
  (`labelOffset`) and the six maps go.

### 2.4 One drag routine

- A single `LabelDragResolver` (pure, in `viewport3d/` or `sketch/`) turns "the pointer is at sketch-plane point P" into the
  placement parameters for the dragged dimension, per kind. The 2D canvas already works in sketch coordinates (its transform maps
  screen to sketch); the 3D view gets P from `hitTestSketchPlane` as the mouse grab already does.
- It replaces the camera-aware block in `PartViewport` (`radialDimensionAngleDegrees`, `projectRadialDimensionBasis`, the five
  `on…LabelDragged` callbacks) with plane-point maths, which also removes the "angle flips when the pointer crosses the centre" and
  grazing-angle jumps that come from resolving through the projected screen position.
- Entry: a mouse press on a label (found with `constraintOverlayItemAt` in 3D, `dimensionLabelAt` in 2D) and move past the tap
  threshold starts the drag; release ends it - the same press-drag-release shape as points and lines, and the same hook
  (`onSketchGrabStart/Update/End`, `_tryGrabAtCursor`). Touch keeps drag mode's tap-to-grab / tap-to-drop.

### 2.5 The sign

- One function `dimensionValueText(double value, {int decimals = 2})` returning the absolute value, used at every place in 1.2.
  Radius and diameter keep their `R` / `⌀` prefix; angles keep `°`. Angles are included on the assumption that a negative angle
  has no meaning to a user (**to confirm**).
- `GhostValueEditor` pre-fills the magnitude. On confirm the stored value is `sign(existing) × (typed text starts with "-" ? -1 : 1)
  × |typed|`: a plain number keeps the dimension on its current side; a leading minus flips the side. The flip is therefore
  invisible in the text, as decided; the side is seen in the model.
- No backend change and no stored-value migration.
- Also check: the ribbon's Edit Dimension value, any tooltip or status text that prints a constraint value, the AI plan summary if
  it prints sketch dimensions.

## 3. Phases

| Phase | Work | Size |
|---|---|---|
| P1 | **Sign fix.** `dimensionValueText`, every call site, the editor prefill and sign rule, tests. Independent of everything below and shippable first. | small |
| P2 | **Backend placement.** `Sketch.label_placements`, native format read/write, the PUT / DELETE endpoints, `ConstraintResponse.label`, deletion and copy handling, backend tests (round trip, absent key, delete with the constraint, bad keys). | medium |
| P3 | **Client model.** `DimensionLabelPlacement`, DTO and API client, controller map load / write, remove the pixel maps; painters and overlay items read placement. Default placement stays as it is today when unset. | medium-large |
| P4 | **Drag resolver and entry points.** `LabelDragResolver` with per-kind maths; 2D canvas and 3D view both call it; mouse press-drag-release on labels in both views; touch drag mode routed through it; remove the camera-aware block in `PartViewport`. | large |
| P5 | **Docs and device check.** Update `docs/desktop-input-scope.md`, `docs/roadmap.md`; Linux-build run of every dimension kind in both views, then a save / reopen round trip. | small |

P1 can go out alone straight away. P2 and P3 must land together (a client that writes placements needs the endpoint). P4 depends
on P3.

## 4. Tests

- **Backend:** native round trip with and without `label_placements`; older file loads; placement removed when its constraint is
  deleted; the PUT validates keys and finite numbers; export / import of a sketch in a part keeps them.
- **Unit (headless, no GPU):** `dimensionValueText` (negative, zero, rounding, `R`, `⌀`, `°`); the sign rule on confirm;
  `LabelDragResolver` per kind against known sketch geometry - drag to a point, read the parameters back, feed them to the layout
  function and expect the label at that point; zoom-independence and orbit-independence follow from there being no pixels in it.
- **Widget:** a mouse press-drag-release on a label moves it in the 2D canvas and, with a fake plane hit, in the 3D viewport's
  grab path; a label's placement survives rebuilding the screen from a fresh constraint list.
- **By hand (Linux build):** each kind (linear, horizontal, vertical, line-distance, radius, diameter, angle), both views, drag,
  release, orbit (position stays attached to the geometry), save, reopen.

## 5. Risks and open points

- **Default placement must not change.** Every painter has its own default; P3 must leave unset placements looking exactly as
  today (golden-style checks on the layout functions, not screenshots).
- **Pixel offsets in old sessions are lost anyway** (they never persisted), so there is nothing to migrate.
- **Perpendicular offset today is derived from the pixel offset.** Replacing it is the part of P3 most likely to need rework; the
  resolver tests in P4 cover the maths, the by-hand pass covers the look.
- **Sketch copies and patterns:** a derived (pattern or mirror) instance shows its source's dimensions? Not today, so no placement
  is needed; confirm when P3 reaches that code.
- **Angle sign:** see 2.5; ask before P1 ships if any angle is meant to read as reflex.
- **No undo** (decision 3) means a mis-drag is corrected by dragging back; revisit if testing says otherwise.
- **Backend change needs the backend suite and a server deploy** alongside the client; an older server returns no `label`, which
  the client treats as "no placement saved" (and its PUT fails quietly with a message, so positions simply don't persist there).
- A stronger model is not needed to plan this; the decisions that matter (save on the backend, sign rule, no undo) are already
  made. Reviewing P2's file-format change and P4's maths by someone who knows the solver is the useful second pair of eyes.

## 6. The VR client (`DIDSA-UK/DIDSA-VR`, read 28 Oct 2026; not run)

- **Backend changes are safe for VR and not needed by it.** The VR design table reads constraints as plain dictionaries
  (`scripts/design_table/sketch_session.gd`: `constraints[str(c["id"])] = c`, then `c.get(...)`), so an extra optional `label` on a
  constraint is ignored. `scripts/native_compose.gd` keeps each sketch dictionary as it is and re-posts it, so a saved
  `label_placements` key passes through VR's import / compose path intact. VR never calls the new endpoint. No schema bump.
- **Placement and dragging stay out of scope for VR.** It lays dimensions out itself (`scripts/design_table/dimension_layout.gd`,
  a fixed `DIM_OFFSET`) and has no per-dimension placement and no dragging. After P2-P4 VR keeps its default layout. Reading a saved
  placement in VR, and dragging labels in VR, would each be separate work in that repo.
- **The sign bug reaches VR.** `SketchSession.dimension_text` prints `format_value(float(c["distance"]))` with no absolute value for
  `line_distance` and `point_line_distance` dimensions. The ghost (candidate) dimensions already use `absf`, so only an existing
  signed dimension shows a minus. The fix is one `absf` in `dimension_text` (and a headless test in `tests/sketch_methods.gd`
  or `tests/sketch_session.gd`), in the VR repo, as its own commit. It needs no backend change.
- VR rules to follow there (its `CLAUDE.md`): read `docs/status.md` and `tests/README.md` first, add any new test file to
  `tests/run_all.sh` and the `tests/README.md` table, and say what was not verified (headless tests cannot judge the headset).

## 7. As built (28 Oct 2026)

Commits on `claude/flutter-desktop-mode-ui-pxmq0q`, in order: P1 (sign), P2 (backend), P3 + P4 (client placement and drag), P5 (docs). The VR sign fix is
on `claude/dimension-sign-fix` in `DIDSA-UK/DIDSA-VR`. Where the plan was silent or turned out wrong, the smallest sensible choice was made and is recorded here.

**Sign (P1)**

- `dimensionValueText` and `resolveDimensionSign` are in `client/lib/sketch/dimension_text.dart`. The label painters (2D and 3D overlay items), the edit-field pre-fill
  and the ribbon's Edit Dimension field all use it. Reference dimensions (`(12.5)`) were left alone: they are measured, never signed.
- **The "leading minus flips the side" rule has no effect on the backend today.** `PATCH .../constraints/{id}` for a line-distance or point-line dimension takes the
  side from the geometry's current side and stores `-abs(value)` or `abs(value)` (`update_constraint_value` in `backend/app/sketch/router.py`), whatever sign was sent. The
  client sends the resolved signed value as specified, so the rule is in place for when the server honours it, but a typed `-5` currently keeps the current side. Making
  the flip real is a backend change to that route (and a decision on whether flipping a side should move the geometry); it was not made here.
- Angles show their magnitude (plan 2.5, "to confirm"): done on the stated assumption. Nothing reads an angle as reflex.
- The AI plan summary, tooltips and status text were checked for printed constraint values: none print a signed dimension.

**Backend (P2)**

- `Sketch.label_placements` plus `live_label_placements()`. A placement is **not removed at each of the many places a constraint is deleted** (cascades, shape
  deletes, undo of creation all pop from `constraints` directly). Instead the placement of a constraint that no longer exists is ignored everywhere it is read: not
  written to the native format, not loaded, not returned in a response; the explicit `DELETE .../constraints/{id}` also drops it. Same outcome, one rule.
- Nothing in the backend copies a sketch's constraints (no duplicate-sketch route), so there was no copy handling to add; sketch export / import and the document
  native export go through `sketch_to_dict` / `sketch_from_dict`, which carry the key. A sketch import keeps the constraint ids, so its placements survive.
- `PUT .../constraints/{id}/label` returns 204 and accepts the known keys `offset`, `along`, `angle`, `leg`, `radius` (unknown keys 422, empty body 422). It does not
  check that a key suits the dimension's kind. A NaN or infinity cannot be refused over the wire with a clean 422 (FastAPI fails to encode its own error body for any float
  field in this app); the model refuses them (tested there) and the app's clients cannot send one.

**Client (P3, P4)**

- Placement semantics (all sketch units): see `LabelDragResolver`'s doc comment. They are the 3D view's existing sketch-local fields, with two changes. The general
  linear dimension's offset is along the left-hand normal of A to B **in sketch space** (it used to be along a screen-canonical normal whose sign could flip as the camera
  orbited), and horizontal / vertical `along` is the distance in the axis's positive direction (the painters apply the A/B order themselves).
- **Angle placement is exact, unlike the old drag.** `radius` and `along` are the two coordinates of the label's position in the frame (middle of the rays, chord), so the label
  lands under the pointer. The old drag took the radius from the distance to the vertex and the along from a projection, which put the label slightly off the pointer.
- **Pixel offsets stay for the relationship glyphs only** (V, H, parallel, perpendicular, equal, collinear, coincident, fixed, point-on-...). They are not dimensions,
  have no placement, are not saved, and are moved by the existing `updateLabelDrag` pixel path. `labelUsesPlacement(id)` says which is which. The plan said the
  pixel maps and the zoom reference go; for dimensions they have, for glyphs they remain.
- **The flat canvas keeps its pixel layouts and converts.** Rather than lay every kind out a second time, `dimensionLabelPixelOffset` (`sketch_canvas.dart`) turns a placement into the
  pixel offset each painter and `_constraintLabelCenter` already take. An unplaced dimension gets zero offset, so the defaults are exactly as before. One consequence: the
  painters' 6 px floor on a dimension line's distance from the geometry still applies, so a placement within 6 px of the geometry is drawn at 6 px.
- **The 3D painters lay a placed dimension out in sketch space and project it** (general linear, line-to-line, radius / diameter, angle), so the label lands exactly where it was
  dropped from any camera. An unplaced dimension keeps the old pixel defaults in both views, so the two views' *defaults* still differ from each other; they agree once a
  label has been moved or a file with saved placements is opened.
- A placed label of an angle whose lines are parallel (or, in the flat canvas, meet implausibly far away) cannot be moved: there is no arc to place, and the plain-chip
  fallback keeps its old (unsaved) pixel offset behaviour only if that was already set. A radius / diameter label dragged exactly onto the circle's centre is ignored for that move.
- Writes: one `PUT` when the drag is released (`endLabelDrag`), serialised per label (a second release while the first write is out is written after it). A failed write (for example an
  older server without the route) leaves the placement in the session and sets `errorMessage`. A refresh never overwrites a placement being dragged or written.
- Ghost (not yet confirmed) dimensions are not draggable and take no placement, as before.
- **Mouse in the flat canvas:** a press on a label with no entity nearby used to start a box select (the marquee check ran first). It now starts the label drag
  (`_marqueeMayStartAt(byMouse: true)`). Touch is unchanged there.
- **Mouse in the 3D view:** `PartViewport.onSketchLabelGrabStart` (new) is tried before the point / line grab on a press that passes the tap threshold; the moves and the
  release use the existing `onSketchGrabUpdate` / `onSketchGrabEnd`. `onConstraintOverlayItemTap` now also passes the plane point under the label, which touch drag mode uses.
- **Touch:** drag mode still taps to grab and taps to drop. A dimension label now follows the on-canvas cursor (scaled by the touch sensitivity, like a point) instead of
  the raw finger delta. Glyph labels keep the raw finger delta.
- Removed: the six sketch-unit maps and their setters, the 3D view's `onRadial/Linear/LineDistance/AngleLabel…Dragged` callbacks and `draggingConstraintLabelId`,
  `radialDimensionAngleDegrees` and `projectRadialDimensionBasis` (and their tests). `canonicalPerpendicular` is still the default for an unplaced general linear dimension.

**Tests added:** `test/dimension_text_test.dart`, `test/label_drag_resolver_test.dart`, `test/dimension_label_placement_canvas_test.dart` (every kind, three zooms),
`test/dimension_label_placement_3d_test.dart` (every kind, three cameras, a simulated mouse press-drag, orbit independence), `test/sketch_canvas_label_drag_test.dart`
(real mouse and touch gestures on the flat canvas), the label group in `test/sketch_controller_test.dart` (live drag, grab offset, no undo, release writes once, reload from the
constraint list, older server, delete), and `backend/tests/test_dimension_label_placements.py`.

**Not verified:**

- No device, no headset, no Linux-build run of every dimension kind in both views (P5's hand check) and no save / reopen round trip through a running app. The backend round trip is
  covered by tests; the client side of it by the fake-backend test above.
- The 3D viewport's own pointer path (`PartViewport._beginMouseGrab`, `_overlayItemPlanePoint`) cannot mount without a GPU here, so it has no widget test. Its maths is covered by
  `dimension_label_placement_3d_test.dart` (the same projection, hit-test and plane steps in a simulated press-drag with an orthographic camera); a perspective camera and the
  real event wiring were not driven. The embedded sketch screen's handlers (`_handleEmbeddedLabelGrabStart`, drag-mode tap) likewise.
- Touch drag mode in the 3D view was not exercised on a screen; the flat canvas's touch path has a widget test.
- Backend: the suite was run without the `bevel_pair` modules (the slowest, untouched by this change).

## 8. Review of the as-built work (28 Oct 2026)

Checked: the full Flutter suite (3249 passed, 43 skipped), `flutter analyze` (only `material.dart` infos), the backend suite, a Linux debug build
(a dimension created and dragged by mouse in the flat canvas and in the Orbit View; the placement was in the backend's native export as
`label_placements`; importing that export into a fresh session returned it on the constraint list; re-entering the sketch drew the label
at the saved place). Not run: a device, a headset, touch, the VR repo's Godot suite (no Godot here; its change is two lines plus one test).

- **Typed minus.** The server's value `PATCH` for a line-distance or point-line dimension has always taken the side from the geometry
  (`_signed_line_distance_value`, from the Phase 4 re-attach work), so a typed `-5` never flipped a side, before or after this work. The
  "leading minus flips the side" rule in section 2.5 was a wrong assumption of the plan, not a regression. The client still sends the
  resolved sign; it is ignored. With magnitude-only labels, the simplest honest behaviour is that the edit field takes a magnitude and a
  minus is ignored; flipping a side, if wanted, needs its own control. Not changed.
- **Press on a label next to a glyph.** In the flat canvas a press on a dimension's text that was within reach of its sibling glyph (the H
  next to a horizontal line's dimension) picked up the glyph, because `dimensionLabelAt` returned the first match in the constraint map.
  It now returns the nearest label within reach (test in `dimension_label_placement_canvas_test.dart`).
- **Stale placements after a delete** are filtered when read and when written (`Sketch.live_label_placements`), so they never reach a file;
  the cost is a few bytes held in memory until the sketch goes. Acceptable.
