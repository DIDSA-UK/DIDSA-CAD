"""OCCT geometry construction for `OffsetSurfaceFeature` - Phase 2 surfacing
package, fourth and last of the surface-consuming tools. Offsets `source`
(a Body face or an existing single-shell surface Feature - see `app.
document.models.OffsetSourceRef`'s own docstring) by `distance` along its
own outward normal, into a brand-new, independent Surface.

**Fresh, smaller implementation, not a generalization of `app.document.
move_face`** - that module's own `offset_distance` mode shape ("offset a
named subset of faces of an existing whole Body, in place") genuinely
doesn't fit "offset exactly one Face/Shell into an independent copy". This
module instead calls `BRepOffset_MakeOffset` directly, using `move_face.
py`'s already-tuned `Initialize(...)` parameters/tolerance/mode
(`_OFFSET_TOLERANCE`, `BRepOffset_Skin`, `GeomAbs_Intersection`) duplicated
here as a literal constant with this citing comment, not imported - that
module's own offset call is a private implementation detail of a Direct-
Editing-specific routine, not a shared utility (mirrors `app.document.
surface_ops.sew_surfaces`'s own "cited as precedent, not imported" note
about `app.document.bevel`'s sewing tolerance).

**Verification status**: needs a real on-device/CI pass before being
trusted - this repo's dev sandbox has never had `pythonocc-core` installed."""

from fastapi import HTTPException
from OCC.Core.BRepOffset import BRepOffset_MakeOffset, BRepOffset_Skin
from OCC.Core.GeomAbs import GeomAbs_Intersection
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_SHELL
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape, topods

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.graph import resolve_feature_produces
from app.document.models import OffsetSurfaceFeature, Part, Produces, SubShapeType

# `BRepOffset_MakeOffset.Initialize`'s own coincidence tolerance - the exact
# value `app.document.move_face`'s own `offset_distance` mode already
# proved (see that module's own `_OFFSET_TOLERANCE`) - duplicated here as a
# literal per this module's own top docstring, not imported.
_OFFSET_TOLERANCE = 1e-6


def _invalid_surface_feature_ref(surface_feature_id: str, detail: str) -> HTTPException:
    """Mirrors `app.document.thicken._invalid_surface_feature_ref` exactly -
    kept as its own copy per this codebase's "no sibling-Feature-module
    internals reuse" convention."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "invalid_surface_feature_ref",
            "surface_feature_id": surface_feature_id,
            "detail": detail,
        },
    )


def _invalid_offset_source(detail: str) -> HTTPException:
    """`OffsetSurfaceFeature.source` resolved to something structurally
    wrong for this tool - e.g. a Compound-of-shells surface Feature (v1
    scope: ambiguous per-shell, rejected outright - see `OffsetSourceRef`'s
    own docstring)."""
    return HTTPException(status_code=422, detail={"type": "invalid_offset_source", "detail": detail})


def _offset_surface_failed(detail: str) -> HTTPException:
    """A structurally-valid source that `BRepOffset_MakeOffset` nonetheless
    couldn't offset - mirrors `app.document.move_face`'s own `move_face_
    failed`/`move_face_null_result` distinction, collapsed to one type here
    since this tool has no in-place-mutation neighbour-consuming behaviour
    to distinguish a null result from."""
    return HTTPException(status_code=422, detail={"type": "offset_surface_failed", "detail": detail})


def _resolve_offset_source_shape(
    part: Part, feature: OffsetSurfaceFeature, bodies_so_far: dict[str, TopoDS_Shape]
) -> TopoDS_Shape:
    """Resolves `feature.source` to the raw shape `BRepOffset_MakeOffset`
    offsets - a `TopoDS_Face` for `face_ref` (resolved from `bodies_so_far`
    the same way `app.document.move_face`/`app.document.fillet` already
    resolve a `SubShapeRef`), or the referenced surface Feature's own live
    shape for `surface_feature_id` (required to be a single `TopAbs_FACE` -
    e.g. a `PlanarSurfaceFeature` - or a single `TopAbs_SHELL` - e.g. a
    Revolve/Loft/Swept/Ruled Surface - a Compound-of-shells source is
    rejected outright, see `_invalid_offset_source`)."""
    source = feature.source
    if source.face_ref is not None:
        if source.face_ref.shape_type != SubShapeType.FACE:
            raise _invalid_offset_source("face_ref must reference a face")
        return topods.Face(resolve_subshape_from_bodies(bodies_so_far, source.face_ref))

    assert source.surface_feature_id is not None
    source_feature = part.get_feature(source.surface_feature_id)
    if source_feature is None or resolve_feature_produces(source_feature, part) != Produces.SURFACE:
        raise _invalid_surface_feature_ref(
            source.surface_feature_id, "does not refer to a surface-producing Feature in this Part"
        )
    shape = bodies_so_far.get(source.surface_feature_id)
    if shape is None:
        raise _invalid_surface_feature_ref(
            source.surface_feature_id, "could not be resolved to a live shape"
        )
    if shape.ShapeType() not in (TopAbs_FACE, TopAbs_SHELL):
        raise _invalid_offset_source(
            "the given surface Feature is not a single Face or connected Shell (a "
            "Compound-of-shells source is ambiguous per-shell - v1 scope)"
        )
    return shape


def resolve_offset_surface_from_bodies(
    feature: OffsetSurfaceFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The raw offset shape for `feature` - always either returns a real
    shape or raises, same "always raise, never return None" contract every
    Phase 2 tool in this package follows (see `ThickenFeature`'s own
    docstring)."""
    source_shape = _resolve_offset_source_shape(part, feature, bodies_so_far)

    offset_maker = BRepOffset_MakeOffset()
    offset_maker.Initialize(
        source_shape,
        0.0,
        _OFFSET_TOLERANCE,
        BRepOffset_Skin,
        False,
        False,
        GeomAbs_Intersection,
        False,
        False,
    )
    if source_shape.ShapeType() == TopAbs_FACE:
        offset_maker.SetOffsetOnFace(topods.Face(source_shape), feature.distance)
    else:
        explorer = TopExp_Explorer(source_shape, TopAbs_FACE)
        while explorer.More():
            offset_maker.SetOffsetOnFace(topods.Face(explorer.Current()), feature.distance)
            explorer.Next()
    offset_maker.MakeOffsetShape()
    result = offset_maker.Shape()

    if not offset_maker.IsDone() or result is None or result.IsNull():
        raise _offset_surface_failed("could not offset the given surface by the given distance")
    return result


def resolve_offset_surface(
    part: Part, feature: OffsetSurfaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.thicken.resolve_thicken`'s own self-exclusion convention
    exactly."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_offset_surface_from_bodies(feature, part, bodies, all_excluded)
