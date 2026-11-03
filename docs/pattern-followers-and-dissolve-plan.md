# Component patterns: mated parts follow pattern copies, and "Dissolve pattern" — investigation & plan

Status: **investigated, not implemented; product decisions confirmed** (hand-off document for one Sonnet 5.5 session working in both `DIDSA-UK/DIDSA-CAD` and `DIDSA-UK/didsa-vr`). Builds on
`docs/pattern-component-bugfix-plan.md` (B2 step 4 was deferred there) and `docs/assembly-scope.md` §2y/§2z.

| # | Request | Size |
|---|---------|------|
| F1 | A part mated to a pattern copy follows when the copy moves (its source is moved/solved, or the pattern is edited); mates that can't follow are shown as broken | M–L, backend + client |
| F2 | "Dissolve pattern" from the long-press menu of a pattern row: turn every copy into a real component | M, backend + client |
| V1-V3 | VR client (`DIDSA-UK/didsa-vr`): copy mates fold to their source (V1, a live bug), copies move with their source (V2), parity (V3) | S–M, VR |

Recommended order: **V1 first** (a small VR fix for a bug already live on `main`), then **F1**, **F2**, the
`geometry=false` backend addition, then **V2** (needs it) and **V3**. F1 and F2 are independent, but F2's tests are
simpler to write once copy mates behave like ordinary mates.

**Assumption to confirm:** "pattern feature in the feature tree" means a row in the **Assembly tree's Patterns
section** (Assembly lens, `ComponentPattern`). Dissolving a Part-lens body Pattern feature (`PatternFeature`) is a
different feature and out of scope here.

---

## How copies work today (what both changes touch)

- A `ComponentPattern` is data only (`models.ComponentPattern`); copies are never stored. Each copy is computed on demand
  by `assembly.expand_component_pattern_instances(pattern, source.transform)` and addressed by the path segment
  `<source occurrence id>#pattern:<pattern id>:<index>` (`assembly.parse_pattern_segment`,
  `assembly.resolve_pattern_copy_transform`, `occurrence_paths.resolve_path`).
- Copy pose = `compose(step_i, source_pose)` (Linear, and Circular with `orient_with_rotation`); Circular with
  `orient_with_rotation = false` keeps the source rotation and moves only the position. A copy is therefore a **fixed
  function of its source's pose and the pattern parameters**.
- That path is the key for everything stored against a copy:
  - **mates** (`Mate.references[*].occurrence_id`, and `midplane.b_occurrence_id`), in whichever Part owns the mate;
  - **Appearance overrides** (`Part.appearance_overrides[*].path`, plus `scope: "pattern"` overrides that paint every
    copy of a pattern), `appearance_routes.drop_overrides_of_pattern`;
  - **Scene overrides** (`Part.scenes[*].overrides[*].path`), `scenes_routes.drop_scene_overrides_of_pattern`.
- Mates on copies (added in §2y): a copy is a **frozen** side — `assembly_group.discover_component` adds every copy top to
  `frozen`, and the side gets `frozen_transform` = the copy's pose at the source's **stored** pose
  (`build_group_model.single_side`). So the copy never takes part in a solve, and it also never *follows* its source in
  one. That is the gap F1 closes.

---

## F1. Mated parts follow pattern copies

### When a copy moves

1. **Its source moves** — gizmo drag + post-drag `/solve`, constrained drag (`/mate-motion`), numeric Move/Rotate, a mate
   solve that moves the source, undo, AI plan `move_component`.
2. **The pattern changes** — `PATCH /component-patterns/{id}`: spacing, direction(s), count/skip (surviving copies don't
   move, but `direction`/`spacing`/axis/angle/`orient_with_rotation` do move them), or the source list.

Today neither re-solves anything attached to a copy: case 1 leaves B behind (copy is frozen at the source's *old*
stored pose during the solve, then rendered at the new one), case 2 has no solve at all (`update_component_pattern`
only drops mates on copies that no longer exist).

### Design: a copy is a *follower* of its source in the group model

In `backend/app/document/assembly_group.py`:

