# Assembly tree overhaul: scope (20 Nov 2026)

The owner asked for a scoping review of the build / assembly / feature tree in the Flutter client and the Godot VR client.
The prompt was that sub-assemblies and parts don't expand: you cannot see the children of children. This doc covers what the
leading CAD products do, what ours do today, a ranked list of what's missing and how to add it, and how the tree should treat
the upstream assembly in Make Focus and Edit Alone, on desktop and on a phone.

**Visual concepts** (desktop, Focus, Edit Alone, phone sheet, deep nesting on a phone, VR room tree) are in the published page
<https://claude.ai/artifact/9bvc9fbpAnC2uhoq5vxpBW> (private to the owner until shared). This file is the text of record.

Code read: `client/lib/viewport3d/assembly_tree_panel.dart`, `feature_tree_panel.dart`, `edit_alone_row.dart`,
`component_context_menu.dart`, `client/lib/assembly/focus_stack.dart`, `occurrence_visibility.dart`, the focus / Edit Alone /
layout parts of `part_screen.dart`, `docs/view-override-edit-alone-sketch-origin-plan.md`, `docs/desktop-layout-scope.md`;
DIDSA-VR `scripts/assembly_tree_window.gd`, `scripts/tree/occurrence_tree_model.gd`, `docs/feature-tree-review-2026-11-11.md`.
Nothing was built or run.

## 1. Where we are

| Capability | Flutter phone | Flutter desktop | VR world tree | Notes |
|---|---|---|---|---|
| Expand sub-assemblies (children of children) | No | No | Yes, lazy | Flutter lists one level; Make Focus swaps the tree rather than expanding it |
| Expand a part to its features inside an assembly | No | No | No | Flutter swaps to the Feature tree with the lens; VR only at the design table (BUILD tab) |
| Tree -> viewport selection | Top level | Top level | Any depth, by path | VR fixed "the second placement selects the first" (its B1); Flutter will meet it as soon as it nests |
| Viewport -> tree (expand, mark, scroll) | Mark only | Mark only | Yes | No row exists for a nested pick in Flutter |
| Constraint state per row | Yes | Yes | Yes | Pin / lock / open lock + DOF / warning |
| Rigid-set brackets | Yes | Yes | Yes | Ours; not seen elsewhere |
| Mates and Patterns sections | Focused level only | Focused level only | No | Nothing per sub-assembly |
| Problems shown on collapsed parents | No | No | No | Essential once rows collapse |
| Search / filter | No | No | No | |
| Focus breadcrumb | One level back | One level back | n/a | `AssemblyFocusStack` keeps the whole label path; the tree shows only the last label |
| Edit Alone in the tree | "Editing X [Done]" row | same | n/a | No upstream context, no "edits every placement" warning |
| Actions | Inline buttons + long-press menu | Right-click menu | Bottom bar | Phone inline buttons are 32 dp (below 48 dp) and squeezed by a `FittedBox` |
| Instance names | `bolt:2` | `bolt:2` | `Bolt <2>` | The clients disagree |
| Large assemblies | Builds every row (nested `ExpansionTile`s) | same | One request per expand | |

The data for nesting already exists in Flutter: `assembly-mesh` instances carry the full `occurrencePath`, and
`occurrence_visibility.dart` already resolves hide / isolate by path.

## 2. What the leading products do

- **SOLIDWORKS (FeatureManager):** one tree from assembly to sketch; state prefixes ((f) fixed, (-) under-defined); warnings on
  the parent of a broken item; options to expand the tree to the selection and scroll it into view; a flyout tree over the
  viewport while the PropertyManager has the pane; an optional Display Pane (visibility, appearance, transparency columns);
  breadcrumbs in the viewport. 2026: a Tree Display option to hide configuration / display-state clutter, and an option that
  stops lightweight parts resolving just because a row was expanded. Instance names `Bolt<2>`.
