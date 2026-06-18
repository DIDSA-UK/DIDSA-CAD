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
