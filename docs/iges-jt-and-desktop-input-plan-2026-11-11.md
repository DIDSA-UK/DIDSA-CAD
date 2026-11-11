# IGES / JT file support and desktop-mode mouse input: plan

Source: the owner's testing notes of 2026-11-11 (Flutter client on a phone in desktop mode; file-format request).
This doc is for the implementation session. Code pointers were read on branch `ccr-dec7d67f-ipq5rn` (= `main` plus this doc).
Line numbers drift, so search for the named symbol. **Nothing here was run**: no OCCT, no Flutter and no device were available
while planning. Where a cause is a guess from reading, it says so and the first step is how to confirm it.

The VR items from the same notes are in `DIDSA-UK/DIDSA-VR`, `docs/vr-feedback-2026-11-11-plan.md`. Item F-3 below touches
the VR client's file list (one line), nothing else crosses over.

| Item | Summary | Kind | Size |
|---|---|---|---|
| F-1 | Desktop mode: Ctrl/Shift + middle drag intermittently orbits instead of pan / zoom | Bug (cause unconfirmed) | Small-medium |
| F-2 | Desktop mode: a left click with a mouse sets a rotation centre; not wanted for a mouse | Bug / behaviour change | Small |
| F-3 | IGES import and export (Part and assembly), colours and names where IGES allows | Feature | Medium |
| F-4 | JT import via an open reader (FerroJT recommended); no export | Feature, spike first | Medium (after the spike) |
| F-5 | Mesh viewer: open the new B-rep formats (and any other cheap mesh formats) | Feature | Small-medium (after F-3) |

Suggested order: **F-2 → F-1 (diagnose first) → F-3 → F-5 → F-4 spike (can run in parallel) → F-4**.

---

## F-2: a left click with a mouse sets a rotation centre

**Cause (read, certain).** `PartViewport._handleTap`-style tap code (search `setsPivot` in `client/lib/viewport3d/part_viewport.dart`,
about line 4900): in orbit mode on the part and assembly screens a tap on the model runs `resolveOrbitTap` and then
`setState(() => _touchPivot = pivotHit!.point)`. It never looks at what kind of pointer tapped. The empty-space branch at the end of
the same function (`if (setsPivot && _touchPivot != null) setState(() => _touchPivot = null)`) clears it.
It is a touch feature (`_touchPivot`, "persistent rotation pivot a tap on the model sets").

**Fix.**
1. Compute `setsPivot` as before **and `!_mouseDriven`** (`_lastPointerKind == PointerDeviceKind.mouse`, already tracked by
   `_noteDeviceKind`). With a mouse the tap then falls through to its ordinary meaning (plane tap, background tap) exactly as if no
   pivot code existed.
2. When the pointer kind changes touch → mouse (`_noteDeviceKind`), clear `_touchPivot` so a pivot set by an earlier finger tap does
   not keep steering a mouse orbit with no way to see why. (Check `_pivotMarker` / the overlay drawn at `_touchPivot`, near
   `worldToScreen(... _touchPivot!)` about line 7498, disappears with it.)
3. Keep the context-menu entry "Rotate about here" (`setRotationPivotAtGlobal`, called from `part_screen.dart` about line 14780) and
   "Clear pivot" (`onClearPivot`, line 2624): a deliberate menu choice is not the accident the owner reported.
4. **Do not remove** D2's per-drag orbit about the geometry under the middle press (`_orbitPivot`, `_orbitPivotAt`): it is a
   separate feature from the persistent LMB pivot, and the owner's note is about the LMB one. If the owner meant both, it is a
   one-line change (`_orbitPivot = null`); say in the PR that it was left in.

**Tests.** `test/part_viewport_mouse_navigation_test.dart` (skips without a GPU) and the pure `resolveOrbitTap` tests: add a test
that a mouse tap in orbit mode leaves `rotationPivot == null`, and a touch tap still sets it. Update `docs/desktop-input-scope.md`
(D2 notes: "orbit about the cursor" stays; the touch pivot is touch only).

---

## F-1: Ctrl+middle orbits (should pan), Shift+middle orbits (should zoom), intermittently

