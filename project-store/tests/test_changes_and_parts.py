"""The change feed from a cursor, and the part-id index."""

import os

from tests.conftest import commit, native_file, put, upload


def feed(client, project, since=None, **params):
    query = dict(params)
    if since is not None:
        query["since"] = since
    return client.get(f"/projects/{project}/changes", params=query)


def test_feed_from_the_start_and_from_a_cursor(client, project):
    assert feed(client, project).json() == {"project": project, "changes": [], "cursor": "0", "more": False}
    put(client, project, "a.didsa", b"1", device="Desktop")
    put(client, project, "b.didsa", b"1", device="Quest 3")
    first = feed(client, project).json()
    assert [(c["path"], c["op"], c["version"], c["device"]) for c in first["changes"]] == [
        ("a.didsa", "put", 1, "Desktop"),
        ("b.didsa", "put", 1, "Quest 3"),
    ]
    assert all("at" in c for c in first["changes"])
    cursor = first["cursor"]
    assert feed(client, project, cursor).json()["changes"] == []
    put(client, project, "a.didsa", b"2", base=1, device="Quest 3")
    client.delete(f"/projects/{project}/files/b.didsa", headers={"If-Match": '"1"', "X-Device-Name": "Desktop"})
    later = feed(client, project, cursor).json()
    assert [(c["path"], c["op"], c["version"], c["device"]) for c in later["changes"]] == [
        ("a.didsa", "put", 2, "Quest 3"),
        ("b.didsa", "delete", 2, "Desktop"),
    ]
    assert feed(client, project, later["cursor"]).json()["changes"] == []
    # asking again from the old cursor gives the same answer (a cursor is a place, not a subscription)
    assert feed(client, project, cursor).json()["changes"] == later["changes"]


def test_the_tree_cursor_starts_the_feed_where_the_tree_ends(client, project):
    put(client, project, "a.didsa", b"1")
    tree_cursor = client.get(f"/projects/{project}/tree").json()["cursor"]
    assert feed(client, project, tree_cursor).json()["changes"] == []
    put(client, project, "b.didsa", b"1")
    assert [c["path"] for c in feed(client, project, tree_cursor).json()["changes"]] == ["b.didsa"]


def test_a_commit_is_in_the_feed_as_all_its_files(client, project):
    cursor = feed(client, project).json()["cursor"]
    commit(client, project, [{"op": "put", "path": f"{n}.didsa", "base_version": None, "upload_id": upload(client, project, n.encode())} for n in "abc"])
    assert [c["path"] for c in feed(client, project, cursor).json()["changes"]] == ["a.didsa", "b.didsa", "c.didsa"]


def test_a_refused_write_is_not_in_the_feed(client, project):
    put(client, project, "a.didsa", b"1")
    cursor = feed(client, project).json()["cursor"]
    assert put(client, project, "a.didsa", b"2", base=9).status_code == 412
    assert put(client, project, "a.didsa", b"1", base=1).status_code == 200  # unchanged
    assert feed(client, project, cursor).json()["changes"] == []


def test_a_move_is_a_delete_and_a_put_that_say_so(client, project):
    put(client, project, "a.didsa", b"1")
    cursor = feed(client, project).json()["cursor"]
    commit(client, project, [{"op": "move", "path": "a.didsa", "to": "sub/b.didsa", "base_version": 1}])
    changes = feed(client, project, cursor).json()["changes"]
    by_path = {c["path"]: c for c in changes}
    assert by_path["a.didsa"]["op"] == "delete" and by_path["a.didsa"]["moved_to"] == "sub/b.didsa"
    assert by_path["sub/b.didsa"]["op"] == "put" and by_path["sub/b.didsa"]["moved_from"] == "a.didsa"


