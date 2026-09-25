# Save / Load / Project Pipeline — Current-State Findings

Investigation date: 2026-09-25. This is a **read-only findings doc**, written to capture
the current behavior before planning an overhaul. No code changes were made as part of
this investigation.

Repo: `client/lib/` (Flutter/Dart client), `backend/app/` (Python backend). Related prior
design docs: `docs/assembly-scope.md`, `docs/ai-modelling/13-multi-part-assembly-overhaul.md`.

---

## 1. Every distinct save-related user-facing action

All entries live in the File menu (`client/lib/viewport3d/part_toolbar.dart`, wired
~line 310–330) and are implemented as private methods on `_PartScreenState` in
`client/lib/viewport3d/part_screen.dart` (~21.8k lines — effectively a God-object screen).
There is no dedicated save/persistence controller class for the single-file flow; it's
all inline in `PartScreen`.

### A. "Save" (legacy, single whole-session file)
- `part_screen.dart:9084` `_saveNativeFile()`.
- Builds export bytes via `_buildNativeExportBytes()` (`part_screen.dart:9009`), calling
  `DocumentApiClient.exportNative()` with **no `partId`** — dumps the **entire current
  backend session** (every loaded Part's Features + Sketches, including every assembly
  Occurrence's sub-parts) into one flat JSON blob, plus client-only extras
  (`hidden_feature_ids`, `section_planes`).
- If `_lastSavedFilePath` is known and trustworthy (desktop only — see §4), writes
  straight to that path via `dart:io`, no dialog.
- Otherwise falls to `_saveNativeFileViaDialog()` (`part_screen.dart:9057`), using
  `FilePicker.platform.saveFile(dialogTitle: 'Save Project', ...)`. On desktop this only
  returns a path; the code writes the bytes itself via `dart:io` right after (there's a
  comment explaining `file_picker`'s desktop plugins silently ignore the `bytes:` param).
  On mobile, `file_picker`'s own native save path does the write.
- Result: one `*.DIDSAprt` file containing the **whole multi-part session** as a flat
  blob — not a true multi-file project. Cross-references between parts are not stored as
  file paths in this mode (this is the pre-assembly format, unmodified).
- Trigger: File > Save.

### B. "Save As" (legacy)
- `part_screen.dart:9105` `_saveAsNativeFile()`.
- Same export logic as Save, but always suggests a fresh generic filename
  (`'${_part?.name}.DIDSAprt'`) and always goes through `_saveNativeFileViaDialog` —
  deliberately skips Save's "reuse known path" optimization.
- Trigger: File > Save As.

### C. "Save All" (multi-file project / assembly)
- `part_screen.dart:11046` `_onSaveAllPressed()` → `AssemblyDocumentClient.saveAll()`
  (`client/lib/assembly/assembly_document_client.dart:102`).
- Entirely separate machinery from A/B (the "Phase 15" / `docs/assembly-scope.md` §6
  multi-file mechanism):
  1. `_ensureProjectRoot()` (`part_screen.dart:10933`) resolves/picks a `ProjectRoot`
     (a folder, not a file — see §2).
  2. Exports the full session (`exportNative()`, no partId) to enumerate every loaded Part.
  3. For every Part **not yet** in `_relativePathByPartId`, shows
     `showRelativePathPromptDialog` (`client/lib/viewport3d/relative_path_dialog.dart:21`)
     — one dialog **per un-pathed part, sequentially** — "Save "$partName" as…".
  4. Once every part has a path, `AssemblyDocumentClient.saveAll(...)`:
     - `stampExternalRefs()` (`client/lib/assembly/save_all.dart:22`) rewrites every
       Occurrence's `external_ref` to the now-known relative path of the Part it resolves
       to (this is what makes the files re-openable as a linked assembly).
     - Re-imports the stamped document.
     - Loops `(partId, relativePath)` → `savePart()` (`assembly_document_client.dart:79`)
       — per-part `exportNative(partId: partId)` + `StorageService.writeFile(root, ...)`.
- Result: **N separate `.DIDSAprt` files**, one per Part, cross-referencing each other via
  `Occurrence.external_ref` relative paths. This is the true multi-part assembly format.
- Trigger: File > Save All.

### D. "Open" (legacy, single file)
- Reads one `.DIDSAprt` file via `file_picker`'s `pickFiles`, imports as the whole
  session. Counterpart to A/B.

### E. "Open Project…" (multi-file assembly)
- `part_screen.dart:11113` `_onOpenProjectPressed()`.
- `_ensureProjectRoot()` → `showOpenProjectPathPromptDialog`
  (`relative_path_dialog.dart:113`) → `AssemblyDocumentClient.openAssembly(root, path)` →
  `AssemblyGraphComposer.compose()` walks every `Occurrence.external_ref` transitively,
  reading/caching each referenced file → one combined import payload →
  `DocumentApiClient.importNative`. Pushes a **fresh `PartScreen`**, seeded with
  `initialRelativePathByPartId` so a later Save All knows where each part already lives.
- Counterpart to C.

### F. Creating a new part/occurrence inside an assembly ("Create Component…")
- `part_screen.dart:10960` `_onCreateNewComponentPressed()`. See §3 for the full trace.
- Involves up to 3 separate prompts (name, folder, path) plus a possible 4th later at
  Save All time for the parent part — see §3 and §5.

### G. "Add Component" (insert an *existing* file as an occurrence)
- `_onInsertComponentPressed()` (`part_screen.dart:10815`) — `FilePicker.pickFiles`,
  merges via `mergeComponentIntoDocument`. Not a save, but its `externalRef` is set to the
  picked file's bare display name (not a real relative path — flagged in code comments as
  "a real gap"), corrected later by Save All's path-stamping.

### H. "Locate missing file" — re-link an unresolved Occurrence
- `_onLocateMissingFilePressed()` (`part_screen.dart:10866`) — confirmation dialog + file
  picker, `relocateOccurrenceInDocument`. Shares the file-picker/merge machinery above.

### I. Export (STEP/STL/OBJ/glTF)
- `_exportPart` (~`part_screen.dart:9296–9364`) — geometry interchange, unrelated to
  project persistence, via `showExportFormatDialog`.

---

## 2. What is a "Project"?

**There is no `Project` class.** No manifest file (no `project.json` or similar) exists
anywhere. "Project" is really two things layered together:

### a) `ProjectRoot` — just a folder handle
`client/lib/storage/project_root.dart` — a `sealed class ProjectRoot` with three variants:
- `DesktopProjectRoot(String path)` — plain OS directory.
- `SafProjectRoot(treeUri, displayName)` — Android SAF tree URI
  (`SafUtil.pickDirectory(persistablePermission: true)`).
- `IosProjectRoot(bookmarkBase64, displayName)` — iOS security-scoped bookmark.

It holds **no manifest, no list of parts, no metadata** — just a reference to a folder.
Resolved via `StorageService.pickOrCreateProjectRoot()` / `lastUsedProjectRoot()`,
persisted as an opaque key in `RecentProjectStore` (`client/lib/storage/
recent_project_store.dart`, via `shared_preferences`).

### b) The "project" content is an implicit graph of `.DIDSAprt` files
A project is: *a folder, plus whatever `.DIDSAprt` files happen to be under it, linked to
each other by relative-path references.* The graph is discovered lazily, never declared:
- Each `.DIDSAprt` file is a single Part's export (`schema_version`, `document: {id,
  root_part_id, parts: [exactly one part]}`, `sketches: [...]`).
- `Occurrence.external_ref` (client: throughout `part_screen.dart`/`add_component.dart`;
  backend: `backend/app/document/models.py` ~line 3115, `class Occurrence`) is a
  root-relative path string pointing at another `.DIDSAprt` file — the only "project
  structure" that exists.
- `AssemblyGraphComposer.compose()` (`client/lib/assembly/assembly_graph_composer.dart:93`)
  discovers the graph at Open-time: recursively reads files, follows every `external_ref`,
  dedups by relative path, detects cycles (`AssemblyGraphCycleException`), builds one
  `ComposedAssemblyGraph` payload plus `relativePathByPartId` (needed so a later Save All
  knows which file each Part id should write back to) and `staleRelativePaths` (fallback
  to cached copy if a live read fails — `FileCache`).
- `AssemblyDocumentClient` (`client/lib/assembly/assembly_document_client.dart`) ties
  `ProjectRoot` + `StorageService` + `AssemblyGraphComposer` + `DocumentApiClient`
  together for `openAssembly` / `fetchAssemblyMesh` / `savePart` / `saveAll`.

### How this differs from a single Part/Assembly file
- **Legacy single-file Save** dumps the whole in-memory session into one flat JSON file;
  occurrence `external_ref`s are left stale/null for merged components. Effectively a
  "session dump," kept unchanged when assemblies were added ("fully additive... which
  stay exactly as they are" — direct quote, `part_toolbar.dart:84`).
- **"Project" (multi-file assembly)** is the set of individually-saved-and-linked
  `.DIDSAprt` files under a `ProjectRoot`, reconstructed into one in-memory session only
  when opened via `AssemblyGraphComposer.compose`.
- These are **not interchangeable and not automatically reconciled**. A session opened
  via legacy "Open" has no `ProjectRoot`/`relativePathByPartId` until something calls
  `_ensureProjectRoot()` (Save All, Create Component, or "Continue with AI").

---

## 3. Traced flow: new part/occurrence inside an assembly

Entry point: Assembly lens → "Add" FAB → `showAssemblyAddMenu`
(`client/lib/viewport3d/add_button_menu.dart:63`) → "Create Component…" →
`_onAssemblyAddPressed` (`part_screen.dart:10785`) →
`_onCreateNewComponentPressed()` (`part_screen.dart:10960`).

1. **Dialog: "Create Component" / name field** — `_promptComponentName()`
   (`part_screen.dart:11013`, plain `AlertDialog` + `TextFormField`, defaults to
   "New Component"). Purely a *logical name* for the new backend Part
   (`DocumentApiClient.createPart(name)`) — nothing to do with files yet.
2. Backend creates the Part; client merges it as a new `Occurrence` on the current root
   Part (`mergeComponentIntoDocument`, `client/lib/assembly/add_component.dart:63`) and
   re-imports (`_api.importNative(merged)`). No dialog here.
3. **Dialog (conditional): folder picker** — `_ensureProjectRoot()`
   (`part_screen.dart:10933`). Only shows a picker the *first* time in a session with no
   `ProjectRoot` yet (tries in-memory root → `StorageService.lastUsedProjectRoot()`
   silently → only then a real native folder picker). A no-op on any subsequent
   save-related action in the same session.
4. **Dialog: relative path prompt for the new component** —
   `showRelativePathPromptDialog(title: 'Save "$name" as…', initialValue: name,
   skippable: true)` (`relative_path_dialog.dart:21`) — a *second* text-entry dialog
   immediately after step 1, pre-filled with the same string just typed. This is the
   likely source of the "asked to save the same thing twice" perception. Skippable
   ("Skip — save later"). If accepted, stores `_relativePathByPartId[newPartId] = path`.
5. **Later — "Save All"** (`_onSaveAllPressed`, `part_screen.dart:11046`): calls
   `_ensureProjectRoot()` again (no-op), exports the full session, then loops over
   **every currently-loaded Part with no entry in `_relativePathByPartId`** and shows the
   *same* `showRelativePathPromptDialog` again (not skippable this time) for each one.
   - If step 4 was answered, the new component itself is **not** re-prompted.
   - But the **parent/root assembly Part** (the one the component was added into) is
     never given a path by any step above — `_onCreateNewComponentPressed` only ever
     assigns a path to the part it just created, never to the part it modified. So Save
     All will also prompt for the parent's filename — a genuinely different file, but it
     lands right after and reads as "yet another save dialog for what I just did."
   - If step 4 was skipped, Save All prompts for that same new part again — a real,
     non-cosmetic second prompt for the identical file.

**Concrete root-cause call sites for the "redundant" feeling:**
- `part_screen.dart:11013` (`_promptComponentName`) immediately followed by
  `relative_path_dialog.dart:21` via `part_screen.dart:10997` — two separate free-text
  dialogs (backend Part name vs. filesystem path) both defaulting to the same string,
  fired back-to-back with nothing explaining they're different things.
- The parent Part is never auto-assigned a path when a child component is created inside
  it, guaranteeing at least one more Save All prompt even in the best case.
- Two entirely parallel save systems (legacy single-file vs. multi-file) coexist in the
  same File menu, explicitly documented as intentionally additive/non-integrated
  (`part_toolbar.dart:82-93`).

---

## 4. Android permissions / SAF involvement

**Not the driver of the repeated Create-Component/Save-All prompts.**

- No `permission_handler` usage for storage anywhere in the client (grepped for
  `permission_handler`, `MANAGE_EXTERNAL_STORAGE`, `READ_EXTERNAL_STORAGE`,
  `WRITE_EXTERNAL_STORAGE` — only unrelated hits are `speech_to_text`'s microphone
  permission).
- `client/android/app/src/main/AndroidManifest.xml` declares only `INTERNET`,
  `RECORD_AUDIO`, a Termux `RUN_COMMAND` custom permission, and
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` — **no storage permissions at all.**
- Android file access goes through **Storage Access Framework (SAF)** via
  `saf_util`/`saf_stream` (`pubspec.yaml:101-102`), wrapped by
  `client/lib/storage/saf_storage_service.dart` (`SafStorageService implements
  StorageService`). This is a **one-time, persistable grant model**:
  `SafUtil.pickDirectory(writePermission: true, persistablePermission: true)` shows the
  native picker once; the tree URI is persisted (`RecentProjectStore`) and re-validated
  (not re-prompted) on later launches via `SafUtil.stat(...)` —
  `lastUsedProjectRoot()` (`saf_storage_service.dart:55`) only falls back to a fresh
  picker if that stat returns null (revoked grant, reinstall, etc.) — expected behavior,
  not a bug.
