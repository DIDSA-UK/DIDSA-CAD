"""Gear-family HTTP routes: gear, rack, bevel gear, bevel pair, gear chain and planetary
gear features (create / update / coarse preview / background jobs) plus `/gear/preview`.

Split out of `app/document/router.py` so the gear surface lives in one file (see
`docs/gear-isolation.md`). These handlers share the document router's helpers
(`get_part_or_404`, `_feature_response`, ...), so this module imports them from
`app.document.router`, and `router.py` includes `gear_router` as its last statement.

Do not import this module directly: import `app.document.router` (which pulls this in once all
of its own helpers exist). The shared per-type touchpoints (`_feature_response` dispatch,
payload validators, domain<->schema converters) intentionally stay in `router.py`.
"""

from app.document.bevel import _spiral_hand_from_feature, resolve_bevel_gear, resolve_bevel_gear_coarse
from app.document.bevel_math import BevelGearGeometry, bevel_gear_geometry, bevel_pair_mesh_preview, max_recommended_face_width, pitch_cone_half_angles, spiral_hand_mismatch_warning
from app.document.bevel_pair import resolve_bevel_pair, resolve_bevel_pair_coarse, resolve_member_profile_shifts
from app.document.gear import resolve_gear, resolve_gear_coarse, resolve_gear_profile_shift
from app.document.gear_chain import resolve_gear_chain, resolve_gear_chain_coarse
from app.document.gear_chain_math import ChainMemberKind, ChainMemberSpec, ChainStageSpec, LinkRatio, chain_overall_ratio, compound_transition_ratio, mesh_link_ratio, meshing_phase_base, pitch_radius, propagate_meshing_phase, rack_meshing_phase_base, resolve_chain as resolve_chain_positions_and_interference
from app.document.gear_math import GearGeometryError, default_rack_backing_height, full_gear_profile_points, full_rack_profile_points, planetary_planet_tooth_count, rack_length as gear_math_rack_length, rack_tooth_geometry, spur_gear_geometry, undercut_warning, validate_planetary_assembly
from app.document.jobs import submit_bevel_pair_job, submit_planetary_job
from app.document.mesh import DEFAULT_MESH_QUALITY, mesh_quality_from_slider
from app.document.models import BevelGearFeature, BevelGearType, BevelPairFeature, GearChainFeature, GearChainMemberSpec, GearChainStage, GearFeature, GearGroup, GearType, Part, PlanetaryGearFeature, RackFeature, RackType
from app.document.planetary_gear import resolve_planetary, resolve_planetary_coarse
from app.document.rack import resolve_rack
from app.document.schemas import BevelGearFeatureCreate, BevelGearFeatureResponse, BevelGearFeatureUpdate, BevelPairFeatureCreate, BevelPairFeatureResponse, BevelPairFeatureUpdate, JobCreateResponse, BevelPairMeshPreviewResult, BodyMeshResponse, GearChainFeatureCreate, GearChainFeatureResponse, GearChainFeatureUpdate, GearFeatureCreate, GearFeatureResponse, GearFeatureUpdate, GearPreviewBevelGearRequest, GearPreviewBevelMember, GearPreviewBevelPairRequest, GearPreviewBevelPairResult, GearPreviewChainRequest, GearPreviewChainResult, GearPreviewInterferenceFinding, GearPreviewLink, GearPreviewMember, GearPreviewPlanetaryRequest, GearPreviewPlanetaryResult, GearPreviewRequest, GearPreviewResponse, PlanetaryGearFeatureCreate, PlanetaryGearFeatureResponse, PlanetaryGearFeatureUpdate, RackFeatureCreate, RackFeatureResponse, RackFeatureUpdate
from app.document.store import get_part_or_404
from fastapi import HTTPException, Query
from typing import Literal
import math
import uuid
from fastapi import APIRouter

from app.document.router import (
    _bevel_gear_feature_response,
    _bevel_pair_feature_response,
    _bevel_pair_member_to_domain,
    _coarse_preview_response,
    _default_plane_ref,
    _feature_response,
    _gear_chain_feature_response,
    _gear_chain_stage_to_domain,
    _gear_feature_response,
    _gear_group_to_domain,
    _plane_ref_to_domain,
    _validate_gear_chain_stages,
    _validate_gear_feature_payload,
    _validate_plane_ref,
    _validate_target_body_ids,
)

# No prefix / dependencies of its own: `router` (router.py) supplies "/document", the tag and `bind_session_id` for everything it includes.
gear_router = APIRouter()


@gear_router.post("/parts/{part_id}/gear-features", response_model=GearFeatureResponse, status_code=201)
def create_gear_feature(part_id: str, payload: GearFeatureCreate) -> GearFeatureResponse:
    """`docs/gear-design/02-gear-feature.md`: mirrors `create_mirror_
    feature`'s exact shape - unlocked from the start, fails closed (via
    `_validate_gear_feature_payload`/`_validate_plane_ref`/
    `_validate_target_body_ids` for payload shape, then `resolve_gear` for
    referential/geometric validity - including every `gear_math`-raised
    `invalid_gear_parameters` failure) before ever persisting an
    unresolvable Gear."""
    part = get_part_or_404(part_id)
    _validate_gear_feature_payload(payload.is_internal, payload.outer_diameter)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.gear_type == GearType.CUT, payload.target_body_ids)
    feature = GearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        gear_type=payload.gear_type,
        is_internal=payload.is_internal,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        profile_shift=payload.profile_shift,
        backlash=payload.backlash,
        root_fillet_radius=payload.root_fillet_radius,
        outer_diameter=payload.outer_diameter,
        target_body_ids=list(payload.target_body_ids),
        helix_angle_degrees=payload.helix_angle_degrees,
        herringbone=payload.herringbone,
        points_per_flank=payload.points_per_flank,
    )
    _, warnings = resolve_gear(part, feature)  # raises on an unresolvable/invalid gear
    part.add_feature(feature)
    return _gear_feature_response(part, feature, warnings)


@gear_router.post("/parts/{part_id}/gear-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_gear_feature_coarse(
    part_id: str, payload: GearFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: the 3D analogue of `/gear/
    preview` for a not-yet-created `GearFeature` - a real coarse solid
    (`app.document.gear.resolve_gear_coarse`) instead of a 2D outline.
    Mirrors `create_gear_feature`'s own validate-then-build shape exactly
    (same scratch Feature, same payload validation), but never calls
    `part.add_feature` - nothing is persisted, no Feature is created, no
    Part state changes; `part_id` is used only to resolve `plane_ref`
    against this Part's own already-real geometry."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    _validate_gear_feature_payload(payload.is_internal, payload.outer_diameter)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.gear_type == GearType.CUT, payload.target_body_ids)
    feature = GearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        gear_type=payload.gear_type,
        is_internal=payload.is_internal,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        profile_shift=payload.profile_shift,
        backlash=payload.backlash,
        root_fillet_radius=payload.root_fillet_radius,
        outer_diameter=payload.outer_diameter,
        target_body_ids=list(payload.target_body_ids),
        helix_angle_degrees=payload.helix_angle_degrees,
        herringbone=payload.herringbone,
        points_per_flank=payload.points_per_flank,
    )
    shape = resolve_gear_coarse(part, feature)  # raises on an unresolvable/invalid gear
    return _coarse_preview_response(shape, mesh_quality)


def _get_gear_feature_or_404(part: Part, feature_id: str) -> GearFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, GearFeature):
        raise HTTPException(status_code=404, detail="Gear feature not found")
    return feature


