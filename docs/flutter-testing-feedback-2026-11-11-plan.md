# Flutter testing feedback 2026-11-11: plan

Source: the owner's report from testing the Flutter client on an Android phone.
This doc is for the implementation session. Code pointers were checked against `main` at `cdeb782`.
Line numbers drift, so search for the named symbol if a line is off. Nothing in this plan was run on a device.
The causes in item 1 come from reading the code. They were not reproduced with the owner's files.

| Item | Summary | Kind | Size |
|---|---|---|---|
| 1 | After changing the project folder, sub-assemblies aren't found. Level 1 could be relinked by hand, level 2 could not | Bug + feature | Medium (1a small, 1b-1d medium; VR V1) |
| 2 | Sketch orientation: pick an edge or line to align a sketch axis, then flip / rotate to refine | Feature | Large (backend + client; VR V2 full frame support) |
| 3 | Why are Intersection and Helix one tool? Split the UI, add Edit Intersection Curve | Question + bug + feature | Small-medium |
| 4 | Orientation pill: buttons draw past the pill's rounded ends when the row scrolls | Bug | Small |
| 5 | Revolve: a "thin" option like Extrude's, including open profiles | Feature | Medium-large (backend + client; VR V3) |

Suggested order: **4 → 3 → 1a → 1b-1d → 5 → 2**. 4 and 3 are small, contained fixes. 1a is the bug that stopped the owner.
2 adds another button to the pill, so 4 should land first. The DIDSA-VR parts (V1-V3, near the end) go with their CAD
items: V1 lands **in the same change** as 1b's vectors.

The owner answered every decision on 2026-11-11 (**Decisions**, at the end). The plan below already follows those answers.

## Progress

| Item | What landed | Tests |
|---|---|---|
| 4 | Orientation pill: `Material` now has `StadiumBorder` + `Clip.antiAlias`, the row is a new `EdgeFadeScrollRow` (fades the end that has more content), icon buttons `VisualDensity.compact`, Cancel is an icon button below 400 dp. `component_selection_toolbar.dart` gets the same clip (it was the only other `Material(borderRadius)` around a horizontal scroll view). | `part_screen_test.dart`: on a 360 dp phone the pill's `Material` clips, Cancel is the icon button, Continue is reachable and taps. Full client suite 3758 passed. **Not checked:** how the fade looks on a device. |
| 3 | `CurvePanel` takes a required `mode` and has no toggle (it opened on Helix and a switched Confirm did nothing). New `IntersectionInitialValues`; `PartScreen._openIntersectionCurveForEdit` (Edit from the tree, same dispatch as Helix); `_intersectionSketchChoices` offers only Sketches **before** the curve (the backend does not refuse later ones on PATCH, so this is a client rule); re-picking a Sketch sends `profile_refs_a/_b: []`. `FeatureDto.curveSketchFeatureIdA/B`, `updateCurveFeature(clearProfileRefsA/B)`. New `feature_helix.svg` / `feature_intersection_curve.svg` used by the picker and the tree. The backend type stays one `CurveFeature`. | `curve_panel_test.dart` (each mode shows its own fields, no toggle, initial intersection values), `part_screen_test.dart` (Intersection Curve entry opens the intersection form and Confirm creates `intersection`; Helix entry creates `helix`; Edit opens on the two Sketches, a later Sketch is not offered, PATCH body), `document_api_client_test.dart` (update body, DTO). No VR change, as planned. |

---

## 1. Moved project folder: nested references not found

### What the code does today

- `Occurrence.external_ref` is a path **relative to the project folder** (`ProjectRoot`), not to the file that holds it.
  If the owner picks a different folder, such as the parent of the old one or a folder inside it, **every reference at every
  level** stops resolving by path.
- The moved-files work (`docs/moved-files-scope.md`, F1-F3) then searches by id. `AssemblyGraphComposer.compose` →
  `resolveOccurrence` → `findFile` (`client/lib/assembly/file_lookup_rule.dart`), over `ProjectFileIndex.build`. The index
  **already searches subfolders**: `SafStorageService.listFiles` walks the whole tree, skipping dot-folders, up to 5000 files.
  So the owner's suggestion ("look in sub folders for matching part id") is already built. It only works when the reference
  has a stored id (`ref_part_id`, else `resolved_part_id`) that equals the root Part id of the file on disk.
- **Why level 1 needed hand relinking.** The id step found nothing, so those references had no usable id. Files saved before
  `ref_part_id` existed (F1, around 20 Oct) often have `resolved_part_id: null`, because a single-file reload drops it. Some
  carry a session id from re-minting that the file on disk never had (the known "Not covered" case in the F3 notes). With no
  id, step 3 can only offer a **name suggestion**, which by design (D11) waits for a click.
- **Why level 2 couldn't be done.** Two gaps:
  1. An unresolved child is never opened, so **its own references are never visited**. They are not in the open's report,
     the banner or the Review sheet.
  2. The sheet's **Use** / **Locate...** (`PartScreen._useReferenceFile`, `_locateReferenceFile`) compose the chosen file with
     `_composeProjectFile`. That compose does run the lookup for the grandchildren, but `_relinkOccurrence` **throws away
     `picked.graph.references`**. The F3 notes list this as "Not built: reports for references inside a file brought in with
     Add Component or a Locate pick". So grandchildren the composer could not find quietly stay unresolved.
     The only way to reach them is Make Focus into each sub-assembly and the tree's red link badge, one by one. The tree
     shows one level at a time (`AssemblyTreePanel`). This is the "would have taken ages" route.

