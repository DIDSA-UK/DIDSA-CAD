"""Colours on import (STEP and IGES): the colour a file puts on its faces, found again on the shapes the importer builds.

OCCT's XCAF readers (`STEPCAFControl_Reader`, `IGESCAFControl_Reader`) keep colours on labels and on face sub-labels, but the importers in `import_geometry` read
plain shapes (and the IGES path sews and rebuilds faces), so the two never share shape identity. They are matched by GEOMETRY instead: every face the CAF reader
colours is recorded by its centroid and area (`ColourIndex`), and a face of an imported shape takes the colour of the recorded face at the same place with the
same area. A body's colour is the one covering most of its area (`dominant_colour`): a body is given one colour, not per-face colours (a file with several
colours on one body keeps the biggest; per-face colours would need face references the importer does not make).

The index is cached by file hash like the healed IGES shape (the CAF read is a second pass over the file)."""

from __future__ import annotations

import hashlib
import os
import tempfile

from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GProp import GProp_GProps
from OCC.Core.IFSelect import IFSelect_RetDone
from OCC.Core.IGESCAFControl import IGESCAFControl_Reader
from OCC.Core.Quantity import Quantity_Color, Quantity_TOC_sRGB
from OCC.Core.STEPCAFControl import STEPCAFControl_Reader
from OCC.Core.TDF import TDF_Label, TDF_LabelSequence
from OCC.Core.TDocStd import TDocStd_Document
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape, topods
from OCC.Core.XCAFDoc import XCAFDoc_ColorGen, XCAFDoc_ColorSurf, XCAFDoc_ColorTool, XCAFDoc_DocumentTool

_CELL = 0.05  # mm: the centroid grid
_MATCH_DISTANCE = 0.02  # mm
_CACHE: dict[str, "ColourIndex"] = {}
_CACHE_MAX = 3


def _hex(colour: Quantity_Color) -> str:
    r, g, b = colour.Values(Quantity_TOC_sRGB)
    return "#%02X%02X%02X" % tuple(max(0, min(255, round(c * 255))) for c in (r, g, b))


def _label_colour(label: TDF_Label) -> str | None:
    colour = Quantity_Color()
    for kind in (XCAFDoc_ColorSurf, XCAFDoc_ColorGen):
        if XCAFDoc_ColorTool.GetColor(label, kind, colour):
            return _hex(colour)
    return None


def _face_key(face: TopoDS_Shape) -> tuple[float, float, float, float]:
    props = GProp_GProps()
    brepgprop.SurfaceProperties(face, props)
    centre = props.CentreOfMass()
    return centre.X(), centre.Y(), centre.Z(), props.Mass()


class ColourIndex:
    """Faces a file coloured, by place: `colour_of(face)` and `dominant_colour(shape)`."""

    def __init__(self) -> None:
        self.fallback: str | None = None  # a file-wide colour read straight from the file when OCCT's reader attached none (IGES colour pointers)
        self._cells: dict[tuple[int, int, int], list[tuple[float, float, float, float, str]]] = {}
        self.count = 0

    def add(self, face: TopoDS_Shape, colour: str) -> None:
        x, y, z, area = _face_key(face)
        key = (round(x / _CELL), round(y / _CELL), round(z / _CELL))
        self._cells.setdefault(key, []).append((x, y, z, area, colour))
        self.count += 1

    def colour_of(self, face: TopoDS_Shape) -> str | None:
        x, y, z, area = _face_key(face)
        cx, cy, cz = round(x / _CELL), round(y / _CELL), round(z / _CELL)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for ox, oy, oz, oarea, colour in self._cells.get((cx + dx, cy + dy, cz + dz), ()):
                        if abs(ox - x) < _MATCH_DISTANCE and abs(oy - y) < _MATCH_DISTANCE and abs(oz - z) < _MATCH_DISTANCE and abs(oarea - area) <= 1e-3 * max(area, oarea) + 1e-6:
                            return colour
        return None

    def dominant_colour(self, shape: TopoDS_Shape) -> str | None:
        """The colour covering most of `shape`'s area among the faces this index knows, or None when none matched."""
        if self.count == 0:
            return self.fallback
        area_by_colour: dict[str, float] = {}
        explorer = TopExp_Explorer(shape, TopAbs_FACE)
        while explorer.More():
            face = topods.Face(explorer.Current())
            colour = self.colour_of(face)
            if colour is not None:
                area_by_colour[colour] = area_by_colour.get(colour, 0.0) + _face_key(face)[3]
            explorer.Next()
        return max(area_by_colour, key=area_by_colour.get) if area_by_colour else self.fallback


