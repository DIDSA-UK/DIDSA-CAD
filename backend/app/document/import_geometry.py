"""Resolves an `ImportFeature`'s raw `source_data` bytes into a real OCCT
`TopoDS_Shape` - the OCCT-dependent counterpart to the OCCT-free
`app.document.mesh_import` decoders, mirroring the split every other
Feature module in this codebase already keeps (e.g. `app.document.sweep`
vs. its own pure-Python path-resolution helpers).
"""

import hashlib
import logging
import math
import os
import tempfile
from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder, BRep_Tool
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Sewing
from OCC.Core.IGESControl import IGESControl_Reader
from OCC.Core.Interface import Interface_Static
from OCC.Core.ShapeFix import ShapeFix_Shape, ShapeFix_Solid
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_SHELL, TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopTools import TopTools_IndexedDataMapOfShapeListOfShape
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.TopoDS import TopoDS_Shell, topods
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
        if not shape_has_solid(shape):
            # Some exporters (a Creo surface model: 750 faces, no shell, no solid) write loose faces. They are watertight but unconnected, so they
            # show with arbitrary orientation and have no volume to the boolean operations: sew them into shells and solids, as an IGES import does.
            healed = _heal_to_solid(shape)
            if shape_has_solid(healed):
                return healed
            # Sewing did not close it into solids: keep the file's own faces. (On the owner's 750-face Creo STEP it made 87 open shells, an invalid shape
            # and edge tolerances of 31 mm from a valid, 0.006 mm original.)
        return shape
    finally:
        os.unlink(tmp_path)


def shape_has_solid(shape: TopoDS_Shape) -> bool:
    """Whether `shape` contains at least one real solid (F-3's `solid` flag)."""
    return TopExp_Explorer(shape, TopAbs_SOLID).More()


def _free_edge_count(shape: TopoDS_Shape) -> int:
    """Edges of `shape` that only one face uses (not counting degenerate ones): zero means a closed shell. A seam edge (a sphere's, a cylinder's) is used twice by
    its own face, so it is not free."""
    ancestors = TopTools_IndexedDataMapOfShapeListOfShape()
    topexp.MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, ancestors)
    free = 0
    for index in range(1, ancestors.Extent() + 1):
        edge = topods.Edge(ancestors.FindKey(index))
        if BRep_Tool.Degenerated(edge):
            continue
        if ancestors.FindFromIndex(index).Size() < 2:
            free += 1
    return free


def _bounding_diagonal(shape: TopoDS_Shape) -> float:
    box = Bnd_Box()
    brepbndlib.Add(shape, box)
    if box.IsVoid():
        return 0.0
    xmin, ymin, zmin, xmax, ymax, zmax = box.Get()
    return math.sqrt((xmax - xmin) ** 2 + (ymax - ymin) ** 2 + (zmax - zmin) ** 2)


def _sew(faces: list, tolerance: float) -> list:
    """Shells from `faces` sewn at `tolerance` (a lone face that sewing hands back as a face is wrapped in a shell of its own)."""
    sewing = BRepBuilderAPI_Sewing(tolerance)
    for face in faces:
        sewing.Add(face)
    sewing.Perform()
    sewn = sewing.SewedShape()
    shells = []
    explorer = TopExp_Explorer(sewn, TopAbs_SHELL)
    while explorer.More():
        shells.append(topods.Shell(explorer.Current()))
        explorer.Next()
    # A face that sewed to nothing (a whole sphere or torus is one periodic face) comes back bare, not in a shell: wrap each in a shell of its own, so it is
    # kept and can become a solid. (Faces already inside a shell are skipped by the TopAbs_SHELL avoid-type.)
    builder = BRep_Builder()
    loose = TopExp_Explorer(sewn, TopAbs_FACE, TopAbs_SHELL)
    while loose.More():
        shell = TopoDS_Shell()
        builder.MakeShell(shell)
        builder.Add(shell, topods.Face(loose.Current()))
        shells.append(shell)
        loose.Next()
    return shells


