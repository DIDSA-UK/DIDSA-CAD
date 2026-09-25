# Save / Project / Assembly overhaul — Scoping Document

Companion to a planning request covering: unifying the two parallel,
non-integrated persistence systems in `PartScreen`'s File menu (the legacy
single-file "session dump" — Save/Save As/Open, predates assemblies — and
the newer multi-file, folder-based system for assemblies — Save All/Open
Project, built on `ProjectRoot` + `Occurrence.external_ref` relative-path
links, no real manifest); removing the "name it" / "save it" dialog pair
that fires when creating a new component inside an assembly; giving the
parent assembly Part a save path at creation time instead of prompting for
it again at the next Save All; auto-naming components so no dialog is
needed at all by default; and adding a rename action (assembly tree,
long-press) that keeps a component's display name, its underlying Part
name, and its on-disk file in sync. Revised after a first pass raised the
question directly: **this app is pre-release, so no backwards
compatibility constraint applies** — the plan below takes full advantage
of that (no legacy format to keep alive, no migration tooling, no "two
concepts a user has to learn"), which is a materially different, simpler
answer than a released product would get. This is a **planning document
only** — no code changes were made producing it. It builds on
`docs/save-project-pipeline-findings.md` (the original read-only
investigation) and does not re-derive anything that doc already covers;
citations below use current line numbers, which have drifted from that
doc's own by roughly 1,100 lines due to unrelated feature work (Shell
body-first rework, Chamfer angle+flip, Extrude draft option) landing on
`part_screen.dart` in between.

Backend: `backend/app/document/models.py` (`Part`, `Occurrence`,
`Document`), `backend/app/document/native_format.py` (`export_native`/
`import_native`, `SCHEMA_VERSION`), `backend/app/document/router.py`
(`create_part`, `update_part`, `export_native_document`,
`import_native_document`), `backend/app/document/schemas.py`
(`PartCreate`, `PartUpdate`). Two small backend additions are proposed
this time (§3.2: `PartUpdate.name`, and extending the Occurrence PATCH
with `name_override`) — both filling a gap in an endpoint that already
exists, not new infrastructure; everything else in this document is
client-only.
Client: `client/lib/viewport3d/part_screen.dart` (the ~23k-line
`_PartScreenState` God object every save action still lives on),
`client/lib/viewport3d/part_toolbar.dart` (File menu),
`client/lib/viewport3d/relative_path_dialog.dart`,
`client/lib/viewport3d/assembly_tree_panel.dart`,
`client/lib/viewport3d/component_context_menu.dart`,
`client/lib/assembly/assembly_document_client.dart`,
`client/lib/assembly/save_all.dart`, `client/lib/assembly/add_component.dart`,
`client/lib/assembly/assembly_graph_composer.dart`, `client/lib/storage/*`
(`project_root.dart`, `storage_service.dart`, `recent_project_store.dart`,
`saf_storage_service.dart`).

**Status: all six phases implemented** (zero-dialog Create Component with
auto-naming/auto-pathing, §3.1; the assembly tree's Rename action,
backend + client + all three `StorageService` platforms, §3.2; Save/Save
As split on Project-vs-not, §3.3; accurate dirty-state tracking replacing
the unconditional exit warning, §3.4; the Open-Project prompt's
listFiles-backed picker, §3.5; Open/Open Project unified into one entry,
§5's Phase 6, once the extras-restoration design question §3.3's first
implementation pass raised was actually resolved rather than guessed at).
`dart analyze` clean across `client/lib`/`client/test`; the full `flutter
test` suite (2292 tests) passing; the full backend suite (2488 tests)
passing.

---

## 1. Grounding: what the findings doc established, restated only where a decision below depends on it

- **Two systems share one File menu, confirmed-deliberate "add, don't
  replace."** `part_toolbar.dart:83-93`'s own doc comment states it
  outright. Menu wiring: `part_toolbar.dart:309-330` (`Open…` 309-310,
  `Open Project…` 314-315, `Save` 319-320, `Save As…` 324-325, `Save All`
  329-330).
- **Legacy Save/Save As/Open** (`part_screen.dart:9239` `_saveNativeFile`,
  `:9260` `_saveAsNativeFile`, `:9212` `_saveNativeFileViaDialog`, `:9164`
  `_buildNativeExportBytes`) round-trip the *entire current backend
  session* — every loaded Part's Features/Sketches — as one flat
  `document.parts: [...]` JSON blob via `DocumentApiClient.exportNative()`
  with no `partId`.
