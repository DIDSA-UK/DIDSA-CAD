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
| Phase 1 chunk 1 (body_cache GET-list fix) | code-reviewed, fix-up in progress | **actual branch: `claude/new-session-yihda3`** (base: `main`) — note the original planned branch name `claude/lod-body-cache-get-features-fix` was never used; the user's manual dispatch landed on a session-default branch name instead | User-dispatched retry completed for real (commit `9da90f8`). Coordinator ran a real code review before merge and found a genuine regression: the fix dropped the original blanket `except HTTPException: warnings = []` around the per-Feature resolve call, so now an unrelated broken Feature elsewhere in the same Part (e.g. a Mirror/Pattern/Split referencing a deleted body) takes down the ENTIRE `GET /parts/{id}/features` request instead of just showing `warnings=[]` for the one affected row — a lockout regression worse in kind than the performance bug being fixed, and unverified by the branch's own test suite. Fix-up session `session_01EuxEdhEE7DfqCfoRahRwc1` dispatched 2026-08-27, continuing on the same branch. **Not yet merged** |
| Phase 1 chunk 2 (coarse-mesh mechanism + gear-family builders) | code-reviewed, fix-up in progress | branch `claude/lod-coarse-mesh-gear-family` (base: coordinator branch at `8cbc456`, not `main` — needed to read the design docs, which aren't on `main` yet) | User-dispatched retry completed for real (1882/1882 suite pass). Coordinator ran a real code review before merge (`/code-review high`) and found 3 related gaps: coarse-preview endpoints skip validation the real create endpoints enforce (a 90° bevel pitch-cone angle 500s instead of a clean 422; an internal gear/chain-member with `outer_diameter<=0` 500s; a positive-but-too-small internal `outer_diameter` silently renders a plausible coarse preview for parameters the real endpoint would reject) — none touch the core never-persisted invariant. Fix-up session `session_012WBjHTJXMpMH3ea1ReAhby` dispatched 2026-08-27, continuing on the same branch. **Not yet merged** — chunks 3/4/5 stay blocked until this lands |
| Phase 1 chunk 3 (Pattern coarse builder) | not yet dispatched | — | blocked on chunk 2 merging |
| Phase 1 chunk 4 (Loft coarse builder) | not yet dispatched | — | blocked on chunk 2 merging |
| Phase 1 chunk 5 (client) | not yet dispatched | — | blocked on chunk 2 merging |
| Phase 2 design pass | drafted, see `02-phase2-design.md` | — | **awaiting user approval — no Phase 2 implementation dispatched yet** |

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

**Not yet approved — no Phase 2 implementation dispatched.**

---

## Open questions / cross-cutting decisions

Resolved by design rather than left open (see `01-design.md` §7): retroactive-vs-new-Parts-only
doesn't arise (coarse geometry is never persisted, so it applies uniformly); the persistent
toggle is included in v1 since it's a cheap marginal add-on once the pending-state plumbing
exists. No other open, user-must-decide product question was found.

---

## Dispatched implementation sessions

*(none yet — populated after plan approval, per session: branch, PR link, scope, state,
verification status)*
