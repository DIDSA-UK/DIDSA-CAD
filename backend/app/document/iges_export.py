"""IGES export (F-3, `docs/iges-jt-and-desktop-input-plan-2026-11-11.md`): writes
every current Body of a Part (`compute_part_bodies`' own map, the same one STEP
and the meshes come from) into one IGES file - the simpler cousin of
`app.document.step_export.export_step`.

What an IGES file can and cannot carry:

- **Geometry only.** IGES has no slot for material, mass, supplier fields or
  product structure, so none of the STEP export's metadata is written (same
  rule as that module's supplier fields: nothing is written that would only
  round-trip with DIDSA-CAD itself). The assembly endpoint therefore *flattens*
  to world-placed Bodies exactly like the assembly STEP one - an IGES file has
  no assembly structure.
- **Colours** are written when the caller gives each Body's resolved look (`appearances`, as `export_step` takes them): through an XCAF document and
  `IGESCAFControl_Writer`, the Body's colour on its label and any differing face colours (`step_export._set_body_colours`). IGES carries colour on the
  entities, so a reader gets it back on the faces. Without looks the plain writer is used. IGES has no slot for opacity or names here.
- **Entity type** is `IGES_BREP_MODE` (the writer's mode 1: B-rep solids, type
  186, which is what most importers want for solids) unless a caller passes
  `IGES_FACES_MODE` (mode 0: trimmed surfaces, type 144). Both are module
  constants so they can be tested against the viewer in use.

Like the STEP writer, OCCT's IGES writer only writes to a file path, so this
round-trips through a temp file and returns the bytes.
"""

import os
import tempfile

from OCC.Core.IGESControl import IGESControl_Writer
from OCC.Core.Interface import Interface_Static

IGES_FACES_MODE = 0
IGES_BREP_MODE = 1
IGES_UNIT = "MM"  # the backend's native unit


def export_iges(bodies: dict[str, object], mode: int = IGES_BREP_MODE, appearances: dict | None = None) -> bytes:
    """`bodies` is a Part's current Body map (`compute_part_bodies`'s return
    shape); one shape is added per Body. `appearances` (Body key -> `BodyLook`,
    see `step_export`) adds colours. Returns the IGES file's bytes."""
    if appearances and any(appearances.get(key) is not None for key in bodies):
        return _export_coloured(bodies, appearances)
    writer = IGESControl_Writer(IGES_UNIT, mode)
    for shape in bodies.values():
        writer.AddShape(shape)
    writer.ComputeModel()
    fd, tmp_path = tempfile.mkstemp(suffix=".igs")
    os.close(fd)
    try:
        writer.Write(tmp_path)
        with open(tmp_path, "rb") as handle:
            return handle.read()
    finally:
        os.unlink(tmp_path)


def _export_coloured(bodies: dict[str, object], appearances: dict) -> bytes:
    from OCC.Core.IGESCAFControl import IGESCAFControl_Writer
    from OCC.Core.XCAFDoc import XCAFDoc_DocumentTool

    from app.document.step_export import _new_xcaf_document, _set_body_colours

    doc = _new_xcaf_document()
    shape_tool = XCAFDoc_DocumentTool.ShapeTool(doc.Main())
    colour_tool = XCAFDoc_DocumentTool.ColorTool(doc.Main())
    for key, shape in bodies.items():
        label = shape_tool.AddShape(shape, False)
        look = appearances.get(key)
        if look is not None:
            _set_body_colours(shape_tool, colour_tool, label, shape, look)
    # The CAF writer takes its entity type from the global static, not from a constructor argument: without this it writes trimmed SURFACES (type 144), which
    # another application (FreeCAD) reads as loose faces with no solid. B-rep solids (type 186) are what the plain writer's default mode gives.
    Interface_Static.SetIVal("write.iges.brep.mode", IGES_BREP_MODE)
    Interface_Static.SetCVal("write.iges.unit", IGES_UNIT)
    writer = IGESCAFControl_Writer()
    writer.SetColorMode(True)
    if not writer.Transfer(doc):
        raise RuntimeError("OCCT could not transfer the model to IGES")
    fd, tmp_path = tempfile.mkstemp(suffix=".igs")
    os.close(fd)
    try:
        writer.Write(tmp_path)
        with open(tmp_path, "rb") as handle:
            return handle.read()
    finally:
        os.unlink(tmp_path)
