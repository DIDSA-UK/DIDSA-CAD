# Mates review, shared storage and live sessions: plan

Source: the owner's request of 2026-11-12. Three objectives across the backend, the Flutter client and DIDSA-VR (Godot):
a mates review, server-based storage, and "multi user" (observer and multiplayer design reviews, including a phone
"Cardboard" observer). This plan splits the work into tasks and phases. Each phase is sized for one implementation session
(one PR per repo touched) and names the kind of coding agent it suits.

Written from reading the docs and code on `main` (CAD `b17c61c7`, VR `1e5d188`). **Nothing was run and nothing was seen on a
headset.** Code pointers are symbol names; search for the symbol if a line has moved.

## Decisions (owner, 2026-11-12)

| # | Decision | Answer |
|---|---|---|
| D1 | Rollout order | Mates, then storage, then sessions |
| D2 | Session model | One presenter edits; observers join remotely (over the internet through the existing tunnel) |
| D3 | Storage | A storage service beside the CAD backend; local copy for offline work; version check on sync |
| D4 | Mate preview | The real part glides to the mated position; Cancel glides it back (as SolidWorks does) |
| D5 | Voice | Built in from the first usable session release |
| D6 | Avatars | Head, hands and name tag, one colour per person |
| D7 | Observer tools | Change the observer's own view by default; a Share toggle shows a temporary mark to everyone; nothing is saved |
| D8 | Phone observer | The same Godot project, a second Android export (view-only) |
| D9 | Voice codec | One more add-on exception is allowed: an Opus GDExtension, fetched by a script and never committed, like the OpenXR Vendors plugin |

Still to decide, each at the start of the phase named (recommended answer given there): shared or per-person model scale
(P2), whether the store is its own container or a router in the backend (S0).

## Progress

The implementation session updates this table in its PR.

| Phase | Summary | Repos | State |
|---|---|---|---|
| M0 | Mate benchmark: scaling scenes and first-time accuracy baseline | CAD | Not started |
| M1 | Rigid sets in the group solve | CAD backend | Not started |
| M2 | Constraint model v8 in the Dart and GDScript mirrors; caps raised | CAD client, VR | Not started |
| M3 | Glide preview (Flutter and VR), VR edit-mate preview | CAD client, VR | Not started |
| M4 | Better first guess: type from the picks, pick-point defaults | CAD backend + both clients | Not started |
| M5 | Rigid sets shown in the tree; "moves as one" cues | CAD client, VR | Not started |
| S0 | Storage scope doc and spikes | CAD, VR | Not started |
| S1 | Project store service | CAD | Not started |
| S2 | Flutter: server projects, local cache, offline queue, conflicts | CAD client | Not started |
| S3 | VR: server projects, cache, offline | VR | Not started |
| S4 | Sync hardening and set-up polish | all | Not started |
| P0 | Session protocol scope; voice, Cardboard and `main.gd` split spikes | CAD, VR | Not started |
| P1 | Session hub service and read-only document sharing | CAD | Not started |
| P2 | VR Host / Join Session, roles, avatars, live model state | VR | Not started |
| P3 | Voice | CAD hub, VR | Not started |
| P4 | Observer tools: drone cursor, own-view edits, Share marks | VR | Not started |
| P5 | Phone (Cardboard) observer export and controller mapping | VR | Not started |
| P6 | Flat app joins a session | CAD client | Later |
| P7 | Hardening: reconnects, many participants, per-device keys | all | Later |

---

## Part 1: Mates review

### What is there (and it is the right direction)

`docs/mate-solution-choice-plan.md`, `docs/constrained-drag-smoothness-study.md` and the code agree:

- **Root choice.** Each mate stores its branch (`alignment`, `secondary_flip`, `branch_source`), starts as Closest, and the
  preview returns `controls`, `resolved` and `alternatives` (Flip, Next solution). Branch-specific residuals keep a drag on
  its branch. A new mate that needs an older `auto` mate flipped is offered (`search_branch_changes`), never done silently.
  Conflicts name the mates (`blocked_by`, `conflicting`). This is SolidWorks' model (alignment, flip dimension, MateXpert).
- **Drag.** Only the mate-graph component of the grabbed part is solved (`discover_component`), warm-started from the
  client's last accepted poses (`reference`), with a local nearest-point solve per frame in Flutter
  (`client/lib/motion/local_retraction.dart`) between backend anchors. That is the standard design (in-process damped
  Newton, warm start, decomposition); the study says so and I agree.
- **Tolerance.** Near-redundant mates are accepted within 0.01 mm and shown amber (`mate_tolerance.py`).

### Gaps against SolidWorks / NX

