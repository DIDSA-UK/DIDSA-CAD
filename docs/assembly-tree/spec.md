# Assembly tree: endpoint and client rules (spec)

The contract of the assembly tree overhaul (`docs/assembly-tree-overhaul-scope.md`, section 9.2). It is fixed once A1 merges:
a change is made by the manager, in this file, the vectors and both clients at once.

Contents: 1. the endpoint; 2. cost and `status`; 3. display names; 4. grouping repeats; 5. the state slot; 6. problem counts;
7. visible rows; 8. row keys and reveal; 9. the vectors; 10. where the clients differed and what was chosen.

Words used below: a **node** is one placed occurrence in the response; a **row** is one line a client draws; **siblings** are
the occurrences one Part places, in the Part's order. "Unsaved" is client state: the backend never reports it.

## 1. `GET /parts/{part_id}/assembly-tree`

The whole hierarchy below one Part in one call. No geometry. Usual auth (`X-API-Key`) and session headers.

**Query parameters**

| Name | Default | Range | Meaning |
|---|---|---|---|
| `status` | `false` | bool | Also report constraint and mate status (section 2). Without it every status field is `null` |
| `max_depth` | 32 | 1..32 | Levels walked below the root; a node at this depth is not opened (`truncated`) |
| `max_nodes` | 10000 | 1..10000 | Occurrence nodes listed; the walk stops after this many (depth first, in order) |

A part id that does not exist is a 404; a value out of range is a 422.

**Response** (`AssemblyTreeResponse`, the root Part):

| Field | Type | Meaning |
|---|---|---|
| `part_id` | string | The root Part's id |
| `part_name` | string | The root Part's own name |
| `kind` | `"assembly"` / `"part"` | `assembly` when it places anything |
| `feature_count` | int | How many Features the root Part has |
| `status_included` | bool | Whether the call was made with `status=true` |
| `mates`, `patterns`, `problems` | object / null | As on an assembly node (below); `null` when `kind` is `part` |
| `children` | node[] | The root's occurrences, in order |
| `truncated` | bool | The node cap stopped the walk among the root's own children |
| `node_count` | int | Occurrence nodes listed (the root is not one) |
| `max_depth`, `max_nodes` | int | The caps used |
| `truncated_depth`, `truncated_nodes` | bool | A cap was hit somewhere: the tree is incomplete, and problem counts cover only what is listed |

**Node** (`AssemblyTreeNode`, one placed occurrence; every field is always present):

| Field | Type | Meaning |
|---|---|---|
| `occurrence_id` | string | The occurrence's id within its parent Part (the same id under every placement of that parent) |
| `path` | string[] | Occurrence ids from the root's children down to this node. Unique in the tree |
| `external_ref` | string / null | The placed file, as stored (`parts/<x>.didsa`) |
| `ref_part_id` | string / null | The placed file's root Part id, known even while missing (`/occurrences`' `ref_part_id`) |
| `resolved_part_id` | string / null | The loaded Part it places (session-local id); `null` = missing |
| `part_name` | string / null | That Part's own name; `null` when missing |
| `name_override` | string / null | The name the user gave this placement |
| `kind` | `"assembly"` / `"part"` / `"missing"` | `missing`: no loaded Part; `assembly`: the Part places occurrences; else `part` |
| `fixed`, `hidden`, `suppressed` | bool | The occurrence's own flags (not inherited) |
| `color` | string / null | The occurrence's legacy colour override (`#RRGGBB`) |
| `constraint` | object / null | See below; `null` without `status`, and for an occurrence `constraint-status` leaves out |
| `feature_count` | int / null | Features of the placed Part (whether a part row gets a chevron); `null` when missing |
| `placements` | int / null | How many nodes in this whole response place the same Part (suppressed ones included): "used N x". `null` when missing |
| `cycle` | bool | The Part is already open above this node (placed inside itself): no children, see section 5 |
| `truncated` | bool | The walk did not list (all of) this node's children because of a cap |
| `mates`, `patterns`, `problems` | object / null | On assembly nodes that were walked; `null` on parts, missing, cycle and depth-truncated nodes |
| `children` | node[] | The placed Part's occurrences, in order (empty for parts, missing, cycle, depth-truncated) |

`constraint` (`AssemblyTreeConstraint`): what `GET /parts/{parent}/constraint-status` says about this occurrence within its
parent Part, plus the parent's mates touching it.

