# Mouse, keyboard and big-screen use — scope

**Status:** recommendations only, for the owner to approve or change (section 7). Nothing built yet. Written 26 Oct 2026 from a read of
`client/lib` on `main` and the owner's first test on a Samsung phone in DeX (external monitor, mouse, keyboard): "reasonable, but needs
polish and alignment with desktop CAD controls. Middle click drag to orbit; mouse cursors are on top of each other."

**Target:** an Android device driving an external monitor with a mouse and keyboard: Samsung DeX, and the same thing on non-Samsung
devices (Android 16 desktop windowing, Motorola Ready For, a plain USB-C monitor and Bluetooth mouse). The screen may or may not be a
touch screen, so touch must keep working everywhere but must not be needed for anything. The same work helps the Windows build, which
has the same gaps.

## 1. What the app does today

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

One small class, say `viewport3d/navigation_bindings.dart`, that turns `(buttons, modifiers, drag or click)` into an intent: `orbit`,
`pan`, `zoom`, `select`, `contextMenu`. All three canvases call it instead of each testing `kPrimaryMouseButton` itself. Default
("DIDSA"), what the owner asked for and close to SolidWorks and Blender:

| Mouse | Action |
|---|---|
| MMB drag | orbit (2D sketch canvas: pan) |
| Shift+MMB or Ctrl+MMB drag | pan |
| RMB drag (past the tap threshold) | pan (as today) |
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
- **R1d, presets** (Settings, stored with the other client settings): DIDSA (above), SolidWorks (Ctrl+MMB pan), Fusion 360
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
| 1-7 or numpad | front, back, left, right, top, bottom, isometric (`animateToPlane` / `animateToIsometric` exist) |
| 5 or P | perspective / orthographic toggle |
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
- Ctrl+click adds to / removes from the selection, plain click replaces it (desktop CAD's rule). Today every click toggles, which on
  touch is right but with a mouse means clicking empty space or Esc to clear. Apply only to mouse clicks.
- A middle click in a sketch tool ends the current chain (like Enter), as SolidWorks does.
- Number fields: the wheel over a focused field nudges the value (Fusion), Up/Down arrows likewise.
- DeX window resize: check that panels clamp sensibly when the window is narrow or short (the resizable panels store fractions, so
  probably fine).

## 4. Phases

| Phase | Covers | Size | Notes |
|---|---|---|---|
| D1 | R1a, R1c, R2: middle and right drag navigate in every mode; one cursor; scaled wheel zoom | small | Fixes both things from the first test. Widget-testable with `tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton)`. |
| D2 | R1b, R1 binding table, plain-drag box select, MMB double-click fit | small-medium | Orbit about the cursor needs a hit-test on press; there's no extra round trip to the backend. |
| D3 | R3: shortcut table, Esc/Enter/Delete/undo/save/views/fit, sketch tool keys, `?` sheet, tooltip hints | medium | Esc must never fall through to Android Back. |
| D4 | R4: right-click popups via `showActionSheet(position:)` | small-medium | One helper, then each call site. |
| D5 | R1d presets + settings, R6 polish | small | |
| D6 | R5: `InputModality`, desktop layout ≥ 1000 dp | large | Scope separately once D1-D3 have been used in DeX for a while. |

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

## 7. Decisions for the owner

1. **Default mapping:** DIDSA as in R1 (MMB orbit, Shift/Ctrl+MMB or RMB drag pan, RMB click menu), or straight SolidWorks, Fusion or
   Onshape as the default?
2. **Right drag:** pan (as now, recommended), or orbit like Onshape?
3. **Selection with a mouse:** keep "every click toggles" or switch to "click replaces, Ctrl+click adds" for mouse clicks only (R6)?
4. **How far to take the layout (R5/D6):** the docked panels and top toolbar described, something lighter (same layout, compact
   density, popovers instead of sheets), or leave it until D1-D3 have had some use?
5. Order: D1 → D2 → D3 → D4 → D5, D6 last. Change if keyboard shortcuts matter more than orbit about the cursor.
