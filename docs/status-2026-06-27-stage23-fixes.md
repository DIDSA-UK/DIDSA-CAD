# Stage 23 bug-fix round — status — 2026-06-27 (audit)

Branch: `claude/new-session-u2lhyo`.

**This is a verification pass, not a new fix round.** All 7 items in the fix
prompt were already implemented and merged to `main` by an earlier session
(commits `2dfa706`, `ef93d2e`, `6d349ab`, `791084c`, merged via PR #47/#48/#49,
documented in `docs/status-2026-06-27-viewport-selection-mode-fixes.md`). This
branch was created off current `main`, so it already contains that work. I
independently re-read every line of the relevant code against each of the 7
items below rather than trusting the prior commit messages, and made no
further code changes — there was nothing left to fix.

**Filename note** (same caveat the prior round documented): a *different*,
already-merged piece of work from PR #41 ("sketch UX polish") occupies
`docs/status-2026-06-26-stage23.md`. To avoid implying this round and that one
are the same feature, the prior fix round's own status doc deliberately used
`status-2026-06-27-viewport-selection-mode-fixes.md` instead of this literal
filename. This doc uses the filename the current prompt explicitly asked for,
since that prompt was given again verbatim this session - treat the
`viewport-selection-mode-fixes` doc as the canonical deep-dive and this one as
today's confirmation pass.

## Items

