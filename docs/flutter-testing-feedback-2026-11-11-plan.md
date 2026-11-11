# Flutter testing feedback 2026-11-11: plan

Source: the owner's report from testing the Flutter client on an Android phone.
This doc is for the implementation session. Code pointers were checked against `main` at `cdeb782`.
Line numbers drift, so search for the named symbol if a line is off. Nothing in this plan was run on a device.
The causes in item 1 come from reading the code. They were not reproduced with the owner's files.

| Item | Summary | Kind | Size |
|---|---|---|---|
| 1 | After changing the project folder, sub-assemblies aren't found. Level 1 could be relinked by hand, level 2 could not | Bug + feature | Medium (1a small, 1b-1d medium) |
| 2 | Sketch orientation: pick an edge or line to align a sketch axis, then flip / rotate to refine | Feature | Medium-large (backend + client, VR guard) |
| 3 | Why are Intersection and Helix one tool? | Question + bug | Small |
| 4 | Orientation pill: buttons draw past the pill's rounded ends when the row scrolls | Bug | Small |
| 5 | Revolve: a "thin" option like Extrude's | Feature | Medium (backend + client) |

Suggested order: **4 → 3 → 1a → 1b-1d → 5 → 2**. 4 and 3 are small, contained fixes. 1a is the bug that stopped the owner.
2 adds another button to the pill, so 4 should land first.

## Progress

| Item | What landed | Tests |
|---|---|---|
| | | |

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
    agrees as well as its name): **use it** as `found` with a new `via: suffix`. It goes in the banner as "found in new
    place", which needs nothing from the user, and is an unsaved change, like a by-id find. **This changes D11 for id-less
    references and needs the owner's OK (Decision 1).** If the owner says no, return it as `suggest` with the candidates
    sorted by `k`, and rely on 1c.
  - `k == 1` (only the name agrees) is today's step 3: a suggestion.
  - A stored id that the suffix file does not carry: still a suggestion, never used (the D11 "never a wrong file" rule stays).
- **Shared rule:** this changes the reference implementation, so do it in all three copies:
  `backend/app/document/file_lookup.py` (reference) → `tools/file_lookup_vectors/generate.py` (new vectors: prefix
  added, prefix removed, two equal-`k` candidates → ask/suggest, `k == 1` → suggest, an id present but not matching → suggest)
  → `docs/file-lookup/vectors.json` + `backend/tests/data/file_lookup_vectors.json` (`--check`) → Dart
  `file_lookup_rule.dart` (`LookupVia.suffix`, `ReferenceOutcome` gets a "found by folder" label, `reference_report.dart`)
  → **DIDSA-VR** `scripts/file_lookup.gd` + `tests/fixtures/file_lookup_vectors.json` (copy) + `tests/file_lookup_vectors.gd`.
  If the VR change isn't made in the same rollout, DIDSA-VR's vector test fails on the new cases. Either change both, or land
  the VR change first, behind its vector file update.

### 1c. Feature: learn the shift once and apply it to the rest

Even with 1b, the owner should never have to do the same move twice.

- **In the composer:** when a reference is found by id (step 2) or by suffix (1b), and the found path is
  `newPrefix + tail` where the stored path is `oldPrefix + tail`, record `oldPrefix → newPrefix`. For each later miss in
  the same compose, try the shifted path first, before the index. A shifted file whose id is the stored id, or which has no
  stored id to check, is used and reported. One id-bearing reference anywhere in the tree then fixes the id-less ones that
  moved the same way.
- **In the Review sheet:** when the user picks a file with **Use** or **Locate...**, work out the shift the same way. If any
  other open reports would resolve with it, offer one action: "Apply the same folder change to 6 other references". It runs
  the relink for each (sequentially; each import is a full `importNative`) and adds each one's nested reports (1a).
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
  1b: all levels found by suffix, reported, `external_ref` corrected at each level. With an id on level 1 only: level 2 and 3
  found through the learned shift (1c).
- `test/file_lookup_rule_test.dart` picks up the new vectors automatically. Check the case count goes up.
- `test/references_sheet_test.dart` / `test/part_screen_test.dart`: Use on a level-1 suggestion adds its nested reports to the
  sheet (1a). Use on a level-2 report relinks the Occurrence on the sub-Part. A Use that re-mints still targets the right
  `parentPartId`. "Apply the same folder change". "Use all single suggestions".
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
   orientation-aware). That is deterministic, and rotate×2 reverses it. Optionally the client sends the endpoint nearest
   the tap as the start: store `x_axis_reversed: bool`. **Recommendation: skip it in v1.**
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

