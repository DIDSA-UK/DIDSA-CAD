# Touch viewport UX: the Start button - plan

**Status:** planned 30 Oct 2026, owner's answers to the open questions taken the same day (section 7). Nothing built. The UX
applies to the **phone layout** of the part screen only (`LayoutMode.phone`, `PartScreen` in
`client/lib/viewport3d/part_screen.dart`). The desktop layout (D6, `docs/desktop-layout-scope.md`) keeps its look; it shares the
command list (section 3) and the backend hide / show state (section 6.1).

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
| `feature-tree-fab` | top-left column | **stays** top left (owner, Q1) |
| `assembly-lens-fab` | top-left column | Start menu header (Part / Assembly switch) |
| `undo-component-transform-fab` (Assembly lens, contextual) | top-left column | **stays** top left, contextual as now |
| `selection-mode-fab` | top right, `top: 56` | quick column: **Orbit / Select** (but see 5.4) |
| `measure-fab` | top right, `top: 104` | Start menu, **Evaluate** tab |
| `section-fab` | top right, `top: 152` | Start menu, **Evaluate** tab |
| Reset view button (inside `PartViewport`, top right) | top right | quick column: **Fit** (`showResetViewButton: false` on phone) |
| Hide / Show Reference Planes (`PartToolbar` View menu) | toolbar | Visibility panel (the toolbar entry can stay; both drive the same, now saved, flag) |

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
  **Long press** also opens it (owner, Q4; discoverability, accessibility, and an easy path for tests). A light haptic tick
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
| Fit | `PartViewport.zoomToFit` via `_viewportKey` (what Reset view does) | closes the column |
| Orbit / Select | `_toggleSelectionMode` | same icons as `selection-mode-fab`; closes the column |
| Visibility | opens the Visibility panel (section 6) | closes the column; a dot badge while anything is hidden |

### 5.3 When it closes by itself

**Every quick button closes the column** once it has acted (owner, Q2 and Q3). It also closes on X, when the Start menu opens,
and when any tool session starts (`_anyToolSessionActive` turning true), so it never sits over a tool panel. Because Orbit /
Select is now behind a swipe, the current mode must stay readable: the Selection-mode viewport border already does this; also
give the Start button a small mode glyph in its corner while Selection mode is on.

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
- **Stays open until dismissed** with its own close (x). Opening it closes the quick column (owner, Q3), so the panel and the
  column are never on screen together; swiping up again while the panel is open opens the column and leaves the panel open.
  While a tool panel is open (`_anyToolPanelOpen`) the panel is not drawn and comes back when the tool closes; nothing is lost.
- **Row 1 - categories.** The backend already tags every feature with `produces` (`Produces` in
  `backend/app/document/models.py`: `body`, `plane`, `surface`, `sketch`, `curve`, `none`), which is exactly this list:

  | Chip | What it hides | Resolved by |
  |---|---|---|
  | Reference planes | the three default planes (not features) | the Part's `reference_planes_hidden` flag (new, saved) |
  | Created planes | every feature with `produces == plane` | backend |
  | Sketches | `produces == sketch` | backend |
  | Curves | `produces == curve` | backend |
  | Solids | `produces == body` | backend |
  | Surfaces | `produces == surface` | backend |

  A chip has three states, derived from the hidden set: **all shown** (filled), **all hidden** (outlined), **some hidden**
  (half-filled, e.g. one sketch hidden from the tree). Tapping a chip that is all shown hides the whole category; tapping one that
  is all or partly hidden shows the whole category.
