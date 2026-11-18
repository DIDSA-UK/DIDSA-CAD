"""The hub's key (SESSION_HUB_API_KEY, decision LS-1): the same single-shared-static-key posture as backend/app/auth.py, the browser
relay and the project store, and deliberately a different key from all three, so a device can be given the right to host a
session without the backend's key. Only a presenter needs it (on the WebSocket handshake, `X-API-Key`); observers join with a
code alone. `/health` needs it too, for the reason backend/app/main.py gives (a tunnel makes the hub internet-reachable)."""

import os
import secrets

API_KEY_ENV_VAR = "SESSION_HUB_API_KEY"


def load_api_key() -> str:
    api_key = os.environ.get(API_KEY_ENV_VAR)
    if not api_key:
        raise RuntimeError(
            f"{API_KEY_ENV_VAR} environment variable is not set. Refusing to start without an API key configured, "
            "rather than silently running unauthenticated - see README.md for how to set it."
        )
    return api_key


def key_matches(provided: str | None, expected: str) -> bool:
    return provided is not None and secrets.compare_digest(provided.encode(), expected.encode())
