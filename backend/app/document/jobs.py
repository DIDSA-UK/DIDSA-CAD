"""In-memory job store for job-mode `BevelPairFeature` builds
(`docs/lod-strategy/02-phase2-design.md` SS2/SS4) - deliberately scoped to
this one Feature type's genuine, measured long-tail build cost (up to
~170s+ for a tooth-count-symmetric spiral pair, `docs/status.md`'s
2026-08-26 entries), not a general async-job system. Every other Feature
type's create/update endpoint stays fully synchronous, untouched.

**A plain in-memory dict, no new durability** - matches `app.document.
body_cache`'s own explicit "single-process, no-locking" precedent, and the
rest of `app.document.store`'s own already-non-durable design (every
Feature already vanishes on server restart today; a job dict that survived
one while the Part it's building into did not would be a meaningless
durability boundary - `02-phase2-design.md` SS2 works through this in
full). Deployment is confirmed single-process (`uvicorn app.main:app`, no
`--workers`), so one process-global dict is the whole store.

**Eviction policy - bounded TTL after reaching a terminal state, checked
lazily** (`_JOB_TTL_SECONDS`, swept on every job-store call rather than via
a dedicated background thread - this store never stores raw geometry, only
a `warnings` list or a structured error dict, so the "BREP bytes sitting in
memory forever" memory concern `02-phase2-design.md` SS2 raises is already
much smaller here than a worst-case job store might need to guard against;
a lazy sweep is proportionate rather than under-building for it). A client
that never polls a finished job simply loses it after the TTL - the same
`GET /parts/{id}/features` fallback `02-phase2-design.md` SS1 already
describes for "lost the job id entirely" remains available regardless.

**Concurrency policy - serialize job execution, one `running` job per
server process** (`02-phase2-design.md` SS5's own recommendation): a job's
own pool(s) already claim most/all available cores on constrained hardware
(a Pi 5, a phone), so two genuinely expensive builds contending for the
same handful of cores would only make both slower, not run "in parallel"
in any useful sense. A second job-mode create request while one is already
running gets a clear, immediate `409` (chosen over queueing - simpler, no
extra queue-management thread/state, and matches this app's single-user
self-hosted deployment context where a second concurrent expensive create
is an unusual case worth surfacing to the user rather than silently
absorbing)."""

import threading
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum

from fastapi import HTTPException

from app.document.bevel_pair import resolve_bevel_pair
from app.document.job_cancellation import CancellationToken, JobCancelled
from app.document.models import BevelPairFeature, Part

_JOB_TTL_SECONDS = 15 * 60
"""How long a job stays fetchable after reaching a terminal state
(`succeeded`/`failed`/`cancelled`) before lazy eviction reclaims it - long
enough for a reconnected client (the whole point of job-mode, `02-phase2-
design.md` SS1) to poll a stale-but-recent result, short enough that an
abandoned job's small `warnings`/`error` payload doesn't accumulate
forever on a memory-constrained device."""


class JobStatus(str, Enum):
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"


@dataclass
class JobRecord:
    """One job's own state - never exposes `part`/`feature` outside this
    module directly; `app.document.router`'s own endpoints read `status`/
    `warnings`/`error` and use `feature` only to build the exact same
    `BevelPairFeatureResponse` shape the synchronous endpoint already
    returns (`_bevel_pair_feature_response(job.part, job.feature, job.
    warnings)`).

    `part` is the literal `Part` object reference the request handler
    already resolved (`get_part_or_404`) at job-creation time - captured
    directly rather than re-resolved by `part_id` later, since the
    background build thread has no request context (`app.session_context`'s
    own per-request contextvar is never bound in a plain `threading.Thread`)
    to re-derive it from, and reusing the identical reference also means a
    later poll always reads back the same Part the job is actually building
    into, regardless of which session's request thread happens to poll it."""

    id: str
    part_id: str
    part: Part
    feature: BevelPairFeature
    cancellation: CancellationToken
    status: JobStatus = JobStatus.RUNNING
    warnings: list[str] | None = None
    error: dict | None = None
    created_at: float = field(default_factory=time.monotonic)
    finished_at: float | None = None


_lock = threading.Lock()
_jobs: dict[str, JobRecord] = {}
_running_job_id: str | None = None


def _sweep_expired_locked() -> None:
    """Caller must hold `_lock`. Drops every terminal job whose own TTL has
    elapsed - lazy eviction, no dedicated cleanup thread (see this module's
    own top-level "Eviction policy" docstring)."""
    now = time.monotonic()
    expired = [
        job_id
        for job_id, record in _jobs.items()
        if record.finished_at is not None and now - record.finished_at > _JOB_TTL_SECONDS
    ]
    for job_id in expired:
        del _jobs[job_id]


def _finish_job_locked(job_id: str, status: JobStatus, *, warnings: list[str] | None = None, error: dict | None = None) -> None:
    global _running_job_id
    record = _jobs.get(job_id)
    if record is None:
        return
    record.status = status
    record.warnings = warnings
    record.error = error
    record.finished_at = time.monotonic()
    if _running_job_id == job_id:
        _running_job_id = None


