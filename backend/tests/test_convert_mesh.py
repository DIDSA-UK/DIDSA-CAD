"""F-5: `POST /convert/mesh`, a stateless STEP / IGES -> glb for the mesh viewer. Real OCCT needed."""

import base64
import json
import struct

from fastapi.testclient import TestClient
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

from app.document import router as router_module
from app.document.iges_export import export_iges
from app.document.step_export import export_step
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def _glb_json(glb: bytes) -> dict:
    magic, version, _length = struct.unpack("<4sII", glb[:12])
    assert magic == b"glTF" and version == 2
    chunk_length, chunk_type = struct.unpack("<I4s", glb[12:20])
    assert chunk_type == b"JSON"
    return json.loads(glb[20 : 20 + chunk_length])


def _box_step() -> bytes:
    return export_step({"b": BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()})


def test_step_box_becomes_a_glb_with_twelve_triangles_and_the_right_bounds():
    response = client.post("/document/convert/mesh", json={"source_format": "step", "data_base64": _b64(_box_step())})
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("model/gltf-binary")
    gltf = _glb_json(response.content)
    position = gltf["accessors"][0]
    assert position["count"] == 36  # 12 triangles, unindexed
    assert position["min"] == [0.0, 0.0, 0.0] or all(abs(a - b) < 1e-4 for a, b in zip(position["min"], [0, 0, 0]))
    assert all(abs(a - b) < 1e-4 for a, b in zip(position["max"], [10, 20, 30]))


def test_iges_box_converts_too():
    data = export_iges({"b": BRepPrimAPI_MakeBox(5.0, 5.0, 5.0).Shape()})
    response = client.post("/document/convert/mesh", json={"source_format": "iges", "data_base64": _b64(data)})
    assert response.status_code == 200 and _glb_json(response.content)["accessors"][0]["count"] == 36


def test_nothing_is_stored():
    before = client.get("/document/export/native").json()["document"]["parts"]
    client.post("/document/convert/mesh", json={"source_format": "step", "data_base64": _b64(_box_step())})
    assert client.get("/document/export/native").json()["document"]["parts"] == before


def test_a_mesh_format_corrupt_data_and_bad_base64_are_refused():
    stl = client.post("/document/convert/mesh", json={"source_format": "stl", "data_base64": _b64(b"x")})
    assert stl.status_code == 422 and stl.json()["detail"]["type"] == "unsupported_format"
    corrupt = client.post("/document/convert/mesh", json={"source_format": "step", "data_base64": _b64(b"not step")})
    assert corrupt.status_code == 422
    assert client.post("/document/convert/mesh", json={"source_format": "step", "data_base64": "!!!"}).status_code == 422


def test_the_size_and_triangle_caps(monkeypatch):
    monkeypatch.setattr(router_module, "CONVERT_MAX_BYTES", 10)
    big = client.post("/document/convert/mesh", json={"source_format": "step", "data_base64": _b64(_box_step())})
    assert big.status_code == 413
    monkeypatch.setattr(router_module, "CONVERT_MAX_BYTES", 150 * 1024 * 1024)
    monkeypatch.setattr(router_module, "CONVERT_MAX_TRIANGLES", 5)
    many = client.post("/document/convert/mesh", json={"source_format": "step", "data_base64": _b64(_box_step())})
    assert many.status_code == 422 and many.json()["detail"]["type"] == "import_too_large"


def test_a_coarser_deflection_is_accepted():
    response = client.post("/document/convert/mesh", json={"source_format": "step", "data_base64": _b64(_box_step()), "linear_deflection": 5.0})
    assert response.status_code == 200