@gear_router.patch("/parts/{part_id}/gear-features/{feature_id}", response_model=GearFeatureResponse)
def update_gear_feature(part_id: str, feature_id: str, payload: GearFeatureUpdate) -> GearFeatureResponse:
    """Mirrors `update_mirror_feature`'s exact shape - same validate-
    before-mutate discipline against a scratch Feature sharing the real
    one's id. `plane_ref` follows the same omitted-vs-current convention
    every other Update schema here uses - omitted keeps the Feature's
    existing plane, an explicit value replaces it; there is no way to
    revert to the XY default via this endpoint once a real value has been
    set, matching `MirrorFeatureUpdate.mirror_plane`'s own behaviour."""
    part = get_part_or_404(part_id)
    feature = _get_gear_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_gear_type = payload.gear_type if payload.gear_type is not None else feature.gear_type
    new_is_internal = payload.is_internal if payload.is_internal is not None else feature.is_internal
    new_module = payload.module if payload.module is not None else feature.module
    new_tooth_count = payload.tooth_count if payload.tooth_count is not None else feature.tooth_count
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )
    new_profile_shift = payload.profile_shift if payload.profile_shift is not None else feature.profile_shift
    new_backlash = payload.backlash if payload.backlash is not None else feature.backlash
    new_root_fillet_radius = (
        payload.root_fillet_radius if payload.root_fillet_radius is not None else feature.root_fillet_radius
    )
    new_outer_diameter = (
        payload.outer_diameter if payload.outer_diameter is not None else feature.outer_diameter
    )
    new_target_body_ids = (
        list(payload.target_body_ids) if payload.target_body_ids is not None else feature.target_body_ids
    )
    new_helix_angle_degrees = (
        payload.helix_angle_degrees if payload.helix_angle_degrees is not None else feature.helix_angle_degrees
    )
    new_herringbone = payload.herringbone if payload.herringbone is not None else feature.herringbone
    new_points_per_flank = (
        payload.points_per_flank if payload.points_per_flank is not None else feature.points_per_flank
    )

    _validate_gear_feature_payload(new_is_internal, new_outer_diameter)
    _validate_plane_ref(part, new_plane_ref)
    _validate_target_body_ids(part, new_gear_type == GearType.CUT, new_target_body_ids)

    candidate = GearFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        gear_type=new_gear_type,
        is_internal=new_is_internal,
        module=new_module,
        tooth_count=new_tooth_count,
        face_width=new_face_width,
        pressure_angle_degrees=new_pressure_angle_degrees,
        profile_shift=new_profile_shift,
        backlash=new_backlash,
        root_fillet_radius=new_root_fillet_radius,
        outer_diameter=new_outer_diameter,
        target_body_ids=new_target_body_ids,
        helix_angle_degrees=new_helix_angle_degrees,
        herringbone=new_herringbone,
        points_per_flank=new_points_per_flank,
    )
    _, warnings = resolve_gear(part, candidate)  # raises on an unresolvable/invalid gear

    feature.plane_ref = candidate.plane_ref
    feature.gear_type = candidate.gear_type
    feature.is_internal = candidate.is_internal
    feature.module = candidate.module
    feature.tooth_count = candidate.tooth_count
    feature.face_width = candidate.face_width
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    feature.profile_shift = candidate.profile_shift
    feature.backlash = candidate.backlash
    feature.root_fillet_radius = candidate.root_fillet_radius
    feature.outer_diameter = candidate.outer_diameter
    feature.target_body_ids = candidate.target_body_ids
    feature.helix_angle_degrees = candidate.helix_angle_degrees
    feature.herringbone = candidate.herringbone
    feature.points_per_flank = candidate.points_per_flank
    return _gear_feature_response(part, feature, warnings)


@gear_router.post("/parts/{part_id}/rack-features", response_model=RackFeatureResponse, status_code=201)
def create_rack_feature(part_id: str, payload: RackFeatureCreate) -> RackFeatureResponse:
    """`docs/gear-design/03-rack.md`: mirrors `create_gear_feature`'s exact
    shape - unlike a Gear there is no internal/external discriminator to
    check, so this skips straight to `_validate_plane_ref`/
    `_validate_target_body_ids` for payload shape, then `resolve_rack` for
    referential/geometric validity (including every `gear_math`-raised
    `invalid_rack_parameters` failure) before ever persisting an
    unresolvable Rack."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.rack_type == RackType.CUT, payload.target_body_ids)
    feature = RackFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        rack_type=payload.rack_type,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        backlash=payload.backlash,
        backing_height=payload.backing_height,
        target_body_ids=list(payload.target_body_ids),
    )
    resolve_rack(part, feature)  # raises on an unresolvable/invalid rack; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_rack_feature_or_404(part: Part, feature_id: str) -> RackFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, RackFeature):
        raise HTTPException(status_code=404, detail="Rack feature not found")
    return feature


@gear_router.patch("/parts/{part_id}/rack-features/{feature_id}", response_model=RackFeatureResponse)
def update_rack_feature(part_id: str, feature_id: str, payload: RackFeatureUpdate) -> RackFeatureResponse:
    """Mirrors `update_gear_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id.
    `plane_ref` follows the same omitted-vs-current convention every other
    Update schema here uses."""
    part = get_part_or_404(part_id)
    feature = _get_rack_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_rack_type = payload.rack_type if payload.rack_type is not None else feature.rack_type
    new_module = payload.module if payload.module is not None else feature.module
    new_tooth_count = payload.tooth_count if payload.tooth_count is not None else feature.tooth_count
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )
    new_backlash = payload.backlash if payload.backlash is not None else feature.backlash
    new_backing_height = (
        payload.backing_height if payload.backing_height is not None else feature.backing_height
    )
    new_target_body_ids = (
        list(payload.target_body_ids) if payload.target_body_ids is not None else feature.target_body_ids
    )

    _validate_plane_ref(part, new_plane_ref)
    _validate_target_body_ids(part, new_rack_type == RackType.CUT, new_target_body_ids)

    candidate = RackFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        rack_type=new_rack_type,
        module=new_module,
        tooth_count=new_tooth_count,
        face_width=new_face_width,
        pressure_angle_degrees=new_pressure_angle_degrees,
        backlash=new_backlash,
        backing_height=new_backing_height,
        target_body_ids=new_target_body_ids,
    )
    resolve_rack(part, candidate)  # raises on an unresolvable/invalid rack

    feature.plane_ref = candidate.plane_ref
    feature.rack_type = candidate.rack_type
    feature.module = candidate.module
    feature.tooth_count = candidate.tooth_count
    feature.face_width = candidate.face_width
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    feature.backlash = candidate.backlash
    feature.backing_height = candidate.backing_height
    feature.target_body_ids = candidate.target_body_ids
    return _feature_response(part, feature)


@gear_router.post("/parts/{part_id}/bevel-gear-features", response_model=BevelGearFeatureResponse, status_code=201)
def create_bevel_gear_feature(part_id: str, payload: BevelGearFeatureCreate) -> BevelGearFeatureResponse:
    """`docs/gear-design/10-bevel-gear.md`: mirrors `create_rack_feature`'s
    exact shape - no internal/external discriminator to check (unlike
    Gear), so this skips straight to `_validate_plane_ref`/
    `_validate_target_body_ids` for payload shape, then `resolve_bevel_
    gear` for referential/geometric validity (including every `bevel_
    math`-raised `invalid_bevel_parameters` failure, and every OCCT-
    construction `bevel_failed` failure) before ever persisting an
    unresolvable bevel gear."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.bevel_type == BevelGearType.CUT, payload.target_body_ids)
    feature = BevelGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        bevel_type=payload.bevel_type,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pitch_cone_angle_degrees=payload.pitch_cone_angle_degrees,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        backlash=payload.backlash,
        profile_shift=payload.profile_shift,
        target_body_ids=list(payload.target_body_ids),
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
        spiral_hand=payload.spiral_hand,
    )
    _, warnings = resolve_bevel_gear(part, feature)  # raises on an unresolvable/invalid bevel gear
    part.add_feature(feature)
    return _bevel_gear_feature_response(part, feature, warnings)


@gear_router.post("/parts/{part_id}/bevel-gear-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_bevel_gear_feature_coarse(
    part_id: str, payload: BevelGearFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: mirrors `preview_gear_feature_
    coarse`'s own shape exactly, for a not-yet-created `BevelGearFeature` -
    same `create_bevel_gear_feature` validate-then-build path, but built
    via `app.document.bevel.resolve_bevel_gear_coarse` and never
    persisted."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.bevel_type == BevelGearType.CUT, payload.target_body_ids)
    feature = BevelGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        bevel_type=payload.bevel_type,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pitch_cone_angle_degrees=payload.pitch_cone_angle_degrees,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        backlash=payload.backlash,
        profile_shift=payload.profile_shift,
        target_body_ids=list(payload.target_body_ids),
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
        spiral_hand=payload.spiral_hand,
    )
    shape = resolve_bevel_gear_coarse(part, feature)  # raises on an unresolvable/invalid bevel gear
    return _coarse_preview_response(shape, mesh_quality)


def _get_bevel_gear_feature_or_404(part: Part, feature_id: str) -> BevelGearFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, BevelGearFeature):
        raise HTTPException(status_code=404, detail="Bevel gear feature not found")
    return feature


@gear_router.patch("/parts/{part_id}/bevel-gear-features/{feature_id}", response_model=BevelGearFeatureResponse)
def update_bevel_gear_feature(part_id: str, feature_id: str, payload: BevelGearFeatureUpdate) -> BevelGearFeatureResponse:
    """Mirrors `update_rack_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_bevel_gear_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_bevel_type = payload.bevel_type if payload.bevel_type is not None else feature.bevel_type
    new_module = payload.module if payload.module is not None else feature.module
    new_tooth_count = payload.tooth_count if payload.tooth_count is not None else feature.tooth_count
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_pitch_cone_angle_degrees = (
        payload.pitch_cone_angle_degrees
        if payload.pitch_cone_angle_degrees is not None
        else feature.pitch_cone_angle_degrees
    )
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )
    new_backlash = payload.backlash if payload.backlash is not None else feature.backlash
    new_profile_shift = payload.profile_shift if payload.profile_shift is not None else feature.profile_shift
    new_target_body_ids = (
        list(payload.target_body_ids) if payload.target_body_ids is not None else feature.target_body_ids
    )
    new_points_per_flank = (
        payload.points_per_flank if payload.points_per_flank is not None else feature.points_per_flank
    )
    new_spiral_angle_degrees = (
        payload.spiral_angle_degrees if payload.spiral_angle_degrees is not None else feature.spiral_angle_degrees
    )
    new_spiral_hand = payload.spiral_hand if payload.spiral_hand is not None else feature.spiral_hand

    _validate_plane_ref(part, new_plane_ref)
    _validate_target_body_ids(part, new_bevel_type == BevelGearType.CUT, new_target_body_ids)

    candidate = BevelGearFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        bevel_type=new_bevel_type,
        module=new_module,
        tooth_count=new_tooth_count,
        face_width=new_face_width,
        pitch_cone_angle_degrees=new_pitch_cone_angle_degrees,
        pressure_angle_degrees=new_pressure_angle_degrees,
        backlash=new_backlash,
        profile_shift=new_profile_shift,
        target_body_ids=new_target_body_ids,
        points_per_flank=new_points_per_flank,
        spiral_angle_degrees=new_spiral_angle_degrees,
        spiral_hand=new_spiral_hand,
    )
    _, warnings = resolve_bevel_gear(part, candidate)  # raises on an unresolvable/invalid bevel gear

    feature.plane_ref = candidate.plane_ref
    feature.bevel_type = candidate.bevel_type
    feature.module = candidate.module
    feature.tooth_count = candidate.tooth_count
    feature.face_width = candidate.face_width
    feature.pitch_cone_angle_degrees = candidate.pitch_cone_angle_degrees
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    feature.backlash = candidate.backlash
    feature.profile_shift = candidate.profile_shift
    feature.target_body_ids = candidate.target_body_ids
    feature.points_per_flank = candidate.points_per_flank
    feature.spiral_angle_degrees = candidate.spiral_angle_degrees
    feature.spiral_hand = candidate.spiral_hand
    return _bevel_gear_feature_response(part, feature, warnings)


