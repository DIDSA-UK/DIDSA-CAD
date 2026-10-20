"""STEP colours (`docs/appearance-tool-scope.md` D7, V4): the resolved appearance's colour and opacity written into
`export/step` and `export/assembly-step` through XCAF, checked by reading the exported file back with OCCT's own STEP
reader (`STEPCAFControl_Reader`, colours on) and by the raw `COLOUR_RGB` / `SURFACE_STYLE_TRANSPARENT` entities.

Needs a real pythonocc-core environment (boxes are real extrudes), like `test_appearance.py`, whose helpers it uses."""

import os
import re
import tempfile

from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.Quantity import Quantity_ColorRGBA, Quantity_TOC_sRGB
from OCC.Core.STEPCAFControl import STEPCAFControl_Reader
from OCC.Core.TDF import TDF_LabelSequence
from OCC.Core.TDocStd import TDocStd_Document
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.XCAFDoc import XCAFDoc_ColorSurf, XCAFDoc_DocumentTool

from app.document.step_export import step_colour
from tests.test_appearance import _body_ids, _box_part, _frame_assembly, _put, client


def _colour_of(colour_tool, shape) -> tuple[str, float] | None:
    """The surface colour XCAF read for `shape`, as `(#RRGGBB, opacity)`, or None when the file gives it none. (The
    `TopoDS_Shape` overload: this pythonocc build does not match the `TDF_Label` one for a label from a sequence.)"""
    rgba = Quantity_ColorRGBA()
    if not colour_tool.GetColor(shape, XCAFDoc_ColorSurf, rgba):
        return None
    r, g, b = rgba.GetRGB().Values(Quantity_TOC_sRGB)
    return ("#" + "".join(f"{round(v * 255):02X}" for v in (r, g, b)), round(rgba.Alpha(), 4))


def _read_step(data: bytes) -> list[dict]:
    """Every top-level shape of a STEP file: its bounding box's min x and size in x (to tell the boxes apart), its own
    colour, and each face's colour (`TopExp_Explorer` order)."""
    fd, path = tempfile.mkstemp(suffix=".step")
    os.close(fd)
    try:
        with open(path, "wb") as handle:
            handle.write(data)
        doc = TDocStd_Document("didsa-cad-step-colour-test")
        reader = STEPCAFControl_Reader()
        reader.SetColorMode(True)
        reader.ReadFile(path)
        assert reader.Transfer(doc)
    finally:
        os.unlink(path)
    shape_tool = XCAFDoc_DocumentTool.ShapeTool(doc.Main())
    colour_tool = XCAFDoc_DocumentTool.ColorTool(doc.Main())
    labels = TDF_LabelSequence()
    shape_tool.GetFreeShapes(labels)
    out = []
    for i in range(1, labels.Length() + 1):
        shape = shape_tool.GetShape(labels.Value(i))
        box = Bnd_Box()
        brepbndlib.Add(shape, box)
        x_min, _y0, _z0, x_max, _y1, _z1 = box.Get()
        faces = []
        explorer = TopExp_Explorer(shape, TopAbs_FACE)
        while explorer.More():
            faces.append(_colour_of(colour_tool, explorer.Current()))
            explorer.Next()
        out.append({"x": round(x_min), "size": round(x_max - x_min), "colour": _colour_of(colour_tool, shape), "faces": faces})
    return out


def _by_box(shapes: list[dict]) -> dict[tuple[int, int], dict]:
    return {(s["x"], s["size"]): s for s in shapes}


def test_step_colour():
    assert step_colour({}) is None
    assert step_colour({"metallic": 1.0, "roughness": 0.2, "emission": "#FFFFFF"}) is None  # no STEP equivalent
    assert step_colour({"colour": "#2F6FD6"}) == ("#2F6FD6", 1.0)
    assert step_colour({"opacity": 0.3}) == ("#C8C8C8", 0.3)  # the default colour, as the renderers show it


