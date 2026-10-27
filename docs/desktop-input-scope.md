# Mouse, keyboard and big-screen use — scope

**Status:** decisions taken by the owner on 26 Oct 2026 (section 7); D1 to D5 built on branch
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
| D3 | Keyboard shortcuts (part screen, sketch screen, mesh viewer), Enter / Esc for every tool panel, shortcut sheet, tooltip hints; mesh viewer fit; the part screen click rule as a tested function | Done (not merged; unit and widget tested, including the part screen and sketch screen; not run on a device) | CAD `claude/flutter-desktop-mode-ui-pxmq0q` (`client/`) |
| D4 | Right-click menus: one helper (popup for a mouse, sheet for touch), every tree row, 3D geometry / plane / component / empty-space menus, sketch entity and canvas menus | Done (not merged; unit and widget tested, the 3D viewport tests skip without a GPU; not run on a device) | CAD `claude/flutter-desktop-mode-ui-pxmq0q` (`client/`) |
| D5 | Navigation presets (SOLIDWORKS / Fusion 360 / Onshape), Controls settings screen, invert wheel, orbit speed, view cube on Space, Ctrl+8 normal to, number-field nudging, Tab order, middle click ends a chain | Done (not merged; unit and widget tested, the 3D viewport tests skip without a GPU; not run on a device) | CAD `claude/flutter-desktop-mode-ui-pxmq0q` (`client/`) |
| D6-D7 | | Not started | |

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

### D3 implementation notes

- **One table:** `client/lib/viewport3d/keyboard_shortcuts.dart` - `CadShortcut` / `kCadShortcuts` (keys, label, group), the
  `CadShortcutScope` each screen wraps itself in, `showCadShortcutSheet` (`?` or F1, lists what the screen binds) and
  `withShortcut` for tooltips ("Undo (Ctrl+Z)", "Select all (Ctrl+A)", "Zoom to fit (F)").
- **How keys arrive:** `CadShortcutScope` listens on `HardwareKeyboard` and acts only while its screen's route is on top (not under
  a dialog, sheet or menu); it takes no focus. A first version used an autofocused `Focus`, which would have stopped every
  `autofocus: true` text field from getting focus (Flutter only autofocuses when nothing has focus) - the test that caught it stays.
  The bindings are built on every key press, so they read current state. A key it handles is reported handled, so Android doesn't
  act on it too; Esc is always taken.
- **Text fields:** while one has focus, letters, Enter, Delete/Backspace, arrows, F, Z, Ctrl+A/Z/Y go to the field; Ctrl+S/O/N and
  Ctrl+1-7 still work; Esc leaves the field (a second Esc then acts).
- **Tool panels' Enter / Esc:** a zero-size `ToolPanelKeys(onConfirm:, onCancel:)` sits beside each panel's Cancel button with the
  same callbacks the buttons use - 42 panels and bars (every `ResizableToolPanel` tool, create plane, curve, fill surface, the
  profile/path picker ribbons, measure, section, appearance, scenes, move/rotate component, and the sketch's offset, pattern,
  text and convert bars). Enter does what clicking Confirm does and nothing while Confirm is greyed out; Esc does what Cancel /
  Close / Done does. The most recently opened panel wins.
- **Part screen:** Esc = the open panel's Cancel, else whatever Back cancels (now `_cancelActiveMode`, shared with the `PopScope`),
  else close the File/View toolbar, else clear the selection - it never leaves the Part (Back still asks to). Enter = the panel's
  Confirm. Delete = the tree multi-select's Delete, else (assembly) the selected mate, else the selected component, each with its
  existing confirm. Ctrl+Z = undo the last assembly move/delete (the only undo the part screen has). Ctrl+S / Ctrl+Shift+S /
  Ctrl+O / Ctrl+N = save, save as, open, new. F = zoom to fit; Ctrl+1-7 = front, back, left, right, top, bottom, isometric
  (`PartViewportState.animateToStandardView` - the app is Y-up with its isometric eye at (+1, +1, +1), as SOLIDWORKS is); Z /
  Shift+Z zoom; arrows rotate 15°, Shift+arrows 90°, Ctrl+arrows pan; P perspective/orthographic.
