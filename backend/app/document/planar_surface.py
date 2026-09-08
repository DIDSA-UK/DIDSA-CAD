"""OCCT geometry construction for `PlanarSurfaceFeature` - simplest of the
five new surface-producing tools added alongside Revolve/Swept/Loft/Ruled
Surface: a flat face (or, for a MultiProfile Sketch, a `TopoDS_Compound` of
several) straight from a closed Sketch Profile, via `app.document.extrude.
face_for_profile` verbatim (already handles inner-loop holes) - no prism/
revolve/sweep transform of any kind.

Unlike `SurfaceFeature`/`RevolveSurfaceFeature`, there is no open-chain
fallback here at all - `BRepBuilderAPI_MakeFace(wire)` needs a genuinely
closed wire, so this uses the same strict `EXTRUDABLE_STATUSES` gate
`app.document.router._require_closed_sketch_feature` already enforces for
Extrude/Revolve/Sweep/Swept Surface, not `SurfaceFeature`'s lenient one.

Follows `app.document.loft.resolve_loft_from_bodies`'s own "always raise,
never return None" contract (mirrors that module's own reasoning: a Loft
with an unresolvable section has no legitimate "temporarily nothing to
build" state to tolerate, and neither does a Planar Surface whose one
Sketch has drifted away from a closed profile) rather than `app.document.
surface.resolve_surface_from_bodies`'s own "return None, let the caller
skip" tolerance - `app.document.extrude.compute_part_bodies`'s own
`PlanarSurfaceFeature` branch is expected to catch this module's own narrow
`invalid_planar_surface_sketch` error type and skip with a warning, the
same "router validates eagerly, compute_part_bodies tolerates topology
drift narrowly" split `LoftFeature`'s own branch already uses."""

import logging

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    compute_part_bodies,
    face_for_profile,
    select_profiles,
)
from app.document.models import Part, PlanarSurfaceFeature, SketchFeature
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.store import get_sketch_or_404

logger = logging.getLogger(__name__)


def _invalid_planar_surface_sketch(feature_id: str, status: str) -> HTTPException:
    """A `PlanarSurfaceFeature` whose backing Sketch currently has no closed
    profile at all - mirrors `app.document.loft._invalid_loft_section`'s own
    "a structurally-required precondition failed" 422 shape, distinct `type`
    string per this package's own convention (never reused across tools)."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "invalid_planar_surface_sketch",
            "detail": f"sketch has no closed profile (status={status})",
        },
    )


def resolve_planar_surface_from_bodies(
    feature: PlanarSurfaceFeature,
    sketch_feature: SketchFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The real OCCT face(s) for one `PlanarSurfaceFeature` - always raises
    `invalid_planar_surface_sketch` rather than returning `None` when the
    backing Sketch has no usable closed profile (see this module's own
    docstring for why, unlike `SurfaceFeature`/`RevolveSurfaceFeature`, this
    doesn't tolerate that case by skipping silently).

    A MultiProfile Sketch (disjoint outer loops) produces one face per
    selected outer profile (`feature.profile_refs`, via `app.document.
    extrude.select_profiles` - empty means every one currently detected),
    combined into a single `TopoDS_Compound` when there is more than one -
    exactly `app.document.surface.resolve_surface_from_bodies`'s own
    MultiProfile handling, minus the prism step."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    # Sketcher-roadmap Phase 7 (2D Pattern/Mirror): see extrude.py's
    # identical call site for why this re-expansion is needed - a
    # no-instance Sketch is a no-op, returning the same object.
    sketch = sketch.expand_pattern_and_mirror_instances()
    if result.status not in EXTRUDABLE_STATUSES:
        raise _invalid_planar_surface_sketch(feature.id, result.status.value)

    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
    profiles = select_profiles(candidates, feature.profile_refs)

    faces = [face_for_profile(sketch, profile, basis) for profile in profiles]
    if len(faces) == 1:
        return faces[0]
    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    for face in faces:
        builder.Add(compound, face)
    return compound


def resolve_planar_surface(
    part: Part, feature: PlanarSurfaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation -
    computes `bodies` *as if `feature` weren't in `part.features` yet*,
    mirroring `app.document.revolve.resolve_revolve`'s own self-exclusion
    convention exactly."""
    sketch_feature = part.get_feature(feature.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="sketch_feature_id does not refer to a SketchFeature in this Part",
        )
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_planar_surface_from_bodies(feature, sketch_feature, part, bodies, all_excluded)
