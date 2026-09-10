"""Shared OCCT shell-thickening plumbing - extracted out of
`app.document.loft` so `app.document.extrude`'s own thin-wall extrude can
reuse the identical primitive without a circular import (`loft.py` already
imports from `extrude.py` at module level, so `extrude.py` importing back
from `loft.py` would cycle). Nothing in this module is Loft-specific - it is
generic "thicken an open shell into a solid" OCCT plumbing that any Feature
producing an open shell may need.

**Verification status**: run against a real pythonocc-core 7.9.3 kernel
(on-device testing bug report: "Solid extrude thin ... in and out produce
bad geometry, mid produced no solid at all", 30x30 square / 5mm wall). Two
real bugs confirmed and fixed here: (1) `MakeThickSolidByJoin`'s `Join=`
keyword-argument call was rejected outright with `TypeError` by this OCCT
version's own binding (it's positional-only past `Tol`) - so
[_thicken_by_join] was silently failing on every call and always falling
back to `MakeThickSolidBySimple`, never actually exercising the mitred-
corner path its own docstring described; fixed by passing the full
positional argument list. (2) `MakeThickSolidBySimple` explicitly does not
support `ClosingFaces` ("According to its nature it is not possible to set
list of the closing faces... Non-closed shell or face is expected as
input." - straight from its own OCCT docstring) - so it can never correctly
hollow a genuinely *closed* solid; extrude thin's own bug (see
[thicken_capped_solid_to_solid]) needed the `ClosingFaces` path
specifically, not this module's original open-shell path. (3) once bug (1)
was fixed and `MakeThickSolidByJoin` actually ran on a bare open FACE with
an empty `ClosingFaces` (this module's own [thicken_shell_to_solid] case -
`ThickenFeature`/Loft's thin-wall), it came back a bare `TopoDS_Shell`
(`ShapeType() == TopAbs_SHELL`), not a `TopoDS_Solid` - `BRepCheck_
Analyzer` still reports it "valid" (a valid *shell*, watertight but the
wrong topological kind), yet the rest of this codebase's `compute_part_
bodies` pipeline requires an actual Solid and silently drops anything else
(confirmed: a Thicken feature that returned 201 produced no body at all in
`compute_part_bodies`'s own output). [_thicken_by_join] now checks
`ShapeType() == TopAbs_SOLID` explicitly, treating a Shell result as a
"this input doesn't work with Join" signal (returns `None`, same as any
other `_thicken_by_join` failure) so [thicken_shell_to_solid] falls back to
the known-working `MakeThickSolidBySimple` path for exactly this case - the
`ClosingFaces`-driven [thicken_capped_solid_to_solid] path (extrude thin)
was independently confirmed to already return a genuine Solid, so this
check is a no-op there.
"""

from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepOffset import BRepOffset_Skin
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakeThickSolid
from OCC.Core.GeomAbs import GeomAbs_Intersection
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_SOLID
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

    `ClosingFaces` is passed empty here deliberately: every caller of
    `thicken_shell_to_solid` hands in an *open* shell (a prism/loft's own
    bare side walls, with no cap faces to remove in the first place - see
    `app.document.extrude`'s/`app.document.loft`'s own callers), not a
    closed solid to hollow out - see [thicken_capped_solid_to_solid] for
    the separate, `ClosingFaces`-driven path a genuinely closed solid
    needs instead.

    Returns `None` (never raises) on anything short of a fully valid
    result - `IsDone()` failing, an OCCT `RuntimeError` for a shell/join-
    type combination this call doesn't support, a solid that fails
    `BRepCheck_Analyzer`, or (confirmed against a real kernel: bug (3) in
    this module's own verification-status note above) a result that comes
    back a bare `TopoDS_Shell` rather than a genuine `TopoDS_Solid` - so
    [thicken_shell_to_solid] can fall back to the known-working
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
            BRepOffset_Skin,
            False,
            False,
            GeomAbs_Intersection,
            False,
        )
        thicken.Build()
    except (RuntimeError, TypeError):
        return None
    if not thicken.IsDone():
        return None
    solid = thicken.Shape()
    if solid is None or solid.IsNull() or not BRepCheck_Analyzer(solid).IsValid():
        return None
    if solid.ShapeType() != TopAbs_SOLID:
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


def thicken_capped_solid_to_solid(
    solid: TopoDS_Shape, closing_faces: TopTools_ListOfShape, thickness: float
) -> TopoDS_Shape:
    """Hollows a genuinely *closed* solid (real end caps, e.g. a profile
    face's own prism - unlike [thicken_shell_to_solid]'s open-shell input)
    by removing `closing_faces` and adding wall thickness `thickness` to
    whatever remains, via OCCT's `BRepOffsetAPI_MakeThickSolid.
    MakeThickSolidByJoin` (its textbook "shell this solid, punching a hole
    where these named faces used to be" usage - the same call
    [_thicken_by_join] makes, just with real `closing_faces` instead of an
    empty list).

    `MakeThickSolidBySimple` cannot serve as this function's fallback the
    way it does in [thicken_shell_to_solid]: it explicitly does not support
    `ClosingFaces` at all ("it is not possible to set list of the closing
    faces... Non-closed shell or face is expected as input" - its own OCCT
    docstring), and this function's whole point is hollowing a *closed*
    solid. `MakeThickSolidByJoin` is therefore the only path here, not a
    best-effort upgrade over a fallback - callers get a `ValueError` if it
    fails.

    On-device bug this exists to fix ("Solid extrude thin ... in and out
    produce bad geometry, mid produced no solid at all"): extrude thin
    previously prismed the profile's own WIRE into an already-open, cap-
    less shell, then thickened *that* with an empty `ClosingFaces` list -
    leaving OCCT no faces to remove and no guidance for closing the shape
    at its free top/bottom rim, so it improvised its own rounded capping
    there. Confirmed against a real kernel (30x30 square, 5mm wall, 20mm
    extrude): that came back with its Z bounds inflated ~3.5mm past the
    intended [0, 20] and a volume of 6833 instead of the correct 14000.
    Prisming the profile's own FACE instead (a real capped solid) and
    passing its two end-cap faces (`BRepPrimAPI_MakePrism.FirstShape()`/
    `LastShape()`) as `closing_faces` here reproduces exactly the intended
    flat-rimmed tube: confirmed against the same repro, outward now returns
    volume 14000.0 with Z bounds exactly [0, 20], inward returns 10000.0
    (also exact), both flat."""
    thicken = BRepOffsetAPI_MakeThickSolid()
    thicken.MakeThickSolidByJoin(
        solid,
        closing_faces,
        thickness,
        1.0e-6,
        BRepOffset_Skin,
        False,
        False,
        GeomAbs_Intersection,
        False,
    )
    thicken.Build()
    if not thicken.IsDone():
        raise ValueError("could not thicken the given capped solid by the given thickness")
    result = thicken.Shape()
    if result is None or result.IsNull() or not BRepCheck_Analyzer(result).IsValid():
        raise ValueError("thickened capped solid is invalid")
    if result.ShapeType() != TopAbs_SOLID:
        raise ValueError("thickened capped solid did not come back as a genuine solid")

    volume_props = GProp_GProps()
    brepgprop.VolumeProperties(result, volume_props)
    if volume_props.Mass() < 0:
        result = result.Reversed()
    return result
