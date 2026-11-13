"""Single-shared-static-API-key auth, the same posture as backend/app/auth.py and browser-relay/app/auth.py: one key from the
environment, a constant-time comparison, and a refusal to start without it.

A *separate* key (PROJECT_STORE_API_KEY, not CAD_API_KEY): the store holds the only server copy of every project, so a leaked
store key is a different (and bigger) risk than a leaked geometry key, and a device that should read and write projects can be
given this key without the backend's, and the other way round (docs/shared-storage-scope.md, section 4).

Every route requires it, /health included, for the reason backend/app/main.py gives: a Cloudflare Tunnel makes this container
internet-reachable, so an open endpoint would let any scanner confirm the server is up.
"""

import os
import secrets

from fastapi import HTTPException, Security, status
from fastapi.security import APIKeyHeader

API_KEY_ENV_VAR = "PROJECT_STORE_API_KEY"

_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def load_api_key() -> str:
    api_key = os.environ.get(API_KEY_ENV_VAR)
    if not api_key:
        raise RuntimeError(
            f"{API_KEY_ENV_VAR} environment variable is not set. Refusing to start without an API key configured, "
            "rather than silently running unauthenticated - see README.md for how to set it."
        )
    return api_key


def make_verifier(expected_key: str):
    def verify_api_key(provided_key: str | None = Security(_api_key_header)) -> None:
        if provided_key is None or not secrets.compare_digest(provided_key.encode(), expected_key.encode()):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing or invalid API key.")

    return verify_api_key
