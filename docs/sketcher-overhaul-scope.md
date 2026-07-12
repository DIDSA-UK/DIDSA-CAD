# Sketcher Overhaul — Scoping Document

Companion to the "Sketcher tuning package" section of `docs/roadmap.md`.
That section captures the raw requirements; this document breaks them
into engineering workstreams against the *actual current implementation*
(verified by reading the code, not assumed), with proposed approach,
affected files, complexity/risk, and a suggested delivery order.

Client: `client/lib/sketch/*`, `client/lib/viewport3d/*`.
Backend: `backend/app/sketch/*` (FastAPI + py-slvs, SolveSpace's
Newton-Raphson constraint solver, wrapped by `solver.py`/`constraints.py`).

---

## Phase 1 — Interaction model fixes (client-only, no backend changes)

Highest value, lowest risk: all items live entirely in
`sketch_canvas.dart` / `sketch_controller.dart` / `sketch_screen.dart`
and don't touch the solver or data model.

**Status: implemented (1.1–1.6 below), pending on-device verification —
no Flutter SDK available in the dev environment this was built in, so
`flutter analyze`/`flutter test` could not be run here.** Each change
was reviewed by hand against the surrounding code and cross-checked
against the existing unit test suite's assertions (particularly the
hit-radius/midpoint tests in `sketch_controller_test.dart`, which
default `hitRadius` to `snapRadius` and so are unaffected by the
midpoint-radius fix below) - but this needs a real `flutter test` run
and on-device pass before merging. See the on-device checklist
delivered alongside this update.

### 1.1 Replace "double-tap/double-click to drag" with an explicit drag-mode FAB
**Implemented.** `SketchController.dragModeEnabled`/`toggleDragMode()`
added; `_tryStartEntityDrag` (`sketch_canvas.dart`) now gates on that
flag instead of the 350ms timing window, which is removed entirely
(`_lastTapTime`/`_doubleClickTimeout` deleted). New bottom-left FAB in
`sketch_screen.dart`, select-mode only, toggles the mode; icon fills
with the primary color while active. Implemented as a **sticky**
toggle (stays on until pressed again), matching every other tool-mode
button in this app, rather than auto-clearing after one drag - flagged
in the on-device checklist as worth confirming feels right.
- **Current state (before this change)**: there was no real double-tap gesture. A tap
  fires on pointer-up if travel < 10px (`sketch_canvas.dart:588-591`),
  and a *second* pointer-down within 350ms (`_doubleClickTimeout`,
  `:98`) over a draggable point is reinterpreted as a drag-start
  (`_tryStartEntityDrag`, `:420-440`). This 350ms window is exactly the
  reported false-positive source: select-tap immediately followed by a
  drag-intent tap gets misread as the second half of a click-drag.
- **Proposed approach**: add a persistent mode toggle FAB, bottom-left
  of the canvas (a new sibling to `sketch_speed_dial.dart`'s stack, or
  a small standalone `FloatingActionButton` positioned via
  `Alignment.bottomLeft`). While the mode is active, a single pointer-down
  on a hit-testable point starts a drag directly — no timing race, no
  second tap needed. Off, taps behave as plain select. Remove
  `_doubleClickTimeout`/`_tryStartEntityDrag`'s timing-based path
  entirely rather than layering the FAB on top of it, so there's one
  unambiguous drag-trigger path.
- **Files**: `sketch_canvas.dart` (gesture dispatch), `sketch_controller.dart`
  (mode state), new small widget or extend `sketch_speed_dial.dart`.
- **Risk**: low. Existing tests (`sketch_canvas_ghost_editor_test.dart`
  or similar) will need updating for the new trigger path.

### 1.2 Shrink point hit-radius / detach from the midpoint false-positive problem
**Implemented, plus the actual root cause of the midpoint false-positives
found and fixed.** `pointHitRadiusMultiplier` reduced 1.6 → 1.2 (first-pass
value, needs on-device tuning per the checklist). Separately - and this
turned out to be the real cause of "unintended selections of midpoints"
from the original roadmap notes, not just a radius-tuning question -
`_resolveSelectableAt` (the actual tap-to-select path) was calling
`_nearestLineMidpointId` with the full zoom-scaled tap radius instead of
the tight `snapRadius` every *other* midpoint check in the file already
uses (`hoveredLineMidpoint`, `_pointIdAt`). That meant a tap anywhere
along a line within the generous tap radius of its midpoint silently
converted into "materialize and select the midpoint" instead of
selecting the line - and disagreed with the hover indicator, which only
lit up when genuinely close. Fixed by matching the existing tight-radius
convention. This directly resolves the roadmap's separately-listed
"disconnect between hover/highlight and what actually gets selected...
unintended selections of midpoints" item, not just the point-hit-radius
item.
- **Current state (before this change)**: `minTapHitRadiusPixels = 14.0` (`sketch_controller.dart:274`),
  with an extra `pointHitRadiusMultiplier = 1.6` applied to points only
  (`:279`, used in `_entityAt`, `:814`) — so a point's *effective* radius
  is 22.4px, competing with nearby midpoint hit-testing
  (`_nearestLineMidpointId`, `:883`).
- **Proposed approach**: reduce `pointHitRadiusMultiplier` (needs a
  concrete number — recommend user-testing 1.0–1.2 rather than guessing)
  and/or add explicit priority ordering when a point and a midpoint both
  hit-test positive within the same gesture (endpoints should generally
  win over midpoints at equal distance, since midpoints are a derived
  convenience target). Since hover and tap-select already share one
  code path (`_entityAt`, confirmed unified — see `:862-871`'s own
  comment about a prior "bug-fix round 3" that fixed this exact
  divergence), no separate hover-vs-select reconciliation is needed here,
  just radius/priority tuning.
- **Files**: `sketch_controller.dart` only.
- **Risk**: low, but needs real device/finger testing to pick a good
  constant — this is a tuning task, not a structural change.

### 1.3 Confirm hit-radius zoom-scaling is already consistent (no code change expected)
- **Current state**: `hitRadiusForPixelsPerUnit` (`sketch_controller.dart:284-287`)
  already converts the fixed pixel radius through the live
  `pixelsPerUnit` zoom factor from `ViewTransform`
  (`view_transform.dart:15-28`, `sketch_viewport.dart:33-36`), and this
  is the *same* `pixelsPerUnit` used for rendering. On inspection this
  item from the roadmap notes appears to already be handled correctly.
- **Action**: verify on-device at extreme zoom levels (very zoomed in
  and very zoomed out) before assuming this is done — the `snapRadius`
  floor of 0.5 sketch-units (`:261`) could still feel inconsistent when
  heavily zoomed in, since the radius stops shrinking in screen-pixel
  terms below that floor. Worth a quick manual check rather than new
  engineering.

### 1.4 Auto-create coincident constraint when a point is placed/dropped on another point
**Implemented**, and widened slightly beyond the original scope once a
third instance of the same bug turned up: the 3-point circle tool's
circumcenter-derived centre point (`sketch_controller.dart`, near line
2959) had the exact same "raw `_api.createPoint`, no proximity check"
bug as the rectangle centre point. Both now share a new
`_autoCoincideIfNear(pointId, x, y)` helper (also used by the rewritten
`endPointDrag`) rather than duplicating the check three times.
- **Current state (before this change)**: this exists for the **point-placement tool** only
  (`_clickPointTool`, `sketch_controller.dart:2722-2754`, via
  `_existingPointIdNear` + `_api.createCoincidentConstraint`) — confirmed
  via on-device testing to be **missing everywhere else**. Two separate
  gaps found:
  - `endPointDrag` (`:1144-1163`) has no snap-and-constrain logic at all
    for dragging an existing point onto another.
  - Every other point-creating tool path goes through `_pointIdAt`
    (`:2990-3005`), which *silently reuses* a nearby existing point's id
    instead of creating a new one — no duplicate point, but also no
    constraint, which is usually fine (rectangle/line corners landing on
    shared points don't need a coincident constraint, they just are the
    same point) **except** for one confirmed bug: the rectangle tool's
    centre-tracking point (`_buildRectangle`, `sketch_controller.dart:3136`,
    used by `centreCorner` construction method) is created via a raw
    `_api.createPoint` call with **no proximity check at all** — tested
    placing a rectangle's centre exactly on the sketch origin and no
    coincident constraint was created, because this path never even
    looks for a nearby point.
  `CoincidentConstraint` itself is fully implemented server-side
  (`constraints.py:270-287`, `router.py:405-406`), so all of this is
  UI-glue, not new backend work.
- **Proposed approach**: standardize on `_clickPointTool`'s pattern
  (create the point, then check `_existingPointIdNear` and add a
  coincident constraint if found) as the one path every point-creating
  interaction uses when a *new, independent* point is involved — this
  covers `endPointDrag` and the rectangle centre point specifically.
  Leave `_pointIdAt`'s reuse-by-id behavior as-is for corners/endpoints
  that are meant to literally share a point (that's correct today, not
  a bug). Auto-adding a constraint the user didn't explicitly request
  should stay easy to undo.
