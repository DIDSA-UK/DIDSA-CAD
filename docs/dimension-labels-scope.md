# Dimension labels: saved placement, one drag routine, no minus signs - scope

**Status:** planned 28 Oct 2026, not started. Follows the mouse sketch-entity drag (`docs/desktop-input-scope.md`,
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
