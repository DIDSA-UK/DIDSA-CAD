# Sketcher feedback 2026-10-29: diagnosis and plan

Source: a test report from the flat app's 3D sketcher (Orbit View, the `PartViewport` embedded in `SketchScreen`), using
touch controls. Five items, two of them questions.

This doc is for the implementation session. Code pointers were checked against `main` at `8c8c40e`.
Line numbers drift, so search for the named symbol if a line is off. Nothing here has been run on a device. Each cause
was found by reading the code, and none was reproduced in a test.

| Item | Summary | Cause found | Confidence |
|---|---|---|---|
| 1 | A dimension label grabbed by touch jumps on the first move, and the cursor reappears somewhere unexpected after the drop | The grab offset is measured from the controller's cursor, which Orbit View's drag mode never updates | High |
| 5 | `isImplicitPolygonInscribedTangent` hides the inscribed circle's tangency to the polygon's own edges in `constraintOverlayItems` (so it is neither drawn nor tappable in Orbit View). A coincident to the origin is deliberately **not** hidden, as instructed; nothing changed for it | `sketch_controller_test.dart`: hex with reference circles has no Tangent overlay item; a user Tangent on the same circle to another line still shows. The fake backend now adds the inscribed tangent like `add_polygon` does |
| 2 | Zoom-scaled point snap (`pointSnapPixels` = 14 px, `_pointSnapRadius`, no `snapRadius` floor; flat `snapRadius` until a view reports a zoom). Both views report their zoom (`reportPixelsPerUnit`: flat canvas on every cursor move, touch included; Orbit View via `onDrawCursorMoved`/commit and `moveCursorToSketchPoint(pixelsPerUnit:)`). One resolver, `_resolveLineEnd`/`_lineEndTarget`, now feeds the ghost, `isHoveringChainStart`, `snapCandidatePointId`, `activeLineInference` and both Line commits: existing/first point at the raw cursor wins, then the inference-snapped end (closes the loop or lands on an existing point if within the radius), else a new point **at the snapped position**. Closing a loop adds Horizontal/Vertical when the closing edge is within `lineSnapAngleDegrees` (H/V only). Midpoint-method line free end uses the same resolver | `sketch_controller_test.dart`, group "line end snapping": close within the scaled radius, close via an H snap with the raw cursor outside the radius, free end created at the snapped position, zoomed-in radius shrinks, Orbit zoom report sets the radius, flat radius without a report. The old test "closing a chain loop ... never auto-snaps" asserted the behaviour the open question changes; it now asserts the Horizontal on the closing edge only |
| 3 | Alignment guides, **Line and Point first** (open-question answer: a snapping aid only, no constraint). `_alignToPoints` lines the cursor's x and/or y up with the nearest other point (7 px at the reported zoom; flat `snapRadius` until a zoom is reported), each axis independent, circle/ellipse cardinal points and the line's own start excluded. Priority: existing point/first point > tangent/point-on-curve > own H/V plus alignment (the line's own H fixes y, so only x aligns) > parallel/perpendicular/collinear (dropped when an alignment applies). Applied to a Line's free end (`_resolveLineEnd`), a Line's first point and the Point tool (`_placementTarget`); `activeAlignmentGuides` exposes them; `inferenceSuppressed` turns them off. Flat canvas paints them dashed in the H/V snap green; Orbit View cuts them into dashes (`alignmentGuideDashes`) and draws them through a new `PartViewport.drawAlignmentGuidePolylines` node in the same green | `sketch_controller_test.dart`, group "alignment guides": x alignment moves the Point-tool point and creates no constraint, both axes from two points, tolerance and `inferenceSuppressed`, a point snap beats alignment, a Line with its own H also aligns x and adds only the Horizontal, alignment beats parallel, dash helper. Three existing parallel tests had a cursor level with the target line's end point; their coordinates were shifted so they still test parallel rather than alignment |

**Item 3, remaining tools:** done through `_genericAlignment` (the tap and the ghost both use the aligned cursor; the raw cursor is left
alone while aiming). It covers the point-placing taps of Rectangle (all three methods; the third point of the three-point method
only measures a height, so it does not align), Circle (centre; the three-point method's three points; not the radius tap),
Arc (centre and start; not the sweep end), Polygon, Slot (both centres, not the width), Ellipse and EllipseArc (centre and
major point, not the minor radius), Spline, and the midpoint-method Line's anchor. Taps that only measure never align. Text is
left out. Tests: Rectangle corners with ghost agreement, Circle centre vs radius tap; the Arc/Ellipse/Slot/Polygon/Spline
cases share the same switch and are not tested one by one.
The look of the guide (colour, 7 px tolerance, 6/4 px dash) is untested on a device.
| 2 | Dropping a line chain's last point on its first point does not close the profile (with an inferred Horizontal) | Closing and point merging use a fixed 0.2 sketch-unit radius around the raw cursor. The H/V snap moves the ghost end onto the first point, but the raw cursor stays outside that radius | High |
| 2b | Should there be a Merge for two points? | Not built. Coincident already closes a profile for extrude | Question |
| 3 | No dashed alignment guide when the cursor lines up horizontally or vertically with another point | Not built in either client. The only H/V inference is a line's own segment against its own start point | Certain |
| 4 | Polygon with reference circles, then Select All, then Delete: server error "circle not found" | The cascade deletes the polygon (the server removes its reference circles with it) and then deletes the same circles again | Certain |
| 1 | The tap callback `PartViewport.onConstraintOverlayItemTap` now also passes the plane point under the cursor/tap; `SketchScreen` measures the label grab offset from that point with the new `embeddedLabelGrabOffset` (`sketch_geometry_3d.dart`) instead of `_controller.cursorX/Y`. The mouse grab path uses the same helper. No other stale `_controller.cursorX/Y` read exists in `sketch_screen.dart` | `dimension_label_placement_3d_test.dart`: grab with a deliberately stale controller cursor, label moves exactly with the finger from three cameras. The widget path through `SketchScreen` needs the GPU scene, so it is not covered |
| 5 | A hex polygon shows coincident and tangent glyphs. Are they part of the shape? | Tangent: the inscribed circle's built-in tangency is not hidden as implicit. Coincident: probably the centre placed on the origin, which is a real relation | Tangent certain, coincident likely |

Suggested order: **4 → 1 → 5 → 2 → 3**, with **2b** after them if it is wanted. Items 4, 1 and 5 are small and local. Item 2
adds the zoom-scaled snap radius, which item 3 needs too. Item 3 is a new feature.

## Progress

Implemented on branch `ccr-012a3702-zsqpvs`, one commit per item, in the order 4 → 1 → 5 → 2 → 3. Nothing has been looked
at on a device.

| Item | What landed | Tests |
|---|---|---|
| 4 | `computeDeleteCascade` drops a whole polygon's reference circles from `circleIds`; undo recreates the polygon with `referenceCircles` and reloads the circles (`_loadPolygonReferenceCircles`, shared with the Polygon tool) and maps their old ids to the new ones | `sketch_controller_test.dart`: the existing regression test now checks `errorMessage`; new cascade + undo test. The fake backend now removes reference circles on polygon DELETE and returns 404 for an unknown circle DELETE. No other test relied on the old lenient behaviour |

Item 2 notes. Item 2b (point Merge) is not built, as instructed. Not covered by a test: the midpoint-method line free end
(shares the resolver), and the Orbit View zoom plumbing past `moveCursorToSketchPoint` (needs the GPU scene). The pixel
value (14) and the "snapped position instead of raw cursor" change need a device to judge. The `activeLineSnapAxis` getter
is unchanged.

**Not verified (needs a device):** touch label drag feel (1), the 14 px point snap and 7 px alignment tolerances and whether the
snapped end position feels right (2, 3), the look of the guide in both views (3), and that the Orbit View guide node renders
(the viewport only builds with a GPU scene, which the tests here do not have). Everything above was checked by unit tests and
`flutter analyze` / `flutter test` in `client/` only. The backend was not changed; its suite was not run.

Open-question answers used: item 4 status code, checked against the real backend with a throwaway `TestClient` script
(create polygon with `reference_circles`, delete the polygon, delete its circle): **404** `{"detail":"Circle not found"}`.
The reported 422 was not reproduced here, so it may be how the client reports a failed request; no second error was found.
The partial (collapse) case from item 4 was not given its own test.

---

## 1. A dimension label grabbed by touch jumps, and the cursor comes back in the wrong place

**Path.** In Orbit View with touch, Select mode's drag toggle (`SketchScreen._dragModeActiveInOrbitView`) makes the viewport
run its draw cursor. A tap on a dimension label reaches `PartViewport._commitDrawCursor` (`part_viewport.dart` ~6092). That
hit-tests the labels and calls `onConstraintOverlayItemTap(hitId, labelPoint)`, which runs
`SketchScreen._handleEmbeddedConstraintOverlayTap` (`sketch_screen.dart` ~2255). Its drag-mode branch then does this:

```dart
return _beginEmbeddedLabelDrag(hitId, _controller.cursorX, _controller.cursorY, labelPoint);
```

`_beginEmbeddedLabelDrag` (~2197) sets `grabOffset = labelPoint - pointer`, so that the label keeps its place under the pointer.

**Cause.** `_controller.cursorX/cursorY` is not where the Orbit View cursor is. While drag mode is on,
`SketchScreen._handleDrawCursorMoved` (~2150) sends cursor moves to `updateGrabbedPosition` and **returns before
`moveCursorToSketchPoint`**, so the controller's cursor holds a stale value. That value is wherever the cursor last was in
a draw tool or on the flat canvas. The grab offset is therefore `label - stale point`, which can be any size. On the
first move, `SketchController.dragLabelToPointer` places the label at `real pointer + that offset`, and the label jumps.

The viewport's own cursor (`_cursorPosition`) keeps following the finger during the drag (drawing it is suppressed by
`suppressDrawCursor`). When the label is dropped the cursor is drawn again at the finger's real position, which is that
same wrong offset away from the label. That is the "cursor comes back in an unexpected location" part. Both symptoms
have the same cause.

The mouse path is not affected. `_handleEmbeddedLabelGrabStart` passes the real `pressPoint`. The flat canvas
(`sketch_canvas.dart` `_tryGrabAtCursor`) is not affected either, because there `controller.cursorX/Y` really is the cursor.

**Fix.**

- Pass the plane point under the cursor through the tap callback. Change `PartViewport.onConstraintOverlayItemTap` to
  `bool Function(String? hitConstraintId, vm.Vector3? labelPoint, vm.Vector3? cursorPoint)`. `_commitDrawCursor` passes
  `_drawCursorWorldHit`. The other call site (~5591, the selection-mode tap) passes the plane hit under the tap the same
  way.
- In `_handleEmbeddedConstraintOverlayTap`, convert `cursorPoint` with `worldPointToSketch` and give that to
  `_beginEmbeddedLabelDrag`. Fall back to a zero offset (null `grabOffset`) if it is null. Never use `_controller.cursorX/Y`
  in Orbit View.
- Check the same stale-cursor read in the same handler's other branches. Dimension mode does not use the cursor and Select
  only selects, so they look fine. Also grep `sketch_screen.dart` for `_controller.cursorX` in other Orbit View drag-mode
  code.

The point and line grabs are not affected. `_grabEmbeddedEntityAt` uses the world point it is handed.

After the fix, the label stays under the finger while it is dragged. On release the cursor reappears at the spot on the label
where it was grabbed. One exception: a radius or angle label whose resolver limits where it can go (`LabelDragResolver.radial`
or `.angle`) cannot follow the finger exactly, so the cursor can still end up off the label. That is acceptable and matches
how a point held by the solver behaves.

**Tests.** Pull the offset calculation into a pure helper (for example `embeddedLabelGrabOffset(basis, cursorWorld, labelWorld)`)
and unit-test it. Then add a controller-level test: `beginLabelDrag` with that offset, `dragLabelToPointer` at the same
pointer, and the placement should not change. A widget test through `SketchScreen` needs the GPU scene, so it would skip
here like the other viewport tests do.

---

## 2. Closing a line profile on its first point does not merge

**Path.** `SketchController._clickEndToEndLineTool` (`sketch_controller.dart` ~15624):

```dart
final closingLoop = isHoveringChainStart;
final inference = (!closingLoop && chainStart != null) ? _combinedLineInference(...) : null;
final endPointId = closingLoop ? _chainFirstPointId! : await _pointIdAtCursor(excludeId: ..., inferPointOnCurve: false);
```

**Cause.** There are two problems, and both apply here.

1. **The radius is tiny and does not scale with zoom.** `isHoveringChainStart` (~2995) and `_existingPointIdNear` (~5108, used
   by every draw tap's point merge through `_pointIdAtUntracked`) both test against `SketchController.snapRadius = 0.2`
   sketch units (mm). The comment on `snapRadius` (~1561) says that a zoom-scaled tolerance was set up
   (`hitRadiusForPixelsPerUnit`) but never connected to point snapping. `handleCanvasTap` gets a scaled `hitRadius` from Orbit
   View, but `_handleDrawTap` ignores it. At ordinary zoom, 0.2 mm is about one pixel.
2. **The test uses the raw cursor, not where the ghost shows the end.** The H/V snap (`_snappedLineEnd`, 4° tolerance)
   moves the ghost end onto the start point's horizontal. At 30 mm, 4° of tolerance allows about 2 mm of vertical error.
   So the ghost and the green H marker show the line ending on the first point while the raw cursor is still millimetres
   off it. The result is `closingLoop == false`, and `_existingPointIdNear(raw)` misses as well. A new point is created
   **at the raw cursor**, the Horizontal constraint is added, and the solve pulls the new point onto (or near) the first
   point. It ends up drawn as closed but with **two separate points and no coincidence**, so the profile is open.

Orbit View makes this worse. `moveCursorToSketchPoint` never updates `_lastKnownPixelsPerUnit`, so the pixel-based inference
radii (`_curveInferenceHitRadius`) use a stale zoom there too.

**Fix.**

- **A zoom-scaled point snap.** Add `double get _pointSnapRadius` built from pixels (`_curveInferenceHitRadius(pointSnapPixels)`,
  with a pixel value about the size of the cursor's hover ring; `minTapHitRadiusPixels` = 14 is a reasonable start). Two
  details. First, `_lastKnownPixelsPerUnit` defaults to 20, not "unknown", so in tests the radius becomes 14 / 20 = 0.7
  units instead of 0.2. Either make the zoom nullable and fall back to `snapRadius` until a view reports one, or go
  through the controller tests that place points 0.2 to 0.7 apart and expect no merge. Second, drop the `max(snapRadius, …)`
  floor that `_curveInferenceHitRadius` has for this use. Without that change the sub-millimetre fix below does not happen.
  Use it in `isHoveringChainStart`,
  `isHoveringOrigin`, `snapCandidatePointId` and the draw-tap path of `_existingPointIdNear`. Keep the plain `snapRadius`
  where a caller passes its own radius. This also removes the sub-millimetre corner merge that `snapRadius` was lowered to
  avoid, because zooming in makes the radius smaller.
- **Orbit View reports its zoom on every move.** `PartViewport.onDrawCursorMoved` gains the local pixels-per-unit (it already
  computes that for the commit, in `_localPixelsPerSketchUnit`). `SketchScreen._handleDrawCursorMoved` passes it on, and
  `moveCursorToSketchPoint(x, y, {double? pixelsPerUnit})` stores it in `_lastKnownPixelsPerUnit`.
- **A point snap beats an inference snap, and is tested where the ghost shows the end.** Add one resolver, for example
  `_lineEndTarget()`, returning the end position, an optional existing point id and an optional inference. The ghost
  (`activeDrawGhost`), the snap markers (`isHoveringChainStart`, `snapCandidatePointId`) and the commit all read it, so
  what is drawn and what is committed always agree. Order:
  1. The raw cursor is within `_pointSnapRadius` of the first point, or of another existing point: that point wins.
  2. Otherwise compute the inference. If the **snapped** end is within `_pointSnapRadius` of an existing point, that point
     wins, and so does the chain's first point (close the loop).
  3. Otherwise use the inference and create a new point **at the snapped position**, not the raw cursor. This is also
     cleaner, because the solve no longer has to move it.
- **When the closing edge is within the H/V tolerance, also add the Horizontal or Vertical constraint.** The user saw the H
  marker and expects it. Today a closing edge never gets an inference ("its slope is dictated by the loop"). Add it only
  for H/V, and only when the actual closing segment, first point to chain start, is within `lineSnapAngleDegrees`. A loop
  drawn H, V, H, V then gets a V on its last side, which leaves 4 DOF and is not redundant. **Open question:** confirm that
  the user wants this, and do not do it for parallel, perpendicular or tangent.
- Apply the same ordering to `_clickMidpointLineTool` (~15788) for its free end.

**Tests** (`sketch_controller_test.dart`). Draw three segments of a rectangle. Put the cursor 0.5 units above the first point
with a known zoom (where 0.5 units is less than `_pointSnapRadius`). `isHoveringChainStart` should be true, and the commit
should reuse `_chainFirstPointId`: the last line's `endPointId == firstPointId`, `points.length` should not grow, and
`chainInProgress` should be false. Repeat with the cursor outside the raw radius but with an H snap landing the end on
the first point: same result. With a large zoom (tiny radius), two corners 0.1 units apart should not merge (this
replaces the sub-mm rectangle reasoning in `snapRadius`'s comment). Add an Orbit View case in which
`moveCursorToSketchPoint(..., pixelsPerUnit:)` changes the radius.

### 2b. A Merge action for two points?

**Recommendation: yes, but as a separate, later change, and not needed to fix item 2.** Profile detection already joins
coincident points (`backend/app/sketch/profile.py`, `_coincident_canonical_ids`), so applying the existing **Coincident**
to the two loose points closes the profile for extrude today. Merge is about tidiness: one point instead of two plus a
constraint, simpler drags, one handle to select.

How it would work:

- It appears in the flyout when exactly two points are selected, next to Coincident.
- It needs a **backend endpoint**, for example `POST /sketches/{id}/points/{keep_id}/merge {"absorb": "<id>"}`. Entities do
  not have a client route that changes which points they reference, and doing it from the client would take many calls and
  not be atomic. The server moves every entity and constraint reference from `absorb` to `keep`, deletes `absorb`, and
  drops constraints that now collapse (a Coincident or Distance between the pair, H or V on a line between them).
- **It refuses** (422 with a reason) when the two points are the ends of one line or arc, which would give it zero length;
  when they are two defining points of the same Rectangle, Polygon or Slot; when either is a circle or ellipse cardinal
  point or a reference (projected) point. **The origin is never absorbed**: if one of the pair is the origin, the
  action does Coincident instead, following the existing rule in `_pointIdAtUntracked`.
- **Which point is kept:** the first selected, or the one with more references. It hardly matters, because both are at
  the same place after the solve.
- **Undo** cannot be the usual inverse API call. It needs a server-side unmerge or a sketch snapshot restore. Check
  whether the sketch file import (`router.py`, the "Invalid sketch file" route) can serve as a snapshot before building
  anything new.
- The VR design table uses the same backend, and can add the action later (DIDSA-VR `scripts/design_table/`).

---

## 3. Dashed alignment guides to other points

**Status.** This is not built. Searching both clients turned up nothing that aligns the cursor with *other* points. The
H/V that does exist is `_lineSnapAxis` / `_snappedLineEnd`, which compares only the segment being drawn with its own start
point. The only "guide" polylines are the polygon tool's reference circles (`ghostGuidePolylines`). The user probably
remembers the line's own H/V snap.

**Proposal (what SOLIDWORKS and Onshape call inference lines).**

- **What it finds.** While a draw tool is placing a point, look for an existing point whose x is within a pixel tolerance of
  the cursor's x (vertical alignment), and one whose y is within the tolerance of the cursor's y (horizontal alignment).
  For each axis, take the nearest point along the other axis. Candidates are line, arc and spline ends, centres, free
  points and the origin. Leave out circle and ellipse cardinal points and hidden reference points, which would add noise.
- **The snap.** Move the cursor's x and/or y onto the matched values. Both axes can apply at once, from two different
  points, which is the usual case when placing the last corner of an L or rectangle. This combines with the line's own H/V:
  an own-start H fixes y, and an alignment can then fix x.
- **Priority:** existing point > tangent or point-on-curve > own H/V plus alignment > parallel, perpendicular, collinear.
  `inferenceSuppressed` turns it off as well.
- **No constraint is created.** It is only a snapping aid, as in SOLIDWORKS's dotted inference lines. The user adds an H
  or V relation if they want one kept. **Open question:** confirm this with the user.
- **The visual.** A thin dashed line from the reference point to the snapped cursor, in the inference colour, on both the
  flat canvas and Orbit View. Orbit View needs a new dashed segment list on `PartViewport`, or `drawGhostGuidePolylines`
  extended with a style flag.
- **Tolerance:** about 6 to 8 px, through `_curveInferenceHitRadius`, which in Orbit View needs the zoom reporting from
  item 2.
- **Where it applies.** Do it in one place: an "effective draw cursor" that every draw tap and ghost reads. That is the same
  resolver as item 2's `_lineEndTarget`, generalised. Line, Point, the Rectangle corners, and the Circle, Arc, Polygon and
  Slot centres all benefit. If this is too wide for one pass, do Line and Point first.
- **Performance.** A linear scan of points on every cursor move is fine at sketch sizes (hundreds of points).

**Tests.** Controller: with a point at (10, 0) and the cursor at (10.3, 7) within tolerance, the effective cursor should be
(10, 7) and expose an alignment from that point. With two alignments, both coordinates snap. A point snap still wins.
`inferenceSuppressed` turns it off. A Line committed under an alignment has its end at the snapped x and no extra
constraint.

---

## 4. Select All then Delete on a polygon with reference circles: "circle not found"

**Cause.** In `SketchController.computeDeleteCascade` (~9193), the polygon block takes the polygon's edge and radial lines
out of `lineIds`, because the server's `delete_polygon` removes them. It **does not take the reference circles out of
`circleIds`**. `Sketch.delete_polygon` (`backend/app/sketch/models.py` ~2995) also deletes `circumscribed_circle_id` and
`inscribed_circle_id`. `deleteSelected` (~9940) deletes the polygon first (`cascade.polygons` loop) and then deletes
`circleIds` in its `shapesToDelete` loop. The first `DELETE .../circles/{id}` of an already-removed circle fails with
`Circle not found`. That comes from `_get_circle_or_404` in the router, so it should be a **404**, not the reported 422.
Reproduce against a real backend to confirm that this is the same error. If it really is a 422, there is a second error
behind this one.

The regression test that should have caught this, `bug fix: after deleting a whole Polygon (reference circles included)...`
(`test/sketch_controller_test.dart` ~5402), does not check `errorMessage` after the first delete. Its fake backend's circle
DELETE always returns 200, and its polygon DELETE does not remove circles, so the double delete never shows.

**Fix.**

- In `computeDeleteCascade`'s `for (final polygonId in polygonIds)` loop, also do
  `circleIds.remove(polygon.circumscribedCircleId)` and `circleIds.remove(polygon.inscribedCircleId)`.
- **Undo.** The undo restore at `for (final polygon in capturedPolygons)` (~10546) calls `createPolygon` without
  `referenceCircles`. Before this fix, the circles were captured as ordinary circles and recreated separately. After it they
  are not captured, so pass `referenceCircles: polygon.circumscribedCircleId != null` and add the returned circles to
  `circles` (copy the fetch from `_clickPolygonTool`). Otherwise undo loses them.
- The fake backend should behave like the real one. Polygon DELETE removes its reference circles, and DELETE of an unknown
  circle returns 404. Then add `expect(controller.errorMessage, isNull)` straight after the first `deleteSelected()` in
  the test above, and add an undo case: delete, undo, and both circles should be back. Check that other tests still pass
  once the fake returns 404, since some may rely on the lenient behaviour.
- Check the partial (collapse) case too: select one polygon edge plus the inscribed circle and delete. The circle goes on
  its own route and the polygon collapses. It should already work.

---

## 5. Should a hex polygon's coincident and tangent glyphs be visible?

**Tangent: no, hide it.** With reference circles on, `add_polygon` ties the inscribed circle to the first edge with a real
`TangentConstraint` (`inscribed_tangent_constraint_id`). It is part of how the shape is built, the same as the angle,
equal-radius and edge ties that are already hidden (`isImplicitPolygonEdgeTie`, `isImplicitEqualRadiusTie`). Orbit View
draws it because `SketchController.constraintOverlayItems` (~17677) has a `TangentConstraintDto` case (~17838) with no
implicit check. The flat canvas does not draw tangent glyphs at all (`sketch_canvas.dart`'s `_paintDimensionOverlays` has
no tangent case), so the two views disagree today.

Fix: add `bool isImplicitPolygonInscribedTangent(TangentConstraintDto c)`, true when `c`'s circle is some polygon's
`inscribedCircleId` and its line is in that polygon's `lineIds`. Identify it by membership, the same way the other
`isImplicit*` checks do. The client does not receive `inscribed_tangent_constraint_id`, and does not need to. Check it in
the tangent case of `constraintOverlayItems` and wherever Orbit View hit-tests overlay items, so that a hidden glyph cannot
be tapped. Test: place a hex with reference circles, then `constraintOverlayItems()` should contain no tangent item. A
TangentConstraint the user adds between the inscribed circle and another line still shows.

**Coincident: probably correct to show, but confirm with the user's case.** `add_polygon` makes no CoincidentConstraint.
The likely source is the centre (or the first vertex) dropped on the **origin**: `_pointIdAtUntracked` then creates a new
point and a real coincident to the origin (`_createPointCoincidentWithExisting`), on purpose, so that the shape can later
be freed from it. That relation is real, and every other tool shows it too. If the user placed the hex away from the origin
and existing points and still saw a coincident, it is a separate bug. Ask which point it was on, or reproduce: place a hex
with reference circles in empty space and list `controller.constraints` by type.

The remaining built-in constraints of the reference circles are already hidden: cardinal points (`isCardinalAxisConstraint`
and the same-centre equal radius), the circumscribed radius (it shares the polygon's provisional radius) and the inscribed
radius (provisional).

---

## Verification for the implementation session

- `flutter analyze` and `flutter test` in `client/` (what `client-verify.yml` runs). For item 2b, also the backend's
  pytest suite.
- None of these can be judged headless for feel: touch label drag (1), snap tolerance (2, 3) and the guide's look (3) need
  a device. Say so in the PR rather than claiming they work on a device.
- The DIDSA-VR design table talks to the same backend. Items 4 and 5 are client-only, and 2b adds a route. None of them
  changes an existing API, so VR is not affected.

---

## Handoff: what the next session should pick up

Items 1 to 5 landed (see Progress). Remaining, in the order I would do it:

1. **Point Merge (item 2b above).** Not built. Plan as written in 2b: backend `POST /sketches/{id}/points/{keep_id}/merge`
   with `{"absorb": id}` (moves entity and constraint references, deletes `absorb`, drops constraints that collapse), a
   client flyout action when exactly two points are selected, and undo last. Open points to settle first:
   - **Undo.** Server-side unmerge, or a sketch snapshot restore. Check whether the sketch-file import route
     (`router.py`, "Invalid sketch file") can serve as the snapshot before building anything new.
   - **Refusal list.** Check 2b's list against the real model code (a point shared by a pattern or mirror instance may add
     cases). Origin is never absorbed: do Coincident instead.
   - Backend pytest coverage for the refusals and the reference move, then the client action and its fake-backend mirror.
2. **Roll out to the VR client sketcher** (DIDSA-VR, same backend; `scripts/design_table/` uses the same routes). Items 4 and 5 are client-only
   and 2b adds a route, so VR is not broken by anything here, but it does not have these behaviours yet:
   - the zoom-scaled point snap and loop closing (item 2);
   - the end-resolved-where-the-ghost-shows-it rule: an existing or first point wins, otherwise the end is created at the
     snapped position, and closing within the H/V angle also adds Horizontal/Vertical;
   - alignment guides (item 3), as a snapping aid with no constraint;
   - Merge, once it exists.
3. **Add the other inferred relationships to the VR sketcher.** The flat/Orbit client infers, while placing a Line end:
   Horizontal/Vertical, parallel, perpendicular, collinear, tangent and point-on-curve (`_combinedLineInference` and
   `_applyLineInference` in `sketch_controller.dart`), plus concentric on Circle/Arc centres and point-on-curve for dropped
   points. Port the detection and the constraint creation, using the same backend constraint routes. Priority order to keep:
   existing point > tangent/point-on-curve > own H/V plus alignment > parallel/perpendicular/collinear.

Behaviour to carry across, because it is easy to miss: the snap radius is in pixels at the view's reported zoom (14 px points,
7 px alignment) with the flat 0.2 `snapRadius` only until a zoom is reported; circle/ellipse cardinal points and the line's own
start never act as alignment references; taps that only measure (radius, sweep end, width, minor radius) never align.

Still unverified on a device, so judge feel there before copying numbers: touch label drag, the 14 px and 7 px tolerances,
snapped-position line ends, and the guide's look. Item 4: the reported 422 was not reproduced (the real backend gives 404).
