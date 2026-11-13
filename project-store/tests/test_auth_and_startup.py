import importlib
import sys

import pytest

from tests.conftest import HEADERS


def test_every_route_needs_the_key_health_included(store, client):
    from fastapi.testclient import TestClient

    from app.api import create_app

    bare = TestClient(create_app(store, "test-store-key"))
    wrong = TestClient(create_app(store, "test-store-key"), headers={"X-API-Key": "nope"})
    requests = [
        ("get", "/health"),
        ("get", "/projects"),
        ("post", "/projects"),
        ("get", "/projects/p/tree"),
        ("get", "/projects/p/files/a.didsa"),
        ("put", "/projects/p/files/a.didsa"),
        ("delete", "/projects/p/files/a.didsa"),
        ("post", "/projects/p/commit"),
        ("post", "/projects/p/uploads"),
        ("get", "/projects/p/files/a.didsa/versions"),
        ("get", "/projects/p/files/a.didsa/versions/1"),
        ("get", "/projects/p/changes"),
        ("get", "/projects/p/parts/x"),
    ]
    for method, url in requests:
        for who in (bare, wrong):
            response = getattr(who, method)(url)
            assert response.status_code == 401, (method, url)
    assert client.get("/health").status_code == 200


def test_health_body(client):
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert isinstance(body["version"], str) and "commit.all_or_nothing" in body["api_features"]
    assert "key" not in str(body).lower()


def _fresh_main(monkeypatch, **env):
    for name in ("PROJECT_STORE_API_KEY", "PROJECT_STORE_ROOT"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    sys.modules.pop("app.main", None)
    return importlib.import_module("app.main")


def test_refuses_to_start_without_a_key(monkeypatch, tmp_path):
    with pytest.raises(RuntimeError, match="PROJECT_STORE_API_KEY"):
        _fresh_main(monkeypatch, PROJECT_STORE_ROOT=str(tmp_path / "r"))
    sys.modules.pop("app.main", None)


def test_refuses_to_start_without_a_root(monkeypatch):
    with pytest.raises(RuntimeError, match="PROJECT_STORE_ROOT"):
        _fresh_main(monkeypatch, PROJECT_STORE_API_KEY="k")
    sys.modules.pop("app.main", None)


def test_starts_with_both_and_serves(monkeypatch, tmp_path):
    from fastapi.testclient import TestClient

    module = _fresh_main(monkeypatch, PROJECT_STORE_API_KEY="k", PROJECT_STORE_ROOT=str(tmp_path / "r"))
    try:
        assert TestClient(module.app).get("/health", headers={"X-API-Key": "k"}).status_code == 200
        assert TestClient(module.app).get("/health").status_code == 401
    finally:
        module.app.state.store.close()
        sys.modules.pop("app.main", None)