def test_paging_with_a_limit(client, project):
    for index in range(5):
        put(client, project, f"f{index}.didsa", b"x")
    page = feed(client, project, limit=2).json()
    assert [c["path"] for c in page["changes"]] == ["f0.didsa", "f1.didsa"] and page["more"] is True
    page2 = feed(client, project, page["cursor"], limit=2).json()
    assert [c["path"] for c in page2["changes"]] == ["f2.didsa", "f3.didsa"] and page2["more"] is True
    page3 = feed(client, project, page2["cursor"], limit=2).json()
    assert [c["path"] for c in page3["changes"]] == ["f4.didsa"] and page3["more"] is False
    assert feed(client, project, page3["cursor"]).json()["changes"] == []


def test_the_feed_is_per_project(client, project):
    client.post("/projects", json={"name": "Other"})
    put(client, "Other", "o.didsa", b"x")
    put(client, project, "a.didsa", b"x")
    assert [c["path"] for c in feed(client, project).json()["changes"]] == ["a.didsa"]
    cursor = feed(client, project).json()["cursor"]
    assert feed(client, "Other", cursor).status_code == 200  # a cursor from one project is fine for another


def test_bad_cursors_are_400(client, project):
    put(client, project, "a.didsa", b"x")
    for cursor in ("abc", "-1", "999999", "1.5"):
        response = feed(client, project, cursor)
        assert response.status_code == 400, cursor
        assert response.json()["error"] == "bad_cursor"
    assert client.get(f"/projects/{project}/changes", params={"limit": 0}).status_code == 422


# ---- the part-id index


def test_parts_index_finds_the_paths_with_a_root_part_id(client, project):
    put(client, project, "Gearbox.didsa", native_file("P-root"))
    put(client, project, "parts/Shaft.didsa", native_file("P-shaft"))
    put(client, project, "backup/Shaft copy.didsa", native_file("P-shaft"))  # two files, one id: the index says so
    put(client, project, "notes.txt", b"x")
    response = client.get(f"/projects/{project}/parts/P-shaft")
    assert response.status_code == 200
    body = response.json()
    assert body["part_id"] == "P-shaft"
    assert [f["path"] for f in body["files"]] == ["backup/Shaft copy.didsa", "parts/Shaft.didsa"]
    assert body["files"][0]["version"] == 1 and "sha256" in body["files"][0]
    assert [f["path"] for f in client.get(f"/projects/{project}/parts/P-root").json()["files"]] == ["Gearbox.didsa"]
    assert client.get(f"/projects/{project}/parts/unknown").json() == {"part_id": "unknown", "files": []}


def test_parts_index_follows_a_rename(client, project, root):
    put(client, project, "parts/Shaft.didsa", native_file("P-shaft"))
    commit(client, project, [{"op": "move", "path": "parts/Shaft.didsa", "to": "parts/Shaft-v2.didsa", "base_version": 1}])
    paths = [f["path"] for f in client.get(f"/projects/{project}/parts/P-shaft").json()["files"]]
    assert paths == ["parts/Shaft-v2.didsa"]


def test_parts_index_follows_a_rename_done_outside_the_store(client, project, root):
    put(client, project, "parts/Shaft.didsa", native_file("P-shaft"))
    os.rename(os.path.join(root, project, "parts", "Shaft.didsa"), os.path.join(root, project, "parts", "Shaft-renamed.didsa"))
    paths = [f["path"] for f in client.get(f"/projects/{project}/parts/P-shaft").json()["files"]]
    assert paths == ["parts/Shaft-renamed.didsa"]


def test_parts_index_forgets_a_deleted_file_and_follows_an_edit(client, project):
    put(client, project, "a.didsa", native_file("P1"))
    put(client, project, "a.didsa", native_file("P2"), base=1)
    assert client.get(f"/projects/{project}/parts/P1").json()["files"] == []
    assert len(client.get(f"/projects/{project}/parts/P2").json()["files"]) == 1
    client.delete(f"/projects/{project}/files/a.didsa", headers={"If-Match": '"2"'})
    assert client.get(f"/projects/{project}/parts/P2").json()["files"] == []


def test_parts_index_is_per_project(client, project):
    client.post("/projects", json={"name": "Other"})
    put(client, "Other", "a.didsa", native_file("P"))
    assert client.get(f"/projects/{project}/parts/P").json()["files"] == []
