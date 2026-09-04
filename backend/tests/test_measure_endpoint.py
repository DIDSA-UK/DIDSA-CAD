"""Measure tool: real-OCCT tests for the `/parts/{id}/measure` router/HTTP
surface. Same sandbox caveat as `test_stage_d_fillet.py`'s own docstring
(`ast.parse`-verified/manually reviewed only here, pending a real
pythonocc-core environment)."""

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY
from tests.test_stage_d_fillet import (
    _boxy_part_and_body,
    _create_fillet,
    _edge_ref,
    _mesh,
)

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _vertex_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "vertex", "index": index}


def _face_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "face", "index": index}


def _measure(part_id: str, refs: list[dict]):
    return client.post(f"/document/parts/{part_id}/measure", json={"refs": refs})


# --- Single-entity ---------------------------------------------------------


def test_measuring_an_edge_of_a_10_unit_cube_reports_its_length():
    part, body_id = _boxy_part_and_body()  # a 10x10 square extruded 10 units
    response = _measure(part["id"], [_edge_ref(body_id, 0)])
    assert response.status_code == 200
    body = response.json()
    assert body["length"] == 10.0


def test_measuring_a_face_of_a_10_unit_cube_reports_area_and_unit_normal():
    part, body_id = _boxy_part_and_body()
    response = _measure(part["id"], [_face_ref(body_id, 0)])
    assert response.status_code == 200
    body = response.json()
    # Surface-integral area (unlike a straight edge's length) picks up a
    # tiny floating-point residual from GProp's quadrature - approx, not ==.
    assert body["area"] == pytest.approx(100.0)
    assert body["normal"] is not None
    nx, ny, nz = body["normal"]
    magnitude_squared = nx * nx + ny * ny + nz * nz
    assert abs(magnitude_squared - 1.0) < 1e-6


def test_measuring_a_vertex_reports_one_of_the_cubes_own_corners():
    part, body_id = _boxy_part_and_body()
    mesh = _mesh(part["id"])[0]["mesh"]
    vertex_ids = mesh["topology_vertex_ids"]
    vertices = mesh["topology_vertices"]

    response = _measure(part["id"], [_vertex_ref(body_id, vertex_ids[0])])
    assert response.status_code == 200
    body = response.json()
    assert tuple(body["point"]) == tuple(vertices[0])


def test_measuring_the_rounded_face_after_a_fillet_reports_its_radius():
    part, body_id = _boxy_part_and_body()
    create_response = _create_fillet(part["id"], [_edge_ref(body_id, 0)], 1.0)
    assert create_response.status_code == 201

    mesh = _mesh(part["id"])[0]["mesh"]
    planar_flags = mesh["face_is_planar"]
    rounded_face_index = next(i for i, planar in enumerate(planar_flags) if not planar)

    response = _measure(part["id"], [_face_ref(body_id, rounded_face_index)])
    assert response.status_code == 200
    body = response.json()
    assert body["radius"] == 1.0
    assert body["diameter"] == 2.0
    assert body["axis"] is not None


# --- Two-entity --------------------------------------------------------------


def test_measuring_two_vertices_reports_distance_and_matching_delta():
    part, body_id = _boxy_part_and_body()
    mesh = _mesh(part["id"])[0]["mesh"]
    vertex_ids = mesh["topology_vertex_ids"]
    vertices = mesh["topology_vertices"]

    response = _measure(
        part["id"],
        [_vertex_ref(body_id, vertex_ids[0]), _vertex_ref(body_id, vertex_ids[1])],
    )
    assert response.status_code == 200
    body = response.json()

    ax, ay, az = vertices[0]
    bx, by, bz = vertices[1]
    expected_delta = (bx - ax, by - ay, bz - az)
    expected_distance = sum(d * d for d in expected_delta) ** 0.5

    assert body["distance"] == pytest.approx(expected_distance)
    delta = tuple(body["delta"])
    assert delta == expected_delta or delta == tuple(-d for d in expected_delta)


def test_measuring_two_parallel_faces_of_a_cube_reports_normal_distance():
    part, body_id = _boxy_part_and_body()
    mesh = _mesh(part["id"])[0]["mesh"]
    face_count = len(mesh["face_is_planar"])

    # A cube has 6 faces; try every pair until a parallel one turns up
    # (face indices aren't in any documented order, so this doesn't assume
    # which two of the six are opposite each other).
    found = None
    for i in range(face_count):
        for j in range(i + 1, face_count):
            response = _measure(part["id"], [_face_ref(body_id, i), _face_ref(body_id, j)])
            assert response.status_code == 200
            body = response.json()
            if body.get("faces_parallel"):
                found = body
                break
        if found:
            break

    assert found is not None, "expected at least one parallel face pair on a cube"
    # Opposite faces of a 10-unit cube are exactly 10 units apart.
    assert found["normal_distance"] == 10.0


# --- Rejections --------------------------------------------------------------


def test_measuring_a_stale_reference_returns_missing_reference_422():
    part, body_id = _boxy_part_and_body()
    response = _measure(part["id"], [_edge_ref(body_id, 999)])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


def test_measuring_zero_entities_is_rejected():
    part, _ = _boxy_part_and_body()
    response = _measure(part["id"], [])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_measure_selection"


def test_measuring_three_entities_is_rejected():
    part, body_id = _boxy_part_and_body()
    response = _measure(
        part["id"],
        [_edge_ref(body_id, 0), _edge_ref(body_id, 1), _edge_ref(body_id, 2)],
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_measure_selection"
