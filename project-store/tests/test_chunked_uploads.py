"""S4: chunked upload (a file too big for one request, e.g. past a Cloudflare tunnel's 100 MB limit). Session, in-order chunks, resume
after a cut, the declared SHA-256 checked at the end, survival of a store restart, and an old store file migrating."""

import hashlib
import os
import sqlite3

from fastapi.testclient import TestClient

from app import api as api_module
from app.api import create_app
from app.store import CHUNK_SIZE, Store
from tests.conftest import HEADERS, TEST_KEY, commit, db_state, disk_state, native_file


def session(client, project, data: bytes, sha: str | None = None):
    return client.post(f"/projects/{project}/uploads/sessions", json={"size": len(data), "sha256": sha or hashlib.sha256(data).hexdigest()})


def chunk(client, project, upload_id, offset, data: bytes):
    return client.put(f"/projects/{project}/uploads/{upload_id}", params={"offset": offset}, content=data)


def send_all(client, project, data: bytes, size: int = 10):
    opened = session(client, project, data)
    assert opened.status_code == 201, opened.text
    upload_id = opened.json()["upload_id"]
    for offset in range(0, len(data), size):
        answer = chunk(client, project, upload_id, offset, data[offset : offset + size])
        assert answer.status_code == 200, answer.text
    return upload_id


def test_health_advertises_chunked_uploads(client):
    assert "uploads.chunked" in client.get("/health").json()["api_features"]


def test_chunks_then_complete_then_commit(client, project, root):
    data = native_file("rp-1", "x" * 95)
    upload_id = send_all(client, project, data, size=17)
    done = client.post(f"/projects/{project}/uploads/{upload_id}/complete")
    assert done.status_code == 200, done.text
    assert done.json()["sha256"] == hashlib.sha256(data).hexdigest() and done.json()["size"] == len(data)
    answer = commit(client, project, [{"op": "put", "path": "big.didsa", "base_version": None, "upload_id": upload_id}])
    assert answer.status_code == 200, answer.text
    assert disk_state(root)[os.path.join(project, "big.didsa")] == data
    assert client.get(f"/projects/{project}/files/big.didsa").content == data
    assert client.get(f"/projects/{project}/parts/rp-1").json()["files"][0]["path"] == "big.didsa"  # part id read at complete


def test_status_and_resume_after_a_cut(client, project):
    data = bytes(range(200))
    upload_id = session(client, project, data).json()["upload_id"]
    assert chunk(client, project, upload_id, 0, data[:60]).json()["received"] == 60
    # the client lost the reply to its next chunk and does not know whether it landed: it asks
    status = client.get(f"/projects/{project}/uploads/{upload_id}").json()
    assert status["received"] == 60 and status["size"] == 200 and status["complete"] is False
    # sending the chunk it believes is next, from the wrong place, is refused and says where to go on from
    wrong = chunk(client, project, upload_id, 100, data[100:140])
    assert wrong.status_code == 409 and wrong.json()["error"] == "wrong_offset" and wrong.json()["received"] == 60
    assert chunk(client, project, upload_id, 60, data[60:]).json()["received"] == 200
    assert client.post(f"/projects/{project}/uploads/{upload_id}/complete").status_code == 200


def test_a_chunk_sent_twice_does_not_corrupt_the_file(client, project):
    data = b"abcdefghij" * 5
    upload_id = session(client, project, data).json()["upload_id"]
    chunk(client, project, upload_id, 0, data[:20])
    assert chunk(client, project, upload_id, 0, data[:20]).status_code == 409  # a repeated chunk is refused, not appended
    chunk(client, project, upload_id, 20, data[20:])
    assert client.post(f"/projects/{project}/uploads/{upload_id}/complete").status_code == 200


def test_complete_too_early_says_how_much_is_missing(client, project):
    data = b"z" * 50
    upload_id = session(client, project, data).json()["upload_id"]
    chunk(client, project, upload_id, 0, data[:30])
    early = client.post(f"/projects/{project}/uploads/{upload_id}/complete")
    assert early.status_code == 409 and early.json()["error"] == "incomplete" and early.json()["received"] == 30


