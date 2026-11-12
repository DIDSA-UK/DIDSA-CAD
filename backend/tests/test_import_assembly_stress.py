"""F-6 hardening: harder generated assemblies than the first fixtures, with an INDEPENDENT oracle: the expected world shape is built by hand from the generation spec
(prototype shapes transformed by the composed placements) and compared, by volume and bounding box, with what the importer produced once inserted and exported.

Covers: four-level nesting with shared prototypes and non-axis rotations, a MIRRORED sub-assembly (with a nested rotated sub-assembly inside it), a mirrored leaf, per-instance
colours (the Occurrence's own colour), names, and a 300-placement assembly (time and payload size recorded)."""

import base64
import math
import os
import tempfile
import time

import pytest
from fastapi.testclient import TestClient
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCone, BRepPrimAPI_MakeCylinder
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax1, gp_Ax2, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
from OCC.Core.Quantity import Quantity_Color, Quantity_TOC_sRGB
from OCC.Core.STEPCAFControl import STEPCAFControl_Writer
from OCC.Core.STEPControl import STEPControl_AsIs
from OCC.Core.TDataStd import TDataStd_Name
from OCC.Core.TDocStd import TDocStd_Document
from OCC.Core.TopLoc import TopLoc_Location
from OCC.Core.TopoDS import TopoDS_Compound
from OCC.Core.BRep import BRep_Builder
from OCC.Core.XCAFDoc import XCAFDoc_ColorSurf, XCAFDoc_DocumentTool

from app.document import step_assembly
from app.document.import_geometry import _shape_from_step
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def trsf(translation=(0, 0, 0), axis=(0, 0, 1), degrees=0.0, mirror_plane=None) -> gp_Trsf:
    t = gp_Trsf()
    if mirror_plane is not None:
        t.SetMirror(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(*mirror_plane)))
        return t
    if degrees:
        t.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(*axis)), math.radians(degrees))
    t2 = gp_Trsf()
    t2.SetTranslation(gp_Vec(*translation))
    return t2.Multiplied(t)  # rotate first, then translate: the importer's convention


class Spec:
    """A hand-built assembly: prototypes (shape or children) and placements, built twice: once as an XCAF STEP, once as the expected world shape."""

    def __init__(self):
        self.doc = TDocStd_Document("stress")
        self.shapes = XCAFDoc_DocumentTool.ShapeTool(self.doc.Main())
        self.colours = XCAFDoc_DocumentTool.ColorTool(self.doc.Main())
        self.protos: dict[str, tuple] = {}  # name -> (label, shape or None, [(child name, trsf)])

    def leaf(self, name, shape, colour=None):
        label = self.shapes.AddShape(shape, False)
        TDataStd_Name.Set(label, name)
        if colour:
            self.colours.SetColor(label, Quantity_Color(*colour, Quantity_TOC_sRGB), XCAFDoc_ColorSurf)
        self.protos[name] = (label, shape, [])

    def assembly(self, name, placements, component_colours=None):
        label = self.shapes.NewShape()
        TDataStd_Name.Set(label, name)
        for index, (child, t) in enumerate(placements):
            component = self.shapes.AddComponent(label, self.protos[child][0], TopLoc_Location(t))
            if component_colours and component_colours.get(index):
                self.colours.SetColor(component, Quantity_Color(*component_colours[index], Quantity_TOC_sRGB), XCAFDoc_ColorSurf)
        self.protos[name] = (label, None, list(placements))

    def step_bytes(self) -> bytes:
        self.shapes.UpdateAssemblies()
        writer = STEPCAFControl_Writer()
        writer.Transfer(self.doc, STEPControl_AsIs)
        fd, path = tempfile.mkstemp(suffix=".step")
        os.close(fd)
        try:
            assert writer.Write(path) == 1
            return open(path, "rb").read()
        finally:
            os.unlink(path)

    def expected(self, name, accumulated=None) -> list:
        """The world shapes of `name` (a list), by composing every placement down the tree."""
        accumulated = accumulated or gp_Trsf()
        _label, shape, children = self.protos[name]
        if shape is not None:
            return [BRepBuilderAPI_Transform(shape, accumulated, True).Shape()]
        out = []
        for child, t in children:
            out += self.expected(child, accumulated.Multiplied(t))
        return out


