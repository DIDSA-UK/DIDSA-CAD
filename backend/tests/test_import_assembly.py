"""F-6 (`docs/iges-jt-and-desktop-input-plan-2026-11-11.md`): importing a STEP file AS AN ASSEMBLY (and an IGES file as one part per solid). Real OCCT needed.

Fixtures are made here with OCCT's XCAF writer (a two-level assembly with a repeated part, a colour, a mirrored placement), so their licence is ours.
Covers: the probe's counts; one Part per distinct prototype (a repeated part is ONE Part with several Occurrences); world poses equal to the single-body
import's solids; the mirrored placement baked into its own Part; a product with no shape skipped and reported; names, colours and unique file names kept;
the insert endpoint (a sub-assembly Occurrence on the open root) and the open-as-new endpoint; the size cap; IGES one-part-per-solid; errors."""

import base64
import os
import tempfile

import pytest
from fastapi.testclient import TestClient
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
from OCC.Core.Quantity import Quantity_Color, Quantity_TOC_sRGB
from OCC.Core.STEPCAFControl import STEPCAFControl_Writer
from OCC.Core.STEPControl import STEPControl_AsIs
from OCC.Core.TDataStd import TDataStd_Name
from OCC.Core.TDocStd import TDocStd_Document
from OCC.Core.TopLoc import TopLoc_Location
from OCC.Core.XCAFDoc import XCAFDoc_ColorSurf, XCAFDoc_DocumentTool

from app.document import step_assembly
from app.document.iges_export import export_iges
from app.document.step_export import export_step
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _location(x=0.0, y=0.0, z=0.0, mirror=False) -> TopLoc_Location:
    trsf = gp_Trsf()
    if mirror:
        trsf.SetMirror(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0)))
    else:
        trsf.SetTranslation(gp_Vec(x, y, z))
    return TopLoc_Location(trsf)


def _write_xcaf(doc) -> bytes:
    writer = STEPCAFControl_Writer()
    writer.Transfer(doc, STEPControl_AsIs)
    fd, path = tempfile.mkstemp(suffix=".step")
    os.close(fd)
    try:
        assert writer.Write(path) == 1
        with open(path, "rb") as handle:
            return handle.read()
    finally:
        os.unlink(path)


def _assembly_step(mirrored: bool = False) -> bytes:
    """Top = [Box at x=100, Sub at y=50, Sub at y=80, (Box mirrored)]; Sub = [Pin, Pin at x=20]."""
    doc = TDocStd_Document("fixture")
    shapes = XCAFDoc_DocumentTool.ShapeTool(doc.Main())
    colours = XCAFDoc_DocumentTool.ColorTool(doc.Main())
    box = shapes.AddShape(BRepPrimAPI_MakeBox(10, 10, 10).Shape(), False)
    TDataStd_Name.Set(box, "Box")
    colours.SetColor(box, Quantity_Color(1, 0, 0, Quantity_TOC_sRGB), XCAFDoc_ColorSurf)
    pin = shapes.AddShape(BRepPrimAPI_MakeCylinder(3, 20).Shape(), False)
    TDataStd_Name.Set(pin, "Pin")
    sub = shapes.NewShape()
    TDataStd_Name.Set(sub, "Sub")
    shapes.AddComponent(sub, pin, _location())
    shapes.AddComponent(sub, pin, _location(20, 0, 0))
    top = shapes.NewShape()
    TDataStd_Name.Set(top, "Top")
    shapes.AddComponent(top, box, _location(100, 0, 0))
    shapes.AddComponent(top, sub, _location(0, 50, 0))
    shapes.AddComponent(top, sub, _location(0, 80, 0))
    if mirrored:
        shapes.AddComponent(top, box, _location(mirror=True))
    shapes.UpdateAssemblies()
    return _write_xcaf(doc)


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def _part(document_native: dict, part_id: str) -> dict:
    return next(p for p in document_native["document"]["parts"] if p["id"] == part_id)


def test_probe_counts_products_assemblies_and_placements():
    probe = step_assembly.probe_step(_assembly_step(mirrored=True))
    assert probe["products"] == 2  # Box and Pin
    assert probe["assemblies"] == 2  # Sub and Top
    assert probe["instances"] == 6  # 2 pins + box + 2 subs + the mirrored box
    assert probe["has_structure"] is True
    assert probe["mirrored_instances"] == 1
    assert probe["name"] == "Top"


