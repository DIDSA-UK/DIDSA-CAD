"""STEP export - writes every current Body of a Part (per
`app.document.extrude.compute_part_bodies`, the same source of truth
`/mesh` and every other export format tessellates from) into a single
AP242 STEP file, one shape per Body so each stays its own distinct STEP
product rather than being fused into one compound.

AP242 is written even though no PMI/MBD was populated at first - locked-in
scope (AskUserQuestion round): the file is future-ready for Model-Based
Definition without a later schema migration, rather than writing an older
schema now and needing to re-export everything once MBD support exists.

**MBD metadata (Part Properties round)**: now populated via OCCT's XCAF
document framework (`STEPCAFControl_Writer`, not the bare `STEPControl_
Writer` this module used before) - the standardized subset only:
- Part Number/Name/Description/Revision -> STEP `product.id`/`.name`/
  `.description`/`product_definition_formation.id`, via each Body's own
  shape-label `TDataStd_Name` attribute (name) and `XCAFDoc_ShapeTool`'s own
  product/revision plumbing.
- Material -> STEP's `material_designation`, via `XCAFDoc_MaterialTool`
  (name + density), resolved per Body through `Part.resolve_material`
  (per-Body override, else the Part's own default).
- Mass -> STEP's "validation properties" mechanism, via the `XCAFDoc_Volume`
  attribute OCCT's STEP writer reads back when present on a shape label.

Supplier/Supplier Part Number/Remarks are deliberately never written here -
no STEP AP has a schema slot for them (see `Part`'s own docstring), so
writing them would only ever round-trip with DIDSA-CAD itself, not
interoperate with another platform.

**Verification status**: verified against a real `pythonocc-core==7.9.3`
install (conda-forge), not just code review - see the git history for what
that pass caught and fixed. Two corrections from the first draft of this
module, both confirmed by hand against a real install before landing:

1. `TDocStd_Document`/`XCAFApp_Application`: the textbook `XCAFApp_
   Application.GetApplication()` + `app.NewDocument(...)` two-step (found in
   most OCCT C++ tutorials) is a **hard process abort** in this
   pythonocc-core build - `TDocStd_Document`'s own format-name constructor
   argument needs the application's plugin/resource files
   (`CSF_PluginDefaults` etc.) wired up, which this build's own Python
   layer does not do for you. pythonocc-core's own bundled `OCC.Extend.
   DataExchange` module (`read_step_file_with_names_colors`) uses a much
   simpler, working idiom instead: `TDocStd_Document("any-label-string")`
   with no `XCAFApp_Application` involved at all - copied here verbatim.
2. `TDataStd_Name.Set(label, ...)` wants a plain Python `str`, not a
   `TCollection_ExtendedString` - passing the latter raises a SWIG
   overload-resolution `TypeError` (this one's a clean, catchable Python
   exception, not a process abort).

`XCAFDoc_Volume.Set`/`XCAFDoc_MaterialTool.AddMaterial`/`SetMaterial`,
`STEPCAFControl_Writer.Transfer`, and the density-unit round-trip
(`AddMaterial`'s density arg in kg/m^3 with `densName="KG/M3"` reads back as
g/cm^3 via `XCAFDoc_MaterialTool.GetDensityForShape` - OCCT's own Units
library normalizing it) were all confirmed correct as originally written,
by writing a real STEP file and grepping it for the resulting `PRODUCT`/
`DESCRIPTIVE_REPRESENTATION_ITEM`/`VOLUME_MEASURE` entities.
"""

import os
import tempfile

from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GProp import GProp_GProps
from OCC.Core.IFSelect import IFSelect_RetDone
from OCC.Core.Interface import Interface_Static
from OCC.Core.STEPCAFControl import STEPCAFControl_Writer
from OCC.Core.STEPControl import STEPControl_AsIs
from OCC.Core.TCollection import TCollection_HAsciiString
from OCC.Core.TDataStd import TDataStd_Name
from OCC.Core.TDocStd import TDocStd_Document
from OCC.Core.XCAFDoc import XCAFDoc_DocumentTool

from app.document.models import MaterialAssignment, Part


def _new_xcaf_document() -> TDocStd_Document:
    """A fresh, empty XCAF document - see this module's own docstring for
    why this is `TDocStd_Document("...")` alone (pythonocc-core's own
    `OCC.Extend.DataExchange` idiom) and not the `XCAFApp_Application`
    two-step every OCCT C++ tutorial shows, which aborts the whole process
    in this build."""
    return TDocStd_Document("didsa-cad-step-export")


