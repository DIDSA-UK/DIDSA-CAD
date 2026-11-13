"""Stale writes, all-or-nothing commits and two writers racing."""

import os
import threading

from tests.conftest import commit, db_state, disk_state, native_file, put, upload


def test_stale_put_is_412_and_writes_nothing(client, project, root, store):
    put(client, project, "a.didsa", b"v1")
    put(client, project, "a.didsa", b"v2 from Quest", base=1, device="Quest 3")
    before_disk, before_db = disk_state(root), db_state(store)
    response = put(client, project, "a.didsa", b"v2 from Desktop", base=1, device="Desktop")
    assert response.status_code == 412
    current = response.json()["current"]
    assert current["version"] == 2 and current["modified_by"] == "Quest 3"
    assert disk_state(root) == before_disk and db_state(store) == before_db
    assert os.listdir(store.tmp_dir) == [], "the refused body was not left behind"
    assert client.get(f"/projects/{project}/files/a.didsa").content == b"v2 from Quest"


def test_commit_with_one_stale_file_is_refused_whole_with_409(client, project, root, store):
    for name in ("a", "b", "c"):
        put(client, project, f"{name}.didsa", f"{name}1".encode())
    put(client, project, "b.didsa", b"b2 by someone else", base=1, device="Quest 3")
    uploads = {name: upload(client, project, f"{name}-mine".encode()) for name in ("a", "b", "c", "new")}
    before_disk, before_db = disk_state(root), db_state(store)
    response = commit(
        client,
        project,
        [
            {"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": uploads["a"]},
            {"op": "put", "path": "b.didsa", "base_version": 1, "upload_id": uploads["b"]},
            {"op": "put", "path": "c.didsa", "base_version": 1, "upload_id": uploads["c"]},
            {"op": "put", "path": "new.didsa", "base_version": None, "upload_id": uploads["new"]},
        ],
    )
    assert response.status_code == 409
    body = response.json()
    assert [c["path"] for c in body["conflicts"]] == ["b.didsa"]
    clash = body["conflicts"][0]
    assert clash["base_version"] == 1 and clash["current_version"] == 2 and clash["reason"] == "changed"
    assert clash["current"]["modified_by"] == "Quest 3"
    # nothing written: not the files that were fine, not the new one, no new version, no change-feed entry
    assert disk_state(root) == before_disk and db_state(store) == before_db
    assert client.get(f"/projects/{project}/files/a.didsa").content == b"a1"
    assert client.get(f"/projects/{project}/files/new.didsa").status_code == 404
    # the uploads survive for the retry once the clash is dealt with
    retry = commit(
        client,
        project,
        [
            {"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": uploads["a"]},
            {"op": "put", "path": "b.didsa", "base_version": 2, "upload_id": uploads["b"]},
            {"op": "put", "path": "c.didsa", "base_version": 1, "upload_id": uploads["c"]},
            {"op": "put", "path": "new.didsa", "base_version": None, "upload_id": uploads["new"]},
        ],
    )
    assert retry.status_code == 200 and client.get(f"/projects/{project}/files/b.didsa").content == b"b-mine"


def test_commit_409_lists_every_clash(client, project, root, store):
    for name in ("a", "b", "c", "d"):
        put(client, project, f"{name}.didsa", b"1")
    put(client, project, "a.didsa", b"2", base=1, device="Quest 3")  # changed
    client.delete(f"/projects/{project}/files/b.didsa", headers={"If-Match": '"1"', "X-Device-Name": "Quest 3"})  # deleted
    commit(client, project, [{"op": "move", "path": "c.didsa", "to": "c2.didsa", "base_version": 1}])  # moved away
    put(client, project, "existing.didsa", b"x")  # a create-only that finds it there
    uid = lambda: upload(client, project, b"mine")  # noqa: E731
    before_disk, before_db = disk_state(root), db_state(store)
    response = commit(
        client,
        project,
        [
            {"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": uid()},
            {"op": "put", "path": "b.didsa", "base_version": 1, "upload_id": uid()},
            {"op": "put", "path": "c.didsa", "base_version": 1, "upload_id": uid()},
            {"op": "delete", "path": "d.didsa", "base_version": 1},
            {"op": "put", "path": "existing.didsa", "base_version": None, "upload_id": uid()},
            {"op": "put", "path": "never-was.didsa", "base_version": 3, "upload_id": uid()},
        ],
    )
    assert response.status_code == 409
    clashes = {c["path"]: c for c in response.json()["conflicts"]}
    assert set(clashes) == {"a.didsa", "b.didsa", "c.didsa", "existing.didsa", "never-was.didsa"}
    assert clashes["a.didsa"]["reason"] == "changed"
    assert clashes["b.didsa"]["reason"] == "deleted" and clashes["b.didsa"]["current"]["deleted"] is True
    assert clashes["c.didsa"]["reason"] == "deleted" and clashes["c.didsa"]["current"]["moved_to"] == "c2.didsa"
    assert clashes["existing.didsa"]["reason"] == "exists"
    assert clashes["never-was.didsa"]["reason"] == "missing" and clashes["never-was.didsa"]["current"] is None
    assert disk_state(root) == before_disk and db_state(store) == before_db


