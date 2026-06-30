# Prompt A — 3D viewport fixes — status — 2026-06-30

Branch: `claude/new-session-khsgmg`.

## Items implemented

| # | Item | Status | Files changed |
|---|------|--------|---------------|
| A2 | Box selection | Done | `part_viewport.dart` |
| A3 | Clip distance constants, auto-fit, slider | Done | `orbit_camera.dart`, `view_preferences.dart`, `part_toolbar.dart`, `part_screen.dart`, `part_viewport.dart` |
| A4 | Perspective off by default | Done (state only — see flutter_scene note below) | `orbit_camera.dart`, `view_preferences.dart`, `part_toolbar.dart`, `part_screen.dart`, `part_viewport.dart` |

---

## A2 — Box selection

**Approach.** A `GestureDetector(onDoubleTapDown: …)` wraps the existing `Listener` in `PartViewport.build`. The GestureDetector only adds the double-tap recogniser; it does not intercept raw pointer events — the Listener still receives them unconditionally. All orbit handler bodies (`_handlePointerDown/Move/End/Signal`) are untouched; all new A2 logic lives in the wrapper methods `_onPointerDown/Move/End`.

**State.** Two new `PartViewportState` fields: `Offset? _boxAnchor`, `Offset? _boxCurrent`; and a `bool _doubleTapDetected` latch.

**Gesture sequence.**

1. `_onDoubleTapDown(TapDownDetails)` fires when GestureDetector recognises the second tap-down while `selectionMode` is true. Sets `_doubleTapDetected = true`, anchors the box at `_cursorPosition ?? _viewportCenter()`, resets `_selectionGestureTravel`.
2. Subsequent `_onPointerMove` events extend `_boxCurrent` (clamped to viewport) when `_doubleTapDetected` is true, bypassing the normal cursor-move path.
3. `_onPointerEnd`: if `_doubleTapDetected` is true and `_selectionGestureTravel >= 4.0 dp` → `_finalizeBoxSelection`; otherwise → `_cancelBoxSelection`.

**Hit-test.** `_hitTestEntitiesInBox(Rect, MeshDto)` projects each topology vertex, edge midpoint, and face centroid via `_worldToScreen` and tests containment in the box. Returns `List<SelectionEntityRef>` in vertex → edge → face priority order (same as `hitTestMeshEntities`). Each hit fires `onSelectionToggle` — the accumulate-don't-replace contract is owned by `PartScreen` (same as single-tap selection).

**Projection.** `_worldToScreen(vm.Vector3)` performs geometric frustum projection using `cam.position`, `cam.target`, `cam.right`, `cam.up` (two new public getters added to `OrbitCamera`), and the fixed `kCameraVerticalFovRadians = π/4` constant (same assumption as `selection_hit_test.dart`). flutter_scene provides no `worldToScreen` inverse API, so the math is done in Dart. Returns `null` for points behind the near clip plane or when the viewport size is degenerate.

**Overlay.** A `_BoxSelectionPainter` (`CustomPainter`) renders a filled + stroked rectangle using `_selectedColor` (fill at alpha × 0.15, stroke at alpha × 0.85). Wrapped in `IgnorePointer` as a sibling in the `Stack`, visible only while `_boxAnchor != null && _boxCurrent != null`.

---

## A3 — Clip distance

**Constants.** `kDefaultNearClip = 0.1` and `kDefaultFarClip = 3000.0` added as top-level constants in `orbit_camera.dart`, adjacent to where clip distances are applied. `OrbitCamera.defaultFarClip`, `_minFarClip` updated to reference `kDefaultFarClip` (was `1000.0`).

**Persistence.** `ViewPreferences` gained `farClipPrefKey`, `defaultFarClip`, `_farClip`, `farClip` getter, `setFarClip(double)`. Loaded alongside the other view preferences in `ViewPreferences.load()`.

**View menu slider.** `PartToolbar` gained two library-level helpers:
- `sliderToClip(t)` = `exp(lerp(log(500), log(50000), t)).round()` — maps [0,1] → [500,50000] mm logarithmically.
- `clipToSlider(farClip)` = inverse of the above.

The View submenu has a new "Far clip: N mm" label + `Slider` above the reference-planes divider. Logarithmic mapping gives the slider the same perceived resolution across the full range.

**State.** `PartScreen` holds `_farClip` (loaded from `ViewPreferences` on init), writes it back via `_onFarClipChanged`, and passes it to both `PartToolbar` (renders the slider) and `PartViewport` (applies it to `_camera.farClip`).

**Auto-fit on recentre.** The "Reset view" button now calls `_doRecentre()` instead of `_camera.reset()` directly. `_doRecentre` computes the mesh AABB, derives the diagonal `sqrt(dx²+dy²+dz²)`, and sets `farClip = max(kDefaultFarClip, 2.0 * diagonal)`. The result is written to `_camera.farClip`, `_camera.nearClip = kDefaultNearClip`, and propagated to `PartScreen` via `onFarClipChanged`. If no mesh is loaded, only `_camera.reset()` runs (no clip change).

---

## A4 — Perspective off by default

**flutter_scene limitation.** flutter_scene 0.18.x provides only `PerspectiveCamera` with a fixed π/4 vertical FOV — there is no `OrthographicCamera` and no settable FOV. The two projection modes are visually identical until flutter_scene exposes orthographic support. The state, persistence, and UI toggle are fully wired; the rendering difference is a TODO.

**State.** `OrbitCamera.isPerspective` (bool, default false). `ViewPreferences` gained `perspectivePrefKey`, `defaultIsPerspective = false`, `_isPerspective`, `isPerspective` getter, `setIsPerspective(bool)`.

**View menu toggle.** The View submenu's first entry is a `Perspective` `ListTile` with a checkbox icon (checked when `isPerspective` is true). Tapping it calls `onPerspectiveChanged(!isPerspective)`. State flows `PartScreen._isPerspective` → `PartViewport.isPerspective` → `_camera.isPerspective` (synced in `initState` and `didUpdateWidget`).

**Scroll-wheel wrapper.** `_onPointerSignal` wraps `_handlePointerSignal` — the orbit handler body is untouched, and the wrapper is the extension point for future orthographic-specific scroll behaviour (e.g. adjusting an ortho scale factor without moving the camera).

---

## Tests added

| File | Tests |
|------|-------|
| `test/clip_distance_test.dart` (new) | `sliderToClip(0.0)` ≈ 500; `sliderToClip(1.0)` ≈ 50000; round-trip for several values; monotone; `clipToSlider` endpoints; auto-fit returns `kDefaultFarClip` for empty/small mesh; `max(kDefaultFarClip, 2·diagonal)` for large mesh; exact boundary case |
| `test/part_viewport_test.dart` (extended) | A2 double-tap-then-drag fires `onSelectionToggle` for in-box entities; A2 double-tap with < 4dp travel does not fire `onSelectionToggle` |
| `test/part_screen_test.dart` (extended) | A4 `PartScreen` starts with `isPerspective = false`; toggling the View menu's Perspective entry switches to true then back to false; no exception during either transition |

---

## Constraint compliance

All orbit handler bodies (`_handlePointerDown`, `_handlePointerMove`, `_handlePointerEnd`, `_handlePointerSignal`) are line-for-line unchanged. Every new behaviour (A2 box selection, A3 farClip sync, A4 perspective sync, A3 recentre auto-fit) lives exclusively in the wrapper methods `_onPointerDown/Move/End` and `_onPointerSignal`, or in new helper methods called from them.
