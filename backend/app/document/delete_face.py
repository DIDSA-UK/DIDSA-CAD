"""OCCT geometry construction for DeleteFaceFeature (Direct Editing family,
fourth entry - see `docs/direct-editing-scope.md`) - removes every face
named in `face_refs` (1+, all sharing one Body) from its Body in one pass,
healing the resulting opening(s) closed, via OCCT `BRepAlgoAPI_Defeaturing`.

`BRepAlgoAPI_Defeaturing` is OCCT's own dedicated tool for exactly this
operation (originally built for defeaturing imported/dumb-solid CAD models -
removing a fillet/chamfer/pocket/boss feature and healing the surrounding
topology back to what it would have been without that feature) - not a
technique this codebase invented; confirmed working via a real pythonocc-core
spike (build a box, fillet one edge, `AddFaceToRemove` the new fillet face,
`Build()` restores the exact original 6-face/volume=1000 box; the same for a
Chamfer's planar face). Chosen over the "extrude an oversized block, boolean
it in" idiom `app.document.split`/early drafts of this module considered -
that technique fits Split's own "divide one Body into two along a cutting
tool" problem, but has no natural way to *heal* a Body back into a single
valid solid after removing one of its faces, which is a fundamentally
different operation (see `app.document.move_face`'s own module docstring for
where that oversized-block idiom *does* fit this family).

V2 (see `docs/direct-editing-scope.md`'s own "Delete Face V2 spike
findings" section): `AddFaceToRemove` genuinely supports being called once
per face before a single `Build()` - confirmed removing two independent
Fillet blend faces at once restores the exact original sharp box, bit-for-
bit the same numbers a single-face removal already produces - so multi-
face removal is the *same* technique v1 already used, just looped, not a
new one. Non-planar (cylindrical/conical) faces work the same way, not
just Fillet-generated blend faces - confirmed removing a plain box's own
through-hole cylindrical wall restores the exact original box. Both
confirmed findings, not assumptions.

Critical fail-closed detail, also only discovered via the spike: an
ill-defined removal (most commonly, a planar face of a primitive
box/cylinder with no adjacent fillet/chamfer/pocket to naturally close the
gap) does NOT raise or return `IsDone() == False` - `Build()` succeeds and
`Shape()` silently returns the *original, unmodified* Body instead, with the
target face(s) still present. The only signal this happened is `HasWarnings()`
- confirmed `False` for a genuine removal (the chamfer-face case above) and
`True` for the silent-no-op case, so `resolve_delete_face_from_bodies` fails
closed on `not IsDone() or HasWarnings()`, not `IsDone()` alone. Confirmed
(V2 spike) this signal generalizes correctly to both the multi-face and
non-planar cases too - e.g. removing two independent bosses' own top faces
(nothing to heal into) reports `HasWarnings=True` with the returned volume
unchanged from before removal, exactly like the single-planar-face silent-
no-op case.

Second, more serious fail-closed detail, also only found by testing every
face of a real chamfered box in turn rather than trusting one hand-picked
"it worked" case: `HasWarnings() == False` does NOT guarantee a *correct*
result either. Removing one of the plain box faces immediately adjacent to
the chamfered edge (not the chamfer face itself) reports `IsDone=True,
HasWarnings=False` - genuinely no warning at all - yet silently returns a
Body stretched several units past its own original bounding box in the
adjacent face's own direction, not healed back to the plain 10x10x10 box a
correct removal produces. There is no dedicated OCCT signal for this
"succeeded, but geometrically wrong" case, so `resolve_delete_face_from_
bodies` adds its own bounding-box sanity check: `_bbox_max_growth` measures
how far the post-removal shape's own `Bnd_Box` extends beyond the
*pre-removal* shape's own `Bnd_Box` in any direction, and rejects a result
that grows further than a modest fraction of the pre-removal shape's own
diagonal. This is a heuristic, not a proof - the reasoning is that
healing a single removed feature face (a fillet, chamfer, pocket, boss)
never legitimately extends a Body's silhouette far past where it already
extended before the removal (an un-filleted/un-chamfered sharp corner sits
at most a few percent of the part's own size past the rounded/cut version;
a wrongly-healed adjacent face, confirmed by the same test, blows past it
by an order of magnitude more) - see `test_feature_delete_face.py`'s own
coverage of exactly this "wrong face, still no warning" case for the real
numbers this bound was calibrated against.

This module needs `compute_part_bodies`/`resolve_subshape_from_bodies` from
extrude.py at module level, so (mirroring app.document.chamfer/fillet's own
identical circular-import workaround) extrude.py imports this module back
via a function-local import inside `_apply_feature_to_bodies` instead.
"""

from fastapi import HTTPException
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Defeaturing
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GeomAbs import GeomAbs_Cone, GeomAbs_Cylinder, GeomAbs_Plane
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Face, TopoDS_Shape, topods

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import DeleteFaceFeature, Part, SubShapeType

_SUPPORTED_SURFACE_TYPES = (GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone)


def _delete_face_not_found(body_id: str) -> HTTPException:
    return HTTPException(status_code=422, detail={"type": "missing_reference", "body_id": body_id})


def _delete_face_mixed_body_selection(body_ids: set[str]) -> HTTPException:
    """V2: every entry in `face_refs` must resolve to the same Body -
    mirrors `app.document.fillet._mixed_body_selection`'s identical
    constraint on `edge_refs` (`BRepAlgoAPI_Defeaturing`, like
    `BRepFilletAPI_MakeFillet`, operates on one solid at a time)."""
    return HTTPException(
        status_code=422,
        detail={"type": "mixed_body_selection", "body_ids": sorted(body_ids)},
    )


