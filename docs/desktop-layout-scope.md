# Desktop layout (D6) - scope

**Status:** scoped 27 Oct 2026, not started. Phase D6 of `docs/desktop-input-scope.md`, which covers mouse and keyboard input
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
