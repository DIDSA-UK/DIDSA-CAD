"""A file changed outside the store (a sync client, a copy by hand) becomes a version by "outside"."""

import os

from app import store as store_module
from tests.conftest import commit, native_file, put, upload


def edit_on_disk(root, project, path, data: bytes, bump_seconds: int = 10) -> None:
    full = os.path.join(root, project, *path.split("/"))
    before = os.stat(full).st_mtime_ns if os.path.exists(full) else 0
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as handle:
        handle.write(data)
    os.utime(full, ns=(before + bump_seconds * 10**9, before + bump_seconds * 10**9))


def versions(client, project, path):
    return client.get(f"/projects/{project}/files/{path}/versions").json()["versions"]


def test_an_edit_on_disk_becomes_a_version_by_outside_and_an_old_save_is_refused(client, project, root):
    put(client, project, "a.didsa", b"v1 from the store")
    edit_on_disk(root, project, "a.didsa", b"v2 from a sync client")
    # a device that read version 1 now saves: refused, whatever it did before (no tree read in between)
    response = put(client, project, "a.didsa", b"v2 from Desktop", base=1)
    assert response.status_code == 412
    current = response.json()["current"]
    assert current["version"] == 2 and current["modified_by"] == "outside"
    # nothing of the save landed, and the outside edit is the current file
    assert client.get(f"/projects/{project}/files/a.didsa").content == b"v2 from a sync client"
    history = versions(client, project, "a.didsa")
    assert [(v["version"], v["by"]) for v in history] == [(2, "outside"), (1, "Desktop")]
    assert client.get(f"/projects/{project}/files/a.didsa/versions/1").content == b"v1 from the store"
    # a save based on the new version is accepted
    assert put(client, project, "a.didsa", b"v3", base=2).status_code == 200


def test_the_tree_notices_an_edit_a_new_file_and_a_removal(client, project, root):
    put(client, project, "a.didsa", b"a")
    put(client, project, "gone.didsa", b"gone")
    edit_on_disk(root, project, "a.didsa", b"a edited")
    edit_on_disk(root, project, "sub/new.didsa", b"dropped in by hand")
    os.unlink(os.path.join(root, project, "gone.didsa"))
    files = {f["path"]: f for f in client.get(f"/projects/{project}/tree").json()["files"]}
    assert sorted(files) == ["a.didsa", "sub/new.didsa"]
    assert files["a.didsa"]["version"] == 2 and files["a.didsa"]["modified_by"] == "outside"
    assert files["sub/new.didsa"]["version"] == 1 and files["sub/new.didsa"]["modified_by"] == "outside"
    gone = versions(client, project, "gone.didsa")
    assert gone[0]["deleted"] and gone[0]["by"] == "outside"
    assert client.get(f"/projects/{project}/files/gone.didsa/versions/1").content == b"gone"
    # the change feed says the same
    changes = client.get(f"/projects/{project}/changes").json()["changes"]
    outside = [(c["path"], c["op"], c["version"]) for c in changes if c["device"] == "outside"]
    assert sorted(outside) == [("a.didsa", "put", 2), ("gone.didsa", "delete", 2), ("sub/new.didsa", "put", 1)]


def test_a_save_over_a_file_deleted_outside_is_refused(client, project, root):
    put(client, project, "a.didsa", b"a")
    os.unlink(os.path.join(root, project, "a.didsa"))
    response = put(client, project, "a.didsa", b"mine", base=1)
    assert response.status_code == 412 and response.json()["current"]["deleted"] is True
    # and the store can create it again
    assert put(client, project, "a.didsa", b"fresh").json()["version"] == 3


def test_a_commit_over_an_outside_edit_is_409(client, project, root, store):
    put(client, project, "a.didsa", b"a")
    put(client, project, "b.didsa", b"b")
    edit_on_disk(root, project, "b.didsa", b"b outside")
    response = commit(
        client,
        project,
        [
            {"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": upload(client, project, b"a mine")},
            {"op": "put", "path": "b.didsa", "base_version": 1, "upload_id": upload(client, project, b"b mine")},
        ],
    )
    assert response.status_code == 409
    clash = response.json()["conflicts"][0]
    assert clash["path"] == "b.didsa" and clash["current"]["modified_by"] == "outside"
    assert client.get(f"/projects/{project}/files/a.didsa").content == b"a"


