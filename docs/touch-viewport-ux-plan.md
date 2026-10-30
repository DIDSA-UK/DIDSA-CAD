# Touch viewport UX: the Start button - plan

**Status:** planned 30 Oct 2026, nothing built. Applies to the **phone layout** of the part screen only
(`LayoutMode.phone`, `PartScreen` in `client/lib/viewport3d/part_screen.dart`). The desktop layout (D6,
`docs/desktop-layout-scope.md`) is unchanged, except that it shares the command list (section 3).

**Owner's goal:** a touch UX that gives the viewport as much of the screen as possible while keeping tools one or two taps away.

## 1. The owner's outline

- The bottom-right "+" (Add) FAB becomes a **Start button**.
- **Tap Start:** opens the Start menu, organised like the desktop ribbon tabs. The **lens switch** (Part / Assembly), **Measure**
  and **Section** move into it.
- **Swipe up from Start:** opens a **quick column** of small FABs above it: **Menu** (the hamburger / `PartToolbar`), **Fit**,
  **Orbit / Select**, and a new **Visibility** button. While the column is open, Start shows an **X** that closes it.
- **Visibility panel:** toggles for reference planes, created planes, sketches, curves, solids and surfaces; a second row of
  standard-view buttons (orthographic view points). It stays open until the user dismisses it.

## 2. Today (what moves)

| Control today | Where | Becomes |
|---|---|---|
| `add-fab` ("+", Add menu: New Sketch / Feature, or the Assembly Add menu) | Scaffold FAB slot, bottom right | **Start** button |
| `hamburger-fab` (opens `PartToolbar`: File, View, Selection Filters) | top-left column | quick column: **Menu** |
| `feature-tree-fab` | top-left column | **stays** top left (section 7, Q1) |
| `assembly-lens-fab` | top-left column | Start menu header (Part / Assembly switch) |
| `undo-component-transform-fab` (Assembly lens, contextual) | top-left column | **stays** top left, contextual as now |
| `selection-mode-fab` | top right, `top: 56` | quick column: **Orbit / Select** (but see 5.4) |
| `measure-fab` | top right, `top: 104` | Start menu, **Evaluate** tab |
| `section-fab` | top right, `top: 152` | Start menu, **Evaluate** tab |
| Reset view button (inside `PartViewport`, top right) | top right | quick column: **Fit** (`showResetViewButton: false` on phone) |
| Hide / Show Reference Planes (`PartToolbar` View menu) | toolbar | Visibility panel (the toolbar entry can stay; both drive `_referencePlanesHidden`) |

Result on an idle part screen: the top right is empty, the top left holds only the tree button (plus Undo when there is one), and
the bottom right holds one FAB. The picker Confirm FABs (`confirm-*-picker-fab`) and every tool panel are untouched.

## 3. One command list for both layouts

`PartScreen._ribbonTabs()` already lists every command as `RibbonTabData` / `RibbonGroup` / `RibbonCommand`
(`viewport3d/desktop_chrome.dart`), with enabled state, `selected` (Measure, Section, render mode) and the lens gating. **The
Start menu renders the same list.** No second copy of any command or handler; a ribbon change shows up in both layouts.

Changes to the list:

- `_ribbonTabs({required bool touch})`. With `touch: true` the **Features** tab carries every feature, grouped as the feature
  picker groups them today (Sketch-based, Reference, Surfacing, From Surfaces, Direct Edit, Modify, Repeat, Boolean), instead of
  the desktop's short list plus "All features". The grouping comes from one table shared with `feature_picker_sheet.dart` so the
  two cannot drift. A `RibbonGroup` gains an optional `title` for the section headings.
- Tabs that do nothing in the current lens are left out on touch (desktop keeps them, disabled): Part lens shows **Features,
  Sketch, Evaluate, View**; Assembly lens shows **Assembly, Evaluate, View**.
- Evaluate already holds Measure, Section, Appearance, Scenes, Properties. View holds Fit, View cube, Normal to, the standard
  views, Perspective, Planes and the render modes; it stays (the Visibility panel is the fast path, View the complete one).

## 4. The Start menu (tap)

