"""OCCT geometry construction for `SolidFromSurfacesFeature` - Phase 2
surfacing package, third of four surface-consuming tools. Sews 2+ existing
upstream surface Features into a single watertight solid, generalizing
`app.document.bevel`'s own proven gear-tooth-assembly pipeline (cited as
precedent, reimplemented fresh rather than importing gear-specific
internals - see that module's own top docstring, in particular its own
"`MakeSolid` alone on the raw sewn shell is not sufficient" note): `app.
document.surface_ops.sew_surfaces` -> require exactly one resulting
`TopAbs_SHELL` -> `ShapeFix_Shell` -> `BRepBuilderAPI_MakeSolid` ->
`BRepLib.OrientClosedSolid` -> a post-hoc `BRepCheck_Analyzer`/positive-
volume sanity check (mirrors `app.document.move_face`'s own post-boolean
validity-check pattern).

A structurally-valid set of surfaces that doesn't actually sew into one
closed shell (a missing face, a gap, ...) is the single most important
failure path here - `not_watertight`, never a silently-broken solid.

**Verification status**: needs a real on-device/CI pass before being
trusted - this repo's dev sandbox has never had `pythonocc-core` installed."""

from fastapi import HTTPException
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeSolid
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepLib import breplib
from OCC.Core.GProp import GProp_GProps
from OCC.Core.ShapeFix import ShapeFix_Shell
from OCC.Core.TopAbs import TopAbs_SHELL
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape, TopoDS_Shell, topods

from app.document.extrude import compute_part_bodies
from app.document.models import Part, Produces, SolidFromSurfacesFeature
from app.document.surface_ops import sew_surfaces


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


def _not_watertight(detail: str) -> HTTPException:
    """The single most important failure path in this whole Feature - a
    structurally-valid set of surfaces that doesn't actually sew into one
    closed, valid solid (missing a face, a gap, a sliver, ...)."""
    return HTTPException(status_code=422, detail={"type": "not_watertight", "detail": detail})


def _resolve_surface_feature_shape(
    part: Part, surface_feature_id: str, bodies_so_far: dict[str, TopoDS_Shape]
) -> TopoDS_Shape:
    source_feature = part.get_feature(surface_feature_id)
    if source_feature is None or source_feature.produces != Produces.SURFACE:
        raise _invalid_surface_feature_ref(
            surface_feature_id, "does not refer to a surface-producing Feature in this Part"
        )
    shape = bodies_so_far.get(surface_feature_id)
    if shape is None:
        raise _invalid_surface_feature_ref(surface_feature_id, "could not be resolved to a live shape")
    return shape


def _single_shell(shape: TopoDS_Shape) -> TopoDS_Shell:
    """Mirrors `app.document.bevel._single_shell` exactly - explodes `shape`
    into its constituent `TopAbs_SHELL`s and requires exactly one, else
    raises `not_watertight` (a sewn result with 0 or 2+ disjoint shells
    means the given surfaces did not close up into a single connected
    boundary)."""
    if shape.ShapeType() == TopAbs_SHELL:
        return topods.Shell(shape)
    shells: list[TopoDS_Shell] = []
    explorer = TopExp_Explorer(shape, TopAbs_SHELL)
    while explorer.More():
        shells.append(topods.Shell(explorer.Current()))
        explorer.Next()
    if len(shells) != 1:
        raise _not_watertight(
            f"the given surfaces did not sew into a single connected shell (got {len(shells)})"
        )
    return shells[0]


def resolve_solid_from_surfaces_from_bodies(
    feature: SolidFromSurfacesFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The raw solid for `feature` - always either returns a real, checked-
    valid solid or raises `not_watertight` (see this module's own top
    docstring for the full Sewing -> ShapeFix -> MakeSolid -> OrientClosed
    Solid -> validity-check pipeline)."""
    if len(feature.surface_feature_ids) < 2:
        raise _not_watertight("SolidFromSurfacesFeature needs at least 2 surface_feature_ids")
    shapes = [
        _resolve_surface_feature_shape(part, surface_feature_id, bodies_so_far)
        for surface_feature_id in feature.surface_feature_ids
    ]
    sewn = sew_surfaces(shapes)
    shell = _single_shell(sewn)

    fixer = ShapeFix_Shell(shell)
    fixer.Perform()
    fixed_shell = fixer.Shell()

    solid_maker = BRepBuilderAPI_MakeSolid(fixed_shell)
    if not solid_maker.IsDone():
        raise _not_watertight("could not build a solid from the sewn surfaces")
    solid = solid_maker.Solid()
    breplib.OrientClosedSolid(solid)

    if solid is None or solid.IsNull() or not BRepCheck_Analyzer(solid).IsValid():
        raise _not_watertight("the resulting solid failed validity checks")

    volume_props = GProp_GProps()
    brepgprop.VolumeProperties(solid, volume_props)
    if volume_props.Mass() <= 0:
        raise _not_watertight("the resulting solid has zero or negative volume")

    return solid


def resolve_solid_from_surfaces(
    part: Part, feature: SolidFromSurfacesFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.thicken.resolve_thicken`'s own self-exclusion convention
    exactly."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_solid_from_surfaces_from_bodies(feature, part, bodies, all_excluded)
