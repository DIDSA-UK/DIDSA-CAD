# Desktop sketcher feedback 2026-10-28 — diagnosis and plan

Source: first test report after the desktop layout and desktop input work (PR #314).
All four items are in Orbit View, the 3D view inside the sketch screen (`SketchScreen._buildBaseLayer`
embeds a `PartViewport`). Item 2 also affects the part screen.

This doc is for the implementation session. Code pointers were checked against `main` at `3494734`.
Line numbers drift, so search for the named symbol if a line is off.

| Item | Summary | Cause found | Confidence |
|---|---|---|---|
| 1 | Reset view FAB partly covered by the other FABs | Two top-right overlays at the same spot; desktop mode hid the FAB that used to cover one of them | Certain (read from code) |
| 2 | Orbit about the point under the mouse sends the model off screen | Pivot read along an unnormalised picking ray | Certain (read from code and `flutter_scene` 0.18.1 source) |
| 3 | Grid does not move properly when panning | The grid recentres on the view in cell-sized jumps, taking its fade and fill with it | High |
| 4 | Grid clips when orbiting | The grid is not part of the scene bounds the camera's depth range is fitted to | High |

Suggested order: **2 → 1 → 3 + 4** (3 and 4 are one change).

---

## 1. The Reset view FAB is partly covered

**Cause.** Two overlays are pinned to the top right of the 3D sketch view, both at `top: 8, right: 8`:

- `PartViewport`'s own **Reset view** `IconButton.filled` (`part_viewport.dart`, the `Positioned` with
  `tooltip: 'Reset view'`, around line 7162). It recentres and fits (`_doRecentre`).
- `SketchScreen`'s top-right FAB column (`sketch_screen.dart`, around line 943): Exit Sketch, Hide Reference Body,
  the Orbit/Cursor toggle and **Return to Default View**.

On a phone the Exit Sketch FAB is first in that column. It is the same 40 px size as the Reset view button and covered
it exactly, so nobody saw it. Commit `34edb2b` hides Exit Sketch in desktop layout (`!widget.standalone && !_desktopLayout`).
The column now starts with an 8 px spacer and the Hide Reference Body FAB at y = 16, so the Reset view button behind it
(y = 8 to 48) shows as a sliver.

The part screen avoids this because it puts its own top-right FABs at `top: 56`, under the button
(`part_screen.dart`, the comment on "move the select/orbit fab ... under 'centre view'").

**Fix.**

- Add `bool showResetViewButton = true` to `PartViewport`. `SketchScreen` passes `false`. The sketcher already has
  Return to Default View, middle double-click fit, F and the context menu's Zoom to Fit, and two reset icons a few
  pixels apart are confusing anyway.
- Drop the leading `SizedBox(height: 8)` in the column when Exit Sketch is hidden, so the column starts at the corner
  like the part screen's.

**Tests.** A widget test of `SketchScreen` in desktop layout with Orbit View active: no two of the top-right buttons'
rects overlap, and there is no `Reset view` tooltip. One more case for the phone layout. These need the 3D view, so they
may skip without a GPU like the other viewport tests. If so, test the column layout on its own.

---

## 2. Orbit about the point under the mouse sends the model off screen

**Cause.** `PartViewportState._orbitPivotAt` (`part_viewport.dart`, around line 5195) returns `ray.at(nearest.rayT)`.

- The ray comes from `Camera.screenPointToRay` (`flutter_scene` 0.18.1, `lib/src/camera.dart`). Its direction is
  `unproject(1.0) - near`, the whole near-to-far span, **not a unit vector**. `vm.Ray.at(t)` is `origin + direction * t`
  and does not normalise.
- The hit tests normalise before they measure. `hitTestFaces` does `ray.direction.normalized()`, and the edge and vertex
  tests do the same, so `rayT` is a distance in mm.

So the pivot lands `rayT × |direction|` along the ray instead of `rayT`. In orthographic mode (`PartViewport.isPerspective` defaults to false, and
the sketcher never sets it), `|direction|` is the widened depth range: about the scene's diameter plus 20 mm, often hundreds to
thousands of mm. The pivot ends up thousands of times too far behind the model, and orbiting about it swings the model
out of view. This is what was seen.

- It only happens over geometry. Over empty space there is no pivot and the camera orbits about its target, which works.
- After an extrude, or during the extrude preview, there is a body under the cursor, so the bad pivot is used.
- `OrbitCamera.orbitAboutPointByScreenDelta` itself is correct: its test passes a pivot directly.
- In the sketcher, the sketch plane and sketch entities are not pivot candidates. Over a bare sketch there is never a
  pivot.

The same mistake is in two other places:

- The section placement tap: `widget.onSectionPlacementTap!(ray.at(faceHit.rayT), ...)` (around line 4547). Clicking a
  face may place the new section plane far behind the model.
- The adaptive grid's perspective scale: `2 * hit.$2 * tan(fov/2)` in `_syncSketchPlaneGridNode` and
  `_refreshSketchGridForCamera`. `hitTestSketchPlane` returns `t` along the unnormalised ray. The orthographic branch
  is not affected. Item 3 removes this code.

**Fix.**

- Add a helper next to `hitTestSketchPlane`, for example `vm.Vector3 pointAtDistance(vm.Ray ray, double t)`, which
  returns `ray.origin + ray.direction.normalized() * t`. Use it in `_orbitPivotAt` and in the section placement.
- Alternatively, normalise once where the ray is built, in a small `_screenRay(Offset)` wrapper. That is the root
  fix, but every `rayT` consumer would need checking. Do the helper now and note the wrapper as follow-up.