- Writes on Android go through `SafStream.writeFileUriBytes`/`writeFileBytes` against the
  resolved SAF document URI — a direct write, no re-prompt per write.
- A separate, already-diagnosed bug **does** exist in the **legacy single-file Save**
  path on Android/iOS: `file_picker`'s `saveFile()` returns a fabricated path (guessed
  from `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)` on Android),
  unrelated to where SAF actually wrote the file. Reusing that fake path for a silent
  rewrite is denied by scoped storage, so `_saveNativeFile`'s try/catch falls back to
  re-showing the dialog **every single time** on Android — documented in the comment on
  `_canPersistFilePathForReuse` (`part_screen.dart:8980-9001`). Fixed for desktop only
  (gating "reuse last path" to desktop); Android/iOS still fall through to a dialog on
  every plain Save, by design of the workaround.

Net: SAF/scoped storage is **not** what produces the multi-prompt Create-Component/Save
All chain — that's pure app-level UX/flow design. SAF *is* the confirmed root cause of a
separate, distinct bug: legacy plain Save re-prompting for a location every time on
Android because `file_picker`'s returned path can't be trusted for a silent rewrite.

---

## 5. Overall assessment

The system is genuinely redundant/confusing, for two independent, stacked reasons:

1. **Two parallel, non-integrated persistence systems share one File menu.** The legacy
   single-file "session dump" (Save/Save As/Open) predates assemblies and was
   deliberately left untouched when the multi-file system (Save All/Open Project) was
   added — an explicit, acknowledged design decision, not an oversight. Nothing in the UI
   distinguishes which is "the real save" for an assembly; either can be invoked on the
   same session, producing similar-looking prompts that write to entirely different,
   mutually-unaware formats/locations. This is the largest structural source of confusion.
