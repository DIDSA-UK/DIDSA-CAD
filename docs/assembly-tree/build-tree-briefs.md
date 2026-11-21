# Build tree into the one tree: briefs (Phase B insert)

**Status:** written 21 Nov 2026 for the Phase B manager to slot into section 10 of `docs/assembly-tree-overhaul-scope.md`.
Nothing built. The rules in 10.3 to 10.5 (every worker, report format, manager checks) apply unchanged, with chunk names
`P<n>` and PR titles `Tree P<n>: <summary>`.

## Why this exists

The owner's answer 1 (section 8 of the scope) is **one tree**: features under parts, and a part opened on its own shows the
same tree with the part at the root. Phase A put feature *names* under part rows in the assembly tree, but no phase owned the
build tree itself. The Part lens and the sketcher still draw the old `FeatureTreePanel`
(`client/lib/viewport3d/feature_tree_panel.dart`, about 1,370 lines). This was a gap in the original phasing.

It goes inside Phase B, after B2 and before B3. B3 (Edit Alone on a part switches to the Part lens) and B4 / B5 (the phone
sheet, deep trees) would otherwise be built for the assembly tree only, and then redone for the build tree.

## Owner's decisions (21 Nov 2026)

1. **The Part lens inside an assembly shows the whole tree.** The assembly tree stays, dimmed outside the focus as B3 builds it,
   with the focused part's row open to its features and folders. The lens switches the toolbars, not the tree. A part file
   opened on its own shows the same widget with the part as the root.
2. **Tapping a feature row selects it**, the same as an assembly row: it highlights what the feature made in the viewport and
   shows the bar. **Edit** is in the bar, on a double-tap (touch) and on a double-click (desktop); the right-click /
   long-press menu still has it. This replaces today's tap, which opens the edit panel and rolls back.

## Target behaviour (what the P chunks build)

- **One widget everywhere.** `AssemblyTreeView` draws the Assembly lens, the Part lens and the sketcher's read-mostly tree.
  `FeatureTreePanel` and `EditAloneRow` are removed at the end (P3). (B3 retires `EditAloneRow` from the assembly tree; P2 and
  P3 make sure nothing else uses it.)
- **The live part.** One row at a time is the *live part*: the root when a part is opened on its own, or the focused part's
  row in the Part lens inside an assembly. Only the live part's rows are editable, pickable and carry the full feature state.
  Feature rows under other parts stay as Phase A made them: read-only names. Editing those in context is #13, Phase C.
- **Under the live part, in today's order:** the folder rows **Bodies**, **Planes** (the three default planes, then the
  plane features), **Surfaces** and **Curves**, all collapsed, each shown only when it has something in it (Planes always).
  Then its **features in build order**, open. Folder contents are the same rows the old panel had: bodies, surfaces and curves
  come from `GET /mesh`, as today.
- **Feature row anatomy** follows scope section 3: a type icon (the existing SVGs), the name, and **one state slot**.
  Severity order:

  lost reference (red; the reason in the tooltip and the bar) > moved or held reference (amber) > waiting for detail (the
  LOD pending marker) > after the rollback point (dimmed) > hidden (eye-off)

  The LOD "pin to coarse" control leaves the row. It becomes a desktop column and a More action on touch.
- **The bar for a feature row** (phone; desktop keeps the right-click menu and the double-click):
  - **Edit**, **Roll back to here**, **Hide / Show**, **More**;
  - More holds **Delete** (the cascade confirmation as today), **Pin to coarse** where it applies, and anything else the old
    row menu had.

  Body / surface / curve rows: **Hide / Show**, **Zoom**, More. Default planes: **Show / Hide**; their tap opens the plane
  sheet, as today.
- **Picker modes** become rules in the model, not separate widgets. Each row gets *pickable / picked / locked (with a
  reason)*. While a picker is open, its banner replaces the bar. The modes:
  - the sketch picker for a pending Extrude;
  - the Mirror / Pattern source multi-picker;
  - convert pick in the sketcher (earlier sketches pickable, later ones locked with the reason);
  - the sketcher's read-mostly lock (`lockedReason`).

  Multi-select (long-press) keeps its keys (`TreeMultiSelectKeys`) and header.
