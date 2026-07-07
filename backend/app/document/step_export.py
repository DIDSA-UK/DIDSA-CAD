"""STEP export - writes every current Body of a Part (per
`app.document.extrude.compute_part_bodies`, the same source of truth
`/mesh` and every other export format tessellates from) into a single
AP242 STEP file, one `Transfer` per Body so each stays its own distinct
STEP product rather than being fused into one compound.

AP242 is written even though no PMI/MBD is populated yet - locked-in scope
(AskUserQuestion round): the file is future-ready for Model-Based
Definition without a later schema migration, rather than writing an older
schema now and needing to re-export everything once MBD support exists.
"""

import os
import tempfile

from OCC.Core.IFSelect import IFSelect_RetDone
from OCC.Core.Interface import Interface_Static
from OCC.Core.STEPControl import STEPControl_AsIs, STEPControl_Writer


def export_step(bodies: dict[str, object]) -> bytes:
    """`bodies` is a Part's current Body map (`compute_part_bodies`'s own
    return shape) - takes it directly rather than a `Part`, so the router
    can reuse the one `compute_part_bodies` call it already needs to check
    "does this Part have anything to export" before ever reaching here."""
    # STEPControl_Writer() must be constructed *before* SetCVal - it's the
    # writer's own controller init that registers "write.step.schema" into
    # OCCT's static-parameter table in the first place; setting it any
    # earlier is a silent no-op and the writer falls back to its default
    # schema (AP214) rather than raising, which is exactly the bug this
    # comment is guarding against (caught by CI: the exported file's own
    # FILE_SCHEMA said AUTOMOTIVE_DESIGN/AP214, not AP242, despite this same
    # call appearing to run without error).
    writer = STEPControl_Writer()
    Interface_Static.SetCVal("write.step.schema", "AP242DIS")
    for shape in bodies.values():
        status = writer.Transfer(shape, STEPControl_AsIs)
        if status != IFSelect_RetDone:
            raise RuntimeError(f"STEP transfer failed for a Body (status={status})")

    # pythonocc-core's STEP writer only writes to a real file path, not an
    # in-memory buffer - round-trip through a temp file, same pattern as
    # every other "OCCT writer wants a path" integration in this codebase.
    fd, tmp_path = tempfile.mkstemp(suffix=".step")
    os.close(fd)
    try:
        status = writer.Write(tmp_path)
        if status != IFSelect_RetDone:
            raise RuntimeError(f"STEP write failed (status={status})")
        with open(tmp_path, "rb") as handle:
            return handle.read()
    finally:
        os.unlink(tmp_path)
