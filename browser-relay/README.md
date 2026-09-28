# Browser relay

A small, separate service that lets DIDSA-VR's floating Browser window (and,
via Chrome's built-in PDF viewer, its PDF reader) drive a real headless
Chromium tab from inside a Quest headset. See DIDSA-VR's `docs/status.md`
for how this came about: DIDSA-VR originally scoped a native
Godot-embedded browser (CEF), found it has no Android/Quest build at all,
and this service is the generalized answer to the reframed question that
followed - "if DIDSA-CAD can run in a floating window, can any app?".

## Architecture

This service is a **dumb relay**, not a browser proxy. It knows nothing
about the Chrome DevTools Protocol (CDP) beyond the one HTTP call needed to
open a new tab. Everything else - `Page.navigate`, `Page.startScreencast`,
decoding JPEG frames, forwarding clicks as `Input.dispatchMouseEvent` - is
the Godot client's job (`scripts/browser_window.gd` in DIDSA-VR).

```
Godot (Quest)  --WebSocket, X-API-Key-->  browser-relay  --CDP WebSocket-->  headless Chromium tab
                     (this service, one container)         (127.0.0.1 only, never exposed)
```

1. A client opens `wss://.../ws` with an `X-API-Key` header.
2. `app/auth.py` checks it (same single-static-key posture as the OCCT
   backend's `X-API-Key`, but its own separate `BROWSER_RELAY_API_KEY` -
   see that file's docstring for why they're not the same key).
3. `app/chrome.py` asks the one shared Chromium process (headless, CDP
   bound to `127.0.0.1` only - never reachable except from this container)
   for a fresh tab, up to `BROWSER_RELAY_MAX_SESSIONS` at once.
4. `app/main.py` opens a WebSocket to that tab's own CDP endpoint and
   copies frames verbatim in both directions until either side
   disconnects, then closes the tab.

Keeping CDP logic entirely client-side means this service's own surface
never has to grow just because the client starts using a new CDP domain,
and it's small enough to unit-test without a real browser (see below).

## Why a separate container from the OCCT backend

This runs on the same Raspberry Pi 5 (4GB) as the existing `backend/`
OCCT service, but as its **own** Docker container rather than another
process inside that one:

- A misbehaving Chromium tab (or a client that never disconnects) can only
  exhaust what this container is given, not take memory the OCCT solver
  needs mid-operation.
- `BROWSER_RELAY_MAX_SESSIONS` (default 2) and the container's own memory
  limit (see the repo-root `docker-compose.example.yml`) are the two hard caps
  meant to keep this service's worst case bounded on a 4GB machine.
- The two services can be restarted, rebuilt, and scaled independently -
  relevant here since this one depends on a large-ish Debian+Chromium base
  image the OCCT backend has no reason to carry.

## Environment variables

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `BROWSER_RELAY_API_KEY` | yes | - | Shared secret clients send as `X-API-Key`. Service refuses to start without it (same fail-fast posture as `backend/app/auth.py`). |
| `BROWSER_RELAY_MAX_SESSIONS` | no | `2` | Max concurrent Chrome tabs. |
| `BROWSER_RELAY_CDP_PORT` | no | `9333` | Local-only port Chrome's own CDP HTTP/WebSocket endpoint listens on. Never published outside the container. |
| `BROWSER_RELAY_CHROME_BINARY` | no | `chromium` | Binary name/path launched. The Dockerfile installs Debian's `chromium` apt package and sets this to match. |

## Running locally

```
pip install -r requirements.txt
BROWSER_RELAY_API_KEY=dev-key BROWSER_RELAY_CHROME_BINARY=/path/to/chromium \
    python -m uvicorn app.main:app --port 8100
```

## Tests

```
pip install -r requirements.txt
pytest
```

`pytest` itself does not launch a real Chromium - it covers `app/auth.py`'s
key check, `app/chrome.py`'s pure argv-building and its session-cap
refusal path, and `app/main.py`'s `_pump()` frame-forwarding logic against
fake sockets (see `tests/test_relay.py`'s own docstring). Ubuntu's
`chromium-browser` apt package, in particular, is a snap-only wrapper that
doesn't run without snapd, and snapd doesn't work in a plain container -
confirmed by actually trying it, not assumed, in the sandbox this service
was built in.

**This service has, however, been validated end-to-end against a real
Chromium binary** (not a mock): a standalone script opened an authenticated
WebSocket to a running instance of this exact service, sent
`Page.enable`/`Page.navigate`/`Page.startScreencast`, received a real
JPEG `Page.screencastFrame`, acked it, and sent a real
`Input.dispatchMouseEvent` - all through the relay, with the real Chromium
process on the other end (a locally available Chromium build, not the
Debian-apt one this Dockerfile installs, but the same binary CDP surface).
A wrong-`X-API-Key` connection was also confirmed rejected before
`accept()`. One more thing was checked the same way, settling a question
DIDSA-VR's docs had open: navigating a tab to a local PDF file makes
headless Chrome load its own built-in PDF-viewer extension and render it
inline (`isDownload: false`, a normal `Page.loadEventFired`, and working
screencast frames of the rendered page) rather than triggering a download
- so DIDSA-VR's PDF reader window needs no separate implementation at all,
just this same Browser window pointed at a PDF URL.

What's still unverified is the Debian-apt `chromium` package specifically
(vs. the binary used for the check above) and the arm64 Raspberry Pi
target - both are reasonable to expect to behave the same way, but neither
has been run for real yet, and DIDSA-VR's `scripts/browser_window.gd`
client has not been driven against this service by an actual Godot
process (see that repo's own docs for its own, separate CDP-message
pure-function tests).
