# Bug report 2026-10-14 (flat app) — investigation and implementation plan

Source: tester report against the latest flat (Flutter) client build, with two
attached files, `Frame_A.DIDSAprt` (800 mm 60x60 box section, mitred ends) and
`Frame_B.DIDSAprt` (the same part, 1600 mm, made by Save As of A and then
editing it).

This doc is written for a **follow-up implementation session**. Each item has
the root cause (with code pointers as of `b4ca653`), the planned fix, and the
tests to add. Line numbers drift; search for the named symbol if a line is off.

Suggested order: **3 → 1 → 2 → 5 → 4 → 6 → 8 → 7**. Item 3 can corrupt
saved data, items 1 and 2 share code with it, and the rest are UI-only.

---

## 1. The title bar shows "Part 1" after Open instead of the file name

**Root cause.** `PartScreen._displayPartName` (`client/lib/viewport3d/part_screen.dart`,
around line 22009) only uses `_lastSavedFileName`, falling back to `_part.name`.
`_lastSavedFileName` is seeded only from `PartScreen.initialFileName`, and
only `_openBundlePayload` passes that. Every single-Part file (including both
attached files) is project-shaped (`isBundleShapedNativeFile` == false), so
Open goes through `_openComposedProject` (around line 10200). That pushes the
new screen with `initialProjectRoot`/`initialRelativePathByPartId` and **no
`initialFileName`**, so the title falls back to the backend Part name, which
is always `"Part 1"`. The bug shows on every platform.

Project-mode Save As (`_saveFocusedPartAs`) also never updates the title.

