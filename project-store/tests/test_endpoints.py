"""Every endpoint: its success and its error cases."""

import hashlib
import os

from tests.conftest import commit, native_file, put, upload


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ---- projects


def test_projects_empty_create_list(client, root):
    assert client.get("/projects").json() == {"projects": []}
    created = client.post("/projects", json={"name": "Gearbox"}, headers={"X-Device-Name": "Quest 3"})
    assert created.status_code == 201
    assert created.json()["name"] == "Gearbox" and created.json()["file_count"] == 0
    assert os.path.isdir(os.path.join(root, "Gearbox"))
    listed = client.get("/projects").json()["projects"]
    assert [p["name"] for p in listed] == ["Gearbox"]
    assert listed[0]["last_change"] is None and listed[0]["last_device"] is None


def test_project_summary_counts_size_last_change_and_device(client, project, clock):
    put(client, project, "a.didsa", b"12345")
    clock.advance(60)
    put(client, project, "b/c.didsa", b"123", device="Quest 3")
    entry = client.get("/projects").json()["projects"][0]
    assert entry["file_count"] == 2 and entry["total_size"] == 8
    assert entry["last_device"] == "Quest 3"
    assert entry["last_change"].startswith("2027-") or entry["last_change"].startswith("2026-")


def test_create_project_twice_is_409_even_in_another_case(client, project):
    assert client.post("/projects", json={"name": project}).status_code == 409
    assert client.post("/projects", json={"name": project.lower()}).status_code == 409


def test_create_project_body_must_be_json_with_a_name(client):
    assert client.post("/projects", json={}).status_code == 422
    assert client.post("/projects", content=b"nope").status_code == 422


def test_unknown_project_is_404_everywhere(client):
    for method, url, kwargs in [
        ("get", "/projects/Nope/tree", {}),
        ("get", "/projects/Nope/files/a.didsa", {}),
        ("put", "/projects/Nope/files/a.didsa", {"content": b"x", "headers": {"If-None-Match": "*"}}),
        ("delete", "/projects/Nope/files/a.didsa", {"headers": {"If-Match": '"1"'}}),
        ("post", "/projects/Nope/commit", {"json": {"changes": []}}),
        ("post", "/projects/Nope/uploads", {"content": b"x"}),
        ("get", "/projects/Nope/files/a.didsa/versions", {}),
        ("get", "/projects/Nope/files/a.didsa/versions/1", {}),
        ("get", "/projects/Nope/changes", {}),
        ("get", "/projects/Nope/parts/x", {}),
    ]:
        response = getattr(client, method)(url, **kwargs)
        assert response.status_code == 404, url
        assert response.json()["error"] == "no_such_project"


# ---- PUT / GET / DELETE


def test_create_then_read_back_with_etag(client, project, root):
    response = put(client, project, "parts/Shaft.didsa", b"hello")
    assert response.status_code == 201
    body = response.json()
    assert body["version"] == 1 and body["sha256"] == sha(b"hello") and body["size"] == 5
    assert body["modified_by"] == "Desktop" and body["part_id"] is None
    assert response.headers["etag"] == '"1"'
    # plain file at its real path
    with open(os.path.join(root, project, "parts", "Shaft.didsa"), "rb") as handle:
        assert handle.read() == b"hello"
    got = client.get(f"/projects/{project}/files/parts/Shaft.didsa")
    assert got.status_code == 200 and got.content == b"hello"
    assert got.headers["etag"] == '"1"' and got.headers["x-sha256"] == sha(b"hello")


def test_overwrite_with_if_match(client, project):
    put(client, project, "a.didsa", b"one")
    response = put(client, project, "a.didsa", b"two", base=1)
    assert response.status_code == 200 and response.json()["version"] == 2
    assert response.headers["etag"] == '"2"'
    assert client.get(f"/projects/{project}/files/a.didsa").content == b"two"


def test_a_save_that_changes_nothing_costs_nothing(client, project, store):
    put(client, project, "a.didsa", b"same")
    response = put(client, project, "a.didsa", b"same", base=1)
    assert response.status_code == 200
    assert response.json()["version"] == 1 and response.json()["unchanged"] is True
    assert len(client.get(f"/projects/{project}/files/a.didsa/versions").json()["versions"]) == 1
    assert len(client.get(f"/projects/{project}/changes").json()["changes"]) == 1


