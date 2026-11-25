# Assembly tree overhaul: scope (20 Nov 2026)

The owner asked for a scoping review of the build / assembly / feature tree in the Flutter client and the Godot VR client.
The prompt was that sub-assemblies and parts don't expand: you cannot see the children of children. This doc covers what the
leading CAD products do, what ours do today, a ranked list of what's missing and how to add it, and how the tree should treat
the upstream assembly in Make Focus and Edit Alone, on desktop and on a phone.

**Status:** Phase A built and closed 21 Nov (section 9). Phase B complete 25 Nov (section 10), with the build tree (P1-P3) folded in. Phase C briefs in section 12 (25 Nov; owner's questions in 12.8). How every phase is run: section 11.

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
| 9 | Phone portrait sheet | 2 | Section 5 (decided, section 8) | Flutter | M |
| 10 | Collapse all, expand to selection, remembered state | 2 | Header buttons; expanded paths per document in view preferences | Both | S |
| 11 | One instance-name format in both clients; fold repeats | 2 | `Bolt <2>` (section 8). Fold (on by default, can be switched off) more than 3 identical siblings into "Bolt M4 x4", expanding to the instances. A shared spec with golden JSON vectors (names, state icon, bubbles, actions per row kind) both clients test against, as the solver vectors are shared | Both | S |
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
| B, context | #5, #9, #10, #8; the build tree (P1-P3) | Q2 and Q3 answered (section 8). Briefs: section 10 |
| C, depth | #7, #13, #12, #14, #15; VR T2 | Run as section 11 says. Briefs: section 12 |
| D, power | #16, #17, #18; VR T3 | Backend work. Run as section 11 says |

**Tests:** pure model tests against the shared vectors in both clients (paths, merge on refresh, bubbles, names, actions per
row kind); a widget test that a viewport pick under the second placement of a sub-assembly opens the second branch; a scroll
test at 2,000 rows. Not testable headless: feel, the sheet's heights, readability on a device.

## 8. Owner's answers (20 Nov 2026)

1. **One tree**, with features under parts. The Part / Assembly lens still switches the toolbars; a part opened on its own shows
   the same tree with the part at the root.
2. **Phone portrait: a bottom sheet** with three heights; phone landscape and tablets keep the side panel.
3. **Focus upstream rows differ by layout:** dimmed in place on desktop (and tablet / landscape side panel); reduced to the
   pinned ancestor chain on a phone in portrait.
4. **Instance names `Bolt <2>`** in both clients (Flutter changes from `bolt:2`; VR already uses it).
5. **Yes, add `GET /parts/{id}/assembly-tree`** (the whole hierarchy in one call, with rolled-up problem counts).
6. **Repeated parts are grouped by default** ("Bolt M4 x4", more than 3 identical siblings), with a switch to turn grouping off
   (a header / Columns-menu toggle, remembered in view preferences).

## 9. Phase A: implementation briefs

Phase A is built by a chain of sessions: a **manager** session that hands out these briefs, checks the results and keeps the
progress table (9.7) current, and **worker** sessions that each build one chunk. This section is the single source of truth.
A worker prompt only needs to name its chunk; everything else is here.

### 9.1 Order and gates

```
A1 contract (DIDSA-CAD: backend + spec + vectors)
 ├── A2 Flutter tree logic (DIDSA-CAD client, pure)      ──> A3 Flutter tree widget ──> A4 Flutter integration
 └── A5 VR adoption (DIDSA-VR)                            (A5 can run alongside A2-A4)
```

- A chunk starts only after the chunk it depends on is **merged to `main`**, and starts from `main`.
- Owner device checks: after A4 (the Flutter tree on a phone and on desktop) and after A5 (the headset).
- Phase B to D get briefs of their own after Phase A has been used.

### 9.2 The contract (fixed once A1 merges)

A1 produces these. After A1 merges, nobody else changes them. A worker that needs a change says so in its report, and the
manager changes the contract in both repos at once.

1. **`GET /parts/{part_id}/assembly-tree`** (backend), with its response schema documented in `docs/assembly-tree/spec.md`.
2. **`docs/assembly-tree/spec.md`**: the rules both clients follow:
   - display names (name override, then the Part's name, then the file name if a person chose it, then "Component N"),
     with `<n>` instance suffixes, written `Bolt <2>`;
   - grouping repeats (on by default, can be switched off);
   - the single state slot and its severity order: missing > broken > over-constrained > unsaved > under-constrained > fixed;
   - problem counts on collapsed rows;
   - how the visible rows are listed for a given set of open rows (order, depth, group rows);
   - row keys (the full occurrence path; how a group row and a feature row are keyed).
3. **`docs/assembly-tree/vectors.json`**: input trees and expected outputs for every rule in the spec, produced by a small
   reference implementation in `tools/assembly_tree_vectors/` (with its own test), not typed by hand. Flutter tests read it
   from `../docs/assembly-tree/vectors.json`. VR copies it to `tests/fixtures/assembly_tree_vectors.json` and registers it in
   `tests/fixtures/README.md`, as it does the other vector files.

"Unsaved" is client-side state: the vectors take it as an input; the backend never reports it.

### 9.3 Every worker

- **Read first:** the repo's `CLAUDE.md` (DIDSA-VR has one; DIDSA-CAD has none), `docs/status.md`, sections 1 to 8 of this doc,
  your brief, and the contract (9.2) if your chunk comes after A1. Read only the files your brief names, plus what they lead
  you to.
- **Stay in your chunk.** Don't change files another chunk owns, and don't change the contract.
- **Branch:** the branch your session is given. When done, push and open a PR into `main` titled `Tree A<n>: <summary>`, with a
  body in the format of 9.4.
- **Tests:** the commands CI runs for the parts you touched, all passing before you report. DIDSA-CAD backend:
  `python -m pytest tests/ -m "not gears" -n auto` in `backend/` (or the files you touched plus the assembly files, if the whole
  suite is too slow here; say which). Client: `flutter analyze` and `flutter test` in `client/`. DIDSA-VR: `tests/ci.sh`
  (see its `CLAUDE.md` for adding test files).
- **Docs:** add an entry to that repo's `docs/status.md` (what was built, the tests, what is not verified). Don't edit 9.7:
  the manager owns it.
- **Say what you could not verify.** Never write that something works on a device.

### 9.4 Report format (the PR body and the reply to the manager)

```
Chunk: A<n>   PR: <link>   Branch: <name>
Built: <bullets>
Differs from the brief: <bullets, or "nothing">
Contract change needed: <none, or what and why>
Tests: <files added/changed>; <command> -> <pass/fail counts>
Not verified: <bullets>
Owner should try: <bullets, or "nothing yet">
```

### 9.5 Manager checks before merging

1. CI is green on the PR.
2. The report matches the brief: every "Done when" point is covered, and differences are explained.
3. The diff stays inside the chunk; the contract is untouched (after A1).
4. Run `/code-review` on the PR and act on what it finds.
5. Anything bigger than a one-line fix goes back to the worker with a short list; the manager doesn't implement it.
6. After merging: update 9.7 (the manager owns it: commit it on the manager's own branch and bring it to `main` in a small docs
   PR now and then) and give the owner the next worker prompt (and the device check, where 9.1 says so).

### 9.6 The briefs

#### A1. Contract: hierarchy endpoint, spec and vectors (DIDSA-CAD)

**Suggested model:** strongest. **Size:** M. **Depends on:** nothing.

**Build:**
- `GET /parts/{part_id}/assembly-tree` in `backend/app/document/router.py` (next to `list_occurrences` and
  `get_constraint_status`), with its schemas in `schemas.py`. One nested response from the root Part down. Each occurrence node
  has:
  - `occurrence_id` and `path` (occurrence ids from the root);
  - `external_ref`, `ref_part_id` and `resolved_part_id`;
  - `part_name` (the resolved Part's own name, so clients don't need a fetch per Part), `name_override`;
  - `kind` (`assembly` / `part` / `missing`), `fixed`, `hidden`, `suppressed`, `color`;
  - `constraint` (status, dof, rigid set: what `constraint-status` reports for it within its parent);
  - `feature_count` (so a part row knows whether to show a chevron);
  - `children`.

  Each assembly node (the root included) also has `mates` and `patterns` summaries (count; broken, near, held / lost counts)
  and a rolled-up `problems` count for its subtree (missing, broken or over-constrained, near).
- **Guards:** a reference cycle or a Part placed inside itself must not recurse; mark the node and stop. Cap the depth (say
  32) and the node count, and report when a cap was hit. Pattern copies are not nodes.
- **Cost:** time it on the VR gear-train demo (`DIDSA-VR/demo/assemblies/gear_train/`, if reachable, or an equivalent fixture)
  and on a synthetic tree of about 2,000 occurrences. If the constraint status makes it slow, put it behind `?status=true`
  (default to whatever keeps a typical tree under about 300 ms) and say so in the spec.
- `docs/assembly-tree/spec.md`, `docs/assembly-tree/vectors.json` and `tools/assembly_tree_vectors/` as in 9.2. Write the
  rules from today's behaviour where it already agrees: Flutter's `occurrenceDisplayName`, `looksGeneratedName` and
  `_withInstanceOrdinal` (`client/lib/viewport3d/assembly_tree_panel.dart`) and VR's `occurrence_tree_model.gd`
  (`apply_instance_names`, `state_icon`). The owner's answers in section 8 settle where they differ.

**Done when:**
- `backend/tests/test_assembly_tree.py` covers:
  - two levels;
  - one sub-assembly placed twice (distinct paths, same child ids);
  - a missing file, and hidden / suppressed / fixed;
  - the problem roll-up;
  - the cycle guard and the caps;
  - agreement with `/occurrences` and `/constraint-status` level by level.
- The reference implementation's test passes, and the vectors cover every rule in the spec, including grouping on and off and
  a tree with more than 3 identical siblings.
- The spec names every field and rule a client needs, so the A2 and A5 workers don't have to read the backend.

**Don't touch:** client code, DIDSA-VR.

#### A2. Flutter tree logic (DIDSA-CAD `client/`)

**Suggested model:** mid-tier. **Size:** M. **Depends on:** A1.

**Build:**
- The DTOs and `getAssemblyTree(partId)` in `client/lib/api/document_api_client.dart`, matching the spec.
- `client/lib/assembly/assembly_tree_model.dart`, pure Dart with no widgets:
  - nodes keyed by full path, a set of open rows, and the grouping switch;
  - `visibleRows()`, a flat list of rows for a given set of open rows. Each row has its depth, kind, label, state slot,
    problem count, group count and key;
  - lazy feature rows under a part (`setFeatures(path, features)`), named with the existing `featureDisplayName`;
  - the root Mates and Patterns folders as rows (per-level mates is Phase C);
  - `reveal(path)`, which returns the rows to open so a path is visible, and `indexOf(key)`;
  - `merge(newTree)`, which keeps the open rows and the selection after a refresh (VR's `merge_children` is the precedent).

**Done when:** `client/test/assembly_tree_model_test.dart` passes every vector in `../docs/assembly-tree/vectors.json`, plus
these cases:
- two placements of one sub-assembly give distinct keys;
- `reveal` on a 4-deep path;
- `merge` keeps what was open;
- feature rows appear under an open part.

`flutter analyze` is clean.

**Don't touch:** `part_screen.dart`, `assembly_tree_panel.dart` and any widget.

#### A3. Flutter tree widget (DIDSA-CAD `client/`)

**Suggested model:** mid-tier, or the strongest if A2's report flags trouble. **Size:** M. **Depends on:** A2.

**Build:** a new widget, `client/lib/viewport3d/assembly_tree_view.dart`. It doesn't replace anything yet; A4 swaps it in.
- It draws `AssemblyTreeModel.visibleRows()` in one `ListView.builder` with a fixed row height: 30 px on desktop, 48 dp on a
  phone (use `LayoutModeScope`).
- Rows follow the rules in section 3:
  - one state slot, problem counts on collapsed rows, and the unsaved dot;
  - the rigid-set bracket is kept;
  - an eye-off icon only on hidden rows;
  - no buttons in phone rows; a hover eye on desktop.
- Interaction:
  - tap to select, long-press for the menu or multi-select, right-click for the context menu (keep today's callbacks and
    multi-select behaviour);
  - a selection bar for phone (Hide, Isolate, Focus, Alone, More), passed in as callbacks.
- Header: title, collapse all, and the grouping switch (the widget only reports the change; A4 saves it).
- It keeps today's `visible` / `docked` / Edit Alone / focus-label inputs, so it can sit where the old panel sits.
- An `AssemblyTreeController` with `reveal(path)` that scrolls the row into view.

**Done when:** `client/test/assembly_tree_view_test.dart` covers:
- a nested row opens and closes;
- `reveal` scrolls to a row 4 deep among 2,000 rows (it builds only what is on screen);
- a problem count shows on a collapsed parent;
- a phone row has no buttons, and a hidden row shows the eye-off;
- the selection bar's callbacks fire;
- the grouping switch reports its change;
- the desktop hover eye appears.

`flutter analyze` is clean.

**Don't touch:** `part_screen.dart`, the old `assembly_tree_panel.dart`, the model (raise a problem with it in the report).

#### A4. Flutter integration (DIDSA-CAD `client/`)

**Suggested model:** strongest (`part_screen.dart` is about 30,000 lines). **Size:** M-L. **Depends on:** A3.

**Build:**
- In `part_screen.dart`, the Assembly tree uses `AssemblyTreeView`, fed by `getAssemblyTree` wherever the tree's
  occurrences and constraint status are fetched today. Keep the existing `/occurrences` fetches the rest of the screen relies on.
- **Selection by path:** `_selectedOccurrenceId` becomes a path. A viewport pick calls `reveal` (expand, mark, scroll). A row
  selects by path. Use VR's B1 test as the model: a pick under the second placement of a sub-assembly must reveal the second
  branch.
- **Nested rows' actions act on the right thing:**
  - Hide / Isolate are per path, so hiding a child under one placement does not hide it under the other. Check
    `occurrence_visibility.dart`, which matches bare ids today.
  - Fix / Float, Rename and Delete go to the occurrence on its parent Part. Delete warns "changes every placement (used N×)".
  - Make Focus from a nested row pushes each level onto `AssemblyFocusStack`.
- **Names** become `Bolt <2>` everywhere, through the spec's rules (about 7 files use `occurrenceDisplayName` /
  `occurrencePathDisplayName`).
- The grouping switch is saved in view preferences, on by default.
- Remove the old `AssemblyTreePanel`. Move its pure helpers that other files import (`mateDisplayName`, rigid-set helpers,
  `componentPatternDisplayName`, …) to a file of their own, so imports stay simple.

**Done when:** `part_screen_test.dart` has an "Assembly tree" group covering:
- a pick under the second placement reveals the right row;
- a row tap selects by path;
- hiding a nested row hides only that placement;
- Fix on a nested row PATCHes its parent Part;
- Make Focus from a nested row, then the breadcrumb back;
- the grouping switch is saved.

Also: the old panel's tests are moved or retired (say which), `flutter analyze` is clean, and the whole `flutter test` passes.

**Don't touch:** the backend and the contract; Phase B items (the phone sheet, the full breadcrumb strip, search).

#### A5. VR adoption (DIDSA-VR)

**Suggested model:** mid-tier. **Size:** M. **Depends on:** A1 (can run alongside A2 to A4).

**Build:**
- `scripts/assembly_tree_window.gd` reads `GET /parts/{id}/assembly-tree` once instead of one request per level, and falls
  back to the per-level fetch on a 404 (an older backend).
- `scripts/tree/occurrence_tree_model.gd` follows the spec for names, grouping (on by default; a switch in the window header,
  saved with the other user settings), the state slot and problem counts on collapsed rows.
- Copy the vectors into `tests/fixtures/assembly_tree_vectors.json` and register them in `tests/fixtures/README.md`.
- Keep everything T1 does: selection by path, the pulse, the bottom bar, refresh in place.

**Done when:**
- `tests/occurrence_tree_model.gd` passes every vector;
- `tests/occurrence_tree_actions.gd` passes with a fake backend that serves the new call, and with one that 404s;
- `tests/e2e_assembly_tree.gd` (named in the 11 Nov review, never written) runs against a live backend from `main`: it opens a
  two-level assembly, fixes a nested part from the tree, and checks that a grip on that part is refused. It is added to
  `tests/e2e_ci_list.txt`.
- `tests/ci.sh` is clean, and the test files are registered as the repo's `CLAUDE.md` says.

**Don't touch:** rooms, the design table, T2 / T3 work, DIDSA-CAD.

### 9.7 Progress

| Chunk | Status | PR | Model used | Notes |
|---|---|---|---|---|
| A1 contract | merged 20 Nov | #388 | strongest | One send-back (suppressed mates counted, one failing level failed the call, GET wrote mate refs); all fixed. Added states `cycle`, `near`; `status` off by default; `status_failed` / `status_incomplete`. |
| A2 Flutter logic | merged 20 Nov | #389 | mid-tier | One send-back (refresh lost open groups while grouping was off; small API/model nits); all fixed. 36/36 vectors. |
| A3 Flutter widget | merged 20 Nov | #390 | mid-tier | One send-back (late tree / hidden pane lost reveals and root features; eye rules; repeat feature requests); all fixed. A4 must call `forgetFeaturesRequest` on a failed fetch. |
| A4 Flutter integration | merged 20 Nov | #391 | strongest | One send-back (raw ids at root, session-hidden after focus, status fallback, Edit Alone depth, error handling). Owner device check: row select doesn't highlight in the viewport, Hide / Isolate on a sub-assembly don't reach its children, grouping switch too big, wants zoom to selection: follow-up A4.1 (#392, merged 21 Nov). Owner re-checked on phone and desktop. |
| A5 VR adoption | merged 20 Nov | VR #96 | mid-tier | One send-back (a Part-not-found 404 forced the old per-level reads for good; Fix/Float icon stale; null children crashed); all fixed. 36/36 vectors. Render check (Xvfb/Mesa, 8 scenarios) as expected; found an intermittent stale tree after Float and clipped state hints: follow-up A5.1 (VR #98, merged 20 Nov after one send-back), render check script in VR `tools/assembly_tree_render_check/` (VR #97). Owner headset check done. |

**Phase A closed 21 Nov 2026.** Every chunk needed one send-back; the owner's device checks found what review could not
(row → viewport highlight, Hide / Isolate reaching a sub-assembly's children, the grouping switch's size, zoom to selection).

## 10. Phase B: implementation briefs

Phase B is #5 (Focus and Edit Alone context), #9 (phone portrait sheet), #10 (collapse all, expand to selection, remembered
state), #8 (search and filter) and, added by the owner on 21 Nov, the build tree on the one tree (P1-P3, 10.6). It runs as Phase A did (section 9): a manager hands out these briefs, checks results and
keeps 10.7; workers build one chunk each. This section is the source of truth for Phase B; where it says "as 9.x", that
subsection applies with `A` read as `B`.

**VR is in Phase B**, in three small chunks: a faster row build (B6), search and remembered state (B7), and the world tree's
room context plus the row-hint order (B8). The room's own docked tree, with its context strip, stays with VR T2 in Phase C
(section 7). The room console already says "Placed N times: editing it here changes all of them", so VR's "used N x" exists.

### 10.1 Order and gates

```
B1 contract additions (DIDSA-CAD: spec 11-13 + reference + vectors v2)
 ├── B2 Flutter #10 + #8 ──> P1 live part (model, view) ──> P2 Part lens ──> P3 sketcher, old panel gone
 │     ──> B3 Flutter #5 ──> B4 Flutter phone sheet ──> B5 Flutter phone deep trees
 └── B7 VR #10 + #8 (also after B6)
B6 VR row build (no dependency; can start now) ──> B7 ──> B8 VR room context and row hints
```

- A chunk starts only after the chunks it depends on are **merged to `main`**, and starts from `main`.
- The Flutter chunks run one at a time (all of them touch `part_screen.dart`); the VR chain runs alongside.
- VR #97, the A5 render check, merged 21 Nov as `tools/assembly_tree_render_check/assembly_tree_render_check.gd` (its PR
  first had it as `tests/e2e_assembly_tree_render.gd`); VR workers run it from there.