- **Fusion (Browser + Timeline):** component hierarchy with Bodies / Sketches / Origin / Joints folders per component, history
  on a horizontal timeline. **Activating** a component keeps the rest of the browser in place but greyed: the model for our Focus.
- **NX (Assembly Navigator):** distinguishes the **work part** (edit in context, the rest greyed) from the **displayed part**
  (the part on its own; the navigator re-roots on it). Our Focus is the work part and our Edit Alone is the displayed part.
- **Inventor / Solid Edge:** end-of-part marker, Relationships folders; Solid Edge's PathFinder has a lower pane listing the
  selected component's relationships, so mates aren't repeated under every row.
- **Onshape (Instances list):** sub-assemblies expand in place; mates in a folder; user folders; a filter with tokens
  (`:part`, `:assembly`, `:mate`, `:errors`, `:warnings`, `:suppressed`; filtering by warnings added 18 Sep 2026); eyes on hover.
- **Shapr3D (touch first):** Items Manager (tree view on iPad since late 2024) and a separate History panel; users report that
  both open at once leave too little room even on a 12.9" iPad, and ask for resizing and collapse-all.

Fusion, NX, Inventor and Solid Edge are from product knowledge, not checked against their 2026 releases.

**Conventions users will expect:** assembly at the root with indented children and a type icon; the tree and viewport select
each other (a 3D pick opens the ancestors, marks the row and scrolls to it); hidden / suppressed stay in the tree, dimmed;
missing files in red; problems on collapsed parents; instance numbers; mates in a folder per assembly level; right-click /
long-press menu; collapse all and a filter once trees get long.

**Ours to keep:** rigid-set brackets; mate health on rows (broken / near / held / followed, the pulse after a pattern edit);
`SelectionBreadcrumbBar` tiers; unsaved dots; VR's bottom action bar, world pulse and the planned leader line; Make Focus and
Edit Alone as two clear modes.

## 3. Rules for keeping it uncluttered