def test_put_without_a_precondition_is_428_and_writes_nothing(client, project, root):
    response = client.put(f"/projects/{project}/files/a.didsa", content=b"x")
    assert response.status_code == 428 and response.json()["error"] == "precondition_required"
    assert not os.path.exists(os.path.join(root, project, "a.didsa"))
    put(client, project, "a.didsa", b"v1")
    assert client.put(f"/projects/{project}/files/a.didsa", content=b"v2").status_code == 428
    assert client.get(f"/projects/{project}/files/a.didsa").content == b"v1"


def test_malformed_preconditions_are_400(client, project):
    url = f"/projects/{project}/files/a.didsa"
    for headers in [
        {"If-Match": "abc"},
        {"If-Match": '"0"'},
        {"If-Match": "*"},
        {"If-Match": 'W/"1"'},
        {"If-None-Match": '"1"'},
        {"If-Match": '"1"', "If-None-Match": "*"},
    ]:
        assert client.put(url, content=b"x", headers=headers).status_code == 400, headers
    assert client.delete(url, headers={"If-None-Match": "*"}).status_code == 428  # a delete needs If-Match; this is not one
    assert client.delete(url, headers={"If-Match": "*"}).status_code == 400


def test_create_when_it_exists_is_412_with_the_current_version(client, project):
    put(client, project, "a.didsa", b"first")
    response = put(client, project, "a.didsa", b"second")
    assert response.status_code == 412
    body = response.json()
    assert body["error"] == "stale_version" and body["current"]["version"] == 1
    assert body["current"]["sha256"] == sha(b"first") and body["current"]["modified_by"] == "Desktop"
    assert response.headers["etag"] == '"1"'
    assert client.get(f"/projects/{project}/files/a.didsa").content == b"first"


def test_overwrite_a_file_that_does_not_exist_is_412(client, project):
    response = put(client, project, "ghost.didsa", b"x", base=1)
    assert response.status_code == 412 and response.json()["current"] is None


def test_get_missing_file_is_404(client, project):
    assert client.get(f"/projects/{project}/files/none.didsa").status_code == 404


def test_put_over_the_size_limit_is_413_and_leaves_nothing(client, project, store, root):
    big = b"x" * (store.max_file_bytes + 1)
    response = client.put(f"/projects/{project}/files/big.step", content=big, headers={"If-None-Match": "*"})
    assert response.status_code == 413
    assert not os.path.exists(os.path.join(root, project, "big.step"))
    assert os.listdir(store.tmp_dir) == []
    assert client.post(f"/projects/{project}/uploads", content=big).status_code == 413


def test_an_empty_file_is_a_file(client, project):
    assert put(client, project, "empty.txt", b"").status_code == 201
    assert client.get(f"/projects/{project}/files/empty.txt").content == b""


def test_tree_lists_every_file_with_its_details(client, project):
    put(client, project, "Gearbox.didsa", native_file("P-root"))
    put(client, project, "parts/Shaft.didsa", native_file("P-shaft"))
    put(client, project, "notes.txt", b"not native")
    put(client, project, "parts/Shaft.didsa", native_file("P-shaft", "edited"), base=1, device="Quest 3")
    tree = client.get(f"/projects/{project}/tree").json()
    by_path = {f["path"]: f for f in tree["files"]}
    assert sorted(by_path) == ["Gearbox.didsa", "notes.txt", "parts/Shaft.didsa"]
    assert by_path["Gearbox.didsa"]["part_id"] == "P-root"
    assert by_path["parts/Shaft.didsa"]["part_id"] == "P-shaft" and by_path["parts/Shaft.didsa"]["version"] == 2
    assert by_path["parts/Shaft.didsa"]["modified_by"] == "Quest 3"
    assert by_path["notes.txt"]["part_id"] is None
    assert set(by_path["notes.txt"]) == {"path", "size", "sha256", "version", "modified_at", "modified_by", "part_id"}
    assert tree["cursor"] == "4"


