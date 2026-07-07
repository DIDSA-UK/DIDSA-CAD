"""Resolves an `ImportFeature`'s raw `source_data` bytes into a real OCCT
`TopoDS_Shape` - the OCCT-dependent counterpart to the OCCT-free
`app.document.mesh_import` decoders, mirroring the split every other
Feature module in this codebase already keeps (e.g. `app.document.sweep`
vs. its own pure-Python path-resolution helpers).
"""

import os
import tempfile

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.gp import gp_Pnt
from OCC.Core.IFSelect import IFSelect_RetDone
from OCC.Core.Poly import Poly_Triangle, Poly_Triangulation
from OCC.Core.STEPControl import STEPControl_Reader
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Face, TopoDS_Shape

from app.document.mesh_data import MeshData
from app.document.mesh_import import MeshImportError, decode_glb, decode_obj, decode_stl
from app.document.models import ImportFeature, ImportSourceFormat


def _import_failed(detail: str) -> HTTPException:
    """A structurally-valid file that OCCT nonetheless couldn't turn into
    usable geometry - mirrors `app.document.sweep._sweep_failed`'s own
    "resolvable reference, unresolvable geometry" distinction."""
    return HTTPException(status_code=422, detail={"type": "import_failed", "detail": detail})


def _invalid_import_data(detail: str) -> HTTPException:
    """The uploaded bytes themselves are malformed/unparseable for the
    declared `source_format` - mirrors `app.document.native_format`'s own
    "client-supplied-file problem" 422 convention."""
    return HTTPException(status_code=422, detail={"type": "invalid_import_data", "detail": detail})


def _shape_from_step(data: bytes) -> TopoDS_Shape:
    """pythonocc-core's STEP reader only reads from a real file path, not
    an in-memory buffer - round-trips through a temp file, the read-side
    mirror of `app.document.step_export.export_step`'s own write-side
    temp-file pattern."""
    fd, tmp_path = tempfile.mkstemp(suffix=".step")
    os.close(fd)
    try:
        with open(tmp_path, "wb") as handle:
            handle.write(data)
        reader = STEPControl_Reader()
        read_status = reader.ReadFile(tmp_path)
        if read_status != IFSelect_RetDone:
            raise _invalid_import_data(f"Could not parse STEP file (status={read_status})")
        transferred_root_count = reader.TransferRoots()
        if transferred_root_count < 1:
            raise _import_failed("STEP file transferred no usable shapes")
        shape = reader.OneShape()
        if shape.IsNull():
            raise _import_failed("STEP file produced an empty shape")
        return shape
    finally:
        os.unlink(tmp_path)


def _shape_from_mesh_data(mesh: MeshData) -> TopoDS_Shape:
    """The same surface-less, triangulation-only `TopoDS_Face` convention
    OCCT's own STL import uses: a single face carrying nothing but a
    `Poly_Triangulation`, no underlying `Geom_Surface`. `tessellate_shape`
    (see `app.document.mesh`) already reads a face's triangulation directly
    when one is present, so this needs no separate meshing step, and OCCT's
    own `BRepMesh_IncrementalMesh` safely skips a face that already carries
    one. Sufficient for the requested "view, measure, model around" use
    case; not a substitute for a real, watertight B-rep solid - see
    `ImportFeature`'s own docstring for the Boolean-op limitation this
    implies."""
    if not mesh.vertices:
        raise _import_failed("Mesh file has no geometry to import")

    triangulation = Poly_Triangulation(len(mesh.vertices), len(mesh.triangles), False)
    for i, (x, y, z) in enumerate(mesh.vertices, start=1):
        triangulation.SetNode(i, gp_Pnt(x, y, z))
    for i, triangle in enumerate(mesh.triangles, start=1):
        triangulation.SetTriangle(i, Poly_Triangle(triangle.a + 1, triangle.b + 1, triangle.c + 1))

    face = TopoDS_Face()
    builder = BRep_Builder()
    builder.MakeFace(face)
    builder.UpdateFace(face, triangulation)

    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    builder.Add(compound, face)
    return compound


def resolve_import(feature: ImportFeature) -> TopoDS_Shape:
    """Dispatches on `feature.source_format` - a real B-rep solid for STEP,
    or a triangulation-only reference shape (see `_shape_from_mesh_data`)
    for STL/OBJ/glTF, decoded first via the matching OCCT-free
    `app.document.mesh_import` function."""
    if feature.source_format == ImportSourceFormat.STEP:
        return _shape_from_step(feature.source_data)

    try:
        if feature.source_format == ImportSourceFormat.STL:
            mesh = decode_stl(feature.source_data)
        elif feature.source_format == ImportSourceFormat.OBJ:
            mesh = decode_obj(feature.source_data.decode("utf-8"))
        else:
            assert feature.source_format == ImportSourceFormat.GLTF
            mesh = decode_glb(feature.source_data)
    except (MeshImportError, UnicodeDecodeError) as exc:
        raise _invalid_import_data(str(exc)) from exc

    return _shape_from_mesh_data(mesh)
