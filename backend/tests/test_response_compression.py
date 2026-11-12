"""A big JSON response (a part's mesh) is gzipped for a client that accepts it, left alone for one that does not, and small replies are never compressed."""

import gzip
import json

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _part_with_a_box() -> str:
    from tests.test_iges_import_export import _create_part  # a part to ask the mesh of

    return _create_part("Compression")


def test_a_large_reply_is_gzipped_when_the_client_accepts_it_and_decodes_to_the_same_json():
    import base64

    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeSphere

    from app.document.iges_export import export_iges

    part_id = _part_with_a_box()
    data = export_iges({"s": BRepPrimAPI_MakeSphere(20.0).Shape()})
    assert client.post(f"/document/parts/{part_id}/import-features", json={"source_format": "iges", "data_base64": base64.b64encode(data).decode()}).status_code == 201
    plain = client.get(f"/document/parts/{part_id}/mesh?quality=0.5", headers={"Accept-Encoding": "identity"})
    assert plain.headers.get("content-encoding") is None
    zipped = client.get(f"/document/parts/{part_id}/mesh?quality=0.5", headers={"Accept-Encoding": "gzip"})
    assert zipped.headers.get("content-encoding") == "gzip"
    assert zipped.json() == plain.json()
    assert len(gzip.compress(plain.content)) < len(plain.content) / 2  # it is worth doing for a mesh


def test_a_small_reply_is_not_compressed():
    reply = client.get("/health", headers={"Accept-Encoding": "gzip"})
    assert reply.status_code == 200 and reply.headers.get("content-encoding") is None
    assert json.loads(reply.content)