def _delete_face_unsupported_surface_type(body_id: str) -> HTTPException:
    """V2 accepts planar, cylindrical, and conical faces (confirmed via
    spike); anything else (spherical, toroidal, free-form/B-spline, ...)
    is rejected here - same type name `app.document.move_face` uses for
    the identical surface-type decision on its own `offset_distance`
    mode, deliberately kept consistent across the family."""
    return HTTPException(
        status_code=422, detail={"type": "unsupported_surface_type", "body_id": body_id}
    )


def _delete_face_failed(body_id: str) -> HTTPException:
    """`BRepAlgoAPI_Defeaturing` either didn't complete, or (the silent-
    no-op case this module's own docstring documents) completed but
    reported warnings - both mean the removal has no well-defined healed
    result. 422, matching every other structured geometry-failure error in
    this codebase (`fillet_failed`, `mirror_failed`, `scale_body_failed`,
    ...)."""
    return HTTPException(status_code=422, detail={"type": "delete_face_failed", "body_id": body_id})


def _face_count(shape: TopoDS_Shape) -> int:
    count = 0
    exp = TopExp_Explorer(shape, TopAbs_FACE)
    while exp.More():
        count += 1
        exp.Next()
    return count


def _volume(shape: TopoDS_Shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


# How far `_bbox_max_growth` tolerates the post-removal shape's own Bnd_Box
# extending beyond the pre-removal shape's own, as a fraction of the
# pre-removal shape's own bounding-box diagonal - see this module's own top
# docstring for the real numbers (a correct chamfer-undo: ~0 growth; a
# wrongly-healed adjacent face: several units past a ~17-unit diagonal) this
# was calibrated against.
_MAX_BBOX_GROWTH_RATIO = 0.25


def _bbox_max_growth(before: TopoDS_Shape, after: TopoDS_Shape) -> float:
    """How far `after`'s own axis-aligned `Bnd_Box` extends beyond
    `before`'s own, in the single worst-offending direction - 0.0 (or
    negative) when `after` is fully contained within `before`'s own bbox.
    Same `Bnd_Box`/`BRepBndLib.brepbndlib.Add` idiom `app.document.
    scale_body._bbox_center`/`app.document.split._bbox_corners_and_
    diagonal` already establish."""
    before_box, after_box = Bnd_Box(), Bnd_Box()
    brepbndlib.Add(before, before_box)
    brepbndlib.Add(after, after_box)
    bxmin, bymin, bzmin, bxmax, bymax, bzmax = before_box.Get()
    axmin, aymin, azmin, axmax, aymax, azmax = after_box.Get()
    return max(
        bxmin - axmin, axmax - bxmax,
        bymin - aymin, aymax - bymax,
        bzmin - azmin, azmax - bzmax,
    )


def resolve_delete_face_from_bodies(
    bodies: dict[str, TopoDS_Shape],
    feature: DeleteFaceFeature,
) -> tuple[str, TopoDS_Shape]:
    """The Body id `feature` modifies and its post-removal shape, resolved
    against `bodies` - an already-in-progress `app.document.extrude.
    compute_part_bodies` accumulator, never a fresh recompute (same reason
    `resolve_fillet_from_bodies`'s own doc comment gives)."""
    body_ids = {ref.body_id for ref in feature.face_refs}
    if len(body_ids) != 1:
        raise _delete_face_mixed_body_selection(body_ids)
    body_id = next(iter(body_ids))
    source = bodies.get(body_id)
    if source is None:
        raise _delete_face_not_found(body_id)

    faces: list[TopoDS_Face] = []
    for ref in feature.face_refs:
        if ref.shape_type != SubShapeType.FACE:
            raise _delete_face_not_found(body_id)
        face = topods.Face(resolve_subshape_from_bodies(bodies, ref))
        if BRepAdaptor_Surface(face, True).GetType() not in _SUPPORTED_SURFACE_TYPES:
            raise _delete_face_unsupported_surface_type(body_id)
        faces.append(face)

    defeaturing = BRepAlgoAPI_Defeaturing()
    defeaturing.SetShape(source)
    for face in faces:
        defeaturing.AddFaceToRemove(face)
    defeaturing.SetRunParallel(False)
    defeaturing.Build()
    if not defeaturing.IsDone() or defeaturing.HasWarnings():
        raise _delete_face_failed(body_id)

    result = defeaturing.Shape()
    # Belt-and-braces: HasWarnings() is the confirmed real-world signal for
    # the silent-no-op case (see this module's own top docstring), but an
    # empty/degenerate result (zero faces, zero-or-negative volume) fails
    # closed here too rather than ever being registered as a Body.
    if _face_count(result) == 0 or _volume(result) <= 0.0:
        raise _delete_face_failed(body_id)

    # Second, more serious check - see this module's own top docstring for
    # the real "succeeded with no warnings, but geometrically wrong" case
    # this catches, which HasWarnings() alone does not.
    before_box = Bnd_Box()
    brepbndlib.Add(source, before_box)
    diagonal = before_box.CornerMax().Distance(before_box.CornerMin())
    if _bbox_max_growth(source, result) > diagonal * _MAX_BBOX_GROWTH_RATIO:
        raise _delete_face_failed(body_id)

    return body_id, result


def resolve_delete_face(
    part: Part, feature: DeleteFaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[str, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation - mirrors
    `resolve_fillet`'s own self-exclusion shape exactly (Delete Face
    modifies a Body in place, so re-resolving against its own prior output
    would double-apply it - deleting an already-deleted face's own healed
    neighbor, not re-deriving the original candidate)."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_delete_face_from_bodies(bodies, feature)
