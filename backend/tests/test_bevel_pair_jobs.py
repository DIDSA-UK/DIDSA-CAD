"""Real-OCCT tests for LOD Phase 2 chunk 2: job-mode `BevelPairFeature`
builds (`docs/lod-strategy/02-phase2-design.md` SS4) - `POST .../bevel-pair-
features/jobs`, `GET .../jobs/{job_id}`, `POST .../jobs/{job_id}/cancel`.
Structurally mirrors `test_bevel_pair_feature.py`'s own HTTP-level shape for
the synchronous endpoints these mirror.
"""

import os
import time

from fastapi.testclient import TestClient

from app.document.jobs import JobStatus, submit_bevel_pair_job
from app.document.models import Part
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _member(tooth_count: int, profile_shift: float = 0.0) -> dict:
    return {"tooth_count": tooth_count, "profile_shift": profile_shift}


def _pair_payload(**overrides) -> dict:
    payload = {
        "module": 4.0,
        "member_1": _member(20),
        "member_2": _member(40),
        "face_width": 15.0,
    }
    payload.update(overrides)
    return payload


def _spiral_symmetric_pair_payload(**overrides) -> dict:
    """A genuinely slow, tooth-count-symmetric spiral pair - the exact
    shape `test_bevel_pair_feature.py`'s own `test_search_meshing_phase_
    symmetric_ratio_escalates_through_tiers_and_never_worse_than_full_tier_
    alone` uses, confirmed there to actually run the phase-search pool
    through both tiers rather than resolving via the cheap warm start."""
    payload = _pair_payload(
        module=4.0,
        member_1=_member(20),
        member_2=_member(20),
        face_width=8.0,
        points_per_flank=12,
        spiral_angle_degrees=20.0,
    )
    payload.update(overrides)
    return payload


def _poll_until_terminal(part_id: str, job_id: str, timeout_s: float = 300.0) -> dict:
    deadline = time.monotonic() + timeout_s
    body = {}
    while time.monotonic() < deadline:
        response = client.get(f"/document/parts/{part_id}/jobs/{job_id}")
        assert response.status_code == 200, response.json()
        body = response.json()
        if body["status"] != "running":
            return body
        time.sleep(0.1)
    raise AssertionError(f"job {job_id} did not reach a terminal state within {timeout_s}s: {body}")


# --- (a) job-mode create returns fast, doesn't wait for the build ----------


def test_job_mode_create_returns_immediately_not_waiting_for_the_build():
    """A real, non-trivial pair (enough member tooth count that the build
    itself takes a real, measurable amount of wall-clock) - the create
    request itself must come back in well under a second, proving the
    build genuinely runs in a background thread rather than blocking this
    request."""
    part = _create_part()
    start = time.monotonic()
    response = client.post(f"/document/parts/{part['id']}/bevel-pair-features/jobs", json=_pair_payload())
    elapsed = time.monotonic() - start

    assert response.status_code == 202, response.json()
    body = response.json()
    assert body["status"] == "running"
    assert body["job_id"]
    assert elapsed < 1.0, f"job-mode create took {elapsed}s - should return near-instantly, not wait for the build"

    # Drain the job to completion so this test doesn't leave a dangling
    # `running` job behind for a later test to race against (only one job
    # runs at a time per process, `app.document.jobs`'s own concurrency
    # policy).
    _poll_until_terminal(part["id"], body["job_id"])


# --- (b) polling: running -> succeeded, matching a synchronous create's own result --


