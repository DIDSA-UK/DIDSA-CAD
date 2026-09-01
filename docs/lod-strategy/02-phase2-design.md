# LOD Strategy — Phase 2 design: cancellation + reconnect (approved)

Status: **approved 2026-09-01**. Scope confirmed with the user: cancellation of an
in-progress expensive build, and a cheap way for a reconnected client to learn the outcome —
explicitly NOT UI concurrency (do other work while a build runs) and NOT fine-grained progress
percentages. Builds on Phase 1's client-side coarse/pending state, now merged to `main` (PRs
#173/#174/#175) — chunk 4 below reuses the real, already-landed coarse-preview endpoints for
`BevelPairFeature`/`PlanetaryGearFeature` (`POST /parts/{id}/bevel-pair-features/coarse-preview`,
`.../planetary-gear-features/coarse-preview`) to show a placeholder while a job-mode build
polls, not a hypothetical mechanism. Re-checked against `main` before dispatch: nothing landed
since Phase 1 touches `bevel_pair.py`/`planetary_gear.py`/`router.py`/`extrude.py`, so this
design's assumptions still hold.

## 1. The central reframing: disconnect was never actually losing work

Investigated directly rather than assumed: every create/update route is a plain `def`, not
`async def`, dispatched to Starlette's threadpool. Nothing in this app checks
`request.is_disconnected()` (zero hits), and a sync handler gives no `await` point to check it
even if it wanted to. **A dropped client connection does not stop the in-flight OCCT
computation** — the thread runs to completion, and `part.add_feature(feature)` persists the
result server-side before the (now-undeliverable) response is even built.

This is not hypothetical: the client's own `spiralBevelPairRequestTimeout` (720s,
`client/lib/config.dart:183`) is a *self-inflicted* disconnect on a long build — if the real
build runs past 720s, the client aborts the connection itself, and the server keeps going
and still succeeds.

**So the actual gap is not "prevent lost work" (never at risk) — it's "give a reconnected
client a cheap channel back to the result," plus genuine cancellation (a real gap: nothing
today lets a user abort a build they no longer want).** This reframes Phase 2's value and
shrinks its scope versus what "disconnect resilience" sounds like.

**This also sharpens why Phase 1 chunk 1 (the `body_cache` GET-list fix, already dispatched)
matters beyond its own original scope**: without it, a client's fallback path for "did that
finish?" (`GET /parts/{id}/features`) re-runs the entire build to answer the question — for a
dropped spiral-bevel-pair create, that's paying the ~170s+ cost a second time just to check,
and a third time on a naive retry. The new job-status-poll endpoint below sidesteps this for
the common case (poll by job id, a cheap dict lookup) — but `GET /features` remains the
fallback if a client loses the job id entirely (e.g. app fully restarted), so chunk 1 still
matters as a safety net, not just as its own independent fix.

## 2. Job store: in-memory dict, no new durability — confirmed appropriate, not assumed

`body_cache.py`'s own docstring already states the precedent: "matches the rest of
`app.document.store`'s existing single-process, no-locking assumption." Confirmed this holds
for the whole backend: `store.py`'s `_documents` dict (the entire Part/Feature/Sketch store)
is itself explicitly "no real persistence" — every Feature already vanishes on server restart
today. Deployment is confirmed single-process (`uvicorn app.main:app`, no `--workers`, no
gunicorn/supervisor). A job dict that survived a restart while the Part it's building into did
not would be a meaningless, inconsistent durability boundary — there'd be nothing to resume a
job against. **A plain in-memory dict is the right, proportionate choice, not a shortcut.**

New risk this does introduce, not present elsewhere in this codebase: a job's result payload
needs actual eviction (TTL after reaching a terminal state, or evict-on-first-fetch) — unlike
`_documents`/`body_cache`'s unbounded-but-small-in-practice accumulation, a finished job's BREP
bytes sitting in memory forever on a Pi 5 is a real constrained-memory concern.

## 3. Cancellation mechanics

`bevel_pair.py` already has the mechanism in embryonic form: `ProcessPoolExecutor` pools for
member builds and (for spiral pairs) the meshing-phase grid-scan. One real gap in the standard
library API: `Future.cancel()` only cancels *queued*, not in-flight, work. Real cancellation
needs reaching into the pool's worker process handles to actually terminate the OS process
doing that job's work — this is genuinely new code, but a small, well-understood amount, and
terminating a process is always safe (the OS reclaims everything).