def test_wrong_hash_discards_the_upload(client, project, store):
    data = b"q" * 40
    upload_id = session(client, project, data, sha="0" * 64).json()["upload_id"]
    chunk(client, project, upload_id, 0, data)
    bad = client.post(f"/projects/{project}/uploads/{upload_id}/complete")
    assert bad.status_code == 400 and bad.json()["error"] == "checksum_mismatch"
    assert client.get(f"/projects/{project}/uploads/{upload_id}").status_code == 404
    assert not os.path.exists(os.path.join(store.upload_dir, upload_id))


def test_an_unfinished_upload_cannot_be_committed(client, project, root):
    data = b"w" * 30
    upload_id = session(client, project, data).json()["upload_id"]
    chunk(client, project, upload_id, 0, data[:10])
    refused = commit(client, project, [{"op": "put", "path": "a.didsa", "base_version": None, "upload_id": upload_id}])
    assert refused.status_code == 400 and refused.json()["error"] == "unknown_upload"
    assert disk_state(root) == {}


def test_a_chunk_past_the_declared_size_is_refused(client, project):
    upload_id = session(client, project, b"x" * 10).json()["upload_id"]
    over = chunk(client, project, upload_id, 0, b"x" * 11)
    assert over.status_code == 400 and over.json()["error"] == "chunk_past_end"
    assert client.get(f"/projects/{project}/uploads/{upload_id}").json()["received"] == 0


def test_limits_on_the_session_and_the_chunk(client, project, monkeypatch):
    assert session(client, project, b"x" * (1024 * 1024 + 1)).status_code == 413  # the fixture's file limit is 1 MiB
    assert client.post(f"/projects/{project}/uploads/sessions", json={"size": 0, "sha256": "0" * 64}).status_code == 400
    assert client.post(f"/projects/{project}/uploads/sessions", json={"size": 5, "sha256": "nope"}).status_code == 400
    assert client.post(f"/projects/{project}/uploads/sessions", json={"size": "5"}).status_code == 422
    monkeypatch.setattr(api_module, "MAX_CHUNK_BYTES", 8)
    upload_id = session(client, project, b"y" * 20).json()["upload_id"]
    assert chunk(client, project, upload_id, 0, b"y" * 9).status_code == 413
    assert chunk(client, project, upload_id, 0, b"y" * 8).status_code == 200
    assert CHUNK_SIZE <= 64 * 1024 * 1024 and CHUNK_SIZE < 100 * 1024 * 1024  # what a client is told to send fits under the tunnel's limit


def test_unknown_expired_and_foreign_uploads(client, project, clock):
    assert client.get(f"/projects/{project}/uploads/nope").status_code == 404
    assert client.post("/projects", json={"name": "Other"}).status_code == 201
    upload_id = session(client, project, b"k" * 10).json()["upload_id"]
    assert client.get(f"/projects/Other/uploads/{upload_id}").status_code == 404  # another project's upload
    clock.advance(3601)
    assert client.get(f"/projects/{project}/uploads/{upload_id}").status_code == 404  # expired without activity
    assert chunk(client, project, upload_id, 0, b"k" * 10).status_code == 404


def test_each_chunk_keeps_the_upload_alive(client, project, clock):
    data = b"m" * 30
    upload_id = session(client, project, data).json()["upload_id"]
    for i in range(3):
        clock.advance(3000)  # more than an hour in all, but never an hour without a chunk
        assert chunk(client, project, upload_id, i * 10, data[i * 10 : i * 10 + 10]).status_code == 200
    assert client.post(f"/projects/{project}/uploads/{upload_id}/complete").status_code == 200


def test_cancel_removes_the_bytes(client, project, store):
    upload_id = session(client, project, b"c" * 10).json()["upload_id"]
    assert client.delete(f"/projects/{project}/uploads/{upload_id}").status_code == 200
    assert client.get(f"/projects/{project}/uploads/{upload_id}").status_code == 404
    assert not os.path.exists(os.path.join(store.upload_dir, upload_id))


