# Save / Project / Assembly overhaul — Scoping Document

Companion to a planning request covering: unifying the two parallel,
non-integrated persistence systems in `PartScreen`'s File menu (the legacy
single-file "session dump" — Save/Save As/Open, predates assemblies — and
the newer multi-file, folder-based system for assemblies — Save All/Open
Project, built on `ProjectRoot` + `Occurrence.external_ref` relative-path
links, no real manifest); collapsing the "name it" / "save it" dialog pair
that fires back-to-back when creating a new component inside an assembly;
and giving the parent assembly Part a save path at creation time instead of
prompting for it again at the next Save All. This is a **planning
document only** — no code changes were made producing it. It builds
directly on `docs/save-project-pipeline-findings.md` (a prior read-only
investigation of the current system, file paths/line numbers/call traces)
and does not re-derive anything that doc already covers; where a citation
below has moved from that doc's own line numbers, it's because unrelated
feature work (Shell body-first rework, Chamfer angle+flip, Extrude draft
option) landed on `part_screen.dart` between the two investigations and
shifted the file by roughly 1,100 lines — the citations here are current as
of this document's own writing.

Backend: `backend/app/document/models.py` (`Part`, `Occurrence`,
`Document`), `backend/app/document/native_format.py` (`export_native`/
`import_native`, `SCHEMA_VERSION`), `backend/app/document/router.py`
(`create_part`, `export_native_document`, `import_native_document`).
**This document proposes zero backend changes** — see §1.3 for why the
whole problem here is client-side state/UX, not a data-model gap.
Client: `client/lib/viewport3d/part_screen.dart` (the ~23k-line
`_PartScreenState` God object every save action still lives on),
`client/lib/viewport3d/part_toolbar.dart` (File menu), `client/lib/
viewport3d/relative_path_dialog.dart`, `client/lib/assembly/
assembly_document_client.dart`, `client/lib/assembly/save_all.dart`,
`client/lib/assembly/add_component.dart`, `client/lib/assembly/
assembly_graph_composer.dart`, `client/lib/storage/*` (`project_root.dart`,
`storage_service.dart`, `recent_project_store.dart`,
`saf_storage_service.dart`).

