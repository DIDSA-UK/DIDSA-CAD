# Assembly tree: endpoint and client rules (spec)

The contract of the assembly tree overhaul (`docs/assembly-tree-overhaul-scope.md`, section 9.2). It is fixed once A1 merges:
a change is made by the manager, in this file, the vectors and both clients at once.

Contents: 1. the endpoint; 2. cost and `status`; 3. display names; 4. grouping repeats; 5. the state slot; 6. problem counts;
7. visible rows; 8. row keys and reveal; 9. the vectors; 10. where the clients differed and what was chosen; 11. the filter;
12. remembered open rows; 13. the live part (the build tree). Sections 11 to 13 came with Phase B's first chunk (B1) and only
add: sections 1 to 10 are as they were, except the new row kinds in section 7, the new keys in section 8 and the version
in section 9.

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
| `status_failed` | bool | The root's own level: as on a node (section 2) |
| `status_incomplete` | bool | With `status`: some level anywhere has `status_failed` (section 2). Always false without `status` |

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
| `status_failed` | bool | With `status`: this assembly level's status could not be computed (section 2). Always false without `status` and on non-assembly nodes |
| `mates`, `patterns`, `problems` | object / null | On assembly nodes that were walked; `null` on parts, missing, cycle and depth-truncated nodes |
| `children` | node[] | The placed Part's occurrences, in order (empty for parts, missing, cycle, depth-truncated) |

`constraint` (`AssemblyTreeConstraint`): what `GET /parts/{parent}/constraint-status` says about this occurrence within its
parent Part, plus the parent's mates touching it.

