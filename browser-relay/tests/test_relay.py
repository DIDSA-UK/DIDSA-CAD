"""Exercises app/main.py's _pump() - the actual "dumb relay" logic this
service exists for - against two fake in-process sockets shaped like
Starlette's WebSocket and the `websockets` client respectively. This is
deliberately the level this service's own tests can reach without a real
Chromium binary (see browser-relay/README.md): the two socket shapes are
faked exactly, but nothing about CDP itself is - _pump() never looks at
message content, so a fake string is exactly as good a test as a real CDP
frame would be for this function specifically.
"""

import asyncio

import pytest
from fastapi import WebSocketDisconnect
from websockets.exceptions import ConnectionClosed

from app.main import _pump


class _FakeStarletteSocket:
    """Mimics the two Starlette WebSocket methods _pump() calls."""

    def __init__(self, incoming: list[str] | None = None) -> None:
        self._incoming = list(incoming or [])
        self.sent: list[str] = []

    async def receive_text(self) -> str:
        if not self._incoming:
            raise WebSocketDisconnect()
        return self._incoming.pop(0)

    async def send_text(self, message: str) -> None:
        self.sent.append(message)


class _FakeChromeSocket:
    """Mimics the two `websockets` client methods _pump() calls."""

    def __init__(self, incoming: list[str] | None = None) -> None:
        self._incoming = list(incoming or [])
        self.sent: list[str] = []

    async def recv(self) -> str:
        if not self._incoming:
            raise ConnectionClosed(None, None)
        return self._incoming.pop(0)

    async def send(self, message: str) -> None:
        self.sent.append(message)


def test_pumps_client_frames_to_chrome_until_client_disconnects():
    client = _FakeStarletteSocket(incoming=["Page.navigate", "Input.dispatchMouseEvent"])
    chrome = _FakeChromeSocket()

    asyncio.run(_pump(client, chrome, source_is_starlette=True))

    assert chrome.sent == ["Page.navigate", "Input.dispatchMouseEvent"]


def test_pumps_chrome_frames_to_client_until_chrome_closes():
    chrome = _FakeChromeSocket(incoming=["Page.screencastFrame"])
    client = _FakeStarletteSocket()

    asyncio.run(_pump(chrome, client, source_is_starlette=False))

    assert client.sent == ["Page.screencastFrame"]


def test_pump_returns_cleanly_on_immediate_disconnect():
    client = _FakeStarletteSocket()
    chrome = _FakeChromeSocket()

    # Must not raise - a client that disconnects before sending anything is
    # the normal "user closed the browser window" case, not an error.
    asyncio.run(_pump(client, chrome, source_is_starlette=True))
    assert chrome.sent == []