- **Owner device checks** after every user-facing chunk: B2 (phone and desktop), P2 (the Part lens on desktop and
  phone: a part opened alone, and a part focused inside an assembly), P3 (the sketcher's tree, convert pick), B3 (desktop, and a tablet or a phone in
  landscape), B4 and B5 (phone portrait), B6, B7 and B8 (headset). B1 has none.

### 10.2 Contract additions (B1; fixed once B1 merges)

B1 adds three sections to `docs/assembly-tree/spec.md` and new case kinds to the vectors, so Flutter and VR filter, restore
and draw the live part the same way. In sections 1-10 only additions: the new row kinds in section 7's list and the new keys in
section 8's table. The endpoint does not change, and the 36 existing cases stay as they are. After B1 merges, changes go through the manager, as 9.2 says.

**Spec section 11, Filter (#8).** Input: a query string, plus everything section 7 takes. Output: rows and `unknown`.

- **Parsing:** split on whitespace. A word starting with `:` is a token; any other word is a name term. Case does not matter.
  An empty query (or only spaces) means no filter: section 7's rows.
- **Tokens:** `:missing` (state `missing`); `:errors` (state `missing`, `cycle`, `broken` or `over_constrained`: the bubble's
  `error` set); `:warnings` (state `near`); `:unsaved` (state `unsaved`); `:fixed` (the `fixed` flag, whatever the state);
  `:hidden`; `:suppressed`; `:parts` (kind `part`); `:assemblies` (kind `assembly`). `:mates` waits for Phase C (mates are not
  rows yet). An unknown token is left out of the matching and listed in `unknown` (in query order,
  lower case), so a client can say "unknown filter :foo".
- **Which rows can match:** every occurrence row at any depth, whatever the open keys; feature rows only where features were
  fetched (a client cannot find features it has not read; it says so in the filter's hint). Group rows, folders and the root
  never match themselves.
- **A row matches** when its `label` contains every name term (substring, so `<2>` finds instance 2) and it meets every known
  token (AND).
- **Listed:** the root; every match; every ancestor of a match: occurrence rows and, with grouping on, the group row a match
  or an ancestor sits in. Order and depth as section 7. Folders are not listed while a filter is on. Each row gains
  `match` (true / false; the root false). A listed row is `open` when something below it is listed; a match with nothing
  listed below is `open: false` (its `expandable` as usual). Bubbles follow section 6 with these `open` values.
- **The filter does not change the open keys.** Clearing it gives section 7's rows for the same open keys. Opening or closing
  a row while a filter is on is not offered (the chevron is inert). Selecting a row and then clearing the filter reveals it
  (section 8).
- **Without `status`,** `:errors` and `:warnings` can only find what section 5 lists for that case; a client says the status
  is still loading.

**Spec section 12, Remembered open rows (#10).**

- **What is stored:** the open keys (section 8) of one document's tree, per document, in the client's own storage. Which
  document key a client uses (file path, cloud project and path) is the client's choice; the stored keys are the spec's.
  At most 2,000 keys; beyond that, keys are kept in visible-row order (everything open) and the rest dropped.
- **Restore** (opening a document, and the existing refresh rule of section 8): keep a stored key when it names a row of the
  new tree that can open, under **either** grouping setting (so switching grouping off and on loses nothing); drop the rest.
  Feature keys are never open keys. Output in visible-row order with everything open, so it is deterministic.
- **Collapse all** empties the open keys (the root stays open). **Expand to selection** adds section 8's reveal keys for the
  selected path. Both are stored.
- Restoring does not move the camera or change the selection. Edit Alone's re-rooted tree (B3) is not stored: it starts with
  its root open and reveals the selection.

**Spec section 13, the live part (the build tree).** One row at a time is the live part (10.6, "The build tree").

- **Inputs** (besides section 7's): the live row's key (`""` for a part opened alone); its features in build order, each with
  `id`, `label`, `type` and the state flags `lost_reference` (with a reason), `moved_reference`, `pending_detail`,
  `rolled_back`, `hidden`; its bodies, surfaces and curves (`id`, `label`, `hidden`); its default planes' hidden flags.
- **Rows under the live row**, after anything section 7 already lists under it (its child occurrences; at the root, also the
  Mates and Patterns folders): the folders, then its features in build order (replacing the Phase A feature rows of that
  row). Folders in order `bodies_folder`, `planes_folder`, `surfaces_folder`, `curves_folder`; each shown only when it has
  something in it, `planes_folder` always; all collapsed by default; `count` = items. Inside: `body` / `surface` / `curve`
  rows; in Planes the three `default_plane` rows (XY, XZ, YZ) then the plane features (`type` `create_plane`), which also stay
  in the build order.
- **Keys** (all under the live row's key `K`, as section 8 writes them): folders `K#bodies`, `K#planes`, `K#surfaces`,
  `K#curves`; `K#body:<id>`, `K#surface:<id>`, `K#curve:<id>`; default planes `K#plane:xy` / `xz` / `yz`; a plane feature in
  the Planes folder `K#plane:<feature id>` (its build-order row keeps `K#feature:<id>`). B1 confirms that a feature id can
  never be `xy`, `xz` or `yz`.
- **When a row becomes live** its key is added to the open keys (it shows open); the user can close it.
- **The feature state slot,** one per row, most severe first: `lost_reference` (red), `moved_reference` (amber),
  `pending_detail`, `rolled_back` (dimmed), `hidden` (eye-off), else `none`. Body / surface / curve rows: `hidden` or `none`.
  Folders never carry a state or bubble.
- **Filter (section 11) on these rows:** feature, body, surface, curve and plane rows can match (by label); `:errors` also
  matches `lost_reference`, `:warnings` matches `moved_reference`; `:hidden` matches hidden features, bodies, surfaces,
  curves and planes; new tokens `:features` (any feature row) and `:sketches` (`type` `sketch`). Folders never match, but a
  match inside one lists the folder (open), as a group is listed.
- **Remembered rows (section 12):** folder keys can be open keys; feature, body, surface, curve and plane keys never are.

**Vectors, version 2** (B1 has not started, so everything is one version): new case kinds `filter` (section 7's inputs plus
`query`; `expected`: `{rows, unknown}`), `restore` (inputs `stored`, `grouping`; `expected`: the kept keys), and, with the
live-part inputs added, `live_part` (`expected`: rows), `live_part_filter` and `live_part_restore`. All generated by
`tools/assembly_tree_vectors/`, never by hand. A client's vector test runs every kind it implements and **fails on a kind it
does not know**, except where its chunk says to skip one by name until a later chunk. B1 updates
`client/test/assembly_tree_model_test.dart` only to skip the five new kinds by name; B2 removes the skip of `filter` and
`restore`, P1 of the three `live_part` kinds. VR keeps its v1 copy until B7 copies v2; B7 implements `filter` and `restore`
and skips the `live_part` kinds by name (VR's BUILD tab adopts section 13 in Phase C, with T2).

### 10.3 Every worker

As 9.3, plus what Phase A taught (and section 11, which applies to every phase):

- **PR title** `Tree B<n>: <summary>`; body as 10.4.
- **Background answers:** any request whose answer can land after a newer edit, a newer request or a different document
  (tree, status, features, a restore on open) must drop stale answers with a token or sequence number, and a test must
  deliver a late answer and show it dropped. (A4, A5 and A5.1 each found one.)
- **Keep the contract's behaviour:** status is off by default; structure first, status in the background; the states as
  given, `cycle`, `near`, `fully_constrained` and `status_failed` included.
- **Screenshots where a render is possible:** Flutter through `tools/gui_harness/` (Linux release build under Xvfb; see its
  README), VR through `tools/assembly_tree_render_check/` (Xvfb + Mesa against a live backend). Put them in the PR. A Mesa or
  Xvfb render is not a phone or the headset; say which you have.
- **Repo rules that tripped Phase A:** DIDSA-VR test registration (`tests/run_all.sh`, a row in `tests/README.md`,
  `tests/e2e_ci_list.txt` for live-backend tests); generated vectors are never edited by hand.

### 10.4 Report format

As 9.4 with `Chunk: B<n>`, plus one line before "Not verified":
`Screenshots: <files or links, what renderer, or "none possible: why">`.

### 10.5 Manager checks before merging

As 9.5, plus: run `/code-review` on the PR **and again on every fix round** before saying merge (A4's unchecked fix round
needed a follow-up); after a user-facing chunk merges, give the owner the device check from 10.1 with what to try.

### 10.6 The briefs

#### B1. Contract additions: filter, restore, the live part (DIDSA-CAD)

**Suggested model:** strongest. **Size:** S-M. **Depends on:** nothing (Phase A merged).

**Build:** spec sections 11, 12 and 13 as 10.2 sets them, plus the additions to sections 7 and 8, (worded for a client author who never reads the backend); the filter
restore and live-part functions in `tools/assembly_tree_vectors/reference.py`, their tests in `test_reference.py`, the generator
writing `version: 2` with the new cases; `vectors.json` regenerated. Cases at least: a name term deep in a collapsed branch
(ancestors listed open); a match inside a group (group row listed); two name terms (AND); `<2>`; each token; a token plus a
name; an unknown token; `:errors` with and without status; a fetched and an unfetched feature; an empty query equal to
section 7; restore with a deleted row, a group key with grouping off, a key of a row that can no longer open, a feature key.
Live part: a part opened alone (empty folders hidden, Planes always); the live part three levels down in an assembly; every
feature state, and two states on one feature (the most severe wins); a filter on a lost reference inside a collapsed live
part; a filter match inside Bodies; `:sketches` and `:features`; restore with a folder key and with a feature key.
The skip in `client/test/assembly_tree_model_test.dart`.

**Done when:** `test_reference.py` passes and fails when `vectors.json` differs from the generator; the 36 v1 cases are
byte-for-byte as before apart from `version`; `flutter test test/assembly_tree_model_test.dart` passes; the vectors workflow
is green.

**Don't touch:** the endpoint, spec sections 1-10 beyond the additions to 7 and 8, client code (other than the skip),
DIDSA-VR.

#### B2. Flutter: remembered state, expand to selection, search (#10, #8) (DIDSA-CAD `client/`)

**Suggested model:** strongest (it reaches `part_screen.dart`). **Size:** M. **Depends on:** B1.

**Build:**
- `AssemblyTreeModel`: `filteredRows(query)` (spec 11) and `restoreOpenKeys(stored)` (spec 12), passing the new vectors;
  remove B1's skip of `filter` and `restore` (the `live_part` kinds stay skipped until P1).
- `AssemblyTreeView` header: a filter field (an icon that opens it on a phone, a box on desktop; Esc / clear closes it) with
  the hint "Name, or :errors :missing :hidden ..."; an `unknown` note; matches marked, ancestors plain; "Expand to selection"
  next to collapse all (and in the row menu). Keep the header one line on a phone (the A4.1 lesson: no oversized controls).
- `part_screen.dart`: store open keys per document (`ViewPreferences` or a small store beside it, keyed by the document's
  file / project identity), restored when the tree first arrives; collapse all and expand to selection stored. A tree
  answer for an earlier document, or one landing after the user already opened or closed rows, must not overwrite them.

**Done when:** model tests pass every v2 vector; view tests: the filter lists a deep match with its ancestors and clearing
it restores the rows, an unknown token shows its note, expand to selection opens a 4-deep path and scrolls; `part_screen_test`
"Assembly tree" adds: open keys survive a reopen, a stale tree answer for the previous document is dropped, a user
collapse before the tree arrives is kept, collapse all is stored. `flutter analyze` clean, whole `flutter test` passes.

**Don't touch:** the contract, Focus / Edit Alone (B3), the phone sheet (B4), the Part lens / `FeatureTreePanel` (P1-P3).

#### The build tree (P1-P3): the owner's decisions and the target

Added 21 Nov 2026 from `docs/assembly-tree/build-tree-briefs.md` (now a pointer to here). The owner's answer 1 (section 8) is
**one tree**, but no phase owned the build tree: the Part lens and the sketcher still draw the old `FeatureTreePanel`
(`client/lib/viewport3d/feature_tree_panel.dart`, about 1,370 lines). P1-P3 go after B2 and before B3, so that B3-B5 are
built once, for one tree.

**Owner's decisions (21 Nov 2026):**

1. **The Part lens inside an assembly shows the whole tree.** The assembly tree stays, dimmed outside the focus as B3 builds it,
   with the focused part's row open to its folders and features. The lens switches the toolbars, not the tree. A part file
   opened on its own shows the same widget with the part as the root.
2. **Tapping a feature row selects it**, the same as an assembly row: it highlights what the feature made in the viewport and
   shows the bar. **Edit** is in the bar, on a double-tap (touch) and on a double-click (desktop); the right-click /
   long-press menu still has it. This replaces today's tap, which opens the edit panel and rolls back.

**Target behaviour:**

- **One widget everywhere.** `AssemblyTreeView` draws the Assembly lens, the Part lens and the sketcher's read-mostly tree.
  `FeatureTreePanel` goes in P3; `EditAloneRow` goes in B3 (after P3 it is used only by `AssemblyTreeView`).
- **The live part** (spec 13): the root when a part is opened on its own, or the focused part's row in the Part lens inside an
  assembly. Only its rows are editable, pickable and carry the full feature state. Feature rows under other parts stay as
  Phase A made them: read-only names (editing them in context is #13, Phase C).
- **Under the live part, in today's order:** the folders **Bodies**, **Planes** (the three default planes, then the plane
  features), **Surfaces** and **Curves**, collapsed, each shown only when it has something in it (Planes always); then its
  **features in build order** (plane features included, as the old panel lists them in both places). Bodies, surfaces and
  curves come from `GET /mesh`, as today.
- **Feature row:** the type icon (the existing SVGs, `feature_tree_panel.dart`'s icon map), the name (`featureDisplayName`),
  one state slot: lost reference (red; the reason in the tooltip and the bar) > moved or held reference (amber) > waiting for
  detail (the LOD pending marker) > after the rollback point (dimmed) > hidden (eye-off). The LOD "pin to coarse" control
  leaves the row (see P1).
- **The bar** (phone; desktop keeps the right-click menu and the double-click): feature rows **Edit**, **Roll back to here**,
  **Hide / Show**, **More** (Delete with today's cascade confirmation, Pin to coarse where it applies, anything else the old
  row menu had). Body / surface / curve rows: **Hide / Show**, **Zoom**, More. Default planes: **Show / Hide**; their tap opens
  the plane sheet, as today.
- **Picker modes are rules in the model**, not separate widgets: each row is *pickable / picked / locked (with a reason)*;
  while a picker is open its banner replaces the bar. Modes: the sketch picker for a pending Extrude; the Mirror / Pattern
  source multi-picker; convert pick in the sketcher (`TreeConvertPick`: earlier sketches pickable, later ones locked with the
  reason); the sketcher's read-mostly lock (`lockedReason`). Multi-select (long-press) keeps its header.
- **Search and remembered rows** (B2) work on the live part too; all its features are fetched, so all can match.

#### P1. Live part in the model and the widget (DIDSA-CAD `client/`)

**Suggested model:** mid-tier; the strongest if B2's report flags trouble in the model or the view. **Size:** M.
**Depends on:** B2.

**Build:**
- **`AssemblyTreeModel`** (`client/lib/assembly/assembly_tree_model.dart`):
  - the live-part inputs (`setLivePart(key, ...)` with features and their state flags, bodies, surfaces, curves, plane
    features) and spec 13's rows, kinds, keys and state slot, passing the `live_part`, `live_part_filter` and
    `live_part_restore` vectors (remove B1's skip of them). The live part's features replace what `setFeatures` gave that row;
    other rows keep `setFeatures`.
  - picker rules: `setPicker(...)` giving each row a pickable / picked / locked-with-reason flag on `AssemblyTreeRow`.
  - multi-select: the view's `selectedKeys` / `onMultiSelectToggle(row)` work on **row keys** (spec 8 and 13). Part screen's
    multi-select state uses `TreeMultiSelectKeys` (`tree_multi_select_controller.dart`: `feature:<id>`, `body:<id>`, ...),
    which are not row keys; add a pure mapping both ways (on the model or in that file) for P2 to use. Don't change
    `TreeMultiSelectKeys`' format.
- **`AssemblyTreeView`** (`client/lib/viewport3d/assembly_tree_view.dart`):
  - folder, feature, body / surface / curve and plane rows, icons from the existing feature SVGs, one state slot;
  - the feature, body and plane bars, as callbacks in the view's existing style: reuse `onHideSelected`, `onZoomSelected`,
    `onMoreSelected`; add `onEditSelected` and `onRollbackSelected`;
  - `onRowEdit(row)`, raised by a double-tap and a double-click (there is no `onEdit` today); `onRowTap` stays select-only;
  - the picker banner in place of the bar while a picker is open; the multi-select header (`multiSelectHeader`) for feature
    rows;
  - the coarse pin: a More action everywhere and, on desktop, a pin column that is off by default. There is no Columns menu
    yet (#15, Phase C); its switch is an icon toggle in the desktop header like the grouping toggle, saved in
    `ViewPreferences`, and moves into the Columns menu in Phase C.

**Done when:** model tests pass every `live_part*` vector; view tests: a part opened alone draws its folders and features in
order; a tap selects and does not edit, a double-tap edits; a lost reference shows red with its reason in the bar; Roll back
to here fires; in sketch-picker mode ineligible rows are locked and the banner shows; the source multi-picker ticks rows; the
sketcher lock shows its reason; long-press multi-select; the desktop pin column and its toggle; the multi-select key mapping
round-trips. `flutter analyze` clean.

**Don't touch:** `part_screen.dart`, `feature_tree_panel.dart`, the contract.

#### P2. The Part lens on the one tree (DIDSA-CAD `client/`)

**Suggested model:** strongest (`part_screen.dart` is about 30,000 lines; the riskiest chunk of the overhaul). **Size:** L.
**Depends on:** P1.

**Build:**
- **`part_screen.dart`:** `_buildFeatureTreePanel` (docked pane and phone panel) draws `AssemblyTreeView`:
  - a part opened alone: the root is the part, live;
  - inside an assembly: the whole tree, the focused part live and open;
  - switching lens changes the toolbars and which row is live, and keeps the tree, its open rows, the scroll position and the
    selection.
- **Wiring:** every `FeatureTreePanel` input moves to the new tree or is listed as dropped, with the reason:
  - `onFeatureTap` / `onFeatureLongPress` / `onFeatureContextMenu`, and the body, surface and curve tap / long-press /
    context-menu callbacks;
  - `onReferencePlaneTap` (opens the plane sheet) and `onReferencePlaneVisibility`;
  - the hidden sets and lost / moved references; pending detail and `onToggleCoarsePin`;
  - `onSketchPicked` (Extrude's sketch picker), `onFeaturePickerToggle` (Mirror / Pattern source), `onMultiSelectToggle`
    and the multi-select header (through P1's key mapping);
  - `editAloneLabel` / `onEditAloneDone` (to the view's own inputs of the same names; B3 replaces them with the strip);
  - the resize handle and the docked / overlay layouts.
- **Tap now selects.** `_onFeatureTap`'s edit-and-rollback flow moves to the bar's Edit, the double-tap and the menu. A tap
  selects the feature and highlights what it made through the existing highlight path. A body or face picked in the viewport
  reveals and marks its feature row (the producing feature, through `baseFeatureId`).
- Background answers (mesh, features, the tree) follow 10.3's stale-answer rule across lens switches and focus changes.

**Done when:**
- The PR has a table of every `FeatureTreePanel` input: where it went, or why it was dropped. Reordering features by drag:
  if a reorder exists anywhere, it is listed there.
- `part_screen_test` gets a "Build tree" group: a part opened alone shows the folders and features; a tap selects and
  highlights and opens no panel; Edit from the bar opens the panel at the rollback point; double-tap edits; Hide on a feature
  and on a body; a default plane's tap opens the plane sheet; Extrude's sketch picker and Mirror's source picker through the
  tree; multi-select delete; lens switching keeps the open rows and selection; inside an assembly the Part lens shows the
  whole tree with the focused part live; a late features answer after a focus change is dropped.
- `feature_tree_panel_test.dart` and `feature_tree_reference_planes_test.dart` cases moved to the new tests or retired with a
  reason; `tree_context_menu_test.dart` and `tree_multi_select_controller_test.dart` still pass (they import the old panel).
- `tools/gui_harness/` screenshots on desktop and at phone size. `flutter analyze` clean, whole `flutter test` passes.

**Don't touch:** the sketcher's tree (P3), the contract, B3 to B5 work (focus dimming, the strip, the phone sheet).

#### P3. The sketcher's tree, and retiring the old panel (DIDSA-CAD `client/`)

**Suggested model:** mid-tier. **Size:** M. **Depends on:** P2.

**Build:**
- `_buildSketchTreePanel` (`part_screen.dart`; the sketcher gets it through `TreeConvertPickScope`) draws `AssemblyTreeView`
  in its read-mostly lock (`lockedReason`), with convert pick (`TreeConvertPick`: earlier sketches pickable, later ones
  locked with the reason, the picked ones ticked) and its visibility toggles (`onToggleVisibility`).
- Delete `feature_tree_panel.dart`. Move what other files still import to `client/lib/viewport3d/feature_tree_helpers.dart`:
  `featureDisplayName` (imported by `assembly_tree_model.dart`), the feature icon map, `TreeConvertPick` and
  `TreeConvertPickScope` (imported by `sketch/sketch_screen.dart`), and whatever `part_screen.dart` and the tests still use.
  Today's importers: `assembly_tree_model.dart`, `part_screen.dart`, `sketch/sketch_screen.dart`; tests
  `feature_tree_panel_test`, `feature_tree_reference_planes_test`, `part_screen_test`, `sketch_convert_picks_test`,
  `tree_context_menu_test`, `tree_multi_select_controller_test`.
- `edit_alone_row.dart` stays: `AssemblyTreeView` still uses it until B3.

**Done when:** tests for the sketcher's tree (rows locked with the reason, convert pick ticks an earlier sketch and refuses a
later one, visibility toggles) replace what `sketch_screen_feature_tree_test.dart` and `sketch_convert_picks_test.dart`
cover for the old panel; no file imports `feature_tree_panel.dart`; screenshots of the sketcher's tree; `flutter analyze`
clean, whole `flutter test` passes.

**Don't touch:** the contract, VR, B3 to B5 work.

#### B3. Flutter: Focus and Edit Alone context (#5) (DIDSA-CAD `client/`)

**Suggested model:** strongest. **Size:** M. **Depends on:** P3.

After P2, Edit Alone on a part lands in the Part lens, which is the same tree, so the strip and the re-rooting below hold in
both lenses (a part's Edit Alone: the part at the root, live). B3 deletes `edit_alone_row.dart` (P3 left
`AssemblyTreeView` its only user).

**Build** (section 4; desktop and side-panel layouts; phone portrait gets its form in B5):
- **Make Focus keeps the whole tree** from the root (it swaps the tree to the focused Part today): rows outside the focused
  branch dimmed (as the viewport fades them), a rail in the assembly-lens colour beside the focused branch, the focused row
  revealed. Tapping a dimmed row selects it and offers "Focus here" (pops or pushes `AssemblyFocusStack` to that path).
- **Breadcrumb strip** above the tree: every level of `AssemblyFocusStack`'s label path; a crumb pops to that depth. It
  replaces the one-level "back" label; the root crumb is the root row (rule 5: not drawn twice).
- **Edit Alone re-roots the tree on the target**: one strip "Editing <name> [Done]", a read-only line "in Rover > Mast"
  (each crumb leaves Edit Alone at that level) and "used N x" when the target's Part is placed more than once. It replaces
  `EditAloneRow` and the separate root row, in the Assembly and the Part lens. Not stored (spec 12).
- Focus changes while a tree or status answer is in flight: the late answer is dropped or applied to the right root.

**Done when:** `part_screen_test` covers: Focus on a nested row keeps the root's rows, dims the outside, rails the branch;
a crumb pops two levels; "Focus here" from a dimmed row; Edit Alone shows only the target's subtree with "in ..." and
"used 2 x"; a crumb in the Edit Alone line leaves Edit Alone at that level; Edit Alone on a part shows the strip in the Part lens; a late answer from before a focus change is
dropped. Desktop screenshots of Focus and Edit Alone from `tools/gui_harness/`. Analyze and the whole suite pass.

**Don't touch:** the contract, the phone portrait layout (B4, B5), VR.

#### B4. Flutter: phone portrait sheet (#9) (DIDSA-CAD `client/`)

**Suggested model:** strongest. **Size:** M. **Depends on:** B3.

**Build** (sections 5 and 8.2; phone portrait only, landscape and tablets keep the side panel):
- The tree as a bottom sheet with three heights: **peek** (the header and the selected row with its bar), **half**, **full**;
  the root row becomes the sheet title. Rows 48 dp, no buttons. It drops to peek when a tool panel opens and comes back after.
- **One selection surface per layout.** Today a selected top-level row on a phone shows both the old
  `AssemblyComponentSelectionDrawer` and the new selection bar. In portrait the sheet's peek with its bar is the only one:
  the drawer does not open, for tree selections or viewport picks. Every drawer action must land in the bar or More
  (Hide, Isolate, Focus, Zoom, Alone; More: Fix / Float, Move / Rotate, Colour, Rename, Mate, Pattern, Delete; feature rows:
  Edit, Roll back, Hide). The PR lists each drawer action and where it went. In landscape / tablet the drawer stays and
  gains what only the bar had (Zoom, Alone), and the tree there shows no bar.
- The filter field (B2) sits in the sheet header; opening it goes to full.
- The sheet is the one tree, so it holds the Part lens's tree too (P2): feature, body and plane rows get their bars in the
  peek like any row.

**Done when:** widget tests: the three heights and the drag between them; a viewport pick shows the peek, not the drawer; a
tool panel drops it to peek; every listed drawer action reachable from the bar or More; landscape shows the drawer and no
bar. Screenshots at a phone portrait size (gui_harness window sized, e.g., 390 x 844) of peek, half, full. Analyze and suite.

**Don't touch:** the contract, deep-tree behaviour and Focus in portrait (B5), the desktop tree.

#### B5. Flutter: phone deep trees and Focus in portrait (#9, #5) (DIDSA-CAD `client/`)

**Suggested model:** mid-tier. **Size:** S-M. **Depends on:** B4.

**Build:** in the portrait sheet: ancestors pin to the top while scrolling (like contact-list headers) and tapping one
collapses back to it; indent capped at 4 levels (12 dp each), deeper rows stop moving right (the pinned chain shows where
you are); under Focus, rows outside the focused branch are not shown: they reduce to the pinned ancestor chain (8.3).

**Done when:** widget tests: a row 7 deep has the indent of depth 4; scrolling a long branch keeps its ancestors pinned and
a tap on one collapses to it; under Focus the outside rows are absent and the chain is shown; `reveal` still scrolls to
the right row with pinned headers in the way. Screenshots of a 7-deep tree. Analyze and suite.

**Don't touch:** the contract, the desktop / side-panel tree.

#### B6. VR: build only the rows on screen (DIDSA-VR)

**Suggested model:** mid-tier. **Size:** S-M. **Depends on:** VR #97 merged.

**Why:** the window builds every row of an open level (about 0.4 s for 2,000 rows on a CPU renderer), a frame hitch in a
headset; B7 makes big lists more frequent (a restored open set, a filter listing many matches).

**Build:** in `scripts/assembly_tree_window.gd`, a fixed row height and a pool of row controls reused as the list scrolls
(only the visible rows plus a margin exist); selection, the pulse, reveal (scroll to the row), the bottom bar and refresh in
place behave as before. Measure before and after: building and scrolling 2,000 rows, headless and on Mesa.

**Done when:** a new headless test shows a 2,000-row open level creates no more than the pool's controls and that reveal
of a row 4 deep scrolls it into view; the render check's eight scenarios still pass; the timing before / after is in the PR.
`tests/ci.sh` clean; tests registered.

**Don't touch:** the model's rules, rooms, the design table's PARTS tab, DIDSA-CAD.

#### B7. VR: remembered state, expand to selection, search (#10, #8) (DIDSA-VR)

**Suggested model:** mid-tier. **Size:** M. **Depends on:** B1, B6.

**Build:** copy vectors v2 into `tests/fixtures/assembly_tree_vectors.json` (source commit in `tests/fixtures/README.md`);
`occurrence_tree_model.gd` gets `filtered_rows` (spec 11) and `restore_open_keys` (spec 12). The window header gets a search
button that opens the popup keyboard (`main.open_keyboard_for`), the query shown under the title with a clear button;
"Collapse" and "To selection" buttons; open keys stored per document in user settings (`app_settings.gd`, its own section),
restored when the tree first arrives, with the stale-answer rule (`_refresh_token` / `_mutation_seq` are the precedent).

**Done when:** `tests/occurrence_tree_model.gd` passes every v2 `rows`, `reveal`, `filter` and `restore` case and skips the
`live_part` kinds by name (10.2); `tests/occurrence_tree_actions.gd` adds a filter,
clearing it, collapse, to selection, and a restore after reopening (with a late answer for the old document dropped);
`tests/e2e_assembly_tree.gd` restores open rows across a reopen against a live backend; render-check screenshots of a
filtered tree. `tests/ci.sh` clean; tests registered.

**Don't touch:** the contract, rooms, DIDSA-CAD.

#### B8. VR: room context in the world tree; row-hint order (#5) (DIDSA-VR)

**Suggested model:** mid-tier. **Size:** S. **Depends on:** B7.

**Build:**
- While a room is open, the world tree dims every row outside it: rows that are a placement of the room's Part (rooms are per
  Part, `room_manager.is_open_for`) and the rows below them stay full, the rest dimmed; the room's rows get the rail. The
  bottom bar for a room row keeps "Placed N times" from the console.
- **Row-hint order** (the owner's question from A5.1). Proposed: a problem state's word (`missing`, `cycle`, `broken`,
  `over`, `near`) stays first; otherwise `suppressed` comes before the state word (a suppressed part is not solved, so its
  state means little), and the rigid-set note before `under n` / `full` / `fixed`; `hidden` last. The bottom bar keeps the
  full reasons. *Confirmed by the owner, 21 Nov.*

**Done when:** headless tests for the dimming (two placements of the room's Part both full; a sibling dimmed; closing the room
undims) and the hint order on a narrow row; render-check screenshots. `tests/ci.sh` clean; tests registered.

**Don't touch:** the contract, the room's own tree (Phase C, T2), DIDSA-CAD.

**Left for later:** the room's docked tree and its context strip (Phase C with T2); `:mates` (Phase C, when mates are rows);
storing Edit Alone's open rows.

### 10.7 Progress

| Chunk | Status | PR | Model used | Notes |
|---|---|---|---|---|
| B1 contract additions | merged 21 Nov | #397 | mid-tier | Two send-backs. The `#` occurrence-id guard the manager asked for was removed (it broke Undo for a hand-edited id); spec 8 says such ids give undefined results. Planes-folder keys always `K#plane:feature:<id>`. 102 cases, the 36 v1 cases unchanged. |
| B2 Flutter #10 + #8 | merged 21 Nov | #398 | strongest | Four rounds (the per-document key). Left for B2.1: rows opened before the first answer on a never-stored document are not stored; a rename during the first load can store rows not shown. Owner device check pending. |
| P1 live part (model, view) | merged 21 Nov | #400 | strongest | Fix round merged before the manager's check; a post-merge review found model issues (auto-open key, restore, stale live selection, folders closed on clear): fixed in P2's round. |
| P2 Part lens on the one tree | merged 24 Nov | #401 | strongest | Three rounds. Round 1 fixed the send-back (live folders, previous Part's features, surface picks, ticks, superseded refresh, P1's model items) but brought in three regressions (a failed mesh hid the features, a moved live row kept its selection, a superseded call swallowed the newer error); round 2 fixed them. Round 2's review found only rarer cases: carried into P3 (10.8). "Roll back to here" left out until the rollback bar (#17, Phase D): owner, 24 Nov. |
| P3 sketcher's tree, old panel gone | merged 24 Nov | #404 | strongest | Two rounds (squash-merged). Manager send-back: the sketcher's fallback tree took another root's features; a mesh error that was not an `ApiException` escaped the banner. The fix brought one unreadable-answer rule to both API clients (`decodeOrUnreadable`). Owner, 24 Nov: a mate-drag commit whose 200 answer cannot be read is not retried (option A). Leftovers carried into B3 (10.8). |
| B3 Flutter #5 | merged 25 Nov | #406 | mid-tier (brief said strongest) | Two rounds. Manager send-back: with a deeper focus, a tree built from the lists (or truncated, or without the focus node) lost the focused level and its selection; the focused Part's list under the root; "used N ×" counted from a one-level tree; `<n>` lost while focused; Show outside the focus did nothing. A fallback tree rooted at the focused Part (as before B3) covers those cases. P3's four carried items done. Nits carried into B4 (10.8). |
| B4 Flutter phone sheet | merged 25 Nov | #408 | strongest | Owner-run (section 11). Self-review: `/code-review high` on the PR (7 important: a pick's peek overwrote the person's height and left an empty sheet; landscape lost the bar for nested and live rows; Pattern's source pick at peek; the filter under a held sheet; picks during a reload; the bottom inset), then `medium` on the fix commit (6 important: an open filter under a held sheet, the drag with an inset, the pick's peek across a tool and a turn, two surfaces for a Part-lens pick in landscape, a focus-level id during a reload). All fixed with a test each. P2's drawer behind the bar: fixed. B3's and P3's carried items done. Nits carried into B5 (10.8). |
| B5 Flutter phone deep trees | merged 25 Nov | #409 | mid-tier | Owner-run (section 11). Self-review: `/code-review high` on the PR (3 important: a drag on the pinned chain did not scroll the list; the chain kept a stale offset after a layout clamped it; under Focus a filter's matches outside it were dropped), then `medium` on the fix commit (2 important: the drag handler covered the whole list, a post-frame `setState` on every scroll). All fixed with a test each. B4's items 1-4 done (item 4 in part: see 10.8). Nits carried (10.8). |
| B6 VR row build | merged 21 Nov | VR #99 | mid-tier | Two send-backs (PARTS-tab scroll box, folder bubble, press guard). 2,002 rows, Mesa 943+337 ms -> 67+112 ms; PARTS tab scroll ~12 ms/frame slower (Table / Bring rebuilt per bind). Owner headset check pending. |
| B7 VR #10 + #8 | merged 22 Nov | VR #100 | mid-tier | Fix round merged before the manager's check; post-merge review found five issues: follow-up B7.1. |
| B7.1 VR follow-up | merged 24 Nov | VR #101 | mid-tier | Three rounds (squash-merged: two commit trailers named a model). Round 2's review found rarer orders of the same status-hint race and an older observer bug: carried into B8 (10.8). |
| B8 VR room context, hints | merged 24 Nov | VR #102 | mid-tier | Two rounds (squash-merged). Manager send-back: a level read in flight across a same-document re-read landed on the rebuilt row; a failed placement count read as 0 ("Not placed"). The count is now -1 when unknown, kept per row and re-read only after a change. Leftovers carried into the next VR chunk (10.8). |
| B8.1 VR follow-up | merged 25 Nov | VR #104 | mid-tier | Owner-run (section 11). B8's items 1-7 done (a test each where a bug). Item 6 decided: an unreadable count is asked again once per tree answer. New: a fainter rail (40 %) on the way to a room, and the root counts as the way (10.6 said dimmed: owner to confirm). Self-review high (1 important: no retry in the fallback) then medium (one finding acted on). |
| B2.1 Flutter follow-up | folded into C0 | | | B2's two leftovers plus whatever the owner's B2 device check finds: now Phase C's C0 (12.6) |

### 10.8 Hand-off (25 Nov): Phase B complete

From B4 on there is no standing manager session (section 11, "Owner-run chunks"). Each worker reviews its own PR, updates
its 10.7 row and this section's lists in its PR, and the owner checks CI and merges.

**In flight:** nothing. Every Phase B chunk is merged (B5 #409, B8.1 VR #104 on 25 Nov). What is left is the owner's
device checks below, then B2.1 if they find anything.

**Next:** B2.1 only if the owner's checks give it anything (10.7). Nits carried from B5's reviews, for whichever chunk next touches the sheet:
  1. The sheet's strips and banners get what is left after a hard-coded 48 dp header and 100 dp for the bar (`_sheetFrame` / body); the phone filter header or the multi-select header can differ, and an overfull set of strips is clipped (Done, Focus here can be cut off at half on a small phone). Measure instead.
  2. `_peekPixels` does not count the Focus here bar that peek now shows for a selected row outside the focus: the drag's peek snap is one row short then.
  3. With more ancestors than `maxPinned` the deepest are kept and drawn at shallower slots than they were tested for, so a kept ancestor's own row can show twice (and `_flushScroll` assumes slot `min(level, maxPinned)`).
  4. `_appliedFocusPath` is read when the load lands, not captured before the awaits; two placements of one Part focused in turn during a load can pair a tree with the other's path.
  5. A pinned row has the same inner keys (`tree-chevron:`, ...) and semantics as the list row it repeats: two rows announced.
  6. `_dropOutside` is off while filtering; clearing the filter drops them again without resetting the cached pin index (it is keyed on list identity only), and a selected match outside the focus then relies on the `selectedRow` fallback.
  7. B4 item 4 is done for the helpers (`_focusRelPath`, `_treeNamesByFullPath`, `_ownerPartIdOf`, Hide's owner); Fix, Rename, Delete and Isolate still read `_focusStack.current` as the owner and `_TreeTarget`'s fallback does too, in the window while a root change is loading.
  8. The pinned chain has no push-out animation (a row leaves when its branch has nothing left under the chain) and a flick from the chain does not fling.
  9. For the owner's device check (not bugs): a tap on a pinned ancestor on the way to the focus only selects it (closing it would hide the focus); the chain takes at most half the list; B4's open questions of the Start button, the close at peek, the peek under a tool panel and the sketcher's floating tree stay open.

**VR leftovers** from B8.1's reviews, for whichever VR chunk next touches the tree:
  1. The per-level fallback shows no way to a room below a closed row whose children are not fetched (it cannot tell a
     leaf from an assembly).
  2. `apply_theme` re-binds every pooled row (cosmetic).
  3. `session_observer._queue_doc` compares against `loaded_rev` before a model change resets it (low risk: events are
     held until the model is shown).
  4. For the owner: B8.1 shows the root row as the way to a room (not dimmed) when a room's Part is anywhere below it;
     10.6 said the root is dimmed. Confirm on the headset.

**Owner decisions:** row-hint order as proposed (21 Nov); "Roll back to here" waits for the rollback bar (#17, Phase D;
24 Nov); a mate-drag commit whose 200 answer cannot be read is not retried (option A, 24 Nov).

**Owner device checks:** all once Phase B is complete, not after each chunk. Owed so far:
B2 (phone and desktop: remembered rows, Save As, Expand to selection, filter tokens, phone header); P2 (a part opened
alone; a part focused in an assembly in the Part lens; lens switching with folders open and a row selected); P3 (desktop
and phone: the sketcher's tree beside a sketch, a convert pick from it, locked rows, the banner when the server's answer
cannot be read); B3 (desktop, and a tablet or a phone in landscape: Make Focus on a nested part with dim, rail, crumbs and
Focus here on a dimmed row; Edit Alone on a twice-placed sub-assembly and on a nested part with "in ...", "used 2 ×",
crumbs and Done); B5 (phone portrait: a tree 6 or more levels deep opened to its bottom, scrolling a long branch with the chain pinned above it, a tap on a pinned ancestor, a drag that starts on the chain, Tree > Expand to selection and a 3D pick of a deep part with the chain in the way, Make Focus on a nested part and then the rows outside it gone, the focused branch and the chain to it; indent stopping at the fifth level); B4 (phone portrait: the sheet's peek, half and full and the drag and fling between them; a 3D pick
opening a closed sheet at peek and closing it again when the selection is cleared; the bar and More for a component and
for a feature, body and plane in the Part lens; a tool panel dropping the sheet to peek and its return; the filter opening
it to full; Edit Alone's pill at peek; the bar above the home indicator; and in landscape the drawer with Zoom, the bar
only for nested components and rows tapped in the tree); B6 (headset: fast scroll, deep reveal, Fix / Float hints, PARTS tab Table and back); B7 and B7.1
(headset: Find kept after adding a component and after Save As, To selection, Collapse, remembered rows after reopening,
the "unavailable" hint); B8 (headset: rows outside an open room dimmed and the rail on the inside rows, the bar's "Placed
N times" against a real backend, the hint order on the row width); B8.1 (headset: a room on a Part placed inside a
sub-assembly: the sub-assembly and the root full with a faint rail, the placements with the full rail, the rest dimmed;
the faint rail kept when the sub-assembly is collapsed; a theme change with a room open moves the rails to the new
accent; "Placed N times" on a room row). Each worker adds its chunk's check from 10.1 here.

## 11. Running a phase: cost and process (Phases B, C and D)

Every phase from B on is run by a manager session and worker sessions, as section 9 describes. These rules were added on
24 Nov 2026, after Phase B's first chunks proved expensive in tokens. Each phase's managers follow them, and each phase's
briefs refer to them rather than repeating them.

**Manager sessions**
- **Hand over before the context grows.** When a manager session gets long, it writes a hand-off into its phase's
  section (what is in flight, what the owner owes, the next step), brings it to `main`, and the owner starts a fresh
  manager with a short prompt pointing at it. A long context is re-read on every turn; that was most of the cost.
- **Read little.** A manager reads its phase's section and the repo's `CLAUDE.md` up front, and other files only when a
  check or a brief needs them.
- **A mid-tier model is enough for a manager** once the briefs are written; use the strongest model for writing a phase's
  briefs and for its riskiest chunks.

**Reviews**
- **Workers review themselves first.** Every worker prompt says: "Run /code-review on your PR and fix what it finds
  before you reply." The manager's review is then a check, not the first look.
- **One manager review per round, sized to the round:** `/code-review` at `high` on a chunk's first PR; at `medium` on a
  fix round, limited to that round's own commits and to important findings. Always name the repo and a worktree path (a
  run started outside a repo reviewed the wrong one).
- **The manager's own checks are cheap; keep doing them:** CI, the diff stays in its chunk, generated files regenerate
  and match across repos, and a spot check of the biggest finding before passing it on.

**Rounds**
- **Send back only important findings.** Nits go into the next chunk in the same area, or a follow-up chunk
  (`<chunk>.1`).
- **Stop a send-back spiral.** When a round's important findings are rarer edge cases than the last round's, merge, and
  let the owner's device check and a follow-up decide what is left (B2 took four rounds on one document key).
- **The owner merges only on the manager's "merge", fix rounds included.** Merging an unchecked round cost a follow-up
  every time it happened (A4, P1, B7).

**Workers**
- **Mid-tier for narrow chunks**, the strongest only where a chunk is large or risky (most of `part_screen.dart`, a
  contract).
- **Every worker prompt carries these lines:** "Start from main"; "Follow section N of
  docs/assembly-tree-overhaul-scope.md; reply with the report and open the PR"; "You may commit and push to your session's
  branch and open the PR" (B1's session was blocked without it); "Run /code-review on your PR and fix what it finds
  before you reply". (A rule against model names in commits and docs was dropped on 25 Nov: the owner does not mind
  them. The cloud sessions' own instructions may still keep them out; neither a prompt line nor a check is needed.)
- **Keep prompts short:** the brief lives in the doc, and the prompt adds only what was learned since.

**Owner-run chunks** (from 25 Nov, B4 on). The manager's reviews kept finding important bugs the workers' own reviews
missed (P3 2, B8 2, B3 5), because workers reviewed at medium and only their last commit. A standing manager was the cost,
not the review, so the review moves to the worker and the manager goes:
1. The worker writes the chunk, then runs `/code-review high` on the whole PR (`origin/main...HEAD`), fixes the important
   findings, runs `/code-review medium` on its fix commits, fixes those, and updates its 10.7 row and the 10.8 lists
   (leftover nits, the device check) in the same PR. Nits go to 10.8, not another round.
2. The owner checks that CI ran and passed on the PR's head commit (a run that never started is not green), then
   merges.
3. A manager session is opened only to write a phase's briefs, for a contract or other risky chunk, or when a chunk's
   rounds stop converging; it hands off and closes.

## 12. Phase C: implementation briefs

Phase C is #7 (a Mates folder per assembly level, and the selection's mates), #13 (edit a feature in context), #12 (hover
linking), #14 (flyout tree), #15 (optional columns) and VR T2 (DIDSA-VR `docs/feature-tree-review-2026-11-11.md` R1, R4's
BUILD-tab move and R6: one tree component with scopes, the PARTS tab on it, the room's docked tree with its context strip and
"used N x"), with VR's BUILD tab adopting spec section 13. It also takes Phase B's leftovers (10.8). Written 25 Nov 2026.

It runs **owner-run** (section 11, "Owner-run chunks"): no standing manager. Each worker builds its chunk, reviews its own PR
and records its row and leftovers; the owner checks CI and merges. A manager session is opened only for C1 (a contract) or
when a chunk's rounds stop converging. This section is the source of truth for Phase C; where it says "as 9.x" or "as 10.x",
that subsection applies with `A` or `B` read as `C`.

Chunks: **C0-C5 are Flutter / contract** (DIDSA-CAD), **C6-C9 are VR** (DIDSA-VR). Section 7's VR parts of #7 and #12 are
in VR T3 (Phase D) unless the owner moves them (12.8, question 8).

### 12.1 Order and gates

```
C1 contract + Flutter model (spec 14, vectors v3; no part_screen.dart) ──────────────┐
C0 Flutter Phase B follow-up ──> C3 Flutter #13 ──> C2 Flutter #7 (after C1) ──> C4 Flutter #12 + #15 ──> C5 Flutter #14
C6 VR one tree component, PARTS tab ──> C7 VR room tree ──> C8 VR BUILD tab on spec 13 ──> C9 VR parts open to features
```

- A chunk starts only after the chunks it depends on are **merged to `main`**, and starts from `main`.
- **Flutter chunks that touch `part_screen.dart` run one at a time** (C0, C3, C2, C4, C5, in that order). C1 touches only the
  contract, the reference and `assembly_tree_model.dart`, so it runs alongside C0 or C3. The VR chain runs alongside all of
  them, one VR chunk at a time (they all touch `assembly_tree_window.gd` or what C6 splits it into).
- **C0 waits for the owner's Phase B device checks** (10.8), since it takes what they find. If they are not done when Phase C
  starts, run C3 first and C0 after it.
- **First to start:** C1, C6, and C3 (or C0 if the Phase B checks are done).
- **Owner device checks** after Phase C is complete, not after each chunk (as 10.8 settled): each worker adds its chunk's
  check to 12.8. C1 has none.

### 12.2 Contract additions (C1; fixed once C1 merges)

C1 adds spec **section 14** and vectors **version 3**, so both clients draw a Mates (and Patterns) folder under every
assembly level the same way, with mate rows that can be filtered. After C1 merges, changes go through a manager session, as
9.2 says. **The endpoint does not change** unless the owner answers question 1 the other way (12.8).

**Spec section 14, a folder per assembly level (#7).**

- **Where:** under an **open assembly occurrence row** (kind `assembly`), after its children and before its features: the
  **Mates** folder when that node's `mates.count > 0`, then **Patterns** when `patterns.count > 0` (question 2), at depth + 1.
  The root's folders (section 7 item 5) are the same rule at depth 1. Group rows and part rows have none. Folders are
  collapsed by default.
- **Keys:** the owning row's key and `#mates` / `#patterns` (section 8 already says so: `mast/arm#mates`; the root's stay
  `#mates`, `#patterns`). Folder keys can be open keys (section 12 restore keeps them when the folder still shows).
- **Bubble:** the folder carries its level's mates: `error` = `mates.broken`, `warning` = `mates.near` (as the root's folder
  today). An **open** assembly row then shows no bubble of its own (rule 5: not twice; section 6's "open occurrence row" line
  changes; question 3). A collapsed row keeps its rolled-up `problems` bubble.
- **Item rows** (kind `mate` / `pattern`, new in the spec; Flutter has them as client-only rows since A4): the client fetches
  a level's items when its folder first opens (`GET /parts/{owner part}/mates`, `/component-patterns`, the owner being the
  node's `resolved_part_id`) and passes them in, as features are passed. Input per folder key: `[{id, label, status,
  suppressed, held, lost}]` (`status` `ok` / `near` / `broken` from the listing; `held`; `lost` = `lost_references` not
  empty; patterns: `id`, `label`, `suppressed`). Keys: the folder key, `#item:` and the id (`mast/arm#mates#item:m3`, what
  Flutter writes today at the root). Item keys are never open keys.
- **Item label:** the mate naming rule, written from Flutter's `mateDisplayName` (`client/lib/viewport3d/assembly_tree_helpers.dart`:
  "Coincident 2", "Width 1", "Symmetric 1", counted per type within the level) and VR's mate names where they agree; the
  reference implements it and the vectors carry a `mate_names` case kind (input: one level's `/mates` entries; expected: the
  labels). Patterns keep `componentPatternDisplayName`'s rule, written into the spec the same way.
- **Item state slot**, most severe first: `lost` or `broken` (red) > `near` or `held` (amber) > `suppressed` (dimmed) > `none`.
  Item rows carry no bubble and cannot open.
- **Filter (section 11):** `:mates` (any mate item row) becomes a known token; `:errors` matches red items, `:warnings` amber,
  `:suppressed` suppressed items. Items match by label. Only fetched items can match (as features). A match inside a folder
  lists the folder (open) and its ancestors, as a group is listed. Folders never match themselves. Folders were not listed
  while a filter is on (B1); with this section they are listed exactly when an item in them matches.
- **Unfetched folder:** an open folder whose items are not fetched lists nothing under it (a client may show progress).

**Vectors, version 3.** New kinds `level_folders` (section 7's inputs plus `items`, folder key -> item list; expected: rows),
`level_folders_filter`, `level_folders_restore` and `mate_names`. Existing `rows`, `filter` and `restore` cases whose open
rows include an assembly with mates or patterns **change** (they now list that level's folder, and the open row loses its
bubble): C1 lists in its PR every existing case whose expectation changed, and why. All generated by
`tools/assembly_tree_vectors/`, never by hand. The Flutter model passes v3 in C1 itself (below), so `main` stays green. VR keeps
its v2 copy (C8 needs only the v2 `live_part` kinds) until the chunk that brings #7 to VR copies v3.

### 12.3 Every worker

As 9.3 and 10.3 (stale answers dropped with a test, the contract's behaviour kept, screenshots where a render is possible,
the repo's rules), plus:

- **PR title** `Tree C<n>: <summary>`; body as 12.4.
- **Owner-run:** the steps in 12.5 are part of the chunk, not optional.
- **Records:** DIDSA-CAD chunks update their 12.7 row and the 12.8 lists in the same PR. VR chunks cannot edit this file:
  they put their 12.7 row and their 12.8 text in the report, and the next DIDSA-CAD chunk to open a PR copies them in (or the
  owner does, in a small docs PR).
- **Leftovers:** a chunk that takes items from 10.8 or 12.8 marks each one done (with its test) or carried, by number.

**The worker prompt** (the owner fills in `<repo>` and `<chunk>`):

```
Start from main in <repo>. Follow section 12.6 <chunk>; reply with the report (12.4) and open the PR. You may commit and push
to your session's branch and open the PR. Process (section 11, owner-run): when written, run /code-review high on the whole
PR (origin/main...HEAD) and fix the important findings; then /code-review medium on your fix commits and fix those; nits go
to 12.8. Update your 12.7 row and the 12.8 lists in the same PR (VR chunks put that text in their report instead). Say what
you could not verify.
```

`<repo>` is `DIDSA-UK/DIDSA-CAD` for C0-C5 and `DIDSA-UK/DIDSA-VR` for C6-C9 (a VR worker reads this file from DIDSA-CAD's
`main`: `docs/assembly-tree-overhaul-scope.md`).

### 12.4 Report format

As 10.4 with `Chunk: C<n>`, plus two lines before "Not verified":

```
Review: high -> <n> important (<what>, fixed, a test each); medium on the fix commits -> <n> (fixed); nits -> 12.8
Records: 12.7 row and 12.8 text updated in this PR (VR: the row and the text, here)
```

### 12.5 The owner-run steps (section 11)

1. **Worker:** builds the chunk; runs `/code-review high` on the whole PR (`origin/main...HEAD`, naming the repo and its
   worktree path); fixes every important finding with a test where it is a bug; runs `/code-review medium` on its fix commits
   only and fixes those; puts nits in 12.8, not another round; updates 12.7 and 12.8 (VR: in the report); replies with 12.4.
2. **Owner:** checks that CI **ran and passed on the PR's head commit** (a run that never started is not green), then merges.
   Device checks wait for the end of the phase (12.1).
3. **Manager session** (mid-tier is enough; the strongest for C1): opened only for **C1** (a high review of the contract
   before merge: spec wording a client author can follow, the reference and the regenerated vectors, the list of changed
   cases), or when a chunk's rounds stop converging (section 11, "Stop a send-back spiral"). It writes its findings into 12.8
   and closes.

### 12.6 The briefs

#### C0. Flutter: Phase B follow-up (DIDSA-CAD `client/`)

**Suggested model:** mid-tier. **Size:** S-M. **Depends on:** the owner's Phase B device checks (12.1). Replaces B2.1 (10.7).

**Build:**
- 10.8's B5 sheet nits 1-8: measure the sheet's header and bar instead of the hard-coded 48 dp / 100 dp (1); count the Focus
  here bar in `_peekPixels` (2); keep pinned ancestors at their tested slots when there are more than `maxPinned` (3); capture
  `_appliedFocusPath` before the awaits (4); one semantics node per pinned row (5); reset the pin index cache when clearing the
  filter brings `_dropOutside` back (6); Fix, Rename, Delete, Isolate and `_TreeTarget`'s fallback take their owner Part from
  the loaded tree, not `_focusStack.current`, while a root change is loading (7); the chain's push-out and fling (8, optional:
  say if left).
- B2's two leftovers (10.7): rows opened before the first answer on a never-stored document are stored; a rename during the
  first load does not store rows that are not shown.
- What the owner's Phase B device checks found (the owner lists it in the prompt or in 12.8 before starting).

**Done when:** a test per bug (1-7, the two B2 items, each device-check bug); screenshots at 390 x 844 for 1-3;
`flutter analyze` clean, whole `flutter test` passes.

**Don't touch:** the contract, `assembly_tree_model.dart` (C1 owns it), Phase C features.

**Left for later:** 10.8 item 9 stays with the owner's device check.

#### C1. Contract: a folder per assembly level, mate rows, `:mates` (DIDSA-CAD)

**Suggested model:** strongest. **Size:** M. **Depends on:** nothing (Phase B merged); the owner's answers to questions 1-3.

**Build:**
- Spec section 14 as 12.2 sets it, plus the additions it needs in sections 6 (the open-row bubble), 7 (the folders' place
  and the `mate` / `pattern` kinds), 8 (item keys), 11 (`:mates`, folders listed with a match) and 12 (folder keys of any
  level). Worded for a client author who never reads the backend.
- `tools/assembly_tree_vectors/reference.py`, `test_reference.py`, `generate.py` writing `version: 3`; `vectors.json`
  regenerated. Cases at least: a folder under an open sub-assembly placed twice (two folder keys); a level with mates and
  no patterns; an open row's bubble moved to its folder; an unfetched open folder; every item state and two on one item;
  `:mates`; `:errors` matching a broken mate three levels down inside a collapsed branch (folder and ancestors listed open);
  restore with a nested folder key, an item key, and a folder whose level lost its mates; `mate_names` with Width and
  Symmetric mates.
- `client/lib/assembly/assembly_tree_model.dart` passes v3: per-level folders; `setFolderItems` takes any folder key (today
  `#mates` / `#patterns` at the root only, built from host-named `AssemblyFolderItem`s) and items carry the spec's state;
  `:mates` known; `client/test/assembly_tree_model_test.dart` runs the new kinds. `part_screen.dart` keeps compiling with the
  root's folders as today (C2 wires the rest).

**Done when:** `test_reference.py` passes and fails when `vectors.json` differs from the generator; the PR lists every
existing case whose expectation changed and why; `flutter test test/assembly_tree_model_test.dart` passes every v3 case;
`flutter analyze` clean, whole `flutter test` passes; the vectors workflow is green; the manager's review (12.5 step 3) is in
the PR.

**Don't touch:** the endpoint (unless question 1 says otherwise; then its tests in `backend/tests/test_assembly_tree.py` and the
spec's section 1), `part_screen.dart` beyond what keeps it compiling, `assembly_tree_view.dart`, DIDSA-VR.

**Left for later:** VR's copy of v3 (with #7 in VR, Phase D or question 8).

#### C2. Flutter: mates per assembly level and the selection's mates (#7) (DIDSA-CAD `client/`)

**Suggested model:** strongest (`part_screen.dart`). **Size:** M. **Depends on:** C1; C3 (one Flutter chunk at a time).

**Build:**
- **Per-level folders:** when a level's Mates or Patterns folder opens, fetch `listMates(owner)` /
  `/component-patterns` for that node's `resolved_part_id`, once per Part per tree answer (a Part placed twice shares one fetch);
  name and state them by the spec; drop stale answers (a newer tree, a document change, a mate edit). The focused level's
  `_mates` / `_componentPatterns` (`part_screen.dart`, loaded with `listMates(focusPartId)`) feed its folder, so it is not
  fetched twice.
- **Mate rows at any level:** a tap selects the mate and highlights its two components (by full path under that placement); the
  bar / menu for a mate on the focused level is today's (`_onMateTap`, `_onMateLongPress`, which run only while
  `_focusIsTreeRoot` today); a mate on another level gets **Focus here to edit** (pushes the focus to that level, then opens
  the mate as `_onMateTap` does) plus Suppress / Delete only if question 4 says so. Pattern rows the same way.
- **The selection's mates:** the component drawer (`AssemblyComponentSelectionDrawer`; it docks under the tree on desktop) and
  the phone sheet's More list the selected component's mates on its parent level (mates whose references' top occurrence is
  the component), each with its state; a tap selects that mate and reveals its row.
- The filter hint gains `:mates`; a `:mates` filter says when some levels' mates are not fetched yet (as features).

**Done when:** `part_screen_test` "Assembly tree" adds: a nested level's folder fetches once and lists its mates with a broken
one red; two placements of one sub-assembly share the fetch and each highlights its own components; a late mates answer
after a mate edit is dropped; Focus here to edit from a nested mate; the drawer lists the selected nested component's mates
and a tap reveals the row; `:mates :errors` finds a broken mate in a collapsed branch once fetched. Desktop and 390 x 844
screenshots. Analyze and the whole suite pass.

**Don't touch:** the contract, the model's rules (raise a problem in the report), VR.

**Left for later:** mates repeated under components (left out on purpose, section 6); editing a nested level's mates in place
(question 4).

#### C3. Flutter: edit a feature in context from the tree (#13) (DIDSA-CAD `client/`)

**Suggested model:** strongest (`part_screen.dart`, focus and lens state). **Size:** S-M. **Depends on:** nothing in
Phase C (runs after C0 if C0 started first).

**Build** (Phase 20 in-context editing, `docs/assembly-scope.md` section 2v, already retargets Part-lens tools through the
focused path; this chunk is the way in from the tree):
- A read-only feature row under a part that is not live (P2: `onRowEdit` is null for them today, `part_screen.dart`
  `onRowEdit: live ? _editLiveRow : null`) gets **Edit in context**: on a double-click (desktop), a double-tap (touch), in its
  bar and in its menu.
- It pushes `AssemblyFocusStack` to the part's path (each level, as Make Focus from a nested row does), switches to the Part
  lens (the part becomes live), and once that part's live features land opens the feature's panel at its rollback point, as
  `_editLiveRow` / `_onFeatureTap` do. A focus change, a lens switch or a document change before the features land cancels
  it (the stale-answer rule).
- Inside Edit Alone, a feature row under a part in the re-rooted tree does the same within Edit Alone.
- After the panel closes the focus and lens stay where they are (question 5).

**Done when:** `part_screen_test` "Build tree" adds: double-click a feature three levels down focuses its part, Part lens,
the panel open on that feature; the same from the bar on a phone; a focus change before the features land opens nothing; the
second placement of a sub-assembly focuses the second path; inside Edit Alone. Desktop screenshots of before and after.
Analyze and the whole suite pass.

**Don't touch:** the contract, the model, the Phase 20 retargeting itself, VR.

**Left for later:** VR's analogue is C9's Table action.

#### C4. Flutter desktop: hover linking and the Columns menu (#12, #15) (DIDSA-CAD `client/`)

**Suggested model:** mid-tier. **Size:** S-M. **Depends on:** C2 (one at a time; mate rows to hover).

**Build** (desktop layout only; touch gets neither, rule 4):
- **Row hover lights the part:** hovering an occurrence row lights that placement (by full path) in the viewport, a feature
  row of the live part what it made, a mate row its two components. Not through `PartViewport.highlightOverride`, which dims
  everything else for Select Other: a separate hover input that only lights. Cleared on exit; nothing while a picker or a
  drag is active.
- **Part hover lights the row:** `PartViewport` reports its hover changes (its `_recomputeHover` / `_syncHoverNode`) to the
  screen; the tree marks the hovered row, or the nearest listed ancestor when the row is collapsed. It never opens, scrolls or
  selects. Throttled so a moving pointer does not rebuild the tree each frame.
- **Columns menu** in the desktop tree header, off by default, saved in `ViewPreferences`: **Eye** (a column instead of the
  hover eye), **Colour** (the placement's colour; a click opens `occurrence_colour_sheet.dart`), **DOF** (from `constraint.dof`;
  empty while status loads), **Coarse pin** (P1's icon toggle moves here, `ViewPreferences.assemblyTreePinColumn` kept), and
  the **grouping** switch (section 8, answer 6: header or Columns menu). **Transparency** only if question 7 says so (no
  per-placement transparency exists in the client or the backend today).

**Done when:** view tests: hovering a row reports its key once and clearing it reports null; a hovered collapsed descendant
marks its ancestor; each column on and off, saved and restored; the pin setting survives the move. `part_screen_test`: a row
hover lights the second placement only and dims nothing; a viewport hover marks the row and does not scroll. Desktop
screenshots with every column on. Analyze and the whole suite pass.

**Don't touch:** the contract, the phone layouts, VR.

**Left for later:** hover in VR (question 8); Transparency (question 7).

#### C5. Flutter desktop: the flyout tree (#14) (DIDSA-CAD `client/`)

**Suggested model:** mid-tier. **Size:** S-M. **Depends on:** C4.

**Build:** while a docked tool panel holds the left pane (`_desktopFrame` hides the tree while `_desktopToolPanelOpen`), a
translucent **pick-only** tree over the viewport's top left, below the picker prompt card (`picker_ribbon.dart`) so neither
covers the other: the same model, open rows and selection as the docked tree; a row click selects, as a tree click does
today, so the open tool takes it where it takes a tree selection now; no bar, no menu, no columns, no filter (or the filter
only: say which). It opens from a small "Tree" tab (question 6), closes on Esc and when the tool closes, and the docked tree
then shows the same open rows.

**Done when:** `part_screen_test`: opening a tool panel hides the pane and shows the tab; the flyout opens with the docked
tree's open rows; a row click selects and the tool sees the selection; no menu on right-click; Esc and closing the tool close
it; it does not overlap the picker prompt. Desktop screenshots. Analyze and the whole suite pass.

**Don't touch:** the contract, the docked panel's layout (L3), the phone layouts, VR.

**Left for later:** a flyout on a phone or tablet (not planned: the sheet drops to peek, B4).

#### C6. VR: one tree component with scopes; the PARTS tab on it (T2: R1, R4) (DIDSA-VR)

**Suggested model:** strongest (it splits the 1,866-line `scripts/assembly_tree_window.gd`). **Size:** M. **Depends on:**
nothing (Phase B merged).

**Build:**
- The shared component (the review's R1): the rows, the pooled row build (B6), the bottom bar, search, remembered rows, room
  context, refresh in place and selection both ways move from `assembly_tree_window.gd` into `scripts/tree/occurrence_tree_view.gd`
  (or as R1 names them), driven by a **scope** object: World (root `main.current_root_part_id()`, nodes from
  `RoomRegistry.world_parts`, adds Room), Table PARTS (the world's root, adds Table / Bring), and Room (C7). `occurrence_tree_model.gd`
  stays the pure rules.
- `assembly_tree_window.gd` becomes the World window on it. `scripts/design_table/table_tree_window.gd`'s PARTS tab uses it:
  **Table** and **Bring** move into the bottom bar (`_uses_action_bar()` returns true; the inline `_add_row_actions` buttons
  go), and **Room** and **Delete** come back (the review's B5). The BUILD tab is untouched (C8).
- VR leftovers from 10.8: 1 (the per-level fallback shows the way to a room below a closed row whose children are not
  fetched, or says why it cannot), 2 (`apply_theme` re-binds only rows on screen), 3 (`session_observer._queue_doc` compares
  after the model change resets `loaded_rev`).

**Done when:** every existing tree test passes unchanged in meaning (`tests/assembly_tree_window.gd`, `occurrence_tree_actions.gd`,
`assembly_tree_pool*.gd`, `assembly_tree_races.gd`, `tree_b71.gd`, `tree_b8.gd`, `tree_open_settings.gd`, `design_table_tree.gd`:
say which needed a path change); new headless tests: the PARTS tab's bar offers Table / Bring / Room / Delete for a placed part
and greys Table with its reason for a sub-assembly; a test per leftover; the render check's scenarios still pass, plus a
PARTS-tab screenshot. `tests/ci.sh` clean; tests registered.

**Don't touch:** the model's rules, rooms' own tree (C7), the BUILD tab (C8), DIDSA-CAD.

**Left for later:** the review's R4 extras (Mate, Appearance, Suppress in the bar), T3.

#### C7. VR: the room's docked tree and its context strip (T2: R6, section 4) (DIDSA-VR)

**Suggested model:** mid-tier. **Size:** M. **Depends on:** C6.

**Build:**
- The room console (`scripts/room/room_console.gd`) gets a **Tree** button that opens a tree window in the Room scope, docked
  beside the console (as the table tree docks to the table) in the room's colour; it moves with the console.
- Rooted at the room's Part; rows resolve to the room's nodes (`RoomRegistry.parts_in_room`), never the world's hidden copy.
  Fix / Float, Rename and Delete write to the room's Part (as `room_edit.gd` and the room's mates already do); Hide is
  view-only (owner, 11 Nov).
- **The context strip** above it (section 4): the room's name, one read-only line "in Rover > Mast" (the placements of the
  room's Part in the world; the first one, and "+1 more" when there are several), and **"used N x"** from the console's
  `uses_text` when the Part is placed more than once. Crumbs are read-only (question 9).
- Selection both ways inside the room (a pick in the room reveals its row); its open rows remembered per room's Part, as B7's
  are per document.

**Done when:** headless tests: the room tree lists the room Part's children; a row selects the room's node, not the world's;
Fix on a room row PATCHes the room's Part; the strip shows "in ..." and "used 2 x" for a Part placed twice; a pick in the room
reveals its row; closing the room closes its tree. Render-check screenshots of a room with its tree. `tests/ci.sh` clean;
tests registered.

**Don't touch:** the contract, the BUILD tab (C8), DIDSA-CAD.

**Left for later:** crumbs that act (question 9); a room tree for nested rooms beyond what the scope gives.

#### C8. VR: the BUILD tab on spec section 13, its actions in the bottom bar (DIDSA-VR)

**Suggested model:** mid-tier; the strongest if C6's report flags trouble in the shared view. **Size:** M. **Depends on:** C7.

**Build:**
- `occurrence_tree_model.gd` implements spec section 13 (the live part): folders Bodies, Planes (the three default planes,
  then the plane features), Surfaces, Curves; features in build order; the feature state slot. `tests/occurrence_tree_model.gd`
  stops skipping the three `live_part` kinds (`SKIPPED_KINDS`) and passes them (VR's v2 copy has them).
- The BUILD tab (`table_tree_window.gd` `_redraw_build`, today its own rows over `build_tree.gd`) draws the part on the table
  as the live part through the shared view. `build_tree.gd` keeps only what the spec does not cover (summaries, LABELS) or is
  retired; say which.
- Its action strip under the selected row (`_action_strip`: Edit, Fix a reference, Lines, Hide / Show, Roll back / forward,
  Delete) moves to the bottom bar (owner, 11 Nov: one pattern everywhere). The group eyes become the folders' Hide / Show.

**Done when:** every `live_part*` vector passes; `tests/design_table_build_tree.gd`, `design_table_visibility_tree.gd` and
`e2e_build_tree.gd` pass (moved to the new rows where needed: say which); new tests: the bar's actions for a feature, a body and
a default plane; a lost reference shows red with its reason in the bar. Render-check screenshots of the BUILD tab. `tests/ci.sh`
clean; tests registered.

**Don't touch:** the contract, the vectors (copy only), DIDSA-CAD.

**Left for later:** the rollback bar (#17, Phase D).

#### C9. VR: parts open to their features in the world and room trees (#19) (DIDSA-VR)

**Suggested model:** mid-tier. **Size:** S. **Depends on:** C8.

**Build:** a part row opens to its features (read-only names from `GET /parts/{id}/features`, fetched on first open with the
stale-answer rule; spec 7 feature rows). A selected feature row's bar offers **Table**: puts that part on the table and selects
that feature in the BUILD tab (VR's analogue of #13).

**Done when:** headless tests: opening a part row fetches once and lists its features; a late answer for another document is
dropped; Table from a feature row seats the part and selects the feature. Render-check screenshot. `tests/ci.sh` clean; tests
registered.

**Don't touch:** the contract, DIDSA-CAD.

**Left for later (Phase D, VR T3):** the Mates and Patterns folders in VR (with vectors v3), laser hover, the leader line and
Frame, unless question 8 moves the first two here.

### 12.7 Progress

| Chunk | Status | PR | Model used | Notes |
|---|---|---|---|---|
| C0 Flutter Phase B follow-up | not started | | | Waits for the owner's Phase B device checks; replaces B2.1 |
| C1 contract + Flutter model | not started | | | Needs answers to questions 1-3; manager review before merge |
| C2 Flutter #7 | not started | | | |
| C3 Flutter #13 | not started | | | |
| C4 Flutter #12 + #15 | not started | | | |
| C5 Flutter #14 | not started | | | |
| C6 VR one tree component | not started | | | |
| C7 VR room tree | not started | | | |
| C8 VR BUILD tab on spec 13 | not started | | | |
| C9 VR parts to features | not started | | | |

### 12.8 Hand-off

**In flight:** nothing; briefs written 25 Nov 2026.

**Leftovers placed:** 10.8's B5 sheet nits 1-8 and B2.1 -> C0 (item 9 stays with the device check); VR leftovers 1-3 -> C6;
VR item 4 (the root as the way to a room) is the owner's, below.

**Open questions for the owner** (answer before the chunk named):
1. *C1.* A level's mates: fetched from `GET /parts/{owner}/mates` when its folder opens (recommended: no endpoint change; the
   tree answer already has the counts for the folder's chevron and bubble; `:mates` finds only fetched mates, as with
   features), or listed in the assembly-tree answer (an endpoint change; `:mates` finds every mate; bigger answers).
2. *C1.* A Patterns folder per level as well as Mates (recommended: one rule for both), or Mates only.
3. *C1.* An open assembly row's own mates bubble moves to its Mates folder (recommended: rule 5, nothing twice; changes some
   existing vector expectations) or shows on both.
4. *C2.* A mate on a level other than the focused one: select and highlight, with **Focus here to edit** (recommended: the mate
   tools work on the focused level), or also Suppress / Delete in place.
5. *C3.* After editing a feature in context, stay focused on that part in the Part lens (recommended) or go back to the focus
   and lens you came from.
6. *C5.* The flyout tree opens from a small Tree tab (recommended, closed by default) or shows whenever a tool panel holds
   the pane.
7. *C4.* A Transparency column: leave it out until there is per-placement transparency (recommended; none exists), or add
   transparency first (a backend field: Phase D).
8. *Phase plan.* #7 and #12 for VR (Mates folders, laser hover) in Phase D with T3 (recommended), or a C10 VR chunk in
   Phase C.
9. *C7.* The room tree's "in Rover > Mast" line read-only (recommended), or a crumb that closes the room and reveals that
   level in the world tree.
10. *Headset, from 10.8.* B8.1 draws the root as the way to a room (not dimmed) when the room's Part is below it; 10.6 said
    dimmed. Confirm, or C6 changes it.

**Nits carried:** none yet (each chunk adds its own here, with the chunk it is for).

**Owner device checks owed:** Phase B's list in 10.8 (still owed as of 25 Nov), then Phase C's, added by each chunk:
C0 (whatever it fixed from the Phase B checks); C2 (desktop and phone: a sub-assembly's Mates folder, a broken mate in it,
Focus here to edit, the drawer's mates); C3 (desktop and phone: edit a feature three levels down from the tree); C4 (desktop:
hover both ways on a large assembly, each column); C5 (desktop: the flyout with Extrude, Mirror and a mate tool open); C6
(headset: the World tree as before, the PARTS tab's bar); C7 (headset: a room's tree beside its console, its strip, Fix from
it); C8 (headset: the BUILD tab's folders and bar); C9 (headset: a part opened to its features, Table from a feature).

## Sources

- [What's New in SOLIDWORKS 2026 – Design](https://blogs.solidworks.com/products/solidworks/whats-new-in-solidworks-2026-design)
- [GoEngineer: SOLIDWORKS 2026 UI/UX](https://www.goengineer.com/blog/solidworks-2026-ui-ux-performance-and-imports-whats-new)
- [SOLIDWORKS FeatureManager Design Tree overview](https://help.solidworks.com/2022/English/SolidWorks/sldworks/c_featuremanager_design_tree.htm)
- [Onshape: Instances list](https://cad.onshape.com/help/Content/Assembly/instances_list.htm)
- [Onshape improvements, 18 Sep 2026](https://forum.onshape.com/discussion/31763/improvements-to-onshape-september-18-2026)
- [Shapr3D version history](https://www.shapr3d.com/content-library/brief-version-history)
- [Shapr3D Items Manager](https://support.shapr3d.com/hc/en-us/articles/7873936188956)
- [Shapr3D forum: resizable Items and History panels](https://discourse.shapr3d.com/t/make-items-panel-and-history-panel-resizable/28059)