def test_part_step_without_appearance_has_no_colours():
    part = _box_part("Plain")
    data = client.get(f"/document/parts/{part['id']}/export/step").content
    assert b"COLOUR_RGB" not in data and b"SURFACE_STYLE" not in data
    (shape,) = _read_step(data)
    assert shape["colour"] is None and set(shape["faces"]) == {None}


def test_part_step_writes_body_and_face_colours_and_opacity():
    part = _box_part("Two bodies", two_bodies=True)
    body_a, body_b = _body_ids(part["id"])
    r = client.patch(
        f"/document/parts/{part['id']}",
        json={
            "appearance": {"colour": "#2F6FD6", "roughness": 0.6},
            "body_appearances": {body_b: {"opacity": 0.4}},
            "face_appearances": [{"face": {"body_id": body_a, "shape_type": "face", "index": 1}, "appearance": {"colour": "#202020"}}],
        },
    )
    assert r.status_code == 200, r.text
    data = client.get(f"/document/parts/{part['id']}/export/step").content
    shapes = _by_box(_read_step(data))
    first, second = shapes[(0, 10)], shapes[(30, 10)]
    assert first["colour"] == ("#2F6FD6", 1.0)
    # Only the face painted differently carries its own colour; the rest show the body's.
    assert [i for i, c in enumerate(first["faces"]) if c is not None] == [1]
    assert first["faces"][1] == ("#202020", 1.0)
    # An opacity-only body keeps the part's colour below it (field by field, D3), written with its transparency.
    assert second["colour"] == ("#2F6FD6", 0.4)
    assert set(second["faces"]) == {None}
    # The raw entities: hex / 255 exactly (sRGB, as picked), and STEP's transparency is 1 - opacity.
    text = data.decode("ascii", errors="replace")
    rgbs = {tuple(round(float(v) * 255) for v in m) for m in re.findall(r"COLOUR_RGB\('[^']*',([\d.E+-]+),([\d.E+-]+),([\d.E+-]+)\)", text)}
    assert rgbs == {(0x2F, 0x6F, 0xD6), (0x20, 0x20, 0x20)}
    assert [round(float(v), 4) for v in re.findall(r"SURFACE_STYLE_TRANSPARENT\(([\d.E+-]+)\)", text)] == [0.6]
    # Product names and the AP242 schema are untouched by the colours.
    assert "AP242" in text.split("FILE_SCHEMA", 1)[1].split(";", 1)[0]


def test_part_step_ignores_fields_step_cannot_carry():
    part = _box_part("Shiny")
    r = client.patch(f"/document/parts/{part['id']}", json={"appearance": {"metallic": 1.0, "roughness": 0.1, "emission_strength": 2.0}})
    assert r.status_code == 200, r.text
    data = client.get(f"/document/parts/{part['id']}/export/step").content
    assert b"COLOUR_RGB" not in data and b"SURFACE_STYLE_TRANSPARENT" not in data


