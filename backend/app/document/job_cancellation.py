"""Real mid-build cancellation for job-mode `BevelPairFeature` builds
(`docs/lod-strategy/02-phase2-design.md` SS3) - the one piece of genuinely
new machinery Phase 2 needs, since `Future.cancel()` only cancels *queued*
work, never work a `ProcessPoolExecutor` worker is already executing.

`app.document.bevel_pair.resolve_bevel_pair_from_bodies`/`_search_meshing_
phase` are this Feature type's only two places that ever open a
`ProcessPoolExecutor` (the member-build pool and, for a spiral pair only,
the meshing-phase search pool) - both run strictly sequentially, never
concurrently, so a job ever has at most one live pool to cancel. A
`CancellationToken` is created once per job (`app.document.jobs`) and
threaded down into both call sites as an optional parameter; every
synchronous (non-job) caller passes `None` (the default), which skips all
tracking - this is a purely additive capability, not a synchronous-contract
change.
"""

import threading
from concurrent.futures import ProcessPoolExecutor
from contextlib import contextmanager, nullcontext
from typing import Iterator


class JobCancelled(Exception):
    """Raised, in the job's own background build thread, once a
    cancellation request has actually reached (or pre-empted) that job's
    in-flight `ProcessPoolExecutor` - `app.document.jobs`'s own job runner
    catches this specifically and marks the job `cancelled` rather than
    `failed`. Never raised for any synchronous (non-job) caller, since
    those never construct a `CancellationToken` in the first place."""


def _kill_pool_workers(executor: ProcessPoolExecutor) -> None:
    """Reaches into `executor`'s own worker `multiprocessing.Process`
    handles (`ProcessPoolExecutor._processes`, a `pid -> Process` dict -
    there is no public API for this; `concurrent.futures` was never
    designed for cancelling in-flight work, the exact gap this whole module
    exists to close) and terminates every live one directly - a killed OS
    process is always safe to reclaim (the OS cleans up everything it
    held), unlike force-killing a thread mid-C++-call into OCCT (`02-
    phase2-design.md` SS3's own reasoning for why this needed a process pool
    to begin with, not a thread pool). `shutdown(wait=True, cancel_futures=
    True)` afterward reaps the now-dead workers and drops any
    still-queued-but-not-yet-started futures (a grid-scan trial, or - LOD
    Phase 2 chunk 3 - a planet build that never got a worker slot) - called
    from THIS (the cancelling) thread so a still-queued future is dropped
    the instant `cancel()` is called, not whenever the job's own thread next
    happens to notice.

    This function's own `shutdown()` call races, by construction, against
    the job's own thread calling `shutdown_pool_quietly` on the exact same
    `executor` on its way out of `resolve_bevel_pair_from_bodies`'s/
    `resolve_planetary_from_bodies`'s own `try/finally` (below) - two
    threads both tearing down the same executor's internal queues/pipes
    concurrently is NOT the "idempotent, safe to call twice" case `Process
    PoolExecutor.shutdown`'s own docs describe (that's about repeated calls
    from one thread); confirmed on-device as a real, if narrow, race: a
    spurious `OSError: [Errno 9] Bad file descriptor` surfaced from this
    exact interleaving in this session's own real-cancellation test (~1 in
    3 runs). The already-issued `process.kill()` calls above are the actual
    load-bearing, externally-observable effect (confirmed directly via
    `os.kill(pid, 0)` in this module's own tests) - a `shutdown()` failing
    partway through loses nothing observable, so any exception here is
    swallowed rather than left to surface as a spurious job failure."""
    processes = list(getattr(executor, "_processes", {}).values())
    for process in processes:
        try:
            process.kill()
        except Exception:  # noqa: BLE001 - already-exited/unreachable process, nothing to do
            pass
    try:
        executor.shutdown(wait=True, cancel_futures=True)
    except Exception:  # noqa: BLE001 - best-effort only, see this function's own docstring
        pass


