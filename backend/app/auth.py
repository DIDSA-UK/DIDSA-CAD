"""Single-shared-static-API-key auth for the FastAPI app.

This is deliberately the simplest thing that works for a personal/hobby
deployment behind a Cloudflare Tunnel: one key, read from the environment,
checked on every request. It is not a multi-user auth system - see
README.md for the explicit list of what this does not provide (rate
limiting, per-client revocation, rotation, etc).

The key is read once at import time so a missing CAD_API_KEY fails the
app at startup rather than letting it come up unauthenticated.
"""

import os
import secrets

from fastapi import HTTPException, Request, Security, status
from fastapi.security import APIKeyHeader

from app import view_tokens

_API_KEY_ENV_VAR = "CAD_API_KEY"

_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def _load_api_key() -> str:
    api_key = os.environ.get(_API_KEY_ENV_VAR)
    if not api_key:
        raise RuntimeError(
            f"{_API_KEY_ENV_VAR} environment variable is not set. Refusing to "
            "start without an API key configured, rather than silently "
            "running unauthenticated - see README.md for how to set it."
        )
    return api_key


_EXPECTED_API_KEY = _load_api_key()


def verify_api_key(provided_key: str | None = Security(_api_key_header)) -> None:
    if provided_key is None or not secrets.compare_digest(provided_key, _EXPECTED_API_KEY):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid API key.",
        )


def key_is_valid(provided_key: str | None) -> bool:
    return provided_key is not None and secrets.compare_digest(provided_key, _EXPECTED_API_KEY)


def verify_access(request: Request) -> None:
    """The app-level gate (`app.main`): the API key, as `verify_api_key`, OR a live-session view token
    (`app.view_tokens`, docs/live-sessions-scope.md section 5) on an allowlisted GET.

    A request with a valid key is the key's: any token on it is ignored. A token request binds the token's document session in
    `request.state.view_token_session` (read by `app.session_context.bind_session_id`, which would otherwise take the session from
    `X-Document-Session`), so an observer reads only the presenter's document and never learns its session id. Anything else is
    401: an invalid or expired token says `view_token_invalid` so the observer knows to ask the session hub for a fresh one; a valid
    token on a route outside the allowlist says `view_token_not_allowed`."""
    if key_is_valid(request.headers.get("X-API-Key")):
        return
    token = request.headers.get(view_tokens.HEADER)
    if token is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing or invalid API key.")
    record = view_tokens.lookup(token)
    if record is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="view_token_invalid")
    if not view_tokens.path_allowed(request.method, request.url.path):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="view_token_not_allowed")
    request.state.view_token_session = record.session_id
    request.state.view_token = record
