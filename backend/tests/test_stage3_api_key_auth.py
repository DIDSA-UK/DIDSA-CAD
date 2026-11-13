from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)


def test_health_without_api_key_is_rejected():
    response = client.get("/health")

    assert response.status_code == 401
    assert response.json() == {"detail": "Missing or invalid API key."}


def test_health_with_wrong_api_key_is_rejected():
    response = client.get("/health", headers={"X-API-Key": "wrong-key"})

    assert response.status_code == 401
    assert response.json() == {"detail": "Missing or invalid API key."}


def test_health_with_correct_api_key_succeeds():
    response = client.get("/health", headers={"X-API-Key": TEST_API_KEY})

    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_health_reports_the_running_git_branch():
    # Falls back to "unknown" rather than failing (see app.main's own
    # _read_git_branch) if git/the repo isn't available in whatever
    # environment runs this test, so this only checks the field's shape,
    # not a specific branch name.
    response = client.get("/health", headers={"X-API-Key": TEST_API_KEY})

    assert isinstance(response.json()["git_branch"], str)
    assert response.json()["git_branch"] != ""


def test_sketch_endpoint_without_api_key_is_rejected():
    response = client.post("/sketch/sketches", json={"plane": "XY"})

    assert response.status_code == 401


def test_sketch_endpoint_with_wrong_api_key_is_rejected():
    response = client.post(
        "/sketch/sketches", json={"plane": "XY"}, headers={"X-API-Key": "wrong-key"}
    )

    assert response.status_code == 401


def test_sketch_endpoint_with_correct_api_key_succeeds():
    response = client.post(
        "/sketch/sketches", json={"plane": "XY"}, headers={"X-API-Key": TEST_API_KEY}
    )

    assert response.status_code == 201


def test_health_lists_the_api_features_a_client_may_depend_on():
    # B5 (docs/assembly-perf-mates-and-ui-plan.md): a client checks these before it runs a plan an older backend would fail mate by mate.
    features = client.get("/health", headers={"X-API-Key": TEST_API_KEY}).json()["api_features"]
    assert isinstance(features, list) and all(isinstance(f, str) for f in features)
    assert {"ai_plan.face_selector.normal", "ai_plan.mate_paths"} <= set(features)
    assert len(features) == len(set(features))


def test_health_names_the_project_store_only_when_told_where_it_is(monkeypatch):
    headers = {"X-API-Key": TEST_API_KEY}
    monkeypatch.delenv("PROJECT_STORE_URL", raising=False)
    body = client.get("/health", headers=headers).json()
    assert "project_store" not in body and "project_store" not in body["api_features"]

    monkeypatch.setenv("PROJECT_STORE_URL", "  ")
    body = client.get("/health", headers=headers).json()
    assert "project_store" not in body and "project_store" not in body["api_features"]

    monkeypatch.setenv("PROJECT_STORE_URL", "https://store.example.com")
    monkeypatch.setenv("PROJECT_STORE_API_KEY", "must-never-appear")
    response = client.get("/health", headers=headers)
    body = response.json()
    assert body["project_store"] == "https://store.example.com"
    assert "project_store" in body["api_features"] and "ai_plan.mate_paths" in body["api_features"]
    assert "must-never-appear" not in response.text
    # the module's own list is not changed by a request
    from app.main import API_FEATURES

    assert "project_store" not in API_FEATURES
