"""Entry point: `uvicorn app.main:app --workers 1`. Refuses to start without SESSION_HUB_API_KEY. ONE worker only: rooms live in
this process's memory (a restart ends every session; clients say so and the presenter hosts again)."""

import logging
import os

from app.api import create_app
from app.auth import load_api_key
from app.hub import Hub, Limits

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


def build_from_env():
    api_key = load_api_key()
    limits = Limits(
        max_rooms=int(os.environ.get("SESSION_HUB_MAX_ROOMS", "16")),
        max_participants=int(os.environ.get("SESSION_HUB_MAX_PARTICIPANTS", "7")),
    )
    return create_app(Hub(limits=limits, public_url=os.environ.get("SESSION_HUB_PUBLIC_URL", "").strip()), api_key)


app = build_from_env()
