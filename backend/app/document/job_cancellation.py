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
from contextlib import contextmanager
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
    to begin with, not a thread pool).

    Deliberately does NOT call `executor.shutdown()` itself, even though
    killing every worker is exactly the kind of thing you'd expect to want
    torn down immediately. `resolve_bevel_pair_from_bodies`/`_search_
    meshing_phase` (`app.document.bevel_pair`) both already own an outer
    `with ProcessPoolExecutor(...) as executor:` block that is *guaranteed*
    to call `shutdown()` on its own exit - the exception this kill produces
    (whatever a worker dying mid-`Future.result()` surfaces: `BrokenProcess
    Pool`, `EOFError`, ...) has nowhere else to go but out through that
    block. Calling `shutdown()` here too, from THIS thread (`cancel()`'s own
    caller, typically the `POST .../cancel` request thread), used to race
    that guaranteed call - both threads tearing down the same executor's
    internal IPC file descriptors concurrently produced a genuine, real,
    reproducible `OSError: [Errno 9] Bad file descriptor` on ARM64 CI
    (`docs/status.md`'s dated entry for this fix). `ProcessPoolExecutor.
    shutdown` is idempotent only for *sequential* calls (a second call
    after the first has fully completed is a safe no-op) - concurrent calls
    from two different threads are not the same thing and are not safe.
    Leaving the sole `shutdown()` call to the owning thread's own context
    manager removes the second caller entirely, closing the race at its
    root instead of catching its fallout after the fact (`app.document.
    jobs`'s own job-runner still does that too, as a backstop for any other
    shape this kind of race could take)."""
    processes = list(getattr(executor, "_processes", {}).values())
    for process in processes:
        try:
            process.kill()
        except Exception:  # noqa: BLE001 - already-exited/unreachable process, nothing to do
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
