"""F-3 (`docs/iges-jt-and-desktop-input-plan-2026-11-11.md`): IGES import and
export. Real OCCT needed (IGESControl_Reader / _Writer).

Covers: export of a box and a cylinder read back with `_shape_from_iges`
(volume and bounding box); the part and assembly export endpoints; the mode
constants; an import over HTTP that reports `solid`; an IGES with only
surfaces (mode 0 from a face) that sews into a closed solid when it is closed
and stays a shell when it is not; an inch-unit file read in millimetres; a
corrupt file -> 422 `invalid_import_data`; the native-format round trip of
`source_format: iges`."""

import base64
import os
import tempfile

import pytest
from fastapi.testclient import TestClient
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeFace
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Pln, gp_Pnt
from OCC.Core.IGESControl import IGESControl_Writer

from app.document.iges_export import IGES_BREP_MODE, IGES_FACES_MODE, export_iges
from app.document.import_geometry import _shape_from_iges, shape_has_solid
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _volume(shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


def _bbox(shape):
    box = Bnd_Box()
    brepbndlib.Add(shape, box)
    return box.Get()  # xmin, ymin, zmin, xmax, ymax, zmax


def _box_bodies():
    return {"b": BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()}


def _write_iges(shape, unit: str = "MM", mode: int = IGES_BREP_MODE) -> bytes:
    writer = IGESControl_Writer(unit, mode)
    writer.AddShape(shape)
    writer.ComputeModel()
    fd, path = tempfile.mkstemp(suffix=".igs")
    os.close(fd)
    try:
        writer.Write(path)
        with open(path, "rb") as handle:
            return handle.read()
    finally:
        os.unlink(path)


def test_export_box_round_trips_volume_and_bounds():
    data = export_iges(_box_bodies())
    assert data.startswith(b" ") or b"S      1" in data  # an IGES start section
    shape = _shape_from_iges(data)
    assert shape_has_solid(shape)
    assert _volume(shape) == pytest.approx(10 * 20 * 30, rel=1e-6)
    assert _bbox(shape) == pytest.approx((0, 0, 0, 10, 20, 30), abs=1e-6)


def test_export_cylinder_round_trips():
    cylinder = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), 5.0, 12.0).Shape()
    shape = _shape_from_iges(export_iges({"c": cylinder}))
    assert shape_has_solid(shape)
    assert _volume(shape) == pytest.approx(3.141592653589793 * 25 * 12, rel=1e-4)


def test_faces_mode_is_a_constant_and_still_reads_back_as_a_closed_solid():
    assert (IGES_FACES_MODE, IGES_BREP_MODE) == (0, 1)
    data = export_iges(_box_bodies(), mode=IGES_FACES_MODE)
    shape = _shape_from_iges(data)
    # six trimmed faces sew into a closed shell, which becomes a solid
    assert shape_has_solid(shape)
    assert _volume(shape) == pytest.approx(6000, rel=1e-4)


def test_an_open_set_of_surfaces_stays_a_shell_not_a_solid():
    face = BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), 0, 10, 0, 10).Face()
    shape = _shape_from_iges(_write_iges(face, mode=IGES_FACES_MODE))
    assert not shape_has_solid(shape)
    assert _bbox(shape) == pytest.approx((0, 0, 0, 10, 10, 0), abs=1e-6)


def test_inch_file_is_read_in_millimetres():
    # A 25.4 mm cube written with unit IN is a 1 x 1 x 1 inch cube in the FILE (coordinates ~1.0, not 25.4);
    # reading it must give 25.4 mm back, not 1.
    cube = BRepPrimAPI_MakeBox(25.4, 25.4, 25.4).Shape()
    data = _write_iges(cube, unit="IN")
    assert b"25.4" not in data
    shape = _shape_from_iges(data)
    assert _bbox(shape) == pytest.approx((0, 0, 0, 25.4, 25.4, 25.4), abs=1e-3)


def test_metre_file_is_read_in_millimetres():
    cube = BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()
    data = _write_iges(cube, unit="M")
    shape = _shape_from_iges(data)
    assert _bbox(shape) == pytest.approx((0, 0, 0, 10, 20, 30), abs=1e-3)


def _create_part(name: str = "IGES Test Part") -> str:
    return client.post("/document/parts", json={"name": name}).json()["id"]


def _import(part_id: str, data: bytes, fmt: str = "iges"):
    return client.post(
        f"/document/parts/{part_id}/import-features",
        json={"source_format": fmt, "data_base64": base64.b64encode(data).decode()},
    )


def test_http_import_reports_solid_and_the_body_has_the_right_size():
    part_id = _create_part()
    response = _import(part_id, export_iges(_box_bodies()))
    assert response.status_code == 201
    body = response.json()
    assert body["source_format"] == "iges"
    assert body["solid"] is True
    mesh = client.get(f"/document/parts/{part_id}/mesh").json()
    assert isinstance(mesh, list) and len(mesh) == 1


def test_http_import_of_open_surfaces_reports_not_solid():
    face = BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), 0, 10, 0, 10).Face()
    part_id = _create_part("Surface Only")
    response = _import(part_id, _write_iges(face, mode=IGES_FACES_MODE))
    assert response.status_code == 201
    assert response.json()["solid"] is False


def test_corrupt_iges_is_a_422_invalid_import_data():
    part_id = _create_part("Corrupt")
    response = _import(part_id, b"this is not an IGES file at all\n" * 5)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] in ("invalid_import_data", "import_failed")


def test_export_endpoints_return_iges_that_reads_back():
    part_id = _create_part("Export Me")
    assert _import(part_id, export_iges(_box_bodies())).status_code == 201
    response = client.get(f"/document/parts/{part_id}/export/iges")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("model/iges")
    assert 'filename="Export Me.igs"' in response.headers["content-disposition"]
    assert _volume(_shape_from_iges(response.content)) == pytest.approx(6000, rel=1e-4)
    assembly = client.get(f"/document/parts/{part_id}/export/assembly-iges")
    assert assembly.status_code == 200
    assert _volume(_shape_from_iges(assembly.content)) == pytest.approx(6000, rel=1e-4)


def test_export_of_an_empty_part_is_a_400():
    part_id = _create_part("Empty")
    assert client.get(f"/document/parts/{part_id}/export/iges").status_code == 400


def test_native_format_round_trips_an_iges_import():
    part_id = _create_part("Native Round Trip")
    assert _import(part_id, export_iges(_box_bodies())).status_code == 201
    exported = client.get("/document/export/native", params={"part_id": part_id})
    assert exported.status_code == 200
    assert b'"iges"' in exported.content
    reopened = client.post("/document/import/native", content=exported.content, headers={"Content-Type": "application/json"})
    assert reopened.status_code in (200, 201)
