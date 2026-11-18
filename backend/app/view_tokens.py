"""Read-only view tokens for live-session observers (docs/live-sessions-scope.md, section 5; decision LS-3).

A presenter (who holds the API key and a document session) mints a token bound to that session and one root Part; the session
hub hands it to observers, who send it as `X-View-Token` with NO API key. `app.auth.verify_access` lets such a request through only
for a GET on the allowlist below, and binds the request to the token's session (an observer never learns the session id).

Held in memory only, like the documents themselves: a backend restart loses both, which is right (the session they point at is
gone too). At most `MAX_TOKENS_PER_SESSION` live tokens per session (minting another revokes the oldest) and `MAX_TOKENS` in all.
"""

import re
import secrets
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Callable

HEADER = "X-View-Token"
DEFAULT_TTL_S = 12 * 3600
MAX_TTL_S = 12 * 3600
MIN_TTL_S = 60
MAX_TOKENS_PER_SESSION = 4
MAX_TOKENS = 512

# GET only, and only these paths (the whole path, after any root_path). Nothing that returns a file, a file path or the parametric
# model: section 7 of the scope says why `/parts/{id}`, `/occurrences` and every `/export/*` route are left out.
ALLOWED_GET_PATHS = (
    re.compile(r"^/document/parts/[^/]+/assembly-mesh\.glb$"),
    re.compile(r"^/document/view-state$"),
)


@dataclass(frozen=True)
class ViewToken:
    token: str
    session_id: str
    root_part_id: str
    created_at: float
    expires_at: float


_lock = threading.Lock()
_tokens: "OrderedDict[str, ViewToken]" = OrderedDict()
_clock: Callable[[], float] = time.time


def set_clock(clock: Callable[[], float]) -> None:
    """Tests only: a settable clock."""
    global _clock
    _clock = clock


def reset() -> None:
    """Tests only: forget every token and restore the real clock."""
    global _clock
    with _lock:
        _tokens.clear()
    _clock = time.time


def path_allowed(method: str, path: str) -> bool:
    return method == "GET" and any(rx.match(path) for rx in ALLOWED_GET_PATHS)


def mint(session_id: str, root_part_id: str, ttl_s: int | None = None) -> ViewToken:
    ttl = DEFAULT_TTL_S if ttl_s is None else max(MIN_TTL_S, min(int(ttl_s), MAX_TTL_S))
    now = _clock()
    record = ViewToken(
        token=secrets.token_urlsafe(32),
        session_id=session_id,
        root_part_id=root_part_id,
        created_at=now,
        expires_at=now + ttl,
    )
    with _lock:
        _sweep_locked(now)
        mine = [t for t in _tokens.values() if t.session_id == session_id]
        while len(mine) >= MAX_TOKENS_PER_SESSION:
            oldest = mine.pop(0)
            _tokens.pop(oldest.token, None)
        _tokens[record.token] = record
        while len(_tokens) > MAX_TOKENS:
            _tokens.popitem(last=False)
    return record


def lookup(token: str | None) -> ViewToken | None:
    """The live token, or None (unknown, revoked or expired)."""
    if not token:
        return None
    now = _clock()
    with _lock:
        record = _tokens.get(token)
        if record is None:
            return None
        if record.expires_at <= now:
            _tokens.pop(token, None)
            return None
        return record


def revoke(token: str, session_id: str) -> bool:
    """Revokes `token` if it belongs to `session_id` (a presenter can only end its own). True if one was removed."""
    with _lock:
        record = _tokens.get(token)
        if record is None or record.session_id != session_id:
            return False
        del _tokens[token]
        return True


def _sweep_locked(now: float) -> None:
    for key in [k for k, t in _tokens.items() if t.expires_at <= now]:
        del _tokens[key]
