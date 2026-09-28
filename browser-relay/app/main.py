"""Browser relay: a "dumb pipe" WebSocket service that lets a Godot client
drive an arbitrary headless-Chromium tab over the Chrome DevTools Protocol
(CDP) - the generalized mechanism behind DIDSA-VR's floating Browser
window (and, via Chrome's own built-in PDF viewer, its PDF reader; see
that repo's docs/status.md for the "if DIDSA-CAD can run in a floating
window, can any app?" framing this came from).

This service does not speak CDP. It authenticates the incoming client
WebSocket (X-API-Key, see app/auth.py), asks app/chrome.py for a fresh
Chrome tab, and then copies raw WebSocket frames in both directions
between the client and that tab's own CDP WebSocket - Page.enable,
Page.navigate, Page.startScreencast, Input.dispatchMouseEvent, all of it,
are the *client's* concern (see DIDSA-VR's scripts/browser_window.gd).
Keeping every CDP detail out of this service is deliberate: it's the
smallest, most stable surface that can sit on a resource-constrained
Raspberry Pi next to the existing OCCT backend (see docs/vr-recon-*.md),
and it means this service never needs to change just because the client
starts using a new CDP domain.
"""

import asyncio
from contextlib import asynccontextmanager

import websockets
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from websockets.exceptions import ConnectionClosed

from app.auth import is_authorized
from app.chrome import ChromePool, TooManySessionsError

_chrome_pool = ChromePool()


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    await _chrome_pool.start()
    try:
        yield
    finally:
        await _chrome_pool.stop()


app = FastAPI(lifespan=_lifespan)


@app.get("/health")
async def health() -> dict:
    # Intentionally unauthenticated, like backend/app/main.py's own
    # /health - it reports liveness only (no session data, no CDP access),
    # and Cloudflare Tunnel makes this container internet-reachable with
    # no auth of its own either.
    return {"status": "ok"}


async def _pump(source, sink, *, source_is_starlette: bool) -> None:
    """Forward frames from source to sink until either side closes. Split
    out from the endpoint below so it can be tested directly against two
    in-process fake sockets, without a real client or a real Chrome tab -
    see tests/test_relay.py."""
    try:
        while True:
            if source_is_starlette:
                message = await source.receive_text()
            else:
                message = await source.recv()
            if source_is_starlette:
                await sink.send(message)
            else:
                await sink.send_text(message)
    except (WebSocketDisconnect, ConnectionClosed):
        pass


@app.websocket("/ws")
async def relay(client: WebSocket) -> None:
    if not is_authorized(client.headers):
        await client.close(code=4401)
        return

    await client.accept()

    try:
        tab_id, tab_ws_url = await _chrome_pool.new_tab()
    except TooManySessionsError:
        await client.close(code=4503)
        return

    async with websockets.connect(tab_ws_url, max_size=None) as chrome_ws:
        client_to_chrome = _pump(client, chrome_ws, source_is_starlette=True)
        chrome_to_client = _pump(chrome_ws, client, source_is_starlette=False)

        _done, pending = await asyncio.wait(
            [asyncio.ensure_future(client_to_chrome), asyncio.ensure_future(chrome_to_client)],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()

    await _chrome_pool.close_tab(tab_id)
