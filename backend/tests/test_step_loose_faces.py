"""A STEP (or IGES) file whose faces are not grouped into shells or solids (a Creo surface model: 750 faces, no shell, no solid) is sewn into solids on import, and a
face that is a whole periodic surface by itself (a torus, a sphere) is kept rather than dropped when its neighbours sew into a shell."""

import base64
import math
import os
import tempfile

import pytest
from fastapi.testclient import TestClient
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakeSphere, BRepPrimAPI_MakeTorus
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Pnt
from OCC.Core.IGESControl import IGESControl_Writer
from OCC.Core.STEPControl import STEPControl_AsIs, STEPControl_Writer
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Compound, topods

from app.document.import_geometry import _shape_from_iges, _shape_from_step, shape_has_solid
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

EXPECTED_VOLUME = 100 * 60 * 40 - math.pi * 10**2 * 40 + 2 * math.pi**2 * 30 * 8**2 + 4 / 3 * math.pi * 15**3


def _loose_faces():
    """A box with a hole, a torus and a sphere, as a bare list of faces (the torus and sphere are one face each)."""
    box = BRepPrimAPI_MakeBox(100, 60, 40).Shape()
    hole = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(50, 30, -1), gp_Dir(0, 0, 1)), 10, 50).Shape()
    part = BRepAlgoAPI_Cut(box, hole).Shape()
    torus = BRepPrimAPI_MakeTorus(gp_Ax2(gp_Pnt(300, 0, 0), gp_Dir(0, 0, 1)), 30, 8).Shape()
    sphere = BRepPrimAPI_MakeSphere(gp_Pnt(500, 0, 0), 15).Shape()
    faces = []
    for solid in (part, torus, sphere):
        explorer = TopExp_Explorer(solid, TopAbs_FACE)
        while explorer.More():
            faces.append(topods.Face(explorer.Current()))
            explorer.Next()
    return faces


def _compound(faces):
    builder, compound = BRep_Builder(), TopoDS_Compound()
    builder.MakeCompound(compound)
    for face in faces:
        builder.Add(compound, face)
    return compound


def _step_bytes(faces) -> bytes:
    writer = STEPControl_Writer()
    writer.Transfer(_compound(faces), STEPControl_AsIs)
    fd, path = tempfile.mkstemp(suffix=".step")
    os.close(fd)
    try:
        writer.Write(path)
        return open(path, "rb").read()
    finally:
        os.unlink(path)


def _iges_bytes(faces) -> bytes:
    writer = IGESControl_Writer("MM", 0)  # faces mode: loose surfaces, no solids
    writer.AddShape(_compound(faces))
    writer.ComputeModel()
    fd, path = tempfile.mkstemp(suffix=".igs")
    os.close(fd)
    try:
        writer.Write(path)
        return open(path, "rb").read()
    finally:
        os.unlink(path)


def _count(shape, kind) -> int:
    explorer, n = TopExp_Explorer(shape, kind), 0
    while explorer.More():
        n += 1
        explorer.Next()
    return n


def _volume(shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


@pytest.mark.parametrize("reader,make", [(_shape_from_step, _step_bytes), (_shape_from_iges, _iges_bytes)])
def test_loose_faces_become_solids_and_a_lone_periodic_face_is_kept(reader, make):
    faces = _loose_faces()
    shape = reader(make(faces))
    assert shape_has_solid(shape)
    assert _count(shape, TopAbs_SOLID) == 3  # the part, the torus, the sphere
    assert _count(shape, TopAbs_FACE) == len(faces) == 9  # nothing dropped
    assert _volume(shape) == pytest.approx(EXPECTED_VOLUME, rel=1e-4)


def test_a_step_that_already_has_a_solid_is_left_alone():
    from app.document.step_export import export_step

    box = BRepPrimAPI_MakeBox(10, 20, 30).Shape()
    shape = _shape_from_step(export_step({"b": box}))
    assert _count(shape, TopAbs_SOLID) == 1 and _volume(shape) == pytest.approx(6000, rel=1e-6)


def test_http_import_of_loose_face_step_reports_a_solid():
    part_id = client.post("/document/parts", json={"name": "Loose"}).json()["id"]
    data = base64.b64encode(_step_bytes(_loose_faces())).decode()
    response = client.post(f"/document/parts/{part_id}/import-features", json={"source_format": "step", "data_base64": data})
    assert response.status_code == 201 and response.json()["solid"] is True
    mass = client.get(f"/document/parts/{part_id}/mass-properties")
    assert mass.status_code == 200


def test_a_step_whose_faces_cannot_be_sewn_into_solids_keeps_its_own_faces():
    box = BRepPrimAPI_MakeBox(100, 60, 40).Shape()
    faces = []
    explorer = TopExp_Explorer(box, TopAbs_FACE)
    while explorer.More():
        faces.append(topods.Face(explorer.Current()))
        explorer.Next()
    shape = _shape_from_step(_step_bytes(faces[:5]))  # an open box: it never closes
    assert not shape_has_solid(shape)
    assert _count(shape, TopAbs_FACE) == 5