1. **No rigid sets.** `build_group_model` gives every member 6 variables, including parts that are fully locked to each
   other. A sub-assembly is one member (so it does act as a block), but two top-level parts mated solid do not. SolidWorks
   and NX (the D-Cubed solver) merge mutually fixed parts into one rigid set before solving, and treat a sub-assembly as
   rigid unless it is made flexible. The owner's perception is correct.
2. **Scaling.** Backend `solve_group`: 3.4 / 15 / 46 ms for 1 / 3 / 8 members (smoothness study, F1c). The work is dense
   linear algebra on 6k variables, so it grows roughly with the cube of the group size. Flutter's local solve is off above
   8 members or 64 rows (`kLocalMaxMembers`, `kLocalMaxRows`; the gear-train demo is already over), VR's GDScript solver is
   not used at all (12 to 70 ms a frame). `search_branch_changes` (24 solves) and `alternatives` (4 solves) multiply the
   cost per preview. A 30-part bolted frame is one component today; with rigid sets it is one or two bodies.
3. **Preview is a ghost.** The part stays put and a translucent copy shows the result. SolidWorks moves the real component
   as a preview and restores it on cancel. VR has no preview when editing a mate.
4. **First guess.** 83.3% right first time on the bench (`mate-solution-choice-plan.md`, Phase 4). Same-facing distances
   (inset or overhang) 54%; parts started far from their orientation are the other large miss. Interference tie-breaks were
   measured and dropped; do not repeat them.
5. **Mate type is not guessed from the picks.** `_mateType = kMateTypes.first` in `part_screen.dart`; no inference was found
   by search in either client (not confirmed by running the apps).

### M0. Benchmark first (CAD backend; small; standard agent)

Extend the existing mate bench and `backend/tests/motion_scenes.py`:
- scaling scenes: a chain of N bolted plates (N = 5, 10, 20, 50), a frame of N bars with redundant mates, a mechanism
  (4-bar linkage) carrying a 20-part rigid payload;
- record `solve_group`, preview (with alternatives) and drag-anchor times, and how often the client model is refused by the
  caps;
- first-time accuracy scenes for M4: same-facing inset / overhang with realistic pick points, and upside-down starts.

Done when the numbers are in this doc's M0 section. Every later mates phase is judged against them.

### M1. Rigid sets (CAD backend; large; strongest agent, solver maths)

- **Detect.** After `analyze_model`, members whose relative motion is zero in every nullspace vector form a rigid set
  (exact; reuses the SVD basis already computed). A cheaper first pass: two members whose shared mates alone have rank 6.
  A set that contains a frozen member (fixed, or the `""` ref) is frozen. Cache per part revision; invalidate on any mate,
  fix or suppress change.
- **Reduce.** Solve with one 6-variable body per set; members keep a constant offset from the set's lead member. Mates
  inside a set drop out of the solve (they are checked once for `status`). Couplers, limits and pattern followers are never
  merged across.
- **Report.** `constraint_status` / the mates listing gain `rigid_set` (an id per occurrence). `GroupSolveResult.poses`
  still lists every occurrence, so existing clients keep working unchanged.
- **Constraint model v8** (emitted only when a set exists, like v4 to v7): members are the sets; each carries its followers
  as fixed offsets. Golden vectors in `docs/motion/vectors.json` via `tools/motion_vectors/generate.py`.
- **Branch search and alternatives** run on the reduced model.

Tests: the M0 scenes give the same poses as before to 1e-9; a locked pair reports one set; flexing a set (suppress one
mate) splits it; legacy fixtures (`table_top_frame`, the platform) keep their poses; the 50-plate chain solves in the time
of a 1 to 2 member group.

Risk: a set locked only by near-redundant mates (amber). Rule: `near` mates count as locking; a broken mate does not.

### M2. Client mirrors (Flutter and VR; medium; standard agent with the vectors as the guard)

- `local_retraction.dart` and `local_retraction.gd` read v8; followers of a set are posed from the lead member each frame
  (same shape as the v7 pattern followers).
- With sets, re-measure the caps: raise `kLocalMaxMembers` / `kLocalMaxRows` if the M0 scenes allow.
- VR: re-run `docs/local-retraction-benchmark.md` on the reduced models. If a typical group is now 1 to 3 bodies the
  GDScript solve may fit a frame; if not, VR stays on the projector (no change in behaviour). **Needs the owner on a
  Quest** for the final number.

### M3. Glide preview (Flutter and VR; medium; standard agent, UI)

