"""The observers' glb cache (docs/live-sessions-scope.md, section 5): per document session, the last few encoded
`assembly-mesh.glb` responses keyed by the document revision, the Part and the query, so N observers fetching after one edit cost
one encode on the Pi. Only view-token requests use it (`router.get_assembly_mesh_glb`): the presenter's own requests are computed
as before, so a revision bump the backend missed could never show the presenter a stale model."""

import hashlib
import threading
from collections import OrderedDict

MAX_ENTRIES_PER_SESSION = 4
MAX_BYTES = 64 * 1024 * 1024

_lock = threading.Lock()
_entries: "OrderedDict[tuple, bytes]" = OrderedDict()
_bytes = 0


def _query_hash(part_id: str, query: str) -> str:
    canonical = "&".join(sorted(query.split("&"))) if query else ""
    return hashlib.sha256(f"{part_id}?{canonical}".encode()).hexdigest()[:16]


def key(session_id: str, rev: int, part_id: str, query: str) -> tuple:
    return (session_id, rev, _query_hash(part_id, query))


def etag(rev: int, part_id: str, query: str) -> str:
    return f'"{rev}-{_query_hash(part_id, query)}"'


def get(cache_key: tuple) -> bytes | None:
    with _lock:
        data = _entries.get(cache_key)
        if data is not None:
            _entries.move_to_end(cache_key)
        return data


def put(cache_key: tuple, data: bytes) -> None:
    global _bytes
    if len(data) > MAX_BYTES:
        return
    with _lock:
        if cache_key in _entries:
            return
        session_id, rev, _ = cache_key
        # An older revision of the same session is never asked for again (observers fetch the current one): drop it.
        for old in [k for k in _entries if k[0] == session_id and k[1] < rev]:
            _bytes -= len(_entries.pop(old))
        _entries[cache_key] = data
        _bytes += len(data)
        mine = [k for k in _entries if k[0] == session_id]
        while len(mine) > MAX_ENTRIES_PER_SESSION:
            _bytes -= len(_entries.pop(mine.pop(0)))
        while _bytes > MAX_BYTES and _entries:
            _, dropped = _entries.popitem(last=False)
            _bytes -= len(dropped)


def reset() -> None:
    """Tests only."""
    global _bytes
    with _lock:
        _entries.clear()
        _bytes = 0
