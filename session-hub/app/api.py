"""The hub's transport: FastAPI with `GET /health` (the key) and the WebSocket `/ws` (docs/live-sessions-scope.md, section 6).

Each socket gets a `WsConnection`: the hub (`app/hub.py`) queues messages on it without awaiting, and one sender task per socket
writes them out. The queue is **latest-wins** per key (presence per sender, each piece of presenter state, and `poses`, whose
queued deltas are merged), so a slow phone gets the newest state rather than a backlog; voice frames older than `VOICE_MAX_AGE_S`
when their turn comes are dropped.
"""

import asyncio
import contextlib
import json
import logging
from collections import OrderedDict
from typing import Callable

from fastapi import Depends, FastAPI, HTTPException, Security, WebSocket, WebSocketDisconnect, status
from fastapi.security import APIKeyHeader

from app.auth import key_matches
from app.hub import PROTO, Hub

log = logging.getLogger("session_hub")

VOICE_MAX_AGE_S = 0.2
CLOSE_GRACE_S = 0.15  # between the last message and the close frame: a client that processes both in one read (Godot's WebSocketPeer) drops the message, so it is given a moment to read it first
MAX_QUEUE = 512  # unkeyed messages queued for one receiver before it is treated as gone

API_FEATURES = ["rooms", "resume", "snapshot", "voice_relay", "marks"]

_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


class WsConnection:
    def __init__(self, websocket: WebSocket, clock: Callable[[], float]):
        self.websocket = websocket
        self.remote = websocket.client.host if websocket.client else "?"
        self._clock = clock
        self._queue: "OrderedDict[object, tuple]" = OrderedDict()
        self._serial = 0
        self._wake = asyncio.Event()
        self._close_code: int | None = None
        self._close_reason = ""

    # Called by the hub (never awaits).
    def send(self, message: dict, key=None, merge=None) -> None:
        if self._close_code is not None:
            return
        if key is None:
            self._serial += 1
            key = ("_", self._serial)
            if len(self._queue) >= MAX_QUEUE:
                self.close(1013)
                return
        elif key in self._queue and merge is not None:
            message = merge(self._queue[key][1], message)
        if key in self._queue:
            self._queue.pop(key)  # the newer value goes to the back, in order with what came after the old one
        self._queue[key] = ("json", message)
        self._wake.set()

    def send_voice(self, frame: bytes, at: float) -> None:
        if self._close_code is not None:
            return
        self._serial += 1
        self._queue[("voice", self._serial)] = ("voice", frame, at)
        self._wake.set()

    def close(self, code: int = 1000, reason: str = "") -> None:
        if self._close_code is None:
            self._close_code = code
            self._close_reason = reason[:100]
            self._wake.set()

    @property
    def closing(self) -> bool:
        return self._close_code is not None

    async def pump(self) -> None:
        """Writes the queue out until the hub closes this connection (what is queued is sent first) or the socket fails."""
        try:
            while True:
                await self._wake.wait()
                self._wake.clear()
                sent_something = False
                while self._queue:
                    _key, item = self._queue.popitem(last=False)
                    sent_something = True
                    if item[0] == "json":
                        await self.websocket.send_text(json.dumps(item[1], separators=(",", ":")))
                    elif self._clock() - item[2] <= VOICE_MAX_AGE_S:
                        await self.websocket.send_bytes(item[1])
                if self._close_code is not None:
                    if sent_something:
                        await asyncio.sleep(CLOSE_GRACE_S)
                    with contextlib.suppress(Exception):
                        await self.websocket.close(code=self._close_code, reason=self._close_reason)
                    return
        except Exception:  # noqa: BLE001 - a dead socket; the receive loop sees it too
            return


def create_app(hub: Hub, api_key: str, tick_s: float = 1.0) -> FastAPI:
    def verify_api_key(provided: str | None = Security(_api_key_header)) -> None:
        if not key_matches(provided, api_key):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing or invalid API key.")

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        async def ticker():
            while True:
                await asyncio.sleep(tick_s)
                hub.tick()

        task = asyncio.create_task(ticker())
        try:
            yield
        finally:
            task.cancel()

    app = FastAPI(lifespan=lifespan)

    @app.get("/health", dependencies=[Depends(verify_api_key)])
    def health() -> dict:
        return {"status": "ok", "proto": PROTO, "api_features": API_FEATURES, **hub.stats()}

    @app.websocket("/ws")
    async def ws(websocket: WebSocket) -> None:
        provided = websocket.headers.get("x-api-key")
        if provided is not None and not key_matches(provided, api_key):
            await websocket.close(code=4401)  # before accepting: a wrong key is refused at the handshake
            return
        await websocket.accept()
        conn = WsConnection(websocket, hub.clock)
        hub.on_open(conn, has_key=provided is not None)
        sender = asyncio.create_task(conn.pump())
        try:
            while not conn.closing:
                message = await websocket.receive()
                if message["type"] == "websocket.disconnect":
                    break
                if message.get("text") is not None:
                    hub.on_text(conn, message["text"])
                elif message.get("bytes") is not None:
                    hub.on_bytes(conn, message["bytes"])
        except WebSocketDisconnect:
            pass
        finally:
            hub.on_close(conn)
            conn.close(1000)
            with contextlib.suppress(Exception):
                await asyncio.wait_for(sender, timeout=2.0)
            sender.cancel()

    return app
