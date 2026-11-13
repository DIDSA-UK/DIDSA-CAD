import itertools
import os

import pytest
from fastapi.testclient import TestClient

from app.api import create_app
from app.store import Store

# app/main.py (the entry point) reads its key and root from the environment at import time and refuses to start without them; the
# tests build the app with `create_app` and a temp folder instead, and only test_startup.py imports main.
TEST_KEY = "test-store-key"
HEADERS = {"X-API-Key": TEST_KEY}


class FakeClock:
    """A settable clock: tests move time with `advance`, nothing sleeps."""

    def __init__(self, start: float = 1_800_000_000.0):
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def root(tmp_path):
    return str(tmp_path / "store-root")


@pytest.fixture
def store(root, clock):
    os.makedirs(root)
    instance = Store(root, clock=clock, max_file_bytes=1024 * 1024)
    yield instance
    instance.close()


@pytest.fixture
def client(store):
    return TestClient(create_app(store, TEST_KEY), headers={**HEADERS, "X-Device-Name": "Desktop"})


@pytest.fixture
def project(client):
    assert client.post("/projects", json={"name": "Gearbox"}).status_code == 201
    return "Gearbox"


def native_file(root_part_id: str | None, extra: str = "") -> bytes:
    """A minimal native file: the shape backend/app/document/native_format.py writes, trimmed to what the store reads."""
    import json

    document = {"id": "doc", "parts": [{"id": "x", "name": extra}]}
    if root_part_id is not None:
        document["root_part_id"] = root_part_id
    return json.dumps({"schema_version": 1, "document": document}).encode()


_counter = itertools.count()


def put(client, project, path, content: bytes, *, base=None, device="Desktop"):
    """PUT a file: create when `base` is None, else replace that version."""
    headers = {"X-Device-Name": device}
    headers.update({"If-None-Match": "*"} if base is None else {"If-Match": f'"{base}"'})
    return client.put(f"/projects/{project}/files/{path}", content=content, headers=headers)


def upload(client, project, content: bytes) -> str:
    response = client.post(f"/projects/{project}/uploads", content=content)
    assert response.status_code == 201, response.text
    return response.json()["upload_id"]


def commit(client, project, changes, message=None):
    body = {"changes": changes}
    if message is not None:
        body["message"] = message
    return client.post(f"/projects/{project}/commit", json=body)


def disk_state(root: str) -> dict:
    """Every file under the root that is not the store's own data: relative path -> bytes."""
    found = {}
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != ".didsa-store"]
        for name in files:
            full = os.path.join(folder, name)
            with open(full, "rb") as handle:
                found[os.path.relpath(full, root)] = handle.read()
    return found


def db_state(store) -> dict:
    """All the store's rows that a refused write must leave alone (devices and uploads are bookkeeping, not versions)."""
    return {
        table: [tuple(row) for row in store.db.execute(f"SELECT * FROM {table} ORDER BY 1, 2, 3")]
        for table in ("files", "versions", "changes")
    }
