"""Resolves an `ImportFeature`'s raw `source_data` bytes into a real OCCT
`TopoDS_Shape` - the OCCT-dependent counterpart to the OCCT-free
`app.document.mesh_import` decoders, mirroring the split every other
Feature module in this codebase already keeps (e.g. `app.document.sweep`
vs. its own pure-Python path-resolution helpers).
"""

import logging
import os
import tempfile
from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.gp import gp_Pnt
from OCC.Core.IFSelect import IFSelect_RetDone
from OCC.Core.Poly import Poly_Triangle, Poly_Triangulation
from OCC.Core.STEPControl import STEPControl_Reader
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Face, TopoDS_Shape

from app.document.mesh_data import MeshData
from app.document.mesh_import import MeshImportError, decode_gltf, decode_obj, decode_stl
from app.document.models import ImportFeature, ImportSourceFormat, MaterialAssignment

logger = logging.getLogger(__name__)


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


@dataclass
class StepImportMetadata:
    """Whatever MBD metadata (Part Properties round) a STEP file imported
    from another CAD platform happened to carry - every field is `None`/
    absent when the source file (or the exporting CAD system) simply didn't
    populate it, which is common (mass export in particular is usually
    opt-in in most CAD tools' own STEP export dialog). Never treated as
    guaranteed-present - see `extract_step_metadata`'s own docstring."""

    name: str | None = None
    material: MaterialAssignment | None = None


def extract_step_metadata(data: bytes) -> StepImportMetadata | None:
    """Best-effort read of a STEP file's own XCAF product name/material
    (Part Properties round) via `STEPCAFControl_Reader` - a genuinely new
    OCCT technique to this codebase, on the read side of the same AP242/XCAF
    machinery `app.document.step_export.export_step` now writes with.
    Returns `None` (never raises) on any failure - this is supplementary,
    nice-to-have metadata for pre-filling this app's own Part Properties/
    material-assignment UI after an import, never something a successful
    geometry import should be blocked by. What actually comes back depends
    entirely on what the *source* CAD system chose to populate on its own
    STEP export - there is no guarantee any given field is present, even for
    a well-formed AP242 file.

    Deliberately wrapped in one broad try/except for the whole function
    (unlike `app.document.step_export`'s narrower per-call wrapping) - unlike
    export, which controls exactly what it asks OCCT to write, this is
    reading arbitrary third-party STEP files through a corner of the
    pythonocc-core binding surface this codebase has not exercised before,
    so any of several unfamiliar calls could plausibly raise on a given
    pythonocc-core version or a given file's own structure."""
    fd, tmp_path = tempfile.mkstemp(suffix=".step")
    os.close(fd)
    try:
        with open(tmp_path, "wb") as handle:
            handle.write(data)

        from OCC.Core.STEPCAFControl import STEPCAFControl_Reader
        from OCC.Core.TCollection import TCollection_ExtendedString
        from OCC.Core.TDataStd import TDataStd_Name
        from OCC.Core.TDF import TDF_LabelSequence
        from OCC.Core.TDocStd import TDocStd_Document
        from OCC.Core.XCAFApp import XCAFApp_Application
        from OCC.Core.XCAFDoc import XCAFDoc_DocumentTool

        app = XCAFApp_Application.GetApplication()
        doc = TDocStd_Document(TCollection_ExtendedString("XmlXCAF"))
        app.NewDocument(TCollection_ExtendedString("MDTV-XCAF"), doc)

        reader = STEPCAFControl_Reader()
        reader.SetNameMode(True)
        reader.SetMatMode(True)
        if reader.ReadFile(tmp_path) != IFSelect_RetDone:
            return None
        if not reader.Transfer(doc):
            return None

        shape_tool = XCAFDoc_DocumentTool.ShapeTool(doc.Main())
        material_tool = XCAFDoc_DocumentTool.MaterialTool(doc.Main())

        free_shapes = TDF_LabelSequence()
        shape_tool.GetFreeShapes(free_shapes)
        if free_shapes.Length() < 1:
            return None
        label = free_shapes.Value(1)

        name: str | None = None
        name_attr = TDataStd_Name()
        if label.FindAttribute(TDataStd_Name.GetID(), name_attr):
            name = name_attr.Get().ToExtString()

        material: MaterialAssignment | None = None
        material_label = material_tool.GetMaterial(label)
        if material_label is not None and not material_label.IsNull():
            got = material_tool.GetMaterial(material_label)
            # pythonocc-core wraps a C++ bool-returning, reference-out-param
            # method as a Python tuple `(ok, name, description, density,
            # dens_name, dens_val_type)` - unpack defensively rather than
            # assuming this exact shape, since this specific binding is the
            # least-exercised call in this file.
            if isinstance(got, tuple) and len(got) >= 4 and got[0]:
                material_name = str(got[1])
                density_kg_m3 = float(got[3])
                material = MaterialAssignment(
                    material_id=f"imported:{material_name}",
                    name=material_name,
                    density_g_cm3=density_kg_m3 / 1000.0,
                )

        if name is None and material is None:
            return None
        return StepImportMetadata(name=name, material=material)
    except Exception:  # noqa: BLE001 - deliberately broad, see docstring
        logger.warning("Could not extract STEP MBD metadata from an imported file", exc_info=True)
        return None
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
            mesh = decode_gltf(feature.source_data)
    except (MeshImportError, UnicodeDecodeError) as exc:
        raise _invalid_import_data(str(exc)) from exc

    return _shape_from_mesh_data(mesh)
