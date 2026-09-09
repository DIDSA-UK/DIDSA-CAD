"""OCCT geometry construction for `RuledSurfaceFeature` - a thin, UX-only
wrapper around `app.document.loft_surface`'s own construction (mirrors
`app.document.loft.LoftFeature`'s own docstring: at exactly 2 sections,
`ruled=True` vs `False` is geometrically identical - a spline fit through 2
points degenerates to the same result as a straight line - so the only real
difference this tool offers is UX: an exactly-2-pick tree entry with no
ruled toggle, no reference/alignment-point UI, no guide-curve UI).

Builds a scratch `LoftSurfaceFeature(sections=feature.sections, ruled=True,
guide_curve_refs=[])` sharing this Feature's own id, and delegates entirely
to `app.document.loft_surface.resolve_loft_surface_from_bodies` - not a
reimplementation. The router enforces `sections` has exactly 2 entries
(`_validate_ruled_surface_sections`); `LoftSection.reference_point`/
`.alignment_point` are always `None` on both (the schema layer doesn't even
expose those two fields for a Ruled Surface's own section shape - see
`app.document.schemas.RuledSurfaceSectionSchema`).

A genuine construction failure here surfaces with whichever `type` string
`app.document.loft_surface` itself raises (`invalid_loft_surface_section`/
`loft_surface_failed`) - deliberately not rewrapped, since the underlying
failure genuinely *is* a Loft Surface construction failure (this tool
shares that construction verbatim); only the "wrong number of sections"
precondition, which is specific to this tool's own exactly-2 UX contract,
gets its own distinct `invalid_ruled_surface_sections` type."""

from fastapi import HTTPException
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import compute_part_bodies
from app.document.loft_surface import resolve_loft_surface_from_bodies
from app.document.models import LoftSurfaceFeature, Part, RuledSurfaceFeature


def _invalid_ruled_surface_sections(detail: str) -> HTTPException:
    """`RuledSurfaceFeature.sections` must have exactly 2 entries - own
    distinct `type` string per this package's own convention (never reused
    from `app.document.loft._invalid_loft_section`/`app.document.loft_
    surface._invalid_loft_surface_section`, both of which allow 2+)."""
    return HTTPException(status_code=422, detail={"type": "invalid_ruled_surface_sections", "detail": detail})


def resolve_ruled_surface_from_bodies(
    feature: RuledSurfaceFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The raw ruled-lofted shell for `feature` - delegates entirely to
    `app.document.loft_surface.resolve_loft_surface_from_bodies` via a
    scratch `LoftSurfaceFeature`, discarding that call's own non-blocking
    self-intersection warnings (not meaningful for a 2-section ruled
    surface - see this module's own docstring)."""
    if len(feature.sections) != 2:
        raise _invalid_ruled_surface_sections(f"a Ruled Surface needs exactly 2 sections, got {len(feature.sections)}")
    scratch = LoftSurfaceFeature(id=feature.id, sections=feature.sections, ruled=True, guide_curve_refs=[])
    shell, _warnings = resolve_loft_surface_from_bodies(scratch, part, bodies_so_far, excluded_feature_ids)
    return shell


def resolve_ruled_surface(
    part: Part, feature: RuledSurfaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.loft_surface.resolve_loft_surface`'s own self-exclusion
    convention exactly."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_ruled_surface_from_bodies(feature, part, bodies, all_excluded)
