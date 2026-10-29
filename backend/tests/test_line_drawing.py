"""GET /document/parts/{id}/drawing.png - AI Modelling's render-back check
drawing (`app.document.line_drawing`)."""

import struct
import zlib

from fastapi.testclient import TestClient

from app.document.line_drawing import project
from app.main import app
from tests.conftest import TEST_API_KEY
from tests.test_stage_export_formats import _create_box_part

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _decode_greyscale_png(data: bytes) -> tuple[int, int, bytes]:
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset, width, height, idat = 8, 0, 0, b""
    while offset < len(data):
        (length,) = struct.unpack(">I", data[offset : offset + 4])
        kind = data[offset + 4 : offset + 8]
        body = data[offset + 8 : offset + 8 + length]
        if kind == b"IHDR":
            width, height = struct.unpack(">II", body[:8])
            assert body[8:10] == b"\x08\x00"  # 8-bit greyscale
        elif kind == b"IDAT":
            idat += body
        offset += 12 + length
    raw = zlib.decompress(idat)
    assert len(raw) == height * (width + 1)
    pixels = b"".join(raw[y * (width + 1) + 1 : (y + 1) * (width + 1)] for y in range(height))
    return width, height, pixels


def test_drawing_of_a_box_is_a_png_with_ink_and_reports_its_size() -> None:
    part_id = _create_box_part("Drawing Box")
    response = client.get(f"/document/parts/{part_id}/drawing.png")
    assert response.status_code == 200
    assert response.headers["content-type"] == "image/png"
    assert [float(v) for v in response.headers["x-bounding-box"].split(",")] == [10.0, 10.0, 10.0]
    width, height, pixels = _decode_greyscale_png(response.content)
    assert (width, height) == (1400, 1000)
    dark = sum(1 for p in pixels if p < 128)
    assert 0 < dark < width * height // 4  # lines, not a filled image


def test_drawing_of_a_part_with_no_geometry_is_rejected() -> None:
    part = client.post("/document/parts", json={"name": "Empty Drawing Part"}).json()
    assert client.get(f"/document/parts/{part['id']}/drawing.png").status_code == 400


def test_front_view_of_a_box_is_its_outline_drawn_x_across_z_up() -> None:
    """A box seen square-on shows its four outline edges (its back edges,
    reported as hidden, lie exactly under them)."""
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

    view = project(BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape(), "front", 0.1)
    x0, y0, x1, y1 = view.bounds()
    assert (round(x1 - x0, 6), round(y1 - y0, 6)) == (10.0, 30.0)  # front: X across, Z up
    assert len(view.visible) == 4


def test_top_view_shows_a_hidden_pocket_as_dashed_edges() -> None:
    """A blind pocket cut into the underside is invisible from the top, so
    its edges must come back as hidden ones."""
    from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCC.Core.gp import gp_Pnt

    block = BRepPrimAPI_MakeBox(40.0, 40.0, 10.0).Shape()
    pocket = BRepPrimAPI_MakeBox(gp_Pnt(10.0, 10.0, 0.0), 20.0, 20.0, 5.0).Shape()
    shape = BRepAlgoAPI_Cut(block, pocket).Shape()
    view = project(shape, "top", 0.1)
    assert len(view.visible) == 4
    assert len(view.hidden) >= 4