@gear_router.post("/parts/{part_id}/gear-chain-features", response_model=GearChainFeatureResponse, status_code=201)
def create_gear_chain_feature(part_id: str, payload: GearChainFeatureCreate) -> GearChainFeatureResponse:
    """`docs/gear-design/05-gear-chain-and-planetary.md`: mirrors
    `create_loft_feature`'s exact shape - validates payload shape
    (`_validate_gear_chain_stages`/`_validate_plane_ref`), then
    resolvability (`app.document.gear_chain.resolve_gear_chain` - bent-path
    positioning, group-adjacency/module matching, per-stage OCCT
    construction, and the compound-join connected-solid-count BLOCKING
    check) before ever persisting an unresolvable chain. Non-blocking
    interference/compound-join `warnings` are threaded straight into the
    response, same as Loft's own self-intersection warnings."""
    part = get_part_or_404(part_id)
    groups = [_gear_group_to_domain(g) for g in payload.groups]
    stages = [_gear_chain_stage_to_domain(s) for s in payload.stages]
    _validate_gear_chain_stages(groups, stages)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = GearChainFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        groups=groups,
        stages=stages,
        start_direction_degrees=payload.start_direction_degrees,
        print_clearance_margin=payload.print_clearance_margin,
    )
    _, warnings = resolve_gear_chain(part, feature)  # raises on an unresolvable/invalid chain
    part.add_feature(feature)
    return _gear_chain_feature_response(part, feature, warnings)


@gear_router.post("/parts/{part_id}/gear-chain-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_gear_chain_feature_coarse(
    part_id: str, payload: GearChainFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: mirrors `preview_gear_feature_
    coarse`'s own shape exactly, for a not-yet-created `GearChainFeature` -
    same `create_gear_chain_feature` validate-then-build path, but built
    via `app.document.gear_chain.resolve_gear_chain_coarse` and never
    persisted. Every stage's own member(s) come back as their own entry
    (`_coarse_preview_response`), same as the real chain's own multi-Body
    compound."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    groups = [_gear_group_to_domain(g) for g in payload.groups]
    stages = [_gear_chain_stage_to_domain(s) for s in payload.stages]
    _validate_gear_chain_stages(groups, stages)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = GearChainFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        groups=groups,
        stages=stages,
        start_direction_degrees=payload.start_direction_degrees,
        print_clearance_margin=payload.print_clearance_margin,
    )
    shape = resolve_gear_chain_coarse(part, feature)  # raises on an unresolvable/invalid chain
    return _coarse_preview_response(shape, mesh_quality)


def _get_gear_chain_feature_or_404(part: Part, feature_id: str) -> GearChainFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, GearChainFeature):
        raise HTTPException(status_code=404, detail="Gear chain feature not found")
    return feature


@gear_router.patch("/parts/{part_id}/gear-chain-features/{feature_id}", response_model=GearChainFeatureResponse)
def update_gear_chain_feature(
    part_id: str, feature_id: str, payload: GearChainFeatureUpdate
) -> GearChainFeatureResponse:
    """Mirrors `update_loft_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_gear_chain_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_groups = (
        [_gear_group_to_domain(g) for g in payload.groups] if payload.groups is not None else feature.groups
    )
    new_stages = (
        [_gear_chain_stage_to_domain(s) for s in payload.stages] if payload.stages is not None else feature.stages
    )
    new_start_direction_degrees = (
        payload.start_direction_degrees
        if payload.start_direction_degrees is not None
        else feature.start_direction_degrees
    )
    new_print_clearance_margin = (
        payload.print_clearance_margin
        if payload.print_clearance_margin is not None
        else feature.print_clearance_margin
    )

    _validate_gear_chain_stages(new_groups, new_stages)
    _validate_plane_ref(part, new_plane_ref)

    candidate = GearChainFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        groups=new_groups,
        stages=new_stages,
        start_direction_degrees=new_start_direction_degrees,
        print_clearance_margin=new_print_clearance_margin,
    )
    _, warnings = resolve_gear_chain(part, candidate)  # raises on an unresolvable/invalid chain

    feature.plane_ref = candidate.plane_ref
    feature.groups = candidate.groups
    feature.stages = candidate.stages
    feature.start_direction_degrees = candidate.start_direction_degrees
    feature.print_clearance_margin = candidate.print_clearance_margin
    return _gear_chain_feature_response(part, feature, warnings)


@gear_router.post(
    "/parts/{part_id}/planetary-gear-features", response_model=PlanetaryGearFeatureResponse, status_code=201
)
def create_planetary_gear_feature(part_id: str, payload: PlanetaryGearFeatureCreate) -> PlanetaryGearFeatureResponse:
    """`docs/gear-design/05-gear-chain-and-planetary.md`: mirrors
    `create_gear_feature`'s exact shape - unlike a chain there is no
    payload-shape validation to do beyond `_validate_plane_ref` (sun/ring/
    planet tooth counts have no discriminated-union shape to check); every
    real check (derived planet tooth count, the assembly condition, planet-
    planet interference) is `app.document.planetary_gear.resolve_planetary`'s
    job, and a failure there BLOCKS creation outright (`00-conventions.md`'s
    validation-banner exception - there is no valid planet gear to draw at
    all for an invalid combination, not a quality tradeoff)."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = PlanetaryGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        sun_tooth_count=payload.sun_tooth_count,
        ring_tooth_count=payload.ring_tooth_count,
        planet_count=payload.planet_count,
        face_width=payload.face_width,
        ring_outer_diameter=payload.ring_outer_diameter,
        pressure_angle_degrees=payload.pressure_angle_degrees,
    )
    resolve_planetary(part, feature)  # raises (blocking) on an invalid/unresolvable planetary set
    part.add_feature(feature)
    return _feature_response(part, feature)


@gear_router.post("/parts/{part_id}/planetary-gear-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_planetary_gear_feature_coarse(
    part_id: str, payload: PlanetaryGearFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: mirrors `preview_gear_feature_
    coarse`'s own shape exactly, for a not-yet-created `PlanetaryGearFeature`
    - same `create_planetary_gear_feature` validate-then-build path, but
    built via `app.document.planetary_gear.resolve_planetary_coarse` and
    never persisted. Sun/ring/every planet come back as their own entry
    (`_coarse_preview_response`), same as the real assembly's own multi-Body
    compound."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = PlanetaryGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        sun_tooth_count=payload.sun_tooth_count,
        ring_tooth_count=payload.ring_tooth_count,
        planet_count=payload.planet_count,
        face_width=payload.face_width,
        ring_outer_diameter=payload.ring_outer_diameter,
        pressure_angle_degrees=payload.pressure_angle_degrees,
    )
    shape = resolve_planetary_coarse(part, feature)  # raises (blocking) on an invalid/unresolvable planetary set
    return _coarse_preview_response(shape, mesh_quality)