| Field | Meaning |
|---|---|
| `status` | `fixed` / `fully_constrained` / `under_constrained` / `over_constrained` |
| `dof` | Its own remaining degrees of freedom (0 for fixed / fully constrained) |
| `rigid_set` | The rigid set it moves with (the set lead's occurrence id), or `null` |
| `broken_mates` | Unsuppressed mates of the parent touching it (by the mate's top-level occurrences) whose status is `broken`, leaving out mates that also touch a suppressed occurrence |
| `near_mates` | ... whose status is `near` |

`free_motions` from `constraint-status` are not included.

`mates` (`AssemblyTreeMates`, one assembly level's own mates): `count`, `suppressed`, and with `status` also `broken`, `near`
(the `/mates` listing's `status`), `held` (its `held`) and `lost` (mates with `lost_references`); those four are `null`
without `status`, and leave out every mate touching a suppressed occurrence of this level (`count` and `suppressed` count
every mate).

`patterns` (`AssemblyTreePatterns`): `count`, `suppressed`. Pattern copies are not nodes.

`problems` (`AssemblyTreeProblems`, rolled up over this assembly's subtree, section 6): `missing`, `cycles`, and with
`status` also `broken`, `over_constrained`, `near` (`null` without it).

Every placement is its own node with its own subtree: a sub-assembly placed twice appears twice, with distinct `path`s and
the same `occurrence_id`s below it. A suppressed occurrence is listed, with its subtree.

## 2. Cost and `status`

**`status` is off by default.** A client asks for the structure first (fast at any size) and for `status=true` once the
model has loaded (the viewport's `assembly-mesh` fetch builds the same bodies), or in the background, and merges the answer
(section 8).

**Read-only.** The call never changes the document. (`GET /mates` writes re-found mate reference indices and adopted
signatures back; this call checks the references the same way but writes nothing, so its status is what `/mates` would
report.)

**A level that fails.** Status is computed per distinct assembly Part. If that raises for one Part, the server logs it and
every node of that Part (each placement, and the root when it is that Part) has `status_failed: true`, and
`status_incomplete` is true on the response. On such a node: `mates.broken` / `near` / `held` / `lost` are `null`; its
children's `constraint` is `null`; it adds 0 of its own to `problems` (counts from the levels below it still roll up).
The node's own `constraint` belongs to its parent's level and is unaffected. The other levels are filled in as usual. So:

| `status_included` | `status_failed` | Meaning of a `null` status field on that level |
|---|---|---|
| false | false | Status was not requested |
| true | true | Status was requested and failed for this level (show "status unavailable", do not show it as healthy) |
| true | false | Requested and computed: a `null` `constraint` is an occurrence `constraint-status` leaves out |

Measured on this repo's dev container (4 vCPU Xeon 2.1 GHz, one process, `tests/bench_assembly_tree.py`; CI and the Pi will differ):

| Tree | Occurrences | No `status` | `status=true`, cold | `status=true`, warm | Size (no status / status) |
|---|---|---|---|---|---|
| Gear-train demo (DIDSA-VR `demo/assemblies/gear_train`, 18 mates) | 9 | 5 ms (3 ms warm) | 5,863 ms | 47 ms | 6 / 6 kB |
| ... after an `assembly-mesh` fetch | 9 | 5 ms | 88 ms | 37 ms | |
| The demo placed 222 times under one root | 2,220 | 72-74 ms | 6,594 ms | 527 ms | 1,310 / 1,501 kB |
| 40 sub-assemblies x 49 distinct parts, no mates | 2,000 | 42-175 ms | 990 ms | 1,036 ms | 944 / 1,127 kB |

- The cold `status` time is building the placed Parts' bodies (OCCT), which the first `assembly-mesh` fetch pays as well.
- Status is computed once per distinct assembly Part, not per placement. One body cache is shared by every level's mate
  checks, and the constraint analysis skips free motions (`constraint_report(..., free_motions=False)`), which took the
  distinct-parts tree from 1.6 s to 1.0 s warm.
- What is left on wide levels is `constraint_report`'s own per-occurrence cost (a group model per unmated occurrence; its
  cache key is built from the whole level each time), about 0.5 ms per occurrence: the same as `constraint-status` costs
  today. Not changed here.
- Being read-only costs the demo about 20 ms warm: references a `/mates` call would have signed once are checked again on
  every call until something saves them.
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
3. **Instance groups and numbers**: siblings without a name override that place the same Part (`resolved_part_id`), or,
   when missing, the same `external_ref`, form one instance group (the **instance key**). The whole group takes one base
   name: the Part's name unless it looks generated, else the file name of the **first member, in sibling order, whose file
   name does not look generated** (so one Part placed through `parts/left_arm.didsa` and `parts/arm_copy.didsa` is
   `left_arm` throughout, a member placed through a generated file name included). A group with neither has no instance
   key: its members are each `Component N` (rule 1.4) and are neither numbered nor grouped. When a group has two or more
   members, each is named `Base <n>`, n = 1, 2, ... in sibling order. A renamed placement is never numbered and is not
   counted. One placement keeps the plain base name. Two different Parts with the same name are not numbered.
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
- `broken`, `near`: mates with that status, at this level and every level below, leaving out mates that touch a suppressed
  occurrence of their level.

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

Each row: `key`, `kind` (`root` / `assembly` / `part` / `missing` / `group` / `feature` / `mates_folder` / `patterns_folder`; and,
only with a live part (section 13), `bodies_folder` / `planes_folder` / `surfaces_folder` / `curves_folder` / `body` / `surface` /
`curve` / `default_plane`),
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
| Live part's folders and items (section 13) | the live row's key `K` and `#bodies` / `#planes` / `#surfaces` / `#curves`; `K#body:<id>`, `K#surface:<id>`, `K#curve:<id>`; `K#plane:xy` / `xz` / `yz`; `K#plane:feature:<feature id>` | `mast/arm/head#bodies`, `#plane:xy`, `#plane:feature:f3`, `#body:b1` |

The ids the backend and both clients make never contain `#` or `/` (the backend's uuid4, VR's `occ_<hex>`; the contract is only that property, not the format), and pattern copies use `#pattern:`, so keys do not collide.
The backend does not check an id it is given (`POST /parts/{id}/occurrences`, `POST /parts/{id}/add-component`, whose
`occurrence_id` is taken as given, and `import_native`, which takes ids as written), so a hand-edited `.didsa` can still carry a `#` or a `/`. Keys can then collide
(`/` joins path ids: `a/b` at the root and the child `b` of `a` are one key; `#` is the separator of group, feature and folder
keys), and the rows, filter, reveal and restore results for those rows are undefined. A client must not crash on one: it treats the
key as it is. Keys use stored ids only
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

- `version`: 2 (version 1 had the `rows` and `reveal` cases only; they are the first 36 cases, unchanged). `states`: the state slot
  order (section 5).
- `trees`: name -> a full response (section 1), every field present. Ids are made up and mean nothing outside the file.
- `cases`, each with `name`, `why`, `tree`:
  - `kind: "rows"`: inputs `open` (keys), `grouping`, `unsaved_part_ids`, `features` (row key -> `[{id, label}]`);
    `expected`: the rows of section 7, in order, every field.
  - `kind: "reveal"`: inputs `path`, `grouping`; `expected`: the keys to open, in order (section 8).

  - Version 2 (sections 11 to 13): `kind: "filter"` (the `rows` inputs plus `query`; `expected`: `{rows, unknown}`, every row with
    `match`); `"restore"` (`stored`, `grouping`, `limit`; `expected`: the kept keys); `"live_part"` (the `rows` inputs plus `live`,
    section 13; every row has `type`); `"live_part_filter"` (`live` and `query`) and `"live_part_restore"` (`live`, `stored`,
    `grouping`, `limit`). A client runs every kind it implements and fails on a kind it does not know.
  DIDSA-VR's `tests/occurrence_tree_model.gd` checks `version == 1` and runs every case that is not `rows` as a reveal, so B7 changes
  it when it copies version 2 (`filter` and `restore` implemented; the three `live_part` kinds skipped by name).

A client passes when, for every case, its rows (or keys) equal `expected` exactly.

The generator also writes `backend/tests/data/assembly_tree_rollup_vectors.json`: a few of the models as native documents
(no features, no mates) with the tree `reference.build_tree` builds for them. `backend/tests/test_assembly_tree.py`
imports each and requires the endpoint to answer exactly that tree, so the backend walk and the reference cannot drift
apart.

## 10. Where the clients differed, and what this spec chose

Settled by the owner (scope section 8): instance names `Bolt <2>` (Flutter had `bolt:2`); repeats grouped by default with a
switch. Chosen here where they differed and section 8 did not say:

| Topic | Flutter (Nov 2026) | VR (Nov 2026) | This spec |
|---|---|---|---|
| Base name | override, file name, `Component N` (never the Part's name) | override, the Part's name (fetched), placeholder `Occurrence <id>` | override, Part name, file name, `Component N` (as 9.2 lists); generated names skipped at each step |
| Which siblings are numbered | same `resolvedPartId ?? externalRef`, renamed ones still counted (gaps) | same Part, renamed and missing ones left out | same Part (missing: same file), named after the Part or the first member's usable file name; renamed and `Component N` left out, no gaps |
| Missing file state | red link-off in the trailing cluster | `warning` | `missing`, its own state, the most severe |
| Over-constrained by `near` mates only | amber warning | (not handled) | `near`, amber |
| A broken mate on a row | only as "red, not amber" on an over-constrained row; otherwise on the mate row | not on the row | `broken` state on every row it touches |
| Fully constrained | lock | lock | kept as `fully_constrained` (lowest but `none`), though 9.2's order does not list it |
| Root row | a permanent root row (plus the Edit Alone row) | root row | one root row, always open, never collapses |
| Mates / Patterns | sections under the list | none | root folders after the root's children |
| Cycles | (not handled) | (not handled) | a `cycle` state after `missing` |

## 11. Filter

Input: a query string, plus everything section 7 takes (open keys, the grouping switch, unsaved Part ids, fetched features) and,
with a live part, section 13's inputs. Output: `rows` and `unknown`. Every output row has `match` (true / false).

**Parsing.** Lower-case the query and split it on runs of whitespace. A word starting with `:` is a **token**; any other word is a
**name term**. A word repeated is used once. An empty query, or one with only spaces, is **no filter**: the rows are section 7's
for the open keys, every `match` is false, `unknown` is empty.

**Tokens.** A token names a test of one row. Matching is by the row's own fields (section 7), so a client needs nothing else:

| Token | A row meets it when |
|---|---|
| `:missing` | `state` is `missing` |
| `:errors` | `state` is `missing`, `cycle`, `broken`, `over_constrained` or (section 13) `lost_reference`: the bubble's `error` set |
| `:warnings` | `state` is `near` or (section 13) `moved_reference` |
| `:unsaved` | `state` is `unsaved` |
| `:fixed` | the occurrence's `fixed` flag is true, whatever its `state` (with `status`, a row whose constraint says `fully_constrained` shows that state, not `fixed`, but still meets `:fixed`) |
| `:hidden` | the row's `hidden` is true (an occurrence, or a feature, body, surface, curve or default plane; whatever its `state`) |
| `:suppressed` | the row's `suppressed` is true (its own flag: the rows below a suppressed row are not suppressed) |
| `:parts` / `:assemblies` | `kind` is `part` / `assembly` (a missing row is neither) |
| `:features` | `kind` is `feature` (a fetched feature, or any feature row of the live part; a plane feature counts in both places it is listed) |
| `:sketches` | `type` is `sketch` (only feature rows of a live part have a `type`; section 7's fetched features have none, so they never match) |

`:mates` waits for Phase C (mates are not rows yet). A word starting with `:` that is not in this table is an **unknown token**: it
is left out of the matching and listed in `unknown` (lower case, once each, in query order), so a client can say "unknown filter
:foo". A lone `:` is an unknown token.

**Which rows can match.** Every occurrence row at any depth, whatever the open keys; feature rows only where features were
fetched (a client cannot find features it has not read, and says so in the filter's hint); under a live part, its feature, body,
surface, curve and plane rows. The root, group rows and folder rows never match themselves.

**A row matches** when its `label` contains every name term (a substring; so `<2>` finds instance 2) and it meets every known
token (AND). With no name term and no known token (the query holds only unknown tokens) nothing matches: the output is the root
row and `unknown`.

**Listed rows.** The root; every match; every ancestor of a match: occurrence rows, with grouping on the group row a match or an
ancestor sits in, and the live part's folder a match sits in. Only the matching members of a group are listed under it. Order
and depth are section 7's (and section 13's). The Mates and Patterns folders are not listed while a filter is on. A listed row's
`open` is true when some row below it is listed (the root's always); a match with nothing listed below is `open: false`, its
`expandable` as usual. Bubbles follow section 6 with these `open` values.

**The open keys are not changed.** Clearing the filter gives section 7's rows for the same open keys. The chevrons are inert
while a filter is on. Selecting a row and then clearing the filter reveals it (section 8).

**Without `status`,** `:errors` and `:warnings` find only what section 5 lists for that case (missing files, cycles); a client says
the status is still loading.

## 12. Remembered open rows

- **Stored:** the open keys (section 8) of one document's tree, per document, in the client's own storage. The key a client uses
  for the document (a file path, a cloud project and path) is the client's choice; the stored keys are the spec's. At most 2,000
  (`MAX_STORED_KEYS`); beyond that the first 2,000 in the order below are kept and the rest dropped.
- **Restore** (when a document opens, and the refresh rule of section 8): keep a stored key when it names a row of the new tree
  that can open, **under either grouping setting** (a group key is checked as if grouping were on, so switching grouping off and
  on loses nothing); drop the rest. Never kept: the root's `""`, feature, body, surface, curve and plane keys. Folder keys are:
  `#mates` and `#patterns` when the folder shows, and the live part's folders (section 13) when the folder shows and a live part
  is given. The result is in **the order of the tree's visible rows with every row open and grouping on**, whatever the current
  grouping, so it is deterministic. In the vectors, `grouping` is the client's current setting and does not change the result.
- **Collapse all** empties the open keys (the root stays open). **Expand to selection** adds section 8's reveal keys for the
  selected path. Both are stored.
- Restoring does not move the camera or change the selection. Edit Alone's re-rooted tree (B3) is not stored: it starts with its
  root open and reveals the selection.

## 13. The live part (the build tree)

One row at a time is the **live part**: the root when a part is opened on its own (key `""`), or the focused part's row in the Part
lens inside an assembly. Only its rows are built from the inputs below; feature rows under other parts stay section 7's
(`label` only, no `type`).

**Inputs** (`live`): `key` (the live row's key, `K`); `features`, in build order, each `{id, label, type, lost_reference,
moved_reference, pending_detail, rolled_back, hidden}` (`lost_reference` is the reason as a string, or null when not lost; the
rest are booleans, false when absent); `bodies`, `surfaces`, `curves` (`{id, label, hidden}`); `default_planes_hidden`
(`{xy, xz, yz}`). If `key` names no row of the tree, or a missing row, `live` is ignored: nothing is added (rows still carry a
null `type`). The live row is always `expandable` (its Planes folder is always there), unless it is missing.

**Rows.** With `live` given every row has `type`: the feature's `type` on a feature row, else null. Under the live row, **after
anything section 7 lists under it** (its child occurrences; at the root also the Mates and Patterns folders), in this order:

1. The folders `bodies_folder` ("Bodies"), `planes_folder` ("Planes"), `surfaces_folder` ("Surfaces"), `curves_folder` ("Curves"),
   at the live row's depth + 1. Each is shown only when it has something in it; **Planes always**. `count` is its items (Planes:
   the three default planes plus the plane features). They start collapsed (section 7's open keys decide).
2. Its **features in build order**, at the same depth as the folders (`kind` `feature`), **replacing** section 7's feature rows of
   that row.

Inside an open folder (depth + 2): `body` / `surface` / `curve` rows; in Planes the three `default_plane` rows ("XY plane", "XZ
plane", "YZ plane", in that order), then the plane features (`type` `create_plane`, `kind` `feature`) in build order, which also
stay in the build order below. When a row becomes live a client adds its key to the open keys (it shows open); the user can close it.

**Keys** (section 8 has the table): folders `K#bodies`, `K#planes`, `K#surfaces`, `K#curves`; `K#body:<id>`, `K#surface:<id>`,
`K#curve:<id>`; default planes `K#plane:xy` / `xz` / `yz`; every plane feature in the Planes folder `K#plane:feature:<feature id>`
(always, so the two kinds of plane row can never share a key), its build-order row `K#feature:<id>`. Ids are the backend's: a feature id the backend makes is a UUID (a hand-written file can carry any id); a body id can contain `#` (`<feature id>#<n>`, when a feature makes several bodies). A client appends the whole id after the prefix and never splits a key, so that is harmless.

**A feature id can never be `xy`, `xz` or `yz`.** Every route that
creates a feature mints its id with `uuid.uuid4()` (the one fixed id in the backend, `ImportFeature`'s `convert`, is not a plane
name), and no request body supplies the id of a new feature. One door is not shut: a native `.didsa` file written or edited by
hand can carry any string as a feature id (`native_format._feature_from_dict` takes it as it is) and an import does not check it.
So the spec does not rely on the rule: every plane feature in the Planes folder is keyed `K#plane:feature:<id>`, whatever its id, and
the default planes keep `K#plane:xy` / `xz` / `yz`, so the two can never share a key. The build-order key is `K#feature:<id>`.

**The state slot of a feature row,** one per row, the most severe first:

| State | When | Suggested look |
|---|---|---|
| `lost_reference` | `lost_reference` is not null (the reason is the tooltip and the bar's text) | red |
| `moved_reference` | `moved_reference` | amber |
| `pending_detail` | `pending_detail` (waiting for detail) | the pending marker |
| `rolled_back` | `rolled_back` (after the rollback point) | dimmed |
| `hidden` | `hidden` | eye-off |
| `none` | none of the above | nothing |

`hidden` is also the row's `hidden` field, whichever state wins. Body, surface, curve and default-plane rows: `hidden` or `none`
by the same rule. Folders never have a state (`none`) or a bubble; feature rows have no bubble. The `hidden` and `suppressed` of
a folder are false.

**The filter (section 11) on these rows.** Feature, body, surface, curve and plane rows match by `label` and the tokens above;
`:errors` also matches `lost_reference`, `:warnings` `moved_reference`, `:hidden` the `hidden` flag of any of them. A folder never
matches, but a match inside one lists the folder, open, as a group is listed. A plane feature matches in both places it is listed.

**Remembered rows (section 12):** folder keys can be open keys; feature, body, surface, curve and plane keys never are.