VR builds sketch frames itself (`SketchMath.fixed_basis` / `basis_from_plane_response` + `with_origin`) and **refuses a
flipped / turned sketch** (`table_editor.gd`, the `"That sketch is flipped or turned in the flat app..."` check around
line 1517, and `_plane_for_row` around line 2841). An aligned sketch passes those checks today and **would open with the
wrong axes**.
- **Minimum (in this rollout):** add `row.get("x_axis_ref") != null` to both checks, and update the message ("flipped,
  turned or aligned to an edge in the flat app"). Add a headless test.
- **Later:** use the response's resolved axes (`SketchMath.with_frame(basis, row)`) and drop the refusal for all three. Note it
  as open work in VR's `docs/status.md`.
- `native_compose.gd` must pass the unknown key through. Add a test, as done for `origin`.

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
4. **Optional:** Intersection curves have no Edit (only `_editHelix`). Add Edit Intersection Curve (re-pick the two Sketches),
   only if it stays small.

Tests: `test/curve_panel_test.dart` (or the existing panel tests): no toggle, and each mode shows its own fields.
`part_screen_test.dart`: the Intersection Curve entry opens the intersection form, and Confirm creates an `intersection`
curve.

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
   the outer wire only. Then say so in the panel's help and in Decision 6.
4. Revolve **Cut** with thin is valid (cut a groove of wall thickness). Keep `target_body_ids` handling unchanged.
5. Provenance / face selectors: as with thin Extrude, no edge-index provenance for the thin branch. Copy that note.
6. AI plan (`backend/app/ai_plan.py` `RevolveStep`, client `ai_plan.dart`): **out of scope**, unless adding the two optional
   fields is trivial. Note it as open work.

### Client

- `RevolvePanel` (`client/lib/viewport3d/revolve_panel.dart`): a **Thin** toggle, a thickness field and an Outward / Inward
  / Symmetric choice. Lift the widgets out of `ExtrudePanel` into a shared `ThinWallControls` rather than copying them.
  `onChanged` gains `thickness`, `thicknessDirection`. Edit shows the stored values.
- `document_api_client.dart`: `createRevolveFeature` / `updateRevolveFeature` send `thickness` / `thickness_direction`, and the
  Revolve feature DTO reads them. Live preview uses the same path as the other Revolve fields.
- DIDSA-VR: no Revolve thin UI needed. Check `native_compose.gd` passes the keys through, and that VR's feature table shows
  a thin Revolve without errors. No change is expected.

### Tests

Backend (`tests/test_stage_f_revolve.py` or a new `test_revolve_thin.py`; needs pythonocc, so say which ran): a 20×10
rectangle 30 mm off the axis, 360°, t = 2 outward / inward / symmetric gives exact volumes (2π·r̄·A_ring). A 90° case gives
flat end faces. An inward wall thicker than half the width → 422. An outward ring crossing the axis → 422. Cut thin.
Native round trip and old file (no keys → solid revolve). Update with `thickness: null` → back to solid.
Client: `revolve_panel_test.dart` (toggle shows fields, sends values, edit pre-fills), `document_api_client_test.dart`.

---

## Decisions (for the owner)

1. **Item 1b, the folder-shift match for references with no stored id:** use it automatically when exactly one file matches
   on at least its folder and name (`k ≥ 2`), and report it in the banner as "found in a new place" (**Recommendation**:
   it's the change that actually fixes a moved project folder, and a path that agrees on folder + name is much stronger
   evidence than a name alone). Or keep it as a suggestion that needs a click (strict D11), and rely on 1c's
   "Apply to all" to make the clicks cheap?
2. **Item 2, alignment as a live reference vs a snapshot:** store the edge and follow it when the model changes
   (**Recommendation**, the same as the sketch origin, with the lost-reference fallback). Or store just the resulting angle
   (simpler, but it doesn't update if the edge moves)?
3. **Item 2, which axis the pick aligns:** X, with rotate to put Y on the edge (**Recommendation**). Or ask X / Y in the
   ribbon?
4. **Item 2, DIDSA-VR:** refuse aligned sketches in VR for now, as flipped / turned ones are (**Recommendation**), with full
   support (using the resolved frame for all three) as a separate VR task?
5. **Item 3:** keep one backend `CurveFeature` and split only the UI (**Recommendation**). Add Edit for Intersection curves
   now or later?
6. **Item 5:** closed profiles only, matching Extrude's thin (**Recommendation**). Island walls are as in point 3. Open-profile thin revolve
   (a line revolved into a cup or bowl wall) is a natural next step, and the 2D-offset approach supports it (offset an
   open wire into a closed ring). Want it in this item?
