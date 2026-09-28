"""Manages one shared headless-Chromium process and hands out CDP tab
WebSocket URLs to it - the only piece of this service that knows Chrome
exists at all. app/main.py's WebSocket endpoint never talks CDP itself; it
just relays raw frames between an authenticated client and the URL this
module hands it (see main.py's own docstring for why).

Deliberately one Chrome process for the whole service, not one per client:
this runs on a 4GB Raspberry Pi alongside the OCCT backend (see
docs/vr-recon-*.md in this repo for that deployment), and a fresh Chromium
process per connection would be the fastest way to exhaust it. Each client
instead gets its own *tab* in the one process, and MAX_SESSIONS caps how
many tabs can be open at once so one runaway VR session can't take the
whole Pi down with it.
"""

import asyncio
import os
import shutil
import tempfile

import httpx

_MAX_SESSIONS = int(os.environ.get("BROWSER_RELAY_MAX_SESSIONS", "2"))
_CDP_PORT = int(os.environ.get("BROWSER_RELAY_CDP_PORT", "9333"))
_CHROME_BINARY = os.environ.get("BROWSER_RELAY_CHROME_BINARY", "chromium")
_STARTUP_TIMEOUT_SECONDS = 15.0
_STARTUP_POLL_INTERVAL_SECONDS = 0.2


class TooManySessionsError(RuntimeError):
    pass


def build_chrome_args(binary: str, port: int, user_data_dir: str) -> list[str]:
    """Pure (no subprocess): the exact argv used to launch Chrome, split out
    so the launch flags can be reviewed/tested without actually starting a
    process - every flag here narrows Chrome down to "headless CDP target
    with no host-visible surface", not general hardening."""
    return [
        binary,
        "--headless=new",
        f"--remote-debugging-port={port}",
        "--remote-debugging-address=127.0.0.1",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--disable-extensions",
        "--no-first-run",
        f"--user-data-dir={user_data_dir}",
        "about:blank",
    ]


class ChromePool:
    """Owns the single Chrome subprocess and its tab bookkeeping. One
    instance lives for the life of the FastAPI app (see main.py's lifespan
    handler)."""

    def __init__(self) -> None:
        self._process: asyncio.subprocess.Process | None = None
        self._user_data_dir: str | None = None
        self._open_tabs: set[str] = set()
        self._lock = asyncio.Lock()

    @property
    def cdp_base_url(self) -> str:
        return f"http://127.0.0.1:{_CDP_PORT}"

    async def start(self) -> None:
        if self._process is not None:
            return
        self._user_data_dir = tempfile.mkdtemp(prefix="browser-relay-chrome-")
        args = build_chrome_args(_CHROME_BINARY, _CDP_PORT, self._user_data_dir)
        self._process = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await self._wait_until_ready()

    async def _wait_until_ready(self) -> None:
        deadline = asyncio.get_event_loop().time() + _STARTUP_TIMEOUT_SECONDS
        async with httpx.AsyncClient() as client:
            while asyncio.get_event_loop().time() < deadline:
                try:
                    response = await client.get(f"{self.cdp_base_url}/json/version", timeout=1.0)
                    if response.status_code == 200:
                        return
                except httpx.HTTPError:
                    pass
                await asyncio.sleep(_STARTUP_POLL_INTERVAL_SECONDS)
        raise RuntimeError("Chromium did not become ready for CDP connections in time.")

    async def stop(self) -> None:
        if self._process is not None:
            self._process.terminate()
            try:
                await asyncio.wait_for(self._process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                self._process.kill()
            self._process = None
        if self._user_data_dir is not None:
            shutil.rmtree(self._user_data_dir, ignore_errors=True)
            self._user_data_dir = None
        self._open_tabs.clear()

    async def new_tab(self) -> tuple[str, str]:
        """Returns (tab_id, websocket_debugger_url). Raises
        TooManySessionsError instead of opening a tab past the cap."""
        async with self._lock:
            if len(self._open_tabs) >= _MAX_SESSIONS:
                raise TooManySessionsError(
                    f"Already at the {_MAX_SESSIONS}-tab limit (BROWSER_RELAY_MAX_SESSIONS)."
                )
            async with httpx.AsyncClient() as client:
                response = await client.put(f"{self.cdp_base_url}/json/new?about:blank", timeout=5.0)
                response.raise_for_status()
                tab = response.json()
            self._open_tabs.add(tab["id"])
            return tab["id"], tab["webSocketDebuggerUrl"]

    async def close_tab(self, tab_id: str) -> None:
        async with self._lock:
            self._open_tabs.discard(tab_id)
        async with httpx.AsyncClient() as client:
            try:
                await client.get(f"{self.cdp_base_url}/json/close/{tab_id}", timeout=5.0)
            except httpx.HTTPError:
                pass
