"""OCCT geometry construction for `GearChainFeature`
(`docs/gear-design/05-gear-chain-and-planetary.md`) - the OCCT-dependent
half of `app.document.gear_chain_math`'s pure positioning/interference
math, mirroring the `*_math.py`/OCCT-construction split every other gear
Feature module here keeps (`docs/gear-design/00-conventions.md`).

Reuses `app.document.gear`'s and `app.document.rack`'s own real internals
directly (`_gear_outline_wire`/`_gear_face`/`spur_gear_geometry` for a
gear member, `rack_outline_points`/`prism_solid_from_outline` for a rack
member) rather than re-deriving tooth construction - the same reuse this
workstream's own Spike 2 already established as the right approach
("built every solid via `app.document.gear`'s own real internals").

**Structural transition (Spike 2 findings, part 1)**: a compound stage's
`compound_merge=FUSE_INTO_ONE` join is checked by counting connected
solids after the fuse (reusing `app.document.extrude._explode_solids`
directly, no new topology code) - more than one solid is `00-conventions.
md`'s "no valid geometry to draw" BLOCKING exception, since the user asked
for one fused body and got none. A `KEEP_SEPARATE` axial overlap, and a
`FUSE_INTO_ONE` join whose fused volume comes up short of the two
members' own unfused volumes (silently-swallowed geometry), are both
non-blocking warnings instead - valid geometry, just surprising. A join
fillet was explicitly rejected by Spike 2 (convergence too narrow/
unpredictable) - not built here; see that spike's own "Optional join
fillet" section before reconsidering.

**Verification status**: like every other genuinely new OCCT technique in
this project, this module needs (and, per `docs/status.md`'s dated
entries, has received) a real on-device/CI pass against `pythonocc-core`
before being trusted - this repo's dev sandbox has never had it installed.
"""

import logging
import math
from dataclasses import replace

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Fuse
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Vec
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape

from app.document.create_plane import resolve_plane_ref
from app.document.extrude import _explode_solids, basis_normal, compute_part_bodies
from app.document.gear import _gear_face, _gear_outline_wire
from app.document.gear_chain_math import (
    ChainMemberKind,
    ChainMemberSpec,
    ChainStageSpec,
    GearGeometryError,
    ResolvedGearChain,
    compound_axial_overlap,
    meshing_phase_base,
    pitch_radius,
    propagate_meshing_phase,
    rack_meshing_phase_base,
    resolve_chain,
    thin_member_warning,
)
from app.document.gear_math import spur_gear_geometry
from app.document.models import (
    GearChainFeature,
    GearChainMemberSpec,
    GearChainMemberType,
    GearChainStage,
    GearGroup,
    MergeMode,
    Part,
    ResolvedPlane,
)
from app.document.rack import prism_solid_from_outline, rack_outline_points

logger = logging.getLogger(__name__)

_POINTS_PER_FLANK = 12


def _invalid_gear_chain_parameters(detail: str) -> HTTPException:
    """A chain parameter combination `gear_chain_math`/this module itself
    rejects - mirrors `app.document.gear._invalid_gear_parameters`'s own
    convention."""
    return HTTPException(status_code=422, detail={"type": "invalid_gear_chain_parameters", "detail": detail})


def _gear_chain_join_failed(stage_index: int, detail: str) -> HTTPException:
    """Spike 2's own resolution: a compound stage's `FUSE_INTO_ONE` join
    that comes back as more than one connected solid - `00-conventions.
    md`'s "no valid geometry to draw" BLOCKING exception (there is nothing
    sensible to register as "the" fused Body), not a soft warning."""
    return HTTPException(
        status_code=422,
        detail={"type": "gear_chain_compound_join_failed", "stage_index": stage_index, "detail": detail},
    )


def _gear_chain_failed(detail: str) -> HTTPException:
    return HTTPException(status_code=422, detail={"type": "gear_chain_failed", "detail": detail})


def _positioned_basis(basis: ResolvedPlane, x: float, y: float, z: float = 0.0, rotation: float = 0.0) -> ResolvedPlane:
    """A `ResolvedPlane` identical to `basis` except shifted by `(x, y)` in
    its own in-plane frame and `z` along its own normal, with its in-plane
    `x_axis`/`y_axis` rotated by `rotation` radians (CCW-positive) about
    that same normal. Mirrors `app.document.gear._twisted_basis`'s own
    shift-and-rotate construction (same rotation-matrix formula, same
    linearity argument for why embedding commutes with rotation),
    generalized from "shift along the normal only" (helical stacking) to
    "shift in-plane too" (one chain stage's own `(x, y)` position within
    its `plane_ref`)."""
    ox, oy, oz = basis.origin
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    nx, ny, nz = basis.normal
    shifted_origin = (
        ox + x * xx + y * yx + z * nx,
        oy + x * xy + y * yy + z * ny,
        oz + x * xz + y * yz + z * nz,
    )
    if rotation == 0.0:
        return replace(basis, origin=shifted_origin)
    cos_r, sin_r = math.cos(rotation), math.sin(rotation)
    rotated_x_axis = (cos_r * xx + sin_r * yx, cos_r * xy + sin_r * yy, cos_r * xz + sin_r * yz)
    rotated_y_axis = (-sin_r * xx + cos_r * yx, -sin_r * xy + cos_r * yy, -sin_r * xz + cos_r * yz)
    return replace(basis, origin=shifted_origin, x_axis=rotated_x_axis, y_axis=rotated_y_axis)