**What the code does.** `mouse_navigation.dart`: `mouseNavActionFor(buttons, control:, shift:, preset:)` is correct for SOLIDWORKS
(middle+Ctrl = pan, middle+Shift = zoom, middle alone = orbit). `mouseNavActionForEvent` reads the modifiers with
`HardwareKeyboard.instance.isControlPressed` / `isShiftPressed` **on every move**. Both symptoms (Ctrl gives orbit, Shift gives
orbit) are exactly what the table returns when both modifier reads are `false`. The 2D canvas and the mesh viewer use the same
function, so they would show it too. The table itself is not the bug; the modifier *state* is.

**Ranked hypotheses (none confirmed; do step 0 first).**
1. **`HardwareKeyboard` lost a key-down/key-up** (most likely, matches "intermittently"). Flutter's `HardwareKeyboard` only knows
   what key events it was sent. A Ctrl or Shift press that happened while the window/view did not have key focus, during an Android
   window or DeX focus change, or while the layout rebuilt (phone ⇄ desktop switch rebuilds the screen), is never seen, or its
   key-up is. Flutter then also logs "A KeyUpEvent is dispatched, but the state shows that the physical key is not pressed".
   Switching to desktop mode is exactly when focus and the window change.
2. **The mouse is reported as a different `PointerDeviceKind`** on some presses (touch or stylus with a button mask). Then
   `isMouseNavPress` / `mouseNavActionForEvent` return null and the press falls through to the touch path, where a one-pointer drag
   orbits. This also explains "orbits" for any modifier. Cheap to rule in or out with step 0.
3. **A stale `_mouseNavPointer`** (a pointer-up lost to a focus change): a later middle press is treated as a continuation. Less
   likely, but `_onPointerEnd` / `_endMouseNavigation` only reset when `event.pointer == _mouseNavPointer`.
4. **Another widget in the desktop layout absorbs the press**: the docked panels / ribbon wrap `Listener`s or `GestureDetector`s
   that can win the arena over the viewport's `Listener` for part of the area. Check by pressing in the middle of the viewport vs
   near the docked panel edges.

**Step 0: instrument (small, keep behind a debug flag, e.g. Controls ▸ "Show input debug").** A one-line overlay in the viewport
showing, for the last pointer event: `kind`, `buttons` (as bits), `HardwareKeyboard.isControlPressed/isShiftPressed`, the
`MouseNavAction` chosen, and `_mouseNavPointer`. Have the owner reproduce on the device and read off which hypothesis it is.
Log the same line with `debugPrint` for a `adb logcat` run. Do not guess a fix before this.