- **Save All / Open Project** (`_onSaveAllPressed` `:11203`,
  `_onOpenProjectPressed` `:11270`, `_ensureProjectRoot` `:11090`) resolve
  a `ProjectRoot` folder (`client/lib/storage/project_root.dart` — a plain
  directory on desktop, a persisted SAF tree URI on Android, a
  security-scoped bookmark on iOS; no manifest file, no part list, just a
  folder handle), export each Part individually
  (`exportNative(partId: ...)`), stamp every `Occurrence.external_ref` to
  the now-known relative path of the Part it resolves to
  (`stampExternalRefs`, `save_all.dart:22`), and write one `.DIDSAprt` file
  per Part (`AssemblyDocumentClient.savePart`,
  `assembly_document_client.dart:79`).
- **The wire format is identical between the two systems** — both go
  through the same `export_native`/`import_native`
  (`native_format.py:1993`/`:2042`) with the same `SCHEMA_VERSION = 1`
  (`native_format.py:165`). The only structural difference is how many
  Parts one file's `document.parts` holds, and whether `external_ref` is a
  resolvable relative path or stale/null.
- **The redundant-prompt chain, traced** (`_onCreateNewComponentPressed`
  `:11117`): `_promptComponentName()` (`:11170`) is immediately followed by
  `showRelativePathPromptDialog` (`:11154-11162`) pre-filled with the same
  string. Only the *new* Part's id is written into `_relativePathByPartId`
  (`:11163`); the *parent* Part is never assigned a path here, so it's
  guaranteed to be one of the Parts `_onSaveAllPressed`'s per-missing-Part
  loop (`:11217-11232`) prompts for at the next Save All.
- **Components already have a working, but display-only, auto-name
  fallback.** `occurrenceDisplayName` (`assembly_tree_panel.dart:18-31`)
  resolves a shown label as `nameOverride` (the user's own choice) →
  `externalRef`'s file basename → `"Component N"` (an ordinal counting
  occurrences seen so far) — exactly the fallback chain §3.1 below
  proposes making real/persisted instead of computed fresh on every
  render.
- **`Occurrence.name_override` exists in the data model
  (`models.py:3293`) but has no mutation endpoint.**
  `document_api_client.dart:4571`'s own comment confirms it: of
  `hidden`/`suppressed`/`name_override`, only `hidden` has since gained one
  (`updateOccurrenceHidden`, added as an independently-omittable field on
  the same occurrence PATCH `updateOccurrenceTransform` first added) —
  `suppressed` and `name_override` still don't.
- **`PartUpdate` (`backend/app/document/schemas.py:46-59`) has no `name`
  field** — `update_part` (`router.py:3173-3190`) only ever touches Part
  Properties metadata (part_number/description/revision/remarks/supplier/
  supplier_part_number), never the Part's own `name`.
- **No rename action exists anywhere in the UI.**
  `ComponentContextMenuAction` (`component_context_menu.dart:14-25`) —
  already opened via long-press on an assembly-tree row — has no `rename`
  entry.
- **`StorageService` (`client/lib/storage/storage_service.dart`) has no
  rename/move method** — `pickOrCreateProjectRoot`, `lastUsedProjectRoot`,
  `resolve`, `readFile`, `writeFile`, `lastModified`, `exists`,
  `listFiles` only. The underlying platform capability exists on both
  platforms that would need it: the `saf_util` package (Android) already
  exposes `rename(uri, isDir, newName)` and `delete(uri, isDir)` directly
  (`saf_util-3.1.0/lib/saf_util.dart:108-151`); desktop gets it for free
  via `dart:io`'s `File.rename`/`FileSystemEntity.rename`. iOS
  (`IosStoragePlugin.swift`) doesn't have an equivalent yet and would need
  one added, mirroring what `FileManager.moveItem` already provides at the
  OS level — a real but modest gap, not a blocker.
- **No dirty-state tracking exists at all.** `_confirmExitPart`
  (`part_screen.dart:9080`) shows an unconditional "unsaved work would be
  lost" warning on every exit path. `_runGuarded` (`:20429`) is already the
  de facto choke point for essentially every backend-mutating action in
  this file (171 call sites).
- SAF/Android permission handling is confirmed **not** the cause of the
  redundant-prompt chain (findings §4) — it's the confirmed cause of a
  separate, distinct bug (legacy plain Save re-prompting every time on
  Android/iOS). Relevant here only where it constrains §3.3's Open design.

---

## 2. The model: one document, one save — no "Project" or "Bundle" for the user to learn

**Revised decision, given no backwards-compatibility constraint: don't
give the user two named concepts at all.** The first pass proposed keeping
the legacy single-file format as an explicit, user-facing "Bundle"
alongside a "Project." That was the right call *if* existing user files
had to keep opening under a name that made sense — but since this is
pre-release, that constraint doesn't exist, so it's worth asking the
sharper question directly: does the user ever need to know there are two
kinds of save destination? No.

