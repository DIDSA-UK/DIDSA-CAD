"""Colours on import (STEP and IGES), `app.document.import_colours`: the colour a file puts on its faces comes back on the Part's body (one-part import) and on each Part
of an assembly import. Matching is by geometry (centroid and area), so it survives the IGES healer rebuilding faces. Files here are written by our own exporters (with
colours) or are small hand-made IGES text; the real SolidWorks files are run by hand (the owner's data is not committed)."""

import base64

import pytest
from fastapi.testclient import TestClient
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder

from app.document import import_colours, step_assembly
from app.document.iges_export import export_iges
from app.document.step_export import export_step
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def _body_colour(fmt: str, data: bytes):
    root = client.post("/document/parts", json={"name": "C"}).json()["id"]
    assert client.post(f"/document/parts/{root}/import-features", json={"source_format": fmt, "data_base64": _b64(data)}).status_code == 201
    part = next(p for p in client.get("/document/export/native").json()["document"]["parts"] if p["id"] == root)
    values = list((part.get("body_appearances") or {}).values())
    return values[0]["colour"] if values else None


def test_a_coloured_iges_gives_its_body_that_colour():
    box = BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()
    assert _body_colour("iges", export_iges({"b": box}, appearances={"b": ({"colour": "#3366CC"}, {})})) == "#3366CC"


def test_a_coloured_step_gives_its_body_that_colour():
    box = BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()
    assert _body_colour("step", export_step({"b": box}, appearances={"b": ({"colour": "#CC3333"}, {})})) == "#CC3333"


def test_an_uncoloured_file_leaves_the_body_alone():
    box = BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()
    assert _body_colour("iges", export_iges({"b": box})) is None
    assert _body_colour("step", export_step({"b": box})) is None


def test_mixed_colours_on_one_body_keep_the_one_covering_most_of_it():
    box = BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape()
    look = ({"colour": "#CC3333"}, {0: {"colour": "#3333CC"}})  # one face blue, the rest red
    assert _body_colour("step", export_step({"b": box}, appearances={"b": look})) == "#CC3333"


def test_each_solid_of_an_iges_assembly_import_takes_its_own_colour_even_after_healing():
    bodies = {"a": BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape(), "b": BRepPrimAPI_MakeCylinder(4.0, 30.0).Shape()}
    data = export_iges(bodies, appearances={"a": ({"colour": "#CC3333"}, {}), "b": ({"colour": "#33CC33"}, {})})
    structure = step_assembly.read_iges_solids(data)
    colours = sorted(child.colour for child, _t in structure.roots[0].children)
    assert colours == ["#33CC33", "#CC3333"]


def test_a_step_assembly_leaf_with_colour_only_on_its_solids_is_coloured():
    # SolidWorks puts a part's colour on its solids, not on the product: a colour on a face sub-shape must reach the Part
    from tests.test_import_assembly_stress import Spec

    spec = Spec()
    spec.leaf("Block", BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape())
    from OCC.Core.Quantity import Quantity_Color, Quantity_TOC_sRGB
    from OCC.Core.XCAFDoc import XCAFDoc_ColorSurf

    label = spec.protos["Block"][0]
    from OCC.Core.TopAbs import TopAbs_FACE
    from OCC.Core.TopExp import TopExp_Explorer

    explorer = TopExp_Explorer(spec.protos["Block"][1], TopAbs_FACE)
    while explorer.More():
        sub = spec.shapes.AddSubShape(label, explorer.Current())
        spec.colours.SetColor(sub, Quantity_Color(0.2, 0.4, 0.8, Quantity_TOC_sRGB), XCAFDoc_ColorSurf)
        explorer.Next()
    spec.assembly("Holder", [("Block", __import__("tests.test_import_assembly_stress", fromlist=["trsf"]).trsf())])
    imported = step_assembly.build_native_payload(step_assembly.read_step_structure(spec.step_bytes()), "X")
    block = next(p for p in imported.payload["document"]["parts"] if p["name"] == "Block")
    colour = block["appearance"]["colour"]
    assert all(abs(int(colour[i : i + 2], 16) - v) <= 2 for i, v in ((1, 51), (3, 102), (5, 204)))


def _iges_with_colour(colour_percent: str, coloured_entities: int, plain_entities: int) -> bytes:
    """A skeleton IGES directory + parameter section: entity 314 first, then `coloured_entities` surfaces pointing at it and `plain_entities` that do not."""
    directory, parameters = [], []

    def add(entity: int, colour: int, params: str):
        seq = len(directory) + 1
        directory.append("%8d%8d%8d%8d%8d%8d%8d%8d%8s" % (entity, seq, 0, 0, 0, 0, 0, 0, "0") + "D%7d" % seq)
        directory.append("%8d%8d%8d%8d%8d%8s%8s%8s%8s" % (entity, 0, colour, 1, 0, "", "", "", "") + "D%7d" % (seq + 1))
        parameters.append(params.ljust(64)[:64] + "%8d" % seq + "P%7d" % (len(parameters) + 1))

    add(314, 0, "314," + colour_percent + ",;")
    for _ in range(coloured_entities):
        add(144, -1, "144,1,0,0,0;")
    for _ in range(plain_entities):
        add(144, 0, "144,1,0,0,0;")
    return ("\n".join(["start".ljust(72) + "S      1", "global".ljust(72) + "G      1"] + directory + parameters + ["T".ljust(72) + "T      1"])).encode()


def test_iges_file_colour_reads_the_colour_a_directory_pointer_names():
    assert import_colours.iges_file_colour(_iges_with_colour("79.2156862745098,81.9607843137255,93.3333333333333", 3, 1)) == "#CAD1EE"
    assert import_colours.iges_file_colour(_iges_with_colour("100,0,0", 1, 5)) == "#FF0000"
    assert import_colours.iges_file_colour(_iges_with_colour("100,0,0", 0, 4)) is None
    assert import_colours.iges_file_colour(b"not an iges file") is None


def test_a_file_the_colour_reader_cannot_read_still_imports_uncoloured():
    index = import_colours.colour_index("iges", b"garbage")
    assert index.count == 0 and index.dominant_colour(BRepPrimAPI_MakeBox(1, 1, 1).Shape()) is None