2. **Within the multi-file flow, creating a component asks for the same string twice in
   immediate succession** (component name, then save-as filename pre-filled with that
   name), and because the parent Part is never given a path at creation time, **Save All
   predictably asks at least once more** shortly after for the parent file. None of these
   three prompts is a literal duplicate write of the same file, but nothing explains the
   distinction, so it reads as redundant even though the underlying data model is sound.

**Root cause, concretely:**
- No unification between the legacy single-file path and the `ProjectRoot`-backed
  multi-file path — both real, both wired into the same menu, confirmed-deliberate
  "add, don't replace."
- `_onCreateNewComponentPressed`'s "name it" → "where to save it" two-dialog sequence,
  plus never assigning the *parent* part a path, guarantees ≥2 prompts up front and ≥1
  more on the next Save All for what the user experiences as one action.
- SAF/Android permission handling is **not** the cause of this specific multi-prompt
  chain (its persisted-grant model correctly avoids repeat OS prompts); it *is* the
  confirmed cause of a separate legacy-Save-on-Android repeat-dialog bug.

**Directions a fix could take** (not decided — for the planning session to weigh):
- Deprecate/hide the legacy single-file Save/Save As/Open once a project root exists, or
  clearly separate them in the UI (e.g. "Quick Save (local file)" vs. "Project").
- Merge "name this component" and "where to save this file" into one prompt, or
  auto-derive the filename from the name and skip the second prompt by default.
- Auto-register the *parent* Part's path (if not yet known) at the same moment a new
  child component's path is captured, so Save All doesn't need a second round for what
  was really one user action.
