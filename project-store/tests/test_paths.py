"""Every refused path, over HTTP (PUT URL) and in a commit's JSON, plus the validator itself."""

import os
from urllib.parse import quote, unquote

import pytest

from app.paths import UnsafePath, validate_file_path, validate_project_name
from tests.conftest import commit, disk_state, upload

REFUSED = {
    "dotdot-start": "../escape.didsa",
    "dotdot-middle": "a/../../escape.didsa",
    "dotdot-only": "..",
    "dot": "a/./b.didsa",
    "absolute": "/etc/passwd",
    "empty-part": "a//b.didsa",
    "backslash": "a\\b.didsa",
    "backslash-dotdot": "..\\x.didsa",
    "store-dir": ".didsa-store/store.sqlite",
    "store-dir-nested": "a/.didsa-store/x",
    "store-dir-case": ".DIDSA-STORE/x",
    "colon": "C:/x.didsa",
    "colon-name": "a:b.didsa",
    "star": "a*.didsa",
    "question": "a?.didsa",
    "quote": 'a".didsa',
    "angle": "a<b>.didsa",
    "pipe": "a|b.didsa",
    "control-char": "a\x01b.didsa",
    "trailing-dot": "a/name.",
    "trailing-space": "a/name ",
    "reserved-con": "CON",
    "reserved-with-extension": "parts/nul.didsa",
    "reserved-lower": "aux.txt",
    "reserved-com1": "com1.x",
    "reserved-lpt9": "LPT9",
    "long-name": "x" * 256,
    "versions-collision": "a/versions",
    "versions-number-collision": "a/versions/3",
}


@pytest.mark.parametrize("path", REFUSED.values(), ids=REFUSED.keys())
def test_validator_refuses(path):
    with pytest.raises(UnsafePath):
        validate_file_path(path)


@pytest.mark.parametrize("path", ["Gearbox.didsa", "parts/Shaft v2.didsa", "a/b/c/d.step", "naïve/ü.didsa", "versions/x.didsa", "a/versions/readme"])
def test_validator_accepts(path):
    assert validate_file_path(path) == path


@pytest.mark.parametrize("name", ["", ".hidden", "a/b", "..", ".didsa-store", "CON", "a:b", "x" * 256, "name."])
def test_project_name_refused(name):
    with pytest.raises(UnsafePath):
        validate_project_name(name)


@pytest.mark.parametrize("name", ["..", ".hidden", "a/b", ".didsa-store", "CON", "a\\b", "", "q?"])
def test_create_project_refuses_bad_names(client, root, name):
    assert client.post("/projects", json={"name": name}).status_code == 400
    assert client.get("/projects").json() == {"projects": []}


@pytest.mark.parametrize("path", REFUSED.values(), ids=REFUSED.keys())
def test_put_url_refuses(client, project, root, path):
    # A path that cannot be sent in a URL as is (the client library may rewrite ".."), or arrives as another one, must still end
    # up refused or at worst stored under a safe name inside the project: never outside it, never in .didsa-store.
    before = disk_state(root)
    response = client.put(f"/projects/{project}/files/{quote(path, safe='/')}", content=b"x", headers={"If-None-Match": "*"})
    url_path = str(response.request.url.path)
    sent = unquote(url_path.split("/files/", 1)[1]) if "/files/" in url_path else None
    if sent == path:
        assert response.status_code == 400, (path, response.status_code)
        assert disk_state(root) == before
    else:
        # The HTTP client itself rewrote the URL (it resolves "." and ".." segments): the commit test below sends the raw string.
        assert all(key.startswith(project + os.sep) for key in disk_state(root))


@pytest.mark.parametrize("path", REFUSED.values(), ids=REFUSED.keys())
def test_commit_refuses_each_path_and_writes_nothing(client, project, root, store, path):
    from tests.conftest import db_state

    good = upload(client, project, b"good")
    bad = upload(client, project, b"bad")
    before_disk, before_db = disk_state(root), db_state(store)
    response = commit(
        client,
        project,
        [
            {"op": "put", "path": "fine.didsa", "base_version": None, "upload_id": good},
            {"op": "put", "path": path, "base_version": None, "upload_id": bad},
        ],
    )
    assert response.status_code == 400, path
    assert disk_state(root) == before_disk and db_state(store) == before_db


def test_commit_refuses_an_unsafe_move_target(client, project):
    uid = upload(client, project, b"a")
    assert commit(client, project, [{"op": "put", "path": "a.didsa", "base_version": None, "upload_id": uid}]).status_code == 200
    response = commit(client, project, [{"op": "move", "path": "a.didsa", "to": "../out.didsa", "base_version": 1}])
    assert response.status_code == 400


def test_get_and_delete_refuse_bad_paths_too(client, project):
    assert client.get(f"/projects/{project}/files/{quote('a:b', safe='')}").status_code == 400
    assert client.delete(f"/projects/{project}/files//etc/passwd", headers={"If-Match": '"1"'}).status_code == 400
    assert client.get(f"/projects/{project}/files/.didsa-store/store.sqlite").status_code == 400
    assert client.get(f"/projects/{project}/files/.didsa-store/blobs/x").status_code == 400


def test_project_names_in_urls_cannot_reach_the_store_folder(client):
    assert client.get("/projects/.didsa-store/tree").status_code == 404
    assert client.get("/projects/..%2F/tree").status_code in (400, 404)


def test_a_symlink_inside_a_project_cannot_lead_out_of_it(client, project, root, tmp_path):
    import os

    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, os.path.join(root, project, "link"))
    response = client.put(f"/projects/{project}/files/link/escape.didsa", content=b"x", headers={"If-None-Match": "*"})
    assert response.status_code == 400
    assert list(outside.iterdir()) == []