def shutdown_pool_quietly(executor: ProcessPoolExecutor) -> None:
    """`executor.shutdown(wait=True)`, swallowing any `Exception` - the
    job's own owning thread calls this exactly once, in a `finally` block,
    on its way out of `resolve_bevel_pair_from_bodies`'s/`resolve_planetary_
    from_bodies`'s own pool-open window (replacing a plain `with executor:`,
    which offers no hook to swallow what `__exit__` itself raises). See
    `_kill_pool_workers`'s own docstring for the concurrent-shutdown race
    this guards against - the same reasoning applies symmetrically from
    this (the job) thread's own side of that race."""
    try:
        executor.shutdown(wait=True)
    except Exception:  # noqa: BLE001 - best-effort only, see this function's own docstring
        pass


class CancellationToken:
    """Shared, across threads, between a job's own background-thread build
    call and the `POST .../jobs/{job_id}/cancel` endpoint's own request
    thread - the only channel connecting them, since once `resolve_bevel_
    pair_from_bodies` starts it runs synchronously to completion (or
    exception) with no other hook point a different thread could reach.

    At most one `ProcessPoolExecutor` is ever registered at a time (the two
    pools this Feature type can open - member-build, meshing-phase-search -
    are strictly sequential, never concurrent), tracked via `track()` for
    exactly the window each one is open. `cancel()` (called from a
    different thread) kills whichever pool is CURRENTLY registered; if none
    is (between phases, before the first pool opens, or after the last one
    already closed), it still records the request (`_cancelled = True`) so
    the *next* `track()` call - if there is one - kills its own pool
    immediately on entry instead of ever submitting real work. This covers
    all three phase-boundary cases `02-phase2-design.md` SS3 calls out:
    mid-member-build, mid-phase-search, and between phases (nothing to kill
    yet, but the next phase must not proceed)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cancelled = False
        self._executor: ProcessPoolExecutor | None = None

    def is_cancelled(self) -> bool:
        with self._lock:
            return self._cancelled

    @contextmanager
    def track(self, executor: ProcessPoolExecutor) -> Iterator[None]:
        """Wraps the body that submits work to (and awaits results from)
        `executor` - registers it for the duration of the `with` block.
        Raises `JobCancelled` (instead of whatever exception, if any, the
        body itself raised - e.g. `BrokenProcessPool` from `cancel()`
        killing a worker mid-`Future.result()`) whenever `is_cancelled()`
        is true by the time the block exits, covering both "already
        cancelled before this pool even opened" and "cancelled while this
        pool was live"."""
        with self._lock:
            already_cancelled = self._cancelled
            if not already_cancelled:
                self._executor = executor
        if already_cancelled:
            _kill_pool_workers(executor)
            raise JobCancelled()
        try:
            yield
        except Exception:
            if self.is_cancelled():
                raise JobCancelled() from None
            raise
        finally:
            with self._lock:
                if self._executor is executor:
                    self._executor = None

    def cancel(self) -> bool:
        """Called from the `POST .../cancel` endpoint's own request thread.
        Returns whether a live pool was actually found and killed (the
        common, real-cancellation case) - `False` only means no pool
        happened to be open at this exact instant (between phases, or
        before/after the job's own pool-bearing window), not that the
        cancellation request itself failed: `_cancelled` is set regardless,
        so a pool that opens afterward still aborts immediately."""
        with self._lock:
            self._cancelled = True
            executor = self._executor
        if executor is None:
            return False
        _kill_pool_workers(executor)
        return True


def cancellation_scope(cancellation: "CancellationToken | None", executor: ProcessPoolExecutor):
    """`cancellation.track(executor)` when job-mode passed a real
    `CancellationToken`, a plain no-op context manager otherwise - every
    synchronous (non-job) caller passes `cancellation=None`, so this is a
    pure no-op for them, byte-for-byte the same pool behavior as before
    cancellation support existed. Promoted out of `app.document.bevel_pair`
    (LOD Phase 2 chunk 2's original, sole owner) to here (LOD Phase 2 chunk
    3) so `app.document.planetary_gear`'s own pool can reuse the identical
    hook rather than duplicating it - `bevel_pair.py` now imports this
    directly instead of keeping its own private copy, a pure refactor with
    no behavior change (confirmed by its own existing test suite passing
    unchanged)."""
    if cancellation is None:
        return nullcontext()
    return cancellation.track(executor)
