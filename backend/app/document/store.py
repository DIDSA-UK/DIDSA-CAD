import threading
from collections import OrderedDict

from fastapi import HTTPException

from app.document import body_cache
from app.document.models import Document, Part, SketchFeature
from app.session_context import get_current_session_id

# Per-session in-memory store (still a stopgap - no real persistence - but
# no longer a single instance shared by every connection to the backend).
# Bug history: this used to be one bare `_document = Document(id="default")`
# module global, mutated in place by every request regardless of which
# client/tab/device sent it - see app.session_context's docstring for the
# full data-loss story. Keyed by session id instead, one Document per
# session, so concurrent sessions can never see or clobber each other's
# state.
#
# `_MAX_SESSIONS` is a bound on worst-case memory growth from sessions that
# connect once and never come back (a stray client, a test run) - an
# OrderedDict used as a simple LRU, oldest session evicted once the cap is
# exceeded. Not a correctness mechanism for any *active* session: a real
# deployment is expected to have a small handful of concurrent sessions at
# once, nowhere near this cap.
_MAX_SESSIONS = 200

_lock = threading.Lock()
_documents: "OrderedDict[str, Document]" = OrderedDict()


def get_document() -> Document:
    session_id = get_current_session_id()
    with _lock:
        document = _documents.get(session_id)
        if document is None:
            document = Document(id="default")
            _documents[session_id] = document
        _documents.move_to_end(session_id)
        _evict_oldest_locked()
        return document


def replace_document(document: Document) -> None:
    """Native file import's "full replace, not merge" (client-owned files,
    locked-in scope): swaps out the whole in-memory Document for `document`,
    for the current request's session only. Only intended to be called by
    `app.document.router`'s native-import endpoint, immediately followed by
    `app.sketch.store.replace_all_sketches` doing the same for the Sketch
    side - together they make an import a clean, atomic full replacement
    rather than a merge with whatever Document/Sketches were open before,
    scoped to this one session.

    On-device feedback (herringbone/complex-gear timeout investigation):
    also drops every cached `compute_part_bodies` checkpoint chain (`app.
    document.body_cache.clear`) - the incoming `document`'s Parts can reuse
    ids a stale cache entry still references with completely different
    content, and there's no cheaper per-part signal available here to tell
    which entries are actually still valid. `body_cache` is keyed by Part
    id (a fresh uuid4 per Part, never reused across sessions in practice),
    so clearing it globally rather than per-session is harmless - it just
    means an import in one session can force a cache rebuild for another
    session's unrelated Part in the vanishingly unlikely event of a uuid4
    collision."""
    session_id = get_current_session_id()
    with _lock:
        _documents[session_id] = document
        _documents.move_to_end(session_id)
        _evict_oldest_locked()
    body_cache.clear()


def _evict_oldest_locked() -> None:
    """Caller must hold `_lock`. Bounds `_documents` to `_MAX_SESSIONS`
    entries, evicting the least-recently-used session first."""
    while len(_documents) > _MAX_SESSIONS:
        _documents.popitem(last=False)


def get_part_or_404(part_id: str) -> Part:
    part = get_document().parts.get(part_id)
    if part is None:
        raise HTTPException(status_code=404, detail="Part not found")
    return part


def is_sketch_locked(sketch_id: str) -> bool:
    """True if `sketch_id` belongs to a SketchFeature that is locked (not
    the last Feature in its Part). Sketches not wrapped by any Feature at
    all (e.g. created directly via the sketch router rather than through a
    Part) are never locked - this only ever returns True for a sketch that
    is genuinely behind a later Feature."""
    for part in get_document().parts.values():
        for feature in part.features:
            if isinstance(feature, SketchFeature) and feature.sketch_id == sketch_id:
                return part.is_locked(feature.id)
    return False