def _get_planetary_gear_feature_or_404(part: Part, feature_id: str) -> PlanetaryGearFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, PlanetaryGearFeature):
        raise HTTPException(status_code=404, detail="Planetary gear feature not found")
    return feature


@gear_router.patch("/parts/{part_id}/planetary-gear-features/{feature_id}", response_model=PlanetaryGearFeatureResponse)
def update_planetary_gear_feature(
    part_id: str, feature_id: str, payload: PlanetaryGearFeatureUpdate
) -> PlanetaryGearFeatureResponse:
    """Mirrors `update_gear_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_planetary_gear_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_module = payload.module if payload.module is not None else feature.module
    new_sun_tooth_count = payload.sun_tooth_count if payload.sun_tooth_count is not None else feature.sun_tooth_count
    new_ring_tooth_count = (
        payload.ring_tooth_count if payload.ring_tooth_count is not None else feature.ring_tooth_count
    )
    new_planet_count = payload.planet_count if payload.planet_count is not None else feature.planet_count
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_ring_outer_diameter = (
        payload.ring_outer_diameter if payload.ring_outer_diameter is not None else feature.ring_outer_diameter
    )
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )

    _validate_plane_ref(part, new_plane_ref)

    candidate = PlanetaryGearFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        module=new_module,
        sun_tooth_count=new_sun_tooth_count,
        ring_tooth_count=new_ring_tooth_count,
        planet_count=new_planet_count,
        face_width=new_face_width,
        ring_outer_diameter=new_ring_outer_diameter,
        pressure_angle_degrees=new_pressure_angle_degrees,
    )
    resolve_planetary(part, candidate)  # raises (blocking) on an invalid/unresolvable planetary set

    feature.plane_ref = candidate.plane_ref
    feature.module = candidate.module
    feature.sun_tooth_count = candidate.sun_tooth_count
    feature.ring_tooth_count = candidate.ring_tooth_count
    feature.planet_count = candidate.planet_count
    feature.face_width = candidate.face_width
    feature.ring_outer_diameter = candidate.ring_outer_diameter
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    return _feature_response(part, feature)


@gear_router.post("/parts/{part_id}/bevel-pair-features", response_model=BevelPairFeatureResponse, status_code=201)
def create_bevel_pair_feature(part_id: str, payload: BevelPairFeatureCreate) -> BevelPairFeatureResponse:
    """`docs/gear-design/11-bevel-pair.md`: mirrors `create_planetary_gear_
    feature`'s exact shape - no payload-shape validation beyond `_validate_
    plane_ref` (member tooth counts have no discriminated-union shape to
    check); every real check (the pitch-cone-split formula's own domain,
    both members' own bevel_math validation, OCCT construction) is `app.
    document.bevel_pair.resolve_bevel_pair`'s job, raising the structured
    `invalid_bevel_pair_parameters`/`bevel_failed` errors before ever
    persisting an unresolvable pair."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = BevelPairFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        member_1=_bevel_pair_member_to_domain(payload.member_1),
        member_2=_bevel_pair_member_to_domain(payload.member_2),
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        shaft_angle_degrees=payload.shaft_angle_degrees,
        backlash=payload.backlash,
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
    )
    _, warnings = resolve_bevel_pair(part, feature)  # raises on an unresolvable/invalid bevel pair
    part.add_feature(feature)
    return _bevel_pair_feature_response(part, feature, warnings)


@gear_router.post("/parts/{part_id}/bevel-pair-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_bevel_pair_feature_coarse(
    part_id: str, payload: BevelPairFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: mirrors `preview_gear_feature_
    coarse`'s own shape exactly, for a not-yet-created `BevelPairFeature` -
    same `create_bevel_pair_feature` validate-then-build path, but built via
    `app.document.bevel_pair.resolve_bevel_pair_coarse` (two cones, no
    meshing-phase search) and never persisted. Both members come back as
    their own entry (`_coarse_preview_response`), same as the real pair's
    own 2-Body compound."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = BevelPairFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        member_1=_bevel_pair_member_to_domain(payload.member_1),
        member_2=_bevel_pair_member_to_domain(payload.member_2),
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        shaft_angle_degrees=payload.shaft_angle_degrees,
        backlash=payload.backlash,
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
    )
    shape = resolve_bevel_pair_coarse(part, feature)  # raises on an unresolvable/invalid bevel pair
    return _coarse_preview_response(shape, mesh_quality)


@gear_router.post("/parts/{part_id}/bevel-pair-features/jobs", response_model=JobCreateResponse, status_code=202)
def create_bevel_pair_feature_job(part_id: str, payload: BevelPairFeatureCreate) -> JobCreateResponse:
    """`docs/lod-strategy/02-phase2-design.md` SS4: job-mode counterpart to
    `create_bevel_pair_feature` - a separate route, not a query flag,
    because the response shape genuinely differs (an immediate `{job_id,
    status}` here vs. the full synchronous 201 there). Only the cheap,
    synchronous part of `create_bevel_pair_feature` runs on this request
    (payload-shape validation, `_validate_plane_ref`, building the `Bevel
    PairFeature` object itself - no OCCT yet); `app.document.jobs.submit_
    bevel_pair_job` hands the real build (`resolve_bevel_pair` - the same
    call the synchronous endpoint makes, cancellation-aware this time - plus
    persisting via `part.add_feature` on success) to a dedicated background
    thread and returns immediately. `202 Accepted` (not `201 Created`) - the
    Feature does not exist yet, only the job tracking its eventual creation
    does.

    Every other Feature type's create endpoint, and `create_bevel_pair_
    feature`/`preview_bevel_pair_feature_coarse` above, are completely
    untouched by this endpoint's existence."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = BevelPairFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        member_1=_bevel_pair_member_to_domain(payload.member_1),
        member_2=_bevel_pair_member_to_domain(payload.member_2),
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        shaft_angle_degrees=payload.shaft_angle_degrees,
        backlash=payload.backlash,
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
    )
    job = submit_bevel_pair_job(part_id, part, feature)  # raises 409 if a job is already running
    return JobCreateResponse(job_id=job.id, status="running")


@gear_router.post("/parts/{part_id}/planetary-gear-features/jobs", response_model=JobCreateResponse, status_code=202)
def create_planetary_gear_feature_job(part_id: str, payload: PlanetaryGearFeatureCreate) -> JobCreateResponse:
    """LOD Phase 2 chunk 3 - job-mode counterpart to `create_planetary_gear_
    feature`, mirroring `create_bevel_pair_feature_job` above exactly (same
    reasoning for the separate route/`202`/background-thread shape - see
    that endpoint's own docstring). Only the cheap, synchronous part of
    `create_planetary_gear_feature` runs on this request (payload-shape
    validation, `_validate_plane_ref`, building the `PlanetaryGearFeature`
    object itself - no OCCT yet); `app.document.jobs.submit_planetary_job`
    hands the real build (`resolve_planetary`, now cancellation-aware -
    chunk 1's own pooling plus this chunk's `cancellation` threading) to a
    dedicated background thread.

    `preview_planetary_gear_feature_coarse` above and every other Feature
    type's own synchronous create endpoint are completely untouched."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = PlanetaryGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        sun_tooth_count=payload.sun_tooth_count,
        ring_tooth_count=payload.ring_tooth_count,
        planet_count=payload.planet_count,
        face_width=payload.face_width,
        ring_outer_diameter=payload.ring_outer_diameter,
        pressure_angle_degrees=payload.pressure_angle_degrees,
    )
    job = submit_planetary_job(part_id, part, feature)  # raises 409 if a job is already running
    return JobCreateResponse(job_id=job.id, status="running")


def _get_bevel_pair_feature_or_404(part: Part, feature_id: str) -> BevelPairFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, BevelPairFeature):
        raise HTTPException(status_code=404, detail="Bevel pair feature not found")
    return feature


@gear_router.patch("/parts/{part_id}/bevel-pair-features/{feature_id}", response_model=BevelPairFeatureResponse)
def update_bevel_pair_feature(part_id: str, feature_id: str, payload: BevelPairFeatureUpdate) -> BevelPairFeatureResponse:
    """Mirrors `update_planetary_gear_feature`'s exact shape - same
    validate-before-mutate discipline against a scratch Feature sharing
    the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_bevel_pair_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_module = payload.module if payload.module is not None else feature.module
    new_member_1 = (
        _bevel_pair_member_to_domain(payload.member_1) if payload.member_1 is not None else feature.member_1
    )
    new_member_2 = (
        _bevel_pair_member_to_domain(payload.member_2) if payload.member_2 is not None else feature.member_2
    )
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )
    new_shaft_angle_degrees = (
        payload.shaft_angle_degrees if payload.shaft_angle_degrees is not None else feature.shaft_angle_degrees
    )
    new_backlash = payload.backlash if payload.backlash is not None else feature.backlash
    new_points_per_flank = (
        payload.points_per_flank if payload.points_per_flank is not None else feature.points_per_flank
    )
    new_spiral_angle_degrees = (
        payload.spiral_angle_degrees if payload.spiral_angle_degrees is not None else feature.spiral_angle_degrees
    )

    _validate_plane_ref(part, new_plane_ref)

    candidate = BevelPairFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        module=new_module,
        member_1=new_member_1,
        member_2=new_member_2,
        face_width=new_face_width,
        pressure_angle_degrees=new_pressure_angle_degrees,
        shaft_angle_degrees=new_shaft_angle_degrees,
        backlash=new_backlash,
        points_per_flank=new_points_per_flank,
        spiral_angle_degrees=new_spiral_angle_degrees,
    )
    _, warnings = resolve_bevel_pair(part, candidate)  # raises on an unresolvable/invalid bevel pair

    feature.plane_ref = candidate.plane_ref
    feature.module = candidate.module
    feature.member_1 = candidate.member_1
    feature.member_2 = candidate.member_2
    feature.face_width = candidate.face_width
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    feature.shaft_angle_degrees = candidate.shaft_angle_degrees
    feature.backlash = candidate.backlash
    feature.points_per_flank = candidate.points_per_flank
    feature.spiral_angle_degrees = candidate.spiral_angle_degrees
    return _bevel_pair_feature_response(part, feature, warnings)


def _invalid_gear_preview_parameters(detail: str) -> HTTPException:
    """Mirrors `app.document.gear._invalid_gear_parameters`'s convention -
    a `gear_math`-rejected parameter combination has no valid geometry to
    draw at all, so `/gear/preview` blocks (422) rather than returning a
    warning, per `00-conventions.md`'s stated exception to the non-blocking
    validation-banner rule."""
    return HTTPException(status_code=422, detail={"type": "invalid_gear_preview_parameters", "detail": detail})


def _preview_transform_profile(
    points: list[tuple[float, float]], center: tuple[float, float], angle: float = 0.0
) -> list[tuple[float, float]]:
    """Rotates (about the profile's own local origin) then translates a raw
    `gear_math`/`rack_tooth_geometry` profile (always centred on its own
    local origin) into a chain/planetary preview's shared 2D frame - the
    one transform every other preview response already spares the client
    (`00-conventions.md`'s "don't duplicate the math client-side" point),
    generalized here from "translate only" to "rotate then translate" for a
    rack member, whose own length axis isn't generally aligned with the
    chain's local x axis."""
    if angle == 0.0:
        return [(center[0] + x, center[1] + y) for x, y in points]
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    return [(center[0] + x * cos_a - y * sin_a, center[1] + x * sin_a + y * cos_a) for x, y in points]


def _preview_rack_rotation(resolved_stage, start_direction_degrees: float) -> float:
    """Mirrors `app.document.gear_chain._rack_rotation` exactly (a rack's
    own length axis is perpendicular to its one adjacent chain segment) -
    small, deliberate duplication of that OCCT-adjacent module's private
    helper rather than importing it, matching every other branch of
    `_gear_preview_response` below (which already duplicates `resolve_gear`/
    `resolve_rack`'s own cheap math rather than calling into them)."""
    orientation = resolved_stage.incoming_direction
    if orientation is None:
        orientation = resolved_stage.outgoing_direction
    if orientation is None:
        orientation = math.radians(start_direction_degrees)
    return orientation + math.pi / 2


def _chain_member_math_spec(member: GearChainMemberSpec, group: GearGroup) -> ChainMemberSpec:
    """Mirrors `app.document.gear_chain._member_to_math_spec` exactly - see
    `_preview_rack_rotation`'s own docstring for why this is duplicated
    rather than imported."""
    return ChainMemberSpec(
        kind=ChainMemberKind(member.member_type.value),
        module=group.module,
        pressure_angle_degrees=group.pressure_angle_degrees,
        tooth_count=member.tooth_count,
        face_width=member.face_width,
        outer_diameter=member.outer_diameter,
    )


def _chain_stage_math_spec(stage: GearChainStage, groups: dict[str, GearGroup]) -> ChainStageSpec:
    """Mirrors `app.document.gear_chain._build_stage_specs`'s own per-stage
    conversion (see `_preview_rack_rotation`'s docstring)."""
    if stage.is_compound:
        return ChainStageSpec(
            turn_angle_degrees=stage.turn_angle_degrees,
            compound_member_a=_chain_member_math_spec(
                stage.compound_member_a, groups[stage.compound_member_a.group_id]
            ),
            compound_member_b=_chain_member_math_spec(
                stage.compound_member_b, groups[stage.compound_member_b.group_id]
            ),
        )
    return ChainStageSpec(
        turn_angle_degrees=stage.turn_angle_degrees,
        member=_chain_member_math_spec(stage.member, groups[stage.member.group_id]),
    )


# One meshing junction's propagated phase state - mirrors `app.document.
# gear_chain._PhaseState` exactly (kind, pitch_radius-or-None-for-rack,
# phase-value; see `_preview_rack_rotation`'s docstring for why this is
# duplicated rather than imported).
_PreviewPhaseState = tuple[ChainMemberKind, float | None, float]


