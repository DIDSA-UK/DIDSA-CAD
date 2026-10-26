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

from app.document.reference_history import note_operation
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakeSolid,
    BRepBuilderAPI_Sewing,
)
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepFill import brepfill
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepOffset import BRepOffset_Skin
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakeThickSolid
from OCC.Core.GeomAbs import GeomAbs_Intersection
from OCC.Core.GProp import GProp_GProps
from OCC.Core.ShapeAnalysis import ShapeAnalysis_FreeBounds
from OCC.Core.ShapeFix import ShapeFix_Solid
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_SHELL, TopAbs_SOLID, TopAbs_WIRE
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopoDS import TopoDS_Edge, TopoDS_Shape, topods
from OCC.Core.TopTools import TopTools_IndexedDataMapOfShapeListOfShape, TopTools_ListOfShape


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


def _thicken_by_capping_free_bounds(shell: TopoDS_Shape, thickness: float) -> TopoDS_Shape | None:
    """On-device feedback ("Thicken surface on a rectangular extruded
    surface still produced bad geometry"): a genuinely open, multi-face,
    cap-less shell (e.g. `app.document.surface._prism_shell_for_wire`'s
    own output - a rectangular tube's 4 side walls, no top/bottom) has no
    known cap faces to pass as `ClosingFaces` the way [thicken_capped_
    solid_to_solid] does for Extrude Thin (that function's own caller
    controls its construction and can build temporary caps *before*
    thickening; a Surface feature arrives here already built, with no cap
    information at all) - so both [_thicken_by_join] (empty `ClosingFaces`,
    rejected for this shell shape per bug (3) in this module's own
    verification-status note) and `MakeThickSolidBySimple` (this module's
    fallback) improvise their own rounded/bulged closing at every free
    edge, not just the intended wall thickness. Confirmed against a real
    kernel (10x10 square wire, prismed 20 along Z, thickness 2): bounding
    box inflates by `thickness*sqrt(2)` on *every* axis instead of staying
    flat, and volume comes back roughly half the correct 1920.

    Fix: discover the shell's own free boundary wire loops via OCCT's
    `ShapeAnalysis_FreeBounds` (for the tube case, exactly the top and
    bottom rims), build a temporary face for each (`BRepBuilderAPI_
    MakeFace`), sew them onto the shell into a genuinely closed solid
    (`BRepBuilderAPI_Sewing` + `BRepBuilderAPI_MakeSolid`, then `ShapeFix_
    Solid` - confirmed necessary against a real kernel: without it the
    sewn solid's face orientations come back inconsistent, and thickening
    it produces an invalid result with a negative, wrong-magnitude
    volume), then thicken via the same proven `MakeThickSolidByJoin` +
    `ClosingFaces` idiom [thicken_capped_solid_to_solid] uses, passing the
    newly-built caps as the faces to remove again - leaving a correctly
    flat-rimmed thickened shell. Confirmed against the same repro: volume
    now comes back exactly 1920.0, Z bounds exactly [0, 20]; also
    confirmed against an L-shaped (non-convex, 6-vertex) profile - a
    valid, flat-Z-bounded solid.

    Returns `None` (never raises) if any step fails - no closed boundary
    wire found, a cap face that fails to build, a sewn result that can't
    be coerced into a valid solid, or the thicken call itself failing -
    so [thicken_shell_to_solid] can fall back to `MakeThickSolidBySimple`
    (correct for the genuinely-already-closed/single-face cases this
    function isn't needed for) rather than surface a crash."""
    free_bounds = ShapeAnalysis_FreeBounds(shell)
    closed_wires_compound = free_bounds.GetClosedWires()
    wire_explorer = TopExp_Explorer(closed_wires_compound, TopAbs_WIRE)
    boundary_wires = []
    while wire_explorer.More():
        boundary_wires.append(topods.Wire(wire_explorer.Current()))
        wire_explorer.Next()
    if not boundary_wires:
        return None

    cap_faces = []
    for wire in boundary_wires:
        face_maker = BRepBuilderAPI_MakeFace(wire)
        if not face_maker.IsDone():
            return None
        cap_faces.append(face_maker.Face())

    sewing = BRepBuilderAPI_Sewing(1.0e-6)
    sewing.Add(shell)
    for face in cap_faces:
        sewing.Add(face)
    sewing.Perform()
    sewn = sewing.SewedShape()
    if sewn is None or sewn.IsNull():
        return None

    solid_maker = BRepBuilderAPI_MakeSolid()
    if sewn.ShapeType() == TopAbs_SHELL:
        solid_maker.Add(topods.Shell(sewn))
    else:
        shell_explorer = TopExp_Explorer(sewn, TopAbs_SHELL)
        found_shell = False
        while shell_explorer.More():
            solid_maker.Add(topods.Shell(shell_explorer.Current()))
            found_shell = True
            shell_explorer.Next()
        if not found_shell:
            return None
    if not solid_maker.IsDone():
        return None
    solid = solid_maker.Solid()

    fixer = ShapeFix_Solid(solid)
    fixer.Perform()
    solid = fixer.Solid()
    if solid is None or solid.IsNull() or not BRepCheck_Analyzer(solid).IsValid():
        return None

    closing_faces = TopTools_ListOfShape()
    for face in cap_faces:
        closing_faces.Append(face)
    try:
        return thicken_capped_solid_to_solid(solid, closing_faces, thickness)
    except ValueError:
        return None