| Field | Meaning |
|---|---|
| `status` | `fixed` / `fully_constrained` / `under_constrained` / `over_constrained` |
| `dof` | Its own remaining degrees of freedom (0 for fixed / fully constrained) |
| `rigid_set` | The rigid set it moves with (the set lead's occurrence id), or `null` |
| `broken_mates` | Unsuppressed mates of the parent touching it (by the mate's top-level occurrences) whose status is `broken` |
| `near_mates` | ... whose status is `near` |

`free_motions` from `constraint-status` are not included.

`mates` (`AssemblyTreeMates`, one assembly level's own mates): `count`, `suppressed`, and with `status` also `broken`, `near`
(the `/mates` listing's `status`), `held` (its `held`) and `lost` (mates with `lost_references`); those four are `null`
without `status`.

`patterns` (`AssemblyTreePatterns`): `count`, `suppressed`. Pattern copies are not nodes.

`problems` (`AssemblyTreeProblems`, rolled up over this assembly's subtree, section 6): `missing`, `cycles`, and with
`status` also `broken`, `over_constrained`, `near` (`null` without it).

Every placement is its own node with its own subtree: a sub-assembly placed twice appears twice, with distinct `path`s and
the same `occurrence_id`s below it. A suppressed occurrence is listed, with its subtree.

## 2. Cost and `status`

**`status` is off by default.** A client asks for the structure first (fast at any size) and for `status=true` once the
model has loaded (the viewport's `assembly-mesh` fetch builds the same bodies), or in the background, and merges the answer
(section 8).

Measured on this repo's dev container (4 vCPU Xeon 2.1 GHz, one process, `tests/bench_assembly_tree.py`; CI and the Pi will differ):

| Tree | Occurrences | No `status` | `status=true`, cold | `status=true`, warm | Size (no status / status) |
|---|---|---|---|---|---|
| Gear-train demo (DIDSA-VR `demo/assemblies/gear_train`, 18 mates) | 9 | 5 ms (2 ms warm) | 5,459 ms | 21 ms | 5 / 6 kB |
| ... after an `assembly-mesh` fetch | 9 | 6 ms | 93 ms | 20 ms | |
| The demo placed 222 times under one root | 2,220 | 51 ms | 6,110 ms | 533 ms | 1,256 / 1,448 kB |
| 40 sub-assemblies x 49 distinct parts, no mates | 2,000 | 34-169 ms | 1,537 ms | 1,600 ms | 896 / 1,079 kB |

- The cold `status` time is building the placed Parts' bodies (OCCT), which the first `assembly-mesh` fetch pays as well.
- Status is computed once per distinct assembly Part, not per placement. Warm, it costs what `constraint-status` costs on a
  wide level: about 0.75 ms per occurrence (a group model and free motions for each unmated occurrence), the same as calling
  `constraint-status` for every assembly today.
- Without `status`, a typical tree is well under the 300 ms target at any size measured. With it, a typical tree (the demo) is
  under 300 ms once the viewport has loaded, but a 2,000-occurrence tree is not, hence the default.

## 3. Display names

For each node, among its siblings:

1. **Base name**, the first that applies:
   1. `name_override`, when it has a non-space character (shown as stored);
   2. `part_name`, unless it looks generated;
   3. the file name: the last `/` segment of `external_ref` without its last extension (`lib/v1.2/clip.step.didsa` ->
      `clip.step`; a leading dot is not an extension: `.washer`), unless it looks generated;
   4. `Component N`, N = the node's 1-based place among all its siblings.
2. **Looks generated**: empty or only spaces; a UUID with or without dashes; or 16+ hex digits with an optional 1-6 letter
   prefix and `-` / `_` (`part-3f2a...`, `occ_ab12...`). Regexes: `^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$`
   and `^(?:[A-Za-z]{1,6}[-_])?[0-9a-fA-F]{16,}$`, on the trimmed name.
3. **Instance numbers**: siblings whose base name came from the Part name or the file name are "the same thing placed again"
   when they place the same Part (`resolved_part_id`), or, when missing, the same `external_ref`. When two or more siblings
   share that, each is named `Base <n>`, n = 1, 2, ... in sibling order among them. A renamed placement or a `Component N`
   is never numbered and is not counted. One placement keeps the plain base name. Two different Parts with the same name are
   not numbered.
4. Numbers are display-time only: they renumber after a delete.

The root row's name is `part_name`. Group rows and folders: sections 4 and 7.

## 4. Grouping repeats

**On by default**, with a switch to turn it off (the owner, 20 Nov; where the switch lives and how it is saved is each
client's). With grouping on, at each level:

- Siblings that share an instance key (section 3, rule 3) **and number 4 or more** become one **group row**, placed where the
  first of them is. The rest of them are not listed at the level.
- Label: `<base> x<n>` (ASCII `x`, a space before it): `Bolt M4 x4`.
- Open, a group lists its members under it (depth + 1), in sibling order, with their instance names (`Bolt M4 <1>` ...).
- The group's state slot is the most severe state among its unsuppressed members (all suppressed: among all of them).
  `hidden` when every member is hidden, `suppressed` when every member is.
- Collapsed, its bubble counts its unsuppressed members' own rows and everything below them (section 6).

With grouping off there are no group rows; the names are the same.

## 5. The state slot

One state per row, the most severe that applies, in this order:

| State | When | Suggested look |
|---|---|---|
| `missing` | `kind` is `missing` | red link-off / warning |
| `cycle` | `cycle` is true | red warning |
| `broken` | `constraint.broken_mates > 0` | red warning |
| `over_constrained` | `constraint.status` is `over_constrained` and `near_mates == 0` | red warning |
| `near` | `constraint.status` is `over_constrained` and `near_mates > 0` (and no broken mate) | amber warning |
| `unsaved` | the client has unsaved changes to the Part (`resolved_part_id`) | the unsaved dot |
| `under_constrained` | `constraint.status` is `under_constrained` | open lock (tooltip: `dof`) |
| `fixed` | `constraint.status` is `fixed`, or `constraint` is `null` and `fixed` is true | pin |
| `fully_constrained` | `constraint.status` is `fully_constrained` | lock |
| `none` | nothing of the above | nothing |

- The root row: `unsaved` when the root Part is unsaved, else `none`. Feature and folder rows: `none`.
- Without `status`, only `missing`, `cycle`, `unsaved`, `fixed` (the flag) and `none` can occur.
- `hidden` and `suppressed` are not states: a hidden row shows the eye-off icon, a suppressed row is drawn dimmed.

## 6. Problem counts

**Backend roll-up** (`problems` on every walked assembly node and the root): over the assembly's subtree, every level below and
including its own:

- `missing`: rows in state `missing`; `cycles`: rows in state `cycle`;
- `over_constrained`: rows in state `over_constrained` (a row whose state is `broken` or `near` is not counted: its mates are);
- `broken`, `near`: mates with that status, at this level and every level below.

Counted once per placement (a sub-assembly placed twice counts twice). A suppressed occurrence adds nothing (neither its own
row nor its subtree) to the counts above it; its own `problems` are still filled in. Under a cap, counts cover what is listed.

**Bubble** (one per row, at most): from three numbers,

- `error` = `missing + cycles + broken + over_constrained` (a `null` counts as 0),
- `warning` = `near`,
- `unsaved` = rows below (not suppressed, not under a suppressed row, not missing) whose Part the client has unsaved,

the row shows `{"level": "error", "count": error}` if `error > 0`, else `warning`, else `unsaved`, else no bubble. Which
numbers a row uses:

| Row | Bubble from |
|---|---|
| A collapsed occurrence row that can open | its `problems` + unsaved rows below it |
| An open occurrence row | its own level's mates only: `error` = `mates.broken`, `warning` = `mates.near` (its children show their own) |
| A collapsed group | each unsuppressed member: its own row (1 error if its state is `missing`, `cycle` or `over_constrained`; 1 unsaved if unsaved) plus its `problems` and unsaved rows below it |
| An open group | none |
| The root's Mates folder | the root's mates: `error` = `mates.broken`, `warning` = `mates.near` |
| The root, rows that cannot open, features, Patterns folder | none |

## 7. Visible rows

The flat list a client draws, top to bottom, for a set of **open keys** (section 8), the grouping switch, the set of unsaved
Part ids and the features the client has fetched (per row key, `[{id, label}]`, labels named by the client's feature naming).

1. **The root row** (key `""`, depth 0, kind `root`): always first and always open; it does not collapse.
2. **The root's children** at depth 1, as section 4 lists them (occurrence rows and group rows).
3. Under an **open occurrence row**: its children at depth + 1, then its features (when fetched) at depth + 1.
4. Under an **open group row**: its members at depth + 1, each followed by its own rows when it is open.
5. After the root's children: the **Mates** folder (if `mates.count > 0`), then **Patterns** (if `patterns.count > 0`), at
   depth 1; then the root's own features, at depth 1 (a Part opened on its own: the root row and its features).
6. A row **can open** (`expandable`) when: an occurrence row is not missing and has children or `feature_count > 0`; a group or
   folder always. The root, missing rows, features, and cycle / truncated nodes with no children and no features cannot. An
   open key on a row that cannot open is ignored (`open` is false).
7. An open part row whose features are not fetched yet lists nothing under it (a client may show progress on the row).
8. A folder's contents are drawn by the client from `/mates` and `/component-patterns`; they are not rows in this model yet
   (Phase C). Only the root has folders in Phase A.

Each row: `key`, `kind` (`root` / `assembly` / `part` / `missing` / `group` / `feature` / `mates_folder` / `patterns_folder`),
`depth`, `label`, `state`, `bubble` (`{level, count}` or `null`), `expandable`, `open`, `count` (members of a group, items in
a folder, else `null`), `path` (the node's `path` for occurrence rows, `[]` for the root, else `null`), `hidden`,
`suppressed`. A client maps an occurrence row back to its node by `path` for everything else (`dof`, `rigid_set`, `color`,
`placements`...).

**Default open state:** only the root is open (rows below the first level start collapsed). Remembering open rows per
document is Phase B.

## 8. Row keys and reveal

| Row | Key | Example |
|---|---|---|
| Root | `""` | |
| Occurrence | its `path` joined with `/` | `mast/arm/head` |
| Group | the parent's key, `/` (omitted at the root), `#group:` and the first member's `occurrence_id` | `wheel_l/#group:b1`, `#group:s1` |
| Feature | the owning row's key, `#feature:` and the feature id | `mast/arm/head/lens#feature:f2`, `#feature:f1` |
| Folder | the owning row's key and `#mates` / `#patterns` | `#mates` |

`#` never occurs in an occurrence id (pattern copies use `#pattern:`), so keys cannot collide. Keys use stored ids only
(occurrence and feature ids are kept in the file), so they survive a refresh and a reopen; `resolved_part_id` is
session-local and is never part of a key.

**Reveal** (a viewport pick, "expand to selection"): to list the row at `path`, open each ancestor occurrence (`path[:1]`,
`path[:2]`, ... `path[:-1]`) and, with grouping on, the group row any of the path's nodes sits in (before that node). Order:
for each level, the group (if any), then the ancestor. Nothing is needed for a top-level row that is not in a group.

**Refresh:** keep the open keys and the selection (a key or path) across a new response; drop keys whose rows no longer exist.
A group key changes when its first member is deleted; the group then starts collapsed.

## 9. The vectors

`docs/assembly-tree/vectors.json`, generated by `tools/assembly_tree_vectors/generate.py` from the reference implementation
`tools/assembly_tree_vectors/reference.py` (never edit it by hand; `test_reference.py` fails when the file differs from
what the generator writes; CI: `.github/workflows/assembly-tree-vectors.yml`). Flutter reads it from
`../docs/assembly-tree/vectors.json`; DIDSA-VR copies it unchanged to `tests/fixtures/assembly_tree_vectors.json`.

- `version`: 1. `states`: the state slot order (section 5).
- `trees`: name -> a full response (section 1), every field present. Ids are made up and mean nothing outside the file.
- `cases`, each with `name`, `why`, `tree`:
  - `kind: "rows"`: inputs `open` (keys), `grouping`, `unsaved_part_ids`, `features` (row key -> `[{id, label}]`);
    `expected`: the rows of section 7, in order, every field.
  - `kind: "reveal"`: inputs `path`, `grouping`; `expected`: the keys to open, in order (section 8).

A client passes when, for every case, its rows (or keys) equal `expected` exactly.

## 10. Where the clients differed, and what this spec chose

Settled by the owner (scope section 8): instance names `Bolt <2>` (Flutter had `bolt:2`); repeats grouped by default with a
switch. Chosen here where they differed and section 8 did not say:

| Topic | Flutter (Nov 2026) | VR (Nov 2026) | This spec |
|---|---|---|---|
| Base name | override, file name, `Component N` (never the Part's name) | override, the Part's name (fetched), placeholder `Occurrence <id>` | override, Part name, file name, `Component N` (as 9.2 lists); generated names skipped at each step |
| Which siblings are numbered | same `resolvedPartId ?? externalRef`, renamed ones still counted (gaps) | same Part, renamed and missing ones left out | same Part (missing: same file); renamed and `Component N` left out, no gaps |
| Missing file state | red link-off in the trailing cluster | `warning` | `missing`, its own state, the most severe |
| Over-constrained by `near` mates only | amber warning | (not handled) | `near`, amber |
| A broken mate on a row | only as "red, not amber" on an over-constrained row; otherwise on the mate row | not on the row | `broken` state on every row it touches |
| Fully constrained | lock | lock | kept as `fully_constrained` (lowest but `none`), though 9.2's order does not list it |
| Root row | a permanent root row (plus the Edit Alone row) | root row | one root row, always open, never collapses |
| Mates / Patterns | sections under the list | none | root folders after the root's children |
| Cycles | (not handled) | (not handled) | a `cycle` state after `missing` |
