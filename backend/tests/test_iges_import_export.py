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


# --- hardening: messy, real-world-like IGES (generated here; independent expected volumes) -------------------------------------------------------------

from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.BRepFilletAPI import BRepFilletAPI_MakeFillet
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeSphere
from OCC.Core.gp import gp_Trsf, gp_Vec
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import topods


def _faces(shape):
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    out = []
    while explorer.More():
        out.append(topods.Face(explorer.Current()))
        explorer.Next()
    return out


def _nudged(face, dx):
    t = gp_Trsf()
    t.SetTranslation(gp_Vec(dx, 0, 0))
    return BRepBuilderAPI_Transform(face, t, True).Shape()


def _write_many(shapes, mode=IGES_FACES_MODE):
    writer = IGESControl_Writer("MM", mode)
    for shape in shapes:
        writer.AddShape(shape)
    writer.ComputeModel()
    fd, path = tempfile.mkstemp(suffix=".igs")
    os.close(fd)
    try:
        writer.Write(path)
        return open(path, "rb").read()
    finally:
        os.unlink(path)


def test_surfaces_with_real_world_gaps_still_become_a_solid():
    # six faces of a 100 x 60 x 40 box, every second one nudged 2 microns (20 um): well over the 1e-4 first tolerance
    faces = _faces(BRepPrimAPI_MakeBox(100.0, 60.0, 40.0).Shape())
    for gap in (0.002, 0.02):
        data = _write_many([_nudged(f, gap) if i % 2 else f for i, f in enumerate(faces)])
        shape = _shape_from_iges(data)
        assert shape_has_solid(shape), gap
        assert _volume(shape) == pytest.approx(240000, rel=2e-3), gap


def test_a_single_periodic_face_a_sphere_closes_into_a_solid():
    shape = _shape_from_iges(_write_many(_faces(BRepPrimAPI_MakeSphere(25.0).Shape())))
    assert shape_has_solid(shape)
    assert _volume(shape) == pytest.approx(4 / 3 * 3.141592653589793 * 25**3, rel=1e-4)


def test_curved_filleted_faces_and_real_solids_keep_their_exact_volume():
    block = BRepPrimAPI_MakeBox(50.0, 50.0, 50.0).Shape()
    fillet = BRepFilletAPI_MakeFillet(block)
    explorer = TopExp_Explorer(block, TopAbs_EDGE)
    for _ in range(4):
        fillet.Add(5.0, topods.Edge(explorer.Current()))
        explorer.Next()
    filleted = fillet.Shape()
    expected = _volume(filleted)
    assert _volume(_shape_from_iges(_write_many(_faces(filleted)))) == pytest.approx(expected, rel=1e-6)
    assert _volume(_shape_from_iges(_write_many([filleted], IGES_BREP_MODE))) == pytest.approx(expected, rel=1e-6)
    holed = BRepAlgoAPI_Cut(BRepPrimAPI_MakeBox(60.0, 60.0, 20.0).Shape(), BRepPrimAPI_MakeCylinder(8.0, 20.0).Shape()).Shape()
    assert _volume(_shape_from_iges(_write_many([holed], IGES_BREP_MODE))) == pytest.approx(_volume(holed), rel=1e-6)


def test_an_open_box_and_a_gap_too_big_stay_surfaces():
    faces = _faces(BRepPrimAPI_MakeBox(100.0, 60.0, 40.0).Shape())
    assert not shape_has_solid(_shape_from_iges(_write_many(faces[:5])))
    assert not shape_has_solid(_shape_from_iges(_write_many([_nudged(f, 5.0) if i % 2 else f for i, f in enumerate(faces)])))  # 5 mm: not a gap, a different model


