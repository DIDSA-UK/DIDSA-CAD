"""HTTP-level tests for the STEP/STL/OBJ/glb export endpoints - real OCCT
needed (tessellation, STEPControl_Writer), so these only run for real in CI
(no pythonocc-core in this sandbox - see every other OCCT-touching test
file's own version of this caveat). Read-only endpoints (no store mutation),
so unlike the native-format import test, no save/restore of the shared
process-global Document is needed here.
"""

import struct

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_box_part(name: str = "Export Test Part") -> str:
    part = client.post("/document/parts", json={"name": name}).json()
    part_id = part["id"]
    sketch_feature = client.post(
        f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}
    ).json()
    sketch_id = sketch_feature["sketch_id"]
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(0, 0), (10, 0), (10, 10), (0, 10)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
    client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 10.0,
        },
    )
    return part_id


def test_export_step_of_a_box_succeeds_and_looks_like_a_step_file():
    part_id = _create_box_part()
    response = client.get(f"/document/parts/{part_id}/export/step")
    assert response.status_code == 200
    assert response.content.startswith(b"ISO-10303-21")
    assert b"AP242" in response.content


def test_export_stl_of_a_box_has_twelve_triangles():
    part_id = _create_box_part()
    response = client.get(f"/document/parts/{part_id}/export/stl")
    assert response.status_code == 200
    (count,) = struct.unpack_from("<I", response.content, 80)
    # A box tessellates to 2 triangles per face * 6 faces.
    assert count == 12
    assert len(response.content) == 80 + 4 + count * 50


def test_export_obj_of_a_box_has_vertex_and_face_lines():
    part_id = _create_box_part()
    response = client.get(f"/document/parts/{part_id}/export/obj")
    assert response.status_code == 200
    text = response.text
    assert "\nv " in text
    assert "\nf " in text


def test_export_glb_of_a_box_is_a_valid_glb_container():
    part_id = _create_box_part()
    response = client.get(f"/document/parts/{part_id}/export/glb")
    assert response.status_code == 200
    magic, version, total_length = struct.unpack_from("<4sII", response.content, 0)
    assert magic == b"glTF"
    assert version == 2
    assert total_length == len(response.content)


@pytest.mark.parametrize("fmt", ["step", "stl", "obj", "glb"])
def test_export_of_a_part_with_no_solid_geometry_is_rejected(fmt):
    part = client.post("/document/parts", json={"name": "Empty Part"}).json()
    response = client.get(f"/document/parts/{part['id']}/export/{fmt}")
    assert response.status_code == 400
