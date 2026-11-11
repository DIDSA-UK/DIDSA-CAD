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
- **Colours are not written yet** (the plan's "plain writer first, colour
  second"): `IGESCAFControl_Writer` with an XCAF document, like `export_step`,
  is the follow-up.
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

IGES_FACES_MODE = 0
IGES_BREP_MODE = 1
IGES_UNIT = "MM"  # the backend's native unit


def export_iges(bodies: dict[str, object], mode: int = IGES_BREP_MODE) -> bytes:
    """`bodies` is a Part's current Body map (`compute_part_bodies`'s return
    shape); one shape is added per Body. Returns the IGES file's bytes."""
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