| # | Item | Status | Where verified |
|---|------|--------|-----------------|
| 1 | Intermittent face hover highlight | Confirmed correct | `part_viewport.dart` (`_handleSelectionPointerMove`/`_handleSelectionPointerHover`/`_recomputeHover`), `selection_hit_test.dart` (`hitTestFaces`, `hitTestMeshEntities`) |
| 2 | Selected entities not highlighted, distinct from hover | Confirmed correct | `part_viewport.dart` (`_syncSelectedEntityNodes`, `_syncHoverNode`, `didUpdateWidget`'s `selectedEntities` branch) |
| 3 | Vertex hover highlight not appearing | Confirmed correct | `backend/app/document/mesh.py` (`_extract_topology_vertices`), `schemas.py`, `document_api_client.dart` (`MeshDto.topologyVertices`/`topologyVertexIds`), `mesh_geometry.dart` (`buildVertexMarkersNode`) |
| 4 | Tap screen to select (remove Select button) | Confirmed correct | `part_viewport.dart` (`_onPointerDown`/`_onPointerMove`/`_onPointerEnd`, `_commitSelection`) - no `FilledButton`/`ElevatedButton` labelled Select exists anywhere in the file |
| 5 | Bottom drawer FAB overlap / excessive height | Confirmed correct | `selection_list_drawer.dart` (`DraggableScrollableSheet` sizes, `_fabColumnClearance` padding, `SafeArea`) |
| 6 | `_dependents.isEmpty` assertion on Set Length | Superseded - see Addendum below | Initially "Confirmed correct" per `sketch_canvas.dart`'s `unfocus()` pattern, but a real-device report falsified that; genuinely fixed (deferred removal past a full frame) in both `sketch_canvas.dart` and `sketch_ribbon.dart` |
| 7 | Hamburger → FAB above feature-tree FAB | Confirmed correct | `part_screen.dart` (FAB column: `hamburger-fab` always visible unless `_toolbarOpen` is false and an extrude panel is active, `feature-tree-fab` below it, `selection-mode-fab` in the `Scaffold.floatingActionButton` slot) |

## Detail per item

**1 - face hover.** `_handleSelectionPointerMove` and
`_handleSelectionPointerHover` both write `_cursorPosition` first, then call
`_recomputeHover()`, which reads only `_cursorPosition` (never a raw
event-local position) to build the ray via
`_camera.cameraFor(_viewportSize).screenPointToRay(cursor, _viewportSize)`.
`hitTestFaces` in `selection_hit_test.dart` is a pure Möller-Trumbore
ray-triangle intersection with no radius/distance gate at all; the 9px
`kSelectionHitRadiusPixels` / 16px `kVertexSelectionHitRadiusPixels` gates are
applied only inside `hitTestEdges`/`hitTestVertices`. `setState` wraps every
cursor-move call site, so a hover change is never silently dropped.

**2 - selected vs hover highlight.** Selected-entity highlight nodes
(`_selectedFacesNode`/`_selectedEdgesNode`/`_selectedVerticesNode`) are built
from `widget.selectedEntities` in `_syncSelectedEntityNodes`, independent of
`_hoverHit`, using a distinct `_selectedColor` from `_hoverColor`. They
persist across cursor moves since nothing re-triggers
`_syncSelectedEntityNodes` except a `selectedEntities` change.
`didUpdateWidget`'s `selectedEntities` branch calls `_syncSelectedEntityNodes()`
then `_syncHoverNode()` in that order, so the hover node (if any) is always
re-added to the end of the scene's node list after a selection change -
preserving "selected, then hover on top" paint order even when both target
the same entity.

**3 - vertex hover.** Backend: `_extract_topology_vertices` in `mesh.py`
populates `topology_vertices`/`topology_vertex_ids` using the same
`TopExp_Explorer` pattern `_extract_edges`/face tessellation already use;
`schemas.py` exposes both with `[]` defaults. Client:
`document_api_client.dart`'s `MeshDto.fromJson` parses
`topology_vertices`/`topology_vertex_ids` with `?? const []`, so an absent
field never throws. Rendering: this codebase renders all 3D highlights as
real `flutter_scene` GPU nodes rather than a 2D `CustomPainter` overlay -
`buildVertexMarkersNode` (`mesh_geometry.dart`) turns a hovered/selected
vertex's world position into a constant-screen-size dot via a near-zero-length
`PolylineGeometry` segment with a large pixel `width`; the GPU projects it
through the real view/projection matrices every frame as part of normal scene
rendering, which is the equivalent of the prompt's "manually project through
MVP in a painter" for this rendering architecture.

**4 - tap-to-select.** No `Select` button exists in `part_viewport.dart`.
Pointer dispatch goes through a raw `Listener` (not `GestureDetector`) with
its own tap/drag disambiguation: `_onPointerDown` resets
`_selectionGestureTravel`, `_onPointerMove` accumulates it and forwards to
`_handleSelectionPointerMove` (drag) or `_handleSelectionPointerHover` (mouse),
and `_onPointerEnd` calls `_commitSelection()` only if the gesture stayed under
`_tapTravelThreshold` - i.e. a tap commits the current hover (toggling it into
or out of the selection set, or clearing the set if the cursor is over
background), a real drag commits nothing. Orbit mode's existing tap/drag
handlers (`_handlePointerDown`/`_handlePointerMove`/`_handlePointerEnd`) are
untouched and unreachable while in selection mode.

**5 - bottom drawer.** `SelectionListDrawer` wraps its content in a
`DraggableScrollableSheet(initialChildSize: 0.18, minChildSize: 0.12,
maxChildSize: 0.4)`, with a `SafeArea` and `Padding(right:
_fabColumnClearance)` (72dp) around the `Material` content so the drag handle,
header, and entity list never sit under the bottom-right FAB column. The
header/handle/list all live in one `CustomScrollView`'s slivers rather than a
fixed-height `Column` + `Expanded ListView`, so dragging the sheet toward its
minimum size scrolls content out of view instead of overflowing.

**6 - `_dependents.isEmpty`.** `_GhostValueEditorState` (the inline
"Set length"-style dimension editor in `sketch_canvas.dart`) owns its own
`FocusNode`, disposed in `dispose()`. Both `_confirm()` and `_cancel()` call
`_focusNode.unfocus()` before the controller call that causes this widget to
be removed from the tree (`confirmGhostValue`/`cancelGhostEdit`), avoiding the
Focus-dependents race that previously tripped the assertion. Separately
confirmed no `InheritedWidget`/`InheritedNotifier` exists anywhere under
`client/lib` - all shared mutable state in this codebase already uses
`setState`/`ListenableBuilder`-style patterns, so 6a/6b/6c/6d's specific
remedies don't apply here; the actual root cause (an unmounting focused
`TextField`) is what's fixed.

