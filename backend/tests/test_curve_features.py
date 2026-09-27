"""Curve features (Helix/Intersection curve), the NORMAL_TO_CURVE_FEATURE_AT_
PARAMETER plane type, and Fill Surface - real-OCCT tests for their full
router/HTTP surface, mirroring test_stage_h_sweep.py's own shape.

Covers the three "curves as valid targets" requirements directly:
- a Helix as a Sweep path (`test_sweep_along_helix`),
- a Helix as the curve source for a plane construction
  (`test_plane_normal_to_curve_feature_at_parameter`),
- Sketch lines as Fill Surface boundaries (`test_fill_surface_basic`).
"""

import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers -----------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> list[dict]:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    lines = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        lines.append(_add_line(sketch_id, a["id"], b["id"]))
    return lines


def _add_circle(sketch_id: str, center: dict, radius_point: dict) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center["id"], "radius_point_id": radius_point["id"]},
    )
    assert response.status_code == 201
    return response.json()


def _create_helix(part_id: str, **overrides) -> dict:
    payload = {
        "curve_type": "helix",
        "axis_ref": {"fixed_plane": "XY"},
        "radius": 5.0,
        "pitch": 2.0,
        "turns": 3.0,
        "right_handed": True,
    }
    payload.update(overrides)
    response = client.post(f"/document/parts/{part_id}/curve-features", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


# --- Helix ---------------------------------------------------------------


def test_create_helix_curve_feature():
    part = _create_part()
    curve = _create_helix(part["id"])
    expected_length = math.sqrt((2 * math.pi * 5.0) ** 2 + 2.0**2) * 3.0
    assert curve["length"] == pytest.approx(expected_length, rel=1e-6)
    assert curve["closed"] is False
    assert curve["produces"] == "curve"


def test_helix_requires_positive_radius():
    part = _create_part()
    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "helix",
            "axis_ref": {"fixed_plane": "XY"},
            "radius": -1.0,
            "pitch": 2.0,
            "turns": 3.0,
        },
    )
    assert response.status_code == 422


def test_helix_requires_nonzero_pitch():
    part = _create_part()
    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "helix",
            "axis_ref": {"fixed_plane": "XY"},
            "radius": 5.0,
            "pitch": 0.0,
            "turns": 3.0,
        },
    )
    assert response.status_code == 422


def test_helix_left_handed_winds_opposite_direction():
    part = _create_part()
    right = _create_helix(part["id"], right_handed=True)
    left = _create_helix(part["id"], right_handed=False)
    assert right["length"] == pytest.approx(left["length"], rel=1e-9)


def test_update_helix_feature():
    part = _create_part()
    curve = _create_helix(part["id"])
    response = client.patch(
        f"/document/parts/{part['id']}/curve-features/{curve['id']}", json={"turns": 5.0}
    )
    assert response.status_code == 200, response.text
    updated = response.json()
    expected_length = math.sqrt((2 * math.pi * 5.0) ** 2 + 2.0**2) * 5.0
    assert updated["length"] == pytest.approx(expected_length, rel=1e-6)


def test_delete_curve_feature():
    part = _create_part()
    curve = _create_helix(part["id"])
    response = client.delete(f"/document/parts/{part['id']}/features/{curve['id']}")
    assert response.status_code == 204


# --- Sweep along a Helix (curve as a Sweep path) ---------------------------


def test_sweep_along_helix():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"], plane="XY")
    sketch_id = sketch_feature["sketch_id"]
    center = _add_point(sketch_id, 5.0, 0.0)
    radius_point = _add_point(sketch_id, 5.5, 0.0)
    _add_circle(sketch_id, center, radius_point)

    curve = _create_helix(part["id"])

    response = client.post(
        f"/document/parts/{part['id']}/sweep-features",
        json={
            "sketch_feature_id": sketch_feature["id"],
            "path_refs": [{"curve_feature_id": curve["id"]}],
            "mode": "boss",
        },
    )
    assert response.status_code == 201, response.text

    mesh = client.get(f"/document/parts/{part['id']}/mesh")
    assert mesh.status_code == 200
    bodies = mesh.json()
    # Both the standalone Helix curve (registered for its own display, see
    # test_standalone_curve_feature_appears_in_mesh) and the swept solid
    # Body appear here - two entries, not one.
    assert len(bodies) == 2
    solid = next(b for b in bodies if not b["is_curve"])
    assert solid["is_surface"] is False
    assert len(solid["mesh"]["vertices"]) > 0


def test_standalone_curve_feature_appears_in_mesh():
    part = _create_part()
    curve = _create_helix(part["id"])
    mesh = client.get(f"/document/parts/{part['id']}/mesh")
    assert mesh.status_code == 200
    bodies = mesh.json()
    assert len(bodies) == 1
    assert bodies[0]["body_id"] == curve["id"]
    assert bodies[0]["is_curve"] is True
    assert bodies[0]["is_surface"] is False
    assert len(bodies[0]["mesh"]["edges"]) > 0


# --- Intersection curve ------------------------------------------------------


