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
Chromium binary and a real Godot process** (not mocks): a real headless
Godot 4.7.2 process, using `WebSocketPeer` with a real `X-API-Key`
handshake header exactly like `scripts/browser_window.gd` (DIDSA-VR repo)
does, connected to a running instance of this exact service and drove a
real `Page.enable`/`Page.navigate`/`Page.startScreencast` sequence,
received a real JPEG `Page.screencastFrame` and decoded it with Godot's
own `Image.load_jpg_from_buffer()` into a real 800x600 `Image`, and sent a
real `Input.dispatchMouseEvent` - all through the relay, with a real
Chromium process on the other end (a locally available Chromium build,
not the Debian-apt one this Dockerfile installs - see below - but the
same binary CDP surface). A wrong-`X-API-Key` connection was also
confirmed rejected before `accept()`. One more thing was checked the same
way, settling a question DIDSA-VR's docs had open: navigating a tab to a
local PDF file makes headless Chrome load its own built-in PDF-viewer
extension and render it inline (`isDownload: false`, a normal
`Page.loadEventFired`, and working screencast frames of the rendered
page) rather than triggering a download - so DIDSA-VR's PDF reader window
needs no separate implementation at all, just this same Browser window
pointed at a PDF URL.

**The Docker build itself was also tested for real** (a Docker daemon
became available in this sandbox after the checks above, on a later
request to test more thoroughly): the base image, the CA-bundle
workaround this sandbox's build sometimes needs for `pip install` inside
a container (see `docker build`'s own error if you hit
`CERTIFICATE_VERIFY_FAILED` - install `/root/.ccr/ca-bundle.crt` as a
trusted CA in an early layer and set `PIP_CERT`), and the actual
containerized FastAPI app all built and ran correctly - including
confirming the app's own fail-fast startup behaviour for real: pointing
`BROWSER_RELAY_CHROME_BINARY` at a non-Chrome binary inside a real running
container made the app refuse to start (`Chromium did not become ready
for CDP connections in time.`) rather than come up silently broken, per
`app/chrome.py`'s own design. What that same container **can't** do yet
is actually run Chromium: bind-mounting a real, working Chromium binary
into the built image and launching it directly failed with `error while
loading shared libraries: libglib-2.0.so.0: cannot open shared object
file` - the minimal `python:3.11-slim-bookworm` base is missing
Chromium's runtime shared libraries, exactly what `apt-get install
chromium` (this Dockerfile's own next line) pulls in transitively. That
line itself could not be exercised in this sandbox: `deb.debian.org`
returns `403 Forbidden` on both HTTP and HTTPS here (confirmed directly
with `curl`, not assumed, and not a transient failure - retried once and
got the same result), which is this specific sandbox's own network
egress policy, not a problem with the Dockerfile.

**What's still unverified, as a result**: the Debian-apt `chromium`
package specifically pulling in the libraries Chromium needs (a
`RUN apt-get install chromium` this sandbox cannot reach `deb.debian.org`
to test, though there's no reason to expect the standard apt dependency
resolution to behave differently here than it does for any other Debian
package), and the arm64 Raspberry Pi target. Both are reasonable to
expect to behave the same way as any other environment where
`deb.debian.org` is actually reachable, but neither has been run for real
yet.