**Fix, by hypothesis.**
- **1 (modifier state):** add one small `ModifierTracker` next to `mouse_navigation.dart` that *unions* sources and is the only
  place the app reads Ctrl/Shift/Alt for mouse use: (a) `HardwareKeyboard`; (b) call `HardwareKeyboard.instance.syncKeyboardState()`
  on pointer-down (cheap, and on app resume and window focus gain) so a missed key-down is re-read from the platform; (c) clear it
  on `AppLifecycleState` changes and on pointer-cancel. If (b) is not implemented on the target platform (check the Flutter
  version's docs; Android support must be verified, not assumed), fall back to reading the **MotionEvent meta state** natively:
  override `dispatchGenericMotionEvent` / `dispatchTouchEvent` in the Android `MainActivity` to keep `event.metaState` in a
  `MethodChannel`/static the tracker reads. That is reliable on DeX because the modifier rides on the very event that carries the
  mouse button. Only build the native part if (b) is not enough.
- **2 (device kind):** treat any pointer with a non-primary button mask (`kMiddleMouseButton` / `kSecondaryMouseButton`) as a mouse
  press regardless of `kind`; keep `kind == mouse` as the test for hover and wheel only. Put the rule in `isMouseNavPress` and
  `mouseNavActionForEvent` (one place), and in `SketchCanvas` / the mesh viewer which call them.
- **3:** reset `_mouseNavPointer` on any `PointerDown` of kind mouse when it is not null (a new press cannot belong to the old
  pointer), and on `didChangeAppLifecycleState`.
- **4:** only if step 0 shows the press never reaches `_onPointerDown`: move the nav press handling to a `Listener` with
  `behavior: HitTestBehavior.translucent` above the docked panels' gesture areas, or make the panels not claim middle/right
  buttons.

**Tests.** Pure tests for `ModifierTracker` (fake key events, then a missed key-up, then `sync`); extend
`test/mouse_navigation_test.dart` for the device-kind rule. The viewport pointer tests skip without a GPU (as the D1 notes say);
say that in the PR. **Not verifiable without the device**: say so, and ask the owner to re-test Ctrl/Shift + middle after
switching to desktop mode, with the overlay on, several times (it was intermittent).

---

## F-3: IGES import and export

IGES is a B-rep (and surface / wireframe) exchange format like STEP. The backend already has the whole pattern for STEP; IGES
mirrors it. Backend is pythonocc-core `8.0.1.2` (`backend/environment.yml`); it ships `OCC.Core.IGESControl`
(`IGESControl_Reader`, `IGESControl_Writer`) and `OCC.Core.IGESCAFControl` (`IGESCAFControl_Reader` / `_Writer`, colours and names
through XCAF). **Verify each class imports in the pinned build first** (like the STEP notes: pythonocc builds differ, the XCAF
document idiom `TDocStd_Document("any-label")` with no `XCAFApp_Application` is the one that works here; see
`step_export.py` docstring).

### Backend: import

1. `models.py`: add `IGES = "iges"` to `ImportSourceFormat` (and its docstring). `native_format.py` reads it back with
   `ImportSourceFormat(...)`, so saved documents round-trip with no more change; add a native-format round-trip test.
2. `import_geometry.py`: `_shape_from_iges(data)` next to `_shape_from_step`, same temp-file idiom (the reader only reads a
   path; suffix `.igs`), `IGESControl_Reader`, `ReadFile`, `TransferRoots`, `OneShape`. Same error mapping as STEP
   (`_invalid_import_data` for a parse failure, `_import_failed` for no roots or an empty shape). Dispatch it in `resolve_import`.
3. **IGES-specific work that STEP does not need.** IGES files from many systems carry *surfaces and trimmed faces, not solids*
   (types 143/144/186/510/514). Before returning the shape: run `ShapeFix_Shape`; if the result has no solids, try
   `BRepBuilderAPI_Sewing` on the faces then `ShapeFix_Solid` / `BRepBuilderAPI_MakeSolid` when the shell is closed. A shape that is
   still only faces/shells is **allowed** (it becomes a surface Body, like other non-solid Bodies; check how `compute_part_bodies`
   / `_register_solids` in `extrude.py` handles a non-solid import and reuse it) rather than rejected. Surface the outcome in the
   response so the client can say "imported as surfaces (not a closed solid)".
4. Units: IGES stores the model unit in the Global section; OCCT's reader converts to its working unit by default
   (`Interface_Static.SetCVal("xstep.cascade.unit", "MM")` before reading; set it explicitly, the backend's native unit is mm). Test
   with an inch file and a metre file.
5. Metadata: `extract_step_metadata` has no IGES equivalent worth building (IGES has names on entities but no material). Colours
   and names via `IGESCAFControl_Reader` are a **nice-to-have**; do after the geometry path is green, mirroring the STEP XCAF code.
   Do not block the feature on it.
6. `router.py` `create_import_feature`: the STEP-only metadata block stays STEP-only. No other change (the payload carries
   `source_format`). `schemas.py` `ImportFeatureCreate` takes the enum, so it picks IGES up for free.

### Backend: export

1. New `backend/app/document/iges_export.py`, mirror of `step_export.export_step` but simpler: `IGESControl_Writer("MM", 0)`
   (unit, mode 0 = faces; mode 1 = BRep entities (type 186), which is what most importers want for solids: **make it a module
   constant and test both with the viewer you use; default to B-rep mode 1**), `AddShape` per Body, `ComputeModel`, write to a temp
   file, read the bytes back (same reason as STEP: file path only). Colours: IGES can carry colour per entity (`IGESCAFControl_Writer`
   with an XCAF document, like `export_step`'s `XCAFDoc_ColorTool` code). Build the plain writer first, add colour second.
2. No MBD / material / mass (IGES has no slot for them; say so in the docstring, as the STEP one does for supplier fields).
3. `router.py`: `GET /parts/{part_id}/export/iges` and `GET /parts/{part_id}/export/assembly-iges`, beside the STEP ones
   (`export_part_step`, `export_part_assembly_step`), reusing `_export_bodies_or_400` and `_assembly_export_bodies_or_400`.
   `media_type="model/iges"`, file name `{part.name}.igs`. The assembly one flattens to world-placed bodies exactly like the STEP one
   (no assembly structure in an IGES file; say it in the docstring).
4. Tests (`backend/tests/`, next to `test_assembly_export.py` and the STEP export tests): export a box and a cylinder, read the
   bytes back with `_shape_from_iges`, compare volume and bounding box within tolerance; an inch-unit import; an IGES with only
   surfaces (write one with `IGESControl_Writer` mode 0 from a face); a corrupt file → 4xx with `invalid_import_data`.

### Client (Flutter) and VR

- `client/lib/viewport3d/import_format_dialog.dart`: add `ImportFormatOption(label: 'IGES', value: 'iges', extensions: ['iges', 'igs'])`.
- `client/lib/viewport3d/export_format_dialog.dart`: add `ExportFormatOption(label: 'IGES', value: 'iges')`; wire it in
  `DocumentApiClient` (`document_api_client.dart` ~6471: the `'step'/'stl'/'obj'/'glb'` export switch, and the assembly variant) and
  `part_screen.dart` (~12640-12680, `_importGeometry`, and the export method with the same format strings). Search for every
  `'step'` string literal in `client/lib` and `client/test` to find all the switch sites.
- `client/lib/viewport3d/part_toolbar.dart` ~140 has the doc comment listing formats; update it.
- File-picker extension lists: the import path validates the picked file against `option.extensions`, nothing else to add.
- Tests: widget test for the dialogs (mirror the existing STEP one), `DocumentApiClient` test with a fake HTTP client.
- **VR client** (`DIDSA-VR`): `scripts/main.gd` `_BACKEND_IMPORT_FORMATS` (~line 1426) and `scripts/project_folder.gd`
  `MODEL_EXTENSIONS` (line 10): add `"iges"`/`"igs"` → `"iges"`. One line each plus the test row; do it in the same change as the
  backend, or an IGES file in the project folder would be offered and refused.
- Docs: `docs/status.md`, `docs/roadmap.md` if listed, and the README's supported-formats line.

---

## F-4: JT support

OCCT / pythonocc has no JT reader or writer, but **open-source JT readers exist** (researched 2026-11-11 from the repos' GitHub pages
and the GitHub `jt` topic; stars and dates are as shown then, **commit dates and release tags were not visible** to the research
tool, so check activity yourself with `git log` before committing to one). The licence column matters: the backend is **AGPL-3.0**
and links OCCT (LGPL); the client is Apache-2.0 and takes **no code from the backend** (`LICENSING.md` rule 1).

| Project | Lang / licence | Stars | Reads | Verdict |
|---|---|---|---|---|
| **[jriegel/FerroJT](https://github.com/jriegel/FerroJT)** (and a fork, filestar/ferrojt) | Rust, **MIT or Apache-2.0**, Python bindings (pyo3, abi3 py3.10+) | 4 (fork 0) | JT 7.x-10.x (tested 8.0, 8.1, 9.5, 10.3 samples); the whole logical scene graph (assembly structure, instances, transforms); LOD **triangle meshes**; materials (diffuse / emissive); also a JT writer / builder, JSON dump, glTF and USD export; Cargo + pytest + visual-regression tests | **Best candidate.** Permissive, current design, assembly tree and colours, Python API, Linux wheels via CI. Young (43-48 commits, no releases, 4 stars), so pin a commit and test on the owner's files. Meshes only: no B-rep, no PMI |
| [Open-Cascade-SAS/JT-Assistant](https://github.com/Open-Cascade-SAS/JT-Assistant) | C++ (OCCT module `TKJT`), **GPL-2.0** | 2 (3 forks) | JT mesh reader + a viewer | The one the owner found. A single-commit publication snapshot, no releases. **GPL-2.0 is not AGPL-3.0-compatible unless the files say "or later"**: check headers first. Old JT spec level. Not recommended as the base |
| [jriegel/PyOpenJt](https://github.com/jriegel/PyOpenJt) | C++ + Python, GPL-2.0, derived from the OCC JT reader and the oce-jt / TKJT forks | 19 | Meshes; no assemblies yet | **Deprecated by its own author in favour of FerroJT.** Skip |
| [cbsghost/oce-jt](https://github.com/cbsghost/oce-jt) | C++, GPL-2.0 | 28 | JT reader + assistant (OCE fork) | Last updated Aug 2019. Skip |
| [bitbybit3d/dxjt_toolkit](https://github.com/bitbybit3d/dxjt_toolkit) | C++ | 32 | JT 8.0-10.5, assembly structure, writes JT 8.1 | Its README says the code is **"not free, only open source about usage and demonstration cases"**: not usable in the AGPL repo; Windows x64 build. Skip unless the licence is clarified with the author |
| [TobiasMusin/Voyager](https://github.com/TobiasMusin/Voyager) | Java, Apache-2.0 | 2 | JT 10 scene graph, positions + triangles to glTF | Self-described experimental, no normals / materials / hierarchy. Skip |
| [corubolo/jt-java](https://github.com/corubolo/jt-java) | Java, licence not stated | 7 | Faceted data + scene graph | "Not actively developed". Skip |
| [viachpaliy/JTSharp](https://github.com/viachpaliy/JTSharp) | C#, licence not stated | 9 | JT decode | Last updated Aug 2021. Skip |
| Siemens JT Open Toolkit, Open Cascade JT Component, CAD Exchanger, Datakit | C++ / commercial | n/a | Full read (B-rep, PMI) and write | Proprietary and royalty-bearing: only for a private hosted backend, and an owner decision |

**What this means.** Every open option reads the **tessellated** content of a JT (the LOD triangle meshes) and the assembly tree.
None reads the B-rep (JT only holds it in XT segments) or writes a CAD-quality JT. So the open route gives **JT import as a mesh
reference** (the same triangulation-only Body STL / OBJ / glTF imports make). That is what a viewer / reference use needs. It does
not give a parametric solid, and **JT export is not realistic** (FerroJT's writer rewrites meshes in JT's own family; useful to
keep tessellated geometry, but it is not an interchange export of a DIDSA Part: do not promise it, and decide separately whether
"export a mesh JT" is worth having).

**Recommended route: FerroJT behind a small converter, not linked into the backend's Python process.**
1. **Spike (2-3 days, no product code), result in `docs/jt-spike.md`.** Get 4-5 real `.jt` files from the owner (a part, an assembly,
   one from each CAD system they use; ask the JT versions). Build FerroJT at a pinned commit; run its JSON dump and glTF export on them;
   check: meshes match the CAD model's size (JT units), assembly transforms and instancing, colours, LOD choice (use the finest, or
   pick by triangle budget), speed and memory on a large assembly, a corrupt file (no panic; a clean error), JT versions it
   refuses. Compare with a second reader if one file fails. Check `git log` for activity and open issues / PRs (9 open PRs seen).
2. **If it passes, integrate as a subprocess**, the lowest-risk shape: a `ferrojt` command-line binary (MIT/Apache, so it can be
   shipped next to the AGPL backend; no licence mixing) that writes a **glb** (the project already imports glTF:
   `decode_gltf` in `mesh_import.py`). `jt_import.py` runs it on a temp file with a timeout and size limit, then reuses the glTF path.
   The Python package (`pip install ferrojt`, abi3) is the alternative if the binary is awkward in the Docker image: pin the
   version in `backend/environment.yml` (pip section) and `backend/Dockerfile`.
   **Assembly structure**: the glTF export may flatten or keep nodes; per-part Bodies (each part its own Body with its transform and
   colour) are better than one fused mesh. Prefer the JSON dump / Python API for the tree if glTF loses it, and create one
   `ImportFeature` Body per part (watch the Body-count limit and the `#N` multi-solid naming in `extrude._register_solids`).
3. `ImportSourceFormat.JT = "jt"`; `resolve_import` dispatches to the converter inside the existing `MeshImportError` handling.
4. Client and VR: the same one-liners as IGES (`'jt'`, extensions `['jt']`; VR `_BACKEND_IMPORT_FORMATS` and `MODEL_EXTENSIONS`).
   The import dialog should say "JT is imported as a mesh (no editable faces)", and the Body shows as a reference mesh like STL.
5. Tests: fixtures from the spike (small JT files; check their licence before committing them: use the owner's own or
   FerroJT's samples if their licence allows), a part and an assembly case, a corrupt file, a size / time limit test.
6. **JT export:** not built. The UI says "JT export is not available" (no dead button). Revisit only if the owner needs it and either a
   licensed SDK or FerroJT's writer is shown to produce files their other CAD tools open.

**If the spike fails** (files from the owner's CAD systems do not decode): fall back to asking for STEP / glTF from the source CAD,
and ask FerroJT's author (the same person as PyOpenJt, who responds on the repo) with the failing file; a licensed SDK is the last resort.

---

## F-5: mesh viewer support for the new formats

The viewer (`client/lib/mesh_viewer/mesh_viewer_screen.dart`) decodes **on the device, in an isolate, with no backend**
(`_decodeAndDecimate` handles `stl`, `obj`, `gltf`, `glb`; `_supportedExtensions` at ~line 197; decoders in `mesh_data.dart`).
IGES is a B-rep: it cannot be decoded in Dart, it needs tessellating, and that needs OCCT. So:

1. **New small backend endpoint**, e.g. `POST /convert/mesh` (body: `source_format` + `data_base64`, optional
   `linear_deflection`; response: a `.glb`), stateless (no document, no Part created). It runs the same decode as
   `resolve_import`, meshes with `BRepMesh_IncrementalMesh`, and encodes with the existing `encode_glb` in `mesh_export.py`.
   Cap the upload size and the triangle count; reuse the import errors. This is the single new piece; STEP gets the same path
   for free (the viewer cannot open `.step` today either; add it: `step`, `stp`, `iges`, `igs`, and `jt` if F-4 lands).
2. **Viewer**: add the B-rep extensions to `_supportedExtensions` and the file picker. For those, `_decodeAndDecimate` is not
   used: read the file by path (not through the platform channel; the crash note on the function explains why), POST it
   to `/convert/mesh`, then feed the returned glb bytes to the existing `decodeGltf(bytes, maxTriangles:)` so decimation, up-axis,
   mirror and the export-reduced-mesh buttons keep working. **When no backend is configured**, show "Opening IGES/STEP needs the
   DIDSA-CAD backend; connect one in Settings" instead of failing.
   (Check what the mesh viewer does about a backend today: it may have none. If so, the connection settings (`config.dart`,
   `server_management/`) are the existing way to get one; do not add a second.)
3. **Cheap mesh formats worth adding at the same time** (pure Dart, no backend, each small and testable against the existing
   `mesh_data.dart` pattern): **PLY** (photogrammetry output, the viewer's stated audience, ASCII and binary little-endian) and
   **3MF** (zip + XML). Optional; do PLY first if the owner agrees. Not JT in Dart (see F-4).
4. Tests: extension routing, the "no backend" message, `decodeGltf` on the endpoint's output (fixture), and a backend test for
   `/convert/mesh` (box → glb with the right triangle count and bounds).

---

## Open questions for the owner (the plan assumes the defaults)

1. F-2: leave "orbit about the point under the middle press" (D2) in? **Default: yes.**
2. F-3: IGES export entity type: B-rep solids (type 186) by default? **Default: yes; faces-only as a constant.**
3. F-4: which JT versions and CAD systems do your files come from (and can you share samples)? **Default: FerroJT spike, then mesh import only.**
4. F-5: add PLY / 3MF to the viewer now? **Default: PLY yes, 3MF later.**