No backend change: `preview-mate-solve` already returns every moved member.
- The real nodes animate (about 0.25 s, ease in-out) from the stored pose to the preview's `members` poses. A thin
  outline stays at the start pose. A new preview (type, value, Flip, Next solution) glides from the shown pose to the new one.
- Cancel glides back. Confirm stores (the atomic `POST /mates?solve=`) and the nodes are already there, so nothing jumps.
- The preview is always solved from the stored poses, never the displayed ones (the backend state does not change until
  Confirm), so picks stay valid.
- Couplers and limits place nothing: no glide.
- Flutter: replaces `matePreviewGhosts` in `part_viewport.dart`; a Controls setting "Mate preview: Move part / Ghost" keeps
  the ghost for phones where the moved part hides the picks. VR: `_run_preview` in `mates_tool.gd`; the Relax sandbox's
  `return_glide_s` tween is the pattern. **VR also gets the preview when editing a mate** (today: none).

Tests: widget / headless tests for start, replace, cancel and confirm; a failed preview leaves the part at its start.
Feel is not testable; the owner judges the glide time on the headset.

### M4. A better first guess (backend + both clients; medium; strongest agent for the rules, bench as the judge)

- **Type from the picks.** `preview-mate-solve` accepts `type: "auto"` and returns `suggested_type` with the solve: two
  round faces or circular edges, Concentric; two flat faces, Coincident; flat face and round face, none yet (Tangent is not
  a mate type); a circular edge on each side, Concentric plus Coincident offered as one action ("peg in hole", SolidWorks'
  SmartMate). Clients start on the suggestion and the user can still change it. Put the rule in the backend so the two
  clients cannot drift.
- **Pick points.** Clients send where on each face the pick landed (`pick_points`, local to each occurrence) and, flat app
  only, the view direction. Used only as a tie-break for a Closest branch: for a same-facing distance choose the side that
  brings the two pick points nearer; for alignment prefer the root that turns the picked face towards the other part.
  Must show a net gain on the M0 bench with zero harmed cases, or it does not ship (the Phase 4 rule's standard).
- Target: 83% to 90% or better overall; same-facing distance 54% to 75% or better.

### M5. Show rigid sets (Flutter and VR; small; standard agent)

- Tree: parts in one set share a bracket and read "Moves with <lead>"; fully fixed sets read as fixed.
- Dragging any member of a floating set moves the set (falls out of M1); a short outline on the whole set at grab says why.
- VR: the same outline pulse the mate highlight uses (`highlight_mate`).

### Not in this plan

Tangent, path, cam and belt mates (`gears-and-motion-plan.md` §5a); flexible sub-assemblies; collision detection while
dragging.

---

## Part 2: Shared storage

### What is there

- Files are client-owned: a project folder (`client/lib/storage/*`, `ProjectRoot`), one Part per file, relative-path links
  (`Occurrence.external_ref`), a moved-file lookup by part id (`file_lookup.py` and its mirrors). VR has its own project
  folder (`scripts/project_folder.gd`) with Quest storage limits (All files access needed for files from other apps).
- The backend has no file system, no persistence and one in-memory `Document` per `X-Document-Session`
  (`backend/app/document/store.py`). `docs/assembly-scope.md` decisions #4 and #6 lock that in; this part reopens them.
- The roadmap already names the first step: a version check on write.

### Why a service beside the backend (D3)

| Option | Set-up for the user | Platform limits | Offline | Verdict |
|---|---|---|---|---|
| Storage service beside the backend | Nothing new: it rides on the server and the pairing QR code they already use | None: plain HTTPS from every client, no Android storage permission | Local cache + queue | **Chosen** |
| Cloud drives in the app | A sign-in per device per provider; awkward on a Quest | Each provider needs its own app registration and code; no shared folders on Quest | Needs the same cache anyway | Later, behind the same interface |
| Browser relay | Drives the provider's web page | Fragile, no sync | None | No |

Google Drive / OneDrive / a NAS still work on day one: the store keeps plain files in a plain folder tree, so the server's
folder can be a synced drive folder or a network mount.

### S0. Scope and spikes (small; strongest agent for the scope doc)

- `docs/shared-storage-scope.md`: supersedes assembly-scope #4 and #6 explicitly; the API below; the conflict rules.
- Decide: own container (like `browser-relay/`) or a router in the backend. **Recommended: own small container** in the same
  compose file, own key, so a long upload never competes with OCCT and the backend stays stateless.
- Spike (owner, Quest): where `user://` lives and how much space the cache may take.

### S1. Project store service (CAD repo, new `project-store/`; medium; standard agent)

- `GET /projects`, `GET /projects/{id}/tree` (path, size, content hash, version, modified by, root part id).
- `GET /files/{path}` with `ETag`; `PUT /files/{path}` with `If-Match` (**a stale save is refused with 409**, the roadmap's
  first safeguard); `If-None-Match: *` for a new file; delete and rename.
- Keeps the last N versions of each file (a refused or mistaken save can be recovered).
- `GET /changes?since=<cursor>`: what changed, for sync after being offline.
- A part-id index of the tree, so the moved-files rule works against the server.
- Advertised by the backend's `/health` `api_features` and carried in the pairing code (`&s=<store>&sk=<key>`,
  `docs/vr-headset-pairing.md`), so a paired client finds it with no typing.
