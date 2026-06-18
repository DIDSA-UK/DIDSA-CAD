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

from fastapi import HTTPException, Security, status
from fastapi.security import APIKeyHeader

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