**Before starting, reproduce it.** Write a fake-storage test with a 3-level assembly, `root → sub → part`, whose occurrences
have no `ref_part_id` and `resolved_part_id: null`. Move it under a new root, for example prefix every path with `proj/`.
Expect today: `sub` → suggest; `part` → never reported. After Use on `sub`: `part` is still unresolved and not listed. If the
owner can share one of the real files, check what its occurrences store (`ref_part_id` / `resolved_part_id`) and confirm it
is the no-id case.

### 1a. Bug: carry nested reports through Use / Locate / Add Component

- `_relinkOccurrence` (and the Add Component path, `_onInsertComponentPressed`) appends `picked.graph.references` to
  `_referenceReports` after the merge. **Id remapping:** `relocateOccurrenceInDocument` → `_prepareComponent` may re-mint
  the picked payload (`remintNativeIdentity`), so the `parentPartId` in the nested reports can be stale. Make `_prepareComponent`
  return the old→new id map (have `remintNativeIdentity` return it, or diff the root ids), and rewrite each nested report's
  `parentPartId` before adding it. If the picked Part is reused (`reusesExistingPart`), its nested reports were already
  handled when it was first composed: add none.
- The sheet's **Use** for a nested report already works: `_relinkOccurrence(report.parentPartId, ...)` runs
  `relocateOccurrenceInDocument` with `rootPartId: report.parentPartId`, which only needs the Occurrence to be on that Part.
  Add a test that proves this for a level-2 Occurrence.
- When nested reports arrive, keep the sheet open and update its list. `_referenceReports` is a `ValueNotifier` and the
  sheet already listens. Show a short line, "Found 3 more references inside Sub.didsa", so the owner sees why the list grew.
- Show the level in each row: "in Sub.didsa" (`report.parentPath`). Without it, a list that mixes levels is hard to read.

### 1b. Feature: a "folder shift" step in the lookup rule (the main fix)

Changing the project folder adds or removes the **same leading folders** on every path. Use that before falling back to
name-only suggestions.

- **New rule step, between 2 (id) and 3 (name):** *path suffix*. A file in the index matches when its path and the stored
  path are equal after dropping leading segments from one of them. Compare whole segments, with native extension and
  letter case ignored as `lookupNameKey` does: `proj/parts/x.didsa` ↔ `parts/x.didsa`, and `parts/x.didsa` ↔
  `x.didsa`. Count how many trailing segments agree (`k`); prefer the largest `k`.
- **Outcomes:**
  - The reference has a stored id and the suffix match has that id: step 2 already found it. No change.
  - **The reference has no stored id**, and exactly one file has the largest `k`, with `k ≥ 2` (the file's own folder name
    agrees as well as its name): a new result, **`likely`** (`LookupResult.likely`, `via: suffix`, `path` = that file).
    The rule never uses it by itself. **The client asks the user** (Decision 1, below). Two or more files with the same
    largest `k ≥ 2` stay a `suggest`, with the candidates sorted by `k`.
  - `k == 1` (only the name agrees) is today's step 3: a suggestion.
  - A stored id that the suffix file does not carry: still a suggestion, never used (the D11 "never a wrong file" rule stays).
