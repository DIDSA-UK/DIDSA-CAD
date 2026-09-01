# LOD Strategy — coordination status

Tracking doc for a general "level of detail" (LOD) capability: show a fast, simplified
placeholder for an expensive Part/Feature while the real, detailed geometry builds, with a
toggle between simplified/full detail, and correct handling of downstream operations (e.g. a
Boss/Cut applied while a parent Feature is still coarse).

Motivating case: a spiral `BevelPairFeature` build took 12+ minutes and timed out on a phone.
The algorithmic root cause (an expensive meshing-phase search) was already fixed on `main`
(PR #167 warm-start/tiered search, PR #170 preview-phase fix, PR #172 end-cap-flattening
robustness — see `docs/status.md`'s 2026-08-26 entries). LOD is a *general* follow-on
capability, not a re-litigation of that fix: even a correctly-fast bevel pair is still slower
than an instant placeholder.

This doc is the durable state for a multi-session coordination effort — a coordinator session
(no direct implementation) plans, dispatches implementation to fresh child sessions, and
tracks their branch/PR/state here rather than relying on its own conversation memory. Update
this doc as you go, not just at the end.

Coordinator branch: `claude/lod-strategy-coordination` (this branch carries only this tracking
doc and any design-doc content — no implementation).

---

## Status at a glance

| Item | State | Branch / PR | Notes |
|---|---|---|---|
| Phase 0 investigation | complete | — | see findings 1-4 below |
| Design doc (Phase 1) | approved | `01-design.md` | user approved 2026-08-27; also approved building Phase 2 (real cancellation/disconnect-resilience) as a separate, sequenced follow-on — see below |
| Phase 1 chunk 1 (body_cache GET-list fix) | **merged to `main`** | branch `claude/new-session-yihda3`, [PR #173](https://github.com/DIDSA-UK/DIDSA-CAD/pull/173) | Code-reviewed (found and fixed a real lockout regression), merged 2026-08-27. |
| Phase 1 chunk 2 (coarse-mesh mechanism + gear-family builders) | **merged to `main`** | branch `claude/lod-coarse-mesh-gear-family`, [PR #174](https://github.com/DIDSA-UK/DIDSA-CAD/pull/174) | Two code-review rounds found and fixed real validation gaps in the new coarse-preview endpoints; branch merged forward against `main` twice (PR #172, then PR #173) to reconcile cross-cutting `bevel.py`/`router.py`/`extrude.py` changes, one real semantic conflict resolved by hand. Full suite 1882/1882 passed pre-fix-up (real OCCT); the fix-up and both merge-forward passes were verified by code review + syntax check only in this coordinator's sandbox (no `pythonocc-core` available here), merged 2026-08-27. Foundational plumbing now available on `main` — chunks 3/4/5 unblocked. |
| Phase 1 chunks 3+4+5 (Pattern/Loft coarse builders + client toggle) | **merged to `main`** | branch `claude/lod-pattern-loft-client`, [PR #175](https://github.com/DIDSA-UK/DIDSA-CAD/pull/175) | Pattern/Loft coarse builders + coarse-preview endpoints + instance-count cap (backend, real-OCCT verified: 1909→1919, zero regressions); client mesh-override generalization, per-Feature pending/pinned state, both flows wired (create-time for Pattern/Loft only — the five gear-family types' own create flow lives in `GearDesignScreen`, which has no `PartViewport` mounted; re-open flow wired universally), Feature-tree badge + pin toggle (real Flutter, `flutter analyze` 0 issues, `flutter test` 1453 passed/0 failed). Coordinator review found the coarse-tier fetch firing on every one of ~38 `_refreshMesh()` call sites instead of just Part re-open — fixed in a clean fix-up (verified: real Flutter re-run + a real backend suite re-run to confirm the client-only fix didn't touch backend state). Merged 2026-08-27. |
| **Phase 1 (all 5 chunks) — complete** | — | PRs [#173](https://github.com/DIDSA-UK/DIDSA-CAD/pull/173) [#174](https://github.com/DIDSA-UK/DIDSA-CAD/pull/174) [#175](https://github.com/DIDSA-UK/DIDSA-CAD/pull/175) | The full v1 LOD experience (per `01-design.md`) is on `main`: coarse placeholders for Gear/BevelGear/BevelPair/GearChain/PlanetaryGear/Pattern/Loft, served on Part re-open and (for Pattern/Loft) at create-time, with a Feature-tree badge and persistent pin-to-coarse toggle. Every merged chunk went through at least one real coordinator code-review round; three found and fixed real issues before merge (a lockout regression, three validation gaps, and a refresh-scope design deviation) — none were hypothetical, all were confirmed via a concrete failure scenario before dispatching a fix-up. |
| Phase 2 design pass | **approved** 2026-09-01, see `02-phase2-design.md` | — | Cancellation + reconnect for `BevelPairFeature`/`PlanetaryGearFeature`'s genuine long-tail builds — no general async infra, everything else keeps its synchronous contract. Re-checked against `main` before dispatch: nothing since Phase 1 touches the relevant files. |
| Phase 2 chunks 1+2 (`planetary_gear.py` pooling + job store/job-mode endpoint for `BevelPairFeature`) | **merged to `main`, CI red — fix-up in progress** | branch `claude/lod-phase2-planetary-and-bevel-jobs`, [PR #179](https://github.com/DIDSA-UK/DIDSA-CAD/pull/179) | Two coordinator-dispatched attempts errored out (archived, not investigated per the user's instruction); folded into one prompt (confirmed independent, same toolchain, no double-bootstrap risk); user started it manually and merged directly. `ProcessPoolExecutor` pooling added to `planetary_gear.py`; new in-memory job store + real mid-build cancellation + 3 new routes for `BevelPairFeature`. Implementing session's own real-OCCT run: 1919→1933, "zero regressions" claimed — **but the ARM64 leg of `main`'s own post-merge CI is red** (run [33504260119](https://github.com/DIDSA-UK/DIDSA-CAD/actions/runs/33504260119/job/99844455696): `1 failed, 1932 passed`), a genuine race the x86_64-only sandbox verification didn't catch. Diagnosed directly (see below) and a fix-up dispatched. |
| Phase 2 chunk 3 (extend job-mode to `PlanetaryGearFeature`) | prompt handed to user | branch `claude/lod-phase2-planetary-jobs` (base: `main`, once chunks 1+2's CI is green) | Depends on chunks 1+2 — now merged, but should wait for the cancel-vs-fail race fix-up to land first, since chunk 3 extends the exact classification logic that's currently broken. |
| Phase 2 chunk 4 (client: job-mode create/poll/cancel, resume-on-reconnect) | prompt handed to user | branch `claude/lod-phase2-client-jobs` (base: `main`, once chunks 1+2's CI is green) | Same caution as chunk 3 — the `BevelPairFeature` job endpoint it wires against currently misreports cancellation as failure on a real (if racy) path; wait for the fix-up. |

---

## Phase 0 — investigation (dispatched 2026-08-26)

Four parallel research tasks, none of which write implementation code:

1. **Gear preview architecture** (in-process general-purpose agent) — deep read of
   `/document/gear/preview` and every `_gear_preview_*` handler in
   `backend/app/document/router.py`, whether/how the preview math is duplicated from the real
   Feature-construction modules, how the client renders it, and an assessed opinion on whether
   this 2D schematic-preview pattern can generalize into a real coarse-3D LOD mechanism or
   whether LOD needs something structurally different.
2. **Backend Feature-cost & `body_cache.py` survey** (in-process general-purpose agent) —
   confirms (or refutes) "zero async infra anywhere in this backend"; explains precisely what
   `body_cache.py` does and does not solve (repeat-call incremental rebuild, NOT first-build
   cost); structural (non-timed) survey of which Feature-construction modules
   (`gear.py`, loft, pattern, `boolean.py`, `split.py`, `surface.py`, `bevel.py`,
   `bevel_pair.py`, `gear_chain.py`, `planetary_gear.py`, plain extrude) look expensive from
   code structure alone (loop counts over user-controlled parameters, BRepAlgoAPI/loft
   operation counts).
3. **Client viewport3d / mesh / Feature-tree state** (in-process general-purpose agent) — how
   a Body's mesh reaches the client today, whether the client's state model has any
   per-Feature granularity, what the existing "slow build" UX (`_BuildingGeometryOverlay`,
   `GearDesignScreen`'s build hint) actually represents state-wise, and what's missing to
   support a real three-state (coarse-only / full-detail / toggled-to-coarse) per-Feature UI.
4. **Real OCCT profiling of untested candidates** (remote child session, research-only, no
   commits) — bootstraps `backend/environment.yml`'s conda env and measures real wall-clock
   time for `LoftFeature`, `PatternFeature` (at increasing instance counts), and the
   Boolean-family (`boolean.py`/`split.py`/`surface.py`) at realistic parameters. Already-known
   numbers (herringbone `GearFeature` ~6.4s, spiral `BevelPairFeature` up to ~193s worst-case
   pre-fix) are not re-measured.

Findings will be appended below as each completes, then synthesized into a design section.

### Finding 1 — gear preview architecture (complete)

`/document/gear/preview` (`backend/app/document/router.py`, `_gear_preview_*` handlers) is
confirmed 2D-only, zero-OCCT (`gear_math.py`/`gear_chain_math.py`/`bevel_math.py` — no
`OCC.Core.*` import anywhere in those modules), built on a repo-wide documented convention
(`docs/gear-design/00-conventions.md:53-60`, "OCCT-free `*_math.py` vs. OCCT-dependent
construction module" split, per Feature type).

**Verdict: this pattern does not generalize to a real coarse-3D LOD placeholder.** Three
structural reasons:
1. **2D-only by construction** — every preview response is `list[tuple[float,float]]` outline
   points; no code path produces a 3D shape/mesh. `12-spiral-bevel-gear.md:433-443`'s own
   scope-down (spiral curvature is "inherently an azimuthal/out-of-plane property" the
   schematic structurally can't show — direct the user to the real 3D solid instead) already
   makes this exact point for a narrower case.
2. **Pre-commit-only by construction** — `GearDesignScreen` is popped/replaced by `PartScreen`
   the moment Create/Save succeeds (`gear_design_screen.dart:460`, `:508-510`); preview and
   real geometry are never simultaneously mounted. LOD needs the placeholder to occupy the
   *same viewport slot* as the eventual real geometry and be toggled after the real Body
   exists — the opposite lifecycle.
3. **Gear-math-specific precondition doesn't hold for other Feature types** — `loft.py`,
   `pattern.py`, `boolean.py`, `split.py`, `surface.py`, `sweep.py`, `revolve.py`, `extrude.py`
   all import `OCC.Core.*` directly with no OCCT-free math sibling; there is no closed-form
   analytic substitute for "what will a loft/boolean/pattern result look like" the way an
   involute tooth outline is closed-form. Real LOD for these needs an actual coarse
   `TopoDS_Shape` from a **lower-fidelity pass through real OCCT**, not a 2D stand-in.

**Carried forward as real prior art**: (a) the cheap-vs-expensive module-split *category* of
idea, applied on the 3D side instead of via 2D math duplication; (b) a concrete drift-bug
lesson — the 2026-08-25→2026-08-26 meshing-phase preview bug (PR #170) is first-party proof
that a duplicated "fast path that must visually track a slow path" silently drifts unless it
either calls into the real shared logic or is pinned against it by a test; (c) the
debounce-cheap-path/settle-expensive-path UX cadence (`08-entry-screen-and-preview.md:22-27`)
is a reasonable rhythm to reuse conceptually for "placeholder now, swap in real geometry once
built."

### Finding 3 — client viewport3d / mesh / Feature-tree state (complete)

**Mesh delivery today**: `GET /parts/{part_id}/mesh` (`router.py:5114-5203`) returns one
`BodyMeshResponse` per Body (already per-Body, not one opaque blob), with a `source:
"placeholder"|"computed"` flag — but that placeholder is **Part-level all-or-nothing** (a
fixed 10×10×10 box shown only while the whole Part has zero geometry), not a per-Feature
concept. A `quality: float` slider maps to OCCT tessellation tolerance, but it's one global
value applied to every Body on every fetch — no per-Feature/per-Body quality today.
`PartScreen` (`part_screen.dart`) holds mesh state as plain `StatefulWidget` fields
(`_bodies: List<BodyMeshDto>`, no Riverpod/Provider), replaced wholesale on every
`_refreshMesh()`.

**Reusable precedent, better than expected**:
- `PartViewport` already has real per-Body scene-node granularity (`_meshNodes`/`_edgesNodes`
  maps keyed by `body_id`, `part_viewport.dart:874-886`) — a Body is a distinct
  renderable/removable node, not merged into one mesh.
- `previewOverlayBodyId`/`previewOverlayMesh` (`part_viewport.dart:546-566`) is a **working,
  in-production single-slot mesh-substitution mechanism** — during Fillet/Chamfer editing, one
  Body's rendered mesh is swapped for an alternate while the rest stay unchanged. Structurally
  the same shape an LOD "show coarse mesh for Body X" swap needs, just hardcoded to one Body
  at a time (would need generalizing to a map).
- `FeatureDto.hasLostReference` (a plain backend-sourced bool) already drives a Feature-tree
  badge (glyph overlay + amber subtitle, `feature_tree_panel.dart:704-737`) — the exact
  template for a "coarse stand-in" badge: add a field, add a Stack child/subtitle branch, zero
  new state machinery needed for the tree-row display itself.
- `baseFeatureId()` (`body_naming.dart:59-61`) is the existing, correct Body→Feature mapping
  (handles the multi-solid `#N` split case) for tying a per-Feature LOD choice to the Bodies
  it must apply to.
- `_hiddenFeatureIds`/`_rollbackExcludedFeatureIds` (`part_screen.dart:581,613`) are the direct
  precedent for "a `Set<String>` of Feature ids = one piece of client-only per-Feature state,
  threaded through `_refreshMesh`" — the pattern a coarse/full toggle-override set would
  follow.

### Finding 2 — backend Feature-cost & `body_cache.py` survey (complete)

**Zero async infra, confirmed independently.** Whole-tree grep: exactly one `async def`
(`session_context.py:45`, a per-request contextvar dependency, unrelated to background work);
zero Celery/RQ/BackgroundTasks/websocket/asyncio-task use anywhere. One real nuance:
`bevel_pair.py` already uses `ProcessPoolExecutor` (`spawn` context, BREP-bytes IPC) for
in-request parallelism (member builds + phase-search grid scan) — this shortens wall-clock via
multi-core use but the HTTP handler still blocks until every worker finishes; no early return,
no polling, no cancellation. Worth knowing as a reusable *pattern* (subprocess isolation via
BREP-byte pickling) if background-build infra is ever built, but it is not that infra itself.

**`body_cache.py` solves repeat-call cost only, confirmed precisely.** A generic, per-Part
checkpoint chain (Feature-id sequence + `feature_fingerprint` + Body snapshot after each step
from the *last* call); a later call only re-runs the diverging suffix. With an empty/no-match
cache it falls straight through to a full rebuild — **zero benefit on a first build**, exactly
as expected.

**Critical structural finding, not previously known: body_cache is bypassed on nearly every
real interaction with a Part containing an expensive Feature type, not just the first build.**
Every "fresh entry point" resolver (`resolve_gear`, `resolve_loft`, `resolve_bevel_gear`,
`resolve_bevel_pair`, `resolve_gear_chain`, `resolve_split`, `resolve_pattern`, `resolve_sweep`,
`resolve_revolve`) self-excludes its own not-yet-persisted feature id
(`all_excluded = excluded_feature_ids | {feature.id}`), which is therefore always non-empty —
forcing the *uncached* `compute_part_bodies` branch (full rebuild of every prior Feature) on
**every single create/update call**, regardless of body_cache's existence. Worse: `GET
/parts/{id}/features` (the plain feature list) re-triggers a full uncached rebuild too, for
every Gear/Loft/BevelGear/BevelPair/GearChain Feature in the Part — `_feature_response`
dispatches these five types to helpers that recompute `warnings` via the same uncached
`resolve_X` call even on a plain list fetch (`router.py:771,929,827,866,958`). For
`BevelPairFeature` specifically this means **loading the feature list re-runs the entire
spiral-bevel-pair build** (member builds + phase search) every time. `excluded_feature_ids`
(true B4 rollback) and `/gear/preview` are confirmed as two fully separate code paths sharing
nothing.

**Ranked structural cost survey** (no runtime numbers available in this sandbox — code-shape
only; real numbers pending from the parallel OCCT-profiling child session):
1. **`PatternFeature` with `merge=FUSE_INTO_ONE` (or `tool_feature_id`) and a large instance
   count — highest-risk, least-guarded.** Structurally identical to the already-known-expensive
   "sequential `BRepAlgoAPI_Fuse` chain" shape, but applies to an *arbitrary* (possibly
   expensive) child Body, and **no upper bound exists anywhere** on `count_1`/`count_2`/
   `count_angular` (`router.py:1400-1485` — lower bounds only). A user can request e.g.
   `count_1=1000,count_2=1000,merge=true` today with no server-side rejection.
2. **`PlanetaryGearFeature` with a large `planet_count` — real, unoptimized.** Builds
   `2 + planet_count` full gear solids **fully serially**, no parallelization — the exact shape
   `bevel_pair.py` diagnosed and fixed with `ProcessPoolExecutor` for its 2-member case, never
   applied here. No `planet_count` cap found. No dated status.md entry indicates it's ever been
   profiled.
3. **`BooleanFeature` — bounded by existing Body count, not a free integer field, but its
   `M × N` nested-loop over `target_body_ids × tool_body_ids` has no upper bound either.**
   `split.py`/`surface.py` by contrast are structurally bounded (constant op count regardless
   of input) — genuinely low risk.
4. **`GearChainFeature` with many stages — plausible but self-limiting** (UI-driven one-stage-
   at-a-time authoring, unlike Pattern's single free integer field).
5. **`LoftFeature` — lower cost-confidence, but flagged as genuinely untested for correctness**
   (module docstring repeatedly self-flags as never run against real `pythonocc-core`).

**Genuinely missing (confirms Finding 2's async-infra conclusion from the client side too)**:
today's only "slow build" UX (`PartScreen._runGuarded`'s delayed `_BuildingGeometryOverlay`,
and `GearDesignScreen`'s unconditional build hint) is **purely cosmetic busy/idle** — one
global bool for the whole screen, zero association with which Feature, zero notion of
"coarse result available now, full result still pending." No per-Feature/per-Body coarse-vs-
full wire tag exists; no background-build signal exists (corroborates the synchronous-backend
finding independently, via a `document_api_client.dart` grep: zero `job_id`/`task_id`/
`status`/`async` vocabulary anywhere). A real toggle needs: (1) a per-Body/Feature "coarse" tag
in the mesh response, (2) either real backend async infra or a client-side illusion (fetch
coarse fast, background-refetch full, swap on arrival — fits the existing synchronous request
model with no backend architecture change), (3) a small new per-Feature state container in
`PartScreen` (map/set, following the `_hiddenFeatureIds` convention), (4) generalizing the
single-slot preview-overlay mechanism to a map, (5) a new Feature-tree tap target (both
`onTap`/`onLongPress` are already claimed).

### Finding 4 — real OCCT profiling of untested Feature types (complete, partial detail)

Dispatched to a remote child session (`session_01PuP2HbS9mtXVAwafYzR9fe`) that bootstrapped a
real `pythonocc-core` conda env and profiled `LoftFeature`, `PatternFeature`, and the
Boolean-family. **Limitation, disclosed rather than glossed over**: this coordinator session
has no tool that reaches a Claude Code Remote session's full transcript (cross-session
`SendMessage` returned "not reachable"; `get_session` surfaces only a post-turn summary, not
the full report) — so only the session's own terse verdict was recoverable:

> "profiled 5 Feature types; LOD justified for gears/Patterns/Lofts only"

This is directionally decisive and matches Finding 2's structural prediction exactly
(Boolean-family confirmed NOT LOD-worthy; Pattern and Loft confirmed real candidates alongside
the already-known gear family) — treated as sufficient to design against. The full numeric
detail (exact parameters/timings/dominant OCCT ops) lives only in that child session's own
transcript and was not pulled into this doc. If precise numbers are needed later (e.g. to
calibrate a coarse-eligibility threshold), a future session with CCR transcript access, or the
user pulling it directly, should retrieve it — not treated as a blocker for the design below,
since the design's coarse-eligibility list is set structurally/by Feature-type rather than by
a tuned numeric threshold.

---

## Phase 0 synthesis — design proposed

See **`01-design.md`** for the full design: no new async/job-queue infrastructure needed;
coarse geometry is a real (cheap) OCCT primitive per Feature-type family (cylinder for gears,
cone for bevel gears, skip-fuse for Pattern, 2-section loft for Loft), computed on-demand,
never persisted, never entering the Feature graph — so no downstream-Feature-on-coarse-parent
correctness question exists by construction. Client work generalizes existing per-Body
mesh-swap/badge plumbing rather than inventing new state machinery. Five proposed
implementation chunks, listed in `01-design.md` §8.

**Approved 2026-08-27.** The user also asked what Phase 2 (real cancellation + disconnect-
resilience for the genuine long-tail build, e.g. a still-slow symmetric spiral bevel pair)
would concretely add beyond Phase 1's placeholder — see the chat exchange this doc doesn't
reproduce; short version: cancellation and disconnect-resilience are worth building, UI
concurrency and fine-grained progress are not (given the single-user self-hosted deployment
context). Decision: **keep Phase 1 and Phase 2 as separate, sequenced efforts, not folded
together** — different risk classes (Phase 1 is a narrow addition; Phase 2 is this backend's
first-ever async/job pattern), and Phase 2 genuinely depends on Phase 1's client-side
coarse/pending state rather than the reverse. Phase 1 chunks 1-2 dispatched now; a Phase 2
design pass is running in parallel and will come back for its own approval before any Phase 2
implementation is dispatched.

### Phase 2 research finding — disconnect was never actually losing work

The Phase 2 research pass (dispatched 2026-08-27) found something that changes the framing of
"disconnect resilience": every create/update route is a plain sync `def` with no
disconnect-checking anywhere in the codebase, so a dropped client connection does NOT stop an
in-flight build — the server thread runs to completion and persists the Feature regardless.
The client's own 720s `spiralBevelPairRequestTimeout` is itself a self-inflicted disconnect on
a long build, and the server still finishes and succeeds after it fires. So the real Phase 2
gap is (a) a cheap channel back for a reconnected client to learn the outcome (today, the only
fallback is `GET /features`, which — absent chunk 1's fix — re-runs the entire build just to
answer that question), and (b) genuine mid-build cancellation, a real gap with no existing
analogue. Full design: `02-phase2-design.md`.

**Approved — chunks 1+2 dispatched and implemented, see "Dispatched implementation sessions" below.**

---

## Open questions / cross-cutting decisions

Resolved by design rather than left open (see `01-design.md` §7): retroactive-vs-new-Parts-only
doesn't arise (coarse geometry is never persisted, so it applies uniformly); the persistent
toggle is included in v1 since it's a cheap marginal add-on once the pending-state plumbing
exists. No other open, user-must-decide product question was found.

---

## Dispatched implementation sessions

### Coordinator finding — `main`'s post-PR#179 CI is red (ARM64), real bug not flakiness

PR #179 (Phase 2 chunks 1+2) was merged directly by the user, outside this coordinator's usual
pre-merge review. Checked `main`'s own CI after the fact (something not previously available —
first time this coordination effort has had real GitHub Actions signal, versus this session's
own sandbox lacking `pythonocc-core`): the `Backend - build and test` workflow's ARM64 matrix
leg failed on the merge commit (`6d729fd`, run
[33504260119](https://github.com/DIDSA-UK/DIDSA-CAD/actions/runs/33504260119/job/99844455696)),
`1 failed, 1932 passed`. The x86_64 leg was cancelled as a side effect (not an independent
pass), so this specific race is unconfirmed there — but nothing about its cause is ARM-specific.

**The failing test**: `test_bevel_pair_jobs.py::test_cancel_during_an_active_phase_search_pool_
kills_workers_and_never_persists` — cancels a genuinely in-flight job and expects
`JobStatus.CANCELLED`, got `JobStatus.FAILED` with `error: [Errno 9] Bad file descriptor`.

**Root cause, diagnosed by reading `job_cancellation.py` directly**: `CancellationToken.track()`
only converts an exception to `JobCancelled` (→ `CANCELLED`) if it surfaces *inside* its own
`with track(executor):` scope. But `cancel()`'s `_kill_pool_workers()` already calls
`executor.shutdown(wait=True, cancel_futures=True)` from the cancelling thread, and the build
thread's own *outer* `with ProcessPoolExecutor(...) as executor:` block will *also* call
`.shutdown()` on its exit once `JobCancelled` propagates out of `track()`'s narrower scope. Two
threads tearing down the same pool's IPC file descriptors concurrently is exactly the shape
that produces a raw `OSError: Bad file descriptor` — and if it surfaces during the *outer*
context manager's own exit (after `track()`'s `except` window has already closed), it
propagates uncaught as a genuine "unexpected failure" instead of being recognized as an
expected side effect of cancellation. A real, reproducible race in the classification logic,
not test flakiness or an environmental fluke — confirmed via the actual pytest traceback, not
assumed.

Coordinator-dispatched attempt (`session_0125TpzU45UYuE2kL94JTaeb`) errored out — archived, not
investigated per the user's own instruction (established pattern this whole effort). Prompt
handed to the user as a file 2026-09-01; they're starting it directly on branch
`claude/lod-phase2-cancel-race-fix`. The fix should be architectural — `jobs.py`'s job-runner
should check `cancellation.is_cancelled()` as the authoritative FAILED-vs-CANCELLED signal,
not rely solely on catching `JobCancelled` from one narrow scope, so any exception flavor
surfacing after a cancel request classifies correctly regardless of which layer/thread produces
it. Chunks 3/4 (both build directly on this classification logic) should wait for this fix-up
to land before starting.

### Phase 1 chunk 1 — body_cache GET-list fix (branch `claude/new-session-yihda3`)

Landed the fix this doc's own "Status at a glance" table and §6 describe: `app.document.
router`'s five `_X_feature_response` helpers (Gear/BevelGear/BevelPair/Loft/GearChain) no
longer recompute a plain `GET /parts/{id}/features` read's `warnings` by calling the
create/update entry point (`resolve_gear`/`resolve_loft`/etc), which always self-excludes the
Feature's own id and forces `compute_part_bodies` onto its always-uncached branch. Went one
step further than a same-request-only fix: added a small, separate, part-scoped
`_feature_warnings_cache` in `app.document.extrude` (not `body_cache.py` itself — its own
generic checkpoint-chain mechanism is untouched) that `_apply_feature_to_bodies`'s own
Gear/BevelGear/Loft/GearChain/BevelPair branches populate as a side effect whenever `body_cache`
actually (re)runs their step; a plain GET now reads that cache instead of re-resolving, so a
repeat fetch of an unchanged Part is served with zero reconstruction of any of these five
Feature types — not just the "other" ones in the Part, but the one being displayed too (this
matters most for `BevelPairFeature`: a repeat `GET /features` for an unresolved-via-warm-start
spiral pair no longer reopens the meshing-phase `ProcessPoolExecutor` at all). Create/update's
own eager-validation self-exclusion path is untouched, per this doc's own explicit scoping.

**Verification**: bootstrapped a real `pythonocc-core=7.9.3` conda-forge env (micromamba
GitHub-Releases-asset route — `micro.mamba.pm` blocked by this sandbox's egress, the release
asset wasn't). Full backend suite run twice with real `pythonocc-core` (`pytest-xdist`,
4 cores): **1870/1870 passed (real baseline, before any change) → 1879/1879 passed (post-fix)**,
zero regressions, the +9 all new (a real `ProcessPoolExecutor`-counting test on a
tooth-count-symmetric spiral bevel pair proving a second `GET /features` opens zero pools, two
real-OCCT call-counting tests for Gear/Loft, and 6 pure dict-level tests for the new
`_feature_warnings_cache` itself) — full detail in this session's own `docs/status.md` entry,
2026-08-27.

**Follow-up, same branch**: a code review found the fix above had dropped the pre-existing
"a since-broken unrelated Feature must not take the whole feature list down" resilience —
fixed by re-wrapping each of the five router helpers' `compute_part_bodies(part)` call in the
same `except HTTPException: warnings = []` fallback the pre-fix code had, plus a new regression
test proving it. Full backend suite re-verified for real: **1880/1880 passed**.

**Coordinator note, logged not fixed**: a second review pass found a narrower, non-regressive
limitation — when a Part has both an unrelated broken Feature and multiple warning-bearing
Features, each warning-bearing helper's fallback independently re-runs the same failing prefix
once per call within a single request (never worse than the pre-fix baseline, which always
recomputed on every call). Logged in `docs/status.md`'s coordinator review note rather than
spending a third fix-up round on a bounded edge case.

**Status: merged to `main` via [PR #173](https://github.com/DIDSA-UK/DIDSA-CAD/pull/173),
2026-08-27.** Full detail in `docs/status.md`'s 2026-08-27 entry.

---

### Phase 1 chunk 2 — coarse-mesh mechanism + gear-family coarse builders

- **Branch**: `claude/lod-coarse-mesh-gear-family`. Code-reviewed (two rounds, both found and
  fixed real gaps), merged forward against `main` twice to reconcile with PR #172 (spiral bevel
  end-cap flattening) and PR #173 (chunk 1, above) — both cross-cutting the same files
  (`bevel.py`, `router.py`, `extrude.py`). **PR not yet opened.**
- **Scope**: the full `01-design.md` §8 item 2 — coarse builders for `GearFeature`,
  `BevelGearFeature`, `BevelPairFeature`, `GearChainFeature`, `PlanetaryGearFeature` (one real
  `BRepPrimAPI_MakeCylinder`/`MakeCone` each, positioned via each Feature type's own real
  positioning math, never the real tooth construction); a new `app.document.extrude.
  compute_part_bodies_coarse`/`coarse_eligible_feature_ids` serving mechanism (a brand-new
  function, `compute_part_bodies`'s own real code path untouched); a new `tier=coarse` query
  parameter on `GET /parts/{id}/mesh`; five new `POST /parts/{id}/{route}/coarse-preview`
  endpoints (the 3D analogue of `/gear/preview` for a not-yet-created Feature payload); a new
  `source="coarse"` value on `BodyMeshResponse`.
- **Invariant honored, checked directly**: coarse geometry is never persisted and never enters
  the Feature graph — every coarse-preview endpoint's own test asserts `GET /parts/{id}/features`
  stays empty afterward; `compute_part_bodies_coarse` is deliberately never cached via `body_
  cache`, so it can never leak into the real checkpoint chain a later real `compute_part_bodies`
  call reads back.
- **Verification, real throughout**: bootstrapped a real `pythonocc-core` conda env this session
  (Miniconda + `conda env create -f backend/environment.yml`, `micro.mamba.pm` blocked — same
  `repo.anaconda.com` fallback the 2026-08-07/2026-08-21/2026-08-26 entries in `docs/status.md`
  already used). Real baseline: 1870 passed before any change. New `backend/tests/
  test_lod_coarse_mesh.py` (12 tests): one coarse-builder + one coarse-preview test per Feature
  type, plus a cross-cutting test confirming `tier=coarse` excludes an ordinary Extrude Body
  alongside a Gear in the same Part. Every pre-existing gear-family test file re-run in full:
  170/170 passed (confirms the existing full-fidelity code paths are genuinely untouched). Full
  suite after all changes: 1882/1882 passed, zero regressions.
- **What chunks 3/4/5 can now build on**: `compute_part_bodies_coarse`/`coarse_eligible_
  feature_ids` (extend the isinstance dispatch inside `compute_part_bodies_coarse` with a
  Pattern/Loft branch once each has its own coarse resolver — no other change needed there);
  the `tier=coarse` query parameter and `source="coarse"` schema value (already generic, not
  gear-family-specific); the `POST .../coarse-preview` endpoint pattern (mirror `create_*`'s
  own validate-then-build shape, call the coarse resolver instead, never call `part.add_
  feature`) for Pattern/Loft's own not-yet-created-Feature preview case; chunk 5's client work
  can wire against the gear-family coverage this chunk already provides and extend to Pattern/
  Loft once chunks 3/4 land.
- **Known limitation, documented in the `tier=coarse` endpoint's own docstring rather than left
  implicit**: a Gear/BevelGear Feature bossed/cut into an already-existing Body (non-empty
  `target_body_ids`) inherits that Body's own id (`_apply_boss_or_cut`'s survivor-id tie-break),
  so `coarse_eligible_feature_ids`'s `base_feature_id` lookup attributes it to the earlier
  Feature instead of the Gear/BevelGear itself — a pre-existing ambiguity in this app's own
  Body-identity model (an Extrude Boss fused onto another Extrude has the identical ambiguity
  today), not something LOD introduces or needs to fix; the common case (a gear/bevel gear that
  mints its own standalone Body) is unaffected.
- **Not done this session** (explicitly out of scope): `PatternFeature`/`LoftFeature` coarse
  builders (chunks 3/4); any Flutter/client changes (chunk 5); the `body_cache` GET-list bypass
  bug (chunk 1, a separate parallel session); any async/background-job infrastructure
  (deliberately not needed per the design).
- **Fix-up (commit `1fc9ba3`)**: a coordinator code review before merge found three related
  validation gaps in the new coarse-preview endpoints — a degenerate 90° bevel pitch-cone angle
  500'd instead of returning the same clean 422 the real create endpoint gives; an internal
  gear/chain-member with `outer_diameter<=0` 500'd; a positive-but-too-small internal
  `outer_diameter` silently rendered a plausible coarse preview for parameters the real endpoint
  would reject. All three fixed (mirroring the equivalent checks the real construction paths
  already had), with regression tests, and — as a related find — the same crown-gear guard gap
  was also missing from the real `resolve_bevel_gear_from_bodies` path, fixed there too. A
  second code review of the fix-up's own diff found zero further issues.
- **Coordinator merge**: rebased twice against `main` to reconcile cross-cutting changes — PR
  #172 (spiral bevel end-cap flattening, same day) also touched `bevel.py`; PR #173 (chunk 1,
  above) also touched `router.py`/`extrude.py`. One real semantic conflict, resolved by hand:
  PR #172 reordered `resolve_bevel_gear_from_bodies`'s returned warnings
  (`assembly_warnings + warnings`) while this chunk's fix-up independently wrapped the same
  `_assemble_gear_solid` call in a `try/except` — both changes kept, the try/except wraps the
  call and the reordered return statement is unchanged. Full detail:
  `docs/status.md`'s 2026-08-27 entries. Verified by code review and `py_compile` syntax check
  only in this coordinator's own sandbox (no `pythonocc-core` available here) — not an
  independent OCCT re-run; trusting the branch's own last real 1882/1882 pass plus the
  non-overlapping nature of the merged-in changes.

---

### Phase 1 chunks 3/4/5 — Pattern/Loft coarse builders + client wiring (branch `claude/lod-pattern-loft-client`)

- **Branch**: `claude/lod-pattern-loft-client`, based on `main` post-chunk-2-merge (PR #174).
  **PR not yet opened** — the coordinator should open it.
- **Scope**: `01-design.md` §8 items 3 (Pattern coarse builder), 4 (Loft coarse builder), and 5
  (client) — folded into one session since 3/4 are small and 5 needed their real, landed
  endpoint shapes to build against rather than hypothetical ones.
  - **Backend**: `resolve_pattern_coarse_from_bodies`/`resolve_pattern_coarse`
    (`app.document.pattern`) — reuses the existing, unchanged `_rectangular_instances`/
    `_circular_instances`/`resolve_pattern_from_bodies`, skipping only the fuse chain
    `MergeMode.FUSE_INTO_ONE`/`tool_feature_id` would otherwise require (a `tool_feature_id`
    coarse pass also never runs the final boolean into the target — realized-but-unfused tool
    copies only). `resolve_loft_coarse_from_bodies`/`resolve_loft_coarse`
    (`app.document.loft`) — a `dataclasses.replace(feature, sections=[first, last])` copy handed
    to the real, unchanged `resolve_loft_from_bodies`. Both extend `compute_part_bodies_coarse`'s
    dispatch and `coarse_eligible_feature_ids`; new `POST .../pattern-features/coarse-preview`
    and `.../loft-features/coarse-preview` endpoints, mirroring chunk 2's five existing ones
    exactly. Also closed the `PatternFeature` instance-count upper-bound gap Finding 2/§6
    flagged (`_PATTERN_MAX_TOTAL_INSTANCES = 500`, a judgment call, applied to the *total*
    instance count).
  - **Client**: generalized the mesh-override mechanism via a **new, separate**
    `coarseOverlayMeshes`/`transientCoarsePreviewBodies` pair on `PartViewport` (kept
    `previewOverlayBodyId`/`previewOverlayMesh`, the live Fillet/Chamfer preview, completely
    untouched — a deliberate call within the design's own "your call" latitude, since the two
    represent genuinely different rendering states); new `_coarseOverlayMeshes`/
    `_pendingCoarseBodyIds`/`_pinnedCoarseFeatureIds` state in `PartScreen`, following the
    `_hiddenFeatureIds` convention; both flows wired — Part re-open universally (via
    `_refreshMesh`'s new background `tier=coarse` fetch, benefiting every coarse-eligible
    Feature type with no per-type work), create-time coarse preview specifically for
    `PatternFeature`/`LoftFeature` (the two types whose own configuration panel actually mounts
    `PartScreen`'s `PartViewport` — the five gear-family types use a separate `GearDesignScreen`
    with no viewport mounted at all, so flow 1 doesn't apply to them without a larger, separate
    piece of work); Feature-tree pending-detail badge (`feature_tree_panel.dart`, mirrors
    `hasLostReference`'s exact template, client-only computed state, no new backend field) and a
    persistent pin-to-coarse toggle (a new trailing `IconButton`, shown only for a coarse-eligible
    type).
- **Verification, both stacks real, kept separate**:
  - **Backend**: bootstrapped a real `pythonocc-core=7.9.3` conda-forge env (micromamba
    GitHub-Releases-asset route). Real, race-free baseline (`git stash`, run to completion
    *before* touching the tree again — see this session's own `docs/status.md` entry for a
    disclosed verification hiccup along the way, since fixed): **1909 passed**. Full suite after
    all changes: **1919 passed** (10 new, all in `backend/tests/test_lod_pattern_loft.py`), zero
    regressions.
  - **Client**: bootstrapped a real Flutter SDK (`git clone --depth 1 --branch master
    https://github.com/flutter/flutter.git`, landed on 3.48.0-0.3.pre — recent enough to be past
    the 2026-06-09 `flutter_scene`/`flutter_gpu` API cutoff this doc's own history previously
    hit, so `flutter test` compiled and ran real `PartViewport` widget tests, not just
    `flutter analyze`). `flutter analyze`: 0 issues (one transient `prefer_final_fields` hit
    while iterating led to catching and fixing a real bug pre-ship — a missing clear-before-
    rebuild in the new transient-node sync method). `flutter test`: **1453 passed, 10 skipped**
    (pre-existing GPU/Impeller-unavailable skips, same class already documented elsewhere in
    this suite), **0 failed** — includes 8 new tests (3 `part_viewport_test.dart`, 5
    `feature_tree_panel_test.dart`).
- **Not done this session** (explicitly out of scope, or a documented judgment-call scope
  reduction): Phase 2; any change to the gear-family coarse builders chunk 2 built;
  `BooleanFeature`/`SplitFeature`/`SurfaceFeature` coarse builders; flow 1 (create-time coarse
  preview) for the five gear-family types (architectural reason above); a wireframe/edges
  overlay for `transientCoarsePreviewBodies` (filled faces only).
- Full detail: `docs/status.md`'s 2026-08-27 "LOD Phase 1 chunks 3/4/5" entry.
- **Follow-up fix, same PR (#175), coordinator review**: `_refreshMesh`'s background `tier=coarse`
  fetch was firing on every one of its ~38 call sites, not just Part re-open — scoped it to the
  initial-load call site only, and passed the missing `hiddenFeatureIds`/
  `rollbackExcludedFeatureIds`/`meshQuality` filters through to the coarse-tier fetches. See
  `docs/status.md`'s follow-up paragraph on the same 2026-08-27 entry above for detail.

---

### Phase 2 chunks 1+2 — planetary pooling + `BevelPairFeature` job mode (branch `claude/lod-phase2-planetary-and-bevel-jobs`)

- **Branch**: `claude/lod-phase2-planetary-and-bevel-jobs`, based on `main` post-Phase-1 (PR #178,
  the latest merged `main` at dispatch time). **PR open**: [PR #179](https://github.com/DIDSA-UK/DIDSA-CAD/pull/179).
  Folds `02-phase2-design.md` §6 chunks 1 and 2 into one session — independent pieces (chunk 2 only
  needs `bevel_pair.py`'s *existing* pooling, not this session's new planetary pooling), both
  backend Python/OCCT work.
- **Scope — Part A (chunk 1)**: `ProcessPoolExecutor` pooling for `PlanetaryGearFeature`
  (`00-status.md` Finding 2's own flagged perf gap — "the fix `bevel_pair.py` applied for its
  2-member case, never applied here"), mirroring `bevel_pair.py`'s own `spawn`-context/BREP-bytes
  pattern exactly. Promoted `bevel_pair.py`'s previously-private BREP-bytes serialization helpers
  to a new shared `app.document.occt_process_utils` module (a pure refactor — `bevel_pair.py`'s own
  extensive test suite, which imports those names directly, needed zero changes since it re-exports
  them under their original names). Also the hard prerequisite chunk 3 (a future session) needs
  before `PlanetaryGearFeature` can be safely cancellable at all — killing a worker OS *process* is
  safe, killing a thread mid-C++-call into OCCT is not (`02-phase2-design.md` §3).
- **Scope — Part B (chunk 2, the primary Phase 2 deliverable)**: a new in-memory job store
  (`app.document.jobs`) and real mid-build cancellation (`app.document.job_cancellation`,
  reaching into a `ProcessPoolExecutor`'s own worker process handles and terminating them directly
  — `Future.cancel()` only ever cancels *queued* work), scoped only to `BevelPairFeature`. Three
  new routes: `POST /parts/{id}/bevel-pair-features/jobs` (202, returns `{job_id, status:
  "running"}` immediately — the real build runs in a dedicated background thread, not FastAPI's
  own request threadpool), `GET /parts/{id}/jobs/{job_id}` (polls; on success embeds the *exact
  same* `BevelPairFeatureResponse` the synchronous endpoint returns), `POST
  /parts/{id}/jobs/{job_id}/cancel`. One job running at a time per server process (a second
  concurrent create gets a `409`, chosen over queueing). `bevel_pair.py`'s own resolvers gained an
  optional `cancellation` parameter, `None` by default — a pure no-op for every synchronous caller,
  zero change to any other Feature type's existing contract. Phase 1's coarse-preview endpoint for
  `BevelPairFeature` is completely untouched, ready for a future client session to poll job-mode
  behind it.
- **Real invariant confirmed, not just claimed**: a cancelled job's Feature is never added to the
  Part — the job runner does a final `is_cancelled()` check immediately before `part.add_feature`,
  closing the race where a build finishes cleanly a hair after `cancel()` fires.
- **Verification, real throughout**: bootstrapped a real `pythonocc-core=7.9.3` conda-forge env
  (Miniconda + `conda env create -f backend/environment.yml`, `repo.anaconda.com` route —
  `micro.mamba.pm` blocked by this sandbox's own egress, same fallback prior sessions used; needed
  a one-time `conda tos accept` for the `pkgs/main`/`pkgs/r`/`pkgs/msys2` channels this session
  hit that earlier entries didn't). Real baseline: **1919 passed** (955.79s). Part A: the two
  pre-existing suites this session's changes touch (`test_planetary_gear_feature.py`,
  `test_bevel_pair_feature.py`) re-run in full, unmodified — **56/56 passed**, confirming the
  shared-module refactor and new pooling left both existing code paths byte-for-byte unaffected.
  New `test_planetary_gear_pooling.py` (5 tests: pool-construction counting, worker-count sizing,
  worker-exception propagation via a fake executor — a real forced-spawn-worker-failure test isn't
  practical, same limitation `test_bevel_pair_feature.py` already documents — and a same-result-
  as-a-direct-serial-build check via real tessellated bounding boxes). Real wall-clock before/after,
  disclosed honestly rather than cherry-picked: at the test suite's own default scale, pooling is
  actually a net *loss* in this sandbox (`spawn`'s own per-worker startup cost dominates when each
  member build is cheap) — a genuinely heavy configuration crosses over to a clear ~23% win. Part
  B: new `test_bevel_pair_jobs.py` (9 tests, real HTTP) — job-mode create returns in well under 1s
  (not waiting for the build); job-mode create matches a synchronous create of the identical
  payload field-for-field; **real cancellation** against the exact tooth-count-symmetric spiral
  config `test_bevel_pair_feature.py`'s own equivalent test confirms is real-search-worthy — polls
  until a live pool with real worker PIDs is confirmed active (not assumed), cancels mid-flight,
  confirms those exact PIDs are actually dead afterward, the job settles on `cancelled`, and the
  Feature was never persisted; exception-path parity (an invalid pair 422s identically via both
  paths); the `409` concurrency policy; `404`s for unknown jobs. Full suite after both parts:
  **1933 passed, 0 failed** (1047.93s, `pytest-xdist` 4 cores) — 1919 + 5 + 9, zero regressions.
- **Not done this session** (explicitly out of scope, unblocked for future sessions):
  - Chunk 3 (extending job-mode to `PlanetaryGearFeature`) — depends on this session's Part A
    pooling landing, now unblocked.
  - Chunk 4 (client/Flutter job-mode wiring — fire, poll, cancel affordance, resume-on-reconnect)
    — depends on this session's endpoint shapes existing, now landed; can build against
    `POST .../bevel-pair-features/jobs` / `GET .../jobs/{id}` / `POST .../jobs/{id}/cancel` exactly
    as specified above.
  - Any change to any other Feature type's existing synchronous contract.
  - UI concurrency or fine-grained progress reporting (explicitly out of scope per the approved
    design, `02-phase2-design.md` §7).
- Full detail: `docs/status.md`'s 2026-09-01 "LOD Phase 2 chunks 1+2" entry.
