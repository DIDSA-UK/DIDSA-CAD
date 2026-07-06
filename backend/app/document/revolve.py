"""OCCT geometry construction for RevolveFeature (Prompt F) - the Revolve
module described in the project brief's section 4.4, kept separate from
app.document.router the same way app.document.extrude/fillet/chamfer already
are.

Boss/Cut parity with Extrude (Prompt F's own resolved decision, not
re-litigated here): a RevolveFeature's raw solid (`resolve_revolve_from_bodies`
below) is combined with `target_body_ids` by the exact same fuse/cut/register
dispatch `app.document.extrude.compute_part_bodies` already uses for
ExtrudeFeature (see `app.document.extrude._apply_boss_or_cut`, shared rather
than duplicated) - this module only builds the raw revolved solid, mirroring
`app.document.extrude._solid_for_extrude_feature`'s own contract (return
`None` if the backing Sketch has no extrudable/revolvable profile).

Imported from app.document.extrude's own compute_part_bodies via a
function-local import (see that function's own doc comment), the same
circular-import avoidance app.document.fillet/chamfer already use: this
module needs compute_part_bodies/face_for_profile/EXTRUDABLE_STATUSES from
extrude.py at module level, so extrude.py cannot import this module back at
its own module level.
"""

import logging
import math

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeRevol
from OCC.Core.gp import gp_Ax1, gp_Dir, gp_Vec
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    basis_point_to_world,
    compute_part_bodies,
    face_for_profile,
)
from app.document.graph import sketch_feature_id_for_sketch
from app.document.models import Part, RevolveFeature, SketchFeature
from app.sketch.models import Line, SketchEntityRef, SketchEntityType
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity

logger = logging.getLogger(__name__)


def _invalid_axis_ref(ref: SketchEntityRef) -> HTTPException:
    """Prompt F: the structured `invalid_axis_ref` error for an `axis_ref`
    that cannot be used as a Revolve axis - covers every way this can fail:
    the entity doesn't exist, exists but isn't a Line (Point/Circle are
    invalid axis references per Prompt F's own resolved decision), or is a
    degenerate (zero-length) Line. Deliberately its own structured error
    rather than reusing `app.sketch.store`'s generic `missing_reference`
    (used for a plain unresolvable `SketchEntityRef`) - a client can tell
    "this ref doesn't resolve to anything at all" apart from "this ref
    resolves, just not to something usable as an axis", per the prompt's own
    explicit error-type list."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "invalid_axis_ref",
            "sketch_id": ref.sketch_id,
            "entity_type": ref.entity_type.value,
            "entity_id": ref.entity_id,
        },
    )


def _revolve_failed() -> HTTPException:
    """Prompt F: `BRepPrimAPI_MakeRevol.IsDone()` returned false - a
    geometric failure (the axis passes through the Profile in a way that
    self-intersects the swept solid, etc.), not a malformed reference. 422,
    matching `app.document.fillet._fillet_failed`/`app.document.chamfer.
    _chamfer_failed`'s identical "structured error, not an uncaught OCCT
    exception surfacing as a 500" convention."""
    return HTTPException(status_code=422, detail={"type": "revolve_failed"})