- **Asking the user (Decision 1, Owner).** The composer takes `acceptLikely: bool` (default false). With it false, a
  `likely` reference is left unresolved and reported as `ReferenceOutcome.likely`. Its children are not visited, as for any
  unresolved reference. With it true, a `likely` reference is used as if found (bound, `external_ref` corrected, an unsaved
  change), its children are composed, and it is reported as "found by folder".
  - **Open flow** (`_openComposedProject`, before `importNative`): compose. If the result has `likely` reports, and the
    session preference is not set, show a dialog **before importing**:
    "6 files look like they moved with the project folder" + two or three example rows (`parts/x.didsa` →
    `proj/parts/x.didsa`) + **Use them** / **Not now** + a checkbox **"Don't ask again this session"**.
    - **Use them** re-runs the compose with `acceptLikely: true`, then imports. The `ProjectFileIndex` cache makes the
      second compose cheap: no second folder walk, and the ids are cached. Nested levels below the accepted files can
      themselves be `likely`. The re-compose accepts those too, so one answer covers the whole tree.
    - **Not now** imports as composed. The `likely` references go in the banner and the Review sheet as suggestions, each
      with the one candidate and a **Use** button.
    - **The checkbox** stores the answer for this run of the app. Keep it in memory only, never in preferences, so a new
      session asks again. Hold it app-wide (a small `FolderMatchSessionChoice` singleton or a field on the storage service),
      **not** in `PartScreen` state: Open pushes a fresh `PartScreen`, so screen state would forget it on the next open. While it is set, later opens, and the Use / Locate / Add Component composes (1a), apply the same
      answer without asking. A small line in the Review sheet header shows the stored answer ("Folder matches: used
      automatically this session") with **Ask again** to clear it.
  - The same dialog, and the same session answer, covers 1c's learned shift for id-less files.
- **Shared rule:** this changes the reference implementation, so do it in all three copies:
  `backend/app/document/file_lookup.py` (reference) → `tools/file_lookup_vectors/generate.py` (new vectors: prefix
  added, prefix removed, two equal-`k` candidates → ask/suggest, `k == 1` → suggest, an id present but not matching → suggest)
  → `docs/file-lookup/vectors.json` + `backend/tests/data/file_lookup_vectors.json` (`--check`) → Dart
  `file_lookup_rule.dart` (`LookupResult.likely`, `LookupVia.suffix`, `ReferenceOutcome.likely` and a "found by folder" label,
  `reference_report.dart`) → **DIDSA-VR** `scripts/file_lookup.gd` + `tests/fixtures/file_lookup_vectors.json` (copy) + `tests/file_lookup_vectors.gd`.
  If the VR change isn't made in the same rollout, DIDSA-VR's vector test fails on the new cases. Either change both, or land
  the VR change first, behind its vector file update.

### 1c. Feature: learn the shift once and apply it to the rest

Even with 1b, the owner should never have to do the same move twice.

- **In the composer:** when a reference is found by id (step 2) or by suffix (1b), and the found path is
  `newPrefix + tail` where the stored path is `oldPrefix + tail`, record `oldPrefix → newPrefix`. For each later miss in
  the same compose, try the shifted path first, before the index. A shifted file whose id is the stored id is used and
  reported. A shifted file for a reference **with no stored id** is `likely`, and goes through the same ask-first dialog as
  1b. One id-bearing reference anywhere in the tree then finds the id-less ones that moved the same way, ready for one
  confirmation.
- **In the Review sheet:** when the user picks a file with **Use** or **Locate...**, work out the shift the same way. If any
  other open reports would resolve with it, offer one action: "Apply the same folder change to 6 other references". It runs
  the relink for each, and adds each one's nested reports (1a). Batch the relinks into **one** merge and one `importNative`.
  One import per relink is far too slow on a phone.
- **"Use all single suggestions"** button in the sheet header, for reports with exactly one candidate. It's cheap, and it
  covers what 1b and 1c miss.

### 1d. Make it not happen again

- **Save All writes the ids.** After a repaired open, Save All already writes `ref_part_id` for each resolved reference
  (`AssemblyDocumentClient.savePart`). Make sure the banner says so when the open used suffix or name matches: "Save All to
  record these files' ids, so future moves are found automatically". Also make sure the corrected paths mark every affected
  file unsaved, not just the root. Check this: `bind` writes `external_ref` on child Part dicts, and the Save All dirty set
  must include those child files.
- **Optional, Android:** when the user switches the folder with **Change Folder** in the Open dialog, the old and new SAF
  tree URIs often share a document-id path (`primary:Documents/Proj` vs `primary:Documents`). When one is an ancestor of
  the other, the shift is known exactly and can seed 1c. This depends on the provider, so treat it as a hint only, never as
  the only path. Skip it if it gets fiddly.

### Tests

- `test/moved_files_composer_test.dart`: the 3-level no-id fixture under a new root (prefix added; prefix removed). With
  `acceptLikely: false`: level 1 reported `likely`, levels 2-3 not visited. With `acceptLikely: true`: all levels found by
  folder, reported, `external_ref` corrected at each level. With an id on level 1 only: level 2 and 3
  found through the learned shift (1c).
- `test/file_lookup_rule_test.dart` picks up the new vectors automatically. Check the case count goes up.
- `test/references_sheet_test.dart` / `test/part_screen_test.dart`: Use on a level-1 suggestion adds its nested reports to the
  sheet (1a). Use on a level-2 report relinks the Occurrence on the sub-Part. A Use that re-mints still targets the right
  `parentPartId`. "Apply the same folder change". "Use all single suggestions". The folder-match dialog: Use them
  re-composes with accept and imports once; Not now leaves suggestions; the checkbox skips the dialog on the next open in
  the same session, including in a new `PartScreen`, and applies the stored answer; **Ask again** clears it; nothing is
  written to preferences.
- Backend: `backend/tests/test_file_lookup.py` (new vectors). DIDSA-VR: `tests/file_lookup_vectors.gd`, and
  `tests/moved_files.gd` if its compose gains the learned shift. The VR composer change (1c in `native_compose.gd`) is
  optional, so keep the rule in step even if VR doesn't learn shifts.
- `test/live/moved_files_live_test.dart` (live backend, `DIDSA_LIVE_BACKEND`): one 3-level case moved under a new root,
  opened, Save All, reopened with nothing to report.
- **Cannot be tested here:** SAF on a real phone, including how slow the index walk is on a large folder. The walk does one
  binder call per directory. If the owner picks a very large folder, the first miss can take seconds. Show a "Searching the
  project folder..." progress line while `fileIndex.build` runs.

---

## 2. Sketch orientation: align an axis to an edge or line

### What exists today

- The orientation step (`_PendingOrientationMode.newSketch` from `_addSketchFeature`, `.redefine` from
  `_redefineSketchOrientation`) has rotate ±90°, flip, **Pick origin**, Cancel, Continue/Done (`part_screen.dart`, the
  `_confirmingSketchOrientation && !_pickingSketchOrigin` pill). Flip / rotate are `Sketch.flip` /
  `Sketch.rotation_quarter_turns` (`app.sketch`). The origin is `SketchFeature.origin` (`SketchOrigin`, document layer), set
  with `PATCH .../features/{id}/sketch-origin`.
- Frame: `basis_for_sketch` = `oriented_anchor_basis` (anchor plane → `apply_orientation(flip, quarter turns)`) →
  `basis_with_sketch_origin` (`backend/app/document/create_plane.py`). The client mirrors this in
  `SketchPlaneBasis.withOrientation` / `.withOrigin` (`sketch_geometry_3d.dart`).
- Quarter turns can't express an arbitrary in-plane angle, so aligning to an edge needs a new stored value.
- `SketchOrEdgeRef` (`backend/app/document/models.py`) is already "a Sketch curve **or** a Body edge", which is the right
  reference type.

### Model (backend)

1. `SketchFeature.x_axis_ref: SketchOrEdgeRef | None = None` (document layer, beside `origin`, for the same reasons: it can
   name Body geometry). `None` means today's frame, so every existing file and Sketch is unchanged. Only **straight**
   entities are accepted: a Sketch **Line**, or a **linear** Body edge. A curved edge returns 422 `alignment_edge_not_straight`.
   Arcs and splines (tangent at an end?) are out of v1.
2. **Resolve** in a new step **before** flip / rotate: anchor basis → `align_basis(basis, direction)` → `apply_orientation` →
   origin. `align_basis` projects the edge direction onto the plane (`d - dot(d, n) n`), normalises it as the new `x_axis`,
   and sets `y_axis = n × x_axis`, keeping it right-handed. Flip and quarter turns then act **relative to the edge**: one
   rotate puts Y on the edge, flip reverses X, and so on. The owner asked to refine with flip and rotate, and this gives that.
   Do the alignment inside `oriented_anchor_basis`, so the "auto" origin corner is worked out in the aligned frame.
3. **Direction sense:** use the edge's own start → end (a Sketch Line's `start` → `end`; an OCCT edge's first → last vertex,
   orientation-aware). That is deterministic, and rotate×2 reverses it. The pick **always aligns X** (Decision 3, Owner);
   the user rotates to put Y on the edge. No X / Y choice in the ribbon, and no `x_axis_reversed` field.
   **It is a live reference** (Decision 2, Owner): it follows the edge as the model changes, through the usual reference
   identity following, with the lost-reference fallback in point 5.