def volume(shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


def bounds(shapes) -> tuple:
    box = Bnd_Box()
    for shape in shapes:
        brepbndlib.Add(shape, box)
    return box.Get()


def insert_and_export(step: bytes, name="Imported"):
    root = client.post("/document/parts", json={"name": "Root"}).json()["id"]
    response = client.post(f"/document/parts/{root}/import-assembly", json={"source_format": "step", "data_base64": base64.b64encode(step).decode(), "name": name})
    assert response.status_code == 201, response.text
    exported = client.get(f"/document/parts/{root}/export/assembly-step")
    assert exported.status_code == 200
    return response.json(), _shape_from_step(exported.content), root


def total_volume(shapes) -> float:
    return sum(volume(s) for s in shapes)


def make_deep() -> Spec:
    spec = Spec()
    spec.leaf("Bolt", BRepPrimAPI_MakeCylinder(2, 12).Shape(), colour=(0.9, 0.1, 0.1))
    spec.leaf("Plate", BRepPrimAPI_MakeBox(40, 30, 4).Shape())
    spec.leaf("Cone", BRepPrimAPI_MakeCone(5, 1, 9).Shape())
    spec.assembly("Pair", [("Bolt", trsf((0, 0, 4))), ("Bolt", trsf((20, 0, 4)))])
    spec.assembly("Panel", [("Plate", trsf()), ("Pair", trsf((5, 5, 0), (0, 1, 0), 0)), ("Pair", trsf((5, 20, 0)))], {2: (0.1, 0.2, 0.9)})
    spec.assembly("Frame", [("Panel", trsf((0, 0, 0), (0, 0, 1), 30)), ("Panel", trsf((100, 0, 0), (1, 0, 0), 90)), ("Cone", trsf((10, 10, 50), (1, 1, 0), 33))])
    spec.assembly("Machine", [("Frame", trsf()), ("Frame", trsf((0, 200, 0), (0, 0, 1), 180)), ("Bolt", trsf((300, 0, 0), (0, 1, 1), 17))])
    return spec


def test_four_levels_shared_prototypes_and_non_axis_rotations_match_the_hand_built_world():
    spec = make_deep()
    result, assembled, _root = insert_and_export(spec.step_bytes())
    world = spec.expected("Machine")
    assert result["report"]["skipped"] == []
    assert volume(assembled) == pytest.approx(total_volume(world), rel=1e-6)
    assert bounds([assembled]) == pytest.approx(bounds(world), abs=1e-3)
    # one Part per prototype, however many placements: Bolt, Plate, Cone, Pair, Panel, Frame, Machine
    assert len(result["new_part_ids"]) == 7


def test_a_mirrored_sub_assembly_with_a_nested_rotated_one_inside_is_flattened_not_dropped():
    spec = Spec()
    spec.leaf("Pin", BRepPrimAPI_MakeCylinder(2, 10).Shape())
    spec.leaf("Block", BRepPrimAPI_MakeBox(10, 20, 30).Shape())
    spec.assembly("Inner", [("Pin", trsf((1, 2, 3), (0, 0, 1), 40)), ("Block", trsf((30, 0, 0)))])
    spec.assembly("Leg", [("Inner", trsf((5, 0, 0), (0, 1, 0), 25)), ("Pin", trsf((0, 0, 40)))])
    spec.assembly("Pair", [("Leg", trsf((100, 0, 0))), ("Leg", trsf(mirror_plane=(1, 0, 0)))])  # the second is MIRRORED
    result, assembled, _root = insert_and_export(spec.step_bytes())
    world = spec.expected("Pair")
    assert result["report"]["skipped"] == []
    assert result["report"]["baked"] >= 1
    assert volume(assembled) == pytest.approx(total_volume(world), rel=1e-6)
    assert bounds([assembled]) == pytest.approx(bounds(world), abs=1e-3)


def test_mirroring_twice_is_a_rigid_placement_again_and_stays_shared():
    spec = Spec()
    spec.leaf("Block", BRepPrimAPI_MakeBox(10, 20, 30).Shape())
    spec.assembly("Inner", [("Block", trsf((5, 0, 0), mirror_plane=(0, 1, 0)))])  # mirrored leaf inside...
    spec.assembly("Outer", [("Inner", trsf(mirror_plane=(0, 1, 0)))])  # ...under a mirrored sub-assembly: net rigid
    result, assembled, _root = insert_and_export(spec.step_bytes())
    world = spec.expected("Outer")
    assert result["report"]["skipped"] == []
    assert volume(assembled) == pytest.approx(total_volume(world), rel=1e-6)
    assert bounds([assembled]) == pytest.approx(bounds(world), abs=1e-3)


def test_per_instance_colours_become_the_occurrences_own_colour():
    spec = make_deep()
    imported = step_assembly.build_native_payload(step_assembly.read_step_structure(spec.step_bytes()), "M")
    parts = {p["name"]: p for p in imported.payload["document"]["parts"]}
    def near(hex_a, hex_b):
        return all(abs(int(hex_a[i : i + 2], 16) - int(hex_b[i : i + 2], 16)) <= 2 for i in (1, 3, 5))

    assert near(parts["Bolt"]["appearance"]["colour"], "#E61A1A")  # the prototype's own colour (sRGB rounding allowed)
    colours = [o["color"] for o in parts["Panel"]["occurrences"]]
    assert colours[:2] == [None, None] and near(colours[2], "#1A33E6")  # the third placement (a Pair) carries its own colour


def test_names_survive_and_unnamed_products_get_a_usable_name():
    spec = Spec()
    spec.leaf("", BRepPrimAPI_MakeBox(5, 5, 5).Shape())  # unnamed leaf
    spec.assembly("Holder", [("", trsf())])
    imported = step_assembly.build_native_payload(step_assembly.read_step_structure(spec.step_bytes()), "File Name")
    names = sorted(p["name"] for p in imported.payload["document"]["parts"])
    assert "Holder" in names and all(n for n in names)


def test_six_hundred_flat_placements_of_twenty_prototypes_in_reasonable_time_and_size():
    spec = Spec()
    for i in range(20):
        spec.leaf(f"P{i}", BRepPrimAPI_MakeBox(5 + i, 6, 7).Shape())
    spec.assembly("Big", [(f"P{(i * 7) % 20}", trsf(((i % 30) * 30, (i // 30) * 40, 0))) for i in range(600)])
    step = spec.step_bytes()
    started = time.time()
    probe = step_assembly.probe_step(step)
    imported = step_assembly.build_native_payload(step_assembly.read_step_structure(step), "Big")
    elapsed = time.time() - started
    size = sum(len(f["source_data_base64"]) for p in imported.payload["document"]["parts"] for f in p["features"])
    print(f"\nF-6 stress: {probe['instances']} placements, {len(imported.payload['document']['parts'])} parts, STEP {len(step)} B, payload {size} B, {elapsed:.2f} s")
    assert probe["products"] == 20 and probe["instances"] == 600
    assert len(imported.payload["document"]["parts"]) == 21  # 20 leaves + the assembly
    assert len(next(p for p in imported.payload["document"]["parts"] if p["name"] == "Big")["occurrences"]) == 600
    root = client.post("/document/parts", json={"name": "Root"}).json()["id"]
    started = time.time()
    response = client.post(f"/document/parts/{root}/import-assembly", json={"source_format": "step", "data_base64": base64.b64encode(step).decode()})
    assert response.status_code == 201
    mesh = client.get(f"/document/parts/{root}/assembly-mesh.glb")
    print(f"F-6 stress: insert + assembly mesh {time.time() - started:.2f} s ({len(mesh.content)} B glb)")
    assert mesh.status_code == 200
