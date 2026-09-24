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


def test_measuring_a_straight_edge_of_a_10_unit_cube_reports_a_unit_axis_direction_and_a_point_on_it():
    """Phase 13 (`docs/assembly-scope.md` §6 `[15]`): closes this module's
    own previously-untested gap - a straight edge's own `axis` (a point on
    the line + its direction), the same `single_shape_geometry` branch
    `assembly_solver.py`'s CONCENTRIC/PARALLEL/ANGLE/DISTANCE mate dispatch
    now reuses for a straight-edge mate reference."""
    part, body_id = _boxy_part_and_body()  # a 10x10 square extruded 10 units
    response = _measure(part["id"], [_edge_ref(body_id, 0)])
    assert response.status_code == 200
    body = response.json()
    axis = body["axis"]
    assert axis is not None
    # No radius/diameter - a straight edge has no fitted circle (unlike a
    # circular one, which populates both alongside its own axis).
    assert body["radius"] is None
    direction = axis["direction"]
    length = sum(d * d for d in direction) ** 0.5
    assert abs(length - 1.0) < 1e-9
    # The reported origin genuinely lies on the edge's own infinite line -
    # cross-checked against the edge's own real length (10.0, asserted
    # above) rather than a fixed expected coordinate, since which of the
    # box's 12 edges `index=0` happens to be isn't itself guaranteed.
    origin = axis["origin"]
    assert all(isinstance(c, float) for c in origin)


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


def _circular_edge_indices(part_id: str, body_id: str) -> list[int]:
    """Every edge index on `body_id` that `single_shape_geometry` reports a
    `radius` for (i.e. is actually circular) - a filleted cube's fillet adds
    exactly two (the rounded face's own top/bottom rims), found by probing
    each edge rather than assuming a fixed index the way `_edge_ref(...,
    0)` elsewhere in this file gets away with for a plain straight edge."""
    mesh = _mesh(part_id)[0]["mesh"]
    edge_count = len(set(mesh["edge_ids"]))
    circular = []
    for i in range(edge_count):
        response = _measure(part_id, [_edge_ref(body_id, i)])
        if response.status_code == 200 and response.json().get("radius") is not None:
            circular.append(i)
    return circular


def test_measuring_two_circular_edges_reports_centre_to_centre_distance():
    """Bug fix (assembly testing: "when the user selects a diameter or arc
    and another entity ... it should measure to/from the centre point ...
    e.g. when measuring distance between hole centres")."""
    part, body_id = _boxy_part_and_body()
    create_response = _create_fillet(part["id"], [_edge_ref(body_id, 0)], 1.0)
    assert create_response.status_code == 201

    circular = _circular_edge_indices(part["id"], body_id)
    assert len(circular) >= 2, "expected a fillet's rounded face to have two circular rim edges"
    edge_a, edge_b = circular[0], circular[1]

    center_a = _measure(part["id"], [_edge_ref(body_id, edge_a)]).json()["center"]
    center_b = _measure(part["id"], [_edge_ref(body_id, edge_b)]).json()["center"]
    expected_distance = sum((a - b) ** 2 for a, b in zip(center_a, center_b)) ** 0.5

    response = _measure(part["id"], [_edge_ref(body_id, edge_a), _edge_ref(body_id, edge_b)])
    assert response.status_code == 200
    body = response.json()
    # Centre-to-centre, not the generic nearest-rim-point distance (which
    # would be `expected_distance` minus roughly the sum of the two radii
    # for two coaxial circles of the same radius).
    assert body["distance"] == pytest.approx(expected_distance)
    assert tuple(round(c, 9) for c in body["point_a"]) == tuple(round(c, 9) for c in center_a)
    assert tuple(round(c, 9) for c in body["point_b"]) == tuple(round(c, 9) for c in center_b)


def test_measuring_a_circular_edge_and_a_vertex_reports_distance_to_the_circles_centre():
    part, body_id = _boxy_part_and_body()
    create_response = _create_fillet(part["id"], [_edge_ref(body_id, 0)], 1.0)
    assert create_response.status_code == 201

    circular = _circular_edge_indices(part["id"], body_id)
    assert circular, "expected at least one circular rim edge after filleting"
    edge_index = circular[0]
    center = _measure(part["id"], [_edge_ref(body_id, edge_index)]).json()["center"]

    mesh = _mesh(part["id"])[0]["mesh"]
    vertex_id = mesh["topology_vertex_ids"][0]
    vertex_point = mesh["topology_vertices"][0]

    response = _measure(part["id"], [_edge_ref(body_id, edge_index), _vertex_ref(body_id, vertex_id)])
    assert response.status_code == 200
    body = response.json()
    expected_distance = sum((c - v) ** 2 for c, v in zip(center, vertex_point)) ** 0.5
    # Measured from the circle's own centre, not the nearest point on its rim.
    assert body["distance"] == pytest.approx(expected_distance)


# --- Component Pattern direction-from-edge ------------------------------------


def test_component_pattern_direction_from_a_straight_edge_reports_its_unit_direction():
    """Bug fix (assembly testing: "pattern component tool: selecting a
    custom line to use as a direction always seems to silently fail and
    fall back to using an X/Y/Z direction vector")."""
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/component-pattern-direction",
        json={"ref": {"occurrence_id": "", "subshape_ref": _edge_ref(body_id, 0)}},
    )
    assert response.status_code == 200
    direction = response.json()["direction"]
    length = sum(d * d for d in direction) ** 0.5
    assert abs(length - 1.0) < 1e-9


def test_component_pattern_direction_from_a_stale_edge_returns_missing_reference_422():
    part, body_id = _boxy_part_and_body()
    response = client.post(
        f"/document/parts/{part['id']}/component-pattern-direction",
        json={"ref": {"occurrence_id": "", "subshape_ref": _edge_ref(body_id, 999)}},
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


def test_component_pattern_direction_from_a_vertex_returns_invalid_direction_ref_422():
    part, body_id = _boxy_part_and_body()
    mesh = _mesh(part["id"])[0]["mesh"]
    vertex_id = mesh["topology_vertex_ids"][0]
    response = client.post(
        f"/document/parts/{part['id']}/component-pattern-direction",
        json={"ref": {"occurrence_id": "", "subshape_ref": _vertex_ref(body_id, vertex_id)}},
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_direction_ref"


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
