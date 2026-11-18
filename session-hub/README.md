# Session hub

A small, separate service that runs live design-review sessions: one presenter (Quest or PCVR) and up to six observers (Quest or
phone) in a room with a short join code. It relays presence, the presenter's model state (poses, visibility, section, model place,
"the document changed"), marks and voice frames, and keeps the latest state for late joiners. **It never holds geometry, files or
keys**: observers fetch the presenter's assembly glb from the CAD backend themselves, with a read-only view token the hub hands
out. The spec is `docs/live-sessions-scope.md`; this is phase P1 of `docs/mates-storage-sessions-plan-2026-11-12.md`.

## Why a separate container

The relay's and the store's reasons (decision LS-1): the backend stays stateless, either can be restarted or rebuilt alone, and the
hub's key can be given to a device that should host sessions without giving it the backend's. A hub restart ends every session
(rooms live in memory) and touches no document. This service never imports backend code.

## Running it

```
pip install -r requirements.txt
SESSION_HUB_API_KEY=dev-key python -m uvicorn app.main:app --port 8300 --workers 1
```

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `SESSION_HUB_API_KEY` | yes | - | The key a **presenter** sends as `X-API-Key` on the WebSocket handshake, and `/health` needs. Not `CAD_API_KEY`. The service refuses to start without it. |
| `SESSION_HUB_PUBLIC_URL` | no | "" | This hub's public `wss://` address, put into the join QR code (`didsa-join:1?h=...&c=...`). Without it the presenter's app adds the address it used. |
| `SESSION_HUB_MAX_ROOMS` | no | 16 | Live rooms at once. |
| `SESSION_HUB_MAX_PARTICIPANTS` | no | 7 | Per room: one presenter and six observers (LS-8). |

**One worker only.** Behind a Cloudflare tunnel, give it its own hostname to `localhost:8300` (WebSockets pass through a tunnel).
The CAD backend advertises the hub in its `/health` when told `SESSION_HUB_URL` (its public address, never the key), and the flat
app's pairing code will carry `h` / `hk` (LS-11; the flat app's screen is not changed yet).

## The protocol, briefly

One WebSocket per participant at `/ws`; JSON text frames for everything except voice (binary). The first message is `host`
(presenter: needs the key on the handshake), `join` (observer: the code alone) or `resume` (back within 10 minutes of a drop).
Who may send what, the snapshot, voice framing and every field: `docs/live-sessions-scope.md`, section 4.

- A handshake carrying a **wrong** key is refused before the upgrade. A handshake with **no** key is accepted (observers have none);
  a `host` on it is refused.
- An observer's presenter-only message is dropped and counted, not answered.
- Limits: 64 KB a text message; 60 text messages a second (averaged over 5 s) and 100 voice frames a second per connection;
  10 wrong codes a minute from one address and it is refused for 10 minutes.
- Keep-alive: the hub pings every 10 s; 30 s of silence is a drop.
- A slow receiver's queue is latest-wins (presence per sender, each piece of presenter state, and pose deltas merged), and voice
  frames over 200 ms old are not sent to it.
- Logs: rooms made and ended, joins and leaves by id and display name, refusals. Never message bodies, tokens or voice.

## Tests

`python -m pytest tests/ -v` (CI: `.github/workflows/session-hub-verify.yml`): the rules with a fake connection and clock
(`tests/test_hub.py`: a presenter and two observers, late join, presenter drop and resume, the room ending after 10 minutes,
forbidden messages, wrong codes, muted voice, limits) and the real WebSocket path (`tests/test_ws.py`).

**End to end against a real backend** (not in CI; needs both running): `tools/scripted_session.py` builds a small assembly, mints a
view token, hosts, joins two observers who fetch the glb with only the token (200, then 304) and are refused other routes, streams
poses, sends a document change, checks a late joiner's snapshot and revokes the token at the end. It is also a stand-in presenter
or observer for testing a headset in P2.

```
CAD_URL=http://127.0.0.1:8000 CAD_KEY=... HUB_URL=ws://127.0.0.1:8300 HUB_KEY=... python tools/scripted_session.py
```