1. **Graph membership.** Add `mate_ref_drivers(ref)` (in `assembly.py`, next to `mate_ref_tops`): the tops with every
   copy segment folded to its **source** id (`parse_pattern_segment(top)[0]`). Use it — not `mate_ref_tops` — for
   adjacency/membership in `discover_component` and for the swap/orientation test in `build_group_model`. Remove the
   "freeze every copy top" lines (`discover_component`, ~line 145). Result: a mate B ↔ copy-of-A joins A and B in one
   component, exactly like a direct A ↔ B mate. A `fixed` source stays frozen, and so does its copy (B is grounded on it).
2. **Side geometry.** `_Side` gains `follow: tuple[ComponentPattern, int] | None`. In `single_side`, when the ref's top is
   a copy segment: resolve the target part and local geometry as today (`_target_part_and_transform` already resolves
   copies), then
   - source is a member → `_Side(occurrence_id=<source id>, geometry, frozen_transform=None, follow=(pattern, index))`;
   - source not a member (fixed, or outside the component) → today's frozen side (unchanged).
3. **World pose.** `_world_one`: `transform = placed.get(side.occurrence_id, side.frozen_transform)`; if `side.follow`,
   replace it with `copy_pose(pattern, transform, index)`. Add `assembly.pattern_copy_pose(pattern, source_pose, index)`
   (one index, same maths as `expand_component_pattern_instances`, including the `orient_with_rotation = false` branch)
   and use it from `expand_component_pattern_instances` too so the two can't drift.
4. **Jacobian / client model.** `export_constraint_model` (`constraint_model.py`) doesn't know followers: make it
   return `None` when any side has `follow`. Effects, both already handled:
   - `GroupModel.jacobian` falls back to central differences (`self._spec = False`);
   - the client's `LocalRetractor.tryParse(null)` keeps server-side projection during a drag (slower drags only for
     groups containing a copy mate). `_nearest_point_stage` is skipped when there is no model.
   *Optional v2:* constraint-model version 7 — a side may carry `follow: {pre: {r, t}}` (the constant step, left-
   multiplied after the member pose; plus a flag for `orient_with_rotation = false`), implemented in both
   `constraint_model.py` and `client/lib/motion/local_retraction.dart`. Only worth it if drags feel slow.
5. **py-slvs fallback.** `solve_group`'s single-member fallback (`solve_occurrence_from_guess`, ~line 1037) uses
   `assembly_solver._applicable_mates`, which matches refs by raw top and would silently ignore a follower mate. Skip the
   fallback when any side has `follow` (same as it already does for Width partners).
6. **Couplers and limits.** `_coupler_rows` and the limit rows assume `side.occurrence_id` is the moving body. v1: reject
   creating a gear / rack-pinion / screw / limit mate that references a copy (422 with a clear message) in
   `_validate_mate_create`; check whether any can exist today (§2y allowed them) and, if so, keep them on the old frozen
   path by not setting `follow` for those mate types.
7. **Which side a create/edit solve drives.** `router._mate_solve_target` keeps skipping copies (an explicit
   `occurrence_id=<copy>` stays a 422 — the user should drive the source). Note the behaviour change: a new mate
   B ↔ copy-of-A now solves a group that contains A as well, so with *group* movement A can move too (exactly as for a
   direct A ↔ B mate); *minimal* movement still moves only B.

### Pattern edits re-solve what is attached to their copies (case 2)

In `router.update_component_pattern`, after applying and validating the new values:

