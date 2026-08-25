"""OCCT geometry construction for `SurfaceFeature` - the non-solid
counterpart to `app.document.extrude`'s own `ExtrudeFeature` construction
(see that class's own docstring): "Extrude but a shell instead of a
solid" - no Boss/Cut, no `target_body_ids`, always a brand-new, standalone
Surface.

Builds a `TopoDS_Shell` (or a `TopoDS_Compound` of several, for a
MultiProfile Sketch - see `resolve_surface_from_bodies`) by applying OCCT
`BRepPrimAPI_MakePrism` directly to a Sketch wire rather than to a face -
prism-of-a-wire produces a `TopoDS_Shell`, prism-of-a-face produces a
`TopoDS_Solid` (`app.document.extrude._prism_for_profile`'s own overload) -
this is the one real difference between this module and `_prism_for_
profile`. The wire itself comes from either `app.document.extrude.
wire_for_profile` (a closed profile, or one of a MultiProfile's own outer
loops - the common case, sharing `ExtrudeFeature.profile_refs`' identical
selection machinery) or `app.document.loft.wire_for_open_chain` (a single
open chain - mirrors `app.document.loft`'s own, more conservative
open-chain scoping: no profile selection, at most one candidate).
"""

import logging

from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.gp import gp_Dir, gp_Trsf, gp_Vec
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, TopoDS_Wire

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    basis_normal,
    select_profiles,
    wire_for_profile,
)
from app.document.loft import wire_for_open_chain
from app.document.models import Part, ResolvedPlane, SketchFeature, SurfaceFeature
from app.document.pattern import direction_vector
from app.sketch.profile import OpenChainStatus, ProfileStatus, detect_open_chain, detect_profile
from app.sketch.store import get_sketch_or_404

logger = logging.getLogger(__name__)


def _resolve_direction(
    part: Part,
    feature: SurfaceFeature,
    basis: ResolvedPlane,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> gp_Dir:
    """The world-space direction `feature` extrudes along - `None` (the
    default) is normal to the backing Sketch's own host plane, exactly
    `ExtrudeFeature`'s implicit direction; a real `direction_ref` resolves
    through `app.document.pattern.direction_vector`, the identical helper
    `PatternFeature.direction_1`/`direction_2` already use for the same
    `PatternDirectionRef` type."""
    if feature.direction_ref is None:
        return basis_normal(basis)
    return direction_vector(part, bodies_so_far, feature.direction_ref, excluded_feature_ids)


def _prism_shell_for_wire(wire: TopoDS_Wire, direction: gp_Dir, feature: SurfaceFeature) -> TopoDS_Shape:
    """One wire, moved to `feature.start_distance` along `direction` and
    prismmed the remaining span to `feature.end_distance` - the Surface
    counterpart of `app.document.extrude._prism_for_profile`, prismming the
    bare wire itself (yielding a `TopoDS_Shell`) rather than a face
    (`_prism_for_profile`'s own `TopoDS_Solid` result)."""
    vector = gp_Vec(direction.X(), direction.Y(), direction.Z())

    start_transform = gp_Trsf()
    start_transform.SetTranslation(vector.Multiplied(feature.start_distance))
    moved_wire = BRepBuilderAPI_Transform(wire, start_transform, True).Shape()

    prism_vector = vector.Multiplied(feature.end_distance - feature.start_distance)
    return BRepPrimAPI_MakePrism(moved_wire, prism_vector).Shape()


def resolve_surface_from_bodies(
    feature: SurfaceFeature,
    sketch_feature: SketchFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """The real OCCT shell(s) for one `SurfaceFeature`, or `None` if its
    backing Sketch currently has no usable wire (neither a closed/
    MultiProfile profile nor a single open chain) - callers skip rather
    than error in that case, mirroring `app.document.extrude._solid_for_
    extrude_feature`'s identical "a stale/edited-away profile shouldn't
    fail the whole mesh request" tolerance.

    Tries a closed profile first (`app.sketch.profile.detect_profile`) -
    the common case, and the only one `feature.profile_refs` applies to
    (see `SurfaceFeature`'s own docstring): a MultiProfile Sketch produces
    one shell per selected outer profile (`app.document.extrude.
    select_profiles`), combined into a single `TopoDS_Compound` when there
    is more than one, exactly `_solid_for_extrude_feature`'s own MultiProfile
    handling. Falls back to a single open chain (`app.sketch.profile.
    detect_open_chain`) only when the Sketch has no usable closed profile at
    all - `profile_refs` has no open-chain analogue (mirrors `app.document.
    loft`'s own, more conservative open-chain scoping), so it is simply
    ignored on that path."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    direction = _resolve_direction(part, feature, basis, bodies_so_far, excluded_feature_ids)

    result = detect_profile(sketch)
    if result.status in EXTRUDABLE_STATUSES:
        # Sketcher-roadmap Phase 7 (2D Pattern/Mirror): see extrude.py's
        # identical call site for why this re-expansion is needed - a
        # no-instance Sketch is a no-op, returning the same object.
        expanded_sketch = sketch.expand_pattern_and_mirror_instances()
        candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
        profiles = select_profiles(candidates, feature.profile_refs)
        shells = [
            _prism_shell_for_wire(wire_for_profile(expanded_sketch, profile, basis), direction, feature)
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
        return _prism_shell_for_wire(wire, direction, feature)

    logger.warning(
        "Skipping SurfaceFeature %s: sketch %s has no closed profile (status=%s) "
        "or open chain (status=%s) to extrude",
        feature.id,
        sketch.id,
        result.status.value,
        open_result.status.value,
    )
    return None