**7 - hamburger FAB.** `part_screen.dart`'s top-left FAB column is, top to
bottom: `hamburger-fab` (visible whenever `_toolbarOpen` is true, or whenever
no extrude panel is active - i.e. always visible except the one case where an
extrude panel is open and the toolbar is already closed), then
`feature-tree-fab` (hidden while `_toolbarOpen`, unchanged Stage 22 rule). The
selection-mode toggle FAB lives in the separate
`Scaffold.floatingActionButton` slot (bottom-right, alongside the Add FAB),
both hidden while `_toolbarOpen` or an extrude panel is active - consistent
z-ordering with the rest of the FAB set.

## Test results

No Flutter SDK or pythonocc-core/OCCT is available in this sandbox (same
limitation prior rounds hit) - confirmed by attempting `flutter --version`
(not found) and importing `OCC` after installing `fastapi`/`pydantic` into a
scratch venv (`ModuleNotFoundError: No module named 'OCC'`). Verification here
was a full manual code read of every file touched by the 7 items
(`part_viewport.dart`, `part_screen.dart`, `selection_hit_test.dart`,
`selection_list_drawer.dart`, `mesh_geometry.dart`, `sketch_canvas.dart`,
`document_api_client.dart`, `backend/app/document/mesh.py`/`schemas.py`), plus
confirming the existing regression tests for these fixes are present:
`client/test/part_viewport_test.dart`, `selection_hit_test_test.dart`,
`selection_list_drawer_test.dart`, `selection_actions_test.dart`,
`sketch_canvas_ghost_editor_test.dart`, `backend/tests/test_stage23_mesh_ids.py`.

## Known gaps

None found against the 7 items in this prompt. As in every prior round, test
*execution* (as opposed to static code review) remains blocked by the
sandbox's lack of a Flutter SDK and pythonocc-core/OCCT - this is an
environment limitation, not a known defect in the code.

## Addendum — real-device report, same day

After the audit above shipped, real-device screenshots of a freshly-rebuilt
`main` pull surfaced two problems the static read missed:

**A. Sketch screen's menu FAB at bottom-right, not top-left.** Unlike
`part_screen.dart`'s 3D viewport (top-left hamburger, per item 7 above),
`sketch_screen.dart`'s `sketch-menu-fab` was stacked above
`SketchSpeedDial` at bottom-right - inconsistent with the viewport's
convention. Moved it to its own `Positioned(top: 8, left: 8, ...)` block
(rendered after `SketchRibbon` in the `Stack` so it stays tappable on top of
the ribbon), and `SketchSpeedDial`'s `Positioned` reverted to holding just
itself. No test referenced `sketch-menu-fab`/`openDrawer`/`sketch_screen` by
name, so this carried no test-breakage risk.

**B. Item 6's `_dependents.isEmpty` crash still reproduces live**, confirmed
by the reporter on a freshly-rebuilt app when confirming a "Set Length"
dialog - i.e. through `sketch_ribbon.dart`'s `_SetLengthDialog` (reached from
the ribbon's Length chip on a selected Line), not through the canvas's inline
dimension-mode ghost editor this round's item 6 verified. This directly
falsifies that "Confirmed correct" conclusion: the `unfocus()`-before-removal
pattern, present in *both* `_GhostValueEditorState` (`sketch_canvas.dart`,
Stage 23's own fix) and `_SetLengthDialogState` (`sketch_ribbon.dart`, an
earlier "Stage 23a" fix per its comment), is not sufficient by itself.

Root cause, by Flutter framework behavior rather than a captured stack trace
(still blocked by no Flutter SDK in this sandbox - see `Test results` above,
and `docs/status-2026-06-26-stage20.md`'s own prior conclusion that pinning
the exact dependent `Element` needs a real device stack trace beyond the
single assertion line): `FocusNode.unfocus()` only *schedules* a focus
change: `FocusManager` applies it during the next frame's pre-build phase,
not synchronously. Both sites were calling `unfocus()` and then immediately
performing the action that removes the focused `TextField`'s element in the
very same synchronous call - `Navigator.of(context).pop(value)` in the
dialog, the `confirmGhostValue`/`cancelGhostEdit` controller call in the
canvas editor - racing the deferred focus-change application instead of
waiting for it.

