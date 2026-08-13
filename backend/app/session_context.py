"""Per-request document-session identity.

The root cause of the "save gets stuck on the first file" data-loss bug:
`app.document.store`/`app.sketch.store` used to be a single global,
unscoped Document/Sketch-dict shared by every connection to the backend.
Two tabs, two devices, or the app being reopened while a previous instance
was still connected all read and wrote the exact same in-memory state, so
whichever one last touched it "won" - including on export/Save, which is
how a Save could silently write out a *different* device's model.

This module gives every request an identity (`current_session_id`) so the
stores below can keep one Document/Sketch-set per session instead of one
for the whole process. The identity is carried via the `X-Document-Session`
header, set once per app-launch by the client (see
`client/lib/config.dart`) - not tied to the API key, since the API key is
deliberately one shared secret for every client (see `app/auth.py`), while
session id is exactly the thing that must NOT be shared.

A request with no header at all (an older client, a stray `curl`, a test
that doesn't care about isolation) falls back to a fixed default id -
single-session behaviour, same as before this fix, rather than a hard
error - there is no security property riding on the session id, only data
isolation.
"""

import contextvars

from fastapi import Header

DEFAULT_SESSION_ID = "default"

_current_session_id: contextvars.ContextVar[str] = contextvars.ContextVar(
    "current_session_id", default=DEFAULT_SESSION_ID
)


def get_current_session_id() -> str:
    return _current_session_id.get()


def set_current_session_id(session_id: str | None) -> None:
    _current_session_id.set(session_id or DEFAULT_SESSION_ID)


async def bind_session_id(
    x_document_session: str | None = Header(default=None, alias="X-Document-Session"),
) -> None:
    """FastAPI dependency: binds the current request's session id from the
    `X-Document-Session` header for the remainder of this request.

    Declared `async def` (not a plain `def`) so FastAPI runs it directly on
    the event loop rather than off in a threadpool worker thread - a plain
    `def` dependency would set the contextvar in a thread whose context
    copy never makes it back to the one the path operation function itself
    (also threadpooled, but as a *separate* copy taken from this same
    request's async context) actually runs in. Running here, before that
    handoff, means the mutation is visible everywhere downstream.
    """
    set_current_session_id(x_document_session)