def test_probe_endpoint_and_a_single_part_file_has_no_structure():
    response = client.post("/document/import/probe", json={"source_format": "step", "data_base64": _b64(_assembly_step())})
    assert response.status_code == 200 and response.json()["has_structure"] is True
    single = export_step({"b": BRepPrimAPI_MakeBox(5, 5, 5).Shape()})
    probe = client.post("/document/import/probe", json={"source_format": "step", "data_base64": _b64(single)}).json()
    assert probe["assemblies"] == 0 and probe["has_structure"] is False and probe["products"] >= 1


def test_one_part_per_prototype_with_poses_names_and_colours():
    imported = step_assembly.build_native_payload(step_assembly.read_step_structure(_assembly_step()), "My Assembly")
    parts = {p["name"]: p for p in imported.payload["document"]["parts"]}
    assert set(parts) == {"Box", "Pin", "Sub", "Top"}  # the repeated Pin is ONE Part
    assert [o["resolved_part_id"] for o in parts["Sub"]["occurrences"]] == [parts["Pin"]["id"]] * 2
    top = parts["Top"]
    assert [o["resolved_part_id"] for o in top["occurrences"]] == [parts["Box"]["id"], parts["Sub"]["id"], parts["Sub"]["id"]]
    flat = [c for o in top["occurrences"] for c in o["transform"]["translation"]]
    assert flat == pytest.approx([100, 0, 0, 0, 50, 0, 0, 80, 0])
    assert [o["fixed"] for o in top["occurrences"]] == [True, False, False]  # the first placement of the top assembly is grounded
    assert parts["Box"]["appearance"] == {"colour": "#FF0000"}
    assert imported.root_part_id == top["id"] and imported.folder == "My Assembly"
    assert sorted(imported.part_files.values()) == ["Box.didsa", "Pin.didsa", "Sub.didsa", "Top.didsa"]
    assert imported.report == {"imported": 2, "total": 2, "skipped": [], "baked": 0}


def test_a_mirrored_placement_is_baked_into_its_own_part():
    imported = step_assembly.build_native_payload(step_assembly.read_step_structure(_assembly_step(mirrored=True)), "A")
    parts = {p["name"]: p for p in imported.payload["document"]["parts"]}
    assert "Box (mirrored)" in parts and imported.report["baked"] == 1
    mirrored_occurrence = next(o for o in parts["Top"]["occurrences"] if o["resolved_part_id"] == parts["Box (mirrored)"]["id"])
    assert mirrored_occurrence["transform"]["rotation_angle_degrees"] == 0 and mirrored_occurrence["transform"]["translation"] == [0, 0, 0]


def test_file_names_are_unique_and_sanitised():
    used: set[str] = set()
    assert step_assembly.sanitise_name('a/b:c*?"<>|.') == "a_b_c______"
    assert step_assembly.sanitise_name("  ...  ", "Part") == "Part"
    assert step_assembly.unique_name("Bolt", used) == "Bolt"
    assert step_assembly.unique_name("bolt", used) == "bolt 2"
    assert step_assembly.unique_name("Bolt", used) == "Bolt 3"


def test_insert_endpoint_adds_a_sub_assembly_with_world_poses_equal_to_the_flat_import():
    root = client.post("/document/parts", json={"name": "Root"}).json()["id"]
    response = client.post(f"/document/parts/{root}/import-assembly", json={"source_format": "step", "data_base64": _b64(_assembly_step()), "name": "Imported"})
    assert response.status_code == 201
    body = response.json()
    assert body["occurrence_id"] and len(body["new_part_ids"]) == 4 and body["report"]["skipped"] == []
    assert body["suggested_files"][body["root_part_id"]] == "Imported/Top.didsa"
    occurrences = client.get(f"/document/parts/{root}/occurrences").json()
    assert len(occurrences) == 1 and occurrences[0]["resolved_part_id"] == body["root_part_id"] and occurrences[0]["fixed"] is True
    # the world poses: the assembly glb carries one node per placed leaf; compare the bounding box of the whole to the flat import of the same file
    flat_part = client.post("/document/parts", json={"name": "Flat"}).json()["id"]
    assert client.post(f"/document/parts/{flat_part}/import-features", json={"source_format": "step", "data_base64": _b64(_assembly_step())}).status_code == 201
    from app.document.import_geometry import _shape_from_step

    def bounds(content: bytes):
        box = Bnd_Box()
        brepbndlib.Add(_shape_from_step(content), box)
        return box.Get()

    assembled = client.get(f"/document/parts/{root}/export/assembly-step")
    flat = client.get(f"/document/parts/{flat_part}/export/step")
    assert assembled.status_code == 200 and flat.status_code == 200
    assert bounds(assembled.content) == pytest.approx(bounds(flat.content), abs=1e-4)