- **Row 2 - views:** Front, Back, Left, Right, Top, Bottom, Isometric, each `viewport.animateToStandardView(StandardView.x)` (the
  ribbon's `standardView` helper already does this). The owner's outline says this row can be hidden: a small chevron at the
  row's left folds it away, remembered for the session.

### 6.1 Hide / show becomes backend state (owner's decision)

A category toggle is a **batch hide / show of real features**, stored by the backend and saved in the file (owner, Q5). This moves
**all** hide / show there, not just the new toggles: the tree's eye, the context menu's Hide / Show and the multi-select Hide
all go through the same call, so the tree, the chips and every client agree.

**Today:** hide / show is client-only. `PartScreen._hiddenFeatureIdsByPart` is sent as the `hidden_feature_ids` query parameter
on each `GET /parts/{id}/mesh`, and saved as a top-level `hidden_feature_ids` key the client adds to the native file
(`_rootClientExtras`, read back by `_parseClientExtras` around `part_screen.dart:10765`). The backend keeps nothing
(`router.py` ~8636 says so). The VR client reads that same top-level key (`DIDSA-VR/scripts/main.gd`, `hidden_feature_ids()`).

**Backend (phase T0):**

- `Part` gains `hidden_feature_ids: set[str]` and `reference_planes_hidden: bool` (on the Part, not on each `Feature` subclass:
  one field, no change to the ~40 feature dataclasses). Deleting a feature drops its id from the set.
- `PATCH /document/parts/{part_id}/visibility`, body
  `{"hidden": bool, "feature_ids": [..], "categories": ["sketch", ...], "reference_planes": bool}` (each list optional, at least
  one target). Categories are resolved on the server from `produces` at call time. Returns the Part's whole visibility state
  `{"hidden_feature_ids": [...], "reference_planes_hidden": bool}` so the client replaces its copy, never patches it. Unknown
  feature ids are a 422, not ignored.
- `PartResponse` (and the native export) carry both fields. `GET /parts/{id}/mesh` and the assembly-mesh routes apply the Part's
  stored set (the `hidden_feature_ids` query parameter stays accepted, unioned, for older clients). Hidden bodies are still
  returned with `hidden: true`, as now, so the client can show them during picks (below).
- **Native format:** `_part_to_dict` / `_part_from_dict` save and load both fields per Part. For the VR client and older app
  builds, a save also keeps writing the legacy top-level `hidden_feature_ids` (the root Part's set); a load of a file that has
  only the legacy key moves it into the root Part. Note the new route and fields in `DIDSA-VR/docs/backend-api-notes.md` in
  the same PR's description as a follow-up for the VR repo (no VR change is needed for it to keep working).
- pytest: the route (ids, categories, reference planes, 422s, deletion pruning), mesh honouring the stored set, native round trip,
  legacy-key migration.

**Client (phase T3):**

- `DocumentApiClient.setVisibility(partId, {hidden, featureIds, categories, referencePlanes})` returning a `PartVisibilityDto`.
- `_hiddenFeatureIdsByPart` and `_referencePlanesHidden` become a **cache of the backend's state**: filled from `PartResponse` on
  load and replaced by each `setVisibility` response. The 18 places that mutate `_hiddenFeatureIds` today become calls to one
  `_setFeaturesHidden(ids, hidden)` (optimistic update, roll back and show the error if the call fails). The getter and all
  its read sites stay as they are.
- Stop writing / reading the client stash's `hidden_feature_ids` in `_rootClientExtras` / `_parseClientExtras` (the
  backend export now carries it). `section_planes` stays a client extra.
- Rollback exclusion (`_rollbackExcludedFeatureIds`) is a different thing and stays client-side.
- **Assembly lens:** the chips act on every Part in the composed assembly (one call per Part), and the assembly mesh honours
  each Part's stored set. Occurrence hide (`Occurrence.hidden`) is unchanged.
- **New features are visible**: hiding Sketches hides the sketches that exist; a sketch made afterwards shows, and the chip
  turns half-filled. That is what a batch change means; say so in the chip's tooltip.

**Forced visible during picks** (client-side, display only - never written to the backend): generalising
`_referencePlanesForcedVisible`, while a flow needs the user to tap something of a category, that category is drawn and
pickable whatever its hidden state - sketches during every sketch / profile picker (`_anyFeatureOrSourcePickerSessionActive`
and the profile / path pickers), surfaces during the Knit / Thicken / Solid-from-surfaces / Offset pickers, solids during body
pickers (Extrude target body, Mirror / Pattern bodies, Boolean, Split, Shell), created planes during plane picks. One getter per
category, next to `_referencePlanesForcedVisible`. Chips show a lock badge while forced, so the user knows why hidden geometry is
showing. Outside those flows hidden means **not drawn and not pickable**, and Fit frames only what is visible.

- The Visibility quick button shows a dot badge whenever any category is hidden, so hidden geometry is never a surprise after the
  panel is closed.
- Icons: reuse `parttoolbar_show/hide_reference_planes.svg` and the feature-tree section icons where they exist; otherwise
  Material icons for now, listed in the PR as a follow-up for proper SVGs.

## 7. Owner's decisions (30 Oct 2026)

1. **Tree button** stays alone at the top left.
2. **Fit and Orbit / Select close the quick column** after acting.
3. **Opening the Visibility panel closes the quick column.** The panel stays until its own close.
4. **Long press** also opens the quick column.
5. **Hide / show is backend state, saved in the file**; the category toggles are batch changes of it (section 6.1).
6. **Sketch screen:** not in this plan.

## 8. Phases (each a session)

| Phase | Covers |
|---|---|
| **T0** | Backend: `Part.hidden_feature_ids` / `reference_planes_hidden`, `PATCH /parts/{id}/visibility`, mesh routes honouring them, native save / load with the legacy key, pytest (section 6.1). |
| **T1** | `_ribbonTabs(touch:)`, shared feature-group table, `RibbonGroup.title`; `StartMenuSheet` (lens header, tabs, tiles); Start FAB tap opens it; remove the lens, Measure and Section FABs and the Add menus from the phone layout. Tests updated (see 9). |
| **T2** | `StartButton` with the column: swipe / long press / X, the four quick buttons, close-after-action rules, `showResetViewButton: false` on phone, hamburger FAB removed, stand-alone Orbit / Select during tool sessions (5.4), swipe hint. |
| **T3** | Client side of 6.1: `setVisibility`, the hidden-state cache, the 18 mutation sites through `_setFeaturesHidden`, stash key dropped; forced-visible getters; the Visibility panel (both rows, three-state chips), badge; Assembly lens. |
| **T4** | Polish: animation timings, Recent row (optional), landscape and small-phone (360 x 640) layout pass, `docs/roadmap.md` / status entry, on-device checklist (10). |

T0 and T1 can run in parallel; T2 needs T1; T3 needs T0 and T2.

## 9. Tests

- Read `docs/flutter-widget-test-lessons.md` first.
- `test/part_screen_test.dart` has about 60 lines that find the FABs being moved (`add-fab`, `measure-fab`, `section-fab`,
  `hamburger-fab`, `assembly-lens-fab`, `selection-mode-fab`, or their tooltips). Add helpers (`openStartMenu`,
  `tapStartCommand(tester, 'Measure')`, `openQuickColumn` via long press, `toggleSelectionMode`) to the test file's helpers and
  move the tests onto them in T1 / T2. Do not delete coverage: each test keeps checking the same behaviour, reached the new way.
  The tests that check the Add FAB hides during tool panels (e.g. "the "Add" FAB is hidden while the Extrude panel is open") now
  check Start.
- New: `test/start_menu_test.dart` (tabs per lens, lens switch in place, tile runs the command, disabled tiles), `test/
  start_button_test.dart` (tap vs drag vs long press, X, every quick button closes the column, closes when a tool opens),
  `test/visibility_panel_test.dart` (three-state chips from a hidden set, tap rules, lock badge), part-screen tests with a fake API
  that a chip sends one batch `setVisibility` call and applies its response, that a failed call rolls back, that hiding Solids
  removes bodies from the viewport and from picking, that a profile picker forces sketches back on, and that a tree-eye hide goes
  through the same call. Existing hide / show and native save / load tests move from the client stash to the backend fields.
- Backend: pytest as listed in 6.1; the e2e / round-trip tests that save and reopen a file with hidden features.
- The desktop-layout tests ("desktop layout (D6)") must pass unchanged: the desktop ribbon is still built from `_ribbonTabs()`.
- `flutter analyze` and the whole `flutter test` suite clean before each push.

## 10. On-device checklist (not verifiable in widget tests)

Swipe up from Start on a phone with gesture navigation (no clash with the system home swipe: Start sits above the inset); a slow
swipe vs a tap; one-handed reach of the top quick button; the column and the Visibility panel not covering a tool panel; landscape;
the badge and lock states readable; frame rate while the column animates over a heavy model. Record results in the PR; do not claim
any of it was checked on a device unless it was.

## 11. Risks

- `part_screen.dart` is ~27 000 lines. New widgets go in their own files (`start_button.dart`, `start_menu_sheet.dart`,
  `visibility_panel.dart`); `PartScreen` only wires state and callbacks.
- Moving hide / show to the backend touches saved files: the legacy top-level key must keep round-tripping (older app builds and
  the VR client read it) until both have moved to the backend fields. Test a file saved before T0 opening after it, and a file
  saved after T0 opening in the VR client's loader (it just reads the legacy key).
- A hide now costs a round trip. Apply it optimistically so the tap feels instant; the mesh does not need refetching (hidden
  bodies are already in the last response, flagged).
- The FAB visibility rules are a long list of hard-won exceptions (see the comments at the add FAB's build site). Start inherits
  the add FAB's condition **as is**; do not rewrite it.
- Gesture conflicts: the drag recognizer sits only on the Start button's own area, never the viewport, so orbit / pan / pinch are
  unaffected.
