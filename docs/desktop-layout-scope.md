# Desktop layout (D6) - scope

**Status:** scoped 27 Oct 2026. L1-L6 are built (section 8); what each leaves out is listed there. Nothing has been run on a device. Phase D6 of `docs/desktop-input-scope.md`, which covers mouse and keyboard input
(D1-D5, D7); this covers what the app looks like on a big window. Owner's goal: *"dock a phone and have a full desktop CAD
experience"* (DeX, Android desktop mode, an external monitor; Windows benefits too).

**Owner's decisions (27 Oct 2026):** SOLIDWORKS-style; switches on automatically, with a manual override; every screen in one pass.

## 1. When it applies

- An app-wide `LayoutMode` (`phone` / `desktop`) from an `InputModality` notifier and the window size:
  - **desktop** when the window is at least **1000 dp wide and 600 dp tall** and the last pointer was a **mouse** (or a hardware
    keyboard is in use with no touch since);
  - a **manual override** in the Controls settings (D5): Automatic (default) / Always desktop / Always phone;
  - **hysteresis:** once desktop, stay desktop until the window drops below 900 dp or a touch is used, so resizing a DeX window
    across the line doesn't flip the layout back and forth.
- `InputModality` is a `Listener` in `MaterialApp.builder` recording each `PointerDownEvent` / `PointerHoverEvent` kind, plus
  `HardwareKeyboard`. A touch on a touch monitor switches back to phone mode: bigger targets, the current layout. That's the point
  of keeping both.
- **Nothing changes in phone mode.** Every desktop widget is new or a wrapper. The phone layout and its tests stay as they are.
  Widget tests run both modes for every screen (a fixed 1280 × 800 surface and a mouse pointer for desktop).

## 2. The part screen (most of the work)

SOLIDWORKS' arrangement:

```
+--------------------------------------------------------------------------+
| App bar: logo, file name, File / View menus, Save, Undo, ?, AI          |
+--------------------------------------------------------------------------+
| Ribbon (CommandManager): Features | Sketch | Assembly | Evaluate | View |
|   [big icon + label buttons for the active tab]                         |
+------------------+-------------------------------------------------------+
| Feature tree     |                                        [view cube]   |
|  (or Assembly    |                                                      |
|   tree)          |                3D viewport                           |
|                  |                                                      |
|  - while a tool  |                                                      |
|    is open, its  |                                                      |
|    panel docks   |                                                      |
|    here instead  |                                                      |
|    (Property-    |                                                      |
|    Manager), tree|                                                      |
|    one click away|                                                      |
+------------------+-------------------------------------------------------+
| Status bar: selection summary, units, constraint state, busy/job        |
+--------------------------------------------------------------------------+
```