def test_open_as_new_replaces_the_session_with_the_imported_top_as_root():
    response = client.post("/document/import/assembly", json={"source_format": "step", "data_base64": _b64(_assembly_step()), "name": "Fresh"})
    assert response.status_code == 201
    body = response.json()
    assert body["occurrence_id"] is None
    exported = client.get("/document/export/native").json()
    assert exported["document"]["root_part_id"] == body["root_part_id"]
    assert {p["name"] for p in exported["document"]["parts"]} == {"Box", "Pin", "Sub", "Top"}


def test_a_product_with_no_shape_is_skipped_and_reported():
    structure = step_assembly.read_step_structure(_assembly_step())
    empty = step_assembly.ProductNode(key="empty", name="Ghost")  # no shape, no components
    structure.roots[0].children.append((empty, gp_Trsf()))
    imported = step_assembly.build_native_payload(structure, "A")
    assert imported.report["skipped"] == [{"name": "Ghost", "reason": "has no shape and no components"}]
    assert imported.report["imported"] == 2


def test_the_product_cap_is_a_clear_error(monkeypatch):
    monkeypatch.setattr(step_assembly, "MAX_PRODUCTS", 1)
    with pytest.raises(step_assembly.AssemblyImportError) as caught:
        step_assembly.read_step_structure(_assembly_step())
    assert caught.value.code == "import_too_large" and "import it as one part" in str(caught.value)
    response = client.post("/document/import/probe", json={"source_format": "step", "data_base64": _b64(_assembly_step())})
    assert response.status_code == 422 and response.json()["detail"]["type"] == "import_too_large"


def test_a_corrupt_file_and_a_mesh_format_are_422():
    corrupt = client.post("/document/import/probe", json={"source_format": "step", "data_base64": _b64(b"not a step file")})
    assert corrupt.status_code == 422 and corrupt.json()["detail"]["type"] in ("invalid_import_data", "import_failed")
    mesh = client.post("/document/import/probe", json={"source_format": "stl", "data_base64": _b64(b"x")})
    assert mesh.status_code == 422 and mesh.json()["detail"]["type"] == "unsupported_format"


def test_iges_one_part_per_solid():
    two_boxes = {"a": BRepPrimAPI_MakeBox(10, 10, 10).Shape(), "b": BRepPrimAPI_MakeBox(5, 5, 5).Shape()}
    data = export_iges(two_boxes)
    probe = client.post("/document/import/probe", json={"source_format": "iges", "data_base64": _b64(data)}).json()
    assert probe["products"] == 2 and probe["has_structure"] is False
    response = client.post("/document/import/assembly", json={"source_format": "iges", "data_base64": _b64(data), "name": "Plate"})
    assert response.status_code == 201
    exported = client.get("/document/export/native").json()
    names = sorted(p["name"] for p in exported["document"]["parts"])
    assert names == ["Plate", "Solid 1", "Solid 2"]
    top = _part(exported, response.json()["root_part_id"])
    assert len(top["occurrences"]) == 2 and all(o["transform"]["translation"] == [0, 0, 0] for o in top["occurrences"])


def test_rigid_transform_round_trip_of_a_rotation():
    trsf = gp_Trsf()
    trsf.SetRotation(__import__("OCC.Core.gp", fromlist=["gp_Ax1"]).gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), 1.0)
    trsf.SetTranslationPart(gp_Vec(1, 2, 3))
    as_dict = step_assembly._rigid_to_dict(trsf)
    assert as_dict["rotation_axis"] == pytest.approx([0, 0, 1]) and as_dict["rotation_angle_degrees"] == pytest.approx(57.2957795, rel=1e-6)
    assert as_dict["translation"] == pytest.approx([1, 2, 3])