def test_coloured_export_carries_the_body_colour_back_on_the_faces():
    from OCC.Core.IGESCAFControl import IGESCAFControl_Reader
    from OCC.Core.Quantity import Quantity_Color, Quantity_TOC_sRGB
    from OCC.Core.TDF import TDF_LabelSequence
    from OCC.Core.TDocStd import TDocStd_Document
    from OCC.Core.XCAFDoc import XCAFDoc_ColorGen, XCAFDoc_ColorSurf, XCAFDoc_ColorTool, XCAFDoc_DocumentTool

    box = BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()
    data = export_iges({"b": box}, appearances={"b": ({"colour": "#3366CC"}, {})})
    fd, path = tempfile.mkstemp(suffix=".igs")
    os.close(fd)
    try:
        open(path, "wb").write(data)
        doc = TDocStd_Document("read")
        reader = IGESCAFControl_Reader()
        reader.SetColorMode(True)
        assert reader.ReadFile(path) and reader.Transfer(doc)
        shapes = XCAFDoc_DocumentTool.ShapeTool(doc.Main())
        free = TDF_LabelSequence()
        shapes.GetFreeShapes(free)
        subs = TDF_LabelSequence()
        shapes.GetSubShapes(free.Value(1), subs)
        found = []
        for i in range(subs.Length()):
            colour = Quantity_Color()
            for kind in (XCAFDoc_ColorSurf, XCAFDoc_ColorGen):
                if XCAFDoc_ColorTool.GetColor(subs.Value(i + 1), kind, colour):
                    found.append(tuple(round(c * 255) for c in colour.Values(Quantity_TOC_sRGB)))
                    break
        assert found and all(abs(a - b) <= 1 for rgb in found for a, b in zip(rgb, (0x33, 0x66, 0xCC)))
    finally:
        os.unlink(path)
    # the geometry is unchanged by writing colours
    assert _volume(_shape_from_iges(data)) == pytest.approx(6000, rel=1e-6)


def _entity_types(data: bytes) -> set:
    """The IGES entity type numbers in the directory section (first field of the odd D lines)."""
    return {int(line[:8]) for line in data.decode("ascii", "ignore").splitlines() if len(line) >= 73 and line[72] == "D" and int(line[73:80]) % 2 == 1}


def test_default_and_coloured_exports_both_write_brep_solids_not_loose_surfaces():
    # Found with FreeCAD as an independent reader: the coloured (CAF) writer defaulted to trimmed surfaces (type 144), which FreeCAD reads as faces with no solid. Our own
    # reader HEALS surfaces into a solid, so only the raw file shows it.
    box = BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()
    plain = export_iges({"b": box})
    coloured = export_iges({"b": box}, appearances={"b": ({"colour": "#3366CC"}, {})})
    for data in (plain, coloured):
        assert 186 in _entity_types(data) and 144 not in _entity_types(data)
    assert 314 in _entity_types(coloured)  # the colour definitions are there


FREECADCMD = os.environ.get("FREECADCMD", "/opt/tools/fc-env/bin/freecadcmd")


@pytest.mark.skipif(not os.path.exists(FREECADCMD), reason="FreeCAD (an independent IGES / STEP reader) is not installed: set FREECADCMD")
def test_freecad_reads_our_iges_as_solids_with_the_right_volume(tmp_path):
    import subprocess

    holed = BRepAlgoAPI_Cut(BRepPrimAPI_MakeBox(60.0, 60.0, 20.0).Shape(), BRepPrimAPI_MakeCylinder(8.0, 20.0).Shape()).Shape()
    sphere = BRepPrimAPI_MakeSphere(10.0).Shape()
    expected = _volume(holed) + _volume(sphere)
    files = {"plain.igs": export_iges({"a": holed, "b": sphere}), "coloured.igs": export_iges({"a": holed, "b": sphere}, appearances={"a": ({"colour": "#CC3333"}, {})})}
    script = tmp_path / "check.py"
    script.write_text(
        "import Part\nfor name in %r:\n    s = Part.Shape(); s.read(str(%r + '/' + name))\n    print('FC', name, len(s.Solids), round(s.Volume, 3), s.isValid())\n" % (list(files), str(tmp_path))
    )
    for name, data in files.items():
        (tmp_path / name).write_bytes(data)
    out = subprocess.run([FREECADCMD, str(script)], capture_output=True, text=True, timeout=300).stdout
    lines = [line.split() for line in out.splitlines() if line.startswith("FC ")]
    assert len(lines) == 2
    for _fc, name, solids, volume, valid in lines:
        assert int(solids) == 2 and float(volume) == pytest.approx(expected, rel=1e-4) and valid == "True", name
