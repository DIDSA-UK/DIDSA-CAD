from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh


def test_occt_box_construction():
    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    assert not box.IsNull()


def test_occt_meshing():
    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    mesh = BRepMesh_IncrementalMesh(box, 0.1)
    mesh.Perform()
    assert mesh.IsDone()