- **Search and remembered rows** (B2) work on the live part too. All its features are fetched, so all of them can match.

## Contract additions (go into B1; B1 has not started)

B1 already adds spec sections 11 (filter) and 12 (remembered rows) and vectors v2. Add to the same chunk:

**Spec section 13, the live part.**
- **Inputs:** the live row's key (`""` for a part opened alone), its features with their state flags, and its bodies,
  surfaces, curves and plane features.
- **Rows under the live part:** the folder rows `bodies_folder`, `planes_folder`, `surfaces_folder` and `curves_folder`, then
  the features. Their keys are `<owner key>#bodies` (and so on), and `#plane:xy|xz|yz` for a default plane. Body, surface and
  curve rows are keyed `#body:<id>`, `#surface:<id>` and `#curve:<id>`. When a folder shows, and its default open state
  (collapsed).
- **The feature state slot:** the order above, with a state name for each (`lost_reference`, `moved_reference`,
  `pending_detail`, `rolled_back`, `hidden`).
- **The filter (section 11) on these rows:**
  - `:errors` also matches `lost_reference`, and `:warnings` matches `moved_reference`;
  - `:hidden` matches hidden features and bodies;
  - new tokens `:features` and `:sketches`;
  - folder rows never match, but a match inside one lists the folder.
- **Remembered rows (section 12):** folder keys can be open keys; feature, body and plane keys never are.

**Vectors:** a case kind `live_part` (section 7's inputs plus the live part's inputs; `expected`: the rows), plus filter cases
that use it. Like everything else, they are generated by `tools/assembly_tree_vectors/`. If B1's version 2 is already out,
these make version 3. VR copies them when it adopts the build tree (Phase C); its BUILD tab is not changed in Phase B.

Cases at least:
- a part opened alone (folders hidden when empty, Planes always);
- the live part three levels down in an assembly;
- every feature state, and two states on one feature (the most severe wins);
- a filter on a lost reference inside a collapsed live part;
- a filter match inside Bodies;
- restore with a folder key and with a feature key.

## Order

```
B1 (+ section 13) → B2 → P1 → P2 → P3 → B3 → B4 → B5          (VR: B6 → B7 → B8, unchanged)
```

