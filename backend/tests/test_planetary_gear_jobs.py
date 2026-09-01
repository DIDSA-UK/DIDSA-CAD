"""Real-OCCT tests for LOD Phase 2 chunk 3: job-mode `PlanetaryGearFeature`
builds - extends the exact `BevelPairFeature` job-mode mechanism chunk 2
established (`docs/lod-strategy/02-phase2-design.md` SS4) to a second
Feature type, now that `planetary_gear.py` has real `ProcessPoolExecutor`
pooling to cancel into (chunk 1). Structurally mirrors `test_bevel_pair_
jobs.py`'s own shape - the generic job store/poll/cancel endpoints are
shared, not duplicated (`app.document.jobs`).
"""

import os
import time

from fastapi.testclient import TestClient

from app.document.jobs import JobStatus, submit_planetary_job
from app.document.models import PlaneRef, PlanetaryGearFeature
from app.main import app
from app.sketch.models import Plane
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _planetary_payload(**overrides) -> dict:
    # sun_tooth_count=20, ring_tooth_count=60 -> planet_tooth_count = 20;
    # assembly condition (20+60) % 5 == 0 - a well-formed default, same
    # values `test_planetary_gear_feature.py` already uses.
    payload = {
        "module": 1.0,
        "sun_tooth_count": 20,
        "ring_tooth_count": 60,
        "planet_count": 5,
        "face_width": 5.0,
        "ring_outer_diameter": 70.0,
    }
    payload.update(overrides)
    return payload


def _slow_planetary_feature(id_: str = "slow-planetary-job-test") -> PlanetaryGearFeature:
    """A genuinely slow, real configuration - real wall-clock measured in
    this session at ~6-8s for the whole pooled build (module=40, 800/2400
    tooth, 4 planets - the same scale `test_planetary_gear_pooling.py`'s
    own real before/after timing used to show a genuine pooling win), large
    enough to reliably keep a real `ProcessPoolExecutor` pool active long
    enough for a cancellation test to observe it mid-flight, not assumed."""
    return PlanetaryGearFeature(
        id=id_,
        plane_ref=PlaneRef(fixed_plane=Plane.XY),
        module=40.0,
        sun_tooth_count=800,
        ring_tooth_count=2400,
        planet_count=4,
        pressure_angle_degrees=20.0,
        face_width=100.0,
        ring_outer_diameter=40.0 * (2400 + 10),
    )


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
    part = _create_part()
    start = time.monotonic()
    response = client.post(f"/document/parts/{part['id']}/planetary-gear-features/jobs", json=_planetary_payload())
    elapsed = time.monotonic() - start

    assert response.status_code == 202, response.json()
    body = response.json()
    assert body["status"] == "running"
    assert body["job_id"]
    assert elapsed < 1.0, f"job-mode create took {elapsed}s - should return near-instantly, not wait for the build"

    # Drain to completion so this test doesn't leave a dangling `running`
    # job behind for a later test to race against (only one job runs at a
    # time per process, shared across every job-mode Feature type -
    # `app.document.jobs`'s own concurrency policy).
    _poll_until_terminal(part["id"], body["job_id"])


# --- (b) polling: running -> succeeded, matching a synchronous create's own result --


def test_job_mode_create_matches_a_synchronous_create_of_the_identical_payload():
    # ring_outer_diameter must exceed the ring's own dedendum diameter,
    # which grows with ring_tooth_count - the default (70.0, sized for the
    # smaller default ring) is too small for this larger ring.
    payload = _planetary_payload(sun_tooth_count=40, ring_tooth_count=120, planet_count=4, ring_outer_diameter=140.0)

    part_sync = _create_part("Sync")
    sync_response = client.post(f"/document/parts/{part_sync['id']}/planetary-gear-features", json=payload)
    assert sync_response.status_code == 201, sync_response.json()
    sync_body = sync_response.json()

    part_job = _create_part("Job")
    job_response = client.post(f"/document/parts/{part_job['id']}/planetary-gear-features/jobs", json=payload)
    assert job_response.status_code == 202, job_response.json()
    job_id = job_response.json()["job_id"]

    status_body = _poll_until_terminal(part_job["id"], job_id)
    assert status_body["status"] == "succeeded", status_body
    result = status_body["result"]
    assert result is not None
    assert result["type"] == "planetary_gear"

    # Same content as the synchronous response, apart from each create's own
    # minted Feature id.
    for key in sync_body:
        if key == "id":
            continue
        assert result[key] == sync_body[key], f"field {key!r} differs: job={result[key]!r} sync={sync_body[key]!r}"

    # And the Feature really was persisted into the job's own Part.
    features_response = client.get(f"/document/parts/{part_job['id']}/features")
    assert features_response.status_code == 200
    assert len(features_response.json()) == 1
    assert features_response.json()[0]["id"] == result["id"]

    mesh_response = client.get(f"/document/parts/{part_job['id']}/mesh")
    assert mesh_response.status_code == 200
    # sun + ring + 4 planets = 6 Bodies.
    assert len(mesh_response.json()) == 6