def test_part_id_is_read_only_from_the_root_field(client, project, tmp_path):
    cases = {
        "ok.didsa": native_file("R1"),
        "no-root.didsa": native_file(None),
        "broken.didsa": b'{"document": {"root_part_id": "R2"',
        "binary.didsa": b"\x89PNG\r\n\x1a\n" + b"\x00" * 50,
        "list.didsa": b"[1, 2, 3]",
        "number-root.didsa": b'{"document": {"root_part_id": 7}}',
        "elsewhere.didsa": b'{"root_part_id": "TOP", "document": {"parts": [{"root_part_id": "NESTED"}]}}',
        "other.json": native_file("R3"),
    }
    for name, data in cases.items():
        assert put(client, project, name, data).status_code == 201
    parts = {f["path"]: f["part_id"] for f in client.get(f"/projects/{project}/tree").json()["files"]}
    assert parts == {
        "ok.didsa": "R1",
        "no-root.didsa": None,
        "broken.didsa": None,
        "binary.didsa": None,
        "list.didsa": None,
        "number-root.didsa": None,
        "elsewhere.didsa": None,
        "other.json": None,
    }


def test_part_id_of_a_real_backend_file(client, project):
    """A real native file from the backend's own test data (read-only: nothing from the backend is imported)."""
    import json

    path = os.path.join(os.path.dirname(__file__), "..", "..", "backend", "tests", "data", "frame_a_save_as_source.DIDSAprt")
    if not os.path.exists(path):
        import pytest

        pytest.skip("backend test data not present (the store's image carries only project-store/)")
    with open(path, "rb") as handle:
        data = handle.read()
    expected = json.loads(data)["document"]["root_part_id"]
    assert put(client, project, "frame.DIDSAprt", data).json()["part_id"] == expected


def test_delete_with_if_match(client, project, root):
    put(client, project, "a/b.didsa", b"x")
    response = client.delete(f"/projects/{project}/files/a/b.didsa", headers={"If-Match": '"1"', "X-Device-Name": "Quest 3"})
    assert response.status_code == 200
    assert response.json()["version"] == 2 and response.json()["deleted"] is True
    assert not os.path.exists(os.path.join(root, project, "a", "b.didsa"))
    assert not os.path.exists(os.path.join(root, project, "a")), "the emptied folder is tidied away"
    assert client.get(f"/projects/{project}/files/a/b.didsa").status_code == 404
    assert client.get(f"/projects/{project}/tree").json()["files"] == []
    # the history is kept
    versions = client.get(f"/projects/{project}/files/a/b.didsa/versions").json()["versions"]
    assert [(v["version"], v["deleted"], v["by"]) for v in versions] == [(2, True, "Quest 3"), (1, False, "Desktop")]
    assert client.get(f"/projects/{project}/files/a/b.didsa/versions/1").content == b"x"


def test_delete_errors(client, project):
    put(client, project, "a.didsa", b"x")
    assert client.delete(f"/projects/{project}/files/a.didsa").status_code == 428
    stale = client.delete(f"/projects/{project}/files/a.didsa", headers={"If-Match": '"7"'})
    assert stale.status_code == 412 and stale.json()["current"]["version"] == 1
    assert client.get(f"/projects/{project}/files/a.didsa").content == b"x"
    assert client.delete(f"/projects/{project}/files/none.didsa", headers={"If-Match": '"1"'}).status_code == 404
    client.delete(f"/projects/{project}/files/a.didsa", headers={"If-Match": '"1"'})
    again = client.delete(f"/projects/{project}/files/a.didsa", headers={"If-Match": '"1"'})
    assert again.status_code == 412 and again.json()["current"]["deleted"] is True


def test_recreate_after_delete_continues_the_counter(client, project):
    put(client, project, "a.didsa", b"x")
    client.delete(f"/projects/{project}/files/a.didsa", headers={"If-Match": '"1"'})
    assert put(client, project, "a.didsa", b"y").json()["version"] == 3
    # a stale device that still holds version 1 is refused, not mistaken for the new file
    assert put(client, project, "a.didsa", b"z", base=1).status_code == 412


def test_a_file_cannot_also_be_a_folder(client, project, root):
    put(client, project, "a", b"file")
    response = put(client, project, "a/b.didsa", b"x")
    assert response.status_code == 409 and response.json()["error"] == "path_conflict"
    put(client, project, "d/x.didsa", b"x")
    assert put(client, project, "d", b"x").status_code == 409
    assert sorted(os.listdir(os.path.join(root, project))) == ["a", "d"]


# ---- versions


