"""Shared low-level OCCT surface-stitching primitive - used by both
KnitSurfaceFeature (stops here) and SolidFromSurfacesFeature (continues
to ShapeFix_Shell/MakeSolid/OrientClosedSolid) - kept in a neutral shared
module rather than one Feature module importing another's internals,
matching this codebase's existing pattern of shared primitives living in
app.document.extrude, never cross-imported between sibling Feature
modules."""

from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Sewing
from OCC.Core.TopoDS import TopoDS_Shape


def sew_surfaces(shapes: list[TopoDS_Shape], tolerance: float = 1e-4) -> TopoDS_Shape:
    """Raw BRepBuilderAPI_Sewing result - no ShapeFix/MakeSolid. Tolerance
    1e-4 matches app.document.bevel's own proven gear-tooth-assembly
    sewing constant (cited as precedent, not imported - that module's own
    sewing call is a private implementation detail of a gear-specific
    routine, not a shared utility)."""
    sewing = BRepBuilderAPI_Sewing(tolerance)
    for shape in shapes:
        sewing.Add(shape)
    sewing.Perform()
    return sewing.SewedShape()
