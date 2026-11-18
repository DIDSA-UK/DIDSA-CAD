"""Live-session plumbing around every request (docs/live-sessions-scope.md, section 5), as a plain ASGI middleware:

1. **The document revision header.** Every `/document` and `/sketch` response carries `X-Document-Revision` for its session; a
   non-GET that answers 2xx bumps it first (unless its path is one known not to change the document, `_NON_MUTATING`).
2. **One writer or one observer read at a time, per session.** Before live sessions a document session had one client, which sends
   one request at a time. An observer's glb GET (a view token, `app.view_tokens`) is the first request that can run while the
   presenter's edit is mutating the same `Document` in another worker thread. So a token GET and every non-GET of the same session
   take that session's lock; the presenter's own GETs do not (unchanged behaviour), nor does a job cancel (it must reach a running
   request). Known gap: a background job (`app.document.jobs`) adds its Feature from its own thread, outside any request; it bumps
   the revision when it does, but does not take this lock.

Pure ASGI rather than `BaseHTTPMiddleware`, so the response is not buffered and contextvars behave as in a plain app.
"""

import asyncio
import re

from app import auth, view_tokens
from app.document import revision
from app.session_context import DEFAULT_SESSION_ID

REVISION_HEADER = b"x-document-revision"

# Non-GET routes that never change the document: a spare bump only costs observers a 304, a missed one shows stale geometry, so
# only routes whose name says "preview" / "measure" / "probe" / "validate" / "cancel" are left out, and minting / revoking a view
# token (it changes who may read, not the document).
_NON_MUTATING = re.compile(r"(preview|/measure$|/import/probe$|/ai-plan/validate$|/jobs/[^/]+/cancel$|^/document/view-tokens)")
_TRACKED_PREFIXES = ("/document", "/sketch")

_locks: dict[tuple[int, str], asyncio.Lock] = {}


def _lock_for(session_id: str) -> asyncio.Lock:
    # Keyed by the running loop too: uvicorn has one loop, but a test client may run each request on its own, and an asyncio.Lock
    # that has had a waiter belongs to the loop it was made on.
    key = (id(asyncio.get_running_loop()), session_id)
    lock = _locks.get(key)
    if lock is None:
        lock = _locks[key] = asyncio.Lock()
        if len(_locks) > 1000:  # bounded like the revision table; an idle session's lock is cheap to make again
            for key in list(_locks)[:200]:
                if not _locks[key].locked():
                    del _locks[key]
    return lock


def _header(scope, name: bytes) -> str | None:
    for key, value in scope.get("headers", []):
        if key == name:
            return value.decode("latin-1")
    return None


class SessionHooks:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not scope.get("path", "").startswith(_TRACKED_PREFIXES):
            await self.app(scope, receive, send)
            return
        method = scope.get("method", "GET")
        path = scope.get("path", "")
        has_key = auth.key_is_valid(_header(scope, b"x-api-key"))
        session_id = _header(scope, b"x-document-session") or DEFAULT_SESSION_ID
        token_request = False
        if not has_key:
            record = view_tokens.lookup(_header(scope, b"x-view-token"))
            if record is not None:
                session_id = record.session_id
                token_request = True
        mutating = method not in ("GET", "HEAD", "OPTIONS") and not _NON_MUTATING.search(path)

        async def send_with_revision(message):
            if message["type"] == "http.response.start":
                status = message.get("status", 500)
                if has_key and mutating and 200 <= status < 300:
                    rev = revision.bump(session_id)
                else:
                    rev = revision.current(session_id)
                headers = list(message.get("headers", []))
                headers.append((REVISION_HEADER, str(rev).encode()))
                message = {**message, "headers": headers}
            await send(message)

        serialise = token_request or (has_key and method not in ("GET", "HEAD", "OPTIONS") and not path.endswith("/cancel"))
        if serialise:
            async with _lock_for(session_id):
                await self.app(scope, receive, send_with_revision)
        else:
            await self.app(scope, receive, send_with_revision)
