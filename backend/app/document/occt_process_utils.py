"""Shared `ProcessPoolExecutor` IPC helpers for OCCT geometry construction -
promoted out of `app.document.bevel_pair` (its original, sole owner) so
`app.document.planetary_gear`'s own new pooling (LOD Phase 2 chunk 1) can
reuse the identical BREP-bytes round-trip rather than duplicating it. A pure
extraction - no behavior change from `bevel_pair.py`'s own original
`_shape_to_brep_bytes`/`_shape_from_brep_bytes`.

A `TopoDS_Shape` (a SWIG-wrapped C++ object) is not picklable, so it cannot
cross a `ProcessPoolExecutor` worker boundary directly - every module here
that parallelizes real OCCT construction across worker processes needs the
same real-BREP-file round-trip to move a finished solid back to the main
process."""

import os
import tempfile

from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepTools import breptools
from OCC.Core.TopoDS import TopoDS_Shape


def shape_to_brep_bytes(shape: TopoDS_Shape) -> bytes:
    """Round-trips `shape` through a real BREP file (`breptools.Write` has
    no in-memory/string overload confirmed available - a real temp file is
    the one guaranteed-available serialization path) - the only way to move
    a `TopoDS_Shape` across a `ProcessPoolExecutor` worker boundary. A
    modest gear solid's own BREP text is small (tens to low hundreds of KB)
    and local disk I/O on this app's own Pi 5 target hardware is far
    cheaper than the minutes-scale OCCT construction this is unblocking, so
    the extra round-trip cost here is not the bottleneck this workstream is
    chasing."""
    fd, path = tempfile.mkstemp(suffix=".brep")
    os.close(fd)
    try:
        breptools.Write(shape, path)
        with open(path, "rb") as f:
            return f.read()
    finally:
        os.unlink(path)


def shape_from_brep_bytes(data: bytes) -> TopoDS_Shape:
    """Inverse of `shape_to_brep_bytes` - the receiving process's own half
    of the round-trip, reconstructing a real `TopoDS_Shape` from a worker
    process's finished solid (or vice versa, for anything sent into a
    worker via an `initializer`)."""
    fd, path = tempfile.mkstemp(suffix=".brep")
    os.close(fd)
    try:
        with open(path, "wb") as f:
            f.write(data)
        shape = TopoDS_Shape()
        builder = BRep_Builder()
        breptools.Read(shape, path, builder)
        return shape
    finally:
        os.unlink(path)