def _resolve_axis(
    part: Part,
    ref: SketchEntityRef,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> gp_Ax1:
    """The world-space `gp_Ax1` `ref` resolves to - `ref`'s Sketch is *not*
    required to be the same Sketch as the Profile being revolved (Prompt
    F's own confirmed decision), so it's resolved entirely independently:
    its own owning SketchFeature, its own basis (fixed or custom plane, via
    `app.document.create_plane.resolve_sketch_basis` - the same recursive,
    `bodies_so_far`-aware resolution `app.document.extrude._solid_for_
    extrude_feature` already uses for the Profile's own Sketch), and the
    Line's two endpoints mapped through that basis. An axis Line that
    happens to be one of the Profile's own entities (Prompt F's other
    confirmed decision: this is allowed, no special-case rejection) needs
    no different handling here at all - it's just another Line to resolve.

    Fails closed with `invalid_axis_ref` (never a generic `missing_reference`
    or an uncaught OCCT exception) for every way `ref` can be unusable as an
    axis: wrong `entity_type`, an unresolvable Point/Line/Circle lookup, no
    SketchFeature owning `ref.sketch_id` in this Part, or a degenerate
    (zero-length) Line."""
    if ref.entity_type != SketchEntityType.LINE:
        raise _invalid_axis_ref(ref)
    try:
        entity = resolve_sketch_entity(ref)
    except HTTPException:
        raise _invalid_axis_ref(ref) from None
    if not isinstance(entity, Line):
        raise _invalid_axis_ref(ref)

    axis_sketch_feature_id = sketch_feature_id_for_sketch(part, ref.sketch_id)
    axis_sketch_feature = part.get_feature(axis_sketch_feature_id) if axis_sketch_feature_id else None
    if not isinstance(axis_sketch_feature, SketchFeature):
        raise _invalid_axis_ref(ref)

    sketch = get_sketch_or_404(ref.sketch_id)
    basis = resolve_sketch_basis(part, axis_sketch_feature, bodies_so_far, excluded_feature_ids)
    start = sketch.points[entity.start_point_id]
    end = sketch.points[entity.end_point_id]
    origin = basis_point_to_world(basis, start.x, start.y)
    end_world = basis_point_to_world(basis, end.x, end.y)
    direction = gp_Vec(origin, end_world)
    if direction.Magnitude() < 1e-9:
        raise _invalid_axis_ref(ref)
    return gp_Ax1(origin, gp_Dir(direction))


def resolve_revolve_from_bodies(
    feature: RevolveFeature,
    sketch_feature: SketchFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """The raw revolved solid for `feature`, or `None` if its backing Sketch
    no longer has a revolvable profile - mirrors `app.document.extrude.
    _solid_for_extrude_feature`'s own contract exactly (callers skip rather
    than error, per the same "a stale/edited-away profile shouldn't fail the
    whole mesh request" reasoning).

    Boss/Cut dispatch (fusing/cutting the returned solid into `bodies_so_far`)
    is the caller's job - see `app.document.extrude._apply_boss_or_cut`,
    shared with `ExtrudeFeature` - not this function's, since that logic is
    identical regardless of which Feature type produced the new solid.

    A MultiProfile Sketch (disjoint outer loops, C2) produces one revolved
    solid per sub-profile, combined into a `TopoDS_Compound` - transparent to
    every caller, exactly like `_solid_for_extrude_feature`'s own MultiProfile
    handling."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    if result.status not in EXTRUDABLE_STATUSES:
        logger.warning(
            "Skipping RevolveFeature %s: sketch %s has no closed profile (status=%s)",
            feature.id,
            sketch.id,
            result.status.value,
        )
        return None

    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    axis = _resolve_axis(part, feature.axis_ref, bodies_so_far, excluded_feature_ids)
    angle_radians = math.radians(feature.angle)

    if result.status == ProfileStatus.CLOSED_LOOP:
        assert result.profile is not None
        profiles = [result.profile]
    else:
        profiles = result.loops

    solids = []
    for profile in profiles:
        face = face_for_profile(sketch, profile, basis)
        revol_maker = BRepPrimAPI_MakeRevol(face, axis, angle_radians)
        if not revol_maker.IsDone():
            raise _revolve_failed()
        solids.append(revol_maker.Shape())

    if len(solids) == 1:
        return solids[0]

    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    for solid in solids:
        builder.Add(compound, solid)
    return compound


def resolve_revolve(
    part: Part, feature: RevolveFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape | None:
    """Fresh entry point for the router's create/update validation - computes
    `bodies` *as if `feature` weren't in `part.features` yet* (excludes its
    own id in addition to whatever the caller already excludes), mirroring
    `app.document.fillet.resolve_fillet`'s self-exclusion convention. Needed
    here for the same reason it's needed there even though Revolve is
    Boss/Cut-shaped (not an in-place modify like Fillet/Chamfer): re-
    validating an *edit* to an existing Revolve must be checked against its
    target Body's shape *before* this Revolve's own (about-to-be-replaced)
    Boss/Cut effect, not stacked on top of it - without this, `compute_part_
    bodies` would apply this Revolve's *old* angle/axis/mode to its target(s)
    before this function ever got a chance to validate the *candidate* one
    against them. A brand-new Feature (not yet in `part.features`) is
    unaffected - its id isn't there to exclude in the first place."""
    sketch_feature = part.get_feature(feature.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="sketch_feature_id does not refer to a SketchFeature in this Part",
        )
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_revolve_from_bodies(feature, sketch_feature, part, bodies, all_excluded)
