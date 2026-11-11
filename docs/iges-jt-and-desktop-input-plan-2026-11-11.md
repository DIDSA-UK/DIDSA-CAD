# IGES / JT file support and desktop-mode mouse input: plan

Source: the owner's testing notes of 2026-11-11 (Flutter client on a phone in desktop mode; file-format request).
This doc is for the implementation session. Code pointers were read on branch `ccr-dec7d67f-ipq5rn` (= `main` plus this doc).
Line numbers drift, so search for the named symbol. **Nothing here was run**: no OCCT, no Flutter and no device were available
while planning. Where a cause is a guess from reading, it says so and the first step is how to confirm it.
**Reviewed 11 Nov** (second pass against the code): F-3's surface handling corrected (an import is already one Body whatever its
shape), F-4's per-part Bodies corrected (an ImportFeature is always one Body), F-5 adjusted (the mesh viewer is opened before connecting).

The VR items from the same notes are in `DIDSA-UK/DIDSA-VR`, `docs/vr-feedback-2026-11-11-plan.md`. F-3 adds the new
extensions to the VR client's file lists, and F-6 needs the VR plan's V-9 (VR saving one file per Part) before it reaches VR.

| Item | Summary | Kind | Size |
|---|---|---|---|
| F-1 | Desktop mode: Ctrl/Shift + middle drag intermittently orbits instead of pan / zoom | Bug (cause unconfirmed) | Small-medium |
| F-2 | Desktop mode: a left click with a mouse sets a rotation centre; not wanted for a mouse | Bug / behaviour change | Small |
| F-3 | IGES import and export (Part and assembly), colours and names where IGES allows | Feature | Medium |
| F-4 | JT import via an open reader (FerroJT recommended); no export | Feature, spike first | Medium (after the spike) |
| F-5 | Mesh viewer: open the new B-rep formats (and any other cheap mesh formats) | Feature | Small-medium (after F-3) |
| F-6 | Import STEP / IGES / JT **as an assembly** (a Part per product, placed as occurrences), chosen at import | Feature | Large (backend + both clients) |

**Work packages for the implementation session** (one PR each, in this order):