def _free_edges(shape: TopoDS_Shape) -> list[TopoDS_Edge]:
    """The edges of `shape` that belong to exactly one face (its open boundary)."""
    ancestors = TopTools_IndexedDataMapOfShapeListOfShape()
    topexp.MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, ancestors)
    free = []
    for index in range(1, ancestors.Extent() + 1):
        edge = topods.Edge(ancestors.FindKey(index))
        if not BRep_Tool.Degenerated(edge) and ancestors.FindFromIndex(index).Size() == 1:
            free.append(edge)
    return free


def _edge_midpoint(edge: TopoDS_Edge):
    curve = BRepAdaptor_Curve(edge)
    return curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter()))


def _edge_ends(edge: TopoDS_Edge):
    """Start and end points *as the edge is oriented in its shape* (a curve's own parameter
    direction is not that when the edge is reversed)."""
    return BRep_Tool.Pnt(topexp.FirstVertex(edge, True)), BRep_Tool.Pnt(topexp.LastVertex(edge, True))


def _volume_is_plausible(shell: TopoDS_Shape, solid: TopoDS_Shape, thickness: float) -> bool:
    """Whether `solid` could be `shell` thickened by `thickness`: about area x |thickness| (corners
    add or remove a little, so the window is wide). Catches a "valid" but empty result: capping the
    free boundary of a single flat wall returned a solid of volume 0.0 for one sign of the thickness."""
    area_props = GProp_GProps()
    brepgprop.SurfaceProperties(shell, area_props)
    volume_props = GProp_GProps()
    brepgprop.VolumeProperties(solid, volume_props, 1.0e-6)
    expected = area_props.Mass() * abs(thickness)
    return 0.3 * expected <= abs(volume_props.Mass()) <= 3.0 * expected