1. Find every mate (in the pattern's own Part) with a reference whose top is a copy of this pattern.
2. For each distinct non-copy, non-source occurrence those mates drive (B), run a group solve with `grabbed_id = B`,
   **`also_frozen = set(pattern.source_occurrence_ids)`** (the sources must not move because the pattern changed) and
   `group` movement. Copies of the frozen sources resolve to their new poses through the frozen-side path.
3. **The pattern edit is always stored** (confirmed: never refused because of a mate). Each group that converges is
   committed (`_commit_group`). A group that does not converge (or whose B is `fixed`) is left where it was, and its
   mates on copies are now **broken** (see "Broken mates" below). The PATCH response gains
   `broken_mate_ids: list[str]` - the mates this edit left unsatisfied - so the client can flash them.
4. Mates naming copies that no longer exist are still dropped first (`_drop_mates_with_dead_pattern_copies`), as today.
5. Also check `_drop_mates_with_dead_pattern_copies` and the re-solve only look at the pattern's own Part: a mate in a
   *parent* assembly naming `sub/src#pattern:…` is carried by `sub` (moves rigidly with it), so it needs no re-solve —
   but a dead copy there is not cleaned up today either. Fix the cleanup to walk every Part (use
   `occurrence_paths.path_uses_pattern`).

### Broken mates (new, confirmed)

Nothing in the app marks a mate as unsatisfied today (`MateResponse` has no such field; the tree draws every mate the
same). Add it as a **computed** state, not a stored flag, so it can never go stale:

- Backend: `MateResponse.status: Literal["ok", "broken"]`, computed whenever mates are listed or returned. A mate is
  `broken` when its residual at the **stored** poses is above tolerance (reuse `assembly_solver._mate_residual_vector`
  with each side resolved through `_target_part_and_transform` + local geometry; tolerance in line with the solver's
  `_NOISE_TOL`, mm/rad scaled like the residual rows). Limit mates: `broken` when the measured value is outside
  `[limit_min, limit_max]`. Couplers (gear/rack/screw) measure relative motion and are always `ok`. Suppressed mates
  are `ok`. A reference that no longer resolves is `broken` too. Cache `compute_part_bodies` per Part for the whole
  listing - this runs on every tree refresh, so measure it on the frame fixture (`backend/tests/data/frame_ai_test/`)
  and keep it cheap.
- This also surfaces mates broken for other reasons (geometry edited in a part file, an over-constrained import), which
  is the intent - say so in the report rather than special-casing pattern edits.
- Client `MateDto.status`; `assembly_tree_panel.dart` mate rows: a broken mate draws in the theme's error colour with
  a warning icon and the tooltip/subtitle "Broken - can't be satisfied". Rows named in a PATCH's `broken_mate_ids`
  additionally **flash** (a short pulse of the row background, ~3 pulses over ~2 s) after the tree refresh, and the
  Mates section expands if collapsed so the flash is visible. A `SnackBar` says "Pattern updated - N mate(s) could not
  be kept".
- A broken mate stays a normal mate: a later solve of its group tries to satisfy it; editing, suppressing or deleting
  it is how the user resolves it. Note in the report: while it stays broken, a drag/solve of that group may fail with
  the usual "No placement satisfies these mates together" until the user fixes it - existing behaviour for
  conflicting mates.

Tests: backend - a pattern spacing edit that B (fixed) can't follow → 200, pattern stored, B unmoved,
`broken_mate_ids == [mate]`, `GET .../mates` reports `status: "broken"`; moving the pattern back → `ok` again; a
satisfied mate is `ok`; limit mate outside its range → `broken`. Client - a broken mate row uses the error colour and
icon; a PATCH returning `broken_mate_ids` triggers the flash (pump the animation) and the SnackBar.

### Client: a source whose copies are mated counts as mated (verified gap)

Every client move path decides between "constrained" (solving) and "plain PATCH" with
`_isMated(occurrenceId)` (`part_screen.dart` ~12612), which tests `mateTopLevelOccurrences(m).contains(id)`. A mate on a
copy has the top `A#pattern:P:i`, never `A`, so **a source whose only mates are on its copies is treated as unmated**:
gizmo drags and the numeric Move/Rotate Apply (`_applyGizmoWorldTransform` ~12938) then send a bare
`updateOccurrenceTransform` with no solve, and B would be left behind even with the backend fixed.

Fix: make `mateTopLevelOccurrences` (or a new `mateDrivingOccurrences`) fold a `#pattern:` top to its source id — the
client mirror of `mate_ref_drivers` — and use it in `_isMated` and every other place that uses it to decide which parts
a move or drag involves (grep `mateTopLevelOccurrences`). Then also check:
- the constrained path (`_applyConstrainedWorldTransform`, `/mate-motion`, `/solve`) moves and refreshes every member
  of the group, B included;
- undo (`_componentTransformUndoStack` / `_undoLastAssemblyAction`) restores the followers too, not only the dragged
  source - if it only stores the dragged occurrence today, that is an existing limitation for direct mates as well;
  record it rather than widen scope;
- AI plan `move_component` (`ai_plan_translator.dart`) solves after moving.

Client test: B mated to a copy of A → `_isMated(A)` is true → a numeric Move of A goes through the constrained path
(the fake backend records a `/mate-motion` or `/solve` call, not a bare transform PATCH).

### Tests (backend; client needs none for F1 beyond an existing-flow smoke test)

Extend `backend/tests/test_mate_pattern_copy.py` (some existing assertions change on purpose: a copy is no longer
always frozen — say which in the report):
- B mated to copy-of-A; solve with A grabbed and moved → B follows (copy face and B face still coincide).
- Same with a Circular pattern, both `orient_with_rotation` values.
- A fixed → B mate to A's copy still solves B onto it; A never moves.
- PATCH pattern spacing → B moves with the copy, A doesn't; pattern stored; `broken_mate_ids` empty.
- PATCH that makes the mate unsatisfiable (B fixed) → 200, pattern stored, B unchanged, mate reported broken.
- `export_constraint_model` returns `None` for a model with a follower side; `mate-motion` still works.
- The py-slvs fallback is not used for a follower group (no false "converged").
- Coupler/limit mate on a copy → 422.
- Regression: every existing mate/pattern/group-solve test still passes unchanged except the ones listed.

---

## F2. Dissolve pattern

### Behaviour

Dissolving pattern P replaces every **live** copy (not skipped, pattern not suppressed) with a real `Occurrence`, then
deletes P. Nothing visibly moves. Everything that pointed at a copy now points at the new occurrence.

### Backend: `POST /parts/{part_id}/component-patterns/{pattern_id}/dissolve`

Response: `{ "occurrences": [OccurrenceResponse…], "renamed": {"<old copy segment>": "<new occurrence id>"} }`.
Atomic: build everything on copies of the lists, assign at the end.

1. Reject a suppressed pattern with 422 (it has no live copies; the client disables the action).
2. For each source S (in `source_occurrence_ids` order) and each index `i` in
   `expand_component_pattern_instances(P, S.transform)`:
   - new `Occurrence(id=uuid4, external_ref=S.external_ref, part_id=S.part_id, placed_part_id/ref_part_id as S,
     transform=<the copy's pose>, hidden=S.hidden, fixed=False (confirmed: never inherited), suppressed=False, color=S.color,
     name_override=<see naming>)`;
   - insert the new occurrences **right after S** in `part.occurrences`, in index order (instance numbering in the tree
     then reads naturally, `S:1`, `S:2`, …).
3. **Rewrite references** from `S#pattern:P:i` to the new id, in **every Part of the document** (mates/overrides in a
   parent assembly can reach the copy through a longer path `outer/…/S#pattern:P:i/inner`). Add
   `occurrence_paths.rewrite_segment(document, from_part, path, owner_part_id, old_segment, new_segment)` built on
   `walk_segments` (only rewrite the segment read in `owner_part_id`). Apply it to:
   - mate references (`occurrence_id`, `midplane.b_occurrence_id`) of every Part;
   - `appearance_overrides[*].path` of every Part;
   - every scene's `overrides[*].path` of every Part.
4. **`scope: "pattern"` appearance overrides of P** paint the **source and** every copy (`appearance.py` ~174: the
   segment matches when it *is* the source or starts with `<source>#pattern:<P>:`). Replace each with plain path
   overrides on the source **and** each new occurrence, so nothing changes colour. Precedence matters: a named path
   already beats `scope: "pattern"` on the same node, so where the source or a copy already has its own path override,
   **merge** — keep that override's fields and fill only the fields it leaves unset from the pattern-scoped one —
   instead of adding a second override (two equal-specificity entries would resolve by list order). Then drop the
   pattern-scoped one.
5. Delete P (without the current drop-overrides/drop-mates cascade — everything was rewritten).
6. Validate after: every rewritten mate path resolves (`_check_mate_occurrence_path`), else 500-safe 422 and nothing stored.

### Client

- `assembly_tree_panel.dart` Patterns rows: long-press today goes **straight to the delete confirmation**
  (`onPatternLongPress: _confirmDeleteComponentPattern`, `part_screen.dart` ~25813); right-click shows Edit/Delete
  (`_onPatternContextMenu`, reusing `MateContextMenuAction`). Replace both with one `PatternContextMenuAction
  { edit, dissolve, delete }` action sheet / context menu (touch long-press and mouse right-click show the same
  entries). Dissolve is disabled for a suppressed pattern.
- `_confirmDissolveComponentPattern(pattern)`: an `AlertDialog` — "Dissolve pattern? Its N copies become separate
  components. They no longer update when the source or the pattern changes. This can't be undone." → call the new
  `DocumentApiClient.dissolveComponentPattern(focusPartId, patternId)` (route through `focusPartId`, like
  create/update/delete) → `_refreshAssemblyTree()` + `_refreshAssemblyMesh()`; select nothing.
- No client-side path rewriting is needed: everything is re-fetched.

### Naming (B4 rules)

Default: new occurrences get `name_override = None` when the source has none, so the tree shows `<file>:<n>`. When the
source has a `name_override` (e.g. "Short Rail BOT_RIGHT"), the new ones get `"<override> (2)"`, `"(3)"`, … numbered by
pattern index + 1, so they stay recognisable.

### Interplay with F1

After a dissolve, a part that was mated to a copy is mated to an ordinary, **floating** occurrence - always floating,
even when the source was fixed (confirmed). The former copy no longer follows the source and can itself be moved by
later solves. The dialog text says so.

### Tests

Backend (`backend/tests/test_component_pattern_dissolve.py`):
- Linear 2×2 grid and Circular: N new occurrences at exactly the copies' world poses (compare `assembly-mesh` before/
  after — every instance at the same world transform, the copy paths replaced by plain ids); pattern gone.