4. **Degenerate:** an edge (nearly) parallel to the normal (`|projection| < 1e-6 · edge length`) returns 422
   `alignment_edge_parallel_to_normal` when it is set. If it becomes degenerate later, the frame falls back to unaligned
   and the reference is reported as lost.
5. **Upstream / cycles / lost:** copy the origin rules exactly (`sketch_origin_is_upstream`, the reorder / rollback guard,
   the lost-reference fallback). A Sketch Line must come from an **earlier** Sketch, never this one. A lost or unresolvable
   reference falls back to the unaligned frame and reports `lost_references: ["x_axis_ref.edge_ref"]` (or `.sketch_entity_ref`).
   Use the same signature / history following as other `SubShapeRef`s.
6. **API:** `PATCH /document/parts/{part_id}/features/{feature_id}/sketch-alignment` with `{x_axis_ref: SketchOrEdgeRefSchema | null}`
   (sibling of `/sketch-origin`), returning `SketchFeatureResponse`. The response gains `x_axis_ref` and **the resolved
   frame** (`resolved_x_axis`, `resolved_y_axis`, `resolved_normal` in world coordinates, beside `resolved_origin`). The
   clients then draw the frame without rebuilding the alignment. If the origin is `"auto"`, re-resolve it after the change,
   as the origin PATCH does after flip / rotate.
7. **Native format:** write `x_axis_ref` only when set. Old files load `None`. Add a round trip and an old-file test.
8. Route every other Sketch-frame builder through `basis_for_sketch` as the origin work did (grep `apply_orientation`,
   `oriented_basis_for_plane`, `ai_plan.py`, gear code).

### Client

1. DTOs: `FeatureDto.sketchXAxisRef`, `resolvedSketchXAxis/YAxis`. `updateSketchAlignment(partId, featureId, ref)`.
2. Basis: where the client builds a Sketch's `SketchPlaneBasis` (the list in the origin plan, 3b point 2), use the resolved
   axes when present. **Check that a Sketch's 3D drawing, its Extrude, and the orientation indicator all agree for an aligned
   Sketch.** The file's history records this class of bug for flip / rotate.
