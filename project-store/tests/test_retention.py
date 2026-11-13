"""The kept-versions rule: the last 20 of each file and everything younger than 30 days, whichever keeps more; a deleted file's
versions for 30 days. The clock is injected; nothing sleeps."""

import os

from app.store import KEEP_DAYS, KEEP_LAST_VERSIONS, Expect
from tests.conftest import put

DAY = 86400


def save(store, path, data: bytes, clock, device="Desktop"):
    """Write a new version through the store, one second after the last write."""
    clock.advance(1)
    from hashlib import sha256

    tmp = store.new_tmp_path()
    with open(tmp, "wb") as handle:
        handle.write(data)
    staged = store.make_staged(tmp, sha256(data).hexdigest(), len(data), path)
    current = store.current_info("P", path)
    expect = Expect(version=current["version"]) if current else Expect(create=True)
    return store.put("P", path, staged, expect, device)[0]


def kept(store, path):
    return sorted(v["version"] for v in store.versions("P", path)["versions"])


def blob_exists(store, data: bytes) -> bool:
    from hashlib import sha256

    return os.path.exists(store._blob_path(sha256(data).hexdigest()))


def test_constants_are_the_decided_ones():
    assert (KEEP_LAST_VERSIONS, KEEP_DAYS) == (20, 30)


def test_everything_young_is_kept_even_past_twenty(store, clock):
    store.create_project("P", "t")
    for index in range(35):
        save(store, "a.didsa", f"v{index}".encode(), clock)
    store.prune()
    assert kept(store, "a.didsa") == list(range(1, 36))


def test_old_versions_beyond_the_last_twenty_go_but_the_last_twenty_stay_whatever_their_age(store, clock):
    store.create_project("P", "t")
    for index in range(30):
        save(store, "a.didsa", f"v{index + 1}".encode(), clock)
    clock.advance(31 * DAY)
    store.prune()
    assert kept(store, "a.didsa") == list(range(11, 31))
    assert not blob_exists(store, b"v10") and blob_exists(store, b"v11") and blob_exists(store, b"v30")
    # the bytes of a kept version still read back, a pruned one is gone
    assert store.open_version("P", "a.didsa", 11)[1].read() == b"v11"
    import pytest

    from app.store import NotFound

    with pytest.raises(NotFound):
        store.open_version("P", "a.didsa", 10)


def test_a_file_with_few_old_versions_keeps_them_all(store, clock):
    store.create_project("P", "t")
    for index in range(3):
        save(store, "a.didsa", f"v{index + 1}".encode(), clock)
    clock.advance(400 * DAY)
    store.prune()
    assert kept(store, "a.didsa") == [1, 2, 3]


def test_whichever_keeps_more_wins_young_beyond_twenty_plus_old_dropped(store, clock):
    store.create_project("P", "t")
    for index in range(10):  # old
        save(store, "a.didsa", f"old{index}".encode(), clock)
    clock.advance(40 * DAY)
    for index in range(25):  # young: more than 20
        save(store, "a.didsa", f"new{index}".encode(), clock)
    store.prune()
    assert kept(store, "a.didsa") == list(range(11, 36)), "all 25 young ones kept, the 10 old ones dropped"


def test_the_boundary_is_exactly_thirty_days(store, clock):
    store.create_project("P", "t")
    for index in range(25):
        save(store, "a.didsa", f"v{index + 1}".encode(), clock)
    first_write = clock.now - 24  # version 1 was written 24 s before the last
    clock.now = first_write + KEEP_DAYS * DAY - 1
    store.prune()
    assert kept(store, "a.didsa") == list(range(1, 26)), "29 days 23 h 59 m 59 s old: still young"
    clock.now = first_write + KEEP_DAYS * DAY + 5
    store.prune()
    assert kept(store, "a.didsa")[0] > 1, "past 30 days and outside the last 20: dropped"


def test_the_rule_applies_to_each_file_alone(store, clock):
    store.create_project("P", "t")
    for index in range(25):
        save(store, "busy.didsa", f"b{index}".encode(), clock)
    save(store, "quiet.didsa", b"q1", clock)
    clock.advance(60 * DAY)
    store.prune()
    assert kept(store, "busy.didsa") == list(range(6, 26))
    assert kept(store, "quiet.didsa") == [1]


