"""Entry point: `uvicorn app.main:app`. Refuses to start without PROJECT_STORE_API_KEY and PROJECT_STORE_ROOT, so it never comes up
unauthenticated or writing somewhere nobody chose. ONE worker only: writes are serialised by a lock inside the process (README.md)."""

import os

from app.api import create_app
from app.auth import load_api_key
from app.store import Store

ROOT_ENV_VAR = "PROJECT_STORE_ROOT"
MAX_FILE_ENV_VAR = "PROJECT_STORE_MAX_FILE_MB"


def build_from_env():
    api_key = load_api_key()
    root = os.environ.get(ROOT_ENV_VAR)
    if not root:
        raise RuntimeError(
            f"{ROOT_ENV_VAR} environment variable is not set. Refusing to start without a folder to keep projects in - see README.md."
        )
    os.makedirs(root, exist_ok=True)
    max_mb = int(os.environ.get(MAX_FILE_ENV_VAR, "200"))
    return create_app(Store(root, max_file_bytes=max_mb * 1024 * 1024), api_key)


app = build_from_env()