def test_commit_move_onto_an_existing_file_is_a_clash(client, project, root, store):
    put(client, project, "a.didsa", b"a")
    put(client, project, "b.didsa", b"b")
    before_disk, before_db = disk_state(root), db_state(store)
    response = commit(client, project, [{"op": "move", "path": "a.didsa", "to": "b.didsa", "base_version": 1}])
    assert response.status_code == 409 and response.json()["conflicts"][0]["reason"] == "target_exists"
    assert disk_state(root) == before_disk and db_state(store) == before_db


def test_commit_that_would_make_a_file_a_folder_is_a_clash(client, project, root, store):
    put(client, project, "a", b"file")
    put(client, project, "d/x.didsa", b"x")
    before_disk, before_db = disk_state(root), db_state(store)
    response = commit(
        client,
        project,
        [
            {"op": "put", "path": "a/b.didsa", "base_version": None, "upload_id": upload(client, project, b"1")},
            {"op": "put", "path": "d", "base_version": None, "upload_id": upload(client, project, b"2")},
            {"op": "put", "path": "q", "base_version": None, "upload_id": upload(client, project, b"3")},
            {"op": "put", "path": "q/r", "base_version": None, "upload_id": upload(client, project, b"4")},
        ],
    )
    assert response.status_code == 409
    assert {c["path"] for c in response.json()["conflicts"]} == {"a/b.didsa", "d", "q", "q/r"}
    assert disk_state(root) == before_disk and db_state(store) == before_db


def test_replacing_a_file_by_a_folder_in_one_commit_is_fine(client, project):
    put(client, project, "a", b"file")
    response = commit(
        client,
        project,
        [
            {"op": "delete", "path": "a", "base_version": 1},
            {"op": "put", "path": "a/b.didsa", "base_version": None, "upload_id": upload(client, project, b"1")},
        ],
    )
    assert response.status_code == 200, response.text
    assert client.get(f"/projects/{project}/files/a/b.didsa").content == b"1"


def test_a_failure_part_way_through_a_commit_puts_everything_back(client, project, root, store, monkeypatch):
    put(client, project, "a.didsa", b"a1")
    put(client, project, "b.didsa", b"b1")
    before_disk, before_db = disk_state(root), db_state(store)
    uploads = [upload(client, project, f"mine{i}".encode()) for i in range(4)]
    original, calls = store._apply_put, []

    def failing(*args, **kwargs):
        calls.append(1)
        if len(calls) == 3:
            raise OSError("disk full (injected)")
        return original(*args, **kwargs)

    monkeypatch.setattr(store, "_apply_put", failing)
    changes = [
        {"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": uploads[0]},
        {"op": "put", "path": "new/c.didsa", "base_version": None, "upload_id": uploads[1]},
        {"op": "put", "path": "b.didsa", "base_version": 1, "upload_id": uploads[2]},
    ]
    from fastapi.testclient import TestClient

    from app.api import create_app

    failing_client = TestClient(create_app(store, "test-store-key"), headers=client.headers, raise_server_exceptions=False)
    assert failing_client.post(f"/projects/{project}/commit", json={"changes": changes}).status_code == 500
    assert len(calls) == 3
    assert disk_state(root) == before_disk, "files restored, the new folder removed"
    assert db_state(store) == before_db
    # and the store still works, with the uploads still usable
    monkeypatch.undo()
    assert commit(client, project, changes).status_code == 200


# ---- two writers racing: one wins, the other is refused (threads against the one worker's lock)