- No locks (the long-term vision doc rules out PDM-style locking): optimistic version check, and on conflict the user
  picks Keep mine (as a new version) / Take theirs / Save mine as a copy.

### S2. Flutter (medium to large; standard agent)

- A `RemoteStorageService` behind the existing `StorageService` interface, so Open / Save / Save All / the composer are
  unchanged above it.
- Local cache of every opened file (`file_cache.dart`), a queue of unsent saves, a sync state per file (synced, to send,
  conflict) and a status chip. Offline: open from the cache, save to the queue, sync on reconnect with the version check.
- File menu: "Server projects" next to the local project folder; "Copy this project to the server".

### S3. VR (medium; standard agent)

- `project_folder.gd` gains a server source: Files lists server projects; the cache lives in `user://` (no All files access
  needed, which removes most of the Quest storage friction).
- Same queue and conflict rules as S2. The landing shows what is waiting to sync.

### S4. Hardening (small to medium)

Interrupted uploads, a server that comes back mid-save, two devices offline on the same file, large STEP imports, cache size
limit and clean-up, thumbnails for the VR Rooms and landing tiles. Tests run against a store that is switched off and on.

---

## Part 3: Live sessions, observers and the phone app

### What is there

Nothing built. The idea is in `DIDSA-VR/docs/vision-brief.md` ("Multiplayer and environments", "Phone observer").
`docs/vr-recon-2026-09-24.md` §5 lists what the backend lacks: session separate from document, a push channel, identity.
D2 (one presenter) removes the hardest of those, concurrent edits.

### Shape

```
Presenter (Quest / PCVR) ── REST ──> CAD backend (the presenter's document session, as today)
        │                                  ▲ read-only, by a session token
        └── WebSocket ──> Session hub <── WebSocket ── Observers (Quest, phone)
                          (presence, model state, marks, voice)
```

- The presenter works exactly as now. The app also publishes what changed to the hub.
- Observers fetch the same glb from the CAD backend **read-only** using a token the hub hands out, then apply the hub's
  stream: occurrence poses (20 to 30 Hz during a drag), visibility, appearance, shown scene, section planes, the model's
  place and scale, and a "geometry changed, refetch" signal after a design-table edit.
- A late joiner gets a snapshot, then the stream.
- Presence at about 15 Hz: head, hands or cursor, laser end, name, colour, role.
- Everything goes out through the same tunnel as the backend (`wss://`), so remote observers need no new network set-up.

### P0. Scope and three spikes (strongest agent for the protocol; spikes need the owner's devices)

- `docs/live-sessions-scope.md`: message list, roles, the read-only token, what is never sent (API keys, files).
- **Voice spike.** Microphone to Opus to WebSocket to playback, on a Quest and an Android phone. Godot has no Opus encoder
  reachable from GDScript, so voice uses **one more add-on exception, allowed by the owner (D9)**: a small Opus
  GDExtension, pinned and fetched by a `tools/` script like the OpenXR Vendors plugin, and noted in DIDSA-VR's `CLAUDE.md`.
  The spike picks the add-on (it must build for Quest and phone arm64 and for desktop) and checks microphone capture on
  Android in Godot 4.7, which was not verified when this plan was written; it settles both before P3 is sized.
- **Cardboard spike.** Gyroscope camera, side-by-side stereo with lens distortion, 60 fps on a mid-range phone with a real
  assembly and today's shaders.
- **`main.gd` split audit.** Which of its 2,457 lines are viewing (scene, glb, environment, clip) and which are Quest input;
  the list of what a view-only build must not load.

### P1. Session hub (CAD repo, new `session-hub/`; medium to large; strongest agent)

- Rooms with a short join code and a QR code; roles presenter / observer; display name and colour.
- Relays presence, model state, marks and voice frames; keeps the latest snapshot for late joiners; no geometry.
- Backend: a read-only token that lets another client `GET` the presenter's assembly mesh / glb and tree, and a document
  change counter so observers know when to refetch. No write route accepts the token.
- Tests: a scripted presenter and two scripted observers; late join; presenter drops and returns.