Fix applied to both sites: keep the `unfocus()` call, but defer the
removal-triggering call itself to `WidgetsBinding.instance.
addPostFrameCallback`, guaranteeing a full frame (and the focus-change
application within it) elapses before the focused widget is actually torn
down:
- `sketch_ribbon.dart`: `_SetLengthDialogState._submit()`/`_cancel()` now
  both funnel through a shared `_dismiss(value)` that unfocuses, captures the
  `NavigatorState`, then pops inside a post-frame callback (guarded by
  `navigator.mounted`).
- `sketch_canvas.dart`: `_GhostValueEditorState._confirm()`/`_cancel()` defer
  their `confirmGhostValue`/`cancelGhostEdit` calls the same way (guarded by
  `mounted`).

Added `client/test/sketch_ribbon_set_length_test.dart` - a regression test
for the `_SetLengthDialog` flow specifically (select a Line, tap the Length
chip, type a value, tap Set), since the existing
`sketch_canvas_ghost_editor_test.dart` only ever covered the canvas's ghost
editor and never exercised this dialog at all.

Caveat, stated plainly: without a Flutter SDK in this sandbox, none of these
widget tests can actually be run, and the fix is reasoned from documented
`FocusManager`/frame-scheduling behavior rather than a captured device stack
trace pinpointing the exact dependent `Element`. This is a genuine
strengthening of the mitigation (a stricter ordering guarantee than the
prior "call unfocus() first" pattern alone), not a guaranteed-by-reproduction
fix - if it recurs, the most useful next artifact is the full scrolled error
detail/stack trace from the device's red error screen, as
`status-2026-06-26-stage20.md` already recommended.

## Addendum 2 — vertex hover/selection (almost) never winning over an edge

A follow-up question from the user ("the cursor is over a vertex and the
line is highlighted instead") led to a second genuine bug in
`client/lib/viewport3d/selection_hit_test.dart`'s `hitTestMeshEntities`, not
covered by item 3's "Confirmed correct" verdict above (that item only
checked that vertex hover/selection *renders correctly once a vertex hit is
returned* - it never checked whether `hitTestMeshEntities` reliably returns
one in the first place).

`kVertexSelectionHitRadiusPixels` (16px) is deliberately wider than
`kSelectionHitRadiusPixels` (9px, used for edges), with a doc comment
explicitly stating the wider radius exists "so a corner is realistically
reachable without needing pixel-perfect cursor placement." But the old
comparison was:

```dart
if (vertexHit != null && (edgeHit == null || vertexHit.pixelDistance! <= edgeHit.pixelDistance!)) {
  return vertexHit;
}
```

i.e. being inside the vertex's wider radius was not itself sufficient - the
vertex still had to be at least as close as any in-radius edge. Every
vertex sits at the shared endpoint of one or more edges, and an edge's
closest-point-to-ray calculation is free to slide along the segment toward
wherever the cursor actually is, while the vertex is a single fixed point.
So for almost any cursor position off the vertex's *exact* projected pixel
- any direction with a component along an adjacent edge, which is nearly
every direction once 2+ edges meet at a corner - the edge becomes strictly
closer and wins outright, regardless of how generous the vertex's own
radius was. In practice this meant a vertex could be hit only in a sliver
a pixel or two wide dead-center on its own projection - consistent with the
user's report that moving the cursor around a vertex never highlighted it.

Fix: a vertex within its own radius now wins unconditionally, matching the
radius's stated intent -

```dart
if (vertexHit != null) return vertexHit;
if (edgeHit != null) return edgeHit;
```

Added a regression test,
`'a vertex within its own radius wins even when a different edge is
strictly nearer'`, in `client/test/selection_hit_test_test.dart` -
constructs a vertex ~10.8px off-ray (outside the edge radius, inside the
vertex radius) alongside an unrelated edge ~1.4px off-ray (much closer in
raw distance) and asserts the vertex still wins. All pre-existing
`hitTestMeshEntities` tests continue to pass unmodified, since every one of
them already had the vertex within radius (the bug only manifested when an
in-radius edge was *also* present and closer, which none of the existing
cases happened to exercise).

Same standing caveat as elsewhere in this document: no Flutter SDK in this
sandbox, so this is verified by static reading of the corrected logic
against the new and existing unit tests' worked-out pixel-distance math,
not by an actual `flutter test` run.

## Addendum 3 — three follow-up reports after Addendum 2 shipped

