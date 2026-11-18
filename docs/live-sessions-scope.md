# Live sessions: scope (P0)

Phase P0 of `docs/mates-storage-sessions-plan-2026-11-12.md` (Part 3). Written 2026-11-18 from reading both repos on `main`
(CAD `8f8ee4a`, VR `095ad2f`). **A scope, not code: nothing in `backend/`, `client/` or DIDSA-VR was changed, and nothing was run on a
headset or a phone.** The companion pieces are in DIDSA-VR: `docs/main-gd-split-audit.md` (what a view-only build must not load) and
`docs/live-sessions-spikes.md` (the voice and Cardboard spikes, for the owner's devices).

Every choice the plan left open is decided below with one line of reasoning and listed in section 10; **the owner accepted all thirteen on 2026-11-18**, so P1 builds them as written.
P1 (hub and backend token) and P2 (VR Host / Join) should be buildable from this doc alone; section 11 checks that.

## 1. What this does, in one paragraph

The presenter (Quest or PCVR) works exactly as today against their own backend document session. When they press **Host Session**,
the app asks the backend for a **view token** bound to that session, opens a WebSocket to a new **session hub** and creates a room; the
hub hands out a short **join code**. An observer (Quest or phone) types or scans the code, connects to the hub with nothing else, and
gets back a snapshot: which model, the view token and the backend's public address. The observer fetches the presenter's assembly glb
**from the backend, read-only, with the token**, then applies the hub's stream: part poses, visibility, section plane, model place,
"geometry changed" signals, presence, marks and voice. The hub never holds geometry, files or keys; it relays and keeps the latest
value of each piece of state for late joiners.

```
Presenter ── REST + X-API-Key + X-Document-Session ──> CAD backend   <── GET assembly-mesh.glb + X-View-Token ── Observer
    │  POST /document/view-tokens (mint)                     ▲                                                      │
    └── wss + X-API-Key (hub key) ──> Session hub <── wss, join code only ───────────────────────────────────────────┘
                                      (rooms, roles, latest state, presence, marks, voice frames)
```

## 2. What is there today (found while writing this)

| | Where | What it means for sessions |
|---|---|---|
| Backend auth | `backend/app/auth.py`, applied app-wide in `backend/app/main.py` (`FastAPI(dependencies=[Depends(verify_api_key)])`) | One shared `CAD_API_KEY` for every route. A view token needs a change to this **app-level** dependency, not a router: section 5 |
| Document sessions | `backend/app/session_context.py` (`X-Document-Session`, "no security property riding on the session id"), `app/document/store.py` (one in-memory `Document` per id, LRU 200) | The session id is not a secret today and grants nothing without the key, but it is the presenter's document: observers are never told it (the token stands in for it) |
| Router dependency | `app/document/router.py`: `APIRouter(prefix="/document", dependencies=[Depends(bind_session_id)])` | Runs **after** the app-level key check and **resets** the session id from the header. P1 must make it keep a token-bound session (section 5, "Gotchas") |
| The glb | `GET /document/parts/{part_id}/assembly-mesh.glb` (`quality`, `tier`, `include_hidden`, `topology`, `hidden_feature_ids`, `rollback_excluded_feature_ids`) | What both VR roles render. Nodes are flat, one per placed instance, with `extras.instance_path` (the full occurrence path, pattern copies included), `occurrence_id`, `owner_part_id`; materials carry the resolved appearance. **No display names** |
| Tree data | `GET /parts/{id}` (the whole Part: features, sketches), `GET /parts/{id}/occurrences` (rows include `external_ref`, the placed **file's path**) | Both expose what an observer must not get (section 7). Names for an observer come another way (section 5) |
| A document change counter | none | P1 adds one (section 5) |
| Push channel | none in the backend; the browser relay (`browser-relay/`) is a WebSocket service with its own key in the handshake header, and DIDSA-VR's `browser_window.gd` already opens `wss://` with `X-API-Key` | The hub follows the relay's and the store's pattern: own container, own key |
| How the headset finds services | Pairing QR `didsa-vr:1?n=&u=&k=` + `r`/`rk` (relay), `p`/`pk` (store), `s` reserved (`docs/vr-headset-pairing.md`); `/health` advertises `project_store` when `PROJECT_STORE_URL` is set | The hub gets `h`/`hk` and `/health` gains `session_hub` the same way |
| How VR moves parts | `controller.gd` `_sync_pose` PATCHes the occurrence on release; during a drag and while mates are relaxed (the sandbox) the pose is client-only | Observers must get poses from the presenter's **client**, not the backend: the stream carries them |
| What VR keeps client-only | visibility (hide / isolate / reverse, `main.gd`), the section plane (one world-space plane, `section_tool.gd`), whole-model place and scale (`AssemblyRoot` transform, `two_hand_model.gd`), sandbox paint and scene looks (a layer in `appearance_tool.gd` / `scenes_tool.gd`), Assembly Rooms | Each is either streamed (section 4) or not mirrored in v1 (section 8) |
| Identity | VR's `device_name()` setting (sent to the store as `X-Device-Name`) | Used as the default display name |

## 3. Roles

| | Presenter | Observer |
|---|---|---|
| How many | Exactly one per room (D2); the one who created it | Up to **6** (decision LS-8) |
| Connects with | The hub key (`X-API-Key` on the WebSocket handshake) | The join code only. No key of any kind |
| Edits the document | Yes, as today | Never. Has no backend write access at all (token is GET-only on an allowlist) |
| Tools (P2 gating) | Everything | No mates, design table, save, files, rooms, servers. Own-view tools come in P4 |
| Can send | Every message in section 4 | `presence`, `voice` frames, `mark` (own, P4), `hand` (raise / lower), `leave`. The hub drops anything else from an observer and counts it |
| Can do to others | Remove a participant, lock the room, clear marks, mute all (P3), Gather everyone, end the session | Nothing |

**No presenter hand-over in v1** (D2): if the presenter leaves for good the session ends. A presenter that **drops** (network, app
restart) has **10 minutes** to come back with its `resume` token (section 4) before the hub closes the room; observers see "Presenter
reconnecting" meanwhile and keep the last state.

## 4. Messages

### 4.1 Transport and conventions

- **One WebSocket per participant**, `wss://<hub>/ws` (plain `ws://` only on a local network, the relay's address rule). Godot's
  `WebSocketPeer.set_handshake_headers` exists in 4.7.2 (checked on the desktop build), which is how the presenter sends the hub key.
- **Text frames are JSON** for everything except voice; **binary frames are voice only** (section 4.6). Reasoning: JSON is what both
  clients already parse and debug, and the state messages are small (decision LS-7).
- Every JSON message is an object with `"t"` (its type). The hub adds `"from"` (the sender's participant id) and `"at"` (hub time, ms)
  to everything it relays; a client never sets `from` and the hub overwrites it if one does.
- **State messages from the presenter carry `"seq"`** (an integer that only goes up per connection, restarted with `resume`). A client
  ignores a state message older than one it has applied for the same key.
- **Model space** = the frame of the glb's root as VR shows it under `AssemblyRoot`: **millimetres**, Godot axes (y up). Every pose,
  point and plane in a message is in model space, never in a participant's world space. A participant converts with their own
  `AssemblyRoot` transform. (In v1 everyone uses the presenter's model place, section 4.3, so it only matters for avatars; it keeps a
  private scale possible later.)
- **A transform** is 12 numbers: basis x, y, z columns, then origin, `[xx,xy,xz, yx,yy,yz, zx,zy,zz, ox,oy,oz]`. Positions rounded to
  0.01 mm, basis to 1e-5. Twelve rather than position + quaternion because occurrence transforms can mirror.
- **A pose** (presence only) is 7 numbers `[px,py,pz, qx,qy,qz,qw]`, position in model mm.
- **A target** names a thing in the model: `{"path": "<instance_path>", "body": "<body_id>"?, "face": <int>?}`. `path` is the glb's
  `extras.instance_path`, which is unique per placed instance (pattern copies included); occurrence ids alone are not (VR's tree
  addresses rows by path for this reason).
- **Limits** (hub-enforced): a text message at most **64 KB**; per connection at most **60 text messages a second** and **100 voice
  frames a second**, each averaged over 5 s, then `error rate_limited` and close.

### 4.2 Joining, leaving and room control

| `t` | Direction | Fields | Meaning |
|---|---|---|---|
| `host` | presenter → hub (first message) | `proto: 1`, `name`, `device` (`quest` / `pcvr` / `phone` / `desktop`), `client`, `model` (4.3, with `kind`), `backend_url`, `view_token`, `view_expires_at` | Create a room. A handshake with a **wrong** hub key is refused before the upgrade; a `host` on a handshake with **no** key gets `error not_allowed` (observers' handshakes carry none, so a missing key cannot be refused earlier) |
| `join` | observer → hub (first message) | `proto: 1`, `code`, `name`, `device`, `client` | Join by code |
| `resume` | either → hub (first message) | `proto: 1`, `resume` | Come back after a drop with the token from `welcome`; the hub restores id, name, colour and role. Resuming as the presenter needs the hub key on the handshake too |
| `welcome` | hub → the one who connected | `you: {id, name, colour, role}`, `room: {code, join_uri, locked}`, `resume`, `participants: [...]`, `snapshot` (4.7). **To an observer also:** `backend_url`, `view_token` | Accepted |
| `error` | hub → client | `code`, `message` | Then the hub closes. Codes: `proto_unsupported`, `bad_code`, `room_full`, `room_locked`, `removed`, `not_allowed`, `rate_limited`, `too_big`, `resume_expired`, `hub_full` (no room for another session), `bad_message` (a `host` without a usable model) |
| `joined` / `left` | hub → all | participant / `id`, `reason` (`left`, `dropped`, `removed`) | Roster changes. A `dropped` presenter is shown as reconnecting |
| `roster` | hub → all | `participants: [{id, name, colour, role, device, hand, muted, talking, connected}]` | Sent on any change of a participant's own fields (hand, mute, talking) |
| `lock` | presenter → hub → all | `locked: bool` | No new joins while locked (`resume` still works) |
| `remove` | presenter → hub | `id` | The hub sends that participant `error removed`, closes it, and refuses its `resume` |
| `token` | presenter → hub → observers | `view_token`, `view_expires_at` | A renewed token (section 5); observers swap it in |
| `end` | presenter → hub → all | | The session is over; the hub closes everyone and forgets the room |
| `leave` | anyone → hub | | A clean goodbye (versus a drop) |
| `ping` / `pong` | either way | `n` | Keep-alive every 10 s; 30 s silent = dropped |

- **Participant id:** a small integer 1 to 255 chosen by the hub, never reused within a room (it also labels voice frames).
- **Colour:** the hub gives each participant the first free colour of a fixed palette of 8 (D6: one colour each); the presenter's is
  always the first.
- **Join code:** 6 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no 0/O, 1/I/L), e.g. `K7XQ4M`, unique among live rooms.
  The QR code is `didsa-join:1?h=<hub wss address>&c=<code>` (the hub writes `h` into `welcome.room.join_uri` when it is told its
  public address, `SESSION_HUB_PUBLIC_URL`; otherwise `join_uri` has only `c` and the presenter's app adds the address it used): a **separate scheme** from pairing (`didsa-vr:1`) so a join code can
  never be mistaken for, or carry, a server's keys (decision LS-2).
- **Admission:** anyone with the code is admitted, the presenter sees them arrive and can Remove them or Lock the room (decision LS-2).
  A wrong code costs: 10 wrong codes from one address in a minute and that address is refused for 10 minutes.

### 4.3 The model and what the presenter changes in it (presenter → hub → observers)

| `t` | Fields | Meaning, and how an observer applies it |
|---|---|---|
| `model` | `source` (below), `title`, `rev` | What is shown. On a change of source, observers drop everything and load the new model |
| `doc_changed` | `rev`, `parts: [part_id]` or `all: true`, `hidden_feature_ids?` | The backend document changed (a feature landed, a mate solved, a paint, a part added). With `parts`: refetch only those parts' own glb (`GET /parts/{pid}/assembly-mesh.glb`) and swap their meshes, as `main.gd` `swap_part_mesh` already does after a design-table edit. With `all`: refetch the root's glb. Ignore if `rev` ≤ the rev already loaded. `hidden_feature_ids` repeats the presenter's design-table hide list, so the observer's fetch matches |
| `poses` | `full: bool`, `items: [{path, xf}]` | Part poses relative to the glb root. `full: true` replaces the whole table (sent after every load and refetch, and on `resume`); otherwise only what moved. Sent at most **30 Hz** while anything moves, nothing while still. Observers smooth (section 4.8) |
| `visibility` | `hidden: [path]` | The full list of instances the presenter has hidden on top of the glb (hide, isolate, a shown scene). A full list every time: it is short and cannot drift |
| `section` | `on`, `point: [x,y,z]`, `normal: [x,y,z]` | The presenter's one section plane (VR has one), in model space. Observers convert it to their world and set the same global clip uniform |
| `place` | `xf` (model root in the presenter's world, metres, scale included) | The shared model place and scale (decision LS-6, the plan's P2 recommendation). Observers set their `AssemblyRoot` to it |
| `status` | `activity` (`model` / `design_table` / `room` / `files` / `idle`), `detail` | What the presenter is doing, for a line in the observer's view: "Alex is at the design table: Shaft" (design table and rooms are not mirrored in v1, section 8) |
| `scene` | `id` or null, `name` | The scene shown. Poses and visibility already arrive as `poses` / `visibility`; this is the name for the observer's status line |
| `gather` | `pose` (a model-space point and facing) | Gather everyone: each client teleports its rig to a spot around that pose (P2 lays them out in an arc, as the landing does) |
| `marks_clear` | `ids?` (none = all) | The presenter clears shared marks |
| `mute_all` | | P3 |

`source` is one of:

- `{"kind": "backend", "root_part_id": "<id>", "rev": <int>, "quality": <0..1>, "tier": "full"}`: fetch
  `GET <backend_url>/document/parts/<root>/assembly-mesh.glb` with the token. A phone may ask `tier=coarse` (P5).
- `{"kind": "demo", "path": "res://demo/..."}`: a demo shipped in the APK; every client has the same file. No backend involved.

A model that is neither (a bare `.glb` opened from a folder) **cannot be hosted**: Host Session says so. It would mean sending a file
(decision LS-9).

### 4.4 Presence (everyone → hub → everyone else)

| `t` | Fields | Rate |
|---|---|---|
| `presence` | `head` (pose), `hands: [left, right]` (pose or null), `laser: [x,y,z]` or null (the laser's end, model space), `cursor` (pose or null; the P4 drone cursor), `mode` (`free` / `following` / `seated`) | **15 Hz** while anything changed by more than 2 mm or 1°; 1 Hz otherwise |
| `hand` | `up: bool` | Raise hand |

The hub does not echo a participant's own presence back. A phone sends `head` with its gyro orientation at its seat position and
`hands: [null, null]`.

### 4.5 Marks (P4; the shape is fixed now so the hub can relay them in P1)

| `t` | Fields |
|---|---|
| `mark` | `id` (sender-chosen, unique per sender), `kind` (`share` / `ping` / `look_here`), `target` (a target, or `{"point": [x,y,z]}`), `colour` (the sender's), `ttl_s` (ping 3, look_here 10, share until cleared) |
| `mark_clear` | `id` (an observer clears its own) |

Marks are never written anywhere (D7). The hub keeps live `share` marks in the snapshot until cleared or their sender leaves.

**As built in P4 (DIDSA-VR; no change to this protocol, the hub or the backend).** The VR client uses the ids `share` (one live share per person: a new one replaces it, here and at the hub), `look` and `ping<n>`. A target is `{path, body?, face?}` with `path` the glb's `instance_path` (the key `poses` use; a sub-assembly is its path prefix, the root's own content may have the empty path) or `{point: [x,y,z]}` in model-space millimetres; a `look_here` carries both the selection's target and the `point`. The `colour` the hub stamps is the one drawn (a client's own is ignored). A mark for a part the receiver does not have is kept and drawn when it appears. A `marks_clear` without `ids` clears every mark (shares, pings, look-heres) at the receivers; an observer's is dropped by the hub, so only the presenter's button exists. The hub forgets a participant's shares when they leave or are removed (`left` with a reason other than `dropped`) and the client drops them with the roster. A mark is relayed to everyone, including the presenter; "Look here" is not directed at the presenter alone (the presenter's client says it in words).

### 4.6 Voice (P3; framing fixed now)

Binary frames: **byte 0** = format version (1), **byte 1** = participant id (the hub overwrites it with the sender's id), **bytes 2-3**
= sequence number (big-endian, wraps), **byte 4** = flags (bit 0: last frame of a talk spurt), then **one Opus packet**: 20 ms, 48 kHz
mono, about 24 kbit/s. The hub relays to everyone else and **never decodes, mixes, records or logs** them. A frame from a muted
(by the presenter) participant is dropped at the hub. `voice_state {muted, talking}` (JSON) updates the roster.

### 4.7 The snapshot (what a late joiner gets in `welcome`)

The hub keeps the **latest value per key** of the presenter's state messages and nothing else:
`model`, the newest `doc_changed.rev` (with the union of `parts` since the last `full` reload is **not** kept: a late joiner fetches
the root glb at that rev, which already includes them), the pose table (applying `full` and partial `poses` in order), `visibility`,
`section`, `place`, `status`, `scene`, live `share` marks, and each participant's last `presence`. A late joiner loads the model,
then applies the snapshot, then the stream. The hub understands only these keys; it never interprets a transform.

### 4.8 Smoothing and order

Observers render remote poses and presence **one interval behind** (about 70 ms at 15 Hz presence, 35 ms at 30 Hz poses),
interpolating between the last two received values by `at`; a gap over 500 ms snaps. A `doc_changed` that arrives while a refetch is
running is queued; the newer `rev` wins. Poses are applied **after** a refetch, from the `full` table the presenter sends after its
own reload.

## 5. The read-only view token (backend, P1)

**Minted by the backend, held in its memory, handed to observers by the hub** (decision LS-3). Reasoning: the backend is the only
thing that can tell what a token may read, and a token in its own memory needs no secret shared between hub and backend.

| Route (new) | Auth | Does |
|---|---|---|
| `POST /document/view-tokens` | `X-API-Key` + `X-Document-Session` (the presenter) | Body `{root_part_id, ttl_s?}` (default and maximum **12 h**). Returns `{token, expires_at}`. `token` is 32 random bytes, URL-safe base64. Bound to the caller's session id and root. At most 4 live tokens per session (the oldest is revoked) |
| `DELETE /document/view-tokens/{token}` | key + session | Revoke (Host Session's End, and a presenter re-hosting) |
| `GET /document/view-state` | `X-View-Token` | `{rev, root_part_id, expires_at}`: lets an observer check it is current without a hub message |

**What a token may read: `GET /document/parts/{part_id}/assembly-mesh.glb` (any Part in the bound session, every existing query
parameter) and `GET /document/view-state`. Nothing else, including `/health`.** Any other route, and any non-GET, with a token and
no key: **401**. A request with both a key and a token is treated as the key's (the token is ignored). Unknown, expired or revoked
token: 401 with `detail: "view_token_invalid"`, so the observer can ask the hub for a fresh one.

**Names for the observer's tree / breadcrumb (P4):** add `name` (the occurrence's display name: `name_override`, else the placed
Part's name) to each glb node's `extras`, beside `instance_path`. Additive; DIDSA-VR ignores unknown extras. This avoids opening
`/parts/{id}` or `/occurrences` to a token (section 7 says why).

**The document revision** (`rev`): an integer per document session, starting at 1 and bumped by every request that changes the
document (an import is a change; nothing resets it), and by a background job when it adds its Feature. Returned on **every** response as `X-Document-Revision` (so the presenter learns it from the request it just made,
with no extra call) and as the glb's `ETag` (`"<rev>-<hash of the query>"`), so an observer's refetch can send `If-None-Match` and
get a **304**. As built (P1, `backend/app/session_hooks.py`): every non-GET that answers 2xx bumps it, except routes whose path says
preview, measure, import probe, AI-plan validate, job cancel, and minting or revoking a view token, because a missed bump shows stale
geometry while a spare bump only costs a 304. `ETag` and `304` are for token requests only.

**A small glb cache** (per session: the last 4 `(rev, query) -> bytes`, at most 64 MB in all) so six observers fetching after one
edit cost one encode on the Pi, not six. **Token requests only:** the presenter's own requests are computed as before, so a bump the
backend missed can never show the presenter a stale model.

**Gotchas for P1, found in the code:**

1. `verify_api_key` is an **app-level** dependency. The token check must replace it there (key, or token + allowlisted route + GET),
   not be added to a router, or the key check rejects the token request first.
2. `bind_session_id` (the `/document` router's dependency) runs after it and **sets the session from `X-Document-Session`**, falling
   back to `"default"` when absent. With a token it must bind the token's session and ignore the header, or an observer reads the
   `default` document, or any session it names.
3. **A second reader is new.** Today a session's only client is the app that made it (`store.py`'s lock guards the dict lookup, not a
   mutation). An observer's glb GET can now run in another worker thread while the presenter's edit is mutating the same `Document`.
   (Whether the presenter's own app already overlaps requests across its tools was not checked.) **As built:** a per-session lock
   (`app/session_hooks.py`) held by every token GET and every non-GET of that session (not a job cancel, which must reach a running
   request; not the presenter's own GETs, which behave as before). A background job's commit is outside it (known gap; it is rare
   and bumps the revision).
4. The `/openapi.json` and `/docs` routes stay reachable without auth (`main.py` says so); they show the schema, not data. Nothing to do.

## 6. The hub (P1)

- **Its own small service, `session-hub/` in this repo, its own container in `docker-compose.example.yml`, its own key
  `SESSION_HUB_API_KEY`** (decision LS-1), for the relay's and the store's reasons: no state in the backend, restart either alone, a
  key that can be given to a presenter device without the backend's. Python 3.11, FastAPI WebSockets, **one worker**, rooms in memory
  (a hub restart ends every session; clients show "Session ended" and the presenter can host again).
- Presenter auth: the hub key in the handshake (`X-API-Key`), as the relay does. Observers: no key, first message `join`.
- `GET /health` (needs the key, like every service here) answers `{status, rooms, participants, api_features}`.
- Per-observer **latest-wins send queue** for state and presence (a slow phone gets the newest pose, not a backlog); voice frames older
  than 200 ms in the queue are dropped.
- Limits: 7 participants (1 + 6), 16 rooms, the message limits in 4.1. All are settings.
- **Finding it:** the backend's `/health` gains `session_hub` (its public `wss://` address) when `SESSION_HUB_URL` is set, as
  `project_store` does; the flat app's Connect a VR headset screen writes `h` (hub address) and `hk` (hub key) into the pairing code,
  as `p` / `pk`. An observer needs neither: the join QR carries the hub address.
- **Logging:** room created / ended, joins and leaves by participant id and display name, errors. Never message bodies, tokens, codes
  of other rooms or voice.

## 7. What is never sent

| Never | Not to the hub | Not to an observer | How it is kept out |
|---|---|---|---|
| The CAD backend's key (`CAD_API_KEY`) | ✓ | ✓ | The presenter keeps it; the token stands in for it |
| The project store's, relay's and hub's keys | ✓ (the hub key only as the presenter's handshake header, never in a message) | ✓ | |
| The presenter's document session id | ✓ | ✓ | The token is bound to it server-side |
| **Files**: native `.didsa` / `.didsaprt`, STEP / IGES / STL / OBJ, project store files, file **paths** and folder names | ✓ | ✓ | Every `/export/*` route and `/export/native` is outside the token allowlist; `/occurrences` (has `external_ref`, a path) and `/parts/{id}` are too. `model.title` is the root Part's name, never a file name |
| **The parametric model**: features, sketches, dimensions, mates, scenes' stored data, appearance override records | ✓ | ✓ | Outside the allowlist. An observer gets the **mesh** (and display names), which is what a design review shows |
| Server addresses other than the backend's public address and the hub's | ✓ | ✓ | The store and relay addresses are not in any message |
| Anything recorded: voice, marks, presence | n/a | n/a | The hub relays and forgets (D7); voice is never written to disk |

An observer **does** get: the glb (geometry, colours, instance paths, display names, and with `topology` the edge / face identity
the drone cursor will pick, P4), the backend's public address, a token that can only fetch that, and everyone's display name, colour
and presence.

## 8. Not mirrored in v1 (each one a decision to confirm)

- **Sandbox paint, a live paint preview and a scene's looks.** They are a client-side layer on the presenter's Appearance tool;
  mirroring them needs the appearance resolution model, which is built from `/parts/{id}` and the override records (section 7 keeps
  those out). A **real paint** is a document change: `doc_changed` and the refetched glb carry it, painted by the backend with the
  same rule. If the owner wants scene looks mirrored, P4 can add a `looks` message carrying resolved colours per target (decision LS-4).
- **Assembly Rooms** and **the design table's sketch** (decision LS-5). Observers see the world assembly; `status` says where the
  presenter is; a feature or a room edit reaches them as `doc_changed`.
- **Environment (Light / Dark / Mid / Passthrough) and view mode (edges, wireframe):** each person's own (decision LS-10); a phone
  never runs Passthrough.
- **Mate previews and the glide** (M3): poses during a glide stream like any move (`poses` at 30 Hz), so observers see the part glide;
  the ghosts and lines are not drawn for them.

## 9. Bandwidth (estimates, not measured)

Presence: about 250 bytes of JSON x 15 Hz = 30 kbit/s per sender, x 6 receivers through the hub. Poses during a drag of one part:
about 150 bytes x 30 Hz = 36 kbit/s. Voice: about 30 kbit/s per talker with framing and WebSocket overhead. Seven people, two
talking and one dragging: under 1 Mbit/s out of the hub. The glb is the large item: one fetch per observer per `doc_changed` (a 304
when nothing changed for that query). To be measured in P1's scripted test and P2 on the tunnel.

## 10. Decisions for the owner (all thirteen recommendations ACCEPTED, 2026-11-18)

The owner accepted every recommendation below on 2026-11-18; the table is kept as the record of what was asked.

| # | Question | Recommendation and one line of reasoning |
|---|---|---|
| LS-1 | Hub as its own container with its own key, or inside the backend? | **Own container, `SESSION_HUB_API_KEY`**: the backend stays stateless and a hub crash or restart never touches a document (the S0-1 reasoning) |
| LS-2 | How observers get in | **6-character code + QR (`didsa-join:1?h=&c=`), anyone with the code is admitted, presenter can Remove and Lock**; a knock-to-enter step can come in P7 with per-device keys. A separate QR scheme so a join code can never carry keys |
| LS-3 | Who mints the read-only token, and what it may read | **The backend, in memory, 12 h, GET-only on `assembly-mesh.glb` and `view-state`**: the narrowest thing that lets an observer render, and nothing to share between hub and backend |
| LS-4 | Do observers see the presenter's sandbox paint, paint preview and scene looks? | **Not in v1**: it needs the parametric / override data LS-3 keeps out; real paints do reach them. Revisit in P4 with a `looks` message if wanted |
| LS-5 | Mirror Assembly Rooms and the design table's sketch? | **Not in v1**: a status line instead; their results arrive as document changes |
| LS-6 | (P2's open question) shared or per-person model place and scale | **Shared, set by the presenter**, presence in model space (the plan's own recommendation; it keeps a private scale possible later) |
| LS-7 | Message encoding | **JSON text for state, binary only for voice** |
| LS-8 | Room size | **1 presenter + 6 observers** (the plan puts "more than six people" in P7) |
| LS-9 | Hosting a model that is not in the backend | **Only backend documents and shipped demos can be hosted**; a bare `.glb` from a folder would mean sending a file |
| LS-10 | Environment and view mode | **Each person's own** |
| LS-11 | Pairing keys and discovery for the hub | **`h` / `hk` in the pairing code; `session_hub` in `/health` from `SESSION_HUB_URL`** (the `p` / `pk` precedent) |
| LS-12 | Display names for observers | **`extras.name` on each glb node**, so no tree route is opened to the token |
| LS-13 | Voice add-on (D9) | **TwoVoip** (`goatchurchprime/two-voip-godot-4`, MIT), subject to the spike: DIDSA-VR `docs/live-sessions-spikes.md` |

## 11. Check against P1 and P2

**P1 (hub, token) can be built from:** sections 4 (every message the hub must route, with who may send it), 4.7 (exactly what the
snapshot keeps), 5 (three routes, the allowlist, the revision header, the cache, the three gotchas) and 6 (service shape, limits,
discovery). The plan's P1 tests map onto it: a scripted presenter and two scripted observers (host, join, `poses`, `doc_changed`, an
observer's token fetch of the glb returning 200 then 304, an observer's attempt at `PATCH` / `export/native` / `/parts/{id}` returning
401); late join (snapshot contents); presenter drop and `resume` within 10 minutes, and the room closing after. Add: a forbidden message
from an observer is dropped; a wrong code ten times is refused; voice frames from a muted participant are dropped; a glb fetch racing
an edit returns either the old or the new mesh, never an error.

**P2 (VR Host and Join) can be built from:** 3 (role gating), 4.2 (host, join, resume, the QR scheme), 4.3 (what the presenter
sends and when: `poses` from the hands and the mates glide, `visibility` from the hide / isolate paths, `section` from the section tool,
`place` from the two-hand model, `doc_changed` after anything that called the backend successfully, `status`), 4.4 (avatars from
`presence`), 4.8 (smoothing), and 8 (what not to mirror). Where to hook these in `main.gd` and what an observer must not load:
DIDSA-VR `docs/main-gd-split-audit.md`. Two things P2 must still choose, both small: where Host / Join sit on the landing's monolith,
and the comfort vignette for Follow presenter.

**Left to P3 / P5 by design:** the voice add-on and the mic path (the spike decides), the phone's camera rig and render budget (the
Cardboard spike decides).