- Skipped indices produce no occurrence.
- A mate on a copy now names the new occurrence and still solves; a mate in a parent assembly reaching the copy through
  a nested path is rewritten.
- A path appearance override and a scene override on a copy are rewritten; a `scope: "pattern"` override becomes per-
  occurrence overrides on the source and every new occurrence and the painted colours are unchanged (`assembly-mesh`
  appearance per instance), including a copy that also had its own path override (merged, not duplicated).
- Suppressed pattern → 422, nothing changes. Unknown pattern → 404.
- Native export/import round trip after a dissolve.
- Naming: with and without a source `name_override`.

Client:
- `assembly_tree_panel_test.dart`: long-press on a pattern row shows Edit / Dissolve / Delete; Dissolve disabled when
  suppressed.
- `part_screen_test.dart` (fake backend: add the dissolve route): Dissolve → confirm → one dissolve call to the focused
  part, tree/mesh refreshed; Cancel → no call.
- `document_api_client_test.dart`: request/response shape.

---

## VR client impact (`DIDSA-UK/didsa-vr`, investigated at 90c6d12)

The VR client (Godot/GDScript) calls the same backend. It never creates, edits or dissolves component patterns, and it
can't pick a pattern copy for a mate (`mates_tool.gd` `_validate_pick` rejects a copy's node because the GLB gives copies
`occurrence_id = ""`, with the misleading message "Can't mate the assembly's own root content"). But it does read mates
made in Flutter, and moves, solves and enforces them. What the changes mean there:

### Additive, nothing breaks

- `MateResponse.status` (new field): VR reads mates as dictionaries and ignores unknown keys.
- `PATCH /component-patterns/{id}` → `broken_mate_ids`, and the new dissolve endpoint: VR calls neither.
- Constraint model: F1 makes `export_constraint_model` return `None` for a group with a follower (no new version).
  VR's `scripts/motion/local_retraction.gd` mirrors the Dart one and only reads the model for limit mates; with no model
  it keeps server projection. **Don't** do the optional "version 7" without also porting it to
  `local_retraction.gd` (it mirrors the Dart and Python ones line for line and shares golden vectors).
- After a dissolve the former copies are ordinary occurrences; VR's `group_index.gd` replays them like any other part
  once VR reloads the assembly. VR doesn't notice another client's edits until it reloads (existing behaviour for any
  Flutter edit), and `appearance_tool.gd` caches the pattern list (`_patterns`) until then.

### VR work (in `didsa-vr`, same session; items V1-V3)

Follow `didsa-vr/CLAUDE.md`: read `docs/status.md`, `docs/backend-api-notes.md` and `tests/README.md` first; GDScript only;
a new test file goes in `tests/run_all.sh` and gets a row in `tests/README.md` (live-backend ones also in
`tests/e2e_ci_list.txt`); update `docs/status.md` and `docs/backend-api-notes.md`; say what headless tests could not
verify, and never claim "works on the headset".