**Fix.**
- Change `_displayPartName` to this precedence:
  1. If `_projectRoot != null`, use the basename of
     `_relativePathByPartId[_part!.id]` (the **root** Part's file), without the
     `.DIDSAprt` extension.
  2. Otherwise use `_lastSavedFileName`, as today.
  3. Otherwise use `_part?.name ?? 'Part'`.
- With that change, project-mode Save As updates the title automatically,
  because it already rewrites `_relativePathByPartId`.
- Optional: add a `•`/`*` dirty marker to the title from `_isDirty`, which is
  already tracked.

**Tests.** Add a widget test: a `PartScreen` given `initialProjectRoot` and
`initialRelativePathByPartId {root: 'sub/Frame_A.DIDSAprt'}` shows
`Frame_A` in the AppBar. Add a second test that the title updates after
`_relativePathByPartId` changes (Save As).

---

## 2. Save behaves like Save As, and you cannot overwrite the original

**Root cause.** Plain Save has two bodies (`_saveNativeFile`, around line 9800):

- **A Project exists** (`_projectRoot != null`, e.g. the session came from
  Open): this calls `_saveFocusedPart`, which overwrites silently through
  `StorageService.writeFile`. The SAF version prefers `writeFileUriBytes` on
  the existing URI, so it overwrites correctly. This path is fine.
- **No Project** (a session that began with New, or the first launch): Save
  writes only to `_lastSavedFilePath`, and that field is set only when
  `_canPersistFilePathForReuse` is true (desktop). On Android and iOS it is
  always null, so **every Save falls back to
  `FilePicker.platform.saveFile`**. On Android that is `ACTION_CREATE_DOCUMENT`,
  which can never overwrite. Picking the same name gives
  `Frame_A (1).DIDSAprt`, then `(2)`, and so on. That matches what the tester
  saw: the same dialog as Save As, and a growing pile of files. The session
  also never becomes project-backed after that save, so the next Save repeats
  the dialog.

**Target convention.**
- **Save:** if the document has a known location, overwrite it silently.
  Otherwise, behave exactly like Save As.
- **Save As:** always prompt. On success, the open document *becomes* the new
  file: the title, the path used by later Saves, and its identity (see item 3)
  all switch to it.

**Decision (tester, 2026-10-14): Option A, a project folder.** Every
native Save on Android goes through a persisted SAF folder grant
(`StorageService`/`SafStorageService`, which already exists and already
overwrites in place through `writeFileUriBytes`). The rejected options were:
- B: a persisted single-file URI. It can't serve assemblies, which need
  sibling files, and it needs native `ACTION_CREATE_DOCUMENT` code.
- C: app-private storage. Files are hidden from other apps and lost on
  uninstall.
- D: `MANAGE_EXTERNAL_STORAGE`. Play Store policy and user trust.

B may be added later as a convenience for loose single files, but it is out of
scope here.

**Behaviour after the fix (Android):**

| Situation | Save | Save As |
|---|---|---|
| New Part, no folder ever granted | The SAF folder picker opens once, then the name prompt, then the file is written. | The same as Save. |
| New Part, a folder granted earlier (`lastUsedProjectRoot` still valid) | Name prompt only (it shows the folder and has Change Folder), then the file is written. | The same as Save. |
| Part already has a file (opened, or saved once) | **Silent overwrite**, no dialog, "Saved" snackbar. | Name prompt, then a new file with fresh ids (item 3). The session switches to the new file. |
| The grant was revoked, or the file was deleted or moved since | The write fails, so show an error and fall back to the Save As flow, which re-prompts for the folder if needed. Never fail silently. | The same as Save. |

**Fix.**
1. **Stop using `FilePicker.platform.saveFile` for native saves on mobile**
   (`!_canPersistFilePathForReuse`). In `_saveNativeFile` and
   `_saveAsNativeFile`, replace the project-less mobile branch with a new
   `_firstSaveIntoProject({required bool isSaveAs})`:
   - `final root = await _ensureProjectRoot()`. This reuses the last
     remembered folder if its grant is still held, and otherwise shows the
     SAF folder picker. If the user cancels, abort with no state change and
     leave `_isDirty` as it was.
   - `final path = await showRelativePathPromptDialog(context, title:
     'Save "<name>" as…', initialValue: <part name>, root: root,
     onRootChanged: …)`. Wiring `onRootChanged` makes Change Folder available
     on first save. Cancel aborts.
   - `await _assemblyDocumentClient.savePart(root, _part!.id, path, extras:
     <root extras, see 3>)`.
   - `setState(() { _projectRoot = root; _relativePathByPartId = {...,
     _part!.id: path}; _isDirty = false; })`, then show a "Saved to <path>"
     snackbar.

   From then on `_projectRoot != null`, so plain Save takes the existing
   `_saveFocusedPart` route, a silent overwrite, and Save As takes
   `_saveFocusedPartAs`. Item 1's title change makes the title read the new
   file name straight away.
2. **Write failure falls back to Save As.** In `_saveFocusedPart`, a
   `StorageException` from `savePart` currently only sets `_errorMessage`.
   Keep the message ("Couldn't write <path>: <reason>"), then offer the
   Save As flow. If the failure looks like a lost grant, re-validate with
   `_storageService.lastUsedProjectRoot()` (it re-checks with `stat`), and if
   that is null, clear `_projectRoot` so `_ensureProjectRoot` re-prompts for
   the folder. `_isDirty` stays true until a write really succeeds.
3. **Avoid losing the client-only extras.** `savePart` writes
   `exportNative(partId:)`, which leaves out the `hidden_feature_ids`/
   `section_planes` keys that the old `_buildNativeExportBytes` added. Give
   `AssemblyDocumentClient.savePart` an optional
   `Map<String, dynamic>? extras`, merged into the top-level payload before
   encoding, and pass the root Part's two keys whenever the Part being saved
   is `_part!.id`. This applies to every save that goes through `savePart`:
   `_saveFocusedPart`, `_saveFocusedPartAs`, the new first save, and
   `saveAll`'s root entry. Desktop's project-mode saves also stop losing
   them as a side effect. `_openComposedProject` must read these keys back
   for the root file, as `_openBundlePayload` already does, so they
   round-trip. Pass them through `initialHiddenFeatureIds`/
   `initialSectionPlanes`.
4. **Changes to the name prompt** (`relative_path_dialog.dart`
   `showRelativePathPromptDialog`):
   - Show the current folder ("Folder: <root.displayName>"), so a silently
     reused folder is visible and Change Folder makes sense.
   - Reword the collision warning from "Save All will overwrite it" to "A
     file with this name already exists and will be replaced."
   - Add a `confirmText` parameter (default "Save") so the button matches
     the action.
5. **Save As to the same path** as the current one is a plain Save: no
   identity re-mint (item 3) and no reopen.
6. **Desktop stays as it is** for silent overwrite (it already works). For
   one mental model on both platforms, after a desktop dialog save also set
   `_projectRoot = DesktopProjectRoot(p.dirname(savedPath))` and
   `_relativePathByPartId[_part!.id] = p.basename(savedPath)`. Plain Save
   then takes the same `_saveFocusedPart` route there too. Keep the
   whole-session bundle dump (`_buildNativeExportBytes` and the dialog)
   only for sessions opened from a legacy bundle-shaped file.
7. **Clean-up.** `_lastSavedFilePath` and `_saveNativeFileViaDialog` become
   desktop-only, or dead code once 6 lands. Remove whatever has no caller
   left, and update the long doc comments on `_saveNativeFile`/
   `_saveAsNativeFile` that describe the old mobile dialog fallback.

**Tests.** Use a fake `StorageService`, through the existing seams
`storageService` and `canPersistFilePathForReuse: false`, plus a fake
`AssemblyDocumentClient`:
- A fresh Part with no remembered folder: Save picks the folder once,
  prompts for the name once, and writes once. A second Save writes to the
  same relative path with no picker and no prompt.
- A fresh Part with a remembered folder: Save prompts for the name only.
- Cancelling the folder picker or the name prompt writes nothing and leaves
  `_isDirty` true.
- Save As prompts and rebinds `_relativePathByPartId`, and the title
  follows. Save As to the same path does no re-mint.
- `savePart` throwing `StorageException` shows an error, keeps `_isDirty`,
  and the Save As flow is offered.
- The root Part's `hidden_feature_ids`/`section_planes` are in the written
  bytes and restored after `_openComposedProject`.
- `AssemblyDocumentClient.savePart` with `extras` merges the keys at the top
  level. This is a plain unit test.

Respect `docs/flutter-widget-test-lessons.md` (real async I/O chains don't
settle inside `testWidgets`; keep the I/O behind fakes).

**Manual check (Android device).**
1. New part, then Save: folder picker (first time only), then name, then
   the file appears in the chosen folder.
2. Edit, then Save: no dialog, and the same single file is updated. Check
   its modified time in a file manager, and that there is no `(1)` copy.
3. Kill the app and relaunch, then Open the file, edit it and Save: a silent
   overwrite.
4. Revoke the folder permission in Android settings, then Save: an error,
   then the folder is re-prompted.

---

## 3. Frame_A and Frame_B arrive in an assembly at the same length (high priority, data integrity)

**This is not a mesh cache.** It is an identity collision. Both attached
files share the same `document.id` (`c5ebe226…`), the same Part id
(`fffa86c4-e927-4a51-aa72-281da85a99eb`) and the same sketch ids
(`b6d0d58d…`, `8972570e…`, `b9f081b9…`). The content differs, though: B's
`b9f081b9` sketch has different entities, and B has extrude `55be2a45…` where
A has `9333651c…`. Save As copies the Part verbatim. Nothing ever re-mints ids,
and **every assembly merge path dedups by Part id and sketch id, assuming
that the same id means the same file:**

- `client/lib/assembly/add_component.dart` `mergeComponentIntoDocument`:
  `currentPartIds.contains(part['id'])` drops the incoming Part. The sketches
  are deduped the same way.
- `backend/app/document/add_component.py` `merge_component_into_document`
  is a 1:1 port with the same dedup. It is used by the VR client's
  add-component.
- `client/lib/assembly/assembly_graph_composer.dart` `compose()`: dedups by
  path, but then puts both Part dicts into `parts` and merges sketches into
  `sketchesById`. The backend `import_native` keys `document.parts` by id, so
  the **last one read wins**, and the sketches can come from the other file.
  `relativePathByPartId` inverts to a single entry, so one of the two files
  disappears from the save map.

**Reproduced** (Python, `merge_component_into_document` with the attached
files): after adding A and then B, the merged document has one component
Part. Both occurrences have `resolved_part_id = fffa86c4…`, and that Part has
the 800 mm boss. B's 1600 mm Part is silently discarded.

**Consequences beyond the visual bug.** On reopen, the composed graph can mix
B's features with A's sketches (or the reverse). A Save All then writes that
mixed Part to whichever single path survived in `relativePathByPartId`. That
is a real risk of silently corrupting a part file. Fix this first.

**Fix (both halves needed).**

*a. A shared re-mint helper.* Add `remintNativeIdentity(Map payload, {Set<String>? onlyIds})`
in Dart (`client/lib/assembly/remint_identity.dart`) and
`remint_native_identity(payload, only_ids=None)` in Python
(`backend/app/document/native_format.py` or a sibling module):
- Collect the ids to replace: `document.id`, every `parts[].id`, and every
  `sketches[].id`, optionally restricted to `onlyIds`. Map each to a fresh
  UUID v4. The client already depends on `uuid`.
- Walk the whole JSON tree and replace every **string value** exactly equal
  to an old id. UUIDs are unique strings, so this catches every reference
  without listing reference sites. Those sites include
  `SketchFeature.sketch_id`, `profile_refs[].sketch_id`,
  `root_part_id`, occurrence `resolved_part_id`, and any future field.
  Dict keys are left alone: `body_material_assignments` keys are feature ids,
  which are Part-scoped and don't need re-minting.
- Feature, entity and point ids stay as they are. They are scoped to the Part
  or sketch: routes are `/parts/{part_id}/features/{feature_id}` and the body
  cache is keyed by Part id. Only the session-global stores (parts in the
  document, sketches in `app/sketch/store.py`) collide.
- Unit-test both implementations against the attached files, which are good
  fixtures (copy them into `backend/tests/fixtures/` and `client/test/fixtures/`).
  Check that A's ids are gone, all references are consistent, and a
  backend `import_native` of the result succeeds.

*b. Stop creating collisions: Save As re-mints.*
- `_saveFocusedPartAs` and the project-less Save As from item 2 write
  `remintNativeIdentity(exportNative(partId))` to the **new** path. Skip this
  when the new path equals the current one.
- If the focused Part is the **root** Part, the session must become the new
  file (normal Save As convention). After a successful write, reopen it with
  `_openComposedProject(root, newPath)`, the same `pushReplacement` Open
  already uses, so in-session ids match the file. That is the simplest
  correct option. The alternative, re-keying every Part-id-keyed state map
  in place (`_hiddenFeatureIdsByPart`, `_sectionPlanesByPart`, the focus
  stack, `_relativePathByPartId`), is fragile.
- If the focused Part is a **sub-component** (assembly focus), treat Save As
  as "Save a copy": write the re-minted copy and keep the assembly pointing
  at the original. Say so in the snackbar ("Saved a copy as …"). Repointing
  the occurrence to the copy (SolidWorks "replace component") is a possible
  follow-up and is out of scope here.

*c. Heal existing collisions on import (fixes files already on disk,
including the tester's Frame_B).*
- **Composer:** keep `pathByPartId`. When a newly read file's Part id is
  already claimed by a *different* relative path, re-mint that file's payload
  (its Part id plus its own sketch ids) before folding it in. Do the same for
  any sketch id that is already present with different content. The re-minted
  ids live only in the session; the next Save of that Part writes them to
  disk, so the files heal themselves.
- **Add Component (Dart):** give `mergeComponentIntoDocument` the session's
  `relativePathByPartId` (or a `isSameSource(partId)` callback). If the
  incoming root Part id already exists in the session but came from a
  different file (or from an unknown source), re-mint the incoming payload
  before merging. If it is the same file, keep today's dedup (two occurrences
  of one Part is correct). Keep the existing "Cannot insert a Part into
  itself" check, but run it *after* the source comparison, so a Save-As copy
  of the open Part can still be inserted.
  Call sites: `part_screen.dart` `_onInsertComponentPressed` (around line
  12055), the Create Component path (around line 12209), and
  `ai/ai_plan_translator.dart` (around line 869).
- **Add Component (backend, for VR):** in `merge_component_into_document`,
  when the incoming Part id exists and the existing occurrences that resolve
  to it carry a different `external_ref` than the incoming `external_ref`
  (or there is none), re-mint before merging. Mirror the Dart behaviour.

**Tests.**
- Backend `tests/test_add_component.py`: adding A then B gives two distinct
  component Parts, the boss `end_distance`s are 800 and 1600, and the
  occurrences resolve to different Parts. Adding A twice still dedups to one
  Part.
- Client `add_component_test.dart`: the same cases.
- Composer test: two files with the same Part id at different paths produce
  two Parts and two entries in `relativePathByPartId`.
- Save As test: the written file's Part id differs from the session's
  original Part id.

**VR note.** The fix in `backend/app/document/add_component.py` covers DIDSA-VR's
add-parts path, so the VR repo needs no change. Its own `mesh_identity.gd`
keys by occurrence/body. Re-check that if VR shows the same symptom after the
backend fix.

---

## 4. The multi-select drawer covers the tree, so rows can't be selected

**Root cause.** While a tree multi-select session is active,
`SelectionListDrawer` (with `MultiSelectActionBar` as its header) is placed
`Positioned.fill` *above* both tree panels (`part_screen.dart`, around line
22813, "Stacked *above* both tree panels"). It is a `DraggableScrollableSheet`
taking 18–40 % of the height, full width minus the 72 px FAB clearance. The
tree panel is top-left, full height, and 66 % wide on portrait phones, so the
bottom 18–40 % of the tree's rows sit under the sheet and can't be tapped.
The sheet's list of selected rows also repeats information the tree already
shows with its checkmarks.

**Options considered:**

| | Option | Pros | Cons |
|---|---|---|---|
| **A (recommended)** | **Dock the action bar inside the tree panel.** In multi-select mode, the tree panel's own header row is replaced by `MultiSelectActionBar` (count, Hide/Show, Delete, More, Cancel), like Android contextual action bars (Files, Gmail). There is no bottom sheet; the selected rows are already highlighted in the tree. | Removes the overlap entirely. Selection and actions sit together. Less UI. | Loses the per-row "remove" X list. Unticking the row in the tree does the same job. Slightly more change in `FeatureTreePanel` and `AssemblyTreePanel` (both get an optional `multiSelectHeader` widget slot). |
| B | **Keep the sheet, inset the tree.** Listen to the sheet's extent (`NotificationListener<DraggableScrollableNotification>`) and pass it to the tree panels as `bottomInset`, applied as `ListView` bottom padding. | Smallest change. Every row can be reached by scrolling. | The tree's visible area shrinks by up to 40 %. Two lists of the same selection stay on screen. |
| C | **Shift the sheet right of the tree** (`left: treePanelWidth`). | No overlap and no tree change. | On a portrait phone (66 % tree width, minus the 72 px FAB clearance) the sheet is about 50 px wide, which is unusable. Works only on tablet or landscape. |
| D | **Collapse the sheet to the action bar only** (no item list), with `maxChildSize` equal to the bar's height. | Trivial. | Reduces the overlap (about 56 px) but doesn't remove it. The last row or two still needs a scroll that isn't padded. |

**Decision (tester, 2026-10-14): Option A.** Implement A; B is not needed.

**Fix (option A).**
- Give `FeatureTreePanel` and `AssemblyTreePanel` an optional
  `Widget? multiSelectHeader`. While it is non-null, it replaces the panel's
  normal title row (the title and the Close button) at the top of the panel,
  in the panel's own `Material`, and the row list keeps the rest of the
  height.
- In `PartScreen`, pass `MultiSelectActionBar(...)` (unchanged widget: count,
  Hide/Show, Delete, More with exactly 1 selected, Cancel) as
  `multiSelectHeader` to whichever tree panel is built while
  `_activeMultiSelect != null`.
- Delete the `if (_activeMultiSelect != null) Positioned.fill(child:
  SelectionListDrawer(items: _multiSelectDrawerItems(), …))` block (around
  line 22813). Remove `_multiSelectDrawerItems()` and
  `SelectionListDrawer.items`/`SelectionListDrawerItem` if nothing else uses
  them.
- Rows deselect by tapping the row again (`onMultiSelectToggle`, which
  already exists). Make sure the selected-row highlight and checkbox are
  clearly visible, since the separate list is gone.
- Narrow panels: `MultiSelectActionBar` already scales its button cluster
  down. Check it at the 66 %-of-portrait default width and at the minimum
  drag width, and switch to icon-only buttons with tooltips if it gets
  cramped.
- If the tree panel is closed while multi-select is active, its existing
  `onClose` already calls `_exitMultiSelect()`. Keep that.

**Tests.** A widget test with a tree long enough to reach the bottom of the
screen: in multi-select mode, tapping the last visible row toggles its
membership. That test fails today because the tap hits the sheet.

---

## 5. Mate face picking: entities behind the face win the ray

**Root cause.** Mate authoring picks on placed occurrence geometry through
`hitTestComponentInstanceEntities` (`client/lib/viewport3d/selection_hit_test.dart`,
around line 2053, called from `PartViewport._hoverHitTestComponentEntities`).
That function chooses `bestVertex`/`bestEdge` purely by **screen-space pixel
distance** across every occurrence and body, then returns vertex before edge
before face. It **never compares their depth with the nearest face**. A
vertex or edge on the far side of the same part, or on another part behind
it, that projects within tolerance of the cursor beats the face you're
looking at. The only filter is the "face local size" tie-break, which ignores
depth.

The root-Part path `hitTestBodies` already fixed exactly this
("I'm able to pick edges through faces"): it drops a vertex or edge whose
`rayT > bestFace.rayT + kFaceOcclusionEpsilon` when faces are drawn filled
(`facesOccludeOtherHits`). The component-instance path never got the port.

**Fix.**
- Add a `facesOccludeOtherHits` parameter to
  `hitTestComponentInstanceEntities`. When it is true, run the face
  ray-test whenever any filter is on, not only face/body, and null out
  `bestVertex`/`bestEdge` behind `bestFace` by the same epsilon rule,
  *before* the existing face-local-size tie-break. Pass it from
  `_hoverHitTestComponentEntities` the same way the root path does
  (`renderMode.showsFilledFaces && !bodiesHidden`).
- Occluders should include every *rendered* instance, including
  non-selectable or dimmed ones outside the focus path, and the root Part's
  own bodies (`meshHit`). A part in front still blocks picks behind it even
  when it isn't selectable. Practically: compute the nearest face `rayT`
  over all instances (selectable or not) as an occluder depth, separate from
  `bestFace` (selectable only). Then in `_recomputeHover`, also drop a
  `componentEntityHit` vertex/edge that sits behind `meshHit`'s face `rayT`.
- Also check `hitTestAllComponentInstanceCandidates` (Select Other) sorts by
  `rayT`, so the nearest face is listed first.

**Tests.** Pure hit-test unit tests in `selection_hit_test_test.dart`:
- Two stacked box instances: a ray through the front face, near the
  projection of a back-box vertex, returns the front **face**.
- The same with the back vertex on the *same* instance.
- In wireframe (`facesOccludeOtherHits: false`) the old behaviour is kept.

---

## 6. The assembly selection drawer needs a close button

**Root cause.** `AssemblyComponentSelectionDrawer`
(`client/lib/viewport3d/assembly_component_selection_drawer.dart`) only
offers Move, Fix/Float and Delete. The only way out is to tap empty space.
The same is true of the Part-lens `SelectionListDrawer` that opens for a
selection inside a focused part.

**Fix.**
- Add `onClose` to `AssemblyComponentSelectionDrawer`, rendered as an
  `IconButton(Icons.close, tooltip: 'Clear selection')` at the end of the
  title row. In `PartScreen`, wire it to
  `setState(() { _selectedOccurrenceId = null; _selectedEntities = {}; })`,
  matching whatever `_onOccurrenceTap` does when it deselects.
- For consistency, give `SelectionListDrawer` an optional `onClearAll`, with
  the same X at the top-right of the sheet next to the drag handle, and wire
  it in the Part-lens instance. "Assembly focus" in the report could mean
  either drawer, so do both.

**Tests.** A widget test: select an occurrence, tap the close button, and the
drawer is gone and the selection is cleared.

---

## 7. A "fully constrained" flag on parts in the assembly tree

**Today.** The tree shows a push-pin for `fixed` occurrences only.
Constraint state is computed only on demand for the occurrence being dragged
(`_motionStatusText`, "Group: 5 DOF", from the motion session), never for
every row.

**Fix.**
- **Backend:** add `GET /document/parts/{part_id}/constraint-status`,
  returning `{occurrence_id: {status, dof}}` with `status` one of
  `fixed | fully_constrained | under_constrained | over_constrained`.
  Implement it in `assembly_group.py` with the existing analysis, and no new
  maths:
  - `fixed`: `occurrence.fixed`.
  - For each mate-graph component not yet visited (`discover_component`),
    run `build_group_model` and `analyze_model` once. For each member:
    `mobility[oid] == 0 and grounded`, with `quality.residual_inf <= tol`,
    gives `fully_constrained`. `residual_inf > tol` (mates contradict) gives
    `over_constrained`. Anything else gives `under_constrained`, with
    `dof = mobility[oid]`.
  - An unmated, unfixed occurrence is `under_constrained` with dof 6.
  - Note the subtlety: a group can have every member at mobility 0 but be
    ungrounded. Then the whole group still floats as one rigid body, so its
    members are *under*-constrained. That is why the `grounded` condition is
    needed.
  - Add tests in `tests/test_assembly_group.py`: a plate fixed and a part
    with 3 coincident face mates gives fully; one mate gives under; a
    floating mated pair gives under.
- **Client:** fetch it in `_refreshAssemblyTree`, next to `listOccurrences`
  (it is already refreshed after mate add, delete or edit and after moves).
  Pass `constraintStatusByOccurrenceId` to `AssemblyTreePanel`. Render a
  compact badge in the row's trailing cluster: a ✓ / lock glyph for fully
  constrained, "(−)" or a hollow icon with a DOF tooltip for under, a warning
  icon for over, and keep the push-pin for fixed. Mind the trailing-width
  note in `assembly_tree_panel.dart` (around line 579) about the badge budget.
  Prefer replacing the pin with a single status icon slot over adding a
  fifth badge.
- Performance: one SVD per component, from a finite-difference Jacobian.
  This is fine for hobby-scale assemblies. Compute it lazily on tree refresh,
  never per frame.

---

## 8. The Add Mate drawer needs a button to clear selections

**Root cause.** `MatePanel` (`client/lib/viewport3d/mate_panel.dart`) lists the
selected references but has no remove or clear control. The only reset is the
implicit "a third distinct tap starts fresh" in `_toggleSelectedEntity`
(`part_screen.dart`, around line 2423), which users don't discover.

**Fix.**
- Add `onClearSelection` to `MatePanel`, shown as a `TextButton.icon`
  ("Clear selection") under the selection rows, only when
  `selectedEntities.isNotEmpty`. Also add a per-row X (`onRemoveEntity`) so
  one wrong pick can be undone without losing the other.
- Wire it in `PartScreen` to clear `_selectedEntities`, then call
  `unawaited(_scheduleMatePreview())` so the ghost preview resets. That is the
  same pattern every other mate-panel callback uses.

**Tests.** A widget test: with two refs selected, Clear selection empties the
list and the Confirm button disables.

---

## Validation checklist for the implementing session

- Backend: `pytest backend/tests/test_add_component.py tests/test_assembly_group.py
  tests/test_stage_native_format.py`, plus the new tests.
- Client: `flutter analyze` and `flutter test`, at least the touched suites
  plus the new ones.
- Manual (Android, the tester's platform for items 2–3):
  - The item 2 manual check above (first save, silent re-save, relaunch,
    revoked grant).
  - Open `Frame_A`: the title reads "Frame_A".
  - New assembly, then add `Frame_A` and `Frame_B`: two different lengths.
  - Save As a part, then add both copies to an assembly: two distinct parts.
  - Mate-pick a face with a part behind it.
  - Multi-select at the bottom of a long tree.