def test_versions_list_and_bytes(client, project):
    put(client, project, "a.didsa", b"one")
    put(client, project, "a.didsa", b"two", base=1, device="Quest 3")
    listing = client.get(f"/projects/{project}/files/a.didsa/versions").json()
    assert listing["path"] == "a.didsa"
    assert [(v["version"], v["size"], v["sha256"], v["by"]) for v in listing["versions"]] == [
        (2, 3, sha(b"two"), "Quest 3"),
        (1, 3, sha(b"one"), "Desktop"),
    ]
    assert "at" in listing["versions"][0]
    one = client.get(f"/projects/{project}/files/a.didsa/versions/1")
    assert one.content == b"one" and one.headers["etag"] == '"1"'
    assert client.get(f"/projects/{project}/files/a.didsa/versions/2").content == b"two"


def test_version_errors(client, project):
    put(client, project, "a.didsa", b"one")
    assert client.get(f"/projects/{project}/files/a.didsa/versions/9").status_code == 404
    assert client.get(f"/projects/{project}/files/nope.didsa/versions").status_code == 404
    assert client.get(f"/projects/{project}/files/nope.didsa/versions/1").status_code == 404
    client.delete(f"/projects/{project}/files/a.didsa", headers={"If-Match": '"1"'})
    assert client.get(f"/projects/{project}/files/a.didsa/versions/2").status_code == 404  # a delete has no bytes


def test_a_folder_called_versions_still_works(client, project):
    put(client, project, "versions/x.didsa", b"x")
    assert client.get(f"/projects/{project}/files/versions/x.didsa").content == b"x"


# ---- uploads and commit (success)


def test_upload_returns_an_id_and_hash(client, project):
    response = client.post(f"/projects/{project}/uploads", content=b"abc")
    assert response.status_code == 201
    body = response.json()
    assert body["size"] == 3 and body["sha256"] == sha(b"abc") and len(body["upload_id"]) >= 16 and "expires_at" in body


def test_commit_of_several_files_is_one_step(client, project, root):
    a, b, c = (upload(client, project, native_file(name)) for name in ("A", "B", "C"))
    response = commit(
        client,
        project,
        [
            {"op": "put", "path": "Gearbox.didsa", "base_version": None, "upload_id": a},
            {"op": "put", "path": "parts/B.didsa", "base_version": None, "upload_id": b},
            {"op": "put", "path": "parts/C.didsa", "base_version": None, "upload_id": c},
        ],
        message="Save All",
        )
    assert response.status_code == 200, response.text
    files = {f["path"]: f for f in response.json()["files"]}
    assert {p: f["version"] for p, f in files.items()} == {"Gearbox.didsa": 1, "parts/B.didsa": 1, "parts/C.didsa": 1}
    assert files["parts/B.didsa"]["part_id"] == "B"
    assert sorted(os.listdir(os.path.join(root, project))) == ["Gearbox.didsa", "parts"]
    # a second commit replaces two of them and deletes one, each against its own version
    d, e = upload(client, project, native_file("A", "edit")), upload(client, project, native_file("B", "edit"))
    response = commit(
        client,
        project,
        [
            {"op": "put", "path": "Gearbox.didsa", "base_version": 1, "upload_id": d},
            {"op": "put", "path": "parts/B.didsa", "base_version": 1, "upload_id": e},
            {"op": "delete", "path": "parts/C.didsa", "base_version": 1},
        ],
    )
    assert response.status_code == 200, response.text
    versions = {f["path"]: f["version"] for f in response.json()["files"]}
    assert versions == {"Gearbox.didsa": 2, "parts/B.didsa": 2, "parts/C.didsa": 2}
    assert client.get(f"/projects/{project}/files/parts/C.didsa").status_code == 404


def test_commit_message_is_kept_with_the_versions(client, project):
    uid = upload(client, project, b"x")
    commit(client, project, [{"op": "put", "path": "a.didsa", "base_version": None, "upload_id": uid}], message="first save")
    assert client.get(f"/projects/{project}/files/a.didsa/versions").json()["versions"][0]["message"] == "first save"


def test_commit_with_no_changes_is_a_no_op(client, project):
    assert commit(client, project, []).status_code == 200