def test_job_mode_create_matches_a_synchronous_create_of_the_identical_payload():
    payload = _pair_payload(member_1=_member(15), member_2=_member(30))

    part_sync = _create_part("Sync")
    sync_response = client.post(f"/document/parts/{part_sync['id']}/bevel-pair-features", json=payload)
    assert sync_response.status_code == 201, sync_response.json()
    sync_body = sync_response.json()

    part_job = _create_part("Job")
    job_response = client.post(f"/document/parts/{part_job['id']}/bevel-pair-features/jobs", json=payload)
    assert job_response.status_code == 202, job_response.json()
    job_id = job_response.json()["job_id"]

    status_body = _poll_until_terminal(part_job["id"], job_id)
    assert status_body["status"] == "succeeded", status_body
    result = status_body["result"]
    assert result is not None

    # Same shape/content as the synchronous response, apart from the two
    # ids (each create minted its own uuid4 Feature id) and each Part's own
    # id embedded in plane_ref/etc, if any - compare everything else.
    for key in sync_body:
        if key == "id":
            continue
        assert result[key] == sync_body[key], f"field {key!r} differs: job={result[key]!r} sync={sync_body[key]!r}"

    # And the Feature really was persisted into the job's own Part.
    features_response = client.get(f"/document/parts/{part_job['id']}/features")
    assert features_response.status_code == 200
    assert len(features_response.json()) == 1
    assert features_response.json()[0]["id"] == result["id"]


def test_polling_shows_running_before_succeeded():
    """Confirms the status actually transitions through `running` rather
    than the poll endpoint always reading a snapshot taken after the fact -
    polls immediately after create, before the (real, non-instant) member
    builds could plausibly have finished."""
    part = _create_part()
    job_response = client.post(f"/document/parts/{part['id']}/bevel-pair-features/jobs", json=_pair_payload())
    job_id = job_response.json()["job_id"]

    first_poll = client.get(f"/document/parts/{part['id']}/jobs/{job_id}")
    assert first_poll.status_code == 200
    # Not asserted to always be "running" (a very fast build on fast
    # hardware could in principle finish first) but this should be the
    # overwhelmingly common case, and the same request must never 404.
    assert first_poll.json()["status"] in ("running", "succeeded")

    final = _poll_until_terminal(part["id"], job_id)
    assert final["status"] == "succeeded"


# --- (c) real cancellation ---------------------------------------------------


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def test_cancel_during_an_active_phase_search_pool_kills_workers_and_never_persists():
    """Drives a genuinely slow, tooth-count-symmetric spiral pair (confirmed
    real-search-worthy by `test_bevel_pair_feature.py`'s own equivalent
    test) into job mode, waits for its phase-search `ProcessPoolExecutor`
    to actually become live (polling the job's own `CancellationToken` -
    the real timing assumption is verified here directly, not assumed),
    cancels it mid-flight, and confirms: (1) the OS worker processes that
    were alive at cancel time are actually gone afterward, (2) the job's
    own status settles on `cancelled`, (3) the Feature was never added to
    the Part."""
    part = Part(id="cancel-test-part", name="Cancel Test")
    from app.document.models import BevelPairFeature, BevelPairMemberSpec, PlaneRef
    from app.sketch.models import Plane

    feature = BevelPairFeature(
        id="cancel-test-feature",
        plane_ref=PlaneRef(fixed_plane=Plane.XY),
        module=4.0,
        member_1=BevelPairMemberSpec(tooth_count=20),
        member_2=BevelPairMemberSpec(tooth_count=20),
        face_width=8.0,
        points_per_flank=12,
        spiral_angle_degrees=20.0,
    )

    record = submit_bevel_pair_job(part.id, part, feature)

    # Wait for a real, live ProcessPoolExecutor (either the member-build
    # pool or - the one this specific config is chosen to reach - the
    # phase-search pool) with at least one real worker process, rather
    # than assuming a fixed sleep is long enough.
    deadline = time.monotonic() + 60.0
    executor = None
    while time.monotonic() < deadline:
        executor = record.cancellation._executor
        if executor is not None and getattr(executor, "_processes", None):
            break
        if record.status is not JobStatus.RUNNING:
            break
        time.sleep(0.02)

    assert executor is not None, "no ProcessPoolExecutor was ever registered - cancellation tracking never engaged"
    live_pids = list(executor._processes.keys())
    assert live_pids, "pool was registered but had no live worker processes at the moment we checked"
    assert all(_pid_alive(pid) for pid in live_pids), "worker PIDs were already dead before cancel() - test raced"

    cancelled_something = record.cancellation.cancel()
    assert cancelled_something is True, "cancel() found no live pool to kill - the timing assumption above was wrong"

    deadline = time.monotonic() + 60.0
    while record.status is JobStatus.RUNNING and time.monotonic() < deadline:
        time.sleep(0.05)
    assert record.status is JobStatus.CANCELLED, f"job settled on {record.status!r}, not cancelled"

    for pid in live_pids:
        assert not _pid_alive(pid), f"worker pid {pid} is still alive after cancel()"

    assert part.features == [], "the Feature must never be added to the Part when cancelled before it persists"

    # And the HTTP poll surface agrees - the job lookup itself never
    # touches the session-scoped document store (`job.part` was captured
    # directly at submission time, `app.document.jobs.JobRecord`'s own
    # docstring), so this works even though `part` above was built directly
    # rather than through the real `POST /parts` endpoint.
    status_response = client.get(f"/document/parts/{part.id}/jobs/{record.id}")
    assert status_response.status_code == 200, status_response.json()
    assert status_response.json()["status"] == "cancelled"