```
+---------------------------------------------+
|  [ Part | Assembly ]                    [x] |   lens switch, close
|  Features  Sketch  Evaluate  View           |   tab strip (scrolls if narrow)
|---------------------------------------------|
|  Sketch-based                               |
|  [Extr] [Revo] [Swee] [Loft] [Heli] ...     |   icon + label tiles, 4-5 per row
|  Reference                                  |
|  [Plane]                                    |
|  Surfacing                                  |
|  ...                                        |   scrolls
+---------------------------------------------+
                                        ( X )    Start shows X while the menu is open
```

- A modal bottom sheet (`showModalBottomSheet`, `isScrollControlled`, about 60% of the height, draggable to 90%) - the same
  shape as the Add menu and feature picker it replaces, so back-gesture and barrier-tap dismissal work as they do now.
- **Header:** the Part / Assembly `SegmentedButton` (the desktop's `_buildDesktopLensSwitch` minus the tree toggle; it calls
  `_toggleAssemblyLens`). Switching lens swaps the tab set in place without closing the sheet.
- **Tabs:** a `TabBar` over the groups. The last tab used is remembered per lens for the session. The sheet carries the lens tint
  (`assemblyLensButtonColors`) in Assembly lens, as the Add FAB does now.
- **Tiles:** `RibbonCommand` rendered as a 72 x 72 dp tile (icon / svg over a one-line label), disabled tiles greyed with their
  tooltip on long press, `selected` tiles filled (Measure / Section on, current render mode). Tapping a tile closes the sheet,
  then runs `onPressed` (pop first, so the tool opens on a clear screen; the same order `_onAddPressed` uses today).
- `showAddButtonMenu` / `showAssemblyAddMenu` (`add_button_menu.dart`) are no longer used by the part screen. Delete them if
  nothing else uses them (`ai_modelling_screen.dart` imports from the same area: check before deleting).
- Optional, T4: a **Recent** row at the top of the sheet with the last four commands used (in memory). Cheap, and the biggest
  speed-up for repeated Extrude / Fillet sessions.

## 5. The quick column (swipe up)

```
                      [ Visibility ]  <- 4th
                      [ Orbit/Sel. ]  <- 3rd
                      [ Fit        ]  <- 2nd
                      [ Menu       ]  <- 1st, nearest the thumb
                      (    X     )    Start, showing X
```

### 5.1 Gesture

- Start is one widget (`StartButton`, new file `viewport3d/start_button.dart`) holding the FAB and the column, placed in the
  Scaffold `floatingActionButton` slot so both move together when a SnackBar pushes the FAB up.
- **Tap** opens the Start menu. **Vertical drag upward** past 24 dp, or a fling up, opens the column (a `GestureDetector` with
  `onVerticalDragEnd`/`Update` around the FAB: once the drag passes touch slop it wins the arena and the tap does not fire).
  **Long press** also opens it (discoverability, accessibility, and an easy path for tests). A light haptic tick
  (`HapticFeedback.selectionClick`) when it opens.
- A small chevron (`^`, 12 dp) above the FAB hints that it swipes; it goes after the column has been opened three times
  (counted in `ControlsPreferences`, so it is a once-per-install hint).
- While the column is open Start shows **X**; tapping X closes the column. Swipe down on X also closes it. A tap on X never
  opens the Start menu.

### 5.2 Buttons

`FloatingActionButton.small`, 8 dp gaps, staggered scale + fade in (150 ms), keys `quick-menu-fab`, `quick-fit-fab`,
`quick-selection-mode-fab`, `quick-visibility-fab`.

| Button | Action | Notes |
|---|---|---|
| Menu | `_toolbarOpen = true` (opens `PartToolbar` as the hamburger does) | closes the column; the toolbar's own close icon closes it |
| Fit | `PartViewport.zoomToFit` via `_viewportKey` (what Reset view does) | column stays open |
| Orbit / Select | `_toggleSelectionMode` | same icons and `primaryContainer` fill as `selection-mode-fab`; column stays open |
| Visibility | toggles the Visibility panel (section 6) | filled while the panel is open; a dot badge while anything is hidden |

### 5.3 When it closes by itself

The column is **sticky**: Fit and Orbit / Select leave it open (they are used repeatedly). It closes on X, on Menu, when the Start
menu opens, and when any tool session starts (`_anyToolSessionActive` turning true), so it never sits over a tool panel.

### 5.4 Orbit / Select during tool sessions (must keep)

