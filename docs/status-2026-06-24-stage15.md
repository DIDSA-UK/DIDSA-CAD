# Stage 15 status — 2026-06-24

Branch: `claude/new-session-1vxwt7` (tracks `origin/claude/new-session-1vxwt7`).
Builds on Stage 14 (merged to `main` via PR #29).

## Items

| # | Item | Status | Commit |
|---|------|--------|--------|
| 1 | Entity placement ghost preview | Complete | `59e3318` |
| 2 | Double-tap-drag dimension/constraint labels to reposition | Complete | `64cabf7` |
| 3 | RTS edge-pan only while cursor moving | Complete | `59e3318` |
| 4 | Snap-point hover highlight | Complete | `59e3318` |
| 5 | Wire remaining constraint buttons (coincident/parallel/perpendicular/equal-length) | Complete | `c158983` |
| 6 | Rectangle sketch tool | Complete | `9942a3e` |
| 7 | Closed-profile area fill | Complete | `de1606f` |

All 7 items from the Stage 15 prompt are implemented and verified. No backend
code was touched this session (items 1–7 were all client-only; item 7 reuses
the pre-existing `GET /sketch/sketches/{id}/profile` endpoint and schema
unchanged).

## What changed, by item

**1 — Ghost preview**: `SketchController.activeDrawGhost` (sealed
`DrawGhost`/`LineGhost`/`CircleGhost`/`RectGhost`) tracks the in-progress
entity from its first placed point to the live cursor; `_SketchPainter`
renders it as a dashed preview every frame. No backend calls.

**2 — Label drag-to-reposition**: `SketchController` holds a
`Map<String, Offset> _labelOffsets` (client-side only, never sent to the
backend) with `labelOffsetFor`/`beginLabelDrag`/`updateLabelDrag`/
`endLabelDrag`/`resetLabelOffset`. `sketch_canvas.dart` exposes a public
`dimensionLabelAt(controller, transform, canvasPos, radius)` free function
used both by the painter (to draw labels at their offset position) and by
the existing double-click-drag gesture detector (checked before
point-dragging, so label-drag and point-drag stay mutually exclusive). A
drag under 4px resets the offset to zero (the "double-tap" gesture).

**3 — Idle-aware edge-pan**: `_SketchCanvasState` tracks
`_lastCursorMoveTime`, updated on any non-zero cursor-move delta.
`_onEdgePanTick` now also requires
`DateTime.now().difference(_lastCursorMoveTime) < _edgePanIdleThreshold`
(150ms) before panning, so the canvas no longer auto-scrolls once the
cursor stops moving even while still hovering the edge.

**4 — Snap highlight**: `SketchController.snapCandidatePointId` exposes the
existing `_existingPointIdNear` snap lookup; the painter draws a 2x-radius
highlight + concentric ring around it in all draw-mode tools.

**5 / 6**: carried over from the prior segment of this session — constraint
buttons for Coincident/Parallel/Perpendicular/EqualLength wired end-to-end,
and a full Rectangle sketch tool (Two Corner / Centre + Corner / Three
Point construction methods) added alongside Line/Circle/Point.

**7 — Closed-profile fill**: `ProfileDetectionDto` (in
`lib/api/sketch_api_client.dart`) now also parses the nested
`profile.point_ids` from the backend's `ProfileDetectionResponse`.
`SketchController._refreshProfile()` calls the existing
`GET /sketch/sketches/{id}/profile` and stores the result in a new
`List<String>? closedProfilePointIds` (non-null only when the status is
`closed_loop` and the loop has points). It's called from inside
`_refreshAllPoints()`, so it piggybacks on every one of that method's ~13
existing call sites with no per-site changes needed. `_SketchPainter` draws
the fill (`Color(0xFF4CAF82)` at 0.15 alpha) plus a 1.5px outline (0.35
alpha) from the ordered point ids, as the very first paint call — before
the reference-ghost wireframe's geometry and well before lines/circles —
so it never draws over anything else. Null `closedProfilePointIds` is a
complete no-op.

## Known bugs / deferred items

None identified this session. The two new item-7 unit tests cover both
directions of the transition (loop closes → fill appears; loop breaks via
deleting an edge → fill disappears on the next refresh), matching the
spec's required test list exactly.

## Test/analyze results

**`flutter analyze`**: 0 issues (fixed one incidental `withOpacity`
deprecation warning encountered while verifying items 1/3/4, switched to
`withValues(alpha: ...)`; same pattern used for item 7's new fill colors).

**`flutter test test/sketch_controller_test.dart`**: 95 passed, 0 failed
(89 after items 1/3/4's new tests, 93 after item 2's, 95 after item 7's).

**Full `flutter test`**: 106 passed, 7 failed — the same 7 pre-existing,
documented, out-of-scope failures present before this session began
(`mesh_geometry_test.dart`, `orbit_camera_test.dart`, `part_screen_test.dart`,
`reference_planes_test.dart`, `sketch_geometry_3d_test.dart`,
`triad_test.dart` — all `flutter_scene`/`flutter_gpu` load failures from a
pinned package incompatibility, unrelated to this session's work — plus
`widget_test.dart`'s confirmed-pre-existing assertion failure). No
regressions.

## Backend

Not touched this session. The `/sketch/sketches/{id}/profile` endpoint and
`ProfileDetectionResponse`/`ProfileResponse` schemas used by item 7 already
existed unchanged from a prior stage.

## Branch / commits

Branch: `claude/new-session-1vxwt7`, pushed to `origin/claude/new-session-1vxwt7`.

- `c158983` — Stage 15 item 5: wire Coincident/Parallel/Perpendicular/EqualLength constraints
- `9942a3e` — Stage 15 item 6: add Rectangle sketch tool
- `59e3318` — Sketch: ghost preview, snap highlight, and idle-aware edge-pan (items 1, 3, 4)
- `64cabf7` — Sketch: double-tap-drag to reposition dimension/constraint labels (item 2)
- `de1606f` — Fill the sketch's closed profile with a translucent green area highlight (item 7)
