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
- **Current state**: not supported at all today. Sketch constraints and
  dimensions only ever reference in-sketch `PointDto`/`LineDto`
  entities; there is no concept of a sketch entity referencing external
  body geometry (edges/vertices from other features) anywhere in
  `models.py`, `constraints.py`, or the client dimension code. Separately,
  the feature-tree already has a reusable pattern for this kind of
  status color: `feature_tree_panel.dart:449-464` conditionally colors a
  feature's icon (grey when `locked`) — a direct template to extend
  with a `hasLostReference` yellow state.
- **Proposed approach**: this is the largest, most structural item in
  the package. Needs: (a) a new backend concept of an "external
  reference" on a sketch (edge/vertex id + snapshot of its geometry at
  reference time, so a dimension can still render/solve even before
  the live lookup resolves), (b) staleness detection when the
  referenced feature is edited/deleted (re-resolve on model change,
  flag `hasLostReference` if the id no longer resolves), (c) client
  picking UI to let the user select body edges/points while placing a
  dimension, (d) the tree-icon yellow state reusing the existing
  color-branch pattern. Recommend scoping this as its own follow-up
  design doc rather than folding into the rest of this package — it's
  materially bigger than every other item here and touches the core
  data model (a sketch referencing something outside itself for the
  first time).
- **Files**: `models.py`, `schemas.py`, `solver.py` (external refs feed
  the solve as fixed inputs), `router.py`, `sketch_dimension_bar.dart`,
  `sketch_controller.dart`, `feature_tree_panel.dart`.
- **Risk**: high — new data model concept, cross-feature staleness
  tracking, and new picking UX all at once. Treat as its own
  mini-project.

---

## Phase 5 — Sketch orientation control

### 5.1 Flip / rotate sketch axes, reference-axis alignment, retrospective redefine
**Decided: discrete steps** (90° rotation + mirror flip), not free/
continuous rotation — confirmed. Simpler solver-basis math (a small
fixed set of basis transforms rather than an arbitrary angle), and a
much simpler axis-arrow indicator to keep in sync.
- **Current state**: `Sketch.plane` is only a fixed enum
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
  5. **Spline** — high; needs a new curve entity type end-to-end
     (model, solver representation, rendering, hit-testing/dragging of
     control points) — confirm what curve types py-slvs actually
     exposes before scoping further, this may need its own design doc.
  6. **Text (outline, for cutting/embossing)** — highest; effectively a
     separate feature from the rest of the sketcher — needs font
     outline extraction (e.g. via a font-parsing/path library) to turn
     glyphs into sketch curve geometry, unrelated to the constraint
     solver. Recommend scoping and estimating this one entirely
     separately from the rest of the sketcher package.
- **Files**: backend `models.py`/`constraints.py`/`solver.py` (new
  entity + constraint types per shape), `sketch_controller.dart`,
  `sketch_canvas.dart`, `sketch_speed_dial.dart`, `sketch_api_client.dart`
  for each.
- **Risk**: low→high across the list; sequence in the order above and
  stop to re-scope before spline/text specifically.

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
   confirmed complexity order; spline and text need their own scoping
   passes when reached.

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