**There is just one document.** A Part on its own is one file. The moment
it grows an Occurrence of another Part (Create Component, Add Component),
saving it needs somewhere to put more than one file — that's resolved
transparently, the first time it's actually needed, via the exact same
native folder picker that exists today (`_ensureProjectRoot`,
`part_screen.dart:11090`), with no separate "you're now in Project mode"
announcement and no user-visible name for the concept. `ProjectRoot`
itself doesn't go away — it's real, necessary plumbing (a folder handle
abstracted over desktop paths, SAF tree URIs, and iOS bookmarks) — it just
stops being something the UI ever asks the user to think about as
distinct from "saving."

Concretely:

- **Part** — unchanged (`models.py:2980`): a name, an ordered Feature
  list, the Sketches it references. Backed by exactly one `.DIDSAprt` file
  once it's ever been saved.
- **Assembly** — unchanged: not a distinct type, just a Part with one or
  more `Occurrence`s (`models.py:3228`). "Assembly lens" stays a view
  mode.
- **The whole-session flat dump retires as a *save format*.** It's not
  deleted from the codebase — `DocumentApiClient.exportNative()` with no
  `partId` is still exactly how Save All enumerates every loaded Part
  before splitting them out (`_onSaveAllPressed`'s `fullSessionExport`,
  `:11208-11213`) — it's just never again what a user's own Save/Save
  As/Save All writes to disk as a standalone file. (There's no
  "portable single-file snapshot for email" feature carried forward
  either — if that's wanted later it belongs next to STEP/STL/OBJ/glTF
  under Export, as a deliberate one-off, not as a Save entrance point;
  see §3.3's closing note.)

**What this buys, concretely:** a brand-new user's very first Save behaves
exactly like Save always has in any app — one native "where do you want
this" prompt, one file, done. Nothing about folders or projects is ever
surfaced until the user actually adds a second component, at which point
one more native folder prompt (already exactly what happens today) is all
that's added — not a new concept, just the same folder-picker moment it
already is.

---

## 3. Workstreams

### 3.1 "Create Component…" needs no dialog at all — auto-name, auto-path, rename later

The first pass proposed merging the name dialog and the path dialog into
one. Going further: **drop the dialog entirely.** Tapping "Create
Component…" should create the component immediately, the same way
Fusion 360/SolidWorks-style tools default a new component to
"Component1"/"Part1" with zero prompts and let the user rename afterward
if they care. This works cleanly here because the fallback naming
convention already exists and is already exercised as a *display*
computation — `occurrenceDisplayName`'s `"Component N"` ordinal
(`assembly_tree_panel.dart:29-30`) — this workstream just promotes it into
the real, persisted name at creation time instead of only ever being
computed fresh for display.

1. `_onCreateNewComponentPressed` (`part_screen.dart:11117`) drops the
   `_promptComponentName()` call (`:11121`, and the function itself,
   `:11170`, is removed) and instead generates a name locally —
   `"Component $ordinal"`, `ordinal` picked the same way
   `occurrenceDisplayName` already counts (occurrences on the current root
   seen so far + 1), checked against the current root's existing sibling
   occurrence names so two rapid taps never collide as "Component 3" and
   "Component 3" again.
2. `DocumentApiClient.createPart(name)` and `mergeComponentIntoDocument`
   (unchanged) run exactly as today, with the generated name as both the
   backend Part's own `.name` and the Occurrence's `nameOverride`
   (`add_component.dart:69`/`:147`, unchanged parameter).
3. `_ensureProjectRoot()` (`:11090`, unchanged) resolves a folder with no
   new dialog if one's already known. Once resolved, **register two paths
   in `_relativePathByPartId` in the same step, both silently
   auto-derived, no prompt**:
   - the new child Part's path — `withDefaultExtension(generatedName)`;
   - **the parent/root Part's path, if `_relativePathByPartId[rootPartId]`
     is still absent** — `withDefaultExtension(parentPart.name)`. This is
     the direct fix for the gap in §1: today only `newPartId`'s path is
     ever registered here (`:11163`), never `rootPartId`'s, guaranteeing a
     later Save-time prompt for the parent.
   Both derivations run through the same collision check
   `relative_path_dialog.dart:36-40` already performs
   (`storageService.resolve`) — a rare collision (re-running Create
   Component enough times to exhaust a folder's names) gets a
   numbered-suffix fallback (`Component 3 (2).DIDSAprt`), never a popup.
4. The component appears in the assembly tree immediately, named
   "Component N", with a real path already assigned. If the user wants a
   different name, they use **§3.2's rename action** — the correction
   path, not an upfront gate.

Net: 2 mandatory dialogs → 0, and the ≥1 guaranteed follow-up prompt at
the next Save All for the parent Part → 0 in the common case. `Add
Component`'s own separate, already-documented gap (a picked existing
file's `externalRef` is its bare display name, not a real relative path)
is unaffected by this workstream — it's still corrected the same way it
is today, by `stampExternalRefs` at the next Save.

### 3.2 Rename from the assembly tree — one action, three things stay in sync

New long-press action on an assembly-tree row (`AssemblyTreePanel`,
opened via the existing `showComponentContextMenu`,
`component_context_menu.dart`) that renames a component. To actually be
useful as the correction path §3.1 relies on, one rename action needs to
keep three things in sync, not just the tree label:

1. **The Occurrence's display name** (`nameOverride`) — always safe to
   change, this is what the tree literally shows
   (`occurrenceDisplayName`). Needs a small backend addition: extend the
   existing occurrence PATCH (`update_occurrence_transform`'s endpoint,
   `router.py`, already independently-omittable per field —
   `updateOccurrenceHidden`'s own addition is the precedent) to also
   accept `name_override`, plus a matching
   `DocumentApiClient.updateOccurrenceName` client method mirroring
   `updateOccurrenceHidden`.
2. **The underlying Part's own `.name`** — only meaningful, and only
   attempted, when this Part has exactly one Occurrence in the current
   session (the common case, especially now that §3.1 makes every new
   component start that way). Needs `PartUpdate` (`schemas.py:46-59`) to
   grow a `name: str | None` field and `update_part`
   (`router.py:3173-3190`) to apply it — the same omitted-vs-current-value
   convention every other field on that endpoint already follows, so this
   is a same-shape addition, not a new pattern.
3. **The on-disk file**, if this Part already has an entry in
   `_relativePathByPartId` — needs the new `StorageService.renameFile`
   (§1) implemented per-platform (`saf_util.rename` on Android,
   `File.rename` on desktop, a small `IosStoragePlugin.swift` addition on
   iOS), updating `_relativePathByPartId[partId]` to the new relative path
   afterward. Any *other* Occurrence's `external_ref` pointing at this
   file gets corrected automatically at the next Save/Save All via the
   already-existing `stampExternalRefs` (`save_all.dart:22`) — no new
   propagation logic needed there.

**When a Part is instanced more than once** (two Occurrences resolving to
the same underlying Part — a legitimate, already-supported case), (2) and
(3) are skipped: renaming from the tree only ever changes that one
Occurrence's `nameOverride`, never the shared file or the shared Part
name, since either would silently relabel every other instance's file out
from under it. The rename dialog should say so plainly when it applies
("Bracket.DIDSAprt" is used by 3 components — this renames only this one")
rather than silently doing the narrower thing with no explanation.

UI: add `ComponentContextMenuAction.rename` to the enum
(`component_context_menu.dart:14-25`) and an entry to
`showComponentContextMenu`; the handler opens a single-field name dialog
(same `AlertDialog`/`StatefulBuilder`/`TextFormField` shape as everything
else in this area) pre-filled with the current display name, and on
confirm runs the three updates above.

### 3.3 Four entrances, not more: Save, Save As, Save All, Open

**Fully implemented, including Open** (`part_screen.dart`'s
`_saveNativeFile`/`_saveAsNativeFile`/`_saveFocusedPart`/
`_saveFocusedPartAs`/`_onSaveAllPressed`/`_onOpenPressed`). The first
implementation pass shipped Save/Save As/Save All but deliberately left
Open/Open Project as two separate entries, having surfaced a real
feature-parity gap the planning pass missed: legacy `_openNativeFile`
restores two client-only extras that only live in the *root* file's own
top-level JSON keys — `hidden_feature_ids` and `section_planes` — neither
of which `AssemblyGraphComposer.compose`/
`AssemblyDocumentClient.openAssembly` (the "Open Project…" path) has ever
carried; that composer only ever merges `document.parts`, and, more
fundamentally, requires **exactly one Part per file** (it throws a
`FormatException` otherwise) — a legacy Bundle's whole point is *multiple*
Parts in one file, so the composer couldn't even read one at all, let
alone restore its extras. Phase 6 (below) resolved this not by teaching
the composer to also carry the extras, but by resolving the underlying
design question directly: **read the file first and let its own shape
decide which reader it needs**, rather than picking a reader and hoping.
A Bundle (`document.parts.length > 1`) goes through the exact same direct
`import_native` + extras-restoration `_openNativeFile` always used
(factored into `_openBundlePayload`); anything else goes through the real
composer (`_openComposedProject`). Since the two shapes are mutually
exclusive by construction (a Project's own per-Part `savePart` export
never had a way to write more than one Part into a file, and a Bundle's
`_buildNativeExportBytes` never resolves `external_ref`s into a real
graph), there's no case where the "wrong" reader could plausibly apply —
the shape check is a completeness guarantee, not a heuristic.

The first pass introduced "Save a Copy…" and "Save as Project…" on top of
the legacy four. With §2's model, neither is needed:

- **"Save as Project…" is no longer justified.** It existed to give a
  Bundle-mode session somewhere to "graduate" to. Once there's no
  Bundle/Project distinction (§2), there's nothing to graduate — Save and
  Save All already resolve a folder transparently the moment more than one
  file is actually needed. Dropped entirely.
- **"Save a Copy…" isn't needed as a Save entrance either.** A portable,
  single-file whole-session export is a real but separate need from
  "save my work" — if wanted, it belongs as an `Export` option (alongside
  STEP/STL/OBJ/glTF, `_exportPart`), not as a fifth thing living under
  Save. Not proposed as part of this overhaul; flagged only so it isn't
  silently lost as a possible future ask.

That leaves the four you'd expect, kept at their familiar names rather
than invented ones, each with one clear, non-overlapping meaning
(standard CAD convention — SolidWorks/Fusion 360 draw this line the same
way):

- **Save** (`_saveNativeFile`) — dispatches on whether `_projectRoot` is
  set. With no Project yet, it's exactly today's whole-session flat-dump
  behavior, unchanged (`_lastSavedFilePath` reuse on desktop via
  `_canPersistFilePathForReuse`, a dialog on first save). Once a Project
  exists, it calls the new `_saveFocusedPart`: saves the *currently
  focused* Part only (`_focusStack?.current ?? _part?.id`, the same
  resolution `_onCreateNewComponentPressed` already uses), not the whole
  session — stamps every `Occurrence.external_ref` across the full session
  first (`stampExternalRefs`, re-imported) so the focused Part's own file
  reflects any newly-known paths for the components it references, then
  writes just that one file via `AssemblyDocumentClient.savePart`. A
  focused Part with no known path yet (rare — realistically only "Add
  Component"/"Locate Missing File") gets one silently auto-derived via
  `_autoAssignPath` (§3.1), never a blocking dialog for a plain Save.
- **Save As** (`_saveAsNativeFile` → `_saveFocusedPartAs`) — same
  Project-vs-not dispatch. In Project mode: prompts for a new
  project-relative path via the existing `showRelativePathPromptDialog`
  (reused as-is, not a new dialog), then **always writes a fresh export**
  of the focused Part's current in-session content to that path via
  `savePart` — deliberately *not* a physical move/rename of the old file.
  This was a correction made during implementation: the original plan here
  said to reuse `StorageService.renameFile` (§3.2), but `renameFile` only
  relocates existing bytes — reusing it for Save As would have silently
  saved the Part's *old, previously-written* content under the new name
  rather than its current state, which is exactly backwards for what "Save
  As" means. If the new path differs from the old one, the old file is
  left in place rather than deleted — `StorageService` has no delete
  primitive (a deliberate scope limit, not an oversight), so an orphaned
  stale file is the honest, safe outcome, never silent data loss. A later
  plain Save targets the new path from then on (standard "Save As"
  rebinding semantics).
- **Save All** — writes back every loaded/dirty Part in the whole session,
  i.e. today's `_onSaveAllPressed` behavior, unchanged, carrying forward
  §3.1's auto-path improvements so it prompts only for a genuinely
  unpathed Part rather than anything Create Component already handled.
  For a lone Part, Save and Save All are simply identical — the same
  non-event they are in any CAD tool before an assembly exists.
- **Open** (`_onOpenPressed`) — one entry, replacing `Open…`/`Open
  Project…`. Still genuinely differs by platform for *how the root file
  gets picked* (this part of the original plan held up unchanged):
  - **Desktop** (`_openViaDesktopFilePicker`): a single native "Open File"
    dialog (`file_picker`, unchanged from the old plain Open), bytes
    already in hand from the picker. `ProjectRoot` is derived from the
    picked file's own parent directory
    (`DesktopProjectRoot(p.dirname(pickedPath))`) only if the file turns
    out not to be Bundle-shaped — a Bundle never gets a `ProjectRoot`
    attached at all, staying exactly the single-file session it always
    was (no separate folder step either way, since plain `dart:io` access
    has no scoped permission to negotiate).
  - **Android/iOS** (`_openViaProjectFolderPicker`): keeps the two-step
    shape — grant/resolve the containing folder (`_ensureProjectRoot`),
    then pick the file inside it (§3.5's listFiles-backed picker) — a
    genuine platform constraint (a single-document SAF pick grants no
    tree-level write access to siblings), not leftover caution. Reads the
    picked file's own bytes through `StorageService` purely to sniff its
    shape (`_openComposedProject` re-reads it again as part of its own
    real graph walk — a small, accepted duplication for a small JSON
    file).
  - Either way, the decoded file is handed to the new
    `isBundleShapedNativeFile` (promoted to a free function in a new
    `client/lib/assembly/native_file_shape.dart`, specifically so it's
    directly unit-testable — see §5's own testing note) to choose between
    `_openBundlePayload` (`import_native` + `hidden_feature_ids`/
    `section_planes` restoration, exactly `_openNativeFile`'s old body)
    and `_openComposedProject` (`AssemblyDocumentClient.openAssembly`,
    exactly `_onOpenProjectPressed`'s old body) — both former methods
    removed, their logic folded into these two shared helpers so either
    platform half of `_onOpenPressed` can reach them.

`part_toolbar.dart`'s File-menu entries dropped from five to four —
`onOpenNative`/`onOpenProject` merged into one `onOpen` callback field.

### 3.4 Accurate dirty-state, replacing the unconditional exit warning

Unchanged from the first pass, still optional relative to §3.1-§3.3 but
cheap given `_runGuarded`'s existing 171-call-site chokepoint
(`part_screen.dart:20429`):

- Add a coarse `_isDirty` bool to `_PartScreenState`. Set `true`
  unconditionally at the top of `_runGuarded` — a false positive (flagged
  dirty by something that turned out to be read-only) is harmless, just an
  extra "unsaved" indicator, never a lost-work risk the other direction
  would be.
- Clear it at the end of a successful Save/Save As/Save All (§3.3).
- Surface it as a small indicator on the toolbar's Save entry.
- `_confirmExitPart` (`:9080`) skips its dialog entirely when `!_isDirty`
  — a real behavior improvement, not cosmetic.

Explicitly **not** proposed: periodic silent autosave — a materially
bigger, riskier change (silent overwrites, partial-failure handling across
N files mid-edit) than this overhaul calls for. Its own scoping pass, if
wanted, layered on top of an already-accurate dirty flag.

### 3.5 Project-files convenience (supports §3.3's Open, low priority)

**Implemented.** `showOpenProjectPathPromptDialog` now fetches
`StorageService.listFiles(root, extensionFilter: kNativeFileExtension)`
once, before the dialog opens, and shows every match as a sorted, tappable
row above the original free-text field (tapping a row resolves
immediately, no extra "Open" press needed) — the text field stays as a
fallback for anything not listed, or for typing a path from memory. A
`listFiles` failure (an unreachable root) falls back to the text field
alone with a short explanatory note rather than failing the whole dialog.
The one caller, `_onOpenProjectPressed`, now passes `storageService`/`root`
through to it. Caught one real bug while testing this: the original draft
sorted the list returned by `listFiles` in place, which throws against a
`const []`/otherwise-unmodifiable result — `StorageService`'s contract
never promised a mutable list back, so this now copies into a fresh list
first.

---

## 4. Data migration — much less of a concern than the first pass assumed

Because this is pre-release, there's no installed base of real user files
to protect, so this section is short:

- The wire format doesn't change at all (`native_format.py:165`'s
  `SCHEMA_VERSION` stays `1`; `Occurrence.external_ref`'s meaning,
  `models.py:3293`, is untouched). Any `.DIDSAprt` file produced during
  development so far — single-part or multi-part — keeps opening exactly
  as before via `AssemblyGraphComposer.compose`.
- The only behavior change touching a file created under today's system is
  §3.1's auto-derive-first logic applying the next time a still-unpathed
  Part in it gets created/saved — strictly fewer prompts, never a
  destructive rewrite.
- **No project manifest file (`project.json` or similar) is proposed.**
  Nothing in this overhaul needs one — the lazy-discovery graph compose
  already works, and a second source of truth about "what's in this
  project" would need its own versioning story for no concrete benefit
  identified here. If a future need appears (multi-root cross-references,
  workspace-level metadata), it should get its own scoping document built
  on top of, not replacing, the relative-path scheme already in place.

---

## 5. Suggested phased delivery order

Every phase below is client-only except Phase 2's two small, precedented
backend field additions (§3.2). Each phase is additive or a like-for-like
replacement at its own call sites, ships independently, and leaves the
app fully working before the next phase starts.

**Phase 1 — §3.1: zero-dialog Create Component, auto-name, auto-path both
Parts. Implemented.**
- `_onCreateNewComponentPressed` (`part_screen.dart`) generates a name
  locally via the new `_nextComponentName` (mirrors
  `occurrenceDisplayName`'s own "Component N" ordinal, checked against
  every name already in use) instead of prompting, and registers both the
  new child's and the parent's paths in `_relativePathByPartId` in the
  same step via the new `_autoAssignPath` helper.
- Removed: `_promptComponentName`.
- Unchanged: `mergeComponentIntoDocument` (`add_component.dart`),
  `_ensureProjectRoot`, `_onSaveAllPressed` — still the correct fallback
  for anything this phase doesn't cover (e.g. Add Component's own
  pre-existing external-ref gap).
- Tests: `client/test/part_screen_test.dart`'s "Create Component creates
  an auto-named, auto-pathed Part…" test rewritten for the zero-dialog
  flow, including a same-action Save All assertion proving neither Part
  needs a further prompt.

**Phase 2 — §3.2: rename action (assembly tree, long-press). Implemented.**
- Backend: `PartUpdate.name` added (`schemas.py`) and handled in
  `update_part` (`router.py`) — rejects an empty/whitespace-only name
  with a 422 rather than silently applying it, since `Part.name` has no
  "cleared" state the way the metadata fields do. `OccurrenceTransformUpdate`
  widened with `name_override` (same tri-state as the existing `color`
  field: omitted leaves it untouched, `""` clears it, anything else sets
  it), handled in `update_occurrence_transform`.
- Client: `ComponentContextMenuAction.rename` added, with its menu entry;
  new `_renameOccurrence`/`_promptRenameComponent` in `part_screen.dart`;
  `DocumentApiClient.updateOccurrenceName` (mirrors `updateOccurrenceColor`
  exactly) and `updatePart`'s new `name` parameter;
  `StorageService.renameFile` added to the interface and implemented on
  all three platforms — `saf_util.rename`/`delete` already existed in the
  Android plugin and needed no native changes; desktop uses
  `File.rename`; iOS needed a small, real addition (`IosStoragePlugin.swift`'s
  new `renameFile` case wrapping `FileManager.moveItem`, plus
  `IosBookmarkChannel.renameFile`) since no rename primitive existed
  there before. Same-directory-only by design (§3.2's own reasoning) —
  every real call site only ever changes a file's own name.
  `relative_path.dart` gained `siblingRelativePath` for computing the
  resulting relative path.
- The "only rename the file/Part name when instanced exactly once"
  check counts occurrences across the *whole session* (a fresh
  `exportNative()`), not just the focused Part's own children, since a
  shared Part could be instanced inside a different sub-assembly than the
  one currently focused.
- Tests: two new `part_screen_test.dart` widget tests (singly- vs.
  multiply-instanced rename), plus unit tests for `renameFile` added to
  `desktop_storage_service_test.dart`, `saf_storage_service_test.dart`
  (needed a `rename` implementation added to that file's own fake
  `SafUtil`), and `ios_storage_service_test.dart` (same, for its fake
  `IosBookmarkChannel`), and backend tests added to
  `test_occurrence_transform_update.py` for both the `name_override`
  tri-state and `update_part`'s new `name` field/validation.

**Phase 3 — §3.3: Save/Save As split on Project-vs-not. Implemented for
Save/Save As/Save All; Open deliberately not touched.**
- `_saveNativeFile` and `_saveAsNativeFile` now dispatch on `_projectRoot`:
  unchanged legacy whole-session behavior with no Project yet; the new
  `_saveFocusedPart`/`_saveFocusedPartAs` once one exists (§3.3's own
  description, including the Save-As correction — a fresh export, not a
  physical file move).
- `_onSaveAllPressed`/`Open…`/`Open Project…` left entirely unchanged.
  `part_toolbar.dart`'s doc comments updated to describe the new split;
  the menu's own five entries were **not** collapsed to four (see §3.3's
  opening note on the Open extras-restoration gap this surfaced).
- Tests: two new `part_screen_test.dart` widget tests — plain Save writes
  only the focused Part (a `writeCounts`-per-path instrumentation added to
  the test file's fake `StorageService` to prove this), and Save As saves
  fresh content under a new path and rebinds future Saves to it, leaving
  the old file in place.

**Phase 4 — §3.4: dirty-state tracking. Implemented.**
- `_isDirty` added to `_PartScreenState`, set unconditionally at the top
  of `_runGuarded`; cleared at the end of every successful save path
  (`_saveNativeFile`'s two branches, `_saveFocusedPart`,
  `_saveFocusedPartAs`, `_onSaveAllPressed` - only on a fully successful
  Save All, a partial failure leaves it `true`). `_saveNativeFileViaDialog`
  changed to return `bool` (saved vs. cancelled) so a cancelled Save/Save
  As dialog is never mistaken for success.
- One refinement beyond the original plan: `_loadPart` also clears
  `_isDirty` at the end of its own guarded body - loading isn't "the user
  changed something" (a freshly opened Part matches disk exactly, a
  freshly created blank one has nothing to lose), so without this every
  session would start dirty from the first frame purely from
  `_runGuarded`'s own coarse default, defeating the point for the common
  "opened it, didn't touch anything, exited" case.
- `_confirmExitPart` skips its dialog when `!_isDirty`; `_startNewPart`'s
  own separate "Start a new project?" dialog (never routed through
  `_confirmExitPart` - distinct title/button wording) got the same guard
  added directly rather than left inconsistent.
- `PartToolbar` gained `hasUnsavedChanges`, shown as a small dot next to
  the Save entry.
- Tests: `part_screen_test.dart`'s existing "Open Project… asks to
  confirm" test updated to actually dirty the session first (creating a
  component) since a fresh, untouched load no longer warns on its own;
  a new sibling test confirms the no-warning case directly; a new
  "unsaved-changes indicator" test confirms the toolbar's own dot
  appears/clears correctly. Full `flutter test` suite (2281 tests, 14
  pre-existing skips) passing.

**Phase 5 — §3.5: project-files convenience (listFiles-backed Open
picker). Implemented.**
- `showOpenProjectPathPromptDialog` (`relative_path_dialog.dart`) widened
  to take `storageService`/`root`, fetch `listFiles` once before opening,
  and render a tappable, sorted row per matching file above the original
  text field - falling back to the text field alone (with a short note) on
  a `listFiles` failure.
- `_onOpenProjectPressed`'s own call site updated to pass them through.
- Tests: new `relative_path_dialog_test.dart` (files listed and sorted,
  tapping a row resolves it, typing still works, empty-folder message,
  `listFiles`-failure fallback, Cancel) - a minimal `Builder`+`TextButton`
  harness calling the dialog function directly, the same pattern
  `component_context_menu_test.dart` already establishes for a standalone
  dialog/sheet function, rather than routing through the real `PartScreen`
  (whose own real-`dart:io` "Open Project… through the real screen" test
  was already dropped as too flaky for this harness - see the Phase 16
  test group's own doc comment).

**Phase 6 (new, added during implementation) — unify Open/Open Project.
Implemented.**
- Resolved the design question §3.3's first-pass note raised directly
  (§3.3 above has the full reasoning): rather than teaching the composer
  to carry `hidden_feature_ids`/`section_planes`, read the file first and
  let its own shape (`isBundleShapedNativeFile`, new
  `client/lib/assembly/native_file_shape.dart`) decide which reader it
  needs. The two shapes are mutually exclusive by construction (a
  Project's own per-Part export can't produce more than one Part in a
  file; a Bundle's export never resolves `external_ref`s into a graph),
  so this is a completeness guarantee, not a heuristic guess.
- `part_screen.dart`: removed `_openNativeFile` and `_onOpenProjectPressed`
  as standalone methods; their bodies became `_openBundlePayload`/
  `_openComposedProject`, both reachable from the new `_onOpenPressed`
  (dispatches on `_canPersistFilePathForReuse`) via
  `_openViaDesktopFilePicker`/`_openViaProjectFolderPicker`.
- `part_toolbar.dart`: `Open…`/`Open Project…` merged into one `Open…`
  entry backed by a single `onOpen` callback.
- A real testability gap surfaced here too: `_canPersistFilePathForReuse`
  wraps a genuine `dart:io Platform.isX` check, which (unlike Flutter's
  own `defaultTargetPlatform`) has no override seam - every widget test in
  this suite runs on a Linux host, so a platform-gated Open would
  otherwise always take the desktop `file_picker` branch and never
  reach the `StorageService`-driven Android/iOS one, silently untesting
  what the pre-existing "Open Project hardening" tests already covered
  before unification removed its own always-reachable menu entry. Fixed
  by adding `PartScreen.canPersistFilePathForReuse` (nullable, defaults to
  the real platform check), the same "inject a test override" convention
  `documentApi`/`storageService`/`assemblyDocumentClient` already
  establish - threaded through every `PartScreen(...)` re-construction so
  the override survives a `pushReplacement`.
- Tests: `native_file_shape_test.dart` (new, plain non-widget tests for
  `isBundleShapedNativeFile`); a new widget test confirming a Bundle opens
  directly with its `hidden_feature_ids`/`section_planes` restored and no
  `ProjectRoot` attached; the pre-existing "Open Project hardening" tests
  updated to force `canPersistFilePathForReuse: false` and tap the unified
  `Open…` entry. **Deliberately not tested through the real screen**: the
  Project-shaped (composed-graph) half of the dispatch - confirmed
  directly during this phase that even a trivial single-Part,
  zero-Occurrence file's `openAssembly` call never reliably settles inside
  this suite's own `testWidgets` pump loop, the exact "real dart:io/HTTP
  async chain + testWidgets' own fake-async pump loop" combination the
  Phase 16 test group's own doc comment already found too flaky to drive
  through the real screen (its own "Open Project… through the real
  screen" test was dropped for the same reason). That branch's own
  routing decision is what `native_file_shape_test.dart` covers directly;
  the graph composition itself already has real, non-flaky coverage in
  `assembly_graph_composer_test.dart`/`assembly_document_client_test.dart`.

No phase requires a `SCHEMA_VERSION` bump or a data migration script —
per §4, every file created under today's system keeps working before,
during, and after this plan lands. Verification for Phases 1-6: `flutter
analyze`/`dart analyze` clean across `client/lib` and `client/test`; the
full `flutter test` suite (2292 tests, 14 pre-existing skips) passing, not
just the individually-touched files; the full backend suite
(`backend/tests/`, 2488 tests) passing (Phase 6 made no backend changes).
