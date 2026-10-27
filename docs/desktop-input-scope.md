# Mouse, keyboard and big-screen use — scope

**Status:** decisions taken by the owner on 26 Oct 2026 (section 7); D1 and D2 built on branch
`claude/flutter-desktop-mode-ui-pxmq0q` (Progress below). Written 26 Oct 2026 from a read of `client/lib` on `main` and the owner's first test on a Samsung phone in DeX (external monitor, mouse, keyboard): "reasonable, but needs
polish and alignment with desktop CAD controls. Middle click drag to orbit; mouse cursors are on top of each other."

**Target:** an Android device driving an external monitor with a mouse and keyboard: Samsung DeX, and the same thing on non-Samsung
devices (Android 16 desktop windowing, Motorola Ready For, a plain USB-C monitor and Bluetooth mouse). The screen may or may not be a
touch screen, so touch must keep working everywhere but must not be needed for anything. The same work helps the Windows build, which
has the same gaps.

## Progress

| Phase | Summary | Status | Where |
|---|---|---|---|
| D1 | Middle/right mouse drags navigate in every mode (SOLIDWORKS bindings), one cursor, scroll-scaled wheel zoom | Done (not merged; unit and widget tested, the 3D viewport test skips without a GPU; not run on a device) | CAD `claude/flutter-desktop-mode-ui-pxmq0q` (`client/`) |
| D2 | Orbit about the geometry under the cursor, mouse box select on drag (window / crossing, Ctrl adds), middle double-click fit, SOLIDWORKS click selection for a mouse | Done (not merged; unit and widget tested, the 3D viewport tests skip without a GPU; not run on a device) | CAD `claude/flutter-desktop-mode-ui-pxmq0q` (`client/`) |
| D3-D7 | | Not started (D7 needs the owner's go-ahead) | |

Update this table with every milestone.

### D1 implementation notes

- `client/lib/viewport3d/mouse_navigation.dart`: the bindings (`mouseNavActionFor`: middle orbit, Ctrl+middle pan, Shift+middle
  zoom, right pan; modifiers read live on every move), `wheelZoomFactor` (one notch, taken as 50 px of scroll, keeps the old 10 %;
  smaller deltas zoom in proportion; never more than a notch per event), `dragZoomFactor` (drag up zooms in) and the cursor per
  action. Tests: `test/mouse_navigation_test.dart`.
- **3D viewport** (`part_viewport.dart`): a middle or right mouse press is taken first in `_onPointerDown`, ahead of gizmos, marquee,
  select and draw cursor (`_mouseNavPointer`); its moves and release never reach those handlers, so a right click no longer commits a
  selection (or fires a background tap in orbit mode) and a middle drag orbits in selection and draw-cursor modes. On release the hover
  is recomputed at the pointer. Left drag in orbit mode still orbits (the Orbit/Select button stays until D6 hides it for a mouse).
  The painted crosshairs are skipped while the last pointer was a mouse (`_lastPointerKind`); a `MouseRegion` shows the system cursor:
  crosshair (`precise`) for the draw cursor, a hand while a gizmo is held, `allScroll`/`grabbing`/`zoomIn` while orbiting/panning/
  zooming, else the arrow. Test: `test/part_viewport_mouse_navigation_test.dart` (skips without a GPU backend, as the other viewport
  pointer tests do here and in CI).
- **2D sketch canvas** (`sketch_canvas.dart`): middle drag pans (nothing to orbit), Ctrl+middle and right drag pan, Shift+middle zooms
  about the press point; the crosshair is not painted for a mouse; the cursor is a crosshair in draw mode and the arrow in select mode.
  Test: `test/sketch_canvas_mouse_navigation_test.dart`.
- **Mesh viewer**: the same middle/right bindings; left drag still orbits (nothing to select).
- What D1 loses for a mouse: the painted crosshair's colour (blue over geometry in select, green over a valid draw point). The hover
  pre-highlight still shows what's under the cursor in select; the draw case has only the cursor shape. Worth judging on the device.
- Not checked: the wheel notch size DeX reports (if under 50 px, each notch zooms a little less than before), and the Shift+middle
  zoom direction against SOLIDWORKS' (chosen as drag up = zoom in).

### D2 implementation notes

- **Orbit about the cursor** (`OrbitCamera.orbitAboutPointByScreenDelta`): a middle press hit-tests under the cursor
  (`PartViewportState._orbitPivotAt`: bodies, components and component edges/vertices, whatever the selection filter, reference
  planes skipped) and the drag orbits about that point - the target's offset from it is carried round in the camera's frame, so the
  point stays put on screen. Over empty space it orbits about the camera target as before. The target moves with it (as a pan
  does); Reset view recentres. Test: `test/orbit_camera_test.dart`.
- **Middle double-click** (`MiddleDoubleClickDetector`, platform double-tap time and slop): Reset view in the 3D viewport, Zoom to
  fit in the 2D sketch canvas. Not added to the mesh viewer (it has no fit action of its own yet).
- **Mouse box select** (2D canvas and the 3D-embedded sketch): a left press on blank canvas in select mode becomes a box as soon as
  it drags past the tap threshold - no 500 ms hold and no pop circle (both stay for touch). Dragged left to right it's a window
  (blue, entirely inside, as before); right to left it's a crossing (green, anything touching); Ctrl adds to the selection.
  `SketchController.selectInRect(rect, crossing:, additive:)`; the crossing geometry is in `sketch/marquee_selection.dart`
  (curves tested as fine polylines - circles/arcs/ellipses 96 samples a turn, splines 24 per span; arcs and ellipse arcs follow their
  counter-clockwise sweep). In the 3D view a mouse box only starts inside a sketch: **box select of bodies, faces and components is
  not built** - it was built once and parked (June 2026), see D7 in section 4.
- **Click rule** (`SelectClick` in `mouse_navigation.dart`): a plain mouse click replaces the selection, Ctrl+click adds or removes,
  a click on empty space clears, Ctrl+click on empty space keeps it. Touch is unchanged (sketch: each tap adds while the flyout is
  open; part: each tap toggles). `PartViewport.onSelectClick` reports the rule just before it commits a click; the 2D canvas sets
  `SketchController.selectClick` on every press. In the part screen a plain click only replaces **when no tool is open**
  (`_anyToolSessionActive`, the list that already hid the corner buttons): inside a tool every click keeps collecting picks as before,
  which is also how a SOLIDWORKS feature's selection box behaves. Tests: `test/sketch_controller_test.dart` ("desktop input D2"),
  `test/marquee_selection_test.dart`, `test/sketch_canvas_mouse_navigation_test.dart`, `test/part_viewport_mouse_navigation_test.dart`
  (skips without a GPU). The part screen's replace branch has no headless test (it needs the real viewport); D3 extracts it into a
  pure function and tests it (section 4), and it's on the device checklist (section 6).
- Select Other's click-then-hold still works with a mouse: its "undo the first click" is now always a toggle.

## 1. What the app did before D1

### 3D viewport (`viewport3d/part_viewport.dart`)

| Input | Orbit mode (default) | Selection mode / draw-cursor mode |
|---|---|---|
| Left drag | orbit | nothing but hover (the cursor follows; no orbit, no pan) |
| Right drag | pan | nothing but hover |
| Middle drag | **nothing** (`kMiddleMouseButton` is not read anywhere in `client/lib`) | nothing |
| Wheel | zoom toward the cursor (lens zoom, `zoomFovTowardScreenPoint`) | same |
| Left click | `_handleTap` (sketch plane / background tap) | select (toggle) / commit draw point |
| Left press and hold 500 ms | — | marquee (a touch gesture; same timer for a mouse) |
| Right click | nothing | nothing |
| Hover | nothing | moves the crosshair, pre-highlight (`_syncHoverNode`) |

- **Orbit and Select are two modes switched by a FAB** (`part_screen.dart` `_toggleSelectionMode`). That suits one finger, which can't
  both orbit and select. With a mouse it means **you cannot orbit or pan at all while selecting or sketching**, only zoom; you have to
  click the FAB, orbit, click it again. Many tools switch to selection mode for you (`_selectionMode = true` in about 20 places), so
  this happens all the time.
- **Two cursors.** In selection and draw-cursor modes the viewport paints its own crosshair (`_CursorCrosshairPainter`) at the
  cursor position. For touch that's the whole UI (the finger moves the crosshair like a trackpad). With a mouse the crosshair sits
  under the system arrow, because nothing sets a `MouseRegion` cursor on the viewport. The painted one also trails the arrow by a frame
  or two, since it's drawn by the app.
- Orbit always pivots on the camera target, not on the geometry under the cursor.
- Each wheel event zooms by a fixed 10 % whatever its size, so a trackpad's or a high-resolution wheel's stream of small scroll events
  zooms far too fast.

### Sketch canvas (`sketch/sketch_canvas.dart`) and mesh viewer (`mesh_viewer/mesh_viewer_screen.dart`)

- Sketch: left = cursor and click, right drag = pan, wheel = zoom to cursor, hover moves the cursor 1:1. Same painted crosshair under
  the system arrow. Marquee is still the 500 ms hold. Click-move-click and press-drag-release both move a grabbed entity: good.
- Mesh viewer: left drag orbit, right drag pan, wheel zoom. No middle button either.

### Keyboard

**No shortcuts at all.** No `Shortcuts`, `CallbackShortcuts`, `Actions` or `LogicalKeyboardKey` anywhere in `client/lib`. The only
`FocusNode`s are on the value text fields (ghost dimension, set length, offset). So there's no Esc, Delete, Enter, Ctrl+Z, Ctrl+S or
view keys. On Android an **unhandled key goes back to the system**, so Esc may act as Back and leave the screen (to check on the device).

### Menus, layout, cursors

- Context menus are touch-first: long-press, then a bottom sheet (`showActionSheet`, `action_sheet.dart`; about 23 bottom-sheet call
  sites). Right click doesn't open them.
- The layout is mobile-first: FAB columns in the corners, speed dials, bottom sheets, panels you drag to resize. The panels already have
  resize cursors (`feature_tree_panel.dart`, `assembly_tree_panel.dart`, `resizable_tool_panel.dart`) and there are about 170 tooltips,
  so hover works in places.
- Density stays at the Android default (no `visualDensity`), so controls are sized for fingers on a 27-inch screen.
- Manifest: `configChanges` already includes `screenSize|smallestScreenSize|screenLayout|density|uiMode`, so resizing a DeX window
  or moving between screens doesn't restart the activity. `resizeableActivity` is on by default. Nothing DeX-specific is needed there.

## 2. How desktop CAD does it

| | Orbit | Pan | Zoom | Right click | Select |
|---|---|---|---|---|---|
| SolidWorks | MMB drag | Ctrl+MMB | wheel (to cursor), Shift+MMB | context menu | LMB, box drag |
| Fusion 360 (default) | Shift+MMB | MMB | wheel | marking menu | LMB, window/crossing |
| Fusion "SolidWorks" preset, Inventor | MMB / Shift+MMB, F4 | Ctrl+MMB / MMB | wheel | menu | LMB |
| Onshape | RMB drag | MMB / Ctrl+RMB | wheel | menu on click without drag | LMB, box drag |
| FreeCAD (CAD style) | MMB+LMB or MMB+RMB | MMB | wheel | menu | LMB |
| Blender | MMB | Shift+MMB | wheel, Ctrl+MMB | menu | LMB |

What they all share, and what a user expects:

1. **Navigation never needs a mode switch.** Left is for selecting and drawing; the middle (or right) button moves the view, in every
   tool, sketches included.
2. Wheel zoom goes toward the cursor (the app has this already).
3. Orbit pivots on the point under the cursor when the drag starts (Onshape, Fusion, SolidWorks' "rotate about the point").
4. **A right click without a drag opens a context menu** for what's under the cursor; a right drag moves the view (Onshape) or does
   nothing.
5. Box select is a plain left drag on empty space. Left-to-right selects what's fully inside, right-to-left anything it touches
   (SolidWorks, AutoCAD, Fusion).
6. Esc cancels the current tool or clears the selection, Delete deletes, Enter or a middle click confirms, Ctrl+Z/Ctrl+Y undo and redo,
   F (or a middle double-click) fits the view, plus keys for the standard views.
7. The system pointer changes with context (arrow, crosshair when drawing, a hand over grab handles, resize arrows on splitters), and
   there's no second painted cursor.
8. Most offer **navigation presets** (Fusion, Onshape, FreeCAD) because everyone arrives with muscle memory from another package.

## 3. Recommendations

### R1. A mouse binding map, without modes (viewport, mesh viewer, embedded sketch, 2D sketch)

One small module (built in D1 as `viewport3d/mouse_navigation.dart`) that turns buttons and modifiers into an intent. All three
canvases call it instead of each testing `kPrimaryMouseButton` itself. **SOLIDWORKS is the template** (owner, 26 Oct 2026), with right
drag kept as pan so there's a pan with no keyboard attached:

| Mouse | Action |
|---|---|
| MMB drag | orbit (2D sketch canvas: pan) |
| Ctrl+MMB drag | pan |
| Shift+MMB drag | zoom |
| RMB drag (past the tap threshold) | pan (as before; SOLIDWORKS uses it for mouse gestures - owner to reassess in testing) |
| RMB click (no drag) | context menu at the cursor (R4) |
| Wheel | zoom to cursor, scaled by how far it scrolled (R1c) |
| LMB click | select / draw / commit (as the current mode says) |
| LMB drag on empty space | box select straight away, no 500 ms hold, direction picks inside or crossing (2D and 3D) |
| LMB drag on a gizmo handle | drag the handle (as today) |
| MMB double-click | fit all (the existing Reset view) |

These apply **whatever the Orbit/Select FAB is set to**. With a mouse, selection mode effectively stays on for the left button and the
view moves with the middle and right buttons. The FAB is still there for touch and does what it does now.

- **R1a, the routing fix itself:** in `_onPointerMove`'s `selectionMode` and `drawCursorMode` branches, a mouse event with the middle
  or right button down goes to orbit or pan instead of `_handleSelectionPointerHover` and `return`. A mouse event with only the left
  button keeps the hover path. That's a few lines in each branch and is what removes the "can't orbit while selecting" problem.
- **R1b, orbit about the cursor:** on a middle-button press, hit-test under the cursor (`hitTestBodies` already exists) and orbit
  about that point; over empty space, about the target as now. This is the single biggest "feels like CAD" change after R1a.
- **R1c, wheel and trackpad scaling:** `factor = pow(1.0015, scrollDelta.dy)` (tune the base) instead of a flat 1.1 per event, in
  both the 3D viewport and the sketch canvas. Also handle `PointerPanZoomUpdateEvent` (precision trackpads, Chromebooks, Windows)
  as pinch plus pan.
- **R1d, presets** (Settings, stored with the other client settings): SOLIDWORKS (above, the default), Fusion 360
  (Shift+MMB orbit, MMB pan), Onshape (RMB drag orbit, MMB pan, RMB click menu), Blender (Shift+MMB pan). Plus "invert wheel
  zoom" and an orbit speed slider. Cheap once R1 is a table, and it matters to people coming from any one of them.

### R2. One cursor

When the pointer is a mouse, **don't paint the crosshair; let the system draw it**:

- Wrap the viewport and sketch canvas `Listener` in a `MouseRegion` whose cursor follows the state: `SystemMouseCursors.precise`
  (crosshair) in draw-cursor mode and sketch draw tools, `basic` for select, `grab`/`grabbing` over and during a gizmo drag,
  `allScroll` (or `move`) while orbiting or panning. Flutter's Android embedding maps these onto Android pointer icons, which DeX shows.
- Track the kind of the last pointer event (`PointerDeviceKind`) in the viewport state and skip `_CursorCrosshairPainter` (and the
  sketch canvas's crosshair) while it is `mouse`. A touch brings the painted crosshair back on the next touch, so a touch monitor
  still works. The hover colour the crosshair carried (blue "on something", green "valid draw point") moves to the pre-highlight that
  `_syncHoverNode` already draws, plus the cursor shape.
- A system cursor has no lag, which suits a mouse better than any painted one.

### R3. Keyboard shortcuts

One `Shortcuts` + `Actions` layer per screen (`PartScreen`, `SketchScreen`, mesh viewer), built from a single shortcut table so the
help sheet and tooltips read from the same source. Single-key shortcuts must not fire while a text field has focus: a `Shortcuts`
above a focused `TextField` can take plain letter keys before the field gets them, so the actions check for focused text input and
step aside. Every key the app handles must be marked handled so Android doesn't turn it
into Back or a system action.

Suggested first set:

| Key | Action |
|---|---|
| Esc | cancel the active tool or panel; with none, clear the selection (never pops the screen) |
| Enter / numpad Enter | confirm the open tool panel (the same as its OK / tick) |
| Delete / Backspace | delete the selection (feature, sketch entity, occurrence, mate), with the existing confirm where there is one |
| Ctrl+Z / Ctrl+Y, Ctrl+Shift+Z | undo / redo wherever an undo stack exists (sketch; assembly transforms); greyed out elsewhere |
| Ctrl+S, Ctrl+Shift+S, Ctrl+O, Ctrl+N | save, save as, open, new |
| Ctrl+A | select all (sketch) |
| F | fit all (Reset view) |
| Ctrl+1 ... Ctrl+7 | front, back, left, right, top, bottom, isometric, as SOLIDWORKS (`animateToPlane` / `animateToIsometric` exist) |
| Ctrl+8 | normal to the selected face or plane (SOLIDWORKS) |
| Space | the view orientation picker (SOLIDWORKS) |
| Z / Shift+Z | zoom out / in (SOLIDWORKS) |
| Arrow keys, Shift+arrows, Ctrl+arrows | rotate the view, rotate 90°, pan (SOLIDWORKS) |
| Ctrl+B | rebuild / recompute (SOLIDWORKS) |
| P | perspective / orthographic toggle |
| S | the sketch tool menu; in a sketch: L line, C circle, A arc, R rectangle, D dimension, T trim, X construction |
| E, V | extrude, revolve (the tool shortcuts follow Fusion where they don't clash) |
| Shift+/ (?) or F1 | the shortcut sheet |
| Tab / Shift+Tab | move through the fields of a tool panel (check the panels' focus order) |

Avoid the Meta (Windows/Samsung) key, which DeX keeps for itself, and Shift+Space / Ctrl+Space, which switch keyboard language on
many Samsung devices. Add the shortcut to each button's tooltip ("Extrude (E)").

### R4. Right-click menus

Wherever a long-press opens a bottom sheet today (bodies, occurrences, mates, feature tree rows, sketch entities), a right click opens
the same entries as a desktop popup at the cursor (`showMenu`, or `MenuAnchor` for the tree). The simplest route: give
`showActionSheet` an optional position. When the gesture that opened it came from a mouse, it shows a popup menu at that position
built from the same `ActionSheetEntry` list; from touch, the bottom sheet as now. Then each call site only has to pass the pointer
position and wire up `onSecondaryTapUp` next to its existing long-press. Right click on empty viewport space: a menu with Fit all,
the standard views, perspective/orthographic, and Show/Hide.

### R5. Layout for a big window

Don't decide by platform (DeX reports Android). Decide by **window size** and **the input actually in use**:

- An app-wide `InputModality` notifier: a `Listener` at the top of the app (in `MaterialApp.builder`) records the kind of each
  `PointerDownEvent` / `PointerHoverEvent`, plus `HardwareKeyboard`. Values: `touch`, `mouse`. Mixed use just flips it back and
  forth; nothing is ever locked out.
- Width breakpoints from `MediaQuery.sizeOf`: at **≥ 1000 dp** with a mouse, a "desktop" layout:
  - feature tree / assembly tree as a docked left panel that stays open, the tool panel docked on the right, so the viewport is no
    longer covered;
  - the FAB and speed-dial actions in one toolbar along the top (a slim ribbon: Sketch, Features, Assembly, Inspect), with tooltips;
  - tool panels and pickers as anchored popovers or dialogs instead of bottom sheets;
  - `VisualDensity.compact` and the smaller button sizes Material uses on desktop (only while the modality is `mouse`, so a touch
    monitor gets back the bigger targets when you touch it);
  - the Orbit/Select FAB hidden while the modality is `mouse` (R1 makes it pointless), shown again on touch.
- Below 1000 dp, or with touch, the current layout unchanged. This is the biggest piece of work and benefits most from the owner's
  view on how far to go, so it comes last and on its own.

### R6. Smaller polish

- Hover highlights on tree rows and toolbar buttons (Material gives most of this once controls are proper buttons; check the custom
  rows in `feature_tree_panel.dart` / `assembly_tree_panel.dart`).
- Double-click a feature row to edit it; double-click a dimension to edit its value (already one click on touch; keep both).
- Ctrl+click adds to / removes from the selection, plain click replaces it, a click on empty space clears it (SOLIDWORKS' rule; the
  owner chose it for the mouse). Today every click toggles, which stays for touch. **Moved into D2.**
- A middle click in a sketch tool ends the current chain (like Enter), as SolidWorks does.
- Number fields: the wheel over a focused field nudges the value (Fusion), Up/Down arrows likewise.
- DeX window resize: check that panels clamp sensibly when the window is narrow or short (the resizable panels store fractions, so
  probably fine).

## 4. Phases

| Phase | Covers | Size | Notes |
|---|---|---|---|
| D1 | R1a, R1c, R2: middle and right drag navigate in every mode; one cursor; scaled wheel zoom | small | Fixes both things from the first test. Widget-testable with `tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton)`. |
| D2 | R1b, plain-drag box select, MMB double-click fit, desktop click selection for a mouse (R6) | small-medium | Built (Progress above). |
| D3 | R3: shortcut table, Esc/Enter/Delete/undo/save/views/fit, sketch tool keys, `?` sheet, tooltip hints. **Also from D2:** a fit action for the mesh viewer (F needs one), wired to its middle double-click too; the part screen's click rule moved into a pure, unit-tested function (Esc and Delete act on the same selection) | medium | Esc must never fall through to Android Back. |
| D4 | R4: right-click popups via `showActionSheet(position:)` | small-medium | One helper, then each call site. |
| D5 | R1d presets + settings, R6 polish | small | |
| D6 | R5: `InputModality`, the full desktop layout ≥ 1000 dp | large | The owner wants "a full desktop CAD experience" from a docked phone. Scope it separately (it touches every screen). |
| D7 | 3D box select of faces, edges, vertices, bodies and components (part and assembly), mouse and touch | medium | **A revisit of a feature the owner parked** - needs the owner's go-ahead. See below. |

### D7: 3D box select (revisit)

Built once as A2 (June 2026), tried three ways and rejected on the device each time - a projection that picked the wrong region, a
frustum test that picked nothing, then camera-axis dot products that picked unreliably - and parked: *"Not robust enough to rely on.
let's park it for now."* (`docs/status.md`, "2026-06-30 - Box selection"). The report's own lesson: each attempt could only be
checked on the device, with no toolchain to test it first. Two things are different now:

- `screen_projection.dart`'s `worldToScreen` already places every screen-space overlay (constraint labels, the origin marker, loft
  seam handles) on top of the real render, so a projection proven on the device exists to build on, instead of a fourth hand-rolled
  one.
- Flutter runs here, so "is this entity inside this box" can be unit-tested headless against known cameras (perspective,
  orthographic, focus transform) before it ever reaches the device, and the window/crossing rules can reuse the 2D crossing
  geometry (`sketch/marquee_selection.dart`) on projected polylines.

Rough shape: project each candidate's vertices/edge polylines/face outlines with `worldToScreen`; a window box takes what is wholly
inside, a crossing box what touches; respect the selection filter; Ctrl adds. Open questions for the owner before building:
whether hidden (back or occluded) geometry is picked (SOLIDWORKS picks through by default for edges; an occlusion test is more work),
what a box picks by default in a part (SOLIDWORKS: edges; faces are usually clicked), and whether touch gets it too (the double-tap
-then-drag of the old attempt, or the long-press the sketch uses). Kept out of D5 because it is a feature, not polish, and out of D6
because it doesn't depend on the layout.

D1 to D3 make DeX feel like a desktop CAD tool without touching the layout; D6 is what makes it look like one.

## 5. Testing

- Widget tests: Flutter's test gestures accept a pointer kind and buttons, and `tester.sendKeyEvent` / `sendKeyDownEvent` with
  modifiers drive shortcuts. Each phase adds tests for its bindings (MMB drag changes `OrbitCamera.orientation` in selection mode; RMB
  click opens a menu; Esc clears the selection and does not pop the route; a text field with focus swallows `E`). Read
  `docs/flutter-widget-test-lessons.md` first.
- The test touch paths must stay green unchanged: every routing change is gated on `PointerDeviceKind.mouse`.
- On the device (only the owner can do this): DeX with a mouse; DeX on a touch monitor, swapping between them; a non-Samsung
  desktop mode if one is to hand; a Bluetooth keyboard on the phone screen alone.

## 6. Not verified, to check on a device

Nothing here has been run; this is from reading the code. In particular, check on the device:

- that DeX passes the middle button through to Flutter as `kMiddleMouseButton` (Android's `BUTTON_TERTIARY` normally maps to it; some
  mice or DeX settings remap middle click);
- that a right click reaches the app and isn't turned into Back (the right-drag pan in the sketch suggests it does);
- what Esc and Backspace do today when nothing handles them (possibly Back);
- that `SystemMouseCursors.precise`, `grab` and `none` show in DeX (Flutter maps them to Android pointer icons, API 24+);
- the trackpad case: DeX on a laptop-style touchpad, or the phone screen used as a touchpad, delivers scroll events, not pan-zoom ones.

From D2 (none of it run on a device; the 3D viewport tests skip without a GPU):

- the part screen's click rule: with no tool open a plain click replaces and Ctrl+click adds/removes; inside a tool (Fillet, Extrude,
  Shell, ...) every click still adds to the tool's picks; in an assembly a face click closes the component's drawer;
- orbit about the cursor on a face, an edge, a component and empty space, perspective and orthographic, and inside a focused
  sub-assembly (the pivot goes through the focus transform);
- the mouse box in the 2D canvas and in the 3D-embedded sketch: starts on the first small drag, green right to left, Ctrl adds;
- middle double-click fit in the 3D view and the 2D canvas.

## 7. Decisions (owner, 26 Oct 2026)

1. **Template: SOLIDWORKS** (the larger user base). MMB orbit, Ctrl+MMB pan, Shift+MMB zoom, its view keys (R3).
2. **Right drag stays pan** for now (it gives a pan with no keyboard); the owner will reassess in testing. Ctrl+MMB pans too.
3. **Selection with a mouse matches desktop CAD:** click replaces, Ctrl+click adds/removes, click on empty space clears. Touch keeps
   toggling.
4. **Layout: up to a full desktop-style experience** - dock a phone and get a full desktop CAD app (D6, scoped on its own).
5. Order as section 4: D1 → D2 → D3 → D4 → D5, D6 scoped separately.
6. **Open (27 Oct 2026):** whether to revisit 3D box select (D7) and, if so, the questions under D7 in section 4.
