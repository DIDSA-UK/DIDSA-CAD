# 3D viewport selection mode — status — 2026-06-27

Branch: `claude/viewport-selection-mode-etxb4b`.

**Filename note**: the brief asked for this doc at
`docs/status-2026-06-26-stage23.md`, but that exact filename already exists
on `main` (PR #41, "Implement Stage 23: sketch UX polish (23a-23h)") -
a different, already-merged piece of work that happens to reuse the
"Stage 23" label for a different feature set entirely. Overwriting it would
destroy that history, so this doc uses a non-colliding name instead and
covers only the 3D-viewport selection-mode brief described below.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Orbit/Selection mode toggle FAB | Complete | `part_screen.dart` |
| 2 | Persistent cursor in selection mode | Complete | `part_viewport.dart` |
| 3 | Hover highlight + hit-testing | Complete | `selection_hit_test.dart`, `mesh_geometry.dart`, backend `mesh.py` |
| 4 | Selection behaviour (toggle/accumulate/clear) | Complete | `part_screen.dart`, `part_viewport.dart` |
| 5 | Selection list drawer | Complete | `selection_list_drawer.dart` |
| 6 | Context action panel | Complete | `selection_context_panel.dart`, `selection_actions.dart` |
| 7 | Preserve orbit mode exactly | Complete | see "Item 7" below |

## What changed, by item

**Item 1 — mode toggle FAB**: `PartScreen` gained `_selectionMode` (bool,
default `false`) and `_selectedEntities` (`Set<SelectionEntityRef>`) state,
plus a second `FloatingActionButton` (distinct `heroTag`, since multiple
FABs are visible at once) that toggles between them. It respects the
existing Stage 22 z-order gating (`_toolbarOpen`/`_extrudeSketchFeature`
visibility) the other FABs already use. The tooltip names the mode a tap
will switch *into* ("Switch to selection mode" / "Switch to orbit mode"),
with `Icons.touch_app` for Orbit and `Icons.threed_rotation` for Selection.
Switching back to Orbit clears `_selectedEntities` entirely and turns
`selectionMode` off on `PartViewport`, which removes the cursor and both
drawers as a consequence of their own visibility gating - no separate
"force close" call needed.

**Item 2 — persistent cursor**: `PartViewportState` tracks `_cursorPosition`
(`Offset?`, null whenever selection mode is off). A `didUpdateWidget` block
resets it to the viewport centre on entering selection mode and nulls it on
leaving. New pointer-dispatch wrapper methods (`_onPointerDown`,
`_onPointerMove`, `_onPointerEnd`, `_onPointerHover`) route to either the
*existing, untouched* orbit handlers or to new selection-mode-only logic
based on `widget.selectionMode`. In selection mode, touch/pen drag moves
the cursor by `delta * _cursorDragSensitivity` (0.6, so a full-viewport drag
doesn't blow past the model - "sensitivity-scaled, not 1:1" per the brief),
while a desktop mouse drives the cursor straight off `onPointerHover`'s
`localPosition`. A dedicated on-screen "Select" `FilledButton` commits
whatever's under the cursor - no tap-gesture detection is used for
selection. The cursor is rendered as a screen-space crosshair
(`_CursorCrosshairPainter`, a `CustomPainter` wrapped in `IgnorePointer` so
it never intercepts pointer events).

**Item 3 — hover hit-testing**: Backend `mesh.py` now tessellates three new
parallel id arrays onto `MeshData` - `face_ids` (one per triangle, shared
across all triangles of one OCCT face), `edge_ids` (one per 6-float edge
segment, shared across every segment sampled from one OCCT edge), and a new
`topology_vertices`/`topology_vertex_ids` pair (real OCCT vertices - points
where 2+ edges meet - extracted via `TopExp_Explorer`/
`TopTools_IndexedMapOfShape` over `TopAbs_VERTEX`, the same de-duplication
approach `_extract_edges` already used for edges). All three are stable
only within one response, since the shape is rebuilt from scratch on every
request - documented inline as the "foundation for all future operations"
per the brief. `schemas.py`/`router.py` plumb these through the
`/document/parts/{id}/mesh` response with no new endpoint. Client
`MeshDto` gained matching fields (`faceIds`, `edgeIds`, `topologyVertices`,
`topologyVertexIds`), all defaulting to `const []` so older/incomplete
mesh JSON still parses.

`selection_hit_test.dart` (new) implements the actual nearest-entity
hit-test: `kSelectionHitRadiusPixels = 9.0` (8-10dp band, deliberately
*not* reusing the sketcher's larger radius), `hitTestVertices`/
`hitTestEdges` project each topology vertex/edge segment to screen space
and pick the nearest one inside the radius; `hitTestFaces` ray-casts
against the mesh triangles and is only consulted when no edge/vertex hit
inside the radius, per the brief's edge/vertex-priority rule.
`hitTestMeshEntities` ties the three together into one `HoverHit?`.
`PartViewportState._recomputeHover` calls this on every cursor move (via
`OrbitCamera.cameraFor(...).screenPointToRay`, reusing `flutter_scene`'s own
picking math rather than hand-rolling screen-to-world unprojection).

Highlight rendering reuses three building blocks added to
`mesh_geometry.dart`: `buildHighlightFacesNode` (a translucent triangle
overlay), `buildMeshEdgesNode` (a `PolylineGeometry` node with a wider
stroke, `kHighlightEdgeStrokeWidth`, for the colour-change-plus-thickness
hover/selected look the brief asks for on edges), and
`buildVertexMarkersNode` (renders each vertex as a near-zero-length
`PolylineGeometry` segment with a larger pixel `width`, exploiting
`PolylineGeometry.width` being a screen-pixel rather than world-unit
quantity to get a constant-screen-size dot regardless of camera distance).
`_hoverColor` (amber, alpha 0.55) and `_selectedColor` (blue, alpha 0.85)
are visually distinct per the brief's "selected entities = distinct colour,
not just hover colour" requirement.

**Item 4 — selection behaviour**: `PartViewport` stays ignorant of
add-vs-remove semantics - it only reports "this entity was hit" or
"nothing was hit" via `onSelectionToggle(SelectionEntityRef)` /
`onClearSelection()`, fired by the Select button off the current
`_hoverHit`. `PartScreen._toggleSelectedEntity` does the actual
`Set.remove`-else-`Set.add` toggle; `_clearSelectedEntities` does
`Set.clear()`. This mirrors the existing `selectedPlane`/`onPlaneTap`
controlled-widget pattern already used elsewhere in `PartViewport`.
Multi-select across entity types accumulates freely since it's a plain
`Set<SelectionEntityRef>` with value equality on `(kind, id)`.

**Item 5 — selection list drawer**: New `SelectionListDrawer` (stateless,
dumb - returns `SizedBox.shrink()` when `selectedEntities` is empty,
otherwise a height-capped (`maxHeight: 160`) `ListView.builder` of
`ListTile`s, one per selected entity, each with a leading kind icon, a
"Face/Edge/Vertex #id" label, and a trailing × `IconButton` that calls
`onRemove`). Removing the last entity is handled entirely by `PartScreen`'s
own gating - once the set empties, the drawer's gate (see Item 6 below)
stops rendering it, no separate "close" affordance needed.

**Item 6 — context action panel**: New `selection_actions.dart` defines
`ContextAction` and `contextActionsFor(Set<SelectionEntityRef>)`, a pure
function implementing the brief's composition table (edges-only -> Chamfer
+ Fillet; faces-only or vertices-only -> Create Plane; mixed
edges+vertices, no faces -> Create Plane "Normal to Edge Through Vertex";
mixed faces+vertices, no edges -> Create Plane "Parallel to Face Through
Vertex"; mixed edges+faces (+/- vertices) -> Create Plane + Chamfer +
Fillet; empty -> `[]`). `SelectionContextPanel` (new, stateless) renders
those actions as a horizontally-scrollable row of `OutlinedButton`s above
the selection list drawer, gated the same way (`SizedBox.shrink()` when
`contextActionsFor` returns empty). Every button's `onPressed` is `null`
via `_disabledCallbackFor`, written as an explicit per-action-label
`switch` (Chamfer / Fillet / the three Create-Plane label variants) so each
future CAD operation gets its own dedicated
`// TODO: wire up <action>` comment at its own callback site, even though
every branch currently returns `null`.

Both new widgets are deliberately "dumb" (no internal visibility/animation/
positioning) - `PartScreen` owns all of that via one combined
`Positioned`+`SafeArea`+`Column` block (panel above drawer, matching the
brief's stacking order), so the panel always sits directly above the
drawer with no manual height bookkeeping between separately-animated
widgets. The block needs no special-cased margin to avoid the mode-toggle
FAB, since `Scaffold.floatingActionButton` is always painted by Flutter in
its own layer above the `body` Stack regardless of what the body renders.

`PartViewport`'s own internal Select button rises from `bottom: 16` to a
static `_kSelectButtonRaisedBottom = 232.0` once `selectedEntities` is
non-empty, so it clears the panel+drawer instead of being covered by them -
documented in-code as a heuristic estimate (not a measured layout), since
`PartViewport` has no visibility into that sibling subtree's actual
rendered height.

**Item 7 — orbit mode preserved exactly**: The existing orbit gesture
handler bodies (`_handlePointerDown`, `_handlePointerMove`,
`_handlePointerEnd`, `_handlePointerSignal`) were not edited at all in this
work - confirmed by re-reading every diff hunk against `part_viewport.dart`
line by line. All new selection-mode behaviour lives in new wrapper
methods (`_onPointerDown`/`_onPointerMove`/`_onPointerEnd`/`_onPointerHover`)
that route to the old handlers unconditionally whenever
`widget.selectionMode` is false, and to new selection-only logic only when
it's true. `Listener`'s callbacks in `build()` were repointed at these
wrappers (a mechanical, behaviour-preserving rename for the orbit path -
every call into the old handler bodies is unconditional and unchanged).

## New test coverage

- `backend/tests/test_stage23_mesh_ids.py` (new): backend coverage for
  `face_ids`/`edge_ids`/`topology_vertices`/`topology_vertex_ids` on
  `tessellate_shape`'s output and the `/mesh` endpoint's JSON - id
  density/sharing semantics (one id per triangle, shared per OCCT face;
  one id per segment, shared per OCCT edge; one id per real OCCT vertex)
  and that a degenerate edge consumes no id.
- `client/test/selection_hit_test_test.dart` (new): pure-function coverage
  of `hitTestVertices`/`hitTestEdges`/`hitTestFaces`/`hitTestMeshEntities` -
  edge/vertex priority over a coincident face, the 8-10dp radius cutoff,
  "nothing in range" returning null, and the id-lookup helpers
  (`faceTrianglesForId`/`edgeSegmentsForId`/`vertexPositionForId`).
- `client/test/selection_actions_test.dart` (new): every row of Item 6's
  composition table, including the empty-selection -> `[]` case and that
  mixed-combo labels match the brief's exact static strings.
- `client/test/mesh_geometry_test.dart`: extended with coverage for
  `vertexMarkerSegments` and `triangleHighlightBuffers` (including the
  degenerate zero-area-triangle -> zero-normal-not-NaN case).
- `client/test/part_screen_test.dart`: extended with the Item 1 FAB-toggle
  test (tooltip/icon swap, both directions, no exception).
- `client/test/part_viewport_test.dart` (new, this segment): three
  widget-level tests against `PartViewport` directly -
  - **Item 7's required orbit-preservation test**: pumps a real `MeshDto`
    fixture in the default (Orbit) mode, performs a `dragFrom` gesture
    inside the viewport, and asserts `onSelectionToggle`/`onClearSelection`
    are never invoked, no "Select" button ever appears, and
    `tester.takeException()` is null throughout.
  - Entering selection mode (`selectionMode: true`) makes the Select button
    appear where it didn't before, with no exception.
  - With `mesh: null` and `selectionMode: true`, tapping the Select button
    (once the scene itself - which initializes independently of `mesh`
    being non-null - is ready) fires `onClearSelection`, never
    `onSelectionToggle`, exercising Item 4's "empty space + Select clears
    the selection" rule end-to-end through a real widget tree and gesture.

  This sandbox's `flutter_scene` GPU calls (`Scene.initializeStaticResources`,
  `UnskinnedGeometry.uploadVertexData`) are confirmed (from the pre-existing
  first test in `part_screen_test.dart` and its own doc comment) to actually
  execute under headless `flutter test`, which is why these are real pumped-
  widget-and-gesture tests rather than pure-function-only coverage.

## Test/analyze results

No Flutter/Dart SDK is installed in this sandbox (`which flutter dart`
finds nothing; confirmed again this session via a filesystem sweep for a
Dart SDK / pub cache, which also turned up empty) - same limitation called
out in every prior stage's status doc in this repo. `flutter analyze` and
`flutter test` could not actually be run here. Verification was manual:

- Every edited/created Dart and Python file was re-read in full after
  editing, checking brace/paren matching, method signatures used against
  their actual declarations (e.g. `MeshDto`'s exact constructor shape,
  `OrbitCamera.cameraFor(...).screenPointToRay`'s signature), and that no
  existing method body in `part_viewport.dart`'s orbit-handling section was
  altered.
- Cross-checked every new `vm.Vector4` colour constant is `static final`
  (not `static const`), since `vm.Vector4` has no const constructor - a
  mistake that would otherwise only surface as a compile error.
- Confirmed via `grep` that `vector4FromHex`/`colorFromHex` (existing
  `view_preferences.dart` helpers) and `Theme.of(context).colorScheme...
  withValues(alpha:)` (not the deprecated `withOpacity`) are used
  consistently with the rest of the codebase's conventions.
- The backend has a working pythonocc-core install in CI (per
  `.github/workflows/backend-verify.yml`), but that workflow was not run
  from this sandbox; `mesh.py`'s new `_extract_topology_vertices` mirrors
  `_extract_edges`'s already-working `TopTools_IndexedMapOfShape`/
  `TopExp_Explorer` pattern closely enough that the same OCCT API calls are
  in active, working use elsewhere in this file.

## Known gaps / deferred

- No on-device/emulator/`flutter test` run of any of the above - every
  claim is based on manual code reading only, same caveat as every prior
  client-side stage's status doc in this repo.
- Chamfer, Fillet, and Create Plane are intentionally unimplemented -
  every context-action button is permanently disabled
  (`_disabledCallbackFor` always returns `null`), with one
  `// TODO: wire up <action>` comment per action at its own callback site,
  per the brief's explicit scaffold-only scope.
- The existing `.github/workflows/backend-verify.yml` only builds/tests the
  Python backend - there is still no Flutter CI job in this repo, so a push
  to this branch gives no automated signal on any client-side change
  (existing or new) either.
- `_kSelectButtonRaisedBottom` (232.0) is a static heuristic, not a
  measured layout value - if `SelectionContextPanel`/`SelectionListDrawer`'s
  actual combined rendered height on a real device differs meaningfully
  (e.g. very long entity names wrapping, or many selected entities filling
  the drawer to its 160px cap on a very short screen), the Select button
  could end up slightly mismatched with the panel/drawer's true top edge.
  Not fixed here since `PartViewport` has no architectural visibility into
  a sibling widget's rendered size without new cross-widget plumbing
  (e.g. a `GlobalKey`/`LayoutBuilder` hookup), which felt like scope
  creep beyond what Item 5/6 asked for.

## Branch / commits

Branch: `claude/viewport-selection-mode-etxb4b`. See the branch's commit
log for exact hash(es)/message(s).