def test_the_scan_is_stat_first_and_hashes_only_on_a_difference(client, project, root, monkeypatch):
    for index in range(5):
        put(client, project, f"f{index}.didsa", f"content {index}".encode())
    hashed = []
    real = store_module._sha_of_file
    monkeypatch.setattr(store_module, "_sha_of_file", lambda path: hashed.append(path) or real(path))
    for _ in range(3):
        client.get(f"/projects/{project}/tree")
        client.get(f"/projects/{project}/files/f0.didsa")
        client.get(f"/projects/{project}/changes")
    assert hashed == [], "unchanged files are never re-hashed"
    edit_on_disk(root, project, "f3.didsa", b"edited")
    client.get(f"/projects/{project}/tree")
    assert len(hashed) == 1, "only the edited file is hashed"
    client.get(f"/projects/{project}/tree")
    assert len(hashed) == 1, "and only once"


def test_touched_but_not_changed_is_not_a_version(client, project, root):
    put(client, project, "a.didsa", b"same bytes")
    full = os.path.join(root, project, "a.didsa")
    stamp = os.stat(full).st_mtime_ns + 5 * 10**9
    os.utime(full, ns=(stamp, stamp))
    assert client.get(f"/projects/{project}/tree").json()["files"][0]["version"] == 1
    assert len(versions(client, project, "a.didsa")) == 1


def test_a_changed_size_with_the_same_mtime_is_noticed(client, project, root):
    put(client, project, "a.didsa", b"short")
    full = os.path.join(root, project, "a.didsa")
    stamp = os.stat(full).st_mtime_ns
    with open(full, "wb") as handle:
        handle.write(b"a much longer replacement")
    os.utime(full, ns=(stamp, stamp))
    assert client.get(f"/projects/{project}/tree").json()["files"][0]["version"] == 2


def test_outside_edit_of_a_native_file_updates_the_part_index(client, project, root):
    put(client, project, "a.didsa", native_file("OLD"))
    edit_on_disk(root, project, "a.didsa", native_file("NEW"))
    assert client.get(f"/projects/{project}/parts/NEW").json()["files"][0]["path"] == "a.didsa"
    assert client.get(f"/projects/{project}/parts/OLD").json()["files"] == []


def test_a_project_folder_copied_in_by_hand_appears(client, root):
    os.makedirs(os.path.join(root, "FromDrive", "parts"))
    with open(os.path.join(root, "FromDrive", "parts", "Shaft.didsa"), "wb") as handle:
        handle.write(native_file("S"))
    listed = client.get("/projects").json()["projects"]
    assert [(p["name"], p["file_count"], p["last_device"]) for p in listed] == [("FromDrive", 1, "outside")]
    assert client.get("/projects/FromDrive/tree").json()["files"][0]["part_id"] == "S"


def test_the_scan_skips_the_store_folder_symlinks_and_unstorable_names(client, project, root, tmp_path):
    base = os.path.join(root, project)
    with open(os.path.join(base, "ok.didsa"), "wb") as handle:
        handle.write(b"ok")
    with open(os.path.join(base, "bad:name.didsa"), "wb") as handle:
        handle.write(b"x")
    with open(tmp_path / "elsewhere.didsa", "wb") as handle:
        handle.write(b"x")
    os.symlink(tmp_path / "elsewhere.didsa", os.path.join(base, "link.didsa"))
    os.symlink(tmp_path, os.path.join(base, "linkdir"))
    os.makedirs(os.path.join(base, ".didsa-store"))
    with open(os.path.join(base, ".didsa-store", "x"), "wb") as handle:
        handle.write(b"x")
    assert [f["path"] for f in client.get(f"/projects/{project}/tree").json()["files"]] == ["ok.didsa"]
    assert [p["name"] for p in client.get("/projects").json()["projects"]] == [project]


def test_outside_changes_survive_a_restart(client, project, root, clock):
    from app.store import Store

    put(client, project, "a.didsa", b"one")
    edit_on_disk(root, project, "a.didsa", b"two")
    client.get(f"/projects/{project}/tree")
    reopened = Store(root, clock=clock)
    try:
        assert reopened.tree(project)["files"][0]["version"] == 2
        edit_on_disk(root, project, "a.didsa", b"three")
        assert reopened.tree(project)["files"][0]["version"] == 3
    finally:
        reopened.close()