**Status: not started.** Nothing in this document is implemented. §5 lays
out a suggested phased delivery order; each phase is independently
shippable and leaves the app fully working (see §5's own "why this doesn't
break anything mid-phase" note on every phase).

---

## 1. Grounding: what §1–§5 of the findings doc established, restated only where a decision below depends on it

- **Two systems share one File menu, confirmed-deliberate "add, don't
  replace."** `part_toolbar.dart:83-93`'s own doc comment states it
  outright: the multi-file Save All/Open Project machinery is "fully
  additive alongside the Save/Save As/Open entries above (which stay
  exactly as they are — a single-file, `file_picker`-driven, whole-session
  dump)." Menu wiring: `part_toolbar.dart:309-330` (`Open…` 309-310, `Open
  Project…` 314-315, `Save` 319-320, `Save As…` 324-325, `Save All`
  329-330).
- **Legacy Save/Save As/Open** (`part_screen.dart:9239` `_saveNativeFile`,
  `:9260` `_saveAsNativeFile`, `:9212` `_saveNativeFileViaDialog`, `:9164`
  `_buildNativeExportBytes`) round-trip the *entire current backend
  session* — every loaded Part's Features/Sketches — as one flat
  `document.parts: [...]` JSON blob via `DocumentApiClient.exportNative()`
  with no `partId`. `_canPersistFilePathForReuse` (`:9156`) gates
  reuse-last-path to desktop only; Android/iOS always re-prompt (a
  separate, already-diagnosed `file_picker`-returns-a-fake-path bug, not
  something this document touches).
- **Save All / Open Project** (`_onSaveAllPressed` `:11203`,
  `_onOpenProjectPressed` `:11270`, `_ensureProjectRoot` `:11090`) resolve
  a `ProjectRoot` folder (`client/lib/storage/project_root.dart` — a plain
  directory on desktop, a persisted SAF tree URI on Android, a
  security-scoped bookmark on iOS; no manifest file, no part list — just a
  folder handle), then export each Part *individually*
  (`exportNative(partId: ...)`), stamp every `Occurrence.external_ref` to
  the now-known relative path of the Part it resolves to
  (`stampExternalRefs`, `save_all.dart:22`), and write one `.DIDSAprt` file
  per Part (`AssemblyDocumentClient.savePart`,
  `assembly_document_client.dart:79`).
- **The wire format is identical between the two systems.** Both go
  through the same `export_native`/`import_native`
  (`backend/app/document/native_format.py:1993`/`:2042`) with the same
  `SCHEMA_VERSION = 1` (`native_format.py:165`). The only structural
  difference is *how many Parts one file's `document.parts` holds* and
  *whether `Occurrence.external_ref` is a resolvable relative path or
  stale/null*. This is the load-bearing fact behind §2's decision not to
  deprecate the legacy format, and behind §4's conclusion that no
  migration tooling is actually needed.
- **The redundant-prompt chain, traced** (`_onCreateNewComponentPressed`
  `:11117`): `_promptComponentName()` (`:11170`, a backend Part name) is
  immediately followed by `showRelativePathPromptDialog` (`:11154-11162`,
  a filesystem path) pre-filled with the same string — two free-text
  dialogs for what reads as one action. Only the *new* Part's id is ever
  written into `_relativePathByPartId` (`:11163`); the *parent* Part (the
  one the new Occurrence was merged onto) is never assigned a path here,
  so it's guaranteed to be one of the Parts `_onSaveAllPressed`'s
  per-missing-Part loop (`:11217-11232`) prompts for at the next Save All
  — a second, later dialog for what the user experiences as the same
  create-a-component action.
- **No dirty-state tracking exists at all.** `_confirmExitPart`
  (`part_screen.dart:9080`) shows an unconditional "unsaved work would be
  lost" warning on every exit path, regardless of whether anything
  actually changed since the last save. `_runGuarded`
  (`part_screen.dart:20429`) is already the de facto choke point for
  essentially every backend-mutating action in this file (171 call
  sites) — relevant to §3.3's proposal.
- SAF/Android permission handling is confirmed **not** the cause of any of
  the above (findings §4) — it's the confirmed cause of a separate,
  distinct bug (legacy plain Save re-prompting every time on Android/iOS).
  Not revisited here except where it constrains §3.2's Open redesign
  (Android/iOS genuinely need a folder-level grant before a later Save can
  write sibling files; a single-document SAF pick doesn't provide one).

---

## 2. The mental model: Project, Part, Assembly, and (kept, renamed) Bundle

**Decision: keep the legacy single-file format, but as an explicit,
clearly-labeled "Bundle" distinct from a Project — do not deprecate it and
do not force every save through a folder.**

Why, concretely:

1. **It's the same file format already**, per §1's schema point — a
   Bundle is not a second data model to maintain going forward, it's the
   *same* `export_native` JSON with N≥1 Parts and unresolved
   `external_ref`s, vs. a Project's N files each with exactly 1 Part and
   resolved `external_ref`s. Keeping both costs almost nothing extra
   because they were never actually two formats, just two ways of slicing
   the same one.
2. **Real files already exist in this shape** and must keep opening
   regardless of any decision made here (see §4) — so the reader/writer
   code for it isn't going away even in a "deprecate the UI entry" world.
3. **It serves a real, distinct use case** a folder-first model makes
   worse: a user modelling one simple standalone Part (the common case for
   a first-time or casual user) shouldn't be forced to pick a project
   folder before their first save. A Bundle is also the right shape for
   "email this to a colleague as one attachment" or "grab a portable
   snapshot" — genuinely different from "these are independently reusable
   parts I want to reference from other assemblies later," which is what a
   Project is *for*.

So, four terms, precisely:

- **Part** — the atomic modelling document: a name, an ordered Feature
  list, and the Sketches it references. Unchanged from today
  (`backend/app/document/models.py:2980`). Once saved into a Project it's
  backed 1:1 by exactly one `.DIDSAprt` file; inside a Bundle it's one
  entry in that Bundle's `document.parts` list.
- **Assembly** — not a distinct file type or backend entity, and no
  terminology or data-model change is proposed here: it's simply *a Part
  that contains one or more `Occurrence`s of other Parts*
  (`models.py:3228`), exactly as today. "Assembly lens" stays a *view
  mode* over such a Part. The only change this document asks for is
  consistency in user-facing copy — never describing "Save All" or
  "Project" as a feature bolted onto assemblies specifically, since any
  Part can (and, per below, by default does) live in a Project the moment
  it's saved there.
- **Project** — the *save destination*: a `ProjectRoot` folder
  (`client/lib/storage/project_root.dart`, unchanged) holding every Part
  file ever saved into it, cross-linked by relative-path `external_ref`s,
  discovered lazily by `AssemblyGraphComposer.compose` exactly as today.
  **No manifest file is proposed** (see §4's closing note for why a
  `project.json` is explicitly out of scope) — the lazy-discovery model
  already works and introducing a second source of truth about "what's in
  this project" would need its own versioning/migration story for no
  clear win yet.
- **Bundle** — a single, self-contained `.DIDSAprt` file holding a whole
  in-memory session (possibly many Parts + Occurrences), with no folder,
  no independently-reusable per-part files, and no live cross-file links
  (`Occurrence` resolution inside a Bundle works only via
  `resolved_part_id` against Parts embedded in that same file, never via a
  resolvable `external_ref`). This is what "Save"/"Save As"/"Open" mean
  going forward — renamed in the UI (see §3.2) to make the distinction
  from a Project legible, but functionally identical to today's legacy
  single-file flow.

**Which mode is a session in?** Exactly the state already tracked today:
a session is in **Project mode** once it has a `ProjectRoot`
(`_projectRoot`/`_ensureProjectRoot()`, `part_screen.dart:11090`) —
established today only by Create Component / Add Component / Open
Project, and, going forward, additionally by an explicit "Save as
Project…" action (§3.2). Otherwise it's in **Bundle mode**, the default
for a brand-new session — no behavior change from today's default, just a
name for it. A session never silently loses Project mode once it has a
root; there's no "downgrade."

---

## 3. Workstreams

### 3.1 One dialog for "Create Component…", and the parent gets a path for free

Replaces `_onCreateNewComponentPressed`'s (`part_screen.dart:11117`)
current two-dialog sequence (`_promptComponentName` `:11170`, then
`showRelativePathPromptDialog` `:11154-11162`) with:

1. **One dialog**, e.g. `showCreateComponentDialog` in a new
   `client/lib/viewport3d/create_component_dialog.dart` (mirroring
   `relative_path_dialog.dart`'s `AlertDialog` + `StatefulBuilder` +
   `TextFormField` + disabled-until-valid `FilledButton` shape — the
   established convention for exactly this kind of modal in this
   codebase). Primary field: **Name** (defaults "New Component", as
   today). A collapsed, optional "Change file name" affordance reveals a
   second field pre-filled with `withDefaultExtension(name)`
   (`client/lib/assembly/relative_path.dart`, already used by
   `relative_path_dialog.dart:96`) and re-syncs to the Name field on every
   keystroke *until the user directly edits it* — the standard
   title-drives-slug-until-touched pattern. Nothing about "where this file
   lives" is asked here; that's still `_ensureProjectRoot()`'s job,
   unchanged, invoked with no new dialog if a root is already known.
2. On confirm: create the backend Part
   (`DocumentApiClient.createPart(name)`, unchanged), merge the Occurrence
   (`mergeComponentIntoDocument`, `add_component.dart`, unchanged), resolve
   the `ProjectRoot` (`_ensureProjectRoot()`, unchanged), then **register
   two paths in `_relativePathByPartId` in the same step**:
   - the new child Part's path, from step 1's (possibly auto-derived)
     filename;
   - **the parent/root Part's path, if `_relativePathByPartId[rootPartId]`
     is still absent** — auto-derived the same way, as
     `withDefaultExtension(parentPart.name)`. This is the direct fix for
     the gap in §1: today `_onCreateNewComponentPressed` only ever writes
     `newPartId`'s path (`:11163`), never `rootPartId`'s, guaranteeing a
     later Save-time prompt for the parent. Both derivations run through
     the same collision check `relative_path_dialog.dart:36-40` already
     performs (`storageService.resolve`) before being accepted silently —
     a collision on either one surfaces as an inline warning inside the
     *same* dialog (reusing the existing `collisionWarning` treatment,
     `relative_path_dialog.dart:78-85`) rather than a second popup, with a
     numbered-suffix default (`Bracket (2).DIDSAprt`) the user can still
     edit.
3. No further prompt fires for either Part at the next Save (§3.2) unless
   the user deliberately renames a file later (a "Project Files" browsing
   affordance, §3.4, not the creation flow).

Net: 2 mandatory dialogs → 1, and the ≥1 guaranteed follow-up prompt at
the next Save All for the parent Part → 0 in the common case. `Add
Component`'s own separate, already-documented gap (a picked existing
file's `externalRef` is its bare display name, not a real relative path —
`add_component.dart`'s own doc comment calls this out) is unaffected by
this workstream; it's still corrected the same way it is today, by
`stampExternalRefs` at the next Save.

### 3.2 One "Save" that means "save my work" — collapsing the File menu

New File menu, replacing the five entries at `part_toolbar.dart:309-330`
with four:

- **Save** (the one unambiguous "save my work" action). Internally
  dispatches on session mode (§2), never asks which kind of save the user
  meant:
  - **Project mode**: today's `_onSaveAllPressed` (`:11203`) logic, minus
    the prompts §3.1 now avoids for anything auto-assigned — in the
    steady state (no genuinely-new, never-configured Part), Save now
    round-trips with **zero dialogs**. Still prompts, sequentially, only
    for a Part that truly has no path and wasn't auto-derivable (e.g. one
    added via "Add Component"/"Locate missing file", where an
    externally-picked file's own name isn't a safe default to silently
    reuse) — auto-derive-first, prompt-only-on-genuine-ambiguity is the
    rule throughout, not just at creation time.
  - **Bundle mode**: today's `_saveNativeFile` (`:9239`) logic, unchanged
    — reuse `_lastSavedFilePath` on desktop, prompt once on first save or
    wherever the path can't be trusted for silent reuse
    (`_canPersistFilePathForReuse`, `:9156`).
- **Save a Copy…** — today's `_saveAsNativeFile` (`:9260`), the explicit,
  deliberate whole-session Bundle export. Available in *either* mode (a
  Project-mode session can still export a portable single-file snapshot).
  **Deliberate behavior change from today's Save As**: does *not* rebind
  the session's own save destination — a later plain "Save" still targets
  the original Project/Bundle, never the copy just written. (Today's
  `_saveAsNativeFile` → `_saveNativeFileViaDialog` does set
  `_lastSavedFilePath` on desktop, `:9223`, silently repointing future
  plain Saves at the "As" target — surprising once "Save a Copy" is named
  as a copy.)
- **Save as Project…** — new. The explicit "give my Bundle-mode session a
  real Project folder" action, for a user who wants to start reusing Parts
  across files without first adding a component. Internally: resolve a
  `ProjectRoot` (`_ensureProjectRoot()`), then run the *unchanged*
  `stampExternalRefs` (`save_all.dart:22`) + per-Part
  `AssemblyDocumentClient.savePart` loop (`assembly_document_client.dart`)
  against the current session's already-multi-Part `document.parts` (a
  Bundle of an assembly already has every Part embedded — see §4, this
  doubles as the migration path item 4 asks about, with no new code
  beyond exposing this entry point).
- **Open** — one entry, replacing `Open…`/`Open Project…`. Opens either a
  Bundle file or a Project's root Part file through the same reader path:
  `AssemblyGraphComposer.compose` already handles a file with zero
  `external_ref`s fine (a Bundle composes as a trivial single-node graph),
  so there's no behavioral fork needed once a `ProjectRoot` is known —
  only *how that root is obtained* differs by platform, and this is
  deliberately **not** collapsed to one identical flow everywhere:
  - **Desktop**: a single native "Open File" dialog (`file_picker`,
    unchanged from today's plain Open), with `ProjectRoot` silently set to
    `DesktopProjectRoot(dirname(pickedPath))` — no separate folder step,
    since plain `dart:io` file access has no scoped-permission concept to
    negotiate.
  - **Android/iOS**: keeps today's two-step shape (grant/resolve the
    containing folder via SAF/bookmark, *then* pick the file inside it) —
    this is a genuine platform constraint, not leftover caution: a
    single-document SAF pick returns no tree-level write grant to
    siblings, so a later Save couldn't write the project's other files
    without a separate grant regardless. What *does* improve on mobile is
    step two (see §3.4) — replacing free-text relative-path entry with a
    real file list.

`_confirmExitPart`'s (`:9080`) unconditional warning is addressed in
§3.3, not here.

### 3.3 Accurate dirty-state, replacing the unconditional exit warning

Optional relative to §3.1/§3.2 but cheap given `_runGuarded`'s existing
171-call-site chokepoint (`part_screen.dart:20429`):

- Add a coarse `_isDirty` bool to `_PartScreenState`. Set `true`
  unconditionally at the top of `_runGuarded` — deliberately coarse
  (assumes any guarded action might mutate state); a false positive
  (dirty flag set by something that turned out to be read-only) is
  harmless, just an extra "unsaved" indicator, never a lost-work risk the
  other direction would be.
- Clear it at the end of a successful Save / Save a Copy / Save as
  Project (§3.2's three write paths).
- Surface it as a small indicator on the toolbar's Save entry (a dot/label
  change, no new screen).
- `_confirmExitPart` (`:9080`) skips its dialog entirely when `!_isDirty`
  — a real behavior improvement (today's warning fires even with nothing
  to lose), not just cosmetic.

Explicitly **not** proposed: periodic silent autosave. Autosaving a
Project's own multiple files without an explicit user action is a
materially bigger, riskier change (silent overwrites, partial-failure/
conflict handling across N files mid-edit) than this overhaul's actual
problem calls for. If wanted later, it should be its own scoping pass on
top of an already-accurate dirty flag, not bundled here.

### 3.4 Project-files convenience (supports §3.2's Open, low priority)

A small list-based picker, backed by `StorageService.listFiles(root,
extensionFilter: 'DIDSAprt')` (`client/lib/storage/storage_service.dart:91`
— already implemented, currently unused by any call site per a repo-wide
grep), replacing the free-text "type the relative path" field in
`showOpenProjectPathPromptDialog` (`relative_path_dialog.dart:104-140`)
with a tappable list of files actually under the resolved root, falling
back to free text for anything not listed (a nested subfolder, e.g.). Pure
UX polish; nothing else in this document depends on it, and it can land in
any order relative to §3.1–§3.3, or be dropped without affecting the rest
of the plan.

---

## 4. Data migration

**Existing legacy single-file `.DIDSAprt` dumps**: zero format change.
Under the new naming these files simply *are* Bundles — `Open` (§3.2)
reads them exactly as today's plain Open does, since a Bundle is that same
format, only relabeled. No conversion, no on-disk rewrite, no
schema-version bump. A user who wants one promoted into a real Project
uses the new "Save as Project…" action (§3.2) — purely additive (writes
new per-part files under a chosen/created folder), never modifies or
deletes the original Bundle file.

**Existing multi-file projects (current `external_ref`/`ProjectRoot`
scheme)**: also zero format change — no new manifest, no
`SCHEMA_VERSION` bump (`native_format.py:165` stays `1`), no change to
what `Occurrence.external_ref` means (`models.py:3293`, or on the client).
Every file a user already has on disk under a project folder keeps opening
exactly as before via the unchanged `AssemblyGraphComposer.compose`. The
only behavior change touching existing projects is §3.1's
auto-derive-first logic applying retroactively the next time a
still-unpathed Part in an existing project gets created/saved — strictly
fewer prompts, never a destructive rewrite of anything already on disk.

**Explicitly out of scope**: a real project manifest file (`project.json`
or similar) recording an authoritative part list/metadata. Nothing in
this overhaul needs one — the lazy-discovery graph compose already works,
and introducing a second source of truth about "what's in this project"
would need its own versioning/migration story layered on top of
everything above, for no concrete benefit this planning pass identified.
If a future need appears (multi-root cross-references, workspace-level
metadata, dependency graphs spanning projects), it should get its own
scoping document built *on top of*, not replacing, the relative-path
scheme already in place.

---

## 5. Suggested phased delivery order

All four phases are client-only — **no backend change is proposed
anywhere in this document**; every gap identified is client-side
state/UX, not a data-model gap (§1's schema-identity point is why). Each
phase below is additive or a like-for-like replacement at its own call
sites, ships independently, and leaves the app fully working before the
next phase starts.

**Phase 1 — §3.1: merge the Create Component dialogs, auto-assign the
parent's path.**
- New: `client/lib/viewport3d/create_component_dialog.dart`
  (`showCreateComponentDialog`).
- Modify: `_onCreateNewComponentPressed` (`part_screen.dart:11117`) to
  call the new dialog and register both paths.
- Remove: `_promptComponentName` (`:11170`) — folded into the new dialog.
- Unchanged: `mergeComponentIntoDocument` (`add_component.dart`),
  `_ensureProjectRoot` (`:11090`), `AssemblyDocumentClient`/`save_all.dart`
  in full, `_onSaveAllPressed` (`:11203`) — still the correct fallback for
  anything Phase 1 doesn't cover (e.g. Add Component's own pre-existing
  gap). Lowest risk in this plan: one call site's dialog sequence changes,
  nothing else in the File menu is touched, so the app's save behavior
  everywhere else is provably untouched.

**Phase 2 — §3.2: collapse the File menu to Save / Save a Copy… / Save as
Project… / Open.**
- Modify `part_toolbar.dart`: replace the five entries at `:309-330` with
  four; merge the corresponding callback fields (`:77-95`) — `onSaveNative`/
  `onSaveAll` → one `onSave`; `onOpenNative`/`onOpenProject` → one `onOpen`;
  `onSaveAsNative` → `onSaveACopy`; add `onSaveAsProject`.
- Modify `part_screen.dart`: add a dispatcher (`_onSavePressed`) that
  branches on `_projectRoot`/mode and calls either `_saveNativeFile`
  (`:9239`) or the (renamed) Project-save logic currently in
  `_onSaveAllPressed` (`:11203`); a matching `_onOpenPressed` dispatcher
  per §3.2's platform split, replacing `_onOpenProjectPressed`'s
  (`:11270`) standalone entry point; `_saveAsNativeFile` (`:9260`) becomes
  `_onSaveACopyPressed` with the `_lastSavedFilePath`-rebind behavior
  change called out in §3.2 removed; new `_onSaveAsProjectPressed`
  wrapping the unchanged `saveAll`/`stampExternalRefs` pair.
- Medium risk — the most heavily-used entries in the app change name and
  dispatch logic; needs the existing widget-test coverage for the File
  menu (see `docs/flutter-widget-test-lessons.md` for this repo's testing
  conventions) extended to the merged callbacks before landing. Ship after
  Phase 1 so Create Component's cleaner flow is already exercised when
  verifying Save's steady-state prompt count end-to-end.

**Phase 3 — §3.3: dirty-state tracking.**
- Add `_isDirty` to `_PartScreenState`; set in `_runGuarded`
  (`:20429`); clear at the end of each Phase 2 save dispatcher.
- Modify `_confirmExitPart` (`:9080`) to gate on it.
- Purely additive; can ship independently of, or even before, Phase 2 —
  its only soft dependency is that "clear on successful save" reads most
  naturally against Phase 2's unified save entry points.

**Phase 4 — §3.4: project-files convenience (Open Recent / listFiles-backed
picker).**
- New small panel using `StorageService.listFiles` (`storage_service.dart:91`).
- Modify `showOpenProjectPathPromptDialog`
  (`relative_path_dialog.dart:104-140`) to offer the list with free-text
  fallback.
- Lowest priority of the four; pure polish, no other phase depends on it,
  safe to drop entirely without affecting Phases 1–3.

No phase requires a `SCHEMA_VERSION` bump, a backend endpoint change, or a
one-time data migration script — per §4, every file a user already has
keeps working before, during, and after this plan lands.
