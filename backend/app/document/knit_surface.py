"""OCCT geometry construction for `KnitSurfaceFeature` - Phase 2 surfacing
package, second of four surface-consuming tools. Sews 2+ existing upstream
surface Features into one shape via `app.document.surface_ops.sew_surfaces`
and stops there (unlike `app.document.solid_from_surfaces`, which continues
that same sewn result on to a solid) - a shared low-level primitive in a
neutral module, not one Feature module importing another's internals,
matching this codebase's existing pattern.

Note: `BRepBuilderAPI_Sewing.Perform()` has no hard failure mode the way
`ThruSections`/`MakeRevol` do - it always produces *something* (possibly
several disjoint pieces), never raising on its own. This module's eager
resolve therefore mainly catches a stale/invalid `surface_feature_ids`
reference, not a genuine geometric failure - `knit_failed` exists for
consistency with every other tool's own structured-error convention, but is
not expected to actually fire in practice.

**Verification status**: needs a real on-device/CI pass before being
trusted - this repo's dev sandbox has never had `pythonocc-core` installed."""

from fastapi import HTTPException
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import compute_part_bodies
from app.document.models import KnitSurfaceFeature, Part, Produces
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


def _knit_failed(detail: str) -> HTTPException:
    """See this module's own top docstring - kept for structured-error
    consistency, not expected to actually fire in practice since `Sewing.
    Perform()` has no hard failure mode."""
    return HTTPException(status_code=422, detail={"type": "knit_failed", "detail": detail})


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


def resolve_knit_surface_from_bodies(
    feature: KnitSurfaceFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The raw sewn shape for `feature` (a Shell or Compound, whatever
    `sew_surfaces` returns) - always either returns a real shape or raises,
    same "always raise, never return None" contract every Phase 2 tool in
    this package follows (see `ThickenFeature`'s own docstring)."""
    if len(feature.surface_feature_ids) < 2:
        raise _knit_failed("KnitSurfaceFeature needs at least 2 surface_feature_ids")
    shapes = [
        _resolve_surface_feature_shape(part, surface_feature_id, bodies_so_far)
        for surface_feature_id in feature.surface_feature_ids
    ]
    sewn = sew_surfaces(shapes)
    if sewn is None or sewn.IsNull():
        raise _knit_failed("sewing the given surfaces produced no result")
    return sewn


def resolve_knit_surface(
    part: Part, feature: KnitSurfaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.thicken.resolve_thicken`'s own self-exclusion convention
    exactly."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_knit_surface_from_bodies(feature, part, bodies, all_excluded)