3. **Pill:** an **Align** button (icon `Icons.straighten`, tooltip "Align the sketch X axis to an edge or line",
   `ValueKey('sketch-orientation-align')`) between flip and Pick origin, in both modes. Tapping it enters an align sub-mode,
   built the same way as `_startPickSketchOrigin`: a selection-filter override that allows **edges** and **sketch lines**
   only, selection mode turned on for the pick and restored after, and a `PickerRibbon` ("Tap a straight edge or line to
   align the sketch X axis") with **Clear alignment** (sends `null`) and Cancel. A pick sends `updateSketchAlignment` and
   returns to the pill. The orientation indicator turns to the new axes; flip / rotate then refine. A curved edge or a
   later Sketch's line is greyed or refused with a short snackbar (backend 422 types above).
4. **Redefine + Cancel:** save the current `x_axis_ref` on entry, beside `_pendingOrientationOriginalFlip` / `Rotation` / origin,
   and restore it on Cancel. As with origin: existing local geometry turns with the frame, and pinned external references
   stay put, so show the same "pinned geometry can distort" note.
5. With "auto" origin and no manual pick, re-send `"auto"` after an alignment change, as after flip / rotate.

### DIDSA-VR

Full support, in the same rollout (Decision 4, Owner). See **DIDSA-VR rollout** at the end, section V2.

### Tests

Backend `tests/test_sketch_alignment.py` (new; needs pythonocc, so run it in CI or the `tools/` conda env, and say which
ran): a fixed plane aligned to a 30° Sketch Line gives x at 30°; flip and rotate on top give the 4×2 frames; an Extrude of a
rectangle at the local origin comes out rotated 30°; a Body edge on a face Sketch; a curved edge → 422; an edge parallel to
the normal → 422; a later Sketch's line → 422; a lost edge falls back and is reported; a followed edge is followed; native
round trip and old file; with "auto" origin the corner is recomputed in the aligned frame.
Client: `document_api_client_test.dart` (parse / send), `sketch_geometry_3d_test.dart` (resolved axes used),
`part_screen_test.dart` (Align is in the pill in both modes; picking a line sends the ref; Clear sends null; Cancel in
redefine restores; flip after align keeps the ref).

---

## 3. Why are Intersection and Helix one tool?

**Answer.** They are one backend feature type. `CurveFeature` (`backend/app/document/models.py`) is "a 3D curve" with two
construction methods (`curve_type`: `helix` | `intersection`). That follows the `CreatePlaneFeature` convention of one
dataclass whose fields are checked against its type. Both are curves you use as a Sweep path, a Fill Surface boundary or a
plane reference, so it made sense in the model. The client then built **one panel**, `CurvePanel`
(`client/lib/viewport3d/curve_panel.dart`), with a Helix / Intersection `SegmentedButton` at the top. Later the Add picker
got **two separate entries** (`feature_picker_sheet.dart`: "Helix", "Intersection Curve"), but the toggle stayed. That is
the grouping the owner sees.

**It is also a bug.** `CurvePanel._mode` always starts at `CurveMode.helix`. So **"Intersection Curve" opens on the Helix
form**, and the user has to find the toggle. Worse, `_startIntersectionCurve` passes only `onIntersectionChanged`, and
`_startHelix` passes only `onHelixChanged`. Switching the toggle to the other type and pressing Confirm **does nothing,
silently**: the sheet closes and no feature is made.

**Fix (client only; keep the one backend type):**
1. Give `CurvePanel` a required `mode` and **remove the toggle**. Helix and Intersection become two forms in one shell. If
   that is cleaner, split them into `HelixPanel` / `IntersectionCurvePanel` that share the `ResizableToolPanel` scaffold.
   The titles already differ ("Create Helix", "Create Intersection Curve").
2. Give them distinct icons. Both use `feature_sweep.svg` today (`feature_picker_sheet.dart`, the two `FeatureEntrySpec`s).
   Add a helix icon and an intersection icon to `assets/icons/feature/`.
3. Check every other place they appear together and keep them separate: the desktop ribbon, the tree's labels
   (`feature_tree_panel.dart` already names them separately from `curveType`), and the AI tool groups.
4. **Edit Intersection Curve, now** (Decision 5, Owner). Today only Helix has Edit (`_editHelix`); an Intersection curve
   in the tree has no Edit. The backend already supports it: `PATCH /parts/{part_id}/curve-features/{feature_id}` takes
   `sketch_feature_id_a/_b` and `profile_refs_a/_b` (`CurveFeatureUpdate`). Client:
   - `IntersectionInitialValues` on the panel (the two Sketch feature ids), the form opened on them, title "Edit
     Intersection Curve".
   - `_editIntersectionCurve(feature)` beside `_editHelix`, reached from the tree's Edit, the context menu and the
     selection actions, wherever Helix Edit is offered. Grep `_editHelix` call sites.
   - `DocumentApiClient.updateCurveFeature` sends the two ids. Add them if the method only sends Helix fields today.
   - The choice list leaves out Sketches **after** the curve in the feature order, and the curve's own downstream
     Sketches, as Create does for the order. Check what the backend refuses and match it.
   - `profile_refs_a/_b`: Create doesn't set them today (whole Sketches). Keep Edit the same: re-picking a Sketch clears
     its profile refs.

Tests: `test/curve_panel_test.dart` (or the existing panel tests): no toggle, each mode shows its own fields, the
intersection form opens on initial values. `part_screen_test.dart`: the Intersection Curve entry opens the intersection
form, and Confirm creates an `intersection` curve; Edit on an Intersection curve opens the form on its two Sketches and
Confirm PATCHes the new ids. `document_api_client_test.dart`: the update body.
DIDSA-VR: its helix tool already skips intersection curves (`helix_tool.gd`: "an intersection curve has no settings
here"). No VR change.

---

## 4. Orientation pill: buttons draw past the pill

**Cause.** The pill (`part_screen.dart`, inside `if (_confirmingSketchOrientation && !_pickingSketchOrigin)`) is
`Material(elevation: 4, borderRadius: 24)` around a horizontal `SingleChildScrollView`. `Material`'s `clipBehavior` defaults
to `Clip.none`, so when the row is wider than the screen, scrolled content draws outside the rounded backing. With Pick
origin added, the row is rotate, rotate, flip, origin, Cancel, Continue. That overflows on a phone, so it always scrolls,
and the buttons slide past the right end of the pill.

**Fix.**
1. `clipBehavior: Clip.antiAlias` on that `Material`. Better still, use `shape: const StadiumBorder()` plus the clip, so the
   clip follows the pill exactly.
2. Make overflow visible: a short fade at whichever edge has more content (a `ShaderMask` driven by the scroll position).
   Then the user knows to scroll, and nothing looks cut off.
3. Make the row fit a phone so it rarely scrolls, especially with item 2's Align button. Use `visualDensity: VisualDensity.compact`
   on the icon buttons, and below about 400 dp show Cancel as an icon button (`Icons.close`, tooltip "Cancel"). Keep
   Continue / Done as the one labelled button.
4. The same unclipped pattern is in `component_selection_toolbar.dart` (`Material(borderRadius: 12)` → `Padding` →
   horizontal `SingleChildScrollView`). The padding hides most of it, but add the clip there too. Grep for other
   `Material(... borderRadius ...)` wrapping a horizontal scroll view.

Tests: `part_screen_test.dart`: on a 360 dp phone, the pill's `Material` has a clip (`clipBehavior != Clip.none`), all
controls can be reached by scrolling, and Continue is tappable. A golden test isn't needed. Not checkable here: how the fade
looks on the device.

---

## 5. Revolve: thin option

### What exists today

- Extrude thin: `ExtrudeFeature.thickness: float | None` + `thickness_direction: ThicknessDirection` (`outward` / `inward` /
  `symmetric`). Built in `app/document/extrude.py`: the profile **face** is prismed into a capped solid, then thickened with
  `MakeThickSolidByJoin`, removing the two caps (`_thin_wall_solid_for_direction`, `shell_ops.thicken_capped_solid_to_solid`,
  `GeomAbs_Intersection` joins). Thin and draft can't be used together. 422 `thin_extrude_failed`. Client: `ExtrudePanel`
  (`_isThin`, thickness field, direction choice).
- `RevolveFeature` (`models.py`; `app/document/revolve.py`, `BRepPrimAPI_MakeRevol(face, axis, angle)`) has no thin option.

### Backend

1. `RevolveFeature.thickness: float | None = None`, `thickness_direction: ThicknessDirection = OUTWARD`, reusing the enum.
   Create / update schemas, response, native format (write only when set), and validation (`thickness > 0` after `abs`, the
   same as Extrude's validator).
2. **Geometry: offset the profile in 2D, then revolve the ring.** Don't copy Extrude's cap-removal approach. A 360° revolve
   has **no caps** to remove, and thickening a closed solid with no closing faces makes a hidden inner void, not a wall.
   Instead, build the thin profile face in the sketch plane with `BRepOffsetAPI_MakeOffset` on the profile's outer wire
   (`GeomAbs_Intersection` join, matching Extrude's sharp corners):
   - `outward`: region between the wire and its +t offset.
   - `inward`: between the −t offset and the wire.
   - `symmetric`: between the −t/2 and +t/2 offsets.
   Then `BRepPrimAPI_MakeRevol(ringFace, axis, angle)` as now. For an angle < 360 this gives the same solid as Extrude's
   method (the revolved side faces' normals lie in the profile plane). Put the ring builder in `shell_ops.py` (or a small
   `thin_profile.py`) so Extrude can use it later. **Don't switch Extrude to it in this item.**
3. **Failure cases** (new 422 `thin_revolve_failed` with a `reason`): the inward offset collapses (wall thicker than the
   profile), the offset fails, or the outward / symmetric ring **crosses or touches the axis**. Check the ring face's
   distance to the axis line is above tolerance before revolving, because a self-intersecting revolve is what OCCT gives
   otherwise. Inner holes in the profile (islands): thin Extrude walls them too, because its cap-removal thickens every side
   face. Match that if it stays simple: offset each wire of the profile face, outer and holes, each away from the material
   for `outward`, and build the ring as the face's offset region minus the face, or the reverse. If it doesn't, v1 thins
   the outer wire only, and says so in the panel's help.
4. **Open profiles, thin only** (Decision 6, Owner): a Sketch with no closed profile but a single open chain (a line,
   or lines and arcs, revolved into a cup, bowl or bell wall) can be thin-revolved. A solid Revolve still needs a closed
   profile.
   - **Detecting:** reuse Revolve Surface's fallback exactly (`app/document/revolve_surface.py`: `detect_profile` first,
     then `detect_open_chain` → `SINGLE_CHAIN` → `wire_for_open_chain`). A closed profile always wins, as there. With
     `thickness` unset and only an open chain, keep today's error (no profile).
   - **Ring face from an open wire:** offset the open wire (`BRepOffsetAPI_MakeOffset` with `IsOpenResult=True`), then
     close it into one face: wire, end cap (straight segment), reversed offset wire, end cap.
   - **Direction for an open chain** (an open chain has no inside or outside, so the enum is read against the **axis**):
     `outward` = the wall grows on the side away from the axis, `inward` = toward the axis, `symmetric` = both by t/2.
     Pick the side per chain from the offset that moves the chain's midpoint further from the axis. Document it in
     `ThicknessDirection`'s doc comment, and label it in the panel for open profiles ("Away from axis / Toward axis / Both
     sides").
   - **End on the axis:** a chain that ends on the axis (the centre of a cup's bottom) is allowed. The end cap then lies
     along the axis and the revolve closes it. The ring must still not **cross** the axis (point 3's check). An end that
     sits within the tolerance of the axis but not on it: snap it to the axis, or refuse with `reason: near_axis`. Pick
     one and test it.
   - `profile_refs` is ignored for an open chain, as in Revolve Surface.
   - A 360° open-chain thin revolve whose ends are both off the axis is a tube with open ends. That is fine.
5. Revolve **Cut** with thin is valid (cut a groove of wall thickness). Keep `target_body_ids` handling unchanged.
6. Provenance / face selectors: as with thin Extrude, no edge-index provenance for the thin branch. Copy that note.
7. AI plan (`backend/app/ai_plan.py` `RevolveStep`, client `ai_plan.dart`): **out of scope**, unless adding the two optional
   fields is trivial. Note it as open work.

### Client

- `RevolvePanel` (`client/lib/viewport3d/revolve_panel.dart`): a **Thin** toggle, a thickness field and an Outward / Inward
  / Symmetric choice. Lift the widgets out of `ExtrudePanel` into a shared `ThinWallControls` rather than copying them.
  `onChanged` gains `thickness`, `thicknessDirection`. Edit shows the stored values. When the chosen Sketch has no closed
  profile but an open chain, open the panel with Thin **on and locked**, a hint ("An open profile revolves as a thin wall"),
  and the axis-relative direction labels. Today the Revolve entry refuses a Sketch with no closed profile. Relax that check
  in `part_screen.dart` (the Revolve guided flow's profile check) to "closed profile or a single open chain".
- `document_api_client.dart`: `createRevolveFeature` / `updateRevolveFeature` send `thickness` / `thickness_direction`, and the
  Revolve feature DTO reads them. Live preview uses the same path as the other Revolve fields.
- DIDSA-VR: see **DIDSA-VR rollout**, V3.

### Tests

Backend (`tests/test_stage_f_revolve.py` or a new `test_revolve_thin.py`; needs pythonocc, so say which ran): a 20×10
rectangle 30 mm off the axis, 360°, t = 2 outward / inward / symmetric gives exact volumes (2π·r̄·A_ring). A 90° case gives
flat end faces. An inward wall thicker than half the width → 422. An outward ring crossing the axis → 422. Cut thin.
Native round trip and old file (no keys → solid revolve). Update with `thickness: null` → back to solid.
Open chain: an L-shaped chain (base on the axis, side wall up) revolved 360° at t = 2 gives a closed-bottom cup with the
expected volume. Away-from-axis and toward-axis put the wall on the right side. A chain with both ends off the axis gives
an open tube. A chain crossing the axis → 422. A Sketch with both a closed profile and an open chain uses the closed
profile. An open chain with `thickness` unset → the existing no-profile error.
Client: `revolve_panel_test.dart` (toggle shows fields, sends values, edit pre-fills, open profile: Thin locked on with
the axis labels), `document_api_client_test.dart`, `part_screen_test.dart` (Revolve on an open-chain Sketch opens the
panel instead of refusing).

---

## DIDSA-VR rollout (same pass)

Work in DIDSA-VR on branch `ccr-462e27b1-yawq7e`. Read its `CLAUDE.md`, `docs/backend-api-notes.md` and `tests/README.md`
first. New test files go in `tests/run_all.sh` and get a row in `tests/README.md`; live-backend tests also go in
`tests/e2e_ci_list.txt`. Update VR's `docs/status.md` and `CHANGELOG.md`. Do the CAD backend part of each item before its
VR part, because VR's live tests need it.

### V1. File lookup rule (item 1b / 1c)

- `scripts/file_lookup.gd`: the `likely` result and the path-suffix step, exactly as the Python reference. Copy the new
  vectors to `tests/fixtures/file_lookup_vectors.json`, and `tests/file_lookup_vectors.gd` must pass all of them. **This
  must land together with the CAD vector change**, or VR's vector test fails.
- `scripts/native_compose.gd`: an `accept_likely` flag, used the way the flat app uses it; the learned shift (1c) too.
- **Asking:** VR has no modal dialogs. When an open has `likely` references, show it on the load status line, and in
  **Files > References** as a header row: "6 files look like they moved with the project folder" with **Use them**,
  **Not now**, and a **Don't ask again this session** toggle. Use them re-opens with `accept_likely`, the way
  `main.choose_reference` already re-opens with a pick, keeping the "only unsaved change is a corrected path → no discard
  prompt" rule. The toggle is held in memory on `main.gd` (not in `secrets.cfg` or any saved settings) and applies to later
  opens and room adds while the app runs.
- Tests: `tests/file_lookup_vectors.gd` (new vectors), `tests/moved_files.gd` (3-level id-less fixture under a new root:
  not accepted → level 1 `likely`, deeper levels not visited; accepted → all levels resolved; session toggle skips the
  question on a second open).

### V2. Sketch frame: flip, turn, origin and edge alignment (item 2)

Today VR builds a sketch's frame itself and **refuses** a sketch that is flipped or turned in the flat app
(`table_editor.gd` around line 1517, `_plane_for_row` around line 2846, and so `sketch_picks.gd`'s finished-sketch picks).
An aligned sketch would get past those checks and open with the wrong axes. Replace all of it with the backend's resolved
frame:

- **Backend first (CAD, item 2 point 6):** `SketchFeatureResponse` returns the whole resolved frame, `resolved_origin` +
  `resolved_x_axis`, `resolved_y_axis`, `resolved_normal`, after anchor → alignment → flip / turns → origin. These are the
  exact vectors `basis_for_sketch` uses, so the sketch's points map with `origin + u·x + v·y`.
- `SketchMath.with_frame(basis, row)` (replaces `with_origin`, which stays as a wrapper for older backends): when the row
  has all four resolved vectors, use them; otherwise fall back to today's plane basis + `with_origin`.
- **Flipped (mirrored) frames:** `apply_orientation`'s flip negates X only, so a flipped frame is **left-handed**
  (`x × y = −n`; the backend has `is_mirrored_basis`). `SketchMath.orient_to_table` assumes right-handed and would build a
  reflection. For a mirrored frame, lay the table out with `n' = x × y`, so the part is shown from the other side of the
  sheet, with X right and Y away exactly as the flat app's 2D view shows them. Check the flat app's own sketch view does
  the same before settling on it. Test that a point drawn at (u, v) on the table lands at `origin + u·x + v·y` in both cases.
- **Remove the refusals** in `table_editor.gd` (both sites) and the "flipped or turned" message, once `with_frame` is in.
  Keep a refusal only for a row with a lost reference *and* no resolved frame (an older backend), with the message
  "That sketch's frame can't be worked out here".
- `SketchSession.open_sketch` / `reopen`: take the frame from the create / feature response, as `with_origin` is used now.
  New face sketches still send `"origin": "auto"`. VR still has no orientation step, so it doesn't send `x_axis_ref`,
  flip or turns. Note "set orientation / align in VR" as open work in `docs/status.md`.
- `tests/helpers/fake_cad.gd`: the sketch-feature rows carry the resolved frame, with cases for turned, flipped and
  aligned.
- `native_compose.gd` passes `x_axis_ref` through unchanged. Add a test like the `origin` one.
- Tests: headless `SketchMath.with_frame` (right-handed, mirrored, missing keys → fallback); reopening a turned / flipped /
  aligned sketch from the fake backend puts its curves where the frame says; `sketch_picks` loads them instead of skipping.
  Live backend (`tests/ci_e2e.sh`): make a sketch on XY aligned to a 30° line of an earlier sketch, then flip it; open it
  in VR, draw a point at (10, 0), and check the backend reports it at the expected part-frame position.
- **Cannot be tested here:** how a flipped sketch shown from the other side feels on the headset.

### V3. Revolve thin (item 5)

VR's revolve tool (`scripts/design_table/features/revolve_tool.gd`, request built in `part_features.gd`
`revolve_request`) gets the same options its extrude tool has (`ext_thin`, `ext_wall`, `ext_dir` in
`extrude_tool.gd`):
- options `rev_thin`, `rev_wall` (default 2.0), `rev_dir` (`outward` / `inward` / `symmetric`), added to
  `table_editor.gd`'s `options` dictionary; buttons "Thin wall", "Wall N mm", and the three direction toggles. For an
  open-profile sketch the labels read "Away from axis / Toward axis / Both sides", and Thin is locked on.
- `revolve_request` sends `thickness` / `thickness_direction` when thin, and refuses a wall ≤ 0 with the usual `_bad`.
- **Open profiles:** `revolve_tool.on_activated` says "The sketch needs a closed shape to revolve" when
  `session.profile_ok()` is false. Allow a single open chain when Thin is on (the sketch session needs an open-chain
  check, as the loft / ruled tools may already have; reuse it if so). Change the text to "a closed shape, or one open line
  chain for a thin wall".
- The Build row's description shows "thin N mm" for a thin revolve, as for a thin extrude. Grep how extrude's row
  reads `thickness`.
- `tests/helpers/fake_cad.gd` accepts the new keys. Tests: headless option handling and request body (closed and open
  chain), the open-chain gate; live backend: an L chain revolved 360° thin makes one body.

---

## Decisions (answered by the owner, 2026-11-11)

1. **Folder-shift match for references with no stored id (item 1b / 1c):** **advise and let the user accept or not**, with a
   **"Don't ask again this session"** checkbox. Built as `LookupResult.likely` + the ask-first dialog in 1b, and the
   Files > References header row in VR (V1).
2. **Edge alignment:** **follow the edge** (a live reference with the lost-reference fallback).
3. **Which axis:** **always X**; rotate to put Y on the edge.
4. **DIDSA-VR:** **plan the VR rollout in the same pass.** Full support using the resolved frame, which also ends VR's
   refusal of flipped and turned sketches (V2), plus V1 and V3.
5. **Edit Intersection Curve:** **now** (item 3 point 4). The backend type stays one `CurveFeature`; only the UI is split.
6. **Thin revolve of open profiles:** **yes** (item 5 point 4).