def test_a_store_restart_mid_upload_loses_nothing(root, clock, project, store, client):
    data = bytes(range(100))
    upload_id = session(client, project, data).json()["upload_id"]
    chunk(client, project, upload_id, 0, data[:40])
    store.close()  # the store is switched off ...
    revived = Store(root, clock=clock, max_file_bytes=1024 * 1024)  # ... and on again
    try:
        again = TestClient(create_app(revived, TEST_KEY), headers=HEADERS)
        assert again.get(f"/projects/{project}/uploads/{upload_id}").json()["received"] == 40
        assert chunk(again, project, upload_id, 40, data[40:]).status_code == 200
        assert again.post(f"/projects/{project}/uploads/{upload_id}/complete").status_code == 200
        assert commit(again, project, [{"op": "put", "path": "r.didsa", "base_version": None, "upload_id": upload_id}]).status_code == 200
        assert again.get(f"/projects/{project}/files/r.didsa").content == data
    finally:
        revived.close()


def test_bytes_written_by_a_chunk_that_never_got_recorded_are_overwritten(client, project, store):
    # a crash after the bytes were appended but before `received` was updated: the file is longer than `received` says
    data = b"0123456789" * 3
    upload_id = session(client, project, data).json()["upload_id"]
    chunk(client, project, upload_id, 0, data[:10])
    with open(os.path.join(store.upload_dir, upload_id), "ab") as stray:
        stray.write(b"STRAY-BYTES" * 10)  # longer than what is still to come
    chunk(client, project, upload_id, 10, data[10:])
    assert client.post(f"/projects/{project}/uploads/{upload_id}/complete").status_code == 200


def test_a_refused_chunked_commit_writes_nothing_and_keeps_the_upload(client, project, store):
    assert client.put(f"/projects/{project}/files/a.didsa", content=b"v1", headers={"If-None-Match": "*"}).status_code == 201
    before = db_state(store)
    upload_id = send_all(client, project, b"v2-big-copy", size=4)
    client.post(f"/projects/{project}/uploads/{upload_id}/complete")
    stale = commit(client, project, [{"op": "put", "path": "a.didsa", "base_version": 7, "upload_id": upload_id}])
    assert stale.status_code == 409
    assert db_state(store) == before
    retry = commit(client, project, [{"op": "put", "path": "a.didsa", "base_version": 1, "upload_id": upload_id}])
    assert retry.status_code == 200


def test_requires_the_key(root, store):
    anonymous = TestClient(create_app(store, TEST_KEY))
    for method, path in (("post", "/projects/p/uploads/sessions"), ("get", "/projects/p/uploads/x"), ("put", "/projects/p/uploads/x?offset=0"),
                         ("post", "/projects/p/uploads/x/complete"), ("delete", "/projects/p/uploads/x")):
        assert getattr(anonymous, method)(path).status_code == 401, path


def test_a_store_from_before_s4_migrates(tmp_path, clock):
    root = str(tmp_path / "old")
    os.makedirs(root)
    first = Store(root, clock=clock)
    first.close()
    # recreate the S1-S3 shape of the uploads table, with a one-shot upload in it
    db = sqlite3.connect(os.path.join(root, ".didsa-store", "store.sqlite"))
    db.executescript("DROP TABLE uploads; CREATE TABLE uploads (id TEXT PRIMARY KEY, project TEXT NOT NULL, size INTEGER NOT NULL, "
                     "sha256 TEXT NOT NULL, part_id TEXT, created_at REAL NOT NULL);")
    os.makedirs(os.path.join(root, "P"))
    db.execute("INSERT INTO uploads VALUES ('old1', 'P', 3, ?, NULL, ?)", (hashlib.sha256(b"abc").hexdigest(), clock()))
    db.commit()
    db.close()
    with open(os.path.join(root, ".didsa-store", "uploads", "old1"), "wb") as handle:
        handle.write(b"abc")
    upgraded = Store(root, clock=clock)
    try:
        row = upgraded.db.execute("SELECT * FROM uploads WHERE id = 'old1'").fetchone()
        assert row["complete"] == 1 and row["received"] == 3
        assert upgraded.upload_status("P", "old1")["complete"] is True
        assert upgraded.commit("P", [{"op": "put", "path": "x.didsa", "base_version": None, "upload_id": "old1"}], None, "t")["files"]
    finally:
        upgraded.close()