def _race(callables):
    barrier = threading.Barrier(len(callables))
    results = [None] * len(callables)

    def run(index):
        barrier.wait()
        results[index] = callables[index]()

    threads = [threading.Thread(target=run, args=(i,)) for i in range(len(callables))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)
    assert all(not t.is_alive() for t in threads)
    return results


def test_two_writers_on_one_file_one_wins_the_other_gets_412(client, project, root):
    put(client, project, "a.didsa", b"base")
    results = _race([lambda i=i: put(client, project, "a.didsa", f"writer {i}".encode(), base=1, device=f"dev{i}") for i in range(2)])
    assert sorted(r.status_code for r in results) == [200, 412]
    winner = next(r for r in results if r.status_code == 200).json()
    assert winner["version"] == 2
    assert client.get(f"/projects/{project}/files/a.didsa").content == f"writer {winner['modified_by'][3:]}".encode()
    assert len(client.get(f"/projects/{project}/files/a.didsa/versions").json()["versions"]) == 2


def test_many_writers_exactly_one_wins(client, project):
    put(client, project, "a.didsa", b"base")
    results = _race([lambda i=i: put(client, project, "a.didsa", f"w{i}".encode(), base=1) for i in range(8)])
    codes = sorted(r.status_code for r in results)
    assert codes == [200] + [412] * 7
    assert client.get(f"/projects/{project}/tree").json()["files"][0]["version"] == 2


def test_two_creators_of_one_file_one_wins(client, project):
    results = _race([lambda i=i: put(client, project, "new.didsa", f"w{i}".encode()) for i in range(2)])
    assert sorted(r.status_code for r in results) == [201, 412]


def test_two_commits_racing_on_one_file_one_wins_the_other_gets_409_and_writes_nothing(client, project, root, store):
    put(client, project, "a.didsa", b"base")
    put(client, project, "b.didsa", b"base")
    plans = []
    for i in range(2):
        plans.append(
            [
                {"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": upload(client, project, f"a by {i}".encode())},
                {"op": "put", "path": f"only-{i}.didsa", "base_version": None, "upload_id": upload(client, project, f"only {i}".encode())},
            ]
        )
    results = _race([lambda p=p, i=i: commit(client, project, p) for i, p in enumerate(plans)])
    assert sorted(r.status_code for r in results) == [200, 409]
    winner = next(i for i, r in enumerate(results) if r.status_code == 200)
    loser = 1 - winner
    files = {f["path"]: f for f in client.get(f"/projects/{project}/tree").json()["files"]}
    assert files["a.didsa"]["version"] == 2
    assert client.get(f"/projects/{project}/files/a.didsa").content == f"a by {winner}".encode()
    assert f"only-{winner}.didsa" in files and f"only-{loser}.didsa" not in files, "the loser wrote none of its files"
    assert not os.path.exists(os.path.join(root, project, f"only-{loser}.didsa"))


def test_a_stale_writer_racing_a_commit(client, project):
    put(client, project, "a.didsa", b"base")
    uid = upload(client, project, b"from commit")
    results = _race(
        [
            lambda: commit(client, project, [{"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": uid}]),
            lambda: put(client, project, "a.didsa", b"from put", base=1),
        ]
    )
    assert sorted(r.status_code for r in results) == [200, 409] or sorted(r.status_code for r in results) == [200, 412]


def test_writers_on_different_files_both_succeed(client, project):
    results = _race([lambda i=i: put(client, project, f"f{i}.didsa", b"x") for i in range(6)])
    assert [r.status_code for r in results] == [201] * 6
    assert len(client.get(f"/projects/{project}/tree").json()["files"]) == 6


def test_native_files_in_a_commit_race_keep_the_part_index_consistent(client, project):
    put(client, project, "a.didsa", native_file("P1"))
    plans = [
        [{"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": upload(client, project, native_file(f"P{i}"))}] for i in (2, 3)
    ]
    results = _race([lambda p=p: commit(client, project, p) for p in plans])
    assert sorted(r.status_code for r in results) == [200, 409]
    live = client.get(f"/projects/{project}/tree").json()["files"][0]["part_id"]
    assert live in ("P2", "P3")
    assert client.get(f"/projects/{project}/parts/P1").json()["files"] == []
    assert [f["path"] for f in client.get(f"/projects/{project}/parts/{live}").json()["files"]] == ["a.didsa"]