def _preview_member_phase(
    member_spec: ChainMemberSpec, predecessor: _PreviewPhaseState | None, incoming_direction: float | None
) -> float:
    """Mirrors `app.document.gear_chain._member_phase` exactly (see
    `_preview_rack_rotation`'s own docstring for why this is duplicated
    rather than imported) - the phase value (radians for a round EXTERNAL/
    INTERNAL member, mm along its own rotated tooth-row axis for a RACK) to
    apply to `member_spec` so one of its own tooth gaps sits at the
    meshing contact point with `predecessor` - `0.0` for the first member
    in a chain (`predecessor is None`), matching `meshing_phase_base`'s own
    documented zero-reference baseline."""
    is_rack = member_spec.kind == ChainMemberKind.RACK
    radius = None if is_rack else pitch_radius(member_spec)
    if predecessor is None:
        return 0.0
    predecessor_kind, predecessor_radius, predecessor_phase = predecessor
    assert incoming_direction is not None
    base_value = (
        rack_meshing_phase_base(member_spec.tooth_count, math.pi * member_spec.module)
        if is_rack
        else meshing_phase_base(member_spec.tooth_count, predecessor_kind, incoming_direction)
    )
    return propagate_meshing_phase(
        predecessor_kind, predecessor_radius, predecessor_phase, member_spec.kind, radius, incoming_direction, base_value
    )


def _preview_member_outline(
    stage_index: int,
    label: str,
    member_spec: ChainMemberSpec,
    group_id: str | None,
    display_color: str | None,
    center: tuple[float, float],
    rotation: float = 0.0,
) -> GearPreviewMember:
    """One physical member's `GearPreviewMember` - the tooth outline (raw
    `gear_math` points, transformed into the shared preview frame via
    `_preview_transform_profile`) plus its reference-circle numbers, shared
    by the chain and planetary preview builders below."""
    if member_spec.kind == ChainMemberKind.RACK:
        rack_geometry = rack_tooth_geometry(
            module=member_spec.module, pressure_angle_degrees=member_spec.pressure_angle_degrees
        )
        outline_points = _preview_transform_profile(
            full_rack_profile_points(rack_geometry, member_spec.tooth_count), center, rotation
        )
        return GearPreviewMember(
            stage_index=stage_index,
            label=label,
            member_type="rack",
            group_id=group_id,
            display_color=display_color,
            center=center,
            outline_points=outline_points,
        )

    is_internal = member_spec.kind == ChainMemberKind.INTERNAL
    geometry = spur_gear_geometry(
        module=member_spec.module,
        tooth_count=member_spec.tooth_count,
        pressure_angle_degrees=member_spec.pressure_angle_degrees,
        is_internal=is_internal,
    )
    outline_points = _preview_transform_profile(full_gear_profile_points(geometry), center, rotation)
    return GearPreviewMember(
        stage_index=stage_index,
        label=label,
        member_type=member_spec.kind.value,
        group_id=group_id,
        display_color=display_color,
        center=center,
        outline_points=outline_points,
        pitch_radius=geometry.pitch_radius,
        base_radius=geometry.base_radius,
        addendum_radius=geometry.addendum_radius,
        dedendum_radius=geometry.dedendum_radius,
        outer_radius=(member_spec.outer_diameter / 2) if is_internal and member_spec.outer_diameter else None,
    )


