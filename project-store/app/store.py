"""The project store's core: projects as plain folders, a version per file, optimistic concurrency, a change feed.

Everything here is synchronous and serialised by ONE re-entrant lock (the service runs one worker process, so there is no
cross-process locking to get wrong). `Store` has no HTTP in it; app/api.py maps its errors to status codes. See
docs/shared-storage-scope.md sections 4 to 6 for the design and README.md for the on-disk layout.

On disk (`root`):
    <project>/...                the CURRENT version of every file, at its real path, as plain files
    .didsa-store/store.sqlite    versions, the change feed, the part-id index, devices, uploads
    .didsa-store/blobs/ab/cdef   every kept version's bytes, by SHA-256
    .didsa-store/tmp, uploads    staging (emptied at start-up)

Versions are a per-file counter that only goes up (a delete is a version too, so a stale copy can never match a re-created file).
"""

import contextlib
import dataclasses
import hashlib
import os
import shutil
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Callable, Iterator

from app import native
from app.paths import STORE_DIR_NAME, UnsafePath, is_valid_name_for_scan, validate_file_path, validate_project_name

KEEP_LAST_VERSIONS = 20
KEEP_DAYS = 30
UPLOAD_TTL_SECONDS = 3600
CHUNK_SIZE = 32 * 1024 * 1024  # what a client is told to send per chunk (well under a Cloudflare tunnel's 100 MB request limit)
MAX_CHUNK_BYTES = 64 * 1024 * 1024  # the most one chunk request may carry (413 past it)
SWEEP_INTERVAL_SECONDS = 3600
OUTSIDE = "outside"
UNKNOWN_DEVICE = "unknown"

_COPY_CHUNK = 1024 * 1024


# ---------------------------------------------------------------- errors


class StoreError(Exception):
    status = 500
    code = "error"

    def __init__(self, detail: str, code: str | None = None, **extra):
        super().__init__(detail)
        self.detail = detail
        if code is not None:
            self.code = code
        self.extra = extra


class BadRequest(StoreError):
    status = 400
    code = "bad_request"


class NotFound(StoreError):
    status = 404
    code = "not_found"


class PreconditionFailed(StoreError):
    """412: a single write's If-Match / If-None-Match did not hold. `extra["current"]` describes what is current."""

    status = 412
    code = "stale_version"


class PreconditionRequired(StoreError):
    status = 428
    code = "precondition_required"


class Conflict(StoreError):
    """409: the name is taken, a path collides with a folder, or (extra["conflicts"]) a commit clashed. Nothing was written."""

    status = 409
    code = "conflict"


class TooLarge(StoreError):
    status = 413
    code = "too_large"


# ---------------------------------------------------------------- small value types


@dataclasses.dataclass
class Staged:
    """Bytes already on disk inside `.didsa-store/` (a PUT body or an upload), hashed and with its part id read."""

    path: str
    sha256: str
    size: int
    part_id: str | None


@dataclasses.dataclass
class Expect:
    """What a single write says it is replacing: a version (`version` set), or a create-only (`create` True)."""

    version: int | None = None
    create: bool = False


def iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def clean_device(name: str | None) -> str:
    """X-Device-Name is free text and trusted for nothing: trimmed, control characters dropped, 80 characters at most."""
    if not name:
        return UNKNOWN_DEVICE
    cleaned = "".join(ch for ch in name if ch.isprintable()).strip()[:80]
    return cleaned or UNKNOWN_DEVICE


def _sha_of_file(path: str) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as handle:
        while chunk := handle.read(_COPY_CHUNK):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


_SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    project TEXT NOT NULL, path TEXT NOT NULL,
    version INTEGER NOT NULL, sha256 TEXT, size INTEGER NOT NULL DEFAULT 0, mtime_ns INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0, modified_at REAL NOT NULL, modified_by TEXT NOT NULL,
    part_id TEXT, deleted_at REAL, moved_to TEXT,
    PRIMARY KEY (project, path)
);
CREATE INDEX IF NOT EXISTS files_part ON files (project, part_id) WHERE deleted = 0 AND part_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS versions (
    project TEXT NOT NULL, path TEXT NOT NULL, version INTEGER NOT NULL,
    sha256 TEXT, size INTEGER NOT NULL DEFAULT 0, at REAL NOT NULL, by TEXT NOT NULL,
    op TEXT NOT NULL, moved_to TEXT, moved_from TEXT, message TEXT,
    PRIMARY KEY (project, path, version)
);
CREATE INDEX IF NOT EXISTS versions_sha ON versions (sha256);
CREATE TABLE IF NOT EXISTS changes (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, project TEXT NOT NULL, path TEXT NOT NULL,
    op TEXT NOT NULL, version INTEGER NOT NULL, device TEXT NOT NULL, at REAL NOT NULL,
    moved_to TEXT, moved_from TEXT
);
CREATE INDEX IF NOT EXISTS changes_project ON changes (project, seq);
CREATE TABLE IF NOT EXISTS uploads (
    id TEXT PRIMARY KEY, project TEXT NOT NULL, size INTEGER NOT NULL, sha256 TEXT NOT NULL,
    part_id TEXT, created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (name TEXT PRIMARY KEY, first_seen REAL NOT NULL, last_seen REAL NOT NULL);
"""


class Store:
    def __init__(self, root: str, clock: Callable[[], float] = time.time, max_file_bytes: int = 200 * 1024 * 1024):
        self.root = os.path.abspath(root)
        self.clock = clock
        self.max_file_bytes = max_file_bytes
        self.lock = threading.RLock()
        self.data_dir = os.path.join(self.root, STORE_DIR_NAME)
        self.blob_dir = os.path.join(self.data_dir, "blobs")
        self.tmp_dir = os.path.join(self.data_dir, "tmp")
        self.upload_dir = os.path.join(self.data_dir, "uploads")
        for directory in (self.blob_dir, self.tmp_dir, self.upload_dir):
            os.makedirs(directory, exist_ok=True)
        # Whatever a crashed run left half-staged is not a version of anything.
        for directory in (self.tmp_dir,):
            for name in os.listdir(directory):
                with contextlib.suppress(OSError):
                    os.unlink(os.path.join(directory, name))
        self.db = sqlite3.connect(os.path.join(self.data_dir, "store.sqlite"), check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        # NORMAL: a power cut may lose the last transaction but cannot corrupt the file, and it saves SD-card writes (scope, section 10).
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(_SCHEMA)
        self._migrate_uploads()
        self._last_sweep = self.clock()
        self._pruned = False
        self.sweep()

    def close(self) -> None:
        with self.lock:
            self.db.close()

    def _migrate_uploads(self) -> None:
        """S4: chunked uploads add `received` (bytes so far) and `complete` (0 while chunks are still coming) to `uploads`. A store made
        before S4 has neither: its rows are one-shot uploads, so they are complete and `received` is their size."""
        columns = {row["name"] for row in self.db.execute("PRAGMA table_info(uploads)").fetchall()}
        if "received" not in columns:
            self.db.execute("ALTER TABLE uploads ADD COLUMN received INTEGER")
            self.db.execute("UPDATE uploads SET received = size")
        if "complete" not in columns:
            self.db.execute("ALTER TABLE uploads ADD COLUMN complete INTEGER NOT NULL DEFAULT 1")

    # ------------------------------------------------------------ helpers

    @contextlib.contextmanager
    def _transaction(self) -> Iterator[None]:
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        else:
            self.db.execute("COMMIT")

    def _project_dir(self, project: str) -> str:
        try:
            validate_project_name(project)
        except UnsafePath as error:
            raise NotFound(f"no project named {project!r}", code="no_such_project") from error
        directory = os.path.join(self.root, project)
        if not os.path.isdir(directory) or os.path.islink(directory):
            raise NotFound(f"no project named {project!r}", code="no_such_project")
        return directory

    def _file_path(self, project_dir: str, path: str) -> str:
        """The real path of a validated project-relative path; refuses anything that would leave the project (symlinks included)."""
        full = os.path.join(project_dir, *path.split("/"))
        real_parent = os.path.realpath(os.path.dirname(full))
        real_project = os.path.realpath(project_dir)
        if real_parent != real_project and not real_parent.startswith(real_project + os.sep):
            raise BadRequest("the path leaves the project", code="bad_path")
        return full

    def _check_path(self, path) -> str:
        try:
            return validate_file_path(path)
        except UnsafePath as error:
            raise BadRequest(str(error)) from error

    def _blob_path(self, sha: str) -> str:
        return os.path.join(self.blob_dir, sha[:2], sha[2:])

    def _ensure_blob(self, source: str, sha: str, *, consume: bool = False) -> None:
        """Put `source`'s bytes in the blob store under `sha` (a no-op when already there)."""
        blob = self._blob_path(sha)
        if os.path.exists(blob):
            if consume:
                with contextlib.suppress(OSError):
                    os.unlink(source)
            return
        os.makedirs(os.path.dirname(blob), exist_ok=True)
        if consume:
            os.replace(source, blob)
            return
        staging = self.new_tmp_path()
        shutil.copyfile(source, staging)
        os.replace(staging, blob)

    def new_tmp_path(self) -> str:
        return os.path.join(self.tmp_dir, uuid.uuid4().hex)

    def _touch_device(self, device: str, now: float) -> None:
        self.db.execute(
            "INSERT INTO devices (name, first_seen, last_seen) VALUES (?, ?, ?) "
            "ON CONFLICT(name) DO UPDATE SET last_seen = excluded.last_seen",
            (device, now, now),
        )

    def _info(self, row) -> dict:
        return {
            "path": row["path"],
            "size": row["size"],
            "sha256": row["sha256"],
            "version": row["version"],
            "modified_at": iso(row["modified_at"]),
            "modified_by": row["modified_by"],
            "part_id": row["part_id"],
        }

    def _current_description(self, row) -> dict | None:
        """What a refused client is told is current: the live file's details, or the delete / move that removed it, or None."""
        if row is None:
            return None
        if not row["deleted"]:
            return self._info(row)
        return {
            "path": row["path"],
            "version": row["version"],
            "deleted": True,
            "modified_at": iso(row["modified_at"]),
            "modified_by": row["modified_by"],
            **({"moved_to": row["moved_to"]} if row["moved_to"] else {}),
        }

    def _row(self, project: str, path: str):
        return self.db.execute("SELECT * FROM files WHERE project = ? AND path = ?", (project, path)).fetchone()

    def _record_change(self, project, path, op, version, device, now, moved_to=None, moved_from=None) -> None:
        self.db.execute(
            "INSERT INTO changes (project, path, op, version, device, at, moved_to, moved_from) VALUES (?,?,?,?,?,?,?,?)",
            (project, path, op, version, device, now, moved_to, moved_from),
        )

    def _record_version(self, project, path, version, sha, size, now, device, op, moved_to=None, moved_from=None, message=None) -> None:
        self.db.execute(
            "INSERT INTO versions (project, path, version, sha256, size, at, by, op, moved_to, moved_from, message) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (project, path, version, sha, size, now, device, op, moved_to, moved_from, message),
        )

    # ------------------------------------------------------------ the "changed outside the store" scan

    def _walk(self, project_dir: str) -> Iterator[tuple[str, str, os.stat_result]]:
        """(relative path, real path, stat) of every regular file under a project, skipping the store's own folder,
        symlinks and names the store would refuse."""
        stack = [("", project_dir)]
        while stack:
            prefix, directory = stack.pop()
            try:
                entries = list(os.scandir(directory))
            except OSError:
                continue
            for entry in entries:
                name = entry.name
                if name.lower() == STORE_DIR_NAME or not is_valid_name_for_scan(name):
                    continue
                try:
                    if entry.is_symlink():
                        continue
                    relative = prefix + name
                    if entry.is_dir(follow_symlinks=False):
                        stack.append((relative + "/", entry.path))
                    elif entry.is_file(follow_symlinks=False):
                        yield relative, entry.path, entry.stat(follow_symlinks=False)
                except OSError:
                    continue

    def _record_outside_put(self, project: str, path: str, full: str, st: os.stat_result, row, now: float) -> None:
        """A file whose content differs from the last recorded version (or that is new): a new version by "outside"."""
        staging = self.new_tmp_path()
        shutil.copyfile(full, staging)
        sha, size = _sha_of_file(staging)
        if row is not None and not row["deleted"] and row["sha256"] == sha:
            os.unlink(staging)
            # Touched but not changed (a sync client rewrote it): remember the new stat so it is not hashed again.
            self.db.execute("UPDATE files SET size = ?, mtime_ns = ? WHERE project = ? AND path = ?", (size, st.st_mtime_ns, project, path))
            return
        part_id = native.root_part_id(staging, size) if native.looks_native(path) else None
        self._ensure_blob(staging, sha, consume=True)
        version = (row["version"] + 1) if row is not None else 1
        self._record_version(project, path, version, sha, size, now, OUTSIDE, "put")
        self._record_change(project, path, "put", version, OUTSIDE, now)
        self.db.execute(
            "INSERT INTO files (project, path, version, sha256, size, mtime_ns, deleted, modified_at, modified_by, part_id, deleted_at, moved_to) "
            "VALUES (?,?,?,?,?,?,0,?,?,?,NULL,NULL) "
            "ON CONFLICT(project, path) DO UPDATE SET version = excluded.version, sha256 = excluded.sha256, size = excluded.size, "
            "mtime_ns = excluded.mtime_ns, deleted = 0, modified_at = excluded.modified_at, modified_by = excluded.modified_by, "
            "part_id = excluded.part_id, deleted_at = NULL, moved_to = NULL",
            (project, path, version, sha, size, st.st_mtime_ns, now, OUTSIDE, part_id),
        )

    def _record_outside_delete(self, project: str, row, now: float) -> None:
        version = row["version"] + 1
        self._record_version(project, row["path"], version, None, 0, now, OUTSIDE, "delete")
        self._record_change(project, row["path"], "delete", version, OUTSIDE, now)
        self.db.execute(
            "UPDATE files SET version = ?, sha256 = NULL, size = 0, deleted = 1, deleted_at = ?, modified_at = ?, modified_by = ?, "
            "part_id = NULL, moved_to = NULL WHERE project = ? AND path = ?",
            (version, now, now, OUTSIDE, project, row["path"]),
        )

    def _scan_path(self, project: str, project_dir: str, path: str) -> None:
        """Cheap check of one file against its last recorded version: stat first, hash only when size or mtime differs."""
        row = self._row(project, path)
        full = self._file_path(project_dir, path)
        try:
            st = os.stat(full, follow_symlinks=False)
            exists = os.path.isfile(full) and not os.path.islink(full)
        except OSError:
            st, exists = None, False
        now = self.clock()
        with self._transaction():
            if exists:
                if row is None or row["deleted"] or row["size"] != st.st_size or row["mtime_ns"] != st.st_mtime_ns:
                    self._record_outside_put(project, path, full, st, row, now)
            elif row is not None and not row["deleted"]:
                self._record_outside_delete(project, row, now)

    def _scan_project(self, project: str, project_dir: str) -> None:
        live = {r["path"]: r for r in self.db.execute("SELECT * FROM files WHERE project = ? AND deleted = 0", (project,))}
        seen: set[str] = set()
        now = self.clock()
        changed = []
        for relative, full, st in self._walk(project_dir):
            seen.add(relative)
            row = live.get(relative)
            if row is None:
                row = self._row(project, relative)  # a deleted one that has come back
                changed.append((relative, full, st, row))
            elif row["size"] != st.st_size or row["mtime_ns"] != st.st_mtime_ns:
                changed.append((relative, full, st, row))
        gone = [row for path, row in live.items() if path not in seen]
        if not changed and not gone:
            return
        with self._transaction():
            for relative, full, st, row in changed:
                self._record_outside_put(project, relative, full, st, row, now)
            for row in gone:
                self._record_outside_delete(project, row, now)

    # ------------------------------------------------------------ staging (the API streams bodies here, outside the lock)

    def make_staged(self, tmp_path: str, sha256: str, size: int, path_hint: str | None = None) -> Staged:
        """`path_hint` is the file's path when it is known (a PUT); an upload for a commit does not know it yet, so its part id is
        read by sniffing and used at commit time only for a path that names a native file."""
        part_id = None if path_hint is not None and not native.looks_native(path_hint) else native.root_part_id(tmp_path, size)
        return Staged(tmp_path, sha256, size, part_id)

    def discard(self, staged: Staged) -> None:
        with contextlib.suppress(OSError):
            os.unlink(staged.path)

    # ------------------------------------------------------------ projects

    def _project_names(self) -> list[str]:
        names = []
        for entry in sorted(os.scandir(self.root), key=lambda e: e.name):
            if entry.name.startswith(".") or entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                continue
            try:
                validate_project_name(entry.name)
            except UnsafePath:
                continue
            names.append(entry.name)
        return names

    def list_projects(self) -> list[dict]:
        with self.lock:
            result = []
            for name in self._project_names():
                self._scan_project(name, os.path.join(self.root, name))
                count, total = self.db.execute(
                    "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files WHERE project = ? AND deleted = 0", (name,)
                ).fetchone()
                last = self.db.execute("SELECT at, device FROM changes WHERE project = ? ORDER BY seq DESC LIMIT 1", (name,)).fetchone()
                result.append(
                    {
                        "name": name,
                        "file_count": count,
                        "total_size": total,
                        "last_change": iso(last["at"]) if last else None,
                        "last_device": last["device"] if last else None,
                    }
                )
            return result

    def create_project(self, name: str, device: str) -> dict:
        try:
            validate_project_name(name)
        except UnsafePath as error:
            raise BadRequest(str(error)) from error
        with self.lock:
            directory = os.path.join(self.root, name)
            # Compared in lower case as well: a synced folder may live on a case-insensitive file system.
            if any(existing.lower() == name.lower() for existing in os.listdir(self.root)):
                raise Conflict(f"a project named {name!r} already exists")
            os.mkdir(directory)
            with self._transaction():
                self._touch_device(clean_device(device), self.clock())
            return {"name": name, "file_count": 0, "total_size": 0, "last_change": None, "last_device": None}

    # ------------------------------------------------------------ reads

    def tree(self, project: str) -> dict:
        with self.lock:
            project_dir = self._project_dir(project)
            self._scan_project(project, project_dir)
            rows = self.db.execute("SELECT * FROM files WHERE project = ? AND deleted = 0 ORDER BY path", (project,)).fetchall()
            return {"project": project, "files": [self._info(r) for r in rows], "cursor": self._latest_cursor()}

    def _latest_cursor(self) -> str:
        return str(self.db.execute("SELECT COALESCE(MAX(seq), 0) FROM changes").fetchone()[0])

    def open_current(self, project: str, path: str):
        """(info, open binary file) for a live file. The handle stays valid even if the file is replaced meanwhile."""
        path = self._check_path(path)
        with self.lock:
            project_dir = self._project_dir(project)
            self._scan_path(project, project_dir, path)
            row = self._row(project, path)
            if row is None or row["deleted"]:
                raise NotFound(f"no file {path!r} in {project!r}")
            return self._info(row), open(self._file_path(project_dir, path), "rb")

    def current_info(self, project: str, path: str) -> dict | None:
        """The details of the live file at `path` (after a scan), or None. Used to refuse a stale write before its body is read."""
        path = self._check_path(path)
        with self.lock:
            project_dir = self._project_dir(project)
            self._scan_path(project, project_dir, path)
            row = self._row(project, path)
            return self._info(row) if row is not None and not row["deleted"] else None

    def check_expectation(self, project: str, path: str, expect: Expect, for_delete: bool = False) -> None:
        """Raises PreconditionFailed if a write with this expectation would be refused now (the full check is repeated under the lock
        when the write is made)."""
        path = self._check_path(path)
        with self.lock:
            project_dir = self._project_dir(project)
            self._scan_path(project, project_dir, path)
            self._check_expectation(self._row(project, path), path, expect, for_delete)

    def versions(self, project: str, path: str) -> dict:
        path = self._check_path(path)
        with self.lock:
            self._project_dir(project)
            rows = self.db.execute(
                "SELECT * FROM versions WHERE project = ? AND path = ? ORDER BY version DESC", (project, path)
            ).fetchall()
            if not rows:
                raise NotFound(f"no history for {path!r} in {project!r}")
            return {
                "path": path,
                "versions": [
                    {
                        "version": r["version"],
                        "size": r["size"],
                        "sha256": r["sha256"],
                        "at": iso(r["at"]),
                        "by": r["by"],
                        "op": r["op"],
                        "deleted": r["op"] == "delete",
                        **({"moved_to": r["moved_to"]} if r["moved_to"] else {}),
                        **({"moved_from": r["moved_from"]} if r["moved_from"] else {}),
                        **({"message": r["message"]} if r["message"] else {}),
                    }
                    for r in rows
                ],
            }

    def open_version(self, project: str, path: str, version: int):
        path = self._check_path(path)
        with self.lock:
            self._project_dir(project)
            row = self.db.execute(
                "SELECT * FROM versions WHERE project = ? AND path = ? AND version = ?", (project, path, version)
            ).fetchone()
            if row is None:
                raise NotFound(f"version {version} of {path!r} is not kept")
            if row["sha256"] is None:
                raise NotFound(f"version {version} of {path!r} is a delete: it has no bytes")
            return (
                {"path": path, "version": version, "sha256": row["sha256"], "size": row["size"]},
                open(self._blob_path(row["sha256"]), "rb"),
            )

    def changes(self, project: str, since: str | None, limit: int = 1000) -> dict:
        with self.lock:
            project_dir = self._project_dir(project)
            self._scan_project(project, project_dir)
            try:
                after = int(since) if since not in (None, "") else 0
                if after < 0:
                    raise ValueError
            except ValueError as error:
                raise BadRequest(f"the cursor {since!r} is not one this store issued", code="bad_cursor") from error
            latest = int(self._latest_cursor())
            if after > latest:
                raise BadRequest(f"the cursor {since!r} is ahead of this store: ask for the tree instead", code="bad_cursor")
            rows = self.db.execute(
                "SELECT * FROM changes WHERE project = ? AND seq > ? ORDER BY seq LIMIT ?", (project, after, limit + 1)
            ).fetchall()
            more = len(rows) > limit
            rows = rows[:limit]
            # Everything after `after` for this project has been read when `more` is false, so the next cursor is the newest change
            # of ALL projects (still valid here, and a quiet project does not re-read an empty range); otherwise the last one returned.
            cursor = str(rows[-1]["seq"]) if more else str(latest)
            return {
                "project": project,
                "changes": [
                    {
                        "path": r["path"],
                        "op": r["op"],
                        "version": r["version"],
                        "device": r["device"],
                        "at": iso(r["at"]),
                        **({"moved_to": r["moved_to"]} if r["moved_to"] else {}),
                        **({"moved_from": r["moved_from"]} if r["moved_from"] else {}),
                    }
                    for r in rows
                ],
                "cursor": cursor,
                "more": more,
            }

    def parts(self, project: str, part_id: str) -> dict:
        with self.lock:
            project_dir = self._project_dir(project)
            self._scan_project(project, project_dir)
            rows = self.db.execute(
                "SELECT * FROM files WHERE project = ? AND deleted = 0 AND part_id = ? ORDER BY path", (project, part_id)
            ).fetchall()
            return {"part_id": part_id, "files": [self._info(r) for r in rows]}

    # ------------------------------------------------------------ uploads (for commits)

    def add_upload(self, project: str, staged: Staged) -> dict:
        with self.lock:
            self._project_dir(project)
            self.sweep_uploads()
            upload_id = uuid.uuid4().hex
            os.replace(staged.path, os.path.join(self.upload_dir, upload_id))
            now = self.clock()
            self.db.execute(
                "INSERT INTO uploads (id, project, size, sha256, part_id, created_at, received, complete) VALUES (?,?,?,?,?,?,?,1)",
                (upload_id, project, staged.size, staged.sha256, staged.part_id, now, staged.size),
            )
            return {"upload_id": upload_id, "size": staged.size, "sha256": staged.sha256, "expires_at": iso(now + UPLOAD_TTL_SECONDS)}

    # ---- chunked uploads (S4): a session declares the size and SHA-256, chunks arrive in order, `complete` checks the hash

    def start_upload_session(self, project: str, size: int, sha256: str) -> dict:
        if not isinstance(size, int) or isinstance(size, bool) or size < 1:
            raise BadRequest("size must be a whole number of bytes, at least 1")
        if size > self.max_file_bytes:
            raise TooLarge(f"a file may be at most {self.max_file_bytes} bytes")
        if not isinstance(sha256, str) or len(sha256) != 64 or any(c not in "0123456789abcdef" for c in sha256.lower()):
            raise BadRequest("sha256 must be the file's 64 hex characters")
        with self.lock:
            self._project_dir(project)
            self.sweep_uploads()
            upload_id = uuid.uuid4().hex
            with open(os.path.join(self.upload_dir, upload_id), "wb"):
                pass
            now = self.clock()
            self.db.execute(
                "INSERT INTO uploads (id, project, size, sha256, part_id, created_at, received, complete) VALUES (?,?,?,?,NULL,?,0,0)",
                (upload_id, project, size, sha256.lower(), now),
            )
            return {"upload_id": upload_id, "size": size, "received": 0, "chunk_size": CHUNK_SIZE, "complete": False,
                    "expires_at": iso(now + UPLOAD_TTL_SECONDS)}

    def _open_session(self, project: str, upload_id: str):
        row = self.db.execute("SELECT * FROM uploads WHERE id = ?", (upload_id,)).fetchone()
        if row is None or row["project"] != project or row["created_at"] < self.clock() - UPLOAD_TTL_SECONDS:
            raise NotFound(f"upload {upload_id!r} is unknown, expired or belongs to another project", code="unknown_upload")
        return row

    def _session_info(self, row) -> dict:
        return {"upload_id": row["id"], "size": row["size"], "received": row["received"], "complete": bool(row["complete"]),
                "chunk_size": CHUNK_SIZE, "expires_at": iso(row["created_at"] + UPLOAD_TTL_SECONDS)}

    def upload_status(self, project: str, upload_id: str) -> dict:
        with self.lock:
            return self._session_info(self._open_session(project, upload_id))

    def add_chunk(self, project: str, upload_id: str, offset: int, staged: Staged) -> dict:
        """Append `staged` (one chunk already on disk) at `offset`, which must be exactly the bytes received so far (409 with `received`
        otherwise, so a client that lost a reply asks `upload_status` and carries on from there). The chunk file is consumed."""
        try:
            with self.lock:
                row = self._open_session(project, upload_id)
                if row["complete"]:
                    raise Conflict("this upload is already complete", code="upload_complete", **self._session_info(row))
                if offset != row["received"]:
                    raise Conflict(f"expected offset {row['received']}, got {offset}", code="wrong_offset", **self._session_info(row))
                if row["received"] + staged.size > row["size"]:
                    raise BadRequest("this chunk goes past the size the upload declared", code="chunk_past_end")
                target = os.path.join(self.upload_dir, upload_id)
                with open(target, "r+b") as out:
                    out.seek(offset)
                    out.truncate()  # bytes past `received` (a chunk cut off half-way by a crash) are not part of the file
                    with open(staged.path, "rb") as source:
                        shutil.copyfileobj(source, out, _COPY_CHUNK)
                received = offset + staged.size
                self.db.execute("UPDATE uploads SET received = ?, created_at = ? WHERE id = ?", (received, self.clock(), upload_id))
                return self._session_info(self._open_session(project, upload_id))
        finally:
            self.discard(staged)

    def complete_upload(self, project: str, upload_id: str) -> dict:
        """All bytes in: check the size and the declared SHA-256 (a mismatch discards the upload: it cannot be repaired), then it is an
        ordinary upload, usable in a commit like the one-shot kind. Completing twice answers the same."""
        with self.lock:
            row = self._open_session(project, upload_id)
            target = os.path.join(self.upload_dir, upload_id)
            if row["complete"]:
                return {"upload_id": upload_id, "size": row["size"], "sha256": row["sha256"], "expires_at": iso(row["created_at"] + UPLOAD_TTL_SECONDS)}
            if row["received"] != row["size"]:
                raise Conflict(f"{row['received']} of {row['size']} bytes received", code="incomplete", **self._session_info(row))
            sha, size = _sha_of_file(target)
            if sha != row["sha256"] or size != row["size"]:
                self._drop_upload(upload_id)
                raise BadRequest("the bytes received do not match the declared SHA-256; the upload was discarded, send it again", code="checksum_mismatch")
            part_id = native.root_part_id(target, size)
            now = self.clock()
            self.db.execute("UPDATE uploads SET complete = 1, part_id = ?, created_at = ? WHERE id = ?", (part_id, now, upload_id))
            return {"upload_id": upload_id, "size": size, "sha256": sha, "expires_at": iso(now + UPLOAD_TTL_SECONDS)}

    def cancel_upload(self, project: str, upload_id: str) -> None:
        with self.lock:
            self._open_session(project, upload_id)
            self._drop_upload(upload_id)

    def _drop_upload(self, upload_id: str) -> None:
        self.db.execute("DELETE FROM uploads WHERE id = ?", (upload_id,))
        with contextlib.suppress(OSError):
            os.unlink(os.path.join(self.upload_dir, upload_id))

    def sweep_uploads(self) -> None:
        cutoff = self.clock() - UPLOAD_TTL_SECONDS
        for row in self.db.execute("SELECT id FROM uploads WHERE created_at < ?", (cutoff,)).fetchall():
            with contextlib.suppress(OSError):
                os.unlink(os.path.join(self.upload_dir, row["id"]))
        self.db.execute("DELETE FROM uploads WHERE created_at < ?", (cutoff,))

    def _take_upload(self, project: str, upload_id) -> Staged:
        row = self.db.execute("SELECT * FROM uploads WHERE id = ?", (upload_id,)).fetchone() if isinstance(upload_id, str) else None
        file_path = os.path.join(self.upload_dir, upload_id) if row is not None else None
        if row is None or row["project"] != project or not row["complete"] or row["created_at"] < self.clock() - UPLOAD_TTL_SECONDS or not os.path.exists(file_path):
            raise BadRequest(f"upload {upload_id!r} is unknown, expired or belongs to another project", code="unknown_upload")
        return Staged(file_path, row["sha256"], row["size"], row["part_id"])

    # ------------------------------------------------------------ single-file writes

    def _check_expectation(self, row, path: str, expect: Expect, for_delete: bool) -> None:
        live = row is not None and not row["deleted"]
        if expect.create:
            if live:
                raise PreconditionFailed(f"{path!r} already exists", current=self._current_description(row))
            return
        if for_delete and row is None:
            raise NotFound(f"no file {path!r}")
        if not live or row["version"] != expect.version:
            raise PreconditionFailed(
                f"{path!r} is not at version {expect.version}", current=self._current_description(row)
            )

    def put(self, project: str, path: str, staged: Staged, expect: Expect, device: str, message: str | None = None) -> tuple[dict, bool]:
        """Write one file. Returns (new version's info, created). Raises PreconditionFailed (nothing written)."""
        device = clean_device(device)
        try:
            path = self._check_path(path)
            with self.lock:
                project_dir = self._project_dir(project)
                self._scan_path(project, project_dir, path)
                row = self._row(project, path)
                self._check_expectation(row, path, expect, False)
                self._check_tree_conflicts(project, [path], set())
                created = row is None or bool(row["deleted"])
                results = self._apply(project, project_dir, [("put", path, None, staged)], device, message)
                return results[0], created
        finally:
            self.discard(staged)

    def delete(self, project: str, path: str, expect: Expect, device: str) -> dict:
        device = clean_device(device)
        path = self._check_path(path)
        with self.lock:
            project_dir = self._project_dir(project)
            self._scan_path(project, project_dir, path)
            row = self._row(project, path)
            self._check_expectation(row, path, expect, True)
            return self._apply(project, project_dir, [("delete", path, None, None)], device, None)[0]

    # ------------------------------------------------------------ commit

    def commit(self, project: str, changes: list[dict], message: str | None, device: str) -> dict:
        """Several changes, all or nothing. Raises Conflict(conflicts=[...]) listing EVERY clash, with nothing written."""
        device = clean_device(device)
        with self.lock:
            project_dir = self._project_dir(project)
            ops = self._validate_commit(project, changes)
            self._scan_project(project, project_dir)

            conflicts: list[dict] = []
            for op, path, to, staged, base in ops:
                row = self._row(project, path)
                live = row is not None and not row["deleted"]
                if op == "put" and base is None:
                    if live:
                        conflicts.append(self._conflict(op, path, base, row, "exists"))
                elif not live or row["version"] != base:
                    reason = "deleted" if row is not None and row["deleted"] else ("missing" if row is None else "changed")
                    conflicts.append(self._conflict(op, path, base, row, reason))
                if op == "move":
                    target = self._row(project, to)
                    if target is not None and not target["deleted"]:
                        conflicts.append(self._conflict(op, to, None, target, "target_exists"))
            leaving = {path for op, path, to, staged, base in ops if op in ("delete", "move")}
            new_paths = [to if op == "move" else path for op, path, to, staged, base in ops if op in ("put", "move")]
            conflicts.extend(self._tree_conflicts(project, new_paths, leaving))
            if conflicts:
                raise Conflict(
                    f"{len(conflicts)} change(s) clash with what is current; nothing was written", conflicts=conflicts
                )

            applied = self._apply(project, project_dir, [(op, path, to, staged) for op, path, to, staged, base in ops], device, message)
            # Uploads are consumed only now that the commit landed (a refused commit keeps them for the retry).
            for op, path, to, staged, base in ops:
                if staged is not None:
                    self.db.execute("DELETE FROM uploads WHERE id = ?", (os.path.basename(staged.path),))
                    with contextlib.suppress(OSError):
                        os.unlink(staged.path)
            return {"files": applied, "cursor": self._latest_cursor()}

    def _conflict(self, op: str, path: str, base, row, reason: str) -> dict:
        return {
            "path": path,
            "op": op,
            "base_version": base,
            "reason": reason,
            "current_version": row["version"] if row is not None else None,
            "current": self._current_description(row),
        }

    def _validate_commit(self, project: str, changes) -> list[tuple]:
        """Structure, paths and uploads (400 on any fault, before anything is compared). Returns [(op, path, to, staged, base)]."""
        if not isinstance(changes, list):
            raise BadRequest("changes must be a list")
        ops = []
        touched: set[str] = set()
        for index, change in enumerate(changes):
            where = f"changes[{index}]"
            if not isinstance(change, dict):
                raise BadRequest(f"{where} must be an object")
            op = change.get("op")
            if op not in ("put", "delete", "move"):
                raise BadRequest(f"{where}: op must be put, delete or move")
            path = self._check_path(change.get("path"))
            base = change.get("base_version")
            if base is not None and (not isinstance(base, int) or isinstance(base, bool) or base < 1):
                raise BadRequest(f"{where}: base_version must be a positive integer or null")
            to = None
            staged = None
            if op == "put":
                staged = self._take_upload(project, change.get("upload_id"))
            elif op == "delete":
                if base is None:
                    raise BadRequest(f"{where}: a delete needs the base_version it deletes")
            else:
                if base is None:
                    raise BadRequest(f"{where}: a move needs the base_version it moves")
                to = self._check_path(change.get("to"))
                if to == path:
                    raise BadRequest(f"{where}: a move needs a different 'to'")
            for name in (path, to):
                if name is None:
                    continue
                if name in touched:
                    raise BadRequest(f"{name!r} appears twice in one commit", code="duplicate_path")
                touched.add(name)
            ops.append((op, path, to, staged, base))
        return ops

    def _tree_conflicts(self, project: str, new_paths: list[str], leaving: set[str]) -> list[dict]:
        """A new file at `a/b` cannot live beside a live file `a`, nor a new `a` beside live files under `a/`."""
        found = []
        live = {r["path"] for r in self.db.execute("SELECT path FROM files WHERE project = ? AND deleted = 0", (project,))} - leaving
        new = set(new_paths)
        for path in new_paths:
            parts = path.split("/")
            ancestors = ["/".join(parts[:i]) for i in range(1, len(parts))]
            clash = next((a for a in ancestors if a in live or a in new), None)
            if clash is None:
                clash = next((p for p in live | new if p.startswith(path + "/")), None)
            if clash is not None:
                found.append(
                    {
                        "path": path,
                        "op": "put",
                        "base_version": None,
                        "reason": "path_conflict",
                        "current_version": None,
                        "current": None,
                        "detail": f"{path!r} would be both a file and a folder (see {clash!r})",
                    }
                )
        return found

    def _check_tree_conflicts(self, project: str, new_paths: list[str], leaving: set[str]) -> None:
        found = self._tree_conflicts(project, new_paths, leaving)
        if found:
            raise Conflict(found[0]["detail"], conflicts=found, code="path_conflict")

    # ------------------------------------------------------------ applying a checked set of changes

    def _apply(self, project: str, project_dir: str, ops: list[tuple], device: str, message: str | None) -> list[dict]:
        """Do the file moves, then the database writes in one transaction; undo the files if anything fails. Checks are the caller's."""
        now = self.clock()
        undo: list[Callable[[], None]] = []
        results: list[dict] = []
        try:
            with self._transaction():
                self._touch_device(device, now)
                for op, path, to, staged in ops:
                    if op == "put":
                        results.append(self._apply_put(project, project_dir, path, staged, device, now, message, undo))
                    elif op == "delete":
                        results.append(self._apply_delete(project, project_dir, path, device, now, message, undo))
                    else:
                        results.extend(self._apply_move(project, project_dir, path, to, device, now, message, undo))
                self._prune_paths(project, {r["path"] for r in results}, now)
        except BaseException:
            for action in reversed(undo):
                with contextlib.suppress(Exception):
                    action()
            raise
        if self._pruned:
            self._pruned = False
            self.gc_blobs()
        self._maybe_sweep()
        return results

    def _write_current(self, project: str, project_dir: str, path: str, sha: str, undo: list) -> os.stat_result:
        """Replace the file at `path` with the blob `sha`, atomically (a copy staged beside the store, then os.replace)."""
        full = self._file_path(project_dir, path)
        previous_sha = None
        previous = self._row(project, path)
        if previous is not None and not previous["deleted"] and os.path.exists(full):
            previous_sha = previous["sha256"]
        created_dirs = self._make_parent_dirs(project_dir, full)
        staging = self.new_tmp_path()
        shutil.copyfile(self._blob_path(sha), staging)
        try:
            os.replace(staging, full)
        except OSError as error:
            with contextlib.suppress(OSError):
                os.unlink(staging)
            for directory in created_dirs:
                with contextlib.suppress(OSError):
                    os.rmdir(directory)
            raise Conflict(f"{path!r} cannot be written: {error.strerror}", code="path_conflict") from error

        def restore() -> None:
            if previous_sha is not None:
                backup = self.new_tmp_path()
                shutil.copyfile(self._blob_path(previous_sha), backup)
                os.replace(backup, full)
            else:
                with contextlib.suppress(OSError):
                    os.unlink(full)
                for directory in created_dirs:
                    with contextlib.suppress(OSError):
                        os.rmdir(directory)

        undo.append(restore)
        return os.stat(full)

    def _make_parent_dirs(self, project_dir: str, full: str) -> list[str]:
        created = []
        directory = os.path.dirname(full)
        missing = []
        while directory != project_dir and not os.path.isdir(directory):
            missing.append(directory)
            directory = os.path.dirname(directory)
        for directory in reversed(missing):
            try:
                os.mkdir(directory)
            except OSError as error:
                for made in reversed(created):
                    with contextlib.suppress(OSError):
                        os.rmdir(made)
                raise Conflict(f"cannot create the folder for {full!r}: {error.strerror}", code="path_conflict") from error
            created.append(directory)
        return created

    def _apply_put(self, project, project_dir, path, staged: Staged, device, now, message, undo) -> dict:
        row = self._row(project, path)
        if row is not None and not row["deleted"] and row["sha256"] == staged.sha256:
            # A save that changes nothing costs nothing: no new version, no new blob.
            return {**self._info(row), "op": "put", "unchanged": True}
        self._ensure_blob_from(staged)
        st = self._write_current(project, project_dir, path, staged.sha256, undo)
        version = (row["version"] + 1) if row is not None else 1
        part_id = staged.part_id if native.looks_native(path) else None
        self._upsert_live(project, path, version, staged.sha256, staged.size, st.st_mtime_ns, now, device, part_id)
        self._record_version(project, path, version, staged.sha256, staged.size, now, device, "put", message=message)
        self._record_change(project, path, "put", version, device, now)
        return {**self._info(self._row(project, path)), "op": "put", "unchanged": False}

    def _ensure_blob_from(self, staged: Staged) -> None:
        blob = self._blob_path(staged.sha256)
        if os.path.exists(blob):
            return
        os.makedirs(os.path.dirname(blob), exist_ok=True)
        try:
            os.link(staged.path, blob)  # the upload / staging file is unlinked later; the blob keeps the bytes
        except OSError:
            self._ensure_blob(staged.path, staged.sha256)

    def _upsert_live(self, project, path, version, sha, size, mtime_ns, now, device, part_id) -> None:
        self.db.execute(
            "INSERT INTO files (project, path, version, sha256, size, mtime_ns, deleted, modified_at, modified_by, part_id, deleted_at, moved_to) "
            "VALUES (?,?,?,?,?,?,0,?,?,?,NULL,NULL) "
            "ON CONFLICT(project, path) DO UPDATE SET version = excluded.version, sha256 = excluded.sha256, size = excluded.size, "
            "mtime_ns = excluded.mtime_ns, deleted = 0, modified_at = excluded.modified_at, modified_by = excluded.modified_by, "
            "part_id = excluded.part_id, deleted_at = NULL, moved_to = NULL",
            (project, path, version, sha, size, mtime_ns, now, device, part_id),
        )

    def _remove_current(self, project_dir: str, path: str, sha: str, undo: list) -> None:
        full = self._file_path(project_dir, path)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(full)

        def restore() -> None:
            os.makedirs(os.path.dirname(full), exist_ok=True)
            backup = self.new_tmp_path()
            shutil.copyfile(self._blob_path(sha), backup)
            os.replace(backup, full)

        undo.append(restore)
        directory = os.path.dirname(full)
        while directory != project_dir:
            try:
                os.rmdir(directory)
            except OSError:
                break
            directory = os.path.dirname(directory)

    def _mark_deleted(self, project, path, version, now, device, moved_to=None) -> None:
        self.db.execute(
            "UPDATE files SET version = ?, sha256 = NULL, size = 0, deleted = 1, deleted_at = ?, modified_at = ?, modified_by = ?, "
            "part_id = NULL, moved_to = ? WHERE project = ? AND path = ?",
            (version, now, now, device, moved_to, project, path),
        )

    def _apply_delete(self, project, project_dir, path, device, now, message, undo) -> dict:
        row = self._row(project, path)
        self._remove_current(project_dir, path, row["sha256"], undo)
        version = row["version"] + 1
        self._mark_deleted(project, path, version, now, device)
        self._record_version(project, path, version, None, 0, now, device, "delete", message=message)
        self._record_change(project, path, "delete", version, device, now)
        return {"path": path, "op": "delete", "version": version, "deleted": True, "modified_at": iso(now), "modified_by": device}

    def _apply_move(self, project, project_dir, path, to, device, now, message, undo) -> list[dict]:
        row = self._row(project, path)
        target = self._row(project, to)
        sha, size, part_id = row["sha256"], row["size"], row["part_id"]
        st = self._write_current(project, project_dir, to, sha, undo)
        self._remove_current(project_dir, path, sha, undo)
        new_version = (target["version"] + 1) if target is not None else 1
        self._upsert_live(project, to, new_version, sha, size, st.st_mtime_ns, now, device, part_id)
        self._record_version(project, to, new_version, sha, size, now, device, "move", moved_from=path, message=message)
        self._record_change(project, to, "put", new_version, device, now, moved_from=path)
        old_version = row["version"] + 1
        self._mark_deleted(project, path, old_version, now, device, moved_to=to)
        self._record_version(project, path, old_version, None, 0, now, device, "delete", moved_to=to, message=message)
        self._record_change(project, path, "delete", old_version, device, now, moved_to=to)
        return [
            {"path": path, "op": "delete", "version": old_version, "deleted": True, "moved_to": to, "modified_at": iso(now), "modified_by": device},
            {**self._info(self._row(project, to)), "op": "move", "moved_from": path, "unchanged": False},
        ]

    # ------------------------------------------------------------ retention

    def _prune_paths(self, project: str, paths: set[str], now: float) -> None:
        for path in paths:
            self._prune_file(project, path, now)

    def _prune_file(self, project: str, path: str, now: float) -> None:
        """Keep the last KEEP_LAST_VERSIONS versions and everything younger than KEEP_DAYS, whichever keeps more. A deleted
        file keeps its versions KEEP_DAYS after the delete; then only the delete's own record (the counter) stays, so a stale
        copy's version can never match a file created later."""
        horizon = now - KEEP_DAYS * 86400
        row = self._row(project, path)
        rows = self.db.execute(
            "SELECT version, at, op FROM versions WHERE project = ? AND path = ? ORDER BY version DESC", (project, path)
        ).fetchall()
        if row is not None and row["deleted"]:
            drop = [] if row["deleted_at"] >= horizon else [r["version"] for r in rows if r["version"] != row["version"]]
        else:
            drop = [r["version"] for index, r in enumerate(rows) if index >= KEEP_LAST_VERSIONS and r["at"] < horizon]
        if drop:
            self._pruned = True
            self.db.executemany(
                "DELETE FROM versions WHERE project = ? AND path = ? AND version = ?", [(project, path, v) for v in drop]
            )

    def prune(self) -> None:
        """Apply the retention rule to every file now (writes apply it to the files they touch)."""
        with self.lock:
            now = self.clock()
            with self._transaction():
                for row in self.db.execute("SELECT DISTINCT project, path FROM versions").fetchall():
                    self._prune_file(row["project"], row["path"], now)
            self.gc_blobs()

    def sweep(self) -> None:
        with self.lock:
            self._last_sweep = self.clock()
            self.prune()
            self.sweep_uploads()

    def _maybe_sweep(self) -> None:
        if self.clock() - self._last_sweep >= SWEEP_INTERVAL_SECONDS:
            self.sweep()

    def gc_blobs(self) -> None:
        """Delete blobs no kept version refers to."""
        referenced = {r[0] for r in self.db.execute("SELECT DISTINCT sha256 FROM versions WHERE sha256 IS NOT NULL")}
        for prefix in os.listdir(self.blob_dir):
            directory = os.path.join(self.blob_dir, prefix)
            if not os.path.isdir(directory):
                continue
            for name in os.listdir(directory):
                if prefix + name not in referenced:
                    with contextlib.suppress(OSError):
                        os.unlink(os.path.join(directory, name))
            with contextlib.suppress(OSError):
                os.rmdir(directory)