| # | Package | Needs the owner afterwards |
|---|---|---|
| 1 | **F-2** (no pivot on a mouse click) | Quick check in desktop mode |
| 2 | **F-1 step 0**: the input debug overlay (behind a setting) | Reproduce Ctrl/Shift + middle with it on, report what it shows |
| 3 | **F-3** IGES import / export (backend, Flutter, the VR file lists) | Try their own IGES files |
| 4 | **F-6** assembly import, **STEP first** (probe, import-assembly, dialog, Save All of new Parts); IGES "one part per solid" after | Try a real multi-part STEP |
| 5 | **F-5** mesh viewer via the server (STEP / IGES), PLY in Dart | |
| 6 | **F-4 spike** (FerroJT on the owner's JT samples, `docs/jt-spike.md`); can run in parallel from the start | **Supply 4-5 JT files and their CAD systems / versions** |
| 7 | **F-1 fix** (once the overlay has named the cause), **F-4** (if the spike passes) | |

F-6 reuses F-3's IGES reader and F-4's JT reader for those formats; build it for STEP first, it has the real structure.

## Progress notes (implementation session, 11 Nov 2026)

One PR per package, stacked (each PR's base is the branch of the one before).

**Package F-2 (built).** The cause was as read. `setsPivot` in `part_viewport.dart` now comes from the pure `orbitTapSetsPivot` (`touch_pivot.dart`): false for a mouse, in selection / draw-cursor mode and with a sketch plane. `_noteDeviceKind` clears `_touchPivot` when the pointer changes to a mouse. "Rotate about here" / "Clear pivot" and D2's per-drag orbit about the point under the middle press (`_orbitPivot`) are unchanged: **the D2 orbit was left in** (a one-line change if the owner meant both). Note: with a mouse an empty-space click no longer clears a menu-set pivot (use "Clear pivot"), per the plan's "exactly as if no pivot code existed". Tests: pure `orbitTapSetsPivot` tests run here; the two new PartViewport widget tests (mouse click sets no pivot, finger still does, mouse after finger drops it; menu pivot works with a mouse) **skip without a GPU, so they did not run here**. Check in desktop mode: a left click on the model should not plant the pivot marker; two-finger/touch tap still does.

**Package F-1 step 0 (built; no fix).** `lib/viewport3d/input_debug.dart` + a Controls switch "Show input debug" (off by default, `ControlsPreferences.showInputDebug`, in the reset). With it on, the 3D viewport draws one line bottom-left for the last pointer event (down / move / hover / up / cancel): device kind, pointer id, buttons as bits, `HardwareKeyboard` Ctrl and Shift, the `MouseNavAction` the table picks, and `_mouseNavPointer`; the same line goes to `debugPrint` as `DIDSA input: ...` (read it with `adb logcat -s flutter`). **Only the 3D part viewport has it**: the 2D sketch canvas and the mesh viewer use the same function but are not instrumented yet. No navigation behaviour changed; **F-1's fix is waiting on the owner's reading** (hypotheses 1-4 above). Tests: `test/input_debug_test.dart` (format, setting round trip, note on/off with a simulated Ctrl, the overlay widget). **Owner:** turn it on in Controls, reproduce Ctrl/Shift + middle after switching to desktop mode several times, and report the line on a failing drag (look at `ctrl=`, `shift=`, kind, and whether `nav=` is set).

**Package F-3 IGES (built, backend + Flutter; the VR file-list lines are in the VR PR of the same name).**
- Verified first: `IGESControl_Reader` / `_Writer`, `IGESCAFControl_*`, `Interface_Static`, `BRepBuilderAPI_Sewing`, `ShapeFix_Shape` / `ShapeFix_Solid` all import in the pinned pythonocc `8.0.1.2`.
- Backend: `ImportSourceFormat.IGES`; `import_geometry._shape_from_iges` (temp `.igs`, `xstep.cascade.unit` set to MM, same error mapping as STEP) then `_heal_to_solid` (ShapeFix, then sew the faces and, if every sewn shell is closed, `SolidFromShell`, else leave the sewn shell); `ImportFeatureResponse.solid` (create response only, STEP and IGES; None otherwise); `app/document/iges_export.py` (`IGESControl_Writer("MM", mode)`, `IGES_BREP_MODE = 1` default, `IGES_FACES_MODE = 0` constant) with `GET /parts/{id}/export/iges` and `/export/assembly-iges` (`model/iges`, `{name}.igs`). Native format round-trips `source_format: iges` with no further change. Tests: `backend/tests/test_iges_import_export.py` (12: box and cylinder round trip, faces mode, open surfaces stay a shell, inch and metre files, HTTP import `solid` true / false, corrupt file 422, both export endpoints, empty part 400, native round trip).
- **Differs from the plan / not done:** **colours and names are not written or read** (the plan's nice-to-have: `IGESCAFControl_*` is left for later); the export is checked by reading it back with our own reader, **not opened in another CAD system or viewer**, so "mode 1 is what importers want" is untested; `solid` is also reported for STEP (cheap, same code path); a faces-mode file with a closed set of faces comes back as a solid.
- Flutter: IGES in the import (`iges`, `igs`) and export dialogs (saved as `.igs`: `ExportFormatOption.fileExtension`), `FeatureDto.solid`, a snackbar "Imported as surfaces (not a closed solid)" when `solid == false`, doc comments. Tests: `test/iges_formats_test.dart`.
- **Owner:** import your own IGES files (solids and surface-only), check the size, the "surfaces" message and that the export opens in your other CAD tool.

**Package F-6 CAD half: assembly import, STEP first, then IGES one part per solid (built; the VR choice is a separate VR PR that must follow V-9).**
- **Backend** (`app/document/step_assembly.py`, endpoints in `router.py`): `POST /import/probe` (structure counts, no geometry; STEP and IGES), `POST /parts/{root}/import-assembly` (insert as a sub-assembly Occurrence through `merge_component_into_document` then `import_native`) and `POST /import/assembly` ("open as new": the imported top becomes the root, a full replace built and validated first). STEP is read through XCAF (`STEPCAFControl_Reader`, the `TDocStd_Document("any-label")` idiom): one Part per distinct prototype (a repeated part is one Part with several Occurrences), `TopLoc_Location` -> a rigid `RigidTransform` (rotate about the origin then translate), names from the labels, a colour from the XCAF colour tool as the Part's `appearance`, the first placement of the top assembly `fixed`. A **mirrored or scaled placement of a leaf is baked** into its own Part ("<name> (mirrored)") at identity; a mirrored / scaled sub-assembly, a product with no shape and one that cannot be re-encoded are **skipped and reported** ("35 of 37 parts imported; 2 skipped"), never sinking the import. Caps: 2,000 distinct parts (`import_too_large`), a 120 s read (`import_too_slow`; the thread is abandoned, not killed). File names are sanitised and unique ("Bolt", "Bolt 2"); `suggested_files` are `<folder>/<File>.didsa`, the folder named after the file. **IGES:** `mode` is implied by the format: one Part per solid ("Solid 1..n", identity placements, no hierarchy) under a root named after the file. Tests: `backend/tests/test_import_assembly.py` (12, fixtures made with OCCT's own XCAF writer: probe counts, one Part per prototype, poses, mirrored baking, colour, names, both endpoints, **the world bounding box of the inserted assembly equals the flat import's**, skipped product, the cap, corrupt / mesh formats, IGES solids, the transform round trip).
- **Flutter:** after the format, a STEP / IGES file with several products asks "As an assembly (suggested) / As one part" with the counts (`import_assembly_dialog.dart`; a probe that fails falls back to one part with a note); an assembly import gives each new Part the suggested path and marks it "never written", so the **existing Save / Save All writes them** into the folder beside the root file and stamps the occurrences' `external_ref` (the Create Component path). Tests: `test/import_assembly_test.dart`.
- **Differences / not done / not verified:** colours are the Part's appearance only (no per-face or per-instance colours); no `TDataStd` metadata beyond names; the planned "Save All of new Parts" **has no dedicated test** (it reuses `_saveFocusedPart`; I did not run a save and reopen); a mirrored sub-assembly is skipped rather than baked; assemblies are not meshed-once-per-prototype by anything new (the existing per-Part cache already does that); JT is not included (waits on F-4's spike); the 120 s read cap cannot kill a running OCCT call. **Owner:** import a real multi-part STEP in the flat app, check the part count and names, Save, reopen the root file and confirm every reference resolves.

**Package F-5: mesh viewer formats (built; STEP / IGES through the saved server, PLY in Dart).**
- **Backend:** stateless `POST /document/convert/mesh` (`source_format` step | iges, `data_base64`, optional `linear_deflection`) -> a `.glb` (`model/gltf-binary`), nothing stored, no Part made; same readers as `resolve_import`, `_merged_body_mesh_data` + `encode_glb`; capped at 150 MB upload (413) and 3,000,000 triangles (422 `import_too_large`, "use a larger linear deflection"). Tests: `backend/tests/test_convert_mesh.py` (6: box -> 12 triangles and bounds, IGES, nothing stored, mesh formats / corrupt / bad base64 refused, both caps, a deflection).
- **Flutter** (`mesh_viewer/`): `decodePly` (ASCII, binary little / big endian, polygons fanned, vertex normals used when present else flat normals, colour and extra properties skipped, points-only refused, in-decode decimation); the picker also takes `ply`, `step`, `stp`, `iges`, `igs`; a B-rep file is read by path, converted by `convertBrepToGlb` (the saved `ApiConfig` server; no server or unreachable -> "Opening STEP / IGES files needs a DIDSA-CAD server: connect one first", a refusal quotes the server's reason) and the returned glb goes through the existing `decodeGltf`, so decimation, up-axis, mirror and export work unchanged. Every mesh format still works with no server. Tests: `test/mesh_viewer_formats_test.dart` (PLY cases, routing, the client with a mock server, and `decodeGltf` on the endpoint's real output: `test/fixtures/convert_mesh_box.glb`).
- **Not done / not verified:** the viewer screen itself (picker and error banner) is not exercised (GPU tests skip here); the conversion's wait is a spinner-less decode stage (no progress text); **3MF is not built** (the plan's default: later); JT is not included (F-4 spike). The viewer is still opened before connecting: a saved connection is whatever `ApiConfig` holds (set from the connection screen on an earlier run). **Owner:** open a STEP and an IGES in the mesh viewer with a server saved, and with none; open a photogrammetry PLY.

**Hardening pass on F-3 / F-6 (after the owner's challenge: "create IGES and STEP files yourself and run the tests").** Generated harder inputs with an independent expected result, and added FreeCAD (installed with micromamba, `/opt/tools/fc-env`) as a second application reading our files. What it found and what changed:
- **A real bug only FreeCAD could see:** the coloured IGES export (the CAF writer) wrote trimmed surfaces (type 144), not B-rep solids; FreeCAD read loose faces. Our own reader healed them into a solid and hid it. Fixed (`write.iges.brep.mode` set for the CAF writer); tests check the raw entity types (186, not 144) and, when FreeCAD is installed (`FREECADCMD`), that FreeCAD reads solids with the right volume.
- **IGES healing was too weak:** surfaces with gaps of 2 microns or more stayed open, and a sphere (one periodic face) never closed. Sewing now climbs a tolerance ladder scaled to the model (1e-4 mm, then 1e-5 / 1e-4 / 1e-3 of the bounding diagonal), wraps a lone face in a shell, and tests closedness by free edges. A 20 micron gap and a sphere now become solids; an open box, or a 5 mm "gap", correctly stay surfaces.
- **Mirrored / scaled SUB-ASSEMBLIES are no longer dropped:** they are flattened into a baked assembly Part with the composed placements (mirror-of-mirror comes out rigid and shared again). Checked against a hand-built world shape (volume and bounding box) through insert and export; FreeCAD agrees (12502.7 vs 12502.65 expected).
- **Per-instance colours** (a colour on the placement) become the Occurrence's own colour; **IGES export now carries colours** (not import).
- **Stress:** four-level nesting with shared prototypes and non-axis rotations matches the oracle to 1e-6 relative volume; 600 flat placements of 20 prototypes import in 0.3 s (payload 0.4 MB, insert plus assembly mesh 0.4 s). Tests: `test_import_assembly_stress.py` (7), 7 new in `test_iges_import_export.py`.
- **Still not covered:** files from a real CAD system (everything is generated by OCCT, FreeCAD included, so a shared-kernel blind spot remains); IGES colours on import; 2,000-part scale; the OCCT-thread-keeps-running timeout.

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
   (types 143/144/186/510/514). Checked: `extrude.py` (~2064) registers an ImportFeature as **exactly one Body keyed by the
   feature id, whatever shape `resolve_import` returns** (it deliberately skips `_register_solids`), so a faces-only IGES already
   imports and shows; nothing rejects it. What to add: `ShapeFix_Shape`, then, when there are no solids, `BRepBuilderAPI_Sewing` and
   `BRepBuilderAPI_MakeSolid` / `ShapeFix_Solid` if the sewn shell is closed, so a closed model becomes a real solid (volume, mass,
   booleans work). Leave an open model as the sewn shell. Return whether it became a solid in the response
   (e.g. `ImportFeatureResponse.solid: bool`) so the client can say "imported as surfaces (not a closed solid)".
   Note the same "one Body" rule applies to a multi-solid file: all its solids are one Body (the STEP path behaves the same today).
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
   **Assembly structure**: an ImportFeature is always **one Body** (`extrude.py` ~2064), so v1 imports a JT assembly as one mesh
   Body (all parts at their transforms; colours kept per triangle if the glTF path carries them, else one colour). Importing a
   JT (or STEP) **assembly as an assembly** (a Part per JT part, placed as occurrences) is a separate, larger feature: STEP import
   doesn't do it either. Note it as a follow-up, decided with the owner, not part of F-4.
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

0. **The viewer is offline by design today**: it is opened from the connection screen *before* connecting
   (`connection_screen.dart` ~405, `MeshViewerScreen()` takes no client), for photogrammetry files on the phone. So a backend path can
   only work when a server has been set up before; use the saved connection (`config.dart` / `server_management/`), and keep every
   mesh format working with no server.
1. **New small backend endpoint**, e.g. `POST /convert/mesh` (body: `source_format` + `data_base64`, optional
   `linear_deflection`; response: a `.glb`), stateless (no document, no Part created). It runs the same decode as
   `resolve_import`, meshes with `BRepMesh_IncrementalMesh`, and encodes with the existing `encode_glb` in `mesh_export.py`.
   Cap the upload size and the triangle count; reuse the import errors. This is the single new piece; STEP gets the same path
   for free (the viewer cannot open `.step` today either; add it: `step`, `stp`, `iges`, `igs`, and `jt` if F-4 lands).
2. **Viewer**: add the B-rep extensions to `_supportedExtensions` and the file picker. For those, `_decodeAndDecimate` is not
   used: read the file by path (not through the platform channel; the crash note on the function explains why), POST it
   to `/convert/mesh`, then feed the returned glb bytes to the existing `decodeGltf(bytes, maxTriangles:)` so decimation, up-axis,
   mirror and the export-reduced-mesh buttons keep working. **When no server is saved or it doesn't answer**, show "Opening IGES /
   STEP needs a DIDSA-CAD server: connect one first" instead of failing.
2b. **JT in the viewer, offline (option, after F-4's spike).** JT carries its own meshes, so it does not need the server. FerroJT is
   MIT / Apache-2.0, which the Apache client may ship (`LICENSING.md`: only backend / GPL code is barred). A Rust library through
   FFI (`flutter_rust_bridge`, built for Android arm64 / x86_64 and Windows / Linux) decoding to the viewer's `DecodedMesh` would open JT
   on the phone with no server. Cost: a Rust toolchain in the client build and a native library per platform, a first for this
   client. Recommend only if the owner needs offline JT viewing; otherwise JT goes through the same server endpoint as IGES.
3. **Cheap mesh formats worth adding at the same time** (pure Dart, no backend, each small and testable against the existing
   `mesh_data.dart` pattern): **PLY** (photogrammetry output, the viewer's stated audience, ASCII and binary little-endian) and
   **3MF** (zip + XML). Optional; do PLY first if the owner agrees. Not JT in Dart (see F-4).
4. Tests: extension routing, the "no backend" message, `decodeGltf` on the endpoint's output (fixture), and a backend test for
   `/convert/mesh` (box → glb with the right triangle count and bounds).

---

## F-6: import as a real assembly (STEP first, then IGES and JT)

**Today** every import is one `ImportFeature` and one Body (`extrude.py` ~2064), whatever the file holds: a 40-part STEP assembly
becomes one lump. It can't be mated, hidden part by part, fixed, or seen in the tree, which matters most in VR (mates need separate
occurrences).

**What the user sees.** The import dialog gets a second step after the format (Flutter `import_format_dialog.dart`; VR: a choice on
the tablet when a file is opened from the Files page):
- **As an assembly** (default when the file holds more than one product): one Part per distinct product, one occurrence per
  placement, the product tree kept, names and colours from the file.
- **As one part** (default for a single product; today's behaviour): one Body, fast and simple.
The backend can **count the products cheaply first** (a "probe" call: read the file's structure, no geometry transfer) so the dialog
shows "This file has 37 parts in 6 sub-assemblies" and picks the default. For IGES the two choices are **one part** or **one part per
solid** (IGES has no reliable assembly structure: see below).

**Which is heavier, and which fails more?**

| | As one part | As an assembly |
|---|---|---|
| Reading | `STEPControl_Reader`, geometry only | `STEPCAFControl_Reader` (XCAF: structure, names, colours): slower and more memory on big files; the XCAF document idiom is fragile in this pythonocc build (see `step_export.py`'s notes) |
| Meshing | The whole model in one Body, **every instance meshed** | Each distinct product meshed **once**, cached per Part (`body_cache` is per Part, N placements = one recompute); **lighter** for assemblies with repeats (fasteners), about the same otherwise |
| Storage | The whole source file is embedded once in the ImportFeature | Each Part stores its own geometry: re-encode each product (a per-part STEP written from its shape, so `resolve_import` keeps working), N files on disk in the flat app; more to write at import |
| Ways to fail | Few: the file reads or it doesn't | More: products with no shape, **mirrored instances** (a negative-determinant placement can't be a rigid occurrence transform: bake those into their own mirrored Part), scaled instances (same), duplicate or illegal names as file names, thousands of tiny parts (a slow, very large tree), a product that fails to transfer (must not sink the whole import) |
| What you get | A reference shape | A working assembly: mates, fix, hide, tree, appearance per part |

So: **assembly import costs more at import time and has more ways to go wrong; one-part import is cheap and robust but a dead
end for assembly work.** Hence the choice, with a sensible default, and an assembly import that **reports per part** ("35 of 37
parts imported; 2 skipped: <names, reasons>") instead of all-or-nothing.

**Backend (DIDSA-CAD `backend/app/document/`).**
1. `POST /import/probe` `{source_format, data_base64}` → `{products, assemblies, instances, has_structure, mirrored_instances,
   name}`: XCAF read of the structure only (`XCAFDoc_ShapeTool.GetFreeShapes`, `IsAssembly`, `GetComponents`), capped in time.
2. `POST /parts/{root_part_id}/import-assembly` (insert into the current assembly as a sub-assembly occurrence) and an "open as new"
   variant (the imported top product becomes the root, like opening a native file): walk the XCAF tree; for each distinct prototype
   (`GetReferredShape`) create a Part with one ImportFeature holding that prototype's shape re-encoded as STEP, named from
   `TDataStd_Name`; for each component create an Occurrence with the component's `TopLoc_Location` as its transform (mm; split off
   any scale or mirror as described above); nested assemblies become sub-assembly Parts with their own occurrences; colours from
   `XCAFDoc_ColorTool` become the Part's appearance or appearance overrides. Build the whole result as one native payload and apply it
   through the same merge path `add_component` uses (`merge_component_into_document`, then `import_native`), so the session is only
   replaced if everything that was kept is valid.
3. Response: the new Part ids, a suggested file name per Part (sanitised, unique), and the per-part report.
4. Limits: product count and total size caps with a clear error ("this file has 4,000 parts; import as one part, or split it");
   a time cap on the read.

**Formats.**
- **STEP**: the real case (AP203 / AP214 / AP242 all carry product structure through XCAF).
- **IGES**: no product structure worth the name (some systems write subfigures, types 308 / 408, which `IGESCAFControl_Reader` maps to
  XCAF; most files are flat). Offer **one part per solid** instead: each solid of the read shape becomes a Part with one occurrence at
  identity, no hierarchy, names "Solid 1..n" or the entity labels when present.
- **JT** (after F-4): FerroJT reads the logical scene graph (parts, instances, transforms); each JT part becomes a Part whose
  ImportFeature is that part's mesh (as glb, the glTF path), each instance an occurrence. Mesh Parts can be mated on their
  triangles only as far as the mates tool supports mesh geometry today: check, and say so in the dialog if not.

**Clients.**
- **Flat app**: the new Parts have no file yet: the save path already knows a Part "that has no file yet" (the tree's hollow dot,
  `save_all.dart`). Save All must write them into a folder next to the assembly (default: `<file name>/` beside the root file) using
  the suggested names, and set each occurrence's `external_ref` to the relative path. Check the save-project pipeline docs
  (`docs/save-project-overhaul-scope.md`) for where that belongs.
- **VR**: today it saves the whole session as one snapshot file; DIDSA-VR `docs/vr-feedback-2026-11-11-plan.md` V-9 changes that to
  the flat app's one-file-per-Part Save, with the same auto-naming, so imported Parts get files the same way in both apps. Land V-9
  before F-6 reaches VR. Add the choice to the Files page import (`main.gd` `_import_external_file`), then refresh the tree and mates
  state (`mark_stale`).
- Both: the import report shown to the user.

**Tests.** Fixture STEP files (make them with the backend's own `export_step` from a test assembly where possible, so their licence is
ours): two-level assembly with a repeated part → right Part count (one per prototype), occurrence count and world poses equal to the
single-body import's solids (to tolerance); a mirrored instance → baked Part; a product with no shape → skipped and reported; probe
counts; IGES one-part-per-solid; the size cap. Flat app: Save All writes the new Parts and the root reopens with every reference
resolved.

---

## Open questions for the owner (the plan assumes the defaults)

1. F-2: leave "orbit about the point under the middle press" (D2) in? **Default: yes.**
2. F-3: IGES export entity type: B-rep solids (type 186) by default? **Default: yes; faces-only as a constant.**
3. F-4: which JT versions and CAD systems do your files come from (and can you share samples)? **Default: FerroJT spike, then mesh import only.**
4. F-5: add PLY / 3MF to the viewer now? **Default: PLY yes, 3MF later.**
5. F-6: when importing as an assembly into the flat app, where do the new part files go? **Default: a folder named after the file,
   beside the assembly.**
