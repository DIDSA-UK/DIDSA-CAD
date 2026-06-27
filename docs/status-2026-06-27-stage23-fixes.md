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
| 6 | `_dependents.isEmpty` assertion on Set Length | Confirmed correct | `sketch_canvas.dart` (`_GhostValueEditorState` owns its own `FocusNode`, calls `unfocus()` before the controller call that removes the widget); no `InheritedWidget`/`InheritedNotifier` exists anywhere under `client/lib` |
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