def test_writes_prune_the_file_they_touch(store, clock):
    store.create_project("P", "t")
    for index in range(25):
        save(store, "a.didsa", f"v{index + 1}".encode(), clock)
    clock.advance(31 * DAY)
    save(store, "a.didsa", b"v26", clock)  # no explicit prune: the write applies the rule to this file
    assert kept(store, "a.didsa") == list(range(7, 27))


def test_a_blob_shared_by_two_files_survives_until_neither_keeps_it(store, clock):
    store.create_project("P", "t")
    for index in range(25):
        save(store, "a.didsa", b"same" if index == 0 else f"a{index}".encode(), clock)
    save(store, "b.didsa", b"same", clock)
    clock.advance(31 * DAY)
    store.prune()
    assert 1 not in kept(store, "a.didsa")
    assert blob_exists(store, b"same"), "b.didsa's version 1 still refers to it"


def test_a_deleted_files_versions_are_kept_thirty_days(store, clock):
    store.create_project("P", "t")
    save(store, "a.didsa", b"one", clock)
    save(store, "a.didsa", b"two", clock)
    clock.advance(1)
    store.delete("P", "a.didsa", Expect(version=2), "Desktop")
    clock.advance(29 * DAY)
    store.prune()
    assert kept(store, "a.didsa") == [1, 2, 3]
    assert store.open_version("P", "a.didsa", 1)[1].read() == b"one"
    clock.advance(2 * DAY)
    store.prune()
    assert kept(store, "a.didsa") == [3], "only the delete's own record stays"
    assert not blob_exists(store, b"one") and not blob_exists(store, b"two")


def test_a_deleted_file_old_versions_do_not_outlive_the_delete_by_the_20_rule(store, clock):
    store.create_project("P", "t")
    save(store, "a.didsa", b"one", clock)
    clock.advance(40 * DAY)
    store.delete("P", "a.didsa", Expect(version=1), "Desktop")  # the file is old, the delete is new: kept
    store.prune()
    assert kept(store, "a.didsa") == [1, 2]


def test_a_file_deleted_long_ago_cannot_be_mistaken_for_a_new_one(store, clock):
    store.create_project("P", "t")
    save(store, "a.didsa", b"one", clock)
    store.delete("P", "a.didsa", Expect(version=1), "Desktop")
    clock.advance(100 * DAY)
    store.prune()
    created = save(store, "a.didsa", b"again", clock)
    assert created["version"] == 3, "the counter was kept, so a copy that holds version 1 is still stale"


def test_a_recreated_file_is_a_live_file_again(store, clock):
    store.create_project("P", "t")
    save(store, "a.didsa", b"one", clock)
    store.delete("P", "a.didsa", Expect(version=1), "Desktop")
    save(store, "a.didsa", b"two", clock)
    clock.advance(31 * DAY)
    store.prune()
    assert kept(store, "a.didsa") == [1, 2, 3], "3 versions: well within the last 20"
    assert store.tree("P")["files"][0]["version"] == 3


def test_the_hourly_sweep_runs_from_a_write(store, clock):
    store.create_project("P", "t")
    for index in range(25):
        save(store, "a.didsa", f"v{index + 1}".encode(), clock)
    save(store, "other.didsa", b"x", clock)
    clock.advance(31 * DAY)
    save(store, "other.didsa", b"y", clock)  # touches other.didsa only; the sweep (an hour passed) tidies a.didsa
    assert kept(store, "a.didsa") == list(range(6, 26))


def test_retention_over_http(client, project, store, clock):
    for index in range(25):
        clock.advance(1)
        response = put(client, project, "a.didsa", f"v{index}".encode(), base=None if index == 0 else index)
        assert response.status_code in (200, 201)
    clock.advance(31 * DAY)
    store.prune()
    listing = client.get(f"/projects/{project}/files/a.didsa/versions").json()["versions"]
    assert [v["version"] for v in listing] == list(range(25, 5, -1))
    assert client.get(f"/projects/{project}/files/a.didsa/versions/5").status_code == 404
    assert client.get(f"/projects/{project}/files/a.didsa/versions/6").status_code == 200