def test_commit_move(client, project, root):
    put(client, project, "a/Shaft.didsa", native_file("S"))
    response = commit(client, project, [{"op": "move", "path": "a/Shaft.didsa", "to": "parts/Shaft-v2.didsa", "base_version": 1}], message="rename")
    assert response.status_code == 200, response.text
    files = {f["path"]: f for f in response.json()["files"]}
    assert files["a/Shaft.didsa"]["deleted"] and files["a/Shaft.didsa"]["moved_to"] == "parts/Shaft-v2.didsa"
    assert files["parts/Shaft-v2.didsa"]["version"] == 1 and files["parts/Shaft-v2.didsa"]["part_id"] == "S"
    assert not os.path.exists(os.path.join(root, project, "a"))
    assert client.get(f"/projects/{project}/files/parts/Shaft-v2.didsa").status_code == 200


def test_the_same_upload_can_be_used_once_it_commits_it_is_spent(client, project):
    uid = upload(client, project, b"x")
    change = {"op": "put", "path": "a.didsa", "base_version": None, "upload_id": uid}
    assert commit(client, project, [change]).status_code == 200
    again = commit(client, project, [{**change, "path": "b.didsa"}])
    assert again.status_code == 400 and again.json()["error"] == "unknown_upload"


# ---- commit (errors that are not clashes)


def test_commit_bad_requests(client, project, store):
    uid = upload(client, project, b"x")
    other = upload(client, project, b"y")
    bad = [
        [{"op": "rename", "path": "a.didsa", "base_version": None}],
        [{"op": "put", "path": "a.didsa", "base_version": None, "upload_id": "nope"}],
        [{"op": "put", "path": "a.didsa", "base_version": None}],
        [{"op": "put", "path": "a.didsa", "base_version": 0, "upload_id": uid}],
        [{"op": "put", "path": "a.didsa", "base_version": "1", "upload_id": uid}],
        [{"op": "put", "path": "a.didsa", "base_version": True, "upload_id": uid}],
        [{"op": "delete", "path": "a.didsa", "base_version": None}],
        [{"op": "move", "path": "a.didsa", "base_version": 1}],
        [{"op": "move", "path": "a.didsa", "to": "a.didsa", "base_version": 1}],
        [{"op": "put", "path": "a.didsa", "base_version": None, "upload_id": uid}, {"op": "put", "path": "a.didsa", "base_version": None, "upload_id": other}],
        [{"op": "put"}],
        ["not an object"],
    ]
    for changes in bad:
        assert commit(client, project, changes).status_code in (400, 422), changes
    assert client.get(f"/projects/{project}/tree").json()["files"] == []
    assert commit(client, project, "x").status_code == 422


def test_an_upload_belongs_to_its_project(client, project):
    client.post("/projects", json={"name": "Other"})
    uid = upload(client, "Other", b"x")
    response = commit(client, project, [{"op": "put", "path": "a.didsa", "base_version": None, "upload_id": uid}])
    assert response.status_code == 400


def test_an_upload_expires_after_an_hour(client, project, clock):
    uid = upload(client, project, b"x")
    clock.advance(3599)
    assert commit(client, project, [{"op": "put", "path": "ok.didsa", "base_version": None, "upload_id": uid}]).status_code == 200
    stale = upload(client, project, b"y")
    clock.advance(3601)
    response = commit(client, project, [{"op": "put", "path": "late.didsa", "base_version": None, "upload_id": stale}])
    assert response.status_code == 400 and response.json()["error"] == "unknown_upload"


def test_device_name_is_recorded_and_cleaned_but_trusted_for_nothing(client, project):
    response = client.put(
        f"/projects/{project}/files/a.didsa",
        content=b"x",
        headers={"If-None-Match": "*", "X-Device-Name": "  Quest 3\t" + "z" * 200},
    )
    assert response.status_code == 201
    name = response.json()["modified_by"]
    assert name.startswith("Quest 3") and len(name) <= 80 and "\t" not in name
    nameless = client.put(f"/projects/{project}/files/b.didsa", content=b"x", headers={"If-None-Match": "*", "X-Device-Name": ""}, )
    assert nameless.json()["modified_by"] == "unknown"
    # a claim to be the outside scan is just a name; it gets no special treatment (the scan's versions are told apart by what wrote them)
    assert put(client, project, "c.didsa", b"x", device="outside").status_code == 201