- **Files**: `sketch_controller.dart` only (`endPointDrag`,
  `_buildRectangle`'s centre-point creation).
- **Risk**: low.

### 1.5 Global sizing pass (new item, added mid-implementation)
**Implemented.** Every point/line/label/highlight size in
`_SketchPainter` (`sketch_canvas.dart`) was scattered as inline magic
numbers - now centralized into named constants at the top of the class
(`_pointRadius`, `_pointRadiusEmphasis`, `_pointRadiusSelected`,
`_pointRadiusSnapping`, `_lineStrokeWidth`, `_lineStrokeWidthEmphasis`,
`_originHalfSize`/`_originHalfSizeSnapping`, `_dimensionFontSize`,
`_snapHighlightPointRadius`, `_midpointSnapIndicatorRadius`), each
shrunk from its prior value (e.g. point radius 4→3, selected 7→5, line
stroke 2→1.5, constraint label font 11→9.5). Deliberately kept separate
from the touch **hit**-radius constants in `sketch_controller.dart`
(1.2 above) - visual size and touch-target size are different
concerns; the hit-radius already sits well above the visual dot size on
purpose, for touchability. First-pass values, explicitly expected to
need re-tuning on-device (per the user's own framing of this request) -
centralizing them was done specifically so that re-tuning is a one-line
change per constant rather than a file-wide hunt.
- **Files**: `sketch_canvas.dart` only.
- **Risk**: low (pure rendering constants), but *will* need iteration -
  treat the current values as a starting point, not a final answer.

### 1.6 Traditional CAD-style dimension rendering (new item, added mid-implementation)
**Implemented** for the two dimension types that already had a real
two-extension-line-plus-offset-segment layout: `_paintDistanceDimension`
and `_paintLineDistanceDimension`. Added, per ISO 129/ASME Y14.5
technical-drawing convention: a small gap between the measured
point/line-midpoint and where its extension (witness) line starts
(`_extensionLineGap = 4.0`), a slight overshoot of the extension line
past the dimension line it meets (`_extensionLineOvershoot = 3.0`), and
solid filled arrowheads at both ends of the dimension line, pointing
outward and touching the extension lines (`_drawArrowhead`/
`_drawDimensionArrows`). The dimension label chip already paints last
(on top), which incidentally already gives the traditional "break in
the line behind the text" look without extra work.
- **Not touched, deliberately out of scope for this pass**:
  - `_paintPointLineDistanceDimension` (Point-to-Line distance) doesn't
    even draw a dimension line today, only a floating numeric label -
    a materially bigger change (needs the same layout work the other
    two already had) than "add arrows to an existing line," left as a
    follow-up.
  - The dimension-mode **ghost preview** (ghost ballooning/placement
    UI, `_layoutGhost` and friends around `sketch_canvas.dart:820-1002`)
    still renders as a plain dashed line with no extension-line-gap/
    arrowhead treatment - it's already visually distinguished (dashed,
    different color) as "not yet committed," so left alone rather than
    doubling the size of this change; worth revisiting if the
    plain-vs-decorated inconsistency reads oddly on-device.
  - Angle dimensions, and the H/V/parallel/perpendicular/equal/collinear
    glyphs, stay as simple text chips - they're annotations of an
    existing relationship, not a measured distance, so the
    extension-line/arrow treatment doesn't obviously apply the same way.
- **Files**: `sketch_canvas.dart` only.
- **Risk**: low - purely additive rendering, no layout values that
  existing callers depended on were removed, just extended.

---

## Phase 2 — Drag-solve semantics (client + backend)

**Status: implemented, pending on-device verification.**

### 2.1 "Dragged point stays put, others move to accommodate" during solve
- **Current state**: no pinning concept exists anywhere. `update_point`
  (`router.py:258-266`) is a raw coordinate overwrite with no re-solve.
  `endPointDrag` (`sketch_controller.dart:1144-1163`) only *then* calls
  a whole-sketch, unconstrained-in-that-sense `solve_sketch` (one-shot
  py-slvs batch solve, `solver.py:209-296`). The solver has no
  `fixed_point_id`/anchor parameter — the only entity that's ever hard-fixed
  today is the sketch origin (`_FIXED_GROUP`, `solver.py:79-97`).
- **Proposed approach**: add an optional `anchor_point_id` (or list) to
  `solve_sketch`, which temporarily adds that point to the fixed group
  (same mechanism already used for the origin) for that one solve call,
  then removes it. Wire `endPointDrag` to pass the just-dragged point's
  id as the anchor. This directly reuses an existing mechanism rather
  than inventing a new solver mode — the main risk is *which* point wins
  when the anchor conflicts with an explicit dimensional constraint on
  that same point (e.g. user dragged a point that has a fixed-length
  dimension to another point) — needs a documented fallback (likely:
  anchor loses to explicit numeric constraints, since those are
  intentional design values).
- **Files**: `solver.py`, `router.py` (pass-through param), `schemas.py`
  (request field), `sketch_api_client.dart`, `sketch_controller.dart`.
- **Risk**: medium — this is the first item that touches the solver's
  core contract, needs solver-level test coverage (`backend/tests/`)
  for the anchor-vs-constraint conflict case specifically.

---

## Phase 3 — Constraint visual feedback

**Status: 3.1/3.2 implemented, pending on-device verification.**

**Decided approach (superseding the earlier heuristic idea): client-side
structural DOF/rigidity analysis, computed live, no backend round-trip.**

Discussed and rejected: deferring actual position-solving to
sketch-exit (client edits fully local, backend `solve` only called on
close). Rejected because it doesn't solve the coloring problem on its
own (still need DOF analysis, which is a separate topological question
from *where points end up*), and it actively conflicts with Phase 2 —
the sketch would visually look "unsolved" (constraints not visibly
satisfied) throughout editing, then jump when the deferred solve
finally runs. Real numeric solving stays on the backend, per-edit,
unchanged.

What *does* move client-side: whether an entity is fully/under/over
constrained is a question about the **topology** of the constraint
graph (how many degrees of freedom each constraint type removes), not
about solved numeric positions — so it doesn't need py-slvs at all.
This is the same technique real parametric sketchers use internally
(2D bar-joint rigidity / "pebble game" style DOF counting) to report
constraint status independent of the solver actually running. The
client already caches the full points/lines/constraints graph locally,
so this can run instantly on every constraint add/remove/delete, with
zero network round-trip — strictly better than either the original
heuristic (which leaned on py-slvs's own admittedly-unreliable
`blamed_constraint_ids`, "most recently added," not a real diagnosis)
or a server round-trip per keystroke.

**Architecture rule**: this client-side DOF checker is advisory/UI-only
— it must never become a second source of truth. Anything that
consumes sketch state programmatically (a script, an AI agent driving
the backend API directly per the project's stated architecture —
`docs/project-brief.md` §6/§8, stateless server, client-holds-model,
API-first from Stage 1) reads the backend's own `SolveResult.dof`/
`converged` fields, which are unchanged by this work. Keep the two
concerns cleanly separated: backend `dof`/`converged` = authoritative
solve result; client rigidity check = fast local preview for the
person actively sketching.

### 3.1 Fully-constrained line/curve turns dark green
- **Current state**: no per-entity constrained/unconstrained flag
  exists anywhere; `SolveResult.dof` (`solver.py:26-57`) is a
  whole-sketch scalar only.
- **Proposed approach**: new client-side module implementing the DOF
  counting — needs an explicit, documented DOF-cost table per
  constraint type (coincident, horizontal, vertical, parallel,
  perpendicular, equal_length, angle, distance, at_midpoint, collinear,
  point_line_distance — the full list from `constraints.py:147-532`
  each remove a different, specific number of degrees of freedom, this
  is a real per-type analysis task, not a single constant), run over
  the cached local graph. Color a line/curve green once its
  entities have zero remaining freedom under this count.
- **Files**: new Dart module (e.g. `client/lib/sketch/dof_analysis.dart`),
  called from `sketch_canvas.dart` for rendering; a small, clearly
  isolated file — see the forking note below for why isolation matters
  here specifically.
- **Risk**: medium — real algorithm work (getting the per-constraint-type
  DOF costs right, including edge cases like redundant-but-consistent
  constraints), but no solver/backend risk and no round-trip latency
  concern.

### 3.2 Over-constrained entities turn red and disallow drag on their defining points
- **Current state**: no over-constrained detection at the entity level;
  py-slvs's own `Failed` list (`solver.py:264-268`) is documented as
  unreliable for root-cause attribution.
- **Proposed approach**: same DOF-counting module as 3.1 naturally
  detects the over-constrained case too (negative remaining freedom
  once a redundant constraint is added) — flag those specific
  entities/constraints red and disable drag on their points. This is a
  genuine improvement over the originally-floated heuristic, not just a
  cheaper version of it, since it's counting actual redundancy in the
  graph rather than guessing from "whatever was added last."
- **Files**: same new DOF-analysis module + `sketch_canvas.dart`
  (red rendering + drag-disable check).
- **Risk**: shares 3.1's algorithm risk; no separate backend risk.

**Fork note**: because this logic is a client-only duplication of
knowledge that also lives in the backend's constraint-type list, keep
the DOF-cost table in one small, explicitly-labeled file that documents
"must stay in sync with `backend/app/sketch/constraints.py`'s type
list" — cheap insurance for a future standalone fork where the two
could otherwise drift silently if the backend's constraint set ever
changes.

---

## Phase 4 — 3D context while sketching

**Status: 4.1 and 4.2 implemented together (see below); 4.3 v1 and v2 both
implemented (see 4.3's own section) - shipped as two separate, sequenced
rounds per the "no working checkpoint in between" risk this section
originally flagged, not bundled together.** An Orbit View toggle FAB
(`sketch_screen.dart`)
swaps the flat 2D `SketchCanvas` for a read-only, look-only `PartViewport`
embedding the Part's Body meshes (shaded, at a fixed ~25% transparent
opacity - direction (a) from 4.1's proposed approach) alongside this
Sketch's own geometry (via `sketch_geometry_3d.dart`'s existing
`sketchGeometry3DFrom`/`SketchPlaneBasis`). A second "Return to Default
View" FAB animates the embedded viewport's camera back to facing the
Sketch's plane via `PartViewportState.animateToPlane`, the same mechanism
the 3D viewport already uses for its own camera-into-sketch transition.
Editing stays 2D-only throughout - every edit-mode control (the ribbon,
mode pill, drag-mode FAB, construction/dimension bar, speed dial) hides
while Orbit View is active, and the toggle itself only appears once the
Sketch's plane resolves to one of the three fixed `ReferencePlaneKind`s
(a custom-plane Sketch has no `orientationFacingPlane` equivalent yet,
same limitation `_openSketchWithAnimation` already has). Body-edge
hit-testing/picking (4.1's "(a)" direction's other half) was not built -
nothing in this pass makes the rendered bodies selectable, since nothing
in 4.1/4.2's own ask needed it; that remains 4.3's territory.

**On-device bug-fix round (post-implementation)**:
- **Face-culling bug**: `bodyOpacity < 1.0` (Orbit View's own default, or
  the main 3D viewport's own Body Transparency slider) made whole
  back-facing triangles of a solid disappear rather than fade, because
  `flutter_scene`'s `Material.bind()` unconditionally back-face-culls any
  translucent (`AlphaMode.blend`) material regardless of the material's own
  `doubleSided` flag - the same quirk already documented (and fixed) for
  the flat reference-plane quad in `reference_planes.dart`, just never
  applied to real body mesh geometry until now. Fixed in
  `mesh_geometry.dart`'s `meshBuffersFromMesh`/`geometryFromMesh` (new
  `doubleSidedWinding` parameter, emitting a second reverse-wound,
  normal-flipped copy of every triangle) and wired into
  `part_viewport.dart`'s `_syncMeshNode` for any translucent body/preview
  material. Applies to the main 3D viewport too, not just the sketcher -
  this was a real, previously-latent bug, just made prominent by Orbit
  View's opacity-below-100%-by-default entry point.
- **Orbit View now offers the same View controls as the 3D viewport**:
  render mode (Shaded / Shaded + Edges / Wireframe), Body Colour, Body
  Transparency - added to `sketch_screen.dart`'s hamburger menu (a new
  "3D View" submenu, shown in place of the 2D canvas's own View submenu
  while Orbit View is active), reusing `PartToolbar`'s exact
  `showColourSwatchSheet`/`showBodyOpacitySheet` helpers. Defaults to
  `shadedWithEdges` (edges visible by default, per on-device feedback) and
  ~25% transparent (unchanged from 4.1's own ask).
- **Stable entry orientation**: entering Orbit View no longer snaps the
  camera to `OrbitCamera`'s own angled default view. `PartViewport` gained
  a new optional `initialViewPlane` parameter (set once, in
  `PartViewportState.initState`) that starts the embedded `OrbitCamera`
  facing the given plane exactly - matching what the flat 2D canvas was
  already showing - so the view only changes once the user actually
  orbits it themselves. "Return to Default View" is unaffected and still
  useful after the user has since orbited away from that view.

**Second on-device round**:
- **Orbit View transparency always resets to ~25% on entry**: previously
  `_orbitBodyOpacity` persisted across toggles within a session (whatever
  the user last set it to via the 3D View menu); now every fresh entry
  into Orbit View resets it to 4.1's default, matching the "temporary
  inspection mode" framing - a session shouldn't carry state forward
  unpredictably.
- **Leaving Orbit View now animates back to the sketch view first**:
  previously the toggle FAB swapped instantly back to the flat 2D canvas
  from whatever angle the camera had been orbited to. `_exitOrbitView` now
  awaits the same `animateToPlane` call `_returnOrbitToDefaultView` uses
  before swapping, so leaving reads as a smooth camera return rather than
  a hard cut.
- **4.1's original ask, actually built**: bodies now render as a static,
  non-interactive shaded backdrop *behind the flat 2D canvas itself*
  during ordinary sketch editing (not just inside Orbit View) - a
  read-only `PartViewport` (camera fixed once via `initialViewPlane`,
  wrapped in `IgnorePointer` so it never orbits) sits behind `SketchCanvas`
  in `_buildBaseLayer`'s Stack, and `SketchCanvas`'s own Canvas
  Transparency now defaults to ~25% whenever the Sketch's Part has Body
  geometry (bodyless Sketches keep the fully-opaque default). The body
  itself stays fully opaque - it's the *canvas*'s own fade that reveals
  it - and reuses the existing Hide/Show Reference Body toggle, so one FAB
  now controls both the ghost-wireframe outline and the shaded backdrop.
  Two `PartViewport`/`Scene` instances can now be alive at once during
  ordinary 2D editing (this static backdrop, on top of whatever the main
  `PartScreen` viewport is doing off-screen) - worth an on-device eye on
  performance; if it's a problem on lower-end devices, gating this behind
  its own visibility toggle (rather than always-on whenever a Body exists)
  is a natural follow-up for a later phase.

### 4.1 Show existing bodies behind the canvas, default ~25% transparent
- **Correction (confirmed on-device, this is NOT already working)**: the
  earlier "one-line default change" verdict was wrong. `canvasOpacity`
  (`sketch_canvas.dart:49,60`, applied at `:1795`) only fades a flat
  background *color rect*, and there is nothing else in the `Stack`
  behind `SketchCanvas` (`sketch_screen.dart:180-190`) for that fade to
  reveal — no 3D body rendering happens behind the sketch canvas at
  all. What *does* exist is a separate, always-on, opacity-independent
  mechanism: `referenceGhostSegments` — a flat list of the visible
  bodies' mesh edges, projected onto the sketch plane
  (`edgeSegmentsFromMesh` + `projectMeshEdgesOntoPlane`,
  `part_screen.dart:4719-4725`) and painted as dashed lines
  (`sketch_canvas.dart:1797-1806`). This is a 2D wireframe outline, not
  a shaded/solid body, and it's pure paint — not hit-testable, so it
  can't currently support the body-edge dimensioning ask in 4.3 either.
  Changing the opacity default currently changes nothing a user would
  notice, since it fades a plain background, not the bodies.
- **Proposed approach**: this needs real work, and should be scoped
  together with 4.3 rather than treated as trivial, since both need the
  same underlying capability — *interactive* body geometry available
  inside the sketch view, not just a projected outline. Two viable
  directions: (a) render the actual mesh (shaded, using the existing
  mesh-viewer rendering path) behind the 2D sketch canvas at the chosen
  opacity, with hit-testing added against that mesh's edges/vertices for
  4.3's picking, or (b) keep the flat 2D projection approach but make
  the projected segments genuinely hit-testable objects (simpler, but
  doesn't give real depth/occlusion cues the "orbit to see where you're
  sketching" ask implies). Recommend (a) given 4.2 already establishes
  a 3D camera path for this screen.
- **Files**: `sketch_canvas.dart`, `sketch_screen.dart`, `part_screen.dart`
  (ghost-segment computation), likely shares infrastructure with 4.2
  and 4.3.
- **Risk**: medium — smaller than 4.3 alone but no longer the trivial
  item it first appeared to be; sequence it alongside 4.2/4.3 rather
  than as an early quick win.

### 4.2 Orbit-view button + animated return-to-default-view button
**Decided: look-only toggle**, not simultaneous 3D editing — confirmed.
Editing always happens back in the flat 2D view; orbit is purely for
inspection, matching the original ask and the lower-risk reuse path
below.
- **Current state**: the sketcher uses a flat 2D `SketchViewport`
  (pan/zoom only, `sketch_viewport.dart`), not the 3D `OrbitCamera`
  used by the part viewer (`viewport3d/orbit_camera.dart`). However,
  `OrbitCamera` already has everything needed for reuse:
  `orientationFacingPlane(ReferencePlaneKind)` computes the
  quaternion facing a given plane (`:276-280`), and
  `PartViewport.animateToPlane` already animates the camera to a plane
  orientation via an `AnimationController` (`part_viewport.dart:786-792`),
  used today for the camera-animation-into-sketch transition
  (`part_screen.dart:2484,3000`). `OrbitCamera.reset()` backs an
  existing "Reset view" button elsewhere in the app
  (`part_viewport.dart:1122-1126,1460`).
- **Proposed approach**: treat orbit-view as a **temporary inspection
  mode**, not simultaneous 2D-editing-in-3D — matches the actual ask
  ("a button to change to orbit view so user can see where they are
  sketching... a button to return to default view... should animate").
  Toggle to a read-only 3D `OrbitCamera` view (reusing the part
  viewer's camera plumbing) showing the sketch's existing
  `sketch_geometry_3d.dart` projection alongside bodies; "return to
  default" calls the same `animateToPlane`/orientation-facing logic
  already proven for entering sketch mode. Editing stays on the 2D
  canvas; orbit is look-only.
- **Files**: `sketch_screen.dart` (mode toggle + camera lifecycle),
  reuses `orbit_camera.dart`, `part_viewport.dart` patterns,
  `sketch_geometry_3d.dart` (already renders sketch entities in 3D
  world space, confirmed reusable as-is).
- **Risk**: medium — mostly integration work reusing proven
  components, main complexity is state management for switching
  between two camera/input models cleanly.

### 4.3 Dimensioning from body edges/points + yellow "lost reference" tree indicator
**Status: v1 (vertices) and v2 (whole edges) both implemented, pending
on-device verification.** v1 shipped first (per this section's own item
6 recommendation) and was verified on-device, which surfaced an unrelated
pre-existing horizontal/vertical-dimension sign bug (fixed separately -
see the bug-fix in `solver.py`'s `_PySlvsBuilder._project_distance`). v2
followed immediately after, built *from* v1 exactly as item 6 anticipated:
an edge materializes as two Points (v1's own vertex-materialize call,
reused twice - `app.document.extrude.edge_endpoint_vertex_refs` finds
the edge's two endpoint vertices, `create_external_edge_reference` is the
new endpoint) plus a real `Line` between them, needing zero new solver/
constraint machinery - a pinned Line is already rigid once both endpoints
are pinned Points, and `solve_sketch`'s existing external-reference
re-pin pass already re-resolves both on every solve regardless of which
Sketch entity references them. Client: `SketchController.
pickReferenceGhostEdge` mirrors `pickReferenceGhostVertex` exactly (same
materialize-once/reuse-on-repick cache, same "hand the result to
`_applyDimensionHit` as an ordinary entity" trick - `SelectionKind.line`
rather than a new kind), and the ghost outline's dashed rendering (Phase
4.1) is now also hit-testable via a new, separately-tracked
`referenceGhostEdges` list carrying `(bodyId, edgeIndex)` per segment.
`has_lost_reference`/the feature-tree badge needed no changes at all for
v2 - both endpoint Points already flow through the same `external_
references` dict v1 built.
- **Current state (re-confirmed via a dedicated research pass)**: not
  supported at all today, and every piece of it is genuinely new -
  there is no existing partial version of any of this to extend.
  - **Phase 4.1's "ghost" body outline carries no ids.**
    `referenceGhostSegments` (`part_screen.dart`'s `_openSketch`, via
    `edgeSegmentsFromMesh` + `projectMeshEdgesOntoPlane`) is a flat
    `List<((double,double),(double,double))>` of anonymous 2D segments -
    `edgeSegmentsFromMesh` (`mesh_geometry.dart`) reads only the raw
    `mesh.edges` coordinate floats and explicitly discards
    `mesh.edgeIds`. It is also not currently hit-testable at all:
    `sketch_controller.dart`'s dimension-mode tap resolver
    (`_resolveSelectableAt`) never consults it. The ghost is a pure
    render-only backdrop today.
  - **A real, precedented stable-reference mechanism already exists,
    just not wired into the sketch canvas.** `SubShapeRef` (`{body_id,
    shape_type: EDGE|FACE|VERTEX, index}`, `document/models.py:191-216`)
    is exactly the "point at a specific piece of a Body" primitive this
    phase needs - already used end-to-end by `CreatePlaneFeature`'s
    edge/vertex/face refs, `FilletFeature`/`ChamferFeature`'s
    `edge_refs`. Resolution is always re-derived, never cached
    (`resolve_subshape_from_bodies`, `extrude.py:927-945`, re-walks
    `topexp.MapShapes` against the *current* body every time) and fails
    closed with a structured `missing_reference` 422 when the index no
    longer resolves (`_missing_reference`, `extrude.py:905-924`). The
    3D viewport already has a full pick pipeline onto this type
    (`selection_hit_test.dart`'s `SelectionEntityRef` -> `part_screen.dart`
    building `SubShapeRefDto`s from taps, e.g. line ~3886 for edges) -
    none of it reaches the 2D sketch canvas.
  - **The solver already has the one mechanism this phase actually
    needs: a Point that's real but pinned.** `_PySlvsBuilder.point2d`
    (`solver.py:140-150`) puts a Point into py-slvs's never-solved
    `_FIXED_GROUP` whenever its id is the Sketch's own origin *or* is
    in the caller-supplied `anchor_point_ids` set (the drag-solve
    mechanism) - using whatever `(x, y)` that Point's own dataclass
    already holds. There is no existing way to pin a Point whose
    `(x, y)` comes from *outside* `sketch.points` (i.e. a body-vertex
    projection) - but the pinning half of the mechanism is exactly what
    an external reference needs, and it's already point-id-based, not
    tied to any special Point subtype.
  - **No staleness/dirty flag exists anywhere on a `Feature` today.**
    Every "is this reference still good" check in the codebase is
    pull-based, not a persisted flag: re-derive from the Part's current
    state on read, then either succeed or fail closed. The one
    existing precedent for surfacing a broken reference to the client
    without hard-failing the whole response is
    `_create_plane_feature_response` (`router.py:159-199`): resolve in
    a `try`, and on `HTTPException` soft-fail specific fields to `None`
    rather than raising. There is no existing `hasLostReference`-shaped
    boolean on any Feature or its response schema.
  - **`feature_tree_panel.dart`'s "locked -> grey" branch is a real,
    directly-extensible template**, but it's two independent ternaries
    on one `ListTile` (`_buildFeatureTile`, lines ~450-489) - the
    `leading` icon color/glyph and the `subtitle` text each already
    switch on `feature.locked` separately, alongside a third,
    independent `hidden`-driven `Opacity`/trailing-icon channel. A
    `hasLostReference` state needs its own branch alongside (not
    instead of) `locked`, since a Feature could in principle be both.
  - **The dimension-pick pipeline is entirely Sketch-Point/Line-id
    shaped**, and would need a new case threaded through every layer:
    `SelectionKind` (`sketch_controller.dart:485`, no body-entity
    variant), `DimensionGhost` (`pointAId`/`pointBId`/`lineAId`/
    `lineBId` - always Sketch-internal id strings), `confirmGhostValue`
    (`sketch_controller.dart:4655-4785`, its `DistanceConstraint`
    creation calls only ever take two Sketch Point ids), and
    `sketch_dimension_bar.dart`'s entity-label `switch` (no body-entity
    case).
- **Proposed approach**: fold the new "external reference" concept into
  the *existing* Point-based machinery as far as possible, rather than
  adding a second, parallel dimensioning system. Concretely:
  1. **A body reference materializes as a real, ordinary Sketch
     `Point`** - not a new geometry primitive. `Sketch` gains
     `external_references: dict[str, SubShapeRef]` (Point id ->
     the Body vertex it tracks) alongside its existing `points` dict.
     A new endpoint, `POST /sketch/sketches/{id}/external-references`
     (body: a `SubShapeRefSchema`, `shape_type` restricted to `VERTEX`
     in v1 - see item 6), resolves the vertex's current 3D position via
     the existing `resolve_subshape` + the plane-projection helpers
     `create_plane.py`'s `_basis_for_sketch` already exposes, creates a
     real `Point` at the projected `(x, y)`, records the mapping in
     `external_references`, and returns the new `PointResponse` -
     identical shape to any other Point creation endpoint.
  2. **Every solve re-resolves and re-pins every external Point before
     building the solver.** `solve_sketch` gains a pre-pass: for each
     `(point_id, ref)` in `external_references`, re-resolve `ref`
     against the Part's current bodies (same `resolve_subshape`
     call as creation); on success, overwrite that Point's `(x, y)`
     with the freshly-projected position and add its id to the
     existing `anchor_point_ids` fixed set (`_PySlvsBuilder` needs no
     changes at all - it already treats "is this id in the pinned set"
     as the only question that matters); on failure, leave the Point at
     its last-known `(x, y)` (so the rest of the sketch doesn't
     visually collapse) and record the id in a new
     `lost_reference_point_ids` field on `SolveResult`, mirroring the
     existing `blamed_constraint_ids`/
     `solver_reported_failed_constraint_ids` pattern exactly.
  3. **Dimensioning to an external Point needs zero new constraint
     types.** Once step 1 has materialized it as a real `Point`, every
     existing path - `DistanceConstraint`, the V/H/linear ghost trio,
     `circleForDistanceConstraint`'s radius/diameter machinery if ever
     relevant, undo/redo, native-format persistence - already works
     against it unmodified, because none of that code path
     distinguishes *how* a Point came to exist. This is the core reason
     to materialize rather than invent a parallel "external point"
     concept: it collapses what would otherwise be a second dimension
     system back into the first one.
  4. **Client picking UX**: extend `edgeSegmentsFromMesh`/
     `projectMeshEdgesOntoPlane`'s pipeline to also carry each
     segment's endpoint `topology_vertex_ids` through to a new
     `SketchScreen`/`SketchController` field (e.g.
     `referenceGhostVertices: List<(String bodyId, int vertexId, double
     x, double y)>`, populated from `MeshDto.topologyVertexIds`, which
     the pipeline currently drops on the floor exactly the way
     `edgeIds` is dropped) - the projected positions already exist as a
     side effect of the segment projection, this is purely "stop
     discarding data that's already computed." Add a new
     `SelectionKind.bodyVertex` case; dimension-mode tap-resolution
     hit-tests these ghost vertex markers (small, always-visible
     crosshairs on the ghost outline, distinct from the dashed line
     styling) alongside the existing Point/Line/Circle candidates. On
     first pick, immediately call the new endpoint from item 1 to
     materialize the real Point, then hand its id into the *existing*
     `_dimensionSelection`/`_rebuildDimensionGhosts` flow unchanged - a
     picked body vertex is indistinguishable from a picked Point from
     that call onward. Re-picking the same ghost vertex a second time
     (e.g. after cancelling) should reuse the already-materialized
     Point rather than creating a duplicate - check
     `external_references`'s values for a matching `SubShapeRef` first.
  5. **`hasLostReference` at the Feature level**: `SketchFeatureResponse`
     gains a `has_lost_reference: bool`, computed the same soft-fail-
     without-raising way `_create_plane_feature_response` already
     computes its `origin`/`normal` fields - attempt to resolve every
     entry in the Sketch's `external_references`; any failure sets the
     flag `true` without failing the whole feature-list response.
     `build_feature_graph` (`document/graph.py`) gains one more
     `depends_on` source: a `SketchFeature` depends on
     `base_feature_id(ref.body_id)` for every external reference its
     Sketch holds, so cascade-delete/rebuild ordering (already fully
     general over `depends_on`) accounts for it with no changes to the
     graph algorithm itself. Client: `feature_tree_panel.dart`'s
     `_buildFeatureTile` gains a third, independent branch alongside
     `locked`/`hidden` - e.g. a yellow warning-triangle overlay badge
     on the existing `leading` icon (kept independent of, not
     replacing, the lock-grey branch, since both could be true at
     once) plus an amber `subtitle` override ("Lost reference" takes
     display priority over "Editable"/"Imported"/"Locked").
  6. **Explicit v1 scope: Body *vertices* only, not full edges.** A
     vertex projects to exactly one `(x, y)` and slots into the
     Point-reuse design in item 3 with zero new constraint machinery.
     Referencing a whole edge (for e.g. a point-to-edge distance, or an
     edge-to-edge parallel/perpendicular tie) needs either a new
     Point-to-external-line distance constraint type or projecting the
     edge as a synthetic, similarly-pinned two-Point Line - a real
     follow-on but materially more work (a new `PointLineDistance`-
     style solver path, or Line-level external-reference plumbing
     mirroring everything in items 1-2 a second time), and edge-vertex
     picking already covers the most common real case (dimensioning a
     new hole/feature off an existing corner). Flag as v2, matching how
     9.1 was split into a frozen-copy v1 and an associative-link v2 for
     the same "ship the simpler half first" reason.
  7. **Explicit v1 non-goal: editing/moving the source geometry through
     the sketch.** An external reference Point is read-only from the
     sketch's own drag/edit tools in v1 (its position is always
     overwritten by the item-2 pre-pass on the next solve regardless of
     any local edit) - worth a `SketchPointView`-level `isExternal`
     flag purely so the client can refuse a drag attempt with a clear
     reason, rather than silently reverting it after the next solve.
- **Files**: backend - `models.py` (`Sketch.external_references`,
  `SubShapeRef` reuse), `schemas.py` (`SketchOrientationUpdate`-style new
  request/response shapes, `SolveResult.lost_reference_point_ids`),
  `solver.py` (the re-resolve-and-pin pre-pass), `router.py` (new
  external-reference endpoint, `SketchFeatureResponse.has_lost_reference`),
  `graph.py` (one more `depends_on` source), `create_plane.py` (reused
  plane-projection helper), `native_format.py` (persist
  `external_references`). Client - `sketch_api_client.dart`
  (`SubShapeRefDto` reuse, new endpoint call,
  `lostReferencePointIds`), `part_screen.dart`/`mesh_geometry.dart`
  (stop discarding `topology_vertex_ids` through the ghost-projection
  pipeline), `sketch_controller.dart` (`SelectionKind.bodyVertex`,
  ghost-vertex hit-testing, materialize-on-pick), `sketch_canvas.dart`
  (ghost-vertex marker rendering), `sketch_dimension_bar.dart` (new
  chip case), `feature_tree_panel.dart` (yellow lost-reference branch).
- **Risk**: high, but more contained than the original scoping pass
  assumed - v1 reuses `SubShapeRef`'s already-precedented resolve/
  fail-closed pattern verbatim and reuses the Point/DistanceConstraint
  machinery verbatim; the two genuinely new pieces are the solver's
  re-resolve-and-pin pre-pass (small, mechanical, same shape as the
  existing anchor-pinning code) and the Feature-graph/staleness wiring
  (new field, but follows an existing soft-fail precedent exactly). The
  main remaining risk is UX, not architecture: making body-vertex ghost
  markers discoverable/tappable at a useful hit-radius without cluttering
  the canvas, and getting the "materialize on first pick, reuse
  thereafter" de-duplication right so repeated dimensioning off the same
  corner doesn't spawn duplicate Points. Treat as its own mini-project
  as originally recommended; v1 (vertex-only) is the unit to ship first.

---

## Phase 5 — Sketch orientation control

### 5.1 Flip / rotate sketch axes, reference-axis alignment, retrospective redefine
**Decided: discrete steps** (90° rotation + mirror flip), not free/
continuous rotation — confirmed. Simpler solver-basis math (a small
fixed set of basis transforms rather than an arbitrary angle), and a
much simpler axis-arrow indicator to keep in sync.

**Status: discrete flip/90° rotate is fully implemented and wired to a
UI entry point; reference-axis alignment is not built at all.** The data
model (`Sketch.flip`/`rotation_quarter_turns`), the `PATCH .../orientation`
endpoint, and `plane_indicator.dart` reading live orientation state
(rather than a hardcoded per-plane table) all landed in an earlier round
- but nothing called any of it until now: `sketch_screen.dart`'s
hamburger menu gained a "Sketch Orientation" entry (`_pickOrientation`)
opening a bottom sheet (`_OrientationSheet`) with rotate-90°-CW/CCW
buttons and a Flip switch, calling `SketchController.setOrientation`
directly on each tap. One entry point covers both the creation-time and
retrospective-redefine cases the original proposal below called out
separately - `SketchScreen` is the same screen either way, and
orientation is never baked into stored Point coordinates (see `Sketch.
set_orientation`'s own doc comment), so redefining it on an existing
Sketch is exactly as safe as setting it on a brand new one; no separate
long-press/tree entry point was needed. Reference-axis alignment (pick
an edge/line to set as the local X axis) remains fully unscoped new
work - there is no reference-direction concept anywhere in the backend,
only the 4 discrete rotation states.

- **Current state (superseded by the Status note above; kept for the
  original before/after research)**: `Sketch.plane` is only a fixed enum
  (`Plane.XY|XZ|YZ`, `models.py:25-31,208`) or `None` when anchored to a
  custom `CreatePlaneFeature` — there is no independent
  orientation/flip/rotate/reference-axis state on a sketch at all. The
  solver hardcodes its workplane normal direction per canonical plane
  (`solver.py:234-236`). The existing `plane_indicator.dart` widget
  (bottom-left axis-arrows + label, matching the roadmap's described
  position) is purely cosmetic today — axes are hardcoded per plane
  (`_axesByPlane`, lines 19-32), not derived from any stored
  orientation state, and there's no flip/rotate logic anywhere in the
  sketch files.
- **Proposed approach**: add orientation fields to `Sketch`
  (e.g. a flip flag + rotation step, or store an explicit U/V basis
  pair derived from the plane's default axes plus applied
  flip/rotation — the latter is more general and handles the
  reference-axis-alignment case uniformly) and thread that basis
  through `solve_sketch`'s workplane construction instead of the
  hardcoded normal. Client: extend `plane_indicator.dart` to read the
  live basis rather than a hardcoded per-plane table, add flip/rotate
  buttons during sketch creation, wire an optional edge/line pick
  (reusing hit-testing infra from the sketcher itself) to set the
  reference axis, and add a long-press handler on a sketch (tree or
  canvas) that re-enters this same orientation UI retrospectively —
  requires re-solving/re-projecting existing sketch geometry against
  the new basis when redefined after the fact, which is the trickiest
  sub-piece (existing point coordinates are plane-relative already, so
  a basis change is a re-projection, not a re-entry of geometry, but
  needs care around any *external* references from Phase 4.3 if that's
  shipped by then).
- **Files**: `models.py`, `schemas.py`, `solver.py`,
  `plane_indicator.dart`, `sketch_screen.dart` (creation flow),
  `feature_tree_panel.dart` or canvas (long-press entry point).
- **Risk**: medium-high — real data-model addition plus a retrospective
  edit path that has to stay correct against existing sketch geometry;
  sequence after Phase 4.3 if both are in flight, since retrospective
  redefinition interacts with external references.

---

## Phase 6 — Drawing tool additions

### 6.1 Line tool: snap to horizontal/vertical + auto-constrain on placement
- **Current state**: Horizontal/Vertical constraints are fully
  implemented but only ever user-invoked explicitly
  (`addHorizontalConstraint`/`addVerticalConstraint`,
  `sketch_controller.dart:1939,1955`, wired to ribbon shortcuts
  `:1914-1917`). There's no angle-threshold auto-snap during line
  placement today — existing snap behavior only covers point/midpoint/
  chain-start coincidence (`sketch_canvas.dart:1644-1934`).
- **Proposed approach**: during the line tool's drag/preview, compute
  the angle to horizontal/vertical and snap the preview endpoint when
  within a threshold (a few degrees), mirroring the existing
  point-snap visual pattern; on placement while snapped, call the
  existing `addHorizontalConstraint`/`addVerticalConstraint` methods
  automatically — no new constraint machinery needed, just new
  triggering logic.
- **Files**: `sketch_controller.dart`, `sketch_canvas.dart`.
- **Risk**: low — additive, reuses existing constraint calls.

### 6.2 New shape/curve tools: arc, ellipse, slot, polygon, spline, text
**Decided: complexity-based order confirmed** (arc → polygon → slot →
ellipse → spline → text), no reprioritization requested.
- **Current state**: today's tools are point, line, circle, rectangle
  (`sketch_speed_dial.dart:43-99`). None of arc/ellipse/slot/polygon/
  spline/text exist client- or backend-side.
- **Proposed approach**: treat as a backlog of independent tool
  additions, not one lump of work, roughly in order of increasing
  complexity:
  1. **Arc** — moderate; py-slvs supports arc entities directly, similar
     shape to the existing circle tool's client/backend pattern.
  2. **Polygon** — moderate; likely composed of line entities plus
     equal-length/angle constraints generated at creation time, no new
     solver entity type needed.
  3. **Slot** — moderate; composite of two arcs + two tangent lines,
     buildable from arc + line primitives once (1) lands.
  4. **Ellipse** — moderate-high; need to confirm py-slvs's constraint
     support for ellipse entities (may be more limited than
     circle/arc) before committing to an approach.
  5. **Spline** — moderate, revised down from the original "high"
     estimate now that the open question below is resolved. See
     **6.2.5** for the full scoping pass: py-slvs does expose a real
     cubic-Bezier solver primitive (`SLVS_E_CUBIC`/`addCubic`), but v1
     deliberately doesn't use it, following the same
     decompose-into-plain-Points precedent Circle/Arc/Ellipse already
     established.
  6. **Text (outline, for cutting/embossing)** — high, but now
     concretely scoped rather than open-ended. See **6.2.6**: OCCT
     itself (via pythonocc-core) has built-in TrueType-to-BRep
     conversion, which - if actually reachable in this project's pinned
     conda build (**unconfirmed, first thing to check**) - avoids
     needing a new font-parsing dependency at all.
- **Files**: backend `models.py`/`constraints.py`/`solver.py` (new
  entity + constraint types per shape), `sketch_controller.dart`,
  `sketch_canvas.dart`, `sketch_speed_dial.dart`, `sketch_api_client.dart`
  for each.
- **Risk**: low→high across the list; sequence in the order above.

### 6.2.5 Spline tool
- **Current state**: Arc/Polygon/Slot/Ellipse all shipped (6.2.1-6.2.4);
  no Spline entity exists client- or backend-side. The original 6.2
  entry above flagged "confirm what curve types py-slvs actually
  exposes" as the blocking unknown - now resolved by direct inspection
  of the installed solver module (`python3.11 -c "from py_slvs import
  slvs"`, then grepping `slvs.py` for every `SLVS_E_`/`SLVS_C_`
  constant and `System.add*` method, the same technique that confirmed
  Ellipse's *lack* of support in 6.2.4): py-slvs genuinely exposes
  `SLVS_E_CUBIC` (a 4-point cubic Bezier curve entity - two endpoints
  plus two control handles) via `System.addCubic(wrkpln, p1, p2, p3,
  p4, group=0, h=0)`, plus `SLVS_C_CUBIC_LINE_TANGENT`/
  `addCubicLineTangent` and `SLVS_C_CURVE_CURVE_TANGENT`/
  `addCurvesTangent` for tangency constraints between segments - a
  materially richer primitive than Arc ever needed (Arc's own
  `SLVS_E_ARC_OF_CIRCLE` exists in py-slvs too, but this codebase
  doesn't use it either - see below).
- **Proposed approach**:
  1. **Do not use `SLVS_E_CUBIC` in v1.** `solver.py` currently never
     passes any py-slvs specialized entity type (`SLVS_E_CIRCLE`,
     `SLVS_E_ARC_OF_CIRCLE`) into the solver at all - grepped directly,
     zero references. Every curved entity this app has (Circle, Arc)
     instead decomposes entirely into plain Points plus ordinary
     `DistanceConstraint`s, with the curve's "circular-ness" enforced
     geometrically rather than via a native solver primitive (see the
     Arc class's own docstring: "zero new py-slvs primitives"). This
     looks like a deliberate architectural choice - `solve_sketch`
     appears to run in a flat, workplane-less scheme, and every
     specialized SLVS entity type requires a `wrkpln` (workplane)
     handle this codebase's solver integration has never had to thread
     through before. Wiring up real `SLVS_E_CUBIC` entities would be
     the first time it needed to, which is a materially bigger, riskier
     lift than anything Arc/Polygon/Slot/Ellipse needed - exactly the
     kind of thing this scoping pass exists to flag rather than
     discover mid-implementation.
  2. **v1: follow the established Ellipse/Arc precedent instead.** A
     Spline is a chain of real, draggable Points; the smooth curve
     through them is a plain Catmull-Rom interpolation (passes exactly
     through each tapped Point, unlike a control-point Bezier where the
     curve only touches the first/last handle - matches the more
     intuitive "click points, curve follows them" mental model most
     sketch-spline tools default to), computed client- and backend-side
     from those Points' positions - not represented by any new solver
     primitive, zero new py-slvs machinery, mirroring Ellipse's own
     "sidestep the solver" design exactly. Every Point stays fully
     draggable/constrainable like any other Point; only the
     interpolation shape *between* them is derived, not independently
     constrainable in v1 (no per-segment tangent-continuity constraint -
     see item 6 below for where that would go later).
  3. **Tap sequence**: repeated single-Point taps, reusing Line's
     existing chain machinery almost verbatim (`chainFirstPointId`-style
     in-progress state, an explicit Finish action mirroring
     `finishChain()`) - no new gesture design needed. Minimum 2 points;
     a straight 2-point "spline" degenerates to a line, which is fine
     and not worth special-casing away.
  4. **`endpoint_point_ids()`**: override to return (first point, last
     point), the same override Arc already has - this alone slots an
     open Spline into the existing generic Line/Arc chain-walk
     `profile.py` already does, so it can close a loop together with
     Lines/Arcs with no `profile.py` changes at all. A *closed* spline
     (looping back on itself, standalone like Circle/Ellipse) is
     explicit v1.1 scope, not v1 - v1 only supports a Spline as one
     open edge in a larger Line/Arc/Spline chain, exactly how Slot's
     Arcs already participate.
  5. **OCCT wire construction**: `GeomAPI_Interpolate` (builds a
     `Geom_BSplineCurve` through an ordered `TColgp_HArray1OfPnt`, i.e.
     exactly a Catmull-Rom-equivalent interpolation) is the direct,
     idiomatic OCCT tool for this - `wire_for_profile`'s existing
     per-hop dispatch (straight edge for a Line, `gp_Circ`-based edge
     for an Arc) gains a third case: a `BRepBuilderAPI_MakeEdge` built
     from the interpolated `Geom_BSplineCurve`.
  6. **Client rendering/hit-testing**: sample the same Catmull-Rom
     formula at a fixed step count into a polyline - the same
     "boundary sampling" approach 6.2.4 already used for Ellipse's
     profile-containment checks - and draw/hit-test it exactly like a
     Polygon's already-sampled edges (`_distanceToSegment` per hop).
     A true `Path.cubicTo`-based smooth render is a pure visual
     upgrade, not required for v1.
  7. **Explicit v1 non-goal**: tangent-continuity between segments
     (`addCubicLineTangent`/`addCurvesTangent`, item 1's real
     primitive) - only worth the `wrkpln` integration risk if a
     Catmull-Rom fit's visible kinks at sharp turns actually bother
     users in practice. Flagged as future work, not committed to.
- **Files**: mirrors Ellipse's own file list exactly - backend
  `models.py` (`Spline` dataclass + `Sketch.add_spline`/`delete_spline`),
  `schemas.py`, `router.py` (CRUD), `store.py`, `extrude.py`
  (`GeomAPI_Interpolate` wire branch), `native_format.py`; `profile.py`
  needs no changes beyond what `endpoint_point_ids()` already buys for
  free. Client: `sketch_api_client.dart` (`SplineDto`),
  `sketch_controller.dart` (tool/ghost/render/hit-test - closely
  mirrors `_ellipseDrawGhost`/`_clickEllipseTool`'s shape),
  `sketch_canvas.dart`, `sketch_speed_dial.dart`.
- **Risk**: moderate, not high - the interpolation math (Catmull-Rom +
  its OCCT `GeomAPI_Interpolate` equivalent) is new but standard and
  well-documented; the tap-sequence UI is close to a total reuse of
  Line's chain tool. The originally-flagged blocking unknown ("confirm
  what curve types py-slvs actually exposes") is now resolved: real
  native support exists, but v1 deliberately doesn't reach for it,
  keeping this in line with every other curved entity this codebase
  has shipped so far.

### 6.2.6 Text tool (outline, for cutting/embossing)
- **Current state**: no text/font support anywhere in the codebase -
  no font-parsing dependency in `backend/environment.yml`, no `Text`
  concept in `sketch/models.py`, nothing in the client. Explicitly out
  of scope for every prior 6.2 sub-phase.
- **Proposed approach**:
  1. **Key finding, unconfirmed on-device**: OCCT (the library
     `pythonocc-core` wraps) has built-in TrueType-font-to-BRep
     conversion via `Font_BRepFont`/`Font_BRepTextBuilder`, and
     `pythonocc-core`'s own repository additionally ships a convenience
     Python wrapper for it - `src/Addons/Font3d.cpp`, exposing
     `text_to_brep(text, fontName, fontAspect, size,
     isCompositeCurve)` and `register_font(fontPath, fontAspect)` -
     meaning font-outline extraction may need **no new dependency at
     all**, just the `pythonocc-core` this project already pins. This
     is **not yet confirmed for this project's exact build**:
     `Font3d.cpp` lives in `pythonocc-core`'s `src/Addons` directory,
     not its auto-generated `OCC.Core.*` bindings, so whether it's
     actually compiled into `pythonocc-core=7.9.3=novtk*` (the exact
     pin in `backend/environment.yml`) needs a direct check
     (`python3.11 -c "from OCC.Core.Addons import text_to_brep"` or
     wherever it actually lands - exact import path unconfirmed too).
     This sandbox has no `pythonocc-core` installed at all (`import
     OCC` -> `ModuleNotFoundError`, the same limitation noted
     throughout every backend change in this whole document that
     touches `extrude.py`), so this could not be verified directly in
     this pass. **This is the single highest-leverage thing to check
     first**, before any other Text work starts - if it's missing from
     the `novtk` build, the fallback is a genuinely new dependency
     (e.g. Python's `fontTools`, walking each glyph's outline table by
     hand and converting to OCCT edges) - a materially bigger,
     from-scratch lift that would justify treating Text as its own
     separate research spike, exactly as the original 6.2 entry above
     recommended.
  2. **Recommend NOT decomposing text into constrainable
     Points/Lines/Splines.** A single word already produces dozens of
     contours (each letter, plus inner "holes" for closed counters like
     o/e/a/g), each with many curve segments - materializing all of
     that as draggable, individually-constrainable sketch Points would
     be enormous data/UI clutter for no real user benefit (nobody
     hand-tweaks the curve of a single serif). Every mainstream CAD
     tool (Fusion 360, SolidWorks, Onshape) treats sketch text the same
     way: an opaque, regenerate-on-edit object, only "exploded" into
     real editable curves on explicit user request - a natural v2
     feature once Spline (6.2.5) exists to explode *into*.
  3. **New lightweight entity** (e.g. `TextEntity`) - fields: content
     string, font (a small backend-bundled allowlist for v1, not
     arbitrary system/uploaded fonts - sidesteps a font-management UI
     and per-font licensing surface entirely), size, an anchor Point
     (real, draggable/constrainable, same role as Circle's center), and
     rotation. Glyph geometry itself is never persisted as Points - it
     regenerates from these fields on demand, the same
     recompute-from-parametric-inputs principle every other
     feature/extrude/fillet in this app already follows.
  4. **Profile detection**: each contour `text_to_brep` returns becomes
     its own loop-with-holes - exactly the shape `profile.py`'s
     existing nested-loop classification (`_classify_nesting`) already
     handles (built for "a plate with a round hole," generalizes
     directly to "an 'o' is an outer ring with one hole," "an 'i' is
     two disjoint outer loops - the stem and the dot," "the whole
     string is one `MultiProfile` of N disjoint per-letter outer
     loops"). The new work is a `_text_profile`-style function
     upstream of that - structurally mirroring `_circle_profile`/
     `_ellipse_profile`'s "pack the owning entity's id into `line_ids`"
     convention, but yielding potentially many loops per Text entity
     instead of exactly one.
  5. **Client rendering**: no font-outline renderer belongs in Flutter
     for this - a real preview needs the actual server-generated
     tessellated outline anyway (same reasoning every curved entity in
     6.2 needs real geometry for rendering, not an approximation), so
     add a lightweight preview-outline endpoint (returns each contour
     as a polyline, mirroring the existing mesh-tessellation endpoints
     already serving 3D body preview) that the client calls once per
     content/font/size change, caches, and draws with the same
     fill/stroke machinery `_addLoopBoundary`/`_profileLoopPath`
     already use for profile fills.
  6. **Extrude**: once contours are Profile loops (item 4), extrusion
     is already fully generic - no `extrude.py` wire-construction
     changes expected beyond what `_text_profile` needs.
  7. **Explicit v1 non-goals**: multi-line text/wrapping, arbitrary
     uploaded fonts, per-character kerning controls beyond the font's
     own defaults, "explode to editable curves" (deferred to v2, once
     Spline exists).
- **Files**: backend - `backend/environment.yml` (only if item 1's
  on-device check shows the addon is missing and `fontTools` becomes
  necessary), new `backend/app/sketch/text_geometry.py` (the
  `text_to_brep` wrapper + font allowlist), `models.py` (`TextEntity`),
  `schemas.py`, `router.py`, `profile.py` (`_text_profile`), a handful
  of bundled `.ttf` files as new binary assets - **each bundled font's
  license must be confirmed to permit redistribution**, a real,
  easy-to-miss legal check alongside the engineering one. Client: new
  `sketch_api_client.dart` DTOs + preview-outline fetch,
  `sketch_controller.dart`/`sketch_canvas.dart` (new tool, anchor-point
  placement + cached preview rendering), `sketch_speed_dial.dart`.
- **Risk**: high, but now concretely scoped rather than open-ended -
  the single biggest unknown (whether OCCT's text-to-BRep is actually
  reachable through this project's pinned `pythonocc-core` build) is a
  five-minute on-device check, not a research project. Assuming it
  checks out, the remaining work (one new lightweight entity type, a
  `profile.py` loop-source generalization, a preview-tessellation
  endpoint, font licensing) is real but bounded, and needs no new curve
  math the way Spline does. If the check fails, escalate this back to
  "needs its own separate research pass" for the `fontTools` fallback,
  exactly as the original 6.2 entry anticipated.

---

## Phase 7 — Unified 2D/3D sketching environment ("infinite plane" hybrid)

Raised as an exploratory question: can the sketcher live inside the same
environment as the 3D viewport, with a locked camera orientation and the
canvas read as an infinite plane, rather than two separate
canvas/viewport widgets? This directly extends Phase 4.1's already-shipped
shaded-body backdrop (`sketch_screen.dart`'s `_buildBaseLayer`, the
non-orbit branch) - today that backdrop's camera is static (`initialViewPlane`,
set once); this phase asks it to pan/zoom in lockstep with the flat 2D
canvas above it, so the two visually read as one continuous scene.

### 7.1 Sync the 2D canvas's pan/zoom with the 3D backdrop's camera
- **Current state**: pan/zoom is owned entirely by `SketchViewport`
  (`sketch_viewport.dart:12-40` - `double zoom`, `Offset panOffset`,
  `panByScreenDelta`/`applyAnchoredZoomPan`/`zoomAtScreenPoint`/`zoomToFit`),
  itself a private field of `_SketchCanvasState`
  (`sketch_canvas.dart:68`) with **no external observability at all** -
  no callback param, no `ValueListenable`, not even a public getter.
  `SketchViewport`'s own doc comment is explicit that this is deliberate:
  pan/zoom is "purely a view concern, not sketch domain state," kept off
  `SketchController` on purpose. Five call sites mutate it today: mouse
  right-drag pan (`:532`), two-finger pinch/pan (`:616-631`), mouse-wheel
  zoom (`:602-608`), the RTS edge-pan ticker (`:299-326`), and the
  "zoom to fit" button (`:749`). Separately, `OrbitCamera`
  (`orbit_camera.dart`) has no external injection or observation point
  either (confirmed already for Phase 4's own work) - `panByScreenDelta`/
  `zoomByFactor`/`target`/`distance` are only ever mutated by
  `PartViewportState`'s own raw pointer handlers; there is no precedent
  anywhere in this codebase for an `OrbitCamera` being driven
  programmatically from outside its owning widget (the closest thing,
  `animateToPlane`, only ever touches `orientation`, driven by an
  internal `AnimationController`, not target/distance/pan).
- **Proposed approach**: (a) add a new optional `onViewportChanged(Offset
  panOffset, double zoom)` callback param to `SketchCanvas`, fired from
  each of the five mutation sites above; (b) add two new public methods
  to `PartViewportState` - `applyExternalPan(double dx, double dy)` /
  `applyExternalZoom(double scaleFactor)`, thin wrappers around
  `_camera.panByScreenDelta`/`zoomByFactor` + `setState` - reachable via
  a `GlobalKey<PartViewportState>` on the backdrop instance (which
  doesn't have one today; only the Orbit View branch's instance does);
  (c) in `sketch_screen.dart`, translate `SketchViewport`'s pan(px)/
  zoom(linear multiplier) deltas into calls on the backdrop through that
  key; (d) give `PartViewport` a new locked gesture mode - pan/zoom
  allowed, rotation suppressed - since today any drag in its default
  mode calls `orbitByScreenDelta`, and remove the backdrop's
  `IgnorePointer` wrapper only for that locked interaction; (e)
  suppress the backdrop's unconditionally-rendered "Reset view" button
  (`part_viewport.dart:1476-1485`, currently just inert under
  `IgnorePointer`) with a new `showControls`-style flag, since it would
  fight programmatic sync once live. Orbit View (already shipped) stays
  the "step back and freely rotate" escape hatch, untouched by any of
  this.
- **Open risk worth a spike before committing to full delivery**:
  `flutter_scene` 0.18.x has no true orthographic camera - `OrbitCamera`
  is always a `PerspectiveCamera` with a fixed FOV (documented on
  `OrbitCamera.isPerspective`'s own field). `SketchViewport`'s zoom is a
  linear pixels-per-unit multiplier; `OrbitCamera`'s "zoom" is
  `distance` (an inverse, FOV-dependent measure, body-radius-clamped via
  `setZoomBoundsForRadius`). These aren't a 1:1 mapping, and a
  perspective camera panned off-axis introduces foreshortening a true
  orthographic "infinite plane" wouldn't have - the "feels like one flat
  window" premise this phase is built on may not fully hold up
  visually. Recommend a small throwaway prototype (sync just pan first,
  on a real device, one plane) to validate the feel before investing in
  the full locked-gesture-mode/callback plumbing.
- **Files**: `sketch_viewport.dart`, `sketch_canvas.dart` (new callback +
  call sites), `sketch_screen.dart` (wiring + new `GlobalKey`),
  `viewport3d/part_viewport.dart` (external pan/zoom methods, locked
  gesture mode, `showControls` flag).
- **Risk**: medium-high - genuine new architecture (no existing
  precedent for externally-driven camera control, no existing
  observability on the 2D canvas's own pan/zoom), plus the open
  perspective-vs-orthographic visual-fidelity question above. Not a
  rewrite of the sketcher (all of `SketchCanvas`'s rendering/hit-testing/
  drag-solve logic stays untouched) - the "completely new sketcher"
  alternative (every sketch entity rebuilt as real 3D scene geometry
  with ray-cast hit-testing) was considered and explicitly rejected as
  materially higher-risk for no real benefit, since sketches are
  inherently planar.

---

## Phase 8 — DXF/DWG import to sketch

### 8.1 Import DXF geometry as real, editable sketch entities
- **Current state**: entirely greenfield - a repo-wide grep found zero
  mentions of "dxf" or "dwg" anywhere in code or docs. The existing
  `ImportFeature` pipeline (STEP/STL/OBJ/glTF -> a Part's Body,
  `part_screen.dart:2251`'s `_importGeometry()` -> `POST
  /parts/{id}/import-features`, `document/router.py:1234`) is
  architecturally unrelated: it's a Part/Body-level, 3D,
  fixed-non-parametric import (base64-in-JSON, one API call, no
  preview/confirm step, backend re-decodes the raw bytes on every
  recompute rather than caching parsed geometry) in `app.document`, not
  `app.sketch` - not a reusable substrate for "import into an editable,
  still-parametric 2D Sketch," though its general shape (client picks
  file -> base64 -> JSON POST -> server-side parse) is a conventions
  precedent worth mirroring. No DXF-parsing library is a dependency
  today - `backend/environment.yml` has exactly `pythonocc-core`,
  `fastapi`, `uvicorn`, `pytest`, `httpx`, and `py-slvs`; `ezdxf` (the
  standard, actively-maintained, MIT-licensed Python DXF library) would
  be wholly new. The Sketch entity model only has `Point`/`Line`/`Circle`
  (`sketch/models.py` - `Arc` does not exist, confirmed both in the
  model and in this doc's own Phase 6.2, which lists Arc as an
  *unscheduled* backlog item) - DXF `ARC` entities and
  `LWPOLYLINE`/`POLYLINE` bulge (arc) segments have nothing to map onto
  today. There is no bulk-create endpoint anywhere in
  `sketch/router.py` - every Point/Line/Circle/Constraint creation is
  one POST, so an uncached import of N entities is N+ sequential
  round-trips absent new plumbing. There is no unit/scale concept
  anywhere in the sketch model either - `Point.x`/`.y` are bare floats
  with an implicit, undocumented unit - while DXF files routinely carry
  an explicit `$INSUNITS` header and arbitrary drawing units.
- **Proposed approach**:
  1. **DXF only for v1, not DWG.** DWG is a proprietary Autodesk binary
     format with no viable open-source native parser (`ezdxf` itself
     only reads DXF). Realistic DWG support means shelling out to
     Autodesk/ODA's free `ODAFileConverter` CLI to convert DWG->DXF
     server-side first - a separate, distinct decision (extra installed
     binary, its own licensing terms to check) that should not be
     bundled into DXF v1's scope. Simplest v1: reject `.dwg` uploads
     with a clear "please save as DXF" message.
  2. **Backend**: add `ezdxf` as a new dependency; a new endpoint (e.g.
     a stateless "parse and return entities" endpoint rather than one
     that mutates the Sketch store directly, keeping the client
     authoritative over what actually gets created, per this project's
     own API-first design - see the Cross-cutting notes below) that
     extracts `LINE`/`CIRCLE`/`ARC`/`LWPOLYLINE`(+bulge)/`POLYLINE`
     entities from modelspace only for v1 (layers, blocks, text,
     dimensions, and hatches are explicit non-goals, called out as such
     rather than silently dropped). Read `$INSUNITS` where present
     (default to millimeters, matching the sketch model's own implicit
     convention, when absent/unitless) and return the detected unit +
     a suggested scale alongside the parsed entities, rather than
     silently assuming.
  3. **Arc handling - a real product decision, not a detail**: either
     (a) block DXF import on Phase 6.2's Arc tool landing first, or (b)
     flatten `ARC`/bulge segments into short line-segment approximations
     on import as an interim stopgap (common practice in many DXF
     importers, but means imported "arcs" aren't editable/
     constrainable as arcs). Recommend (b) for a usable v1, revisited
     once Arc ships.
  4. **Client**: a new "Import DXF" entry point (sketch screen hamburger
     menu) -> file picker -> parse-preview request -> a genuine
     preview/confirm step (unlike `ImportFeature`'s no-preview flow -
     DXF import is messier and riskier: arbitrary source-tool quirks,
     unknown entity count, unit ambiguity - a user gut-check before
     flooding the sketch matters here) showing entity count, detected
     unit, and an editable scale factor -> on confirm, create each
     Point/Line/Circle via the existing one-at-a-time endpoints,
     wrapped in a single undo-stack entry - `SketchController`'s
     existing `deleteSelected()`/`_restoreDeletedEntities()`
     (`sketch_controller.dart`) already demonstrates exactly this
     pattern (many sequential API calls, one grouped undo entry with
     id-remapping) and can be copied directly, so no new undo-stack
     mechanism is needed.
  5. **Deferred**: a real bulk-create backend endpoint, only if
     sequential-round-trip latency proves a real problem in practice
     for large drawings - ship v1 without it and measure first.
- **Files**: `backend/environment.yml` (new dep), new
  `backend/app/sketch/dxf_import.py` (or similar), `sketch/router.py`,
  `sketch/schemas.py`; client: new import-sheet widget or an addition to
  `sketch_screen.dart`'s hamburger menu, `sketch_controller.dart` (batch
  create + one undo entry), `sketch_api_client.dart`.
- **Risk**: medium-high - a genuinely new backend dependency and parsing
  surface, a real blocking dependency on Phase 6.2's Arc (or an explicit
  flatten-to-lines interim decision), a unit/scale UX built from
  scratch with no existing convention to extend, and DWG needs its own
  explicit non-goal framing rather than being assumed free alongside
  DXF.

---

## Phase 9 — Convert/Translate Entities (bring in lines from other sketches and body edges)

### 9.1 Convert external geometry into real, editable entities in the active sketch
**Overlaps substantially with Phase 4.3** (deferred above) - both are
fundamentally "a Sketch referencing something outside itself for the
first time." Whichever of the two ships first effectively decides where
that concept first enters `app.sketch.models` - see the sequencing note
at the end of this section.
- **Current state**: two very different source types, with very
  different reference-stability properties already established
  elsewhere in this codebase:
  - **Body edges/vertices**: the raw `MeshDto` ids the 3D viewport's own
    hit-testing uses (`face_ids`/`edge_ids`/`topology_vertex_ids`) are
    explicitly documented as "only stable within one response" - a
    Body is rebuilt from scratch on every mesh request. The durable
    mechanism that already exists is `SubShapeRef`
    (`document/models.py:191-216` - `body_id` + `shape_type` + an
    OCCT-enumeration `index` captured at reference time), already used
    by Fillet/Chamfer/Create Plane, re-resolved fresh via
    `resolve_subshape` (`document/extrude.py:757-778`), which fails
    closed (`422 missing_reference`) if the Body's topology changed
    enough to invalidate the index - a known, already-accepted risk in
    this codebase ("cheap to fall back from later if it proves too
    fragile in practice" - its own doc comment), not something this
    phase introduces new.
  - **Other-Sketch geometry**: `SketchEntityRef` (sketch id + entity
    id), already used by Extrude's `profile_refs`, Revolve's
    `axis_ref`, and Sweep's multi-Sketch `path_refs`, resolved via a
    plain dict lookup by permanent id (`sketch/store.py`'s
    `resolve_sketch_entity`) - materially more durable than the
    body-edge case, since ids are never reassigned, only failing if the
    source entity was itself deleted. Revolve's and Sweep's own doc
    comments already confirm the source Sketch need not be the same one
    the Feature's own profile lives in, or even a single Sketch per
    Feature.
  - The client already has essentially all the picking infrastructure
    this needs, none of it purpose-built for this feature: 
    `SelectionEntityKind`/`SelectionEntityRef`
    (`viewport3d/selection_hit_test.dart:61-129`) already treat Body
    edges/vertices and other-Sketch Points/Lines/Circles as first-class,
    uniformly-handled members of one type; `SelectionFilterState`
    (`selection_filter.dart`) already has a proven per-tool-panel
    filter pattern (Fillet's edge+face filter, Revolve's
    body+sketchLine-only filter, Sweep's ordered multi-Sketch chain);
    the Fillet panel's open/seed-selection/live-preview/close session
    pattern (`part_screen.dart`'s `_openFilletPanel` et al) is a ready
    template; and a dedicated "pick a whole source Sketch" mode already
    exists separately (`isSketchPickerMode`/`pickableSketchIds`,
    `feature_tree_panel.dart`, used by Extrude/Revolve's own "which
    Sketch is my profile" step) for the "which Sketch am I converting
    from" step.
  - What's genuinely new: **nothing today actually materializes a copy
    of external geometry as new persisted Point/Line rows inside a
    different Sketch's own collections.** Every existing reference
    (`SketchEntityRef`, `SubShapeRef`) is only ever consumed live by a
    downstream Feature's own compute step (Extrude/Revolve/Sweep/
    Fillet) - none of them spawn new sketch-native entities in a
    sibling Sketch. That's the actual novel mechanic here.
- **Proposed approach - split into two real sub-scopes, not one**:
  - **v1: frozen one-time copy, no live link.** Pick a Body
    edge/vertex or another Sketch's Point/Line/Circle (reusing the
    selection infrastructure above, scoped to a new filter covering
    `sketchPoint`/`sketchLine`/`sketchCircle`/`edge`/`vertex`); resolve
    its current world-space geometry (already available - body edges
    via existing mesh/edge data, other-Sketch entities via that
    Sketch's own plane basis) and project onto the *active* sketch's
    plane, reusing `projectMeshEdgesOntoPlane`/`worldPointToSketch`
    (`viewport3d/sketch_geometry_3d.dart`, already built for Phase
    4.1's ghost-wireframe overlay) - cross-plane projection needs to be
    handled explicitly here, not assumed same-plane; then create real
    new Point/Line/Circle entities in the active sketch via the
    existing one-at-a-time endpoints, one grouped undo entry (same
    `deleteSelected`-style pattern as Phase 8's import). **This is
    genuinely client-only** - compute coordinates, call existing create
    endpoints - no new backend data model at all for v1, a real
    scope-reduction discovery from this research.
  - **v2: associative/live link, deferred until paired with Phase
    4.3.** Store a `SketchEntityRef`/`SubShapeRef`-style back-reference
    on the converted entity; add staleness detection, re-resolve on
    upstream model change, and the yellow "lost reference" tree-icon
    state (reusing `feature_tree_panel.dart:449-464`'s existing
    grey-when-locked color-branch pattern, exactly as Phase 4.3 already
    proposes). This half inherits Phase 4.3's own risk assessment
    verbatim and should be built *once*, shared between both features,
    not duplicated - if only one of {4.3, Convert Entities} is picked
    up, do v1 (frozen copy) alone and leave v2 for whichever phase
    tackles the shared external-reference foundation.
- **Files**: v1 - `viewport3d/part_screen.dart` (new selection filter +
  panel session), a new panel widget or an addition to
  `sketch_screen.dart`, `sketch_controller.dart` (creation calls + one
  grouped undo entry), reuses `sketch_geometry_3d.dart`'s projection
  helpers. v2 (shared with 4.3) - `models.py`, `schemas.py`,
  `router.py`, `feature_tree_panel.dart`.
- **Risk**: v1 - low-medium, almost entirely reuse of existing
  picking/projection/creation infrastructure, no new backend concept.
  v2 - high, inherits Phase 4.3's own "new data model concept,
  cross-feature staleness tracking" assessment directly; sequence
  together with 4.3 rather than attempting independently.

---

## Suggested delivery order

1. **Phase 1 — DONE, pending on-device verification** (interaction
   fixes, the now-broadened 1.4 coincident-on-drop/rectangle-centre/
   circle-centre fix, plus two items added mid-implementation: 1.5
   global sizing pass and 1.6 traditional CAD-style dimension
   rendering). Implemented without a Flutter SDK available to run
   `flutter analyze`/`flutter test` in the dev environment this was
   built in - see the on-device checklist delivered alongside this
   update for what to verify before considering it shippable.
2. **Phase 2 — DONE, pending on-device verification** (drag-pin solve
   semantics) — natural follow-on to Phase 1 since it changes what
   "drag" means; touches the solver but reuses the existing fixed-group
   mechanism. Backend logic verified directly against a real py-slvs
   install (anchor holds exactly; default no-anchor behaviour unchanged;
   conflicting anchors correctly fail to converge without crashing); the
   full API-level pytest suite needs `pythonocc-core`, which isn't
   installable in this sandbox, so that layer is verified via CI instead
   (see the new tests in `test_stage2b_solver_integration.py`).
3. **Phase 6.1** (line snap) — small, independent, can slot in anywhere.
4. **Phase 3 (3.1/3.2) — DONE, pending on-device verification**
   (constraint color feedback, client-side DOF/rigidity analysis) — new
   `client/lib/sketch/dof_analysis.dart` implements the per-constraint-
   type DOF-cost table via a union-find clustering algorithm (a
   documented, honestly-approximate simplification of the full
   combinatorial pebble game - see that file's own doc comment for the
   algorithm and its known edge-case limitations), wired into
   `sketch_canvas.dart` (dark-green/red Line/Circle/Point coloring) and
   `sketch_controller.dart` (`beginPointDrag`/`beginLineDrag` refuse to
   grab an over-constrained Point). Covered by pure-Dart unit tests
   (`dof_analysis_test.dart`) verified by hand-tracing the DOF arithmetic
   against the algorithm's own formulas (no Dart SDK in this sandbox to
   run them directly - see CI).
5. **Phase 4.1 + 4.2 + 4.3** (3D context, orbit view, body-edge
   dimensioning) — now sequenced together rather than 4.1 being a
   quick win, since all three need the same underlying capability
   (real, hit-testable body geometry inside the sketch view). Do 4.2
   (orbit, look-only) first as it's the most self-contained reuse of
   existing camera code, then 4.1+4.3 together once interactive body
   geometry is in place. 4.3 remains the largest item here and may
   still warrant its own scoping doc when picked up.
6. **Phase 5** (sketch orientation, discrete flip/rotate) — do before
   the retrospective-redefine part of 4.3 if both are in flight, since
   redefinition is simpler against an already-generalized orientation
   model.
7. **Phase 6.2** (new shape tools) — ongoing backlog, pick off in the
   confirmed complexity order. Arc/Polygon/Slot/Ellipse (6.2.1-6.2.4)
   are done; Spline (6.2.5) and Text (6.2.6) are now scoped (see those
   sections) but not yet implemented. Do Spline before Text - besides
   being the lower-risk of the two, Text's recommended v2 "explode to
   editable curves" feature explodes *into* Spline segments, so having
   Spline already shipped means that path is buildable later without
   backfilling anything. Text's own first step, before any other work
   on it starts, is the five-minute on-device check of whether
   `pythonocc-core`'s `text_to_brep` addon is actually present in this
   project's pinned conda build - see 6.2.6.
8. **Phase 9.1 (v1, frozen-copy Convert Entities)** — can slot in any
   time after Phase 4.1 (needs its plane-projection helpers), genuinely
   client-only, no dependency on Phase 4.3.
9. **Phase 4.3 + Phase 9.1 (v2, associative link)** — do these together
   if both are ever picked up, building the shared external-reference/
   staleness-tracking foundation once rather than twice; either can go
   first structurally, but building it in isolation for just one of them
   means redoing the same design work when the other arrives.
10. **Phase 8** (DXF import) — sequence Phase 6.1 (Arc) before it, or
    explicitly commit to the flatten-arcs-to-lines interim approach
    described in 8.1; independent of everything else in this list
    otherwise.
11. **Phase 7** (hybrid 2D/3D environment) — do the recommended
    throwaway prototype/spike first, independent of every other item
    above; only invest in the full callback/gesture-mode plumbing once
    the perspective-camera visual-fidelity question is actually
    answered on a real device.

## Cross-cutting notes (architecture fit)

Raised and resolved while scoping Phase 3, but relevant to the whole
package:

- **AI/API-driven model building**: the project was already designed
  API-first — `docs/project-brief.md` §6/§8 states the server is
  stateless, the client holds the authoritative model, and the original
  Stage 1 build was verified via direct API calls with no UI at all.
  Nothing in this package changes that contract. The one new thing
  (Phase 3's client-side DOF checker) is Flutter-only UI logic with no
  backend endpoint and must stay advisory-only, never authoritative —
  see the architecture rule under Phase 3.
- **Future standalone fork (lower priority)**: no structural obstacle
  found in anything scoped here — the stateless/no-persistence design
  was already fork-friendly. The one thing to isolate cleanly for this
  reason is Phase 3's DOF-cost table (see its fork note).
- **iOS port**: also not a new consideration — Windows/Android/iOS was
  the stated target client set from the original vision (§1, §3), so no
  architecture rework is implied. Phase 1's move away from
  timing-based double-tap-drag detection toward an explicit FAB is a
  net positive for cross-platform gesture consistency. Worth keeping
  Apple's ~44pt minimum touch-target guidance in mind when tuning the
  point hit-radius down in 1.2 (today's effective ~44px diameter is
  already close to that line).