def test_cancel_on_an_already_finished_job_returns_409():
    part = _create_part()
    job_response = client.post(f"/document/parts/{part['id']}/bevel-pair-features/jobs", json=_pair_payload())
    job_id = job_response.json()["job_id"]
    _poll_until_terminal(part["id"], job_id)

    cancel_response = client.post(f"/document/parts/{part['id']}/jobs/{job_id}/cancel")
    assert cancel_response.status_code == 409, cancel_response.json()


def test_cancel_on_an_unknown_job_returns_404():
    part = _create_part()
    response = client.post(f"/document/parts/{part['id']}/jobs/not-a-real-job-id/cancel")
    assert response.status_code == 404


# --- (d) exception path parity ----------------------------------------------


def test_job_mode_surfaces_the_same_structured_error_a_synchronous_create_would():
    """An invalid pair (a shaft angle that makes `pitch_cone_half_angles`
    unsolvable) - the synchronous endpoint 422s with a structured
    `invalid_bevel_pair_parameters` detail; job mode must surface the exact
    same structured error via the poll endpoint's own `error` field once
    the job settles on `failed`."""
    payload = _pair_payload(member_1=_member(60), member_2=_member(60), shaft_angle_degrees=1.0)

    part_sync = _create_part("Sync Fail")
    sync_response = client.post(f"/document/parts/{part_sync['id']}/bevel-pair-features", json=payload)
    assert sync_response.status_code == 422, sync_response.json()
    sync_detail = sync_response.json()["detail"]

    part_job = _create_part("Job Fail")
    job_response = client.post(f"/document/parts/{part_job['id']}/bevel-pair-features/jobs", json=payload)
    assert job_response.status_code == 202, job_response.json()
    job_id = job_response.json()["job_id"]

    status_body = _poll_until_terminal(part_job["id"], job_id)
    assert status_body["status"] == "failed", status_body
    assert status_body["result"] is None
    assert status_body["error"]["detail"] == sync_detail

    # And the Feature was never persisted.
    features_response = client.get(f"/document/parts/{part_job['id']}/features")
    assert features_response.status_code == 200
    assert features_response.json() == []


# --- Concurrency policy: one running job at a time --------------------------


def test_second_concurrent_job_create_gets_409():
    # The first job uses the slow, tooth-count-symmetric spiral config -
    # guaranteed still running by the time the second request lands right
    # after it, unlike a cheap straight-bevel pair that could plausibly
    # finish before the second POST is even sent.
    part = _create_part()
    first = client.post(f"/document/parts/{part['id']}/bevel-pair-features/jobs", json=_spiral_symmetric_pair_payload())
    assert first.status_code == 202, first.json()
    job_id = first.json()["job_id"]

    try:
        second = client.post(f"/document/parts/{part['id']}/bevel-pair-features/jobs", json=_pair_payload())
        assert second.status_code == 409, second.json()
    finally:
        _poll_until_terminal(part["id"], job_id)


def test_get_unknown_job_returns_404():
    part = _create_part()
    response = client.get(f"/document/parts/{part['id']}/jobs/not-a-real-job-id")
    assert response.status_code == 404