def _gear_preview_chain_response(payload: GearPreviewChainRequest) -> GearPreviewChainResult:
    """`docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
    bevel-pair preview" extension, the `GearChainFeature` half - reuses
    `_validate_gear_chain_stages` (the exact payload-shape validation
    `create_gear_chain_feature` itself runs) and `app.document.
    gear_chain_math.resolve_chain` (the real bent-path positioning +
    interference math, `05-gear-chain-and-planetary.md`'s own Spike 1) so
    the preview and the real Feature agree on every rejection and every
    resolved position - only the OCCT solid construction itself
    (`app.document.gear_chain.resolve_gear_chain_from_bodies`) is
    deliberately not run here."""
    groups = [_gear_group_to_domain(g) for g in payload.groups]
    stages = [_gear_chain_stage_to_domain(s) for s in payload.stages]
    _validate_gear_chain_stages(groups, stages)
    groups_by_id = {g.id: g for g in groups}

    try:
        stage_specs = [_chain_stage_math_spec(stage, groups_by_id) for stage in stages]
        resolved = resolve_chain_positions_and_interference(
            stage_specs, payload.start_direction_degrees, payload.print_clearance_margin
        )

        members: list[GearPreviewMember] = []
        # Propagated meshing-phase state, carried stage to stage - mirrors
        # `app.document.gear_chain.resolve_gear_chain_from_bodies`'s own
        # `prev_state` loop variable exactly (see `_preview_member_phase`'s
        # docstring for why this duplication exists).
        prev_state: _PreviewPhaseState | None = None
        for i, (stage, spec, resolved_stage) in enumerate(zip(stages, stage_specs, resolved.stages)):
            if spec.is_compound:
                rotation_a = _preview_member_phase(spec.compound_member_a, prev_state, resolved_stage.incoming_direction)
                # `compound_member_b` (the outgoing-facing member) gets a
                # fixed 0.0 reference, decoupled from `compound_member_a`'s
                # own rotation - mirrors `resolve_gear_chain_from_bodies`'s
                # own decoupling exactly (see that function's inline
                # comment for why: no shared-shaft "keyed at a specific
                # relative angle" constraint exists here to preserve).
                prev_state = (spec.compound_member_b.kind, pitch_radius(spec.compound_member_b), 0.0)
                members.append(
                    _preview_member_outline(
                        i,
                        "a",
                        spec.compound_member_a,
                        stage.compound_member_a.group_id,
                        groups_by_id[stage.compound_member_a.group_id].display_color,
                        resolved_stage.center,
                        rotation_a,
                    )
                )
                members.append(
                    _preview_member_outline(
                        i,
                        "b",
                        spec.compound_member_b,
                        stage.compound_member_b.group_id,
                        groups_by_id[stage.compound_member_b.group_id].display_color,
                        resolved_stage.center,
                    )
                )
            else:
                phase = _preview_member_phase(spec.member, prev_state, resolved_stage.incoming_direction)
                is_rack = spec.member.kind == ChainMemberKind.RACK
                rotation = (
                    _preview_rack_rotation(resolved_stage, payload.start_direction_degrees) if is_rack else phase
                )
                prev_state = (spec.member.kind, None if is_rack else pitch_radius(spec.member), phase)
                members.append(
                    _preview_member_outline(
                        i,
                        "single",
                        spec.member,
                        stage.member.group_id,
                        groups_by_id[stage.member.group_id].display_color,
                        resolved_stage.center,
                        rotation,
                    )
                )
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    interference_findings = [
        GearPreviewInterferenceFinding(
            stage_index_a=finding.stage_index_a,
            member_label_a=finding.member_label_a,
            stage_index_b=finding.stage_index_b,
            member_label_b=finding.member_label_b,
            gap=finding.gap,
            kind=finding.kind,
        )
        for finding in resolved.interference_findings
    ]

    def _link(from_index: int, to_index: int, kind: Literal["mesh", "compound"], link_ratio: LinkRatio) -> GearPreviewLink:
        return GearPreviewLink(
            from_stage_index=from_index,
            to_stage_index=to_index,
            kind=kind,
            ratio=link_ratio.ratio,
            reverses_direction=link_ratio.reverses,
            linear_mm_per_revolution=link_ratio.linear_mm_per_revolution,
        )

    links: list[GearPreviewLink] = []
    mesh_ratios: list[LinkRatio] = []
    for k in range(len(stage_specs) - 1):
        if stage_specs[k].is_compound:
            links.append(
                _link(k, k, "compound", compound_transition_ratio(stage_specs[k].compound_member_a, stage_specs[k].compound_member_b))
            )
        mesh_ratio = mesh_link_ratio(stage_specs[k].outgoing_member(), stage_specs[k + 1].incoming_member())
        mesh_ratios.append(mesh_ratio)
        links.append(_link(k, k + 1, "mesh", mesh_ratio))
    if stage_specs and stage_specs[-1].is_compound:
        last = len(stage_specs) - 1
        links.append(
            _link(
                last,
                last,
                "compound",
                compound_transition_ratio(stage_specs[last].compound_member_a, stage_specs[last].compound_member_b),
            )
        )

    return GearPreviewChainResult(
        members=members,
        interference_findings=interference_findings,
        links=links,
        overall_ratio=chain_overall_ratio(mesh_ratios),
    )


def _gear_preview_planetary_response(payload: GearPreviewPlanetaryRequest) -> GearPreviewPlanetaryResult:
    """`docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
    bevel-pair preview" extension, the `PlanetaryGearFeature` half - reuses
    the exact same `gear_math` calls and orbit-radius/even-spacing
    positioning `app.document.planetary_gear.resolve_planetary_from_bodies`
    itself uses (that positioning is already pure arithmetic, no OCCT, so
    it's duplicated here rather than the OCCT solid construction, per this
    module's established "duplicate the cheap math" precedent)."""
    try:
        planet_tooth_count = planetary_planet_tooth_count(payload.sun_tooth_count, payload.ring_tooth_count)
        sun_geometry = spur_gear_geometry(
            module=payload.module,
            tooth_count=payload.sun_tooth_count,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            is_internal=False,
        )
        ring_geometry = spur_gear_geometry(
            module=payload.module,
            tooth_count=payload.ring_tooth_count,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            is_internal=True,
        )
        planet_geometry = spur_gear_geometry(
            module=payload.module,
            tooth_count=planet_tooth_count,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            is_internal=False,
        )
        validate_planetary_assembly(
            sun_teeth=payload.sun_tooth_count,
            ring_teeth=payload.ring_tooth_count,
            planet_count=payload.planet_count,
            planet_pitch_radius=planet_geometry.pitch_radius,
            planet_addendum_radius=planet_geometry.addendum_radius,
        )
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    if payload.face_width <= 0:
        raise _invalid_gear_preview_parameters(f"face_width must be positive, got {payload.face_width!r}")
    if payload.ring_outer_diameter / 2 <= ring_geometry.dedendum_radius:
        raise _invalid_gear_preview_parameters(
            f"ring_outer_diameter ({payload.ring_outer_diameter!r}) must exceed the ring's own tooth profile "
            f"outer reach (dedendum diameter {ring_geometry.dedendum_radius * 2!r})"
        )

    # Meshing-phase alignment - mirrors `app.document.planetary_gear.
    # resolve_planetary_from_bodies`'s own phase-computation block exactly
    # (see that function's inline comment for the full derivation/real-OCCT
    # verification this reuses) - duplicated here rather than imported, per
    # this module's established "duplicate the cheap math" precedent
    # (`_preview_rack_rotation`'s own docstring).
    sun_rotation = 0.0
    planet_0_azimuth = 0.0
    planet_0_base = meshing_phase_base(planet_tooth_count, ChainMemberKind.EXTERNAL, planet_0_azimuth)
    planet_0_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL,
        sun_geometry.pitch_radius,
        sun_rotation,
        ChainMemberKind.EXTERNAL,
        planet_geometry.pitch_radius,
        planet_0_azimuth,
        planet_0_base,
    )
    ring_azimuth = planet_0_azimuth + math.pi
    ring_base = meshing_phase_base(payload.ring_tooth_count, ChainMemberKind.EXTERNAL, ring_azimuth)
    ring_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL,
        planet_geometry.pitch_radius,
        planet_0_rotation,
        ChainMemberKind.INTERNAL,
        ring_geometry.pitch_radius,
        ring_azimuth,
        ring_base,
    )

    members = [
        GearPreviewMember(
            stage_index=0,
            label="sun",
            member_type="external",
            center=(0.0, 0.0),
            outline_points=_preview_transform_profile(full_gear_profile_points(sun_geometry), (0.0, 0.0), sun_rotation),
            pitch_radius=sun_geometry.pitch_radius,
            base_radius=sun_geometry.base_radius,
            addendum_radius=sun_geometry.addendum_radius,
            dedendum_radius=sun_geometry.dedendum_radius,
        ),
        GearPreviewMember(
            stage_index=1,
            label="ring",
            member_type="internal",
            center=(0.0, 0.0),
            outline_points=_preview_transform_profile(full_gear_profile_points(ring_geometry), (0.0, 0.0), ring_rotation),
            pitch_radius=ring_geometry.pitch_radius,
            base_radius=ring_geometry.base_radius,
            addendum_radius=ring_geometry.addendum_radius,
            dedendum_radius=ring_geometry.dedendum_radius,
            outer_radius=payload.ring_outer_diameter / 2,
        ),
    ]
    orbit_radius = sun_geometry.pitch_radius + planet_geometry.pitch_radius
    planet_outline = full_gear_profile_points(planet_geometry)
    for i in range(payload.planet_count):
        angle = 2 * math.pi * i / payload.planet_count
        center = (orbit_radius * math.cos(angle), orbit_radius * math.sin(angle))
        planet_base = meshing_phase_base(planet_tooth_count, ChainMemberKind.EXTERNAL, angle)
        planet_rotation = propagate_meshing_phase(
            ChainMemberKind.EXTERNAL,
            sun_geometry.pitch_radius,
            sun_rotation,
            ChainMemberKind.EXTERNAL,
            planet_geometry.pitch_radius,
            angle,
            planet_base,
        )
        members.append(
            GearPreviewMember(
                stage_index=2 + i,
                label=f"planet_{i}",
                member_type="external",
                center=center,
                outline_points=_preview_transform_profile(planet_outline, center, planet_rotation),
                pitch_radius=planet_geometry.pitch_radius,
                base_radius=planet_geometry.base_radius,
                addendum_radius=planet_geometry.addendum_radius,
                dedendum_radius=planet_geometry.dedendum_radius,
            )
        )

    sun_spec = ChainMemberSpec(ChainMemberKind.EXTERNAL, payload.module, payload.pressure_angle_degrees, payload.sun_tooth_count, payload.face_width)
    planet_spec = ChainMemberSpec(ChainMemberKind.EXTERNAL, payload.module, payload.pressure_angle_degrees, planet_tooth_count, payload.face_width)
    ring_spec = ChainMemberSpec(
        ChainMemberKind.INTERNAL, payload.module, payload.pressure_angle_degrees, payload.ring_tooth_count,
        payload.face_width, payload.ring_outer_diameter,
    )
    sun_to_planet = mesh_link_ratio(sun_spec, planet_spec)
    planet_to_ring = mesh_link_ratio(planet_spec, ring_spec)

    return GearPreviewPlanetaryResult(
        members=members, sun_to_planet_ratio=sun_to_planet.ratio, planet_to_ring_ratio=planet_to_ring.ratio
    )


