"""OCCT geometry construction for `SweptSurfaceFeature` - the Swept-Surface
counterpart of `app.document.sweep`'s own `SweepFeature` construction:
reuses `app.document.sweep.resolve_path_wire` verbatim for path resolution,
but builds an open shell via `BRepOffsetAPI_MakePipeShell` (never calling
`.MakeSolid()`, the step that caps a pipe's ends into a solid - see `app.
document.sweep._sweep_wire`'s own setup, this module diverges only at that
one call) instead of a solid.

On-device feedback ("swept surface should support an open profile sketch"):
unlike `SweepFeature`, this module never calls `.MakeSolid()` and
`_shell_for_wire` below has no dependency at all on `wire` being closed
(`BRepOffsetAPI_MakePipeShell.Add` sweeps an open wire into an open shell
exactly as readily as a closed one) - the closed-profile-only gate this
module originally inherited from Sweep's own `EXTRUDABLE_STATUSES` was
therefore stricter than the actual OCCT operation needs, not a real
limitation. Prefers a closed Profile (`EXTRUDABLE_STATUSES`) when the
Sketch has one, exactly as before; falls back to a single open chain
(`app.sketch.profile.detect_open_chain`, reusing `app.document.loft.
wire_for_open_chain` - the exact same open-chain wire builder the thin/
open-chain Loft path already uses) when it doesn't. `feature.profile_refs`
(multi-profile disambiguation) has no open-chain analogue - mirrors `app.
document.loft._resolve_open_section`'s own "a sketch with 2+ disjoint open
chains is ambiguous, reject" scoping, rather than trying to extend it.

v1 scope (mirrors `app.document.loft._resolve_closed_section`'s own
identical guard): a *closed* profile with inner loops (holes) is rejected
outright - `SweepFeature`'s own hollow-profile handling boolean-cuts two
independently swept *solids* together, which has no shell equivalent (there
is no "subtract one open shell from another" operation). An open chain has
no holes concept at all, so this guard is moot for the open-chain path."""

import logging

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_RightCorner
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakePipeShell
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, TopoDS_Wire

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    compute_part_bodies,
    select_profiles,
    wire_for_profile,
)
from app.document.loft import wire_for_open_chain
from app.document.models import Part, SketchFeature, SweptSurfaceFeature
from app.document.sweep import resolve_path_wire
from app.sketch.profile import OpenChainStatus, ProfileStatus, detect_open_chain, detect_profile
from app.sketch.store import get_sketch_or_404

logger = logging.getLogger(__name__)


def _swept_surface_failed() -> HTTPException:
    """`BRepOffsetAPI_MakePipeShell.IsDone()` returned false - mirrors
    `app.document.sweep._sweep_failed`'s own convention, its own distinct
    `type` string (never `sweep_failed` - a different tool's error)."""
    return HTTPException(status_code=422, detail={"type": "swept_surface_failed"})