def _heal_to_solid(shape: TopoDS_Shape) -> TopoDS_Shape:
    """IGES from many systems carries surfaces and trimmed faces, not solids. `ShapeFix_Shape` first; then, when there is no solid, sew the faces and - if every
    sewn shell is closed - turn them into real solids, so a closed model gets a volume and works in booleans. Real files have gaps between surfaces, so the
    sewing tolerance climbs a ladder scaled to the model (1e-4 mm, then 1e-5 / 1e-4 / 1e-3 of its bounding diagonal) and stops at the first that closes every
    shell; if none does, the attempt with the fewest free edges stays as an open shell (a Body is still one Body whatever the shape - `extrude.py`)."""
    fixer = ShapeFix_Shape(shape)
    fixer.Perform()
    shape = fixer.Shape()
    if shape_has_solid(shape):
        return shape
    faces = []
    face_explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while face_explorer.More():
        faces.append(topods.Face(face_explorer.Current()))
        face_explorer.Next()
    if not faces:
        return shape
    diagonal = _bounding_diagonal(shape)
    best: tuple[int, list] | None = None
    # Sewing a real file takes tens of seconds a pass (an 859-face SolidWorks export: ~24 s), so the ladder starts at the first rung that can plausibly work:
    # that file needs ~2 microns, and a pass at 1e-4 only to fail cost another 21 s.
    for tolerance in sorted({max(1e-4, diagonal * 1e-5), max(1e-4, diagonal * 1e-4), max(1e-4, diagonal * 1e-3)}):
        shells = _sew(faces, tolerance)
        if not shells:
            continue
        free = sum(_free_edge_count(shell) for shell in shells)
        if best is None or free < best[0]:
            best = (free, shells)
        if free == 0:
            break
    if best is None:
        return shape
    free, shells = best
    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    if free > 0:
        for shell in shells:
            builder.Add(compound, shell)
        return compound
    for shell in shells:
        builder.Add(compound, ShapeFix_Solid().SolidFromShell(shell))
    return compound


_IGES_CACHE: dict[str, TopoDS_Shape] = {}  # sha256 of the file -> its healed shape (a few entries: the probe, the import and every re-mesh read the same file)
_IGES_CACHE_MAX = 3


def _shape_from_iges(data: bytes) -> TopoDS_Shape:
    key = hashlib.sha256(data).hexdigest()
    cached = _IGES_CACHE.get(key)
    if cached is not None:
        return cached
    shape = _shape_from_iges_uncached(data)
    if len(_IGES_CACHE) >= _IGES_CACHE_MAX:
        _IGES_CACHE.pop(next(iter(_IGES_CACHE)))
    _IGES_CACHE[key] = shape
    return shape