def _collect(shape_tool, label: TDF_Label, index: ColourIndex, location, depth: int = 0) -> None:
    if depth > 32:
        return
    if shape_tool.IsAssembly(label):
        components = TDF_LabelSequence()
        shape_tool.GetComponents(label, components)
        for i in range(components.Length()):
            component = components.Value(i + 1)
            if not shape_tool.IsReference(component):
                continue
            referred = TDF_Label()
            shape_tool.GetReferredShape(component, referred)
            _collect(shape_tool, referred, index, location.Multiplied(shape_tool.GetLocation(component)), depth + 1)
        return
    shape = shape_tool.GetShape(label)
    if shape is None or shape.IsNull():
        return
    leaf_colour = _label_colour(label)
    # a colour can sit on a face, a shell or a SOLID (SolidWorks puts it on each solid of a part: a mirror feature makes two): it covers every face beneath
    covered: list[TopoDS_Shape] = []
    subs = TDF_LabelSequence()
    shape_tool.GetSubShapes(label, subs)
    for i in range(subs.Length()):
        sub = subs.Value(i + 1)
        colour = _label_colour(sub)
        sub_shape = shape_tool.GetShape(sub)
        if colour is None or sub_shape is None or sub_shape.IsNull():
            continue
        face_explorer = TopExp_Explorer(sub_shape, TopAbs_FACE)
        while face_explorer.More():
            face = face_explorer.Current()
            covered.append(face)
            index.add(face.Moved(location), colour)
            face_explorer.Next()
    if leaf_colour is not None:
        explorer = TopExp_Explorer(shape, TopAbs_FACE)
        while explorer.More():
            face = explorer.Current()
            if not any(face.IsSame(c) for c in covered):
                index.add(face.Moved(location), leaf_colour)
            explorer.Next()


def colour_index(source_format: str, data: bytes) -> ColourIndex:
    """The colour index of a STEP / IGES file (empty when the file has no colours or cannot be read by the CAF reader: colours are never a reason to fail an import)."""
    from OCC.Core.TopLoc import TopLoc_Location

    key = hashlib.sha256(source_format.encode() + data).hexdigest()
    cached = _CACHE.get(key)
    if cached is not None:
        return cached
    index = ColourIndex()
    fd, path = tempfile.mkstemp(suffix=".igs" if source_format == "iges" else ".step")
    os.close(fd)
    try:
        with open(path, "wb") as handle:
            handle.write(data)
        reader = IGESCAFControl_Reader() if source_format == "iges" else STEPCAFControl_Reader()
        reader.SetColorMode(True)
        doc = TDocStd_Document("didsa-cad-import-colours")
        if reader.ReadFile(path) == IFSelect_RetDone and reader.Transfer(doc):
            shape_tool = XCAFDoc_DocumentTool.ShapeTool(doc.Main())
            free = TDF_LabelSequence()
            shape_tool.GetFreeShapes(free)
            for i in range(free.Length()):
                _collect(shape_tool, free.Value(i + 1), index, TopLoc_Location())
    except Exception:  # colours are a nicety: a file the CAF reader chokes on still imports, uncoloured
        index = ColourIndex()
    finally:
        os.unlink(path)
    if index.count == 0 and source_format == "iges":
        index.fallback = iges_file_colour(data)
    if len(_CACHE) >= _CACHE_MAX:
        _CACHE.pop(next(iter(_CACHE)))
    _CACHE[key] = index
    return index


def iges_file_colour(data: bytes) -> str | None:
    """The colour most of an IGES file's surfaces / solids point at, read straight from the fixed-format file (Directory entry: the colour field of the second line
    is a negative pointer to a colour definition, entity 314, whose parameters are RGB percentages). OCCT's CAF reader attaches none of these to shapes for some
    exporters (SolidWorks' trimmed-surface files), so this is the fallback: one colour for the whole file, the commonest. None when nothing is coloured."""
    lines = data.decode("ascii", "ignore").splitlines()
    directory = [line for line in lines if len(line) >= 73 and line[72] == "D"]
    parameters: dict[int, str] = {}
    for line in lines:
        if len(line) >= 73 and line[72] == "P":
            try:
                pointer = int(line[64:72])
            except ValueError:
                continue
            parameters[pointer] = parameters.get(pointer, "") + line[:64]
    colours: dict[int, tuple[float, float, float]] = {}
    counts: dict[int, int] = {}
    for first in range(0, len(directory) - 1, 2):
        try:
            entity = int(directory[first][:8])
            colour_field = int(directory[first + 1][16:24])
        except ValueError:
            continue
        sequence = first + 1  # the DE sequence number of the entity's first line
        if entity == 314:
            fields = parameters.get(sequence, "").rstrip().rstrip(";").split(",")
            try:
                colours[sequence] = (float(fields[1]), float(fields[2]), float(fields[3]))
            except (IndexError, ValueError):
                pass
        elif entity in (144, 186, 143, 510, 514, 128, 126) and colour_field < 0:
            counts[-colour_field] = counts.get(-colour_field, 0) + 1
    best = max((n for n in counts if n in colours), key=lambda n: counts[n], default=None)
    if best is None:
        return None
    return "#%02X%02X%02X" % tuple(max(0, min(255, round(c * 2.55))) for c in colours[best])