Owner device checks after P2 (Part lens on desktop and phone: a part opened alone, and a part focused inside an assembly)
and after P3 (the sketcher's tree, convert pick).

## The briefs

### P1. Live part in the model and the widget (DIDSA-CAD `client/`)

**Suggested model:** mid-tier; the strongest if B2's report flags trouble in the model or the view. **Size:** M.
**Depends on:** B1 (with section 13) and B2 merged.

**Build:**
- **`AssemblyTreeModel`:**
  - the live-part inputs (`setLivePart(key, features, bodies, surfaces, curves)` or equivalent) and the section 13 rows, keys
    and state slot, passing every `live_part` vector and the new filter and restore cases;
  - picker rules: `setPicker(mode, pickable, picked, locked + reason)`, giving each row a pickable / picked / locked flag;
  - multi-select keys as `TreeMultiSelectKeys`.
- **`AssemblyTreeView`:**
  - the folder and feature rows, with icons from the existing feature SVGs and one state slot;
  - the feature, body and plane bars (section "Target behaviour");
  - double-tap and double-click raise `onEdit`;
  - the picker banner in place of the bar while a picker is open;
  - the multi-select header for feature rows;
  - the coarse pin as a desktop column, off by default, plus a More action.

**Done when:**
- Model tests pass every new vector.
- View tests cover:
  - a part opened alone draws its folders and features in order;
  - a tap selects and does not edit, while a double-tap edits;
  - a lost reference shows red with its reason in the bar;
  - Roll back to here fires its callback;
  - in sketch-picker mode, ineligible rows are locked and the banner shows;
  - the source multi-picker ticks rows;
  - the sketcher lock shows its reason;
  - long-press multi-select;
  - the desktop pin column.
- `flutter analyze` is clean.

**Don't touch:** `part_screen.dart`, `feature_tree_panel.dart`, the contract.

### P2. The Part lens on the one tree (DIDSA-CAD `client/`)

**Suggested model:** strongest (`part_screen.dart` is about 30,000 lines, and this is the riskiest chunk of the overhaul).
**Size:** L. **Depends on:** P1.

**Build:**
- **`part_screen.dart`:** the Part lens draws `AssemblyTreeView`, desktop pane and phone panel alike:
  - for a part opened alone, the root is the part;
  - inside an assembly, the whole tree, with the focused part as the live part;
  - switching lens changes the toolbars and which row is live, and keeps the tree, its open rows, the scroll position and the
    selection.
- **Wiring:** every `FeatureTreePanel` input moves to the new tree or is listed as dropped, with the reason. The inputs and
  what they do:
  - feature tap, long-press and context menus (features, bodies, surfaces, curves);
  - body / surface / curve tap and hide;
  - the default planes (tap opens the plane sheet; show / hide);
  - the hidden sets and lost / moved references;
  - pending detail and the coarse pin;
  - the sketch picker, the feature source picker and the multi-select header;
  - Edit Alone;
  - the resize handle and the docked / overlay layouts.
- **Tap now selects.** `_onFeatureTap`'s edit-and-rollback flow moves to the bar's Edit, the double-tap and the menu. A tap
  selects the feature and highlights what it made in the viewport, through the existing highlight path. Picking a body or
  face in the viewport reveals and marks its feature row (the producing feature, through `baseFeatureId`).
- Background answers (mesh, features, the tree) follow 10.3's stale-answer rule across lens switches and focus changes.

**Done when:**
- The PR has a table of every `FeatureTreePanel` input: where it went, or why it was dropped.
- `part_screen_test` gets a "Build tree" group covering:
  - a part opened alone shows the folders and features;
  - a tap selects and highlights, and does not open a panel;
  - Edit from the bar opens the panel at the rollback point;
  - double-tap edits;
  - Hide on a feature and on a body;
  - a default plane's tap opens the plane sheet;
  - Extrude's sketch picker and Mirror's source picker through the tree;
  - multi-select delete;
  - lens switching keeps the open rows and selection;
  - inside an assembly, the Part lens shows the whole tree with the focused part live;
  - a late features answer after a focus change is dropped.
- `feature_tree_panel_test.dart` cases are moved to the new tests, or retired with a reason.
- `tools/gui_harness/` screenshots on desktop and at phone size.
- `flutter analyze` is clean, and the whole `flutter test` passes.

**Don't touch:** the sketcher's tree (P3), the contract, B3 to B5 work (focus dimming, the phone sheet).

### P3. The sketcher's tree, and retiring the old panel (DIDSA-CAD `client/`)

**Suggested model:** mid-tier. **Size:** M. **Depends on:** P2.

**Build:**
- `_buildSketchTreePanel` (`part_screen.dart`) draws `AssemblyTreeView` in its read-mostly lock (the `lockedReason`), with
  convert pick (earlier sketches pickable, later ones locked with the reason, the picked ones ticked) and its visibility
  toggles.
- Delete `feature_tree_panel.dart`, and `edit_alone_row.dart` if nothing uses it after B3. Move what other files still import
  (`featureDisplayName`, the icon map, `isFeatureEditable`, ...) to `client/lib/viewport3d/feature_tree_helpers.dart`.
  `feature_context_menu.dart`, `feature_picker_sheet.dart`, `extrude_panel.dart` and `resizable_tool_panel.dart` import from
  the new place.

**Done when:**
- Tests for the sketcher's tree: rows locked with the reason, convert pick ticks an earlier sketch and refuses a later one,
  visibility toggles. They replace what `sketch_screen_feature_tree_test.dart` covers.
- No file imports `feature_tree_panel.dart`.
- Screenshots of the sketcher's tree.
- `flutter analyze` is clean, and the whole `flutter test` passes.

**Don't touch:** the contract, VR, B3 to B5 work.

## Left for later

- Edit a feature of a non-live part from the tree (#13, Phase C).
- The draggable rollback bar (#17, Phase D); "Roll back to here" covers it until then.
- VR's design-table BUILD tab adopting section 13 (Phase C, with VR T2).
- Reordering features by drag. The old panel didn't do it either; if a reorder exists elsewhere, P2 lists it in its table.
