"""OCCT geometry construction for `RevolveSurfaceFeature` - the Revolve-
Surface counterpart of `app.document.surface`'s own Extrude-Surface
construction: mirrors `SurfaceFeature`'s closed-or-open-wire tolerance
exactly (try a closed profile first via `app.sketch.profile.detect_profile`,
fall back to a single open chain via `detect_open_chain`/`app.document.loft.
wire_for_open_chain` only when no closed profile exists at all), but
revolves the resolved wire around an axis (`app.document.revolve._resolve_
axis`, reused verbatim) instead of prismming it along a direction -
`BRepPrimAPI_MakeRevol(wire, axis, angle)` applied to a bare wire (not a
face, the way `app.document.revolve.resolve_revolve_from_bodies` uses it)
produces a `TopoDS_Shell`, not a `TopoDS_Solid` - the same "revolve of a
wire vs. of a face" split `app.document.surface`'s own "prism of a wire vs.
of a face" split already establishes for Extrude Surface vs. `ExtrudeFeature`.

Unlike `SurfaceFeature`, a genuine geometric revolve failure
(`BRepPrimAPI_MakeRevol.IsDone()` returning false) is possible here (a
`BRepPrimAPI_MakePrism` call has no equivalent exposed failure mode) -
raised as a structured `revolve_surface_failed` 422, mirroring `app.
document.revolve._revolve_failed`'s identical convention. A missing/broken
backing Sketch (no closed profile, no open chain either) is instead
tolerated by returning `None` from `resolve_revolve_surface_from_bodies` -
the same "skip, don't fail the whole /mesh request" resilience `app.
document.surface.resolve_surface_from_bodies` already gives `SurfaceFeature`
for topology drift; `app.document.extrude.compute_part_bodies`'s own
`RevolveSurfaceFeature` branch additionally catches a genuine `invalid_
axis_ref`/`revolve_surface_failed` broadly, the same blanket tolerance its
own `RevolveFeature` branch already has. `resolve_revolve_surface` (the
router's own eager-resolve entry point) raises instead of returning `None`,
since a brand-new Feature with nothing to revolve is a real create/update
failure, not topology drift to be tolerated later."""

import logging
import math

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeRevol
from OCC.Core.gp import gp_Ax1
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, TopoDS_Wire

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    compute_part_bodies,
    select_profiles,
    wire_for_profile,
)
from app.document.loft import wire_for_open_chain
from app.document.models import Part, RevolveSurfaceFeature, SketchFeature
from app.document.revolve import _resolve_axis
from app.sketch.profile import OpenChainStatus, ProfileStatus, detect_open_chain, detect_profile
from app.sketch.store import get_sketch_or_404

logger = logging.getLogger(__name__)


def _revolve_surface_failed() -> HTTPException:
    """`BRepPrimAPI_MakeRevol.IsDone()` returned false - mirrors `app.
    document.revolve._revolve_failed`'s identical convention, its own
    distinct `type` string per this package's "never reuse another tool's
    error type" rule."""
    return HTTPException(status_code=422, detail={"type": "revolve_surface_failed"})


def _revolve_shell_for_wire(wire: TopoDS_Wire, axis: gp_Ax1, angle_radians: float) -> TopoDS_Shape:
    """One wire, revolved by `angle_radians` about `axis` - the Revolve
    Surface counterpart of `app.document.revolve.resolve_revolve_from_
    bodies`'s own per-profile `BRepPrimAPI_MakeRevol(face, axis, angle)`
    call, applied to a bare wire instead of a face so the result is a
    `TopoDS_Shell`, not a `TopoDS_Solid`."""
    revol_maker = BRepPrimAPI_MakeRevol(wire, axis, angle_radians)
    if not revol_maker.IsDone():
        raise _revolve_surface_failed()
    return revol_maker.Shape()


def resolve_revolve_surface_from_bodies(
    feature: RevolveSurfaceFeature,
    sketch_feature: SketchFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """The real OCCT shell(s) for one `RevolveSurfaceFeature`, or `None` if
    its backing Sketch currently has no usable wire (neither a closed/
    MultiProfile profile nor a single open chain) - callers skip rather
    than error in that case, mirroring `app.document.surface.resolve_
    surface_from_bodies`'s identical tolerance.

    Tries a closed profile first - the common case, and the only one
    `feature.profile_refs` applies to (mirrors `SurfaceFeature`'s own
    scoping). Falls back to a single open chain only when the Sketch has no
    usable closed profile at all."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    axis = _resolve_axis(part, feature.axis_ref, bodies_so_far, excluded_feature_ids)
    angle_radians = math.radians(feature.angle)

    result = detect_profile(sketch)
    if result.status in EXTRUDABLE_STATUSES:
        expanded_sketch = sketch.expand_pattern_and_mirror_instances()
        candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
        profiles = select_profiles(candidates, feature.profile_refs)
        shells = [
            _revolve_shell_for_wire(wire_for_profile(expanded_sketch, profile, basis), axis, angle_radians)
            for profile in profiles
        ]
        if len(shells) == 1:
            return shells[0]
        builder = BRep_Builder()
        compound = TopoDS_Compound()
        builder.MakeCompound(compound)
        for shell in shells:
            builder.Add(compound, shell)
        return compound

    open_result = detect_open_chain(sketch)
    if open_result.status == OpenChainStatus.SINGLE_CHAIN:
        expanded_sketch = sketch.expand_pattern_and_mirror_instances()
        wire = wire_for_open_chain(expanded_sketch, open_result.chain, basis)
        return _revolve_shell_for_wire(wire, axis, angle_radians)

    logger.warning(
        "Skipping RevolveSurfaceFeature %s: sketch %s has no closed profile (status=%s) "
        "or open chain (status=%s) to revolve",
        feature.id,
        sketch.id,
        result.status.value,
        open_result.status.value,
    )
    return None


def resolve_revolve_surface(
    part: Part, feature: RevolveSurfaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation -
    computes `bodies` *as if `feature` weren't in `part.features` yet*,
    mirroring `app.document.revolve.resolve_revolve`'s own self-exclusion
    convention exactly. Unlike `resolve_revolve_surface_from_bodies`, this
    always raises rather than returning `None` - a brand-new/edited Feature
    with nothing usable to revolve is a real validation failure at create/
    update time, not topology drift to be tolerated later."""
    sketch_feature = part.get_feature(feature.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="sketch_feature_id does not refer to a SketchFeature in this Part",
        )
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    shape = resolve_revolve_surface_from_bodies(feature, sketch_feature, part, bodies, all_excluded)
    if shape is None:
        raise HTTPException(
            status_code=422,
            detail={
                "type": "revolve_surface_failed",
                "detail": "sketch has no closed profile or open chain to revolve",
            },
        )
    return shape