The add FAB is hidden through every tool session (the long condition at its build site), and so the Start button and its column
will be too. But the owner asked for Orbit / Select to stay reachable while a tool or picker is open (on-device feedback quoted at
`_selectionModeFabVisible`). So: **while Start is hidden and `_selectionModeFabVisible` is true, the stand-alone
`selection-mode-fab` keeps showing, top right, exactly as today.** Outside tool sessions it is not shown (the column has it).
Write this as one getter, e.g. `_standaloneSelectionModeFabVisible => _selectionModeFabVisible && !_startButtonVisible`.

Measure and Section lose their "reachable while another tool is open" FABs. That is acceptable: today they already hide while
another tool panel is open (`_measureFabVisible`, `_sectionFabVisible`), and both panels close with their own **Done**
(`MeasurementPanel.onDone`, `SectionPanel.onClose`).

The mode stays visible once its FAB is gone: Selection mode already draws a tinted border round the viewport.

## 6. The Visibility panel

```
+--------------------------------------------------+
| Show   [RefPl] [Planes] [Sketch] [Curve] [Solid] [Surf]   (x) |
| View   [Front] [Back] [Left] [Right] [Top] [Bottom] [Iso]       |
+--------------------------------------------------+
```

- A card docked bottom left, to the left of the FAB column, `min(width - 88, 420)` dp wide, rows scroll sideways if they do not
  fit. Icon chips (40 dp, filled = shown, outlined = hidden) with a short label under each. Landscape fits both rows unscrolled.
- **Stays open until dismissed:** its own close (x), or the Visibility quick button. Closing the quick column does **not** close it
  (Q3). While a tool panel is open (`_anyToolPanelOpen`) the panel is not drawn and comes back when the tool closes; nothing is
  lost.
- **Row 1 - categories:**

  | Toggle | What it hides | Source |
  |---|---|---|
  | Reference planes | the three default planes | existing `_referencePlanesHidden` (same flag the toolbar entry flips) |
  | Created planes | `create_plane` features' plane geometry | features with `type == 'create_plane'` |
  | Sketches | sketch geometry in 3D | `_visibleSketchGeometries` / `type == 'sketch'` |
  | Curves | Helix / Intersection curve bodies | `BodyMeshDto.isCurve` |
  | Solids | solid bodies | `!isSurface && !isCurve` |
  | Surfaces | surface bodies | `BodyMeshDto.isSurface` |

