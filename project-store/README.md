# Project store

A small, separate service that keeps DIDSA projects as a plain folder tree on the server, gives every file a version, and refuses a
save made from an out-of-date copy. The spec is `docs/shared-storage-scope.md` (sections 4 to 6); this is phase S1 of
`docs/mates-storage-sessions-plan-2026-11-12.md`. The flat app's client (S2) is built (`client/lib/storage/server/`, `client/README.md`); DIDSA-VR's (S3, `docs/mates-storage-sessions-plan-2026-11-12.md`) is built (DIDSA-VR PR #85) and tested against this store: its e2e test starts a throwaway one (`PROJECT_STORE_API_KEY`, `PROJECT_STORE_ROOT`, one worker).

## Why a separate container

Same reasoning as `browser-relay/README.md`: the CAD backend stays stateless and never reads or writes a project file
(`docs/assembly-scope.md` decision #6), so the files live here. A long upload or a history clean-up never competes with OCCT for
the Pi's 4 GB, either can be restarted or rebuilt alone, and the key can be given to a device without the backend's (and back).
This service never imports backend code.

## On disk (`PROJECT_STORE_ROOT`)

```
<root>/<Project>/path/File.didsa      the CURRENT version of each file, as a plain file
<root>/.didsa-store/store.sqlite      versions, change feed, devices, uploads (SQLite, WAL)
<root>/.didsa-store/blobs/ab/cdef...  every kept version's bytes, by SHA-256
```

The root may be a synced Drive / OneDrive folder or a NAS mount (not tried here). A file changed there is noticed by a scan: size
and mtime are compared with the last recorded version (stat only) and only a difference is hashed; a different hash is recorded as
a new version by `outside`, so the next save made from an older copy is refused. The scan runs before every read of a tree, change
feed, part index or project list, before any read of a file, and before any write to a file (a commit scans the whole project).
Limits of that scan: a change that keeps both size and mtime is not noticed; a file with a name Windows cannot store, a symlink
and `.didsa-store` are ignored. Back the root folder up: it holds the only server copy.

## API

Every request, `/health` included, needs `X-API-Key` (the backend's rule: the tunnel makes the service internet-reachable, so an open
endpoint would let a scanner confirm it is up). A device names itself with `X-Device-Name`; it is recorded as "modified by" and
trusted for nothing else.

| | |
|---|---|
| `GET /health` | `{status, api_features, version}` |
| `GET /projects`, `POST /projects {name}` | list; create (201, 409 if the name is taken, 400 for a bad name) |
| `GET /projects/{p}/tree` | every file: `path, size, sha256, version, modified_at, modified_by, part_id`; also `cursor` |
| `GET /projects/{p}/files/{path}` | the bytes; `ETag: "<version>"`, `X-Sha256` |
| `PUT /projects/{p}/files/{path}` | `If-Match: "<v>"` or `If-None-Match: *`. Neither: **428**. Stale: **412** with `current`. 200 / 201 |
| `DELETE /projects/{p}/files/{path}` | `If-Match` required (428), 412 when stale, history kept |
| `POST /projects/{p}/uploads` | raw body; `{upload_id}`, valid one hour |
| `POST /projects/{p}/uploads/sessions {size, sha256}` | **chunked upload (S4)** for a file too big for one request: `{upload_id, size, received: 0, chunk_size, complete: false}`. 413 over the file limit, 400 for a bad size / hash |
| `PUT /projects/{p}/uploads/{id}?offset=N` | one chunk (at most 64 MB; the advised `chunk_size` is 32 MB), appended **in order**: `N` must be the bytes received so far, else **409 `wrong_offset`** with `received` (a client that lost a reply asks where the store is and carries on). Each chunk renews the hour. 400 `chunk_past_end`; 404 `unknown_upload` once expired |
| `GET /projects/{p}/uploads/{id}` | `{size, received, complete, chunk_size, expires_at}`: how far it got (how an interrupted upload resumes) |
| `POST /projects/{p}/uploads/{id}/complete` | needs all bytes (else 409 `incomplete`); checks the size and the declared SHA-256 (a mismatch is 400 `checksum_mismatch` and **the upload is discarded**); then `{upload_id, size, sha256}` and the id goes into a `commit` exactly like a one-shot upload's. Calling it twice answers the same |
| `DELETE /projects/{p}/uploads/{id}` | cancel: the bytes are removed |
| `POST /projects/{p}/commit` | `{message?, changes: [{op: put\|delete\|move, path, to?, base_version\|null, upload_id?}]}`: all or nothing. **409** lists every clash (`conflicts`), nothing written |
| `GET .../files/{path}/versions`, `.../versions/{v}` | kept versions (newest first), and their bytes |
| `GET /projects/{p}/changes?since=<cursor>&limit=` | `{changes, cursor, more}`; start from the tree's `cursor` |
| `GET /projects/{p}/parts/{part_id}` | `{part_id, files}`: the paths whose root Part id this is (200 with `[]` when none) |

Errors are `{error, detail, ...}`. Paths are refused with 400 (never repaired): `..`, absolute, backslashes, `.didsa-store`,
characters or names Windows cannot store, and (because of the history routes) a last part `versions` or `versions/<digits>`.
Versions are per-file counters (a delete is a version, so a stale copy never matches a file re-created later). Kept: the last 20
versions of each file and everything younger than 30 days, whichever is more; a deleted file's versions for 30 days.
A native file's `part_id` is `document.root_part_id` of its JSON (names ending `.didsa`, `.didsaprt`, `.didsa.json`, up to 100 MB);
anything else is null. Files up to 200 MB (`PROJECT_STORE_MAX_FILE_MB`). Cloudflare's tunnel limit of 100 MB per request is
documented, not measured; a file over about 90 MB goes up in chunks (S4, above), which keeps every request under it.
`/health` lists `uploads.chunked` when the store can take them; a client checks before relying on it. The chunk session is in the `uploads` table (new columns `received`
and `complete`, added with `ALTER TABLE` at start-up, so a store made before S4 opens unchanged and its rows count as complete one-shot uploads) and the bytes are in
`.didsa-store/uploads/<id>`; both **survive a restart** (only `tmp/` is cleared at start-up), so a store switched off and on loses no chunk. An upload nobody touched for an
hour is swept like any other, and unfinished sessions may declare at most 4 times the file limit in all (**429 `too_many_uploads`** past it), so abandoned ones cannot fill the disk; a client cancels the session of a file that changed (`DELETE`). The file's SHA-256 is computed once, at `complete` (a 200 MB file reads in about a second on a laptop; not measured on a Pi).

## Environment variables

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `PROJECT_STORE_API_KEY` | yes | - | Clients send it as `X-API-Key`. The service refuses to start without it. |
| `PROJECT_STORE_ROOT` | yes (the image sets `/data`) | - | Where projects and `.didsa-store/` live. |
| `PROJECT_STORE_MAX_FILE_MB` | no | `200` | Largest file. |

## Running beside the backend

`docker-compose.example.yml` has a `project-store` service (port 8200, a volume at `/data`, `mem_limit`). Set `PROJECT_STORE_API_KEY`
(a different value from `CAD_API_KEY`) and, so the backend can advertise the store, `PROJECT_STORE_URL` (the address clients reach
it at, e.g. `https://store.example.com`, never the key). The backend's `GET /health` then carries `project_store` and lists
`project_store` in `api_features`; with `PROJECT_STORE_URL` unset both are absent. Clients take the store's key separately.
Locally: `PROJECT_STORE_API_KEY=dev PROJECT_STORE_ROOT=/tmp/store python -m uvicorn app.main:app --port 8200` (one worker).

## Tests

```
pip install -r requirements.txt
pytest
```

FastAPI's TestClient, a temp folder per test, an injected clock, no network. CI: `.github/workflows/project-store-verify.yml`.
Not verified: a Raspberry Pi, a Cloudflare tunnel, a synced Drive / NAS folder as the root, a 100 MB upload through the tunnel.