**V1 - copy mates fold to their source (fix now; already broken on CAD `main`).** `scripts/mates_tool.gd`
`mate_ref_top()` (~1574) only splits on `/`, so a Flutter-made mate on a copy puts `A#pattern:P:i` into `_mated_ids`.
"Enforce all" (`enforce_all`, ~1123) then calls `POST /parts/<owner>/occurrences/A#pattern:P:i/solve`; the `#` starts a
URL fragment, so the request is mangled (best case 404, worst case it solves the wrong occurrence). The same set drives
`is_mated()` (~1677) and the save gate (~1853), so a source whose only mates are on its copies is treated as unmated
and moved without a solve.
- Fix: in `mate_ref_top`, after taking the first `/` segment, strip a `#pattern:` suffix (reuse
  `GroupIndex.base_segment`, `scripts/group_index.gd`) - the VR mirror of the backend's `mate_ref_drivers` and the
  Flutter fold. Both `mated_tops` callers (the active root, nested states ~1551, other roots ~1662) then see `A`.
- Defensive: any URL built from an occurrence id should never contain `#`; assert it in `solve_occurrence` (push an
  error and skip) rather than send a mangled request.
- This works against the backend as it is today (the copy side is frozen there) and is what F1 needs, so it can land
  before or after the backend work.
- Tests (`tests/nested_mates.gd`, SMOKE lines): a mate on `A#pattern:P:1` marks `A` mated and not the copy id; a nested
  `S/A#pattern:P:1` marks `S`; a Width mate whose `midplane.b_occurrence_id` is a copy marks its source;
  `enforce_all` with such a mate solves `A` (stub `_api_request` and check no requested path contains `#`).

**V2 - copies move with their source.** `_adopt_backend_poses` (~2407) re-reads `GET .../occurrences` and moves nodes
by occurrence id; a copy's node has `occurrence_id = ""`, so it never moves until the GLB is reloaded. With F1, dragging
A in VR moves B on the server (VR adopts B's pose) while A's copy stays put, so B looks detached.
- Fix: after the existing occurrence pass, if the scope has any node whose `instance_path` contains `#pattern:`, call
  the new `GET /parts/<root>/assembly-mesh?geometry=false` (below) - `<root>` is the node's `group_root` meta
  (`group_index.gd`: the world's loaded root, or a room's Part for a room's nodes), since `instance_path` is relative
  to the Part that GLB was loaded for - and set each copy node's world transform from the
  instance whose `occurrence_path` joined by `/` equals the node's `instance_path` (mm -> m via `spawn_scale`, the same
  conversion the GLB load uses). Include the copy moves in the same undo entry (`_push_group_move`). Skip the request
  when there are no copy nodes. If the backend is older (the query parameter ignored, geometry returned), still use the
  instances - only slower.
- Also call it after `enforce_all` and after a relaxed-sandbox return, where poses are adopted the same way.
- Live drag: copies still only catch up when the drag's pose is committed (no per-frame update). Record that in
  `docs/status.md` as a known limitation.
- Tests: a pure helper `copy_poses_from_instances(instances: Array, spawn_scale: float) -> Dictionary`
  (`instance_path -> Transform3D`) with SMOKE cases (a top-level copy, a nested copy, a non-copy ignored, unit
  conversion); an e2e test (`tests/e2e_pattern_follow.gd`, add to `e2e_ci_list.txt`) on a running backend: import a
  part, place two occurrences A and B, create a Linear pattern of A, mate B to a copy face, move A, solve, assert B
  moved by the same offset and A's copy node is at A's pose plus the pattern step.

**V3 - parity (smaller, same session).**
- Mate to a copy in VR: in `mates_tool.gd` `try_pick`, when `occ_ref.occurrence_id == ""` and the node's
  `instance_path` contains `#pattern:`, use the copy's segment (the last path segment read in the node's
  `owner_part_id`) as `occurrence_id`. Keep refusing true root content. Make the rejection text for root content
  unchanged and add a test that a copy pick is accepted and builds the right `MateEntityRef`.
