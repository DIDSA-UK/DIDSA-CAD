# Assembly tree overhaul: scope (20 Nov 2026)

The owner asked for a scoping review of the build / assembly / feature tree in the Flutter client and the Godot VR client.
The prompt was that sub-assemblies and parts don't expand: you cannot see the children of children. This doc covers what the
leading CAD products do, what ours do today, a ranked list of what's missing and how to add it, and how the tree should treat
the upstream assembly in Make Focus and Edit Alone, on desktop and on a phone.

**Status:** scoped; the owner answered every question on 20 Nov (section 8). Phase A briefs in section 9. Nothing built.

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
| B, context | #5, #9, #10, #8 | Q2 and Q3 answered (section 8) |
| C, depth | #7, #13, #12, #14, #15; VR T2 | |
| D, power | #16, #17, #18; VR T3 | Backend work |

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
- **Docs:** add an entry to that repo's `docs/status.md` (what was built, the tests, what is not verified), and tick your chunk
  in 9.7 with the PR link.
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
6. After merging: update 9.7 and give the owner the next worker prompt (and the device check, where 9.1 says so).

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
| A1 contract | not started | | | |
| A2 Flutter logic | not started | | | |
| A3 Flutter widget | not started | | | |
| A4 Flutter integration | not started | | | |
| A5 VR adoption | not started | | | |

## Sources

- [What's New in SOLIDWORKS 2026 – Design](https://blogs.solidworks.com/products/solidworks/whats-new-in-solidworks-2026-design)
- [GoEngineer: SOLIDWORKS 2026 UI/UX](https://www.goengineer.com/blog/solidworks-2026-ui-ux-performance-and-imports-whats-new)
- [SOLIDWORKS FeatureManager Design Tree overview](https://help.solidworks.com/2022/English/SolidWorks/sldworks/c_featuremanager_design_tree.htm)
- [Onshape: Instances list](https://cad.onshape.com/help/Content/Assembly/instances_list.htm)
- [Onshape improvements, 18 Sep 2026](https://forum.onshape.com/discussion/31763/improvements-to-onshape-september-18-2026)
- [Shapr3D version history](https://www.shapr3d.com/content-library/brief-version-history)
- [Shapr3D Items Manager](https://support.shapr3d.com/hc/en-us/articles/7873936188956)
- [Shapr3D forum: resizable Items and History panels](https://discourse.shapr3d.com/t/make-items-panel-and-history-panel-resizable/28059)
