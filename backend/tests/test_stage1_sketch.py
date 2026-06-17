import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Line

client = TestClient(app)


def test_line_set_length_preserves_direction():
    line = Line(id="t", start=(0.0, 0.0), end=(3.0, 4.0))
    assert line.length == pytest.approx(5.0)

    line.set_length(10.0)

    assert line.start == (0.0, 0.0)
    assert line.end[0] == pytest.approx(6.0)
    assert line.end[1] == pytest.approx(8.0)
    assert line.length == pytest.approx(10.0)


def test_line_set_length_on_zero_length_line_raises():
    line = Line(id="t", start=(1.0, 1.0), end=(1.0, 1.0))
    with pytest.raises(ValueError):
        line.set_length(5.0)


def test_create_line_from_endpoints():
    response = client.post(
        "/sketch/lines", json={"start": {"x": 0, "y": 0}, "end": {"x": 3, "y": 4}}
    )
    assert response.status_code == 201
    body = response.json()
    assert body["start"] == {"x": 0, "y": 0}
    assert body["end"] == {"x": 3, "y": 4}
    assert body["length"] == pytest.approx(5.0)
    assert "id" in body


def test_create_line_from_length_and_angle():
    response = client.post(
        "/sketch/lines",
        json={"start": {"x": 1, "y": 1}, "length": 10, "angle": 0},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["start"] == {"x": 1, "y": 1}
    assert body["end"]["x"] == pytest.approx(11.0)
    assert body["end"]["y"] == pytest.approx(1.0)
    assert body["length"] == pytest.approx(10.0)


def test_create_line_requires_end_or_length_and_angle():
    response = client.post("/sketch/lines", json={"start": {"x": 0, "y": 0}})
    assert response.status_code == 422


def test_create_line_rejects_both_end_and_length():
    response = client.post(
        "/sketch/lines",
        json={"start": {"x": 0, "y": 0}, "end": {"x": 1, "y": 1}, "length": 5, "angle": 0},
    )
    assert response.status_code == 422


def test_get_line_round_trip():
    created = client.post(
        "/sketch/lines", json={"start": {"x": 0, "y": 0}, "end": {"x": 6, "y": 8}}
    ).json()

    response = client.get(f"/sketch/lines/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_line_not_found():
    response = client.get("/sketch/lines/does-not-exist")
    assert response.status_code == 404


def test_update_length_moves_second_endpoint_only():
    created = client.post(
        "/sketch/lines", json={"start": {"x": 0, "y": 0}, "end": {"x": 3, "y": 4}}
    ).json()

    response = client.patch(f"/sketch/lines/{created['id']}", json={"length": 15})

    assert response.status_code == 200
    body = response.json()
    assert body["start"] == {"x": 0, "y": 0}
    # Direction (3, 4) normalized is (0.6, 0.8); scaled to length 15.
    assert body["end"]["x"] == pytest.approx(9.0)
    assert body["end"]["y"] == pytest.approx(12.0)
    assert body["length"] == pytest.approx(15.0)


def test_update_endpoints_directly_recomputes_length():
    created = client.post(
        "/sketch/lines", json={"start": {"x": 0, "y": 0}, "end": {"x": 1, "y": 0}}
    ).json()

    response = client.patch(
        f"/sketch/lines/{created['id']}",
        json={"start": {"x": 0, "y": 0}, "end": {"x": 0, "y": 9}},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["end"] == {"x": 0, "y": 9}
    assert body["length"] == pytest.approx(9.0)


def test_update_zero_length_line_with_length_is_rejected():
    created = client.post(
        "/sketch/lines", json={"start": {"x": 2, "y": 2}, "end": {"x": 2, "y": 2}}
    ).json()

    response = client.patch(f"/sketch/lines/{created['id']}", json={"length": 5})

    assert response.status_code == 400


def test_update_requires_endpoints_or_length():
    created = client.post(
        "/sketch/lines", json={"start": {"x": 0, "y": 0}, "end": {"x": 1, "y": 1}}
    ).json()

    response = client.patch(f"/sketch/lines/{created['id']}", json={})

    assert response.status_code == 422
