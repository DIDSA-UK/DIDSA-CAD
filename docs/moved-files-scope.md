# Finding moved files — scope

**Status:** approved by the owner on 20 Oct 2026 with every recommendation (section 6); being built on branch
`claude/appearance-and-scenes`, phase by phase (Progress below). Grows `docs/scenes-scope.md` D11 and the roadmap entry ("Finding
moved files") into a scope of its own.

## Progress

| Phase | Summary | Status | Where |
|---|---|---|---|
| F1 | Backend: `Occurrence.ref_part_id`, native round trip, API; the lookup rule + golden vectors | Done (not merged) | CAD `claude/appearance-and-scenes` |
| F2 | DIDSA-VR | Not started | VR |
| F3 | Flat app | Not started | CAD |

Update this table with every milestone.

## F1 implementation notes (backend)

- **The rule:** `backend/app/document/file_lookup.py` (`find_file`, `name_key`), pure Python. Its answer always has the same keys:
  `result` (`found` / `ask` / `suggest` / `missing`), `path`, `via` (`path` / `id`), `candidates` (sorted) and `path_mismatch`.
  Golden vectors: `tools/file_lookup_vectors/generate.py` -> `docs/file-lookup/vectors.json` (16 cases; the backend's copy is
  `backend/tests/data/file_lookup_vectors.json`, `--check` keeps the two in step). A file at the path whose id could not be read
  counts as a different file (a suggestion, never used silently). Name matches set the native extension and letter case aside, as the
  existing path lookup does.
- **`Occurrence.ref_part_id`** (wire key `ref_part_id`, in the native file, `OccurrenceResponse` and `OccurrenceCreate`): what is
  written is `placed_part_id`, the resolved target's id when there is one, else the stored value. So it follows the session while the
  reference resolves, and is kept, not dropped, while it doesn't (a root file opened on its own, a missing file). A file saved before
  the field existed seeds it from its stored `resolved_part_id` (the target's id at its last save). A reference with no id anywhere
  writes no key, so such a file saves exactly as before. A non-string value is a 422 on import. Add-component records the placed
  file's root Part id; Undo after a delete (`POST .../occurrences`) restores it.
- **For F3 (ids re-minted during compose):** the flat app re-mints a clashing file's ids, so the session id, and so the
  `ref_part_id` the parent saves, is the new one, while the file on disk keeps the old id until it is saved. F3 must save a re-minted
  file with its new ids, or write the on-disk id into the parent itself. Otherwise the next open reports a mismatch at the path: a
  suggestion, never a wrong file, but a needless question. DIDSA-VR does not re-mint.
- **No endpoint for re-pointing a reference:** both clients compose a payload before importing it, so a corrected path and id go
  in through the payload. F2 / F3 add a PATCH only if their review screens need one after the assembly is open.
- **Tests:** `backend/tests/test_file_lookup.py`.

## 1. Today

| What | Where | Gap |
|---|---|---|
| An assembly finds a placed file by `Occurrence.external_ref`, a path relative to the project folder | Backend model and native format (`models.py` `Occurrence`, `native_format._occurrence_to_dict`); resolving it is the client's job (the backend has no file system) | A file moved to another folder, or renamed outside the app, is not found. |
| Each file also writes `resolved_part_id` (the placed Part's id) | `native_format._occurrence_to_dict` | Trusted only when the target is in the same import payload; a single-file reload drops it, and the next save writes `null`. So it is not a dependable "which file is this" id. |
| Flat app: `AssemblyGraphComposer` | `client/lib/assembly/assembly_graph_composer.dart` | Exact path, then the same name under another native extension / case. A file that can't be read falls back to the **last cached copy** (`FileCache`, marked stale), so a moved file can show old content without saying where the real one went. |
| DIDSA-VR: `native_compose.gd` | DIDSA-VR `scripts/native_compose.gd` | Same lookup, across the file's own folder, the project folder and the models folders. Not found: left unresolved and listed ("N referenced files not loaded: ..."). |
| Rename inside the flat app | `docs/save-project-overhaul-scope.md` 3.2, `save_all.dart` `stampExternalRefs` | Fixes the references **in the session that is open**. Another assembly on disk that places the same file keeps the old path, which is the commonest way to get a broken reference today. |

Every native file already carries its Part's id, assigned once when the Part was created and kept on every save. Two files share an id
only when one was copied outside the app, or was saved by Save As before Save As started re-minting ids (`remint_identity.dart`).

## 2. The rule (shared by both clients)

When an assembly is composed, each reference is looked up in this order:

1. **The path** (as today: exact, then another native extension or letter case). If the file there has the stored id, or the reference
   has no stored id (an older file), use it. If the file there has a **different** id, the path now points at some other file: go on
   to step 2 and, whatever is found, report it.
2. **The id**, in an index of the project folder (and in DIDSA-VR also the models folders). **One file with that id:** use it, say so
   ("Frame A.didsa was found in parts/frames/"), and mark the assembly as changed so the next save writes the corrected path.
   **Several:** ask, listing the candidates with their folder and last-modified time. Nothing is loaded until the user picks one.
3. **The file name, anywhere in the index** (for an older reference with no stored id, or an id that is not found): never used
   automatically; offered as a suggestion ("A file called Frame A.didsa is in parts/old/. Use it?").
4. **Nothing found:** unresolved as today, listed, with **Locate...** to pick the file by hand. A picked file whose id differs from
   the stored one gets a warning ("This is not the file that was placed here. Use it anyway?"), never a silent swap.

**Never guess silently** (D11): a file that doesn't match by id is only ever used after the user says so. The flat app's
stale-cache fallback moves to after step 3. A cached copy is still shown when nothing is found, marked stale as today.

The rule is a pure function, `(reference, stored id, the file found at the path or none, index) -> found | ask(candidates) |
suggest(candidates) | missing`. It is written once as a Python reference with golden vectors (the appearance and scenes precedent) and
copied into Dart and GDScript, each tested against the same vectors. It runs on the client; the backend never sees the file system.

## 3. What is stored

- **Backend (F1):** a new optional `Occurrence.ref_part_id`: the placed file's own Part id, kept even when the target is not in the
  session (unlike `resolved_part_id`). Each save writes the target's id when the target is resolved and keeps the stored value when it
  is not, so a file saved while a reference was missing doesn't lose it. A file without the field loads as before. The field is
  written only when set (no `SCHEMA_VERSION` bump, the `component_patterns` precedent). Older files get it on their next save.
- **The index (F2, F3):** client-side only, a cache of `{relative path -> (root Part id, file name, last modified)}`. It is built
  when a reference misses (not on every open) and refreshed for any file whose last-modified time has changed. Reading a file's id
  means opening it, so a large project folder costs one scan the first time. The flat app already has `StorageService.listFiles`
  (recursive) and `FileCache`; DIDSA-VR walks the folders with `DirAccess`.
- **Ids made by re-minting:** when the flat app re-mints a clashing file's ids during compose, the session id is no longer the id on
  disk. The stored `ref_part_id` must be the **on-disk** id of the file that was found (the composer knows it), not the session id;
  F1 and F3 handle this together.

## 4. In the apps

- **Flat app (F3):** when an assembly opens with references that moved, a banner shows "2 files were found in new places, 1 needs
  you" with a **Review** sheet: each reference with what happened (found by id / pick one / suggestion / missing) and **Use**,
  **Locate...** or **Leave missing** for each one. The assembly tree's existing stale / missing badge opens the same sheet.
- **DIDSA-VR (F2):** the same list on a tablet page, reached from the load message that already lists files not loaded; picking a
  candidate is a laser click. **Locate...** opens the existing file browser.
- **Saving the corrected path:** the fix is an ordinary edit (unsaved until Save, can be undone), so nothing on disk changes behind
  the user's back.

## 5. Phases

| Phase | What | Repo |
|---|---|---|
| F1 | Backend: `Occurrence.ref_part_id` (model, native round trip, write rules, tests); the lookup rule in Python + golden vectors. | CAD |
| F2 | DIDSA-VR: index, the rule in GDScript (vectors), the compose change, the tablet page and Locate...; headless and live-backend tests. | VR |
| F3 | Flat app: index, the rule in Dart (vectors), the composer change (search before the stale cache), the banner / Review sheet and Locate...; tests. | CAD |

Each phase is one milestone, with the usual report and wait between them. F2 and F3 are independent of each other after F1.

## 6. Questions for the owner (settled 20 Oct 2026: **Owner** approved every recommendation)

1. **One match by id:** use it straight away and tell the user (**Recommendation**, D11's wording), or always ask first?
2. **Older references (no stored id):** name-only matches are suggestions only, never used without a click (**Recommendation**). Or
   should a single name match elsewhere in the project folder be used automatically, like an id match?
3. **Where to search:** the project folder, recursively (plus DIDSA-VR's models folders) (**Recommendation**). Or should there also be
   a list of extra search folders, like SolidWorks' search paths? (Not proposed for v1.)
4. **Also fix other assemblies on rename:** when a file is renamed in the flat app, should it also offer to update the other
   assemblies in the project folder that place it (open them, fix the path, save)? That would stop most broken references from
   happening in the first place, but it writes files the user doesn't have open. **Recommendation:** leave it out of v1. The id
   lookup already repairs those references the next time each assembly is opened.