def _shape_from_iges_uncached(data: bytes) -> TopoDS_Shape:
    """The IGES twin of `_shape_from_step`: same temp-file idiom (the reader
    only reads a path; suffix `.igs`), same error mapping. The model unit is
    set to millimetres explicitly (the backend's native unit; OCCT converts
    the file's own Global-section unit to it), then `_heal_to_solid`."""
    fd, tmp_path = tempfile.mkstemp(suffix=".igs")
    os.close(fd)
    try:
        with open(tmp_path, "wb") as handle:
            handle.write(data)
        Interface_Static.SetCVal("xstep.cascade.unit", "MM")
        reader = IGESControl_Reader()
        read_status = reader.ReadFile(tmp_path)
        if read_status != IFSelect_RetDone:
            raise _invalid_import_data(f"Could not parse IGES file (status={read_status})")
        transferred_root_count = reader.TransferRoots()
        if transferred_root_count < 1:
            raise _import_failed("IGES file transferred no usable shapes")
        shape = reader.OneShape()
        if shape.IsNull():
            raise _import_failed("IGES file produced an empty shape")
        return _heal_to_solid(shape)
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
    (Part Properties round) via `STEPCAFControl_Reader` - the read side of
    the same AP242/XCAF machinery `app.document.step_export.export_step`
    writes with. Returns `None` on failure (never lets a malformed/unusual
    third-party STEP file's metadata block a successful geometry import) -
    what actually comes back depends entirely on what the *source* CAD
    system chose to populate on its own STEP export; there is no guarantee
    any given field is present, even for a well-formed AP242 file.

    Verified against a real `pythonocc-core==7.9.3` install, not just code
    review - two corrections from the first draft, both confirmed by hand:
    1. Document creation mirrors `app.document.step_export._new_xcaf_
       document`'s own fix - `TDocStd_Document("...")` alone, no
       `XCAFApp_Application` (that idiom is a hard process abort in this
       build, which no amount of try/except can catch - a process abort
       isn't a Python exception at all, so getting the OCCT calls
       themselves right is the only real fix, not defensive wrapping).
    2. `TDF_Label.FindAttribute` with a plain `(GUID, attr)` pair - the
       naive/textbook call - doesn't match this binding's expected
       argument shape and raises (a catchable `TypeError`, unlike (1));
       `TDF_Label.GetLabelName()` is pythonocc-core's own simpler
       convenience wrapper for the same thing and is used instead.
       Likewise `XCAFDoc_MaterialTool.GetMaterial(shapeLabel)` - passing a
       *shape's* label where the binding actually expects a *material's*
       own label - segfaults; `GetDensityForShape(shapeLabel)` is the
       binding's own correct shape-oriented accessor (confirmed to already
       return density in g/cm^3, matching this app's own convention,
       regardless of what unit string the source file's material was
       declared in - OCCT's own Units library normalizes it), and a
       material's *name* has no equivalent single-call accessor, so it's
       recovered by scanning `GetMaterialLabels()` (see below).
    """
    fd, tmp_path = tempfile.mkstemp(suffix=".step")
    os.close(fd)
    try:
        with open(tmp_path, "wb") as handle:
            handle.write(data)

        from OCC.Core.STEPCAFControl import STEPCAFControl_Reader
        from OCC.Core.TDF import TDF_LabelSequence
        from OCC.Core.TDocStd import TDocStd_Document
        from OCC.Core.XCAFDoc import XCAFDoc_DocumentTool

        doc = TDocStd_Document("didsa-cad-step-import")

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

        name = label.GetLabelName() or None

        material: MaterialAssignment | None = None
        density_g_cm3 = material_tool.GetDensityForShape(label)
        if density_g_cm3 > 0:
            # No single-call "material name for this shape" accessor exists
            # on this binding (see this function's own docstring) - the
            # common case is exactly one material defined in the whole
            # document, so name that one; with several, there's no reliable
            # way to tell which belongs to this shape from density alone
            # (two materials can share a density), so fall back to a
            # density-only label rather than guessing wrong.
            material_labels = TDF_LabelSequence()
            material_tool.GetMaterialLabels(material_labels)
            material_name = f"Imported ({density_g_cm3:g} g/cm3)"
            if material_labels.Length() == 1:
                got = material_tool.GetMaterial(material_labels.Value(1))
                if isinstance(got, (list, tuple)) and len(got) >= 2 and got[0]:
                    material_name = str(got[1])
            material = MaterialAssignment(
                material_id=f"imported:{material_name}",
                name=material_name,
                density_g_cm3=density_g_cm3,
            )

        if name is None and material is None:
            return None
        return StepImportMetadata(name=name, material=material)
    except Exception:  # noqa: BLE001 - a genuinely unfamiliar third-party file's
        # structure could still raise somewhere in this reading path even with
        # every call above confirmed against a real install - never let that
        # block a successful geometry import, which is all this metadata is
        # supplementary to.
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
    if feature.source_format == ImportSourceFormat.IGES:
        return _shape_from_iges(feature.source_data)

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