- **Ribbon:** the corner FABs, speed dials and the Add menu become ribbon tabs of labelled buttons with tooltips and keys
  (`withShortcut`). **Features:** Extrude, Revolve, Sweep, Loft, Fillet, Chamfer, Shell, Pattern, Mirror, Boolean, Split, Thicken,
  the surfaces group, Move/Scale/Delete Body, Delete/Move Face. **Sketch:** New sketch (pick a plane or face), Edit sketch.
  **Assembly:** Insert component, Mate, Move/Rotate, Pattern component, Focus. **Evaluate:** Measure, Section, Appearance, Scenes,
  Part properties. **View:** standard views, view cube, perspective, render mode, planes, selection filter, background. The tab
  follows the lens (Part / Assembly) as the toolbar does now. The ribbon replaces the corner FAB columns, the toolbar overlay
  (`PartToolbar`'s File / View become app-bar menus) and the Orbit / Select toggle (not needed with a mouse - D1).
- **Part tool keys (from D3):** each ribbon button carries a key (E Extrude, V Revolve, S New sketch ...). The key does what the
  button does, landing in the same guided step (pick a sketch / profile).
- **Left pane:** the feature / assembly tree docked (resizable, as today). While a tool is open, its panel (every
  `ResizableToolPanel` tool) docks there instead of rising from the bottom, with Confirm / Cancel at the top, as SOLIDWORKS'
  PropertyManager has them (Enter / Esc already work - D3). The tree stays one click away (a tab at the pane's top). Pickers
  (`picker_ribbon.dart`) show their prompt in the same pane.
- **Viewport:** fills the rest. The view cube (D5) sits in its top-right corner. The selection drawer and component drawer become
  the left pane's selection section or the status bar, not sheets over the viewport.
- **Sheets become dialogs or popovers:** the bottom sheets (feature picker, material picker, colour, opacity, polygon resolution,
  scene controls, select other) open as anchored popovers or centred dialogs. Context menus are popups already (D4).
- **Density:** `VisualDensity.compact` and desktop-sized controls while in desktop mode.

## 3. The sketch screen

The same frame: the ribbon's **Sketch** tab holds the draw tools (from the speed dial), dimension, trim, offset, pattern / mirror,
convert, text, construction, and Exit sketch. The sketch ribbon (`sketch_ribbon.dart`, the selection's contextual actions) docks
in the left pane, as do the bars (offset, pattern, text, convert, dimension, construction method). The canvas or Orbit View fills
the rest; the constraint state and the DOF readout go to the status bar.

## 4. The other screens (same pass, lighter)

| Screen | Desktop treatment |
|---|---|
| Tool chooser | a grid of tiles sized for a big window, with keyboard focus; recent files listed beside it |
| Connection, first install, server management | a centred, max-width (about 720 dp) form instead of full-width |
| Gear, bevel, gear chain design | they already split form / preview at 700 dp: give the form a fixed side width and the preview the rest; app-bar actions instead of FABs |
| AI modelling | chat on the left (fixed width), the preview / plan on the right |
| Mesh viewer | the viewport full-size, controls in an app-bar menu or side pane instead of sheets |
| Materials manager, material form, part properties | list on the left, detail on the right (master-detail) |
| Settings screens (sketcher, mesh viewer, AI provider / prompt, Controls) | centred, max-width |
| Headset pairing | centred dialog-sized card |

## 5. Phases (each a session)

| Phase | Covers |
|---|---|
| L1 | `InputModality`, `LayoutMode` with hysteresis and the override, compact density; a desktop-mode test harness |
| L2 | Part screen frame: app bar menus, ribbon (both lenses), left pane with the tree, status bar; part tool keys |
| L3 | Tool panels and pickers docking in the left pane; drawers into the pane / status bar |
| L4 | Sheets → popovers / dialogs (part and sketch screens) |
| L5 | Sketch screen frame (ribbon tab, left pane, status bar) |
| L6 | The other screens (section 4) |

L1 first; L2-L5 in order; L6 can run beside L3-L5.

## 6. Risks

- `part_screen.dart` is ~26 000 lines and owns every panel's state. The desktop frame should **reuse the same panel widgets**, only
  placed differently (a `PanelHost` that docks them in the left pane on desktop, or at the bottom as now). It should not grow a
  second copy of any tool's logic.
- Tests: many widget tests find widgets by position or by the FABs. Desktop mode must stay opt-in in tests (phone remains the
  default surface) so the existing suite is unaffected.
- Not run on a device: every phase ends with the on-device checklist in `docs/desktop-input-scope.md` section 6.

## 7. Still open (to settle at L2, not blocking L1)

- Ribbon icons: reuse the FAB / speed-dial SVGs (`assets/icons/`) with labels, or new larger icons.
- Whether the status bar shows units and a coordinate readout (needs a cursor-to-model point, which the 3D hover already has).

## 8. What is built (first layout: the part screen frame, L1 + most of L2)

- **L1:** `lib/layout/layout_mode.dart` - `LayoutMode`, `LayoutPreference` (Automatic / Always desktop / Always phone, saved in
  `ControlsPreferences`, chosen in the Controls screen), `resolveLayoutMode` (1000 x 600 to enter, stays desktop down to 900 x 520,
  a touch or pen drops back to phone, a mouse or trackpad brings it back), `LayoutModeController`, `LayoutModeScope` and
  `LayoutModeHost` (in `MaterialApp.builder`: watches the window and the pointers, makes controls compact). With no host (a widget test
  that pumps a screen alone) every screen is the phone layout, so the existing suite is unchanged.
- **Part screen, desktop layout** (`PartScreen._buildDesktopRibbon` and friends, `viewport3d/desktop_chrome.dart`):
  an app bar with File and Options menus (File: the toolbar overlay's file actions; Options: the selection filters, tree pane,
  background / colour / scene, Controls and the shortcut list - every view command is on the ribbon's View tab only), a Save button and the shortcut list; the ribbon tabs (Features, Sketch, Assembly, Evaluate, View) share the app bar row with File and View (the ribbon itself is 70 dp of buttons, 10% shorter than first built), whose buttons
  call the same actions as the FABs and sheets (`_runFeatureAction` is the Feature picker's own switch, now shared); a Part / Assembly
  switch on the ribbon that follows the lens; the tree docked in a resizable, foldable left pane (the same `FeatureTreePanel` /
  `AssemblyTreePanel` widgets with a `docked` flag - no slide, no handle, no Close button); a status bar (selection by kind, unsaved
  Parts, lens, projection, render mode). The corner FABs (menu, tree, lens, Add, select / orbit, Measure, Section) are not built on
  this layout; the picker Confirm FABs stay.
- Tests: `test/layout_mode_test.dart`, `test/part_screen_test.dart` ("desktop layout (D6)"), `test/controls_settings_test.dart`.
- **Not yet done on the part screen (rest of L2, L3, L4):** tool panels still rise from the bottom over the viewport rather than
  docking in the left pane; the selection drawer and component drawer are still bottom sheets; the bottom sheets (feature picker,
  colour, scenes, select other) are still sheets; the status bar has no units or cursor coordinates; ribbon icons reuse the FAB icons
  and Material icons. The Sketch tab holds only New Sketch, Sketch on face and Plane (the in-sketch tools belong to L5).
- **Not verified:** run once in a Linux debug build at 1280 x 720 (a part with two bodies, selecting a body, the View and Assembly tabs,
  the File menu, a ribbon New Sketch); not run on a device, on DeX, or with a touch screen swapping modes.

## 9. The rest of the layouts (built after the owner confirmed the part screen frame)

- **L3, panels and drawers on the part screen:** every tool panel (`ResizableToolPanel`, plus Create Plane, Curve and Fill Surface
  through `BottomToolPanelFrame`) docks at the left, 340 dp wide and as tall as the viewport, in place of the tree while the tool
  is open; the tree comes back when it closes. The pickers (`PickerRibbon`) are a prompt card at the top left of the viewport and
  leave the tree in place, because they pick from it. The selection drawer and the component drawer dock under the tree in the left
  pane (`_buildSelectionDrawer`, `_buildComponentDrawer`; the phone layout still gets the draggable sheets). The pane's width
  survives a tool opening and closing.
- **L4, sheets:** `showAdaptiveSheet` (`layout/adaptive_sheet.dart`) is `showModalBottomSheet` on the phone layout and a centred dialog
  (at most 560 x 85% of the window) on the desktop layout. The feature picker, select other, material picker, colour, opacity,
  polygon resolution, scene controls, plane sheets, references sheet and the Helix / Intersection / Fill Surface panels use it.
  Context menus were already popups (D4).
- **L5, sketch screen:** a tool ribbon under the app bar (the draw tools, Dimension, Trim, Convert, Offset, Pattern, Construct,
  Drag, Inference) replaces the speed dial and the drag / inference / exit FABs; Exit Sketch is in the app bar; a status bar shows
  the tool, the selection count, and the constraint state. The sketch bars are `ResizableToolPanel`s, so they dock at the left too.
  The contextual selection ribbon (`SketchRibbon`) was already a left panel and is unchanged.
- **L6, other screens:** the tool chooser is a 2 x 2 grid; the settings, form and management screens (AI system prompt, AI
  provider, sketcher, mesh viewer settings, material form, part properties, materials manager, headset pairing, server
  management, first install) and the AI modelling screen are centred columns (560-900 dp); the gear, bevel and gear-chain screens
  put the form on the left and the preview on the right.
- **Not done:** the mesh viewer keeps its own controls (no app-bar menu or side pane yet); the materials manager is a centred list,
  not master-detail; the AI screen has no side-by-side chat and plan (its steps are separate screens); the connection screen was
  already a narrow centred form and is unchanged; the sketch screen has no tabs or left pane beyond the docked bars; the part
  screen's status bar still has no units or cursor coordinates. Not run on a device or with a touch screen swapping modes.
- Tests: `test/layout_mode_test.dart` (rules, host, setting, `showAdaptiveSheet`), `test/part_screen_test.dart` ("desktop layout
  (D6)": frame, ribbon, pane, docked tool panel, menus), `test/sketch_screen_desktop_test.dart`. The full suite passed.
