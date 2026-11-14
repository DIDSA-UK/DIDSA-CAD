# Shared storage: scope (S0)

Phase S0 of `docs/mates-storage-sessions-plan-2026-11-12.md` (Part 2). Written 2026-11-13 from reading both repos on `main`
(CAD `3469f1c`, VR `089a0c9`). **Built since:** the store (S1, `project-store/`) and the flat app's side (S2, `client/lib/storage/server/`; its results and
where it differs from section 7 are in "S2 results" of the plan). The DIDSA-VR side (S3) is built (DIDSA-VR PR #85, merged; "S3 results" in the plan; **section 7's VR paragraph below is the design as scoped and differs from what was built**: the mirror is a visible folder in Documents, not `user://`). The Quest spike is in DIDSA-VR (Launcher > Servers > **Check storage**).
The owner's decisions are in section 8: **all eight recommendations accepted on 2026-11-13**, so S1 builds them as written.

## 1. What this does, in one paragraph

A small **project store** runs beside the CAD backend (its own container, like `browser-relay/`). It keeps projects as a plain folder
tree on the server, gives every file a version, and refuses a save made from an out-of-date copy. Both apps get a **server projects**
source next to their local project folder: the flat app through its existing `StorageService` interface, DIDSA-VR through a local copy
(a mirror folder in its own storage) so its path-based file code stays as it is. Offline, both work from their local copy and queue
saves; on reconnect each queued save is checked against the server's version, and a clash is the user's choice (Keep mine, Take
theirs, Save mine as a copy). No locks: the long-term vision rules out PDM-style locking.

## 2. Decisions this supersedes (`docs/assembly-scope.md`)

- **#4 (storage is a user-chosen local folder; network storage is whatever the OS exposes):** superseded **in part**. A local folder
  stays exactly as it is and stays the default. A server project is a second kind of project root, served by the store over HTTPS, not
  something the OS exposes. Still no built-in SMB / WebDAV client.
- **#6 (the backend stays stateless, has no file system):** **kept for the backend.** The CAD backend still never reads or writes a
  file and still takes a composed payload per request. The files live in the store, a different service. This is the main reason for
  the separate container (section 4).
- **Composition stays on the client.** The roadmap's placeholder ("shared network storage + server-side assembly composition") paired
  the two; this scope separates them. Both apps already compose a multi-file assembly from what their storage layer returns (the flat
  app's `AssemblyGraphComposer`, VR's `native_compose.gd`), and VR can add a component through `POST .../add-component`. A server project
  is just another place those files come from. Server-side composition is not needed for S1 to S4 and is not in this scope.
- **#5 (always the latest, fall back to a cached copy marked stale):** kept, and the store makes it work across devices: "the latest"
  is the store's current version, and the cache is the local copy.

## 3. What is there today (found while writing this)

| | Flat app (`client/`) | DIDSA-VR |
|---|---|---|
| Where files are | A user-chosen project folder: a path on desktop, an SAF tree on Android, a bookmark on iOS (`lib/storage/*`, sealed `ProjectRoot` / `FileHandle`) | `Documents/DIDSA` by default, or any folder with *All files access* (`scripts/project_folder.gd`; owner decision 4 Nov: B + C, no SAF plugin) |
| Storage layer | `StorageService`: resolve, read, write, list (recursive), rename, exists, last modified. Every caller works in project-relative paths. | None: `main.gd`, `native_compose.gd`, `file_lookup.gd`, `file_index.gd`, `project_save.gd` call `FileAccess` / `DirAccess` on paths directly |
| Cache | `FileCache` (last bytes seen per root + path; the stale fallback of #5) | None |
| A save over a file that changed meanwhile | **Not checked**: Save All writes every file (`assembly/save_all.dart`) | Checked by modified time: a file that changed on disk since it was read is not overwritten unless the user says so (`project_save.gd`, V-9) |
| Moved files | The moved-files rule: path, then the Part id in an index of the folder (`docs/moved-files-scope.md`), built client-side by reading files | The same rule (`file_lookup.gd`, `file_index.gd`) |
| Pairing | The QR code `didsa-vr:1?n=&u=&k=` plus optional `r` / `rk` (browser relay); `s` is reserved for the document session (`docs/vr-headset-pairing.md`) | `scripts/landing/pairing_payload.gd`: **unknown keys are ignored**, so new keys can be added without breaking an older headset |
| Auth | One static `X-API-Key` for the backend (`backend/app/auth.py`), another for the relay | the same keys, from the pairing code or typed |

Two consequences for this scope: (1) **the plan's pairing keys `s` / `sk` cannot be used**: `s` is reserved for the document session, and DIDSA-VR already reads it as that.
The store gets `p` (its address) and `pk` (its key). (2) **VR has no storage layer**, and putting one under every file call was the reason
the SAF option (D) was turned down on 4 Nov; the mirror folder (section 7) avoids it.

## 4. The store: its own container (decision S0-1)

**Recommended: its own small service, `project-store/` in the CAD repo, its own container in `docker-compose.example.yml`, its own key.**

- The backend keeps decision #6 (no files) and stays something you can restart or scale without losing anything.
- A long upload or a version-history clean-up never competes with OCCT for the Pi's 4 GB, and a crash in one never takes the other down
  (the relay's reasoning, `browser-relay/README.md`).
- Its image is small (Python + FastAPI, no OCCT): rebuilding it does not rebuild the backend.
- Its key can be given to a device that should read and write projects without being given the backend's, and the other way round.

The other option, a router inside the backend, is simpler to deploy (one container, one key) but gives the backend a file system and state,
and every backend deploy restarts the store. It would be the right call only if a second container is a real burden on the owner's set-up;
nothing found says it is (the relay already runs as a second one).

**How it is built:** Python 3.11, FastAPI, one worker process (so writes are serialised by a lock in the process, with no file-locking
across processes to get wrong), stdlib `sqlite3` for the metadata, the same `X-API-Key` pattern as `backend/app/auth.py` with its own
`PROJECT_STORE_API_KEY`, and `PROJECT_STORE_ROOT` (a mounted volume) for the data.

**On disk** (`PROJECT_STORE_ROOT`):

```
<root>/
  Gearbox/                     a project = a top-level folder
    Gearbox.didsa              the CURRENT version of each file, at its real path, as plain files
    parts/Shaft.didsa
  .didsa-store/                the store's own data (hidden; never served as a project)
    store.sqlite               versions, the change feed, the part-id index, devices
    blobs/ab/cdef...           every kept version's bytes, by content hash (SHA-256)
```

The current files are plain files in a plain tree on purpose: the server's folder can be a synced Drive / OneDrive folder or a NAS mount,
and a file can be copied in or out by hand. A file changed **outside the store** (by a sync client, by hand) is noticed by a scan (its
size or modified time differs from the last version recorded; the content hash decides) and recorded as a new version by "outside", so the
next save from an app made before that change is refused like any other stale save. Kept versions are stored by content hash, so a save
that changes nothing costs nothing and history is cheap: this also keeps the long-term door open to the git-like history the vision doc
prefers (`didsa-longterm-vision-and-model.md`, "branch/merge, not locking").

## 5. The API (S1)

All under the store's base URL, every request with `X-API-Key`. A device names itself with `X-Device-Name` (free text, e.g. "Quest 3",
"Desktop"): with one shared key the store cannot know who a person is, so "modified by" is the **device** that said so, shown as such and
never trusted for anything else.

| Method and path | What it does |
|---|---|
| `GET /health` | `{status, api_features, version}`. **Needs the key**, like the backend's (`backend/app/main.py` says why: the tunnel makes it internet-reachable, and an open endpoint lets any scanner confirm the server is up) |
| `GET /projects` | the projects: name, file count, total size, last change, last device |
| `POST /projects` `{name}` | a new, empty project (409 if the name is taken) |
| `GET /projects/{p}/tree` | every file: `path, size, sha256, version, modified_at, modified_by, part_id` (the file's root Part id when it is a native file, else null) |
| `GET /projects/{p}/files/{path}` | the current bytes; `ETag: "<version>"` |
| `PUT /projects/{p}/files/{path}` | write one file. `If-Match: "<version>"` (overwrite that version only) or `If-None-Match: *` (create only). **Neither header: 428** (a client must always say which version it is replacing). A stale `If-Match`: **412** with the current version's details. 200 / 201 with the new version. |
| `DELETE /projects/{p}/files/{path}` | `If-Match` required; 412 when stale. The file's history is kept. |
| `POST /projects/{p}/commit` | **several changes, all or nothing** (section 6): `{message?, changes: [{op: put \| delete \| move, path, to?, base_version \| null, upload_id?}]}`. 200 with every new version, or **409** with the list of paths whose `base_version` is no longer current, and nothing written |
| `POST /projects/{p}/uploads` | the bytes of one file for a commit (raw body); returns an `upload_id` valid for an hour |
| `POST .../uploads/sessions`, `PUT .../uploads/{id}?offset=`, `GET .../uploads/{id}`, `POST .../uploads/{id}/complete`, `DELETE .../uploads/{id}` | **S4**: chunked upload for a file past a tunnel's request limit (in-order chunks, resume from `received`, the declared SHA-256 checked at the end); the id then goes into a commit like any upload's. `project-store/README.md` is the reference |
| `GET /projects/{p}/files/{path}/versions` | the kept versions: version, size, sha256, when, which device |
| `GET /projects/{p}/files/{path}/versions/{v}` | the bytes of a kept version |
| `GET /projects/{p}/changes?since=<cursor>` | what changed since a cursor (path, op, version, device), and the next cursor: a device that was offline asks this first |
| `GET /projects/{p}/parts/{part_id}` | the paths whose root Part id is this one: the moved-files rule's index, served instead of built by reading every file |

**Versions:** a number per file that only goes up (1, 2, 3...), not a timestamp (clocks differ between devices). The content hash is
alongside it, so a client can tell "my copy is already the current one" without downloading it.

**Why 412 for a stale single-file write, not the plan's 409:** it is HTTP's own answer to a failed `If-Match` precondition, which is
exactly what this is, and plain HTTP tooling understands it. 409 is kept for a commit, where several files may clash at once and the body
lists them. Both mean "nothing was written, here is what is current".

**Kept versions:** the last 20 of each file and every version younger than 30 days, whichever keeps more (decision S0-4). A file deleted
from a project keeps its versions for 30 days.

**Limits:** files up to 200 MB. A Cloudflare tunnel (the owner's set-up) refuses request bodies over 100 MB on its free plan (Cloudflare's
documented limit; not measured here), so a larger STEP file needs chunked upload; that was S4 (built: both clients send a file over about 90 MB in 32 MB chunks). The store refuses `..`, absolute
paths, a path into `.didsa-store/`, and names Windows cannot store. S1 also refuses a path whose last part is `versions`, or
`versions/<digits>`: `GET .../files/a/versions` and `.../versions/3` are the history routes, so such a file could never be read back
(found while building S1). `GET .../parts/{part_id}` answers 200 with an empty list when no file has that id.

## 6. Conflicts

**When:** a save (or a queued offline save) is sent with the version it was based on, and the store's current version is a later one:
another device saved in between, or a file was changed outside the store.

**What the user is asked** (the plan's three choices), per file, with who changed it and when:

- **Keep mine:** write mine as the next version over theirs (theirs stays in the history and can be got back).
- **Take theirs:** drop my change to this file and load theirs (mine is kept as a local copy until the next successful sync, in case).
- **Save mine as a copy:** write mine next to theirs as `<name> (<device>, <date>).didsa`. **The copy gets a new Part id** (as Save As
  already does, `remint_identity.dart`): with the same id, the moved-files rule would find two files with one id and ask every time.

**A whole assembly at once (Save All):** a save of several files is one `commit`: all of it lands or none of it does, so a project is
never left half from one device and half from another. A 409 lists every clashing file; the user decides each, and the commit is sent
again with the choices made. A single-file Save is a commit of one file.

**A file renamed or deleted on one device and changed on another:** the commit's `base_version` for a path that no longer exists is a
clash like any other ("Shaft.didsa was renamed to Shaft-v2.didsa on Desktop"); Keep mine writes it at the old path again, Take theirs drops
it, Save mine as a copy writes the copy. References to it are the moved-files rule's job, which already handles a file found under another
path by its Part id.

**Not attempted:** merging two people's changes to one file (feature by feature, occurrence by occurrence). Stable, diffable feature ids
keep that possible later; it is not in S1 to S4.

## 7. The two apps

**Flat app (S2, built; see "S2 results" in the plan for the differences).** A `ServerProjectRoot` / `ServerFileHandle` next to the existing sealed variants, and a `RemoteStorageService` behind
`StorageService`, so Open, Save, Save All and the composer do not change above it. Two things the interface lacks today and S2 adds:

1. **a write that names the version it replaces** (`writeFile(..., baseVersion:)`; the local services ignore it), and
2. **a write of several files at once** (`commit`), which Save All uses for a server project. For a local folder it stays file by file.

`FileCache` becomes the server project's local copy, plus a queue of unsent saves and a sync state per file (synced / to send / clash),
shown as a chip. Offline: open from the cache, save to the queue. File menu: "Server projects" next to the local folder; "Copy this
project to the server". **Also worth doing in S2, for local folders:** the flat app's Save All has no check at all for a file changed
on disk since it was read (VR has one). The same "changed meanwhile?" question as the store's, asked by modified time.

**DIDSA-VR (S3): a mirror folder.** *(As built, 14 Nov: the mirror is `Documents/DIDSA-Cloud/<server host>/<project>/`, visible so files can be dragged in by hand, with the sync state private in `user://didsa-cloud-state/`; it needs All files access, falling back to `user://DIDSA-Cloud` without it. The text below is the original design.)* Each server project the headset opens is copied into `user://projects/<server>/<project>/`, with a
small `sync.json` beside it (each file's version and hash as last synced, the queue, the cursor). Everything that reads files today
(`native_compose.gd`, `file_lookup.gd`, `file_index.gd`) reads that folder with no change; `project_save.gd` writes there as it does to any
folder, then the sync step sends what changed as one commit. So:

- no storage layer under every file call (the reason option D was turned down on 4 Nov),
- no *All files access* for server projects (`user://` is the app's own; the Quest permission problems in `docs/android-build.md` do not
  apply to them), and
- offline just works: the mirror is the copy.

Files lists server projects next to the local folder; the landing shows what is waiting to sync and any clash.

**The Quest spike (done in this phase; the owner reads it off the headset).** Launcher > Servers > **Check storage**
(`scripts/storage_probe.gd`) shows where `user://` is on the Quest, how much room it has (and Documents), and the time to write and read
a 20 MB file; the same line goes to `adb logcat`. The questions to answer are in DIDSA-VR `docs/android-build.md`, "Storage for server
projects". **Run here on the desktop only** (headless, `tests/storage_probe.gd`). What S3 needs from the answers: enough free space for a
few projects (hundreds of MB), and write / read times that make a sync of a whole project feel quick. If `user://` turns out to be small or
slow on the Quest, the mirror can live in `Documents/DIDSA/.server/` instead (the app's own files there need no permission either).

**Finding the store.** The backend's `/health` gains `project_store` (its public address, when the backend is told it with
`PROJECT_STORE_URL`; never the key). The flat app's server settings take the store's key once. The pairing code gains `p=<store address>`
and `pk=<store key>` (not `s` / `sk`, section 3). An older headset ignores both keys; an older flat app never writes them.

## 8. Decisions for the owner (all eight recommendations ACCEPTED, 2026-11-13)

The owner accepted every recommendation below on 2026-11-13; the table is kept as the record of what was asked.

| # | Question | Recommendation |
|---|---|---|
| S0-1 | The store as its own container, or a router in the backend? | **Own container** (section 4) |
| S0-2 | One shared store key (as the backend and relay have), or a key per device now? | **One shared key now**, devices named by `X-Device-Name`; per-device keys with revocation stay in P7 |
| S0-3 | Where the server keeps projects | A volume the owner mounts at `PROJECT_STORE_ROOT`; may be a synced Drive / OneDrive folder or a NAS mount (changes made there are picked up by the scan) |
| S0-4 | How many versions to keep | **The last 20 of each file, and everything from the last 30 days**, whichever keeps more |
| S0-5 | Save All on a server project as one all-or-nothing commit | **Yes** (section 6) |
| S0-6 | DIDSA-VR keeps server projects as a mirror folder in its own storage | **Yes**, `user://`, unless the spike shows it too small or slow (then `Documents/DIDSA/.server/`) |
| S0-7 | Pairing code keys for the store | `p` and `pk` |
| S0-8 | Add a "changed on disk meanwhile?" check to the flat app's Save All for **local** folders too, in S2 | **Yes**: VR already has it; the flat app silently overwrites |

## 9. The phases, refined

- **S1, the store** (CAD repo, `project-store/`): sections 4 and 5. Tests: every endpoint; a stale `PUT` refused with 412 and nothing
  written; a commit with one stale file refused whole with 409 and nothing written; two writers racing (one wins, the other gets 412 / 409);
  a file changed on disk outside the store becomes a version by "outside" and a save based on the old one is refused; the change feed from a
  cursor; the part-id index after a rename; the kept-versions rule; paths that must be refused. The compose file gains the service.
- **S2, the flat app:** section 7. Tests: the remote service against a fake store (widget and service tests), offline save to the queue
  and the sync on reconnect, each of the three conflict choices, the copy's new Part id, Save All as one commit, the local-folder check
  (S0-8).
- **S3, DIDSA-VR:** the mirror and its sync, the Files and landing UI, the pairing keys. Tests: headless with a fake store (as
  `mates_suggested_type.gd` fakes the backend), plus one e2e against a real store in `ci_e2e.sh`.
- **S4, hardening:** chunked upload past the tunnel's limit, an upload cut off half-way, the store coming back mid-sync, two devices
  offline on one file, the local copy's size limit and clean-up, thumbnails for the Rooms and landing tiles.

## 10. Risks and open points

- **Backups.** The store holds the only server copy. Its folder should itself be backed up (a synced Drive folder does that). S1 documents
  it; it does not build a backup.
- **The SD card.** A Pi on an SD card wears with many small writes. Saves are not that frequent, and SQLite with WAL batches them; a USB
  SSD for `PROJECT_STORE_ROOT` is the safer set-up. Not measured.
- **One shared key** means any device with it can read and write every project. Fine for one person's devices; not for sharing with
  someone else (P7).
- **Clock skew** does not matter for conflicts (versions are counters), only for the "when" shown to the user.
- **Live sessions (Part 3)** do not depend on this (observers get geometry from the presenter's session), but the presenter needs S2 / S3
  to open the same project on every device.

## 11. Not verified

Nothing in sections 4 to 9 is built. The Quest spike has run only on a desktop (headless). The Cloudflare limit is from Cloudflare's
documentation, not measured. The store's performance on a Pi is unknown until S1.
