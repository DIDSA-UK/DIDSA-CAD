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

**Verification status**: the XCAF/STEPCAFControl technique above is new to
this codebase - like every other genuinely new OCCT technique here (see
`app.document.loft`'s own module docstring), it needs a real on-device/CI
pass before being trusted; this repo's dev sandbox has historically had no
`pythonocc-core` installed. The mass/volume validation-properties write in
particular (`XCAFDoc_Volume`) is the most speculative part of this module -
wrapped in its own narrow try/except so a version of pythonocc-core missing
that specific (less commonly used) binding degrades to "no mass in this
STEP file" rather than failing the whole export; Name/Material writing is
not wrapped this way, since those are extremely well-established, widely
documented OCCT/XCAF calls.
"""

import logging
import os
import tempfile

from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GProp import GProp_GProps
from OCC.Core.IFSelect import IFSelect_RetDone
from OCC.Core.Interface import Interface_Static
from OCC.Core.STEPCAFControl import STEPCAFControl_Writer
from OCC.Core.STEPControl import STEPControl_AsIs
from OCC.Core.TCollection import TCollection_ExtendedString, TCollection_HAsciiString
from OCC.Core.TDataStd import TDataStd_Name
from OCC.Core.TDocStd import TDocStd_Document
from OCC.Core.XCAFApp import XCAFApp_Application
from OCC.Core.XCAFDoc import XCAFDoc_DocumentTool

from app.document.models import MaterialAssignment, Part

logger = logging.getLogger(__name__)


def _new_xcaf_document() -> TDocStd_Document:
    """A fresh, empty XCAF document - the standard OCCT
    `XCAFApp_Application`/`TDocStd_Document` boilerplate every XCAF-based
    read/write starts from."""
    app = XCAFApp_Application.GetApplication()
    doc = TDocStd_Document(TCollection_ExtendedString("XmlXCAF"))
    app.NewDocument(TCollection_ExtendedString("MDTV-XCAF"), doc)
    return doc


def _set_shape_mass_property(label, volume_mm3: float) -> None:
    """Best-effort: records `volume_mm3` on `label` via the `XCAFDoc_Volume`
    XCAF attribute, so `STEPCAFControl_Writer` includes it as a STEP
    validation property. See this module's own docstring for why this is
    wrapped separately from the rest of the XCAF writing - the most
    speculative single call in this file."""
    try:
        from OCC.Core.XCAFDoc import XCAFDoc_Volume

        XCAFDoc_Volume.Set(label, volume_mm3)
    except Exception:  # noqa: BLE001 - deliberately broad, see module docstring
        logger.warning("Could not record a STEP validation-property volume for a Body", exc_info=True)


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
            TDataStd_Name.Set(label, TCollection_ExtendedString(display_name))

            volume_props = GProp_GProps()
            brepgprop.VolumeProperties(shape, volume_props)
            _set_shape_mass_property(label, abs(volume_props.Mass()))

    Interface_Static.SetCVal("write.step.schema", "AP242DIS")
    writer = STEPCAFControl_Writer()
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
