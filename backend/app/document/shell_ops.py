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

from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakeThickSolid
from OCC.Core.GeomAbs import GeomAbs_Intersection
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopoDS import TopoDS_Shape
from OCC.Core.TopTools import TopTools_ListOfShape


def _thicken_by_join(shell: TopoDS_Shape, thickness: float) -> TopoDS_Shape | None:
    """On-device feedback ("extrude thin solid isn't working as desired
    with a rectangular sketch, the wall thickness is wrong, not flat"):
    `MakeThickSolidBySimple` (this module's original, still-used-as-
    fallback implementation below) offsets each face independently and
    restitches them with no explicit corner-join control - exactly the
    kind of naive per-face offset that produces a non-planar/slanted wall
    or a thickness gap at a profile's sharp (near-90-degree) corners,
    matching the reported rectangular-sketch defect.

    `MakeThickSolidByJoin` is OCCT's fuller-featured thicken entry point,
    taking an explicit `JoinType` - `GeomAbs_Intersection` computes each
    wall face's true planar intersection with its neighbour (a flat,
    correctly-mitred corner) rather than `MakeThickSolidBySimple`'s
    undefined-at-the-corner per-face approach, or `GeomAbs_Arc`'s
    (this call's own default) rounded corner - neither of which is what a
    sharp-cornered profile's thin wall should look like.

    `ClosingFaces` (the classic "which face(s) of a *closed* solid to
    remove, turning it into a shell before offsetting" argument) is passed
    empty here deliberately: every caller of `thicken_shell_to_solid`
    already hands in an *open* shell (a prism/loft's own bare side walls,
    with no cap faces to remove in the first place - see
    `app.document.extrude`'s/`app.document.loft`'s own callers), not a
    closed solid to hollow out - the empty-list behaviour against an
    already-open shell has not been confirmed identical to
    `MakeThickSolidBySimple`'s own against a real OCCT kernel (flagged in
    this module's own verification-status note below), which is exactly
    why [thicken_shell_to_solid] treats this as a best-effort upgrade with
    a fallback, not an unconditional replacement.

    Returns `None` (never raises) on anything short of a fully valid
    result - `IsDone()` failing, an OCCT `RuntimeError` for a shell/join-
    type combination this call doesn't support, a `TypeError` if this
    OCCT/pythonocc-core version's own `MakeThickSolidByJoin` binding
    doesn't accept the exact keyword-argument signature assumed here (not
    yet confirmed against a real kernel - see this module's own
    verification-status note), or a solid that fails `BRepCheck_Analyzer`
    - so [thicken_shell_to_solid] can fall back to the known-working
    `MakeThickSolidBySimple` path rather than surface a regression (or a
    crash) on a shape/environment this join-type upgrade doesn't actually
    help."""
    thicken = BRepOffsetAPI_MakeThickSolid()
    try:
        thicken.MakeThickSolidByJoin(
            shell,
            TopTools_ListOfShape(),
            thickness,
            1.0e-6,
            Join=GeomAbs_Intersection,
        )
        thicken.Build()
    except (RuntimeError, TypeError):
        return None
    if not thicken.IsDone():
        return None
    solid = thicken.Shape()
    if solid is None or solid.IsNull() or not BRepCheck_Analyzer(solid).IsValid():
        return None
    return solid


def thicken_shell_to_solid(shell: TopoDS_Shape, thickness: float) -> TopoDS_Shape:
    """Thickens an open shell into a solid via OCCT's standard
    BRepOffsetAPI_MakeThickSolid idiom.

    Tries [_thicken_by_join] first (`GeomAbs_Intersection`-mitred corners -
    see that function's own doc comment for the rectangular-corner bug
    this fixes), falling back to the original `MakeThickSolidBySimple`
    call - kept exactly as before, unconditionally, for a shell the join
    upgrade doesn't successfully handle - rather than risk regressing a
    shape that already thickened correctly under it.

    Either path includes the volume-sign fixup a real on-device/CI run
    found necessary: the output solid can come back with inverted
    (inward-pointing) face orientation depending on the input shell's own
    winding - BRepGProp's volume integral is signed by face orientation,
    so this surfaces as a *negative* Mass() for an otherwise perfectly
    valid solid (confirmed via a real 10x8x1 thin loft: OCCT returned
    -80.0, not 80.0). `.Reversed()` flips every face's orientation (and,
    transitively, the sign BRepGProp reports) without changing the solid's
    actual shape at all - the standard OCCT fix for exactly this, applied
    unconditionally based on a real volume check rather than assumed to
    always be needed (a shell that happens to come out right-side-up
    already has this be a no-op check, not a blind flip). Raises
    `ValueError` if neither path completes."""
    solid = _thicken_by_join(shell, thickness)
    if solid is None:
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