def test_assembly_step_colours_as_seen_from_the_exported_root():
    """The assembly export resolves every placed Body from the root (D3): the root's overrides beat the sub-assembly's
    file and the parts' own records, field by field; a node override reaches everything below it."""
    a = _frame_assembly()
    bar_body_0 = a["bar_bodies"][0]
    # Lower levels: the frame file paints barB green and half see-through; the bar paints itself red.
    assert _put(a["frame"], {"path": "barB", "appearance": {"colour": "#00AA00", "opacity": 0.5}}).status_code == 200
    assert client.patch(f"/document/parts/{a['bar']}", json={"appearance": {"colour": "#AA0000"}}).status_code == 200
    # The root: a whole-assembly base coat, the frame blue, one body of barA its own colour, one of its faces white.
    assert _put(a["root"], {"path": "", "appearance": {"colour": "#D0D0D0"}}).status_code == 200
    assert _put(a["root"], {"path": "frame", "appearance": {"colour": "#2F6FD6"}}).status_code == 200
    assert _put(a["root"], {"path": "frame/barA", "body_id": bar_body_0, "appearance": {"colour": "#D63A2F"}}).status_code == 200
    face = {"body_id": bar_body_0, "shape_type": "face", "index": 2}
    assert _put(a["root"], {"path": "frame/barA", "body_id": bar_body_0, "face": face, "appearance": {"colour": "#FFFFFF"}}).status_code == 200

    shapes = _by_box(_read_step(client.get(f"/document/parts/{a['root']}/export/assembly-step").content))
    # Root own box (0..20), bolt (-10, size 2), frame's own box (30, 6), barA's bodies (30 and 42, 4), barB's (80, 92).
    assert set(shapes) == {(0, 20), (-10, 2), (30, 6), (30, 4), (42, 4), (80, 4), (92, 4)}
    assert shapes[(0, 20)]["colour"] == ("#D0D0D0", 1.0)
    assert shapes[(-10, 2)]["colour"] == ("#D0D0D0", 1.0)  # the whole-assembly coat beats the bolt's lack of paint
    assert shapes[(30, 6)]["colour"] == ("#2F6FD6", 1.0)
    bar_a_0 = shapes[(30, 4)]
    assert bar_a_0["colour"] == ("#D63A2F", 1.0)
    assert [i for i, c in enumerate(bar_a_0["faces"]) if c is not None] == [2] and bar_a_0["faces"][2] == ("#FFFFFF", 1.0)
    assert shapes[(42, 4)]["colour"] == ("#2F6FD6", 1.0)  # the root's frame override beats the bar's own red
    # barB: the root's blue beats the frame file's green, but the frame file's opacity shows through (nothing above sets one).
    assert shapes[(80, 4)]["colour"] == ("#2F6FD6", 0.5)
    assert shapes[(92, 4)]["colour"] == ("#2F6FD6", 0.5)


def test_assembly_step_of_a_sub_assembly_uses_its_own_overrides():
    """Exported from the frame, the root's overrides do not apply: the frame file's own paint and the bar's do."""
    a = _frame_assembly()
    assert _put(a["root"], {"path": "frame", "appearance": {"colour": "#2F6FD6"}}).status_code == 200
    assert _put(a["frame"], {"path": "barB", "appearance": {"colour": "#00AA00", "opacity": 0.5}}).status_code == 200
    assert client.patch(f"/document/parts/{a['bar']}", json={"appearance": {"colour": "#AA0000"}}).status_code == 200
    shapes = _by_box(_read_step(client.get(f"/document/parts/{a['frame']}/export/assembly-step").content))
    assert set(shapes) == {(0, 6), (0, 4), (12, 4), (50, 4), (62, 4)}
    assert shapes[(0, 6)]["colour"] is None
    assert shapes[(0, 4)]["colour"] == ("#AA0000", 1.0) and shapes[(12, 4)]["colour"] == ("#AA0000", 1.0)
    assert shapes[(50, 4)]["colour"] == ("#00AA00", 0.5) and shapes[(62, 4)]["colour"] == ("#00AA00", 0.5)


def test_assembly_step_paints_pattern_copies():
    """A component pattern's copies are exported Bodies too; a single copy painted by its `#pattern:` path, the rest by
    the pattern's own override (`scope: "pattern"`)."""
    a = _frame_assembly()
    pattern = client.post(
        f"/document/parts/{a['root']}/component-patterns",
        json={"source_occurrence_ids": ["bolt"], "pattern_type": "linear", "direction": [0.0, 1.0, 0.0], "count": 3, "spacing": 10.0},
    )
    assert pattern.status_code in (200, 201), pattern.text
    pattern_id = pattern.json()["id"]
    assert _put(a["root"], {"path": "bolt", "scope": "pattern", "pattern_id": pattern_id, "appearance": {"colour": "#333333"}}).status_code == 200
    assert _put(a["root"], {"path": f"bolt#pattern:{pattern_id}:2", "appearance": {"opacity": 0.25}}).status_code == 200
    shapes = [s for s in _read_step(client.get(f"/document/parts/{a['root']}/export/assembly-step").content) if (s["x"], s["size"]) == (-10, 2)]
    assert sorted(s["colour"] for s in shapes) == [("#333333", 0.25), ("#333333", 1.0), ("#333333", 1.0)]