def _run_bevel_pair_job(job_id: str) -> None:
    """The background build thread's own entry point - runs the exact same
    `resolve_bevel_pair` the synchronous `create_bevel_pair_feature`
    endpoint calls, then persists via `part.add_feature` on success, same
    validate-then-persist discipline every Feature type here already uses.
    Never touches `app.session_context`/`app.document.store` - `part`/
    `feature` were both already captured, in the request thread, by
    `submit_bevel_pair_job` before this thread ever started."""
    with _lock:
        record = _jobs[job_id]
    part, feature, cancellation = record.part, record.feature, record.cancellation

    try:
        _shape, warnings = resolve_bevel_pair(part, feature, cancellation=cancellation)
    except Exception as exc:  # noqa: BLE001 - classification below decides FAILED vs CANCELLED for every flavor
        # `cancellation.is_cancelled()` is the authoritative signal here, not
        # just `isinstance(exc, JobCancelled)`. `track()` (`app.document.
        # job_cancellation`) only converts an exception to `JobCancelled`
        # while its own narrow `with` scope is still open; a cancellation
        # can also tear down the `ProcessPoolExecutor` a hair after that
        # scope has already exited (e.g. the owning thread's own outer
        # `with ProcessPoolExecutor(...) as executor:` racing its `shutdown()`
        # against `cancel()`'s), in which case whatever raw exception that
        # produces (`OSError`, `BrokenProcessPool`, `EOFError`, ...) never
        # passes through `track()`'s `except` at all. Checking the flag
        # directly classifies a job as `cancelled` whenever cancellation was
        # actually requested, regardless of which layer or exception type a
        # cancellation-triggered teardown happens to surface.
        if isinstance(exc, JobCancelled) or cancellation.is_cancelled():
            with _lock:
                _finish_job_locked(job_id, JobStatus.CANCELLED)
            return
        if isinstance(exc, HTTPException):
            with _lock:
                _finish_job_locked(job_id, JobStatus.FAILED, error={"status_code": exc.status_code, "detail": exc.detail})
            return
        with _lock:
            _finish_job_locked(
                job_id, JobStatus.FAILED, error={"status_code": 500, "detail": f"unexpected job failure: {exc}"}
            )
        return

    # Real invariant (`docs/lod-strategy/02-phase2-design.md` SS4): a
    # cancelled job's Feature must never reach the Part, even if the build
    # itself happened to finish cleanly a hair after `cancel()` was called
    # (the race `CancellationToken`'s own docstring documents - `cancel()`
    # racing ahead of the last `track()` window closing, so the build
    # returns normally instead of raising `JobCancelled`). Checked here,
    # immediately before the one persisting call, closing that window as
    # tightly as this store can.
    with _lock:
        if cancellation.is_cancelled():
            _finish_job_locked(job_id, JobStatus.CANCELLED)
            return
        part.add_feature(feature)
        _finish_job_locked(job_id, JobStatus.SUCCEEDED, warnings=warnings)


def submit_bevel_pair_job(part_id: str, part: Part, feature: BevelPairFeature) -> JobRecord:
    """Creates and starts a new job - called from the request thread (so
    `part` is already the correct, session-scoped `Part` object), returns
    immediately with the job in `running` state; the actual build runs in a
    dedicated `threading.Thread` (NOT FastAPI's own request-handling
    threadpool - a long job must not consume one of that pool's limited
    slots for its full duration). Raises `409` if another job is already
    running anywhere in this server process (see this module's own
    top-level "Concurrency policy" docstring)."""
    global _running_job_id
    with _lock:
        _sweep_expired_locked()
        if _running_job_id is not None:
            raise HTTPException(
                status_code=409,
                detail={
                    "type": "job_already_running",
                    "detail": f"job {_running_job_id!r} is already running - only one job runs at a time",
                },
            )
        job_id = str(uuid.uuid4())
        record = JobRecord(id=job_id, part_id=part_id, part=part, feature=feature, cancellation=CancellationToken())
        _jobs[job_id] = record
        _running_job_id = job_id

    thread = threading.Thread(target=_run_bevel_pair_job, args=(job_id,), daemon=True)
    thread.start()
    return record


def get_job(part_id: str, job_id: str) -> JobRecord:
    """Fetches a job's current state - `404` if it never existed, already
    evicted (TTL elapsed), or belongs to a different Part than `part_id`
    names (the URL's own `part_id` must match, same scoping every other
    `/parts/{part_id}/...` endpoint here already enforces)."""
    with _lock:
        _sweep_expired_locked()
        record = _jobs.get(job_id)
    if record is None or record.part_id != part_id:
        raise HTTPException(status_code=404, detail="Job not found")
    return record


def cancel_job(part_id: str, job_id: str) -> JobRecord:
    """Requests cancellation of a running job - `404` via `get_job` if it
    doesn't exist/doesn't belong to this Part, `409` if it's already
    reached a terminal state (cancelling a finished job is meaningless).
    Returns immediately once the kill request has been issued
    (`CancellationToken.cancel`) - the job's own status may still read
    `running` for a brief window until its background thread actually
    notices and finishes; poll `GET .../jobs/{job_id}` to observe the
    transition to `cancelled`."""
    record = get_job(part_id, job_id)
    if record.status != JobStatus.RUNNING:
        raise HTTPException(
            status_code=409,
            detail={"type": "job_not_running", "detail": f"job is already {record.status.value}, cannot cancel"},
        )
    record.cancellation.cancel()
    return record