1. A healthy row is one line: chevron, type icon, name, instance number. A badge or second line only when something needs attention.
2. One state slot per row, most severe wins: missing > broken > over-constrained > unsaved > under-constrained > fixed.
3. No buttons in phone rows. Select the row, act from a bar. Only exception: the eye-off icon on a hidden row (it is state).
4. Desktop gets hover affordances and optional columns; touch gets neither.
5. Nothing twice: mates once per assembly level (the selection's own mates go in the selection panel); the focus breadcrumb
   and the root row are the same row.
6. Collapsed below the first level by default; expansion remembered per document.

## 4. Focus and Edit Alone: the upstream tree

- **Make Focus (edit in context):** keep the whole tree, **dim the rows outside the focus** (the viewport already fades them to
  0.25) and mark the focused branch with a rail in the assembly-lens colour. A breadcrumb strip at the top names every level
  (`AssemblyFocusStack`'s label path) and each crumb jumps there (pop to that depth). Make Focus straight from a nested row
  (push each level). Tapping a dimmed row offers to move the focus there. **On a phone** the dimmed rows are not shown: the
  rows outside the focus reduce to the pinned ancestor chain (section 5).
- **Edit Alone (the target on its own):** **re-root the tree on the target.** Nothing upstream is drawn in the viewport, so
  nothing upstream gets a row. Above the tree: "Editing <name> [Done]" and one read-only line "in Rover > Mast", each crumb
  leaving Edit Alone to that level, plus **"used N x"** when the target's Part is placed more than once (an edit changes every
  placement; VR's B3). This one strip replaces today's Edit Alone row and the separate root row.
- **VR:** a room is the Edit Alone analogue and the design table is the single-part analogue. The room's docked tree (VR T2)
  gets the same context strip and "used N x"; the world tree, while a room is open, dims the rows outside it.

## 5. Desktop and phone

- **Desktop (docked pane):** one tree, any depth, 28-30 px rows; header with collapse all, a filter box and a Columns menu (off by
  default: eye, colour disc, transparency, DOF); hover shows the eye and lights the part; right-click menu as today; a flyout tree
  over the viewport while a tool panel holds the pane.
- **Phone portrait: the tree as a sheet** with three heights (peek: the header and the selected row; half; full) instead of a
  side panel at 66% width. In portrait the phone is short of width, not height, and indentation uses width. The root row becomes
  the sheet title (one level of indent saved). Rows 44-48 dp, no buttons. A bar for the selected row: Hide, Isolate, Focus,
  Alone, More (Fix / Float, Colour, Rename, Mate, Pattern, Delete). Feature rows get Edit, Roll back, Hide. The sheet drops to
  peek when a tool panel opens.
- **Phone, deep trees:** ancestors pin to the top while scrolling (like section headers in a contacts list); tapping one
  collapses back to it. Indent capped at about 4 levels (12 dp each); deeper rows stop moving right.
- **Phone landscape / tablet:** keep the side panel.

## 6. Missing features, ranked

Tier 1 is the foundation and the headline gap, tier 2 is what CAD users expect, tier 3 is power and polish.
Size: S under 2 days, M up to a week, L more.

| # | Feature | Tier | How | Client | Size |
|---|---|---|---|---|---|
| 1 | **Expand sub-assemblies and parts to any depth** | 1 | Pure `AssemblyTreeModel` (nodes keyed by **full occurrence path**, expanded set, lazy children), mirroring VR's `occurrence_tree_model.gd`; children from #2; a part's features from `GET /parts/{id}` on first open | Flutter | M |
| 2 | **Whole hierarchy in one call; virtualised rows** | 1 | Backend `GET /parts/{id}/assembly-tree`: nested occurrences with names, part ids, fixed / hidden / suppressed / missing, instance counts and rolled-up problem counts, no geometry. Client flattens visible rows into one `ListView.builder` (fixed extent, cheap scroll-to-row) replacing nested `ExpansionTile`s | Backend, both | M |
| 3 | **Two-way selection at any depth** | 1 | Widen `_selectedOccurrenceId` to a path; a viewport pick opens ancestors, marks and scrolls; a row selects by path. Reuse VR's B1 test (two placements of one sub-assembly) | Flutter | M |
| 4 | **Problems bubble up to collapsed parents** | 1 | Subtree counts from #2 (missing, broken / over-constrained, near, unsaved); one red or amber bubble; tap opens the first problem | Both | S |
| 5 | **Focus and Edit Alone context** | 1 | Section 4 | Flutter; VR rooms | M |
| 6 | **Declutter phone rows; selection bar** | 1 | Section 3 rules 1-3, the bar in section 5; desktop keeps right-click, adds hover eye | Flutter | S-M |
| 7 | Mates folder per assembly level; the selection's mates in the selection panel | 2 | Collapsed "Mates (n)" under each assembly row with a health bubble; the component drawer / desktop selection section lists the selected component's mates | Both | M |
| 8 | Search and filter | 2 | Name filter keeping ancestors of matches; tokens `:missing :errors :hidden :fixed :unsaved :mates` | Both | S-M |
| 9 | Phone portrait sheet | 2 | Section 5 (Q2) | Flutter | M |
| 10 | Collapse all, expand to selection, remembered state | 2 | Header buttons; expanded paths per document in view preferences | Both | S |
| 11 | One instance-name format in both clients; fold repeats | 2 | Q4. Fold more than 3 identical siblings into "Bolt M4 x4", expanding to the instances. A shared spec with golden JSON vectors (names, state icon, bubbles, actions per row kind) both clients test against, as the solver vectors are shared | Both | S |
| 12 | Hover linking | 2 | Row hover lights the part (existing highlight override); part hover lights the row. Desktop and VR laser | Flutter desktop, VR | S |
| 13 | Edit a feature in context from the tree | 2 | Double-click a feature under a nested part: focus its path, Part lens, open the feature panel (builds on assembly-scope section 5 item 10) | Flutter | M |
| 14 | Flyout tree over the viewport | 3 | While a docked tool panel holds the pane, a translucent pick-only tree top-left (SOLIDWORKS) | Flutter desktop | S-M |
| 15 | Optional columns | 3 | Columns menu: eye, colour, transparency, DOF; the colour disc moves here from the row | Flutter desktop | S |
| 16 | Drag to reorder / restructure | 3 | Desktop drag; phone More > Move to...; backend moves that carry mates | Backend, Flutter | L |
| 17 | Rollback bar | 3 | Desktop draggable bar; phone "Roll back to here" | Flutter | M |
| 18 | User folders | 3 | Display-only grouping on the Part | Backend, both | M |
| 19 | VR T2 / T3 (`feature-tree-review-2026-11-11.md`) | 2 | As planned there, plus the context strip and "used N x" and parts opening to features with a "Table" action | VR | M-L |

**Left out on purpose:** buttons in phone rows (colour disc, always-on eye); mates repeated under every component; subtitles on
healthy rows ("Moves with ..." only on the selected row or its tooltip; the bracket is enough otherwise); hidden context rows in
Edit Alone; two trees side by side on a phone.

## 7. Phasing

| Phase | Contents | Notes |
|---|---|---|
| A, foundation | #2, #1, #3, #4, #6, the shared spec and vectors (#11) | The headline fix. VR can adopt the endpoint and bubbles at the same time |
| B, context | #5, #9, #10, #8 | After Q2 and Q3 |
| C, depth | #7, #13, #12, #14, #15; VR T2 | |
| D, power | #16, #17, #18; VR T3 | Backend work |

**Tests:** pure model tests against the shared vectors in both clients (paths, merge on refresh, bubbles, names, actions per
row kind); a widget test that a viewport pick under the second placement of a sub-assembly opens the second branch; a scroll
test at 2,000 rows. Not testable headless: feel, the sheet's heights, readability on a device.

## 8. Questions for the owner

1. **One tree with features under parts, or keep the lens split?** Recommended: one tree (the lens still switches toolbars;
   a part opened on its own shows the same tree with the part at the root).
2. **Phone portrait: bottom sheet or today's side panel?** Recommended: sheet in portrait, side panel in landscape.
3. **Upstream rows in Focus:** dimmed in place on desktop and reduced to pinned ancestors on a phone, or the same on both?
4. **Instance name format:** `Bolt<2>`, `Bolt <2>` (VR) or `bolt:2` (Flutter)? Recommended `Bolt <2>` in both.
5. **Add `GET /parts/{id}/assembly-tree`?** Recommended: yes (removes per-level fetches in VR; needed for bubbles).
6. **Fold repeated parts** ("Bolt M4 x4") by default, or only from a header toggle?

## Sources

- [What's New in SOLIDWORKS 2026 – Design](https://blogs.solidworks.com/products/solidworks/whats-new-in-solidworks-2026-design)
- [GoEngineer: SOLIDWORKS 2026 UI/UX](https://www.goengineer.com/blog/solidworks-2026-ui-ux-performance-and-imports-whats-new)
- [SOLIDWORKS FeatureManager Design Tree overview](https://help.solidworks.com/2022/English/SolidWorks/sldworks/c_featuremanager_design_tree.htm)
- [Onshape: Instances list](https://cad.onshape.com/help/Content/Assembly/instances_list.htm)
- [Onshape improvements, 18 Sep 2026](https://forum.onshape.com/discussion/31763/improvements-to-onshape-september-18-2026)
- [Shapr3D version history](https://www.shapr3d.com/content-library/brief-version-history)
- [Shapr3D Items Manager](https://support.shapr3d.com/hc/en-us/articles/7873936188956)
- [Shapr3D forum: resizable Items and History panels](https://discourse.shapr3d.com/t/make-items-panel-and-history-panel-resizable/28059)
