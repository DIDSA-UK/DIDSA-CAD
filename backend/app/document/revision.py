"""The document revision (docs/live-sessions-scope.md, section 5): an integer per document session that only goes up, bumped by
every request that changes the document (and by a background job that adds its Feature). Every response carries it as
`X-Document-Revision` (`app.session_hooks`), so a presenter learns it from the request it just made; observers compare it with
the revision they loaded to know when to refetch the glb.

A missed bump would show an observer stale geometry; a spare bump only costs a 304. So `app.session_hooks` bumps on every non-GET
that answers 2xx except a short list of routes known not to change the document.
"""

import threading
from collections import OrderedDict

_MAX_SESSIONS = 1000  # small ints; bounded like the documents (store.py keeps 200), with room to spare

_lock = threading.Lock()
_revisions: "OrderedDict[str, int]" = OrderedDict()


def current(session_id: str) -> int:
    """The session's revision; 1 for a session nothing has changed yet."""
    with _lock:
        return _revisions.get(session_id, 1)


def bump(session_id: str) -> int:
    with _lock:
        value = _revisions.get(session_id, 1) + 1
        _revisions[session_id] = value
        _revisions.move_to_end(session_id)
        while len(_revisions) > _MAX_SESSIONS:
            _revisions.popitem(last=False)
        return value


def reset() -> None:
    """Tests only."""
    with _lock:
        _revisions.clear()