def test_intersection_curve_from_two_open_chains():
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"], plane="XY")
    a1 = _add_point(sketch_a["sketch_id"], -10, -10)
    a2 = _add_point(sketch_a["sketch_id"], 10, 10)
    _add_line(sketch_a["sketch_id"], a1["id"], a2["id"])

    sketch_b = _create_sketch_feature(part["id"], plane="XZ")
    b1 = _add_point(sketch_b["sketch_id"], -10, -10)
    b2 = _add_point(sketch_b["sketch_id"], 10, 10)
    _add_line(sketch_b["sketch_id"], b1["id"], b2["id"])

    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "intersection",
            "sketch_feature_id_a": sketch_a["id"],
            "sketch_feature_id_b": sketch_b["id"],
        },
    )
    assert response.status_code == 201, response.text
    curve = response.json()
    assert curve["length"] > 0
    assert curve["closed"] is False


def test_intersection_curve_requires_existing_sketch_features():
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"], plane="XY")
    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "intersection",
            "sketch_feature_id_a": sketch_a["id"],
            "sketch_feature_id_b": "does-not-exist",
        },
    )
    assert response.status_code == 422


def test_intersection_curve_rejects_disjoint_result():
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"], plane="XY")
    _add_square(sketch_a["sketch_id"], -10, -10, 20)

    sketch_b = _create_sketch_feature(part["id"], plane="XZ")
    _add_square(sketch_b["sketch_id"], -3, 2, 6)

    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "intersection",
            "sketch_feature_id_a": sketch_a["id"],
            "sketch_feature_id_b": sketch_b["id"],
        },
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "curve_construction_failed"


# --- Plane normal to a curve feature at a parameter -------------------------


def test_plane_normal_to_curve_feature_at_parameter():
    part = _create_part()
    curve = _create_helix(part["id"])

    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "normal_to_curve_feature_at_parameter",
            "curve_feature_id": curve["id"],
            "curve_parameter": 0.5,
        },
    )
    assert response.status_code == 201, response.text
    plane = response.json()
    assert plane["origin"] is not None
    radial = math.hypot(plane["origin"][0], plane["origin"][1])
    assert radial == pytest.approx(5.0, rel=1e-6)
    assert plane["origin"][2] == pytest.approx(3.0, rel=1e-6)
    normal = plane["normal"]
    magnitude = math.sqrt(sum(c**2 for c in normal))
    assert magnitude == pytest.approx(1.0, rel=1e-6)


def test_plane_normal_to_curve_feature_rejects_out_of_range_parameter():
    part = _create_part()
    curve = _create_helix(part["id"])
    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "normal_to_curve_feature_at_parameter",
            "curve_feature_id": curve["id"],
            "curve_parameter": 1.5,
        },
    )
    assert response.status_code == 422


# --- Fill Surface -------------------------------------------------------------


def test_fill_surface_basic():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"], plane="XY")
    lines = _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)

    boundary_refs = [
        {"sketch_id": sketch_feature["sketch_id"], "entity_type": "line", "entity_id": line["id"]}
        for line in lines
    ]
    response = client.post(
        f"/document/parts/{part['id']}/fill-surface-features", json={"boundary_refs": boundary_refs}
    )
    assert response.status_code == 201, response.text

    mesh = client.get(f"/document/parts/{part['id']}/mesh")
    bodies = mesh.json()
    assert len(bodies) == 1
    assert bodies[0]["is_surface"] is True
    assert len(bodies[0]["mesh"]["vertices"]) > 0


def test_fill_surface_requires_at_least_two_boundaries():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"], plane="XY")
    lines = _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    boundary_refs = [
        {"sketch_id": sketch_feature["sketch_id"], "entity_type": "line", "entity_id": lines[0]["id"]}
    ]
    response = client.post(
        f"/document/parts/{part['id']}/fill-surface-features", json={"boundary_refs": boundary_refs}
    )
    assert response.status_code == 422


def test_fill_surface_from_curve_feature_boundary():
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"], plane="XY")
    a1 = _add_point(sketch_a["sketch_id"], -10, -10)
    a2 = _add_point(sketch_a["sketch_id"], 10, 10)
    _add_line(sketch_a["sketch_id"], a1["id"], a2["id"])

    sketch_b = _create_sketch_feature(part["id"], plane="XZ")
    b1 = _add_point(sketch_b["sketch_id"], -10, -10)
    b2 = _add_point(sketch_b["sketch_id"], 10, 10)
    _add_line(sketch_b["sketch_id"], b1["id"], b2["id"])

    curve = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "intersection",
            "sketch_feature_id_a": sketch_a["id"],
            "sketch_feature_id_b": sketch_b["id"],
        },
    ).json()

    # A second, parallel line (offset in Z) alongside the curve so
    # MakeFilling has more than one boundary constraint to work with.
    sketch_c = _create_sketch_feature(part["id"], plane="XY")
    c1 = _add_point(sketch_c["sketch_id"], -10, -9)
    c2 = _add_point(sketch_c["sketch_id"], 10, 11)
    line_c = _add_line(sketch_c["sketch_id"], c1["id"], c2["id"])

    response = client.post(
        f"/document/parts/{part['id']}/fill-surface-features",
        json={
            "boundary_refs": [
                {"curve_feature_id": curve["id"]},
                {
                    "sketch_id": sketch_c["sketch_id"],
                    "entity_type": "line",
                    "entity_id": line_c["id"],
                },
            ]
        },
    )
    assert response.status_code == 201, response.text