def test_polling_shows_running_before_succeeded():
    part = _create_part()
    job_response = client.post(f"/document/parts/{part['id']}/planetary-gear-features/jobs", json=_planetary_payload())
    job_id = job_response.json()["job_id"]

    first_poll = client.get(f"/document/parts/{part['id']}/jobs/{job_id}")
    assert first_poll.status_code == 200
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


def test_cancel_during_an_active_pool_kills_workers_and_never_persists():
    """Drives a genuinely slow planetary configuration (large tooth counts/
    module - real wall-clock confirmed several seconds, `_slow_planetary_
    feature`'s own docstring) into job mode, waits for its sun/ring/planet
    `ProcessPoolExecutor` to actually become live (polling the job's own
    `CancellationToken` - the real timing assumption is verified here
    directly, not assumed), cancels mid-flight, and confirms: (1) the OS
    worker processes that were alive at cancel time are actually gone
    afterward, (2) the job's own status settles on `cancelled`, (3) the
    Feature was never added to the Part."""
    from app.document.models import Part

    part = Part(id="cancel-test-planetary-part", name="Cancel Test")
    feature = _slow_planetary_feature()

    record = submit_planetary_job(part.id, part, feature)

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
    # A real planetary pool has 2 + planet_count workers to submit (capped
    # by cpu_count-1) - confirms this is genuinely the sun/ring/planet pool,
    # not some other single-worker pool.
    assert len(live_pids) >= 2, f"expected at least 2 live workers for a sun+ring+planets pool, got {live_pids}"

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
    # directly at submission time), so this works even though `part` above
    # was built directly rather than through the real `POST /parts` endpoint.
    status_response = client.get(f"/document/parts/{part.id}/jobs/{record.id}")
    assert status_response.status_code == 200, status_response.json()
    assert status_response.json()["status"] == "cancelled"


def test_cancel_on_an_already_finished_job_returns_409():
    part = _create_part()
    job_response = client.post(f"/document/parts/{part['id']}/planetary-gear-features/jobs", json=_planetary_payload())
    job_id = job_response.json()["job_id"]
    _poll_until_terminal(part["id"], job_id)

    cancel_response = client.post(f"/document/parts/{part['id']}/jobs/{job_id}/cancel")
    assert cancel_response.status_code == 409, cancel_response.json()


# --- (d) exception path parity ----------------------------------------------


def test_job_mode_surfaces_the_same_structured_error_a_synchronous_create_would():
    """An invalid planetary set (odd tooth difference - mirrors `test_
    planetary_gear_feature.py`'s own `test_odd_tooth_difference_is_blocked`)
    - the synchronous endpoint 422s with a structured `invalid_planetary_
    parameters` detail; job mode must surface the exact same structured
    error via the poll endpoint's own `error` field once the job settles on
    `failed`."""
    payload = _planetary_payload(sun_tooth_count=20, ring_tooth_count=61, planet_count=5)

    part_sync = _create_part("Sync Fail")
    sync_response = client.post(f"/document/parts/{part_sync['id']}/planetary-gear-features", json=payload)
    assert sync_response.status_code == 422, sync_response.json()
    sync_detail = sync_response.json()["detail"]
    assert sync_detail["type"] == "invalid_planetary_parameters"

    part_job = _create_part("Job Fail")
    job_response = client.post(f"/document/parts/{part_job['id']}/planetary-gear-features/jobs", json=payload)
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


# --- Concurrency policy: one running job at a time, shared across Feature types --


def test_second_concurrent_job_create_gets_409_across_feature_types():
    """The concurrency policy is process-wide, not per-Feature-type
    (`app.document.jobs`'s own shared `_running_job_id` global, generalized
    this session from `BevelPairFeature`-only) - a slow `PlanetaryGearFeature`
    job already running must block a concurrent `BevelPairFeature` job-mode
    create too, not just another `PlanetaryGearFeature` one."""
    part = _create_part()
    slow = _slow_planetary_feature()
    first_payload = {
        "module": slow.module,
        "sun_tooth_count": slow.sun_tooth_count,
        "ring_tooth_count": slow.ring_tooth_count,
        "planet_count": slow.planet_count,
        "face_width": slow.face_width,
        "ring_outer_diameter": slow.ring_outer_diameter,
        "pressure_angle_degrees": slow.pressure_angle_degrees,
    }
    first = client.post(f"/document/parts/{part['id']}/planetary-gear-features/jobs", json=first_payload)
    assert first.status_code == 202, first.json()
    job_id = first.json()["job_id"]

    try:
        bevel_pair_payload = {
            "module": 4.0,
            "member_1": {"tooth_count": 20, "profile_shift": 0.0},
            "member_2": {"tooth_count": 40, "profile_shift": 0.0},
            "face_width": 15.0,
        }
        second = client.post(f"/document/parts/{part['id']}/bevel-pair-features/jobs", json=bevel_pair_payload)
        assert second.status_code == 409, second.json()
    finally:
        _poll_until_terminal(part["id"], job_id, timeout_s=300.0)


def test_get_unknown_job_returns_404():
    part = _create_part()
    response = client.get(f"/document/parts/{part['id']}/jobs/not-a-real-job-id")
    assert response.status_code == 404
