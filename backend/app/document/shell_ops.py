"""Shared OCCT shell-thickening plumbing - extracted out of
`app.document.loft` so `app.document.extrude`'s own thin-wall extrude can
reuse the identical primitive without a circular import (`loft.py` already
imports from `extrude.py` at module level, so `extrude.py` importing back
from `loft.py` would cycle). Nothing in this module is Loft-specific - it is
generic "thicken an open shell into a solid" OCCT plumbing that any Feature
producing an open shell may need.

**Verification status**: same caution as everywhere else this idiom is used
in this project - verified so far only by code review (this repo's dev
sandbox has never had `pythonocc-core` installed). See `app.document.loft`'s
own module docstring for the fuller history of this technique.
"""

from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakeThickSolid
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopoDS import TopoDS_Shape


def thicken_shell_to_solid(shell: TopoDS_Shape, thickness: float) -> TopoDS_Shape:
    """Thickens an open shell into a solid via OCCT's standard
    BRepOffsetAPI_MakeThickSolid idiom, including the volume-sign fixup
    a real on-device/CI run found necessary: MakeThickSolidBySimple's own
    output solid can come back with inverted (inward-pointing) face
    orientation depending on the input shell's own winding -
    BRepGProp's volume integral is signed by face orientation, so this
    surfaces as a *negative* Mass() for an otherwise perfectly valid solid
    (confirmed via a real 10x8x1 thin loft: OCCT returned -80.0, not 80.0).
    `.Reversed()` flips every face's orientation (and, transitively, the
    sign BRepGProp reports) without changing the solid's actual shape at
    all - the standard OCCT fix for exactly this, applied unconditionally
    based on a real volume check rather than assumed to always be needed
    (a shell that happens to come out right-side-up already has this be a
    no-op check, not a blind flip). Raises `ValueError` if the thicken
    operation itself does not complete."""
    thicken = BRepOffsetAPI_MakeThickSolid()
    thicken.MakeThickSolidBySimple(shell, thickness)
    thicken.Build()
    if not thicken.IsDone():
        raise ValueError("could not thicken the given surface by the given thickness")
    solid = thicken.Shape()

    volume_props = GProp_GProps()
    brepgprop.VolumeProperties(solid, volume_props)
    if volume_props.Mass() < 0:
        solid = solid.Reversed()
    return solid