- In the sketcher, add fallbacks to `_orbitPivotAt` when nothing else is hit: the nearest active-sketch entity, then
  the sketch plane itself (`hitTestSketchPlane` with `widget.sketchPlaneBasis`). Middle-dragging over the sketch then
  orbits about the point under the cursor, as it does over a body.

**Tests.**

- A unit test with a real `OrthographicCamera` from `orthographicCameraFor`. Hit a known plane, compute the pivot,
  orbit about it, and check the pivot projects to the same screen pixel before and after (within 0.5 px). Repeat for
  `FixedPerspectiveCamera`. This test fails on today's code.
- A unit test that `pointAtDistance` with a non-unit ray returns the hit point.

---

## 3 and 4. The sketch grid: jumps while panning, clipped while orbiting

**Today's grid** (`_syncSketchPlaneGridNode` / `_refreshSketchGridForCamera` in `part_viewport.dart`,
`buildSketchGridNode` / `sketchGridSpacingFor` / `snapToGridSpacing` in `sketch_geometry_3d.dart`):

- The cell size comes from a 1-2-5 ladder for the current mm per pixel.
- The grid is 40 cells across (`sketchGridHalfCells = 20`), so its size scales with zoom.
- It is centred on where the view centre meets the plane, snapped to the cell size, and rebuilt whenever that snapped
  centre changes.
- It fades over its outer 20 %. The translucent plane fill copies the grid's centre and extent.

**Cause of item 3 (jumps while panning).** The lines sit on multiples of the cell size, so they do not slide. But the
grid's square, its faded border and the fill behind it all jump one cell whenever the view centre crosses a cell
boundary. Lines near the border change alpha at each jump. While panning this reads as the grid stuttering instead of
moving with the plane. In perspective, the cell size also changes while panning, because of the scale bug in item 2.

**Cause of item 4 (clipped while orbiting).** The camera's depth range only covers the scene bounds: bodies, sketch
geometry and assembly instances (`_syncZoomBounds` → `OrbitCamera.setZoomBoundsForRadius`, widened in
`orthographicCameraFor`). The grid and the fill are not part of it.

- Orthographic zoom changes `halfHeight`, not `distance`, so the camera stays about 80 mm from its target however far
  out you zoom.
- Zoomed out, the adaptive grid is hundreds of mm across. When orbiting toward edge-on, part of it passes behind the
  camera and is cut by the near plane.
- With no bodies (`sceneRadius == 0`) the depth range is not widened at all.

**Fix (as the report suggests: a fixed grid).**

- The grid is a **fixed 100 × 100 mm square centred on the sketch origin**. It is built once per plane and never
  recentred, so it moves rigidly with the plane when panning or orbiting. Delete `_refreshSketchGridForCamera`'s
  recentring and `_sketchGridKey`'s centre fields. Keep only the camera-side rebuild for when the camera crosses the plane.
- The plane fill matches the same square, so the two never disagree.
- **Spacing** (recommendation, confirm below): 10 mm lines always, plus 1 mm minor lines (fainter) only when they are at
  least about 8 px apart on screen. Zooming changes whether the minor lines show. Panning and orbiting change nothing.
  That is at most 202 lines a side, about the same as today.
- **Larger sketches** (recommendation, confirm below): if the sketch geometry goes past ±50 mm, grow the square to the
  next multiple of 100 mm that covers it. It changes only when the geometry changes, never on pan.
- **No clipping:** in `_syncZoomBounds`, while `sketchPlaneBasis` is set, include the grid square's four corners
  (through `focusWorldTransformMatrix`, like the other bounds) in the scene bounds. The orthographic depth range then
  always spans the grid. `keepOrbitOutsideScene` also keeps the orbit sphere outside it, so the camera never sits inside
  the grid's extent.
- Remove the perspective `hit.$2` scale code (the item 2 bug) with the adaptive code.

**Tests.**

- `sketchGridLinesFrom` for a 100 mm fixed grid: 11 major lines a side at multiples of 10 mm, centred on the origin.
- Minor lines on and off around the pixel threshold.
- Growth: the half-extent is the furthest geometry coordinate rounded up to a multiple of 50 mm, at least 50 mm.
  Geometry at x = 130 mm gives a 300 × 300 mm square.
- A camera test: pan and orbit the camera, and the grid node's transform and line set do not change. This replaces the
  recentring tests in `test/` that cover `snapToGridSpacing` and `_refreshSketchGridForCamera`. Search for them and
  update them, do not delete them blindly.
- A clip test: an orthographic camera at distance 80 looking edge-on at the 100 mm grid with no bodies. Every grid corner
  is within `[near, far]` of `orthographicCameraFor`.

---

## Open questions for the owner

1. **Grid spacing:** 10 mm major plus 1 mm minor lines when zoomed in (recommended), or a single fixed spacing (which one)?
2. **Sketches larger than 100 mm:** grow the grid in 100 mm steps to cover them (recommended), or keep it at
   100 × 100 mm whatever the sketch size?
3. **Reset button in the sketcher:** hide the 3D view's own Reset view (fit) and keep Return to Default View (normal to
   the sketch plane), as recommended, or keep both, stacked?

## Not verified

- Flutter is not installed in the session that wrote this, so nothing here was run. Items 1 and 2 are read straight
  from the code and the `flutter_scene` / `vector_math` sources and are certain.
- Items 3 and 4 match the report and the code, but no grid was looked at on screen. The fixed grid removes both causes
  either way.
- If clipping is still seen after the fix while **bodies** are in view, look next at `effectiveNearClip` in perspective
  mode. It is not the cause in the sketcher, which is orthographic.
