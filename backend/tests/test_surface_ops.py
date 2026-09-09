"""Unit test for `app.document.surface_ops.sew_surfaces` - the shared
low-level OCCT sewing primitive Knit Surfaces/Solid from Surfaces both
build on. Per the same sandbox caveat as every other OCCT-touching test in
this project (see `test_stage_d_fillet.py`'s own docstring), needs a real
pythonocc-core environment (not available in this repo's own dev sandbox)."""

from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakeWire
from OCC.Core.gp import gp_Pnt
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Face

from app.document.surface_ops import sew_surfaces


def _square_face(x0: float, y0: float, z: float, size: float) -> TopoDS_Face:
    corners = [
        gp_Pnt(x0, y0, z),
        gp_Pnt(x0 + size, y0, z),
        gp_Pnt(x0 + size, y0 + size, z),
        gp_Pnt(x0, y0 + size, z),
    ]
    wire_maker = BRepBuilderAPI_MakeWire()
    for a, b in zip(corners, corners[1:] + corners[:1]):
        wire_maker.Add(BRepBuilderAPI_MakeEdge(a, b).Edge())
    return BRepBuilderAPI_MakeFace(wire_maker.Wire()).Face()


def _face_count(shape) -> int:
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    count = 0
    while explorer.More():
        count += 1
        explorer.Next()
    return count


def test_sewing_two_adjacent_unit_squares_produces_a_two_face_shell():
    # Two coplanar-adjacent unit squares sharing an edge (x in [0,1] and
    # x in [1,2], both y in [0,1], both z=0) - a minimal "these two
    # surfaces are actually touching" case.
    face_a = _square_face(0.0, 0.0, 0.0, 1.0)
    face_b = _square_face(1.0, 0.0, 0.0, 1.0)

    sewn = sew_surfaces([face_a, face_b])

    assert sewn is not None
    assert not sewn.IsNull()
    assert _face_count(sewn) == 2


def test_sewing_a_single_face_returns_it_unchanged_in_face_count():
    face = _square_face(0.0, 0.0, 0.0, 1.0)

    sewn = sew_surfaces([face])

    assert _face_count(sewn) == 1
