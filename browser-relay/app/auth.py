"""Single-shared-static-API-key auth for the browser relay's WebSocket
endpoint, matching backend/app/auth.py's convention deliberately - same
"simplest thing that works for a personal/hobby deployment" posture, same
fail-fast-at-startup-if-unset behaviour, same constant-time comparison.

This is a *separate* key (BROWSER_RELAY_API_KEY, not CAD_API_KEY) rather
than reusing the CAD backend's, even though both currently live on the same
Cloudflare Tunnel host: this service proxies to a live Chromium tab, a
materially different (and larger) blast radius than the OCCT backend if a
key ever leaked, so the two are not tied together.

FastAPI's APIKeyHeader dependency (used by backend/app/auth.py) is built
for HTTP routes and doesn't apply cleanly to a WebSocket endpoint, so this
checks the header directly off the WebSocket's own header dict instead -
same header name, same comparison, no HTTP-only machinery involved.
"""

import os
import secrets

_API_KEY_ENV_VAR = "BROWSER_RELAY_API_KEY"
_HEADER_NAME = "x-api-key"


def _load_api_key() -> str:
    api_key = os.environ.get(_API_KEY_ENV_VAR)
    if not api_key:
        raise RuntimeError(
            f"{_API_KEY_ENV_VAR} environment variable is not set. Refusing "
            "to start without an API key configured, rather than silently "
            "running unauthenticated - see README.md for how to set it."
        )
    return api_key


_EXPECTED_API_KEY = _load_api_key()


def is_authorized(headers) -> bool:
    """headers: any mapping-like object with a case-insensitive .get(), such
    as Starlette's WebSocket.headers - checked directly against the header
    dict rather than via a FastAPI Security dependency (see module
    docstring)."""
    provided_key = headers.get(_HEADER_NAME)
    return provided_key is not None and secrets.compare_digest(provided_key, _EXPECTED_API_KEY)