def _bevel_member_schematic(label: str, axis_angle_degrees: float, geometry: BevelGearGeometry) -> GearPreviewBevelMember:
    """`GearPreviewBevelMember`'s own axial-cross-section schematic (see
    that schema's docstring for why this is an envelope, not a tooth
    outline) - built in the member's own local frame (axis along local +x)
    then rotated by `axis_angle_degrees` about the shared apex at the
    origin, mirroring `_preview_transform_profile`'s rotate-then-translate
    shape with a translation of `(0, 0)` (both a pair's members' apexes
    coincide there, per `11-bevel-pair.md`).

    The 8-point outline traces the full symmetric-about-the-axis envelope:
    from the inner face-cone corner out along the face cone to the outer
    face-cone corner, across to the outer root-cone corner, in along the
    root cone to the inner root-cone corner, across the axis to the
    mirrored inner root-cone corner, and back out along the mirrored
    boundary to close - the same closed "picture-frame wedge" shape a real
    bevel-gear engineering drawing's axial half-section shows, both sides
    of the axis rather than just one."""
    face = geometry.face_cone_angle
    root = geometry.root_cone_angle
    pitch = geometry.pitch_cone_angle
    outer = geometry.cone_distance
    inner = geometry.inner_cone_distance

    def point(radius: float, angle: float) -> tuple[float, float]:
        return (radius * math.cos(angle), radius * math.sin(angle))

    local_outline = [
        point(inner, face),
        point(outer, face),
        point(outer, root),
        point(inner, root),
        point(inner, -root),
        point(outer, -root),
        point(outer, -face),
        point(inner, -face),
    ]
    local_pitch_line = (point(inner, pitch), point(outer, pitch))

    axis_angle = math.radians(axis_angle_degrees)
    outline_points = _preview_transform_profile(local_outline, (0.0, 0.0), axis_angle)
    pitch_line = tuple(_preview_transform_profile(list(local_pitch_line), (0.0, 0.0), axis_angle))

    return GearPreviewBevelMember(
        label=label,
        axis_angle_degrees=axis_angle_degrees,
        outline_points=outline_points,
        pitch_line=pitch_line,
        pitch_cone_angle_degrees=math.degrees(pitch),
        cone_distance=outer,
        inner_cone_distance=inner,
        pitch_radius=geometry.pitch_radius,
        face_width=geometry.face_width,
        effective_profile_shift=geometry.profile_shift,
    )


def _bevel_face_width_warning(label: str, geometry: BevelGearGeometry) -> str | None:
    """`10-bevel-gear.md`'s own face-width-vs-cone-distance non-blocking
    warning - the same `max_recommended_face_width = cone_distance / 3`
    rule-of-thumb `app.document.bevel.resolve_bevel_gear_from_bodies`
    itself surfaces, reproduced here so the preview flags it before
    Create, per `00-conventions.md`'s validation-banner convention."""
    max_face_width = max_recommended_face_width(geometry.cone_distance)
    if geometry.face_width > max_face_width:
        return (
            f"{label}: face_width ({geometry.face_width!r}) exceeds the recommended maximum "
            f"({max_face_width:.3f}, cone_distance/3) - the tooth thins toward degeneracy near the apex"
        )
    return None


def _gear_preview_bevel_gear_response(payload: GearPreviewBevelGearRequest) -> tuple[GearPreviewBevelMember, list[str]]:
    """`docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
    bevel-pair preview" extension, the standalone `BevelGearFeature` half -
    reuses `bevel_math.bevel_gear_geometry` directly (the same function
    `app.document.bevel.resolve_bevel_gear_from_bodies` calls), skipping
    only the OCCT shell/solid assembly itself."""
    try:
        geometry = bevel_gear_geometry(
            module=payload.module,
            tooth_count=payload.tooth_count,
            face_width=payload.face_width,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            backlash=payload.backlash,
            profile_shift=payload.profile_shift,
            # shaft_angle_degrees deliberately omitted (defaults to 90.0,
            # unused) - passing pitch_cone_angle_degrees directly skips
            # the mate_tooth_count/shaft_angle_degrees-derived path
            # entirely, per bevel_gear_geometry's own docstring.
            pitch_cone_angle_degrees=payload.pitch_cone_angle_degrees,
        )
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    warning = _bevel_face_width_warning("single", geometry)
    return _bevel_member_schematic("single", 0.0, geometry), ([warning] if warning else [])