def _swept_surface_holes_unsupported() -> HTTPException:
    """v1 scope: a Swept Surface profile with inner loops (holes) has no
    shell equivalent for `SweepFeature`'s own hollow-profile boolean-cut
    technique (there is no "subtract one open shell from another"
    operation) - mirrors `app.document.loft._resolve_closed_section`'s own
    "profile with holes is not supported (v1 scope)" guard, its own
    distinct `type` string."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "swept_surface_holes_unsupported",
            "detail": "a profile with holes is not supported as a Swept Surface profile (v1 scope)",
        },
    )


def _shell_for_wire(path_wire: TopoDS_Wire, wire: TopoDS_Wire) -> TopoDS_Shape:
    """Sweeps `wire` along `path_wire` into an open shell - mirrors `app.
    document.sweep._sweep_wire`'s own setup exactly, diverging only at the
    point a solid-vs-shell result is decided: no `.MakeSolid()` call here."""
    pipe_maker = BRepOffsetAPI_MakePipeShell(path_wire)
    pipe_maker.SetTransitionMode(BRepBuilderAPI_RightCorner)
    pipe_maker.Add(wire)
    pipe_maker.Build()
    if not pipe_maker.IsDone():
        raise _swept_surface_failed()
    return pipe_maker.Shape()


def resolve_swept_surface_from_bodies(
    feature: SweptSurfaceFeature,
    sketch_feature: SketchFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """The real OCCT shell(s) for one `SweptSurfaceFeature`, or `None` if
    its backing Sketch no longer has a closed profile or a single open
    chain to sweep - callers skip rather than error in that case, mirroring
    `app.document.surface.resolve_surface_from_bodies`'s identical
    tolerance. A *closed* profile with holes always raises `swept_surface_
    holes_unsupported` rather than being tolerated - that is a structural
    v1-scope limitation, not topology drift (see this module's own doc
    comment for why an open chain has no holes concept to trip this at
    all)."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    # Only probed when there's no closed profile to use - keeps the common
    # (closed-profile) case from paying for an open-chain detection pass it
    # will never use.
    open_result = None if result.status in EXTRUDABLE_STATUSES else detect_open_chain(sketch)
    is_open_chain = open_result is not None and open_result.status == OpenChainStatus.SINGLE_CHAIN
    if result.status not in EXTRUDABLE_STATUSES and not is_open_chain:
        logger.warning(
            "Skipping SweptSurfaceFeature %s: sketch %s has no closed profile or single open "
            "chain (closed status=%s, open status=%s)",
            feature.id,
            sketch.id,
            result.status.value,
            open_result.status.value if open_result is not None else "n/a",
        )
        return None
    # Sketcher-roadmap Phase 7 (2D Pattern/Mirror): see extrude.py's
    # identical call site for why this re-expansion is needed here too.
    sketch = sketch.expand_pattern_and_mirror_instances()

    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    # `resolve_path_wire`'s second element (a fixed-binormal direction for
    # the closed Circle/Ellipse path case - see `app.document.sweep.
    # _sweep_wire`'s own doc comment) is `app.document.sweep`'s own fix for
    # a Sweep-specific defect; not yet applied here, so intentionally
    # discarded rather than threaded through this module's own
    # `_swept_surface_wire`-equivalent pipe-shell call.
    path_wire, _fixed_binormal = resolve_path_wire(part, feature.path_refs, bodies_so_far, excluded_feature_ids)

    if result.status in EXTRUDABLE_STATUSES:
        if result.status == ProfileStatus.CLOSED_LOOP:
            assert result.profile is not None
            candidates = [result.profile]
        else:
            candidates = result.loops
        profiles = select_profiles(candidates, feature.profile_refs)

        for profile in profiles:
            if profile.inner_loops:
                raise _swept_surface_holes_unsupported()

        shells = [_shell_for_wire(path_wire, wire_for_profile(sketch, profile, basis)) for profile in profiles]
    else:
        assert open_result is not None and open_result.chain is not None
        shells = [_shell_for_wire(path_wire, wire_for_open_chain(sketch, open_result.chain, basis))]

    if len(shells) == 1:
        return shells[0]
    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    for shell in shells:
        builder.Add(compound, shell)
    return compound


def resolve_swept_surface(
    part: Part, feature: SweptSurfaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.sweep.resolve_sweep`'s own self-exclusion convention
    exactly. Unlike `resolve_swept_surface_from_bodies`, this always raises
    rather than returning `None` - a brand-new/edited Feature with nothing
    usable to sweep is a real validation failure at create/update time, not
    topology drift to be tolerated later."""
    sketch_feature = part.get_feature(feature.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="sketch_feature_id does not refer to a SketchFeature in this Part",
        )
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    shape = resolve_swept_surface_from_bodies(feature, sketch_feature, part, bodies, all_excluded)
    if shape is None:
        raise HTTPException(
            status_code=422,
            detail={"type": "swept_surface_failed", "detail": "sketch has no closed profile to sweep"},
        )
    return shape