def _thicken_by_offset_and_walls(shell: TopoDS_Shape, thickness: float) -> TopoDS_Shape | None:
    """Thickens an open shell of any number of faces (an L-shaped wall, an arc-and-line wall) by
    building the solid explicitly: the shell, its mitred offset (`MakeThickSolidByJoin` with no
    closing faces returns just the offset shell, with `GeomAbs_Intersection` corners), and a ruled
    wall between every free edge and its offset edge, all sewn.

    This replaces `MakeThickSolidBySimple` for shells [_thicken_by_join] and
    [_thicken_by_capping_free_bounds] decline. Simple offsets each face on its own and leaves the
    corners open: two 10 mm and 6 mm walls 8 mm tall, 1 mm thick, came out at 88-108 mm3 instead of
    the 136 (material on the outside of the bend) or 120 (inside) this gives exactly. Each free
    edge is matched to the nearest offset free edge (their midpoints are about |t| apart), the
    offset edge flipped if it runs the other way, and the walls built with `brepfill.Face`.

    Returns `None` (never raises) if the shell cannot be offset, an edge has no partner, the sewn
    result is not a closed valid solid, or its volume is implausible for the shell's area."""
    offset_maker = BRepOffsetAPI_MakeThickSolid()
    try:
        offset_maker.MakeThickSolidByJoin(
            shell, TopTools_ListOfShape(), thickness, 1.0e-6, BRepOffset_Skin, False, False, GeomAbs_Intersection, False
        )
        offset_maker.Build()
    except (RuntimeError, TypeError):
        return None
    if not offset_maker.IsDone():
        return None
    offset = offset_maker.Shape()
    if offset is None or offset.IsNull():
        return None

    originals = _free_edges(shell)
    candidates = _free_edges(offset)
    if not originals or len(originals) != len(candidates):
        return None

    sewing = BRepBuilderAPI_Sewing(1.0e-6)
    sewing.Add(shell)
    sewing.Add(offset)
    taken: set[int] = set()
    try:
        for edge in originals:
            middle = _edge_midpoint(edge)
            best = min(range(len(candidates)), key=lambda i: middle.Distance(_edge_midpoint(candidates[i])))
            if best in taken or middle.Distance(_edge_midpoint(candidates[best])) > 2.0 * abs(thickness):
                return None
            taken.add(best)
            partner = candidates[best]
            start, end = _edge_ends(edge)
            partner_start, partner_end = _edge_ends(partner)
            if start.Distance(partner_start) + end.Distance(partner_end) > start.Distance(partner_end) + end.Distance(
                partner_start
            ):
                partner = topods.Edge(partner.Reversed())
            sewing.Add(brepfill.Face(edge, partner))
        sewing.Perform()
    except RuntimeError:
        return None
    sewn = sewing.SewedShape()
    if sewn is None or sewn.IsNull() or sewn.ShapeType() != TopAbs_SHELL or _free_edges(sewn):
        return None
    fixer = ShapeFix_Solid(BRepBuilderAPI_MakeSolid(topods.Shell(sewn)).Solid())
    fixer.Perform()
    solid = fixer.Solid()
    if solid is None or solid.IsNull() or not BRepCheck_Analyzer(solid).IsValid():
        return None

    return solid if _volume_is_plausible(shell, solid, thickness) else None


def thicken_shell_to_solid(shell: TopoDS_Shape, thickness: float) -> TopoDS_Shape:
    """Thickens an open shell into a solid via OCCT's standard
    BRepOffsetAPI_MakeThickSolid idiom.

    Tries [_thicken_by_join] first (`GeomAbs_Intersection`-mitred corners -
    see that function's own doc comment for the rectangular-corner bug
    this fixes), then [_thicken_by_capping_free_bounds] (a genuinely
    open, multi-face, cap-less shell - see that function's own doc
    comment), then [_thicken_by_offset_and_walls] (the mitred offset plus
    ruled walls along the free edges - what a multi-face open wall, whose
    free boundary has no planar cap, needs), falling back to the original
    `MakeThickSolidBySimple` call - kept unconditionally for a shell none of
    the upgrades handles - rather than risk regressing a shape that
    already thickened correctly under it.

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
    `ValueError` if no path completes."""
    solid = _thicken_by_join(shell, thickness)
    if solid is not None and not _volume_is_plausible(shell, solid, thickness):
        solid = None
    if solid is None:
        solid = _thicken_by_capping_free_bounds(shell, thickness)
        if solid is not None and not _volume_is_plausible(shell, solid, thickness):
            solid = None
    if solid is None:
        solid = _thicken_by_offset_and_walls(shell, thickness)
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
    note_operation(thicken)  # a Shell hollows its Body in place: faces survive or are Modified, the inner offset faces are new

    volume_props = GProp_GProps()
    brepgprop.VolumeProperties(result, volume_props)
    if volume_props.Mass() < 0:
        result = result.Reversed()
    return result
