"""OCCT geometry construction for `ThickenFeature` - Phase 2 surfacing
package, first of four surface-consuming tools (Thicken/Knit Surfaces/Solid
from Surfaces/Offset Surface). Thickens the shell produced by an existing
upstream surface-producing Feature into a brand-new, standalone solid Body,
via `app.document.loft.thicken_shell_to_solid` (the Phase-0-extracted
function `LoftFeature`'s own thin/open-chain path already uses, including
its own volume-sign fixup) - not reimplemented here, matching this
codebase's "shared low-level primitives live in a neutral/source module,
never cross-imported between sibling Feature modules" convention (`app.
document.loft` is the proven source for this one, the same way `app.
document.surface_ops` is for Knit Surfaces/Solid from Surfaces).

**Verification status**: like every other genuinely new OCCT technique in
this project, this module needs a real on-device/CI pass before being
trusted - this repo's dev sandbox has never had `pythonocc-core` installed."""

from fastapi import HTTPException
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import compute_part_bodies
from app.document.graph import resolve_feature_produces
from app.document.loft import thicken_shell_to_solid
from app.document.models import Part, Produces, ThickenFeature


def _invalid_surface_feature_ref(surface_feature_id: str, detail: str) -> HTTPException:
    """`surface_feature_id` doesn't resolve to a real, currently-computable
    `Produces.SURFACE` Feature in this Part - a stale/deleted/wrong-type
    reference, mirrors every other tool's own "structurally-valid-looking
    reference that doesn't actually resolve" 422 convention."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "invalid_surface_feature_ref",
            "surface_feature_id": surface_feature_id,
            "detail": detail,
        },
    )


def _thicken_failed(detail: str) -> HTTPException:
    """A structurally-valid surface source that OCCT nonetheless couldn't
    thicken - mirrors `app.document.loft._loft_failed`'s own "resolvable
    parameters, unresolvable geometry" distinction. Wraps `app.document.
    loft.thicken_shell_to_solid`'s own `ValueError`."""
    return HTTPException(status_code=422, detail={"type": "thicken_failed", "detail": detail})


def resolve_surface_feature_shape(
    part: Part, surface_feature_id: str, bodies_so_far: dict[str, TopoDS_Shape]
) -> TopoDS_Shape:
    """Resolves `surface_feature_id` to its live shape in `bodies_so_far` -
    shared resolution shape every Phase 2 surface-consuming tool uses
    (Thicken/Knit Surfaces/Solid from Surfaces/Offset Surface each call an
    equivalent of this in their own module, not cross-imported from here,
    matching this codebase's own "no sibling-Feature-module internals
    reuse" convention - kept as one function per module rather than a
    shared one since each call site's own error type/detail differs
    slightly). Validates the referenced Feature exists and currently
    `produces == Produces.SURFACE`, then fetches its shape from `bodies_
    so_far` (raises if missing - a stale reference that resolved
    structurally but has no live shape, e.g. its own upstream Sketch was
    deleted)."""
    source_feature = part.get_feature(surface_feature_id)
    if source_feature is None or resolve_feature_produces(source_feature, part) != Produces.SURFACE:
        raise _invalid_surface_feature_ref(
            surface_feature_id, "does not refer to a surface-producing Feature in this Part"
        )
    shape = bodies_so_far.get(surface_feature_id)
    if shape is None:
        raise _invalid_surface_feature_ref(surface_feature_id, "could not be resolved to a live shape")
    return shape


def resolve_thicken_from_bodies(
    feature: ThickenFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The raw thickened solid for `feature` - a Thicken has exactly one
    required input, no legitimate "temporarily nothing to build" state to
    tolerate (mirrors `app.document.loft.resolve_loft_from_bodies`'s own
    "always raise" reasoning), so this always either returns a real solid
    or raises."""
    shell = resolve_surface_feature_shape(part, feature.surface_feature_id, bodies_so_far)
    try:
        return thicken_shell_to_solid(shell, feature.thickness)
    except ValueError as exc:
        raise _thicken_failed(str(exc)) from None


def resolve_thicken(
    part: Part, feature: ThickenFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.loft.resolve_loft`'s own self-exclusion convention
    exactly (computes `bodies` as if `feature` weren't in `part.features`
    yet)."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_thicken_from_bodies(feature, part, bodies, all_excluded)