def _gear_preview_bevel_pair_response(payload: GearPreviewBevelPairRequest) -> tuple[GearPreviewBevelPairResult, list[str]]:
    """The `BevelPairFeature` half - reuses `bevel_math.pitch_cone_half_
    angles` + `bevel_gear_geometry`'s `pitch_cone_angle_degrees` direct-
    field path in the exact same order `app.document.bevel_pair.resolve_
    bevel_pair_from_bodies` itself calls them, so preview and Create derive
    identical cone angles for identical inputs. `profile_shift` resolution
    (`None` -> auto) goes through `bevel_pair.resolve_member_profile_
    shifts` too, for the same reason - a preview with an unresolved `None`
    passed straight into `bevel_gear_geometry` would crash (that function's
    own `profile_shift: float` has no `None` handling), and resolving it
    differently from Create would make the preview lie about what Create
    would actually build."""
    try:
        gamma_1, gamma_2 = pitch_cone_half_angles(
            payload.member_1.tooth_count, payload.member_2.tooth_count, payload.shaft_angle_degrees
        )
        profile_shift_1, profile_shift_2 = resolve_member_profile_shifts(
            module=payload.module,
            tooth_count_1=payload.member_1.tooth_count,
            tooth_count_2=payload.member_2.tooth_count,
            face_width=payload.face_width,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            shaft_angle_degrees=payload.shaft_angle_degrees,
            backlash=payload.backlash,
            profile_shift_1=payload.member_1.profile_shift,
            profile_shift_2=payload.member_2.profile_shift,
            gamma_1=gamma_1,
            gamma_2=gamma_2,
        )
        geometry_1 = bevel_gear_geometry(
            module=payload.module,
            tooth_count=payload.member_1.tooth_count,
            face_width=payload.face_width,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            backlash=payload.backlash,
            profile_shift=profile_shift_1,
            pitch_cone_angle_degrees=math.degrees(gamma_1),
        )
        geometry_2 = bevel_gear_geometry(
            module=payload.module,
            tooth_count=payload.member_2.tooth_count,
            face_width=payload.face_width,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            backlash=payload.backlash,
            profile_shift=profile_shift_2,
            pitch_cone_angle_degrees=math.degrees(gamma_2),
        )
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    warnings = [
        w
        for w in (
            _bevel_face_width_warning("member_1", geometry_1),
            _bevel_face_width_warning("member_2", geometry_2),
            # `docs/gear-design/13-spiral-bevel-pair.md`'s own Spike C §3 -
            # cheap, pure math (no OCCT), so the preview can surface a
            # hand-of-spiral mismatch before Create even though its own
            # axial-cross-section envelope can't show spiral curvature
            # itself (unaffected - see GearPreviewBevelMember's own
            # docstring / 12-spiral-bevel-gear.md's "Preview stays
            # unchanged" finding).
            spiral_hand_mismatch_warning(
                payload.spiral_angle_degrees,
                _spiral_hand_from_feature(payload.member_1.spiral_hand),
                _spiral_hand_from_feature(payload.member_2.spiral_hand),
            ),
        )
        if w
    ]
    members = [
        _bevel_member_schematic("member_1", 0.0, geometry_1),
        _bevel_member_schematic("member_2", payload.shaft_angle_degrees, geometry_2),
    ]
    mesh_preview = bevel_pair_mesh_preview(geometry_1, geometry_2)
    return (
        GearPreviewBevelPairResult(
            members=members,
            shaft_angle_degrees=payload.shaft_angle_degrees,
            mesh_preview=BevelPairMeshPreviewResult(
                member_1_teeth=mesh_preview.member_1_teeth,
                member_2_teeth=mesh_preview.member_2_teeth,
                center_1=mesh_preview.center_1,
                center_2=mesh_preview.center_2,
                pitch_radius_1=mesh_preview.pitch_radius_1,
                pitch_radius_2=mesh_preview.pitch_radius_2,
            ),
        ),
        warnings,
    )


def _gear_preview_response(payload: GearPreviewRequest) -> GearPreviewResponse:
    """`docs/gear-design/08-entry-screen-and-preview.md`: the actual math
    behind `/gear/preview` - runs only `gear_math`/`gear_chain_math` (no
    OCCT, no tessellation), shared by the GET and POST routes below.
    `"chain"`/`"planetary"` reuse `_gear_preview_chain_response`/
    `_gear_preview_planetary_response` above, `"bevel_gear"`/`"bevel_pair"`
    reuse `_gear_preview_bevel_gear_response`/`_gear_preview_bevel_pair_
    response`; a future gear type still adds one more `gear_kind` literal
    value plus one more branch here, not a new endpoint, per this schema's
    own original design."""
    if payload.gear_kind == "chain":
        if payload.chain is None:
            raise _invalid_gear_preview_parameters("chain is required when gear_kind is chain")
        return GearPreviewResponse(gear_kind="chain", chain=_gear_preview_chain_response(payload.chain))

    if payload.gear_kind == "planetary":
        if payload.planetary is None:
            raise _invalid_gear_preview_parameters("planetary is required when gear_kind is planetary")
        return GearPreviewResponse(
            gear_kind="planetary", planetary=_gear_preview_planetary_response(payload.planetary)
        )

    if payload.gear_kind == "bevel_gear":
        if payload.bevel_gear is None:
            raise _invalid_gear_preview_parameters("bevel_gear is required when gear_kind is bevel_gear")
        member, warnings = _gear_preview_bevel_gear_response(payload.bevel_gear)
        return GearPreviewResponse(gear_kind="bevel_gear", bevel_gear=member, warnings=warnings)

    if payload.gear_kind == "bevel_pair":
        if payload.bevel_pair is None:
            raise _invalid_gear_preview_parameters("bevel_pair is required when gear_kind is bevel_pair")
        result, warnings = _gear_preview_bevel_pair_response(payload.bevel_pair)
        return GearPreviewResponse(gear_kind="bevel_pair", bevel_pair=result, warnings=warnings)

    if payload.module is None or payload.tooth_count is None:
        raise _invalid_gear_preview_parameters("module and tooth_count are required for this gear_kind")

    if payload.gear_kind == "rack":
        try:
            rack_geometry = rack_tooth_geometry(
                module=payload.module,
                pressure_angle_degrees=payload.pressure_angle_degrees,
                backlash=payload.backlash,
            )
            outline_points = full_rack_profile_points(rack_geometry, payload.tooth_count)
        except GearGeometryError as exc:
            raise _invalid_gear_preview_parameters(str(exc)) from exc

        backing_height = (
            payload.backing_height
            if payload.backing_height is not None
            else default_rack_backing_height(payload.module)
        )
        if backing_height <= 0:
            raise _invalid_gear_preview_parameters(f"backing_height must be positive, got {backing_height!r}")

        return GearPreviewResponse(
            gear_kind="rack",
            outline_points=outline_points,
            pitch_line_y=0.0,
            addendum_line_y=rack_geometry.addendum_height,
            dedendum_line_y=-rack_geometry.dedendum_height,
            rack_length=gear_math_rack_length(rack_geometry, payload.tooth_count),
        )

    is_internal = payload.gear_kind == "internal"
    if is_internal and payload.outer_diameter is None:
        raise _invalid_gear_preview_parameters("outer_diameter is required when gear_kind is internal")

    resolved_profile_shift = resolve_gear_profile_shift(
        module=payload.module,
        tooth_count=payload.tooth_count,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        backlash=payload.backlash,
        profile_shift=payload.profile_shift,
        is_internal=is_internal,
    )
    try:
        geometry = spur_gear_geometry(
            module=payload.module,
            tooth_count=payload.tooth_count,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            profile_shift=resolved_profile_shift,
            backlash=payload.backlash,
            is_internal=is_internal,
        )
        outline_points = full_gear_profile_points(geometry)
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    warnings: list[str] = []
    if not is_internal:
        warning = undercut_warning(payload.tooth_count, payload.pressure_angle_degrees, resolved_profile_shift)
        if warning is not None:
            warnings.append(warning)

    return GearPreviewResponse(
        gear_kind=payload.gear_kind,
        outline_points=outline_points,
        pitch_radius=geometry.pitch_radius,
        base_radius=geometry.base_radius,
        addendum_radius=geometry.addendum_radius,
        dedendum_radius=geometry.dedendum_radius,
        outer_radius=(payload.outer_diameter / 2) if is_internal and payload.outer_diameter else None,
        effective_profile_shift=resolved_profile_shift,
        warnings=warnings,
    )


@gear_router.post("/gear/preview", response_model=GearPreviewResponse)
def preview_gear(payload: GearPreviewRequest) -> GearPreviewResponse:
    """`docs/gear-design/08-entry-screen-and-preview.md`: cheap enough (pure
    `gear_math`, no OCCT/tessellation) to call on every debounced keystroke
    while the Gear Design entry screen's form is being edited - the POST
    body form, for a client sending a full JSON payload."""
    return _gear_preview_response(payload)


@gear_router.get("/gear/preview", response_model=GearPreviewResponse)
def preview_gear_via_query(
    gear_kind: Literal["external", "internal", "rack"] = Query(...),
    module: float = Query(...),
    tooth_count: int = Query(...),
    pressure_angle_degrees: float = Query(20.0),
    profile_shift: float | None = Query(None),
    backlash: float = Query(0.0),
    outer_diameter: float | None = Query(None),
    backing_height: float | None = Query(None),
) -> GearPreviewResponse:
    """Same preview, as a plain query-string GET - convenient for a quick
    manual check (a browser/`curl` URL, no JSON body) without needing a
    second implementation of the actual math."""
    return _gear_preview_response(
        GearPreviewRequest(
            gear_kind=gear_kind,
            module=module,
            tooth_count=tooth_count,
            pressure_angle_degrees=pressure_angle_degrees,
            profile_shift=profile_shift,
            backlash=backlash,
            outer_diameter=outer_diameter,
            backing_height=backing_height,
        )
    )