- **Zoom to fit keeps the view direction** (F, and the middle double-click from D2 - which used Reset view and so also turned the
  view back to isometric): `_doRecentre(keepOrientation: true)`. The Reset view button still resets everything.
- **Sketch screen:** L, C, A, R = line, circle, arc, rectangle; D = dimension; T = trim; X = construction on/off for the selection;
  Esc = the open bar's Cancel, else the dimension being typed, else back to Select, else clear the selection (never exits the
  sketch); Enter = the bar's confirm, else finish the line chain; Delete = the ribbon's Delete (same rules: pattern/mirror
  instances delete themselves, a pinned point can't); Ctrl+Z, Ctrl+A; F = fit (the 2D canvas, or Orbit View's 3D view, where the
  view keys work too).
- **Mesh viewer:** F and a middle double-click zoom to fit (new: it had no fit action).
- **Part screen click rule:** `selectionAfterClick` in `mouse_navigation.dart`, used by `_toggleSelectedEntity` and unit-tested.
- Tests: `test/keyboard_shortcuts_test.dart`, `test/sketch_screen_keyboard_test.dart`, `test/part_screen_test.dart` ("desktop
  input D3": Ctrl+Z undoes a component move, Esc deselects), `test/mouse_navigation_test.dart` (`selectionAfterClick`).
- **Left out of D3, and where they go:**
  - **Redo** (Ctrl+Y is in the table but bound nowhere): no screen has a redo stack (the sketch's is a `TODO`). Building one is
    undo/redo work, not input work - a roadmap item of its own.
  - **Feature undo** in the part screen (Ctrl+Z only undoes assembly moves and deletes): same - there is no feature undo to bind.
  - **Ctrl+8 normal to** and the **Space view picker**: need a face-normal lookup and a picker UI - moved to D5.
  - **Ctrl+B rebuild**: the backend recomputes on every change; there is no manual rebuild to bind. Dropped unless one appears.
  - **Part tool keys (S, E, V ...)**: the part tools open through guided multi-step flows (pick a sketch, a profile ...), so a key
    needs a decision per tool on where it lands - moved to D6, with the desktop toolbar.
  - **Tab order** through panel fields: not checked - D5 polish.

### D4 implementation notes

- **The helper** (`viewport3d/action_sheet.dart`): `showContextMenu<T>(context, entries, {Offset? at})`. With `at` (a mouse
  right click's global position) it shows a `showMenu` popup there - icon (or a `leading` widget), label, the key hint at the right
  edge (`ActionSheetEntry.shortcut`), a divider above a row that sets `dividerBefore`, a disabled row's reason as its tooltip;
  without `at` it is `showActionSheet`, the bottom sheet, unchanged. `ActionSheetEntry` gained `leading`, `iconColor`,
  `labelColor`, `shortcut` and `dividerBefore` (the sheet ignores the last two) and `icon` is now optional when `leading` is given.
  `MouseContextMenuRegion` wraps a row / canvas and reports a secondary tap by a **mouse** (position global); touch long-presses
  never reach it. Tests: `test/context_menu_test.dart`.
- **Every existing menu takes `at`:** `showComponentContextMenu`, `showMateContextMenu`, `showPlaneContextSheet`,
  `showCreatePlaneContextSheet`, `showAddButtonMenu`, `showAssemblyAddMenu` (the two Add menus have no right-click caller - they
  hang off buttons - but take it for the same reason). `showFeatureContextMenu` and `showBodyContextMenu` were moved onto the helper
  (one entry list, two presentations); the touch sheets look the same (same `ListTile` rows; the disabled reason is still the
  subtitle, the red Delete icon is `iconColor`). The two plane sheets keep their own touch layout (drag handle, title row) and
  only add the popup branch.
- **Rule (SOLIDWORKS):** a right click without a drag on something not selected selects it (a plain click) and opens its menu; on
  something already in the selection, the selection stays. `PartScreen._selectForContextMenu` for part geometry and tree rows (it
  does nothing while a tool is open and gathering picks - the menu still opens, so a right click never adds a pick);
  `SketchController.selectUnderCursorForContextMenu` for the sketch.
- **Tree rows:** `FeatureTreePanel` (`onFeatureContextMenu`, `onBodyContextMenu`, `onSurfaceContextMenu`, `onCurveContextMenu`) and
  `AssemblyTreePanel` (`onOccurrenceContextMenu`, `onMateContextMenu`, `onPatternContextMenu`) wrap each row in a
  `MouseContextMenuRegion`. The part screen answers with the row's menu directly (`_onFeatureLongPress(feature, at:)` etc.; on touch
  those are reached through "More"). Not offered during a multi-select or a picker. Two rows had no menu to open: a **Curve**
  row (touch toggles Hide / Show) gets a one-entry Hide / Show menu, and a **Pattern** row (touch goes straight to the delete
  confirmation) gets Edit / Delete. Tests: `test/tree_context_menu_test.dart`, and `test/part_screen_test.dart` ("desktop input D4").
- **3D view** (`PartViewport.onContextMenuRequested(HoverHit? hit, Offset globalPosition)`): fired from `_endMouseNavigation` when a
  right press released within `kTouchSlop` of travel; the hit comes from `_hitAt`, which runs the hover hit-test (same candidates,
  filter and priorities) at the click without disturbing the hover state. `PartScreen._onViewportContextMenu` picks the menu:
  - a **component** - `showComponentContextMenu` as a popup (it selects the component first, as its long-press does);
  - a **reference plane / created plane** - the plane sheets as popups (not during plane picking or the sketch orientation step);
  - a **face, edge, vertex or body** - the new geometry menu (`viewport3d/viewport_context_menus.dart`): Select Other (enabled when
    more than one candidate lies under the click), Zoom to Selection, Normal To (a flat face only), Measure (face / edge / vertex;
    opens Measure with it picked), Appearance... (face / body; opens the Appearance panel for it), then the owning body's Hide / Show
    Body and Assign Material (left out for a face on a placed component, which has no body of this part);
  - **empty space** (and a sketch entity seen from the part) - the view menu: Zoom to Fit (F), Standard Views, Perspective /
    Orthographic (P), Hide / Show Reference Planes, Reset View. A popup has no flyouts, so **Standard Views** opens a second popup
    at the same place with the seven views and their Ctrl+number hints.
  New viewport methods: `resetView`, `zoomToEntities` (frames the bounds of the entities' geometry about their centre, view
  direction kept; a lone vertex frames a patch 2 % of the model), `planarFaceNormal` (uses the mesh's `faceIsPlanar` flag, else
  the triangle normals; pointing to the camera's side), `animateToFaceNormal` (D5's Ctrl+8 uses these two), and
  `selectOtherAtGlobal` / `hasSelectOtherCandidatesAt` (`_fireSelectOther`'s candidate list pulled out as
  `_selectOtherCandidatesAt`). Test: `test/part_viewport_mouse_navigation_test.dart` (GPU-gated: skips here).
- **Sketch** (`sketch/sketch_context_menu.dart`; each entry carries the callback it runs): `SketchCanvas.onContextMenuRequested(hit,
  position)` fires on a right release under the tap slop; in select mode the entity under the cursor is selected by the rule above.
  An entity gets the ribbon's main actions: Edit / Delete Pattern or Mirror, Make Construction / Make Solid (X), Fix / Unfix,
  every constraint the ribbon offers for the selection (the not-yet-wired ones disabled), and Delete (with the point's blocked
  reason). Empty canvas (and any non-select mode) gets Line, Circle, Arc, Rectangle, Dimension, Trim (with their keys), Select All
  and Zoom to Fit. Orbit View (the 3D view inside the sketch screen) routes through `SketchScreen._onOrbitContextMenu` to the same
  two menus. The ribbon's constraint icon switch is now the top-level `sketchConstraintSvgAsset`. Tests:
  `test/sketch_context_menu_test.dart`, `test/sketch_controller_test.dart` ("desktop input D4").
- **Left out / not matching the scope exactly:** a constraint *label* or dimension under the right click is not hit-tested (the
  click falls through to the entity or canvas menu); Select Other from the menu opens the same sheet as the click-and-hold, with
  no first click to undo; Normal To keeps the camera's up as near as it can (D5's Ctrl+8 shares it);
  "Zoom to selection" for sketch entities in the 3D view frames nothing (they have no mesh) and returns without moving the camera.

### D5 implementation notes

- **Presets** (`viewport3d/controls_preferences.dart`, `mouse_navigation.dart`): `NavigationPreset` (`solidworks`, `fusion360`,
  `onshape`) and `mouseNavActionFor(..., preset:)` hold the three tables of section 4 (SOLIDWORKS is the default argument, so
  nothing that did not pass one changed). `mouseNavActionForEvent` reads the stored preset, so the 3D viewport, the 2D sketch canvas
  (where orbit pans) and the mesh viewer all follow it. A right click without a drag opens the D4 menu in every preset - Onshape
  needed no change there because a click is told from a drag by travel. Fusion 360 and Onshape have no zoom drag.
- **Controls settings** (`ControlsPreferences`, `shared_preferences` like `ScenePreferences`; `ControlsSettingsScreen`): the preset
  (radio list with each preset's bindings), "Invert wheel zoom" (`wheelZoomFactor(..., invert:)` at the three wheel call sites), and
  "Orbit speed" 0.25x to 3x (11 steps; a mouse orbit's delta is scaled in the 3D viewport's middle / right drag and the mesh
  viewer's mouse orbit), the shortcut list, and Reset to defaults. Every change saves at once. Opened from the part screen's View
  menu ("Controls"), the sketch screen's menu and an icon on the tool chooser's app bar; each screen loads the stored values when
  it opens. **Differs from the scope:** the orbit speed does *not* scale the keyboard arrows - they turn by fixed degrees (15, and
  Shift 90), and scaling would break the 90 degree snap; touch orbit is also untouched.
- **View cube** (`viewport3d/view_cube.dart`, Space in the part screen and in the sketch's Orbit View): a popup at the last place
  the pointer was over the viewport (else its middle), kept on screen. The cube is drawn orthographically with the camera's axes
  (`ViewCubeProjection`: pure, unit tested); each visible face is a 3 x 3 grid - the middle cell is the face, an edge cell the
  edge, a corner cell the corner - so the 26 targets are all reachable and the hovered cell is highlighted with its name
  (Front, Top Right, Front Top Right ...). A click turns the view with `animateToViewCubeTarget` (the up vector is world Y; Top and
  Bottom keep SOLIDWORKS' ups, as `StandardView` does). Esc or a click outside closes it. The corner-of-the-viewport cube the scope
  mentions for D6 can reuse the same painter.
- **Normal To / Ctrl+8:** `PartScreen._normalToAction` for exactly one selected reference plane (`animateToBasis`), created plane
  (its basis) or flat face (`animateToFaceNormal`, from D4: planar by the mesh's `faceIsPlanar`, the view turned to look at it with
  the up kept as near to the current one as the new direction allows). Anything else leaves the key alone. The same action is the
  view cube's Normal To button, enabled under the same rule.
- **Number-field nudging** (`viewport3d/number_field_nudge.dart`, installed by `CadShortcutScope`): while a single-line text field
  holding a number has focus, Up / Down step it by 1 (Shift 10, Ctrl 0.1) and so does the wheel while the pointer is over it (one
  step per 50 px of scroll). It goes through the field's `userUpdateTextEditingValue`, so each panel's `onChanged` hears it as typing
  and no panel was touched. Up / Down are taken by a `FocusManager` early key handler: a `HardwareKeyboard` handler cannot stop the
  field's own Up / Down, which moved the caret and undid the step (found by the test). Min / max limits are the panels' own
  validation, as for typing. Not a number (or a multi-line field): left to the field.
- **Tab order:** `ResizableToolPanel` (every `ResizableToolPanel` tool) is now a `FocusTraversalGroup`, so Tab / Shift+Tab walk its
  fields and buttons in reading order inside the panel instead of wandering out to the viewport's buttons; the test fails without it.
  **Not done:** the hand-built bars (the sketch's offset / pattern / text bars, the picker ribbons, create plane and the like) were
  not audited and are not wrapped; only the `ResizableToolPanel` family is.
- **Middle click ends a chain:** a middle click that does not drag, in a draw tool, calls `finishChain` (what Enter does) - in the 2D
  canvas and in Orbit View (`PartViewport.onMouseMiddleClick`). A middle double-click still fits.
- **Double-click on a Feature row:** a click already opens the Feature for editing, so a double-click is just two clicks - and the
  second used to re-enter `_onFeatureTap` while the first was still opening the Feature. `_onFeatureTap` now ignores a click while
  one is opening it (tested: it fails without the guard).
- **Checked, no change:** tree rows are `ListTile`s with an `onTap`, which already give a hover highlight.
- **Not done:** the DeX window-resize check is a device check (below); the new screen and popup are tested at 320 x 480.
- Tests: `test/mouse_navigation_test.dart` (presets, invert), `test/controls_settings_test.dart`, `test/view_cube_test.dart`,
  `test/number_field_nudge_test.dart`, `test/tool_panel_tab_order_test.dart`, `test/sketch_canvas_mouse_navigation_test.dart`
  (middle click), `test/part_screen_test.dart` ("desktop input D5": Space, Ctrl+8, double-click) and, GPU-gated,
  `test/part_viewport_mouse_navigation_test.dart` (Onshape right-drag orbit, view cube pick).

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
| D3 | R3: shortcut table, Esc/Enter/Delete/undo/save/views/fit, sketch tool keys, `?` sheet, tooltip hints. **Also from D2:** a fit action for the mesh viewer (F needs one), wired to its middle double-click too; the part screen's click rule moved into a pure, unit-tested function (Esc and Delete act on the same selection) | medium | Built (Progress above; what it left out is listed there). |
| D4 | R4: right-click menus - the helper, every tree/viewport/sketch menu, new 3D geometry and view menus | medium | Built (Progress above; what it left out is listed there). |
| D5 | R1d presets + Controls settings, R6 polish. **Also from D3:** Ctrl+8 normal to, the Space view cube, Tab order through panel fields | medium | Built (Progress above; what it left out is listed there). |
| D6 | R5: `InputModality`, the full desktop layout ≥ 1000 dp. **Also from D3:** keys for the part tools (S, E, V ...) with the desktop toolbar | large | Scoped in `docs/desktop-layout-scope.md`. |
| D7 | 3D box select (part and assembly): visible geometry only, edges by default, mouse drag and touch tap-hold-drag | medium | A revisit of a feature the owner parked in June; questions answered 27 Oct (below). |

### D4: right-click menus (scoped 27 Oct 2026)

**Rule (SOLIDWORKS):** a right click without a drag on something that isn't selected selects it (as a plain click would) and opens
its menu at the cursor; on something already in the selection it keeps the selection. A right drag still pans (D1). Touch keeps
its long-presses and bottom sheets unchanged.

**One helper:** `showContextMenu<T>(context, entries, {Offset? at})` beside `showActionSheet` in `action_sheet.dart`. With `at`
(a mouse) it shows a desktop popup (`showMenu`, icon + label, a disabled entry's reason as its tooltip) at that point; without, the
bottom sheet as now. Every existing menu function takes the same optional `at` and passes it on: `showComponentContextMenu`,
`showMateContextMenu`, `showFeatureContextMenu`, `showBodyContextMenu` (these two build their own sheets today - move them onto
the helper), `showPlaneContextSheet`, `showCreatePlaneContextSheet`, `showAddButtonMenu` / `showAssemblyAddMenu`.

**Where right click opens what:**

| Where | Menu |
|---|---|
| Feature tree rows (feature, body, surface, curve - the 5 `onLongPress` rows in `feature_tree_panel.dart`) | the row's existing long-press menu, via `onSecondaryTapUp` |
| Assembly tree rows (occurrence, mate, pattern - 3 in `assembly_tree_panel.dart`) | the row's existing menu |
| 3D view, a component (assembly) | the component menu |
| 3D view, a reference plane / created plane | the plane sheets, as a popup |
| 3D view, a face, edge or vertex of a part (**owner: SOLIDWORKS-style**) | new geometry menu: Select Other (the existing Select Other list, for the point clicked), Zoom to selection, Normal to (a planar face; shares Ctrl+8, D5), Measure (opens Measure with it picked), Appearance (opens the Appearance tool on that face/body), Hide / Show body, then the owning body's own menu items (`showBodyContextMenu`'s) |
| 3D view, empty space | view menu: Zoom to fit, Standard views (submenu, with their Ctrl+numbers), Perspective / Orthographic, Show / Hide planes, Reset view |
| Sketch (2D canvas and Orbit View), an entity | its main ribbon actions: Delete, Construction on/off, Fix / Unfix, the constraint chips the ribbon offers for the selection |
| Sketch, empty canvas | the tools (Line, Circle, Arc, Rectangle, Dimension, Trim, with their keys), Select all, Zoom to fit |

**Wiring:** `PartViewport` gets `onContextMenuRequested(HoverHit? hit, Offset globalPosition)`, fired from D1's middle/right
release (`_endMouseNavigation`) when the right button travelled less than the tap threshold - the hit-test is the one hover
already runs, at that point. The part screen picks the menu from the hit. In the 2D canvas the same on a right release without a
drag. New "Zoom to selection" = frame the entity's bounds (`_doRecentre`'s framing on a given box, orientation kept).

**Tests:** the helper (popup with `at`, sheet without); a right click on a tree row opens the row's menu (widget test, no GPU);
the sketch canvas right click (widget test); the viewport path is GPU-gated like the other viewport pointer tests. **Size:**
medium (about a dozen call sites plus two new menus).

### D5: presets, Controls settings, view cube, polish (scoped 27 Oct 2026)

- **Presets (owner: SOLIDWORKS, Fusion 360, Onshape)** - `mouseNavActionFor` takes a `NavigationPreset`:

  | | Orbit | Pan | Zoom drag | Right drag |
  |---|---|---|---|---|
  | SOLIDWORKS (default) | MMB | Ctrl+MMB, RMB | Shift+MMB | pan |
  | Fusion 360 | Shift+MMB | MMB, RMB | - | pan |
  | Onshape | RMB | MMB, Ctrl+RMB | - | orbit |

  Right click without a drag opens the menu (D4) in all three; wheel zoom is the same. Plus **invert wheel zoom** and an **orbit
  speed** slider (scales `OrbitCamera.orbitSensitivity` for mouse and keys).
- **Controls settings screen (owner: a new screen)** - `ControlsPreferences` (shared_preferences, like `ScenePreferences`), a
  `ControlsSettingsScreen` with the preset, invert wheel, orbit speed and a button for the shortcut sheet. Opened from the part
  screen's View menu, the sketch's menu and the tool chooser.
- **View cube on Space (owner: a view cube, not a list)** - a popup at the cursor showing a small cube drawn with the current camera
  orientation (`CustomPainter`, faces labelled Front/Top/Right..., SOLIDWORKS' names); clicking a face, edge or corner animates to
  that view (26 targets: 6 faces, 12 edges, 8 corners - `OrbitCamera.orientationLookingFrom`), plus a Normal to button when a planar
  face or plane is selected. Esc or a click outside closes it. The same cube can later sit in the viewport's corner (D6).
- **Ctrl+8 normal to** - a selected reference/created plane: `animateToBasis` (exists); a selected face: its normal from
  `faceTrianglesForId` (planar if every triangle's normal agrees within a tolerance; otherwise the key does nothing), the view
  turned to look at it, up kept as close to the current up as possible.
- **Polish (R6):** Tab order through every tool panel's fields (audit, `FocusTraversalGroup` where needed); hover highlight on tree
  rows; double-click a feature row to edit it; a middle click in a sketch tool ends the chain (as Enter); the wheel and Up/Down over
  a focused number field nudge the value; DeX window resize checked at narrow and short sizes.
- **Size:** medium (the view cube is most of it).

### D6: the desktop layout

Scoped in its own document, **`docs/desktop-layout-scope.md`** (owner: SOLIDWORKS-style; automatic with a manual override;
every screen in one pass). It also takes D3's part tool keys.

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
inside, a crossing box what touches; respect the selection filter; Ctrl adds.

**Owner's answers (27 Oct 2026):**

1. **Hidden geometry is not picked** - only what the camera can see. So each candidate needs a visibility test (for an edge, sample
   points along it and ray-test them against the shaded faces, the same face-occlusion rule `hitTestBodies` already applies to
   clicks via `facesOccludeOtherHits`; wireframe/hidden-bodies modes have nothing to occlude).
2. **Default target: edges.** A box picks edges unless the selection filter says otherwise (faces, vertices, bodies, components
   when those filters are on).
3. **Touch: tap and hold, then drag**, as the sketcher does (the 500 ms long-press on empty space; the old attempt's
   double-tap-then-drag is not brought back).

4. **In an assembly the box picks whole components** (SOLIDWORKS); inside a part, or a focused component, it picks edges by default.

Approved to build after D3 (the owner said "start D3" with these answers).

**Plan (scoped 27 Oct 2026):**

- A new pure module, `viewport3d/box_select.dart`: `boxSelect(camera, viewportSize, focusTransform, candidates, rect, {crossing,
  filter, occluders})` returning the picked `SelectionEntityRef`s. Pure, so it is unit-tested headless against known perspective and
  orthographic cameras - the piece every June attempt lacked.
- **Projection:** `worldToScreenFocused` (`screen_projection.dart`, the projection every overlay already uses on the device). The
  mesh data is all there: `edgeSegmentsForId`, `faceTrianglesForId`, `topologyVerticesFromMesh` (`selection_hit_test.dart`), and
  the component instances' meshes and transforms.
- **Visible only:** sample each edge (and each face's triangle centroids, each vertex) and ray-test the sample against the shaded
  faces (`hitTestFaces`'s triangle test): a sample is visible when no face is nearer than it by more than
  `kFaceOcclusionEpsilon`. Wireframe mode and hidden bodies have nothing to occlude.
- **Window** (left to right): an edge is picked when all its samples are inside the box and at least one is visible; a face when all
  its boundary edges' samples are inside and one of its centroids is visible; a vertex when inside and visible; a component when its
  projected bounds are inside and some of it is visible. **Crossing** (right to left): any visible sample inside, or a visible
  segment crossing the box (the 2D `polylineTouchesRect`). Ctrl adds.
- **What's picked:** the selection filter decides, edges by default in a part; whole top-level components in an assembly; inside a
  focused component, its edges.
- **Gestures:** the mouse box from D2 now also starts outside a sketch; touch gets tap-hold-drag on empty space (the existing 500 ms
  marquee long-press, which today only selects in a sketch). Computed once, on release.
- **Cost:** sampling is per edge, so a large assembly could be slow on a phone - measure on the device; cap samples per edge and skip
  the occlusion test for components whose bounds are outside the box.
- **Tests:** `test/box_select_test.dart` - a box seen from the front and from the side, perspective and orthographic: window vs
  crossing, a hidden back edge not picked, a box behind another not picked, a focus transform, components vs edges. **Size:** medium. Kept out of D5 because it is a feature, not polish, and out of D6
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

From D3:

- **what Esc does in DeX**: whether it reaches the app as Esc at all, or DeX turns it into Back first (then the part screen's Back
  handler runs: it cancels a picker, or asks to exit the Part). The app handles Esc itself; it can't stop a system-level remap;
- that Ctrl+1-7 show the views SOLIDWORKS users expect (Front looking along -Z with Y up, Top looking down with -Z up), and that
  F frames without turning;
- Enter / Esc on a few tool panels (Extrude, Fillet, Mate, Measure) and the sketch's Pattern / Offset bars;
- typing in a panel's number field: letters, Enter and Delete edit the field; Esc leaves it;
- Ctrl+S / Ctrl+O / Ctrl+N against what the File menu does.

From D4:

- that a right click reaches the app as a secondary tap in DeX and does not also pan or turn into Back (a right *drag* still pans);
- the popup's position and size on the real screen: it opens at the pointer, moves to fit near an edge, and a tall menu (the
  Feature menu for a sketch has about a dozen rows) scrolls rather than clipping;
- right click on a tree row in the Build Tree and Assembly Tree opens that row's menu, and does not start a multi-select;
- right click on a face, an edge, a vertex, a body, a component, a plane and on empty space each give the menu in section 4's
  table; the face is selected first, unless it was already part of the selection;
- Zoom to Selection frames the selection; Normal To turns a flat face to face you (and is greyed out on a curved one); Measure and
  Appearance... open their tools with the pick made; Select Other lists the candidates under the click;
- Standard Views opens its second popup in the same place, and each view matches Ctrl+number;
- in the 2D sketch, right click on a selected entity vs an unselected one (the selection should only change for the latter), on
  empty canvas, and in Orbit View;
- a touch long-press and a touch tap still open the bottom sheets exactly as before, including on a touch monitor.

From D5:

- each preset's bindings in DeX (middle / right / Ctrl / Shift drags, and a right click still opens a menu); changing the preset
  takes effect at once in the 3D view, the 2D sketch and the mesh viewer, and survives restarting the app;
- invert wheel zoom, and the orbit speed slider (does 1x feel like before, and 3x / 0.25x usable?);
- Space opens the cube under the pointer; clicking a face, an edge and a corner gives the view you expect (Front looks along -Z
  with Y up, Top looks down); hover names the cell; Esc or a click outside closes it; Normal To is greyed unless a flat face or
  plane is selected; the same from the sketch's Orbit View;
- Ctrl+8 on a flat face, a reference plane and a created plane; on a curved face it does nothing;
- Up / Down and the wheel on a focused number field in a few panels (Extrude depth, Fillet radius, Mate value, a sketch
  dimension): the value and the live preview follow; Shift and Ctrl change the step. Does Android treat Up / Down in a text
  field differently from the Flutter test (it may also move the caret)?
- Tab / Shift+Tab inside Extrude, Fillet and Mate: the order matches the screen and does not leave the panel;
- a middle click ends a line chain in the 2D sketch and in Orbit View;
- double-clicking a Feature row opens its panel or sketch once;
- the Controls screen, the view cube and the context menus at a narrow DeX window width and a short one.

## 7. Decisions (owner, 26 Oct 2026)

1. **Template: SOLIDWORKS** (the larger user base). MMB orbit, Ctrl+MMB pan, Shift+MMB zoom, its view keys (R3).
2. **Right drag stays pan** for now (it gives a pan with no keyboard); the owner will reassess in testing. Ctrl+MMB pans too.
3. **Selection with a mouse matches desktop CAD:** click replaces, Ctrl+click adds/removes, click on empty space clears. Touch keeps
   toggling.
4. **Layout: up to a full desktop-style experience** - dock a phone and get a full desktop CAD app (D6, scoped on its own).
5. Order as section 4: D1 → D2 → D3 → D4 → D5, D6 scoped separately.
6. **3D box select (D7), 27 Oct 2026:** revisit it after D3; visible geometry only, edges by default, touch is tap-hold-drag;
   whole components in an assembly.
7. **D4-D6, 27 Oct 2026:** right click on part geometry gets a SOLIDWORKS-style menu; presets SOLIDWORKS + Fusion 360 + Onshape in
   a new Controls settings screen; Space opens a view cube; the desktop layout is SOLIDWORKS-style (ribbon on top, tree left, tool
   panels docking in place of the tree), switches on automatically with a manual override, and covers every screen in one pass.
8. **Order:** D4 → D5 → D7 → D6 (D6 is the largest; D7 can go before or after it). Each phase in its own session.