- Broken mates: show `status == "broken"` in the tablet's mate list (`scripts/ui/tablet_pages.gd`) in the theme's
  error colour with "Broken" after the name; a tablet test with a fake list.
- Copy names: label copies like Flutter (`<source name> [<pattern name> #<index + 1>]`, pattern name as Flutter's
  `componentPatternDisplayName`: "Linear N"/"Circular N" by position in the Part's pattern list) in
  `group_index.gd` `_tag_pattern_copy` instead of `"<name> (copy <i>)"`; the pattern list is already fetched by
  `appearance_tool.gd` - if it is not available at tagging time keep the old label rather than adding a request.

### One backend addition for VR (include in the CAD work)

`GET /parts/{part_id}/assembly-mesh?geometry=false` (default `true`, unchanged): the same `instances` list (each with
`occurrence_path` and world transform, copies included) but empty `geometry`, so VR (and Flutter, if useful) can
refresh every instance's pose - copies and nested parts included - without downloading meshes. Implement by skipping
`_geometry_for` in `get_assembly_mesh`'s walk, and skip `_paint_json_instances` too (its per-face painting reads that
geometry) or limit it to the node-level appearance. Test: same instance paths and transforms as the full response, no
geometry; record it in `didsa-vr/docs/backend-api-notes.md` when the VR task picks it up.

## Product decisions (confirmed)

1. A pattern edit that breaks a mate on one of its copies is **applied**; the mate is left **broken**, its row is shown
   in the error colour in the Assembly tree, and it flashes after the edit (see "Broken mates").
2. Dissolved instances are **always floating** - Fix/Float is not inherited from the source.
3. Dissolved instance names: no source override → `<file>:<n>`; source override → `"<override> (n)"`.
4. The Patterns row in the **Assembly tree** is the place (not Part-lens body patterns), and its long-press becomes the
   Edit / Dissolve / Delete menu.

## Files (expected)

Backend: `app/document/assembly.py`, `assembly_group.py`, `router.py` `get_assembly_mesh` (`geometry=false`), `constraint_model.py` (None for followers), `router.py`
(pattern PATCH re-solve + `broken_mate_ids`, mate `status`, dissolve route, mate validation for couplers/limits, cleanup across Parts),
`occurrence_paths.py` (`rewrite_segment`), `appearance_routes.py` / `scenes_routes.py` (rewrite helpers), `schemas.py`
(dissolve response), tests. Client: `assembly_tree_panel.dart`, `part_screen.dart` (`_isMated`), `viewport3d/width_pick.dart` (`mateTopLevelOccurrences`, 4 call sites), `api/document_api_client.dart`, a new
`pattern_context_menu.dart` (or extend `mate_context_menu.dart`), tests. Docs: a §2aa entry in `docs/assembly-scope.md`.

VR (`didsa-vr`): `scripts/mates_tool.gd` (`mate_ref_top`, `solve_occurrence` guard, `_adopt_backend_poses`,
`try_pick`), `scripts/group_index.gd` (copy labels), `scripts/ui/tablet_pages.gd` (broken mates), tests
(`tests/nested_mates.gd`, new pure-helper SMOKE cases, `tests/e2e_pattern_follow.gd`), `tests/run_all.sh`,
`tests/README.md`, `tests/e2e_ci_list.txt`, `docs/status.md`, `docs/backend-api-notes.md` (`geometry=false`, mate
`status`, `broken_mate_ids`, dissolve), `CHANGELOG.md`.

## Verification

```
/opt/sdks/micromamba run -n didsa-backend python -m pytest backend/tests/ -q -n 4
cd client && flutter analyze && flutter test
# VR (from the didsa-vr root; tools/setup_test_env.sh installs Godot 4.7.2 and the rest if missing)
GODOT=/path/to/godot tests/ci.sh
GODOT=/path/to/godot tests/ci_e2e.sh   # with a local backend from this CAD branch: tools/start_backend.sh
```