A further round of real-device feedback, after Addendum 2's vertex-priority
fix, surfaced three more issues - one a direct consequence of that fix
exposing a second, previously-dormant bug, the other two unrelated UI
requests.

**A. Vertex hover/selection now targets correctly but never renders.**
`client/lib/viewport3d/mesh_geometry.dart`'s `buildVertexMarkersNode` draws
each highlighted vertex as a "fake dot": a near-zero-length
`PolylineGeometry` segment (`vertexMarkerSegments`) given a large pixel
`width`, relying on the segment's *end caps* alone to produce a visible
disk. `buildMeshEdgesNode` (which it delegates to) never passed a `cap`
argument to `PolylineGeometry`, so it always used the package default,
`PolylineCap.butt` - confirmed against the actual `flutter_scene` v0.18.1
source (`packages/flutter_scene/lib/src/geometry/polyline_geometry.dart`,
fetched via WebFetch since no local Flutter SDK/pub cache exists in this
sandbox), where only `PolylineCap.round` adds the camera-facing disk at
each endpoint; `butt` leaves a near-zero-length segment with virtually no
extent in any direction, i.e. invisible. Edges (real, non-degenerate
segments) never showed this problem since their length alone gives the cap
choice nothing to matter for.

Fix: added a `cap` parameter (default `PolylineCap.butt`, preserving every
existing edge-rendering call site's behavior) to `buildMeshEdgesNode`, and
`buildVertexMarkersNode` now passes `cap: PolylineCap.round` explicitly.
`client/test/mesh_geometry_test.dart` only exercises
`vertexMarkerSegments`'s pure data step, not this GPU-bound rendering call,
so nothing existing could have caught this and nothing existing regresses.

**B. Sketch screen's contextual ribbon should sit in front of the hamburger
FAB.** `client/lib/sketch/sketch_screen.dart`'s `Stack` built the
`sketch-menu-fab` `Positioned` block *after* `SketchRibbon`'s
`Positioned.fill`, so - per Flutter's later-children-paint-on-top `Stack`
ordering - the FAB sat in front of the ribbon whenever both occupied the
same top-left corner. Swapped the order so `SketchRibbon` now comes after
(in front of) the FAB block. No test references `sketch-menu-fab` or
mounts `SketchRibbon` via this screen's `Stack` (the one test that mounts
`SketchRibbon`, `sketch_ribbon_set_length_test.dart`, does so standalone),
so this carried no test-breakage risk.

**C. 2D sketcher's point hit-box is too small.** Same underlying class of
bug as Addendum 2's 3D fix, reported independently: `_entityAt` in
`client/lib/sketch/sketch_controller.dart` checked points, lines, and
circles all against the same `radius` (itself `minTapHitRadiusPixels`
(22px) converted to sketch units, or `snapRadius`, whichever is larger -
see `hitRadiusForPixelsPerUnit`). A line/circle offers its entire
length/circumference as a target; a point is one exact location, so the
same radius is a much smaller *effective* target for a point. Added
`pointHitRadiusMultiplier = 1.6` and applied it only to the points pass
(`radius * pointHitRadiusMultiplier`), leaving the lines/circles passes at
the original `radius` - mirroring the 3D viewport's
`kVertexSelectionHitRadiusPixels` (16px) vs `kSelectionHitRadiusPixels`
(9px) asymmetry that Addendum 2 fixed the priority logic for.

Verified by hand against every `handleCanvasTap` call site in
`client/test/sketch_controller_test.dart` that selects a Line/Circle: each
deliberately taps at least ~1.0 sketch unit away from the nearest stored
Point (several carry an explicit "away from the line's midpoint" comment
for this reason already), comfortably outside the new 0.8-unit
(`snapRadius (0.5) * 1.6`) default point radius - so none of them flip from
a line/circle hit to a point hit under the wider radius. Every tap that
*was* already within the old radius of a point stays within the new, wider
one too, so no point-hit test's outcome changes either. No new regression
test was added for this widening itself, since it only changes a numeric
threshold the existing tests' worked tap coordinates already clear with
margin, rather than changing any branch of comparison logic the way
Addendum 2's fix did.

All three fixes are unverified by an actual `flutter test` run, for the
same standing reason as everywhere else in this document: no Flutter SDK
in this sandbox.