def _solid_volume(shape: TopoDS_Shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


def _member_to_math_spec(member: GearChainMemberSpec, group: GearGroup) -> ChainMemberSpec:
    return ChainMemberSpec(
        kind=ChainMemberKind(member.member_type.value),
        module=group.module,
        pressure_angle_degrees=group.pressure_angle_degrees,
        tooth_count=member.tooth_count,
        face_width=member.face_width,
        outer_diameter=member.outer_diameter,
    )


def _resolve_group(groups: dict[str, GearGroup], group_id: str) -> GearGroup:
    group = groups.get(group_id)
    if group is None:
        raise _invalid_gear_chain_parameters(f"group_id {group_id!r} does not refer to a group on this chain")
    return group


def _build_stage_specs(feature: GearChainFeature, groups: dict[str, GearGroup]) -> list[ChainStageSpec]:
    specs = []
    for stage in feature.stages:
        if stage.is_compound:
            group_a = _resolve_group(groups, stage.compound_member_a.group_id)
            group_b = _resolve_group(groups, stage.compound_member_b.group_id)
            specs.append(
                ChainStageSpec(
                    turn_angle_degrees=stage.turn_angle_degrees,
                    compound_member_a=_member_to_math_spec(stage.compound_member_a, group_a),
                    compound_member_b=_member_to_math_spec(stage.compound_member_b, group_b),
                )
            )
        else:
            group = _resolve_group(groups, stage.member.group_id)
            specs.append(
                ChainStageSpec(
                    turn_angle_degrees=stage.turn_angle_degrees,
                    member=_member_to_math_spec(stage.member, group),
                )
            )
    return specs


def _adjacent_group_id(stage: GearChainStage, *, outgoing: bool) -> str:
    if stage.is_compound:
        return stage.compound_member_b.group_id if outgoing else stage.compound_member_a.group_id
    return stage.member.group_id


def _validate_group_adjacency(feature: GearChainFeature) -> None:
    """Every meshing pair (consecutive stages, or one side of a compound
    join) must share a literal `group_id`, not just a coincidentally-equal
    module - `05-gear-chain-and-planetary.md`'s own "two stages can only
    mesh if they share a group" rule, which is what makes a mismatched-
    module pair *structurally* impossible to construct, not merely
    numerically guarded against."""
    for k in range(len(feature.stages) - 1):
        outgoing_id = _adjacent_group_id(feature.stages[k], outgoing=True)
        incoming_id = _adjacent_group_id(feature.stages[k + 1], outgoing=False)
        if outgoing_id != incoming_id:
            raise _invalid_gear_chain_parameters(
                f"stage {k} and stage {k + 1} must share a GearGroup to mesh (got {outgoing_id!r} and "
                f"{incoming_id!r})"
            )
    for i, stage in enumerate(feature.stages):
        if stage.is_compound and stage.compound_member_a.group_id == stage.compound_member_b.group_id:
            raise _invalid_gear_chain_parameters(
                f"compound stage {i}'s two members must use different groups (both got "
                f"{stage.compound_member_a.group_id!r}) - a compound station with matching groups is just "
                "an ordinary single-gear station"
            )


def _build_member_solid(basis: ResolvedPlane, member: GearChainMemberSpec, group: GearGroup) -> TopoDS_Shape:
    """One physical member's real OCCT solid - reuses `app.document.gear`'s
    tooth-outline/face construction for EXTERNAL/INTERNAL (straight-tooth
    only; `GearChainFeature` v1 has no helix/profile-shift/root-fillet
    fields per member - see `GearChainMemberSpec`'s own docstring for why
    that's out of scope here) and `app.document.rack`'s own outline/prism
    construction for RACK."""
    if member.member_type == GearChainMemberType.RACK:
        outline_points = rack_outline_points(
            module=group.module,
            tooth_count=member.tooth_count,
            pressure_angle_degrees=group.pressure_angle_degrees,
            backlash=0.0,
            backing_height=None,
        )
        return prism_solid_from_outline(basis, outline_points, member.face_width)

    is_internal = member.member_type == GearChainMemberType.INTERNAL
    try:
        geometry = spur_gear_geometry(
            module=group.module,
            tooth_count=member.tooth_count,
            pressure_angle_degrees=group.pressure_angle_degrees,
            is_internal=is_internal,
        )
    except GearGeometryError as exc:
        raise _invalid_gear_chain_parameters(str(exc)) from exc
    if is_internal and member.outer_diameter is None:
        raise _invalid_gear_chain_parameters("outer_diameter is required for an internal chain member")

    wire, _root_corner_vertices = _gear_outline_wire(basis, geometry, _POINTS_PER_FLANK)
    face = _gear_face(basis, is_internal, member.outer_diameter, geometry, wire)
    normal = basis_normal(basis)
    prism_vector = gp_Vec(normal.X(), normal.Y(), normal.Z()).Multiplied(member.face_width)
    return BRepPrimAPI_MakePrism(face, prism_vector).Shape()


def _rack_rotation(resolved_stage, orientation_fallback: float) -> float:
    orientation = (
        resolved_stage.incoming_direction
        if resolved_stage.incoming_direction is not None
        else resolved_stage.outgoing_direction
    )
    if orientation is None:
        orientation = orientation_fallback
    return orientation + math.pi / 2


# One meshing junction's propagated phase state: the outgoing member's own
# `kind`, its pitch radius (`None` for RACK - `gear_chain_math.propagate_
# meshing_phase`'s own arc-length-unit marker), and its phase value
# (radians if round, mm along its own tooth-row axis if RACK).
_PhaseState = tuple[ChainMemberKind, float | None, float]


def _member_phase(
    member: GearChainMemberSpec, group: GearGroup, predecessor: _PhaseState | None, incoming_direction: float | None
) -> float:
    """The phase value (radians for a round EXTERNAL/INTERNAL member, mm
    along its own rotated tooth-row axis for a RACK) to apply to `member`
    so one of its own tooth gaps sits at the meshing contact point with
    `predecessor` - `None` for stage 0's own incoming member, which has no
    predecessor and stays at this module's `0.0` zero-reference by
    convention (`gear_chain_math.meshing_phase_base`'s own documented
    baseline case)."""
    kind = ChainMemberKind(member.member_type.value)
    is_rack = kind == ChainMemberKind.RACK
    radius = None if is_rack else group.module * member.tooth_count / 2
    if predecessor is None:
        return 0.0
    predecessor_kind, predecessor_radius, predecessor_phase = predecessor
    assert incoming_direction is not None
    base_value = (
        rack_meshing_phase_base(member.tooth_count, math.pi * group.module)
        if is_rack
        else meshing_phase_base(member.tooth_count, predecessor_kind, incoming_direction)
    )
    return propagate_meshing_phase(
        predecessor_kind, predecessor_radius, predecessor_phase, kind, radius, incoming_direction, base_value
    )


def resolve_gear_chain_from_bodies(
    feature: GearChainFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> tuple[TopoDS_Shape, list[str]]:
    """The real OCCT compound for one `GearChainFeature` (every stage's own
    solid(s), positioned per `gear_chain_math.resolve_chain`, assembled
    into one `TopoDS_Compound` - never fused with each other, since
    consecutive meshing stages are meant to stay independent Bodies) plus
    every non-blocking warning (interference findings, compound-join
    volume-loss/thin-member warnings). The caller (`app.document.extrude.
    compute_part_bodies`) registers the returned compound via `app.
    document.extrude._register_solids` directly - that function's own
    `TopAbs_SOLID` walk already splits it into one Body per physically
    disconnected stage/member, with no new suffix scheme needed (Spike 2's
    own suggestion, reused literally: "reuse `_explode_solids`... no new
    topology code needed")."""
    groups = {g.id: g for g in feature.groups}
    _validate_group_adjacency(feature)
    stage_specs = _build_stage_specs(feature, groups)
    try:
        resolved_chain: ResolvedGearChain = resolve_chain(
            stage_specs, feature.start_direction_degrees, feature.print_clearance_margin
        )
    except GearGeometryError as exc:
        raise _invalid_gear_chain_parameters(str(exc)) from exc

    chain_basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)

    warnings: list[str] = [
        f"stage {finding.stage_index_a} member {finding.member_label_a} and stage {finding.stage_index_b} "
        f"member {finding.member_label_b} {'overlap' if finding.kind == 'overlap' else 'come within the print-clearance margin of'} "
        f"each other (gap={finding.gap:.3f}mm)"
        for finding in resolved_chain.interference_findings
    ]

    stage_shapes: list[TopoDS_Shape] = []
    # Propagated meshing-phase state, carried stage to stage - `None` until
    # the first stage is built (stage 0's own incoming member has no
    # predecessor). `gear_chain_math.propagate_meshing_phase`'s own module
    # note explains why this can't be computed per-junction in isolation:
    # each successor's correct phase depends on its immediate predecessor's
    # *actual* applied phase, not just its kind.
    prev_state: _PhaseState | None = None
    for i, stage in enumerate(feature.stages):
        resolved_stage = resolved_chain.stages[i]
        x, y = resolved_stage.center

        if stage.is_compound:
            group_a = groups[stage.compound_member_a.group_id]
            group_b = groups[stage.compound_member_b.group_id]
            rotation_a = _member_phase(stage.compound_member_a, group_a, prev_state, resolved_stage.incoming_direction)
            # `compound_member_b` (the outgoing-facing member) gets a fixed
            # 0.0 reference, decoupled from `compound_member_a`'s own
            # rotation - this construction has no shared-shaft "keyed at a
            # specific relative angle" constraint to preserve (see
            # `GearChainStage`'s own docstring: nothing here claims the two
            # members are printed/manufactured as one clocked part), so 0.0
            # is just as valid a starting phase for the next junction's own
            # `propagate_meshing_phase` correction as any other value would
            # be - and far simpler than threading `compound_member_a`'s own
            # rotation through a same-shaft coupling assumption this
            # module doesn't otherwise make.
            prev_state = (ChainMemberKind(stage.compound_member_b.member_type.value), group_b.module * stage.compound_member_b.tooth_count / 2, 0.0)
            basis_a = _positioned_basis(chain_basis, x, y, z=0.0, rotation=rotation_a)
            basis_b = _positioned_basis(chain_basis, x, y, z=stage.compound_axial_offset)
            solid_a = _build_member_solid(basis_a, stage.compound_member_a, group_a)
            solid_b = _build_member_solid(basis_b, stage.compound_member_b, group_b)

            for label, member in (("a", stage.compound_member_a), ("b", stage.compound_member_b)):
                thin_warning = thin_member_warning(member.face_width, f"stage {i} member {label}")
                if thin_warning:
                    warnings.append(thin_warning)

            if stage.compound_merge == MergeMode.FUSE_INTO_ONE:
                fused = BRepAlgoAPI_Fuse(solid_a, solid_b).Shape()
                solids = _explode_solids(fused)
                if len(solids) > 1:
                    raise _gear_chain_join_failed(
                        i,
                        f"fusing compound stage {i}'s two members produced {len(solids)} disconnected solids "
                        "instead of one - check the axial offset (a gap between the two members), or "
                        "whether an internal member's own bore reaches the paired external member's "
                        "addendum",
                    )
                unfused_volume = _solid_volume(solid_a) + _solid_volume(solid_b)
                fused_volume = _solid_volume(fused)
                if fused_volume < unfused_volume - max(1e-6 * unfused_volume, 1e-6):
                    warnings.append(
                        f"compound stage {i}: fused volume ({fused_volume:.3f}mm^3) is less than its two "
                        f"members' own combined unfused volume ({unfused_volume:.3f}mm^3) - the axial "
                        "stacking offset likely overlaps the two members, silently losing material"
                    )
                stage_shapes.append(fused)
            else:
                overlap = compound_axial_overlap(stage.compound_member_a.face_width, stage.compound_axial_offset)
                if overlap > 0:
                    warnings.append(
                        f"compound stage {i}: kept separate with a {overlap:.3f}mm axial overlap between its "
                        "two members - they will interpenetrate rather than being fused"
                    )
                builder = BRep_Builder()
                compound = TopoDS_Compound()
                builder.MakeCompound(compound)
                builder.Add(compound, solid_a)
                builder.Add(compound, solid_b)
                stage_shapes.append(compound)
        else:
            group = groups[stage.member.group_id]
            phase = _member_phase(stage.member, group, prev_state, resolved_stage.incoming_direction)
            is_rack = stage.member.member_type == GearChainMemberType.RACK
            if is_rack:
                rotation = _rack_rotation(resolved_stage, math.radians(feature.start_direction_degrees))
                shift = phase
            else:
                rotation = phase
                shift = 0.0
            radius = None if is_rack else group.module * stage.member.tooth_count / 2
            prev_state = (ChainMemberKind(stage.member.member_type.value), radius, phase)
            shifted_x = x + shift * math.cos(rotation)
            shifted_y = y + shift * math.sin(rotation)
            basis = _positioned_basis(chain_basis, shifted_x, shifted_y, rotation=rotation)
            stage_shapes.append(_build_member_solid(basis, stage.member, group))

    whole_chain = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(whole_chain)
    for shape in stage_shapes:
        builder.Add(whole_chain, shape)
    return whole_chain, warnings


def resolve_gear_chain(
    part: Part, feature: GearChainFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[TopoDS_Shape, list[str]]:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.loft.resolve_loft`'s own self-exclusion convention
    exactly (computes `bodies` as if `feature` weren't in `part.features`
    yet)."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_gear_chain_from_bodies(feature, part, bodies, all_excluded)
