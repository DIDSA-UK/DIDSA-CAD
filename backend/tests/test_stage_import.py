"""HTTP-level tests for `POST /document/parts/{id}/import-features` - real
OCCT needed (STEPControl_Reader, the mesh-to-shape triangulation build), so
these only run for real in CI (no pythonocc-core in this sandbox - see
every other OCCT-touching test file's own version of this caveat).
"""

import base64

from fastapi.testclient import TestClient

from app.document.mesh_export import encode_stl
from app.document.mesh_data import MeshData, Triangle
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Import Test Part") -> str:
    return client.post("/document/parts", json={"name": name}).json()["id"]


def _create_box_part_and_export_step() -> bytes:
    part_id = _create_part("STEP Source Part")
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
    return client.get(f"/document/parts/{part_id}/export/step").content


def _single_triangle_stl_bytes() -> bytes:
    mesh = MeshData()
    mesh.vertices = [(0.0, 0.0, 0.0), (10.0, 0.0, 0.0), (0.0, 10.0, 0.0)]
    mesh.normals = [(0.0, 0.0, 1.0)] * 3
    mesh.triangles = [Triangle(a=0, b=1, c=2)]
    return encode_stl(mesh)


def test_importing_a_step_file_creates_a_new_body():
    step_bytes = _create_box_part_and_export_step()
    part_id = _create_part()

    response = client.post(
        f"/document/parts/{part_id}/import-features",
        json={"source_format": "step", "data_base64": base64.b64encode(step_bytes).decode("ascii")},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "import"
    assert body["source_format"] == "step"
    assert body["source_byte_count"] == len(step_bytes)

    mesh_response = client.get(f"/document/parts/{part_id}/mesh")
    assert mesh_response.status_code == 200
    bodies = mesh_response.json()
    assert len(bodies) == 1
    assert bodies[0]["source"] == "computed"


def test_importing_an_stl_file_creates_a_new_body():
    part_id = _create_part()
    stl_bytes = _single_triangle_stl_bytes()

    response = client.post(
        f"/document/parts/{part_id}/import-features",
        json={"source_format": "stl", "data_base64": base64.b64encode(stl_bytes).decode("ascii")},
    )
    assert response.status_code == 201

    mesh_response = client.get(f"/document/parts/{part_id}/mesh")
    assert mesh_response.status_code == 200
    bodies = mesh_response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["triangle_indices"]) == 1


def test_import_rejects_invalid_base64():
    part_id = _create_part()
    response = client.post(
        f"/document/parts/{part_id}/import-features",
        json={"source_format": "step", "data_base64": "not-valid-base64!!!"},
    )
    assert response.status_code == 422


def test_import_rejects_corrupt_step_bytes():
    part_id = _create_part()
    response = client.post(
        f"/document/parts/{part_id}/import-features",
        json={
            "source_format": "step",
            "data_base64": base64.b64encode(b"this is not a step file").decode("ascii"),
        },
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_import_data"


def test_import_rejects_corrupt_stl_bytes():
    part_id = _create_part()
    response = client.post(
        f"/document/parts/{part_id}/import-features",
        json={
            "source_format": "stl",
            "data_base64": base64.b64encode(b"not an stl file").decode("ascii"),
        },
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_import_data"


def test_an_extrude_cut_can_target_an_imported_body():
    part_id = _create_part()
    stl_bytes = _single_triangle_stl_bytes()
    import_response = client.post(
        f"/document/parts/{part_id}/import-features",
        json={"source_format": "stl", "data_base64": base64.b64encode(stl_bytes).decode("ascii")},
    )
    imported_feature_id = import_response.json()["id"]

    sketch_feature = client.post(
        f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}
    ).json()
    sketch_id = sketch_feature["sketch_id"]
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(1, 1), (2, 1), (2, 2), (1, 2)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
    cut_response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature["id"],
            "extrude_type": "cut",
            "start_distance": -1.0,
            "end_distance": 1.0,
            "target_body_ids": [imported_feature_id],
        },
    )
    assert cut_response.status_code == 201