### P2. VR Host and Join (VR; large; standard agent, owner testing with two devices)

- Home monolith: **Host Session** (shows the join code and QR) and **Join Session** (type or scan). The same app; the role
  decides which tools exist. An observer has no mates, design table or save.
- Avatars (D6): a headset shape, two controller shapes with the laser, a name tag that faces the viewer, one colour each.
- Live model state from the presenter, smoothed between updates.
- Go to presenter, Follow presenter (rides their viewpoint, with a comfort vignette), and the presenter's Gather everyone.
- **Scale (decide here):** recommended v1 is one shared model place and scale set by the presenter; presence is sent in
  model space so avatars stay correct. A private scale for an observer is a later step.

### P3. Voice (hub + VR; size set by the P0 spike)

Open mic with a mute, push-to-talk option, voice placed at the speaker's avatar with a floor so far people stay audible,
per-person volume, the presenter can mute all. The hub relays frames; it does not mix.
**First usable session release = P1 + P2 + P3 (D5).**

### P4. Observer tools (VR; medium; standard agent)

- **Drone cursor.** A small coloured, named marker the observer flies through the model. It selects what it touches or
  points at, with the existing breadcrumb (Face, Body, Part, sub-assembly) to choose the level.
- **Own view (default):** colour, hide, isolate, see-through, section, measure, pull a part out (an exploded look). Uses the
  Appearance tool, section tool and Relax sandbox code paths, with nothing sent to the backend.
- **Share (D7):** shows the current selection and its colour to everyone as a temporary mark with the observer's name; the
  presenter clears marks. Also Ping (a pulse at a point), Raise hand, Look here (asks the presenter to come).
- **Reset my view** puts everything back to what the presenter shows.

### P5. Phone (Cardboard) observer (VR repo, second Android export; large; standard agent + owner's phone)

- OpenXR off; the P0 camera rig; a "magic window" mode (no viewer, the phone is a window you turn) as the fallback and for
  people who get sick.
- Bluetooth controllers through Godot's joypad input. Mapping, also on a help card in the app:

| Control | One-handed wand (stick, A, B, trigger) | Full gamepad adds |
|---|---|---|
| Move yourself | Stick (forward / back / strafe, in the direction you look) | Left stick; right stick turns in snaps |
| Drone cursor | **Hold the trigger**: the stick flies the cursor, your gaze steers it | Right stick flies it at any time; triggers raise / lower it |
| Select | A at the cursor (or at your gaze with no cursor out) | Bumpers step the breadcrumb level up / down |
| Back / menu | B: back; hold B: the tool ring | D-pad: tool ring directly |
| Quick tools | In the ring: Colour, Hide, Isolate, Share, Ping, Go to presenter, Reset | X colour, Y hide, Start mute, Select reset view |
| No controller | Gaze and dwell on a small menu: Follow presenter, Go to presenter, Mute | |

- Lighter rendering for phones (simpler materials, MSAA off, the LOD work in `docs/lod-strategy/`).

### P6 and P7 (later)

P6: the flat app joins as an observer (a 2D view with the same marks and voice), then hosts. P7: reconnects, more than six
people, per-device keys (pairing version 2 in `docs/vr-headset-pairing.md`) so one person can be removed.

---

## Order and dependencies

```
M0 → M1 → M2 ─┐
      └→ M5   ├─ mates done
M3 (any time) │
M4 (after M0) ┘
S0 → S1 → S2 ─┬→ S4
          S3 ─┘
P0 (spikes can run during S) → P1 → P2 → P3 → P4 → P5
```

- M3 and M4 do not depend on M1; they can go to a second agent while M1 is in review.
- S1 before P1 is not a hard dependency (observers get geometry from the presenter's backend session, not from files), but
  the presenter needs S2 / S3 to open the same project on every device, so storage stays second (D1).
- P0's spikes need only the owner's devices and can run while storage is being built.

## Which agent for which phase

| Kind | Phases | Why |
|---|---|---|
| Strongest model, high effort | M1, M4 rules, S0, P0 scope, P1 | Solver maths, protocol and data-model decisions that later phases build on |
| Standard model | M0, M2, M3, M5, S1 to S4, P2, P4, P5 | Client and service work with a clear spec and golden vectors or tests as the guard |
| Needs the owner's hardware | M2 (Quest timing), M3 (glide feel), S0 spike, P0 spikes, P2, P3, P5 | Headless tests cannot judge feel, audio or frame rate |

Each phase starts with its own short kickoff prompt naming this doc, the phase id, the files listed there and the tests
that must pass, as `docs/motion/s5-s6-kickoff-prompts.md` did.