**`planetary_gear.py` has no pooling at all today** — it builds `sun + ring + planet_count`
solids fully serially, in-process. There is nothing to cancel short of killing the request
thread itself. **Thread-kill is ruled out as actively unsafe here, not just generally
inadvisable**: OCCT holds native, process-global state, and `bevel_pair.py` already documents
a real, on-device-reproduced fork-unsafety hazard from exactly this kind of native-state
fragility. Force-killing a thread mid-C++-call risks corrupting that global state for the rest
of the server process's life — every subsequent request, not just the killed one. A killed
*process* has no such blast radius.

**Conclusion: `planetary_gear.py` needs `ProcessPoolExecutor` pooling added — mirroring
`bevel_pair.py`'s existing pattern exactly — before it can be safely cancellable at all.** This
is not just a Phase 2 prerequisite; it's the same performance gap Phase 0's Finding 2 already
flagged independently ("the exact shape `bevel_pair.py` diagnosed and fixed... never applied
here"). One implementation chunk serves both purposes.

## 4. Proposed API contract — narrow, not a blanket async switch

- **New job-mode create endpoint**, scoped only to the confirmed genuine long tail: spiral
  `BevelPairFeature` now, `PlanetaryGearFeature` once §3's pooling lands. A separate route
  (not a query flag on the existing endpoint) since the response shape genuinely differs (202
  + `{job_id}` vs. the full synchronous 201 response). Validates payload synchronously (cheap),
  then hands the real build to a background thread (not FastAPI's own request threadpool, so
  a long job doesn't consume a request-handling slot for its full duration) and returns
  immediately.
- **`GET /parts/{part_id}/jobs/{job_id}`** — polls `running|succeeded|failed|cancelled`; on
  success, embeds the exact same Feature response the synchronous endpoint would have
  returned, so client result-handling code is unchanged, only the fetch timing differs.
- **`POST /parts/{part_id}/jobs/{job_id}/cancel`** — terminates the job's worker process(es)
  per §3; the Feature is never added to the Part if cancelled before persistence, matching the
  existing validate-before-persist discipline every resolver already follows.
- **Every other Feature type keeps its existing synchronous contract, untouched.** This is
  deliberately narrow — consistent with Phase 1's own decision not to introduce async infra
  for the general case, and with the scope the user confirmed (cancellation + reconnect only).

## 5. New risk surfaced, worth deciding explicitly: concurrent job contention

A job's worker pool(s) already claim most/all available cores on a Pi 5 (4 cores) or phone for
the job's duration. Nothing today has ever had to reason about two OCCT-heavy builds sharing a
handful of cores at once. **Recommend serializing job execution in v1** (one job "running" at a
time per server process; a second job-mode create request queues rather than starting
immediately) rather than letting pools contend — simple, matches the single-user deployment
context, and avoidable complexity if it turns out nobody ever triggers two expensive builds
back to back.

## 6. Proposed implementation chunks

1. **Add `ProcessPoolExecutor` pooling to `planetary_gear.py`**, mirroring `bevel_pair.py`'s
   pattern (promote the currently-private `_shape_to_brep_bytes`/`_shape_from_brep_bytes`
   BREP-bytes IPC helpers to a small shared module rather than duplicating them). Real,
   standalone performance win independent of Phase 2, and a prerequisite for cancellability.
   Can dispatch immediately, independent of everything else in Phase 2.
2. **Job store + job-mode endpoint + poll + cancel, scoped to `BevelPairFeature` only** — the
   primary target, since it's the one with a measured worst case. Depends on nothing but #1
   being optional (bevel_pair already has pooling).
3. **Extend job-mode to `PlanetaryGearFeature`** — depends on #1 landing.
4. **Client**: job-mode create flow (fire, get job id, poll, swap in result when ready — reuses
   Phase 1's coarse-placeholder display while polling), a cancel affordance, and resume-on-
   reconnect (persist the in-flight job id locally so relaunching the app can resume polling
   rather than losing track of it). Depends on #2 at minimum.

Each ships to its own branch/PR per the established pattern.

## 7. What this deliberately does not include

UI concurrency (editing other Features/Parts while a job runs) and fine-grained progress
percentages — both real, both explicitly out of scope per the user's own confirmed framing.
Extending job-mode to any Feature type beyond BevelPairFeature/PlanetaryGearFeature — no other
type has a measured long-tail case that justifies it; if one emerges, extending this mechanism
is a small follow-up, not a redesign.