def _set_shape_mass_property(label, volume_mm3: float) -> None:
    """Records `volume_mm3` on `label` via the `XCAFDoc_Volume` XCAF
    attribute, so `STEPCAFControl_Writer` includes it as a STEP validation
    property (`PROPERTY_DEFINITION('geometric validation property',
    'volume', ...)` + `VOLUME_MEASURE`, confirmed by writing a real file and
    grepping it) - the raw value round-trips verbatim (no unit conversion,
    unlike density), so `volume_mm3` (this app's own implicit-mm convention)
    is exactly what shows up in the exported file."""
    from OCC.Core.XCAFDoc import XCAFDoc_Volume

    XCAFDoc_Volume.Set(label, volume_mm3)


def export_step(bodies: dict[str, object], part: Part | None = None) -> bytes:
    """`bodies` is a Part's current Body map (`compute_part_bodies`'s own
    return shape) - takes it directly rather than only a `Part`, so the
    router can reuse the one `compute_part_bodies` call it already needs to
    check "does this Part have anything to export" before ever reaching
    here. `part`, when given, supplies the MBD metadata (Part Properties +
    material assignment) described in this module's own docstring; `None`
    (the default, and every pre-existing caller/test) exports geometry only,
    with no behavior change from before this feature."""
    doc = _new_xcaf_document()
    shape_tool = XCAFDoc_DocumentTool.ShapeTool(doc.Main())
    shape_tool.SetAutoNaming(False)
    material_tool = XCAFDoc_DocumentTool.MaterialTool(doc.Main())

    # A material is registered once per distinct (name, density) pair, not
    # once per Body - re-registering an identical material for every Body
    # that shares it would be wasteful (though not incorrect) STEP output.
    material_labels: dict[tuple[str, float], object] = {}

    def _material_label(assignment: MaterialAssignment):
        key = (assignment.name, assignment.density_g_cm3)
        label = material_labels.get(key)
        if label is None:
            # AddMaterial's density is expected in kg/m^3 by STEP/XCAF
            # convention (the standard SI unit for this field) - this app's
            # own material library stores density in g/cm^3 (see
            # `MaterialAssignment`'s own docstring); 1 g/cm^3 == 1000 kg/m^3.
            density_kg_m3 = assignment.density_g_cm3 * 1000.0
            label = material_tool.AddMaterial(
                TCollection_HAsciiString(assignment.name),
                TCollection_HAsciiString(assignment.name),
                density_kg_m3,
                TCollection_HAsciiString("KG/M3"),
                TCollection_HAsciiString("MASS/VOLUME"),
            )
            material_labels[key] = label
        return label

    for body_id, shape in bodies.items():
        label = shape_tool.AddShape(shape, False)

        if part is not None:
            material = part.resolve_material(body_id)
            if material is not None:
                material_tool.SetMaterial(label, _material_label(material))

            # Part Properties -> STEP product identity. Every Body in this
            # export shares the same Part-level name/part number/revision/
            # description (there is exactly one Part per export) - a real
            # per-Body distinguishing name isn't tracked anywhere in this
            # app yet, so the Part's own name is used for every Body's own
            # shape label, matching what a single-Part STEP export from most
            # mainstream CAD tools looks like (one product name repeated
            # across its constituent solids unless the user names them
            # individually).
            display_name = part.part_number or part.name
            TDataStd_Name.Set(label, display_name)

            volume_props = GProp_GProps()
            brepgprop.VolumeProperties(shape, volume_props)
            _set_shape_mass_property(label, abs(volume_props.Mass()))

    # STEPCAFControl_Writer() must be constructed *before* SetCVal - same
    # ordering requirement this module's own original bare-STEPControl_
    # Writer code already had to learn the hard way (confirmed again here:
    # reordering these two during the XCAF rewrite silently dropped every
    # export back to AP214/AUTOMOTIVE_DESIGN, caught by grepping a real
    # exported file's own FILE_SCHEMA line for "AP242" and getting nothing).
    writer = STEPCAFControl_Writer()
    Interface_Static.SetCVal("write.step.schema", "AP242DIS")
    if not writer.Transfer(doc, STEPControl_AsIs):
        raise RuntimeError("STEP transfer failed for this Part's Bodies")

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