- **Row 2 - views:** Front, Back, Left, Right, Top, Bottom, Isometric, each `viewport.animateToStandardView(StandardView.x)` (the
  ribbon's `standardView` helper already does this). The owner's outline says this row can be hidden: a small chevron at the
  row's left folds it away, remembered for the session.

### 6.1 How category hiding works

- New state `ViewportCategoryVisibility` (six bools; new file `viewport3d/category_visibility.dart`, pure and unit-tested), held
  by `PartScreen`. In memory for the session, like `_referencePlanesHidden` today (Q5).
- **Client-side only.** It does **not** write into `_hiddenFeatureIds` (that set is per-feature, saved in the file and sent to the
  backend's mesh calls). Category hiding filters what is handed to `PartViewport` - the bodies list, sketch geometries, created
  plane geometry - so turning a category back on restores every per-feature choice untouched, and no mesh is refetched.
- Hidden means **not drawn and not pickable**: filter before the lists reach `PartViewport`, so its hit tests never see them (as
  `referencePlanesHidden` already does for reference planes). Fit frames what is visible.
- **Forced visible during picks**, generalising `_referencePlanesForcedVisible`: while a flow needs the user to tap something of a
  category, that category shows whatever the toggle says - sketches during every sketch / profile picker
  (`_anyFeatureOrSourcePickerSessionActive` and the profile / path pickers), surfaces during the Knit / Thicken / Solid-from-surfaces
  / Offset pickers, solids during body pickers (Extrude target body, Mirror / Pattern bodies, Boolean, Split, Shell), created
  planes during plane picks. One getter per category, next to `_referencePlanesForcedVisible`. Toggle chips show forced state
  (a lock badge) so the user knows why a hidden category is showing.
- **Assembly lens:** check `assembly_instance_render.dart`. If instance meshes carry the surface / curve flags, apply Solids /
  Surfaces / Curves there too; otherwise those chips are disabled in Assembly lens with a tooltip saying so. Planes and sketches
  follow the focused Part as the Part lens does.
- The Visibility quick button shows a dot badge whenever any category is hidden, so hidden geometry is never a surprise after the
  panel is closed.
- Icons: reuse `parttoolbar_show/hide_reference_planes.svg` and the feature-tree section icons where they exist; otherwise
  Material icons for now, listed in the PR as a follow-up for proper SVGs.

## 7. Open questions (recommended defaults; build these unless the owner says otherwise)

1. **Tree button:** stays alone top left (recommended - it is the most-used control and the tree is a full panel), or also into
   the quick column for a completely clear viewport?
2. **Quick column sticky** after Fit / Orbit-Select (recommended), or close after any tap?
3. **Visibility panel independent** of the column (recommended), or closed with it?
4. **Long press** as a second way to open the column (recommended).
5. **Category hides session-only** (recommended), or saved in the `.didsa` client stash with `hidden_feature_ids`?
6. **Sketch screen** (`sketch_screen.dart`, its speed dial): same treatment later? Recommended as a follow-up plan once this one
   has been used on a phone; out of scope here.

## 8. Phases (each a session)

| Phase | Covers |
|---|---|
| **T1** | `_ribbonTabs(touch:)`, shared feature-group table, `RibbonGroup.title`; `StartMenuSheet` (lens header, tabs, tiles); Start FAB tap opens it; remove the lens, Measure and Section FABs and the Add menus from the phone layout. Tests updated (see 9). |
| **T2** | `StartButton` with the column: swipe / long press / X, the four quick buttons, stickiness rules, `showResetViewButton: false` on phone, hamburger FAB removed, stand-alone Orbit / Select during tool sessions (5.4), swipe hint. |
| **T3** | `ViewportCategoryVisibility`, filtering into `PartViewport`, forced-visible getters, the Visibility panel (both rows), badge. Assembly lens check. |
| **T4** | Polish: animation timings, Recent row (optional), landscape and small-phone (360 x 640) layout pass, `docs/roadmap.md` / status entry, on-device checklist (10). |

T1 and T3's pure state class can run in parallel; T2 needs T1; T3's panel needs T2's Visibility button.

## 9. Tests

- Read `docs/flutter-widget-test-lessons.md` first.
- `test/part_screen_test.dart` has about 60 lines that find the FABs being moved (`add-fab`, `measure-fab`, `section-fab`,
  `hamburger-fab`, `assembly-lens-fab`, `selection-mode-fab`, or their tooltips). Add helpers (`openStartMenu`,
  `tapStartCommand(tester, 'Measure')`, `openQuickColumn` via long press, `toggleSelectionMode`) to the test file's helpers and
  move the tests onto them in T1 / T2. Do not delete coverage: each test keeps checking the same behaviour, reached the new way.
  The tests that check the Add FAB hides during tool panels (e.g. "the "Add" FAB is hidden while the Extrude panel is open") now
  check Start.
- New: `test/start_menu_test.dart` (tabs per lens, lens switch in place, tile runs the command, disabled tiles), `test/
  start_button_test.dart` (tap vs drag vs long press, X, stickiness, closes when a tool opens), `test/category_visibility_test.dart`
  (pure state and forced-visible), part-screen tests that hiding Solids removes bodies from the viewport and from picking, and that
  a profile picker forces sketches back on.
- The desktop-layout tests ("desktop layout (D6)") must pass unchanged: the desktop ribbon is still built from `_ribbonTabs()`.
- `flutter analyze` and the whole `flutter test` suite clean before each push.

## 10. On-device checklist (not verifiable in widget tests)

Swipe up from Start on a phone with gesture navigation (no clash with the system home swipe: Start sits above the inset); a slow
swipe vs a tap; one-handed reach of the top quick button; the column and the Visibility panel not covering a tool panel; landscape;
the badge and lock states readable; frame rate while the column animates over a heavy model. Record results in the PR; do not claim
any of it was checked on a device unless it was.

## 11. Risks

- `part_screen.dart` is ~27 000 lines. New widgets go in their own files (`start_button.dart`, `start_menu_sheet.dart`,
  `visibility_panel.dart`, `category_visibility.dart`); `PartScreen` only wires state and callbacks.
- The FAB visibility rules are a long list of hard-won exceptions (see the comments at the add FAB's build site). Start inherits
  the add FAB's condition **as is**; do not rewrite it.
- Gesture conflicts: the drag recognizer sits only on the Start button's own area, never the viewport, so orbit / pan / pinch are
  unaffected.
